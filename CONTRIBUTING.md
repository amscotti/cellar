# Contributing

## Prerequisites

- **Zig 0.17.0 exactly.** The code uses `std.Io.*` spellings that older (and
  newer) releases do not have. CI pins the same version.
- **Linux** (x86_64/aarch64) is the deployment target and runs the gates in
  CI. **macOS (arm64)** builds and passes `zig build test` natively — day-to-day
  development works there; run the gate suite on Linux (or in a container)
  before merging. Cross-compile with
  `zig build -Dtarget=x86_64-linux-gnu` (or `aarch64-linux-gnu`).
- No system SQLite or Lua needed: SQLite is vendored in `vendor/sqlite3`,
  Lua 5.4 comes from the pinned `zlua` package. The first `zig build` needs
  network to fetch `zlua`.

## Build and test

```bash
zig build                 # debug binary in zig-out/bin/
zig build test            # unit tests (zero leaks expected)
bash gates/run.sh         # L1, L2, G1–G10 against a ReleaseSafe build
zig fmt --check src/      # formatting (CI enforces)
```

`gates/run.sh` rebuilds ReleaseSafe itself, so a stale `zig-out` cannot make
a gate lie. Gate output lands in `gates/evidence/` (git-ignored).

Before claiming anything works, run the full gate suite.

## Conventions

- Commits: conventional prefixes (`feat:`, `fix:`, `docs:`, `test:`), and the
  body explains *why* the change is correct, not just what moved.
- Code, tests and comments never cite plan phases or task ids
  (`gates/check-no-plan-refs.sh` enforces this).
- Only `src/vm/*.zig` and `src/store/sqlite.zig` may touch C headers
  (`gates/check-layers.sh`).
- Placement decisions go through `Locator` only
  (`gates/check-locator.sh`).
- Every fix gets a test or gate assertion that fails without it.
- Run `zig fmt src/` before committing.

## Reading order

1. `README.md` — what it is, what it is not.
2. `docs/HANDOFF.md` — operations guide and architecture map.
3. `docs/BINDINGS.md` — the guest API contract.
4. `docs/DECISIONS.md` — product decisions vs Durable Objects / celld /
   Rivet / Orleans.
5. `docs/adr/` — one short record per irreversible choice.
6. `docs/CLUSTER.md` — the (unimplemented) cluster design the seams exist for.
