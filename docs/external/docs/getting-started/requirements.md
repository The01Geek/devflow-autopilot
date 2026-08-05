---
title: "Requirements"
description: "Prepare the local tools and GitHub access that PRFlow needs."
---

# Requirements

This page is for anyone preparing a workstation for local PRFlow runs. Cloud runs have a separate [environment and runner setup path](/docs/runs/cloud/setup).

## Required Local Tools

Install one supported coding client and make these tools available on `PATH`:

| **Requirement** | **Why PRFlow Needs It** |
| --- | --- |
| Claude Code, GitHub Copilot CLI or Codex CLI | Loads and runs the PRFlow plugin skills. |
| Git | Reads repository history and manages the feature branch. |
| GitHub CLI (`gh`) | Reads and writes issues, pull requests and reviews. Authenticate it with `gh auth login`. |
| `jq` | Processes JSON used by PRFlow helpers. |
| Python 3.11 or newer, available as `python3` | Runs configuration, workpad and verification helpers. |
| POSIX Bash | Runs PRFlow's shell helpers. `sh`, Dash and PowerShell alone are not substitutes. |

The repository must be a Git repository connected to GitHub. Your GitHub identity needs enough access to read the issue and create branches, issue comments and pull requests.

You can inspect the main versions and authentication state with:

```bash
git --version
gh --version
gh auth status
jq --version
python3 --version
bash --version
```

PRFlow avoids GNU-only command flags, so the standard macOS and BSD command-line tools are supported.

## PyYAML Is Advisory for Local Runs

PyYAML is recommended but is not a hard local prerequisite. Install it with:

```bash
python3 -m pip install PyYAML
```

Without PyYAML, one helper cannot apply severity demotions from deferred-findings blocks in pull-request bodies. The review continues with the findings intact. This can surface and fix more findings than intended, so installing PyYAML avoids unnecessary churn.

The local preflight reports missing PyYAML as an advisory and still succeeds. PyYAML remains required by PRFlow's own test suite, continuous integration and cloud tiers.

## Windows Bash Choices

On Windows, use any one of these POSIX Bash environments:

- Windows Subsystem for Linux (WSL) Bash.
- Git Bash.
- MSYS2 Bash.

PRFlow does not require one specific choice. Set the frozen `DEVFLOW_BASH` environment variable when you need to select the Bash executable explicitly:

```bash
export DEVFLOW_BASH=/path/to/bash
```

A PowerShell-only host with none of these Bash environments cannot run PRFlow's shell helpers. Windows may also expose Python as `python` or `py -3` without a `python3` command. Follow [installation troubleshooting](/docs/troubleshooting/installation) if preflight reports that case.

## Let Initialization Check the Environment

The recommended [`init` skill](/docs/getting-started/initialization) runs the bundled preflight after it scaffolds repository files. Missing tools are reported with remedies. They do not undo the scaffold that was already written.
