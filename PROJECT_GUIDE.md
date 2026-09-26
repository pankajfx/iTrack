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
| 15 | [Performance, scale & the media pipeline](#15-performance-scale--the-media-pipeline) | slowness, load, concurrency, image/audio sizing |

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
- **The login form must carry a username field.** `login.html` picks an account through custom dropdowns, not a text input. With only `autocomplete="current-password"` present, a password manager keys its saved entry to the origin alone and refills the *same* password for every engineer you select — which looks exactly like a wrong-password bug. A visually hidden `autocomplete="username"` input (`#account-username`) is kept in sync with the selection so credentials are scoped per account, and the password box is cleared whenever the selection changes. Keep both if you touch that form.
- **Image popups go through one shared viewer** — `window.openImageViewer(src, title, filename)` in [base.html](templates/base.html) (markup `#app-image-viewer` + an IIFE right below the toast container). It handles zoom (buttons, wheel, pinch, double-tap), drag-to-pan, Esc/`+`/`-`/`0` keys, background scroll-lock, and download. Callers pass a data URL and a title; the viewer derives the file extension from the data URL's MIME type. **Do not add per-page lightboxes** — call the shared one. Current callers: `showImageModal()` (SIM/firmware, both tracker detail pages), `openSVPhoto(idx)` (NOC site-verification photos), `viewFullImage()` / `window.viewChatImage` (chat images).
- **Chat bubbles have one renderer.** `renderMessageBubble(msg, currentRole)` in [chat_component.html](templates/chat_component.html) is used by both the API render (`displayMessages`) and the Socket.IO append (`appendNewMessage`). They used to build different markup, so a message changed shape on reload. Add message types there, not in either caller.
- **Voice notes carry their own duration.** `MediaRecorder` emits a live-stream container with no Duration header, so players report `Infinity` — controls read 0:00, the scrubber is dead and the clip cannot be replayed. Three things address this and all are needed: the client measures the length while recording and sends it as `duration` (stored on the message doc by `api_send_chat_message`); `fixAudioDurations()` seeks past the end to force the browser to resolve the real duration; and the clip's `src` goes on the `<audio>` element rather than a `<source type="...">`, which the browser skips outright when it does not claim to support the declared type. The recorder also picks its container from `MediaRecorder.isTypeSupported` (WebM/Opus on Chrome and Firefox, MP4/AAC on Safari) instead of hardcoding WebM.
- **Image quality is preserved end to end** — downloads re-wrap the stored bytes as a Blob rather than re-drawing through a canvas, so the saved file is byte-identical to what is stored. Captures are taken at the camera's native stream resolution (canvas sized from `videoWidth`/`videoHeight`, never the displayed size), request `width/height: { ideal: 1920/1080 }` and encode at JPEG `0.95`; chat uploads are re-encoded server-side at max 1920px / quality 95 ([app.py](app.py) `api_upload_chat_file`). Raising these further inflates the inline `data:` URLs that ship on every chat poll and count against Mongo's 16MB document cap.

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

- **Accessibility flag to fix:** the viewport sets `maximum-scale=1.0, user-scalable=no` ([base.html:5](templates/base.html#L5)), which disables pinch-zoom (WCAG 1.4.4 violation). Recommend removing the zoom lock. The shared image viewer implements its own pinch/wheel zoom to work around this for photos (see [§7](#7-conventions--code-map)).
- **Scroll locking is automatic - do not hand-roll it.** A watcher in [base.html](templates/base.html) observes the DOM for any `.fixed.inset-0` overlay becoming visible and pins the body (`position: fixed` at the saved offset, restored on close - `overflow: hidden` alone does not stop iOS rubber-banding). Every modal in the app is such an element toggled with the `hidden` class, so new ones are covered for free. Opt out with `data-no-scroll-lock="1"`; force a re-check after an unusual visibility change with `window.syncPageScrollLock()`.
- **Full-screen camera/media modals need `min-height: 0` on the video row.** A flex child defaults to `min-height: auto`, so a `<video>`'s intrinsic height (1080px) becomes a floor the `flex-1` row cannot shrink below - it grows past the viewport and pushes the Capture button off-screen, which is only reachable by zooming the browser out. Give the media row `style="min-height:0"` + `overflow-hidden`, and the header/button bars `flex-shrink-0`.
- **Percentage widths collapse inside chat bubbles.** `.chat-message` is shrink-to-fit, so a child with `width: 100%` has no definite parent width to resolve against and falls back to min-content - this is what rendered voice notes as a tiny blob. Give media a definite width (`width: 15rem`) plus `max-width: 100%`, never the reverse.
- **Full-screen overlays must lock the page behind them.** The image viewer sets `body { position: fixed; top: -<scrollY>px }` while open and restores the offset on close (a plain `overflow: hidden` does not stop iOS rubber-banding). It also sets `window.appImageViewerOpen`, which the global pull-to-refresh touch handlers check so panning inside the viewer never triggers a page refresh. Any new full-screen modal should do the same.
- **Media inside chat bubbles must be fluid.** `.chat-audio` and `.chat-image` size to the bubble (`width: 100%` with a max), bubbles widen to 85% below 640px, and `#chat-messages` clips horizontally. A fixed-width player overflowed the chat card on phones.
- **Chat never yanks the user's scroll position.** `displayMessages()` in [chat_component.html](templates/chat_component.html) skips the re-render entirely when the message signature (count + last id + timestamp) is unchanged, and only pins to the bottom when the user is already within 60px of it. The 5s poll therefore leaves someone reading history alone. Sending a message scrolls back to the bottom explicitly.
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
| `scripts/seed_users.py` | **DESTRUCTIVE by default** — clears `users` and repopulates from `scripts/SDWAN Installation Tracker Master User Data.xlsx` (passwords hashed; FEG hierarchy derived). Creates the `users` unique index. `--passwords-only` is the **safe** mode: it re-hashes each sheet password onto the matching existing user and touches nothing else — no deletes, no inserts, no other fields. `--dry-run` reports without writing. | Initial setup or a deliberate reset. Use `--passwords-only` to recover a forgotten password on a populated DB. | The default (full) mode **never** against live production with real accounts. |
| `scripts/seed_trackers.py` | Generates sample tracker data for demo/testing. | Local demos / load testing. | Never in production. |
| `init_db.py` (root) | **Legacy.** Creates the wrong `noc_users` collection and seeds `predefined_reasons`; does not set up `users`. | Only for the `predefined_reasons` seed, if you extract that. | Don't rely on it for indexes/users — use the scripts above. |
| `exec_prod/ServerAdminPankaj_V3.ps1` | Windows ops console (start/stop app, Mongo, reverse proxy; NSSM services). | On the server, as Administrator. See [§9](#9-windows-server-production-setup--caveats). | Not for dev machines. Avoid its "Waitress Service" option (breaks WebSockets). |

Run scripts from the project root, e.g. `python scripts/create_indexes.py`.

**Workbook gotchas (both bit us on 2026-09-26):**

1. **Read the per-role sheets, never `All(270)`.** The consolidated `All(270)` sheet's `Password` column is a *placeholder* - the literal value `test123` repeated for all 270 users. The real per-user passwords live in `FE(235)`, `FEG(23)`, `FS(5)`, `FSG(1)`, `NS(5)`, `NSG(1)` (235+23+5+1+5+1 = 270), which agree with `All(270)` on every other column. Seeding from `All(270)` set every account's password to `test123`, so no real credential worked. `seed_users.py` now reads the role sheets (matched by the pattern `ROLE(n)`) and falls back to the consolidated sheet only if they are absent. It also prints its source sheets and **warns loudly** when every row shares one password.
2. **The autofilter breaks openpyxl.** The workbook carries `<customFilter val=" ">`, which openpyxl's validator rejects, so `load_workbook()` raised before reading a single row. `seed_users.py` now strips `<autoFilter>` from a temp copy before loading, leaving the original file untouched.

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

**Performance / scale** - superseded by [§15](#15-performance-scale--the-media-pipeline), which carries the measured baseline and the ordered remediation plan. Start there.

---

## 15. Performance, scale & the media pipeline

> **This section is the current-state record for performance work.** Measured 2026-09-26 against the local
> `sdwan_tracker` database. Re-measure and update the numbers here whenever you change anything in it —
> do not add a second performance document.

### 15.1 Measured baseline

Dataset at time of audit: **207 trackers, 526 chat messages, 270 users**.

| Collection | Docs | Data size | Avg doc |
|---|---|---|---|
| `trackers` | 207 | 3.9 MB | 19.3 KB |
| `chat_messages` | 526 | 2.3 MB | 4.4 KB |
| `users` | 270 | 0.1 MB | 0.5 KB |

Endpoint measurements (local, warm, single client — so these are a *floor*, not production latency):

| Endpoint | Time | Response size |
|---|---|---|
| `GET /noc/dashboard` (HTML) | 26 ms | 98 KB |
| `GET /api/trackers/all-noc` | 113 ms | **4,205,999 B (4.2 MB)** |
| `GET /api/trackers/<id>/chat/messages` (heaviest thread) | 18 ms | **2,237,521 B (2.2 MB)** |
| `GET /static/js/vendor/chart.umd.min.js` | 21 ms | 205 KB |
| `GET /static/css/output.css` | 81 ms | 43 KB |

Where the bytes actually are:

- **69% of all tracker JSON is base64 image data.** Largest single tracker document: **1,204 KB**, of which 1,195 KB is images.
- **93% of chat message bytes are base64 media** (`file_url`).

### 15.2 Root causes, ranked

**1. No indexes existed.** `trackers` and `chat_messages` had only `_id`. Every dashboard query was a
`COLLSCAN`. `scripts/create_indexes.py` defines the right indexes but had never been run against this
database. **Fixed 2026-09-26** — applied, verified:

| Query | Before | After |
|---|---|---|
| FE dashboard (`fe.id` + sort) | COLLSCAN, 207 examined | IXSCAN, 0 examined |
| FEG dashboard | COLLSCAN, 207 examined | IXSCAN, 27 examined / 27 returned |
| NOC unassigned queue | COLLSCAN, 207 examined | IXSCAN, 5 examined / 5 returned |

At 207 documents a collection scan is invisible. At 200,000 it is the difference between milliseconds and
seconds, and it scales linearly with *every concurrent user*.

**2. List endpoints return whole documents, including every embedded photo.**
`api_all_fe`, `api_all_noc_trackers`, `api_unassigned_trackers` and `api_my_installations` all call
`find(...)` with **no projection**. A dashboard that renders a table of IDs and statuses downloads every
site-verification photo, SIM photo and firmware photo in the result set. This is the single largest
avoidable cost in the app.

**3. Everything is polled, and every poll is a full refetch.**

| Poller | Interval | Payload |
|---|---|---|
| FE dashboard `loadInstallations` | 30 s | full `all-fe` |
| NOC dashboard `loadTrackers` | 30 s | full `all-noc` (all trackers, all users) |
| NOC dashboard reassignment requests | 30 s | full list |
| NOC tracker detail `loadTracker` | 15 s | full tracker doc incl. images |
| FE tracker detail `loadTracker` | 30 s | full tracker doc incl. images |
| Chat `loadChat` | 5 s | **every message ever sent in the thread, with media inline** |

Socket.IO rooms already exist and already broadcast; the polling is belt-and-braces that never got removed.

**4. Dashboard tab counts are computed client-side** from the full list (`allInstallations.filter(...).length`
in `fe_dashboard.html`). The counts therefore cannot appear until the entire multi-megabyte payload has
downloaded and parsed — this is why *"the landing page takes forever to reflect the counts"*. The counts are
six `count_documents()` calls that the server could answer in single-digit milliseconds off the indexes.

**5. Static assets are served with `no-cache`.** `app.config['SEND_FILE_MAX_AGE_DEFAULT'] = 0` plus
`TEMPLATES_AUTO_RELOAD = True` are development settings. Roughly 300 KB of CSS/JS/fonts is revalidated on
every single page load, per user.

**6. The serving model is a development server.** `SocketIO(app, async_mode='threading')` with
`socketio.run(...)` runs the **Werkzeug development server**, one thread per connection, one process.
(The comment above `socketio.run` claims `eventlet.monkey_patch()` is called at module top — it is not.
There is no monkey-patching anywhere. The comment is wrong; the async mode is `threading`.)
There is also no `message_queue`, so Socket.IO **cannot** be scaled to more than one process: a second worker
would not see the first worker's rooms, and broadcasts would reach only the clients attached to that worker.

**7. N+1 query patterns.** `api_noc_users_stats` issues `2 × N` `count_documents()` calls, one pair per NOC
operator. `api_all_fe` for `ROLE_FS` does a `users` lookup and then an `$in` over the result.

**8. Concurrency correctness bugs.** See §15.6 — these are not performance issues, they are data-integrity
issues that only appear under parallel load, which is exactly the scenario being planned for.

### 15.3 What breaks at target scale

Target: ~2,000 field engineers and ~300 NOC operators working simultaneously.

The NOC dashboard poll alone, **at today's tiny dataset**:

```
4.2 MB x 300 NOC users / 30 s  =  42 MB/s sustained  =  336 Mbps
```

That is with 207 trackers. Tracker volume grows without bound — at 20,000 trackers the same response is
roughly 400 MB and the arithmetic stops being meaningful.

Chat is worse per-client because the interval is 6x shorter:

```
2.2 MB / 5 s = 440 KB/s per open chat tab
1,000 FEs with a tracker open = 440 MB/s
```

Both numbers are served by a single-process development server. The practical ceiling today is on the order
of **tens** of concurrent users, not thousands.

### 15.4 The media pipeline — why the same photo has three different sizes

This is the answer to "why is an iPhone photo 3 MB, an in-app capture 400 KB, and an uploaded copy 600 KB".

**There are two independent downsizing stages, and they are not the same stage.**

**Stage 1 — in-app camera capture (client).** The in-app camera does *not* invoke the phone's camera app. It
calls `getUserMedia()` and grabs a frame from a **video stream**, then draws it to a canvas and encodes it.
A video stream is capped at video capture modes — typically 1080p — no matter what the sensor can do for a
still. So an in-app capture is ~2.07 MP where the native still is ~12 MP. **The resolution is lost at
capture time; nothing downstream removes it.** This is a hard platform limit of `getUserMedia`, not a
setting. The capture code itself is correct — the canvas is sized from `video.videoWidth` /
`videoHeight`, never the displayed element size, so no *further* downscaling happens.

**Stage 2 — chat upload (server).** `api_upload_chat_file` opens the uploaded file with Pillow, resizes the
longest edge down to `IMAGE_MAX_DIM`, and re-encodes as JPEG at `IMAGE_QUALITY`. A 4032x3024 phone still
becomes 1920x1440.

Measured through the real pipeline (synthetic 4032x3024 source; absolute KB are inflated because the test
image is noise, the *ratios* are what matter):

| Path | Output | File | Stored as base64 |
|---|---|---|---|
| Phone native still | 4032x3024 | 6,799 KB | 9,066 KB |
| Chat upload — old settings (1024 px, q85) | 1024x768 | 367 KB | 490 KB |
| Chat upload — current (1920 px, q95) | 1920x1440 | 2,198 KB | 2,931 KB |
| In-app capture (`getUserMedia` 1080p, q95) | 1920x1080 | 1,676 KB | — |
| Passthrough re-encode, no resize | 4032x3024 | 5,705 KB | 7,606 KB |

So the observed ordering falls out exactly: **in-app capture (1920x1080, 2.07 MP) < uploaded copy
(1920x1440, 2.76 MP) < original (12 MP)**. The uploaded copy is bigger than the in-app capture because it
keeps the 4:3 aspect of the sensor rather than the 16:9 of the video stream — about 33% more pixels.

**Was quality being degraded? Yes, in two places, both now addressed:**
- Chat uploads were capped at **1024 px / quality 85**. Now `1920 / 95` by default and configurable.
- Downloads used to re-wrap the data URL with a hardcoded `.jpg` extension. They now save the stored bytes
  verbatim as a Blob — a download never re-encodes, so it is byte-identical to what is stored.

**Configuration (added 2026-09-26).** `MEDIA_PROFILE` selects a preset; individual knobs override it.

| Env var | Default | Meaning |
|---|---|---|
| `MEDIA_PROFILE` | `balanced` | `compact` \| `balanced` \| `original` |
| `IMAGE_MAX_DIM` | from profile | Longest edge for the server-side resize. **`0` = never resize.** |
| `IMAGE_QUALITY` | from profile | JPEG quality (1-100) for the server-side re-encode |
| `CAPTURE_MAX_DIM` | from profile | Requested camera width (`ideal`), sent to the browser |
| `CAPTURE_QUALITY` | from profile | Canvas JPEG quality (0-1), sent to the browser |

| Profile | Server resize | Server quality | Capture dim | Capture quality |
|---|---|---|---|---|
| `compact` | 1280 px | 82 | 1280 | 0.82 |
| `balanced` | 1920 px | 95 | 1920 | 0.95 |
| `original` | none | 98 | 4096 | 0.98 |

The server publishes the capture half to the browser as `window.MEDIA_CONFIG`, and every capture site calls
`window.cameraConstraints()` / `window.captureQuality()` (both defined in `base.html`). **Do not hardcode
camera constraints or `toDataURL` quality in a template** — both ends must follow one policy.

> **Before switching to `original`, read §15.5 item 4.** At `original`, a single photo is ~7.6 MB of base64
> *inside a document*. A tracker holds up to 8 images; Mongo's hard document limit is 16 MB. `original` is
> only safe once media has been moved out of documents.

### 15.5 Remediation plan

Ordered by payoff per unit of risk. Items 1 is done; the rest are the forward plan.

**1. Apply the indexes. — DONE 2026-09-26.** `python scripts/create_indexes.py`. Idempotent, safe to re-run.
Run it on every environment, including production. (Two bugs in the tooling were fixed at the same time:
the script crashed printing a box-drawing character to a cp1252 Windows console *after* creating the
indexes, so it looked like it had failed; and `seed_users.py` created the `users.username` index unnamed,
colliding with `create_indexes.py`'s named version.)

**2. Project away media in every list endpoint.** Highest payoff remaining, lowest risk. Dashboards never
render embedded photos — only the detail view does.

```python
# Fields a list view never needs. Keep in one place so every list endpoint agrees.
TRACKER_LIST_PROJECTION = {
    'site_verification.images': 0,
    'sim.sim1.images': 0,
    'sim.sim2.images': 0,
    'firmware.images': 0,
    'router.images': 0,
    'events': 0,            # timelines are detail-only
}
trackers = list(mongo.db.trackers.find(query, TRACKER_LIST_PROJECTION)
                                 .sort('created_at', -1))
```

Expected effect on the measured baseline: `all-noc` drops from 4.2 MB to roughly 1.3 MB — and the saving
grows as photo usage grows. Apply to `api_all_fe`, `api_all_noc_trackers`, `api_unassigned_trackers`,
`api_my_installations`.

**3. Server-side counts and pagination.** Make the tab counts a separate, tiny, index-only endpoint so they
render immediately instead of waiting on the list:

```python
@app.route('/api/trackers/counts')
@login_required
def api_tracker_counts():
    scope = _visibility_query()          # same role filter the list endpoints use
    pipeline = [{'$match': scope}, {'$group': {'_id': '$status', 'n': {'$sum': 1}}}]
    return jsonify({r['_id']: r['n'] for r in mongo.db.trackers.aggregate(pipeline)})
```

Then paginate the list itself (`?page=`/`?limit=`, default 50) and have the client request more on scroll.
Factor the per-role visibility filter out of `api_all_fe` into `_visibility_query()` so counts, list and
pagination cannot drift apart.

**4. Get media out of documents.** This is the structural fix that makes everything else hold.
Store photos and voice notes in **GridFS** (already available — no new infrastructure) or an object store,
keep only `{file_id, mime, bytes, width, height}` in the tracker/message, and serve them from
`GET /api/media/<file_id>` with `Cache-Control: public, max-age=31536000, immutable`. Benefits, all at once:
documents shrink by ~70%, list responses stop carrying blobs, media is fetched once and then cached by the
browser instead of re-downloaded on every 5-second poll, and the 16 MB document ceiling stops being a
design constraint — which is what makes `MEDIA_PROFILE=original` viable.

**5. Chat: fetch incrementally, and never inline media in the list.**

```python
since = request.args.get('since')        # ISO timestamp of the newest message held
q = {'tracker_id': tracker_id}
if since:
    q['timestamp'] = {'$gt': datetime.fromisoformat(since)}
msgs = list(mongo.db.chat_messages.find(q, {'file_url': 0}).sort('timestamp', 1).limit(200))
```

With media served by URL (item 4) and `since` filtering, the steady-state chat poll goes from **2.2 MB every
5 seconds** to a few hundred bytes. Combined with item 6, to nothing at all.

**6. Delete the polling.** Socket.IO rooms, broadcasts and reconnect-rejoin already work. Drop
`setInterval(loadChat, 5000)`, `setInterval(loadTracker, 15000/30000)` and the two dashboard 30-second
timers to a slow safety-net reconcile (120 s+) and let the sockets carry updates. Keep one manual refresh
control. This is the difference between load scaling with *user count* and load scaling with *event rate*.

**7. Cache static assets.** Remove the two development settings and version the URLs:

```python
app.config['SEND_FILE_MAX_AGE_DEFAULT'] = 31536000      # 1 year; bust via ?v=<build>
app.config['TEMPLATES_AUTO_RELOAD'] = os.environ.get('FLASK_DEBUG', '').lower() == 'true'
```

**8. Fix the N+1 in `api_noc_users_stats`** — one aggregation instead of `2 x N` counts:

```python
pipeline = [
    {'$match': {'noc_assignee': {'$ne': None}}},
    {'$group': {'_id': {'a': '$noc_assignee',
                        'done': {'$eq': ['$status', STATUS_INSTALLATION_COMPLETE]}},
                'n': {'$sum': 1}}},
]
```

**9. Run a real server, and make multi-process possible.** `async_mode='threading'` on the Werkzeug dev
server is the hard ceiling. Move to gevent (already installed) and add a Redis message queue so Socket.IO
rooms are shared across workers:

```python
socketio = SocketIO(app, cors_allowed_origins="*", async_mode='gevent',
                    message_queue=os.environ.get('SOCKETIO_MESSAGE_QUEUE'))  # redis://...
```

```
gunicorn -k geventwebsocket.gunicorn.workers.GeventWebSocketWorker -w 4 app:app
```

**Without `message_queue`, more than one worker is silently broken** — a broadcast only reaches clients
connected to the worker that emitted it. Do not add workers before adding the queue. Note §9's existing
warning: do not use the ops console's "Waitress Service" option, which breaks WebSockets.

Also raise the Mongo pool to match worker concurrency:
`MONGO_URI=...?maxPoolSize=200&minPoolSize=10&waitQueueTimeoutMS=5000`.

**10. Aggregations for analytics.** Several analytics endpoints pull documents into Python and iterate.
Move to `$group`/`$avg`/`$sum` pipelines (already flagged in §14).

### 15.6 Correctness bugs that only appear under parallel load

These are not throughput problems. They are silent data corruption that surfaces exactly when many FEs work
at once — the scenario being planned for.

**`tracker_id` is generated by counting documents.**

```python
'tracker_id': f"SDWAN-{now.year}-{mongo.db.trackers.count_documents({}) + 1:06d}",
```

Two FEs creating a tracker in the same instant both read the same count and get **the same `tracker_id`**.
It is also wrong after any deletion, and `count_documents({})` is an O(n) scan on every create. Replace with
an atomic counter:

```python
seq = mongo.db.counters.find_one_and_update(
    {'_id': f'tracker_{now.year}'}, {'$inc': {'seq': 1}},
    upsert=True, return_document=ReturnDocument.AFTER)['seq']
tracker_id = f"SDWAN-{now.year}-{seq:06d}"
```

**`sdwan_id` uniqueness is check-then-insert.** `api_create_tracker` does `find_one` and then `insert_one` —
two concurrent creates with the same SDWAN ID both pass the check. The unique index
(`trackers_sdwan_id_unique`) is the real guard and is **now applied**, so the second insert will raise
`DuplicateKeyError`. Catch it and return the same 409 the pre-check returns, rather than letting it 500.

**Event appends are safe; whole-document writes are not.** `events[]` uses `$push`, which is atomic. Audit
any code path that reads a tracker, mutates it in Python and writes the whole document back — that is a
lost-update race. Prefer targeted `$set`/`$push`.

### 15.7 Current status

| Item | State |
|---|---|
| Indexes applied and verified | Done 2026-09-26 |
| `create_indexes.py` console crash | Fixed |
| `seed_users.py` index-name collision | Fixed |
| Configurable media policy (`MEDIA_PROFILE` et al.) | Done 2026-09-26 |
| Downloads preserve stored bytes exactly | Done |
| List-endpoint projections | **Pending — item 2** |
| Server-side counts + pagination | **Pending — item 3** |
| Media out of documents (GridFS) | **Pending — item 4, unblocks `original` profile** |
| Incremental chat fetch | **Pending — item 5** |
| Remove polling in favour of sockets | **Pending — item 6** |
| Static asset caching | **Pending — item 7** |
| Production server + `message_queue` | **Pending — item 9** |
| `tracker_id` race | **Pending — §15.6** |
