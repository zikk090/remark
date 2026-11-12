#!/bin/bash
# Remark build script
#
#   ./build.sh            build build/Remark.app
#   ./build.sh install    build, copy to ~/Applications, launch
#   ./build.sh dmg        build + package build/Remark-<version>.dmg
#   ./build.sh release    dmg + push + create a GitHub release with the DMG attached (needs `gh`)
#
# Signing (auto-detected, override with REMARK_SIGN_ID):
#   • "Developer ID Application" → hardened runtime; set REMARK_NOTARY_PROFILE to notarize
#     (create it once with: xcrun notarytool store-credentials <profile> --apple-id … --team-id …)
#   • "Apple Development"        → fine for your own Macs
#   • none                        → ad-hoc
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-build}"
APP="build/Remark.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)

# ---------- build ----------
# Universal (Apple silicon + Intel) needs full Xcode; fall back to the native arch otherwise.
if swift build -c release --arch arm64 --arch x86_64 >/tmp/remark-universal.log 2>&1; then
  BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
  echo "Built universal binary"
else
  swift build -c release
  BIN=$(swift build -c release --show-bin-path)
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Remark" "$APP/Contents/MacOS/Remark"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -d Resources/AppIcon.iconset ]; then
  iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
fi

# ---------- sign ----------
SIGN_ID="${REMARK_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
  IDS=$(security find-identity -v -p codesigning 2>/dev/null || true)
  SIGN_ID=$(echo "$IDS" | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)"/\1/' || true)
  [ -z "$SIGN_ID" ] && SIGN_ID=$(echo "$IDS" | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/' || true)
fi

if [[ "$SIGN_ID" == Developer\ ID* ]]; then
  echo "Signing (hardened runtime) with: $SIGN_ID"
  codesign --force --options runtime --timestamp --entitlements Resources/Remark.entitlements --sign "$SIGN_ID" "$APP"
elif [ -n "$SIGN_ID" ]; then
  echo "Signing with: $SIGN_ID"
  codesign --force --sign "$SIGN_ID" "$APP"
else
  echo "Signing ad-hoc"
  codesign --force --sign - "$APP"
fi
echo "Built $APP ($VERSION)"

# ---------- install ----------
if [ "$MODE" = "install" ]; then
  mkdir -p "$HOME/Applications"
  # Quit the running copy and wait until it's gone, otherwise LaunchServices
  # refuses to open the new one (error -600).
  if pgrep -x Remark >/dev/null; then
    osascript -e 'tell application id "com.ezinnekalu.remark" to quit' >/dev/null 2>&1 || pkill -x Remark || true
    for _ in $(seq 1 50); do pgrep -x Remark >/dev/null || break; sleep 0.1; done
    pkill -9 -x Remark 2>/dev/null || true
    sleep 0.5
  fi
  rm -rf "$HOME/Applications/Remark.app"
  cp -R "$APP" "$HOME/Applications/Remark.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$HOME/Applications/Remark.app" >/dev/null 2>&1 || true
  open "$HOME/Applications/Remark.app" || { sleep 1; open "$HOME/Applications/Remark.app"; }
  echo "Installed to ~/Applications/Remark.app and launched"
  exit 0
fi

[ "$MODE" = "build" ] && exit 0

# ---------- dmg ----------
DMG="build/Remark-$VERSION.dmg"
STAGE="build/dmg-stage"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Remark $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
if [ -n "$SIGN_ID" ]; then codesign --force --sign "$SIGN_ID" "$DMG" 2>/dev/null || true; fi

if [ -n "${REMARK_NOTARY_PROFILE:-}" ] && [[ "$SIGN_ID" == Developer\ ID* ]]; then
  echo "Notarizing…"
  xcrun notarytool submit "$DMG" --keychain-profile "$REMARK_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi
echo "Packaged $DMG"

# ---------- release ----------
if [ "$MODE" = "release" ]; then
  command -v gh >/dev/null || { echo "Install the GitHub CLI: brew install gh"; exit 1; }
  if [ -n "$(git status --porcelain)" ]; then
    echo "Commit your changes first (git status isn't clean)."; exit 1
  fi
  git push origin HEAD
  if gh release view "v$VERSION" >/dev/null 2>&1; then
    gh release upload "v$VERSION" "$DMG" --clobber
  else
    gh release create "v$VERSION" "$DMG" --title "Remark $VERSION" --generate-notes --target "$(git rev-parse HEAD)"
  fi
  echo "Released v$VERSION → $(gh release view "v$VERSION" --json url -q .url)"
fi
