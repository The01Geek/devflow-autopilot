# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# shellcheck shell=bash
# Sourceable review-and-fix contract module.
# Contract: the caller sets LIB and RESULTS_FILE, defines assert_eq, and sources
# lib/test/module-harness.sh first. The module owns its private fixture and cleanup;
# it never invokes the runner or the full-suite boundary. The inventory in
# review-and-fix-contract.inventory.md maps the extracted coverage to its former
# run.sh locations. Modules may not self-skip.
# The `trap _raf_cleanup EXIT` below relies on a sourcing contract: both callers
# (module-harness.sh and run-module.sh) source this module inside a ( ... )
# subshell, so the trap fires at subshell exit and cannot clobber the runner's
# own EXIT handling. Do not source this module directly in a runner's top-level
# shell without restoring the trap.

# This module deliberately uses the caller's module API only. A caller may point
# DEVFLOW_RAF_CONTRACT_ROOT at a scratch repository copy for mutation evidence;
# the normal focused and full-suite paths default to the repository containing LIB.
RAF_ROOT="${DEVFLOW_RAF_CONTRACT_ROOT:-${LIB%/lib}}"
# #539: review-and-fix is a thin root SKILL.md + skills/review-and-fix/references/*.md
# durable step references. The content contract pins below target the *shipped bundle*
# (root + every reference, reassembled), so RAF_SKILL resolves to a byte-faithful
# concatenation built once per source below — mirroring run.sh's MAXI_BUNDLE. The real
# root file is kept as RAF_SKILL_ROOT for the readability assertion.
RAF_SKILL_ROOT="$RAF_ROOT/skills/review-and-fix/SKILL.md"
RAF_REFS_DIR="$RAF_ROOT/skills/review-and-fix/references"
RAF_RECEIVING_SKILL="$RAF_ROOT/skills/receiving-code-review/SKILL.md"
RAF_REQUESTING_SKILL="$RAF_ROOT/skills/requesting-code-review/SKILL.md"
RAF_EXTENSION="$RAF_ROOT/.devflow/prompt-extensions/review-and-fix.md"
RAF_SCHEMA="$RAF_ROOT/.devflow/config.schema.json"
RAF_EXAMPLE="$RAF_ROOT/.devflow/config.example.json"
RAF_CONFIG_GET="$RAF_ROOT/scripts/config-get.sh"
RAF_INVENTORY="$RAF_ROOT/lib/test/modules/review-and-fix-contract.inventory.md"

_raf_tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/devflow-raf-contract.XXXXXX")" || {
  printf 'could not allocate review-and-fix-contract fixture\n' >&2
  return 1
}
_raf_cleanup() {
  rm -rf "$_raf_tmp_root"
}
trap _raf_cleanup EXIT

# Build the shipped review-and-fix bundle (#539): thin root + every reference, in a
# stable order, into a single .md the content pins grep. Members come from the FIXED
# RAF_EXPECTED_REFS list (this module builds its member list from no glob — unlike run.sh's MAXI_BUNDLE).
# The bundle is assembled through the shared devflow_module_build_bundle helper (#758,
# retiring the last hand-rolled member-by-member loop in any test module — run.sh's own
# monolith `_build_skill_bundle` is deliberately kept, per that helper's own docstring):
# the helper is the deletion/emptiness
# guard, reporting a missing, empty, or unreadable member through the assertion channel as a
# named-per-member RED (fail-closed) — a partial bundle would otherwise turn absence/count
# pins into vacuous passes. The member-count assertion below is a lockstep self-consistency
# check on the RAF_EXPECTED_REFS literal itself (it catches an accidental edit to that list);
# it is NOT the deletion guard.
RAF_SKILL="$_raf_tmp_root/review-and-fix-bundle.md"
RAF_EXPECTED_REFS="convergence.md error-handling.md fix-delta-gate.md fixing.md loop-control.md loop-exit.md pre-fix-gates.md shadow-review.md"
_raf_bundle_members=("$RAF_SKILL_ROOT")
for _rf in $RAF_EXPECTED_REFS; do _raf_bundle_members+=("$RAF_REFS_DIR/$_rf"); done
devflow_module_build_bundle "raf module: review-and-fix-bundle" "$RAF_SKILL" "${_raf_bundle_members[@]}"
# 9 = thin root + 8 references. run.sh's #530 budget block pins the SAME 8-name set in its own
# `RAF_EXPECTED_REFS` variable. Rather than couple the two lists by prose lockstep, both verify
# their set directly against the shipped `references/*.md` directory: run.sh via its per-`_r`
# existence check + `_raf_unexpected` guard, and this module via the shared builder's
# per-member usability RED above (list⊇disk) plus the disk⊇list cross-check below. Neither list
# can silently drift from disk, so the two cannot silently drift from each other. (run.sh's
# MAXI_BUNDLE assembles its bundle via the glob; this module builds from the fixed list, so its
# deletion guard is the builder's per-member RED, not a shrinking glob.)
assert_eq "raf module: bundle assembled all 9 members (thin root + 8 references)" "9" \
  "${#_raf_bundle_members[@]}"
# disk⊇list: an on-disk references/*.md not named in RAF_EXPECTED_REFS (mirrors run.sh's #530
# `_raf_unexpected`). Combined with the list⊇disk per-member check above, this pins the list
# directly to the shipped directory instead of to run.sh's copy by prose lockstep.
_raf_unexpected=""
for _uf in "$RAF_REFS_DIR"/*.md; do
  [ -e "$_uf" ] || continue
  case " $RAF_EXPECTED_REFS " in
    *" ${_uf##*/} "*) : ;;
    *) _raf_unexpected="$_raf_unexpected ${_uf##*/}" ;;
  esac
done
assert_eq "raf module: no references/*.md outside RAF_EXPECTED_REFS (disk⊇list cross-check)" "" "$_raf_unexpected"

# #529: the review engine is a thin root plus gated phase references, so an engine
# contract sentence may live in ANY member of the bundle (the shadow-roster rule
# below now sits in skills/review/phases/phase-3-agents.md, not the root). Pin
# against the whole concatenated surface — root + phases/*.md — exactly as
# lib/test/run.sh pins engine content against its $REVIEW_BUNDLE, so a sentence
# that moves between references does not silently break its pin. Uniqueness (the
# _raf_pin_unique "exactly one" contract) is preserved: the sentence appears once
# across the bundle.
RAF_REVIEW_BUNDLE="$_raf_tmp_root/review-engine-bundle.md"
: > "$RAF_REVIEW_BUNDLE"
cat "$RAF_ROOT/skills/review/SKILL.md" "$RAF_ROOT"/skills/review/phases/*.md \
  >> "$RAF_REVIEW_BUNDLE" 2>/dev/null || :

_raf_pin_count() { # literal file -> occurrence count, unreadable file is zero
  local literal="$1" file="$2" count
  if [ ! -r "$file" ]; then
    printf '0\n'
    return 0
  fi
  count="$(grep -oF -- "$literal" "$file" 2>/dev/null | grep -c .)" || count=0
  printf '%s\n' "${count:-0}"
}

_raf_pin_unique() { # assertion-name literal file
  assert_eq "$1" "1" "$(_raf_pin_count "$2" "$3")"
}

_raf_maxi_clamp() { # raw-value [config-get-status]
  local value="$1" status="${2:-0}"
  if [ "$status" -ne 0 ] || ! printf '%s' "$value" | grep -Eq '^-?[0-9]+$'; then
    printf '5\n'
  elif [ "$value" -lt 1 ]; then
    printf '1\n'
  else
    printf '%s\n' "$value"
  fi
}

# ────────────────────────────────────────────────────────────────────────────
echo "review-and-fix contract: iteration cap and bundle integrity"
# ────────────────────────────────────────────────────────────────────────────
assert_eq "raf module: review-and-fix skill is readable" "yes" \
  "$([ -r "$RAF_SKILL_ROOT" ] && echo yes || echo no)"
assert_eq "raf module: review-and-fix extension is readable" "yes" \
  "$([ -r "$RAF_EXTENSION" ] && echo yes || echo no)"
assert_eq "raf module: coverage inventory is readable" "yes" \
  "$([ -r "$RAF_INVENTORY" ] && echo yes || echo no)"
_raf_pin_unique "raf module: inventory identifies the source baseline" \
  "209b9e6c" "$RAF_INVENTORY"
_raf_pin_unique "raf module: inventory names the iteration-cap extraction" \
  "Iteration cap and configuration resolution" "$RAF_INVENTORY"
_raf_pin_unique "raf module: inventory names the convergence contract" \
  "Convergence, shadow, and re-sweep contracts" "$RAF_INVENTORY"
_raf_pin_unique "raf module: inventory names the telemetry contract" \
  "Telemetry, recovery, and continuation contracts" "$RAF_INVENTORY"

RAF_MAXI_PROP='.properties.devflow_review_and_fix.properties.max_iterations'
assert_eq "raf max_iterations: schema type is integer" "integer" \
  "$(jq -r "$RAF_MAXI_PROP.type" "$RAF_SCHEMA")"
assert_eq "raf max_iterations: schema minimum is one" "1" \
  "$(jq -r "$RAF_MAXI_PROP.minimum" "$RAF_SCHEMA")"
assert_eq "raf max_iterations: schema default is five" "5" \
  "$(jq -r "$RAF_MAXI_PROP.default" "$RAF_SCHEMA")"
assert_eq "raf max_iterations: schema has a non-empty description" "yes" \
  "$(jq -e "$RAF_MAXI_PROP.description | type == \"string\" and (length > 0)" "$RAF_SCHEMA" >/dev/null && echo yes || echo no)"
assert_eq "raf max_iterations: example matches schema default" \
  "$(jq -r "$RAF_MAXI_PROP.default" "$RAF_SCHEMA")" \
  "$(jq -r '.devflow_review_and_fix.max_iterations' "$RAF_EXAMPLE")"
RAF_MAXI_CFG="$_raf_tmp_root/max-iterations.json"
printf '%s' '{"devflow_review_and_fix":{"max_iterations":9}}' > "$RAF_MAXI_CFG"
assert_eq "raf max_iterations: configured integer resolves verbatim" "9" \
  "$("$RAF_CONFIG_GET" .devflow_review_and_fix.max_iterations 5 "$RAF_MAXI_CFG")"
printf '%s' '{"devflow_review_and_fix":{}}' > "$RAF_MAXI_CFG"
assert_eq "raf max_iterations: missing key resolves to default" "5" \
  "$("$RAF_CONFIG_GET" .devflow_review_and_fix.max_iterations 5 "$RAF_MAXI_CFG")"
assert_eq "raf max_iterations: missing config resolves to default" "5" \
  "$("$RAF_CONFIG_GET" .devflow_review_and_fix.max_iterations 5 "$_raf_tmp_root/absent.json")"
printf '%s' '{"devflow_review_and_fix":{"max_iterations":0}}' > "$RAF_MAXI_CFG"
assert_eq "raf max_iterations: resolver preserves below-floor value" "0" \
  "$("$RAF_CONFIG_GET" .devflow_review_and_fix.max_iterations 5 "$RAF_MAXI_CFG")"
printf '%s' '{"devflow_review_and_fix":{"max_iterations":"abc"}}' > "$RAF_MAXI_CFG"
assert_eq "raf max_iterations: resolver preserves non-integer value" "abc" \
  "$("$RAF_CONFIG_GET" .devflow_review_and_fix.max_iterations 5 "$RAF_MAXI_CFG")"
assert_eq "raf max_iterations clamp: valid value is honored" "9" "$(_raf_maxi_clamp 9)"
assert_eq "raf max_iterations clamp: no upper cap" "42" "$(_raf_maxi_clamp 42)"
assert_eq "raf max_iterations clamp: zero floors to one" "1" "$(_raf_maxi_clamp 0)"
assert_eq "raf max_iterations clamp: negative floors to one" "1" "$(_raf_maxi_clamp -3)"
assert_eq "raf max_iterations clamp: non-integer falls back" "5" "$(_raf_maxi_clamp abc)"
assert_eq "raf max_iterations clamp: float falls back" "5" "$(_raf_maxi_clamp 2.5)"
assert_eq "raf max_iterations clamp: empty falls back" "5" "$(_raf_maxi_clamp '')"
assert_eq "raf max_iterations clamp: resolver failure falls back" "5" "$(_raf_maxi_clamp '' 2)"
_raf_pin_unique "raf max_iterations: skill keeps negative-aware integer validation" \
  "'^-?[0-9]+\$'" "$RAF_SKILL"
_raf_pin_unique "raf max_iterations: skill keeps below-floor guard" \
  '"$MAX_ITERS" -lt 1' "$RAF_SKILL"
_raf_pin_unique "raf max_iterations: skill keeps default fallback" "MAX_ITERS=5" "$RAF_SKILL"

# ────────────────────────────────────────────────────────────────────────────
echo "review-and-fix contract: pre-fix gates and guardrails"
# ────────────────────────────────────────────────────────────────────────────
_raf_pin_unique "raf guardrail: scoped staging prohibition" \
  'Never use `git add -A` or `git add .` at the fix-commit step' "$RAF_SKILL"
_raf_pin_unique "raf guardrail: logs-only post-shadow exemption" \
  'a post-shadow commit whose diff touches only `.devflow/logs/**` does not constitute an unreviewed edit' "$RAF_SKILL"
_raf_pin_unique "raf guardrail: non-logs post-shadow edits still gate" \
  'Any commit touching a path outside `.devflow/logs/**` still trips the gate' "$RAF_SKILL"
_raf_pin_unique "raf guardrail: empty diff fails closed" \
  'An empty or errored `git diff` output is NOT exempt' "$RAF_SKILL"
_raf_pin_unique "raf extension: sourceability guard shape" \
  'Guard-class shape 1 — existence-vs-sourceability' "$RAF_EXTENSION"
_raf_pin_unique "raf extension: sourceability checks its outcome" \
  'type <fn> >/dev/null 2>&1' "$RAF_EXTENSION"
_raf_pin_unique "raf extension: PATH tool guard shape" \
  'Guard-class shape 2 — tr-dependence' "$RAF_EXTENSION"
_raf_pin_unique "raf extension: explicit local focused selection" \
  'bash lib/test/run-module.sh review-and-fix-contract' "$RAF_EXTENSION"
_raf_pin_unique "raf extension: focused selection never auto-routes files" \
  'automate changed-file-to-module routing' "$RAF_EXTENSION"
_raf_pin_unique "raf extension: skips cannot certify a clean run" \
  'A nonempty skip tally is not clean.' "$RAF_EXTENSION"

# ────────────────────────────────────────────────────────────────────────────
echo "review-and-fix contract: convergence and verification evidence"
# ────────────────────────────────────────────────────────────────────────────
_raf_pin_unique "raf convergence: park-calibration gate heading" \
  '#### Park-calibration gate (before any APPROVE-family conclusion)' "$RAF_SKILL"
_raf_pin_unique "raf convergence: under-grade finding re-enters the loop" \
  'route the finding back through Step 2.5 → Step 3 as a promoted iteration' "$RAF_SKILL"
_raf_pin_unique "raf convergence: early exit also runs the gate" \
  'on the Step 4.5 early-exit path when non-REJECT' "$RAF_SKILL"
_raf_pin_unique "raf convergence: clean sentinel is mandatory" \
  'park-calibration gate clean: no parked finding matched' "$RAF_SKILL"
_raf_pin_unique "raf convergence: over-grade gate heading" \
  '#### Over-grade calibration gate (before any Decide outcome 2 promotion)' "$RAF_SKILL"
_raf_pin_unique "raf convergence: over-grade never auto-demotes" \
  'flags and requires a recorded technical evaluation; it never auto-demotes' "$RAF_SKILL"
_raf_pin_unique "raf convergence: fix-delta gate is per iteration" \
  'on **every iteration unconditionally**' "$RAF_SKILL"
_raf_pin_unique "raf convergence: fix-delta narrows to current cumulative delta" \
  're-reviews **only the cumulative fix delta of this iteration**' "$RAF_SKILL"
_raf_pin_unique "raf convergence: fix-delta re-dispatch is bounded" \
  'triggers **exactly one bounded re-dispatch**' "$RAF_SKILL"
_raf_pin_unique "raf convergence: no-fix iteration bypasses the delta gate" \
  'skip the gate for that iteration' "$RAF_SKILL"
_raf_pin_unique "raf convergence: early shadow trigger is explicit" \
  'run the early shadow once after iteration 1 regardless of that iteration verdict, gated on engine_self_modifying' "$RAF_SKILL"
_raf_pin_unique "raf convergence: promoted iteration counts against cap" \
  'promoted iteration 2 it spawns DOES count toward the cap' "$RAF_SKILL"
_raf_pin_unique "raf verification: re-sweep is mechanism scoped" \
  'Mechanism-scoped self-authored-claim re-sweep' "$RAF_SKILL"
_raf_pin_unique "raf verification: re-sweep searches identifiers rather than hunks" \
  'identifier-located, not hunk-located' "$RAF_SKILL"
_raf_pin_unique "raf verification: re-sweep finding is explicit" \
  'A comment that still describes the pre-change mechanism is a finding' "$RAF_SKILL"
_raf_pin_unique "raf verification: mutation evidence is required" \
  'the mutation you ran and the pin you observed go RED' "$RAF_SKILL"

# ────────────────────────────────────────────────────────────────────────────
echo "review-and-fix contract: telemetry, recovery, continuation, and prompt composition"
# ────────────────────────────────────────────────────────────────────────────
_raf_pin_unique "raf telemetry: every iteration emits a record" \
  'a non-optional emit on every iteration — including a degraded or hand-run path where the review engine was dispatched directly via `Agent` instead of this Skill' "$RAF_SKILL"
_raf_pin_unique "raf telemetry: write tool is required for records" \
  'using the Write tool, not a shell `>` redirect' "$RAF_SKILL"
_raf_pin_unique "raf telemetry: direct Agent bypass is named" \
  'hand-runs the review engine via direct `Agent` dispatch' "$RAF_SKILL"
_raf_pin_unique "raf continuation: loop role schema persists" \
  '"loop_role": "fix | promoted"' "$RAF_SKILL"
_raf_pin_unique "raf continuation: verification prescription is checked at its source" \
  'verify the prescription against its cited source of truth' "$RAF_SKILL"
_raf_pin_unique "raf continuation: expected handoff writes a pushback" \
  'the source of truth is recorded as a pushback' "$RAF_SKILL"
_raf_pin_unique "raf continuation: recovery uses the full shadow roster" \
  'keeps the full roster regardless of `iterations`' "$RAF_REVIEW_BUNDLE"
_raf_pin_unique "raf prompt composition: exhaustive shadow rule" \
  'Block-presence gate (fail-closed on persistence, not just on value).' "$RAF_SKILL"
_raf_pin_unique "raf prompt composition: unresolved provenance fails closed" \
  'do not infer `"none"` without that live evidence' "$RAF_SKILL"
_raf_pin_unique "raf prompt composition: topic priming stays visible in overview" \
  'Topic-priming is a second, distinct leak channel' "$RAF_ROOT/docs/DEVFLOW_SYSTEM_OVERVIEW.md"
_raf_pin_unique "raf prompt composition: receiving guidance remains coupled" \
  'mutation-check every new test before completion is claimed' "$RAF_RECEIVING_SKILL"
_raf_pin_unique "raf prompt composition: requesting guidance remains coupled" \
  'State the **mutation evidence** for each test you present' "$RAF_REQUESTING_SKILL"
