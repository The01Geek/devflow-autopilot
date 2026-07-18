---
bump: patch
---

create-issue: skill tier-ladder + strict tool-side enforcement for tiered draft-root binding (issue #569, follow-up to #562).

The `/devflow:create-issue` skill now folds the three-tier canonical-draft-root selection into its draft-write recipe — tier 1 the resolver's main root (taken only on a clean, non-empty `resolve-main-root.sh` answer whose `.git` entry is a directory), tier 2 the active-worktree root (`git rev-parse --show-toplevel`), tier 3 the existing embed fallback — with the first landed write binding that root for the rest of the run via `record-draft-binding` and every later write site reading the bound path back from `query-draft-binding` (never context recall). `scripts/issue-audit-state.py record-dispatch --arm file` now strictly requires a recorded binding (`binding-required-on-file-arm`) and cross-checks the orchestrator-reported `--write-path` against the recorded binding (`write-path-mismatch`). The file-arm, audit-prompt-template, and embed-arm out-of-bounds enumerations additionally name the non-bound root's same-slug draft path under divergent roots, the sub-step 3 display note reads `<bound-root>` (was `<main-root>`), and `docs/DEVFLOW_SYSTEM_OVERVIEW.md` §11 is reconciled to describe the shipped behavior.
