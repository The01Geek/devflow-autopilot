---
title: "Cloud runs"
description: "Run PRFlow from authorized GitHub comments through repository automation."
---

# Cloud Runs

Cloud runs let an authorized collaborator start PRFlow from GitHub without keeping a local Claude Code session open.

For implementation, add a standalone issue comment:

```text
/prflow:implement 123
```

The command does not use an `@claude` mention. PRFlow validates the commenter, provisions the declared environment and records progress in a single workpad comment.

Cloud automation is optional. Complete [Cloud setup](/docs/runs/cloud/setup), learn the supported [Triggers](/docs/runs/cloud/triggers) and keep [Recovery](/docs/runs/cloud/recovery) available for failed or interrupted runs.
