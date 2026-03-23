---
name: implement
description: Automated feature development orchestrator. Executes a full lifecycle for a GitHub issue — discovery, planning, implementation, code review, and documentation. Takes an issue number as argument.
argument-hint: <issue-number>
disable-model-invocation: true
---
# /implement — Automated Feature Development Orchestrator

You are the main implementation agent. Your job is to execute a full feature development lifecycle for a GitHub issue. You hold continuous context from discovery through implementation through review fixes — most work happens directly in your session.

**Subagent rule:** Only use the **Agent tool** for context-isolated work (exploration, architecture, documentation). Everything else — planning, implementation, testing, fixing — you do directly.

**Skill rule:** Use the **Skill tool** for `pr-review-toolkit:review-pr` during code review. This runs in your context, which is correct — you need the review findings to fix issues.

**Input:** GitHub issue number provided as `$ARGUMENTS`

---

## Phase 1: Setup

Output: `Phase 1/4: Setup — fetching issue and creating branch...`

### 1.1 Fetch the GitHub Issue

Run:
```bash
gh issue view $ARGUMENTS --json title,body,labels,number
```

If this fails, stop immediately and report: "Error: Could not fetch GitHub issue #$ARGUMENTS. Verify the issue number exists."

Save the issue title, body, labels, and number — you will use these throughout the workflow.

### 1.2 Create Feature Branch

Slugify the issue title: lowercase, replace spaces/special characters with hyphens, truncate to 50 characters.

Branch name: `issue-{number}-{slugified-title}`

```bash
git fetch origin main
git checkout -b issue-{number}-{slugified-title} origin/main
```

If the branch name already exists, append today's date as YYYYMMDD:
```bash
git checkout -b issue-{number}-{slugified-title}-YYYYMMDD origin/main
```

### 1.3 Push Branch

```bash
git push -u origin {branch-name}
```

---

## Phase 2: Discover, Plan & Implement

Output: `Phase 2/4: Discover, Plan & Implement...`

### 2.1 Discovery

Use the **Agent tool** with `subagent_type: feature-dev:code-explorer` to explore the codebase and understand the system as it relates to the issue.

Pass the following prompt:
- The GitHub issue title, body, and labels
- **Explicit instruction:** "Start by reading the internal documentation path from `.github/project-config.yml` (using `yq '.docs.internal' .github/project-config.yml`) and then read relevant files under that path to understand the system architecture and identify which modules and files are relevant to this issue. Use the documentation as a map to guide your code exploration. Then explore the actual code guided by those findings. Return a distilled summary of: relevant files, current behavior, patterns used, dependencies, and anything the implementer needs to know."

After the explorer returns its findings, review them for any mentions of outdated, incomplete, or missing documentation. Read the internal docs path from `.github/project-config.yml`. If the explorer identified gaps, update the docs yourself — create or edit the relevant files in that path based on the explorer's findings and what you now understand about the system.

If you made any documentation changes:
```bash
DOC_PATH=$(yq '.docs.internal' .github/project-config.yml)
git add "$DOC_PATH"
git commit -m "docs: update internal documentation for issue #$ARGUMENTS"
git push
```

### 2.2 Assess Complexity & Plan

Using the explorer's findings, evaluate the issue complexity:

**Simple issues** (implement directly — skip architect):
- Single-module changes (e.g., add a field, fix a bug, update a config)
- Clear solution described in the issue body
- No architectural decisions needed
- Touches ≤ 5 files

**Complex issues** (use architect subagent):
- Cross-module changes affecting multiple subsystems
- New features requiring design decisions
- Changes to interfaces, data models, or system architecture
- Ambiguous requirements needing breakdown into tasks

#### Path A: Simple issue

Output: `Skipping architect — issue is straightforward. Implementing directly.`

Plan the implementation inline using the explorer's findings. Identify which files to create/modify and what changes to make.

#### Path B: Complex issue

Use the **Agent tool** with `subagent_type: feature-dev:code-architect` to design the implementation.

Pass it:
- The full GitHub issue content (title, body, labels)
- The explorer's distilled findings as inline context, prefixed with: "The code-explorer analyzed the current codebase and produced the following findings:"

The architect returns a focused blueprint (files to create/modify, component designs, data flows, build sequence). Hold this blueprint in your context — do NOT commit it (it is a temporary working artifact).

### 2.3 Implement

Now implement the feature yourself. You have full context:
- The explorer's system understanding
- The architect's blueprint (if complex) or your own inline plan (if simple)
- The original issue requirements

Write the code. Follow the patterns and conventions described in `CLAUDE.md`.

### 2.4 Test

Run the project's test command and lint command in parallel (check CLAUDE.md or README for the correct commands):

- Run the project's test command (check CLAUDE.md or README)
- Run the project's lint command (check CLAUDE.md or README)

- If **both pass** → proceed to committing.
- If **either fails** → fix the failing tests/lint errors yourself (you wrote the code, you have full context). Re-run the failing command(s) to verify.

### 2.5 Commit Implementation

Stage and commit all implementation changes:

```bash
git add *
git commit -m "feat: implement issue #$ARGUMENTS — {short description from issue title}"
git push
```

If the commit includes test fixes, use a single commit combining implementation and fixes.

---

## Phase 3: Review & Fix

Output: `Phase 3/4: Review & Fix...`

### 3.1 Create Draft PR

```bash
gh pr create --draft --title "{issue title}" --body "$(cat <<'EOF'
Work in progress — automated review pending.

Resolves #{issue_number}

Generated with [Claude Code](https://claude.com/claude-code) via `/implement $ARGUMENTS`
EOF
)"
```

### 3.2 Code Review

Invoke the **Skill tool** with `skill: pr-review-toolkit:review-pr`.

This runs the PR review in your context. Follow the skill's instructions to complete the review.

### 3.3 Evaluate & Fix

Classify each issue from the review using these severity definitions:

- **Critical**: Security vulnerabilities, data loss risks, broken functionality, missing error handling for external inputs
- **Major**: Logic errors, incorrect API contracts, missing validation, broken patterns from CLAUDE.md, deviations from issue requirements
- **Simplification** (fix, but do NOT re-review for these alone): DRY violations, unnecessary complexity, code that could be cleaner
- **Minor** (do NOT fix or re-review): Style preferences, naming suggestions, cosmetic changes

**Decision logic:**
- **No issues or minor only** → proceed to Phase 4.
- **Simplification + minor only** → fix simplifications, commit, proceed to Phase 4 (no re-review).
- **Major or critical** → fix the issues, commit, push, then re-review (invoke `pr-review-toolkit:review-pr` again). Maximum 2 total review iterations.

After fixing, commit and push:
```bash
git add *
git commit -m "fix: address code review feedback for issue #$ARGUMENTS"
git push
```

### 3.4 Mark PR as Ready

```bash
gh pr ready
```

---

## Phase 4: Documentation

Output: `Phase 4/4: Documentation — updating docs and finalizing PR...`

### 4.1 Update Documentation

Use the **Agent tool** with `subagent_type: wikiwizard-combined` to update all documentation in a single session.

Pass it:
- The GitHub issue title, body, and number
- Instruction: "Run all three documentation steps sequentially (internal docs, external docs, release notes). The issue context is provided for release notes generation."

After the agent completes, commit any documentation changes. Read the docs path from `.github/project-config.yml`:

```bash
DOC_PATH=$(yq '.docs.path' .github/project-config.yml)
git status -- "$DOC_PATH"
```

If there are changes:
```bash
git add "$DOC_PATH"
git commit -m "docs: update documentation for issue #$ARGUMENTS"
git push
```

### 4.2 Update PR Description

Review the full branch diff to build the final PR description:
```bash
git log origin/main..HEAD --oneline
```

Update the PR with a proper description:
```bash
gh pr edit --title "{issue title}" --body "$(cat <<'EOF'
## Summary

{2-3 bullet points summarizing the changes}

Resolves #{issue_number}

## Completion Checklist

- [x] Codebase explored and understood
- [x] Feature implemented
- [x] Tests passing
- [x] Code reviewed and feedback addressed
- [x] Documentation updated

Generated with [Claude Code](https://claude.com/claude-code) via `/implement $ARGUMENTS`
EOF
)"
```

### 4.3 Report Completion

Output the PR URL and a brief summary of what was accomplished.

---

## Error Handling

- **Empty steps**: If any phase produces no file changes, skip the commit and continue. Do not create empty commits.
- **Git conflicts**: If a push fails due to conflicts, run `git pull --rebase origin {branch}` and retry once. If it fails again, stop and report the error.
- **Subagent failures**: If a subagent fails or produces no useful output, note the failure and continue to the next step. Do not retry the same subagent more than once.
- **Commit prefixes**: Use `docs:` for documentation, `feat:` for implementation, `fix:` for review fixes and test fixes.
- **Context recovery**: If context was compressed and you lose track of variables, recover from `git log`, `git branch --show-current`, and `gh pr list --head {branch}`.
