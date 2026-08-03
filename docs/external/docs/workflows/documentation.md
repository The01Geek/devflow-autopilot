---
title: "Documentation"
description: "Keep developer docs, public guidance and release notes synchronized with code changes."
---

# Documentation

Use the documentation workflow when a branch's docs need to catch up before merge:

```text
/prflow:docs
```

PRFlow treats documentation as part of implementation, not a separate publishing task. Depending on the change, it can update:

- Internal developer documentation
- Public, customer-facing documentation
- Release notes or changesets

The repository configuration defines where each documentation family lives. Public docs should explain supported user behavior without exposing secrets, private operational details or internal-only implementation mechanics.

When `/prflow:implement` changes user-visible behavior, it normally invokes the relevant documentation checks as part of the same pull request.
