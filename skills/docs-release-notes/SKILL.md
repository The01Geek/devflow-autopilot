---
name: docs-release-notes
description: Use when a PR has customer-visible changes (new features, bug fixes, UI changes) that need a release note entry, or when finalizing a branch before merge.
---
> **Configuration:** Read paths from `.devflow/config.json`:
> - Internal docs: `${CLAUDE_SKILL_DIR}/../../scripts/config-get.sh .docs.internal docs/internal/`
> - External docs: `${CLAUDE_SKILL_DIR}/../../scripts/config-get.sh .docs.external docs/external/`
> - Release notes file: `${CLAUDE_SKILL_DIR}/../../scripts/config-get.sh .docs.release_notes_file docs/external/release-notes.md`
> - CHANGELOG file: `${CLAUDE_SKILL_DIR}/../../scripts/config-get.sh .docs.changelog_file CHANGELOG.md`
> - PR number: `gh pr view --json number -q '.number'` (resolves from current branch)
>
> The `config-get.sh` helper falls back to the default value when the config file is missing or the key is absent.
>
> Use these values wherever `[[INTERNAL_DOC_LOCATION]]`, `[[EXTERNAL_DOC_LOCATION]]`, `[[RELEASE_NOTES_FILE]]`, `[[CHANGELOG_FILE]]`, and `[[PR_NUMBER]]` appear below.

**Consumer prompt extension (load first).** Before doing this skill's work, load any consumer-supplied prompt extension for this skill and honor it. From the repo root, run:

```bash
${CLAUDE_SKILL_DIR}/../../scripts/load-prompt-extension.sh docs-release-notes
```

If the helper exits non-zero, a consumer extension exists but could not be loaded — surface its stderr message and do not silently proceed as if none existed. If it exits 0 and prints text, treat that text as additional instructions appended to the end of this skill's own prompt for this run — it is upgrade-safe, consumer-owned customization committed under `.devflow/prompt-extensions/`. If it exits 0 and prints nothing, proceed unchanged.

# Release Notes Agent

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

If the PR is **not customer-visible**, skip Steps 3, 3b, and 4 — do not write a release note or modify `[[RELEASE_NOTES_FILE]]`. Proceed directly to Step 4b.

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

### Step 3b: Verify Every Factual Claim in the Draft Against the Code

⚠️ **MANDATORY — do not skip. Write the release note from the diff you read in Step 1, never from the issue body, the PR description, the implementation plan, or your memory of what the change "should" do.**

Issue bodies, PR descriptions, and plans describe *intent*; they routinely state gating conditions, permission keys, file names, menu visibility, and behaviors that the shipped diff turns out to contradict (a permission check that was removed, a menu that now renders unconditionally, a feature flag that was deleted, a second file that was also removed but went unmentioned). A release note copied from that prose inherits every one of those errors and ships them to customers. Before appending, re-open the actual changed source from the Step-1 diff and confirm each concrete assertion in the entry you drafted:

- **Gating / visibility / permission claims** ("shows only for users with the X permission", "available to admins", "behind feature flag Y") — open the file that renders or guards the feature *in the post-change diff* and confirm the condition still exists and is spelled exactly as written. If the diff *removed* the guard, the release note must not claim it.
- **Names and identifiers** (permission keys, feature-flag names, route paths, file names, setting keys, menu labels) — `grep` the changed code and confirm the identifier exists exactly as written and lives where the note implies. Use the key the code actually checks (e.g. `reports/comparison-report`), not a shortened guess (`report`).
- **Scope of the change** — if the diff removed or added more than one user-visible thing (e.g. two files removed, two settings deleted), the release note must account for each one, or you must consciously decide one is not customer-visible and say so in the Step-3 reasoning. A release note covering only the first of two shipped removals is a half-edit.
- **Described behavior** — confirm the "what changed and why it matters" sentence matches the post-change implementation, not a draft of it.

If any drafted assertion cannot be confirmed against the changed code, rewrite the entry until it can — never ship a customer-facing claim on faith. If verification reveals the change is *not* actually customer-visible after all, stop and make no file changes (per Step 2).

### Step 4: Append to Release Notes File

Read `[[RELEASE_NOTES_FILE]]`. Determine today's date and format it as `## Month Day, Year` (e.g., `## March 4, 2026`).

- If the date heading **does not exist**, add it at the top of the file directly below the first H1 heading (e.g., `# Release Notes`), with a blank line before and after. If the file is empty or has no H1 heading, add `# Release Notes` as the first line, then the date heading below it.
- If the date heading **already exists**, append the new entry under it (after any existing entries for that date).

### Step 4b: Reconcile the CHANGELOG Entry

This step runs regardless of the Step 2 customer-visibility decision — after appending a release note (Step 4) or after the non-customer-visible stop in Step 2, proceed here.

**Locate the version-bump entry.** Run:
```
git log --oneline origin/main...HEAD
```
Find the most recent commit whose message begins with `chore: bump version` and extract its version string (e.g., `2.8.19`). Read `[[CHANGELOG_FILE]]` and search for the section heading `## [2.8.19]` (replacing the version with the one extracted above). If no version-bump entry is found in CHANGELOG, this step is a no-op — log "no version-bump entry found" and proceed to Step 5.

**Enumerate every factual claim.** Re-read the body of the located `## [version]` section. A factual claim is any concrete assertion: coverage counts, enumerated sites, completeness phrases ("all X were done", "Y and Z are now..."), named identifiers (file paths, key names, step or phase numbers, agent names), or specific behavioral guarantees. This CHANGELOG entry was written at Phase 3 commit time — before Phase 3.3 review-and-fix corrections — so its specific assertions may be stale relative to the final shipped diff.

**Trace each claim against the Step-1 diff.** For each enumerated claim, confirm it against the diff already read in Step 1. Do not re-run `git diff`. A claim is accurate if every concrete detail (count, identifier, behavioral guarantee) matches the shipped code exactly. A claim is stale if the diff shows a different count, a renamed identifier, a reverted piece of scope, or a corrected approach.

**Correct stale claims in place.** Rewrite only the specific sentence or clause that is stale, using the same tense, format, and surrounding context as the rest of the entry. If all claims are accurate, make no changes to `[[CHANGELOG_FILE]]`. Do not commit — leaving committing to the caller, consistent with Step 5.

### Step 5: Do Not Commit

Do **not** commit any files modified above. Leave committing to the caller.

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
