---
bump: patch
type: Changed
---

- **The cloud tier's App-token mints now pass `client-id` instead of the deprecated `app-id`
  input.** `actions/create-github-app-token@v3` emits `Input 'app-id' has been deprecated with
  message: Use 'client-id' instead.` on every mint. All nine mint steps across
  `devflow-implement.yml` (3), `devflow.yml` (4), `devflow-runner.yml` (1), and
  `version-consolidate.yml` (1) now use `client-id:`, sourced from the unchanged
  `vars.DEVFLOW_APP_ID` / `vars.DEVFLOW_REVIEWER_APP_ID` repository variables — the variable
  names, the opt-in `!= ''` gates, the `permission-*` downscopes, and the fail-loud contract
  are all untouched, so no consumer action is required. `lib/test/run.sh`'s two coupled
  literal pins (primary + reviewer mint sites) move with them. `docs/cloud-setup.md` now names
  the App's **client ID** as the variable's value, since `client-id` is the input it feeds.
