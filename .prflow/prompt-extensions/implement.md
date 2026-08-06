# DevFlow repo — operative policy for `/prflow:implement`

This repository is the DevFlow plugin itself. The base `/prflow:implement` skill is
versioning-agnostic and environment-agnostic by design; this extension is DevFlow's opt-in and is
the **operative** repo policy for what an implement run adds to the rules `CLAUDE.md` already
states (edit this file to change it).

## Versioning policy

**Add exactly one uniquely-named `.changeset/*.md` file for a change that reaches consumers** — a
fix, feature, or breaking change to the engine surface (`skills/`, `agents/`, `lib/`, `scripts/`,
the workflows, the config schema) — and never edit `.claude-plugin/plugin.json` or `CHANGELOG.md`
directly. Internal-only changes (tests, CI, dev-only docs) add none, and the Phase 3 review gate
FAILs an engine-surface change that carries no changeset.

**Default the `bump:` frontmatter key to `patch`.** Choose `minor` or `major` only when this
issue's body explicitly authorizes the larger step — never infer one from the change's size or
feature-ness.

**Write it after the draft PR exists but before the review pass**, named after the branch or issue
(e.g. `issue-290-<slug>.md`) so it never collides with a concurrent PR's. That way the prose can
cite the PR number and the changeset lands inside the diff `/simplify` and `/prflow:review-and-fix`
review; record the increment decision in the workpad so it survives context compaction.

**Commit-message contract (load-bearing — do not drift).** The merge-time consolidation commit's
subject begins with the literal `chore: bump version`, and `skills/docs-release-notes/SKILL.md`
Step 4b uses that prefix to confirm a bump happened, reads the authoritative version from
`.claude-plugin/plugin.json`, then assembles the dated `## [x.y.z]` CHANGELOG entry from every
pending changeset's prose. Renaming the subject makes Step 4b see no bump and silently disables
that reconciliation; the producer (`version-consolidate.yml`) and consumer are kept in lockstep by
a coupling pin in `lib/test/run.sh`.

**Step 4b legitimately no-ops during `/prflow:implement`.** The bump commit is created at merge
time on `main` rather than on the feature branch, so its `origin/main..HEAD` scan finds none — here
CHANGELOG correctness rests on the in-diff changeset prose, which the Phase 2.3.4a self-claim sweep
and Phase 4.2 keep aligned with the shipped diff.

## The project's preflight-guaranteed tool set (for §2.3.6's un-guaranteed-tool sweep)

The base skill's §2.3.6 un-guaranteed-tool guard class keys on "a tool **the project's preflight**
does not guarantee", and for this repository that set is the one `CLAUDE.md` states and
`lib/preflight.sh`'s header declares. Everything else a helper might reach for on `PATH` is
un-guaranteed, so a value deciding a selection or an emitted result must not be derived through
one; a tool *added* to the preflight set is reconciled into this run's sweep by the §2.3.0b
enumeration-reconciliation sweep. This concrete instantiation is what the base skill's generic
wording means — the base skill stays repo-agnostic and names no tools.

## Comment discipline — do not preserve mirror facts with wording pins

The base skill's §2.3 authoring rule keeps mirror-fact comments — an exact count, an enumerated
list of sites or values, a scope word restating a predicate, narration of what adjacent code does —
out of the diff, or makes them drift-proof. Remove or rewrite a mirror fact as a lower bound or a
pointer to the defining symbol, and where the underlying claim is load-bearing prefer a behavioral
test at the executable boundary that fails when the implementation drifts. Header and contract
comments stay load-bearing prose, but their prose presence alone is not a test target.

## Behavioral regressions — executable evidence, not attestation

When a test protects a **named behavioral regression**, exercise the rendered interface or
machine-observable contract with an ordinary executable test: break the behavior on a scratch copy
or fixture, observe that test go RED, then restore the correct behavior. Do not encode the
regression as source-text presence — the former mutation-taking helpers and wrappers are retired.

Then record **evidence, not an attestation**: the workpad `--note` records the behavior you broke
and the executable test you observed go RED. A note that merely testifies a guard is relevant
proves nothing a reviewer can re-run.

**Wording-only pins are prohibited**, per `CLAUDE.md`'s executable-evidence policy and its closed
`# structural-pin-ok:` category set. An operative prompt regression is behavioral: exercise the
rendered or consumed prompt with an ordinary executable test, break the behavior in a scratch
fixture, and demonstrate that test going RED. The diff-scoped `mutation-routing` gate applies the
same policy to helper-based and raw presence assertions, and unchanged legacy sites need no
backfill.

## Focused test modules are the iteration default

`CLAUDE.md`'s suite-running policy — test selection, the focused-first precondition, the
whole-suite gate, shard decomposition, and the per-launch `Verification evidence:` record —
governs this run unchanged and is not restated here. This section states only what
`/prflow:implement` adds to it.

On a cloud tier that grants the focused runner, the direct leading-token form
`lib/test/run-module.sh <module-id>` is the mandated invocation (the `bash` wrapper stays
deny-floored on cloud, so a wrapper-first mandate would burn the run's budget on denials).

**Phase 4.3 owns this run's whole-suite obligation, exactly once.** A focused or `monolith`
result iterates; the Phase 4.3 completion-evidence flight takes a whole-suite result, and a run
that cannot produce one stops at `Blocked` naming the cause rather than claiming completion.

**This run's records go on the issue workpad.** Write the focused-selection marker as a
`## Progress` note (`scripts/workpad.py update <ISSUE_NUMBER> --note "<marker>"`) and each
`Verification evidence:` marker with the `note` reflection kind, so a compacted run's
verification choices survive in the repository rather than only in its transcript.

**A mid-iteration full-suite run is a `## Devflow Reflection` bullet, not a `## Progress` note.**
The missing focused coverage is the signal the retrospective turns into the next extraction
ticket, so record it as an `improvement` naming the surface no module reaches.

For **local create-issue contract iteration only**, select `create-issue-contract` and run
exactly `lib/test/run-module.sh create-issue-contract` as a direct leading token.

## Repo-specific command names and coupled-pin recognizers (relocation destination, issue #1072)

The phase files state their verification, relocation and capability-boundary obligations
**generically** — "the project's own test/lint command", "the project's own relocation check", "a
coupled test-suite pin that asserts workflow content" — because the concrete names below are this
repository's own and must never ship to a consumer whose tree does not carry them (`lib/test/**` is
pruned from the vendored plugin). The **form constraint stays in the phase files**, so a run whose
extension was lost to compaction still reads a phase-file sentence sufficient to avoid the denied
shape.

- **The project's own test command** is `lib/test/run.sh` (the serial primitive) and, for the whole
  suite, `lib/test/run-parallel.sh`; a focused surface uses `lib/test/run-module.sh <module-id>`.
- **The project's own relocation check** is `lib/test/pin-corpus-lint.py --reloc`, which turns a
  bare `ABSENT` pin into `relocated to <file>` and fails closed on a genuine deletion or an
  unresolvable search set. It has no direct-token grant on the cloud implement tier and
  `python3 <path>` is the denied interpreter-head shape, so there the reconciliation is discharged
  by observing the full suite green; the local/interactive tier runs it directly.
- **The coupled test-suite pin that asserts workflow content** is, in this repository, a
  `lib/test/run.sh` pin. It is the literal Phase 1's Pass 5 detects a workflow-resident AC from,
  and the pin the workflows-scoped commit-guard greps miss, so reverting a workflow-resident AC on
  a workflow-incapable cloud credential reverts that coupled pin with it and the pushable
  remainder stays CI-green.

## Interpreter-faithful probes — probe under the shell the artifact actually runs under

When you probe behavior that depends on the **interpreter or environment** an artifact runs under —
a shell built-in's expansion, a `printf` escape, a locale effect, a version-specific behavior — run
the probe under the interpreter the artifact actually runs under, and prefer mutation evidence from
an ordinary executable test over a hand probe when the two disagree. A probe run under the *wrong*
interpreter reports a **false vacuity**: an assertion live under the artifact's real shell looks
dead under whatever shell you happened to type into, and chasing that phantom costs real effort
across every reviewer who repeats it while finding zero defects. The artifact's own shebang (or its
runner's invocation) is the authority for which interpreter is "actual".

## Dogfood every run — capture process-improvement signal (standing side task)

This repository runs `/prflow:implement` under DevFlow's **own** engine, so every run here is a
live test of that engine. Treat improving DevFlow as a standing side task, second only to shipping
the issue: the weekly `/prflow:retrospective-weekly` loop mines these notes, so a friction you
record today becomes a fix tomorrow.

**What to capture**, in the `## Devflow Reflection` section as you go rather than batched to the
end where compaction will have dropped the detail: **bugs** in any DevFlow skill, script, workflow
or agent you exercised; **friction** — steps that were confusing, redundant, awkwardly ordered or
missing, and any denial that forced a workaround; **problematic dependencies** such as an
easy-to-desync coupled pair, a silent-fail consumer, or a resolver that behaved unexpectedly on
this runtime; and **improvement ideas** the run surfaced even if you did not act on them.

**How to record it.** Append each observation with `scripts/workpad.py update <ISSUE_NUMBER>
--reflection-kind improvement --reflection "<observation>"`, naming the concrete surface and the
specific improvement so the retrospective can act without re-deriving what you saw. Reserve the
other kinds for what they mean: `note` (a friction you worked around), `issue-accuracy` (the
driving issue's own claims were wrong), `blocked` (a hard stop), `deferred` (punted work),
`dropped-failed` (a subagent or step that failed and you continued past).

**Before finalizing (Phase 4.3), confirm the side task ran — and record it on the surface whose
cost matches the signal.** `lib/cheap-gate.jq` forces an LLM retrospective pass on any run that
left even one `## Devflow Reflection` bullet, so a reflection is the expensive-but-loud surface and
a `## Progress` note the cheap-but-quiet one. A run that hit real friction, a bug, or a hazard
already has its Reflection bullet, and the gate tripping there is correct rather than waste. A run
that was genuinely frictionless end-to-end and ran no mid-iteration full suite files **no**
`--reflection` bullet: record `scripts/workpad.py update <ISSUE_NUMBER> --note "dogfood side task
ran: frictionless, nothing to capture"` instead, which proves the side task ran while leaving
`cheap-gate.jq` free to skip the clean PR cheaply.

A run that shipped the issue, hit no friction, and left **neither** a Reflection bullet nor that
Progress note has skipped the side task; empty-and-silent is not done. Never invent findings to
fill Reflection — the frictionless Progress note is the honest terminal state for a clean run.

## Keeping prompt prose lean (advisory)

Prompt-surface prose carries an instruction and its consequence; rationale for why the rule exists belongs in the review record, not in the prompt.

Prefer moving rare-path detail and long explanations into progressively loaded references rather
than growing mandatory prompt prose, and when a tested helper owns a decision let the skill point
at it instead of restating the branch logic. This is guidance, not a gate — there is no byte
census, ceiling, or cutover artifact to satisfy.

## Prompt-surface edit routing (repo policy)

`CLAUDE.md`'s "Editing any skill file" convention mandates the `superpowers:writing-skills`
RED/GREEN discipline before any `SKILL.md` edit, and this repo extends that mandate to its
**prompt-surface** files. An autonomous `/prflow:implement` run must **not** invoke
`writing-skills` through the **Skill tool** mid-phase — that is a tail call which adopts the nested
skill's flow as the run's whole task and strands the run (the engine's #362 exclusionary Skill
rule, preserved **unchanged**: `writing-skills` is **not** added to the engine's three-skill
allowlist). This repo routes the discipline through a context-isolated **Agent-tool subagent**,
where a Skill-tool `writing-skills` invocation is safe because the skill's flow *is* the subagent's
whole task.

**The trigger globs.** The routing fires on an edit to any path matching one of:
`skills/*/SKILL.md`, `skills/implement/phases/*.md`, `skills/implement/references/*.md`, `skills/review/phases/*.md`, `skills/review-and-fix/references/*.md`, `.prflow/prompt-extensions/*.md`.
(`agents/*.md` and skill companion files *other than* the `skills/review-and-fix/references/*.md`
step references named above stay under the base skill's Phase 2 §2.4 discipline.)

**The routing rule (edit-intent time).** Before making any edit to a path matching a trigger glob,
the orchestrator dispatches a context-isolated Agent-tool subagent whose prompt instructs it to
invoke `superpowers:writing-skills` and perform the edit under that skill's RED/GREEN discipline,
returning the edit and its evidence.

**The repair arm (resumed/compacted runs).** Evaluated **at extension load and again at Phase 3
entry**: when the branch diff already touches a trigger glob and the workpad carries no
`Writing-skills evidence:` marker, route the existing edits through the subagent for RED/GREEN
verification — recording the marker — before the run proceeds. **Fail closed on an unresolvable
operand:** an unreadable branch diff reads as *unknown → fire the arm*, never as "no trigger
touched", and an unreadable workpad likewise reads as "no marker", so a degraded read on the very
state this arm protects can never silently skip the discipline.

**The fallback clause.** The subagent checks `writing-skills` against its available-skills list
**before** editing and quotes that check's outcome in its returned evidence; when the check reports
the skill **absent**, the edit is made under the base skill's Phase 2 §2.4 inline RED/GREEN
micro-test discipline and the workpad records the degraded mode. The recorded mode is derived from
the quoted check, so `subagent` can never be recorded when the skill never loaded.

**The evidence contract.** After any trigger-file edit, the workpad carries a line **containing**
the exact marker literal `Writing-skills evidence:`, recorded via the sanctioned `workpad.py update
--note` path — whose rendering prepends `  - HH:MM:SS — ` to every note, which is why the contract
is *containment*, never line-start. That literal is the exact string the review-gate criterion
matches, a coupled site pinned in lockstep across `review-and-fix.md` and `review.md`.

**The line's shape.** After the marker literal the line names the trigger files touched and `mode=`
(`subagent` for the dispatch path, `inline-degraded` for the fallback), then carries all four slots
below, each written `<slot>=yes` or `<slot>=no` followed by one clause in parentheses:

| Slot | A `yes` clause states | A `no` clause states |
|---|---|---|
| `skill-loaded` | the quoted available-skills check outcome, which reported the skill present | why it did not load — that same check reported it absent, or could not be made |
| `guidance-applied` | which named guidance was applied | why none was |
| `pressure-scenario` | the subagent scenario run, and the baseline rationalization it captured verbatim | why the cycle does not fit this edit |
| `micro-tests` | the reps run and the no-guidance control | why not |

A worked line for the hardest case — a one-sentence factual correction to reference prose:

> Writing-skills evidence: skills/review/phases/phase-3-agents.md mode=subagent
> skill-loaded=yes (available-skills list reported the writing-skills id PRESENT)
> guidance-applied=yes (Match the Form to the Failure — a stale fact is corrected in place, so
> the form stays a plain statement) pressure-scenario=no (the edit adds and relaxes no rule, so
> there is no discipline failure for a scenario to elicit) micro-tests=no (a corrected fact
> shapes no behavior, so a no-guidance control has no failure to exhibit)

**`no` is a discharging value.** `pressure-scenario=no` with its reason discharges that slot
exactly as `yes` does, and is the expected outcome for an edit the cycle does not fit; what this
rule and the review gate require is a stated disposition, never a particular one.

**What `pressure-scenario=yes` asserts.** Record `yes` when a subagent ran against the *unedited*
text without the guidance and its rationalizations were captured verbatim — that run is the
observable event the slot names. Analysis of what the edited text would do on some path is
reasoning about the artifact, not that run, so the slot is `no`.

## Batched artifact regeneration

`CLAUDE.md`'s generated-artifacts policy — the batched pass, its residual unchecked verdict, the
two-denials discipline, and the merge-conflict classification — governs this run unchanged. Run
the granted direct leading-token form once after applying edits and before each full-suite
re-verify run:

```bash
lib/test/regenerate-artifacts.py
```

Record this run's `batched-regeneration: run|refused|skipped` discharge line on the issue workpad
before each full-suite run, so a compacted context leaves an auditable gap rather than an
undetectable silent revert to serial discovery.
