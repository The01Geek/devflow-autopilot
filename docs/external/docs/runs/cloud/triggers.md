---
title: "Cloud triggers"
description: "Use supported GitHub comments to start PRFlow cloud workflows."
---

# Cloud Triggers

Cloud commands must appear as a real, standalone line in an eligible GitHub comment. PRFlow ignores examples inside quotes, code fences and blockquotes.

## Implement an issue

On an issue, an authorized collaborator can comment:

```text
/prflow:implement 123
```

Implementation is issue-only. The number is optional when the current issue is unambiguous, but including it makes intent clear.

## Review a pull request

On a pull request, an authorized collaborator can comment:

```text
/prflow:review
```

This manual review trigger is always available in a configured cloud installation. Automatic review requests can be added separately after you have assessed the security and cost implications for your repository.
