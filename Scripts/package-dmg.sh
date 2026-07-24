#!/usr/bin/env bash
# Build a simple drag-and-drop DMG for OpenZweb.app
set -euo pipefail

APP=""
VERSION="1.0.0"
OUT_DIR="dist"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "Usage: $0 --app path/to/OpenZweb.app [--version 1.0.0] [--out dist]" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
STAGE="$(mktemp -d)"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

APP_NAME="$(basename "$APP")"
cp -R "$APP" "$STAGE/$APP_NAME"

# Strip quarantine and ad-hoc sign so Gatekeeper is less likely to report
# "OpenZweb is damaged and can't be opened".
xattr -cr "$STAGE/$APP_NAME" 2>/dev/null || true
# Nested binary first
if [ -x "$STAGE/$APP_NAME/Contents/Resources/Core/zju-connect" ]; then
  codesign --force --sign - --timestamp=none \
    "$STAGE/$APP_NAME/Contents/Resources/Core/zju-connect" 2>/dev/null || true
fi
codesign --force --deep --sign - --timestamp=none "$STAGE/$APP_NAME" 2>/dev/null || true
codesign --verify --verbose=1 "$STAGE/$APP_NAME" 2>/dev/null || true

ln -s /Applications "$STAGE/Applications"

DMG_RW="$OUT_DIR/OpenZweb-${VERSION}-rw.dmg"
DMG_FINAL="$OUT_DIR/OpenZweb-${VERSION}-macos-arm64.dmg"
rm -f "$DMG_RW" "$DMG_FINAL"

hdiutil create \
  -volname "OpenZweb" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDRW \
  "$DMG_RW" >/dev/null

hdiutil convert "$DMG_RW" -format UDZO -imagekey zlib-level=9 -o "$DMG_FINAL" >/dev/null
rm -f "$DMG_RW"

# Also clear quarantine on the DMG itself (best effort for local builds)
xattr -cr "$DMG_FINAL" 2>/dev/null || true

echo "Created $DMG_FINAL"
ls -lah "$DMG_FINAL"
