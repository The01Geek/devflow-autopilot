---
title: "Documentation"
description: "Choose the PRFlow documentation workflow for branch changes, one topic or a new documentation set."
---

# Documentation

Use this workflow guide when you want to verify or update documentation. The selected workflow can edit the documented files unless you choose report-only verification. A run returns updated documentation or a report that names the skipped work and any blocker.

## Choose a Documentation Workflow

| **Need** | **Command** | **Behavior** |
| --- | --- | --- |
| Run a complete branch documentation pass | `docs` | Runs internal sync, external sync and release notes in sequence. Internal and external steps can be disabled by configuration. |
| Update developer documentation for changed code | `docs-sync-internal` | Edits internal docs in proportion to functional changes on the current branch. |
| Align existing public docs with internal docs or shipped behavior | `docs-sync-external` | Edits existing customer-facing docs and removes internal-only detail. Both internal and external documentation trees must already exist. |
| Verify one named topic and fix its internal docs | `docs-verify <topic>` | Compares the topic's documentation with code and edits missing or inaccurate internal docs. |
| Inspect one topic without changing files | `docs-verify --report-only <topic>` | Returns a structured code and documentation findings report with no edits, commits or pushes. |
| Create or reorganize developer docs from scratch | `docs-bootstrap-internal` | Builds a domain-based internal documentation structure with substantive seed pages. |
| Create or comprehensively rebuild public docs | `docs-bootstrap-external` | Generates customer-facing docs from existing internal documentation. Stops if the internal source is absent or empty. |
| Add a customer-facing release note | `docs-release-notes` | Adds a note only for customer-visible changes and reconciles an applicable changelog entry. |

## Run the Complete Pass

Use `docs` when a branch needs a general documentation check before merge:

```text
/prflow:docs
```

The router first updates internal developer docs, then aligns external docs and finally evaluates release notes. It does not commit its changes. A caller such as [Implement](/docs/workflows/implement) owns the commit.

## Sync or Bootstrap

Use a sync command when the relevant documentation tree already exists. Use a bootstrap command when the tree is absent, empty or needs a comprehensive rebuild.

External documentation depends on an internal source of truth. Run `docs-bootstrap-internal` first when internal docs do not exist. `docs-bootstrap-external` refuses to fabricate public guidance without that source.

## Verify Without Editing

The default `docs-verify` mode can change internal documentation. Add `--report-only` when you need analysis without file changes.

```text
/prflow:docs-verify --report-only retry handling
```

Create Issue uses this report-only mode to inspect a topic before it drafts a ticket.

## Related Articles

- [Command Reference](/docs/reference/command-reference)
- [Configuration Settings](/docs/configuration/settings)
