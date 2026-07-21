---
bump: patch
type: Added
---

- **Packaging validation gate and manifest metadata.** The test suite gained a `#671 packaging`
  block that parses every agent and skill frontmatter plus both plugin manifests, and runs
  `claude plugin validate --strict` over a staged plugin tree where the CLI is available. The
  plugin manifest gained `displayName` and the marketplace entry gained `version`, `license`,
  `keywords`, and an owner `url`. The version consolidator now bumps `CITATION.cff` and the
  marketplace plugin entry alongside the manifest, and the `version-consolidate` workflow stages
  both so the lockstep lands on merge. (#671)
