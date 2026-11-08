# ADR-0013 — One `Snapshot`, one producer.

*Context:* The dashboard, the SSE stream, `/healthz` and the review gate "every number on screen is also in the health JSON" cannot all be true if each path queries its own source. *Decision:* A ticker thread builds a `Snapshot` once per second (counters, rate ring, per-cell last-observed values), publishes it by atomic pointer swap, and every reader — HTML render, SSE event, `/healthz` — reads that same struct. *Consequences:* Per-render cost is O(cells) pointer reads; the review gate holds by construction; stale per-cell values are labelled "last observed".

_Status: accepted. Immutable; supersede rather than edit._
