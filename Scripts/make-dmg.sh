#!/bin/bash
# Package build/TodoApp.app into a drag-to-install DMG.
# Run Scripts/build-app.sh first.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/TodoApp.app"
DMG="$ROOT/build/TodoApp.dmg"
STAGE="$ROOT/build/dmg-stage"

[ -d "$APP" ] || { echo "error: $APP not found — run build-app.sh first"; exit 1; }

echo "==> Stage contents"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> Create DMG"
hdiutil create -volname "Todo + Pomodoro" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null

rm -rf "$STAGE"
echo "==> Done: $DMG"
ls -lh "$DMG"
