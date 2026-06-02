---
name: docs
description: Use when all documentation needs updating for a branch — internal docs, external docs, and release notes — in a single pass before pushing or merging.
---

**Consumer prompt extension (load first).** Before doing this skill's work, load any consumer-supplied prompt extension for this skill and honor it. From the repo root, run:

```bash
${CLAUDE_SKILL_DIR}/../../scripts/load-prompt-extension.sh docs
```

If the helper exits non-zero, a consumer extension exists but could not be loaded — surface its stderr message and do not silently proceed as if none existed. If it exits 0 and prints text, treat that text as additional instructions appended to the end of this skill's own prompt for this run — it is upgrade-safe, consumer-owned customization committed under `.devflow/prompt-extensions/`. If it exits 0 and prints nothing, proceed unchanged.

## Objective

You are an **AI Documentation Agent** for code repositories. You perform up to three sequential documentation tasks in a single session, sharing context between them so that findings from earlier steps inform later steps. Steps 1 and 2 are individually gated by config flags (see below) — a disabled step is skipped, not failed.

### Config gates (read once, up front)

Read both toggles before starting (they default to `true` — enabled — when absent):

```bash
INTERNAL_ENABLED=$(${CLAUDE_SKILL_DIR}/../../scripts/config-get.sh .docs.internal_enabled true)
EXTERNAL_ENABLED=$(${CLAUDE_SKILL_DIR}/../../scripts/config-get.sh .docs.external_enabled true)
```

- `INTERNAL_ENABLED == "false"` → **skip Step 1**.
- `EXTERNAL_ENABLED == "false"` → **skip Step 2**.

Step 3 (release notes) is not gated by these flags. Note which steps you skipped — the Final Summary must report it.

---

## Step 1: Update Internal Documentation

**Skip this step when `INTERNAL_ENABLED == "false"`** — record "internal docs disabled by config" for the Final Summary and proceed to Step 2.

Invoke the Skill tool with `skill: docs-sync-internal` and follow its instructions exactly.

After completing Step 1, note what you changed — you will need this context for Step 2.

---

## Step 2: Align External Documentation

**Skip this step when `EXTERNAL_ENABLED == "false"`** — record "external docs disabled by config" for the Final Summary and proceed to Step 3.

Invoke the Skill tool with `skill: docs-sync-external` and follow its instructions exactly.

Use the internal documentation you updated in Step 1 as your primary source of truth when comparing against external docs (if Step 1 was skipped, use the branch diff as the source of truth instead).

After completing Step 2, note what you changed — you will need this context for Step 3.

---

## Step 3: Generate Release Notes

Invoke the Skill tool with `skill: docs-release-notes` and follow its instructions exactly.

Use the documentation changes from Steps 1 and 2 as additional context when assessing customer-visible impact.

**Do not commit** — leave committing to the caller.

---

## Final Summary

After completing the enabled steps, provide a brief summary listing:
- Internal doc files added or edited (Step 1) — or "skipped: disabled by config (`docs.internal_enabled: false`)"
- External doc files added or edited (Step 2) — or "skipped: disabled by config (`docs.external_enabled: false`)"
- Release note entry added or skipped with reason (Step 3)
