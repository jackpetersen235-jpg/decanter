#!/bin/bash
# Build the framestat frame-pacing probe (see framestat.m). MUST be x86_64 — the wine tree runs
# under Rosetta and dyld refuses a mismatched inserted library. No framework links on purpose:
# it talks to CAMetalLayer through the objc runtime, so injecting it can't change load order.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/libframestat.dylib"
SDK="$(xcrun --show-sdk-path)"

clang -arch x86_64 -dynamiclib -fblocks -O2 -Wall \
      -isysroot "$SDK" -mmacosx-version-min=13.0 \
      -lobjc \
      -o "$OUT" "$HERE/framestat.m"

codesign -f -s - "$OUT"
echo "built $OUT"
file "$OUT"
