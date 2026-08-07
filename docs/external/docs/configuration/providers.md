---
title: "Model Providers"
description: "Route cloud execution sections through Anthropic-compatible endpoints."
---

Route a cloud execution section through an Anthropic-compatible gateway or proxy. Provider routing is best effort, and gateway behavior can differ from the Anthropic default.

## Provider Entry Settings

Each key under `providers` is a provider name.

| **Setting** | **Type and accepted values** | **Fallback** | **Tier and security note** | **Example** |
| --- | --- | --- | --- | --- |
| `providers.<name>.base_url` | Required string URL without a trailing `/v1` API segment | None; a routed job fails if absent | Cloud only. The endpoint receives model requests and their content. | `"base_url": "https://gateway.example.com"` |
| `providers.<name>.auth` | Required `bearer` or `api_key` | None; a routed job fails if invalid | Cloud only. Both use the fixed `DEVFLOW_PROVIDER_API_KEY` secret. | `"auth": "bearer"` |
| `providers.<name>.timeout_ms` | Optional integer milliseconds | Action or client default | Cloud only. Use a positive value supported by the endpoint. | `"timeout_ms": 3000000` |
| `providers.<name>.effort_supported` | Boolean | `false` | Cloud only. False removes `--effort` to avoid gateway rejection. | `"effort_supported": false` |
| `providers.<name>.env` | Object with environment-variable names and string values | Empty object | Cloud only. Values are exported into the job environment. Do not override `PATH`, GitHub tokens or model credentials. | `"env": {"CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"}` |

**Warning:** `.prflow/config.json` is committed repository content. Never place tokens, passwords, private keys or other secret values in `providers.<name>.env`. Store credentials in GitHub Actions secrets and reference only supported secret-backed inputs.

## Section Routing Settings

| **Setting** | **Type and accepted values** | **Fallback** | **Tier and security note** | **Example** |
| --- | --- | --- | --- | --- |
| `prflow.provider` | String matching a provider name | Anthropic OAuth route | General cloud command workflow. Requires `DEVFLOW_PROVIDER_API_KEY` when set. | `"provider": "gateway"` |
| `prflow.claude_model` | String model identifier | Top-level `claude_model` | General cloud command workflow. Use the identifier expected by the route. | `"claude_model": "provider/model"` |
| `prflow_implement.provider` | String matching a provider name | Anthropic OAuth route | Shipped implementation path. Requires `DEVFLOW_PROVIDER_API_KEY` when set. | `"provider": "gateway"` |
| `prflow_implement.claude_model` | String model identifier | Top-level `claude_model` | Shipped implementation path. | `"claude_model": "provider/model"` |
| `prflow_runner.provider` | String matching a provider name | Anthropic OAuth route | **Retained legacy setting** for the withheld automatic-review runner. No effect in fresh installs. | `"provider": "gateway"` |
| `prflow_runner.claude_model` | String model identifier | Top-level `claude_model` | **Retained legacy setting** for the withheld runner. | `"claude_model": "provider/model"` |

## Configure a Provider Route

1. Add `DEVFLOW_PROVIDER_API_KEY` as a repository or environment secret.
2. Add the provider entry.
3. Point each desired active section at the entry.
4. Keep `CLAUDE_CODE_OAUTH_TOKEN` until every active section is routed and tested.

```json
{
  "providers": {
    "gateway": {
      "base_url": "https://gateway.example.com",
      "auth": "bearer",
      "timeout_ms": 3000000,
      "effort_supported": false,
      "env": {
        "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS": "1"
      }
    }
  },
  "prflow": {
    "provider": "gateway",
    "claude_model": "provider/model"
  },
  "prflow_implement": {
    "provider": "gateway",
    "claude_model": "provider/model"
  }
}
```

A selected provider with a missing secret, undefined entry, empty URL, invalid auth value or invalid environment-variable name fails before the model action starts.
