## Phase 2: Discover, Plan & Implement

Output: `Phase 2/4: Discover, Plan & Implement...`

Update the workpad: `workpad.py update $ISSUE_NUMBER --status Discovering --note "entered Phase 2"`.

### 2.1 Discovery

Use the **Agent tool** with `subagent_type: devflow:code-explorer` to explore the codebase and understand the system as it relates to the issue.

**The issue body is a starting point, not the source of truth.** Treat its problem framing, any stated root cause, and its Technical Context as a strong lead to *verify* — never fact to implement on faith. The explorer (and the architect in Path B) confirm the issue's claims against the actual code; where a **descriptive** claim (current behavior, the stated root cause) diverges from the code, **the code wins**: surface the divergence in the workpad and plan from what the code shows, rather than implementing a claim the code contradicts.

**Know which sections are authoritative.** The issue's *narrative* — Problem Statement, Current Behavior, User Impact, Technical Context, and the Implementation Notes prose (including its `Documentation Needed` bullet) — is a non-authoritative starting point to verify, not a mandate. The **Desired Behavior** and **Acceptance Criteria** sections are the authoritative decided spec the implementation must satisfy. The "code wins" rule above applies to **descriptive** claims only — it never overrides Desired Behavior or Acceptance Criteria, which are prescriptive decisions, not descriptions of current behavior. "Non-authoritative" means the narrative cannot be used to **narrow or suppress** required work — *not* "ignore it": verify each narrative claim, but never let a wrong or contradictory narrative talk you out of work the authoritative sections (and the shipped diff) warrant.

**Pick the exploration map first.** Default is `.docs.internal`. Override it when the issue scope sits outside app code — scan the issue body for path mentions (`.github/workflows/`, `.claude/`, `scripts/`, `cron/`, `tools/`, etc.) or a section headed "Technical Context", "Relevant files", "Files to touch", "Files to change", or "Implementation files"; collect those paths as `PRIMARY_PATHS` and instruct the explorer to read them first, falling back to `.docs.internal` only for gaps. Otherwise `PRIMARY_PATHS` stays empty and the default applies.

Pass the following prompt:
- The GitHub issue title, body, and labels
- **Explicit instruction:** "Start by reading {PRIMARY_PATHS if non-empty, otherwise the internal documentation path from `.devflow/config.json` via `"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/config-get.sh .docs.internal docs/internal/`} and read relevant files under that path to understand the system architecture and identify which modules and files are relevant to this issue. Use the documentation as a map to guide your code exploration. Then explore the actual code guided by those findings. Return a distilled summary of: relevant files, current behavior, patterns used, dependencies, and anything the implementer needs to know."

Documentation updates are handled in Phase 4 by the `devflow:docs` subagent — it has the full picture (the shipped code, not just the plan) and the right mandate. Do not edit `.docs.internal` here; if the explorer surfaced outdated or missing docs, that signal carries forward in your context to Phase 4.1 where the subagent will act on it.

### 2.1.5 Reproduce-First Gate (only for `bug`-labelled issues)

If the issue's labels (saved in 1.1) **do not** include `bug`, skip this step entirely and continue to 2.2.

If the labels **do** include `bug`, you must capture a *reproduction signal* before planning a fix. A reproduction signal is any one of:

- a new failing test in the diff that exercises the bug,
- a quoted error log / stack trace from a real run, or
- a recorded shell command (with output) that demonstrates the failure.

Write the evidence to a temp file, then: `workpad.py update $ISSUE_NUMBER --status Reproducing --set-reproduction-file /tmp/repro-${ISSUE_NUMBER}.md --tick-progress "reproduction captured" --note "captured reproduction signal"`. (The helper inserts `## Reproduction` after `## Acceptance Criteria` if it doesn't yet exist.)

**Temporary proof edits are allowed** when they raise confidence in the reproduction (e.g. inserting a `console.log`, hardcoding a request payload, tweaking a build input). Every temporary proof edit MUST be reverted before the implementation commit in 2.5, and the fact that you made one must be recorded in the workpad's `Reproduction` section so reviewers can follow the evidence.

**Phase 2.2 cannot start until the workpad's `Reproduction` section is populated.** If you cannot reproduce the bug: `workpad.py update $ISSUE_NUMBER --status Blocked --reflection-kind blocked --reflection "cannot reproduce: {obstacle}"`, then emit the 👎 outcome reaction (see *Outcome reaction* in the Workpad Reference) and stop the run — do not invent a fix.

### 2.2 Assess Complexity & Plan

`workpad.py update $ISSUE_NUMBER --status Planning`.

Using the explorer's findings (and the reproduction signal, for bugs), evaluate the issue complexity:

**Simple issues** (implement directly — skip architect):
- Single-module changes (e.g., add a field, fix a bug, update a config)
- Clear solution described in the issue body
- No architectural decisions needed
- Touches ≤ 5 files

**Complex issues** (use architect subagent):
- Cross-module changes affecting multiple subsystems
- New features requiring design decisions
- Changes to interfaces, data models, or system architecture
- Ambiguous requirements needing breakdown into tasks

#### Path A: Simple issue

Output: `Skipping architect — issue is straightforward. Implementing directly.`

Plan the implementation inline using the explorer's findings. Identify which files to create/modify and what changes to make.

#### Path B: Complex issue

Use the **Agent tool** with `subagent_type: devflow:code-architect` to design the implementation.

Pass it:
- The full GitHub issue content (title, body, labels)
- The explorer's distilled findings as inline context, prefixed with: "The code-explorer analyzed the current codebase and produced the following findings:"

The architect returns a focused blueprint (files to create/modify, component designs, data flows, build sequence). Hold this blueprint in your context — do NOT commit it (it is a temporary working artifact).

#### 2.2.4 Reuse & Altitude gate (mandatory, before the plan is written)

Two of the cleanup lenses that the Phase 3.2 `/simplify` pass would otherwise flag — **reuse** and **altitude** — are *design* decisions, far cheaper to make now than to refactor out of a finished diff. Apply both to the plan (from either path) before you write it to the workpad:

1. **Reuse.** For every piece of new code the plan proposes (a helper, a parser, a validator, a state shape, an API client), grep the shared/utility modules and the files adjacent to the change for something that already does the job. If it exists, the plan reuses the existing helper by `file:line` rather than re-implementing it. New code is justified only when no existing implementation fits — don't propose new code when a suitable one already exists.
2. **Altitude.** Check that each planned change sits at the right depth, not as a fragile bandaid. A pile of special cases layered on shared infrastructure is the signal that the fix isn't deep enough — prefer generalizing the underlying mechanism over stacking special cases. If the plan is reaching for a special-case patch, ask whether the shared mechanism should change instead, and re-aim the plan there.

Fold the result into the plan: name the helpers to reuse (with `file:line`) in the relevant plan steps, and pick the altitude before writing the steps. This is a planning gate, not a code edit — it changes *what you will write*, so it must precede the plan write below.

After planning (either path), write the plan steps as `- [ ]` checkboxes to a temp file, then `workpad.py update $ISSUE_NUMBER --replace-plan-file /tmp/plan-${ISSUE_NUMBER}.md`.

#### 2.2.5 Scope-Adjustment Rule (multi-PR issues)

If discovery and planning revealed that the issue's deliverables span more than fits in a single PR (e.g., a phased cleanup, a multi-stage migration, or any issue whose acceptance criteria explicitly enumerate work for several future PRs), **you must narrow the workpad's `## Acceptance Criteria` to only the items this PR will deliver** before continuing to 2.3. Otherwise the Phase 3.4 gate will reject your run for criteria that are out-of-scope by design, and the run will stop without ever reaching Phase 4.

Steps when scoping down:

1. Write the narrowed AC list (only in-scope checkboxes, verbatim) to a temp file, e.g. `/tmp/narrowed-acs-${ISSUE_NUMBER}.md`.
2. Apply the change atomically:
   ```bash
   workpad.py update $ISSUE_NUMBER \
       --replace-acs-file /tmp/narrowed-acs-${ISSUE_NUMBER}.md \
       --note "scope decision: {which subset this PR delivers}. Deferred (verbatim): {list}. Will be tracked in follow-up issue(s) filed in Phase 4.0."
   ```

This is not "inventing" criteria (forbidden by 1.4) — the deferred items are preserved verbatim in the workpad notes (`--note`) and carried forward by Phase 4.0.

If you are unsure whether to scope down, prefer a single fully-in-scope PR. Only re-scope when the issue body itself describes phased work or the diff would otherwise exceed reasonable PR size.

#### 2.2.6 AC-Plan reconciliation (rewrite surface details, never relax intent)

Some ACs name specific identifiers (job names, file paths, function names, command names). If the plan you settled on — or a later refactor in /simplify (3.2) or /devflow:review-and-fix (3.3) — uses different identifiers for the *same underlying behavior*, the literal AC text becomes stale and Phase 3.4 will reject a strictly-correct refactor. You may rewrite the affected AC in the workpad **only if** the rewritten text verifies the same observable outcome with the new identifiers; never relax what's verified.

Reconciliation steps:
```bash
workpad.py update $ISSUE_NUMBER \
    --rewrite-ac "{OLD AC substring}" "{NEW AC text}" \
    --note "AC rewrite: {old verbatim} → {new}. Motivated by: {structural change}"
```
`--rewrite-ac` preserves the box state (don't tick during the rewrite — Phase 3.4 will tick via `--tick-ac-n` later). This is **not** scope adjustment — the rewritten AC is still gated in 3.4.

**When the rewrite records a design *deviation* (the plan intentionally diverges from what an AC prescribed), also leave an in-repo breadcrumb comment at the deviation site.** The workpad `--note`/AC-rewrite paper trail lives only on the issue — and blinded shadow reviewers (Phase 3.3's fix loop deliberately withholds loop history) never see it, so a signed-off deviation gets independently re-raised as a finding, iteration after iteration (on #304 the signed-off AC11 deviation was re-litigated by three separate blinded reviewers, one grading the PR "not ready to merge" over it). To make the sign-off travel in repo content the reviewer *does* see, add a short comment at the deviating code site naming the **parent issue** and pointing at the **workpad record** — e.g. `# Deviates from issue #<N>'s prescribed <X>: <one-line why>; see the workpad AC-rewrite note.` — so the deviation reads as a recorded decision, not an undiscovered defect. (A pure surface-identifier rewrite with no behavioral deviation needs no such comment; this obligation is scoped to a *deviation*.)

If the rewrite would relax the AC (drop a guarantee, weaken a check, remove a verification surface), STOP — apply 2.2.5 (defer the AC to a follow-up issue) or revert the structural change instead.

### 2.3 Implement

`workpad.py update $ISSUE_NUMBER --status Implementing`.

Now implement the feature yourself. You have full context:
- The explorer's system understanding
- The architect's blueprint (if complex) or your own inline plan (if simple)
- The original issue requirements

**Test-first gate (mandatory when the change is testable).** Before you write implementation code, decide whether the change adds or alters behavior an automated test (unit or integration) can exercise — a function's return value, an API or CLI contract, an exit code, a parser's handling of an input shape, a state transition, a raised error, or an end-to-end path an integration test drives. If it does, write the test **first**, run it, and confirm it **fails for the right reason** (the behavior doesn't exist yet), then implement until it passes. This is the 2.1.5 reproduce-first gate generalized from bugs to features — but mind what 2.1.5 actually captured: its reproduction signal is **any one of** a failing test, a quoted error log, *or* a recorded shell command. Only when that signal **was a failing test** does it already satisfy this gate (don't write a second one). If 2.1.5 reproduced the bug with a non-test signal (a log or a shell command), there is no failing test yet, so this gate **still applies**: write the failing test now, before implementing the fix. A test added *after* the code, never seen to fail, encodes whatever the code happens to do rather than what the issue requires — write it first.

**Stub-blindness rule (when a test stubs an external boundary).** A stub matches on *some* properties of the request and ignores the rest — and everything the stub cannot see becomes a behavior your test can never exercise, so bugs in it surface one at a time as review findings across later iterations instead of being caught on day one (on #304 the gh stub matched any URL substring, so compare-operand order, `head_sha` query scoping, and fallback direction each escaped the stub and re-surfaced as pins c11/c13 and siblings across iterations 3–5). When a test stubs a boundary (a `gh`/HTTP stub, a mocked client, a fake filesystem), **enumerate the request/shape properties the stub ignores** — URL paths and query parameters, the *order* of compare operands, the *direction* of a default/fallback, headers, method — and **pin each ignored property as a static assertion in the same change** (a grep-pin on the source, an explicit equality assertion), so the stub's blind spots are covered by construction rather than discovered later. **Record the enumeration in the existing test-first `--note`.** Relatedly, a **declared-but-unused stub failure knob** — a failure-injection env var / flag the stub defines (`DRP_STATUS_FAIL`-style) that no test actually drives — is a pre-commit **smell**: it is mechanically detectable (grep the knob name; if it appears only in the stub definition, never in a test that sets it, it is dead) and must be resolved before commit (wire a test to it, or remove it), not left to a downstream reviewer.

**When the test you write IS a guard** (a drift/sync assertion, a coverage check, a regression test that pins a literal or contract), a green suite is necessary but **not sufficient** — a *vacuous* guard passes too. **Mutation-check any test guard you add here:** temporarily break what it pins (delete the line/block it asserts, flip the condition) and confirm the guard goes **RED**, then restore. This is the same discipline as the mutation-check rule in `skills/review-and-fix/SKILL.md` (Step 3), re-scoped to **any added or edited test guard in the diff** — so a guard authored as primary implementation work is covered here, not only a fix-loop deliverable. **Then confirm the guard registered:** a green suite is not evidence that a guard *ran*. After adding any guard, confirm its named assertion actually appears in the run as a PASS **and** that the suite's assertion count rose by what you added — green alone is necessary, not sufficient. A guard that silently no-ops (an assertion helper invoked before it is defined → command-not-found, a test file the runner never sources, a setup probe that returns success on failure) asserts nothing while the suite stays green, so a guard you never saw register as PASS may be protecting nothing.

**When the guard you add is a *behavioral-fix pin*** — an `assert_pin_unique` (or equivalent coverage pin) you add *specifically because* removing the pinned text would re-introduce a **named** bug or regression (a coupled-invariant pin, the operative qualifier of a sweep rule, a regression guard) — the mutation-check above has a sharper failure mode it must catch: **pin the operative sentence, not an adjacent framing clause.** The **operative sentence** is the minimal text that IS the behavioral fix — the text whose removal *alone* re-introduces the bug; a **framing clause** is a sentence that *describes or introduces* the fix but whose absence alone leaves the bug fixed. A framing-only pin stays GREEN on the exact targeted half-revert it was meant to catch (the recurring framing-only-pin sub-pattern behind PRs #62 and #173 — most precisely #173, where the framing clause was pinned but the operative qualifier was not; #62 was the sibling wrong-comparand variant of the same fail-open-guard class). So before committing such a pin: (a) **name the operative sentence** — the minimal text whose removal alone re-introduces the bug; (b) **confirm the pin literal targets that operative sentence**, not the framing clause around it; (c) **counterfactually half-revert** — delete *only* the operative sentence, leave every framing clause intact, and confirm the pin goes **RED**; and (d) **bake that half-revert into the suite — do not leave it a one-time manual act.** A half-revert you run once by hand proves the pin caught the regression *at authoring time* but protects nothing afterward; express the pin instead through **your framework's removal-proof assertion** (the assertion form that itself proves *PASS with the pinned text → FAIL without it*), so step (c) re-runs on every suite execution rather than relying on your memory of having done it once. **Record that operative-sentence commitment as an auditable note before writing the pin** — exactly like the 2.3 sweep-selection and test-first notes, log a one-line `workpad.py update $ISSUE_NUMBER --note` **naming the operative sentence and asserting the pin literal is a substring of it**, so a framing-only pin becomes a visible error a reviewer or the weekly retrospective can catch instead of a silent slip; the note is a per-pin commitment, so a diff that adds several behavioral-fix pins records one such note per pin. When the behavioral property needs several necessary sentences (e.g. the four-pin case in PR #173), use **at least one pin per operative sentence** — one pin on a multi-sentence property silently under-covers it. This sharper check applies **only** to behavioral-fix pins; it does **not** apply to pins on literal constants, token names, count-based guards, absence pins, or `RGOK_MARK` / `ECHO_TOK` token-rot guards, where no operative-vs-framing distinction exists and the plain mutation-check above suffices.

**When no automated test applies**, there is nothing to assert against: a change whose deliverable is prose, templates, config, or an embedded DSL (jq or shell inside Markdown, a `SKILL.md` procedure), or one with no observable behavior boundary. A change whose behavior emerges only from an end-to-end round trip is **not** this case — an integration test can drive it, so it takes the gate above. Skip the test and rely on the Phase 2.4 adversarial input-shape dry-trace instead — do **not** invent a parallel mechanism.

Record the call either way: `workpad.py update $ISSUE_NUMBER --note "test-first: {test path, fails→passes} | {no automated test: <reason>; dry-trace at 2.4}"`. Like the 2.3 sweep-selection note, this is an auditable commitment — a "no automated test" note on a change that plainly added a pure function, a new exit code, or a drivable end-to-end path is a visible error a reviewer or the weekly retrospective can catch, where a silent skip is not.

Write the code. Follow the patterns and conventions described in `CLAUDE.md`. As plan steps complete, tick them off: `workpad.py update $ISSUE_NUMBER --tick-plan "{substring of completed step}"`.

**Comment discipline (authoring rule).** An authored comment must state a constraint the code cannot show for itself — *why* a path fails closed, a cross-file producer/consumer contract, a portability trap, or the provenance of a non-obvious shape; these rationale, contract, portability, and provenance classes are load-bearing and stay. A comment that mirrors a fact the code already carries is not authored: the mirror-fact classes are an exact count, an enumerated list of sites or values, a scope word that restates a predicate, and narration of what the adjacent code does or what this change did — each is accurate the moment it is written and rots silently the moment a later change updates the code and not the comment. When a mirrorable fact genuinely earns prose, make it drift-proof rather than copying it: bind it to a test assertion added in the same change, state it as a lower bound instead of an exact count, or point at the defining symbol instead of copying its contents. A mirror-fact claim authored anyway is reconciled downstream by the 2.3.4a self-authored-claim reconciliation sweep — but authoring it drift-proof here is cheaper than reconciling it there.

**Sweep selection (run first).** The 2.3.x sweeps below are **not a flat checklist** — classify the diff and run the sweeps its shape warrants (**when in doubt, run them all**). Each sweep's heading states its own authoritative trigger; this list only tells you which to *consider*:

- **Deletes** code (a call site, branch, method, file, route, page, or asset) → run **2.3.1**, and **2.3.2** if it deletes a method/file/route/page.
- **Changes a contract** (a signature, a renamed/moved symbol, a tightened validator, or a routing/branch predicate) → run **2.3.0**.
- **Adds a rule that has peers** (a clause, guard, validator, or invariant that must hold at two or more co-equal sites for the rule to actually hold) → run **2.3.0a**.
- **Adds a value to an enumerated set** (a new enum/string-union member, status, kind, or verdict value — *or a member of a doc-enumerated configuration set: a workflow trigger list (the `on:` event set), a config-key set, a permissions list*) → run **2.3.0b**.
- **Always**, whatever the diff's shape → run **2.3.3** (convention), **2.3.4** (boundary-assumption), **2.3.4a** (self-authored-claim reconciliation), **2.3.5** (simplification & efficiency), **2.3.6** (error-handling & silent-failure).

This narrows *ceremony*, never *coverage*, and is **fail-safe**: each sweep's heading is authoritative, so if its trigger fires you run it even when this list didn't call it out — if the index ever drifts from a heading, the heading wins (drift can only add a sweep, never skip a warranted one). **The trigger shapes above are substrate-agnostic** — a contract, a peer-replicated rule, or an enumerated-set membership can live in prose / `SKILL.md` / doc / config just as much as in code (this repo's own coupled-invariant rule spans code mirror sites — a constant, a config-key name, a `SKILL.md` contract pin a `run.sh` grep asserts — as well as prose ones), so **classify by what the change replicates across sites, not by whether it is code**. An add-only diff that replicates nothing across sites typically runs just the five always-on sweeps — **but** an add-only prose/doc/config diff that adds a peer-replicated rule, a value to an enumerated set, or a contract literal mirrored elsewhere still trips the contract-completeness sweeps (**2.3.0** / **2.3.0a** / **2.3.0b**), not just the five. **Record the diff shape you classified and the sweeps you are running in a workpad `--note`** — the selection is then an auditable commitment a reviewer or the weekly retrospective can check, not a silent skip; a note reading "add-only" on a diff that in fact deleted a file is a visible error, where an unrecorded mental skip is not.

**Run each selected sweep after implementing and before running tests (Phase 2.4)** — that timing is the same for every sweep.

For the grep-based sweeps (**2.3.0**, **2.3.0a**, **2.3.0b**, **2.3.2**), don't merely attest you grepped: run the actual `git grep -n` / `grep -rnE` the sweep describes and record a **concise** result via `--note` (the match count plus "all intended", or the specific offending sites) — evidence, not a claim.

#### 2.3.0 Changed-contract sweep (mandatory whenever the change modifies a signature, renames/moves a symbol, tightens a validator, or changes a routing/branch predicate)

2.3.1–2.3.3 below all trigger on *deletion* or *addition*. Modifying a contract is just as blast-radius-prone, but it slips past `git diff` review because every dependent site still compiles — the call resolves, the fixture parses, the assertion runs — and is only *semantically* stale. After any change that modifies a signature, renames or moves a symbol, tightens a validator, or alters a predicate that classifies input, before running tests, grep the whole repo for every dependent site and bring each into line:

1. **All variants of a changed predicate.** If you changed a predicate that classifies input (e.g. a check for one specific status, type, or keyword), enumerate every value the predicate must now accept or reject and confirm every runner/branch routes them identically. A predicate fixed at one site but not its siblings is a defect in *this* PR, not a follow-up.
2. **Sibling call sites of a shared dependency.** If you wrapped or extended a shared object (e.g. added a per-request guard or a new error branch), grep for every caller that consumes that object and confirm each one plumbs the new inputs and handles the new branch — not just the site that motivated the change.
3. **Fixtures and assertions matching the old contract.** If you tightened a validator or moved output between streams (e.g. stdout↔stderr), grep tests for every fixture value and assertion that encoded the old contract — both in the files you touched *and* in shared `conftest.py` / helper modules — and update them. A fixture under a newly-stricter validator, or an assertion on a stream you rerouted, is a CI failure waiting for the next merge.

A modify / rename / reroute is not done until grepping for the old symbol, predicate value, stream, or contract returns only the intended sites.

**Re-run this sweep after any merge or rebase of the base branch** (the configured `base_branch`, not a hard-coded `main`)**.** A clean *textual* merge is not a clean *semantic* merge: the base branch may have added a fixture, call site, or assertion (often from a concurrently-merged PR) that your new contract now rejects, and git merges it cleanly without ever surfacing the conflict. After any `git merge` / `git pull --rebase` of the base branch the run performs (including the Error Handling conflict-recovery path), re-run steps 1–3 against the newly-arrived sites and treat any new site that violates the change's contract as a defect in *this* PR. See [`docs/implement-skill.md`](../../../docs/implement-skill.md) for why each Phase 2.3 sweep exists.

#### 2.3.0a Peer-checkpoint completeness sweep (mandatory whenever the change adds a rule/clause/guard/invariant that has co-equal peer sites)

2.3.0 catches a *modified* contract leaving its *dependent* sites (callers, fixtures) stale. This sweep catches the additive twin: you **add** a rule — a guard, a validator clause, a read-only precondition, a classification tripwire, a fallback — and state it at only *some* of the co-equal sites that must all carry it for the rule to actually hold. Each site reads correct in `git diff`, the happy path works, and the PR's own prose/CHANGELOG describes the rule as if it held everywhere — so the asymmetry ships clean and surfaces only as a `/devflow:review` REJECT or a human/post-bot patch. This is *not* caller→callee propagation (that is 2.3.0's job); a **peer set** is two or more sites that must each enforce the *same* rule independently (the four gate checkpoints of a skill step, the object/scalar/array branches of a config-leaf handler, the selection predicate *and* the parallel derivation that must agree on the same fallback). After adding any such rule, before running tests:

1. **Enumerate the peer set by grep, not from memory.** Pick the shared marker the peers have in common (the clause's keyword, the guarded variable, the predicate name, the step heading) and `git grep -n` it across the repo to list every site the rule must hold at. Working from memory is exactly how a peer gets missed.
2. **Apply the rule at every member — or record the exemption.** Add the clause/guard/branch at each enumerated site. If a peer is *deliberately* exempt, that is allowed, but the asymmetry must be recorded with a `--note` (which peer, why) — a *silent* one-sided rule is the defect; a *documented* one is a decision.
3. **Reconcile prose that overclaims the rule's breadth.** Grep the diff's own prose, CHANGELOG, and docs for any statement that describes the rule as universal ("every checkpoint", "all branches", "always"). Either make it true at every peer or narrow the prose to match reality — an overclaiming sentence on a half-applied rule is itself a defect.

The rule is not done until grepping the shared marker returns the rule present at every peer in the set (or an explicit `--note` for each exemption).

#### 2.3.0b Enum-enumeration reconciliation sweep (mandatory whenever the change adds a value to an enumerated value set — a code enum/string-union *or* a doc-enumerated configuration set)

**The "enumerated value set" is not only code-shaped.** A **doc-enumerated configuration set** counts too: a workflow's `on:` **trigger list** (adding a `check_suite` / `workflow_run` / `push` trigger), a **config-key set**, or a **permissions list** is an enumerated set that one or more docs also enumerate — so adding a member pulls the doc-mirror reconciliation below into Phase 2, not a later shadow pass. (On #304 the workflow's `on:` trigger set was enumerated by two docs; because the sweep read as code-enum-only it was classified n/a, and the contradicting doc mirrors survived to the iteration-2 shadow instead of being reconciled here.)


2.3.0a catches a rule added at only *some* of its co-equal peer sites. This sweep catches the sibling defect for a different shape of addition: you **add a value to an enumerated value set** — a new enum/string-union member, a status, a kind, a verdict, a `fix_decision` — update the code call-sites that branch on it, and leave a *doc/comment enumeration* of the value set, or a *fall-through consumer* (an `else` / `default` / `// null` arm that silently absorbs the new value), stale. The runtime can even be *correct* — the new value rides an intended fall-through — while a prose enumeration of the set and a `case`-less consumer go quietly out of date, surfacing only as a shadow-review finding or a human patch. "Consistent behavior" is not "reconciled enumeration." The 2.3.0 (changed-contract) and 2.3.0a (peer-checkpoint) sweeps grep *code* call-sites; this one explicitly adds the **doc/comment enumerations and fall-through consumers** they miss. After adding any value to an enumerated set, before running tests:

1. **Enumerate every site that names a member of the set, by grep — not from memory.** Grep the repo for the *existing* member literals of the value set (not just the new one): `git grep -n` each known value across code call-sites, jq/py/sh consumers, **doc/comment enumerations** (a prose list of the values, a docstring taxonomy, an inline `// one of: …` comment), **and fall-through consumers** (an `else` / `default` / `// null` arm whose behavior now depends on whether the new value should reach it). Working from the new value alone misses exactly the sites that enumerate the *old* set.
2. **Reconcile each site, or record an explicit exemption.** Add the new value to every enumeration meant to be exhaustive, and confirm every fall-through consumer treats the new value the way the design intends — verify the *intended* arm; do not assume the `else` is correct just because the suite is green. A site deliberately left out (a fall-through that *should* absorb the value) is allowed, but the exemption must be recorded with a `--note` (which site, why) — a *silent* stale enumeration is the defect; a *documented* one is a decision.
3. **Record the grep result as evidence.** Per the "Sweep selection" grep-evidence rule, record the match count plus "all reconciled" (or the specific stale sites you fixed) via `--note` — evidence, not a claim.

The addition is not done until grepping each member literal of the value set returns every enumerating site reconciled (or an explicit `--note` for each exemption).

#### 2.3.1 Orphaned-setup sweep (mandatory whenever the change deletes code)

Removing a call site, a UI block, a branch, or a whole function almost always strands the *setup lines* that fed it — a service-locator/dependency fetch, a query or record lookup, a computed local, an import or `use` clause — whose only consumer was the code you just deleted. These survive `git diff` review because nothing is *syntactically* broken; the line is simply dead. Reviewers keep flagging them as "optional cleanup", which means the PR shipped imperfect.

After every deletion, before running tests, do this sweep:

1. List the functions/methods/templates your diff removed lines from (`git diff --staged -U0` or `git diff -U0`).
2. For each one, re-read the **whole** surrounding function in its post-edit state.
3. Delete any local that is now assigned but never read, and any import / `use` clause / dependency declaration that lost its only consumer.
4. If something is *still* used elsewhere in the function, leave it; this sweep removes only genuinely-orphaned lines, never live ones — and never touch functions the diff didn't already modify.

Treat a leftover orphaned setup line as a defect in **this** PR, not a pre-existing-dead-code excuse — if the diff touched the function, the function leaves clean.

#### 2.3.2 Stranded-dependents sweep (mandatory whenever the change deletes a method, file, route, or page)

2.3.1 prunes dead lines *inside* the functions you touched. This sweep handles the inverse blast radius — the things *outside* your diff that the deletion stranded. When a removal/cleanup PR deletes its primary target, it routinely leaves dangling artifacts the deletion stripped of purpose: now-callerless public methods, leftover asset files, dead arguments still being passed to a callee that stopped reading them, and — worst — *surviving* pages, links, menu entries, or route references that still point at the code you just deleted (a guaranteed 404 / fatal for users).

After deleting any public method, class, file, page, route, endpoint, asset, or template, before running tests, do this sweep:

1. **Now-orphaned public surfaces.** For every public method or function you removed the *callers* of (not the function itself), and for every file/asset the just-deleted code was the sole consumer of: grep the whole repo for remaining references. Zero references → it is part of *this* removal; delete it too. (E.g. a public method left as a zombie with zero callers after its only caller was removed; an image/template asset left after its sole consumer was deleted.)
2. **Dead arguments to changed callees.** For every callee whose signature or body you changed so it stops reading some inputs: re-check each call site and stop passing the now-ignored arguments/keys. (E.g. a caller still passing several now-dead keys into a helper after the receiver stopped reading them.)
3. **Surviving inbound links and route refs.** For every page, route, endpoint, or file path you deleted: grep the repo for that path/URL/route name (links in templates, menu/nav configs, `href`s, redirects, route tables, sitemap entries). Every surviving reference is a regression — remove the link, or restore the target if it was deleted in error. (E.g. a navigation page still linking to a sub-page after that sub-page's source file was deleted → users hit a 404.)
4. **In-scope subtree completeness.** If the issue scopes a directory/feature subtree for removal, walk the *whole* subtree — do not stop at the files the obvious entry points reference. An untraversed leaf page that still calls the deleted integration is in scope by definition. (E.g. an orphan leaf file left in place still calling the deleted integration, linked from a surviving index page, despite sitting inside the in-scope subtree.)

Treat any stranded dependent as a defect in **this** PR. A deletion PR is not done until grepping for the deleted symbols/paths returns nothing but the deletion itself.

**Scope boundary with Phase 4.1 (*Update Documentation*).** This sweep covers references in *code, config, and routing tables* — i.e. things that break behavior at runtime if left dangling. Prose references to the deleted symbols/paths inside `docs/internal/` (descriptions, walkthroughs, "to install X, do Y") are **not** in scope here; they are handled by the Phase 4.1 documentation pass (`devflow:docs` subagent). If your grep turns up only docs hits, note them and move on — do not edit `docs/internal/` from this phase.

#### 2.3.3 Convention-compliance sweep on touched code (mandatory)

Same principle as 2.3.1, applied to `CLAUDE.md` conventions instead of dead code: **any function, method, query, or new file your diff added or modified lines in must conform to the conventions in `CLAUDE.md` when you leave it** — even if the violation was already there before you touched it, and even if "everything around it does it the same way." Recurring offenders that reviewers keep flagging as *Important* and that then ship anyway:

- A function signature left non-conforming after you edited it (e.g. argument shape, parameter style, return type) — whatever the project's CLAUDE.md mandates for function definitions in that language.
- A raw query/literal string in code you touched that violates the project's style rules (quoting, casing, identifier escaping) — whatever the project's CLAUDE.md mandates for embedded queries or literals.
- A new variable, method, file, or identifier you introduced that copies a legacy misspelling or non-conforming name from a sibling file — whatever the project's CLAUDE.md mandates for naming. "It matches the established convention across the existing code" is **not** a valid reason to propagate a misspelled or non-conforming name into new code; name the new thing correctly.

Do this sweep:

1. From `git diff --staged -U0` (or `git diff -U0`), list every function/method/query/new file your diff added or changed lines in.
2. Re-read each one in its post-edit state and check it against the rules in `CLAUDE.md` that apply to the languages and surfaces your diff touched.
3. Fix any violation in code the diff already touches. If fixing it cleanly is genuinely out of scope (it would balloon the diff into an unrelated refactor), say so explicitly in the workpad notes (`--note`) with the reason — do not leave it silent for `/devflow:review` to catch.
4. Do not reformat or rename code the diff didn't otherwise touch — this sweep covers only lines/functions/files your change already modified or introduced, never a repo-wide cleanup.

Treat a known convention violation in touched code as a defect in **this** PR, not a pre-existing-style excuse — if the diff touched it, it leaves `CLAUDE.md`-compliant.

#### 2.3.4 Boundary-assumption verification sweep (mandatory)

2.3.0–2.3.3 keep the diff internally consistent (contract changes propagated, no dead lines, no stranded dependents, no convention drift). This sweep targets a different defect class: a claim your diff *depends on* about something **outside the lines you wrote** that you asserted from memory instead of verifying against the source of truth. These ship clean — the code reads fine in `git diff` review, and they pass your own tests (because the tests encode the same wrong assumption) — so they only surface as a `/devflow:review` REJECT or a human post-merge patch. The cheapest place to catch them is here, before you commit.

A **boundary assumption** is any factual claim the diff relies on about something the diff does not own. The recurring kinds:

- **Dependency-version behavior** — a symbol, export, signature, or runtime behavior of a third-party package. Verify it against the **pinned range's** actual installed source/changelog, not the latest docs (e.g. importing a symbol that is only public in a version newer than your dependency pin permits, so an in-constraint install breaks at import).
- **Supported-runtime behavior** — a behavior of the language, standard library, or interpreter. Verify it holds across the project's **entire** documented supported-runtime range, not just the version in your hands.
- **Sibling-producer output** — the shape or content of data produced by another module your code consumes. Verify it by reading the **production producer**, not by assuming a field is populated (e.g. consuming a field that the producer hard-codes empty).
- **Real host/runtime environment** — a path, base URL, network namespace, or sandbox constraint of where the code actually runs. Verify against the **real host**, not the local dev shell (e.g. relative asset paths that resolve locally but 404 under the deployed base URL).

Do this sweep:

1. From `git diff --staged -U0` (or `git diff -U0`), list every claim the diff depends on that falls into one of the four kinds above. The diff is the *trigger* for finding which boundaries the change now relies on — a boundary's definition site (an unchanged import, a producer module, a version pin) usually sits in context `-U0` doesn't print, so follow each claim to its actual source. Purely-internal claims (a local you just wrote, a function defined in the same diff) are **out of scope** — this sweep is only about boundaries you don't own.
2. For each claim, verify it against the **actual source of truth** — the pinned version's installed source/changelog, the producer module, the documented supported-runtime range across *all* of it, the real host — never from memory.
3. **A test assertion about a boundary is itself an unverified claim.** A test that asserts a wrong boundary value still passes — it encodes the bug rather than catching it — so a green run at 2.4 is not confirmation. When the diff adds or changes a test that asserts a boundary value, verify that value against the same source of truth here.
4. If the code is wrong, fix it. If a boundary genuinely **cannot** be verified in-environment, do **not** assert it as true: always record the gap with `workpad.py update $ISSUE_NUMBER --reflection-kind note --reflection "unverified boundary: {claim} — needs {live env} to confirm"` so it is visible to review and the merger. If — and only if — a specific acceptance criterion's verification depends on that boundary, additionally retag that criterion `(post-merge)` (per Phase 1.2, via the Phase 3.4 `--rewrite-ac` retag pattern) so the 3.4 gate doesn't block on a live-only check. An unverifiable external *boundary* is exactly the genuinely-live runtime-environment case the Phase 3.4 gate permits a `(post-merge)` tag for; it is **not** the runnable-but-blocked tooling gap nor the self-claim confirmation that gate refuses (see §3.4). `(post-merge)` covers code that ships correct but can only be *verified* live — it is never a way to wave through a boundary you suspect is wrong (that is a blocker).

Treat an unverified boundary assumption as a defect in **this** PR, not a review-engine problem to be caught downstream — if the diff depends on it, verify it here or route it to `(post-merge)` with a reflection note.

**Workflow-diff addendum (mandatory whenever the diff touches `.github/workflows/`).** A workflow job is a boundary the generic sweep above under-covers in two specific ways — the token permissions it runs under and the artifacts its event paths leave on the head. Run both named checks over the diff, each with a workpad `--note` evidence obligation:

- **(a) Endpoint↔permission map.** Enumerate **every API call the diff adds to a workflow job** — each inline `gh api <endpoint>`, and each helper the job runs that itself calls `gh api` — and map each endpoint family to the token permission it requires (e.g. `check-runs` → `checks`, `commits/*/status` → `statuses`, `actions/runs` → `actions`, `issues/*/comments` → `issues`). Diff that required set against the job's own `permissions:` block; a call whose permission the job does not declare is a defect **in this PR** (it 403s at runtime — on #304 a missing `statuses: read` made a private-repo precondition permanently defer, and a missing `actions: read` did the same). Record the map (endpoint → permission → present/absent) in a `--note`. This check is backed by the deterministic `lib/test/run.sh` endpoint↔permission lint, but run the map by hand here too so a gap is caught before commit, not only in CI.
- **(b) Event-path artifact-lifecycle walkthrough.** For **each new or changed event path** the diff introduces, enumerate the artifacts that path leaves on the head — check runs, commit statuses, comments — **with their names and conclusions**. Then re-run **every reader of those artifacts in the same file** against that enumerated set and confirm each reader still resolves correctly for the new artifacts (a new check-run name or conclusion must not wedge an exactly-once counter, a status reader, or a dedupe filter — on #304 a deferral's `finalize_check` job check-run wedged the exactly-once gate exactly because the new artifact was not walked against its readers). Record the walkthrough — artifacts produced, readers re-checked — in a `--note`.

#### 2.3.4a Self-authored-claim reconciliation sweep (mandatory)

2.3.4 verifies the claims your diff *depends on* about boundaries it doesn't own (its inputs and preconditions). This sweep is its twin on the output side: it verifies the claims your diff *authors* — the behavioral assertions you wrote in prose — against what the shipped code actually does. The trigger is deliberately different, and that difference is the whole point: 2.3.4 starts from *the boundaries your code reads*; this sweep starts from *the prose your diff wrote*. 2.3.4 explicitly carves out claims about code defined in your own diff ("a function defined in the same diff is **out of scope**") — those are exactly the claims this sweep owns. A sentence in a doc you edited, or a comment you added, that contradicts the code path it describes ships clean: the prose reads plausibly, the code compiles, and your tests assert the prose's *intent* rather than the code's *actual behavior*, so the contradiction only surfaces as a `/devflow:review` finding or a post-merge patch. The cheapest place to catch it is here, before you commit.

A **self-authored claim** is any behavioral assertion the diff introduces about what the shipped code does. The surfaces, all in scope here:

- **Internal docs the diff adds or edits** (`docs/internal/…` and the like) — a described behavior, flow, "it does X then Y", or guarantee.
- **External docs the diff adds or edits** — the same, in customer-facing prose.
- **Code comments the diff adds or changes** — an inline claim about what the adjacent or called code does (e.g. "returns the deduped set", "never retries", "matches the reference query exactly").

(The **PR-body** claims are reconciled separately in **Phase 4.2**, where the body is authored — the body does not exist at commit time. This sweep covers every claim that *does* exist before commit.)

Do this sweep:

1. From `git diff --staged -U0` (or `git diff -U0`), list every behavioral claim the diff **adds or changes** in the three surfaces above. A claim is any sentence or clause asserting what the code *does* — not a TODO, a rationale, or a statement of intent that makes no factual behavioral assertion.
2. For each claim, trace the **actual shipped code path** it describes and confirm the code does what the prose says — **following dispatch into pre-existing code the diff calls but did not modify** (the claim's truth often resolves only downstream, in a helper your diff doesn't own). Unlike 2.3.4, a claim about code *defined in your own diff* is **in scope** here, not carved out — that blind spot is precisely what this sweep closes.
3. On any prose↔code divergence, **the code is the fact.** Resolve it one of two ways and never commit the unreconciled pair: either **fix the code** so the claim becomes true, or **rewrite the claim** so it states what the code actually does. Choosing one is mandatory — "note it and move on" is not an option for a contradiction you authored.
4. If fixing the *code* is genuinely out of scope for this PR (it would balloon the diff into an unrelated refactor), then **rewrite the claim** to the truth now — never leave false prose standing for `/devflow:review` to catch.
5. **Clean-path evidence.** For any step the diff adds that claims to *enumerate, verify, or scan* a set of things, confirm the step instructs its producer to log a summary (the count checked, the result) even on the clean path where nothing needs changing. A step worded "if all accurate, make no changes" with no trailing log is flagged: a silent no-op is indistinguishable from a step that never ran, so the human reviewing the run cannot tell it executed.
6. **Mirror-fact drift-proofing.** Every comment the diff adds or changes that carries an exact count, an enumerated list of sites or values, or a predicate-restating scope word is made drift-proof per the §2.3 treatments — rewritten or removed — before commit, **even when the comment is currently accurate.** A mirror-fact comment is true when written and rots only once a later change updates the code and not the comment, so this step fires on every diff whether or not the writer applied the §2.3 authoring rule — the accurate-today comment is exactly the one that ships and later goes stale.

Scope and discipline mirror the other 2.3.x sweeps: only the claims your diff added or changed are in scope — never a repo-wide doc/comment audit. Treat a self-authored claim that contradicts the shipped code as a defect in **this** PR, not a `doc-accuracy` finding to be caught downstream.

**When this run changed direction, the sweep extends past the diff.** If you **reverted, narrowed scope, removed a marker, or renamed a contract** after you or the issue already described the original intent, two surfaces hold a now-false description that the reverting commit's own `git diff` doesn't contain — so steps 1–2 above can't reach them. On a change of direction only, also reconcile:

- **The issue workpad** — a ticked AC or Plan step whose wording still describes the reverted approach. Rewrite it to the shipped reality via `workpad.py update` (`--rewrite-ac` / `--replace-plan-file` / re-tick).
- **Earlier-authored prose naming the changed contract** — comments, docstrings, and docs that asserted the old behavior with a contract word ("always", "never retries", "fail-closed", a removed/renamed key) in an earlier commit. Grep the touched files **and their callers** for those words; fix the ones that now misdescribe the code.

Record the reconciled surfaces — or an intentional verbatim carve-out, with the reason — in a `## Devflow Reflection` bullet.

#### 2.3.5 Simplification & Efficiency sweep (mandatory)

2.3.0–2.3.4a keep the diff correct, dead-line-free, convention-clean, and consistent with the claims it makes; the 2.2.4 gate already settled reuse and altitude at plan time. This sweep handles the two remaining cleanup lenses that only become visible once the code is *assembled*.

After implementing, before running tests, re-read every function your diff added or changed lines in (from `git diff --staged -U0` or `git diff -U0`) and apply both lenses:

1. **Simplification.** Flag and remove unnecessary complexity the diff *adds*: redundant or derivable state (a field that's always recomputable from another), copy-paste with slight variation (collapse to one parameterized form), needless deep nesting (flatten with early returns), and dead code the diff leaves behind. For each, write the simpler form that does the same job.
2. **Efficiency.** Flag and fix wasted work the diff *introduces*: redundant computation or repeated I/O inside a loop or hot path that could be hoisted or cached, independent operations run sequentially that could run together, and blocking work added to startup or a hot path. Reach for the cheaper alternative — but don't trade clarity for a micro-optimization that doesn't sit on a hot path.

Scope and discipline mirror the other 2.3.x sweeps: only touch functions/files the diff already added or changed lines in — never a repo-wide refactor. If a simplification is real but cleanly fixing it is genuinely out of scope (it would balloon the diff into an unrelated refactor), say so explicitly in the workpad notes (`--note`) with the reason rather than leaving it silent. Reuse and altitude are **not** re-litigated here — they were decided in 2.2.4; this sweep is only simplification and efficiency.

Treat avoidable added complexity or wasted work in touched code as a defect in **this** PR, not a `/simplify` problem to be caught downstream.

#### 2.3.6 Error-handling & silent-failure sweep (mandatory)

2.3.0–2.3.5 keep the diff correct, propagated, dead-line-free, and clean. This sweep targets the defect class the Phase 3.3 `silent-failure-hunter` review agent keeps surfacing: an error the code *handles* in a way that hides it — swallowed, over-broadly caught, masked by an unexplained fallback, or reported too vaguely to act on. These ship clean because the happy path works and the suite is green (the failure only fires on an input the tests don't exercise), so they survive `git diff` review and only surface as a Phase 3.3 finding or a production incident. The cheapest place to catch them is here, alongside the other always-on sweeps.

A **silent failure** is any error the code can hit that doesn't leave the caller, the user, or a log a true, actionable account of what went wrong. The recurring kinds, in this repo's idiom:

- **Swallowed error.** A `try/except` that catches and continues, a bash `... || true` / `cmd 2>/dev/null` / `|| echo ""` / unchecked `$?`, or a `jq`/parse step whose failure is discarded — leaving no breadcrumb, or (worse) printing/returning *success* for work that may not have happened. An empty `except:` / `catch {}` is the absolute form and is never acceptable.
- **Over-broad catch.** `except Exception:` / `except:` (or a bash trap) around more than the one operation whose specific failure you meant to handle, so an *unrelated* error — a typo'd name, a missing dependency, a `KeyboardInterrupt` — hides under the same handler. Catch the narrowest type around the smallest scope.
- **Unjustified or wrong-direction fallback.** Falling back to a default, the built-in config default, an alternate path, or empty output on failure without recording *that* it fell back and *why* — the reader can't tell a real empty result from a masked failure. A fallback that defaults an *error* to a success-shaped value (an API error read as "passing", a parse error read as "no criteria") is worse: it fails *open*. A fallback is allowed only as documented, intended behavior, it fails toward the safe side, and it still leaves a breadcrumb.
- **Misdirected or generic breadcrumb.** A best-effort path that *does* emit a message, but a generic one ("error", "failed") that points at the wrong cause — the silent-fail trap CLAUDE.md already calls out for `config-get.sh` / the jq consumers. The breadcrumb must name the *specific* shape that detonated.
- **Mock/stub leaking past tests.** Production code falling back to a fake/stub/hard-coded value when the real source is unavailable, outside test scaffolding.

**All-output-channels honesty (breadcrumb honesty is not scoped to stderr).** The honesty rule applies to **every** output channel a failure or condition drives — a stderr breadcrumb, a log line, a **machine-readable reason code**, and a **user-facing title or status string** alike. No channel may assert a state the code did not actually observe: if the code could not distinguish two conditions, none of its channels may name one as fact. An unverifiable condition is reported *as unverifiable* on every channel, not resolved to a plausible-but-unobserved cause on one of them. This is the gap a per-arm stderr breadcrumb passes while a coarser channel lies: on #304 every failure arm had a specific stderr breadcrumb (so the sweep, framed around stderr, passed), yet the machine-readable reason code driving the user-facing check title asserted `"branch behind base"` on an *API outage* — a state the code never observed. Check the reason code and the title/status string with the same rigor as the stderr line: each must name the specific observed cause, or report the condition as unverifiable.

Do this sweep:

1. From `git diff --staged -U0` (or `git diff -U0`), list every error-handling site the diff **added or changed**: each `try/except` / `catch`, each `|| true` / `|| echo` / `2>/dev/null` / `set +e`, each `$?` check or swallowed exit code, each fallback/default-on-failure, each `jq`/parse step that can fail, each optional-chaining / `// default` that can skip a failing op. If the diff added none, the sweep is a no-op — record that and move on.
2. For each site, confirm it does **not** silently fail: the failure is either propagated, or handled with (a) a breadcrumb naming the *specific* cause and (b) — for anything user- or caller-facing — an actionable account of what went wrong. A best-effort exit-0 path still leaves the **specific** breadcrumb, never a generic or misdirected one, and never prints success for work that didn't happen.
3. Narrow every broad catch to the specific type around the smallest scope. For each catch you keep, enumerate what unexpected errors it could swallow — if that list isn't empty, tighten it.
4. Justify every fallback: it must be documented/intended behavior, it must fail toward the safe side (never default an error to a success-shaped value), and it must leave a breadcrumb distinguishing a masked failure from a real empty result. Remove any production fallback to a mock/stub.
5. Fix any silent failure in touched code. If a handler is *genuinely* a best-effort absorber, make that intent explicit in a comment **and** keep its breadcrumb — don't leave it reading as an accidental swallow. If a fix is truly out of scope, say so in a `--note` with the reason rather than leaving it silent for `/devflow:review` to catch.
6. **Per-branch breadcrumbs on multi-branch no-op paths.** For any multi-branch no-op path the diff adds (e.g. "if A, stop; else find B; if B absent, stop"), confirm each branch emits a distinct diagnostic naming which condition fired. Two different no-op or failure modes that converge on one shared breadcrumb is flagged: the reader cannot tell which branch fired, so it is a variant of the misdirected/generic-breadcrumb kind above.

Scope and discipline mirror the other 2.3.x sweeps: only touch error-handling sites the diff already added or changed — never a repo-wide error-handling audit. Treat a silent failure in touched code as a defect in **this** PR, not a `silent-failure-hunter` finding to be caught downstream.

### 2.4 Test

Run the project's test and lint commands (check `CLAUDE.md` or `README`). Issue both Bash calls in a single assistant turn so they run in parallel.

- If **both pass** → proceed to committing.
- If **either fails** → fix the failing tests/lint errors yourself (you wrote the code, you have full context). Re-run the failing command(s) to verify.

**When the deliverable can't be exercised by a test, a green suite is not enough.** A change whose deliverable is prose, templates, config, or an embedded DSL (jq or shell inside Markdown, a SKILL.md procedure) is invisible to the test suite — passing tests say nothing about it. Match the verification to the deliverable: for a **logic-bearing** artifact (config, template, jq/shell-in-prose, **or inline jq inside a workflow file** — a parser just like a standalone consumer), enumerate an **adversarial input-shape matrix** — the `{object, array, scalar, valid-falsy (explicit false / 0 / empty string), missing, wrong-type}` shapes, i.e. the corrupt, empty, scalar-where-object-expected, valid-falsy (the `false`/`0`/`""` an `// true`/`// default` extraction silently coerces), and edge shapes — and statically dry-trace the logic against each; for **pure prose** (e.g. a reworded procedure), trace it against representative scenarios. Record the traces concisely in a workpad `--note`. (This is the same lesson the review engine's shape-sweep learned the expensive way — run it as your *opening* move on parser/best-effort code, not after three review iterations.)

### 2.5 Commit Implementation

For `bug`-labelled issues: confirm any temporary proof edits made in 2.1.5 have been reverted. Verify with `git diff HEAD` and `git diff --staged`. The working tree about to be committed must NOT include any stray `console.log`s, hardcoded payloads, or other proof-only edits.

Stage and commit all implementation changes:

```bash
git add -A
git commit -m "feat: implement issue #$ARGUMENTS — {short description from issue title}"
git push
```

If the commit includes test fixes, use a single commit combining implementation and fixes.

Then tick the implementation gate **and its parent phase** in the workpad: `workpad.py update $ISSUE_NUMBER --tick-progress "code + sweeps" --tick-progress "**Implement**"`.

**⚠ You are NOT done. Code is committed but not reviewed or documented. Proceed to Phase 3.**
