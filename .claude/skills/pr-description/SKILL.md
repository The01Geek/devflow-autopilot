---
name: pr-description
description: Use when generating or updating a PR description for the current branch. Takes an optional issue number as argument.
argument-hint: <issue-number>
---

# /pr-description — Generate or Update PR Description

Generate a structured PR description by analyzing the current branch's changes against the base branch. When an existing PR is found, merges new content with human-added content instead of replacing it.

**Input:** `$ARGUMENTS` is an optional GitHub issue number. If provided, include a "Resolves #N" link.

## Step 1: Gather Context

Run these commands to understand what changed:

```bash
git fetch origin main
git log origin/main...HEAD --oneline
```

```bash
git diff origin/main...HEAD --stat
```

Read the diff details for any files that need deeper understanding:

```bash
git diff origin/main...HEAD
```

If an issue number was provided, fetch the issue for context:

```bash
gh issue view $ARGUMENTS --json title,body,labels
```

**Check for an existing PR on the current branch:**

```bash
gh pr view HEAD --json number,body,title 2>/dev/null
```

If this succeeds, an existing PR was found. Save the PR number and body for Step 2.

## Step 2: Generate the PR Description

### Mode A: No existing PR (or empty body)

Generate a fresh description using the template below.

### Mode B: Existing PR with content

Fetch the existing body and apply these merge rules:

**Re-generate from the diff** (always overwrite — these reflect current state):
- Summary
- Changes
- Visual Changes
- Breaking Changes

**Merge** (keep existing items that are still relevant, add new ones, remove stale ones):
- Test Plan — preserve human-added checklist items; add items for new changes; remove items for changes that no longer exist

**Merge** (combine existing and new):
- Resolves — if `$ARGUMENTS` provides an issue number, include it; also keep any existing issue references that differ from `$ARGUMENTS`

**Preserve as-is:**
- Any non-template sections found between the markers (e.g., "## Reviewer Notes", "## Deploy Steps") — carry them forward in the same position
- Any content that appears BEFORE `<!-- PR_BODY_START -->` or AFTER `<!-- PR_BODY_END -->` in the existing body — output it in the same position relative to the markers

**If the existing body has NO markers:** Treat the entire existing body as pre-marker content. Output it above `<!-- PR_BODY_START -->`, then generate the full template below the marker.

### Template

Output the description as plain text (not inside a code block) so it appears directly in your response:

<!-- PR_BODY_START -->
## Summary
- [1-3 concise bullet points describing what changed and why]

## Changes
[Group changes by module or concern. Use bold for the area name, colon, then a brief description.]

**[Area name]**: [What changed]
**[Area name]**: [What changed]

## Resolves
#[issue number, or omit this section if no issue number was provided]

## Test Plan
- [ ] [Concrete verification step]
- [ ] [Concrete verification step]

## Visual Changes
[Describe UI changes, or "N/A" if none]

## Breaking Changes
[Describe breaking changes and migration steps, or "None"]

Generated with [Claude Code](https://claude.com/claude-code)
<!-- PR_BODY_END -->

**Rules:**
- Be concise. No filler words.
- Summary bullets should explain *what* and *why*, not list files.
- Changes section groups by logical area (e.g., "Orders module", "Frontend", "Database"), not individual files.
- Test Plan items must be concrete and actionable, not generic ("Run tests").
- The entire output between the markers must be valid GitHub-flavored Markdown.
- Do NOT wrap the output in a code block. Output the markers and content as plain text so they appear directly in your response.
- When updating an existing PR, do NOT discard human-added content. If in doubt about whether something was human-added, preserve it.

## Step 3: Apply the Description

- **If an existing PR was found (Mode B):** Update it directly:
  ```bash
  gh pr edit $PR_NUMBER --body "$(cat <<'EOF'
  [full output including any pre/post-marker content]
  EOF
  )"
  ```
- **If no existing PR (Mode A):** Output the description as plain text for the caller to use when creating the PR.
