---
bump: patch
type: Fixed
---

- **`/devflow:implement`'s outcome-reaction fence no longer addresses the repository through an
  Actions-only environment variable in its `gh api` REST path.** The fallback triggering-comment lookup now uses the
  `{owner}/{repo}` placeholders `gh` fills from the git remote, so it resolves on the
  local/interactive tier instead of collapsing to an empty repo segment and issuing a doomed API
  call at every terminal `Status` transition. The fence additionally admits a resolved comment id
  only when it is a bare digit string: `gh` writes an HTTP error body to **stdout**, so the
  previous non-empty check could be satisfied by a 404 payload and pass it downstream as a
  comment id — on the cloud tier that could POST a malformed reaction and append a misleading
  note to the issue workpad whenever the comment listing failed. A new stdlib-only guard,
  `lib/test/lint-gh-api-repo-path.py`, audits the tracked-and-unignored files outside the
  Actions-only directories and its own documented exclusion set (the prose surfaces that state
  the rule and the machine-appended corpora that quote it), and fails the suite if the form is
  reintroduced. (#664)
