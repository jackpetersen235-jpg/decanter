#!/bin/bash
#
# Package the built Decanter executable into a double-clickable Decanter.app bundle.
# Usage: Scripts/make_app.sh [debug|release]   (default: release)
#
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "▸ Building ($CONFIG)…"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/Decanter"
APP="$ROOT/build/Decanter.app"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Decanter"
[ -f "$ROOT/Assets/AppIcon.icns" ] && cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
[ -f "$ROOT/Assets/wallpaper.png" ] && cp "$ROOT/Assets/wallpaper.png" "$APP/Contents/Resources/wallpaper.png"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Decanter</string>
    <key>CFBundleDisplayName</key>     <string>Decanter</string>
    <key>CFBundleIdentifier</key>      <string>com.decanter.app</string>
    <key>CFBundleExecutable</key>      <string>Decanter</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.games</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSHumanReadableCopyright</key> <string>Decanter — a Wine bottle manager for gaming.</string>
</dict>
</plist>
PLIST

# Ad-hoc code signature so Gatekeeper lets you open it locally.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || \
    echo "  (codesign skipped — you may need to right-click ▸ Open the first time)"

echo "▸ Done: $APP"
echo "  Launch with:  open \"$APP\""
