---
bump: patch
type: Fixed
---

- **Renamed the PR-authoring GitHub App reference to its current slug.** The App
  was renamed `devflow-autopilot` → `prflow-implementer` (`PRFlow (Implementer)`;
  the app id is unchanged at `3102164`) and the old slug now 404s, so every
  workflow comment, setup instruction, and architecture note naming it pointed at
  an identity a reader could not look up. The `DEVFLOW_APP_ID` variable and
  secret names are deliberately unchanged — they are configuration identifiers,
  not App identity — as are the workspace-path grants in `.devflow/config.json`
  (repo-name, re-anchored onto the live `$GITHUB_WORKSPACE`) and the dated
  `CHANGELOG.md` records.
