---
title: "Cloud-run problems"
description: "Diagnose GitHub comment triggers, authorization, setup and verification failures."
---

# Cloud-Run Problems

## A comment did not trigger

Confirm the command is a standalone line, not quoted or fenced. Implementation commands belong on issues; review commands belong on the pull-request conversation tab — a review command typed into the review-submission box or an inline diff-line comment is ignored, because those review events are not subscribed. The commenter must be allowed by the repository configuration.

## Authentication failed

Confirm `CLAUDE_CODE_OAUTH_TOKEN` exists as a repository secret and is available to the workflow's event context. If you configured another provider or a GitHub App, verify its corresponding secret and variable names.

## Setup failed

Inspect the Actions log before the PRFlow phase begins. Check configured Python and Node.js versions, repository install commands and any pinned dependencies.

## A test command was blocked

Cloud tool permissions are explicit. Add the narrow command pattern to every PRFlow execution path that must run it, then review the configuration change before retrying.

## A run stopped midway

Use the single workpad comment to find the last completed phase, correct the cause and start a new run. See [Cloud recovery](/docs/runs/cloud/recovery) for the full sequence.
