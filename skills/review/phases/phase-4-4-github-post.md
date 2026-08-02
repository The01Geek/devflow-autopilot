<!-- prflow:review-ref phase=4.4 file=skills/review/phases/phase-4-4-github-post.md start -->
### 4.4 Record the verdict as a formal GitHub review (PR mode only)

**If — and only if — `$PR_NUMBER` is a PR number** (an actual PR, not the current branch), you MUST also submit the verdict as a formal GitHub Pull Request review, a visible merge signal.

**This gate, and every `gh` invocation in this phase, reads `$PR_NUMBER` — the PR number the skill root parsed out of `$ARGUMENTS` — and never the raw `$ARGUMENTS` string, because an extended argument string such as `123 --issue 456` fails the is-a-PR-number test, so a gate left reading the raw string silently skips the `gh pr review --request-changes` post and the merge-blocking signal this phase exists to guarantee is lost with no error.**
 A REJECT that lives only in a comment or chat output is routinely missed — the PR gets marked ready and merged with the rejection outstanding. A `--request-changes` review blocks the merge button (or at minimum forces an explicit dismissal), the behavior we want.

Map the verdict to a review **event** and post it through the bundled helper `scripts/post-review-verdict.sh` (issue #1059). **What goes in the review body depends on whether a progress comment already carries the full report** — set `$BODY` accordingly. The discriminator is **did the skill author the live progress comment this run (`$WP` set)?** — NOT `$GITHUB_ACTIONS`. The skill is the **sole** author of that comment in every context: no workflow seeds one, and the skill authors it even in a standalone local PR-mode run. Keying on `$GITHUB_ACTIONS` would be wrong in two directions: it would double-post locally (false but the skill seeded), and, worse, in a cloud run with `live_progress_comment_enabled = false` (or a failed Phase 0.3.5 seed) it would be *true* while **no** comment carries the report, leaving the stub pointing at a nonexistent comment and the report posted nowhere. `$WP` is the single authoritative signal.

- **A progress comment carries the report** — true when the skill authored the live progress comment this run (PR mode AND `prflow_review.live_progress_comment_enabled` AND the Phase 0.3.5 seed succeeded, i.e. **`$WP` is set**), cloud or local alike. The full Phase 4.1 report already lives in that comment, so the review body is a short verdict-only **stub**; duplicating it forces reviewers to scroll past two copies. Set `$BODY` to `$STUB`:

  ```
  ## Verdict: {VERDICT} — full report in PR comment

  > The complete review report (checklist results, findings, details) is in the
  > PRFlow Review progress comment on this PR.
  ```

- **No progress comment exists** — **`$WP` is unset**: the live comment is **off** (`live_progress_comment_enabled` false), its seed failed, or this is current-branch/non-PR mode. This now includes **cloud runs with the flag off** (the workflow no longer seeds a fallback comment), not just standalone local runs. A stub would point at a comment that does not exist and the report would live only in chat (lost entirely in a cloud run), so set `$BODY` to the full `$REPORT` from Phase 4.1 — one self-contained artifact, no dangling pointer. (It begins with its `## Verdict: {VERDICT}` line, so a standalone REJECT starts with `## Verdict: REJECT` — the exact prefix `dismiss-stale-rejections.sh` matches, so a standalone REJECT is still cleared by a later APPROVE.)

where `{VERDICT}` is the actual verdict line (e.g. `APPROVE`, `APPROVE with notes`, `APPROVE WITH CAVEAT`, `REJECT`) — reflect what Phase 4.2 decided, do not template-fill literally. The `## Verdict: {VERDICT}` line is load-bearing: a cloud caller's verdict-derivation step greps for it in the **HEAD-scoped `gh pr review` body** and in **this run's run-keyed `prflow:review-progress` progress comment** (both scoped to the current HEAD SHA / run). It appears as the stub's first line AND inside the full `$REPORT`, so the grep matches either. Note the marker-less `gh pr comment` self-review fallback (below) is **not** read by such a step — the current-HEAD scoping deliberately supersedes the old un-scoped "grep every issue comment" path; when that fallback is the *only* verdict artifact (no progress comment AND `gh pr review` failed) a REJECT concludes the blocking `incomplete` (re-run needed) rather than `reject`, which still blocks the merge.

Map the Phase 4.2 verdict to exactly one review **event** — the closed set GitHub's REST API accepts, which is all the helper accepts:

| Verdict | Review event |
|---|---|
| **REJECT** (any form) | `REQUEST_CHANGES` |
| **APPROVE WITH CAVEAT** / **APPROVE with notes** | `COMMENT` |
| **APPROVE** (clean, no findings) | `APPROVE` |

A REJECT driven by the Phase 4.2 self-contradicting-diff carve-out is a **REJECT (any form)** like any other, mapping to `REQUEST_CHANGES` via the first row above — no separate branch for it.

**Write `$BODY` to a file, then post it through the helper.** The helper takes the body as a **file path** (not an inline string), so a report containing backticks, `$(`, or literal double quotes reaches the API unmangled. Write `$BODY` to `.prflow/tmp/review-verdict-body.md` with the **Write tool** (not a shell redirect — the cloud matcher denies redirect shapes), then invoke the helper as a **single leading-token statement at the repo-relative vendored literal**, with the event and the body-file path in argument position — no leading `cd`, no `VAR=value` prefix, no unexpanded `${CLAUDE_SKILL_DIR:-…}` anchor in the leading token (any of those makes the command no longer *begin with* the granted literal and it is silently denied):

```bash
.prflow/vendor/prflow/scripts/post-review-verdict.sh "$PR_NUMBER" REQUEST_CHANGES .prflow/tmp/review-verdict-body.md
```

Substitute the mapped event (`APPROVE` / `REQUEST_CHANGES` / `COMMENT`) for the `REQUEST_CHANGES` token above. **Pass `"$PR_NUMBER"` here, never `"$ARGUMENTS"`: the quoted form reaches the helper as a single argv element, so an extended argument string like `123 --issue 456` would be handed over whole and rejected as non-numeric.** (On the local tier, resolve the `${CLAUDE_SKILL_DIR:-…}` anchor to `scripts/post-review-verdict.sh` as the leading token; the cloud tier uses the vendored literal exactly as written.)

**Read the helper's single outcome line and route on it (the vocabulary is closed and has no silent path):**

- **`POSTED <event>` (exit 0)** — the formal review exists. Continue exactly as today: **post no fallback comment**, and the `$BODY` stub-versus-full-report selection above stands unchanged.
- **`FAILED <error>` (exit 1)** — the API call was issued and refused; `<error>` is the captured, single-line cause. Take the **fallback arm** below, recording that error line.
- **`SKIP <reason>` (exit 3)** — the helper declined to issue the request (`not-numeric` / `unknown-event` / `body-file-unreadable`). Take the **same fallback arm** below, recording the skip reason in place of an error line.
- **No output at all** — the harness/permission matcher refused the invocation before it ran. Read the silence as **route to the fallback arm** — **never** as authorization to treat the review as posted. Record the cause as `the review-post helper produced no output (harness refusal)`.

**Fallback arm (any non-`POSTED` outcome, including silence).** Post the **full `$REPORT`** (not `$STUB`) as a plain comment with `gh pr comment $PR_NUMBER --body-file <file>`, where the file's body **opens with a failure record** stating, at minimum: that the formal `gh pr review` post could not be posted; the helper's captured error line (or the skip reason / harness-refusal note); the **verdict** that was reached; and the sentence *"This comment is **not** read as a verdict by the verdict-derivation consumers (`reviewDecision` and the reviews API are unchanged); it is a human-readable record only."* Compose the file with the Write tool, prepending that failure record above the `$REPORT` body, then pass its path. **Never silently skip this step on a REJECT** — the rejection must be impossible to miss. **A failed post never downgrades the verdict** — it stands; only the durable GitHub artifact changed shape.

**A consumer reading `reviewDecision` or the reviews API after a failed post sees exactly what it saw before this change** — this phase mints no verdict marker and changes no consumer matcher (the machine-readability of a failed post is issue #1030's owned design, deliberately untouched here). What this change adds is a durable, human-readable *diagnosis* at the point a reader looks.

**Then, on any APPROVE form only (APPROVE / APPROVE with notes / APPROVE WITH CAVEAT), clear a stale REJECT — and run this dismissal REGARDLESS of the post outcome above (`POSTED`, `FAILED`, `SKIP …`, or silence).** The dismissal is **not conditioned on the post succeeding**: it is independent housekeeping, and a failed post is exactly the case where a prior REJECT is most likely still outstanding. A prior REJECT's `--request-changes` review stays the PR's effective `reviewDecision` until *dismissed*; the APPROVE-with-notes `COMMENT` review never supersedes it, and the REJECT may be a different bot identity (auto path posts as `github-actions[bot]`, manual `@claude` as another), so no later review clears it either. Without this the PR is wedged at `reviewDecision: CHANGES_REQUESTED` forever, contradicting the green check and this APPROVE. The script dismisses **only Devflow Review's own reports** (body marker), never a human's `--request-changes`. On REJECT, **skip this** — the changes-request must stand. Run (re-run safe):

```bash
.prflow/vendor/prflow/scripts/dismiss-stale-rejections.sh "$PR_NUMBER"
```

**Pass `"$PR_NUMBER"` here, never `"$ARGUMENTS"`: the quoted form reaches `dismiss-stale-rejections.sh` as a single argv element, so an extended argument string is handed over whole, matches no PR, and the stale-REJECT dismissal silently no-ops after an APPROVE — leaving the PR wedged at `CHANGES_REQUESTED`.** (On the local tier, resolve the `${CLAUDE_SKILL_DIR:-…}` anchor to `scripts/dismiss-stale-rejections.sh` as the leading token.)

**Record the dismissal's exit code.** On a **`POSTED` APPROVE**, a non-zero exit is reported in chat output (token scope) and that the PR stays blocked until dismissed manually — as it is today. On a **`FAILED` / `SKIP …` / silent APPROVE**, the dismissal ran with no `POSTED` review, so write **its outcome into the fallback comment's failure record** (dismissed / non-zero exit and cause), so the whole story — the failed post, its error, the verdict, and the dismissal result — lives in one durable artifact. **A dismissal failure never downgrades the verdict** — it stands; only merge-gate housekeeping failed.
<!-- prflow:review-ref phase=4.4 file=skills/review/phases/phase-4-4-github-post.md end -->
