---
bump: patch
type: Fixed
---

- **A new user's first command works again: the documented install identifier is now
  `prflow@devflow-marketplace`.** The plugin was renamed `devflow` → `prflow` and the rename
  swept every executable surface, but the human-facing surfaces were left behind — `README.md`
  and `docs/` still told a reader to run `claude plugin install devflow@devflow-marketplace`,
  which fails on a clean install with `Plugin "devflow" not found in marketplace
  "devflow-marketplace"`. The marketplace `renames` map migrates an *already-installed* plugin;
  it is not an install-time alias. All nine documented install sites across `README.md`,
  `docs/install.md`, `docs/cloud-setup.md` and `docs/DEVFLOW_SYSTEM_OVERVIEW.md` now name
  `prflow@devflow-marketplace`, and both `README.md` and `docs/install.md` explain why the
  marketplace keeps the `devflow-marketplace` name (the `renames` map is scoped per
  marketplace, so renaming it would strand every existing install).
- **Every documented command is now `/prflow:`.** README's quick start, the skills table, the
  end-to-end workflow diagram and all of `docs/` used the retired `/devflow:` local-command
  namespace. The README's namespacing note previously gave inverted advice — *"always use the
  `/devflow:`-prefixed form"* — and now states the split correctly: **local** slash commands are
  `/prflow:` only, because a skill's namespace is the plugin name, while **cloud comment
  triggers accept both** namespaces during the alias window. `docs/workflow-triggers.md` states
  that dual acceptance where the trigger surface is documented.
- **Two dead documentation links are repointed.** `docs/external/release-notes.md` cited
  issues #930 and #920 at the pre-rename `The01Geek/devflow-autopilot` path, which now returns
  404; both point at `The01Geek/prflow` and were re-verified live.
- **Product naming and scaffolded config.** `README.md`, `CITATION.cff`, `CONTRIBUTING.md`,
  `SECURITY.md`, `LICENSES/README.md`, the `docs/` corpus and the vendored agent descriptions
  now say **PRFlow**. `.devflow/config.example.json` — what `/prflow:init` scaffolds into a new
  repository — and the `config.schema.json` descriptions an editor surfaces no longer seed the
  stale `devflow:` agent namespace or document `/devflow:` commands.
- **Deliberately unchanged:** the `devflow-marketplace` marketplace name, the `.devflow/`
  directory, `DEVFLOW_*` environment variables, `devflow_*` config keys, the `<!-- devflow:* -->`
  markers, the reserved `DevFlow` provenance label, the `Devflow Reflection` / `Devflow Review`
  markers, the workflow filenames, the `lib + python tests` check name, and the
  `devflow-autopilot` GitHub App, which is a separate identity that has not been renamed.
  `CHANGELOG.md` and `.devflow/learnings/**` are dated historical records and keep the old name.
