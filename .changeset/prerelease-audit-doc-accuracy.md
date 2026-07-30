---
bump: patch
---

### Fixed

- Cloud setup docs no longer describe `devflow-review.yml`, a workflow that is not in the
  tree. `docs/cloud-setup.md` had named it among "the five consumer-shipped workflows" and
  its workflow inventory gave an install instruction ("edit that list when installing") for
  a file that does not exist. The true shipped set is **two** workflows — `devflow.yml` and
  `devflow-implement.yml` — and the inventory now states which entries `install.sh` copies,
  which belong to this repository only, and which are the retained withheld-tier files.
  `docs/DEVFLOW_SYSTEM_OVERVIEW.md` carried the same stale count and is reconciled.
- README requirements no longer overstate the PyYAML dependency. It is a lazy import in a
  single helper, reached only when a pull-request body already carries a deferred-findings
  block, and the review engine logs and steps over its absence with all findings intact.
- The withheld auto-review tier disclosure is reworded to state its actual disposition —
  the feature was withdrawn rather than abandoned, and a fresh install is unaffected — and
  moved below the fold, with the removal procedure spelled out.

### Changed

- Skill descriptions shown in the skill picker use the current product name: `init`,
  `receiving-code-review` and `requesting-code-review`. The `/devflow:implement` alias in
  the `implement` skill's description is retained deliberately — it is still a live trigger.
- `docs/DEVFLOW_SYSTEM_OVERVIEW.md` no longer carries a hand-maintained version literal
  (it read `2.4.3` against a shipped `2.28.1`); it points at `plugin.json` instead.
- `CHANGELOG.md`'s live header uses the current product name. Dated entries are unchanged.
- The README gained an `install` anchor so the published one-pager's call-to-action lands
  on the install instructions rather than the top of the page.
