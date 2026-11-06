#!/bin/bash
# Run Decanter's pure-logic tests WITHOUT XCTest — for a Mac where `swift test` can't run (only the
# Command Line Tools installed, or Xcode's license not yet accepted). Compiles the chosen test
# classes together with the sources they need and Shim.swift (a minimal XCTest stand-in).
#
#   bash Scripts/test-shim/run-tests.sh                 # every class in DEFAULT_TESTS
#   bash Scripts/test-shim/run-tests.sh GameScannerTests BottleListTests
#
# Tests that need AppModel or a view can't run here; they still need `swift test`. When a test needs
# another source file, add it to SRC.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
H="$REPO/Scripts/test-shim"
W="${TMPDIR:-/tmp}/decanter-test-shim"; rm -rf "${W:?}"; mkdir -p "$W"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"

SRC=(Models/Bottle Models/BottleSettings Models/BottleList Models/BottleSetupState Models/DockMenuEntries
     Models/AutoAddGames Models/UpdateCheck Models/PrefixSharing Support/Paths Support/SekiroGraphicsConfig Support/Quarantine
     Managers/Steam Managers/LaunchWait Managers/EngineDownloadProgress Managers/SteamBootstrapProgress Managers/GameScanner
     Managers/NativeWindow Managers/Uninstaller)
DEFAULT_TESTS=(SteamBootstrapProgressTests UpdateCheckTests AutoAddGamesTests DockMenuEntriesTests EngineDownloadProgressTests BottleSetupStateTests
     BottleListTests GameScannerTests NativeWindowTests SteamLogonTests LaunchWaitTests
     SteamProcessTests UninstallerTests QuarantineTests)
[ $# -eq 0 ] && set -- "${DEFAULT_TESTS[@]}"

FILES=("$H/Shim.swift")
for s in "${SRC[@]}"; do f="$REPO/Sources/Decanter/$s.swift"; [ -f "$f" ] && FILES+=("$f"); done
MAIN="$W/main.swift"; echo "import Foundation" > "$MAIN"
for c in "$@"; do
  t="$REPO/Tests/DecanterTests/$c.swift"
  # XCTest re-exports Foundation, so swap the import rather than dropping it.
  sed -e 's/^import XCTest/import Foundation/' -e '/^@testable import/d' "$t" > "$W/$c.swift"
  FILES+=("$W/$c.swift")
  echo "print(\"$c\")" >> "$MAIN"
  /usr/bin/grep -oE 'func (test[A-Za-z0-9_]+)\(\)( throws)?' "$t" | while read -r _ sig rest; do
    n="${sig%%(*}"
    # A fresh instance per test, and the body runs on the SAME instance setUp ran on.
    if [ -n "${rest:-}" ]; then echo "do { let t = $c(); t.shimRun(\"$n\") { try t.$n() } }" >> "$MAIN"
    else echo "do { let t = $c(); t.shimRun(\"$n\") { t.$n() } }" >> "$MAIN"; fi
  done
done
echo 'print(shimFailures == 0 ? "ALL PASSED" : "\(shimFailures) FAILURE(S)"); exit(shimFailures == 0 ? 0 : 1)' >> "$MAIN"
swiftc -swift-version 5 -o "$W/run" "${FILES[@]}" "$MAIN" 2>&1 | /usr/bin/grep -E "error" || true
[ -x "$W/run" ] || { echo "Compile failed — see errors above."; exit 1; }
"$W/run"
