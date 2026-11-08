# ADR-0011 — Guest code is trusted in MVP.

*Context:* In-process interpreters are not security boundaries. *Decision:* Dangerous libraries are removed from the guest environment and the README states that this build is not a sandbox. Isolation starts with process-per-cell post-MVP. *Consequences:* Never expose this build to untrusted uploaders; the admin token is the only auth.

_Status: accepted. Immutable; supersede rather than edit._
