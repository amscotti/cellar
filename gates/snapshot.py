#!/usr/bin/env python3
"""Snapshot + restore drill.

A snapshot that has never been restored is a file, not a backup. This gate:

  1. writes three rows, snapshots the cell through the admin API;
  2. checks the snapshot with `sqlite3` directly (integrity + contents);
  3. writes two more rows, so the snapshot is provably stale;
  4. stops the server, restores the snapshot over the live database, starts again;
  5. requires the cell to read three — the snapshot's value, not five;
  6. and requires the cell to still serve increments afterwards.

The restore also removes `-wal`/`-shm`: copying a database file under a live WAL is
how a "restore" silently resurrects neither the old nor the new state.
"""
import glob
import json
import os
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request

BIN = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "zig-out", "bin", "cellar")
DATA = f"/tmp/snap-{os.getpid()}"
PORT = 8099 + (os.getpid() % 300)
BASE = f"http://127.0.0.1:{PORT}"
TOKEN = "t"

APP = """
local M = {}
function M.incr(_)
  db.exec("create table if not exists counters (id integer primary key, n integer)")
  db.exec("insert into counters (id, n) values (1, 1) on conflict(id) do update set n = n + 1")
  return tostring(db.value("select n from counters where id = 1"))
end
function M.get(_) return tostring(db.value("select n from counters where id = 1") or 0) end
return M
"""

results = []


def check(name, got, want):
    ok = got == want
    results.append(ok)
    print(f"  {'PASS' if ok else 'FAIL'}  {name:<38} -> {got!r}")


def start():
    p = subprocess.Popen([BIN, "serve", "--listen", f"127.0.0.1:{PORT}",
                          "--admin-token", TOKEN, "--data", DATA, "--shards", "1"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(60):
        try:
            socket.create_connection(("127.0.0.1", PORT), 0.2).close()
            return p
        except OSError:
            time.sleep(0.1)
    raise SystemExit("server did not start")


def post(path, body=b"", token=None):
    req = urllib.request.Request(BASE + path, data=body, method="POST")
    if token:
        req.add_header("X-Cellar-Token", token)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def main() -> int:
    shutil.rmtree(DATA, ignore_errors=True)
    p = start()
    try:
        post("/admin/deploy?cell=snap", APP.encode(), TOKEN)
        for _ in range(3):
            post("/c/snap/incr")
        before = post("/c/snap/get")[1]

        code, body = post("/admin/snapshot?cell=snap", b"", TOKEN)
        check("snapshot accepted", code, 200)
        info = json.loads(body)
        path = info["path"]
        check("snapshot file exists", os.path.exists(path), True)
        check("snapshot is not empty", info["bytes"] > 0, True)

        con = sqlite3.connect(path)
        ok = con.execute("pragma integrity_check").fetchone()[0]
        rows = con.execute("select n from counters where id = 1").fetchone()[0]
        con.close()
        check("snapshot integrity", ok, "ok")
        check("snapshot holds the rows at that moment", rows, int(before))

        # Make the live database provably newer than the snapshot.
        post("/c/snap/incr")
        post("/c/snap/incr")
        check("live value moved on", post("/c/snap/get")[1], str(int(before) + 2))
    finally:
        p.send_signal(signal.SIGTERM)
        p.wait(timeout=10)

    # Restore: the database file is replaced, and the WAL that belonged to the
    # replaced file is removed with it.
    db = glob.glob(f"{DATA}/cells/*/db.sqlite")[0]
    for stale in (db + "-wal", db + "-shm"):
        if os.path.exists(stale):
            os.remove(stale)
    shutil.copyfile(path, db)

    p = start()
    try:
        after = post("/c/snap/get")[1]
        check("restored cell reads the snapshot value", after, before)
        check("restored cell still serves writes", post("/c/snap/incr")[1], str(int(before) + 1))
    finally:
        p.terminate()
        p.wait(timeout=10)
        shutil.rmtree(DATA, ignore_errors=True)

    print("PASS" if all(results) else "FAIL")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
