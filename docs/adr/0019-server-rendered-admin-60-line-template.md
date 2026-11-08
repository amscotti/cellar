# ADR-0019 — Server-rendered admin with a 60-line template engine and inline CSS.

*Context:* The admin view must work offline, with no build step, in a single binary — a JS framework or a bundler would add a toolchain the project does not otherwise need. *Decision:* One HTML template embedded in the binary, substituted in a single pass over `{{markers}}`; CSS inline; no client-side framework, and JS only where SSE needs it. Every interpolated value is HTML-escaped by the renderer. *Consequences:* The whole UI is reviewable in one file and cannot break at runtime for want of an asset. The renderer is deliberately dumb: it substitutes, it does not parse, so a future field containing `{{` would need escaping at the call site (none does today).

_Status: accepted. Immutable; supersede rather than edit._
