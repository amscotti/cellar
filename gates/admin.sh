#!/usr/bin/env bash
# Admin-read gate: reads are open on loopback and gated everywhere else, with the
# `?token=` unlock still working (the dashboard cannot send a header before it has a
# cookie).
set -uo pipefail
cd "$(dirname "$0")/.."

BIN=./zig-out/bin/cellar
[ -x "$BIN" ] || { echo "build first: zig build"; exit 1; }
P1=$(( 8800 + ($$ % 90) ))
P2=$(( P1 + 90 ))
D1=./.admintest.$$; D2=./.admintest2.$$
cleanup() { [ -n "${S1:-}" ] && kill "$S1" 2>/dev/null; [ -n "${S2:-}" ] && kill "$S2" 2>/dev/null; rm -rf "$D1" "$D2"; }
trap cleanup EXIT

rm -rf "$D1" "$D2"
$BIN serve --listen "0.0.0.0:$P1" --admin-token tok --data "$D1" >/tmp/admin-gate.log 2>&1 &
S1=$!
for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:$P1/healthz" >/dev/null 2>&1 && break; sleep 0.1; done

C_NONE=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$P1/admin")
C_CELLS=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$P1/admin/cells")
C_UNLOCK=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$P1/admin?token=tok")
C_WRONG=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$P1/admin?token=nope")
curl -s -c /tmp/admin-gate.jar "http://127.0.0.1:$P1/admin?token=tok" -o /dev/null
C_COOKIE=$(curl -s -o /dev/null -w '%{http_code}' -b /tmp/admin-gate.jar "http://127.0.0.1:$P1/admin")
C_HEALTH=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$P1/healthz")

echo "  off-loopback: /admin=$C_NONE /admin/cells=$C_CELLS (expect 401 401)"
echo "  unlock: ?token=$C_UNLOCK (expect 303), wrong=$C_WRONG (expect 401), cookie=$C_COOKIE (expect 200)"
echo "  /healthz=$C_HEALTH (expect 200)"

$BIN serve --listen "0.0.0.0:$P2" --admin-token tok --admin-open 1 --data "$D2" >/tmp/admin-gate2.log 2>&1 &
S2=$!
for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:$P2/healthz" >/dev/null 2>&1 && break; sleep 0.1; done
C_OPEN=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$P2/admin")
echo "  --admin-open 1: /admin=$C_OPEN (expect 200)"

FAIL=0
[ "$C_NONE" = "401" ] || FAIL=1
[ "$C_CELLS" = "401" ] || FAIL=1
[ "$C_UNLOCK" = "303" ] || FAIL=1
[ "$C_WRONG" = "401" ] || FAIL=1
[ "$C_COOKIE" = "200" ] || FAIL=1
[ "$C_HEALTH" = "200" ] || FAIL=1
[ "$C_OPEN" = "200" ] || FAIL=1
[ "$FAIL" = "0" ] && echo PASS || { echo FAIL; exit 1; }
