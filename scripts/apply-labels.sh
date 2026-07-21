#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# apply-labels.sh <number> <label…> — best-effort apply one or more labels to a
# GitHub issue or PR (a PR is an issue, so the same REST endpoint serves both).
#
# Labels may be passed as separate arguments, as a single comma-separated value,
# or any mix; they are normalized with the same split-on-commas / trim / drop-
# empties idiom the `docs.labels` / `deferred.labels` consumers use. Application
# goes through the REST endpoint
#   POST /repos/{owner}/{repo}/issues/{number}/labels
# via `gh api`, whose `{owner}`/`{repo}` placeholders `gh` fills from the git
# remote on BOTH tiers, WITHOUT the org-scoped GraphQL
# resolution that `gh issue edit`/`gh pr edit --add-label` trigger — so a
# repo-scoped token (GitHub App installation token, or a fine-grained `repo`-only
# PAT, neither of which carries `read:org`) applies labels successfully.
#
# This is the single hardened label-apply path every call site routes through. It
# mirrors ensure-label.sh's best-effort contract: it ALWAYS exits 0 — whether it
# applied the labels, the label set was empty, or the underlying `gh` call failed
# (no auth, offline, rate-limited) — so a label hiccup can never abort the caller.
# It never falls back to porcelain: a failed REST call is logged and tolerated, not
# retried via `gh issue edit`/`gh pr edit`.
#
# It ALWAYS leaves a stderr breadcrumb on EVERY path it can take — naming the target and
# the labels on success as well as on failure (issue #455), and naming the arg-slip on a
# missing/non-numeric number or an empty label set (the #480 review). The success line is what
# makes a HARNESS REFUSAL observable: a permission matcher that denies the command produces
# no output at all, so without a success breadcrumb "applied" and "denied" are byte-identical
# to a caller reading the tool result, and a caller told to "record a failure when the
# stderr names one" has a guard whose comparand is absent precisely in the denial case.
#
# THE HELPER HAS NO SILENT PATH. That is the whole contract, and it is why the callers may
# read "no output at all" as a refusal: applied → the success line; API failure → the warning
# line; a caller arg-slip (no/blank/non-numeric number, or no label content) → its own warning
# line; refused by the harness → nothing at all, the ONLY silent outcome. An earlier revision
# exited silently on an empty label set, which made a caller that passed an empty label literal
# indistinguishable from a denial — and every call site would have fabricated a `dropped-failed`
# reflection blaming a refusal that never happened (CLAUDE.md's "unknown is not zero").
set -uo pipefail

# gh binary: resolved once via the single-source resolver (execution-verified);
# an explicit DEVFLOW_GH still wins, so test stubs are untouched.
# shellcheck source=../lib/resolve-gh.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/resolve-gh.sh"
: "${DEVFLOW_GH:=$(devflow_resolve_gh)}"
# `${1:-}`, NOT `${1:?}`: a `${1:?}` aborts with a bash usage line and rc 1, which breaks the
# "ALWAYS exits 0" best-effort contract above and — worse — leaves the arg-slip guard below
# unreachable on the very shapes it exists to catch (the #480 review).
NUMBER="${1:-}"
[ "$#" -gt 0 ] && shift

# The number must be digits. This is a fail-CLOSED guard on the one caller mistake the skills
# explicitly warn about: a `$PR_NUM` that did not survive into a later command. Both spellings
# of that slip land here, and neither may be silent:
#   * UNQUOTED (`apply-labels.sh $PR_NUM DevFlow`) — the empty expansion word-splits away, so
#     `NUMBER` swallows the LABEL (`apply-labels.sh DevFlow`) and the label set comes out empty.
#   * QUOTED (`apply-labels.sh "$PR_NUM" DevFlow`) — no word-splitting: `NUMBER` is set-but-null
#     and the label survives. (This is why the number is read with `${1:-}` above: `${1:?}` would
#     have aborted here with rc 1 and a raw bash usage line instead of the breadcrumb below.)
# Callers read "no output at all" as a harness refusal, so a silent exit on either shape would
# produce a durable reflection blaming a permission denial that never happened — steering the
# reader away from the real cause (CLAUDE.md's "unknown is not zero"). No label is ever applied
# to issue "" — the helper refuses first. Breadcrumb loudly and exit 0 (best-effort preserved).
case "$NUMBER" in
    ''|*[!0-9]*)
        echo "devflow: warning: apply-labels.sh got a non-numeric issue/PR number '${NUMBER}' (args: $*); no labels applied. This is NOT a harness denial — it is a caller arg-slip, most likely a shell variable that did not survive into this command." >&2
        exit 0 ;;
esac

# Normalize the args into a clean label list — split on commas, trim, drop empties.
# Accepts `DevFlow Retrospective` (separate args), `"DevFlow,Deferred"` (one
# comma-separated arg), or a mix.
#
# BASH BUILTINS ONLY — deliberately not the `tr | sed | grep` pipeline the config-reading
# call sites use. This derivation decides BOTH which labels get POSTed (a selection) AND
# whether the breadcrumb below fires (an emitted result), and CLAUDE.md's guard-class 2 is
# explicit: such a value must not be derived through a non-preflight PATH tool. `lib/preflight.sh`
# guarantees git/gh/jq/python3 — NOT tr/sed/grep. With the pipeline, a host missing `tr`
# silently yields an EMPTY label set, the helper exits 0 printing nothing, and the caller —
# which now reads "no output at all" as a harness denial — records a denial that never
# happened while the label is silently dropped.
LABELS=()
for _raw in "$@"; do
    _rest="$_raw"
    while [ -n "$_rest" ]; do
        case "$_rest" in
            *,*) _part="${_rest%%,*}"; _rest="${_rest#*,}" ;;
            *)   _part="$_rest";       _rest="" ;;
        esac
        # Trim leading/trailing whitespace with parameter expansion (no external tool).
        _part="${_part#"${_part%%[![:space:]]*}"}"
        _part="${_part%"${_part##*[![:space:]]}"}"
        [ -n "$_part" ] && LABELS+=("$_part")
    done
done

# Empty label set → apply nothing (no POST), exit 0, but NEVER silently (the #480 review). This
# mirrors the `[ -n "$CLEAN_LABELS" ]` guard the docs.labels/deferred.labels call sites use —
# except the guard cannot be the caller's alone: the call sites route "no output at all" to a
# `dropped-failed` denial reflection, so a silent exit here is byte-identical to a harness
# refusal and a caller that substitutes an empty label literal (`apply-labels.sh 42 ""`) would
# fabricate a denial that never happened. Naming the empty set is what leaves the helper with
# exactly ONE silent outcome — an actual refusal — which is the comparand every call site's
# guard reads. The set can be empty only when the caller passed no label content: the derivation
# above is BUILTIN-ONLY (a missing PATH tool can no longer empty it, which is what the old
# `tr | sed | grep` derivation risked — a false denial while silently dropping a real label).
if [ "${#LABELS[@]}" -eq 0 ]; then
    echo "devflow: warning: apply-labels.sh got no label content for #${NUMBER} (args: $*); nothing applied. This is NOT a harness denial — the caller passed an empty/whitespace-only label list." >&2
    exit 0
fi

# Build the REST field list — one `labels[]=<name>` field per label, which gh api
# assembles into a JSON `{"labels":[…]}` array body. The field value is passed
# literally (no shell expansion of the label text).
FIELDS=()
for _lbl in "${LABELS[@]}"; do
    FIELDS+=(-f "labels[]=${_lbl}")
done

# Capture stderr only (stdout → /dev/null) so a genuine failure names its cause in
# the breadcrumb without the success-body output polluting it. The `2>&1 >/dev/null`
# order redirects stderr to the captured stream first, then stdout to /dev/null.
ERR_OUT="$("$DEVFLOW_GH" api --method POST "repos/{owner}/{repo}/issues/${NUMBER}/labels" "${FIELDS[@]}" 2>&1 >/dev/null)"
RC=$?

_joined="$(IFS=,; echo "${LABELS[*]}")"
if [ "$RC" -ne 0 ]; then
    # Best-effort: log the specific target + labels + cause, then still exit 0.
    echo "devflow: warning: could not apply label(s) '${_joined}' to #${NUMBER} (best-effort, continuing): ${ERR_OUT}" >&2
else
    # SUCCESS breadcrumb — load-bearing, not chatter (issue #455). Without it this helper
    # is silent on success AND silent when the harness REFUSES the command, so those two
    # outcomes are byte-identical to an agent reading the tool result: "no stderr" cannot
    # mean "applied" and "denied" at once. A caller told to "record a failure when the
    # stderr names one" then has a guard whose comparand is absent in the denial case, and
    # it fails open exactly where a silent denial is the defect being fixed. With this line,
    # the three outcomes are distinguishable: applied → this breadcrumb; API failure → the
    # warning above; refused by the harness → NO output at all.
    echo "devflow: applied label(s) '${_joined}' to #${NUMBER}" >&2
fi

exit 0
