# DevFlow repo — operative policy for `/prflow:review-and-fix`

This repository is the DevFlow plugin itself: its findings frequently concern the
engine prose in `skills/` and the best-effort shell/`jq`/Python helpers in
`scripts/`/`lib/`. The base skill's gates stand unchanged — this extension **sharpens**
(never supplants) the **fix-delta gate** (Step 0.9) and the **Step 2.6 shadow reviewer
prompts** with four repo-specific verification-discipline shapes — two fail-open guard
classes the issue-#247 dogfooding run reproduced at runtime (shapes 1–2), and two
vacuous-verification classes the PR #340 fix loop reproduced (shapes 3–4) — plus an
interpreter-faithful-probe rule (PR #340's R7). Flag an instance of any shape as at least
**Important** (a silent selection/output change, a vacuous test, or a re-derived guard
contract is a correctness defect), and require the fix to verify the *outcome*, not the
precondition.

> **Maintainer note (budget):** the shapes below retain principle/flag/fix, but their detailed
> `#247`/`PR #340` reproduction walkthroughs were trimmed for prompt budget (issue #530) to at
> most a one-line summary (some carry none). Full context: issue #247 / PR #340 history.

Template: [Keeping prompt prose lean](implement.md#keeping-prompt-prose-lean-advisory).

## Wording-only pin review policy

A wording-only pin is a test whose protected literal can change without changing executable
behavior and without breaking a machine-consumed contract. Flag every newly added wording-only,
secondary-prose, documentation-presence, advisory-heading, or comment-presence pin as an
**Important** finding, whether it uses a pin helper or a raw text-presence assertion. A
`# structural-pin-ok:` comment does not make prose executable. This "whether it uses a pin
helper" scope is now enforced mechanically, not by review alone: `mutation-routing-worktree`
reports a **new or modified** count-helper pin (`pin_count` / `devflow_module_pin_count`) whose
literal resolves into prose exactly as it reports the equivalent static-helper or raw-`grep` pin
(issue #925 — helper identity selects no exemption). The pre-existing population is grandfathered
(only changed sites are adjudicated), so the clause is enforced for new and modified sites; an
unmodified prose pin that predates the rule is not retroactively failed.

An operative prompt regression instead uses an ordinary executable test over the
rendered or consumed prompt and demonstrates that test going RED when the behavior
breaks. A new static presence pin is valid only with
the exact declaration `# structural-pin-ok: <category> -- <rationale>`, a nonempty rationale,
and one category from this closed set: `helper-contract`, `schema-config-vocabulary`,
`security-credential-boundary`, `machine-sentinel-provenance`,
`routing-dispatch-contract`, `lifecycle-state-transition`,
`generated-artifact-identity`, `cross-file-phase-contract`.

## Focused test modules are the fix-iteration default

Before choosing a test, use finding context, test plan, or coverage map
(`lib/test/modules/coverage-map.json`, whose `focused_test` field names the covering Python test
for a unit no shell module owns) to identify a candidate module, then confirm its ID
in `scripts/workflow-flight-recorder-registry.json`. Explicitly record the selected ID and
use the direct leading-token form `lib/test/run-module.sh <module-id>` for the RED/GREEN loop on the local/interactive tier, where the classifier routinely denies the `bash <path>` wrapper — so lead with the direct form. Reserve that wrapper (`bash lib/test/run-module.sh <module-id>`) for a host where the direct form is unavailable and the wrapper is permitted. Selection is explicit:
consulting the coverage map counts (record the entry, confirm the ID).
Do not infer or automate changed-file-to-module routing. For **local review-and-fix contract iteration only**,
run exactly `lib/test/run-module.sh review-and-fix-contract` as a direct leading token. Cloud-tier runs use `lib/test/run-module.sh <module-id>` (direct leading-token form) when the tier grants it and a registered module covers the fix; otherwise they use the already-permitted complete suite without requesting new permissions.

Focused verification is the fix-iteration default: a focused pass covering the changed surface is sufficient for an intermediate commit or push.

**Tier 1 — iterate on the covering focused test.** When a covering focused test exists, iterate on it rather than the full suite. A fixed `scripts/*.py` or `lib/*.py` unit whose coverage-map entry names a `focused_test` routes to that test, invoked as a **direct leading token** — `lib/test/test_python_scripts.py`, or a narrower `lib/test/test_python_scripts.py SomeClass.test_name` — and **never** as `python3 <path>`, the interpreter-head shape the cloud matcher denies (issue #401); those files carry the exec bit and are granted as direct-token forms via `.prflow/config.json`'s `prflow_implement.allowed_tools` (issue #1078 moved them out of the shipped `implement` profile into that self-repo grant channel), so the form holds on the cloud implement tier too — on any other tier (the `command` profile `devflow.yml` resolves, say) use it only when that tier grants it, otherwise fall back to the already-permitted complete suite rather than emitting a silently-refused command. A shell surface with a registered module keeps the module runner above. Selection stays explicit and agent-consulted: record the coverage-map entry consulted and the target selected. Losing this prose to compaction or an auto-resume degrades to the full-suite default — slower, never incorrect.

**The selection record has a named sink — a named record of its own, never free prose in a general-purpose field** (coupled copy; edit together with `.prflow/prompt-extensions/implement.md` and `.prflow/prompt-extensions/receiving-code-review.md`, per the authoring comments each already carries). Write it through `scripts/focused_selection.py`'s record shape (`build_record` → a machine-parseable dict; `encode_marker`/`decode_markers` round-trip it). Per **touched surface** the record names either the coverage-map entry consulted and the target selected (a discharging focused result), or which of the four exemption grounds applied. On a **standalone** fix loop the sink is the iteration record `iter-<N>.json`'s `verification_evidence` object, which gains a `focused_selection` field holding that record (see `skills/review-and-fix/references/fixing.md`); when the fix loop runs **inside `/prflow:implement`** the sink is the issue workpad through `scripts/workpad.py` (the marker as a `## Progress` note). This is what makes a followed rule and an ignored one leave *distinguishable* traces — a loop that consulted the map records the per-surface entries, a loop that skipped to the full suite records none — and it adds **no** launch counter, **no** ordinal, and no mechanical changed-file-to-module routing.

**Tier 2 — coalescing extraction.** When **no** covering focused test exists (a `lib/test/run.sh`-resident shell block), use the full suite for the **first** mid-iteration cycle on that surface. Only a **second** mid-iteration cycle on the same uncovered surface triggers a durable module extraction — dispatched as an Agent-tool subagent (never a nested interactive skill), written RED-first, and registered (its `lib/test/coverage_map_guard.py` repair now runs in-env on both tiers) — after which the loop iterates on `lib/test/run-module.sh <new-id>`. A one-off fix pays one full run; an iteratively-fixed surface extracts once.

**The full-suite fallback is a closed set**, complete by construction. The full suite remains the mid-iteration test in exactly these cases: (a) a surface whose checks require `run.sh`'s full-suite global setup; (b) a check that legitimately self-skips, which a module may not (`run-module.sh` makes `skip()` fatal); (c) a surface whose tier-2 extraction cannot be completed — a cross-cutting `run.sh` helper spanning many `run_sh_blocks` that no single module can isolate, or a `--fix` that leaves residual drift; (d) the first mid-iteration cycle on a `run.sh`-resident surface, before a second cycle warrants extraction. A run that takes any of them records a `## Devflow Reflection` bullet naming **which** case applied.

<!-- Coupled copy (same-commit reconciliation): the focused-first precondition and the single-turn push/verify mandate below are a real copy; its coupled counterpart is the real copy in `.prflow/prompt-extensions/receiving-code-review.md` (with `.prflow/prompt-extensions/implement.md` the single-source home, which carries a real copy rather than being merely pointed at). Edit both together. The issue-#1252 batching rule below is a THREE-way real copy — its counterparts are the real copies in `.prflow/prompt-extensions/receiving-code-review.md` and in that same single-source home; edit all three together. -->
**Focused-first is a precondition on the mid-iteration full-suite launch, not merely fix-iteration advice.** Before a fix loop launches the complete suite **mid-iteration**, every touched surface that has a covering focused test invocable on this tier must already have been run this cycle. "Has a covering focused test" is answered by the two coverage-map fields the selection rule above already consults — a `focused_test` entry for a Python unit, **or** a registered module id in `owner` for a shell surface routed through the focused-module runner. A surface is **exempt** on any of four total grounds: (1) **no coverage-map entry at all** (the majority case — the map covers only `lib/` and `scripts/`); (2) a **declared exempt subtree**; (3) an **`unmodularized` entry with no `focused_test`**; or (4) a **covering test the running tier cannot invoke** (its token ungranted), which routes that surface to the full suite exactly as the tier-grant fallback above directs. A covering focused test that **ran and failed** also discharges the precondition, for the sole purpose of launching the full suite to diagnose the failure; the completion-claim gate is unchanged. The per-surface obligation is discharged by the explicit agent-consulted selection above — recording the consulted coverage-map entry and the selected target **per surface**, into the named focused-selection sink above, each surface's entry stating either its discharging focused result or the exemption ground that applied — and is **not** licence to derive the touched-surface set mechanically. It adds **no** launch counter and **no** ordinal, and the per-launch closed-set reflection bullet is unchanged. The precondition binds the **mid-iteration** launch only; the final gate's full-suite launch is **not** gated on it, preserving the division that a focused result discharges intermediate iteration only. And it never inverts the compaction/auto-resume degradation sentence above: a loop that cannot establish which covering focused tests it already ran this cycle **re-runs them** — an unestablished record is **not** a satisfied precondition — and where the record of the touched surfaces themselves is lost it degrades to the full-suite default rather than being blocked behind an unsatisfiable precondition.

A mid-iteration `#434` stale-prose `blocking-gate` skip on a dirty tree is **expected** — it clears once the tree is committed — so never re-run the full suite mid-iteration solely to clear it. **What the loop does instead is commit the tree, then continue:** committing is the action the skip calls for and clears it, where a fresh full-suite run does not. The `#434` self-scan is unmodified, and the completion-claim skip rule stated below is preserved unchanged.

Full-suite runs are coalesced through the existing `scripts/verification-flight.py` single flight (`#528`); the helper accepts any non-empty terminal-evidence object and mandates no field, so recording the **coordinator command identity**, the **compact aggregate**, the **exit status**, the **skip population**, and the **retained-log root** there is a caller obligation this repository adopts: diagnose from the aggregate's `Failure recap` and, where the coordinator's per-class detail cap elided detail, from the complete shard logs under that retained-log root — instead of relaunching. Mid-iteration, prefer the covering focused test. **Consult the single flight before any full-suite relaunch, and record that you did:** read the durable status handle first, and when it already holds a clean result for the current tree read that result rather than re-producing it — recording the consultation in the named focused-selection sink above (its `single_flight_consulted` field), so a consulted flight is distinguishable from an unconsulted one.

**Batch every owed fix into one whole-suite pass (issue #1252).** Before the fix loop launches a whole-suite pass — mid-iteration or the final gate alike — apply every fix already owed: every failure the previous pass's `Failure recap` named, every edit already identified and not yet made, and the *Batched artifact regeneration* pass below. Launching one pass per fix is the waste this rule names. **Recording surface.** Any remainder or reason this rule requires recording, at a mid-iteration launch and at the gate launch alike, is written through `scripts/workpad.py` with the `deferred` reflection kind — a friction kind, deliberately not the friction-suppressing `note`; on a run with no workpad, in the PR description; a run with neither names that terminal and reports the item unrecordable rather than stalling. **An unestablished owed-fix set is never an empty one, and a mid-iteration launch and the gate launch resolve it differently.** The set is established by reading whichever of those surfaces this loop recorded on — the workpad via `scripts/workpad.py id <issue>` then `scripts/workpad.py body <comment-id>`, where `id`'s exit 2 means *no workpad* and routes to the PR-description surface while its exit 1 means *unestablished* — plus the previous pass's `Failure recap` from its retained-log root. **A limb with nothing to read is established-and-empty, not unestablished**: a loop with no previous whole-suite pass has no `Failure recap` limb to establish, and a surface that reads successfully carrying no owed-fix record establishes an empty set. Only a limb the loop tried to read and could not is unestablished. *Mid-iteration*, a loop that cannot establish it applies what it can establish, launches, and records the unestablished remainder on the surface above; it never blocks a mid-iteration launch. *At the final gate it blocks instead*: establish the set, apply it, and only then launch, because a pass launched over an unestablished owed-fix set is intermediate evidence and does not discharge that gate. **A loop that still cannot establish the set at that gate neither falls through to the mid-iteration arm nor launches a discharging pass**: it records the remainder on that same surface and exits the loop reporting non-convergence, naming the unestablishable owed-fix set as the cause — never a clean verdict, and never a silent stall. This shares the focused-first precondition's refusal to read an unestablished record as satisfied, but **diverges on the remedy**: that precondition binds mid-iteration only and degrades to the full suite rather than blocking, whereas this gate arm blocks. This rule **overrides nothing**. The existing relaunch rules above stand — do not relaunch to re-read a result you already have, and do not relaunch merely to clear an expected `#434` stale-prose skip. `scripts/verification-flight.py`'s single flight is **unchanged**, and it correctly does **not** suppress a post-edit relaunch: the checkout has drifted, so the second launch is a legitimately new flight. The final gate's whole-suite requirement is untouched — batching governs *when* that launch is paid for, never *what* it must report, and **no focused result ever discharges it**. **Mid-iteration only** — never at that gate — where the focused-first precondition above already establishes that the surface a single edit touched has a covering focused test, that test rather than a whole-suite pass is the instrument for confirming the edit. Batching changes **how many passes are paid, never what is checked** — the same edits are checked, in one pass instead of several. A fix that **cannot** be batched, because a later fix depends on the earlier one's *verified* result, is launched separately and the reason recorded on the recording surface above. This rule **requires** that the `Verification evidence:` record issue #1249 establishes for a whole-suite launch carry that launch's own time, so the interval between two consecutive records is derivable without knowing the total launch count. #1249 has landed and is that record's producer, but it shipped the record without a clock — its launches are told apart by the coordinator's per-launch run root, which carries no time — so this change adds the launch's own start time to that record's stated content, and re-authorizing any further measurement channel is a decision for that issue, not this rule. It authorizes **no** second, competing record here, and introduces **no** full-suite launch counter, **no** launch ordinal, and **no** mechanical changed-file-to-module routing.

A focused result discharges intermediate iteration only, never the final review/fix gate.
**Whose terminal that is depends on the caller.** When the fix loop runs **inside `/prflow:implement`** (Phase 3.3) the terminal is not its own: every Phase 4 commit — the 4.1 docs/changeset commit, a 4.2 claim-audit commit, the 4.3 clean-tree backstop, checkpoint 4's merge — makes a Phase 3 flight stale by definition, and Phase 4.3's completion-evidence flight then re-verifies the final tree, so a whole-suite pass paid at the loop's terminal is **discarded rather than relied on**; there the loop's terminal is discharged by the covering focused result the iteration already produced, or by the `monolith` shard result the shard-instrument rule below permits. The whole-suite obligation is owned **exactly once**, by that Phase 4.3 flight, whose terms this scoping leaves untouched — its whole-suite requirement and its `#456` skip accounting are unchanged. The caller is knowable with **no new flag, field, or counter**: it is the same distinction the focused-selection sink above already routes on — the issue workpad inside `/prflow:implement`, `iter-<N>.json` standalone. **Fail-closed direction:** a loop that cannot establish which caller it has treats itself as **standalone** and applies the standalone arm below. <!-- Authoring constraint: keep this caller distinction invocation-derived — the same axis the focused-selection sink above already routes on — and never degrade it to workpad-presence-only inference. A workpad's presence or absence tracks things other than the caller, so that inference is what would produce an affirmative-but-wrong inside-implement classification, which the fail-closed clause cannot catch: it fires on an unestablished caller, never on a confidently wrong one. -->
**A standalone terminal is narrowed too, on what else will ever verify this tree.** The loop's terminal verdict is a **findings** verdict — `Review converged after {N} iteration(s)…`, the APPROVE family, `REJECT` — and no line of it asserts that a test suite is green, so gating a findings verdict on a whole-suite result answers a question that verdict never asks. What the terminal genuinely owes is the **honesty floor**, because the loop *edits code* and emitting an APPROVE over unverified edits is an unbacked claim: it verifies **in-env**, at the narrowest covering target, every surface it changed — on every tier, for every caller, non-negotiable, and cheap. Past that floor the standalone whole-suite obligation survives **only where no external backstop exists**: where the run establishes that nothing outside it will exercise the broader suite over this tree, the loop genuinely is the last line and pays the whole-suite pass itself. That is the ordinary standalone shape rather than an edge case — the skill reviews the **current branch** when no PR number is given and `--push-each-iteration` is **off** by default, so a standalone run routinely has no PR and no push and therefore nothing downstream at all. Where a standalone run **does** publish to a PR whose merge this project gates on a check outside this run that exercises the broader suite over the pushed tree (here, the required `lib + python tests` check), the loop emits its findings verdict **without** a whole-suite pass, and its wording may **not** assert or imply that the broader suite is green — that claim belongs to the gate that actually establishes it. **Fail-closed default:** a loop that cannot establish whether such a backstop exists takes the whole-suite result.
This scopes **which run pays** the whole-suite pass and **what the terminal may claim**, never **which channel establishes** either: the issue-#405 in-env rule stated below is neither weakened nor narrowed — every loop still verifies in its own environment, and no loop waits on, polls, re-checks, or cites CI for its own progress. Declining to **claim** what this run did not verify is the opposite of resting a verdict on a result it never saw; the backstop is a property of the project the run evaluates once, never a signal it reads.
The final gate is preserved, and on the local/interactive and reception/shepherd tiers it is parallelized.
Before a completion or PR-ready claim, issue the CI-triggering push and the full local run **in a single assistant turn** so they execute in parallel; the push is NOT gated on the local run finishing. <!-- Coupled copy (same-commit reconciliation) with `.prflow/prompt-extensions/receiving-code-review.md`'s single-turn mandate. -->
The **claim** is gated on it: read the local run's summary before you make one. A nonzero failure tally, a nonempty skip tally, a **non-zero exit status** (the coordinator returns one for a shard that did not complete even when its tally reads clean), or a run that never started (denied, blocked, or unreached) is not a completion — report the failure detail and iterate, and say so explicitly rather than letting the already-landed push stand as the claim.
**The final full-suite command is the parallel coordinator `lib/test/run-parallel.sh` (issue #1086)** — the same tested partition CI shards, derived from `lib/test/run-shard.sh --list-shards`, run concurrently inside this checkout, recombined through `lib/test/shard-tally.py`, with every launched shard's complete log retained under an ignored run root and one compact aggregate printed. On the **cloud** tier it is a **direct leading token** with nothing around it (it owns its own assignments, redirects and background processes, precisely because the matcher refuses those shapes caller-side); on the **local/interactive** tier it is invoked through the documented `DEVFLOW_BASH` selection boundary. **Grant-timing caveat:** the tool grant is resolved from the *default branch* at trigger time while this file is read from the working tree, so on a PR that is itself adding the grant the cloud tier's final command stays `lib/test/run.sh` — and no output at all from the coordinator there is a denial, not an empty result. `lib/test/run.sh` stays the serial primitive the `monolith` shard runs and the uncovered-surface fallback above names, and focused iteration is unchanged — and, mid-iteration on a tier where the coordinator meaningfully exceeds a single shard, that same `monolith` shard may stand in for the whole suite on a `run.sh`-resident surface (the shard-instrument rule below).

**A `run.sh`-resident surface may run the `monolith` shard mid-iteration where a shard is the real saving (issue #1253).** On a tier where the whole-suite coordinator meaningfully exceeds a single shard, a **mid-iteration** cycle on a surface whose assertions are confined to one shard's population may run `lib/test/run-shard.sh <shard>` for that shard instead of a whole-suite pass; `lib/test/run.sh`-resident assertions are the **`monolith`** shard's population, so such a surface runs `lib/test/run-shard.sh monolith`. **Which tiers (per issue #1253's AC1):** the **cloud implement tier**, where the coordinator meaningfully exceeds `monolith` (measured ~10.5 min vs ~3.9 min, 2026-08-04); on a **local/interactive** host running the five shards concurrently the whole-suite time is near the slowest-shard bound and the saving is small, so prefer the shard there only where it is the actual saving. Four limits keep this from being a downgrade: (1) `monolith` is a cheaper **whole-file** run, not a focused module; (2) it covers **one surface only** — every other touched surface still takes its own covering focused test or the existing fallback; (3) it **never discharges the final completion gate**, whose terms (a whole-suite result, `#456` skip accounting) are unchanged; (4) the two selectors no-op the module-tier invocation and the pooled-Python open/join in `run.sh` itself, so an edit to those call sites is `run.sh`-resident yet not exercised by the shard and takes the existing fallback. Record a mid-iteration shard run in the named focused-selection sink as the surface's **exemption** entry with the shard named in the reason clause — **no new field** in `scripts/focused_selection.py`'s schema; the `Verification evidence:` marker is per whole-suite launch and records nothing for a shard run. On the cloud tier read the terminal `Failure recap` through `| tail -<n>` (the `tail` head is granted) rather than taking `run-shard.sh`'s full echoed log into context. This is a **mid-iteration** instrument only — roughly one whole-suite launch saved per run given case (d)'s first-cycle-only scope and the #1252 batching rule; it reduces neither the *number* of verification rounds nor the tier-2 module-extraction obligation.
The full local run is that coordinator plus every lint gate required by `CLAUDE.md` (using its documented classifier fallback when necessary), and it remains the authoritative local signal because it yields richer failure detail than CI for troubleshooting. A nonempty skip tally is not clean.
The cloud `/prflow:implement` in-env gate (issue #405) is unchanged and unweakened: such a run verifies in its own environment and never waits on, polls, re-checks, or cites CI for its own progress; the parallel-push allowance above is a local/interactive and reception/shepherd tier rule only.

**Every tier that maintains a workpad — capture each parallel full-suite launch and record a `Verification evidence:` marker (issues #719, #1249).** Because the parallelized gate launches the full run *concurrently* with the CI-triggering push rather than serialized behind it, a launch that is denied, blocked, or never reached leaves no trace — and a run that launches the suite **more than once** (a first launch that fails, a second that comes back clean) otherwise records only the launch it happens to mention, leaving the earlier one nowhere in the repository (issue #1249). So let the coordinator retain **each** launch: `lib/test/run-parallel.sh` writes every launched shard's complete log under its own run root and prints that root, so the caller composes **no redirect of its own** — and, before the completion claim, record the marker literal `Verification evidence:` in the workpad through `scripts/workpad.py` with the **`note`** reflection kind, **once for each whole-suite launch the run performs** (a run with more than one launch ends with more than one record). Each record carries the **command invoked**, the launch's outcome as the coordinator reported it (its `aggregate CLEAN` / `aggregate FAILED` line), the run's **pass, fail, and skip tallies** when reported, the **coordinator's retained-log root**, and the launch's **own start time** (issue #1252 — the reflection channel timestamps nothing, so the bullet carries the clock explicitly, which is what makes the interval between two consecutive records derivable) — and the records are told apart by that distinct run root the coordinator mints per launch (`run-<pid>-<n>`), so there is **no launch counter and no ordinal to maintain**. Three paths produce no run root, each naming what to record instead: a **tier-denied** launch (no output — issue #401 — record the refusal, no root); a launch **terminated at the per-command execution ceiling** (issue #1132 — record the termination and route to shard decomposition); and the **shard-decomposition** path itself, whose record names the `lib/test/shard-tally.py` recombination rather than a single root. Use `note` because it is the only kind `lib/cheap-gate.jq` does not treat as friction. **Fallback:** a reception pass with no linked issue (`lib/fetch-pr-context.sh` emits `NoIssue`) has no workpad — record the marker in the **PR description**; a run with **neither** workpad nor PR names that terminal and reports the evidence **unrecordable** rather than stalling. This is **artifact vocabulary plus a captured artifact, not runtime enforcement**: no gate consumes it here, and `lib/cheap-gate.jq` is deliberately not wired to it (wiring it would change retrospective sampling for every merged PR — a separate decision, not a population-coverage exclusion). The **cloud tiers now carry the obligation too**: the issue-#405 in-env rule is unchanged, and on top of it a cloud run records one marker per launch exactly as a local run does, so a repeated or failed cloud launch is legible in the repository's records. The change makes a repeated launch **legible, not prevented** — per-launch completeness is not machine-checkable, so the advisory below observes only that **at least one** record is present.

## Guard-class shape 1 — existence-vs-sourceability (verify the outcome, not the precondition)

A guard that tests a file's **existence** and then treats a later **consumption** of that
file as guaranteed is fail-open: the file can exist yet be unreadable, corrupt, or fail to
parse/source, so the precondition passes while the outcome it stands in for never happens.

- **Flag:** any `[ -f <file> ] && . <file>` (or `[ -f x ] && source x`, `[ -e x ]` gating a
  later read/parse) where the guard's *intent* is "the thing the file provides is now
  available." `[ -f ]` proves the path exists — it proves nothing about whether sourcing
  succeeded or the symbol/function it defines is now callable.
- **Fix (verify the outcome):** assert the *consumed result* directly. For a sourced helper,
  check the function is defined after sourcing — `. <file> 2>/dev/null; type <fn> >/dev/null 2>&1 || { breadcrumb; fail-closed; }` — not that the file exists. For a parsed value, check the
  parse produced a usable value. Fail **closed** with a specific breadcrumb when the outcome
  check fails, never silently continue as if the sibling loaded.

## Guard-class shape 2 — tr-dependence (an external PATH tool whose absence silently changes output)

A value (a slug, a branch name, a path segment, a normalized identifier) derived by piping
through an external tool consulted on `PATH` — `tr`, `sed`, `awk`, `paste`, `jq` — degrades
**silently** on a host where that tool is missing or behaves differently: the pipeline still
runs, the value comes out wrong (empty, unnormalized, or truncated), and the wrong value then
selects the wrong directory / writes the wrong file / no-ops a gate, with no error.

- **Flag:** any selection- or output-determining value derived through such a tool where a
  failure of the tool (absent on `PATH`, a BSD/GNU behavioral difference, a locale effect)
  would silently change *which* thing is selected or *what* is emitted, rather than surfacing
  an error. Especially where the derived value keys a filesystem path or a comparison.
- **Fix:** either prove the tool is a hard, preflight-guaranteed prerequisite (and cite it), or
  make the failure observable — check the derived value is non-empty/well-formed before it is
  used to select or emit, and fail closed with a breadcrumb naming the tool if it is not. A
  value that is *only* correct when an un-guaranteed tool is present is an unverified boundary.
- **#247 reproduction:** a derived slug degrades on a `PATH` without `tr` and selects the wrong directory.

## Guard-class shape 3 — vacuous negative test (attribute the rejection, carry a positive control)

A negative test — one asserting that a bad input is *rejected* — passes while proving nothing when
the rejection comes from somewhere other than the guard it names. Two sub-shapes: the fixture trips
an **unrelated precondition** and the call fails before reaching the guard under test; or a **different
guard** rejects the input first (more than one guard can reject it), so an exit-code-and-no-output
assertion stays green even against a mutant that disables the very guard the test exists to kill.

- **Flag:** a negative test whose only assertions are the exit code and the absence of output/PATCH,
  on an input that more than one guard could reject — and no positive control on the same fixture
  proving the fixture is otherwise valid. The test names one guard but pins no signal that distinguishes
  it from a precondition or a sibling guard firing first.
- **Fix (attribute + control the outcome):** pin the **rejecting guard's own distinct signal** (its
  specific message/breadcrumb, e.g. `net-adds` absent with the offending pair named), not merely that
  the call failed — so the assertion fails if any *other* guard did the rejecting. And add a **positive
  control on the same fixture**: a companion assertion that the fixture is otherwise valid and the call
  would succeed but for the one property under test, so an unrelated precondition rejecting the fixture
  cannot masquerade as the rejection under test.
- **PR #340 cost this would have eliminated:** two vacuous tests and their follow-up findings.

## Guard-class shape 4 — re-derived consumer contract (write the guard as the operation it protects)

A guard written as a *separate predicate approximating* a downstream consumer's contract — instead of
using that consumer's own operation as the guard — accepts a **superset** of what the consumer accepts,
so inputs the guard waves through still break the consumer: it fails open exactly where it claims to
fail closed. The tell is a guard that inspects a *proxy* for the protected value (an argument string, a
subset of separators) rather than the value the consumer actually operates on.

- **Flag:** a new guard/predicate over a string or shape that hand-derives what a nearby parser,
  splitter, or narrowing op already decides — a regex/`in`-check/type-check standing in for a
  `strptime`, a `splitlines()`, a `_find_checkbox_row`, a JSON decode — especially when the correct
  idiom already exists elsewhere in the same file. Naming the protected operation *after* the predicate
  is written is itself the smell.
- **Fix (write the guard as the operation):** name the downstream operation the guard protects, in the
  code, before writing the predicate; then write the guard **as** that operation (share its contract by
  construction, so the accepted sets are identical and cannot drift). Before writing any new predicate
  over a string or shape, grep the file for an existing idiom doing the same job and reuse it.
- **PR #340 cost this would have eliminated:** the original guard defect and an extra review iteration.

## Probe rule — run interpreter- and environment-dependent probes under the real interpreter

When a fix or a review probes behavior that depends on the **interpreter or environment** the artifact
actually runs under, run interpreter- and environment-dependent probes under the interpreter the artifact
actually runs under, and prefer evidence from the executable test under its real
interpreter over a hand probe when the two disagree. A probe run
under the *wrong* interpreter reports a false vacuity — an assertion that is live under the artifact's
real shell looks dead under the shell you happened to type into — and chasing it costs real effort across
every reviewer who repeats the mistake, finding zero defects.

- **#340 reproduction (local instance):** a test loop drives eight separators through `printf '%b'`.
  Three of them are multibyte octal escapes. Bash expands them; that session's zsh does not. The
  orchestrator and two independent reviewers each probed under zsh, saw literal backslash text, and
  briefly concluded three assertions were vacuous. They were not — the suite's shebang is bash, and the
  executable suite evidence was decisive. Cost: real effort, three times over; defects found: zero. **PR #340
  cost this would have eliminated:** the three false vacuity alarms — duplicated investigative effort
  across the orchestrator and two reviewers with zero defects found.

## Count-locked prose — a `count-locked` row on an unpinned claim triggers the pin-or-don't-write policy

The shared engine's Phase 0.6 `stale-prose-lint.py` ships **detection only**: it tags an exact-count
claim in diff-added prose as `count-locked` in its TSV output. The **policy** for what to do about a
`count-locked` claim lives here, in this repo's layer, not in the engine. When the fix loop's Step 3
stale-prose pre-check (or the engine's Phase 0.6) reports a `count-locked` row whose claim is **not**
already bound to a test assertion that would fail if the count drifts (the
`assert_pin_unique` / `pin_count` corpus), apply the repo's **pin-or-don't-write** policy: either
bind the counted claim to a suite pin in the same change so a later drift turns the desk RED, or reword
it drift-proof (a lower bound instead of an exact count, a pointer to the defining symbol instead of a
copied enumeration) so there is no frozen count to go stale. Do not ship an unpinned exact-count claim
in engine prose — an unpinned `count-locked` header is the very defect class (#328/#336) Phase 0.6
exists to catch, so authoring a fresh one is a self-inflicted Important finding. The engine detects; this
extension decides. (#423)

## Config-derivation fixes sweep the full six-shape adversarial matrix, not just the reviewer-cited row

When a fix touches **how a config value is read, derived, or defaulted** — a `config-get.sh` read, an
inline `jq` extraction over `.prflow/config.json`, an `// default` / `// true`-style fallback, an enum
validation, or any other code that turns a raw config value into a decision — the **same fix** sweeps the
full CLAUDE.md six-shape adversarial matrix over that value: `{object, array, scalar, valid-falsy (explicit false / 0 / empty string), missing, wrong-type}`.
Each shape is **tested in `lib/test/run.sh` in the same change** (exit-0 + a specific, not generic,
breadcrumb per shape; the **valid-falsy** row is load-bearing — a real `false` / `0` / `""` an
`// true` / `// default` extraction silently coerces to its truthy default is the documented
off-switch-that-never-worked defect, #312/#304). A shape that genuinely does not apply to this value is
recorded with a **written reason** instead of a test — never silently skipped. A fix that covers **only**
the reviewer-cited shape row is **incomplete by policy**: the sibling rows are exactly the next run's
predictable test-gap findings (PR #451 round 2 fixed and tested one config-read arm; round 3 existed
almost solely to add the untested sibling arm), so shipping the whole matrix at once is what stops the
per-fix extra review iteration. This is DevFlow-repo policy; the governing convention is CLAUDE.md's
best-effort-parser adversarial-matrix gotcha, and this section is its coupled mirror in
`.prflow/prompt-extensions/receiving-code-review.md` — edit both in the same change. (#466)

## Merge conflicts in generated artifacts

This section's trigger is a **merge conflict**, not an edit: whenever a rebase, base merge, or branch
update leaves a conflict in a checked-in file, resolve it as follows before touching the conflicted
bytes. It is a different trigger from the Batched artifact regeneration section, whose trigger is
post-edit and pre-suite — no in-run conflict arm routes through that section, so the conflict rule
lives here on its own.

The listing this rule reads comes from the granted direct leading-token form:

```bash
lib/test/regenerate-artifacts.py --list
```

1. Run that command.
2. **Establish that the listing is usable before classifying anything.** This gate precedes the
   classification below, and the order is load-bearing: an unusable listing emits no `conflict-path`
   lines, so every conflicted path would otherwise satisfy step 3's "not among them" exit and be
   hand-merged — the guard failing open on exactly the input it exists to catch. The listing is
   usable only if the command exited **0** and emitted at least one `artifact` line and at least one
   `conflict-class` line. If it was refused, the interpreter is absent, the exit code is anything
   else, or the output is empty, truncated, or otherwise unattributable, treat every conflicted
   generated artifact as **needs-human-reconciliation** and stop rather than blind-regenerating. This
   verdict is **residual, not an enumeration of known failures**: any outcome you cannot positively
   attribute is unusable. An unestablished class is unknown — not `by-hand`, and not "absent from the
   set".
3. With a usable listing, look for the conflicted path among the emitted `conflict-path` and
   `conflict-sibling` paths. If it is **not** among them, hand-merge it as any normal file — the
   fail-closed default for the complement of the generated-artifact set.
4. If it **is**, follow the class of the **line that matched**, not the row's class unconditionally.
   A `conflict-path` match is governed by that row's `conflict-class` and `conflict-recipe`. A
   `conflict-sibling` match is governed by **that line's own fourth field**, which is the sibling's
   class — never the owning row's `conflict-class`: a coupled sibling is a file the row's gate reads
   but its generator never writes, so the row's recipe would send you to regenerate a file no
   generator produces. Then follow the governing recipe verbatim — never hand-merge the conflicted
   generated bytes. `regenerate` means re-run the recipe's named write command against the merged
   tree. `reconcile-source` means merge the recipe's named source of truth first, regenerate from it,
   then hand-update the coupled by-hand sibling the `conflict-sibling` line names. `by-hand` means the
   record has no writer and is re-measured or hand-merged deliberately.

Hand-merged generated bytes match no source of truth, so the artifact's own gate then reports them as
drift with a remedy aimed at the wrong file — the run burns a loop chasing a misdirected diagnosis
while silently reverting whatever a concurrent PR added. This rule hardcodes no artifact path and no
command: both are read from `--list` at runtime, so the rule and the registry structurally cannot
drift.

## Batched artifact regeneration

After applying edits and before each full-suite re-verify run, run the granted direct leading-token form once:

```bash
lib/test/regenerate-artifacts.py
```

A fix loop's edits drift the checked-in generated records, and rediscovering each one a full suite run later is an iteration's dominant cost. The helper is the sole enumeration point; no inventory is listed here.

Act on its report first: commit a changed manifest with its causing edits, and resolve every exit-1-forcing judgment item under the policy it names. Informational lines need reading, not action.

**Any outcome but exit 0 or a fully-reported exit 1** — exit 2, a traceback, an empty or truncated report, an unattributable exit code — means an artifact went unchecked: unknown, not clean. Judge residually, never by hunting a named token. Never record `run`; record `batched-regeneration: skipped` naming what you saw, and fall back to serial discovery.

If the matcher refuses the invocation **twice**, stop — record the refusal and proceed to the suite run rather than iterating variants (the issue-401 two-denials discipline). On a run that maintains a workpad, record one line before each full-suite run — `batched-regeneration: run|refused|skipped`.

## Prompt-surface edit routing evidence gate

DevFlow-repo policy: a reviewed diff that touches a **prompt-surface** file must carry evidence
that its edit went through the `superpowers:writing-skills` RED/GREEN discipline (see
`.prflow/prompt-extensions/implement.md`'s "Prompt-surface edit routing" rule). This gate is
the review-time backstop for that routing — flag a missing discharge as at least **Important**.

**Trigger.** This gate applies only when the reviewed diff touches a path matching one of the
trigger globs: `skills/*/SKILL.md`, `skills/implement/phases/*.md`, `skills/implement/references/*.md`, `skills/review/phases/*.md`, `skills/review-and-fix/references/*.md`, `.prflow/prompt-extensions/*.md`.
A diff touching none of them draws no finding.

**Enforcement surfaces.** The gate is enforced on: an implement run's **Phase 3** (which holds
its own issue number), a **`/prflow:review-and-fix` run given a PR**, and **PR-mode standalone
`/prflow:review`**. A no-PR, no-issue **current-branch** run — standalone review's branch mode
and review-and-fix's current-branch mode alike — is **outside the gate's scope** (there is no
issue workpad or PR body to read), so the gate is a no-op there.

**Discharge arms, checked in order** when the reviewed diff touches any trigger glob:

1. The **linked issue** — in an in-run enforcement (implement Phase 3) that is the run's own
   issue; in PR-mode that is the PR's `closingIssuesReferences` — carries a
   `<!-- prflow:workpad -->` comment — or one carrying the superseded `<!-- devflow:workpad -->`
   spelling, since issue #1003 renamed the marker namespace and rewrote no existing body — whose
   body **contains** the marker literal
   `Writing-skills evidence:`. Fetch the issue's comments through the granted `gh` read path (the
   workpad lives on the linked issue, not the PR thread — the established `lib/fetch-pr-context.sh`
   contract; resolve `closingIssuesReferences` first, then fetch that issue's comments).
2. Otherwise, the **PR description** **contains** the marker literal `Writing-skills evidence:` —
   the discharge surface for interactive/human PRs and for a linked issue that has no workpad.

A discharge-surface read that **fails or cannot be resolved** — a `gh` comment-fetch error
(network/auth/rate-limit), or an unresolvable/empty `closingIssuesReferences` — reads as
*marker-absent on that surface*, **never** as *checked-and-clean*; the gate fails toward the
FAIL finding, matching `implement.md`'s repair-arm read-failure handling. When **no** checked
surface can be confirmed to contain the marker — whether because it was genuinely absent or
because the read could not be established — the review reports a **FAIL** finding naming this
rule (fail **closed** — an absent, malformed, or misspelled marker, and an unestablished read,
all read as absent).

**What the gate checks — shape, not mere presence.** A marker found on either surface discharges
the gate only when it carries all four slots the `implement.md` evidence contract names —
`skill-loaded`, `guidance-applied`, `pressure-scenario`, `micro-tests` — each with an explicit
`=yes` or `=no`. Read the four dispositions and report them in the review.

**A slot whose disposition is absent is undischarged, never compliant.** Silence about a slot is
an unestablished measurement, not a `no`; this repo's *unknown is not zero* rule forbids
collapsing it onto either value. When a slot is missing, or carries a value outside `yes`/`no`,
raise the same **FAIL** finding this rule already carries and list the slots at issue. The remedy
is to restate the marker with those dispositions, **not** to perform the step — a restatement
recording `pressure-scenario=no` with its reason discharges the gate in full.

**A `no` never draws a finding on its own.** A marker whose four dispositions are all recorded is
discharged whatever they say. The gate reads them so a reader can weigh whether a step suited the
edit; it never requires the subagent pressure-scenario cycle, whose expected disposition on a
small factual correction to prose is `no`.

## Verification-evidence marker advisory (non-blocking)

DevFlow-repo policy: a second marker gate on the **same shared review-engine surface** as the `Writing-skills evidence:` gate above — the gate that already reads the linked issue's workpad and the PR description. It adds a **non-blocking advisory** for the `Verification evidence:` marker that **every tier maintaining a workpad** records — `/prflow:implement` (cloud and local/interactive, since issue #1249 extended the obligation to the cloud tier), `/prflow:review-and-fix`, and direct-reception passes (per `.prflow/prompt-extensions/implement.md`, `review-and-fix.md`, and `receiving-code-review.md`). Unlike the `Writing-skills evidence:` gate, this clause is **advisory (non-blocking)**: it never raises the review verdict to a FAIL/REJECT on its own — it only informs the reader that a completion/PR-ready claim was made with no captured verification run.

**Input population (stated explicitly).** The clause reads the two durable per-PR surfaces the `Verification evidence:` marker is recorded on — the **linked issue's workpad** and the **PR description** — the same surfaces the `Writing-skills evidence:` gate already fetches (the workpad via `lib/fetch-pr-context.sh` from the linked issue thread; no new fetch channel is required). The marker is recorded on **every tier that maintains a workpad** (issue #1249 extended it from local/interactive to cloud `/prflow:implement`, whose in-env verification under issue #405 now records it too), so the clause checks **every** PR carrying a completion/PR-ready claim rather than only local/interactive ones. Because per-launch completeness is not machine-checkable — no consumer can know how many launches a run performed — the clause can only observe that **at least one** record is present, never that every launch was recorded.

**Tier discriminator (per PR).** Classify from the workpad `## Progress` section: a workpad carrying any `<!-- prflow:checkpoint gha:… -->` row — or the superseded `<!-- devflow:checkpoint gha:… -->` spelling, which a pre-rename run stamped — is a **cloud** run (those checkpoints are stamped cloud-only — `skills/implement/phases/phase-1-setup.md`, `skills/implement/SKILL.md`); a workpad with no such row is a **local/interactive** run. Since issue #1249 the clause acts on **both** classifications; it records the classification in the finding it emits so a reader knows which tier was expected to record the marker, but no longer uses it to gate whether it acts.

**Behavior:**

1. On **any** PR carrying a completion/PR-ready claim — cloud-classified or local/interactive alike — the clause checks the workpad and the PR description for the `Verification evidence:` marker literal.
2. When the marker is present on either surface the clause is silent. When it is absent from both surfaces the review emits one advisory (non-blocking) finding naming the missing `Verification evidence:` marker and the tier classification the checkpoint discriminator assigned. The advisory never raises the verdict to a FAIL/REJECT by itself.

**Covered population.** A **cloud or local** implement run's workpad, a **`/prflow:review-and-fix` run given a PR**, and a **direct-reception** marker recorded in the **PR description**. A local **current-branch** run with no PR and no linked issue is **out of scope** — it leaves no durable surface (workpad or PR body) for the gate to read, the same case the `Writing-skills evidence:` gate scopes out.

**Accepted residual.** The `gha:` checkpoint is best-effort and fires only when the workpad carries a canonical `## Progress` section, so a cloud run on a legacy workpad lacking that section writes no checkpoint and is classified local/interactive. Since the clause now acts on both classifications (issue #1249), that only mislabels the tier named in the finding — it no longer changes whether the advisory fires. Because the finding is non-blocking, this is accepted rather than guarded.
