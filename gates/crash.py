#!/usr/bin/env python3
"""Crash gate: kill the process mid-write and check what survived.

This is the test the cluster research says must pass before clustering is worth
anything: "clustering multiplies an unverified durability story rather than
repairing it." So: hammer one cell with increments, SIGKILL the server, restart, and
check the database is intact and that nothing acknowledged was lost.

The invariant is one-sided on purpose. A write that committed but whose response was
still in flight when the process died is *not* a loss — the client never saw a 200.
So: rows >= acknowledged, rows <= acknowledged + (in-flight requests).
"""
import json
import os
import signal
import socket
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.request
import urllib.error

BIN = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "zig-out", "bin", "cellar")
DATA = f"/tmp/crash-{os.getpid()}"
PORT = 8099 + (os.getpid() % 300)
BASE = f"http://127.0.0.1:{PORT}"

APP = """
local M = {}
function M.incr(_)
  db.exec("create table if not exists counters (id integer primary key, n integer)")
  db.exec("insert into counters (id, n) values (1, 1) on conflict(id) do update set n = n + 1")
  return tostring(db.value("select n from counters where id = 1"))
end
function M.get(_)
  return tostring(db.value("select n from counters where id = 1") or 0)
end
return M
"""

acked = 0
lock = threading.Lock()
stop = threading.Event()


def start():
    p = subprocess.Popen([BIN, "serve", "--listen", f"127.0.0.1:{PORT}",
                          "--admin-token", "t", "--data", DATA, "--shards", "1",
                          "--deadline-ms", "5000"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(60):
        try:
            socket.create_connection(("127.0.0.1", PORT), 0.2).close()
            return p
        except OSError:
            time.sleep(0.1)
    raise SystemExit("server did not start")


def post(path, body=b""):
    req = urllib.request.Request(BASE + path, data=body, method="POST")
    with urllib.request.urlopen(req, timeout=5) as r:
        return r.read().decode()


def hammer():
    global acked
    while not stop.is_set():
        try:
            post("/c/crash/incr", b"")
            with lock:
                acked += 1
        except Exception:
            return


def db_rows():
    con = sqlite3.connect(f"{DATA}/cells/" + os.listdir(f"{DATA}/cells")[0] + "/db.sqlite")
    try:
        ok = con.execute("pragma integrity_check").fetchone()[0]
        n = con.execute("select n from counters where id = 1").fetchone()
        return ok, (n[0] if n else 0)
    finally:
        con.close()


def main() -> int:
    subprocess.run(["rm", "-rf", DATA], check=True)
    p = start()
    deploy_src = APP
    req = urllib.request.Request(f"{BASE}/admin/deploy?cell=crash", data=deploy_src.encode(), method="POST")
    req.add_header("X-Cellar-Token", "t")
    try:
        urllib.request.urlopen(req, timeout=5).read()
    except urllib.error.HTTPError as e:
        print("deploy failed:", e.code, e.read()[:200])
        return 1

    threads = [threading.Thread(target=hammer) for _ in range(8)]
    for t in threads:
        t.start()
    time.sleep(1.5)
    p.send_signal(signal.SIGKILL)   # no drain, no flush, no chance
    p.wait()
    stop.set()
    for t in threads:
        t.join(timeout=5)
    time.sleep(0.2)

    ok, rows = db_rows()
    print(f"  acknowledged before SIGKILL: {acked}")
    print(f"  rows in the cell database:   {rows}")
    print(f"  integrity_check:             {ok}")

    # Restart on the same data dir and make sure it still serves.
    p = start()
    try:
        after = post("/c/crash/get", b"")
        alive = post("/c/crash/incr", b"")
    finally:
        p.terminate()
        p.wait(timeout=10)

    print(f"  after restart: get={after} incr={alive}")

    fail = 0
    if ok != "ok":
        print("  FAIL: database is not intact after SIGKILL")
        fail = 1
    if rows < acked:
        print(f"  FAIL: lost acknowledged writes (rows {rows} < acked {acked})")
        fail = 1
    if rows > acked + 64:
        print(f"  FAIL: {rows - acked} unacknowledged rows — a transaction committed that no client saw")
        fail = 1
    if after != str(rows):
        print(f"  FAIL: runtime reads {after}, database holds {rows}")
        fail = 1
    if alive != str(rows + 1):
        print(f"  FAIL: cell does not serve after restart ({alive!r})")
        fail = 1

    subprocess.run(["rm", "-rf", DATA])
    print("PASS" if fail == 0 else "FAIL")
    return fail


if __name__ == "__main__":
    sys.exit(main())
