# CLAUDE.md — ITrack (SDWAN Installation Tracker)

> ## ⚠️ Read `PROJECT_GUIDE.md` first
> **Before starting any task**, open [`PROJECT_GUIDE.md`](PROJECT_GUIDE.md), use its **Section Index** to jump to the section(s) relevant to your task, and follow it. It is the **single source of truth** — architecture, workflow, data model, API surface, security gaps, Windows-production caveats, mobile/responsive rules, and the one-time scripts. Read only the sections you need, not the whole file. **If the code and the guide disagree, the code wins — fix the guide in the same change.** The quick reference below is a summary; the guide is authoritative.

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
| Backend | Flask 3.0, Flask-SocketIO 5.3.6, Python |
| Database | MongoDB (PyMongo 4.6.1) |
| Auth | Flask sessions + Werkzeug password hashing |
| Frontend CSS | Tailwind CSS 3.4.1 (pre-compiled `output.css`) |
| Real-time | Socket.IO 4.7.2 (CDN) with REST fallback |
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
  seed_users.py         # DESTRUCTIVE user seed from master workbook
  seed_trackers.py      # Sample tracker data (demo/testing only)
  seed_form_options.py  # Seeds form_options collection for the Android app (idempotent)
exec_prod/              # Windows ops console (ServerAdminPankaj_V3.ps1) + deploy payload

android/                # Flutter FE Android app (itrack_fe) — see PROJECT_GUIDE §15 + android/docs/
android_backend/        # Thin Flask blueprint /api/android/* for the app (registered in app.py)

templates/
  base.html                    # Base layout (CDN: Socket.IO, Chart.js)
  login.html                   # Login with role selector
  fe_dashboard.html            # FE mobile-first dashboard
  fe_new_installation.html     # Create new tracker form
  fe_tracker_detail.html       # FE tracker detail + ZTP + HSO workflow
  noc_dashboard.html           # NOC desktop dashboard
  noc_tracker_detail.html      # NOC tracker detail + SIM/ZTP/HSO approval
  analytics_dashboard_v1.html  # Analytics with drill-down charts
  chat_component.html          # FE-NS chat (included in detail views)
  theme_styles.html            # CSS variable injection per role/theme

static/
  css/output.css          # Compiled Tailwind (do NOT hand-edit)
  css/input.css           # Tailwind source (edit to rebuild)
  css/fonts.css           # Font-face declarations
  fonts/                  # Self-hosted: Fjalla One + Material Symbols
  js/realtime_handler.js  # Socket.IO-first update handler with API fallback
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
- `chat_messages` — FE-NS coordination messages
- `predefined_reasons` — dropdown options for failures/delays
- `audit_logs` — system audit trail
- `notifications` — user notifications

Key indexes on `trackers`: `sdwan_id` (unique), `tracker_id`, `noc_assignee`, `status`, `created_at`

---

## Key Conventions

- **All timestamps**: stored as naive UTC `datetime` in MongoDB. Use `get_utc_now()` helper. Frontend converts to IST (+5:30) for display.
- **State changes**: always append to `events[]` array in the tracker doc — never mutate silently.
- **Embedded documents**: tracker contains nested objects (`fe`, `sim`, `router`, `ztp`, `hso`) — no separate collections.
- **Session auth**: user data in Flask session — no JWT.
- **Naming**: Python = snake_case, JS = camelCase, CSS = Tailwind utility classes, MongoDB fields = snake_case, API routes = kebab-case.
- **Role strings**: use constants — never hardcode.

---

## app.py Structure (sections in order)

1. Configuration & Setup
2. Helper functions: `get_utc_now()`, `serialize_doc()`, `make_event()`, `login_required`, `is_chat_unlocked()`
3. Page routes: `/fe/*`, `/noc/*`, `/analytics/*`
4. Auth APIs: `/api/auth/*`, `/api/login/*`
5. Tracker query APIs: `/api/trackers/*`
6. Tracker creation: `POST /api/trackers`
7. NOC operations: assign, SIM, ZTP, HSO — `/api/trackers/<id>/*`
8. Chat APIs: `/api/trackers/<id>/chat/*`
9. Analytics APIs: `/api/analytics/*`

---

## Dev Commands

```bash
# Run app
python app.py
run.bat          # Windows shortcut
./run.sh         # Linux/Mac shortcut

# Set up a fresh database (NOT init_db.py — that is legacy)
python scripts/create_indexes.py   # canonical indexes (idempotent)
python scripts/seed_users.py       # seed users (DESTRUCTIVE — see guide §12)

# Rebuild Tailwind CSS (only if templates changed)
npm install
npm run build:css

# Dev watch mode for CSS
npm run watch:css
```

**Environment variables:**
```bash
MONGO_URI=mongodb://localhost:27017/sdwan_tracker
SECRET_KEY=your-strong-secret-key
ADMIN_PASSWORD=change-me           # /admin panel; default 'qwerty' — set in prod
REALTIME_MODE=hybrid               # 'socket' | 'api' | 'hybrid'
PORT=5001                          # default listen port
```

Default dev server: `http://localhost:5001` (override with `PORT`)

---

## Rules for This Project

- **Keep root clean**: only essential files in root. One-time scripts → `scripts/` (tracked). Misc dev docs → `assets/` (gitignored).
- **Docs go in `PROJECT_GUIDE.md`** — do not create new standalone markdown files; add to the relevant section of the guide.
- **Don't create extra markdown files** for small changes — insert into an existing relevant doc.
- **Don't edit `output.css` directly** — rebuild from `input.css` via Tailwind.
- **Chat unlock is status-driven** — only unlocked in `CHAT_UNLOCKED_STATUSES` set.
- **Themes are injected server-side** — configured in `theme_config.py`, rendered in `theme_styles.html`.
- **Socket.IO loaded from CDN** in `base.html` — no local copy.
- **Tailwind `output.css` is pre-compiled** — `node_modules/` only needed if rebuilding CSS.
