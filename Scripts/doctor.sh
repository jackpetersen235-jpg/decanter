#!/bin/bash
#
# Decanter Doctor — a self-contained health check for a Decanter setup.
#
# Safe to run any time: it only READS state and prints what's wrong + what to do next.
# It needs nothing but the standard macOS tools, so it works whether you have the full repo
# or just the app from a shared zip. Great first step when helping someone (or being helped by
# Claude Code) get Decanter working.
#
#   bash doctor.sh
#
set -uo pipefail

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
warn() { printf "  \033[33m!\033[0m %s\n" "$1"; }
bad()  { printf "  \033[31m✗\033[0m %s\n" "$1"; }
info() { printf "    %s\n" "$1"; }

APPSUP="$HOME/Library/Application Support/Decanter"
ENGINE_BIN="$APPSUP/Wine/Libraries/Wine/bin/wine"
NEXT=()

echo
bold "Decanter Doctor"
echo

# ---------- 1. Machine ----------
bold "System"
if [ "$(uname -m)" = "arm64" ]; then ok "Apple silicon Mac ($(sysctl -n machdep.cpu.brand_string 2>/dev/null))"
else bad "This is an Intel Mac. Decanter targets Apple silicon (M1–M5)."; fi

VER=$(sw_vers -productVersion 2>/dev/null); MAJOR=${VER%%.*}
if [ "${MAJOR:-0}" -ge 14 ]; then ok "macOS $VER"
else bad "macOS $VER — Decanter needs macOS 14 or newer."; fi

if [ -f /Library/Apple/usr/libexec/oah/libRosettaRuntime ]; then ok "Rosetta 2 installed"
else
  bad "Rosetta 2 is NOT installed (needed to run the Windows engine and games)"
  NEXT+=("Install Rosetta:  softwareupdate --install-rosetta --agree-to-license")
fi

FREE=$(df -g "$HOME" 2>/dev/null | awk 'NR==2{print $4}')
if [ "${FREE:-0}" -ge 5 ]; then ok "Free disk: ${FREE} GB"
else warn "Only ${FREE:-?} GB free — games need lots of space"; fi

PWR=$(pmset -g batt 2>/dev/null | grep -o "AC Power\|Battery Power" | head -1)
[ "$PWR" = "AC Power" ] && ok "On AC power (best for gaming)" || warn "On battery — plug in while gaming; macOS throttles performance otherwise"
echo

# ---------- 2. The app ----------
bold "Decanter app"
APP=""
for c in "/Applications/Decanter.app" "$HOME/Applications/Decanter.app" \
         "$(dirname "$0")/Decanter.app" \
         "$HOME/coding/Decanter/build/Decanter.app" "$(dirname "$0")/../build/Decanter.app"; do
  [ -d "$c" ] && { APP="$c"; break; }
done
if [ -n "$APP" ]; then
  ok "Found: $(echo "$APP" | sed "s|$HOME|~|")"
  if xattr "$APP" 2>/dev/null | grep -q com.apple.quarantine; then
    warn "App is quarantined — first open must be right-click ▸ Open (or: xattr -cr \"$APP\")"
  fi
else
  warn "Decanter.app not found in the usual places (that's fine if you haven't installed it yet)"
fi
echo

# ---------- 3. Wine engine ----------
bold "Windows engine (Wine)"
if [ -x "$ENGINE_BIN" ]; then
  V=$("$ENGINE_BIN" --version 2>/dev/null)
  if [ -n "$V" ]; then ok "Decanter engine works: $V"
  else bad "Engine present but won't run — Rosetta likely missing (see System above)"; fi
  [ -f "$APPSUP/Wine/Libraries/DXMT/x64/d3d11.dll" ] && ok "DXMT (fast DirectX→Metal) available" || warn "DXMT DLLs missing from the engine"
  # wine.inf decides whether a NEW bottle can be created at all. Its absence is invisible until
  # someone tries: existing prefixes keep working, and wineboot fails with an unhelpful
  # "could not load kernel32.dll". Builds between 2026-07-18 and 2026-07-30 shipped without it,
  # because the msync overlay replaces share/ wholesale and carries no wine.inf of its own.
  if [ -f "$APPSUP/Wine/Libraries/Wine/share/wine/wine.inf" ]; then
    ok "Engine can create new game spaces (wine.inf present)"
  else
    bad "Engine CANNOT create new game spaces - share/wine/wine.inf is missing"
    NEXT+=("Reinstall the engine: delete \"$APPSUP/Wine\" then press \"Set everything up for me\" again")
  fi
else
  warn "Decanter's own engine isn't installed yet"
  NEXT+=("Open Decanter and press \"Set everything up for me\" — it downloads the engine (~317 MB)")
fi
# other wine builds Decanter can also use
for probe in \
  "Whisky:$HOME/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/bin/wine" \
  "Mythic:$HOME/Library/Application Support/Mythic/Engine/wine/bin/wine64" \
  "CrossOver:$HOME/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine"; do
  name=${probe%%:*}; path=${probe#*:}
  [ -x "$path" ] && info "(also found $name's Wine)"
done
echo

# ---------- 4. Bottles & Steam ----------
bold "Bottles & Steam"
BJ="$APPSUP/bottles.json"
STEAM_OK=0
if [ -f "$BJ" ]; then
  # Display each bottle…
  python3 - "$BJ" <<'PY' 2>/dev/null
import json, os, sys
data = json.load(open(sys.argv[1]))
if not data:
    print("  ! no bottles yet")
for b in data:
    prefix = b.get("url","").replace("file://","").replace("%20"," ").rstrip("/")
    steam = os.path.exists(f"{prefix}/drive_c/Program Files (x86)/Steam/steam.exe")
    mark = "\033[32m✓\033[0m" if b.get("isInitialized") else "\033[33m!\033[0m"
    print(f"  {mark} {b['name']}  —  graphics={b['settings'].get('graphics')}  Steam={'installed' if steam else 'not installed'}")
PY
  # …then compute (separately, cleanly) whether any bottle has Steam.
  STEAM_OK=$(python3 - "$BJ" <<'PY' 2>/dev/null || echo 0
import json, os, sys
d = json.load(open(sys.argv[1]))
print(1 if any(os.path.exists(
    b.get("url","").replace("file://","").replace("%20"," ").rstrip("/")
    + "/drive_c/Program Files (x86)/Steam/steam.exe") for b in d) else 0)
PY
)
else
  warn "No bottles yet"
fi
if [ "${STEAM_OK:-0}" != "1" ] && [ -x "$ENGINE_BIN" ]; then
  NEXT+=("Open Decanter and press \"Set everything up for me\" (creates a game bottle + installs Steam)")
fi
RUN=$(pgrep -f 'steam\.exe' 2>/dev/null | grep -v "$$" | wc -l | tr -d ' ')
[ "${RUN:-0}" -gt 0 ] && info "Steam is currently running" || true
echo

# ---------- 5. Next steps ----------
if [ ${#NEXT[@]} -gt 0 ]; then
  bold "Next steps"
  for n in "${NEXT[@]}"; do printf "  → %s\n" "$n"; done
else
  bold "Looks healthy."
  info "Open Decanter, launch Steam from a bottle, install and play your games."
fi
echo
info "Reference for a helper (or Claude Code): docs/SETUP-WITH-CLAUDE.md"
echo
