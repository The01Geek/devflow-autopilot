# `/devflow:implement` skill — Phase 2.3 sweep discipline and Phase 4.3 finalize

**Skill:** `skills/implement/SKILL.md` (Phase 2.3, *Implement*)

The `/devflow:implement` orchestrator runs a set of mandatory **sweeps** in Phase 2.3, after writing the
code and before running tests. Each sweep closes a class of blast-radius bug that survives `git diff`
review because nothing is *syntactically* broken — the affected lines still compile, parse, or run;
they are only *semantically* stale. This doc is the internal-docs counterpart of that section: it
records *why* each sweep exists so the skill text can stay terse.

A **"Sweep selection (run first)"** preamble in the skill indexes which of these sweeps a given diff's shape warrants — so an add-only diff runs just the five always-on sweeps (2.3.3/2.3.4/2.3.4a/2.3.5/2.3.6) instead of consciously dispatching the deletion/contract sweeps as no-ops. The index is **fail-safe**: each sweep's own heading (the *Triggers on* column below) stays authoritative, so a drifted or incomplete index can only over-select, never skip a warranted sweep.

## The sweeps

| Sweep | Triggers on | Closes |
|---|---|---|
| 2.3.0 Changed-contract | a change that **modifies** a signature, renames/moves a symbol, tightens a validator, or alters a classifying predicate | dependent sites left on the *old* contract (other predicate branches, sibling callers, fixtures/assertions) |
| 2.3.0a Peer-checkpoint completeness | a change that **adds** a rule/clause/guard/invariant which has *co-equal peer sites* (two or more sites that must each enforce the same rule for it to hold) | the rule stated at only *some* peers — a guard applied to one config-leaf branch but not its siblings, a read-only clause present at 2 of 4 gate checkpoints, a fallback in the selection predicate but not the parallel derivation |
| 2.3.0b Enum-enumeration reconciliation | a change that **adds a value to an enumerated value set** (a new enum/string-union member, status, kind, verdict, or `fix_decision`) | enumerating sites left stale — a doc/comment list of the value set, or a fall-through consumer (an `else`/`default`/`// null` arm) — that the *code*-call-site sweeps (2.3.0/2.3.0a) miss, even when the runtime stays correct because the new value rides an intended fall-through |
| 2.3.1 Orphaned-setup | a **deletion** of code | setup lines (a dependency fetch, lookup, computed local, import) whose only consumer was the deleted code |
| 2.3.2 Stranded-dependents | a **deletion** of a method, file, route, or page | references *outside* the diff the deletion stripped of purpose (callerless public methods, dead args, surviving inbound links) |
| 2.3.3 Convention-compliance | any code the diff **added or modified** | `CLAUDE.md` convention violations in touched code |
| 2.3.4 Boundary-assumption | any diff that **depends on** a fact about something it does not own | claims about a dependency version, the supported runtime, a sibling producer's output, or the real host that were asserted from memory instead of verified |
| 2.3.4a Self-authored-claim reconciliation | any diff that **authors** a behavioral claim in prose — internal/external docs it edits, or code comments it adds/changes | a sentence or comment that asserts what the shipped code does but contradicts the actual code path (including the diff's *own* new code, which 2.3.4 carves out) — caught by tracing each authored claim to the code, following dispatch into pre-existing helpers the diff calls |
| 2.3.5 Simplification & Efficiency | any code the diff **added or modified** | avoidable complexity (redundant/derivable state, copy-paste variation, deep nesting, dead code) and wasted work (redundant I/O or computation, needless sequential ops, hot-path/startup cost) that only show up once the change is assembled |
| 2.3.6 Error-handling & silent-failure | any code the diff **added or modified** | silent failures — swallowed or over-broadly-caught errors, unjustified or fail-open fallbacks, mock/stub leaks, and generic/misdirected breadcrumbs — that ship clean because the happy path works and only fire on an input the tests don't exercise |

2.3.1–2.3.3 trigger on *deletion* or *addition*. **2.3.0** fills the gap for *modification*: changing a
contract is just as blast-radius-prone as deleting one, but it is harder to catch because every
dependent site still compiles. The common failure mode is fixing the originating site but not its
siblings — a predicate corrected in one branch but not the others, one caller that plumbs a new
per-request input while its sibling sharing the same object does not, or a fixture/assertion left
encoding the old contract. **2.3.4** is orthogonal to all of the above: it is not about the diff's own
consistency but about facts the diff *relies on* across a boundary it does not control.

**2.3.0a** is the *additive* twin of 2.3.0. Where 2.3.0 watches a *modified* contract for stale
*dependent* sites (caller→callee), 2.3.0a watches a *newly-added* rule for incomplete *co-equal peer*
coverage: a guard, validator clause, read-only precondition, classification tripwire, or fallback that
must hold at every member of a peer set but lands at only some. The distinction matters because the two
fire on different diff shapes and grep different things — 2.3.0 greps for the old symbol/predicate/contract
across dependents; 2.3.0a greps for the *shared marker* of the peers (the clause keyword, the guarded
variable, the step heading) to enumerate the set the rule must blanket. The weekly retrospective surfaced
this as a recurring `incomplete-edit` sub-pattern distinct from 2.3.1/2.3.2 (deletion-triggered) and
2.3.0 (modification-triggered): a read-only clause present at 2 of 4 gate checkpoints, a config-leaf
warning on the object path but not the scalar/array paths, a `closingIssuesReferences` fallback in the
selection predicate but not the parallel workpad derivation — each correct in isolation, each described
by its PR's prose as if it held everywhere, each surfacing only as a REJECT or post-bot fix. A deliberately
exempt peer is allowed when recorded with a `--note`; only a *silent* asymmetry is the defect. It is
numbered 2.3.0a (not renumbering 2.3.1–2.3.6) for the same presentational reason 2.3.6 sits last.

**2.3.0b** is a second sibling in the 2.3.0 family, for a different additive shape: *adding a value to an
enumerated value set*. Where 2.3.0a watches a newly-added rule for incomplete peer coverage, 2.3.0b watches
a newly-added enum/status/kind/verdict value for *stale enumerating sites* — and, critically, it greps a
class the code-call-site sweeps do not: **doc/comment enumerations** of the value set and **fall-through
consumers** (an `else`/`default`/`// null` arm). The motivating case (#160) is the worked example: adding
`fix_decision: "severity-calibrated"` was behaviorally correct because the value rode an intended `else null`
fall-through in `verdict_for`, yet `lib/efficiency-trace.jq`'s and `docs/efficiency-trace.md`'s prose
enumerations of the value set went stale until a shadow reviewer flagged them — "consistent behavior" is not
"reconciled enumeration." 2.3.0 and 2.3.0a grep *code* sites; 2.3.0b keys on the *observable* member literals
of the set (grep each known value, not a re-judgment) so the doc/comment and fall-through sites are caught at
implement time. A site deliberately exempt (a fall-through that *should* absorb the value) is allowed when
recorded with a `--note`; only a *silent* stale enumeration is the defect.

**2.3.5** is different in kind from the correctness sweeps above: it front-loads the *cleanup* lenses that the Phase 3.2 `/simplify` pass (`/code-review --fix`) would otherwise be the first to catch. `/code-review` applies four cleanup lenses — reuse, simplification, efficiency, altitude. The first two of those are *design* decisions and are settled earlier, at the **2.2.4 Reuse & Altitude plan gate**, because reusing an existing helper or picking the right altitude is far cheaper before the code is written than after. Simplification and efficiency are properties of the *assembled* diff, so they belong in a post-write sweep — hence 2.3.5. Together, 2.2.4 + 2.3.5 mean the in-loop `/simplify` should find little; when it finds a lot, that is the signal those two gates were skipped or rushed. `/simplify` still earns its place as a backstop because it sees the whole diff at once and catches cross-change duplication and dead code no single in-loop sweep would.

**2.3.6** front-loads the Phase 3.3 `silent-failure-hunter` review agent the way 2.3.5 front-loads `/simplify`. Its defect class — a swallowed error, an over-broad `except`/catch, a fallback that masks a failure (or fails *open*, defaulting an error to a success-shaped value), a mock/stub leaking into production, or a generic/misdirected breadcrumb — has no home among the other sweeps: it isn't a contract change (2.3.0), a deletion (2.3.1/2.3.2), or, in general, a documented `CLAUDE.md` rule (2.3.3), and it only sometimes doubles as a boundary claim (2.3.4) or added complexity (2.3.5). Baseline testing of the implement skill confirmed the gap: capable agents running 2.3.0–2.3.5 caught these defects only when they happened to overlap another sweep's trigger, attributed them inconsistently, and missed a pure swallow (a `gh … 2>/dev/null || true` that printed success for a comment that never posted) outright — exactly the findings `silent-failure-hunter` then raised in Phase 3.3. Making it an always-on, explicitly-named sweep gives the class a deterministic home so it is caught at implement time, not a review iteration later. It is a *correctness* sweep numbered last only to avoid renumbering its predecessors; each sweep's intro references "2.3.0–2.3.N" of the lower-numbered sweeps, so the ordering is presentational, not an execution dependency.

## Changed-contract sweep (2.3.0) and the post-merge re-sweep

The skill spells out the three checks (predicate variants, sibling call sites, fixtures/assertions).
The *why*: the common failure mode is fixing the originating site but not its siblings — and those
siblings still compile, so `git diff` review misses them.

The sweep must also be **re-run after any merge or rebase of `main`** — the skill's Error Handling
conflict-recovery path (`git pull --rebase origin {branch}`) and anywhere else the run pulls in
`main`. A clean textual merge is not a clean semantic merge: `main` can arrive with a fixture, call
site, or assertion (often from a concurrently-merged PR) that the change's new contract now rejects,
merged cleanly with no conflict. A newly-arrived violating site is a defect in *this* PR, not a
follow-up.

## Boundary-assumption sweep (2.3.4)

The four boundary kinds and how to verify each are in the skill (and summarized in the table above).
The *why*: these bugs ship clean and pass the author's own tests — because the tests encode the same
wrong assumption — so a green run is not confirmation, and a test assertion *about* a boundary is
itself an unverified claim. A boundary that genuinely cannot be verified in-environment is never
asserted as true: it is recorded with a `--reflection` note and, only when a specific acceptance
criterion's verification depends on it, retagged `(post-merge)` — and that retag is itself gated (see
*Acceptance-criteria gate* below): an unverifiable external boundary is the one genuinely-live case the
gate accepts, never a runnable-but-blocked or self-claim-confirming criterion.

## Self-authored-claim sweep (2.3.4a)

2.3.4a is the enforced twin of 2.3.4 on the *output* side. 2.3.4 verifies the facts the diff **depends
on** across boundaries it doesn't own; 2.3.4a verifies the behavioral claims the diff **authors** — the
sentences it writes into internal docs, external docs, and code comments — against what the shipped code
actually does. The trigger is the authored prose, not the code's boundaries, and that is why it is a
separate sweep: 2.3.4 explicitly carves out claims about *code defined in the same diff*, so a comment
that misdescribes the diff's own new function, or a doc sentence the diff adds that overstates a
guarantee, is precisely the blind spot 2.3.4 leaves and 2.3.4a closes. These contradictions ship clean —
the prose reads plausibly, the code compiles, and the author's tests assert the prose's *intent* rather
than the code's *behavior* — so the engine reconciles every authored claim before commit: it traces each
claim to the actual code path (following dispatch into pre-existing helpers the diff calls) and, on any
divergence, **the code is the fact** — it fixes the code or rewrites the claim, and never commits the
unreconciled pair. The **PR body** is reconciled the same way in Phase 4.2, where the body is authored
(it does not exist at commit time).

## Acceptance-criteria gate: the gated `(post-merge)` tag (Phase 3.4)

The Phase 3.4 gate requires every **non-post-merge** acceptance criterion to be verified before the run
advances. A `(post-merge)` tag exempts a criterion from blocking, so the gate enforces — as engine
behavior, not advisory prose — exactly **when** that tag is permitted: **only when the criterion
genuinely requires a runtime environment that does not exist during the implement run** (a live deploy
target, a real third-party endpoint, a production data path). The observable test is whether the
verification could ever run on the orchestrator host given the right tools; if it could, it is not
post-merge. Two cases are therefore never eligible and the gate refuses the tag for them:

- **Runnable-but-blocked (local tooling/environment gap)** — a criterion verifiable on this host but
  blocked right now by a denied command, a missing build tool, an un-spawnable helper, or a failed
  restore. A tooling gap is not a runtime-environment gap; it takes the existing **`Blocked`** escalation
  path (human handoff), never a silent post-merge pass. (A genuine permission/sandbox denial of the *test
  suite itself* is a distinct mechanism — the auditable, workpad-recorded skip to the CI `lib + python
  tests` gate per `CLAUDE.md`; it does not tick the AC.)
- **Confirmation of a self-authored claim** — a criterion whose purpose is to confirm a behavioral claim
  the PR already asserts as true. It is runnable pre-merge by construction (the claim is about the shipped
  diff), so deferring it would defer the one check that could falsify the claim; the gate refuses the tag
  regardless of stated reason.

This is the gate enforcing "verified before merge" rather than trusting the run's narrative: a local
tooling gap can no longer be laundered into a post-merge pass, and a self-claim confirmation can no
longer be deferred past the one test that would catch it.

## Phase 4.3 finalize: publish vs. draft (`implement_pr_state`)

Phase 4.3 (*Finalize the PR and Finalize Workpad*) is where a run ends. It runs three things in order:

1. **Clean-tree backstop (unconditional).** `git status --porcelain` must be empty before finalizing. The run started from a clean base-branch checkout, so anything dirty here is this run's own work an earlier phase failed to commit — it is committed with the right prefix and the under-committing phase is recorded in `Devflow Reflection`, never papered over. This runs in *both* the publish and draft cases; it is independent of the publish decision.
2. **Publish decision.** By default the run publishes the draft PR created in Phase 3.1 by running `gh pr ready`.
3. **Workpad finalization.** `Status` flips to `Complete` (🎉), the final `## Progress` item is ticked, and the 🎉 outcome reaction is emitted on the triggering comment — in both cases.

The publish step is gated by a per-consumer config key, **`devflow_implement.implement_pr_state`** (string, read via `config-get.sh .devflow_implement.implement_pr_state ready_for_review`):

| Value | Phase 4.3 behavior |
|---|---|
| `ready_for_review` (default) | Runs `gh pr ready` — the PR is published, exactly as before. |
| `draft` | Skips `gh pr ready` — the PR is left as the Phase 3.1 draft. No extra comment is posted to the PR thread. The workpad `--note` wording states the PR was *left as a draft* rather than marked ready. |
| missing / empty / any other value | Resolves to `ready_for_review` (publish). |

**Default-to-publish is the safe direction**: only the exact literal `draft` suppresses publishing, so a typo'd or future value can never accidentally leave a PR unpublished, and a hard config read failure (malformed config) also falls back to publishing. Existing consumers and DevFlow's own runs — which do not set the key — are unaffected.

**Downstream consequence of `draft`.** Publishing a PR is what fires the rest of the pipeline: the cloud review (`devflow-review.yml` triggers on the `ready_for_review` event) and CI's `ready_for_review` listener both key off the draft→ready transition. Choosing `draft` therefore *intentionally* suppresses those for that run until a human publishes the PR — this is the documented trade-off a consumer accepts, not a bug to be fixed. It lets maintainers of repos that adopt DevFlow keep bot-completed PRs out of the ready-for-review queue and publish them on their own cadence (after a manual look, on a release boundary, or to avoid auto-notifying reviewers).

The gate lives once in `skills/implement/SKILL.md` Phase 4.3 — the skill body is shared by the local and cloud `/devflow:implement` paths, and both read the same `config.json` via `config-get.sh`, so no workflow change is needed and the logic is never forked.

## `## Devflow Reflection`: grouped-by-kind rendering (`--reflection-kind`)

Reflection bullets are grouped by **kind** so a human triaging a DevFlow PR/issue sees the items that need follow-up separated from purely informational notes, without expanding and reading a flat list. `scripts/workpad.py update` takes a `--reflection-kind {blocked|deferred|dropped-failed|note}` flag that applies to that call's `--reflection` bullet(s); the helper — the single chokepoint every reflection flows through — owns the glyph, bold label, and sub-section placement, so the structure holds regardless of how the orchestrator phrases the text.

| Kind | Glyph + label | Sub-section |
|---|---|---|
| `blocked` | `⛔ **Blocked:**` | `### ⚠️ Action required` |
| `deferred` | `⏭️ **Deferred:**` | `### ⚠️ Action required` |
| `dropped-failed` | `❗ **Dropped/Failed:**` | `### ⚠️ Action required` |
| `note` (default when omitted) | `ℹ️ **Note:**` | `### ℹ️ Notes` |

Both sub-sections live inside the existing `## Devflow Reflection` `<details>` block. Mechanics, baked into the helper:

- A sub-heading is emitted **only** when its group has ≥1 bullet (an empty group produces no heading); a second bullet of an existing kind nests under the existing heading without duplicating it; appended content stays before `</details>`.
- Sub-headings are `### ` (level-3), **never** `## ` — `lib/fetch-pr-context.sh` terminates the reflection parse at the first `## ` heading, so a level-2 sub-heading would truncate `reflections[]`. The parser captures every kind bullet (glyph + label prefix included — useful signal for the retrospective LLM, irrelevant to `cheap-gate.jq`'s non-empty check) and excludes the `### ` headings, for both the new grouped shape and a legacy flat block. The gate is unchanged: any run that left ≥1 reflection bullet is forced into LLM analysis.
- `--reflection-kind` defaults to `note`, so un-migrated call-sites degrade to the Notes sub-section — never to Action required. A single kind applies to every `--reflection` in the call, so the orchestrator emits different kinds in separate `update` calls (this is why the Phase 4.3 `publish_failed` `dropped-failed` reflection is its own call, separate from the `note`-kind finalize). This mirrors `workpad.py`'s existing helper-owns-the-rendering-token idiom (`--status` derives and prepends the status glyph; `--note` nests under the right `## Progress` phase).

## Phase 4.0 / 4.0.5 deferred-issue labels (`deferred.labels`)

When a run scopes itself down, it files follow-up issues for the work it deferred: Phase 4.0 files an issue per deferred *acceptance criterion* (carried verbatim from the 2.2.5 scope decision), and Phase 4.0.5 files an issue per deferred *review finding* (the Step-3 deferrals manifest). The labels applied to those follow-up issues are configurable via **`deferred.labels`** — a comma-separated string under the top-level `deferred` object (default `DevFlow,Deferred`), read by both phases with `config-get.sh .deferred.labels DevFlow,Deferred`.

Both phases resolve and apply the labels with the **same idiom Phase 4.1 uses for `docs.labels`**, so there is one normalization rule to learn:

- **Normalize** the raw value by splitting on `,`, trimming whitespace from each entry, and dropping empties. `"DevFlow, Deferred"` applies both labels; a whitespace-only or all-separators value (e.g. `" , "`) normalizes to *none* and applies no labels. (A literal empty string resolves to the `DevFlow,Deferred` default rather than meaning no-labels, matching how config defaults resolve.)
- **Ensure-then-apply, best-effort, post-creation.** The issue is created with **no** `--label` on `gh issue create`; the normalized labels are then ensured to exist via `ensure-label.sh` (which always exits 0) and applied in a single `gh issue edit --add-label` per filed issue. A label hiccup is logged to stderr and a `Devflow Reflection` note, never allowed to block or unwind the filing — mirroring the post-creation `--add-label` idiom Phase 3.1 uses for the hardcoded `DevFlow` provenance label.

The reason it lives in the **skill**, not in `file-deferrals.py`, is the standing config rule: config is read by the Node resolver (`config-get.sh`), never by Python — so the resolve/normalize/ensure/apply steps stay in the skill body and the deferral helper stays config-agnostic. A **hard** `config-get.sh` read failure (corrupt `config.json`, missing node) is distinguished from an empty result: its non-zero rc is captured and recorded in a reflection, and the run continues filing the issues *without* labels rather than aborting.

This key controls **only** deferred-issue labeling. It is independent of the hardcoded `DevFlow` provenance label that retrospective detection matches literally (`lib/scan.sh`, `lib/classify-pr-kind.jq`) — that string is a constant no config key controls — and separate from the `docs.labels` docs-pass label.

## Scope boundary between Phase 2.3.2 and Phase 4.1

The 2.3.2 stranded-dependents sweep covers references in **code, config, and routing tables** — things
that break behavior at runtime if left dangling (a surviving `href` to a deleted page, a call site
still passing dead arguments). It does **not** cover prose references to the deleted symbols/paths
inside `docs/internal/` (descriptions, walkthroughs, install steps). Those are handled by the Phase
4.1 documentation pass, which spawns the `devflow:docs` subagent after the code is committed. If a
2.3.2 grep turns up only docs hits, the skill notes them and moves on rather than editing
`docs/internal/` from Phase 2.3 — the docs pass has the full picture (shipped code, not just the
plan) and the right mandate to update prose.
