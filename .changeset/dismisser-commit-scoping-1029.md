---
bump: patch
---

### Fixed

- `scripts/dismiss-stale-rejections.sh` no longer dismisses a `CHANGES_REQUESTED` review that is not
  actually superseded (#1029). The selection filter matched only the review *body*, so a REJECT
  recorded against the pull request's **current** head was dismissed exactly like one recorded
  against an abandoned commit — including a REJECT another review pass had posted seconds earlier on
  that same commit. Every candidate is now compared against the pull request's current head: a review
  whose `commit_id` differs is dismissed as before, one whose `commit_id` equals the current head is
  refused, and one carrying no `commit_id` is refused too (staleness cannot be shown, so the guard
  fails closed rather than open). A head that cannot be read — the request fails, or the value is
  empty, `null`, or not a commit SHA — dismisses nothing. The pre-existing body scoping is unchanged:
  a human `--request-changes`, an already-dismissed review, and a null-body row are still never
  selected. Refusals report a new exit status `3`, distinct from the clean-no-op `0` so a wedged pull
  request cannot look like there was nothing to do; a genuine dismissal failure still reports `1`.
