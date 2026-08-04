---
bump: patch
type: Fixed
---

- **The dependency-section outbound-direction filter no longer drops a number because of the human reason text.** A correctly-drafted `Blocked by #N — <reason>` line under `## Dependencies` whose reason prose happened to contain an ordering word (`must merge before`, `blocks`, `required by`, …) had its issue number silently discarded, so the early implement dependency gate fell open and the GitHub-native blocked-by stamp registered nothing. `OUTBOUND_DECLARATION` in `scripts/preflight.py` is narrowed so an outbound keyword governs its line only when a number run follows it within a bounded same-clause window; the vocabulary and line-level governance are unchanged, and — because the narrowing only ever removes matches — no false `BLOCKED` is introduced for the outbound separator shapes (`Blocks: #N`, `Blocks issue #N`, `| Blocks | #N |`). (#1269)
