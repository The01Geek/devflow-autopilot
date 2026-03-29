---
name: create-issue
description: Use when you have a rough user story, bug report, or feature idea that needs to become a well-structured GitHub issue.
argument-hint: <user-story>
---
## Prerequisites

If `$ARGUMENTS` is empty, ask the user to describe their user story, bug report, or feature idea before proceeding.

## Steps

### Step 1: Document current state
Invoke the `/docs-verify` skill with the topic extracted from the user story (e.g., `/docs-verify survey module`).

This will verify and update documentation in `docs/internal/` for the relevant features.

After the skill completes, commit and push the documentation changes.

### Step 2: Clarify user story

Evaluate whether the user story needs clarification based on the doc findings and the story itself.

**General principle:** Identify gaps, ambiguities, or risks that would produce a weak or incorrect GitHub issue. If the story is clear and the feature is straightforward, skip to Step 3.

**Ask when:**
- User story is missing who benefits or why it's needed
- No clear scope boundary — could mean several different things
- Doc review revealed the feature touches multiple modules or has non-obvious dependencies
- Acceptance criteria are implied but not stated, and there are multiple valid interpretations
- Tension between what was asked and what the codebase currently supports

**Skip when:**
- Bug report with clear repro steps
- Small feature with obvious scope ("add a tooltip to the X button")
- User story already specifies behavior, scope, and edge cases

**If clarification is needed:**
- Ask questions **one at a time**
- Prefer multiple choice when the options are known
- Bias toward brevity — only ask what genuinely reduces ambiguity
- If the user says "just create it" or similar, stop and proceed to Step 3

**Record all Q&A pairs** for the handoff:
```
## Clarifications
Q: [question asked]
A: [user's answer]
```

### Step 3: Create GitHub issue
Use the `github-issue-creator` subagent to create a well-structured GitHub issue. **Do not add labels** to the created issue.

**Pass to github-issue-creator:**
- The original user story (below)
- The documentation findings from Step 1 (file paths and summary of current state)
- Any gaps between current implementation and what the user story requires
- Clarifications from Step 2 (structured Q&A pairs, appended after documentation findings). Omit this section if no questions were asked.

---

User Story (rough draft): $ARGUMENTS
