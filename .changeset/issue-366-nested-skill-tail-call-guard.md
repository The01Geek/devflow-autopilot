---
bump: patch
type: Fixed
---

- **Guard `/devflow:implement` against nested-Skill tail-call early-stops.** The implement
  orchestrator now carries a **Nested-skill completion re-anchor** (after completing any nested
  skill's procedure, re-`Read` the current phase file and resume the interrupted step, never
  re-invoking the nested skill) and an **exhaustive, exclusionary Skill rule** that forbids
  invoking any approval-gated or interactive skill (e.g. `claude-md-management:revise-claude-md`,
  `superpowers:brainstorming`) mid-run, so a nested skill's interactive terminal step can no
  longer become the run's terminal step and freeze the workpad at an in-progress `Status`. A
  scoped carve-out lets an autonomous run make a required `CLAUDE.md` edit directly, and the
  Terminal-status self-check now reads the workpad `Status` immediately before any run-final
  message. Runner-agnostic prose only — no Claude Code `Stop` hook. (#366)
