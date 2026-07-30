---
bump: patch
type: Changed
---

- **Repository references now point at `The01Geek/prflow`, the repository's new name.** The
  GitHub repository was renamed from `devflow-autopilot` to `prflow`; this updates every live
  reference that names it — the installer's `DEVFLOW_REPO` default, the `vendor-plugin`
  composite action's `DEVFLOW_REPO` default, the `claude plugin marketplace add` instructions,
  the `raw.githubusercontent.com` installer pins, the plugin and marketplace manifests'
  `homepage`/`repository` metadata, the config schema's `$id` and its `devflow_version`
  description, the citation metadata, and the marketplace registration
  `scripts/provision-local-settings.sh` writes into `.claude/settings.json`. GitHub redirects
  the old repository path for git and API traffic, so existing installations keep working and
  no consumer action is required; GitHub Pages does **not** redirect, which is why the
  README's one-pager links had to move to `https://the01geek.github.io/prflow/`. Dated
  historical records — the changelog, the external release notes, and the retrospective
  learnings corpus — deliberately keep the old name, because rewriting them would falsify a
  record of runs that happened under it. The plugin's own identity is untouched: the plugin is
  still named `prflow` with the `devflow` alias, and the `devflow-autopilot` GitHub App keeps
  its name, which is a separate thing from the repository. (#972)
