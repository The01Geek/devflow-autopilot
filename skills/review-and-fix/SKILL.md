---
name: review-and-fix
description: Use when you need findings on a PR or current branch to be auto-applied, not just reported.
argument-hint: "[pr-number] [--push-each-iteration]"
---

# /devflow:review-and-fix — Review, Fix, and Verify Loop

You are the review-and-fix orchestrator. Run /devflow:review's review engine, fix the findings it surfaces, and re-run until the engine returns a clean verdict.

**Input:** `$ARGUMENTS` may contain an optional PR number and/or the flag `--push-each-iteration`. Parse the two independently — either, both, or neither may be present (`863`, `--push-each-iteration`, `863 --push-each-iteration`, or empty). If no PR number is given, review and fix the current branch. The numeric token (if any) is `$PR_NUMBER` throughout this skill.

**`--push-each-iteration` (default off).** When set, the loop runs `git push` after each iteration's fix commit (Step 3, item 6), so the remote PR branch — and any CI attached to it — tracks every iteration. When absent (the default, and the expected mode for direct user invocation), the loop commits locally and never touches the remote. The flag governs *commit propagation only*; it does NOT post a verdict to GitHub (`gh pr review` / `gh pr comment`) in either case — the skill stays silent on verdicts by design (see "Engine source of truth"). `/devflow:implement` sets this flag at its Phase 3.3 because it operates on a live draft PR with CI; direct users normally omit it. The flag is orthogonal to loop correctness: the loop sees its own fixes regardless of pushing (current-branch mode diffs against local `HEAD`; PR mode uses the head-override in Step 1).

**Key principle:** You perform fixes DIRECTLY in this session. Do NOT delegate fixes to a subagent. You need full conversation context to apply `superpowers:receiving-code-review` principles (technical evaluation, pushback, verification).

## When NOT to use

- Not for trivial doc-only PRs — use `/devflow:review` and read the report; auto-fixing prose adds churn for little value. **Exception — engine-surface PRs are never "doc-only" for this purpose.** When the diff touches devflow's own engine surface (`skills/**`, `agents/**`, `lib/**` — including changes that are *entirely* Markdown, like a SKILL.md edit), `/devflow:review`'s Phase 0.5 sets `engine_self_modifying` and forces the **full** checklist + all four always-on Phase-3 agents, precisely because a typo there silently breaks every future review. Those changes are the highest-risk diffs in the repo, not low-value prose — so this doc-only carve-out does **not** apply to them: an all-Markdown engine-surface PR is unambiguously a valid `review-and-fix` target. The carve-out is only for genuinely inert prose (READMEs, `docs/`, comments) outside the engine surface.
- Not for PRs where you want to hand-review every finding before deciding — use `/devflow:review` instead; this skill commits fixes between iterations.
- Not for PRs that cross a release boundary or touch infrastructure where surprise commits would be costly — review-and-fix produces commits as a side effect of converging.
- Not for first-pass branch hygiene (rebases, conflict resolution, build fixes) — get a clean diff first, then run review-and-fix on the result.
- Not for situations where you need a formal `--request-changes` merge block as a side effect — this skill is silent on GitHub by design. Run `/devflow:review <PR>` afterward (or instead) to post the verdict as a blocking review.

## Engine source of truth

This skill wraps /devflow:review's four-phase engine in a fix loop. Phases 0 through 4.3 — setup, diff classification, checklist generation (including >10-file batching and Phase 1.5 dedup), checklist verification (including lite-mode partition), review agents (including the exact per-agent prompts and the `defect_signature` contract), and aggregation — live in `/devflow:review`'s SKILL.md and are authoritative. Read them on every Step 1; never improvise the engine or paraphrase the Phase 3 prompts. Drift between the two skills is the single biggest cause of /devflow:review-and-fix missing findings that /devflow:review caught.

This skill **skips** /devflow:review's Phase 4.4 entirely — no GitHub post. The final report is emitted to chat only; the human reviewer decides whether to convert it into a formal merge signal by running `/devflow:review <PR>` separately (which performs an independent re-review and posts the result). It also adds:
- A **fix-delta handoff** before Step 1 in iterations N≥2 (passes the prior iteration's checklist + fix-files into Phase 1's generator and Phase 2's narrow-reuse logic; Phase 1+2 always re-run — they are *not* skipped wholesale).
- A **persistent workpad** (`.devflow/tmp/review/<slug>/<run-id>/iter-<N>.json`, run-scoped) that carries checklist verdicts, findings, fix decisions, and convergence inputs across iterations.
- A **shadow review pass** at Step 2.6 — a *parent-orchestrated* independent re-review that re-runs /devflow:review's Phases 0–4.3 with each reviewer agent's prompt blinded to the loop's prior findings — before declaring convergence on a non-REJECT verdict (see Step 2.6).
- A **`## Coverage` section** in the final report aggregating per-iter finding counts, shadow agreement, and Phase 1.1.5 cap drops (see Loop Exit → Coverage).
- A **per-phase telemetry summary** at Loop Exit (agent calls / tokens / wall-clock).

**Maintainer rule.** Engine changes belong in /devflow:review's SKILL.md; this file should only touch the loop wrapper, the workpad, the fix-delta handoff (Step 0.9), the Step 2.5 verification gate, the Step 2.6 shadow review, the fix step, the convergence check, the telemetry summary, or Loop Exit's chat output. **Violating the letter of these phases is violating the spirit** — even when a paraphrase looks faithful, the downstream agents are calibrated to /devflow:review's exact wording.

---

## Persistent workpad

The orchestrator persists per-iteration state under `.devflow/tmp/review/<slug>/<run-id>/iter-<N>.json` (relative to the repo root). `<slug>` is `pr-<N>` in PR mode or the sanitized current branch name in branch mode. `<run-id>` is a per-run discriminator (see below). `<N>` is the iteration number, starting at 1.

**Run-scoping (`<run-id>`).** The workpad is scoped by a per-run id so that a second `/devflow:review-and-fix` or `/devflow:review` invocation on the same PR — including `/devflow:implement` Phase 3.3's bounded re-review, which re-invokes this skill on the *same* PR — never clobbers a prior run's `iter-*.json` or `deferrals.json`. Reuse the **exact** discriminator `/devflow:review`'s live progress comment already uses (don't invent a new one):

```bash
RUN_ID="${GITHUB_RUN_ID:-local-$(date -u +%Y%m%dT%H%M%SZ)}-${GITHUB_RUN_ATTEMPT:-1}"
```

Compute `RUN_ID` **once at loop start, before iteration 1, and hold the literal value for the run's whole lifetime** — never recompute it (on a local run the timestamp would change between calls and split one run's state across two directories). This is the same compute-once-and-reuse rule the run-keyed progress-comment marker follows.

**All in-run scratch is run-scoped** — `diff.patch`, `iter-*.json`, and `deferrals.json` all live under `.devflow/tmp/review/<slug>/<run-id>/`, so two runs on the same PR never clobber any of them. The cached diff is at `.devflow/tmp/review/<slug>/<run-id>/diff.patch` — the full diff written by Phase 0.2 of `/devflow:review` on every iteration (overwritten within a run, but never across runs). Phase 3 agents Read this file directly via the `{DIFF_PATH}` substitution Phase 0.2 fills in, instead of re-running `gh pr diff` / `git diff` 4–5 times in parallel — so they pick up the run-scoped path automatically with no per-agent-prompt change. **Run-id consistency across the wrapper and the engine:** so the engine's Phase 0.2 and this wrapper agree on one `<run-id>` for the whole run (rather than `/devflow:review` computing a fresh timestamp-based id on each inline invocation), the wrapper passes its held `RUN_ID` into the engine's Phase 0.2 (see Step 1's head-override paragraph, which already plumbs caller inputs into Phase 0.2). See `/devflow:review`'s Phase 0.2 for the write logic.

**Important.** Only `.devflow/tmp/` is ephemeral working state — the rest of `.devflow/` (`config.json`, `learnings/`, the schema/example) is intentionally tracked. The scaffolder (`scripts/scaffold-config.sh`, run by `install.sh` / `/devflow:init`) writes a scoped `.devflow/.gitignore` that ignores only `tmp/`. This skill does NOT manage that entry itself (it's a repo-level concern); flag missing coverage in the chat output only if `.devflow/tmp/` is not already ignored.

### Schema

```json
{
  "iter": 1,
  "started_at": "2026-05-16T20:45:00Z",
  "fix_commit_sha": "abc1234",
  "fix_files": ["src/example_pkg/foo.py", "tests/test_foo.py"],
  "checklist": [
    {
      "id": "VC-1",
      "claim": "...",
      "file": "src/example_pkg/foo.py",
      "verification_mode": "lite",
      "claim_signature": "api_contract:foo.py:spdx-header-present",
      "verdict": "PASS",
      "evidence": "...",
      "reused_from_iter_prev": false
    }
  ],
  "phase3_dispatched": [
    "pr-review-toolkit:code-reviewer",
    "pr-review-toolkit:silent-failure-hunter",
    "pr-review-toolkit:comment-analyzer",
    "superpowers:requesting-code-review",
    "pr-review-toolkit:type-design-analyzer",
    "pr-review-toolkit:pr-test-analyzer"
  ],
  "diff_profile": {
    "small_diff": false,
    "config_only": false,
    "has_new_types": true,
    "engine_self_modifying": false,
    "checklist_skipped": null
  },
  "phase3_findings": [
    {
      "agent": "pr-review-toolkit:code-reviewer",
      "severity": "Critical",
      "description": "...",
      "defect_signature": {"file": "src/example_pkg/foo.py", "line_range": [42, 47], "kind": "null_deref"},
      "corroboration_count": 2,
      "step25_classification": "codebase | web_confirmed | web_refuted | web_inconclusive | over_budget",
      "fix_decision": "applied | pushed_back | deferred | advisory"
    }
  ],
  "fix_decisions": [
    {"finding_id": "F-3", "decision": "applied", "commit": "abc1234"},
    {
      "finding_id": "F-7",
      "decision": "pushed_back",
      "source_file": "src/example_pkg/foo.py",
      "claim_text": "function returns None when input is empty",
      "skip_category": "claim-quality",
      "evidence": "lines 200-220 of foo.py show the empty-input branch raises ValueError instead"
    },
    {
      "finding_id": "F-9",
      "decision": "deferred",
      "source_file": "src/example_pkg/bar.py",
      "claim_text": "race condition in concurrent writer",
      "skip_category": "already-tracked",
      "evidence": "#42"
    },
    {
      "finding_id": "F-11",
      "decision": "deferred",
      "source_file": "src/example_pkg/baz.py",
      "claim_text": "preexisting style violation on line 88",
      "skip_category": "out-of-scope",
      "evidence": "git blame shows line 88 unchanged by this PR (last touched in commit 9abcdef, three months ago)"
    },
    {
      "finding_id": "F-13",
      "decision": "deferred",
      "source_file": "src/example_pkg/qux.py",
      "claim_text": "log message is slightly imprecise about which retry attempt failed",
      "skip_category": "uncategorized",
      "evidence": "real but minor wording nit; not worth a fix-loop iteration"
    },
    {
      "finding_id": "F-15",
      "decision": "advisory",
      "source_file": "src/example_pkg/quux.py",
      "claim_text": "claim about a specific Postgres lock mode behavior",
      "skip_category": "advisory-parked",
      "evidence": "Step 2.5 demoted this finding after WebFetch verification; refuted by https://www.postgresql.org/docs/current/explicit-locking.html"
    }
  ],
  "convergence_inputs": {
    "fixes_applied": 4,
    "fix_diff_lines": 22,
    "new_corroborated_critical_count": 0
  },
  "cap_drops": {
    "count": 0,
    "by_category": {}
  },
  "shadow": {
    "ran_at": null,
    "verdict": null,
    "coverage": null,
    "reviewers_dispatched": [],
    "expected_reviewers": [],
    "reason": null,
    "checklist_skipped": null,
    "phase3_findings": [],
    "phase2_fails": [],
    "comparison": {
      "shadow_total": 0,
      "overlap_with_iter_N": 0,
      "new": 0,
      "new_critical": 0,
      "new_important": 0
    },
    "promoted_to_iter_next": false
  },
  "telemetry": {
    "phase_0":    {"calls": 0, "tokens": 0,     "wall_clock_s": 1.2},
    "phase_0_5":  {"calls": 0, "tokens": 0,     "wall_clock_s": 0.3},
    "phase_1":    {"calls": 2, "tokens": 9400,  "wall_clock_s": 28},
    "phase_1_5":  {"calls": 1, "tokens": 3100,  "wall_clock_s": 11},
    "phase_2":    {"calls": 27,"tokens": 95000, "wall_clock_s": 220},
    "phase_3":    {"calls": 5, "tokens": 48000, "wall_clock_s": 180},
    "step_2_5":   {"calls": 0, "tokens": 0,     "wall_clock_s": 4,  "webfetches": 2},
    "step_2_6":   {"calls": 35,"tokens": 155000,"wall_clock_s": 440}, /* aggregates a full Phases 0–4.3 fan-out (tens of agent calls), not a single call — contrast phase_3's 5 above */
    "phase_4_x":  {"calls": 0, "tokens": 0,     "wall_clock_s": 1}
  }
}
```

`phase3_dispatched` is the array of Phase-3 agent identifiers **actually launched** this iteration, captured at Step 1's Phase 3.1 dispatch *after* Phase 0.5 gating (so a gated-out `pr-test-analyzer` / `type-design-analyzer` is absent). It is load-bearing for the Loop Exit effectiveness trace: a `null` verdict (dispatched but silent) is derived as `phase3_dispatched − (agents present in phase3_findings)`, so without this roster a silent agent is indistinguishable from one that was never launched. The field is best-effort — if it is absent on an older/partial workpad, the trace degrades to classifying only the agents that appear in `phase3_findings`. (In the example above `pr-test-analyzer` appears in `phase3_dispatched` even though `diff_profile` records only `has_new_types: true`: `pr-test-analyzer` is gated by the **test-relevance predicate**, which is not a `diff_profile` flag, so its presence cannot be cross-checked against the profile — this is the same asymmetry the too-narrow tripwire relies on when it keys off `phase3_dispatched` rather than `diff_profile`.)

Use the **same identifier string** in `phase3_dispatched` that you write to each finding's `phase3_findings.agent`, so the trace can match dispatch to outcome. For the five pr-review-toolkit agents that is `pr-review-toolkit:<name>` (e.g. `pr-review-toolkit:code-reviewer`). For the sixth Phase-3 dispatch — the general-purpose final-pass reviewer launched via `Task`/`subagent_type: general-purpose` invoking `/superpowers:requesting-code-review` (see /devflow:review's Phase 3.1) — record it as **`superpowers:requesting-code-review`** in both places, so this (most expensive) dispatch is tallied consistently rather than appearing under an ad-hoc string each run.

`diff_profile` records the engine's Phase 0.5 classification for this iteration — the four flags (`small_diff`, `config_only`, `has_new_types`, `engine_self_modifying`) plus a nested `checklist_skipped` member (`"intentional"` when Phase 0.5 bypassed Phase 1+2 on a small_diff+config_only diff, `"failure"` when checklist generation failed, else `null`) — so the checklist-skip tripwire's `diff_profile.checklist_skipped` read resolves against the nested field shown in the schema example, not a sibling. It is load-bearing for fair cross-run analysis in two ways: (1) a `null`-verdict agent on a `config_only` diff is *correctly* silent (out of its domain), not a cut candidate — the analyzer must segment by diff shape, and this is how it learns the shape; (2) it lets the trace report the orchestrator's **verification posture** — when Phase 0.5 skips the checklist, or when every verifiable item was resolved via the cheap orchestrator-direct `lite` path instead of dispatching verifier subagents, that is a deliberate cost-saving decision and the trace says so explicitly rather than rendering a bare "0 verifiers". Best-effort: if `diff_profile` is absent, the trace labels the profile "not recorded" and the posture falls back to the raw lite/agent counts.

`cap_drops` is populated from /devflow:review's Phase 1.1.5 output (see that skill's Phase 1.1.5 for the shape — `count` is the total dropped at the 100-item cap, `by_category` is the per-category breakdown). The Coverage section in the final report reads this.

`shadow` is populated by Step 2.6 (the shadow review pass). `coverage` is `"full"` when the parent ran the complete multi-agent fan-out a standalone /devflow:review Phase 3 would launch (subject to the Phase 3.1 applicability gates) and `"not_verified"` when the fan-out could not be completed (outcome 3 — see Step 2.6 "Decide"); `reviewers_dispatched` is the roster of Phase-3 reviewer agents the parent actually launched for the shadow (same identifier strings as `phase3_dispatched`). It is only present on the workpad of the iter that triggered the shadow — typically the iter with the tentative non-REJECT verdict. Promoted-shadow iters (when the shadow surfaces new findings and triggers iter N+1 → Step 2.5) have their own workpad without a `shadow` block of their own unless they too produce a non-REJECT verdict that triggers another shadow.

### Lifecycle

- **Iter 1 start:** create the run-scoped directory `.devflow/tmp/review/<slug>/<run-id>/` if missing (using the `RUN_ID` computed once at loop start). There is no prior iteration to read.
- **Iter N start (N≥2):** before doing anything else, read `iter-<N-1>.json`. The fix-delta handoff (Step 0.9) and convergence check both consume it. If the file is missing or unreadable, log a warning and continue without the handoff optimizations (Phase 1 generator runs without the prior-checklist variance-recovery block; Phase 2.0.5 reuses nothing; Phase 3 runs without prior-findings context). Phase 1+2+3 still run — they always do.
- **Iter N end:** write `iter-<N>.json` with everything collected during the iteration before looping back to Step 1.
- **Step 2.6 end (shadow pass):** when the shadow review pass runs at end-of-loop, append the `shadow` block to the latest iter's workpad (re-writing `iter-<N>.json` with the shadow result included). If the shadow promotes new findings into iter (N+1), iter (N+1) is a normal iter from a lifecycle standpoint — it will write its own `iter-<N+1>.json` per the regular end-of-iter rule.

The workpad is best-effort and informational. A write failure should not abort the loop — log it and continue.

---

## Main Loop

**Resolve the iteration cap once, at loop start.** Read `devflow_review_and_fix.max_iterations` (default 5) via the config helper — the same `${CLAUDE_SKILL_DIR}`-anchored, no-`bash`-prefix invocation the effectiveness-trace gate uses (see "Subagent effectiveness trace"), so the read is cwd-independent and the resolved-path allow-list entry matches. Capture stderr + rc so a resolver failure (missing `node`, malformed `config.json` → non-zero exit with empty stdout) is distinguishable from a legitimately-absent key, and clamp the result:

```bash
MAX_ITERS=$("${CLAUDE_SKILL_DIR}/../../scripts/config-get.sh" .devflow_review_and_fix.max_iterations 5 2>/tmp/devflow-maxiter.err); MAX_ITERS_RC=$?
# Surface a genuine resolver failure (missing `node`, malformed config.json) in the
# Actions UI rather than swallowing it into a silent default — mirrors the
# effectiveness-trace gate's `::warning::` on a non-zero read.
if [ "$MAX_ITERS_RC" -ne 0 ]; then
  echo "::warning::devflow review-and-fix max_iterations read failed (rc=$MAX_ITERS_RC): $(cat /tmp/devflow-maxiter.err) — using default 5"
fi
# Fallback to the default 5 on any resolver failure (rc≠0 → empty stdout) or a
# non-integer/empty value; clamp a configured value below 1 up to 1 so the loop
# always runs at least once. No upper bound is imposed — any integer ≥ 1 is honored.
if [ "$MAX_ITERS_RC" -ne 0 ] || ! printf '%s' "$MAX_ITERS" | grep -Eq '^-?[0-9]+$'; then
  MAX_ITERS=5
elif [ "$MAX_ITERS" -lt 1 ]; then
  MAX_ITERS=1
fi
```

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

On iterations N ≥ 2, prepare the iter-(N-1) state Phase 1, Phase 2, and Phase 3 of the engine will consume. **Phase 1+2 always re-run**; this step does NOT skip them. The earlier version of this gate did skip Phase 1+2 wholesale when the fix commit didn't intersect the prior checklist's files, and that turned out to be the primary false-pass mechanism for this skill — see the rationale block below.

**Why this step is a handoff, not a skip gate.** The user's framing, which is load-bearing: iterations exist for two distinct reasons that need *different* responses.

1. **Fix-induced defects** — did the fix introduce new bugs? File-intersection between the fix commit and the prior checklist IS the right signal here, and we exploit it via Phase 2's narrow per-item reuse (see /devflow:review's Phase 2.0.5).
2. **Variance-recovered defects** — did iter-(N-1) miss something a second look would find? File-intersection is the WRONG signal here. The very assumption iterations exist to challenge is that the prior pass's checklist was complete; gating Phase 1+2 on "the fix touched a prior-checklist file" silently sacrifices this case to optimize the first. Variance recovery is handled by (a) Phase 1's generator running fresh with the prior checklist as a dedup input, and (b) Phase 3's review agents always re-running with prior findings labeled "already considered, look for new."

This step's job is to compute and stage the inputs both Phase 1 and Phase 2 need; it does not decide whether to run them.

Compute:

1. **Fix-files set** (`fix_files`). The files modified by iter-(N-1)'s fix commit. **Prefer the value Step 3.7 already wrote** to iter-(N-1)'s workpad (the `fix_files` field); the workpad is being loaded anyway for `prior_checklist` and `prior_phase3_findings`, so no extra cost. If the field is absent (older workpad, partial write), recompute:
   ```bash
   git diff --name-only ${PREV_FIX_COMMIT}~1 ${PREV_FIX_COMMIT}
   ```
   where `${PREV_FIX_COMMIT}` is the `fix_commit_sha` recorded in `iter-<N-1>.json`. If `iter-<N-1>.json` itself is missing or unreadable, the lifecycle note (see "Persistent workpad → Lifecycle" above) already covers this: skip the handoff optimizations entirely (Phase 1 runs without the prior-checklist variance-recovery block; Phase 2.0.5 reuses nothing; Phase 3 runs without prior-findings context) and proceed to Step 1. Do not attempt partial recovery from `HEAD~1` — without the prior checklist, `fix_files` alone has no downstream consumer.

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

Every drift incident this skill has had traces to one of those rationalizations. Violating the letter of /devflow:review's phases is violating the spirit, even when the paraphrase reads correct.

The engine produces, for this iteration: a verdict in {APPROVE, APPROVE with notes, APPROVE WITH CAVEAT, APPROVE WITH ADVISORY NOTES, REJECT} (matching `/devflow:review`'s Phase 4.1 enum) plus a markdown report. Phase 0.5 flags (`small_diff`, `config_only`, `has_new_types`, `engine_self_modifying`, `checklist_skipped`) apply unchanged. **The fix loop's iteration cap is still `$MAX_ITERS`** (the configured cap; default 5) — Phase 0.5 only scales agent dispatch, not the loop.

### Step 2: Check Verdict

- Engine verdict **APPROVE** AND no advisory findings carry forward from any prior Step 2.5 → tentative final verdict `APPROVE`. Go to **Step 2.6: Shadow review** before exiting the loop.
- Engine verdict **APPROVE** but advisory findings have been parked → tentative final verdict `APPROVE WITH ADVISORY NOTES`. Go to **Step 2.6: Shadow review**.
- Engine verdict **APPROVE WITH CAVEAT** (Phase 4.2 rule 4a — a checklist *coverage* gap, e.g. checklist generation failed; **not** a finding-severity verdict) → tentative final verdict `APPROVE WITH CAVEAT`. Go to **Step 2.6: Shadow review**. There are no Important findings to fix on this path; the caveat is about verification coverage.
- Engine verdict **APPROVE with notes** (Phase 4.2 rule 6 — only Important and/or Suggestion findings present, no Critical) → split on finding severity:
  - **If the current iteration's `phase3_findings` contains any finding with `severity` `Important` (or its `Major` alias)** → do **NOT** go to the shadow pass yet. Continue to **Step 2.5** (verification gate) → **Step 3** (fix), routing it exactly as a REJECT would route *for loop purposes* — a skill named review-and-**fix** fixes Important findings, it does not merely note them. The same Step 2.5 gate that guards Critical findings runs first (web-verifying single-source external-tool claims, passing codebase claims straight through), so a confidently-wrong Important finding is demoted to advisory rather than blindly applied — the identical protection Critical findings already get. An Important finding Step 3 *cannot* fix is recorded via the existing `skip_category` pushback flow (Step 3, item 5), the same as a skipped Critical; it does **not** spin, because the `$MAX_ITERS`-iteration cap, the "same `(source_file, claim_text)` skipped twice → escalate to the user and stop" rule (Step 3, item 5), and Step 4.5's convergence check jointly bound it. This routing change lives **only** here in the loop wrapper; `/devflow:review`'s Phase 4.2 verdict computation is unchanged — standalone `/devflow:review` still reports an Important-only PR as "APPROVE with notes" and applies no fixes.
  - **If every finding is `severity` `Suggestion`/`Minor` only** (no Important/Major, no Critical) → tentative final verdict `APPROVE WITH CAVEAT`. Go to **Step 2.6: Shadow review**. Suggestion/Minor findings remain advisory and are **not** auto-fixed.
- Engine verdict **REJECT** → continue to Step 2.5. (REJECT verdicts never reach the shadow pass — the loop is still finding things to fix; let it converge first.)

### Step 2.5: Pre-fix verification gate

Before applying any fixes, classify each Critical or Important/Major finding from Phase 3 (the existing review agents). The goal is to keep the loop from auto-applying confidently-stated-but-wrong fixes; LLM verbalized confidence is poorly calibrated, especially on claims about external tool/framework behavior. Phase 2 checklist FAILs and findings raised by ≥2 Phase 3 agents are *corroborated* — pass them straight to Step 3. The gate targets the remaining single-source findings.

For each Critical/Important finding raised by exactly one Phase 3 agent:

1. **Classify the claim:**
   - **External-tool claim** — the finding rests on a specific external framework, CLI flag, GitHub Actions semantic, library API, or platform behavior the orchestrator could look up in docs (e.g. *"id-token: write only takes effect at workflow level"*, *"--permission-mode acceptEdits denies Bash"*, *"`@/`syntax must be quoted in claude-code-action"*). Run web verification.
   - **Codebase claim** — the finding is about this repository only (e.g. *"this method bypasses the project's EntityService pattern"*, *"caller doesn't handle the empty-array return"*). External docs cannot adjudicate these; pass through to Step 3 unchanged.

2. **Web verification** (up to a per-iteration cap of **5** WebFetches; remaining external-tool claims that don't fit the budget become *advisory*):
   - Compose ONE focused query naming the tool and the claimed behavior. Prefer queries that target the canonical documentation source (e.g. `site:docs.github.com id-token permission job level`) over generic web search.
   - WebFetch the most-authoritative-looking source. Preference order: official documentation → tool's GitHub repo / release notes → blog or third-party tracker. Use WebSearch to find the URL first only when no canonical doc URL is obvious.
   - Classify the result:
     - **Confirmed** (the docs explicitly support the agent's claim) → keep finding; auto-fix in Step 3.
     - **Refuted** (the docs explicitly contradict the agent's claim) → **demote to *advisory* with a `refuted by {url}` tag**. Do NOT auto-fix. Also append a line to the workpad's `Devflow Reflection` section: `verified false positive — {claim text} — refuted by {url}` to build the evidence trail. The finding still surfaces in this iteration's `## Advisory Findings` section so the human reviewer can override if the docs were wrong about the codebase. (Earlier versions of this skill *dropped* refuted findings entirely; that hid user-visible evidence and was a primary drift mechanism vs. /devflow:review.)
     - **Inconclusive** (the docs don't directly address the claim, or the fetched page is ambiguous) → demote to *advisory* — do NOT auto-fix.

3. **Add an `## Advisory Findings` section to the iteration's report** listing every advisory finding verbatim (the original agent's claim plus a one-line reason: `refuted by {url}`, `inconclusive after web verification`, or `over verification budget`). Advisory findings:
   - Are surfaced for human attention but are **not** auto-fixed.
   - Do **not** contribute to the per-iteration REJECT/APPROVE verdict — they're parked, not failing, so the loop can converge. They are therefore NEVER a REJECT trigger that the Loop Exit `### Pre-mapping: Step-3-evaluated REJECT downgrade` section has to evaluate; the gate's qualifying `skip_category` set deliberately does not include `advisory-parked` because advisory findings can't reach the gate as triggers in the first place.
   - **Do** contribute to the final reported verdict at Loop Exit: if any advisory findings survive when the engine would otherwise return a clean APPROVE, the final verdict becomes **APPROVE WITH ADVISORY NOTES** and the full advisory list lands in the chat-only final report (see "Verdict → chat output"). This prevents the loop from silently dismissing concerns it couldn't fix.
   - Carry forward across iterations unchanged; do not re-verify the same advisory finding on a later iteration in the same run.
   - **Are recorded in the workpad at demotion time, not at Step 3 / item 7.** When demoting a finding to advisory in this step, append a row to `fix_decisions` of the form `{finding_id, decision: "advisory", source_file, claim_text, skip_category: "advisory-parked", evidence: <one-line demotion reason>}`. This keeps the workpad's `fix_decisions` array the single source of truth for every per-finding outcome (applied / pushed_back / deferred / advisory) — Step 3 item 7 will then only need to write rows for the applied / pushed_back / deferred decisions it sees, since advisory rows are already present.

**Agreement heuristic.** Two findings agree when they describe the same defect (same root cause + same affected file/line span); identical wording is not required. Use your own judgment; do not invoke a subagent for this.

**When WebFetch/WebSearch are unavailable** (older workflow, local invocation with restricted tools), skip the web step: external-tool claims that cannot be verified are demoted to advisory directly. The gate still provides value via the cross-agent corroboration filter.

### Step 2.6: Shadow review (non-REJECT verdicts only)

Run a structurally-independent re-review before declaring convergence. Only triggers when the loop's tentative final verdict is non-REJECT (APPROVE, APPROVE WITH ADVISORY NOTES, APPROVE WITH CAVEAT) — either from Step 2 on the current iteration, or from Step 4.5's early-exit convergence path. REJECT verdicts skip this step and go straight to Loop Exit. (Per the Step 2 APPROVE-with-notes severity split, an `APPROVE with notes` engine verdict carrying an Important/Major finding is **not** a tentative final verdict — it routes to Step 2.5 → Step 3 like a REJECT and only reaches the shadow once those findings are fixed or pushed back; a Suggestion/Minor-only `APPROVE with notes` arrives here as `APPROVE WITH CAVEAT`.)

**Why a shadow pass.** Iterations inside the fix loop share state — the orchestrator's context window carries prior findings, fix decisions, and pushback history forward. That state biases what the engine looks for and what it accepts as "already considered." The shadow pass is the loop's audit: the same multi-agent engine runs again, and we compare. This matches what users already do manually today (`/devflow:review <PR>` after `/devflow:review-and-fix`); doing it inside the loop costs the same and feeds the result into one more iteration if the shadow disagrees, instead of leaving it to the human.

**Where independence comes from.** The shadow's independence does **not** come from running the engine inside a fresh subagent context — it cannot. The engine's Phase 1, 1.5, and 3 *fan out to subagents* (and Phase 2 does for its agent-path items — lite items the orchestrator probes directly), and a subagent cannot dispatch its own subagents (nested `Agent`/`Task` dispatch is unsupported in the harness — this is structural, not a permissions gap, so granting `Agent` to a subagent does not fix it). A single shadow subagent told to "run the engine" therefore reaches Phase 3, finds it has no `Agent` tool, and silently collapses to a degraded single-agent self-check that returns a plausible clean `APPROVE` — the exact false-convergence this step exists to prevent. So the **parent orchestrator** runs the shadow fan-out itself (the parent *can* dispatch), and independence is enforced **per reviewer prompt**: each shadow reviewer agent runs in a fresh context whose prompt withholds the loop's prior findings, fix decisions, and pushback history. The only residual shared state is the parent's aggregation — a far smaller bias risk than losing all of Phase 3's coverage to a degraded subagent.

**Iteration accounting.** The shadow pass itself is NOT counted toward the `$MAX_ITERS`-iteration cap — it's a verification pass on the final iter's state, not a fix iteration. A *promoted* iter (one started because the shadow surfaced new findings — see outcome #2 below) DOES count toward the cap, because it runs Step 2.5 + Step 3 + Step 4 + Step 4.5 from the fix-loop side even though it skips Phase 1+2.

#### Run the shadow fan-out (parent-orchestrated)

**The parent orchestrator runs the shadow engine pass itself — do NOT delegate the whole engine to one `general-purpose` subagent.** A single subagent cannot dispatch the engine's Phase 1/1.5/2/3 fan-out (nested dispatch is unsupported), so it would degrade to a single-agent self-check and return a false clean verdict. Instead, re-run /devflow:review's Phases 0 through 4.3 from the parent using the same loading mechanic as Step 1 — `Glob` for `**/devflow/skills/review/SKILL.md` (with the repo-own `skills/review/SKILL.md` fallback when the Glob matches nothing, per Step 1), `Read` it in full, and execute its phases inline (the parent holds the `Agent` tool, so every Phase-3 reviewer launches normally) — but with the prior-findings handoff *withheld* (the inverse of Step 1's iter-N≥2 inputs; see "Blind every shadow reviewer prompt" below). Stop before Phase 4.4 (no `gh pr review` / `gh pr comment` — the loop is silent on GitHub by design). This reuses /devflow:review's Phase 3.1 launch list and per-agent prompts verbatim, so the shadow exercises the **same reviewer set** a standalone `/devflow:review` Phase 3 would launch on this diff — subject to the same Phase 3.1 structural-applicability gates (`has_new_types` for `type-design-analyzer`, the test-relevance predicate for `pr-test-analyzer`), evaluated against the shadow's own Phase 0.5 classification (it re-runs Phase 0.5 as part of Phases 0–4.3) — see the expected-roster rule below.

**Blind every shadow reviewer prompt — this is the independence guarantee now.** Because the parent's own context is no longer blind (it carries the iter history), independence must be enforced in the prompts instead. This is the **inverse** of Step 1's iter-N≥2 behavior:

- Do **NOT** run Step 0.9's fix-delta handoff for the shadow, and do **NOT** pass `prior_phase3_findings` / `prior_checklist` / `fix_files` into any shadow phase.
- Do **NOT** prepend /devflow:review's Phase 3.1 "Prior-findings context (fix-loop callers only)" block to any shadow reviewer prompt, and do **NOT** populate the general-purpose final-pass reviewer's "Prior-iteration findings (already considered, look for new)" line — pass `"none"` there. The "already considered, look for new" handoff is correct for normal fix iterations but **defeats the shadow's purpose**; reintroducing it turns the audit back into a self-check.
- Each shadow reviewer therefore sees only the diff and the standard task + `defect_signature` prompt — a fresh context with the loop's findings withheld.

Capture `reviewers_dispatched` (the roster of Phase-3 agents you actually launched) as you dispatch — the workpad record and the report's Coverage section both report it. Collect the engine's Phase 4.1 markdown report, its verdict, the aggregated Phase 3 findings (each with its `defect_signature`), and the Phase 2 FAIL/INCONCLUSIVE items, then proceed to "Parse and compare".

**Coverage is a positive assertion, not the default-on-no-error.** Before you may set `coverage: "full"`, compute the **expected roster** for this run and confirm `reviewers_dispatched` covers it — `"full"` is something you *prove*, never what you assume because nothing visibly broke. Record the computed roster in `expected_reviewers` **on every outcome** (including not-verified — the Coverage section needs it to explain *why* a shortfall was a shortfall). The expected roster is mechanical (so a gated-out analyzer is never confused with a dropped reviewer), and it is computed from the **shadow's own Phase 0.5 classification** — the shadow re-runs Phases 0–4.3, so it produces its *own* `diff_profile`; validate the dispatched roster against *that*, not the loop's last-iter recorded profile (a post-fix diff can legitimately flip `has_new_types` or the test predicate). The roster:

- the four **always-on** agents — `pr-review-toolkit:code-reviewer`, `pr-review-toolkit:silent-failure-hunter`, `pr-review-toolkit:comment-analyzer`, `superpowers:requesting-code-review` — unconditionally; **plus**
- `pr-review-toolkit:type-design-analyzer` iff `has_new_types` is true, and `pr-review-toolkit:pr-test-analyzer` iff the test-relevance predicate matches, both evaluated against the shadow's own `diff_profile` per /devflow:review's Phase 3.1 gates.

**`engine_self_modifying` adds and removes nothing here.** Per /devflow:review's Phase 0.5, that override forces the full checklist and the four always-on agents on, but the two structural-applicability gates (`has_new_types`, test-relevance) *survive* it — so on an engine-self-modifying diff the expected roster is still "four always-on + each analyzer whose gate is true," exactly the rule above. Do **not** force the two analyzers into the expected roster on `engine_self_modifying`; that would manufacture a phantom shortfall.

**Too-narrow-classification tripwire.** Because the expected roster is computed from the shadow's *own* Phase 0.5 — deliberately, so a legitimate post-fix flip of `has_new_types` / the test predicate is honored — a too-narrow (mis)classification has a blind spot: if the shadow's own Phase 0.5 *under*-classifies the diff, it shrinks **both** the expected and the dispatched roster in lockstep, so `reviewers_dispatched ⊇ expected_reviewers` still holds and coverage reads `"full"` over a roster that silently dropped a gated analyzer. Defend the invariant **without** abandoning the authoritative-profile rule above (the shadow's own `diff_profile` is still what `expected_reviewers` is normally computed from — the loop's last-iter profile is *not* the authoritative expected roster, because a genuine post-fix flip would otherwise manufacture a phantom shortfall). Instead, consult the loop's **last-iter recorded gated-analyzer roster** — the gated members (`type-design-analyzer` / `pr-test-analyzer`) present in the loop's last-iter `phase3_dispatched` — *only as a one-way narrowing tripwire*. **Compare the dispatched roster, not `diff_profile`:** the persisted `diff_profile` carries `has_new_types` but **not** the test-relevance predicate that gates `pr-test-analyzer`, so a profile-vs-profile comparison can catch a narrowed `type-design-analyzer` yet is blind to a narrowed `pr-test-analyzer` (the exact false-clean this tripwire exists to close, left open for one of the two analyzers) — whereas `phase3_dispatched` records the post-gate launch of *both* analyzers (see the schema note above), so it is the comparand that covers both. When the shadow's own expected roster drops a gated analyzer that the loop's last iter actually launched — a *narrowing* divergence — that flip is suspect (it cannot be told apart from a misclassification), so:
- Record the divergence as a `Devflow Reflection` workpad note (an audit-trail note in the workpad's reflection section — *not* a shadow-block JSON field; the shadow block has no slot for it and the Coverage render reads only the block's `coverage`/`reason`/`comparison`/roster) naming which gate flipped and in which direction, and
- **Widen *both* `expected_reviewers` and the dispatched roster to the union (superset) of both sides' gated analyzers** (the shadow's own expected gated set and the loop's last-iter dispatched gated set) — widening `expected_reviewers` too is essential: if you widened only the dispatched roster, the `reviewers_dispatched ⊇ expected_reviewers` join would still pass on the narrow `expected_reviewers` even when a union-only analyzer never returned, re-opening the very gap this tripwire closes. With both widened, a genuine flip keeps full coverage and a misclassification cannot silently shrink the roster.

(A *widening* divergence — the shadow's profile adds an analyzer — needs no tripwire: the shadow already dispatches the larger roster, and `expected_reviewers` from its own profile already includes it.) Only after the union roster is dispatched **and** every union member is joined (per the 1:1 join below) may coverage read `"full"`; if a union member cannot be dispatched or its result is lost, that is a shortfall → `coverage: "not_verified"`, outcome 3.

**Absent comparand fails closed.** The loop's last-iter `phase3_dispatched` is a best-effort workpad field (see the schema note — it can be absent, `null`, or unparseable on an older/partial workpad). The tripwire reads that field, so define its missing-input behavior explicitly rather than letting it silently no-op (which would fail *open* — the shadow's own possibly-narrow roster would stand unchecked, re-opening the blind spot). When the last-iter `phase3_dispatched` is absent or unparseable, **treat it as a trip**: widen `expected_reviewers` *and* **actually dispatch** the **full gated roster** (both `type-design-analyzer` and `pr-test-analyzer` in addition to the four always-on), and record a `Devflow Reflection` note that the tripwire ran without a comparand. This is a deliberate, narrow exception to the `engine_self_modifying` "do not force the two analyzers into the expected roster" rule above: that rule's phantom-shortfall warning is about expecting an analyzer the Phase 3.1 gate then *refuses to dispatch* (so `reviewers_dispatched ⊉ expected_reviewers`). Here the trip overrides the structural-applicability gates to dispatch both analyzers, so expected and dispatched move together and no shortfall is manufactured — a structurally-inapplicable analyzer returns a clean "nothing to analyze" assessment (empty findings, but an assessment present), which satisfies the 1:1 join. The trip therefore over-widens coverage rather than under-reporting it — fail-closed.

**Union-widened late dispatches are full roster members.** An analyzer added by the tripwire (whether from a narrowing divergence or the absent-comparand trip) is dispatched after the shadow's initial fan-out, but it is a first-class member of the roster for every downstream rule: build its prompt with the **same blinding** as the rest of the shadow fan-out ("Blind every shadow reviewer prompt" above), subject it to the **same 1:1 join** and positive-evidence contract, and grant it the **same single bounded re-dispatch** eligibility on a transient failure (outcome 3's *Transient vs. structural* rule). It is not a second-class "extra" dispatch with weaker handling.

A missing **always-on** agent (or a missing gated analyzer whose gate is *true*) is a coverage shortfall → `coverage: "not_verified"`, outcome 3. A gated-*out* analyzer (its gate is false) is **not** a shortfall — it was correctly never expected (**except** when the too-narrow tripwire above has widened the expected roster to the union: an analyzer gated-out by the shadow's own profile but launched by the loop's last iter (present in its `phase3_dispatched`) *is* expected for that run, and its absence is a shortfall like any other). Set `coverage: "full"` only when `reviewers_dispatched` ⊇ the computed expected roster **and** every dispatched reviewer returned a result that positively shows it ran (the Phase-3 output contract: an assessment/verdict plus a `defect_signature` on every finding it raises, per /devflow:review's Phase 3.1). A structurally-valid but evidence-empty response — e.g. a reviewer that errored internally yet emitted `{findings: []}` with no assessment — counts as *did not return cleanly*, not as a clean reviewer.

**Dispatched is not collected — require a 1:1 join.** "Dispatched the expected roster" and "have every reviewer's result" are two different claims, and `coverage: "full"` requires *both*. After aggregation, perform an explicit **1:1 join** between every identifier in `reviewers_dispatched` and the aggregated results (Phase 3 findings + the per-reviewer assessment captured in "Parse and compare"): each dispatched identifier MUST map to exactly one collected, successfully-parsed result that meets the positive-evidence contract above. A reviewer that was dispatched but whose result was never collected, was lost, or failed to parse (a *dispatched-but-lost* result) is a coverage shortfall exactly like a never-dispatched one → `coverage: "not_verified"`, outcome 3, with `reason` naming the dispatched identifier whose result was lost. Do not let a launched-but-silent reviewer pass as covered merely because its identifier is in `reviewers_dispatched`.

**`superpowers:requesting-code-review` unavailable does NOT downgrade-and-proceed in shadow mode.** /devflow:review's Phase 3.1 says that if `/superpowers:requesting-code-review` is unavailable the orchestrator may "fall back to relying on the other Phase-3 reviewer agents" — that graceful degradation is correct for a *normal* review, but it is **overridden here**: `superpowers:requesting-code-review` is an always-on member of the shadow's expected roster, so its absence is a coverage shortfall like any other → `coverage: "not_verified"`, outcome 3. The shadow never declares full coverage on a three-of-four roster.

**Checklist skip is not a coverage shortfall, but `coverage: "full"` is about the reviewer roster, not the checklist.** If the shadow's own Phase 0.5 sets `checklist_skipped = "intentional"` (a `small_diff` + `config_only` diff), Phase 1+2 don't run and `shadow_phase2_fails` is empty *by design* — that is not a shortfall and does not block `coverage: "full"`. But record `checklist_skipped` on the shadow block so a reader doesn't read "full reviewer coverage" as "the checklist axis was re-audited" — an empty `shadow_phase2_fails` from an intentional skip is vacuous, not agreement.

**Checklist-skip narrowing tripwire (the checklist-axis analogue of the roster tripwire above).** Honoring an intentional skip is safe only when the diff genuinely *is* `small_diff` + `config_only`. A too-narrow self-misclassification that mis-sets `checklist_skipped = "intentional"` on a substantive diff would silently drop the Phase 1+2 checklist axis while the reviewer-roster join still reads `"full"` — the same false-clean shape the roster tripwire closes, one dimension over. The roster tripwire does **not** catch this (it compares gated *analyzers*, not `checklist_skipped`), so apply the parallel guard: before honoring the skip, consult the loop's **last-iter recorded** `diff_profile.checklist_skipped` *only as a one-way narrowing tripwire* (the shadow's own profile remains authoritative for everything else, exactly as with the roster — a genuine post-fix shrink to `config_only` is rare but real, so the loop's profile is a tripwire, not the source of truth). When the shadow's own profile **skips** the checklist (`checklist_skipped = "intentional"`), honor that skip **only** when the loop's last-iter `checklist_skipped` is *also exactly* `"intentional"` — i.e. the loop and the shadow independently judged this a legitimate `small_diff` + `config_only` skip. In **every other case** the narrowing is suspect — it cannot be told apart from a misclassification — so **trip**: do **not** honor the skip; **run the shadow's Phase 1+2** (overriding the `small_diff` + `config_only` bypass, the same way the roster trip overrides the analyzer gates; this trip's precondition cannot arise under `engine_self_modifying`, which already forces the full checklist on, so the shadow's own profile is never `checklist_skipped = "intentional"` there — no interaction to reconcile, unlike the roster trip's `engine_self_modifying` carve-out) so `shadow_phase2_fails` is a real re-audit rather than vacuously empty, and record a `Devflow Reflection` note that the checklist-skip tripwire fired. "Every other case" is exhaustive and fail-closed — it is **any** last-iter comparand that is not exactly `"intentional"`: (a) the loop's last iter **ran** the checklist (`checklist_skipped` is `null`) — the canonical narrowing; (b) the loop's last iter recorded a checklist-generation **`"failure"`** — a failed generation never audited the axis either, so honoring a skip on top of it would leave the checklist axis unaudited across the whole run; or (c) the comparand is **absent, unparseable, or its iter file cannot be read at all** (a best-effort field — matching the roster tripwire's absent-comparand rule). All of (a)–(c) trip and run Phase 1+2. A *widening* divergence (the loop skipped but the shadow runs the checklist) needs no tripwire — the shadow already audits more. (Note the cost of case (c): on a genuinely trivial `small_diff` + `config_only` diff whose last-iter workpad is simply missing — the common shape on a first iteration where no prior workpad exists — this forces a real Phase 1+2 re-audit anyway, and if that forced re-audit cannot complete it surfaces as a Phase-2 INCONCLUSIVE → REJECT → outcome-2 promotion, burning an iteration. This is the fail-*closed* direction and therefore acceptable, but it is a deliberate cost, not a free check — an absent comparand is treated as suspect rather than waved through.)

**Honest-degradation fail-safe.** If the parent cannot complete that full fan-out — the `Agent` tool is unavailable, /devflow:review's SKILL.md is unreadable, the shadow's own Phase 0.5 cannot classify the diff, a reviewer returned nothing/garbage/evidence-empty, or `reviewers_dispatched` falls short of the expected roster for any other reason — do **NOT** fall back to a single-agent pass and do **NOT** report a clean verdict from a partial pass. Record `coverage: "not_verified"` with a `reason` naming what was missing and take **outcome 3** below. (One bounded exception, defined under outcome 3's *Transient vs. structural* rule: a *single* dispatched reviewer that returned garbage/empty gets exactly **one** targeted re-dispatch before this fail-safe fires — structural failures, and any second or multi-reviewer failure, are immediate `not_verified` with no retry.) Coverage is **fail-closed**: any value other than a positively-verified `"full"` (including `null`, unset, or unrecognized) is treated as `"not_verified"` everywhere downstream. A degraded pass is never allowed to clear the PR.

#### Parse and compare

When the shadow fan-out completes, aggregate the engine's verdict and findings (same Phase 4 aggregation the loop already runs) into `shadow_verdict`, `shadow_phase3_findings`, and `shadow_phase2_fails`.

**Compare shadow's findings to the loop's last iter's findings** (the workpad's `iter-<N>.json` from the loop's most recent fix iteration — N is the iteration that produced the tentative final verdict, not counting the shadow itself):

A shadow finding is **new** iff no finding in the last iter's `phase3_findings` matches it under /devflow:review's Phase 3.2 `defect_signature` corroboration rule (same `file` + overlapping `line_range` + identical `kind`). See that section for the canonical definition — do not paraphrase it here.

Apply the same comparison to `shadow_phase2_fails` against the last iter's `checklist` (matching on `claim_signature` where available, else on `(source_file, claim text)`).

#### Decide

**Evaluate coverage first.** Before classifying findings, settle `coverage` per the positive-assertion rule above. If it is anything other than a verified `"full"`, the fan-out was incomplete and its findings are an untrustworthy "what's new" signal — take **outcome 3** regardless of what the partial pass produced (a partial pass that happens to catch one new finding does **not** route to outcome 2; incomplete coverage always wins). Only when `coverage` is `"full"` do outcomes 1 and 2 apply.

Three outcomes:

1. **The shadow ran with full reviewer coverage (`coverage: "full"`) AND its findings are a subset of (or equal to) the loop's last iter's findings AND `shadow_verdict` is non-REJECT** → genuine convergence. Record the shadow result in the workpad (see "Shadow workpad record" below) and proceed to **Loop Exit** with the tentative final verdict unchanged. (A clean subset is only convergence when the full fan-out actually ran — a partial pass takes outcome 3, never this one.)

   **Block-presence gate (fail-closed on persistence, not just on value).** This outcome keys off the *in-memory* `coverage` value, but the chat headline and Coverage render sites (Loop Exit) read the *persisted* shadow block and fail closed when it is absent. Mirror that here so the Decide path can't fire on a value that was never persisted: after appending the `shadow` block (see "Shadow workpad record"), **re-read it back from disk and confirm a present block with `coverage: "full"`** before committing to outcome 1. If the best-effort append failed and no block is present, **or** it reads back without `coverage: "full"`, **or the read-back itself cannot be performed or parsed** (Read error, unreadable file, unparseable JSON — the workpad is best-effort everywhere else, so a failed read-back is reachable), do **not** take outcome 1 — fall through to **outcome 3** (`not_verified`, `reason`: "shadow coverage could not be confirmed persisted"), exactly as the render sites would. **Downgrade the in-memory state too:** set the in-memory `coverage` to `"not_verified"` and `verdict` to `null` (the same downgrade outcome 3 records) before falling through, so any in-memory consumer downstream of Decide reads the failed-closed values rather than the stale pre-gate `"full"` / clean verdict — the persisted block alone failing closed is not enough if a later step reads the value from memory. Route straight to outcome 3's **terminal** `not_verified` state: a persistence/read-back failure is **not** a reviewer-return failure, so outcome 3's *Transient vs. structural* re-dispatch step does not apply here (there is no reviewer to re-dispatch — the fan-out already returned; only the confirmatory persist/read-back failed). Any result other than a positively-confirmed present `coverage: "full"` block fails closed. (The outcome-3 re-record is itself a best-effort append; if *it* is also lost, the block is simply absent, which the Loop Exit render sites already treat as not-verified — so the end state stays fail-closed without a re-read loop.) (Phrase the `reason` as a *persistence/read-back* failure, not a fan-out failure — the fan-out may have run cleanly; it was only the confirmatory persist/read-back that could not be verified. The Coverage section renders this `reason` verbatim, so a misleading "fan-out could not be completed" wording would misdescribe a clean run whose persist step hiccuped.) Outcome 1 requires both the in-memory verdict *and* a persisted full-coverage block. (This terminal fail-closed state is load-bearing on every Loop Exit render site treating an absent/non-`"full"` block as not-verified — see "Verdict → chat output" and the Coverage "Shadow agreement" section; a future render-site edit that fell *open* on a missing block would re-open the path this gate closes. Named here as a breadcrumb, matching the engine-mapping breadcrumb on the transient-retry rule.)

2. **Shadow surfaces any new Critical or Important Phase 3 finding, OR any new Phase 2 FAIL, OR `shadow_verdict` is REJECT** → the loop has not converged. **Promote the shadow's new findings into a new iteration:**
   - The promoted iter has its own iter number (N+1) and writes its own `iter-<N+1>.json` workpad at end-of-iter per the regular Persistent workpad → Lifecycle rule. Its `iter` field is N+1; it does NOT overload iter-N's workpad.
   - Step 0.9 (fix-delta handoff) runs for the promoted iter but **short-circuits**: stage only `prior_phase3_findings` (Step 2.5's classification needs it to evaluate shadow's findings against what's already been considered); skip the `fix_files` and `prior_checklist` computation — Phase 1+2 are skipped for promoted iters, so those staged values have no downstream consumer.
   - Treat the shadow's new findings as iter (N+1)'s Phase 3 findings (plus iter (N+1)'s Phase 2 FAILs for any new checklist FAILs from shadow).
   - Skip Phase 1+2 for this promoted iter — shadow already ran a full engine, so re-running Phase 1+2 would be redundant work. (This is the one place in the loop where Phase 1+2 is skipped on iter ≥2; it's safe because the inputs *are* a Phase 1+2+3 result.)
   - Go straight to **Step 2.5** (pre-fix verification gate) → **Step 3** (fix findings) for the promoted iter. The regular loop continues from there: Step 4 → Step 4.5 → Step 1 of iter (N+2) if needed.
   - **Iteration cap still applies** (see "Iteration accounting" above — promoted iter counts toward the `$MAX_ITERS` cap). If the final iter (iter `$MAX_ITERS`) has already run and shadow still surfaces new findings, do NOT start a further iteration. Exit to Loop Exit with:
     - Final verdict `REJECT` if any of shadow's new findings is Critical.
     - Final verdict `APPROVE WITH UNRESOLVED SHADOW FINDINGS` otherwise (Important-only).
     - Include the unresolved shadow findings verbatim in the chat output and in the report's `## Unresolved Shadow Findings` section.
   - **Caller contract — do not silently hand-fix this verdict.** `APPROVE WITH UNRESOLVED SHADOW FINDINGS` is terminal *for the loop*: it is at the iteration cap and will not re-review itself, and these findings reach the caller only via the chat output and the `## Unresolved Shadow Findings` report section — they do **not** flow through the Step-3 deferrals manifest (that channel carries only `skip_category` Yes-downgrade skips, not shadow findings). A wrapping orchestrator (e.g. /devflow:implement Phase 3.3) that elects to *fix* these findings must re-establish independent coverage over the fix delta — re-invoking this skill for one more bounded pass — and may **not** resolve them with an unreviewed final commit; an orchestrator hand-fix that ships without re-review is exactly the unreviewed-final-edit gap this contract closes. The loop itself never hand-fixes a capped verdict.
   - **Persistence note (asymmetry with outcome 1 is intentional).** Unlike outcome 1, the promotion decision keys off the in-memory *findings*, not the persisted `coverage` value, so it needs no read-back gate to act: a lost full-coverage append does not make the loop wrongly *clear* a PR (the failure-closed direction) — it only risks under-reporting coverage at Loop Exit. When this run later ends on `APPROVE WITH UNRESOLVED SHADOW FINDINGS`, the full-coverage block lives one iter back (on iter N, written by the same best-effort append); if that append was lost, the Loop Exit render-time assertion for that verdict falls back to the not-verified rendering (see "Verdict → chat output"), so a lost write still never produces a coverage claim the persisted record can't back.

3. **The shadow could not run the full multi-agent fan-out, OR a reviewer returned a malformed/empty response, OR the fan-out otherwise errored** → shadow agreement is *not verified* (but for a *single* malformed/empty reviewer, first apply the *Transient vs. structural* re-dispatch rule below — outcome 3 is only final after that one bounded retry). Record `coverage: "not_verified"`, **null `verdict`** (see "Shadow workpad record" — outcome 3 nulls `verdict` so no consumer can read a stale clean-looking value), and the reason in the workpad, note it in chat (`Shadow review pass not verified: {reason}. Proceeding to Loop Exit with the loop's tentative verdict — shadow agreement not verified.`), and proceed to Loop Exit. **Never** downgrade to a single-agent pass and report a clean verdict from it: a not-verified shadow leaves the loop's tentative verdict standing but is reported as unverified, never as agreement.

   **Transient vs. structural before declaring not-verified.** Distinguish the *kind* of failure before recording outcome 3:
   - **Structural** failures — the `Agent` tool is unavailable, /devflow:review's SKILL.md is unreadable, or the shadow's own Phase 0.5 cannot classify the diff — are **immediate** `not_verified`. They will not recover on retry (the fan-out as a whole cannot run), so do **not** retry; record outcome 3 now.
   - **Transient** failures — a *single* dispatched reviewer returned garbage / empty / evidence-empty / failed to parse while the rest of the roster returned cleanly — get **exactly one targeted re-dispatch** of just that reviewer (same blinded prompt). If the re-dispatch returns a clean result, **fold it into `shadow_phase3_findings` and re-run the "Parse and compare" step** (so a new finding the recovered reviewer raises still enters the new-vs-overlap comparison), then complete the 1:1 join and proceed normally (outcome 1 or 2). **Join bookkeeping:** the re-dispatch *replaces* the failed attempt's join obligation for that identifier — the reviewer appears **once** in `reviewers_dispatched` and the join is evaluated against the recovered result only, so a successful retry is neither double-counted (failed attempt + retry) nor torn (findings folded in but the identifier still marked lost). If it fails again — **or does not return at all** (the retry hangs or errors; decide "did not return" by the same agent-dispatch completion/failure signal the harness surfaces for any Phase-3 dispatch, not by waiting indefinitely) — record `not_verified` / outcome 3 with the reviewer named in `reason`. Re-dispatch at most one reviewer once — **the single-retry budget is global to the entire shadow pass** (the initial fan-out plus any tripwire-widened late dispatches, combined; the "same single bounded re-dispatch eligibility" granted to union-widened late dispatches above draws from this *same* budget, not a fresh one). A second transient failure anywhere in the pass, or more than one failed reviewer, collapses to `not_verified` immediately (treat a multi-reviewer failure as structural). This budget is **single-context in-memory state** held by the parent orchestrator for the duration of the one shadow pass; it is deliberately not persisted to the workpad and is never reconstructed from disk, so there is no path on which a budget already spent earlier in the pass is re-granted to a later (e.g. tripwire-widened) dispatch — the parent that spends it is the same parent that gates the later dispatch. **This budget governs Phase-3 *reviewer* re-dispatches only.** The Phase 1+2 work that the checklist-skip tripwire forces to run is engine Phase-1/Phase-2 dispatch, handled by /devflow:review's own phase logic — a transiently-failed Phase-2 verifier there neither draws from nor replenishes this reviewer-retry budget. A forced checklist re-audit that cannot complete fails closed on its own engine-phase terms: it surfaces as a Phase-2 INCONCLUSIVE (not a spent reviewer retry), and a Phase-2 INCONCLUSIVE drives `shadow_verdict` to REJECT per /devflow:review's Phase 4.2 verdict mapping (any INCONCLUSIVE → REJECT), which Decide **outcome 2** promotes on (`shadow_verdict is REJECT` → new iteration). So a degraded forced re-audit cannot read clean — the fail-closed property is *load-bearing on that engine-mapping → outcome-2 chain*, named here so a future edit to either side does not silently re-open the false-clean path.

   Do not block the loop on a shadow failure beyond this single bounded re-dispatch.

#### Shadow workpad record

After Step 2.6 completes (regardless of outcome), append a `shadow` block to the last iter's workpad file (`iter-<N>.json`):

```json
"shadow": {
  "ran_at": "2026-05-17T12:34:00Z",
  "verdict": "APPROVE",                                  /* the in-memory shadow_verdict; null on a not_verified (outcome 3) block */
  "coverage": "full",
  /* this example depicts a diff where neither structural gate fired (has_new_types false, no test-relevant change), hence the four always-on agents only — it is NOT the same scenario as the iter-workpad example above, whose has_new_types:true adds type-design-analyzer; the two need not match */
  "reviewers_dispatched": ["pr-review-toolkit:code-reviewer", "pr-review-toolkit:silent-failure-hunter", "pr-review-toolkit:comment-analyzer", "superpowers:requesting-code-review"],
  "expected_reviewers": ["pr-review-toolkit:code-reviewer", "pr-review-toolkit:silent-failure-hunter", "pr-review-toolkit:comment-analyzer", "superpowers:requesting-code-review"],
  "reason": null,
  "checklist_skipped": null,
  "phase3_findings": [/* the parsed array — persists the in-memory shadow_phase3_findings */],
  "phase2_fails": [/* the parsed array — persists the in-memory shadow_phase2_fails */],
  "comparison": {
    "shadow_total": X,
    "overlap_with_iter_N": Y,
    "new": Z,
    "new_critical": Z_crit,
    "new_important": Z_imp
  },
  "promoted_to_iter_next": true | false
}
```

`coverage` is `"full"` only when `reviewers_dispatched` covered `expected_reviewers` and every reviewer returned cleanly (outcome 1 or 2); otherwise it is `"not_verified"` (outcome 3), with `reviewers_dispatched` left as the partial roster (or `[]`) and `reason` naming what was missing. `expected_reviewers` is the mechanically-computed roster (four always-on agents plus any gated analyzer whose Phase 3.1 gate is true against `diff_profile` — **plus any analyzer the too-narrow tripwire added by widening to the union with the loop's last-iter dispatched roster (`phase3_dispatched`)**, so a tripwire-widened block validates against its own definition) so a reader can see *why* a shortfall was a shortfall. The Coverage section in the final report (Loop Exit) reads this block; because Loop Exit reads it back from disk, `reason` must be persisted here, not only rendered in chat.

**Field-name mapping (persisted ⇄ in-memory).** The "Parse and compare" step works in memory with the `shadow_`-prefixed names; this block persists them under unprefixed keys. The mapping is exact and load-bearing — a consumer reading the block back must not expect the in-memory names: persisted **`verdict`** is the in-memory `shadow_verdict`, persisted **`phase3_findings`** is `shadow_phase3_findings`, and persisted **`phase2_fails`** is `shadow_phase2_fails`. (The drift between `phase2_fails` here and `shadow_phase2_fails` above is intentional naming, not two different fields.)

**On a `not_verified` block, `verdict` is nulled, not merely non-authoritative.** PR #58 established that `verdict` is non-authoritative on a not-verified block; this goes further — **outcome 3 sets `verdict: null`** (see outcome 3 in "Decide"), so the shadow cannot leave a clean-looking value (e.g. an `"APPROVE"` produced before the coverage shortfall was detected) for any consumer to read at all. Coverage remains the authoritative signal; no consumer may read `verdict` without first gating on `coverage == "full"`, and on a not-verified block there is nothing to read because `verdict` is `null`. The same gate-on-`coverage` discipline applies to the block's `comparison` counts (`shadow_total` / `overlap_with_iter_N` / `new` / `new_critical` / `new_important`): on a `not_verified` block they may hold stale partials computed before the shortfall was detected, so no consumer reads them without first confirming `coverage == "full"` (the Coverage section's full-coverage branch, which renders `X`/`Y`/`Z` from `comparison`, is already gated this way).

#### Cost note

The shadow pass roughly doubles the cost of a converging run — one full engine pass that doesn't lead to fixes when it agrees. (This is why the `step_2_6` telemetry example carries a full-engine-pass magnitude — tens of agent calls and ~a Phase-1+1.5+2+3's worth of tokens — not the single call the old single-subagent design logged; `step_2_6` now aggregates the whole Phases 0–4.3 fan-out the parent runs.) This is intentional:

1. It matches what experienced users already do manually (`/devflow:review` after `/devflow:review-and-fix`); net cost is zero in their workflow and shadow agreement is now mechanical rather than a separate session.
2. It addresses the empirically-observed "review finds things review-and-fix missed" pattern — the entire reason this step exists.
3. The independence guarantee (each reviewer agent runs in a fresh context with the loop's prior findings withheld from its prompt) is what makes shadow a credible audit rather than a self-check that re-derives the same answer. The parent runs the fan-out so the full reviewer set actually launches; blinding lives in the prompts, not in a subagent context that could not have dispatched the fan-out in the first place.

### Step 3: Fix Findings

Apply the `superpowers:receiving-code-review` principles. After Step 2.5, the findings reaching Step 3 are: Phase 2 checklist FAILs, corroborated Phase 3 findings, confirmed-by-web findings, and codebase-claim findings. Refuted and inconclusive findings have been demoted to advisory and are not in this list; they stay parked.

1. **Read all findings** without reacting. Understand the full picture before fixing anything.

2. **Evaluate each finding technically:**
   - For verification checklist FAILs: Read the evidence. Verify it yourself by reading the source file cited. If the evidence is correct, fix the code. If the evidence is wrong (the verifier misread the source), skip the fix and document why.
   - For Critical/Important findings from review agents: Read the finding. Check if it's valid for this codebase. If valid, fix it. If not, skip and document why. (Note: external-tool claims that survived Step 2.5 are already either web-confirmed or corroborated by ≥2 agents — be slow to dismiss them as invalid.)
   - For Suggestion/Minor findings: Fix only if trivial and clearly correct. Do not spend time on cosmetic issues.

3. **Fix one issue at a time — then fix its whole class, not just the reported instance.** After each fix, verify the surrounding code still makes sense. Then generalize the finding to its `defect_signature.kind` and scan the **changed surface** (the files/hunks in this PR's diff, plus any file your fix just touched) for other instances of the same class; fix every sibling in this **same** iteration, applying item 2's severity triage to each. A reviewer reports the one instance it happened to land on, but a bug class usually recurs across the diff (e.g. one unchecked-type jq op flagged → sweep the program for every unguarded `startswith`/index/`// ""`-on-maybe-non-string op). Catching siblings here, deterministically, is far cheaper than letting the next Step 2.6 shadow rediscover them one at a time — each shadow that promotes a missed sibling costs a full extra engine pass plus a promoted fix iteration (see the Cost note under Step 2.6). **Bound the sweep to the PR's own changed surface — never to pre-existing untouched code** (that is what the `out-of-scope` skip and the Loop Exit widens-surface guard are for); a sibling you deliberately choose not to fix is recorded through the same pushback flow as any skip (item 5).

4. **Run tests** after all fixes. Check CLAUDE.md, README, or project configuration for the project's test and lint commands. If tests fail, fix the test failures before continuing.

5. **Track pushbacks.** For each finding you skipped (whether checklist FAIL or Phase 3 finding), record a structured entry: `{source_file, claim_text, skip_category, evidence}`. `skip_category` MUST be one of the values defined in the **`skip_category` enum (authoritative)** block below — this is the single source of truth for the enum, referenced by both this step and the Loop Exit Pre-mapping gate. Adding a new category requires editing only this block; both consumers read from it.

   #### `skip_category` enum (authoritative)

   | Value | Meaning | Required `evidence` | Pre-mapping gate: qualifies for REJECT downgrade? |
   | --- | --- | --- | --- |
   | `claim-quality` | Verifier evidence is correct in form but the underlying code is fine (e.g. the verifier oversimplified a branch the code handles correctly). | Cite the source span proving the code is correct. | **Yes** |
   | `out-of-scope` | The flagged lines are pre-existing code unmodified by this PR's diff, or belong to a separate concern from what this PR is doing. | Cite `git blame` / `git log -S` or the diff to prove the lines are not in this PR. | **Yes** |
   | `already-tracked` | A separate issue or PR addresses the underlying defect. | Cite the issue/PR number. | **Yes** |
   | `uncategorized` | None of the above fit cleanly. Use for "polish," "defer," "minor," "low priority," or any real-but-unfixed defect. | Free text describing why it wasn't fixed in-loop. | **No** — keeps the REJECT. The three named categories describe false-positive REJECTs; `uncategorized` describes a real defect that was simply not fixed. |
   | `advisory-parked` | Written by Step 2.5 at demotion time (not by this step). Marks a finding that web-verification refuted or could not confirm. | Demotion reason (e.g. `refuted by {url}`, `inconclusive after web verification`, `over verification budget`). | **N/A** — advisory findings are not REJECT triggers; they cannot reach the gate as triggers in the first place. |

   **Drift rule.** If a future edit adds a sixth value, add a row above AND verify the Pre-mapping gate's reference to this table still makes sense — the gate uses the "qualifies for downgrade?" column verbatim and assumes nothing else.

   A skip recorded with `skip_category` set to a value not in this enum (typo, missing field, etc.) is treated as missing-category and the gate keeps the REJECT.

   If the same `(source_file, claim_text)` pair was also skipped in the previous iteration, escalate to the user: "Finding persists after pushback: {claim}. Manual review needed." and stop the loop.

6. **Commit fixes** before re-running the review:
   ```bash
   git add -A && git commit -m "fix: address review findings (iteration {N})"
   ```
   Capture the resulting SHA (`git rev-parse HEAD`) and write it to the iter-N workpad as `fix_commit_sha` — Step 0.9 of iter-(N+1) reads it.

   **If `--push-each-iteration` is set**, push immediately after the commit so the remote PR branch (and its CI) tracks this iteration:
   ```bash
   git push
   ```
   If the push fails (no upstream, rejected non-fast-forward, blocked by policy), do **not** abort the loop — report the failure in chat and continue. Pushing propagates fixes to the remote (CI, crash-durability); it is not what makes the next iteration see them (Step 1's head-override handles that), so a failed push never breaks convergence. When the flag is absent (the default), skip the push entirely.

7. **Persist the workpad.** Before looping, write `iter-<N>.json` with: fix_commit_sha, fix_files (`git diff --name-only HEAD~1 HEAD`), the iter-N `checklist` array — **mandatory whenever Phase 1+2 ran this iteration** (i.e. `checklist_skipped` is `null`): one entry per checklist item carrying its `verification_mode` (`lite` or `agent`, per /devflow:review's Phase 2 lite/agent partition), `verdict`, `claim_signature`, and `reused_from_iter_prev: true|false` (whether Phase 2.0.5's narrow-reuse path was taken). Persisting `checklist[]` is what lets `efficiency-trace.jq` derive the real lite/agent split and a `verification_posture` other than `none-recorded`; omitting it on a run where Phase 1+2 ran is a telemetry regression, not a best-effort skip. (When Phase 1+2 were genuinely skipped — `checklist_skipped` is `"intentional"` or `"failure"` — `checklist` is `[]` and the posture reflects the skip.) Continue with `phase3_dispatched` (the array of Phase-3 agent identifiers actually launched this iteration after Phase 0.5 gating — see the workpad schema note above for why this roster is load-bearing for the Loop Exit effectiveness trace), `diff_profile` (the engine's Phase 0.5 flags + `checklist_skipped` for this iteration — see the schema note; carried into the record so cross-run analysis can segment by diff shape and the trace can report verification posture), Phase 3 findings (each with `defect_signature`, `step25_classification`, and the matching `fix_decision` so iter-(N+1)'s Phase 3 handoff has the full record), `fix_decisions` (one entry per finding using the shape shown in the workpad schema example: `applied` entries carry `{finding_id, decision, commit}`; `pushed_back` / `deferred` entries carry the structured pushback fields `{source_file, claim_text, skip_category, evidence}` from Step 3 item 5 where `skip_category` is one of the values in the `skip_category` enum (authoritative) table; `advisory` entries — written by Step 2.5 at demotion time, not here — carry `skip_category: "advisory-parked"` plus the demotion `evidence`), convergence_inputs, `cap_drops` (from /devflow:review's Phase 1.1.5 output — see that skill for the shape), and the `telemetry` block — **mandatory**: populate per-phase `calls` / `tokens` / `wall_clock_s` for the phases that ran this iteration (capture rules in Loop Exit's "Run telemetry summary"). Per-phase `tokens` is best-effort *per source* — a missing `<usage>` block for one agent is skipped, but the `telemetry` block as a whole must still be written; the failure mode to eliminate is the block being wholesale absent (which forces `efficiency-trace.jq` to carry `telemetry[].phases` through as `null`), not one missing token. The `shadow` block, if any, is appended later by Step 2.6 and is not populated here.

### Step 4: Continue Loop

Output: `Fixed {N} issues, skipped {M}. Re-running review...`

### Step 4.5: Convergence check (skip when about to start iteration 2)

Before looping back to Step 1, evaluate whether iter N+1 is likely to be a no-op. If it is, exit the loop early with iter N's current state. Convergence check is inactive on the iter-1 → iter-2 transition (no previous iteration to compare against). Starting at the iter-2 → iter-3 decision, check all three:

1. **Few fixes.** Iter N applied fewer than 3 fixes in Step 3 (counting one fix per finding addressed).
2. **Small fix-diff.** The diff produced by this iteration's fix commits is fewer than 30 changed lines. (`git diff HEAD~{commits_this_iter}..HEAD --shortstat`)
3. **No new findings.** No new corroborated/confirmed Critical or Important finding emerged in iter N's Phase 3 vs iter N-1's Phase 3. (Advisory findings carried over from Step 2.5 don't count as new.)

If all three hold → **exit the loop early.** The remaining unresolved findings (skipped via pushback in Step 3, or advisory from Step 2.5) are the *final* output of the run; iterating further wouldn't change them. Use iter N's current verdict as the tentative final verdict and proceed to **Step 2.6: Shadow review** before Loop Exit (the shadow pass still runs on early-exit convergence — it's the "loop is stuck" detector confirming the stop is genuine). Output: `Converged after iteration N — fewer than 3 small fixes applied and no new findings; running shadow review before final verdict.`

If any condition fails → loop back to Step 1 for iter N+1.

Note: convergence is *not* a way around an unresolved REJECT. If iter N's verdict is REJECT due to stuck/pushed-back findings, the shadow pass and Loop Exit's verdict flow still fire (a REJECT-on-convergence-exit goes straight to Loop Exit; Step 2.6 only runs when the tentative verdict is non-REJECT). Early exit just means "iterating won't help" — the human gate still applies.

---

## Loop Exit

### Pre-mapping: Widens-surface guard + deferrals manifest

Run this step BEFORE the REJECT downgrade gate below. It does two things: enforces a widens-surface guard on Yes-downgrade skips, and emits a structured manifest that downstream callers (currently /devflow:implement Phase 4.0.5) can consume to file follow-up issues and inject the Scope-Acknowledged Findings block into the PR body.

**Widens-surface guard.** Walk every `fix_decisions` entry in the final iter's workpad whose `skip_category` reads **Yes** in the enum table (Step 3, item 5 — currently `claim-quality`, `out-of-scope`, `already-tracked`). For each candidate, join to its Phase 3 finding via `finding_id` to obtain `defect_signature.file` and `defect_signature.line_range`, then read the cached diff (`.devflow/tmp/review/<slug>/<run-id>/diff.patch`) and check whether any non-comment hunk in the diff overlaps that file within ±10 lines of the line range. If overlap is detected, the skip is **disqualified for the downgrade gate** — append a bullet to the workpad's `Devflow Reflection` (`widens-surface guard rejected skip for finding {finding_id}: PR diff overlaps {file}:{lines}`) and treat the finding as a non-skipped REJECT trigger for the gate that runs next. This catches the "refactor around a pre-existing bug, then defer the bug" pattern: the bug's lines weren't touched in isolation, but the surrounding code changed in a way that widens reliance on the broken behavior.

**Deferrals manifest.** After the guard runs, emit `.devflow/tmp/review/<slug>/<run-id>/deferrals.json` (run-scoped, alongside this run's `iter-*.json`) containing every **surviving** Yes-downgrade skip (i.e. `claim-quality` / `out-of-scope` / `already-tracked` entries that the widens-surface guard did not disqualify). The manifest is written regardless of whether the downgrade gate ultimately fires; `claim-quality` and `already-tracked` skips on non-REJECT runs are still legitimate deferrals worth tracking for the verdict matcher. If zero entries survive, omit the file entirely.

Schema:

```json
{
  "schema_version": 1,
  "pr_branch": "<current branch>",
  "base_branch": "<base_branch from .devflow/config.json; if absent, the repo default branch via `gh repo view --json defaultBranchRef -q .defaultBranchRef.name`, falling back to `main`>",
  "generated_at": "<ISO 8601 UTC>",
  "deferrals": [
    {
      "agent": "<from phase3_findings.agent>",
      "severity": "<Critical | Important | Suggestion>",
      "file": "<from defect_signature.file>",
      "line_range": [<start>, <end>],
      "symbol": "<best-effort, see below>",
      "kind": "<from defect_signature.kind>",
      "summary": "<verbatim from phase3_findings.description>",
      "category": "<one of: out-of-scope, already-tracked, claim-quality>",
      "explanation": "<verbatim from fix_decisions.evidence>"
    }
  ]
}
```

`symbol` is best-effort: scan the finding's `description` for the first backtick-quoted identifier; if none, leave empty string. Downstream matchers (the /devflow:review verdict engine) fall back to `line_range` + summary similarity when `symbol` is absent.

This step writes the artifact and applies the guard. It does **NOT** file follow-up issues, mutate the PR body, or touch GitHub — those are /devflow:implement Phase 4.0.5's responsibility. /devflow:review-and-fix is silent on GitHub by design and stays so. When the caller is standalone /devflow:review-and-fix (no orchestrator wrapping it), the manifest is still written but no consumer reads it — that's fine; it's informational state on disk and useful for debugging.

### Pre-mapping: Step-3-evaluated REJECT downgrade

If the engine's final verdict is **REJECT** AND **every** REJECT trigger (checklist FAILs and Critical Phase 3 findings) was Step-3-skipped with a `skip_category` whose "qualifies for REJECT downgrade?" column in the `skip_category` enum (authoritative) table (Step 3, item 5) reads **Yes** AND survived the widens-surface guard above, **downgrade the final verdict to `APPROVE WITH CAVEAT`** and surface each trigger in the report's `## Downgraded Findings` section with its category label and evidence.

The gate consults that table directly — it does not maintain its own list. If a future edit adds a sixth `skip_category`, mark its downgrade-eligibility in the table row and the gate picks it up automatically. **One trigger whose category reads "No" (or "N/A", or whose category isn't in the table at all) keeps the REJECT.** Similarly, any REJECT trigger that was NOT skipped at all (i.e. the orchestrator addressed it in Step 3 but the post-fix engine re-run still rejects) keeps the REJECT; the downgrade gate is for false-positive REJECTs, not for unfinished work. A trigger whose skip was disqualified by the widens-surface guard above keeps the REJECT for the same reason — the guard found that this PR widens reliance on the deferred bug, so the bug is no longer "pre-existing and unrelated" for review purposes.

### Verdict → chat output

The fix loop is silent on GitHub by design — it does NOT post a `gh pr review` or `gh pr comment` for any verdict. The final report (including any `## Advisory Findings`, `## Coverage`, and `## Unresolved Shadow Findings` sections) is emitted to chat only. A human who wants a formal `--request-changes` / `--approve` / `--comment` review on the PR runs `/devflow:review <PR>` separately; that skill performs an independent re-review and posts the result via its own Phase 4.4.

Map the final verdict to the chat line that precedes the full report:

In all three APPROVE-family lines below (APPROVE, APPROVE WITH ADVISORY NOTES, APPROVE WITH CAVEAT), `{shadow status}` states the shadow's coverage explicitly so the chat line never overclaims an audit that didn't fully run. Read it from the **most recent iteration that has a `shadow` block** (normally the final iter; but an `APPROVE WITH UNRESOLVED SHADOW FINDINGS` run ends on a *promoted* iter that has no shadow block of its own — its full-coverage shadow lives one iter back, on the iter that triggered the promotion). Render `shadow agreed, full coverage` when that block's `coverage` is `"full"`, or `shadow agreement not verified` when `coverage` is anything else (fail-closed — `"not_verified"`, `null`, or unset all render as not-verified). **Block presence is fail-closed too:** if the final verdict is non-REJECT but *no iteration* has a `shadow` block at all — the Step 2.6 append is best-effort and can fail (see Persistent workpad → Lifecycle), so this is reachable, e.g. an outcome-3 record lost to a write error — treat it exactly as not-verified: render `shadow agreement not verified` and drop the absolute clause. Only a *present* block with `coverage: "full"` may render `shadow agreed, full coverage`; never let a missing block fall through to a clean "shadow agreed" / "All checks approved". These three `{shadow status}` lines are selected by the **verdict string**, and the verdicts that select them (APPROVE / APPROVE WITH ADVISORY NOTES / APPROVE WITH CAVEAT) only arise from outcome 1 (full coverage, shadow agreed) or outcome 3 (not verified) — so for *these* lines `coverage` cleanly disambiguates. `APPROVE WITH UNRESOLVED SHADOW FINDINGS` is the separate outcome-2-at-iteration-cap verdict; it *normally* carries `coverage: "full"` (the shadow ran fully and *disagreed*), uses its own dedicated line below, and must **not** be routed through the `{shadow status}` template — never render "shadow agreed" for it. ("Normally" because the one-iter-back full-coverage block it reads was written by a best-effort append that can be lost; that line's own render-time assertion falls back to a not-verified rendering in that case — see its bullet below.) When `{shadow status}` is the not-verified string, **drop the trailing `All checks approved.` / `with caveats.` absolute clause** — replace it with `See report.` so the headline doesn't overclaim relative to its own parenthetical.

- **APPROVE**: `Review passed after {N} iteration(s) ({shadow status}). All checks approved.` (→ `… ({shadow status}). See report.` when not-verified)
- **APPROVE WITH ADVISORY NOTES**: `Review passed after {N} iteration(s) ({shadow status}) with {M} advisory finding(s) parked for human review. See report.`
- **APPROVE WITH CAVEAT** (engine verdict APPROVE WITH CAVEAT / APPROVE with notes, or the Step-3-evaluated REJECT downgrade fired): `Review passed after {N} iteration(s) ({shadow status}) with caveats. See report.`
- **APPROVE WITH UNRESOLVED SHADOW FINDINGS** (iter cap hit while shadow still surfaced new Important findings — see Step 2.6): `Review converged after {N} iteration(s) but a final shadow pass surfaced {K} new Important finding(s) that the loop could not address within the iteration cap. See report.`
  - **Render-time coverage assertion (this line is exempt from `{shadow status}`, so assert explicitly here).** This verdict is *not* routed through the `{shadow status}` template above, so it never runs that template's render-time `coverage == "full"` check — yet it depends on a `coverage: "full"` shadow block that lives **one iter back** (the promotion-triggering iter, since the promoted final iter has no shadow block of its own) and was written by the same best-effort append that can fail. Before rendering this line, **read that one-iter-back block and assert it is present with `coverage: "full"`**. If it is present and full, render this line. If the block is absent or reads back as anything other than `"full"` (the best-effort write was lost, or coverage was never verified), the run cannot honestly claim "a final shadow pass surfaced K findings" — **fall back to the not-verified rendering**: emit `Review converged after {N} iteration(s); {K} unresolved Important finding(s) remain, but shadow coverage for that pass was not verified (shadow block missing or not full). See report.` so the headline never asserts a shadow result the persisted record can't back.
- **REJECT** (max iterations reached or convergence exit with the iteration's verdict still REJECT *and* the downgrade did not apply, OR shadow surfaced a new Critical at the iter cap): `Review still has findings after {N} iteration(s). Remaining issues require manual review:` followed by the list of unresolved findings. Then append the formal-merge-signal hint, conditional on mode:
  - **PR mode** (`$ARGUMENTS` is a PR number): `To post this verdict as a formal merge signal (e.g. a blocking --request-changes review), run \`/devflow:review {PR_NUMBER}\` — it performs an independent re-review and posts the result.`
  - **Current-branch mode** (no PR yet): `To post this verdict as a formal merge signal once a PR exists, push the branch and open a PR, then run \`/devflow:review <PR>\` — it performs an independent re-review and posts the result.`

### Coverage

Inject a `## Coverage` section into the final report, positioned between the engine report's `## Code Review Findings` and `## Verdict Criteria` sections (those headings come from /devflow:review's Phase 4.1 template). The section reports run-level coverage so the human reader can see how exhaustive the engine was and where it cut corners.

Compute by reading every `iter-<K>.json` workpad (plus the appended `shadow` block, if any) and rendering:

```markdown
## Coverage

### Per-iteration finding counts

| Iter | Phase 3 findings | Critical | Important | Suggestion | Phase 2 FAILs | Phase 2 INCONCLUSIVE |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 7 | 1 | 3 | 3 | 2 | 0 |
| 2 | 4 | 0 | 2 | 2 | 0 | 1 |
| ... | | | | | | |

### Shadow agreement

**Select the block to read by verdict, and fix branch precedence — both matter here.** For `APPROVE WITH UNRESOLVED SHADOW FINDINGS`, pin to *that specific* promotion-triggering iter one back (the promoted final iter has no shadow block of its own) and read **only** that block — do **not** fall back to an earlier iter's `shadow` block if the one-iter-back block was lost to a best-effort write, or this section would read an unrelated earlier full-coverage block and render "full reviewer coverage" while the chat headline (which pins to the same one-iter-back block — see "Verdict → chat output") correctly renders not-verified, an internal report/headline contradiction that over-claims. For every other non-REJECT verdict, read the **most recent iteration that has a `shadow` block** (normally the final iter). **Branch precedence:** for `APPROVE WITH UNRESOLVED SHADOW FINDINGS` specifically, evaluate the *lost-write* branch below (one-iter-back block absent, or present but not `coverage: "full"`) **before** the `coverage: "full"` branch, and render the `coverage: "full"` branch only when that pinned block is present *and* full — so the two not-verified branches that can both match an AWUSF lost-write (this one and the generic "no shadow block at all" branch) resolve deterministically to the AWUSF-specific sentence. **Also scan every iter's `shadow` block:** if any shadow on an iteration **strictly before the block this section pinned to read** ran `coverage: "not_verified"` (even when the most recent one is `"full"`), append a line — `Note: an earlier shadow pass (iter K) was not verified ({reason}); only the later pass achieved full coverage.` — so the audit chain's gaps aren't hidden behind the last clean pass. **Exclude the pinned block itself from this scan** — for an AWUSF lost-write the one-iter-back pinned block is *itself* the not-verified block this section already renders via the AWUSF lost-write branch, so re-reporting it here as "an earlier not-verified pass" would describe the same lost block twice under two framings.

{If `coverage` is `"full"`: "Shadow ran with full reviewer coverage ({reviewers_dispatched roster}). It raised X findings; Y were already in iter N (overlap = Y/X); Z were new (Z_crit Critical, Z_imp Important)." then — If Z == 0: "Genuine convergence — shadow agreed with the loop." / If Z > 0 (reachable only at the iteration cap, where outcome 2 could not promote): "The final shadow surfaced Z new finding(s) the loop could not address within the iteration cap — see the `## Unresolved Shadow Findings` section; the verdict reflects that (APPROVE WITH UNRESOLVED SHADOW FINDINGS, or REJECT if any was Critical)." (Below the cap, an outcome-2 shadow promotes into iter N+1 and is therefore *not* the final block this section reads — its Z>0 shows in the per-iteration finding-counts table above, not here.)} {If `coverage` is `"not_verified"`: "Shadow agreement NOT verified — {reason}; the loop's tentative verdict stands but was not independently audited." The prefix is **reason-agnostic** (do *not* hardcode "the full multi-agent fan-out could not be completed") because `reason` carries the specific cause verbatim — and that cause is not always a fan-out failure: the outcome-1 block-presence gate records `reason: "shadow coverage could not be confirmed persisted"` for a clean run whose persist/read-back hiccuped, and a transient single-reviewer failure records the reviewer name; a hardcoded fan-out prefix would misdescribe both. **`{reason}` fallback:** if `reason` is empty, `null`, or absent (a partial write can leave `coverage` set but `reason` empty), substitute the cause-neutral literal `shadow coverage was not verified (specific reason not recorded)` so the line still reads as a complete sentence with no empty parenthetical — **cause-neutral on purpose**, since the lost `reason` may have been a persist/read-back failure (a clean run), not a fan-out failure, and a hardcoded "fan-out could not be completed" fallback would re-introduce exactly the misdescription this branch's reason-agnostic prefix was changed to avoid.} {If the verdict is non-REJECT but **no iteration has a `shadow` block** (the best-effort Step 2.6 append may have failed): "Shadow agreement NOT verified — the shadow result was not recorded (workpad write may have failed); the loop's tentative verdict stands but was not independently audited."} {**If the verdict is `APPROVE WITH UNRESOLVED SHADOW FINDINGS` but the one-iter-back shadow block (the promotion-triggering iter's block) is absent or reads back as anything other than `coverage: "full"`** — the same lost-write case the chat headline's render-time assertion guards (see "Verdict → chat output"): "Shadow coverage for the final pass NOT verified — the unresolved-findings verdict stands, but the full-coverage shadow block that surfaced them was not recorded (workpad write may have failed); the surfaced findings were not independently corroborated." Render this **instead of** the `coverage: "full"` branch for that verdict, so the Coverage section never asserts full coverage the persisted record can't back — matching the headline fallback.} {If shadow did not run at all because the verdict was REJECT (REJECT skips Step 2.6): "Shadow pass did not run — final verdict was REJECT before convergence."}

### Phase 1.1.5 cap drops

Phase 1.1.5 dropped M items at the 100-item cap (categories: dependency_interaction: K1, api_contract: K2, ...). {Omit this subsection entirely if M == 0 across all iters.}
```

If a workpad is missing or unreadable, omit the corresponding row and append a one-line note: `Iter K workpad unreadable; coverage row omitted.` Coverage rendering never blocks the final verdict.

Coverage and the Run telemetry summary (below) both consume the per-iter workpads. Read each `iter-<K>.json` once into memory at Loop Exit and render both sections from the same in-memory array — do not re-open files.

### Run telemetry summary

After the verdict line, print a compact telemetry table to chat (informational only — best-effort). Aggregate across all iterations by reading every `iter-<K>.json` workpad and summing per-phase counts.

For each agent invocation during the run, record (these are the same per-phase values that Step 7 persists into each `iter-<N>.json` workpad's mandatory `telemetry` block — capture them as the phase runs so Step 7 has them, don't reconstruct them here):
- `calls` / `agent_call_count` — increment by 1 per Agent / Task tool call in that phase.
- `tokens` / `total_tokens` — parse the `usage.total_tokens` value from each agent's tool-result `<usage>` block when present. If one source's value is missing, skip *that source* silently (do not block, and do not drop the whole `telemetry` block — a single missing `<usage>` must not leave `telemetry.phases` null).
- `wall_clock_s` — measure elapsed time between phase enter and phase exit using the orchestrator's clock.

Phase boundaries (matching the workpad schema): `phase_0`, `phase_0_5`, `phase_1`, `phase_1_5`, `phase_2`, `phase_3`, `step_2_5`, `step_2_6` (shadow pass), `phase_4_x` (covers Phase 4.1–4.3 + Loop Exit final-report emission).

Render as:

```
## Run telemetry
| Phase | Iter | Calls | Tokens | Wall-clock |
| --- | --- | --- | --- | --- |
| Phase 1 | 1 | 2 | ~9.4k | 28s |
| Phase 1.5 | 1 | 1 | ~3.1k | 11s |
| Phase 2 | 1 | 39 | ~140k | 4m12s |
| Phase 3 | 1 | 5 | ~48k | 3m00s |
| Phase 2 | 2 | 27 | ~95k | 3m40s |
| ... | | | | |
| **Total** | | 52 | ~310k | 11m05s |
```

Notes:
- Token counts are approximate (best-effort parsing of `<usage>` blocks). Mark with `~` to signal estimation.
- Failures to collect telemetry are non-fatal — print whatever was captured, omit rows with no data.
- Skip the table entirely when no iterations produced workpads (e.g. catastrophic early failure).

### Subagent effectiveness trace

After the Run telemetry table, derive and persist the **per-run subagent effectiveness trace** — a factual answer to "which subagents earned their cost on this PR." This is gated behind a config flag (on by default) and is **best-effort and non-fatal**: a missing/unreadable workpad, an absent `phase3_dispatched` field, or a write failure logs a warning and the loop still emits its normal verdict. Never abort the loop here.

All derivation lives in `lib/efficiency-trace.jq` (a mechanical jq filter, no LLM) behind the `lib/efficiency-trace.sh` wrapper — mirroring how the weekly retrospective keeps `lib/` thin. The wrapper reads the gating flag itself, so when the flag is off it emits nothing and no file is written.

**Invoke both helpers directly — no `bash` prefix.** `config-get.sh` below and `efficiency-trace.sh` in step 3 are invoked the way `/devflow:implement` invokes its helpers: as executables resolving to a `.devflow/vendor/devflow/…` path, never `bash <path>`. Resolved-path allow-list entries (`Bash(.devflow/vendor/devflow/lib/efficiency-trace.sh:*)`, `Bash(.devflow/vendor/devflow/scripts/config-get.sh:*)`) match on the command's leading token after expansion; a `bash`-prefixed command starts with `bash` and matches nothing, so on a headless run the prompt is denied and the trace is silently skipped. Direct invocation requires `lib/efficiency-trace.sh` to keep its executable bit (it is committed `+x`); never re-add a `bash` prefix to dodge a missing bit.

1. **Read the gating flag** via the config helper (use the `${CLAUDE_SKILL_DIR}`-anchored path so the read is cwd-independent, matching how this engine invokes `match-deferrals.py` / `dismiss-stale-rejections.sh`). Capture stderr + rc so a resolver failure is distinguishable from an intentional flag-off — `config-get.sh` exits non-zero with empty stdout when `node` is missing or `config.json` is malformed, and an empty `ENABLED` would otherwise fall into the "not true → skip" branch indistinguishably from `false`:
   ```bash
   ENABLED=$("${CLAUDE_SKILL_DIR}/../../scripts/config-get.sh" .devflow_review_and_fix.efficiency_telemetry_enabled true 2>/tmp/devflow-et-flag.err); ENABLED_RC=$?
   if [ "$ENABLED_RC" -ne 0 ]; then
     echo "::warning::devflow efficiency-trace gate read failed (rc=$ENABLED_RC): $(cat /tmp/devflow-et-flag.err) — skipping trace"
   fi
   ```
   If `ENABLED_RC` is non-zero or `ENABLED` is not `true`, **skip this entire section** — render no trace and write no file under `.devflow/logs/`. (The wrapper re-checks the flag itself, so this is belt-and-suspenders; the read here is what gates the `mkdir`/render below. The `::warning::` above ensures a genuine resolver failure surfaces in the Actions UI rather than masquerading as a deliberate flag-off.)

2. **Resolve the run slug and timestamp.** `<slug>` is `pr-<N>` in PR mode or the sanitized current branch name in branch mode; `<run-id>` is the per-run discriminator computed once at loop start (see Persistent workpad → Run-scoping). The run's workpads live in the run-scoped directory `.devflow/tmp/review/<slug>/<run-id>/`. The run timestamp is `date -u +%Y%m%dT%H%M%SZ`.

3. **Render the trace to chat** and **write the per-run record**. Capture the trace's stderr+rc so a real failure surfaces a reason rather than degrading silently to an empty skip:
   ```bash
   LIB="${CLAUDE_SKILL_DIR}/../../lib"
   WORKPAD_DIR=".devflow/tmp/review/<slug>/<run-id>"   # run-scoped: the trace must read THIS run's iter-*.json, not a sibling run's
   RECORD=".devflow/logs/efficiency/<slug>-$(date -u +%Y%m%dT%H%M%SZ).json"
   mkdir -p .devflow/logs/efficiency
   # Render the Markdown trace to chat. Use ::warning:: (not a plain echo) so a
   # failure surfaces in the Actions UI on a headless run; and detect the
   # all-workpads-malformed case, where the helper exits 0 with empty stdout (the
   # `||` branch never fires) — print an explicit notice so it isn't a silent no-op.
   TRACE="$("$LIB/efficiency-trace.sh" --workpad-dir "$WORKPAD_DIR" --slug "<slug>" --mode trace 2>/tmp/devflow-et.err)"; TRACE_RC=$?
   if [ "$TRACE_RC" -ne 0 ]; then
     echo "::warning::devflow efficiency-trace unavailable (rc=$TRACE_RC): $(cat /tmp/devflow-et.err)"
   elif [ -z "$TRACE" ]; then
     echo "::warning::devflow efficiency-trace produced no output (all workpads unreadable/malformed?): $(cat /tmp/devflow-et.err)"
   else
     printf '%s\n' "$TRACE"
   fi
   # Write the per-run JSON record (one file per run). Capture rc + stderr so a real
   # regression surfaces a ::warning:: breadcrumb instead of vanishing silently:
   "$LIB/efficiency-trace.sh" --workpad-dir "$WORKPAD_DIR" --slug "<slug>" --mode record > "$RECORD" 2>/tmp/devflow-et-record.err; RECORD_RC=$?
   if [ "$RECORD_RC" -ne 0 ]; then
     echo "::warning::devflow efficiency-trace record mode failed (rc=$RECORD_RC): $(cat /tmp/devflow-et-record.err)"
   fi
   # Remove the record on ANY of: helper failure (rc≠0 — guards a truncated-but-
   # non-empty file left by a mid-write abort, which a bare `-s` check would keep
   # and `git add -A` would then commit), or empty output (flag-off / zero-iteration
   # run → 0-byte file). Only a clean rc-0, non-empty write survives.
   { [ "$RECORD_RC" -ne 0 ] || [ ! -s "$RECORD" ]; } && rm -f "$RECORD"
   ```
   Print the rendered Markdown trace (the `--mode trace` output) into the chat report, after the Run telemetry table. The trace assigns each dispatched subagent exactly one verdict — **unique-effective**, **corroborating**, **noise**, or **null** (see `lib/efficiency-trace.jq`'s header and [`docs/efficiency-trace.md`](../../docs/efficiency-trace.md) for the derivation rules) — shows the per-iteration **diff profile** (the Phase 0.5 flags) and **verification posture** (so a low verifier count reads as a deliberate cheap-path/skip decision, not as "nothing ran"), the Phase-3 dispatch count, and flags any iteration that applied zero fixes as having added nothing.

4. **The record is committed deterministically.** `.devflow/logs/efficiency/<slug>-<timestamp>.json` lives under a tracked directory (the scoped `.devflow/.gitignore` ignores only `tmp/`). Do **not** leave it for an incidental future `git add -A` to absorb — that is nondeterministic and leaves untracked working-tree cruft in a standalone local run (where no further commits follow this one). Instead, both observability artifacts (this record and the durable workpad copy below) are committed together in a single dedicated `chore:` commit at the end of Loop Exit — see "Persisting observability artifacts" below. That commit is created on every writable run, **local included**; it is pushed only when `--push-each-iteration` is set. So local mode's no-remote-side-effect property is preserved by *not pushing*, not by leaving a tracked file uncommitted. The record carries the existing per-phase/per-iteration cost telemetry forward from the workpads, so that cost data is no longer discarded with `.devflow/tmp/`.

If `lib/efficiency-trace.sh` is missing or errors, the trace step above already emits `Effectiveness trace unavailable: {reason}` to chat; proceed — the verdict is unaffected.

### Durable workpad copy (writable runs only)

The run-scoped scratch under `.devflow/tmp/review/<slug>/<run-id>/` is gitignored and is destroyed with the runner (or a local `.devflow/tmp/` cleanup). On a **writable** run, persist a durable run-scoped copy of the workpad so this run's `iter-*.json` / `deferrals.json` survive teardown. The read-only-profile guard is the same write-permission enforcement the effectiveness record relies on (the cloud `review` profile denies the `mkdir`/`cp`), mirroring `/devflow:review`'s Phase 4.5 tmp-scratch/logs-durable split — though unlike the effectiveness record this copy is not additionally behind the telemetry flag; it runs on every writable run:

```bash
# Writable run (local/IDE) only. Under the read-only cloud `review` profile, SKIP this
# block entirely — no copy, no error; the gitignored `.devflow/tmp/` scratch above still
# succeeds and is sufficient for the in-run consumers. `.devflow/logs/` is a tracked
# directory (the repo `.gitignore` negates it), so no gitignore change is needed.
# Define the paths in THIS block: each fenced snippet is a separate shell, and the
# effectiveness-trace block's $WORKPAD_DIR is telemetry-gated, so it is not in scope here.
WORKPAD_DIR=".devflow/tmp/review/<slug>/<run-id>"
DURABLE=".devflow/logs/review/<slug>/<run-id>"
# `compgen -G` both tests for and (on success) is the source of the .json matches, so the
# unmatched-glob case (run dir exists but holds no .json — reachable only if iter-1's
# best-effort write failed) short-circuits the copy entirely instead of passing a literal
# `*.json` to cp and tripping a spurious failure warning under nullglob-off.
if [ -d "$WORKPAD_DIR" ] && compgen -G "$WORKPAD_DIR"/*.json >/dev/null; then
  # Best-effort (never aborts the loop), but log on failure rather than swallowing it
  # with a bare `|| true` — a denied mkdir/cp (read-only FS, ENOSPC, perms) should leave
  # a breadcrumb, matching the effectiveness-trace block's posture, so a missing durable
  # copy isn't discovered only when someone later goes looking for it. Capture the real
  # mkdir/cp stderr into the warning rather than `2>/dev/null`-ing it, so the breadcrumb
  # names the actual reason (ENOSPC/perms) instead of just asserting failure.
  if ! cp_err="$( { mkdir -p "$DURABLE" && cp -p "$WORKPAD_DIR"/*.json "$DURABLE"/; } 2>&1 )"; then
    echo "::warning::durable workpad copy failed ($WORKPAD_DIR -> $DURABLE): ${cp_err:-unknown}; best-effort, loop continues"
  fi
fi
```

The copy is best-effort: a failure never aborts the loop. Because the destination is tracked, this run persists it deterministically alongside the effectiveness record in the single dedicated `chore:` commit at the end of Loop Exit (see "Persisting observability artifacts" below) — committed on every writable run, **local included**, and additionally pushed only when `--push-each-iteration` is set (so when driven by `/devflow:implement`, that orchestrator finds it already committed rather than relying on a later `git add -A` to sweep it up). Do **not** run this block under the read-only cloud `review` profile — the durable copy is intentionally writable-runs-only.

### Persisting observability artifacts

Both artifacts written above — the effectiveness record (`.devflow/logs/efficiency/<slug>-<timestamp>.json`, when telemetry is enabled and the run had readable iterations) and the durable workpad copy (`.devflow/logs/review/<slug>/<run-id>/`, on a writable run) — live under the tracked `.devflow/logs/` tree. Persist them deterministically in a single dedicated `chore:` commit at the end of Loop Exit, *after* the run's fix commits, rather than leaving them for an incidental future `git add -A` to absorb:

```bash
# Stage ONLY the .devflow/logs/ artifact subtrees this run wrote. Add each subtree
# conditionally on its existence: the effectiveness record is telemetry-gated (its dir is
# absent when the trace is disabled) while the durable copy is not, so passing a
# non-existent pathspec to a single `git add` would abort it atomically and stage NEITHER
# subtree. The commit below is then ALSO pathspec-scoped (`git commit -- "${ADD_PATHS[@]}"`),
# so the "only .devflow/logs/ artifacts" guarantee is enforced by the commit itself, not
# merely by what we add — a pre-dirty index left staged by an earlier step can never ride
# into this chore: commit. Best-effort with `::warning::` breadcrumbs, matching the
# effectiveness-trace and durable-copy blocks above; a failure never aborts the loop.
ADD_PATHS=()
[ -d .devflow/logs/efficiency ] && ADD_PATHS+=(.devflow/logs/efficiency)
[ -d .devflow/logs/review ] && ADD_PATHS+=(.devflow/logs/review)
if [ "${#ADD_PATHS[@]}" -gt 0 ]; then
  if ! add_err="$(git add -- "${ADD_PATHS[@]}" 2>&1)"; then
    echo "::warning::observability-artifact staging failed: ${add_err:-unknown}; not persisted this run, loop continues"
  # Scope the dirtiness check to the artifact pathspecs too, so an unrelated pre-staged
  # change does not make this fire (and the empty case is a clean no-op — no empty commit).
  elif ! git diff --cached --quiet -- "${ADD_PATHS[@]}"; then
    if commit_err="$(git commit -m "chore: persist review-and-fix observability artifacts

Co-Authored-By: Claude <noreply@anthropic.com>" -- "${ADD_PATHS[@]}" 2>&1)"; then
      # Push ONLY when --push-each-iteration is set (cloud / opt-in) AND the commit landed,
      # matching the fix iterations' remote contract. In default local mode the commit is
      # created but NOT pushed: local mode's no-remote-side-effect property is preserved by
      # not pushing, not by leaving tracked files uncommitted.
      if <--push-each-iteration is set>; then
        if ! push_err="$(git push 2>&1)"; then
          echo "::warning::observability-artifact push failed: ${push_err:-unknown}; commit is local-only, loop continues"
        fi
      fi
    else
      echo "::warning::observability-artifact commit failed: ${commit_err:-unknown}; artifacts left staged, loop continues"
    fi
  fi
fi
```

Run this block on every writable run; skip it under the read-only cloud `review` profile (where neither artifact was written and the tree is not writable). The existence checks plus the pathspec-scoped `git diff --cached --quiet -- "${ADD_PATHS[@]}"` guard make it a clean no-op when neither artifact changed this run (telemetry gated off *and* nothing durable to copy), so no empty commit is ever created. Because both the guard and the commit are pathspec-scoped, the commit contains only the `.devflow/logs/` artifacts regardless of what else may be staged. A user who does not want the logs can drop the single labeled `chore:` commit with one `git reset HEAD~1`.

---

## Error Handling

- **Agent failures**: Treat as INCONCLUSIVE or note in report. Never abort the entire review. **Exception — shadow reviewers (Step 2.6):** this lenient rule does NOT apply to a shadow-pass reviewer failure. A shadow reviewer that fails, returns garbage, or is absent from the dispatched roster is a coverage shortfall that forces `coverage: "not_verified"` / outcome 3 (the shadow's fail-closed contract) — it must never be silently treated as INCONCLUSIVE-and-proceed, because that re-opens the false-clean path Step 2.6 exists to close. The *one* bounded concession (see Step 2.6 outcome 3's *Transient vs. structural* rule): a single transiently-failed reviewer gets exactly one targeted re-dispatch before `not_verified` is recorded; structural failures and any second/multi-reviewer failure are immediate `not_verified` with no retry. This is a single bounded retry, not the lenient INCONCLUSIVE-and-proceed path.
- **Test failures after fixes**: Fix the test failures before re-running the review loop.
- **Commit failures**: If a commit fails (e.g., pre-commit hook), fix the issue and retry the commit.
- **Cannot locate /devflow:review's SKILL.md**: Fatal **only when both** the primary Glob (`**/devflow/skills/review/SKILL.md`) **and** the repo-own fallback (`skills/review/SKILL.md`, the devflow-self / self-review case — see Step 1) fail to resolve a readable file. If the Glob misses but the fallback resolves, that is the normal self-review path — proceed, do not error. When both miss, error out with a clear message; do not improvise by paraphrasing the phases, and do not silently fall back to a stale plugin-cache copy. (See "Engine source of truth" and the self-review callout in Step 1.)

---

## Common Mistakes

- Trying to skip Step 2.6 because iter N looked clean — the whole point of the shadow pass is that iter N's quietness might be undersampling. A clean iter that didn't survive shadow audit is not convergence.
- Re-posting the loop's verdict to GitHub via `gh pr review` from inside the loop — this skill is silent on GitHub by design; the user runs `/devflow:review <PR>` separately for a formal merge signal.
- Confusing Step 0.9's narrow-reuse signals with a wholesale Phase 1+2 skip — Phase 1+2 always re-run on iter ≥ 2; Step 0.9 only stages reuse INPUTS (see the rationale block in Step 0.9 itself).
- Fixing only the literal instance a finding reports and leaving its `defect_signature.kind` siblings in the same diff for the shadow pass to rediscover — that converts one free deterministic sweep (Step 3, item 3) into multiple doubled-cost shadow promotions. Generalize every finding to its class and sweep the changed surface before committing.
