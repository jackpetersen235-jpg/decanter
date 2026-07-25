#!/bin/bash
# Watch sekiro.exe and capture thread stacks WHILE it is stalled.
#
# WHY. The profiler says the 26 s is spent with the command buffer open on the CPU side
# (GPUEndTime - kernelEndTime is ~0.2 ms, while GPUStartTime is 26 s earlier), and the process
# sits in state `U` at ~2% CPU — blocked in a syscall, not computing. That means the answer is a
# STACK, not a shader: whatever the render thread is waiting on will be named in it.
#
# Runs alongside gpuprof-direct.sh. Each capture is timestamped so it lines up with the profiler
# log and the 1 Hz sampler.
#
# Usage: bash stallstack.sh [outdir]
set -uo pipefail

OUT="${1:-$HOME/Library/Application Support/Decanter/stallstacks-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
echo "stall stacks -> $OUT"
echo "waiting for sekiro.exe..."

while ! pgrep -f 'sekiro\.exe' >/dev/null 2>&1; do sleep 2; done
PID=$(pgrep -f 'sekiro\.exe' | head -1)
echo "watching pid $PID"

streak=0
captured=0
while kill -0 "$PID" 2>/dev/null; do
  st=$(ps -o state= -p "$PID" 2>/dev/null | tr -d ' ')
  case "$st" in
    *U*) streak=$((streak+1)) ;;
    *)   streak=0 ;;
  esac

  # Two consecutive uninterruptible samples ~= a real stall, not a momentary blip. Capture fast:
  # the window is ~26 s, and `sample` needs a few seconds of it.
  if [ "$streak" -ge 2 ]; then
    captured=$((captured+1))
    f="$OUT/stall-$(date +%H%M%S)-$captured.txt"
    echo "  [$(date +%H:%M:%S)] STALL detected — sampling to $(basename "$f")"
    # -mayDie: do not let a sample failure kill the watcher. 4 s at 1 ms is plenty to see a
    # thread that is parked in one place for 26 s.
    sample "$PID" 4 1 -file "$f" >/dev/null 2>&1 \
      || echo "    (sample failed — see note in this script about permissions)"
    # Do not re-trigger on the same stall.
    while st=$(ps -o state= -p "$PID" 2>/dev/null | tr -d ' '); [ -n "$st" ] && [ "${st#*U}" != "$st" ]; do
      sleep 1
    done
    streak=0
  fi
  sleep 0.5
done

echo "game exited. captured $captured stall stack(s) in $OUT"
