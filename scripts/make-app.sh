#!/bin/bash
# Assembles dist/AgentTracker.app around the SwiftPM release binary — no Xcode
# project (see the Package.swift header for why the repo stays Xcode-free).
#
#   scripts/make-app.sh             # build + assemble + sign + validate
#   scripts/make-app.sh --install   # …then copy into /Applications
#
# Signing: ad-hoc by default. Set CODESIGN_IDENTITY to a Developer ID to
# produce a distributable build (hardened runtime is enabled only then —
# notarization requires it, ad-hoc gains nothing from it). Honest ladder:
#   unsigned      — TCC grants break on every launch; never shipped
#   ad-hoc        — grants stick to this exact binary; rebuilding/replacing the
#                   app INVALIDATES the old Accessibility grant, and toggling
#                   the stale entry does nothing — remove it with − and re-add
#                   (or: tccutil reset Accessibility com.thinkvelta.agent-tracker)
#   self-signed   — grants survive rebuilds. One-time setup: Keychain Access →
#                   Certificate Assistant → Create a Certificate… → name
#                   "AgentTracker Local", type "Code Signing"; then build with
#                   CODESIGN_IDENTITY="AgentTracker Local" make install
#   Developer ID  — grants survive updates; Gatekeeper-friendly for download
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

APP_NAME="AgentTracker"
BUNDLE_ID="com.thinkvelta.agent-tracker"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD 2> /dev/null || echo 1)"
MIN_OS="14.0"
IDENTITY="${CODESIGN_IDENTITY:--}"

DIST="$REPO/dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"

echo "==> swift build -c release"
swift build -c release
BINARY="$(swift build -c release --show-bin-path)/$APP_NAME"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BINARY" "$CONTENTS/MacOS/$APP_NAME"
cp assets/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"
# The hook installers ride along so a bundled app can onboard without the
# repo present; they copy the hook to ~/.agent-tracker/bin, so nothing ever
# references a path inside the bundle.
cp -R integrations "$CONTENTS/Resources/integrations"

cat > "$CONTENTS/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_NUMBER</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.developer-tools</string>
	<key>LSMinimumSystemVersion</key>
	<string>$MIN_OS</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> codesign ($([ "$IDENTITY" = "-" ] && echo ad-hoc || echo "$IDENTITY"))"
SIGN_FLAGS=(--force --sign "$IDENTITY")
[ "$IDENTITY" != "-" ] && SIGN_FLAGS+=(--options runtime --timestamp)
codesign "${SIGN_FLAGS[@]}" "$APP"

echo "==> validating"
plutil -lint "$CONTENTS/Info.plist" > /dev/null
# LSUIElement is what keeps the app out of the Dock; agreeing with the
# runtime .accessory policy is a hard requirement, so its absence fails the
# build rather than shipping an app that flashes a Dock icon.
[ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$CONTENTS/Info.plist")" = "true" ]
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$CONTENTS/Info.plist")" = "$BUNDLE_ID" ]
[ -x "$CONTENTS/MacOS/$APP_NAME" ]
[ -f "$CONTENTS/Resources/AppIcon.icns" ]
[ -x "$CONTENTS/Resources/integrations/agent-tracker-hook.py" ]
codesign --verify --deep "$APP"
echo "    OK: $APP_NAME.app v$VERSION ($BUILD_NUMBER), $(du -sh "$APP" | cut -f1 | tr -d ' ')"

if [ "${1:-}" = "--install" ]; then
  TARGET="/Applications"
  [ -w "$TARGET" ] || TARGET="$HOME/Applications"
  mkdir -p "$TARGET"
  echo "==> installing into $TARGET"
  if pgrep -x "$APP_NAME" > /dev/null; then
    echo "    stopping the running $APP_NAME"
    pkill -x "$APP_NAME" || true
    sleep 1
  fi
  rm -rf "${TARGET:?}/$APP_NAME.app"
  # ditto preserves the code signature; cp -R can subtly invalidate it.
  ditto "$APP" "$TARGET/$APP_NAME.app"
  echo "    installed — launch with: open '$TARGET/$APP_NAME.app'"
fi
