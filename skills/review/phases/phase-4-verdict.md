<!-- devflow:review-ref phase=4 file=skills/review/phases/phase-4-verdict.md start -->
## Phase 4: Aggregation and Verdict

Output: `Phase 4/4: Aggregating findings...`

### 4.0 Match deferrals from PR body (PR mode only)

**Skip this step entirely in current-branch mode** (no PR → no body to read). On standalone branch reviews, there is no Scope-Acknowledged Findings block; jump straight to 4.1.

When `$ARGUMENTS` is a PR number, the engine consults the **Scope-Acknowledged Findings** block in the PR body (delimited by `<!-- DEVFLOW_DEFERRED_FINDINGS_START -->` / `<!-- DEVFLOW_DEFERRED_FINDINGS_END -->`) and demotes any current finding matching a validated deferral entry to **Informational**. This is the consumer side of the contract /devflow:implement Phase 4.0.5 produces; without it, /devflow:review re-raises findings /devflow:implement already filed follow-up issues for. (See `"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/match-deferrals.py` for the matcher's exact guard order and matching rule.)

Serialize the Phase 3 findings collected in 3.2 to a JSON array with one object per finding:

```json
[
  {"file": "...", "line_range": [N, M], "kind": "...", "description": "...",
   "severity": "Critical|Important|Suggestion", "agent": "..."}
]
```

The order matters — index N in this array becomes the matcher's `finding_index` reference.

Pipe the JSON to the matcher via stdin (the `review` allowed-tools profile in `claude-runner.yml` is read-only and does not grant the Write tool, so the orchestrator cannot write a `findings.json` file; stdin is the load-bearing alternative):

```bash
printf '%s' "$FINDINGS_JSON" | "${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/match-deferrals.py \
    --pr $ARGUMENTS \
    --diff ".devflow/tmp/review/<slug>/<run-id>/diff.patch" \
    --findings -
```

Capture the matcher's stdout (the JSON report described below). When invoked from /devflow:implement Phase 3.3 via /devflow:review-and-fix (which DOES have the Write tool), the file form `--findings .devflow/tmp/review/<slug>/<run-id>/findings.json` is equally supported — pick whichever the surrounding profile permits.

The matcher always exits 0 when it ran (any result, including no block found). Read the output JSON:

- `block_present: false` → PR has no Scope-Acknowledged Findings block; proceed to 4.1 with all findings intact.
- `pr_author_trusted: false` → PR author is not in `devflow.allowed_bots`; **every** deferral is rejected with reason `untrusted-filer`. All findings flow through unchanged. Include the rejection list in 4.1's `## Deferrals` section so the human reader sees the contract was claimed but not honorable.
- For each entry in `honored[]`: the finding at `findings[finding_index]` is **demoted to Informational** for the rest of Phase 4. Record the `deferral_id` + `follow_up_issue` so the 4.1 line annotation can cite them.
- **A `settled-by-disclosure` foreclosure match (issue #621)** (an `honored[]` entry, category `settled-by-disclosure`, null `follow_up_issue`) is demoted **only when the matched finding is below this run's `verdict_severity_threshold`** — no follow-up work backs it, so it **never demotes a verdict-gating finding** (an at-or-above match is reported undemoted). Its 4.1 line **quotes the `disclosure.phrase` inline** for the merge gate.
- For each entry in `rejected_deferrals[]`: the deferral did not apply (issue closed, missing cross-link, widens-surface failed, a foreclosure's disclosure failed to verify — `disclosure-unverified`, or no matching finding). The current finding (if any) is **not** demoted — flag it in 4.1's `## Deferrals` section with the reason.

**A self-contradicting-diff finding is never demotable.** The demotion above does **not** apply to a *self-contradicting-diff* finding — a review-agent finding that a doc/release-note line, a code comment, or a test **the PR's own diff added or modified** is untrue (same definition of contradicting the diff as `skills/receiving-code-review/SKILL.md`'s documented-falsehood carve-out: **a claim that is stale, contradicts HEAD, or contradicts another part of this change**). Even when a validated deferral entry in `honored[]` matches such a finding, it may **not** be demoted to Informational / pre-existing / out-of-scope, and the deferral path does **not** satisfy the Phase 4.2 gate for it — only a **fix** (correct the prose, or the code the prose describes) clears the REJECT it drives (Phase 4.2's self-contradicting-diff carve-out). Leave the finding at its original severity bucket in the 4.1 report (not under "Informational — Deferred") with the "deferral not honored — self-contradicting diff" annotation described in 4.1, and let Phase 4.2 REJECT on it.

If the matcher itself errors out (exit code 2), log the failure (`Deferral matcher failed: {stderr}; proceeding without demotions.`) and continue to 4.1 with all findings intact. Never block the review on a matcher failure — the safe default is to surface findings, not hide them.

**Caching note.** The matcher makes N+1 GitHub API calls for N deferrals (PR body/author + one per `follow_up.issue` cross-link guard). Tolerable; batch via `gh api graphql` if it ever bottlenecks.

### 4.1 Build the report

**GitHub autolink hygiene** (this report is posted as a PR comment/review): never put a bare `#` immediately before a number unless it is a real issue or PR reference — GitHub renders `#2` as a link to issue/PR 2, which misleads readers. For an ordinal, count, or list position, spell it out ("item 2", "step 3"), never `#2`. Genuine references like `#123` stay as-is.

Construct the report in this format:

```markdown
## Verdict: {APPROVE | APPROVE with notes | APPROVE WITH CAVEAT | APPROVE WITH ADVISORY NOTES | REJECT} ({summary})

## Issue Compliance
{If issue found: "Reviewed against issue #{number}: {title}. Requirement-based checklist items are included in the verification results below."}
{If no issue found: "No related issue found — requirement compliance not checked."}

## Verification Checklist Results
{a plain-text line, not a bullet, no surrounding parentheses:} {pass} passed, {fail} failed, {inconclusive} inconclusive — {lite_count} via lite probe, {agent_count} via agent.
{for each FAIL or INCONCLUSIVE item: "- VC-N: VERDICT — claim [source_file:source_line]"}
{when {pass} > 0, emit the PASS items inside a collapsed block — `{pass}` − `{normalized_count}` MUST equal the number of `- VC-N` lines listed inside it (normalized items render outside the block, so they are excluded from this equality). Leave a blank line before `<details>` so GitHub renders the collapsible correctly after the preceding list:}

<details><summary>✅ Passed items ({pass} − {normalized_count} of {total}) — click to expand</summary>

{for each PASS item not carrying `normalized: true`: "- VC-N: claim [source_file:source_line]"}

</details>
{for each item carrying `normalized: true`, render it visibly OUTSIDE the `<details>` block: "- VC-N: NORMALIZED (wording-only) — claim [source_file:source_line]"}
{when {pass} == 0, omit the `<details>` block entirely — never emit an empty collapsible.}

FAIL and INCONCLUSIVE items stay listed outside the `<details>` block so they remain visible. The block renders collapsibly on GitHub; in a chat-only `/devflow:review-and-fix` run it renders as inline HTML, which stays readable.

## Code Review Findings
{Group findings by severity under a sub-heading that carries the severity icon — "### 🔴 Critical", "### 🟠 Important / Major", "### 🟡 Suggestion / Minor", "### ℹ️ Informational — Deferred". Emit the sub-headings in that order and omit any whose group has no findings.}
{Within each group render each finding as a numbered-list item with NO icon, NO agent-name prefix, and NO severity-word prefix: "1. description (raised by N/{total Phase 3 agents that returned results} agents)", numbering restarting from 1 within each sub-heading. The severity is conveyed by the sub-heading alone — never repeat the icon or the severity word ("Critical:", "Important:", "Suggestion:") on the list items.}
{Stamp EVERY self-contradicting-diff carve-out finding (Phase 4.0/4.2 — a doc/release-note line, comment, or test the diff added or modified that is untrue) with the **unconditional machine-detectable marker** ` [self-contradicting-diff carve-out: {file}]` appended **immediately after that line's `(raised by N/M agents)` agent-count suffix**, regardless of deferral status. The marker therefore always lands in the finding line's **trailing bracketed-annotation region** — the run of ` [...]` annotations following that suffix — and **never inside the finding's free-prose `description`**, which precedes it. Note the marker is *not* necessarily line-final: the deferral annotation and the 4.1.5 over-grade annotation below append *after* it. This fixed position is a contract, not a formatting preference: it is the only thing that lets the Phase 0.3.6 consumer match the marker **structurally** rather than by a bare substring scan of the line — a scan that a finding quoting the marker literal in its prose would fool. `{file}` is REQUIRED and is the finding's `defect_signature.file` — the repo-relative path of the single file carrying the untrue line. The rendered finding line is otherwise free prose, so this marker is the **only** place the blocker's file survives into the report; a finding whose `defect_signature.file` is absent gets the marker with the literal `{file}` replaced by `unknown` (never omit the marker, never invent a path). This marker is a **producer key**: the Phase 0.3.6 blocker-recheck fast path reads it both to tell a carve-out blocker apart from an ordinary code finding and to recover the blocker's file — a REJECT-driving finding *without* this marker is a non-carve-out finding there, and a marker carrying `unknown` yields no file-scoped blocker; either fails the fast path's preconditions closed. (Coupled with the Phase 0.3.6 precondition-3/4 consumer and its `lib/test/run.sh` pin.)}
{for findings whose index appears in the matcher's honored[] list, append " [Deferred → #{follow_up_issue}]" to the line and place it under the "### ℹ️ Informational — Deferred" sub-heading rather than under its original severity bucket — **except a self-contradicting-diff finding (Phase 4.0), which is never demoted**: keep it under its original severity bucket and, in addition to the ` [self-contradicting-diff carve-out: {file}]` marker above, append " [Deferral not honored — self-contradicting diff; only a fix clears it]", so Phase 4.2 still REJECTs on it.}
{Within each severity, list corroborated findings (N≥2) before single-source ones (N=1) so the highest-confidence items lead.}
{If Phase 4.1.5 flags a finding as a suspected over-grade, append its advisory annotation to that finding's line here — see 4.1.5. The annotation never changes the verdict.}

## Deferrals
{Omit this section entirely when 4.0 was skipped (current-branch mode) or block_present was false. Otherwise render:}
- Honored: {stats.honored}
{for each honored entry: "  - {deferral_id} → #{follow_up_issue} ({category})"}
- Rejected: {len(rejected_deferrals)}
{for each rejected entry: "  - {deferral_id} — rejected: {reason}"}
{If pr_author_trusted is false, prepend a single line: "**Block claimed but not honored — PR author is not in `devflow.allowed_bots`. All deferrals rejected.**"}

## Verdict Criteria
- Any FAIL in verification checklist → REJECT
- Any INCONCLUSIVE in verification checklist → REJECT (manual check needed)
- Any finding that a doc/release-note line, comment, or test **the diff added or modified** is untrue → REJECT at every threshold value and regardless of severity chip (self-contradicting-diff carve-out — a claim that is stale, contradicts HEAD, or contradicts another part of this change; non-demotable, corroboration-independent)
- A deterministic Phase 0.6 stale-prose `STALE` finding participates **only** through the config-gated severity rule above (as a `$SP_SEVERITY` engine finding, per Phase 0.6) and can **never invoke the threshold-independent self-contradicting-diff carve-out**, which is scoped to review-agent findings — so under a `critical` threshold with `stale_prose.severity` below it, a deterministic STALE never flips this verdict.
- A Phase 0.6 STALE row that was **adjudicated a false positive this run** (the Phase 4.1.7 producer triage) **or demoted via the Phase 0.6 adjudication carry-forward join** (a prior run's adjudication) is rendered Informational and is **excluded from verdict computation at every configured `stale_prose.severity`, including `critical`** — a confirmed false positive is not a finding.
- Any finding from review agents at or above the configured verdict threshold ({VERDICT_THRESHOLD}) → REJECT (excluding findings demoted to Informational via Phase 4.0's deferral match; when the threshold admits Important, an admitted finding does not REJECT if it is genuinely pre-existing behavior the diff does not touch — the carve-out above overrides this)
- Checklist generation failed → max APPROVE WITH CAVEAT
- 2+ review agents failed → partial review coverage
- Only findings below the verdict threshold → APPROVE with notes
- No findings → APPROVE
```

### 4.1.5 Over-grade advisory annotation (advisory for shapes 1/3 + non-comment shape 2; a deterministic verdict cap for the in-code-comment sub-case)

**This subsection is the single source of truth for the over-grade shape definitions.** `/devflow:review-and-fix`'s Step 2.6 *Over-grade calibration gate* consumes this same shape list at runtime rather than forking its own copy — keep the shapes defined **here only**, so the standalone-engine annotation and the fix-loop gate can never drift apart.

After building the report (4.1) and **before** computing the verdict (4.2), scan the Phase-3 findings the verdict will weigh (the `Critical` / `Important` / `Major` findings not deferral-demoted in 4.0). **Flag** a finding as a *suspected over-grade* when it matches one of these **observable** over-grade shapes (keyed on observable signals — what the suite catches, which direction the code fails, how many agents corroborated — never on a re-judgment of the finding's merits, or the annotation just relocates the calibration problem it exists to surface):

1. **Suite-RED or fail-closed defect graded above its blast radius** — the defect's own failure mode is one the project's test suite catches **RED**, or the code **fails closed** on the bad input (it aborts / refuses / returns the safe value rather than admitting a wrong one). A fenced or fail-closed defect is real and worth fixing, but its observable blast radius is a loud, bounded stop — not the silent corruption a `Critical`/`Important` grade asserts. **A fail-*open* defect is never this shape** — a defect that admits a wrong value, corrupts state, or silently skips a guard on the triggering input does **not** match, no matter that its limitation is disclosed in a comment or its trigger input is contrived. "Documented" and "contrived" are disclosure facts, not severity facts: contrivedness argues *for* the guard, never for demoting the severity of its failing open. Grade a fail-open defect on the direction it takes on its triggering input, not on how exotic that input is or whether a comment disclosed it (the same reasoning shape 2 applies to a false-against-HEAD artifact).
2. **Diagnostic-or-cosmetic-only finding with no behavioral fail-direction** — the finding's entire observable impact is the wording of a message / breadcrumb / log / comment or another purely-diagnostic surface, with no wrong output, no corrupted state, and no skipped guard. Real and worth fixing, but not a high-severity blast radius. **Excludes a false-against-HEAD diff-added/modified artifact.** A diff-added or diff-modified doc line, code comment, example, or command-form whose claim is **false against HEAD** is **not** cosmetic wording — it is a truthfulness defect (a `documented_falsehood`), because false against HEAD is a truthfulness defect (a self-contradicting diff — non-demotable REJECT); true but awkwardly worded is a clarity Suggestion (demotable). Such an artifact is a self-contradicting diff that the Phase 4.2 carve-out REJECTs non-demotably and is a subject of the Phase 4.1.6 truthfulness sweep below — never a demotable Suggestion under this shape. (This discriminator is single-sourced here; the shared `defect_signature` block and the `comment-analyzer` / `code-reviewer` agent files mirror it verbatim.)
3. **Uncorroborated single-source finding from an empirical over-grader** — the finding is graded `Critical`/`Important` but is **single-source** (corroboration count 1 from Phase 3.2) from `silent-failure-hunter` or `pr-test-analyzer`, with **no** corroboration from any other Phase-3 agent **and** no Phase-2 verification-checklist FAIL covering the same defect. Empirically this uncorroborated-single-source-from-an-empirical-over-grader signal is the highest-probability over-grade.

**Deterministic in-code-comment cap (shape 2 refinement — the one flag that changes the verdict).** Shape 2's *in-code-comment* sub-case is **not** advisory-only: a finding whose **sole** observable impact is an inaccurate or stale **in-code comment**, on a comment the diff under review did **not** add or modify, is **capped at 🟡 Suggestion / Minor deterministically — Phase 4.2 does not REJECT on it** — regardless of the severity a review agent assigned. This is a *severity-classification* rule (a comment-only-on-unmodified-comment defect is by definition ≤ Suggestion/Minor), keyed **only** on the two observable properties — the impact is solely an in-code comment, and that comment was not diff-touched — never on a re-judgment of the finding's merits, so it does **not** reopen the #195 lenient-verdict hole (a genuine behavioral defect is never touched; only this deterministically-defined comment-only class is capped). The cap is **narrow by construction**:
- **In-code comments only.** The cap names in-code comments specifically; shape 2's other diagnostic surfaces — a log line, a breadcrumb, an error / message string — keep their advisory-annotate-only treatment (no verdict change), and shapes 1 and 3 stay advisory-only too.
- **A machine-significant comment is not comment-only impact.** A comment the compiler, linter, or a tool *reads* — a type/lint directive (`# type: ignore`, `# noqa`, an `eslint-disable`/suppression pragma), or a tool-read marker (e.g. a `<!-- devflow:workpad -->`-style marker, an embedded `jq`/shell `#` comment inside a Markdown code fence) — has a **behavioral** fail-direction, so a defect in it is **not** solely-comment impact and the cap does **not** apply: grade it by its behavioral fail-direction like any other finding. The cap covers only genuinely inert prose comments.
- **Excludes any comment the diff added or modified.** A comment *this change itself* introduced or edited that is untrue is a **self-contradicting diff**, which the Phase 4.2 threshold-independent carve-out REJECTs at every threshold, non-demotably — the cap never touches it (it covers only pre-existing, diff-untouched comments; see Phase 4.2).

**On a flag other than the deterministic in-code-comment cap above, standalone `/devflow:review` adds an advisory annotation and nothing else.** Because standalone review has **no fixer** to record a technical evaluation, for an *advisory-only* flag (shapes 1 and 3, and shape 2's non-comment diagnostic surfaces) it MUST **not auto-demote** — append a parenthetical to the flagged finding's line in 4.1's `## Code Review Findings` (alongside the existing `(raised by N/M agents)` clause) of the form `[suspected over-grade: shape {n} — observable fail-direction is {X}, milder than the {severity} label]`, naming the matched shape and the observable fail-direction. **For those advisory-only flags the verdict computation in 4.2 is unchanged** — the annotation never demotes a finding, never alters its severity, and never clears or downgrades a REJECT. A flagged `Critical` still drives REJECT exactly as before; the annotation only tells a human the grade is *suspect*, so they can distinguish a genuine blocker from a diminishing-returns over-grade. **The deterministic in-code-comment cap is the sole exception** — it is a classification rule, not an advisory annotation, so it *does* set the finding to Suggestion/Minor and Phase 4.2 does not REJECT on it, but only for the narrowly-defined comment-only-on-unmodified-comment class (never a diff-added/modified comment, never a non-comment surface).

If no finding matches, add the line `over-grade annotation: no finding flagged` to the report so a clean scan is visible rather than ambiguous with a skipped step.

The full **flag-and-record** gate — which *requires* a recorded `severity-calibrated` technical evaluation before a flagged finding may drive a shadow-promotion, and which still never auto-demotes — lives in `/devflow:review-and-fix` Step 2.6, because the fix loop has a fixer to record that evaluation. Standalone review is **advisory by construction**: do not port the gate's recording requirement here, and never let the annotation change what 4.2 computes. A consumer repo may sharpen these shapes via `.devflow/prompt-extensions/review.md`, but the extension never makes the annotation change the verdict.

### 4.1.6 Pre-verdict truthfulness sweep (promote-only; over every finding regardless of severity chip, plus an intra-diff contradiction scan over the diff itself)

After the over-grade scan (4.1.5) and **before** computing the verdict (4.2), run a **pre-verdict truthfulness sweep** over the Phase-3 findings. Unlike the over-grade scan — which weighs only the `Critical` / `Important` / `Major` findings — this sweep runs over **every** Phase-3 finding **regardless of its severity chip**: `this sweep does **not** inherit 4.1.5's Critical/Important/Major scope`, because the mis-filed falsehood it closes lands at 🟡 Suggestion, exactly where the over-grade scan never looks.

For each finding whose subject is a **diff-added or diff-modified** doc line, code comment, example, or command-form, verify the flagged claim against HEAD by reading the named symbol, command surface, or code path it describes, and apply the shape-2 discriminator (false against HEAD = truthfulness defect, non-demotable; true but awkwardly worded = clarity Suggestion, demotable):

- a **demonstrated** falsehood — the claim is false against the shipped code — is routed into the Phase 4.2 self-contradicting-diff carve-out and drives **REJECT**, **independent of how the producing agent framed or graded it** (a Suggestion-chipped, clarity-worded finding routes exactly like a Critical one). An `example` or `command-form` is a documentation artifact, so it routes into the carve-out **as the doc line or code comment it inhabits** — the carve-out's own byte-frozen `doc/release-note line` / `code comment` categories already cover it; this sweep does **not** widen (and must never edit) the Phase 4.2 carve-out enumeration;
- an **inconclusive** check — the claim cannot be *demonstrated* false against HEAD — leaves the finding **exactly as filed**. The sweep never promotes on suspicion, only on demonstrated falsity — this fail direction is the load-bearing safety property that contains the false-REJECT risk.

**The sweep is promote-only: it never demotes, downgrades, or clears any finding** — it can only *add* a REJECT the Phase 4.2 carve-out already warrants, never remove or soften one (mirroring the shadow pass's promote-only under-grade gate). Scope is strictly diff-added/modified artifacts that contradict the shipped code: an accurate mention of a still-present limitation, a still-valid follow-up reference, a diff-untouched inaccurate comment (governed by the deterministic in-code-comment cap, which this sweep does not touch), a machine-significant comment (lint/type directive, tool-read marker — graded by its behavioral fail-direction), and a subjective or forward-looking statement that asserts no verifiable fact are **never** sweep subjects.

**Diff-scan input — the intra-diff contradiction scan (the failing case has *no* finding to iterate over).** The per-finding pass above cannot catch a contradiction that *no agent flagged*: the PR #340 failure was a diff that published an absolute claim ("a crafted multi-pair sequence … is caught by the same rule") while the *same diff* added or retained a limitation note ("a tag appended to an already-ticked `[x]` row is outside the unticked-row population") that contradicts it — ten reviewers each read the two artifacts as locally plausible, so **no finding existed** for a per-finding sweep to iterate over. So this sweep also takes a **diff-scan input**, independent of the Phase-3 findings: scan the PR's own diff for its **added absolute claims** (a diff-added doc line, comment, example, or help string asserting a universal — "every", "never", "always", "cannot", "is caught by the same rule") and cross-product each against the diff's **added or retained limitation notes** about the **same symbol** ("known limitation", "not closed here", "outside … population", "does not handle"). When a limitation note contradicts an absolute claim's universal — the claim asserts a case the limitation says is *not* covered — that is a self-contradicting diff: **file it as a non-demotable `documented_falsehood` and route it into the Phase 4.2 self-contradicting-diff carve-out (REJECT)**, exactly as a demonstrated per-finding falsehood routes, and independent of whether any Phase-3 agent flagged it. This is the *opposite direction* of the "known limitation the same diff already fixed" shape (which the dispatch shapes already carry): there the diff *closed* the limitation and left a stale note; here the diff *left the limitation open* and published an absolute claim over it. Scope the pairing to the same symbol — an absolute claim and a limitation note about *different* symbols are not a contradiction and produce no finding. If the diff-scan finds no contradicting pair, add the line `intra-diff contradiction scan: no contradiction found` so a clean scan is visible rather than ambiguous with a skipped step.

If the sweep demonstrates no falsehood, add the line `truthfulness sweep: no finding promoted` to the report so a clean pass is visible rather than ambiguous with a skipped step. This sweep is a **classification** step keyed on observable properties (the artifact is diff-added/modified; its claim is demonstrably false against HEAD), never a re-judgment of merits — so it does not reopen the #195 lenient-verdict hole. `/devflow:review-and-fix` and `/devflow:implement` Phase 3 inherit it unchanged through the shared engine.

**#504 displaced-path routing (this sweep).** When verifying a flagged claim about a path the run's ground-truth block lists as #458-displaced, the working-tree copy is base-ref/stub bytes (not HEAD) — verify against `git show <head>:<path>` + the cached diff, never a working-tree read; a base-state claim via `git show $PR_BASE_SHA:<path>`. On a routed-read error where the cached diff does not evidence the path as deleted at head, probe `git cat-file -e <head>:<path>` and leave the finding INCONCLUSIVE (never working-tree/fetch fallback). Listed paths stay fully in review scope (channel, not depth). Inert with no displaced list; per-mode head binding and the full fail direction live in the truthfulness-contract routing (the `defect_signature` block pasted to every Phase-3 agent).

**Phase 4.1.7 runs at this seam — after 4.1.6, before 4.2 — when its gate is met**; 4.2 consumes its adjudications.

### 4.2 Determine verdict

**Resolve the verdict-severity threshold once, before applying the rules.** Read `devflow_review.verdict_severity_threshold` (default `critical`) via the same portable skill-dir-anchored, no-`bash`-prefix `config-get.sh` invocation the live-progress-comment gate uses. `config-get.sh` reads the value but does **not** validate the enum — it coerces any JSON value to a string — so validate the enum **inline** and fall back to the default `critical` on a resolver failure (rc≠0) or any value outside the enum, with a **specific breadcrumb naming the key and the fallback value** (never aborting the review):

```bash
# A missing key returns the default `critical` silently (verdict computation stays
# byte-identical to today). Discriminate a resolver FAILURE from an out-of-enum value
# without carrying a variable across statements (an inline-bash runner that strips such a
# variable would misreport a failure as a bad enum): `if !` reads config-get's OWN exit
# status directly (rc≠0 surfaces its stderr); the value validation is a separate `case` on
# the value alone. Both fall back to the default, each with its own DISTINCT breadcrumb.
if ! VERDICT_THRESHOLD=$("${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/config-get.sh .devflow_review.verdict_severity_threshold critical); then
  echo "::warning::devflow review: could not read .devflow_review.verdict_severity_threshold (config-get.sh rc≠0 — malformed config.json or missing python3?); using default 'critical'" >&2
  VERDICT_THRESHOLD=critical
fi
case "$VERDICT_THRESHOLD" in
  critical|important|suggestion) : ;;
  *) echo "::warning::devflow review: .devflow_review.verdict_severity_threshold value '$VERDICT_THRESHOLD' is not one of critical/important/suggestion; using default 'critical'" >&2
     VERDICT_THRESHOLD=critical ;;
esac
```

Severity ordering: `critical` > `important` > `suggestion`; "at or above `$VERDICT_THRESHOLD`" reads down that ladder. This threshold moves **only the REJECT line (rule 3)** below; every other rule and verdict label is unchanged. At the default `critical` (or an absent key) rule 3 fires on exactly the Critical findings it always has, so **rule 3's verdict computation is byte-identical to today for findings that do not contradict the diff** (the threshold-independent self-contradicting-diff carve-out below is the one deliberate default-`critical` change — a self-contradicting-diff finding now drives REJECT; see Phase 4.2).

**Threshold-independent self-contradicting-diff carve-out (evaluated before the numbered rules — a correctness principle, not a severity grade).** A review-agent finding that a doc/release-note line, a code comment, or a test **the PR's own diff added or modified** is untrue drives **REJECT** at **every** `verdict_severity_threshold` value — including the default `critical` — and **regardless of the severity chip** the agent assigned it (a Suggestion-graded self-contradiction still REJECTs). This mirrors the documented-falsehood carve-out in `skills/receiving-code-review/SKILL.md` and shares its definition of contradicting the diff: **a claim that is stale, contradicts HEAD, or contradicts another part of this change**. It is **not demotable** — Phase 4.0's deferral match may not demote such a finding, and the deferral path does not satisfy this gate for it; only a **fix** clears the REJECT. It is **not** conditioned on the Phase 3.2 corroboration count — a single-source self-contradicting finding blocks exactly like a corroborated one. Because it is always in-scope, the rule 3 in-scope qualifier below never reclassifies it as pre-existing.

**Complement — the deterministic in-code-comment cap (Phase 4.1.5).** The mirror case — a finding whose sole observable impact is an inaccurate/stale in-code comment the diff did **not** add or modify — is capped at Suggestion/Minor by 4.1.5, so it does **not** drive REJECT here. The cap and this carve-out **partition the comment-only space by whether the diff touched the comment**: a diff-added/modified untrue comment is a self-contradicting diff (REJECT above, non-demotable), a pre-existing diff-untouched inaccurate comment is capped (≤ Minor, no REJECT). The two never collide, and the cap **never overrides** this carve-out — a diff-added or diff-modified untrue comment still REJECTs at every threshold regardless of the cap.

Apply these rules in order (first match wins). For every rule that counts findings by severity, **exclude findings demoted to Informational by Phase 4.0's deferral match** — they appear in the report under the "Informational — Deferred" sub-heading but do not contribute to verdict computation. (Rejected-deferral entries do *not* demote their corresponding finding; those flow through at their original severity.)

Rules 1 and 2 below read each checklist item's **stored (post-normalization) verdict** — a wording-only FAIL that `scripts/normalize-verdicts.py` normalized to PASS is a stored PASS here and does not drive REJECT, while its raw FAIL survives only in the item's `raw_verdict` audit trail.

1. Any verification checklist item with verdict FAIL → **REJECT**
2. Any verification checklist item with verdict INCONCLUSIVE → **REJECT** (add "manual check needed" note)
3. Any finding from existing review agents at or above `$VERDICT_THRESHOLD` (excluding deferral-demoted ones) → **REJECT** — with one in-scope qualifier: when `$VERDICT_THRESHOLD` admits Important (i.e. is set to `important` or `suggestion`), an admitted finding drives REJECT **unless it is genuinely pre-existing behavior the diff does not touch** (mirroring the `type-design-analyzer` "Do not report on pre-existing types the diff does not touch" carve-out). The self-contradicting-diff carve-out above overrides this qualifier: a finding that contradicts the diff is **always** in-scope and can never be classified pre-existing. At the default `critical`, this qualifier is inert (only Critical findings reach rule 3), so **rule 3 is byte-identical to today** — the self-contradicting-diff carve-out above is the one deliberate default-`critical` change.
4a. If Phase 1+2 were skipped **because checklist generation failed** (`checklist_skipped = "failure"`) → maximum verdict is **APPROVE WITH CAVEAT** — verification checklist not generated (never a clean APPROVE)
4b. If Phase 1+2 were skipped **intentionally by Phase 0.5** (`checklist_skipped = "intentional"`, i.e. small_diff AND config_only) → no caveat; the verdict follows the remaining rules normally. The skip was a deliberate engine-profile choice for a low-risk diff, not a failure.
5. If 2 or more Phase 3 agents failed to return results → add "partial review coverage" note to the verdict
6. Only findings below `$VERDICT_THRESHOLD` present (excluding deferral-demoted ones) → **APPROVE with notes**
7. No findings (excluding deferral-demoted ones) → **APPROVE**

### 4.3 Present the report

Output the full report to the user.

### 4.5 Run telemetry + effectiveness trace

This step is gated by `devflow_review_and_fix.efficiency_telemetry_enabled` (read via `"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/config-get.sh .devflow_review_and_fix.efficiency_telemetry_enabled true`; the flag is shared with `/devflow:review-and-fix`). When `false`, skip this step entirely — no telemetry, no trace, no record. It is **independent** of the live-comment flag: either can be on while the other is off.

When enabled, assemble a **single workpad-shaped object** for this run from state the engine already produced and write it to `.devflow/tmp/review/<slug>/<run-id>/iter-1.json` (run-scoped, the same `<run-id>` Phase 0.2 resolved). The `telemetry` key is mandatory: when no phase figures were established, emit the literal JSON string `"unavailable"`, never a missing key or `null`. This scratch write is what `efficiency-trace.sh --mode trace` reads back; landing in gitignored `.devflow/tmp/` (like Phase 0.2's `diff.patch`), it is **not** a tree write and is permitted under the read-only cloud `review` profile — only the durable `--persist` write to the telemetry branch (issue #441) is gated to writable runs.

**Author it with an allow-listed command** — the read-only cloud `review` profile grants the execution-verified jq wrapper `Bash(.devflow/vendor/devflow/scripts/run-jq.sh:*)` (invoke it as the leading token by path so a shim-shadowed Windows/WSL host resolves a runnable jq; bare `Bash(jq:*)` is also granted but skips that resolution), plus `Bash(printf:*)` and `Bash(tee:*)`. Build the object with `"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/run-jq.sh -n` (or `printf '%s'`, or the `tee <file> <<'EOF'` heredoc Phase 0.3.5 sanctions — never a `cat`-headed heredoc, which the *Cloud command-shape discipline* classifies as denied) and `>`-redirect it, e.g. `"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/run-jq.sh -n --argjson findings '…' '{iter:1, source:"review", …}' > .devflow/tmp/review/<slug>/<run-id>/iter-1.json`. The `>` redirect of a granted head is permitted (the denied redirect class is `/tmp`-targeted and `cat`-heredoc writes, never an in-workspace redirect of a granted head); an ungranted head is silently denied and the trace has no input.

```json
{
  "iter": 1,
  "source": "review",
  "diff_profile": { … the Phase 0.5 flags … },
  "checklist": [ { "verification_mode": "lite|agent", "verdict": "…" }, … ],
  "phase3_dispatched": [ "<agent id>", … ],
  "phase3_findings": [ { "agent": "<id>", "corroboration_count": N, "contributed_to_verdict": true|false }, … ],
  "telemetry": { "phase_0_5": {…}, "phase_1": {…}, "phase_2": {…}, "phase_3": {…} }
}
```

`source: "review"` selects the **review-mode** derivation in `lib/efficiency-trace.jq` (distinguishing the record from `/devflow:review-and-fix`'s). Because standalone review never applies a fix, each Phase-3 finding carries `contributed_to_verdict` instead of `fix_decision`: `true` when it counted toward the verdict (drove the REJECT, or was a non-deferral-demoted Important/Suggestion in an APPROVE-with-notes), `false` when Phase 4.0's deferral match demoted it to Informational. The jq then classifies each agent `unique-effective` / `corroborating` / `noise` / `null` off contribution instead of applied-fix.

Then render the trace and (on a writable run) persist the record, reusing the **same hardened invocation** `/devflow:review-and-fix`'s Loop Exit uses (direct invocation — no `bash` prefix; rc/stderr `::warning::` breadcrumbs; remove-on-rc≠0):

```bash
WORKPAD_DIR=$(printf '%s' ".devflow/tmp/review/<slug>/<run-id>")   # run-scoped: read THIS run's iter-1.json. Capture form: a bare VAR="…" assignment is a probe-denied shape (.github/workflows/matcher-probe.yml); the matcher descends into $(…).
# Trace (renders to chat / the live comment; reads only):
# Three-way, mirroring /devflow:review-and-fix's Loop Exit. `if !` reads the helper's OWN
# exit status — never a captured rc read in a later statement (a cross-statement-variable-
# stripping inline-bash runner would leave it empty): rc≠0 is a failure; rc=0-but-empty
# stdout (e.g. telemetry flag off, or zero readable workpads) is a benign no-trace —
# surface it but append nothing, never a blank trace section:
if ! TELEM="$("${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../lib/efficiency-trace.sh --workpad-dir "$WORKPAD_DIR" --slug "<slug>" --mode trace 2>.devflow/tmp/review/<slug>/<run-id>/rv-et.err)"; then
  echo "::warning::review effectiveness trace unavailable (rc≠0): $(cat .devflow/tmp/review/<slug>/<run-id>/rv-et.err 2>/dev/null)"; TELEM=""
elif [ -z "$TELEM" ]; then
  echo "::warning::review effectiveness trace rendered empty (rc=0, no output — telemetry disabled or no readable workpads); omitting the trace section"
fi

# Record (WRITABLE runs only — never under the read-only cloud profile). --persist
# (issue #441) reads THIS run's iter-1.json (source:"review" → review-mode record),
# hashes it into the object store, advances the TELEMETRY BRANCH ref with a compare-and-
# swap, and pushes — the SAME code path /devflow:review-and-fix's Loop Exit uses. Nothing
# touches the working tree or the current branch. Best-effort/exit-0: an unpushable branch
# (offline, no remote, read-only fork-PR token) still advances the local ref and warns.
# (No `|| true`: --persist is exit-0 by contract, and `true` is an ungranted head here.)
"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../lib/efficiency-trace.sh --persist --workpad-dir "$WORKPAD_DIR" --slug "<slug>"
```

- **PR mode + live comment on:** append the Run telemetry summary (per-phase `calls`/`tokens`/`wall_clock_s`) and the rendered `$TELEM` trace into the live progress comment's finalization (Phase 4 of the update protocol), so the comment is the single complete surface. The comment edit goes through `gh` — permitted under the read-only cloud profile.
- **Writable run (local/IDE) only:** run the `--persist` record block above. **Never run it under the read-only cloud `review` profile** (`contents: read`); the comment is the cloud surface, the durable record is writable-run-only.
- **Telemetry-on with live comment OFF, in a read-only cloud run:** there is no surface (comment disabled, `--persist` gated out). Do **not** silently compute-and-discard: emit a one-line chat note (`::warning::devflow review telemetry enabled but no surface available (live comment disabled, read-only run) — trace not persisted`) so the no-op is visible. A writable run still persists the record, so this note is read-only-cloud-only.

Best-effort throughout: a telemetry/trace failure is a `::warning::`, never a downgrade of the verdict.
<!-- devflow:review-ref phase=4 file=skills/review/phases/phase-4-verdict.md end -->
