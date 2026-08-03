---
title: "Local runs"
description: "Run PRFlow directly from Claude Code with minimal setup."
---

# Local Runs

Local runs are the default PRFlow experience. Open Claude Code in an initialized repository, then invoke a namespaced command such as:

```text
/prflow:implement 123
```

The run uses the repository, GitHub authentication and development tools already available in your environment. No GitHub Actions workflow or cloud secret is required.

Use local runs when you want to stay interactive, review decisions as the work proceeds or use tools that are already configured on your machine.

If a command cannot run a required tool, review [Local permissions](/docs/runs/local/permissions).
