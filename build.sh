#!/bin/bash
# Build Remark.app.   ./build.sh          → build/Remark.app
#                      ./build.sh install  → also copy to ~/Applications and launch
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/Remark.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/Remark" "$APP/Contents/MacOS/Remark"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"

# Signing: set REMARK_SIGN_ID to a "Apple Development: …" identity to keep
# macOS permissions across rebuilds. Falls back to ad-hoc signing.
SIGN_ID="${REMARK_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
  SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/' || true)
fi
if [ -n "$SIGN_ID" ]; then
  echo "Signing with: $SIGN_ID"
  codesign --force --deep --sign "$SIGN_ID" "$APP"
else
  echo "Signing ad-hoc (Screen Recording permission may need re-granting after each rebuild)"
  codesign --force --deep --sign - "$APP"
fi

echo "Built $APP"

if [ "${1:-}" = "install" ]; then
  mkdir -p "$HOME/Applications"
  pkill -x Remark 2>/dev/null || true
  rm -rf "$HOME/Applications/Remark.app"
  cp -R "$APP" "$HOME/Applications/Remark.app"
  open "$HOME/Applications/Remark.app"
  echo "Installed to ~/Applications/Remark.app and launched"
fi
