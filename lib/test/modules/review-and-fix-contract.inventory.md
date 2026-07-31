# Review-and-fix contract module inventory

This inventory records the provenance of the focused contract module. It is a
navigation aid, not a second source of behavior: `review-and-fix-contract.sh`
owns the executable assertions, and the complete suite calls the same module
through `module-harness.sh`.

Source baseline: `209b9e6c` (`origin/main` before issue #565).

| Contract group | Former `lib/test/run.sh` coverage | Module destination | Representative contract |
| --- | --- | --- | --- |
| Iteration cap and configuration resolution | `1022–1097` | `review-and-fix-contract.sh` / iteration-cap section | the schema/example resolver contract and the clamp's own arms |
| Pre-fix gates and guardrails | `1621–1801` | pre-fix gates and guardrails section | the prompt extension's focused-selection and skip-accounting guardrails |
| Convergence, shadow, and re-sweep contracts | `2149–2565`, `2992–3150`, `3801–3836`, `4425–4594` | convergence and verification-evidence section | the over-grade gate's no-auto-demote rule, the early shadow trigger, and the mechanism-scoped re-sweep |
| Telemetry, recovery, and continuation contracts | `4822–4832`, `19629–20304`, `29506–29621` | telemetry/recovery/continuation section | per-iteration records, the loop-role schema, and the full recovery shadow roster |
| Prompt-composition contracts | `40909–40944` | prompt-composition section | topic-priming visibility and the coupled receiving-review guidance |
| Routing and mapping assertions | `8605–8891` | global runner boundary plus focused module | the generic runner stays global; the module pins review-and-fix coverage only |

The `Former lib/test/run.sh coverage` column is a provenance record of where each
group came from, frozen at the source baseline; the `Representative contract`
column names what the module asserts **today**. The two diverge deliberately:
issue #946 step 3 retired 28 of this module's 44 existence-only pins after they
were adjudicated `prose-sole-copy` — agent-executed prompt prose no tool reads —
so several contracts a group originally represented are now covered by the
review pass rather than by an assertion here.

The generic test harness, registry validation, module registration, full-suite
boundary, and module-runner tests stay global so deleting this module cannot
also delete the checks that prove it is selected and executed.
