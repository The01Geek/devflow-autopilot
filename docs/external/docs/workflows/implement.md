---
title: "Implement an issue"
description: "Turn an existing GitHub issue into a tested, reviewed and documented pull request."
---

# Implement an Issue

Run the implementation workflow with an open GitHub issue number:

```text
/prflow:implement 123
```

PRFlow uses the issue as the source of scope. It then:

1. Inspects the real repository and confirms the implementation boundary.
2. Plans the change and identifies verification requirements.
3. Implements the code and tests.
4. Runs independent review passes and fixes verified problems.
5. Updates relevant documentation and release notes.
6. Creates or updates a pull request for human review.

PRFlow does not automatically merge the pull request. Repository protections and your normal approval process remain in control.

For execution from GitHub issue comments, see [Cloud runs](/docs/runs/cloud/index).
