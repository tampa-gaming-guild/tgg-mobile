# Flutter + Android SDK/build-tools, no local toolchain install required.
# iOS builds aren't possible from this image (or any Linux container) --
# Xcode only runs on macOS -- see README for the GitHub Actions macOS runner
# plan for iOS builds.
FROM ghcr.io/cirruslabs/flutter:stable

WORKDIR /workspace

# Accept Android SDK licenses at build time so `flutter build apk` and
# `flutter run` don't block on an interactive prompt later.
RUN yes | sdkmanager --licenses > /dev/null || true
