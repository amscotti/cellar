# Changelog

All notable changes to this project. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions are the
`cellar --version` string.

## [Unreleased]

### Security

- `http.fetch` now enforces an egress policy: only `http`/`https`, no
  URL userinfo, and by default no loopback/private/link-local/metadata
  addresses. Redirects are returned to the guest instead of followed.
  New flags: `--fetch-allow-host` (allowlist) and `--fetch-allow-private`
  (trusted networks only). See `docs/BINDINGS.md`.
- The dashboard cookie now carries `Secure` when the request arrived over
  HTTPS (`X-Forwarded-Proto`) or the listener is not loopback; override with
  `--cookie-secure`.
- Admin error responses no longer leak raw Zig error names; failures are
  logged server-side and answered with a generic `internal` envelope.

### Added

- macOS (arm64) and aarch64-Linux builds: OS primitives moved behind
  `src/util/sys.zig` (entropy, clocks, fsync) and the `std.Io` permissions
  APIs, and SQLite text/blob binds now spell out `SQLITE_TRANSIENT`'s copy
  semantics with a real destructor instead of the `(destructor)-1` sentinel
  Zig cannot materialise on aarch64. `zig build && zig build test` passes
  natively on macOS; gates remain Linux/CI.
- `LICENSE` (MIT).
- `cellar doctor`: read-only config/data-dir/credential sanity report.
- Durable token sources that keep secrets out of `ps`:
  `--admin-token-file` / `--cell-token-file` and `CELLAR_ADMIN_TOKEN` /
  `CELLAR_CELL_TOKEN` for `serve`; `--token-file`, `CELLAR_TOKEN` and
  `CELLAR_SERVER` for the client commands.
- `docs/BINDINGS.md` (the guest API contract referenced by ADR-0002),
  `CONTRIBUTING.md`, this changelog, and a CI workflow
  (`.github/workflows/ci.yml`: fmt check, `zig build test`, gates).

### Fixed

- `--peers` accepts comma-joined values (`--peers a@h:1,b@h:2`); previously
  the joined string was stored as one entry and placement silently fell
  back to local.
- Registry hygiene carried over from the last internal review round:
  `keyExists` propagates database errors instead of reporting "never
  issued"; `Registry.open` closes the database handle when startup fails
  after opening it; the credential migration probes `sqlite_master`
  instead of attempting the copy on every start; the revoke path resets
  its statement before preparing the existence probe.

### Removed

- Internal build journals (`docs/PLAN.md`, `docs/NIGHTLOG.md`,
  `docs/REVIEWS*.md`). The durable record is the code, the gates, and
  `docs/adr/`; the one still-open item from those notes (below) is tracked
  here instead.
- Tracked test/probe runtime directories and `gates/evidence/` outputs are
  no longer in the index (they were committed despite `.gitignore`).

### Known open items

- A catastrophic Lua regexp pattern runs in C with no preemption and holds
  its shard until the process restarts; an external watchdog is the planned
  fix and is not built yet.

## [0.1.0]

Initial proof of concept: single Zig binary hosting Lua 5.4 functions where
every named cell owns its SQLite database on one shard thread; dashboard,
CLI, per-cell keys with rotation, rate limiting, snapshots, blob GC,
metrics, and the L1/L2/G1–G10 gate suite. 24 ADRs in `docs/adr/`.
