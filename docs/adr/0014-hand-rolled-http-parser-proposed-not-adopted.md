# ADR-0014 — A hand-rolled HTTP parser (proposed, not adopted).

*Context:* Phase 1 had a time-boxed risk: if `std.http.Server` could not be driven from the blocking accept loop within an hour, the fallback was a hand-written request parser. *Decision:* Not adopted. `std.http.Server` worked from a blocking loop once `receiverExpectContinue` handled `Expect: 100-continue`, so there was nothing to hand-roll. *Consequences:* The runtime inherits std's parser and its limits — the header quirks this codebase has to defend against (a field name with whitespace before the colon is silently dropped; `Transfer-Encoding: gzip` becomes a content encoding) and the absence of socket read timeouts are std's, not ours, and the gates check the ones that matter (`gates/http_edges.py`). A hand-rolled parser would have traded those for our own CVEs.

_Status: not adopted (proposed, never needed). Immutable; supersede rather than edit._
