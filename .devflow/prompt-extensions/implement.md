# DevFlow repo — versioning policy for `/devflow:implement`

This repository (the DevFlow plugin itself) manages its own version, so apply the
following when implementing an issue here. The base `/devflow:implement` skill is
versioning-agnostic by design — this extension is DevFlow's opt-in, and it is the
**operative** versioning rule for this repo (edit this file to change the policy).

**When to bump.** Bump `.claude-plugin/plugin.json`'s `version` only for changes that
reach consumer repos as an update — a fix, feature, or breaking change to the engine
surface (`skills/`, `agents/`, `lib/`, `scripts/`, the workflows, the config schema).
Internal-only changes (tests, CI, dev-only docs) do **not** bump.

**Which increment — default to `patch`.** Use the smallest step. Choose `minor`
(backward-compatible feature) or `major` (breaking change) **only when this issue's body
explicitly authorizes the larger step** — e.g. an acceptance criterion naming the target
version or the SemVer increment. When the issue is silent on the increment, choose
`patch`. Never infer a larger bump from the change's size or "feature-ness" on your own.

**CHANGELOG is mandatory with any bump.** Whenever you bump the version, add the matching
`## [x.y.z]` entry to `CHANGELOG.md` in the same change (Keep-a-Changelog format, dated,
citing the PR number). The Phase 3 review gate FAILs on a version↔`CHANGELOG` mismatch.

**When to apply it.** Decide the increment once the committed diff is concrete (record the
decision in the workpad so it survives context compaction), then apply the bump +
`CHANGELOG` entry **after the draft PR exists but before the review pass** — so the entry
can cite the PR number and the version + `CHANGELOG` land inside the diff that `/simplify`
and `/devflow:review-and-fix` review. The Phase 4.3 clean-tree backstop is the final guard
that the bump never ends up uncommitted.
