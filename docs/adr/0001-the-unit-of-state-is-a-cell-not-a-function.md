# ADR-0001 — The unit of state is a cell, not a function.

*Context:* A Lambda-style model makes "function" the unit of deployment and leaves state homeless, forcing a shared database. *Decision:* Storage belongs to a named cell. Many functions share one cell's database; one function may run in thousands of cells, each with its own database. The key is chosen by the caller and mapped to `id = hex(sha256(utf8(key)))`. *Consequences:* No cross-cell queries; the key is the tenancy boundary; a hot cell is a single-threaded bottleneck by construction (documented, not accidental).

_Status: accepted. Immutable; supersede rather than edit._
