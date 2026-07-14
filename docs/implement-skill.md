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
| 2.3.0c Operand-trace | a change that **adds a guard, predicate, validator, or coverage invariant** in code, **or** ships **agent-executed imperative prose stating a policy** (a `SKILL.md`/`phases/*.md` command block) | a guard whose comparand comes from the diff's *own* code (the blind spot 2.3.4 carves out and 2.3.0a/2.3.0b's peer/enum focus misses), and a stated policy whose operand no step produces (an inert guard). Trigger (a) demands a four-column operand table — comparand, producer (file+line), emitted on every selected path?, and the load-bearing *what OTHER inputs produce the same value?*; trigger (b) demands every policy name its observable operand, its producing step, and a route for every outcome including failure |
| 2.3.1 Orphaned-setup | a **deletion** of code | setup lines (a dependency fetch, lookup, computed local, import) whose only consumer was the deleted code |
| 2.3.2 Stranded-dependents | a **deletion** of a method, file, route, or page | references *outside* the diff the deletion stripped of purpose (callerless public methods, dead args, surviving inbound links) |
| 2.3.3 Convention-compliance | any code the diff **added or modified** | `CLAUDE.md` convention violations in touched code |
| 2.3.4 Boundary-assumption | any diff that **depends on** a fact about something it does not own | claims about a dependency version, the supported runtime, a sibling producer's output, the real host, or an **external tool's output string/message/exit code** that were asserted from memory instead of verified — the external-output kind carries a reproduction obligation (paste the observed bytes; doc prose is not evidence) and the companion outcome-verification rule (a precondition check never stands in for verifying the consumed outcome). In-diff guards carved out here route to **2.3.0c** |
| 2.3.4a Self-authored-claim reconciliation | any diff that **authors** a behavioral claim in prose — internal/external docs it edits, or code comments it adds/changes | a sentence or comment that asserts what the shipped code does but contradicts the actual code path (including the diff's *own* new code, which 2.3.4 carves out) — caught by tracing each authored claim to the code, following dispatch into pre-existing helpers the diff calls |
| 2.3.5 Simplification & Efficiency | any code the diff **added or modified** | avoidable complexity (redundant/derivable state, copy-paste variation, deep nesting, dead code) and wasted work (redundant I/O or computation, needless sequential ops, hot-path/startup cost) that only show up once the change is assembled |
| 2.3.6 Error-handling & silent-failure | any code the diff **added or modified** | silent failures — swallowed or over-broadly-caught errors, unjustified or fail-open fallbacks, mock/stub leaks, generic/misdirected breadcrumbs, plus two fail-open guard classes mirrored from the reviewer extension: the **existence-standing-in-for-outcome** shape (verify the outcome, not the precondition) and the **un-guaranteed-tool derivation** shape (a value that decides a selection or an emission must not be derived through a tool the project's preflight does not guarantee, cosmetic sanitization excepted when it fails closed) — all shipping clean because the happy path works and only firing on an input the tests don't exercise |
| 2.3.7 Collection-cardinality | a change that **adds a collection output with ordering, dedup, or aggregation logic** (a sorted list, deduped set, grouped/counted tally, tie-broken ranking) | a cardinality-sensitive output shipped with only a single-element test, which exercises no ordering/dedup/aggregation logic — closed by a multi-element test case (order-sensitive elements + collapsing duplicates) that would catch a wrong sort key, mis-keyed dedup, or off-by-one tally. Trigger-gated, **not** one of the five always-on sweeps |

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
numbered 2.3.0a (not renumbering 2.3.1–2.3.6) for the same presentational reason the higher-numbered
sweeps (2.3.6, then the trigger-gated 2.3.7) are appended rather than renumbering their predecessors.

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

**2.3.6** front-loads the Phase 3.3 `silent-failure-hunter` review agent the way 2.3.5 front-loads `/simplify`. Its defect class — a swallowed error, an over-broad `except`/catch, a fallback that masks a failure (or fails *open*, defaulting an error to a success-shaped value), a mock/stub leaking into production, or a generic/misdirected breadcrumb — has no home among the other sweeps: it isn't a contract change (2.3.0), a deletion (2.3.1/2.3.2), or, in general, a documented `CLAUDE.md` rule (2.3.3), and it only sometimes doubles as a boundary claim (2.3.4) or added complexity (2.3.5). Baseline testing of the implement skill confirmed the gap: capable agents running 2.3.0–2.3.5 caught these defects only when they happened to overlap another sweep's trigger, attributed them inconsistently, and missed a pure swallow (a `gh … 2>/dev/null || true` that printed success for a comment that never posted) outright — exactly the findings `silent-failure-hunter` then raised in Phase 3.3. Making it an always-on, explicitly-named sweep gives the class a deterministic home so it is caught at implement time, not a review iteration later. It is a *correctness* sweep numbered to avoid renumbering its predecessors — the later trigger-gated 2.3.7 is appended after it under the same presentational convention; each sweep's intro references "2.3.0–2.3.N" of the lower-numbered sweeps, so the ordering is presentational, not an execution dependency. The sweep also carries a **per-branch-breadcrumb** sub-check: for any multi-branch no-op path the diff adds (e.g. "if A, stop; else find B; if B absent, stop"), it confirms each branch emits a distinct diagnostic naming which condition fired — two failure modes converging on one shared breadcrumb is flagged, a variant of the misdirected/generic-breadcrumb kind.

**2.3.7** (collection-cardinality) is trigger-gated, not one of the five always-on sweeps: it fires only when the diff adds a **collection output whose value depends on cardinality** — a sorted list, a deduped set, a grouped/counted tally, a tie-broken ranking. That logic is invisible to a single-element test (one element is already sorted, already unique, already its own tally), so a green happy-path test with one input exercises neither the ordering comparator, the dedup key, nor the aggregation step, and a wrong sort key / mis-keyed dedup / off-by-one tally ships clean until a `pr-test-analyzer` review agent or a two-element production input hits it. The sweep requires a **multi-element** test case (order-sensitive elements plus collapsing duplicates) — a single-element happy-path test does not discharge it; where no automated test can drive the output, the obligation becomes the Phase 2.4 adversarial dry-trace over a multi-element input. It provenance-traces to the recurring missing-multi-row-test class (PR #468's `demoted[]` ordering/dedup behavior had no test until a review agent flagged it), the same way 2.3.6 homes the silent-failure class.

**2.3.0c** (operand-trace) sits with the additive 2.3.0a/2.3.0b family but targets a different blind spot: an operand nobody traced to its producer. Its code trigger owns exactly the diff's *own* guards that 2.3.4 carves out (2.3.4 verifies boundaries the diff doesn't own; 2.3.0a/2.3.0b watch peer sites and enumerated sets, not the operand a single guard reads), demanding a four-column operand table whose load-bearing fourth column asks *what OTHER inputs produce the same value?* — the "what else exits 2?" question that, unanswered, let a marker-deletion guard read `python3`/argparse/unopenable-script's shared exit-2 as "no workpad." When the comparand is *derived* (piped through a helper, a parse step, a subprocess, or any pipeline rather than read as a plain literal), the row additionally enumerates the malformed/empty arms the producer can emit — producer failure, unparseable output, wrong-type, valid-falsy/empty, missing key or file (the `CLAUDE.md` six-shape adversarial matrix) — and states the guard's decided behavior on each; a derived comparand with any arm left unenumerated fails open on exactly the malformed input the sweep exists to surface. Its prose-policy trigger fires on agent-executed `SKILL.md`/`phases/*.md` command blocks: a policy stated against an operand no step produces is an inert guard that silently no-ops on exactly the input it was written to gate, so every stated policy must name its observable operand, its producing step, and a route for every outcome including failure — **and place that obligation at the execution point it gates**, carrying at most a cross-reference from a thematic section, because thematic-only prose leaves the enforcement point with nothing to execute and the policy no-ops where it was meant to fire.

**Phase 2.4** splits the "no automated test" verification by one question — *does this text enter a model's context as instruction?* Human-read prose keeps the adversarial dry-trace; prose that becomes an agent's prompt (an injected block, a composed prompt, a `SKILL.md`/`phases/*.md` command block) gets a `writing-skills` subagent RED/GREEN micro-test with a no-guidance control, because a dry-trace cannot catch a prompt-prose defect — the text reads perfectly while steering the model wrong. The trigger is what the text *becomes*, never where the file lives (a block in a script or workflow YAML that becomes a prompt still takes the micro-test).

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

The five boundary kinds and how to verify each are in the skill (and summarized in the table above).
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
never ran, so the human reviewing the run cannot tell it executed. It also carries a **mirror-fact
drift-proofing** clause: any comment the diff adds or changes that carries an exact count, an enumerated list
of sites/values, or a predicate-restating scope word is rewritten or removed per the §2.3 authoring
treatments before commit — even when it is currently accurate — because an accurate-today mirror-fact comment
is precisely the one that silently rots once a later change updates the code and not the comment.

## Review-engine hardening: forced operative-sentence pin note + inline-review observability backstop

Two guards close gaps the review surface let ship "green" and only a blinded shadow pass (or nothing) caught.

**Evidence-based behavioral-fix pin (Phase 2.3 + review-and-fix Step 3).** The behavioral-fix-pin
discipline — pin the *operative* sentence whose removal *alone* re-introduces the bug, never an adjacent
*framing/justification* clause — was advice a fix-iteration author could quietly violate by pinning the
nearest unique literal instead (the recurring framing-only-pin class behind PRs #173/#171/#167). Issue
#375 replaced the earlier *substring-attestation* note (which merely asserted "the pin literal is a
substring of the operative sentence" — unfalsifiable self-testimony) with an **evidence** record: a
behavioral-fix pin is expressed through **`assert_pin_red_under <name> <literal> <mutation> [file]`** (the
mutation-taking removal-proof assertion in `lib/test/run.sh`), passing a `sed -E` mutation that
re-introduces the named bug by deleting *only* the operative sentence, and the workpad `--note` records
**the mutation you ran and the pin you observed go RED** under it. Unlike `assert_pin_red_on_removal`
(whole-line deletion, which reports `PASS->FAIL` for *any* present-and-unique literal — framing or
operative alike), `assert_pin_red_under` reports a framing-only pin **RED** when it survives the operative
mutation, so the operative-vs-framing distinction is enforced mechanically rather than by author
diligence. The requirement lives at three co-equal homes — `phase-2-implement.md` §2.3 (the implement-path
author), `skills/review-and-fix/SKILL.md`'s Step 3 mutation-check step (the fix-loop author), and
`.devflow/prompt-extensions/implement.md` (this repo's operative policy) — and is scoped to
**behavioral-fix** pins only, never to literal-constant, token-name, count-based, or absence pins where no
operative-vs-framing distinction exists. Two mechanical suite guards (`lib/test/pin-corpus-lint.py`,
self-scanned by `lib/test/run.sh`) now catch the two blind spots the parents (#370/#371) had to
rediscover in a shadow: a **pin-in-comment lint** (a pin literal that also appears in a comment of its own
target inflates the count) and a **wrapped-literal meta-guard** (a phrase assembled from wrapped adjacent
string literals lives on no single line, so a line-based `git grep` misses it — pin the rendered
`--help`/stderr surface instead).

**Inline-review observability backstop (Phase 3.3).** `review-and-fix`'s Loop Exit is what normally
persists a run's effectiveness record (`.devflow/logs/efficiency/<slug>-<run-id>.json`) and durable
workpad copy, derived from its per-iteration `iter-*.json`. But Phase 3.3 drives that loop **inline in the
orchestrator's context**, and a dropped Loop Exit then leaves those artifacts unwritten — the run
contributes nothing to `.devflow/logs/efficiency/`, which is `review-and-fix`'s own #1 documented "Common
Mistake," unguarded at this seam. So after the inline `review-and-fix` invocation returns — regardless of
verdict — the orchestrator deterministically runs the existing `lib/efficiency-trace.sh --persist` Layer-3
backstop (idempotent: it never re-derives an existing record, and with no `--workpad-dir`/`--slug` it
scans every run-scoped dir, which is exactly the "the orchestrator does not hold the loop's internal
slug/run-id" case). When even `--persist` has no `iter-*.json` inputs — the inline loop wrote no
per-iteration workpad this run, so the telemetry is genuinely lost — the orchestrator records a
`dropped-failed` reflection naming the gap rather than letting it vanish silently. The "no inputs"
detection is **this-run-scoped**: the orchestrator snapshots the pre-existing `iter-*.json` set
*before* driving the loop and, after, records a loss only when no *new* `iter-*.json` appeared
(`comm -13` against the snapshot). This matters on the local/interactive tier, where `.devflow/tmp`
persists across runs — a whole-tree presence check would let a prior run's leftover mask a genuine
loss. If the snapshot itself is missing, the detector degrades to whole-tree presence and emits a
distinct `::warning::` naming that degrade, since it can then mask a real loss behind a leftover
file. The backstop also catches the sibling failure mode where the loop *did* write `iter-*.json`
but `--persist`'s own record derivation/write step then failed silently (rc 0 by design): it
captures the invocation's stderr and greps it for `--persist`'s own `record not written`
breadcrumb (jq/mkdir failures) **and** its differently-worded disk/permission write-failure
breadcrumb — a single-literal grep would silently miss the latter — recording a second
`dropped-failed` reflection when either fires. The surface it does **not** cover is the
telemetry-branch write/push itself (`::warning::telemetry-branch: …`). The record is staged under
gitignored `.devflow/tmp/`; post-#469 a **degraded** branch write (or a CI staging-only run)
**retains** that staging root (only a *clean* write deletes it), bounded by a newest-N prune on the
next `--persist`; a *degraded* write additionally emits one `::warning::` naming its **absolute
path**, while a staging-only run retains silently, so on a **local**
filesystem a failed branch write is recoverable rather than lost. On an **ephemeral CI runner** the
staging tree does not survive teardown, so recovery there awaits the forthcoming trusted
telemetry-push relay (follow-up to #469); until it lands a cloud runner's degraded/staged records are
not recoverable (coupled with `skills/implement/phases/phase-3-review.md` and
`docs/efficiency-trace.md`, which say the same). If the stderr capture itself can't be allocated
(`mktemp` fails), the backstop degrades to discarding `--persist`'s stderr entirely rather than
aborting — this disables the record-write-failure check for that run (the no-inputs case still
runs) and emits its own distinct `::warning::`, the same degrade-and-warn discipline as the
snapshot-missing case above. Because the
`APPROVE WITH UNRESOLVED SHADOW FINDINGS` path can drive a **second**, separate inline
`review-and-fix` invocation (the bounded re-review in §3.3), the orchestrator re-runs the whole
snapshot-then-backstop procedure around that second invocation too — a fresh this-run baseline
before, the persistence check after — so it is not left unguarded at the same seam. The §3.3
clause is pinned by coupled `lib/test/run.sh` removal-proof assertions (#235 finding B, extended
by the #236 review).

**The backstop detects a dropped telemetry gap; the upstream fix is to not drop it (#296).** The
Layer-3 `--persist` backstop can only recover what was *written* — so the real protection is that the
per-iteration `iter-<N>.json` emit is a **non-optional obligation on every iteration, however the loop
was executed**: whether `review-and-fix` ran as a `Skill` invocation or was **hand-run via direct
`Agent` dispatch** on a degraded path, the record is still written, and always **with the Write tool,
never a shell `>` redirect** the cloud sandbox denies into `.devflow/tmp`. A cloud `claude-code-action`
permission/sandbox denial is **not** the local-tier permission classifier and is **not** license to
leave the instrumented loop and hand-run the engine — on the implement job `Skill`, `Agent`, `Write`,
`efficiency-trace.sh`, `workpad.py`, and `config-get.sh` are all allowlisted, so the loop is navigable,
not blocked. This makes only the **effectiveness** half of the telemetry (dispatch/findings/verdicts)
recoverable on a degraded run; the **token/wall-clock cost** half is captured *live* by the loop, and
**no backstop DevFlow currently ships reconstructs it** once the loop is abandoned — so today it
carries no deterministic guarantee, only the probabilistic protection of staying on the loop. (That
is a gap in what is built, **not** a limit of the platform: issue #437 observed that the cloud
`execution_file` *does* carry the tokens, wall-clock, the dispatch roster, and cost with zero agent
cooperation, and that on the local tier the `Stop` transcript's per-message token counts are **real**
figures, not streaming placeholders — wall-clock and the dispatch roster were *not* measured locally;
see [`docs/execution-file-shape.md`](execution-file-shape.md).
An agent-independent cost floor is buildable; it simply has not been built yet.) Note the deliberate implement-vs-runner asymmetry:
the read-only `review` runner uses `--permission-mode acceptEdits`, but `/devflow:implement` does
**not** — friction at the seam is reduced by single-statement leading-token helper forms and the Write
tool for scratch, never by widening the permission grant.

## Acceptance-criteria gate: the gated `(post-merge)` tag (Phase 3.4)

The Phase 3.4 gate requires every **non-post-merge** acceptance criterion to be verified before the run
advances. A `(post-merge)` tag exempts a criterion from blocking, so the gate enforces — as engine
behavior, not advisory prose — exactly **when** that tag is permitted: **only when the criterion
genuinely requires a runtime environment that does not exist during the implement run** (a live deploy
target, a real third-party endpoint, a production data path). The observable test is whether the
verification could ever run on the orchestrator host given the right tools; if it could, it is not
post-merge. Three cases are therefore never eligible and the gate refuses the tag for them:

- **Runnable-but-blocked (local tooling/environment gap)** — a criterion verifiable on this host but
  blocked right now by a denied command, a missing build tool, an un-spawnable helper, or a failed
  restore. A tooling gap is not a runtime-environment gap; it takes the existing **`Blocked`** escalation
  path (human handoff), never a silent post-merge pass. (A *verification command* that is **not granted**
  in the run's allowlist — its direct-form invocation refused before it could run — takes that same
  **`Blocked`** path, naming `devflow_implement.allowed_tools` (and `devflow.allowed_tools` for the command
  path) as the exact remedy: grant the command so the run can verify in-env, then re-run. It is **never**
  deferred to a CI result — see *In-env verification is the gate* below.)
- **Confirmation of a self-authored claim** — a criterion whose purpose is to confirm a behavioral claim
  the PR already asserts as true. It is runnable pre-merge by construction (the claim is about the shipped
  diff), so deferring it would defer the one check that could falsify the claim; the gate refuses the tag
  regardless of stated reason.
- **Self-reconfiguration verification** (issue #338) — a criterion whose only unmet precondition is the
  orchestrator's own session/harness/account being in the configuration the diff just shipped (a hook the
  diff registered now active, a flag/setting the diff added now enabled). The host *can* become a fresh or
  child session with the change active, so it is runnable pre-merge and never `(post-merge)`: it is run and
  evidenced — by an automated test driving the now-active code path, or by a separate/fresh session
  observing the change live — or it takes the **`Blocked`** path. Evidence produced while prototyping is
  captured in the workpad and PR body rather than re-deferred; the rule never mandates activating a
  blocking hook mid-run in the orchestrator's own session.

This is the gate enforcing "verified before merge" rather than trusting the run's narrative: a local
tooling gap can no longer be laundered into a post-merge pass, a self-claim confirmation can no
longer be deferred past the one test that would catch it, and a self-reconfiguration check can no longer
ride a "cleanest in a fresh session" rationale into an unchecked post-merge deferral. To keep every mid-run
`--rewrite-ac` retag auditable, `workpad.py` structurally rejects a `--rewrite-ac` call that appends the
`(post-merge)` tag (a single pair or a crafted multi-pair sequence) without a non-empty `--note` rationale
(issue #338). (The Phase 2.2.5 `--replace-acs-file` wholesale channel is a deliberate, known exception.)

### In-env verification is the gate — CI is never an in-run verification channel (issue #405)

A **verification-command** acceptance criterion — one whose verification is *running a test/lint/build
command* (the project's test suite, `shellcheck`/`ruff`, a `pytest`/build invocation) — is satisfied
**only by an in-environment observed pass**, on both the local and cloud `/devflow:implement` tiers. The
run executes the command **in its own environment** and ticks the criterion on the pass it observes there.
It **never waits on, polls, re-checks, or cites CI** for its own progress, and ticks nothing on a CI
result. CI (for this repo, the `lib + python tests` job) is the **required post-PR check that gates the
human merge** — not a channel the run reads to verify itself.

The command is invoked by its **direct leading-token** form (`lib/test/run.sh`, not `bash lib/test/run.sh`
— the `bash <path>` wrapper is deny-floored and can never be granted), which resolves because the
suite/lint commands are granted through `devflow_implement.allowed_tools` (and `devflow.allowed_tools` for
the `/devflow:*` command path). This repo grants the three direct forms — `Bash(lib/test/run.sh:*)`,
`Bash(lib/preflight.sh:*)`, `Bash(shellcheck:*)` — under both keys. The three outcomes at the Phase 3.4
gate:

- **In-env pass** — the command ran and passed here; tick the criterion on that observed result.
- **In-env failure** — the command *ran and failed*; that is a real failure, not a deferral: fix it or
  take the **`Blocked`** path. Never `(post-merge)` it.
- **In-env run denied** — the direct-form command is **not granted** in this run's allowlist, so it was
  refused before it could run. Take the **`Blocked`** path naming `devflow_implement.allowed_tools` (and
  `devflow.allowed_tools` for the command path) as the remedy, then re-run. Never launder a denied
  verification command into a `(post-merge)` retag or a CI observation — never a silent stall, never a
  verdict resting on a CI result the run never saw.

**Consumer rule.** List your repo's test/lint commands in `devflow_implement.allowed_tools` (and
`devflow.allowed_tools` for the command path) and the run verifies them in-env; leave them ungranted and a
verification-command AC goes **`Blocked`**, its message naming `devflow_implement.allowed_tools` as the
exact remedy. See [`cloud-setup.md`](cloud-setup.md#extending-the-tool-allowlist) for the config surface.
The shared review engine, executed inline by Phase 3.3, takes its **test evidence from the orchestrator's
own in-env suite/lint results** for the current HEAD — never a CI conclusion. (The read-only `review`
runner is a separate, unchanged case: its wait-for-CI-then-review posture is the correct *post-PR*
sequence.)

**Documentation-AC deferral (Phase-4.1-owned, distinct from `(post-merge)`).** A criterion whose
satisfaction is a *documentation edit that Phase 4.1's `devflow:docs` subagent owns* — a `docs/…`
deliverable that pass authors, rather than a `skills/`/`scripts/`/`lib/`/test change this phase can make
now — is **left unticked at the 3.4 gate, recorded in a workpad deferral note naming the AC (`3.4: doc-AC
deferred to Phase 4.1: {AC text}`), and does not block the gate**. This is deliberately not the
`(post-merge)` channel (reserved for genuinely-live verification the host can never run in-session): a
doc-AC is fully dischargeable *in this run* by Phase 4.1, so it is neither retagged `(post-merge)` nor
routed through the gate's "satisfiable with a small follow-up edit — do it now" channel, whose remediation
explicitly excludes doc authoring owned by Phase 4.1. The deferral keeps docs Phase-4.1-authored (it does
not weaken Phase 2's docs-ownership rule) while stopping the gate from forcing doc authoring into Phase 3
to satisfy a criterion Phase 4.1 owns. Phase 4.1 **must** discharge each such deferred doc-AC and tick it
(citing the deferral note) before the §4.3 terminal `--status Complete` write — see the Phase 4.1 gate
below; an undischargeable doc-AC routes to the existing `Blocked` path, never to a silent Complete.

**Pre-merge probe contract.** Passing the genuinely-live test is necessary but not sufficient: a
criterion whose *verification* needs a runtime environment can still carry a **pre-merge-observable
precondition that is already false**, and a `(post-merge)` tag means "the live check can't run until after
merge **and everything observable now has been checked**" — not "the criterion is deferred unexamined."
So before any `(post-merge)` tag or retag lands (whether at Phase 1.2 parse time or retro-tagged here),
the run must decompose the criterion into **(a) pre-merge-observable preconditions** — remote
configuration readable via read-only `gh api` reads (repo settings, a ruleset's required checks and
bypass-actor list, branch protection), static properties of the shipped files (a workflow's declared
`permissions:` / token wiring, a config key's presence) — and **(b) the genuinely-live residue** only a
merge/deploy/live-CI run can produce; probe every (a) precondition read-only (folding in any failure mode
the linked issue's Potential Gotchas / Implementation Notes name for that mechanism); and record each
probed precondition, its probe command, and its observed result in the deferral `--note` (or the explicit
finding `"no pre-merge-observable precondition"` — an empty set is legal, a *silent* deferral is the
defect). A probe whose observed result shows the deferred live verification cannot succeed as shipped
routes to a pre-merge fix or the `Blocked` path — **never** a deferral. A *denied* probe (classifier /
sandbox refused it, or the API returned an auth/permission error so state was unreadable) is recorded as
denied and the deferral proceeds; the two are told apart by whether the probe obtained a definitive answer
about the precondition, not by raw exit status — a `gh api` **404** (object observably absent) or **200
with falsy data** (empty required-checks array, absent bypass actor) is **observed-false**, not a denial.
A passed probe only *narrows* the deferral to the genuinely-live residue; it never ticks the AC box. The
contract lives in `skills/implement/phases/phase-3-review.md` and is the single source of truth for both
the Phase 1.2 tag-time path (`skills/implement/phases/phase-1-setup.md`) and the Phase 3.4 retro-tag path.

## Phase 4.3 finalize: publish vs. draft (`implement_pr_state`)

Phase 4.3 (*Finalize the PR and Finalize Workpad*) is where a run ends. It runs three things in order:

1. **Clean-tree backstop (unconditional).** `git status --porcelain` must be empty before finalizing. The run started from a clean base-branch checkout, so anything dirty here is this run's own work an earlier phase failed to commit — it is committed with the right prefix and the under-committing phase is recorded in `Devflow Reflection`, never papered over. This runs in *both* the publish and draft cases; it is independent of the publish decision.
2. **Publish decision.** By default the run publishes the draft PR created in Phase 3.1 by running `gh pr ready`.
3. **Workpad finalization.** `Status` flips to `Complete` (🎉), the final `## Progress` item is ticked, and the 🎉 outcome reaction is emitted on the triggering comment — in both cases. The final-item tick is a `--tick-progress` substring match against the `## Progress` "PR marked ready" row; if that label has drifted (or was already ticked on a resumed run) the tick is a *volatile* miss — the `## Progress` section is still present, so the call still flips `Status` to `Complete` and writes its note but **exits non-zero** rather than aborting. The finalize must consume that exit code (per the failure-isolation contract below): a non-zero finalize means the box is still `- [ ]` and the row must be re-resolved and re-ticked before the run is treated as cleanly Complete.

**Terminal self-record gate on `--status Complete`.** Because Phase 4.3 is the deterministic chokepoint where a run flips to `Complete`, `workpad.py` reconciles the workpad self-record against reality on every `--status Complete` write (`_terminal_complete_gate`, issue #258), running *last* over the post-mutation sections so a call that ticks the final AC row and flips to `Complete` in one shot still passes. Its three outcomes:

- **Hard-fail (structural abort, no PATCH).** If any **non-post-merge** `## Acceptance Criteria` row is still `- [ ]`, the finalize aborts before any PATCH and `Status` is *not* flipped — the run is not allowed to record itself Complete over an unmet AC. The stderr names each offending row (`refusing to finalize Status: Complete — … Acceptance Criteria row(s) still unticked`). `(post-merge)` AC rows are excluded, byte-for-byte the Phase 3.4 exclusion. The Phase 3.4 gate should already have ticked every non-post-merge AC, so this fires only on a drift; the fix is to tick the outstanding AC once its work is real (`--tick-ac-n`) or take the Blocked path, then re-issue the finalize — never a verbatim retry.
- **Non-blocking warning — unticked `## Plan` rows.** A still-unticked Plan row only warns (a genuinely dropped/superseded step may honestly stay unticked); the finalize still succeeds. Phase 3.5 ticks the versioning and final-suite Plan steps (which complete in Phase 3, so the Phase 2 tick loop never reaches them) precisely so this warning fires only on a real drop. (The versioning step commits the repo's version artifact — for this repo the `.changeset/*.md` file that the merge-time `version-consolidate` Action later consolidates into a bump + `CHANGELOG` entry, not an in-PR version bump.)
- **Non-blocking warning — un-mirrored AC placeholder.** If the `## Acceptance Criteria` section still holds the un-mirrored `new-body` placeholder (AC-mirroring never ran, so the checkbox scan has nothing to check and the hard-fail is vacuously satisfied), the finalize warns and succeeds — the self-record was never populated, so investigate the mirroring rather than trusting the Complete. A genuinely AC-less issue carries the *distinct* `_(none provided in issue body)_` sentinel and is unaffected.

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
- **Phase 4.1 post-subagent re-anchor (`skills/implement/phases/phase-4-documentation.md`).** After the Phase 4.1 `devflow:docs` subagent returns and its docs are committed, the orchestrator re-`Read`s `phases/phase-4-documentation.md` (via the same portable `${CLAUDE_SKILL_DIR:-…}` skill-directory anchor the entry-gate uses) before §4.2, re-anchoring the remaining §4.2/§4.3 procedure that a long context-isolated subagent return may have evicted from the working set. It is scoped to **subagent** returns — here, the Phase 4.1 docs subagent; the Phase 2 and Phase 3 subagent returns carry their own phase entry-gate reads. A **Skill-tool** return is covered by the separate generalized re-anchor below.

Both are prose contracts, so their automated boundary is a coupled pin assertion in `lib/test/run.sh` (the same RED/GREEN mechanism the engine uses for skill contracts): each **operative** clause carries an `assert_pin_unique` presence pin (exactly-once) *and* an `assert_pin_red_on_removal` proof that it flips RED against the un-pinned source; the section heading is pinned presence-only. The always-loaded orchestrator also repeats the Phase 4.1 re-anchor *trigger* in its Phase 4 section (the phase file carries the operative instruction, but the trigger to re-read survives the subagent-return eviction only if it lives in the always-resident body), and the terminal-status self-check binds every termination path — not only a deliberate wrap-up — so a run that simply halts at "documentation done" without concluding is still caught. To make that binding checkable rather than merely stated, the orchestrator must **read the live workpad `Status` line immediately before emitting any run-final message** — from the comment, not from its memory of where the run got to — and conclude only when that line reads a terminal value.

### Nested-skill tail-call guard (Skill rule, completion re-anchor, and `CLAUDE.md` carve-out)

The Phase 4.1 re-anchor above generalizes into a broader guard against a *nested `Skill` tail call* stopping the run early (issue #366). A nested `Skill` runs as a tail call, so an interactive skill's terminal "ask the user / apply with approval" step becomes the *run's* terminal step, stalling the run mid-phase with the workpad frozen at an in-progress `Status`; a non-interactive nested skill can instead complete cleanly but leave the phase continuation evicted from the working set. Three coupled clauses in `skills/implement/SKILL.md` (all in the always-resident orchestrator body, pinned in `lib/test/run.sh`) close both variants:

- **Exhaustive, exclusionary Skill rule.** The *only* skills the orchestrator may invoke via the Skill tool are `simplify` and `review-and-fix` (code review) and `pr-description` (PR documentation). Any approval-gated or interactive skill — one whose procedure ends in an "ask the user" / "apply with approval" step (e.g. `claude-md-management:revise-claude-md`, the `superpowers` `brainstorming` skill) — must **never** be invoked from inside an autonomous phase, generalizing the existing precedent that the autonomous run does not invoke the full interactive `/devflow:create-issue` pipeline. This clause prevents the *observed* incident: an interactive skill stalling mid-procedure awaiting approval, a point no completion-anchored re-anchor can ever reach.
- **Nested-skill completion re-anchor.** After completing any nested skill's *procedure* (anchored on completion of the nested procedure, **not** on the `Skill` tool call's immediate return — that return is merely the loaded skill body the orchestrator then executes over later turns), and before any other action, re-`Read` the current phase file and resume the interrupted step, **never re-invoking the nested skill** (the same idempotency clause the Phase 4.1 re-anchor carries). This closes the *latent* variant where a non-interactive nested skill completes but the continuation was evicted. It lives in the always-resident body for the same eviction-resistance reason.
- **`CLAUDE.md` edit carve-out.** `CLAUDE.md`'s Conventions section mandates `revise-claude-md` / `claude-md-improver` for `CLAUDE.md` edits, but invoking either mid-run would reproduce the very stall the exclusionary rule prevents. So any `CLAUDE.md` edit an autonomous run is *required* to make — by a Phase-3 review finding **or** by the issue's own acceptance criteria — is made **directly by the orchestrator**, citing the carve-out and recording it in the workpad; interactive/human sessions still use `revise-claude-md` / `claude-md-improver`. This is one half of a coupled pair with a matching Conventions bullet in `CLAUDE.md`, kept in lockstep.

### The Skill tail-call hazard, and the three cross-phase rules that contain it (issue #362)

The two guards above catch a run that *under-completes* Phase 4. A distinct failure kills a run outright, anywhere in the lifecycle: **a mid-phase Skill-tool invocation is a tail call, not a subroutine call.** The nested skill's body arrives as a new instruction gradient, so when that skill's own procedure ends in a user-facing report or approval step, the implement run ends *with* it — the workpad freezes at an in-progress `Status`, no terminal reaction fires, and nothing announces the death. (Observed on issue #356: the run invoked `claude-md-management:revise-claude-md` mid-Phase-3.3 and died on that skill's final approval step. The terminal-status self-check above cannot fire, because the resident instruction gradient at that moment belongs to the nested skill, not the orchestrator.) Three always-resident cross-phase rules in `skills/implement/SKILL.md` contain it — always-resident because a Skill-return eviction can strike in any phase, and only the resident body is out of its reach:

- **Subagent path for interactive skills (the Skill rule).** A mid-run edit that project conventions route through an *interactive* skill — any skill whose procedure ends in a user approval step — is performed by dispatching that skill inside a context-isolated **Agent-tool subagent** whose prompt pre-grants the approval, never by invoking it through the Skill tool mid-phase. The subagent absorbs the nested instruction gradient and hands control back. `simplify`, `review-and-fix`, and `pr-description` stay direct Skill invocations precisely because none of them ends in a user approval step. The rule is phrased repo-agnostically (the orchestrator ships to consumer repos); this repo's own instance of it lives in `CLAUDE.md`'s "Updating `CLAUDE.md`?" convention, which names `revise-claude-md` as the interactive skill to dispatch that way.
- **Generalized mid-phase re-anchor.** After **every** Skill-tool return mid-phase — not only the Phase 4.1 docs subagent — the orchestrator re-`Read`s the current phase file and resumes at the step immediately following the invocation, never re-dispatching the skill that just returned. This is the same eviction defense as the Phase 4.1 re-anchor, generalized from one subagent return to every nested-skill return; the older rule remains, now scoped to *subagent* returns.
- **Non-interactive self-answer rule.** On the cloud tier (`GITHUB_ACTIONS` set) there is no user to answer a nested skill's question, so asking one strands the run. The orchestrator answers such a question itself on the user's behalf — the issue description is the primary guide, the workpad `## Plan` and `## Acceptance Criteria` secondary — records each self-answered question and its answer via `--note`, and continues the nested procedure. An interactive local run still asks the user. The rule reaches **only** questions a nested skill directs at the user: it never answers the issue's own open questions, and a workpad `Blocked` pause stays a pause.

### Local-tier Stop-hook backstop (`lib/implement-stop-guard.sh`)

The workflow-level stall backstop below is **cloud-only** (a `Stop` hook does not exist there — `claude-code-action` discards `.claude/`), so an unattended *local-tier* run that dies mid-phase has no deterministic net. `lib/implement-stop-guard.sh` is that net. It is **repo-local by design**: it is wired in this repo's own `.claude/settings.json` and ships to no consumer repo.

The guard is **marker-gated**, so an ordinary session never pays for it. Phase 1.3 writes an empty run-marker `.devflow/tmp/implement-active-<issue>` the moment the workpad exists (gitignored, anchored to the repo or worktree root); the always-resident *Outcome reaction* block — which already binds every terminal `Status` transition — removes it at each of them. On `Stop`, the guard:

1. allows immediately when `GITHUB_ACTIONS` is set (the cloud tier has its own backstop);
2. globs for a marker with pure bash and **allows immediately when none exists** — this arm spawns no interpreter and makes no network call (only the one local `git rev-parse` its repo-root resolver runs), which is the property every non-implement session relies on;
3. allows when `python3` is unavailable (its own breadcrumb, not folded into the parse arm below), and otherwise parses `session_id` out of the hook's stdin JSON, allowing when the JSON is unparseable, the id is missing, or the id is unsafe as a filename component;
4. allows when this session's sentinel `.devflow/tmp/stop-guard-<session_id>` already exists;
5. allows, keeping **every** marker, when `scripts/workpad.py` itself is absent — `python3 <script>` exits 2 on an unopenable script, which is the very code `workpad.py` uses for "no workpad", so without this check a missing helper would be read as a stale marker and delete it, silently disabling the backstop;
6. otherwise reads each marker's live workpad `Status` with `scripts/workpad.py status <n>`, which is the **source of truth** — the marker only gates *whether* to ask.

`workpad.py status` routes the outcome: a `terminal` class deletes the marker and continues (self-heal, so a marker left by a killed run costs at most one query); exit 2 (no workpad) deletes the stale marker likewise; exit 1 (unreadable), exit 3 (`gh` transport/auth failure), and an unrecognized status class all keep the marker and **fail open** — the guard never blocks on a workpad it could not read. When several markers are present the first `interim` one blocks; markers after it in scan order are simply re-scanned on a later Stop event, so their self-heal is deferred, never lost. Solely on `interim`, it writes the sentinel, prints to stderr an instruction naming the issue and the interim status word, and exits **2** — the documented Stop-hook code that prevents the stop and feeds stderr back to the agent. The instruction addresses both readers: an implement run is told to return to the phase that owns the remaining work and drive `Status` to a terminal value; any other session is told to say the guard blocked the stop and simply end its turn again.

The `session_id`-keyed sentinel bounds the guard to **at most one block per session**, so a run that genuinely cannot finalize is never trapped. Every non-blocking path exits 0 with a stderr breadcrumb naming *that arm* (including a failed sentinel write, which allows rather than blocking without a bound). The hook entry in `.claude/settings.json` therefore carries a short `timeout` and — load-bearing — **no `|| true`**, which would swallow the blocking exit 2 and neuter the whole mechanism; `lib/test/run.sh` pins that absence against the guard's own command string, and drives every arm as a unit test.

### Resume detection of an existing PR (`phase-1-setup.md` §1.4)

A re-triggered run — a manual retrigger, or the stall backstop's auto-resume — may already have a feature branch and an open draft PR from its first attempt, while the local harness hands it a *fresh* worktree on a different branch. §1.4's original Signal 1 (linked worktree) would adopt that worktree's branch, opening a second branch and a second PR and silently abandoning the committed work. A **resume pre-check now runs before Signal 1**: it reads the workpad's `**Branch:**` line and queries the issue's open PRs both by head branch and by body reference (either query alone has a blind spot). When an open PR exists, the run checks out that PR's head branch — fetching it first when absent locally — and skips branch creation entirely; with several open PRs it picks the one whose head matches the workpad `Branch` line, else the newest. If the checkout is refused because the branch is already checked out in another linked worktree, the run continues in *that* worktree rather than duplicating the branch. With no workpad `Branch` line and no open PR, §1.4 behaves exactly as it did before the pre-check existed.

### Stale-checkout guard for adopted branches (`phase-1-setup.md` §1.4/§1.6, `phase-2-implement.md` §2.1)

An implement run that *adopts* a pre-existing branch (the worktree/`USE_CURRENT` path) used to perform **no base fetch** — the explicit `git fetch origin "$BASE"` ran only on the new-branch arm — so every later verification read the tree as it stood at the fork point, possibly days behind the base. The verified #325 incident: a run adopted `worktree-issue-322`, forked 43 hours before PR #319 merged, grepped its stale tree for the jq fixture that issue #322 truthfully said "already shipped in PR #319," found nothing, and recorded "Code wins: treating it as not-yet-shipped" — a **false refutation of a true claim** that re-implemented merged work into a human-resolved dirty merge (while the same run's dependency note said "#319 MERGED, safe to build on"). Four bounded rules close this:

- **Freshness guard (§1.4).** The adopted-branch arm now runs the same breadcrumbed `git fetch origin "$BASE"`, derives how far `HEAD` is behind `origin/$BASE` with `git rev-list --count HEAD..origin/$BASE` (git is preflight-guaranteed; the compare uses bash builtins per guard-class 2), and records the result in the workpad — **including the behind-by-0 case, so freshness is provably checked, not assumed.** A fetch failure on this arm records a **freshness-unverified reflection and continues** (the tree is marked unvouched); it never hard-blocks adoption, unlike the new-branch arm's `exit 1`.
- **Read-target rule (§1.6 + §2.1, coupled mirrors).** When the adopted branch is behind `origin/$BASE` — unconditionally when freshness is unverified, and equally when no freshness record exists at all (Phase 1.4's workpad write is best-effort; a missing record reads as unverified, never as behind-by-0) — verification reads that adjudicate shipped-work claims target `origin/$BASE` state (`git show origin/$BASE:<path>`), never the unfetched fork point. It governs read targets only; the working branch is instead reconciled at the **Phase 1.4 update-branch checkpoint** (see *Base-branch update checkpoints* below), and this rule (with the coherence rule) stays in force whenever that checkpoint's outcome is neither `UPDATED` nor `UP_TO_DATE`.
- **Cross-pass coherence rule (§1.6 + §2.1, coupled mirrors).** A "shipped/landed in PR #N" claim is REFUTED from tree reads only after a read-only `gh pr view N --json state,mergeCommit` confirms PR #N is MERGED **and** `git merge-base --is-ancestor <merge_commit_sha> HEAD` confirms the merge commit is an ancestor of the checkout. MERGED + non-ancestor — and every indeterminate outcome (shallow-history ancestor error, `gh` failure) — yields "checkout stale — refresh and re-verify," never "code wins." The §2.1 code-wins paragraph carries the matching qualifier: the code wins over a descriptive claim only when the code being read is verified fresh.
- **Sibling-PR annotation rule (§4.0).** When split-AC composition writes an already-shipped annotation, it must name the sibling PR **and its merge state at filing time** (e.g. "shipped in PR #N, unmerged at filing"), so a later run's verification checks PR #N's live state and ancestry (the coherence rule) instead of grepping whatever tree it holds. The parent's decided criteria remain the unreworded semantic source; the composed sibling-PR annotation is the stated, bounded exception to the 2.2.5 verbatim guarantee.

The two coherence-rule sites and the two read-target-rule sites are **coupled mirrors** (edited and pinned together per the `CLAUDE.md` coupled-invariant discipline); the change adds no helper, workflow, allowlist, or config surface — consumers inherit it through the shared skill.

### Base-branch update checkpoints (`devflow_implement.update_branch_checkpoints`)

An `/devflow:implement` run can take hours while sibling PRs merge, leaving its feature branch behind base. In a repo whose branch protection requires PR branches to be up to date before merge, the run would otherwise publish a PR on a stale branch — skipped/missing CI, and — because DevFlow's own `devflow_review.require_up_to_date` deferral is head-scoped and cannot see the *base* advancing (the known limitation in [`DEVFLOW_SYSTEM_OVERVIEW.md`](DEVFLOW_SYSTEM_OVERVIEW.md) §14) — a PR that can strand indefinitely behind a neutral "branch behind base" check. The run therefore brings its branch up to date with the configured `base_branch` at **four checkpoints**, all through one shared helper — `scripts/update-branch-checkpoint.sh` — so every state the merge gate or an auto-review consumes is current, including the terminal pushed state (up to the residual gaps §14 notes: a deferral already stranded on an earlier base advance, and a base that advances in the narrow window between the checkpoint push and the review firing):

1. **Resume/adopt (Phase 1.4).** The adopted-branch arm (every resumed run) invokes the helper immediately after the freshness record above.
2. **Pre-draft-PR (Phase 3.1).** Immediately before `gh pr create`, so the self-review and first review pass see current base.
3. **Each fix iteration + Loop Exit (`/devflow:review-and-fix` loop, `--push-each-iteration` only).** After each iteration's fix commit and immediately before that iteration's push — the helper's single push carries the fix and the base merge together — plus once at Loop Exit after the observability commit, covering the terminal pushed state of a standalone `/devflow:review-and-fix N --push-each-iteration` run (which never reaches Phase 4.3). A direct invocation without the flag never touches the base. The **`devflow_implement.*`** off-switch also governs this checkpoint inside such a standalone review-and-fix run.
4. **Pre-ready (Phase 4.3).** After the clean-tree backstop and before the publish decision; on a real merge (`UPDATED`) the run re-runs the project test suite and publishes only when it passes — and when the suite is absent, ungranted, or otherwise unrunnable on this tier, it publishes anyway and records that the merge was not locally re-verified (CI is the validating gate).

**The helper owns the whole mechanical sequence** — the off-switch read, base derivation, the pre-state guards, `git fetch`, behind-by derivation, `git merge --no-edit origin/$BASE` when behind, `git push`, and the push-race recovery arm — so a cloud call site invokes one granted leading-token command (the cloud allowlists grant no inline `git rev-list`, so the behind-by derivation and the base merge run inside the helper's own subprocess; `Bash(git merge:*)` *is* granted, but only for the agent-level `git merge --abort` the conflict contract prescribes at a call site). It is git-only plus `config-get.sh` reads (no `gh`, no `jq`), guard-class-2 throughout (every decision derives from git output, `python3`, and bash builtins). It prints exactly one machine-readable token with a matching exit code:

| token | exit | meaning |
| --- | --- | --- |
| `UP_TO_DATE` | 0 | behind-by 0; tree untouched |
| `UPDATED <n>` | 0 | merged and pushed (incl. via push-race recovery) |
| `DISABLED` | 0 | off-switch; tree untouched |
| `CONFLICT` | 2 | base merge left in progress (`MERGE_HEAD` present); conflicted paths + resolution contract on stderr |
| `UNVERIFIED` | 3 | the `base_branch` config read, fetch, or behind-by derivation failed, the tree was dirty, HEAD is detached / on no branch, or no merge base was reachable (even after the unshallow retry); nothing merged |
| `PUSH_REJECTED` | 4 | push refused twice (or a conflicted integrate); the local branch is restored to its pre-checkpoint SHA — *attempted, not guaranteed*: a failed restore keeps the token but emits a `WARNING` breadcrumb saying the tree may still carry the base-merge commit, and the call site hard-stops on that breadcrumb rather than continuing |
| `MERGE_IN_PROGRESS` | 5 | `MERGE_HEAD` existed at invocation; nothing touched |

A **`CONFLICT`** at any checkpoint is resolved *in-run*: the agent resolves the conflicts (it holds full context of its own changes), runs the project test suite on the resolved tree, commits the merge, pushes, records the conflicted files, and re-runs the Phase 2.3.0 changed-contract sweep. A resolution whose suite run **fails** is **aborted** (`git merge --abort`, restoring the pre-checkpoint tree) before the run hard-stops — the workpad `Blocked` flip when implement-driven, the loop's native "stop and report" when review-and-fix runs standalone — so a failed resolution never remains in the tree. `UNVERIFIED`/`PUSH_REJECTED` are loud but non-fatal (record and continue) — **with one exception: a `PUSH_REJECTED` whose stderr carries the failed-restore `WARNING` hard-stops too**, because the branch may still carry an unpushed base-merge commit that no clean-tree backstop can see (the divergence is in committed history); **`MERGE_IN_PROGRESS` hard-stops** (continuing would absorb an abandoned resolution into the next ordinary commit). The shallow cloud checkout (`fetch-depth: 50`) means the helper's one `git fetch --unshallow origin "$BASE"` retry on an out-of-shallow merge base is not theoretical; the retry targets the base ref explicitly because the cloud checkout's single-branch refspec would otherwise leave `origin/$BASE` un-deepened. When even the unshallow retry cannot establish a merge base, the checkpoint degrades to `UNVERIFIED` (record-and-continue), never a bad merge.

**Config.** The off-switch is **`devflow_implement.update_branch_checkpoints`** (boolean, default `true`), read via `config-get.sh`: the checkpoints are disabled exactly when the value serializes to the string `false` — an explicit JSON `false`, or a shape `config-get.sh` serializes identically (the JSON string `"false"`, or `[false]`, since arrays comma-join); a missing config file, missing key, empty string, or any other value leaves them enabled (issue #312 valid-falsy discipline — the documented off-switch genuinely disables, and near-`false` shapes fail toward "off", the pre-feature status quo). On-by-default mirrors `stall_backstop.enabled`'s safe-direction default. A consumer repo without an up-to-date branch-protection rule keeps working unchanged apart from ordinary base merges on feature branches — and turns the whole mechanism off with one key.

### Workflow-level stall backstop (harness-side, `devflow_implement.stall_backstop`)

The two guards above are **agent-side**: they can only fire while the agent is still generating and re-enters its loop. A **cloud** `/devflow:implement` run has a failure mode they cannot reach — the headless `claude-code-action` session is single-shot, and the SDK ends the session the moment the model emits a tool-call-free turn (e.g. a narrate-and-hand-back turn right after `gh pr create`). When that happens at, say, the Phase 2→3 boundary, the agent never re-enters, so the terminal-status self-check is structurally unreachable — yet the Actions job still reports `success` (the action returns `subtype: success`, not `error_max_turns`). The run is then a green success that actually stalled mid-lifecycle, indistinguishable from a healthy one and feeding the stale-workpad retrospective gap (observed on issue #259 → PR #264 and issue #258 → PR #265).

A **workflow-level backstop** closes this, governed by two config keys under `devflow_implement.stall_backstop` (read via `config-get.sh`):

- **`stall_backstop.enabled`** (boolean, default `true`) — master switch. When `false`, the backstop is skipped entirely and the job behaves exactly as before (green on a mid-lifecycle stop). An unrecognized/missing value resolves to `true` (the safe, honest-failure direction).
- **`stall_backstop.max_resume_attempts`** (integer, default `2`, minimum `0`) — hard cap on automatic resume attempts. `0` means detect-and-fail-loud only; `N` means up to `N` auto-resumes before failing loud. A negative/non-integer value resolves to `2`.

When enabled, a post-`claude` step keys on the issue workpad `Status` (via `workpad.py status`, which reports the status as a `CLASS GLYPH WORD` line reusing the same `🚀`/`🎉`/`👎`/`💥` vocabulary — **never** on PR draft state, mirroring the agent-side self-check so an intended `implement_pr_state=draft` run that reached `Status: Complete` is never a false positive):

- **Terminal `Status`** (`Complete` 🎉 / `Blocked` 👎 / `Failed` 💥) → no-op; the job concludes normally. (`Failed` is written by this backstop's own dead-run flip below, so a re-triggered run reads it as a decided end rather than a stall.)
- **Interim `Status`** (any 🚀 phase) → auto-resume: post a distinct audit comment (attempt *k* of `max_resume_attempts`) and re-dispatch `/devflow:implement <n>` so the skill's Phase 1.3 workpad-resume continues from where it stopped, bounded by the cap.

**Denial-proof helper invocation on a resumed run (issue #405).** A resumed run — and every cloud helper invocation — must invoke bundled helpers with the **repo-relative vendored literal** (`.devflow/vendor/devflow/scripts/…`, `.devflow/vendor/devflow/lib/…`) as the command's **leading token**: never an absolute path (`/home/runner/.../scripts/workpad.py`), never the repo-root `scripts/…` form, and never behind a `VAR=value` prefix or a `bash <path>` wrapper. Each of those makes the command no longer *begin with* the granted literal, so the cloud allowlist silently denies it — and a resumed run that reaches for the absolute or repo-root form is denied on its very first `workpad.py` call and dies without resuming. The stall-backstop **resume comment now carries this discipline inline** (a `Resume note:` line in the comment body), so a resumed run receives the rule inside its own triggering comment even if it never re-reads the skill prose; the same rule is stated in the skill's always-resident orchestrator body. After two denials of a given command shape, switch to a listed legal form rather than iterating a third spelling.
- **Cap exhausted** (including `max_resume_attempts: 0`) → the job exits non-zero (red) and posts a distinct comment naming the stall for a manual retrigger.
- **Unreadable `Status`** (workpad missing / unparseable — `workpad.py status` exits 2 or 1, where exit 2 is "no workpad" and exit 1 covers both a missing/empty `Status` line and a present `Status` line whose word isn't in the canonical vocabulary (`Reviewing`/`Complete`/`Blocked`/etc.)) → fail closed (`unreadable` class) with a distinct diagnostic comment, never a false "stalled at X" claim.
- **Auth/API failure reading the workpad** (`workpad.py status` exits **3** — a `gh`-api/transport/auth failure such as an expired App installation token, reading either the workpad `Status` or the issue comment list that counts prior attempts) → fail closed (`auth-failure` class, distinct from `unreadable`) with an auth-specific diagnostic comment, and **without consuming a resume attempt** — the workpad may be perfectly healthy; only the read failed (issue #287).

**Dead-run `Status` flip → `💥 Failed` (issue #356).** On every **fail-loud** exit of the `Stall backstop` step that is reached after successfully reading a genuinely **interim** `Status` — the `fail-exhausted` arm (cap exhausted), the `mktemp` abort, the dropped-resume-comment abort, and the resume-posted-but-no-App-token abort — the step first performs a best-effort `workpad.py update <n> --status Failed --note "run died: <cause> — <run URL>"`, then exits with today's exit code. This introduces one new canonical **terminal** workpad status word, **`Failed`**, with the glyph **💥** (added to `workpad.py`'s `_STATUS_GLYPHS`; `_status_glyph` maps `failed`→💥; `cmd_status` classes it terminal; it is deliberately left out of `_STATUS_TO_PROGRESS_PHASE`, so a `--note` accompanying the flip nests under the most-recent-ticked `## Progress` phase, exactly like `Blocked`). Without this flip a dead run leaves its workpad frozen at `🚀 Implementing`, silently lying that it is still working; the flip makes the death visible in the run's own comment. The flip is guarded on the `interim` status class (a terminal/unreadable/auth-failure `Status` is never clobbered — fail closed) and is positional, not temporal: it is called only at genuine fail-loud exits, **never** on the green resume path (writing a terminal `Failed` before a resume would make the resumed run's own backstop read `terminal → noop` and disarm it). It is best-effort — a flip whose `workpad.py update` fails emits a `::warning::` and leaves the step's exit code exactly what it is today — and stays inside the step's `set +e` discipline. **💥 is a workpad-only glyph with no triggering-comment reaction equivalent** (unlike 🚀/🎉/👎, which map to rocket/hooray/-1): the backstop emits no outcome reaction for a `Failed` flip. A `Failed` workpad resumes normally on a fresh `/devflow:implement <n>` re-trigger — the gate's early-acknowledgement refreshes the `Run` link and Phase 1.3's resume arm resets `Status` to `🚀 Setup`; `Failed` is not `Blocked`, so it never joins the Blocked pause branch. A dead implement run also stops masquerading as clean in the weekly retrospective: `lib/cheap-gate.jq`'s clean condition is `workpad_final_status == "Complete"`, so `Failed` (which `lib/fetch-pr-context.sh` now strips the 💥 from, like the other glyphs) gates non-clean with reason `workpad status not Complete`.

On **every** resume — whether triggered by this backstop's auto-resume, a manual re-trigger, or an external stall-backstop retry — the `gate` job's early-acknowledgement step (`Create workpad (early acknowledgement)` in `devflow-implement.yml`) deterministically refreshes the workpad's `**Run:**` link to the *current* run before handing off. When it finds a workpad already exists (`workpad.py id` succeeds), instead of only skipping the duplicate create it first runs `workpad.py update <n> --run-link "[View run](<this run's URL>)"`, so an operator watching a stalled/retried run can click through the workpad to the currently-active job's logs rather than the original run's. This write lands at the workflow (gate) level, independent of whether the subsequent `claude` job goes on to execute Phase 1.3 — so the `Run:` link stays current even on a resume that stalls again before Phase 1.3's own workpad-resume runs. It is best-effort (mirroring the create-failure path): a failed refresh emits a `::warning::` breadcrumb noting the `claude` job will refresh it in Phase 1.3 instead, then exits 0, so a workpad-update hiccup never fails the gate job or blocks the run. (The Phase 3.1 draft-PR body carries the same `[View run]` link for the run that created the PR, omitted entirely on a local-tier run where there is no Actions run URL.)

**Prevention layer (issue #415).** The backstop above is the deterministic *convergence* net; a coordinated *prevention* layer reduces how often the early-quit fires in the first place (mirroring the review tier's #408/#410 fix). **(1) Headless-wait discipline (prose).** A new always-resident cross-phase rule in `skills/implement/SKILL.md` — cloud-conditioned on `GITHUB_ACTIONS`, sitting beside the *Non-interactive self-answer rule* — tells the orchestrator this is a headless (`claude -p`) run where **ending the turn ends the process** with no re-invocation: never end the turn while any dispatched Agent-tool subagent has not returned (a Phase-2 `code-explorer`/`code-architect`, Phase-3's inline `review-and-fix` agents, the Phase-4.1 `devflow:docs` subagent), poll to keep the turn alive, and treat `ScheduleWakeup`/future task-notifications as unavailable. Its always-resident placement is load-bearing — it survives nested-skill body eviction, so it governs every dispatch point including the Phase-3 inline review pass. A one-line mirror rides inside the stall-backstop resume comment (`devflow-implement.yml`) as a second `Headless note:` line beside the #405 `Resume note:` — coupled with the skill rule in one commit and pinned in `lib/test/run.sh` — so a resumed run receives it even if it never re-reads the skill prose. It is cloud-scoped: a local/interactive run (`GITHUB_ACTIONS` unset) is untouched and `ScheduleWakeup`/task-notifications work normally. **(2) Probe-verified `ScheduleWakeup` denial.** `.github/workflows/matcher-probe.yml`'s `schedulewakeup-probe` job runs a `claude-code-action` session with `--disallowedTools ScheduleWakeup` (the tool also granted in `--allowed-tools`, so the flag under test is the only possible removal cause), has the model attempt one `ScheduleWakeup` call bracketed by two positive controls, and derives a deterministic DENIED/AVAILABLE/REMOVED/INCONCLUSIVE verdict from the execution file (never the model's text). The verdict gates whether `devflow-implement.yml`'s `claude` step ships `--disallowedTools ScheduleWakeup`: a removed/denied verdict ships the flag plus a `lib/test/run.sh` pin, a still-available verdict ships no flag and records the omission rationale on the PR — the same probe-before-grant discipline the matcher-probe corpus already uses. **Executed (issue #418):** the probe measured **AVAILABLE** across real cloud runs 29140791165 and 29138117625 (both recorded a `ScheduleWakeup` `tool_use` that was not denied; a third run, 29139012320, hit the documented compliant-model false-positive — presumptive REMOVED with both controls run — and the two positive observations are dispositive over it), so per the tool-still-available arm no flag or `--disallowedTools`-flag `lib/test/run.sh` pin shipped and the early-quit prevention rests on the headless-wait prose alone. The verdict is version-dependent — re-probe (via the `schedulewakeup-probe` job) after a `claude-code-action` upgrade before trusting it. **Implement-tier matcher probe (issue #450).** An additional sibling job in the same `matcher-probe.yml`, `implement-probe`, applies the identical execution-file measurement to the read-write `devflow-implement` tool profile — a distinct allowlist from the read-only `review` profile the existing `probe` job measures, so a command SHAPE or grant FORM proven accepted on one tier is unproven on the other. It composes `--allowed-tools` from `devflow-implement.yml`'s baked TOOLS literal (a verbatim-sync copy, pinned in `lib/test/run.sh`) plus the config extras, splitting the label-helper grants by form (explicit vendored literal for `apply-labels.sh`, `*/basename` glob for `ensure-label.sh`) so every label verdict attributes to exactly one grant form, and judges the unexpanded-anchor leading token, `for` / piped `while read` / `VAR="$(…)"` wrappers, and a positive control by matcher verdict alone. Human-dispatched only; its observed table is the implement-tier evidence of record. `matcher-probe.yml` is repo-internal and is not shipped to consumer repos by `install.sh`.

The decision itself is a pure, unit-tested helper (`scripts/stall-backstop-decide.sh`) so `lib/test/run.sh` drives every branch; the audit/fail comments go through the best-effort repo-scoped REST helper `scripts/post-issue-comment.sh` (the `ensure-label.sh`/`apply-labels.sh` always-exit-0 + stderr-breadcrumb contract), so a comment hiccup never flips a *fail* decision green; on the resume arm — where the comment *is* the action — a dropped re-dispatch comment fails the job loud (a never-posted resume must not read as green). The thin workflow-caller step (`Stall backstop`, `if: always()` after the observability-persist backstop in `devflow-implement.yml`'s `claude` job) wires these together: it reads the two config keys via the vendored `config-get.sh`, reads the workpad `Status` via `workpad.py status`, counts prior auto-resume attempts by grepping the issue's comments for the `<!-- devflow:stall-backstop-audit -->` marker each resume comment carries (the count input is CR-stripped, and a failed comment read makes the attempt count unknowable, so it fails the job loud rather than resuming unbounded past an unenforceable cap), feeds all four inputs to `stall-backstop-decide.sh`, and acts on the token. Only the resume comment carries the `/devflow:implement <n>` trigger phrase; the fail-loud comments deliberately do not (so a failed run never self-retriggers). Three boundaries govern the auto-resume in practice: a `/devflow:implement` comment authored by the built-in `GITHUB_TOKEN` does **not** re-trigger the workflow (GitHub suppresses recursive `GITHUB_TOKEN` events), so when no `DEVFLOW_APP_ID` App token is configured the step posts the resume comment and then **fails the job loud** (auto-resume is inert under `GITHUB_TOKEN`, and an inert resume must not read as green — a human re-posts the trigger, or configures the App); that App's bot login must be present in `devflow.allowed_bots` or the gate's actor authorization declines the resume comment; and the new run's `gate` dedupe must not classify the resume as a duplicate of the still-finishing original — which it no longer does: `dedupe-implement-run.sh` reads the triggering comment body from `GITHUB_EVENT_PATH` and, when it carries the `<!-- devflow:stall-backstop-audit -->` marker every resume comment writes, skips deduping so the taking-over run proceeds instead of being swallowed (issue #280, resolving the deferred #268 finding; the detection lives in the script — reading the event payload rather than a workflow-passed env — precisely so the fix needs no `.github/workflows/` change). The fail-loud + audit-comment behavior is correct regardless of all three.

## Workpad ticking: failure-isolation contract and index-based ticking

`workpad.py update` PATCHes the workpad once per call, and it distinguishes two failure classes so a batch of mutations is not lost to a single bad checkbox tick:

- **Structural failures abort the whole call before any PATCH** (exit 1, clear stderr): `gh` cannot resolve the repo, the API call fails, a target section (`## Progress`/`## Plan`/`## Acceptance Criteria`) is absent, the `Last updated` line is missing (or the `Status` line when `--status` is supplied), a `--rewrite-ac` substring matches zero or multiple rows, a `--rewrite-ac` pair appends the `(post-merge)` tag (NEW ends with it; neither OLD nor the row it targets already does) without a non-empty `--note` rationale (issue #338 — so every mid-run `(post-merge)` retag is a recorded, auditable claim; a text tweak on an already-`(post-merge)` row creates no new deferral and needs no note), or a `--replace-*-file`/`--set-reproduction-file` is unreadable. A `--status Complete` write with any non-post-merge `## Acceptance Criteria` row still `- [ ]` is also a structural abort — the terminal self-record gate (see Phase 4.3 above) — so a run can never record itself Complete over an unmet AC. A structural failure persists nothing — all-or-nothing, as it always was.
- **Volatile per-row tick misses are isolated, not aborted.** A `--tick-*`/`--tick-*-n` flag that does not resolve to exactly one tickable row *inside a present section* — a substring matching zero or multiple unticked rows, or a `-n` index that is out of range or lands on an already-ticked row — does **not** discard the call. Every other mutation (`--status`, `--note`, `--reflection`, and every tick that *did* resolve) is applied and PATCHed, and the call then **exits non-zero** with a stderr report naming each tick that did not land. So one bad tick in a batch no longer silently loses the accompanying status/notes.

A single `_report_failed_ticks` chokepoint in `scripts/workpad.py` writes the collected misses on all three exit paths — the structural-abort path, the `gh`-PATCH-failure path, and the clean-PATCH-but-ticks-missed path — so a miss is never silently dropped, and the stderr preamble states whether a PATCH was persisted so the caller can distinguish "nothing landed, re-send the whole call" from "the body PATCHed, re-tick only the named row(s)."

**Callers must check the exit code of any tick call — the printed body alone is not a success signal.** Because a volatile miss still PATCHes (and prints) the body while leaving its target row `- [ ]`, a non-zero exit from any `update` carrying a `--tick-*`/`--tick-*-n` means at least one tick did not land. This is why the Phase 3.4 gate and the Phase 4.3 finalize both gate on the exit code, not the stdout body.

**Ticking is addressable by substring or by index.** Besides the substring flags (`--tick-progress`/`--tick-plan`/`--tick-ac`), Plan and Acceptance Criteria accept a **1-based index** form (`--tick-plan-n`/`--tick-ac-n`) that counts every `[ ]` and `[x]` row within that section in document order (the index is section-scoped, not whole-document; Progress has no index form). The Phase 3.4 AC gate ticks confirmed criteria by index — repeatable and combinable in one call — so it no longer depends on hand-picking a unique prose substring per AC.

## `## Devflow Reflection`: grouped-by-kind rendering (`--reflection-kind`)

Reflection bullets are grouped by **kind** so a human triaging a DevFlow PR/issue sees the items that need follow-up separated from improvement proposals and purely informational notes, without expanding and reading a flat list. `scripts/workpad.py update` takes a `--reflection-kind {blocked|deferred|dropped-failed|improvement|issue-accuracy|note}` flag that applies to that call's `--reflection` / `--reflection-file` bullet(s); the helper — the single chokepoint every reflection flows through — owns the glyph, bold label (or none, for the glyph-only kinds), and sub-section placement, so the structure holds regardless of how the orchestrator phrases the text.

| Kind | Rendered bullet | Label? | Sub-section |
|---|---|---|---|
| `blocked` | `- ⛔ **Blocked:** …` | labeled | `### ⚠️ Action required` |
| `deferred` | `- ⏭️ **Deferred:** …` | labeled | `### ⚠️ Action required` |
| `dropped-failed` | `- ❗ **Dropped/Failed:** …` | labeled | `### ⚠️ Action required` |
| `improvement` | `- 💡 …` | glyph-only | `### 💡 Improvements` |
| `issue-accuracy` | `- 📝 **Issue accuracy:** …` | labeled | `### ℹ️ Notes` |
| `note` (default when omitted) | `- ℹ️ …` | glyph-only | `### ℹ️ Notes` |

The three sub-sections render in the canonical order `### ⚠️ Action required` → `### 💡 Improvements` → `### ℹ️ Notes`, all inside the existing `## Devflow Reflection` `<details>` block. A kind whose sub-heading already names it renders **glyph-only** (`note` under `### ℹ️ Notes`, `improvement` under `### 💡 Improvements`) — the redundant bold label is dropped (issue #476); the others keep a label because their heading does not uniquely name them (the three actionable kinds share `### ⚠️ Action required`; `issue-accuracy` renders under `### ℹ️ Notes`). Mechanics, baked into the helper:

- A sub-heading is emitted **only** when its group has ≥1 bullet (an empty group produces no heading); a second bullet of an existing kind nests under the existing heading without duplicating it; appended content stays before `</details>`.
- Sub-headings are `### ` (level-3), **never** `## ` — `lib/fetch-pr-context.sh` terminates the reflection parse at the first `## ` heading, so a level-2 sub-heading would truncate `reflections[]`. The parser captures every kind bullet (glyph, and bold-label prefix when present — a glyph-only bullet is captured identically; useful signal for the retrospective LLM, irrelevant to `cheap-gate.jq`'s non-empty check) and excludes the `### ` headings, for the grouped shape and a legacy flat block alike. The gate is unchanged: any run that left ≥1 reflection bullet is forced into LLM analysis.
- `--reflection-kind` defaults to `note`, so un-kinded call-sites degrade to the Notes sub-section — never to Action required. A single kind applies to every bullet in the call, so the orchestrator emits different kinds in separate `update` calls (this is why the Phase 4.3 `publish_failed` `dropped-failed` reflection is its own call, separate from the `note`-kind finalize). This mirrors `workpad.py`'s existing helper-owns-the-rendering-token idiom (`--status` derives and prepends the status glyph; `--note` nests under the right `## Progress` phase).
- **The Phase 1.6 issue-claim audit records clean confirmations as `## Progress` `--note`s, not reflections** — an assumption checked that held carries no friction signal, and a reflection trips the retrospective cheap gate. Only audit *findings* reflect: a wrong count/exclusion as `issue-accuracy`, punted workflow-capability work as `deferred`, a policy/dependency contradiction as `blocked`.
- **Interpolation-safe input.** `--reflection-file PATH` reads the bullet text verbatim as UTF-8 from a file (or stdin when `PATH` is `-`), bypassing shell interpolation — the recipe for reflection text containing backticks, `$`, or double quotes. The call-site recipe (in `skills/implement/SKILL.md`) authors the payload to a `.devflow/tmp/` file with the Write tool, passes `--reflection-file <path>` alongside the `--reflection-kind`, then deletes the payload after the helper call succeeds; an unreadable, undecodable, or empty payload aborts the call before any PATCH.

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
the issue body, scopes strictly to the Documentation Needed block under `## Implementation
Notes` — recognized in **any** of the three scope-opening shapes real bodies use: the template's
canonical `- **Documentation Needed** — …` list item (issue #185), a bare, blank-line-preceded
`**Documentation Needed** — …` bold paragraph with no `- ` marker (the form an LLM-drafted `##
Implementation Notes` section commonly renders, which the older `- `-required anchor matched nothing of,
silently skipping the gate; issue #309, a sibling of the #289 miss class), **or** a `### Documentation
Needed` level-3 heading (issue #380 — the form a body that renders its deliverables under a subheading
uses, the real issue #363 body, which matched nothing under the two bold openers and silently skipped the
gate). The heading opener anchors to exactly level 3 inside `## Implementation Notes`, so a deeper `####
…` heading or a bullet that merely mentions the label does not open, and any other level-3+ heading closes
an open heading-form scope so later-subsection paths never leak. The template canonically emits the
bold-bullet form; the heading form is accepted so a differently-rendered body still gates. A bold-emphasis span that only begins a wrapped continuation
line inside the bullet does not close the scope, so paths on later wrapped lines are still captured.
Two adjacent grammar shapes are handled explicitly (issue #327), both in the leak-safe direction: (1) a
top-level bold **deliverable** list after the bullet stays in scope — a backtick-led bold item
(`- **`docs/a.md`**`) is a listed deliverable, not a peer section label, so it is captured instead of
silently closing the scope to empty output (a non-backticked `- **docs/a.md**`, being indistinguishable
from a peer label, still closes — an accepted, `run.sh`-pinned tradeoff, since real deliverable lists
backtick their paths); (2) a trailing blank-line-preceded **plain-prose** paragraph (not blank, not a
list item, not bold) closes the scope so its path-like tokens do not leak as deliverables — but only
**once a deliverable has already been captured** in the scope (an `emitted` gate), so a primary prose
declaration and any intervening prose before the deliverables stay in scope. A blank-separated plain
sub-list stays in scope. The `emitted` gate arms only on a structural line (list item or bold line)
bearing a token Stage B would emit, mirroring Stage B's basename+extension predicate, so plain prose can
never arm the close — keeping the fix strictly leak-safe (it never introduces a new fail-open).
It then emits the recognizable file paths one per line — a token counts as a path only if it
ends in a recognized doc/source extension **or** names an in-tree tracked regular file (the
`[ -f ] && git ls-files --error-unmatch` rescue for extensionless real files like `Makefile`/`LICENSE`).
A bare "contains `/`" test is deliberately **not** sufficient — it wrongly emitted directory tokens
(`docs/internal`) and rooted skill-invocation refs (`/claude-md-management`, from colon-splitting); rooted
(`/…`), parent-dir-escaping (`../…`), and trailing-slash directory tokens are dropped outright (issue #254). So prose, skill names
(`devflow:docs`), directories, and paths named in *other* sections or bullets are excluded by
construction (no judgement call, and none of the LLM-extraction drift that earlier incarnations of this
gate suffered). Its behavior is verified by a fixture-based input-shape matrix in `lib/test/run.sh`
(bullet-with-paths, no-paths, absent section, path-in-another-section-not-extracted, directory-token and
rooted-token rejection) rather than by the shadow review.

**Stage 1 — Pre-flight briefing (before dispatch).** The orchestrator runs the helper over the issue
body and treats its output as the required deliverables. If the helper emits one or more paths, the
dispatch instruction sent to the `devflow:docs` subagent is extended with "The issue requires the
following files to be updated; treat each as a mandatory deliverable: `<path1>`, `<path2>`, …". If the
helper emits nothing **but** the issue body still contains a Documentation Needed section **in either
accepted form** — the bold-bullet `**Documentation Needed**` form **or** a `### Documentation Needed`
heading (the safety-net grep matches both, carrying the same `\*{0,2}` bold-tolerance as the extractor's
own opener so the two heading recognizers cannot drift) — the orchestrator records an auditable workpad
note (the skipped enforcement is logged rather than silently disabled). Matching only the bold-bullet form
here would leave a heading-form issue's empty extraction silently unrecorded — the exact #363 gap. When no
paths are extractable the subagent receives the normal instruction unchanged.

**Stage 2 — Post-hoc diff gate (after the subagent commits).** After the subagent completes and before
ticking `Documentation`, the orchestrator **re-runs the same helper** — the single source of truth, so
the two passes can never disagree about which files were named — and checks each path against the PR's
cumulative diff:

```bash
if ! DIFF_OUT=$(git diff --name-only "origin/$BASE...HEAD") \
   && { git fetch origin "$BASE" >/dev/null 2>&1; ! DIFF_OUT=$(git diff --name-only "origin/$BASE...HEAD"); }; then
  # command failure on the read AND its retry → route to Blocked, never a path-absent verdict
fi
```

Before trusting that output the orchestrator guards two fail-open inputs. It ensures `$BASE` is
non-empty by re-deriving it exactly as Phase 1.4 does — **applying Phase 1.4's non-empty fallback, not
just the config read** (the read alone returns nothing on malformed config, which would collapse the
range to `origin/...HEAD` and judge every path absent). And it reads the **exit status, never stdout
emptiness**, as the failure signal — discriminated by the single-statement `if !` guard reading git's
**own** exit status inline (never a captured `DIFF_RC` read in a later statement, which an inline-bash
runner that strips cross-statement variable reads would leave empty): a `git diff` failure (or an
unfetched `origin/$BASE`) is a command failure that says nothing about any path — the guard re-fetches
and retries, and if the re-fetch itself fails it routes to Blocked rather than falling through to a
path-absent verdict on a broken command. An rc-0 result with empty stdout, by contrast, is the
legitimate "none of these files were touched" signal (the genuine absence the gate exists to catch) and
is acted on as real.

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

**Discharging 3.4-deferred documentation ACs (before §4.3 Complete).** Any acceptance criterion the
Phase 3.4 gate deferred as Phase-4.1-owned (a `docs/…` deliverable, recorded in a `3.4: doc-AC deferred to
Phase 4.1: {AC text}` workpad note — see the Phase 3.4 gate above) is this phase's obligation to close.
Once the docs pass has run and its changes are committed, for **each** such deferred doc-AC the
orchestrator confirms the required docs actually landed in this run's diff (Stage 2 already verified the
named deliverable paths) and ticks the criterion by its 1-based position, citing the deferral note. This
tick **must** happen before §4.3's terminal `--status Complete` write, because `workpad.py`'s terminal
Complete gate hard-fails a Complete write while any non-post-merge acceptance-criteria row is still
unticked — a doc-AC left unticked would abort the finalize. A deferred doc-AC that genuinely cannot be
discharged (the docs pass could not author it and the content cannot be derived) is *not* ticked and *not*
finalized: it takes the existing `Blocked` path and emits the 👎 outcome reaction, never a silent Complete
over an undischarged doc-AC.

## Scope boundary between Phase 2.3.2 and Phase 4.1

The 2.3.2 stranded-dependents sweep covers references in **code, config, and routing tables** — things
that break behavior at runtime if left dangling (a surviving `href` to a deleted page, a call site
still passing dead arguments). It does **not** cover prose references to the deleted symbols/paths
inside `docs/internal/` (descriptions, walkthroughs, install steps). Those are handled by the Phase
4.1 documentation pass, which spawns the `devflow:docs` subagent after the code is committed. If a
2.3.2 grep turns up only docs hits, the skill notes them and moves on rather than editing
`docs/internal/` from Phase 2.3 — the docs pass has the full picture (shipped code, not just the
plan) and the right mandate to update prose.
