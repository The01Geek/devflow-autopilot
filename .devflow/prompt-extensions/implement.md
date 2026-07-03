# DevFlow repo — operative policy for `/devflow:implement`

This repository (the DevFlow plugin itself) manages its own version and runs under a
permission classifier that routinely blocks shell invocations, so apply the following
when implementing an issue here. The base `/devflow:implement` skill is
versioning-agnostic and environment-agnostic by design — this extension is DevFlow's
opt-in, and it is the **operative** repo policy (edit this file to change it).

## Versioning policy

DevFlow versions itself with **changesets**, not an in-PR version bump. Each PR that reaches
consumers declares its change in a uniquely-named `.changeset/*.md` file and never edits
`.claude-plugin/plugin.json` or `CHANGELOG.md`; a merge-time GitHub Action (shipped at
`ci/version-consolidate.yml`, installed by a maintainer into `.github/workflows/`; runs
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
`scripts/workpad.py update <WORKPAD_ID> --reflection-kind note --reflection "<observation>"`
— process-improvement signal is a `note` (it lands under `### ℹ️ Notes`). Reserve the
actionable kinds for what they mean: `blocked` (a hard stop), `deferred` (punted work),
`dropped-failed` (a subagent/step that failed and you continued past). Name the **concrete
surface** — the file, skill, or step — and the specific improvement, so the retrospective can
act without re-deriving what you already saw. This is **additive** to the verification-gap
reflections above and to the reflections the base skill already writes (deferrals, reverts,
post-review code fixes); it does not replace any of them.

**Before finalizing (Phase 4.3), confirm the side task ran — and record the confirmation on
the *right* surface, because the surface carries a cost.** `lib/cheap-gate.jq` forces an LLM
retrospective pass on any run that left **even one** `## Devflow Reflection` bullet, so a
reflection is the expensive-but-loud surface and a `## Progress` note is the cheap-but-quiet
one. Route by whether the run actually had signal:

- **The run hit real friction / a bug / a hazard** → it is already a `## Devflow Reflection`
  `note` bullet (per *How to record it* above). That is exactly the signal the retrospective
  must be forced to read; the gate tripping here is correct, not waste.
- **The run was genuinely frictionless end-to-end** → do **not** file a `--reflection` bullet
  for it. Record the confirmation as a `## Progress` note instead:
  `scripts/workpad.py update <WORKPAD_ID> --note "dogfood side task ran: frictionless, nothing to capture"`.
  A `--note` writes to `## Progress`, which does **not** feed `reflections[]`, so `## Devflow
  Reflection` stays empty and `cheap-gate.jq` still skips the clean PR cheaply — while the
  Progress note still proves the side task was run, not silently skipped.

An implement run that shipped the issue, hit no friction, and left **neither** a Reflection
bullet nor this Progress note has skipped the side task; empty-and-silent is not done. Never
invent findings to fill Reflection — the frictionless *Progress note* is the honest terminal
state for a clean run, precisely so you never have to.
