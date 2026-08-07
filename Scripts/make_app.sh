#!/bin/bash
#
# Package the built Decanter executable into a double-clickable Decanter.app bundle.
# Usage: Scripts/make_app.sh [debug|release]   (default: release)
#
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Build for BOTH architectures. This is NOT the fix for the "bounces in the Dock" report — that
# was a stuck first-launch Gatekeeper check, cleared by restarting. But an arm64-only binary
# genuinely cannot launch on an Intel Mac, and this app gets passed around, so universal removes a
# whole failure mode for about 1.5 MB.
ARCHS=(--arch arm64 --arch x86_64)

echo "▸ Building ($CONFIG, universal)…"
swift build -c "$CONFIG" "${ARCHS[@]}"

BIN_DIR="$(swift build -c "$CONFIG" "${ARCHS[@]}" --show-bin-path)"
BIN="$BIN_DIR/Decanter"
APP="$ROOT/build/Decanter.app"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Decanter"
[ -f "$ROOT/Assets/AppIcon.icns" ] && cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Patched DXMT (see Assets/DXMT/VERSION.txt). Ships in the bundle so a fresh install can fix the
# 26 s geometry-shader stall without the user building anything.
if [ -d "$ROOT/Assets/DXMT" ]; then
  mkdir -p "$APP/Contents/Resources/DXMT"
  cp "$ROOT/Assets/DXMT/"* "$APP/Contents/Resources/DXMT/"
fi

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
