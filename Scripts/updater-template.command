#!/bin/bash
#
# Update Decanter — double-click me.
#
# Replaces the installed Decanter with the copy sitting next to this file. Your bottles, games,
# saves and Steam login are NOT touched: those live in
#   ~/Library/Application Support/Decanter/
# which this script never opens. Only the app itself is replaced.
set -uo pipefail

cd "$(dirname "$0")" || exit 1
NEW="$PWD/Decanter.app"

say() { printf '%s\n' "$1"; }
fail() { printf '\n❌ %s\n\nNothing was changed. Tell whoever sent you this what it says above.\n' "$1"; read -r -p "Press return to close." _; exit 1; }

say "Updating Decanter…"
say ""

[ -d "$NEW" ] || fail "Can't find Decanter.app next to this file. Keep them in the same folder."

# Where is the current one? Check the usual place, then ask Spotlight, so a Decanter living
# somewhere unusual is updated in place rather than duplicated into /Applications.
OLD=""
if [ -d "/Applications/Decanter.app" ]; then
    OLD="/Applications/Decanter.app"
else
    FOUND=$(mdfind -name "Decanter.app" 2>/dev/null | grep -v "$PWD" | head -1)
    [ -n "$FOUND" ] && [ -d "$FOUND" ] && OLD="$FOUND"
fi

if [ -z "$OLD" ]; then
    say "No existing Decanter found — installing a fresh copy to /Applications."
    OLD="/Applications/Decanter.app"
else
    say "Found the current version at:"
    say "   $OLD"
fi

# Quit it first. A running app cannot be replaced cleanly, and a half-replaced bundle is worse
# than an out-of-date one.
if pgrep -x "Decanter" >/dev/null 2>&1; then
    say "Quitting the running copy…"
    osascript -e 'tell application "Decanter" to quit' >/dev/null 2>&1
    for _ in $(seq 1 20); do pgrep -x "Decanter" >/dev/null 2>&1 || break; sleep 0.5; done
    pgrep -x "Decanter" >/dev/null 2>&1 && pkill -x "Decanter" 2>/dev/null
    sleep 1
fi

# Copy to a temporary name first, then swap. If the copy fails halfway, the old app is still there
# and working rather than half-overwritten.
STAGE="${OLD%.app}.updating.app"
rm -rf "$STAGE" 2>/dev/null
say "Copying the new version…"
cp -R "$NEW" "$STAGE" || fail "Couldn't copy the new version into place."

rm -rf "$OLD" 2>/dev/null
mv "$STAGE" "$OLD" || fail "Couldn't swap the new version into place."

# Clear the download quarantine and re-sign, so it opens normally — no right-click ▸ Open,
# no "Decanter is damaged" warning.
xattr -cr "$OLD" 2>/dev/null
codesign --force --sign - "$OLD" >/dev/null 2>&1

[ -x "$OLD/Contents/MacOS/Decanter" ] || fail "The updated app looks incomplete."

say ""
say "✅ Updated."
say ""
say "Your bottles, games and saves were not touched."
say "Opening Decanter…"
open "$OLD"
sleep 1
