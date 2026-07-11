---
bump: patch
type: Added
---

- **Headless-wait discipline for the cloud implement tier.** `skills/implement/SKILL.md`'s
  always-resident cross-phase rules now carry a cloud-conditioned (`GITHUB_ACTIONS`)
  headless-wait rule: on the headless cloud runner, ending the turn ends the process, so the
  orchestrator must never end its turn while a dispatched agent is still pending — it polls to
  keep the turn alive and treats `ScheduleWakeup`/task-notifications as unavailable. A one-line
  mirror rides inside `devflow-implement.yml`'s stall-backstop resume comment so a resumed run
  receives it too. This is the implement-tier port of the review-tier fix (#408/#410); it
  reduces how often a cloud implement run early-quits mid-phase and burns a
  `devflow_implement.stall_backstop` resume attempt. A `schedulewakeup-probe` job in
  `matcher-probe.yml` deterministically measures whether `--disallowedTools ScheduleWakeup`
  removes/denies the tool in `claude-code-action`, gating a future `claude_args` denial.
  The probe's four-way verdict derivation is extracted into the unit-tested helper
  `scripts/schedulewakeup-probe-verdict.py` (every arm plus the fail-open name-match are
  driven in `lib/test/run.sh`), and its ScheduleWakeup name-match is hardened to be
  case-insensitive and to record a tool call even when it carries no `input` key, so a
  present tool never mis-reads as absent and ships the denial flag.
  Local/interactive runs are unchanged. (#417)
