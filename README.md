# TGG Mobile

Companion app for Tampa Gaming Guild members and hosts: dashboard, profile,
membership credits, and BLE-beacon auto check-in. Talks to the token-based
API in the [`clubmanager`](https://github.com/tampa-gaming-guild/clubmanager)
repo (`public_html/member/api/`) — that repo is the source of truth for the
database and business logic; this repo is the client only.

## Toolchain: Docker, no local Flutter install required

Flutter + the Android SDK/build tools live in a container
(`docker/flutter/Dockerfile`, based on `ghcr.io/cirruslabs/flutter:stable`).
Nobody needs Flutter installed on their machine to build or test the Android
side of this app.

```
docker compose up -d flutter
docker exec tgg-mobile-flutter flutter pub get
docker exec tgg-mobile-flutter flutter analyze
docker exec tgg-mobile-flutter flutter test
docker exec tgg-mobile-flutter flutter build apk --debug
```

The repo is bind-mounted into the container at `/workspace`; `pub` and
`gradle` caches live in named volumes so they survive container rebuilds.

### Choosing a backend

Which server a build talks to is fixed at compile time by `TGG_ENV`, defined
in `lib/config/app_config.dart`:

| `TGG_ENV` | Backend | Notes |
|---|---|---|
| `dev` (default) | `http://localhost:8080/member/api` | Reached from a physical device via `adb reverse tcp:8080 tcp:8080` |
| `test` | `https://tampagamingguild.org/member/api` | Stripe is in test mode here, so renewal and payment flows are safe to exercise |
| `prod` | *not available yet* | Refused at startup, see below |

```
docker exec tgg-mobile-flutter flutter build apk --debug --dart-define=TGG_ENV=test
```

Named environments rather than a raw URL, because the path differs per
environment as well as the host — handing the full URL to whoever types the
build command makes a typo into a plausible but wrong target.

There is no `prod` yet: `https://tampagamingguild.org/api` is still served by
the WordPress/CiviCRM site, so a build pointed there would fire login and
check-in requests at the live public site and get HTML back instead of JSON.
`AppConfig.validate()` throws on startup for `prod`, and for any unrecognised
value, rather than silently falling back to the dev URL. Wire it up when the
real docroot moves to `public_html/member/`.

Non-production builds show a corner ribbon naming the environment, and
Account Settings prints the environment and base URL at the bottom. That is
driven by `TGG_ENV`, not by debug/release, since a release build aimed at
`test` is otherwise indistinguishable from a real one — and this app writes
real check-ins, including on its own via beacon auto check-in.

Any deployed target must be HTTPS: cleartext is permitted only for
`localhost` (`android/app/src/main/res/xml/network_security_config.xml`).

### Running on a real Android device (required for BLE testing)

Emulators don't have real BLE radios, so background beacon detection can only
be verified on physical hardware. The container reaches your device through
an ADB server running on the **host** (Windows), not inside the container —
no USB passthrough needed:

1. On the host, start adb listening on all interfaces: `adb -a -P 5037 nodaemon server`
2. Connect your phone: over USB (`adb devices` should list it), or over WiFi
   (`adb connect <phone-ip>:5555` after enabling wireless debugging on the
   phone and pairing it once over USB).
3. From the container: `docker exec tgg-mobile-flutter flutter devices` should
   now show the phone (the container is pre-configured via
   `ANDROID_ADB_SERVER_ADDRESS` in `docker-compose.yml` to talk to the host's
   adb server instead of spinning up its own).
4. `docker exec -it tgg-mobile-flutter flutter run` to install and run with
   hot reload.

### iOS

Xcode only runs on macOS — no container or emulation trick works around that,
so iOS builds can't happen on this (Windows) machine at all. Plan: CI builds
via a GitHub Actions macOS runner once the Android app is in decent shape;
someone with a physical iPhone will need to sideload/TestFlight it for actual
BLE testing there, since the iOS Simulator has no real Bluetooth radio either.

## Builds and releases

CI lives in a single file, `.github/workflows/android.yml`, and that is
deliberate: `github.run_number` is counted **per workflow file** and it becomes
the APK's `versionCode`. Two workflow files would keep two independent
counters, and Android refuses a downgrade while Play refuses a duplicate. For
the same reason, **never rename that file** — renaming resets the counter to 1.

| Trigger | Environment | Result |
|---|---|---|
| Pull request | — | `flutter analyze` + tests only, no artifact |
| Push to `main` | `test` | Signed APK, published over the rolling `latest-test` pre-release |
| Tag `v*` | `test` for now, `prod` later | Signed APK on a real Release, plus an AAB for Play |

Version numbers come from the tag, not from `pubspec.yaml` (whose `version:`
is a placeholder): tagging `v1.2.3` gives `versionName` 1.2.3, and the CI run
number becomes `versionCode`. Builds off `main` are versioned `0.0.<run>`.

Re-running a failed run reuses its run number, so if a tag build fails after
uploading anywhere, push a new tag rather than re-running it.

### For testers (sideloading)

The download link never changes:

```
https://github.com/tampa-gaming-guild/tgg-mobile/releases/download/latest-test/tgg-mobile-test.apk
```

Install straight over the previous build — no uninstall needed, as long as the
signing key hasn't changed. There is **no auto-update**: Android never notices
a new APK exists, so new builds have to be announced. First install only, the
phone asks permission to install apps from your browser, and Play Protect warns
that the developer is unrecognised (**More details → Install anyway**). Both are
normal for any app not distributed through the Play Store.

### Release signing

Release builds are signed with an upload keystore that **never lives in this
repo**. `android/app/build.gradle.kts` reads it from `android/key.properties`
locally, or from environment variables in CI, and hard-fails when `CI` is set
and no keystore is configured — a debug-signed release would install fine and
then never be upgradable.

Generate it once, outside the repo:

```
keytool -genkeypair -v -keystore R:/secure/tgg/tgg-upload.jks \
  -storetype PKCS12 -alias tgg-upload -keyalg RSA -keysize 4096 \
  -validity 10950 \
  -dname "CN=Tampa Gaming Guild, OU=Mobile, O=Tampa Gaming Guild, L=Tampa, ST=Florida, C=US"
```

Then `android/key.properties` (gitignored — forward slashes even on Windows,
since backslash is an escape character in `.properties` files):

```
storeFile=R:/secure/tgg/tgg-upload.jks
storePassword=...
keyAlias=tgg-upload
keyPassword=...
```

For CI, base64 the keystore into `ANDROID_KEYSTORE_BASE64` alongside
`ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD`.
Use PowerShell's `[Convert]::ToBase64String(...)`, **not** `certutil -encode`,
which wraps the output in PEM headers that `base64 -d` rejects.

> **Back the keystore up before the first release.** GitHub secrets are
> write-only — you cannot read it back out. Android will not install an update
> whose signing certificate differs from the installed copy, so losing this file
> permanently severs you from every phone that has the app, and the only remedy
> is having every user uninstall and reinstall. Keep it in a password manager
> plus one offline copy, and record its SHA-256 fingerprint
> (`keytool -list -v -keystore ...`) so future builds can be verified.

### Google Play

Not wired up yet — there is no developer account. The upload step exists in the
workflow but is inert until the repo variable `PLAY_ENABLED` is set to `true`.
Before flipping it: register (as an **organization**, which exempts you from the
12-testers-for-14-days rule that applies to personal accounts), create the app
under `com.tampagamingguild.tggmobile`, and upload the first bundle **by hand** —
the API cannot create an app's initial release.

### Launcher icon

The icon sources in `assets/icon/` are generated from the brand master in
`Logos/` (untracked, ~20 MB of EPS/PDF lockups). `flutter_launcher_icons`
expands them into every density:

```
docker exec tgg-mobile-flutter dart run flutter_launcher_icons
```

The generated resources are committed so they show up in review. Note
`adaptive_icon_foreground_inset: 0` in `pubspec.yaml`: the foreground PNG
already carries its own safe-zone padding, sized so the artwork's diagonal
clears a circular mask, and the package's default 16% inset would stack on top
and shrink the mark to roughly 45% of the canvas. If you resize the artwork,
re-check it against circle, squircle and rounded-square masks — the d20 loses
its right-hand faces first.

## Project structure

Standard `flutter create` layout (`lib/`, `android/`, `ios/`). `android/` and
`ios/` are committed (not regenerated) since they carry the beacon-detection
plugin's native config once that's wired up.

The Android application id is `com.tampagamingguild.tggmobile`, matching the
iOS bundle id. It is **permanent once published to Play**. Note that the
MethodChannel names in `lib/beacon/beacon_background.dart` embed that string and
are matched by constants in `BeaconBackgroundChannel.kt` and
`BeaconBackgroundRunner.kt` — they are opaque names, so changing one side alone
compiles and launches cleanly and then silently never delivers a call.
