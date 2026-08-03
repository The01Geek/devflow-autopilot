---
bump: patch
type: Fixed
---

- **Shipped skill bodies no longer point at PRFlow-internal documentation.** Every file under
  `skills/**` is installed verbatim into a consumer repository, but 26 lines across 13 first-party
  skill files referenced PRFlow's own `docs/` tree — paths that do not resolve in a consumer's
  checkout, sending a consumer's runtime agent (and, in the init skill, its human maintainer) after
  documentation about someone else's repository. Each reference is now removed where the sentence
  stood without it, or replaced with self-contained repo-agnostic prose that carries the original
  claim's full strength, including its evidence grade where it had one. Where a pointer was the only
  backing for a claim — the cloud allowlist's `unestablished` and `inference, not measurement`
  grades, the base-branch `CLAUDE.md` restore that scopes a review-path self-supply hazard, the
  experiment store's deliberate abandoned-run survivorship bias — that backing is restated inline
  rather than dropped, and where a pointer still helps it now names an artifact the consumer
  actually has (`lib/efficiency-trace.jq`'s header, `scripts/build-experiment-records.py`'s
  docstring). Three PRFlow-internal PR numbers no longer ship inside the review engine. No behavior
  changes and no frontmatter is touched. (#1190)
