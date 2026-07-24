# DevFlow repo — operative policy for `/devflow:implement`

This repository (the DevFlow plugin itself) manages its own version and runs under a
permission classifier that routinely blocks shell invocations, so apply the following
when implementing an issue here. The base `/devflow:implement` skill is
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
number and the changeset lands inside the diff that `/simplify` and `/devflow:review-and-fix`
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
`origin/main..HEAD` scan legitimately finds no bump commit during `/devflow:implement` and
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

## Comment discipline — pin mirror-fact comments or don't write them

The base skill's §2.3 authoring rule keeps mirror-fact comments (an exact count, an
enumerated list of sites/values, a scope word restating a predicate, narration of what
adjacent code does) out of the diff or makes them drift-proof. This repository sharpens the
"drift-proof" alternative into a hard local rule: **a mirror-fact comment is written only if
it is pinned by a `lib/test/run.sh` assertion added in the same change — otherwise it is not
written.** With the pin in place, a later code change that strands the comment turns the suite
RED at the desk instead of shipping a stale comment to review; without it, the comment is
review-time-only again, which is exactly the rot this policy removes. Header and contract
comments — fail-closed decision matrices, cross-file producer/consumer contracts, and the
issue provenance of a non-obvious shape — are load-bearing and stay, pinned or not. **Prefer a
lower bound over an exact count in both the comment and its pin** (`at least N`, not `N`), so
adding an Nth site never forces a coupled edit of the comment and the assertion.

## Behavioral-fix pins — evidence, not attestation

When you add a **behavioral-fix pin** in this repo (a coverage pin added *specifically because*
removing the pinned text would re-introduce a **named** bug — the operative qualifier of a sweep
rule, a coupled-invariant pin, a regression guard), express it through **`assert_pin_red_under`**
— the mutation-taking removal-proof assertion in `lib/test/run.sh`
(`assert_pin_red_under <name> <literal> <mutation> [file]`) — passing a `sed -E`
**mutation that re-introduces the named bug** by removing *only* the operative sentence from a
scratch copy. Unlike `assert_pin_red_on_removal` (whole-line deletion, which reports PASS→FAIL for
*any* present-and-unique literal, framing or operative alike), `assert_pin_red_under` reports a
framing-only pin **RED** when it survives the operative mutation, so the pin proves it catches the
*guarded regression*, not merely its own line vanishing.

Then record **evidence, not an attestation**. The workpad `--note` records
**the mutation you ran and the pin you observed go RED** under it — a reproducible fact — instead of
the old unfalsifiable attestation that "the pin literal is a substring of the operative sentence." A
note that testifies about the pin proves nothing a reviewer can re-run; a note that states the
mutation and the observed RED verdict does.

This mandate is now **mechanically enforced** (issue #666). `lib/test/pin-corpus-lint.py`'s
`mutation-routing` gate, driven from `lib/test/run.sh`, reports a finding — turning the suite RED —
for any pin call site the change *adds* whose helper is not mutation-taking
(`assert_pin_unique`, `assert_pin_red_on_removal`, `devflow_module_pin_unique`,
`devflow_module_pin_present`) unless its logical line carries a format-strict
`# structural-pin-ok: <reason>` declaration. So a genuine **structural** pin — a surface-presence
or contract-presence pin whose removal breaks no behavioral guarantee — must carry that marker (a
one-line reason, the same reviewable artifact as the existing `# raw-guard-ok:` convention), and a
**behavioral-fix** pin must instead route through `assert_pin_red_under` per the rule above. The
gate is diff-scoped: it only flags pins the change adds, so the existing corpus needs no backfill.
Do not silence it with a false reason — the marker's reason is a reviewer-read diff line, exactly
like `# raw-guard-ok:`.

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
unit and `run.sh` block) — to identify a candidate
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
When no registered module covers the change, use the full suite during iteration.

Focused verification is the iteration default: a focused pass covering the changed surface is sufficient for an intermediate commit or push.
Run the full suite mid-iteration only when no registered module covers the changed surface, and when you do, record a `## Devflow Reflection` bullet stating why the full run was necessary (no registered module covered the changed surface).
The reflection-routing rule below carries this as a named capture case, so it stays a Reflection bullet — not the cheap `## Progress` note — even when the run was otherwise frictionless.

A focused result discharges intermediate iteration only, never the final completion gate.
The final gate is preserved, and on the local/interactive tier it is parallelized.
Before a completion or PR-ready claim, push to trigger CI and start the full local run at the same time; the push is NOT gated on the local run finishing.
The **claim** is gated on it: read the local run's summary before you make one. A nonzero failure tally, a nonempty skip tally, or a run that never started (denied, blocked, or unreached) is not a completion — report the failure detail and iterate, and say so explicitly rather than letting the already-landed push stand as the claim.
The full local run is `bash lib/test/run.sh` plus every lint gate required by `CLAUDE.md` (using its documented classifier fallback when necessary), and it remains the authoritative local signal because it yields richer failure detail than CI for troubleshooting. A nonempty skip tally is not clean.
The cloud `/devflow:implement` in-env gate (issue #405) is unchanged and unweakened: such a run verifies in its own environment and never waits on, polls, re-checks, or cites CI for its own progress; the parallel-push allowance above is a local/interactive-tier rule only. The final full-suite obligation binds the cloud tier too: a cloud completion claim rests on that in-env `bash lib/test/run.sh` (or a covering focused module) plus every required lint gate, run in the cloud run's own environment — not on any CI result the run never saw.

**Local/interactive tier — capture the parallel full-suite launch and record a `Verification evidence:` marker (issue #719).** Because the parallelized gate launches the full local run *concurrently* with the CI-triggering push — not serialized behind it as the pre-#707 gate was — a launch that is denied, blocked, or never reached leaves no trace, so "push, nothing to read, claim made" is otherwise indistinguishable from "push, ran the suite, read a clean summary, claim made". To make the two distinguishable, on the **local/interactive tier** capture the full-suite launch to a named file under `.devflow/tmp/` (redirect `bash lib/test/run.sh` to e.g. `.devflow/tmp/verification-<ISSUE_NUMBER>.log`) and, before the completion claim, record the exact marker literal `Verification evidence:` in the workpad through `scripts/workpad.py` — a bullet carrying the run's **pass, fail, and skip tallies** and the **captured file's path**. A launch that never started then produces an **absent capture file**, and a completion claim without the marker is an **inspectable** defect rather than an indistinguishable one — the refused-launch terminal is legible in the workpad, not only in prose.

Record the marker with the **`note`** reflection kind (`scripts/workpad.py update <ISSUE_NUMBER> --reflection-kind note --reflection "Verification evidence: …"`): `note` is the only kind `lib/cheap-gate.jq` does not treat as friction, so a marker recorded as any other kind would flip an otherwise-clean run and make the retrospective gate fire on exactly the runs that complied. **Fallback channel when there is no workpad:** a direct reception pass on a branch with no linked issue (`lib/fetch-pr-context.sh` emits `NoIssue`) has no workpad, so record the marker in the **PR description** instead; a run with **neither** a workpad nor a PR names that terminal explicitly and reports the evidence as **unrecordable** rather than stalling. This is **artifact vocabulary plus a captured artifact, not runtime enforcement** — the capture file and the workpad bullet are what a later reader, a reviewer, and the retrospective inspect; no gate in this change consumes them. `lib/cheap-gate.jq` is deliberately **not** wired to the marker, because its input population is merged watched-author PRs — predominantly cloud `/devflow:implement` runs, the population this local/interactive scoping excludes by name — so a clause there would evaluate out-of-coverage on nearly every workpad and be itself a guard that reads as armed and cannot fail, the exact shape #719 removes. Runtime enforcement is deferred to the named follow-up **issue #730**, scoped to a consumer whose input population actually contains local/interactive runs. The cloud tiers keep the issue-#405 in-env verification rule unchanged and gain **no** capture obligation: the cloud command-shape matchers deny `>`/`2>` redirects and `VAR="$(…)"` captures even when the head is granted (issues #401/#455), so a denied capture would produce exactly the artifact signature of a never-started run — destroying the mechanism's only discriminator on the tier where it would be least visible.

## Interpreter-faithful probes — probe under the shell the artifact actually runs under

When you probe behavior that depends on the **interpreter or environment** an artifact runs under —
a shell built-in's expansion, a `printf` escape, a locale effect, a version-specific behavior — run
the probe under the interpreter the artifact actually runs under, and
prefer mutation evidence over a hand probe when the two disagree. A probe run under the *wrong*
interpreter reports a **false vacuity**: an assertion that is live under the artifact's real shell
looks dead under whatever shell you happened to type into, and chasing that phantom costs real effort —
multiplied across every reviewer who repeats the same wrong-interpreter probe — while finding zero real
defects. The artifact's own shebang (or its runner's invocation) is the authority for which interpreter
is "actual"; a mutation that breaks the pinned behavior and turns the suite red is decisive where a hand
probe under a different shell is not.

**#340 reproduction (local instance):** a test loop drives eight separators through `printf '%b'`. Three
of them are multibyte octal escapes. Bash expands them; that session's zsh does not. The orchestrator and
two independent reviewers each probed under zsh, saw literal backslash text, and briefly concluded three
assertions were vacuous. They were not — the suite's shebang is bash, and the mutation evidence was
decisive. Cost: real effort, three times over; defects found: zero. **PR #340 cost this would have
eliminated:** the three false vacuity alarms — duplicated investigative effort across the orchestrator
and two reviewers with zero defects found.

## Dogfood every run — capture process-improvement signal (standing side task)

This repository runs `/devflow:implement` under DevFlow's **own** engine, so every run
here is a live test of that engine. Treat improving DevFlow as a standing **side task** of
this run, second only to shipping the issue itself: while you work the four phases, actively
watch the process and record what you learn so future implement runs are better. The weekly
`/devflow:retrospective-weekly` loop mines exactly these notes — a `## Devflow Reflection`
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
**prompt-surface** files. An autonomous `/devflow:implement` run must **not** invoke
`writing-skills` through the **Skill tool** mid-phase — a mid-phase Skill-tool call is a tail
call that adopts the nested skill's flow as the run's whole task and strands the run (the
engine's #362 exclusionary Skill rule, which this extension preserves **unchanged**:
`writing-skills` is **not** added to the engine's three-skill allowlist). This repo instead
routes the discipline through a context-isolated **Agent-tool subagent**, where a Skill-tool
`writing-skills` invocation is safe because the skill's flow *is* the subagent's whole task.

**The trigger globs.** The routing fires on an edit to any path matching one of:
`skills/*/SKILL.md`, `skills/implement/phases/*.md`, `skills/review/phases/*.md`, `skills/review-and-fix/references/*.md`, `.devflow/prompt-extensions/*.md`.
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
contract is *containment*, never line-start). The line records: the trigger files touched, the
mode (`subagent` for the dispatch path, `inline-degraded` for the fallback), the quoted
available-skills check outcome, and the RED/GREEN/no-guidance micro-test outcomes. This
`Writing-skills evidence:` marker literal is the exact string the review-gate criterion matches
(also as containment) — a coupled site, pinned in lockstep across `review-and-fix.md` and
`review.md`.

## Merge conflicts in generated artifacts

This section's trigger is a **merge conflict**, not an edit: whenever a rebase, base merge, or branch
update leaves a conflict in a checked-in file, resolve it as follows before touching the conflicted
bytes. It is a different trigger from the Batched artifact regeneration section, whose trigger is
post-edit and pre-suite — no in-run conflict arm routes through that section, so the conflict rule
lives here on its own.

1. Run `python3 lib/test/regenerate-artifacts.py --list`.
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

After applying edits and before each full-suite re-verify run, run `python3 lib/test/regenerate-artifacts.py` once. Loop-induced edits drift the repo's checked-in generated records — editing a reached skill asset drifts the cloud-writer runtime manifest, and editing the capability manifest drifts the generated workflow literals — and discovering each one a full suite run at a time is the dominant cost of a Phase 2-3 iteration. The helper is the sole enumeration point for this repo's suite-owned generated artifacts, so this section deliberately lists no artifact inventory of its own — an inventory duplicated into prose is one that silently goes stale as artifacts are added.

Act on its report before starting the suite run: commit a changed manifest together with the edits that caused it, and resolve every printed exit-1-forcing judgment item under the governing policy that item names. Informational lines require reading, not action. A merge conflict in one of these regenerated records is resolved under the Merge conflicts in generated artifacts section, never by hand-merging its bytes.

**If the helper reports an INFRASTRUCTURE failure (its final line names it, and the run exits 2), at least one artifact was NEVER CHECKED.** Do not read those lines as informational: an unchecked artifact is unknown, not clean, and the report names the row that failed. Treat the batched pass as **undischarged** — record `batched-regeneration: skipped` naming the failing row (the pass ran but established nothing, so it discharges exactly as a skipped pass does), and fall back to the status-quo serial discovery for that artifact. Never record `run` on an exit-2 report.

**The unchecked verdict is residual, not an enumeration of the helper's declared states.** Any outcome that is not a clean exit 0 carrying a per-row line for every registered row — a traceback, an empty report, a truncated one, an exit code you cannot attribute — is equally an unchecked pass, whether or not the literal `INFRASTRUCTURE` appears. Record `batched-regeneration: skipped` naming what you actually observed. Keying this on the enumerated tokens alone is what would let a novel failure shape read as "nothing to do". Note that an exit-2 run may still have **rewritten** `scripts/devflow-cloud-writer-contract.json` — the mechanical row runs first and writes unconditionally — so check for and commit that regeneration even on an undischarged pass.

If the runner's permission matcher refuses the invocation **twice**, stop — do not iterate variants of the command (the issue-401 two-denials discipline). Record the refusal in the workpad and proceed to the suite run: the batched pass then degrades to the status-quo serial discovery, which is slower but never a silent stall.

On a run that maintains a workpad, record one discharge line before each full-suite run — `batched-regeneration: run|refused|skipped`. A compacted context that dropped this section then leaves an auditable gap rather than an undetectable silent revert to serial discovery.
