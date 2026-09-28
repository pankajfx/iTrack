from flask import Flask, render_template, request, jsonify, session, redirect, url_for, flash, send_file
from flask_pymongo import PyMongo
from flask.sessions import SecureCookieSessionInterface
from flask_socketio import SocketIO, emit, join_room, leave_room
from werkzeug.security import check_password_hash, generate_password_hash
from werkzeug.middleware.proxy_fix import ProxyFix
from datetime import datetime, timezone, timedelta
from bson import ObjectId
from bson.errors import InvalidId
from pymongo import ReturnDocument
import gridfs
import base64
import re
from pymongo.errors import DuplicateKeyError
import os
import hmac
import secrets
import time
from urllib.parse import urlparse
from functools import wraps
from dotenv import load_dotenv
from theme_config import get_active_fe_theme, get_active_noc_theme, get_theme_for_role

# Load environment variables from the project-root .env before reading any config.
load_dotenv(os.path.join(os.path.dirname(os.path.abspath(__file__)), '.env'))

app = Flask(__name__)
app.config['SECRET_KEY'] = os.environ.get('SECRET_KEY', 'dev-secret-key-change-in-production')
# maxPoolSize must cover the concurrency of every worker process, or requests
# queue on connection checkout under load. Appended only when the URI does not
# already carry pool settings, so an explicit MONGO_URI always wins.
_mongo_uri = os.environ.get('MONGO_URI', 'mongodb://localhost:27017/sdwan_tracker')
if 'maxPoolSize' not in _mongo_uri:
    _pool = os.environ.get('MONGO_MAX_POOL_SIZE', '100')
    _mongo_uri += ('&' if '?' in _mongo_uri else '?') +                   f'maxPoolSize={_pool}&minPoolSize=5&waitQueueTimeoutMS=5000&retryWrites=true'
app.config['MONGO_URI'] = _mongo_uri

app.config['MAX_CONTENT_LENGTH'] = 16 * 1024 * 1024  # 16MB max file size

# Development conveniences that cost real bandwidth in production: without them
# ~300KB of CSS/JS/fonts was revalidated on every page load, per user. Both now
# follow FLASK_DEBUG. Static URLs are versioned with ?v=<STATIC_VERSION> so a
# long max-age is still safe to bust on deploy.
FLASK_DEBUG = os.environ.get('FLASK_DEBUG', 'false').lower() == 'true'
app.config['TEMPLATES_AUTO_RELOAD'] = FLASK_DEBUG
app.config['SEND_FILE_MAX_AGE_DEFAULT'] = 0 if FLASK_DEBUG else 31536000
def _static_fingerprint():
    """Newest modification time under static/. Any changed CSS/JS - not just
    output.css, which this used to watch - produces a new version, so browsers
    holding year-long cached copies fetch the new file after a deploy."""
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'static')
    newest = 0
    for base, _dirs, files in os.walk(root):
        for name in files:
            try:
                newest = max(newest, int(os.path.getmtime(os.path.join(base, name))))
            except OSError:
                pass
    return str(newest)


STATIC_VERSION = os.environ.get('STATIC_VERSION') or _static_fingerprint()

# The session cookie is signed with SECRET_KEY; anyone holding it can mint a
# session for any user and role. The default used to be a fixed string in this
# file. Outside debug mode the app now refuses to start without a real one.
_WEAK_SECRETS = {'', 'dev-secret-key-change-in-production', 'your-strong-secret-key',
                 'change-me', 'changeme', 'secret'}
if app.config['SECRET_KEY'] in _WEAK_SECRETS or len(app.config['SECRET_KEY']) < 32:
    if FLASK_DEBUG:
        print('[warning] SECRET_KEY is weak or missing - tolerated only because FLASK_DEBUG=true')
    else:
        raise RuntimeError(
            'SECRET_KEY is missing or weak (need at least 32 random characters). Generate one with:  '
            'python -c "import secrets; print(secrets.token_urlsafe(48))"  and set it in .env')

mongo = PyMongo(app)
# Serving model. async_mode='threading' + socketio.run() is the Werkzeug dev
# server: one process, one thread per connection, and no way to add workers -
# without a message queue a second worker cannot see the first worker's rooms, so
# broadcasts reach only the clients attached to whichever worker emitted them.
#
#   SOCKETIO_ASYNC_MODE    threading (default, dev) | gevent | eventlet
#   SOCKETIO_MESSAGE_QUEUE redis://host:6379/0 - REQUIRED before running >1 worker
#
# Production (see PROJECT_GUIDE section 15.5 item 9):
#   SOCKETIO_ASYNC_MODE=gevent SOCKETIO_MESSAGE_QUEUE=redis://127.0.0.1:6379/0 #   gunicorn -k geventwebsocket.gunicorn.workers.GeventWebSocketWorker -w 4 app:app
SOCKETIO_ASYNC_MODE    = os.environ.get('SOCKETIO_ASYNC_MODE', 'threading')
SOCKETIO_MESSAGE_QUEUE = os.environ.get('SOCKETIO_MESSAGE_QUEUE') or None

socketio = SocketIO(app,
                    cors_allowed_origins=os.environ.get('CORS_ORIGINS', '*'),
                    async_mode=SOCKETIO_ASYNC_MODE,
                    message_queue=SOCKETIO_MESSAGE_QUEUE)

# ─── Jinja2 template filters ───────────────────────────────────────────────
@app.template_filter('display_name')
def display_name_filter(username):
    """Convert 'Name_Franchise' to 'Name (Franchise)'."""
    if not username:
        return username
    if '_' in username:
        parts = username.split('_', 1)
        return f'{parts[0]} ({parts[1]})'
    return username

# ─── Canonical role constants ───────────────────────────────────────────────
# These are the ONLY valid role strings used throughout the application.
# Session, DB documents, and route guards all use these exact strings.
ROLE_FE             = 'FIELD_ENGINEER'
ROLE_FEG            = 'FIELD_ENGINEER_GROUP'
ROLE_FS             = 'FIELD_SUPPORT'
ROLE_FSG            = 'FIELD_SUPPORT_GROUP'
ROLE_NS             = 'NOC_SUPPORT'      # NOC Support individual operator
ROLE_NSG            = 'NOC_SUPPORT_GROUP'
ROLE_ANALYTICS      = 'ANALYTICS'

FE_ROLES  = {ROLE_FE, ROLE_FEG, ROLE_FS, ROLE_FSG}
NOC_ROLES = {ROLE_NS, ROLE_NSG}

# ─── Real-time configuration ─────────────────────────────────────────────────
# Controls how updates are delivered: Socket.IO-first with API fallback
REALTIME_MODE = os.environ.get('REALTIME_MODE', 'hybrid')  # 'socket', 'api', 'hybrid'
SOCKET_TIMEOUT = int(os.environ.get('SOCKET_TIMEOUT', '2000'))  # milliseconds
SOCKET_INCLUDE_FULL_DATA = os.environ.get('SOCKET_INCLUDE_FULL_DATA', 'true').lower() == 'true'

# ─── Media pipeline configuration ────────────────────────────────────────────
# Photos and voice notes are stored as base64 data URLs INSIDE documents, so every
# byte is paid three times over: once in Mongo, once in every API response that
# carries the document, and once in the client's memory. These knobs trade fidelity
# against that cost without a code change.
#
#   MEDIA_PROFILE   compact | balanced (default) | original
#   IMAGE_MAX_DIM   longest edge in px for server-side resize; 0 = never resize
#   IMAGE_QUALITY   JPEG quality 1-100 for the server-side re-encode
#   CAPTURE_MAX_DIM / CAPTURE_QUALITY   handed to the browser camera (see
#                   window.MEDIA_CONFIG) so in-app captures follow the same policy
#
# A note on "original": getUserMedia samples a VIDEO stream, so an in-app capture
# can never reach the resolution of the phone's native still camera regardless of
# this setting - see PROJECT_GUIDE.md section 15.
MEDIA_PROFILES = {
    'compact':  {'image_max_dim': 1280, 'image_quality': 82,
                 'capture_max_dim': 1280, 'capture_quality': 0.82},
    'balanced': {'image_max_dim': 1920, 'image_quality': 95,
                 'capture_max_dim': 1920, 'capture_quality': 0.95},
    'original': {'image_max_dim': 0,    'image_quality': 98,
                 'capture_max_dim': 4096, 'capture_quality': 0.98},
}
MEDIA_PROFILE = os.environ.get('MEDIA_PROFILE', 'balanced').lower()
if MEDIA_PROFILE not in MEDIA_PROFILES:
    MEDIA_PROFILE = 'balanced'
_mp = MEDIA_PROFILES[MEDIA_PROFILE]

def _env_int(name, default):
    try:
        return int(os.environ[name])
    except (KeyError, ValueError):
        return default

def _env_float(name, default):
    try:
        return float(os.environ[name])
    except (KeyError, ValueError):
        return default

IMAGE_MAX_DIM   = _env_int('IMAGE_MAX_DIM',   _mp['image_max_dim'])
IMAGE_QUALITY   = _env_int('IMAGE_QUALITY',   _mp['image_quality'])
CAPTURE_MAX_DIM = _env_int('CAPTURE_MAX_DIM', _mp['capture_max_dim'])
CAPTURE_QUALITY = _env_float('CAPTURE_QUALITY', _mp['capture_quality'])


# ─── Authentication hardening ────────────────────────────────────────────────
# Failed logins are counted in Mongo (collection login_attempts, TTL-expired), so
# the limits hold across every worker process and survive restarts. Three
# counters, all over the same sliding window:
#   pair     account + client IP  - stops one source guessing one password
#   account  across all IPs       - caps distributed guessing on one account
#   ip       across all accounts  - stops one source spraying many accounts
# Locking on the pair first means an attacker who knows a name (the login page
# lists them) cannot lock the real user out from a different IP.
LOGIN_MAX_FAILURES         = _env_int('LOGIN_MAX_FAILURES', 5)
LOGIN_ACCOUNT_MAX_FAILURES = _env_int('LOGIN_ACCOUNT_MAX_FAILURES', 20)
LOGIN_IP_MAX_FAILURES      = _env_int('LOGIN_IP_MAX_FAILURES', 30)
LOGIN_WINDOW_MINUTES       = _env_int('LOGIN_WINDOW_MINUTES', 15)

# Sessions used to be browser-session cookies with no server-side expiry, and a
# deleted user kept access for as long as their browser stayed open (field
# phones rarely close browsers). Now: a sliding lifetime, and every request
# re-checks that the account still exists, is active, and has not had its
# sessions revoked (session_epoch is bumped on password change/deactivation).
SESSION_LIFETIME_HOURS = _env_int('SESSION_LIFETIME_HOURS', 12)
USER_CHECK_TTL_SECONDS = _env_int('USER_CHECK_TTL_SECONDS', 30)
app.config['PERMANENT_SESSION_LIFETIME'] = timedelta(hours=SESSION_LIFETIME_HOURS)
app.config['SESSION_REFRESH_EACH_REQUEST'] = True

# Behind Caddy/Nginx every request arrives from 127.0.0.1. Without ProxyFix the
# per-IP login limits would count every user as one client, and HTTPS would be
# invisible to the app. Set to the number of proxies in front of the app (1 for
# the standard single reverse proxy). Leave 0 when clients connect directly -
# trusting X-Forwarded-* from untrusted clients lets them spoof their IP.
TRUST_PROXY_HOPS = _env_int('TRUST_PROXY_HOPS', 0)
if TRUST_PROXY_HOPS > 0:
    app.wsgi_app = ProxyFix(app.wsgi_app, x_for=TRUST_PROXY_HOPS, x_proto=TRUST_PROXY_HOPS,
                            x_host=TRUST_PROXY_HOPS, x_port=TRUST_PROXY_HOPS)

# ─── Session cookie ──────────────────────────────────────────────────────────
# HttpOnly: page scripts cannot read it. SameSite=Lax: other sites' POSTs do
# not carry it. Lax rather than Strict, because Strict also drops the cookie on
# top-level links from outside (a tracker link shared in WhatsApp or email would
# land the user logged out). Secure is decided per request (SESSION_COOKIE_SECURE
# = auto): set whenever the request arrived over HTTPS - directly, or through a
# proxy when TRUST_PROXY_HOPS is set - so plain-HTTP development keeps working.
# Force it with SESSION_COOKIE_SECURE=true once everything is served over HTTPS.
SESSION_COOKIE_SECURE_MODE = os.environ.get('SESSION_COOKIE_SECURE', 'auto').strip().lower()
app.config['SESSION_COOKIE_HTTPONLY'] = True
app.config['SESSION_COOKIE_SAMESITE'] = 'Lax'


class _AutoSecureSessionInterface(SecureCookieSessionInterface):
    def get_cookie_secure(self, app):
        if SESSION_COOKIE_SECURE_MODE in ('1', 'true', 'yes'):
            return True
        if SESSION_COOKIE_SECURE_MODE in ('0', 'false', 'no'):
            return False
        return request.is_secure


app.session_interface = _AutoSecureSessionInterface()

# ─── Response headers ────────────────────────────────────────────────────────
# CSP: scripts, styles, fonts, images and connections only from this origin (all
# vendor assets are self-hosted), plus reverse geocoding (CSP_CONNECT_EXTRA,
# default Nominatim). 'unsafe-inline' remains for scripts and styles because the
# templates use inline <script> blocks and onclick= attributes throughout;
# removing it means moving every handler into files - tracked in PROJECT_GUIDE.
# HSTS is opt-in (HSTS_MAX_AGE) - only enable it once a trusted certificate and
# a stable hostname are in place, because browsers then refuse plain HTTP.
CSP_CONNECT_EXTRA = os.environ.get('CSP_CONNECT_EXTRA', 'https://nominatim.openstreetmap.org').split()
HSTS_MAX_AGE = _env_int('HSTS_MAX_AGE', 0)
_CSP = '; '.join([
    "default-src 'self'",
    "script-src 'self' 'unsafe-inline'",
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data: blob:",
    "media-src 'self' data: blob:",
    "font-src 'self' data:",
    "connect-src 'self' ws: wss: " + ' '.join(CSP_CONNECT_EXTRA),
    "worker-src 'self' blob:",
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'self'",
    "frame-ancestors 'none'",
])


@app.after_request
def security_headers(resp):
    h = resp.headers
    h.setdefault('X-Content-Type-Options', 'nosniff')
    h.setdefault('X-Frame-Options', 'DENY')
    h.setdefault('Referrer-Policy', 'strict-origin-when-cross-origin')
    h.setdefault('Permissions-Policy', 'camera=(self), microphone=(self), geolocation=(self), '
                                       'payment=(), usb=(), serial=(), bluetooth=()')
    h.setdefault('Cross-Origin-Opener-Policy', 'same-origin')
    if 'Content-Security-Policy' not in h:       # /api/media sets a stricter sandbox policy
        h['Content-Security-Policy'] = _CSP
    if HSTS_MAX_AGE > 0 and request.is_secure:
        h.setdefault('Strict-Transport-Security', 'max-age=%d' % HSTS_MAX_AGE)
    # Authenticated JSON must not linger in shared caches or the back/forward cache.
    if request.path.startswith('/api/') and not request.path.startswith('/api/media/'):
        h['Cache-Control'] = 'no-store'
    return resp


# ─── Tracker status constants ────────────────────────────────────────────────
# Canonical status strings used across backend, frontend, and analytics.
STATUS_WAITING_NOC       = 'waiting_noc_assignment'
STATUS_NOC_WORKING       = 'noc_working'
STATUS_ZTP_PULL_PENDING  = 'ztp_pull_pending'
STATUS_ZTP_CONFIG_UNVERIFIED = 'ztp_config_unverified'
STATUS_ZTP_PULL_DONE_FE  = 'ztp_pull_done_by_fe'
STATUS_ZTP_PULL_UNVERIFIED = 'ztp_pull_unverified'
STATUS_ZTP_PULL_REQ_NOC  = 'ztp_pull_requested_from_noc'
STATUS_FE_REQ_ZTP        = 'fe_requested_ztp'
STATUS_READY_COORD       = 'ready_for_coordination'
STATUS_HSO_SUBMITTED     = 'hso_submitted'
STATUS_HSO_REJECTED      = 'hso_rejected'
STATUS_COMPLETE          = 'installation_complete'
# Legacy statuses (kept for backwards compat with old documents)
STATUS_ZTP_PULL_VERIFIED = 'ztp_pull_verified'
STATUS_ZTP_PULL_DONE_NOC = 'ztp_pull_done_by_noc'

# Statuses where chat is unlocked (FE-NS coordination phase)
CHAT_UNLOCKED_STATUSES = {
    STATUS_READY_COORD,
    STATUS_FE_REQ_ZTP,
    STATUS_ZTP_PULL_REQ_NOC,    # Chat unlocks when FE requests NOC to do ZTP pull
    STATUS_HSO_SUBMITTED,
    STATUS_HSO_REJECTED,
    STATUS_COMPLETE,
    STATUS_ZTP_PULL_VERIFIED,   # Legacy
    STATUS_ZTP_PULL_DONE_NOC,   # Legacy
}

# Statuses from which FE can submit HSO
HSO_SUBMITTABLE_STATUSES = {
    STATUS_READY_COORD,
    STATUS_HSO_REJECTED,
    STATUS_FE_REQ_ZTP,
    STATUS_ZTP_PULL_VERIFIED,   # Legacy
    STATUS_ZTP_PULL_DONE_NOC,   # Legacy
}

# ─── Helpers ────────────────────────────────────────────────────────────────
@app.context_processor
def inject_config():
    """Make configuration available to all templates"""
    return {
        'config': {
            'REALTIME_MODE': REALTIME_MODE,
            'SOCKET_TIMEOUT': SOCKET_TIMEOUT,
            'SOCKET_INCLUDE_FULL_DATA': SOCKET_INCLUDE_FULL_DATA,
            'MEDIA_PROFILE': MEDIA_PROFILE,
            'CAPTURE_MAX_DIM': CAPTURE_MAX_DIM,
            'CAPTURE_QUALITY': CAPTURE_QUALITY,
            'STATIC_VERSION': STATIC_VERSION,
        }
    }

def next_tracker_id(year):
    """Atomically allocate the next per-year tracker number.

    The previous implementation was f"SDWAN-{year}-{count_documents({}) + 1}",
    which hands the SAME id to two FEs creating a tracker at the same moment,
    repeats ids after any deletion, and costs an O(n) scan on every create.
    """
    doc = mongo.db.counters.find_one_and_update(
        {'_id': f'tracker_{year}'},
        {'$inc': {'seq': 1}},
        upsert=True,
        return_document=ReturnDocument.AFTER,
    )
    return f"SDWAN-{year}-{doc['seq']:06d}"


# ─── Media store (GridFS) ────────────────────────────────────────────────────
# Photos and voice notes used to live as base64 data URLs INSIDE tracker and chat
# documents. That made 69% of tracker bytes image data, put every photo into every
# list response, and re-sent whole media files on every 5-second chat poll
# (PROJECT_GUIDE section 15.2). They now live in GridFS and documents carry only a
# reference; clients fetch /api/media/<id> once and the browser caches it.
#
# Reads stay backward compatible: a document may still hold an inline `data` /
# `file_url` data URL. serialize_media_ref() emits a usable URL either way, so the
# migration (scripts/migrate_media.py) can run at any time, or not at all.
_DATA_URL_RE = re.compile(r'^data:([^;,]+)(;base64)?,(.*)$', re.S)

# Media types safe to serve inline from our origin. Types arrive from the client
# (data URL prefixes, multipart content types) and are never trusted as-is:
# text/html and image/svg+xml both carry script, and serving either inline from
# /api/media would run it on this origin. Anything off this list is stored and
# served as an opaque download.
INLINE_MEDIA_TYPES = {
    'image/jpeg', 'image/png', 'image/webp', 'image/gif', 'image/bmp',
    'image/heic', 'image/heif',
    'audio/webm', 'audio/mp4', 'audio/ogg', 'audio/mpeg', 'audio/wav',
    'audio/x-wav', 'audio/aac', 'audio/x-m4a',
}


def safe_media_type(mime):
    mime = (mime or '').split(';')[0].strip().lower()
    return mime if mime in INLINE_MEDIA_TYPES else 'application/octet-stream'

def _gridfs():
    return gridfs.GridFS(mongo.db, collection='media')


def store_data_url(data_url, tracker_id=None, kind=None):
    """Persist a data: URL into GridFS. Returns (file_id, mime, size) or None."""
    if not data_url or not isinstance(data_url, str):
        return None
    m = _DATA_URL_RE.match(data_url)
    if not m:
        return None
    mime, is_b64, payload = safe_media_type(m.group(1)), bool(m.group(2)), m.group(3)
    try:
        raw = base64.b64decode(payload) if is_b64 else payload.encode('utf-8')
    except Exception:
        return None
    file_id = _gridfs().put(raw, contentType=mime,
                            metadata={'tracker_id': tracker_id, 'kind': kind})
    return {'file_id': str(file_id), 'mime': mime, 'size': len(raw)}


def media_url(file_id):
    return f'/api/media/{file_id}'


def serialize_media_ref(ref):
    """Normalise a stored media reference to something the client can render.

    Accepts the new shape ({file_id, mime, size}) and the legacy inline shape
    ({data: 'data:...'} / a bare data URL string), so old documents keep working.
    """
    if not ref:
        return None
    if isinstance(ref, str):
        return {'url': ref, 'inline': True}
    if ref.get('file_id'):
        out = {'url': media_url(ref['file_id']), 'file_id': ref['file_id'],
               'mime': ref.get('mime'), 'size': ref.get('size'), 'inline': False}
        return {k: v for k, v in out.items() if v is not None}
    if ref.get('data'):
        return {'url': ref['data'], 'inline': True}
    return None


def bootstrap_tracker_counters():
    """Seed the per-year counters from ids already in the collection.

    Without this the first allocation after deploying the atomic counter would
    return SDWAN-<year>-000001 and collide with existing trackers. Uses $max, so
    it is idempotent and safe to run from every worker on start.
    """
    try:
        rows = mongo.db.trackers.aggregate([
            {'$match': {'tracker_id': {'$regex': r'^SDWAN-\d{4}-\d+$'}}},
            {'$project': {
                'year': {'$substrBytes': ['$tracker_id', 6, 4]},
                'seq': {'$toInt': {'$substrBytes': ['$tracker_id', 11, -1]}},
            }},
            {'$group': {'_id': '$year', 'max': {'$max': '$seq'}}},
        ])
        for row in rows:
            mongo.db.counters.update_one(
                {'_id': f"tracker_{row['_id']}"},
                {'$max': {'seq': row['max']}},
                upsert=True,
            )
    except Exception as exc:                       # never block startup on this
        print(f"[startup] tracker counter bootstrap skipped: {exc}")


def get_utc_now():
    """Return the current time as a naive UTC datetime.
    MongoDB stores datetimes as UTC by default; using naive datetimes
    avoids timezone-aware vs naive comparison errors."""
    return datetime.utcnow()


def serialize_doc(doc):
    """Recursively convert ObjectIds and datetimes to JSON-safe types.
    Datetimes are formatted as ISO-8601 with a 'Z' suffix so the
    frontend knows they are UTC and can convert to IST."""
    if doc is None:
        return None
    if isinstance(doc, list):
        return [serialize_doc(item) for item in doc]
    if isinstance(doc, dict):
        doc = doc.copy()
        if '_id' in doc:
            doc['_id'] = str(doc['_id'])
        for key, value in doc.items():
            if isinstance(value, ObjectId):
                doc[key] = str(value)
            elif isinstance(value, datetime):
                doc[key] = value.isoformat() + 'Z' if value.tzinfo is None else value.isoformat()
            elif isinstance(value, (dict, list)):
                doc[key] = serialize_doc(value)
        return doc
    return doc


def make_event(stage, actor_id, actor_role, remarks, metadata=None):
    """Build a standard event dict. Every stage transition goes through
    this helper to ensure consistent structure across all API endpoints."""
    return {
        'stage': stage,
        'timestamp': get_utc_now(),
        'actor': actor_id,
        'actor_role': actor_role,
        'remarks': remarks,
        'metadata': metadata or {},
        'delay_tags': []
    }


@app.errorhandler(InvalidId)
def handle_invalid_object_id(_e):
    return jsonify({'error': 'Not found'}), 404


@app.errorhandler(404)
def handle_not_found(e):
    if request.path.startswith('/api/'):
        return jsonify({'error': 'Not found'}), 404
    return e


@app.errorhandler(405)
def handle_method_not_allowed(e):
    if request.path.startswith('/api/'):
        return jsonify({'error': 'Method not allowed'}), 405
    return e


@app.errorhandler(500)
def handle_server_error(e):
    # Flask has already logged the traceback; the client gets no internals.
    if request.path.startswith('/api/'):
        return jsonify({'error': 'Internal server error'}), 500
    return e


# ─── Login throttling ────────────────────────────────────────────────────────
_LOOPBACK = {'127.0.0.1', '::1', 'localhost'}

# Checked against when an account does not exist, so a missing account and a
# wrong password cost the same time - otherwise latency reveals which names exist.
_DUMMY_PASSWORD_HASH = generate_password_hash('placeholder-for-constant-time-login')


def _throttle_keys(account_key):
    ip = request.remote_addr or 'unknown'
    keys = {'pair': 'pair:%s|%s' % (account_key, ip), 'account': 'acct:' + account_key}
    # A loopback address means the real client is behind an unconfigured local
    # proxy; counting it would pool every user into one bucket.
    if ip not in _LOOPBACK:
        keys['ip'] = 'ip:' + ip
    return keys


def login_lockout_seconds(account_key):
    """Seconds until this caller may try `account_key` again (0 = allowed)."""
    now = get_utc_now()
    window = timedelta(minutes=LOGIN_WINDOW_MINUTES)
    limits = {'pair': LOGIN_MAX_FAILURES, 'account': LOGIN_ACCOUNT_MAX_FAILURES,
              'ip': LOGIN_IP_MAX_FAILURES}
    wait = 0.0
    for kind, key in _throttle_keys(account_key).items():
        recent = [d['at'] for d in mongo.db.login_attempts.find(
            {'key': key, 'at': {'$gt': now - window}}, {'at': 1}).sort('at', 1)]
        if len(recent) >= limits[kind]:
            # Allowed again once enough of the oldest failures leave the window.
            release = recent[len(recent) - limits[kind]] + window
            wait = max(wait, (release - now).total_seconds())
    return wait


def record_login_failure(account_key):
    now = get_utc_now()
    mongo.db.login_attempts.insert_many(
        [{'key': k, 'at': now} for k in _throttle_keys(account_key).values()])


def clear_login_failures(account_key):
    keys = _throttle_keys(account_key)
    mongo.db.login_attempts.delete_many({'key': {'$in': [keys['pair'], keys['account']]}})


def throttled_response(wait):
    minutes = max(1, int(round(wait / 60.0)))
    resp = jsonify({'success': False,
                    'message': 'Too many failed attempts. Try again in %d minute%s.'
                               % (minutes, '' if minutes == 1 else 's')})
    resp.status_code = 429
    resp.headers['Retry-After'] = str(int(wait) + 1)
    return resp


def ensure_security_indexes():
    """TTL cleanup for login_attempts plus the lookup index; idempotent."""
    try:
        mongo.db.login_attempts.create_index([('key', 1), ('at', 1)], name='login_attempts_key_at')
        mongo.db.login_attempts.create_index('at', name='login_attempts_ttl',
                                             expireAfterSeconds=max(LOGIN_WINDOW_MINUTES, 60) * 60)
    except Exception as exc:                         # never block startup on this
        print(f"[startup] security index setup skipped: {exc}")


# ─── Session validity ────────────────────────────────────────────────────────
_user_state_cache = {}      # user_id -> (checked_at, session_epoch or None if invalid)


def session_user_valid():
    """The session's user still exists, is active, and has not been revoked.

    Cached per process for USER_CHECK_TTL_SECONDS, so revocation takes effect
    within that many seconds on every worker without a database hit per request.
    """
    uid = session.get('user_id')
    if not uid:
        return False
    now = time.monotonic()
    hit = _user_state_cache.get(uid)
    if hit and now - hit[0] < USER_CHECK_TTL_SECONDS:
        epoch = hit[1]
    else:
        oid = parse_oid(uid)
        doc = mongo.db.users.find_one({'_id': oid}, {'active': 1, 'session_epoch': 1}) if oid else None
        epoch = None if (not doc or doc.get('active') is False) else doc.get('session_epoch', 0)
        if len(_user_state_cache) > 50000:
            _user_state_cache.clear()
        _user_state_cache[uid] = (now, epoch)
    return epoch is not None and epoch == session.get('epoch', 0)


def _wants_json():
    return request.path.startswith(('/api/', '/admin/api/')) or request.is_json


def login_required(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if 'user_id' not in session or not session_user_valid():
            session.clear()
            # API callers get a 401 they can act on; a redirect used to hand
            # fetch() an HTML login page that then failed to parse as JSON.
            if _wants_json():
                resp = jsonify({'error': 'Authentication required', 'login': url_for('login')})
                resp.status_code = 401
                resp.headers['X-Auth-Required'] = '1'
                return resp
            return redirect(url_for('login'))
        return f(*args, **kwargs)
    return decorated_function


# ─── Request guards ──────────────────────────────────────────────────────────
def _has_operator_keys(value, depth=0):
    if depth > 32:
        return True                                  # absurd nesting is refused too
    if isinstance(value, dict):
        return any((isinstance(k, str) and k.startswith('$')) or _has_operator_keys(v, depth + 1)
                   for k, v in value.items())
    if isinstance(value, list):
        return any(_has_operator_keys(v, depth + 1) for v in value)
    return False


# ─── CSRF ────────────────────────────────────────────────────────────────────
# Session cookies ride along on requests another site makes, so every
# state-changing request must prove it came from one of our pages:
#   1. X-CSRF-Token must equal the per-session token. Pages carry it in
#      <meta name="csrf-token">, and the fetch() wrapper in base.html attaches it
#      to every same-origin POST/PUT/PATCH/DELETE - no page needs to change.
#   2. An Origin (or Referer) header naming another host is refused outright.
#      Host-only comparison: behind a TLS-terminating proxy the scheme differs
#      (https outside, http inside) unless TRUST_PROXY_HOPS is set, and Caddy
#      and the generated Nginx config both forward Host. PUBLIC_ORIGINS adds
#      extra allowed origins, e.g. a second hostname for the same service.
# /socket.io/ never reaches these hooks (Engine.IO answers it first); sockets are
# protected by the origin check configured on the SocketIO server instead.
PUBLIC_ORIGINS = {o.strip().rstrip('/') for o in os.environ.get('PUBLIC_ORIGINS', '').split(',') if o.strip()}
_UNSAFE_METHODS = ('POST', 'PUT', 'PATCH', 'DELETE')


def csrf_token():
    token = session.get('csrf_token')
    if not token:
        token = secrets.token_urlsafe(32)
        session['csrf_token'] = token
    return token


app.jinja_env.globals['csrf_token'] = csrf_token


def _origin_allowed(value):
    if not value:
        return True                                  # absent: the token decides
    try:
        u = urlparse(value)
    except ValueError:
        return False
    if '%s://%s' % (u.scheme, u.netloc) in PUBLIC_ORIGINS:
        return True
    return bool(u.netloc) and u.netloc.lower() == (request.host or '').lower()


def _csrf_failure(reason):
    resp = jsonify({'error': 'Request blocked: %s. Reload the page and try again.' % reason})
    resp.status_code = 403
    resp.headers['X-CSRF-Failed'] = '1'
    return resp


@app.before_request
def csrf_protect():
    if request.method not in _UNSAFE_METHODS:
        return None
    origin = request.headers.get('Origin')
    if origin is not None and not _origin_allowed(origin):
        return _csrf_failure('cross-site request')
    if origin is None and not _origin_allowed(request.headers.get('Referer')):
        return _csrf_failure('cross-site request')
    sent = request.headers.get('X-CSRF-Token', '')
    expected = session.get('csrf_token', '')
    if not expected or not sent or not hmac.compare_digest(sent, expected):
        return _csrf_failure('missing or stale security token')
    return None


@app.route('/api/csrf-token')
def api_csrf_token():
    """Fresh token for a page whose token went stale (e.g. the user signed in
    again in another tab). Readable only by same-origin scripts - no CORS."""
    return jsonify({'token': csrf_token()})


@app.before_request
def reject_query_operators():
    """No legitimate payload carries a key starting with '$'. Refusing them
    everywhere closes NoSQL operator injection - {"$regex": ...} in place of a
    name - for every endpoint at once, including ones written later."""
    if request.method in ('POST', 'PUT', 'PATCH', 'DELETE') and request.is_json:
        data = request.get_json(silent=True)
        if data is not None and _has_operator_keys(data):
            return jsonify({'error': 'Invalid request'}), 400


@app.route('/api/media/<file_id>')
@login_required
def api_get_media(file_id):
    """Serve one stored media file.

    Immutable content addressed by id, so it is safe to cache hard. `private`
    because it is behind a session - a shared cache must not keep it.
    """
    try:
        oid = ObjectId(file_id)
    except Exception:
        return jsonify({'error': 'Bad media id'}), 400
    try:
        f = _gridfs().get(oid)
    except gridfs.NoFile:
        return jsonify({'error': 'Not found'}), 404

    # Media is only as visible as the tracker it belongs to. A file with no
    # recorded owner is refused rather than guessed at (fail closed).
    owner = (f.metadata or {}).get('tracker_id')
    if not owner or visible_tracker(owner, {'_id': 1}) is None:
        return jsonify({'error': 'Not found'}), 404

    # Re-checked at serve time as well, so media stored before the write-side
    # check existed is covered too.
    mime = safe_media_type(f.content_type)
    resp = app.response_class(f.read(), mimetype=mime)
    resp.headers['Cache-Control'] = 'private, max-age=31536000, immutable'
    resp.headers['Content-Length'] = str(f.length)
    resp.headers['X-Content-Type-Options'] = 'nosniff'
    resp.headers['Content-Security-Policy'] = "default-src 'none'; sandbox"
    if mime == 'application/octet-stream':
        resp.headers['Content-Disposition'] = f'attachment; filename="media-{file_id}"'
    return resp


def offload_image_field(data_url, kind, tracker_id=None):
    """Data URL -> GridFS reference, falling back to inline on failure.

    Returning the inline shape on failure means a storage hiccup degrades to the
    old behaviour rather than losing the engineer's photo.
    """
    stored = store_data_url(data_url, tracker_id=tracker_id, kind=kind)
    return stored if stored else {'data': data_url}


def offload_site_images(images, tracker_id=None):
    """Offload a site_verification.images list, preserving gps/type/captured_at."""
    out = []
    for img in images or []:
        if not isinstance(img, dict):
            continue
        entry = {k: v for k, v in img.items() if k != 'data'}
        if img.get('data'):
            entry.update(offload_image_field(img['data'], 'site_verification', tracker_id))
        out.append(entry)
    return out


def is_chat_unlocked(tracker):
    """Chat unlocks when the tracker enters the FE-NS coordination phase.
    This happens via multiple paths:
    1. NS clicked 'Mark Ready for Coordination' (normal happy path).
    2. FE clicked 'Request NS to do ZTP' (legacy flow).
    3. FE clicked 'Request NOC to Perform ZTP Pull' (new 2-phase flow).
    4. HSO submitted/rejected — chat stays open for discussion.
    5. Installation complete — chat available for post-completion review."""
    return tracker.get('status') in CHAT_UNLOCKED_STATUSES


# ─── Page Routes ────────────────────────────────────────────────────────────
@app.route('/')
def index():
    if 'user_id' in session:
        role = session.get('role')
        if role in FE_ROLES:
            return redirect(url_for('fe_dashboard'))
        elif role in NOC_ROLES:
            return redirect(url_for('noc_dashboard'))
        elif role == ROLE_ANALYTICS:
            return redirect(url_for('analytics_dashboard'))
    return redirect(url_for('login'))


@app.route('/login')
def login():
    return render_template('login.html')


@app.route('/fe/dashboard')
@login_required
def fe_dashboard():
    if session.get('role') not in FE_ROLES:
        return redirect(url_for('index'))
    return render_template('fe_dashboard.html', theme=get_theme_for_role(session.get('role')))


@app.route('/fe/new-installation')
@login_required
def fe_new_installation():
    if session.get('role') != ROLE_FE:
        return redirect(url_for('fe_dashboard'))
    return render_template('fe_new_installation.html', theme=get_theme_for_role(session.get('role')))


@app.route('/fe/tracker/<tracker_id>')
@login_required
def fe_tracker_detail(tracker_id):
    if session.get('role') not in FE_ROLES:
        return redirect(url_for('index'))
    tracker = visible_tracker(tracker_id, {'fe': 1})
    if not tracker:
        flash('Tracker not found', 'error')
        return redirect(url_for('fe_dashboard'))
    # Only the FE who created the tracker can take actions (FEG/FS/FSG are read-only viewers)
    can_interact = (tracker.get('fe', {}).get('id') == session['user_id'])
    return render_template('fe_tracker_detail.html',
                           tracker_id=tracker_id,
                           can_interact=can_interact,
                           theme=get_theme_for_role(session.get('role')))


@app.route('/noc/dashboard')
@login_required
def noc_dashboard():
    if session.get('role') not in NOC_ROLES:
        return redirect(url_for('index'))
    return render_template('noc_dashboard.html', theme=get_theme_for_role(session.get('role')))


@app.route('/noc/tracker/<tracker_id>')
@login_required
def noc_tracker_detail(tracker_id):
    if session.get('role') not in NOC_ROLES:
        return redirect(url_for('index'))
    if visible_tracker(tracker_id, {'_id': 1}) is None:
        return redirect(url_for('noc_dashboard'))
    return render_template('noc_tracker_detail.html',
                           tracker_id=tracker_id,
                           theme=get_theme_for_role(session.get('role')))


@app.route('/analytics/dashboard')
@login_required
def analytics_dashboard():
    if session.get('role') not in {ROLE_ANALYTICS, ROLE_NSG, ROLE_FSG}:
        return redirect(url_for('index'))
    return render_template('analytics_dashboard_v1.html')


# Legacy redirects so old bookmarks still work
@app.route('/franchise/dashboard')
@login_required
def franchise_dashboard():
    return redirect(url_for('fe_dashboard'))


@app.route('/field_support/dashboard')
@login_required
def field_support_dashboard():
    return redirect(url_for('fe_dashboard'))


@app.route('/field_support_admin/dashboard')
@login_required
def field_support_admin_dashboard():
    return redirect(url_for('fe_dashboard'))


# ─── Login / Logout API ─────────────────────────────────────────────────────
@app.route('/api/login/field-support-groups', methods=['GET'])
def api_get_field_support_groups():
    # Query users collection for FIELD_SUPPORT_GROUP role
    groups = list(mongo.db.users.find(
        {'role': ROLE_FSG},
        {'_id': 0, 'username': 1, 'name': 1, 'zone': 1, 'role': 1}
    ))
    return jsonify(groups)


@app.route('/api/login/field-supports', methods=['GET'])
def api_get_field_supports():
    # Query users collection for FIELD_SUPPORT role only (FSG is fetched separately)
    supports = list(mongo.db.users.find(
        {'role': ROLE_FS},
        {'_id': 0, 'username': 1, 'name': 1, 'region': 1, 'role': 1}
    ))
    return jsonify(supports)


@app.route('/api/login/field-engineer-groups', methods=['GET'])
def api_get_field_engineer_groups():
    # Query users collection for FIELD_ENGINEER_GROUP role
    groups = list(mongo.db.users.find(
        {'role': ROLE_FEG},
        {'_id': 0, 'username': 1, 'name': 1, 'region': 1, 'role': 1}
    ))
    return jsonify(groups)


@app.route('/api/login/field-engineers', methods=['GET'])
def api_get_field_engineers():
    feg_name = request.args.get('field_engineer_group')
    query = {'role': ROLE_FE}
    if feg_name:
        query['field_engineer_group'] = feg_name
    engineers = list(mongo.db.users.find(
        query,
        {'_id': 0, 'username': 1, 'name': 1, 'field_engineer_group': 1, 'region': 1, 'location': 1, 'role': 1}
    ))
    return jsonify(engineers)


@app.route('/api/login/noc-supports', methods=['GET'])
def api_get_noc_supports():
    noc_users = list(mongo.db.users.find(
        {'role': {'$in': [ROLE_NS, ROLE_NSG]}},
        {'_id': 0, 'username': 1, 'name': 1, 'role': 1}
    ))
    return jsonify(noc_users)


# ─── Get NOC Users for Reassignment ─────────────────────────────────────────
@app.route('/api/noc-users', methods=['GET'])
@login_required
def api_get_noc_users_for_reassignment():
    if session.get('role') != ROLE_NS:
        return jsonify({'error': 'Unauthorized'}), 403
    
    # Get all NOC users except current user
    noc_users = list(mongo.db.users.find(
        {
            'role': ROLE_NS,
            '_id': {'$ne': ObjectId(session['user_id'])}
        },
        {'_id': 1, 'username': 1, 'name': 1}
    ))
    
    # Convert ObjectId to string
    for user in noc_users:
        user['_id'] = str(user['_id'])
    
    return jsonify({'noc_users': noc_users})


_LOGIN_FIELDS = {
    ROLE_FE:        (('name', 'fe_name'), ('field_engineer_group', 'fe_group')),
    ROLE_FEG:       (('name', 'feg_name'),),
    ROLE_FS:        (('name', 'fs_name'),),
    ROLE_FSG:       (('name', 'fsg_name'),),
    ROLE_NS:        (('username', 'noc_username'),),
    ROLE_NSG:       (('username', 'noc_username'),),
    ROLE_ANALYTICS: (('username', 'username'),),
}


@app.route('/api/auth/login', methods=['POST'])
def api_login():
    data = request.get_json(silent=True) or {}
    role = data.get('role')
    password = data.get('password')
    if role not in _LOGIN_FIELDS:
        return jsonify({'success': False, 'message': 'Invalid role'}), 400

    # Only non-empty strings reach the query. An object such as {"$regex": "^Dev"}
    # used to be spliced straight into find_one() - NoSQL operator injection.
    query = {'role': role}
    for field, param in _LOGIN_FIELDS[role]:
        value = data.get(param, 'analytics' if param == 'username' else None)
        if not isinstance(value, str) or not value.strip() or len(value) > 200:
            return jsonify({'success': False, 'message': 'Invalid credentials'}), 400
        query[field] = value
    if not isinstance(password, str) or not password or len(password) > 200:
        return jsonify({'success': False, 'message': 'Invalid credentials'}), 400

    account_key = role + ':' + '|'.join(str(query[f]) for f, _ in _LOGIN_FIELDS[role])
    wait = login_lockout_seconds(account_key)
    if wait > 0:
        return throttled_response(wait)

    user = mongo.db.users.find_one(query)
    password_ok = check_password_hash(user.get('password') or _DUMMY_PASSWORD_HASH if user
                                      else _DUMMY_PASSWORD_HASH, password)
    if not user or not password_ok or user.get('active') is False:
        record_login_failure(account_key)
        return jsonify({'success': False, 'message': 'Invalid credentials'}), 401

    clear_login_failures(account_key)
    # A fresh session per login: nothing from a previous identity (an admin
    # flag, a CSRF token) carries over.
    session.clear()
    session.permanent = True
    session['epoch'] = user.get('session_epoch', 0)
    session['user_id'] = str(user['_id'])
    session['username'] = user.get('username', user.get('name'))
    session['role'] = role
    session['name'] = user.get('name', user.get('username'))

    if role == ROLE_FE:
        session['field_engineer_group'] = user.get('field_engineer_group')
        session['field_support'] = user.get('field_support')
        session['region'] = user.get('region')
        session['zone'] = user.get('zone')
        session['email'] = user.get('email')
        session['contact'] = user.get('contact')
        session['location'] = user.get('location')
    elif role == ROLE_FEG:
        session['field_engineer_group'] = user.get('name')
        session['field_support'] = user.get('field_support')
        session['state'] = user.get('state')
        session['region'] = user.get('region')
        session['zone'] = user.get('zone')
    elif role == ROLE_FS:
        session['field_support'] = user.get('name')
        session['region'] = user.get('region')
        session['field_support_group'] = user.get('field_support_group')
        session['zone'] = user.get('zone')
    elif role == ROLE_FSG:
        session['field_support_group'] = user.get('name')
        session['zone'] = user.get('zone')
    elif role in NOC_ROLES:
        session['noc_name'] = user.get('name', user.get('username'))

    return jsonify({'success': True, 'role': role})


@app.route('/api/auth/logout', methods=['POST'])
def api_logout():
    session.clear()
    return jsonify({'success': True})


# ─── Tracker Query APIs ─────────────────────────────────────────────────────
@app.route('/api/trackers/check/<sdwan_id>')
@login_required
def api_check_sdwan_id(sdwan_id):
    """Is this SDWAN ID taken? It used to return the ENTIRE tracker to any
    logged-in user; SDWAN IDs are easy to enumerate. The id is included only
    when the caller may open that tracker."""
    tracker = mongo.db.trackers.find_one({'sdwan_id': sdwan_id}, {'_id': 1})
    if not tracker:
        return jsonify({'exists': False})
    out = {'exists': True}
    if visible_tracker(tracker['_id'], {'_id': 1}):
        out['tracker_id'] = str(tracker['_id'])
    return jsonify(out)


def resolve_tracker_media(tracker):
    """Rewrite every stored image reference into a URL the client can use.

    Handles both shapes - a GridFS reference becomes /api/media/<id>, a legacy
    inline data URL is passed through unchanged - so the frontend has exactly one
    thing to render (`data`) regardless of when the tracker was created.
    """
    def fix_list(images):
        for img in images or []:
            if isinstance(img, dict):
                ref = serialize_media_ref(img)
                if ref:
                    img['data'] = ref['url']
                    img['inline'] = ref.get('inline', False)
        return images

    fix_list((tracker.get('site_verification') or {}).get('images'))
    for key in ('sim1', 'sim2'):
        fix_list(((tracker.get('sim') or {}).get(key) or {}).get('images'))
    fix_list((tracker.get('firmware') or {}).get('images'))
    fix_list((tracker.get('router') or {}).get('images'))
    return tracker


@app.route('/api/trackers/<tracker_id>')
@login_required
def api_get_tracker(tracker_id):
    tracker = visible_tracker(tracker_id)
    if not tracker:
        return jsonify({'error': 'Tracker not found'}), 404

    can_interact = True
    if session.get('role') == ROLE_FE:
        can_interact = (tracker.get('fe', {}).get('id') == session['user_id'])

    return jsonify({
        'tracker': resolve_tracker_media(serialize_doc(tracker)),
        'can_interact': can_interact,
    })


# ─── Tracker list plumbing ───────────────────────────────────────────────────
# Dashboards render IDs, statuses and timers - never embedded photos or the event
# timeline. Without this projection every list response carried the full base64
# payload of every photo in the result set (69% of tracker bytes; see
# PROJECT_GUIDE section 15.2). Detail views fetch the whole document separately.
TRACKER_LIST_PROJECTION = {
    'site_verification.images': 0,
    'sim.sim1.images': 0,
    'sim.sim2.images': 0,
    'firmware.images': 0,
    'router.images': 0,
    'events': 0,
}

# Analytics reads pull whole documents into Python and iterate. Most of them never
# look at events[], which is the bulk of a document now that media lives in GridFS.
# Excluding it keeps these endpoints from scaling with timeline length as well as
# tracker count. Endpoints that DO read events (fe/day, noc/user/day) intentionally
# omit this projection.
ANALYTICS_PROJECTION = {'events': 0}

DEFAULT_PAGE_SIZE = 50
MAX_PAGE_SIZE     = 200


# ─── Dashboard buckets ───────────────────────────────────────────────────────
# Each dashboard tab is a named bucket. These used to be predicates evaluated in
# the browser over the entire tracker list; they now run in Mongo so the
# dashboards can fetch one page at a time. The rules are transcribed from the
# client code they replace and are DIFFERENT per side - keep them that way:
#
#   FE  unassigned  status == waiting_noc_assignment
#       ongoing     status not in (waiting, installation_complete, completed)
#       completed   status in (installation_complete, completed), dated by completed_at
#       me          fe.id == current user
#   NOC unassigned  no noc_assignee AND status != installation_complete
#       ongoing     has noc_assignee AND status != installation_complete
#       completed   status == installation_complete, dated by completed_at
#       me          noc_assignee == current user
#
# Date ranges: the client's isInDateRange() rejects a missing date for every role
# except FIELD_ENGINEER, which is exempt from date filtering entirely. range_bounds()
# reproduces both halves of that.
FE_DONE_STATES = [STATUS_COMPLETE, 'completed']
FE_BUCKETS  = ('unassigned-me', 'unassigned-overall', 'ongoing-me',
               'ongoing-overall', 'completed-me', 'completed-overall')
NOC_BUCKETS = ('unassigned', 'ongoing-me', 'ongoing-overall',
               'completed-me', 'completed-overall')


def dashboard_side():
    return 'noc' if session.get('role') in NOC_ROLES else 'fe'


def range_bounds():
    """(from, to) naive-UTC datetimes from ?from=&to=, or (None, None) if unfiltered."""
    if session.get('role') == ROLE_FE:
        return None, None                      # FE is exempt, as in isInDateRange()

    def parse(param):
        raw = request.args.get(param)
        if not raw:
            return None
        try:
            return datetime.fromisoformat(raw.replace('Z', '')[:26])
        except ValueError:
            return None
    return parse('from'), parse('to')


def _dated(field, frm, to):
    if frm is None and to is None:
        return {}
    cond = {}
    if frm is not None:
        cond['$gte'] = frm
    if to is not None:
        cond['$lte'] = to
    return {field: cond}


def bucket_query(name, frm=None, to=None):
    """Mongo filter for one dashboard bucket, or None if the name is unknown."""
    uid = session.get('user_id')
    if dashboard_side() == 'fe':
        mine = {'fe.id': uid}
        rules = {
            'unassigned': ({'status': STATUS_WAITING_NOC}, 'created_at'),
            'ongoing':    ({'status': {'$nin': FE_DONE_STATES + [STATUS_WAITING_NOC]}}, 'created_at'),
            'completed':  ({'status': {'$in': FE_DONE_STATES}}, 'completed_at'),
        }
        valid = FE_BUCKETS
    else:
        mine = {'noc_assignee': uid}
        rules = {
            'unassigned': ({'noc_assignee': {'$in': [None, '']},
                            'status': {'$ne': STATUS_COMPLETE}}, 'created_at'),
            'ongoing':    ({'noc_assignee': {'$nin': [None, '']},
                            'status': {'$ne': STATUS_COMPLETE}}, 'created_at'),
            'completed':  ({'status': STATUS_COMPLETE}, 'completed_at'),
        }
        valid = NOC_BUCKETS
    if name not in valid:
        return None
    kind, _, who = name.partition('-')
    base, date_field = rules[kind]
    q = dict(base)
    if who == 'me':
        # `mine` may set noc_assignee, which must win over the "has an assignee"
        # condition of the ongoing rule.
        q.update(mine)
    q.update(_dated(date_field, frm, to))
    return q


def dashboard_scope():
    """Everything the current user may see on their dashboard, or None."""
    if dashboard_side() == 'noc':
        return {}
    return fe_visibility_query()


# ─── Per-tracker authorization ───────────────────────────────────────────────
# Every read of a single tracker - the detail API and pages, its chat, its media -
# goes through visible_tracker(), which applies the SAME scope as the caller's
# dashboard. Before this, any logged-in user could read any tracker, its chat and
# its photos just by knowing or guessing an id.
def visibility_scope():
    """Trackers the current user may READ: their dashboard scope, plus the
    org-wide read-only Analytics role. None means nothing."""
    if session.get('role') == ROLE_ANALYTICS:
        return {}
    return dashboard_scope()


def parse_oid(value):
    try:
        return ObjectId(value)
    except (InvalidId, TypeError):
        return None


def visible_tracker(tracker_id, projection=None):
    """The tracker if the current user may see it, otherwise None.

    Callers answer 404 rather than 403 either way, so a probe cannot use the
    status code to learn which ids exist.
    """
    oid = parse_oid(tracker_id)
    scope = visibility_scope()
    if oid is None or scope is None:
        return None
    query = {'$and': [{'_id': oid}, scope]} if scope else {'_id': oid}
    return mongo.db.trackers.find_one(query, projection)


def can_write_chat(tracker):
    """Only the participants may post to (or mark read in) a tracker's chat:
    the owning FE, the assigned NS, and NOC Support Group supervising. FE-side
    supervisors and Analytics can read but never write - the UI already hid
    the input for them, but the API accepted their posts."""
    role, uid = session.get('role'), session.get('user_id')
    if role == ROLE_FE:
        return (tracker.get('fe') or {}).get('id') == uid
    if role == ROLE_NS:
        return tracker.get('noc_assignee') == uid
    return role == ROLE_NSG


def link_media_to_tracker(tracker):
    """Record the owning tracker on media stored before the tracker existed
    (photos offloaded during creation), so /api/media can authorize it."""
    ids = []
    for images in ((tracker.get('site_verification') or {}).get('images'),
                   ((tracker.get('sim') or {}).get('sim1') or {}).get('images'),
                   ((tracker.get('sim') or {}).get('sim2') or {}).get('images'),
                   (tracker.get('firmware') or {}).get('images'),
                   (tracker.get('router') or {}).get('images')):
        for img in images or []:
            oid = parse_oid((img or {}).get('file_id'))
            if oid:
                ids.append(oid)
    if ids:
        mongo.db['media.files'].update_many(
            {'_id': {'$in': ids}}, {'$set': {'metadata.tracker_id': str(tracker['_id'])}})


def fe_visibility_query():
    """Mongo filter for what the current FE-side user may see.

    Single source of truth so the list, the counts and pagination can never
    disagree. Returns None when the role has no FE-side visibility at all.
    """
    role = session.get('role')
    if role == ROLE_FE:
        return {'fe.id': session['user_id']}
    if role == ROLE_FEG:
        return {'fe.field_engineer_group': session.get('field_engineer_group')}
    if role == ROLE_FS:
        # FS sees every FEG sitting under them.
        fegs = mongo.db.users.find({'role': ROLE_FEG, 'field_support': session.get('field_support')},
                                   {'name': 1})
        names = [f['name'] for f in fegs if 'name' in f]
        return {'fe.field_engineer_group': {'$in': names}} if names else None
    if role == ROLE_FSG:
        return {}
    return None


def paginate_args():
    """(skip, limit) from ?page=&limit=, clamped. limit=0 means 'everything'."""
    try:
        page = max(1, int(request.args.get('page', 1)))
    except ValueError:
        page = 1
    raw = request.args.get('limit')
    if raw is None:
        limit = DEFAULT_PAGE_SIZE
    else:
        try:
            limit = int(raw)
        except ValueError:
            limit = DEFAULT_PAGE_SIZE
        limit = 0 if limit <= 0 else min(limit, MAX_PAGE_SIZE)
    return (page - 1) * limit, limit


def tracker_page(query, sort_dir=-1):
    """Projected, sorted, paginated tracker list + the total for that query.

    ?filter=<bucket> narrows to one dashboard tab (see bucket_query), with
    ?from=&to= applied the way the tab's date field requires.
    """
    name = request.args.get('filter')
    if name:
        frm, to = range_bounds()
        bq = bucket_query(name, frm, to)
        if bq is None:
            return {'trackers': [], 'total': 0, 'returned': 0, 'has_more': False,
                    'error': f'unknown filter {name!r}'}
        query = {'$and': [query, bq]} if query else bq
    skip, limit = paginate_args()
    cursor = mongo.db.trackers.find(query, TRACKER_LIST_PROJECTION).sort('created_at', sort_dir)
    if limit:
        cursor = cursor.skip(skip).limit(limit)
    trackers = list(cursor)
    total = mongo.db.trackers.count_documents(query)
    return {
        'trackers': serialize_doc(trackers),
        'total': total,
        'returned': len(trackers),
        'has_more': bool(limit) and (skip + len(trackers)) < total,
    }


@app.route('/api/trackers/all-fe')
@login_required
def api_all_fe():
    """Trackers visible to the current FE-side user, by hierarchy."""
    query = fe_visibility_query()
    if query is None:
        return jsonify({'trackers': [], 'total': 0, 'returned': 0, 'has_more': False})
    return jsonify(tracker_page(query))


@app.route('/api/trackers/all-noc')
@login_required
def api_all_noc_trackers():
    if session.get('role') not in NOC_ROLES:
        return jsonify({'error': 'Unauthorized'}), 403
    return jsonify(tracker_page({}))


@app.route('/api/trackers/unassigned')
@login_required
def api_unassigned_trackers():
    if session.get('role') != ROLE_NS:
        return jsonify({'error': 'Unauthorized'}), 403
    return jsonify(tracker_page({'noc_assignee': None, 'status': STATUS_WAITING_NOC},
                                sort_dir=1))


@app.route('/api/trackers/my-installations')
@login_required
def api_my_installations():
    role = session.get('role')
    if role == ROLE_FE:
        query = {'fe.id': session['user_id']}
    elif role == ROLE_NS:
        query = {'noc_assignee': session['user_id']}
    else:
        return jsonify({'trackers': [], 'total': 0, 'returned': 0, 'has_more': False})
    return jsonify(tracker_page(query))


@app.route('/api/trackers/counts')
@login_required
def api_tracker_counts():
    """Badge counts for every tab on the caller's dashboard, in one $facet pass.

    Response: {buckets: {<tab name>: n}, avg_completion_ms: {overall, me},
               by_status: {...}, total}

    Tab names match the client filter ids exactly, and the rules differ between
    the FE and NOC dashboards - see bucket_query(). Average completion is taken
    over completed trackers that carry both timestamps, dated by completed_at,
    which is what the old client-side updateStats() computed.
    """
    scope = dashboard_scope()
    if scope is None:
        return jsonify({'buckets': {}, 'avg_completion_ms': {}, 'by_status': {}, 'total': 0})

    frm, to = range_bounds()
    names = NOC_BUCKETS if dashboard_side() == 'noc' else FE_BUCKETS
    facet = {name: [{'$match': bucket_query(name, frm, to)}, {'$count': 'n'}] for name in names}

    for who in ('overall', 'me'):
        q = bucket_query('completed-' + who, frm, to)
        q = {'$and': [q, {'created_at': {'$ne': None}, 'completed_at': {'$ne': None}}]}
        facet['avg_' + who] = [
            {'$match': q},
            {'$group': {'_id': None, 'ms': {'$avg': {'$subtract': ['$completed_at', '$created_at']}}}},
        ]
    facet['by_status'] = [{'$group': {'_id': '$status', 'n': {'$sum': 1}}}]

    row = next(iter(mongo.db.trackers.aggregate([{'$match': scope}, {'$facet': facet}])), {})
    buckets = {name: (row.get(name) or [{}])[0].get('n', 0) for name in names}
    avg = {who: ((row.get('avg_' + who) or [{}])[0].get('ms')) for who in ('overall', 'me')}
    by_status = {r['_id']: r['n'] for r in row.get('by_status', [])}
    return jsonify({'buckets': buckets, 'avg_completion_ms': avg,
                    'by_status': by_status, 'total': sum(by_status.values())})


# Fields the dashboard search covers: (label, dotted path). The old client search
# also looked at sim1_number, sim2_number, device_serial and noc_assignee_username
# - none of which exist on any tracker, so SIM search never matched anything. The
# real SIM numbers live under sim.simN.number; the NOC engineer is matched by
# name through the users collection below.
SEARCH_FIELDS = [
    ('SDWAN ID',    'sdwan_id'),
    ('Customer',    'customer'),
    ('FE Name',     'fe.name'),
    ('FE Username', 'fe.username'),
    ('FE Phone',    'fe.phone'),
    ('SIM1 Number', 'sim.sim1.number'),
    ('SIM2 Number', 'sim.sim2.number'),
    ('Tracker ID',  'tracker_id'),
]
SEARCH_LIMIT = 100


def _dig(doc, path):
    for part in path.split('.'):
        if not isinstance(doc, dict):
            return None
        doc = doc.get(part)
    return doc


@app.route('/api/trackers/search')
@login_required
def api_tracker_search():
    """Case-insensitive substring search across the caller's visible trackers.

    The query is escaped: it is a literal substring, never a regex. The NOC
    dashboard used to compile user input straight into a RegExp; doing that on
    the server would let anyone who can log in submit a catastrophic pattern.
    """
    term = (request.args.get('q') or '').strip()
    if not term:
        return jsonify({'results': [], 'total': 0, 'truncated': False})
    if len(term) > 100:
        return jsonify({'error': 'Search term too long'}), 400

    scope = dashboard_scope()
    if scope is None:
        return jsonify({'results': [], 'total': 0, 'truncated': False})

    literal = re.escape(term)
    pattern = re.compile(literal, re.IGNORECASE)
    ors = [{path: {'$regex': literal, '$options': 'i'}} for _, path in SEARCH_FIELDS]

    noc_names = {}
    for u in mongo.db.users.find({'role': {'$in': list(NOC_ROLES)},
                                  '$or': [{'name': {'$regex': literal, '$options': 'i'}},
                                          {'username': {'$regex': literal, '$options': 'i'}}]},
                                 {'name': 1, 'username': 1}):
        noc_names[str(u['_id'])] = u.get('name') or u.get('username')
    if noc_names:
        ors.append({'noc_assignee': {'$in': list(noc_names)}})

    query = {'$and': [scope, {'$or': ors}]} if scope else {'$or': ors}
    total = mongo.db.trackers.count_documents(query)
    docs = list(mongo.db.trackers.find(query, TRACKER_LIST_PROJECTION)
                                 .sort('created_at', -1).limit(SEARCH_LIMIT))

    results = []
    for d in serialize_doc(docs):
        matches = []
        for label, path in SEARCH_FIELDS:
            v = _dig(d, path)
            if v is not None and pattern.search(str(v)):
                matches.append({'field': label, 'value': str(v)})
        if d.get('noc_assignee') in noc_names:
            matches.append({'field': 'NOC Engineer', 'value': noc_names[d['noc_assignee']]})
        results.append({'tracker': d, 'matches': matches})

    return jsonify({'results': results, 'total': total, 'truncated': total > len(results)})


@app.route('/api/noc/users/stats')
@login_required
def api_noc_users_stats():
    if session.get('role') != ROLE_NSG:
        return jsonify({'error': 'Unauthorized'}), 403
    noc_users = list(mongo.db.users.find({'role': ROLE_NS}, {'name': 1, 'username': 1}))

    # One pass over the index instead of 2 x N count_documents() round trips.
    tallies = {}
    for row in mongo.db.trackers.aggregate([
        {'$match': {'noc_assignee': {'$ne': None}}},
        {'$group': {'_id': {'assignee': '$noc_assignee',
                            'done': {'$eq': ['$status', STATUS_COMPLETE]}},
                    'n': {'$sum': 1}}},
    ]):
        key = row['_id']['assignee']
        bucket = tallies.setdefault(key, {'ongoing': 0, 'completed': 0})
        bucket['completed' if row['_id']['done'] else 'ongoing'] += row['n']

    users_stats = []
    for user in noc_users:
        user_id = str(user['_id'])
        t = tallies.get(user_id, {'ongoing': 0, 'completed': 0})
        users_stats.append({
            'id': user_id,
            'name': user.get('name', 'N/A'),
            'username': user.get('username', 'N/A'),
            'ongoing_count': t['ongoing'],
            'completed_count': t['completed'],
            'total_count': t['ongoing'] + t['completed'],
        })
    return jsonify({'users': users_stats})


@app.route('/api/hierarchy/view')
@login_required
def api_hierarchy_view():
    role = session.get('role')
    
    # Get date range parameters (optional)
    date_from = request.args.get('date_from')
    date_to = request.args.get('date_to')
    
    # Build date filters if provided
    created_date_filter = {}
    completed_date_filter = {}
    if date_from and date_to:
        try:
            from_dt = datetime.fromisoformat(date_from.replace('Z', ''))
            to_dt = datetime.fromisoformat(date_to.replace('Z', ''))
            created_date_filter = {'created_at': {'$gte': from_dt, '$lte': to_dt}}
            completed_date_filter = {'completed_at': {'$gte': from_dt, '$lte': to_dt}}
        except:
            pass  # If date parsing fails, ignore date filter

    if role == ROLE_FEG:
        feg = session.get('field_engineer_group')
        fes = list(mongo.db.users.find({'role': ROLE_FE, 'field_engineer_group': feg}))
        data = []
        for fe in fes:
            fe_id = str(fe['_id'])
            base_filter = {'fe.id': fe_id}

            pending = mongo.db.trackers.count_documents({**base_filter, 'status': 'waiting_noc_assignment', **created_date_filter})
            ongoing = mongo.db.trackers.count_documents({**base_filter, 'status': {'$nin': ['waiting_noc_assignment', 'installation_complete']}, **created_date_filter})
            done    = mongo.db.trackers.count_documents({**base_filter, 'status': 'installation_complete', **completed_date_filter})
            total   = pending + ongoing + done
            
            data.append({
                'id': fe_id, 
                'name': fe.get('name'), 
                'phone': fe.get('contact'),  # Use 'contact' field from user document
                'email': fe.get('email'),
                'location': fe.get('location'),  # State/location
                'field_support': session.get('field_support'),
                'total_count': total, 
                'unassigned_count': pending, 
                'ongoing_count': ongoing, 
                'completed_count': done
            })
        return jsonify({'type': 'field_engineers', 'data': data, 'total_count': len(data)})

    elif role == ROLE_FS:
        fs = session.get('field_support')
        fegs = list(mongo.db.users.find({'role': ROLE_FEG, 'field_support': fs}))
        data = []
        for feg in fegs:
            feg_name = feg.get('name')
            base_filter = {'fe.field_engineer_group': feg_name}

            pending = mongo.db.trackers.count_documents({**base_filter, 'status': 'waiting_noc_assignment', **created_date_filter})
            ongoing = mongo.db.trackers.count_documents({**base_filter, 'status': {'$nin': ['waiting_noc_assignment', 'installation_complete']}, **created_date_filter})
            done    = mongo.db.trackers.count_documents({**base_filter, 'status': 'installation_complete', **completed_date_filter})
            total   = pending + ongoing + done
            
            fe_count = mongo.db.users.count_documents({'role': ROLE_FE, 'field_engineer_group': feg_name})
            data.append({
                'id': str(feg['_id']), 
                'name': feg_name, 
                'region': feg.get('region'),  # Add region field
                'fe_count': fe_count,
                'total_count': total, 
                'unassigned_count': pending, 
                'ongoing_count': ongoing, 
                'completed_count': done
            })
        return jsonify({'type': 'field_engineer_groups', 'data': data, 'total_count': len(data)})

    elif role == ROLE_FSG:
        fss = list(mongo.db.users.find({'role': ROLE_FS}))
        data = []
        for fs in fss:
            fs_name = fs.get('name')
            
            # Get all FEGs under this FS
            fegs_under_fs = list(mongo.db.users.find({'role': ROLE_FEG, 'field_support': fs_name}))
            feg_names = [feg.get('name') for feg in fegs_under_fs]
            
            if feg_names:
                # Build base filter with FEG names
                base_filter = {'fe.field_engineer_group': {'$in': feg_names}}

                pending = mongo.db.trackers.count_documents({**base_filter, 'status': 'waiting_noc_assignment', **created_date_filter})
                ongoing = mongo.db.trackers.count_documents({**base_filter, 'status': {'$nin': ['waiting_noc_assignment', 'installation_complete']}, **created_date_filter})
                done    = mongo.db.trackers.count_documents({**base_filter, 'status': 'installation_complete', **completed_date_filter})
                total   = pending + ongoing + done

                fe_count = mongo.db.users.count_documents({'role': ROLE_FE, 'field_engineer_group': {'$in': feg_names}})
            else:
                total = pending = ongoing = done = fe_count = 0
            
            feg_count = len(feg_names)
            
            data.append({'id': str(fs['_id']), 'name': fs_name, 'feg_count': feg_count, 'fe_count': fe_count,
                         'total_count': total, 'unassigned_count': pending, 'ongoing_count': ongoing, 'completed_count': done})
        return jsonify({'type': 'field_supports', 'data': data, 'total_count': len(data)})

    return jsonify({'error': 'Unauthorized'}), 403


@app.route('/api/hierarchy/drill-down')
@login_required
def api_hierarchy_drill_down():
    """Drill-down API for hierarchical views - returns FEGs under an FS, or FEs under a FEG"""
    role = session.get('role')
    
    # Get drill-down parameters
    fs_name = request.args.get('fs_name')
    feg_name = request.args.get('feg_name')
    
    # Get date range parameters (optional)
    date_from = request.args.get('date_from')
    date_to = request.args.get('date_to')
    
    # Build date filters if provided
    created_date_filter = {}
    completed_date_filter = {}
    if date_from and date_to:
        try:
            from_dt = datetime.fromisoformat(date_from.replace('Z', ''))
            to_dt = datetime.fromisoformat(date_to.replace('Z', ''))
            created_date_filter = {'created_at': {'$gte': from_dt, '$lte': to_dt}}
            completed_date_filter = {'completed_at': {'$gte': from_dt, '$lte': to_dt}}
        except:
            pass  # If date parsing fails, ignore date filter
    
    # FSG can drill down to FEGs under an FS
    if role == ROLE_FSG and fs_name:
        fegs = list(mongo.db.users.find({'role': ROLE_FEG, 'field_support': fs_name}))
        data = []
        for feg in fegs:
            feg_name_val = feg.get('name')
            base_filter = {'fe.field_engineer_group': feg_name_val}

            pending = mongo.db.trackers.count_documents({**base_filter, 'status': 'waiting_noc_assignment', **created_date_filter})
            ongoing = mongo.db.trackers.count_documents({**base_filter, 'status': {'$nin': ['waiting_noc_assignment', 'installation_complete']}, **created_date_filter})
            done    = mongo.db.trackers.count_documents({**base_filter, 'status': 'installation_complete', **completed_date_filter})
            total   = pending + ongoing + done
            
            fe_count = mongo.db.users.count_documents({'role': ROLE_FE, 'field_engineer_group': feg_name_val})
            data.append({
                'id': str(feg['_id']), 
                'name': feg_name_val, 
                'phone': feg.get('phone'),
                'email': feg.get('email'),
                'region': feg.get('region'),
                'field_support': feg.get('field_support'),
                'fe_count': fe_count,
                'total_count': total, 
                'unassigned_count': pending, 
                'ongoing_count': ongoing, 
                'completed_count': done
            })
        return jsonify({'success': True, 'type': 'field_engineer_groups', 'data': data, 'total_count': len(data)})
    
    # FSG or FS can drill down to FEs under a FEG - an FS only under their own.
    # Without this an FS could list any region's engineers with their contact details.
    if role == ROLE_FS and feg_name and not mongo.db.users.count_documents(
            {'role': ROLE_FEG, 'name': feg_name, 'field_support': session.get('field_support')}):
        return jsonify({'error': 'Not in your region'}), 403

    if (role == ROLE_FSG or role == ROLE_FS) and feg_name:
        fes = list(mongo.db.users.find({'role': ROLE_FE, 'field_engineer_group': feg_name}))
        data = []
        for fe in fes:
            fe_username = fe.get('username')
            # Match trackers by username (stable; stored on every tracker from session['username'])
            base_filter = {'fe.username': fe_username}

            pending = mongo.db.trackers.count_documents({**base_filter, 'status': 'waiting_noc_assignment', **created_date_filter})
            ongoing = mongo.db.trackers.count_documents({**base_filter, 'status': {'$nin': ['waiting_noc_assignment', 'installation_complete']}, **created_date_filter})
            done    = mongo.db.trackers.count_documents({**base_filter, 'status': 'installation_complete', **completed_date_filter})
            total   = pending + ongoing + done

            data.append({
                'id': str(fe['_id']),
                'name': fe.get('name'),
                'phone': fe.get('contact') or fe.get('phone'),
                'email': fe.get('email'),
                'region': fe.get('region'),
                'field_engineer_group': fe.get('field_engineer_group'),
                'total_count': total,
                'unassigned_count': pending,
                'ongoing_count': ongoing,
                'completed_count': done
            })
        return jsonify({'success': True, 'type': 'field_engineers', 'data': data, 'total_count': len(data)})
    
    return jsonify({'success': False, 'error': 'Invalid drill-down parameters'}), 400


# ─── Tracker Creation ───────────────────────────────────────────────────────
@app.route('/api/trackers', methods=['POST'])
@login_required
def api_create_tracker():
    if session.get('role') != ROLE_FE:
        return jsonify({'success': False, 'message': 'Only Field Engineers can create trackers'}), 403

    data = request.get_json(silent=True) or {}
    for field, limit in (('sdwan_id', 64), ('customer', 200), ('fe_phone', 32)):
        value = data.get(field)
        if not isinstance(value, str) or not value.strip() or len(value) > limit:
            return jsonify({'success': False, 'message': 'Invalid or missing %s' % field}), 400
    existing = mongo.db.trackers.find_one({'sdwan_id': data['sdwan_id']})
    if existing:
        return jsonify({'success': False, 'message': 'SDWAN ID already exists',
                        'tracker_id': str(existing['_id'])}), 409

    now = get_utc_now()
    captured_images = data.get('images', {})

    def build_sim(provider_key, number_key):
        provider = data.get(provider_key, '')
        number   = data.get(number_key, '')
        images   = [
            dict(field='provider', **offload_image_field(captured_images[provider_key], 'sim'))
            if captured_images.get(provider_key) else None,
            dict(field='number', **offload_image_field(captured_images[number_key], 'sim'))
            if captured_images.get(number_key) else None,
        ]
        return {
            'provider': provider,
            'number': number,
            'status': 'pending' if number else 'not_required',
            'images': [i for i in images if i],
            # Per-attempt history — each attempt adds an entry here so retries are traceable
            'attempts': [],
            'failure_reason': None,
            'root_cause_of_initial_failure': None,
            'activation_started_at': None,
        }

    tracker = {
        # ── Identity ──────────────────────────────────────────────────────
        'tracker_id': next_tracker_id(now.year),
        'sdwan_id': data['sdwan_id'],
        'customer': data['customer'],
        'site_name': data.get('site_name', ''),
        'site_address': data.get('site_address', ''),

        # ── Field Engineer ────────────────────────────────────────────────
        'fe': {
            'id': session['user_id'],
            'username': session['username'],
            'name': session.get('name', session['username']),
            'phone': data['fe_phone'],
            'email': session.get('email', ''),
            # Hierarchy codes for filtering at every FEG/FS/FSG level
            'field_engineer_group': session.get('field_engineer_group'),
            'field_support': session.get('field_support'),
            'region': session.get('region'),
            'zone': session.get('zone'),
            # History allows future multi-FE handoff without losing audit trail
            'history': [{'fe_name': session.get('name', session['username']), 'assigned_at': now, 'left_at': None}]
        },

        # ── NOC Assignment ────────────────────────────────────────────────
        # noc_assignee holds the CURRENT assignee user_id (string or None).
        # noc_history is the full audit log of who worked on this tracker.
        'noc_assignee': None,
        'noc_history': [],

        # ── SIM Data ──────────────────────────────────────────────────────
        'sim': {
            'sim1': build_sim('sim1_provider', 'sim1_number'),
            'sim2': build_sim('sim2_provider', 'sim2_number'),
        },

        # ── Router Details ────────────────────────────────────────────
        'router': {
            'type': data.get('router_type', ''),
            'make': data.get('router_make', ''),
            'firmware_version': data.get('router_firmware_version', ''),
            'images': [dict(field='firmware',
                            **offload_image_field(captured_images['router_firmware_version'], 'firmware'))]
                      if captured_images.get('router_firmware_version') else []
        },

        # ── Firmware + ZTP ────────────────────────────────────────────────
        'firmware': {
            'version': data.get('router_firmware_version', ''),
            'images': [dict(field='version',
                            **offload_image_field(captured_images['router_firmware_version'], 'firmware'))]
                      if captured_images.get('router_firmware_version') else []
        },
        'ztp': {
            # ztp_config_status: NS verifies that ZTP config is correct
            # values: pending → config_verified | config_failed
            'config_status': 'pending',
            'config_verified_at': None,
            'config_failure_reason': None,
            # ztp_execution: who runs ZTP and the result
            # values: pending → initiated → completed | failed
            # performed_by: 'FE' or 'NS'
            'status': 'pending',
            'performed_by': None,         # 'FE' or 'NS' — key for KPI "ZTP done by FE vs NS"
            'fe_requested_ns': False,     # True when FE cannot do ZTP and asks NS
            'initiated_at': None,
            'completed_at': None,
            'failure_reason': None,
            'root_cause_of_initial_failure': None,
            'attempts': [],               # [{performed_by, started_at, result, reason}]
        },

        # ── HSO ───────────────────────────────────────────────────────────
        # HSO tracks the hand-over sign-off cycle. FE submits, NS approves or rejects.
        # Multiple submit/reject cycles are captured in hso_attempts.
        'hso': {
            'status': 'pending',          # pending | submitted | rejected | approved
            'submitted_at': None,         # Set when FE clicks Submit HSO
            'approved_at': None,          # Set when NS approves
            'rejected_at': None,
            'rejection_reason': None,
            'attempts': [],               # [{submitted_at, action, actor, reason}]
        },

        # ── Site Verification ─────────────────────────────────────────────
        # FE captures 3 GPS-watermarked photos at site before creating tracker.
        # NOC confirms (FE present) or rejects (FE not at site) before assigning.
        # Rejected trackers require FE to resubmit new photos; rejection time is
        # excluded from NOC queue-wait KPI (queue wait = confirmed_at → assigned_at).
        'site_verification': {
            'status': 'pending',          # pending | confirmed | rejected
            # [{type, file_id|data, mime, size, gps:{lat,lng,address}, captured_at}]
            'images': offload_site_images(data.get('site_images', [])),
            'noc_reviewed_at': None,
            'noc_reviewed_by': None,
            'noc_reviewer_name': None,
            'rejection_reason': None,
            'rejection_count': 0,
            'last_submitted_at': now,
        },

        # ── Dedicated Stage Timestamps ────────────────────────────────────
        # These are set once (first occurrence) as the tracker progresses.
        # Having them as top-level indexed fields makes KPI aggregation fast
        # without scanning the events array on every analytics query.
        'stage_timestamps': {
            'tracker_created_at':                now,
            'site_verification_submitted_at':    now,
            'site_verification_confirmed_at':    None,
            'noc_assigned_at':                   None,
            'sim1_activation_started_at':        None,
            'sim1_activation_done_at':           None,
            'sim2_activation_started_at':        None,
            'sim2_activation_done_at':           None,
            'ztp_config_verified_at':            None,
            'ztp_started_at':                    None,
            'ztp_done_at':                       None,
            'ready_for_coordination_at':         None,
            'hso_submitted_at':                  None,
            'hso_approved_at':                   None,
            'installation_complete_at':          None,
        },

        # ── Event Log ─────────────────────────────────────────────────────
        # Append-only audit trail. Every action adds an event.
        'events': [make_event('tracker_created', session['user_id'], ROLE_FE,
                              'Installation tracker created at site')],

        # ── Status ────────────────────────────────────────────────────────
        'status': 'waiting_noc_assignment',
        'created_at': now,
        'updated_at': now,
        'completed_at': None,
    }

    try:
        result = mongo.db.trackers.insert_one(tracker)
    except DuplicateKeyError:
        # The pre-check above is check-then-insert, so two concurrent creates for
        # the same SDWAN ID both pass it. trackers_sdwan_id_unique is the real
        # guard; surface it as the same 409 rather than a 500.
        existing = mongo.db.trackers.find_one({'sdwan_id': data['sdwan_id']})
        return jsonify({'success': False, 'message': 'SDWAN ID already exists',
                        'tracker_id': str(existing['_id']) if existing else None}), 409
    tracker['_id'] = result.inserted_id
    link_media_to_tracker(tracker)
    
    # Broadcast new tracker creation to all dashboards
    broadcast_dashboard_update(ROLE_NS, 'tracker_created', {
        'tracker_id': str(result.inserted_id),
        'sdwan_id': data['sdwan_id'],
        'customer': data['customer'],
        'status': 'waiting_noc_assignment'
    })
    
    # Also broadcast to FE hierarchy roles
    for role in [ROLE_FE, ROLE_FEG, ROLE_FS, ROLE_FSG]:
        broadcast_dashboard_update(role, 'tracker_created', {
            'tracker_id': str(result.inserted_id),
            'fe_id': session['user_id']
        })
    
    return jsonify({'success': True, 'tracker': serialize_doc(tracker)})


# ─── NOC: Assign Tracker ────────────────────────────────────────────────────
@app.route('/api/trackers/<tracker_id>/assign', methods=['POST'])
@login_required
def api_assign_tracker(tracker_id):
    if session.get('role') != ROLE_NS:
        return jsonify({'error': 'Unauthorized'}), 403

    tracker = mongo.db.trackers.find_one({'_id': ObjectId(tracker_id)})
    if not tracker:
        return jsonify({'error': 'Tracker not found'}), 404

    # Guard: site verification must be confirmed before assignment
    sv = tracker.get('site_verification', {})
    if sv.get('status') != 'confirmed':
        return jsonify({'error': 'Site verification not confirmed. Confirm FE is at site before assigning.'}), 400

    now = get_utc_now()
    noc_name = session.get('noc_name', session['username'])

    mongo.db.trackers.update_one(
        {'_id': ObjectId(tracker_id)},
        {
            '$set': {
                'noc_assignee': session['user_id'],
                'status': 'noc_working',
                'stage_timestamps.noc_assigned_at': now,
                'updated_at': now
            },
            '$push': {
                'events': make_event('noc_assigned', session['user_id'], ROLE_NS,
                                     f"Assigned to {noc_name}",
                                     {'noc_name': noc_name}),
                'noc_history': {
                    'assignee_id': session['user_id'],
                    'assignee_name': noc_name,
                    'assigned_at': now,
                    'released_at': None
                }
            }
        }
    )
    
    # Broadcast assignment update via Socket.IO
    broadcast_tracker_update(tracker_id, 'tracker_assigned', {
        'noc_assignee': session['user_id'],
        'noc_name': noc_name,
        'status': 'noc_working'
    })
    
    # Broadcast to NOC dashboards
    broadcast_dashboard_update(ROLE_NS, 'tracker_assigned', {
        'tracker_id': tracker_id,
        'noc_assignee': session['user_id']
    })
    
    return jsonify({'success': True})


# ─── NOC: Confirm Site Verification ─────────────────────────────────────────
@app.route('/api/trackers/<tracker_id>/site-verify/confirm', methods=['POST'])
@login_required
def api_site_verify_confirm(tracker_id):
    if session.get('role') not in NOC_ROLES:
        return jsonify({'error': 'Unauthorized'}), 403

    tracker = mongo.db.trackers.find_one({'_id': ObjectId(tracker_id)})
    if not tracker:
        return jsonify({'error': 'Tracker not found'}), 404

    sv = tracker.get('site_verification', {})
    if sv.get('status') != 'pending':
        return jsonify({'error': 'Site verification is not in pending state'}), 400

    now = get_utc_now()
    noc_name = session.get('noc_name', session['username'])

    mongo.db.trackers.update_one(
        {'_id': ObjectId(tracker_id)},
        {
            '$set': {
                'site_verification.status': 'confirmed',
                'site_verification.noc_reviewed_at': now,
                'site_verification.noc_reviewed_by': session['user_id'],
                'site_verification.noc_reviewer_name': noc_name,
                'stage_timestamps.site_verification_confirmed_at': now,
                'updated_at': now,
            },
            '$push': {
                'events': make_event('site_verification_confirmed', session['user_id'],
                                     session['role'],
                                     f"Site verification confirmed by {noc_name} — FE confirmed at site")
            }
        }
    )

    broadcast_tracker_update(tracker_id, 'site_verification_confirmed', {
        'site_verification_status': 'confirmed',
        'noc_reviewer_name': noc_name,
    })
    # Notify FE dashboard
    fe_id = tracker.get('fe', {}).get('id')
    if fe_id:
        broadcast_to_user(fe_id, 'site_verification_confirmed', {
            'tracker_id': tracker_id,
            'sdwan_id': tracker.get('sdwan_id'),
            'message': 'Your site verification was confirmed. Awaiting NOC assignment.'
        })

    return jsonify({'success': True})


# ─── NOC: Reject Site Verification ──────────────────────────────────────────
@app.route('/api/trackers/<tracker_id>/site-verify/reject', methods=['POST'])
@login_required
def api_site_verify_reject(tracker_id):
    if session.get('role') not in NOC_ROLES:
        return jsonify({'error': 'Unauthorized'}), 403

    tracker = mongo.db.trackers.find_one({'_id': ObjectId(tracker_id)})
    if not tracker:
        return jsonify({'error': 'Tracker not found'}), 404

    sv = tracker.get('site_verification', {})
    if sv.get('status') != 'pending':
        return jsonify({'error': 'Site verification is not in pending state'}), 400

    data = request.json or {}
    reason = data.get('reason', '').strip()
    if not reason:
        return jsonify({'error': 'Rejection reason is required'}), 400

    now = get_utc_now()
    noc_name = session.get('noc_name', session['username'])

    mongo.db.trackers.update_one(
        {'_id': ObjectId(tracker_id)},
        {
            '$set': {
                'site_verification.status': 'rejected',
                'site_verification.noc_reviewed_at': now,
                'site_verification.noc_reviewed_by': session['user_id'],
                'site_verification.noc_reviewer_name': noc_name,
                'site_verification.rejection_reason': reason,
                'updated_at': now,
            },
            '$inc': {
                'site_verification.rejection_count': 1,
            },
            '$push': {
                'events': make_event('site_verification_rejected', session['user_id'],
                                     session['role'],
                                     f"Site verification rejected by {noc_name}: {reason}")
            }
        }
    )

    broadcast_tracker_update(tracker_id, 'site_verification_rejected', {
        'site_verification_status': 'rejected',
        'rejection_reason': reason,
    })
    # Notify FE with urgent push
    fe_id = tracker.get('fe', {}).get('id')
    if fe_id:
        broadcast_to_user(fe_id, 'site_verification_rejected', {
            'tracker_id': tracker_id,
            'sdwan_id': tracker.get('sdwan_id'),
            'rejection_reason': reason,
            'message': f"Site verification rejected: {reason}. Please retake site photos."
        })

    return jsonify({'success': True})


# ─── FE: Resubmit Site Verification ─────────────────────────────────────────
@app.route('/api/trackers/<tracker_id>/site-verify/resubmit', methods=['POST'])
@login_required
def api_site_verify_resubmit(tracker_id):
    if session.get('role') != ROLE_FE:
        return jsonify({'error': 'Only Field Engineers can resubmit site verification'}), 403

    tracker = mongo.db.trackers.find_one({'_id': ObjectId(tracker_id)})
    if not tracker:
        return jsonify({'error': 'Tracker not found'}), 404

    # Only the FE who created the tracker can resubmit
    if tracker.get('fe', {}).get('id') != session['user_id']:
        return jsonify({'error': 'Unauthorized — not the tracker owner'}), 403

    sv = tracker.get('site_verification', {})
    if sv.get('status') != 'rejected':
        return jsonify({'error': 'Site verification is not in rejected state'}), 400

    data = request.json or {}
    new_images = data.get('site_images', [])
    if len(new_images) < 3:
        return jsonify({'error': 'All 3 site photos are required'}), 400
    new_images = offload_site_images(new_images, tracker_id)

    now = get_utc_now()

    mongo.db.trackers.update_one(
        {'_id': ObjectId(tracker_id)},
        {
            '$set': {
                'site_verification.status': 'pending',
                'site_verification.images': new_images,
                'site_verification.last_submitted_at': now,
                'site_verification.noc_reviewed_at': None,
                'site_verification.noc_reviewed_by': None,
                'site_verification.noc_reviewer_name': None,
                'site_verification.rejection_reason': None,
                'stage_timestamps.site_verification_submitted_at': now,
                'updated_at': now,
            },
            '$push': {
                'events': make_event('site_verification_resubmitted', session['user_id'],
                                     ROLE_FE,
                                     'FE resubmitted site verification photos')
            }
        }
    )

    broadcast_tracker_update(tracker_id, 'site_verification_resubmitted', {
        'site_verification_status': 'pending',
    })
    broadcast_dashboard_update(ROLE_NS, 'site_verification_resubmitted', {
        'tracker_id': tracker_id,
        'sdwan_id': tracker.get('sdwan_id'),
    })

    return jsonify({'success': True})


# ─── NOC: Request Reassignment ──────────────────────────────────────────────
@app.route('/api/trackers/<tracker_id>/request-reassignment', methods=['POST'])
@login_required
def api_request_reassignment(tracker_id):
    if session.get('role') != ROLE_NS:
        return jsonify({'error': 'Unauthorized'}), 403

    data = request.json
    target_noc_id = data.get('target_noc_id', '').strip()
    reason = data.get('reason', '').strip()
    
    if not target_noc_id or not reason:
        return jsonify({'error': 'Target NOC user and reason are required'}), 400

    tracker = mongo.db.trackers.find_one({'_id': ObjectId(tracker_id)})
    if not tracker:
        return jsonify({'error': 'Tracker not found'}), 404

    # Only the currently assigned NOC can request reassignment
    if tracker.get('noc_assignee') != session['user_id']:
        return jsonify({'error': 'Only the assigned NOC can request reassignment'}), 403

    # Cannot request to reassign to yourself
    if target_noc_id == session['user_id']:
        return jsonify({'error': 'Cannot request reassignment to yourself'}), 400

    # Get target NOC user details
    target_user = mongo.db.users.find_one({'_id': ObjectId(target_noc_id), 'role': ROLE_NS})
    if not target_user:
        return jsonify({'error': 'Target NOC user not found'}), 404

    now = get_utc_now()
    noc_name = session.get('noc_name', session['username'])

    # Create reassignment request
    reassignment_request = {
        'from_noc_id': session['user_id'],
        'from_noc_name': noc_name,
        'to_noc_id': target_noc_id,
        'to_noc_name': target_user.get('name', target_user['username']),
        'reason': reason,
        'status': 'pending',  # pending, accepted, denied
        'requested_at': now,
        'responded_at': None,
        'response_reason': None
    }

    mongo.db.trackers.update_one(
        {'_id': ObjectId(tracker_id)},
        {
            '$set': {
                'reassignment_request': reassignment_request,
                'updated_at': now
            },
            '$push': {
                'events': make_event('reassignment_requested', session['user_id'], ROLE_NS,
                                     f"{noc_name} requested to transfer tracker to {reassignment_request['to_noc_name']}. Reason: {reason}",
                                     reassignment_request)
            }
        }
    )
    return jsonify({'success': True})


# ─── NOC: Accept Reassignment Request ───────────────────────────────────────
@app.route('/api/trackers/<tracker_id>/accept-reassignment', methods=['POST'])
@login_required
def api_accept_reassignment(tracker_id):
    if session.get('role') != ROLE_NS:
        return jsonify({'error': 'Unauthorized'}), 403

    tracker = mongo.db.trackers.find_one({'_id': ObjectId(tracker_id)})
    if not tracker:
        return jsonify({'error': 'Tracker not found'}), 404

    req = tracker.get('reassignment_request')
    if not req or req.get('status') != 'pending':
        return jsonify({'error': 'No pending reassignment request found'}), 404

    # Only the target NOC can accept
    if req.get('to_noc_id') != session['user_id']:
        return jsonify({'error': 'Only the target NOC can accept this request'}), 403

    now = get_utc_now()
    noc_name = session.get('noc_name', session['username'])

    # Update request status
    req['status'] = 'accepted'
    req['responded_at'] = now

    # Perform the reassignment
    mongo.db.trackers.update_one(
        {'_id': ObjectId(tracker_id)},
        {
            '$set': {
                'noc_assignee': session['user_id'],
                'reassignment_request': req,
                'updated_at': now
            },
            '$push': {
                'events': make_event('reassignment_accepted', session['user_id'], ROLE_NS,
                                     f"{noc_name} accepted reassignment request from {req['from_noc_name']}",
                                     {'request': req}),
                'noc_history': {
                    'assignee_id': session['user_id'],
                    'assignee_name': noc_name,
                    'assigned_at': now,
                    'released_at': None,
                    'reassignment_reason': f"Accepted transfer from {req['from_noc_name']}: {req['reason']}",
                    'previous_assignee': req['from_noc_name']
                }
            }
        }
    )
    
    # Broadcast reassignment via Socket.IO
    broadcast_tracker_update(tracker_id, 'reassignment_accepted', {
        'new_assignee': session['user_id'],
        'new_assignee_name': noc_name,
        'previous_assignee': req['from_noc_id']
    })
    
    # Notify both NOC users
    broadcast_to_user(req['from_noc_id'], 'reassignment_accepted', {
        'tracker_id': tracker_id,
        'accepted_by': noc_name
    })
    broadcast_to_user(session['user_id'], 'reassignment_accepted', {
        'tracker_id': tracker_id,
        'message': 'You accepted the transfer request'
    })
    
    # Update NOC dashboards
    broadcast_dashboard_update(ROLE_NS, 'tracker_reassigned', {
        'tracker_id': tracker_id,
        'new_assignee': session['user_id']
    })
    
    return jsonify({'success': True})


# ─── NOC: Deny Reassignment Request ─────────────────────────────────────────
@app.route('/api/trackers/<tracker_id>/deny-reassignment', methods=['POST'])
@login_required
def api_deny_reassignment(tracker_id):
    if session.get('role') != ROLE_NS:
        return jsonify({'error': 'Unauthorized'}), 403

    data = request.json
    denial_reason = data.get('reason', '').strip()
    if not denial_reason:
        return jsonify({'error': 'Denial reason is required'}), 400

    tracker = mongo.db.trackers.find_one({'_id': ObjectId(tracker_id)})
    if not tracker:
        return jsonify({'error': 'Tracker not found'}), 404

    req = tracker.get('reassignment_request')
    if not req or req.get('status') != 'pending':
        return jsonify({'error': 'No pending reassignment request found'}), 404

    # Only the target NOC can deny
    if req.get('to_noc_id') != session['user_id']:
        return jsonify({'error': 'Only the target NOC can deny this request'}), 403

    now = get_utc_now()
    noc_name = session.get('noc_name', session['username'])

    # Update request status
    req['status'] = 'denied'
    req['responded_at'] = now
    req['response_reason'] = denial_reason

    mongo.db.trackers.update_one(
        {'_id': ObjectId(tracker_id)},
        {
            '$set': {
                'reassignment_request': req,
                'updated_at': now
            },
            '$push': {
                'events': make_event('reassignment_denied', session['user_id'], ROLE_NS,
                                     f"{noc_name} denied reassignment request from {req['from_noc_name']}. Reason: {denial_reason}",
                                     {'request': req, 'denial_reason': denial_reason})
            }
        }
    )
    return jsonify({'success': True})


# ─── NOC: Get Reassignment Requests ─────────────────────────────────────────
@app.route('/api/trackers/reassignment-requests', methods=['GET'])
@login_required
def api_get_reassignment_requests():
    if session.get('role') != ROLE_NS:
        return jsonify({'error': 'Unauthorized'}), 403

    # Find all trackers with pending reassignment requests for current user
    trackers = list(mongo.db.trackers.find({
        'reassignment_request.to_noc_id': session['user_id'],
        'reassignment_request.status': 'pending'
    }))

    requests = []
    for t in trackers:
        req = t.get('reassignment_request', {})
        requests.append({
            'tracker_id': str(t['_id']),
            'sdwan_id': t.get('sdwan_id'),
            'customer': t.get('customer'),
            'from_noc_name': req.get('from_noc_name'),
            'reason': req.get('reason'),
            'requested_at': req.get('requested_at').isoformat() + 'Z' if req.get('requested_at') else None
        })

    return jsonify({'requests': requests})


# ─── NOC: Revoke Reassignment Request ───────────────────────────────────────
@app.route('/api/trackers/<tracker_id>/revoke-reassignment', methods=['POST'])
@login_required
def api_revoke_reassignment(tracker_id):
    if session.get('role') != ROLE_NS:
        return jsonify({'error': 'Unauthorized'}), 403

    tracker = mongo.db.trackers.find_one({'_id': ObjectId(tracker_id)})
    if not tracker:
        return jsonify({'error': 'Tracker not found'}), 404

    req = tracker.get('reassignment_request')
    if not req or req.get('status') != 'pending':
        return jsonify({'error': 'No pending reassignment request found'}), 404

    # Only the requesting NOC can revoke
    if req.get('from_noc_id') != session['user_id']:
        return jsonify({'error': 'Only the requesting NOC can revoke this request'}), 403

    now = get_utc_now()
    noc_name = session.get('noc_name', session['username'])

    # Update request status to revoked
    req['status'] = 'revoked'
    req['responded_at'] = now

    mongo.db.trackers.update_one(
        {'_id': ObjectId(tracker_id)},
        {
            '$set': {
                'reassignment_request': req,
                'updated_at': now
            },
            '$push': {
                'events': make_event('reassignment_revoked', session['user_id'], ROLE_NS,
                                     f"{noc_name} revoked transfer request to {req['to_noc_name']}",
                                     {'request': req})
            }
        }
    )
    return jsonify({'success': True})


# ─── NOC: SIM Activation ────────────────────────────────────────────────────
@app.route('/api/trackers/<tracker_id>/sim/<sim_key>/status', methods=['POST'])
@login_required
def api_update_sim_status(tracker_id, sim_key):
    if session.get('role') != ROLE_NS:
        return jsonify({'error': 'Unauthorized'}), 403

    tracker = mongo.db.trackers.find_one({'_id': ObjectId(tracker_id)})
    if not tracker:
        return jsonify({'error': 'Tracker not found'}), 404
    if tracker.get('noc_assignee') != session['user_id']:
        return jsonify({'error': 'This tracker is not assigned to you'}), 403

    data = request.json
    status         = data.get('status')
    failure_reason = data.get('failure_reason')
    remarks        = data.get('remarks', f'{sim_key.upper()} status → {status}')
    now            = get_utc_now()

    stage_map = {
        'activation_in_process':              f'{sim_key}_activation_in_process',
        'activation_complete_manual':         f'{sim_key}_activation_complete_manual',
        'activation_complete_preactivated':   f'{sim_key}_activation_complete_preactivated',
        'activation_failed':                  f'{sim_key}_activation_failed',
    }

    update_data = {f'sim.{sim_key}.status': status, 'updated_at': now}

    if status == 'activation_in_process':
        # Only stamp activation_started_at on the FIRST attempt
        if not tracker.get('sim', {}).get(sim_key, {}).get('activation_started_at'):
            update_data[f'sim.{sim_key}.activation_started_at'] = now
            update_data[f'stage_timestamps.{sim_key}_activation_started_at'] = now
        # Record the attempt starting
        attempt = {'attempt_no': len(tracker.get('sim', {}).get(sim_key, {}).get('attempts', [])) + 1,
                   'started_at': now, 'result': None, 'reason': None}
    elif status in ('activation_complete_manual', 'activation_complete_preactivated'):
        update_data[f'sim.{sim_key}.activation_done_at'] = now
        update_data[f'stage_timestamps.{sim_key}_activation_done_at'] = now
        if failure_reason:
            update_data[f'sim.{sim_key}.failure_reason'] = None  # Clear on success
    elif status == 'activation_failed':
        update_data[f'sim.{sim_key}.failure_reason'] = failure_reason

    event = make_event(stage_map.get(status, f'{sim_key}_status_update'),
                       session['user_id'], ROLE_NS, remarks,
                       {'sim_key': sim_key, 'status': status, 'failure_reason': failure_reason})

    # Append to the per-SIM attempts array for retry tracking
    attempt_entry = {
        'attempt_no': len(tracker.get('sim', {}).get(sim_key, {}).get('attempts', [])) + 1,
        'started_at': now if status == 'activation_in_process' else None,
        'result': None if status == 'activation_in_process' else status,
        'reason': failure_reason
    }

    push_ops = {'events': event}
    # Only push a new attempt record when we START an activation (not on every status change)
    if status == 'activation_in_process':
        push_ops[f'sim.{sim_key}.attempts'] = attempt_entry

    mongo.db.trackers.update_one(
        {'_id': ObjectId(tracker_id)},
        {'$set': update_data, '$push': push_ops}
    )
    
    # Broadcast SIM status update via Socket.IO
    broadcast_tracker_update(tracker_id, 'sim_status_updated', {
        'sim_key': sim_key,
        'status': status,
        'failure_reason': failure_reason
    })
    
    return jsonify({'success': True, 'message': f'{sim_key.upper()} status updated'})


# ─── NOC: ZTP Config Verification ───────────────────────────────────────────
# This is a NEW stage that was missing. NS verifies the ZTP configuration
# based on what FE submitted (firmware version, SDWAN ID etc.) before
# either NS or FE can initiate ZTP.
@app.route('/api/trackers/<tracker_id>/ztp/config', methods=['POST'])
@login_required
def api_verify_ztp_config(tracker_id):
    if session.get('role') != ROLE_NS:
        return jsonify({'error': 'Unauthorized'}), 403

    tracker = mongo.db.trackers.find_one({'_id': ObjectId(tracker_id)})
    if not tracker:
        return jsonify({'error': 'Tracker not found'}), 404
    if tracker.get('noc_assignee') != session['user_id']:
        return jsonify({'error': 'Not assigned to you'}), 403

    data = request.json
    result         = data.get('result')   # 'verified' or 'failed'
    failure_reason = data.get('failure_reason')
    remarks        = data.get('remarks', f'ZTP config {result}')
    now            = get_utc_now()

    if result not in ('verified', 'failed'):
        return jsonify({'error': 'result must be "verified" or "failed"'}), 400

    update_data = {
        'ztp.config_status': f'config_{result}',
        'stage_timestamps.ztp_config_verified_at': now,
        'updated_at': now
    }
    if result == 'failed':
        update_data['ztp.config_failure_reason'] = failure_reason

    mongo.db.trackers.update_one(
        {'_id': ObjectId(tracker_id)},
        {
            '$set': update_data,
            '$push': {'events': make_event(f'ztp_config_{result}', session['user_id'], ROLE_NS,
                                           remarks, {'failure_reason': failure_reason})}
        }
    )
    
    # Broadcast ZTP config verification via Socket.IO
    broadcast_tracker_update(tracker_id, 'ztp_config_updated', {
        'result': result,
        'failure_reason': failure_reason
    })
    
    return jsonify({'success': True, 'message': f'ZTP config marked as {result}'})


# ─── FE: Start ZTP (FE performs ZTP) ────────────────────────────────────────
# After NS verifies ZTP config, FE sees a "Start ZTP" button.
# FE clicks it, which initiates the ZTP process from the field device.
@app.route('/api/trackers/<tracker_id>/ztp/fe-start', methods=['POST'])
@login_required
def api_fe_start_ztp(tracker_id):
    if session.get('role') != ROLE_FE:
        return jsonify({'error': 'Unauthorized'}), 403

    tracker = mongo.db.trackers.find_one({'_id': ObjectId(tracker_id)})
    if not tracker:
        return jsonify({'error': 'Tracker not found'}), 404
    if tracker.get('fe', {}).get('id') != session['user_id']:
        return jsonify({'error': 'Not your tracker'}), 403
    if tracker.get('ztp', {}).get('config_status') != 'config_verified':
        return jsonify({'error': 'ZTP config not yet verified by NOC'}), 400

    now = get_utc_now()
    attempt_no = len(tracker.get('ztp', {}).get('attempts', [])) + 1

    mongo.db.trackers.update_one(
        {'_id': ObjectId(tracker_id)},
        {
            '$set': {
                'ztp.status': 'initiated',
                'ztp.performed_by': 'FE',
                'ztp.initiated_at': now,
                'stage_timestamps.ztp_started_at': now,
                'updated_at': now
            },
            '$push': {
                'events': make_event('ztp_initiated_by_fe', session['user_id'], ROLE_FE,
                                     'FE initiated ZTP from device'),
                'ztp.attempts': {
                    'attempt_no': attempt_no,
                    'performed_by': 'FE',
                    'started_at': now,
                    'result': None,
                    'reason': None
                }
            }
        }
    )
    
    # Broadcast ZTP initiation via Socket.IO
    broadcast_tracker_update(tracker_id, 'ztp_initiated', {
        'performed_by': 'FE'
    })
    
    return jsonify({'success': True, 'message': 'ZTP initiated by FE'})


# ─── FE: ZTP Completed (FE reports ZTP succeeded) ───────────────────────────
@app.route('/api/trackers/<tracker_id>/ztp/fe-complete', methods=['POST'])
@login_required
def api_fe_complete_ztp(tracker_id):
    if session.get('role') != ROLE_FE:
        return jsonify({'error': 'Unauthorized'}), 403

    tracker = mongo.db.trackers.find_one({'_id': ObjectId(tracker_id)})
    if not tracker:
        return jsonify({'error': 'Tracker not found'}), 404
    if tracker.get('fe', {}).get('id') != session['user_id']:
        return jsonify({'error': 'Not your tracker'}), 403

    now = get_utc_now()
    mongo.db.trackers.update_one(
        {'_id': ObjectId(tracker_id)},
        {
            '$set': {
                'ztp.status': 'fe_completed',   # Distinct from 'completed' so NS must verify
                'ztp.fe_completed_at': now,
                'updated_at': now
            },
            '$push': {
                'events': make_event('ztp_completed_by_fe', session['user_id'], ROLE_FE,
                                     'FE reports ZTP completed — awaiting NS verification')
            }
        }
    )
    
    # Broadcast ZTP completion via Socket.IO
    broadcast_tracker_update(tracker_id, 'ztp_completed_by_fe', {
        'status': 'fe_completed'
    })
    return jsonify({'success': True, 'message': 'ZTP reported complete by FE — awaiting NS verification'})


# ─── FE: Request NS to Perform ZTP ──────────────────────────────────────────
# If FE cannot perform ZTP (device issue, connectivity), FE clicks this button.
# Chat unlocks immediately so FE can explain the situation to NS.
@app.route('/api/trackers/<tracker_id>/ztp/request-noc', methods=['POST'])
@login_required
def api_request_noc_ztp(tracker_id):
    if session.get('role') != ROLE_FE:
        return jsonify({'error': 'Unauthorized'}), 403

    tracker = mongo.db.trackers.find_one({'_id': ObjectId(tracker_id)})
    if not tracker:
        return jsonify({'error': 'Tracker not found'}), 404
    if tracker.get('fe', {}).get('id') != session['user_id']:
        return jsonify({'error': 'Not your tracker'}), 403

    now = get_utc_now()
    mongo.db.trackers.update_one(
        {'_id': ObjectId(tracker_id)},
        {
            '$set': {
                'ztp.fe_requested_ns': True,
                'status': 'fe_requested_ztp',   # Chat unlocks on this status
                'updated_at': now
            },
            '$push': {
                'events': make_event('fe_requested_noc_ztp', session['user_id'], ROLE_FE,
                                     'FE cannot perform ZTP — requested NS to do it. Chat unlocked.')
            }
        }
    )
    
    # Broadcast ZTP request to NOC via Socket.IO
    broadcast_tracker_update(tracker_id, 'ztp_requested_from_noc', {
        'status': 'ztp_pull_requested_from_noc'
    })
    
    return jsonify({'success': True, 'message': 'Request sent to NOC. Chat is now unlocked.'})


# ─── NOC: ZTP Status Update (NS performs or verifies ZTP) ───────────────────
@app.route('/api/trackers/<tracker_id>/ztp/status', methods=['POST'])
@login_required
def api_update_ztp_status(tracker_id):
    if session.get('role') != ROLE_NS:
        return jsonify({'error': 'Unauthorized'}), 403

    tracker = mongo.db.trackers.find_one({'_id': ObjectId(tracker_id)})
    if not tracker:
        return jsonify({'error': 'Tracker not found'}), 404
    if tracker.get('noc_assignee') != session['user_id']:
        return jsonify({'error': 'Not assigned to you'}), 403

    data           = request.json
    status         = data.get('status')   # 'initiated' | 'completed' | 'failed' | 'verified_fe_completion'
    failure_reason = data.get('failure_reason')
    remarks        = data.get('remarks', f'ZTP {status}')
    now            = get_utc_now()

    stage_map = {
        'initiated':              'ztp_initiated_by_noc',
        'completed':              'ztp_completed_by_noc',
        'failed':                 'ztp_failed',
        'verified_fe_completion': 'ztp_fe_completion_verified',
    }

    update_data = {'ztp.status': status, 'updated_at': now}

    if status == 'initiated':
        update_data['ztp.performed_by'] = 'NS'
        update_data['ztp.initiated_at'] = now
        update_data['stage_timestamps.ztp_started_at'] = now
        attempt_no = len(tracker.get('ztp', {}).get('attempts', [])) + 1
        push_attempt = {
            'attempt_no': attempt_no,
            'performed_by': 'NS',
            'started_at': now,
            'result': None,
            'reason': None
        }
    elif status in ('completed', 'verified_fe_completion'):
        update_data['ztp.status'] = 'completed'  # Normalise both to 'completed'
        update_data['ztp.completed_at'] = now
        update_data['stage_timestamps.ztp_done_at'] = now
        push_attempt = None
    elif status == 'failed':
        update_data['ztp.failure_reason'] = failure_reason
        push_attempt = None

    event_stage = stage_map.get(status, 'ztp_status_update')
    push_ops = {'events': make_event(event_stage, session['user_id'], ROLE_NS, remarks,
                                     {'status': status, 'failure_reason': failure_reason})}
    if status == 'initiated' and push_attempt:
        push_ops['ztp.attempts'] = push_attempt

    mongo.db.trackers.update_one(
        {'_id': ObjectId(tracker_id)},
        {'$set': update_data, '$push': push_ops}
    )
    
    # Broadcast ZTP status update via Socket.IO
    broadcast_tracker_update(tracker_id, 'ztp_status_updated', {
        'status': status,
        'failure_reason': failure_reason
    })
    
    return jsonify({'success': True, 'message': f'ZTP status updated to {status}'})


# ─── NEW ZTP WORKFLOW ENDPOINTS (2-Phase: Config Verification → Pull Execution) ───

# Phase 1a: FE submits ZTP configuration for NOC verification
@app.route('/api/ztp/config/submit', methods=['POST'])
@login_required
def api_ztp_config_submit():
    """FE submits ZTP device configuration for NOC to verify."""
    if session.get('role') != ROLE_FE:
        return jsonify({'error': 'Unauthorized'}), 403

    data = request.json
    tracker_id = data.get('tracker_id')

    tracker = mongo.db.trackers.find_one({'_id': ObjectId(tracker_id)})
    if not tracker:
        return jsonify({'error': 'Tracker not found'}), 404
    if tracker.get('fe', {}).get('id') != session['user_id']:
        return jsonify({'error': 'Not your tracker'}), 403

    now = get_utc_now()
    config_data = {
        'device_model': data.get('device_model', ''),
        'firmware_version': data.get('firmware_version', ''),
        'serial_number': data.get('serial_number', ''),
        'mac_address': data.get('mac_address', ''),
        'submitted_by': session['username'],
        'submitted_at': now,
    }

    mongo.db.trackers.update_one(
        {'_id': ObjectId(tracker_id)},
        {
            '$set': {
                'ztp.config': config_data,
                'ztp.config_status': 'pending',
                'status': STATUS_ZTP_PULL_PENDING if tracker.get('status') == STATUS_ZTP_CONFIG_UNVERIFIED else tracker.get('status'),
                'updated_at': now
            },
            '$push': {
                'events': make_event('ztp_config_submitted', session['user_id'], ROLE_FE,
                                     'ZTP device configuration submitted for NOC verification',
                                     {'config': config_data})
            }
        }
    )

    return jsonify({'success': True, 'message': 'Configuration submitted for NOC verification'})


# Phase 1b: NOC verifies ZTP Configuration
@app.route('/api/ztp/config/verify', methods=['POST'])
@login_required
def api_ztp_config_verify():
    """NOC verifies or rejects ZTP configuration"""
    if session.get('role') != ROLE_NS:
        return jsonify({'error': 'Unauthorized'}), 403

    data = request.json
    tracker_id = data.get('tracker_id')
    # Accept both 'result' (canonical) and 'verified' (from ZTP component JS boolean)
    result = data.get('result')
    if result is None:
        verified_flag = data.get('verified')
        if verified_flag is True:
            result = 'verified'
        elif verified_flag is False:
            result = 'unverified'
    notes = data.get('notes', '')

    if result not in ('verified', 'unverified'):
        return jsonify({'error': 'result must be "verified" or "unverified"'}), 400

    tracker = mongo.db.trackers.find_one({'_id': ObjectId(tracker_id)})
    if not tracker:
        return jsonify({'error': 'Tracker not found'}), 404
    if tracker.get('noc_assignee') != session['user_id']:
        return jsonify({'error': 'Not assigned to you'}), 403

    now = get_utc_now()

    if result == 'verified':
        new_status = STATUS_ZTP_PULL_PENDING
        event_msg = 'ZTP Configuration Verified by NOC'
    else:
        new_status = STATUS_ZTP_CONFIG_UNVERIFIED
        event_msg = f'ZTP Configuration Marked as Unverified: {notes}'

    verification_entry = {
        'verified_by': session['username'],
        'result': result,
        'timestamp': now,
        'notes': notes
    }

    mongo.db.trackers.update_one(
        {'_id': ObjectId(tracker_id)},
        {
            '$set': {
                'status': new_status,
                'updated_at': now
            },
            '$push': {
                'events': make_event('ztp_config_verification', session['user_id'], ROLE_NS, event_msg),
                'ztp.config_verification_history': verification_entry
            }
        }
    )

    return jsonify({'success': True, 'message': f'ZTP config marked as {result}'})


# Phase 2: ZTP Pull Execution - FE Actions
@app.route('/api/ztp/pull/action', methods=['POST'])
@login_required
def api_ztp_pull_action():
    """FE marks ZTP pull as done or requests NOC to perform it"""
    if session.get('role') != ROLE_FE:
        return jsonify({'error': 'Unauthorized'}), 403

    data = request.json
    tracker_id = data.get('tracker_id')
    action = data.get('action')  # 'done_by_fe' or 'request_noc'
    notes = data.get('notes', '')

    tracker = mongo.db.trackers.find_one({'_id': ObjectId(tracker_id)})
    if not tracker:
        return jsonify({'error': 'Tracker not found'}), 404
    if tracker.get('fe', {}).get('id') != session['user_id']:
        return jsonify({'error': 'Not your tracker'}), 403

    now = get_utc_now()

    if action == 'done_by_fe':
        new_status = STATUS_ZTP_PULL_DONE_FE
        event_msg = 'FE Completed ZTP Pull - Awaiting NOC Verification'
        pull_entry = {
            'action': 'done_by_fe',
            'performed_by': session['username'],
            'timestamp': now,
            'notes': notes
        }
    elif action == 'request_noc':
        new_status = STATUS_ZTP_PULL_REQ_NOC
        event_msg = 'FE Requested NOC to Perform ZTP Pull'
        pull_entry = {
            'action': 'requested_from_noc',
            'performed_by': session['username'],
            'timestamp': now,
            'notes': notes
        }
    else:
        return jsonify({'error': 'Invalid action'}), 400

    mongo.db.trackers.update_one(
        {'_id': ObjectId(tracker_id)},
        {
            '$set': {
                'status': new_status,
                'updated_at': now
            },
            '$push': {
                'events': make_event('ztp_pull_action', session['user_id'], ROLE_FE, event_msg),
                'ztp.pull_history': pull_entry
            }
        }
    )

    return jsonify({'success': True, 'message': event_msg})


# Phase 2: ZTP Pull Execution - NOC Verifies FE's Work
@app.route('/api/ztp/pull/verify', methods=['POST'])
@login_required
def api_ztp_pull_verify():
    """NOC verifies or rejects FE's ZTP pull work"""
    if session.get('role') != ROLE_NS:
        return jsonify({'error': 'Unauthorized'}), 403

    data = request.json
    tracker_id = data.get('tracker_id')
    # Accept both 'result' (canonical) and 'verified' (from ZTP component JS boolean)
    result = data.get('result')
    if result is None:
        verified_flag = data.get('verified')
        if verified_flag is True:
            result = 'verified'
        elif verified_flag is False:
            result = 'unverified'
    notes = data.get('notes', '')

    if result not in ('verified', 'unverified'):
        return jsonify({'error': 'result must be "verified" or "unverified"'}), 400

    tracker = mongo.db.trackers.find_one({'_id': ObjectId(tracker_id)})
    if not tracker:
        return jsonify({'error': 'Tracker not found'}), 404
    if tracker.get('noc_assignee') != session['user_id']:
        return jsonify({'error': 'Not assigned to you'}), 403

    now = get_utc_now()

    pull_entry = {
        'action': result,
        'performed_by': session['username'],
        'timestamp': now,
        'notes': notes
    }

    if result == 'verified':
        event_msg = "NOC Verified FE's ZTP Pull - ZTP Complete"
        # Mirror what api_update_ztp_status does for status='verified_fe_completion':
        # Set ztp.status='completed', write all stage timestamps, and advance the
        # tracker to ready_for_coordination so the downstream chain (Quick Actions,
        # HSO submit button, chat unlock) all work correctly.
        set_fields = {
            'status': STATUS_READY_COORD,
            'ztp.status': 'completed',
            'ztp.performed_by': 'FE',
            'ztp.completed_at': now,
            'stage_timestamps.ztp_done_at': now,
            'stage_timestamps.ready_for_coordination_at': now,
            'updated_at': now
        }
    else:
        event_msg = f'NOC Marked ZTP Pull as Unverified: {notes}'
        set_fields = {
            'status': STATUS_ZTP_PULL_UNVERIFIED,
            'updated_at': now
        }

    mongo.db.trackers.update_one(
        {'_id': ObjectId(tracker_id)},
        {
            '$set': set_fields,
            '$push': {
                'events': make_event('ztp_pull_verification', session['user_id'], ROLE_NS, event_msg),
                'ztp.pull_history': pull_entry
            }
        }
    )

    return jsonify({'success': True, 'message': event_msg})


# Phase 2: ZTP Pull Execution - NOC Performs ZTP
@app.route('/api/ztp/pull/perform-by-noc', methods=['POST'])
@login_required
def api_ztp_pull_perform_by_noc():
    """NOC performs ZTP pull when requested by FE"""
    if session.get('role') != ROLE_NS:
        return jsonify({'error': 'Unauthorized'}), 403

    data = request.json
    tracker_id = data.get('tracker_id')
    notes = data.get('notes', '')

    tracker = mongo.db.trackers.find_one({'_id': ObjectId(tracker_id)})
    if not tracker:
        return jsonify({'error': 'Tracker not found'}), 404
    if tracker.get('noc_assignee') != session['user_id']:
        return jsonify({'error': 'Not assigned to you'}), 403

    now = get_utc_now()
    event_msg = 'ZTP Pull Completed by NOC - ZTP Complete'

    pull_entry = {
        'action': 'done_by_noc',
        'performed_by': session['username'],
        'timestamp': now,
        'notes': notes
    }

    noc_name = session.get('noc_name', session['username'])

    # Transition the tracker to ready_for_coordination so that:
    #   - The Installation Status tile shows "Ready — Chat Open" (not "FE Needs Help")
    #   - is_chat_unlocked() returns True, enabling the chat
    #   - renderQuickActions() shows the HSO Approve/Reject section
    #   - renderHsoSection() shows the FE's Submit HSO button
    # Also write all ZTP completion fields that the rest of the code expects:
    #   - ztp.status = 'completed'  (renderQuickActions checks ztpDone = ztp.status === 'completed')
    #   - ztp.performed_by = 'NS'   (KPI: ZTP done by FE vs NS)
    #   - ztp.completed_at          (stage duration KPI)
    #   - stage_timestamps.ztp_done_at  (fast KPI aggregation field)
    #   - stage_timestamps.ready_for_coordination_at  (NS processing time KPI)
    mongo.db.trackers.update_one(
        {'_id': ObjectId(tracker_id)},
        {
            '$set': {
                'status': STATUS_READY_COORD,
                'ztp.status': 'completed',
                'ztp.performed_by': 'NS',
                'ztp.completed_at': now,
                'stage_timestamps.ztp_done_at': now,
                'stage_timestamps.ready_for_coordination_at': now,
                'updated_at': now
            },
            '$push': {
                'events': make_event('ztp_completed_by_noc', session['user_id'], ROLE_NS, event_msg,
                                     {'performed_by': 'NS', 'notes': notes}),
                'ztp.pull_history': pull_entry,
                # Also record in the canonical ztp.attempts array for KPI tracking
                'ztp.attempts': {
                    'attempt_no': len(tracker.get('ztp', {}).get('attempts', [])) + 1,
                    'performed_by': 'NS',
                    'started_at': now,
                    'result': 'completed',
                    'reason': notes or None
                }
            }
        }
    )
    
    # Broadcast ready for coordination via Socket.IO
    broadcast_tracker_update(tracker_id, 'ready_for_coordination', {
        'status': 'ready_for_coordination'
    })

    return jsonify({'success': True, 'message': 'ZTP pull completed by NOC. Ready for coordination.'})


# ─── NOC: Mark Ready for Coordination ───────────────────────────────────────
# Called after ZTP is fully completed (by FE verified by NS, or by NS directly).
# This unlocks the chat channel for FE-NS coordination.
@app.route('/api/trackers/<tracker_id>/ready-for-coordination', methods=['POST'])
@login_required
def api_ready_for_coordination(tracker_id):
    if session.get('role') != ROLE_NS:
        return jsonify({'error': 'Unauthorized'}), 403

    tracker = mongo.db.trackers.find_one({'_id': ObjectId(tracker_id)})
    if not tracker:
        return jsonify({'error': 'Tracker not found'}), 404
    if tracker.get('noc_assignee') != session['user_id']:
        return jsonify({'error': 'Not assigned to you'}), 403

    now = get_utc_now()
    mongo.db.trackers.update_one(
        {'_id': ObjectId(tracker_id)},
        {
            '$set': {
                'status': 'ready_for_coordination',
                'stage_timestamps.ready_for_coordination_at': now,
                'updated_at': now
            },
            '$push': {
                'events': make_event('ready_for_coordination', session['user_id'], ROLE_NS,
                                     'SIM activation & ZTP complete. Chat unlocked. Ready for FE coordination.')
            }
        }
    )
    return jsonify({'success': True, 'message': 'Marked as ready for coordination. Chat is now unlocked.'})


# ─── FE: Submit HSO ─────────────────────────────────────────────────────────
# FE clicks this button to formally notify NS that the hand-over sign-off
# document has been submitted. This creates a timestamped event and moves
# the tracker to 'hso_submitted' status so NS can see it.
@app.route('/api/trackers/<tracker_id>/hso/submit', methods=['POST'])
@login_required
def api_submit_hso(tracker_id):
    if session.get('role') != ROLE_FE:
        return jsonify({'error': 'Unauthorized'}), 403

    tracker = mongo.db.trackers.find_one({'_id': ObjectId(tracker_id)})
    if not tracker:
        return jsonify({'error': 'Tracker not found'}), 404
    if tracker.get('fe', {}).get('id') != session['user_id']:
        return jsonify({'error': 'Not your tracker'}), 403
    # Allow HSO submission from every status where the FE-NS coordination phase has begun.
    if tracker.get('status') not in HSO_SUBMITTABLE_STATUSES:
        return jsonify({'error': 'Tracker is not in the correct state to submit HSO'}), 400

    now = get_utc_now()
    attempt_no = len(tracker.get('hso', {}).get('attempts', [])) + 1
    # First submission sets submitted_at; resubmissions add to the attempts log
    set_ops = {
        'hso.status': 'submitted',
        'hso.submitted_at': now,   # Tracks the LATEST submission timestamp
        'status': 'hso_submitted',
        'updated_at': now
    }
    # Only stamp the KPI field on the very first submission
    if attempt_no == 1:
        set_ops['stage_timestamps.hso_submitted_at'] = now

    mongo.db.trackers.update_one(
        {'_id': ObjectId(tracker_id)},
        {
            '$set': set_ops,
            '$push': {
                'events': make_event('hso_submitted', session['user_id'], ROLE_FE,
                                     f'HSO submitted by FE (attempt #{attempt_no})'),
                'hso.attempts': {
                    'attempt_no': attempt_no,
                    'submitted_at': now,
                    'action': 'submitted',
                    'actor_id': session['user_id'],
                    'actor_role': ROLE_FE,
                    'reason': None
                }
            }
        }
    )
    
    # Broadcast HSO submission via Socket.IO
    broadcast_tracker_update(tracker_id, 'hso_submitted', {
        'status': 'hso_submitted',
        'attempt_no': attempt_no
    })
    
    return jsonify({'success': True, 'message': f'HSO submitted (attempt #{attempt_no})'})


# ─── NOC: Approve HSO ───────────────────────────────────────────────────────
@app.route('/api/trackers/<tracker_id>/hso/approve', methods=['POST'])
@login_required
def api_approve_hso(tracker_id):
    if session.get('role') != ROLE_NS:
        return jsonify({'error': 'Unauthorized'}), 403

    tracker = mongo.db.trackers.find_one({'_id': ObjectId(tracker_id)})
    if not tracker:
        return jsonify({'error': 'Tracker not found'}), 404
    if tracker.get('noc_assignee') != session['user_id']:
        return jsonify({'error': 'Not assigned to you'}), 403
    if tracker.get('hso', {}).get('status') != 'submitted':
        return jsonify({'error': 'No pending HSO submission to approve'}), 400

    data    = request.json or {}
    remarks = data.get('remarks', 'HSO approved by NS')
    now     = get_utc_now()

    mongo.db.trackers.update_one(
        {'_id': ObjectId(tracker_id)},
        {
            '$set': {
                'hso.status': 'approved',
                'hso.approved_at': now,
                'status': 'installation_complete',
                'stage_timestamps.hso_approved_at': now,
                'stage_timestamps.installation_complete_at': now,
                'completed_at': now,
                'updated_at': now
            },
            '$push': {
                'events': {
                    '$each': [
                        make_event('hso_approved', session['user_id'], ROLE_NS, remarks),
                        make_event('installation_complete', 'system', 'system',
                                   'Installation completed successfully'),
                    ]
                }
            }
        }
    )
    
    # Broadcast HSO approval and installation completion via Socket.IO
    broadcast_tracker_update(tracker_id, 'installation_complete', {
        'status': 'installation_complete',
        'hso_status': 'approved'
    })
    
    return jsonify({'success': True, 'message': 'HSO approved. Installation complete!'})


# ─── NOC: Reject HSO ────────────────────────────────────────────────────────
# NS rejects the HSO with a reason. FE will see the rejection reason and
# a "Re-submit HSO" button. The tracker reverts to 'hso_rejected' status.
@app.route('/api/trackers/<tracker_id>/hso/reject', methods=['POST'])
@login_required
def api_reject_hso(tracker_id):
    if session.get('role') != ROLE_NS:
        return jsonify({'error': 'Unauthorized'}), 403

    tracker = mongo.db.trackers.find_one({'_id': ObjectId(tracker_id)})
    if not tracker:
        return jsonify({'error': 'Tracker not found'}), 404
    if tracker.get('noc_assignee') != session['user_id']:
        return jsonify({'error': 'Not assigned to you'}), 403
    if tracker.get('hso', {}).get('status') != 'submitted':
        return jsonify({'error': 'No pending HSO submission to reject'}), 400

    data   = request.json or {}
    reason = data.get('reason')
    if not reason:
        return jsonify({'error': 'Rejection reason is required'}), 400

    now = get_utc_now()
    mongo.db.trackers.update_one(
        {'_id': ObjectId(tracker_id)},
        {
            '$set': {
                'hso.status': 'rejected',
                'hso.rejected_at': now,
                'hso.rejection_reason': reason,
                'status': 'hso_rejected',   # FE sees this and can Re-submit
                'updated_at': now
            },
            '$push': {
                'events': make_event('hso_rejected', session['user_id'], ROLE_NS,
                                     f'HSO rejected: {reason}', {'reason': reason})
            }
        }
    )
    
    # Broadcast HSO rejection via Socket.IO
    broadcast_tracker_update(tracker_id, 'hso_rejected', {
        'status': 'hso_rejected',
        'reason': reason
    })
    
    return jsonify({'success': True, 'message': 'HSO rejected. FE will be notified to re-submit.'})


# ─── NOC: Legacy "incomplete" endpoint ──────────────────────────────────────
# Kept for backwards compatibility but internally maps to the reject flow.
@app.route('/api/trackers/<tracker_id>/hso/incomplete', methods=['POST'])
@login_required
def api_hso_incomplete(tracker_id):
    """Legacy endpoint — routes to reject internally."""
    if session.get('role') != ROLE_NS:
        return jsonify({'error': 'Unauthorized'}), 403
    data = request.json or {}
    data['reason'] = data.get('reason') or data.get('remarks', 'HSO incomplete')
    # Re-use reject handler logic inline
    tracker = mongo.db.trackers.find_one({'_id': ObjectId(tracker_id)})
    if not tracker:
        return jsonify({'error': 'Tracker not found'}), 404
    if tracker.get('noc_assignee') != session['user_id']:
        return jsonify({'error': 'Not assigned to you'}), 403

    reason = data['reason']
    now = get_utc_now()
    mongo.db.trackers.update_one(
        {'_id': ObjectId(tracker_id)},
        {
            '$set': {
                'hso.status': 'rejected',
                'hso.rejected_at': now,
                'hso.rejection_reason': reason,
                'status': 'hso_rejected',
                'updated_at': now
            },
            '$push': {
                'events': make_event('hso_rejected', session['user_id'], ROLE_NS,
                                     f'HSO incomplete/rejected: {reason}', {'reason': reason})
            }
        }
    )
    return jsonify({'success': True, 'message': 'HSO marked as incomplete (rejected)'})


# ─── Predefined Reasons ─────────────────────────────────────────────────────
@app.route('/api/config/reasons/<category>')
@login_required
def api_get_reasons(category):
    doc = mongo.db.predefined_reasons.find_one({'category': category})
    return jsonify({'reasons': doc.get('reasons', []) if doc else []})


# ─── Chat APIs ──────────────────────────────────────────────────────────────
@app.route('/api/trackers/<tracker_id>/chat/messages', methods=['GET'])
@login_required
def api_get_chat_messages(tracker_id):
    tracker = visible_tracker(tracker_id)
    if not tracker:
        return jsonify({'error': 'Tracker not found'}), 404

    user_role = session.get('role')
    # NOC operators can only see chat for trackers assigned to them
    if user_role == ROLE_NS and tracker.get('noc_assignee') != session['user_id']:
        return jsonify({'error': 'Not assigned to you'}), 403

    can_interact = True
    if user_role == ROLE_FE:
        can_interact = (tracker.get('fe', {}).get('id') == session['user_id'])
    elif user_role in (ROLE_FEG, ROLE_FS, ROLE_FSG):
        can_interact = False  # Hierarchy supervisors are read-only

    # ?since=<iso> returns only what the client does not already hold, and media
    # is never inlined - each message carries a /api/media/<id> URL the browser
    # fetches once and caches. The old endpoint re-sent every message in the
    # thread, with every photo and voice note inline, every 5 seconds: measured at
    # 2.2MB per poll on the heaviest thread (PROJECT_GUIDE section 15.2).
    query = {'tracker_id': tracker_id}
    since = request.args.get('since')
    if since:
        try:
            query['timestamp'] = {'$gt': datetime.fromisoformat(since.replace('Z', ''))}
        except ValueError:
            pass

    try:
        limit = min(int(request.args.get('limit', 200)), 500)
    except ValueError:
        limit = 200

    cursor = mongo.db.chat_messages.find(query).sort('timestamp', -1).limit(limit)
    messages = list(cursor)[::-1]          # newest-first for the limit, then chronological
    total = mongo.db.chat_messages.count_documents({'tracker_id': tracker_id})

    payload = []
    for m in serialize_doc(messages):
        media = serialize_media_ref(m.get('media') or m.get('file_url'))
        m.pop('file_url', None)
        m.pop('media', None)
        if media:
            m['file_url'] = media['url']   # field name kept for client compatibility
            m['media_inline'] = media.get('inline', False)
        payload.append(m)

    return jsonify({
        'messages': payload,
        'total': total,
        'incremental': bool(since),
        'chat_unlocked': is_chat_unlocked(tracker),
        'can_interact': can_interact
    })


@app.route('/api/trackers/<tracker_id>/chat/send', methods=['POST'])
@login_required
def api_send_chat_message(tracker_id):
    tracker = visible_tracker(tracker_id)
    if not tracker:
        return jsonify({'error': 'Tracker not found'}), 404

    user_role = session.get('role')
    if user_role == ROLE_FE and tracker.get('fe', {}).get('id') != session['user_id']:
        return jsonify({'error': 'Not your tracker'}), 403
    if user_role == ROLE_NS and tracker.get('noc_assignee') != session['user_id']:
        return jsonify({'error': 'Not assigned to you'}), 403

    if not can_write_chat(tracker):
        return jsonify({'error': 'Read-only access to this chat'}), 403

    if not is_chat_unlocked(tracker):
        return jsonify({'error': 'Chat is locked. Complete SIM activation and ZTP first.'}), 403

    data = request.json
    message_text = data.get('message', '').strip()
    message_type = data.get('type', 'text')
    file_url     = data.get('file_url')
    media        = data.get('media')          # {file_id, mime, size} from /chat/upload

    # A client that still posts an inline data URL gets it offloaded here rather
    # than stored in the document.
    if media is None and file_url and file_url.startswith('data:'):
        media = store_data_url(file_url, tracker_id=tracker_id, kind=message_type)
        if media:
            file_url = None
    try:
        duration = float(data.get('duration')) if data.get('duration') is not None else None
    except (TypeError, ValueError):
        duration = None

    if not message_text and not file_url and not media:
        return jsonify({'error': 'Message or file required'}), 400

    now = get_utc_now()
    sender_name = session.get('noc_name') or session.get('name') or session.get('username', 'User')
    message = {
        'tracker_id': tracker_id,
        'sender_id': session['user_id'],
        'sender_role': user_role,
        'sender_name': sender_name,
        'message': message_text,
        'type': message_type,
        'media': media,            # {file_id, mime, size} - served via /api/media/<id>
        'file_url': file_url,      # legacy inline fallback; None for new messages
        'duration': duration,      # seconds, audio only - see api_send_chat_message
        'timestamp': now,
        'read': False
    }

    result = mongo.db.chat_messages.insert_one(message)
    message['_id'] = result.inserted_id
    mongo.db.trackers.update_one({'_id': ObjectId(tracker_id)}, {'$set': {'updated_at': now}})
    
    # Broadcast message via Socket.IO for real-time delivery
    broadcast_chat_message(tracker_id, message)
    
    return jsonify({'success': True, 'message': serialize_doc(message)})


@app.route('/api/trackers/<tracker_id>/chat/upload', methods=['POST'])
@login_required
def api_upload_chat_file(tracker_id):
    tracker = visible_tracker(tracker_id)
    if not tracker:
        return jsonify({'error': 'Tracker not found'}), 404

    user_role = session.get('role')
    if user_role == ROLE_FE and tracker.get('fe', {}).get('id') != session['user_id']:
        return jsonify({'error': 'Not your tracker'}), 403
    if user_role == ROLE_NS and tracker.get('noc_assignee') != session['user_id']:
        return jsonify({'error': 'Not assigned to you'}), 403
    if not can_write_chat(tracker):
        return jsonify({'error': 'Read-only access to this chat'}), 403
    if not is_chat_unlocked(tracker):
        return jsonify({'error': 'Chat is locked'}), 403

    if 'file' not in request.files:
        return jsonify({'error': 'No file provided'}), 400

    file      = request.files['file']
    file_type = request.form.get('type', 'image')

    if file.filename == '':
        return jsonify({'error': 'No file selected'}), 400

    import base64
    from io import BytesIO

    file_data = file.read()

    if file_type == 'image':
        # Sanity check — reject HTML blobs masquerading as images
        if file_data[:5] in (b'<!DOC', b'<html') or b'<!DOCTYPE' in file_data[:100]:
            return jsonify({'error': 'Invalid file type. Please upload an image file.'}), 400
        try:
            from PIL import Image
            img = Image.open(BytesIO(file_data))
            if img.mode in ('RGBA', 'LA', 'P'):
                bg = Image.new('RGB', img.size, (255, 255, 255))
                if img.mode == 'P':
                    img = img.convert('RGBA')
                bg.paste(img, mask=img.split()[-1] if img.mode in ('RGBA', 'LA') else None)
                img = bg
            # Governed by MEDIA_PROFILE / IMAGE_MAX_DIM / IMAGE_QUALITY so the
            # fidelity-vs-bandwidth trade can be changed without a deploy.
            # IMAGE_MAX_DIM = 0 keeps the original dimensions.
            if IMAGE_MAX_DIM and max(img.size) > IMAGE_MAX_DIM:
                ratio = IMAGE_MAX_DIM / max(img.size)
                img = img.resize(tuple(int(d * ratio) for d in img.size), Image.Resampling.LANCZOS)
            out = BytesIO()
            img.save(out, format='JPEG', quality=IMAGE_QUALITY, optimize=True)
            file_data = out.getvalue()
            mime_type = 'image/jpeg'
        except ImportError:
            mime_type = file.content_type or 'image/jpeg'
        except Exception as e:
            print(f"[upload] image rejected: {e!r}")
            return jsonify({'error': 'Could not read that image. Try a JPEG or PNG photo.'}), 400
    elif file_type == 'audio':
        mime_type = file.content_type or 'audio/webm'
    else:
        mime_type = file.content_type or 'application/octet-stream'

    if len(file_data) > 10 * 1024 * 1024:
        return jsonify({'error': 'File too large. Use a smaller file.'}), 400

    mime_type = safe_media_type(mime_type)
    file_id = _gridfs().put(file_data, contentType=mime_type,
                            metadata={'tracker_id': tracker_id, 'kind': file_type})
    return jsonify({
        'success': True,
        'type': file_type,
        'media': {'file_id': str(file_id), 'mime': mime_type, 'size': len(file_data)},
        'file_url': media_url(file_id),    # what the client sets as src
    })


@app.route('/api/trackers/<tracker_id>/chat/mark-read', methods=['POST'])
@login_required
def api_mark_messages_read(tracker_id):
    tracker = visible_tracker(tracker_id)
    if not tracker:
        return jsonify({'error': 'Tracker not found'}), 404
    # Marking read changes the other side's unread badge, so only participants may.
    if not can_write_chat(tracker):
        return jsonify({'error': 'Read-only access to this chat'}), 403
    mongo.db.chat_messages.update_many(
        {'tracker_id': tracker_id, 'sender_role': {'$ne': session.get('role')}, 'read': False},
        {'$set': {'read': True}}
    )
    return jsonify({'success': True})


# ─── Analytics / KPI APIs ───────────────────────────────────────────────────

# Categorical palette (fixed order — see dataviz skill palette.md)
CHART_CATEGORICAL = ['#2a78d6', '#1baf7a', '#eda100', '#008300',
                      '#4a3aa7', '#e34948', '#e87ba4', '#eb6834']
# Status palette (reserved semantics — never reused as a plain series color)
CHART_STATUS_GOOD     = '#0ca30c'
CHART_STATUS_WARNING  = '#fab219'
CHART_STATUS_SERIOUS  = '#ec835a'
CHART_STATUS_CRITICAL = '#d03b3b'
CHART_MUTED = '#c3c2b7'


def _lighten_hex(hex_color, factor=0.35):
    """Mix a hex color toward white by `factor` (0-1) for a lighter tint."""
    hex_color = hex_color.lstrip('#')
    r, g, b = (int(hex_color[i:i + 2], 16) for i in (0, 2, 4))
    r = round(r + (255 - r) * factor)
    g = round(g + (255 - g) * factor)
    b = round(b + (255 - b) * factor)
    return f'#{r:02x}{g:02x}{b:02x}'


def get_date_range(range_type, custom_from=None, custom_to=None):
    now = get_utc_now()
    if range_type == 'today':
        return now.replace(hour=0, minute=0, second=0, microsecond=0), now
    elif range_type == 'yesterday':
        y = now - timedelta(days=1)
        return y.replace(hour=0, minute=0, second=0, microsecond=0), \
               y.replace(hour=23, minute=59, second=59, microsecond=999999)
    elif range_type == 'last7days':
        return (now - timedelta(days=7)).replace(hour=0, minute=0, second=0, microsecond=0), now
    elif range_type == 'lastmonth':
        return (now - timedelta(days=30)).replace(hour=0, minute=0, second=0, microsecond=0), now
    elif range_type == 'alltime':
        return datetime(2000, 1, 1), now
    elif range_type == 'custom' and custom_from and custom_to:
        return (datetime.fromisoformat(custom_from.replace('Z', '+00:00')).replace(tzinfo=None),
                datetime.fromisoformat(custom_to.replace('Z', '+00:00')).replace(tzinfo=None))
    return now.replace(hour=0, minute=0, second=0, microsecond=0), now


def duration_minutes(t_start, t_end):
    if t_start and t_end:
        return max(0, (t_end - t_start).total_seconds() / 60)
    return None


def calculate_stage_times(tracker):
    """Compute KPI durations from the dedicated stage_timestamps sub-document.
    Falls back to scanning events only for fields not yet stamped in older records."""
    ts = tracker.get('stage_timestamps', {})

    def _ts(key):
        """Return the datetime for a timestamp key, handling both datetime and string formats."""
        val = ts.get(key)
        if isinstance(val, str):
            return datetime.fromisoformat(val.rstrip('Z'))
        return val

    created_at  = tracker.get('created_at') or _ts('tracker_created_at')
    assigned_at = _ts('noc_assigned_at')
    sim1_start  = _ts('sim1_activation_started_at')
    sim1_done   = _ts('sim1_activation_done_at')
    sim2_start  = _ts('sim2_activation_started_at')
    sim2_done   = _ts('sim2_activation_done_at')
    ztp_config  = _ts('ztp_config_verified_at')
    ztp_start   = _ts('ztp_started_at')
    ztp_done    = _ts('ztp_done_at')
    coord_at    = _ts('ready_for_coordination_at')
    hso_sub_at  = _ts('hso_submitted_at')
    hso_done_at = _ts('hso_approved_at')
    complete_at = tracker.get('completed_at') or _ts('installation_complete_at')

    stage_times = {
        'queue_wait_minutes':         duration_minutes(created_at, assigned_at),
        'sim1_activation_minutes':    duration_minutes(sim1_start, sim1_done),
        'sim2_activation_minutes':    duration_minutes(sim2_start, sim2_done),
        'ztp_config_minutes':         duration_minutes(assigned_at, ztp_config),
        'ztp_execution_minutes':      duration_minutes(ztp_start, ztp_done),
        'ns_processing_minutes':      duration_minutes(assigned_at, coord_at),
        'hso_review_minutes':         duration_minutes(hso_sub_at, hso_done_at),
        'total_minutes':              duration_minutes(created_at, complete_at),
    }
    return stage_times


def _analytics_allowed():
    return session.get('role') in {ROLE_ANALYTICS, ROLE_NSG, ROLE_FSG}


@app.route('/api/NOC_SUPPORT_GROUP/kpi')
@app.route('/api/analytics/kpi')
@login_required
def api_analytics_kpi():
    if not _analytics_allowed():
        return jsonify({'error': 'Unauthorized'}), 403

    range_type  = request.args.get('range', 'today')
    custom_from = request.args.get('from')
    custom_to   = request.args.get('to')
    start, end  = get_date_range(range_type, custom_from, custom_to)

    started    = list(mongo.db.trackers.find({'created_at': {'$gte': start, '$lte': end}}, ANALYTICS_PROJECTION))
    completed  = list(mongo.db.trackers.find({'completed_at': {'$gte': start, '$lte': end}}, ANALYTICS_PROJECTION))
    in_progress = mongo.db.trackers.count_documents({'created_at': {'$lte': end}, 'completed_at': None, 'noc_assignee': {'$ne': None}})
    unassigned  = mongo.db.trackers.count_documents({'completed_at': None, 'noc_assignee': None})

    # Average completion time and full stage breakdown over completed trackers
    completion_hours = []
    stage_avgs = {
        'queue_wait_minutes': [],
        'sim1_activation_minutes': [],
        'sim2_activation_minutes': [],
        'ztp_config_minutes': [],
        'ztp_execution_minutes': [],
        'ns_processing_minutes': [],
        'hso_review_minutes': [],
    }

    for t in completed:
        if t.get('created_at') and t.get('completed_at'):
            completion_hours.append((t['completed_at'] - t['created_at']).total_seconds() / 3600)
        st = calculate_stage_times(t)
        for k in stage_avgs:
            if st.get(k) is not None:
                stage_avgs[k].append(st[k])

    def _avg(lst):
        return round(sum(lst) / len(lst), 1) if lst else None

    # SIM and ZTP quality metrics
    date_filter = {'created_at': {'$gte': start, '$lte': end}}
    sim1_fails = mongo.db.trackers.count_documents({**date_filter, 'sim.sim1.failure_reason': {'$ne': None}})
    sim2_fails = mongo.db.trackers.count_documents({**date_filter, 'sim.sim2.failure_reason': {'$ne': None}})
    ztp_fails  = mongo.db.trackers.count_documents({**date_filter, 'ztp.failure_reason': {'$ne': None}})
    ztp_by_fe  = mongo.db.trackers.count_documents({**date_filter, 'ztp.performed_by': 'FE'})
    ztp_by_ns  = mongo.db.trackers.count_documents({**date_filter, 'ztp.performed_by': 'NS'})
    hso_multi  = mongo.db.trackers.count_documents({**date_filter, 'hso.attempts.1': {'$exists': True}})

    # Completion rate
    completion_rate = round(len(completed) / len(started) * 100, 1) if started else 0

    avg_h = _avg(completion_hours)
    return jsonify({
        'total_started':          len(started),
        'total_completed':        len(completed),
        'completion_rate':        completion_rate,
        'avg_completion':         f"{avg_h}h" if avg_h else "-",
        'avg_completion_hours':   avg_h,
        'in_progress':            in_progress,
        'unassigned':             unassigned,
        'sim1_failure_count':     sim1_fails,
        'sim2_failure_count':     sim2_fails,
        'sim_failure_count':      sim1_fails + sim2_fails,  # backward compat
        'ztp_failure_count':      ztp_fails,
        'ztp_by_fe':              ztp_by_fe,
        'ztp_by_ns':              ztp_by_ns,
        'hso_multi_attempt':      hso_multi,
        'avg_queue_wait_min':     _avg(stage_avgs['queue_wait_minutes']),
        'avg_sim1_act_min':       _avg(stage_avgs['sim1_activation_minutes']),
        'avg_sim2_act_min':       _avg(stage_avgs['sim2_activation_minutes']),
        'avg_ztp_config_min':     _avg(stage_avgs['ztp_config_minutes']),
        'avg_ztp_exec_min':       _avg(stage_avgs['ztp_execution_minutes']),
        'avg_ns_processing_min':  _avg(stage_avgs['ns_processing_minutes']),
        'avg_hso_review_min':     _avg(stage_avgs['hso_review_minutes']),
    })


@app.route('/api/NOC_SUPPORT_GROUP/fe/overview')
@app.route('/api/analytics/fe/overview')
@login_required
def api_analytics_fe_overview():
    if not _analytics_allowed():
        return jsonify({'error': 'Unauthorized'}), 403
    range_type  = request.args.get('range', 'today')
    start, end  = get_date_range(range_type, request.args.get('from'), request.args.get('to'))
    trackers    = list(mongo.db.trackers.find({'created_at': {'$gte': start, '$lte': end}}, ANALYTICS_PROJECTION))

    day_data = {}
    fe_accounts = set()
    for t in trackers:
        fe_user = t.get('fe', {}).get('username', 'Unknown')
        fe_accounts.add(fe_user)
        day_key = t['created_at'].strftime('%Y-%m-%d')
        day_data.setdefault(day_key, {}).setdefault(fe_user, {'started': 0, 'completed': 0})
        day_data[day_key][fe_user]['started'] += 1
        if t.get('completed_at'):
            day_data[day_key][fe_user]['completed'] += 1

    sorted_days = sorted(day_data.keys())
    fe_accounts = sorted(fe_accounts)

    # Cap to the busiest accounts so the chart stays readable on wide ranges
    # (e.g. "All Time" can span 100+ distinct FE accounts) — fold the long
    # tail into "Other" instead of rendering one stack per account, which
    # made every bar sub-pixel wide and the chart look empty.
    totals = {fe: sum(day_data[d].get(fe, {}).get('started', 0) for d in sorted_days) for fe in fe_accounts}
    top_accounts = sorted(sorted(fe_accounts, key=lambda fe: totals[fe], reverse=True)[:8])
    top_set = set(top_accounts)
    other_accounts = [fe for fe in fe_accounts if fe not in top_set]
    display_accounts = top_accounts + (['Other'] if other_accounts else [])

    def _bucket_stats(day, fe_list):
        started = sum(day_data[day].get(fe, {}).get('started', 0) for fe in fe_list)
        completed = sum(day_data[day].get(fe, {}).get('completed', 0) for fe in fe_list)
        return started, completed

    colors = CHART_CATEGORICAL
    datasets = []
    for i, fe in enumerate(display_accounts):
        base_color = colors[i % len(colors)]
        fe_list = other_accounts if fe == 'Other' else [fe]
        stats = [_bucket_stats(d, fe_list) for d in sorted_days]
        datasets.append({'label': f'{fe} - Completed',
                         'data': [c for (_, c) in stats],
                         'backgroundColor': base_color, 'stack': fe})
        datasets.append({'label': f'{fe} - In Progress',
                         'data': [s - c for (s, c) in stats],
                         'backgroundColor': _lighten_hex(base_color, 0.45),
                         'stack': fe})
    return jsonify({'labels': sorted_days, 'datasets': datasets})


@app.route('/api/NOC_SUPPORT_GROUP/noc/overview')
@app.route('/api/analytics/noc/overview')
@login_required
def api_analytics_noc_overview():
    if not _analytics_allowed():
        return jsonify({'error': 'Unauthorized'}), 403
    range_type = request.args.get('range', 'today')
    start, end = get_date_range(range_type, request.args.get('from'), request.args.get('to'))
    trackers   = list(mongo.db.trackers.find({'created_at': {'$gte': start, '$lte': end}}, ANALYTICS_PROJECTION))

    day_data = {}
    for t in trackers:
        day_key = t['created_at'].strftime('%Y-%m-%d')
        day_data.setdefault(day_key, {'started': 0, 'completed': 0})
        day_data[day_key]['started'] += 1
        if t.get('completed_at'):
            day_data[day_key]['completed'] += 1

    sorted_days = sorted(day_data.keys())
    return jsonify({
        'labels': sorted_days,
        'datasets': [
            {'label': 'Completed',  'data': [day_data[d]['completed'] for d in sorted_days],
             'backgroundColor': CHART_STATUS_GOOD, 'stack': 'total'},
            {'label': 'In Progress','data': [day_data[d]['started'] - day_data[d]['completed'] for d in sorted_days],
             'backgroundColor': CHART_STATUS_WARNING, 'stack': 'total'},
        ]
    })


@app.route('/api/NOC_SUPPORT_GROUP/trend')
@app.route('/api/analytics/trend')
@login_required
def api_analytics_trend():
    if not _analytics_allowed():
        return jsonify({'error': 'Unauthorized'}), 403
    range_type = request.args.get('range', 'today')
    start, end = get_date_range(range_type, request.args.get('from'), request.args.get('to'))
    trackers   = list(mongo.db.trackers.find({'created_at': {'$gte': start, '$lte': end}}, ANALYTICS_PROJECTION))

    day_data = {}
    for t in trackers:
        day_key = t['created_at'].strftime('%Y-%m-%d')
        day_data.setdefault(day_key, {'started': 0, 'completed': 0, 'times': []})
        day_data[day_key]['started'] += 1
        if t.get('completed_at'):
            day_data[day_key]['completed'] += 1
            day_data[day_key]['times'].append((t['completed_at'] - t['created_at']).total_seconds() / 3600)

    sorted_days = sorted(day_data.keys())
    return jsonify({
        'labels': sorted_days,
        'datasets': [
            {'label': 'Started',   'data': [day_data[d]['started'] for d in sorted_days],
             'type': 'bar', 'backgroundColor': CHART_CATEGORICAL[0], 'yAxisID': 'y'},
            {'label': 'Completed', 'data': [day_data[d]['completed'] for d in sorted_days],
             'type': 'bar', 'backgroundColor': CHART_STATUS_GOOD, 'yAxisID': 'y'},
            {'label': 'Avg Completion (h)',
             'data': [round(sum(day_data[d]['times'])/len(day_data[d]['times']), 2)
                      if day_data[d]['times'] else 0 for d in sorted_days],
             'type': 'line', 'borderColor': CHART_CATEGORICAL[7], 'backgroundColor': 'transparent',
             'yAxisID': 'y1', 'tension': 0.4},
        ]
    })


@app.route('/api/analytics/stage-durations')
@login_required
def api_analytics_stage_durations():
    """Average time spent in each stage (for pipeline / funnel charts)."""
    if not _analytics_allowed():
        return jsonify({'error': 'Unauthorized'}), 403
    range_type = request.args.get('range', 'today')
    start, end = get_date_range(range_type, request.args.get('from'), request.args.get('to'))
    completed = list(mongo.db.trackers.find({'completed_at': {'$gte': start, '$lte': end}}, ANALYTICS_PROJECTION))

    stage_totals = {
        'Queue Wait': [], 'SIM1 Activation': [], 'SIM2 Activation': [],
        'ZTP Config': [], 'ZTP Execution': [], 'NS Processing': [], 'HSO Review': []
    }
    key_map = {
        'Queue Wait': 'queue_wait_minutes', 'SIM1 Activation': 'sim1_activation_minutes',
        'SIM2 Activation': 'sim2_activation_minutes', 'ZTP Config': 'ztp_config_minutes',
        'ZTP Execution': 'ztp_execution_minutes', 'NS Processing': 'ns_processing_minutes',
        'HSO Review': 'hso_review_minutes'
    }
    for t in completed:
        st = calculate_stage_times(t)
        for label, key in key_map.items():
            if st.get(key) is not None:
                stage_totals[label].append(st[key])

    def _avg(lst):
        return round(sum(lst) / len(lst), 1) if lst else 0

    labels = list(stage_totals.keys())
    values = [_avg(stage_totals[l]) for l in labels]
    # Ordinal ramp (pipeline progresses stage-by-stage) — single hue, light -> dark
    colors = ['#9ec5f4', '#6da7ec', '#5598e7', '#3987e5', '#2a78d6', '#1c5cab', '#104281']

    return jsonify({
        'labels': labels,
        'datasets': [{
            'label': 'Avg Duration (min)',
            'data': values,
            'backgroundColor': colors,
        }]
    })


@app.route('/api/analytics/status-distribution')
@login_required
def api_analytics_status_distribution():
    """Current tracker status distribution (for pie/doughnut chart)."""
    if not _analytics_allowed():
        return jsonify({'error': 'Unauthorized'}), 403

    pipeline = [
        {'$group': {'_id': '$status', 'count': {'$sum': 1}}},
        {'$sort': {'count': -1}}
    ]
    results = list(mongo.db.trackers.aggregate(pipeline))

    status_labels = {
        STATUS_WAITING_NOC: 'Waiting NOC',
        STATUS_NOC_WORKING: 'NOC Working',
        STATUS_ZTP_PULL_PENDING: 'ZTP Pull Pending',
        STATUS_ZTP_CONFIG_UNVERIFIED: 'ZTP Config Unverified',
        STATUS_ZTP_PULL_DONE_FE: 'ZTP Pull Done (FE)',
        STATUS_ZTP_PULL_UNVERIFIED: 'ZTP Pull Unverified',
        STATUS_ZTP_PULL_REQ_NOC: 'ZTP Requested NOC',
        STATUS_FE_REQ_ZTP: 'FE Requested ZTP',
        STATUS_READY_COORD: 'Ready for Coordination',
        STATUS_HSO_SUBMITTED: 'HSO Submitted',
        STATUS_HSO_REJECTED: 'HSO Rejected',
        STATUS_COMPLETE: 'Completed',
    }
    colors = CHART_CATEGORICAL + [CHART_STATUS_WARNING, CHART_STATUS_SERIOUS,
                                   CHART_STATUS_CRITICAL, CHART_STATUS_GOOD]

    labels = [status_labels.get(r['_id'], r['_id']) for r in results]
    values = [r['count'] for r in results]

    return jsonify({
        'labels': labels,
        'datasets': [{
            'data': values,
            'backgroundColor': colors[:len(values)],
        }]
    })


@app.route('/api/analytics/ztp-breakdown')
@login_required
def api_analytics_ztp_breakdown():
    """ZTP performed by FE vs NS breakdown (for pie chart)."""
    if not _analytics_allowed():
        return jsonify({'error': 'Unauthorized'}), 403
    range_type = request.args.get('range', 'today')
    start, end = get_date_range(range_type, request.args.get('from'), request.args.get('to'))
    date_filter = {'created_at': {'$gte': start, '$lte': end}}

    by_fe = mongo.db.trackers.count_documents({**date_filter, 'ztp.performed_by': 'FE'})
    by_ns = mongo.db.trackers.count_documents({**date_filter, 'ztp.performed_by': 'NS'})
    pending = mongo.db.trackers.count_documents({**date_filter, 'ztp.performed_by': None, 'status': {'$ne': STATUS_COMPLETE}})

    return jsonify({
        'labels': ['ZTP by FE', 'ZTP by NOC', 'Pending'],
        'datasets': [{
            'data': [by_fe, by_ns, pending],
            'backgroundColor': [CHART_CATEGORICAL[0], CHART_CATEGORICAL[4], CHART_MUTED],
        }]
    })


@app.route('/api/analytics/sim-performance')
@login_required
def api_analytics_sim_performance():
    """SIM activation success vs failure rates."""
    if not _analytics_allowed():
        return jsonify({'error': 'Unauthorized'}), 403
    range_type = request.args.get('range', 'today')
    start, end = get_date_range(range_type, request.args.get('from'), request.args.get('to'))
    date_filter = {'created_at': {'$gte': start, '$lte': end}}

    sim1_total = mongo.db.trackers.count_documents({**date_filter, 'sim.sim1.status': {'$ne': 'not_required'}})
    sim1_ok = mongo.db.trackers.count_documents({**date_filter, 'sim.sim1.status': {'$in': ['activation_complete_manual', 'activation_complete_preactivated']}})
    sim1_fail = mongo.db.trackers.count_documents({**date_filter, 'sim.sim1.failure_reason': {'$ne': None}})
    sim1_pending = sim1_total - sim1_ok - sim1_fail

    sim2_total = mongo.db.trackers.count_documents({**date_filter, 'sim.sim2.status': {'$ne': 'not_required'}})
    sim2_ok = mongo.db.trackers.count_documents({**date_filter, 'sim.sim2.status': {'$in': ['activation_complete_manual', 'activation_complete_preactivated']}})
    sim2_fail = mongo.db.trackers.count_documents({**date_filter, 'sim.sim2.failure_reason': {'$ne': None}})
    sim2_pending = sim2_total - sim2_ok - sim2_fail

    return jsonify({
        'sim1': {'total': sim1_total, 'success': sim1_ok, 'failed': sim1_fail, 'pending': sim1_pending},
        'sim2': {'total': sim2_total, 'success': sim2_ok, 'failed': sim2_fail, 'pending': sim2_pending},
        'labels': ['SIM1 Success', 'SIM1 Failed', 'SIM1 Pending', 'SIM2 Success', 'SIM2 Failed', 'SIM2 Pending'],
        'datasets': [{
            'label': 'SIM Performance',
            'data': [sim1_ok, sim1_fail, sim1_pending, sim2_ok, sim2_fail, sim2_pending],
            'backgroundColor': [CHART_STATUS_GOOD, CHART_STATUS_CRITICAL, CHART_MUTED,
                                 CHART_STATUS_GOOD, CHART_STATUS_CRITICAL, CHART_MUTED],
        }]
    })


@app.route('/api/analytics/sim-provider-performance')
@login_required
def api_analytics_sim_provider_performance():
    """SIM activation stats broken down by provider (Airtel, Jio, VI, BSNL)."""
    if not _analytics_allowed():
        return jsonify({'error': 'Unauthorized'}), 403
    range_type = request.args.get('range', 'today')
    start, end = get_date_range(range_type, request.args.get('from'), request.args.get('to'))
    date_filter = {'created_at': {'$gte': start, '$lte': end}}

    PROVIDERS = ['Airtel', 'Jio', 'VI', 'BSNL']
    SUCCESS_STATUSES = ['activation_complete_manual', 'activation_complete_preactivated']

    def agg_by_provider(sim_key):
        """Return {provider: {total, success, failed}} via a single aggregation."""
        pipeline = [
            {'$match': {**date_filter, f'sim.{sim_key}.status': {'$ne': 'not_required'},
                        f'sim.{sim_key}.provider': {'$in': PROVIDERS}}},
            {'$group': {
                '_id': f'$sim.{sim_key}.provider',
                'total': {'$sum': 1},
                'success': {'$sum': {'$cond': {
                    'if': {'$in': [f'$sim.{sim_key}.status', SUCCESS_STATUSES]},
                    'then': 1, 'else': 0
                }}},
                'failed': {'$sum': {'$cond': {
                    'if': {'$and': [
                        {'$ne': [f'$sim.{sim_key}.failure_reason', None]},
                        {'$ne': [f'$sim.{sim_key}.failure_reason', '']}
                    ]},
                    'then': 1, 'else': 0
                }}}
            }}
        ]
        return {row['_id']: row for row in mongo.db.trackers.aggregate(pipeline)}

    sim1_stats = agg_by_provider('sim1')
    sim2_stats = agg_by_provider('sim2')

    result = {}
    for p in PROVIDERS:
        s1 = sim1_stats.get(p, {'total': 0, 'success': 0, 'failed': 0})
        s2 = sim2_stats.get(p, {'total': 0, 'success': 0, 'failed': 0})
        total   = s1['total']   + s2['total']
        success = s1['success'] + s2['success']
        failed  = s1['failed']  + s2['failed']
        result[p] = {
            'total':   total,
            'success': success,
            'failed':  failed,
            'pending': max(0, total - success - failed),
        }

    return jsonify({'providers': PROVIDERS, 'data': result})


@app.route('/api/NOC_SUPPORT_GROUP/fe/day/<date>')
@app.route('/api/analytics/fe/day/<date>')
@login_required
def api_analytics_fe_day(date):
    if not _analytics_allowed():
        return jsonify({'error': 'Unauthorized'}), 403
    try:
        day_start = datetime.strptime(date, '%Y-%m-%d')
        day_end   = day_start + timedelta(days=1)
    except ValueError:
        return jsonify({'error': 'Invalid date format'}), 400

    trackers = list(mongo.db.trackers.find({'created_at': {'$gte': day_start, '$lt': day_end}}).sort('created_at', 1))
    timeline_data = []
    for t in trackers:
        noc_id   = t.get('noc_assignee')
        noc_name = None
        if noc_id:
            u = mongo.db.users.find_one({'_id': ObjectId(noc_id)})
            noc_name = u.get('name', u.get('username')) if u else None
        stage_times = calculate_stage_times(t)
        timeline_data.append({
            'tracker_id': t.get('tracker_id'),
            'sdwan_id':   t.get('sdwan_id'),
            'customer':   t.get('customer'),
            'fe_name':    t.get('fe', {}).get('name'),
            'fe_username': t.get('fe', {}).get('username'),
            'fe_phone':   t.get('fe', {}).get('phone'),
            'noc_assignee': noc_name,
            'status':      t.get('status'),
            'created_at':  t['created_at'].isoformat() if t.get('created_at') else None,
            'completed_at': t['completed_at'].isoformat() if t.get('completed_at') else None,
            'stage_times': stage_times,
            'events': [{'stage': e.get('stage'), 'timestamp': e['timestamp'].isoformat(), 'remarks': e.get('remarks')}
                       for e in t.get('events', []) if isinstance(e.get('timestamp'), datetime)]
        })
    return jsonify({'date': date, 'trackers': timeline_data})


@app.route('/api/NOC_SUPPORT_GROUP/noc/day/<date>')
@app.route('/api/analytics/noc/day/<date>')
@login_required
def api_analytics_noc_day(date):
    if not _analytics_allowed():
        return jsonify({'error': 'Unauthorized'}), 403
    try:
        day_start = datetime.strptime(date, '%Y-%m-%d')
        day_end   = day_start + timedelta(days=1)
    except ValueError:
        return jsonify({'error': 'Invalid date format'}), 400

    trackers = list(mongo.db.trackers.find({'created_at': {'$gte': day_start, '$lt': day_end}}, ANALYTICS_PROJECTION))
    noc_data = {}
    for t in trackers:
        noc_id = t.get('noc_assignee')
        if noc_id:
            u = mongo.db.users.find_one({'_id': ObjectId(noc_id)})
            noc_name = u.get('name', u.get('username')) if u else 'Unknown'
        else:
            noc_id, noc_name = 'unassigned', 'Unassigned'
        key = f"{noc_id}|{noc_name}"
        noc_data.setdefault(key, {'noc_id': noc_id, 'noc_name': noc_name, 'started': 0, 'completed': 0})
        noc_data[key]['started'] += 1
        if t.get('completed_at'):
            noc_data[key]['completed'] += 1

    keys       = sorted(noc_data.keys())
    noc_labels = [noc_data[k]['noc_name']  for k in keys]
    noc_ids    = [noc_data[k]['noc_id']    for k in keys]
    return jsonify({
        'date': date,
        'labels': noc_labels,
        'noc_ids': noc_ids,
        'datasets': [
            {'label': 'Started',   'data': [noc_data[k]['started']   for k in keys], 'backgroundColor': CHART_CATEGORICAL[0]},
            {'label': 'Completed', 'data': [noc_data[k]['completed'] for k in keys], 'backgroundColor': CHART_STATUS_GOOD},
        ]
    })


@app.route('/api/NOC_SUPPORT_GROUP/noc/user/<user_id>/day/<date>')
@app.route('/api/analytics/noc/user/<user_id>/day/<date>')
@login_required
def api_analytics_noc_user_day(user_id, date):
    if not _analytics_allowed():
        return jsonify({'error': 'Unauthorized'}), 403
    try:
        day_start = datetime.strptime(date, '%Y-%m-%d')
        day_end   = day_start + timedelta(days=1)
    except ValueError:
        return jsonify({'error': 'Invalid date format'}), 400

    u = mongo.db.users.find_one({'_id': ObjectId(user_id)})
    noc_name = u.get('name', u.get('username')) if u else 'Unknown'
    trackers = list(mongo.db.trackers.find({'created_at': {'$gte': day_start, '$lt': day_end},
                                            'noc_assignee': user_id}).sort('created_at', 1))
    timeline_data = []
    for t in trackers:
        st = calculate_stage_times(t)
        timeline_data.append({
            'tracker_id': t.get('tracker_id'),
            'sdwan_id':   t.get('sdwan_id'),
            'customer':   t.get('customer'),
            'fe_name':    t.get('fe', {}).get('name'),
            'status':     t.get('status'),
            'created_at': t['created_at'].isoformat() if t.get('created_at') else None,
            'completed_at': t['completed_at'].isoformat() if t.get('completed_at') else None,
            'stage_times': st,
            'events': [{'stage': e.get('stage'), 'timestamp': e['timestamp'].isoformat(), 'remarks': e.get('remarks')}
                       for e in t.get('events', []) if isinstance(e.get('timestamp'), datetime)]
        })
    return jsonify({'date': date, 'noc_name': noc_name, 'trackers': timeline_data})


@app.route('/api/NOC_SUPPORT_GROUP/export/fe')
@app.route('/api/analytics/export/fe')
@login_required
def api_analytics_export_fe():
    if not _analytics_allowed():
        return jsonify({'error': 'Unauthorized'}), 403
    try:
        from io import BytesIO
        import openpyxl
        from openpyxl.styles import Font, PatternFill, Alignment

        range_type = request.args.get('range', 'today')
        start, end = get_date_range(range_type, request.args.get('from'), request.args.get('to'))
        trackers   = list(mongo.db.trackers.find({'created_at': {'$gte': start, '$lte': end}}, ANALYTICS_PROJECTION).sort('created_at', 1))

        wb = openpyxl.Workbook()
        ws = wb.active
        ws.title = "FE Analytics"

        headers = ['SDWAN ID','Customer','FE Name','FE Username','FE Phone','NOC Assignee',
                   'Status','Created At','Completed At','Duration (hours)',
                   'Queue Wait (min)','SIM1 Act (min)','NS Processing (min)','ZTP Exec (min)',
                   'ZTP Performed By','HSO Attempts','SIM1 Failed','ZTP Failed']
        ws.append(headers)
        hfill = PatternFill(start_color='1A56A0', end_color='1A56A0', fill_type='solid')
        for cell in ws[1]:
            cell.fill = hfill
            cell.font = Font(bold=True, color='FFFFFF')
            cell.alignment = Alignment(horizontal='center')

        for t in trackers:
            created   = t.get('created_at')
            completed = t.get('completed_at')
            duration  = round((completed - created).total_seconds() / 3600, 2) if created and completed else ''
            noc_id    = t.get('noc_assignee')
            noc_name  = ''
            if noc_id:
                u = mongo.db.users.find_one({'_id': ObjectId(noc_id)})
                noc_name = u.get('name', u.get('username', '')) if u else ''
            st  = calculate_stage_times(t)
            ztp = t.get('ztp', {})
            hso = t.get('hso', {})
            ws.append([
                t.get('sdwan_id',''), t.get('customer',''),
                t.get('fe',{}).get('name',''), t.get('fe',{}).get('username',''), t.get('fe',{}).get('phone',''),
                noc_name, t.get('status',''),
                created.strftime('%Y-%m-%d %H:%M:%S') if created else '',
                completed.strftime('%Y-%m-%d %H:%M:%S') if completed else '',
                duration,
                round(st['queue_wait_minutes'], 1) if st.get('queue_wait_minutes') is not None else '',
                round(st['sim1_activation_minutes'], 1) if st.get('sim1_activation_minutes') is not None else '',
                round(st['ns_processing_minutes'], 1) if st.get('ns_processing_minutes') is not None else '',
                round(st['ztp_execution_minutes'], 1) if st.get('ztp_execution_minutes') is not None else '',
                ztp.get('performed_by', ''),
                len(hso.get('attempts', [])),
                'Yes' if t.get('sim',{}).get('sim1',{}).get('failure_reason') else 'No',
                'Yes' if ztp.get('failure_reason') else 'No',
            ])

        for col in ws.columns:
            ws.column_dimensions[col[0].column_letter].width = min(max(len(str(c.value or '')) for c in col) + 2, 50)

        out = BytesIO()
        wb.save(out)
        out.seek(0)
        return send_file(out,
                         mimetype='application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
                         as_attachment=True,
                         download_name=f'fe_analytics_{range_type}_{datetime.now().strftime("%Y%m%d")}.xlsx')
    except ImportError:
        return jsonify({'error': 'openpyxl not installed. Run: pip install openpyxl'}), 500
    except Exception as e:
        print(f"[error] {request.method} {request.path}: {e!r}")
        return jsonify({'error': 'Internal server error'}), 500


@app.route('/api/NOC_SUPPORT_GROUP/export/noc')
@app.route('/api/analytics/export/noc')
@login_required
def api_analytics_export_noc():
    if not _analytics_allowed():
        return jsonify({'error': 'Unauthorized'}), 403
    try:
        from io import BytesIO
        import openpyxl
        from openpyxl.styles import Font, PatternFill, Alignment

        range_type = request.args.get('range', 'today')
        start, end = get_date_range(range_type, request.args.get('from'), request.args.get('to'))
        trackers   = list(mongo.db.trackers.find({'created_at': {'$gte': start, '$lte': end}}, ANALYTICS_PROJECTION).sort('created_at', 1))

        wb = openpyxl.Workbook()
        ws = wb.active
        ws.title = "NOC Analytics"

        headers = ['SDWAN ID','Customer','FE Name','NOC Assignee','Status',
                   'Created At','NOC Assigned At','Completed At',
                   'Queue Wait (min)','NS Processing (min)','ZTP Performed By','Total Duration (h)']
        ws.append(headers)
        hfill = PatternFill(start_color='7C3AED', end_color='7C3AED', fill_type='solid')
        for cell in ws[1]:
            cell.fill = hfill
            cell.font = Font(bold=True, color='FFFFFF')
            cell.alignment = Alignment(horizontal='center')

        for t in trackers:
            created   = t.get('created_at')
            completed = t.get('completed_at')
            noc_id    = t.get('noc_assignee')
            noc_name  = ''
            if noc_id:
                u = mongo.db.users.find_one({'_id': ObjectId(noc_id)})
                noc_name = u.get('name', u.get('username', '')) if u else ''
            st = calculate_stage_times(t)
            assigned_at = t.get('stage_timestamps', {}).get('noc_assigned_at')
            ws.append([
                t.get('sdwan_id',''), t.get('customer',''),
                t.get('fe',{}).get('name',''), noc_name, t.get('status',''),
                created.strftime('%Y-%m-%d %H:%M:%S') if created else '',
                assigned_at.strftime('%Y-%m-%d %H:%M:%S') if isinstance(assigned_at, datetime) else '',
                completed.strftime('%Y-%m-%d %H:%M:%S') if completed else '',
                round(st['queue_wait_minutes'], 1) if st.get('queue_wait_minutes') is not None else '',
                round(st['ns_processing_minutes'], 1) if st.get('ns_processing_minutes') is not None else '',
                t.get('ztp',{}).get('performed_by',''),
                round((completed - created).total_seconds()/3600, 2) if created and completed else '',
            ])

        for col in ws.columns:
            ws.column_dimensions[col[0].column_letter].width = min(max(len(str(c.value or '')) for c in col) + 2, 50)

        out = BytesIO()
        wb.save(out)
        out.seek(0)
        return send_file(out,
                         mimetype='application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
                         as_attachment=True,
                         download_name=f'noc_analytics_{range_type}_{datetime.now().strftime("%Y%m%d")}.xlsx')
    except ImportError:
        return jsonify({'error': 'openpyxl not installed. Run: pip install openpyxl'}), 500
    except Exception as e:
        print(f"[error] {request.method} {request.path}: {e!r}")
        return jsonify({'error': 'Internal server error'}), 500


# ─── Admin: User Management ─────────────────────────────────────────────────
# Separate password-gated admin panel for managing users (create / update).
# Admin session is tracked independently of the regular user session.

ADMIN_PASSWORD = os.environ.get('ADMIN_PASSWORD', 'qwerty')

# Role → human label mapping for display
ROLE_LABELS = {
    ROLE_FE:        'Field Engineer',
    ROLE_FEG:       'Field Engineer Group',
    ROLE_FS:        'Field Support',
    ROLE_FSG:       'Field Support Group',
    ROLE_NS:        'NOC Support',
    ROLE_NSG:       'NOC Support Group',
    ROLE_ANALYTICS: 'Analytics',
}

# Fields that are relevant for each role (used by the frontend to show/hide inputs)
ROLE_FIELDS = {
    ROLE_FE:  ['name', 'username', 'password', 'zone', 'region', 'state',
               'field_engineer_group', 'field_support', 'email', 'contact', 'location'],
    ROLE_FEG: ['name', 'username', 'password', 'zone', 'region', 'state', 'field_support'],
    ROLE_FS:  ['name', 'username', 'password', 'zone', 'region', 'field_support_group'],
    ROLE_FSG: ['name', 'username', 'password', 'zone'],
    ROLE_NS:  ['name', 'username', 'password'],
    ROLE_NSG: ['name', 'username', 'password'],
    ROLE_ANALYTICS: ['name', 'username', 'password'],
}


def admin_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if not session.get('admin_authenticated'):
            return jsonify({'error': 'Admin authentication required'}), 403
        return f(*args, **kwargs)
    return decorated


@app.route('/admin')
def admin_page():
    return render_template('admin_users.html',
                           role_labels=ROLE_LABELS,
                           role_fields=ROLE_FIELDS,
                           all_roles=list(ROLE_LABELS.keys()))


@app.route('/admin/auth', methods=['POST'])
def admin_auth():
    data = request.json or {}
    if data.get('password') == ADMIN_PASSWORD:
        session['admin_authenticated'] = True
        return jsonify({'success': True})
    return jsonify({'success': False, 'error': 'Incorrect password'}), 401


@app.route('/admin/logout', methods=['POST'])
def admin_logout():
    session.pop('admin_authenticated', None)
    return jsonify({'success': True})


@app.route('/admin/api/users', methods=['GET'])
@admin_required
def admin_list_users():
    users = list(mongo.db.users.find({}, {'password': 0}))
    for u in users:
        u['_id'] = str(u['_id'])
    return jsonify(users)


@app.route('/admin/api/users', methods=['POST'])
@admin_required
def admin_create_user():
    data = request.json or {}
    role = data.get('role')
    if role not in ROLE_LABELS:
        return jsonify({'error': 'Invalid role'}), 400

    name = (data.get('name') or '').strip()
    username = (data.get('username') or '').strip()
    password = data.get('password', '')

    if not name:
        return jsonify({'error': 'Name is required'}), 400
    if not password:
        return jsonify({'error': 'Password is required'}), 400

    # username defaults to name if not provided
    if not username:
        username = name

    # Prevent duplicate usernames
    if mongo.db.users.find_one({'username': username}):
        return jsonify({'error': f'Username "{username}" already exists'}), 409

    doc = {
        'name':     name,
        'username': username,
        'password': generate_password_hash(password),
        'role':     role,
        'created_at': get_utc_now(),
    }
    # Optional role-specific fields
    for field in ['zone', 'region', 'state', 'field_engineer_group', 'field_support',
                  'field_support_group', 'email', 'contact', 'location']:
        val = (data.get(field) or '').strip()
        if val:
            doc[field] = val

    result = mongo.db.users.insert_one(doc)
    return jsonify({'success': True, 'id': str(result.inserted_id)}), 201


@app.route('/admin/api/users/<user_id>', methods=['PUT'])
@admin_required
def admin_update_user(user_id):
    data = request.json or {}
    try:
        oid = ObjectId(user_id)
    except Exception:
        return jsonify({'error': 'Invalid user ID'}), 400

    user = mongo.db.users.find_one({'_id': oid})
    if not user:
        return jsonify({'error': 'User not found'}), 404

    set_ops = {}

    # Name
    name = (data.get('name') or '').strip()
    if name:
        set_ops['name'] = name

    # Username — check uniqueness if changed
    username = (data.get('username') or '').strip()
    if username and username != user.get('username'):
        if mongo.db.users.find_one({'username': username, '_id': {'$ne': oid}}):
            return jsonify({'error': f'Username "{username}" already exists'}), 409
        set_ops['username'] = username

    # Password - only update if provided. Changing it revokes every existing
    # session for the account (session_user_valid compares session_epoch).
    password = data.get('password', '')
    revoke = False
    if password:
        set_ops['password'] = generate_password_hash(password)
        revoke = True

    # Deactivation locks the account out of login and ends its sessions.
    if 'active' in data:
        set_ops['active'] = bool(data['active'])
        revoke = revoke or not set_ops['active']

    # Optional fields
    for field in ['zone', 'region', 'state', 'field_engineer_group', 'field_support',
                  'field_support_group', 'email', 'contact', 'location']:
        if field in data:
            set_ops[field] = (data[field] or '').strip()

    if not set_ops:
        return jsonify({'error': 'No changes provided'}), 400

    set_ops['updated_at'] = get_utc_now()
    update = {'$set': set_ops}
    if revoke:
        update['$inc'] = {'session_epoch': 1}
    mongo.db.users.update_one({'_id': oid}, update)
    return jsonify({'success': True})


# ─── Socket.IO Event Handlers ───────────────────────────────────────────────
# These handlers manage real-time WebSocket connections for instant updates

@socketio.on('connect')
def handle_connect():
    """Client connected to WebSocket"""
    print(f"Client connected: {request.sid}")

@socketio.on('disconnect')
def handle_disconnect():
    """Client disconnected from WebSocket"""
    print(f"Client disconnected: {request.sid}")

@socketio.on('join_tracker')
def handle_join_tracker(data):
    """User joins a tracker room to receive real-time updates for that tracker"""
    tracker_id = data.get('tracker_id')
    if tracker_id:
        join_room(f"tracker_{tracker_id}")
        print(f"Client {request.sid} joined tracker_{tracker_id}")

@socketio.on('leave_tracker')
def handle_leave_tracker(data):
    """User leaves a tracker room"""
    tracker_id = data.get('tracker_id')
    if tracker_id:
        leave_room(f"tracker_{tracker_id}")
        print(f"Client {request.sid} left tracker_{tracker_id}")

@socketio.on('join_dashboard')
def handle_join_dashboard(data):
    """User joins their dashboard room to receive tracker list updates"""
    user_id = data.get('user_id')
    role = data.get('role')
    if user_id and role:
        # Join role-specific room for dashboard updates
        join_room(f"dashboard_{role}")
        join_room(f"user_{user_id}")
        print(f"Client {request.sid} joined dashboard_{role} and user_{user_id}")

@socketio.on('leave_dashboard')
def handle_leave_dashboard(data):
    """User leaves dashboard room"""
    user_id = data.get('user_id')
    role = data.get('role')
    if user_id and role:
        leave_room(f"dashboard_{role}")
        leave_room(f"user_{user_id}")
        print(f"Client {request.sid} left dashboard_{role} and user_{user_id}")


# ─── Helper Functions for Broadcasting ──────────────────────────────────────
def broadcast_tracker_update(tracker_id, event_type, data, include_full_tracker=True):
    """
    Broadcast tracker updates with optional complete tracker data
    
    Args:
        tracker_id: Tracker ID
        event_type: Type of event (e.g., 'ztp_status_updated')
        data: Partial data (for backward compatibility)
        include_full_tracker: If True, fetch and include complete tracker
    """
    payload = {
        'tracker_id': tracker_id,
        'event_type': event_type,
        'data': data,
        'timestamp': datetime.utcnow().isoformat() + 'Z'
    }
    
    # Include complete tracker data if enabled and mode supports it
    if include_full_tracker and SOCKET_INCLUDE_FULL_DATA and REALTIME_MODE in ('socket', 'hybrid'):
        try:
            tracker = mongo.db.trackers.find_one({'_id': ObjectId(tracker_id)})
            if tracker:
                payload['tracker'] = serialize_doc(tracker)
                print(f"[Socket.IO] Broadcasting tracker_update with full data: tracker_id={tracker_id}, event_type={event_type}")
            else:
                print(f"[Socket.IO] Broadcasting tracker_update (tracker not found): tracker_id={tracker_id}, event_type={event_type}")
        except Exception as e:
            print(f"[Socket.IO] Error fetching tracker for broadcast: {e}")
            print(f"[Socket.IO] Broadcasting tracker_update without full data: tracker_id={tracker_id}, event_type={event_type}")
    else:
        print(f"[Socket.IO] Broadcasting tracker_update: tracker_id={tracker_id}, event_type={event_type}")
    
    socketio.emit('tracker_update', payload, room=f"tracker_{tracker_id}")

def broadcast_chat_message(tracker_id, message):
    """Broadcast a new chat message to everyone in the tracker room.

    Media goes out as a /api/media/<id> URL, never as bytes - a broadcast reaches
    every connected client, so inlining a voice note here multiplied it by the
    room size.
    """
    payload = serialize_doc(dict(message))
    ref = serialize_media_ref(payload.get('media') or payload.get('file_url'))
    payload.pop('media', None)
    payload.pop('file_url', None)
    if ref:
        payload['file_url'] = ref['url']
        payload['media_inline'] = ref.get('inline', False)
    socketio.emit('new_chat_message', {
        'tracker_id': tracker_id,
        'message': payload,
    }, room=f"tracker_{tracker_id}")

def broadcast_dashboard_update(role, event_type, data):
    """Broadcast dashboard updates to all users of a specific role"""
    print(f"[Socket.IO] Broadcasting dashboard_update: role={role}, event_type={event_type}")
    socketio.emit('dashboard_update', {
        'event_type': event_type,
        'data': data
    }, room=f"dashboard_{role}")

def broadcast_to_user(user_id, event_type, data):
    """Broadcast notification to a specific user"""
    socketio.emit('user_notification', {
        'event_type': event_type,
        'data': data
    }, room=f"user_{user_id}")


# Seed the tracker-id counters as soon as the app object exists, so it happens
# under gunicorn too - not only when this file is run directly.
with app.app_context():
    bootstrap_tracker_counters()
    ensure_security_indexes()


if __name__ == '__main__':
    # Development entry point only. This is the Werkzeug dev server; see the
    # SocketIO configuration above for how to run this in production.
    if SOCKETIO_ASYNC_MODE == 'threading' and not FLASK_DEBUG:
        print('[warning] async_mode=threading is the development server. '
              'Set SOCKETIO_ASYNC_MODE=gevent and SOCKETIO_MESSAGE_QUEUE for production.')
    if SOCKETIO_MESSAGE_QUEUE is None:
        print('[warning] no SOCKETIO_MESSAGE_QUEUE: safe for a single process only. '
              'Adding workers without it silently breaks Socket.IO broadcasts.')
    debug = FLASK_DEBUG
    port = int(os.environ.get('PORT', 5001))
    socketio.run(app, debug=debug, host='0.0.0.0', port=port)

