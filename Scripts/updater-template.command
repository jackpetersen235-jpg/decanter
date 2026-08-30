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

# F25 (bug-sweep): is this actually a Decanter.app, not just something with that name?
# `mdfind`/`[ -d ]` alone found ~/Library/HTTPStorages/com.decanter.app (a directory, not an app)
# and this repo's own build output on the machine this was fixed on — either would have been
# `rm -rf`'d and replaced with the new app if it happened to sort first.
is_decanter() { [ -x "$1/Contents/MacOS/Decanter" ]; }

# Where is the current one? Check the usual places first, then ask Spotlight as a last resort —
# F25: `mdfind | head -1` picks an ARBITRARY match (ordering isn't specified), and on the machine
# this was fixed on it picked this repo's `build/Decanter.app` over the real install. Skip a
# Trash copy, anything under this script's own folder, and anything under a repo's `build/`
# directory — those are never the install a real user is running.
OLD=""
for cand in "/Applications/Decanter.app" "$HOME/Applications/Decanter.app"; do
    if is_decanter "$cand"; then OLD="$cand"; break; fi
done
if [ -z "$OLD" ]; then
    while IFS= read -r cand; do
        case "$cand" in
            *"/.Trash/"*|*"/build/"*|"$PWD"*) continue ;;
        esac
        if is_decanter "$cand"; then OLD="$cand"; break; fi
    done < <(mdfind -name "Decanter.app" 2>/dev/null)
fi

if [ -z "$OLD" ]; then
    say "No existing Decanter found — installing a fresh copy to /Applications."
    OLD="/Applications/Decanter.app"
else
    say "Found the current version at:"
    say "   $OLD"
    # F25: an interactive double-click script can afford one keypress to make a wrong target
    # visible while it's still recoverable, before anything is deleted.
    read -r -p "Press return to continue, or close this window to cancel. " _
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

# F25: the delete's failure used to be silenced and unchecked (`set -e` is deliberately absent
# here — see top of file — so nothing stopped the script on its own). If `rm -rf` failed, `$OLD`
# would still exist as a directory, `mv` would then move `$STAGE` INSIDE it rather than replacing
# it, `mv` would still succeed so `|| fail` never fired, and the final `-x` check below would
# still pass because the OLD bundle was untouched — reporting "✅ Updated" having updated nothing,
# with a nested copy left inside the bundle.
rm -rf "$OLD" || fail "Couldn't remove the old version — is it running, or owned by another user?"
[ -e "$OLD" ] && fail "The old version is still in place; not swapping."
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
