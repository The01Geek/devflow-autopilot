---
name: create-issue
description: Use when you have a rough user story, bug report, or feature idea that needs to become a well-structured GitHub issue.
argument-hint: <user-story>
---
## Prerequisites

If `$ARGUMENTS` is empty, ask the user to describe their user story, bug report, or feature idea before proceeding.

## Completion checklist (do this first)

This skill is a **pipeline that ends with a created GitHub issue** — not with a documentation report. Before doing anything else, create a TodoWrite todo list with exactly these items:

1. Run `/docs-verify --report-only` and capture its findings report
2. Clarify the user story (or consciously skip — see Step 2)
3. Draft and create the GitHub issue (Step 3)

Mark each todo `in_progress` when you start and `completed` only when done. **The skill is not complete until the issue is created** — a finished `/docs-verify` report is only todo 1.

## Steps

### Step 1: Assess current state (read-only)
Invoke the `/docs-verify` skill in report-only mode with the topic extracted from the user story (e.g., `/docs-verify --report-only survey module`).

This verifies internal docs against the code and **returns a findings report** — current behavior, relevant files, and any doc/code drift — **without editing, committing, or pushing anything.**

`/docs-verify` is a standalone workflow, so it announces its own completion when it finishes. That signal ends *its* report (todo 1), not this skill — keep going to Step 2. Carry the findings, including any drift noted, forward into Step 3.

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

### Step 3: Draft and create the GitHub issue

Draft the issue **from the context you already hold** — the documentation findings from Step 1 (relevant files, current behavior, any drift) and the clarifications from Step 2 — doing only targeted verification reads where a specific claim needs confirming. Do not re-explore the whole codebase; the findings are your map.

Follow `references/issue-template.md` for the required section structure, the quality checklist, autolink hygiene, and the exact `gh issue create` invocation. Key rules:

- Create the issue **directly via `gh issue create`** piping the body through stdin — no scratch file, nothing written to the working tree.
- **Do not add labels** — never pass `--label`.
- Report the issue URL that `gh` prints on success.

---

User Story (rough draft): $ARGUMENTS
