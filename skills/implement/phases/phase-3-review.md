## Phase 3: Review & Fix

Output: `Phase 3/4: Review & Fix — creating PR and running review...`

`workpad.py update $ISSUE_NUMBER --status Reviewing`.

### 3.1 Create Draft PR

**Base-branch update checkpoint 2 (pre-draft-PR) — run FIRST, before `gh pr create`.** Phase 2 can run for hours, so immediately before the draft PR exists, bring the feature branch up to date with the configured base so the self-review (3.2) and the first review pass (3.3) see current base. Invoke the shared checkpoint helper — it derives the base branch *internally* (from `base_branch`, the same fail-closed fallback the draft-PR block re-derives below), so no `$BASE` needs to be in scope here:

```bash
"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/update-branch-checkpoint.sh
```

Handle the printed token **per the implement-driven outcome-handling contract in phase-1-setup.md §1.4.1** (record on the issue workpad; `Blocked` on `MERGE_IN_PROGRESS` or a failed conflict resolution; resolve a `CONFLICT` and re-run the Phase 2.3.0 sweep before continuing; record-and-continue on `UNVERIFIED`/`PUSH_REJECTED`). **Do not open the draft PR on a tree the run has hard-stopped on**: `MERGE_IN_PROGRESS`, an unresolved (or suite-failed, aborted) `CONFLICT`, and a `PUSH_REJECTED` whose stderr carries the failed-restore `WARNING` (see §1.4.1's `PUSH_REJECTED` caveat) each stop the run instead. **Every other token proceeds to open the draft PR** — `UP_TO_DATE`, `UPDATED`, `DISABLED`, a *resolved* `CONFLICT`, and equally the record-and-continue outcomes `UNVERIFIED` and an ordinary (restore-succeeded) `PUSH_REJECTED`: those two are *degraded but non-fatal* by the §1.4.1 contract, and the branch is simply not vouched current (the #429 read-target rules stay in force). Withholding the PR on them would contradict the contract's own "record and continue" and would leave the run wedged at Phase 3.1 with no PR and no stop.

Re-derive the base branch and open the draft PR against it **in one bash block**. Each phase's bash block runs as a **separate** shell, so the `$BASE` resolved in Phase 1.4 is **not** in scope here — re-read it (behaviorally identical to Phase 1.4: the `config-get.sh` read plus the fail-closed empty-read fallback to `main`) so `gh pr create` targets the **configured** `base_branch` rather than the repo default branch. Keep the re-derivation and `gh pr create` in the **same** block so `$BASE` cannot be lost to a shell boundary between them (an empty `--base ""` would mistarget silently — the very failure this fix prevents). Pass the re-derived base as the `--base` flag; do **not** pass `--head` — Phase 3.1 runs on the checked-out feature branch, so `gh pr create` defaults `--head` to it correctly:

Derive the run link exactly the way Phase 1.3 §1.3 does — the same
`$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID` form — so the draft PR
links back to the run that created it, letting a reviewer trace it to its originating job's
logs. On a **local-tier** run there is no GitHub Actions run, so `$RUN_URL` is empty and the
`View run` line is omitted entirely rather than rendering a broken `[View run]()` link. The
heredoc uses an **unquoted** `<<EOF` so `$RUN_URL` expands (the `/devflow:implement` backticks
are backslash-escaped so they stay literal, not command substitution):

```bash
BASE=$("${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/config-get.sh .base_branch main) || BASE=""
[ -n "$BASE" ] || { echo "devflow: base_branch read failed (malformed config or missing python3); falling back to 'main'" >&2; BASE=main; }
# Empty on a local-tier run (no GITHUB_RUN_ID) → the View-run line is stripped below.
RUN_URL=""
[ -n "$GITHUB_RUN_ID" ] && RUN_URL="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
BODY=$(cat <<EOF
Work in progress — automated review pending.

Resolves #{issue_number}
[View run]($RUN_URL)

Generated via \`/devflow:implement $ARGUMENTS\`
EOF
)
# Local-tier run has no run URL: drop the broken "[View run]()" line rather than
# leaving a placeholder link in the PR body.
[ -n "$RUN_URL" ] || BODY=$(printf '%s\n' "$BODY" | grep -vF '[View run]()')
gh pr create --base "$BASE" --draft --title "{issue title}" --body "$BODY"
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

`/simplify` runs the code-review engine over the current diff in **quality-only** mode — the **reuse / simplification / efficiency / altitude** cleanup angles — and applies the fixes directly instead of stopping at a report (skipping any whose fix would change intended behavior). By its own charter it does not hunt for bugs; use `/code-review` for that. It remains a fast self-review that catches the quality issues the heavier `review-and-fix` engine in 3.3 would otherwise spend turns on, keeping 3.3 focused on correctness, contracts, and verification rather than quality nits.

**Cleanup agents are quality-only; they never own correctness.** These operative rules follow from that charter:

- `/simplify`'s cleanup agents are quality-only reviewers, never correctness reviewers — chartered for the reuse / simplification / efficiency / altitude angles only.
- The orchestrator never solicits a correctness or guard-class verdict from a `/simplify` cleanup agent.
- The orchestrator never records a cleanup agent's "clean" report as evidence toward any correctness class — a "clean" from an agent chartered not to examine correctness is not evidence that correctness holds.
- Correctness is owned by the Phase 3.3 reviewers, whose dispatch prompts carry the repo's guard classes via `.devflow/prompt-extensions/review-and-fix.md` (a consumer prompt extension that `/simplify`, a built-in Claude Code skill, never loads).

**Triage each `/simplify` finding against the issue's acceptance criteria before applying it (this `/devflow:implement` path only).** The `/simplify` cleanup agents see only the diff — never the issue's `## Acceptance Criteria` or any Phase 2.2.5 scope decisions — so a cleanup that reads as correct against the diff alone can directly violate the issue's deliberate scope (e.g. move a rule out of the file an AC pinned it to, or trim an exclusion list or wording an AC mandated). Before applying each finding, evaluate it against the workpad's in-scope `## Acceptance Criteria` and Phase 2.2.5 scope-decision notes — **against both the *literal* AC text and the *generality / consumer-facing* ACs** (an AC that mandates a surface stay broad, work for all consumers, or not narrow an event/input/filter). A finding can satisfy every literal AC while breaking a generality one: **any finding that narrows an event, input, or filter surface re-runs the consumer-boundary question before it lands** — does this narrowing still serve every consumer the AC intends, or does it optimize for the literal cases only? (On #304 an applied efficiency finding narrowed the `workflow_run` event filter in a way that satisfied every literal AC while breaking push-CI consumer repos — a generality AC — caught only by a later shadow.) If its fix would violate an acceptance criterion (literal or generality) or the decided scope, **skip the finding and record the AC conflict as the skip rationale** via `workpad.py update $ISSUE_NUMBER --note "skipped /simplify finding: {finding}; would violate AC: {which criterion}"`. Apply findings that do not conflict as normal. This triage is the apply-time analogue of the Phase 3.4 AC gate and exists only on the issue-context `/devflow:implement` path — it does **not** change standalone `/simplify` / `/code-review` behavior, which carry no issue/AC context. One carve-out: a finding that conflicts with a now-*stale* AC that a legitimate refactor superseded is **not** a silent skip — that is Phase 2.2.6 AC-rewrite territory (rewrite the AC text with a `--note` paper trail, then let the finding apply), never this guardrail.

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
# Portable enumeration (this prose block runs under the AGENT's shell — zsh/dash/sh — not a
# bash-shebanged .sh, so no bash-only glob-completion builtin, and the unquoted glob must survive zsh's
# default `nomatch`). The guard turns nomatch off under native zsh (no-op elsewhere: $ZSH_VERSION
# unset → `&&` short-circuits, `|| :` stays rc-0). `set --` captures the matched iter-*.json into
# "$@" (with nomatch off, an unmatched glob leaves $1 the literal pattern). `[ -e "$1" ]` gates
# the enumeration so the EMPTY-set case writes an EMPTY snapshot file — never the literal
# unmatched pattern — via the builtin `printf` (no external tool whose absence could fake output).
[ -n "${ZSH_VERSION:-}" ] && setopt nonomatch || :
set -- "$ROOT"/.devflow/tmp/review/*/*/iter-*.json
{ [ -e "$1" ] && printf '%s\n' "$@" | sort; } > "$ROOT/.devflow/tmp/.phase33-iters-before" || :
```

Invoke the **Skill tool** with `skill: review-and-fix` and `args: "--push-each-iteration"`. The flag is load-bearing here: this phase operates on the live draft PR created in 3.1, and `--push-each-iteration` propagates each fix iteration to the remote branch so its CI validates the converging state and progress survives a mid-loop crash. (Direct users of `/devflow:review-and-fix` omit the flag and the loop stays local — see that skill's Input section for the flag's semantics.)

**Stay on the instrumented loop — a cloud permission/sandbox denial is not license to leave it.** This phase drives `review-and-fix` **inline in your context**. If you hit a `claude-code-action` permission or sandbox denial here — a piped/compound `.sh` invocation, a `$(...)` redirect target, or a shell `>` write into `.devflow/tmp` refused as "may only write to files in allowed working directories" — that denial is not the local-tier permission classifier, and is not license to abandon the instrumented loop and hand-run the review engine via direct `Agent` dispatch. On the cloud implement job `Skill`, `Agent`, `Write`, `efficiency-trace.sh`, `workpad.py`, and `config-get.sh` are all allowlisted, so the instrumented loop is navigable, not blocked. Whatever path the review runs, the per-iteration effectiveness record (`iter-<N>.json`) is a non-optional emit on every iteration, written with the Write tool (never a shell `>`/heredoc redirect the sandbox denies) — that is what keeps the **effectiveness** half of the telemetry recoverable even on a degraded, hand-run pass; and the emit is non-optional **on every path, including a degraded one**.

**A denied `Skill` call is not the engine being unavailable — `Skill` is a loader, and the engine is a file in the tree.** This dissolves the dilemma before any telemetry argument is needed. `review-and-fix` executes `skills/review/SKILL.md` Phases 0–4.3 verbatim; those files are in the checkout. If the `Skill` invocation is refused twice, apply the repo's own shape discipline (two denials of a shape → switch to a permitted alternative, never iterate variants): **`Read` the engine from the tree and execute its phases inline.** That is not "hand-running the review from memory" — it *is* the engine, from source. The only thing you may never substitute is a **paraphrase**: five agents dispatched from recollection, with no checklist generate/dedupe/verify, no Step 2.5 classification, no shadow pass, no deferrals manifest, no convergence criteria, is a different artifact wearing the label of a DevFlow review. Note also what the tempting rationalization that a hand-run pass "saves half the time" actually measures: the engine's time *is* those phases, so the saving **is** the omission — that is arithmetic, not a judgment call.

**What the emit protects, stated precisely — claim no more than this, because a claim the harness can falsify teaches the reader to discount the true ones.** Do **not** argue that the data is *unrecoverable*: the cloud `execution_file` is a message transcript, so a reviewer's findings prose lands in it, and even the Phase 1.1.5 cap announcement is chat (in standalone `/devflow:review` that announcement is the *only* surface the engine ships). The true claim is narrower and stronger: **the emit is the only form any shipping code reads.** `lib/efficiency-trace.sh` pins the `iter-*.json` field contract and `--persist` derives `.devflow/logs/efficiency/` from it; `lib/efficiency-trace.jq` derives `verification_posture` from its `checklist[]`; and `defect_signature` is the correlation key the review engine itself joins on — Phase 3.2's mechanical corroboration and the fix loop's iter-(N+1) prior-findings handoff both key on it. **Nothing in the tree parses review findings or telemetry out of `execution_file` prose — the shipped readers consume only structured fields (denials, tool names, result status).** So the emit is structured, joinable data that ships, versus prose that nothing parses — and your **adjudication** in particular (the calibrated `severity`, the `fix_decision` and its reasoning, the `defect_signature`) is a judgment, not an event: it exists only because you record it. Drop the emit and no shipping consumer sees any of it, on either tier.

(On the **token/wall-clock-cost** half, be precise rather than alarmist: issue #437 measured that the cloud `execution_file` *does* carry per-message tokens, wall-clock, the dispatch roster and cost with zero agent cooperation — so on the cloud tier that data is **un-ingested, not lost**, and a floor that reads it is buildable; on the **local** tier the only thing measured was that the `Stop` transcript's token counts are **real** rather than placeholders — **not** wall-clock, **not** the roster. Nothing ships today that ingests either. The cost half is therefore a *backlog* gap, and a cloud-tier agent can correctly defeat it as a reason to stay on the loop. **Do not rest the obligation on it** — rest it on the adjudication above (a judgment that exists only if recorded) and on `cap_drops` as structured, joinable data: nothing shipped ingests the chat announcement it would otherwise have to be scraped from.) When you need a scratch or telemetry file under `.devflow/tmp`, author it with the Write tool, not a shell redirect; the pre-loop snapshot below is a shell-computed listing whose redirect may itself be refused — its failure does not abort the phase, though it degrades the no-inputs detector to whole-tree presence (which the detector's own `::warning::` surfaces on the run log, because on the persistent local tier a leftover `iter-*.json` can then mask a real loss); it is a degrade to note, not a hard blocker, and never a reason to leave the loop.

This runs the four-phase review engine in your context:
1. **Verification checklist** — generates and verifies every dependency interaction, test-mock alignment, data format assumption, and API contract claim against actual source code
2. **Existing review agents** — runs the first-party review agents (code-reviewer, silent-failure-hunter, comment-analyzer, type-design-analyzer, pr-test-analyzer) and the first-party `devflow:requesting-code-review` final-pass reviewer in parallel
3. **Automatic fix loop** — fixes findings using `devflow:receiving-code-review` principles, re-runs the engine, loops until APPROVE or the configured iteration cap (`devflow_review_and_fix.max_iterations`, default 5)

Follow the skill's instructions. It handles evaluation, fixing, testing, and re-review internally.

**Observability-persistence backstop (after `review-and-fix` returns, before the verdict branches below).** `review-and-fix`'s Loop Exit is what normally derives this run's effectiveness record (`.devflow/logs/efficiency/<slug>-<run-id>.json`) and durable workpad copy from its per-iteration `iter-*.json`. But this phase drives that loop **inline in your context**, so a dropped Loop Exit leaves those artifacts unpersisted and the run contributes nothing to `.devflow/logs/efficiency/` — the skill's own #1 documented "Common Mistake," unguarded at this seam. So regardless of the verdict, first **verify this run's observability artifacts were persisted and run the efficiency-trace persist backstop when they are missing**; the backstop is idempotent (it never re-derives an existing record), so running it unconditionally is safe. **When the inline loop wrote no per-iteration workpad, `--persist` now first *synthesizes* a minimal iteration record from this run's fix commits** (issue #381 — `fix: address review findings (iteration N)` commits → `iter` / `fix_commit_sha` / `fix_files` / `loop_role` / `synthesized: true`), so the zero-workpad case is answered by synthesis, not only a reflection. The synthesized `iter-*.json` land under the same `.devflow/tmp/review/` tree, so the new-input detector below counts them as recovered inputs and does **not** fire the gap reflection. **Only when synthesis *also* finds nothing** — the loop wrote no workpad **and** synthesis recovered nothing (no unrecorded fix commit, a failed search — unresolvable base ref or a failed `git log` — failed writes, a discovery-mode skip: workpad-less run dirs ambiguous across slugs, or this dir not its slug's synthesis target, or an unsubstituted `<placeholder>` identity refused by either persist call; `--persist`'s warnings name which when a candidate dir was visited at all) — **record a `dropped-failed` reflection naming the observability gap** so the lost telemetry is visible rather than silently absent:
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
# (always exits 0). Two calls, targeted FIRST: this orchestrator drove review-and-fix
# inline and holds the loop's <slug> and RUN_ID, and persisting its own run by explicit
# identity is immune to every discovery-mode skip (multi-slug ambiguity, not-latest
# ordering) AND to the lone-stale-foreign-dir shape, where discovery would misattribute
# this branch's fix commits to a leftover slug and the sha exclusion would lock the
# misattribution in while the new synthesized files suppressed the gap reflection. The
# argument-less discovery call then covers every OTHER leftover run dir on disk. If the
# slug/run-id are genuinely not held (the inline loop died before RUN_ID was computed),
# skip the targeted call with a --note recording that, and rely on discovery + the
# detector below as the loud floor — never substitute guessed values.
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
# Targeted persist FIRST (substituting this run's held <slug>/<run-id> — the
# targeted form is exempt from every discovery-mode skip by caller intent):
"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../lib/efficiency-trace.sh --workpad-dir "$ROOT/.devflow/tmp/review/<slug>/<run-id>" --slug "<slug>" --persist 2>"$PERSIST_ERR" || true
# Then argument-less discovery for every OTHER leftover run dir on disk; its
# stderr appends to the same capture so the single surfacing line carries both:
"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../lib/efficiency-trace.sh --persist 2>>"$PERSIST_ERR" || true   # best-effort; captured (not swallowed) so its ::warning:: breadcrumbs both surface to the run log below AND are checked for a record-write failure by the detector
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
# Portable, no bash-only glob-completion builtin (this prose runs under the agent's shell — zsh/dash/sh). The
# zsh nomatch guard + `set --` capture the current iter-*.json into "$@"; the two arms then make
# the "no inputs FROM THIS RUN" decision STRUCTURALLY distinguish a genuine zero-set from a failed
# enumeration: `[ ! -e "$1" ]` is definitive absence (zero iter-*.json exist at all — with nomatch
# off an unmatched glob leaves $1 the literal pattern, so `! -e` is true), and ONLY when files DO
# exist does the `-z` arm enumerate them via the builtin `printf` and diff `comm -13 "$BEFORE"`
# (files present now but not pre-loop = what THIS run wrote). The old glob-completion-builtin substitution form
# could yield empty output from a MISSING glob-completion builtin and fire the false telemetry-loss reflection; the
# builtin `printf` over real matches removes that fail-open path. Caveat (mirrors the site-1
# note): `[ ! -e "$1" ]` reads a dangling-symlink first-match as definitive absence, so it could
# record a false telemetry-loss — irrelevant here (this DevFlow-controlled iter-*.json tree is
# never symlinked); don't "simplify" it into a form that reintroduces that false-loss path.
[ -n "${ZSH_VERSION:-}" ] && setopt nonomatch || :
set -- "$ROOT"/.devflow/tmp/review/*/*/iter-*.json
if [ ! -e "$1" ] || [ -z "$(printf '%s\n' "$@" | sort | comm -13 "$BEFORE" -)" ]; then
  # Guard the loss-record write itself: if workpad.py fails (gh API/permission error,
  # absent reflection section, bad $ISSUE_NUMBER) the ::warning:: keeps the gap visible on
  # the run log rather than silently dropping both the telemetry AND its loss-record — a
  # double silent failure at the exact seam this clause exists to make visible. Mirrors the
  # --persist line's best-effort breadcrumb discipline.
  workpad.py update $ISSUE_NUMBER --reflection-kind dropped-failed --reflection "review-and-fix inline loop wrote no iter-*.json this run AND lib/efficiency-trace.sh --persist synthesized nothing (no unrecorded 'fix: address review findings (iteration N)' commit to reconstruct from, a failed search — unresolvable base ref or failed git log — failed synthesized writes, or a discovery-mode skip such as multi-slug ambiguity or a refused unsubstituted placeholder identity; --persist's own warnings name which when a candidate dir was visited), so this run's effectiveness telemetry (.devflow/logs/efficiency/) is missing" \
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
# runs against the combined capture (the targeted call's stderr plus the whole-tree
# discovery call's), so a
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

**A verification-command criterion is satisfied only by an *in-env* observed pass — never by a CI conclusion. CI is the post-PR merge gate; it is never an in-run verification channel.** The scope is determinable, not a phrase to pattern-match: this rule fires for **any** acceptance criterion whose verification is *running a test/lint/build command* (the project's test suite passes, `shellcheck`/`ruff` pass, a `pytest`/build invocation, …). Run that command **in the run's own environment** and tick the criterion on the pass you observe there. Invoke the command by its **direct leading-token** form (`lib/test/run.sh`, not `bash lib/test/run.sh` — the `bash <path>` wrapper is deny-floored and can never be granted), which resolves because the suite/lint commands are granted through `devflow_implement.allowed_tools` (and `devflow.allowed_tools` for the command path); the suite scripts carry the exec bit + shebang that make the direct form runnable. Do **not** wait for, poll, re-check, or cite CI to gate this criterion — the run neither waits for CI nor ticks anything on it.

- **In-env pass** — the command ran and passed in this environment. Tick the criterion on that observed result (by its 1-based AC position): `workpad.py update $ISSUE_NUMBER --tick-ac-n {N} --note "verified in-env: '{cmd}' observed passing on $(git rev-parse HEAD)"`. The `[x]` asserts a result you *ran and saw* for *this* code.
- **In-env failure** — the command *ran and failed*. That is a real failure, **not** a deferral: do **not** tick and do **not** `(post-merge)` it. Fix it (a small follow-up per step 1 below), or take the gate's Blocked path — `workpad.py update $ISSUE_NUMBER --status Blocked --reflection-kind blocked --reflection "AC unmet: '{cmd}' failed in-env on $(git rev-parse HEAD): {failing jobs}"`, emit the 👎 outcome reaction, and stop.
- **In-env run denied** — the direct-form command is **not granted** in this run's allowlist, so it was refused before it could run. This is a tooling gap, **not** a runtime-environment gap and **not** a CI-deferral: take the gate's **Blocked path** naming the config key that grants it — `workpad.py update $ISSUE_NUMBER --status Blocked --reflection-kind blocked --reflection "AC unmet: verification command '{cmd}' is not granted in this run's environment (direct-form invocation denied) — add it to devflow_implement.allowed_tools (and devflow.allowed_tools for the command path) so the run can verify in-env, then re-run. CI is the post-PR merge gate, not an in-run verification channel, so this criterion is never ticked or deferred on a CI result"` — then emit the 👎 outcome reaction and stop. Never launder a denied verification command into a `(post-merge)` retag or a CI observation.

A bare direct **grep** of a few SKILL-contract pins is **not** a substitute for the suite — it confirms specific pins, not "the suite passes," so it can never by itself satisfy such a criterion.

Tick each criterion as you confirm it, **by its 1-based position** in the workpad's `## Acceptance Criteria` section (the list mirrors the issue's AC order): `workpad.py update $ISSUE_NUMBER --tick-ac-n {N}`. `--tick-ac-n` is repeatable and combinable, so the whole gate can tick every confirmed AC in one call (`--tick-ac-n 1 --tick-ac-n 2 …`) without hand-picking unique prose substrings — and a single bad index no longer discards the rest of the batch (it is reported as a volatile miss while the other ticks land). Cite the verification (a test, a file:line, or a prior note) in a `--note` on the same call where helpful.

**Consume the tick call's exit code — do not advance on the stdout body alone** (per the failure-isolation contract in the Workpad Reference). Because a volatile index miss still PATCHes the body and leaves the target AC `- [ ]`, an unchecked non-zero exit would let the gate pass with an in-scope AC still unticked — the exact silent failure the index contract elsewhere prevents. So after the tick call: if it exited **0**, the named AC rows are now `- [x]` and the gate proceeds; if it exited **non-zero**, read the stderr report naming each unresolved `--tick-ac-n`, re-resolve the position (a Phase 2.2.5 `--replace-acs-file` may have reordered/added/removed AC rows, so the criterion's section-scoped index can have drifted out of range or onto an already-ticked row — `--rewrite-ac` alone preserves order and count) and re-tick, and only when a criterion's tick genuinely cannot be resolved take the gate's Blocked path (step 4 below). The gate passes only when every non-post-merge AC row reads `- [x]` **and** the ticks that set it exited 0.

**Post-merge criteria are exempt from the gate.** A criterion whose checkbox line ends in `(post-merge)` (tagged during Phase 1.2) does not block. The orchestrator's responsibility for a post-merge criterion ends at "the code reaches the state where the live verification *becomes possible* to run." Leave the checkbox unticked — the merger will tick it after deploy via the `## Post-Merge Verification` section that `/pr-description` adds to the PR body in Phase 4.2. Do **not** invent evidence to tick a post-merge box during /devflow:implement; the live signal is what counts.

**Documentation-AC deferral (Phase-4.1-owned, and NOT the `(post-merge)` channel).** An acceptance criterion whose satisfaction is a *documentation edit that Phase 4.1's `devflow:docs` subagent owns* — a `docs/…` deliverable that pass authors, as opposed to a `skills/`/`scripts/`/`lib/`/test change this phase can make now — is **left unticked at this gate, recorded in a workpad deferral note naming the AC (`workpad.py update $ISSUE_NUMBER --note "3.4: doc-AC deferred to Phase 4.1: {AC text}"`), and does not block the gate's blocking check.** This is deliberately **not** the `(post-merge)` channel (reserved for genuinely-live verification the host can never run in-session): a doc-AC is fully dischargeable *in this run* by Phase 4.1, which authors the docs through its normal pass and then ticks the box — so it is neither retagged `(post-merge)` nor routed through rule 1's "do it now" channel below. Phase 4.1 **must** discharge each such deferred doc-AC and tick it (citing the deferral note) **before** the §4.3 terminal `--status Complete` write; an undischargeable doc-AC routes to the existing Blocked path, never to a silent Complete. This deferral mirrors Phase 4.0's recorded-note-plus-downstream-discharge idiom for 2.2.5-deferred criteria, and it does not weaken Phase 2's docs-ownership rule (docs stay Phase-4.1-authored) — it stops the gate from forcing doc authoring into Phase 3 to satisfy a criterion Phase 4.1 owns.

**A `(post-merge)` tag is permitted only when the criterion genuinely requires a runtime environment that does not exist during the implement run** — a live deploy target, a real third-party endpoint, a production data path, or similar. That is the *only* qualifying condition, and it is the observable test the gate applies: *would running this verification require an environment the orchestrator host can never be, no matter which tools were installed?* If yes, it is genuinely-live and `(post-merge)` is correct. If the verification could run on the orchestrator host given the right tools, it is **not** post-merge — even if those tools happen to be unavailable right now. Three cases therefore **never** qualify, and the gate must refuse the tag (or retag) for them:

- **Runnable-but-blocked (local tooling/environment gap).** A criterion you *could* verify on this host but can't right now because a command was denied, a build tool is missing, a helper won't spawn, or a restore errored. A tooling gap is not a runtime-environment gap — route it to the **Blocked path** (step 4 below: `--status Blocked`), which escalates to a human; never launder it into `(post-merge)`. (A denied *verification command* — the run's test/lint/build not granted in the allowlist — takes the same Blocked path, naming `devflow_implement.allowed_tools` as the remedy per the in-env-denied arm above. It never defers to a CI result: CI is the post-PR merge gate, not an in-run verification channel.)
- **Confirmation of a self-authored claim.** A criterion whose purpose is to confirm a behavioral claim the PR already asserts as already-true (in its description, its docs, or its code). It is runnable pre-merge **by construction** — the claim is *about the shipped diff* — so deferring it would defer the one check that could falsify the claim. Refuse the tag regardless of the stated reason: verify it now, or, if it genuinely cannot be satisfied, take the Blocked path.
- **Self-reconfiguration verification.** A criterion whose only unmet precondition is the orchestrator's own session/harness/account being in the configuration the diff just shipped — a `PreToolUse` hook the diff just registered now active, a flag/setting the diff just added now enabled. Because the host *can* become a fresh or child session with the change active, this verification **is runnable on this host and is never `(post-merge)`** — a fresh local session is something the host *can* be, so a "cleanest in a fresh session" rationale does not make it genuinely-live. Run and evidence it before the gate passes — by an **automated test that drives the now-active code path**, or by **spawning or reloading a separate session with the change active and recording the observed result** — or, if it genuinely cannot be run, take the **Blocked path** (step 4). Evidence already produced during development (a seam exercised while prototyping, a block confirmed live in-session before it was reverted) is **captured in the workpad and PR body rather than re-deferred** — do not let that evidence evaporate. The rule never mandates activating a blocking hook mid-run in the orchestrator's own session (that can break the run's own later tool calls); the safe evidencing paths above exist precisely so it never has to.

**Pre-merge probe contract (mandatory before any `(post-merge)` tag or retag exempts a criterion from this gate — whether tagged at Phase 1.2 parse time or retagged here).** The genuinely-live test above is *whole-criterion*: it asks whether the *verification* needs a runtime environment the host can never be. But a criterion that passes that test can still carry a **pre-merge-observable precondition that is already false** — and a `(post-merge)` tag means "the live verification genuinely cannot run until after merge, **and everything observable now has been checked**," not "the whole criterion is deferred unexamined." So before the tag lands, decompose the criterion and probe its observable preconditions:

1. **Decompose** the criterion into **(a) pre-merge-observable preconditions** — remote configuration state readable via a read-only `gh api` call (repo settings, a ruleset's required checks and bypass-actor list, branch protection), static properties of the shipped files (a workflow's declared `permissions:` / token wiring, a config key's presence), any fact the orchestrator host can observe now — and **(b) the genuinely-live residue** that only a merge / deploy / live CI run can produce.
2. **Probe every (a) precondition read-only**, using REST `gh api` reads (per the CLAUDE.md label/REST gotcha) and static greps of the shipped files. **The probe set MUST include any failure mode the linked issue's Potential Gotchas or Implementation Notes names for that criterion's mechanism** — the issue often already names the exact pre-merge-observable state that later detonates (issue #294's Potential Gotchas named the ruleset bypass-actor gap that PR #301 then hit post-merge on all 5 push attempts). Keep the obligation **bounded** to the deferred criterion's own named mechanism plus those issue-named failure modes — it is not open-ended research.
3. **Record each probed precondition, the probe command, and its observed result in the deferral `--note`** — with the probe's timestamp, since pre-merge state can drift before merge — or, when the observable set is genuinely empty, the explicit finding `"no pre-merge-observable precondition"`. An empty set is legal and recordable; a *silent* deferral carrying no probe record is the defect.
4. **An observed result showing the deferred live verification cannot succeed as shipped routes to a pre-merge fix or the Blocked path (step 4 below) — never a deferral.** A probe that observes a precondition is already false is a blocker you can fix now, not a live check to punt.
5. **A denied probe (classifier / sandbox) is recorded as denied and the deferral proceeds.** A denial is *not* an observed-false result, so it never blocks a genuinely-live deferral — this must not recreate the runnable-but-blocked launder in reverse. **Tell the two apart by whether the probe obtained a definitive answer about the precondition — never by the raw exit status alone.** Classify *denied* only when the state could not be read at all: the classifier / sandbox refused the command, the network failed, or the API returned an auth/permission error (401/403 the token can't satisfy) so the config is unreadable. Everything that *did* obtain a definitive answer is an **observed** result routed by step 4 — and that explicitly includes a non-zero `gh api` exit that carries one: an HTTP **404** ("the ruleset / branch-protection object is absent") and a **200 with falsy data** (an empty required-checks array, an absent bypass actor) are both **observed-false**, not denials. Do not read "`gh api` exited non-zero → the probe never ran → denied → proceed": a 404 is the object being observably absent, which is exactly the #294/#301 precondition failure, and laundering it into a denial is the reverse launder this rule forbids.
6. **A passed probe never ticks the AC box.** A passed probe only *narrows* the deferral to the genuinely-live residue; the live signal still owns the tick and the genuinely-live residue check always remains. The checkbox stays unticked either way.

This contract is the single source of truth for both the Phase 1.2 tag-time path (`skills/implement/phases/phase-1-setup.md`) and the retro-tag path below.

**Red flags that you are about to launder a runnable check into `(post-merge)`** — STOP and take the Blocked path (step 4) instead:
- "The suite/lint/helper won't run *here*, so I'll mark it post-merge and let CI catch it." → tooling gap: **Blocked path** naming `devflow_implement.allowed_tools` (grant the command so the run verifies in-env) — **never** a retag and **never** a CI deferral.
- "This criterion just confirms what the PR already says, so it's safe to defer." → confirmation-AC: **never** post-merge.
- "The hook/flag/setting I just added only takes effect in a fresh session, so I'll mark it post-merge." → self-reconfiguration: run-and-evidence (an automated test driving the now-active path, or a separate session observing the change live), Blocked as the fallback — **never** a retag.
- "It's *basically* a live check." → if it could run on this host with the right tools, it is **not** live.
- "The pre-merge probe came back showing the deferred check can't succeed as shipped, but I'll defer it and let the merge surface it." → observed-cannot-succeed probe: **never** a deferral — a probe that observed a precondition is already false is a pre-merge fix or the Blocked path (step 4), not a `(post-merge)` tag. (A *denied* probe is different — a denial is not an observed-false result and does not block a genuinely-live deferral.)

If the workpad's Acceptance Criteria section reads `_(none provided in issue body)_`, the gate passes trivially.

The gate applies only to criteria currently in the workpad's `## Acceptance Criteria` section. If you scoped down via the 2.2.5 rule, deferred criteria live in the workpad notes and are **not** gated here — they will be carried into a follow-up issue in Phase 4.0.

If non-post-merge criteria remain unchecked after Phase 3.3:

1. If a criterion is satisfiable with a small follow-up edit, do it now (still inside Phase 3) — write the code, run tests, commit (using the `fix:` prefix), tick the box, and continue. **This "do it now" channel excludes documentation authoring owned by Phase 4.1** (a `docs/…` deliverable the `devflow:docs` subagent authors): a doc-AC is deferred to Phase 4.1 per the *Documentation-AC deferral* rule above, never written here in Phase 3 to tick the box.
2. If a criterion's *literal text* is now stale because /simplify or /devflow:review-and-fix refactored the structure (e.g. renamed jobs, merged files), but the *underlying behavior* the criterion verifies is preserved in the diff, apply **2.2.6** now: rewrite the AC text in the workpad with a `--note` paper trail, then tick the box.
3. If a criterion is genuinely outside this PR's scope and you missed it during 2.2.5, **go back to 2.2.5 now**: move the item to the workpad notes (`--note`) as deferred, rewrite the Acceptance Criteria section, PATCH, and re-run this gate against the narrowed set. Then continue to Phase 4.
4. Otherwise — i.e. the criterion is in-scope but you cannot satisfy it AND it is not tagged `(post-merge)` — `workpad.py update $ISSUE_NUMBER --status Blocked --reflection-kind blocked --reflection "AC unmet (in-scope, not post-merge): {AC text}"`, then emit the 👎 outcome reaction (see *Outcome reaction* in the Workpad Reference) and stop the run with a clear report to the user. Do **not** advance to Phase 4 with unmet in-scope, non-post-merge criteria.

Once the gate passes (every non-post-merge AC ticked), tick the gate **and its parent phase** in the workpad: `workpad.py update $ISSUE_NUMBER --tick-progress "acceptance-criteria gate" --tick-progress "**Review**"`.

(A criterion the orchestrator can't satisfy may be retroactively tagged `(post-merge)` **only if it is genuinely-live by the rule above** — it requires a runtime environment absent during the run, it is *not* a runnable-but-blocked tooling gap, it is *not* the confirmation of a self-authored claim, and it is *not* a self-reconfiguration verification (the change's own hook/flag/setting needing an active session). **Before the retag lands, run the Pre-merge probe contract above** — decompose the criterion, probe every pre-merge-observable precondition read-only (folding in any failure mode the linked issue's Potential Gotchas / Implementation Notes names for its mechanism), and record each probed precondition, the probe command, and its observed result in the retag `--note` — or the explicit finding `"no pre-merge-observable precondition"`. A probe whose observed result shows the deferred live verification cannot succeed as shipped routes to a pre-merge fix or the Blocked path — **never** this retag. When it qualifies and every probe passes (or is recorded denied), retag with `workpad.py update $ISSUE_NUMBER --rewrite-ac "{old text}" "{old text} (post-merge)" --note "retro-tagged as post-merge (genuinely-live): {the runtime env it requires}. Pre-merge probes: {precondition → command → observed result, each}; or 'no pre-merge-observable precondition'"` — the `--note` rationale is **mandatory**: `workpad.py` structurally aborts a `--rewrite-ac` that appends the `(post-merge)` tag without one (issue #338), so the retag is always a recorded, auditable claim. Then let it pass the gate. The passed probes narrow the deferral to the genuinely-live residue; they do **not** tick the AC box. If it fails the genuinely-live rule — runnable on this host, blocked only by local tooling, a self-claim confirmation, or a self-reconfiguration verification — do **not** retag; take the Blocked path (step 4 above) instead.)

### 3.5 Tick Phase-3-completed Plan steps

Two kinds of `## Plan` step routinely **complete in Phase 3**, not Phase 2, so the Phase 2 "tick plan steps as they complete" loop never reaches them — leaving their rows falsely `- [ ]` on a finished run. Tick each **at the point its work completes here**, so the terminal Phase 4.3 `--status Complete` self-record gate's non-blocking `## Plan` warning fires only on a genuinely dropped/superseded step (that gate: a non-post-merge unticked **AC** row hard-fails the Complete write, while an unticked **Plan** row only warns — see the finalize call in Phase 4.3):

- **The versioning step** (where repo policy declares the version change — e.g. this repo's changeset workflow, per `.devflow/prompt-extensions/implement.md`, applied after the draft PR exists but before the review pass): once the artifact that step produces is committed — for a changeset-based repo, the `.changeset/*.md` file; for a repo that still bumps in-PR, the version bump + matching `CHANGELOG` entry — tick its Plan row — `workpad.py update $ISSUE_NUMBER --tick-plan "{substring of the versioning plan step}"`. The Phase 3 review gate then fails an engine-surface change that carries **no** such versioning artifact (for this repo, a missing changeset file) and passes one that does.
- **The final full-suite / `shellcheck` / `ruff` run**: once you have observed it green **in-env** (the direct-form command granted via `devflow_implement.allowed_tools` — never a CI conclusion), tick its Plan row — `workpad.py update $ISSUE_NUMBER --tick-plan "{substring of the final-suite plan step}"`. A denied verification command takes the Blocked path (§3.4), not a CI deferral.

Only tick a step your plan actually lists (a `--tick-plan` that matches nothing is a volatile miss); if this run's plan carries no such step — a consumer repo with no version policy, say — skip its tick. Consume the tick call's exit code as everywhere else (a non-zero exit means the substring did not resolve to exactly one unticked row — re-resolve and re-tick).

**⚠ You are NOT done. PR is still a draft and needs documentation and a proper description. Proceed to Phase 4.**
