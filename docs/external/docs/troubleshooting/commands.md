---
title: "Command problems"
description: "Fix PRFlow commands that are unavailable, rejected or used in the wrong context."
---

# Command Problems

## The command is unknown

Use the current namespace, including the colon:

```text
/prflow:implement 123
```

If the command still does not appear, reload plugins and confirm the installation as described in [Installation problems](/docs/troubleshooting/installation).

## GitHub operations fail

Run `gh auth status` and confirm the authenticated account can access the repository. The account also needs permission for the issue, pull request or workflow operation being attempted.

## Verification cannot run

Read the reported command and error. Install the repository dependency, correct the command or grant an appropriately narrow local permission. PRFlow should report blocked verification rather than treating it as a pass.

## The workflow is not appropriate

Use `/prflow:review` for assessment only. Use `/prflow:review-and-fix` when you also want local corrections. Use `/prflow:implement <issue-number>` when the work should produce a complete pull request from an existing issue.
