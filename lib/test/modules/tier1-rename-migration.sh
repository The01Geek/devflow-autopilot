# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# shellcheck shell=bash
# Sourceable Tier-1 rename/migration contract module (issue #1002).
# Contract: the caller sets LIB and RESULTS_FILE, defines assert_eq, and sources
# lib/test/module-harness.sh first (which defines the namespaced module pin API:
# devflow_module_pin_count / devflow_module_pin_unique / devflow_module_pin_present).
# This module uses assert_eq plus the `_t1_*` domain-private helpers defined below —
# it references NO monolith helper. The module owns its private fixture root and
# cleanup; it never invokes the runner or the full-suite boundary. The inventory in
# tier1-rename-migration.inventory.md records the module's provenance. Modules may
# not self-skip.
# The `trap _t1_cleanup EXIT` below relies on a sourcing contract: both callers
# (module-harness.sh's full-suite boundary and run-module.sh) source this module
# inside a ( ... ) subshell, so the trap fires at subshell exit and cannot clobber
# the runner's own EXIT handling. Do not source this module directly in a runner's
# top-level shell without restoring the trap.
#
# WHAT THIS MODULE OWNS. The subjects of issue #1002's Tier 1 migration:
#   lib/rename-map.json                 the single source of the rename map
#   lib/resolve-state-dir.sh + lib/state_dir.py
#                                       the state-directory contract (a coupled pair)
#   scripts/config-get.sh               the superseded-key probe
#   scripts/scaffold-config.sh          the config-key migration, its gate, the guard
#   scripts/migrate-consumer-tier1.sh   the all-or-nothing consumer migration
# Every assertion is behavioural: a helper is driven file-in/file-out over a fixture
# consumer tree and judged on its exit code, its emitted report, and the resulting
# BYTES. There is no wording-only pin here (issues #375/#666/#810).

T1_MAP="$LIB/rename-map.json"
T1_STATE_SH="$LIB/resolve-state-dir.sh"
# The python sibling (lib/state_dir.py) is imported through PYTHONPATH="$LIB"
# rather than invoked by path, so it needs no path variable here.
T1_CFGGET="$LIB/../scripts/config-get.sh"
T1_SCAFFOLD="$LIB/../scripts/scaffold-config.sh"
T1_MIGRATE="$LIB/../scripts/migrate-consumer-tier1.sh"
T1_EXAMPLE="$LIB/../.prflow/config.example.json"
T1_SCHEMA="$LIB/../.prflow/config.schema.json"

_t1_tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/devflow-tier1-rename.XXXXXX")" || {
  printf 'could not allocate tier1-rename-migration fixture\n' >&2
  return 1
}
_t1_cleanup() {
  chmod -R u+w "$_t1_tmp_root" 2>/dev/null || true
  rm -rf "$_t1_tmp_root"
}
trap _t1_cleanup EXIT

# A fresh fixture repo root. Every fixture lives under the module's own temp root, so
# no assertion here can reach the live checkout. `mktemp -d` rather than an incrementing
# counter: this helper is always called through a command substitution, whose subshell
# would discard a counter increment and hand every fixture the SAME directory — the
# fixtures would then contaminate each other and the failures would read as defects in
# the code under test.
_t1_root() {
  mktemp -d "$_t1_tmp_root/rXXXXXX"
}

# Content-addressed whole-tree digest, .git pruned. Byte-identity is asserted over
# BYTES rather than over a list of paths, because a partial write would still satisfy
# a path list. The walk is rooted at the module's own fixture root, never at the
# repository root.
# tree-walk-ok: enumerates a module-owned mktemp fixture tree (never the repository
# root), so it cannot descend into a sibling git worktree; issue #711's hazard does
# not arise and git ls-files cannot see an unversioned fixture.
_t1_snap() {
  ( cd "$1" || return 0
    # The walk is confined by the `cd` above to the module's own mktemp fixture root.
    _t1_paths="$(find . -path ./.git -prune -o \( -type f -o -type l \) -print)"  # tree-walk-ok: rooted at a module-owned mktemp fixture tree, never the repository root, so it cannot descend into a sibling git worktree (issue #711) and git ls-files cannot see an unversioned fixture
    printf '%s\n' "$_t1_paths" \
      | LC_ALL=C sort \
      | while IFS= read -r f; do
          [ -n "$f" ] || continue
          printf '%s %s\n' "$f" "$(shasum "$f" 2>/dev/null | cut -d' ' -f1)"
        done | shasum | cut -d' ' -f1 ) 2>/dev/null
}

# yes/no over "does this text contain that literal", so an assertion reads as a
# behaviour rather than as a grep.
_t1_has() {
  case "$1" in
    *"$2"*) printf 'yes' ;;
    *) printf 'no' ;;
  esac
}

# A consumer repository on the SUPERSEDED layout, carrying one of every artifact the
# atomic unit touches plus a frozen record whose bytes must survive.
_t1_old_consumer() {
  local r; r="$(_t1_root)"
  mkdir -p "$r/.devflow/vendor/devflow/scripts" "$r/.devflow/learnings" \
           "$r/.github/workflows" "$r/.claude-plugin"
  cat > "$r/.devflow/config.json" <<'T1_CFG'
{
  "base_branch": "main",
  "devflow": { "allowed_bots": "botA", "workpad_marker": "<!-- devflow:workpad -->" },
  "devflow_implement": { "effort": "low" },
  "devflow_review": { "max_iterations": 9 },
  "devflow_version": "0123456789abcdef0123456789abcdef01234567",
  "workflows": { "devflow": true, "devflow-review": false }
}
T1_CFG
  printf 'echo vendored\n' > "$r/.devflow/vendor/devflow/scripts/x.sh"
  printf '{"frozen":"record"}\n' > "$r/.devflow/learnings/r.jsonl"
  printf 'run: .devflow/vendor/devflow/scripts/x.sh\n' > "$r/.github/workflows/devflow.yml"
  printf '{"plugins":[{"name":"prflow","source":"./.devflow/vendor/devflow"}]}\n' \
    > "$r/.claude-plugin/marketplace.json"
  printf '%s' "$r"
}

# ────────────────────────────────────────────────────────────────────────────
echo "#1002 A. the rename map is the single source every site resolves against"
# ────────────────────────────────────────────────────────────────────────────
# The map is machine-readable and every consuming site agrees with it. A site that
# carried its own literal copy would drift silently, which is the defect issue #988's
# one-owner criterion exists to stop.
assert_eq "#1002 rename map parses as JSON" "yes" \
  "$(python3 -c 'import json,sys; json.load(open(sys.argv[1])); print("yes")' "$T1_MAP" 2>/dev/null || printf 'no')"

_t1_map_keys="$(python3 -c '
import json,sys
m=json.load(open(sys.argv[1]))
print(" ".join(sorted(m["config_keys"])))' "$T1_MAP" 2>/dev/null)"
assert_eq "#1002 the map declares exactly the seven superseded top-level keys" \
  "devflow devflow_implement devflow_retrospective devflow_review devflow_review_and_fix devflow_runner devflow_version" \
  "$_t1_map_keys"

assert_eq "#1002 every mapped target is the prflow_ sibling of its source" "ok" \
  "$(python3 -c '
import json,sys
m=json.load(open(sys.argv[1]))["config_keys"]
bad=[k for k,v in m.items() if v != k.replace("devflow","prflow",1)]
print("ok" if not bad else "bad:"+",".join(bad))' "$T1_MAP" 2>/dev/null)"

# The two state-directory resolvers are a coupled pair, and both are pinned against
# the map. Driving all three is what makes the coupling enforced rather than asserted.
# shellcheck source=../../resolve-state-dir.sh
_t1_sh_names="$( . "$T1_STATE_SH" >/dev/null 2>&1; printf '%s %s' \
  "${PRFLOW_STATE_DIR_CURRENT:-UNSET}" "${PRFLOW_STATE_DIR_SUPERSEDED:-UNSET}")"
_t1_map_names="$(python3 -c '
import json,sys
p=json.load(open(sys.argv[1]))["paths"]["state_dir"]
print(p["current"], p["superseded"])' "$T1_MAP" 2>/dev/null)"
assert_eq "#1002 the SHELL state-dir resolver agrees with the rename map" \
  "$_t1_map_names" "$_t1_sh_names"

_t1_py_names="$(PYTHONPATH="$LIB" python3 -c '
import state_dir
print(state_dir.STATE_DIR_CURRENT, state_dir.STATE_DIR_SUPERSEDED)' 2>/dev/null)"
assert_eq "#1002 the PYTHON state-dir resolver agrees with the rename map" \
  "$_t1_map_names" "$_t1_py_names"

assert_eq "#1002 the two state-dir resolvers agree with EACH OTHER (coupled pair)" \
  "$_t1_sh_names" "$_t1_py_names"

_t1_vendor="$(python3 -c '
import json,sys
p=json.load(open(sys.argv[1]))["paths"]["vendor_dir"]
print(p["superseded"], p["current"])' "$T1_MAP" 2>/dev/null)"
assert_eq "#1002 the map declares the vendored-path rename at both levels" \
  ".devflow/vendor/devflow .prflow/vendor/prflow" "$_t1_vendor"

# The FROZEN set is declared in the map so a later sweep cannot widen it silently.
assert_eq "#1002 the map freezes the two workflows.* config sub-keys" "yes" \
  "$(python3 -c '
import json,sys
f=json.load(open(sys.argv[1]))["frozen"]["config_keys"]
print("yes" if set(f)=={"workflows.devflow","workflows.devflow-review"} else "no:"+",".join(f))' "$T1_MAP" 2>/dev/null)"

assert_eq "#1002 the map declares a four-member atomic unit" "4" \
  "$(python3 -c '
import json,sys
print(len(json.load(open(sys.argv[1]))["atomic_unit"]))' "$T1_MAP" 2>/dev/null)"

assert_eq "#1002 the atomic unit names exactly the four members the migration applies" \
  "marketplace-source-rewrite state-dir-move version-pin-advance workflow-content-rewrite" \
  "$(python3 -c '
import json,sys
print(" ".join(sorted(r["id"] for r in json.load(open(sys.argv[1]))["atomic_unit"])))' "$T1_MAP" 2>/dev/null)"

# ────────────────────────────────────────────────────────────────────────────
echo "#1002 B. the shipped config vocabulary carries no superseded top-level key"
# ────────────────────────────────────────────────────────────────────────────
for _t1_f in "$T1_SCHEMA" "$T1_EXAMPLE"; do
  _t1_label="${_t1_f##*/}"
  assert_eq "#1002 $_t1_label declares no top-level property beginning 'devflow'" "none" \
    "$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
props = d.get("properties", d) if sys.argv[2]=="schema" else d
bad=[k for k in props if k.startswith("devflow")]
print(",".join(bad) if bad else "none")' "$_t1_f" "$( [ "$_t1_label" = "config.schema.json" ] && echo schema || echo plain )" 2>/dev/null)"
done

# The FROZEN counter-control: the workflows block still declares exactly the two
# brand-named sub-keys. Renaming these is the single most damaging edit available in
# this change (`.workflows.devflow // false` silently disables everything), so the
# purity assertion above must not be read as licence to sweep them.
assert_eq "#1002 FROZEN: config.schema.json still declares workflows.{devflow,devflow-review}" \
  "devflow devflow-review" \
  "$(python3 -c '
import json,sys
print(" ".join(json.load(open(sys.argv[1]))["properties"]["workflows"]["properties"]))' "$T1_SCHEMA" 2>/dev/null)"

assert_eq "#1002 FROZEN: config.example.json still carries the workflows.devflow toggle" "yes" \
  "$(python3 -c '
import json,sys
w=json.load(open(sys.argv[1])).get("workflows",{})
print("yes" if "devflow" in w and "devflow-review" in w else "no")' "$T1_EXAMPLE" 2>/dev/null)"

# ────────────────────────────────────────────────────────────────────────────
echo "#1002 C. state-directory resolution and its LOUD transitional fallback"
# ────────────────────────────────────────────────────────────────────────────
_t1_r="$(_t1_root)"; mkdir -p "$_t1_r/.prflow"
# shellcheck source=../../resolve-state-dir.sh
_t1_out="$( . "$T1_STATE_SH" >/dev/null 2>&1; prflow_state_dir "$_t1_r" 2>"$_t1_tmp_root/e1" )"
assert_eq "#1002 shell: the canonical directory resolves when present" "$_t1_r/.prflow" "$_t1_out"
assert_eq "#1002 shell: resolving the canonical directory emits NO breadcrumb" "" \
  "$(cat "$_t1_tmp_root/e1")"

_t1_r="$(_t1_root)"; mkdir -p "$_t1_r/.devflow"
# shellcheck source=../../resolve-state-dir.sh
_t1_out="$( . "$T1_STATE_SH" >/dev/null 2>&1; prflow_state_dir "$_t1_r" 2>"$_t1_tmp_root/e2" )"
assert_eq "#1002 shell: falls back to the superseded directory when only it is present" \
  "$_t1_r/.devflow" "$_t1_out"
assert_eq "#1002 shell: the superseded fallback breadcrumbs, naming the remedy" "yes" \
  "$(_t1_has "$(cat "$_t1_tmp_root/e2")" '/prflow:init')"
assert_eq "#1002 shell: the breadcrumb names the superseded directory it read" "yes" \
  "$(_t1_has "$(cat "$_t1_tmp_root/e2")" '.devflow/')"

_t1_r="$(_t1_root)"; mkdir -p "$_t1_r/.prflow" "$_t1_r/.devflow"
# shellcheck source=../../resolve-state-dir.sh
_t1_out="$( . "$T1_STATE_SH" >/dev/null 2>&1; prflow_state_dir "$_t1_r" 2>"$_t1_tmp_root/e3" )"
assert_eq "#1002 shell: with BOTH present the canonical directory wins" "$_t1_r/.prflow" "$_t1_out"
assert_eq "#1002 shell: with BOTH present there is no breadcrumb (nothing was superseded)" "" \
  "$(cat "$_t1_tmp_root/e3")"

_t1_r="$(_t1_root)"
# shellcheck source=../../resolve-state-dir.sh
_t1_out="$( . "$T1_STATE_SH" >/dev/null 2>&1; prflow_state_dir "$_t1_r" 2>"$_t1_tmp_root/e4" )"
assert_eq "#1002 shell: with NEITHER present the canonical path is handed back" \
  "$_t1_r/.prflow" "$_t1_out"
# A fresh repository is not a stale one. Breadcrumbing here would train an operator to
# ignore the one line that matters.
assert_eq "#1002 shell: a fresh repository earns NO breadcrumb" "" "$(cat "$_t1_tmp_root/e4")"

# A plain FILE or a dangling symlink at either name is not a state directory.
_t1_r="$(_t1_root)"; : > "$_t1_r/.prflow"; mkdir -p "$_t1_r/.devflow"
# shellcheck source=../../resolve-state-dir.sh
_t1_out="$( . "$T1_STATE_SH" >/dev/null 2>&1; prflow_state_dir "$_t1_r" 2>/dev/null )"
assert_eq "#1002 shell: a FILE at the canonical name is not a state directory" \
  "$_t1_r/.devflow" "$_t1_out"

_t1_r="$(_t1_root)"; ln -s "$_t1_r/nowhere" "$_t1_r/.prflow"; mkdir -p "$_t1_r/.devflow"
# shellcheck source=../../resolve-state-dir.sh
_t1_out="$( . "$T1_STATE_SH" >/dev/null 2>&1; prflow_state_dir "$_t1_r" 2>/dev/null )"
assert_eq "#1002 shell: a DANGLING symlink at the canonical name is not a state directory" \
  "$_t1_r/.devflow" "$_t1_out"

# The Python sibling answers identically on every row — that is what makes the pair
# coupled rather than merely parallel.
for _t1_case in canonical superseded both neither; do
  _t1_r="$(_t1_root)"
  case "$_t1_case" in
    canonical)  mkdir -p "$_t1_r/.prflow"; _t1_want="$_t1_r/.prflow" ;;
    superseded) mkdir -p "$_t1_r/.devflow"; _t1_want="$_t1_r/.devflow" ;;
    both)       mkdir -p "$_t1_r/.prflow" "$_t1_r/.devflow"; _t1_want="$_t1_r/.prflow" ;;
    neither)    _t1_want="$_t1_r/.prflow" ;;
  esac
  # shellcheck source=../../resolve-state-dir.sh
  _t1_sh="$( . "$T1_STATE_SH" >/dev/null 2>&1; prflow_state_dir "$_t1_r" 2>/dev/null )"
  _t1_py="$(PYTHONPATH="$LIB" python3 -c '
import state_dir,sys
sys.stdout.write(state_dir.resolve_state_dir(sys.argv[1]))' "$_t1_r" 2>/dev/null)"
  assert_eq "#1002 python: $_t1_case resolves to the same directory the shell chose" \
    "$_t1_want" "$_t1_py"
  assert_eq "#1002 coupled pair: shell and python agree on the $_t1_case row" \
    "$_t1_sh" "$_t1_py"
done

_t1_r="$(_t1_root)"; mkdir -p "$_t1_r/.devflow"
_t1_pyerr="$(PYTHONPATH="$LIB" python3 -c '
import state_dir,sys
state_dir.resolve_state_dir(sys.argv[1])' "$_t1_r" 2>&1 >/dev/null)"
assert_eq "#1002 python: the superseded fallback breadcrumbs, naming the remedy" "yes" \
  "$(_t1_has "$_t1_pyerr" '/prflow:init')"

# ────────────────────────────────────────────────────────────────────────────
echo "#1002 D. config-get.sh superseded-key probe (absent vs present-and-empty)"
# ────────────────────────────────────────────────────────────────────────────
# The resolver collapses {absent, null, present-and-empty} onto one empty stdout, so a
# breadcrumb sited at that gate would fire on a key a consumer deliberately set to "".
# The probe re-reads and distinguishes them. These rows are the six-shape config matrix
# the repository's best-effort-parser convention requires, applied to the superseded key.
_t1_cfg() { printf '%s' "$2" > "$_t1_tmp_root/cfg$1.json"; printf '%s' "$_t1_tmp_root/cfg$1.json"; }

_t1_f="$(_t1_cfg 1 '{"devflow":{"allowed_bots":"botA"}}')"
_t1_out="$("$T1_CFGGET" .prflow.allowed_bots FALLBACK "$_t1_f" 2>"$_t1_tmp_root/pe1")"; _t1_rc=$?
assert_eq "#1002 probe: absent new key + present superseded key emits the breadcrumb" "yes" \
  "$(_t1_has "$(cat "$_t1_tmp_root/pe1")" 'superseded counterpart')"
assert_eq "#1002 probe: the breadcrumb names BOTH the requested and the superseded key" "yes yes" \
  "$(_t1_has "$(cat "$_t1_tmp_root/pe1")" '.prflow.allowed_bots') $(_t1_has "$(cat "$_t1_tmp_root/pe1")" '.devflow.allowed_bots')"
assert_eq "#1002 probe: the breadcrumb names the remedy" "yes" \
  "$(_t1_has "$(cat "$_t1_tmp_root/pe1")" '/prflow:init')"
assert_eq "#1002 probe: the default is still emitted and the exit code is unchanged" "FALLBACK 0" \
  "$_t1_out $_t1_rc"

# The valid-falsy rows. A present new key holding "", false, 0 or null is a deliberate
# consumer value, not an un-migrated config, and must NOT breadcrumb.
for _t1_val in '""' 'false' '0' 'null'; do
  _t1_f="$(_t1_cfg 2 "{\"prflow\":{\"allowed_bots\":$_t1_val},\"devflow\":{\"allowed_bots\":\"botA\"}}")"
  "$T1_CFGGET" .prflow.allowed_bots FALLBACK "$_t1_f" >/dev/null 2>"$_t1_tmp_root/pe2"
  assert_eq "#1002 probe: a new key present and holding $_t1_val emits NO breadcrumb" "" \
    "$(cat "$_t1_tmp_root/pe2")"
done

# Negative control: the breadcrumb is conditioned on the SUPERSEDED key's presence, not
# on every miss. Without this row the probe could fire on any absent key and still pass.
_t1_f="$(_t1_cfg 3 '{"docs":{"internal":"D"}}')"
"$T1_CFGGET" .prflow.allowed_bots FALLBACK "$_t1_f" >/dev/null 2>"$_t1_tmp_root/pe3"
assert_eq "#1002 probe: both keys absent emits NO breadcrumb (negative control)" "" \
  "$(cat "$_t1_tmp_root/pe3")"

# First-segment-only mapping: no deeper segment is rewritten.
_t1_f="$(_t1_cfg 4 '{"devflow_implement":{"stall_backstop":{"enabled":true}}}')"
"$T1_CFGGET" .prflow_implement.stall_backstop.enabled X "$_t1_f" >/dev/null 2>"$_t1_tmp_root/pe4"
assert_eq "#1002 probe: only the FIRST dot-path segment is mapped" "yes" \
  "$(_t1_has "$(cat "$_t1_tmp_root/pe4")" '.devflow_implement.stall_backstop.enabled')"

# A deeper segment that happens to contain the old brand is not a superseded key.
_t1_f="$(_t1_cfg 5 '{"prflow":{"devflow_note":"x"}}')"
"$T1_CFGGET" .prflow.devflow_note MISS "$_t1_f" >/dev/null 2>"$_t1_tmp_root/pe5"
assert_eq "#1002 probe: a deeper segment carrying the old brand is not rewritten" "" \
  "$(cat "$_t1_tmp_root/pe5")"

# Wrong-type and malformed rows: a diagnostic must never break the read it diagnoses.
_t1_f="$(_t1_cfg 6 '{"devflow":"a scalar, not an object"}')"
"$T1_CFGGET" .prflow.allowed_bots D "$_t1_f" >/dev/null 2>&1; _t1_rc=$?
assert_eq "#1002 probe: a superseded key holding a scalar still exits 0 with the default" "0" "$_t1_rc"

_t1_f="$(_t1_cfg 7 '["an","array","root"]')"
"$T1_CFGGET" .prflow.allowed_bots D "$_t1_f" >/dev/null 2>&1; _t1_rc=$?
assert_eq "#1002 probe: a non-object config root still exits 0 with the default" "0" "$_t1_rc"

_t1_f="$(_t1_cfg 8 '{bad json')"
"$T1_CFGGET" .prflow.allowed_bots D "$_t1_f" >/dev/null 2>"$_t1_tmp_root/pe8"; _t1_rc=$?
assert_eq "#1002 probe: malformed JSON keeps exit 2 (the documented parse-error code)" "2" "$_t1_rc"
assert_eq "#1002 probe: malformed JSON emits no superseded-key breadcrumb (no key established)" "no" \
  "$(_t1_has "$(cat "$_t1_tmp_root/pe8")" 'superseded counterpart')"

# The no-default path: exit 1 AND still breadcrumb. Requires a repo-root-anchored run,
# because the 3-argument form cannot express "config file, no default".
_t1_r="$(_t1_root)"; mkdir -p "$_t1_r/.prflow"
printf '%s' '{"devflow":{"allowed_bots":"botA"}}' > "$_t1_r/.prflow/config.json"
( cd "$_t1_r" && "$T1_CFGGET" .prflow.allowed_bots ) >/dev/null 2>"$_t1_tmp_root/pe9"; _t1_rc=$?
assert_eq "#1002 probe: the no-default path keeps exit 1" "1" "$_t1_rc"
assert_eq "#1002 probe: the breadcrumb is written on the no-default path too" "yes" \
  "$(_t1_has "$(cat "$_t1_tmp_root/pe9")" 'superseded counterpart')"

# A key found under its NEW name resolves normally and says nothing.
_t1_f="$(_t1_cfg 9 '{"prflow":{"allowed_bots":"botNEW"}}')"
_t1_out="$("$T1_CFGGET" .prflow.allowed_bots D "$_t1_f" 2>"$_t1_tmp_root/pe10")"; _t1_rc=$?
assert_eq "#1002 probe: a migrated key resolves to its value, exit 0, no breadcrumb" "botNEW 0 " \
  "$_t1_out $_t1_rc $(cat "$_t1_tmp_root/pe10")"

# config-get.sh resolving a consumer still on the superseded DIRECTORY.
_t1_r="$(_t1_root)"; mkdir -p "$_t1_r/.devflow"
printf '%s' '{"prflow":{"allowed_bots":"legacyBot"}}' > "$_t1_r/.devflow/config.json"
_t1_out="$( cd "$_t1_r" && "$T1_CFGGET" .prflow.allowed_bots NONE 2>"$_t1_tmp_root/pe11" )"
assert_eq "#1002 config-get reads through to the superseded state directory" "legacyBot" "$_t1_out"
assert_eq "#1002 config-get breadcrumbs when it read the superseded state directory" "yes" \
  "$(_t1_has "$(cat "$_t1_tmp_root/pe11")" 'superseded .devflow/ state directory')"

# ────────────────────────────────────────────────────────────────────────────
echo "#1002 E. scaffold-config.sh: key migration, its gate, and the anti-graft guard"
# ────────────────────────────────────────────────────────────────────────────
_t1_seven='{"devflow":{"allowed_bots":"botA"},"devflow_implement":{"effort":"low"},"devflow_retrospective":{"min_occurrences":7},"devflow_review":{"max_iterations":9},"devflow_review_and_fix":{"fix_severity_threshold":"critical"},"devflow_runner":{"effort":"low"},"devflow_version":"abc123"}'

# A scaffolder fixture: a repo whose shipped workflows are FRESH, so the gate passes.
_t1_scaffold_root() {
  local r; r="$(_t1_root)"
  mkdir -p "$r/.prflow" "$r/.github/workflows"
  printf '%s' "$1" > "$r/.prflow/config.json"
  printf '%s' "$r"
}

_t1_r="$(_t1_scaffold_root "$_t1_seven")"
_t1_out="$("$T1_SCAFFOLD" "$_t1_r" 2>&1)"
_t1_keys="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(",".join(sorted(k for k in d if k.startswith(("devflow","prflow")))))' "$_t1_r/.prflow/config.json" 2>/dev/null)"
assert_eq "#1002 scaffolder: with the gate satisfied every superseded key is renamed" \
  "prflow,prflow_implement,prflow_retrospective,prflow_review,prflow_review_and_fix,prflow_runner,prflow_version" \
  "$_t1_keys"
assert_eq "#1002 scaffolder: the consumer VALUES are carried across byte-for-byte" \
  "botA low 7 9 critical low abc123" \
  "$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(d["prflow"]["allowed_bots"], d["prflow_implement"]["effort"],
      d["prflow_retrospective"]["min_occurrences"], d["prflow_review"]["max_iterations"],
      d["prflow_review_and_fix"]["fix_severity_threshold"], d["prflow_runner"]["effort"],
      d["prflow_version"])' "$_t1_r/.prflow/config.json" 2>/dev/null)"
assert_eq "#1002 scaffolder: it reports one line per migrated key" "7" \
  "$(printf '%s\n' "$_t1_out" | grep -c 'migrated superseded config key')"
assert_eq "#1002 scaffolder: it reports the version pin without gating on it" "yes" \
  "$(_t1_has "$_t1_out" 'plugin version pin is')"

# The GATE. A shipped workflow still reading a superseded name refuses the migration.
_t1_r="$(_t1_scaffold_root "$_t1_seven")"
printf 'run: jq -r ".devflow.allowed_bots"\n' > "$_t1_r/.github/workflows/devflow.yml"
_t1_before="$(shasum "$_t1_r/.prflow/config.json" | cut -d' ' -f1)"
_t1_out="$("$T1_SCAFFOLD" "$_t1_r" 2>&1)"
assert_eq "#1002 scaffolder gate: a stale SHIPPED workflow refuses the migration" "yes" \
  "$(_t1_has "$_t1_out" 'NOT migrating superseded config keys')"
assert_eq "#1002 scaffolder gate: the refusal names the stale file" "yes" \
  "$(_t1_has "$_t1_out" 'devflow.yml')"
assert_eq "#1002 scaffolder gate: the refusal names install.sh --apply as the remedy" "yes" \
  "$(_t1_has "$_t1_out" 'install.sh --apply')"
assert_eq "#1002 scaffolder gate: nothing was migrated" "yes" \
  "$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print("yes" if all(k in d for k in ("devflow","devflow_version")) else "no")' "$_t1_r/.prflow/config.json" 2>/dev/null)"
# THE ANTI-GRAFT GUARD on the refusal path: the deep merge must not create a new-name
# block holding example defaults beside the surviving superseded one. This is the
# dominant silent-revert hazard (#988 finding 1) and the reason the guard keys on the
# ORIGINAL config rather than on whether the migration ran.
assert_eq "#1002 anti-graft: on the REFUSAL path no prflow_* key is grafted" "none" \
  "$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
g=[k for k in d if k.startswith("prflow")]
print(",".join(sorted(g)) if g else "none")' "$_t1_r/.prflow/config.json" 2>/dev/null)"

# The same guard on the DEGRADED path where jq is unusable.
_t1_r="$(_t1_scaffold_root "$_t1_seven")"
printf 'run: jq -r ".devflow.allowed_bots"\n' > "$_t1_r/.github/workflows/devflow.yml"
_t1_out="$(DEVFLOW_JQ="$_t1_tmp_root/no-such-jq" "$T1_SCAFFOLD" "$_t1_r" 2>&1)"
assert_eq "#1002 anti-graft: with jq unusable the backfill is skipped, and it says so" "yes" \
  "$(_t1_has "$_t1_out" 'no usable jq')"
assert_eq "#1002 anti-graft: on the jq-unusable path no prflow_* key is grafted" "none" \
  "$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
g=[k for k in d if k.startswith("prflow")]
print(",".join(sorted(g)) if g else "none")' "$_t1_r/.prflow/config.json" 2>/dev/null)"

# NEGATIVE CONTROL for the gated set: a stale RETAINED (unshipped) workflow must NOT
# refuse. install.sh cannot refresh those files, so gating on one would block the
# migration forever. This row is what pins the gated set to the two shipped filenames.
_t1_r="$(_t1_scaffold_root "$_t1_seven")"
printf 'run: .devflow/vendor/devflow/scripts/x.sh\n' > "$_t1_r/.github/workflows/devflow-runner.yml"
_t1_out="$("$T1_SCAFFOLD" "$_t1_r" 2>&1)"
assert_eq "#1002 scaffolder gate: a stale RETAINED workflow does NOT refuse the migration" "no" \
  "$(_t1_has "$_t1_out" 'NOT migrating superseded config keys')"
assert_eq "#1002 scaffolder: the retained unshipped workflow is REPORTED by name instead" "yes" \
  "$(_t1_has "$_t1_out" 'devflow-runner.yml is present')"
assert_eq "#1002 scaffolder: the migration proceeded despite the retained file" "yes" \
  "$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print("yes" if "prflow" in d and "devflow" not in d else "no")' "$_t1_r/.prflow/config.json" 2>/dev/null)"

# The retained-file report fires on EVERY run, including one where the config has
# already migrated — otherwise it falls silent on the run after the one that mattered.
_t1_out="$("$T1_SCAFFOLD" "$_t1_r" 2>&1)"
assert_eq "#1002 scaffolder: the retained-file report persists after the config migrated" "yes" \
  "$(_t1_has "$_t1_out" 'devflow-runner.yml is present')"

# Both-present, new block equal to the shipped example default: the superseded value
# wins and the superseded block goes.
_t1_r="$(_t1_root)"; mkdir -p "$_t1_r/.prflow" "$_t1_r/.github/workflows"
python3 -c '
import json,sys
ex=json.load(open(sys.argv[1]))
json.dump({"devflow_review":{"max_iterations":42},"prflow_review":ex["prflow_review"]},
          open(sys.argv[2],"w"), indent=2)' "$T1_EXAMPLE" "$_t1_r/.prflow/config.json"
_t1_out="$("$T1_SCAFFOLD" "$_t1_r" 2>&1)"
assert_eq "#1002 both-present (example-valued): the SUPERSEDED value wins" "42" \
  "$(python3 -c '
import json,sys
print(json.load(open(sys.argv[1]))["prflow_review"]["max_iterations"])' "$_t1_r/.prflow/config.json" 2>/dev/null)"
assert_eq "#1002 both-present (example-valued): the superseded block is removed" "False" \
  "$(python3 -c '
import json,sys
print("devflow_review" in json.load(open(sys.argv[1])))' "$_t1_r/.prflow/config.json" 2>/dev/null)"
assert_eq "#1002 both-present (example-valued): the run reports that it did so" "yes" \
  "$(_t1_has "$_t1_out" 'still held the shipped example default')"

# Both-present, new block DIFFERING from the example: a deliberate consumer edit a
# rename must not discard. Neither block changes and the conflict names both exits.
_t1_r="$(_t1_root)"; mkdir -p "$_t1_r/.prflow" "$_t1_r/.github/workflows"
printf '%s' '{"devflow_review":{"max_iterations":42},"prflow_review":{"max_iterations":99}}' \
  > "$_t1_r/.prflow/config.json"
_t1_out="$("$T1_SCAFFOLD" "$_t1_r" 2>&1)"
assert_eq "#1002 both-present (differing): NEITHER block is changed" "42 99" \
  "$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(d["devflow_review"]["max_iterations"], d["prflow_review"]["max_iterations"])' "$_t1_r/.prflow/config.json" 2>/dev/null)"
assert_eq "#1002 both-present (differing): the conflict is reported" "yes" \
  "$(_t1_has "$_t1_out" 'NOT migrating devflow_review')"
assert_eq "#1002 both-present (differing): the report names BOTH resolutions available" "yes yes" \
  "$(_t1_has "$_t1_out" 'delete the devflow_review block') $(_t1_has "$_t1_out" 'delete the prflow_review block')"

# Idempotency: a config already on the new names is left byte-identical.
_t1_r="$(_t1_root)"; mkdir -p "$_t1_r/.prflow" "$_t1_r/.github/workflows"
cp "$T1_EXAMPLE" "$_t1_r/.prflow/config.json"
_t1_before="$(shasum "$_t1_r/.prflow/config.json" | cut -d' ' -f1)"
_t1_out="$("$T1_SCAFFOLD" "$_t1_r" 2>&1)"
assert_eq "#1002 scaffolder: an already-migrated config is left byte-identical" \
  "$_t1_before" "$(shasum "$_t1_r/.prflow/config.json" | cut -d' ' -f1)"
assert_eq "#1002 scaffolder: an already-migrated config produces no migration lines" "0" \
  "$(printf '%s\n' "$_t1_out" | grep -cE 'migrated superseded config key|NOT migrating')"

# The scaffolder operates IN PLACE on a superseded directory rather than scaffolding a
# second one beside it — the worst outcome available here.
_t1_r="$(_t1_root)"; mkdir -p "$_t1_r/.devflow" "$_t1_r/.github/workflows"
printf '%s' '{"devflow":{"allowed_bots":"botA"}}' > "$_t1_r/.devflow/config.json"
"$T1_SCAFFOLD" "$_t1_r" >/dev/null 2>&1
assert_eq "#1002 scaffolder: it does NOT create a second state directory beside a superseded one" "no" \
  "$( [ -d "$_t1_r/.prflow" ] && printf 'yes' || printf 'no' )"
assert_eq "#1002 scaffolder: it migrated the config IN PLACE in the superseded directory" "yes" \
  "$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print("yes" if "prflow" in d else "no")' "$_t1_r/.devflow/config.json" 2>/dev/null)"

# ────────────────────────────────────────────────────────────────────────────
echo "#1002 F. migrate-consumer-tier1.sh: the atomic unit"
# ────────────────────────────────────────────────────────────────────────────
# PREVIEW writes nothing. install.sh upgrades are dry-run by default, so this is the
# mode every existing consumer meets first, and a report claiming a migration a
# preview never performed is the failure this row exists to catch.
_t1_r="$(_t1_old_consumer)"; _t1_before="$(_t1_snap "$_t1_r")"
_t1_out="$("$T1_MIGRATE" "$_t1_r" 2>&1)"; _t1_rc=$?
assert_eq "#1002 migrate: a preview exits 0" "0" "$_t1_rc"
assert_eq "#1002 migrate: a preview leaves the repository byte-identical" \
  "$_t1_before" "$(_t1_snap "$_t1_r")"
assert_eq "#1002 migrate: the preview says nothing was written" "yes" \
  "$(_t1_has "$_t1_out" 'nothing was written')"
assert_eq "#1002 migrate: the preview is labelled distinctly from an applied run" "yes no" \
  "$(_t1_has "$_t1_out" 'PREVIEW') $(_t1_has "$_t1_out" 'APPLIED')"
assert_eq "#1002 migrate: the preview enumerates all four members of the atomic unit" "4" \
  "$(printf '%s\n' "$_t1_out" | grep -c 'will migrate')"

# APPLY: every member lands together.
_t1_r="$(_t1_old_consumer)"
_t1_out="$("$T1_MIGRATE" --apply --pin v9.9.9 "$_t1_r" 2>&1)"; _t1_rc=$?
assert_eq "#1002 migrate: an apply exits 0" "0" "$_t1_rc"
assert_eq "#1002 migrate: the applied run is labelled distinctly from a preview" "yes no" \
  "$(_t1_has "$_t1_out" 'APPLIED') $(_t1_has "$_t1_out" 'nothing was written')"
assert_eq "#1002 migrate member 1: the state directory moved" "yes yes" \
  "$( [ -d "$_t1_r/.prflow" ] && printf 'yes' || printf 'no' ) $( [ -d "$_t1_r/.devflow" ] && printf 'no' || printf 'yes' )"
assert_eq "#1002 migrate member 1: the inner vendored directory moved too" "yes" \
  "$( [ -d "$_t1_r/.prflow/vendor/prflow" ] && printf 'yes' || printf 'no' )"
assert_eq "#1002 migrate member 2: the workflow body no longer names the superseded path" "no" \
  "$(_t1_has "$(cat "$_t1_r/.github/workflows/devflow.yml")" '.devflow/vendor/devflow')"
assert_eq "#1002 migrate member 3: the marketplace source points at the current vendor dir" \
  "./.prflow/vendor/prflow" \
  "$(python3 -c '
import json,sys
print(json.load(open(sys.argv[1]))["plugins"][0]["source"])' "$_t1_r/.claude-plugin/marketplace.json" 2>/dev/null)"
assert_eq "#1002 migrate member 4: the version pin is renamed AND advanced to the given ref" "v9.9.9" \
  "$(python3 -c '
import json,sys
print(json.load(open(sys.argv[1]))["prflow_version"])' "$_t1_r/.prflow/config.json" 2>/dev/null)"
assert_eq "#1002 migrate member 4: the superseded pin key is gone" "False" \
  "$(python3 -c '
import json,sys
print("devflow_version" in json.load(open(sys.argv[1])))' "$_t1_r/.prflow/config.json" 2>/dev/null)"
# The whole-tree emptiness assertion the acceptance criterion asks for: a post-migration
# consumer contains NO reference to the old vendored path, anywhere.
assert_eq "#1002 migrate: no file in the migrated tree names the superseded vendored path" "0" \
  "$(grep -rl '\.devflow/vendor/devflow' "$_t1_r" 2>/dev/null | grep -cv '/\.git/')"
assert_eq "#1002 migrate: the staging directory and the commit journal are both removed" "no no" \
  "$( [ -e "$_t1_r/.prflow.migrate-stage" ] && printf 'yes' || printf 'no' ) $( [ -e "$_t1_r/.prflow.migrate-journal" ] && printf 'yes' || printf 'no' )"
# FROZEN controls over the migrated tree.
assert_eq "#1002 migrate FROZEN: workflows.{devflow,devflow-review} survive the migration" \
  "devflow devflow-review" \
  "$(python3 -c '
import json,sys
print(" ".join(json.load(open(sys.argv[1]))["workflows"]))' "$_t1_r/.prflow/config.json" 2>/dev/null)"
assert_eq "#1002 migrate FROZEN: the workpad marker VALUE is not rewritten" "<!-- devflow:workpad -->" \
  "$(python3 -c '
import json,sys
print(json.load(open(sys.argv[1]))["prflow"]["workpad_marker"])' "$_t1_r/.prflow/config.json" 2>/dev/null)"
assert_eq "#1002 migrate FROZEN: the workflow FILENAMES are unchanged" "yes" \
  "$( [ -f "$_t1_r/.github/workflows/devflow.yml" ] && printf 'yes' || printf 'no' )"
assert_eq "#1002 migrate FROZEN: a learnings record moves with its bytes intact" '{"frozen":"record"}' \
  "$(cat "$_t1_r/.prflow/learnings/r.jsonl" 2>/dev/null)"

# Idempotency: a second run over a migrated tree is a byte-identical no-op.
_t1_before="$(_t1_snap "$_t1_r")"
_t1_out="$("$T1_MIGRATE" --apply --pin v9.9.9 "$_t1_r" 2>&1)"; _t1_rc=$?
assert_eq "#1002 migrate: a re-run over a migrated tree exits 0" "0" "$_t1_rc"
assert_eq "#1002 migrate: a re-run over a migrated tree changes nothing" \
  "$_t1_before" "$(_t1_snap "$_t1_r")"
assert_eq "#1002 migrate: a re-run says the tree is already migrated" "yes" \
  "$(_t1_has "$_t1_out" 'ALREADY MIGRATED')"

# A repository with no state directory at all is a first-time install, not an
# un-migrated consumer — a distinct report, never "migrated 0 items".
_t1_r="$(_t1_root)"
_t1_out="$("$T1_MIGRATE" --apply --pin v1 "$_t1_r" 2>&1)"; _t1_rc=$?
assert_eq "#1002 migrate: a repository with no state directory exits 0" "0" "$_t1_rc"
assert_eq "#1002 migrate: it is reported as nothing-to-migrate, not as a migration" "yes no" \
  "$(_t1_has "$_t1_out" 'NOTHING TO MIGRATE') $(_t1_has "$_t1_out" 'APPLIED')"

# ────────────────────────────────────────────────────────────────────────────
echo "#1002 G. the atomic unit is ALL-OR-NOTHING (per-member induced blockers)"
# ────────────────────────────────────────────────────────────────────────────
# THE LOAD-BEARING FAMILY. One arm per member of the atomic unit: make THAT member
# alone unsatisfiable, run the migration, and assert the whole set was refused and the
# repository is byte-identical. Four RED arms if the apply is not transactional — which
# is what makes "no member can be applied without the others" an executable claim
# rather than a prose one.
_t1_blocked_member() {
  local member="$1" r before after out rc
  r="$(_t1_old_consumer)"
  set -- --apply --pin v9.9.9
  case "$member" in
    state-dir-move)             mkdir -p "$r/.prflow.migrate-stage" ;;
    workflow-content-rewrite)   chmod a-w "$r/.github/workflows/devflow.yml" ;;
    marketplace-source-rewrite) chmod a-w "$r/.claude-plugin/marketplace.json" ;;
    version-pin-advance)        set -- --apply ;;
  esac
  before="$(_t1_snap "$r")"
  out="$("$T1_MIGRATE" "$@" "$r" 2>&1)"; rc=$?
  after="$(_t1_snap "$r")"
  chmod -R u+w "$r" 2>/dev/null || true
  assert_eq "#1002 all-or-nothing [$member]: the run REFUSES" "1" "$rc"
  assert_eq "#1002 all-or-nothing [$member]: the repository is byte-identical" "$before" "$after"
  assert_eq "#1002 all-or-nothing [$member]: the report names the blocked member" "yes" \
    "$(_t1_has "$out" "$member")"
  assert_eq "#1002 all-or-nothing [$member]: the state directory did NOT move" "yes no" \
    "$( [ -d "$r/.devflow" ] && printf 'yes' || printf 'no' ) $( [ -d "$r/.prflow" ] && printf 'yes' || printf 'no' )"
  assert_eq "#1002 all-or-nothing [$member]: the marketplace source was NOT rewritten" "yes" \
    "$(_t1_has "$(cat "$r/.claude-plugin/marketplace.json" 2>/dev/null)" '.devflow/vendor/devflow')"
}
for _t1_m in state-dir-move workflow-content-rewrite marketplace-source-rewrite version-pin-advance; do
  _t1_blocked_member "$_t1_m"
done

# A tree carrying BOTH directories is mid-migration or hand-migrated: refuse rather
# than move one inside the other (a bare `mv` would nest them).
_t1_r="$(_t1_old_consumer)"; mkdir -p "$_t1_r/.prflow"
_t1_before="$(_t1_snap "$_t1_r")"
_t1_out="$("$T1_MIGRATE" --apply --pin v1 "$_t1_r" 2>&1)"; _t1_rc=$?
assert_eq "#1002 all-or-nothing: both directories present REFUSES" "1" "$_t1_rc"
assert_eq "#1002 all-or-nothing: both directories present leaves the tree byte-identical" \
  "$_t1_before" "$(_t1_snap "$_t1_r")"
assert_eq "#1002 all-or-nothing: the both-present refusal states the two operator exits" "yes yes" \
  "$(_t1_has "$_t1_out" 'merge the two directories') $(_t1_has "$_t1_out" 'delete the incomplete')"

# A leftover commit journal means a previous run died inside the destructive window.
# That is detectable and refused, rather than silently half-done.
_t1_r="$(_t1_old_consumer)"; : > "$_t1_r/.prflow.migrate-journal"
_t1_before="$(_t1_snap "$_t1_r")"
_t1_out="$("$T1_MIGRATE" --apply --pin v1 "$_t1_r" 2>&1)"; _t1_rc=$?
assert_eq "#1002 all-or-nothing: a leftover commit journal REFUSES" "1" "$_t1_rc"
assert_eq "#1002 all-or-nothing: a leftover journal leaves the tree byte-identical" \
  "$_t1_before" "$(_t1_snap "$_t1_r")"
assert_eq "#1002 all-or-nothing: the journal refusal names the journal path" "yes" \
  "$(_t1_has "$_t1_out" '.prflow.migrate-journal')"

# A stale-but-unparseable marketplace.json is a blocker, not a silent skip.
_t1_r="$(_t1_old_consumer)"
printf '%s' '{"plugins":[{"source":"./.devflow/vendor/devflow" BROKEN' \
  > "$_t1_r/.claude-plugin/marketplace.json"
_t1_before="$(_t1_snap "$_t1_r")"
_t1_out="$("$T1_MIGRATE" --apply --pin v1 "$_t1_r" 2>&1)"; _t1_rc=$?
assert_eq "#1002 all-or-nothing: a stale but unparseable marketplace.json REFUSES" "1" "$_t1_rc"
assert_eq "#1002 all-or-nothing: the unparseable-marketplace refusal is byte-identical" \
  "$_t1_before" "$(_t1_snap "$_t1_r")"
assert_eq "#1002 all-or-nothing: the refusal names JSON validity as the cause" "yes" \
  "$(_t1_has "$_t1_out" 'not valid JSON')"

# The migration reports what it could NOT migrate, naming each item individually.
_t1_r="$(_t1_old_consumer)"
printf 'run: .devflow/vendor/devflow/scripts/filter-runner-tools.sh\n' \
  > "$_t1_r/.github/workflows/devflow-runner.yml"
_t1_out="$("$T1_MIGRATE" "$_t1_r" 2>&1)"
assert_eq "#1002 migrate: an unshipped retained workflow is named in the could-not-migrate report" "yes" \
  "$(_t1_has "$_t1_out" 'could not migrate')"
assert_eq "#1002 migrate: the could-not-migrate entry names the specific file" "yes" \
  "$(_t1_has "$_t1_out" 'devflow-runner.yml')"

# ────────────────────────────────────────────────────────────────────────────
echo "#1002 H. the workflow config-job per-family fail-loud guard"
# ────────────────────────────────────────────────────────────────────────────
# The trigger-time channel reads config through inline jq and never through
# config-get.sh, so the resolver's breadcrumb cannot reach it. The selector is driven
# directly over the adversarial shape matrix, because a grep-pin on the ::error::
# literal is not coverage of the branch that chooses it.
_t1_guard='if type != "object" then $fams | split(" ") | join(" ") else ($fams | split(" ")) - [keys[]] | join(" ") end'
_t1_fams="prflow prflow_version"
_t1_missing() { printf '%s' "$1" | jq -r --arg fams "$_t1_fams" "$_t1_guard" 2>/dev/null; }

assert_eq "#1002 family guard: every family present reports nothing missing" "" \
  "$(_t1_missing '{"prflow":{},"prflow_version":"x"}')"
assert_eq "#1002 family guard: an un-migrated config reports BOTH families missing" \
  "prflow prflow_version" "$(_t1_missing '{"devflow":{},"devflow_version":"x"}')"
assert_eq "#1002 family guard: one absent family is named alone" "prflow_version" \
  "$(_t1_missing '{"prflow":{}}')"
# FAMILY granularity, not leaf: the schema marks none of the optional leaves required,
# so a consumer who never set one must be unaffected.
assert_eq "#1002 family guard: a present family with absent optional leaves is silent" "" \
  "$(_t1_missing '{"prflow":{},"prflow_version":""}')"
assert_eq "#1002 family guard: a present family holding null is silent (the key exists)" "" \
  "$(_t1_missing '{"prflow":null,"prflow_version":"x"}')"
# Fail CLOSED on every non-object root: a hand-corrupted config must not read as clean.
for _t1_shape in '["a"]' '"hello"' 'null' '42'; do
  assert_eq "#1002 family guard: a non-object root ($_t1_shape) fails closed" \
    "prflow prflow_version" "$(_t1_missing "$_t1_shape")"
done

# The guard is wired into both SHIPPED workflows, on the same side of the enable gate
# as the pre-existing allowed_bots guard (an intentionally-disabled repo is never
# failed). Asserted by driving the file's own text for the ordering relationship.
for _t1_wf in devflow devflow-implement; do
  _t1_body="$(cat "$LIB/../.github/workflows/$_t1_wf.yml" 2>/dev/null)"
  assert_eq "#1002 family guard: $_t1_wf.yml carries the per-family guard" "yes" \
    "$(_t1_has "$_t1_body" 'MISSING_FAMILIES')"
  assert_eq "#1002 family guard: $_t1_wf.yml gates it on the workflow being enabled" "yes" \
    "$(_t1_has "$_t1_body" 'if [ "$ENABLED" = "true" ]; then')"
  assert_eq "#1002 family guard: $_t1_wf.yml routes the operator to /prflow:init" "yes" \
    "$(_t1_has "$_t1_body" 'run /prflow:init to migrate the whole Tier 1 set')"
done
