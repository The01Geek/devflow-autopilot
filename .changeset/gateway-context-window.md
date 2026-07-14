---
bump: patch
type: Fixed
---

- **Third-party model providers: document how to get the model's real context window.** Claude Code
  cannot verify a gateway model's context length, so it budgets **200K** and auto-compacts there —
  even for a natively-1M model (GLM-5.2, MiniMax-M3, Qwen3.7-Plus, …), silently costing most of the
  window you are paying for. `docs/cloud-setup.md` now documents `CLAUDE_CODE_MAX_CONTEXT_TOKENS`
  (honored only for model ids that do not begin with `claude-`, i.e. purpose-built for gateway
  models) and both worked examples set it to `1000000`. Verified: `/context` reports a 1,000,000-token
  window against `z-ai/glm-5.2` on OpenRouter instead of 200,000. Flagged as undocumented/upgrade-fragile,
  with an explicit warning against the `CLAUDE_CODE_EXTRA_BODY` + `opus[1m]` workaround, which injects a
  `model` override into every request and collapses the haiku/subagent roles onto a single model.
- **Corrected a wrong gateway-400 remedy.** The docs advised `CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING=1`
  for `thinking`/`adaptive` 400s, but that flag is hard-scoped to the Opus/Sonnet **4.6** family and is
  therefore **inert for a third-party gateway model** — exactly the audience of that section. The lever
  that actually drops the `thinking` field for any model is `CLAUDE_CODE_DISABLE_THINKING=1`.
