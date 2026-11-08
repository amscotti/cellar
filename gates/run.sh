#!/usr/bin/env bash
# Gate runner. Every gate prints PASS/FAIL and writes evidence to gates/evidence/.
# Usage: gates/run.sh [phase]   (phase filters which gates run; default 0)
set -uo pipefail
cd "$(dirname "$0")/.."
PHASE="${1:-0}"
mkdir -p gates/evidence
FAIL=0
ok()   { echo "GATE $1 PASS"; }
bad()  { echo "GATE $1 FAIL: $2"; FAIL=1; }
ZIG="${ZIG:-zig}"

run_g1() {
  if $ZIG build test >gates/evidence/G1.txt 2>&1; then ok G1; else bad G1 "zig build test"; tail -20 gates/evidence/G1.txt; fi
}

run_g2() {
  # ReleaseSafe, because `thresholds.toml` states a 20 MiB ceiling and a debug build is
  # 60 MB: the declared number was measured against nothing. Building release here also
  # means every later gate exercises the binary an operator would run.
  if $ZIG build -Doptimize=ReleaseSafe >gates/evidence/G2-build.txt 2>&1; then
    local out size max
    out=$(./zig-out/bin/cellar --version 2>&1)
    size=$(stat -c%s zig-out/bin/cellar)
    max=$(sed -n 's/^max_binary_bytes = \([0-9]*\)/\1/p' gates/thresholds.toml | head -1)
    printf '%s\nsize_release_bytes=%s\nmax_bytes=%s\n' "$out" "$size" "$max" > gates/evidence/G2.txt
    case "$out" in cellar*) ;; *) bad G2 "version line: $out"; return ;; esac
    if [ -n "${max:-}" ] && [ "$size" -gt "$max" ]; then
      bad G2 "binary size ${size} > ${max}"
    else
      ok G2
    fi
  else
    bad G2 "zig build"; tail -20 gates/evidence/G2-build.txt
  fi
}

run_g15() {
  if ./gates/check-locator.sh >gates/evidence/G15.txt 2>&1; then ok G15; else bad G15 "locator bypass"; cat gates/evidence/G15.txt; fi
}

run_lint() {
  if ./gates/check-no-plan-refs.sh >gates/evidence/L1.txt 2>&1; then ok L1; else bad L1 "plan references in code"; cat gates/evidence/L1.txt; fi
  if ./gates/check-layers.sh >gates/evidence/L2.txt 2>&1; then ok L2; else bad L2 "layer violation"; cat gates/evidence/L2.txt; fi
}

run_g3_shutdown() {
  if ./gates/drain.sh >gates/evidence/G3-drain.txt 2>&1 && python3 gates/drain_queue.py >gates/evidence/G3b-drain-queue.txt 2>&1; then ok G3; else bad G3 "graceful shutdown"; tail -8 gates/evidence/G3-drain.txt gates/evidence/G3b-drain-queue.txt 2>/dev/null; fi
}

run_g4_rate() {
  if ./gates/rate.sh >gates/evidence/G4-rate.txt 2>&1; then ok G4; else bad G4 "rate limit"; tail -8 gates/evidence/G4-rate.txt; fi
}

run_g5_admin() {
  if ./gates/admin.sh >gates/evidence/G5-admin.txt 2>&1; then ok G5; else bad G5 "admin read auth"; tail -8 gates/evidence/G5-admin.txt; fi
}

run_g6_crash() {
  if python3 gates/crash.py >gates/evidence/G6-crash.txt 2>&1; then ok G6; else bad G6 "crash durability"; tail -10 gates/evidence/G6-crash.txt; fi
}

run_g7_snapshot() {
  if python3 gates/snapshot.py >gates/evidence/G7-snapshot.txt 2>&1; then ok G7; else bad G7 "snapshot/restore"; tail -10 gates/evidence/G7-snapshot.txt; fi
}

run_g10_coldstart() {
  if python3 gates/coldstart.py >gates/evidence/G10-coldstart.txt 2>&1; then ok G10; else bad G10 "cold start / relocation"; tail -12 gates/evidence/G10-coldstart.txt; fi
}

run_g9_edges() {
  if python3 gates/http_edges.py >gates/evidence/G9-http-edges.txt 2>&1; then ok G9; else bad G9 "http/vm edges"; tail -12 gates/evidence/G9-http-edges.txt; fi
}

run_g8_gc() {
  if python3 gates/gc.py >gates/evidence/G8-gc.txt 2>&1; then ok G8; else bad G8 "blob gc"; tail -10 gates/evidence/G8-gc.txt; fi
}

run_lint
run_g1
run_g2
run_g3_shutdown
run_g4_rate
run_g5_admin
run_g6_crash
run_g7_snapshot
run_g8_gc
run_g9_edges
run_g10_coldstart
if [ "$PHASE" -ge 3 ]; then run_g15; fi

if [ "$FAIL" -ne 0 ]; then echo "gates: FAILED"; exit 1; fi
echo "gates: all green (phase $PHASE)"
