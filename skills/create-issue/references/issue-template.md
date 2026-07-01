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

**Verify every load-bearing premise before drafting — not only file paths.** Any premise the
issue relies on as fact, and any premise that seeds the Implementation Notes `Approach`, is
checked with a method matched to its class: **data-source / data-model** claims ("column X
holds the role name") against the schema definitions or the code that reads and writes that
data; **"parent PR or commit already did X"** claims at HEAD (read the file, `git log -p` /
`git log -S<symbol>`), never taken from the parent issue's narrative; **data-coverage /
population** claims ("column X is set for most users") against live data when it is available.
A load-bearing premise that cannot be verified (e.g. live data unavailable) is written as an
explicitly flagged assumption for the implementer to confirm — never baked into a prescriptive
`Approach`. Verification is **proportional** (cheap in-repo reads for most claims, live-data
only for population claims) and scoped to **load-bearing** premises, so incidental context
bullets stay light and drafting is never blocked in a data-less authoring context.

### Acceptance Criteria
Checkbox items (`- [ ]`), each a **single unconditional, testable assertion**:
- **Supplied criteria are challenged, never accepted at face value.** When the user's story
  arrives with its own acceptance-criteria list, that list is *suspect input*, not a finished
  section. Vet each item for **correctness** (is it atomic, testable, and a genuinely resolved
  decision — not an unresolved fork in disguise?) and the list as a whole for **completeness**
  (which forks, edge cases, and factors does it omit?). This is the Step-2 independent-derivation
  discipline at draft time — a polished, comprehensive-looking list earns the same scrutiny a
  terse story gets.
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
- **Testing Strategy** — the implementer must inherit a concrete, test-first plan, not a
  vague intent. Build it in three moves: **(1) classify the boundary, (2) walk the coverage
  dimensions, (3) commit to named assertions tied to ACs.** The plan you write is *decided*
  — the no-options rule still applies here: state what **will** be tested, never "we could
  test X or Y." The dimension list below is a checklist *for you while drafting*; it does
  not get pasted into the issue. What lands in the issue is the chosen assertions.

  **Move 1 — Classify the test boundary.** Can an automated test exercise this change? Any
  automated test counts, not only a unit test: a return value, an API/CLI contract, an exit
  code, a parser's handling of an input shape, a state transition, a raised error, or an
  end-to-end path an integration test can drive. If any such boundary exists, the change is
  covered by test automation. Then **name the test level(s)** deliberately — more than one
  often applies: a pure helper (e.g. an RFC-4180 quoting function) earns a unit test *and*
  the endpoint that calls it earns an integration test. Say both; do not collapse them.

  **Move 2 — Walk the coverage dimensions.** For each dimension below, either include
  concrete cases or let it drop because it genuinely does not apply — a dimension's absence
  is a *decision*, not an oversight. The Acceptance Criteria above are the floor, not the
  ceiling: most ACs spell out only the happy path, so the test plan routinely adds cases the
  ACs never named.
  - **Happy path** — the primary decided behavior for each AC.
  - **Boundary & degenerate inputs** — empty / zero / one / max: empty collection, first and
    last element, off-by-one edges, page 0 and past-the-end, size and length limits, empty
    string vs. null vs. missing. (The CSV export with *zero* responses still emits a header
    row; pagination is exercised at page 0, the exact-multiple page, and the partial final
    page — these are where off-by-ones hide.)
  - **Error & failure paths** — every error the change can raise or must reject: malformed
    input, missing resource (404), unauthenticated vs. unauthorized (401 vs. 403), conflict,
    downstream/dependency failure. Assert the *specific* failure (status, error type,
    message contract), not merely "it errors."
  - **Adversarial / malformed input** — values crafted to break parsing or escaping:
    delimiter/quote/newline injection (RFC-4180), Unicode / non-ASCII / encoding (UTF-8,
    BOM), oversized or deeply-nested payloads, and every hostile shape a parser or config
    consumer must survive without detonating.
  - **State, concurrency & idempotency** — re-running the operation, concurrent callers,
    partial-failure rollback, ordering, and double-fire. Assert the invariant still holds.
  - **Scale / performance** — only when an AC implies it (streaming vs. buffering, 100k+
    rows, query-count ceilings). Assert the *property* (no full-collection buffering, bounded
    query count), not a brittle wall-clock number.
  - **Security / authorization** — ownership and tenant isolation, and that secrets or other
    tenants' data are never exposed, whenever the change touches an access boundary.

  **Move 3 — Commit to named assertions.**
  - **Every AC maps to at least one named assertion, and every assertion maps back to an
    AC** — no orphans in either direction. If an AC cannot be pinned by any assertion, it is
    not testable as written: tighten it, or it belongs in `## 🚫 Blocked`.
  - Each assertion is **test-first**: written before the code, it must fail first *for the
    right reason* — and spell that reason out. For a *feature*, the right reason is that the
    behavior does not exist yet. **For a bug fix, the right reason is that the test
    reproduces the reported defect** — the regression test must fail against today's code by
    exhibiting the exact wrong behavior (the dropped last row, the off-by-one), then pass
    after the fix. "Behavior doesn't exist yet" is the wrong framing for a bug; the wrong
    behavior already exists.
  - Name the **fixtures / test doubles** the failing test needs, and what must **not** be
    mocked — never mock the unit under test or the boundary the assertion is proving.
  - **Don't test the framework.** Assert observable behavior (the CSV bytes round-trip
    through a standard parser, the row count, the raised error type), not internal wiring or
    library internals (a specific transport header the framework sets, a private call count)
    *unless that wiring is itself the AC*.
  - **Guarantee-class changes** (the deterministic backstop / hook / gate mechanisms on the
    Step 2 strength ladder): the test must prove the guarantee holds **on the path where the
    actor skipped the manual step** — that is the entire reason the mechanism exists. Assert
    it fires (and is idempotent) when a human or agent *forgot* the cooperative step, not
    only when everyone cooperated.

  **If no automated test applies** — the deliverable is prose, marketing copy, pure config
  with no consumer behavior, or a DSL with no observable boundary — say so with the one-line
  reason, then give the stand-in as a **reproducible verification**: a numbered manual
  checklist or an adversarial trace of the input shapes the change must survive, each item
  tied to an AC and concrete enough that a second reviewer reaches the same verdict.
  "Confirmed by review" alone is not a plan — state *what* the reviewer checks and *how they
  know it passed.*
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
- [ ] Load-bearing Technical Context premises (data-source/model, coverage/population, "already-done") are verified — not just file paths — or written as flagged assumptions to confirm
- [ ] Acceptance criteria are measurable, testable, and unconditional
- [ ] Implementation notes describe a single chosen approach
- [ ] Testing Strategy classifies the boundary + level, walks the coverage dimensions (boundary/error/adversarial/state/scale/security as they apply), and gives test-first assertions with every AC mapped to ≥1 assertion and no orphan assertions — bug fixes reproduce the defect first; guarantee-class changes test the skipped-step path; or it names a reproducible stand-in verification when no automated test applies
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
