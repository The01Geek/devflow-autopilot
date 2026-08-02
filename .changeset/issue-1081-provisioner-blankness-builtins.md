---
bump: patch
type: Fixed
---

- **Both settings provisioners now classify an existing settings file's blankness with bash
  builtins, never `grep`.** `scripts/provision-local-settings.sh` and
  `scripts/provision-auto-mode.sh` decided whether an existing `.claude/settings.json` held
  content by shelling out to `grep -q '[^[:space:]]'`. On a host where `grep` does not resolve
  on `PATH` that test came back false, the file was treated as blank, and the deep merge wrote
  DevFlow's defaults alone — silently clobbering every key the user had set while reporting
  success (the auto-mode script writes user-global `~/.claude/settings.json`, outside any repo
  or diff). The classification is now a NUL probe plus a captured read plus a `case`
  whitespace test, all builtins, so a missing `grep` reaches the same outcome as a present one.
  A NUL-bearing settings file now fails closed (exit 2, byte-for-byte unchanged) on every host
  rather than only on some, and both scripts' `Exit codes:` headers and the `/prflow:init`
  breadcrumb routing tables record the two new exit-2 causes. (#1081)
