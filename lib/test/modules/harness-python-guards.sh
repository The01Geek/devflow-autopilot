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
# lib/test/module-harness.sh first. This module uses assert_eq (caller-provided, per that
# contract — both run.sh and run-module.sh define it) plus the harness helpers
# devflow_run_focused_python_test and devflow_module_allocate_owned_directory, and
# references NO helper that lives ONLY in lib/test/run.sh. The module owns its
# private fixture root and cleanup; it never invokes the runner or the full-suite
# boundary. The inventory in harness-python-guards.inventory.md maps the extracted
# coverage to its former run.sh locations and records the deliberate exclusions.
# Modules may not self-skip.
# The `trap _hpg_cleanup EXIT` below relies on a sourcing contract: both callers
# (module-harness.sh's full-suite boundary and run-module.sh) source this module
# inside a ( ... ) subshell, so the trap fires at subshell exit and cannot clobber
# the runner's own EXIT handling. Do not source this module directly in a runner's
# top-level shell without restoring the trap.

# Allocate through the harness's shared owned-directory allocator (template validation
# plus the pre-existing-directory rejection a bare `mktemp -d` cannot make) rather than
# re-implementing that check here.
_hpg_tmp_root="$(devflow_module_allocate_owned_directory \
  "${TMPDIR:-/tmp}/devflow-harness-python-guards.XXXXXX")" || {
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
RAP_ROOT="$(mktemp -d "$_hpg_tmp_root/rap.XXXXXX")" || {
  printf 'could not allocate the #600 render-audit-prompt fixture\n' >&2
  return 1
}
# Shared runner, for the reasons stated in the #527 block below: it surfaces the captured
# traceback on a RED, applies the PYTHON_COLORS=0 determinism guard, and removes the
# positional `$?` read a later inserted statement would silently re-point at another command.
devflow_run_focused_python_test "#600 render-audit-prompt: focused Python tests pass" \
  "$LIB/test/test_render_audit_prompt.py" "$RAP_ROOT/rap-unit.out"
assert_eq "#600 render-audit-prompt writes no file (stateless)" "0" \
  "$(grep -cE "open\([^)]*['\"][wax]|\.write_text\(|\.write_bytes\(" "$LIB/../scripts/render-audit-prompt.py" || true)"
assert_eq "#600 render-audit-prompt reads no stdin (stateless)" "0" \
  "$(grep -cE 'sys\.stdin|(^|[^a-zA-Z_])input\(' "$LIB/../scripts/render-audit-prompt.py" || true)"
rm -rf "$RAP_ROOT"

VB_ROOT="$(mktemp -d "$_hpg_tmp_root/vb.XXXXXX")" || {
  printf 'could not allocate the #527 verification-baseline fixture\n' >&2
  return 1
}

# ────────────────────────────────────────────────────────────────────────────
echo "verification-launch baseline analyzer (issue #527, Wave 1)"
# ────────────────────────────────────────────────────────────────────────────
# Route through the shared focused-Python-test runner rather than a bare redirect +
# positional `$?`: the runner surfaces the captured traceback on a RED (the old form wrote
# the capture and then removed it unread, leaving only "expected 0, got 1" in the module
# whose whole purpose is fast diagnosable iteration) and applies its PYTHON_COLORS=0
# determinism guard. It also removes the positional `$?` read, which a later inserted
# statement would silently re-point at the wrong command.
devflow_run_focused_python_test "verification baseline: focused Python tests pass" \
  "$LIB/test/test_verification_baseline.py" "$VB_ROOT/vb-unit.out"
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

VF_ROOT="$(mktemp -d "$_hpg_tmp_root/vf.XXXXXX")" || {
  printf 'could not allocate the #528 verification-flight fixture\n' >&2
  return 1
}

# ────────────────────────────────────────────────────────────────────────────
echo "single-flight verification coordination ledger (issue #528, Wave 2)"
# ────────────────────────────────────────────────────────────────────────────
# Shared runner, for the reasons stated in the #527 block above.
devflow_run_focused_python_test "verification flight: focused Python tests pass" \
  "$LIB/test/test_verification_flight.py" "$VF_ROOT/vf-unit.out"
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
# #719 positive control: the zero-expecting exec sweep above is only meaningful if its COUNTING
# half is live — a broken counter (a mistyped grep, an empty spelling stream, a swallowed loop)
# would pass the "expected 0" sweep by counting nothing, certifying a coordinator it never read.
# Plant EVERY derived spelling into a scratch copy of the real coordinator and require the sweep
# to count each, so the sweep's hit tally over the planted copy must equal the derived list's own
# element count. The comparand (VF_TUPLE_LEN) is derived independently from the tuple, not from
# the sweep, so this is not a self-referential tautology.
VF_PLANT="$(mktemp "$VF_ROOT/vf-plant.XXXXXX")" || {
  printf 'could not allocate the #528 positive-control fixture\n' >&2
  return 1
}
cat "$VF_SRC" > "$VF_PLANT"
while IFS= read -r _vf_spelling; do
  [ -n "$_vf_spelling" ] || continue
  printf '%s\n' "$_vf_spelling" >> "$VF_PLANT"
done <<VFPLANT
$VF_SPELLINGS
VFPLANT
VF_PLANT_HITS=0
while IFS= read -r _vf_spelling; do
  [ -n "$_vf_spelling" ] || continue
  case "$(grep -cF -- "$_vf_spelling" "$VF_PLANT" || true)" in
    0) : ;;
    *) VF_PLANT_HITS=$((VF_PLANT_HITS + 1)) ;;
  esac
done <<VFPLANTHITS
$VF_SPELLINGS
VFPLANTHITS
assert_eq "#528 banned-exec sweep positive control: every planted spelling is counted (counting half is live)" \
  "$VF_TUPLE_LEN" "$VF_PLANT_HITS"
rm -f "$VF_PLANT"
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
RI_ROOT="$(mktemp -d "$_hpg_tmp_root/ri.XXXXXX")" || {
  printf 'could not allocate the #668 reception-identity capture root\n' >&2
  return 1
}
# Shared runner, for the reasons stated in the #527 block above.
devflow_run_focused_python_test "reception identity: focused Python tests pass (library + CLI + flight extension)" \
  "$LIB/test/test_reception_identity.py" "$RI_ROOT/ri-unit.out"
# The library is an importable, non-executable stdlib-only routine (AC1): no exec bit,
# no PyYAML import, no gh call, no network call.
assert_eq "reception identity: library carries no executable bit" "no" \
  "$([ -x "$RI_LIB" ] && echo yes || echo no)"
assert_eq "reception identity: CLI carries the executable bit" "yes" \
  "$([ -x "$RR_CLI" ] && echo yes || echo no)"
assert_eq "reception identity: library imports no PyYAML" "0" \
  "$(grep -cE '(^|[^a-zA-Z_])(import yaml|from yaml import)' "$RI_LIB" || true)"
# The gh-call sweep's boundary is `(^|[^a-zA-Z_])gh ` — a deliberate BSD-PORTABILITY delta from
# the `\bgh \b` word-boundary spelling: BSD `grep -E` (macOS) does not honor GNU's `\b`
# word-boundary escape, so `\bgh \b` matches nothing there and the guard fails OPEN on exactly
# the platform CLAUDE.md's portability convention targets. `(^|[^a-zA-Z_])` is the portable
# left-boundary and the trailing space is the right one; the behavior is identical to `\bgh \b`
# on a leading-token `gh ` call and is portable across GNU and BSD grep.
assert_eq "reception identity: library makes no gh call" "0" \
  "$(grep -cE '"gh"|(^|[^a-zA-Z_])gh ' "$RI_LIB" || true)"
# #719: the comment above enumerates four AC1 properties (no exec bit, no PyYAML import, no gh
# call, no network call); the fourth had no assertion, so the enumeration over-claimed its own
# coverage. Pin the network-call absence too — a stdlib-only importable routine opens no socket
# and pulls in no HTTP client. The boundary mirrors the gh-call sweep's portable form.
assert_eq "reception identity: library makes no network call" "0" \
  "$(grep -cE '(^|[^a-zA-Z_])(import socket|import urllib|import http|import ssl|from socket import|from urllib|from http|import requests|import httpx|urlopen)' "$RI_LIB" || true)"
# The CLI imports the library rather than re-implementing the derivation (AC2): exactly one
# copy of the identity format ships. Pin the import and the absence of a second write-tree.
assert_eq "reception identity: CLI imports the library (single derivation implementation)" "1" \
  "$(grep -cF 'import reception_identity' "$RR_CLI" || true)"
assert_eq "reception identity: CLI does not re-implement write-tree" "0" \
  "$(grep -cF 'write-tree' "$RR_CLI" || true)"
rm -rf "$RI_ROOT"

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
_CG_UNIT_OUT="$(mktemp "$_hpg_tmp_root/cg-unit.XXXXXX")" || {
  printf 'could not allocate the #591 coverage-map unit-test capture\n' >&2
  return 1
}
devflow_run_focused_python_test "#591 coverage-map guard: focused Python tests pass" \
  "$LIB/test/test_coverage_map_guard.py" "$_CG_UNIT_OUT"
rm -f "$_CG_UNIT_OUT"

# ── Planted-defect positive control (issue #707 AC) ──────────────────────────
# #719: describe the two assertions above ACCURATELY. The FIRST — the shipped-tree
# clean check (`#591 coverage-map guard: shipped tree + map is clean`) — is a
# clean-tree assertion that on its own cannot distinguish "the guard verified a
# clean tree" from "the guard silently reported nothing", because a live green tells
# the reader nothing about whether the guard could still observe a defect. The
# SECOND — the focused unit test `test_coverage_map_guard.py` — is NOT in that
# position: it already carries planted-defect arms over synthetic fixtures (as the
# control below it does), so it does distinguish the two states for the guard's arms.
# This control closes the remaining gap for the module's LIVE-TREE path specifically —
# it plants a real coverage-map drift and requires the module to observe it. The mutation is
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
# One template for both arms, parameterized on the ONLY field that differs (`files`).
# Two hand-written copies of the map schema would let the control arm and the drift arm
# diverge in some other key, which would make the control pass — or fail — for a reason
# unrelated to the planted drift, defeating its whole purpose.
_hpg_write_map() {  # files-object -> writes the fixture's coverage map
  printf '{"schema_version": 1, "files": %s, "run_sh_blocks": {}, "non_code_exempt": ["scripts/workflow-flight-recorder-registry.json", "lib/test/modules/coverage-map.json"], "exempt_subtrees": ["lib/test/"], "generated_by": "harness-python-guards planted-defect fixture"}\n' \
    "$1" > "$_hpg_cg_fixture/lib/test/modules/coverage-map.json"
}
# Undrifted map: the planted unit is listed, so the guard must report nothing.
_hpg_write_map '{"lib/planted-drift.sh": {"owner": "unmodularized", "note": ""}}'
# `git ls-files` is an index read, so staging is enough — no commit, no identity
# config, no history. A fixture whose git setup fails must not silently degrade
# into a vacuous control, so the setup outcome is asserted before the arms run.
# Ambient git configuration is neutralized: a global `core.excludesFile` matching the
# planted path, or an `init.templateDir`, would change what `git ls-files` reports WITHOUT
# changing either command's exit status — the drift arm would then pass for the wrong
# reason. And the setup assertion checks the OUTCOME the arms depend on (the planted unit
# is actually tracked), never merely that the commands exited 0 (guard-class 1).
_hpg_cg_setup=fail
git -c core.excludesFile=/dev/null -c init.templateDir= -C "$_hpg_cg_fixture" init -q >/dev/null 2>&1 \
  && git -c core.excludesFile=/dev/null -C "$_hpg_cg_fixture" add -A >/dev/null 2>&1 \
  && case "$(git -C "$_hpg_cg_fixture" ls-files)" in *"lib/planted-drift.sh"*) _hpg_cg_setup=ok ;; esac
assert_eq "#707 planted-defect control: fixture repository was created and the planted unit is tracked" "ok" "$_hpg_cg_setup"
_hpg_cg_clean_out="$(python3 "$LIB/test/coverage_map_guard.py" "$_hpg_cg_fixture" 2>&1)"
_hpg_cg_clean_rc=$?
assert_eq "#707 planted-defect control: the undrifted fixture is clean (control arm)" "0" "$_hpg_cg_clean_rc"
assert_eq "#707 planted-defect control: the undrifted fixture reports no violation" "" "$_hpg_cg_clean_out"
# Plant the drift: drop the tracked unit from `files`, which is exactly the
# ratchet arm the live-tree invocation above exists to enforce.
_hpg_write_map '{}'
_hpg_cg_drift_out="$(python3 "$LIB/test/coverage_map_guard.py" "$_hpg_cg_fixture" 2>&1)"
_hpg_cg_drift_rc=$?
assert_eq "#707 planted-defect control: the planted coverage-map drift turns the guard RED" "yes" \
  "$([ "$_hpg_cg_drift_rc" -ne 0 ] && echo yes || echo no)"
assert_eq "#707 planted-defect control: the RED names the drifted unit" "yes" \
  "$(case "$_hpg_cg_drift_out" in *"lib/planted-drift.sh"*) echo yes ;; *) echo no ;; esac)"
rm -rf "$_hpg_cg_fixture"
