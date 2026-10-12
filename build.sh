#!/usr/bin/env bash
#
# Builds Kivi-Dash.app from the SwiftPM package.
#
# SwiftPM has no first-class notion of an app bundle, so this script assembles
# one by hand and ad-hoc signs it. That keeps `swift build` working for
# contributors with only the Command Line Tools, and avoids checking in an
# .xcodeproj (merge conflicts, plus an Xcode dependency for no benefit).
#
# Usage:
#   ./build.sh                  build, test, lint, assemble, sign
#   ./build.sh --skip-tests     assemble without running the test suite
#   ./build.sh --install        also copy the bundle to /Applications
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

APP_NAME="Kivi-Dash"
BUNDLE_ID="com.shridhar600.kividash"
# CFBundleVersion must be period-separated integers. `git describe` yields e.g.
# `v0.3.0`, which LaunchServices rejects — and `plutil -lint` would not catch it.
RAW_VERSION="$(git describe --tags --abbrev=0 2>/dev/null || echo "0.1.0")"
VERSION="$(printf '%s' "$RAW_VERSION" | sed 's/^v//; s/[^0-9.].*$//')"
if ! [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then VERSION="0.1.0"; fi
BUILD_DIR="$ROOT/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"

SKIP_TESTS=0
DO_INSTALL=0
DO_LAUNCH=1
for arg in "$@"; do
  case "$arg" in
    --skip-tests) SKIP_TESTS=1 ;;
    --install) DO_INSTALL=1 ;;
    --no-launch) DO_LAUNCH=0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '\033[1m==>\033[0m %s\n' "$1"; }

# Always start from a clean bundle so stale resources cannot linger.
say "Cleaning $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$CONTENTS/MacOS"

if [ "$SKIP_TESTS" -eq 0 ]; then
  say "swift test"
  swift test
fi

say "swift build -c release"
swift build -c release

BINARY="$(swift build -c release --show-bin-path)/KiviStatsApp"
if [ ! -x "$BINARY" ]; then
  echo "expected executable not found: $BINARY" >&2
  exit 1
fi
cp "$BINARY" "$CONTENTS/MacOS/$APP_NAME"

say "Writing Info.plist"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- Menu bar only: no Dock icon and no app switcher entry. Without this the
         app launches with a Dock icon and no visible window. -->
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Fail the build on a malformed plist rather than shipping a bundle that will
# not launch.
say "Validating Info.plist"
plutil -lint "$CONTENTS/Info.plist"

# Ad-hoc signature: enough to run locally, requires no certificate or secrets.
say "Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP_BUNDLE"
codesign --verify --verbose=2 "$APP_BUNDLE" 2>&1 | sed 's/^/    /'

say "Built $APP_BUNDLE"
# Launching is opt-out: a successful build opens the app by default so a local
# build is immediately visible; --no-launch suppresses it for scripts or a
# machine where the app should not start.
if [ "$DO_LAUNCH" -eq 1 ]; then open "$APP_BUNDLE" 2>/dev/null || true; fi

if [ "$DO_INSTALL" -eq 1 ]; then
  say "Installing to /Applications"
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP_BUNDLE" "/Applications/$APP_NAME.app"
  # Launch Services caches bundle paths; without this a rebuild at a new path
  # can appear to do nothing.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "/Applications/$APP_NAME.app" || true
  echo "Installed. Launch at login is not registered automatically."
fi