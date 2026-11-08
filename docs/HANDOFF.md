# Operations guide

Everything needed to build, run, and operate cellar. Start with
**Quickstart**, then **What is actually proven**, and only then the design docs.

## What this is

A single Zig binary that hosts uploaded Lua functions where every named **cell** owns its
own SQLite database and is served by exactly one shard thread at a time. Same cell key →
same database → same thread → serialized. A cell's state lives in its database, not in the
process, so a cell can be evicted, restarted, or moved (the directory is self-contained)
and come back knowing everything. Each invocation runs inside exactly one SQLite
transaction that the guest cannot end.

The shape is Cloudflare Durable Objects / Deno's `celld`. It is a **proof of concept**:
guest code is trusted (see "Exposure" in the README), there is no cluster yet, and the
availability guarantees are per-process.

## Status

| | |
|---|---|
| Tests | `zig build test`, zero leaks |
| Gates | 12 checks — L1, L2, G1–G10 (plus G15 at `gates/run.sh 3`) |
| Binary | ReleaseSafe, size ceiling 20 MiB enforced by G2 (`gates/thresholds.toml`) |
| Code | Zig in `src/`; see the architecture map below |
| History | `CHANGELOG.md`; design rationale in `docs/adr/` |

## Quickstart

```bash
# Requires Zig 0.17.0 (see "Toolchain"). SQLite is vendored; there is no other dependency.
zig build                       # debug; gates build ReleaseSafe themselves

# Durable admin token (keeps the secret out of argv and survives restarts):
printf '%s' "$(openssl rand -hex 16)" > ./admin-token && chmod 600 ./admin-token
./zig-out/bin/cellar serve --listen 127.0.0.1:8080 --data ./data --admin-token-file ./admin-token
# Without a token source, serve generates one and prints it once at startup.

# In another shell — the CLI speaks the same HTTP API:
./zig-out/bin/cellar deploy examples/webhook/app.lua --cell room --token-file ./admin-token
./zig-out/bin/cellar invoke room join ada --token-file ./admin-token
curl -s localhost:8080/healthz | head -c 400
open http://127.0.0.1:8080/admin          # dashboard; unlock once with ?token=<hex>
```

`./zig-out/bin/cellar doctor` prints a read-only sanity report (config,
data directory, credential durability, fetch posture) without starting the
server.

Run everything the project claims:

```bash
zig build test            # unit tests, zero leaks
bash gates/run.sh         # L1,L2,G1-G10; evidence in gates/evidence/ (git-ignored)
```

## Toolchain

- **Zig 0.17.0** exactly — this code uses `std.Io.*`, `std.Io.Dir`, `@splat` and other
  0.17 spellings; other releases will not compile. Unpack the 0.17.0
  tarball anywhere and put `zig` on `PATH` (CI uses `mlugg/setup-zig`).
- **Lua 5.4** via the `zlua` package (pinned by commit + hash in `build.zig.zon`; fetched
  by `zig build`, so the first build needs network).
- **SQLite**, vendored in `vendor/sqlite3` and compiled in — no system SQLite.
- **Linux (x86_64 and aarch64) is the supported deployment target; macOS
  (arm64) builds and passes the full unit suite locally** — develop on
  either, deploy on Linux. OS primitives (entropy, clocks, fsync, chmod)
  go through `src/util/sys.zig` plus the `std.Io` APIs, so there is no
  Linux-only syscall surface left outside that one file's Linux branch.
  The gate scripts are Linux-oriented (GNU `stat`, signal drills), so CI
  runs them on Ubuntu; on macOS run `zig build test` plus a serve smoke.
  Windows is unsupported.

## Using it

| Action | How |
|---|---|
| Deploy | `POST /admin/deploy?cell=K` with the Lua source as the body (admin token), or the CLI. A module is a chunk that returns a table of functions. |
| Invoke | `POST /c/<cell>/<fn>` with the body as the argument; the handler returns a string. |
| Auth | Control plane: `--admin-token-file` (preferred), `--admin-token`, or `CELLAR_ADMIN_TOKEN`; a random token is generated if none is set. Data plane: `--cell-token(-file)` / `CELLAR_CELL_TOKEN` (off by default = open). Per-cell keys: `POST /admin/key?cell=K` returns a token **once**; a keyed cell ignores the shared token. Client: `--token-file` / `CELLAR_TOKEN`. |
| Fetch | Off unless `--allow-fetch 1`; private/metadata addresses blocked, redirects not followed. `--fetch-allow-host` allowlist, `--fetch-allow-private` for trusted networks. See `docs/BINDINGS.md`. |
| Rate limit | `--rate-per-s N --rate-burst B`, keyed on the cell. |
| Snapshot | `POST /admin/snapshot?cell=K` → `data/snapshots/<cell>-<unix>.db` (`VACUUM INTO`, on the cell's thread). |
| Restore | Stop; replace `cells/<digest>/db.sqlite` **and delete `-wal`/`-shm`**; start. `gates/snapshot.py` is the drill. |
| GC | `POST /admin/gc?keep=N` prunes deployment rows to the newest N per module and deletes unreferenced blobs (never a blob a cell, a deployment row or a `meta.json` pin names). |
| Metrics / logs | `GET /metrics` (Prometheus text) and one JSON line per invocation on stderr, correlated by `x-cellar-invocation`. |
| Keys / rotation | `POST /admin/key?cell=K` then `POST /admin/revoke?key_id=ID`; revoking is idempotent (200 `revoked:false` on a retry). |

## Data directory

```
data/
  state.db            control plane: cells, deployments, credentials (WAL, synchronous=FULL)
  blobs/<sha>.bin      module source, content-addressed, hash-verified on read
  cells/<sha256(key)>/ one directory per cell: key, db.sqlite (+ -wal/-shm), meta.json
  snapshots/           VACUUM INTO copies, one per manual snapshot request
```

The whole directory is **relocatable** — `gates/coldstart.py` moves a populated one and
starts there. Delete `zig-out/`, `.zig-cache/` freely; never delete `state.db` without
reading "state.db loss" in `gates/restart.sh` (a cell directory can rebuild a cell from
`meta.json`, and that path is tested).

## Architecture in one pass

`src/http/server.zig` accepts a connection, parses a request, applies framing/auth/rate
checks, and for `/c/...` builds an `Invocation` and submits it to a shard. The shard is a
hash of the cell key (`Scheduler.submit`), so every invocation for one cell lands on one
thread. The shard thread (`Shard.loop`) opens the cell if needed (`cellFor`: claim the
directory, open SQLite, load the pinned module from the blob store, arm its alarm),
begins a transaction, runs the guest on a fresh Lua coroutine, and either commits or rolls
back. `http.fetch` inside the guest parks the cell (transaction still open) and hands the
request to a worker pool; a completion resumes the coroutine, and a reaper aborts it if
the invocation deadline passes first. Deploys are ordinary queue jobs (`swap_src`), so a
swap is ordered against invocations at dequeue.

| Path | Responsibility |
|---|---|
| `src/cli.zig`, `src/config.zig` | argument parsing, limits, flags |
| `src/http/server.zig` | HTTP/1.1, routing, admin auth, SSE, drain |
| `src/http/admin.zig` + `index.html` | dashboard: escape, substitute, tables, form deploy |
| `src/runtime/scheduler.zig` | shards, queues, invocation lifecycle, cells, deploy, alarms, snapshot |
| `src/runtime/registry.zig` | `state.db`; single writer thread; published immutable `Catalog` |
| `src/runtime/fetch.zig` | blocking HTTP(S) via `std.http.Client`, on the pool |
| `src/runtime/locator.zig`, `membership.zig`, `gossip.zig` | local/remote decision; SWIM state + wire format (no transport) |
| `src/store/sqlite.zig` | WAL, statement cache, authorizer, progress handler |
| `src/store/blob.zig`, `meta.zig`, `paths.zig` | content-addressed blobs; cell metadata; directory naming + claim |
| `src/vm/lua.zig`, `lua_bindings.zig`, `stdlib.zig` | the VM seam, `db.*`, guest `json/crypto/time/log/alarm` |
| `src/util/` | arena allocator, bounded JSON escaping, rate limiter |

## What is actually proven

Every claim below is a gate or a test, not an assertion in prose. That is the point of the
gate list — keep it that way when you change something.

| Gate | What it proves |
|---|---|
| L1 | No code, test or comment cites a plan phase or task id |
| L2 | Only `src/vm/*` and `src/store/sqlite.zig` touch C headers |
| G1 | `zig build test` — unit tests, zero leaks |
| G2 | `ReleaseSafe` builds, `--version` is sane, binary ≤ 20 MiB |
| G3 | SIGTERM: in-flight and queued work finishes, new work gets 503, exit 0; idle keep-alive sockets do not delay shutdown |
| G4 | Per-cell rate limit: burst honoured, every 429 carries `retry-after`, another cell unaffected |
| G5 | Auth edges: per-cell keys, rotation, empty shared token denies, revoked-last-key keeps the cell closed, cookie mutations need same origin |
| G6 | SIGKILL mid-write: `integrity_check` ok, rows ≥ acknowledged |
| G7 | Snapshot → staleness → stop → restore (deleting `-wal`/`-shm`) → rows are the snapshot's, and the cell still writes |
| G8 | Deploy pins; GC keeps every blob a cell or `meta.json` still names; a missing pin is `ModuleUnavailable`, not the fixture; a deploy can repair it |
| G9 | HTTP/VM edges: CL.0, TE+CL, `Transfer-Encoding :` and `gzip`, token scope, revoke 404/idempotency, runaway SQL interrupted, silent upstream 504 at the deadline, `pcall` cannot swallow it |
| G10 | Cold start, data-directory relocation, fresh install |

## Invariants the code enforces

These hold **today**, each with the thing that checks it. (The surviving
numbered invariants I9/I10/I14/I15/I16 are summarised in the README; the ADRs
carry the rationale.)

- **One owner per cell at a time.** Only the owning shard thread touches a cell's VM,
  SQLite handle or arena; a parked cell defers further invocations rather than sharing an
  open transaction (`Shard.loop`, `deferred`).
- **One transaction per invocation.** The authorizer denies `TRANSACTION`, `SAVEPOINT`,
  `ATTACH`, `DETACH`, `PRAGMA`; `gates/regress.py` and `store/db_test.zig` prove a guest
  `COMMIT` fails and a rollback leaves no rows.
- **Arena has exactly one owner**, handed over with `give`/`take`; a shed or timed-out
  invocation is never handed back early.
- **No guest code can kill the process.** Guest lookups run under `lua_pcall`, table
  reads are raw, `load`/`loadfile`/`dofile`/`collectgarbage` are absent, `__gc` is refused,
  and `alarm.set` is range-checked.
- **Cell keys cannot escape their directory**: the directory is the full hex digest, a key
  file is checked on open, mode 0700.
- **Blobs are immutable and verified** on read; a torn or mismatched file is refused
  rather than executed.
- **A deploy is acknowledged only after its pin is durable**; a failed load leaves no pin
  (ADR-0022).
- **The catalog is borrowed, never owned**: a slice from `Registry.lock()` is valid only
  while the lock is held — copy before unlocking (ADR-0023).

## Known limits (do not rediscover these)

- A **catastrophic Lua pattern** runs in C with no preemption and blocks its shard until
  the process restarts. An external watchdog is the fix; it is not built.
- No socket read/write timeouts; a client can hold a connection (bounded by `--max-conns`).
- `--max-cells` is per shard, so the ceiling is `shards × max_cells`.
- Deploys are always local, even when `Locator` says remote.
- Eviction is LRU under a cap, not the idle-with-hysteresis policy in `docs/DECISIONS.md`
  (that is the target, not the current behaviour).
- The admin session is still the raw token in a cookie; `docs/DECISIONS.md` §5 describes
  the session-token design that should replace it if cells ever return HTML.
- Cluster membership/gossip (`membership.zig`, `gossip.zig`, `gossip_net.zig`) is
  implemented and tested as pure state machines but has no transport and is not wired
  into the serving path beyond `Locator` placement (see `docs/CLUSTER.md`).

## Reading order

See `CONTRIBUTING.md` ("Reading order"). In short: README → this guide →
`docs/BINDINGS.md` → `docs/DECISIONS.md` → `docs/adr/` → `docs/CLUSTER.md`
(the design the seams exist for; transport, lease and handoff are not
implemented).

## Conventions

See `CONTRIBUTING.md`. The short version: conventional commits explaining
*why*; no plan-phase citations in code (L1); new C only in `src/vm/*` and
`src/store/sqlite.zig` (L2); every fix gets a test or gate assertion that
fails without it; run `bash gates/run.sh` before claiming anything works —
it rebuilds ReleaseSafe, so a stale `zig-out` cannot make a gate lie.
