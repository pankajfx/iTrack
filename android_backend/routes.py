"""Mobile-only API blueprint (/api/android/*) for the Flutter FE app.

Design constraints (see android/docs/ARCHITECTURE.md):
- Zero coupling to app.py: no imports from it (avoids circular imports).
  Role strings and the tiny serializer below intentionally duplicate app.py
  equivalents; they must stay in sync with the canonical constants there.
- Read-only: this blueprint never writes to trackers/users/chat collections.
  All mutating operations go through the existing /api/* routes.
- Unlike the web app's login_required (302 redirect to /login), auth failures
  here return JSON 401 so the mobile client gets a machine-readable signal.
"""
from datetime import datetime, timezone
from functools import wraps

from flask import Blueprint, jsonify, session

from android_backend.form_defaults import DEFAULT_FORM_OPTIONS

APP_NAME = 'iTrack'
MIN_APP_VERSION = '1.0.0'

# Mirrors ROLE_FE in app.py — the only role allowed to use FE mutation flows.
ROLE_FE = 'FIELD_ENGINEER'
# Mirrors FE_ROLES in app.py — roles allowed to view FE data (read-only for non-FE).
FE_ROLES = frozenset({
    'FIELD_ENGINEER', 'FIELD_ENGINEER_GROUP',
    'FIELD_SUPPORT', 'FIELD_SUPPORT_GROUP',
})

android_bp = Blueprint('android_api', __name__, url_prefix='/api/android')

_mongo = None  # set by register_android_api


def get_utc_now():
    """Naive UTC datetime — same storage convention as app.py."""
    return datetime.now(timezone.utc).replace(tzinfo=None)


def android_login_required(f):
    """Session guard returning JSON 401 (never the web app's 302 redirect)."""
    @wraps(f)
    def decorated(*args, **kwargs):
        if 'user_id' not in session:
            return jsonify({
                'success': False,
                'error': 'authentication_required',
                'message': 'Not logged in or session expired',
            }), 401
        return f(*args, **kwargs)
    return decorated


@android_bp.route('/ping', methods=['GET'])
def ping():
    """Unauthenticated connectivity check for the app's Server Setup screen."""
    return jsonify({
        'success': True,
        'app': APP_NAME,
        'server_time': get_utc_now().isoformat() + 'Z',
        'min_app_version': MIN_APP_VERSION,
    })


@android_bp.route('/me', methods=['GET'])
@android_login_required
def me():
    """Return the logged-in user's session profile.

    The web login response only returns {success, role}; templates receive the
    rest server-side. The app needs user_id (Socket.IO join_dashboard) and the
    profile fields here instead.
    """
    return jsonify({
        'success': True,
        'authenticated': True,
        'user': {
            'user_id': session.get('user_id'),
            'username': session.get('username'),
            'name': session.get('name'),
            'role': session.get('role'),
            'region': session.get('region'),
            'fe_group': session.get('field_engineer_group'),
            'email': session.get('email'),
            'contact': session.get('contact'),
            'location': session.get('location'),
        },
    })


@android_bp.route('/form-options', methods=['GET'])
@android_login_required
def form_options():
    """New-installation dropdown lists, served from the form_options collection.

    Falls back to DEFAULT_FORM_OPTIONS per category if the collection has not
    been seeded (scripts/seed_form_options.py), so the app always gets usable
    lists. Each option is {value, label}.
    """
    result = {}
    for category, defaults in DEFAULT_FORM_OPTIONS.items():
        doc = _mongo.db.form_options.find_one({'category': category})
        values = doc.get('values') if doc else None
        result[category] = values if values else defaults
    return jsonify({'success': True, **result})


def register_android_api(app, mongo):
    """Wire the blueprint into the main Flask app (called once from app.py)."""
    global _mongo
    _mongo = mongo
    app.register_blueprint(android_bp)
