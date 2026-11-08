# Security policy

## Supported versions

cellar is a proof of concept; only the `main` branch receives fixes.

## Threat model (read this before exposing it)

**Guest code is trusted.** The Lua VM enforces deadlines, a memory cap, and a
curated library set as *availability* guards. They are not a security
boundary: do not accept uploads from untrusted users, and do not treat one
cell's code as isolated from the process beyond its own database and
transaction.

Defaults reflect that model: the data plane (`/c/...`) is open unless
`--cell-token` or per-cell keys are configured, admin reads are open only on
loopback, and `http.fetch` is off unless `--allow-fetch` is set (with
private/metadata address literals blocked by default — see
`docs/BINDINGS.md`). Terminate TLS at a reverse proxy; cellar speaks plain
HTTP.

## Reporting a vulnerability

Please report suspected vulnerabilities privately to the repository owner
(GitHub private vulnerability reporting on this repository) with a minimal
reproduction. Do not open a public issue for an exploitable bug.
