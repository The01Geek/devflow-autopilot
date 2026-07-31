---
bump: patch
---

### Fixed

- **`/prflow:init` now corrects a superseded App slug left in `devflow.allowed_bots`, and
  `install.sh` reports one it finds.** The PR-authoring GitHub App was renamed
  `devflow-autopilot` → `prflow-implementer` (the app id behind `DEVFLOW_APP_ID` is
  unchanged). Actor authorization compares bot logins for equality, so a consumer whose
  config still names the old slug carries an entry that authorizes nothing — and the
  failure is silent one run later: the implement and review stall-backstops post their
  resume comment successfully and finish green, then the gate that comment re-enters
  declines the App as an unknown actor, so the run never resumes. The config scaffolder is
  add-only and can backfill a key but never rewrite a value, so an upgrade could not fix
  this on its own. `/prflow:init` now reads an existing `.devflow/config.json`, renames the
  stale entry (or drops it when the current login is already listed), preserves every other
  value, reports exactly what it changed for review before committing, and is a no-op on a
  config that is already correct; an unreadable, non-JSON, or wrong-shaped config leaves the
  file untouched with a one-line breadcrumb and never stops the run. `install.sh` carries
  the detection half only — it emits a `NOTICE` naming the entry and its replacement and
  routes to `/prflow:init`, never rewriting `.devflow/config.json` for this, the same
  detect-and-route split it already uses for `.claude/settings.json`.
