# Review-and-fix contract module inventory

This inventory records the provenance of the focused contract module. It is a
navigation aid, not a second source of behavior: `review-and-fix-contract.sh`
owns the executable assertions, and the complete suite calls the same module
through `module-harness.sh`.

Source baseline: `209b9e6c` (`origin/main` before issue #565).

| Contract group | Former `lib/test/run.sh` coverage | Module destination | Representative contract |
| --- | --- | --- | --- |
| Iteration cap and configuration resolution | `1022–1097` | `review-and-fix-contract.sh` / iteration-cap section | `MAX_ITERS=5` fallback and the schema/example resolver contract |
| Pre-fix gates and guardrails | `1621–1801` | pre-fix gates and guardrails section | scoped staging, post-shadow gate, and extension guardrails |
| Convergence, shadow, and re-sweep contracts | `2149–2565`, `2992–3150`, `3801–3836`, `4425–4594` | convergence and verification-evidence section | calibration gates, fix-delta convergence, bounded shadowing, and mechanism-scoped re-sweep |
| Telemetry, recovery, and continuation contracts | `4822–4832`, `19629–20304`, `29506–29621` | telemetry/recovery/continuation section | per-iteration records, source-of-truth pushback, and recovery evidence |
| Prompt-composition contracts | `40909–40944` | prompt-composition section | exhaustive prompt provenance and a fail-closed attestation |
| Routing and mapping assertions | `8605–8891` | global runner boundary plus focused module | the generic runner stays global; the module pins review-and-fix coverage only |

The generic test harness, registry validation, module registration, full-suite
boundary, and module-runner tests stay global so deleting this module cannot
also delete the checks that prove it is selected and executed.
