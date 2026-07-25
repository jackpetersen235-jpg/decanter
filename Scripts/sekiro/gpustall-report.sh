#!/bin/bash
# Correlate a gpuprof-run.sh session into a verdict.
# Usage: bash gpustall-report.sh <STAMP>       (the YYYYmmdd-HHMMSS printed by gpuprof-run.sh)
set -uo pipefail

DATA="$HOME/Library/Application Support/Decanter"
STAMP="${1:?usage: gpustall-report.sh <STAMP>}"
LOG="$DATA/gpustall-$STAMP.log"
CSV="$DATA/gpusample-$STAMP.csv"

[ -f "$LOG" ] || { echo "no such log: $LOG" >&2; exit 1; }

echo "=============================================================="
echo " gpustall report — $STAMP"
echo "=============================================================="
echo
echo "--- session ---"
grep -E 'armed on|bound .* class' "$LOG" | sed 's/^/  /'
n_slow=$(grep -c 'SLOW cb#' "$LOG")
echo "  slow command buffers: $n_slow"
[ "$n_slow" = 0 ] && {
  echo
  echo "  No command buffer exceeded the threshold."
  echo "  If stalls DID occur, the render thread was not blocked on GPU execution and the"
  echo "  'one pathological shader' model is wrong — check the sampler CSV instead."
  exit 0
}
echo

echo "--- worst command buffers ---"
# NOTE the '-' in the sched character class. sched is GPUStartTime - kernelEndTime and it goes
# NEGATIVE on exactly the buffers we care about; a [0-9.]+ class silently failed to match, the
# line fell through unparsed, and the report printed the log TIMESTAMP as the duration ("16.0 ms"
# for a 26-second stall). Verified against real data 2026-07-24.
grep 'SLOW cb#' "$LOG" \
  | sed -E 's/.*SLOW (cb#[0-9]+)  gpu=([0-9.]+)ms sched=(-?[0-9.]+)ms  outstanding@commit=(-?[0-9]+) now=(-?[0-9]+)  encoders=([0-9]+)/\2 \1 sched=\3ms depth=\4 enc=\6/' \
  | sort -rn | head -10 | awk '{printf "  %10.1f ms  %s %s %s %s\n", $1, $2, $3, $4, $5}'
echo

echo "--- FIXED DURATION, OR VARIABLE COMPUTATION? ---"
# The single most diagnostic number here. Real GPU work varies with the scene; a timeout does not.
grep 'SLOW cb#' "$LOG" | sed -E 's/.*gpu=([0-9.]+)ms.*/\1/' \
  | awk '{v[n++]=$1; s+=$1; if(mx==""||$1>mx)mx=$1; if(mn==""||$1<mn)mn=$1}
         END {
           if (n < 2) { printf "  only %d stall(s) — need 2+ to judge\n", n; exit }
           mean = s/n; spread = mx-mn; rel = 100*spread/mean
           printf "  %d stalls: mean %.1f ms, min %.1f, max %.1f, spread %.1f ms (%.2f%%)\n",
                  n, mean, mn, mx, spread, rel
           print ""
           if (rel < 2) {
             print "  => FIXED DURATION. Independent stalls agreeing this tightly are not"
             print "     computation — variable scene work cannot reproduce to <2%. This is a"
             print "     TIMEOUT or a fixed-length wait. The pathological-shader model is"
             print "     FALSIFIED; look at synchronisation (fences/events), not shader cost."
           } else {
             print "  => variable duration, consistent with workload-dependent GPU cost."
           }
         }'
echo

echo "--- PRIME SUSPECT: pipelines enriched in slow buffers vs baseline ---"
# Ranked by enrichment, not raw frequency. A pipeline that runs every frame appears in 100% of
# slow buffers AND 100% of normal ones — that is a coincidence, not a cause. The culprit is the
# one that shows up in slow buffers far more often than in normal ones.
awk '
  /SLOW cb#/ { cur = "S"; nslow++;  delete seen; next }
  /BASE cb#/ { cur = "B"; nbase++;  delete seen; next }
  /enc\[/ {
    if (cur == "") next
    for (i = 1; i <= NF; i++) if ($i ~ /^enc\[/) { k = i; break }
    kind = $(k+1); name = $(k+2)
    n = $(k+3); sub(/^n=/, "", n)
    w = $(k+4); sub(/^work=/, "", w)
    kk[name] = kind; nn[name] += n; ww[name] += w
    # count each pipeline at most once per command buffer
    if (!seen[name]) { seen[name] = 1; if (cur == "S") S[name]++; else B[name]++ }
  }
  END {
    if (nslow == 0) exit
    for (p in kk) {
      sr = S[p] / nslow
      br = (nbase > 0) ? B[p] / nbase : 0
      # +0.02 floor keeps a pipeline absent from a small baseline from scoring infinity
      enr = sr / (br + 0.02)
      printf "%.1f\t%.0f%%\t%.0f%%\t%s\t%s\t%d\t%.0f\n", enr, sr*100, br*100, kk[p], p, nn[p], ww[p]
    }
    printf "#\t%d\t%d\n", nslow, nbase > "/dev/stderr"
  }' "$LOG" 2>/tmp/gsr.$$ | sort -rn | head -15 \
  | awk -F'\t' 'BEGIN{printf "  %-6s %-7s %-7s %-8s %-40s %8s %13s\n",
                       "enrich","in slow","in base","kind","pipeline","invokes","total work"}
                {printf "  %-6s %-7s %-7s %-8s %-40s %8s %13s\n", $1, $2, $3, $4, $5, $6, $7}'
read -r _ ns nb < /tmp/gsr.$$ 2>/dev/null || true
rm -f /tmp/gsr.$$
echo "  (from $n_slow slow and ${nb:-0} baseline command buffers)"
[ "${nb:-0}" = 0 ] && echo "  NOTE: no baseline captured — 'enrich' is meaningless, read 'in slow' only."
echo

echo "--- ALIBI CHECK: do the suspects also run in FAST buffers? ---"
# The test that actually settles guilt. A pathological shader is slow whenever it runs. If the
# same pipeline, at the same thread count, also appears in buffers that complete in single-digit
# ms, then its cost is not what makes the slow buffers slow — it is a bystander.
awk '
  /SLOW cb#/ { g=$0; sub(/.*gpu=/,"",g); sub(/ms.*/,"",g); cur="S"; next }
  /BASE cb#/ { g=$0; sub(/.*gpu=/,"",g); sub(/ms.*/,"",g); cur="B"; next }
  /enc\[/ {
    if (cur == "") next
    for (i=1;i<=NF;i++) if ($i ~ /^enc\[/) { k=i; break }
    name=$(k+2)
    if (cur=="B") { bn[name]++; bt[name]+=g; if (bmax[name]==""||g+0>bmax[name]) bmax[name]=g+0 }
    else          { sn[name]++; st[name]+=g }
  }
  END {
    hdr=0
    for (p in sn) {
      if (bn[p] > 0) {
        if (!hdr) { printf "  %-44s %14s %14s\n", "pipeline", "in FAST bufs", "in SLOW bufs"; hdr=1 }
        printf "  %-44s %8.1f ms n=%-3d %8.0f ms\n", substr(p,1,44), bt[p]/bn[p], bn[p], st[p]/sn[p]
      }
    }
    if (!hdr) print "  (no suspect pipeline ever appeared in a fast buffer — no alibi)"
    else {
      print ""
      print "  => Every pipeline listed above has an ALIBI: it runs in milliseconds in normal"
      print "     command buffers and is merely PRESENT in the slow ones. Same shader, same"
      print "     work, ~1000x the time. Shader cost does not explain these stalls."
    }
  }' "$LOG"
echo

echo "--- IS IT ONE FAT ENCODER, OR A BACKLOG? ---"
# A single pathological dispatch stalls with a SHALLOW queue: the render thread submitted it and
# is waiting, nothing else outstanding. A backlog of ordinary work stalls with a DEEP one.
grep 'SLOW cb#' "$LOG" \
  | sed -E 's/.*outstanding@commit=([0-9-]+).*/\1/' \
  | awk '{s+=$1; n++; if($1>mx)mx=$1; if($1<=2)shallow++}
         END {
           if (n==0) exit
           printf "  queue depth at commit: mean %.1f, max %d, over %d stalls\n", s/n, mx, n
           printf "  %d/%d (%.0f%%) had depth <= 2\n", shallow, n, 100*shallow/n
           print ""
           if (shallow*2 >= n) {
             print "  => SHALLOW. Consistent with one pathological encoder. Report premise holds."
           } else {
             print "  => DEEP. The render thread was waiting behind a QUEUE of ordinary work, not"
             print "     one runaway shader. The single-shader premise does not survive this."
           }
         }'
echo

if [ -f "$CSV" ]; then
  echo "--- GPU unit split during blocked samples (state U) ---"
  # Renderer pinned with tiler idle => compute/fragment bound. Both busy => ordinary geometry load.
  awk -F, 'NR>1 && $12 ~ /U/ { d+=$3; r+=$4; t+=$5; n++; if ($6!=""){p+=$6; pn++} }
           NR>1 && $12 ~ /R/ && $3>40 { D+=$3; R+=$4; T+=$5; m++ }
           END {
             if (n == 0) { print "  no blocked samples captured"; exit }
             printf "  blocked  n=%-4d device %3.0f%%  renderer %3.0f%%  tiler %3.0f%%\n", n, d/n, r/n, t/n
             if (m) printf "  active   n=%-4d device %3.0f%%  renderer %3.0f%%  tiler %3.0f%%\n", m, D/m, R/m, T/m
             if (pn) printf "  GPU power state while blocked: %.2f (scale is 0/1 — MaxPowerState=1)\n", p/pn
             print ""
             # Braces are required. Without them the second print of the else-if body runs
             # unconditionally, and the report emitted a dangling "treat the single-shader model
             # as unsupported" line under data that said the exact opposite. Seen 2026-07-24.
             if (r/n > 60 && t/n < 20) {
               print "  => renderer-bound with an idle tiler: fragment or compute work, not geometry."
             } else if (r/n < 10 && t/n < 10 && d/n > 90) {
               print "  => device pinned while BOTH renderer and tiler read idle. That is not a"
               print "     shader executing — treat the single-shader model as unsupported here."
             }
             # NOTE: no conclusion is drawn from the submissions column. Measured 2026-07-22:
             # fSubmissionsSinceLastCheck reads 0 in every sample, blocked AND active, so the
             # delta is always 0. It does not track what its name suggests. An earlier version
             # concluded "no new submissions while blocked" from it — that fired unconditionally
             # and was meaningless. Do not reinstate without validating the field first.
           }' "$CSV"
else
  echo "--- no sampler CSV for this stamp ---"
fi
echo
echo "raw: $LOG"
[ -f "$CSV" ] && echo "     $CSV"
