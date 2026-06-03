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
set -uo pipefail

: "${DEVFLOW_GH:=gh}"
NAME="${1:?Usage: ensure-label.sh <name>}"

# Capture both streams so we can distinguish "already exists" (benign) from a
# genuine failure (no auth / network / API error) and emit the right breadcrumb.
ERR_OUT="$("$DEVFLOW_GH" label create "$NAME" --description "Created by DevFlow automation" 2>&1)"
RC=$?

if [ "$RC" -eq 0 ]; then
    echo "devflow: created label '$NAME'" >&2
elif printf '%s' "$ERR_OUT" | grep -qiE 'already exists|already been taken'; then
    echo "devflow: label '$NAME' already exists" >&2
else
    echo "devflow: warning: could not ensure label '$NAME' (best-effort, continuing): ${ERR_OUT}" >&2
fi

exit 0
