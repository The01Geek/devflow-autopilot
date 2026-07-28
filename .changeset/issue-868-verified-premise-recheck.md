---
bump: patch
type: Added
---

- **`Verified:` premises are re-checked at implement time.** A `Verified:` bullet in an issue
  is what licenses an implementing run to skip its own investigation, and nothing re-checked one
  once the issue was filed — so a premise that had since become false silently converted "go and
  check" into "this was already checked", and the run built on it. `/devflow:implement`'s Phase 1.6
  issue-claim audit gains a Verified-premise re-check pass that re-derives each recognized bullet
  in the issue body against the current tree via the new `scripts/check-verified-premises.py`
  helper, and fails closed to ordinary investigation when a bullet's handle or quotation no longer
  resolves. Refuting is deliberately the hardest verdict to reach — a cited directory, a glob, a
  path carrying a `::`/anchor/line locator, a filename-shaped identifier, and an elided quotation
  all resolve to "could not establish" rather than to a refutation, because a refuted premise is
  discarded and recorded as issue-accuracy feedback against the issue. (#880)
- **Drafted issues must give each `Verified:` bullet a re-derivation handle.** `/devflow:create-issue`
  now requires every `Verified:` bullet to carry the repository path plus the sentence quoted
  verbatim from it, or the exact command whose output grounded the claim, so re-checking a premise
  is mechanical rather than a re-investigation; the Step 3.5 self-steelman requires the same helper
  to run over the assembled draft — executed at the Step 3.6 pre-dispatch canonical write, the
  first anchor at which that draft file exists — and rewrites any bullet that carries no handle
  before the user sees it. The
  helper reads files and nothing else — a command handle is reported for the caller to re-run under
  its own judgment and is never executed, and a cited path that is absolute or escapes the
  repository root is refused rather than adjudicated. (#880)
