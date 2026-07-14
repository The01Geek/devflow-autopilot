#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
#
# validate-telemetry-artifact.sh <artifact_dir> <out_staging_root>
#
# The untrusted-input gate for the cross-workflow telemetry relay (issue #489, AC4).
# The trusted telemetry-push job downloads a workflow artifact that was produced by a
# PR-HEAD review run (`.github/workflows/telemetry-push.yml`) — so the artifact is
# PR-author-influenced data reaching a trusted, write-capable execution, and the #404
# invariant ("no PR-controlled artifact reaches a trusted, write-capable execution
# unvalidated") requires it be validated BEFORE any of it is staged for a branch push.
#
# Contract (ALL-OR-NOTHING — the whole artifact is dropped on ANY violation):
#   - Walk <artifact_dir> with bash BUILTINS only (the admit/reject SELECTION never
#     routes through a non-preflight PATH tool per CLAUDE.md's guard-class-2 rule).
#   - Reject the whole artifact (::warning:: naming the reason, exit 1, write NOTHING to
#     <out_staging_root>) if ANY entry is: a symlink; an absolute path; a `..` traversal
#     component; a path not admitted by the allowlist below; a `*.json` that is not a
#     JSON object (malformed JSON included); or if the artifact exceeds the entry-count
#     or total-byte caps.
#   - Admit ONLY (both under `.devflow/logs/`, mirroring the telemetry-branch store layout):
#       .devflow/logs/review/<slug>/<run-id>/<name>.json      (per-iteration workpad copies)
#       .devflow/logs/efficiency/<slug>-<run-id>.json          (derived effectiveness record)
#     where <slug>/<run-id>/<name> are `[A-Za-z0-9._-]+` (and reject a `..`/`.` segment).
#   - On success: populate <out_staging_root> with ONLY the admitted, validated regular
#     files at their `.devflow/logs/…`-relative paths (a fresh tree copied from scratch,
#     so symlinks/traversal cannot survive), exit 0.
#   - Empty OR absent <artifact_dir>: NOT a violation — exit 0 leaving <out_staging_root>
#     empty (the caller then pushes nothing and says so — the intermediate-inert contract).
#
# Caps (override via env; both fail CLOSED — a value that is unset/empty/non-numeric
# falls back to the default rather than disabling the cap):
#   DEVFLOW_TELEMETRY_MAX_ENTRIES  (default 500)
#   DEVFLOW_TELEMETRY_MAX_BYTES    (default 5242880 = 5 MiB)
#
# stdout: nothing on success (the out root IS the result). A single ::warning:: on stderr
# on rejection. Exit 0 = admitted (possibly empty); exit 1 = dropped whole.

set -uo pipefail

ARTIFACT_DIR="${1:-}"
OUT_ROOT="${2:-}"

if [ -z "$ARTIFACT_DIR" ] || [ -z "$OUT_ROOT" ]; then
  echo "::warning::validate-telemetry-artifact: usage: validate-telemetry-artifact.sh <artifact_dir> <out_staging_root>" >&2
  exit 1
fi

# jq is a preflight prerequisite; route through the shared resolver so DEVFLOW_JQ / a
# Windows shim / a test stub is honored. Falling back to bare `jq` keeps the JSON
# type-check running rather than silently skipping it.
# shellcheck source=../lib/resolve-jq.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/resolve-jq.sh" \
  || { echo "::warning::validate-telemetry-artifact: resolve-jq.sh could not be sourced — using bare 'jq' (set DEVFLOW_JQ to override)" >&2; : "${DEVFLOW_JQ:=jq}"; }

# Cap resolution — a non-numeric/empty override fails CLOSED to the default (never off).
_dvt_num() {  # value default -> echoes value if a positive integer, else default
  case "$1" in
    ''|*[!0-9]*) printf '%s\n' "$2" ;;
    *) printf '%s\n' "$1" ;;
  esac
}
MAX_ENTRIES="$(_dvt_num "${DEVFLOW_TELEMETRY_MAX_ENTRIES:-}" 500)"
MAX_BYTES="$(_dvt_num "${DEVFLOW_TELEMETRY_MAX_BYTES:-}" 5242880)"

# Absent artifact dir → inert (exit 0, empty out root). Distinguished from a violation:
# the download step uses if-no-files-found:ignore, so a run with no artifact is normal.
if [ ! -d "$ARTIFACT_DIR" ]; then
  exit 0
fi

reject() {  # reason -> emit one ::warning::, exit 1 (whole artifact dropped)
  echo "::warning::validate-telemetry-artifact: dropping the whole downloaded artifact — $1" >&2
  exit 1
}

# Byte size of a file. This value gates admission (the size cap), so a non-preflight
# derivation must fail CLOSED: `wc -c` output is validated as a bare integer, and an
# empty/non-numeric result (wc absent, unreadable file) returns rc 1 so the caller
# rejects rather than admitting an unsized entry.
_dvt_filesize() {  # path -> echoes byte count (rc 0) or rc 1 if underivable
  local n
  n="$(wc -c < "$1" 2>/dev/null)" || return 1
  n="${n//[[:space:]]/}"   # wc may pad with leading spaces on some platforms
  case "$n" in
    ''|*[!0-9]*) return 1 ;;
    *) printf '%s\n' "$n"; return 0 ;;
  esac
}

# Collect every regular-file entry (and detect symlinks) with a builtin walk. The array
# is NUL-safe (each element is one path), so hostile names with spaces/newlines are
# handled. bash 3.2 aborts on "${arr[@]}" when empty under set -u, so every expansion
# uses the ${arr[@]+"${arr[@]}"} guarded form.
_entries=()
_dvt_walk() {
  local d="$1" e
  for e in "$d"/* "$d"/.[!.]* "$d"/..?*; do
    [ -e "$e" ] || [ -L "$e" ] || continue   # -L so a DANGLING symlink is still seen
    if [ -L "$e" ]; then
      reject "entry '${e#"$ARTIFACT_DIR"/}' is a symlink (symlinks are never admitted)"
    elif [ -d "$e" ]; then
      _dvt_walk "$e"
    elif [ -f "$e" ]; then
      _entries+=("$e")
    else
      reject "entry '${e#"$ARTIFACT_DIR"/}' is neither a regular file nor a directory"
    fi
  done
}
_dvt_walk "$ARTIFACT_DIR"

# Empty artifact → inert (exit 0, empty out root).
if [ "${#_entries[@]}" -eq 0 ]; then
  exit 0
fi

if [ "${#_entries[@]}" -gt "$MAX_ENTRIES" ]; then
  reject "entry count ${#_entries[@]} exceeds the cap of ${MAX_ENTRIES}"
fi

# Path-component safety: reject an absolute path, an empty component, or a `.`/`..`
# component. Operates on the artifact-relative path (rel), which is what would become
# the store-relative path on the branch.
_dvt_path_safe() {  # rel -> rc 0 if safe, 1 otherwise
  local rel="$1" IFS=/ comp
  case "$rel" in /*) return 1 ;; esac        # absolute
  # shellcheck disable=SC2086
  set -- $rel
  for comp in "$@"; do
    case "$comp" in ''|.|..) return 1 ;; esac
  done
  # A leading/trailing/double slash produces an empty positional above; also reject a
  # bare empty rel.
  [ -n "$rel" ] || return 1
  return 0
}

# Path admission allowlist. `slug`, `run-id`, and the review filename are each a single
# `[A-Za-z0-9._-]+` segment; the `.`/`..` segments are already excluded by _dvt_path_safe.
_dvt_admitted() {  # rel -> rc 0 if the path shape is admitted
  local rel="$1"
  local seg='[A-Za-z0-9._-]+'
  if [[ "$rel" =~ ^\.devflow/logs/review/${seg}/${seg}/${seg}\.json$ ]]; then return 0; fi
  if [[ "$rel" =~ ^\.devflow/logs/efficiency/${seg}\.json$ ]]; then return 0; fi
  return 1
}

# Pass 1: validate every entry. Any failure drops the whole artifact (nothing copied).
_total_bytes=0
_admitted_rel=()
for e in ${_entries[@]+"${_entries[@]}"}; do
  rel="${e#"$ARTIFACT_DIR"/}"
  _dvt_path_safe "$rel" || reject "entry '$rel' has an unsafe path (absolute, empty, or a '.'/'..' traversal component)"
  _dvt_admitted "$rel" || reject "entry '$rel' is not an admitted telemetry path (only .devflow/logs/review/<slug>/<run-id>/<name>.json and .devflow/logs/efficiency/<slug>-<run-id>.json)"

  # Size cap (accumulated across all entries). This value gates admission, so _dvt_filesize
  # validates its `wc -c` output as a bare integer and fails CLOSED (rc 1 → reject) when it
  # cannot be derived — an unsized entry is never admitted.
  sz=0
  if ! sz="$(_dvt_filesize "$e")"; then
    reject "entry '$rel' could not be sized (unreadable)"
  fi
  _total_bytes=$((_total_bytes + sz))
  if [ "$_total_bytes" -gt "$MAX_BYTES" ]; then
    reject "total artifact size exceeds the cap of ${MAX_BYTES} bytes"
  fi

  # JSON type-check (every admitted entry is a *.json). Must parse AND be an object;
  # efficiency records must additionally carry the stable identifying keys the producer
  # always emits (schema_version:number, slug:string) — this is the record-shape check.
  if ! "$DEVFLOW_JQ" -e 'type == "object"' "$e" >/dev/null 2>&1; then
    reject "entry '$rel' is not a JSON object (malformed JSON or wrong top-level type)"
  fi
  case "$rel" in
    .devflow/logs/efficiency/*)
      if ! "$DEVFLOW_JQ" -e '(.schema_version | type == "number") and (.slug | type == "string")' "$e" >/dev/null 2>&1; then
        reject "entry '$rel' does not match the efficiency record shape (needs numeric schema_version and string slug)"
      fi ;;
  esac
  _admitted_rel+=("$rel")
done

# Pass 2: nothing violated — copy the admitted files into a fresh out root at their
# store-relative paths. Building the tree from scratch (regular-file copies only) means
# no symlink or odd mode can ride along.
mkdir -p "$OUT_ROOT" || reject "could not create the validated staging root '$OUT_ROOT'"
for rel in ${_admitted_rel[@]+"${_admitted_rel[@]}"}; do
  dest="$OUT_ROOT/$rel"
  mkdir -p "$(dirname "$dest")" || reject "could not create '$rel' parent under the staging root"
  # cp of a validated regular file; -p not used so no odd source mode is preserved.
  cp -- "$ARTIFACT_DIR/$rel" "$dest" || reject "could not copy admitted entry '$rel' into the staging root"
done

exit 0
