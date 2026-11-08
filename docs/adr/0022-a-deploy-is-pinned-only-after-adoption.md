# ADR-0022 — A deploy is pinned only after the shard has adopted it.

*Context:* A deploy can fail to compile or load. Pinning the cell to a module that then fails to load leaves a cell that cannot start and never recovers. *Decision:* Write the immutable deployment row (audit) before the swap, swap on the owning shard, write the active cell pin after the swap succeeds, then write `meta.json`. A failed load leaves an unused version and no pin. *Consequences:* A failed deploy burns a version number, which is what Workers does with an uploaded-but-undeployed version; an untaken version is harmless. The durable pin is the acknowledgement — a 200 means the pin was written (`deploy_live_unpinned` exists for the one case where the module is live and the pin is not).

_Status: accepted. Immutable; supersede rather than edit._
