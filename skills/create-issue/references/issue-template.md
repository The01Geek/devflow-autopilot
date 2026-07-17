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

Every issue includes these sections, in this order. (A **`## Dependencies`** section
appears as the very first body section only when a prerequisite is still open at drafting
time, a **Visual Specification** section appears only for user-visible UI changes, and
`## 🚫 Blocked` appears only if unresolved items exist — see below.)

### Title
Clear, descriptive, action-oriented, and scoped to **one** feature/fix (e.g., "Add PDF
export for survey results"). If you are tempted to write "and" joining two features, the
issue should have been split in Step 2 — ask the user to split before drafting.

Exception: if the scope-split decision is itself unresolved because the user disengaged
(it is the first item in `## 🚫 Blocked`), a neutral multi-feature title is acceptable —
it honestly reflects the unresolved scope. Do not silently pick one feature to satisfy the
title rule; that would be inventing a default the skill forbids.

### Dependencies (include only when a prerequisite is still open at drafting time)
Rendered as the **first body section, above `## Problem Statement`** — and included **only**
when at least one prerequisite issue is **still open at drafting time**. Each entry is one
line naming the blocking issue and why it must land first:

```markdown
## Dependencies
Blocked by #N — <one-line reason it must land first>
```

Both the `## Dependencies` heading and the `Blocked by #N` phrasing are exactly the forms
`/devflow:implement` Phase 1 Pass 4 recognizes as a declared sequencing dependency, so the
existing implement gate consumes this section with **no recognizer change** — it blocks an
implement run while any listed prerequisite is still open (and fails closed on an
unresolvable reference). Omit the section entirely when no prerequisite is open — exactly as
the Visual Specification and Blocked sections are omitted when empty; never write
"Dependencies: none".

Keep this section distinct from the two other "dependency"-flavored surfaces, or drafters
will file entries in the wrong one:

- **`## Dependencies` (this section)** — cross-issue **ordering**: another issue/PR that must
  land before this work can start. This is the only surface Pass 4 reads.
- **`## 🚫 Blocked`** — unresolved **decisions**, not ordering (see below).
- **`Technical Context` → `Dependencies` bullet** — the **service/module/library** this
  depends on, not another issue.

A prerequisite that is **already closed at drafting time** is not listed here — record it as
provenance in `Technical Context` instead (e.g. "builds on #M, merged"), never in this
section, so producer and Pass-4 consumer agree on the open-at-drafting-time inclusion rule.

### Problem Statement
Why is this needed? Which user hits what pain.

### Current Behavior
For a bug, what happens today; for a feature, what's missing.

### Desired Behavior
The single decided behavior after implementation. State it declaratively ("Owners
export results as PDF"), never as a menu.

### User Impact
Who benefits and how.

### Technical Context
Ground this in the documentation findings passed by the caller. Open the section with this
standardized **scope note**, included **verbatim** in every issue. It is fixed boilerplate,
not an undecided choice — the no-options gate does not apply to it, so never reword or drop
it during the no-options check:

> **Scope note:** The files and details below are the known starting points, not the full
> list. Before implementing, trace the change through the codebase to find every affected
> call site, consumer, and layer — this issue maps the work, it does not bound it.

- **Relevant Classes/Files** — specific files from the findings (see load-bearing-premise
  verification below).
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
population** claims ("column X is set for most users") against live data when it is available;
and **relied-on third-party behavior** — every behavior of an external platform, API, or
service the issue **relies on** (load-bearing for the Desired Behavior, an acceptance
criterion, **or** the Implementation Notes Approach — not only an AC's mechanism): webhook /
event delivery, trigger syntax, token scopes, endpoint behavior, response shapes, rate
limits, and the like. Relied-on behavior is **never assumed**. Verify it with this **decided
fallback ladder**, in order, stopping at the first rung that resolves it: **(1)** the vendor's
**official documentation via `WebFetch`** (not memory); **(2)** when the official docs are not
reachable, **`WebSearch`**; **(3)** when search is unavailable or fails, **ask the user to
provide the documentation**. Record the verified fact and its source URL in the draft's
`Technical Context` before the relied-on claim is written. This is the premise class the #304
run missed: it prescribed a `check_suite`/`workflow_run` mechanism GitHub cannot deliver
(Actions-created check suites never emit `check_suite`; `workflow_run` requires a named
workflow list), which only surfaced mid-implement — a `WebFetch` of the events docs at
drafting time would have caught it.

**Ladder terminal arm — decided two ways.** When the ladder yields **no documentation** and
**no working example in this codebase already proves** the relied-on behavior, the item
becomes a `## 🚫 Blocked` entry phrased as a **direct question** — the exact vendor-behavior
fact to confirm plus one line on why it blocks the work — because an unverifiable load-bearing
external premise blocks implementation exactly as an undecided decision does. When a **working
in-codebase example does prove** the behavior but documentation remains unavailable, write the
claim inline as an explicitly flagged `— assumption, confirm before implementing` line
**citing that in-repo example** (not a Blocked entry).

Treat an empty or inconclusive result (no matching commit, no matching column/schema, data
unavailable) as **unverified** — never as silent confirmation. A load-bearing premise that
cannot be verified is written as an explicitly flagged assumption for the implementer to
confirm — stated inline as a declarative fact tagged `— assumption, confirm before
implementing` (a factual premise-to-confirm, so the no-options gate's hedge/deferral ban does
not apply to it, and it is not a `## 🚫 Blocked` item — **with the one exception of the
ladder terminal arm above**, where a relied-on third-party behavior that is neither
documentation-verified nor proven by an in-repo example becomes a Blocked vendor-behavior
question), and never baked into a prescriptive `Approach`.

Verification is **proportional**: cheap in-repo reads for most claims, live-data only for
population claims, and the docs ladder only for **relied-on** third-party behavior. It is
scoped to **load-bearing** premises, so incidental context bullets — and an **incidental
third-party mention** (named in passing, not load-bearing for the Desired Behavior, an AC, or
the Approach) — stay light and trigger no verification, so drafting is never blocked in a
data-less authoring context.

**Unstated mechanism dependencies are a premise class too.** The verification above attaches
to premises the issue **states as fact**. But a designed mechanism can *rely on* an in-repo
behavior — a helper's exit code, a resolver's output shape, a gate's semantics — that the body
never asserts as a claim, so the claim-driven loop has nothing to verify (issue #446's
config-unreadable arm rested on `config-get.sh`'s malformed-input non-zero exit without ever
asserting it as a claim). Enumerate the draft's **own mechanism dependencies** — the in-repo
behaviors the designed mechanism relies on but never states — and resolve each with a **cited
probe** (a "Verified:" bullet citing observed output) or an **implementer-obligation AC** (subject
to the obligation-arm execution-tier constraint in the Acceptance Criteria guidance above: a
command already granted in `devflow_implement.allowed_tools`, or a code-reading obligation citing
the producer — never an ungranted-helper run). This is the **in-repo sibling of the
relied-on-third-party-behavior class** above — same discipline, extended to unstated in-repo
reliances; it adds no duplicate premise class.

**Occurrence counts and coupled-site lists are a premise class too.** A *count* of in-repo
occurrences ("fixed at both call sites", "the ten coupled invariants") or a *list* of mirror
sites is a load-bearing premise the claim-driven loop otherwise accepts as written — and a count
assembled from **recall** is exactly how a real enumeration silently drifts (a claimed "both
occurrences" while the pattern lives at several more sites). Ground it one of two decided ways,
selected by observed drafting-time capability: **(a) executed** — where the drafter's tier grants
a repository text search, run a **whitespace-normalized** search (a phrase wrapped across adjacent
lines defeats a line-based search) and cite it in the draft as a **"Verified:"** bullet carrying
the exact command and its hit list; **(b) records** — where that search command is unavailable or
denied on the tier, and for any count **not derivable from a repository text search** (a count of
pull-request occurrences, a tally over an evidence bundle), cite the specific evidence records
consulted — the query output, the source rows — **record-by-record**. Neither arm accepts a count
from recall.

**Verifying "the code does X" includes the gates on the path to X.** Confirming that the code
doing X exists and does X is not complete until you have read the **enclosing gates,
conditionals, and their defaults** on the path that reaches X — a claim can be true of code that
a default-off conditional never executes ("appended by the runner" when the append is gated
behind a flag that defaults false). A premise that holds only under a **non-default
configuration** states that precondition **inside the claim**, never as a bare "the code does X".

This same discipline runs **twice**: here at drafting time, and again in the calling
skill's Step 3.5 self-steelman, which re-applies it to the *assembled* draft (fresh
targeted reads/greps against the code, never ambient context) before the user sees it.
Keep the two coherent — a change to the premise-classes or the flagged-assumption form
above must carry into Step 3.5's checks.

### Visual Specification (include only for user-visible UI changes)
Include this section **only** when the issue involves user-visible UI changes (Step 2's
visual-specification guidance decided this). Omit it entirely for non-UI issues — do not
leave an empty "Visual Specification: none" placeholder, exactly as the Blocked section is
omitted when empty.

Record one of two things, per what Step 2 obtained from the user:

- **A screenshot or mockup** — embed it inline when a hosted URL is available
  (`![description](https://…)`); otherwise reference it with a one-line note on how the
  implementer can obtain it (attached file name, design-tool link such as Figma).
- **A verbally-verified placement spec** — when the user has no screenshot/mockup, the
  pinned-down visual details Step 2 verified with them: placement & layout, visual states
  (hover/focus/error/empty/loading/disabled), responsive behavior across breakpoints, and
  design-system/style match, plus any task-specific dimension. Only the dimensions that
  actually apply appear here; a screenshot is preferred, but this verbal spec is an
  accepted substitute.

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
- **A value-comparison AC states its comparison in the producing surface's observed-output
  terms — in the AC's own language.** When an AC (or a Testing-Strategy assertion) compares a
  produced value against a literal, phrase the comparison in the terms the producing surface
  actually emits, grounded one of two decided ways. **(a) The verified arm** — a drafting-time
  probe cited in the issue; the cited probe must exercise the **boundary fixtures the
  comparison distinguishes** (for a type-sensitive comparison, the type-boundary fixture — a
  JSON string `"true"` vs. a boolean `true`), and a probe **silent on the distinguishing axis
  does not ground the verified arm**. **(b) The obligation arm** — a named implementer
  obligation stating the **decided semantics** or the **exact fixture-and-observed-output
  command** the implementer runs, never a bare "establish the semantics." Before taking the
  obligation arm for a *probeable* fact, a drafter whose direct helper probe is classifier-denied
  first attempts the documented local-tier fallback probe forms (`python3 <path>` / `jq`); only
  when those are also unavailable is the obligation arm legal for that fact. When the axis is a
  specification *choice* rather than a probeable fact, it is **not** an obligation — it is a Step
  2 decision fork resolved with the user (Blocked on disengagement). **Adjective-only comparison
  language** ("explicit `true`", "reads as exactly `true`") without that grounding is
  **non-conforming** — including the shape where a probe is present in the issue but **silent on
  the axis** the AC's language gestures at (the named #446 defect). **Obligation arms are
  implement-tier verification commands (this governs this value-comparison AC and the Step 3.5
  unstated-mechanism-dependency hunt alike):** an obligation whose discharge requires *executing* an in-repo command must name a
  command already granted on the consuming tier (the repo's declared test/lint commands in
  `devflow_implement.allowed_tools`) or be phrased as a **code-reading obligation citing the
  producer code** — never a run-this-ungranted-helper AC that would send a consumer repo's cloud
  `/devflow:implement` run Blocked for a probe the drafter could have run locally.
- **Every universal quantifier the body asserts about the system under change is grounded,
  or it does not ship.** A universal quantifier — "never", "always", "each", "every", "all",
  "cannot" — asserted anywhere outside `## 🚫 Blocked` (in Desired Behavior, an
  acceptance criterion, Technical Context, or the Testing Strategy) is grounded one of three
  decided ways: **(a) pinned** — a named AC or assertion covers each arm or element the
  quantifier ranges over, and an **accepted-loss / suppression** claim ("X is silently
  dropped", "never surfaces Y") is pinned by a fixture in which the suppressed input is
  *present*, so the claimed absence is actually exercised; **(b) scoped** — rewritten to the
  precise form the mechanism supports ("no *per-file* filename arguments", not "no filename
  arguments"); or **(c) removed**. The carve-out is stated inside this rule and is
  **extensional, not grammatical**: exempt are only (i) mandated-verbatim template boilerplate
  (the Technical Context scope note, `Blocked by #N` lines) and (ii) rule text the change ships
  as artifact content (a convention sentence the change adds to a file, quoted in the body). An
  acceptance-criterion or Desired-Behavior sentence is **never** exempt however imperative its
  phrasing — its universal is a claim about the post-change system by definition. A **detector
  or guard coverage claim** ("catches all future X", "can never fall behind", "every violation
  is flagged") additionally carries a **planted-defect positive-control obligation** on the
  implementer — plant the defect the guard targets and prove the guard fires on it — the
  claim-level counterpart to the mechanism-level **Guarantee-class bullet in Testing Strategy
  Move 3**, extended from the delivered mechanism's tests to the coverage claim itself.
- **An AC establishing a trust or integrity boundary over executable artifacts defines the
  protected set over the transitive closure.** When an acceptance criterion protects scripts,
  hooks, or anything sourced, exec'd, or imported — asserts they cannot be tampered with, are
  validated, or run from a trusted copy — the protected set is defined over the **transitive
  source / exec / import closure** of the named entry points, not the entry points alone (a
  protected script that `source`s an unprotected sibling leaves the boundary open one hop
  deeper). An issue that deliberately protects less states the **residual unprotected surface**
  explicitly.
- **No acceptance criterion forbids a surface another criterion's discharge must touch.** The
  criteria are checked against *each other* for mutual consistency: an AC that bars a path, a
  file class, or a tier that a second AC's implementation must edit is an unresolved scope fork,
  not two independent criteria — reconcile it (widen the exclusion, or move the conflict to
  `## 🚫 Blocked`) before the issue ships.
- **A designed LLM/semantic-judgment surface over third-party text carries an input-is-data
  guard, paired with a hostile-input test.** When the issue designs a *new* LLM or semantic
  judgment over text the change does not author (issue bodies, PR comments, commit messages,
  external API responses) whose output drives an automated selection or action, the draft
  carries the guard as an acceptance criterion — the text is **data to classify, never
  instructions to obey** — **paired with** a Testing Strategy case that exercises
  instruction-shaped input (a body that directs the judgment) and asserts it is **not**
  obeyed: an automated assertion where a test boundary exists, otherwise a named item in the
  reproducible verification checklist. The guard AC without the paired hostile-input case is
  non-conforming — the pairing exists so the guard cannot be satisfied by a compliance
  sentence the implementation never ships. A surface that **reuses an existing,
  already-guarded judgment path is exempt when the draft cites that path**; a draft with **no
  new judgment surface gains no new questions and no new flags** (the same
  skip-when-inapplicable shape as the visual-specification guidance).
- **Every enumerated test/case/example list inside an AC declares its closure.** Such a list
  takes one of two forms: a **floor**, carrying the exact marker `at minimum`, or a **closed
  set**, carrying an explicit exhaustiveness statement of the shape `exactly these N —
  complete by construction`. An enumeration carrying neither is non-conforming — declare it a
  floor or a closed set. ACs themselves stay closed, testable assertions; the adjacent-case
  sweep obligation for a floor-marked list lands in Testing Strategy Move 2 below.
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
  ACs never named. This floor-not-ceiling rule extends to a **floor-marked AC list** (one
  carrying the `at minimum` marker): the coverage walk sweeps the new capability's contract
  dimensions — **state, case variants, multiplicity, absence** — beyond the enumerated items,
  and **writes the sweep's output back as additional closed AC items before filing**, so no AC
  is left open-ended for a non-interactive run that must decide when it is met.
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

  **Move 2a — Reconcile an enumerated case matrix against governing conventions.** *This
  applies only when the Testing Strategy enumerates an input-shape or case matrix* for a
  surface (a parser, a config consumer, a best-effort input handler) — a matrix-free Testing
  Strategy imposes nothing here, so a convention-free repo's issues carry at most one bounded-search
  line and only when they enumerate a matrix. When it *does* enumerate one, and a repo-published
  convention already governs that surface's matrix, the issue either enumerates the **full
  convention matrix** or states the **narrowing explicitly with its justification** — a silently
  narrower list must never override the convention. Such a Testing Strategy (only this class of
  issue) carries a one-line **discharge record**:

  > `governing conventions consulted: <sources cited by path, or "none found; searched <the bounded list>">`

  The search is **bounded to a named list** — `CLAUDE.md`, `CONTRIBUTING.md`, and testing
  guidance under the repo's configured internal-docs path — with the **consumer prompt extension**
  as the override point naming where that repo's conventions actually live; cite sources by path
  when found. The record is a **claim to verify, not an attestation to accept**: the Step 3.6
  auditor independently re-runs the bounded search and its flag condition is **defined** — it
  fires when the auditor finds a governing matrix at a path the line omits, never on a judgment
  disagreement about what counts as governing. (On a runner where Step 3.6 takes its degraded
  inline arm, the verify-not-attest property does not hold — the record is attestation-only there,
  which the mandatory "degraded" audit-summary marker already signals.)

  **Move 2a also fires on *introduction*, not only on narrowing.** An issue that introduces a
  **reader of input the repo does not itself produce** — historical records, user- or
  reporter-controlled text, an external structured format, agent- or human-mutable markdown —
  **enumerates that input's malformed / boundary shape matrix in the Testing Strategy**,
  appropriate to the input's type, including **at least one production-realistic fixture** (a
  real captured record, not only a hand-built well-formed token). A deliberately narrower
  enumeration states its **justification**. A **blanket testing-scope waiver** ("this artifact
  has no desk test", "the parser itself is untested") is **non-conforming**; a conforming
  waiver states what **inside the exempted artifact remains governed** — which behavior is still
  covered, and by what.

  **Move 3 — Commit to named assertions.**
  - **Every AC maps to at least one named assertion, and every assertion maps back to an
    AC** — no orphans in either direction; **and every state a multi-state contract enumerates
    maps to ≥1 AC** (a status enum, an outcome-token set, an error/exit-code set, or a
    state-machine node — the *contract-enumeration* sense of "state", distinct from the runtime
    *State, concurrency & idempotency* coverage dimension above). If an AC cannot be pinned by
    any assertion, it is not testable as written: tighten it, or it belongs in `## 🚫 Blocked`.
  - Each assertion is **test-first**: written before the code, it must fail first *for the
    right reason* — and spell that reason out. For a *feature*, the right reason is that the
    behavior does not exist yet. **For a bug fix, the right reason is that the test
    reproduces the reported defect** — the regression test must fail against today's code by
    exhibiting the exact wrong behavior (the dropped last row, the off-by-one), then pass
    after the fix. "Behavior doesn't exist yet" is the wrong framing for a bug; the wrong
    behavior already exists.
  - **A mechanical claim is verified-or-obligation, never a bare prediction.** When an
    assertion states a mechanical outcome — "running X reports Y", "the extractor/grep/command
    emits Z", "this must fail RED reporting W" — take exactly one of two decided forms: **(a)
    verified** — you actually ran the extraction/grep/command while drafting the issue and cite
    its **observed** output, or **(b) an obligation** — write it as a requirement on the
    implementer ("the pin must cover X"), **never** a prediction of the specific result Y/Z/W
    you did not execute. An unverified mechanical prediction reads exactly like a decided
    requirement and sends the implementer to re-derive (or encode) a falsehood. The same
    discipline governs **Relevant Classes/Files line anchors**: cite the symbol or section, not
    a `file:line` number, which rots between drafting and implementation.
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
The **only** place unresolved decisions may appear. Include this section when the user
disengaged in Step 2 leaving Definition-of-Ready items open — **or** when the relied-on
third-party-behavior ladder (see *Technical Context* above) terminates with a load-bearing
external premise that is neither documentation-verified nor proven by an in-repo example: that
ladder-produced vendor-behavior question is the one Blocked entry class not arising from user
disengagement. Each item is a direct question plus one line on why it blocks work:

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
- [ ] Open cross-issue prerequisites are listed in `## Dependencies` as `Blocked by #N — <reason>` lines (rendered above Problem Statement, only when a prerequisite is still open at drafting time; already-closed prerequisites recorded as Technical Context provenance instead)
- [ ] Load-bearing Technical Context premises (data-source/model, coverage/population, "already-done", relied-on third-party behavior) are verified — not just file paths; relied-on third-party behavior is checked against official docs via the WebFetch → WebSearch → ask-the-user ladder with the source recorded — or, when unverifiable, becomes a `## 🚫 Blocked` vendor-behavior question (or a flagged assumption citing an in-repo example)
- [ ] For a user-visible UI change, the Visual Specification section records a screenshot/mockup or a verbally-verified placement spec (screenshot preferred, verbal verification an accepted substitute); non-UI issues omit the section entirely
- [ ] Acceptance criteria are measurable, testable, and unconditional
- [ ] Value-comparison ACs/assertions state the comparison in the producing surface's observed-output terms, grounded by a boundary-covering probe (exercising the type-boundary fixture the comparison distinguishes) or a named implementer obligation carrying its execution-tier constraint — adjective-only or probe-silent-on-the-axis comparison language is non-conforming
- [ ] Every universal quantifier ("never/always/each/every/all/cannot") the body asserts about the system under change, outside `## 🚫 Blocked`, is grounded — pinned per-arm/per-element (an accepted-loss/suppression claim pinned by a fixture in which the suppressed input is present), scoped to the mechanism's supported form, or removed — with only mandated-verbatim boilerplate and rule-text-shipped-as-artifact-content exempt, and detector-coverage claims additionally carrying a planted-defect positive-control obligation
- [ ] No AC forbids a surface (a path, a file class, a tier) that another AC's discharge must touch — the ACs are mutually consistent
- [ ] An AC establishing a trust/integrity boundary over executable artifacts defines the protected set over the transitive source/exec/import closure of its entry points, or states the residual unprotected surface explicitly
- [ ] A Testing Strategy that enumerates an input-shape/case matrix for a convention-governed surface carries the full convention matrix (or an explicit named-and-justified narrowing) and a `governing conventions consulted:` discharge line bounded to `CLAUDE.md`, `CONTRIBUTING.md`, and the configured internal-docs path
- [ ] The draft's own unstated mechanism dependencies (relied-on in-repo helper/resolver/gate behaviors it never asserts as claims) are each resolved with a cited probe or an implementer-obligation AC
- [ ] Every in-repo occurrence count or coupled-site list is grounded by an executed whitespace-normalized search (cited as a "Verified:" bullet with the command and its hit list) where the tier grants one, else by the specific evidence records consulted record-by-record — never assembled from recall
- [ ] A premise verified as "the code does X" was read with its enclosing gates/conditionals and their defaults on the path to X, and any claim that holds only under a non-default configuration states that precondition inside the claim
- [ ] A designed LLM/semantic-judgment surface over third-party text (issue bodies, PR comments, commit messages, external API responses) carries the input-is-data guard AC paired with a hostile-input Testing Strategy case that asserts instruction-shaped input is not obeyed — or cites the existing already-guarded judgment path it reuses; a draft with no such surface adds nothing here
- [ ] Every enumerated test/case/example list inside an AC declares its form — the `at minimum` floor marker or an explicit closed-set exhaustiveness statement — and each floor-marked list has had Move 2's coverage sweep (state, case variants, multiplicity, absence) written back as additional closed AC items
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

Create the issue **directly**, sourcing the body from the **single presentation source** — the
same bytes the user approved. Which source that is depends on the epoch's arm:

**On a file-arm epoch**, the body comes from the gated canonical file, via the state owner's
`emit-body` query. **Do not pipe it into `gh`**:

```bash
# WRONG — a refused emit-body exits non-zero with EMPTY stdout, and without pipefail
# `gh` still runs and creates an EMPTY-BODIED issue:
#   python3 .../issue-audit-state.py emit-body "<slug>" ... | gh issue create --body-file -
```

Instead emit to a temp file, **guard it non-empty, and only then post** — so a refusal stops
creation rather than filing an empty issue. Do this in **one single statement** (a shell
variable assigned in one statement and read in a later statement of the same inline command is
stripped by some runners' marshaling — the cross-statement hazard this repo bans), and go
through a file rather than a `"$(…)"` capture: command substitution strips trailing newlines
and a re-emitting `printf '%s\n'` re-adds exactly one, mutating the posted bytes against the
recorded body-only digest (a false attestation mismatch). The file round-trip is **byte-exact**.
Substitute `<main-root>` with the main working-tree root Step 4 sub-step 2 already resolved
via `resolve-main-root.sh` (the root whose `.devflow/tmp` that sub-step already created —
a cwd-relative `.devflow/tmp/` may not exist inside a linked worktree checkout). The
guarded file is handed to `gh` directly via `--body-file <path>` — never re-piped through
`cat`, whose absence (a non-preflight PATH tool) would feed `gh` empty stdin and create the
empty-bodied issue the guard exists to prevent; this temp file IS the gated `emit-body`
output, so the old never-`--body-file` rule (which banned the unaudited preview copy) does
not apply to it:

```bash
python3 "${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/issue-audit-state.py emit-body "<slug>" --nonce "<nonce>" --draft-file "<absolute issue-draft-<slug>.md path>" > "<main-root>/.devflow/tmp/issue-body-<slug>.md" && test -s "<main-root>/.devflow/tmp/issue-body-<slug>.md" && gh issue create --title "Action-oriented title here" --body-file "<main-root>/.devflow/tmp/issue-body-<slug>.md"
```

**On an embed- or inline-arm epoch** there is no trustworthy canonical file, so the body is
re-emitted from context through a quoted heredoc (quoted so backticks and `$` in the markdown
are not expanded). This is a **disclosed residual**, not the preferred path — the re-emission is
not byte-identical-by-construction the way `emit-body` is:

```bash
gh issue create --title "Action-oriented title here" --body-file - <<'BODY'
## Dependencies
Blocked by #N — <reason>
(include this section, above Problem Statement, ONLY when a prerequisite is still open at
drafting time; omit it entirely otherwise)

## Problem Statement
...

## Current Behavior
...

## Desired Behavior
...

## User Impact
...

## Technical Context
...

## Acceptance Criteria
...

## Implementation Notes
...
BODY
```

**Do NOT add labels** — never pass `--label`. Labeling is handled separately by maintainers.

`gh issue create` prints the new issue URL on success. Report that URL back to the caller.
