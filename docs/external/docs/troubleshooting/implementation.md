---
title: "Implementation Problems"
description: "Recover from issue blockers, branch-state refusals, capability limits and interrupted implementation."
---

# Implementation Problems

This page is for users whose `/prflow:implement` run stops before producing a complete pull request.

## A Declared Issue Dependency Is Still Open

PRFlow reads dependency declarations such as `depends on #123`, `blocked by #123` and `must merge after #123`. An open declared prerequisite blocks implementation.

Confirm that the dependency direction in the issue is correct. Close or merge the prerequisite, or correct the issue text if it described the inverse relationship. Then rerun implementation.

If PRFlow reports that a dependency could not be resolved, check GitHub authentication and repository access before retrying. An unreadable dependency does not count as closed.

## The Branch-State Preflight Refuses to Continue

Implementation checks commits on the feature branch that are not in the base branch before adopting it. A refusal means the run could not prove that the existing commits belong to the issue's prior work.

Check the workpad's branch and pull-request links. Confirm that the expected remote branch still exists and points at the intended commits. Do not bypass the guard by discarding unknown commits. Reconcile or publish the branch deliberately, then rerun.

## Every Required Change Is Under `.github/workflows/`

The built-in `GITHUB_TOKEN` cannot push workflow-file changes. When every acceptance criterion requires that capability, cloud implementation stops Blocked instead of opening an empty pull request.

Run the issue with a human credential or configure the optional GitHub App with both `Contents: write` and `Workflows: write`. If only some work is workflow-bound, PRFlow can defer that subset and continue with an independently shippable remainder.

## A Verification Command Is Blocked

Add the required leading command and arguments to `prflow_implement.allowed_tools` in a prior merged change. Provision the tool in `setup` as needed. Do not rely on `prflow.allowed_tools`; the two paths do not inherit from each other.

## The Run Stopped Midway

Open the dedicated workpad and use its branch and pull-request links. Reissue the original implementation comment after correcting the cause. The new run reuses the workpad and adopts pushed checkpoints when available.

A run interrupted before its first branch checkpoint can have no recoverable code. A cancelled run is terminal and is not automatically resumed. See [Cloud Recovery](/docs/runs/cloud/recovery).
