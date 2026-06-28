# DevFlow repo — operative policy for `/devflow:implement`

This repository (the DevFlow plugin itself) manages its own version and runs under a
permission classifier that routinely blocks shell invocations, so apply the following
when implementing an issue here. The base `/devflow:implement` skill is
versioning-agnostic and environment-agnostic by design — this extension is DevFlow's
opt-in, and it is the **operative** repo policy (edit this file to change it).

## Versioning policy

**When to bump.** Bump `.claude-plugin/plugin.json`'s `version` only for changes that
reach consumer repos as an update — a fix, feature, or breaking change to the engine
surface (`skills/`, `agents/`, `lib/`, `scripts/`, the workflows, the config schema).
Internal-only changes (tests, CI, dev-only docs) do **not** bump.

**Which increment — default to `patch`.** Use the smallest step. Choose `minor`
(backward-compatible feature) or `major` (breaking change) **only when this issue's body
explicitly authorizes the larger step** — e.g. an acceptance criterion naming the target
version or the SemVer increment. When the issue is silent on the increment, choose
`patch`. Never infer a larger bump from the change's size or "feature-ness" on your own.

**CHANGELOG is mandatory with any bump.** Whenever you bump the version, add the matching
`## [x.y.z]` entry to `CHANGELOG.md` in the same change (Keep-a-Changelog format, dated,
citing the PR number). The Phase 3 review gate FAILs on a version↔`CHANGELOG` mismatch.

**When to apply it.** Decide the increment once the committed diff is concrete (record the
decision in the workpad so it survives context compaction), then apply the bump +
`CHANGELOG` entry **after the draft PR exists but before the review pass** — so the entry
can cite the PR number and the version + `CHANGELOG` land inside the diff that `/simplify`
and `/devflow:review-and-fix` review. The Phase 4.3 clean-tree backstop is the final guard
that the bump never ends up uncommitted.

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

## Reconcile every descriptive surface after a late change of direction

The base `/devflow:implement` skill's **Phase 2.3.4a** sweep now carries the general rule: after
a *change of direction* (a revert, scope-narrowing, marker removal, or rename) it extends the
self-authored-claim sweep beyond the current diff to reconcile the **issue workpad** (Plan, AC
wording, Status) and **earlier-authored prose** that names the changed contract. This is the
single dominant `doc-accuracy` failure in *this* repo, so the repo-specific surfaces and the
worked examples below make that rule operational here — they do not restate it.

**This repo's advertise-the-change surfaces** to add to the 2.3.4a re-walk when a change of
direction lands: `CHANGELOG.md`, `README.md`, `DEVFLOW_SYSTEM_OVERVIEW.md`, and any `docs/**`
page describing the feature. Reconcile any claim that now overstates the shipped reality — an
attribution model, an equality/identity claim, a removed or renamed surface.

**Worked examples** (the production failures the rule exists to stop):

- **#144** — `writing-skills` was hard-forked, then **reverted** to stay external, but the issue
  workpad's Plan + Acceptance-Criteria still claimed it was vendored (AC1/AC2 ticked, "retains
  upstream copyright"); and CHANGELOG/README/`DEVFLOW_SYSTEM_OVERVIEW.md` prose still advertised
  attribution markers a later commit had **removed**. The workpad and the marketing prose were
  never re-walked after the revert.
- **#125** — `/devflow:implement` was scoped to issues only, but stale "issue/PR" wording survived
  in now-issues-only inline comments (dedupe-step comment, duplicate-notice comment, the
  number-resolution comment whose own function header was already updated to "issue").
- **#64** — a telemetry-id equality **overclaim** shipped in docs and had to be corrected by the
  human; an inline guard comment called itself "fail-closed" while the value it reads fails **open**.

*Scope note (other `doc-accuracy` sub-patterns this rule does not address):* the coarse
`doc-accuracy` category also lumped non-prose items — a deferred E402/lint finding left in,
a self-inflicted CI-red revert that stripped test-required attribution markers without
reconciling the asserting tests in the same commit, and an inert cloud-allow-list omission.
Those are reconcile-the-*tests*/CI and engine-allow-list problems, not descriptive-text
drift; this extension covers the dominant descriptive-text-drift sub-pattern only.
