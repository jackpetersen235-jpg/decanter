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
# NATIVE_ONLY=1 builds just this Mac's architecture. Universal builds need Xcode's xcbuild, so a
# machine with only the Command Line Tools — or an Xcode whose license isn't accepted yet — can
# still produce a local test build. Never ship a NATIVE_ONLY build to anyone else.
if [ "${NATIVE_ONLY:-0}" = 1 ]; then
  ARCHS=(--arch "$(uname -m)")
  echo "▸ NATIVE_ONLY=1 — building $(uname -m) only (local testing; do not distribute)"
fi

# macOS 27's SDK makes SwiftUI's `@State` a MACRO whose plugin (SwiftUIMacros) ships only with full
# Xcode, so with just the Command Line Tools every build fails: "plugin for module 'SwiftUIMacros'
# not found" (first hit 2026-11-05, after the macOS 27.2 / CLT 27.2 update). The CLT keep the 26.x
# SDKs beside it, and the app targets macOS 14, so fall back to the newest of those. Skipped when
# the toolchain has the plugin (full Xcode) or SDKROOT is already set.
PLUGINS="$(dirname "$(xcrun -f swift)")/../lib/swift/host/plugins"
SDK_MAJOR="$(xcrun --show-sdk-version | cut -d. -f1)"
if [ -z "${SDKROOT:-}" ] && [ "$SDK_MAJOR" -ge 27 ] && ! ls "$PLUGINS" 2>/dev/null | grep -qi swiftui; then
  SDK_DIR="$(dirname "$(xcrun --show-sdk-path)")"
  for candidate in "$SDK_DIR/MacOSX26.5.sdk" "$SDK_DIR/MacOSX26.sdk"; do
    if [ -d "$candidate" ]; then export SDKROOT="$candidate"; break; fi
  done
  [ -n "${SDKROOT:-}" ] && echo "▸ No SwiftUI macro plugin in these tools — building against $(basename "$SDKROOT")"
fi

# Record the SDK actually used. macOS picks an app's look from the SDK version stamped into the
# binary, and Xcode's build system (active once the Xcode license is accepted) stamped `sdk 14.0` —
# the deployment target — which runs the app in macOS 14 COMPATIBILITY MODE: no floating sidebar,
# compact toolbar, old control metrics, whatever the SwiftUI says. The Command Line Tools stamp the
# real SDK; this makes both do so. 14.0 is the deployment target from Package.swift (.macOS(.v14)).
SDK_VERSION="$(xcrun --show-sdk-version)"
LINK_SDK=(-Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$SDK_VERSION")

echo "▸ Building ($CONFIG, universal, SDK $SDK_VERSION)…"
swift build -c "$CONFIG" "${ARCHS[@]}" "${LINK_SDK[@]}"

BIN_DIR="$(swift build -c "$CONFIG" "${ARCHS[@]}" "${LINK_SDK[@]}" --show-bin-path)"
BIN="$BIN_DIR/Decanter"

# Refuse to ship a compatibility-mode binary. See docs/APPLE-GEOMETRY.md ▸ "SDK stamp".
STAMPED="$(otool -l "$BIN" | awk '/LC_BUILD_VERSION/{f=1} f && $1=="sdk"{print $2; exit}')"
if [ "${STAMPED%%.*}" -lt 26 ]; then
  echo "✗ Decanter is stamped sdk $STAMPED — macOS would run it in compatibility mode (old design)." >&2
  exit 1
fi
echo "▸ SDK stamp: $STAMPED"
KEEPALIVE_BIN="$BIN_DIR/GPUKeepalive"
APP="$ROOT/build/Decanter.app"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Decanter"
# Bundled helper for BottleSettings.gpuKeepAlive — see Sources/GPUKeepalive/main.swift. Same
# location Sekiro.app's own hand-tuned launcher uses (Contents/MacOS/gpukeepalive), so
# Paths.bundledGPUKeepalive's lookup matches regardless of which app it's reading.
[ -f "$KEEPALIVE_BIN" ] && cp "$KEEPALIVE_BIN" "$APP/Contents/MacOS/gpukeepalive"
# Release only: drop the debug map, which records the absolute path of every source and object
# file — the builder's home folder included (`/Users/<name>/…`, or a temp dir named after it).
# Found in the shared zip 2026-11-05: 190 such paths in Decanter, 6 in gpukeepalive. Function
# names stay, so a crash report still names the function. The app is re-signed further down.
if [ "$CONFIG" = "release" ]; then
  strip -S "$APP/Contents/MacOS/Decanter" 2>/dev/null
  [ -f "$APP/Contents/MacOS/gpukeepalive" ] && strip -S "$APP/Contents/MacOS/gpukeepalive" 2>/dev/null
fi
[ -f "$ROOT/Assets/AppIcon.icns" ] && cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Patched DXMT (see Assets/DXMT/VERSION.txt). Ships in the bundle so a fresh install can fix the
# 26 s geometry-shader stall without the user building anything.
if [ -d "$ROOT/Assets/DXMT" ]; then
  mkdir -p "$APP/Contents/Resources/DXMT"
  cp "$ROOT/Assets/DXMT/"* "$APP/Contents/Resources/DXMT/"
fi

# "Real game window" (BottleSettings.nativeWindow) — two native pieces, built with plain clang
# because neither belongs in the Swift package:
#   - the window hook is an x86_64 dylib injected into Wine (which runs under Rosetta); dyld
#     refuses a mismatched inserted library, so x86_64 ONLY — see Helpers/WindowHook/.
#   - "Decanter Game.app" is the games-category app a game is launched through so macOS Game
#     Mode can engage (see Helpers/GameHost/). It ships here only as a TEMPLATE: Decanter copies
#     it to Application Support/Decanter and launches it from there, because Game Mode treats an
#     app launched from inside another app's bundle as an extension and never engages for it
#     (Paths.installedGameHost). Signed on its own so the installed copy carries a valid seal.
SDK="$(xcrun --show-sdk-path)"
echo "▸ Building window hook + game host"
mkdir -p "$APP/Contents/Resources/WindowHook"
# A neutral install name: without one, the dylib's own ID is the absolute path it was built at,
# which names the builder's home folder. Nothing looks it up by that name — it is injected by
# file path via DYLD_INSERT_LIBRARIES.
clang -arch x86_64 -dynamiclib -fblocks -O2 -Wall -isysroot "$SDK" -mmacosx-version-min=14.0 \
      -install_name @rpath/libwindowhook.dylib \
      -lobjc -o "$APP/Contents/Resources/WindowHook/libwindowhook.dylib" \
      "$ROOT/Helpers/WindowHook/window-hook.m"
HOST="$APP/Contents/Resources/GameHost/Decanter Game.app"
mkdir -p "$HOST/Contents/MacOS" "$HOST/Contents/Resources"
clang -arch arm64 -arch x86_64 -O2 -Wall -isysroot "$SDK" -mmacosx-version-min=14.0 \
      -o "$HOST/Contents/MacOS/decanter-game-host" "$ROOT/Helpers/GameHost/game-host.c"
cp "$ROOT/Helpers/GameHost/Info.plist" "$HOST/Contents/Info.plist"
[ -f "$ROOT/Assets/AppIcon.icns" ] && cp "$ROOT/Assets/AppIcon.icns" "$HOST/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$HOST" >/dev/null

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
    <key>CFBundleShortVersionString</key> <string>1.2</string>
    <key>CFBundleVersion</key>         <string>36</string>
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
