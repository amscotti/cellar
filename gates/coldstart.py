#!/usr/bin/env python3
"""G10: cold start and relocation.

Every other gate starts from a state the code created moments earlier. This one does
what an operator does on day one and on day thirty: deploy to a fresh directory, move
the whole data directory somewhere else (the docs claim it is relocatable — the cell
dir is a digest of the key, the blob store is content-addressed, and meta.json is
self-describing), start again there, then start once more from nothing.

A failure here is not a race or an edge case: it means a data directory cannot be
moved, or a fresh install does not work.
"""
import glob
import json
import os
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

BIN = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "zig-out", "bin", "cellar")
ROOT = f"/tmp/coldstart-{os.getpid()}"
PORT = 8900 + (os.getpid() % 90)
BASE = f"http://127.0.0.1:{PORT}"
TOKEN = "t"

APP = """
local M = {}
function M.bump(body)
  db.exec("create table if not exists n(x integer)")
  db.exec("insert into n(x) values (1)")
  return tostring(db.value("select count(*) from n"))
end
function M.snapshot_rows(_)
  return tostring(db.value("select count(*) from n"))
end
return M
"""

results = []


def check(name, got, want):
    ok = got == want
    results.append(ok)
    print(f"  {'PASS' if ok else 'FAIL'}  {name:<48} -> {got!r}")


def start(data):
    p = subprocess.Popen([BIN, "serve", "--listen", f"127.0.0.1:{PORT}",
                          "--admin-token", TOKEN, "--data", data, "--shards", "2"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(80):
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


def get(path, token=None):
    req = urllib.request.Request(BASE + path)
    if token:
        req.add_header("X-Cellar-Token", token)
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def stop(p):
    p.terminate()
    p.wait(timeout=15)


def main() -> int:
    shutil.rmtree(ROOT, ignore_errors=True)
    a = f"{ROOT}/a"
    os.makedirs(a)

    # 1. First hour: deploy, write, look at the dashboard.
    p = start(a)
    try:
        post("/admin/deploy?cell=alpha", APP.encode(), TOKEN)
        post("/admin/deploy?cell=beta", APP.encode(), TOKEN)
        for _ in range(3):
            post("/c/alpha/bump", b"", TOKEN)
        post("/c/beta/bump", b"", TOKEN)
        check("alpha has 3 rows", post("/c/alpha/snapshot_rows", b"", TOKEN)[1], "3")
        code, page = get("/admin")
        check("dashboard renders", code, 200)
        check("dashboard lists both cells", ("alpha" in page) and ("beta" in page), True)
        check("both cells have detail", get("/admin/cells/beta")[0], 200)
        code, detail = get("/admin/cells/alpha")
        check("cell detail names the module", json.loads(detail).get("module"), "default")
        check("snapshot accepted", post("/admin/snapshot?cell=alpha", b"", TOKEN)[0], 200)
        snaps = glob.glob(f"{a}/snapshots/*.db")
        check("a snapshot file exists", len(snaps), 1)
    finally:
        stop(p)

    # 2. Day thirty: move the whole data directory and start again.
    b = f"{ROOT}/b"
    shutil.move(a, b)
    p = start(b)
    try:
        check("a moved data dir keeps alpha's rows", post("/c/alpha/snapshot_rows", b"", TOKEN)[1], "3")
        check("a moved data dir keeps beta serving", post("/c/beta/bump", b"", TOKEN)[1], "2")
        check("moved registry still knows alpha", json.loads(get("/admin/cells/alpha")[1])["module"], "default")
        check("moved registry still knows beta", json.loads(get("/admin/cells/beta")[1])["module"], "default")
    finally:
        stop(p)

    # 3. Fresh install: nothing to migrate, nothing to open, dashboard still works.
    c = f"{ROOT}/c"
    os.makedirs(c)
    p = start(c)
    try:
        check("fresh healthz", get("/healthz")[0], 200)
        check("fresh dashboard", get("/admin")[0], 200)
        check("fresh install has no cells", "no cells yet" in get("/admin")[1], True)
        code, body = post("/c/never/echo", b"hi", TOKEN)
        check("an undeployed cell runs the built-in module", body, "echo:hi")
    finally:
        stop(p)
        shutil.rmtree(ROOT, ignore_errors=True)

    print("PASS" if all(results) else "FAIL")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
