---
bump: minor
type: Added
---

- **Config-gated attribution of cloud-tier writer commits to the triggering user.** A new
  default-off boolean key `devflow.attribute_commits_to_triggerer` (`false` by default). When
  enabled, each cloud-tier **writer** run (`/devflow:implement`'s `claude` job and
  `/devflow:review-and-fix`'s `command` job) resolves the triggering user
  (`github.event.sender.login`) to a GitHub commit identity and exports
  `GIT_AUTHOR_*`/`GIT_COMMITTER_*` before the agent runs, so the agent's commits carry the
  triggering human as author and committer — parity with local runs in `git blame`/history. The
  flag is read at trigger time from the trusted default-branch config, so its effect is
  post-merge-only; it is humans-only and fail-safe (a non-`User` type, a `[bot]` login, or an
  unresolvable type falls back to current authorship with a warning), needs no new credential
  (commit identity is git metadata, independent of the push token), and is fail-open (advisory,
  never gates the run). The read-only review tier is unaffected. Documented in
  `docs/cloud-setup.md`. (#683)
