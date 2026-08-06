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
so iOS builds can't happen on this (Windows) machine at all. Every iOS build,
sign, and archive step runs on a GitHub Actions macOS runner instead; see
[iOS builds and TestFlight](#ios-builds-and-testflight) below for the pipeline
and how testers get a build.

The BLE beacon auto check-in feature has a native iOS port
(`BeaconMonitor`/`BeaconBackgroundChannel`/`BeaconBackgroundRunner`.swift)
using Core Location/`CLBeaconRegion` region monitoring — Android's
CoreBluetooth-style background-scan approach doesn't transfer, since iOS
needs region monitoring and an "Always" location grant instead. The toggle
in `AccountSettingsScreen` is live on both platforms, but the iOS side is
implemented-but-unverified: the Simulator has no real Bluetooth radio and
can't meaningfully simulate region monitoring either, so foreground,
backgrounded, and fully-terminated detection all still need to be checked on
a physical iPhone once one is available.

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

### iOS builds and TestFlight

CI lives in `.github/workflows/ios.yml`, a separate file from Android's on
purpose — see that file's header comment for why splitting is fine here even
though `android.yml` deliberately isn't split. `verify` runs on
`ubuntu-latest` (no Xcode needed for `flutter analyze`/`flutter test`);
`build` runs on a `macos-14` runner, since that's the only way to build,
sign, and archive an iOS app without a physical Mac.

| Trigger | Environment | Result |
|---|---|---|
| Pull request | — | `flutter analyze` + tests only, no artifact |
| Push to `main` | `test` | Uploaded to TestFlight (Internal Testing group) |
| Tag `v*` | `test` for now, `prod` later | Uploaded to TestFlight (Internal Testing group) |

Every row ends at TestFlight, unlike Android's table: there's no iOS
equivalent of handing someone an installable file directly. Apple only
allows sideloading outside TestFlight via enterprise or ad-hoc UDID
registration, neither of which fits a public club app, so TestFlight is the
only distribution path — don't add a GitHub Release/direct-download row to
match Android without re-deriving why they differ.

`CFBundleVersion` comes from `ios.yml`'s own `github.run_number`, which is
an **independent counter** from `android.yml`'s (each workflow file gets its
own). That's fine: Apple only requires it to increase within this bundle
ID's own TestFlight history, never compared against Android's `versionCode`.
`CFBundleShortVersionString` is resolved the same way as Android's
`versionName` — from the `v*` tag, or `0.0.<run>` off `main`.

#### Apple Developer Program prerequisites

One-time setup, done by a human in Apple's portals — CI can't bootstrap any
of this:

1. **Enroll in the Apple Developer Program** ($99/yr). Individual enrollment
   is faster but puts a personal legal name on TestFlight/the App Store with
   no clean upgrade path later; organization enrollment shows "Tampa Gaming
   Guild" but needs a **D-U-N-S number** for the club, which can take days to
   weeks — start that lookup early if choosing this path.
2. Register the App ID `com.tampagamingguild.tggmobile` in the Apple
   Developer portal, matching the bundle id already in `project.pbxproj` and
   Android's `applicationId`. No extra capability registration is needed for
   the beacon port's background location mode — unlike Push Notifications or
   HealthKit, `UIBackgroundModes: [location]` is a plain `Info.plist`
   declaration with no App ID-level capability or entitlement behind it, so
   `release_testflight` picks it up without a `bootstrap_signing` re-run.
3. Create the app record in App Store Connect (**My Apps → New App**) — like
   Play above, the API can't create an app's first record, only upload to an
   existing one.
4. Generate an **App Store Connect API key** (Users and Access →
   Integrations → App Store Connect API, role **App Manager**). Download the
   `.p8` immediately; Apple only allows one download. This is what lets CI
   authenticate non-interactively — no Apple ID/2FA prompt to clear, which
   matters since nobody will ever be sitting at a Mac to clear one.
5. Add each tester as an App Store Connect user first (**Users and Access →
   People**, by Apple ID email), then create an **Internal Testing** group
   under the TestFlight tab and add them to it, with **Automatic
   Distribution** turned on. Internal testers (up to 100) get a build the
   moment Apple finishes processing it, with no per-build review — unlike
   external/public-link testers, who'd need a short Beta App Review each
   time.

### For testers (TestFlight)

Unlike Android's fixed sideload link, there's no file to hand anyone. Once
added to App Store Connect and the Internal Testing group (above), a tester
gets a TestFlight invite by email; installing the TestFlight app and
accepting it is the only manual step. After that, new builds arrive
automatically — no re-announcement needed the way Android's sideload builds
require.

### iOS signing

Builds are signed via [`fastlane match`](https://docs.fastlane.tools/actions/match/)
rather than a manually exported `.p12`/`.mobileprovision`: match can
generate the distribution cert and provisioning profile itself, from CI, via
the App Store Connect API — no step ever needs Xcode open on a Mac nobody
has, not even the first time.

Certs/profiles live in a **separate, private** repo
(`tampa-gaming-guild/tgg-mobile-ios-signing`), never in this one — this repo
is public, same reasoning as the Android keystore. File contents are
encrypted with `MATCH_PASSWORD` regardless, but a private repo also keeps
cert/profile metadata and commit cadence off public view and write access
scoped to just Bob and CI.

Two fastlane lanes (`ios/fastlane/Fastfile`):
- `bootstrap_signing` — generates/refreshes the cert and profile. Run once
  via `workflow_dispatch`, and again whenever the cert is renewed (yearly).
- `release_testflight` — what the normal `build` job runs. Always uses
  `match(readonly: true)`: a routine CI run should never be able to mutate
  the shared cert store, only an intentional `bootstrap_signing` run can.

CI secrets needed: `APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID`,
`ASC_KEY_CONTENT` (the downloaded `.p8`, base64-encoded — same
`[Convert]::ToBase64String(...)` approach as the Android keystore, not
`certutil -encode`), `MATCH_GIT_URL`, `MATCH_GIT_BASIC_AUTHORIZATION` (a PAT
scoped to the signing repo), and `MATCH_PASSWORD`. The repo variable
`TESTFLIGHT_GROUP` names which internal group builds go to (defaults to
`Internal`).

> **Back up `MATCH_PASSWORD` and the App Store Connect API key before the
> first release**, the same way the Android keystore gets backed up. A new
> API key can always be generated, but losing the match passphrase makes
> every cert/profile in the signing repo unreadable, and the only remedy is
> re-running `bootstrap_signing` from scratch.

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
feature's native code.

The Android application id is `com.tampagamingguild.tggmobile`, matching the
iOS bundle id. It is **permanent once published to Play**. Note that the
MethodChannel names in `lib/beacon/beacon_background.dart` embed that string and
are matched by constants in `BeaconBackgroundChannel.kt`/`BeaconBackgroundRunner.kt`
(Android) and `BeaconBackgroundChannel.swift`/`BeaconBackgroundRunner.swift`
(iOS) — they are opaque names, so changing one side alone compiles and
launches cleanly and then silently never delivers a call.
