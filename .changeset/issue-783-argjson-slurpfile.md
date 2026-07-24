---
bump: patch
type: Fixed
---

- **Fix the weekly retrospective loop crashing with `jq: Argument list too long` at corpus scale.**
  The corpus-aggregating helpers (`lib/actionable-patterns.sh`, `lib/scan.sh`, and
  `skills/retrospective-weekly/SKILL.md` Step 9) passed operands that grow with the corpus —
  the pattern view, the open-issue map, the processed-PR set, the candidate set, and the Step 9
  summary arrays — to `jq` through `--argjson` argv slots, which overflow the kernel argument
  limit once the corpus is large enough. They now route those corpus-sized operands through
  `--slurpfile <file>` (a file read) instead; bounded scalars keep `--argjson` under an inline
  `# argjson-ok:` marker. A new `lib/test/lint-argjson-transport.py` guard (driven from
  `lib/test/run.sh`, with behavioral-fix pins and a planted-defect positive control) turns the
  suite RED if any of those three helpers regains an unmarked `--argjson`. The misleading
  `actionable-patterns.sh` failure breadcrumb that blamed the cooldown comparison now names the
  output-build / operand-size cause. (#783)
