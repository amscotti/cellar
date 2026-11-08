"""Regression probes for the P0s the review found. Speaks raw HTTP so the exact
bytes matter: each case sends what the reviewer sent and checks the server's
behaviour, not just its status code."""
import json
import os
import socket
import sqlite3
import subprocess
import sys
import time

BIN = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "zig-out", "bin", "cellar")
# Unique per run, and never `pkill -x cellar`: a probe run used to kill whatever
# cellar was alive, including another gate's server, which looked like a crash.
DATA = os.environ.get("CELLAR_PROBE_DATA", f"/tmp/probe-data-{os.getpid()}")
PORT = int(os.environ.get("CELLAR_PROBE_PORT", 8099 + (os.getpid() % 300)))


def start():
    subprocess.run(["rm", "-rf", DATA], check=True)
    p = subprocess.Popen([BIN, "serve", "--listen", f"127.0.0.1:{PORT}",
                          "--admin-token", "tok", "--data", DATA],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(50):
        try:
            socket.create_connection(("127.0.0.1", PORT), 0.2).close()
            return p
        except OSError:
            time.sleep(0.1)
    raise SystemExit("server did not start")


def send(raw, read_all=True):
    s = socket.create_connection(("127.0.0.1", PORT), 3)
    s.settimeout(3)
    s.sendall(raw)
    out = b""
    try:
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            out += chunk
            if not read_all and b"\r\n\r\n" in out:
                break
    except socket.timeout:
        pass
    s.close()
    return out


results = []

# 1. Expect: 100-continue must not abort the process.
p = start()
r = send(b"POST /c/t1/echo HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\n"
         b"Content-Length: 5\r\nConnection: close\r\n\r\nhello")
alive = p.poll() is None and socket.create_connection(("127.0.0.1", PORT), 1)
results.append(("expect-continue keeps process alive",
                p.poll() is None,
                f"exit={p.poll()} resp={r[:40]!r}"))
results.append(("expect-continue answers 100 then 200", b"100 Continue" in r and b"200 OK" in r, r[:60]))

# 2. A body spelling a different cell key must not change the routed cell.
body = b"z" * (128 * 1024)
r = send(b"POST /c/aaaaaa/echo HTTP/1.1\r\nHost: x\r\n"
         b"Content-Length: %d\r\nConnection: close\r\n\r\n" % len(body) + body)
time.sleep(0.3)
cells = []
dbp = os.path.join(DATA, "state.db")
if os.path.exists(dbp):
    c = sqlite3.connect(f"file:{dbp}?mode=ro", uri=True)
    cells = [row[0] for row in c.execute("select key from cells")]
    c.close()
results.append(("big body does not reroute to body-derived cell",
                "aaaaaa" in cells and not any(c and set(c) == {"z"} for c in cells),
                f"cells={cells}"))

# 3. Oversized body + pipelined request: one response, connection closed.
raw = (b"POST /c/a/echo HTTP/1.1\r\nHost: x\r\nContent-Length: 1048577\r\n\r\n"
       + b"A" * (1024 * 1024 + 1)
       + b"GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n")
r = send(raw)
responses = r.count(b"HTTP/1.1 ")
results.append(("oversized body yields exactly one response",
                responses == 1, f"count={responses} head={r[:40]!r}"))

# 4. Empty token is not a token.
r = send(b"POST /admin/deploy?cell=owned HTTP/1.1\r\nHost: x\r\n"
         b"X-Cellar-Token:\r\nContent-Length: 26\r\nConnection: close\r\n\r\n"
         b"local M = {} return M\n\x20\x20\x20")
results.append(("empty token is rejected", b"401" in r.split(b"\r\n")[0], r[:40]))

# 5. Guest SAVEPOINT cannot commit.
deploy = (b"local M = {}\nfunction M.try_sp(b)\n"
          b"  db.exec('create table if not exists sp(x integer)')\n"
          b"  db.exec('savepoint s1')\n"
          b"  db.exec('insert into sp values (1)')\n"
          b"  db.exec('release s1')\n"
          b"  return 'ok'\nend\nreturn M\n")
r = send(b"POST /admin/deploy?cell=sp HTTP/1.1\r\nHost: x\r\nX-Cellar-Token: tok\r\n"
         b"Content-Length: %d\r\nConnection: close\r\n\r\n" % len(deploy) + deploy)
r2 = send(b"POST /c/sp/try_sp HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n"
          b"Connection: close\r\n\r\n")
results.append(("savepoint is refused by the authorizer",
                b"savepoint" in r2.lower() or b"not authorized" in r2.lower() or b"error" in r2.lower(),
                r2[-120:]))

# 6. A POST with neither Content-Length nor Transfer-Encoding must not abort the
# process: std.http asserts on it in discardBody, and that assert killed the server
# when /admin/key was hit without a body.
r = send(b"POST /admin/key?cell=nf HTTP/1.1\r\nHost: x\r\nX-Cellar-Token: tok\r\nConnection: close\r\n\r\n")
alive = send(b"GET /healthz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
results.append(("a bodyless POST does not kill the server",
                b"200" in r.split(b"\r\n")[0] and b'"ok":true' in r and b"200" in alive.split(b"\r\n")[0],
                r[:120]))

p.kill()
print()
bad = 0
for name, ok, detail in results:
    print(f"{'PASS' if ok else 'FAIL'}  {name}")
    if not ok:
        bad += 1
        print(f"      {detail}")
print()
print("ALL PASS" if bad == 0 else f"{bad} FAILURES")
sys.exit(1 if bad else 0)
