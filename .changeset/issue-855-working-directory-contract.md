---
bump: patch
type: Added
---

- **Make DevFlow's working-directory contract explicit and enforced.** Adds the canonical page `docs/working-directory-contract.md` (vendored to consumers) stating that on the cloud tiers the run begins at the `actions/checkout` workspace root and the Bash tool's working directory persists across calls — which is why every granted helper literal is repo-relative and no DevFlow surface emits a leading `cd` — and that the local/interactive tier re-anchors instead (`git rev-parse --show-toplevel` for the `.devflow/` readers, `BASH_SOURCE` for `scripts/*.sh` helpers). Revokes `Bash(cd:*)` from `devflow_implement.allowed_tools` (and the matcher-probe implement `EXTRAS` mirror), adds the implement-profile desk lint `IR4` (a leading `cd` in a scanned prompt surface now fails at the desk), points the four affected skills at the new page, and corrects the `cd`-evidence drift in `docs/DEVFLOW_SYSTEM_OVERVIEW.md` and `docs/cloud-allowlist.md`. (#855)
