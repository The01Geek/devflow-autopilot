## Phase 1: Setup

Output: `Phase 1/4: Setup — creating the workpad and branch...`

**Ordering matters in Phase 1.** The workpad is the run's *only* GitHub comment and its "job started" acknowledgment. In a cloud run the `gate` job has already created a lean workpad before this skill starts, so 1.3 **resumes** it; in a local-tier run 1.3 creates it as the **first GitHub write** — either way before the branch (1.4). Fetch the issue (1.1) and parse its acceptance criteria (1.2) first because the workpad body mirrors them; then initialize-or-load the workpad and populate its Acceptance Criteria; then create the branch and immediately fill the workpad's `Branch` line.

### 1.1 Fetch the GitHub Issue

Run:
```bash
gh issue view $ARGUMENTS --json title,body,labels,number
```

If this fails, stop immediately and report: "Error: Could not fetch GitHub issue #$ARGUMENTS. Verify the issue number exists."

Save the issue title, body, labels, and number — you will use these throughout the workflow. Note whether the labels include `bug` — Phase 2.1.5 depends on it.

### 1.2 Parse Acceptance Criteria from the issue body

Run the bundled parser to extract `## Acceptance Criteria` and (optional) `## Test Plan` sections from the issue, pre-classifying each criterion as either code-verifiable or *post-merge*:

```bash
"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/parse-acs.py --issue $ARGUMENTS > /tmp/acs-${ARGUMENTS}.md
```

The output is checkbox lines ready to splice into the workpad's `## Acceptance Criteria` section, with ` (post-merge)` appended to any criterion whose text matches the bundled trigger phrases (see `parse-acs.py`'s `POST_MERGE_TRIGGERS` list for what's matched). When no AC section exists, the helper prints `_(none provided in issue body)_` and Phase 3.4 passes trivially.

A post-merge criterion is **not** deferred work (that's the 2.2.5 rule) — the code is in-scope and ships in this PR; only the *verification* happens after merge. The Phase 3.4 gate ignores `(post-merge)`-tagged items for blocking; /pr-description in Phase 4.2 surfaces them as a `## Post-Merge Verification` checklist in the PR body.

**Orchestrator override authority.** The trigger-phrase classifier is a heuristic, not exhaustive. After running the helper, eyeball each criterion and override if needed:
- *Demote to code-verifiable* — when a matching phrase appears inside quoted/example text within the criterion rather than describing the verification step itself (e.g. the criterion quotes a function name that happens to contain "click"). Strip the ` (post-merge)` suffix in the file before mirroring.
- *Promote to post-merge* — when no trigger phrase matched but the criterion's intent clearly requires a live PR/deploy/CI environment. Append ` (post-merge)`.

Either kind of override goes into the workpad notes (`--note`) with a one-line reason.

A criterion that is partially live (mixed code + live concerns) is tagged post-merge — verify the code-part during /devflow:implement, leave the live-part for after-merge. **"Verify the code-part" is the Pre-merge probe contract, not just files-in-the-diff:** before this tag exempts the criterion from the Phase 3.4 gate, run that contract — stated authoritatively in `skills/implement/phases/phase-3-review.md` (Phase 3.4), so this rule is a pointer, not a second copy: decompose the criterion into pre-merge-observable preconditions and genuinely-live residue, probe every observable precondition read-only, and record each probe command and observed result in the tag `--note` (or the explicit finding "no pre-merge-observable precondition" when the set is empty). This is the **same contract** the Phase 3.4 retro-tag path runs, so a tag-time deferral and a retag-time deferral carry an identical obligation. A probe whose observed result shows the deferred verification cannot succeed as shipped routes to a pre-merge fix or the Blocked path, never a tag; a denied probe is recorded as denied and does not block. **A passed probe never ticks the AC box** — it only narrows the deferral to the genuinely-live residue; the live signal still owns the tick.

### 1.3 Initialize or Load the Workpad

The workpad is created before the branch exists so the requester sees an acknowledgment immediately. In a cloud run the `gate` job already posted a lean workpad; in a local run you create it here. Set `ISSUE_NUMBER=$ARGUMENTS`, derive the run link, and check whether a workpad already exists:

```bash
ISSUE_NUMBER=$ARGUMENTS
RUN_URL="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"   # "/actions/runs/" segment is literal; empty env (local run) → use a "_(local run)_" placeholder
WORKPAD_ID=$("${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/workpad.py id "$ISSUE_NUMBER" || true)
```

- **`WORKPAD_ID` empty (fresh issue — local-tier run with no `gate` job)** → Build the lean skeleton with the helper and create it, then mirror the issue's Acceptance Criteria into it:
  ```bash
  BODY=$(mktemp)
  # Add --no-reproduction for non-bug issues (labels from 1.1) so the bug-only
  # "reproduction captured" sub-item isn't rendered; omit the flag for bug issues.
  workpad.py new-body $ISSUE_NUMBER --run-link "[View run]($RUN_URL)" > "$BODY"   # + --no-reproduction unless the issue is bug-labelled; omit --run-link for a local run
  workpad.py create $ISSUE_NUMBER "$BODY"
  workpad.py update $ISSUE_NUMBER --replace-acs-file /tmp/acs-${ARGUMENTS}.md
  ```
  `new-body` seeds `**Status:** 🚀 Setup`, the `**Branch:** _(creating…)_` placeholder (filled in 1.4 the instant the branch exists), the friendly `Last updated`, the `## Progress` checklist (the bug-only `reproduction captured` sub-item is rendered only when `--no-reproduction` is omitted) with the `/devflow:implement run started` note nested under Setup, a placeholder `## Plan` (filled in 2.2), a placeholder `## Acceptance Criteria` (you replace it above), and an empty `## Devflow Reflection` `<details>` block. The `## Reproduction` section is added later in 2.1.5 if applicable.
- **`WORKPAD_ID` non-empty (resume — the normal cloud path, since `gate` pre-created it; or a re-run)** → Read the live body with `workpad.py body $WORKPAD_ID`. Treat its `## Progress` notes and `Devflow Reflection` as load-bearing context (see Workpad Reference). Reset for this run **and populate the Acceptance Criteria** (a `gate`-created workpad carries only a placeholder AC section, so always replace it):
  ```bash
  workpad.py update $ISSUE_NUMBER \
      --status Setup \
      --run-link "[View run]($RUN_URL)" \
      --replace-acs-file /tmp/acs-${ARGUMENTS}.md \
      --note "/devflow:implement run resumed"
  ```
  **Legacy-workpad migration (required):** a workpad created before run/PR links and the `## Progress` checklist existed won't have those lines. `--run-link`/`--pr-link` insert the missing header lines on their own, but `--tick-progress`/`--note` (used at every later phase boundary) will **abort the run** with `section '## Progress' not found` if the section is absent. So when resuming such a workpad you MUST seed a `## Progress` section before Phase 1.5 — `workpad.py body` the live comment, splice the `## Progress` checklist from the template above into the body (right after the front-matter, before `## Plan`), and `workpad.py patch $WORKPAD_ID <file>`. Do not leave it to chance: skip this and the first `--tick-progress`/`--note` call fails closed.

After this step, every later phase boundary touches the workpad via `workpad.py update $ISSUE_NUMBER ...` — no `WORKPAD_ID` variable to track across calls.

### 1.4 Create or Detect Feature Branch

Decide whether you are **already on the branch to use** or must **create one**. Two independent signals mean "already on it — skip creation":

1. **A linked git worktree** — the local harness pre-creates a worktree and checks out a branch for you (e.g. `worktree-issue-165`), whatever its name. This is the deterministic, **naming-independent** signal: a linked worktree's `--git-common-dir` (the main repo's `.git`) differs from its `--git-dir` (`.git/worktrees/<name>`); in the main working tree they are equal. The two are compared in **absolute form** (`--path-format=absolute`) so the test reflects directory identity rather than path representation.
2. **A recognized feature-branch name** — `claude/issue-*` / `issue-*`, the cloud-tier GitHub Action path (the Action checks out such a branch; it is not a worktree).

Otherwise, create a fresh feature branch off the base.

The base branch is **read from config** (`base_branch` in `.devflow/config.json`, default `main`) — never hard-code `main`, so the run branches off whatever trunk the consumer repo actually uses (`master`, `develop`, …). Resolve it **first**, because the worktree check needs it (it must never reuse the base branch itself — never build directly on trunk, even inside a worktree):

```bash
# config-get.sh itself falls back to the supplied `main` default — printing it,
# exit 0 — on the ordinary SOFT paths: a missing config file or an absent/empty
# key. It does NOT apply the default on a HARD failure — a malformed/unreadable
# .devflow/config.json, or a missing `python3` (the resolver runtime) — which exits
# non-zero with empty stdout. So this guard exists only for those two hard paths:
# catch the empty read and supply `main` here (config-get already handled the
# soft paths). It trusts config-get's contract that it prints a fully-resolved
# value or nothing, never a partial/garbage string.
BASE=$("${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/config-get.sh .base_branch main) || BASE=""
[ -n "$BASE" ] || { echo "devflow: base_branch read failed (malformed config or missing python3); falling back to 'main'" >&2; BASE=main; }
CUR=$(git branch --show-current 2>/dev/null) || CUR=""
```

Now decide. Set `USE_CURRENT=1` to mean "reuse `$CUR`, skip creation":

```bash
USE_CURRENT=
# Resolve the git-dir layout ONCE, in ABSOLUTE form (`--path-format=absolute`) so the
# worktree comparison is byte-consistent regardless of how the caller's cwd was spelled —
# a harness-injected GIT_DIR / GIT_COMMON_DIR (or a non-root cwd) could otherwise print
# the same directory two different ways and false-positive "linked worktree". Note:
# --path-format=absolute normalizes relative vs. absolute output but does NOT canonicalize
# symlinks, `..`, or trailing slashes. A hard `git rev-parse` failure (corrupt repo,
# broken git, or git < 2.31 which lacks --path-format) yields an empty string: that fails
# CLOSED to the create path below with an attributable breadcrumb.
COMMON_DIR=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || COMMON_DIR=""
GIT_DIR_PATH=$(git rev-parse --path-format=absolute --git-dir 2>/dev/null) || GIT_DIR_PATH=""
[ -n "$COMMON_DIR" ] && [ -n "$GIT_DIR_PATH" ] || echo "devflow: one or both git-dir path values are empty (git < 2.31 lacking --path-format, repo corrupt, or injected GIT_DIR/GIT_COMMON_DIR env override) — linked-worktree detection (Signal 1) disabled; if this is actually a worktree, check git version, repo integrity, and env" >&2
# Reuse $CUR ONLY when it is a real branch (non-empty — not a detached HEAD) and NOT the
# base branch (never build directly on trunk, even in a worktree). These two guards
# apply to BOTH reuse signals, so they sit out here once — a base branch that happens to
# be named like a feature branch (`base_branch` = `issue-next`) must still create, not
# reuse, via Signal 2.
if [ -n "$CUR" ] && [ "$CUR" != "$BASE" ]; then
  # Signal 1 — linked worktree (naming-independent): the worktree's --git-common-dir
  # differs from its --git-dir; in the main working tree they are equal. This fires
  # whatever the harness named the worktree branch, fixing the case where a
  # `worktree-issue-<N>` branch (matching neither name pattern below) used to fall
  # through and create a SECOND branch.
  if [ -n "$COMMON_DIR" ] && [ -n "$GIT_DIR_PATH" ] && [ "$COMMON_DIR" != "$GIT_DIR_PATH" ]; then
    echo "devflow: in a linked worktree on '$CUR' (≠ base '$BASE') — using it as the feature branch, skipping creation" >&2
    USE_CURRENT=1
  fi
  # Signal 2 — cloud-tier recognized name (kept as a second skip condition).
  case "$CUR" in
    claude/issue-*|issue-*) USE_CURRENT=1 ;;
  esac
fi
```

**If `USE_CURRENT` is set, skip branch creation entirely** — `$CUR` is the feature branch; jump straight to filling the workpad `Branch` line below.

Otherwise, create a new branch. The canonical branch name is computed by the helper (handles slugification, unicode, length truncation, and collision suffixing deterministically):

Write the issue title (from the `gh issue view` above) to a temp file with the **Write tool** — `/tmp/devflow-issue-$ARGUMENTS-title.txt` — then derive the branch from it. Using `--title-file` instead of passing the title as a positional shell argument avoids breakage when the title contains quotes, backticks, or `$`.

```bash
if [ -z "$USE_CURRENT" ]; then
  # Fetch the base explicitly with a DevFlow breadcrumb so a bad/offline base is
  # attributable here, not a bare git error downstream — most importantly when the
  # fallback 'main' isn't the consumer's real trunk (a master/develop repo).
  git fetch origin "$BASE" || { echo "devflow: could not fetch base branch 'origin/$BASE' — if the base is correct, check network/auth; otherwise set base_branch in .devflow/config.json to the repo's real trunk (master/develop/…)" >&2; exit 1; }
  BRANCH=$("${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/branch-for-issue.py $ARGUMENTS --title-file /tmp/devflow-issue-$ARGUMENTS-title.txt) || { echo "devflow: branch-for-issue.py failed — could not derive a branch name for issue #$ARGUMENTS; check that the issue title file exists and the issue number is valid" >&2; exit 1; }
  [ -n "$BRANCH" ] || { echo "devflow: branch-for-issue.py returned an empty branch name for issue #$ARGUMENTS — cannot create a branch" >&2; exit 1; }
  git checkout -b "$BRANCH" "origin/$BASE"
fi
```

**Immediately fill the workpad's `Branch` line** (so the placeholder from 1.3 is never left on a completed run):
```bash
workpad.py update $ISSUE_NUMBER --branch "$(git branch --show-current)"
```

### 1.5 Push Branch

```bash
git push -u origin HEAD
```

Then tick the Setup phase in the workpad's `## Progress` checklist:
```bash
workpad.py update $ISSUE_NUMBER --tick-progress "branch & workpad"
```

### 1.6 Issue-Claim Audit

Before Phase 2 begins, operationalise the Phase 2.1 principle that "the issue body is a starting point, not the source of truth" with the targeted pre-checks below that catch wrong scope, policy, dependency, and execution-capability assumptions before any code edit. Run after the issue data from 1.1 is in hand; passes are independent (read their sources in any order or in a single batch). Record each finding immediately via `workpad.py update $ISSUE_NUMBER --reflection-kind note --reflection "issue-claim audit ({type}): {finding}"`. A claim that confirms correctly is still worth a one-line note — it proves the assumption was checked, not inherited.

**Scope:** the explicitly-defined claim types below only. Do not attempt to verify every sentence in the issue body — open-ended verification creates a runaway discovery loop and produces false-positive discrepancies on subjective or aspirational claims.

#### Pass 1 — Count or enumeration claims

Scan the issue body's Technical Context and Implementation Notes for numeric claims about codebase entities — file counts, skill counts, directory counts, item lists (e.g. "N skill directories", "four agents", "the five validators"). For each, verify against the actual codebase via `git ls-files`, `ls`, or grep:

```bash
# Adapt to the specific entity the issue names:
git ls-files 'skills/*/SKILL.md' | wc -l   # skill count
ls -d agents/*/                              # agent enumeration
```

Record: `--reflection-kind note --reflection "issue-claim audit (count): claimed '{N} X', verified '{M}' at HEAD"`. Use the verified count as the working assumption from Phase 2 onward; discard the issue body count when they differ. If no count or enumeration claims are found in the issue body, record: `--reflection-kind note --reflection "issue-claim audit (count): no count or enumeration claims found — pass complete"`.

#### Pass 2 — Negative-scope claims (explicit surface exclusions)

Scan the issue body's Technical Context for claims that explicitly exclude a surface from scope — "no X is required", "no workflow change", "no runtime change", "no agent modification". For each exclusion, trace whether the change the issue proposes to make could affect that surface.

**Cloud-tier workflow impact check (mandatory when editing any `skills/*/SKILL.md`).** When any `skills/*/SKILL.md` is being added or modified, check whether any new shell helper it invokes is present in the cloud profile allowlist in `.github/workflows/devflow-runner.yml` and any vendored consumer copy:

```bash
grep -n 'TOOLS=' .github/workflows/devflow-runner.yml
# The vendored consumer copy is commonly absent. Test for it first so an absent
# file is NOT conflated with "helper missing from TOOLS=" — a fail-open that would
# silently record "no impact" when the guard never ran. Treat the two as distinct:
VENDORED=.devflow/vendor/devflow/.github/workflows/devflow-runner.yml
if [ -f "$VENDORED" ]; then
  grep -n 'TOOLS=' "$VENDORED"   # present: empty result here means a real allowlist gap
else
  echo "vendored copy absent — check not applicable (NOT a no-impact result)"
fi
```

A present-but-no-match grep on either file is a real allowlist gap (the helper is missing from `TOOLS=`); an absent vendored file is "check not applicable" — never read it as confirmation of no impact. If the trace finds a required change the issue excluded, record: `--reflection-kind note --reflection "issue-claim audit (negative-scope): issue excluded '{surface}' but trace requires it — adding to plan"`, then add the missed surface to the working plan before 2.2 begins. If the trace confirms the exclusion is correct (no impact on that surface), record: `--reflection-kind note --reflection "issue-claim audit (negative-scope): issue excluded '{surface}'; trace confirms no impact"`. If the issue body contains no scope-exclusion claims, record: `--reflection-kind note --reflection "issue-claim audit (negative-scope): no scope-exclusion claims found — pass complete"`.

#### Pass 3 — Policy-referencing claims in ACs

Scan the issue's Acceptance Criteria for explicit policy directives — versioning rules ("default no version bump"), testing process requirements, or any AC that names a policy file as the authority. For each, read the operative policy source verbatim:

- `.devflow/prompt-extensions/implement.md` — versioning and bump increment rules
- `CLAUDE.md` — repo conventions

When an AC claim contradicts the operative policy, do not proceed to Phase 2. Record the contradiction: `workpad.py update $ISSUE_NUMBER --status Blocked --reflection-kind blocked --reflection "issue-claim audit (policy): AC claims '{AC text}' but operative policy in {file} states '{policy text}' — contradiction requires user resolution before Phase 2"`, then emit the 👎 outcome reaction (see *Outcome reaction* in the Workpad Reference) and stop the run.

When the AC claim matches the policy, record the confirmation: `--reflection-kind note --reflection "issue-claim audit (policy): AC aligns with {file}"`. If the issue's ACs contain no explicit policy directives, record: `--reflection-kind note --reflection "issue-claim audit (policy): no policy-referencing AC claims found — pass complete"`.

#### Pass 4 — Declared sequencing-dependency claims

Scan the issue body for explicit claims that this work **depends on** or **must land after** another issue/PR — the phrasings `depends on #N`, `must merge after #N`, `blocked by #N`, `follow-up to #N`, `after #N and #M`, or a dedicated `## Dependencies` section listing `#N` references. Building on unmerged prerequisite work is the failure this pass catches deterministically (the #157 retrospective flagged the absence of any such verification, and the #247 run re-confirmed it).

**Scope:** only *explicit* dependency directives. A `#N` that is a plain cross-reference ("as in #247", "the #157 retrospective flagged this", "carried from #241") is **not** a declared dependency — it is provenance/context, not a sequencing constraint. Do not treat every `#N` in the body as a dependency; extract only those attached to a depends-on / must-merge-after / blocked-by / follow-up-to phrasing (or living under a `## Dependencies` heading).

For each declared dependency `#N`, check its state via `gh issue view` (works for both issues and PRs — a PR number resolves too):

```bash
gh issue view N --json state,title --jq '.state'   # OPEN | CLOSED | MERGED
```

Note the state domain: an **issue** resolves to `OPEN` or `CLOSED`, but a **PR** resolves to `OPEN`, `CLOSED`, or `MERGED`. A prerequisite has *landed* — the condition this pass verifies — when it is `CLOSED` **or** `MERGED`; only `OPEN` means it has not landed. Treat `MERGED` exactly like `CLOSED` (a merged PR is the canonical "prerequisite shipped" case); do **not** route a `MERGED` dependency to the Blocked path.

- **All declared dependencies are `CLOSED` or `MERGED`** (or the issue declares none) → the prerequisites have landed; record the confirmation: `--reflection-kind note --reflection "issue-claim audit (dependency): declared dependencies {#N, #M} all landed (closed/merged) — safe to build on"` (or, when none were declared, `--reflection-kind note --reflection "issue-claim audit (dependency): no declared sequencing dependencies found — pass complete"`).
- **Any declared dependency is still `OPEN`** → do not proceed to Phase 2. Building on unmerged prerequisite work is exactly the mistake this pass exists to stop. Record the block and stop the run: `workpad.py update $ISSUE_NUMBER --status Blocked --reflection-kind blocked --reflection "issue-claim audit (dependency): declared dependency #N is still OPEN — this issue states it must land after #N; building now would build on unmerged work. Resolve/merge #N (or amend the issue if the dependency is stale) before re-running Phase 1"`, then emit the 👎 outcome reaction (see *Outcome reaction* in the Workpad Reference) and stop.
- **A dependency reference cannot be resolved** (a non-zero `gh issue view` — the number is wrong, or gh/network failed) → this is a *command failure* that says nothing about the dependency's state, so do **not** treat it as closed. Record it as actionable and take the Blocked path rather than fail open: `workpad.py update $ISSUE_NUMBER --status Blocked --reflection-kind blocked --reflection "issue-claim audit (dependency): could not resolve declared dependency #N state (gh issue view failed — wrong number or gh/network); cannot confirm it merged before building. Verify #N and re-run Phase 1"`, then emit the 👎 outcome reaction and stop.

#### Pass 5 — Execution-capability claims (workflow-resident ACs vs. the executing credential)

Scan the Acceptance Criteria for any criterion whose satisfaction requires **editing a file under the repo's own `.github/workflows/`** — a workflow YAML, or a file coupled to that edit that cannot ship without it (most commonly a `lib/test/run.sh` pin that asserts workflow content and turns CI red the moment the workflow change is missing). This pass converts the CLAUDE.md-documented credential boundary — "workflow changes land via a human/PAT, not an agent run" — into a plan-time routing decision, so a workflow-resident AC is deferred here rather than discovered at push time after a full commit has already been built (the #318/#319 mid-run-revert thrash this pass exists to stop).

**Static, never a live probe.** Like the four passes above, this pass is best-effort and static: match each AC's target surface against the repo's `.github/workflows/` by reading the **AC text and the surfaces it implies** — do **not** run a `gh`/API probe to test the token's actual scope. The interactive-tier classifier can deny `gh`, and a probe would turn a diagnostic into a new Phase 1 failure mode.

**Phase 1.6 records a *provisional* capability flag; Phase 2.2.5 confirms it against the actual planned diff.** This pass runs before Phase 2 planning, so the concrete diff does not exist yet — detection here is necessarily from the AC text and the surfaces it names (an AC that names a workflow file, requires CI to go red/green on a workflow change, or names a coupled `lib/test/run.sh` pin). That catches the ACs whose workflow-residence is visible in their own text. An AC whose workflow-residence surfaces **only during implementation** — its text never names `.github/workflows/`, but the plan discovers it must edit one — is caught at **Phase 2.2.5**, which re-evaluates the capability decision against the concrete planned diff before any code is written (that is where the scope-adjustment actually narrows the ACs). So Pass 5 is the plan-time *first* filter, not the last word: it records the provisional flag on the ACs it can see, and 2.2.5 is the backstop that also catches the ones the plan surfaces. This closes the gap **provided planning enumerated the full file set**; if implementation itself (Phase 2.3) later reveals a required `.github/workflows/` edit that neither filter caught — planning was incomplete — re-apply the 2.2.5 scope-adjustment **then, before committing**, so a capability-blocked AC is still never carried to push time on the cloud tier.

**Key the routing decision on the pushing credential's actual capability, not on the tier or the path alone.** The block is a property of *who is pushing*, not of the path, and — crucially — **not of the cloud tier as a whole.** Whether a `.github/workflows/` push succeeds turns on the credential:

- A **local/interactive-tier** run (no `GITHUB_ACTIONS`) pushes workflow files routinely (a human credential — issue #331 itself landed that way).
- A **cloud-tier** run's capability depends on whether a **workflow-capable token** is in play. DevFlow's `devflow-implement` workflow mints an optional GitHub App installation token (Contents **and** Workflows write) and seeds it into `actions/checkout` **when — and only when — the `DEVFLOW_APP_ID` repository variable is set** (issues #357/#358); the workflow exports that variable to this run as the `DEVFLOW_APP_ID` environment value. When **`DEVFLOW_APP_ID` is non-empty**, the seeded App token carries the `workflows` scope and this run pushes `.github/workflows/` exactly like a human run — **do NOT defer.** When **`DEVFLOW_APP_ID` is empty/unset**, the run falls back to the built-in `GITHUB_TOKEN` (github-actions[bot]), which **cannot** push `.github/workflows/` — that is the one enumerated blocked capability.

**Defer only when you can positively confirm the pushing credential cannot push a workflow file — i.e. a cloud-tier run (`GITHUB_ACTIONS=true`) whose `DEVFLOW_APP_ID` is empty/unset.** In every other case — a local/interactive run (no `GITHUB_ACTIONS`), or a cloud run with a workflow-capable App token (`DEVFLOW_APP_ID` non-empty) — the credential *can* push `.github/workflows/`, so record the finding as a note and proceed; neither defer nor block. Keying on the **tier alone** (cloud ⇒ defer) is a false premise: it spuriously defers deliverable workflow work on the App-configured cloud tier this repo itself runs — where `DEVFLOW_APP_ID` is set and the seeded App token (#357/#358) pushes workflows just fine — inverting this pass's intent and declining work the run could ship. Keying on the **path alone** would wrongly split local work.

**When a discriminating signal is genuinely unreadable, proceed — do not defer.** Both signals are directly observable in the DevFlow cloud environment (`GITHUB_ACTIONS` from the runner, `DEVFLOW_APP_ID` exported by the `devflow-implement` workflow — always exported, empty-valued when the variable is unset), so the deferral condition is a conjunction of two *positively-confirmed* facts. If you cannot confirm both (no `GITHUB_ACTIONS`, or no `DEVFLOW_APP_ID` value exported to read at all), treat the credential as workflow-capable and proceed. This is the safe direction *post-#357*: a **spurious deferral silently under-delivers shippable workflow work** (the exact failure this keying corrects), whereas a genuinely-unpushable workflow edit that slips through fails **loudly and recoverably at push time** — the pre-#357 behavior — not a silent corruption.

**Match only the repo's *own* `.github/workflows/`.** A vendored consumer copy under `.devflow/vendor/devflow/.github/workflows/` is an ordinary pushable file, not a workflow the executing token gates — never treat a vendored-path edit as capability-blocked.

Route by capability (the deferral arms below are the **cloud-tier, `DEVFLOW_APP_ID`-empty** case — the only case whose credential cannot push a workflow file):

- **Credential is workflow-capable** — a local/interactive run (no `GITHUB_ACTIONS`) **or** a cloud run whose `DEVFLOW_APP_ID` is non-empty (the seeded App token carries the `workflows` scope) → behavior is unchanged: record the finding as a note and proceed — never defer, never block. `--reflection-kind note --reflection "issue-claim audit (execution-capability): credential is workflow-capable — workflow-file ACs are pushable by this run; no deferral"` (or, when no AC touches workflows, `--reflection-kind note --reflection "issue-claim audit (execution-capability): no workflow-resident acceptance criteria found — pass complete"`).
- **Cloud tier, `DEVFLOW_APP_ID` empty, but no in-scope AC is workflow-resident** → record the clean confirmation and proceed: `--reflection-kind note --reflection "issue-claim audit (execution-capability): cloud tier — no acceptance criterion requires editing .github/workflows/; nothing to defer"`.
- **Cloud tier, `DEVFLOW_APP_ID` empty, some but not all in-scope ACs are workflow-resident** → route every capability-blocked AC through the Phase 2.2.5 scope-adjustment **before Phase 2.3 writes any code**: narrow the workpad ACs to the pushable subset, and preserve each deferred criterion verbatim in the 2.2.5 `--note` with the `GITHUB_TOKEN`-fallback workflows-scope boundary (no workflow-capable App token; `DEVFLOW_APP_ID` unset) named as the reason (Phase 4.0 then files the workflows-capable follow-up). Treat a `lib/test/run.sh` pin (or any file) that asserts the deferred workflow's content as **blocked with it**, so the pushable subset stays CI-green on its own. Record here: `--reflection-kind note --reflection "issue-claim audit (execution-capability): cloud tier — ACs {list} require editing .github/workflows/ (incl. coupled CI pins), which this run's GITHUB_TOKEN fallback (no workflow-capable App token; DEVFLOW_APP_ID unset) cannot push; deferring via 2.2.5 to a workflows-capable follow-up"`.
- **Cloud tier, `DEVFLOW_APP_ID` empty, every in-scope AC is workflow-resident** → there is no shippable subset, so take the Phase 1 Blocked path instead of opening a near-empty PR: `workpad.py update $ISSUE_NUMBER --status Blocked --reflection-kind blocked --reflection "issue-claim audit (execution-capability): every in-scope acceptance criterion requires editing .github/workflows/, which this cloud run's GITHUB_TOKEN fallback (no workflow-capable App token; DEVFLOW_APP_ID unset) cannot push — this issue must be implemented by a workflows-capable run (a human/PAT, or a cloud run with the DevFlow App configured). Re-dispatch there; no PR opened"`, then emit the 👎 outcome reaction (see *Outcome reaction* in the Workpad Reference) and stop the run.

**Boundary-assumption caveat (state it in the note).** The deferral fires only when this run's credential is the `GITHUB_TOKEN` fallback (github-actions[bot], no `workflows` scope). A consumer whose cloud run *does* carry that scope but does **not** set `DEVFLOW_APP_ID` (a bespoke PAT-seeded checkout) would proceed by default (the fail-open-toward-proceed direction above); one that wants the deferral anyway overrides this pass via `.devflow/prompt-extensions/implement.md` (the sanctioned additive surface) — do **not** add a config key for it. Name the observed `DEVFLOW_APP_ID`/tier signals in the cloud-tier note so the deferral reads as an auditable plan-time decision, not a silent split.
