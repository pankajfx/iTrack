# iTrack FE App — Development Setup (from zero)

This guide gets a **fresh Windows machine** ready to build and run the Flutter app. You do **not** need Android Studio — we use the command-line tools only.

> Already set up on the original dev laptop? Skip to `TESTING.md`. This is for a new machine or if something broke.

---

## What you need (and why)

| Tool | Version | Why |
|---|---|---|
| **Flutter SDK** | 3.27.x (stable) | The framework + `flutter` command |
| **JDK (Java)** | 17 (Temurin) | Gradle needs it to build the Android APK |
| **Android SDK** | platform 35, build-tools 35 | Compiles the Android app; `adb` talks to phones |
| **VS Code** | any recent | Editor + Flutter/Dart extensions (optional but recommended) |
| **Chrome** | any | For the UI-preview build |

---

## Step 1 — Flutter SDK

If `flutter --version` already prints 3.27.x, skip this.

1. Download the Flutter 3.27.x stable zip from https://docs.flutter.dev/release/archive (Windows).
2. Extract to `C:\flutter` (so `C:\flutter\bin\flutter.bat` exists).
3. Add `C:\flutter\bin` to your **Path** (User environment variables).
4. New terminal → `flutter --version` should print 3.27.x.

## Step 2 — JDK 17

```powershell
winget install --id EclipseAdoptium.Temurin.17.JDK --silent
```
Then set an environment variable (System → Environment Variables → User):
- `JAVA_HOME` = `C:\Program Files\Eclipse Adoptium\jdk-17.x.x-hotspot` (use the exact folder that appeared)
- Add `%JAVA_HOME%\bin` to **Path**.

Verify in a new terminal: `java -version` → should say `openjdk version "17…"`.

## Step 3 — Android SDK command-line tools

1. Download **"Command line tools only"** (Windows) from https://developer.android.com/studio#command-line-tools-only
2. Extract so the final layout is exactly:
   ```
   %LOCALAPPDATA%\Android\Sdk\cmdline-tools\latest\bin\sdkmanager.bat
   ```
   ⚠️ The `latest` folder level is **mandatory** — if you extracted a `cmdline-tools` folder, rename/move it to `cmdline-tools\latest`.
3. Set environment variables (User):
   - `ANDROID_HOME` = `%LOCALAPPDATA%\Android\Sdk`
   - Add to **Path**: `%ANDROID_HOME%\platform-tools` and `%ANDROID_HOME%\cmdline-tools\latest\bin`
4. Install the SDK packages (new terminal):
   ```powershell
   sdkmanager "platform-tools" "platforms;android-35" "build-tools;35.0.0" "build-tools;34.0.0"
   ```
5. Accept licences:
   ```powershell
   flutter doctor --android-licenses
   ```
   Press `y` at each prompt.

## Step 4 — Verify

```powershell
flutter doctor -v
```
You want green ticks for **Flutter**, **Android toolchain**, and **Chrome**. It's fine if "Visual Studio" and "Android Studio" show warnings — those are only for Windows-desktop apps and the Studio IDE, neither of which we use.

## Step 5 — Get the app's dependencies

```powershell
cd d:\pankajfx_github_all_repo\iTrack\android
flutter pub get
```

## Step 6 — VS Code (optional, recommended)

Install the **Flutter** and **Dart** extensions (the Flutter one pulls in Dart). Open the `android/` folder. You get autocomplete, error highlighting, and one-click run/debug.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `flutter` not recognised | `C:\flutter\bin` isn't on Path; open a **new** terminal after editing Path |
| Android toolchain ✗ "cmdline-tools missing" | The `cmdline-tools\latest` nesting is wrong (Step 3.2) |
| `Unable to locate a Java Runtime` / Gradle fails | `JAVA_HOME` not set or points at the wrong folder (Step 2) |
| `sdkmanager` not recognised | Add `…\cmdline-tools\latest\bin` to Path |
| Licences keep failing | Re-run `flutter doctor --android-licenses`, accept every prompt |
| `flutter pub get` network errors | Corporate proxy/VPN; try a different network |

Once `flutter doctor` is happy, continue to **`TESTING.md`** to run the app.
