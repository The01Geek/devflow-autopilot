---
title: "Working Directory"
description: "Understand how local PRFlow runs resolve the repository root and nested repositories."
---

Launch PRFlow safely from a repository subdirectory, monorepo package or nested Git checkout by confirming which repository and branch the run will use.

## Run From Any Repository Subdirectory

Local PRFlow skills can start from the Git repository root or a subdirectory. Core configuration and prompt-extension readers call `git rev-parse --show-toplevel` and anchor the default `.prflow/` path to that root.

Shell helpers that need bundled sibling files resolve from their own script location. They do not depend on the current directory for those files.

As a result, a command run from `packages/web/` normally reads the same root `.prflow/config.json` and `.prflow/prompt-extensions/` files as a command run from the repository root.

## The Nearest Git Root Wins

`git rev-parse --show-toplevel` returns the nearest containing Git root. This matters when:

- A monorepo contains a nested Git repository.
- The current directory is inside a Git submodule.
- A team deliberately stores `.prflow/` somewhere other than the Git root.

In those layouts, PRFlow anchors to the inner or nearest repository. Move to the intended repository before starting the skill. Explicit configuration-path options, where a helper provides them, are honored as written.

## Outside a Git Repository

Some helpers fall back to the current directory when no Git root can be resolved. Issue, branch, workpad and pull-request workflows still depend on real Git and GitHub repository state.

For predictable behavior, start those workflows from inside the intended Git checkout.

## Do Not Change Directory Mid-Run

PRFlow's authored commands avoid a leading `cd`. Cloud helper paths are repository-relative, and the cloud Bash working directory persists across tool calls. A directory change can make later helpers resolve against the wrong path.

Local readers re-anchor many paths, but keeping the session inside the same repository avoids selecting another Git root or confusing project-specific test commands.

See [Local Runs](/docs/runs/local/index) for the full local execution model.
