---
bump: patch
---

### Added

- `scripts/prompt-surface-growth.py` renders the prompt-surface byte delta a branch introduces, alongside the running byte total at `HEAD`, as a markdown table for the PR description. The covered population is tracked `*.md` files under `skills/`, `agents/`, and `.prflow/prompt-extensions/`, enumerated from the committed tree at both the merge-base and `HEAD` so a deleted file still renders (total `0`, negative delta). It is measurement only — no threshold, ceiling, or budget — and always exits 0, printing a stated one-line breadcrumb instead of a table when `HEAD` is the merge-base, when no covered path changed, or when the merge-base cannot be resolved. (#1355)
- The `implement` and `command` capability profiles grant the new helper, so a cloud run can invoke it rather than having it silently refused. (#1355)
