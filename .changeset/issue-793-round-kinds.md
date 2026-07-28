---
bump: patch
---

### Added

- `/devflow:create-issue` Step 3.6 rounds now carry a tool-owned **kind**. `scripts/issue-audit-state.py` derives one of exactly two kinds — `discovery` (the cold whole-draft round) or `targeted` (a claim-scoped re-check of what a revision was supposed to fix) — from recorded facts alone, answers it through the new read-only `query-round-kind`, and `record-dispatch` now requires `--kind` and refuses any kind other than the one the tool selects, mirroring the existing `write-path-mismatch` cross-check. The orchestrator never chooses a kind. Selection fails toward the expensive kind: every unestablished or unsatisfied condition selects `discovery` and names the failing condition, and neither an empty changed-section set nor one whose computation errored is read as "nothing changed" (PR #884).
- A `targeted` round's whole payload — the enumerated claims as id plus one-line summary, and the tool-derived changed-section set — travels in one frozen **dispatch-scope file** whose path and content digest both join the round's closed recorded regeneration tuple, written by the new `write-dispatch-scope` and rendered by `scripts/render-audit-prompt.py`'s new `targeted` block. The auditor learns what to check, never what was concluded: no status, severity, disposition, prior verdict, rationale or evidence reaches it (PR #884).
- A clean `targeted` round is confirmed rather than trusted — it never grounds the clean scan, the coverage axis, the calibration signal or the convergence basis, and when every claim returns `addressed` the tool selects a confirming whole-draft round through the new `confirm-whole-draft` next action, funded from its own counter (PR #884).
- The Step 4 audit summary (`query-summary`) now grounds its verdict and class counts on the latest **whole-draft** round instead of the latest completed one, so a scoped re-check never renders as the run's verdict, and reports the scoped round beside them under a new `scoped_round=` token rather than dropping it (PR #884).

### Changed

- `scripts/stage-draft-write.py`'s `stage --path` is now a **base** the helper completes with the staged bytes' own digest, reporting the resolved path, so the run keeps a durable byte history instead of a single latest-bytes slot. A second stage of different bytes lands beside the first; re-staging identical bytes resolves to the same path. The new `record-staged-write` / `query-staged-write` pair records and resolves that path durably, so the write-failure recovery arm re-applies the artifact that write recorded rather than the newest on disk (PR #884).
