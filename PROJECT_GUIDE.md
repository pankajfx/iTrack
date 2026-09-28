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
| 5 | [Real-time (Socket.IO) — architecture & robustness](#5-real-time-socketio--architecture--robustness) | live updates, rooms, reconnects, proxies, socket capacity |
| 6 | [API surface](#6-api-surface) | routes, endpoints, request/response |
| 7 | [Conventions & code map](#7-conventions--code-map) | timestamps, events, naming, `app.py` layout |
| 8 | [Security — controls, production settings & residual risks](#8-security--controls-production-settings--residual-risks) | auth, sessions, CSRF, headers, go-live checklist |
| 9 | [Production deployment — Windows (primary) & Linux](#9-production-deployment--windows-primary--linux) | serving model, service, proxy, workers & sizing, gunicorn, operations |
| 10 | [Mobile-first & responsive](#10-mobile-first--responsive) | any UI/template/CSS work |
| 11 | [Pros / cons / loopholes](#11-pros--cons--loopholes) | quick health snapshot |
| 12 | [One-time scripts](#12-one-time-scripts) | seeding, indexes, ops console |
| 13 | [Dev commands & environment variables](#13-dev-commands--environment-variables) | running locally, config |
| 14 | [Known issues & improvement roadmap](#14-known-issues--improvement-roadmap) | what to build/fix next |
| 15 | [Performance, scale & the media pipeline](#15-performance-scale--the-media-pipeline) | slowness, load, concurrency, image/audio sizing |
| 16 | [Background jobs — Celery, APScheduler & scheduled maintenance](#16-background-jobs--celery-apscheduler--scheduled-maintenance) | periodic tasks, job queues, backups, cleanup |

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
| Backend | Flask 3.0, Flask-SocketIO 5.3.6, Python 3.11. Serving: **gevent** in production, threading in development ([§9](#9-production-deployment--windows-primary--linux)) |
| Database | MongoDB via PyMongo 4.6.1 + Flask-PyMongo 2.3.0 |
| Auth | Signed-cookie Flask sessions, revocable server-side (`session_epoch`); Werkzeug scrypt password hashing; CSRF tokens (no JWT) ([§8](#8-security--controls-production-settings--residual-risks)) |
| Frontend CSS | Tailwind 3.4.1, **pre-compiled** to `static/css/output.css` |
| Real-time | Socket.IO 4.7.2 client, **self-hosted** ([static/js/vendor/socket.io.min.js](static/js/vendor/socket.io.min.js), loaded at [base.html:911](templates/base.html#L911)); one shared socket per page, REST catch-up after any gap ([§5](#5-real-time-socketio--architecture--robustness)) |
| Icons | Material Symbols (self-hosted woff2). **Font Awesome is CSS/emoji-emulated** — no FA font files are served (the old `tech.md` claim of an FA 7.2.0 dependency is inaccurate). |
| Fonts | Inter, Manrope, Outfit, Fjalla One — all **self-hosted** variable woff2/ttf in `static/fonts/`, declared in `static/css/fonts.css`. No Google Fonts requests. |
| Charts | Chart.js 4.4.0 + chartjs-adapter-date-fns + hammerjs + chartjs-plugin-zoom, all **self-hosted** in `static/js/vendor/` (analytics dashboard) |
| Images & media | Pillow (chat photo re-encode, off the event loop); files in GridFS, served by `/api/media/<id>` |
| Excel | openpyxl (analytics export + user seeding) |
| Templates | Jinja2 |

**Single-file backend:** all routes + business logic live in `app.py` (~4,850 lines). See the section map in [§7](#7-conventions--code-map).

**Templates (verified current set):** `base.html`, `login.html`, `theme_styles.html`, `fe_dashboard.html`, `fe_new_installation.html`, `fe_tracker_detail.html`, `noc_dashboard.html`, `noc_tracker_detail.html`, `analytics_dashboard_v1.html`, `chat_component.html`, `admin_users.html`.
Own JS: `static/js/secure_fetch.js` (loaded first by `base.html`; adds the CSRF header to every state-changing `fetch` and sends expired sessions to the login page). `static/js/realtime_handler.js` is legacy and no template loads it. (Old docs referenced `ztp_component.html`, `static/fontawesome-css/`, `static/webfonts/` — none of these are present/used.)

---

## 4. Data model

MongoDB DB: `sdwan_tracker`. Collections:

- **`users`** — accounts with role + hierarchy fields (`field_engineer_group`, `field_support`, `region`, `zone`, `state`, etc.). **This is the collection the app authenticates against.**
- **`trackers`** — installation docs with embedded sub-documents (below).
- **`chat_messages`** — FE-NS coordination messages. Photos and voice notes live in GridFS and are referenced by id; the API hands out `/api/media/<id>` URLs ([§15.4](#154-the-media-pipeline--why-the-same-photo-has-three-different-sizes)).
- **`predefined_reasons`** — dropdown options for SIM/ZTP/HSO failures and delay tags (seeded by `init_db.py`).
- **`audit_logs`** — append-only record of admin sign-ins and user changes (never passwords); expires after `AUDIT_RETENTION_DAYS`.
- **`notifications`** — user notifications.
- **`login_attempts`** — failed sign-ins, for throttling; expires automatically ([§8](#8-security--controls-production-settings--residual-risks)).
- **`counters`** — the atomic per-year `tracker_id` sequence.
- **`fs.files` / `fs.chunks`** — GridFS media; each file's `metadata.tracker_id` decides who may fetch it.

### Tracker embedded sub-documents
`fe`, `sim` (`sim1`/`sim2` with `attempts[]`, `failure_reason`), `router`, `ztp` (`performed_by`, `failure_reason`, `root_cause_of_initial_failure`), `hso` (`attempts[]`), `site_verification`, `reassignment_request`, `events[]`, and **`stage_timestamps`** (flat KPI timestamps stamped on first occurrence of each stage — powers analytics without scanning `events[]`). Duration math lives in `calculate_stage_times()` [app.py:2490](app.py#L2490).

### Indexes
The **canonical** index setup is `scripts/create_indexes.py` (idempotent; covers `trackers`, `users`, `chat_messages`, `predefined_reasons`, `notifications`). Run it on any fresh or production DB.

> ⚠️ **`init_db.py` is legacy / partially wrong.** It creates a `noc_users` collection the app never uses and does **not** create the `users` collection or its indexes (despite old docs claiming it seeds "sample users"). Use `scripts/create_indexes.py` for indexes and `scripts/seed_users.py` for users. See [§12](#12-one-time-scripts).

---

## 5. Real-time (Socket.IO) — architecture & robustness

**Feasibility verdict:** Socket.IO is the right transport for this app and is production-ready on the Windows server. One gevent process held 300 authenticated live sockets with ~100 dashboard requests/s on top ([§9.5](#95-capacity--sizing--how-many-workers)), and pages recover from a 45-second server outage on their own. The design rule that makes it robust: **the socket is a fast signal; the REST API is the source of truth.** Anything a page may have missed is re-fetched, so no event is ever the only copy of a change.

### 5.1 Rooms and events

Every socket belongs to a signed-in user ([`handle_connect`, app.py:4685](app.py#L4685)). Rooms are joined on the server's authority, never the client's.

| Room | Who is in it | Authorized by | Events delivered |
|---|---|---|---|
| `user_<id>` | every socket of that user, joined at connect | the session | `session_ended` (account revoked), `user_notification` |
| `tracker_<id>` | tracker detail pages (`join_tracker`) | `visible_tracker()` — the same rule as the REST API ([app.py:1341](app.py#L1341)) | `tracker_update` (with the full, media-resolved tracker when `SOCKET_INCLUDE_FULL_DATA`), `new_chat_message` (media as `/api/media` URLs, never bytes) |
| `dashboard_<role>` | dashboards (`join_dashboard`) | the role in the session — a role sent by the client is ignored | `dashboard_update` carrying only `{event_type, tracker_id}`; each dashboard re-queries its own scoped data |

Broadcast helpers: `broadcast_tracker_update`, `broadcast_chat_message`, `broadcast_dashboard_update`, `broadcast_to_user` ([app.py:4741-4810](app.py#L4741)).

Connection-level protections: sockets from other origins are refused (`CORS_ORIGINS`, default same-origin). A refused connection carries the reason `auth_required`, which sends the page to `/login?expired=1`. Clients may send at most 64 KB per message. When an admin deactivates a user or changes their password, `session_ended` is emitted at once, and a sweep every `SOCKET_SESSION_SWEEP_SECONDS` (60, [app.py:4661](app.py#L4661)) disconnects any socket whose session was revoked.

### 5.2 Delivery guarantees — and how the app closes the gaps

Socket.IO delivers **at most once, in order, while connected**. Nothing is queued for a disconnected client and the server keeps no replay log, so the app never relies on a single event:

| Situation | What repairs it |
|---|---|
| Socket dropped and came back (network blip, server restart, deploy) | `window.onSocketReconnect(fn)` re-runs each page's loader on every re-connect: chat `loadChat` (incremental, `?since=`, [chat_component.html:217](templates/chat_component.html#L217)), tracker pages `loadTracker`, dashboards `loadTrackers` / `loadInstallations` and the transfer requests. Rooms are re-joined by the `onSocketReady` callbacks, which run on every connect. |
| Phone locked or tab in the background (mobile browsers freeze it) | On return the page reconnects at once instead of waiting out the backoff, and re-runs the catch-up if it was hidden for more than 30 s, even when the socket never noticed a disconnect ([base.html:1018](templates/base.html#L1018)). |
| An event lost without any disconnect (rare) | Safety-net refresh: chat 60 s, dashboards 120 s, tracker detail 15 s (NOC) / 30 s (FE). |
| The same chat message arrives live **and** through catch-up | Rendered once: messages are de-duplicated by `_id`. |

Acknowledged delivery with server-side replay was considered and rejected: it needs a persistent per-client cursor and gains nothing over the incremental REST catch-up for this workload.

### 5.3 Client connection policy ([base.html:961](templates/base.html#L961))

- **One socket per page** (`window.socket`), shared by the page and the chat component. There used to be two.
- **Long-polling first, then upgrade to WebSocket.** The 4.7.2 client does not fall back from a failed WebSocket to polling, so WebSocket-first meant *no live updates at all* behind a proxy that does not pass upgrades. Polling works through anything; the upgrade happens wherever the proxy allows it.
- **Reconnect forever**, backoff 1 s → 15 s with ±50 % jitter so a server restart does not bring every client back in the same second; 20 s connect timeout. The old client gave up after 10 attempts (~30 s) and stayed offline until reloaded.
- The browser's `online` event (network back) reconnects immediately.
- A **"Reconnecting…" pill** ([base.html:400](templates/base.html#L400)) shows whenever the socket is down.
- Only signed-in pages open a socket; the login page opens none.

### 5.4 Server side: heartbeat, proxies, processes

- **Heartbeat:** the server pings every `SOCKETIO_PING_INTERVAL` (25 s) and drops a client that stays silent for `SOCKETIO_PING_TIMEOUT` (20 s) more ([app.py:142](app.py#L142)). A reverse proxy must allow idle connections longer than the interval: the Nginx config generated by the ops console uses `proxy_read_timeout 120s`; Caddy has no idle limit on WebSockets.
- **Proxies** must pass the WebSocket upgrade (Caddy: automatic; Nginx: `Upgrade`/`Connection` headers, generated by the ops console) and forward `Host`, which the origin checks compare against. If the upgrade is blocked, clients stay on long-polling: still live, just more requests.
- **Serving mode:** gevent in production — one process, one event loop for HTTP and every socket ([§9](#9-production-deployment--windows-primary--linux)). Threading mode spends an OS thread per connection (1,213 threads at 300 sockets).
- **More than one process** needs a message queue (`SOCKETIO_MESSAGE_QUEUE`, Redis) so an emit in one process reaches clients held by another, and **sticky sessions** at the proxy, because a Socket.IO session lives in the process that opened it. See [§9.6](#96-scaling-out--more-than-one-process).

### 5.5 Measured behaviour (2026-09-28, real Chrome, throwaway database)

| Scenario | Result |
|---|---|
| 45 s server outage | **Before:** the page never reconnected. **After:** reconnected 10.5 s after the server came back (backoff), showed the message sent while it was offline without a reload, and received new messages live. |
| 12 s outage | Reconnected 0.5 s after the server came back. |
| Chat NOC → FE and FE → NOC | Arrives live, exactly once on each side. |
| Admin deactivates a signed-in user | Their open page goes to the login screen in 0.1–0.3 s. |
| Live `tracker_update` re-render | Photos still load (media resolved to `/api/media` URLs). |
| 300 sockets in one gevent process | 12 OS threads, 112 MB; one chat message reached all 300 in ≤ 188 ms. |

### 5.6 Configuration

| Var | Default | Effect |
|---|---|---|
| `REALTIME_MODE` | `hybrid` | `socket` \| `api` \| `hybrid`: whether pages use the socket payload or re-fetch over REST |
| `SOCKET_TIMEOUT` | `2000` | ms the client waits for a socket update before falling back to REST |
| `SOCKET_INCLUDE_FULL_DATA` | `true` | include the full tracker in `tracker_update` |
| `SOCKETIO_PING_INTERVAL` / `SOCKETIO_PING_TIMEOUT` | `25` / `20` | heartbeat, seconds |
| `SOCKET_SESSION_SWEEP_SECONDS` | `60` | how often sockets of revoked sessions are disconnected |
| `CORS_ORIGINS` | *(same origin)* | comma-separated origins allowed to open sockets. A list **replaces** the same-origin default, so include the site's own origin; `*` opens sockets to any website (don't) |
| `SOCKETIO_MESSAGE_QUEUE` | *(none)* | `redis://…`, required before running more than one process |

### 5.7 Known limits

- Room membership is checked when a page joins. A user who loses access to a tracker *while viewing it* (for example, it is transferred away) keeps receiving that tracker's live updates until the page is closed or the socket reconnects. The REST API refuses them immediately.
- `dashboard_update` makes a dashboard reload its current page of results rather than patch one card. That is cheap now that lists are paged ([§14](#14-known-issues--improvement-roadmap)).

---

## 6. API surface

`app.py` route groups (see [§7](#7-conventions--code-map) for the section map):

- **Infrastructure:** `GET /healthz` (no sign-in; up/down plus a database ping, for proxies and monitors), `GET /api/csrf-token` (a fresh CSRF token for the fetch wrapper), `GET /api/media/<id>` (GridFS media, authorized per tracker).
- **Page routes:** `/`, `/login`, `/fe/*`, `/noc/*`, `/analytics/dashboard`, `/admin`; legacy redirects `/franchise/*`, `/field_support*/*`.
- **Auth & login enumeration:** `POST /api/auth/login`, `POST /api/auth/logout`, and unauthenticated `GET /api/login/*` dropdown-population endpoints (public by design; see [§8.3](#83-residual-risks-accepted-or-tracked)).
- **Tracker query:** `/api/trackers/all-fe`, `/all-noc` (`?filter=&page=&limit=`), `/unassigned`, `/my-installations`, `/api/trackers/counts`, `/api/trackers/search`, `/api/trackers/<id>`, `/api/trackers/check/<sdwan_id>`, `/api/hierarchy/*`. Every by-id read goes through `visible_tracker()`.
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
- **Never interpolate user-typed data into HTML raw.** Anything that came from a person - customer, SDWAN ID, names, phones, reasons, search matches - goes through `esc()` inside a template literal, and through `escJs()` when it is an argument inside an inline handler (`onclick="fn(${escJs(x)})"`). HTML-escaping alone is not enough in a handler: the browser decodes `&#39;` back to `'` before the JavaScript is parsed. IDs, dates, counts and internal constants need neither. Prefer `textContent` when building a single node.
- **Chat bubbles have one renderer.** `renderMessageBubble(msg, currentRole)` in [chat_component.html](templates/chat_component.html) is used by both the API render (`displayMessages`) and the Socket.IO append (`appendNewMessage`). They used to build different markup, so a message changed shape on reload. Add message types there, not in either caller.
- **Voice notes carry their own duration.** `MediaRecorder` emits a live-stream container with no Duration header, so players report `Infinity` — controls read 0:00, the scrubber is dead and the clip cannot be replayed. Three things address this and all are needed: the client measures the length while recording and sends it as `duration` (stored on the message doc by `api_send_chat_message`); `fixAudioDurations()` seeks past the end to force the browser to resolve the real duration; and the clip's `src` goes on the `<audio>` element rather than a `<source type="...">`, which the browser skips outright when it does not claim to support the declared type. The recorder also picks its container from `MediaRecorder.isTypeSupported` (WebM/Opus on Chrome and Firefox, MP4/AAC on Safari) instead of hardcoding WebM.
- **Image quality is preserved end to end** — downloads re-wrap the stored bytes as a Blob rather than re-drawing through a canvas, so the saved file is byte-identical to what is stored. Captures are taken at the camera's native stream resolution (canvas sized from `videoWidth`/`videoHeight`, never the displayed size), request `width/height: { ideal: 1920/1080 }` and encode at JPEG `0.95`; chat uploads are re-encoded server-side per `MEDIA_PROFILE` (default: longest side 1920px, quality 95) by `_reencode_chat_image` ([app.py:3549](app.py#L3549)), off the event loop. Files are stored in GridFS and served by URL, so higher settings cost storage and download size, not document size.

### `app.py` section order
1. Config & setup → 2. Helpers (`get_utc_now`, `serialize_doc`, `make_event`, `login_required`, `is_chat_unlocked`) → 3. Page routes → 4. Auth/login APIs → 5. Tracker query APIs → 6. Tracker creation → 7. NOC ops (assign/SIM/ZTP/HSO) → 8. Chat APIs → 9. Analytics APIs → (10) Admin panel → (11) Socket.IO handlers & broadcast helpers → entry point.

---

## 8. Security — controls, production settings & residual risks

> **Status 2026-09-28:** every finding from the pre-production audit is fixed and verified. A scripted probe of 18 abuse scenarios, all 18 of which succeeded before this work, now fails on every one, while 7 legitimate flows keep working, with no server errors, in both serving modes (threading and gevent). Real-browser suites cover CSRF, CSP (no violations on any page), session expiry and live updates. The probes live outside the repo because they need the credential workbook.

### 8.1 Controls in place

| Area | Before | Now | Code |
|---|---|---|---|
| Session signing key | Fixed public default in `app.py` | The app refuses to start unless `SECRET_KEY` has ≥ 32 characters and is not a known placeholder (tolerated only with `FLASK_DEBUG=true`) | [app.py:111](app.py#L111) |
| Tracker reads | Any signed-in user could read any tracker by id | Every by-id read, chat read and media file goes through `visible_tracker()`, the user's dashboard scope; out-of-scope ids answer 404, so probing reveals nothing | [app.py:1341](app.py#L1341) |
| Chat writes | Any signed-in user could post | Only the owning FE, the assigned NS and the NOC Support Group | [app.py:1355](app.py#L1355) |
| Live updates (Socket.IO) | No authentication, any origin, client-chosen rooms and roles | Session required to connect; rooms authorized server-side; same-origin only; revoked sessions disconnected; dashboard broadcasts carry ids, not data | [§5.1](#51-rooms-and-events) |
| Sign-in | No throttling; query operators accepted; response time revealed which accounts exist | Failures counted in MongoDB, shared by every process: 5 per account+IP, 20 per account, 30 per IP in 15 min, then `429` with `Retry-After`; inputs must be strings; unknown accounts cost the same time as wrong passwords | [app.py:583](app.py#L583), [app.py:1066](app.py#L1066) |
| Sessions | No way to revoke a session | 12 h sliding lifetime; `session_epoch` revokes all of a user's sessions on password change, deactivation or deletion, re-checked every 30 s per process; API calls then get `401` + `X-Auth-Required` and pages go to `/login?expired=1` | [app.py:661](app.py#L661), [app.py:688](app.py#L688) |
| CSRF | None | Per-session token on every POST/PUT/PATCH/DELETE, attached automatically by [static/js/secure_fetch.js](static/js/secure_fetch.js), plus an Origin/Referer host check; a stale token is refreshed and the request retried once | [app.py:765](app.py#L765) |
| Cookies | Framework defaults | `HttpOnly`; `SameSite=Lax` (Strict would sign users out when they open a tracker link from WhatsApp or email); `Secure` whenever the request arrived over HTTPS, or always with `SESSION_COOKIE_SECURE=true` | [app.py:273](app.py#L273) |
| Response headers | None | CSP (scripts, styles, fonts and connections same-origin, plus the geocoder), `X-Frame-Options: DENY`, `nosniff`, `Referrer-Policy`, `Permissions-Policy` (camera, microphone, location: this site only), `Cross-Origin-Opener-Policy`, HSTS when `HSTS_MAX_AGE` is set, `Cache-Control: no-store` on API JSON | [app.py:316](app.py#L316) |
| Admin panel | Page public; password `qwerty` compared in plain text; no limits | Disabled unless `ADMIN_PASSWORD` is ≥ 12 characters and not a common password; constant-time comparison; the same lockout as sign-in; 30-minute idle expiry (`ADMIN_SESSION_MINUTES`); every sign-in and user change written to `audit_logs`; output escaped | [app.py:4453](app.py#L4453) |
| Uploads and media | Client-chosen content types served inline | Only allow-listed image and audio types are served inline; anything else downloads as `application/octet-stream` under a sandboxing CSP; chat photos are re-encoded; requests capped at 16 MB | [app.py:430](app.py#L430), [app.py:809](app.py#L809) |
| Stored XSS | User-typed fields rendered raw on dashboards | `esc()` / `escJs()` on every user-typed value ([§7](#7-conventions--code-map)) | dashboards |
| Seeded passwords | Password defaulted to the username | `seed_users.py` skips rows without a password | [scripts/seed_users.py](scripts/seed_users.py) |
| Client IPs behind the proxy | Every user appeared as 127.0.0.1 | `TRUST_PROXY_HOPS=1` gives the real client IP to the login limits and HTTPS detection to cookies and HSTS, and binds the app to 127.0.0.1 so nothing can bypass the proxy | [app.py:260](app.py#L260) |

### 8.2 Go-live checklist (production `.env`)

| Setting | Value | Why |
|---|---|---|
| `SECRET_KEY` | 48+ random characters: `python -c "import secrets; print(secrets.token_urlsafe(48))"` | Signs every session. Changing it signs everyone out, which is also the way to invalidate all sessions at once. |
| `ADMIN_PASSWORD` | ≥ 12 characters, not a common password | Otherwise the admin panel stays disabled (the rest of the app runs). |
| `FLASK_DEBUG` | `false` | Debug mode also tolerates a weak `SECRET_KEY`. |
| `SOCKETIO_ASYNC_MODE` | `gevent` | The production server ([§9](#9-production-deployment--windows-primary--linux)). |
| `TRUST_PROXY_HOPS` | `1` behind one Caddy/Nginx; `0` when clients connect directly | Real client IPs for the login limits, HTTPS detection for cookies and HSTS, and a loopback-only bind. Never set it higher than the number of proxies you run: clients could then forge their IP. |
| `SESSION_COOKIE_SECURE` | `true` once the site is HTTPS-only | The cookie never travels over plain HTTP. |
| `HSTS_MAX_AGE` | `31536000`, **only** with a trusted certificate on a stable hostname | Browsers then refuse plain HTTP for that long, and the server cannot take it back. |
| `MONGO_URI` | a dedicated user with `readWrite` on the database, `authSource=admin` | The default URI is unauthenticated localhost. Keep MongoDB bound to 127.0.0.1. |
| `CORS_ORIGINS` / `PUBLIC_ORIGINS` | unset, unless users reach the app under a hostname the proxy does not pass through as `Host` | `CORS_ORIGINS` replaces the socket same-origin rule with an explicit list (include the site's own origin); `PUBLIC_ORIGINS` adds origins to the CSRF check. |
| `CSP_CONNECT_EXTRA` | default (Nominatim) | Change only if the reverse-geocoding service changes. |

**Rotate anything that was ever committed.** Old defaults (the previous `SECRET_KEY` string, `qwerty`) are in git history: treat them as public. Accounts seeded from the workbook keep the workbook's passwords, so hand them out over a trusted channel and reset any that leaked through the admin panel.

### 8.3 Residual risks (accepted or tracked)

- **CSP still allows inline script and style** (`'unsafe-inline'`), because the templates use inline `<script>` blocks and `onclick=` handlers throughout. XSS defence therefore rests on output escaping (`esc()` / `escJs()`, `textContent`). `connect-src` also allows `ws:`/`wss:` to any host, for browsers whose `'self'` does not cover WebSocket URLs. Removing `'unsafe-inline'` means moving every handler into static JS files; tracked in [§14](#14-known-issues--improvement-roadmap).
- **The login pickers list account names publicly** (`GET /api/login/*`). The login screen needs them before anyone is signed in. Throttling limits guessing; the lists reveal names, groups and regions, not credentials.
- **Reverse geocoding goes to a third party.** FE browsers send GPS coordinates to `nominatim.openstreetmap.org`, whose usage policy allows at most one request per second and no bulk use. For stricter data handling, self-host Nominatim and point `CSP_CONNECT_EXTRA` and the two calls in `fe_new_installation.html` / `fe_tracker_detail.html` at it.
- **Live-update rooms are authorized at join time**; see [§5.7](#57-known-limits).
- **The session cookie is signed, not encrypted.** Users can read their own session (id, role, names) but cannot change it. Never put a secret in the session.
- **The admin panel has one shared password and no second factor.** The audit log records the IP of each admin action, not a named person. Limit who knows it, and consider allowing `/admin` only from the NOC network at the proxy.
- **MongoDB access control is the operator's job**; see the checklist above.

### 8.4 Checks after touching auth, sessions, sockets or headers

1. `python app.py` with a short `SECRET_KEY` and `FLASK_DEBUG=false` must refuse to start.
2. Open a tracker page: DevTools → Console shows no Content-Security-Policy violations.
3. Signed in as an FE with no link to a tracker, `GET /api/trackers/<its id>` answers 404.
4. Deactivate a test user in `/admin`: their open page goes to the login screen within a second.

---

## 9. Production deployment — Windows (primary) & Linux

> The production server is Windows. Sections 9.1–9.6 and 9.8 are for it. Section 9.7 covers Linux with gunicorn, which does not run on Windows at all.

### 9.1 Topology

```
 FE phones / NOC desktops
        |  HTTPS 443: pages, API, Socket.IO (long-polling, then WebSocket)
        v
 Caddy (preferred) or Nginx          TLS, compression, WebSocket upgrade,
        |                            X-Forwarded-For / -Proto, Host
        |  http://127.0.0.1:5001
        v
 "ITracker" Windows service (NSSM)   python app.py with SOCKETIO_ASYNC_MODE=gevent:
        |                            one process, one event loop for HTTP and sockets,
        |                            CPU work (scrypt, Pillow) on a thread pool
        |  mongodb://127.0.0.1:27017 (authenticated)
        v
 MongoDB service                     data + GridFS media
```

### 9.2 Choosing the server

| Option | Verdict | Why |
|---|---|---|
| `python app.py` with `SOCKETIO_ASYNC_MODE=gevent` | **Production, Windows and Linux** | gevent's WSGI server with WebSocket support, every connection on one event loop; measured in 9.5. CPU-heavy calls go to a thread pool through `run_blocking()` ([app.py:23](app.py#L23)). |
| `python app.py` with `threading` (the default) | Development only | Werkzeug's development server; one OS thread per connection (1,213 threads at 300 sockets). It refuses to start without a console, so it cannot be a service: the app says so and exits. |
| waitress | Never | WSGI only: it cannot carry WebSocket upgrades. The ops console's old "Waitress Service" option is gone, and the console warns if one is still installed. |
| eventlet | Never | Hangs on the first MongoDB call on Windows (measured) and is deprecated upstream. The app refuses to start with it. |
| gunicorn | Linux only, `-w 1` | Needs `fork`/`fcntl`, so it does not run on Windows. See 9.7 for why more than one worker per instance breaks Socket.IO. |

### 9.3 Install or upgrade on the Windows server

1. **Prerequisites:** Python 3.11 x64 and MongoDB as a Windows service. `exec_prod\deployed\Install-ServerStack.ps1` (as Administrator; PowerShell 7 recommended) downloads Caddy, nginx and NSSM and installs the app's requirements into the venv. The downloads need internet access; on an offline server put `caddy.exe`, nginx and `nssm.exe` in the folders named in its `$Config` first, and it skips them.
2. **Offline wheels.** The server installs Python packages from `exec_prod\wheels`, which is gitignored: it travels with the deploy copy, not with git. On any machine with internet access, from the repo root:
   ```powershell
   python -m pip download -r Requirements.txt -d exec_prod\wheels --only-binary=:all: --platform win_amd64 --python-version 3.11 --implementation cp
   ```
   **Do this before the next deploy.** On 2026-09-28 the folder held six wheels (dnspython, eventlet, greenlet, h11, simple_websocket, wsproto) and none of gevent's. The machine that wrote this guide could not reach PyPI.
3. **Virtual environment:**
   ```powershell
   py -3.11 -m venv venv
   venv\Scripts\python -m pip install --no-index --find-links exec_prod\wheels -r Requirements.txt
   venv\Scripts\python -c "import gevent, geventwebsocket; print('gevent', gevent.__version__)"
   ```
   Tested set: gevent 24.2.1, gevent-websocket 0.10.1, greenlet 3.1.1, zope.event 6.2, zope.interface 8.5, cffi 1.17.1, pycparser 2.22.
4. **Configuration:** copy `.env.example` to `.env` and work through [§8.2](#82-go-live-checklist-production-env). The minimum:
   ```ini
   SECRET_KEY=<48 random characters>
   ADMIN_PASSWORD=<12+ characters>
   MONGO_URI=mongodb://itrack:<password>@127.0.0.1:27017/sdwan_tracker?authSource=admin
   SOCKETIO_ASYNC_MODE=gevent
   TRUST_PROXY_HOPS=1
   SESSION_COOKIE_SECURE=true
   FLASK_DEBUG=false
   ```
5. **Database:** `venv\Scripts\python scripts\create_indexes.py`, then users with `scripts\seed_users.py --dry-run` and again without `--dry-run` ([§12](#12-one-time-scripts)).
6. **Service and proxy.** Edit `$Cfg` at the top of `exec_prod\ServerAdminPankaj_V3.ps1` (the same console as `exec_prod\deployed\ManageServer.ps1`): `AppRoot`, `VenvPython`, `Port`, `LogDir`. Run it as Administrator:
   - **S** installs the app as the `ITracker` service. NSSM runs `python app.py` in gevent mode, starts it at boot after MongoDB, restarts it 5 s after any exit, and writes `LogDir\itracker.out.log` / `itracker.err.log`, rotated at 10 MB.
   - **L** installs Caddy as a service (writing the Caddyfile first if there is none), or **Q** for Nginx. Replace `localhost` with the real hostname and certificate.
   - **Servers that already run Nginx: choose U.** It rewrites `nginx.conf` from the current template, keeps a backup and reloads. Configs written by older consoles pass no WebSocket upgrade and keep nginx's 1 MB upload limit.
   - **A / B / C** start, stop and restart the app, through the service manager when the service exists.
7. **Verify:**
   - `Invoke-WebRequest http://127.0.0.1:5001/healthz -UseBasicParsing` returns `200 {"status":"ok"}`.
   - `LogDir\itracker.out.log` shows `[startup] gevent mode, listening on 127.0.0.1:5001`.
   - In a browser at `https://<host>`: DevTools → Network → filter `socket.io` → a `transport=websocket` request with status **101**. Only `transport=polling` requests means the proxy is not passing the upgrade (live updates still work, less efficiently).
8. **Firewall:** open 443, and 80 if Caddy should redirect or obtain certificates. Keep 5001 and 27017 closed to the network; with `TRUST_PROXY_HOPS=1` the app binds 127.0.0.1 anyway.

**Upgrades:** copy or pull the new code, re-run the `pip install` line if `Requirements.txt` changed, then **C** (restart). Users see sockets drop and reconnect on their own within about 1–15 s, and pages catch up ([§5.2](#52-delivery-guarantees--and-how-the-app-closes-the-gaps)). Sessions survive restarts (signed cookies) unless `SECRET_KEY` changed. Browsers fetch changed CSS/JS automatically, because `STATIC_VERSION` is a fingerprint of `static/`.

### 9.4 Production requirements that are easy to miss

- **HTTPS with a certificate the phones trust.** Camera capture and GPS need a secure context, so over plain `http://<LAN IP>` the FE photo and location features fail. Caddy's `tls internal` is trusted only on machines that ran `caddy trust`, not on field phones. Use a public hostname (Caddy then obtains a certificate itself) or a certificate from your organisation's CA (`tls cert.pem key.pem`).
- **The proxy must pass `Host`.** The CSRF and socket origin checks compare against it. Caddy and the generated Nginx config do. If a proxy rewrites it, list the public origin in `PUBLIC_ORIGINS` and `CORS_ORIGINS`.
- **nginx on Windows tops out near 500 open pages:** one worker, 1,024 connections, two per live socket. Caddy has no such limit, so prefer it.
- **Keep the server clock in sync** (Windows Time service). Timestamps are stored as naive UTC.

### 9.5 Capacity & sizing — how many workers

One process, measured 2026-09-28 on the development machine (8 logical CPUs, Python 3.11, load generator on the same machine), with 300 authenticated sockets open and 30 clients driving the dashboard APIs:

| | threading | gevent |
|---|---|---|
| OS threads with 300 sockets | 1,213 | 12 |
| Memory | 139 MB | 112 MB |
| Dashboard API throughput | ~95 req/s | ~103 req/s |
| Dashboard API p95 | 408 ms | 544–555 ms |
| One chat message to 300 sockets | ≤ 197 ms | ≤ 188 ms |
| 40 simultaneous sign-ins (scrypt), p50 / max | 632 / 899 ms | 686 / 1,021 ms (3,099 ms p50 before the CPU offload) |
| A cheap request during those sign-ins, max | 353 ms | 86 ms (1,640 ms before the offload) |

**How many workers: one process.** The organisation has ~270 accounts. If every one of them had a page open at once, that would still be fewer sockets than the test above. Ordinary use (a dashboard refresh per event plus a 120 s safety net, chat, form posts) is a few requests per second against a measured ~100/s. One gevent process has roughly ten times the headroom this deployment needs.

**The usual gunicorn rule (2 × cores + 1 workers) does not apply.** It is for stateless, synchronous workers. A gevent process is already concurrent, and a Socket.IO session is state that lives in exactly one process.

**When to add processes:** at peak, the app process stays above ~70 % of one CPU core, or dashboard p95 stays above ~1 s, or live connections approach ~1,000 (not measured beyond 300; measure before relying on more). Then run *N* ≈ physical cores − 1 processes (leave a core for MongoDB and the proxy) as described in 9.6.

**MongoDB pool:** `MONGO_MAX_POOL_SIZE` (default 100) is per process, so *N* processes open up to *N* × that many connections. Lower it to 50 from four processes up.

### 9.6 Scaling out — more than one process

Only when 9.5 calls for it. All four parts are required; with any one missing, live updates silently reach only some users:

1. **Message queue**, so an emit in one process reaches clients held by another: `SOCKETIO_MESSAGE_QUEUE=redis://127.0.0.1:6379/0` on every instance, plus the `redis` Python package (not in `Requirements.txt` today; add it together with the queue). On Windows use Memurai (Redis-compatible) or Redis on another host.
2. **Sticky sessions** at the proxy, because a Socket.IO session lives in the process that opened it. Caddy: `lb_policy cookie` (or `ip_hash`). Nginx: `ip_hash` in the `upstream` block. `ip_hash` puts everyone behind one NAT address (a whole office) on the same instance; the cookie policy spreads them. Both generated configs contain the multi-instance form, commented out.
3. **One port per instance**, for example a second NSSM service:
   ```powershell
   nssm install ITracker2 G:\srv\app\itracker\venv\Scripts\python.exe app.py
   nssm set ITracker2 AppDirectory G:\srv\app\itracker
   nssm set ITracker2 AppEnvironmentExtra SOCKETIO_ASYNC_MODE=gevent PORT=5002 PYTHONUNBUFFERED=1
   nssm set ITracker2 AppStdout G:\srv\app\itracker\logs\itracker2.out.log
   nssm set ITracker2 AppStderr G:\srv\app\itracker\logs\itracker2.err.log
   nssm start ITracker2
   ```
4. **Health checks:** `health_uri /healthz` (Caddy) takes an instance out of rotation while its database connection is down.

Already safe across processes: login throttling and the `tracker_id` counter live in MongoDB, and each process re-checks session revocation every 30 s and sweeps its own sockets. **Not verified here:** there is no Redis on the development machine, so load-test this path on a staging server before relying on it.

### 9.7 Linux alternative: gunicorn

Not run for this guide (no Linux host was available); the commands follow Flask-SocketIO's documented deployment.

```bash
python3.11 -m venv venv && venv/bin/pip install -r Requirements.txt gunicorn
SOCKETIO_ASYNC_MODE=gevent venv/bin/gunicorn \
    -k geventwebsocket.gunicorn.workers.GeventWebSocketWorker -w 1 \
    --bind 127.0.0.1:5001 --worker-connections 2000 app:app
```

- **Always `-w 1`.** gunicorn hands each request to whichever worker is free, but Socket.IO long-polling needs every request of a session to reach the process that holds it. With `-w 2` or more, sessions break at random ("Invalid session", endless reconnects). For more capacity run more *instances*, one `-w 1` gunicorn per port, with the message queue and a sticky proxy, exactly as in 9.6.
- gunicorn's gevent worker patches the standard library before importing `app.py`; `app.py` detects that and does not patch twice. Do not add `--preload`: the app would then be imported, unpatched, in the master process.
- `--worker-connections` (default 1,000) caps simultaneous connections per worker, sockets included.
- `python app.py` with `SOCKETIO_ASYNC_MODE=gevent` also works on Linux. gunicorn adds graceful restarts (`kill -HUP`) and a supervising master process.

A systemd template, one unit per port (`systemctl enable --now itrack@5001`):

```ini
# /etc/systemd/system/itrack@.service
[Unit]
Description=ITrack instance on port %i
After=network-online.target mongod.service

[Service]
User=itrack
WorkingDirectory=/srv/itrack
Environment=SOCKETIO_ASYNC_MODE=gevent
ExecStart=/srv/itrack/venv/bin/gunicorn -k geventwebsocket.gunicorn.workers.GeventWebSocketWorker -w 1 --bind 127.0.0.1:%i app:app
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

The app reads the rest of its settings from `/srv/itrack/.env`. Put the same Nginx server block in front that the ops console generates (`New-NginxConfig` in [exec_prod/ServerAdminPankaj_V3.ps1](exec_prod/ServerAdminPankaj_V3.ps1)). On Linux also set `worker_processes auto;` and `worker_connections 4096;`, which Windows nginx cannot use.

### 9.8 Operations

- **Logs:** the service writes `LogDir\itracker.out.log` and `itracker.err.log`, rotated at 10 MB. Lines are prefixed `[startup]`, `[warning]`, `[info]`, `[socket]`, `[audit]` or `[Socket.IO]`. Request logs belong to the proxy (the Caddy `log` directive, nginx `access_log`).
- **Monitoring:** poll `GET /healthz` ([app.py:780](app.py#L780)). It returns `200 {"status":"ok"}`, or `503 {"status":"degraded"}` when MongoDB does not answer. It needs no sign-in and reveals nothing else.
- **Backups:** a nightly `mongodump` through Task Scheduler; see [§16.4](#164-scheduled-maintenance--use-the-os-scheduler). GridFS media is in the same database, so one dump covers data and photos. Test a restore into a scratch database at least once.
- **Rollback:** every change is its own commit on `main` (table below). Revert one with `git revert <sha>`, or deploy an older checkout, and restart the service. The series adds the `login_attempts` collection, writes `audit_logs` entries and a `session_epoch` field on users, but migrates no stored data, so reverting code needs no data step.
- **Settings:** security in [§8.2](#82-go-live-checklist-production-env); every environment variable in [§13](#13-dev-commands--environment-variables).

**The 2026-09 hardening series, one concern per commit** (oldest first):

| Commit | What it changes |
|---|---|
| `91683c8` | Authorization: tracker reads, chat writes and media follow the dashboard scope |
| `3aba43d` | Sign-in throttling, session expiry and revocation, no query operators |
| `1d5eaed` | Versioned static URLs, so a year-long cache never serves stale CSS/JS |
| `69c61eb` | CSRF protection on every state-changing request |
| `045fd35` | Strong `SECRET_KEY` required; cookie flags; security headers |
| `107ccac` | Admin panel: strong password, lockout, audit log, escaping |
| `3127b5e` | Socket authentication and room authorization; photos after live updates |
| `01e268d` | Reconnect forever, catch up after outages, recover on wake |
| `e8f19cc` | gevent production mode; CPU work off the event loop; `/healthz` |
| `57182cc` | gevent pinned; serving guidance; clear error when threading has no console |
| `7d81f31` | Ops console: gevent Windows service, WebSocket-ready Nginx |
| `3b6c843` | Ops console: option U rewrites an existing `nginx.conf` |

---

## 10. Mobile-first & responsive

**Principle: the app must be usable on phone, tablet, and desktop.** FE surfaces (`fe_dashboard`, `fe_new_installation`, `fe_tracker_detail`) are mobile-first; NOC and analytics are desktop-optimized but must still degrade gracefully on small screens.

- **Accessibility flag to fix:** the viewport sets `maximum-scale=1.0, user-scalable=no` ([base.html:5](templates/base.html#L5)), which disables pinch-zoom (WCAG 1.4.4 violation). Recommend removing the zoom lock. The shared image viewer implements its own pinch/wheel zoom to work around this for photos (see [§7](#7-conventions--code-map)).
- **Scroll locking is automatic - do not hand-roll it.** A watcher in [base.html](templates/base.html) observes the DOM for any `.fixed.inset-0` overlay becoming visible and pins the body (`position: fixed` at the saved offset, restored on close - `overflow: hidden` alone does not stop iOS rubber-banding). Every modal in the app is such an element toggled with the `hidden` class, so new ones are covered for free. Opt out with `data-no-scroll-lock="1"`; force a re-check after an unusual visibility change with `window.syncPageScrollLock()`.
- **Full-screen camera/media modals need `min-height: 0` on the video row.** A flex child defaults to `min-height: auto`, so a `<video>`'s intrinsic height (1080px) becomes a floor the `flex-1` row cannot shrink below - it grows past the viewport and pushes the Capture button off-screen, which is only reachable by zooming the browser out. Give the media row `style="min-height:0"` + `overflow-hidden`, and the header/button bars `flex-shrink-0`.
- **Percentage widths collapse inside chat bubbles.** `.chat-message` is shrink-to-fit, so a child with `width: 100%` has no definite parent width to resolve against and falls back to min-content - this is what rendered voice notes as a tiny blob. Give media a definite width (`width: 15rem`) plus `max-width: 100%`, never the reverse.
- **Full-screen overlays must lock the page behind them.** The image viewer sets `body { position: fixed; top: -<scrollY>px }` while open and restores the offset on close (a plain `overflow: hidden` does not stop iOS rubber-banding). It also sets `window.appImageViewerOpen`, which the global pull-to-refresh touch handlers check so panning inside the viewer never triggers a page refresh. Any new full-screen modal should do the same.
- **Media inside chat bubbles must be fluid.** `.chat-audio` and `.chat-image` size to the bubble (`width: 100%` with a max), bubbles widen to 85% below 640px, and `#chat-messages` clips horizontally. A fixed-width player overflowed the chat card on phones.
- **Chat never yanks the user's scroll position.** `displayMessages()` in [chat_component.html](templates/chat_component.html) skips the re-render entirely when the message signature (count + last id + timestamp) is unchanged, and only pins to the bottom when the user is already within 60px of it. The 60 s safety-net poll therefore leaves someone reading history alone. Sending a message scrolls back to the bottom explicitly.
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
- Live updates that heal themselves: authenticated rooms, reconnect forever, REST catch-up after any gap ([§5](#5-real-time-socketio--architecture--robustness)).
- Retry history preserved for SIM/ZTP/HSO.
- Hardened: scoped authorization, CSRF, throttled sign-in, revocable sessions, security headers ([§8](#8-security--controls-production-settings--residual-risks)). One gevent process serves the whole organisation with headroom ([§9.5](#95-capacity--sizing--how-many-workers)).
- Media in GridFS behind per-tracker authorization; lists paged and projected ([§15](#15-performance-scale--the-media-pipeline)).
- Idempotent index script; a Windows ops console that installs the app as a service.

**Cons**
- Monolithic ~4,850-line `app.py`, hard to test in isolation; no automated test suite in the repo.
- Analytics compute in Python over the matching trackers (no aggregation pipelines), so they slow down as data grows ([§15.8](#158-what-is-deliberately-still-open)).
- `print()`-based logging (prefixed, and captured to rotating files by the service).
- Scaling past one process needs Redis and a sticky proxy ([§9.6](#96-scaling-out--more-than-one-process)).

**Loopholes:** none known to be open. Accepted residual risks are listed in [§8.3](#83-residual-risks-accepted-or-tracked).

---

## 12. One-time scripts

All live in the tracked **`scripts/`** folder (moved out of the web-served `static/` path so they and the user data are no longer downloadable via URL). The `.py` files are version-controlled; **the user-data `.xlsx` is gitignored** (`scripts/*.xlsx`) because it holds real accounts.

| Script | What it does | When to run | When NOT to run |
|---|---|---|---|
| `scripts/create_indexes.py` | **Canonical** MongoDB index setup for all collections; idempotent (skips existing). | Once on any fresh/prod DB, and after adding new query patterns. Safe to re-run. | Never harmful. |
| `scripts/seed_users.py` | Makes `users` match the workbook. Reads the **per-role sheets**. Upserts every row **by username**, so existing accounts keep their `_id`, then removes accounts absent from the sheet. `--passwords-only` re-hashes passwords onto existing users and touches nothing else; `--dry-run` reports. *Until 2026-09-26 the full mode deleted every user and re-inserted them, giving everyone a new `_id` and orphaning every tracker - see [section 15.9](#159-incident-reseed-orphaned-every-tracker).* | Initial setup; syncing the user list with the sheet; password recovery with `--passwords-only`. | Against production without a `--dry-run` first. |
| `scripts/relink_orphans.py` | Re-attaches trackers whose `fe.id` / `noc_assignee` point at user ids that no longer exist. FE by the username stored on the tracker; NOC by the name the tracker itself recorded (`noc_name`, `noc_history`, chat sender). Ambiguous ids are reported, never guessed. `--apply` writes a backup to `backups/` first; `--restore <file>` undoes it. | Once, after a reseed made with the old `seed_users.py`. Safe to re-run: reports "nothing to do". | - |
| `scripts/migrate_media.py` | Moves inline base64 media out of tracker and chat documents into GridFS. `--gc` lists GridFS files no document references (e.g. after deleting trackers); `--gc --apply` deletes them, never touching files younger than an hour. | Once per database for the migration; `--gc` whenever trackers or messages are deleted, or weekly on a schedule ([§16.4](#164-scheduled-maintenance--use-the-os-scheduler)). | - |
| `scripts/seed_trackers.py` | Generates sample tracker data for demo/testing. | Local demos / load testing. | Never in production. |
| `init_db.py` (root) | **Legacy.** Creates the wrong `noc_users` collection and seeds `predefined_reasons`; does not set up `users`. | Only for the `predefined_reasons` seed, if you extract that. | Don't rely on it for indexes/users — use the scripts above. |
| `exec_prod/ServerAdminPankaj_V3.ps1` (same console: `exec_prod/deployed/ManageServer.ps1`) | Windows ops console: installs the app as a gevent Windows service (NSSM) and starts/stops it; MongoDB; Caddy or Nginx with WebSocket-ready configs (U rewrites an old `nginx.conf`). `exec_prod/deployed/Install-ServerStack.ps1` lays out Caddy, nginx and NSSM and installs the requirements. | On the server, as Administrator. See [§9.3](#93-install-or-upgrade-on-the-windows-server). | Not for dev machines. |

Run scripts from the project root, e.g. `python scripts/create_indexes.py`.

**Workbook gotchas (both bit us on 2026-09-26):**

1. **Read the per-role sheets, never `All(270)`.** The consolidated `All(270)` sheet's `Password` column is a *placeholder* - the literal value `test123` repeated for all 270 users. The real per-user passwords live in `FE(235)`, `FEG(23)`, `FS(5)`, `FSG(1)`, `NS(5)`, `NSG(1)` (235+23+5+1+5+1 = 270), which agree with `All(270)` on every other column. Seeding from `All(270)` set every account's password to `test123`, so no real credential worked. `seed_users.py` now reads the role sheets (matched by the pattern `ROLE(n)`) and falls back to the consolidated sheet only if they are absent. It also prints its source sheets and **warns loudly** when every row shares one password.
2. **The autofilter breaks openpyxl.** The workbook carries `<customFilter val=" ">`, which openpyxl's validator rejects, so `load_workbook()` raised before reading a single row. `seed_users.py` now strips `<autoFilter>` from a temp copy before loading, leaving the original file untouched.

---

## 13. Dev commands & environment variables

```bash
# Run the app (default http://localhost:5001) - threading development server
python app.py
run.bat        # Windows shortcut
./run.sh       # Linux/Mac shortcut

# The production server, locally (see section 9)
SOCKETIO_ASYNC_MODE=gevent python app.py

# MongoDB setup on a fresh DB
python scripts/create_indexes.py      # indexes (canonical)
python scripts/seed_users.py          # users from the master workbook (removes accounts not in it - --dry-run first)

# Tailwind (only if templates changed)
npm install
npm run build:css       # production build
npm run watch:css       # dev watch
```

### Environment variables

Read from `.env` in the project root (`.env.example` is the template). A variable already set in the process environment wins over `.env`.

**Core**

| Var | Default | Purpose |
|---|---|---|
| `MONGO_URI` | `mongodb://localhost:27017/sdwan_tracker` | Database; use an authenticated URI in production |
| `MONGO_MAX_POOL_SIZE` | `100` | Connections per process (ignored when `MONGO_URI` sets `maxPoolSize`) |
| `SECRET_KEY` | *(none usable)* | Session signing; ≥ 32 characters or the app refuses to start (unless `FLASK_DEBUG=true`) |
| `FLASK_DEBUG` | `false` | Werkzeug debugger, template reload, no static caching |
| `PORT` | `5001` | Listen port |
| `HOST` | `127.0.0.1` when `TRUST_PROXY_HOPS` > 0, else `0.0.0.0` | Listen address |
| `STATIC_VERSION` | fingerprint of `static/` | Cache-busting suffix on CSS/JS URLs |

**Serving and real-time** ([§5](#5-real-time-socketio--architecture--robustness), [§9](#9-production-deployment--windows-primary--linux))

| Var | Default | Purpose |
|---|---|---|
| `SOCKETIO_ASYNC_MODE` | `threading` | `gevent` in production; `eventlet` is refused |
| `SOCKETIO_MESSAGE_QUEUE` | *(none)* | `redis://…`; required for more than one process |
| `SOCKETIO_PING_INTERVAL` / `SOCKETIO_PING_TIMEOUT` | `25` / `20` | Socket heartbeat, seconds |
| `SOCKET_SESSION_SWEEP_SECONDS` | `60` | How often sockets of revoked sessions are disconnected |
| `CORS_ORIGINS` | *(same origin)* | Origins allowed to open sockets (comma-separated); a list replaces the same-origin default |
| `REALTIME_MODE` | `hybrid` | `socket` \| `api` \| `hybrid` |
| `SOCKET_TIMEOUT` | `2000` | ms before REST fallback |
| `SOCKET_INCLUDE_FULL_DATA` | `true` | Full tracker in `tracker_update` broadcasts |

**Security** ([§8](#8-security--controls-production-settings--residual-risks))

| Var | Default | Purpose |
|---|---|---|
| `ADMIN_PASSWORD` | *(none)* | `/admin` password; shorter than 12 characters or common → panel disabled |
| `ADMIN_SESSION_MINUTES` | `30` | Admin idle timeout |
| `TRUST_PROXY_HOPS` | `0` | Number of proxies in front (1 behind Caddy/Nginx) |
| `SESSION_COOKIE_SECURE` | `auto` | `auto` (Secure over HTTPS) \| `true` \| `false` |
| `SESSION_LIFETIME_HOURS` | `12` | Sliding session lifetime |
| `USER_CHECK_TTL_SECONDS` | `30` | How often a process re-checks that a session is still valid |
| `HSTS_MAX_AGE` | `0` (off) | HSTS max-age in seconds; only with a trusted certificate |
| `PUBLIC_ORIGINS` | *(none)* | Extra origins allowed for state-changing requests (comma-separated) |
| `CSP_CONNECT_EXTRA` | `https://nominatim.openstreetmap.org` | Extra `connect-src` origins (space-separated) |
| `LOGIN_MAX_FAILURES` / `LOGIN_ACCOUNT_MAX_FAILURES` / `LOGIN_IP_MAX_FAILURES` | `5` / `20` / `30` | Failed sign-ins allowed per account+IP / account / IP… |
| `LOGIN_WINDOW_MINUTES` | `15` | …within this window |
| `AUDIT_RETENTION_DAYS` | `365` | `audit_logs` expiry |

**Media** ([§15.4](#154-the-media-pipeline--why-the-same-photo-has-three-different-sizes))

| Var | Default | Purpose |
|---|---|---|
| `MEDIA_PROFILE` | `balanced` | `compact` \| `balanced` \| `original`: presets for the four below |
| `IMAGE_MAX_DIM` / `IMAGE_QUALITY` | `1920` / `95` | Chat photo re-encode: longest side in px (0 = keep) / JPEG quality |
| `CAPTURE_MAX_DIM` / `CAPTURE_QUALITY` | `1920` / `0.95` | In-app camera captures |

---

## 14. Known issues & improvement roadmap

Still-valid items (the resolved real-time bugs from the old ANALYSIS.md have been dropped):

**Real-time / performance**
- Dashboard `dashboard_update` triggers a **reload of the current page and badge counts** (`debouncedReload`, 500 ms debounce). Cheap since lists are paged; a targeted card insert/update/remove using the payload's `tracker_id` would remove even that.
- A **"Reconnecting…" pill** already appears while the socket is down ([base.html:400](templates/base.html#L400)); a persistent indicator in the header would help on unreliable field networks.
- Connect the **analytics dashboard** to Socket.IO for live KPI refresh.

**Analytics / KPIs**
- Replace Python-side iteration with **MongoDB aggregation pipelines** (`$group`/`$avg`/`$sum`).
- Add accountability KPIs: NS idle time (`assigned → sim1 start`), FE coordination response (`ready → hso submitted`), HSO reject→resubmit time (from `hso.attempts[]`).
- Add **failure-reason aggregation** endpoints (SIM/ZTP/HSO) and a **per-operator KPI table**.
- Add **SLA thresholds** + breach flags and a live status-funnel card.

**Code quality / storage**
- Store **`actor_name`** in `make_event()` to avoid user lookups in timelines/analytics.
- Consider splitting `app.py` into blueprints as it grows.

**Security** — the audit findings are fixed ([§8](#8-security--controls-production-settings--residual-risks)). Next: drop `'unsafe-inline'` from the CSP by moving inline `<script>` blocks and `onclick=` handlers into static JS ([§8.3](#83-residual-risks-accepted-or-tracked)); bring the verification probes into the repo as an automated test suite.

**Operations** — schedule backups and media cleanup ([§16.4](#164-scheduled-maintenance--use-the-os-scheduler)); load-test the multi-process path on staging before it is needed ([§9.6](#96-scaling-out--more-than-one-process)).

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

Ordered by payoff per unit of risk. The status of every item is in [15.7](#157-current-status).

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

**9. Run a real server. — DONE 2026-09-28.** gevent is the production server, measured in [§9.5](#95-capacity--sizing--how-many-workers): one process holds 300 sockets on 12 OS threads, and CPU-heavy work runs off the event loop. The command originally proposed here, `gunicorn ... -w 4`, would have broken Socket.IO: gunicorn is not sticky, so a session's requests land on different workers. The scale-out path (one worker per instance, a message queue, a sticky proxy) is [§9.6](#96-scaling-out--more-than-one-process); gunicorn itself is Linux-only ([§9.7](#97-linux-alternative-gunicorn)).

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

Re-measured 2026-09-26 after the work below, same dataset (207 trackers, 526 chat messages).

| Endpoint | Before | After | Change |
|---|---|---|---|
| `GET /api/trackers/all-noc` (everything) | 4,205,999 B | 632,113 B | **-85%** |
| `GET /api/trackers/all-noc` (default page) | - | 139,739 B | new |
| `GET /api/trackers/counts` | (client-side, after full download) | 304 B / 7 ms | new |
| `GET /api/trackers/<id>` (image-heavy) | ~1.2 MB | 9,635 B | **-99%** |
| `GET .../chat/messages` (heaviest thread) | 2,237,521 B | 3,656 B | **-99.8%** |
| `GET .../chat/messages?since=` | - | 87 B | new |
| `trackers` collection on disk | 3.9 MB | 1.0 MB | **-74%** |
| NSG dashboard load (data requests) | 4,205,999 B | 51,544 B | **-99%**, and constant as trackers grow |
| FSG dashboard load (data requests) | 4,205,999 B | 10,479 B | **-99.8%** |

| Item | State |
|---|---|
| Indexes applied and verified | Done |
| `create_indexes.py` console crash | Fixed |
| `seed_users.py` index-name collision | Fixed |
| Configurable media policy (`MEDIA_PROFILE`) | Done |
| Downloads preserve stored bytes exactly | Done |
| List-endpoint projections (`TRACKER_LIST_PROJECTION`) | Done |
| Server-side counts (`/api/trackers/counts`, one `$facet`) | Done |
| Pagination in the API (`?page=`/`?limit=`) | Done |
| Media in GridFS + `/api/media/<id>`, cached immutable | Done |
| Media migration (`scripts/migrate_media.py`) | Done - 34 files / 3.8 MB, byte-verified |
| Incremental chat fetch (`?since=`), media never inlined | Done |
| Socket.IO chat broadcasts carry URLs, not bytes | Done |
| Polling reduced to a reconcile safety net (5s/30s -> 60s/120s) | Done |
| Static asset caching follows `FLASK_DEBUG` | Done |
| `api_noc_users_stats` N+1 -> one aggregation | Done |
| Analytics projection (drops `events[]` where unused) | Done - output verified identical on 8 endpoints |
| `tracker_id` atomic counter + seeding | Done - 8 parallel creates gave 8 distinct ids |
| `sdwan_id` `DuplicateKeyError` -> 409 | Done |
| Configurable async mode + `message_queue` + Mongo pool | Done - gevent measured ([§9.5](#95-capacity--sizing--how-many-workers)); the Redis path is configured, not load-tested |
| Dashboards fetch one page per tab (`?filter=`) + counts | Done - 1,374-check equivalence harness, 0 mismatches; real-browser regression, 0 failures |
| Dashboard search on the server (`/api/trackers/search`) | Done - literal substring, never a regex |
| Stored XSS on dashboards | Fixed - see section 8 |
| Script-capable media served inline | Fixed - see section 8 |
| Orphaned tracker ownership | Repaired - see 15.9 |
| **Analytics as aggregation pipelines** | **Pending - see below** |
| Production server: gevent as a Windows service | Done - [§9](#9-production-deployment--windows-primary--linux) |
| Security hardening | Done - [§8](#8-security--controls-production-settings--residual-risks) |
| Real-time resilience (reconnect, catch-up) | Done - [§5](#5-real-time-socketio--architecture--robustness) |
| **More than one process (Redis + sticky proxy)** | **Documented ([§9.6](#96-scaling-out--more-than-one-process)); not needed at current scale; not load-tested** |

### 15.8 What is deliberately still open

**Analytics still iterate in Python.** Measured 7-80 ms at 207 trackers, so this is not urgent, but
`list(find(...))` scales linearly with tracker count. The `events[]` projection removes the worst of it.
Converting the KPI maths to `$group`/`$avg` pipelines changes numbers the business reads, so it wants a
before/after comparison per endpoint - the harness used here (capture every analytics response, diff after
the change) is the right way to do it safely.

**The multi-process path is unproven.** gevent itself is measured ([§9.5](#95-capacity--sizing--how-many-workers))
and is the production server. Running more than one process, with a Redis message queue and a sticky proxy
([§9.6](#96-scaling-out--more-than-one-process)), has not been exercised here: there was no Redis or Linux
host. Load-test it on staging before relying on it. At the current ~270 accounts one process has about ten
times the headroom needed.

### 15.9 Incident: reseed orphaned every tracker

Found 2026-09-26 while testing the dashboards. **205 of 207 trackers referenced FE user ids, and 200
referenced NOC user ids, that no longer existed.** `seed_users.py` full mode used to `delete_many({})`
and re-insert every user, which gives every account a fresh `_id`; trackers store owners by id
(`fe.id`, `noc_assignee`), so one reseed detached all of them. Observed effects, verified through the
real API before the repair:

- An FE opening their own tracker got `can_interact: false` - every action button disabled.
- "My" dashboard tabs were empty for everyone.
- NOC operators were refused chat (`403 Not assigned to you`) on trackers assigned to them.

**Root cause fixed:** full mode now upserts by username. Proven on a copy: a reseed now leaves all 270
user ids byte-identical, while the old delete-and-insert re-orphaned all 207 trackers.

**Data repaired** with `scripts/relink_orphans.py --apply`: 205 trackers re-linked to their FE, 163 to
their NOC operator. Afterwards the same FE got `can_interact: true` and every NOC operator got their
queue back with chat returning 200. Backup: `backups/relink_20260926_221404.json` (undo with
`--restore`).

**Needs a decision:** 37 trackers were assigned to **Yogesh**, who is in neither the workbook nor
`users`. **13 are still open.** They were left untouched on purpose - reassign the open ones from the
NOC Support Group dashboard; the completed ones can stay as history.

### 15.10 How the dashboard change was verified

Moving tab membership from the browser to Mongo changes *where* the rules run, so it was proven
equivalent rather than eyeballed:

- **Equivalence harness.** The original client predicates - checked verbatim against commit `71ef2e3` -
  run in Node over the full visible list, compared with the server's `?filter=` results for 6 roles x
  12 date ranges (the dashboards' own `getDateRange()` in `Asia/Kolkata`, plus boundary-second edges
  pinned to real timestamps) x every tab: ids and order, badge counts, list totals, average completion
  time, and page-by-page reassembly. **1,374 checks, 0 mismatches.** A planted one-word bug produced 52
  mismatches isolated to the NOC roles, so the harness does catch regressions.
- **Real browser.** Headless Chrome per role: badges on load, every tab's title/count/rows, page 2 through
  the pager, a range change, rapid tab switching (responses can arrive out of order; a sequence guard
  keeps the last click), search, zero console errors, desktop and phone screenshots.
- Both ran against a throwaway copy of the database with ownership re-linked, so the "My" tabs had real
  data to compare.

If a tab rule changes, change it in `bucket_query()` only - the list, counts and search all read it.

---

## 16. Background jobs — Celery, APScheduler & scheduled maintenance

**Verdict:** the app needs no job queue today. Periodic maintenance belongs in the OS scheduler (Windows Task Scheduler; cron or systemd timers on Linux) running the existing scripts. Celery is not worth running on this Windows server, and APScheduler is usable only with care.

### 16.1 What already runs in the background

| Work | How it runs | Notes |
|---|---|---|
| Disconnect sockets of revoked sessions | In-process task every `SOCKET_SESSION_SWEEP_SECONDS` (60) | One per process, each sweeping its own sockets: correct with any number of processes |
| Expire old sign-in failures and audit entries | MongoDB TTL indexes on `login_attempts` and `audit_logs` | No application job needed |
| Password hashing, photo re-encoding | `run_blocking()` → gevent's thread pool, inside the request | 0.1–0.7 s; the user is waiting for the result anyway |
| Orphaned-media cleanup, backups | By hand today | Schedule them: 16.4 |

### 16.2 Celery — not recommended here

- Celery has not supported Windows since version 4: its default worker pool relies on `fork`. It can be forced to run (`-P solo` or `-P threads`), but that is unsupported for production.
- It adds a broker (Redis or RabbitMQ), a worker service and a result backend: three more things to run, secure, back up and monitor on the server.
- Nothing in the app needs it. No request does more than about a second of work, nothing needs retries or distribution across machines, and the CPU-heavy parts already run off the event loop.

**Revisit when** a user-triggered task takes longer than ~10 s (very large analytics exports, generated PDF reports), or outbound work needs retries (email, SMS, push notifications). Then run the workers on Linux next to the Redis that the scale-out path ([§9.6](#96-scaling-out--more-than-one-process)) brings anyway, with Celery or the simpler RQ.

### 16.3 APScheduler — feasible for small periodic jobs, with two caveats

APScheduler runs jobs inside the web process (`GeventScheduler` under gevent, `BackgroundScheduler` under threading):

- **Every process runs every job.** With one process that is fine. With more (9.6, or gunicorn workers) each job runs *N* times unless it takes a lock first, for example a lease document in MongoDB claimed with `find_one_and_update` and an expiry time.
- **Jobs share the web process.** A heavy job slows requests; send CPU work through `run_blocking()`.

Use it only for a job that must run *inside* the app, such as one that emits Socket.IO events every few minutes (an SLA-breach alert). Even that can stay outside the web process once the message queue from 9.6 exists: a scheduled script can emit to connected clients with `SocketIO(message_queue='redis://...').emit(...)`.

### 16.4 Scheduled maintenance — use the OS scheduler

Task Scheduler runs each job in its own process: isolated from the app, unaffected by app restarts, with its own log, and without code changes. The scripts load `.env` from the project root themselves, so the working directory does not matter.

**Nightly backup.** Save as `D:\backups\itrack_backup.ps1` (adjust the paths; keep the backup user's URI in a file only Administrators can read):

```powershell
$stamp = Get-Date -Format 'yyyyMMdd_HHmm'
$uri = (Get-Content 'D:\backups\mongo_uri.txt' -Raw).Trim()
& 'C:\Program Files\MongoDB\Tools\100\bin\mongodump.exe' --uri $uri --gzip --archive="D:\backups\itrack_$stamp.gz"
Get-ChildItem 'D:\backups\itrack_*.gz' | Where-Object LastWriteTime -lt (Get-Date).AddDays(-14) | Remove-Item
```

```powershell
schtasks /Create /TN "ITrack backup" /SC DAILY /ST 02:00 /RU SYSTEM /TR "powershell -NoProfile -ExecutionPolicy Bypass -File D:\backups\itrack_backup.ps1"
```

Restore into a scratch database to test: `mongorestore --gzip --archive=D:\backups\itrack_<stamp>.gz --nsFrom "sdwan_tracker.*" --nsTo "restore_test.*"`.

**Weekly media cleanup.** Deletes GridFS files that no tracker or message references. Run it once by hand with `--gc` alone to see what it would delete. The scheduled run keeps anything younger than a day, so a tracker form left open for hours never loses its photos:

```powershell
schtasks /Create /TN "ITrack media GC" /SC WEEKLY /D SUN /ST 03:00 /RU SYSTEM /TR "cmd /c G:\srv\app\itracker\venv\Scripts\python.exe G:\srv\app\itracker\scripts\migrate_media.py --gc --apply --gc-min-age-minutes 1440 >> G:\srv\app\itracker\logs\media_gc.log 2>&1"
```

On Linux the same commands go in cron or a systemd timer.

### 16.5 Which tool for which job

| Need | Use |
|---|---|
| Periodic maintenance: backups, media cleanup, report files | OS scheduler running a script (16.4) |
| A periodic job that must push live updates | One process: APScheduler inside the app. Several: a scheduled script emitting through the message queue |
| A user-triggered job longer than ~10 s, or anything that needs retries | A real queue (Celery or RQ with Redis), on Linux |
| CPU-heavy work inside a request | `run_blocking()`, already in place |
