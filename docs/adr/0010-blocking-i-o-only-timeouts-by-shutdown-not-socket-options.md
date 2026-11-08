# ADR-0010 — Blocking I/O only; timeouts by shutdown, not socket options.

*Context:* `std.Io.Threaded`'s net path is plain blocking syscalls, which suits a prototype — but a blocking `Stream` has no timeout API, and `SO_RCVTIMEO` surfaces as `EAGAIN`, which the threaded backend treats as a programmer bug and panics on in Debug builds. *Decision:* One thread per connection, HTTP/1.1 only, no TLS, no outbound network in MVP. Slow-client enforcement is a **watchdog thread calling `shutdown(fd, .both)`** at the deadline; the blocked `recv` then returns 0 and the connection closes. No `SO_RCVTIMEO`, no `SO_SNDTIMEO`, no `O_NONBLOCK` on accepted sockets. *Consequences:* Timeouts are cancel-safe and never panic; a slow client costs one thread until the watchdog fires.

_Status: accepted. Immutable; supersede rather than edit._
