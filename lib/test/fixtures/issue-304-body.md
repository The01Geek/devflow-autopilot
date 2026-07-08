## Problem Statement

Two independent improvements, filed together at the maintainer's request.

**A — Review auto-trigger wastes runs on unreviewable PRs.** `/devflow:review` is an
expensive, LLM-backed review. Today the `precheck` job in
`.github/workflows/devflow-review.yml` auto-triggers it on the first reviewable event and on
every `synchronize`, with **no** precondition on whether the PR is even in a reviewable
state. Two common cases waste a full review run (and post misleading verdicts): the PR branch
is **behind its base** (it will need updating, producing new commits that re-trigger review
anyway), or the PR's **other CI checks are red** (the code is known-broken, so a code-quality
verdict is premature). Repo owners pay for these runs and reviewers read verdicts on PRs that
were never merge-eligible.

**B — Issue drafts are stronger after a self-steelman, but the skill doesn't do it.** The
maintainer consistently gets materially better issues by manually prompting the drafting agent
with *"Steelman this. Did we miss anything?"* the moment it presents a draft — it makes the
agent stress-test the draft against the actual code rather than armchair it. This valuable
step depends on the human remembering to type it; it should be an institutionalized step in
`skills/create-issue/SKILL.md`.

## Current Behavior

**Part A.** In `.github/workflows/devflow-review.yml`, the `precheck` job routes
`opened`/`reopened`/`ready_for_review`/`synchronize`/`check_run(rerequested)` events. The
first-review and `synchronize` paths gate only on: canonical actor-dedupe variant, PR not a
draft, and (for exactly-once) no prior `Devflow Review` check already existing. There is **no**
check that the branch is up to date with its base, and **no** check of any other CI status.
When these paths set `should_run=true`, `create_check` posts an `in_progress` `Devflow Review`
check and `review` runs the engine unconditionally. `Devflow Review` is a **required** status
check (main branch protection, ruleset 16652954).

**Part B.** `skills/create-issue/SKILL.md` goes directly from Step 3 (draft the issue + pass
the no-options gate) to Step 4 (present the rendered draft to the user for confirmation). The
only pre-draft rigor is the Step 2 independent-derivation pass; there is no post-draft,
code-grounded stress-test of the assembled draft before the user sees it.

## Desired Behavior

**Part A.** The review auto-trigger runs only when the PR is in a reviewable state:

- The PR branch is **not behind** its configured base branch (`base_branch`), **and**
- **every** other check on the PR head — every check-run/status **except** `Devflow Review`
  itself — has concluded **successfully** (no failing and none still pending).

When either precondition is unmet, the review does **not** run; instead a `Devflow Review`
required check is **deliberately still posted and concluded `neutral`** with a reason
("waiting: branch behind base" / "waiting: other CI not green"). Posting it is load-bearing:
today a `should_run=false` skip runs neither `create_check` nor `finalize_check`, so the
required check would be **absent** — and an absent required check wedges the PR forever (the
exact deadlock this workflow exists to prevent). A `neutral` required check does not itself
block merge, and the branch stays un-mergeable for the real reason (red CI blocks; a stale
branch is blocked only if the repo enforces "require branches up to date"). The
review then **auto-re-triggers and re-evaluates the preconditions** when the branch is updated
(existing `synchronize` path) **and** when other CI completes (a new
`check_suite`/`workflow_run: completed` listener) — so once the PR becomes reviewable, the
review fires with no manual Re-run. Both preconditions are governed by config keys under
`devflow_review`, defaulting to enabled, and gate on all non-`Devflow Review` checks
generically (no hardcoded job names), so consumer repos work out of the box and can opt out.

**Part B.** `/devflow:create-issue` performs a mandatory **self-steelman** of the drafted
issue immediately after Step 3's no-options gate and immediately before Step 4 presents it:
the agent re-reads its own draft and stress-tests every load-bearing claim, file reference,
and acceptance criterion against the actual code, hunting for missed acceptance criteria,
edge cases, wrong assumptions, and unstated scope — then revises the draft (re-running the
no-options gate) before presenting it to the user.

## User Impact

- **Repo owners / reviewers:** fewer wasted LLM review runs; no misleading code-quality
  verdicts on PRs that are behind base or failing CI; the review still always eventually runs
  once the PR is genuinely reviewable, with no manual intervention.
- **Consumer repos:** the preconditions are generic and config-gated, so they apply cleanly to
  any repo's CI without naming DevFlow-internal jobs, and can be disabled per repo.
- **Anyone filing issues via `/devflow:create-issue`:** consistently sharper, code-grounded
  issues without having to remember to prompt for a steelman.

## Technical Context

> **Scope note:** The files and details below are the known starting points, not the full
> list. Before implementing, trace the change through the codebase to find every affected
> call site, consumer, and layer — this issue maps the work, it does not bound it.

**Part A — review auto-trigger**
- **Relevant Classes/Files**
  - `.github/workflows/devflow-review.yml` — the `precheck` job's `route` step (the
    first-review, `synchronize`, and `check_run` branches) is where the new preconditions are
    evaluated; `on:` needs a new `check_suite`/`workflow_run: completed` trigger; `create_check`
    / `review` / `finalize_check` jobs consume `precheck` outputs.
  - `.devflow/config.schema.json` and `.devflow/config.example.json` — add the new
    `devflow_review` precondition keys.
  - `.github/actions/read-project-config` — already loads `CONFIG_JSON` into `precheck`; the
    new keys are read from the same `jq` extract step that reads `.workflows["devflow-review"]`
    and `.devflow.allowed_bots`.
  - `lib/test/run.sh` — the workflow's precheck routing is pinned by tests here (gh-stubbed);
    fixtures under `lib/test/fixtures/*-checkruns.json` model check-run responses.
- **Architecture Alignment** — the preconditions are new branches inside the existing
  `precheck.route` step, reusing its established pattern: query GitHub via `gh api` with
  `set -euo pipefail`, **fail closed** on query error (a missed review is recoverable via the
  next event or the manual Re-run button; a spurious/incorrect trigger is the cost to avoid),
  and `emit should_run false` unless a branch explicitly enables. The base-behind check and the
  other-checks-green check mirror the existing check-run queries (`repos/$REPO/commits/$HEAD/check-runs`,
  value-stream + line-count path, not per-page `| length`). Excluding `Devflow Review` from the
  "other checks" set is the analogue of the existing `select(.name=="Devflow Review")` filters,
  inverted.
- **Dependencies** — GitHub REST (`gh api`): compare base..head for behind-count
  (`repos/$REPO/compare/$BASE...$HEAD` → `behind_by > 0`), and
  `repos/$REPO/commits/$HEAD/check-runs` + combined status
  for the other-checks gate. Base branch comes from config `base_branch`, never hardcoded
  `main`.
- **Data/Schema Considerations** — two new keys under `devflow_review` in
  `.devflow/config.schema.json` (booleans, default `true`): one gating the branch-freshness
  precondition, one gating the other-CI-green precondition. `.devflow/config.example.json`
  documents them. `read-project-config` output already carries the whole config JSON, so no new
  wiring beyond the `jq` extract.
- **Cross-layer Impact** — CI/workflow layer only (`.github/`), plus config schema/example and
  the test suite. No skill or Python changes for Part A. **Constraint:** the DevFlow bot's
  installation token cannot push under `.github/workflows/` without the `workflows` permission —
  as with `ci/version-consolidate.yml`, the maintainer may need to apply the workflow change,
  and `main` branch protection must permit the resulting check states.

**Part B — create-issue steelman step**
- **Relevant Classes/Files**
  - `skills/create-issue/SKILL.md` — add the new step between Step 3 ("Draft the issue and pass
    the no-options gate") and Step 4 ("Review with the user, then create"); update the
    "Completion checklist" TodoWrite list so the new step is tracked.
  - `skills/create-issue/references/issue-template.md` — the steelman references the same
    load-bearing-premise verification discipline this file already defines; keep them coherent.
- **Architecture Alignment** — the step reuses the skill's existing machinery: targeted
  verification reads/greps (not a full re-exploration), the no-options gate re-run on revision,
  and, if the steelman surfaces a genuinely new unresolved decision fork, the existing Step 2
  clarification / disengagement / `## 🚫 Blocked` handling (no new decision-handling path).
- **Dependencies** — none beyond the tools the skill already uses.
- **Cross-layer Impact** — documentation/skill layer only. **Constraint (CLAUDE.md):** any
  `SKILL.md` edit must go through the `superpowers:writing-skills` RED/GREEN discipline — never
  a hand-edit of the skill body.

## Acceptance Criteria

**Part A**
- [ ] When the PR branch is behind its configured base branch and
  `devflow_review.require_up_to_date` is enabled, the `precheck` job sets `should_run=false`
  and the `Devflow Review` check concludes `neutral` with a "branch behind base" reason (it
  does not run the review engine).
- [ ] When any check on the PR head other than `Devflow Review` has concluded `failure` (or has
  not yet concluded `success`) and `devflow_review.require_ci_green` is enabled, the `precheck`
  job sets `should_run=false` and the `Devflow Review` check concludes `neutral` with an "other
  CI not green" reason.
- [ ] `Devflow Review` is excluded from the set of "other checks" evaluated by the CI-green
  precondition (its own `in_progress` check never blocks itself).
- [ ] On a precondition-unmet skip, a `Devflow Review` check is still posted and concluded
  `neutral` (the check is never left absent or hanging `in_progress`) — i.e. the skip path runs
  its own create-and-finalize, distinct from today's `should_run=false` paths that post no check.
- [ ] When both preconditions are satisfied, the review auto-triggers exactly as it does today
  (first-review-once semantics and `synchronize` re-review behavior are preserved).
- [ ] Completion of the PR's other CI (a `check_suite`/`workflow_run: completed` event)
  re-evaluates the preconditions and auto-triggers the review when they are now satisfied and no
  `Devflow Review` check has yet run/passed for that head — with no manual Re-run required. This
  is the primary path for the CI-green precondition: the initial reviewable event defers (posts
  a `neutral` "waiting" check) while other CI is still pending, and this completion event fires
  the real review once CI is green.
- [ ] Updating a behind branch (existing `synchronize` path) re-evaluates the preconditions and
  auto-triggers the review when they are now satisfied.
- [ ] Each precondition is independently controlled by a `devflow_review` config key defaulting
  to enabled; setting the key to `false` restores today's unconditional behavior for that
  precondition.
- [ ] The gate references no hardcoded CI job names (e.g. not `lib + python tests`, not a lint
  job name) — it operates over every non-`Devflow Review` check generically, so it works
  unchanged in a consumer repo with different check names.
- [ ] Any GitHub API query the preconditions depend on **fails closed**: on query error the
  review does not auto-trigger, a warning breadcrumb is emitted, and the run is recoverable via
  a later event or the manual Re-run button.
- [ ] A repo with **no** non-`Devflow Review` checks configured is still eventually reviewed and
  never wedged: the CI-green precondition treats "no other CI exists" as satisfied (there is
  nothing red or pending to wait on), evaluated on a CI-completion re-trigger so it is not
  confused with "other CI has not registered yet" at the initial event.

**Part B**
- [ ] `skills/create-issue/SKILL.md` contains a mandatory self-steelman step positioned after
  Step 3's no-options gate and before Step 4 presents the rendered draft.
- [ ] The step instructs the agent to re-read its own draft and stress-test each load-bearing
  claim, file reference, and acceptance criterion against the actual code (targeted reads/greps,
  not a full re-exploration), and to surface missed acceptance criteria, edge cases, wrong
  assumptions, and unstated scope.
- [ ] After the steelman, the agent revises the draft and re-runs the no-options gate before
  presenting; a newly surfaced unresolved decision routes through the existing Step 2
  clarification / disengagement / `## 🚫 Blocked` handling rather than a new mechanism.
- [ ] The skill's "Completion checklist" TodoWrite list is updated to include the steelman step
  so it is tracked.
- [ ] The edit is produced via the `superpowers:writing-skills` RED/GREEN discipline (the
  skill's triggering and downstream behavior remain intact).

## Implementation Notes

**Approach (Part A).** Add two config keys under `devflow_review` (booleans, default `true`) to
`.devflow/config.schema.json` + `.devflow/config.example.json`; read them in the `precheck.extract`
step's `jq` alongside the existing `enabled`/`allowed_bots` extraction. In `precheck.route`,
before a first-review or `synchronize` branch emits `should_run=true`, evaluate the two
preconditions against the resolved `$HEAD`: (1) branch-freshness via a base..head compare
(`repos/$REPO/compare/$BASE...$HEAD` → `behind_by > 0`) using the configured `base_branch`;
(2) other-checks
via the head's check-runs + combined statuses, excluding `Devflow Review`, requiring all
concluded `success`. On an unmet precondition, emit `should_run=false` with a distinct reason so
`finalize_check` concludes the required check **neutral** (add the reason to the neutral-arm
mapping there). Add a `check_suite` (or `workflow_run`) `completed` trigger to `on:` and a route
branch that resolves the associated PR + head, re-checks exactly-once (no prior passing/ran
`Devflow Review` check) and both preconditions, then emits `should_run=true` when clear —
reusing the `synchronize` cost-guard's check-existence query. Preserve the actor-dedupe, draft,
and exactly-once invariants; the new trigger's route branch must respect them.

**Approach (Part B).** Via `superpowers:writing-skills`: insert a "Step 3.5: Steelman the draft
against the code" section into `skills/create-issue/SKILL.md` between the current Steps 3 and 4,
and add the corresponding TodoWrite item. Word it to reuse existing machinery (targeted reads,
no-options-gate re-run, Step 2 handling for new forks) so it introduces no new decision path.

**Code Patterns** — Part A mirrors the existing `precheck.route` branches: `set -euo pipefail`,
`emit` helper, `gh api --paginate` with value-stream + `grep -c` line counting (never per-page
`| length`), fail-closed-on-error arms with `::warning::` breadcrumbs, and `select(.name=="Devflow
Review" …)` check-run filtering (here inverted to *exclude* it). Part B mirrors the skill's
existing gate/pass sections (no-options gate, independent-derivation pass).

**Testing Strategy.**
- *Part A — boundary: automated (shell, gh-stubbed) in `lib/test/run.sh`.* The `precheck.route`
  logic is exercised via the existing gh-stub harness + `*-checkruns.json` fixtures. Named
  assertions, each mapped to an AC:
  - branch-behind + `require_up_to_date=true` → `should_run=false`, neutral reason (AC1); with
    the key `false` → `should_run=true` (AC7).
  - a non-`Devflow Review` check `failure` → `should_run=false`, "CI not green" reason (AC2);
    a non-`Devflow Review` check still `in_progress` → `should_run=false` (AC2, pending arm).
  - only `Devflow Review` present/in_progress among checks, base up to date → `should_run=true`
    (AC3 — self-exclusion; AC9 — zero *other* checks passes).
  - all other checks `success` + not behind → `should_run=true`, first-review-once + synchronize
    behavior unchanged (AC4).
  - a precondition-unmet skip posts a `neutral` check (create+finalize both run on the skip
    path; the check is neither absent nor left `in_progress`) — the "still-posted neutral"
    acceptance criterion.
  - initial `opened`/`ready_for_review` event with other CI still pending → defer (`neutral`
    "waiting"), not proceed (initial-event-race arm).
  - `check_suite/workflow_run: completed` event with preconditions now met and no prior
    `Devflow Review` check → `should_run=true` (AC5); with a prior passing `Devflow Review`
    check → `should_run=false` (exactly-once); triggered by the `Devflow Review` workflow's own
    completion → ignored (no self-trigger loop).
  - fixture-driven fixtures for a compare/`check-runs` query returning error/empty → fail closed,
    `should_run=false` + warning (AC10).
  - fixture asserting the gate contains no literal `lib + python tests` / lint job name — grep the
    workflow for hardcoded job names in the precondition block (AC8).
  - `neutral` conclusion + reason is produced by `finalize_check` on the unmet-precondition path
    (AC1/AC2 conclusion arm).
- *Part B — boundary: skill prose (no automated test).* Reproducible verification: a numbered
  checklist confirming (a) the steelman step exists between Step 3's no-options gate and Step 4
  (AC-B1), (b) it names code-grounded stress-testing of claims/file-refs/ACs and the four hunt
  targets (AC-B2), (c) it re-runs the no-options gate and routes new forks through Step 2 (AC-B3),
  (d) the TodoWrite checklist lists it (AC-B4). The `writing-skills` RED/GREEN loop provides the
  behavioral verification (AC-B5): confirm the skill still triggers on a rough user story and that
  a seeded draft with a code-contradicted claim gets caught by the new step.

**Documentation Needed** — `docs/DEVFLOW_SYSTEM_OVERVIEW.md` (review auto-trigger section) and any
internal workflow doc under `docs/internal/workflows/` describing the trigger policy must document
the new preconditions, the neutral-check-with-re-trigger behavior, and the two config keys. The
`CLAUDE.md` review-engine / gotchas notes should mention the preconditions if they become a
load-bearing invariant. `.devflow/config.example.json` documents the keys inline.

**Potential Gotchas.**
- **Do not re-introduce the required-check deadlock.** The whole workflow exists to keep the
  required `Devflow Review` check from hanging `in_progress` or being absent. A precondition
  skip MUST still create *and* finalize a `neutral` check (today's `should_run=false` paths post
  no check — the new skip path needs its own create+finalize, not a plain `should_run=false`),
  *and* guarantee an eventual auto-re-trigger — never leave the required check absent or pending
  with no event that will revive it.
- **`neutral` does not block merge — the branch-freshness gate is a cost optimization, not a
  correctness gate.** Because a `neutral` required check permits merge, a PR that is behind base
  but otherwise mergeable could merge *unreviewed* in a repo that does not enforce "require
  branches up to date." Document this explicitly; the branch-freshness precondition exists to
  avoid wasting a review that a forthcoming branch-update would invalidate, and pairs with that
  branch-protection setting for correctness. (The review already diffs against the current base,
  so being behind does not corrupt a review's content — reinforcing that this gate is about cost,
  not soundness.)
- **Initial-event race — other CI has not registered yet.** At `opened`/`ready_for_review` time
  the PR head frequently has *zero* non-`Devflow Review` checks because CI hasn't started. Treat
  the initial event as "CI pending" (defer + `neutral` "waiting") rather than "no CI" (proceed),
  and let the `check_suite`/`workflow_run: completed` re-trigger make the proceed decision once
  CI has actually reported — otherwise the review races ahead of CI and the wait-for-green
  precondition is defeated. The re-trigger must ignore the `Devflow Review` workflow's own
  completion to avoid a self-trigger loop, and a genuinely CI-less repo must still be reviewed
  (see the zero-checks acceptance criterion) rather than deferred forever.
- **`neutral` vs `failure` for an unmet precondition:** neutral is deliberate — an unmet
  precondition is "not reviewable yet", not "review rejected". Do not map it to `failure` (that
  would block merge and read like a REJECT).
- **`check_suite`/`workflow_run` re-trigger must respect exactly-once + actor-dedupe + draft
  guards**, or it will double-review or review drafts.
- **Base-branch source:** use configured `base_branch`, never a literal `main` (consumer repos
  and this repo both rely on the config value).
- **Fail-closed everywhere:** every new `gh api` query follows the existing fail-closed pattern —
  an unverifiable precondition must not auto-trigger a review (nor spuriously block).
- **`.github/workflows/` push permission:** the DevFlow bot's installation token may not be able
  to push the workflow change; a maintainer may need to apply it (same constraint as
  `ci/version-consolidate.yml`).
- **Engine-surface change → changeset required** (CLAUDE.md #290): touching `.github/` workflows
  and config schema adds a `.changeset/*.md` (default `bump: patch`); do not edit `plugin.json` /
  `CHANGELOG.md` directly.

