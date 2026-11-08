# ADR-0003 — Thread-per-shard, cells pinned, no shared state.

*Context:* SQLite with `THREADSAFE=0` and all VM state are unsafe to share. *Decision:* Fixed `--shards N` worker threads. `Scheduler.submit` is a **pure enqueue**: it takes a `cell_key`, computes the shard, pushes onto that shard's queue, and returns — it never reads or writes cell state and never triggers a load. The shard loop resolves residency itself; the first queued invocation for a cold cell loads it inline, so every later queued invocation observes `ready`. Only the owning shard touches a cell's VM, SQLite handle, or arena. Cross-thread communication is a queue plus a sticky `std.Io.Event`, never a mutex around cell data. *Consequences:* No cell-level locks; the cold-start race cannot happen because there is exactly one loader thread by construction; scale-out is more shards or more processes.

_Status: accepted. Immutable; supersede rather than edit._
