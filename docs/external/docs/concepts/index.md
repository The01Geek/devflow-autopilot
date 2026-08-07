---
title: "How PRFlow Works"
description: "Understand PRFlow's lifecycle, progress records, review system and human control points."
---

Understand how PRFlow moves a request through an established repository while preserving human control, durable progress and independent review.

PRFlow is an orchestrated delivery workflow. It turns an issue into a branch and workpad, builds a draft pull request, verifies and reviews the change, updates documentation and hands the result to a human. It does not merge.

## Core Concepts

- [The PRFlow Lifecycle](/docs/concepts/lifecycle) follows an issue from request to human merge.
- [Workpads and Resume](/docs/concepts/workpads-and-resume) explains which progress survives an interruption and which work can still be lost.
- [The Review System](/docs/concepts/review-system) explains verification checklists, specialized reviewers, fix iterations and the shadow pass.
- [Human Control](/docs/concepts/human-control) identifies every approval, permission and merge boundary that remains yours.

## A Useful Vocabulary

- **Run:** One execution of a PRFlow skill against a repository and, for implementation, a GitHub issue.
- **Workpad:** The single issue comment that records implementation progress, acceptance criteria and durable notes.
- **Checkpoint:** A remote workpad update or a scoped commit and push that reduces how much progress an interrupted run must reconstruct.
- **Review-ready:** The authoring workflow completed and recorded its available verification and review evidence. It is not a guarantee of correctness or permission to merge without review.
