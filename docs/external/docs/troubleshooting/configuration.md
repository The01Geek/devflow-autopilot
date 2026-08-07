---
title: "Configuration Problems"
description: "Fix missing, invalid, ignored or not-yet-effective PRFlow settings."
---

Diagnose `.prflow/config.json` when PRFlow cannot read it or a setting does not produce the expected behavior.

## The Workflow Reports `config.json not found`

Confirm that `.prflow/config.json` exists on the repository's default branch and is committed. Run `/prflow:init` or the cloud installer to scaffold it. If your repository ignores the file broadly, add it explicitly and narrow the ignore rule.

## The Workflow Reports Invalid JSON

Validate syntax locally:

```bash
python3 -m json.tool .prflow/config.json
```

Fix the first parse error, then rerun the command. The cloud config reader fails on malformed JSON rather than silently using the full scaffold.

Use `.prflow/config.schema.json` for editor validation of types and accepted values. The runtime still applies setting-specific fallbacks for some missing or invalid leaves.

## A Setting Is Ignored

Check the exact current key name and nesting. Current families begin with `prflow`, such as `prflow_implement` and `prflow_review`. Running `/prflow:init` migrates supported superseded family names and backfills new keys.

Then check the execution tier. Common mismatches include:

- `prflow.allowed_tools` does not apply to implementation.
- `prflow_implement.allowed_tools` does not apply to the general cloud command workflow.
- `prflow_runner` and `workflows.prflow-review` have no effect in a fresh install because the automatic-review files are withdrawn.
- Provider selection is per section.

## A Configuration Change Has Not Taken Effect

Trigger-time security settings are read from a trusted default or base branch. Tool grants, provider routing, commit attribution, runner executable paths and git-environment pins added by a pull request are generally post-merge-only for that pull request's own run.

Merge the configuration change, then start a new run. Do not use a same-pull-request result as evidence that a new permission took effect.

## The Installer Backfilled Unexpected Keys

Re-running the installer or `/prflow:init` adds newly scaffolded keys without replacing existing values or arrays. Review the diff. A new default can expose a feature for discovery without enabling every execution path. Consult [Settings](/docs/configuration/settings) before changing it.
