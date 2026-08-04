# DevFlow repo — operative policy for `/prflow:implement`

This repository (the DevFlow plugin itself) manages its own version and runs under a
permission classifier that routinely blocks shell invocations, so apply the following
when implementing an issue here. The base `/prflow:implement` skill is
versioning-agnostic and environment-agnostic by design — this extension is DevFlow's
opt-in, and it is the **operative** repo policy (edit this file to change it).

## Versioning policy

DevFlow versions itself with **changesets**, not an in-PR version bump. Each PR that reaches
consumers declares its change in a uniquely-named `.changeset/*.md` file and never edits
`.claude-plugin/plugin.json` or `CHANGELOG.md`; a merge-time GitHub Action (at
`.github/workflows/version-consolidate.yml`; runs
`scripts/consolidate-changesets.py`) consolidates all pending changesets into a single version
bump + CHANGELOG entry on `main`.
Because each changeset file has a unique name, two concurrent PRs never touch a shared line,
so the version/CHANGELOG merge conflicts that used to tax every concurrent PR are gone. Full
format reference: [`.changeset/README.md`](../../.changeset/README.md).

**When to add a changeset.** Add exactly one `.changeset/*.md` file only for changes that
reach consumer repos as an update — a fix, feature, or breaking change to the engine
surface (`skills/`, `agents/`, `lib/`, `scripts/`, the workflows, the config schema).
Internal-only changes (tests, CI, dev-only docs) add **no** changeset.

**Which bump — default to `patch`.** The changeset frontmatter carries a `bump:` key of
`patch`, `minor`, or `major`. Use the smallest step. Choose `minor` (backward-compatible
feature) or `major` (breaking change) **only when this issue's body explicitly authorizes
the larger step** — e.g. an acceptance criterion naming the target version or the SemVer
increment. When the issue is silent on the increment, choose `patch`. Never infer a larger
bump from the change's size or "feature-ness" on your own.

**Do not edit `plugin.json` or `CHANGELOG.md` directly.** The changeset *is* your changelog
prose (Keep-a-Changelog wording in the body, PR-cited). The merge-time Action bumps
`.claude-plugin/plugin.json` by the **highest** pending `bump:` and assembles the dated
`## [x.y.z]` `CHANGELOG.md` entry from every pending changeset's prose. The Phase 3 review
gate FAILs on an engine-surface change that carries **no** changeset file (the changeset
replaces the old version↔`CHANGELOG` presence check).

**When to write it.** Decide the increment once the committed diff is concrete (record the
decision in the workpad so it survives context compaction), then add the `.changeset/*.md`
file **after the draft PR exists but before the review pass** — so the prose can cite the PR
number and the changeset lands inside the diff that `/simplify` and `/prflow:review-and-fix`
review. Name the file after the branch or issue (e.g. `issue-290-<slug>.md`) so it never
collides with a concurrent PR's. The Phase 4.3 clean-tree backstop is the final guard that
the changeset never ends up uncommitted.

**Commit-message contract (load-bearing — do not drift).** The merge-time consolidation
commit's subject begins with the literal `chore: bump version`. This prefix is not cosmetic:
the release-notes reconciliation step (`skills/docs-release-notes/SKILL.md` Step 4b) uses this
prefix to **confirm a version bump happened** — it then reads the authoritative version from
`.claude-plugin/plugin.json` (never from the commit subject, which a later re-version can
leave stale) and reconciles that version's CHANGELOG entry, or no-ops if no such commit
exists. **Note the consequence for DevFlow's own PRs:** because the bump commit is now created
at merge time on `main` (not on the feature branch), Step 4b's branch-scoped
`origin/main..HEAD` scan legitimately finds no bump commit during `/prflow:implement` and
no-ops — that reconciliation stays live only for consumer repos that still bump in-PR. Here,
CHANGELOG correctness rests on the in-diff changeset prose, which the Phase 2.3.4a self-claim
sweep and Phase 4.2 keep aligned with the shipped diff. The producer of the subject is now the
merge-time Action, not this skill; renaming it
(e.g. to `chore(release): …`) makes Step 4b see no bump and silently disables that
reconciliation. The producer (`version-consolidate.yml`) and consumer (Step 4b) are kept in
lockstep by a coupling pin in `lib/test/run.sh`; change one and the suite goes RED until the
other matches.

## The project's preflight-guaranteed tool set (for §2.3.6's un-guaranteed-tool sweep)

The base skill's §2.3.6 un-guaranteed-tool guard class keys on "a tool **the project's
preflight** does not guarantee." For this repository, that preflight set is fixed and small:
DevFlow's preflight guarantees exactly **git, gh (authenticated), jq, and python3 (>=3.11) with PyYAML**
— the same set `lib/preflight.sh`'s header declares (this enumeration is a coupled mirror of that
header; `lib/test/run.sh` pins the two, so renaming or removing a tool on either side turns
the suite RED; a tool *added* to the preflight set is reconciled here by the §2.3.0b
enumeration-reconciliation sweep, not by these pins). Everything else a helper might
reach for on `PATH` — `tr`, `sed`, `awk`, `cut`, `wc`, `head`, `paste` — is **not** guaranteed: a
value that decides a selection or an emitted result must not be derived through one of those (derive
it with bash builtins instead), while cosmetic sanitization through them is acceptable only when a
missing tool fails closed. This concrete set is what instantiates "the project's preflight" in the
base skill's generic wording; the base skill stays repo-agnostic and names no tools.

## Comment discipline — do not preserve mirror facts with wording pins

The base skill's §2.3 authoring rule keeps mirror-fact comments (an exact count, an
enumerated list of sites/values, a scope word restating a predicate, narration of what
adjacent code does) out of the diff or makes them drift-proof. Remove or rewrite a mirror
fact as a lower bound or a pointer to the defining symbol. When the underlying claim is
load-bearing, prefer a behavioral test at the executable boundary that would fail when the
implementation drifts; do not preserve the comment with a comment-presence or wording-presence
pin. Header and contract comments — fail-closed decision matrices, cross-file
producer/consumer contracts, and the issue provenance of a non-obvious shape — remain
load-bearing prose, but their prose presence alone is not a test target.

## Behavioral regressions — executable evidence, not attestation

When a test protects a **named behavioral regression**, exercise the rendered
interface or machine-observable contract with an ordinary executable test. Break the
behavior on a scratch copy or fixture, observe that executable test go RED, and then
restore the correct behavior. Do not encode the regression as source-text presence;
the former mutation-taking helpers and wrappers are retired.

Then record **evidence, not an attestation**. The workpad `--note` records the
behavior you broke and the executable test you observed go RED — a reproducible fact.
A note that merely testifies that a guard is relevant proves nothing a reviewer can
re-run.

**Wording-only pins are prohibited.** A wording-only pin is a test whose protected literal can
change without changing executable behavior and without breaking a machine-consumed contract.
Do not add wording-only, secondary-prose, documentation-presence, advisory-heading, or
comment-presence pins, whether expressed through a pin helper or a raw `grep`/text-presence
assertion. An operative prompt regression is behavioral: exercise the rendered or
consumed prompt with an ordinary executable test, break the behavior in a scratch
fixture, and demonstrate that test going RED.

The only new non-mutation presence pins permitted are executable-boundary pins classified by
this closed set: `helper-contract`, `schema-config-vocabulary`,
`security-credential-boundary`, `machine-sentinel-provenance`,
`routing-dispatch-contract`, `lifecycle-state-transition`,
`generated-artifact-identity`, and `cross-file-phase-contract`. Their logical line must carry
the format-strict declaration
`# structural-pin-ok: <category> -- <rationale>`, with one category from that set and a
nonempty rationale explaining the machine-consumed or executable boundary. The
diff-scoped `mutation-routing` gate applies this same policy to helper-based and raw presence
assertions; unchanged legacy sites need no backfill. A marker never turns protected prose into
an executable boundary.

## Verification under classifier friction — never ship an unverified assumption

The sandbox permission classifier in this repo frequently denies the very commands that
verify your change — `bash lib/test/run.sh`, `shellcheck`, script-by-path invocations,
file redirection, and live `gh`/network calls. A blocked verification command is **not**
license to assume the change is fine and move on. When a verification you would normally
run is denied, do this in order — do not skip to the last rung:

1. **Retry via the documented authorized path before assuming anything.** The classifier
   denies *forms*, not the work itself: the project test suite and `shellcheck` run fine
   when launched through a `python3 -c "subprocess.run(...)"` wrapper (the authorized
   project commands per `CLAUDE.md`), and files write fine via the Write tool instead of
   shell redirection. Reach for these wrappers *first*; a denied first invocation almost
   never means the verification is truly impossible here.
2. **If the verification is genuinely impossible** (e.g. a live `gh` call needs auth or
   network the sandbox lacks), do the strongest reachable substitute — exercise the code
   path against a stub/fixture — and then **record the residual gap as an explicit
   `## Devflow Reflection` bullet** that names the unverified claim, why it could not be
   exercised live, and the failure mode if the assumption is wrong. Write it as
   *"code-verified via stub, live-unverified: <claim>"*, never as *"impact assessed as
   nil"* or any phrasing that implies it was actually checked.
3. **Never let a verification you skipped read as a verification you passed.** Do not
   assert a test suite, lint, or behavior is clean unless you ran it (directly or via the
   authorized wrapper) and saw the result. An unverified assumption stated as fact is the
   exact failure this rule exists to stop — surface it as an open gap, not a conclusion.

The standard is *evidence before assertion*: a claim that something works must point to a
command you actually ran and its observed output, or be explicitly flagged unverified.

## Focused test modules are the iteration default

Before choosing an iteration test, use the task context or test plan — and the coverage map
(`lib/test/modules/coverage-map.json`, which records the owning module for every `lib/`/`scripts/`
unit and `run.sh` block, and a `focused_test` field naming the covering Python test for a unit no
shell module owns) — to identify a candidate
module, then confirm its exact ID in `scripts/workflow-flight-recorder-registry.json` and inspect
the registered module when needed to establish coverage. Explicitly record the selected ID and
use `bash lib/test/run-module.sh <module-id>` for RED/GREEN iteration. For **local create-issue
contract iteration only**, select `create-issue-contract` and run exactly
`bash lib/test/run-module.sh create-issue-contract` for the RED/GREEN loop. If the classifier denies
the `bash` wrapper, retry the same command with the runner path as the leading token:
`lib/test/run-module.sh <module-id>`. On a cloud tier that grants the focused runner, the direct
leading-token form `lib/test/run-module.sh <module-id>` is the mandated invocation (the `bash`
wrapper stays deny-floored on cloud, so a wrapper-first mandate would burn the run's budget on
denials). Consulting the coverage map to identify a candidate module is part of explicit selection —
record the map entry you consulted and still confirm the selected ID in the registry.
Do not infer or automate changed-file-to-module routing.

Focused verification is the iteration default: a focused pass covering the changed surface is sufficient for an intermediate commit or push.

**Tier 1 — iterate on the covering focused test.** When a covering focused test exists, iterate on it rather than the full suite. A changed `scripts/*.py` or `lib/*.py` unit whose coverage-map entry names a `focused_test` routes to that test, invoked as a **direct leading token** — `lib/test/test_python_scripts.py`, or a narrower `lib/test/test_python_scripts.py SomeClass.test_name` — and **never** as `python3 <path>`, the interpreter-head shape the cloud matcher denies (issue #401); these files carry the exec bit and are granted as direct-token forms via `.prflow/config.json`'s `prflow_implement.allowed_tools` (issue #1078 moved them out of the shipped `implement` profile into that self-repo grant channel, where they benefit this repo's own runs without pre-authorizing colliding paths in a consumer), so the form holds on the cloud implement tier too — on any other tier, use it only when that tier grants it and otherwise fall back to the already-permitted full suite rather than emitting a command the matcher will silently refuse. A shell surface with a registered module keeps `lib/test/run-module.sh <module-id>` as above. Selection stays explicit and agent-consulted: record the coverage-map entry you consulted and the target you selected. Losing this prose to compaction or an auto-resume degrades to the full-suite default — slower, never incorrect.

**The selection record has a named sink — a named record of its own, never free prose in a general-purpose field.** Write it through `scripts/focused_selection.py`'s record shape (`build_record` → a machine-parseable dict; `encode_marker` → the `<!-- prflow:focused-selection … -->` marker; `decode_markers` reads it back). Per **touched surface** the record names either the coverage-map entry consulted and the target selected (a discharging focused result), or which of the four exemption grounds applied. On an **implement run** the sink is the issue workpad through `scripts/workpad.py` — record the marker as a `## Progress` note (`workpad.py update <ISSUE_NUMBER> --note "<marker>"`). On a **standalone fix loop** the sink is the iteration record `iter-<N>.json`'s `verification_evidence` object, which gains a `focused_selection` field holding that same record (see `skills/review-and-fix/references/fixing.md`). This is what makes a followed rule and an ignored one leave *distinguishable* traces: a run that consulted the map records the per-surface entries; a run that skipped straight to the full suite records none. It adds **no** launch counter, **no** launch ordinal, and no mechanical changed-file-to-module routing — the caller supplies the touched-surface set; nothing here derives it.

**Tier 2 — coalescing extraction.** When **no** covering focused test exists (a `lib/test/run.sh`-resident shell block), use the full suite for the **first** mid-iteration cycle on that surface. Only a **second** mid-iteration cycle on the same uncovered surface triggers a durable module extraction — dispatched as an Agent-tool subagent (never a nested interactive skill), written RED-first, and registered (its `lib/test/coverage_map_guard.py` repair now runs in-env on both tiers) — after which the run iterates on `lib/test/run-module.sh <new-id>`. A one-off fix pays one full run; an iteratively-fixed surface extracts once.

**The full-suite fallback is a closed set**, complete by construction. The full suite remains the mid-iteration test in exactly these cases: (a) a surface whose checks require `run.sh`'s full-suite global setup; (b) a check that legitimately self-skips, which a module may not (`run-module.sh` makes `skip()` fatal); (c) a surface whose tier-2 extraction cannot be completed — a cross-cutting `run.sh` helper spanning many `run_sh_blocks` that no single module can isolate, or a `--fix` that leaves residual drift; (d) the first mid-iteration cycle on a `run.sh`-resident surface, before a second cycle warrants extraction. A run that takes any of them records a `## Devflow Reflection` bullet naming **which** case applied.
The reflection-routing rule below carries this as a named capture case, so it stays a Reflection bullet — not the cheap `## Progress` note — even when the run was otherwise frictionless.

**Focused-first is a precondition on the mid-iteration full-suite launch, not merely routing advice.** Before a run launches the complete suite **mid-iteration**, every touched surface that has a covering focused test invocable on this tier must already have been run this cycle. "Has a covering focused test" is answered by the two coverage-map fields the selection rule above already consults together — a `focused_test` entry for a Python unit, **or** a registered module id in `owner` for a shell surface routed through the focused-module runner. A surface is **exempt** on any of four grounds, and the set is total: (1) it has **no coverage-map entry at all** — the majority case, since the map is populated only from `lib/` and `scripts/`, so every prompt surface, doc, and root-level record has none; (2) it sits under a **declared exempt subtree**; (3) its entry is **`unmodularized` with no `focused_test`**; or (4) its **covering test is not invocable on the running tier** (the tier does not grant its token) — which routes that surface to the full suite exactly as the tier-grant fallback above already directs. A covering focused test that **ran and failed** also discharges the precondition, for the sole purpose of launching the full suite to diagnose the failure; the completion-claim gate is unchanged. The per-surface obligation is discharged exactly as the selection rule above directs — explicit, agent-consulted selection recording the consulted coverage-map entry and the selected target **per surface**, into the named focused-selection sink above, each surface's entry stating either its discharging focused result or the exemption ground that applied — and it is **not** a licence to derive the touched-surface set mechanically: the prohibition on inferring or automating changed-file-to-module routing above is unchanged. This adds **no** full-suite launch counter and **no** launch ordinal, and the existing per-launch closed-set reflection bullet naming which case applied is unchanged. The precondition binds the **mid-iteration** launch only; the final completion gate's full-suite launch is **not** gated on it, preserving the division stated below whereby a focused result discharges intermediate iteration only. And it never inverts the compaction/auto-resume degradation sentence above: a run that cannot establish which covering focused tests it already ran this cycle **re-runs them** — an unestablished touched-surface record is **not** a satisfied precondition — and where the record of the touched surfaces themselves is lost it degrades to the full-suite default rather than being blocked behind an unsatisfiable precondition.

A mid-iteration `#434` stale-prose `blocking-gate` skip on a dirty tree is **expected** — it clears once the tree is committed — so never re-run the full suite mid-iteration solely to clear it. **What the run does instead is commit the tree, then continue:** committing is the action the skip calls for, and it clears the skip, where a fresh full-suite run does not. The `#434` self-scan is unmodified, and the completion-claim skip rule stated below is preserved unchanged.

Full-suite runs are coalesced through the existing `scripts/verification-flight.py` single flight (`#528`): diagnose from the run's own `Failure recap` — for the serial primitive the list `lib/test/run.sh` prints at the end of a failing run, and for the coordinator the recap `shard-tally.py combine` renders, plus the complete shard logs under the retained-log root where the per-class detail cap elided entries — instead of relaunching, and mid-iteration prefer the covering focused test. **Consult the single flight before any full-suite relaunch, and record that you did:** read `scripts/verification-flight.py`'s durable status handle first, and when it already holds a clean result for the current tree read that result rather than re-producing it. Record the consultation in the named focused-selection sink above — its `single_flight_consulted` field — so a consulted flight (an existing clean result read rather than relaunched) is distinguishable from an unconsulted one.

**Running the suite without blocking — use `lib/test/launch-detached.py` (issue #1216).** When you launch `lib/test/run.sh` or `lib/test/run-parallel.sh` from a wrapper that backgrounds it (a `subprocess.run(...)` shim, a `cmd &` from a job-control-off shell), invoke it as `python3 lib/test/launch-detached.py <suite command>`. The launcher restores SIGHUP/SIGINT/SIGQUIT/SIGTERM to their default disposition in the child and places it in a new session, then reports the child's real exit status — without it, a backgrounded launch hands the suite an ignored SIGINT that its signal-trap assertions cannot handle (they fail, or the launch-window case hangs), and a child left in the launcher's process group is torn down by the group's own signals mid-run.

**Verification-flight scope — the single statement.** Only a **whole-suite** result discharges the Phase 4.3 completion-evidence gate: a focused result discharges intermediate iteration only, never the final completion gate. This sentence is that rule's one home; every other mention of the scope — later in this file, in `skills/implement/phases/phase-4-documentation.md`, and in `CLAUDE.md`'s tiered-runner bullet — points here rather than restating it. A whole-suite result is one the coordinator produced in a single run, or one recombined from the complete shard partition per the decomposition path below; both cover the same population, and nothing else is whole-suite.
The final gate is preserved, and on the local/interactive tier it is parallelized.
Before a completion or PR-ready claim, issue the CI-triggering push and the full local run **in a single assistant turn** so they execute in parallel; the push is NOT gated on the local run finishing.
The **claim** is gated on it: read the local run's summary before you make one. A nonzero failure tally, a nonempty skip tally, a **non-zero exit status** (which the coordinator returns for a shard that did not complete even when its tally reads clean), or a run that never started (denied, blocked, or unreached) is not a completion — report the failure detail and iterate, and say so explicitly rather than letting the already-landed push stand as the claim.
**The final full-suite command is the parallel coordinator `lib/test/run-parallel.sh` (issue #1086).** It runs the same tested partition CI shards — the population comes from `lib/test/run-shard.sh --list-shards` — concurrently inside this checkout, recombines it through `lib/test/shard-tally.py`, retains every launched shard's complete log under an ignored run root, and prints one compact aggregate instead of the whole assertion stream. **Grant-timing caveat — a grant the PR itself ships is inert in that PR's own run.** `prflow_implement.allowed_tools` / `prflow.allowed_tools` are resolved by the `config` job's **trigger-time checkout of the default branch**, while this file is read at runtime from the *checked-out working tree* — so on a PR that is itself adding a grant, the instruction naming that command is live and the grant is not, and the invocation is **silently denied**. So on the cloud tier, if any whole-suite command below emits no output at all, treat it as a **denial**, not an empty result: fall back to a whole-suite form whose grant is already on the default branch, and go **Blocked** naming `prflow_implement.allowed_tools` as the remedy only when no such form remains. On the **cloud** tier invoke it as a **direct leading token**, `lib/test/run-parallel.sh`, with nothing around it: it owns its own environment assignments, redirects, background processes and aggregation precisely because the matcher refuses those shapes caller-side (issues #401/#455), so a bare granted token is the entire command. On the **local/interactive** tier invoke it through the documented `DEVFLOW_BASH` selection boundary (`CLAUDE.md`'s invocation-layer override), the same boundary every other `.sh` helper is chosen by here.
**When the coordinator exceeds the tier's per-command execution ceiling, decompose it — do not downgrade the evidence (issue #1132).** The observable predicate is a coordinator (or serial-primitive) invocation the tier *terminates on time* rather than one that runs to a verdict — on the cloud implement tier that ceiling is set at *authoring* time by `devflow-implement.yml` (the Claude step's `settings` input sets `BASH_MAX_TIMEOUT_MS` — 20 minutes as of issue #1179, above Claude Code's 600000 ms default), and while its *value* is fixed by the workflow it is not escapable *in-run*: an agent mid-run cannot raise its own ceiling (`CLAUDE_CODE_DISABLE_BACKGROUND_TASKS` is set and `nohup` is ungranted). On that predicate, run the same partition one shard at a time and recombine it, exactly as CI satisfies the same required check: enumerate the population with `lib/test/run-shard.sh --list-shards`, run **every** shard it names as `lib/test/run-shard.sh <shard>` (each is well inside the ceiling), then recombine with `lib/test/shard-tally.py combine` over the explicit tally paths of **this** run only. The recombined result is a whole-suite result under the single statement above and discharges the gate on the same terms as the coordinator's: the `#456` skip accounting is unchanged, and a missing shard, a nonzero failure tally, or a nonempty skip tally is not a completion. Substituting a focused module for the recombined run is the downgrade this path exists to replace.
`lib/test/run.sh` stays the **serial primitive**: the `monolith` shard runs it, and the uncovered-surface fallback above still names it. Focused iteration is unchanged — `lib/test/run-module.sh <module-id>` and the coverage map's `focused_test` files remain the iteration default, and this coordinator is the final gate, never the iteration loop.
The full local run is that coordinator plus every lint gate required by `CLAUDE.md` (using its documented classifier fallback when necessary), and it remains the authoritative local signal because it yields richer failure detail than CI for troubleshooting. A nonempty skip tally is not clean.
The cloud `/prflow:implement` in-env gate (issue #405) is unchanged and unweakened: such a run verifies in its own environment and never waits on, polls, re-checks, or cites CI for its own progress; the parallel-push allowance above is a local/interactive-tier rule only. The final full-suite obligation binds the cloud tier too: a cloud completion claim rests on an in-env **whole-suite** result per the single statement above — the coordinator, or the recombined shard partition when the ceiling terminated it — plus every required lint gate, run in the cloud run's own environment, not on any CI result the run never saw.
**Do not read the coordinator's wall-clock as CI's.** CI isolates each shard on its own runner; the coordinator's shards share one host's CPU, memory, checkout and process namespace, so its `real` time is the slowest shard *under contention*, not the slowest runner.
Full-suite ownership still flows through `scripts/verification-flight.py`. That helper requires only a non-empty terminal-evidence object and mandates no particular field, so recording the **coordinator command identity**, the **compact aggregate**, the **exit status**, the **skip population**, and the **retained-log root** in that evidence is a caller obligation this repository adopts, not a behavior the helper enforces — and the retained-log root is what makes a failing flight diagnosable without relaunching, since the aggregate itself is capped per detail class by the coordinator's own `DETAIL_CAP` constant.

**Every tier that maintains a workpad — capture each parallel full-suite launch and record a `Verification evidence:` marker (issues #719, #1249).** Because the parallelized gate launches the full run *concurrently* with the CI-triggering push — not serialized behind it as the pre-#707 gate was — a launch that is denied, blocked, or never reached leaves no trace, so "push, nothing to read, claim made" is otherwise indistinguishable from "push, ran the suite, read a clean summary, claim made"; and a run that launches the suite **more than once** — a first launch that fails, a second that comes back clean — otherwise records only the launch it happens to mention, leaving the earlier one nowhere in the repository (issue #1249). To make both distinguishable, let the coordinator retain each launch for you: `lib/test/run-parallel.sh` writes every launched shard's complete log under its own run root and prints that root, so the caller composes **no redirect of its own** — the capture is the coordinator's retained-log root rather than a `>`-redirected file. Then, before the completion claim, record the marker literal `Verification evidence:` in the workpad through `scripts/workpad.py` — **once for each whole-suite launch the run performs**, so a run that performs more than one launch ends with **more than one record**, never a single record that mentions only the final launch. A completion claim missing a record for a launch that ran is an **inspectable** defect rather than an indistinguishable one — the refused-launch terminal, and every earlier launch, is legible in the workpad, not only in prose.

**What each record carries, and how launches are told apart (issue #1249).** Each `Verification evidence:` bullet names: the **command invoked**; the launch's **outcome as the coordinator itself reported it** — its `aggregate CLEAN` / `aggregate FAILED` line; the **pass, fail, and skip tallies** when the launch reported them; and the **coordinator's retained-log root**. The records are distinguished by that **distinct run root the coordinator mints and prints per launch** — `lib/test/run-parallel.sh` allocates a fresh `run-<pid>-<n>` root every launch — so there is **no launch counter and no launch ordinal to maintain**: the number of records is simply the number of launches. Three paths produce **no coordinator run root**, and each names what to record instead: a launch the tier **denied** (no output at all — the issue #401 silent-denial shape — record that the launch was refused, with no root); a launch the tier **terminated at its per-command execution ceiling** (issue #1132 — record the termination, then route to the shard decomposition, which has its own Phase 4.3 terminal); and the **shard-decomposition** path itself, where the whole-suite result is recombined by `lib/test/shard-tally.py` rather than produced by one coordinator — its record names the recombination and the shard tally rather than a single run root.

Record the marker with the **`note`** reflection kind (`scripts/workpad.py update <ISSUE_NUMBER> --reflection-kind note --reflection "Verification evidence: …"`): `note` is the only kind `lib/cheap-gate.jq` does not treat as friction, so a marker recorded as any other kind would flip an otherwise-clean run and make the retrospective gate fire on exactly the runs that complied (a `note`-kind bullet under `### ℹ️ Notes` is exempt from `reflections_friction_count`, and the gate counts friction, not bullets, so recording one marker per launch adds no retrospective cost). **Fallback channel when there is no workpad:** a direct reception pass on a branch with no linked issue (`lib/fetch-pr-context.sh` emits `NoIssue`) has no workpad, so record the marker in the **PR description** instead; a run with **neither** a workpad nor a PR names that terminal explicitly and reports the evidence as **unrecordable** rather than stalling. This is **artifact vocabulary plus a captured artifact, not runtime enforcement** — the retained-log root and the workpad bullet are what a later reader, a reviewer, and the retrospective inspect. **The obligation binds every tier that maintains a workpad — cloud `/prflow:implement` included (issue #1249).** The issue-#405 in-env verification rule is unchanged and unweakened; on top of it, a cloud run records one `Verification evidence:` marker per whole-suite launch on its workpad exactly as a local run does, so a repeated or failed cloud launch is **legible in the repository's own records** rather than recoverable only by downloading a run transcript by hand. `lib/cheap-gate.jq` remains **deliberately unwired** to the marker: wiring it would change retrospective sampling for every merged PR, which is a separate decision (see that file's head comment and issue #1249's out-of-scope note) — not, as before, because the marker's population excluded the gate's. This change makes a repeated or failed launch **legible, not prevented** — per-launch completeness is not machine-checkable, so the review-engine advisory below (whose home states this) can only observe that at least one record is present.

## Stopping a suite process — by recorded PID, never by pattern

This checkout's working mode is sibling git worktrees under `.claude/worktrees/` — dozens of them, each able to be running its own full or sharded suite at the same time as yours, under the same command names. A `pgrep -f` / `pkill -f` over `lib/test/run.sh`, `lib/test/run-parallel.sh`, `lib/test/run-shard.sh` or `lib/test/run-module.sh` therefore matches **other branches' live runs**, and nothing in the matched output attributes a PID to a checkout. Never sweep by pattern here, however narrow the pattern looks.

**The coordinator already records its own PID for you.** `lib/test/run-parallel.sh` allocates its run root as `.prflow/tmp/parallel-suite/run-$$-<n>` and prints that path, so the run root's directory name *encodes* the coordinator's PID (`run-<pid>-<n>`) — the coordinator you launched is identified by the path it already reported. Shard PIDs are held only in the coordinator's in-memory `RUNNING` list and are not written to disk; each shard is its own process-group leader and the coordinator's signal traps tear them all down (forwarding a group-kill, `-$pid`, to each shard's process group on teardown), so terminating the coordinator you recorded is the whole remedy — no follow-up sweep is needed, and one is never authorized.

**Clearing a genuinely stale coordinator.** Do it by PID, one at a time: read the candidate PIDs out of the run-root directory names under `.prflow/tmp/parallel-suite/`, and for each confirm with `ps -o ppid=,lstart=,etime= -p <pid>` that it is orphaned (PPID 1), childless, and old enough to be stale. Only then `kill <pid>`. **A run root is retained after its run exits and PIDs are recycled**, so a run-root name identifies a *run*, not necessarily a live process of that run — the `ps` cross-check is what makes the PID attributable, and without it you are back to guessing. If the cross-check does not resolve, leave the process alone and say so.

## Repo-specific command names and coupled-pin recognizers (relocation destination, issue #1072)

The phase files state their verification, relocation and capability-boundary obligations
**generically** — "the project's own test/lint command", "the project's own relocation check",
"a coupled test-suite pin that asserts workflow content" — because the concrete command names
and pin recognizers below are this repository's own and must never ship to a consumer whose
tree does not carry them (`lib/test/**` is pruned from the vendored plugin by
`.github/actions/vendor-plugin/vendor-slice.sh`). The **form constraint stays in the phase
files**: on the cloud tier every verification/relocation command is invoked as the command's
**leading token**, never behind a `bash <path>` wrapper (deny-floored). Only the concrete names
live here, so a run whose extension was lost to compaction still reads a phase-file sentence
sufficient to avoid the denied shape.

- **The project's own test command** is `lib/test/run.sh` (the serial primitive) and, for the
  final full suite, `lib/test/run-parallel.sh`; a focused surface uses
  `lib/test/run-module.sh <module-id>`. These are already stated in full in the verification
  section above — the relocation from `skills/implement/phases/phase-3-review.md`'s in-env
  verification rule and single-flight paragraph adds nothing beyond confirming that this is the
  concrete command those now-generic phase sentences mean. Invoke each as a **direct leading
  token** on the cloud tier; the `bash <path>` wrapper is deny-floored.
- **The project's own relocation check** is `lib/test/pin-corpus-lint.py --reloc` — the
  deterministic desk-time net `skills/implement/phases/phase-2-implement.md`'s relocation sweep
  now names generically. It turns a bare `ABSENT` pin into `relocated to <file>` and fails
  closed on a genuine deletion or an unresolvable search set. On the cloud implement tier it has
  no direct-token grant and `python3 <path>` is the denied interpreter-head shape, so the
  relocation reconciliation is discharged by observing the full suite green (its drift check is
  what turns red on an unreconciled citation); the local/interactive tier runs it directly.
- **The coupled test-suite pin that asserts workflow content** — the recognizer
  `skills/implement/phases/phase-1-setup.md`'s Pass 5 scan, its provisional-flag paragraph, and
  `skills/implement/phases/phase-2-implement.md`'s commit guard now name generically — is, in
  this repository, a `lib/test/run.sh` pin. That is the concrete literal Pass 5 detects a
  workflow-resident AC from, and the concrete pin the workflows-scoped commit-guard greps miss
  (they list only the workflow file itself); reverting a workflow-resident AC on a
  workflow-incapable cloud credential reverts that coupled `lib/test/run.sh` pin with it so the
  pushable remainder stays CI-green.

## Interpreter-faithful probes — probe under the shell the artifact actually runs under

When you probe behavior that depends on the **interpreter or environment** an artifact runs under —
a shell built-in's expansion, a `printf` escape, a locale effect, a version-specific behavior — run
the probe under the interpreter the artifact actually runs under, and
prefer mutation evidence over a hand probe when the two disagree. That mutation
evidence must come from an ordinary executable test running under the artifact's real
interpreter, never from a retired source-text mutation helper. A probe run under the *wrong*
interpreter reports a **false vacuity**: an assertion that is live under the artifact's real shell
looks dead under whatever shell you happened to type into, and chasing that phantom costs real effort —
multiplied across every reviewer who repeats the same wrong-interpreter probe — while finding zero real
defects. The artifact's own shebang (or its runner's invocation) is the authority for which interpreter
is "actual"; a mutation that breaks the behavior and turns the executable test red is decisive where a hand
probe under a different shell is not.

**#340 reproduction (local instance):** a test loop drives eight separators through `printf '%b'`. Three
of them are multibyte octal escapes. Bash expands them; that session's zsh does not. The orchestrator and
two independent reviewers each probed under zsh, saw literal backslash text, and briefly concluded three
assertions were vacuous. They were not — the suite's shebang is bash, and the executable suite evidence was
decisive. Cost: real effort, three times over; defects found: zero. **PR #340 cost this would have
eliminated:** the three false vacuity alarms — duplicated investigative effort across the orchestrator
and two reviewers with zero defects found.

## Dogfood every run — capture process-improvement signal (standing side task)

This repository runs `/prflow:implement` under DevFlow's **own** engine, so every run
here is a live test of that engine. Treat improving DevFlow as a standing **side task** of
this run, second only to shipping the issue itself: while you work the four phases, actively
watch the process and record what you learn so future implement runs are better. The weekly
`/prflow:retrospective-weekly` loop mines exactly these notes — a `## Devflow Reflection`
bullet is the mechanism by which a friction you hit today becomes a fix tomorrow.

**What to capture** (in the `## Devflow Reflection` section, as you go — do not batch to the
end, where context compaction will have dropped the detail):

- **Bugs** in any DevFlow skill, script, workflow, or agent you exercised — a helper that
  failed, a wrong breadcrumb, a gate that fired incorrectly, a doc that contradicted behavior.
- **Friction** — steps that were confusing, redundant, ordered awkwardly, or missing; a
  classifier/permission denial that forced a workaround; anything that made the run harder
  than it should have been.
- **Problematic dependencies** — a coupled-site pair that was easy to desync, a silent-fail
  consumer, a fragile assumption, a resolver/anchor that behaved unexpectedly on this runtime.
- **Improvement ideas** the run surfaced, even if you did not act on them.

**How to record it.** Append each observation with
`scripts/workpad.py update <ISSUE_NUMBER> --reflection-kind improvement --reflection "<observation>"`
— an engine/process-improvement proposal is an `improvement` (it lands under `### 💡
Improvements`). Reserve the other kinds for what they mean: `note` (a friction or deviation you
worked around), `issue-accuracy` (the driving issue's own claims were wrong or underspecified),
`blocked` (a hard stop), `deferred` (punted work), `dropped-failed` (a subagent/step that failed
and you continued past). Name the **concrete surface** — the file, skill, or step — and the
specific improvement, so the retrospective can act without re-deriving what you already saw. This
is **additive** to the verification-gap reflections above and to the reflections the base skill
already writes (deferrals, reverts, post-review code fixes); it does not replace any of them.

**Before finalizing (Phase 4.3), confirm the side task ran — and record the confirmation on
the *right* surface, because the surface carries a cost.** `lib/cheap-gate.jq` forces an LLM
retrospective pass on any run that left **even one** `## Devflow Reflection` bullet, so a
reflection is the expensive-but-loud surface and a `## Progress` note is the cheap-but-quiet
one. Route by whether the run actually had signal:

- **The run hit real friction / a bug / a hazard** → it is already a `## Devflow Reflection`
  bullet (an `improvement`, `note`, or `issue-accuracy` per *How to record it* above). That is
  exactly the signal the retrospective must be forced to read; the gate tripping here is
  correct, not waste.
- **The run performed a full `lib/test/run.sh` run mid-iteration** (no registered module
  covered the changed surface — see *Focused test modules are the iteration default* above) → this
  **is** a `## Devflow Reflection` bullet, even on an otherwise frictionless run. The missing
  focused coverage IS the signal: it names a concrete surface no module reaches, which is exactly
  the ranked to-do list the retrospective turns into the next extraction ticket. Record it as
  an `improvement` (the kind that lands under `### 💡 Improvements`), so two runs reporting the
  same missing-module signal file it under one heading. This case is scoped to a **mid-iteration**
  full run — the final-gate run is mandatory on every run, so requiring a bullet for it would trip
  `cheap-gate.jq` on every PR and carry no signal. Paying the cheap-gate's LLM pass to surface a
  coverage gap is the trade this rule buys deliberately.
- **The run was genuinely frictionless end-to-end** (and ran no mid-iteration full suite) → do **not** file a `--reflection` bullet
  for it. Record the confirmation as a `## Progress` note instead:
  `scripts/workpad.py update <ISSUE_NUMBER> --note "dogfood side task ran: frictionless, nothing to capture"`.
  A `--note` writes to `## Progress`, which does **not** feed `reflections[]`, so `## Devflow
  Reflection` stays empty and `cheap-gate.jq` still skips the clean PR cheaply — while the
  Progress note still proves the side task was run, not silently skipped.

An implement run that shipped the issue, hit no friction, and left **neither** a Reflection
bullet nor this Progress note has skipped the side task; empty-and-silent is not done. Never
invent findings to fill Reflection — the frictionless *Progress note* is the honest terminal
state for a clean run, precisely so you never have to.

## Keeping prompt prose lean (advisory)

Prefer moving rare-path detail and long explanations into progressively loaded references
rather than growing mandatory prompt prose; when a tested helper owns a decision, let the
skill point at it instead of restating the branch logic. Keep the mandatory path lean. This
is guidance, not a gate — there is no byte census, ceiling, or cutover artifact to satisfy.

## Prompt-surface edit routing (repo policy)

`CLAUDE.md`'s "Editing any skill file" convention mandates the `superpowers:writing-skills`
RED/GREEN discipline before any `SKILL.md` edit, and this repo extends that mandate to its
**prompt-surface** files. An autonomous `/prflow:implement` run must **not** invoke
`writing-skills` through the **Skill tool** mid-phase — a mid-phase Skill-tool call is a tail
call that adopts the nested skill's flow as the run's whole task and strands the run (the
engine's #362 exclusionary Skill rule, which this extension preserves **unchanged**:
`writing-skills` is **not** added to the engine's three-skill allowlist). This repo instead
routes the discipline through a context-isolated **Agent-tool subagent**, where a Skill-tool
`writing-skills` invocation is safe because the skill's flow *is* the subagent's whole task.

**The trigger globs.** The routing fires on an edit to any path matching one of:
`skills/*/SKILL.md`, `skills/implement/phases/*.md`, `skills/implement/references/*.md`, `skills/review/phases/*.md`, `skills/review-and-fix/references/*.md`, `.prflow/prompt-extensions/*.md`.
(`agents/*.md` and skill companion/reference files *other than* the `skills/review-and-fix/references/*.md`
step references named above stay under the base skill's Phase 2 §2.4 discipline — out of scope for this routing.)

**The routing rule (edit-intent time).** Before making any edit to a path matching a trigger
glob, the orchestrator dispatches a context-isolated Agent-tool subagent whose prompt instructs
it to invoke `superpowers:writing-skills` and perform the edit under that skill's RED/GREEN
discipline, returning the edit and its evidence; the orchestrator itself does **not** invoke
`writing-skills` through the Skill tool mid-phase.

**The repair arm (resumed/compacted runs).** Evaluated **at extension load and again at Phase 3
entry**: when the branch diff already touches a trigger glob and the workpad carries no
`Writing-skills evidence:` marker, route the existing edits through the subagent for RED/GREEN
verification — recording the marker — before the run proceeds. These two always-reached anchors
make the arm fire even on a resumed or compacted run whose remaining work touches no trigger
path, the exact state the arm exists for. **Fail closed on an unresolvable operand:** the
trigger-glob operand is produced by reading the branch diff (`git diff` against the base) — if
that read **fails or cannot be resolved** (an unfetched/empty base ref, a git error), treat the
trigger-glob condition as **unknown → fire the arm**, never as "no trigger touched"; and an
unreadable workpad likewise reads as "no marker" (fire the arm). Both operands fail toward
*extra* verification, so a degraded read on the resumed/compacted state this arm protects can
never silently skip the RED/GREEN discipline.

**The fallback clause.** The subagent checks `writing-skills` against its available-skills list
**before** editing and quotes that check's outcome in its returned evidence. When the check
reports the skill **absent**, the edit is made under the base skill's Phase 2 §2.4 inline
RED/GREEN micro-test discipline instead, and the workpad records the degraded mode. The recorded
mode is **derived from the quoted check** — so `subagent` can never be recorded when the skill
never loaded.

**The evidence contract.** After any trigger-file edit, the workpad carries a line **containing**
the exact marker literal `Writing-skills evidence:`, recorded via the sanctioned `workpad.py
update --note` path (whose rendering prepends `  - HH:MM:SS — ` to every note, which is why the
contract is *containment*, never line-start). This `Writing-skills evidence:` marker literal is
the exact string the review-gate criterion matches (also as containment) — a coupled site,
pinned in lockstep across `review-and-fix.md` and `review.md`.

**The line's shape.** After the marker literal the line names the trigger files touched and
`mode=` (`subagent` for the dispatch path, `inline-degraded` for the fallback), then carries all
four slots below. Each slot is written `<slot>=yes` or `<slot>=no` followed by one clause in
parentheses:

| Slot | A `yes` clause states | A `no` clause states |
|---|---|---|
| `skill-loaded` | the quoted available-skills check outcome, which reported the skill present | why it did not load — that same check reported it absent, or could not be made |
| `guidance-applied` | which named guidance was applied | why none was |
| `pressure-scenario` | the subagent scenario run, and the baseline rationalization it captured verbatim | why the cycle does not fit this edit |
| `micro-tests` | the reps run and the no-guidance control | why not |

A worked line for the hardest case — a one-sentence factual correction to reference prose:

> Writing-skills evidence: skills/review/phases/phase-3-agents.md mode=subagent
> skill-loaded=yes (available-skills list reported `superpowers:writing-skills` PRESENT)
> guidance-applied=yes (Match the Form to the Failure — a stale fact is corrected in place, so
> the form stays a plain statement) pressure-scenario=no (the edit adds and relaxes no rule, so
> there is no discipline failure for a scenario to elicit) micro-tests=no (a corrected fact
> shapes no behavior, so a no-guidance control has no failure to exhibit)

**`no` is a discharging value.** `pressure-scenario=no` with its reason discharges that slot
exactly as `yes` does, and recording `no` is the expected outcome for an edit the cycle does not
fit. Neither this rule nor the review gate treats an unrun cycle as a defect; what both require
is a stated disposition, never a particular one.

**What `pressure-scenario=yes` asserts.** Record `yes` when a subagent ran against the *unedited*
text without the guidance and its rationalizations were captured verbatim — that run is the
observable event the slot names. When no such run happened the slot is `no`, because analysis of
what the edited text would do on some path is reasoning about the artifact, not that run.

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

Loop-induced edits drift the repo's checked-in generated records — editing a reached skill asset drifts the cloud-writer runtime manifest, and editing the capability manifest drifts the generated workflow literals — and discovering each one a full suite run at a time is the dominant cost of a Phase 2-3 iteration. The helper is the sole enumeration point for this repo's suite-owned generated artifacts, so this section deliberately lists no artifact inventory of its own — an inventory duplicated into prose is one that silently goes stale as artifacts are added. This batched pass does not discharge the existing Phase 2 stale-prose sweep: `scripts/stale-prose-lint.py` consumes a caller-selected diff on stdin and needs the correct post-image mode, so that separate sweep remains a completion-claim obligation.

Act on its report before starting the suite run: commit a changed manifest together with the edits that caused it, and resolve every printed exit-1-forcing judgment item under the governing policy that item names. Informational lines require reading, not action. A merge conflict in one of these regenerated records is resolved under the Merge conflicts in generated artifacts section, never by hand-merging its bytes.

**If the helper reports an INFRASTRUCTURE failure (its final line names it, and the run exits 2), at least one artifact was NEVER CHECKED.** Do not read those lines as informational: an unchecked artifact is unknown, not clean, and the report names the row that failed. Treat the batched pass as **undischarged** — record `batched-regeneration: skipped` naming the failing row (the pass ran but established nothing, so it discharges exactly as a skipped pass does), and fall back to the status-quo serial discovery for that artifact. Never record `run` on an exit-2 report.

**The unchecked verdict is residual, not an enumeration of the helper's declared states.** Any outcome that is not a clean exit 0 carrying a per-row line for every registered row — a traceback, an empty report, a truncated one, an exit code you cannot attribute — is equally an unchecked pass, whether or not the literal `INFRASTRUCTURE` appears. Record `batched-regeneration: skipped` naming what you actually observed. Keying this on the enumerated tokens alone is what would let a novel failure shape read as "nothing to do". Note that an exit-2 run may still have **written**: any writing row that already completed has left its declared `writes` on disk, and the write surface is more than one file. Today those instances are the cloud-writer manifest `scripts/devflow-cloud-writer-contract.json`, and a completed exact-module floor raise, which lands in `scripts/workflow-flight-recorder-registry.json` together with its coupled `lib/test/run.sh` operands — a raise and its call sites move as one unit. Check for and commit every such regeneration even on an undischarged pass.

If the runner's permission matcher refuses the invocation **twice**, stop — do not iterate variants of the command (the issue-401 two-denials discipline). Record the refusal in the workpad and proceed to the suite run: the batched pass then degrades to the status-quo serial discovery, which is slower but never a silent stall.

On a run that maintains a workpad, record one discharge line before each full-suite run — `batched-regeneration: run|refused|skipped`. A compacted context that dropped this section then leaves an auditable gap rather than an undetectable silent revert to serial discovery.
