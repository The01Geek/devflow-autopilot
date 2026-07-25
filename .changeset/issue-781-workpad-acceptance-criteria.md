---
bump: patch
---

### Fixed

- The shared review engine now judges a PR against the acceptance criteria the run is
  actually delivering, and states in its report which surface they came from (#781, PR #786).
  `/devflow:implement` moves the authoritative criteria into the workpad comment — Phase 2.2.5
  narrows the set, Phase 2.2.6 rewrites criterion text, Phase 3.4 retags — while Phase 0.4 read
  them from the GitHub issue body and truncated that body to its first 200 lines, so a run's
  deliberately descoped criteria were re-raised as failures and a criteria section far into a
  long body was silently dropped.

### Added

- `/devflow:review` and `/devflow:review-and-fix` accept `--issue N`, and `/devflow:implement`
  Phase 3.3 passes it at both of its invocation sites, so the engine no longer has to derive the
  issue number from the PR body or the branch name.
- `scripts/workpad.py` gains an `acs` subcommand that prints the workpad's `## Acceptance Criteria`
  section (verbatim, or post-merge-filtered and box-neutralized for the reviewer) and an
  `acs-resolve` subcommand that resolves both surfaces, guards that the workpad section belongs to
  the PR under review, selects the reviewer-facing value, names its source, and reports normalized
  divergence. Phase 4's `## Issue Compliance` reports that source distinctly for each outcome —
  including a workpad whose criteria were never mirrored and a workpad read that failed — and
  reports a no-criteria run as a gap rather than omitting the check.
- `/devflow:implement` writes a delimited, machine-readable scope-decision record whenever it defers
  or rewrites a criterion, so an audited narrowing is distinguishable from an unexplained one; a
  narrowing with no record fails closed.
- The `checklist-generator` category enum gains `issue_acceptance`, giving the review engine's
  highest-priority checklist rank a real producer, bounded by a 25-of-100 sub-cap so it cannot evict
  the lower-ranked signal.

### Changed

- The section- and checkbox-parsing rules `scripts/parse-acs.py` owned are factored into
  `scripts/section_parse.py`, which both helpers import in-process, so the mirror and the read-back
  can never disagree.
- Every raw `$ARGUMENTS` interpolation in the review engine is re-anchored on the parsed
  `$PR_NUMBER`, so an extended argument string cannot reach a command line or silently disable the
  phases gated on an is-a-PR-number test.

### Fixed

- `acs-resolve` no longer collapses a routed non-workpad state onto the `none` source when the
  issue-body fallback is also empty. `none` asserts that both surfaces were examined and neither
  carried criteria, so a run whose workpad read failed (`workpad-read-failed`) reported a
  measurement it never took, and a run whose mirroring silently failed (`workpad-unmirrored`)
  reported the opposite of what happened. The demotion is now reached only from the clean-absence
  state.
- A `rewritten` scope-decision record carrying no `newtext=` field no longer reports its criterion
  as an audited `CHANGED:` text change. It records nothing about what replaced the criterion, so it
  covers nothing and routes to `DROP` — the direction the PR-identity guard already took for the
  same shape.
