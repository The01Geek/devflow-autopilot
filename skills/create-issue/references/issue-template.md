# GitHub Issue Template & Quality Guide

Reference for drafting and posting a well-structured GitHub issue. The calling skill
(`/create-issue`) has already gathered documentation findings and clarifications — draft
the issue **from that context**, doing only targeted verification reads where a specific
claim needs confirming. Do not re-explore the whole codebase; the findings are your map.

## Issue structure

Every issue includes these sections, in this order:

### Title
Clear, descriptive, action-oriented (e.g., "Add bulk order status editing with date range filtering").

### Description
- **Problem Statement** — why is this needed? What pain point does it solve?
- **Current Behavior** — for a bug, what happens today; for a feature, what's missing.
- **Desired Behavior** — what should happen after implementation.
- **User Impact** — who benefits and how.

### Technical Context
Ground this in the documentation findings passed by the caller:
- **Relevant Classes/Files** — specific files from the findings (verify before citing).
- **Architecture Alignment** — how this fits existing patterns.
- **Dependencies** — other services, modules, or features it depends on.
- **Data/Schema Considerations** — schema changes, queries, or data-access patterns.
- **Cross-layer Impact** — which layers are affected (frontend, backend, API, database).

### Acceptance Criteria
Measurable, testable checkbox items (`- [ ]`):
- Specific, implementable requirements.
- Edge cases and error-handling scenarios.
- Performance/scalability considerations if relevant.
- Reference project coding standards from `CLAUDE.md` if available.

### Implementation Notes
- **Recommended Approach** — architecture patterns or design decisions.
- **Code Patterns** — patterns already used in this codebase.
- **Testing Strategy** — how this should be tested.
- **Documentation Needed** — what doc updates the change requires.
- **Potential Gotchas** — pitfalls and architectural constraints.

## Full-stack awareness

When a feature touches the frontend, trace the data flow back to the backend changes it
requires (new endpoints, schema changes, service methods, updated responses). When it
touches the backend, consider whether the frontend must change to consume the new data.
Map the complete path from database through API to UI — UI-only descriptions produce
incomplete issues.

## Quality checklist (verify before posting)

- [ ] Title is clear and action-oriented
- [ ] Problem statement explains the "why"
- [ ] Technical context cites real file paths / class names from this project
- [ ] Acceptance criteria are measurable and testable
- [ ] Implementation notes give genuine technical guidance
- [ ] Recommendations align with existing patterns and conventions
- [ ] Edge cases and error handling are considered
- [ ] Architecture constraints are explicitly noted
- [ ] Documentation references are accurate

## GitHub autolink hygiene

The body is posted to GitHub, which turns `#`-number into a link. Never put a bare `#`
before a number unless it is a real issue or PR reference — GitHub renders `#2` as a link
to issue/PR 2 and misleads readers. For an ordinal, count, or list position, spell it out
("item 2", "step 3"). Genuine references like `#123` stay as-is.

## Posting the issue

Create the issue **directly** — no intermediate scratch file. Pipe the rendered body to
`gh` via stdin with a quoted heredoc so backticks and `$` in the markdown are not expanded:

```bash
gh issue create --title "Action-oriented title here" --body-file - <<'BODY'
## Problem Statement
...full rendered issue markdown...
BODY
```

**Do NOT add labels** — never pass `--label`. Labeling is handled separately by maintainers.

`gh issue create` prints the new issue URL on success. Report that URL back to the caller.
