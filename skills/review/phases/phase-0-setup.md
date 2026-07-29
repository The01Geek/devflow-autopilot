<!-- devflow:review-ref phase=0 file=skills/review/phases/phase-0-setup.md start -->
## Phase 0: Setup

### 0.1 Check for uncommitted changes

Run:
```bash
git status --porcelain
```

If there is output, warn: "You have uncommitted changes that will not be included in this review."

**#504 displaced-path attribution.** If the run's engine-ground-truth block lists displaced paths, attribute any such path's `git status --porcelain` output — content delta, mode-only delta (the `chmod +x` floor flips `100644`→`100755` on every closure member tracked non-executable, every run, even when the PR touches none of them), OR untracked delta (a protected prompt-extension name the checkout never carried is *created* empty by the workflow's truncation step, so the path is reported as `??` rather than ` M`) — to the **trusted-source displacement** the block describes: expected displacement, NOT a PR defect or an uncommitted change to flag. The published list has **two producers** — the Stop-hook trusted-source floor (issue #458) and the prompt-extension truncation (issue #874) — so key the attribution on membership in the published list, never on which producer displaced a path.

**Match a porcelain path against the list by prefix, not by equality.** The list publishes **leaf file** paths, but `git status --porcelain` **collapses a wholly-untracked directory to the directory alone** — a consumer that tracks nothing under `.devflow/prompt-extensions/` reports `?? .devflow/prompt-extensions/`, and one tracking nothing under `.devflow/` reports `?? .devflow/`; neither leaf path appears. An equality-only predicate therefore matches nothing on exactly the consumer shape the untracked clause was added for, and the warning fires on every such review run. So attribute a porcelain path when it **is** a displaced path **or is a directory prefix of one**. All three delta kinds take that attribution, so an untracked displaced path draws no warning either. Remaining paths keep the warning sentence above verbatim. With no displaced list (local tier, manual `devflow.yml` path, consumer skip) all paths keep today's warning.

### 0.1.5 Persist the displaced-path list (compaction survival)

The engine-ground-truth block prepended to this run (rendered by `scripts/render-grounding-block.sh`) carries a displaced-paths section (section 5) ONLY when the workflow published a non-empty `HARDENED_PATHS` this run. Read that section and write the listed repo-relative paths to `.devflow/tmp/displaced-paths.txt` via the **Write tool** (one path per line; write an empty file when there is no such section — `Write(.devflow/tmp/**)` is already granted on the review tier). Phase 2.1a/2.1b, Phase-3 dispatch, and Phase 4.1.6 re-read this file to know which paths route their HEAD verification through `git show`, so a compacted long run keeps the routing at the far end where the sweep executes. A missing or empty file degrades to today's behavior (no displaced list → no routing, no attribution), never to a guess.

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

**Every command in this file interpolates the parsed `$PR_NUMBER` — the numeric token the skill root extracted from `$ARGUMENTS` — and never the raw `$ARGUMENTS`, because an argument string carrying a further token (e.g. `--issue N`) makes `gh pr view` exit non-zero on the unknown flag and the Phase-0.2 failure arm below kills the run before any phase executes.**

**If `$PR_NUMBER` is a PR number:**
```bash
gh pr diff $PR_NUMBER
gh pr view $PR_NUMBER --json headRefName,baseRefName,baseRefOid,headRefOid --jq '.'
```
If either command fails (non-zero exit code), stop immediately and report: "Failed to retrieve diff. Verify the PR number exists and you have required permissions."

Use the PR diff output for Phase 1. Store the head branch name, `baseRefOid` as `$PR_BASE_SHA`, `baseRefName` as `$PR_BASE_BRANCH` (the PR's own base ref, used by the head-override diff below; the name avoids the `BASE_REF` substring the `lib/test/run.sh` #424 grep-c pin forbids, mirroring `lib/fetch-pr-context.sh`), and `headRefOid` as `$PR_HEAD_SHA` — the head-override diff below, Phase 0.3.6's blocker-recheck fast path, and Phase 4's `Reviewed HEAD` line all need them. `$PR_BASE_SHA` (the immutable run-start `baseRefOid`) is retained as the deleted-base fallback below and the reviewer-prompt `Base SHA:` line.

**Caller head-override (fix-loop reuse).** A wrapping skill (currently `/devflow:review-and-fix`) may pass `head_override = local`. When set, take the PR's head from the local working tree instead of the API: set `$PR_HEAD_SHA=$(git rev-parse HEAD)` and fetch the diff with `git diff "origin/$PR_BASE_BRANCH...HEAD"` (three-dot) instead of `gh pr diff $PR_NUMBER`. **The base is the PR's own base ref `$PR_BASE_BRANCH` (its current fetched tip), not the run-start `$PR_BASE_SHA`** — matching `gh pr diff`'s non-override semantics, so a base commit an in-loop Checkpoint-3 (`scripts/update-branch-checkpoint.sh`) merges into the PR head mid-loop is excluded, not attributed as PR-added content (issue #503: once the merge made the stale run-start `baseRefOid` an ancestor, `merge-base(baseRefOid, HEAD)` collapsed to `baseRefOid`, degenerating the three-dot diff to `baseRefOid..HEAD` and sweeping in every newer base commit as PR-added). This lets a fix loop review locally-committed but unpushed commits — the remote `headRefOid` would otherwise lag and re-review pre-fix code. It requires the PR's head branch checked out; the caller guarantees this (review-and-fix Step 0.5). When `head_override` is absent (standalone `/devflow:review`, the default) use the API head as above; do **not** diff against local `HEAD`, since a standalone review must reflect the pushed PR state, not a dirty or stale checkout.

**Resolve the head-override base ref before diffing (mirrors `scripts/update-branch-checkpoint.sh`).** The checked arms below refresh the PR's base through an explicit refspec (including names with `/`), retry a shallow merge-base failure once after `--unshallow`, select the immutable run-start SHA only when the named base has disappeared, and make a retargeted/stacked PR's residual visible. Every terminal failure removes candidate and prior caches before stopping; the wrapping `/devflow:implement` run records that stop as **Blocked**, a standalone run stops and reports it.


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

The deleted-base fallback is **leak-equivalent to the pre-fix binding** when the base advanced (base content newer than `baseRefOid` re-enters the diff); accepted only because base deletion is rare and matches `gh pr diff`'s retained-SHA semantics. `--push-each-iteration` on a PR whose base differs from `$BASE` carries the separately reported residual leak; changing Checkpoint 3 to merge `baseRefName` is separate.

**Fail-closed at the producer (before the cache write).** Both local-diff paths — head override and current branch — stage raw and filtered candidates, then check a separate promotion write to `diff.patch` before checking the published cache can also be emitted to stdout. A producer, filter, promotion (including a partial write then nonzero), or stdout failure records its rc, removes every candidate and any prior `diff.patch`, and stops — an empty or stale cache must never reach the Phase 1–3 agents as "nothing to flag" and yield `APPROVE`. If the runner is terminated mid-command no downstream phase runs; a retry re-enters Phase 0.2, removes any prior cache before production, and republishes before Phase 1 reads. The wrapping `/devflow:implement` run records an observed stop as **Blocked**; a standalone run stops and reports it. (Phase 0.6's degraded note does **not** gate the agents' verdict, so the guard must sit here, before publication.)

**Caller run-id (run-scoped scratch).** This run's scratch under `.devflow/tmp/review/<slug>/` nests one level deeper under a per-run `<run-id>` so concurrent or repeated reviews of the same PR never clobber each other. Resolve `<run-id>` **once** at the start of Phase 0.2 and hold the literal for the whole run:

- A wrapping skill (currently `/devflow:review-and-fix`) may pass `run_id = <value>` — its own loop-start `RUN_ID`. When provided, use it verbatim so the engine's `diff.patch` lands in the *same* run directory as the wrapper's `iter-*.json` / `deferrals.json`.
- When absent (standalone `/devflow:review`), compute it with the **same derivation the progress-comment marker uses** — `${GITHUB_RUN_ID:-local-$(date -u +%Y%m%dT%H%M%SZ)}-${GITHUB_RUN_ATTEMPT:-1}` — and reuse that held literal everywhere (never recompute; on a local run the timestamp would otherwise drift between phases and scatter the scratch across directories).

**Note on `gh pr diff` path filtering.** `gh pr diff <N>` does NOT support path arguments — `gh pr diff <N> -- <file>` errors with `accepts at most 1 arg(s)` (cli/cli#5398, unresolved). Phase 1.1 sidesteps this: it never re-fetches a per-file diff — it slices the cached `diff.patch` with an `awk` section-range over its `^diff --git` headers (see Phase 1.1). Retained as a caution against re-introducing per-file slicing.

**If no argument (review current branch):**
```bash
git diff "origin/$BASE...HEAD"
git diff "origin/$BASE...HEAD" --name-only
```
Use `$BASE` from the guarded capture above, never a hardcoded `origin/main`, so a consumer whose trunk is `master`/`develop` diffs against the right base. If either command fails (non-zero exit code), stop immediately and report: "Failed to retrieve diff. Verify origin/$BASE is reachable and you are on a valid branch."

Use the diff output for Phase 1. The current branch is the review target.

For the checked cache producer below, render `<resolved-local-diff-base>` before executing the fence: substitute `origin/$BASE` in current-branch mode or the selected `$HEAD_OVERRIDE_BASE` value in PR head-override mode. This is a required non-shell placeholder, not an environment variable: if a runner drops the substitution the literal is not a valid ref and `git diff` fails closed, rather than collapsing an unset variable to the valid-but-empty `...HEAD` range. Standalone PR mode stays on the `gh pr diff` path and does not execute this fence.

If the diff is empty, report: "No changes to review. Branch is identical to $BASE." and stop.

**Cache the diff to disk.** Write the diff fetched above to `.devflow/tmp/review/<slug>/<run-id>/diff.patch` — **fetch once, do not re-run `gh pr diff` / `git diff`**. Compute `<slug>`:

- **PR mode:** `pr-<N>` where `<N>` is the parsed `$PR_NUMBER`.
- **Current-branch mode:** the current branch name sanitized for filesystem use — replace `/` with `-`, lowercase, drop any character that isn't `[a-z0-9._-]`. (Matches the workpad slug convention `/devflow:review-and-fix` already uses.)

and `<run-id>` per "Caller run-id" above (caller-provided when wrapped, else computed once here).

Combine the fetch with the cache write in one shot using `tee` so the diff is captured exactly once and stdout stays available for Phase 1. **Filter `.devflow/logs/**` hunks out as the diff streams to disk** — interpose an `awk` stage between fetch and `tee` so the cached `diff.patch` (and the stdout Phase 1 consumes) never contains a telemetry-log hunk:

```bash
mkdir -p .devflow/tmp/review/<slug>/<run-id>
gh pr diff $PR_NUMBER | awk '/^diff --git/{in_logs=/ [ab]\/\.devflow\/logs\//} !in_logs' | tee .devflow/tmp/review/<slug>/<run-id>/diff.patch
# or, in current-branch mode ($BASE from the guarded config-get capture above):
# git diff "origin/$BASE...HEAD" | awk '/^diff --git/{in_logs=/ [ab]\/\.devflow\/logs\//} !in_logs' | tee .devflow/tmp/review/<slug>/<run-id>/diff.patch
# In either local-diff mode, use this checked candidate/promote form.
# Render <resolved-local-diff-base> as the selected HEAD_OVERRIDE_BASE
# (PR head override) or origin/$BASE (current branch). Remove stale authority first.
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

**Why the `awk` filter — and why here.** Since issue #441 DevFlow persists durable telemetry to a dedicated **telemetry branch**, never touching the feature branch, so a normal run leaves **no** `.devflow/logs/` hunk in the PR diff and this filter is a no-op. It is **retained as a defensive guard** for a **pre-#441 legacy branch** carrying `chore: persist review-and-fix observability artifacts` commits on the feature branch, or a consumer that commits `.devflow/logs/` there for another reason. Such hunks are **DevFlow telemetry artifacts, not code-review subjects**, yet would appear in the PR diff where Phase 1/2/3 agents flag them as accreting hygiene artifacts. The filter strips them once, at the single cache-write point downstream phases read. The `awk` program sets `in_logs` on each `diff --git` header (true when the path **starts with** `.devflow/logs/` — anchored to the `a/`/`b/` diff-prefix boundary (` [ab]/.devflow/logs/`) so it matches only paths *rooted* there, never one containing the substring) and suppresses every line while `in_logs` holds; the next non-logs header resets it visible. A logs-only diff filters `diff.patch` to empty — the upstream "No changes to review" stop tests the *raw* fetched diff (before this filter) so it does **not** fire here; every downstream phase reads the empty `diff.patch` (Phase 0.3 an empty file list, Phase 3 agents an empty diff), so a telemetry-only PR is correctly reviewed as nothing to flag. A mixed diff keeps its real code hunks in order; the telemetry commits stay on the branch unchanged — only the engine's diff view is filtered. Standalone review uses the read-only profile's granted `gh pr diff`/`git diff`, `awk`, `tee`, `cat`, and `rm` heads. The wrapper-only local head-override path additionally needs git fetch and git ls-remote; only the writable implement/manual profiles reach it and grant those.

This replaces the bare `gh pr diff` / `git diff` invocation at the top of Phase 0.2 — use the `tee` form instead. Store `<slug>`, `<run-id>`, and the resolved diff path (e.g. `.devflow/tmp/review/pr-863/<run-id>/diff.patch`) so Phase 3 can substitute it into its agent prompts via `{DIFF_PATH}`. Directory creation is harmless if it already exists; the file is overwritten every run *within the same run-id*, never across runs.

**`.devflow/tmp/` should be gitignored** (ephemeral scratch); the rest of `.devflow/` (`config.json`, `learnings/`, the schema/example) is intentionally tracked. The scaffolder (`scripts/scaffold-config.sh`, run by `install.sh` / `/devflow:init`) writes a scoped `.devflow/.gitignore` ignoring only `tmp/`. This skill does not manage that entry (a repo-level concern); flag missing coverage in chat output only if `.devflow/tmp/` is not already ignored.

### 0.3 Get changed file list

Extract the list of changed files **by parsing the filtered `diff.patch` cached in 0.2** (read its `diff --git a/<path> b/<path>` headers), **not** from an independent `git diff --name-only` / `gh pr diff --name-only`. `.devflow/logs/**` paths were stripped from `diff.patch` in 0.2, so deriving the file list from it excludes them by construction — and Phase 1.1's batch slicing reads the **same** filtered `diff.patch`, so a `.devflow/logs/` hunk can never re-enter a batch slice, and Phase 3's agents Read the same cached diff. An independent `--name-only` would re-introduce those paths and desync the file list from the sliced batches. Store this list — Phase 1 and Phase 3 need it.

### 0.3.5 Seed the live progress comment (PR mode)

In PR mode, and when `devflow_review.live_progress_comment_enabled` is `true` (read it via `"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/config-get.sh .devflow_review.live_progress_comment_enabled true`), seed **this run's** live progress comment **now** — the engine's first GitHub write, so "review started" lands as early as possible. Create a fresh comment for this run, keyed by the run-keyed marker, with the Blueprint template (all boxes unticked) and the `Run` link to this job, per the **Live Progress Comment** section above. Because the marker carries this run's id, the find-or-resume lookup matches **only this run's** comment: on a mid-run retry (`rc=0`) it resumes that same comment, never overwriting a **previous** run's comment (those stay on the PR as review history). Thereafter follow the update protocol at each phase boundary. In non-PR mode, or when the flag is off, skip this step (the narrative goes to chat as you proceed, or once at the end).

**Phase 0.3.6 runs at this seam — after 0.3.5, before 0.4 — when its gate is met**; on a hit it ends the run, so 0.4/0.5 never run.

### 0.4 Discover related GitHub issue and resolve its acceptance criteria

**Resolve the issue number in this precedence: a caller-supplied `--issue N` value (bound as `$ISSUE_OVERRIDE` by the two skill roots), then the PR body's `Resolves`/`Fixes`/`Closes` reference, then the `issue-{N}` branch-name pattern.** A caller-supplied value **suppresses** both derivations — it is not run alongside them and never compared against them:

```bash
if test -n "${ISSUE_OVERRIDE:-}"; then
  ISSUE_NUM=$(printf '%s' "$ISSUE_OVERRIDE")
fi
```

If `$ISSUE_NUM` is still empty, attempt the derivations below in order.

**From PR body** (look for `Resolves #N`, `Fixes #N`, or `Closes #N`):

If a PR number was provided:
```bash
if [ -z "$ISSUE_NUM" ]; then
  ISSUE_NUM=$(gh pr view $PR_NUMBER --json body --jq '.body' | grep -oiE '(resolves|fixes|closes)[[:space:]]+#[0-9]+' | grep -oE '[0-9]+' | head -1)
fi
```

If no PR number:
```bash
if [ -z "$ISSUE_NUM" ]; then
  ISSUE_NUM=$(gh pr view HEAD --json body --jq '.body' 2>/dev/null | grep -oiE '(resolves|fixes|closes)[[:space:]]+#[0-9]+' | grep -oE '[0-9]+' | head -1)
fi
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

**Truncation rule:** Only use the **first 200 lines** of the issue body for the narrative `issue_context` — the summary and desired behavior, skipping excessive implementation detail. **The 200-line truncation bounds `issue_context` alone and never the acceptance-criteria value, which `acs-resolve` locates structurally and carries in full however far into the body its section begins.**

Store the issue title and truncated body as `issue_context`.

#### Resolve the acceptance criteria

`/devflow:implement`'s authoritative acceptance criteria live in the **workpad comment**, not the issue body — Phase 2.2.5 narrows them, Phase 2.2.6 rewrites their text, and Phase 3.4 retags them — so the criteria this engine judges against are resolved by `scripts/workpad.py acs-resolve`, never read off the issue body directly. That helper does all of the resolution deterministically in one process (it fetches the issue body itself, resolves both surfaces, retains the non-selected set as the divergence comparand, renders the one parsed workpad section twice — unfiltered as the comparand, post-merge-filtered as the reviewer-facing value — runs the PR-identity guard, and selects the reviewer-facing value); do not re-derive any part of it here — its contract is its `--help` and its module docstring.

When `$ISSUE_NUM` resolved, call it:

The numeric guard now lives INSIDE `cmd_acs_resolve` (issue #857): a non-numeric `$ISSUE_NUM` is a routed `resolver-unavailable` outcome with exit 0. The workpad-read routing was already internal and is unchanged by this issue — an *unreadable* workpad comment is `workpad-read-failed`, while an *absent* one falls through to `issue-body`. So the invocation is a single bare statement whose leading token is the helper path, with no `case` and no `if` compound the cloud matcher would refuse. Resolve the skill-dir anchor INLINE at each call site (never captured into a shell variable a later statement reads — issue #275).

**Two things are load-bearing about the shape below, and both are why it is NOT a capture.** First, the helper's stdout is the payload you must read: assigning it to `ACS_OUT=$(…)` would swallow all three blocks into a shell variable that does not survive the command boundary, leaving you with nothing to consume on the *successful* path — the sibling of the `$WP` defect the live-comment fallback in `skills/review/SKILL.md` fixes by echoing. Running the helper bare puts `criteria:` / `source:` / `divergence:` straight on stdout where you read them. Second, this is the **narrowest** shape available, not a measured-permitted one: `matcher-probe.yml` row 16 *exercises* the `;`-joined shape and row 17 the `if`-compound, but **no PERMITTED/DENIED verdict is recorded for either** — a row that exercises a shape has not measured it. So the bare leading-token invocation with a trailing `; echo "acs-rc=$?"` is chosen because it adds only a granted `echo` to a granted leading token and avoids the `&&`/`||` list **no probe row covers unconfounded** — review shape 3 *is* an `&&` list (`cd /tmp && printf … > /tmp/probe-03.txt`), but it confounds the list with a leading `cd` and a `/tmp` redirect, so its DENIED verdict is not attributable to the list — not because it is proven. Note also that the composite actually emitted here — a leading-token helper with an in-workspace `2>` redirect, `;`-joined to an `echo` — is covered by **no single probe row**. This is the primary and only path here, so read its permitted-ness as unrecorded and rely on the `acs-rc` token below to make a refusal observable.

**The two modes are two separate fences, and you emit exactly one of them** — the fence you do not select is not emitted at all. Emitting both would run the resolver twice and leave you reading the second run's payload; keeping them in separate fences makes that structurally impossible rather than prose-enforced.

**PR mode** (a `$PR_NUMBER` resolved) — emit this fence and no other:

```bash
"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/workpad.py acs-resolve "$ISSUE_NUM" --pr "$PR_NUMBER" 2>.devflow/tmp/review/<slug>/<run-id>/acs.err ; echo "acs-rc=$?"
```

**Current-branch mode** (no PR to bind to) — emit this fence and no other. It OMITS `--pr` entirely rather than passing an empty value (`--pr` is `type=int`, so an empty value is an argparse exit 2):

```bash
"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/workpad.py acs-resolve "$ISSUE_NUM" 2>.devflow/tmp/review/<slug>/<run-id>/acs.err ; echo "acs-rc=$?"
```

**Read the emitted `acs-rc` token — it is the only mechanism that makes a refusal observable.** The invocation's own exit status is what distinguishes "the helper ran and routed an outcome" from "the helper never ran": without it, empty stdout from a denied or non-executable invocation is indistinguishable from a thin-but-successful resolution, and the unestablished state would be collapsed onto the real value `none` — the exact collapse this section forbids. So: on `acs-rc=0`, consume the three blocks the helper printed above the token. On **any** non-zero `acs-rc` — including the 126/127 not-executable-or-not-found codes and the helper's own rc 3 — set `acceptance_criteria_source` to `resolver-unavailable` and read `.devflow/tmp/review/<slug>/<run-id>/acs.err` to quote the cause in the note. A **missing** `acs-rc` token is itself a refusal of the whole statement — likewise `resolver-unavailable`, never a success.

`acs-resolve` itself exits 0 on every resolvable state, including an absent or unreadable workpad, which it routes as an outcome carrying its own source token rather than as a run-ending error; a non-numeric `$ISSUE_NUM` is likewise routed (as `resolver-unavailable`, exit 0) by `cmd_acs_resolve`'s own guard rather than by a pre-call `case`. This mirrors how `skills/review/SKILL.md` seeds its live progress comment: the S1 numeric guard, the S2 `workpad.py` readability precheck, and the S3 rc-2 silent-exit discriminator (screens S1–S3) now live inside the bundled helper `scripts/seed-review-progress.sh`, which owns those screens as executable shell, rather than in a prompt fence.

Store the helper's three output blocks under exactly these run-scoped names, which later phases consume: `acceptance_criteria` (the reviewer-facing criteria block from the `criteria:` section), `acceptance_criteria_source` (the `source:` token), and `acceptance_criteria_divergence` (the `divergence:` lines). **The criteria are injected with box state neutralized — a tick is Phase 3.4's assertion by the author of the code under review that the criterion is satisfied, so shipping the box column would hand the merge-gating judge a specification pre-annotated by the party it is judging** (the helper has already applied both the post-merge filter and the box neutralization to this value; apply neither again).

**Each `resolver-unavailable` case — a non-numeric `$ISSUE_NUM` (now routed by `cmd_acs_resolve`'s own guard as an exit-0 `resolver-unavailable` source token, not a pre-call `case`), the `workpad.py` helper itself being absent/unreadable/non-executable, a permission/allowlist denial of the helper, an rc 126/127 not-executable-or-not-found, or the helper's own rc 3 (the issue body itself could not be read) — sets `acceptance_criteria_source` to `resolver-unavailable`, and the reason Phase 4 renders is that case's own warning text. When the helper never ran (or could not begin), it produced no reviewer-facing `source:` token, so `none` must never be substituted for the token it never produced.**

`acceptance_criteria_source` is exactly one of `workpad`, `issue-body`, `workpad-unmirrored`, `workpad-read-failed`, `pr-identity-mismatch`, `resolver-unavailable`, or `none`, and **Phase 4 reports each of them distinctly** — in particular `resolver-unavailable` (any refusal arm above: a non-numeric issue number, an absent/unreadable/non-executable `workpad.py`, a denied invocation, or any rc≠0 including rc 3's unreadable issue body) means **no surface was examined at all**, so it must never be reported in the wording used for a run that examined both surfaces and found nothing, and `workpad-unmirrored` (Phase 1.2 mirroring never ran) is the *opposite* claim from a legitimately empty section and must never be reported in the wording used for a PR that simply has no workpad, and `workpad-read-failed` is a transport failure that must not present as a normal issue-body resolution.

**On the local/interactive tier the permission classifier denies a helper invoked by path, so a desk run reaches a `resolver-unavailable` refusal arm above rather than any surface at all — and the degradation stays visible rather than silent because Phase 4 reports that unestablished state in its own wording, never as a surface that was read.**

If **no issue number resolved at all**, set `issue_context` and `acceptance_criteria` to empty, set `acceptance_criteria_source` to `none`, and note: "No related issue found — skipping issue compliance check." If an issue **did** resolve and the helper ran but returned no criteria (`acceptance_criteria_source` is `none` from the helper), keep `issue_context` and note instead: "Issue #$ISSUE_NUM resolved but no acceptance criteria were found on either surface — issue compliance is reported as a gap, not skipped." **If instead the call was refused above (`resolver-unavailable`), keep `issue_context` and note: "Issue #$ISSUE_NUM resolved but the acceptance-criteria resolver did not establish either surface (state here which case applied — either the helper RAN and routed `resolver-unavailable` as its own `source:` token, or it NEVER RAN and the observed failure is the evidence: a denied or non-executable invocation, an rc 126/127, the helper's rc 3, or a missing `acs-rc` token; no shell variable carries this) — neither surface was examined, so nothing is known about whether criteria exist." That note never claims either surface was checked: an unestablished measurement is never collapsed onto the real value `none`.** **These two states are distinct and the second one never claims the compliance check was skipped, because criteria-less is a reportable gap while issue-less is an absent subject** — Phase 4's `## Issue Compliance` arms are the coupled mirror of this distinction and are edited with it.

### 0.5 Classify the diff and decide the engine profile

Before launching anything, classify the diff. The classification scales the Phase 1+2 checklist so tiny / config-only PRs don't pay the full engine cost; the Phase 3 roster is decided separately by Phase 3.1's structural-applicability gates and the `iterations` exclusion on every profile (and so type-design-analyzer dispatches only for *actual* new types, not when "class" appears elsewhere in the diff).

Compute five flags:

- `small_diff` = (total changed lines < 100) **AND** (changed-file count ≤ 3). `small_diff` scales no part of the Phase 3 roster; its only effect is the Phase 1 and Phase 2 skip in conjunction with `config_only`.
- `config_only` = every changed file has an extension in `{.yml, .yaml, .json, .md, .toml, .ini, .lock, .txt}`
- `has_new_types` = the added-lines slice of the diff (lines starting with `+` but not `+++`) contains, in a code file (file extension NOT in the `config_only` set above), a line that matches `^\+\s*(?:(?:final|abstract|readonly|export(?:\s+default)?|public|pub)\s+)*(class|interface|type|enum|struct|trait)\s+\w+`. The optional leading modifiers catch language-specific qualifiers (e.g. `final class`, `export default class`, `public class`); without them the regex would miss new-type diffs in languages whose declarations begin with a visibility/modality keyword.
- `engine_self_modifying` = any changed file's path matches `skills/**` OR `agents/**` OR `lib/**` (the DevFlow engine's own files, at the repo root). These SKILL.md / agent-definition / helper-script files *are* the review engine — a typo here silently breaks every future review; `lib/**` is included because its helper scripts and test fixtures are part of the engine surface. (This gate fires only against the DevFlow repo itself; on an adopter's repo these paths normally won't match.) This flag forces no part of the Phase 3 roster — it is a checklist-only override (see the profile table).
- `detect_all_audit` = the diff **adds or changes a "detect-all" scanner / audit / coverage-invariant**: a new or modified function, test, or review/skill step that (a) **enumerates a *population* of sites** (files, symbols, config keys, checklist items, agents, call sites, …) and (b) **asserts a completeness property over that whole population** — a count/coverage assertion, a superset/subset check, or an "every / all / none-remaining / no other" claim. The load-bearing signal is the **combination** of *enumerate-a-population* AND *assert-it-is-complete* — set the flag only when the added/changed lines do **both**. A single-target `grep`, a one-off equality assertion, or a check over a fixed hand-listed set is **not** this shape (it enumerates nothing, or asserts no completeness). Read the flag off the *audit being introduced or edited*, not whatever it matches. It is **independent of** the other four flags and can co-occur with any: a detect-all audit under `skills/**`/`lib/**` is also `engine_self_modifying`, but one added to product code sets `detect_all_audit` alone.

Compute counts from the diff already fetched in 0.2/0.3 — no extra `gh` calls.

Apply the engine profile per the table below. The first row **overrides** all others' **checklist** behavior when its flag is set; otherwise the remaining rows apply per their combinations. Output one line announcing the chosen profile so the reader knows the engine ran a leaner path on purpose:

| Combination | Engine behavior |
|---|---|
| `engine_self_modifying` (any combination of the other flags) | Override the other flags' **checklist** behavior only: run the **full Phase 1+2 checklist** (no skip — `checklist_skipped` stays `null`). The risk — every future review breaks if this is wrong — dwarfs the per-PR saving from a leaner checklist. This flag forces **no** Phase 3 agent on: the Phase 3 roster is decided by Phase 3.1's structural-applicability gates and the `iterations` exclusion on every profile, this one included. The four always-on agents (`code-reviewer`, `silent-failure-hunter`, `comment-analyzer`, `requesting-code-review`) are roster members on every profile regardless of this flag, and `type-design-analyzer` / `pr-test-analyzer` stay gated by `has_new_types` / the **test-relevance predicate** (defined in Phase 3.1). |
| `small_diff` AND `config_only` | Skip Phase 1 + Phase 2 (checklist gen + verify) entirely. Set `checklist_skipped = "intentional"`. In Phase 3.1, skip `devflow:type-design-analyzer` (`has_new_types` is false on a config-only diff) and apply the unified `pr-test-analyzer` test-relevance predicate (which skips on a config-only diff). |
| `config_only` (but not `small_diff`) | Run Phase 1+2 normally. In Phase 3.1, skip `devflow:type-design-analyzer` and apply the unified `pr-test-analyzer` test-relevance predicate (skips on a config-only diff). |
| `small_diff` (but not `config_only`) | Run Phase 1+2 normally. In Phase 3.1, apply the `has_new_types` gate for `type-design-analyzer` and the unified `pr-test-analyzer` test-relevance predicate. |
| neither flag set | Run the full engine. In Phase 3.1, apply the `has_new_types` gate for `type-design-analyzer` and the unified `pr-test-analyzer` test-relevance predicate. |
| `detect_all_audit` (**composes with** any row above — never an override) | **In addition** to the profile the rows above select, **force the completeness-critic pass (Phase 3.1.5)**: the engine independently re-enumerates the audit's target population by a signal *other than the audit's own pattern* and emits a finding if the audit's matched set is not a superset. This is a *forced extra pass*, not a checklist or cost override — it fires regardless of `small_diff` / `config_only`, because a vacuous or incomplete "detect-all" audit is exactly the defect a lean profile would skip. |

`detect_all_audit` is **additive, never suppressed**: unlike the `engine_self_modifying` checklist override it never changes the checklist — it only *adds* the Phase 3.1.5 completeness-critic pass on top of whatever profile the table selected, so even a lean `small_diff`/`config_only` profile still runs the critic when the flag is set.

Concretely: when `engine_self_modifying` is true, the orchestrator does NOT set `checklist_skipped = "intentional"` regardless of `small_diff` / `config_only`. It forces no Phase 3 agent on: the Phase 3 roster is decided by Phase 3.1's per-agent gates on every diff profile, `engine_self_modifying` included. The four always-on agents are roster members on every profile, and the two structural-applicability gates — `has_new_types` for `type-design-analyzer`, and the test-relevance predicate for `pr-test-analyzer` — decide the rest, because an agent with nothing to analyze adds only cost (a `null` type-design verdict, a `corroborating`-only test-analyzer run), never signal.

`has_new_types` is the canonical predicate for the type-design-analyzer gate across all diff profiles, superseding the previous "check for `class ` in the diff" heuristic (false-positives on YAML/markdown comments).

Announce one line, e.g.:
- `Diff classification: engine_self_modifying (overrides other flags' checklist) → running full checklist. Phase 3 roster gated by Phase 3.1 applicability (has_new_types / test-relevance predicate) on every profile.`
- `Diff classification: detect_all_audit (+ engine_self_modifying) → full checklist, AND forcing the Phase 3.1.5 completeness-critic pass.`
- `Diff classification: small_diff + config_only → skipping Phase 1+2 and pr-test-analyzer + type-design-analyzer.`
- `Diff classification: full engine.`
<!-- devflow:review-ref phase=0 file=skills/review/phases/phase-0-setup.md end -->
