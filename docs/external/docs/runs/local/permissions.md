---
title: "Local Permissions"
description: "Grant only the repository, Git and GitHub access a local PRFlow run needs."
---

Review and approve the tool access a local PRFlow run needs. The exact prompt and persistence options come from your coding client.

## Match Permission to the Workflow

A read-only review usually needs repository reads, Git history, pull-request data and verification commands. An implementation or review-and-fix run also needs repository writes, Git commits and GitHub pull-request updates.

Typical permissions include:

- Read files inside the target repository.
- Edit files for workflows that are expected to change code or documentation.
- Inspect Git status, history and diffs.
- Create and push a scoped feature branch.
- Run the repository's specific tests, linters and build commands.
- Use authenticated `gh` commands for the relevant issue or pull request.

## Keep Grants Narrow

- Prefer a specific command such as `make test`, `npm test` or `cargo test` over unrestricted shell access.
- Limit filesystem access to the target repository unless a known dependency lives elsewhere.
- Grant GitHub operations needed for the current issue or pull request instead of broad administrative access.
- Treat `sudo`, raw shell evaluation and user-global file writes as separate, high-risk decisions.
- Review persistent or project-wide grants more carefully than a one-time approval.

Declining a required tool can leave verification incomplete or stop the lifecycle with a recorded blocker. That is safer than reporting unobserved work as validated.

## Repository Configuration Is a Separate Boundary

Cloud tool profiles use `.prflow/config.json`. The `prflow.allowed_tools` and `prflow_implement.allowed_tools` lists are independent; one does not inherit the other.

Those lists do not replace your local client's permission prompts. Review both boundaries when a repository supports local and cloud runs.

## Inspect the Result

Before merging, check that the workpad and pull request identify any command that was denied, skipped or unavailable. A review verdict narrows risk only when its stated evidence was actually observed.

See [Human Control](/docs/concepts/human-control) for the wider approval and merge boundaries.
