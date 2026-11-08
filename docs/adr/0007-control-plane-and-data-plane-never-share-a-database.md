# ADR-0007 — Control plane and data plane never share a database.

*Context:* Registry writes and user writes have different durability and contention needs. *Decision:* `data/state.db` holds cells, deployments and registry counters, written only by the registry thread; cell databases hold only user rows. Each cell's `meta.json` carries `key`, `module`, `version`, `blob_sha`, `schema_version` so the registry is reconstructible. *Consequences:* Losing `state.db` loses no user data and no pins; blobs stay referenced because sweep reads both the registry and every `meta.json`.

_Status: accepted. Immutable; supersede rather than edit._
