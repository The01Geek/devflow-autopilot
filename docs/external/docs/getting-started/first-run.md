---
title: "First run"
description: "Create a well-scoped issue and implement it with PRFlow."
---

# First Run

PRFlow works best when a change begins as a GitHub issue. The issue becomes the shared contract for planning, implementation and review.

## 1. Create the issue

Describe the outcome in ordinary language:

```text
/prflow:create-issue Add an option to keep completed run logs for 30 days
```

Review the proposed issue before approving its creation. PRFlow gathers missing requirements and writes acceptance criteria that can be verified later.

## 2. Implement the issue

Use the issue number returned by GitHub:

```text
/prflow:implement 123
```

PRFlow inspects the repository, plans the change, implements it, runs verification, reviews the result and updates relevant documentation. It creates a pull request for your review but does not merge it.

## 3. Review the pull request

Check the code, tests, documentation and release notes. Request changes or merge through your normal repository process.

Next, learn the complete [implementation workflow](/docs/workflows/implement) or configure [cloud runs](/docs/runs/cloud/index).
