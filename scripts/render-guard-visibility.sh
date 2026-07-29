#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# render-guard-visibility.sh — render the PreToolUse shape-guard's per-run
# telemetry (issue #908) into the devflow-review.yml check-run summary, beneath
# the existing `permission_denials_count` line rendered by describe-denial-count.sh
# (which this file does not touch or duplicate).
#
# Usage: render-guard-visibility.sh <GUARD_FIRED> <GUARD_COUNTS_JSON> <DENIED_COMMANDS_JSON>
#   GUARD_FIRED            "true" | "false" | "unavailable"
#   GUARD_COUNTS_JSON      the guard's {"R1":N,...} per-arm object (already unwrapped
#                          from its .arms envelope by the caller), or "unavailable"/empty.
#   DENIED_COMMANDS_JSON   scripts/extract-execution-shape.sh's permission_denials_commands
#                          value verbatim: {"commands":[...],"total":N,"truncated":bool}
#                          or "unavailable".
#
# NEUTRALIZATION (security boundary, not a nicety). extract-execution-shape.sh's own
# docstring discloses that `permission_denials_commands` is the ONE field it does not
# redact — command text rides through verbatim, un-neutralized, with an explicit note
# that "any consumer added later MUST neutralize before rendering." This is that
# consumer. Each command string may carry attacker-influenced bytes (it is the literal
# text of a denied Bash command an untrusted PR attempted), so before it enters the
# check-run summary it is REWRITTEN, not left verbatim:
#   - a backtick is stripped (conceptually mirrors render-grounding-block.sh's
#     strip-don't-escape philosophy for backticks — that file uses bash
#     `${VAR//\`/}`, this one uses jq to keep the parse and the neutralization in one
#     tool) so it cannot close the surrounding ```text fence early;
#   - EVERY literal `:` is followed by an inserted space, so no `::` substring can
#     survive under any input — including an ODD-LENGTH run of colons (e.g. `:::`),
#     which a naive `gsub("::"; ": :")` does NOT close: jq's `gsub` is
#     non-overlapping and scans past each match's original 2-character span, so
#     `:::` -> match `::` at [0,2), replace, then append the untouched trailing `:`
#     verbatim -> `: ::` — a FRESH `::` pair re-forms at the seam (issue #908 review,
#     confirmed by direct execution). Inserting a space after every single colon has
#     no such seam: no two colons are ever left adjacent, for any input;
#   - an embedded newline is flattened to a visible marker so one denied command can
#     never masquerade as multiple summary lines or break out of its list-item.
# All three run through jq (a preflight-guaranteed tool — CLAUDE.md's guard-class 2
# concern is about a value that DECIDES a selection/emission being derived through a
# non-guaranteed PATH tool; jq is guaranteed, so this is not that hazard) rather than
# `tr`/`sed`, keeping one code path (jq) for both the parse and the neutralization.
# Fencing is applied AFTER the strips, never before — an unstripped backtick could
# otherwise close the fence early (same ordering rationale as
# render-grounding-block.sh's own comment on this point).
#
# Always exits 0 — an informational renderer must never fail the review job.

set -u

_RGV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Guarded source (matches extract-execution-shape.sh / surface-execution-diagnostics.sh):
# a partial-copy deployment missing the sibling lib/resolve-jq.sh must degrade to bare
# `jq` with a breadcrumb, never leave DEVFLOW_JQ unbound under `set -u`.
# shellcheck source=../lib/resolve-jq.sh
. "$_RGV_DIR/../lib/resolve-jq.sh" \
  || { echo "devflow: render-guard-visibility.sh: resolve-jq.sh could not be sourced — using bare 'jq' (set DEVFLOW_JQ to override)" >&2; : "${DEVFLOW_JQ:=jq}"; }
if [ -z "${DEVFLOW_JQ:-}" ]; then
  echo "devflow: render-guard-visibility.sh: resolve-jq.sh sourced but did not assign DEVFLOW_JQ — using bare 'jq'" >&2
  DEVFLOW_JQ=jq
fi

GUARD_FIRED="${1:-unavailable}"
GUARD_COUNTS_JSON="${2:-unavailable}"
DENIED_COMMANDS_JSON="${3:-unavailable}"

case "$GUARD_FIRED" in
  true | false) : ;;
  *) GUARD_FIRED=unavailable ;;
esac

echo "### PreToolUse shape-guard visibility (issue #908)"
echo "- guard fired: **${GUARD_FIRED}**"

# An empty object ({} — the guard fired and denied nothing) and "could not parse" are
# DISTINCT claims and must not collapse to the same rendered line: a valid-but-empty
# object is a positively-known zero, never "unavailable". So parse-validity and
# entry-count are read as two separate signals, not inferred from one empty string.
COUNTS_VALID=false
if [ -n "$GUARD_COUNTS_JSON" ] && [ "$GUARD_COUNTS_JSON" != unavailable ]; then
  if "$DEVFLOW_JQ" -e 'type == "object"' <<<"$GUARD_COUNTS_JSON" >/dev/null 2>&1; then
    COUNTS_VALID=true
    COUNTS_LINE=$("$DEVFLOW_JQ" -r 'to_entries | map("\(.key)=\(.value)") | join(" ")' <<<"$GUARD_COUNTS_JSON" 2>/dev/null) || COUNTS_LINE=""
  fi
fi
if [ "$COUNTS_VALID" = true ]; then
  if [ -n "$COUNTS_LINE" ]; then
    echo "- per-arm denial counts: ${COUNTS_LINE}"
  else
    echo "- per-arm denial counts: none (guard fired, zero denials recorded)"
  fi
else
  echo "- per-arm denial counts: unavailable"
fi

echo "- denied commands (neutralized for rendering — backticks stripped, every \`:\` spaced, newlines shown as ⏎ — never the raw text):"

# Parse the denied-commands object. As with the counts block above, parse-validity and
# emptiness are two SEPARATE signals: {"commands":[],...} is a positively-known zero
# (the run denied nothing) and must render distinctly from "malformed" or the literal
# "unavailable" — collapsing all three onto one "unavailable" line would misreport the
# common, healthy "guard fired, denied nothing" case as an instrumentation failure on
# every clean run (issue #908 review). A non-string entry inside .commands is treated
# as malformed (COMMANDS_VALID=false) rather than silently skipped, so a producer-side
# shape violation is never masked as a clean empty render.
COMMANDS_VALID=false
COMMANDS_BLOCK=""
TRUNCATED=false
TOTAL=""
if [ -n "$DENIED_COMMANDS_JSON" ] && [ "$DENIED_COMMANDS_JSON" != unavailable ]; then
  if "$DEVFLOW_JQ" -e '
      (type == "object") and ((.commands? | type) == "array")
      and ((.commands | map(type == "string") | all))
    ' <<<"$DENIED_COMMANDS_JSON" >/dev/null 2>&1; then
    if COMMANDS_BLOCK=$("$DEVFLOW_JQ" -r '
        (.commands[] | gsub("\n"; "⏎") | gsub("`"; "") | gsub("(?<x>:)"; "\(.x) ") | "- " + .)
      ' <<<"$DENIED_COMMANDS_JSON" 2>/dev/null); then
      COMMANDS_VALID=true
      TRUNCATED=$("$DEVFLOW_JQ" -r 'if .truncated == true then "true" else "false" end' <<<"$DENIED_COMMANDS_JSON" 2>/dev/null) || TRUNCATED=false
      TOTAL=$("$DEVFLOW_JQ" -r 'if (.total? | type) == "number" then (.total | tostring) else "" end' <<<"$DENIED_COMMANDS_JSON" 2>/dev/null) || TOTAL=""
    fi
  fi
fi

if [ "$COMMANDS_VALID" = true ]; then
  if [ -n "$COMMANDS_BLOCK" ]; then
    printf '```text\n'
    printf '%s\n' "$COMMANDS_BLOCK"
    printf '```\n'
    if [ "${TRUNCATED:-false}" = "true" ]; then
      # Derive the shown count from what was actually rendered rather than
      # transcribing the producer's cap as a literal — a producer-side cap change
      # would otherwise silently make a hardcoded figure lie here (CLAUDE.md's
      # "prefer generated evidence over exact checked-in numbers"). Counted with a
      # bash builtin read/case loop, not grep — CLAUDE.md guard-class 2: an EMITTED
      # value must not be derived through a non-preflight PATH tool (shadow-review
      # finding, issue #908 review).
      SHOWING=0
      while IFS= read -r _rgv_line; do
        case "$_rgv_line" in
          "- "*) SHOWING=$((SHOWING + 1)) ;;
        esac
      done <<<"$COMMANDS_BLOCK"
      if [ "$SHOWING" -gt 0 ]; then
        echo "_(list truncated — ${TOTAL:-N} total, showing ${SHOWING})_"
      else
        echo "_(list truncated — ${TOTAL:-N} total)_"
      fi
    fi
  else
    echo "  none (guard fired, zero denied commands recorded)"
  fi
else
  echo "  _(unavailable)_"
fi

exit 0
