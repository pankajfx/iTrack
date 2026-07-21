# PROJECT_GUIDE.md — ITrack (SDWAN Installation Tracker)

**Single source of truth.** This is the canonical reference for the ITrack codebase. It replaces the old `README.md`, `ANALYSIS.md`, and the `.kiro/steering/*.md` files.

> **How to use this guide (for agents & humans):** Do not read the whole file for every task. Match your task to a section in the index below and jump to it. If the code and this guide ever disagree, **the code wins** — fix the guide in the same change. Line references use `app.py:NN` and are clickable in the IDE.

---

## Section Index

| # | Section | Read this when your task touches… |
|---|---|---|
| 1 | [What the app is & user roles](#1-what-the-app-is--user-roles) | roles, permissions, who-sees-what |
| 2 | [Installation workflow & status machine](#2-installation-workflow--status-machine) | statuses, transitions, workflow logic |
| 3 | [Architecture & tech stack](#3-architecture--tech-stack) | dependencies, how pieces fit |
| 4 | [Data model](#4-data-model) | MongoDB collections, tracker shape, indexes |
| 5 | [Real-time (Socket.IO)](#5-real-time-socketio) | live updates, rooms, broadcasts |
| 6 | [API surface](#6-api-surface) | routes, endpoints, request/response |
| 7 | [Conventions & code map](#7-conventions--code-map) | timestamps, events, naming, `app.py` layout |
| 8 | [Security — gaps & missing controls](#8-security--gaps--missing-controls) | auth, hardening, before production |
| 9 | [Windows-server production setup & caveats](#9-windows-server-production-setup--caveats) | deploying/running on the server |
| 10 | [Mobile-first & responsive](#10-mobile-first--responsive) | any UI/template/CSS work |
| 11 | [Pros / cons / loopholes](#11-pros--cons--loopholes) | quick health snapshot |
| 12 | [One-time scripts](#12-one-time-scripts) | seeding, indexes, ops console |
| 13 | [Dev commands & environment variables](#13-dev-commands--environment-variables) | running locally, config |
| 14 | [Known issues & improvement roadmap](#14-known-issues--improvement-roadmap) | what to build/fix next |

---

## 1. What the app is & user roles

A Flask + MongoDB + Socket.IO web app that tracks the full lifecycle of SD-WAN router installations across field teams. Two operational planes:

- **FE (Field Engineer)** — mobile-first; creates trackers on-site and drives the physical install.
- **NS (NOC Support)** — desktop; backend provisioning (SIM activation, ZTP, HSO approval).

### Roles (canonical constants — never hardcode strings)

Defined in [app.py:38-47](app.py#L38-L47):

| Constant | Value | Notes |
|---|---|---|
| `ROLE_FE` | `FIELD_ENGINEER` | Creates & drives own trackers |
| `ROLE_FEG` | `FIELD_ENGINEER_GROUP` | Group oversight (read-only viewer) |
| `ROLE_FS` | `FIELD_SUPPORT` | Regional oversight |
| `ROLE_FSG` | `FIELD_SUPPORT_GROUP` | Sees all FE trackers + analytics |
| `ROLE_NS` | `NOC_SUPPORT` | Individual NOC operator |
| `ROLE_NSG` | `NOC_SUPPORT_GROUP` | NOC group + analytics |
| `ROLE_ANALYTICS` | `ANALYTICS` | Analytics dashboards only |

> ⚠️ The old `structure.md` said `ROLE_NS = 'NOC'` — that was **wrong**. It is `'NOC_SUPPORT'`.

Sets: `FE_ROLES = {FE, FEG, FS, FSG}`, `NOC_ROLES = {NS, NSG}`.

### Visibility hierarchy
- **FE** — only own trackers (`fe.id == user_id`).
- **FEG** — their `field_engineer_group`.
- **FS** — their region (multiple FEGs).
- **FSG** — all FE trackers.
- **Analytics access** (`_analytics_allowed()`, [app.py:2529](app.py#L2529)) is granted to `{ANALYTICS, NSG, FSG}`.
- Only the **owning FE** can take actions on a tracker; FEG/FS/FSG are read-only (`can_interact` gate, [app.py:215](app.py#L215)).

---

## 2. Installation workflow & status machine

### Lifecycle (happy path)
1. FE creates tracker (customer + router + SIM info).
2. NOC assigns tracker to an NS operator.
3. NS activates SIM cards (SIM1, SIM2).
4. NS verifies ZTP configuration.
5. FE **or** NS performs ZTP execution (pull).
6. NS marks *ready for coordination* → **unlocks chat**.
7. FE submits HSO documentation.
8. NS approves HSO → **Installation Complete**.

A **site-verification** sub-flow (confirm / reject / resubmit) exists around creation/assignment: [app.py:991-1163](app.py#L991).

### Status constants ([app.py:55-92](app.py#L55-L92))

`waiting_noc_assignment` → `noc_working` → *(ZTP branch)* → `ready_for_coordination` → `hso_submitted` / `hso_rejected` → `installation_complete`

ZTP branch statuses: `ztp_pull_pending`, `ztp_config_unverified`, `ztp_pull_done_by_fe`, `ztp_pull_unverified`, `ztp_pull_requested_from_noc`, `fe_requested_ztp`.

Legacy statuses kept for old docs: `ztp_pull_verified`, `ztp_pull_done_by_noc`.

### Behavioral gates
- **`CHAT_UNLOCKED_STATUSES`** — chat is only usable in the coordination phase: `ready_for_coordination`, `fe_requested_ztp`, `ztp_pull_requested_from_noc`, `hso_submitted`, `hso_rejected`, `installation_complete` (+ 2 legacy). See `is_chat_unlocked()` [app.py:159](app.py#L159).
- **`HSO_SUBMITTABLE_STATUSES`** — statuses from which FE may submit HSO.
- **Retry history** is preserved: `hso.attempts[]`, `sim.sim1.attempts[]`, `sim.sim2.attempts[]`.

---

## 3. Architecture & tech stack

| Layer | Technology |
|---|---|
| Backend | Flask 3.0, Flask-SocketIO 5.3.6 (`async_mode='threading'`), Python |
| Database | MongoDB via PyMongo 4.6.1 + Flask-PyMongo 2.3.0 |
| Auth | Flask server-side sessions + Werkzeug password hashing (no JWT) |
| Frontend CSS | Tailwind 3.4.1, **pre-compiled** to `static/css/output.css` |
| Real-time | Socket.IO 4.7.2 client, **self-hosted** ([static/js/vendor/socket.io.min.js](static/js/vendor/socket.io.min.js), loaded at [base.html:537](templates/base.html#L537)) + REST fallback |
| Icons | Material Symbols (self-hosted woff2). **Font Awesome is CSS/emoji-emulated** — no FA font files are served (the old `tech.md` claim of an FA 7.2.0 dependency is inaccurate). |
| Fonts | Inter, Manrope, Outfit, Fjalla One — all **self-hosted** variable woff2/ttf in `static/fonts/`, declared in `static/css/fonts.css`. No Google Fonts requests. |
| Charts | Chart.js 4.4.0 + chartjs-adapter-date-fns + hammerjs + chartjs-plugin-zoom, all **self-hosted** in `static/js/vendor/` (analytics dashboard) |
| Images | Pillow (chat upload processing) |
| Excel | openpyxl (analytics export + user seeding) |
| Templates | Jinja2 |

**Single-file backend:** all routes + business logic live in `app.py` (~3,442 lines). See the section map in [§7](#7-conventions--code-map).

**Templates (verified current set):** `base.html`, `login.html`, `theme_styles.html`, `fe_dashboard.html`, `fe_new_installation.html`, `fe_tracker_detail.html`, `noc_dashboard.html`, `noc_tracker_detail.html`, `analytics_dashboard_v1.html`, `chat_component.html`, `admin_users.html`.
Only JS asset: `static/js/realtime_handler.js`. (Old docs referenced `ztp_component.html`, `static/fontawesome-css/`, `static/webfonts/` — none of these are present/used.)

---

## 4. Data model

MongoDB DB: `sdwan_tracker`. Collections:

- **`users`** — accounts with role + hierarchy fields (`field_engineer_group`, `field_support`, `region`, `zone`, `state`, etc.). **This is the collection the app authenticates against.**
- **`trackers`** — installation docs with embedded sub-documents (below).
- **`chat_messages`** — FE-NS coordination messages (attachments stored inline as base64 data URLs — see [§8](#8-security--gaps--missing-controls) and [§14](#14-known-issues--improvement-roadmap)).
- **`predefined_reasons`** — dropdown options for SIM/ZTP/HSO failures and delay tags (seeded by `init_db.py`).
- **`audit_logs`**, **`notifications`** — audit trail & user notifications.

### Tracker embedded sub-documents
`fe`, `sim` (`sim1`/`sim2` with `attempts[]`, `failure_reason`), `router`, `ztp` (`performed_by`, `failure_reason`, `root_cause_of_initial_failure`), `hso` (`attempts[]`), `site_verification`, `reassignment_request`, `events[]`, and **`stage_timestamps`** (flat KPI timestamps stamped on first occurrence of each stage — powers analytics without scanning `events[]`). Duration math lives in `calculate_stage_times()` [app.py:2490](app.py#L2490).

### Indexes
The **canonical** index setup is `scripts/create_indexes.py` (idempotent; covers `trackers`, `users`, `chat_messages`, `predefined_reasons`, `notifications`). Run it on any fresh or production DB.

> ⚠️ **`init_db.py` is legacy / partially wrong.** It creates a `noc_users` collection the app never uses and does **not** create the `users` collection or its indexes (despite old docs claiming it seeds "sample users"). Use `scripts/create_indexes.py` for indexes and `scripts/seed_users.py` for users. See [§12](#12-one-time-scripts).

---

## 5. Real-time (Socket.IO)

- **Rooms:** `tracker_{id}` (viewers of one tracker), `dashboard_{role}` (a role's dashboard), `user_{user_id}` (personal notifications).
- **Client readiness pattern:** `window.onSocketReady(fn)` (defined in `<head>`, [base.html:19](templates/base.html#L19)) queues callbacks and **re-fires them on every reconnect**, so room joins are automatically re-issued after a network blip. All templates use this instead of checking `typeof socket`.
- **Join emits include `user_id`** (e.g. [noc_dashboard.html:1247](templates/noc_dashboard.html#L1247)), so `broadcast_to_user()` reaches the personal room.
- **Broadcast helpers** ([app.py:3378-3433](app.py#L3378)): `broadcast_tracker_update` (emits `tracker_update`, **includes the full serialized tracker** when `SOCKET_INCLUDE_FULL_DATA` and mode ∈ {socket, hybrid}), `broadcast_chat_message`, `broadcast_dashboard_update`, `broadcast_to_user`.
- **Fallback:** `REALTIME_MODE` (`socket` | `api` | `hybrid`, default `hybrid`) controls whether the client relies on the socket payload or falls back to a REST `loadTracker()`.

> The historical "real-time is broken" issues in the old `ANALYSIS.md` (missing `user_id`, no reconnect rejoin, dead `realtime_handler.js`/`tracker_update` listeners, `debug=True`) are **already fixed** in the current code. The one still-open real-time item: dashboards do a **full list reload** on any `dashboard_update` (`debouncedReload`) rather than a targeted card update — see [§14](#14-known-issues--improvement-roadmap).

---

## 6. API surface

`app.py` route groups (see [§7](#7-conventions--code-map) for the section map):

- **Page routes:** `/`, `/login`, `/fe/*`, `/noc/*`, `/analytics/dashboard`, `/admin`; legacy redirects `/franchise/*`, `/field_support*/*`.
- **Auth & login enumeration:** `POST /api/auth/login`, `POST /api/auth/logout`, and unauthenticated `GET /api/login/*` dropdown-population endpoints (see the enumeration note in [§8](#8-security--gaps--missing-controls)).
- **Tracker query:** `/api/trackers/all-fe`, `/all-noc`, `/unassigned`, `/my-installations`, `/api/trackers/<id>`, `/api/trackers/check/<sdwan_id>`, `/api/hierarchy/*`.
- **Creation:** `POST /api/trackers`.
- **Assignment / reassignment:** `/assign`, `/request-reassignment`, `/accept-reassignment`, `/deny-reassignment`, `/revoke-reassignment`, `/reassignment-requests`.
- **SIM / ZTP / HSO ops:** `/sim/<sim_key>/status`, `/ztp/config`, `/ztp/fe-start`, `/ztp/fe-complete`, `/ztp/request-noc`, `/ztp/status`, `/api/ztp/config/*`, `/api/ztp/pull/*`, `/ready-for-coordination`, `/hso/submit`, `/hso/approve`, `/hso/reject`, `/hso/incomplete`. Each guards ownership (`fe.id`) or assignment (`noc_assignee`).
- **Chat:** `/chat/messages`, `/chat/send`, `/chat/upload`, `/chat/mark-read`.
- **Analytics:** `/api/analytics/*` (kpi, fe/overview, noc/overview, trend, stage-durations, status-distribution, ztp-breakdown, sim-performance, sim-provider-performance, per-day, export/fe, export/noc). Each has a `/api/NOC_SUPPORT_GROUP/*` **alias** and is gated by `_analytics_allowed()`.
- **Admin (user management):** `GET/POST /admin/api/users`, `PUT /admin/api/users/<id>`, gated by `@admin_required`; `POST /admin/auth`, `POST /admin/logout`.

---

## 7. Conventions & code map

- **Timestamps:** stored as **naive UTC** in Mongo (`get_utc_now()`); `serialize_doc()` appends `Z` on the way out; frontend converts to **IST (+5:30)**.
- **State changes:** always append to `events[]` via `make_event(stage, actor_id, actor_role, remarks, metadata)` [app.py:136](app.py#L136) — never mutate silently. (Note: events store `actor` + `actor_role` but **not** `actor_name`; see [§14](#14-known-issues--improvement-roadmap).)
- **Embedded docs, not joins** — tracker carries nested `fe`/`sim`/`router`/`ztp`/`hso`.
- **Constants over literals** — always use the role/status constants.
- **Naming:** Python `snake_case`; JS `camelCase`; MongoDB fields `snake_case`; API routes `kebab-case`; CSS = Tailwind utilities.
- **Themes** are injected server-side (`theme_config.py` → `theme_styles.html`) per role.

### `app.py` section order
1. Config & setup → 2. Helpers (`get_utc_now`, `serialize_doc`, `make_event`, `login_required`, `is_chat_unlocked`) → 3. Page routes → 4. Auth/login APIs → 5. Tracker query APIs → 6. Tracker creation → 7. NOC ops (assign/SIM/ZTP/HSO) → 8. Chat APIs → 9. Analytics APIs → (10) Admin panel → (11) Socket.IO handlers & broadcast helpers → entry point.

---

## 8. Security — gaps & missing controls

> All findings below are code-verified. Treat this as the pre-production hardening checklist. **None are fixed yet** — this guide documents them; implementation is a follow-up.

### Findings
- **Weak default secrets.** `SECRET_KEY` defaults to `'dev-secret-key-change-in-production'` ([app.py:12](app.py#L12)). `ADMIN_PASSWORD` defaults to `'qwerty'` and is compared in plaintext, non-constant-time ([app.py:3170](app.py#L3170), [app.py:3216](app.py#L3216)).
- **`/admin` page is unauthenticated.** The route renders the panel to anyone ([app.py:3205](app.py#L3205)); only the `/admin/api/*` calls are gated, and only by a `session['admin_authenticated']` flag with **no rate-limiting, lockout, or CSRF**.
- **Socket.IO has zero auth/authorization.** `connect`/`join_tracker` accept any client ([app.py:3329-3345](app.py#L3329)); CORS is wide open (`cors_allowed_origins="*"`, [app.py:22](app.py#L22)). Any party can join `tracker_{arbitrary_id}` and receive the **full serialized tracker payload** on every change → IDOR + data leak over WebSocket.
- **IDOR on tracker read.** `GET /api/trackers/<id>` is `@login_required` only, no ownership/assignment check ([app.py:438](app.py#L438)) — any logged-in user can read any tracker by id.
- **Unauthenticated user enumeration.** `GET /api/login/*` exposes all usernames/names/regions without auth ([app.py:268-317](app.py#L268)); combined with **no login rate-limiting/lockout** ([app.py:343](app.py#L343)).
- **Predictable seeded passwords.** `scripts/seed_users.py` defaults each password to the username when the Excel has none.
- **No CSRF protection** on any state-changing POST (cookie-session auth, SameSite=Lax default only).
- **Unhardened session cookies.** `SESSION_COOKIE_SECURE` / `SAMESITE` / lifetime are not set — the cookie can ride plain HTTP if the proxy is misconfigured.
- **NoSQL operator-injection surface.** Request-JSON values are placed directly into Mongo query dicts (login builds `query['name'] = data.get(...)`, [app.py:349-364](app.py#L349)). The password hash check still applies, but object payloads (`{"$ne": null}`) can widen matches — cast query inputs to `str` / validate.
- **Weak upload validation.** Chat upload stores base64 data URLs; only a naive HTML-sniff on images, audio/other accept client-supplied `content_type` ([app.py:2384-2450](app.py#L2384)) → data-URL XSS + unbounded document growth (16 MB BSON limit).
- **No security headers** (CSP / HSTS / X-Frame-Options / X-Content-Type-Options) at the app layer, and the proxy configs the ops script generates don't add them either.

### Remediation checklist (prioritized)
- **P1:** require `SECRET_KEY` & `ADMIN_PASSWORD` from env (fail if default in prod); add Socket.IO connection auth + per-room authorization; add ownership check to `GET /api/trackers/<id>`; rate-limit login & `/admin/auth`.
- **P2:** CSRF tokens on POSTs; harden session cookies (`Secure`, `SameSite=Strict`, lifetime); add security headers; enforce an upload MIME/type allowlist + size caps; cast/validate query inputs.
- **P3:** move chat attachments to GridFS or an object store; lock down CORS to the real origin.

---

## 9. Windows-server production setup & caveats

### Serving model
`python app.py` runs `socketio.run(app, async_mode='threading', host='0.0.0.0', port=5001)` ([app.py:22](app.py#L22), [app.py:3436-3441](app.py#L3436)). Port default is **5001** (override with `PORT`); debug is gated behind `FLASK_DEBUG`.

> ⚠️ The entry-point comment claims eventlet monkey-patching / eventlet WSGI — **that is stale**. There is no eventlet import; mode is **threading**. Threading mode uses the Werkzeug server: fine for a small team, but it is **single-process with limited concurrency** — not a hardened multi-worker production server.

### Ops console — `scripts/ServerAdminPankaj_V3.ps1`
An interactive PowerShell menu that manages the whole stack on Windows:
- Start/Stop/Restart **Flask** (runs `python app.py` detached, tracks a PID file, sweeps the port on stop).
- Start/Stop/Restart the **MongoDB** Windows service; launch `mongosh`.
- Reverse proxy: **Caddy** (preferred, `tls internal` local HTTPS) or **Nginx** fallback (auto-generates a self-signed cert + config with `X-Forwarded-Proto https`).
- Optional **NSSM** Windows-service install for Flask / Caddy / Nginx.
Edit the `$Cfg` block at the top (`AppRoot`, `VenvPython`, `Port`, cert paths, service names) to match the server. Run **as Administrator** for service control and local root-CA trust.

### Caveats & pitfalls
- **Do NOT use the "Install Waitress Service" option for the app.** Waitress is WSGI-only and **cannot handle WebSocket upgrades** → Socket.IO breaks. Use the `python app.py` (Start-Flask) path behind the reverse proxy, or migrate to a proper eventlet/gevent worker.
- **TLS:** Caddy/Nginx here serve `localhost` with self-signed/internal certs. Production needs a real domain + trusted cert.
- **MongoDB auth:** the authenticated prod URI is commented out ([app.py:15](app.py#L15)); the default is **unauthenticated localhost**. Enable auth and bind carefully; never expose Mongo externally.
- **Perf flags:** `TEMPLATES_AUTO_RELOAD=True` and `SEND_FILE_MAX_AGE_DEFAULT=0` ([app.py:18-19](app.py#L18)) disable template/static caching — turn these off / raise cache age in production.
- **Logging:** the app uses `print()` throughout. Under NSSM, redirect `AppStdout`/`AppStderr` to log files and configure rotation.
- **All third-party assets are self-hosted** (Socket.IO, Chart.js stack, Inter/Manrope/Outfit/Fjalla fonts, Material Symbols) under `static/js/vendor/` and `static/fonts/` — no CDN or Google Fonts requests at runtime, so the app works on offline/field networks. If a library version needs bumping, re-download the file into `static/js/vendor/` (or refresh the woff2 in `static/fonts/` via the Google Fonts CSS API) rather than pointing back at a CDN.
- **Firewall / binding:** the app binds `0.0.0.0:5001`. Expose only the reverse-proxy port; block 5001 to external traffic.

---

## 10. Mobile-first & responsive

**Principle: the app must be usable on phone, tablet, and desktop.** FE surfaces (`fe_dashboard`, `fe_new_installation`, `fe_tracker_detail`) are mobile-first; NOC and analytics are desktop-optimized but must still degrade gracefully on small screens.

- **Accessibility flag to fix:** the viewport sets `maximum-scale=1.0, user-scalable=no` ([base.html:5](templates/base.html#L5)), which disables pinch-zoom (WCAG 1.4.4 violation). Recommend removing the zoom lock.
- **FOUC gate:** `body { opacity: 0 }` until `.fonts-loaded` ([base.html:37](templates/base.html#L37)) plus font preloads — verify this doesn't leave a blank screen on slow mobile networks; provide a timeout fallback.

### Responsive audit checklist (do this for any UI change)
- NOC dashboard tables and analytics **Chart.js canvases** reflow or scroll horizontally below 768px.
- Touch targets ≥ 44×44px on FE screens.
- Test **landscape** and **short-height** devices (chat + sticky action bars must not overlap).
- Verify theme injection (`theme_styles.html`) doesn't break layout at mobile breakpoints.
- Rebuild Tailwind (`npm run build:css`) after adding any new utility classes — `output.css` is pre-compiled.

---

## 11. Pros / cons / loopholes

**Pros**
- Clean event-sourced audit trail (`events[]` via a single `make_event`).
- Dedicated `stage_timestamps` make KPI aggregation cheap.
- Room-scoped Socket.IO with auto reconnect-rejoin; hybrid REST fallback.
- Retry history preserved for SIM/ZTP/HSO.
- Comprehensive, idempotent index script; sensible reverse-proxy ops console for Windows.

**Cons**
- Monolithic 3.4k-line `app.py` — hard to test in isolation.
- Threading async mode → limited concurrency; not horizontally scalable as-is.
- Analytics compute in Python by loading all matching trackers (no Mongo aggregation pipeline) → slow at scale.
- Chat attachments as base64 in documents → doc bloat, 16 MB BSON ceiling.
- `print()`-based logging.

**Loopholes (security — see [§8](#8-security--gaps--missing-controls))**
- Unauthenticated Socket.IO room join leaks full tracker data (IDOR).
- Tracker GET has no ownership check.
- Public user-enumeration endpoints + no login rate-limiting.
- Weak default admin/secret; no CSRF; unhardened cookies.

---

## 12. One-time scripts

All live in the tracked **`scripts/`** folder (moved out of the web-served `static/` path so they and the user data are no longer downloadable via URL). The `.py` files are version-controlled; **the user-data `.xlsx` is gitignored** (`scripts/*.xlsx`) because it holds real accounts.

| Script | What it does | When to run | When NOT to run |
|---|---|---|---|
| `scripts/create_indexes.py` | **Canonical** MongoDB index setup for all collections; idempotent (skips existing). | Once on any fresh/prod DB, and after adding new query patterns. Safe to re-run. | Never harmful. |
| `scripts/seed_users.py` | **DESTRUCTIVE** — clears `users` and repopulates from `scripts/SDWAN Installation Tracker Master User Data.xlsx` (passwords hashed; FEG hierarchy derived). Creates the `users` unique index. | Initial setup or a deliberate reset. | **Never** against live production with real accounts. |
| `scripts/seed_trackers.py` | Generates sample tracker data for demo/testing. | Local demos / load testing. | Never in production. |
| `init_db.py` (root) | **Legacy.** Creates the wrong `noc_users` collection and seeds `predefined_reasons`; does not set up `users`. | Only for the `predefined_reasons` seed, if you extract that. | Don't rely on it for indexes/users — use the scripts above. |
| `exec_prod/ServerAdminPankaj_V3.ps1` | Windows ops console (start/stop app, Mongo, reverse proxy; NSSM services). | On the server, as Administrator. See [§9](#9-windows-server-production-setup--caveats). | Not for dev machines. Avoid its "Waitress Service" option (breaks WebSockets). |

Run scripts from the project root, e.g. `python scripts/create_indexes.py`.

---

## 13. Dev commands & environment variables

```bash
# Run the app (default http://localhost:5001)
python app.py
run.bat        # Windows shortcut
./run.sh       # Linux/Mac shortcut

# MongoDB setup on a fresh DB
python scripts/create_indexes.py      # indexes (canonical)
python scripts/seed_users.py          # users from the master workbook (DESTRUCTIVE)

# Tailwind (only if templates changed)
npm install
npm run build:css       # production build
npm run watch:css       # dev watch
```

### Environment variables
| Var | Default | Purpose |
|---|---|---|
| `MONGO_URI` | `mongodb://localhost:27017/sdwan_tracker` | DB connection (use an authenticated URI in prod) |
| `SECRET_KEY` | dev placeholder | Flask session signing — **must set in prod** |
| `ADMIN_PASSWORD` | `qwerty` | `/admin` panel password — **must set in prod** |
| `REALTIME_MODE` | `hybrid` | `socket` \| `api` \| `hybrid` |
| `SOCKET_TIMEOUT` | `2000` | ms before REST fallback |
| `SOCKET_INCLUDE_FULL_DATA` | `true` | include full tracker in broadcasts |
| `FLASK_DEBUG` | `false` | gate Werkzeug debug/reloader |
| `PORT` | `5001` | listen port |

---

## 14. Known issues & improvement roadmap

Still-valid items (the resolved real-time bugs from the old ANALYSIS.md have been dropped):

**Real-time / performance**
- Dashboard `dashboard_update` triggers a **full list reload** (`debouncedReload`) — switch to targeted card insert/update/remove using the payload's `tracker_id`.
- Add a persistent **connection-status indicator** in the header (critical for unreliable field networks).
- Connect the **analytics dashboard** to Socket.IO for live KPI refresh.

**Analytics / KPIs**
- Replace Python-side iteration with **MongoDB aggregation pipelines** (`$group`/`$avg`/`$sum`).
- Add accountability KPIs: NS idle time (`assigned → sim1 start`), FE coordination response (`ready → hso submitted`), HSO reject→resubmit time (from `hso.attempts[]`).
- Add **failure-reason aggregation** endpoints (SIM/ZTP/HSO) and a **per-operator KPI table**.
- Add **SLA thresholds** + breach flags and a live status-funnel card.

**Code quality / storage**
- Move chat attachments to **GridFS / object store** (currently base64 in docs).
- Store **`actor_name`** in `make_event()` to avoid user lookups in timelines/analytics.
- Consider splitting `app.py` into blueprints as it grows.

**Security** — see the prioritized checklist in [§8](#8-security--gaps--missing-controls).
