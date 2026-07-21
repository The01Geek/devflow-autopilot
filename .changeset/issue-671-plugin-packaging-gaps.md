---
bump: patch
type: Fixed
---

- **Close plugin packaging gaps.** The test suite now parses every agent and skill frontmatter
  (PyYAML) and both manifests (JSON), and runs `claude plugin validate --strict` over a staged
  plugin tree when the CLI is present (else records an auditable `blocking-gate` skip). Fixed
  the two agent files whose `description` frontmatter failed to parse. The vendored plugin slice
  now carries `LICENSES/` so consumers receive the third-party Apache-2.0/MIT license text.
  Removed the dead `providers` block from the committed config, completed the plugin/marketplace
  manifest metadata around one canonical description, and taught the version consolidator to keep
  `CITATION.cff` in lockstep with the manifest version. (#671)
