#!/usr/bin/env python3
"""G3b: work queued at SIGTERM must still finish.

The drain used to wait on the metrics gauge, which only moves when an invocation
*starts running*. With one shard, a second invocation queued behind a slow first one
was invisible: the gauge hit zero between the two, the drain exited, and the client
lost its response. The counter now moves at admission, so queued and deferred work
count too. This is that scenario, end to end.
"""

import http.client, os, shutil, signal, socket, subprocess, sys, threading, time
BIN=os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "zig-out", "bin", "cellar"); d="/tmp/dq"; shutil.rmtree(d, ignore_errors=True)
PORT=8791 + (os.getpid() % 60)
p=subprocess.Popen([BIN,"serve","--listen",f"127.0.0.1:{PORT}","--admin-token","t","--data",d,
                    "--shards","1","--deadline-ms","8000","--drain-ms","5000"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for _ in range(80):
    try: socket.create_connection(("127.0.0.1",PORT),0.2).close(); break
    except OSError: time.sleep(0.1)
res={}
def go(name, body):
    c=http.client.HTTPConnection("127.0.0.1",PORT,timeout=20)
    try:
        c.request("POST",f"/c/q/{name}",body=body); r=c.getresponse(); res[name]=(r.status, r.read().decode())
    except Exception as e: res[name]=("EXC", str(e))
    finally: c.close()
# slow one runs, the fast one queues behind it on the single shard
t1=threading.Thread(target=go,args=("work",b"1500")); t1.start()
time.sleep(0.1)
t2=threading.Thread(target=go,args=("echo",b"hi")); t2.start()
time.sleep(0.3)
p.send_signal(signal.SIGTERM)
t1.join(); t2.join()
p.wait(timeout=20)
ok = res.get("work")==(200,"done:1500") and res.get("echo")==(200,"echo:hi") and p.returncode==0

# An idle keep-alive socket must not hold up shutdown: it never observes `stopping`, so
# waiting on live connections burned the whole grace (9 s here) on every SIGTERM.
shutil.rmtree(d, ignore_errors=True)
p2=subprocess.Popen([BIN,"serve","--listen",f"127.0.0.1:{PORT+1}","--admin-token","t","--data",d,
                     "--deadline-ms","8000","--drain-ms","5000"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for _ in range(80):
    try: socket.create_connection(("127.0.0.1",PORT+1),0.2).close(); break
    except OSError: time.sleep(0.1)
idle=socket.create_connection(("127.0.0.1",PORT+1),5)
idle.sendall(b"GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n"); idle.recv(4096)
t0=time.time(); p2.send_signal(signal.SIGTERM); p2.wait(timeout=20); idle_dt=time.time()-t0
idle.close()
print("  idle shutdown", round(idle_dt,2), "s (grace would be 9 s)")
ok = ok and idle_dt < 3
print("  slow   ", res.get("work"))
print("  queued ", res.get("echo"))
print("  exit   ", p.returncode)
shutil.rmtree(d, ignore_errors=True)
print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
