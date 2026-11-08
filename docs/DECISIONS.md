# Decisions — what the incumbents do, and what cellar will do

Research done against vendor documentation first, vendor source where the docs are
silent, with celld as the control case (self-hosted Durable Objects on SQLite plus
object storage). One pattern runs through all seven: **bound the unit of work, not the
socket.** No product documents a default fetch *read* timeout; what they bound is the
invocation or the transaction.

Per-decision sources are linked inline below.

## 1. Bounding a parked fetch — adopted

| Product | Bound | What happens on expiry |
|---|---|---|
| Cloudflare DO | No wall-clock limit while I/O is in flight; a 30 s watchdog covers *storage* operations only | Object reset; committed writes survive |
| celld | 30 s on a transaction and on `blockConcurrencyWhile()` | Object reset, open transaction rolled back |
| Rivet | `actionTimeout` 60 s | Action fails, actor keeps running, state saved every 1 s |

[DO lifecycle](https://developers.cloudflare.com/durable-objects/concepts/durable-object-lifecycle),
[celld DO](https://celld.dev/docs/services/durable-objects),
[Rivet limits](https://rivet.dev/docs/actors/limits)

**Decision.** One deadline per *invocation*, not per fetch: `min(guest timeout_ms or
30 s, remaining budget)`, hard cap 60 s. When it expires, the runtime **aborts** the
invocation — drops the coroutine, rolls back the transaction, answers 504 — instead of
handing the guest a catchable error. Transport errors stay catchable; only the deadline
aborts. Never auto-retry a timed-out fetch: a POST may already have been applied
upstream. The alarm retry counter is committed *after* the rollback, or a poison alarm
retries forever (6 attempts, 2 s exponential, then dead-letter — the shape Cloudflare
documents for [alarms](https://developers.cloudflare.com/durable-objects/api/alarms/)).

Why abort rather than resume-with-error: cellar's strongest primitive is that exactly
one transaction is open per invocation. Keeping that true under a timeout means the
timeout has to end the invocation, not become a value the guest can ignore.

## 2. Deploy acknowledgement — adopted

Workers separates an immutable **version** from a **deployment** that points traffic at
it ([versions](https://developers.cloudflare.com/workers/versions-and-deployments/));
celld keeps a `deploy/current.json` pointer and adopts it atomically.

**Decision.** The durable pin *is* the acknowledgement. Upload the blob (idempotent),
insert an immutable deployment row, flip the active pointer in one registry
transaction, and only then return 200 with `{deploy_id, module_hash,
previous_deploy_id}`. On failure return 5xx and leave the old pointer untouched.
`meta.json` becomes a cache written after the commit, carrying `deploy_id`; when it
disagrees with the registry, the registry wins and meta is rewritten. GC must never
delete the active or previous deployment or their blobs.

## 3. Eviction — adopted

DO hibernates after ~10 s idle and evaporates after 70–140 s
([lifecycle](https://developers.cloudflare.com/durable-objects/concepts/durable-object-lifecycle));
Rivet sleeps after 30 s and offers `keepAwake`; Orleans uses 15 min with 80/75 memory
hysteresis ([Orleans](https://learn.microsoft.com/en-us/dotnet/orleans/host/configuration-guide/activation-collection)).

**Decision.** Idle-only LRU with hysteresis. Update `last_active` at the end of every
invocation; never consider a cell with an open invocation, including a parked fetch;
evict at ≥60 s idle, oldest first, stopping at 90 % of `--max-cells`; skip cells with an
alarm due within 60 s; at most 4 evictions per tick, scanned every ~5 s. If the cap is
reached with nothing evictable, reject the activation with 503 + `Retry-After` — never
evict a busy cell. A cap that can only be honoured by evicting busy cells is a deadlock,
not a cap.

## 4. Snapshots — adopted

Litestream ships WAL continuously with 24 h snapshots and 24 h retention
([config](https://litestream.io/reference/config/)); DO offers 30-day PITR for SQLite
objects; Turso backs up at every commit.

**Decision.** Scheduled, not per request: every 6 h, jittered by cell hash, `VACUUM INTO`
on the cell thread between invocations, skipping and rescheduling when busy or parked.
Retain 7 per cell, prune oldest first and only after the replacement row is durable.
`POST /admin/snapshot` stays as a manual trigger. Snapshot-per-request turns a read into
a write of the whole database, serialized on the cell thread — that is the trap.

## 5. Admin auth — partially adopted

Self-hosted cohort converges on one bootstrap secret exchanged for a session
(Supabase dashboard user/password, Convex admin key) plus a bearer header for machines;
Grafana documents the cookie hardening
([Grafana](https://grafana.com/docs/grafana/latest/setup-grafana/configure-security/configure-security-hardening)).

**Decision (target).** Browser: `POST /admin/session` with the token in the body sets an
opaque `__Host-` cookie (12 h, only its hash stored server-side); mutations require the
cookie plus a same-origin `Origin` or `Sec-Fetch-Site`. Machines: `Authorization: Bearer`,
never a cookie. `GET /admin?token=` survives only as a one-time bootstrap that sets the
cookie and 303s with the token stripped.

Already done: `?token=` is refused on reads. Still to do: stop storing the raw token in
the cookie (a stolen cookie is currently the root credential), and require the cookie for
mutations.

## 6. Outbound allowlist — adopted in part (process-level today)

Cloudflare's `globalOutbound: null` plus a gateway worker is the right shape: policy
attached to loaded code at one interception point
([egress control](https://developers.cloudflare.com/dynamic-workers/usage/egress-control/)).
Deno's `--allow-net` is per process, so it cannot express per-cell policy.

**Target.** `fetch_allow` in the deployment record (immutable, versioned), enforced in
the single outbound path before parking: unset inherits `--allow-fetch`, empty denies,
`*` allows, otherwise exact host or `*.suffix` on a label boundary; lowercase, port
stripped, userinfo rejected, and redirects re-enter the check. Because it is deployment
state, rollback would restore it with the code.

**Implemented today** (the process-level subset, in `src/runtime/fetch.zig`):
`--allow-fetch` gates the capability; the URL must be `http`/`https` without userinfo;
loopback/private/link-local/metadata address literals are refused unless
`--fetch-allow-private` is set; `--fetch-allow-host` provides the exact/`*.suffix`
allowlist; redirects are not followed, so a guest follow-up fetch re-enters the check.
Per-cell (deploy-time) lists are not built yet. Not a security boundary: the guest is
trusted, and a hostname check does not stop DNS rebinding.

## 7. Observability — adopted, cheap parts only

Workers trace events carry outcome, CPU/wall time, script and version
([trace events](https://developers.cloudflare.com/logs/logpush/logpush-job/datasets/account/workers_trace_events/));
celld emits an OTel span per cell event and propagates W3C `traceparent`.

**Decision.** Keep one JSON line per invocation on stderr, adding the fields that answer
why-slow and why-failed: `ts, inv_id, trace_id, span_id, cell, shard, deploy_id, kind,
outcome, dur_ms, queue_ms, fetch_ms, fetch_n, db_ms, rows, req_bytes, resp_bytes`.
Accept an incoming `traceparent`, otherwise generate one per invocation and propagate it
on outbound fetches. Sample 100 % of errors/timeouts/aborts and invocations over 1 s, 1 %
of the rest.

## Numbers adopted

| Knob | Value | Precedent |
|---|---|---|
| Invocation deadline | 30 s default, 60 s hard cap | celld 30 s transaction cap; Rivet 60 s action |
| Connect timer | 5 s, classification only | Rivet 5 s connect-phase hook |
| Idle evict threshold | 60 s, stop at 90 % of cap | Orleans 80/75 hysteresis; DO 10 s–140 s |
| Snapshot interval / retention | 6 h / 7 per cell | Litestream 24 h/24 h; DO PITR 30 d |
| Alarm retries | 6, 2 s exponential | Cloudflare alarms |
| Admin session TTL | 12 h | — |
| Success log sample | 1 % | celld `traceidratio` |

## Explicitly not doing (POC)

PITR/WAL shipping/replication; memory-pressure LRU; gradual deploys or traffic
splitting; more than one deadline and one connect timer; synchronizer CSRF tokens;
allowlist UI or DNS pinning (metadata/private address *literals* are blocked — see §6);
OTLP collector, span storage, log
search; deploy signing or an audit log; hibernatable WebSockets; cross-node rebalancing.
