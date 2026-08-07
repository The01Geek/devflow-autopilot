---
title: "Getting Started"
description: "Install PRFlow and carry a request from user story and specification to a review-ready pull request."
---

Start with a user story, feature request or existing GitHub issue. PRFlow can shape the request into an approved issue, then carry it through implementation, verification, review and documentation. You keep final review and merge control.

PRFlow works especially well in established repositories where a change must follow existing architecture, tests and documentation conventions. You can run it locally from Claude Code, GitHub Copilot CLI or Codex CLI. Cloud automation is optional.

## The Shortest Route to Your First Pull Request

1. [Check the requirements](/docs/getting-started/requirements). Install Git, GitHub CLI, `jq`, Python 3.11 or newer and a POSIX Bash shell.
2. [Install the plugin](/docs/getting-started/installation) for your coding client.
3. Run [initialization](/docs/getting-started/initialization) if you want repository configuration, detected tool permissions and update settings. This step is recommended, not required for local defaults.
4. Follow the [first-run guide](/docs/getting-started/first-run) with an existing GitHub issue or create one with PRFlow.

The first run creates or adopts a feature branch, maintains a progress workpad on the issue and opens a pull request. PRFlow verifies and reviews the change before handing it back to you.

## Choose Where Runs Execute

[Local runs](/docs/runs/local/index) use the tools, credentials and permission system already available in your coding client. They are the fastest way to start.

[Cloud runs](/docs/runs/cloud/index) use GitHub Actions and repository credentials. Add them after the local workflow fits your team.

## Related Documentation

- [How PRFlow Works](/docs/concepts/index)
- [Workflow Guides](/docs/workflows/index)
- [Troubleshooting](/docs/troubleshooting/index)
