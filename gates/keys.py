#!/usr/bin/env python3
"""Per-cell credentials, end to end.

Proves the properties that matter:
  * a cell with its own key requires it;
  * the shared `--cell-token` no longer opens that cell (a leaked global password
    must not defeat a per-cell key);
  * cells without a key still use the shared token;
  * the key survives a restart, and state.db holds only its digest.
"""
import json
import os
import socket
import subprocess
import sys
import time
import urllib.request
import urllib.error

BIN = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "zig-out", "bin", "cellar")
DATA = f"/tmp/keys-{os.getpid()}"
PORT = 8099 + (os.getpid() % 300)
BASE = f"http://127.0.0.1:{PORT}"
ADMIN = "adm1n"

results = []


def check(name, got, want):
    ok = got == want
    results.append(ok)
    print(f"  {'PASS' if ok else 'FAIL'}  {name:<46} -> {got!r}")


def start(fresh=True):
    # A restart must reuse the data dir: wiping it here would make the "key
    # survives a restart" check pass for the wrong reason (it would be a fresh
    # server, not a restarted one).
    if fresh:
        subprocess.run(["rm", "-rf", DATA], check=True)
    p = subprocess.Popen([BIN, "serve", "--listen", f"127.0.0.1:{PORT}",
                          "--admin-token", ADMIN, "--cell-token", "shared",
                          "--data", DATA, "--shards", "1"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(60):
        try:
            socket.create_connection(("127.0.0.1", PORT), 0.2).close()
            return p
        except OSError:
            time.sleep(0.1)
    raise SystemExit("server did not start")


def post(path, body=b"", headers=None):
    req = urllib.request.Request(BASE + path, data=body, method="POST")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


p = start()
try:
    # Mint a key for one cell.
    status, body = post(f"/admin/key?cell=vault", headers={"X-Cellar-Token": ADMIN})
    check("admin can mint a key", status, 200)
    token = json.loads(body)["token"]
    check("token is 64 hex chars", len(token) == 64 and all(c in "0123456789abcdef" for c in token), True)

    check("no token rejected", post("/c/vault/echo", b"hi")[0], 401)
    check("shared cell token rejected for keyed cell", post("/c/vault/echo", b"hi", {"X-Cellar-Token": "shared"})[0], 401)
    check("wrong key rejected", post("/c/vault/echo", b"hi", {"X-Cellar-Token": "0" * 64})[0], 401)
    status, body = post("/c/vault/echo", b"hi", {"X-Cellar-Token": token})
    check("own key accepted", (status, body), (200, "echo:hi"))

    check("unkeyed cell still uses shared token", post("/c/plain/echo", b"hi", {"X-Cellar-Token": "shared"})[0], 200)

    # Rotation with overlap: mint a second key, move the client, then revoke the
    # first. Both must work in between, and only the revoked one must stop.
    status, body = post(f"/admin/key?cell=vault", headers={"X-Cellar-Token": ADMIN})
    second = json.loads(body)
    check("second key minted", status, 200)
    check("old key still works during overlap",
          post("/c/vault/echo", b"hi", {"X-Cellar-Token": token})[0], 200)
    check("new key works during overlap",
          post("/c/vault/echo", b"hi", {"X-Cellar-Token": second["token"]})[0], 200)
    status, body = post(f"/admin/revoke?key_id={second['key_id']}", headers={"X-Cellar-Token": ADMIN})
    check("revoke accepted", status, 200)
    check("revoked key rejected",
          post("/c/vault/echo", b"hi", {"X-Cellar-Token": second["token"]})[0], 401)
    check("surviving key still works",
          post("/c/vault/echo", b"hi", {"X-Cellar-Token": token})[0], 200)

    # Restart: the key is in state.db, so it must still work.
    p.terminate()
    p.wait(timeout=5)
    p = start(fresh=False)
    check("own key survives a restart", post("/c/vault/echo", b"hi", {"X-Cellar-Token": token})[0], 200)

    # state.db must hold a digest, not the token. Read it with sqlite3 so a WAL
    # still holding pages is included.
    import sqlite3
    con = sqlite3.connect(os.path.join(DATA, "state.db"))
    rows = list(con.execute("select cell_key, digest, revoked_at from cell_credentials order by revoked_at"))
    con.close()
    live = [r for r in rows if r[2] is None]
    check("two credentials recorded, one revoked", (len(rows), len(live)), (2, 1))
    check("stored value is a 32-byte digest", len(live[0][1]) if live else 0, 32)
    check("stored digest is not the token", live[0][1].hex() == token if live else False, False)
finally:
    p.terminate()
    p.wait(timeout=5)
    subprocess.run(["rm", "-rf", DATA])

print("PASS" if all(results) else "FAIL")
sys.exit(0 if all(results) else 1)
