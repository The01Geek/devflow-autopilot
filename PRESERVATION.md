# Preserved: the auto PR-triggered review tier

This branch preserves the bytes of `.github/workflows/devflow-review.yml` — the caller
of DevFlow's automatic, pull-request-triggered review tier — which was removed from
`main` under issue #936. Nothing on this branch is shipped, installed, or executed.

## Why the tier was withheld

`devflow-review.yml` triggered on `pull_request`, `pull_request_target`, `check_run`,
`workflow_run`, `check_suite` and `status`, called a reusable workflow with
`secrets: inherit`, checked out the pull-request head, and carried no actor-authorization
gate. Two open defects describe the resulting exposure and neither is close to landing:

- **#930** — `precheck` performs a bare `actions/checkout`, which under the `pull_request`
  trigger resolves the PR merge ref, so the config that decides whether a review runs at
  all comes from the pull request under review.
- **#920** — blocked on #930. It is unknown whether the collaborator-permission API call
  succeeds under `precheck`'s `pull-requests: read` token, and fork `pull_request` events
  receive a read-only `GITHUB_TOKEN` regardless of the `permissions:` block, so
  `create_check` cannot POST and the required context goes unreported.

The supported review path is unchanged: a repository collaborator with write, admin or
maintain permission comments `/devflow:review` on a pull request. An outside fork
contributor cannot self-trigger a DevFlow review.

## Recorded callee state

Re-shipping this tier is a **reconstruction, not a restore**. The preserved caller is
frozen at this tip, while its callee `.github/workflows/devflow-runner.yml` stays on
`main` and keeps evolving under the capability-profile generator
(`lib/generate-capability-profiles.py`), the `lib/review-profile.tokens` review-profile
lock, and the `#363` / `#402` gates. Issue #936 also deletes the assertions that coupled
the pair, so nothing on `main` will keep the caller and callee in agreement.

The callee state this branch was cut against, as recorded by the tree itself:

| Path | Object ID at this tip |
| --- | --- |
| `.github/workflows/devflow-runner.yml` | `395a7c38eff6827b7827cc5ae885277009fbd01f` |
| `.github/workflows/devflow-review.yml` | `8076a49b7f0282b1c323cb863adce89a78da9ad5` |

Both were obtained with `git rev-parse HEAD:<path>` — the tree's own recorded object ID,
which no clean filter and no `core.autocrlf` setting can perturb, unlike a bare
`git hash-object <path>` invocation over a working-tree file.

## What a future reconstructor does

1. Compare the callee as it stands then against the callee this branch was cut against:

   ```
   git rev-parse <ref>:.github/workflows/devflow-runner.yml
   ```

   Compare the printed object ID with `395a7c38eff6827b7827cc5ae885277009fbd01f` above.
   Equal means the callee has not moved and the preserved caller's call signature still
   fits. **Different means reconstruct, not restore**: re-derive the caller against
   whatever `devflow-runner.yml` says at that later time — its `secrets: inherit` call
   signature, the permission subset the caller must be a superset of, and the generated
   `TOOLS=` capability profile can all have moved independently.

2. Fix #930 and #920 before re-shipping. The tier is withheld because of them, not
   because of a packaging decision.

3. Re-add the removed test coverage. Issue #936 deleted the assertions whose only subject
   was `devflow-review.yml`; a reconstruction restores coverage as new work.
