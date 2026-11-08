#!/usr/bin/env python3
"""G9: the HTTP and VM edges an attacker actually knocks on.

Every case here was a real finding: a body on GET smuggled a second request past the
proxy (CL.0); Content-Length together with Transfer-Encoding was accepted (TE.CL); the
admin token was accepted in the query string on every read instead of only the unlock;
revoking an unknown key id reported success; a recursive CTE pinned a shard forever
(sqlite3_step runs in C, where the Lua hook cannot see it); and a guest could catch the
deadline with pcall and still commit.
"""

import http.client, json, os, socket, subprocess, time, shutil, sys
PORT = 8400 + (os.getpid() % 300)
BIN=os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "zig-out", "bin", "cellar")
d=f"/tmp/httpedges-{PORT}"; shutil.rmtree(d, ignore_errors=True)
p=subprocess.Popen([BIN,"serve","--listen",f"0.0.0.0:{PORT}","--admin-token","adm","--cell-token","ct","--data",d,"--deadline-ms","400","--allow-fetch","1","--fetch-allow-private","1","--fetch-workers","2"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for _ in range(80):
    try: socket.create_connection(("127.0.0.1",PORT),0.2).close(); break
    except OSError: time.sleep(0.1)

def raw(data, seconds=2.0):
    s=socket.create_connection(("127.0.0.1",PORT),3); s.settimeout(seconds)
    s.sendall(data); out=b""
    try:
        while True:
            b=s.recv(4096)
            if not b: break
            out+=b
    except socket.timeout: pass
    s.close(); return out

def req(m,path,body=b"",hdr=None):
    c=http.client.HTTPConnection("127.0.0.1",PORT,timeout=15)
    c.request(m,path,body=body,headers=hdr or {})
    r=c.getresponse(); b=r.read().decode(); c.close(); return r.status,b

ok=True
def check(n,g,w):
    global ok
    good = g==w if not isinstance(w,str) else str(w) in str(g)
    ok = ok and good
    print(("PASS " if good else "FAIL ")+n+" -> "+repr(g)[:120])

# CL.0: body on GET must be refused, not parsed as a second request
r1=raw(b"GET /healthz HTTP/1.1\r\nHost: x\r\nContent-Length: 57\r\n\r\nGET /admin/cells HTTP/1.1\r\nHost: x\r\nX-Pad: 000\r\n\r\n")
check("CL.0 rejected", r1.count(b"HTTP/1.1"), 1)
check("CL.0 status", r1.split(b"\r\n")[0], "400")

# TE+CL
r2=raw(b"POST /c/t/fn HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n")
check("TE+CL rejected", r2.split(b"\r\n")[0], "400")

# TE with whitespace before the colon, and TE values std maps to a content encoding,
# are dropped by the parser: the raw-head scan must still reject them.
r3=raw(b"POST /c/t/fn HTTP/1.1\r\nHost: x\r\nTransfer-Encoding : chunked\r\n\r\n0\r\n\r\nGET /admin/cells HTTP/1.1\r\nHost: x\r\n\r\n")
check("TE with space before colon rejected", r3.count(b"HTTP/1.1"), 1)
check("TE with space before colon is 400", r3.split(b"\r\n")[0], "400")
r4=raw(b"POST /c/t/fn HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\n\r\nxxGET /admin/cells HTTP/1.1\r\nHost: x\r\n\r\n")
check("TE gzip rejected", r4.split(b"\r\n")[0], "400")

# An early 4xx must answer and close, not drain a body that was never read: the drain
# is unbounded and has no read timeout, so it parks a connection thread forever.
t5=time.time(); r5=raw(b"POST /nope HTTP/1.1\r\nHost: x\r\nContent-Length: 1000000000\r\n\r\n", seconds=5.0)
check("early 4xx answers without draining", r5.split(b" ")[1], b"404")
check("...and does not wait for the body", time.time()-t5 < 1.5, True)

# A cookie-authenticated mutation from another origin on the same host must be refused.
def cookie_req(site):
    c=http.client.HTTPConnection("127.0.0.1",PORT,timeout=10)
    c.request("POST","/admin/revoke?key_id=deadbeef",body="",headers={
        "Cookie":"cellar_token=adm","Sec-Fetch-Site":site,"Host":f"127.0.0.1:{PORT}"})
    r=c.getresponse(); b=r.read().decode(); c.close(); return r.status,b
check("cross-origin cookie mutation refused", cookie_req("same-site")[0], 403)

def cookie_raw(headers):
    c=http.client.HTTPConnection("127.0.0.1",PORT,timeout=10)
    c.request("POST","/admin/revoke?key_id=deadbeef",body="",headers=headers)
    r=c.getresponse(); b=r.read().decode(); c.close(); return r.status,b
# a proxy that rewrites Sec-Fetch-* must not make a foreign Origin look local
check("foreign Origin beats Sec-Fetch-Site", cookie_raw({
    "Cookie":"cellar_token=adm","Origin":"http://evil.example","Sec-Fetch-Site":"same-origin",
    "Host":f"127.0.0.1:{PORT}"})[0], 403)
# duplicate Host is ambiguous -> refuse (raw socket: http.client would collapse it)
dup = raw(("POST /admin/revoke?key_id=deadbeef HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nHost: evil.example\r\n"
           "Cookie: cellar_token=adm\r\nContent-Length: 0\r\n\r\n" % PORT).encode())
check("duplicate Host refused", dup.split(b" ")[1], b"403")
check("same-origin cookie mutation allowed", cookie_req("same-origin")[0], 404)

# ?token= only on the unlock endpoint (non-loopback listener -> reads are gated)
check("token in query on reads refused", req("GET","/admin/cells?token=adm")[0], 401)
check("unlock still accepts token", req("GET","/admin?token=adm")[0], 303)

# revoking twice must stay a success: a rotation script that retries after a dropped
# response must not abort between "old key dead" and "new key installed"
_, kb = req("POST","/admin/key?cell=rv", b"", {"X-Cellar-Token":"adm"})
kid = json.loads(kb)["key_id"]
check("first revoke 200", req("POST",f"/admin/revoke?key_id={kid}", b"", {"X-Cellar-Token":"adm"})[0], 200)
second = json.loads(req("POST",f"/admin/revoke?key_id={kid}", b"", {"X-Cellar-Token":"adm"})[1])
check("second revoke is idempotent", second.get("revoked"), False)

# revoke an unknown id
s,_=req("POST","/admin/revoke?key_id=deadbeef","",{"X-Cellar-Token":"adm"})
check("unknown revoke -> 404", s, 404)

# a runaway recursive CTE must be interrupted, not hang the shard
src=b"""local M = {}
function M.go(_)
  local ok, err = pcall(function()
    db.value("WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c) SELECT count(*) FROM c")
  end)
  return tostring(ok) .. "|" .. tostring(err)
end
return M
"""
req("POST","/admin/deploy?cell=cte",src,{"X-Cellar-Token":"adm"})
t0=time.time(); st,body=req("POST","/c/cte/go",b"",{"X-Cellar-Token":"ct"}); dt=time.time()-t0
check("runaway SQL interrupted (seconds<4)", dt<4.0, True)
check("healthz after runaway SQL", req("GET","/healthz")[0], 200)

# a 200 from /admin/deploy must mean the pin is already visible: the durable pin is
# the acknowledgement, not a best-effort write after it
src4=b"""local M = {}
function M.mark(body) return "pinned:" .. body end
return M
"""
st4,b4=req("POST","/admin/deploy?cell=pinned",src4,{"X-Cellar-Token":"adm"})
sha4=json.loads(b4).get("sha","") if st4==200 else ""
st5,b5=req("GET","/admin/cells/pinned",b"",{"X-Cellar-Token":"adm"})
detail5=json.loads(b5) if st5==200 else {}
check("deploy 200 carries a sha", len(sha4), 64)
check("the pin is visible before the ack returns", detail5.get("blob_sha",""), sha4)
check("cell runs the pinned module", req("POST","/c/pinned/mark",b"x",{"X-Cellar-Token":"ct"})[1], "pinned:x")

# an upstream that accepts and never answers must not hold the cell forever
# (the sink is on loopback, which the fetch egress policy blocks by default;
# this server opts in with --fetch-allow-private so the deadline path is what
# is exercised here — the policy itself is unit-tested in runtime/fetch.zig)
import threading
sink = socket.socket(); sink.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sink.bind(("127.0.0.1", 0)); sink.listen(8)
sink_port = sink.getsockname()[1]
held = []
def acceptor():
    while True:
        try:
            c, _ = sink.accept()
        except OSError:
            return
        held.append(c)          # accept, then never respond
threading.Thread(target=acceptor, daemon=True).start()
src3 = ("local M = {}\nfunction M.go(_)\n"
        "  local ok, err = http.fetch('http://127.0.0.1:%d/x')\n"
        "  return tostring(ok) .. '|' .. tostring(err)\nend\nreturn M\n" % sink_port).encode()
req("POST","/admin/deploy?cell=hang",src3,{"X-Cellar-Token":"adm"})
t0=time.time(); st3,b3=req("POST","/c/hang/go",b"",{"X-Cellar-Token":"ct"}); dt3=time.time()-t0
check("silent upstream is cut off at the deadline (s<4)", dt3<4.0, True)
check("silent upstream -> 504", st3, 504)
check("cell serves again after the abort", req("POST","/c/hang/go",b"",{"X-Cellar-Token":"ct"})[0], 504)
sink.close()

# pcall cannot swallow the deadline -> 504
src2=b"""local M = {}
function M.go(_)
  pcall(function() while true do end end)
  return "ok"
end
return M
"""
req("POST","/admin/deploy?cell=pc",src2,{"X-Cellar-Token":"adm"})
s2,b2=req("POST","/c/pc/go",b"",{"X-Cellar-Token":"ct"})
check("deadline caught by pcall still times out", s2, 504)

p.terminate(); p.wait(timeout=10); shutil.rmtree(d,ignore_errors=True)
print("ALL PASS" if ok else "FAILURES")
sys.exit(0 if ok else 1)
