#!/usr/bin/env python3
"""Auth edge cases (G5, second half): the two ways the data plane reopened itself.

1. An empty `--cell-token` must deny, not skip the check.
2. Revoking a cell's last key must not fall the cell back to the shared token — a
   keyed cell stays keyed (and closed) even when every key is revoked.

Both were found by the HTTP review lens; both are one-line bugs with total impact.
"""

import http.client, json, socket, subprocess, time, sys, os, shutil
BIN=os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "zig-out", "bin", "cellar")

def start(args, port):
    d=f"/tmp/authp0-{port}"
    shutil.rmtree(d, ignore_errors=True)
    p=subprocess.Popen([BIN,"serve","--listen",f"127.0.0.1:{port}","--admin-token","adm","--data",d]+args,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(80):
        try: socket.create_connection(("127.0.0.1",port),0.2).close(); return p,d
        except OSError: time.sleep(0.1)
    raise SystemExit("no start")

def mode(path):
    import stat as _stat
    return oct(_stat.S_IMODE(os.stat(path).st_mode))[2:]

def req(port, method, path, body=b"", headers=None):
    c=http.client.HTTPConnection("127.0.0.1",port,timeout=10)
    c.request(method,path,body=body,headers=headers or {})
    r=c.getresponse(); b=r.read().decode(); c.close(); return r.status, b

ok=True
def check(name, got, want):
    global ok
    good = got==want; ok = ok and good
    print(("PASS " if good else "FAIL ")+name+" -> "+repr(got))

# 1. empty shared token must deny, not skip
p,d=start(["--cell-token",""],8101)
try:
    # state.db holds credential digests and blobs/ holds module source: the directory
    # that contains them must not be traversable by other local users.
    check("data dir is 0700", mode(d), "700")
    check("state.db is 0600", mode(os.path.join(d, "state.db")), "600")
    s,b=req(8101,"POST","/c/x/echo","hi")
    check("empty --cell-token denies", s, 401)
finally:
    p.terminate(); p.wait(); shutil.rmtree(d,ignore_errors=True)

# 2. revoking the last key must not re-open the cell
p,d=start([],8102)
try:
    s,b=req(8102,"POST","/c/k/fn","",{"X-Cellar-Token":"adm"})  # admin token is not a cell token
    st,body=req(8102,"POST","/admin/key?cell=k","",{"X-Cellar-Token":"adm"})
    kid=json.loads(body)["key_id"] if "key_id" in body else None
    s1,_=req(8102,"POST","/c/k/fn","x")
    check("keyed cell denies anonymous", s1, 401)
    st,body=req(8102,"POST",f"/admin/revoke?key_id={kid}","",{"X-Cellar-Token":"adm"})
    check("revoke accepted", st, 200)
    s2,_=req(8102,"POST","/c/k/fn","x")
    check("cell stays closed after last key revoked", s2, 401)
finally:
    p.terminate(); p.wait(); shutil.rmtree(d,ignore_errors=True)
print("ALL PASS" if ok else "FAILURES")
sys.exit(0 if ok else 1)
