# GitHub Issue Template & Quality Guide

Reference for drafting and posting a well-structured GitHub issue. The calling skill
(`/devflow:create-issue`) has already gathered documentation findings and **resolved every
in-scope decision with the user**. Draft the issue **from that context**, doing only
targeted verification reads where a specific claim needs confirming. Do not re-explore
the whole codebase; the findings are your map.

## The no-options rule (read first)

The issue describes **one decided behavior built one decided way.** A developer reading
it must never have to choose between alternatives or fill in a gap to start work.

Outside the `## 🚫 Blocked` section, the body must contain **none** of:

- choice words: "or", "either / or", "alternatively", "vs", "option", "approach A vs B"
- hedge words: "could", "we might", "we may want to", "consider", "perhaps", "possibly"
- deferral words: "TBD", "to be decided", "for now", "Open Question(s)", "(optional)" for
  something that is actually undecided
- competing examples: "e.g. WeasyPrint or ReportLab" where the two are rival choices the
  developer would have to pick between

If drafting surfaces any of these, you have an unresolved decision. Resolve it with the
user, or — only if the user has disengaged — move it verbatim into the Blocked section.
Never leave it as prose in the body.

## Issue structure

Every issue includes these sections, in this order. (`## 🚫 Blocked` appears only if
unresolved items exist — see below.)

### Title
Clear, descriptive, action-oriented, and scoped to **one** feature/fix (e.g., "Add PDF
export for survey results"). If you are tempted to write "and" joining two features, the
issue should have been split in Step 2 — ask the user to split before drafting.

Exception: if the scope-split decision is itself unresolved because the user disengaged
(it is the first item in `## 🚫 Blocked`), a neutral multi-feature title is acceptable —
it honestly reflects the unresolved scope. Do not silently pick one feature to satisfy the
title rule; that would be inventing a default the skill forbids.

### Description
- **Problem Statement** — why is this needed? Which user hits what pain.
- **Current Behavior** — for a bug, what happens today; for a feature, what's missing.
- **Desired Behavior** — the single decided behavior after implementation. State it
  declaratively ("Owners export results as PDF"), never as a menu.
- **User Impact** — who benefits and how.

### Technical Context
Ground this in the documentation findings passed by the caller. Open the section with this
standardized **scope note**, included **verbatim** in every issue. It is fixed boilerplate,
not an undecided choice — the no-options gate does not apply to it, so never reword or drop
it during the no-options check:

> **Scope note:** The files and details below are the known starting points, not the full
> list. Before implementing, trace the change through the codebase to find every affected
> call site, consumer, and layer — this issue maps the work, it does not bound it.

- **Relevant Classes/Files** — specific files from the findings (verify before citing).
- **Architecture Alignment** — how this fits existing patterns.
- **Dependencies** — the specific service/module/library this depends on. If a library is
  needed, name the **one** chosen (decided in Step 2), not a shortlist.
- **Data/Schema Considerations** — schema changes, queries, or data-access patterns.
- **Cross-layer Impact** — which layers are affected (frontend, backend, API, database).

### Acceptance Criteria
Checkbox items (`- [ ]`), each a **single unconditional, testable assertion**:
- Specific and implementable — a developer knows exactly when it's met.
- No conditionals tied to an undecided fork ("if links are public…"). A conditional AC
  means the fork is unresolved — it belongs in Blocked, not here.
- Edge cases and error-handling scenarios, stated as concrete expected behavior.
- Performance/scalability considerations if relevant.
- Reference project coding standards from `CLAUDE.md` if available.

### Implementation Notes
Describe the **one** approach the user chose — not a comparison of candidates.
- **Approach** — the decided design: the specific files to touch and how the change fits.
- **Code Patterns** — patterns already used in this codebase to mirror.
- **Testing Strategy** — classify against test automation first, then state the plan so
  the implementer inherits a clear test-first expectation:
  - **Can an automated test exercise this change?** — any automated test, not only a unit
    test: a return value, an API/CLI contract, an exit code, a parser's handling of an
    input shape, a state transition, a raised error, or an end-to-end path an integration
    test can drive. If any such boundary exists, the change is covered by test automation.
  - **If automatable:** name the specific assertion to write **before** the code (unit or
    integration, whichever fits the boundary) — it must fail first for the right reason
    (the behavior does not exist yet), then pass. Tie each assertion back to an Acceptance
    Criterion above.
  - **If no automated test applies** (the deliverable is prose, templates, config, or an
    embedded DSL with no observable behavior boundary): say so with the one-line reason,
    and name the verification that stands in for a test — the acceptance criteria
    confirmed by review, or an adversarial trace of the input shapes the change must
    survive.
- **Documentation Needed** — what doc updates the change requires.
- **Potential Gotchas** — pitfalls and architectural constraints (these are warnings, not
  unresolved choices).

### 🚫 Blocked — resolve before implementation (include only if non-empty)
The **only** place unresolved decisions may appear. Include this section solely when the
user disengaged in Step 2 leaving Definition-of-Ready items open. Each item is a direct
question plus one line on why it blocks work:

```markdown
## 🚫 Blocked — resolve before implementation
- **Link access model?** Public-with-token or login-required — changes the data model and
  the security review. Implementation cannot start until this is chosen.
```

Do not soften these into "options" or attach a default. If this section is empty, omit it
entirely — do not write "Open Questions: none".

## Full-stack awareness

When a feature touches the frontend, trace the data flow back to the backend changes it
requires (new endpoints, schema changes, service methods, updated responses). When it
touches the backend, consider whether the frontend must change to consume the new data.
Map the complete path from database through API to UI — UI-only descriptions produce
incomplete issues.

## Quality checklist (verify before posting)

- [ ] Title is clear, action-oriented, and scoped to one feature/fix
- [ ] Problem statement explains the "why" and names who benefits
- [ ] Desired Behavior is stated as one decided behavior, not a menu
- [ ] Technical Context opens with the standardized scope note, included verbatim
- [ ] Technical context cites real file paths / class names from this project
- [ ] Acceptance criteria are measurable, testable, and unconditional
- [ ] Implementation notes describe a single chosen approach
- [ ] Testing Strategy classifies test-automation coverage and states the test-first expectation (or names the stand-in verification when no automated test applies)
- [ ] **No-options gate passed**: no choice/hedge/deferral language outside `## 🚫 Blocked`
- [ ] Any unresolved decision is in `## 🚫 Blocked`, phrased as a question — nowhere else
- [ ] Edge cases and error handling are considered
- [ ] Architecture constraints are explicitly noted
- [ ] Documentation references are accurate

## GitHub autolink hygiene

The body is posted to GitHub, which turns `#`-number into a link. Never put a bare `#`
before a number unless it is a real issue or PR reference — GitHub renders `#2` as a link
to issue/PR 2 and misleads readers. For an ordinal, count, or list position, spell it out
("item 2", "step 3"). Genuine references like `#123` stay as-is.

## Posting the issue

**Precondition:** only run this after the user has seen the full rendered issue and
explicitly approved creating it (Step 4 of the calling skill). Never post a draft the user
has not confirmed.

Create the issue **directly** — pipe the rendered body to `gh` via stdin with a quoted
heredoc so backticks and `$` in the markdown are not expanded. Do **not** source the body
from a file with `--body-file` (the `.devflow/tmp/issue-draft-<slug>.md` preview copy from
Step 4 is for the user's eyes only — never the posting source):

```bash
gh issue create --title "Action-oriented title here" --body-file - <<'BODY'
## Problem Statement
...full rendered issue markdown...
BODY
```

**Do NOT add labels** — never pass `--label`. Labeling is handled separately by maintainers.

`gh issue create` prints the new issue URL on success. Report that URL back to the caller.
