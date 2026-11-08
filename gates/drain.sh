#!/usr/bin/env bash
# Graceful shutdown gate.
#
# SIGTERM while an invocation is in flight must: finish that invocation, refuse new
# ones with 503, and exit 0 — not kill the process mid-transaction.
set -uo pipefail
cd "$(dirname "$0")/.."

BIN=./zig-out/bin/cellar
PORT=${PORT:-$(( 8600 + ($$ % 200) ))}
DATA=${DATA:-./.draindata.$$}
[ -x "$BIN" ] || { echo "build first: zig build"; exit 1; }

cleanup() { [ -n "${SERVER:-}" ] && kill -9 "$SERVER" 2>/dev/null; rm -rf "$DATA"; }
trap cleanup EXIT

rm -rf "$DATA"
$BIN serve --listen "127.0.0.1:$PORT" --admin-token t --data "$DATA" --shards 1 \
  --deadline-ms 8000 --drain-ms 5000 >/tmp/drain-gate.log 2>&1 &
SERVER=$!
for _ in $(seq 1 50); do
  curl -sf "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break
  sleep 0.1
done

# Start a 1.5 s invocation, then ask the process to stop 0.3 s in.
( curl -s -o /tmp/drain-body -w '%{http_code}' -X POST -d 1500 \
    "http://127.0.0.1:$PORT/c/w/work" > /tmp/drain-code ) &
REQ=$!
sleep 0.3
START=$(date +%s%N)
kill -TERM "$SERVER"
sleep 0.15
DURING=$(curl -s -o /dev/null -w '%{http_code}' -X POST -d hi "http://127.0.0.1:$PORT/c/w/echo")
wait $REQ 2>/dev/null
CODE=$(cat /tmp/drain-code 2>/dev/null || echo 000)
BODY=$(cat /tmp/drain-body 2>/dev/null || echo "")
wait $SERVER 2>/dev/null
RC=$?
ELAPSED=$(( ($(date +%s%N) - START) / 1000000 ))
SERVER=""

echo "  in-flight request   $CODE $BODY (expected 200 done:1500)"
echo "  new request         $DURING (expected 503)"
echo "  exit code           $RC (expected 0)"
echo "  drain took          ${ELAPSED}ms"

FAIL=0
[ "$CODE" = "200" ] || FAIL=1
[ "$BODY" = "done:1500" ] || FAIL=1
[ "$DURING" = "503" ] || FAIL=1
[ "$RC" = "0" ] || FAIL=1
grep -q "draining (1 outstanding)" /tmp/drain-gate.log || { echo "  missing drain log line"; FAIL=1; }
[ "$FAIL" = "0" ] && echo PASS || { echo FAIL; exit 1; }
