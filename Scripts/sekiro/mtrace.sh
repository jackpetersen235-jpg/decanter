#!/bin/bash
# Metal System Trace capture — Apple's own per-command-buffer GPU instrumentation.
#
# WHY THIS SUPERSEDES OUR OWN PROFILER. docs/DXMT-STALL-REPORT.md PART 1 recorded the isolation as
# blocked because Metal System Trace needs full Xcode, which this machine did not have. Xcode 26.6
# was installed 2026-07-25, so `xctrace` is now available and VERIFIED working (records + exports
# parseable XML).
#
# It matters because it is independent of BOTH prior instruments:
#   - our gpustall.m `gpuMS` figure produced FALSE POSITIVES (logged 26 s buffers during a session
#     where the user counted zero long pauses), so counts derived from it are contaminated
#   - DXMT's own HUD counters are compiled out of release builds (`#ifndef DXMT_DEBUG return;`)
# xctrace is Apple's, measures the driver directly, and needs no custom DXMT.
#
# It also records a `Hangs` instrument (threshold: >100 ms unresponsiveness), which is the closest
# thing yet to measuring what the USER actually perceives rather than what a counter reports.
#
# Usage:
#   bash mtrace.sh            # attach to a running sekiro.exe, record until Ctrl-C or --limit
#   bash mtrace.sh --limit 300s
set -uo pipefail

LIMIT="${2:-}"
[ "${1:-}" = "--limit" ] && LIMIT="$2"
D="$HOME/Library/Application Support/Decanter"
OUT="$D/mtrace-$(date +%Y%m%d-%H%M%S).trace"

PID=$(pgrep -f 'sekiro\.exe' | head -1)
if [ -z "$PID" ]; then
  echo "sekiro.exe is not running — start the game first, then run this." >&2
  exit 1
fi

echo "=============================================="
echo " Metal System Trace — attaching to pid $PID"
echo " output: $OUT"
[ -n "$LIMIT" ] && echo " time limit: $LIMIT" || echo " no time limit — Ctrl-C to stop"
echo "=============================================="
echo
echo "PLAY NORMALLY. Say when you feel a pause; the trace timeline is what we correlate against."
echo

ARGS=(record --template 'Metal System Trace' --attach "$PID" --output "$OUT")
[ -n "$LIMIT" ] && ARGS+=(--time-limit "$LIMIT")

# NOTE: traces are large (~69 MB for 8 s of an idle process; a busy game will be far more).
# Watch disk if recording long sessions.
xcrun xctrace "${ARGS[@]}"

echo
echo "trace saved: $OUT  ($(du -sh "$OUT" 2>/dev/null | cut -f1))"
echo "export a table with:"
echo "  xcrun xctrace export --input '$OUT' --toc"
