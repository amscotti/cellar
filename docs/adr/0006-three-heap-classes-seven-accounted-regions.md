# ADR-0006 — Three heap classes, seven accounted regions.

*Context:* A long-running service leaks unless every allocation has an owner, a lifetime and a counter. *Decision:* Three heap classes — host, VM, SQLite — subdivided into seven regions (§4.5), each with one owner, one allocator, one lifetime, one budget and one counter. Request-path allocation comes from a per-invocation arena whose ownership transfers with the response. *Consequences:* Memory is observable by construction; a leak appears as a number before it appears as an OOM. The SQLite region is **process-global** (SQLite has no per-connection heap), and the plan says so instead of pretending otherwise.

_Status: accepted. Immutable; supersede rather than edit._
