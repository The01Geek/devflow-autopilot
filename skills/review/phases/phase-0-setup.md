<!-- devflow:review-ref phase=0 file=skills/review/phases/phase-0-setup.md start -->
## Phase 0: Setup

### 0.1 Check for uncommitted changes

Run:
```bash
git status --porcelain
```

If there is output, warn: "You have uncommitted changes that will not be included in this review."

**#504 displaced-path attribution.** If the run's engine-ground-truth block lists #458-displaced paths, attribute any such path's `git status --porcelain` output — a content delta OR a mode-only delta (the unconditional `chmod +x` floor surfaces a `100644`→`100755` flip on the three non-executable closure members every run, even on a PR that touches none of them) — to the Stop-hook trusted-source floor: it is expected displacement, NOT a PR defect or an uncommitted change to flag. The remaining paths keep the warning sentence above verbatim. With no displaced list (local tier, manual `devflow.yml` path, consumer skip) all paths keep today's warning.

### 0.1.5 Persist the displaced-path list (compaction survival)

The engine-ground-truth block prepended to this run (rendered by `scripts/render-grounding-block.sh`) carries a displaced-paths section (section 5) ONLY when the workflow published a non-empty `HARDENED_PATHS` this run. Read that section and write the listed repo-relative paths to `.devflow/tmp/displaced-paths.txt` via the **Write tool** (one path per line; write an empty file when the block carries no displaced-paths section — `Write(.devflow/tmp/**)` is already granted on the review tier). The Phase 2.1a/2.1b, Phase-3 dispatch, and Phase 4.1.6 verification surfaces re-read this file to know which paths route their HEAD verification through `git show` — so a compacted long run keeps the routing at the far end where the sweep executes. A missing or empty file degrades to today's behavior (no displaced list → no routing, no attribution), never to a guess.

### 0.2 Determine diff scope and cache the diff

Resolve the configured checkpoint base once for both modes, so current-branch diffing and the PR-mode retargeting check consume the same value:

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

**If `$ARGUMENTS` is a PR number:**
```bash
gh pr diff $ARGUMENTS
gh pr view $ARGUMENTS --json headRefName,baseRefName,baseRefOid,headRefOid --jq '.'
```
If either command fails (non-zero exit code), stop immediately and report: "Failed to retrieve diff. Verify the PR number exists and you have required permissions."

Use the PR diff output for Phase 1. Store the head branch name, `baseRefOid` as `$PR_BASE_SHA`, `baseRefName` as `$PR_BASE_BRANCH` (the PR's own base ref — used by the head-override diff below; the name avoids the `BASE_REF` substring the `lib/test/run.sh` #424 grep-c pin forbids, mirroring how `lib/fetch-pr-context.sh` already exposes this field), and `headRefOid` as `$PR_HEAD_SHA` — the head-override diff (below), Phase 0.3.6's blocker-recheck fast path, and Phase 4's `Reviewed HEAD` line all need them. `$PR_BASE_SHA` (the immutable run-start `baseRefOid`) is retained as the deleted-base fallback (below) and the reviewer-prompt `Base SHA:` line. (Phase 1.1 no longer per-file-slices via `git diff` — it slices the already-cached `diff.patch` with `awk` — so it is not among the consumers of these SHAs.)

**Caller head-override (fix-loop reuse).** A wrapping skill (currently `/devflow:review-and-fix`) may pass `head_override = local`. When set, take the PR's head from the local working tree instead of the API: set `$PR_HEAD_SHA=$(git rev-parse HEAD)` and fetch the diff with `git diff "origin/$PR_BASE_BRANCH...HEAD"` (three-dot) instead of `gh pr diff $ARGUMENTS`. **The base is the PR's own base ref `$PR_BASE_BRANCH` (its current fetched tip), not the run-start `$PR_BASE_SHA`** — matching the semantics `gh pr diff` gives the non-override path, so a base commit an in-loop Checkpoint-3 (`scripts/update-branch-checkpoint.sh`) merges into the PR head mid-loop is excluded rather than attributed to the PR as added content (issue #503: with the stale run-start `baseRefOid`, `merge-base(baseRefOid, HEAD)` collapsed to `baseRefOid` once the merge made it an ancestor, degenerating the three-dot diff to `baseRefOid..HEAD` and sweeping in every base commit newer than `baseRefOid` as PR-added). This lets a fix loop review commits it has made locally but not yet pushed — the remote `headRefOid` would otherwise lag behind and the loop would re-review pre-fix code. It requires the PR's head branch to be the checked-out branch; the caller guarantees this (review-and-fix does so in its Step 0.5). When `head_override` is absent — standalone `/devflow:review`, the default — use the API head exactly as above; do **not** diff against local `HEAD`, since a standalone review must reflect the pushed PR state, not a dirty or stale local checkout.

**Resolve the head-override base ref before diffing (mirrors `scripts/update-branch-checkpoint.sh`).** Execute the checked arms below. They refresh the PR's base through an explicit refspec (including names with `/`), retry a shallow merge-base failure once after `--unshallow`, select the immutable run-start SHA only when the named base has disappeared, and make a retargeted/stacked PR's residual visible. Every terminal failure removes candidate and prior caches before stopping; the wrapping `/devflow:implement` run records that stop as **Blocked**, while a standalone run stops and reports it.

```bash
# BEGIN HEAD_OVERRIDE_BASE_RESOLUTION
if git fetch origin "+refs/heads/$PR_BASE_BRANCH:refs/remotes/origin/$PR_BASE_BRANCH"; then
  HEAD_OVERRIDE_BASE=$(printf '%s' "origin/$PR_BASE_BRANCH")
  if git merge-base "$HEAD_OVERRIDE_BASE" HEAD >/dev/null; then
    :
  else
    if git fetch --unshallow origin "+refs/heads/$PR_BASE_BRANCH:refs/remotes/origin/$PR_BASE_BRANCH"; then
      :
    else
      RETRY_RC=$?
      echo "::warning::devflow review: base unshallow fetch returned rc=$RETRY_RC; probing merge-base once more because a complete repository can reject --unshallow" >&2
    fi
    if git merge-base "$HEAD_OVERRIDE_BASE" HEAD >/dev/null; then
      :
    else
      MERGE_BASE_RC=$?
      rm -f .devflow/tmp/review/<slug>/<run-id>/diff.raw-candidate .devflow/tmp/review/<slug>/<run-id>/diff.candidate .devflow/tmp/review/<slug>/<run-id>/diff.patch
      echo "::error::devflow review: base remains unreachable after unshallow retry (rc=$MERGE_BASE_RC); no review cache was published" >&2
      exit "$MERGE_BASE_RC"
    fi
  fi
else
  FETCH_RC=$?
  if git ls-remote --exit-code --heads origin "refs/heads/$PR_BASE_BRANCH" >/dev/null; then
    rm -f .devflow/tmp/review/<slug>/<run-id>/diff.raw-candidate .devflow/tmp/review/<slug>/<run-id>/diff.candidate .devflow/tmp/review/<slug>/<run-id>/diff.patch
    echo "::error::devflow review: PR base ref '$PR_BASE_BRANCH' still exists but its explicit-refspec fetch failed (rc=$FETCH_RC); refusing the stale retained-SHA fallback" >&2
    exit "$FETCH_RC"
  else
    REF_PROBE_RC=$?
    if [ "$REF_PROBE_RC" -ne 2 ]; then
      rm -f .devflow/tmp/review/<slug>/<run-id>/diff.raw-candidate .devflow/tmp/review/<slug>/<run-id>/diff.candidate .devflow/tmp/review/<slug>/<run-id>/diff.patch
      echo "::error::devflow review: could not confirm whether PR base ref '$PR_BASE_BRANCH' was deleted (git ls-remote rc=$REF_PROBE_RC; fetch rc=$FETCH_RC); refusing the stale retained-SHA fallback" >&2
      exit "$FETCH_RC"
    fi
    HEAD_OVERRIDE_BASE=$(printf '%s' "$PR_BASE_SHA")
    echo "::warning::devflow review: PR base ref '$PR_BASE_BRANCH' is absent on origin; using retained base SHA '$HEAD_OVERRIDE_BASE'" >&2
    if git merge-base "$HEAD_OVERRIDE_BASE" HEAD >/dev/null; then
      :
    else
      MERGE_BASE_RC=$?
      rm -f .devflow/tmp/review/<slug>/<run-id>/diff.raw-candidate .devflow/tmp/review/<slug>/<run-id>/diff.candidate .devflow/tmp/review/<slug>/<run-id>/diff.patch
      echo "::error::devflow review: retained base SHA is unreachable (rc=$MERGE_BASE_RC); no review cache was published" >&2
      exit "$MERGE_BASE_RC"
    fi
  fi
fi
if ! test "$PR_BASE_BRANCH" = "$BASE"; then
  echo "::warning::devflow review: PR base '$PR_BASE_BRANCH' differs from configured checkpoint base '$BASE'; merged checkpoint content can re-enter the review diff" >&2
fi
# END HEAD_OVERRIDE_BASE_RESOLUTION
```

The deleted-base fallback is **leak-equivalent to the pre-fix binding** when the base advanced (base content newer than `baseRefOid` re-enters the diff); it is accepted only because base deletion is rare and matches `gh pr diff`'s retained-SHA semantics. `--push-each-iteration` on a PR whose base differs from `$BASE` carries the separately reported residual leak; changing Checkpoint 3 to merge `baseRefName` is a separate concern.

**Fail-closed at the producer (before the cache write).** Both local-diff paths — head override and current branch — stage raw and filtered candidates, then check a separate promotion write to `diff.patch` before checking that the published cache can also be emitted to stdout. A producer, filter, promotion (including a partial write followed by nonzero), or stdout failure records its rc, removes every candidate and any prior `diff.patch`, and stops — an empty or stale cache must never reach the Phase 1–3 agents as "nothing to flag" and yield `APPROVE`. If the entire runner is terminated mid-command, no downstream phase can execute; a retry re-enters Phase 0.2, removes any prior cache before production, and republishes before Phase 1 reads the cache. The wrapping `/devflow:implement` run records an observed stop as **Blocked**; a standalone run stops and reports it. (Phase 0.6's degraded note does **not** gate the agents' verdict, so the guard must sit here, before publication.)

**Caller run-id (run-scoped scratch).** All of this run's scratch under `.devflow/tmp/review/<slug>/` is nested one level deeper under a per-run `<run-id>` so concurrent or repeated reviews of the same PR never clobber each other (the same isolation the per-run progress-comment marker provides). Resolve `<run-id>` **once** at the start of Phase 0.2 and hold the literal for the whole run:

- A wrapping skill (currently `/devflow:review-and-fix`) may pass `run_id = <value>` — its own loop-start `RUN_ID`. When provided, use it verbatim so the engine's `diff.patch` lands in the *same* run directory as the wrapper's `iter-*.json` / `deferrals.json`.
- When absent (standalone `/devflow:review`), compute it with the **same derivation the progress-comment marker uses** — `${GITHUB_RUN_ID:-local-$(date -u +%Y%m%dT%H%M%SZ)}-${GITHUB_RUN_ATTEMPT:-1}` — and reuse that held literal everywhere (never recompute; on a local run the timestamp would otherwise drift between phases and scatter one run's scratch across directories).

**Note on `gh pr diff` path filtering.** `gh pr diff <N>` does NOT support path arguments — `gh pr diff <N> -- <file>` errors with `accepts at most 1 arg(s)` (cli/cli#5398, unresolved). Phase 1.1 sidesteps this entirely: it never re-fetches a per-file diff — it slices the already-cached `diff.patch` with an `awk` section-range over its `^diff --git` headers (see Phase 1.1). This note is retained as a caution for any future consumer tempted to re-introduce per-file `gh pr diff` slicing.

**If no argument (review current branch):**
```bash
git diff "origin/$BASE...HEAD"
git diff "origin/$BASE...HEAD" --name-only
```
Use `$BASE` from the guarded capture at the start of Phase 0.2, never a hardcoded `origin/main`, so a consumer whose trunk is `master`/`develop` diffs against the right base. If either command fails (non-zero exit code), stop immediately and report: "Failed to retrieve diff. Verify origin/$BASE is reachable and you are on a valid branch."

Use the diff output for Phase 1. The current branch is the review target.

For the checked cache producer below, render `<resolved-local-diff-base>` before executing the fence: substitute `origin/$BASE` in current-branch mode or the mechanically selected `$HEAD_OVERRIDE_BASE` value in PR head-override mode. This is a required non-shell placeholder, not an environment variable: if a runner drops the substitution, the literal is not a valid ref and `git diff` fails closed instead of collapsing an unset variable to the valid-but-empty `...HEAD` range. Standalone PR mode remains on the unchanged `gh pr diff` path and does not execute this fence.

If the diff is empty, report: "No changes to review. Branch is identical to $BASE." and stop.

**Cache the diff to disk.** Write the diff fetched above to `.devflow/tmp/review/<slug>/<run-id>/diff.patch` — **fetch once, do not re-run `gh pr diff` / `git diff`**. Compute `<slug>` as:

- **PR mode:** `pr-<N>` where `<N>` is the PR number from `$ARGUMENTS`.
- **Current-branch mode:** the current branch name sanitized for filesystem use — replace `/` with `-`, lowercase, drop any character that isn't `[a-z0-9._-]`. (Matches the workpad slug convention `/devflow:review-and-fix` already uses.)

and `<run-id>` per "Caller run-id" above (caller-provided when wrapped, else computed once here).

Combine the initial fetch with the cache write in one shot using `tee` so the diff is captured exactly once and stdout remains available for Phase 1 consumption. **Filter `.devflow/logs/**` hunks out as the diff streams to disk** — interpose an `awk` stage between the fetch and `tee` so the cached `diff.patch` (and the stdout Phase 1 consumes) never contains a telemetry-log hunk:

```bash
mkdir -p .devflow/tmp/review/<slug>/<run-id>
gh pr diff $ARGUMENTS | awk '/^diff --git/{in_logs=/ [ab]\/\.devflow\/logs\//} !in_logs' | tee .devflow/tmp/review/<slug>/<run-id>/diff.patch
# or, in current-branch mode ($BASE from the guarded config-get capture above):
# git diff "origin/$BASE...HEAD" | awk '/^diff --git/{in_logs=/ [ab]\/\.devflow\/logs\//} !in_logs' | tee .devflow/tmp/review/<slug>/<run-id>/diff.patch
# In either local-diff mode, use this checked candidate/promote form.
# Render <resolved-local-diff-base> as the mechanically selected HEAD_OVERRIDE_BASE
# value (PR head override) or origin/$BASE (current branch). Remove stale authority first.
rm -f .devflow/tmp/review/<slug>/<run-id>/diff.raw-candidate .devflow/tmp/review/<slug>/<run-id>/diff.candidate .devflow/tmp/review/<slug>/<run-id>/diff.patch
if git diff "<resolved-local-diff-base>...HEAD" > .devflow/tmp/review/<slug>/<run-id>/diff.raw-candidate; then
  if awk '/^diff --git/{in_logs=/ [ab]\/\.devflow\/logs\//} !in_logs' .devflow/tmp/review/<slug>/<run-id>/diff.raw-candidate > .devflow/tmp/review/<slug>/<run-id>/diff.candidate; then
    if sed -n 'p' .devflow/tmp/review/<slug>/<run-id>/diff.candidate > .devflow/tmp/review/<slug>/<run-id>/diff.patch; then
      if cat .devflow/tmp/review/<slug>/<run-id>/diff.patch; then
        rm -f .devflow/tmp/review/<slug>/<run-id>/diff.raw-candidate .devflow/tmp/review/<slug>/<run-id>/diff.candidate
      else
        CAT_RC=$?
        rm -f .devflow/tmp/review/<slug>/<run-id>/diff.raw-candidate .devflow/tmp/review/<slug>/<run-id>/diff.candidate .devflow/tmp/review/<slug>/<run-id>/diff.patch
        echo "::error::devflow review: published diff could not be emitted (rc=$CAT_RC); review cache removed" >&2
        exit "$CAT_RC"
      fi
    else
      PROMOTE_RC=$?
      rm -f .devflow/tmp/review/<slug>/<run-id>/diff.raw-candidate .devflow/tmp/review/<slug>/<run-id>/diff.candidate .devflow/tmp/review/<slug>/<run-id>/diff.patch
      echo "::error::devflow review: diff cache promotion failed (rc=$PROMOTE_RC); no review cache was published" >&2
      exit "$PROMOTE_RC"
    fi
  else
    AWK_RC=$?
    rm -f .devflow/tmp/review/<slug>/<run-id>/diff.candidate .devflow/tmp/review/<slug>/<run-id>/diff.raw-candidate .devflow/tmp/review/<slug>/<run-id>/diff.patch
    echo "::error::devflow review: head-override diff filter failed (rc=$AWK_RC); no review cache was published" >&2
    exit "$AWK_RC"
  fi
else
  DIFF_RC=$?
  rm -f .devflow/tmp/review/<slug>/<run-id>/diff.raw-candidate .devflow/tmp/review/<slug>/<run-id>/diff.candidate .devflow/tmp/review/<slug>/<run-id>/diff.patch
  echo "::error::devflow review: head-override diff producer failed (rc=$DIFF_RC); no review cache was published" >&2
  exit "$DIFF_RC"
fi
```

**Why the `awk` filter — and why here.** As of issue #441 DevFlow persists durable telemetry to a dedicated **telemetry branch** (via git plumbing that never touches the feature branch), so a normal DevFlow run leaves **no** `.devflow/logs/` hunk in the PR diff and this filter is a no-op on it. The filter is **retained as a defensive guard** for the case it still matters: a **pre-#441 legacy branch** that already carried `chore: persist review-and-fix observability artifacts` commits on the feature branch, or a consumer that commits `.devflow/logs/` to the feature branch for some other reason. Any such `.devflow/logs/` hunks are **DevFlow telemetry artifacts, not code-review subjects** — but they would still appear as hunks in the PR diff, where Phase 1/2/3 agents would otherwise flag them as accreting hygiene artifacts with stale line ranges. The filter strips them once, at the single cache-write point every downstream phase reads from, so agents never see a hunk they should not review. The `awk` program sets `in_logs` on each `diff --git` header (true when the header's path **starts with** `.devflow/logs/` — the regex is anchored to the `a/`/`b/` diff-prefix boundary (` [ab]/.devflow/logs/`) so it matches only paths *rooted* at `.devflow/logs/`, never a non-telemetry path that merely contains that substring elsewhere, e.g. `tests/fixtures/.devflow/logs/…`) and suppresses every line while `in_logs` holds — so all of a logs file's hunk lines are dropped together, and the next non-logs header resets `in_logs` to visible. A logs-only diff filters the cached `diff.patch` to empty — note the upstream "No changes to review" stop tests the *raw* fetched diff (before this filter), so it does **not** fire here; instead every downstream phase reads the now-empty `diff.patch` and finds nothing reviewable (Phase 0.3 derives an empty changed-file list, and the Phase 3 agents receive an empty diff), so a telemetry-only PR is correctly reviewed as having nothing to flag. A mixed diff keeps its real code hunks in their original order. The telemetry commits themselves remain on the branch unchanged — only the review engine's view of the diff is filtered. Standalone review uses the read-only profile's granted `gh pr diff`/`git diff`, `awk`, `tee`, `cat`, and `rm` heads. The wrapper-only local head-override path additionally requires git fetch and git ls-remote; only the writable implement/manual profiles can reach that path and grant those commands, while the read-only profile stays unchanged.

This replaces the bare `gh pr diff` / `git diff` invocation at the top of Phase 0.2 — use the `tee` form instead. Store `<slug>`, `<run-id>`, and the resolved diff path (e.g. `.devflow/tmp/review/pr-863/<run-id>/diff.patch`) so Phase 3 can substitute it into its agent prompts via `{DIFF_PATH}`. The directory creation is harmless if it already exists; the file is overwritten on every run *within the same run-id*, never across runs.

**`.devflow/tmp/` should be gitignored** (it's ephemeral scratch); the rest of `.devflow/` (`config.json`, `learnings/`, the schema/example) is intentionally tracked. The scaffolder (`scripts/scaffold-config.sh`, run by `install.sh` / `/devflow:init`) writes a scoped `.devflow/.gitignore` that ignores only `tmp/`. This skill does not manage that entry itself (it's a repo-level concern); flag missing coverage in the chat output only if `.devflow/tmp/` is not already ignored.

### 0.3 Get changed file list

Extract the list of changed files **by parsing the filtered `diff.patch` cached in 0.2** (read its `diff --git a/<path> b/<path>` headers), **not** from an independent `git diff --name-only` / `gh pr diff --name-only`. This matters: `.devflow/logs/**` paths were stripped from `diff.patch` in 0.2, so deriving the file list from it excludes them by construction — and Phase 1.1's batch slicing reads the **same** filtered `diff.patch` (an `awk` section-range over its `^diff --git` headers), so a `.devflow/logs/` hunk can never re-enter a batch slice, and Phase 3's agents Read the same cached diff. An independent `--name-only` would re-introduce those paths and desynchronize the file list from the sliced batches. Store this list — it's needed for Phase 1 and Phase 3.

### 0.3.5 Seed the live progress comment (PR mode)

In PR mode, and when `devflow_review.live_progress_comment_enabled` is `true` (read it via `"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/config-get.sh .devflow_review.live_progress_comment_enabled true`), seed **this run's** live progress comment **now** — this is the engine's first GitHub write, so "review started" lands as early as possible. Create a fresh comment for this run, keyed by the run-keyed marker, with the Blueprint template (all boxes unticked) and the `Run` link to this job, per the **Live Progress Comment** section above. Because the marker carries this run's id, the find-or-resume lookup matches **only this run's** comment: on a mid-run retry (`rc=0`) it resumes that same comment; it never resumes or overwrites a **previous** run's comment — those stay on the PR as review history. Thereafter follow the update protocol at each phase boundary. In non-PR mode, or when the flag is off, skip this step (the narrative goes to chat as you proceed, or is produced once at the end, respectively).

**Phase 0.3.6 runs at this seam — after 0.3.5, before 0.4 — when its gate is met**; on a hit it ends the run, so 0.4/0.5 never run and their outputs are never consumed.

### 0.4 Discover related GitHub issue

Attempt to find the related issue number using these methods in order:

**From PR body** (look for `Resolves #N`, `Fixes #N`, or `Closes #N`):

If a PR number was provided:
```bash
ISSUE_NUM=$(gh pr view $ARGUMENTS --json body --jq '.body' | grep -oiE '(resolves|fixes|closes)[[:space:]]+#[0-9]+' | grep -oE '[0-9]+' | head -1)
```

If no PR number:
```bash
ISSUE_NUM=$(gh pr view HEAD --json body --jq '.body' 2>/dev/null | grep -oiE '(resolves|fixes|closes)[[:space:]]+#[0-9]+' | grep -oE '[0-9]+' | head -1)
```

**From branch name** (fallback — matches `issue-{number}` pattern set by `/devflow:implement`):
```bash
if [ -z "$ISSUE_NUM" ]; then
  # If reviewing a PR, use the stored head branch name from Phase 0.2
  # If reviewing current branch, use git branch --show-current
  BRANCH_NAME=$(printf '%s' "${STORED_HEAD_BRANCH:-$(git branch --show-current)}")   # capture form: the matcher descends into $(…); a bare VAR="…" assignment is a probe-denied shape (.github/workflows/matcher-probe.yml)
  ISSUE_NUM=$(echo "$BRANCH_NAME" | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+')
fi
```

If an issue number was found, fetch the issue:
```bash
gh issue view $ISSUE_NUM --json title,body
```

**Truncation rule:** Only use the **first 200 lines** of the issue body. This captures the summary and desired behavior while skipping excessive implementation detail.

Store the issue title and truncated body as `issue_context`. If no issue was found, set `issue_context` to empty and note: "No related issue found — skipping issue compliance check."

### 0.5 Classify the diff and decide the engine profile

Before launching anything, classify the diff. The classification scales agent dispatch so that tiny / config-only PRs don't pay the full engine cost (and so type-design-analyzer is dispatched only when there are *actually* new types, not when "class" happens to appear as a word elsewhere in the diff).

Compute five flags:

- `small_diff` = (total changed lines < 100) **AND** (changed-file count ≤ 3)
- `config_only` = every changed file has an extension in `{.yml, .yaml, .json, .md, .toml, .ini, .lock, .txt}`
- `has_new_types` = the added-lines slice of the diff (lines starting with `+` but not `+++`) contains, in a code file (file extension NOT in the `config_only` set above), a line that matches `^\+\s*(?:(?:final|abstract|readonly|export(?:\s+default)?|public|pub)\s+)*(class|interface|type|enum|struct|trait)\s+\w+`. The optional leading modifiers catch language-specific qualifiers (e.g. `final class`, `abstract class`, `readonly class`, `export class`, `export default class`, `public class`) — without them, the regex would silently miss genuinely-new-type diffs in languages whose declarations begin with a visibility / modality keyword.
- `engine_self_modifying` = any changed file's path matches `skills/**` OR `agents/**` OR `lib/**` (the DevFlow engine's own files, which live at the repo root in the devflow-autopilot repo). These are the SKILL.md / agent-definition / helper-script files that *are* the review engine — a typo here silently breaks every future review. `lib/**` is included because helper scripts and test fixtures under `lib/` are part of the engine surface. (This gate only fires when reviewing a PR against the DevFlow repo itself; on an adopter's repo these paths normally won't match the engine.)
- `detect_all_audit` = the diff **adds or changes a "detect-all" scanner / audit / coverage-invariant**: a new or modified function, test, or review/skill step that (a) **enumerates a *population* of sites** (files, symbols, config keys, checklist items, agents, call sites, …) and (b) **asserts a completeness property over that whole population** — a count or coverage assertion, a superset / subset check, or an "every / all / none-remaining / no other" claim. The load-bearing signal is the **combination** of *enumerate-a-population* AND *assert-it-is-complete* — set the flag only when the added/changed lines do **both**, so a reviewer applies the rule the same way twice. A single-target `grep`, a one-off equality assertion, or a check over a fixed hand-listed set is **not** this shape (it enumerates nothing, or asserts no completeness property). Read the flag off the *audit being introduced or edited* in the diff, not off whatever the audit happens to match. `detect_all_audit` is **independent of** the other four flags — it can co-occur with any of them: a detect-all audit added under `skills/**`/`lib/**` is also `engine_self_modifying`, but a detect-all audit added to product code sets `detect_all_audit` without it.

Compute counts from the diff already fetched in 0.2/0.3 — no extra `gh` calls.

Apply the engine profile per the table below. The first row **overrides** all others when its flag is set; otherwise the remaining rows apply per their combinations. Output one line announcing the chosen profile so the human reader knows the engine ran a leaner path on purpose, not by accident:

| Combination | Engine behavior |
|---|---|
| `engine_self_modifying` (any combination of the other flags) | Override the other flags' **checklist** behavior: run the **full Phase 1+2 checklist** (no skip — `checklist_skipped` stays `null`) and all four **always-on** Phase 3 agents (`code-reviewer`, `silent-failure-hunter`, `comment-analyzer`, `requesting-code-review`) unconditionally. The risk surface is "every future review breaks if this is wrong," which dwarfs the per-PR cost saving from a leaner profile. **Two structural-applicability gates survive the override** (they are about whether the agent has anything in the diff to analyze, not about cost): `type-design-analyzer` runs only when `has_new_types` is true, and `pr-test-analyzer` runs only when the **test-relevance predicate** (defined in Phase 3.1) matches. |
| `small_diff` AND `config_only` | Skip Phase 1 + Phase 2 (checklist gen + verify) entirely. Set `checklist_skipped = "intentional"`. In Phase 3.1, skip `devflow:type-design-analyzer` (`has_new_types` is false on a config-only diff) and apply the unified `pr-test-analyzer` test-relevance predicate (which skips on a config-only diff). |
| `config_only` (but not `small_diff`) | Run Phase 1+2 normally. In Phase 3.1, skip `devflow:type-design-analyzer` and apply the unified `pr-test-analyzer` test-relevance predicate (which skips on a config-only diff). |
| `small_diff` (but not `config_only`) | Run Phase 1+2 normally. In Phase 3.1, apply the `has_new_types` gate for `type-design-analyzer` and the unified `pr-test-analyzer` test-relevance predicate. |
| neither flag set | Run the full engine. In Phase 3.1, apply the `has_new_types` gate for `type-design-analyzer` and the unified `pr-test-analyzer` test-relevance predicate. |
| `detect_all_audit` (**composes with** any row above — never an override) | **In addition** to the profile the rows above select, **force the completeness-critic pass (Phase 3.1.5)**: the engine independently re-enumerates the audit's target population by a signal *other than the audit's own pattern* and emits a finding if the audit's matched set is not a superset. This is a *forced extra pass*, not a checklist or cost override — it fires regardless of `small_diff` / `config_only`, because a vacuous or incomplete "detect-all" audit is exactly the defect a lean profile would skip past. |

Concretely: when `engine_self_modifying` is true, the orchestrator does NOT set `checklist_skipped = "intentional"` regardless of `small_diff` / `config_only`, and the **always-on** Phase 3 agents all run. The override is the load-bearing rule that keeps the full checklist and the always-on reviewers wired in on engine-self-modifying diffs. It is **not** a blanket bypass of Phase 3.1's per-agent gates: the two structural-applicability gates — `has_new_types` for `type-design-analyzer`, and the test-relevance predicate for `pr-test-analyzer` — apply on every diff profile, `engine_self_modifying` included, because an agent with nothing in the diff to analyze adds only cost (a `null` type-design verdict, a `corroborating`-only test-analyzer run), never signal. The engine-risk rationale protects the checklist and the always-on agents, not the dispatch of demonstrably-inapplicable analyzers.

`has_new_types` is the canonical predicate for the type-design-analyzer gate in Phase 3.1 across all diff profiles; the previous heuristic ("check for `class ` in the diff") fires false-positives on YAML/markdown comments and is superseded.

`detect_all_audit` is **additive, never suppressed**: unlike the `engine_self_modifying` override, it never changes the checklist/agent profile — it only *adds* the Phase 3.1.5 completeness-critic pass on top of whatever profile the table selected, so even a lean `small_diff`/`config_only` profile still runs the critic when the flag is set.

Announce one line, e.g.:
- `Diff classification: engine_self_modifying (overrides other flags) → running full checklist + always-on agents — this diff modifies the review engine itself. type-design-analyzer / pr-test-analyzer still gated by applicability (has_new_types / test-relevance predicate).`
- `Diff classification: detect_all_audit (+ engine_self_modifying) → full checklist + always-on agents, AND forcing the Phase 3.1.5 completeness-critic pass — this diff adds/changes a detect-all audit, so the engine independently re-enumerates the audit's target set rather than trusting the audit's own output.`
- `Diff classification: engine_self_modifying, has_new_types=false, no test-relevant changes → full checklist + always-on agents; skipping type-design-analyzer + pr-test-analyzer (nothing in the diff for them to analyze).`
- `Diff classification: small_diff + config_only → skipping Phase 1+2 and pr-test-analyzer + type-design-analyzer.`
- `Diff classification: config_only → skipping pr-test-analyzer + type-design-analyzer (Phase 1+2 still run).`
- `Diff classification: full engine.`
<!-- devflow:review-ref phase=0 file=skills/review/phases/phase-0-setup.md end -->
