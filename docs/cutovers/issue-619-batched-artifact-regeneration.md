---
schema: 1
kind: growth
---

## Files

Three mandatory census rows grow by one `## Batched artifact regeneration` section each:

- `.devflow/prompt-extensions/implement.md` — the `/devflow:implement` entry surface, loaded
  unconditionally by its `load-prompt-extension.sh` step.
- `.devflow/prompt-extensions/review-and-fix.md` — the `/devflow:review-and-fix` entry surface,
  loaded unconditionally by its SKILL.md `load-prompt-extension.sh` step.
- `.devflow/prompt-extensions/receiving-code-review.md` — loaded whenever the
  receiving-code-review skill itself loads (interactive invocations and description-matched
  dispatches).

No other mandatory row moves. The vendored `skills/receiving-code-review/SKILL.md` is **not**
modified: its body must stay repo-agnostic, and this instruction names repo-specific paths.

## Justification

These bytes buy back full-suite runs, which are the repo's slowest verification step. Before this
change, a loop discovered each drifted generated artifact one full-suite run at a time — an
observed fix loop paid three such rerun cycles on three mechanical regeneration chores whose
commands were already known (the cloud-writer runtime manifest, the prompt-mass census baseline,
and the review-bundle budget record). The drift is induced by the loop's own edits, so it is
predictable before the rerun starts; the instruction converts N discover-fix-rerun cycles into one
batched pass plus one re-verify run.

The bytes belong on the **mandatory** path rather than a conditional reference because the
instruction must fire before *every* full-suite re-verify run. A reference file loaded only on a
rare path would be absent at exactly the moment the pass is due, which is the failure mode the
`batched-regeneration: run|refused|skipped` discharge line exists to make auditable.

All three surfaces are grown rather than one, because each is the unconditional entry surface of a
distinct loop that induces this drift, and no one of them is loaded by the other two. In
particular, `/devflow:review-and-fix` cites the receiving-code-review skill by *principles* only —
a prose citation, not a guaranteed skill load — so the receiving-code-review extension alone would
not reach the flagship fix loop.

Growth is bounded by design: the sections carry **no artifact inventory**. Enumeration lives
solely in `lib/test/regenerate-artifacts.py`'s registry, so adding a sixth artifact later grows the
helper and not these three mandatory rows. Each section's invocation sentence and discharge-record
line are pinned by `assert_pin_unique` in `lib/test/run.sh`, so the grown bytes cannot silently
disappear from any one surface.
