---
bump: patch
---

Complete the CI-green auto-review trigger: ship it to consumers and close three
shipped-job residuals (#990).

**Part A — consumer delivery.** `docs/workflow-triggers.md` now carries a
copy-pasteable `pull_request` job snippet a consumer adds to their own CI, with the
hard `pull_request`-only precondition stated adjacent to it, plus the `allowed_bots`
App-slug requirement (and its trigger-time default-branch resolution), the `2.30.18`
minimum `prflow_version`, the no-repository-root-`scripts/` fact, an absent-file
breadcrumb guard, a sparse cone naming both vendored directories, and the coverage
boundary (GitHub Actions jobs only). A new row in the trigger table and a
`docs/cloud-setup.md` note document the mechanism, and every in-tree statement that a
collaborator comment is the review path is reconciled to name the automatic
producer. `lib/test/extract-ci-review-agreement.py` (driven from the
`review-trigger-helpers` module) asserts a fail-closed byte-equality agreement
predicate between the snippet and the `auto_review_trigger` job region, with a
planted-defect positive control and six fail-closed input shapes. `install.sh`'s
workflow copy loop is byte-unchanged — `ci.yml` is repo-internal and the snippet is
the delivery vehicle.

**Part B — three shipped-job residuals.** `.github/workflows/ci.yml`'s
`auto_review_trigger` job gains a `concurrency` group keyed on the head SHA
(`cancel-in-progress: false`) so its read-then-post dedupe is atomic;
`scripts/post-ci-review-trigger.sh` now suppresses only a marker comment the minting
App itself authored (matching bare and `[bot]` slug forms, empty comparand
fail-closed) instead of on marker containment alone; and the job's `if:` widens to
`!cancelled()` with the two dependency-success tests moved onto the checkout, mint,
and post steps, so a red `lint` — not a required check — is announced by a
`::warning::` naming which dependency withheld the request (composed in the helper
under a new `MODE=announce`) rather than skipped in silence. The announcement path
mints no token and checks out no pull-request code.
