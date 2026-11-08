#!/usr/bin/env bash
# Run the webhook receiver end to end: start a server, deploy the app, send
# signed events, check what the cell stored, stop the server.
#
#   examples/webhook/run.sh
set -uo pipefail
cd "$(dirname "$0")/../.."

BIN=./zig-out/bin/cellar
PORT=${PORT:-$(( 8300 + ($$ % 200) ))}
DATA=${DATA:-./.webhookdemo.$$}
[ -x "$BIN" ] || { echo "build first: zig build"; exit 1; }

cleanup() { [ -n "${SERVER:-}" ] && kill "$SERVER" 2>/dev/null; rm -rf "$DATA"; }
trap cleanup EXIT

rm -rf "$DATA"
$BIN serve --listen "127.0.0.1:$PORT" --admin-token t --data "$DATA" --shards 1 \
  >/tmp/webhook-server.log 2>&1 &
SERVER=$!

for _ in $(seq 1 50); do
  curl -sf "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break
  sleep 0.1
done

echo "deploy:"
$BIN deploy examples/webhook/app.lua --cell hook --server "http://127.0.0.1:$PORT" --token t || exit 1

echo "events:"
python3 examples/webhook/send.py --url "http://127.0.0.1:$PORT/c/hook/hook" || exit 1

echo "rows in the cell database (read with sqlite3, not through the runtime):"
python3 - "$DATA" <<'PY'
import sqlite3, sys, glob
db = glob.glob(f"{sys.argv[1]}/cells/*/db.sqlite")[0]
con = sqlite3.connect(db)
for row in con.execute("select id, type from events order by id"):
    print("  ", row)
print("   total:", con.execute("select count(*) from events").fetchone()[0])
PY

echo "restart (the rows must survive):"
kill "$SERVER"; sleep 0.4
$BIN serve --listen "127.0.0.1:$PORT" --admin-token t --data "$DATA" --shards 1 \
  >>/tmp/webhook-server.log 2>&1 &
SERVER=$!
for _ in $(seq 1 50); do
  curl -sf "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1 && break
  sleep 0.1
done
echo -n "   count after restart: "
curl -s -X POST -d x "http://127.0.0.1:$PORT/c/hook/count"; echo
