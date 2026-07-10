# iTrack FE — Android App (Flutter)

Native Android companion to the iTrack (SDWAN Installation Tracker) web app, reproducing the **Field Engineer** experience: login, tracker dashboard (Unassigned / Ongoing / Done), new-installation wizard with GPS-stamped camera photos, tracker detail with ZTP/HSO actions, and FE↔NOC chat. It talks directly to the existing Flask server using the same session-cookie auth.

## Docs (read in this order)
1. **[docs/OVERVIEW.md](docs/OVERVIEW.md)** — the full detailed reference: file map, API contract, web↔app parity, decisions, fixes. Start here for the complete picture.
2. **[docs/SETUP.md](docs/SETUP.md)** — get a machine ready to build (JDK, Android SDK, Flutter). No Android Studio needed.
3. **[docs/TESTING.md](docs/TESTING.md)** — run it: on a phone over USB, in Chrome (UI preview), or as an installed APK.
4. **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — how it all fits together, with diagrams (great if you're new to mobile dev).
5. **[docs/BUILD_RELEASE.md](docs/BUILD_RELEASE.md)** — create the keystore and build the shareable APK.

## Quick start
```powershell
cd d:\pankajfx_github_all_repo\iTrack

# 1) Backend: seed dropdowns + run the server (once + each session)
python scripts\seed_form_options.py
python app.py

# 2) App: run on a connected phone (see docs/TESTING.md for server URL + firewall)
cd android
flutter pub get
flutter run
```

## At a glance
| | |
|---|---|
| Package | `itrack_fe` · App ID `com.itrack.fieldapp` |
| Min Android | 6.0 (API 23) · target API 35 |
| State mgmt | Provider (`ChangeNotifier`) |
| Server API | Existing Flask `/api/*` + new `/api/android/*` (see `../android_backend/`) |
| Auth | Flask session cookie (persistent) — no tokens |
| Realtime | Socket.IO + 30 s polling (hybrid, mirrors web) |
| v1 scope | FE role; chat text + images (voice notes deferred) |

> Signing secrets (`android/key.properties`, `android/keystore/`) are gitignored — never commit them.
