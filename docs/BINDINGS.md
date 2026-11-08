# Guest bindings

The host binding surface every VM backend must provide (ADR-0002). Lua 5.4
via `zlua` is the only backend today (`src/vm/lua.zig`); a new backend is
accepted by running the same conformance inputs against this surface.

A module is a Lua chunk that returns a table of functions. Handlers are
called as `M.handler(body, headers)` where `body` is the request body string
and `headers` is a table with lowercased names. The handler returns a string
(the response body). Raising a Lua error rolls the whole invocation back.

`db`, `alarm`, and `http` are installed after the module chunk has run, so
top-level code cannot touch the database: only code executing inside an
invocation transaction can (ADR-0004). `json`, `crypto`, `time`, and `log`
are pure and available from the start.

## `db` — the cell's own SQLite database

All statements run inside the one transaction of the current invocation.
Parameters are bound (`?` placeholders), never interpolated by the host.
Only a single statement per call is accepted; multi-statement strings are
refused instead of half-executed.

| Function | Returns |
|---|---|
| `db.exec(sql, ...)` | array of row tables keyed by column name |
| `db.one(sql, ...)` | first row as a table, or `nil` |
| `db.value(sql, ...)` | first column of the first row, or `nil` |
| `db.run(sql, ...)` | number of rows changed (`sqlite3_changes64`) |

A SQLite authorizer rejects `TRANSACTION`, `SAVEPOINT`, `ATTACH`, `DETACH`
and `PRAGMA` coming from guest SQL, and `load_extension` is compiled out
(`-DSQLITE_OMIT_LOAD_EXTENSION`). The guest cannot end, split, or escape its
transaction.

## `json`

| Function | Notes |
|---|---|
| `json.encode(v)` | Lua value → JSON string. `inf`/`nan` encode as `null`. Depth-bounded. |
| `json.decode(s)` | JSON string → Lua value |
| `json.null` | sentinel table for JSON `null` (Lua tables cannot hold `nil` without losing array length) |

## `crypto`

| Function | Returns |
|---|---|
| `crypto.sha256(s)` | hex digest |
| `crypto.hmac_sha256(key, s)` | hex digest |
| `crypto.random(n)` | `n` bytes (1..32) as hex, from `getrandom(2)` |

## `time`

| Function | Returns |
|---|---|
| `time.now_ms()` | wall-clock milliseconds |
| `time.now_s()` | wall-clock seconds |

## `alarm`

One alarm per cell, stored in the cell's own database inside the invocation
transaction: an alarm belonging to a rolled-back write does not exist. When
it fires, the runtime invokes `on_alarm(payload)` as an ordinary invocation.

| Function | Notes |
|---|---|
| `alarm.set(delay_ms)` | arm (or replace) the alarm; delay is bounded to 10 years |
| `alarm.get()` | due time, or `nil` |
| `alarm.clear()` | disarm |

## `log`

`log.info(...)`, `log.warn(...)`, `log.error(...)` write to stderr tagged with
the cell key. Log output is never mixed into the response body.

## `http` — outbound fetch (capability, off by default)

Available only when the operator starts the server with `--allow-fetch 1`;
otherwise `http.fetch` raises `outbound network is not enabled`.

```lua
local ok, body_or_err = http.fetch(url, {
  method = "GET",        -- GET POST PUT DELETE PATCH HEAD
  body = "",             -- request body
  timeout_ms = 5000,     -- still bounded by the invocation deadline
})
```

The call suspends the guest (the transaction stays open, the shard thread is
freed) and resumes with `(true, body)` on success or `(false, err)` on
transport/policy failure. An invocation-deadline expiry aborts the whole
invocation instead of returning a catchable error.

Egress policy (enforced in `src/runtime/fetch.zig`, URL-literal check):

- scheme must be `http` or `https`; URLs carrying userinfo are refused;
- by default, loopback, private (RFC1918), link-local (including the cloud
  metadata address `169.254.169.254`), CGNAT and reserved addresses are
  refused, as are `localhost` and ambiguous numeric host forms;
- `--fetch-allow-host host,*.suffix` (repeatable) restricts fetches to an
  allowlist; `*.suffix` requires a label boundary;
- `--fetch-allow-private 1` lifts the private-address block — only on a
  fully trusted network;
- redirects are never followed by the runtime: the guest receives the 3xx,
  and a follow-up fetch re-enters the policy check;
- the check cannot see DNS, so a public hostname that *resolves* to a private
  address (rebinding) is not stopped here. Guests are trusted (README,
  "Exposure"); this is a foot-gun guard, not a sandbox boundary.

## What guests do not get

No `io`, `os`, `package` or `debug`; `load`/`loadfile`/`dofile` are nil;
`collectgarbage` is nil and `setmetatable` refuses a `__gc` field. There is
no filesystem or environment access. A cell's only durable state is its
database; its only way out is the response (plus `http.fetch` when the
operator grants it).
