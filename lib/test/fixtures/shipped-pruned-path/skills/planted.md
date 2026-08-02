<!-- prflow:review-ref phase=0 file=skills/review/phases/phase-0-setup.md start -->
## Phase 0: Setup

### 0.1 Check for uncommitted changes

Run:
```bash
git status --porcelain
```

If there is output, warn: "You have uncommitted changes that will not be included in this review."

**#504 displaced-path attribution.** If the run's engine-ground-truth block lists displaced paths, attribute any such path's `git status --porcelain` output — content delta, mode-only delta (the `chmod +x` floor flips `100644`→`100755` on every closure member tracked non-executable, every run, even when the PR touches none of them), OR untracked delta (a protected prompt-extension name the checkout never carried is *created* empty by the workflow's truncation step, so the path is reported as `??` rather than ` M`) — to the **trusted-source displacement** the block describes: expected displacement, NOT a PR defect or an uncommitted change to flag. The published list has **two producers** — the Stop-hook trusted-source floor (issue #458) and the prompt-extension truncation (issue #874) — so key the attribution on membership in the published list, never on which producer displaced a path.

**Match a porcelain path against the list by prefix, not by equality.** The list publishes **leaf file** paths, but `git status --porcelain` **collapses a wholly-untracked directory to the directory alone** — a consumer that tracks nothing under `.prflow/prompt-extensions/` reports `?? .prflow/prompt-extensions/`, and one tracking nothing under `.prflow/` reports `?? .prflow/`; neither leaf path appears. An equality-only predicate therefore matches nothing on exactly the consumer shape the untracked clause was added for, and the warning fires on every such review run. So attribute a porcelain path when it **is** a displaced path **or is a directory prefix of one**. All three delta kinds take that attribution, so an untracked displaced path draws no warning either. Remaining paths keep the warning sentence above verbatim. With no displaced list (local tier, manual `devflow.yml` path, consumer skip) all paths keep today's warning.

### 0.1.5 Persist the displaced-path list (compaction survival)

The engine-ground-truth block prepended to this run (rendered by `scripts/render-grounding-block.sh`) carries a displaced-paths section (section 5) ONLY when the workflow published a non-empty `HARDENED_PATHS` this run. Read that section and write the listed repo-relative paths to `.prflow/tmp/displaced-paths.txt` via the **Write tool** (one path per line; write an empty file when there is no such section — `Write(.prflow/tmp/**)` is already granted on the review tier). Phase 2.1a/2.1b, Phase-3 dispatch, and Phase 4.1.6 re-read this file to know which paths route their HEAD verification through `git show`, so a compacted long run keeps the routing at the far end where the sweep executes. A missing or empty file degrades to today's behavior (no displaced list → no routing, no attribution), never to a guess.

### 0.2 Determine diff scope and cache the diff

Resolve the configured checkpoint base once for both modes, so current-branch diffing and the PR-mode retargeting check consume one value:

```bash
# BEGIN CURRENT_BRANCH_BASE_CAPTURE
if ! BASE=$("${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/config-get.sh .base_branch main); then
  echo "::warning::devflow review: could not read .base_branch (config-get.sh rc≠0); falling back to 'main'" >&2
  BASE=main
fi
if test -z "$BASE"; then
  echo "::warning::devflow review: .base_branch resolved empty; falling back to 'main'" >&2
  BASE=main
fi
# END CURRENT_BRANCH_BASE_CAPTURE
```

Run lib/test/run.sh in the run's own environment and tick the criterion on
the pass you observe there.
