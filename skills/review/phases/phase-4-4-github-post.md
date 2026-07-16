<!-- devflow:review-ref phase=4.4 file=skills/review/phases/phase-4-4-github-post.md start -->
### 4.4 Record the verdict as a formal GitHub review (PR mode only)

**If — and only if — `$ARGUMENTS` is a PR number** (you are reviewing an actual PR, not the current branch), you MUST also submit the verdict as a formal GitHub Pull Request review so it becomes a visible merge signal. A REJECT verdict that lives only in a comment or in chat output is routinely missed — the PR gets marked ready and merged with the rejection still outstanding. A `--request-changes` review blocks the merge button (or, at minimum, forces an explicit dismissal), which is the behavior we want.

Map the verdict to a `gh pr review` action. **What goes in `--body` depends on whether a progress comment already carries the full report** — set `$BODY` accordingly. The discriminator is *"does a progress comment carrying the full report exist for this run?"* — i.e. **did the skill author the live progress comment this run (`$WP` set)?** — NOT `$GITHUB_ACTIONS`. The skill is now the **sole** author of that comment in every context: `devflow-review.yml` no longer seeds one (it defers to Phase 0.3.5), and the skill authors it even in a standalone local PR-mode run. So keying on `$GITHUB_ACTIONS` would be wrong in two directions — it would double-post locally (where it is false but the skill seeded), and, worse, in a cloud run with `live_progress_comment_enabled = false` (or where the Phase 0.3.5 seed failed) it would be *true* while **no** comment carries the report, leaving the stub pointing at a comment that does not exist and the full report posted nowhere. `$WP` is the single authoritative signal.

- **A progress comment carries the report** — true when the skill authored the live progress comment this run (PR mode AND `devflow_review.live_progress_comment_enabled` AND the Phase 0.3.5 seed succeeded, i.e. **`$WP` is set**), in cloud or local alike. The full Phase 4.1 report already lives in that comment, so the review body is a short verdict-only **stub**; putting the full report in both places forces reviewers to scroll past two copies. Set `$BODY` to `$STUB`:

  ```
  ## Verdict: {VERDICT} — full report in PR comment

  > The complete review report (checklist results, findings, details) is in the
  > Devflow Review progress comment on this PR.
  ```

- **No progress comment exists** — **`$WP` is unset**: the live comment is **off** (`live_progress_comment_enabled` false), its seed failed, or this is current-branch/non-PR mode. This now includes **cloud runs with the flag off** (the workflow no longer seeds a fallback comment), not just standalone local runs. A stub would point at a comment that does not exist and the full report would live only in chat (lost entirely in a cloud run), so set `$BODY` to the full `$REPORT` from Phase 4.1 — one self-contained artifact, no dangling pointer. (The full report begins with its `## Verdict: {VERDICT}` line, so a standalone REJECT starts with `## Verdict: REJECT` — the exact prefix `dismiss-stale-rejections.sh` matches, so a standalone REJECT is still cleared by a later APPROVE.)

where `{VERDICT}` is the actual verdict line (e.g. `APPROVE`, `APPROVE with notes`, `APPROVE WITH CAVEAT`, `REJECT`) — reflect what Phase 4.2 decided, do not template-fill literally. The `## Verdict: {VERDICT}` line is load-bearing: `finalize_check` (via `scripts/derive-review-verdict.sh`, issue #249) greps for it in the **HEAD-scoped `gh pr review` body** and in **this run's run-keyed `devflow:review-progress` progress comment** (both scoped to the current HEAD SHA / run). It appears as the stub's first line AND as a `## Verdict: {VERDICT}` line inside the full `$REPORT`, so the grep matches in either. Note the marker-less `gh pr comment` self-review fallback (below) is **no longer** read by `finalize_check` — the current-HEAD scoping deliberately supersedes the old un-scoped "grep every issue comment" path; in the narrow case where that fallback is the *only* verdict artifact (no progress comment AND `gh pr review` failed) a REJECT concludes the blocking `incomplete` (re-run needed) rather than `reject`, which still blocks the merge.

| Verdict | Command |
|---|---|
| **REJECT** (any form) | `gh pr review $ARGUMENTS --request-changes --body "$BODY"` |
| **APPROVE WITH CAVEAT** / **APPROVE with notes** | `gh pr review $ARGUMENTS --comment --body "$BODY"` |
| **APPROVE** (clean, no findings) | `gh pr review $ARGUMENTS --approve --body "$BODY"` |

A REJECT driven by the Phase 4.2 self-contradicting-diff carve-out is a **REJECT (any form)** like any other, so it maps to `gh pr review $ARGUMENTS --request-changes` via the first row above — there is no separate branch for it.

If `gh pr review` fails (e.g. you cannot review your own PR as the same GitHub identity, or the token lacks permission), fall back to `gh pr comment $ARGUMENTS --body "$REPORT"` — use the full `$REPORT` here (not `$STUB`), since this fallback comment is the only artifact in that path. Note in your chat output that the formal review could not be posted. **Never silently skip this step on a REJECT** — the whole point is that the rejection must be impossible to miss.

**Then, on any APPROVE form only (APPROVE / APPROVE with notes / APPROVE WITH CAVEAT), clear a stale REJECT.** A prior REJECT's `--request-changes` review stays the PR's effective `reviewDecision` until *dismissed*; the APPROVE-with-notes `--comment` review never supersedes it, and the REJECT may be a different bot identity (auto path posts as `github-actions[bot]`, manual `@claude` as another), so no later review clears it either. Without this the PR is wedged at `reviewDecision: CHANGES_REQUESTED` forever, contradicting the green check and this APPROVE. The script dismisses **only Devflow Review's own reports** (body marker), never a human reviewer's `--request-changes`. On REJECT, **skip this** — the changes-request must stand. Run (re-run safe):

```bash
"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/dismiss-stale-rejections.sh "$ARGUMENTS"
```

If it exits non-zero (token scope), say so in chat output and that the PR stays blocked until dismissed manually. **A dismissal failure never downgrades the verdict** — the verdict stands; only merge-gate housekeeping failed.
<!-- devflow:review-ref phase=4.4 file=skills/review/phases/phase-4-4-github-post.md end -->
