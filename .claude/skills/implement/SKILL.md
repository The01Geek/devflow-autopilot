---
name: implement
description: Use when a comment or message contains /implement followed by a GitHub issue number. Runs the full 4-phase lifecycle — setup, implementation, code review, and documentation.
argument-hint: <issue-number>
---
# /implement — Automated Feature Development Orchestrator

You are the main implementation agent. Execute the full 4-phase lifecycle for a GitHub issue. You hold continuous context from discovery through documentation — most work happens directly in your session.

**Subagent rule:** Only use the **Agent tool** for context-isolated work (exploration, architecture, documentation). Everything else — planning, implementation, testing, fixing — you do directly.

**Skill rule:** Use the **Skill tool** for `review-and-fix` during code review and `pr-description` for PR documentation.

**Input:** GitHub issue number provided as `$ARGUMENTS`

## MANDATORY: All Four Phases Must Execute

```
Phase 1: Setup → Phase 2: Implement → Phase 3: Review → Phase 4: Documentation
```

**Every phase is mandatory regardless of issue complexity or size.** A one-line fix still needs review (Phase 3) and a proper PR description (Phase 4). Committing code is the HALFWAY point, not the finish line.

Output the phase header at the start of each phase so progress is trackable.

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

### 1.2 Create or Detect Feature Branch

Check if you're already on a feature branch (the GitHub Action creates one automatically):
```bash
git branch --show-current
```

If the current branch matches `claude/issue-*` or `issue-*`, use it — skip branch creation.

Otherwise, create a new branch. Slugify the issue title: lowercase, replace spaces/special characters with hyphens, truncate to 50 characters.

```bash
git fetch origin main
git checkout -b issue-{number}-{slugified-title} origin/main
```

If the branch name already exists, append today's date as YYYYMMDD.

### 1.3 Push Branch

```bash
git push -u origin HEAD
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

**⚠ You are NOT done. Code is committed but not reviewed or documented. Proceed to Phase 3.**

---

## Phase 3: Review & Fix

Output: `Phase 3/4: Review & Fix — creating PR and running review...`

### 3.1 Create Draft PR

```bash
gh pr create --draft --title "{issue title}" --body "$(cat <<'EOF'
Work in progress — automated review pending.

Resolves #{issue_number}

Generated with [Claude Code](https://claude.com/claude-code) via `/implement $ARGUMENTS`
EOF
)"
```

### 3.2 Review & Fix

Invoke the **Skill tool** with `skill: review-and-fix`.

This runs the four-phase review engine in your context:
1. **Verification checklist** — generates and verifies every dependency interaction, test-mock alignment, data format assumption, and API contract claim against actual source code
2. **Existing review agents** — runs pr-review-toolkit (code-reviewer, silent-failure-hunter, comment-analyzer, pr-test-analyzer) and superpowers code-reviewer in parallel
3. **Automatic fix loop** — fixes findings using receiving-code-review principles, re-runs the engine, loops until APPROVE or max 4 iterations

Follow the skill's instructions. It handles evaluation, fixing, testing, and re-review internally.

After the skill completes (verdict: APPROVE), commit any fixes and push:
```bash
git add *
git commit -m "fix: address code review feedback for issue #$ARGUMENTS"
git push
```

If the skill exits with unresolved findings after 4 iterations, report the remaining issues to the user and stop.

### 3.3 Mark PR as Ready

```bash
gh pr ready
```

**⚠ You are NOT done. PR needs documentation and a proper description. Proceed to Phase 4.**

---

## Phase 4: Documentation

Output: `Phase 4/4: Documentation — updating docs and finalizing PR...`

### 4.1 Update Documentation

Spawn a **subagent** (using the Agent tool) and instruct it to invoke the `/docs` skill. Pass it:
- The GitHub issue title, body, and number
- Instruction: "Run /docs to update all documentation (internal docs, external docs, release notes). The issue context is provided for release notes generation."

After the subagent completes, commit any documentation changes. Read the docs paths from `.github/project-config.yml`:

```bash
DOCS_INTERNAL=$(yq '.docs.internal' .github/project-config.yml)
DOCS_EXTERNAL=$(yq '.docs.external' .github/project-config.yml)
git status -- "$DOCS_INTERNAL" "$DOCS_EXTERNAL"
```

If there are changes:
```bash
git add "$DOCS_INTERNAL" "$DOCS_EXTERNAL"
git commit -m "docs: update documentation for issue #$ARGUMENTS"
git push
```

### 4.2 Generate PR Description

Invoke the **Skill tool** with `skill: "pr-description"` and `args: "$ARGUMENTS"` (the issue number).

This outputs the PR description between `<!-- PR_BODY_START -->` and `<!-- PR_BODY_END -->` markers. When running inside a GitHub Action, the bash step extracts this from the output to use as the PR body. When running locally, you can also use the output to update an existing PR:

```bash
gh pr edit --body "$(cat <<'EOF'
[paste the generated description here]
EOF
)"
```

### 4.3 Report Completion

Output the PR URL and a brief summary of what was accomplished.

---

## Completion Checklist

Before reporting completion, verify ALL phases executed:
- Phase 1: Issue fetched, branch exists
- Phase 2: Code committed and pushed
- Phase 3: PR created, review ran, PR marked ready
- Phase 4: Docs updated, PR description generated via `/pr-description`

If any phase was skipped, go back and complete it now.

---

## Error Handling

- **Empty steps**: If any phase produces no file changes, skip the commit and continue. Do not create empty commits.
- **Git conflicts**: If a push fails due to conflicts, run `git pull --rebase origin {branch}` and retry once. If it fails again, stop and report the error.
- **Subagent failures**: If a subagent fails or produces no useful output, note the failure and continue to the next step. Do not retry the same subagent more than once.
- **Permission denials**: If a Bash command is denied, note it and continue to the next step. Never skip an entire phase because of a single denied command.
- **Commit prefixes**: Use `docs:` for documentation, `feat:` for implementation, `fix:` for review fixes and test fixes.
- **Context recovery**: If context was compressed and you lose track of variables, recover from `git log`, `git branch --show-current`, and `gh pr list --head {branch}`.
