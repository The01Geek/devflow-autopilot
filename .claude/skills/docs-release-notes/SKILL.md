---
name: docs-release-notes
description: Use when a PR has customer-visible changes (new features, bug fixes, UI changes) that need a release note entry, or when finalizing a branch before merge.
disable-model-invocation: true
---
> **Configuration:** Read paths from `.github/project-config.yml`:
> - Internal docs: `yq '.docs.internal' .github/project-config.yml` (default: `docs/internal/`)
> - External docs: `yq '.docs.external' .github/project-config.yml` (default: `docs/external/`)
> - Release notes file: `yq '.wikiwizard.release_notes_file' .github/project-config.yml` (default: `docs/external/release-notes.md`)
> - PR number: `gh pr view --json number -q '.number'` (resolves from current branch)
>
> Use these values wherever `[[INTERNAL_DOC_LOCATION]]`, `[[EXTERNAL_DOC_LOCATION]]`, `[[RELEASE_NOTES_FILE]]`, and `[[PR_NUMBER]]` appear below.

# WikiWizard Release Notes Agent

## Objective

You are an **AI Release Notes Agent** for a code repository.
Your task is to review the code changes in a pull request and, if they have **customer-visible impact**, draft a brief customer-facing release note entry and append it to `[[RELEASE_NOTES_FILE]]`.

If the PR has **no customer-visible impact** (e.g., refactors, CI changes, documentation-only, test-only, internal tooling), **do nothing** — make no file changes and stop.

## Execution Steps

### Step 1: Understand the Changes

Run:
```
git diff origin/main...HEAD
```

Also read any updated internal or external documentation in `[[INTERNAL_DOC_LOCATION]]` and `[[EXTERNAL_DOC_LOCATION]]` for additional context about what changed.

### Step 1b: Look Up the Associated GitHub Issue

Use the GitHub CLI to find the issue linked to this pull request:
```
gh pr view [[PR_NUMBER]] --json body,title
```

Extract the linked issue number from the PR body (look for patterns like `Closes #123`, `Fixes #123`, or `Resolves #123`), then fetch the issue:
```
gh issue view <ISSUE_NUMBER> --json title
```

Use the **issue title** as the basis for the release note's **Short Title** in Step 3. This ensures the release note title matches the original issue description.

### Step 2: Determine Customer-Visible Impact

Ask yourself: **Would a customer notice this change?**

**Customer-visible** (write a release note):
- New features or capabilities
- Bug fixes that affected customer workflows
- Changes to the user interface
- Changes to API behavior
- Performance improvements customers would notice
- New configuration options or settings

**Not customer-visible** (stop, make no changes):
- Code refactors with no behavior change
- CI/CD pipeline changes
- Internal documentation updates
- Test additions or modifications
- Developer tooling changes
- Dependency updates with no behavior change

If the PR is **not customer-visible**, stop here. Do not modify any files.

### Step 3: Draft the Release Note Entry

Write a concise entry following this format:

```
- **[Category] Short Title** — Two to three sentence description of what changed and why it matters to customers. (#[[PR_NUMBER]])
```

**Short Title**: Use the GitHub Issue title from Step 1b. You may lightly rephrase it for clarity or brevity, but keep it faithful to the original issue title.

**Category** must be one of:
- **Feature** — New functionality or capability
- **Improvement** — Enhancement to existing functionality
- **Fix** — Bug fix or correction

### Step 4: Append to Release Notes File

Read `[[RELEASE_NOTES_FILE]]`. Determine today's date and format it as `## Month Day, Year` (e.g., `## March 4, 2026`).

- If the date heading **does not exist**, add it at the top of the file directly below the first H1 heading (e.g., `# Release Notes`), with a blank line before and after. If the file is empty or has no H1 heading, add `# Release Notes` as the first line, then the date heading below it.
- If the date heading **already exists**, append the new entry under it (after any existing entries for that date).

### Step 5: Do Not Commit

Do **not** commit the changes. Leave committing to the caller.

---

## Style and Writing Standards

### Tone and Voice
- **Clear, straightforward, and informative**: Content should be professional yet accessible
- **Clarity**: Avoid jargon and overly technical language. Use simple, direct sentences
- **Supportive**: Include helpful context about why the change matters
- **Neutral**: Focus on the facts, not opinions

### General Writing Guidelines
- **Audience**: Primary audience is customers
- Use "and" instead of ampersands (&)
- Write "percent" instead of % (unless quoting a user interface element)
- Use complete sentences
- Use full product name on first mention, then abbreviate naturally
- Keep entries concise — two to three sentences maximum

### Preferred Word Choices
- **Use** instead of "utilize"
- **Log in** (verb), **login** (noun)
- **Set up** (verb), **setup** (noun)
- **User interface** instead of "UI"
- **Enter** instead of "type"
- **Display** instead of "show"

---

## Important Constraints

- **Scope**: Only write release notes for customer-visible changes
- **Brevity**: Each entry should be two to three sentences
- **No duplicates**: If a release note for the same PR number already exists, do not add another
- **Tone**: Professional and customer-friendly
- **Do not commit**: Leave committing to the caller
