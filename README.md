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

## Project structure

Standard `flutter create` layout (`lib/`, `android/`, `ios/`). `android/` and
`ios/` are committed (not regenerated) since they carry the beacon-detection
plugin's native config once that's wired up.
