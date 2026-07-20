---
bump: patch
type: Changed
---

- **Calibrated quantitative claims in the `code-explorer`/`code-architect` discovery agents and removed their inert `KillShell`/`BashOutput` grants.** Both agent bodies now state a calibration rule — a quantitative claim (count, size, word count, percentage, arithmetic total) not read directly from tool output in the current session, or derived from truncated/limited/count-mode output, is marked `(unverified estimate)`, and a tool-derived claim states its operands and counting rule inline. The explorer additionally scopes its `file:line` precision to ephemeral in-context analysis, noting that committed documentation references bare paths and symbol names. `/devflow:implement` Phase 2 §2.2 now obliges the orchestrator to independently re-derive a Phase-2 subagent quantitative claim through a preflight-guaranteed channel before it feeds a plan step, gate, or budget decision, recording the re-derived-or-unverified status in the workpad. The two agents' `tools:` lines drop the two inert grants (no `Bash`, so neither could act on them). (#628)
