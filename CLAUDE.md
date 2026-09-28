# CLAUDE.md — ITrack (SDWAN Installation Tracker)

> ## ⚠️ Read `PROJECT_GUIDE.md` first
> **Before starting any task**, open [`PROJECT_GUIDE.md`](PROJECT_GUIDE.md), use its **Section Index** to jump to the section(s) relevant to your task, and follow it. It is the **single source of truth** — architecture, workflow, data model, real-time, API surface, security, production deployment (Windows and Linux), background jobs, mobile/responsive rules, and the one-time scripts. Read only the sections you need, not the whole file. **If the code and the guide disagree, the code wins — fix the guide in the same change.** The quick reference below is a summary; the guide is authoritative.

## Project Origin
This codebase is a **clean production snapshot** migrated from `.production/` of a prior development project. It is the official starting point for continued development.

---

## What This App Does

**SDWAN Installation Tracker** — a Flask web app that tracks the full lifecycle of SD-WAN router installations across field teams. Engineers in the field log progress; NOC operators manage backend provisioning. The app is live-updating via Socket.IO and has role-based dashboards.

### Installation Workflow (in order)
1. FE creates tracker (customer + router + SIM info)
2. NOC assigns tracker to an NS operator
3. NS activates SIM cards (SIM1, SIM2)
4. NS verifies ZTP configuration
5. FE or NS performs ZTP execution (pull)
6. NS marks ready for coordination → unlocks chat
7. FE submits HSO documentation
8. NS approves HSO → **Installation Complete**

---

## Tech Stack

| Layer | Technology |
|---|---|
| Backend | Flask 3.0, Flask-SocketIO 5.3.6, Python 3.11 — **gevent** in production (`python app.py`), threading in dev |
| Database | MongoDB (PyMongo 4.6.1) |
| Auth | Signed-cookie Flask sessions (revocable via `session_epoch`), Werkzeug scrypt hashing, CSRF token on every state-changing request |
| Frontend CSS | Tailwind CSS 3.4.1 (pre-compiled `output.css`) |
| Real-time | Socket.IO 4.7.2 (self-hosted): authenticated rooms, reconnect forever, REST catch-up after any gap |
| Icons | Material Symbols (self-hosted) |
| Charts | Chart.js 4.4.0 (analytics) |
| Templates | Jinja2 |

---

## Project Structure

```
app.py                  # ALL routes + business logic (single file) + /admin panel
theme_config.py         # Role-based theme definitions
init_db.py              # LEGACY — do not use for indexes/users (see PROJECT_GUIDE §12)
Requirements.txt        # Python deps
package.json            # Node deps (Tailwind only)
tailwind.config.js      # Tailwind config

scripts/                # One-time scripts (tracked; *.xlsx gitignored)
  create_indexes.py     # Canonical MongoDB index setup (idempotent)
  seed_users.py         # sync users with the workbook (upserts by username, removes absent accounts; --dry-run)
  migrate_media.py      # inline media -> GridFS; --gc lists (and --apply deletes) unreferenced media
  relink_orphans.py     # re-attach trackers orphaned by an old reseed
  seed_trackers.py      # Sample tracker data (demo/testing only)
exec_prod/              # Windows ops console (ServerAdminPankaj_V3.ps1, deployed/): app as a gevent NSSM
                        # service, Caddy/Nginx configs; wheels/ = offline pip payload (gitignored)

templates/
  base.html                    # Base layout: CSRF meta + secure_fetch.js, the page's one socket, reconnect hooks
  login.html                   # Login with role selector
  fe_dashboard.html            # FE mobile-first dashboard
  fe_new_installation.html     # Create new tracker form
  fe_tracker_detail.html       # FE tracker detail + ZTP + HSO workflow
  noc_dashboard.html           # NOC desktop dashboard
  noc_tracker_detail.html      # NOC tracker detail + SIM/ZTP/HSO approval
  analytics_dashboard_v1.html  # Analytics with drill-down charts
  chat_component.html          # FE-NS chat (included in detail views)
  theme_styles.html            # CSS variable injection per role/theme
  admin_users.html             # /admin user management (needs a strong ADMIN_PASSWORD)

static/
  css/output.css          # Compiled Tailwind (do NOT hand-edit)
  css/input.css           # Tailwind source (edit to rebuild)
  css/fonts.css           # Font-face declarations
  fonts/                  # Self-hosted: Fjalla One + Material Symbols
  js/secure_fetch.js      # CSRF header + session-expiry redirect for every fetch (loaded first)
  js/realtime_handler.js  # legacy; no template loads it
  js/vendor/               # Self-hosted Socket.IO client + Chart.js stack (no CDN)
```

One-time scripts live in the tracked `scripts/` folder (the user-data `.xlsx` is gitignored). The `assets/` folder (misc docs/dev files) remains gitignored.

---

## Role Constants (app.py)

Always use these — never hardcode role strings:

```python
ROLE_FE   = 'FIELD_ENGINEER'
ROLE_FEG  = 'FIELD_ENGINEER_GROUP'
ROLE_FS   = 'FIELD_SUPPORT'
ROLE_FSG  = 'FIELD_SUPPORT_GROUP'
ROLE_NS   = 'NOC_SUPPORT'
ROLE_NSG  = 'NOC_SUPPORT_GROUP'
ROLE_ANALYTICS = 'ANALYTICS'

FE_ROLES  = {ROLE_FE, ROLE_FEG, ROLE_FS, ROLE_FSG}
NOC_ROLES = {ROLE_NS, ROLE_NSG}
```

Role hierarchy for visibility:
- FE: sees only own trackers
- FEG: sees their group
- FS: sees their region
- FSG: sees all FE trackers

---

## MongoDB Collections

- `users` — accounts with role + hierarchy fields
- `trackers` — installation docs with embedded events array
- `chat_messages` — FE-NS coordination messages (media in GridFS, served by `/api/media/<id>`)
- `predefined_reasons` — dropdown options for failures/delays
- `audit_logs` — admin sign-ins and user changes (TTL `AUDIT_RETENTION_DAYS`)
- `notifications` — user notifications
- `login_attempts` — failed sign-ins for throttling (TTL)
- `counters` — atomic per-year `tracker_id` sequence
- `fs.files` / `fs.chunks` — GridFS media; `metadata.tracker_id` authorizes access

Key indexes on `trackers`: `sdwan_id` (unique), `tracker_id`, `noc_assignee`, `status`, `created_at`

---

## Key Conventions

- **All timestamps**: stored as naive UTC `datetime` in MongoDB. Use `get_utc_now()` helper. Frontend converts to IST (+5:30) for display.
- **State changes**: always append to `events[]` array in the tracker doc — never mutate silently.
- **Embedded documents**: tracker contains nested objects (`fe`, `sim`, `router`, `ztp`, `hso`) — no separate collections.
- **Session auth**: signed-cookie Flask session, revocable server-side via `session_epoch` — no JWT.
- **Authorization**: by-id tracker access goes through `visible_tracker()`, chat writes through `can_write_chat()`. Never trust a role, user id or room sent by the client — in an HTTP body or a socket event.
- **CSRF**: state-changing requests need `X-CSRF-Token`; `static/js/secure_fetch.js` adds it to every same-origin `fetch`. Anything that bypasses `fetch` must add it itself.
- **Escaping**: user-typed values go into HTML through `esc()`, and through `escJs()` inside inline handlers.
- **CPU-heavy work** (password hashing, image processing) goes through `run_blocking()` so it never stalls the gevent event loop.
- **Naming**: Python = snake_case, JS = camelCase, CSS = Tailwind utility classes, MongoDB fields = snake_case, API routes = kebab-case.
- **Role strings**: use constants — never hardcode.

---

## app.py Structure (sections in order)

0. Async-mode bootstrap — gevent monkey-patching; **must stay the first code in the file**
1. Configuration & Setup (security settings, headers, CSRF, session checks)
2. Helper functions: `get_utc_now()`, `serialize_doc()`, `make_event()`, `login_required`, `is_chat_unlocked()`
3. Page routes: `/fe/*`, `/noc/*`, `/analytics/*`
4. Auth APIs: `/api/auth/*`, `/api/login/*`
5. Tracker query APIs: `/api/trackers/*`
6. Tracker creation: `POST /api/trackers`
7. NOC operations: assign, SIM, ZTP, HSO — `/api/trackers/<id>/*`
8. Chat APIs: `/api/trackers/<id>/chat/*`
9. Analytics APIs: `/api/analytics/*`
10. Admin panel: `/admin`, `/admin/api/*`
11. Socket.IO handlers + broadcast helpers, then the entry point

---

## Dev Commands

```bash
# Run app (threading development server)
python app.py
SOCKETIO_ASYNC_MODE=gevent python app.py   # the production server, locally (PROJECT_GUIDE §9)
run.bat          # Windows shortcut
./run.sh         # Linux/Mac shortcut

# Set up a fresh database (NOT init_db.py — that is legacy)
python scripts/create_indexes.py   # canonical indexes (idempotent)
python scripts/seed_users.py --dry-run   # sync users with the workbook (upserts by username - guide §12)

# Rebuild Tailwind CSS (only if templates changed)
npm install
npm run build:css

# Dev watch mode for CSS
npm run watch:css
```

**Environment variables:**
```bash
MONGO_URI=mongodb://localhost:27017/sdwan_tracker
SECRET_KEY=                        # >= 32 random chars; the app refuses to start without one (unless FLASK_DEBUG=true)
ADMIN_PASSWORD=                    # >= 12 chars and not common, or /admin stays disabled
REALTIME_MODE=hybrid               # 'socket' | 'api' | 'hybrid'
PORT=5001                          # default listen port

MEDIA_PROFILE=balanced             # compact | balanced | original  (see PROJECT_GUIDE §15.4)
IMAGE_MAX_DIM=1920                 # server-side resize, longest edge; 0 = never resize
IMAGE_QUALITY=95                   # server-side JPEG quality
CAPTURE_MAX_DIM=1920               # camera width requested in the browser
CAPTURE_QUALITY=0.95               # canvas JPEG quality in the browser

SOCKETIO_ASYNC_MODE=threading      # threading (dev) | gevent (production); eventlet is refused
SOCKETIO_MESSAGE_QUEUE=            # redis://... REQUIRED before running >1 process (plus a sticky proxy)
MONGO_MAX_POOL_SIZE=100            # connections per process
STATIC_VERSION=                    # cache-bust token for /static (defaults to a fingerprint of static/)
CORS_ORIGINS=                      # unset = same origin only; a list replaces that; '*' = any site (don't)

# Production, behind Caddy/Nginx - every setting: PROJECT_GUIDE §8.2 and §13
TRUST_PROXY_HOPS=1                 # real client IPs + HTTPS detection; binds 127.0.0.1 (HOST overrides)
SESSION_COOKIE_SECURE=true
HSTS_MAX_AGE=31536000              # only with a trusted certificate on a stable hostname
```

```bash
# One-time database setup, in this order
python scripts/create_indexes.py                    # canonical indexes (idempotent)
python scripts/migrate_media.py --dry-run           # inline base64 media -> GridFS
python scripts/migrate_media.py
python scripts/relink_orphans.py                    # report trackers orphaned by an old reseed
```

> **Performance work:** read [`PROJECT_GUIDE.md` §15](PROJECT_GUIDE.md) first — it holds the measured
> baseline, the ranked root causes and the ordered remediation plan. Re-measure and update it in the same
> change; do not start a second performance document.

Default dev server: `http://localhost:5001` (override with `PORT`)

---

## Rules for This Project

- **Keep root clean**: only essential files in root. One-time scripts → `scripts/` (tracked). Misc dev docs → `assets/` (gitignored).
- **Docs go in `PROJECT_GUIDE.md`** — do not create new standalone markdown files; add to the relevant section of the guide.
- **Don't create extra markdown files** for small changes — insert into an existing relevant doc.
- **Don't edit `output.css` directly** — rebuild from `input.css` via Tailwind.
- **Chat unlock is status-driven** — only unlocked in `CHAT_UNLOCKED_STATUSES` set.
- **Themes are injected server-side** — configured in `theme_config.py`, rendered in `theme_styles.html`.
- **Socket.IO and all vendor JS/fonts are self-hosted** under `static/js/vendor/` and `static/fonts/` — no CDN or Google Fonts calls at runtime.
- **Tailwind `output.css` is pre-compiled** — `node_modules/` only needed if rebuilding CSS.
- **Production serving**: `python app.py` with `SOCKETIO_ASYNC_MODE=gevent`, as the NSSM service the ops console installs. Never waitress or eventlet; never gunicorn with more than one worker (PROJECT_GUIDE §9).
- **Where things are documented**: security §8, deployment and sizing §9, real-time §5, background jobs §16 of `PROJECT_GUIDE.md`.
