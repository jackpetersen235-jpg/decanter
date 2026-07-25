#!/bin/bash
# Build the gpustall Metal profiler. MUST be x86_64 — the wine tree (and winemetal.so, which is
# what actually talks to Metal) is x86_64 running under Rosetta, so an arm64 dylib would simply
# be ignored by dyld with no error.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/libgpustall.dylib"
SDK="$(xcrun --show-sdk-path)"

clang -arch x86_64 -dynamiclib -fobjc-arc -O2 -Wall \
      -isysroot "$SDK" \
      -mmacosx-version-min=13.0 \
      -framework Foundation -framework Metal \
      -o "$OUT" "$HERE/gpustall.m"

# Ad-hoc sign: unsigned dylibs are refused on arm64 Macs even for x86_64 targets.
codesign -f -s - "$OUT"

echo "built $OUT"
file "$OUT"
