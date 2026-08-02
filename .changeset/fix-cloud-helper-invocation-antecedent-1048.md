---
bump: patch
---

Fix the cloud helper-invocation rule in `skills/implement/SKILL.md`, which was reconciled by a false antecedent (issue #1048). The removed sentence claimed the portable helper anchor "resolves to exactly this vendored literal" on the cloud tier; it does not — the anchor expands to a workspace-absolute path on both this repo and consumer repos, while the grant is repo-relative. The block now states, without contradiction, that on the cloud implement tier the repo-relative vendored literal (as leading token) is the required bundled-helper form and that this overrides "run each command exactly as written", with the anchor resolved to the granted literal at emission time. The local/interactive tier's anchor behavior is preserved and explicitly scoped from within the block, and no claim is made about whether a consumer's absolute-form path is granted (left unestablished, per `docs/cloud-allowlist.md`).
