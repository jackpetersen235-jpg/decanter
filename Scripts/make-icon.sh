#!/bin/bash
# Rebuilds Assets/AppIcon.icns from the wizard art in Assets/icon-1024.png.
# make-icon.swift explains the grid and why the tile has to be in the file (macOS 15 and earlier
# show an icon exactly as drawn). make_app.sh copies the result into the app and the game host.
#
#   bash Scripts/make-icon.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Assets/icon-1024.png"
OUT="$ROOT/Assets/AppIcon.icns"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/decanter-icon.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

[ -f "$SRC" ] || { echo "missing source art: $SRC" >&2; exit 1; }

# A compiled binary, not `swift file.swift`: the interpreter is far slower on the pixel scan.
env -u DEVELOPER_DIR swiftc -O "$ROOT/Scripts/make-icon.swift" -o "$WORK/make-icon"
"$WORK/make-icon" "$SRC" "$WORK/icon-1024.png"

SET="$WORK/AppIcon.iconset"
mkdir "$SET"
for size in 16 32 128 256 512; do
  # `-s format png` every time: without it sips can write JPEG data into a .png name, and
  # iconutil then fails with "Failed to generate ICNS" (see CLAUDE.md ▸ Gotchas).
  sips -s format png -z "$size" "$size" "$WORK/icon-1024.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -s format png -z "$double" "$double" "$WORK/icon-1024.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns -o "$OUT" "$SET"
echo "wrote $OUT"
