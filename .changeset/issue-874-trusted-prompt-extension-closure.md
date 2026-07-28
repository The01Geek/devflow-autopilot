---
bump: patch
---

### Security

- The cloud review tier now reads its own appended prompt extensions from the **trusted base ref** instead of the pull request's checkout. `.github/workflows/devflow-runner.yml` unconditionally creates a `$RUNNER_TEMP` closure, creates `.devflow/prompt-extensions/` in the workspace, truncates the workspace copy of each protected extension (`review`, `requesting-code-review`), and exports `DEVFLOW_PROMPT_EXTENSION_ROOT`; it then populates that closure from the base ref inside the existing fetch-success branch alone, through the new suite-driven helper `scripts/materialize-trusted-prompt-extensions.sh`. Because the suppression is unconditional and the population is not, each arm on which population does not happen degrades to an empty closure rather than to the PR-head path. Residuals — the PR-selectable marketplace manifest, the PR-head composite actions under `.github/actions/`, and the diff channel — are recorded rather than claimed closed.
- `devflow_version` is likewise resolved from the trusted base ref by a new step declared above `vendor`, so a pull request no longer selects which plugin commit — and therefore which loader — reviews it. This moves the key into the documented trigger-time-resolved class: a PR that bumps it does not affect its own review.

### Added

- `scripts/load-prompt-extension.sh` honors `DEVFLOW_PROMPT_EXTENSION_ROOT`, composing `<root>/<skill>.md` directly, at top precedence when set and non-empty and inert both when unset and when empty — the `DEVFLOW_GH` / `DEVFLOW_JQ` / `DEVFLOW_BASH` convention. The branch writes a stderr breadcrumb naming the directory it resolved; the repo-root branch is unchanged, so every caller that leaves the variable unset sees byte-identical stdout and exit codes.
- `skills/review/phases/phase-3-agents.md`'s `EXTENSION-STATUS:` contract gains a required `resolved-root` field, making a propagation failure inside the dispatched Task observable rather than silent.
- `.github/workflows/matcher-probe.yml` gains an `env-propagation-probe` job, with `scripts/env-propagation-probe-verdict.py`, measuring whether a step-level `env:` entry reaches both the orchestrator's and a dispatched Task's Bash commands. The measurement is **pending a maintainer-dispatched run**, recorded as such in `docs/cloud-allowlist.md`.

### Changed

- The three extension-classification sites reached inside the review job classify on the command's **stdout** explicitly, so the new stderr breadcrumb cannot make an empty extension report as loaded-with-content.
- `HARDENED_PATHS` is a two-producer join, so the truncated extension paths reach the engine-ground-truth block even when the Stop-hook relevance gate publishes an empty displaced-path set; `skills/review/phases/phase-0-setup.md`'s Phase 0.1 attribution covers the untracked delta a newly created empty extension file produces.
- `install.sh` creates `.devflow/prompt-extensions/`.
