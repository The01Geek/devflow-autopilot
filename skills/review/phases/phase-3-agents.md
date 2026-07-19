<!-- devflow:review-ref phase=3 file=skills/review/phases/phase-3-agents.md start -->
## Phase 3: Existing Review Agents

Output: `Phase 3/4: Running review agents...`

### 3.1 Launch existing review agents in parallel

**Dirty-tree backstop — snapshot before dispatch (mandatory).** Review/analysis agents are advisory and must never modify the working tree (their definitions forbid it; the five fan-out agents put any mutation/half-revert check on a `mktemp` copy, while the narrower final-pass reviewer reports that verification limitation instead of attempting one). Independently of agent compliance, snapshot the working tree immediately before launching the Phase 3.1 batch so a dropped in-place restore is caught deterministically rather than incidentally — Phase 3.2 compares against this snapshot after the batch returns and restores any agent-introduced modification:

```bash
mkdir -p .devflow/tmp
if rm -f "${GIT_SNAP_BEFORE:-.devflow/tmp/review-dirty-tree-before}" ".devflow/tmp/review-dirty-tree-disabled" 2>/dev/null &&
   git status --porcelain -z > "${GIT_SNAP_BEFORE:-.devflow/tmp/review-dirty-tree-before}" &&
   [ -f "${GIT_SNAP_BEFORE:-.devflow/tmp/review-dirty-tree-before}" ] &&
   [ ! -L "${GIT_SNAP_BEFORE:-.devflow/tmp/review-dirty-tree-before}" ] &&
   git hash-object "${GIT_SNAP_BEFORE:-.devflow/tmp/review-dirty-tree-before}"; then
  : # Snapshot captured to a NUL-delimited (`-z`) temp FILE. `-z` emits UNQUOTED paths, so a
    # spaced/special filename is a real pathspec the Phase 3.2 restore can act on (plain
    # `--porcelain` C-quotes such a path — `"my file.txt"` — which `git checkout` then cannot
    # match, a silent restore no-op). `-z` output also contains NUL bytes, which a bash
    # `$(...)` variable cannot hold, so the snapshot lives in a file, not a variable.
else
  # The snapshot itself failed (held .git/index.lock, corrupt index, FS/OOM
  # error). Do NOT fall through with an empty baseline — an empty BEFORE would later read
  # every dirtied path as "agent-introduced" and authorize `git checkout` against the
  # orchestrator's OWN live edits. Fail closed: disable the backstop for this dispatch (3.2
  # short-circuits on the sentinel) with an attributable breadcrumb, rather than risk a
  # destructive restore. A fixed repo-local sentinel survives the Agent-tool boundary;
  # shell variables do not survive into Phase 3.2's later Bash call.
  echo "::warning::devflow review: could not create a regular working-tree snapshot before dispatch (stale-path removal, git status, or regular-file validation failed); dirty-tree backstop DISABLED for this dispatch — no after-compare, no auto-restore" >&2
  rm -f "${GIT_SNAP_BEFORE:-.devflow/tmp/review-dirty-tree-before}" 2>/dev/null
  printf '%s\n' disabled > ".devflow/tmp/review-dirty-tree-disabled"
fi
```

Record the single object ID printed by `git hash-object` as `{GIT_SNAP_BEFORE_OID}` in orchestrator state (not in a workspace file), and do not include it in any review-agent prompt. Phase 3.2 substitutes that exact value below. If no single object ID was established, treat the before-snapshot as failed and leave the sentinel in place; never invent or recover the value from agent-writable scratch after dispatch.

This scopes the assertion to the agent-dispatch window only, so it never flags the orchestrator's own legitimate edits made outside it. (Under `/devflow:review` the agents are contractually read-only and normally leave matching snapshots; the backstop earns its keep whenever that contract is violated and in the write-enabled `/devflow:review-and-fix` and `/devflow:implement` tiers, where it also runs verbatim — including the Step 2.6 shadow pass, which re-executes these same Phases 0–4.3.)

Launch all agents in a single message using multiple Agent tool calls. For each agent, pass a prompt telling it to review the changes.

**Resolve overrides for the Phase-3 roster first.** After the Phase 3.1 applicability gates decide which agents actually launch this run, pass that exact roster (the always-on four — `code-reviewer`, `silent-failure-hunter`, `comment-analyzer`, and the final-pass `devflow:requesting-code-review` dispatched as a `general-purpose` Task — plus any gated-in `type-design-analyzer` / `pr-test-analyzer`) to `resolve-review-overrides.py` per **Per-Subagent Model/Effort Overrides** above. Dispatch each Phase-3 agent via the Agent tool, applying its resolved `model` as the Agent-tool `model` override; do **not** request overrides for a gated-out agent (only emit overrides for agents actually dispatched). The final-pass reviewer's override is keyed under `devflow:requesting-code-review` even though it is dispatched as a `general-purpose` Task (see its dispatch note below).

**`iterations: "first-only"` roster exclusion (fix-loop iterations ≥ 2 only).** Some agents may carry an `iterations: "first-only"` override (see *Per-Subagent Model/Effort Overrides* above). This is a roster-membership decision, made **before** applying the resolved overrides and **before** the expected-roster/coverage accounting for this iteration (resolve the overrides for the applicability-gated roster, drop the excluded agents, then apply overrides and account only the survivors), keyed on the **same caller-supplied fix-loop-iteration signal** that gates the *Prior-findings context* block below: **only** when invoked by `/devflow:review-and-fix` on a fix-loop iteration **N ≥ 2**, drop from the Phase-3 launch list every agent whose resolved override carries `iterations: "first-only"`. The observable operand is that iteration signal (produced by the fix-loop caller — see `skills/review-and-fix/references/loop-control.md`'s per-iteration `{N}`; standalone `/devflow:review` and the Step 2.6 shadow fan-out both **withhold** it, exactly as they withhold the prior-findings handoff) together with the `iterations` value in the resolved override map (produced by `resolve-review-overrides.py`, which drops an invalid value so it never reaches here). An excluded agent looks exactly like a Phase-0.5-gated-out agent to everything downstream: it is **absent** from the dispatched roster, from that iteration's `phase3_dispatched` telemetry, and from the expected-roster accounting, and **no override is requested for it** (the only-emit-overrides-for-dispatched-agents rule applies unchanged). On fix-loop iteration 1, in standalone `/devflow:review`, and when the iteration signal is absent/unresolvable, **exclude nothing** — the agent dispatches normally (its `model`/`effort` applied, `iterations` ignored). This gate is **never** applied to the Step 2.6 shadow fan-out, which keeps the full roster regardless of `iterations` (see its expected-roster rule in `skills/review-and-fix/references/shadow-review.md`). **Precedence over the `engine_self_modifying` always-on force:** when a `first-only` agent is one of the always-on four (as `devflow:code-reviewer` is under this repo's config), this exclusion **overrides** Phase 0.5's `engine_self_modifying` "force the always-on agents on" rule on iterations ≥ 2 — the opted-in always-on agent is dropped from the loop's late iterations even on an `engine_self_modifying` diff. That is the deliberate cost/coverage trade the operator opts into: the Step 2.6 shadow (never scoped by `iterations`) still dispatches the full roster including that agent at its own cadence — after iteration 1 on an `engine_self_modifying` diff and again before convergence — so the excluded agent's late-iteration signal is recovered by that independent audit rather than lost, even though the loop's own intermediate late iterations no longer run it.

**Phase 3 always re-runs on every iteration of the fix loop.** Unlike Phase 1+2 (where individual items can be narrow-reused via `claim_signature` + untouched-file checks — see Phase 2.0.5), Phase 3's review agents are the main lever for *variance recovery*: an LLM reviewer asked the same question twice in different sessions will not always surface the same findings, and that variance is the whole point of iterating. Skipping Phase 3 on a later iteration because "the fix didn't touch any flagged file" silently throws away the second-look signal — exactly the false-pass mode this engine is designed to avoid.

**Prior-findings context (fix-loop callers only).** When invoked by `/devflow:review-and-fix` on iteration N≥2, prepend the following block to every Phase 3 agent's prompt (between the standard task description and the `defect_signature` paragraph). The caller supplies iter-(N-1)'s `phase3_findings` from the workpad:

```
The following findings were raised by a prior review pass on this same code and have already been considered (some fixed, some pushed back as false positives, some deferred). Treat them as PRIOR ART, not as a checklist to re-derive:

- Do NOT re-raise a finding identical to one in the prior set unless you have new evidence the prior decision was wrong.
- DO look for *new* defects the prior pass missed — your value on this iteration is variance recovery, not corroboration.
- If you would have raised an identical finding, you may skip it; the orchestrator already has it.

<prior_findings iteration="N-1">
{paste the iter-(N-1) phase3_findings JSON — agent, severity, description, defect_signature, fix_decision}
</prior_findings>
```

**Diff path:** Substitute the cached diff path computed in Phase 0.2 (`.devflow/tmp/review/<slug>/<run-id>/diff.patch`) into `{DIFF_PATH}` in the prompts below. Phase 3 agents Read this file directly via their `Read` tool — no shell command, no `gh` API call, no redundant re-fetches across the 4–5 parallel agents. The previous `{DIFF_CMD}` substitution (which had every agent re-run `gh pr diff $ARGUMENTS` or a fresh `git diff <base>...HEAD`) is superseded.

**Required `defect_signature` block.** Every Phase-3 finding from every Phase-3 review-agent — both the ones listed below AND any added by future maintainers — MUST carry a `defect_signature` object so corroboration (Phase 3.2) is mechanical, not interpretive. Append this paragraph verbatim to every Phase-3 review-agent prompt so the corroboration contract rides on the dispatch itself, independent of each agent's own frontmatter — applying uniformly to the first-party `devflow:` review agents and the first-party `devflow:requesting-code-review` final pass alike:

```
For every finding you report, include a `defect_signature` field with the following shape:

  defect_signature:
    file: "<path/to/file>"           # required; the primary file the defect lives in
    line_range: [<start>, <end>]     # required when locatable; null only when the defect spans an unbounded region (e.g. "missing test file")
    kind: "<one of: null_deref | unhandled_exception | leak | race | logic_error | api_misuse | type_design | comment_drift | documented_falsehood | test_gap | security | style | other>"

Place this field on each finding alongside severity and description. If your normal output format is a markdown bullet list, append the signature as a fenced JSON block right under the bullet. Without `defect_signature`, the orchestrator cannot corroborate your finding against other agents and may downweight it.

Truthfulness contract (file it, do not soften it): a diff-added or diff-modified doc line, code comment, example, or command-form whose claim is false against HEAD MUST be filed with `kind: documented_falsehood` — never as a clarity or cosmetic Suggestion. The discriminator is: false against HEAD is a truthfulness defect (a self-contradicting diff — non-demotable REJECT); true but awkwardly worded is a clarity Suggestion (demotable). Verify the claim against the shipped code (read the named symbol, command surface, or code path) before you grade it.

**Displaced-path routing (issue #504).** For every path the run's displaced-path list marks as #458-displaced — read that list directly from the Phase 0.1.5 scratch file `.devflow/tmp/displaced-paths.txt` at the start of your review (you receive this contract, not the orchestrator's engine-ground-truth block; a missing or empty file means no displaced list, so this routing is inert and you review every file from the working tree exactly as today) — the working-tree copy is trusted base-ref or fail-closed-stub bytes — NOT the reviewed head — so verify the claim against `git show <head>:<path>` and the Phase 0.2 cached diff, never a working-tree read. Bind `<head>` to a resolved, non-empty commit id per mode (PR-number standalone mode: the Phase 0.2 `headRefOid`; fix-loop `head_override = local` mode: the local `HEAD` it already resolves; no-argument current-branch mode: the literal `HEAD`) — an empty head never reaches the command, since `git show :<path>` is an index read that exits 0 with staged bytes, the silent wrong-bytes shape this routing exists to prevent. A base-state claim about a listed path routes the same way through `git show $PR_BASE_SHA:<path>`. If the routed `git show` errors and the cached diff does not evidence the path as deleted at head, probe with `git cat-file -e <head>:<path>` and grade the claim INCONCLUSIVE with the displacement attribution — never fall back to the working-tree read, never attempt `git fetch` (it is not granted on the review tier; a local tier whose allowlist permits it may fetch-then-retry before the INCONCLUSIVE). Listed paths remain fully in review scope — their committed changes are reviewed from the cached diff and the `git show` reads at full depth; the displacement changes the read channel, never the depth of review, and a claim about a listed path is graded INCONCLUSIVE only through this stated fail direction, never because the routed channel is extra effort. With no displaced list (every local tier, the manual `devflow.yml` path, a consumer relevance-gate skip, every fix-loop iteration) this routing is inert — behave exactly as today.
```

Agents to launch:

**devflow:code-reviewer** — prompt:
```
Review the code changes in this PR. Read the cached diff at `{DIFF_PATH}`. Read CLAUDE.md for project conventions. Focus on CLAUDE.md compliance, bugs, and code quality. Only report issues with confidence >= 80. Per the shared `defect_signature` contract below, a diff-added/modified doc line, comment, example, or command-form whose claim is false against HEAD is a `documented_falsehood`, never a clarity Suggestion — watch for the five recurring shapes: a documented symbol or base class the code lacks; a documented command invocation the skill/CLI does not accept; a "known limitation" the same diff already fixed; an "apply this pattern to X" claim the code does not bear out; and an absolute claim (a universal — "every", "never", "always", "cannot", "is caught by the same rule") that the same diff contradicts by adding or retaining a limitation note about the same symbol it did not actually close.

{paste the defect_signature paragraph above}
```

**devflow:silent-failure-hunter** — prompt:
```
Review the error handling in the code changes. Read the cached diff at `{DIFF_PATH}`. Read the full changed files. Check for silent failures, inadequate error handling, and inappropriate fallback behavior.

{paste the defect_signature paragraph above}
```

**devflow:comment-analyzer** — prompt:
```
Analyze the code comments in the changes. Read the cached diff at `{DIFF_PATH}`. Check that docstrings and comments are accurate, helpful, and not misleading. Per the shared `defect_signature` contract below, a diff-added/modified doc line, comment, example, or command-form whose claim is false against HEAD is a `documented_falsehood`, never a clarity Suggestion — watch for the five recurring shapes: a documented symbol or base class the code lacks; a documented command invocation the skill/CLI does not accept; a "known limitation" the same diff already fixed; an "apply this pattern to X" claim the code does not bear out; and an absolute claim (a universal — "every", "never", "always", "cannot", "is caught by the same rule") that the same diff contradicts by adding or retaining a limitation note about the same symbol it did not actually close.

{paste the defect_signature paragraph above}
```

**devflow:pr-test-analyzer** — prompt:
```
Analyze test coverage for the changes. Read the cached diff at `{DIFF_PATH}`. Check if tests adequately cover new functionality and edge cases.

{paste the defect_signature paragraph above}
```

**devflow:type-design-analyzer** — *launched only when the `has_new_types` gate is true (see Phase 3.1 gates below), on every diff profile including `engine_self_modifying`; skipped otherwise* — prompt:
```
Analyze the type design in the code changes. Read the cached diff at `{DIFF_PATH}`. Evaluate the types actually introduced or modified in this diff for encapsulation, invariant expression, usefulness, and enforcement. Do not report on pre-existing types the diff does not touch.

{paste the defect_signature paragraph above}
```

**General-purpose final-pass reviewer** — dispatch a `Task` with `subagent_type: general-purpose` and instruct it to invoke the `/devflow:requesting-code-review` skill (that skill — vendored first-party under `skills/requesting-code-review/` — renders its own reviewer prompt; we do not inline it). Because it is a first-party DevFlow skill it is always present in any environment where DevFlow itself is installed; there is no companion-plugin install to assume. **Do not, however, treat the final pass's presence as guaranteed-by-construction:** if the skill cannot be resolved or rendered for any *non-companion* reason — a renamed `skills/requesting-code-review/` directory, an orphaned `code-reviewer.md` template, a corrupt plugin install, or a `general-purpose` Task that returns evidence-empty — handle it exactly like any other non-returning Phase-3 agent (record `requesting-code-review did not return results.` and count it among the failed agents per the Phase-3 failed-agent rule below), never as an impossibility. The shadow pass's always-on-roster + 1:1 join then fails the run **closed** on the missing final pass rather than letting a three-of-four roster read as full coverage. **Override key:** resolve and apply this dispatch's model override under the identifier `devflow:requesting-code-review` (not `general-purpose`) — apply its resolved `model` as the Agent-tool `model` override on this `general-purpose` Task so the configured model rides on it, keeping config, dispatch, and the effectiveness trace aligned.

Prompt:

```
Invoke the `/devflow:requesting-code-review` skill to perform a final-pass code review. Pass the following context into the skill:

- Description: {one-line summary — "PR #<N>: <title>" or "Current branch <name> vs <base_branch>"}
- Plan / Requirements: {the PR body if available, else the originating issue body from Phase 0.4, else "No spec available — review against general project standards from CLAUDE.md"}
- Base SHA: {head_override PR mode: $HEAD_OVERRIDE_BASE (the fetched origin/$PR_BASE_BRANCH tip, or $PR_BASE_SHA after confirmed deletion); standalone PR mode: $PR_BASE_SHA/baseRefOid paired with the unchanged gh pr diff result; current-branch mode: origin/$BASE — always the base the cached diff.patch is scoped to}
- Head SHA: {PR_HEAD_SHA or current HEAD}
- Diff path: `{DIFF_PATH}` (the full diff, cached to disk by Phase 0.2 — Read it directly rather than re-fetching)
- Prior-iteration findings (already considered, look for new): {iter-(N-1) phase3_findings JSON if fix-loop iteration N≥2, else "none"}

Return your findings in the standard Phase-3 output format: ### Strengths / ### Issues (grouped by Critical / Important / Suggestion) / ### Recommendations (rendered as a numbered list) / ### Assessment. Every issue MUST carry a `defect_signature` block per the contract below.

{paste the defect_signature paragraph above}
```

**Phase 3.1 structural-applicability gates (apply to this launch list on every diff profile):**

These two gates decide whether `type-design-analyzer` and `pr-test-analyzer` have anything *in the diff* to analyze. They are **applicability** gates, not cost-profile gates, so they apply uniformly across all Phase 0.5 profiles — `engine_self_modifying` included. The `engine_self_modifying` override (Phase 0.5) keeps the full checklist and the four always-on agents (`code-reviewer`, `silent-failure-hunter`, `comment-analyzer`, `requesting-code-review`) firing regardless of these gates; it does **not** force-dispatch the type/test analyzers when the diff gives them nothing to do.

- Skip `devflow:type-design-analyzer` when `has_new_types` is false. (This replaces the older "check for `class ` in the diff" predicate, which over-fired on the literal word *class* appearing in YAML / markdown / comments.) When `has_new_types` is true, it is launched — on every profile, `engine_self_modifying` included.
- Dispatch `devflow:pr-test-analyzer` per the **test-relevance predicate** below; skip it when the predicate does not match.

**`pr-test-analyzer` test-relevance predicate (defined once, applied to every diff profile):** dispatch `pr-test-analyzer` when **either** branch matches —
1. the diff **adds or modifies a test file** (a changed path matching `*test*` / `*spec*`, or a language-specific test-naming convention — e.g. `*_test.go`, `test_*.py`, `*.spec.ts`, `*Test.java`); **or**
2. the diff **adds new testable code logic** — at least one added line (`+`, excluding `+++`) in a file whose extension is **not** in the `config_only` set (`{.yml, .yaml, .json, .md, .toml, .ini, .lock, .txt}`).

Skip `pr-test-analyzer` when **neither** branch matches — i.e. a docs-only or config-only diff with no test-file change. This single predicate replaces the older profile-specific wording ("always runs unless `small_diff` with no test files"); it applies identically under `engine_self_modifying`. (On most engine PRs branch 2 fires — they add `lib/*.sh` / `.jq` / `.py` logic — which is intended: it preserves the "you changed logic but added no tests" catch. The win is on docs-only / config-only engine PRs, where it now correctly skips.)

### 3.1.5 Completeness-critic pass (forced when `detect_all_audit` is set)

**This pass fires whenever Phase 0.5 set `detect_all_audit` — from the classification, not from reviewer memory.** When the flag is unset, skip this subsection entirely. It is the engine's defense against a **vacuous or incomplete "detect-all" audit**: a scanner / audit / coverage-invariant whose completeness was certified by its *own* output, so a site the audit is structurally blind to is invisible to both the audit and any review that judges the audit by what it found. **A "detect-all" claim can never be self-certified by the audit making it** — judging the audit's completeness from the audit's own matched set just re-runs the audit's blind spot (this is the PR #164 / PR #62 / PR #154 class — see `docs/shadow-review.md`).

Run these steps and add any finding to the Phase 3 findings set (it is collected in 3.2 alongside the agents' findings, carries a `defect_signature`, and flows through Phase 4 aggregation like any other finding):

1. **Name the audit's target population and its completeness property.** From the added/changed lines that set `detect_all_audit`, state in one sentence *what population the audit claims to cover* (e.g. "every review agent the engine dispatches", "all raw drift guards in the park-calibration region", "each config-leaf consumer") and *the property it asserts* (count / coverage / superset / "every" / "none-remaining").
2. **Independently re-enumerate that population by a signal OTHER than the audit's own pattern.** This independence is load-bearing and non-negotiable: an enumeration that reuses the audit's matching pattern reproduces the audit's blind spot and proves nothing. Derive the population from a *different* source — e.g. if the audit greps for `**devflow:<name>**` dispatch headers, enumerate the roster instead from `agents/*.md` `name:` frontmatter or the resolver allowlist; if the audit scans for one literal in one region, enumerate the population it *should* cover from the directory listing, from the producer that emits the members, or via a structurally different query. **State explicitly which independent signal you used** so the independence is auditable.
3. **Assert the audit's matched set ⊇ your independent enumeration.** Compare the set the audit actually covers against the independent set. **Every member of the independent set that the audit does not cover is a review finding** — describe the uncovered member, the audit that misses it, and why the audit's pattern is blind to it. Calibrate severity normally: an uncovered member that makes the "detect-all" guarantee vacuous for a real case is at least Important; one that leaves a whole class undetected is Critical.
4. **If the independent enumeration is a subset of the audit's set** (nothing uncovered), record a one-line note that the completeness critic ran and found the audit complete *with respect to the independent signal used*. This is **not** a proof of exhaustiveness — the independent signal can itself have a blind spot (see the calibration in `docs/shadow-review.md`); it asserts only that the audit is a superset of a genuinely independent enumeration.

The completeness critic is a **finding-producing pass, not a verdict override**: it injects findings into the set Phase 4.2 already grades by severity. It adds **no** new Phase 4.2 rule. Because it lives here in the shared Phases 0–4.3, both standalone `/devflow:review` and the `/devflow:review-and-fix` fix loop apply it without any paraphrase in the fix-loop skill.

### 3.2 Collect results

**Dirty-tree backstop — compare after dispatch (mandatory).** Before extracting findings, confirm the Phase 3.1 review-agent batch left the working tree unchanged. Compare against the fixed repo-local NUL-delimited snapshot file taken before dispatch; on any divergence the dispatch violated the advisory contract, so record it as a finding (never discard it silently) and restore only the snapshot-delta paths — those whose **path** was clean at snapshot time and became dirty during the dispatch window. The fixed path is what survives the Agent-tool boundary; shell variables do not. The restore set is computed by **path column** (status prefix stripped from each `-z` record, not whole porcelain line), so the guarantee is exact: any path the orchestrator had **already** modified before dispatch is left to the human — its `git checkout` is never run even if an agent changes its status byte further — so a concurrent legitimate edit is never clobbered. Because the snapshots use `git status --porcelain -z` (UNQUOTED, NUL-delimited paths), a spaced or special-character filename is restored correctly rather than silently skipped. **Residuals the backstop does NOT auto-restore:** (1) a **true rename/copy** (status `R`/`C`) — a staged rename needs index surgery to undo safely, so it is *surfaced* (named in a breadcrumb) but left for the human; (2) an agent's further edit to an **already-dirty path that does not change its status byte** — it produces an identical `-z` record, so the divergence test does not fire, and the path is intentionally never auto-restored regardless. The Step 2.6 shadow + the post-shadow edit gate are the backstop for those residuals.

```bash
# devflow:dirty-tree-compare BEGIN (the complete compare/authenticate/restore wrapper is extracted
# and exercised by the #484 git_sandbox integration tests in lib/test/run.sh)
mkdir -p .devflow/tmp
if [ -f ".devflow/tmp/review-dirty-tree-disabled" ]; then
  : # before-snapshot failed in 3.1 (already surfaced there); backstop disabled this dispatch
elif [ ! -f "${GIT_SNAP_BEFORE:-.devflow/tmp/review-dirty-tree-before}" ] ||
     [ -L "${GIT_SNAP_BEFORE:-.devflow/tmp/review-dirty-tree-before}" ]; then
  echo "::warning::devflow review: the before-dispatch snapshot is missing or no longer a regular non-symlink file; dirty-tree verification SKIPPED this dispatch — possible scratch tampering, nothing auto-restored" >&2
elif [ "$(git hash-object "${GIT_SNAP_BEFORE:-.devflow/tmp/review-dirty-tree-before}" 2>/dev/null)" != "{GIT_SNAP_BEFORE_OID}" ]; then
  echo "::warning::devflow review: the before-dispatch snapshot no longer matches its orchestrator-held object ID; dirty-tree verification SKIPPED this dispatch — scratch integrity failure, nothing auto-restored" >&2
elif ! rm -f "${GIT_SNAP_AFTER:-.devflow/tmp/review-dirty-tree-after}" 2>/dev/null ||
     ! git status --porcelain -z > "${GIT_SNAP_AFTER:-.devflow/tmp/review-dirty-tree-after}" ||
     [ ! -f "${GIT_SNAP_AFTER:-.devflow/tmp/review-dirty-tree-after}" ] ||
     [ -L "${GIT_SNAP_AFTER:-.devflow/tmp/review-dirty-tree-after}" ]; then
  # After-snapshot failed. Do NOT misattribute a git failure as an agent mutation, and do NOT
  # run any restore off an empty AFTER — surface a DISTINCT, attributable breadcrumb instead.
  echo "::warning::devflow review: could not create a regular working-tree snapshot after the Phase 3.1 dispatch (stale-path removal, git status, or regular-file validation failed); dirty-tree verification SKIPPED this dispatch — this is NOT an agent mutation" >&2
  rm -f "${GIT_SNAP_AFTER:-.devflow/tmp/review-dirty-tree-after}" 2>/dev/null
else
  # Compare the two NUL-delimited (`-z`) snapshots. `cmp` rc: 0 identical, 1 differ, >=2 ERROR.
  # An error (unreadable file, mid-run FS failure) must NOT be read as "the tree diverged" and
  # drive a restore off a comparison that never succeeded — fail closed with a distinct,
  # attributable breadcrumb, exactly as the after-snapshot failure branch above does.
  cmp -s "${GIT_SNAP_BEFORE:-.devflow/tmp/review-dirty-tree-before}" "${GIT_SNAP_AFTER:-.devflow/tmp/review-dirty-tree-after}"; cmp_rc=$?
  if [ "$cmp_rc" -ge 2 ]; then
    echo "::warning::devflow review: could not compare the before/after working-tree snapshots (cmp errored, rc=$cmp_rc); dirty-tree comparison SKIPPED this dispatch — this is NOT an agent mutation, nothing auto-restored" >&2
  elif [ "$cmp_rc" -eq 1 ]; then
    # The two snapshots differ — something changed the tree during the dispatch window. The
    # restore set is computed BY PATH COLUMN (status prefix stripped from each `-z` record),
    # NOT by whole record: a path the orchestrator had ALREADY modified before dispatch must
    # never be checked out even if an agent changed its status byte further (` M f` -> `MM f`).
    # Each `-z` record is `XY <path>` (NUL-terminated, UNQUOTED); a rename/copy emits TWO
    # records — `R  <new>` then a bare `<old>` continuation — so the read loops below consume
    # that continuation rather than mis-stripping a prefix off it. The restore set is `paths in
    # AFTER, not present in BEFORE, that are NOT rename/copy entries`; rename/copy entries are
    # surfaced separately and never auto-restored (index surgery needed).
    # devflow:dirty-tree-restore BEGIN (self-contained given the fixed before/after snapshot files and
    # cwd=repo; extracted + exercised by the #216 git_sandbox integration test in lib/test/run.sh)
    mkdir -p .devflow/tmp
    # NOTE (runtime assumption): the NUL-mode grep operand below is a GNU extension — this
    # region runs in the review engine's own GNU/Linux agent runtime (the
    # same env as CI), NOT as a committed macOS/BSD helper, so the no-GNU-flags portability
    # convention (which governs lib/ + scripts/) does not bind it. On a non-GNU host those flags
    # error, which routes through the fail-closed branches below (restore nothing + a breadcrumb)
    # — a degradation, never a clobber.
    rm -f ".devflow/tmp/review-dirty-tree-before-paths" ".devflow/tmp/review-dirty-tree-changed-paths" ".devflow/tmp/review-dirty-tree-renamed-paths" 2>/dev/null
    if ! printf '%s' '' > ".devflow/tmp/review-dirty-tree-before-paths" ||
       ! printf '%s' '' > ".devflow/tmp/review-dirty-tree-changed-paths" ||
       ! printf '%s' '' > ".devflow/tmp/review-dirty-tree-renamed-paths"; then
      # Repo-local scratch allocation failed (quota/perms). Do NOT proceed: an empty
      # before-paths file would report every membership test absent (rc 1) and fail OPEN (every dirty path,
      # incl. the orchestrator's own edits, treated as newly-dirty and restored). Fail closed
      # with a distinct breadcrumb and restore nothing — mirroring the snapshot-failure branches.
      echo "::warning::devflow review: could not allocate repo-local scratch files for the dirty-tree restore; dirty-tree restore SKIPPED this dispatch — this is NOT an agent mutation, nothing auto-restored" >&2
      rm -f ".devflow/tmp/review-dirty-tree-before-paths" ".devflow/tmp/review-dirty-tree-changed-paths" ".devflow/tmp/review-dirty-tree-renamed-paths" 2>/dev/null
    else
      # 1. BEFORE membership set: every path (incl. rename new + orig), prefix stripped and NUL-
      #    delimited. `read -r -d ''` reads NUL records so a spaced/special path never splits.
      before_extract_rc=0
      before_orig=0
      rec=
      while IFS= read -r -d '' rec; do
        if [ "$before_orig" = 1 ]; then
          before_orig=0
          printf '%s\0' "$rec" >> ".devflow/tmp/review-dirty-tree-before-paths" || { before_extract_rc=$?; break; }
          continue
        fi
        case "${rec:0:1}" in [RC]) before_orig=1 ;; esac   # index column (X) only: the two-record shape is emitted iff X is R/C
        printf '%s\0' "${rec:3}" >> ".devflow/tmp/review-dirty-tree-before-paths" || { before_extract_rc=$?; break; }
      done < "${GIT_SNAP_BEFORE:-.devflow/tmp/review-dirty-tree-before}" || before_extract_rc=$?
      [ -z "$rec" ] || before_extract_rc=65
      if [ "$before_extract_rc" -ne 0 ]; then
        echo "::warning::devflow review: could not extract the before-snapshot path set (rc=$before_extract_rc); dirty-tree restore SKIPPED this dispatch — nothing auto-restored" >&2
      else
        # 2. AFTER: rename/copy → surfaced-not-restored (routed to the renamed-paths file); a normal
        #    entry classified by its BEFORE membership. Membership reads NUL records (`grep -z`),
        #    and the THREE grep outcomes are handled distinctly so an error never clobbers:
        #      rc 0  = present in BEFORE (already dirty) → never restore (left to the human);
        #      rc 1  = absent from BEFORE → newly dirtied → restore set;
        #      rc>=2 = grep ERROR → fail closed (do NOT restore — an error must not be read as
        #              "absent → restore", which would clobber a live orchestrator edit).
        #    (Flipping rc 1 to restore-on-present would restore already-dirty paths and clobber
        #    live edits — the direction this guard protects.)
        after_extract_rc=0
        after_orig=0
        rec=
        while IFS= read -r -d '' rec; do
          if [ "$after_orig" = 1 ]; then after_orig=0; continue; fi
          case "${rec:0:1}" in   # index column (X) only: a rename/copy (X = R/C) emits the two-record shape
            [RC]) printf '%s\0' "${rec:3}" >> ".devflow/tmp/review-dirty-tree-renamed-paths" || { after_extract_rc=$?; break; }; after_orig=1; continue ;;
          esac
          if grep -qzxF -- "${rec:3}" ".devflow/tmp/review-dirty-tree-before-paths"; then
            : # present in BEFORE (already dirty) → never restore
          else
            gmrc=$?
            if [ "$gmrc" -eq 1 ]; then
              printf '%s\0' "${rec:3}" >> ".devflow/tmp/review-dirty-tree-changed-paths" || { after_extract_rc=$?; break; } # absent from BEFORE → newly dirtied → restore set
            else
              echo "::warning::devflow review: membership test errored (grep rc=$gmrc) for a dispatch-window path; NOT auto-restoring it (fail-closed) — left for the human" >&2
            fi
          fi
        done < "${GIT_SNAP_AFTER:-.devflow/tmp/review-dirty-tree-after}" || after_extract_rc=$?
        [ -z "$rec" ] || after_extract_rc=65
        if [ "$after_extract_rc" -ne 0 ]; then
          echo "::warning::devflow review: could not extract the after-snapshot restore set (rc=$after_extract_rc); dirty-tree restore SKIPPED this dispatch — nothing auto-restored" >&2
        else
          RENAMED_NAMES=$(tr '\0' ' ' < ".devflow/tmp/review-dirty-tree-renamed-paths")
          if [ ! -s ".devflow/tmp/review-dirty-tree-changed-paths" ]; then
            if [ -n "$RENAMED_NAMES" ]; then
              # The only divergence is a rename/copy: surfaced, never auto-restored (a staged rename
              # needs index surgery to undo safely) — left for the Step 2.6 shadow and the human.
              echo "::warning::devflow review: a Phase 3.1 review-agent dispatch renamed/copied tracked path(s) [ ${RENAMED_NAMES}]; not auto-restored (a staged rename needs index surgery) — left for the Step 2.6 shadow and the human" >&2
            else
              # Divergence with an EMPTY restore set and no rename. The cause is NOT asserted: an
              # empty by-path delta is consistent with an already-dirty path whose status byte changed
              # (its path is in BOTH snapshots) OR a dirty->clean / removed-path transition — `cmp`
              # cannot distinguish them, so the cause cannot be determined here. Nothing auto-restored.
              echo "::warning::devflow review: a Phase 3.1 review-agent dispatch diverged the working tree but the by-path restore set is empty (an already-dirty path's status byte changed, or a dirty->clean transition — the cause cannot be determined here); nothing auto-restored — left for the Step 2.6 shadow and the human" >&2
            fi
          else
            # The changed-paths file holds the snapshot delta (paths clean at snapshot, now dirty, non-rename),
            # NUL-delimited and UNQUOTED so a spaced/special path is a real pathspec. Restore is best-effort
            # and per-path, fed via `read -r -d ''` so a `$`/space/backtick/newline in a pathname never
            # word-splits or shell-expands. Restore from HEAD (NOT `git checkout -- "$p"`, which restores
            # the worktree from the INDEX and so re-materializes a STAGED agent mutation while exiting 0 — a
            # fail-open that reports a clobber as restored). Then trust the TREE STATE, not the exit code:
            # re-run `git status --porcelain -- "$p"` and emit the per-path breadcrumb iff it is STILL dirty,
            # so an untracked or staged-new file the agent created (never auto-deleted; it could be a
            # legitimate orchestrator artifact) is surfaced per-path and never falsely reported as restored.
            CHANGED_NAMES=$(tr '\0' ' ' < ".devflow/tmp/review-dirty-tree-changed-paths")
            echo "::warning::devflow review: a Phase 3.1 review-agent dispatch modified the working tree (advisory review agents must never mutate it); affected paths: [ ${CHANGED_NAMES}]${RENAMED_NAMES:+ (plus surfaced-not-restored rename/copy: [ ${RENAMED_NAMES}])}; recording an Important finding and attempting best-effort restore of the snapshot delta (per-path outcome in the warnings below)" >&2
            while IFS= read -r -d '' p; do
              [ -n "$p" ] || continue
              restore_err=$(git checkout HEAD -- "$p" 2>&1)
              if [ -n "$(git status --porcelain -- "$p")" ]; then
                echo "::warning::devflow review: path '$p' still dirty after restore attempt (e.g. an untracked or staged-new file the agent created — never auto-deleted; git said: ${restore_err:-none}) — left as-is for human inspection" >&2
              fi
            done < ".devflow/tmp/review-dirty-tree-changed-paths"
          fi
        fi
      fi
      rm -f ".devflow/tmp/review-dirty-tree-before-paths" ".devflow/tmp/review-dirty-tree-changed-paths" ".devflow/tmp/review-dirty-tree-renamed-paths" 2>/dev/null
    fi
    # devflow:dirty-tree-restore END
  fi
  # cmp_rc == 0: the snapshots are identical — nothing changed during the dispatch window.
  rm -f "${GIT_SNAP_AFTER:-.devflow/tmp/review-dirty-tree-after}" 2>/dev/null
fi
# Clean up fixed repo-local snapshot state after the dispatch.
rm -f "${GIT_SNAP_BEFORE:-.devflow/tmp/review-dirty-tree-before}" ".devflow/tmp/review-dirty-tree-disabled" 2>/dev/null
# devflow:dirty-tree-compare END
```

When this fires (the non-empty changed-paths branch), add an **Important** finding to the Phase 3 findings set — attributed to the Phase 3.1 review-agent dispatch, naming the affected paths (`CHANGED_NAMES`) it **attempted** to restore (best-effort; an untracked or staged-new file it could not restore is named in its own per-path warning above) — carrying a `defect_signature` (`kind: "other"`, `file` the first affected path) so it flows through Phase 4 aggregation like any other finding. A **true rename/copy** (status `R`/`C`) is surfaced-not-restored: it is named in the aggregate breadcrumb's `surfaced-not-restored rename/copy` list (`RENAMED_NAMES`), left for the human rather than auto-undone. It is the only residual the backstop *detects but deliberately does not restore* — distinct from the other residual noted above (an already-dirty path whose status byte does not change), which is a *detection* limit, not a restore choice. The attributable breadcrumb plus the finding mean a dropped restore is caught and recorded, never silently swallowed.

Collect all agent responses. Extract findings, their severity labels (Critical, Important/Major, Suggestion/Minor), and their `defect_signature` blocks. **If the Phase 3.1.5 completeness-critic pass ran and produced a finding, include it here** as a single-source finding (flag it single-source like any N=1 finding); it carries a `defect_signature`, so it corroborates mechanically with any agent that independently flagged the same coverage gap.

For each finding, compute a **corroboration count** — the number of Phase 3 agents that raised the same defect. Corroboration is now **mechanical**, not interpretive:

> Two findings corroborate iff they have the **same `defect_signature.file`**, **overlapping `defect_signature.line_range`** (treat `null` as overlapping any range in the same file when `kind` matches), AND **identical `defect_signature.kind`**.

A finding without a `defect_signature` block falls back to a one-line text-based agreement heuristic (same described file + same described defect kind in prose), but **flag it in the report** so the human knows the agent skipped the signature contract. Agents that systematically omit `defect_signature` should be re-prompted with the contract reminder.

Corroboration count is a stronger calibrator than the individual agent's verbalized confidence: a finding raised by 3 of 5 agents is much more likely to be a true positive than a 95%-confidence finding raised by only one. Single-source findings are not automatically wrong — they're flagged so a human reader can apply extra scrutiny.

If an agent fails, note: "[agent-name] did not return results." in the report. Track the count of failed agents. Failed agents do not reduce the denominator for the corroboration count of findings other agents raised.
<!-- devflow:review-ref phase=3 file=skills/review/phases/phase-3-agents.md end -->
