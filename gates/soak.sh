#!/usr/bin/env bash
# Soak gate: pushes real invocations through the HTTP surface and checks that the
# server's counter, the client's count, and the rows actually committed to each
# cell's SQLite database all agree.
#
# The last check is the interesting one: every increment happens inside its
# cell's own transaction, so the sum across cell databases is an independent
# witness to the server's own number.
#
#   gates/soak.sh [requests] [cells] [parallelism]
set -euo pipefail

REQ=${1:-2000}
CELLS=${2:-20}
PAR=${3:-8}
# Unique by default: two gate runs at once used to collide on the same port and
# delete each other's data dir, which looked exactly like a server bug. Env vars
# still override.
PORT=${PORT:-$(( 8200 + ($$ % 300) ))}
BIN=./zig-out/bin/cellar
DATA=${DATA:-./.soakdata.$$}
EVID=gates/evidence
mkdir -p "$EVID"

log() { printf '%s\n' "$*" | tee -a "$LOG"; }
LOG=${LOG:-$EVID/soak.$$.log}
: > "$LOG"

log "soak: $REQ requests across $CELLS cells, parallelism $PAR"

rm -rf "$DATA"
$BIN serve --listen "127.0.0.1:$PORT" --admin-token soak \
  --data "$DATA" --shards 4 >/tmp/soak-server.log 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true; rm -rf "$DATA"' EXIT

for _ in $(seq 1 50); do
  curl -sf "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break
  sleep 0.1
done

cat > /tmp/soak-mod.lua <<'LUA'
local M = {}
function M.incr(_b)
  db.exec("create table if not exists counters (id integer primary key, n integer not null default 0)")
  db.exec("insert into counters (id, n) values (1, 1) on conflict(id) do update set n = n + 1")
  return tostring(db.value("select n from counters where id = 1"))
end
function M.echo(b) return b end
return M
LUA

# Deploy must be *verified*, not assumed. A body that fails to deploy leaves the
# cell running the built-in fixture, whose `incr` is a Lua counter, not a
# database write — so every call still succeeds and nothing lands on disk. That
# is exactly how an earlier version of this gate "passed" while writing nothing.
for i in $(seq 1 "$CELLS"); do
  OUT=$(curl -s -X POST --data-binary @/tmp/soak-mod.lua -H 'x-cellar-token: soak' \
    "http://127.0.0.1:$PORT/admin/deploy?cell=soak-$i")
  case "$OUT" in
    *'"ok":true'*) ;;
    *) log "FAIL: deploy to soak-$i rejected: $OUT"; exit 1 ;;
  esac
done
log "  deployed      $CELLS cells"

START=$(date +%s%N)
seq 1 "$REQ" | xargs -P "$PAR" -I{} sh -c '
  cell=$(( ({} % '"$CELLS"') + 1 ))
  curl -sf -X POST -d x "http://127.0.0.1:'"$PORT"'/c/soak-$cell/incr" -o /dev/null || echo FAIL
' > /tmp/soak-out.txt 2>&1
END=$(date +%s%N)

FAILS=$(grep -c FAIL /tmp/soak-out.txt || true)
ELAPSED_MS=$(( (END - START) / 1000000 ))
RPS=$(( REQ * 1000 / (ELAPSED_MS == 0 ? 1 : ELAPSED_MS) ))

HEALTH=$(curl -sf "http://127.0.0.1:$PORT/healthz")
INV=$(printf '%s' "$HEALTH" | sed -n 's/.*"invocations":\([0-9]*\).*/\1/p')
ERRS=$(printf '%s' "$HEALTH" | sed -n 's/.*"errors":\([0-9]*\).*/\1/p')
RESIDENT=$(printf '%s' "$HEALTH" | sed -n 's/.*"resident":\([0-9]*\).*/\1/p')

log "  elapsed       ${ELAPSED_MS} ms  (~${RPS} req/s at $PAR parallel)"
log "  client fails  $FAILS"
log "  invocations   $INV (expected $REQ)"
log "  errors        $ERRS"
log "  resident      $RESIDENT of $CELLS cells"
if kill -0 "$SERVER" 2>/dev/null; then log "  server alive  yes"; else log "  server alive  NO"; fi

# Read every cell database on disk. There is no sqlite3 CLI on this host, so use
# python3; a missing or unreadable database is a failure, not a zero.
SUM=$(python3 - "$DATA" "$CELLS" <<'PY'
import hashlib, os, sqlite3, sys
data, cells = sys.argv[1], int(sys.argv[2])
total = 0
bad = 0
for i in range(1, cells + 1):
    h = hashlib.sha256(f"soak-{i}".encode()).hexdigest()
    p = os.path.join(data, "cells", h, "db.sqlite")
    try:
        c = sqlite3.connect(f"file:{p}?mode=ro", uri=True)
        total += c.execute("select n from counters where id = 1").fetchone()[0]
        c.close()
    except Exception:
        bad += 1
print(f"{total} {bad}")
PY
)
ROWS=${SUM%% *}
BAD=${SUM##* }
log "  rows counted  $ROWS across $CELLS cell databases ($BAD unreadable)"

kill $SERVER 2>/dev/null || true
trap - EXIT
rm -rf "$DATA"
sleep 0.2

[ "$FAILS" -eq 0 ] || { log "FAIL: $FAILS client failures"; exit 1; }
[ "$INV" = "$REQ" ] || { log "FAIL: server counted $INV of $REQ"; exit 1; }
[ "$ERRS" = "0" ] || { log "FAIL: $ERRS guest errors"; exit 1; }
[ "$BAD" -eq 0 ] || { log "FAIL: $BAD unreadable cell databases"; exit 1; }
[ "$ROWS" = "$REQ" ] || { log "FAIL: cell rows sum to $ROWS, expected $REQ"; exit 1; }
log "PASS"
