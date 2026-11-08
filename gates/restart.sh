#!/usr/bin/env bash
# Durability gate: a deployed module and its cell's rows must survive a full
# process restart.
#
# This is the property the whole design exists for, and it was broken until it
# was tested: the runtime kept the deployed module in memory, so a restart
# silently rehydrated the cell with the built-in fixture (which has a `count`
# function that queries a table that does not exist — so it looked like a SQL
# bug rather than a lost deployment).
# NOTE: this runs ./zig-out/bin/cellar. `zig build test` does NOT refresh that
# artifact — run `zig build` first, or the gate will happily test yesterday's
# binary (which cost twenty minutes once).
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=./zig-out/bin/cellar
DATA=${DATA:-./.restartdata.$$}
PORT=${PORT:-$(( 8500 + ($$ % 200) ))}
rm -rf "$DATA"

cat > /tmp/restart-mod.lua <<'LUA'
local M = {}
function M.join(body)
  db.exec("create table if not exists members (id integer primary key, name text)")
  db.exec("insert into members (name) values (?)", body)
  return tostring(db.value("select count(*) from members"))
end
function M.count(_) return tostring(db.value("select count(*) from members")) end
function M.only_in_deployed(_) return "deployed" end
return M
LUA

start() {
  $BIN serve --listen "127.0.0.1:$PORT" --admin-token t --data "$DATA" >/tmp/restart.log 2>&1 &
  echo $!
  for _ in $(seq 1 50); do
    curl -sf "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

P1=$(start)
DEPLOY=$(curl -s -X POST --data-binary @/tmp/restart-mod.lua -H 'x-cellar-token: t' \
  "http://127.0.0.1:$PORT/admin/deploy?cell=durable")
case "$DEPLOY" in *'"ok":true'*) ;; *) echo "FAIL: deploy rejected: $DEPLOY"; kill $P1; exit 1 ;; esac
curl -s -X POST -d ada "http://127.0.0.1:$PORT/c/durable/join" >/dev/null
curl -s -X POST -d bob "http://127.0.0.1:$PORT/c/durable/join" >/dev/null
kill $P1; sleep 0.4

P2=$(start)
AFTER=$(curl -s -X POST -d x "http://127.0.0.1:$PORT/c/durable/count")
MODULE=$(curl -s -X POST -d x "http://127.0.0.1:$PORT/c/durable/only_in_deployed")
kill $P2 2>/dev/null || true

echo "  rows after restart:   $AFTER (expected 2)"
echo "  deployed-only fn:     $MODULE (expected deployed)"

# A cell's database is that tenant's data: the directory must not be world-readable.
CELLDIR=$(find "$DATA/cells" -maxdepth 1 -mindepth 1 -type d | head -1)
MODE=$(stat -c '%a' "$CELLDIR" 2>/dev/null || echo "?")
echo "  cell dir mode:        $MODE (expected 700)"

# ADR-0007: a cell directory is self-describing, so losing the control plane must
# not lose the deployment. Delete state.db and ask again.
sleep 0.3
rm -f "$DATA/state.db" "$DATA/state.db-wal" "$DATA/state.db-shm"
P3=$(start)
FROM_META=$(curl -s -X POST -d x "http://127.0.0.1:$PORT/c/durable/only_in_deployed")
ROWS_META=$(curl -s -X POST -d x "http://127.0.0.1:$PORT/c/durable/count")
kill $P3 2>/dev/null || true
echo "  after state.db loss:  module=$FROM_META rows=$ROWS_META (expected deployed / 2)"

[ "$AFTER" = "2" ] || { echo "FAIL: rows did not survive restart"; exit 1; }
[ "$MODULE" = "deployed" ] || { echo "FAIL: deployed module not restored (cell fell back to the fixture)"; exit 1; }
[ "$MODE" = "700" ] || { echo "FAIL: cell directory is $MODE, expected 700"; exit 1; }
[ "$FROM_META" = "deployed" ] || { echo "FAIL: losing state.db lost the deployment"; exit 1; }
[ "$ROWS_META" = "2" ] || { echo "FAIL: rows lost with state.db ($ROWS_META)"; exit 1; }
echo "PASS"
