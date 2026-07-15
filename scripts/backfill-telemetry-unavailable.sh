#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Re-runnable maintainer migration for issue #499. Legacy record `phases:null`
# may mask a falsy-but-established value; that distinction was already erased,
# and the observed store contained only absent or object workpad telemetry.

set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/lib/resolve-jq.sh" || { echo "::warning::backfill-telemetry-unavailable: could not resolve jq; migration skipped" >&2; exit 0; }
. "$HERE/lib/config-source.sh" 2>/dev/null || { echo "::warning::backfill-telemetry-unavailable: could not source config support; migration skipped" >&2; exit 0; }
. "$HERE/lib/telemetry-branch.sh" 2>/dev/null || { echo "::warning::backfill-telemetry-unavailable: could not source telemetry-branch support; migration skipped" >&2; exit 0; }

root="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null)" || root=""
ref="$(devflow_telemetry_ref 2>/dev/null)" || ref=""
if [ -z "$root" ] || [ -z "$ref" ] || ! git -C "$root" rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then
  echo "::warning::backfill-telemetry-unavailable: telemetry ref is absent or unresolvable; nothing migrated" >&2
  exit 0
fi

stage="$root/.devflow/tmp/telemetry-stage-backfill-$$-${RANDOM}-${SECONDS}"
mkdir -p "$stage" 2>/dev/null || { echo "::warning::backfill-telemetry-unavailable: could not create staging root '$stage'; migration skipped" >&2; exit 0; }
trap 'rm -rf "$stage" 2>/dev/null || true' EXIT
selected=0

while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in */iter-*.json) ;; *) continue ;; esac
  content="$(devflow_telemetry_show_blob "$root" "$ref" "$path")" || { echo "::warning::backfill-telemetry-unavailable: could not read iter blob '$path'; left untouched" >&2; continue; }
  if ! printf '%s' "$content" | "$DEVFLOW_JQ" -e 'type == "object"' >/dev/null 2>&1; then
    echo "::warning::backfill-telemetry-unavailable: iter blob '$path' is malformed or non-object (M7); left byte-verbatim" >&2
    continue
  fi
  printf '%s' "$content" | "$DEVFLOW_JQ" -e 'has("telemetry") and (.telemetry != null)' >/dev/null 2>&1 && continue
  out="$stage/$path"
  mkdir -p "$(dirname "$out")" 2>/dev/null || { echo "::warning::backfill-telemetry-unavailable: could not stage '$path'; skipped" >&2; continue; }
  if printf '%s' "$content" | "$DEVFLOW_JQ" '.telemetry = "unavailable"' > "$out"; then
    selected=$((selected + 1))
  else
    rm -f "$out"; echo "::warning::backfill-telemetry-unavailable: rewrite failed for '$path'; left untouched" >&2
  fi
done < <(devflow_telemetry_list_blobs "$root" "$ref" ".devflow/logs/review/")

while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in .devflow/logs/efficiency/*.json) ;; *) continue ;; esac
  content="$(devflow_telemetry_show_blob "$root" "$ref" "$path")" || { echo "::warning::backfill-telemetry-unavailable: could not read record blob '$path'; left untouched" >&2; continue; }
  if ! printf '%s' "$content" | "$DEVFLOW_JQ" -e 'type == "object"' >/dev/null 2>&1; then
    echo "::warning::backfill-telemetry-unavailable: record blob '$path' is malformed or non-object (R7); left byte-verbatim" >&2; continue
  fi
  telemetry_type="$(printf '%s' "$content" | "$DEVFLOW_JQ" -r '.telemetry | type' 2>/dev/null)" || telemetry_type="unreadable"
  case "$telemetry_type" in null) continue ;; array) ;; *) echo "::warning::backfill-telemetry-unavailable: record blob '$path' has wrong-type telemetry (R4); left byte-verbatim" >&2; continue ;; esac
  if ! printf '%s' "$content" | "$DEVFLOW_JQ" -e 'all(.telemetry[]; type == "object")' >/dev/null 2>&1; then
    echo "::warning::backfill-telemetry-unavailable: record blob '$path' has a non-object telemetry entry (R5); left byte-verbatim" >&2; continue
  fi
  printf '%s' "$content" | "$DEVFLOW_JQ" -e 'any(.telemetry[]; has("phases") and .phases == null)' >/dev/null 2>&1 || continue
  out="$stage/$path"
  mkdir -p "$(dirname "$out")" 2>/dev/null || { echo "::warning::backfill-telemetry-unavailable: could not stage '$path'; skipped" >&2; continue; }
  if printf '%s' "$content" | "$DEVFLOW_JQ" '(.telemetry[] | select(has("phases") and .phases == null) | .phases) = "unavailable"' > "$out"; then
    selected=$((selected + 1))
  else
    rm -f "$out"; echo "::warning::backfill-telemetry-unavailable: rewrite failed for '$path'; left untouched" >&2
  fi
done < <(devflow_telemetry_list_blobs "$root" "$ref" ".devflow/logs/efficiency/")

if [ "$selected" -eq 0 ]; then
  echo "backfill-telemetry-unavailable: no eligible blobs; telemetry store already converged" >&2
  exit 0
fi
rc=0; devflow_telemetry_persist_tree "$root" "$stage" || rc=$?
case "$rc" in
  0) echo "backfill-telemetry-unavailable: migrated $selected blob(s)" >&2 ;;
  2) trap - EXIT; echo "::warning::backfill-telemetry-unavailable: $selected rewrite(s) staged only at '$stage'; CI push operand is unavailable" >&2 ;;
  *) echo "::warning::backfill-telemetry-unavailable: telemetry write degraded (rc=$rc); rerun after resolving the preceding breadcrumb" >&2 ;;
esac
exit 0
