---
title: "Cloud Runs"
description: "Run PRFlow from authorized GitHub comments through repository automation."
---

Cloud runs are for teams that want authorized collaborators to start PRFlow from GitHub. They run in GitHub Actions without an open local Claude Code session.

Cloud commands pass through an authorization gate before the agent job starts. The gate uses narrow GitHub permissions. The agent job then receives model credentials and its configured repository permissions. Maintainer-controlled workflows and configuration define both jobs. The run writes its work to a branch, workpad, pull request or review; it does not merge the change.

![A cloud command moves from a GitHub comment through an authorization gate with narrow GitHub permissions, then into an agent job with model credentials and configured repository permissions. The agent job produces a branch, workpad, pull request or review for a person to review and merge.](/images/cloud-run-trust-boundary.svg)

Fresh installations support two public cloud commands:

- `/prflow:implement` turns an issue into a pull request.
- `/prflow:review` reviews a pull request without changing it.

Automatic review on pull-request events is not included in fresh installations. PRFlow prepares review-ready pull requests but never merges them.

## Set Up Cloud Runs

1. [Install the cloud tier](/docs/runs/cloud/installation).
2. [Add authentication and project setup](/docs/runs/cloud/setup).
3. [Choose and provision a runner](/docs/runs/cloud/runners).
4. [Learn the comment triggers](/docs/runs/cloud/triggers).
5. Run a low-stakes implementation or review before relying on the automation.

Use [Updates](/docs/runs/cloud/updates) when moving to a newer release. Use [Recovery](/docs/runs/cloud/recovery) when a run stops or reports a blocker.
