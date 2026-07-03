## Phase 3: Review & Fix

Output: `Phase 3/4: Review & Fix — creating PR and running review...`

`workpad.py update $ISSUE_NUMBER --status Reviewing`.

### 3.1 Create Draft PR

Re-derive the base branch and open the draft PR against it **in one bash block**. Each phase's bash block runs as a **separate** shell, so the `$BASE` resolved in Phase 1.4 is **not** in scope here — re-read it (behaviorally identical to Phase 1.4: the `config-get.sh` read plus the fail-closed empty-read fallback to `main`) so `gh pr create` targets the **configured** `base_branch` rather than the repo default branch. Keep the re-derivation and `gh pr create` in the **same** block so `$BASE` cannot be lost to a shell boundary between them (an empty `--base ""` would mistarget silently — the very failure this fix prevents). Pass the re-derived base as the `--base` flag; do **not** pass `--head` — Phase 3.1 runs on the checked-out feature branch, so `gh pr create` defaults `--head` to it correctly:

```bash
BASE=$("${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/config-get.sh .base_branch main) || BASE=""
[ -n "$BASE" ] || { echo "devflow: base_branch read failed (malformed config or missing python3); falling back to 'main'" >&2; BASE=main; }
gh pr create --base "$BASE" --draft --title "{issue title}" --body "$(cat <<'EOF'
Work in progress — automated review pending.

Resolves #{issue_number}

Generated via `/devflow:implement $ARGUMENTS`
EOF
)"
```

Then populate the workpad's `PR` link from the freshly-created draft PR:
```bash
PR_URL=$(gh pr view --json url --jq '.url')
PR_NUM=$(gh pr view --json number --jq '.number')
workpad.py update $ISSUE_NUMBER --pr-link "[#$PR_NUM]($PR_URL)"
```

Then stamp the reserved `DevFlow` **provenance** label on the PR (best-effort). `DevFlow` is a hardcoded provenance constant (no config key controls it) — it is the branch-naming-independent signal the weekly retrospective uses to detect DevFlow-authored PRs. Apply it through the shared REST label-apply helper after creation (a PR is an issue, so the same `POST .../issues/{n}/labels` endpoint serves it) so a label hiccup can never block the run:
```bash
"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/ensure-label.sh DevFlow
"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/apply-labels.sh "$PR_NUM" DevFlow
```
Both helpers always exit 0 and need only the `repo` scope: `ensure-label.sh` logs whether the label was created / present / hit a `gh` error, and `apply-labels.sh` applies via REST `POST .../issues/{n}/labels` (not `gh pr edit --add-label`, which resolves the repo via org-scoped GraphQL and fails under a repo-scoped token), logging its own breadcrumb on failure — continue regardless of the label outcome.

### 3.2 Self-Review with /simplify

Invoke the **Skill tool** with `skill: simplify` — this runs the **built-in Claude Code `/simplify` slash-command**, not a DevFlow plugin skill (so there's no `devflow:` prefix and nothing to install). It ships with Claude Code and is always present; do not treat it as a missing skill or skip this phase.

`/simplify` is equivalent to `/code-review --fix`: it runs the code-review engine over the current diff — correctness angles plus the **reuse / simplification / efficiency / altitude** cleanup angles — and applies the fixes directly instead of stopping at a report (skipping any whose fix would change intended behavior). It is a fast self-review that catches the kinds of issues the heavier `review-and-fix` engine in 3.3 would otherwise spend turns on, keeping 3.3 focused on correctness, contracts, and verification rather than quality nits.

**Triage each `/simplify` finding against the issue's acceptance criteria before applying it (this `/devflow:implement` path only).** The `/simplify` cleanup agents see only the diff — never the issue's `## Acceptance Criteria` or any Phase 2.2.5 scope decisions — so a cleanup that reads as correct against the diff alone can directly violate the issue's deliberate scope (e.g. move a rule out of the file an AC pinned it to, or trim an exclusion list or wording an AC mandated). Before applying each finding, evaluate it against the workpad's in-scope `## Acceptance Criteria` and Phase 2.2.5 scope-decision notes: if its fix would violate an acceptance criterion or the decided scope, **skip the finding and record the AC conflict as the skip rationale** via `workpad.py update $ISSUE_NUMBER --note "skipped /simplify finding: {finding}; would violate AC: {which criterion}"`. Apply findings that do not conflict as normal. This triage is the apply-time analogue of the Phase 3.4 AC gate and exists only on the issue-context `/devflow:implement` path — it does **not** change standalone `/simplify` / `/code-review` behavior, which carry no issue/AC context. One carve-out: a finding that conflicts with a now-*stale* AC that a legitimate refactor superseded is **not** a silent skip — that is Phase 2.2.6 AC-rewrite territory (rewrite the AC text with a `--note` paper trail, then let the finding apply), never this guardrail.

After the skill completes, commit any fixes and push:
```bash
git add -A
git commit -m "refactor: address /simplify findings for issue #$ARGUMENTS"
git push
```

If `/simplify` reported the code was already clean and made no changes, skip the commit and continue.

Then tick the `/simplify` gate: `workpad.py update $ISSUE_NUMBER --tick-progress "/simplify"`.

### 3.3 Review & Fix

**Snapshot this run's per-iteration workpad baseline first (before invoking `review-and-fix`).** The observability backstop below decides whether *this* run wrote any `iter-*.json`; on the local/interactive tier `.devflow/tmp` persists across runs, so a whole-tree presence check would count a prior run's leftover and mask a genuine loss. Record the pre-existing set now so the post-return detector measures only what this run adds:
```bash
# Snapshot the iter-*.json that ALREADY exist before driving review-and-fix inline, so the
# post-return detector can tell whether THIS run wrote any per-iteration workpad rather than
# whether the review tree is merely non-empty. On the local/interactive tier .devflow/tmp is
# a persistent gitignored checkout (NOT wiped between runs the way a fresh cloud runner is),
# so a leftover iter-*.json from a prior run would satisfy a whole-tree presence check and
# MASK a genuine telemetry loss this run — the exact silent loss this backstop exists to
# surface. Snapshot to a file because each phase bash block is a separate shell.
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# Check mkdir's own exit status rather than letting a failure here surface only as the
# generic "snapshot file missing" degrade downstream — a distinct breadcrumb here names the
# actual root cause (permissions/read-only-fs/disk-full) instead of leaving a future reader
# only the symptom.
if ! mkdir -p "$ROOT/.devflow/tmp" 2>/dev/null; then
  echo "::warning::phase-3.3: could not create $ROOT/.devflow/tmp (permissions/read-only-fs/disk-full?); pre-loop snapshot will be missing, degrading the no-inputs detector to whole-tree presence below" >&2
fi
compgen -G "$ROOT/.devflow/tmp/review/*/*/iter-*.json" 2>/dev/null | sort > "$ROOT/.devflow/tmp/.phase33-iters-before" || :
```

Invoke the **Skill tool** with `skill: review-and-fix` and `args: "--push-each-iteration"`. The flag is load-bearing here: this phase operates on the live draft PR created in 3.1, and `--push-each-iteration` propagates each fix iteration to the remote branch so its CI validates the converging state and progress survives a mid-loop crash. (Direct users of `/devflow:review-and-fix` omit the flag and the loop stays local — see that skill's Input section for the flag's semantics.)

**Stay on the instrumented loop — a cloud permission/sandbox denial is not license to leave it.** This phase drives `review-and-fix` **inline in your context**. If you hit a `claude-code-action` permission or sandbox denial here — a piped/compound `.sh` invocation, a `$(...)` redirect target, or a shell `>` write into `.devflow/tmp` refused as "may only write to files in allowed working directories" — that denial is not the local-tier permission classifier, and is not license to abandon the instrumented loop and hand-run the review engine via direct `Agent` dispatch. On the cloud implement job `Skill`, `Agent`, `Write`, `efficiency-trace.sh`, `workpad.py`, and `config-get.sh` are all allowlisted, so the instrumented loop is navigable, not blocked. Whatever path the review runs, the per-iteration effectiveness record (`iter-<N>.json`) is a non-optional emit on every iteration, written with the Write tool (never a shell `>`/heredoc redirect the sandbox denies) — that is what keeps the **effectiveness** half of the telemetry recoverable even on a degraded, hand-run pass; the **token/wall-clock-cost** half is live-only and cannot be reconstructed once the loop is abandoned, which is the second reason not to leave it. When you need a scratch or telemetry file under `.devflow/tmp`, author it with the Write tool, not a shell `>` redirect; the pre-loop snapshot below is a shell-computed listing whose `>` may itself be refused — its failure does not abort the phase, though it degrades the no-inputs detector to whole-tree presence (which the block's own `::warning::` surfaces, because on the persistent local tier a leftover `iter-*.json` can then mask a real loss); it is a degrade to note, not a hard blocker, and never a reason to leave the loop.

This runs the four-phase review engine in your context:
1. **Verification checklist** — generates and verifies every dependency interaction, test-mock alignment, data format assumption, and API contract claim against actual source code
2. **Existing review agents** — runs the first-party review agents (code-reviewer, silent-failure-hunter, comment-analyzer, type-design-analyzer, pr-test-analyzer) and the first-party `devflow:requesting-code-review` final-pass reviewer in parallel
3. **Automatic fix loop** — fixes findings using `devflow:receiving-code-review` principles, re-runs the engine, loops until APPROVE or the configured iteration cap (`devflow_review_and_fix.max_iterations`, default 5)

Follow the skill's instructions. It handles evaluation, fixing, testing, and re-review internally.

**Observability-persistence backstop (after `review-and-fix` returns, before the verdict branches below).** `review-and-fix`'s Loop Exit is what normally derives this run's effectiveness record (`.devflow/logs/efficiency/<slug>-<run-id>.json`) and durable workpad copy from its per-iteration `iter-*.json`. But this phase drives that loop **inline in your context**, so a dropped Loop Exit leaves those artifacts unpersisted and the run contributes nothing to `.devflow/logs/efficiency/` — the skill's own #1 documented "Common Mistake," unguarded at this seam. So regardless of the verdict, first **verify this run's observability artifacts were persisted and run the efficiency-trace persist backstop when they are missing**; the backstop is idempotent (it never re-derives an existing record), so running it unconditionally is safe. **When even that backstop has no `iter-*.json` inputs** — the inline loop wrote no per-iteration workpad this run — **record a `dropped-failed` reflection naming the observability gap** so the lost telemetry is visible rather than silently absent:
```bash
# Anchor on the repo root the SAME way efficiency-trace.sh does (git toplevel), so the
# "no inputs" detector below reads the exact .devflow/tmp/review tree --persist scans —
# never a cwd-relative path that could diverge from the wrapper and fire a false
# "telemetry lost" reflection (or mask a real loss) when cwd is not the repo root.
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# Idempotent Layer-3 persist: derives + commits the effectiveness record and durable
# workpad copy from whatever iter-*.json this run left under .devflow/tmp/review/; a commit
# no-op if already persisted (the effectiveness record is presence-idempotent — skipped when
# it already exists; the durable workpad copy re-runs but is content-idempotent, rewriting
# identical bytes) and a full no-op if the inline loop wrote no per-iter workpad. Best-effort
# (always exits 0). No --workpad-dir/--slug: with no args --persist scans every run-scoped
# dir on disk, which is exactly the "the orchestrator does not hold review-and-fix's
# internal slug/run-id" case at this inline seam.
# On mktemp failure, degrade to /dev/null rather than aborting — the capture becomes a
# no-op (stderr is discarded, so the record-write-failure grep below can never match), but
# --persist's own best-effort exit-0 contract is preserved. Track the degrade explicitly in
# $PERSIST_ERR_IS_DEVNULL (not by re-testing the string later) so (a) the cleanup at the
# bottom of this block never runs `rm -f` on the LITERAL PATH `/dev/null` — under a root
# shell with a writable /dev this would delete the device node itself, breaking every other
# command in the environment that redirects to /dev/null — and (b) the degrade gets the same
# distinct ::warning:: breadcrumb discipline as the sibling $BEFORE-missing degrade below,
# instead of silently no-opping the record-write-failure detector for this run.
if PERSIST_ERR=$(mktemp 2>/dev/null); then
  PERSIST_ERR_IS_DEVNULL=0
else
  PERSIST_ERR=/dev/null
  PERSIST_ERR_IS_DEVNULL=1
  echo "::warning::phase-3.3: could not allocate a temp file for --persist's stderr (mktemp failed); ALL of --persist's stderr (durable-copy/staging/commit warnings included, not only the record-write-failure check) is discarded this run, and the record-write-failure detector is DISABLED (only the no-new-inputs case below is still checked)" >&2
fi
"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../lib/efficiency-trace.sh --persist 2>"$PERSIST_ERR" || true   # best-effort; captured (not swallowed) so its ::warning:: breadcrumbs both surface to the run log below AND are checked for a record-write failure by the detector
cat "$PERSIST_ERR" >&2   # surface every --persist breadcrumb to the run log, same as before this capture was added
# Detect the "no inputs FROM THIS RUN" case by diffing against the pre-loop snapshot, anchored
# on $ROOT (matching --persist): comm -13 lists iter-*.json present now but NOT before the
# inline loop — i.e. exactly what THIS run wrote. This is immune to prior-run leftovers on the
# persistent local tier, where a whole-tree presence check would let a leftover mask a real
# loss. If the snapshot file is somehow absent, treating it as empty degrades to whole-tree
# presence — and that degrade direction can MASK a real loss, not surface it: comm -13 against
# an empty snapshot counts every pre-existing leftover iter-*.json on the persistent local tier
# as if this run wrote it, so a leftover file makes the -z check false and suppresses the
# reflection even when this run's loop wrote nothing. Because this snapshot-absent path is the
# reachable failure mode the detector exists to guard against, emit a distinct ::warning:: so
# the degrade is visible on the run log rather than silently indistinguishable from the healthy
# case. Zero NEW iter-*.json means the inline loop wrote no per-iteration workpad, so --persist
# had nothing to derive from and this run's effectiveness telemetry is genuinely lost — surface
# it, do not swallow. (A persist that DID find inputs but failed to write still leaves
# efficiency-trace.sh's own ::warning:: on the run log, surfaced above.) The detector counts NEW
# iter-*.json regardless of --persist's source=="review" skip (standalone /devflow:review runs
# have their own record path); that is correct here because at THIS seam the review-and-fix
# loop just driven inline is what writes this tree, so a foreign review-sourced dir being the
# sole new occupant is not a reachable in-flow shape.
BEFORE="$ROOT/.devflow/tmp/.phase33-iters-before"
if [ ! -f "$BEFORE" ]; then
  : > "$BEFORE"
  echo "::warning::phase-3.3: pre-loop iter-*.json snapshot missing; no-inputs detector degrades to whole-tree presence, which can MASK a real this-run telemetry loss behind a leftover iter-*.json from a prior local run" >&2
fi
if [ -z "$(compgen -G "$ROOT/.devflow/tmp/review/*/*/iter-*.json" 2>/dev/null | sort | comm -13 "$BEFORE" -)" ]; then
  # Guard the loss-record write itself: if workpad.py fails (gh API/permission error,
  # absent reflection section, bad $ISSUE_NUMBER) the ::warning:: keeps the gap visible on
  # the run log rather than silently dropping both the telemetry AND its loss-record — a
  # double silent failure at the exact seam this clause exists to make visible. Mirrors the
  # --persist line's best-effort breadcrumb discipline.
  workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "review-and-fix inline loop wrote no iter-*.json this run; lib/efficiency-trace.sh --persist had no inputs, so this run's effectiveness telemetry (.devflow/logs/efficiency/) is missing" \
    || echo "::warning::phase-3.3: failed to record dropped-failed observability-gap reflection on issue #$ISSUE_NUMBER; this run's effectiveness telemetry is lost AND its loss-record could not be written" >&2
fi
# The no-new-inputs case above only catches a dropped LOOP EXIT (the inline loop wrote no
# iter-*.json at all). It does NOT catch the sibling failure mode where the loop DID write
# iter-*.json but --persist's own record derivation/write step then failed — that failure is
# otherwise invisible to this this-run-scoped detector, which only measures INPUT presence,
# not persistence SUCCESS. Grep the captured --persist stderr for its record-derivation/write
# failure breadcrumbs so this second, independent failure mode is surfaced too, rather than
# reading "inputs existed" as "persisted successfully". efficiency-trace.sh's three record
# derivation/write failure paths do NOT share one common substring: jq-derivation failure and
# mkdir failure both end "...record not written[ for ...]", but the disk/permission write
# failure (a write after mkdir succeeded — ENOSPC/EROFS/quota/perms) instead reads "...failed
# (disk/permission); not persisted for ..." — so match BOTH literals, or a mutated/renamed
# breadcrumb on just the disk-write path would silently escape this detector exactly as the
# single-literal form did (#236 review, Step 3.5 fix-delta gate). This intentionally scopes to
# record derivation/write failures only, not the separate git-staging/commit failure surface
# (efficiency-trace.sh's "not persisted this run" / "artifacts left staged" breadcrumbs) —
# there the record IS written to disk, just not yet committed, a materially different and
# lower-priority gap deferred on the issue #235 workpad. KNOWN LIMITATION (also deferred,
# #236 review shadow pass): unlike the this-run-scoped no-inputs detector above, this grep
# runs against --persist's WHOLE-TREE discovery-mode stderr (no --workpad-dir/--slug), so a
# persistently-failing LEFTOVER run directory elsewhere on the local tier can also match —
# the reflection below therefore does not assert the failure is scoped to this run.
if [ "$PERSIST_ERR_IS_DEVNULL" -eq 0 ] && grep -qE 'record not written|failed \(disk/permission\); not persisted for' "$PERSIST_ERR" 2>/dev/null; then
  workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "lib/efficiency-trace.sh --persist failed to derive/write an effectiveness record (see the record-derivation/write-failure breadcrumb above) — either this run's or an unresolved leftover run's on this host; some run's effectiveness telemetry under .devflow/logs/efficiency/ is missing" \
    || echo "::warning::phase-3.3: failed to record dropped-failed observability-gap reflection (record-write-failure case) on issue #$ISSUE_NUMBER; this run's effectiveness telemetry is lost AND its loss-record could not be written" >&2
fi
[ "$PERSIST_ERR_IS_DEVNULL" -eq 1 ] || rm -f "$PERSIST_ERR" 2>/dev/null
```


After the skill completes with a clean approve-family verdict (`APPROVE`, `APPROVE WITH CAVEAT`, or `APPROVE WITH ADVISORY NOTES` — **not** `APPROVE WITH UNRESOLVED SHADOW FINDINGS`, which is handled separately below), flush any residual fixes. A run that does **not** return one of those three recognizable verdicts — it errors, can't run, or emits nothing parseable as a verdict — is **not** a clean completion: route it to the **Blocked path** below rather than letting an empty/garbled exit fall through to the flush. With `--push-each-iteration` the loop has already committed and pushed every iteration, so this is normally a no-op — guard the commit so an empty staging area doesn't error:
```bash
git add -A
git diff --cached --quiet || git commit -m "fix: address code review feedback for issue #$ARGUMENTS"
git push
```

Then tick the `review-and-fix` gate: `workpad.py update $ISSUE_NUMBER --tick-progress "review-and-fix"`. Before ticking, record the run's shadow-coverage status — `shadow agreed, full coverage` vs `shadow agreement not verified` — via `--note`. Read these from the run's **verdict headline**: those exact literals are the `{shadow status}` parenthetical that review-and-fix renders on its APPROVE-family chat line (its Loop Exit "Verdict → chat output"), **not** from the report's `## Coverage` → `### Shadow agreement` section, which paraphrases the same fact in different prose (`Shadow ran with full reviewer coverage …` / `Shadow agreement NOT verified — {reason}`). Matching the headline token is exact; grepping the report body for the literal would miss. (Bucket the run by the loop's **verdict** first — this clean-completion path versus the AWUSF / REJECT / Blocked branches below — reading it from review-and-fix's **chat-output verdict line** (its Loop Exit "Verdict → chat output"). That line is the only surface carrying the *loop-level* verdicts: `APPROVE WITH UNRESOLVED SHADOW FINDINGS` is rendered there and **never** on the engine's report `## Verdict:` line, whose enum stops at the per-iteration engine verdicts (`APPROVE` / `APPROVE with notes` / `APPROVE WITH CAVEAT` / `APPROVE WITH ADVISORY NOTES` / `REJECT`) — so bucketing off `## Verdict:` would silently read an AWUSF run as a clean approve and ship it unreviewed. Only **after** the verdict has bucketed as clean approve-family, harvest the `{shadow status}` token from that same headline, so the AWUSF lost-write headline's own `… not verified …` prose can never be mis-harvested onto a clean run.) This is so a clean approve-family verdict that rode on a *not-verified* shadow (Step 2.6 outcome 3, which the loop intentionally proceeds on) is visible in the workpad rather than silently consumed as if it had been fully audited. This surfaces the gap without blocking — the loop already chose to proceed on its tentative verdict; contrast the bounded re-review below, which *does* require full coverage because it exists specifically to give an orchestrator hand-fix the independent pass it would otherwise never get.

**If the skill returns `APPROVE WITH UNRESOLVED SHADOW FINDINGS`** (the iteration-cap shadow pass surfaced new Important — never Critical — findings the loop could not address; see that skill's Step 2.6 outcome 2): this is **not** a clean approve. The findings came from a *full-coverage* shadow pass and are real, but they reach you only in chat + the report's `## Unresolved Shadow Findings` section (they do **not** flow through the Step-3 deferrals manifest, so Phase 4.0.5 will not file them). You may **not** silently hand-fix them and ship — any fix you apply to resolve them is itself unreviewed spec/code that no independent pass has seen, and shipping it is the unreviewed-final-edit gap the skill's caller contract forbids. Pick one:
1. **Fix + re-review (bounded once).** Apply fixes for the unresolved findings, commit (`fix:` prefix). **Before re-invoking, re-run the pre-invocation snapshot block from 3.3 above** (recomputes the repo-toplevel-anchored baseline of pre-existing per-iteration workpads) — the bounded re-review below is a **second, separate** inline `review-and-fix` invocation whose own Loop Exit can be dropped exactly like the first invocation's, so it needs its own fresh this-run baseline, not the first invocation's now-stale one. Then **re-invoke `review-and-fix` exactly one more time** (Skill tool, same `args: "--push-each-iteration"`) so the fix delta gets an independent shadow/review pass, and **immediately after it returns, re-run the observability-persistence backstop block from 3.3 above** (the same persist-and-detect procedure — the idempotent Layer-3 persist call, the record-write-failure check, and the `dropped-failed` reflection) against the snapshot just taken — this second invocation's telemetry is protected exactly like the first invocation's, not left unguarded at this seam. **A clean approve-family verdict (`APPROVE` / `APPROVE WITH CAVEAT` / `APPROVE WITH ADVISORY NOTES`) whose verdict headline reads `shadow agreed, full coverage` (the `{shadow status}` token — same surface as the gate note above) clears the re-review** — treat it exactly as a clean completion above (flush residual fixes **and** tick the `review-and-fix` gate), then continue. A clean verdict whose shadow was `not verified` does **not** clear it: the re-review exists precisely to give the hand-fix delta an *independent, full-coverage* pass. **Any other outcome routes through the severity-aware exit below — it does NOT automatically Block** (e.g. `APPROVE WITH UNRESOLVED SHADOW FINDINGS` again, `REJECT`, or a not-verified re-review). Do **not** loop a third time: trigger at most **one** orchestrator-initiated re-review, and that bound is what keeps this terminating. (The bounded re-review is an ordinary `review-and-fix` run, so if *it* defers a finding through the Step-3 deferrals manifest, that is the normal Phase 4.0.5 follow-up-issue channel and proceeds as usual — the "AWUSF findings do not flow through the deferrals manifest" rule above is about the *first* run's unresolved shadow findings, not the re-review's own deferrals.)
2. **Do not fix — route directly through the severity-aware exit below** (treat the unresolved findings as "unresolved after the cap").

**Severity-aware exit (do not fully block on diminishing-returns).** Reached when the bounded re-review did not return a clean **and** full-coverage verdict, or when you chose option 2. Two consecutive non-clean review passes (the capped first run + the bounded re-review) is **not**, by itself, grounds to abort the whole implement lifecycle — hard-blocking there discards the completed work and the review-ready PR over findings that are often advisory or over-graded. Instead, **classify the residual unresolved findings by severity** and route. **First ensure over-grade calibration has actually run on the residual:** the loop's **over-grade calibration gate** (`/devflow:review-and-fix` Step 2.6) — which *flags* a promote-path over-grade and *requires a recorded `severity-calibrated` technical evaluation*, never auto-demoting — ran on the residual **only if a bounded re-review actually ran** (option 1). On **option 2** (you chose not to re-review) and on a **first-run REJECT** (which may never have reached the shadow-promotion decision where the gate fires), the gate has *not* run — do **not** assume a finding was already calibrated; apply the same flag-and-evaluate calibration yourself before classifying, and grade conservatively (default to Critical-treatment on doubt). Then route:

- **A genuine unresolved Critical** — a real Critical (a data-loss/exploit/correctness break citing a concrete failing input), or an Important the orchestrator judges it cannot responsibly defer → **Blocked path** below (the human gate genuinely applies). The same applies to a re-review that errors / returns no parseable verdict at all (no findings to classify → fail closed), **and to any residual whose severity is missing, ambiguous, or cannot be confidently graded** — an ungradeable residual fails **closed** to the Blocked path, it does **not** fall through to soft-proceed.
- **Otherwise** — the residual is only advisory / Suggestion / `severity-calibrated`-down / a deferrable Important, *and every residual was confidently gradeable as non-Critical* → **Soft-proceed path**: do **NOT** block. The PR is review-ready, not auto-merged; the residual findings ride into the human's merge decision rather than aborting the run.

**Soft-proceed path.** Surface the residual findings durably and continue the lifecycle:
- Record each residual finding in the workpad: `workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "unresolved after bounded re-review (non-Critical, surfaced for human review): {finding}"` so it lands under `### ⚠️ Action required` (a non-empty reflection set keeps the run honest about what shipped unverified).
- Tick the `review-and-fix` gate and record `workpad.py update $ISSUE_NUMBER --tick-progress "review-and-fix" --note "review-and-fix did not reach a clean+full-coverage verdict; soft-proceeded on non-Critical residual findings (surfaced above) — PR is review-ready, not auto-merged"`.
- Continue to Phase 3.4 and Phase 4. The PR ships per the configured `implement_pr_state` with the residual findings documented in the workpad and (where the re-review wrote a deferrals manifest) carried into the PR body by Phase 4.0.5 / `/pr-description`. The human merger decides. Do **not** silently hand-fix the residual findings after this point — that is still the unreviewed-final-edit gap; they are *surfaced*, not *resolved*.

**Blocked path (genuine unresolved Critical only).** Reached from the severity-aware exit when a genuine unresolved Critical remains (or a verdict cannot be parsed at all — fail closed): `workpad.py update $ISSUE_NUMBER --status Blocked --reflection-kind blocked --reflection "review-and-fix unresolved Critical (or unparseable verdict): {summary}"`, then emit the 👎 outcome reaction (see *Outcome reaction* in the Workpad Reference) and stop. A non-Critical residual is **not** a Blocked exit — it soft-proceeds per the path above.

**If the skill returns `REJECT`** (it could not converge — whether at the iteration cap or via a pre-cap convergence exit per that skill's Step 4.5, whose verdict is still REJECT): route through the **severity-aware exit** above — a REJECT whose unresolved triggers are all non-Critical/deferrable soft-proceeds (review-ready, surfaced), while a REJECT with a genuine unresolved Critical takes the Blocked path. Like AWUSF, a REJECT must **not** be silently hand-fixed and shipped as resolved; soft-proceed surfaces it for the human rather than resolving it.

### 3.4 Acceptance Criteria Gate

Before advancing to Phase 4, verify every **non-post-merge** checkbox in the workpad's `## Acceptance Criteria` section is ticked (`- [x]`). For each criterion, the verification is one of:

- a passing test in the diff that demonstrates the criterion,
- a documented manual check (recorded in the workpad notes via `--note` with the result), or
- a code reference (file:line) that satisfies the criterion.

**A verification-command criterion you could not locally observe passing is NOT satisfied by CI deferral alone — tick it only on an *observed* green CI result for the current HEAD, route a *red* result to the Blocked path, and a *not-yet-reported* one to `(post-merge)`.** The scope is determinable, not a phrase to pattern-match: this rule fires for **any** acceptance criterion whose verification is *running a test/lint/build command* (`bash lib/test/run.sh` passes, `shellcheck`/`ruff` pass, a `pytest`/build invocation, …) for which you could **not** produce a locally-observed green run. The trigger is "you did not observe it green locally," never your judgment that a criterion is "equivalent" to the examples — if you couldn't watch it pass, the rule applies. First work the tiers in CLAUDE.md's *"Running the suite when the `bash <path>` wrapper above is denied — the tier matters"* section: retry the **direct leading-token** form (`lib/test/run.sh`, not `bash lib/test/run.sh`) and the `python3 <path>` / `jq` fallbacks. Only on a genuine permission/sandbox **denial** of the direct form do you fall back to CI — **never** when the command *ran and failed* (that is a real failure to fix or block on, not a deferral). Falling back to CI, you do **not** tick on the *promise* of CI; you read the actual result of the **`lib + python tests`** job **for the current `git rev-parse HEAD`** (`gh pr checks` / `gh run list --json headSha,status,conclusion` — match the run whose `headSha` equals local HEAD) and split on what you observe:

- **Observed green for HEAD** — a run whose `headSha` equals local `git rev-parse HEAD` reports success. Tick on that observed result (by its 1-based AC position), interpolating the **gh-resolved** HEAD SHA (not a hand-written one) into the provenance recorded on the same call: `workpad.py update $ISSUE_NUMBER --tick-ac-n {N} --note "verified via CI: direct-form '{cmd}' denied locally (tier {N} — the tier the denial occurred on); 'lib + python tests' observed GREEN on $(git rev-parse HEAD)" --reflection-kind note --reflection "suite/lint AC ticked on observed CI green for HEAD, not a local run: {tier + what was denied}"`. The `[x]` then asserts a result you *saw* for *this* code. A green whose `headSha` is an *older* commit than HEAD is not an observation of this diff — treat it as not-yet-reported (third bullet).
- **Observed red for HEAD** — the job *ran and failed*. That is a real failure, **not** a deferral (the same rule that bars deferring a local command that ran and failed): do **not** tick and do **not** `(post-merge)` it. Take the gate's Blocked path — `workpad.py update $ISSUE_NUMBER --status Blocked --reflection-kind blocked --reflection "AC unmet: 'lib + python tests' observed RED on $(git rev-parse HEAD): {failing jobs}"`, emit the 👎 outcome reaction, and stop. A red CI laundered into a post-merge deferral is the exact silent-failure this gate exists to prevent.
- **Not yet reported (still running, or no run for HEAD yet) or status unreadable (`gh` denied/errored)** — there is no observed result, so do **NOT** tick on one that does not exist. Retag the criterion `(post-merge)` via the 3.4 retag pattern below — `--rewrite-ac "{AC text}" "{AC text} (post-merge)" --note "deferred to CI: direct-form '{cmd}' denied locally (tier {N} — the tier the denial occurred on); 'lib + python tests' <not yet reported for HEAD | status unreadable (gh denied)> — confirm green before merge"` (name *which* of the two in the note). That leaves the box unticked, exempts it from the blocking gate, and surfaces it in the PR body's `## Post-Merge Verification` checklist for the human merger, instead of asserting satisfaction the run never observed. (This reuses the `(post-merge)` channel for a *gate-time CI deferral* — the same mechanism as a Phase 1.2 intrinsically-live criterion, though the cause differs: here verification *could* run locally on a tier where the direct form resolves, it just didn't this run.)

A bare direct **grep** of a few SKILL-contract pins is **not** a substitute for the suite — it confirms specific pins, not "the suite passes," so it can never by itself satisfy such a criterion.

Tick each criterion as you confirm it, **by its 1-based position** in the workpad's `## Acceptance Criteria` section (the list mirrors the issue's AC order): `workpad.py update $ISSUE_NUMBER --tick-ac-n {N}`. `--tick-ac-n` is repeatable and combinable, so the whole gate can tick every confirmed AC in one call (`--tick-ac-n 1 --tick-ac-n 2 …`) without hand-picking unique prose substrings — and a single bad index no longer discards the rest of the batch (it is reported as a volatile miss while the other ticks land). Cite the verification (a test, a file:line, or a prior note) in a `--note` on the same call where helpful.

**Consume the tick call's exit code — do not advance on the stdout body alone** (per the failure-isolation contract in the Workpad Reference). Because a volatile index miss still PATCHes the body and leaves the target AC `- [ ]`, an unchecked non-zero exit would let the gate pass with an in-scope AC still unticked — the exact silent failure the index contract elsewhere prevents. So after the tick call: if it exited **0**, the named AC rows are now `- [x]` and the gate proceeds; if it exited **non-zero**, read the stderr report naming each unresolved `--tick-ac-n`, re-resolve the position (a Phase 2.2.5 `--replace-acs-file` may have reordered/added/removed AC rows, so the criterion's section-scoped index can have drifted out of range or onto an already-ticked row — `--rewrite-ac` alone preserves order and count) and re-tick, and only when a criterion's tick genuinely cannot be resolved take the gate's Blocked path (step 4 below). The gate passes only when every non-post-merge AC row reads `- [x]` **and** the ticks that set it exited 0.

**Post-merge criteria are exempt from the gate.** A criterion whose checkbox line ends in `(post-merge)` (tagged during Phase 1.2) does not block. The orchestrator's responsibility for a post-merge criterion ends at "the code reaches the state where the live verification *becomes possible* to run." Leave the checkbox unticked — the merger will tick it after deploy via the `## Post-Merge Verification` section that `/pr-description` adds to the PR body in Phase 4.2. Do **not** invent evidence to tick a post-merge box during /devflow:implement; the live signal is what counts.

**A `(post-merge)` tag is permitted only when the criterion genuinely requires a runtime environment that does not exist during the implement run** — a live deploy target, a real third-party endpoint, a production data path, or similar. That is the *only* qualifying condition, and it is the observable test the gate applies: *would running this verification require an environment the orchestrator host can never be, no matter which tools were installed?* If yes, it is genuinely-live and `(post-merge)` is correct. If the verification could run on the orchestrator host given the right tools, it is **not** post-merge — even if those tools happen to be unavailable right now. Two cases therefore **never** qualify, and the gate must refuse the tag (or retag) for them:

- **Runnable-but-blocked (local tooling/environment gap).** A criterion you *could* verify on this host but can't right now because a command was denied, a build tool is missing, a helper won't spawn, or a restore errored. A tooling gap is not a runtime-environment gap — route it to the **Blocked path** (step 4 below: `--status Blocked`), which escalates to a human; never launder it into `(post-merge)`. (A genuine permission/sandbox denial of the *test suite itself* still follows the `CLAUDE.md` tier rule — an auditable, workpad-recorded skip to the CI `lib + python tests` gate. That is a different mechanism from a `(post-merge)` retag: it does **not** tick the AC and does **not** pretend the check ran, so it is not the launder this rule forbids.)
- **Confirmation of a self-authored claim.** A criterion whose purpose is to confirm a behavioral claim the PR already asserts as already-true (in its description, its docs, or its code). It is runnable pre-merge **by construction** — the claim is *about the shipped diff* — so deferring it would defer the one check that could falsify the claim. Refuse the tag regardless of the stated reason: verify it now, or, if it genuinely cannot be satisfied, take the Blocked path.

**Red flags that you are about to launder a runnable check into `(post-merge)`** — STOP and take the Blocked path (step 4) instead:
- "The suite/lint/helper won't run *here*, so I'll mark it post-merge and let CI catch it." → tooling gap: Blocked path, or the auditable CI-skip per `CLAUDE.md` (which does not tick the AC) — **never** a retag.
- "This criterion just confirms what the PR already says, so it's safe to defer." → confirmation-AC: **never** post-merge.
- "It's *basically* a live check." → if it could run on this host with the right tools, it is **not** live.

If the workpad's Acceptance Criteria section reads `_(none provided in issue body)_`, the gate passes trivially.

The gate applies only to criteria currently in the workpad's `## Acceptance Criteria` section. If you scoped down via the 2.2.5 rule, deferred criteria live in the workpad notes and are **not** gated here — they will be carried into a follow-up issue in Phase 4.0.

If non-post-merge criteria remain unchecked after Phase 3.3:

1. If a criterion is satisfiable with a small follow-up edit, do it now (still inside Phase 3) — write the code, run tests, commit (using the `fix:` prefix), tick the box, and continue.
2. If a criterion's *literal text* is now stale because /simplify or /devflow:review-and-fix refactored the structure (e.g. renamed jobs, merged files), but the *underlying behavior* the criterion verifies is preserved in the diff, apply **2.2.6** now: rewrite the AC text in the workpad with a `--note` paper trail, then tick the box.
3. If a criterion is genuinely outside this PR's scope and you missed it during 2.2.5, **go back to 2.2.5 now**: move the item to the workpad notes (`--note`) as deferred, rewrite the Acceptance Criteria section, PATCH, and re-run this gate against the narrowed set. Then continue to Phase 4.
4. Otherwise — i.e. the criterion is in-scope but you cannot satisfy it AND it is not tagged `(post-merge)` — `workpad.py update $ISSUE_NUMBER --status Blocked --reflection-kind blocked --reflection "AC unmet (in-scope, not post-merge): {AC text}"`, then emit the 👎 outcome reaction (see *Outcome reaction* in the Workpad Reference) and stop the run with a clear report to the user. Do **not** advance to Phase 4 with unmet in-scope, non-post-merge criteria.

Once the gate passes (every non-post-merge AC ticked), tick the gate **and its parent phase** in the workpad: `workpad.py update $ISSUE_NUMBER --tick-progress "acceptance-criteria gate" --tick-progress "**Review**"`.

(A criterion the orchestrator can't satisfy may be retroactively tagged `(post-merge)` **only if it is genuinely-live by the rule above** — it requires a runtime environment absent during the run, it is *not* a runnable-but-blocked tooling gap, and it is *not* the confirmation of a self-authored claim. When it qualifies, retag with `workpad.py update $ISSUE_NUMBER --rewrite-ac "{old text}" "{old text} (post-merge)" --note "retro-tagged as post-merge (genuinely-live): {the runtime env it requires}"`, then let it pass the gate. If it fails that rule — runnable on this host, blocked only by local tooling, or a self-claim confirmation — do **not** retag; take the Blocked path (step 4 above) instead.)

### 3.5 Tick Phase-3-completed Plan steps

Two kinds of `## Plan` step routinely **complete in Phase 3**, not Phase 2, so the Phase 2 "tick plan steps as they complete" loop never reaches them — leaving their rows falsely `- [ ]` on a finished run. Tick each **at the point its work completes here**, so the terminal Phase 4.3 `--status Complete` self-record gate's non-blocking `## Plan` warning fires only on a genuinely dropped/superseded step (that gate: a non-post-merge unticked **AC** row hard-fails the Complete write, while an unticked **Plan** row only warns — see the finalize call in Phase 4.3):

- **The version-bump / `CHANGELOG` step** (where repo policy bumps a version — e.g. this repo's, per `.devflow/prompt-extensions/implement.md`, applied after the draft PR exists but before the review pass): once the bump + matching `CHANGELOG` entry are committed, tick its Plan row — `workpad.py update $ISSUE_NUMBER --tick-plan "{substring of the version-bump plan step}"`.
- **The final full-suite / `shellcheck` / `ruff` run**: once you have observed it green (or recorded the auditable CI-gate skip per `CLAUDE.md`'s tier rule), tick its Plan row — `workpad.py update $ISSUE_NUMBER --tick-plan "{substring of the final-suite plan step}"`.

Only tick a step your plan actually lists (a `--tick-plan` that matches nothing is a volatile miss); if this run's plan carries no such step — a consumer repo with no version policy, say — skip its tick. Consume the tick call's exit code as everywhere else (a non-zero exit means the substring did not resolve to exactly one unticked row — re-resolve and re-tick).

**⚠ You are NOT done. PR is still a draft and needs documentation and a proper description. Proceed to Phase 4.**
