---
name: add-ticket
description: Creates a GitHub issue from a rough user story. First uses doc-verifier to document current state, then passes findings to github-issue-creator to produce a well-structured issue.
argument-hint: <user-story>
disable-model-invocation: true
---
## Steps

### Step 1: Document current state
Invoke the `/verify-doc` skill with the topic extracted from the user story (e.g., `/verify-doc survey module`).

This will verify and update documentation in `docs/internal/` for the relevant features.

After the skill completes, commit and push the documentation changes.

### Step 2: Create GitHub issue
Use the `github-issue-creator` subagent to create a well-structured GitHub issue.

**Pass to github-issue-creator:**
- The original user story (below)
- The documentation findings from Step 1 (file paths and summary of current state)
- Any gaps between current implementation and what the user story requires

---

User Story (rough draft): $ARGUMENTS
