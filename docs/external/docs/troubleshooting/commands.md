---
title: "Command Problems"
description: "Fix unknown commands, GitHub authentication, wrong context and blocked verification."
---

Restore a local PRFlow command that is unavailable, resolves incorrectly or cannot complete its operation.

## The Command Is Unknown

Use the syntax for your client:

| **Client** | **Example** |
| --- | --- |
| Claude Code | `/prflow:implement 123` |
| GitHub Copilot CLI | `/prflow/implement 123` |
| Codex CLI | `$prflow:implement 123` |

If the namespace is correct, reload the plugin and follow [Installation Problems](/docs/troubleshooting/installation).

## GitHub Operations Fail

Check the active GitHub CLI account:

```bash
gh auth status
```

If needed, authenticate again with `gh auth login`. Confirm that the account can read the repository and perform the issue, pull-request or review operation PRFlow attempted. On Windows, also confirm that the same bash session resolves the intended `gh` or `gh.exe`.

## The Command Is Running in the Wrong Context

Use implementation only with an existing GitHub issue. Use review with a pull-request number or a branch that has a resolvable pull request. Review-and-fix changes files and is a local workflow; use review when you want assessment only.

## Verification Is Blocked

Read the blocked message for the exact command. Then do one of the following:

- Install the missing repository dependency.
- Correct the verification command.
- Grant a narrow command pattern to the active execution path.
- Resolve an external service that the verification depends on.

Cloud implementation must observe command-based verification in its own environment. It does not substitute a CI result. A tool grant added by the same pull request is not active until after merge.
