#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# efficiency-trace.sh — render the /devflow:review-and-fix per-run subagent
# effectiveness trace (Markdown) or the per-run JSON record from a run's
# per-iteration workpads, AND deterministically persist those artifacts. All
# derivation lives in lib/efficiency-trace.jq; this wrapper validates inputs,
# reads the gating config, and dispatches jq.
#
# Usage:
#   bash lib/efficiency-trace.sh --workpad-dir DIR --slug SLUG --mode {trace|record}
#   bash lib/efficiency-trace.sh --self-check --workpad-dir DIR --slug SLUG
#   bash lib/efficiency-trace.sh --persist [--workpad-dir DIR --slug SLUG]
#
# Args:
#   --workpad-dir DIR   directory holding the run's iter-<N>.json workpads
#                       (e.g. .devflow/tmp/review/<slug>/<run-id>/).
#   --slug SLUG         the run slug (pr-<N> or sanitized branch name).
#   --mode trace        emit the rendered Markdown trace to stdout.
#   --mode record       emit the per-run JSON record to stdout.
#   --self-check        Layer 2 backstop: warn (never write, never fail) when a
#                       converged writable run left no iter-*.json workpad or no
#                       persisted effectiveness record. Run-id is the basename of
#                       --workpad-dir. Silent when telemetry is disabled.
#   --persist           Layer 3 backstop: derive the per-run record AND commit it
#                       + the durable workpad copy from whatever iter-*.json
#                       workpads exist on disk, in one scoped `chore:` commit.
#                       Idempotent: a no-op (no empty commit) once the record is
#                       already persisted. With --workpad-dir/--slug it persists
#                       just that run; without them it DISCOVERS every run under
#                       .devflow/tmp/review/<slug>/<run-id>/ and persists each.
#
# Gating: when devflow_review_and_fix.efficiency_telemetry_enabled is false,
# --mode and --self-check emit NOTHING and exit 0, and --persist derives no
# record (the durable workpad copy is not telemetry-gated — it runs on every
# writable run, mirroring the SKILL.md Loop Exit split).
#
# Best-effort: a missing dir, zero readable workpads, or an unreadable workpad
# never aborts — every mode degrades gracefully and --persist/--self-check
# always exit 0. The caller (SKILL.md Loop Exit, the Stop hook, the cloud
# wrapper) must itself stay non-fatal.
#
# Environment:
#   DEVFLOW_CONFIG_FILE  override the config path (used by tests).

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=lib/config-source.sh
. "$HERE/config-source.sh"

WORKPAD_DIR=""
SLUG=""
MODE=""
ACTION=""   # "" → use --mode (trace|record); "persist"; "self-check"

while [ $# -gt 0 ]; do
  case "$1" in
    --workpad-dir) WORKPAD_DIR="$2"; shift 2 ;;
    --slug)        SLUG="$2";        shift 2 ;;
    --mode)        MODE="$2";        shift 2 ;;
    --persist)     ACTION="persist";    shift ;;
    --self-check)  ACTION="self-check"; shift ;;
    *) echo "efficiency-trace.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

# ── Gating flag (on by default). ─────────────────────────────────────────────
ENABLED="$(devflow_conf '.devflow_review_and_fix.efficiency_telemetry_enabled' 'true')"

THRESHOLD="$(devflow_conf '.devflow_review_and_fix.efficiency_cut_candidate_min_dispatch' 3)"
# Guard: a non-numeric / empty operator-supplied value must not make --argjson
# abort jq (and the script under set -e) — fall back to the documented default.
# Also clamp values below the schema's `minimum: 1` (e.g. 0) to the default, so
# the persisted record never carries a value config.schema.json forbids.
case "$THRESHOLD" in
  ''|*[!0-9]*) THRESHOLD=3 ;;
esac
[ "$THRESHOLD" -lt 1 ] && THRESHOLD=3

# ── Derivation helpers (shared by --mode and --persist) ──────────────────────

# Populate the VALID_FILES global with the readable iter-*.json OBJECTS in $1.
# Skips unreadable / non-object files (best-effort), logging a ::warning:: each.
collect_valid_files() {
  local dir="$1" f
  VALID_FILES=()
  if [ -n "$dir" ] && [ -d "$dir" ]; then
    for f in "$dir"/iter-*.json; do
      [ -e "$f" ] || continue                       # no glob match → skip
      # Require a JSON OBJECT, not merely well-formed JSON: the filter indexes the
      # workpad as an object (.phase3_findings etc.), so a valid-but-non-object
      # file (stray array/number/string from a partial write) would crash jq and
      # abort the wrapper under set -e. Skip it instead, honoring best-effort.
      if jq -e 'type == "object"' "$f" >/dev/null 2>&1; then
        VALID_FILES+=("$f")
      else
        echo "::warning::efficiency-trace.sh: skipping unreadable/malformed workpad '$f'" >&2
      fi
    done
  fi
}

# Warn (don't fail) if the collected workpads carry mixed run-level `source`
# values — a run should be single-source (see the long rationale this mirrors).
warn_on_mixed_source() {
  [ "${#VALID_FILES[@]}" -gt 1 ] || return 0
  # No `2>/dev/null`: VALID_FILES already passed the `type == "object"` gate, so
  # this jq cannot fail on malformed input — suppressing its stderr would only hide
  # a genuine jq malfunction. Only a STRING `.source` is a real label; a non-string
  # (array/number/bool from a malformed write) is bucketed as the default, mirroring
  # verdict_for's `== "review"` gate — otherwise its JSON rendering would inflate the
  # distinct count into a false-positive "mixed source" warning.
  if [ "$(jq -r 'if (.source | type) == "string" then .source else "review-and-fix" end' "${VALID_FILES[@]}" | sort -u | wc -l)" -gt 1 ]; then
    echo "::warning::efficiency-trace.sh: workpads carry mixed 'source' values; record collapses to the first non-null (a run should be single-source)" >&2
  fi
}

# Run the jq derivation over VALID_FILES for $1 mode ("trace"|"record") and the
# slug $2, to stdout. A fresh GENERATED_AT is stamped per call.
emit_jq() {
  local mode="$1" slug="$2" generated_at
  generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # jq -s over zero files yields null, not []; feed an explicit empty array so the
  # filter (which expects an array) degrades to an empty trace / empty record.
  if [ "${#VALID_FILES[@]}" -eq 0 ]; then
    printf '[]\n' | jq --raw-output -f "$HERE/efficiency-trace.jq" \
      --arg mode "$mode" --arg slug "$slug" \
      --arg generated_at "$generated_at" \
      --argjson cut_candidate_min_dispatch "$THRESHOLD"
  else
    jq --raw-output --slurp -f "$HERE/efficiency-trace.jq" \
      --arg mode "$mode" --arg slug "$slug" \
      --arg generated_at "$generated_at" \
      --argjson cut_candidate_min_dispatch "$THRESHOLD" \
      "${VALID_FILES[@]}"
  fi
}

# Repo root (for the .devflow/logs/ destinations and the commit). Falls back to
# cwd when not in a git tree — the durable/record writes still land relative to
# it, and a non-repo commit simply fails best-effort with a breadcrumb.
repo_root() { git rev-parse --show-toplevel 2>/dev/null || pwd; }

# ── --self-check (Layer 2): warn-only, never writes, never fails ─────────────
do_self_check() {
  # Silent when telemetry is disabled — there is no record to expect, so a
  # missing one is correct, not a gap. (Read-only runs are silent by caller
  # construction: SKILL.md only invokes the self-check on writable runs.)
  [ "$ENABLED" = "true" ] || return 0
  if [ -z "$WORKPAD_DIR" ] || [ -z "$SLUG" ]; then
    echo "::warning::efficiency-trace.sh --self-check requires --workpad-dir and --slug" >&2
    return 0
  fi
  local run_id root record
  run_id="$(basename "$WORKPAD_DIR")"
  root="$(repo_root)"
  # No iter-*.json workpad at all → per-iteration telemetry was never captured.
  if [ ! -d "$WORKPAD_DIR" ] || ! compgen -G "$WORKPAD_DIR"/iter-*.json >/dev/null 2>&1; then
    echo "::warning::devflow review-and-fix self-check: NO iter-*.json workpad was written for run ${SLUG}/${run_id} — per-iteration effectiveness telemetry was not captured this run; there is nothing to persist." >&2
    return 0
  fi
  # Workpads exist but the effectiveness record was not persisted.
  record="${root}/.devflow/logs/efficiency/${SLUG}-${run_id}.json"
  if [ ! -e "$record" ]; then
    echo "::warning::devflow review-and-fix self-check: effectiveness record '.devflow/logs/efficiency/${SLUG}-${run_id}.json' was NOT persisted for run ${SLUG}/${run_id} — recover it with 'lib/efficiency-trace.sh --persist'." >&2
  fi
  return 0
}

# ── --persist (Layer 3): derive + durable-copy + one scoped chore: commit ────

# Persist one run dir's artifacts (best-effort). Sets the global PERSIST_ROOT so
# the single commit at the end is scoped correctly. Returns 0 always.
persist_one() {
  local dir="$1" slug="$2" run_id="$3" root="$4"
  local newest src durable record out cp_err
  # A run dir with no iter-*.json is nothing to persist.
  compgen -G "$dir"/iter-*.json >/dev/null 2>&1 || return 0
  # Skip standalone /devflow:review runs — they have their own Phase 4.5 record
  # path and are out of scope for this review-and-fix backstop. A malformed
  # newest workpad defaults to the historical producer (never "review").
  newest="$(ls -1 "$dir"/iter-*.json 2>/dev/null | sort | tail -1)"
  src="$(jq -r 'if (.source | type) == "string" then .source else "review-and-fix" end' "$newest" 2>/dev/null || echo "review-and-fix")"
  [ "$src" = "review" ] && return 0

  # Durable workpad copy — NOT telemetry-gated (runs on every writable run).
  # Copies every *.json in the run dir (iter-*.json + deferrals.json), mirroring
  # the SKILL.md Loop Exit durable-copy. Content-idempotent: cp overwrites with
  # identical bytes, so git sees a delta only for genuinely new/changed workpads.
  durable="${root}/.devflow/logs/review/${slug}/${run_id}"
  if ! cp_err="$( { mkdir -p "$durable" && cp -p "$dir"/*.json "$durable"/; } 2>&1 )"; then
    echo "::warning::efficiency-trace.sh --persist: durable workpad copy failed (${dir} -> ${durable}): ${cp_err:-unknown}; best-effort, continuing" >&2
  fi

  # Effectiveness record — telemetry-gated, presence-based idempotency. Never
  # re-derive an existing record: its `generated_at` is stamped at derivation
  # time, so re-deriving would churn the bytes and defeat the no-op-on-re-run
  # contract. An existing file (written by the agent's Loop Exit or a prior
  # --persist) is left untouched.
  if [ "$ENABLED" = "true" ]; then
    record="${root}/.devflow/logs/efficiency/${slug}-${run_id}.json"
    if [ ! -e "$record" ]; then
      collect_valid_files "$dir"
      out="$(emit_jq record "$slug")"
      # emit_jq prints nothing for zero readable iterations (catastrophic case),
      # matching the flag-off contract — only a non-empty derivation is written.
      if [ -n "$out" ]; then
        if mkdir -p "$(dirname "$record")" 2>/dev/null; then
          printf '%s\n' "$out" > "$record"
        else
          echo "::warning::efficiency-trace.sh --persist: could not create $(dirname "$record"); record not written for ${slug}/${run_id}" >&2
        fi
      fi
    fi
  fi
  return 0
}

do_persist() {
  local root dir slug run_id parent
  root="$(repo_root)"
  if [ -n "$WORKPAD_DIR" ]; then
    # Targeted: persist exactly the given run. Slug from --slug, else the parent
    # dir name; run-id is the workpad-dir basename.
    run_id="$(basename "$WORKPAD_DIR")"
    if [ -n "$SLUG" ]; then
      slug="$SLUG"
    else
      slug="$(basename "$(dirname "$WORKPAD_DIR")")"
    fi
    persist_one "$WORKPAD_DIR" "$slug" "$run_id" "$root"
  else
    # Discovery: every .devflow/tmp/review/<slug>/<run-id>/ holding iter-*.json.
    # The trailing slash restricts the glob to directories; an unmatched glob
    # stays literal and the `[ -d ]` guard skips it (no nullglob needed).
    for dir in "$root"/.devflow/tmp/review/*/*/; do
      [ -d "$dir" ] || continue
      dir="${dir%/}"                                # strip trailing slash
      run_id="$(basename "$dir")"
      parent="$(dirname "$dir")"
      slug="$(basename "$parent")"
      persist_one "$dir" "$slug" "$run_id" "$root"
    done
  fi

  # ── One scoped `chore:` commit for everything written above ────────────────
  # Stage ONLY the .devflow/logs/ artifact subtrees, each conditionally on its
  # existence (a single `git add` of a non-existent pathspec aborts atomically).
  # The commit is ALSO pathspec-scoped so the "only .devflow/logs/ artifacts"
  # guarantee holds even if the index was pre-dirty. The diff guard makes a
  # re-run (nothing changed) a clean no-op — no empty commit. Best-effort: a
  # failure leaves a ::warning:: and exits 0.
  # Relative pathspecs resolved against $root via `git -C` (robust regardless of
  # the caller's cwd); existence is checked on the absolute path.
  local add_err
  ADD_PATHS=()
  [ -d "${root}/.devflow/logs/efficiency" ] && ADD_PATHS+=(".devflow/logs/efficiency")
  [ -d "${root}/.devflow/logs/review" ] && ADD_PATHS+=(".devflow/logs/review")
  if [ "${#ADD_PATHS[@]}" -gt 0 ]; then
    if ! add_err="$(git -C "$root" add -- "${ADD_PATHS[@]}" 2>&1)"; then
      echo "::warning::efficiency-trace.sh --persist: staging failed: ${add_err:-unknown}; not persisted this run" >&2
    elif ! git -C "$root" diff --cached --quiet -- "${ADD_PATHS[@]}"; then
      local commit_err
      if ! commit_err="$(git -C "$root" commit -m "chore: persist review-and-fix observability artifacts

Co-Authored-By: Claude <noreply@anthropic.com>" -- "${ADD_PATHS[@]}" 2>&1)"; then
        echo "::warning::efficiency-trace.sh --persist: commit failed: ${commit_err:-unknown}; artifacts left staged" >&2
      fi
    fi
  fi
  return 0
}

# ── Dispatch ─────────────────────────────────────────────────────────────────
case "$ACTION" in
  self-check) do_self_check; exit 0 ;;
  persist)    do_persist;    exit 0 ;;
esac

# Default action: --mode trace|record (unchanged contract).
if [ "$MODE" != "trace" ] && [ "$MODE" != "record" ]; then
  echo "efficiency-trace.sh: --mode must be 'trace' or 'record' (or pass --persist / --self-check)" >&2
  exit 2
fi

# Flag off → emit nothing, exit 0 (so a caller writing the record to a file
# produces no file under .devflow/logs/).
if [ "$ENABLED" != "true" ]; then
  exit 0
fi

collect_valid_files "$WORKPAD_DIR"
warn_on_mixed_source
emit_jq "$MODE" "$SLUG"
