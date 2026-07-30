---
bump: patch
---

### Fixed

- Closed the two coverage gaps the #948 routing ladder left on its fail-direction
  paths: `load_machine_consumer_sources`' unreadable / non-UTF-8 skip branch and its
  `MUTATION-ROUTING-CONSUMER-CORPUS-SKIPPED` breadcrumb are now driven end-to-end, and
  the issue-#711 index-reading corpus population (`git ls-files` with no `--others`) is
  pinned by a variant whose consumer is present in the worktree but untracked. Both
  paths route a pin toward step 2 rather than to rc 2, so neither regression was
  previously observable.
- Made step 1's whole-token matching (`(?<![\w-])…(?![\w-])`) an explicit guarantee: a
  distinctive token embedded in a larger identifier no longer needs to be assumed not to
  satisfy step 1.
- Narrowed `CONTRIBUTING.md`'s step-1 description to match
  `build_machine_consumer_corpus`: comment regions are subtracted for the `#`-comment
  extensions only, not for every language the corpus may carry.
- Removed a duplicated soft count of the pins carrying a pre-vocabulary category from
  two comments, which no assertion enforced and which drifts as unrelated follow-up work
  fixes those categories.
