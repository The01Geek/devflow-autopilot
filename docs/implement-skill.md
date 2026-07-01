# `/devflow:implement` skill — Phase 2.3 sweep discipline and Phase 4.3 finalize

**Skill:** `skills/implement/phases/phase-2-implement.md` (Phase 2.3, *Implement*) — the detailed phase procedure read at phase entry by the thin `skills/implement/SKILL.md` orchestrator

The `/devflow:implement` orchestrator runs a set of mandatory **sweeps** in Phase 2.3, after writing the
code and before running tests. Each sweep closes a class of blast-radius bug that survives `git diff`
review because nothing is *syntactically* broken — the affected lines still compile, parse, or run;
they are only *semantically* stale. This doc is the internal-docs counterpart of that section: it
records *why* each sweep exists so the skill text can stay terse.

A **"Sweep selection (run first)"** preamble in the skill indexes which of these sweeps a given diff's shape warrants. Its trigger shapes are **substrate-agnostic** — a contract, a peer-replicated rule, or an enumerated-set membership can live in prose/`SKILL.md`/doc/config as much as in code, so the preamble classifies by *what the change replicates across sites*, not by whether it is code: an add-only diff that replicates nothing across sites runs just the five always-on sweeps (2.3.3/2.3.4/2.3.4a/2.3.5/2.3.6) instead of consciously dispatching the deletion/contract sweeps as no-ops, but an add-only prose/doc/config diff that adds a peer-replicated rule, an enumerated-set member, or a mirrored contract literal still runs the contract-completeness sweeps (2.3.0 / 2.3.0a / 2.3.0b). The index is **fail-safe**: each sweep's own heading (the *Triggers on* column below) stays authoritative, so a drifted or incomplete index can only over-select, never skip a warranted sweep.

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

**2.3.5** is different in kind from the correctness sweeps above: it front-loads the *cleanup* lenses that the Phase 3.2 `/simplify` pass (`/code-review --fix`) would otherwise be the first to catch. `/code-review` applies four cleanup lenses — reuse, simplification, efficiency, altitude. The first two of those are *design* decisions and are settled earlier, at the **2.2.4 Reuse & Altitude plan gate**, because reusing an existing helper or picking the right altitude is far cheaper before the code is written than after. Simplification and efficiency are properties of the *assembled* diff, so they belong in a post-write sweep — hence 2.3.5. Together, 2.2.4 + 2.3.5 mean the in-loop `/simplify` should find little; when it finds a lot, that is the signal those two gates were skipped or rushed. `/simplify` still earns its place as a backstop because it sees the whole diff at once and catches cross-change duplication and dead code no single in-loop sweep would. One asymmetry the orchestrator must close at apply time: the `/simplify` cleanup agents see only the diff, never the issue's `## Acceptance Criteria` or the Phase 2.2.5 scope decisions, so a cleanup that reads as correct against the diff alone can directly violate the issue's deliberate scope (move a rule out of the file an AC pinned it to, trim an exclusion list an AC mandated). On the issue-context `/devflow:implement` path, Phase 3.2 therefore **triages each finding against the in-scope acceptance criteria and Phase 2.2.5 scope notes before applying it** — a finding whose fix would break an AC or the decided scope is skipped, with the AC conflict recorded as the skip rationale via `workpad.py --note`; non-conflicting findings apply as before. This is the apply-time analogue of the Phase 3.4 AC gate and exists only here (standalone `/simplify` / `/code-review` carries no issue/AC context and is unchanged). The one carve-out: a finding that conflicts with a now-*stale* AC a legitimate refactor superseded is not a silent skip but Phase 2.2.6 AC-rewrite territory — rewrite the AC text with a `--note` paper trail, then let the finding apply.

**2.3.6** front-loads the Phase 3.3 `silent-failure-hunter` review agent the way 2.3.5 front-loads `/simplify`. Its defect class — a swallowed error, an over-broad `except`/catch, a fallback that masks a failure (or fails *open*, defaulting an error to a success-shaped value), a mock/stub leaking into production, or a generic/misdirected breadcrumb — has no home among the other sweeps: it isn't a contract change (2.3.0), a deletion (2.3.1/2.3.2), or, in general, a documented `CLAUDE.md` rule (2.3.3), and it only sometimes doubles as a boundary claim (2.3.4) or added complexity (2.3.5). Baseline testing of the implement skill confirmed the gap: capable agents running 2.3.0–2.3.5 caught these defects only when they happened to overlap another sweep's trigger, attributed them inconsistently, and missed a pure swallow (a `gh … 2>/dev/null || true` that printed success for a comment that never posted) outright — exactly the findings `silent-failure-hunter` then raised in Phase 3.3. Making it an always-on, explicitly-named sweep gives the class a deterministic home so it is caught at implement time, not a review iteration later. It is a *correctness* sweep numbered last only to avoid renumbering its predecessors; each sweep's intro references "2.3.0–2.3.N" of the lower-numbered sweeps, so the ordering is presentational, not an execution dependency. The sweep also carries a **per-branch-breadcrumb** sub-check: for any multi-branch no-op path the diff adds (e.g. "if A, stop; else find B; if B absent, stop"), it confirms each branch emits a distinct diagnostic naming which condition fired — two failure modes converging on one shared breadcrumb is flagged, a variant of the misdirected/generic-breadcrumb kind.

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
(it does not exist at commit time). The sweep also carries a **clean-path-evidence** sub-check: for any
step the diff adds that claims to enumerate, verify, or scan a set, it confirms the step logs a summary
(count, result) even when nothing needs changing — a silent no-op step is indistinguishable from one that
never ran, so the human reviewing the run cannot tell it executed.

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
3. **Workpad finalization.** `Status` flips to `Complete` (🎉), the final `## Progress` item is ticked, and the 🎉 outcome reaction is emitted on the triggering comment — in both cases. The final-item tick is a `--tick-progress` substring match against the `## Progress` "PR marked ready" row; if that label has drifted (or was already ticked on a resumed run) the tick is a *volatile* miss — the `## Progress` section is still present, so the call still flips `Status` to `Complete` and writes its note but **exits non-zero** rather than aborting. The finalize must consume that exit code (per the failure-isolation contract below): a non-zero finalize means the box is still `- [ ]` and the row must be re-resolved and re-ticked before the run is treated as cleanly Complete.

The publish step is gated by a per-consumer config key, **`devflow_implement.implement_pr_state`** (string, read via `config-get.sh .devflow_implement.implement_pr_state ready_for_review`):

| Value | Phase 4.3 behavior |
|---|---|
| `ready_for_review` (default) | Runs `gh pr ready` — the PR is published, exactly as before. |
| `draft` | Skips `gh pr ready` — the PR is left as the Phase 3.1 draft. No extra comment is posted to the PR thread. The workpad `--note` wording states the PR was *left as a draft* rather than marked ready. |
| missing / empty / any other value | Resolves to `ready_for_review` (publish). |

**Default-to-publish is the safe direction**: only the exact literal `draft` suppresses publishing, so a typo'd or future value can never accidentally leave a PR unpublished, and a hard config read failure (malformed config) also falls back to publishing. Existing consumers and DevFlow's own runs — which do not set the key — are unaffected.

**Downstream consequence of `draft`.** Publishing a PR is what fires the rest of the pipeline: the cloud review (`devflow-review.yml` triggers on the `ready_for_review` event) and CI's `ready_for_review` listener both key off the draft→ready transition. Choosing `draft` therefore *intentionally* suppresses those for that run until a human publishes the PR — this is the documented trade-off a consumer accepts, not a bug to be fixed. It lets maintainers of repos that adopt DevFlow keep bot-completed PRs out of the ready-for-review queue and publish them on their own cadence (after a manual look, on a release boundary, or to avoid auto-notifying reviewers).

The gate lives once in `skills/implement/phases/phase-4-documentation.md` (Phase 4.3, read at phase entry by the `skills/implement/SKILL.md` orchestrator) — the skill body is shared by the local and cloud `/devflow:implement` paths, and both read the same `config.json` via `config-get.sh`, so no workflow change is needed and the logic is never forked.

## Terminal-status self-check and Phase 4.1 re-anchor (guarding against an early run stop)

A `/devflow:implement` run can *under-complete* Phase 4: it commits the Phase 4.1 documentation, then stops before Phase 4.2 (`/pr-description`) and Phase 4.3 (finalize). The run exits `success`, so nothing signals the shortfall — the workpad is frozen at an in-progress `Status` (`Documenting` 🚀), the draft PR stays un-described, and no terminal outcome reaction is emitted. Two agent-side guards, both in the shared skill body (so local and cloud `/devflow:implement` get them with no workflow change), close this:

- **Terminal-status self-check (`skills/implement/SKILL.md`).** A cross-phase invariant near the Completion Checklist forbids the orchestrator from emitting its run-final message while the workpad `Status` is any in-progress value; it must first have reached a terminal `Status` — `Complete` (🎉) or `Blocked` (👎). The check keys on the workpad `Status`, **not** on PR draft state, so the intended `implement_pr_state=draft` path (which still reaches `Status: Complete`) is never a false positive, while a published PR whose workpad is still `Documenting` does trip it. It reuses the existing `🚀`/`🎉`/`👎` status vocabulary from `scripts/workpad.py` — no new status value.
- **Phase 4.1 post-subagent re-anchor (`skills/implement/phases/phase-4-documentation.md`).** After the Phase 4.1 `devflow:docs` subagent returns and its docs are committed, the orchestrator re-`Read`s `phases/phase-4-documentation.md` (via the same `${CLAUDE_SKILL_DIR}` anchor the entry-gate uses) before §4.2, re-anchoring the remaining §4.2/§4.3 procedure that a long context-isolated subagent return may have evicted from the working set. It is scoped to the Phase 4.1 docs subagent return only — the Phase 2 and Phase 3 subagent returns carry their own phase entry-gate reads.

Both are prose contracts, so their automated boundary is a coupled pin assertion in `lib/test/run.sh` (the same RED/GREEN mechanism the engine uses for skill contracts): each **operative** clause carries an `assert_pin_unique` presence pin (exactly-once) *and* an `assert_pin_red_on_removal` proof that it flips RED against the un-pinned source; the section heading is pinned presence-only. The always-loaded orchestrator also repeats the Phase 4.1 re-anchor *trigger* in its Phase 4 section (the phase file carries the operative instruction, but the trigger to re-read survives the subagent-return eviction only if it lives in the always-resident body), and the terminal-status self-check binds every termination path — not only a deliberate wrap-up — so a run that simply halts at "documentation done" without concluding is still caught.

## Workpad ticking: failure-isolation contract and index-based ticking

`workpad.py update` PATCHes the workpad once per call, and it distinguishes two failure classes so a batch of mutations is not lost to a single bad checkbox tick:

- **Structural failures abort the whole call before any PATCH** (exit 1, clear stderr): `gh` cannot resolve the repo, the API call fails, a target section (`## Progress`/`## Plan`/`## Acceptance Criteria`) is absent, the `Last updated` line is missing (or the `Status` line when `--status` is supplied), a `--rewrite-ac` substring matches zero or multiple rows, or a `--replace-*-file`/`--set-reproduction-file` is unreadable. A structural failure persists nothing — all-or-nothing, as it always was.
- **Volatile per-row tick misses are isolated, not aborted.** A `--tick-*`/`--tick-*-n` flag that does not resolve to exactly one tickable row *inside a present section* — a substring matching zero or multiple unticked rows, or a `-n` index that is out of range or lands on an already-ticked row — does **not** discard the call. Every other mutation (`--status`, `--note`, `--reflection`, and every tick that *did* resolve) is applied and PATCHed, and the call then **exits non-zero** with a stderr report naming each tick that did not land. So one bad tick in a batch no longer silently loses the accompanying status/notes.

A single `_report_failed_ticks` chokepoint in `scripts/workpad.py` writes the collected misses on all three exit paths — the structural-abort path, the `gh`-PATCH-failure path, and the clean-PATCH-but-ticks-missed path — so a miss is never silently dropped, and the stderr preamble states whether a PATCH was persisted so the caller can distinguish "nothing landed, re-send the whole call" from "the body PATCHed, re-tick only the named row(s)."

**Callers must check the exit code of any tick call — the printed body alone is not a success signal.** Because a volatile miss still PATCHes (and prints) the body while leaving its target row `- [ ]`, a non-zero exit from any `update` carrying a `--tick-*`/`--tick-*-n` means at least one tick did not land. This is why the Phase 3.4 gate and the Phase 4.3 finalize both gate on the exit code, not the stdout body.

**Ticking is addressable by substring or by index.** Besides the substring flags (`--tick-progress`/`--tick-plan`/`--tick-ac`), Plan and Acceptance Criteria accept a **1-based index** form (`--tick-plan-n`/`--tick-ac-n`) that counts every `[ ]` and `[x]` row within that section in document order (the index is section-scoped, not whole-document; Progress has no index form). The Phase 3.4 AC gate ticks confirmed criteria by index — repeatable and combinable in one call — so it no longer depends on hand-picking a unique prose substring per AC.

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
- **Ensure-then-apply, best-effort, post-creation.** The issue is created with **no** `--label` on `gh issue create`; the normalized labels are then ensured to exist via `ensure-label.sh` (which always exits 0) and applied through the shared REST `apply-labels.sh` helper (`POST .../issues/{n}/labels`, repo-scope only — not `gh issue edit --add-label`'s org-scoped GraphQL path) per filed issue. A label hiccup is logged to stderr and a `Devflow Reflection` note, never allowed to block or unwind the filing — mirroring the post-creation label-apply idiom Phase 3.1 uses for the hardcoded `DevFlow` provenance label.

The reason it lives in the **skill**, not in `file-deferrals.py`, is the standing config rule: config is read through the single resolver (`config-get.sh`), never re-parsed ad hoc inside a helper — so the resolve/normalize/ensure/apply steps stay in the skill body and the deferral helper stays config-agnostic. A **hard** `config-get.sh` read failure (corrupt `config.json`, missing python3) is distinguished from an empty result: its non-zero rc is captured and recorded in a reflection, and the run continues filing the issues *without* labels rather than aborting.

This key controls **only** deferred-issue labeling. It is independent of the hardcoded `DevFlow` provenance label that retrospective detection matches literally (`lib/scan.sh`, `lib/classify-pr-kind.jq`) — that string is a constant no config key controls — and separate from the `docs.labels` docs-pass label.

## Phase 4.1 Documentation Needed enforcement: two-stage gate

Phase 4.1 (*Update Documentation*) dispatches a `devflow:docs` subagent. When the issue body names
specific files in its `**Documentation Needed**` bullet (a sub-bullet of `## Implementation Notes`
in the issue template), Phase 4.1 enforces delivery through a two-stage gate.

**The bullet is a floor, not a ceiling.** The `Documentation Needed` bullet is an *additive* floor of
mandatory deliverables — it can only *add* required files. A narrative claim that documentation is
unnecessary — including an absent, empty, or contradictory `Documentation Needed` bullet — never
suppresses the routine doc pass: the `devflow:docs` subagent still runs and updates documentation
warranted by the shipped behavior change, and the bullet is never read as a ceiling that authorizes
skipping otherwise-warranted documentation. This mirrors the Phase 2.1 authority hierarchy (the issue
narrative is a non-authoritative starting point; only Desired Behavior and Acceptance Criteria are the
decided spec). The two-stage gate described below is unchanged by this framing — it enforces the floor
of named deliverables; it does not decide whether the doc pass runs.

Path extraction is **deterministic, not LLM-interpreted** (issue #185 Addendum): a bundled helper,
`scripts/extract-doc-needed-paths.sh`, is the single extraction boundary both stages consume. It reads
the issue body, scopes strictly to the `**Documentation Needed**` bullet under `## Implementation
Notes`, and emits the recognizable file paths one per line — a token counts as a path only if it
contains `/` or ends in a recognized extension, so prose, skill names (`devflow:docs`), and paths named
in *other* sections or bullets are excluded by construction (no judgement call, and none of the
LLM-extraction drift that earlier incarnations of this gate suffered). Its behavior is verified by a
fixture-based input-shape matrix in `lib/test/run.sh` (bullet-with-paths, no-paths, absent section,
path-in-another-section-not-extracted) rather than by the shadow review.

**Stage 1 — Pre-flight briefing (before dispatch).** The orchestrator runs the helper over the issue
body and treats its output as the required deliverables. If the helper emits one or more paths, the
dispatch instruction sent to the `devflow:docs` subagent is extended with "The issue requires the
following files to be updated; treat each as a mandatory deliverable: `<path1>`, `<path2>`, …". If the
helper emits nothing **but** the issue body still contains a `**Documentation Needed**` bullet, the
orchestrator records an auditable workpad note (the skipped enforcement is logged rather than silently
disabled). When no paths are extractable the subagent receives the normal instruction unchanged.

**Stage 2 — Post-hoc diff gate (after the subagent commits).** After the subagent completes and before
ticking `Documentation`, the orchestrator **re-runs the same helper** — the single source of truth, so
the two passes can never disagree about which files were named — and checks each path against the PR's
cumulative diff:

```bash
DIFF_OUT=$(git diff --name-only "origin/$BASE...HEAD"); DIFF_RC=$?
```

Before trusting that output the orchestrator guards two fail-open inputs. It ensures `$BASE` is
non-empty by re-deriving it exactly as Phase 1.4 does — **applying Phase 1.4's non-empty fallback, not
just the config read** (the read alone returns nothing on malformed config, which would collapse the
range to `origin/...HEAD` and judge every path absent). And it reads the **exit status, never stdout
emptiness**, as the failure signal: a non-zero `DIFF_RC` (or an unfetched `origin/$BASE`) is a command
failure that says nothing about any path — the orchestrator re-fetches and retries, and if the re-fetch
itself fails it routes to Blocked rather than falling through to a path-absent verdict on a broken
command. An rc-0 result with empty stdout, by contrast, is the legitimate "none of these files were
touched" signal (the genuine absence the gate exists to catch) and is acted on as real.

Bare-filename paths (containing no `/`) are considered satisfied if any diff entry's basename matches
— for example, the diff entry `docs/DEVFLOW_SYSTEM_OVERVIEW.md` satisfies the named path
`DEVFLOW_SYSTEM_OVERVIEW.md`. (Because basename matching is intentionally lenient, issue authors should
use a qualified path — e.g. `docs/README.md` rather than bare `README.md` — when a specific file, not
any same-named file, is the deliverable.) Paths containing a `/` must appear as an exact match. If
Stage 1 extracted no paths, this cross-check is a no-op and the orchestrator proceeds directly to
applying the post-docs labels and ticking `Documentation`.

**For each absent path the orchestrator either self-heals or blocks:**

- **Self-heal:** if the correct update can be derived from the issue body's `**Documentation Needed**`
  prose, the orchestrator performs the missing update itself, records a workpad note (`Phase 4.1
  self-heal: <path> absent from diff; performed update from Documentation Needed prose`), commits with
  a `docs:` prefix, and pushes. It then **re-verifies the self-heal landed and reached the remote** —
  re-running the per-path diff check and confirming the commit and push both succeeded *and* that the
  local branch is in sync with its upstream (`git rev-parse HEAD` equals `@{u}`), so a no-op edit, a
  failed commit, or a no-op/rejected push (which leaves a still-local commit) falls through to *Blocked*
  rather than ticking `Documentation` over a deliverable that never reached the PR.
- **Blocked:** if the correct content cannot be derived from the prose (the note is insufficient), or
  the self-heal did not land per the re-check, the orchestrator does *not* tick `Documentation`. It
  routes to `--status Blocked --reflection-kind blocked` with a reflection naming the missing path
  (`Phase 4.1: Documentation Needed file content cannot be determined for <path> — the docs subagent
  did not update this file and the correct content cannot be derived from the issue body; update
  manually and re-run Phase 4.1`) and emits the 👎 outcome reaction.

The post-docs labels (`docs.labels`, default `Documented`) are applied only after Stage 2's gate has
passed — every named deliverable satisfied, or Stage 1 found no paths — and only when the docs pass
itself succeeded. A run that routes to Blocked stops before this point, so a Blocked PR never carries
the `Documented` label that would mislead downstream docs automation.

The two-stage gate closes a silent-miss class: prior to this change, if a docs subagent missed a
named deliverable, Phase 4.1 ticked `Documentation` without any cross-check and the gap was only
visible to a human reading the PR diff.

## Scope boundary between Phase 2.3.2 and Phase 4.1

The 2.3.2 stranded-dependents sweep covers references in **code, config, and routing tables** — things
that break behavior at runtime if left dangling (a surviving `href` to a deleted page, a call site
still passing dead arguments). It does **not** cover prose references to the deleted symbols/paths
inside `docs/internal/` (descriptions, walkthroughs, install steps). Those are handled by the Phase
4.1 documentation pass, which spawns the `devflow:docs` subagent after the code is committed. If a
2.3.2 grep turns up only docs hits, the skill notes them and moves on rather than editing
`docs/internal/` from Phase 2.3 — the docs pass has the full picture (shipped code, not just the
plan) and the right mandate to update prose.
