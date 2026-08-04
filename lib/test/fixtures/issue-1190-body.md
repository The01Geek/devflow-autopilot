## Problem Statement

Every file under `skills/**` is installed **verbatim** into a third-party consumer repository. `.github/actions/vendor-plugin/vendor-slice.sh`'s `devflow_copy_slice()` copies `skills` (and `agents`) into the vendored plugin at `.prflow/vendor/prflow/`, and the shipped prompt bodies are read by the runtime agent in that consumer's tree.

**26 lines across 13 first-party skill files reference PRFlow's own internal `docs/` tree.** Those references are unresolvable for a consumer reader in the ordinary case: a shipped skill sentence that says *"see `docs/cloud-setup.md`"* names a path that does not exist in the consumer's repository, and — where the doc *is* vendored — points at PRFlow's maintainer documentation rather than anything about the consumer's project.

This is not a cosmetic wart. **It is the whole reason the vendor slice ships `docs/` at all.** `devflow_copy_slice()` copies `"$src/docs"` wholesale and then prunes only two subtrees, with the reason stated in its own comment:

> Prune subtrees no consumer run reaches (issue #677): the published GitHub Pages HTML under docs/site and the Mintlify source under docs/external (both are standalone published sites no shipped skill links to — **the rest of docs/ stays, since shipped skill bodies link into it**), and PRFlow's own test suite under lib/test.

So the 26 references are the sole justification for shipping the maintainer documentation tree into every consumer. Remove them and the justification is gone.

**Each reference is a defect to remove or rework — not a path to update.** Rewriting `docs/x.md` to `docs/internal/x.md` inside a `skills/**` body does **not** discharge this work and is itself a defect: it preserves the unresolvable pointer and merely re-spells it.

## Evidence

All figures measured on `origin/main` at `b3c53d40`. Re-measure rather than trusting them.

### The measurement command

The doc-name set is **derived from the tree**, never transcribed — a hardcoded list rots the moment a doc is added:

```bash
NAMES=$(git ls-files 'docs/*' \
  | grep -vE '^docs/(external|site|superpowers|evidence)/' \
  | sed 's|^docs/||; s|[.]|[.]|g' | tr '\n' '|' | sed 's/|$//')
git grep -nE "docs/($NAMES)" -- skills/ agents/
```

`docs/external` and `docs/site` are excluded because the slice prunes them (they are not internal docs, and `docs/external` is the published public site). `docs/superpowers` and `docs/evidence` are excluded because they are gitignored working trees that never ship.

### The numbers

| Quantity | Measured |
|---|---|
| Total reference lines under `skills/` | **26** |
| Distinct files under `skills/` | **13** |
| Reference lines under `agents/` | **0** |
| Distinct internal documents referenced | **10** |
| Lines that are relative Markdown links (`](../../docs/…)`) | **12**, across **10** files |
| Lines that are bare prose mentions with no link | **14**, across **8** files |

Five files carry both kinds, which is why 10 + 8 exceeds 13.

Split commands (piping the measurement output):

```bash
# link lines
... | grep -E '\]\((\.\./)*docs/'
# prose lines
... | grep -vE '\]\((\.\./)*docs/'
```

**Neither vendored skill is in the population.** `skills/receiving-code-review/` and `skills/requesting-code-review/` — the two skills vendored from `superpowers`, already governed by the repo-agnostic rule in `CLAUDE.md` — carry **zero** references. Every one of the 13 files is a PRFlow first-party skill, and first-party skills ship into consumers on exactly the same terms.

**`agents/` is clean and must stay clean.** The only near-hit, `agents/checklist-generator.md` line 122, is `docs/architecture.md` inside an illustrative checklist item — a generic example of a consumer's own doc, not a PRFlow document. It is correctly outside the population.

### The full enumeration

Grouped by file. **L** = relative Markdown link. **P** = bare prose mention.

---

**1. `skills/create-issue/SKILL.md` — 2 lines, both L → `docs/create-issue-context.md`**

- **L89 (L)** — closes the *Evidence artifact* paragraph. The rule is "reference the resident findings by pointer; do not re-quote the findings block", and the link is offered as the justification: *"(re-emitting already-resident content only inflates the run's runtime main-thread context with no gain — see [`docs/create-issue-context.md`](../../docs/create-issue-context.md))"*.
- **L103 (L)** — the same rule restated for Step 3 drafting, with the same doc as a bare parenthetical citation.

**2. `skills/create-issue/references/step-3-6-audit.md` — 4 lines (2 L, 2 P)**

- **L212 (P)** → `docs/create-issue-context.md`. Inside the *Dimension-list growth policy*: *"text the orchestrator holds in its runtime main-thread context on every turn of a long multi-round run (the axis `docs/create-issue-context.md` owns and measures)"*. The doc is named as the **owner of a measurement axis** — the sentence's authority rests on it.
- **L278 (L)** → `docs/create-issue-context.md`. *Runtime-context discipline*, same by-pointer rule, same citation.
- **L294 (L)** → `docs/advisory-adjudication-calibration.md`. *"the tool cannot observe chat, a self-attestation residual named in [`docs/advisory-adjudication-calibration.md`](../../../docs/advisory-adjudication-calibration.md)"*.
- **L312 (P)** → `docs/DEVFLOW_SYSTEM_OVERVIEW.md`. The strongest dependency in the population: *"`docs/DEVFLOW_SYSTEM_OVERVIEW.md` §11 carries and is canonical for this system contract … this rule is the operational form the batching caller follows, not a restatement of it."* The prose **declares itself non-authoritative** and delegates canon to a document the consumer's runtime agent has no reason to be able to read.

**3. `skills/create-issue/references/step-4-present-create.md` — 1 line (L)**

- **L18 (L)** → `docs/advisory-adjudication-calibration.md`, the same self-attestation-residual citation as step-3-6-audit L294.

**4. `skills/implement/SKILL.md` — 2 lines (1 P, 1 L)**

- **L40 (P)** → `docs/cloud-allowlist.md`. Inside the cloud helper-invocation form: *"whether a consumer's absolute form is granted is unestablished, see `docs/cloud-allowlist.md`'s evidence table"*. The doc carries the **epistemic status** of a claim the shipped rule depends on.
- **L54 (L)** → `docs/working-directory-contract.md`, as *"Canonical statement"* of the working-directory contract.

**5. `skills/implement/phases/phase-1-setup.md` — 1 line (L)**

- **L507 (L)** → `docs/implement-skill.md`. *"The full statement of the threat model lives in [`docs/implement-skill.md`](../../../docs/implement-skill.md)'s* Two provenance sources for ahead history *section; the bullets below are its coupled operative summary — edit the two together."* Names both a **section title** and a **coupled-edit obligation** that a consumer cannot act on.

**6. `skills/implement/phases/phase-2-implement.md` — 1 line (L)**

- **L272 (L)** → `docs/implement-skill.md`, *"for why each Phase 2.3 sweep exists"*.

**7. `skills/implement/phases/phase-4-documentation.md` — 3 lines (2 P, 1 L)**

- **L418 (P)** → `docs/DEVFLOW_SYSTEM_OVERVIEW.md`. **A distinct case**: the path is an *illustrative example filename* in the basename-matching rule — *"(e.g. the diff entry `docs/DEVFLOW_SYSTEM_OVERVIEW.md` satisfies the named path `DEVFLOW_SYSTEM_OVERVIEW.md`)"* — not a pointer into the docs tree. It is not an unresolvable reference; it is a repo-specific example in prose that a consumer's agent reads. Disposition it on that basis (a generic example filename discharges it), not as a broken link.
- **L529 (P)** → `docs/cloud-allowlist.md`: *"`docs/cloud-allowlist.md` records that capture carve-out as an inference rather than a measurement"* — again the doc carries the evidence grade of a shipped rule.
- **L578 (L)** → `docs/implement-skill.md`: *"The downstream consequence is documented in [`docs/implement-skill.md`](../../../docs/implement-skill.md) — CI's `ready_for_review` listener does not auto-fire until a human publishes the PR."*

**8. `skills/init/SKILL.md` — 2 lines, both P → `docs/cloud-setup.md`**

The sharpest consumer-facing pair, because the init skill is the first thing a consumer maintainer runs:

- **L170 (P)** — *"only once the maintainer opts in with `prflow_runner.provision_env: true` (see "Letting the reviewer build/test a PR" in docs/cloud-setup.md)"*. Names a **section title** inside a document the maintainer is being told to consult.
- **L305 (P)** — a troubleshooting arm: *"they must set `prflow_runner.provision_env: true` and populate the `setup` block (see `config.schema.json` / docs/cloud-setup.md)"*.

**9. `skills/retrospective-weekly/SKILL.md` — 2 lines (1 L, 1 P)**

- **L25 (L)** → `docs/working-directory-contract.md`, the standard working-directory-contract pointer.
- **L489 (P)** → `docs/efficiency-trace.md`: *"See `docs/efficiency-trace.md` for the store schema and the abandoned-run bias."* The store schema is genuinely not restated in the skill.

**10. `skills/review-and-fix/references/loop-control.md` — 1 line (P)**

- **L182 (P)** → `docs/cloud-setup.md`. The doc is cited as evidence for a **security-relevant claim**: *"the `CLAUDE.md` arm does not carry this self-supply hazard on the cloud review paths, because `claude-code-action`'s restore pass loads the base branch's `CLAUDE.md` (see `docs/cloud-setup.md`)"*. Removing the pointer removes the only stated backing for a hazard-scoping claim.

**11. `skills/review-and-fix/references/loop-exit.md` — 1 line (L), two targets**

- **L221 (L)** → `docs/efficiency-trace.md` (*"for the derivation rules"* behind the four subagent verdicts) **and** `docs/working-directory-contract.md`, on the same line.

**12. `skills/review/SKILL.md` — 4 lines (1 L, 3 P)**

- **L58 (L)** → `docs/working-directory-contract.md`.
- **L66 (P)** → `docs/DEVFLOW_SYSTEM_OVERVIEW.md`, for the `prflow_review.stall_backstop` mechanism.
- **L226 (P)** → `docs/review-agent-overrides.md`: *"Operators can tune each review subagent's model and reasoning effort via the `prflow_review.agent_overrides` block in `.prflow/config.json` (see `docs/review-agent-overrides.md` and the schema)."* This is **operator-facing configuration guidance** shipped to a consumer whose operator will look for the doc.
- **L228 (P)** → `docs/review-agent-overrides.md` again, for the `session-fallback` reporting semantics.

**13. `skills/review/phases/phase-3-agents.md` — 2 lines, both P → `docs/shadow-review.md`**

- **L187 (P)** — *"this is the PR #164 / PR #62 / PR #154 class — see `docs/shadow-review.md`"*. Ships **three PRFlow-internal PR numbers** into a consumer's review engine as the named evidence class.
- **L194 (P)** — *"the independent signal can itself have a blind spot (see `docs/shadow-review.md`)"*, the stated caveat on a completeness claim.

### Where the prose dependency is substantial

Five sites lean on the referenced document hard enough that removing the pointer changes what the sentence asserts. These need real rewriting, not deletion:

1. `step-3-6-audit.md` **L312** — the prose explicitly cedes canon to `DEVFLOW_SYSTEM_OVERVIEW.md` §11 and calls itself "the operational form … not a restatement". Removing the pointer leaves a rule with no declared authority.
2. `phase-1-setup.md` **L507** — cites a named section as "the full statement of the threat model" and imposes a coupled-edit obligation.
3. `implement/SKILL.md` **L40** and `phase-4-documentation.md` **L529** — both use `docs/cloud-allowlist.md` to carry the *evidence grade* of a claim (`unestablished`; `an inference rather than a measurement`). A self-contained rewrite must restate that grade inline or the rule reads as settled fact.
4. `loop-control.md` **L182** — the only backing for a security-relevant hazard-scoping claim.
5. `review/SKILL.md` **L226/L228** — operator-facing configuration documentation with no self-contained substitute in the skill.

By contrast, the eight `docs/working-directory-contract.md` / `docs/implement-skill.md` / `docs/create-issue-context.md` link sites are largely mechanical: the sentence before the pointer already states the rule, and the pointer is a "canonical statement" tail that can be dropped outright.

### The mechanism this unblocks

`lib/test/lint-shipped-pruned-path.py` derives its forbidden-path set from the **`rm` arguments inside `devflow_copy_slice()`**, not from the `cp -R` line. Verified: its docstring states *"A qualifying prune target is an argument of an `rm` (any flag set — `rm -f` qualifies alongside `rm -rf`) inside `devflow_copy_slice()`"*, and `lib/test/lint-shipped-pruned-path.py --print-prune-set` on `main` today prints exactly:

```
.claude-plugin/marketplace.json
docs/external
docs/site
lib/test
```

So **the prune line is what arms the lint**. Once the internal docs are moved (#1188) and this issue's references are gone, adding `docs/internal` to that `rm -rf` both stops shipping maintainer documentation to consumers and arms the lint to keep it that way. Neither half works while a shipped reference survives.

## User Impact

- **A consumer's runtime agent follows a dead pointer.** The skills that ship these lines — init, implement, review, review-and-fix, create-issue, retrospective-weekly — are the engine a consumer actually runs. A sentence telling it to "see `docs/cloud-setup.md`" resolves against the consumer's tree, where nothing is there.
- **A consumer's human maintainer is sent to documentation about someone else's repository.** `init/SKILL.md` L170 names a section title in a doc the maintainer is told to open; `review/SKILL.md` L226 does the same for reviewer tuning.
- **PRFlow's maintainer documentation is shipped into every consumer repository** solely to keep these 26 lines resolvable — internal cutover records, prompt-mass studies, evidence tables and all.
- **#1188 cannot finish cleanly.** The internal-docs move is a pure path sweep only if no shipped prompt surface carries a path to sweep; today it would have to choose between rewriting 26 shipped lines to `docs/internal/…` (a defect) and leaving them dangling.

## Desired Behavior

The `skills/**` and `agents/**` populations carry **zero** references to PRFlow-internal documentation. Each of the 26 lines is dispositioned individually, choosing exactly one of three arms and recording the choice:

1. **Remove** — the reference adds nothing a consumer's reader can use. The sentence stands without it. Expected for most of the twelve "canonical statement" link tails.
2. **Replace with self-contained, repo-agnostic prose** — the point the pointer was carrying survives, restated inline in language that means something in any repository. Expected for the substantial-dependency sites above.
3. **Explicitly justify** — a recorded per-line reason the reference must stay. This arm is real but costly: **a single justified reference forces `docs/` (later `docs/internal/`) to keep shipping to consumers**, and forecloses the prune. If this arm is used at all, the PR body says so and states the consequence.

A rewrite from `docs/x.md` to `docs/internal/x.md` is **not** one of the arms. It is a defect and fails this issue.

## Acceptance Criteria

Every criterion is dischargeable at a desk with the command named. **None requires a cloud run, a probe dispatch, a merge, or a CI result.**

**AC1 — the population is re-measured, not trusted.** The PR body records the measurement command's output on the pre-change tree and its line/file counts, alongside the link/prose split. If it differs from 26 lines / 13 files / 12 link / 14 prose, the PR body says so and works from the measured figure.
*Desk check:* the *measurement command* above, run and quoted in the PR body.

**AC2 — every reference is enumerated and dispositioned.** The PR body carries one row per reference line: `file:line`, the referenced document, `link`/`prose`, and the chosen arm (`removed` / `replaced` / `justified`). A `justified` row carries its per-line reason.
*Desk check:* row count equals AC1's measured line count.

**AC3 — no reference was merely re-pathed.** No `skills/**` or `agents/**` file gains a `docs/internal/` reference.
*Desk check, unconditional:* `git grep -nE 'docs/internal/' -- skills/ agents/` is empty.

**AC4 — the population is empty (or exactly the justified rows).** Re-running the measurement command against the post-change tree returns only the lines AC2 records as `justified`. For a fully-discharged run, empty.
*Desk check, unconditional:* the measurement command re-run; its output matches AC2's `justified` set exactly, and `git grep -nE "docs/($NAMES)" -- agents/` is empty with no exceptions.

**AC5 — `agents/**` stays at zero.** No agent file gains an internal-doc reference.
*Desk check:* covered by AC4's second command.

**AC6 — every prompt-surface edit carries its RED/GREEN evidence.** Per `CLAUDE.md`'s "Editing any skill file" convention and `.prflow/prompt-extensions/implement.md`'s *Prompt-surface edit routing*, each edited file matching a trigger glob is edited through a context-isolated subagent that invokes `superpowers:writing-skills` — never a mid-phase Skill-tool call — and the workpad carries a line containing the literal `Writing-skills evidence:` naming the files, `mode=` (`subagent` or `inline-degraded`), and **all four slots** in the shape issue #1171 shipped: `skill-loaded=`, `guidance-applied=`, `pressure-scenario=`, `micro-tests=`, each `yes`/`no` with a one-clause parenthetical reason. `no` with a reason is a discharging value.
*Desk check:* read the workpad; the marker line is present and all four slots are written.

**AC7 — the two files outside the trigger globs are handled deliberately.** The routing globs are `skills/*/SKILL.md`, `skills/implement/phases/*.md`, `skills/implement/references/*.md`, `skills/review/phases/*.md`, `skills/review-and-fix/references/*.md`, `.prflow/prompt-extensions/*.md`. Eleven of the thirteen files match one. **`skills/create-issue/references/step-3-6-audit.md` and `skills/create-issue/references/step-4-present-create.md` match none** — they stay under the base skill's Phase 2 §2.4 inline RED/GREEN micro-test discipline. The PR body states which discipline covered each of those two, rather than leaving it implied.
*Desk check:* compare the edited-file list against the glob list; the PR body names the two and their discipline.

**AC8 — no frontmatter is touched.** A skill's frontmatter `description` governs when the skill triggers, so a change there is **behavioral, not cosmetic**. All 26 references are in body prose; none is in frontmatter.
*Desk check:* `git diff` shows no change above the closing `---` of any edited file's frontmatter. If a frontmatter change is nonetheless required, the PR body states the triggering consequence explicitly.

**AC9 — the reworded-prose consequence is acknowledged.** Arm 2 (replace with self-contained prose) writes **diff-added** lines into files `scripts/stale-prose-lint.py` grades — `skills/**` markdown is in its population, and the issue-#629 move exemption is **byte-identity-based** (it pairs added lines against the diff-global removed-line multiset). A reworded line is not byte-identical to anything removed, so it loses the exemption and re-presents any counted claim it carries as new prose. Keep replacement sentences claim-free where possible; where not, expect them graded.
*Desk check:* the PR body names each replacement line that carries a countable claim, or states that none do.

**AC10 — no new wording-only or prose-presence pin is added.** Per #375 / #666 / #810, and per the recorded #843 / #876 decision that agent-executed prompt prose whose only reader is the runtime agent carries **no automated regression coverage by design** — the compensating control for this change is the review pass that reads the prose, not a pin. Retiring or removing a reference owes no replacement coverage.
*Desk check:* `git diff` adds no `*_PIN_*` variable, no `# structural-pin-ok:` marker, and no grep-on-wording assertion.

**AC11 — the pruned-path lint is green and gains no marker.** `lib/test/lint-shipped-pruned-path.py` exits 0 over the `skills/**` + `agents/**` population, and this change adds no `pruned-path-ok` declaration marker. (Six such markers already exist across five files, all for the consumer-owned `docs/external` config default and one consumer-facing prose row; all are unrelated and untouched.)
*Desk check:* run the lint as a direct leading token — exit 0; `git diff` shows no added `pruned-path-ok`.

**AC12 — the vendor slice is unchanged.** `.github/actions/vendor-plugin/vendor-slice.sh` is not modified by this change, and `--print-prune-set` still reports the four current entries.
*Desk check:* `git diff --stat -- .github/actions/vendor-plugin/` is empty; `lib/test/lint-shipped-pruned-path.py --print-prune-set` prints `.claude-plugin/marketplace.json`, `docs/external`, `docs/site`, `lib/test`.

**AC13 — the consequence is recorded.** The PR body states, in one sentence, that with the population empty `docs/` (and after #1188, `docs/internal/`) becomes prunable from the vendor slice — and names the follow-up that would do it. If AC2 recorded any `justified` row, the PR body states instead that the prune is foreclosed and why.
*Desk check:* the sentence is present and consistent with AC2.

**AC14 — the suite is green.** `lib/test/run.sh` (or the parallel coordinator) reaches `0 failed, 0 skipped`.
*Desk check:* read the run's own summary line.

**AC15 — the change carries a changeset.** A uniquely-named `.changeset/*.md` with `bump: patch` frontmatter and Keep-a-Changelog prose, per repository versioning policy. The change touches the engine surface (`skills/`).
*Desk check:* the file exists and the PR cites it.

## Explicitly out of scope

- **Changing `devflow_copy_slice()`'s prune line, or adding `docs/internal` to it.** The internal docs still live at `docs/` root until #1188 relocates them; the prune belongs with the move, not here. AC12 keeps the slice byte-identical.
- **Moving, renaming or reorganising any documentation.** That is #1188.
- **Any general prose pass over any skill.** Only the enumerated lines are edited. A skill body is touched at the reference site and nowhere else.
- **Editing `skills/receiving-code-review/` or `skills/requesting-code-review/`.** Both are already clean; the repo-agnostic rule that governs them is unchanged.
- **Editing `agents/**`.** Measured at zero; AC5 keeps it there.
- **Adding test coverage for the removed prose.** Per #843 / #876 there was never a behavior to cover.
- **Rewriting the internal documents themselves.** If a replacement sentence duplicates something a doc says, the doc is left alone.
- **Any change to `.prflow/config.json`, the shipped workflows, or `install.sh`.**

## Implementation Notes

A map of the surfaces involved. **Floor-declared**: this enumerates what the measurement found; it is a starting map, not a certified-complete list. Re-run the sweep rather than trusting these counts.

**The edited population — 13 files**

| File | Lines | Docs referenced |
|---|---|---|
| `skills/create-issue/SKILL.md` | 2 (2L) | create-issue-context |
| `skills/create-issue/references/step-3-6-audit.md` | 4 (2L, 2P) | create-issue-context, advisory-adjudication-calibration, DEVFLOW_SYSTEM_OVERVIEW |
| `skills/create-issue/references/step-4-present-create.md` | 1 (1L) | advisory-adjudication-calibration |
| `skills/implement/SKILL.md` | 2 (1L, 1P) | working-directory-contract, cloud-allowlist |
| `skills/implement/phases/phase-1-setup.md` | 1 (1L) | implement-skill |
| `skills/implement/phases/phase-2-implement.md` | 1 (1L) | implement-skill |
| `skills/implement/phases/phase-4-documentation.md` | 3 (1L, 2P) | implement-skill, DEVFLOW_SYSTEM_OVERVIEW, cloud-allowlist |
| `skills/init/SKILL.md` | 2 (2P) | cloud-setup |
| `skills/retrospective-weekly/SKILL.md` | 2 (1L, 1P) | working-directory-contract, efficiency-trace |
| `skills/review-and-fix/references/loop-control.md` | 1 (1P) | cloud-setup |
| `skills/review-and-fix/references/loop-exit.md` | 1 (1L) | efficiency-trace, working-directory-contract |
| `skills/review/SKILL.md` | 4 (1L, 3P) | working-directory-contract, DEVFLOW_SYSTEM_OVERVIEW, review-agent-overrides |
| `skills/review/phases/phase-3-agents.md` | 2 (2P) | shadow-review |

**The ten referenced documents** — `docs/create-issue-context.md`, `docs/advisory-adjudication-calibration.md`, `docs/DEVFLOW_SYSTEM_OVERVIEW.md`, `docs/cloud-allowlist.md`, `docs/working-directory-contract.md`, `docs/implement-skill.md`, `docs/cloud-setup.md`, `docs/efficiency-trace.md`, `docs/review-agent-overrides.md`, `docs/shadow-review.md`.

**The mechanism**

- `.github/actions/vendor-plugin/vendor-slice.sh` — `devflow_copy_slice()`; the `cp -R` line copies `docs`, the `rm -rf` line prunes `docs/site`, `docs/external`, `lib/test`. **Read only; not edited by this change.**
- `lib/test/lint-shipped-pruned-path.py` — parses the prune set out of the `rm` arguments inside `devflow_copy_slice()`, identifying the staging variable from the function itself rather than by literal name. Fails closed when the set cannot be established. `--print-prune-set` reports it.
- `lib/test/lint_population.py` — supplies the shared index-reading `git ls-files` enumeration the lint uses over `skills/**` + `agents/**` (issue #711 discipline: no repository-root-anchored recursive walk).

**The editing discipline**

- `.prflow/prompt-extensions/implement.md`, *Prompt-surface edit routing (repo policy)* — the trigger globs, the subagent dispatch rule, the fallback clause, the evidence contract, and the four-slot line shape with its worked example. Read this before the first edit.
- `CLAUDE.md`, *Editing any skill file (`SKILL.md`)* — the standing `superpowers:writing-skills` mandate and the autonomous-run divergence.
- `scripts/stale-prose-lint.py` — the graded population and the issue-#629 byte-identity move exemption (`MoveIndex`, the demotion predicate). Relevant to AC9.

**Suggested order**

1. Re-measure; record the baseline and the split (AC1).
2. Disposition every line on paper first (AC2) — deciding the arm per line before editing keeps the mechanical and the judgment work separate.
3. Do the twelve link sites (largely mechanical: drop the "canonical statement" tail).
4. Do the fourteen prose sites, hardest last — the five substantial-dependency sites need self-contained replacements that carry the original assertion's *strength*, including its evidence grade where it had one.
5. Re-run the measurement command; confirm empty (AC4).
6. Run the pruned-path lint and the suite (AC11, AC14); add the changeset (AC15).

## Dependencies

- **Blocks #1188** — the internal-docs move. With this issue landed, #1188's sweep over shipped prompt surfaces has nothing to sweep, so the move is a pure path rewrite over non-shipped surfaces, and `docs/internal` becomes prunable from the vendor slice. #1188's AC13 states the same requirement from the other side; landing it here first means #1188 does not have to carry it.
- **No other blocker.** This change touches only `skills/**` prose plus a changeset; it needs no config change, no workflow change, and no cloud run.

## Related

- Issue #1188 — move internal documentation into `docs/internal/`; its AC13 and AC14 are the downstream halves of this work.
- Issue #1072 — `lib/test/lint-shipped-pruned-path.py`, the derived-prune-set audit over `skills/**` and `agents/**`, and the `pruned-path-ok` declaration marker.
- Issue #677 — the vendor-slice prune of `docs/site` and `lib/test`, and the comment stating that the rest of `docs/` ships because shipped skill bodies link into it.
- Issue #1171 — the four-slot `Writing-skills evidence:` marker shape AC6 requires.
- Issue #362 — why an autonomous run routes a prompt-surface edit through a subagent instead of a mid-phase Skill-tool call.
- Issues #375 / #666 / #810 — the prohibition on new wording-only and prose-presence pins.
- Issues #843 / #876 — the recorded decision that agent-executed prompt prose carries no automated regression coverage by design, and that retiring such prose owes no replacement coverage.
- Issues #423 / #434 / #629 — the stale counted-prose lint and its byte-identity relocation exemption.

