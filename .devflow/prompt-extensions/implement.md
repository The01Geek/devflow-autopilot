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

## Focused test modules accelerate RED/GREEN only

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

A focused result is never a completion gate. Before a commit, phase completion, push, or
completion claim, run `bash lib/test/run.sh` plus every lint gate required by `CLAUDE.md` (using
its documented classifier fallback when necessary). A nonempty skip tally is not clean.

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
- **The run was genuinely frictionless end-to-end** → do **not** file a `--reflection` bullet
  for it. Record the confirmation as a `## Progress` note instead:
  `scripts/workpad.py update <ISSUE_NUMBER> --note "dogfood side task ran: frictionless, nothing to capture"`.
  A `--note` writes to `## Progress`, which does **not** feed `reflections[]`, so `## Devflow
  Reflection` stays empty and `cheap-gate.jq` still skips the clean PR cheaply — while the
  Progress note still proves the side task was run, not silently skipped.

An implement run that shipped the issue, hit no friction, and left **neither** a Reflection
bullet nor this Progress note has skipped the side task; empty-and-silent is not done. Never
invent findings to fill Reflection — the frictionless *Progress note* is the honest terminal
state for a clean run, precisely so you never have to.

## Prose cutover

Mandatory prompt prose is an implementation surface, not an append-only log. When an
executable helper becomes the sole tested owner of a workflow decision on every consuming
path, remove the superseded decision logic, its duplicated branch/enum mirrors, and its
obsolete prose pins in the **same change**. Keep policy, human decision points, invocation
contracts (including fail-closed handling when the helper is absent), and essential stop
conditions in the skill. Move rare-path explanation to a progressively loaded reference;
never move operative decision logic out of the normal path merely to lower its byte count.

### Sole tested owner: the complete five-condition bar

All five conditions below must hold **for each consuming path** before its decision-owning
prose is superseded:

1. **Every consumer reaches the helper.** Each tier (local interactive, cloud review, cloud
   implement) and supported host family (macOS/BSD, Linux, Windows through WSL / Git Bash /
   MSYS2) that previously executed the prose decision now invokes the helper.
2. **Every branch is driven.** The suite exercises every helper branch, including arm order
   whenever selection precedence affects the result.
3. **Every invoking tier grants it.** Both review-tier grant surfaces and the implement-tier
   grant surface include the helper. Any command shape not already probe-proven carries
   matcher-probe evidence before the cutover relies on it.
4. **Vendored halves ship together.** When the cutover crosses the `install.sh`-shipped /
   `devflow_version`-vendored boundary, both halves land together and the upgrade coupling is
   documented.
5. **Removed pins retain behavioral proof.** Helper-behavior tests that absorb removed prose
   pins carry planted-defect mutation evidence under the repo's behavioral-fix-pin rule.

Ownership is judged **per consuming path**. While even one path still consumes the prose
decision, that prose is not superseded and stays. Relocating decision-owning prose is not a
removal: the owner survives at its destination. Deleting decision-owning prose before one
sole tested owner satisfies all five conditions is unauthorized.

### Pin conservation and retained content

List every removed prose pin in the cutover artifact. Map it to the helper-behavior test that
now absorbs the guarded regression and cite the planted-defect mutation that turns that test
red. If no behavioral obligation remains, record a concrete retirement reason instead. Never
delete a pin merely to make a prose deletion green.

Do not trim these retained categories: policy; a user or maintainer decision; the contract
for invoking the helper; the observable fail-closed response when the helper is unavailable,
malformed, or denied; and stop conditions an agent must act on. Explanations of rare failures
may move to conditional references, but the branch that decides what the run does remains in
the mandatory path unless the tested helper owns it.

### Mandatory-byte census and baseline updates

`lib/test/prompt-mass-manifest.json` groups prompt surfaces as `mandatory` or `reference`.
A file loaded unconditionally on any flow's normal path — including mandatory-at-entry phase
or step references — is `mandatory`; `reference` is reserved for genuinely conditional
rare-path files. The same file may belong to multiple workflow groups because group totals
are independent. `lib/test/prompt-mass-baseline.json` contains one byte row per measured file
of both classes and no total rows; the census derives group totals at report time.

Every byte difference is intentional: growth and reduction both fail until the baseline row
is updated. Reference movement remains visible in the baseline diff but is untolled by the
Review gate; mandatory movement requires an artifact below. The word-denominated,
path-weighted Review and Review-and-Fix ceilings remain separate and unchanged: those ceilings
cap traffic, while this byte mirror audits movement. Do not re-express or remove either
contract when updating the other.

To compute canonical replacement rows, run the direct executable locally when permitted, or
use the interpreter fallback:

```bash
lib/test/prompt-mass-census.py --write-baseline
python3 lib/test/prompt-mass-census.py --write-baseline
```

Copy the printed JSON into `lib/test/prompt-mass-baseline.json` with the Write/Edit tool, then
run the full suite. On a cloud tier, treat the direct `.py` command shape as unproven until a
matcher-probe row establishes it; no step may depend on the config grant added by the same PR,
because cloud config is resolved from the default branch before that PR runs. Concurrent PRs
that edit non-adjacent baseline rows normally merge; same or adjacent rows (including the last
row's comma context) may conflict loudly. Resolve such a conflict by regenerating the complete
printed baseline once against the merged tree.

### Cutover artifact template (schema 1)

Every mandatory-row-moving PR adds a uniquely named `docs/cutovers/<slug>.md` file in that
same diff. Start it with exactly one schema and kind:

```markdown
---
schema: 1
kind: cutover | trim | growth | relocate
---
```

Then use the exact schema-1 headings for the selected kind:

- `cutover`: `## Files`, `## Consuming paths`, `## Branch coverage`, `## Grants and probes`,
  `## Shipping coupling`, `## Mutation evidence`, and `## Pin disposition`. Cite the five
  sole-owner conditions and map every removed prose pin to its absorbing behavioral test or
  recorded retirement reason.
- `trim`: `## Files`, `## Rationale`, and `## Ownership`. Name each trimmed file, give a
  one-line editorial rationale, and state that ownership did not change.
- `growth`: `## Files` and `## Justification`. Name every grown or added mandatory file and
  explain in one line why those bytes belong on the mandatory path.
- `relocate`: `## Source rows` and `## Destinations`. Name each source baseline row and its
  destination file and manifest group.

The body must contain evidence, not empty headings. Artifacts are append-only history. A later
template change mints a new schema version and freezes a new heading set; it never re-validates
old schema-1 artifacts against newer headings. A malformed or pre-existing artifact discharges
no Review gate arm, and artifact file lists must cover every mandatory row the diff moves.

The gate recognizes four audited decisions: `cutover` (ownership transfers and prose leaves),
`trim` (editorial reduction with no ownership change), `growth` (new mandatory bytes), and
`relocate` (bytes move without deleting their owner). A diff that both grows and reduces
mandatory rows needs matching coverage for both directions; one `cutover` may cover both when
the same ownership transfer causes both movements.

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
