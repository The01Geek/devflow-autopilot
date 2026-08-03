---
title: "Runs"
description: "Choose whether PRFlow executes in your local Claude Code session or through GitHub Actions."
---

# Runs

PRFlow supports two execution models:

- [Local runs](/docs/runs/local/index) execute in your current Claude Code session and are the fastest way to get started.
- [Cloud runs](/docs/runs/cloud/index) execute through repository automation after an authorized GitHub comment.

The workflows are conceptually the same, but the execution environment changes. Local runs inherit the tools and credentials available to your session. Cloud runs use explicit GitHub permissions, repository secrets and a declared setup process.

Begin locally. Add cloud automation when comment-driven execution provides enough value to justify the additional repository configuration.
