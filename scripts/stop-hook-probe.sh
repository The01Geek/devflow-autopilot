#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# stop-hook-probe.sh — the Stop-hook half of the issue-#437 harness probe.
#
# Two questions this settles, both by OBSERVATION rather than assertion:
#   AC6 — does a base-branch `.claude/settings.json` Stop hook execute at all when
#         Claude Code runs under `claude-code-action`? (Undocumented; the action wipes
#         `.claude/` and restores it from the BASE branch, so only a hook already on
#         base can answer.) The mere EXISTENCE of the breadcrumb this writes is the
#         measurement — `.github/workflows/matcher-probe.yml`'s `hook-probe` job reads it.
#   AC7 — does the Stop payload's `transcript_path` JSONL carry REAL per-message token
#         counts, or only streaming placeholders? Claude Code's own docs warn the
#         transcript is written asynchronously and may lag, and steer Stop hooks toward
#         `last_assistant_message` instead of parsing it — so this must be established,
#         never assumed. A harness-side cost floor is only possible if these are real.
#
# Reads the Stop hook payload as JSON on stdin (documented fields: session_id,
# transcript_path, cwd, permission_mode, hook_event_name, last_assistant_message —
# https://code.claude.com/docs/en/hooks.md) and writes ONE breadcrumb file:
#     .devflow/tmp/stop-hook-probe-fired      (gitignored; overwritten each Stop)
#
# Contract with the hook-probe workflow job (COUPLED — change both together):
# the job keys on the PRESENCE of `.devflow/tmp/stop-hook-probe-fired`. Renaming this
# path silently turns the AC6 probe into a permanent "did not fire".
#
# token_shape verdict (AC7) — a four-way, unknown-is-never-zero classification:
#   real         — at least one usage figure exceeds 1 (genuine counts are recoverable)
#   placeholder  — usage blocks exist but EVERY figure is 0 or 1 (the reported
#                  streaming-placeholder shape; a cost floor cannot ride these)
#   absent       — the transcript parsed but carries no usage block at all
#   unavailable  — the transcript could not be read/parsed, or no path was supplied.
#                  NEVER collapsed onto `absent` or onto a zero count.
# The verdict DECIDES an emitted result, so it is derived with `jq` (a hard preflight
# prerequisite) and bash builtins only — never `sed`/`tr`/`wc`/`cut`/`head`, whose
# absence would silently empty the value rather than fail (the repo's guard-class 2).
#
# Best-effort and SILENT on stdout: a Stop hook that prints or fails non-zero can
# disrupt the session it is observing. Every failure path writes what it knows,
# breadcrumbs to stderr, and exits 0. It never blocks, never edits the tree, and
# never touches anything outside .devflow/tmp/.

set -uo pipefail

_SHP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Guarded source, mirroring surface-execution-diagnostics.sh: a partial deployment
# without lib/resolve-jq.sh must degrade to bare `jq`, never abort under `set -u`.
# shellcheck source=../lib/resolve-jq.sh
. "$_SHP_DIR/../lib/resolve-jq.sh" \
  || { echo "devflow: resolve-jq.sh could not be sourced from ../lib relative to ${BASH_SOURCE[0]} — using bare 'jq'" >&2; : "${DEVFLOW_JQ:=jq}"; }
[ -n "${DEVFLOW_JQ:-}" ] || DEVFLOW_JQ=jq

# Repo root: prefer the payload's `cwd`, else the git toplevel, else $PWD — matching
# the repo-root-anchoring contract so a hook fired from a subdirectory still writes the
# breadcrumb where the workflow job looks for it.
PAYLOAD="$(cat 2>/dev/null || true)"

_root=""
if [ -n "$PAYLOAD" ]; then
  _root="$("$DEVFLOW_JQ" -r 'if (.cwd | type) == "string" and (.cwd | length) > 0 then .cwd else empty end' <<<"$PAYLOAD" 2>/dev/null || true)"
fi
[ -n "$_root" ] && [ -d "$_root" ] || _root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

MARKER_DIR="$_root/.devflow/tmp"
MARKER="$MARKER_DIR/stop-hook-probe-fired"

if ! mkdir -p "$MARKER_DIR" 2>/dev/null; then
  echo "devflow stop-hook-probe: could not create $MARKER_DIR; breadcrumb not written (the AC6 probe will read this run as 'did not fire')" >&2
  exit 0
fi

# ── AC7: classify the transcript's token shape ───────────────────────────────
TRANSCRIPT=""
if [ -n "$PAYLOAD" ]; then
  TRANSCRIPT="$("$DEVFLOW_JQ" -r 'if (.transcript_path | type) == "string" then .transcript_path else empty end' <<<"$PAYLOAD" 2>/dev/null || true)"
fi

TOKEN_SHAPE="unavailable"
USAGE_BLOCKS="unavailable"
MAX_SEEN="unavailable"

if [ -n "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ]; then
  # One jq pass over the JSONL. `-s` slurps; each line is a message object. We gather
  # every numeric leaf under any `usage` object at any depth (input/output/cache_* alike):
  # a single figure > 1 is sufficient to prove real counts are present, which is exactly
  # the question a harness-side cost floor turns on.
  _shape="$("$DEVFLOW_JQ" -s -r '
      [ .. | objects ] as $objs
      | [ $objs[] | select(has("usage")) | .usage | .. | numbers ] as $n
      # A transcript with NO message objects at all was not meaningfully read — the file is
      # empty, or the async write has not flushed yet (the docs warn the transcript lags the
      # in-memory conversation). That is `unavailable` (never established), NOT `absent`
      # (read, and genuinely carried no tokens). Collapsing the two would report a
      # measurement that never happened as a real negative — the unknown-is-not-zero rule,
      # which is the entire distinction this helper exists to preserve.
      # The real/placeholder boundary is `max > 1` — a deliberate cliff, not an accident.
      # The reported placeholder shape is figures pinned at 0 or 1, so ANY figure above 1 is
      # proof that genuine counts reached the transcript. The residual: a pathological run
      # whose single largest figure is exactly 1 reads as `placeholder`. That is accepted —
      # it is effectively unreachable (a real turn carries hundreds to hundreds of thousands
      # of tokens), and the error direction is the safe one: it under-claims (says the data
      # is unusable) rather than over-claiming a cost floor can be built on it.
      | if ($objs | length) == 0 then "unavailable unavailable unavailable"
        elif ($n | length) == 0 then "absent none none"
        else
          ( if ($n | max) > 1 then "real" else "placeholder" end )
          + " " + ([ $objs[] | select(has("usage")) ] | length | tostring)
          + " " + ($n | max | tostring)
        end
    ' "$TRANSCRIPT" 2>/dev/null || true)"
  # Split with bash builtins only (guard-class 2 — this decides the emitted verdict).
  if [ -n "$_shape" ]; then
    read -r TOKEN_SHAPE USAGE_BLOCKS MAX_SEEN <<<"$_shape"
    [ "$USAGE_BLOCKS" = "none" ] && USAGE_BLOCKS="0"
    [ "$MAX_SEEN" = "none" ] && MAX_SEEN="0"
  else
    echo "devflow stop-hook-probe: transcript '$TRANSCRIPT' could not be parsed; token_shape recorded as 'unavailable' (never 'absent', never 0)" >&2
  fi
elif [ -n "$TRANSCRIPT" ]; then
  echo "devflow stop-hook-probe: transcript_path '$TRANSCRIPT' is not readable; token_shape recorded as 'unavailable'" >&2
else
  echo "devflow stop-hook-probe: no transcript_path in the Stop payload; token_shape recorded as 'unavailable'" >&2
fi

# ── Write the breadcrumb. Presence == AC6 "fired". ───────────────────────────
# Build with jq so the file is always valid JSON (a hand-built string could emit a
# broken literal on an odd value and make the workflow's reader mis-parse a real firing).
if ! "$DEVFLOW_JQ" -n \
      --arg shape "$TOKEN_SHAPE" \
      --arg blocks "$USAGE_BLOCKS" \
      --arg max "$MAX_SEEN" \
      --arg transcript_seen "$([ -n "$TRANSCRIPT" ] && echo yes || echo no)" \
      '{
         fired: true,
         token_shape: $shape,
         usage_blocks: (if $blocks == "unavailable" then null else ($blocks | tonumber? // null) end),
         max_usage_figure: (if $max == "unavailable" then null else ($max | tonumber? // null) end),
         transcript_path_present: ($transcript_seen == "yes")
       }' > "$MARKER" 2>/dev/null; then
  # Fall back to a minimal literal: the PRESENCE of the file is the AC6 measurement,
  # so a failed jq must not cost us the firing observation itself. Everything already
  # ESTABLISHED is reported HONESTLY on this path rather than thrown away — the token
  # shape was classified by the jq pass ABOVE (a different, already-successful call), and
  # `transcript_path_present` is known from a pure-bash variable; neither owes anything to
  # the breadcrumb `jq -n` that just failed. Hardcoding `unavailable`/`null` here would
  # emit facts we can see to be wrong (a gratuitous falsehood in a file whose whole job is
  # honest measurement) and would collapse a real measurement onto the unknown sentinel —
  # the inverse of the unknown-is-not-zero rule, and just as wrong.
  #
  # Every value is re-validated with builtin `case` before interpolation — never a PATH
  # tool (guard-class 2), and fail-closed: an unrecognized shape word degrades to
  # `unavailable` and a non-digit count degrades to `null`, so the literal is always
  # valid JSON no matter what reached these variables.
  case "$TRANSCRIPT" in
    '') _tp=false ;;
    *)  _tp=true ;;
  esac
  case "$TOKEN_SHAPE" in
    real|placeholder|absent|unavailable) _ts="$TOKEN_SHAPE" ;;
    *) _ts=unavailable ;;
  esac
  case "$USAGE_BLOCKS" in
    ''|*[!0-9]*) _ub=null ;;
    *) _ub="$USAGE_BLOCKS" ;;
  esac
  # max_usage_figure accepts a DECIMAL as well as an integer, so the two write paths agree:
  # the primary path builds this value with jq `tonumber`, which happily accepts `1.5`. An
  # integers-only guard here would emit `null` on a float that the primary path emits as a
  # number — a silent divergence between the two paths for the same input. The arms below
  # admit `<digits>` and `<digits>.<digits>` only, so a leading/trailing/duplicate dot (none
  # of which is valid JSON) still fails closed to `null`. (usage_blocks stays integers-only:
  # it is a jq `length`, which cannot be fractional.)
  case "$MAX_SEEN" in
    ''|*[!0-9.]*|*.*.*|.*|*.) _mx=null ;;
    *) _mx="$MAX_SEEN" ;;
  esac
  echo "{\"fired\":true,\"token_shape\":\"${_ts}\",\"usage_blocks\":${_ub},\"max_usage_figure\":${_mx},\"transcript_path_present\":${_tp}}" > "$MARKER" 2>/dev/null \
    || echo "devflow stop-hook-probe: could not write $MARKER" >&2
fi

exit 0
