---
name: review
description: Use when you need a code-review verdict on a PR or current branch, without auto-applying any fixes.
argument-hint: pr-number
---

# /devflow:review — Comprehensive PR Review

You are the review engine orchestrator. Run a four-phase review and present an APPROVE/REJECT verdict.

**Input:** Optional PR number as `$ARGUMENTS`. If omitted, review current branch vs main.

**Engine sharing.** Phases 0 through 4.3 of this skill are also executed verbatim by `/devflow:review-and-fix` (which wraps them in a fix loop and skips Phase 4.4 entirely — no GitHub post; its final report is emitted to chat only). When modifying engine behavior here — Phase 3 agent prompts, Phase 1 batching, Phase 0.5 classification, Phase 4 verdict criteria — verify `/devflow:review-and-fix` still produces the same findings; that's where divergence has historically slipped in. `/devflow:review-and-fix`'s SKILL.md deliberately keeps no paraphrase of these phases, so changes here propagate automatically as long as the file is reachable at the path `**/devflow/skills/review/SKILL.md`.

## When NOT to use

- Not for PRs you want auto-fixed — use `/devflow:review-and-fix` instead.
- Not for general code Q&A or learning the codebase — this skill is verdict-driven, not exploratory.
- Not for reviewing uncommitted local changes — commit to a branch first (Phase 0.1 will warn either way).
- Not for first-time review of a multi-PR feature branch — review the most-recent PR in isolation; the engine compares against `origin/main` (or the PR base) and a long-lived branch diff will swamp Phase 1 with stale items.

---

## Phase 0: Setup

### 0.1 Check for uncommitted changes

Run:
```bash
git status --porcelain
```

If there is output, warn: "You have uncommitted changes that will not be included in this review."

### 0.2 Determine diff scope and cache the diff

**If `$ARGUMENTS` is a PR number:**
```bash
gh pr diff $ARGUMENTS
gh pr view $ARGUMENTS --json headRefName,baseRefOid,headRefOid --jq '.'
```
If either command fails (non-zero exit code), stop immediately and report: "Failed to retrieve diff. Verify the PR number exists and you have required permissions."

Use the PR diff output for Phase 1. Store the head branch name, `baseRefOid` as `$PR_BASE_SHA`, and `headRefOid` as `$PR_HEAD_SHA` — Phase 1's per-file slicing needs them (see Phase 1.1).

**Caller head-override (fix-loop reuse).** A wrapping skill (currently `/devflow:review-and-fix`) may pass `head_override = local`. When set, take the PR's head from the local working tree instead of the API: set `$PR_HEAD_SHA=$(git rev-parse HEAD)` and fetch the diff with `git diff "$PR_BASE_SHA...HEAD"` instead of `gh pr diff $ARGUMENTS`. This lets a fix loop review commits it has made locally but not yet pushed — the remote `headRefOid` would otherwise lag behind and the loop would re-review pre-fix code. It requires the PR's head branch to be the checked-out branch; the caller guarantees this (review-and-fix does so in its Step 0.5). When `head_override` is absent — standalone `/devflow:review`, the default — use the API head exactly as above; do **not** diff against local `HEAD`, since a standalone review must reflect the pushed PR state, not a dirty or stale local checkout.

**Note on `gh pr diff` path filtering.** `gh pr diff <N>` does NOT support path arguments — `gh pr diff <N> -- <file>` errors with `accepts at most 1 arg(s)` (cli/cli#5398, unresolved). When you need per-file slicing in Phase 1.1, use `git diff "$PR_BASE_SHA...$PR_HEAD_SHA" -- <paths>` instead, or pipe the full `gh pr diff` through `filterdiff -i '<pattern>'` if `patchutils` is installed.

**If no argument (review current branch):**
```bash
git diff origin/main...HEAD
git diff origin/main...HEAD --name-only
```
If either command fails (non-zero exit code), stop immediately and report: "Failed to retrieve diff. Verify origin/main is reachable and you are on a valid branch."

Use the diff output for Phase 1. The current branch is the review target.

If the diff is empty, report: "No changes to review. Branch is identical to main." and stop.

**Cache the diff to disk.** Write the diff fetched above to `.devflow/tmp/review/<slug>/diff.patch` — **fetch once, do not re-run `gh pr diff` / `git diff`**. Compute `<slug>` as:

- **PR mode:** `pr-<N>` where `<N>` is the PR number from `$ARGUMENTS`.
- **Current-branch mode:** the current branch name sanitized for filesystem use — replace `/` with `-`, lowercase, drop any character that isn't `[a-z0-9._-]`. (Matches the workpad slug convention `/devflow:review-and-fix` already uses.)

Combine the initial fetch with the cache write in one shot using `tee` so the diff is captured exactly once and stdout remains available for Phase 1 consumption:

```bash
mkdir -p .devflow/tmp/review/<slug>
gh pr diff $ARGUMENTS | tee .devflow/tmp/review/<slug>/diff.patch
# or, in current-branch mode:
# git diff origin/main...HEAD | tee .devflow/tmp/review/<slug>/diff.patch
# or, in PR mode with head_override=local (fix-loop reuse — see "Caller head-override"):
# git diff "$PR_BASE_SHA...HEAD" | tee .devflow/tmp/review/<slug>/diff.patch
```

This replaces the bare `gh pr diff` / `git diff` invocation at the top of Phase 0.2 — use the `tee` form instead. Store `<slug>` and the resolved diff path (e.g. `.devflow/tmp/review/pr-863/diff.patch`) so Phase 3 can substitute it into its agent prompts via `{DIFF_PATH}`. The directory creation is harmless if it already exists; the file is overwritten on every run.

**`.devflow/tmp/` should be gitignored** (it's ephemeral scratch); the rest of `.devflow/` (`config.json`, `learnings/`, the schema/example) is intentionally tracked. The scaffolder (`scripts/scaffold-config.sh`, run by `install.sh` / `/devflow:init`) writes a scoped `.devflow/.gitignore` that ignores only `tmp/`. This skill does not manage that entry itself (it's a repo-level concern); flag missing coverage in the chat output only if `.devflow/tmp/` is not already ignored. When `/devflow:review` is invoked standalone (not from `/devflow:review-and-fix`), this cached diff is the only file in the directory — independent of the fix-loop's `iter-<N>.json` workpad files that live in the same place.

### 0.3 Get changed file list

From the diff, extract the list of changed files (use `--name-only` output or parse from PR diff). Store this list — it's needed for Phase 1 and Phase 3.

### 0.4 Discover related GitHub issue

Attempt to find the related issue number using these methods in order:

**From PR body** (look for `Resolves #N`, `Fixes #N`, or `Closes #N`):

If a PR number was provided:
```bash
ISSUE_NUM=$(gh pr view $ARGUMENTS --json body --jq '.body' | grep -oiE '(resolves|fixes|closes)[[:space:]]+#[0-9]+' | grep -oE '[0-9]+' | head -1)
```

If no PR number:
```bash
ISSUE_NUM=$(gh pr view HEAD --json body --jq '.body' 2>/dev/null | grep -oiE '(resolves|fixes|closes)[[:space:]]+#[0-9]+' | grep -oE '[0-9]+' | head -1)
```

**From branch name** (fallback — matches `issue-{number}` pattern set by `/devflow:implement`):
```bash
if [ -z "$ISSUE_NUM" ]; then
  # If reviewing a PR, use the stored head branch name from Phase 0.2
  # If reviewing current branch, use git branch --show-current
  BRANCH_NAME="${STORED_HEAD_BRANCH:-$(git branch --show-current)}"
  ISSUE_NUM=$(echo "$BRANCH_NAME" | grep -oE 'issue-[0-9]+' | grep -oE '[0-9]+')
fi
```

If an issue number was found, fetch the issue:
```bash
gh issue view $ISSUE_NUM --json title,body
```

**Truncation rule:** Only use the **first 200 lines** of the issue body. This captures the summary and desired behavior while skipping excessive implementation detail.

Store the issue title and truncated body as `issue_context`. If no issue was found, set `issue_context` to empty and note: "No related issue found — skipping issue compliance check."

### 0.5 Classify the diff and decide the engine profile

Before launching anything, classify the diff. The classification scales agent dispatch so that tiny / config-only PRs don't pay the full engine cost (and so type-design-analyzer is dispatched only when there are *actually* new types, not when "class" happens to appear as a word elsewhere in the diff).

Compute four flags:

- `small_diff` = (total changed lines < 100) **AND** (changed-file count ≤ 3)
- `config_only` = every changed file has an extension in `{.yml, .yaml, .json, .md, .toml, .ini, .lock, .txt}`
- `has_new_types` = the added-lines slice of the diff (lines starting with `+` but not `+++`) contains, in a code file (file extension NOT in the `config_only` set above), a line that matches `^\+\s*(?:(?:final|abstract|readonly|export(?:\s+default)?|public|pub)\s+)*(class|interface|type|enum|struct|trait)\s+\w+`. The optional leading modifiers catch language-specific qualifiers (e.g. `final class`, `abstract class`, `readonly class`, `export class`, `export default class`, `public class`) — without them, the regex would silently miss genuinely-new-type diffs in languages whose declarations begin with a visibility / modality keyword.
- `engine_self_modifying` = any changed file's path matches `skills/**` OR `agents/**` OR `lib/**` (the DevFlow engine's own files, which live at the repo root in the devflow-autopilot repo). These are the SKILL.md / agent-definition / helper-script files that *are* the review engine — a typo here silently breaks every future review. `lib/**` is included because helper scripts and test fixtures under `lib/` are part of the engine surface. (This gate only fires when reviewing a PR against the DevFlow repo itself; on an adopter's repo these paths normally won't match the engine.)

Compute counts from the diff already fetched in 0.2/0.3 — no extra `gh` calls.

Apply the engine profile per the table below. The first row **overrides** all others when its flag is set; otherwise the remaining rows apply per their combinations. Output one line announcing the chosen profile so the human reader knows the engine ran a leaner path on purpose, not by accident:

| Combination | Engine behavior |
|---|---|
| `engine_self_modifying` (any combination of the other flags) | Override the other flags: run the **full engine** (no Phase 1+2 skip, no agent gating in Phase 3.1). The risk surface is "every future review breaks if this is wrong," which dwarfs the per-PR cost saving from a leaner profile. |
| `small_diff` AND `config_only` | Skip Phase 1 + Phase 2 (checklist gen + verify) entirely. Set `checklist_skipped = "intentional"`. In Phase 3.1, skip `pr-test-analyzer` and `pr-review-toolkit:type-design-analyzer`. |
| `config_only` (but not `small_diff`) | Run Phase 1+2 normally. In Phase 3.1, skip `pr-test-analyzer` and `pr-review-toolkit:type-design-analyzer`. |
| `small_diff` (but not `config_only`) | Run Phase 1+2 normally. In Phase 3.1, skip `pr-test-analyzer` if no test files (`*test*`, `*spec*`, language-specific test naming conventions, etc.) appear in the diff. |
| neither flag set | Run the full engine. In Phase 3.1, still apply the `has_new_types` gate for `type-design-analyzer`. |

Concretely: when `engine_self_modifying` is true, the orchestrator does NOT set `checklist_skipped = "intentional"` regardless of `small_diff` / `config_only`, and the Phase 3.1 engine-profile gates listed below are bypassed (every Phase 3 agent in the launch list runs). The override is not an aesthetic tag on the announcement line — it is the load-bearing rule that keeps the full engine wired through Phase 1's skip predicate AND Phase 3.1's per-agent gates for engine-self-modifying diffs.

`has_new_types` is the canonical predicate for the type-design-analyzer gate in Phase 3.1; the previous heuristic ("check for `class ` in the diff") fires false-positives on YAML/markdown comments and is superseded.

Announce one line, e.g.:
- `Diff classification: engine_self_modifying (overrides other flags) → running full engine — this diff modifies the review engine itself.`
- `Diff classification: small_diff + config_only → skipping Phase 1+2 and pr-test-analyzer + type-design-analyzer.`
- `Diff classification: config_only → skipping pr-test-analyzer + type-design-analyzer (Phase 1+2 still run).`
- `Diff classification: full engine.`

---

## Phase 1: Verification Checklist Generation

Output: `Phase 1/4: Generating verification checklist...`

**Skip this entire phase (and Phase 2) when Phase 0.5 set `checklist_skipped = "intentional"`** (small_diff AND config_only). Proceed directly to Phase 3. The verdict rule in 4.2 distinguishes this intentional skip from a checklist-gen failure.

### 1.1 Determine batching

Count the changed files. If 10 or fewer, launch one checklist-generator agent. If more than 10, split into batches of 10 and launch one agent per batch. **Slice the diff to only the batch's files** before passing it. To slice:

- **PR mode (PR number provided):** use `git diff "$PR_BASE_SHA...$PR_HEAD_SHA" -- <file1> <file2> ...`. Do NOT use `gh pr diff $ARGUMENTS -- <file>` — that form errors with `accepts at most 1 arg(s)` (cli/cli#5398, unresolved). Alternatively, pipe the cached full diff through `filterdiff -i '<glob>'` if `patchutils` is installed.
- **Current-branch mode:** use `git diff origin/main...HEAD -- <file1> <file2> ...`.
- **Fallback:** grep the cached full diff by `^diff --git` headers.

Passing the full diff to every batch is wasteful and increases dup rate. Tell each batch which other files are being handled by sibling batches so it does not generate items for them.

Merge the resulting checklists by concatenating all items. If batching ran (>1 batch), proceed to **Phase 1.5: Dedup** before renumbering. If only one batch ran, renumber IDs sequentially (`VC-1`, `VC-2`, ...) and skip Phase 1.5.

**In-batch sanity dedup** still applies before Phase 1.5 hands the array off:
1. **Same-claim dedup**: drop items that make the same claim about the same `source_file`. "Same claim" = same defect/contract under scrutiny, not identical wording (e.g., the same path/format assertion appears in both batches → keep one). When Phase 1.5 runs, this is mostly a no-op — the deduper agent does the heavy lifting via `claim_signature`.
2. **Cross-cutting theme dedup**: cross-cutting checks that apply repo-wide — e.g. license/SPDX header conventions, naming or branding rules, `.gitignore` anchoring — should appear at most once each in the merged list, not once per batch. The category for these is "api_contract" by convention.

### 1.1.5 Cap and prioritize

If the merged-and-deduped checklist has more than **100 items**, sort by priority and keep the top 100:
1. Items whose claim cites an issue acceptance criterion (highest yield — these failing means the PR doesn't deliver the feature).
2. `dependency_interaction` items (cross-boundary contracts — highest drift risk).
3. `test_mock_alignment` items (mocks-vs-real divergence is a classic PR-killer).
4. `api_contract` items.
5. `data_format_assumption` items.

Drop items below the cap. This is a cost cap: every checklist item triggers a verifier subagent in Phase 2. Real-world runs on medium PRs have produced 150+ items when generators are exhaustive on doc-heavy diffs, but the load-bearing signal (cross-boundary contracts, mock-vs-real divergence, issue acceptance) is usually captured well within 100. Announce the cap in chat: `Capped checklist at 100 of {N} items (dropped {M} items by category: dependency_interaction: K1, api_contract: K2, ...; priority kept: issue-acceptance, dependency_interaction, ...).` so the human reader knows which categories took the hit, not just that coverage was truncated. (In `/devflow:review-and-fix` mode the same data also lands in the workpad's `cap_drops` block and the report's `## Coverage` section; in standalone `/devflow:review` runs the chat announcement is the only surface.)

**Record what was dropped.** When the cap fires, summarize the dropped items by category so the orchestrator can surface coverage gaps in the final report (and the fix-loop wrapper can record it in the workpad — see `cap_drops` in `/devflow:review-and-fix`'s workpad schema). Compute and return alongside the truncated checklist:

```json
{
  "count": M,
  "by_category": {
    "dependency_interaction": K1,
    "api_contract": K2,
    "test_mock_alignment": K3,
    "data_format_assumption": K4,
    "...": "..."
  }
}
```

where `M` is the total dropped count (`N - 100`) and the per-category counts sum to `M`. If the cap did not fire, return `{"count": 0, "by_category": {}}`. The orchestrator stores this for the report's `## Coverage` section in `/devflow:review-and-fix` and for the chat announcement in standalone `/devflow:review` runs.

### 1.2 Launch checklist-generator agent(s)

Use the **Agent tool** with `subagent_type: "devflow:checklist-generator"`.

Pass the following prompt:
```
Here is the git diff for this PR:

<diff>
{paste the full diff output here}
</diff>

Changed files to analyze:
{paste the file list here}

Generate the verification checklist. Return the JSON array in a ```json code fence.
```

**If `issue_context` is not empty**, append this to the prompt:

```
The following GitHub issue describes the intended behavior for this PR. In addition to code-correctness items, include checklist items that verify the PR implements the key requirements from the issue's summary and desired behavior sections. Focus on functional requirements — not stylistic suggestions or background context in the issue.

<issue>
Title: {issue_title}
Body (first 200 lines):
{truncated_issue_body}
</issue>
```

**If the caller is `/devflow:review-and-fix` on iteration N≥2** (the fix-loop wrapper supplies `prior_checklist` from `iter-<N-1>.json`), append this to the prompt:

```
This is iteration N (N≥2) of an auto-fix loop. The previous iteration's verification checklist is supplied below. Operate in variance-recovery mode per your agent contract (Step 2b):

- Generate claims NOT already present in the prior checklist (dedup against `claim_signature`).
- Prioritize claim categories that are underrepresented in the prior iteration.
- The goal is variance recovery — surfacing what a second-look pass would catch — NOT re-litigation of items already considered.

Return an empty JSON array `[]` if a second pass surfaces nothing new.

<prior_checklist iteration="N-1">
{paste the iter-(N-1) checklist JSON — id, category, claim, source_file, claim_signature, verdict}
</prior_checklist>
```

### 1.3 Parse the checklist

Extract the JSON array from the agent's response (look for the ```json code fence).

If the agent fails or returns malformed JSON, retry once. If it fails again, log: "Verification checklist generation failed. Proceeding with existing agents only." Set a `checklist_skipped` flag and skip to Phase 3.

Store the parsed checklist items for Phase 1.5 (if batched) or Phase 2 (if single-batch).

Output: `Generated {N} verification checklist items.`

---

## Phase 1.5: Dedup (only when Phase 1 ran in >1 batch)

When Phase 1 ran a single generator batch, skip this phase entirely — there are no cross-batch duplicates to resolve.

When Phase 1 ran in 2+ batches, dedupe via the `devflow:checklist-deduper` agent instead of manually. Manual cross-batch dedup is bias-prone (real-run telemetry: orchestrator collapsing ~70 items to ~40 by hand consistently dropped 3–6 legitimate distinct items per run).

Output: `Phase 1.5/4: Deduping checklist across {B} batches...`

### 1.5.1 Launch the deduper agent

Use the **Agent tool** with `subagent_type: "devflow:checklist-deduper"`.

Concatenate the raw checklist items from all batches into a single JSON array. Preserve each item's original `id` and tag it with its source batch so traceability survives the merge — prefix each `id` with `batch{K}:` (e.g. `batch1:VC-3`, `batch2:VC-1`) before passing to the deduper.

Pass the following prompt:
```
Here is the concatenated raw checklist from {B} generator batches. Merge duplicates per your dedup rules and return the deduped JSON array. Preserve `merged_from` provenance on every surviving item.

<raw_checklist>
{paste the JSON array of all items from all batches, with batch-prefixed ids}
</raw_checklist>
```

### 1.5.2 Parse the deduped checklist

Extract the JSON array from the deduper's response (look for the ```json code fence). The output array uses fresh sequential IDs (`VC-1`, `VC-2`, ...) and records `merged_from` on each item.

If the deduper agent fails or returns malformed JSON, retry once. If it fails again, fall back to manual cross-batch dedup using the **In-batch sanity dedup** rules from Phase 1.1 and continue — do NOT block the engine on dedup failure.

Output: `Deduped to {N_after} of {N_before} items.`

---

## Phase 2: Checklist Verification

Output: `Phase 2/4: Verifying {N} checklist items...`

### 2.0 Partition by verification_mode

Split the checklist into two groups based on each item's `verification_mode` field (set by the generator in Phase 1):

- **Lite items** (`verification_mode: "lite"`) — the orchestrator runs `grep -n` / `rg` directly. No agent dispatch. See 2.1a.
- **Agent items** (`verification_mode: "agent"`, or missing/unrecognized) — dispatch the `devflow:checklist-verifier` agent. See 2.1b.

This partition supersedes the old "one verifier agent per checklist item, no batching exceptions" rule. For pure string-presence claims, an orchestrator-direct `grep -n` is 5–10x cheaper than spawning a verifier subagent and produces an identical verdict. The lite path is bounded to claims that reduce mechanically to substring presence/absence — see `checklist-generator.md` for the eligibility rules the generator applies.

### 2.0.5 Narrow-reuse from iter-(N-1) (fix-loop callers only)

When invoked by `/devflow:review-and-fix` on iteration N≥2, iter-(N-1)'s workpad is available and the caller has supplied (a) the iter-(N-1) checklist and (b) the set of files modified by the iter-(N-1) fix commit (`fix_files`). Before partitioning into lite/agent batches, the orchestrator MAY short-circuit verification for items whose verdicts are mechanically guaranteed to be unchanged.

For each item in the **current iteration's** checklist, reuse the prior verdict (skip verification) iff ALL of the following hold:

1. There exists an item in the iter-(N-1) checklist with the **same `claim_signature`**.
2. That prior item's `verdict` is **`PASS`**.
3. The current item's `source_file` is **NOT in `fix_files`** (the fix commit did not touch it).

For each reused item, copy `verdict`, `evidence`, and `file_checked` from the prior result and tag it `reused_from_iter_<N-1>: true` in the workpad. Everything else — new items the generator emitted in variance-recovery mode, items whose prior verdict was FAIL or INCONCLUSIVE, items whose `source_file` was touched by the fix commit — verifies fresh.

**Why narrow.** The framing the user established: iterations exist for two distinct reasons. *Fix-induced defects* (did the fix introduce new bugs?) are well-served by file-intersection — a PASS item whose file the fix didn't touch is genuinely unchanged. *Variance-recovered defects* (did iter-1 miss something a second look would find?) are the opposite — they're the entire purpose of running Phase 1 again, and a coarse "the fix didn't touch any prior-checklist file, so skip Phase 1+2 wholesale" gate would silently dismiss them. The narrow per-item reuse here optimizes only the first case.

Output: `Reused {K} of {N} checklist verdicts from iter-(N-1) (matching claim_signature, prior verdict PASS, source_file untouched by fix commit). Verifying remaining {N-K} fresh.`

### 2.1a Run lite probes directly

For each `lite` item, execute the probe described in `lite_probe`:

- `kind: "string_present"` — run `grep -nF -- "<string>" <file>` (or `rg -nF "<string>" <file>` if available). If a `line_range` is present, additionally check that at least one hit falls inside `[L1, L2]` (inclusive). Verdict: PASS if any in-range hit (or any hit when no range), FAIL otherwise.
- `kind: "string_absent"` — run the same grep. Verdict: PASS if no hit; FAIL if any hit.

Use fixed-string mode (`-F`) by default — `lite_probe.string` is a literal, not a regex. Escape shell-special characters by quoting.

Edge cases:
- File missing → record INCONCLUSIVE with `evidence: "file not found"`.
- `lite_probe` field missing despite `verification_mode: "lite"` (malformed item) → promote the item to the agent path; do not silently PASS.
- `grep` exit code 2 (real error, not just no-match) → INCONCLUSIVE with the stderr text in `evidence`.

Record the result in the same JSON shape as agent verdicts:
```json
{"id": "VC-N", "verdict": "PASS|FAIL|INCONCLUSIVE", "evidence": "lite probe: 2 hits in lines 113, 117", "file_checked": "path/to/file.py"}
```

**Examples:**
- *Lite-eligible:* `claim`: "License header `<expected literal>` appears in `path/to/new_source_file`". `lite_probe`: `{kind: "string_present", string: "<expected literal>", file: "path/to/new_source_file"}`. The orchestrator greps; no agent needed.
- *Agent-required (NOT lite):* `claim`: "Mock return value of `<symbol>` in `path/to/test_file` matches the real signature in `path/to/impl_file`". Two files, semantic shape comparison — must dispatch the verifier.

### 2.1b Launch verifier agents in batches

Split the *agent* items into batches of up to 8. For each batch, launch all agents in parallel using multiple Agent tool calls in a single message.

Use the **Agent tool** with `subagent_type: "devflow:checklist-verifier"` for each item.

Pass the following prompt for each:
```
Verify this claim against the actual source code. Read the referenced files, compare the claim to reality, and report PASS, FAIL, or INCONCLUSIVE.

Checklist item:
{paste the JSON checklist item here}

The `source_line` field (if present) is best-effort from the generator and may be approximate. Treat it as a starting hint; if the symbol/claim isn't at that line, grep the file for the relevant identifier rather than reporting INCONCLUSIVE. Report INCONCLUSIVE only when the source of truth is genuinely unreachable (file missing, claim too vague to locate, external API not consultable).

When a claim's wording is technically inaccurate but the underlying code is correct (e.g., the claim oversimplifies a branch the code handles correctly), prefer **PASS** with an evidence note explaining the wording-vs-code distinction. Reserve FAIL for cases where the code itself is wrong or contradicts the claim's intent.

Report your verdict as JSON in a ```json code fence: {"id": "VC-N", "verdict": "PASS|FAIL|INCONCLUSIVE", "evidence": "...", "file_checked": "..."}
```

### 2.2 Collect results

Collect verdicts from BOTH paths — lite probes (2.1a) and agent batches (2.1b). Parse the JSON verdict from each agent response.

If an agent times out or fails, record that item as:
```json
{"id": "VC-N", "verdict": "INCONCLUSIVE", "evidence": "Verifier agent failed or timed out.", "file_checked": "N/A"}
```

Store all verification results in a single combined array (lite + agent), keyed by `id`.

Output: `Verified: {pass_count} passed, {fail_count} failed, {inconclusive_count} inconclusive ({lite_count} via lite probe, {agent_count} via agent).`

---

## Phase 3: Existing Review Agents

Output: `Phase 3/4: Running review agents...`

### 3.1 Launch existing review agents in parallel

Launch all agents in a single message using multiple Agent tool calls. For each agent, pass a prompt telling it to review the changes.

**Phase 3 always re-runs on every iteration of the fix loop.** Unlike Phase 1+2 (where individual items can be narrow-reused via `claim_signature` + untouched-file checks — see Phase 2.0.5), Phase 3's review agents are the main lever for *variance recovery*: an LLM reviewer asked the same question twice in different sessions will not always surface the same findings, and that variance is the whole point of iterating. Skipping Phase 3 on a later iteration because "the fix didn't touch any flagged file" silently throws away the second-look signal — exactly the false-pass mode this engine is designed to avoid.

**Prior-findings context (fix-loop callers only).** When invoked by `/devflow:review-and-fix` on iteration N≥2, prepend the following block to every Phase 3 agent's prompt (between the standard task description and the `defect_signature` paragraph). The caller supplies iter-(N-1)'s `phase3_findings` from the workpad:

```
The following findings were raised by a prior review pass on this same code and have already been considered (some fixed, some pushed back as false positives, some deferred). Treat them as PRIOR ART, not as a checklist to re-derive:

- Do NOT re-raise a finding identical to one in the prior set unless you have new evidence the prior decision was wrong.
- DO look for *new* defects the prior pass missed — your value on this iteration is variance recovery, not corroboration.
- If you would have raised an identical finding, you may skip it; the orchestrator already has it.

<prior_findings iteration="N-1">
{paste the iter-(N-1) phase3_findings JSON — agent, severity, description, defect_signature, fix_decision}
</prior_findings>
```

**Diff path:** Substitute the cached diff path computed in Phase 0.2 (`.devflow/tmp/review/<slug>/diff.patch`) into `{DIFF_PATH}` in the prompts below. Phase 3 agents Read this file directly via their `Read` tool — no shell command, no `gh` API call, no redundant re-fetches across the 4–5 parallel agents. The previous `{DIFF_CMD}` substitution (which had every agent re-run `gh pr diff $ARGUMENTS` or `git diff origin/main...HEAD`) is superseded.

**Required `defect_signature` block.** Every Phase-3 finding from every Phase-3 review-agent — both the ones listed below AND any added by future maintainers — MUST carry a `defect_signature` object so corroboration (Phase 3.2) is mechanical, not interpretive. Append this paragraph verbatim to every Phase-3 review-agent prompt — it's the only way to instruct external pr-review-toolkit agents we cannot edit:

```
For every finding you report, include a `defect_signature` field with the following shape:

  defect_signature:
    file: "<path/to/file>"           # required; the primary file the defect lives in
    line_range: [<start>, <end>]     # required when locatable; null only when the defect spans an unbounded region (e.g. "missing test file")
    kind: "<one of: null_deref | unhandled_exception | leak | race | logic_error | api_misuse | type_design | comment_drift | test_gap | security | style | other>"

Place this field on each finding alongside severity and description. If your normal output format is a markdown bullet list, append the signature as a fenced JSON block right under the bullet. Without `defect_signature`, the orchestrator cannot corroborate your finding against other agents and may downweight it.
```

Agents to launch:

**pr-review-toolkit:code-reviewer** — prompt:
```
Review the code changes in this PR. Read the cached diff at `{DIFF_PATH}`. Read CLAUDE.md for project conventions. Focus on CLAUDE.md compliance, bugs, and code quality. Only report issues with confidence >= 80.

{paste the defect_signature paragraph above}
```

**pr-review-toolkit:silent-failure-hunter** — prompt:
```
Review the error handling in the code changes. Read the cached diff at `{DIFF_PATH}`. Read the full changed files. Check for silent failures, inadequate error handling, and inappropriate fallback behavior.

{paste the defect_signature paragraph above}
```

**pr-review-toolkit:comment-analyzer** — prompt:
```
Analyze the code comments in the changes. Read the cached diff at `{DIFF_PATH}`. Check that docstrings and comments are accurate, helpful, and not misleading.

{paste the defect_signature paragraph above}
```

**pr-review-toolkit:pr-test-analyzer** — prompt:
```
Analyze test coverage for the changes. Read the cached diff at `{DIFF_PATH}`. Check if tests adequately cover new functionality and edge cases.

{paste the defect_signature paragraph above}
```

**pr-review-toolkit:type-design-analyzer** — *launched only when the `has_new_types` gate is true (see Phase 3.1 gates below), and always when `engine_self_modifying` is set; skipped otherwise* — prompt:
```
Analyze the type design in the code changes. Read the cached diff at `{DIFF_PATH}`. Evaluate the types actually introduced or modified in this diff for encapsulation, invariant expression, usefulness, and enforcement. Do not report on pre-existing types the diff does not touch.

{paste the defect_signature paragraph above}
```

**General-purpose final-pass reviewer** — dispatch a `Task` with `subagent_type: general-purpose` and instruct it to invoke the `/superpowers:requesting-code-review` skill (that skill renders its own reviewer prompt; we do not inline it). This dispatch assumes the `superpowers` plugin is installed in the executing environment; if `/superpowers:requesting-code-review` is not available, the subagent will surface that and the orchestrator should fall back to relying on the other Phase-3 reviewer agents above.

Prompt:

```
Invoke the `/superpowers:requesting-code-review` skill to perform a final-pass code review. Pass the following context into the skill:

- Description: {one-line summary — "PR #<N>: <title>" or "Current branch <name> vs main"}
- Plan / Requirements: {the PR body if available, else the originating issue body from Phase 0.4, else "No spec available — review against general project standards from CLAUDE.md"}
- Base SHA: {PR_BASE_SHA or origin/main HEAD}
- Head SHA: {PR_HEAD_SHA or current HEAD}
- Diff path: `{DIFF_PATH}` (the full diff, cached to disk by Phase 0.2 — Read it directly rather than re-fetching)
- Prior-iteration findings (already considered, look for new): {iter-(N-1) phase3_findings JSON if fix-loop iteration N≥2, else "none"}

Return your findings in the standard Phase-3 output format: ### Strengths / ### Issues (grouped by Critical / Important / Suggestion) / ### Recommendations / ### Assessment. Every issue MUST carry a `defect_signature` block per the contract below.

{paste the defect_signature paragraph above}
```

**Phase 0.5 engine-profile gates (apply to this launch list):**

These gates are **BYPASSED entirely** when `engine_self_modifying` is set in Phase 0.5 — every Phase 3 agent in the launch list runs regardless of `config_only` / `small_diff` / `has_new_types` for engine-self-modifying diffs (see Phase 0.5's override row). Apply the gates below only when `engine_self_modifying` is false.

- Skip `pr-review-toolkit:pr-test-analyzer` when `config_only` is set, OR when `small_diff` is set AND no test files appear in the diff.
- Skip `pr-review-toolkit:type-design-analyzer` when `has_new_types` is false. (This replaces the older "check for `class ` in the diff" predicate, which over-fired on the literal word *class* appearing in YAML / markdown / comments.)

In all other cases, `pr-review-toolkit:type-design-analyzer` is launched when `has_new_types` is true.

### 3.2 Collect results

Collect all agent responses. Extract findings, their severity labels (Critical, Important/Major, Suggestion/Minor), and their `defect_signature` blocks.

For each finding, compute a **corroboration count** — the number of Phase 3 agents that raised the same defect. Corroboration is now **mechanical**, not interpretive:

> Two findings corroborate iff they have the **same `defect_signature.file`**, **overlapping `defect_signature.line_range`** (treat `null` as overlapping any range in the same file when `kind` matches), AND **identical `defect_signature.kind`**.

A finding without a `defect_signature` block falls back to a one-line text-based agreement heuristic (same described file + same described defect kind in prose), but **flag it in the report** so the human knows the agent skipped the signature contract. Agents that systematically omit `defect_signature` should be re-prompted with the contract reminder.

Corroboration count is a stronger calibrator than the individual agent's verbalized confidence: a finding raised by 3 of 5 agents is much more likely to be a true positive than a 95%-confidence finding raised by only one. Single-source findings are not automatically wrong — they're flagged so a human reader can apply extra scrutiny.

If an agent fails, note: "[agent-name] did not return results." in the report. Track the count of failed agents. Failed agents do not reduce the denominator for the corroboration count of findings other agents raised.

---

## Phase 4: Aggregation and Verdict

Output: `Phase 4/4: Aggregating findings...`

### 4.0 Match deferrals from PR body (PR mode only)

**Skip this step entirely in current-branch mode** (no PR → no body to read). On standalone branch reviews, there is no Scope-Acknowledged Findings block; jump straight to 4.1.

When `$ARGUMENTS` is a PR number, the engine consults the **Scope-Acknowledged Findings** block in the PR body (delimited by `<!-- DEVFLOW_DEFERRED_FINDINGS_START -->` / `<!-- DEVFLOW_DEFERRED_FINDINGS_END -->`) and demotes any current finding that matches a validated deferral entry to **Informational**. This is the consumer side of the contract /devflow:implement Phase 4.0.5 produces; without it, /devflow:review re-raises findings that /devflow:implement already filed follow-up issues for, creating the policy mismatch the contract is meant to prevent. (See `${CLAUDE_SKILL_DIR}/../../scripts/match-deferrals.py` for the matcher's exact guard order and matching rule.)

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
printf '%s' "$FINDINGS_JSON" | ${CLAUDE_SKILL_DIR}/../../scripts/match-deferrals.py \
    --pr $ARGUMENTS \
    --diff ".devflow/tmp/review/<slug>/diff.patch" \
    --findings -
```

Capture the matcher's stdout (the JSON report described below). When invoked from /devflow:implement Phase 3.3 via /devflow:review-and-fix (which DOES have the Write tool), the file form `--findings .devflow/tmp/review/<slug>/findings.json` is equally supported — pick whichever the surrounding profile permits.

The matcher always exits 0 when it ran (any result, including no block found). Read the output JSON:

- `block_present: false` → PR has no Scope-Acknowledged Findings block; proceed to 4.1 with all findings intact.
- `pr_author_trusted: false` → PR author is not in `devflow.allowed_bots`; **every** deferral is rejected with reason `untrusted-filer`. All findings flow through unchanged. Include the rejection list in 4.1's `## Deferrals` section so the human reader sees the contract was claimed but not honorable.
- For each entry in `honored[]`: the finding at `findings[finding_index]` is **demoted to Informational** for the rest of Phase 4. Record the `deferral_id` + `follow_up_issue` so the 4.1 line annotation can cite them.
- For each entry in `rejected_deferrals[]`: the deferral did not apply (issue closed, missing cross-link, widens-surface re-check failed, or no matching current finding). The corresponding current finding (if any) is **not** demoted — flag it explicitly in 4.1's `## Deferrals` section with the reason.

If the matcher itself errors out (exit code 2), log the failure (`Deferral matcher failed: {stderr}; proceeding without demotions.`) and continue to 4.1 with all findings intact. Never block the review on a matcher failure — the safe default is to surface findings, not hide them.

**Caching note.** The matcher hits the GitHub API once for the PR body + author and once per `follow_up.issue` for the cross-link guard. For a PR with N deferrals, this is N+1 API calls. Tolerable; if it ever becomes a bottleneck, batch the issue reads via `gh api graphql`.

### 4.1 Build the report

**GitHub autolink hygiene** (this report is posted as a PR comment/review): never put a bare `#` immediately before a number unless it is a real issue or PR reference — GitHub renders `#2` as a link to issue/PR 2, which misleads readers. For an ordinal, count, or list position, spell it out ("item 2", "step 3"), never `#2`. Genuine references like `#123` stay as-is.

Construct the report in this format:

```markdown
# Review Report

## Verdict: {APPROVE | APPROVE with notes | APPROVE WITH CAVEAT | APPROVE WITH ADVISORY NOTES | REJECT} ({summary})

## Issue Compliance
{If issue found: "Reviewed against issue #{number}: {title}. Requirement-based checklist items are included in the verification results below."}
{If no issue found: "No related issue found — requirement compliance not checked."}

## Verification Checklist Results
- ({total} checked, {pass} passed, {fail} failed, {inconclusive} inconclusive)
{for each FAIL or INCONCLUSIVE item: "- VC-N: VERDICT — claim [source_file:source_line]"}
{when {pass} > 0, emit the PASS items inside a collapsed block — `{pass}` MUST equal the number of `- VC-N` lines listed inside it. Leave a blank line before `<details>` so GitHub renders the collapsible correctly after the preceding list:}

<details><summary>{pass} passed checks</summary>

{for each PASS item: "- VC-N: PASS — claim [source_file:source_line]"}

</details>
{when {pass} == 0, omit the `<details>` block entirely — never emit an empty collapsible.}

FAIL and INCONCLUSIVE items stay listed outside the `<details>` block so they remain visible. The block renders collapsibly on GitHub; in a chat-only `/devflow:review-and-fix` run it renders as inline HTML, which stays readable.

## Code Review Findings
{for each finding, prefix the line with its severity icon — 🔴 Critical, 🟠 Important/Major, 🟡 Suggestion/Minor, ℹ️ Informational — Deferred: "- {icon} [agent-name] severity: description (raised by N/{total Phase 3 agents that returned results} agents)"}
{for findings whose index appears in the matcher's honored[] list, append " [Deferred → #{follow_up_issue}]" to the line, render it with the ℹ️ icon, and place it under a separate sub-heading "### Informational — Deferred" rather than under its original severity bucket.}
{group Critical findings first, then Important/Major, then Suggestion/Minor, then Informational — Deferred. Within each severity, list corroborated findings (N≥2) before single-source ones (N=1) so the highest-confidence items lead.}

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
- Any Critical finding from review agents → REJECT (excluding findings demoted to Informational via Phase 4.0's deferral match)
- Checklist generation failed → max APPROVE WITH CAVEAT
- 2+ review agents failed → partial review coverage
- Only Important/Suggestion findings → APPROVE with notes
- No findings → APPROVE
```

### 4.2 Determine verdict

Apply these rules in order (first match wins). For every rule that counts findings by severity, **exclude findings demoted to Informational by Phase 4.0's deferral match** — they appear in the report under the "Informational — Deferred" sub-heading but do not contribute to verdict computation. (Rejected-deferral entries do *not* demote their corresponding finding; those flow through at their original severity.)

1. Any verification checklist item with verdict FAIL → **REJECT**
2. Any verification checklist item with verdict INCONCLUSIVE → **REJECT** (add "manual check needed" note)
3. Any Critical finding from existing review agents (excluding deferral-demoted ones) → **REJECT**
4a. If Phase 1+2 were skipped **because checklist generation failed** (`checklist_skipped = "failure"`) → maximum verdict is **APPROVE WITH CAVEAT** — verification checklist not generated (never a clean APPROVE)
4b. If Phase 1+2 were skipped **intentionally by Phase 0.5** (`checklist_skipped = "intentional"`, i.e. small_diff AND config_only) → no caveat; the verdict follows the remaining rules normally. The skip was a deliberate engine-profile choice for a low-risk diff, not a failure.
5. If 2 or more Phase 3 agents failed to return results → add "partial review coverage" note to the verdict
6. Only Important or Suggestion findings (excluding deferral-demoted ones) → **APPROVE with notes**
7. No findings (excluding deferral-demoted ones) → **APPROVE**

### 4.3 Present the report

Output the full report to the user.

### 4.4 Record the verdict as a formal GitHub review (PR mode only)

**If — and only if — `$ARGUMENTS` is a PR number** (you are reviewing an actual PR, not the current branch), you MUST also submit the verdict as a formal GitHub Pull Request review so it becomes a visible merge signal. A REJECT verdict that lives only in a comment or in chat output is routinely missed — the PR gets marked ready and merged with the rejection still outstanding. A `--request-changes` review blocks the merge button (or, at minimum, forces an explicit dismissal), which is the behavior we want.

Map the verdict to a `gh pr review` action. **What goes in `--body` depends on whether a separate progress comment already carries the full report** — set `$BODY` accordingly:

- **Workflow context** (`$GITHUB_ACTIONS` == `true` — the auto-trigger workflow or the `@claude` listener): a progress comment posts the full Phase 4.1 report verbatim, so the review body is a short verdict-only **stub**; putting the full report in both places forces reviewers to scroll past two copies. Set `$BODY` to `$STUB`:

  ```
  ## Verdict: {VERDICT} — full report in PR comment

  > The complete review report (checklist results, findings, details) is in the
  > Devflow Review progress comment on this PR.
  ```

- **Standalone context** (`$GITHUB_ACTIONS` unset or not `true` — run directly from an IDE/CLI): there is **no** progress comment, so a stub would point at a comment that does not exist and the full report would live only in chat. Set `$BODY` to the full `$REPORT` from Phase 4.1 so the review itself carries it — one self-contained artifact, no dangling pointer. (The full report begins with `# Review Report`, which `dismiss-stale-rejections.sh` matches alongside the stub's `## Verdict: REJECT` prefix, so a standalone REJECT is still cleared by a later APPROVE.)

where `{VERDICT}` is the actual verdict line (e.g. `APPROVE`, `APPROVE with notes`, `APPROVE WITH CAVEAT`, `REJECT`) — reflect what Phase 4.2 decided, do not template-fill literally. The `## Verdict: REJECT` text is load-bearing: `finalize_check` greps for it on the `gh pr comment` fallback path. It appears as the stub's first line AND as a `## Verdict: {VERDICT}` line inside the full `$REPORT`, so the grep matches in either context.

| Verdict | Command |
|---|---|
| **REJECT** (any form) | `gh pr review $ARGUMENTS --request-changes --body "$BODY"` |
| **APPROVE WITH CAVEAT** / **APPROVE with notes** | `gh pr review $ARGUMENTS --comment --body "$BODY"` |
| **APPROVE** (clean, no findings) | `gh pr review $ARGUMENTS --approve --body "$BODY"` |

If `gh pr review` fails (e.g. you cannot review your own PR as the same GitHub identity, or the token lacks permission), fall back to `gh pr comment $ARGUMENTS --body "$REPORT"` — use the full `$REPORT` here (not `$STUB`), since this fallback comment is the only artifact in that path. Note in your chat output that the formal review could not be posted. **Never silently skip this step on a REJECT** — the whole point is that the rejection must be impossible to miss.

**Then, on any APPROVE form only (APPROVE / APPROVE with notes / APPROVE WITH CAVEAT), clear a stale REJECT.** A prior REJECT's `--request-changes` review stays the PR's effective `reviewDecision` until *dismissed*; the APPROVE-with-notes `--comment` review never supersedes it, and the REJECT may be a different bot identity (auto path posts as `github-actions[bot]`, manual `@claude` as another), so no later review clears it either. Without this the PR is wedged at `reviewDecision: CHANGES_REQUESTED` forever, contradicting the green check and this APPROVE. The script dismisses **only Devflow Review's own reports** (body marker), never a human reviewer's `--request-changes`. On REJECT, **skip this** — the changes-request must stand. Run (re-run safe):

```bash
${CLAUDE_SKILL_DIR}/../../scripts/dismiss-stale-rejections.sh "$ARGUMENTS"
```

If it exits non-zero (token scope), say so in chat output and that the PR stays blocked until dismissed manually. **A dismissal failure never downgrades the verdict** — the verdict stands; only merge-gate housekeeping failed.

---

## Common Mistakes

- Re-running Phase 1 on a config-only PR when Phase 0.5 classified it as `small_diff + config_only` — Phase 0.5 already gates this; trust the classification rather than second-guessing it.
- Letting checklist generation failure silently degrade to a clean APPROVE — Phase 4.2 rule 4a forces APPROVE WITH CAVEAT in that case; do not skip past it because "the rest of the engine ran fine."
- Treating an agent's verbalized confidence as load-bearing — Phase 3.2's corroboration count (mechanical, signature-based) is the stronger signal. A 95%-confident single-source finding is weaker than a 3-of-5 corroborated one.
- Dispatching `pr-review-toolkit:type-design-analyzer` on a diff where `has_new_types` is false — the gate exists because that analyzer over-fires when the word *class* appears in YAML, markdown, or comments. Honor the gate.
- Posting a REJECT verdict only to chat without `gh pr review --request-changes` — Phase 4.4 exists because chat-only rejections get missed and the PR ships anyway.
- Posting an APPROVE without dismissing a prior REJECT's `CHANGES_REQUESTED` review (Phase 4.4 final step) — "the required check is green so it'll merge" is the trap: a sticky changes-request keeps `reviewDecision: CHANGES_REQUESTED` and wedges the PR despite the green check and APPROVE verdict.
- Paraphrasing Phase 0.5 in a way that loses the `engine_self_modifying` override — the first row of the table overrides all others; the full engine must run on engine-self-modifying diffs because typos in SKILL.md or agent files silently break every future review.
- Skipping `/devflow:review-and-fix`'s Step 2.5 web-verification gate for single-source Critical findings — auto-applied fixes from confidently-stated-but-wrong external-tool claims are a known false-positive vector. (This skill itself doesn't run Step 2.5; flag it as a mistake when reviewing changes to `/devflow:review-and-fix`.)
