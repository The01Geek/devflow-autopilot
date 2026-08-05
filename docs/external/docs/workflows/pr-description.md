---
title: "Pull Request Description"
description: "Generate or update a structured pull request description from the current branch."
---

# Pull Request Description

Use this workflow when you want the current branch's pull request body to match the current code. It can update an existing pull request body but does not edit branch files. The result is an updated pull request body or a complete description in chat when no pull request exists.

```text
/prflow:pr-description 123
```

The issue number is optional. When provided, PRFlow adds `Resolves #123` and reads the issue for context.

## What PRFlow Reads

PRFlow compares the current branch with the base branch. It reads the commit history, diff summary and detailed diff. When a related implementation workpad exists, it also carries post-merge verification items into the pull request body.

Deferred review findings filed by the implementation workflow appear in a Scope-Acknowledged Findings section. This keeps the human disclosure with the information PRFlow uses to recognize the finding later.

## Existing Pull Request

When the current branch already has a pull request, PRFlow updates its body directly. Generated sections such as Summary, Changes, Visual Changes and Breaking Changes are refreshed from the current diff.

Human content is preserved:

- Human-added Test Plan items remain when they are still relevant.
- Existing issue links remain alongside a newly supplied issue number.
- Custom sections such as Reviewer Notes or Deploy Steps retain their position.
- Content outside the PRFlow body markers remains outside those markers.
- An unmarked existing body is preserved above the newly generated marked section.

## No Existing Pull Request

When no pull request exists, PRFlow does not create one. It outputs the complete description as plain text so a caller or user can supply it when creating the pull request.

## Expected Result

The generated body contains a concise summary, grouped changes, issue links, a concrete test plan and applicable post-merge, deferred, visual and breaking-change sections.

## Related Articles

- [Implement an Issue](/docs/workflows/implement)
- [Command Reference](/docs/reference/command-reference)
