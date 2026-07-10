# iTrack FE App — Testing Guide

Four ways to run the app, from easiest to most realistic. **A physical phone over USB is the primary method** — it's the only one that exercises the camera, GPS, and the real login end-to-end. **No phone? Use the Android emulator (Method B)** — it runs the real native build and logs in for real (unlike Chrome).

Throughout, run all `flutter` commands from the app folder:
```powershell
cd d:\pankajfx_github_all_repo\iTrack\android
```

---

## First: start the Flask server

The app needs the iTrack server running. On the laptop:
```powershell
cd d:\pankajfx_github_all_repo\iTrack
python scripts\seed_form_options.py   # once — fills the dropdown lists
python app.py                          # starts on http://0.0.0.0:5001 (or $PORT)
```
Leave it running in its own terminal. Note the laptop's LAN IP (`ipconfig` → IPv4, e.g. `192.168.1.50`).

---

## Method A — Physical phone over USB  ⭐ recommended

This is the real thing: real camera, real GPS, real APK behaviour.

### One-time phone setup
1. On the phone: **Settings → About phone → tap "Build number" 7 times** to unlock Developer Options.
2. **Settings → Developer options → enable "USB debugging."**
3. Plug the phone into the laptop with a USB cable. On the phone, tap **"Allow"** when it asks to trust this computer.
4. Confirm the laptop sees it:
   ```powershell
   adb devices
   ```
   You should see your device listed as `device` (not `unauthorized`).

### Run it
```powershell
flutter run
```
(If multiple devices are connected, `flutter devices` then `flutter run -d <deviceId>`.)

The app installs and opens on the phone with **hot reload** — edit a `.dart` file, press `r` in the terminal, and the change appears instantly.

### Point the app at the server
On the phone's **Server Setup** screen, enter the laptop's LAN address:
```
http://192.168.1.50:5001
```
(Use your real IP + port.) Requirements:
- Phone and laptop on the **same Wi-Fi**.
- **Windows Firewall** must allow inbound connections to the port. One-time rule (PowerShell **as Administrator**):
  ```powershell
  New-NetFirewallRule -DisplayName "iTrack Flask 5001" -Direction Inbound -Protocol TCP -LocalPort 5001 -Action Allow
  ```
Tap **Test & Continue** → it should say "Connected." Then log in with a real FE account.

### Wireless (no cable) — optional, Android 11+
```powershell
adb pair <phone-ip>:<pair-port>      # from phone: Developer options → Wireless debugging → Pair with code
adb connect <phone-ip>:<port>
flutter run
```

---

## Method B — Android emulator (no physical phone)  📱

A virtual Android device running on the laptop. It runs the **real native build**, so — unlike Chrome — the cookie jar, real login, chat, and hybrid Socket.IO all work end-to-end. Camera and GPS are simulated (the emulator provides a fake camera image and a settable mock location), so it's not a substitute for final on-device testing, but it's the best option when no phone is handy.

### Where the tools live
The Android SDK ships `emulator`, `adb`, `avdmanager`, and `sdkmanager`. On this machine the SDK is at `%LOCALAPPDATA%\Android\Sdk`. The commands below assume these are on your `PATH`; if `adb`/`emulator` aren't found, add them once (PowerShell, current user):
```powershell
$sdk = "$env:LOCALAPPDATA\Android\Sdk"
$paths = "$sdk\platform-tools;$sdk\emulator;$sdk\cmdline-tools\latest\bin"
[Environment]::SetEnvironmentVariable("Path", "$([Environment]::GetEnvironmentVariable('Path','User'));$paths", "User")
# reopen the terminal afterwards
```
`avdmanager`/`sdkmanager` also need a JDK on `JAVA_HOME` (any JDK 17). Flutter itself already finds the SDK via `flutter config`.

### Start an existing emulator
```powershell
emulator -list-avds                 # see what virtual devices exist
emulator -avd itrack_pixel5         # boot one (this repo's default AVD)
```
Leave that terminal open — it's the running device. Wait ~1 min for first boot, then confirm it's online:
```powershell
adb devices                         # should show  emulator-5554   device
```

### Run the app on it
```powershell
flutter run                         # if the emulator is the only device
flutter run -d emulator-5554        # if a phone is also connected
```
Hot reload works exactly as on a phone — edit a `.dart` file, press `r`.

### Point the app at the server
From inside an emulator, `localhost` means the emulator itself, **not** the laptop. Two options on the **Server Setup** screen:
- `http://10.0.2.2:5001` — the emulator's built-in alias for the laptop's loopback. **Easiest — no LAN IP, no firewall rule needed.**
- `http://192.168.1.50:5001` — the laptop's real LAN IP (same as a phone would use).

Make sure Flask is running (`python app.py` binds `0.0.0.0:5001`). Tap **Test & Continue** → "Connected", then log in with a real FE account.

> **Speed:** the emulator uses hardware acceleration (WHPX/HAXM). If it's sluggish or won't boot, run `emulator -accel-check`. On Windows, Windows Hypervisor Platform must be enabled (Windows Features → "Windows Hypervisor Platform").

---

## Method C — Chrome (UI preview only)  🖥️

Good for quickly *seeing* screens and layout while editing. **Not** a full test:
- The camera/GPS buttons won't do anything useful in a browser.
- The Flask server sends **no CORS headers**, so by default the browser blocks the app's API calls — you'll see the UI but can't get past Server Setup.

Plain preview (UI only):
```powershell
flutter run -d chrome
```

**Full-flow preview** (lets the browser actually call the server) — launch Chrome with web security off, pointed at a **local** server:
```powershell
flutter run -d chrome --web-port=8080 --web-browser-flag="--disable-web-security"
```
Then in Server Setup enter `http://localhost:5099` (or wherever Flask is running locally) and log in. ⚠️ Only do this with a dev Chrome window — never browse other sites with web security disabled. This is a convenience, not the supported runtime.

> Why the limitation? On the phone the app uses a native cookie jar and its own HTTPS stack. In a browser those don't exist — the browser enforces CORS and manages cookies itself. The Android app is the real product; Chrome is just a fast way to eyeball the UI.

---

## Method D — Install the APK (no laptop cable needed)

Once you've built an APK (see `BUILD_RELEASE.md`), you can hand it to any phone:

1. Build:
   ```powershell
   flutter build apk --release --split-per-abi
   ```
2. Copy `build\app\outputs\flutter-apk\app-arm64-v8a-release.apk` to the phone (USB, email, or a link).
3. On the phone, open the file. Android will say the app is from an unknown source → tap **Settings → allow "Install unknown apps"** for your file manager/browser, then install.
4. Open **iTrack FE**, enter the server URL, log in.

This is how you distribute to field engineers — no Play Store, no cable.

---

## A good end-to-end test run (parity with the website)

Do this once with a real FE account, ideally with the website open side-by-side as an NOC user:

1. **Login** → dashboard shows your trackers in the three buckets (Unassigned / Ongoing / Done). Compare counts with the website.
2. **Search** for a customer/SDWAN ID → list filters.
3. **+ New** → take the 3 site photos (check the GPS chip shows an address) → fill the form (dropdowns load from the server) → Create. The new tracker should appear on the **website's NOC dashboard** with your 3 GPS-stamped photos.
4. Have the NOC user (website) assign it, activate SIM, verify ZTP config. Watch the phone's tracker update within ~1 second (Socket.IO) — or within 30 s if the socket is blocked.
5. On the phone, run the **ZTP** and **HSO** actions as they unlock. Confirm the buttons appear/disappear at the same statuses as the website.
6. Once status reaches coordination, open **Chat** → send a text and a photo → confirm both show on the website, and NOC's replies show on the phone.
7. Kill and reopen the app → you're **still logged in** (cookie persisted).

If all of that matches the website, the app is working.

---

## Appendix — Managing emulators (create more virtual devices)

Everything here uses the SDK command-line tools (`sdkmanager`, `avdmanager`, `emulator`); no Android Studio needed. Ensure they're on `PATH` and `JAVA_HOME` points at a JDK 17 (see Method B → "Where the tools live").

### 1. Pick and install a system image
A system image is the Android OS the virtual device runs. List what's available / installed:
```powershell
sdkmanager --list                                   # long; look under "system-images;..."
sdkmanager --list_installed
```
Install one (example: Android 14 / API 34, Google APIs, 64-bit):
```powershell
sdkmanager "system-images;android-34;google_apis;x86_64"
```
Image naming: `system-images;android-<API>;<variant>;<abi>`.
- **variant** — `google_apis` (Google services, recommended, mimics a real phone) · `google_apis_playstore` (adds the Play Store) · `default` (bare AOSP).
- **abi** — use `x86_64` on Intel/AMD laptops. (This repo's existing AVD uses the already-installed `system-images;android-30;google_apis;x86`.)

### 2. See the available hardware profiles (device shapes)
```powershell
avdmanager list device                               # pixel_5, pixel_7, Nexus_6, tablets, etc.
```

### 3. Create the AVD
```powershell
avdmanager create avd -n pixel7_api34 -k "system-images;android-34;google_apis;x86_64" -d "pixel_7"
```
- `-n` — a name you choose (used with `emulator -avd <name>`).
- `-k` — the installed system image from step 1.
- `-d` — a device profile from step 2 (sets screen size/density). Omit for a generic device.

Answer **no** to "custom hardware profile" unless you need to tweak RAM/storage. Verify:
```powershell
emulator -list-avds
```

### 4. Launch a chosen device and run any app
```powershell
emulator -avd pixel7_api34                           # boot the device you want
adb devices                                          # confirm it's "device"
flutter run -d emulator-5554                          # launch this Flutter app on it
```
To run a **different app / prebuilt APK** on the same emulator instead:
```powershell
adb install path\to\some_app.apk                     # install any APK
adb shell monkey -p com.itrack.fieldapp 1            # or just launch an installed app by package id
```

### Handy commands
```powershell
emulator -avd itrack_pixel5 -no-snapshot-load        # cold boot (ignore saved state)
emulator -avd itrack_pixel5 -wipe-data               # factory reset the device
avdmanager delete avd -n pixel7_api34                # remove an AVD
adb -s emulator-5554 emu kill                        # shut a running emulator down
```
Multiple emulators can run at once; each gets its own id (`emulator-5554`, `-5556`, …) — target one with `flutter run -d <id>`.
