---
title: "Cloud Runs"
description: "Run PRFlow from authorized GitHub comments through repository automation."
---

# Cloud Runs

Cloud runs are for teams that want authorized collaborators to start PRFlow from GitHub. They run in GitHub Actions without an open local Claude Code session.

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
