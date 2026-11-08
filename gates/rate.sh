#!/usr/bin/env bash
# Rate-limit gate: 5/s per cell with a burst of 5.
#
# Checks three properties that a limiter is easy to get wrong:
#   * a burst is allowed, then requests are refused with 429 + retry-after;
#   * the bucket is per cell, so one hot cell does not starve another;
#   * tokens refill over time.
set -uo pipefail
cd "$(dirname "$0")/.."

BIN=./zig-out/bin/cellar
PORT=${PORT:-$(( 8700 + ($$ % 200) ))}
DATA=${DATA:-./.ratedata.$$}
[ -x "$BIN" ] || { echo "build first: zig build"; exit 1; }

cleanup() { [ -n "${SERVER:-}" ] && kill "$SERVER" 2>/dev/null; rm -rf "$DATA"; }
trap cleanup EXIT

rm -rf "$DATA"
$BIN serve --listen "127.0.0.1:$PORT" --admin-token t --data "$DATA" --shards 1 \
  --rate-per-s 5 --rate-burst 5 >/tmp/rate-gate.log 2>&1 &
SERVER=$!
for _ in $(seq 1 50); do
  curl -sf "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break
  sleep 0.1
done

OK=0; LIMITED=0; RETRY=0
for _ in $(seq 1 20); do
  read -r CODE HDR < <(curl -s -o /dev/null -D /tmp/rate-hdr -w '%{http_code} ' -X POST -d hi "http://127.0.0.1:$PORT/c/hot/echo"; grep -ci 'retry-after' /tmp/rate-hdr | tr -d '\n')
  [ "$CODE" = "200" ] && OK=$((OK+1))
  [ "$CODE" = "429" ] && { LIMITED=$((LIMITED+1)); [ "$HDR" -gt 0 ] && RETRY=$((RETRY+1)); }
done

echo "  burst: $OK allowed, $LIMITED limited, $RETRY with retry-after (expected ~5 / ~15 / ~15)"

OTHER=$(curl -s -o /dev/null -w '%{http_code}' -X POST -d hi "http://127.0.0.1:$PORT/c/cold/echo")
echo "  other cell while hot one is limited: $OTHER (expected 200)"

sleep 1.1
AFTER=$(curl -s -o /dev/null -w '%{http_code}' -X POST -d hi "http://127.0.0.1:$PORT/c/hot/echo")
echo "  hot cell after 1.1s: $AFTER (expected 200)"

FAIL=0
# Burst 5 plus whatever refills while the loop runs (curl startup costs ~25 ms per
# request, so ~2-4 extra tokens). Assert the shape, not an exact count.
[ "$OK" -ge 3 ] && [ "$OK" -le 12 ] || { echo "  unexpected allowed count"; FAIL=1; }
[ "$LIMITED" -ge 5 ] || { echo "  too few 429s"; FAIL=1; }
[ "$RETRY" = "$LIMITED" ] || { echo "  a 429 came without retry-after"; FAIL=1; }
[ "$OTHER" = "200" ] || FAIL=1
[ "$AFTER" = "200" ] || FAIL=1
[ "$FAIL" = "0" ] && echo PASS || { echo FAIL; exit 1; }
