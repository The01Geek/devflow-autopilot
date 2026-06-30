#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# ensure-label.sh <name> — idempotently ensure a GitHub label exists.
#
# Creates the label (with a description) when it is absent; treats an
# "already exists" outcome as success. This is a best-effort provenance step:
# it ALWAYS exits 0 — whether it created the label, the label already existed,
# or the underlying `gh` call failed (no auth, offline, rate-limited) — so a
# label hiccup can never abort the caller (create-issue / implement / Stage B /
# init). It still leaves a specific stderr breadcrumb naming which of the three
# happened, so a real failure is visible rather than silently swallowed.
#
# Creation goes through the REST endpoint
#   POST /repos/{owner}/{repo}/labels
# via `gh api`, whose `{owner}`/`{repo}` placeholders `gh` fills from the git
# remote (and $GITHUB_REPOSITORY in cloud) WITHOUT the org-scoped GraphQL
# resolution `gh label create` triggers — so a repo-scoped token (GitHub App
# installation token, or a fine-grained `repo`-only PAT, neither carrying
# `read:org`) creates labels successfully.
set -uo pipefail

: "${DEVFLOW_GH:=gh}"
NAME="${1:?Usage: ensure-label.sh <name>}"

# Capture both streams so we can distinguish "already exists" (benign) from a
# genuine failure (no auth / network / API error) and emit the right breadcrumb.
# An existing label comes back as an HTTP 422 (Validation Failed / already_exists)
# from the REST endpoint rather than `gh label create`'s plain-text message, so the
# benign-outcome match below also accepts the 422/already_exists shapes.
ERR_OUT="$("$DEVFLOW_GH" api --method POST "repos/{owner}/{repo}/labels" -f "name=$NAME" -f "description=Created by DevFlow automation" 2>&1)"
RC=$?

if [ "$RC" -eq 0 ]; then
    echo "devflow: created label '$NAME'" >&2
elif printf '%s' "$ERR_OUT" | grep -qiE 'already exists|already been taken|already_exists|HTTP 422'; then
    echo "devflow: label '$NAME' already exists" >&2
else
    echo "devflow: warning: could not ensure label '$NAME' (best-effort, continuing): ${ERR_OUT}" >&2
fi

exit 0
