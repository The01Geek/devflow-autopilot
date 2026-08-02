---
bump: patch
---

Read consumer prompt extensions from the trusted base ref on the shipped command tier (#1075).

`scripts/load-prompt-extension.sh` prints an extension file byte-for-byte and every
skill treats that stdout as instructions appended to its own prompt for the run. On
the only review path reachable in a consumer — `devflow.yml`'s `command` job, which
runs `/prflow:review`, `/prflow:review-and-fix` and `/prflow:pr-description` — some
of those reads landed on pull-request content, so a pull-request author could write
part of the prompt of the agent that reviews, and on `/prflow:review-and-fix` also
fixes and pushes, their own pull request. The protection existed but did not ship:
`DEVFLOW_PROMPT_EXTENSION_ROOT` was exported only by the automatic review tier that
issue #936 withheld.

The trust boundary is now decided the same way this repository already decided it one
layer down for the reviewer deny-list floor: **a floor the pull request controls is no
floor**. It is closed rather than recorded as an accepted trade.

The `command` job gains a `promptext` step that **unconditionally** creates
`$RUNNER_TEMP/devflow-trusted-prompt-ext/` and exports `DEVFLOW_PROMPT_EXTENSION_ROOT`
at it, then **conditionally** — inside its own base-ref fetch-success branch and
nowhere else, because `FETCH_HEAD` elsewhere can be the pull-request head — populates
it from the pull request's base ref through the existing
`scripts/materialize-trusted-prompt-extensions.sh`. Every non-population arm (no
number on the command, an unresolvable base branch, a failed fetch, a missing
materialization helper, and every arm inside the helper) therefore degrades to an
**empty** closure and a cause-naming `::warning::` — the run proceeds with no consumer
extension text — never back to the working tree. The protected set is the closed set
those three commands can load, declared once as a job-level `env:` and reconciled
against the skill trees by a drift guard, because a name missing from it would be a
silent *empty* read rather than a no-op.

**Where the mechanism differs from the withheld runner's it differs deliberately, and each
difference is load-bearing rather than an oversight.** No workspace truncation: this tier is
write-capable, so emptying the workspace copies would dirty the tree that
`/prflow:review-and-fix`'s Step 0.5 `gh pr checkout` refuses to run against, and any
truncation that survived would be committed to the contributor's branch by the fix
loop; a loud skew `::warning::` when the vendored loader predates the variable
replaces that belt. And no three-rank trusted-source ladder for the materialization
helper: on a trigger whose workspace is pull-request content, a pull request that can
edit that helper can equally edit the `load-prompt-extension.sh` that consults the
closure, which no ladder reaches, so a ladder would add complexity without adding a
case it defends.

The exposure route is also stated correctly for the first time. Under `issue_comment`
this job's own checkout is the **default branch**; what makes the reads untrusted is
that `/prflow:review-and-fix`'s Step 0.5 branch sync moves the working tree onto the
pull-request head before the engine loads `review` and before Phase 3.1 loads
`requesting-code-review`. Standalone `/prflow:review` never moves the tree at all.
Under `pull_request_review` and `pull_request_review_comment` the workspace is
pull-request content from the first step.

Consequence to expect: a pull request that edits a prompt extension no longer changes
its own review run on this tier — the change takes effect after merge, the same rule
that already governs trigger-time-resolved configuration.

Documentation is reconciled with the residuals rather than under-reporting them.
`docs/DEVFLOW_SYSTEM_OVERVIEW.md`'s base-ref trust boundary and `docs/cloud-setup.md`'s
trusted-ref rule previously enumerated only the manual review comment path and named
neither the write-capable path's mechanism nor the residuals that remain: the
pull-request-controlled composite actions on the two `pull_request_review*` triggers,
which sit upstream of anything the closure can influence; a consumer whose pinned
`prflow_version` ships a loader that ignores the variable; and the local or
interactive `/prflow:review-and-fix` run, which has no dispatching environment to
materialize anything and where the advisory provenance checks stay the sole control.
`skills/review-and-fix/references/shadow-review.md`'s claim that the tier is
"knowingly left unprotected" is corrected to name exactly those two remaining
sub-paths.
