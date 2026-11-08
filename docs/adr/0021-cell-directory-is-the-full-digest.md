# ADR-0021 — A cell's directory is the full 256-bit digest of its key, plus a key file.

*Context:* Cell directories must be collision-free, relocatable, and must refuse a directory that was copied or renamed onto another key. *Decision:* The directory name is the lowercase hex of all 32 bytes of `sha256(cell_key)` — no truncation, so no birthday collisions — and it contains a `key` file naming the cell. `claim()` refuses to open a directory whose key file disagrees. *Consequences:* A data directory can be moved or restored as a unit (G10 checks relocation end to end); a mis-copied cell fails loudly instead of serving another cell's rows; the digest is the cluster-visible identity (ADR-0016) without a second naming scheme.

_Status: accepted. Immutable; supersede rather than edit._
