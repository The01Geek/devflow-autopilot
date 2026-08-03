---
title: "Create an issue"
description: "Turn a rough request into a GitHub issue that is ready for implementation."
---

# Create an Issue

Use `/prflow:create-issue` for a feature idea, bug report or improvement that should be captured in the backlog.

```text
/prflow:create-issue Prevent duplicate release comments when a workflow retries
```

PRFlow explores the request, inspects relevant repository context and drafts a structured issue. You can clarify the scope before the issue is created.

## What a useful request includes

You do not need to write formal acceptance criteria. A concise request is enough when it identifies:

- The user or system affected
- The desired outcome
- Any important constraint or example

PRFlow turns that context into an implementation boundary and testable acceptance criteria. When a criterion uses a number, PRFlow names the exact command or counting rule that measures it. If it cannot establish the instrument, it records the measurement as unestablished instead of publishing an ambiguous threshold.

After creation, pass the issue number to [the implementation workflow](/docs/workflows/implement).
