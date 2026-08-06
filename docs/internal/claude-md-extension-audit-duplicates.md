# AC4 duplicate list — CLAUDE.md ↔ live prompt-extension overlaps (issue #1352)

This is the **AC4 duplicate list**: every rule, fact, or contract present in BOTH `CLAUDE.md` AND at
least one **live** prompt extension under `.prflow/prompt-extensions/*.md`, **after** the placement
audit's edits. The overlap is **semantic** — the same rule restated at different lengths and in
different words, not a literal string match — so the list is derived by reading both inventories, not
by a text sweep.

AC4 is satisfied when every remaining overlap is **either** eliminated **or** listed here with a
stated reason it is a permitted exception. Both arms are used below, and each surviving row names its
evidence: a suite pin whose retirement the issue's Non-Goals put out of scope, or one of the placement
rule's own permitted-exception categories (a coupled mirror a test pins identical, a non-authoritative
`CLAUDE.md` summary paired with a canonical page, a command-specific *application* of a general rule,
or a vendored consumer-shipped body).

## Correction to the pre-edit revision of this artifact

The version of this file written by PR #1360 recommended, for the tiered suite-running policy, that
`CLAUDE.md` "shrink to the tier ladder + pointer" while "the operative per-run mechanics" stayed in
the extensions. **That recommendation was wrong on two counts and has not been followed.** It
contradicts the placement rule the same PR wrote — a tier-scoped rule is *not command-specific*, so
arm one sends it to `CLAUDE.md` in one copy and to no extension — and it contradicts AC6, which
forbids leaving a pointer behind. The issue body settles the direction explicitly ("Under arm one as
settled above, this content is **not command-specific**, so it lives in `CLAUDE.md` in one copy") and
predicts the shape of the result ("Expect `CLAUDE.md`'s share of the total to rise while the total
itself falls"). Issue #1264's measurement of the extension channel — the consumer prompt extension
reached the agent in 8 of 18 review runs and 1 of 4 sampled cloud implement runs — points the same
way: `CLAUDE.md` is loaded by the harness, and the extension is not.

## Measured outcome

Combined always-or-often-resident instruction surface (`CLAUDE.md` + the five substantial live
extensions), before and after this audit's edits:

| Surface | Before | After |
| --- | ---: | ---: |
| `CLAUDE.md` | 107,604 | 85,878 |
| `implement.md` | 70,992 | 18,308 |
| `review-and-fix.md` | 53,515 | 20,191 |
| `receiving-code-review.md` | 30,755 | 8,805 |
| `create-issue.md` | 22,624 | 21,726 |
| `review.md` | 11,013 | 7,973 |
| **combined** | **296,503** | **162,881** |

`CLAUDE.md` fell as well as the total, because the prose-rule compression of its own bullets exceeded
the ~13 KB of tier-scoped policy it absorbed from the extensions.

---

## Resolved — no longer present in both surfaces

### 1. Tiered suite-running policy (test selection, whole-suite gate, shard decomposition, launch recording)

Was a four-way near-copy: `CLAUDE.md`'s Commands bullet plus 77,055 B across the focused-test sections
of `implement.md`, `review-and-fix.md` and `receiving-code-review.md`. Now stated **once** in
`CLAUDE.md`'s Commands section (*Choosing the iteration test*, *The whole-suite gate*, *Recording a
whole-suite launch*). Each extension keeps only the binding its own command adds — implement's Phase
4.3 ownership and workpad sink, review-and-fix's caller split and standalone honesty floor,
receiving-code-review's local-tier form and record routing. The relocated mechanics and rationale live
unlinked in `docs/internal/claude-md-tiered-suite-rationale.md`.

### 2. Verification-flight scope ("only a whole-suite result discharges the completion gate")

Previously recorded **"No — not a permitted exception"**: `implement.md` declared itself the single
home and `CLAUDE.md` restated the gate inline. Now `CLAUDE.md` carries the single statement and
`implement.md` states only which gate owns it for an implement run (Phase 4.3, exactly once). No
restatement remains on either side.

### 3. Cloud allowlist / command-shape rules (leading token, denied composite shapes, two-denials)

The extensions carried the operative per-run forms as part of the tiered-policy copy. Those are gone;
the rules are in `CLAUDE.md` only. `create-issue.md` retains the `cloud-matcher-command-shapes` and
`cloud-allowlist-skew` **audit dimensions**, which are draft-audit criteria rather than restatements —
and both sit inside the AC6-exempt sections.

### 4. Local-tier classifier friction / "never ship an unverified assumption"

Previously **"Partial"**. `implement.md`'s *Verification under classifier friction* section (2,112 B)
is removed; its ordered steps — retry the authorized path, then the strongest reachable substitute
with a recorded residual gap, and never let a skipped verification read as a passed one — are now
stated once in `CLAUDE.md`'s classifier-fallback convention.

### 5. Structural-pin category set / wording-only pins prohibited

Previously **"the verbatim category-list copies are the duplicated surface"**. The closed set
(`helper-contract` … `cross-file-phase-contract`) is now enumerated only in `CLAUDE.md`'s
executable-evidence gotcha. `implement.md`, `review-and-fix.md` and `review.md` state their own
application — authoring, fix-time detection, review-time detection — and refer to that policy's closed
set without re-typing it.

### 6. Preflight-guaranteed tool set enumeration

Previously **"the restated tool-set enumeration is a coupled fact"**. `implement.md` no longer
enumerates the set; it states only that §2.3.6's un-guaranteed-tool guard class resolves against the
set `CLAUDE.md` states and `lib/preflight.sh`'s header declares.

**A stale claim was corrected in the same pass.** `implement.md` asserted that "`lib/test/run.sh` pins
the two, so renaming or removing a tool on either side turns the suite RED". That extension-side pin
(`w2-preflight-set-coupling`) was retired and appears only in the mutation-pin retirement manifest;
`run.sh:10205` asserts the `lib/preflight.sh` header alone. That assertion's own name still advertised
the retired pin and has been reworded.

### 7. Generated-artifact regeneration and merge-conflict classification

Not in the pre-edit list, but found during the pass: `Merge conflicts in generated artifacts` (3,254 B)
and `Batched artifact regeneration` were carried as near-copies by all three of `implement.md`,
`review-and-fix.md` and `receiving-code-review.md` — 18,769 B in total. Neither rule is
command-specific, so both are now stated once in `CLAUDE.md`. See the permitted-exception row below for
the fence `implement.md` retains.

---

## Permitted exceptions — present in both, with the reason

### P1. `implement.md`'s cloud focused-runner sentence, and its `regenerate-artifacts.py` fence

- **Overlap:** the mandated cloud direct-leading-token form, and the batched-regeneration invocation.
- **Reason (suite pin; retirement out of scope).** `lib/test/run.sh`'s `#591` assertion pins the
  literal `is the mandated invocation (the \`bash\`` in `implement.md`, and its `#1354 T2` pair asserts
  that dropping the `regenerate-artifacts.py` grant from a fixture config reports **that file's** head
  as ungranted — which requires a `regenerate-artifacts.py` fence to exist in `implement.md`. The
  issue's Non-Goals put pin retirement out of scope, and per the repo's two-PR sequencing rule a
  re-adjudication cannot share a branch with the sweep it authorizes.

### P2. `review-and-fix.md`'s three module-pinned sentences

- **Overlap:** the explicit local focused-selection command, the no-mechanical-routing rule, and
  `A nonempty skip tally is not clean.`
- **Reason (suite pin; retirement out of scope).** `lib/test/modules/review-and-fix-contract.sh` pins
  all three through its module-private `_raf_pin_unique` wrapper, plus the `#591` cloud-form sentence
  and the `#707` section heading that `receiving-code-review.md` defers to by verbatim text.

### P3. `receiving-code-review.md`'s focused-module opening sentence

- **Overlap:** the record-the-module-ID-first instruction.
- **Reason (suite pin; retirement out of scope).** Pinned in `lib/test/run.sh` as `RCR_PIN_MODULE`.

### P4. The six-shape adversarial matrix

- **Overlap:** the matrix set appears in `CLAUDE.md`'s best-effort-parser gotcha and in the
  config-derivation sections of both `review-and-fix.md` and `receiving-code-review.md`.
- **Reason (pinned coupled mirror + command-specific application).** The two extension copies are a
  self-declared, same-commit coupled mirror of each other, and all four carriers are pinned to one
  `$SIXSHAPE_SET` literal (`#312`/`#466`), never re-typed. The extension sections are the fix-time
  *application* of the general convention.

### P5. Writing-skills routing and its evidence marker

- **Overlap:** `CLAUDE.md` states the mandate, the autonomous-run divergence and the four-slot marker
  shape; `implement.md` is the producer contract; `review-and-fix.md` and `review.md` carry the
  byte-identical consumer gate.
- **Reason (non-authoritative summary + producer/consumer split + pinned lockstep).** `CLAUDE.md`
  self-declares its slot statement non-authoritative and names the canonical producer and consumer.
  `run.sh`'s `#506` block pins the trigger-glob list and the marker literal in lockstep across the
  three files and asserts the two gate copies byte-identical, so the copies cannot silently diverge.

### P6. "Unknown is not zero", named rather than restated

- **Overlap:** `CLAUDE.md` states the rule; the two review extensions' gate text cites it by name when
  handling an absent disposition slot.
- **Reason (named pointer applied to a command-specific gate).** The extension text does not restate
  the rule — it names it and applies it to one gate's decision.

### P7. Command-specific applications of general `CLAUDE.md` rules

- **Overlap:** `review-and-fix.md`'s guard-class shapes (the non-preflight-PATH-tool rule as a
  review-detection shape) and `create-issue.md`'s audit dimensions and evidence axes (the coupled-mirror
  discipline, the `#553` self-referential-count class, the grant-timing bootstrap, the
  executable-evidence rule, the preflight tool set) as draft-audit criteria.
- **Reason (command-specific application).** Each is the rule *applied* to one command's decision
  procedure rather than a second statement of it. The `create-issue.md` instances additionally sit
  inside the two AC6-exempt sections (`## Audit dimensions`, `## Evidence axes`), which are forwarded
  verbatim into every dispatched auditor's prompt by two independent extractors and are verified
  byte-identical to their pre-edit bytes.

### P8. Non-authoritative `CLAUDE.md` summaries paired with a canonical page

- **Overlap:** the working-directory contract, the Phase 2 durability checkpoint, the retrospective
  filing-key record, and the review-verdict marker each carry a short `CLAUDE.md` summary alongside a
  canonical `docs/` page.
- **Reason (explicit permitted-exception category).** Each summary labels itself non-authoritative and
  names its canonical page, so the two cannot be read as competing statements. These are
  `CLAUDE.md`↔`docs/` pairs rather than `CLAUDE.md`↔extension pairs, and are listed only so a reader
  does not mistake them for unlisted duplication.
