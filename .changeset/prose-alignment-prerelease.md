---
bump: patch
type: Changed
---

- **Aligned the plugin description with the text published in the Anthropic plugin
  directory.** `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`
  carried an older, shorter description than the submitted listing; the two now
  match byte-for-byte, and the packaging gate's length ceiling was raised from 160
  to 320 characters (with the rationale it previously lacked) so the canonical
  user-facing string fits. `CITATION.cff`'s abstract and the marketplace-level
  description are separate prose and are unchanged.
- **De-vendored the model-id allowlist comments.** The rationale comment in
  `devflow-implement.yml`, `devflow-runner.yml` and `devflow.yml` named a
  third-party vendor and product as its worked example; it now describes the id
  *shape* the allowlist admits instead, matching the project convention against
  product names in committed files. No executable line changed — the validation
  pattern is byte-identical.
