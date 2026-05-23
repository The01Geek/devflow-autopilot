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

- Not for trivial doc-only PRs — use `/devflow:review` and read the report; auto-fixing prose adds churn for little value.
- Not for PRs where you want to hand-review every finding before deciding — use `/devflow:review` instead; this skill commits fixes between iterations.
- Not for PRs that cross a release boundary or touch infrastructure where surprise commits would be costly — review-and-fix produces commits as a side effect of converging.
- Not for first-pass branch hygiene (rebases, conflict resolution, build fixes) — get a clean diff first, then run review-and-fix on the result.
- Not for situations where you need a formal `--request-changes` merge block as a side effect — this skill is silent on GitHub by design. Run `/devflow:review <PR>` afterward (or instead) to post the verdict as a blocking review.

## Engine source of truth

This skill wraps /devflow:review's four-phase engine in a fix loop. Phases 0 through 4.3 — setup, diff classification, checklist generation (including >10-file batching and Phase 1.5 dedup), checklist verification (including lite-mode partition), review agents (including the exact per-agent prompts and the `defect_signature` contract), and aggregation — live in `/devflow:review`'s SKILL.md and are authoritative. Read them on every Step 1; never improvise the engine or paraphrase the Phase 3 prompts. Drift between the two skills is the single biggest cause of /devflow:review-and-fix missing findings that /devflow:review caught.

This skill **skips** /devflow:review's Phase 4.4 entirely — no GitHub post. The final report is emitted to chat only; the human reviewer decides whether to convert it into a formal merge signal by running `/devflow:review <PR>` separately (which performs an independent re-review and posts the result). It also adds:
- A **fix-delta handoff** before Step 1 in iterations N≥2 (passes the prior iteration's checklist + fix-files into Phase 1's generator and Phase 2's narrow-reuse logic; Phase 1+2 always re-run — they are *not* skipped wholesale).
- A **persistent workpad** (`.devflow/tmp/review/<slug>/iter-<N>.json`) that carries checklist verdicts, findings, fix decisions, and convergence inputs across iterations.
- A **shadow review pass** at Step 2.6 that runs an independent re-review (fresh-context subagent executing /devflow:review's Phases 0–4.3) before declaring convergence on a non-REJECT verdict (see Step 2.6).
- A **`## Coverage` section** in the final report aggregating per-iter finding counts, shadow agreement, and Phase 1.1.5 cap drops (see Loop Exit → Coverage).
- A **per-phase telemetry summary** at Loop Exit (agent calls / tokens / wall-clock).

**Maintainer rule.** Engine changes belong in /devflow:review's SKILL.md; this file should only touch the loop wrapper, the workpad, the fix-delta handoff (Step 0.9), the Step 2.5 verification gate, the Step 2.6 shadow review, the fix step, the convergence check, the telemetry summary, or Loop Exit's chat output. **Violating the letter of these phases is violating the spirit** — even when a paraphrase looks faithful, the downstream agents are calibrated to /devflow:review's exact wording.

---

## Persistent workpad

The orchestrator persists per-iteration state under `.devflow/tmp/review/<slug>/iter-<N>.json` (relative to the repo root). `<slug>` is `pr-<N>` in PR mode or the sanitized current branch name in branch mode. `<N>` is the iteration number, starting at 1.

The same directory also contains `.devflow/tmp/review/<slug>/diff.patch` — the cached full diff written by Phase 0.2 of `/devflow:review` on every iteration (overwritten if it already exists). Phase 3 agents Read this file directly instead of re-running `gh pr diff` / `git diff` 4–5 times in parallel. See `/devflow:review`'s Phase 0.2 for the write logic.

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
    "pr-review-toolkit:comment-analyzer"
  ],
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
    "step_2_6":   {"calls": 0, "tokens": 0,     "wall_clock_s": 0},
    "phase_4_x":  {"calls": 0, "tokens": 0,     "wall_clock_s": 1}
  }
}
```

`phase3_dispatched` is the array of Phase-3 agent identifiers **actually launched** this iteration, captured at Step 1's Phase 3.1 dispatch *after* Phase 0.5 gating (so a gated-out `pr-test-analyzer` / `type-design-analyzer` is absent). It is load-bearing for the Loop Exit effectiveness trace: a `null` verdict (dispatched but silent) is derived as `phase3_dispatched − (agents present in phase3_findings)`, so without this roster a silent agent is indistinguishable from one that was never launched. The field is best-effort — if it is absent on an older/partial workpad, the trace degrades to classifying only the agents that appear in `phase3_findings`.

Use the **same identifier string** in `phase3_dispatched` that you write to each finding's `phase3_findings.agent`, so the trace can match dispatch to outcome. For the five pr-review-toolkit agents that is `pr-review-toolkit:<name>` (e.g. `pr-review-toolkit:code-reviewer`). For the sixth Phase-3 dispatch — the general-purpose final-pass reviewer launched via `Task`/`subagent_type: general-purpose` invoking `/superpowers:requesting-code-review` (see /devflow:review's Phase 3.1) — record it as **`superpowers:requesting-code-review`** in both places, so this (most expensive) dispatch is tallied consistently rather than appearing under an ad-hoc string each run.

`cap_drops` is populated from /devflow:review's Phase 1.1.5 output (see that skill's Phase 1.1.5 for the shape — `count` is the total dropped at the 100-item cap, `by_category` is the per-category breakdown). The Coverage section in the final report reads this.

`shadow` is populated by Step 2.6 (the shadow review pass). It is only present on the workpad of the iter that triggered the shadow — typically the iter with the tentative non-REJECT verdict. Promoted-shadow iters (when the shadow surfaces new findings and triggers iter N+1 → Step 2.5) have their own workpad without a `shadow` block of their own unless they too produce a non-REJECT verdict that triggers another shadow.

### Lifecycle

- **Iter 1 start:** create the directory if missing. There is no prior iteration to read.
- **Iter N start (N≥2):** before doing anything else, read `iter-<N-1>.json`. The fix-delta handoff (Step 0.9) and convergence check both consume it. If the file is missing or unreadable, log a warning and continue without the handoff optimizations (Phase 1 generator runs without the prior-checklist variance-recovery block; Phase 2.0.5 reuses nothing; Phase 3 runs without prior-findings context). Phase 1+2+3 still run — they always do.
- **Iter N end:** write `iter-<N>.json` with everything collected during the iteration before looping back to Step 1.
- **Step 2.6 end (shadow pass):** when the shadow review pass runs at end-of-loop, append the `shadow` block to the latest iter's workpad (re-writing `iter-<N>.json` with the shadow result included). If the shadow promotes new findings into iter (N+1), iter (N+1) is a normal iter from a lifecycle standpoint — it will write its own `iter-<N+1>.json` per the regular end-of-iter rule.

The workpad is best-effort and informational. A write failure should not abort the loop — log it and continue.

---

## Main Loop

Execute this loop with a maximum of 4 iterations.

### Iteration Start

Output: `Review iteration {N}/4...`

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

**Mandatory and authoritative.** Use `Glob` with pattern `**/devflow/skills/review/SKILL.md` to locate /devflow:review's SKILL.md, then `Read` it in full. Execute its **Phases 0 through 4.3 verbatim** — do not improvise the Phase 3 agent prompts, do not skip the Phase 1 >10-file batching, do not substitute your own verdict criteria. This skill deliberately does *not* contain a paraphrase of those phases; if you cannot read /devflow:review's SKILL.md, error out (see Error Handling).

**Why path-based loading, not `Skill: "devflow:review"`.** The `Skill` tool *executes* a skill end-to-end; it would run /devflow:review's Phase 4.4 (formal GitHub post) before this loop has converged, defeating the deferred-post design. We need /devflow:review's phases as a *procedure read inline*, not as an opaque invocation. The path-coupling that follows is the price of that: the glob assumes the plugin layout `<plugin-root>/skills/<skill-name>/SKILL.md` (per the agentskills.io convention) — `**` absorbs depth changes, but the `skills/review/` sub-path is load-bearing. If that layout ever changes, update the glob pattern here and in the "Engine sharing" paragraph at the top of /devflow:review's SKILL.md.

When iter N≥2, hand off the `fix_files`, `prior_checklist`, and `prior_phase3_findings` computed in Step 0.9 into the engine's Phase 1 (generator variance-recovery prompt block), Phase 2 (narrow-reuse — Phase 2.0.5), and Phase 3 (prior-findings context block). Phase 1+2 always run; their *outputs* may be smaller because Phase 2.0.5 reuses some prior verdicts, but the phases themselves do not skip.

**PR-mode head-override (every PR-mode iteration).** In PR mode, pass `head_override = local` into the engine's Phase 0.2 — see /devflow:review's Phase 0.2 "Caller head-override" for the mechanic (it diffs against local `HEAD` instead of re-fetching `gh pr diff`). This is what makes the engine review the fix commits this loop has made locally rather than stale pushed state: on iteration 1 (no fixes yet, branch freshly synced in Step 0.5) it is diff-identical to the remote fetch, and from iteration 2 on it keeps the loop off pre-fix code. Because convergence rides on this override and not on pushing, a no-push PR-mode run (`--push-each-iteration` absent) still converges. Current-branch mode needs no override — it already diffs against local `HEAD`.

Skip /devflow:review's Phase 4.4 (formal GitHub review posting). The fix loop is silent on GitHub by design — the final report is emitted to chat only at Loop Exit. A human who wants a formal merge signal runs `/devflow:review <PR>` separately.

**Red flags — STOP and run Glob+Read if you're about to:**
- Skip the Read because "I already know what /devflow:review does"
- Paraphrase the Phase 3 agent prompts instead of using them verbatim
- Treat the engine recap below as a substitute for the canonical phases
- Guess the path instead of running Glob

Every drift incident this skill has had traces to one of those rationalizations. Violating the letter of /devflow:review's phases is violating the spirit, even when the paraphrase reads correct.

The engine produces, for this iteration: a verdict in {APPROVE, APPROVE WITH CAVEAT / APPROVE with notes, REJECT} plus a markdown report. Phase 0.5 flags (`small_diff`, `config_only`, `has_new_types`, `engine_self_modifying`, `checklist_skipped`) apply unchanged. **The fix loop's iteration cap is still max 4** — Phase 0.5 only scales agent dispatch, not the loop.

### Step 2: Check Verdict

- Engine verdict **APPROVE** AND no advisory findings carry forward from any prior Step 2.5 → tentative final verdict `APPROVE`. Go to **Step 2.6: Shadow review** before exiting the loop.
- Engine verdict **APPROVE** but advisory findings have been parked → tentative final verdict `APPROVE WITH ADVISORY NOTES`. Go to **Step 2.6: Shadow review**.
- Engine verdict **APPROVE WITH CAVEAT** / **APPROVE with notes** → tentative final verdict `APPROVE WITH CAVEAT`. Go to **Step 2.6: Shadow review**.
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

Run a structurally-independent re-review before declaring convergence. Only triggers when the loop's tentative final verdict is non-REJECT (APPROVE, APPROVE WITH ADVISORY NOTES, APPROVE WITH CAVEAT / APPROVE with notes) — either from Step 2 on the current iteration, or from Step 4.5's early-exit convergence path. REJECT verdicts skip this step and go straight to Loop Exit.

**Why a shadow pass.** Iterations inside the fix loop share state — the orchestrator's context window carries prior findings, fix decisions, and pushback history forward. That state biases what the engine looks for and what it accepts as "already considered." The shadow pass is the loop's audit: a fresh engine context with no knowledge of the iter history runs the same engine and we compare. This matches what users already do manually today (`/devflow:review <PR>` after `/devflow:review-and-fix`); doing it inside the loop costs the same and feeds the result into one more iteration if the shadow disagrees, instead of leaving it to the human.

**Iteration accounting.** The shadow pass itself is NOT counted toward the max-4 iteration cap — it's a verification pass on the final iter's state, not a fix iteration. A *promoted* iter (one started because the shadow surfaced new findings — see outcome #2 below) DOES count toward the cap, because it runs Step 2.5 + Step 3 + Step 4 + Step 4.5 from the fix-loop side even though it skips Phase 1+2.

#### Dispatch

Use the **Agent tool** (NOT the `Skill` tool) with `subagent_type: "general-purpose"`. The subagent's fresh context window is the structural guarantee: it has no access to the orchestrator's prior findings, workpad, fix decisions, or pushback history. We dispatch the engine *inline as a procedure read from SKILL.md* — not via the `Skill` tool — because `Skill` runs a skill end-to-end and would execute /devflow:review's Phase 4.4 before the shadow can be intercepted; we need the phases as steps the subagent walks through itself so it can stop before Phase 4.4. This mirrors the Step 1 pattern in this file.

Prompt:

```
You are running a shadow code-review pass for /devflow:review-and-fix's convergence audit. Your fresh context window is the structural guarantee — do NOT consult any prior conversation, workpad, or fix history; everything you need is in /devflow:review's SKILL.md and the diff itself.

1. Use `Glob` with pattern `**/devflow/skills/review/SKILL.md` to locate /devflow:review's SKILL.md. Read it in full.
2. Execute its Phases 0 through 4.3 verbatim against {PR <N> | the current branch}. Do not improvise the Phase 3 agent prompts; do not skip the Phase 1 >10-file batching; do not substitute your own verdict criteria.
3. DO NOT execute Phase 4.4 (no `gh pr review` / `gh pr comment` / no formal GitHub post). This is an internal shadow pass and must produce zero side effects on the PR. /devflow:review's Phase 4.4 only runs in PR mode anyway, but be explicit: if invoked in PR mode, stop after Phase 4.3.
4. Return your output as a single JSON object in a ```json code fence with these keys:
   - "verdict": one of APPROVE / "APPROVE with notes" / "APPROVE WITH CAVEAT" / "APPROVE WITH ADVISORY NOTES" / REJECT
   - "report": the full markdown report from /devflow:review's Phase 4.1
   - "phase3_findings": the array of Phase 3 findings with `defect_signature` blocks
   - "phase2_fails": the array of Phase 2 checklist items with verdict FAIL or INCONCLUSIVE (empty if Phase 1+2 were skipped)
```

#### Parse and compare

When the subagent returns, parse out `shadow_verdict`, `shadow_phase3_findings`, and `shadow_phase2_fails`.

**Compare shadow's findings to the loop's last iter's findings** (the workpad's `iter-<N>.json` from the loop's most recent fix iteration — N is the iteration that produced the tentative final verdict, not counting the shadow itself):

A shadow finding is **new** iff no finding in the last iter's `phase3_findings` matches it under /devflow:review's Phase 3.2 `defect_signature` corroboration rule (same `file` + overlapping `line_range` + identical `kind`). See that section for the canonical definition — do not paraphrase it here.

Apply the same comparison to `shadow_phase2_fails` against the last iter's `checklist` (matching on `claim_signature` where available, else on `(source_file, claim text)`).

#### Decide

Three outcomes:

1. **Shadow's findings are a subset of (or equal to) the loop's last iter's findings AND `shadow_verdict` is non-REJECT** → genuine convergence. Record the shadow result in the workpad (see "Shadow workpad record" below) and proceed to **Loop Exit** with the tentative final verdict unchanged.

2. **Shadow surfaces any new Critical or Important Phase 3 finding, OR any new Phase 2 FAIL, OR `shadow_verdict` is REJECT** → the loop has not converged. **Promote the shadow's new findings into a new iteration:**
   - The promoted iter has its own iter number (N+1) and writes its own `iter-<N+1>.json` workpad at end-of-iter per the regular Persistent workpad → Lifecycle rule. Its `iter` field is N+1; it does NOT overload iter-N's workpad.
   - Step 0.9 (fix-delta handoff) runs for the promoted iter but **short-circuits**: stage only `prior_phase3_findings` (Step 2.5's classification needs it to evaluate shadow's findings against what's already been considered); skip the `fix_files` and `prior_checklist` computation — Phase 1+2 are skipped for promoted iters, so those staged values have no downstream consumer.
   - Treat the shadow's new findings as iter (N+1)'s Phase 3 findings (plus iter (N+1)'s Phase 2 FAILs for any new checklist FAILs from shadow).
   - Skip Phase 1+2 for this promoted iter — shadow already ran a full engine, so re-running Phase 1+2 would be redundant work. (This is the one place in the loop where Phase 1+2 is skipped on iter ≥2; it's safe because the inputs *are* a Phase 1+2+3 result.)
   - Go straight to **Step 2.5** (pre-fix verification gate) → **Step 3** (fix findings) for the promoted iter. The regular loop continues from there: Step 4 → Step 4.5 → Step 1 of iter (N+2) if needed.
   - **Iteration cap still applies** (see "Iteration accounting" above — promoted iter counts toward max-4). If iter 4 has already run and shadow still surfaces new findings, do NOT start iter 5. Exit to Loop Exit with:
     - Final verdict `REJECT` if any of shadow's new findings is Critical.
     - Final verdict `APPROVE WITH UNRESOLVED SHADOW FINDINGS` otherwise (Important-only).
     - Include the unresolved shadow findings verbatim in the chat output and in the report's `## Unresolved Shadow Findings` section.

3. **Shadow returns a malformed or empty response, or the subagent errors** → record the failure in the workpad, note it in chat (`Shadow review pass failed: {reason}. Proceeding to Loop Exit with the loop's tentative verdict — shadow agreement not verified.`), and proceed to Loop Exit. Do not retry; do not block the loop on a shadow failure.

#### Shadow workpad record

After Step 2.6 completes (regardless of outcome), append a `shadow` block to the last iter's workpad file (`iter-<N>.json`):

```json
"shadow": {
  "ran_at": "2026-05-17T12:34:00Z",
  "verdict": "APPROVE",
  "phase3_findings": [/* the parsed array */],
  "phase2_fails": [/* the parsed array */],
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

The Coverage section in the final report (Loop Exit) reads this block.

#### Cost note

The shadow pass roughly doubles the cost of a converging run — one full engine pass that doesn't lead to fixes when it agrees. This is intentional:

1. It matches what experienced users already do manually (`/devflow:review` after `/devflow:review-and-fix`); net cost is zero in their workflow and shadow agreement is now mechanical rather than a separate session.
2. It addresses the empirically-observed "review finds things review-and-fix missed" pattern — the entire reason this step exists.
3. The structural guarantee (fresh context window, no fix-loop state) is what makes shadow a credible audit rather than a self-check that re-derives the same answer.

### Step 3: Fix Findings

Apply the `superpowers:receiving-code-review` principles. After Step 2.5, the findings reaching Step 3 are: Phase 2 checklist FAILs, corroborated Phase 3 findings, confirmed-by-web findings, and codebase-claim findings. Refuted and inconclusive findings have been demoted to advisory and are not in this list; they stay parked.

1. **Read all findings** without reacting. Understand the full picture before fixing anything.

2. **Evaluate each finding technically:**
   - For verification checklist FAILs: Read the evidence. Verify it yourself by reading the source file cited. If the evidence is correct, fix the code. If the evidence is wrong (the verifier misread the source), skip the fix and document why.
   - For Critical/Important findings from review agents: Read the finding. Check if it's valid for this codebase. If valid, fix it. If not, skip and document why. (Note: external-tool claims that survived Step 2.5 are already either web-confirmed or corroborated by ≥2 agents — be slow to dismiss them as invalid.)
   - For Suggestion/Minor findings: Fix only if trivial and clearly correct. Do not spend time on cosmetic issues.

3. **Fix one issue at a time.** After each fix, verify the surrounding code still makes sense.

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

7. **Persist the workpad.** Before looping, write `iter-<N>.json` with: fix_commit_sha, fix_files (`git diff --name-only HEAD~1 HEAD`), the iter-N checklist + verdicts (each item flagged `reused_from_iter_prev: true|false` to record whether Phase 2.0.5's narrow-reuse path was taken), `phase3_dispatched` (the array of Phase-3 agent identifiers actually launched this iteration after Phase 0.5 gating — see the workpad schema note above for why this roster is load-bearing for the Loop Exit effectiveness trace), Phase 3 findings (each with `defect_signature`, `step25_classification`, and the matching `fix_decision` so iter-(N+1)'s Phase 3 handoff has the full record), `fix_decisions` (one entry per finding using the shape shown in the workpad schema example: `applied` entries carry `{finding_id, decision, commit}`; `pushed_back` / `deferred` entries carry the structured pushback fields `{source_file, claim_text, skip_category, evidence}` from Step 3 item 5 where `skip_category` is one of the values in the `skip_category` enum (authoritative) table; `advisory` entries — written by Step 2.5 at demotion time, not here — carry `skip_category: "advisory-parked"` plus the demotion `evidence`), convergence_inputs, `cap_drops` (from /devflow:review's Phase 1.1.5 output — see that skill for the shape), and telemetry (best-effort — see Loop Exit). The `shadow` block, if any, is appended later by Step 2.6 and is not populated here.

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

**Widens-surface guard.** Walk every `fix_decisions` entry in the final iter's workpad whose `skip_category` reads **Yes** in the enum table (Step 3, item 5 — currently `claim-quality`, `out-of-scope`, `already-tracked`). For each candidate, join to its Phase 3 finding via `finding_id` to obtain `defect_signature.file` and `defect_signature.line_range`, then read the cached diff (`.devflow/tmp/review/<slug>/diff.patch`) and check whether any non-comment hunk in the diff overlaps that file within ±10 lines of the line range. If overlap is detected, the skip is **disqualified for the downgrade gate** — append a bullet to the workpad's `Devflow Reflection` (`widens-surface guard rejected skip for finding {finding_id}: PR diff overlaps {file}:{lines}`) and treat the finding as a non-skipped REJECT trigger for the gate that runs next. This catches the "refactor around a pre-existing bug, then defer the bug" pattern: the bug's lines weren't touched in isolation, but the surrounding code changed in a way that widens reliance on the broken behavior.

**Deferrals manifest.** After the guard runs, emit `.devflow/tmp/review/<slug>/deferrals.json` containing every **surviving** Yes-downgrade skip (i.e. `claim-quality` / `out-of-scope` / `already-tracked` entries that the widens-surface guard did not disqualify). The manifest is written regardless of whether the downgrade gate ultimately fires; `claim-quality` and `already-tracked` skips on non-REJECT runs are still legitimate deferrals worth tracking for the verdict matcher. If zero entries survive, omit the file entirely.

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

- **APPROVE**: `Review passed after {N} iteration(s) (shadow agreed). All checks approved.`
- **APPROVE WITH ADVISORY NOTES**: `Review passed after {N} iteration(s) (shadow agreed) with {M} advisory finding(s) parked for human review. See report.`
- **APPROVE WITH CAVEAT** (engine verdict APPROVE WITH CAVEAT / APPROVE with notes, or the Step-3-evaluated REJECT downgrade fired): `Review passed after {N} iteration(s) (shadow agreed) with caveats. See report.`
- **APPROVE WITH UNRESOLVED SHADOW FINDINGS** (iter cap hit while shadow still surfaced new Important findings — see Step 2.6): `Review converged after {N} iteration(s) but a final shadow pass surfaced {K} new Important finding(s) that the loop could not address within the iteration cap. See report.`
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

Shadow pass raised X findings; Y were already in iter N (overlap = Y/X); Z were new (Z_crit Critical, Z_imp Important). {If Z > 0: "The loop promoted them into iter (N+1); this report reflects the post-promotion state."} {If Z == 0: "Genuine convergence — shadow agreed with the loop."} {If shadow did not run (e.g. REJECT verdict): "Shadow pass did not run — final verdict was REJECT before convergence."}

### Phase 1.1.5 cap drops

Phase 1.1.5 dropped M items at the 100-item cap (categories: dependency_interaction: K1, api_contract: K2, ...). {Omit this subsection entirely if M == 0 across all iters.}
```

If a workpad is missing or unreadable, omit the corresponding row and append a one-line note: `Iter K workpad unreadable; coverage row omitted.` Coverage rendering never blocks the final verdict.

Coverage and the Run telemetry summary (below) both consume the per-iter workpads. Read each `iter-<K>.json` once into memory at Loop Exit and render both sections from the same in-memory array — do not re-open files.

### Run telemetry summary

After the verdict line, print a compact telemetry table to chat (informational only — best-effort). Aggregate across all iterations by reading every `iter-<K>.json` workpad and summing per-phase counts.

For each agent invocation during the run, record:
- `agent_call_count` — increment by 1 per Agent / Task tool call.
- `total_tokens` — parse the `usage.total_tokens` value from each agent's tool-result `<usage>` block when present. If the value is missing, skip silently (do not block).
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

1. **Read the gating flag** via the config helper (use the `${CLAUDE_SKILL_DIR}`-anchored path so the read is cwd-independent, matching how this engine invokes `match-deferrals.py` / `dismiss-stale-rejections.sh`):
   ```bash
   ENABLED=$(bash "${CLAUDE_SKILL_DIR}/../../scripts/config-get.sh" .devflow_review_and_fix.efficiency_telemetry_enabled true)
   ```
   If `ENABLED` is not `true`, **skip this entire section** — render no trace and write no file under `.devflow/logs/`. (The wrapper re-checks the flag itself, so this is belt-and-suspenders; the read here is what gates the `mkdir`/render below.)

2. **Resolve the run slug and timestamp.** `<slug>` is `pr-<N>` in PR mode or the sanitized current branch name in branch mode — the same slug used for the workpad directory `.devflow/tmp/review/<slug>/`. The run timestamp is `date -u +%Y%m%dT%H%M%SZ`.

3. **Render the trace to chat** and **write the per-run record**. Capture the trace's stderr+rc so a real failure surfaces a reason rather than degrading silently to an empty skip:
   ```bash
   LIB="${CLAUDE_SKILL_DIR}/../../lib"
   WORKPAD_DIR=".devflow/tmp/review/<slug>"
   RECORD=".devflow/logs/efficiency/<slug>-$(date -u +%Y%m%dT%H%M%SZ).json"
   mkdir -p .devflow/logs/efficiency
   # Render the Markdown trace to chat (best-effort; empty output → skip):
   TRACE="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$WORKPAD_DIR" --slug "<slug>" --mode trace 2>/tmp/devflow-et.err)" \
     || echo "Effectiveness trace unavailable: $(cat /tmp/devflow-et.err)"
   [ -n "$TRACE" ] && printf '%s\n' "$TRACE"
   # Write the per-run JSON record (one file per run):
   bash "$LIB/efficiency-trace.sh" --workpad-dir "$WORKPAD_DIR" --slug "<slug>" --mode record > "$RECORD" 2>/dev/null || true
   # A flag-off / zero-iteration / failed run emits no output → a 0-byte file;
   # remove it so flag-off (and a catastrophic-early-failure run) write nothing
   # under .devflow/logs/.
   [ -s "$RECORD" ] || rm -f "$RECORD"
   ```
   Print the rendered Markdown trace (the `--mode trace` output) into the chat report, after the Run telemetry table. The trace assigns each dispatched subagent exactly one verdict — **unique-effective**, **corroborating**, **noise**, or **null** (see `lib/efficiency-trace.jq`'s header and [`docs/efficiency-trace.md`](../../docs/efficiency-trace.md) for the derivation rules) — shows per-iteration dispatch counts (Phase-3 agents, and checklist verifiers split into lite/agent), and flags any iteration that applied zero fixes as having added nothing.

4. **The record is tracked.** `.devflow/logs/efficiency/<slug>-<timestamp>.json` lives under a tracked directory, so the run's existing commits sweep it up. When `--push-each-iteration` is set, the record written here survives GH-runner teardown via the same `git add -A` + push the fix iterations use; commit and push it now so it is not lost (keep the project's commit-message trailer):
   ```bash
   if [ -s "$RECORD" ] && <--push-each-iteration is set>; then
     git add "$RECORD" && git commit -m "chore: persist review-and-fix effectiveness record

Co-Authored-By: Claude <noreply@anthropic.com>" && git push || true
   fi
   ```
   When `--push-each-iteration` is absent (the default, local mode), leave the record on disk uncommitted — consistent with the loop's no-remote-side-effect contract for that mode. The record carries the existing per-phase/per-iteration cost telemetry forward from the workpads, so that cost data is no longer discarded with `.devflow/tmp/`.

If `lib/efficiency-trace.sh` is missing or errors, the trace step above already emits `Effectiveness trace unavailable: {reason}` to chat; proceed — the verdict is unaffected.

---

## Error Handling

- **Agent failures**: Treat as INCONCLUSIVE or note in report. Never abort the entire review.
- **Test failures after fixes**: Fix the test failures before re-running the review loop.
- **Commit failures**: If a commit fails (e.g., pre-commit hook), fix the issue and retry the commit.
- **Cannot locate /devflow:review's SKILL.md**: This is fatal — /devflow:review-and-fix depends on the engine. Error out with a clear message; do not improvise by paraphrasing the phases. (See "Engine source of truth" at the top.)

---

## Common Mistakes

- Trying to skip Step 2.6 because iter N looked clean — the whole point of the shadow pass is that iter N's quietness might be undersampling. A clean iter that didn't survive shadow audit is not convergence.
- Re-posting the loop's verdict to GitHub via `gh pr review` from inside the loop — this skill is silent on GitHub by design; the user runs `/devflow:review <PR>` separately for a formal merge signal.
- Confusing Step 0.9's narrow-reuse signals with a wholesale Phase 1+2 skip — Phase 1+2 always re-run on iter ≥ 2; Step 0.9 only stages reuse INPUTS (see the rationale block in Step 0.9 itself).
