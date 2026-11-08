# ADR-0008 — The admin UI is no-build and offline.

*Context:* A build step is a second toolchain to keep alive for a prototype. *Decision:* Templates and partials are `@embedFile`d; HTMX **plus its SSE extension** (a separate file — forgetting it is a silent no-op), Alpine, and Pico.css are vendored single files served from `/static/`; no CDN at runtime; no transpiler, bundler or package manager. *Consequences:* Editing a template means rebuilding; the dashboard works air-gapped. A `--admin-tpl-dir`/`--admin-static-dir` override exists in Debug builds only, so the UI loop is not a full C-toolchain rebuild.

_Status: accepted. Immutable; supersede rather than edit._
