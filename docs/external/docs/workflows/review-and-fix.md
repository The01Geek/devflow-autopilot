---
title: "Review and fix"
description: "Assess a branch or pull request, then correct the problems the review verifies."
---

# Review and Fix

PRFlow separates assessment from mutation so you can choose the right level of authority.

Use review when you only want findings:

```text
/prflow:review
```

Use review and fix when you want verified findings corrected locally:

```text
/prflow:review-and-fix
```

The review engine can evaluate correctness, test coverage, silent failures, type design and review comments. It verifies findings against the repository before treating them as actionable.

Neither command merges a pull request. Review the resulting changes and verification output before you publish or merge them.
