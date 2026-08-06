# AC4 duplicate list — CLAUDE.md ↔ live prompt-extension overlaps (issue #1352)

This is the **AC4 duplicate list** for the issue #1352 repo audit: every rule, fact, or contract
that is present in BOTH `CLAUDE.md` AND at least one **live** prompt extension under
`.prflow/prompt-extensions/*.md` (implement, review, review-and-fix, receiving-code-review,
create-issue — the `.md` files, not the `.md.example` scaffolds). The overlap is **semantic**: the
same rule restated at different lengths and in different words, not a literal string match. Each
entry records where the rule appears in CLAUDE.md, where it appears in each extension, the
recommended allocation under the adopted placement rule (a rule **not** tied to one command —
including **tier-scoped** content — lives in CLAUDE.md only; a rule specific to **one command's**
runs lives in that command's extension only; nothing in both), and whether the overlap is a
**permitted exception** (a self-declared coupled mirror that a test pins, a vendored
consumer-shipped body, or a CLAUDE.md non-authoritative summary that already carries a pointer).

The placement-rule reading applied throughout: a **tier-scoped** rule (local / cloud-implement /
cloud-review behaviour that is not about one command) is "not command-specific" and its home is
CLAUDE.md. An **application** of a general rule inside one command's flow (a review-detection
shape, an implement authoring step, a create-issue draft-audit axis) is legitimately
command-specific and belongs in that extension — but where it *restates* the general rule rather
than pointing at it, the restatement is the duplicated surface and should become a pointer.

---

## 1. Tiered suite-running policy (the "which tier / run the suite" operative statement)

- **CLAUDE.md:** the ~4.1KB Commands-section bullet "**Running the suite when the `bash <path>`
  wrapper above is denied — the tier matters**" (tiers 1–3, focused-first, the parallel
  coordinator, the single-turn push+verify mandate). It explicitly concedes: "The operative
  statement of this policy lives in the three prompt extensions
  (`.prflow/prompt-extensions/{implement,review-and-fix,receiving-code-review}.md`) — this bullet is
  their coupled mirror, and the two are edited together."
- **implement.md:** the whole "Focused test modules are the iteration default" → "Verification-flight
  scope — the single statement" → "The final full-suite command is the parallel coordinator" →
  shard-decomposition (#1132) → "Every tier that maintains a workpad … Verification evidence" run of
  sections (lines ~155–222).
- **review-and-fix.md:** "Focused test modules are the fix-iteration default" through the
  Verification-evidence-marker sections (lines ~47–90).
- **receiving-code-review.md:** "Focused test modules in direct reception passes" through its
  Verification-evidence section (lines ~134–153).
- **Recommended allocation:** **Tier-scoped → CLAUDE.md is the correct single home for the
  *principle*.** In practice the operative detail is a self-declared **three-way coupled mirror**
  across the extensions (each carries a real copy because each extension is loaded independently and
  a pointer would not resolve for its reader), and CLAUDE.md is the fourth mirror. This is the
  largest and highest-value consolidation target: shrink the CLAUDE.md bullet to the tier ladder +
  pointer, and keep the operative per-run mechanics in the extensions.
- **Permitted exception?** Partially. The three-way extension copy is a **pinned coupled mirror**
  (authoring comments in each file mandate same-commit reconciliation) — permitted among the
  extensions. CLAUDE.md's copy is *declared* a coupled mirror too, but under the placement rule it
  should degrade to a tier-ladder + pointer rather than re-state the operative mechanics.

## 2. Verification-flight scope ("only a whole-suite result discharges the Phase 4.3 gate")

- **CLAUDE.md:** inside the tiered-runner bullet — "an intermediate commit or push iterates on the
  focused test … the full suite … is the completion gate."
- **implement.md:** "**Verification-flight scope — the single statement.**" — which *declares itself
  the one home*: "This sentence is that rule's one home; every other mention of the scope — later in
  this file, in `skills/implement/phases/phase-4-documentation.md`, and in `CLAUDE.md`'s
  tiered-runner bullet — points here rather than restating it."
- **review-and-fix.md / receiving-code-review.md:** the "A focused result discharges intermediate
  iteration only, never the final gate" sentences.
- **Recommended allocation:** **implement.md is the declared single-source home** (Phase 4.3 is
  implement-specific). CLAUDE.md should carry only a pointer, not a restatement — it currently
  restates the gate inline inside the tiered bullet.
- **Permitted exception?** No — this one is explicitly *supposed* to be single-sourced in
  implement.md, so the CLAUDE.md inline restatement is a drift risk to convert to a pointer.

## 3. "Unknown is not zero"

- **CLAUDE.md:** the dedicated gotcha "**Unknown is not zero — never collapse an unestablished
  measurement onto a real value**" (`permission_denials_count` / `describe-denial-count.sh`), and a
  second application inside the `Verification evidence` marker discussion ("*unknown is not zero*,
  applied to attestation").
- **review.md:** "this repo's *unknown is not zero* rule forbids collapsing it onto either value"
  (Writing-skills slot-absent handling).
- **review-and-fix.md:** byte-identical twin of that sentence.
- **implement.md:** the batched-regeneration sections apply it without the name ("an unchecked
  artifact is **unknown, not clean**"; "unestablished … is never an empty one").
- **Recommended allocation:** **Not command-specific → CLAUDE.md keeps the rule.** The
  review/review-and-fix mentions are already **pointers by name** ("this repo's *unknown is not
  zero* rule") applied to a command-specific gate — permitted.
- **Permitted exception?** Yes — extension mentions are named pointers, not restatements.

## 4. Non-preflight-PATH-tool selection guard

- **CLAUDE.md:** the gotcha "**A value that decides a SELECTION or an EMITTED result must not be
  derived through a non-preflight PATH tool**" (and again inside the reviewer-denylist gotcha, "never
  `tr`, which is a non-preflight PATH tool the SELECTION must not depend on").
- **implement.md:** "**The project's preflight-guaranteed tool set**" section — the concrete
  instantiation (`git`/`gh`/`jq`/`python3`/PyYAML guaranteed; `tr`/`sed`/`awk`/`cut`/`wc`/`head` not).
- **review-and-fix.md:** "**Guard-class shape 2 — tr-dependence**" (review-detection shape).
- **receiving-code-review.md:** carried transitively via the shared shapes it points to.
- **create-issue.md:** the `non-preflight-path-tool-selection-hazards` audit dimension.
- **Recommended allocation:** **Not command-specific → CLAUDE.md is the rule home.** The extensions
  are legitimate command-specific *applications* (implement = authoring instantiation of the tool
  set; review-and-fix = a detection shape; create-issue = a draft-audit axis). Each restates enough
  of the rule to be a partial duplicate; prefer trimming each to the decision + a pointer.
- **Permitted exception?** Applications are permitted, but the restated tool-set enumeration is a
  coupled fact (implement.md already declares its enumeration a coupled mirror of
  `lib/preflight.sh`'s header, pinned by `run.sh`).

## 5. Config-shape six-shape adversarial matrix

- **CLAUDE.md:** the gotcha "**Editing a best-effort parser … lead with an adversarial input-shape
  matrix**" — `{object, array, scalar, valid-falsy, missing, wrong-type}`, valid-falsy load-bearing.
- **review-and-fix.md:** "**Config-derivation fixes sweep the full six-shape adversarial matrix**" —
  which states "the governing convention is CLAUDE.md's best-effort-parser adversarial-matrix
  gotcha, and this section is its coupled mirror in
  `.prflow/prompt-extensions/receiving-code-review.md` — edit both in the same change."
- **receiving-code-review.md:** the byte-identical coupled-mirror twin of that section.
- **create-issue.md:** the `authoring-discipline-defects-devflow` dimension references "**CLAUDE.md's
  six-shape adversarial matrix**" as an audit criterion (pointer form).
- **Recommended allocation:** **Not command-specific (the matrix itself) → CLAUDE.md home.** The
  review-and-fix ↔ receiving-code-review pair is a self-declared coupled mirror (fix-time
  application); create-issue points by name.
- **Permitted exception?** Yes — the two review-side copies are a self-declared, same-commit coupled
  mirror; create-issue is a named pointer.

## 6. Writing-skills / prompt-surface edit routing evidence contract

- **CLAUDE.md:** the "Editing any skill file (`SKILL.md`)? ALWAYS invoke `writing-skills`"
  convention, the autonomous `/prflow:implement` carve-out, and the "marker has a stated shape
  (#1171)" bullet with the four slots — which states "Canonical statement of the slots:
  `.prflow/prompt-extensions/implement.md`'s evidence contract (producer) and the two review
  extensions' byte-identical gate (consumer) — this summary is non-authoritative."
- **implement.md:** "**Prompt-surface edit routing**" — the producer: routing rule, repair arm,
  fallback clause, evidence contract, the four-slot table.
- **review-and-fix.md / review.md:** "**Prompt-surface edit routing evidence gate**" — the consumer
  gate; the two are declared byte-identical twins ("Edit both copies in the same change").
- **Recommended allocation:** producer half → **implement.md** (implement-specific authoring flow);
  consumer half → **review.md + review-and-fix.md** (review-specific gate). CLAUDE.md is already a
  **non-authoritative summary + pointer**.
- **Permitted exception?** Yes — CLAUDE.md self-declares non-authoritative; the review twin pair is a
  declared coupled mirror.

## 7. Structural-pin category set / wording-only pins prohibited (executable evidence)

- **CLAUDE.md:** the gotcha "**Guard executable behavior and machine-consumed contracts, never prose
  presence** (#375/#666/#810)" with the closed `# structural-pin-ok:` category set.
- **implement.md:** "**Behavioral regressions — executable evidence, not attestation**" +
  "**Wording-only pins are prohibited**" — restates the closed category set verbatim.
- **review-and-fix.md / review.md:** "**Wording-only pin review policy**" — restates the same closed
  category set verbatim (review-detection application).
- **create-issue.md:** the `executable-evidence-for-behavioral-regressions` audit dimension.
- **Recommended allocation:** **Not command-specific → CLAUDE.md is the rule home.** The category
  **list** is duplicated verbatim in three extensions — a coupled vocabulary that should ideally be
  single-sourced (or pinned) rather than re-typed. The surrounding policy is a legitimate
  per-command application (authoring vs. detection vs. draft-audit).
- **Permitted exception?** The applications are permitted; the verbatim category-list copies are the
  duplicated surface (schema-config-vocabulary — a candidate for a pin).

## 8. Cloud allowlist / command-shape rules (leading token, denied composite shapes, two-denials)

- **CLAUDE.md:** the gotchas "**Cloud allowlists & command shapes**", "**Cloud allowlist needs the
  helper as the command's LEADING token**", and the "two denials → switch, never iterate variants"
  discipline.
- **implement.md:** the direct-leading-token / deny-floored `bash <path>` wording throughout the
  focused-test and coordinator sections, the "**Repo-specific command names**" relocation section,
  and the issue-401 two-denials discipline in the batched-regeneration section.
- **review-and-fix.md / receiving-code-review.md:** the same leading-token + two-denials wording in
  their coordinator and batched-regeneration sections.
- **create-issue.md:** the `cloud-matcher-command-shapes` and `cloud-allowlist-skew` audit
  dimensions.
- **Recommended allocation:** **Tier-scoped → CLAUDE.md is the rule home.** Extensions carry the
  operative per-run forms (part of the #1 tiered-policy mirror); create-issue carries draft-audit
  axes. Trim extension restatements to the operative form + pointer.
- **Permitted exception?** The operative forms travel with the #1 coupled mirror; create-issue axes
  are command-specific applications.

## 9. Grant-timing bootstrap (trigger-time-resolved config is in-PR-inert / post-merge-only)

- **CLAUDE.md:** the gotcha "**Trigger-time-resolved config is post-merge-only — the grant-timing
  bootstrap (#593)**", which names its "**Semantic (not literal) mirror sites**": the create-issue
  extension's Grant-timing axis, `docs/internal/cloud-setup.md`, and `docs/internal/implement-skill.md`.
- **implement.md / review-and-fix.md / receiving-code-review.md:** the "**Grant-timing caveat**"
  paragraphs beside the `run-parallel.sh` coordinator ("a grant the PR itself ships is inert in that
  PR's own run").
- **create-issue.md:** the "**Grant-timing bootstrap**" evidence axis, which create-issue's own
  authoring-discipline dimension calls "that file's single statement of which state is
  trigger-time-resolved vs runtime-live (read it there; do not restate it)".
- **Recommended allocation:** **Not command-specific → CLAUDE.md is the rule home** (it already lists
  the mirror sites). create-issue's axis is a self-declared single statement for the *draft-audit*
  application; the three coordinator caveats are tier-scoped operative forms.
- **Permitted exception?** Yes — CLAUDE.md explicitly registers these as semantic mirror sites to
  reconcile together.

## 10. Local-tier classifier friction / "never ship an unverified assumption"

- **CLAUDE.md:** the gotcha "**Local-tier classifier blocks shell-script invocation — this is
  expected; use the documented fallbacks**", plus "**A denied bash wrapper does not mean the suite
  cannot run here**" and the "**unverified-assumption** bug class" gotcha ("Adding a guard … trace
  every operand back to its producer").
- **implement.md:** "**Verification under classifier friction — never ship an unverified
  assumption**" (retry authorized path → strongest substitute + reflection → never let skipped read
  as passed).
- **Recommended allocation:** **Tier-scoped → CLAUDE.md is the rule home.** implement.md's section is
  the operative in-run form; it overlaps the CLAUDE.md fallback gotcha and the evidence-before-
  assertion principle. Prefer trimming to the ordered steps + pointer.
- **Permitted exception?** Partial — the operative ordered steps are command-flow; the "evidence
  before assertion" principle is a general rule better cited than re-stated.

## 11. Coupled-mirror / single-source discipline + "never git grep sub-command"

- **CLAUDE.md:** the convention "**Single-source-of-truth is the default … the coupled-invariant
  discipline governs the copies that still exist**", including the "**never** git's own `grep`
  sub-command" and whitespace-normalized-search instructions.
- **create-issue.md:** the `coupled-mirror-sites` audit dimension ("Enumerate mirrors with a
  **whitespace-normalized** search … defeats line-based `git grep`") and the "The `lib/test/run.sh`
  pin corpus" evidence axis.
- **Recommended allocation:** **Not command-specific → CLAUDE.md is the rule home.** create-issue's
  dimension is a draft-audit application of the same discipline.
- **Permitted exception?** Yes — command-specific audit axis; keep as application, prefer pointer for
  the mechanics.

## 12. Self-referential count/ordinal rot (#553)

- **CLAUDE.md:** the gotcha "**A self-referential ordinal count in a `lib/test/run.sh` comment rots
  on your OWN edit (PR #553 REJECT)**".
- **create-issue.md:** `authoring-discipline-defects-devflow` sub-point (5) — "a **self-referential
  count or ordinal** … referring to its own mutable content … (the #553 rot class)".
- **Recommended allocation:** **Not command-specific → CLAUDE.md home.** create-issue is a
  draft-audit application (pointer already present via "#553 rot class").
- **Permitted exception?** Yes — command-specific audit axis.

## 13. Preflight-guaranteed tool set enumeration (git/gh/jq/python3/PyYAML)

- **CLAUDE.md:** stated in the preflight command comment and the config-read gotcha ("python3 is a
  hard preflight prerequisite … PyYAML is required only because …").
- **implement.md:** "The project's preflight-guaranteed tool set" — the enumeration, declared a
  "coupled mirror of that [`lib/preflight.sh`] header".
- **create-issue.md:** repeated in two audit dimensions ("only `git`/`gh`/`jq`/`python3`/PyYAML are
  guaranteed").
- **Recommended allocation:** **Not command-specific → CLAUDE.md / `lib/preflight.sh` header is the
  source.** The enumeration is a coupled fact; implement.md declares itself a mirror pinned by
  `run.sh`. create-issue restates it inside audit axes.
- **Permitted exception?** Yes — the mirror is pinned; create-issue restatements are audit-axis
  applications (candidate for pointer).

---

## Summary of dispositions

- **Consolidate to CLAUDE.md (trim extension restatement to pointer):** #2 (verification-flight
  scope — implement.md is the declared home, CLAUDE.md should point), and the *inline restatements*
  inside #1/#8/#10 that duplicate tier-scoped rules.
- **Keep the rule in CLAUDE.md; extension mentions are already/should be pointers or command-specific
  applications:** #3, #4, #5, #7, #9, #11, #12, #13.
- **Producer/consumer split already correct, CLAUDE.md non-authoritative summary:** #6.
- **Self-declared coupled mirrors that a test pins (permitted, but still true duplicates to
  reconcile together):** the three-way extension mirror in #1, the review-and-fix ↔
  receiving-code-review pair in #5, the review ↔ review-and-fix twin gate in #6/#7.

The single highest-value cleanup is #1: the CLAUDE.md tiered-runner bullet should shrink to the tier
ladder plus a pointer to the three extensions, since it already concedes the operative statement
lives there.
