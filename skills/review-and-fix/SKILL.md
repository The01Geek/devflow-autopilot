---
name: review-and-fix
description: Use when you need findings on a PR or current branch to be auto-applied, not just reported.
argument-hint: "[pr-number] [--push-each-iteration]"
---

# /devflow:review-and-fix — Review, Fix, and Verify Loop

You are the review-and-fix orchestrator. Run /devflow:review's review engine, fix the findings it surfaces, and re-run until the engine returns a clean verdict.

**Input:** `$ARGUMENTS` may contain an optional PR number and/or the flag `--push-each-iteration`. Parse the two independently — either, both, or neither may be present (`863`, `--push-each-iteration`, `863 --push-each-iteration`, or empty). If no PR number is given, review and fix the current branch. The numeric token (if any) is `$PR_NUMBER` throughout this skill.

**`--push-each-iteration` (default off).** When set, the loop runs `git push` after each iteration's fix commit (Step 3, item 6), so the remote PR branch — and any CI attached to it — tracks every iteration. When absent (the default, and the expected mode for direct user invocation), the loop commits locally and does not push the **fix commits**. It is not a no-remote-side-effects mode: independently of this flag, Loop Exit's mandatory `--persist` pushes the `devflow-telemetry` branch to `origin` on every writable run (see *Persisting observability artifacts*). The flag governs *fix-commit propagation and the base-branch update checkpoint* (Checkpoint 3, issue #448 — when set, each iteration's push and the Loop-Exit push run through `scripts/update-branch-checkpoint.sh`, gated by `devflow_implement.update_branch_checkpoints`; when absent, the base is never touched); it does NOT post a verdict to GitHub (`gh pr review` / `gh pr comment`) in either case — the skill stays silent on verdicts by design (see "Engine source of truth"). `/devflow:implement` sets this flag at its Phase 3.3 because it operates on a live draft PR with CI; direct users normally omit it. The flag is orthogonal to loop correctness: the loop sees its own fixes regardless of pushing (current-branch mode diffs against local `HEAD`; PR mode uses the head-override in Step 1).

**Key principle:** You perform fixes DIRECTLY in this session. Do NOT delegate fixes to a subagent. You need full conversation context to apply `devflow:receiving-code-review` principles (technical evaluation, pushback, verification).

**Portable helper anchor (single-statement).** The bundled-helper commands in this skill resolve the skill directory inline at each call site via `${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}`. When `$CLAUDE_SKILL_DIR` is set and non-empty (Claude Code), run each command exactly as written. On a runner where it is unset or empty, replace the placeholder with the skill base directory the runner reports in context (e.g. a `Base directory for this skill:` line) before running the command; if that reported path is Windows-form (`C:\...`), first convert it to this shell's POSIX form with one standalone `wslpath -u '<path>'` (WSL) or `cygpath -u '<path>'` (Git Bash/MSYS2) command and substitute the printed result **only if the command succeeds and prints a non-empty path — otherwise fall through to the drive-letter rules exactly as if the tool were absent, the same success-and-non-empty acceptance the platform's path-normalization rules apply** (if neither tool exists: lowercase the drive letter, map `C:\` to `/mnt/c` on WSL or `/c` on MSYS2, and turn backslashes into `/`; if the environment is neither WSL nor MSYS2, use the path unchanged and report that it could not be normalized — the same arm the platform's path-normalization rules take). Resolve the anchor inline at every call site — never capture it into a shell variable that a later statement reads, because some runners' inline-bash marshaling drops such variables (observed on Copilot CLI). If neither `$CLAUDE_SKILL_DIR` nor a runner-reported base directory is available, stop and report that the helper anchor could not be resolved rather than running a command with a broken path.

**Consumer prompt extension (load first).** Before doing this skill's work, load any consumer-supplied prompt extension for this skill and honor it. From the repo root, run:

```bash
"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/load-prompt-extension.sh review-and-fix
```

If the invocation fails because the helper path does not exist (`No such file`, exit 127, or the platform equivalent), that is the **anchor-resolution** failure described in the *Portable helper anchor* note above — fix the anchor, don't report a missing extension. Otherwise, if the helper exits non-zero, a consumer extension exists but could not be loaded — surface its stderr message and do not silently proceed as if none existed. If it exits 0 and prints text, treat that text as additional instructions appended to the end of this skill's own prompt for this run — it is upgrade-safe, consumer-owned customization committed under `.devflow/prompt-extensions/`. If it exits 0 and prints nothing, proceed unchanged.

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
- A **shadow review pass** at Step 2.6 — a *parent-orchestrated* independent re-review that re-runs /devflow:review's Phases 0–4.3 with each reviewer agent's prompt blinded to the loop's prior findings — before declaring convergence on a non-REJECT verdict (and, on an `engine_self_modifying` PR, also once after iteration 1 regardless of verdict — see Step 2.6).
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
  "loop_role": "fix | promoted",
  "promotion_provenance": "shadow | park-calibration-post-shadow | park-calibration-pre-shadow (promoted iterations only)",
  "current_step": "2.6",
  "current_substep": "run_shadow_fanout",
  "pending_dispatch": {"kind": "shadow_reviewer_fanout", "roster": ["devflow:code-reviewer", "devflow:silent-failure-hunter"], "dispatched_at": "2026-05-16T20:46:00Z"},
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
    "devflow:code-reviewer",
    "devflow:silent-failure-hunter",
    "devflow:comment-analyzer",
    "devflow:requesting-code-review",
    "devflow:type-design-analyzer",
    "devflow:pr-test-analyzer"
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
      "agent": "devflow:code-reviewer",
      "severity": "Critical",
      "description": "...",
      "defect_signature": {"file": "src/example_pkg/foo.py", "line_range": [42, 47], "kind": "null_deref"},
      "corroboration_count": 2,
      "step25_classification": "codebase | web_confirmed | web_refuted | web_inconclusive | over_budget",
      "fix_decision": "applied | pushed_back | deferred | advisory | severity-calibrated"
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
    },
    {
      "finding_id": "F-16",
      "decision": "below-threshold",
      "source_file": "src/example_pkg/quuz.py",
      "claim_text": "same-class advisory instance",
      "skip_category": "below-threshold-parked",
      "evidence": "parked-origin: below-threshold"
    },
    {
      "finding_id": "F-17",
      "decision": "severity-calibrated",
      "source_file": "src/example_pkg/corge.py",
      "claim_text": "missing key crashes the loader",
      "original_severity": "Critical",
      "calibrated_severity": "Important",
      "evidence": "over-grade gate shape 1 (fail-closed): the loader raises KeyError on the missing key and test_loader_missing_key catches it RED — a loud bounded stop, not a silent corruption; recorded technical evaluation, did not auto-demote"
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
  "parked_class_sweep": {
    "classes": [
      {
        "source_finding_ids": ["F-16"],
        "kind_literal": "unchecked_type",
        "sites_examined": ["src/example_pkg/quuz.py:40-72"],
        "new_siblings": [
          {"finding_id": "F-18", "site": "src/example_pkg/quuz.py:63-66", "severity": "Suggestion", "disposition": "advisory", "marker": "parked-sibling: class-sweep"}
        ]
      }
    ],
    "truncation": null,
    "dispatch": "verified"
  },
  "shadow": {
    "ran_at": null,
    "reviewed_sha": null,
    "verdict": null,
    "coverage": null,
    "prompt_addenda": null,
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

`loop_role` names this iteration's role in the fix loop — `fix` for a normal fix iteration, `promoted` for an iteration started by a Decide-outcome-2 shadow promotion (see Step 2.6 "Decide" outcome 2 and Step 4.5). `lib/efficiency-trace.jq` **derives and surfaces it per iteration** in the per-run record (iteration 1 → `fix`; iteration N → `promoted` when iteration N−1's `shadow` block recorded a promotion via `promoted_to_iter_next`, else `fix`), preserving any persisted non-empty value — so the field has a real consumer and is no longer left to be reconstructed by inference; and `lib/efficiency-trace.sh --self-check` warns (best-effort, never failing) when a persisted iter workpad drops it or any other expected field. The `shadow` block remains the record of the shadow pass and any post-shadow delta-review, and the convergence/promotion logic continues to key off that block, not this field. Persisting it on every iteration keeps a multi-iteration run's loop state auditable at a glance from the workpads; an older workpad missing it, or any dropped value, is derived as `fix`.

`phase3_dispatched` is the array of Phase-3 agent identifiers **actually launched** this iteration, captured at Step 1's Phase 3.1 dispatch *after* Phase 0.5 gating (so a gated-out `pr-test-analyzer` / `type-design-analyzer` is absent). It is load-bearing for the Loop Exit effectiveness trace: a `null` verdict (dispatched but silent) is derived as `phase3_dispatched − (agents present in phase3_findings)`, so without this roster a silent agent is indistinguishable from one that was never launched. The field is best-effort — if it is absent on an older/partial workpad, the trace degrades to classifying only the agents that appear in `phase3_findings`. (In the example above `pr-test-analyzer` appears in `phase3_dispatched` even though `diff_profile` records only `has_new_types: true`: `pr-test-analyzer` is gated by the **test-relevance predicate**, which is not a `diff_profile` flag, so its presence cannot be cross-checked against the profile — this is the same asymmetry the too-narrow tripwire relies on when it keys off `phase3_dispatched` rather than `diff_profile`.)

Use the **same identifier string** in `phase3_dispatched` that you write to each finding's `phase3_findings.agent`, so the trace can match dispatch to outcome. For the five first-party review agents that is `devflow:<name>` (e.g. `devflow:code-reviewer`). For the sixth Phase-3 dispatch — the general-purpose final-pass reviewer launched via `Task`/`subagent_type: general-purpose` invoking `/devflow:requesting-code-review` (see /devflow:review's Phase 3.1) — record it as **`devflow:requesting-code-review`** in both places, so this (most expensive) dispatch is tallied consistently rather than appearing under an ad-hoc string each run.

`diff_profile` records the engine's Phase 0.5 classification for this iteration — the four profile-shaping flags (`small_diff`, `config_only`, `has_new_types`, `engine_self_modifying`) plus a nested `checklist_skipped` member (`"intentional"` when Phase 0.5 bypassed Phase 1+2 on a small_diff+config_only diff, `"failure"` when checklist generation failed, else `null`) — so the checklist-skip tripwire's `diff_profile.checklist_skipped` read resolves against the nested field shown in the schema example, not a sibling. (Phase 0.5's fifth flag, `detect_all_audit`, is intentionally **not** persisted here: it never alters the engine profile — it only forces the Phase 3.1.5 completeness-critic pass — so it has no `diff_profile` consumer.) It is load-bearing for fair cross-run analysis in two ways: (1) a `null`-verdict agent on a `config_only` diff is *correctly* silent (out of its domain), not a cut candidate — the analyzer must segment by diff shape, and this is how it learns the shape; (2) it lets the trace report the orchestrator's **verification posture** — when Phase 0.5 skips the checklist, or when every verifiable item was resolved via the cheap orchestrator-direct `lite` path instead of dispatching verifier subagents, that is a deliberate cost-saving decision and the trace says so explicitly rather than rendering a bare "0 verifiers". Best-effort: if `diff_profile` is absent, the trace labels the profile "not recorded" and the posture falls back to the raw lite/agent counts.

`cap_drops` is populated from /devflow:review's Phase 1.1.5 output (see that skill's Phase 1.1.5 for the shape — `count` is the total dropped at the 100-item cap, `by_category` is the per-category breakdown). The Coverage section in the final report reads this.

`current_step`, `current_substep`, and `pending_dispatch` are the **durable continuation operands** (issue #530): the run-scoped record — not agent recall — is the authoritative source of *where in the loop this run is*, so a compacted or resumed run recovers its position by reading them rather than by remembering it. `current_step` is the loop-step id whose procedure is currently executing (e.g. `"2.5"`, `"2.6"`, `"3"`, `"3.5"`, `"4.5"`, `"loop-exit"` — the same ids the **Step routing** table below maps to reference files); `current_substep` is a coarse label within that step (e.g. `"run_shadow_fanout"`, `null` when none); `pending_dispatch` records an in-flight `Agent`/`Skill`/`Task` dispatch (its `kind`, `roster`, and `dispatched_at`) and is cleared to `null` once the dispatch has returned and been joined. These are **best-effort navigation stamps written with the Write tool at each step-transition and immediately before each dispatch** — additive to, and distinct from, the mandatory fused emits (Step 3 item 6/7 and the shadow-block append); a write failure here is logged, never blocking. They are **not** effectiveness/cost telemetry (`efficiency-trace.jq` gets no new consumer of them in this PR — the `reference_reads` read-evidence reconciliation is deferred to the follow-up), so they are excluded from the `ITER_EXPECTED_FIELDS` single-source divergence guard alongside `shadow`/`promotion_provenance`/`parked_class_sweep`. The **always-resident re-read rule** in the *Reference-loading contract* below reads `current_step`/`current_substep` to decide which reference to re-Read after every dispatch return.

`shadow` is populated by Step 2.6 (the shadow review pass). `coverage` is a pure roster measurement: it is `"full"` when the parent ran the complete multi-agent fan-out a standalone /devflow:review Phase 3 would launch (subject to the Phase 3.1 applicability gates) and `"not_verified"` when the fan-out could not be completed (outcome 3 — see Step 2.6 "Decide"). Prompt composition is measured separately by `prompt_addenda`; it gates outcome 1 and the clean-agreement renders, never `coverage` or outcome 2. `reviewers_dispatched` is the roster of Phase-3 reviewer agents the parent actually launched for the shadow (same identifier strings as `phase3_dispatched`). It is only present on the workpad of the iter that triggered the shadow — typically the iter with the tentative non-REJECT verdict. Promoted-shadow iters (when the shadow surfaces new findings and triggers iter N+1 → Step 2.5) have their own workpad without a `shadow` block of their own unless they too produce a non-REJECT verdict that triggers another shadow.

### Lifecycle

- **Iter 1 start:** create the run-scoped directory `.devflow/tmp/review/<slug>/<run-id>/` if missing (using the `RUN_ID` computed once at loop start). There is no prior iteration to read.
- **Iter N start (N≥2):** before doing anything else, read `iter-<N-1>.json`. The fix-delta handoff (Step 0.9) and convergence check both consume it. If the file is missing or unreadable, log a warning and continue without the handoff optimizations (Phase 1 generator runs without the prior-checklist variance-recovery block; Phase 2.0.5 reuses nothing; Phase 3 runs without prior-findings context). Phase 1+2+3 still run — they always do.
- **Iter N end — non-optional emit, fused to the fix commit:** write `iter-<N>.json` with everything collected during the iteration. The write is **anchored to Step 3 item 6's fix-commit moment** (capture `fix_commit_sha`, then Write, as one step) — the one mechanical point every fix iteration necessarily passes through — rather than deferred to a separate end-of-iteration step, so an inline-driven loop has no seam in which to lose it. Writing this per-iteration record is **mandatory on every iteration regardless of how the loop was executed** — whether this loop ran as a `Skill` invocation or was hand-run via direct `Agent` dispatch on a degraded path — and it is written **with the Write tool, never a shell `>`/heredoc redirect** (a shell redirect into `.devflow/tmp` is not dependable from this loop's profile — the in-workspace `>` redirect of a granted head that the read-only review profile permits, e.g. `/devflow:review` Phase 1.1/4.5, does not generalize here; use the Write tool); leaving the instrumented loop is never license to skip it. The `lib/efficiency-trace.sh --persist` synthesis backstop (issue #381) is a *floor* that reconstructs a minimal record from the fix commits when this emit is dropped — never license to skip it. See Step 3 item 7 for the full record shape and fields.
- **Step 2.6 end (shadow pass) — non-optional emit, fused to the pass's termination:** when the shadow review pass runs, append the `shadow` block to the latest iter's workpad (re-writing `iter-<N>.json` with the shadow result included) with the **Write tool**. This is **mandatory on every shadow pass regardless of how the loop was executed**, and it is fused to the moment the pass *terminates* — covering **both** termination paths (Parse-and-compare completion for a full fan-out, and the honest-degradation fail-safe for an outcome-3 pass that dies mid-fan-out) — exactly as Step 2.6 → "Shadow workpad record" specifies; the `--persist` shadow synthesis floor (issue #426) is its backstop, not license to skip it. If the shadow promotes new findings into iter (N+1), iter (N+1) is a normal iter from a lifecycle standpoint — it will write its own `iter-<N+1>.json` per the regular end-of-iter rule.

The workpad is best-effort and informational. A write failure should not abort the loop — log it and continue.

---

## Main Loop

**Expired-credential fail-fast (two strikes, never open-ended retry — issue #487).** A cloud writer-job run rides a GitHub App installation token that expires 60 minutes after job start; a fix loop that outlives that lifetime finds every `git push` and `gh` call rejected with a bad-credential error and can burn budget retrying. A background credential refresher normally keeps the credentials fresh, but it can be defeated by sustained mint failure, so this is the last line of defense: **after two consecutive `git push` or `gh` failures whose output carries the bad-credential signature — HTTP `401`, `Bad credentials`, or `Authentication failed` — stop retrying that operation** (do not try a third variant), record the cause in the loop's own record/workpad, and exit the loop reporting the expired-credential cause rather than iterating on it — the same two-strikes discipline the command-shape rules already use. This prose rule is best-effort under context compaction (a >60-minute run is the maximally compaction-likely population); its compaction-immune sibling is the `gh-fresh.sh` wrapper, which appends a distinctive `devflow-gh-fresh: … expired/bad credential` diagnostic line to stderr at every `gh` call that fails with the bad-credential signature.

**Resolve the iteration cap once, at loop start.** Read `devflow_review_and_fix.max_iterations` (default 5) via the config helper — the same portable skill-dir-anchored, no-`bash`-prefix invocation the effectiveness-trace gate uses (see "Subagent effectiveness trace"), so the read is cwd-independent and the resolved-path allow-list entry matches. Discriminate a resolver failure (missing `python3`, malformed `config.json` → non-zero exit with empty stdout) from a legitimately-absent key with a single-statement `if !` (reading config-get's own exit status inline, never a captured rc read in a later statement), and clamp the result:

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
- **REJECT-driver widening (applies on every REJECT and every threshold combination).** The loop's **effective fix set** is: every finding at or above `$FIX_THRESHOLD` **PLUS every finding that drove the engine's REJECT** under `devflow_review.verdict_severity_threshold` (i.e. at or above the verdict threshold, excluding deferral-demoted findings) — even when that REJECT-driver is *below* `$FIX_THRESHOLD`. So a `verdict_severity_threshold` more inclusive than `$FIX_THRESHOLD` (e.g. verdict `suggestion`, fix `important`) never deadlocks the loop: the fixer can always act on whatever blocks convergence, and **no configuration combination produces a REJECT the fixer is configured to ignore**. These REJECT-drivers route through Step 2.5 → Step 3 exactly like any other fixable finding.
- Engine verdict **REJECT** → continue to Step 2.5. (REJECT verdicts never reach the shadow pass — the loop is still finding things to fix; let it converge first.)


## Step routing (which reference implements each step)

Steps 2.5 through Loop Exit are **step references** — their authoritative procedure lives in a file under `skills/review-and-fix/references/` and is loaded at step entry (the *Reference-loading contract* below governs how). This root retains the invocation contract, the shared `### Schema`/`### Lifecycle`, the Main-Loop control, Steps 0.5/0.9/1/2/4, routing, terminal mapping, and fail-closed handling; it never paraphrases a reference's procedure. When a step's prose above or in a reference names "Step N.M", resolve it to its reference via this table.

| Step (`current_step`) | Reference file | Fires when |
| --- | --- | --- |
| `2.5` — Pre-fix verification gate + Parked-class sweep | `references/pre-fix-gates.md` | Step 2 routed to a fix path (REJECT, a REJECT-driver, or an at-or-above-`$FIX_THRESHOLD` finding), **or** a tentative non-REJECT verdict carries parked findings needing the pre-shadow parked-class sweep |
| `2.6` — Shadow review | `references/shadow-review.md` | a tentative non-REJECT verdict at convergence time, **or** the `engine_self_modifying` early-shadow trigger after iteration 1 |
| `3` — Fix Findings | `references/fixing.md` | after the Step 2.5 gate resolves the effective fix set |
| `3.5` — Fix-delta verification gate | `references/fix-delta-gate.md` | every iteration that committed a fix (unconditional; skipped on iter 1's no-prior-fix state) |
| `4.5` — Convergence check | `references/convergence.md` | before looping back to Step 1, on iteration ≥ 2 |
| `loop-exit` — Loop Exit | `references/loop-exit.md` | the loop terminates (converged, capped, or final REJECT) |

## Reference-loading contract (fail-closed)

Every step reference loads at entry, **before any action in that step**, and a reference that cannot be loaded whole takes the mapped fail-closed outcome below — never an improvised step from memory of an earlier read or from this table's one-line stub.

**Entry-gate read shape** (mirrors `skills/implement/SKILL.md`'s phase entry-gates):

1. **Stamp the position** (best-effort Write, non-blocking): set `current_step` (and `current_substep` when meaningful) in the active `iter-<N>.json` before reading the reference, so a compacted/resumed run recovers where it is from the record, not recall.
2. **Read the reference.** Resolve the skill directory per the *Portable helper anchor* rule at the top of this file and `Read` `<skill-dir>/references/<name>.md` (the vendored-consumer layout resolves the same path).
3. **Completeness check — the single ordered start/end boundary rule.** The returned content's first non-blank line MUST be the reference's canonical `# Reference: <title>` heading and its last non-blank line MUST be the canonical `<!-- END <name>.md -->` marker, **each occurring exactly once, in that order**. A `Read` failure, an empty result, a truncated result, a result missing either marker, a **duplicated** marker, a **reversed** order (END before START), or a marker at a **noncanonical** position (not at the document edge) all mean **reference unreadable** and take the failure-map row below.
4. On success, execute the reference's procedure. On failure, apply the failure-map row — do not proceed into the step.

**Failure-map (per reference — fail-closed; each degrades exactly as the engine already degrades on the equivalent runtime failure):**

| Unreadable reference | Outcome |
| --- | --- |
| `pre-fix-gates.md` | **STOP before any mutation.** No fix may be attempted without gate coverage. Record a `blocked`-kind reflection naming the reference; the loop reports non-convergence. |
| `shadow-review.md` | Record `shadow.coverage: "not_verified"` on the active iter (the existing outcome-3 shape) and proceed to Loop Exit with the tentative verdict reported not-verified — **prohibits a clean approve**. |
| `fixing.md` | **STOP before any mutation.** Never apply a fix blind. Record a `blocked`-kind reflection; the loop reports non-convergence. |
| `fix-delta-gate.md` | Record a not-verified fix-delta outcome (the existing gate-subagent-failure shape) that **prohibits a clean APPROVE-family verdict** for this run — the same effect as an unresolved over-grade flag. (The formal `reference_reads.fix_delta` schema field is deferred to the AC8 follow-up; the behavioral outcome is delivered here.) |
| `convergence.md` | Treat as "a convergence condition failed" — never early-exit: loop back to Step 1 for iteration N+1, or at the cap proceed to Loop Exit reporting non-convergence. Mark non-convergence explicitly. |
| `loop-exit.md` | Run the persistence backstop directly (`lib/efficiency-trace.sh --persist`) to floor the telemetry record, record an **incomplete terminal state** reflection, and emit a generic non-clean chat message instead of any APPROVE-family template — **prohibits a clean approve**. |

**Always-resident re-read rule (issue #530 — this block never leaves the root, for eviction resistance).** After **every** `Agent`/`Task`/`Skill`-tool return that occurred while executing a reference's procedure (a Phase-3 dispatch inside Step 1, a shadow reviewer inside `shadow-review.md`, the blinded subagent inside `fix-delta-gate.md`, and any other), and **before taking the next cross-reference routing action**, re-`Read` the currently-active reference — identified by `current_step`/`current_substep` in the active `iter-<N>.json`, **not** by conversational memory — and resume the interrupted substep. Never re-dispatch the agent/skill that just returned (the same do-not-re-dispatch idempotency the implement orchestrator's re-anchor carries). The durable operands are the step predicate; **agent recall is never the sole predicate**.

### Step 4: Continue Loop

Output: `Fixed {N} issues, skipped {M}. Re-running review...`


## Terminal verdict → chat output (mapping)

This is the externally-visible terminal contract — which converged verdict produces which chat outcome — that downstream callers (e.g. `/devflow:implement` Phase 3.3) rely on. The **authoritative rendering** (headline templates, finding/advisory counts, deferrals-manifest surfacing, the coverage/telemetry appendix) lives in `references/loop-exit.md` under "Verdict → chat output"; this table is the routing summary and may only be rendered **after** `references/loop-exit.md`'s Pre-mapping gates have run and written their verdict/sentinel (see the *Step routing* table's `loop-exit` row).

| Converged verdict | Terminal chat outcome |
| --- | --- |
| `APPROVE` | clean approve — reported only when the shadow pass recorded `coverage: "full"` and no gate prohibits a clean approve |
| `APPROVE WITH ADVISORY NOTES` | approve, surfacing the parked advisory findings |
| `APPROVE WITH CAVEAT` | approve, surfacing the verification-coverage caveat (incl. shadow `not_verified`) |
| `REJECT` | non-clean — the loop exhausted its cap without converging, or a Pre-mapping gate downgraded to REJECT |
| incomplete / not-verified (any fail-closed reference outcome above) | a generic non-clean message; **never** an APPROVE-family template |

## Error Handling

- **Agent failures**: Treat as INCONCLUSIVE or note in report. Never abort the entire review. **Exception — shadow reviewers (Step 2.6):** this lenient rule does NOT apply to a shadow-pass reviewer failure. A shadow reviewer that fails, returns garbage, or is absent from the dispatched roster is a coverage shortfall that forces `coverage: "not_verified"` / outcome 3 (the shadow's fail-closed contract) — it must never be silently treated as INCONCLUSIVE-and-proceed, because that re-opens the false-clean path Step 2.6 exists to close. The *one* bounded concession (see Step 2.6 outcome 3's *Transient vs. structural* rule): a single transiently-failed reviewer gets exactly one targeted re-dispatch before `not_verified` is recorded; structural failures and any second/multi-reviewer failure are immediate `not_verified` with no retry. This is a single bounded retry, not the lenient INCONCLUSIVE-and-proceed path.
- **Test failures after fixes**: Fix the test failures before re-running the review loop.
- **Commit failures**: If a commit fails (e.g., pre-commit hook), fix the issue and retry the commit.
- **Cannot locate /devflow:review's SKILL.md**: Fatal **only when both** the primary Glob (`**/devflow/skills/review/SKILL.md`) **and** the repo-own fallback (`skills/review/SKILL.md`, the devflow-self / self-review case — see Step 1) fail to resolve a readable file. If the Glob misses but the fallback resolves, that is the normal self-review path — proceed, do not error. When both miss, error out with a clear message; do not improvise by paraphrasing the phases, and do not silently fall back to a stale plugin-cache copy. (See "Engine source of truth" and the self-review callout in Step 1.)

---

## Common Mistakes

- **Dropping the Loop Exit observability-persistence steps when this skill is driven interactively/inline by an orchestrator** (rather than as a discrete end-to-end invocation). The fix loop, shadow passes, and fixes all run correctly, but the final *bookkeeping* — Step 3, item 6's fused per-iteration `iter-<N>.json` write (record shape in item 7), the effectiveness-trace render, and the `--persist` write of the record + durable workpad copy to the telemetry branch — gets silently skipped, leaving a hole in the telemetry dataset that **no backstop DevFlow currently ships reconstructs** — the synthesis floor below recovers only an effectiveness skeleton from the fix commits, and nothing that ships reconstructs the per-phase **cost** half at all, which this loop alone captures live. These steps are **mandatory on every writable run**, not best-effort-optional. This applies with equal force to the sibling bypass this entry originally under-named: when the orchestrator does not invoke this Skill at all but **hand-runs the review engine via direct `Agent` dispatch** on a degraded path (e.g. under cloud `claude-code-action` friction), the per-iteration `iter-<N>.json` write (Step 3, item 6; record shape in item 7) is still mandatory on that path — a permission/sandbox denial is not license to leave the instrumented loop. Layered backstops guard this: write each `iter-<N>.json` fused to its fix commit (Step 3, item 6) so the data survives a dropped Loop Exit; run the Loop Exit **Persistence self-check** so a drop is at least loud; and rely on the deterministic `lib/efficiency-trace.sh --persist` backstop (the `Stop` hook locally, the cloud-workflow wrapper in CI) that re-derives the artifacts from the on-disk workpads and persists them to the telemetry branch regardless of what the agent did — and, when even the workpads are gone, **synthesizes a minimal iteration record from the fix commits** (issue #381) so a fully-dropped run still contributes a floor. **That synthesis floor is a safety net, not license to skip the emit:** it recovers only the effectiveness half (`iter` / `fix_commit_sha` / `fix_files` / `loop_role` / `synthesized: true`) and none of the checklist / findings / per-phase cost detail the real record carries — none of that detail is recoverable **from the fix commits** this floor reads. Never treat "the loop converged and I reported the verdict" as the finish line — persistence is part of the run.
- Trying to skip Step 2.6 because iter N looked clean — the whole point of the shadow pass is that iter N's quietness might be undersampling. A clean iter that didn't survive shadow audit is not convergence.
- Re-posting the loop's verdict to GitHub via `gh pr review` from inside the loop — this skill is silent on GitHub by design; the user runs `/devflow:review <PR>` separately for a formal merge signal.
- Confusing Step 0.9's narrow-reuse signals with a wholesale Phase 1+2 skip — Phase 1+2 always re-run on iter ≥ 2; Step 0.9 only stages reuse INPUTS (see the rationale block in Step 0.9 itself).
- Fixing only the literal instance a finding reports and leaving its `defect_signature.kind` siblings in the same diff for the shadow pass to rediscover — that converts one free deterministic sweep (Step 3, item 3) into multiple doubled-cost shadow promotions. Generalize every finding to its class and sweep the changed surface before committing.
