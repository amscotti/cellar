#!/usr/bin/env python3
"""Blob GC gate.

Deploys are content-addressed: every deploy writes a new blob and nothing ever removed
one. This gate checks that garbage collection removes what nothing refers to and — the
part that matters — keeps what a *cell* is still pinned to, even when that version has
fallen out of the deployment history window.

Scenario: cell `keeper` is deployed once (version 1, then abandoned). Cell `live` is
deployed four more times (versions 2-5). Pruning with keep=2 drops versions 1-3 from the
deployment history, but keeper still runs version 1, so its blob must survive. Then the
server restarts: if the blob was deleted, keeper comes back as the built-in fixture and
the invoke below fails.
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
DATA = f"/tmp/gc-{os.getpid()}"
PORT = 8099 + (os.getpid() % 300)
BASE = f"http://127.0.0.1:{PORT}"
TOKEN = "t"

APP = """
local M = {}
function M.mark(body) return "v:" .. body end
return M
"""

results = []


def check(name, got, want):
    ok = got == want
    results.append(ok)
    print(f"  {'PASS' if ok else 'FAIL'}  {name:<44} -> {got!r}")


def start():
    p = subprocess.Popen([BIN, "serve", "--listen", f"127.0.0.1:{PORT}",
                          "--admin-token", TOKEN, "--data", DATA, "--shards", "1",
                          "--gc-min-age-s", "0"],
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


def blobs():
    return sorted(os.path.basename(p) for p in glob.glob(f"{DATA}/blobs/*.bin"))


def main() -> int:
    shutil.rmtree(DATA, ignore_errors=True)
    p = start()
    try:
        # Distinct sources: the blob store is content-addressed, so N identical
        # deploys are one blob. A comment makes each version its own content.
        post("/admin/deploy?cell=keeper", (APP + "\n-- v1\n").encode(), TOKEN)
        time.sleep(0.05)
        for v in range(2, 6):
            post("/admin/deploy?cell=live", (APP + f"\n-- v{v}\n").encode(), TOKEN)
            time.sleep(0.05)
        before = blobs()
        check("one blob per deploy", len(before), 5)
        check("keeper serves", post("/c/keeper/mark", b"k")[1], "v:k")

        code, body = post("/admin/gc?keep=2", b"", TOKEN)
        check("gc accepted", code, 200)
        info = json.loads(body)
        after = blobs()
        check("two unreferenced blobs collected", info["deleted"], 2)
        check("three blobs survive", len(after), 3)

        check("keeper still serves after gc", post("/c/keeper/mark", b"k")[1], "v:k")
        check("live still serves after gc", post("/c/live/mark", b"l")[1], "v:l")
    finally:
        p.terminate()
        p.wait(timeout=10)

    # The real test: restart, so a cell whose blob was wrongly collected would fall
    # back to the built-in fixture instead of the deployed module.
    p = start()
    try:
        check("keeper's module survived a restart", post("/c/keeper/mark", b"k")[1], "v:k")
        check("live's module survived a restart", post("/c/live/mark", b"l")[1], "v:l")
    finally:
        p.terminate()
        p.wait(timeout=10)

    # A pin whose blob is gone must fail loudly. The old behaviour served the cell's
    # real data with the built-in fixture: different handlers, no error, and it
    # rewrote meta.json with an empty pin so the recovery path vanished too.
    import glob as _glob
    for f in _glob.glob(f"{DATA}/blobs/*.bin"):
        os.remove(f)
    p = start()
    try:
        code, body = post("/c/keeper/mark", b"k")
        check("a missing pinned blob is an error, not the fixture", code, 500)
        print("   body:", body[:220])
        check("the error names the cause", "ModuleUnavailable" in body, True)
        # A deploy that fails must not leave the cell resident running the built-in
        # module: that would serve the fixture over real data forever.
        code_bad, _ = post("/admin/deploy?cell=keeper", b"this is not lua", TOKEN)
        check("a broken deploy is refused", code_bad >= 400, True)
        code_after, body_after = post("/c/keeper/mark", b"k")
        check("a failed deploy leaves ModuleUnavailable", body_after, '{"error":{"kind":"internal","message":"ModuleUnavailable"}}')

        # ...and a deploy must still be able to repair it, or the cell is stuck forever.
        post("/admin/deploy?cell=keeper", (APP + "\n-- v9\n").encode(), TOKEN)
        check("a deploy can repair a broken pin", post("/c/keeper/mark", b"k")[1], "v:k")
    finally:
        p.terminate()
        p.wait(timeout=10)
        shutil.rmtree(DATA, ignore_errors=True)

    print("PASS" if all(results) else "FAIL")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
