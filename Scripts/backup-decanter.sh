#!/bin/bash
# backup-decanter.sh — "only ever moving forward, not backwards".
#
# Creates dated, checksum-verified archives of the two things that are IRREPLACEABLE and
# small, and drops them on the USB (or any destination you pass):
#
#   1. The Decanter project  — all source/docs/scripts/assets + full git history
#                              (excludes .build/, which `swift build` regenerates).
#   2. Saves + tuned config  — the Sekiro save (*.sl2) and the prefix registry (*.reg).
#
# What it deliberately does NOT back up: the ~16 GB Steam/game install and the ~17 GB
# RESTORE snapshots. Those are re-downloadable and won't fit on a small stick anyway.
# If you want those too, use a drive with room and copy the whole
# "~/Library/Application Support/Decanter" folder.
#
# Usage:
#   ./Scripts/backup-decanter.sh                 # -> /Volumes/8gigapdrive/Decanter-backups
#   ./Scripts/backup-decanter.sh /some/other/dir # -> custom destination
#
# Nothing is ever deleted except old *auto-generated* backups beyond KEEP (default 10),
# and only inside the destination's Decanter-backups/ folder.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"          # the Decanter repo root
PROJECT_PARENT="$(dirname "$REPO")"
PROJECT_NAME="$(basename "$REPO")"
BOTTLE="$HOME/Library/Application Support/Decanter/Bottles/Steam-Wine11"
STAMP="$(date +%Y-%m-%d-%H%M%S)"
KEEP=10

USB_DEFAULT="/Volumes/8gigapdrive"
DEST_ROOT="${1:-$USB_DEFAULT}"
DEST="$DEST_ROOT/Decanter-backups"

fail() { echo "✗ $*" >&2; exit 1; }
ok()   { echo "✓ $*"; }

[ -d "$DEST_ROOT" ] || fail "Destination not found: $DEST_ROOT (is the USB plugged in and mounted?)"
mkdir -p "$DEST"

# Keep macOS from sprinkling ._AppleDouble files into the archives on FAT drives.
export COPYFILE_DISABLE=1

verify() {  # $1 = archive path -> writes .sha256 and confirms it reads back identical
  local f="$1" sum
  sum="$(shasum -a 256 "$f" | cut -d' ' -f1)"
  echo "$sum  $(basename "$f")" > "$f.sha256"
  [ "$sum" = "$(shasum -a 256 "$f" | cut -d' ' -f1)" ] || fail "checksum mismatch for $f"
  ok "$(basename "$f")  ($(du -h "$f" | cut -f1))  sha256=${sum:0:12}…"
}

# 1) Project (source + git history), minus the regenerable build cache.
PROJ_ARCHIVE="$DEST/Decanter-project-$STAMP.tar.gz"
( cd "$PROJECT_PARENT" && tar --exclude="$PROJECT_NAME/.build" -czf "$PROJ_ARCHIVE" "$PROJECT_NAME" )
verify "$PROJ_ARCHIVE"

# 2) Saves + tuned prefix config (only if the bottle exists on this machine).
if [ -d "$BOTTLE" ]; then
  SAVE_ARCHIVE="$DEST/Decanter-saves+config-$STAMP.tar.gz"
  ( cd "$BOTTLE" && tar -czf "$SAVE_ARCHIVE" \
      "drive_c/users/$(id -un)/AppData/Roaming/Sekiro" \
      system.reg user.reg userdef.reg 2>/dev/null ) || true
  [ -f "$SAVE_ARCHIVE" ] && verify "$SAVE_ARCHIVE"
else
  echo "· no bottle at $BOTTLE — skipping saves (project still backed up)"
fi

# 3) Prune: keep only the newest KEEP of each kind so a small drive never fills.
prune() {  # $1 = glob prefix
  local kept=0
  ls -t "$DEST"/$1-*.tar.gz 2>/dev/null | while read -r f; do
    kept=$((kept+1))
    if [ "$kept" -gt "$KEEP" ]; then rm -f "$f" "$f.sha256"; echo "· pruned old $(basename "$f")"; fi
  done
}
prune "Decanter-project"
prune "Decanter-saves+config"

# 4) Offsite: if this repo has a git 'origin' remote (e.g. a private GitHub repo), push the
#    committed history too. The archives above already capture uncommitted work-in-progress;
#    this keeps the offsite copy current. No-op / non-fatal if there's no remote or no network.
if git -C "$REPO" remote get-url origin >/dev/null 2>&1; then
  if git -C "$REPO" push origin HEAD >/dev/null 2>&1; then
    ok "pushed to origin ($(git -C "$REPO" remote get-url origin))"
  else
    echo "· could not push to origin (offline or auth not set up) — local + USB backups still done"
  fi
else
  echo "· no git 'origin' remote yet — add one to also back up offsite to GitHub"
fi

echo
ok "Backup complete → $DEST"
df -h "$DEST_ROOT" | tail -1
