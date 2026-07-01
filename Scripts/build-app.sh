#!/bin/bash
# Build TodoApp.app entirely with swiftc (no Xcode, no SPM).
# Compiles the SwiftUI app + the bundled MCP server, assembles the .app bundle,
# writes Info.plist, and ad-hoc code-signs ("Sign to Run Locally").
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="TodoApp"
BUNDLE_ID="com.local.todoapp"
VERSION="1.0.0"
OUT="$ROOT/build"
APP="$OUT/$APP_NAME.app"
CORE=(Sources/TodoCore/*.swift)

echo "==> Clean previous bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/mcp-server"

echo "==> Compile MCP server (todo-mcp)"
swiftc -O "${CORE[@]}" Sources/TodoMCP/*.swift -lsqlite3 \
    -o "$APP/Contents/Resources/mcp-server/todo-mcp"

echo "==> Compile app (TodoApp)"
swiftc -O "${CORE[@]}" Sources/TodoApp/*.swift -lsqlite3 \
    -o "$APP/Contents/MacOS/$APP_NAME"

echo "==> Write Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>Todo + Pomodoro</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> Ad-hoc code-sign (stable local identity)"
codesign --force --deep --sign - --identifier "$BUNDLE_ID" \
    "$APP/Contents/Resources/mcp-server/todo-mcp"
codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP"

echo "==> Verify signature"
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

echo "==> Done: $APP"
echo "    MCP binary: $APP/Contents/Resources/mcp-server/todo-mcp"
