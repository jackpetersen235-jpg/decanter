#!/bin/bash
# Build DXMT the way upstream's RELEASE artifacts are built, on this Mac.
#
# The shipped DLLs come from CI's `package` job, which depends on `build-gcc-release-*`. Matching
# that exactly needs two things a current Mac does not have by default, and getting either wrong
# produces a build that links cleanly and then fails at runtime in ways that look like a DXMT bug:
#
#   1. REAL GCC. build-win64.txt asks for `x86_64-w64-mingw32-gcc`. llvm-mingw supplies a program
#      by that name which is actually CLANG, so simply having llvm-mingw on PATH silently builds
#      the clang variant (~15% smaller DLLs). CI installs Homebrew mingw-w64 instead.
#   2. XCODE 16.1. `xcrun metal` follows the host Xcode, and the AIR bitcode version it emits is
#      baked into the DLL. CI pins Xcode 16.1 -> `air64`; Xcode 26 -> `air64_v26`/`air64_v28`.
#      Used via DEVELOPER_DIR, NOT `xcode-select -s`, so it needs no sudo and does not disturb the
#      system-wide Xcode that everything else on this Mac uses.
#
# LLVM's assertions setting is the third trap and is handled below: CI builds LLVM with
# -DLLVM_ENABLE_ASSERTIONS=On. Building with Off produced a winemetal.so ~4 MB light.
#
# Usage:
#   bash dxmt-build.sh stock      # v0.80 as released, plus the metal-target pin
#   bash dxmt-build.sh capped     # the above + d3d11.maxPassesPerCommandBuffer
set -uo pipefail

SRC="$HOME/src/dxmt"
# Xcode 16.1's GUI will NOT launch on macOS 26 -- Apple blocks old Xcode app bundles on newer
# systems. That does not matter: only `xcrun metal` is needed here and it is an ordinary
# command-line binary that runs regardless. So the bundle does not have to be installed, renamed,
# or moved into /Applications; it is used wherever it happens to sit.
XC161=""
for c in "/Applications/Xcode_16.1.app" "$HOME/Downloads/Xcode.app" "$HOME/Downloads/Xcode_16.1.app"; do
  [ -d "$c" ] || continue
  v=$(defaults read "$c/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)
  case "$v" in 16.1*) XC161="$c"; break ;; esac
done
BRANCH="${1:?usage: dxmt-build.sh stock|capped}"

case "$BRANCH" in
  stock)  REF=build-fixes   ;;
  capped) REF=batch-cap     ;;
  fix)    REF=gs-marshal-fix ;;   # index++ AND the overflow guards
  ovf)    REF=overflow-only   ;;   # overflow guards only - no index++
  final)  REF=final-fix       ;;   # index++ + overflow guards + divisor checks  <-- SHIPPING
  *) echo "arg must be stock|capped|fix|ovf|final" >&2; exit 2 ;;
esac

# ---- prerequisites, checked loudly rather than silently substituted ------------------
GCC=/opt/homebrew/bin/x86_64-w64-mingw32-gcc
if [ ! -x "$GCC" ]; then
  echo "MISSING: Homebrew mingw-w64 (real GCC)." >&2
  echo "  brew install mingw-w64" >&2
  exit 1
fi
if [ -z "$XC161" ]; then
  echo "MISSING: an Xcode 16.1 bundle (looked in /Applications and ~/Downloads)." >&2
  echo "  developer.apple.com/download/all -> 'Xcode 16.1' -> expand the .xip" >&2
  echo "  It does NOT need to launch or be installed - only its metal compiler is used." >&2
  exit 1
fi

# Scope Xcode 16.1 to the METAL steps ONLY, via an xcrun shim rather than a global DEVELOPER_DIR.
#
# Exporting DEVELOPER_DIR=Xcode16.1 also swaps the C++ compiler used for the native (darwin) side,
# and Xcode 16.1's clang cannot compile the LLVM 15 headers against the macOS 26 CommandLineTools
# libc++ that meson pairs it with -- it dies with 16 errors inside llvm/IR/Attributes.h. The native
# side must keep using the current toolchain, which builds it cleanly.
#
# meson invokes xcrun for exactly two things (metalir_generator and metallib_generator in
# meson.build), so shimming xcrun targets the metal compiler and nothing else.
SHIM="$(mktemp -d)"
cat > "$SHIM/xcrun" <<SHIMEOF
#!/bin/bash
exec env DEVELOPER_DIR="$XC161/Contents/Developer" /usr/bin/xcrun "\$@"
SHIMEOF
chmod +x "$SHIM/xcrun"
trap 'rm -rf "$SHIM"' EXIT

# PATH must NOT contain llvm-mingw, or x86_64-w64-mingw32-gcc resolves to clang. Homebrew first.
export PATH="$SHIM:/opt/homebrew/bin:$HOME/Library/Python/3.14/bin:/usr/bin:/bin:/usr/sbin:/sbin"

echo "=============================================="
echo " building: $BRANCH ($REF)"
echo " metal   : $(xcrun metal --version 2>&1 | head -1)"
echo " cc      : $($GCC --version | head -1)"
echo "=============================================="

cd "$SRC" || exit 1
git checkout -q "$REF" || exit 1

OUT="$SRC/install-$BRANCH"
rm -rf "build-$BRANCH" "$OUT"
# -Dwine_builtin_dll=false IS THE ONE THAT MATTERS AND IT IS NOT CI'S DEFAULT.
#
# With the default (true) every DLL gets a "Wine builtin DLL" marker in its DOS stub. The game's
# DllOverrides ask for NATIVE d3d11, wine refuses a builtin-marked file for that role, and quietly
# falls back to its own d3d11 -> wined3d -> OpenGL. The game still starts, so nothing looks broken;
# it just renders through the slowest path available and eventually page-faults.
#
# `wine --debugmsg +loaddll` is what exposes it -- official loads `d3d11.dll native`, a default
# build loads `d3d11.dll builtin`. That one word is the entire difference, and it cost a play
# session on 2026-07-27 before anyone thought to look.
meson setup --cross-file build-win64.txt -Denable_nvapi=true -Denable_nvngx=true \
  -Dwine_builtin_dll=false \
  -Dnative_llvm_path=toolchains/llvm-darwin -Dwine_install_path=toolchains/wine \
  "build-$BRANCH" --buildtype release --prefix "$OUT" --strip || exit 1
meson compile -C "build-$BRANCH" || exit 1
meson install -C "build-$BRANCH" || exit 1

echo
echo "=== artifact check (official reference in brackets) ==="
printf '  winemetal.so  %9d   [31805040]\n' "$(stat -f%z "$OUT/x86_64-unix/winemetal.so")"
printf '  d3d11.dll     %9d   [ 5350886]\n' "$(stat -f%z "$OUT/system32/d3d11.dll")"
echo -n "  AIR target    "
strings "$OUT/system32/d3d11.dll" | grep -oE "air64[_a-z0-9]*-apple-macosx?[0-9.]+" | sort -u | tr '\n' ' '
echo "  [air64-apple-macosx15.0.0]"
echo
echo "install with:  bash $(dirname "$0")/dxmt-swap.sh install $OUT"
