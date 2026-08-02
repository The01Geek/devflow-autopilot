---
bump: patch
---

Reconcile the documented consent posture of `scripts/provision-local-settings.sh` with its
shipped, ungated behavior. The script writes the project `.claude/settings.json` immediately
when `/prflow:init` invokes it — no `--apply` gate — but `install.sh` and `CLAUDE.md` described
it as consent-gated, and `CLAUDE.md` additionally mis-described it as a way to widen the local
permission allowlist. The script is deliberately left ungated (a gate would also stop the
superseded-identifier migration that shares one atomic write, and would make a deliberately-typed
command do nothing); every describing sentence is corrected instead — in `install.sh` (the
consent-gated-provisioners comment and the superseded-identifier gate comment), `CLAUDE.md`,
`skills/init/SKILL.md` (the settings step now states the ungated/committed/unpinned posture, and
the `devflow-settings:` relay list gains an arm for every breadcrumb plus a no-match default),
`docs/install.md`, `docs/cloud-setup.md` (the local-editor aside and the now-non-circular
security-posture justification), `docs/DEVFLOW_SYSTEM_OVERVIEW.md`, and `README.md`. Adds
executable assertions in `lib/test/run.sh` pinning the bare-invocation write contract, the
key-for-key agreement of the documented `jsonc` blocks with the shipped output, and that a
superseded-only fixture ends with exactly one (canonical) plugin identifier. The version-pin
axis is split out to a follow-up issue.
