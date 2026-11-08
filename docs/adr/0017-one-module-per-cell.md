# ADR-0017 — One module per cell.

*Context:* A cell owns one database and runs one piece of uploaded code. A deployment could be scoped per function, per cell, or per node. *Decision:* A cell runs exactly one module, named `default`, and a deploy replaces that module for exactly one cell. The blob is content-addressed, so identical source deployed to ten cells is one file; the registry records `(module, version)` rows so the audit trail survives even after the cell moves on. *Consequences:* No per-function granularity within a cell (that is a design decision, not a gap: a cell's functions share a transaction and a database, so deploying them independently would make one cell run code from two versions). Deploy and rollback are pointer operations over immutable blobs.

_Status: accepted. Immutable; supersede rather than edit._
