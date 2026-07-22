# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# shellcheck shell=bash
# Sourceable harness-python-guards contract module (issue #707).
#
# It carries the driver blocks for the monolith-only Python guards whose subject is
# a single code unit and whose verification is self-contained, so a change scoped to
# one of them is verifiable in seconds with
# `lib/test/run-module.sh harness-python-guards` instead of the complete suite.
#
# Contract: the caller sets LIB and RESULTS_FILE, defines assert_eq, and sources
# lib/test/module-harness.sh first (which defines the namespaced module pin API and
# devflow_run_focused_python_test). This module uses assert_eq plus that shared
# focused-Python-test runner — it references NO monolith helper. The module owns its
# private fixture root and cleanup; it never invokes the runner or the full-suite
# boundary. The inventory in harness-python-guards.inventory.md maps the extracted
# coverage to its former run.sh locations and records the deliberate exclusions.
# Modules may not self-skip.
# The `trap _hpg_cleanup EXIT` below relies on a sourcing contract: both callers
# (module-harness.sh's full-suite boundary and run-module.sh) source this module
# inside a ( ... ) subshell, so the trap fires at subshell exit and cannot clobber
# the runner's own EXIT handling. Do not source this module directly in a runner's
# top-level shell without restoring the trap.

_hpg_tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/devflow-harness-python-guards.XXXXXX")" || {
  printf 'could not allocate harness-python-guards fixture\n' >&2
  return 1
}
_hpg_cleanup() {
  rm -rf "$_hpg_tmp_root"
}
trap _hpg_cleanup EXIT

# ────────────────────────────────────────────────────────────────────────────
echo "#600 create-issue audit-prompt renderer (render-audit-prompt.py)"
# ────────────────────────────────────────────────────────────────────────────
# R1..R12 are unit-driven in lib/test/test_render_audit_prompt.py (renderer over
# mktemp fixture trees + a delivery-equivalence matrix that drives the real
# load-prompt-extension.sh). The two greps below are SOURCE-SHAPE pins that
# backstop test_R9_statelessness (which is the outcome check — it observes that no
# file was written and no stdin was read). A source scan cannot see a write routed
# through subprocess/shutil/os.write or a variable-mode Path.open, so these pins
# catch the obvious reintroduction and R9 catches the behavior.
RAP_ROOT="$(mktemp -d "$_hpg_tmp_root/rap.XXXXXX")"
python3 "$LIB/test/test_render_audit_prompt.py" >"$RAP_ROOT/rap-unit.out" 2>&1
RAP_UNIT_RC=$?
# Surface the captured traceback on failure — otherwise the scratch dir is removed
# below and the only signal left is a bare "expected 0, got 1".
[ "$RAP_UNIT_RC" -eq 0 ] || cat "$RAP_ROOT/rap-unit.out"
assert_eq "#600 render-audit-prompt: focused Python tests pass" "0" "$RAP_UNIT_RC"
assert_eq "#600 render-audit-prompt writes no file (stateless)" "0" \
  "$(grep -cE "open\([^)]*['\"][wax]|\.write_text\(|\.write_bytes\(" "$LIB/../scripts/render-audit-prompt.py" || true)"
assert_eq "#600 render-audit-prompt reads no stdin (stateless)" "0" \
  "$(grep -cE 'sys\.stdin|(^|[^a-zA-Z_])input\(' "$LIB/../scripts/render-audit-prompt.py" || true)"
rm -rf "$RAP_ROOT"

VB_ROOT="$(mktemp -d "$_hpg_tmp_root/vb.XXXXXX")"

# ────────────────────────────────────────────────────────────────────────────
echo "verification-launch baseline analyzer (issue #527, Wave 1)"
# ────────────────────────────────────────────────────────────────────────────
python3 "$LIB/test/test_verification_baseline.py" >"$VB_ROOT/vb-unit.out" 2>&1
assert_eq "verification baseline: focused Python tests pass" "0" "$?"
# The analyzer is offline (AC #527-2: read-only, launches no verification
# command and invokes no repository-provided executable) — no subprocess call
# site in the module. (It imports workflow_flight_recorder, which itself uses
# subprocess for read-only git; the analyzer never calls those functions.)
assert_eq "verification baseline: analyzer invokes no subprocess" "0" \
  "$(grep -cE 'subprocess\.(run|Popen|call|check_output|check_call)' "$LIB/../scripts/verification_baseline.py" || true)"
# Widened evasion sweep (PR #531 review): the dotted-call pin alone is evadable
# by `from subprocess import run`, `subprocess.getoutput`, `os.system`,
# `os.popen`, or `pty.spawn` — none of which it matches. The module legitimately
# imports no subprocess machinery at all, so pin the absence of every spelling.
assert_eq "verification baseline: no subprocess import or shell-out spelling" "0" \
  "$(grep -cE '(^|[^a-zA-Z_])(import subprocess|from subprocess import|os\.system|os\.popen|getoutput|check_output|pty\.spawn|import pty)' "$LIB/../scripts/verification_baseline.py" || true)"
# Registry coupled pins (the test_workflow_flight_recorder registry test asserts
# the 5-workflow set; these pin the #527 additions the analyzer depends on).
assert_eq "verification baseline: registry has the review first-message forms" "1" \
  "$(grep -cF '"/devflow:review", "/review"' "$LIB/../scripts/workflow-flight-recorder-registry.json" || true)"
assert_eq "verification baseline: registry has the cloud_mappings section" "1" \
  "$(grep -cF '"cloud_mappings"' "$LIB/../scripts/workflow-flight-recorder-registry.json" || true)"

rm -rf "$VB_ROOT"

VF_ROOT="$(mktemp -d "$_hpg_tmp_root/vf.XXXXXX")"

# ────────────────────────────────────────────────────────────────────────────
echo "single-flight verification coordination ledger (issue #528, Wave 2)"
# ────────────────────────────────────────────────────────────────────────────
python3 "$LIB/test/test_verification_flight.py" >"$VF_ROOT/vf-unit.out" 2>&1
assert_eq "verification flight: focused Python tests pass" "0" "$?"
# The coordinator is data-only (AC #528-1): it launches no subprocess, spawns no
# shell, and runs no git — it never becomes a shell-command bypass. Pin the
# absence of every subprocess / shell-out / exec spelling.
#
# The spelling list is NOT written here. It is read from the single source of
# truth — BANNED_EXEC_SPELLINGS in lib/test/test_verification_flight.py — so this
# shell sweep and the Python guard cannot drift into disagreeing coverage (the
# earlier hand-copied 10-alternative regex was a strict subset of the Python-side
# list, so each guard certified the contract against the other's blind spot).
# python3 is a hard preflight prerequisite, so deriving the list is safe here.
VF_SRC="$LIB/../scripts/verification-flight.py"
VF_SPELLINGS="$(python3 - "$LIB/test/test_verification_flight.py" <<'VFEOF'
import ast, sys

# Derive ATOMICALLY: collect the whole tuple first, and only then print. A
# print-as-you-go loop fails OPEN on a partial derivation — a tuple element that is
# not a bare string literal (a concatenation, an f-string, a name) raises partway
# through, the elements already printed survive in the caller's variable, and a
# non-empty check waves the truncated list through as if coverage were complete.
# Anything unexpected exits non-zero with an empty stdout instead, so the caller's
# fail-closed check fires.
spellings = []
found = False
tree = ast.parse(open(sys.argv[1], encoding="utf-8").read())
for node in tree.body:
    if isinstance(node, ast.Assign) and any(
        getattr(t, "id", "") == "BANNED_EXEC_SPELLINGS" for t in node.targets
    ):
        found = True
        if not isinstance(node.value, ast.Tuple):
            sys.exit("BANNED_EXEC_SPELLINGS is not a tuple literal")
        for elt in node.value.elts:
            if not (isinstance(elt, ast.Constant) and isinstance(elt.value, str)):
                sys.exit("BANNED_EXEC_SPELLINGS holds a non-string-literal element")
            spellings.append(elt.value)
if not found:
    sys.exit("BANNED_EXEC_SPELLINGS assignment not found")
print("\n".join(spellings))
VFEOF
)"
# Fail closed: an empty derivation would make every membership test below vacuous.
assert_eq "verification flight: banned-spelling list derived from its single source" "yes" \
  "$([ -n "$VF_SPELLINGS" ] && echo yes || echo no)"
# Fail closed on a PARTIAL derivation too: the derived line count must equal the
# tuple's own element count, so a silently-truncated list cannot pass the non-empty
# check above. (Deriving the expected count independently, from a plain literal
# count over the source, keeps this from being a self-referential tautology.)
VF_TUPLE_LEN="$(python3 - "$LIB/test/test_verification_flight.py" <<'VFLEN'
import ast, sys
tree = ast.parse(open(sys.argv[1], encoding="utf-8").read())
for node in tree.body:
    if isinstance(node, ast.Assign) and any(
        getattr(t, "id", "") == "BANNED_EXEC_SPELLINGS" for t in node.targets
    ):
        print(len(node.value.elts))
        break
VFLEN
)"
assert_eq "verification flight: banned-spelling derivation is complete (no partial truncation)" \
  "$VF_TUPLE_LEN" "$(printf '%s\n' "$VF_SPELLINGS" | grep -c .)"
VF_EXEC_HITS=0
while IFS= read -r _vf_spelling; do
  [ -n "$_vf_spelling" ] || continue
  case "$(grep -cF -- "$_vf_spelling" "$VF_SRC" || true)" in
    0) : ;;
    *) VF_EXEC_HITS=$((VF_EXEC_HITS + 1)); echo "  exec-sweep hit: $_vf_spelling" ;;  # RED-path diagnostic only; deliberately NOT the ' NOTE ' skip channel
  esac
done <<VFHITS
$VF_SPELLINGS
VFHITS
assert_eq "verification flight: no subprocess / shell-out / exec spelling" "0" "$VF_EXEC_HITS"
# The exact, exhaustive state set is a coupled invariant with the helper source
# and the docs — pin the full declared membership (the grep literals enforce exact
# content) so a dropped/renamed state goes RED.
assert_eq "verification flight: ALL_STATES declares the active set" "1" "$(grep -cF '"claimed", "running"' "$VF_SRC" || true)"
assert_eq "verification flight: TERMINAL_STATES declares every terminal state" "1" \
  "$(grep -cF '"passed", "failed", "timed_out", "cancelled", "stale", "incomplete"' "$VF_SRC" || true)"

# Coupled grant invariant (issue #528 AC): the vendored-literal helper grant must
# land in BOTH the implement profile (inline Implement review pass) and the light
# manual-comment profile (manual Review-and-Fix), and must NOT be added to the
# read-only reviewer profile (standalone CI-grounded Review creates no flight).
assert_eq "#528 coupled: devflow-implement.yml grants verification-flight.py by vendored path" "1" \
  "$(grep -cF 'Bash(.devflow/vendor/devflow/scripts/verification-flight.py:*)' "$LIB/../.github/workflows/devflow-implement.yml" || true)"
assert_eq "#528 coupled: devflow.yml (manual review listener) grants verification-flight.py by vendored path" "1" \
  "$(grep -cF 'Bash(.devflow/vendor/devflow/scripts/verification-flight.py:*)' "$LIB/../.github/workflows/devflow.yml" || true)"
assert_eq "#528 coupled: devflow-runner.yml (read-only reviewer) grants NO verification-flight flight helper" "0" \
  "$(grep -cF 'verification-flight.py' "$LIB/../.github/workflows/devflow-runner.yml" || true)"

rm -rf "$VF_ROOT"

# ────────────────────────────────────────────────────────────────────────────
echo "receiving-review session artifact producer (issue #668)"
# ────────────────────────────────────────────────────────────────────────────
RI_LIB="$LIB/../scripts/reception_identity.py"
RR_CLI="$LIB/../scripts/reception-record.py"
RECEPTION_OUT="$(python3 "$LIB/test/test_reception_identity.py" 2>&1)"
RECEPTION_RC=$?
assert_eq "reception identity: focused Python tests pass (library + CLI + flight extension)" "0" "$RECEPTION_RC"
[ "$RECEPTION_RC" -eq 0 ] || while IFS= read -r _ri_line || [ -n "$_ri_line" ]; do printf '    %s\n' "$_ri_line"; done <<< "$RECEPTION_OUT"
# The library is an importable, non-executable stdlib-only routine (AC1): no exec bit,
# no PyYAML import, no gh call, no network call.
assert_eq "reception identity: library carries no executable bit" "no" \
  "$([ -x "$RI_LIB" ] && echo yes || echo no)"
assert_eq "reception identity: CLI carries the executable bit" "yes" \
  "$([ -x "$RR_CLI" ] && echo yes || echo no)"
assert_eq "reception identity: library imports no PyYAML" "0" \
  "$(grep -cE '(^|[^a-zA-Z_])(import yaml|from yaml import)' "$RI_LIB" || true)"
assert_eq "reception identity: library makes no gh call" "0" \
  "$(grep -cE '"gh"|\bgh \b' "$RI_LIB" || true)"
# The CLI imports the library rather than re-implementing the derivation (AC2): exactly one
# copy of the identity format ships. Pin the import and the absence of a second write-tree.
assert_eq "reception identity: CLI imports the library (single derivation implementation)" "1" \
  "$(grep -cF 'import reception_identity' "$RR_CLI" || true)"
assert_eq "reception identity: CLI does not re-implement write-tree" "0" \
  "$(grep -cF 'write-tree' "$RR_CLI" || true)"

# ────────────────────────────────────────────────────────────────────────────
echo "issue #591: coverage-map ratchet guard"
# ────────────────────────────────────────────────────────────────────────────
# Live-tree ratchet: the guard enumerates git-tracked depth-1 lib/scripts units
# and cross-references lib/test/modules/coverage-map.json + the registry. A new code
# unit shipped without a coverage decision — or a stale/misfiled/wrong-shape map —
# turns THIS suite RED (git + python3 only; guard-class 2). Its arms are exercised
# with synthetic fixtures by test_coverage_map_guard.py below.
COVERAGE_GUARD_OUT="$(python3 "$LIB/test/coverage_map_guard.py" "$LIB/.." 2>&1)"
COVERAGE_GUARD_RC=$?
assert_eq "#591 coverage-map guard: shipped tree + map is clean" "0" "$COVERAGE_GUARD_RC"
[ "$COVERAGE_GUARD_RC" -eq 0 ] || while IFS= read -r _cg_line || [ -n "$_cg_line" ]; do printf '    %s\n' "$_cg_line"; done <<< "$COVERAGE_GUARD_OUT"
# Reuse the shared focused-Python-test runner (module-harness.sh, sourced above)
# rather than re-implementing its capture/assert/indent idiom — it also applies the
# PYTHON_COLORS=0 determinism guard the hand-rolled form dropped.
_CG_UNIT_OUT="$(mktemp "$_hpg_tmp_root/cg-unit.XXXXXX")"
devflow_run_focused_python_test "#591 coverage-map guard: focused Python tests pass" \
  "$LIB/test/test_coverage_map_guard.py" "$_CG_UNIT_OUT"
rm -f "$_CG_UNIT_OUT"

# ── Planted-defect positive control (issue #707 AC) ──────────────────────────
# The two assertions above are clean-tree checks: on their own they cannot
# distinguish "the guard verified a clean tree" from "the guard silently reported
# nothing." This control closes that gap for the module as a whole — it plants a
# real coverage-map drift and requires the module to observe it. The mutation is
# applied ONLY to a synthetic git repository under this module's private fixture
# root; the shipped tree and its tracked coverage-map are never written to (the
# in-place mutation hazard of issues #201/#218). The pair is deliberate: the
# undrifted fixture must be CLEAN, so the RED below is attributable to the planted
# drift rather than to fixture noise.
_hpg_cg_fixture="$_hpg_tmp_root/cg-planted"
mkdir -p "$_hpg_cg_fixture/lib/test/modules" "$_hpg_cg_fixture/scripts"
: > "$_hpg_cg_fixture/lib/planted-drift.sh"
: > "$_hpg_cg_fixture/lib/test/run.sh"
printf '%s\n' '{"schema_version": 1, "test_modules": {}}' \
  > "$_hpg_cg_fixture/scripts/workflow-flight-recorder-registry.json"
# Undrifted map: the planted unit is listed, so the guard must report nothing.
printf '%s\n' '{"schema_version": 1, "files": {"lib/planted-drift.sh": {"owner": "unmodularized", "note": ""}}, "run_sh_blocks": {}, "non_code_exempt": ["scripts/workflow-flight-recorder-registry.json", "lib/test/modules/coverage-map.json"], "exempt_subtrees": ["lib/test/"], "generated_by": "harness-python-guards planted-defect fixture"}' \
  > "$_hpg_cg_fixture/lib/test/modules/coverage-map.json"
# `git ls-files` is an index read, so staging is enough — no commit, no identity
# config, no history. A fixture whose git setup fails must not silently degrade
# into a vacuous control, so the setup outcome is asserted before the arms run.
_hpg_cg_setup=fail
git -C "$_hpg_cg_fixture" init -q >/dev/null 2>&1 \
  && git -C "$_hpg_cg_fixture" add -A >/dev/null 2>&1 \
  && _hpg_cg_setup=ok
assert_eq "#707 planted-defect control: fixture repository was created and staged" "ok" "$_hpg_cg_setup"
_hpg_cg_clean_out="$(python3 "$LIB/test/coverage_map_guard.py" "$_hpg_cg_fixture" 2>&1)"
assert_eq "#707 planted-defect control: the undrifted fixture is clean (control arm)" "0" "$?"
assert_eq "#707 planted-defect control: the undrifted fixture reports no violation" "" "$_hpg_cg_clean_out"
# Plant the drift: drop the tracked unit from `files`, which is exactly the
# ratchet arm the live-tree invocation above exists to enforce.
printf '%s\n' '{"schema_version": 1, "files": {}, "run_sh_blocks": {}, "non_code_exempt": ["scripts/workflow-flight-recorder-registry.json", "lib/test/modules/coverage-map.json"], "exempt_subtrees": ["lib/test/"], "generated_by": "harness-python-guards planted-defect fixture"}' \
  > "$_hpg_cg_fixture/lib/test/modules/coverage-map.json"
_hpg_cg_drift_out="$(python3 "$LIB/test/coverage_map_guard.py" "$_hpg_cg_fixture" 2>&1)"
_hpg_cg_drift_rc=$?
assert_eq "#707 planted-defect control: the planted coverage-map drift turns the guard RED" "yes" \
  "$([ "$_hpg_cg_drift_rc" -ne 0 ] && echo yes || echo no)"
assert_eq "#707 planted-defect control: the RED names the drifted unit" "yes" \
  "$(case "$_hpg_cg_drift_out" in *"lib/planted-drift.sh"*) echo yes ;; *) echo no ;; esac)"
rm -rf "$_hpg_cg_fixture"
