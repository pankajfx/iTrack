# iTrack FE App — Complete Overview & Reference

A single detailed reference for the Flutter FE Android app and its `android_backend` API layer. If you're picking this up fresh, read this once end-to-end, then use the other docs as needed:

- **[README](../README.md)** — quick start + doc index
- **[SETUP.md](SETUP.md)** — install the toolchain from zero
- **[TESTING.md](TESTING.md)** — run in Chrome / on a phone / via APK
- **[ARCHITECTURE.md](ARCHITECTURE.md)** — how the layers work, with diagrams
- **[BUILD_RELEASE.md](BUILD_RELEASE.md)** — keystore + building the APK
- **This file** — everything in detail: file map, API contract, parity map, decisions, fixes

---

## 1. What this is and why it exists

**Goal:** field engineers install a native Android app (a shareable APK, no Play Store) that behaves exactly like the **FIELD_ENGINEER** view of the iTrack website — create trackers with GPS-stamped photos, track their progress through the workflow buckets, run the FE actions (ZTP, HSO), and chat with NOC.

**Chosen design:** the app is a thin **client of the existing Flask server**. It calls the same `/api/*` endpoints the website calls and authenticates with the same **session cookie**. There is no second backend and no duplicated business logic — anything the server enforces (permissions, workflow gates) is enforced once, on the server. A tiny read-only Flask blueprint (`android_backend/`) adds the three mobile-specific endpoints the website never needed.

**v1 scope:** FE role only; chat is text + images (voice notes deferred). FEG/FS/FSG can be added later as read-only logins — the app already respects the server's `can_interact` flag.

---

## 2. The two new project folders

```
iTrack/
├── android_backend/            # NEW — Flask blueprint for the app (server side)
│   ├── __init__.py             #   exports register_android_api
│   ├── routes.py               #   /api/android/ping, /me, /form-options
│   └── form_defaults.py        #   canonical dropdown values (seed source)
├── scripts/
│   └── seed_form_options.py    # NEW — seeds the form_options collection (idempotent)
├── app.py                      # +2 lines: register_android_api(app, mongo)
└── android/                    # NEW — the Flutter app (see §4 for the full lib/ map)
    ├── lib/ …                  #   Dart source
    ├── android/ …              #   Gradle, manifest, signing (note: nested android/android/)
    ├── docs/ …                 #   these documents
    ├── assets/fonts/           #   FjallaOne-Regular.ttf (copied from web static/)
    └── pubspec.yaml            #   dependencies + app version
```

> The Flutter project literally contains its own `android/` platform subfolder, so paths like `android/android/app/build.gradle` are normal, not a typo.

---

## 3. `android_backend` — the server-side API layer

Mounted at `/api/android/*`, registered from `app.py` just before `if __name__ == '__main__':`:
```python
from android_backend import register_android_api
register_android_api(app, mongo)
```

**Design rules (deliberate):**
- **Read-only.** It never writes to `trackers`/`users`/`chat_messages`. Every mutating action still goes through the existing web API, so this blueprint cannot break the website.
- **Zero imports from `app.py`** (avoids circular imports). It re-declares the FE role set and a minimal serializer locally — keep these in sync with `app.py`'s canonical constants if they ever change.
- **JSON 401 on auth failure**, unlike the web app's `login_required` which returns a 302 redirect to `/login`. The app can act on a clean 401; it would choke on an HTML redirect.

| Endpoint | Auth | Response | Why it exists |
|---|---|---|---|
| `GET /api/android/ping` | none | `{success, app:"iTrack", server_time, min_app_version}` | "Test Connection" on the Server Setup screen; future forced-upgrade hook via `min_app_version` |
| `GET /api/android/me` | session | `{authenticated:true, user:{user_id,username,name,role,region,fe_group,…}}` or **401** | Startup session check; supplies `user_id` (needed for Socket.IO `join_dashboard`) which the web login response doesn't return |
| `GET /api/android/form-options` | session | `{customers:[{value,label}], sim_providers:[…], router_types:[…], router_makes:[…]}` | New-installation dropdowns, from the `form_options` collection (falls back to `form_defaults.py` if unseeded) |

**`form_options` collection:** one doc per category `{category, values:[{value,label}], updated_at}`, unique index on `category`. Seeded by `scripts/seed_form_options.py` from `android_backend/form_defaults.py` (which mirrors the lists hardcoded in `templates/fe_new_installation.html`). Idempotent; `--force` resets to defaults. **Editing the collection changes the app's dropdowns with no APK rebuild.**

Seed contents: 25 customers (AGS-AXIS … nelco), SIM providers Airtel/Jio/**VI (value `VI`, label "VI (Vodafone Idea)")**/BSNL, router types PI-15/PI-11/PI-24, makes Made in India/China/Taiwan.

---

## 4. The Flutter app — file-by-file

Layered so a tap flows **UI → state → api/services → server**, and data flows back. State management is **Provider** (`ChangeNotifier`), the simplest officially-recommended option.

### Entry & shell
| File | Purpose |
|---|---|
| `lib/main.dart` | Loads saved server URL + restores session, installs self-signed cert trust (native only), runs the app inside `MultiProvider`. |
| `lib/app.dart` | Root router: no server URL → Server Setup; not logged in → Login; else → Dashboard. Keeps the socket connected to the configured server. |
| `lib/theme/app_theme.dart` | FE "ocean_depths" palette (`#006D6F`→`#004953`), Material 3, Fjalla One headings, rounded cards. |

### API layer (`lib/api/`)
| File | Purpose |
|---|---|
| `api_client.dart` | The single Dio instance. Base URL, **session-expiry detection** (302→/login and HTML-where-JSON), error mapping (409 duplicate, timeouts), delegates platform HTTP to the adapter. |
| `api_exception.dart` | `ApiException`, `SessionExpiredException`, `DuplicateSdwanIdException`. |
| `http_adapter.dart` | Conditional export → picks io or web at compile time. |
| `http_adapter_io.dart` | **Native:** persistent cookie jar (session survives restarts) + self-signed cert trust scoped to the configured host + `HttpOverrides` for Socket.IO. |
| `http_adapter_web.dart` | **Web:** credentialed browser requests, no cookie jar, no cert override (keeps `dart:io` out of the web build). |
| `auth_api.dart` | Login, logout, the two login dropdowns, `/me`, `/ping`. |
| `trackers_api.dart` | `all-fe`, detail, duplicate check, create, site-verify resubmit, ZTP (fe-start/complete/request-noc), HSO submit. |
| `chat_api.dart` | Messages, send text, upload+send image (two-step), mark-read. |
| `options_api.dart` | `form-options`. |

### Models (`lib/models/`) — mirror the server JSON
`user.dart` (User + LoginOption), `tracker.dart` (Tracker + Sim/Router/Ztp/Hso/SiteVerification/TrackerEvent/NocHistory), `chat_message.dart`, `form_options.dart` (OptionItem + FormOptions), `gps_point.dart`.

### State (`lib/state/`) — one `ChangeNotifier` per concern
`server_config.dart`, `auth_state.dart` (login/session/expiry), `dashboard_state.dart` (list + 3 buckets + search + polling + socket), `tracker_detail_state.dart` (detail + **all the FE action gates**), `new_installation_state.dart` (wizard: photos + form + snaps + submit), `chat_state.dart`.

### Services (`lib/services/`) — device + realtime
`socket_service.dart` (one Socket.IO connection, room joins, event fan-out), `image_service.dart` (camera → compress to 1024px q85 → base64), `location_service.dart` (GPS fix + Nominatim reverse geocode, throttled, non-blocking).

### Screens (`lib/screens/`)
`server_setup_screen.dart`, `login_screen.dart`, `dashboard_screen.dart`, `new_installation_screen.dart`, `site_photo_capture_screen.dart` (reused for resubmit), `tracker_detail_screen.dart`, `chat_screen.dart`, `image_viewer_screen.dart`.

### Widgets (`lib/widgets/`)
`base64_image.dart` (decode+cache inline images), `status_badge.dart`, `tracker_card.dart`, `empty_state.dart`, `loading_overlay.dart`, `confirm_dialog.dart`, `photo_capture_tile.dart`, `field_snap_button.dart`, `timeline_list.dart`, `chat_bubble.dart`.

### Utils (`lib/utils/`) — rules copied verbatim from the website
`constants.dart` (statuses, the 3 bucket rules, snap field keys, image targets, poll interval, Nominatim config), `status_maps.dart` (the ~21-entry status→label/colour/icon maps + progress maps, ported from `fe_dashboard.html` and `fe_tracker_detail.html`), `time_utils.dart` (ISO-UTC → IST +5:30 formatting).

---

## 5. Full API contract (every call the app makes)

Session cookie is attached automatically on every call. JSON bodies are sent as `application/json`.

| # | Method · Path | Screen | Notes |
|---|---|---|---|
| 1 | `GET /api/android/ping` | Server Setup | Unauth connectivity check |
| 2 | `GET /api/login/field-engineer-groups` | Login | Dropdown 1 |
| 3 | `GET /api/login/field-engineers?field_engineer_group=X` | Login | Dropdown 2 |
| 4 | `POST /api/auth/login` `{role:"FIELD_ENGINEER", fe_name, fe_group, password}` | Login | 200 + Set-Cookie; 401 = bad credentials |
| 5 | `GET /api/android/me` | startup / login | Profile or JSON 401 |
| 6 | `POST /api/auth/logout` | menu | Clears cookie |
| 7 | `GET /api/trackers/all-fe` | Dashboard | `{trackers:[…]}`, scoped by role server-side |
| 8 | `GET /api/android/form-options` | Wizard | Dropdown lists |
| 9 | `GET /api/trackers/check/<sdwan_id>` | Wizard | Duplicate pre-check |
| 10 | `POST /api/trackers` `{sdwan_id, customer, fe_phone, sim…, router…, images{}, site_images[]}` | Wizard | 200 `{tracker}`; **409** = duplicate SDWAN ID |
| 11 | `GET /api/trackers/<id>` | Detail | `{tracker, can_interact}` |
| 12 | `POST /api/trackers/<id>/ztp/fe-start` | Detail | Gate: config verified + ≥1 SIM active |
| 13 | `POST /api/trackers/<id>/ztp/fe-complete` | Detail | |
| 14 | `POST /api/trackers/<id>/ztp/request-noc` | Detail | Unlocks chat |
| 15 | `POST /api/trackers/<id>/hso/submit` | Detail | Bodyless; gated by status |
| 16 | `POST /api/trackers/<id>/site-verify/resubmit` `{site_images:[≥3]}` | Detail | Only when rejected |
| 17 | `GET /api/trackers/<id>/chat/messages` | Chat | `{messages, chat_unlocked, can_interact}` |
| 18 | `POST /api/trackers/<id>/chat/upload` (multipart) | Chat | Returns base64 `file_url` |
| 19 | `POST /api/trackers/<id>/chat/send` `{message, type, file_url?}` | Chat | Text or image |
| 20 | `POST /api/trackers/<id>/chat/mark-read` | Chat | |

**Socket.IO:** connect to base URL; emit `join_dashboard {user_id, role}` (dashboard) and `join_tracker {tracker_id}` (detail/chat); listen for `tracker_update`, `new_chat_message`, `dashboard_update`, `user_notification`. Plus a 30 s polling refetch on every screen as a safety net (mirrors the web "hybrid" mode).

---

## 6. Web ↔ app feature parity

| Web feature (FE) | App location | Parity |
|---|---|---|
| Login role selector + group→engineer dropdowns | Login screen | ✅ (role fixed to FE) |
| Dashboard buckets: Unassigned / Ongoing / Completed | Dashboard tabs | ✅ same rules, ported verbatim |
| Bucket counts, status pills, progress % | Dashboard cards | ✅ same status→label/colour maps |
| Client-side search | Dashboard search | ✅ (SDWAN ID, customer, phone, SIM) |
| 30 s auto-refresh + live updates | Dashboard/detail/chat | ✅ Socket.IO + polling |
| New installation: 3 GPS site photos + form | Wizard | ✅ camera + Nominatim address |
| Customer/SIM/router dropdowns | Wizard | ✅ now **DB-driven** via `form-options` (web hardcodes them) |
| Per-field camera snaps | Wizard | ✅ |
| Duplicate SDWAN ID → open existing | Wizard 409 handler | ✅ |
| Tracker detail: status/progress/SIM/ZTP/HSO/timeline | Detail screen | ✅ |
| FE actions: ZTP start/complete/request-NOC, HSO submit | Detail buttons | ✅ same gates |
| Site-photo resubmit after rejection | Detail → capture screen | ✅ |
| SIM/router/firmware image viewing | Image viewer | ✅ pinch-zoom |
| Chat (unlock by status), text + images | Chat screen | ✅ |
| Chat voice notes | — | ⏸ deferred to v2 |
| Read-only FEG/FS/FSG view | — | ⏸ deferred (server `can_interact` already respected) |
| "Call NOC" | — | ➖ web only shows a message (doesn't dial); intentionally omitted |

---

## 7. Key mechanisms (quick recap; diagrams in ARCHITECTURE.md)

- **Auth = session cookie.** Login sets the cookie; a persistent cookie jar stores it on disk so you stay logged in across restarts. No tokens.
- **Session expiry** is detected two ways: the web API's 302→/login redirect (interceptor), and `android_backend` guards returning `error:"authentication_required"` (401). Both trigger a graceful logout + "session expired" note. A plain 401 without that marker (e.g. wrong password on login) shows the server's message instead.
- **Images** are base64 data-URLs inline in MongoDB (no file server). The app compresses camera shots to 1024px JPEG q85 before encoding, matching the server's Pillow behaviour.
- **Self-signed HTTPS** (prod Caddy/Nginx): trusted only for the configured host, for both Dio and Socket.IO. No blanket trust.
- **Timestamps** are naive UTC (`…Z`) from the server, displayed in IST (+5:30, no DST).

---

## 8. Decisions made (and why)

| Decision | Why |
|---|---|
| Direct-to-Flask + thin blueprint (not a new JWT API) | Zero logic duplication, one deploy, exact parity; the 3490-line `app.py` is risky to refactor now. `/api/android` leaves room to grow later. |
| DB-backed form options | So dropdowns update without shipping a new APK; the web form's lists are hardcoded today. |
| Provider for state | Simplest officially-recommended option for someone new to Flutter; one state object per screen. |
| `image_picker` (not `camera`) | Uses the native camera app — no viewfinder/lifecycle code, robust across devices. |
| Conditional-import HTTP adapter | Keeps `dart:io`/cookie jar out of the web build so `flutter run -d chrome` compiles for UI preview. |
| minSdk 23 | Uniform runtime-permission model + modern TLS for self-signed HTTPS; covers essentially all phones in use. |
| Text+images chat first | Core coordination flow; voice adds recording/permission/format work better done as a fast follow-up. |

---

## 9. Bugs found while building (and fixed)

1. **Startup crash** — `LateInitializationError: 'dio' not initialized`. On first launch (no server URL yet), `restoreSession()` read `isConfigured`, which touched the uninitialized Dio. Would have crashed the phone on first run too. Fixed by giving `ApiClient` a default Dio and a separate `_configured` flag. *(Caught by actually launching in Chrome.)*
2. **Wrong error on bad password** — `requestJson` treated every 401 as "session expired," so a wrong password showed "Session expired" instead of "Invalid credentials." Fixed by only treating 401s carrying `error:"authentication_required"` as expiry.
3. **Keystore path** — release signing looked under the `app/` module. Fixed to resolve `storeFile` against the project root (`rootProject.file`).
4. **`.gitignore`** — the repo's Python `lib/` rule would have hidden the Flutter `android/lib/` source. Fixed with explicit re-includes; verified with `git check-ignore`.

---

## 10. Known limitations & future work

- **Base64 payloads are heavy** — create POST ≈1–3 MB; list/detail responses embed full images. A future `GET /api/android/trackers/summary` with an image-stripping projection would speed the dashboard on mobile data. *(Flagged, not built.)*
- **No offline mode** — every screen needs the server; a failed create loses wizard state.
- **Self-signed trust is per-host, not pinning** — simpler, but weaker against a LAN attacker; regenerating the cert doesn't break the app.
- **Socket.IO has no server auth** — an existing web limitation the app inherits.
- **Chrome build is UI-preview only** — no CORS on Flask + native cookie jar; real use is the phone/APK.
- **v2 candidates:** voice notes, read-only FEG/FS/FSG logins, targeted list updates instead of full refetch, connection-status indicator, "remember password."

---

## 11. Environment used to build (reference)

| | |
|---|---|
| Flutter | 3.27.4 stable |
| Dart | 3.6 |
| JDK | Temurin 17 |
| Android SDK | platform 35, build-tools 35.0.0 |
| App ID / min / target | `com.itrack.fieldapp` / API 23 / API 35 |
| Output APK | `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` (~17.5 MB), signed `CN=iTrack Field App` |

Verified: `flutter analyze` clean, unit tests pass, web + release builds succeed, app launches and serves, `/api/android/ping` reachable, APK signed with the release key.
