# ADR-0005 — No cross-cell calls in MVP.

*Context:* A→B→A is an instant deadlock when each cell is one thread. *Decision:* The binding surface has no `cell.call`; cross-cell work is ordinary HTTP. *Consequences:* "Coordinator cell" designs are deferred; the post-MVP path is bounded message passing, not synchronous RPC.

_Status: accepted. Immutable; supersede rather than edit._
