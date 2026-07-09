#!/bin/bash
# Build QuestBits.app entirely with swiftc (no Xcode, no SPM).
# Compiles the SwiftUI app + the bundled MCP server, assembles the .app bundle,
# writes Info.plist, and ad-hoc code-signs ("Sign to Run Locally").
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Flavor: CI builds (and FLAVOR=prod) produce the production "QuestBits" app.
# Everything else is a "QuestBits Dev" app with its own bundle id, its own
# database (~/Library/Application Support/TodoAppDev/), and its own MCP
# registration key (todo-dev) — so trying new features never touches prod data.
if [[ "${GITHUB_ACTIONS:-}" == "true" || "${FLAVOR:-}" == "prod" ]]; then
    APP_NAME="QuestBits"
    BUNDLE_ID="com.local.todoapp"
    DEV_DEFINE=""
else
    APP_NAME="QuestBits Dev"
    BUNDLE_ID="com.local.todoapp.dev"
    DEV_DEFINE="-D DEV_BUILD"
fi
# Version: CI passes the git tag via $VERSION. Local builds default to the
# latest tag + commits-since + short hash (e.g. 1.2.1-3-g65a2000) so the
# footer shows where the build actually came from, never a stale 1.0.0.
VERSION="${VERSION:-$(git -C "$ROOT" describe --tags --always 2>/dev/null | sed 's/^v//' || echo 0.0.0)}"
OUT="$ROOT/build"
APP="$OUT/$APP_NAME.app"
CORE=(Sources/TodoCore/*.swift)

# Sparkle auto-update framework (linked into the app only, not the MCP server).
SPARKLE_VERSION="2.6.4"
SPARKLE_DIR="$ROOT/vendor/Sparkle"
SPARKLE_FRAMEWORK="$SPARKLE_DIR/Sparkle.framework"

ensure_sparkle() {
    if [[ -d "$SPARKLE_FRAMEWORK" ]]; then return 0; fi
    echo "==> Downloading Sparkle $SPARKLE_VERSION"
    mkdir -p "$ROOT/vendor"
    local tarball="$ROOT/vendor/Sparkle-$SPARKLE_VERSION.tar.xz"
    curl -L -s -o "$tarball" \
        "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
    mkdir -p "$SPARKLE_DIR"
    tar -xJf "$tarball" -C "$SPARKLE_DIR"
    rm "$tarball"
}
ensure_sparkle

# Sparkle auto-checks are compiled on only for CI/tagged builds so a local dev
# bundle (version 1.0.0) never nags about — or replaces itself with — the
# published release. Manual "Check for Updates…" still works in dev builds.
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    SU_AUTO_CHECKS="true"
else
    SU_AUTO_CHECKS="false"
fi

echo "==> Clean previous bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/mcp-server" "$APP/Contents/Frameworks"

echo "==> Compile MCP server (todo-mcp)"
# $DEV_DEFINE is intentionally unquoted: empty for prod, two words for dev.
swiftc -O $DEV_DEFINE "${CORE[@]}" Sources/TodoMCP/*.swift -lsqlite3 \
    -o "$APP/Contents/Resources/mcp-server/todo-mcp"

echo "==> Compile app ($APP_NAME)"
swiftc -O $DEV_DEFINE "${CORE[@]}" Sources/TodoApp/*.swift -lsqlite3 \
    -F "$SPARKLE_DIR" -framework Sparkle \
    -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
    -o "$APP/Contents/MacOS/$APP_NAME"

echo "==> Embed Sparkle.framework"
# Preserve the framework's nested XPC services (Downloader.xpc, Installer.xpc).
cp -R "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"

echo "==> Bundle fonts (Alegreya + Quicksand, OFL-licensed)"
# Registered automatically at launch via ATSApplicationFontsPath in Info.plist.
mkdir -p "$APP/Contents/Resources/Fonts"
cp "$ROOT/Resources/Fonts/"*.ttf "$ROOT/Resources/Fonts/"OFL-*.txt \
    "$APP/Contents/Resources/Fonts/"

echo "==> Bundle icons (Lucide ISC + Tabler MIT, license texts included)"
mkdir -p "$APP/Contents/Resources/Icons"
cp "$ROOT/Resources/Icons/"*.svg "$ROOT/Resources/Icons/"LICENSE-*.txt \
    "$APP/Contents/Resources/Icons/"

echo "==> Bundle app icon"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "==> Bundle frames + textures (Kenney / ambientCG, CC0)"
mkdir -p "$APP/Contents/Resources/Frames" "$APP/Contents/Resources/Textures"
cp "$ROOT/Resources/Frames/"* "$APP/Contents/Resources/Frames/"
cp "$ROOT/Resources/Textures/"* "$APP/Contents/Resources/Textures/"

echo "==> Write Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>ATSApplicationFontsPath</key><string>Fonts</string>
    <key>SUFeedURL</key><string>https://raw.githubusercontent.com/90n9/quest-bits-releases/main/appcast.xml</string>
    <key>SUPublicEDKey</key><string>cYcjCtkaa77+ITn9yilFD2oMc8oDKXDcmsP0rYpeLzM=</string>
    <key>SUEnableAutomaticChecks</key><$SU_AUTO_CHECKS/>
    <key>SUScheduledCheckInterval</key><integer>3600</integer>
    <key>SUEnableInstallerLauncherService</key><true/>
</dict>
</plist>
PLIST

echo "==> Ad-hoc code-sign (inside-out: Sparkle helpers, framework, binaries, app)"
# Sparkle's nested helpers must be signed before the framework, and the
# framework before the outer app — the outer signature seals everything below.
SPARKLE_IN_APP="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_INNER="$SPARKLE_IN_APP/Versions/B"
for path in \
    "$SPARKLE_INNER/Sparkle" \
    "$SPARKLE_INNER/Autoupdate" \
    "$SPARKLE_INNER/Updater.app" \
    "$SPARKLE_INNER/XPCServices/Downloader.xpc" \
    "$SPARKLE_INNER/XPCServices/Installer.xpc"
do
    [[ -e "$path" ]] && codesign --force --sign - "$path"
done
codesign --force --sign - "$SPARKLE_IN_APP"
codesign --force --sign - --identifier "$BUNDLE_ID" \
    "$APP/Contents/Resources/mcp-server/todo-mcp"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

echo "==> Verify signature"
codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

echo "==> Done: $APP"
echo "    MCP binary: $APP/Contents/Resources/mcp-server/todo-mcp"
