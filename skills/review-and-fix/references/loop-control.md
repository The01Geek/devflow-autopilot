# Reference: Loop Control (workpad, schema field semantics, Main Loop, Steps 0.5–2)

## Persistent workpad

The orchestrator persists per-iteration state under `.devflow/tmp/review/<slug>/<run-id>/iter-<N>.json` (relative to the repo root). `<slug>` is `pr-<N>` in PR mode or the sanitized current branch name in branch mode. `<run-id>` is a per-run discriminator (see below). `<N>` is the iteration number, starting at 1.

**Run-scoping (`<run-id>`).** The workpad is scoped by a per-run id so that a second `/devflow:review-and-fix` or `/devflow:review` invocation on the same PR — including `/devflow:implement` Phase 3.3's bounded re-review, which re-invokes this skill on the *same* PR — never clobbers a prior run's `iter-*.json` or `deferrals.json`. Reuse the **exact** discriminator `/devflow:review`'s live progress comment already uses (don't invent a new one):

```bash
RUN_ID="${GITHUB_RUN_ID:-local-$(date -u +%Y%m%dT%H%M%SZ)}-${GITHUB_RUN_ATTEMPT:-1}"
```

Compute `RUN_ID` **once at loop start, before iteration 1, and hold the literal value for the run's whole lifetime** — never recompute it (on a local run the timestamp would change between calls and split one run's state across two directories). This is the same compute-once-and-reuse rule the run-keyed progress-comment marker follows.

**All in-run scratch is run-scoped** — `diff.patch`, `iter-*.json`, and `deferrals.json` all live under `.devflow/tmp/review/<slug>/<run-id>/`, so two runs on the same PR never clobber any of them. The cached diff is at `.devflow/tmp/review/<slug>/<run-id>/diff.patch` — the full diff written by Phase 0.2 of `/devflow:review` on every iteration (overwritten within a run, but never across runs). Phase 3 agents Read this file directly via the `{DIFF_PATH}` substitution Phase 0.2 fills in, instead of re-running `gh pr diff` / `git diff` 4–5 times in parallel — so they pick up the run-scoped path automatically with no per-agent-prompt change. **Run-id consistency across the wrapper and the engine:** so the engine's Phase 0.2 and this wrapper agree on one `<run-id>` for the whole run (rather than `/devflow:review` computing a fresh timestamp-based id on each inline invocation), the wrapper passes its held `RUN_ID` into the engine's Phase 0.2 (see Step 1's head-override paragraph, which already plumbs caller inputs into Phase 0.2). See `/devflow:review`'s Phase 0.2 for the write logic.

**Important.** Only `.devflow/tmp/` is ephemeral working state — the rest of `.devflow/` (`config.json`, `learnings/`, the schema/example) is intentionally tracked. The scaffolder (`scripts/scaffold-config.sh`, run by `install.sh` / `/devflow:init`) writes a scoped `.devflow/.gitignore` that ignores only `tmp/`. This skill does NOT manage that entry itself (it's a repo-level concern); flag missing coverage in the chat output only if `.devflow/tmp/` is not already ignored.

## Schema field semantics

`loop_role` names this iteration's role in the fix loop — `fix` for a normal fix iteration, `promoted` for an iteration started by a Decide-outcome-2 shadow promotion (see Step 2.6 "Decide" outcome 2 and Step 4.5). `lib/efficiency-trace.jq` **derives and surfaces it per iteration** in the per-run record (iteration 1 → `fix`; iteration N → `promoted` when iteration N−1's `shadow` block recorded a promotion via `promoted_to_iter_next`, else `fix`), preserving any persisted non-empty value — so the field has a real consumer and is no longer left to be reconstructed by inference; and `lib/efficiency-trace.sh --self-check` warns (best-effort, never failing) when a persisted iter workpad drops it or any other expected field. The `shadow` block remains the record of the shadow pass and any post-shadow delta-review, and the convergence/promotion logic continues to key off that block, not this field. Persisting it on every iteration keeps a multi-iteration run's loop state auditable at a glance from the workpads; an older workpad missing it, or any dropped value, is derived as `fix`.

`phase3_dispatched` is the array of Phase-3 agent identifiers **actually launched** this iteration, captured at Step 1's Phase 3.1 dispatch *after* Phase 0.5 gating (so a gated-out `pr-test-analyzer` / `type-design-analyzer` is absent). It is load-bearing for the Loop Exit effectiveness trace: a `null` verdict (dispatched but silent) is derived as `phase3_dispatched − (agents present in phase3_findings)`, so without this roster a silent agent is indistinguishable from one that was never launched. The field is best-effort — if it is absent on an older/partial workpad, the trace degrades to classifying only the agents that appear in `phase3_findings`. (In the root `### Schema` example, `pr-test-analyzer` appears in `phase3_dispatched` even though `diff_profile` records only `has_new_types: true`: `pr-test-analyzer` is gated by the **test-relevance predicate**, which is not a `diff_profile` flag, so its presence cannot be cross-checked against the profile — this is the same asymmetry the too-narrow tripwire relies on when it keys off `phase3_dispatched` rather than `diff_profile`.)

Use the **same identifier string** in `phase3_dispatched` that you write to each finding's `phase3_findings.agent`, so the trace can match dispatch to outcome. For the five first-party review agents that is `devflow:<name>` (e.g. `devflow:code-reviewer`). For the sixth Phase-3 dispatch — the general-purpose final-pass reviewer launched via `Task`/`subagent_type: general-purpose` invoking `/devflow:requesting-code-review` (see /devflow:review's Phase 3.1) — record it as **`devflow:requesting-code-review`** in both places, so this (most expensive) dispatch is tallied consistently rather than appearing under an ad-hoc string each run.

`diff_profile` records the engine's Phase 0.5 classification for this iteration — the four profile-shaping flags (`small_diff`, `config_only`, `has_new_types`, `engine_self_modifying`) plus a nested `checklist_skipped` member (`"intentional"` when Phase 0.5 bypassed Phase 1+2 on a small_diff+config_only diff, `"failure"` when checklist generation failed, else `null`) — so the checklist-skip tripwire's `diff_profile.checklist_skipped` read resolves against the nested field shown in the schema example, not a sibling. (Phase 0.5's fifth flag, `detect_all_audit`, is intentionally **not** persisted here: it never alters the engine profile — it only forces the Phase 3.1.5 completeness-critic pass — so it has no `diff_profile` consumer.) It is load-bearing for fair cross-run analysis in two ways: (1) a `null`-verdict agent on a `config_only` diff is *correctly* silent (out of its domain), not a cut candidate — the analyzer must segment by diff shape, and this is how it learns the shape; (2) it lets the trace report the orchestrator's **verification posture** — when Phase 0.5 skips the checklist, or when every verifiable item was resolved via the cheap orchestrator-direct `lite` path instead of dispatching verifier subagents, that is a deliberate cost-saving decision and the trace says so explicitly rather than rendering a bare "0 verifiers". Best-effort: if `diff_profile` is absent, the trace labels the profile "not recorded" and the posture falls back to the raw lite/agent counts.

`cap_drops` is populated from /devflow:review's Phase 1.1.5 output (see that skill's Phase 1.1.5 for the shape — `count` is the total dropped at the 100-item cap, `by_category` is the per-category breakdown). The Coverage section in the final report reads this.

`current_step`, `current_substep`, and `pending_dispatch` are the **durable continuation operands** (issue #530): the run-scoped record — not agent recall — identifies the active procedure. `current_step` is `"loop-control"` during config resolution and Steps 0.5–2, then the routed step id (`"2.5"`, `"2.6"`, `"3"`, `"3.5"`, `"4.5"`, or `"loop-exit"`). `current_substep` is a coarse label such as `"run_shadow_fanout"`, or `null`. Immediately before every `Agent`/`Skill`/`Task` dispatch, write `pending_dispatch` with `kind`, `roster`, and `dispatched_at`; clear it after the attempt is joined or dispositioned (including terminal failure/not-verified), retaining it only while unresolved. These best-effort Write-tool navigation stamps are additive to the mandatory fused emits. A failed stamp is logged and takes the root contract's absent-operand fail-closed arm; it is never reconstructed from recall. They are not effectiveness telemetry, so `ITER_EXPECTED_FIELDS` excludes them. The root's re-read rule consumes these operands after every dispatch return.

`shadow` is populated by Step 2.6 (the shadow review pass). `coverage` is a pure roster measurement: it is `"full"` when the parent ran the complete multi-agent fan-out a standalone /devflow:review Phase 3 would launch (subject to the Phase 3.1 applicability gates) and `"not_verified"` when the fan-out could not be completed (outcome 3 — see Step 2.6 "Decide"). Prompt composition is measured separately by `prompt_addenda`; it gates outcome 1 and the clean-agreement renders, never `coverage` or outcome 2. `reviewers_dispatched` is the roster of Phase-3 reviewer agents the parent actually launched for the shadow (same identifier strings as `phase3_dispatched`). It is only present on the workpad of the iter that triggered the shadow — typically the iter with the tentative non-REJECT verdict. Promoted-shadow iters (when the shadow surfaces new findings and triggers iter N+1 → Step 2.5) have their own workpad without a `shadow` block of their own unless they too produce a non-REJECT verdict that triggers another shadow.

**`parking_evidence` (authoritative shape).** The two **rationale-bearing** `fix_decisions` row classes — the Step 2.5 advisory-parked row and the Step 3 item 5 Yes-downgrade rows (`claim-quality` / `out-of-scope` / `already-tracked`) — and the parked-class sweep's below-threshold-sibling advisory row (the `parked-sibling: class-sweep` producer) each carry, **beside the retained one-line `evidence` string** (unchanged — it remains the verbatim `deferrals.json` `explanation` input), a structured `parking_evidence` object `{basis, failing_input, source, finding_ref}` written **at parking time** by the arm that parks the finding: `basis` — the one-line causal rationale for parking (for an uncitable Step 2.5 demotion it names the recorded `step25_classification` outcome; for the sweep sibling it names the sweep registration); `failing_input` — the concrete input/state the parking judgment relied on; `source` — the citation (refutation URL, source span, `git blame` proof, issue reference); `finding_ref` — the `{iter, index}` join to the parking-time `phase3_findings` record, written by the parking arm (which knows exactly which finding it demotes) so the row↔finding join is explicit, never a fuzzy `source_file`/`claim_text` match. A field with no applicable value is JSON `null` — **`finding_ref` is always applicable**, so a null there is a writer omission (the fail-closed arm). At comparison time an omitted field, empty string, or wrong-type value reads as a missing operand (the fail-closed arm). The below-threshold producer row (`decision: "below-threshold"`, `skip_category: "below-threshold-parked"`) is **rationale-less** and gains **no** new fields — its absent `parking_evidence` is not a missing operand.

**`park_calibration` (authoritative shape).** An additive top-level block the Step 2.6 Park-calibration gate writes when it runs the evidence classification (below): `park_calibration.evidence_comparisons[]` carries one record per shadow-re-raise↔parked-finding pair, written on **both** dispositions, of the shape `{parked_finding_ref, parked_finding_id, shadow_finding_index, relation, rationale, operands_present, disposition}`. `parked_finding_ref` is the two-dimensional `{iter, index}` identity of the **parking-time record** (the iteration whose arm parked the finding, and the finding's index in that iteration's `phase3_findings`) — it supplies every parked-side operand (condition (b)'s severity comparand and condition (c)'s `step25_classification`), because a later iteration may re-grade a re-emitted finding without rewriting `step25_classification`, so a most-recent-appearance read would compare the wrong record. `parked_finding_id` carries the `fix_decisions.finding_id` when a row exists, else JSON `null` (a row-less rationale-less member); `shadow_finding_index` indexes the shadow block's `phase3_findings`; `relation` is one of the five taxonomy relations; `rationale` is one line; `operands_present` is the boolean the fail-closed arm sets `false` on any missing/malformed/unresolvable operand; `disposition` is `preserved` or `promoted`. The block is absent on a run whose gate wrote no evidence comparison (a first run, or a run with no paired re-raise) — that absence is normal, not an error.


## Main Loop

**Expired-credential fail-fast (two strikes, never open-ended retry — issue #487).** A cloud writer-job run rides a GitHub App installation token that expires 60 minutes after job start; a fix loop that outlives that lifetime finds every `git push` and `gh` call rejected with a bad-credential error and can burn budget retrying. A background credential refresher normally keeps the credentials fresh, but it can be defeated by sustained mint failure, so this is the last line of defense: **after two consecutive `git push` or `gh` failures whose output carries the bad-credential signature — HTTP `401`, `Bad credentials`, or `Authentication failed` — stop retrying that operation** (do not try a third variant), record the cause in the loop's own record/workpad, and exit the loop reporting the expired-credential cause rather than iterating on it — the same two-strikes discipline the command-shape rules already use. This prose rule is best-effort under context compaction (a >60-minute run is the maximally compaction-likely population); its compaction-immune sibling is the `gh-fresh.sh` wrapper, which appends a distinctive `devflow-gh-fresh: … expired/bad credential` diagnostic line to stderr at every `gh` call that fails with the bad-credential signature.

**Resolve the iteration cap once, at loop start.** Read `devflow_review_and_fix.max_iterations` (default 5) via the config helper — the same portable skill-dir-anchored, no-`bash`-prefix invocation the effectiveness-trace gate uses (see "Subagent effectiveness trace" in `references/loop-exit.md`), so the read is cwd-independent and the resolved-path allow-list entry matches. Discriminate a resolver failure (missing `python3`, malformed `config.json` → non-zero exit with empty stdout) from a legitimately-absent key with a single-statement `if !` (reading config-get's own exit status inline, never a captured rc read in a later statement), and clamp the result:

```bash
# Discriminate a genuine resolver failure with a single-statement `if !` that reads
# config-get's OWN exit status — never a captured rc read in a later statement (an
# inline-bash runner that strips such cross-statement variable reads — Copilot CLI /
# Cursor / Codex CLI / Gemini CLI — would leave the rc empty and make the fail check
# inert). On failure warn (surfacing a missing `python3` / malformed config.json in the
# Actions UI) and leave MAX_ITERS empty; the integer-check fallback below then supplies the
# default 5. That fallback is also what makes a stripped-empty value fail-safe.
if ! MAX_ITERS=$("${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/config-get.sh .devflow_review_and_fix.max_iterations 5 2>/tmp/devflow-maxiter.err); then
  echo "::warning::devflow review-and-fix max_iterations read failed (config-get.sh rc≠0): $(cat /tmp/devflow-maxiter.err 2>/dev/null) — using default 5"
fi
# Fallback to the default 5 on a resolver failure (empty stdout from the failed read above)
# or a non-integer/empty value; clamp a configured value below 1 up to 1 so the loop always
# runs at least once. No upper bound is imposed — any integer ≥ 1 is honored.
if ! printf '%s' "$MAX_ITERS" | grep -Eq '^-?[0-9]+$'; then
  MAX_ITERS=5
elif [ "$MAX_ITERS" -lt 1 ]; then
  MAX_ITERS=1
fi
```

**Resolve the fix-severity threshold once, at loop start** (right after the cap above). Read `devflow_review_and_fix.fix_severity_threshold` (default `important`) via the same portable skill-dir-anchored, no-`bash`-prefix `config-get.sh` invocation the cap read uses (so the read is cwd-independent and matches the resolved-path allow-list entry). `config-get.sh` reads the value but does **not** validate the enum — it coerces any JSON value to a string (a number → `5`, an object → `[object Object]`, an array is comma-joined) — so validate the enum **inline** and fall back to the default on a resolver failure (rc≠0, e.g. malformed `config.json`) or any value outside the enum, with a **specific breadcrumb naming the key and the fallback value** (never aborting the loop):

```bash
# A missing key returns the default `important` (a valid value → kept silently, so an
# absent key is byte-identical to today). Discriminate a resolver FAILURE from an
# out-of-enum value with single-statement branches that read no variable carried across
# statements: an inline-bash runner that strips a variable assigned in one statement and
# read in a later one (Copilot CLI / Cursor / Codex CLI / Gemini CLI) would otherwise leave
# a captured rc empty and misreport a resolver failure as a bad enum value. The `if !`
# condition reads config-get's OWN exit status directly (its stderr — a JSON parse location
# or the missing-python3 message — is never suppressed, so it surfaces on the rc≠0 path);
# the value validation is a separate `case` on the value alone. Both fall back to the
# default, each with its own DISTINCT breadcrumb.
if ! FIX_THRESHOLD=$("${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/config-get.sh .devflow_review_and_fix.fix_severity_threshold important); then
  echo "::warning::devflow review-and-fix: could not read .devflow_review_and_fix.fix_severity_threshold (config-get.sh rc≠0 — malformed config.json or missing python3?); using default 'important'" >&2
  FIX_THRESHOLD=important
fi
case "$FIX_THRESHOLD" in
  critical|important|suggestion) : ;;
  *) echo "::warning::devflow review-and-fix: .devflow_review_and_fix.fix_severity_threshold value '$FIX_THRESHOLD' is not one of critical/important/suggestion; using default 'important'" >&2
     FIX_THRESHOLD=important ;;
esac
```

`$FIX_THRESHOLD` is the routing threshold used in Step 2 below. **Severity ordering: `critical` > `important` > `suggestion`; "at or above `$FIX_THRESHOLD`" reads down that ladder** (e.g. threshold `important` ⇒ Critical + Important/Major route to the fixer, Suggestion/Minor stay advisory — the historical default; threshold `suggestion` ⇒ every severity routes to the fixer; threshold `critical` ⇒ only Critical routes). Record the resolved value in the workpad so the run is auditable.

Execute this loop with a maximum of `$MAX_ITERS` iterations (the configured cap resolved above; default 5).

### Iteration Start

Output: `Review iteration {N}/$MAX_ITERS...`

If N ≥ 2: read `iter-<N-1>.json` from the workpad before proceeding.

### Step 0.5: PR-mode branch sync (PR mode only)

Skip this step entirely in current-branch mode (no `$PR_NUMBER`) — that mode already commits to and diffs against the checked-out branch.

In PR mode, this step makes the loop's local fix commits and the engine's diff agree. On **iteration 1**, ensure the PR's head branch is the checked-out branch, so Step 3's fix commits land on the PR's branch and local `HEAD` *is* the PR head:

```bash
gh pr checkout $PR_NUMBER   # checks out (and tracks) the PR's head branch
```

If you are already on the PR's head branch (compare `git branch --show-current` against the `headRefName` resolved in the engine's Phase 0.2), this is a fast no-op. If `gh pr checkout` fails (e.g. dirty working tree, detached HEAD), **stop and report** — do not commit fixes onto the wrong branch.

Keeping local `HEAD` equal to the PR head is what lets Step 1's head-override (passed on every PR-mode iteration) diff against the fix commits this loop makes — see that step for the rationale.

### Step 0.9: Fix-delta handoff (skip on iter 1)

On iteration 1, skip this step — there is no prior iteration to hand off from. Proceed directly to Step 1.

On iterations N ≥ 2, prepare the iter-(N-1) state Phase 1, Phase 2, and Phase 3 of the engine will consume. **Phase 1+2 always re-run**; this step does NOT skip them. The earlier version of this gate did skip Phase 1+2 wholesale when the fix commit didn't intersect the prior checklist's files, and that turned out to be the primary false-pass mechanism for this skill — see the rationale block below. A promoted iteration is the explicit exception described in Step 2.6: its short-circuit staging artifact also carries the promotion site's chosen `promotion_provenance`, so the fused iter-record Write reads durable staged state rather than conversational memory.

**Why this step is a handoff, not a skip gate.** The user's framing, which is load-bearing: iterations exist for two distinct reasons that need *different* responses.

1. **Fix-induced defects** — did the fix introduce new bugs? File-intersection between the fix commit and the prior checklist IS the right signal here, and we exploit it via Phase 2's narrow per-item reuse (see /devflow:review's Phase 2.0.5).
2. **Variance-recovered defects** — did iter-(N-1) miss something a second look would find? File-intersection is the WRONG signal here. The very assumption iterations exist to challenge is that the prior pass's checklist was complete; gating Phase 1+2 on "the fix touched a prior-checklist file" silently sacrifices this case to optimize the first. Variance recovery is handled by (a) Phase 1's generator running fresh with the prior checklist as a dedup input, and (b) Phase 3's review agents always re-running with prior findings labeled "already considered, look for new."

This step's job is to compute and stage the inputs both Phase 1 and Phase 2 need; it does not decide whether to run them.

Compute:

1. **Fix-files set** (`fix_files`). The files modified by iter-(N-1)'s fix commit. **Prefer the value Step 3.7 already wrote** to iter-(N-1)'s workpad (the `fix_files` field); the workpad is being loaded anyway for `prior_checklist` and `prior_phase3_findings`, so no extra cost. If the field is absent (older workpad, partial write), recompute:
   ```bash
   git diff --name-only ${PREV_FIX_COMMIT}~1 ${PREV_FIX_COMMIT}
   ```
   where `${PREV_FIX_COMMIT}` is the `fix_commit_sha` recorded in `iter-<N-1>.json`. If `iter-<N-1>.json` itself is missing or unreadable, the lifecycle note (see the root `SKILL.md`'s `### Lifecycle` "Iter N start" bullet) already covers this: skip the handoff optimizations entirely (Phase 1 runs without the prior-checklist variance-recovery block; Phase 2.0.5 reuses nothing; Phase 3 runs without prior-findings context) and proceed to Step 1. Do not attempt partial recovery from `HEAD~1` — without the prior checklist, `fix_files` alone has no downstream consumer.

2. **Prior checklist** (`prior_checklist`). The full `checklist` array from `iter-<N-1>.json`, including each item's `claim_signature` and `verdict`.

3. **Prior Phase 3 findings** (`prior_phase3_findings`). The full `phase3_findings` array from `iter-<N-1>.json`, including each finding's `defect_signature` and the matching `fix_decisions` entry (so Phase 3 can see which were applied vs. pushed back vs. deferred).

Pass these into Step 1:
- Phase 1's generator dispatch receives `prior_checklist` (variance-recovery mode — see /devflow:review's Phase 1.2 conditional block).
- Phase 2's verification step receives `prior_checklist` and `fix_files` for narrow per-item reuse (see /devflow:review's Phase 2.0.5).
- Phase 3's review-agent dispatch receives `prior_phase3_findings` labeled "already considered" (see /devflow:review's Phase 3.1 conditional block).

Log: `Fix-delta handoff: iter-{N-1} fix touched {len(fix_files)} file(s) ({names}); passing prior checklist ({len(prior_checklist)} items) and prior Phase 3 findings ({len(prior_phase3_findings)}) into Phase 1+2+3 for narrow reuse and variance recovery.`

### Step 1: Run the Review Engine

**Mandatory and authoritative.** Use `Glob` with pattern `**/devflow/skills/review/SKILL.md` to locate /devflow:review's SKILL.md, then `Read` it in full. **Engine-location fallback (self-review case).** That Glob requires a `devflow/` path component, so it matches the vendored-consumer layout (e.g. `.devflow/vendor/devflow/skills/review/SKILL.md`) but **nothing inside the devflow repo itself**, whose engine lives at the repo-root `skills/review/SKILL.md`. When the Glob returns **no match**, fall back to the repo-own path `skills/review/SKILL.md` (resolved from the repo root) and `Read` that. The Glob stays **primary** (the common adopter case); this fallback only ever applies when devflow reviews its *own* PR (see the self-review callout below). Execute its **Phases 0 through 4.3 verbatim** — do not improvise the Phase 3 agent prompts, do not skip the Phase 1 >10-file batching, do not substitute your own verdict criteria. This skill deliberately does *not* contain a paraphrase of those phases; only error out (see Error Handling) when **both** the Glob and the repo-own fallback fail to resolve a readable file.

**Why path-based loading, not `Skill: "devflow:review"`.** The `Skill` tool *executes* a skill end-to-end; it would run /devflow:review's Phase 4.4 (formal GitHub post) before this loop has converged, defeating the deferred-post design. We need /devflow:review's phases as a *procedure read inline*, not as an opaque invocation. The path-coupling that follows is the price of that: the glob assumes the plugin layout `<plugin-root>/skills/<skill-name>/SKILL.md` (per the agentskills.io convention) — `**` absorbs depth changes, but the `skills/review/` sub-path is load-bearing. If that layout ever changes, update the glob pattern here and in the "Engine sharing" paragraph at the top of /devflow:review's SKILL.md.

**Self-review / version-skew (the artifact under review *is* the executing engine).** When the PR under review modifies devflow's own engine surface (`skills/**`, `agents/**`, `lib/**`), two hazards apply that don't exist on an adopter's repo. (1) **Engine location:** the vendored-consumer Glob matches nothing in the devflow repo, so without the repo-own fallback above the run would either hit the fatal "cannot locate" path or — worse — silently resolve a *stale plugin-cache copy* (`.claude/plugins/.../devflow/<version>/skills/review/SKILL.md`) that diverges from the branch under review. The Glob is primary (adopter case) and the repo-own path is its no-match fallback — but in the self-review case that ordering can betray you: if a stale plugin-cache copy carrying a `devflow/` path component happens to sit under the working tree, the Glob *matches it* and the fallback never fires. So when reviewing devflow's own PR, **override to the repo-own `skills/review/SKILL.md` on the branch whenever the Glob resolves a copy whose content diverges from it**: the branch is the source of truth for a self-review, and a cache-vs-branch skew means you would be reviewing the diff with a *different* engine than the one the diff changes. (2) **Loaded-vs-edited skew:** your *own* running instructions are whatever was loaded at invocation (often the plugin cache), which may predate the branch's engine edits — so a change this very PR makes to the loop wrapper does **not** alter the loop you are currently executing. Read the engine fresh from the branch on every Step 1 (and Step 2.6) rather than trusting loaded memory of "what the engine does," and treat the branch's `skills/review/SKILL.md` as authoritative when it disagrees with your loaded copy.

When iter N≥2, hand off the `fix_files`, `prior_checklist`, and `prior_phase3_findings` computed in Step 0.9 into the engine's Phase 1 (generator variance-recovery prompt block), Phase 2 (narrow-reuse — Phase 2.0.5), and Phase 3 (prior-findings context block). Phase 1+2 always run; their *outputs* may be smaller because Phase 2.0.5 reuses some prior verdicts, but the phases themselves do not skip.

**Pass the held `run_id` into the engine's Phase 0.2 on every iteration (both modes).** So the engine scopes its scratch (`diff.patch`, and its Phase 4.5 trace input) under the *same* `<run-id>` this wrapper uses for `iter-*.json` / `deferrals.json`, hand the `RUN_ID` computed once at loop start to Phase 0.2 — see /devflow:review's Phase 0.2 "Caller run-id" for the mechanic (Phase 0.2 prefers a caller-provided run-id over computing its own, which on a local run would otherwise change between inline invocations and scatter one run's scratch across directories).

**PR-mode head-override (every PR-mode iteration).** In PR mode, pass `head_override = local` into the engine's Phase 0.2 — see /devflow:review's Phase 0.2 "Caller head-override" for the mechanic (it diffs against local `HEAD` instead of re-fetching `gh pr diff`). This is what makes the engine review the fix commits this loop has made locally rather than stale pushed state: on iteration 1 (no fixes yet, branch freshly synced in Step 0.5) it is diff-identical to the remote fetch, and from iteration 2 on it keeps the loop off pre-fix code. Because convergence rides on this override and not on pushing, a no-push PR-mode run (`--push-each-iteration` absent) still converges. Current-branch mode needs no override — it already diffs against local `HEAD`.

Skip /devflow:review's Phase 4.4 (formal GitHub review posting). The fix loop is silent on GitHub by design — the final report is emitted to chat only at Loop Exit. A human who wants a formal merge signal runs `/devflow:review <PR>` separately.

**Red flags — STOP and run Glob+Read if you're about to:**
- Skip the Read because "I already know what /devflow:review does"
- Paraphrase the Phase 3 agent prompts instead of using them verbatim
- Treat the engine recap below as a substitute for the canonical phases
- Guess the path instead of running Glob
- append focus/prioritize/scope clauses to a shadow prompt, hand it regenerated or subsetted diff artifacts, or write steering into its prompt-extension file

Every drift incident this skill has had traces to one of those rationalizations. Violating the letter of /devflow:review's phases is violating the spirit, even when the paraphrase reads correct. The engine-defined iter-N≥2 prior-findings handoff is sanctioned only for Step-1 loop iterations, never for a shadow prompt; provenance-clean extension text is the only sanctioned shadow-prompt addition.

The engine produces, for this iteration: a verdict in {APPROVE, APPROVE with notes, APPROVE WITH CAVEAT, APPROVE WITH ADVISORY NOTES, REJECT} (matching `/devflow:review`'s Phase 4.1 enum) plus a markdown report. Phase 0.5 flags (`small_diff`, `config_only`, `has_new_types`, `engine_self_modifying`, `checklist_skipped`) apply unchanged. **The fix loop's iteration cap is still `$MAX_ITERS`** (the configured cap; default 5) — Phase 0.5 only scales agent dispatch, not the loop.

### Step 2: Check Verdict

- Engine verdict **APPROVE** AND no advisory findings carry forward from any prior Step 2.5 → tentative final verdict `APPROVE`. When parked findings exist on this clean-APPROVE arm, run the parked-class sweep before **Step 2.6: Shadow review**; otherwise go directly to Step 2.6.
- Engine verdict **APPROVE** but advisory findings have been parked → tentative final verdict `APPROVE WITH ADVISORY NOTES`. Go to the parked-class sweep before **Step 2.6: Shadow review**.
- For this Step 2 split, advisory findings exclude `decision: "below-threshold"` rows. Those producer rows are sweep inputs only and do not change the verdict selected by the two arms above.
- Engine verdict **APPROVE WITH CAVEAT** (Phase 4.2 rule 4a — a checklist *coverage* gap, e.g. checklist generation failed; **not** a finding-severity verdict) → tentative final verdict `APPROVE WITH CAVEAT`. If parked findings exist on this coverage-caveat arm, run the parked-class sweep before **Step 2.6: Shadow review**; otherwise go directly to Step 2.6. There are no Important findings to fix on this path; the caveat is about verification coverage.
- Engine verdict **APPROVE with notes** (Phase 4.2 rule 6 — only findings *below* the engine's `verdict_severity_threshold` present, no REJECT-driver) → split on finding severity **against the resolved `$FIX_THRESHOLD`**:
  - **If the current iteration's `phase3_findings` contains any finding whose severity is at or above `$FIX_THRESHOLD`** (severity ordering `critical` > `important` > `suggestion`; at the default `important` this is any Important/Major *or* Critical finding, and at `suggestion` it is any finding at all) → do **NOT** go to the shadow pass yet. Continue to **Step 2.5** (verification gate) → **Step 3** (fix), routing it exactly as a REJECT would route *for loop purposes* — a skill named review-and-**fix** fixes findings at or above the configured threshold, it does not merely note them. The same Step 2.5 gate that guards Critical findings runs first (web-verifying single-source external-tool claims, passing codebase claims straight through), so a confidently-wrong finding at or above the threshold is demoted to advisory rather than blindly applied — the identical protection Critical findings already get. A finding Step 3 *cannot* fix is recorded via the existing `skip_category` pushback flow (Step 3, item 5), the same as a skipped Critical; it does **not** spin, because the `$MAX_ITERS`-iteration cap, the "same `(source_file, claim_text)` skipped twice → escalate to the user and stop" rule (Step 3, item 5), and Step 4.5's convergence check jointly bound it (this holds at every threshold value, including `suggestion`, which admits Suggestion/Minor findings to the fixer under the same cap and convergence check, with no new bounding rule). This routing change lives **only** here in the loop wrapper; `/devflow:review`'s Phase 4.2 verdict computation is unchanged — standalone `/devflow:review` applies no fixes.
  - **If every finding is below `$FIX_THRESHOLD`** (nothing at or above the threshold) → append one `fix_decisions` row per finding with `decision: "below-threshold"`, `skip_category: "below-threshold-parked"`, and the pinned evidence marker `parked-origin: below-threshold`; then set tentative final verdict `APPROVE WITH CAVEAT` and go to the parked-class sweep before **Step 2.6: Shadow review**. Findings below the threshold remain advisory and are **not** auto-fixed. These rows make this parking arm derivable without reusing `advisory-parked`: exclude `decision: "below-threshold"` explicitly from the Step 2 clean-APPROVE versus `APPROVE WITH ADVISORY NOTES` “advisory findings carry forward” split, the Loop Exit `APPROVE WITH ADVISORY NOTES` trigger, and the chat headline's advisory count. Only the parked-class sweep union reads these rows. This producer covers findings parked by this arm; below-threshold findings omitted on mixed-severity iterations remain covered by the union's `phase3_findings` minus `applied` derivation.
- **REJECT-driver widening (applies on every REJECT and every threshold combination).** The loop's **effective fix set** is: every finding at or above `$FIX_THRESHOLD` **PLUS every finding that drove the engine's REJECT** (at or above `devflow_review.verdict_severity_threshold`, **or driving a threshold-independent REJECT class — e.g. the Phase 4.2 self-contradicting-diff carve-out — regardless of its severity chip**; excluding deferral-demoted findings) — even when that REJECT-driver is *below* `$FIX_THRESHOLD`. So a `verdict_severity_threshold` more inclusive than `$FIX_THRESHOLD` (e.g. verdict `suggestion`, fix `important`) never deadlocks the loop: the fixer can always act on whatever blocks convergence, and **no configuration combination produces a REJECT the fixer is configured to ignore**. These REJECT-drivers route through Step 2.5 → Step 3 exactly like any other fixable finding.
- Engine verdict **REJECT** → continue to Step 2.5. (REJECT verdicts never reach the shadow pass — the loop is still finding things to fix; let it converge first.)



<!-- END loop-control.md -->
