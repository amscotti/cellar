# ADR-0012 — Guest response fields are validated by the host encoder.

*Context:* `std.http.Server.respond` asserts on `status == .@"continue"` without a `runtime_safety` guard, asserts on CR/LF in header names and values in safety builds, and `http.Status` is `enum(u10)`, so a guest-supplied 2000 traps. `gates/check-no-panic.sh` cannot see stdlib asserts. *Decision:* `src/http/response.zig` is the only caller of `respond`/`respondStreaming`. It rejects 1xx and any status outside 200–599, rejects CR/LF and `:` in header names, rejects guest attempts to set `content-length`/`connection`/`transfer-encoding`, caps header count (32) and total bytes (8 KiB), and frames the body itself. *Consequences:* A hostile or confused guest produces a 500, never an abort or a response split.

_Status: accepted. Immutable; supersede rather than edit._
