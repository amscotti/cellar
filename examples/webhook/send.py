#!/usr/bin/env python3
"""Send signed webhooks the way Stripe does, and check what the cell answers.

    python3 examples/webhook/send.py [--url http://127.0.0.1:8199/c/hook/hook]

Exit code is 0 only if every assertion holds, so this doubles as the reference
app's test.
"""
import argparse
import hashlib
import hmac
import json
import sys
import time
import urllib.request

SECRET = b"whsec_demo_not_a_real_secret"


def sign(body: str, secret: bytes = SECRET, ts: int | None = None) -> str:
    t = ts if ts is not None else int(time.time())
    mac = hmac.new(secret, f"{t}.{body}".encode(), hashlib.sha256).hexdigest()
    return f"t={t},v1={mac}"


def post(url: str, payload: dict, signature: str | None = None) -> str:
    body = json.dumps(payload)
    req = urllib.request.Request(url, data=body.encode(), method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Stripe-Signature", signature or sign(body))
    with urllib.request.urlopen(req, timeout=5) as r:
        return r.read().decode()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8199/c/hook/hook")
    ap.add_argument("--count-url", default=None)
    args = ap.parse_args()
    count_url = args.count_url or args.url.rsplit("/", 1)[0] + "/count"

    event = {"id": "evt_1", "type": "payment.succeeded", "amount": 4200}
    body = json.dumps(event)

    checks = []

    got = post(args.url, event)
    checks.append(("first delivery accepted", got == "accepted:evt_1", got))

    got = post(args.url, event)
    checks.append(("second delivery deduplicated", got == "duplicate:evt_1", got))

    # Re-sign a *different* body with the right secret: accepted under a new id.
    got = post(args.url, {"id": "evt_2", "type": "payment.succeeded"})
    checks.append(("a different event is accepted", got == "accepted:evt_2", got))

    # Same signature, tampered body: the HMAC no longer matches.
    tampered = body.replace("4200", "9999")
    got = post(args.url, json.loads(tampered), signature=sign(body))
    checks.append(("tampered body rejected", got == "reject:bad signature", got))

    # Correctly signed but from an hour ago: replay window closed.
    old = sign(body, ts=int(time.time()) - 3600)
    got = post(args.url, event, signature=old)
    checks.append(("stale timestamp rejected", got == "reject:stale timestamp", got))

    # No signature at all.
    req = urllib.request.Request(args.url, data=body.encode(), method="POST")
    with urllib.request.urlopen(req, timeout=5) as r:
        got = r.read().decode()
    checks.append(("unsigned request rejected", got == "reject:missing signature", got))

    with urllib.request.urlopen(count_url, data=b"", timeout=5) as r:
        count = r.read().decode()
    checks.append(("exactly two rows stored", count == "2", count))

    ok = True
    for name, passed, got in checks:
        print(f"  {'PASS' if passed else 'FAIL'}  {name:<32} -> {got}")
        ok = ok and passed
    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
