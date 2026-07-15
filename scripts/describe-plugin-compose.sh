#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# describe-plugin-compose.sh — select and render the plugin-compose annotation arm
# (issue #505). The composing step in each claude-code-action call site runs
# resolve-extra-plugins.sh against the trusted-ref .claude/settings.json, splices the
# extras beyond the baked baseline into the action's plugins/plugin_marketplaces
# inputs, and calls THIS helper to render the one workflow annotation the outcome
# earns — so a change to the merge-gating judge's loaded-skill surface is auditable
# per run, never silent.
#
# Why a helper rather than an inline `case` in the workflow YAML: the arm selection
# (failed > degraded > spliced > silent) and each arm's message ARE the
# accurate-diagnosis output the feature exists to produce, so a reordered `case` or a
# typo'd glob would silently mis-select while the workflow "works". Inline shell in
# YAML cannot be unit-tested; here lib/test/run.sh drives every arm and the arm order
# directly (the describe-denial-count.sh extraction convention).
#
# Usage: describe-plugin-compose.sh <read-outcome> <entries-file> [defect]
#   read-outcome  "failed" — the trusted base-ref settings read/materialization failed
#                                (review tier: fetch/git-show error; the helper never ran
#                                against a trusted file).
#                 "ok"     — the read succeeded (the file may be absent, valid, or
#                                degraded; the helper ran, or the file was absent).
#   entries-file  a file listing the entries spliced BEYOND the baked baseline (extra
#                 plugins and extra marketplaces, one per line; may be empty/absent).
#                 Used only by the splice arm, which lists them in a ::notice::.
#   defect        optional free text naming the defect/cause — on the degraded arm the
#                 helper's stderr breadcrumb(s); on the failed arm the materialization
#                 failure cause. Absent on the splice and silent arms.
#
# Arm selection (precedence order — a later arm never shadows an earlier one):
#   1. read-outcome == failed            -> ::warning::  trusted-read-failed
#   2. read-outcome == ok + defect       -> ::warning::  degraded-shape (names the defect)
#   3. read-outcome == ok + entries      -> ::notice::   splice (lists every entry)
#   4. else (ok, no defect, no entries)  -> silent       (absent/clean baseline)
#
# The helper-file-absent (skew) arm is NOT here: it stays INLINE in the composing step
# (grep-pinned by run.sh) because it fires precisely when this helper cannot be invoked
# (a consumer whose pinned devflow_version predates issue #505). Always exits 0 — a
# compose annotation never breaks the run.

set -u

read_outcome="${1:-}"
entries_file="${2:-}"
defect="${3:-}"

# Read the spliced entries (one per line), drop blanks, join with ", " via a bash read
# loop — guard-class 2: the joined value that decides the notice text is not derived
# through tr/sed/wc/cut/head (non-preflight PATH tools). Blank lines are skipped so a
# trailing newline never yields an empty list element.
entries=""
if [ -n "$entries_file" ] && [ -f "$entries_file" ]; then
    first=1
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        if [ "$first" -eq 1 ]; then
            entries="$line"
            first=0
        else
            entries="$entries, $line"
        fi
    done < "$entries_file"
fi

case "$read_outcome" in
    failed)
        # The trusted base-ref read failed before the helper could classify the file —
        # distinct from a degraded file the helper DID read (arm 2). Name the cause if
        # the caller supplied it; either way state that base-declared plugins were not
        # composed this run, so a reviewer is not left wondering why the cloud plugin
        # surface diverged from the settings file.
        if [ -n "$defect" ]; then
            printf '::warning::Could not read the trusted base-ref .claude/settings.json (%s); base-declared plugins were not composed this run — proceeding with the baked baseline.\n' "$defect"
        else
            printf '::warning::Could not read the trusted base-ref .claude/settings.json; base-declared plugins were not composed this run — proceeding with the baked baseline.\n'
        fi
        ;;
    ok)
        if [ -n "$defect" ]; then
            # The helper ran and emitted a breadcrumb: the settings file is present but
            # degraded (invalid JSON, wrong-typed enabledPlugins, ...). Proceed with the
            # baked baseline; name the specific defect so a consumer can fix it.
            printf '::warning::.claude/settings.json is degraded (%s); proceeding with the baked plugin baseline.\n' "$defect"
        elif [ -n "$entries" ]; then
            # The observable-output arm: list every spliced entry beyond the baked
            # baseline so a change to the judge's loaded-skill surface is auditable.
            printf '::notice::Composed plugin/marketplace entries beyond the baked baseline: %s\n' "$entries"
        else
            # Silent-absent baseline: the settings file is absent (the normal consumer
            # case) or valid but declares nothing beyond the baseline. No annotation.
            :
        fi
        ;;
    *)
        # Unknown read-outcome: fail safe to silent rather than emit a misleading
        # annotation. The composing step passes only "failed" or "ok".
        :
        ;;
esac
exit 0
