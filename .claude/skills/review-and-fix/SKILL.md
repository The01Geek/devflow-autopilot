---
name: review-and-fix
description: Use when you need a comprehensive code review that also automatically fixes findings. Takes an optional PR number as argument.
argument-hint: pr-number
---

# /review-and-fix — Review, Fix, and Verify Loop

You are the review-and-fix orchestrator. Run the four-phase review engine, fix findings, and re-run until the review passes.

**Input:** Optional PR number as `$ARGUMENTS`. If omitted, review and fix current branch.

**Key principle:** You perform fixes DIRECTLY in this session. Do NOT delegate fixes to a subagent. You need full conversation context to apply receiving-code-review principles (technical evaluation, pushback, verification).

---

## Main Loop

Execute this loop with a maximum of 4 iterations:

### Iteration Start

Output: `Review iteration {N}/4...`

### Step 1: Run the Review Engine

Execute the same four-phase review engine as the `/review` skill:

**Phase 0: Setup**
- Check for uncommitted changes (warn if present)
- Determine diff: if `$ARGUMENTS` is a PR number, use `gh pr diff $ARGUMENTS`; otherwise use `git diff origin/main...HEAD`
- If diff commands fail (non-zero exit code), stop immediately and report the error
- Get changed file list from the diff
- If diff is empty, report "No changes to review" and stop
- Discover related GitHub issue: check PR body for `Resolves/Fixes/Closes #N`, then branch name for `issue-{N}` pattern (if reviewing a PR, use the PR's head branch name, not the local branch). If found, fetch issue via `gh issue view` and store the title + first 200 lines of the body as `issue_context`. If not found, note "No related issue found — skipping issue compliance check."

**Phase 1: Verification Checklist Generation**
- Launch `checklist-generator` agent with the diff and file list
- If `issue_context` is available, include it in the prompt and instruct the generator to also produce checklist items verifying the PR implements the key requirements from the issue's summary and desired behavior sections (focus on functional requirements, not stylistic suggestions)
- Parse JSON checklist from the response
- If generation fails, retry once; if still fails, set `checklist_skipped` flag and skip to Phase 3

**Phase 2: Checklist Verification**
- Launch `checklist-verifier` agents in batches of 8 (one per checklist item)
- Collect PASS/FAIL/INCONCLUSIVE verdicts
- Record timed-out agents as INCONCLUSIVE

**Phase 3: Existing Review Agents**
- Launch in parallel: `pr-review-toolkit:code-reviewer`, `pr-review-toolkit:silent-failure-hunter`, `pr-review-toolkit:comment-analyzer`, `pr-review-toolkit:pr-test-analyzer`, `superpowers:code-reviewer`
- Use `gh pr diff $ARGUMENTS` if reviewing a PR by number, or `git diff origin/main...HEAD` if reviewing the current branch — pass the correct diff command to each agent
- Conditionally launch `pr-review-toolkit:type-design-analyzer` if new types are in the diff
- Collect findings with severity labels. Track the count of failed agents.

**Phase 4: Aggregation and Verdict**
- Build the report (same format as `/review`, including the Issue Compliance section noting which issue was checked)
- Determine verdict using the same rules (including: checklist_skipped → max APPROVE WITH CAVEAT; 2+ failed agents → partial review coverage note)

### Step 2: Check Verdict

If verdict is **APPROVE** → break out of the loop. Output the report and: "Review passed. All checks approved."

If verdict is **REJECT** → continue to Step 3.

### Step 3: Fix Findings

Apply the `superpowers:receiving-code-review` principles:

1. **Read all findings** without reacting. Understand the full picture before fixing anything.

2. **Evaluate each finding technically:**
   - For verification checklist FAILs: Read the evidence. Verify it yourself by reading the source file cited. If the evidence is correct, fix the code. If the evidence is wrong (the verifier misread the source), skip the fix and document why.
   - For Critical/Important findings from review agents: Read the finding. Check if it's valid for this codebase. If valid, fix it. If not, skip and document why.
   - For Suggestion/Minor findings: Fix only if trivial and clearly correct. Do not spend time on cosmetic issues.

3. **Fix one issue at a time.** After each fix, verify the surrounding code still makes sense.

4. **Run tests** after all fixes. Check CLAUDE.md, README, or project configuration for the project's test and lint commands. If tests fail, fix the test failures before continuing.

5. **Track pushbacks.** For each finding you skipped, record `(source_file, claim_text)`. If the same pair was also skipped in the previous iteration, escalate to the user: "Finding persists after pushback: {claim}. Manual review needed." and stop the loop.

6. **Commit fixes** before re-running the review:
   ```bash
   git add -A && git commit -m "fix: address review findings (iteration {N})"
   ```
   This ensures the next review iteration sees the updated code in the diff.

### Step 4: Continue Loop

Output: `Fixed {N} issues, skipped {M}. Re-running review...`

Loop back to Step 1 with a fresh review of the updated code.

---

## Loop Exit

### On APPROVE:
Output the final report and: "Review passed after {N} iteration(s). All checks approved."

### On max iterations (4) reached with REJECT:
Output the final report and: "Review still has findings after 4 iterations. Remaining issues require manual review:"
List all unresolved findings.

---

## Error Handling

- **Agent failures**: Treat as INCONCLUSIVE or note in report. Never abort the entire review.
- **Test failures after fixes**: Fix the test failures before re-running the review loop.
- **Commit failures**: If a commit fails (e.g., pre-commit hook), fix the issue and retry the commit.
