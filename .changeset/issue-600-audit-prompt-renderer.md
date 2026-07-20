---
bump: patch
---

Cut over the `/devflow:create-issue` Step 3.6 fresh-context audit-prompt to a bundled deterministic renderer (`scripts/render-audit-prompt.py`), the create-issue sibling of `render-grounding-block.sh`. The audit-prompt template, the generic dimension checklist, and the heading-extraction rule move to a committed template file (`skills/create-issue/references/audit-prompt-template.md`); on the normal path the orchestrator emits a compact preamble and the auditor runs the renderer instead of hand-emitting the ~2,000-word instruction block into every dispatch. Both the Step 3.6 `## Audit dimensions` and Step 2 `## Evidence axes` forwarding hooks consume the renderer's section-extraction mode, and the Step 3.5 self-check runs its checklist mode. Output carries a positional two-marker (`render-status:` first line / `render-end:` last line) delivery check with a template-file Read fallback ladder.
