# Cluster mode

Nothing in the single-node runtime *needs* a cell to be local — every lookup can go
through `Locator` and a remote answer is already a 307 — but two places are still
hard-wired local: `deploy` submits straight to this process's shards, and `cellFor`
always opens the local cell directory. This document is the shape that design is
for; the status markers below say what actually exists.

The hard problem is not "run on several machines". It is **two nodes believing
they own the same cell at the same time**, which corrupts that cell's database.
Every rule here exists to make that impossible or to make it detectable.

## 1. Membership — `src/runtime/membership.zig` (done, no transport)

SWIM-style state: `alive | suspect | dead`, with incarnation numbers. Implemented
as a pure data structure with no clock and no sockets, so the merge rules are
tested on one machine.

The merging rules, and why each one is there:

| rule | why |
|---|---|
| higher incarnation always wins | refutation must beat any stale rumour, or a suspected-but-healthy node stays suspected forever |
| equal incarnation: worse state wins (dead > suspect > alive) | an "I'm alive" at the same incarnation is exactly what a partitioned node replays; only a *newer* incarnation can clear a suspicion |
| lower incarnation ignored | delayed gossip must not undo newer knowledge |
| a higher incarnation may resurrect a dead member | that is SWIM's refutation path: a restarted node rejoins with a bumped incarnation. It is safe only because the lease in §3 fences the old owner — membership alone cannot prevent two owners |
| join (`add`) with a lower incarnation does nothing | otherwise a stale gossip message could undo newer knowledge |

Probe targets are the least-recently-seen alive members, oldest first: fewest
messages to find the most likely dead node.

Wire format and the digest merge live in `src/runtime/gossip.zig` (done): a fixed
binary packet with explicit lengths, decoded **without allocation** and with every
length checked against the bytes that actually arrived, so a peer cannot make us
allocate by lying in a length field. `applyDigest` merges a peer's state list into
a `Table`; malformed entries are skipped rather than fatal, because one bad peer
must not stop us merging the rest.

`src/runtime/gossip_net.zig` has the round itself (done): `Node.step` picks the
least-recently-seen alive peer, sends a ping carrying a digest of everything it
knows, and turns silence into suspect and then dead; `Node.handle` merges a peer's
digest, learns unknown senders, and answers a ping with an ack. Three tests drive
two nodes through a probe/ack exchange, a partition, and a third node's state
arriving by digest.

Transport status: **`std.Io.net` in Zig 0.17 has no datagram send/receive** — the
socket option constants are there, the primitives are not — so a UDP adapter needs
raw syscalls through `std.os.linux`, or TCP, or a sidecar. That is why the
protocol is behind a `Transport` struct: swapping it must not touch the round
logic, and the tests already prove the logic with an in-memory mailbox.

## 2. Placement — `src/runtime/locator.zig` (done, single node)

`Locator.resolve(key) -> Placement{ local | remote(addr) }`, rendezvous hashing
over the member set. It is the **only** producer of a placement: `gates/check-locator.sh`
fails the build if anything outside `src/runtime/` looks up a cell by key.

Rendezvous hashing rather than a ring: removing a member only moves the keys it
owned, and every node computes the same answer from the same member set without
coordinating.

## 3. Ownership — the lease (design)

The failure this prevents: node A is alive but unreachable, node B decides A is
dead and adopts its cells, then A comes back and keeps serving the same cell.
Two writers, one SQLite file, corruption.

celld's answer, adopted here: **the shared bucket is the authority**, and
ownership is a compare-and-swap on an epoch-fenced record:

```
cells/<key-hash>/owner.json   { owner: "node-a", epoch: 7, expires_at: ... }
```

To take ownership a node must CAS `epoch` from the value it observed to
`epoch+1`. A node that loses the CAS must stop serving that cell immediately,
even if it believes it is the owner: **fencing beats belief.**

*Status: design only.* Nothing in the code enforces an epoch today — there is no
snapshot upload and no bucket writer, so no write currently carries one. The
`meta.json` fields named below exist but are rewritten from local defaults on
every cold load, so they are not yet a lease record. Writing that record and
threading the epoch through every write is the second step of the build order.

## 4. Handoff — RPO=0 (design)

1. New owner wins the CAS at epoch+1.
2. Old owner stops accepting invocations for that cell (queue drained, then 503
   with the new owner's address).
3. `VACUUM INTO` a snapshot to the bucket, plus the WAL segment range.
4. New owner restores, replays, verifies epoch, then serves.

Until step 4 completes the cell is unavailable, which is the honest failure mode:
unavailable beats forked. Test that a handoff under continuous writes either
completes with no lost rows or leaves the cell unavailable — never both owners
serving.

## 5. Routing — already shaped for it

A request for a cell this node does not own gets `307 Temporary Redirect` to the
owner's advertised address (`Scheduler.placement` → `http/server.zig`). The
bundled CLI does not follow it — it POSTs a body and Zig's client cannot replay a
request with a body — so a real deployment puts a routing layer in front. The 307
keeps the runtime honest about who owns what; it is not a load balancer.

## What must not happen (and what actually guards it today)

Exists now:
- A path that resolves a cell without `Locator` — `gates/check-locator.sh` is a heuristic
  over `cells.get(`/`findCell(`, not a proof, and it runs as an opt-in gate rather than
  inside `zig build`.
- Absolute paths inside a cell directory — cell dirs are relocatable by construction
  (`store/paths.zig`, I15), so they can be copied between nodes.
- A deploy pinned before it runs — the cell row is written only after the shard adopts the
  swap (ADR-0022), so a broken module can never become authoritative.

Not yet, and the reason the build order above is the build order:
- Content-addressed blobs (`data/blobs/<sha>.bin`) deduplicate modules and make a deploy a
  pointer swap; they are local disk only. There is no bucket write, so a blob does not
  currently survive losing a node.
- No lease, no epoch enforcement, no snapshot upload, no handoff. `--peers` only lets the
  invoke path answer 307 for a cell another node would own; deploys still run locally.
- The bundled CLI does **not** follow a 307: it sends a body, and Zig's client cannot
  replay a request with a body. A real deployment puts a router in front.

## Build order

1. gossip loop over UDP on top of `membership.zig` (membership only, no ownership)
2. bucket-backed epoch lease, single-node tests with a fake bucket
3. handoff: snapshot + WAL ship + restore, with a kill-the-old-owner test
4. routing through a real address table instead of `--peers` strings
5. only then: sharded cell placement across nodes, and rebalancing
