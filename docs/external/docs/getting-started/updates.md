---
title: "Updates"
description: "Update local plugins and cloud repository automation without mixing the two paths."
---

# Updates

This page is for maintainers updating an existing PRFlow installation. Local plugin updates and cloud repository updates are separate operations.

## Update a Local Plugin

Refresh the marketplace and plugin with the commands supported by your client.

### Claude Code

```bash
claude plugin marketplace update devflow-marketplace
claude plugin update prflow@devflow-marketplace
```

The interactive `/plugin` manager provides equivalent update actions.

### GitHub Copilot CLI

```bash
copilot plugin marketplace update devflow-marketplace
copilot plugin update prflow
```

### Codex CLI

```bash
codex plugin marketplace upgrade devflow-marketplace
```

Start a new client session if the updated skills do not appear. Then run the client-specific form of the [`init` skill](/docs/getting-started/initialization) to backfill new configuration keys, refresh the schema and add any newly shipped prompt-extension examples.

## Update Cloud Repository Files

The default thin cloud installation uses two independently updated artifacts:

- The workflows and composite actions committed in the repository.
- The plugin content fetched at the `prflow_version` ref in `.prflow/config.json`.

Update both sides together. With the installer saved as `devflow-install.sh`, preview the upgrade first, then apply it:

```bash
DEVFLOW_REF=<newer-ref> bash devflow-install.sh
DEVFLOW_REF=<newer-ref> bash devflow-install.sh --apply
```

An upgrade is a dry run by default. The installer does not intentionally change the target repository in this mode. It creates a sandbox copy and can create temporary files. It also executes the downloaded installer, so inspect and verify that file before running it. The preview displays the planned repository diff.

The installer refreshes the workflows and actions. It re-stamps `prflow_version` when the existing value is empty or looks like a commit SHA. A deliberately set tag or branch name is preserved, so advance that value yourself when needed.

A committed-vendor installation created with `DEVFLOW_VENDOR=1` stores the plugin tree in the repository and ignores `prflow_version`. Re-run the installer with the same vendor mode to refresh that tree.

Review and commit the resulting diff. If the installer preserves a modified artifact as a `.prflow-new` sidecar, compare and reconcile it instead of assuming the workflow was updated in place.

Fresh cloud installations maintain `devflow.yml` and `devflow-implement.yml`. Older repositories can retain withdrawn review-tier files; the updater reports them but does not remove them without explicit direction.

See [Cloud Runs](/docs/runs/cloud/index) for the complete setup and update path.
