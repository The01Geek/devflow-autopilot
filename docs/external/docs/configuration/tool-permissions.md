---
title: "Tool Permissions"
description: "Grant repository commands to the correct PRFlow execution path."
---

Grant cloud agents only the repository-specific test, lint, build or deployment commands their work requires.

Installation and runtime provisioning do not grant command execution. PRFlow appends configured entries to a built-in allowlist; configured arrays do not replace the base profile.

| **Setting** | **Type and accepted values** | **Fallback** | **Tier and security note** | **Example** |
| --- | --- | --- | --- | --- |
| `prflow.allowed_tools` | Array of claude-code-action tool strings | Empty array adds nothing | General cloud command workflow. It does not apply to implementation. | `["Bash(npm test:*)"]` |
| `prflow_implement.allowed_tools` | Array of claude-code-action tool strings | Empty array adds nothing | Shipped implementation path. It does not inherit `prflow.allowed_tools`. | `["Bash(npm test:*)"]` |
| `prflow_runner.allowed_tools` | Array of claude-code-action tool strings | Empty array adds nothing | **Retained legacy setting** for the withheld runner. It is used only when `prflow_runner.provision_env` is true. Built-in restrictions still apply and cannot be loosened by this setting. | `["Bash(npm test:*)"]` |

## Grant Commands per Path

List the leading command and arguments directly. Add the same entry under every path that needs it:

```json
{
  "prflow": {
    "allowed_tools": [
      "Bash(npm test:*)",
      "Bash(npm run lint:*)"
    ]
  },
  "prflow_implement": {
    "allowed_tools": [
      "Bash(npm test:*)",
      "Bash(npm run lint:*)"
    ]
  }
}
```

The two shipped allowlists are independent. Neither inherits from the other. A command provisioned by `setup.install` can still be denied if it is absent from the active tier's list.

Use the narrowest leading command that performs the needed check. PRFlow's built-in restrictions can deny compound shell wrappers and raw `bash`, `sh`, `zsh`, `eval`, `exec`, `source` or `sudo` commands even when a broader entry appears in the configuration.

## Plan Grants Before the Work

Cloud workflows resolve grants at trigger time from the default branch. A pull request that adds its own permission cannot use that permission during the same run. The grant becomes effective after merge.

If a required verification command is not granted, implementation marks that verification blocked. It does not treat CI as an in-run substitute. Merge the narrow grant first, then retry the work that needs it.
