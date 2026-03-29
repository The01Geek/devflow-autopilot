---
name: review
description: Use when you need a comprehensive code review of a PR or the current branch with a structured APPROVE/REJECT verdict. Does not fix issues. Takes an optional PR number as argument.
argument-hint: pr-number
---

# /review — Comprehensive PR Review

You are the review engine orchestrator. Run a four-phase review and present an APPROVE/REJECT verdict.

**Input:** Optional PR number as `$ARGUMENTS`. If omitted, review current branch vs main.

---

## Phase 0: Setup

### 0.1 Check for uncommitted changes

Run:
```bash
git status --porcelain
```

If there is output, warn: "You have uncommitted changes that will not be included in this review."

### 0.2 Determine diff scope

**If `$ARGUMENTS` is a PR number:**
```bash
gh pr diff $ARGUMENTS
gh pr view $ARGUMENTS --json headRefName --jq '.headRefName'
```
If either command fails (non-zero exit code), stop immediately and report: "Failed to retrieve diff. Verify the PR number exists and you have required permissions."

Use the PR diff output for Phase 1. Store the head branch name.

**If no argument (review current branch):**
```bash
git diff origin/main...HEAD
git diff origin/main...HEAD --name-only
```
If either command fails (non-zero exit code), stop immediately and report: "Failed to retrieve diff. Verify origin/main is reachable and you are on a valid branch."

Use the diff output for Phase 1. The current branch is the review target.

If the diff is empty, report: "No changes to review. Branch is identical to main." and stop.

### 0.3 Get changed file list

From the diff, extract the list of changed files (use `--name-only` output or parse from PR diff). Store this list — it's needed for Phase 1 and Phase 3.

### 0.4 Discover related GitHub issue

Attempt to find the related issue number using these methods in order:

**From PR body** (look for `Resolves #N`, `Fixes #N`, or `Closes #N`):

If a PR number was provided:
```bash
ISSUE_NUM=$(gh pr view $ARGUMENTS --json body --jq '.body' | grep -oiP '(?:resolves|fixes|closes)\s+#\K\d+' | head -1)
```

If no PR number:
```bash
ISSUE_NUM=$(gh pr view HEAD --json body --jq '.body' 2>/dev/null | grep -oiP '(?:resolves|fixes|closes)\s+#\K\d+' | head -1)
```

**From branch name** (fallback — matches `issue-{number}` pattern set by `/implement`):
```bash
if [ -z "$ISSUE_NUM" ]; then
  # If reviewing a PR, use the stored head branch name from Phase 0.2
  # If reviewing current branch, use git branch --show-current
  BRANCH_NAME="${STORED_HEAD_BRANCH:-$(git branch --show-current)}"
  ISSUE_NUM=$(echo "$BRANCH_NAME" | grep -oP 'issue-\K\d+')
fi
```

If an issue number was found, fetch the issue:
```bash
gh issue view $ISSUE_NUM --json title,body
```

**Truncation rule:** Only use the **first 200 lines** of the issue body. This captures the summary and desired behavior while skipping excessive implementation detail.

Store the issue title and truncated body as `issue_context`. If no issue was found, set `issue_context` to empty and note: "No related issue found — skipping issue compliance check."

---

## Phase 1: Verification Checklist Generation

Output: `Phase 1/4: Generating verification checklist...`

### 1.1 Determine batching

Count the changed files. If 10 or fewer, launch one checklist-generator agent. If more than 10, split into batches of 10 and launch one agent per batch. Merge the resulting checklists by concatenating all items and renumbering IDs sequentially (VC-1, VC-2, ...). Deduplicate items that make the same claim about the same file.

### 1.2 Launch checklist-generator agent(s)

Use the **Agent tool** with `subagent_type: "checklist-generator"`.

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

### 1.3 Parse the checklist

Extract the JSON array from the agent's response (look for the ```json code fence).

If the agent fails or returns malformed JSON, retry once. If it fails again, log: "Verification checklist generation failed. Proceeding with existing agents only." Set a `checklist_skipped` flag and skip to Phase 3.

Store the parsed checklist items for Phase 2.

Output: `Generated {N} verification checklist items.`

---

## Phase 2: Checklist Verification

Output: `Phase 2/4: Verifying {N} checklist items...`

### 2.1 Launch verifier agents in batches

Split checklist items into batches of up to 8. For each batch, launch all agents in parallel using multiple Agent tool calls in a single message.

Use the **Agent tool** with `subagent_type: "checklist-verifier"` for each item.

Pass the following prompt for each:
```
Verify this claim against the actual source code. Read the referenced files, compare the claim to reality, and report PASS, FAIL, or INCONCLUSIVE.

Checklist item:
{paste the JSON checklist item here}

Report your verdict as JSON in a ```json code fence: {"id": "VC-N", "verdict": "PASS|FAIL|INCONCLUSIVE", "evidence": "...", "file_checked": "..."}
```

### 2.2 Collect results

For each batch, collect the agent responses. Parse the JSON verdict from each response.

If an agent times out or fails, record that item as:
```json
{"id": "VC-N", "verdict": "INCONCLUSIVE", "evidence": "Verifier agent failed or timed out.", "file_checked": "N/A"}
```

Store all verification results.

Output: `Verified: {pass_count} passed, {fail_count} failed, {inconclusive_count} inconclusive.`

---

## Phase 3: Existing Review Agents

Output: `Phase 3/4: Running review agents...`

### 3.1 Launch existing review agents in parallel

Launch all agents in a single message using multiple Agent tool calls. For each agent, pass a prompt telling it to review the changes.

**Diff command:** Use `gh pr diff $ARGUMENTS` if reviewing a PR by number, or `git diff origin/main...HEAD` if reviewing the current branch. Substitute the correct command into `{DIFF_CMD}` in the prompts below.

Agents to launch:

**pr-review-toolkit:code-reviewer** — prompt:
```
Review the code changes in this PR. Run `{DIFF_CMD}` to see the diff. Read CLAUDE.md for project conventions. Focus on CLAUDE.md compliance, bugs, and code quality. Only report issues with confidence >= 80.
```

**pr-review-toolkit:silent-failure-hunter** — prompt:
```
Review the error handling in the code changes. Run `{DIFF_CMD}` to see the diff. Read the full changed files. Check for silent failures, inadequate error handling, and inappropriate fallback behavior.
```

**pr-review-toolkit:comment-analyzer** — prompt:
```
Analyze the code comments in the changes. Run `{DIFF_CMD}` to see the diff. Check that docstrings and comments are accurate, helpful, and not misleading.
```

**pr-review-toolkit:pr-test-analyzer** — prompt:
```
Analyze test coverage for the changes. Run `{DIFF_CMD}` to see the diff. Check if tests adequately cover new functionality and edge cases.
```

**superpowers:code-reviewer** — prompt:
```
Review all changes in this PR/branch vs main. Run `{DIFF_CMD}` to see the diff. This is a final-pass code review against project standards.
```

Conditionally launch **pr-review-toolkit:type-design-analyzer** only if the changed files include new class/type definitions (check for `class ` in the diff).

### 3.2 Collect results

Collect all agent responses. Extract findings and their severity labels (Critical, Important/Major, Suggestion/Minor).

If an agent fails, note: "[agent-name] did not return results." in the report. Track the count of failed agents.

---

## Phase 4: Aggregation and Verdict

Output: `Phase 4/4: Aggregating findings...`

### 4.1 Build the report

Construct the report in this format:

```markdown
# Review Report

## Verdict: {APPROVE|REJECT} ({summary})

## Issue Compliance
{If issue found: "Reviewed against issue #{number}: {title}. Requirement-based checklist items are included in the verification results below."}
{If no issue found: "No related issue found — requirement compliance not checked."}

## Verification Checklist Results
{for each item: "- VC-N: VERDICT — claim [source_file:source_line]"}
- ({total} checked, {pass} passed, {fail} failed, {inconclusive} inconclusive)

## Code Review Findings
{for each agent that returned results: "- [agent-name] severity: description"}

## Verdict Criteria
- Any FAIL in verification checklist → REJECT
- Any INCONCLUSIVE in verification checklist → REJECT (manual check needed)
- Any Critical finding from review agents → REJECT
- Checklist generation failed → max APPROVE WITH CAVEAT
- 2+ review agents failed → partial review coverage
- Only Important/Suggestion findings → APPROVE with notes
- No findings → APPROVE
```

### 4.2 Determine verdict

Apply these rules in order (first match wins):
1. Any verification checklist item with verdict FAIL → **REJECT**
2. Any verification checklist item with verdict INCONCLUSIVE → **REJECT** (add "manual check needed" note)
3. Any Critical finding from existing review agents → **REJECT**
4. If Phase 1+2 were skipped (checklist generation failed) → maximum verdict is **APPROVE WITH CAVEAT** — verification checklist not generated (never a clean APPROVE)
5. If 2 or more Phase 3 agents failed to return results → add "partial review coverage" note to the verdict
6. Only Important or Suggestion findings → **APPROVE with notes**
7. No findings → **APPROVE**

### 4.3 Present the report

Output the full report to the user.
