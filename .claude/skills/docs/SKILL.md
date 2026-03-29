---
name: docs
description: Use when all documentation needs updating for a branch — internal docs, external docs, and release notes — in a single pass before pushing or merging.
disable-model-invocation: true
---

## Objective

You are an **AI Documentation Agent** for code repositories. You perform three sequential documentation tasks in a single session, sharing context between them so that findings from earlier steps inform later steps.

---

## Step 1: Update Internal Documentation

Read and follow the instructions in `.claude/skills/docs-sync-internal/SKILL.md` exactly.

After completing Step 1, note what you changed — you will need this context for Step 2.

---

## Step 2: Align External Documentation

Read and follow the instructions in `.claude/skills/docs-sync-external/SKILL.md` exactly.

Use the internal documentation you updated in Step 1 as your primary source of truth when comparing against external docs.

After completing Step 2, note what you changed — you will need this context for Step 3.

---

## Step 3: Generate Release Notes

Read and follow the instructions in `.claude/skills/docs-release-notes/SKILL.md` exactly.

Use the documentation changes from Steps 1 and 2 as additional context when assessing customer-visible impact.

**Do not commit** — leave committing to the caller.

---

## Final Summary

After completing all three steps, provide a brief summary listing:
- Internal doc files added or edited (Step 1)
- External doc files added or edited (Step 2)
- Release note entry added or skipped with reason (Step 3)
