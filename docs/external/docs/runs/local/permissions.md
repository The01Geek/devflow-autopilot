---
title: "Local permissions"
description: "Understand and safely grant the tools a local PRFlow run needs."
---

# Local Permissions

Claude Code asks for permission when a PRFlow workflow needs a tool that is not already allowed. The exact tools depend on the repository and the issue.

Typical local runs need to:

- Read and edit files inside the repository
- Run the repository's tests and linters
- Inspect Git history and the working tree
- Use authenticated GitHub CLI commands for issues and pull requests

Review each request at the narrowest useful scope. Repository-specific commands such as `make test` may be safe to allow for the session, while broad shell access deserves closer review.

PRFlow reports when required verification cannot run. It should not present an unverified change as fully validated.
