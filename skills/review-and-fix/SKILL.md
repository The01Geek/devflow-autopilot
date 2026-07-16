---
name: review-and-fix
description: Use when you need findings on a PR or current branch to be auto-applied, not just reported.
argument-hint: "[pr-number] [--push-each-iteration]"
---

# /devflow:review-and-fix — Review, Fix, and Verify Loop

You are the review-and-fix orchestrator. Run /devflow:review's review engine, fix the findings it surfaces, and re-run until the engine returns a clean verdict.

**Input:** `$ARGUMENTS` may contain an optional PR number and/or the flag `--push-each-iteration`. Parse the two independently — either, both, or neither may be present (`863`, `--push-each-iteration`, `863 --push-each-iteration`, or empty). If no PR number is given, review and fix the current branch. The numeric token (if any) is `$PR_NUMBER` throughout this skill.

**`--push-each-iteration` (default off).** When set, the loop `git push`es after each iteration's fix commit (Step 3, item 6) so the remote PR branch and its CI track every iteration, and each iteration's push plus the Loop-Exit push run through the base-branch update checkpoint (`scripts/update-branch-checkpoint.sh`, Checkpoint 3, issue #448, gated by `devflow_implement.update_branch_checkpoints`). When absent (the default for direct users), fix commits stay local and the base is never touched. Either way the flag never posts a verdict to GitHub — the skill is silent on verdicts by design (see *Engine source of truth*) — and Loop Exit's mandatory `--persist` still pushes the `devflow-telemetry` branch on every writable run (see *Persisting observability artifacts*). `/devflow:implement` sets it at Phase 3.3 (a live draft PR with CI). Loop correctness is orthogonal: the loop sees its own fixes regardless (current-branch mode diffs local `HEAD`; PR mode uses Step 1's head-override).

**Key principle:** You perform fixes DIRECTLY in this session. Do NOT delegate fixes to a subagent. You need full conversation context to apply `devflow:receiving-code-review` principles (technical evaluation, pushback, verification).

**Portable helper anchor (single-statement).** The bundled-helper commands in this skill resolve the skill directory inline at each call site via `${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}`. When `$CLAUDE_SKILL_DIR` is set and non-empty (Claude Code), run each command exactly as written. On a runner where it is unset or empty, replace the placeholder with the skill base directory the runner reports in context (e.g. a `Base directory for this skill:` line) before running the command; if that reported path is Windows-form (`C:\...`), first convert it to this shell's POSIX form with one standalone `wslpath -u '<path>'` (WSL) or `cygpath -u '<path>'` (Git Bash/MSYS2) command and substitute the printed result **only if the command succeeds and prints a non-empty path — otherwise fall through to the drive-letter rules exactly as if the tool were absent, the same success-and-non-empty acceptance the platform's path-normalization rules apply** (if neither tool exists: lowercase the drive letter, map `C:\` to `/mnt/c` on WSL or `/c` on MSYS2, and turn backslashes into `/`; if the environment is neither WSL nor MSYS2, use the path unchanged and report that it could not be normalized — the same arm the platform's path-normalization rules take). Resolve the anchor inline at every call site — never capture it into a shell variable that a later statement reads, because some runners' inline-bash marshaling drops such variables (observed on Copilot CLI). If neither `$CLAUDE_SKILL_DIR` nor a runner-reported base directory is available, stop and report that the helper anchor could not be resolved rather than running a command with a broken path.

**Consumer prompt extension (load first).** Before doing this skill's work, load any consumer-supplied prompt extension for this skill and honor it. From the repo root, run:

```bash
"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/load-prompt-extension.sh review-and-fix
```

If the helper path is missing (`No such file`/exit 127), that is the **anchor-resolution** failure in the *Portable helper anchor* note above — fix the anchor, don't report a missing extension. Any other non-zero exit means a consumer extension exists but could not be loaded — surface its stderr and do not proceed silently. Exit 0 with output: treat the text as consumer-owned instructions appended to this skill's prompt (committed under `.devflow/prompt-extensions/`). Exit 0 with no output: proceed unchanged.


## Engine source of truth

This skill wraps /devflow:review's four-phase engine in a fix loop. Phases 0 through 4.3 — setup, diff classification, checklist generation, checklist verification, review agents (with the exact per-agent prompts and the `defect_signature` contract), and aggregation — live in `/devflow:review`'s SKILL.md and are authoritative. Read them on every Step 1; never improvise the engine or paraphrase the Phase 3 prompts. Drift between the two skills is the single biggest cause of /devflow:review-and-fix missing findings that /devflow:review caught.

This skill **skips** /devflow:review's Phase 4.4 entirely — no GitHub post. The final report is emitted to chat only; the human reviewer decides whether to convert it into a formal merge signal by running `/devflow:review <PR>` separately. On top of the engine it adds the loop wrapper documented in the references: a **fix-delta handoff** (Step 0.9), a run-scoped **persistent workpad** (`.devflow/tmp/review/<slug>/<run-id>/iter-<N>.json`), a **shadow review pass** (Step 2.6), a **`## Coverage` section** and **per-phase telemetry summary** at Loop Exit.

**Maintainer rule.** Engine changes belong in /devflow:review's SKILL.md; this file should only touch the loop wrapper, the workpad, the fix-delta handoff (Step 0.9), the Step 2.5 verification gate, the Step 2.6 shadow review, the fix step, the convergence check, the telemetry summary, or Loop Exit's chat output. **Violating the letter of these phases is violating the spirit** — even when a paraphrase looks faithful, the downstream agents are calibrated to /devflow:review's exact wording.

---


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

**Field semantics** — `loop_role`, `phase3_dispatched`, `diff_profile`, `cap_drops`, `shadow`, and the durable operands `current_step`/`current_substep`/`pending_dispatch` — are documented in `references/loop-control.md` (*Schema field semantics*). `ITER_EXPECTED_FIELDS` in `lib/efficiency-trace.sh` is the single-source set the unconditional top-level fields mirror.

### Lifecycle

- **Iter 1 start:** create the run-scoped directory `.devflow/tmp/review/<slug>/<run-id>/` if missing (using the `RUN_ID` computed once at loop start). There is no prior iteration to read.
- **Iter N start (N≥2):** before doing anything else, read `iter-<N-1>.json`. The fix-delta handoff (Step 0.9) and convergence check both consume it. If the file is missing or unreadable, log a warning and continue without the handoff optimizations (Phase 1 generator runs without the prior-checklist variance-recovery block; Phase 2.0.5 reuses nothing; Phase 3 runs without prior-findings context). Phase 1+2+3 still run — they always do.
- **Iter N end — non-optional emit, fused to the fix commit:** write `iter-<N>.json` with everything collected during the iteration. The write is **anchored to Step 3 item 6's fix-commit moment** (capture `fix_commit_sha`, then Write, as one step) — the one mechanical point every fix iteration necessarily passes through — rather than deferred to a separate end-of-iteration step, so an inline-driven loop has no seam in which to lose it. Writing this per-iteration record is **mandatory on every iteration regardless of how the loop was executed** — whether this loop ran as a `Skill` invocation or was hand-run via direct `Agent` dispatch on a degraded path — and it is written **with the Write tool, never a shell `>`/heredoc redirect** (a shell redirect into `.devflow/tmp` is not dependable from this loop's profile — the in-workspace `>` redirect of a granted head that the read-only review profile permits, e.g. `/devflow:review` Phase 1.1/4.5, does not generalize here; use the Write tool); leaving the instrumented loop is never license to skip it. The `lib/efficiency-trace.sh --persist` synthesis backstop (issue #381) is a *floor* that reconstructs a minimal record from the fix commits when this emit is dropped — never license to skip it. See Step 3 item 7 for the full record shape and fields.
- **Step 2.6 end (shadow pass) — non-optional emit, fused to the pass's termination:** when the shadow review pass runs, append the `shadow` block to the latest iter's workpad (re-writing `iter-<N>.json` with the shadow result included) with the **Write tool**. This is **mandatory on every shadow pass regardless of how the loop was executed**, and it is fused to the moment the pass *terminates* — covering **both** termination paths (Parse-and-compare completion for a full fan-out, and the honest-degradation fail-safe for an outcome-3 pass that dies mid-fan-out) — exactly as Step 2.6 → "Shadow workpad record" specifies; the `--persist` shadow synthesis floor (issue #426) is its backstop, not license to skip it. If the shadow promotes new findings into iter (N+1), iter (N+1) is a normal iter from a lifecycle standpoint — it will write its own `iter-<N+1>.json` per the regular end-of-iter rule.

The workpad is best-effort and informational. A write failure should not abort the loop — log it and continue.

---


## Running the loop

The loop control — config resolution, Iteration Start, Step 0.5 (PR-mode branch sync), Step 0.9 (fix-delta handoff), Step 1 (run the engine — load `/devflow:review`'s SKILL.md), and Step 2 (check verdict) — lives in `references/loop-control.md`. Load it at loop entry per the *Reference-loading contract*, follow it, and from Step 2's verdict route to the step references via the **Step routing** table below. Like every reference it is loaded on demand, not held resident.

## Step routing (which reference implements each step)

Every loop step's authoritative procedure lives in a file under `skills/review-and-fix/references/` and is loaded at step entry (the *Reference-loading contract* below governs how); the root retains the invocation contract, `### Schema`, `### Lifecycle`, routing, terminal mapping, and fail-closed handling, and never paraphrases a reference's procedure. When any prose names "Step N.M", resolve it to its reference via this table.

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
| `loop-control.md` | The loop spine (config, Iteration Start, Steps 0.5/0.9/1/2), loaded at loop entry: **STOP before any mutation** — the loop cannot run the engine or a fix without it. Record a `blocked` reflection; report non-convergence. |
| `error-handling.md` | Contextual guidance (When NOT to use / Error Handling / Common Mistakes), not a loop step — **best-effort**: log and continue; its absence degrades only guidance, never a gate. |

**Always-resident re-read rule (issue #530 — never leaves the root, for eviction resistance).** After **every** `Agent`/`Task`/`Skill`-tool return while executing a reference's procedure, and **before the next cross-reference routing action**, re-`Read` the active reference — identified by `current_step`/`current_substep` in the active `iter-<N>.json`, **not** by conversational memory — and resume the interrupted substep; never re-dispatch the agent/skill that just returned. The durable operands are the step predicate; **agent recall is never the sole predicate**.


### Step 4: Continue Loop

Output: `Fixed {N} issues, skipped {M}. Re-running review...`



## Terminal verdict → chat output (mapping)

The externally-visible terminal contract — which converged verdict produces which chat outcome — that downstream callers (e.g. `/devflow:implement` Phase 3.3) rely on. The authoritative rendering (headlines, counts, deferrals manifest, coverage/telemetry appendix) lives in `references/loop-exit.md` under *Verdict → chat output*, and may only be rendered **after** its Pre-mapping gates have run (see the *Step routing* `loop-exit` row).

| Converged verdict | Terminal chat outcome |
| --- | --- |
| `APPROVE` | clean approve — only when shadow `coverage: "full"` and no gate prohibits it |
| `APPROVE WITH ADVISORY NOTES` | approve, surfacing the parked advisory findings |
| `APPROVE WITH CAVEAT` | approve, surfacing the verification-coverage caveat (incl. shadow `not_verified`) |
| `REJECT` | non-clean — cap exhausted without converging, or a Pre-mapping gate downgraded |
| incomplete / not-verified (any fail-closed reference outcome above) | a generic non-clean message; **never** an APPROVE-family template |


See `references/error-handling.md` for *When NOT to use*, *Error Handling*, and *Common Mistakes*.

