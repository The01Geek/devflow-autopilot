---
title: "The Review System"
description: "Understand how PRFlow verifies claims, combines reviewers and fixes findings."
---

PRFlow combines mechanical evidence with independent review passes to find defects before handoff. The result increases confidence, but it does not prove that a change is perfect.

![The prflow:review skill moves through setup and classification, a verification checklist, specialized reviewers and a verdict. The prflow:review-and-fix skill uses the same engine, applies justified corrections, verifies them and reviews the result again. A shadow pass checks an approval-side result before the loop exits.](/images/review-system-loop.svg)

## Four Review Phases

### Setup and Classification

The review engine identifies the pull-request or branch diff, its base, related issue acceptance criteria and the risk profile of the changed files.

### Verification Checklist

PRFlow builds a change-specific verification checklist. It removes overlapping checks. It can evaluate simple presence or absence claims automatically. It sends deeper claims to a reviewer for evidence-based evaluation.

A failed or inconclusive checklist item prevents a clean approval.

### Specialized Reviewers

PRFlow requests reviewers with different focus areas, including code correctness, tests, comments, silent failures and type design. Findings identify a file, line and defect type when possible.

PRFlow uses those signatures to count independent corroboration. Agreement from several reviewers raises confidence in a finding. A single-source finding remains visible for closer human scrutiny.

### Verdict

PRFlow combines checklist results, findings, completed reviewers and configured severity thresholds into an approval-side or rejection verdict. It reports incomplete checklist items and reviewers that did not complete.

## Review and Fix

`review-and-fix` uses the same review process in a correction loop. It evaluates findings and applies justified corrections. It verifies each correction and reviews the result again. The configured default cap is five fix iterations.

Before an approval-side result stands, a shadow pass reviews the diff again without the primary reviewers' conclusions. It can return a missed finding to another iteration. It also reports which planned reviewers completed and any known coverage gaps. No reported gap proves only that PRFlow recorded no known gap, not that every defect was found.

The inline review-and-fix loop reports its result in the session. Run the standalone `review` workflow when you want PRFlow to attempt a formal pull-request review verdict.

## What Independent Review Means

Independent prompts and reviewer contexts reduce shared blind spots. Agreement from several reviewers and a fresh shadow pass can expose an unsupported approval.

They narrow risk. They do not eliminate it. Reviewers can share model limitations, tests can encode the same mistaken assumption as the implementation and production conditions can differ from the repository environment.

Use the review output as structured evidence for human review. Do not treat an `APPROVE` verdict as proof of correctness or as authorization to merge.

## Related Documentation

- [Review Workflow](/docs/workflows/review)
- [Review and Fix Workflow](/docs/workflows/review-and-fix)
- [Human Control](/docs/concepts/human-control)
