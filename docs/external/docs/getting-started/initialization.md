---
title: "Initialization"
description: "Scaffold and refresh repository-specific PRFlow configuration."
---

# Initialization

This page is for maintainers who want repository-specific PRFlow configuration. Initialization is recommended after installation and after updates. It is not required for local runs because every setting has a built-in default.

Initialization is separate from plugin installation. Run it from anywhere inside the target Git repository with the syntax for your client:

| **Client** | **Command** |
| --- | --- |
| Claude Code | `/prflow:init` |
| GitHub Copilot CLI | `/prflow/init` |
| Codex CLI | `$prflow:init` |

## What Initialization Writes

The initializer resolves the Git repository root. It then applies these idempotent changes:

- It creates `.prflow/config.json` from the shipped example when the file is absent.
- It backfills newly added configuration keys at any nesting depth when the file already exists.
- Existing values win. Customized arrays such as tool allowlists remain unchanged.
- It refreshes `.prflow/config.schema.json` to the current schema.
- It adds a commented, inert `.md.example` prompt-extension file for each skill when that example is absent.
- It does not overwrite existing examples or live prompt extensions.
- It detects Node, Go, Rust, Java, Ruby, PHP, .NET, Make and Docker markers.
- It merges matching build, test and lint tools into the three relevant allowlists. It also adds known setup commands.
- It inspects the repository for additional services, runtime requirements and project-specific build or verification commands that deterministic language detection cannot infer.
- It deep-merges the PRFlow marketplace registration into the project `.claude/settings.json`. The registration enables `prflow@devflow-marketplace` and tracks the marketplace repository's default branch with `autoUpdate: true`.

The language and tool merge is additive. Re-running initialization can discover newly added project tooling without removing custom entries or creating duplicates.

## Other Checks and Side Effects

Initialization also:

- Runs a preflight for Git, a runnable GitHub CLI, `jq`, Python 3.11 or newer and PyYAML. Authentication is a separate `gh auth status` check.
- Creates the reserved `PRFlow` GitHub label on a best-effort basis.
- Checks for shared project-memory files such as `CLAUDE.md` and reports suggestions without editing them.
- On supported third-party Claude Code providers, offers to make `auto` permission mode selectable by editing the user-global `~/.claude/settings.json`. This write requires explicit consent and is not a repository file.

**Important:** The repository scaffold is written before the dependency preflight. A missing hard prerequisite is reported, but it does not roll back `.prflow/` or other successful setup changes. Install the missing tool before running implementation or review.

## Review and Commit the Result

Review the complete diff before committing. Pay particular attention to:

| **Path** | **What to Review** |
| --- | --- |
| `.prflow/config.json` | Detected setup commands, service configuration and tool permissions. |
| `.prflow/config.schema.json` | The refreshed schema shipped with the installed release. |
| `.prflow/prompt-extensions/*.md.example` | Newly added examples. They remain inert until renamed. |
| `.claude/settings.json` | The unpinned, auto-updating project marketplace registration that collaborators inherit. |

Commit the repository files your team wants to share. Do not commit a user-global `~/.claude/settings.json` change.

If the repository predates the PRFlow rename, initialization first follows the protected migration path. Read [Migrate From DevFlow](/docs/getting-started/migrate-from-devflow) before reviewing that larger diff.
