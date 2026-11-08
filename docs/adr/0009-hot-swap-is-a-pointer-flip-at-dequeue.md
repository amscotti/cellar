# ADR-0009 — Hot swap is a pointer flip at dequeue.

*Context:* Deploys must not require a restart or request draining. *Decision:* A deploy compiles into a content-addressed blob and upserts a deployment row; it then messages the cell's shard. The cell adopts the new `Module` when it next dequeues an invocation — the swap point is dequeue, not enqueue, and not "somewhere between". The old module stays referenced until the cell drops it and no other cell pins its blob; sweep consults the registry and every `meta.json`. *Consequences:* No downtime, no dual-write. Because invocations in a cell are serialized, an invocation cannot be in flight when the swap happens — the real hazard (sweeping a blob a cell still needs) is what the gate tests.

_Status: accepted. Immutable; supersede rather than edit._
