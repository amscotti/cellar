# ADR-0002 — The language is a backend behind a six-operation adapter.

*Context:* The prototype must not be rewritten if the language choice changes. *Decision:* `src/vm/vm.zig` defines `Vm` with `create`, `compile` (free function on a scratch VM), `load` → `Module`, `call`, `unload`, plus `heap_used`/`heap_limit` and a comptime `caps` struct (`preempt`, `hard_mem_limit`, `catchable_oom`). `vm.zig` is the only file that imports a backend; the `-Dvm` option selects it. All backends share the host binding surface (`BINDINGS.md`) and the conformance inputs. *Consequences:* A new backend is accepted by running the conformance suite; backend deficits are declared through `caps` and printed by `--version`, never papered over.

_Status: accepted. Immutable; supersede rather than edit._
