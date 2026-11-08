# ADR-0023 — The registry publishes an immutable catalog behind a reader lock.

*Context:* HTTP threads read cells, deployments and key digests on every request while a single writer thread applies deploys and pins. Reading SQLite per request would put the control-plane database on the data-plane hot path. *Decision:* One writer thread applies jobs and rebuilds an immutable `Catalog`; publication swaps a pointer, readers take `read_mu` for as long as they use it, and retired catalogs are freed under that same lock. *Consequences:* Reads are O(1) and allocation-free, and the writer never blocks a reader for longer than a pointer swap. The rule that follows is absolute: a slice borrowed from the catalog is valid only while `read_mu` is held — copy it into the request arena before unlocking. Two use-after-free bugs came from breaking that rule, which is why it is stated here rather than in a comment.

_Status: accepted. Immutable; supersede rather than edit._
