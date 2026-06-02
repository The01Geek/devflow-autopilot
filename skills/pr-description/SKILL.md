---
name: pr-description
description: Use when generating or updating a PR description for the current branch. Takes an optional issue number as argument.
argument-hint: <issue-number>
---

# /pr-description — Generate or Update PR Description

Generate a structured PR description by analyzing the current branch's changes against the base branch. When an existing PR is found, merges new content with human-added content instead of replacing it.

**Input:** `$ARGUMENTS` is an optional GitHub issue number. If provided, include a "Resolves #N" link.

**Consumer prompt extension (load first).** Before doing this skill's work, load any consumer-supplied prompt extension for this skill and honor it. From the repo root, run:

```bash
${CLAUDE_SKILL_DIR}/../../scripts/load-prompt-extension.sh pr-description
```

If the helper exits non-zero, a consumer extension exists but could not be loaded — surface its stderr message and do not silently proceed as if none existed. If it exits 0 and prints text, treat that text as additional instructions appended to the end of this skill's own prompt for this run — it is upgrade-safe, consumer-owned customization committed under `.devflow/prompt-extensions/`. If it exits 0 and prints nothing, proceed unchanged.

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

**Best-effort: pull post-merge acceptance criteria from the /devflow:implement workpad.** When `/devflow:implement` parses a related issue's Acceptance Criteria (its Phase 1.4), it tags items that can only be verified after merge with a trailing `(post-merge)` marker on the checkbox line. Surface those items in the PR body so the merger sees them and can tick them off after deploy.

If an issue number is available (from `$ARGUMENTS` or extracted from the existing PR body via `(?i)(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#(\d+)` — mirroring GitHub's own case-insensitive closes-keyword detection), look up the workpad and read its body:

```bash
ISSUE_NUMBER=$ARGUMENTS  # or the extracted number
WORKPAD_ID=$(${CLAUDE_SKILL_DIR}/../../scripts/workpad.py id "$ISSUE_NUMBER" 2>/dev/null || true)
if [ -n "$WORKPAD_ID" ]; then
    WORKPAD_BODY=$(${CLAUDE_SKILL_DIR}/../../scripts/workpad.py body "$WORKPAD_ID" 2>/dev/null || true)
fi
```

If `WORKPAD_BODY` is set, scan its `## Acceptance Criteria` section for lines matching `^[-*]\s+\[[ x]\]\s+.*\(post-merge\)\s*$`. Strip the leading checkbox and the trailing `(post-merge)` tag from each match; collect them as `POST_MERGE_ITEMS` for Step 2's template.

If no workpad exists, no issue number is available, or no `(post-merge)`-tagged items are found, `POST_MERGE_ITEMS` stays empty and the template's Post-Merge Verification section is omitted entirely. The lookup is best-effort — never fail the run on a missing workpad.

**Best-effort: pull deferred review findings from the manifest.** /devflow:review-and-fix now writes each run's manifest **run-scoped** (`.devflow/tmp/review/<slug>/<run-id>/deferrals.json`), and /devflow:implement Phase 4.0.5 merges every run-scoped manifest into one **slug-level aggregate** at `.devflow/tmp/review/pr-<N>/deferrals.json`, then files follow-up issues and updates that aggregate in place with `id` and `follow_up` fields per entry. Read the slug-level aggregate (the single hydrated path Phase 4.0.5 produces) and surface its entries in the PR body as a Scope-Acknowledged Findings block so /devflow:review (run later as a formal merge signal) can match them and demote the corresponding findings to Informational. (Only entries with a populated `follow_up.issue` render — and only Phase 4.0.5 populates that, so the aggregate is the authoritative source; the run-scoped per-run files are raw, un-hydrated inputs to the merge.)

```bash
PR_NUMBER=$(gh pr view --json number --jq '.number' 2>/dev/null || true)
if [ -n "$PR_NUMBER" ]; then
    DEFERRALS_FILE=".devflow/tmp/review/pr-${PR_NUMBER}/deferrals.json"   # slug-level aggregate written by /devflow:implement Phase 4.0.5
    if [ -s "$DEFERRALS_FILE" ]; then
        DEFERRALS_BODY=$(cat "$DEFERRALS_FILE")
    fi
fi
```

If `DEFERRALS_BODY` is set and the parsed JSON has at least one entry under `deferrals[]` with a populated `follow_up.issue`, render the Deferred Findings section in Step 2's template — a human-readable Markdown table (one row per deferral) for readers, plus the exact machine payload (the same `schema_version: 1` / `deferrals[]` YAML shape) inside the hidden `DEVFLOW_DEFERRED_PAYLOAD` HTML comment that `scripts/match-deferrals.py` parses. Entries lacking a `follow_up.issue` are stale half-written manifests — skip them silently. Otherwise omit the section entirely. The lookup is best-effort — never fail the run on a missing or unparseable manifest.

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
- Post-Merge Verification (when `POST_MERGE_ITEMS` is non-empty — re-derived from the workpad on every run so the list stays in sync with the latest /devflow:implement parse)
- Deferred Findings (when `DEFERRALS_BODY` is non-empty and contains entries with `follow_up.issue` — re-derived from the manifest on every run so the block stays in sync with the latest /devflow:implement Phase 4.0.5 filing)

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
Resolves #[issue number, or omit this section if no issue number was provided]

## Test Plan
- [ ] [Concrete verification step]
- [ ] [Concrete verification step]

## Post-Merge Verification
[Omit this entire section when POST_MERGE_ITEMS is empty. When non-empty, render as:]
The following items can only be verified after this PR is merged or deployed. Tick each after performing the check.
- [ ] [Post-merge AC text, with the trailing (post-merge) tag stripped]
- [ ] [...]

## Deferred Findings
[Omit this entire section when DEFERRALS_BODY is empty or contains no entries with a populated follow_up.issue. When non-empty, render with the markers — the /devflow:review verdict matcher parses them exactly. The visible content is a human-readable Markdown table; the exact machine payload lives in a hidden HTML comment (`DEVFLOW_DEFERRED_PAYLOAD`) so it does not appear in the rendered PR body. One table row per deferral; one payload entry per deferral, in the same order:]

<!-- DEVFLOW_DEFERRED_FINDINGS_START -->
These review-agent findings were deferred under the Scope-Acknowledged Findings contract. /devflow:review honors matching entries as Informational; closing a linked follow-up issue invalidates the deferral and forces re-verification.

| Severity | File | Finding | Follow-up |
| --- | --- | --- | --- |
| <severity> | `<path>:<start>-<end>` | <one-line summary> | #<N> |

<!-- DEVFLOW_DEFERRED_PAYLOAD
schema_version: 1
deferrals:
  - id: <dfr-...>
    finding:
      agent: <agent>
      severity: <Critical | Important | Suggestion>
      file: <path>
      line_range: [<start>, <end>]
      symbol: <symbol or empty>
      kind: <kind>
      summary: |
        <verbatim summary>
    reason:
      category: <out-of-scope | already-tracked | claim-quality>
      explanation: |
        <verbatim explanation>
    follow_up:
      issue: <N>
      url: <url>
      filed_at: <ISO 8601 UTC>
      filed_by: <login>
-->
<!-- DEVFLOW_DEFERRED_FINDINGS_END -->

## Visual Changes
[Describe UI changes, or "N/A" if none]

## Breaking Changes
[Describe breaking changes and migration steps, or "None"]

<!-- PR_BODY_END -->

**Rules:**
- Be concise. No filler words.
- Summary bullets should explain *what* and *why*, not list files.
- Changes section groups by logical area (e.g., "Orders module", "Frontend", "Database"), not individual files.
- Test Plan items must be concrete and actionable, not generic ("Run tests").
- The entire output between the markers must be valid GitHub-flavored Markdown.
- **GitHub autolink hygiene** (the PR body is posted to GitHub): never put a bare `#` immediately before a number unless it is a real issue or PR reference — GitHub renders `#2` as a link to issue/PR 2, which misleads readers. For an ordinal, count, or list position, spell it out ("item 2", "step 3"), never `#2`. Genuine references like `#123` stay as-is.
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
