---
bump: minor
type: Added
---

- **Opt-in third-party model providers for the cloud tier.** Each cloud workflow section
  (`devflow`, `devflow_implement`, `devflow_runner`) can now route through any
  Anthropic-compatible endpoint (OpenRouter, Z.ai, Kimi/Moonshot, LiteLLM gateways, …) via a
  new `providers` map in `.devflow/config.json` plus per-section `provider`/`claude_model`
  keys and one fixed repo secret, `DEVFLOW_PROVIDER_API_KEY`. A single-sourced inline jq
  resolver — byte-identical across the three workflows — emits the per-section endpoint/auth/
  model decision; a `run:` step injects `ANTHROPIC_BASE_URL`/`API_TIMEOUT_MS`/the provider
  `env` map into `$GITHUB_ENV` only when a provider is active, with a fail-loud guard when the
  secret is empty, and `--effort` is dropped for providers that reject it. With no provider
  configured, cloud behavior is byte-identical to the Anthropic-OAuth default — the feature is
  strictly opt-in and best-effort (Anthropic does not support routing Claude Code to non-Claude
  models). The reusable runner's dead `model` input is removed and its `CLAUDE_CODE_OAUTH_TOKEN`
  secret is now optional (still fail-loud on the Anthropic default path). See the new
  "Third-party model providers" section in `docs/cloud-setup.md`. (#315)
