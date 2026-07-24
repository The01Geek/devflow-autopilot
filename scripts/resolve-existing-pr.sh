#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# resolve-existing-pr.sh — resolve whether `/devflow:implement` Phase 3.1 should ADOPT an
# already-open PR for the current head branch, CREATE a new one, or refuse to decide
# (issue #782, hardening the #755 guard).
#
# Why a helper rather than inline shell in the skill body: this is branch-selecting shell,
# the class CLAUDE.md requires real coverage for — "inline shell that selects a branch is
# extracted into a scripts/*.sh helper so the suite can drive each branch and its arm-order,
# because a grep-pin on a message literal is not coverage of the selection that chooses it."
# scripts/describe-denial-count.sh is the reference extraction. The #755 fix loop found two
# defects in the inline form across two iterations (an inlined branch read that degraded to
# an unfiltered repo-wide query, and a nondeterministic `.[0]` on a multi-PR head); both are
# exactly what a driven arm matrix catches mechanically.
#
# Usage: resolve-existing-pr.sh --issue <number> [--branch <name>] [--base <ref>]
#   --issue   the issue this run implements; used for the closes-issue validation.
#   --branch  the head branch. Omitted → read here via `git branch --show-current`.
#   --base    the run's base branch. Omitted → re-derived via config-get.sh (.base_branch,
#             falling back to `main`), the same read Phase 3.1's create arm performs. The
#             helper derives it internally because a `$BASE` resolved in one skill fence does
#             not survive into a later separate command on the cloud runner.
#
# CONTRACT — exactly one token line on stdout, with a matching exit code:
#
#   ADOPT <n> OK                  exit 0   an open PR was resolved AND both checks passed
#   ADOPT <n> WARN:<checks>       exit 0   resolved, but <checks> (a comma-separated subset
#                                          of `closes-issue`,`base-ref`, in that order)
#                                          did not hold — adoption still proceeds, this is a
#                                          visibility obligation, not a stop
#   CREATE                        exit 2   the query ran cleanly and found no open PR
#   REFUSED                       exit 3   the answer could not be established
#
# The 0 / 2 / 3 split mirrors the repo's established shape: `workpad.py id` uses 0 = found,
# 2 = scanned cleanly but absent, and `preflight.py` uses 3 = the measurement could not be
# established. Collapsing REFUSED onto CREATE is the fail-open this helper exists to prevent
# — creating on an unresolved query risks a second PR duplicating a prior attempt's, and
# adopting is impossible — so an unresolvable outcome is never reported as a clean "none".
#
# THE HELPER HAS NO SILENT PATH (mirroring apply-labels.sh): every outcome, and every cause
# within the shared REFUSED outcome, leaves its own stderr breadcrumb. That is what lets the
# caller read "no output at all" as a harness refusal rather than as an answer.
set -uo pipefail

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# gh binary: resolved once via the single-source execution-verified resolver; an explicit
# DEVFLOW_GH still wins with no probe, so the test suite's stubbing contract is preserved.
# shellcheck source=../lib/resolve-gh.sh
. "$_DIR/../lib/resolve-gh.sh"
: "${DEVFLOW_GH:=$(devflow_resolve_gh)}"

ISSUE=""; BRANCH=""; BASE=""; BRANCH_SET=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --issue)  ISSUE="${2:-}"; shift 2 ;;
        --branch) BRANCH="${2:-}"; BRANCH_SET=1; shift 2 ;;
        --base)   BASE="${2:-}"; shift 2 ;;
        *)
            echo "devflow: resolve-existing-pr.sh: unrecognized argument '$1'; refusing to guess" >&2
            printf '%s\n' REFUSED
            exit 3 ;;
    esac
done

# The issue number gates the closes-issue validation, so an absent or non-numeric one leaves
# that check unestablished. CLAUDE.md's "unknown is not zero": report REFUSED rather than
# adopting with a validation silently downgraded to "passed".
case "$ISSUE" in
    ''|*[!0-9]*)
        echo "devflow: resolve-existing-pr.sh: --issue must be a number (got '$ISSUE'); the closes-issue validation cannot be established" >&2
        printf '%s\n' REFUSED
        exit 3 ;;
esac

# Read the branch in its OWN statement when the caller did not supply one. An inner
# `$(git branch --show-current)` inside the query's `--head` would hide its own failure from
# the outer `||` (only gh's status reaches it), and git prints EMPTY on a detached HEAD, a
# broken worktree, or git < 2.22.
if [ -z "$BRANCH_SET" ]; then
    BRANCH="$(git branch --show-current 2>/dev/null)" || BRANCH=""
fi

# FAIL-CLOSED, and the reason this guard is not merely tidiness: `gh pr list --head ""` is not
# a narrower query, it is an UNFILTERED repo-wide open-PR listing that exits 0 — so a helper
# that let an empty branch through would adopt an arbitrary unrelated PR on some other branch.
# The query must never be reached with an empty branch name.
if [ -z "$BRANCH" ]; then
    echo "devflow: resolve-existing-pr.sh: the branch name is empty (detached HEAD, a broken worktree, or git < 2.22); NOT querying — an empty --head degrades to an unfiltered repo-wide listing" >&2
    printf '%s\n' REFUSED
    exit 3
fi

# Re-derive the base when the caller did not pass one. config-get.sh prints its supplied
# default on the SOFT paths (absent file / absent-or-empty key) and nothing on the HARD ones
# (malformed config, missing python3), so the empty-read fallback covers only the latter —
# behaviorally identical to the fallback Phase 1.4 and Phase 3.1's create arm perform.
if [ -z "$BASE" ]; then
    BASE="$("$_DIR/config-get.sh" .base_branch main)" || BASE=""
    if [ -z "$BASE" ]; then
        echo "devflow: resolve-existing-pr.sh: base_branch read failed (malformed config or missing python3); falling back to 'main' for the base-ref validation" >&2
        BASE=main
    fi
fi

# OPEN-SCOPED and branch-explicit, deliberately NOT `gh pr view`: that command takes no
# --state filter and resolves "the pull request that belongs to the current branch" across
# OPEN/CLOSED/MERGED, so a branch whose only PR was CLOSED would yield a non-empty capture,
# the create would be skipped, and every downstream consumer (the workpad PR link, the
# DevFlow label, the description, the publish step) would run against a closed PR while the
# run has no live PR at all.
#
# gh's own stderr is CAPTURED rather than discarded, and the two REFUSED causes below are
# reported separately: "gh exited non-zero (here is why)" and "gh exited 0 but printed
# nothing" are different diagnoses, and a shared generic breadcrumb would point a reader at
# the wrong one (the misdirected-breadcrumb class). The `2>` redirect targets a file rather
# than a `2>&1` merge so the JSON capture stays uncontaminated by the diagnostic bytes.
GH_ERR="$(mktemp)" || GH_ERR=/dev/null
if ! PR_JSON="$("$DEVFLOW_GH" pr list --head "$BRANCH" --state open --json number,createdAt,baseRefName,closingIssuesReferences 2>"$GH_ERR")"; then
    echo "devflow: resolve-existing-pr.sh: 'gh pr list' exited non-zero for branch '$BRANCH'; could not establish whether an open PR exists: $(cat "$GH_ERR" 2>/dev/null)" >&2
    [ "$GH_ERR" = /dev/null ] || rm -f "$GH_ERR"
    printf '%s\n' REFUSED
    exit 3
fi
[ "$GH_ERR" = /dev/null ] || rm -f "$GH_ERR"
if [ -z "$PR_JSON" ]; then
    echo "devflow: resolve-existing-pr.sh: 'gh pr list' exited 0 but printed nothing for branch '$BRANCH' (an empty listing is spelled '[]', never empty output); could not establish whether an open PR exists" >&2
    printf '%s\n' REFUSED
    exit 3
fi

# Selection is deterministic: `gh pr list` documents no stable array order, so a head carrying
# two open PRs (a reopened prior attempt, a stacked PR) would make a bare `.[0]` return
# whichever the API happened to list first. Sort by createdAt and take the newest, exactly as
# phase-1-setup.md §1.4's resume pre-check does.
#
# The filter emits ONE line — either the sentinel `NONE` or `<number> <baseRefName> <yes|no>`.
# A sentinel rather than empty output is load-bearing: an empty line would be ambiguous
# between "no open PR" (a clean CREATE) and "the filter failed" (a REFUSED), and collapsing
# those two is the same fail-open the REFUSED/CREATE split exists to prevent.
# jq goes through run-jq.sh, never a bare `jq` (the #247 execution-verified-resolver rule).
PR_LINE="$(printf '%s' "$PR_JSON" | "$_DIR/run-jq.sh" -r --arg iss "$ISSUE" '
    [ .[] ] | sort_by(.createdAt) | last
    | if . == null then "NONE"
      else "\(.number) \(.baseRefName // "") \(
             ((.closingIssuesReferences // []) | map(.number | tostring) | index($iss))
             | if . == null then "no" else "yes" end)"
      end' 2>/dev/null)" || PR_LINE=""

if [ -z "$PR_LINE" ]; then
    echo "devflow: resolve-existing-pr.sh: the open-PR listing for branch '$BRANCH' could not be parsed (jq failed or produced no line); could not establish whether an open PR exists" >&2
    printf '%s\n' REFUSED
    exit 3
fi
if [ "$PR_LINE" = NONE ]; then
    echo "devflow: resolve-existing-pr.sh: no open PR on branch '$BRANCH' (queried cleanly); the caller should create one" >&2
    printf '%s\n' CREATE
    exit 2
fi

# Field split via the `read` builtin — never `cut`/`awk`/`tr`. This value decides BOTH which
# PR is adopted (a selection) AND which validation warning is emitted (an emitted result),
# and CLAUDE.md's guard-class 2 forbids deriving either through a tool lib/preflight.sh does
# not guarantee: a host missing that tool would yield an empty field, and the run would adopt
# PR "" or report a clean validation it never performed.
PR_NUMBER=""; PR_BASE=""; PR_CLOSES=""
read -r PR_NUMBER PR_BASE PR_CLOSES <<<"$PR_LINE"
case "$PR_NUMBER" in
    ''|*[!0-9]*)
        echo "devflow: resolve-existing-pr.sh: the selected PR's number is not numeric ('$PR_NUMBER' from '$PR_LINE'); refusing to adopt an unidentified PR" >&2
        printf '%s\n' REFUSED
        exit 3 ;;
esac

# AC1 validation. The #755 guard adopted on head-branch match ALONE, so an unrelated open PR
# sharing the branch — a human's manual PR, a branch-name collision — was adopted silently,
# with no `Resolves #N` line and no comparison against the run's base. Each check that did not
# hold is named individually (the conjunctive both-failed case is the union of the two), so
# the caller's durable warning can say WHICH check failed. Adoption still proceeds: this is a
# visibility obligation, not a new stop.
FAILED=""
[ "$PR_CLOSES" = yes ] || FAILED="closes-issue"
if [ "$PR_BASE" != "$BASE" ]; then
    [ -n "$FAILED" ] && FAILED="$FAILED,base-ref" || FAILED="base-ref"
fi
if [ -n "$FAILED" ]; then
    echo "devflow: resolve-existing-pr.sh: adopting open PR #$PR_NUMBER on branch '$BRANCH', but validation failed ($FAILED): it lists closingIssuesReferences=$PR_CLOSES for issue #$ISSUE and targets base '$PR_BASE' (expected '$BASE')" >&2
    printf '%s\n' "ADOPT $PR_NUMBER WARN:$FAILED"
    exit 0
fi
echo "devflow: resolve-existing-pr.sh: adopting open PR #$PR_NUMBER on branch '$BRANCH' (closes issue #$ISSUE, targets base '$BASE')" >&2
printf '%s\n' "ADOPT $PR_NUMBER OK"
exit 0
