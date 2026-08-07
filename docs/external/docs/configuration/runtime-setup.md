---
title: "Runtime Setup"
description: "Configure cloud runtimes, services and repository install commands."
---

Prepare the GitHub Actions runner with the tools and setup commands PRFlow needs before it starts the agent.

Provisioning runs in this order: Python, Node.js, PHP, service containers and then `setup.install` lines.

| **Setting** | **Type and accepted values** | **Fallback or scaffold** | **Tier and security note** | **Example** |
| --- | --- | --- | --- | --- |
| `setup.python_version` | String version | Scaffold: `3.11`; empty skips setup-python | Shipped cloud paths. Keep Python 3.11 or newer for PRFlow helpers. | `"python_version": "3.11"` |
| `setup.node_version` | String version | Scaffold: empty; empty skips setup-node | Shipped cloud paths. Lockfile caching is enabled when a supported lockfile exists. | `"node_version": "20"` |
| `setup.node_working_directory` | Repo-relative string | Empty means repository root | Shipped cloud paths. It controls Node detection and caching, not the working directory of every install line. | `"node_working_directory": "frontend"` |
| `setup.php_version` | String version | Empty skips PHP setup | Shipped cloud paths. Enables PHP and Composer setup. | `"php_version": "8.3"` |
| `setup.php_extensions` | Comma-separated string | Empty installs no extra extensions | Shipped cloud paths. Used only with `php_version`. | `"php_extensions": "mbstring,intl,pdo_mysql"` |
| `setup.php_tools` | Comma-separated string | Empty uses the setup action's standard tools | Shipped cloud paths. Used only with `php_version`. | `"php_tools": "composer:v2,phpunit"` |
| `setup.services` | Array of service objects | Empty array starts none | Shipped cloud paths. Images and options are maintainer-controlled but run code on the runner. Docker must be present. | `"services": [{"name":"redis","image":"redis:7","ports":["6379:6379"]}]` |
| `setup.install` | Array of shell command strings | Scaffold: `["python -m pip install pyyaml"]`; absent runtime fallback: empty array | Shipped cloud paths. Commands run verbatim from the repository root. Treat edits as code execution. | `"install": ["python -m pip install pyyaml", "npm ci --prefix frontend"]` |
| `setup.claude_code_executable` | Single-line nonblank string path | Scaffold: empty; uses action auto-install | Cloud model jobs. Primarily for a preinstalled Windows executable. Trigger-time and post-merge-only. | `"claude_code_executable": "C:\\Users\\runner\\.local\\bin\\claude.exe"` |
| `setup.git_dir_pin` | Boolean | `false` | Cloud jobs except implementation. Can misdirect repository-root config reads; leave off unless validated. Post-merge-only. | `"git_dir_pin": false` |
| `setup.git_work_tree_pin` | Boolean | `false` | Cloud jobs. Breaks remote marketplace cloning; use only with local-only marketplaces. Post-merge-only. | `"git_work_tree_pin": false` |

**Warning:** `.prflow/config.json` is committed repository content. Never place tokens, passwords, private keys or other secret values in `setup.services[].env`. Store credentials in GitHub Actions secrets and reference only supported secret-backed inputs.

Each `setup.services` object requires string `name` and `image`. Optional `ports` and `options` are arrays of complete strings. Optional `env` is an object of string values. Services are reached on `127.0.0.1:<host-port>`. Use health-check options when readiness matters.

## Valid Runtime Example

```json
{
  "setup": {
    "python_version": "3.11",
    "node_version": "20",
    "node_working_directory": "frontend",
    "php_version": "",
    "php_extensions": "",
    "php_tools": "",
    "services": [
      {
        "name": "redis",
        "image": "redis:7",
        "ports": ["6379:6379"]
      }
    ],
    "install": [
      "python -m pip install pyyaml",
      "npm ci --prefix frontend"
    ],
    "claude_code_executable": "",
    "git_dir_pin": false,
    "git_work_tree_pin": false
  }
}
```

Installing a tool does not permit the agent to invoke it. Continue with [Tool Permissions](/docs/configuration/tool-permissions).
