---
title: "Cloud-Run Problems"
description: "Diagnose comment authorization, authentication, runners, runtime setup, stale pins and interrupted workflows."
---

# Cloud-Run Problems

This page is for maintainers diagnosing a GitHub Actions run or a comment that did not start one.

## A Comment Did Not Trigger

Confirm all of these conditions:

- The command is the first recognized standalone command in the comment.
- It is not quoted, fenced, indented as code or embedded in prose.
- `/prflow:implement` is on a regular issue, not a pull request.
- `/prflow:review` is on the pull request's **Conversation** tab.
- The comment does not contain `@claude`.
- `workflows.prflow` is true in committed config.

An authorized command normally receives a 🚀 reaction. No reaction usually means parsing or authorization declined before the agent job started.

## The Actor Is Unauthorized

Humans must match `prflow.allowed_users` and have write, maintain or admin repository permission. Bots must match `prflow.allowed_bots`. Check the exact login, including the configured bare bot name.

An API or permission lookup failure declines the run. Fix the gate job's token permissions or transient GitHub access, then retry.

## Model Authentication Fails

On the default route, confirm `CLAUDE_CODE_OAUTH_TOKEN` is present in the workflow's repository or environment secrets. On a provider route, confirm the section names a valid provider and `DEVFLOW_PROVIDER_API_KEY` is present.

A partially routed installation can need both credentials. A fully provider-routed installation can omit OAuth only when every active model-running section is routed.

## The Job Is Queued Indefinitely

Inspect `DEVFLOW_RUNNER`. A JSON label array must match all labels on an online self-hosted runner. GitHub queues an unmatched label set without raising a configuration error.

Confirm the runner is registered, online and eligible for the repository. An invalid JSON array fails earlier with a visible `fromJSON` error.

## Setup Fails Before the Agent Starts

Read the first failing provisioning step. Confirm the runner has bash, `git`, `gh`, `jq`, Python 3.11 or newer and Docker when services require it. Check `setup` values and commands in their documented order.

On self-hosted Windows, preinstall Claude Code and set `setup.claude_code_executable`. If Python exists without the `python3` command, install the supported shim on the runner.

## A Tool Is Installed but Denied

Provisioning and command authorization are separate. Add a narrow tool entry to the active workflow's allowlist. The general cloud-command and implementation allowlists do not inherit from each other. Merge the grant before expecting it in a new run.

## Plugin Vendoring Fails

In thin mode, confirm `prflow_version` is nonempty and resolves to a tag, branch or commit in `The01Geek/prflow`. An empty pin fails loudly to prevent mutable-main drift. A stale pin can also omit a helper required by newer workflow bytes.

Re-run the installer with a current release tag and apply the update so workflow files and the runtime pin move together. If a locally edited workflow was preserved, merge its `.prflow-new` sidecar by hand.

## The Run Stopped Without Finishing

Use the workpad or review-progress comment to distinguish Blocked, Failed, Cancelled and still-interim state. Inspect execution diagnostics for permission denials. Correct the cause before posting the command again.

Implementation retries reuse the workpad and pushed branch checkpoints. Review retries target the current pushed head. See [Cloud Recovery](/docs/runs/cloud/recovery) for the recovery sequence.
