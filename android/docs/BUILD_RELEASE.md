# iTrack FE App — Building & Signing the APK

This produces the shareable `.apk` you give to field engineers to sideload (no Play Store).

Run everything from the app folder:
```powershell
cd d:\pankajfx_github_all_repo\iTrack\android
```

---

## Why signing matters

Android refuses to install an unsigned app, and it will only let a user *update* an app if the new APK is signed with the **same key** as the installed one. So you create **one keystore, once**, keep it safe forever, and sign every release with it. Lose it → users must uninstall/reinstall to update.

> The keystore and its passwords are **secrets**. They are gitignored (`android/android/key.properties`, `android/android/keystore/`) and must never be committed or shared publicly.

---

## Step 1 — Create the keystore (once)

`keytool` ships with JDK 17. From the app folder:
```powershell
mkdir android\keystore -Force
keytool -genkey -v -keystore android\keystore\itrack-release.jks -alias itrack -keyalg RSA -keysize 2048 -validity 10000
```
It asks for:
- a **keystore password** and a **key password** (can be the same; write them down somewhere safe),
- your name/org/location (any sensible values; press Enter to accept blanks, type `yes` to confirm).

## Step 2 — Point Gradle at it

Create `android\key.properties` (this file is gitignored) with your real values:
```properties
storePassword=YOUR_KEYSTORE_PASSWORD
keyPassword=YOUR_KEY_PASSWORD
keyAlias=itrack
storeFile=keystore/itrack-release.jks
```
`storeFile` is relative to the `android/android/` folder. The build script (`app/build.gradle`) automatically picks this up; if the file is absent it falls back to debug signing so `flutter run` still works.

## Step 3 — Build

**Recommended — smaller, per-CPU APKs:**
```powershell
flutter build apk --release --split-per-abi
```
Output in `build\app\outputs\flutter-apk\`:
- `app-arm64-v8a-release.apk` ← **give this one to almost everyone** (all modern phones)
- `app-armeabi-v7a-release.apk` ← only very old 32-bit phones
- `app-x86_64-release.apk` ← emulators / rare Intel devices

**Or one universal APK** (bigger, runs everywhere) if you don't want to pick:
```powershell
flutter build apk --release
# → build\app\outputs\flutter-apk\app-release.apk
```

## Step 4 — Share & install

Send `app-arm64-v8a-release.apk` to the phone (USB, email, WhatsApp, a download link…). On the phone, open it and allow "install unknown apps" when prompted. See `TESTING.md → Method C`.

---

## Releasing a new version

1. Bump the version in **`pubspec.yaml`**:
   ```yaml
   version: 1.0.1+2   # <versionName>+<versionCode>. versionCode MUST increase every release.
   ```
2. `flutter build apk --release --split-per-abi`
3. Distribute the new APK. Because it's signed with the same keystore, phones install it as an update (data preserved).

---

## App identity (already configured)

| Setting | Value | Where |
|---|---|---|
| Application ID | `com.itrack.fieldapp` | `android/app/build.gradle` |
| App name | `iTrack FE` | `android/app/src/main/AndroidManifest.xml` |
| Min Android | 6.0 (API 23) | `android/app/build.gradle` (`minSdk`) |
| Target/compile | API 35 | Flutter default |

Min SDK 23 covers effectively every phone in use while giving a uniform runtime-permission model for camera/location and a modern TLS stack for the self-signed HTTPS path.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Build fails: `keystore not found` | `storeFile` path in `key.properties` is wrong, or you skipped Step 1 |
| Build fails: `Keystore was tampered with, or password was incorrect` | Wrong password in `key.properties` |
| App won't install: "app not installed" | An older copy signed with a **different** key is installed — uninstall it first |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | Same as above — different signing key than the installed build |
| Gradle/JDK errors | Confirm `JAVA_HOME` points at JDK 17 (see `SETUP.md`) |
