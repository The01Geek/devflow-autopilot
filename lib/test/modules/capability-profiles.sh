# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# shellcheck shell=bash
# Sourceable capability-profiles contract module (issue #591 seed extraction).
# Contract: the caller sets LIB and RESULTS_FILE, defines assert_eq, and sources
# lib/test/module-harness.sh first (which defines the namespaced module pin API:
# devflow_module_pin_count / devflow_module_pin_unique / devflow_module_pin_present /
# devflow_module_pin_red_under). This module uses assert_eq plus its two domain-private
# helpers below (_cap_fail, _cap_noncomment_hits) — it references NO monolith helper.
# The module owns its private fixture root and cleanup; it never invokes the runner
# or the full-suite boundary. The inventory in capability-profiles.inventory.md maps
# the extracted coverage to its former run.sh locations. Modules may not self-skip.
# The `trap _cap_cleanup EXIT` below relies on a sourcing contract: both callers
# (module-harness.sh's full-suite boundary and run-module.sh) source this module
# inside a ( ... ) subshell, so the trap fires at subshell exit and cannot clobber
# the runner's own EXIT handling. Do not source this module directly in a runner's
# top-level shell without restoring the trap.

# Every consumed repository path is derived from LIB (the #561 generator, the manifest,
# the review-profile lock, the cap-mutate fixture-mutator, and the workflows dir) — the
# module never reads a path variable initialized by the monolith.
CAPGEN="$LIB/generate-capability-profiles.py"
CAPMUT="$LIB/test/cap-mutate.py"
CAP_WF_DIR="$LIB/../.github/workflows"

_cap_tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/devflow-capability-profiles.XXXXXX")" || {
  printf 'could not allocate capability-profiles fixture\n' >&2
  return 1
}
_cap_cleanup() {
  rm -rf "$_cap_tmp_root"
}
trap _cap_cleanup EXIT

# ────────────────────────────────────────────────────────────────────────────
echo "#561 capability-profile manifest generator (extracted to capability-profiles module)"
# ────────────────────────────────────────────────────────────────────────────
# The #450 coupled-mirror pin (matcher-probe IMPLEMENT ↔ devflow-implement.yml baked
# TOOLS token-sync) was DELETED under the coupled-invariant same-change rule when #561
# landed: both that equality AND the previously-unpinned review-tier equality (runner
# review ↔ probe REVIEW) are now covered by lib/generate-capability-profiles.py --check,
# which byte-compares every generated region (banner included) against
# lib/capability-profiles.json. The generator is the single source of truth; the suite
# drives its --check so the required `lib + python tests` CI job gates every PR.

# T2/T10 — --check on the REAL committed tree is a clean pass: exit 0, empty stdout
# (python3 as the leading token, per the AC). A drifted region turns THIS suite RED.
CAP_CHECK_OUT="$(python3 "$CAPGEN" --check 2>/dev/null)"; CAP_CHECK_RC=$?
assert_eq "#561 --check on the committed tree exits 0" "0" "$CAP_CHECK_RC"
assert_eq "#561 --check on the committed tree prints empty stdout" "" "$CAP_CHECK_OUT"

# T11 — the generator is python3 stdlib-only (imports no yaml module). Count through the
# module's fail-closed devflow_module_pin_count (an unreadable read → `unestablished` → the
# 0-expected assert_eq goes RED) rather than a raw `grep -c` that fails open to 0.
assert_eq "#561 T11 generator imports no 'yaml' module (stdlib-only)" "0" \
  "$(devflow_module_pin_count 'import yaml' "$CAPGEN")"

# Build an isolated fixture mirroring the repo layout; the generator resolves its paths
# from __file__, so a copy under <root>/lib runs against <root>/.github/workflows. Every
# fixture root is allocated UNDER the module's private tmp root so the EXIT trap is a
# guaranteed backstop even if a per-assertion `rm -rf` is skipped on an early return.
_cap_fixture() {  # <root>
  mkdir -p "$1/lib" "$1/.github/workflows"
  cp "$CAPGEN" "$LIB/capability-profiles.json" "$LIB/review-profile.tokens" "$1/lib/"
  cp "$CAP_WF_DIR/devflow-runner.yml" "$CAP_WF_DIR/devflow.yml" \
     "$CAP_WF_DIR/devflow-implement.yml" "$CAP_WF_DIR/matcher-probe.yml" "$1/.github/workflows/"
}
_cap_wf_snap() { cat "$1/.github/workflows/"*.yml 2>/dev/null; }

# Fail-closed matrix + planted-defect driver: apply a named mutation (the visible
# "mutation command" per the behavioral-fix-pin evidence rule), run the generator in
# <mode> (check|generate), and assert rc!=0 AND the stderr breadcrumb contains <substr>
# AND (when <unchanged> is passed) the target workflow bytes are byte-unchanged.
_cap_fail() {  # name mutation mode substr [unchanged]
  local name="$1" mut="$2" mode="$3" sub="$4" chk="${5:-}" root rc before after v=yes
  root="$(mktemp -d "$_cap_tmp_root/fixture.XXXXXX")" || { echo FAIL >> "$RESULTS_FILE"; printf '  FAIL  %s (mktemp)\n' "$name"; return; }
  _cap_fixture "$root"
  if ! python3 "$CAPMUT" "$root" "$mut" 2>"$root/.muterr"; then
    echo FAIL >> "$RESULTS_FILE"
    printf '  FAIL  %s (mutation itself failed: %s)\n' "$name" "$(cat "$root/.muterr")"
    rm -rf "$root"; return
  fi
  before="$(_cap_wf_snap "$root")"
  if [ "$mode" = check ]; then
    python3 "$root/lib/generate-capability-profiles.py" --check >/dev/null 2>"$root/.err"; rc=$?
  else
    python3 "$root/lib/generate-capability-profiles.py" >/dev/null 2>"$root/.err"; rc=$?
  fi
  after="$(_cap_wf_snap "$root")"
  [ "$rc" -ne 0 ] || v="no(rc=0, expected non-zero)"
  grep -qF "$sub" "$root/.err" || v="no(breadcrumb '$sub' missing; stderr: $(tr '\n' '|' <"$root/.err"))"
  if [ "$chk" = unchanged ] && [ "$before" != "$after" ]; then v="no(target bytes changed by a failed run)"; fi
  assert_eq "$name" "yes" "$v"
  rm -rf "$root"
}

# T6 — the manifest adversarial matrix (config-JSON-consumer six-shape convention + surface
# rows). Each asserts non-zero + a defect-naming breadcrumb + target bytes unchanged.
_cap_fail "#561 T6 manifest: top-level array"                 top-array          generate "top-level must be a JSON object" unchanged
_cap_fail "#561 T6 manifest: top-level scalar"               top-scalar         generate "top-level must be a JSON object" unchanged
_cap_fail "#561 T6 manifest: profiles missing"               profiles-missing   generate "'profiles' must be a JSON object" unchanged
_cap_fail "#561 T6 manifest: profiles wrong-type"            profiles-wrongtype generate "'profiles' must be a JSON object" unchanged
_cap_fail "#561 T6 manifest: unknown group reference"        unknown-group      generate "references unknown group" unchanged
_cap_fail "#561 T6 manifest: duplicate resolved token"       dup-token          generate "duplicate resolved token" unchanged
_cap_fail "#561 T6 manifest: empty resolved profile"         empty-profile      generate "empty token list" unchanged
_cap_fail "#561 T6 manifest: valid-falsy node (group=false)" falsy-group        generate "must be a list" unchanged
_cap_fail "#561 T6 manifest: manifest_version string-typed"  version-string     generate "'manifest_version' must be an integer" unchanged
_cap_fail "#561 T6 manifest: review widens beyond the lock"  review-widen       generate "lib/review-profile.tokens" unchanged
_cap_fail "#561 T6 manifest: review-profile lock absent"     lock-absent        generate "lock absent" unchanged
_cap_fail "#561 T6 manifest: review leading tokens != Read,Glob,Grep" review-leading generate "leading-token contract" unchanged
_cap_fail "#561 T6 manifest: malformed JSON"                 malformed-json     generate "malformed JSON" unchanged
_cap_fail "#561 T6 manifest: manifest file absent"           manifest-absent    generate "manifest absent" unchanged
# The review-widen row is also the reviewer-boundary planted defect: the added token is
# named and the lock is named as the boundary (proving a group-content edit cannot widen
# the reviewer silently).
_cap_fail "#561 reviewer boundary: widening token is named in the breadcrumb" review-widen generate "Bash(WIDEN_REVIEWER:*)" unchanged

# T7 — the region matrix (parser over hand-corruptible workflow text). Each asserts
# non-zero + breadcrumb + the target files left byte-unchanged after the failed run.
_cap_fail "#561 T7 region: anchor absent"                anchor-absent          generate "anchor REVIEW=' not found" unchanged
_cap_fail "#561 T7 region: anchor duplicated"            anchor-duplicated      generate "is duplicated" unchanged
_cap_fail "#561 T7 region: implement quote unterminated" implement-unterminated generate "unterminated quote or missing" unchanged
_cap_fail "#561 T7 region: splice expression absent"     splice-absent          generate "unterminated quote or missing" unchanged
_cap_fail "#561 T7 region: CRLF line ending in a region" crlf-in-region         generate "CRLF line ending" unchanged
_cap_fail "#561 T7 region: target workflow file absent"  target-file-absent     generate "target workflow file absent" unchanged
_cap_fail "#561 T7 region: banner present but malformed" banner-malformed       generate "banner line for this region is present but malformed" unchanged

# T3 — planted-defect positive controls: one token deleted from EACH
# generated region → --check RED naming that exact region.
_cap_fail "#561 T3 planted: token deleted from runner-review region"   del-runner-review   check "region=runner-review"
_cap_fail "#561 T3 planted: token deleted from command region"        del-command         check "region=command"
_cap_fail "#561 T3 planted: token deleted from implement region"      del-implement       check "region=implement"
_cap_fail "#561 T3 planted: token deleted from probe-review region"    del-probe-review    check "region=probe-review"
_cap_fail "#561 T3 planted: token deleted from probe-implement region" del-probe-implement check "region=probe-implement"
# T4 — a token added to the manifest without regenerating → --check RED.
_cap_fail "#561 T4 planted: manifest token added without regenerating" manifest-add-nonreview check "region=command"
# T5 — one banner checksum hex digit flipped → --check RED.
_cap_fail "#561 T5 planted: banner checksum digit flipped" banner-flip check "region=runner-review"

# T12 — directional --check output on a token HAND-ADDED to a generated region: the
# stderr must name that exact workflow-side token AND print the add-to-manifest remedy
# (steering away from blind regeneration, which would silently revert the grant).
CAP_T12="$(mktemp -d "$_cap_tmp_root/t12.XXXXXX")"; _cap_fixture "$CAP_T12"
python3 "$CAPMUT" "$CAP_T12" region-add-token >/dev/null 2>&1
python3 "$CAP_T12/lib/generate-capability-profiles.py" --check >/dev/null 2>"$CAP_T12/.err"; CAP_T12_RC=$?
assert_eq "#561 T12 directional: --check rc non-zero on a hand-added region token" "yes" \
  "$([ "$CAP_T12_RC" -ne 0 ] && echo yes || echo no)"
assert_eq "#561 T12 directional: --check names the exact workflow-side token" "yes" \
  "$(grep -qF 'Bash(HANDADDED:*)' "$CAP_T12/.err" && echo yes || echo no)"
assert_eq "#561 T12 directional: --check prints the add-to-manifest remedy (not blind regenerate)" "yes" \
  "$(grep -qF 'add it to lib/capability-profiles.json' "$CAP_T12/.err" && echo yes || echo no)"
rm -rf "$CAP_T12"

# T1 — idempotency + locale/cwd determinism: strip the banners, generate under LC_ALL=C,
# then generate again under a different LC_ALL AND cwd; cmp every workflow byte-identical.
# Also assert the committed workflows equal the generator's output (committed == generated).
CAP_IDEM="$(mktemp -d "$_cap_tmp_root/idem.XXXXXX")"; _cap_fixture "$CAP_IDEM"
# Assert the strip-banners precondition was actually exercised. strip-banners uses
# expect_change=False (it sweeps every workflow), so a silent no-op — e.g. the banner
# format drifting out from under its regex — returns rc 0 and would leave T1 green while
# its "regenerate onto banner-less workflows" premise never happened. Guard both arms:
# the mutation must exit 0 AND it must have actually removed bytes (snapshot changed).
CAP_IDEM_PRE="$(_cap_wf_snap "$CAP_IDEM")"
python3 "$CAPMUT" "$CAP_IDEM" strip-banners >/dev/null 2>"$CAP_IDEM/.muterr"; CAP_IDEM_STRIP_RC=$?
assert_eq "#561 T1 strip-banners precondition exercised (rc 0 AND banners actually removed)" "yes" \
  "$([ "$CAP_IDEM_STRIP_RC" -eq 0 ] && [ "$CAP_IDEM_PRE" != "$(_cap_wf_snap "$CAP_IDEM")" ] && echo yes || echo no)"
( cd "$CAP_IDEM" && LC_ALL=C python3 lib/generate-capability-profiles.py >/dev/null 2>&1 )
mkdir -p "$CAP_IDEM/after1"; cp "$CAP_IDEM/.github/workflows/"*.yml "$CAP_IDEM/after1/"
( cd "$CAP_IDEM/lib" && LC_ALL=C.UTF-8 python3 generate-capability-profiles.py >/dev/null 2>&1 ); CAP_IDEM_RC=$?
assert_eq "#561 T1 second generation exits 0" "0" "$CAP_IDEM_RC"
CAP_IDEM_V=yes
for f in devflow-runner.yml devflow.yml devflow-implement.yml matcher-probe.yml; do
  cmp -s "$CAP_IDEM/after1/$f" "$CAP_IDEM/.github/workflows/$f" || CAP_IDEM_V="no($f differs across runs)"
done
assert_eq "#561 T1 generator idempotent + locale/cwd-deterministic (cmp per file)" "yes" "$CAP_IDEM_V"
CAP_IDEM_MATCH=yes
for f in devflow-runner.yml devflow.yml devflow-implement.yml matcher-probe.yml; do
  cmp -s "$CAP_IDEM/.github/workflows/$f" "$CAP_WF_DIR/$f" || CAP_IDEM_MATCH="no($f != committed)"
done
assert_eq "#561 committed workflows are byte-identical to the generator's output" "yes" "$CAP_IDEM_MATCH"
rm -rf "$CAP_IDEM"

# T8 — no-runtime-read: no workflow reads policy from the manifest at run
# time. The assertion greps for the two policy-source filenames in NON-COMMENT content
# only (comment lines — the banner comments and the maintenance comments that now name
# the manifest — are stripped first, so a workflow may reference the manifest in prose
# without tripping this). A hit in run:/uses: content is an actual invocation. The
# positive control proves it fires on an invocation line; the negative control proves a
# comment line that DOES name the manifest is NOT flagged (comment-awareness).
_cap_noncomment_hits() {  # <file> -> prints "yes" if a non-comment line names a policy source
  grep -vE '^[[:space:]]*#' "$1" \
    | grep -qE 'generate-capability-profiles\.py|capability-profiles\.json' && echo yes || echo no
}
CAP_RT_HITS=0
for f in devflow.yml devflow-runner.yml devflow-implement.yml devflow-review.yml telemetry-push.yml matcher-probe.yml; do
  [ "$(_cap_noncomment_hits "$CAP_WF_DIR/$f")" = yes ] && CAP_RT_HITS=$((CAP_RT_HITS+1))
done
assert_eq "#561 T8 no workflow reads policy from the manifest at run time (zero non-comment hits)" "0" "$CAP_RT_HITS"
CAP_RT_POS="$(mktemp "$_cap_tmp_root/rtpos.XXXXXX")"; printf '      - run: python3 lib/generate-capability-profiles.py --check\n' > "$CAP_RT_POS"
assert_eq "#561 T8 assertion fires on a real invocation line (positive control)" "yes" \
  "$(_cap_noncomment_hits "$CAP_RT_POS")"
CAP_RT_NEG="$(mktemp "$_cap_tmp_root/rtneg.XXXXXX")"; printf '              # see lib/capability-profiles.json — generated by generate-capability-profiles.py\n' > "$CAP_RT_NEG"
assert_eq "#561 T8 assertion does NOT fire on a comment naming the manifest (negative control, comment-aware)" "no" \
  "$(_cap_noncomment_hits "$CAP_RT_NEG")"
rm -f "$CAP_RT_POS" "$CAP_RT_NEG"

# T13 — #561 review-follow-up hardening (PR #588 review-and-fix).
# T13a/b: an injected DUPLICATE anchor (a second `TOOLS='…widened…'` assign, or a second
# `--allowed-tools` marker) wins at bash/action runtime while a first-match parse would
# inspect only the canonical leading copy. generate already refuses this ("refusing to
# guess"); --check must refuse it too or the reviewer boundary widens past the gate. Both
# region kinds (assign + implement) are exercised so neither dup-guard branch is vacuous.
_cap_fail "#561 T13a --check refuses a duplicated assign anchor (reviewer-boundary vector)" anchor-duplicated    check "is duplicated"
_cap_fail "#561 T13b --check refuses a duplicated implement marker"                        implement-marker-dup check "is duplicated"
# T13c: manifest_version bumped without regenerating → token lists still match and the
# banner sha still matches, so ONLY the found_ver==version conjunct catches it. Without
# this row that conjunct is vacuously covered (a regression dropping it would stay green).
_cap_fail "#561 T13c --check flags a stale banner when manifest_version is bumped w/o regen" version-bump check "banner is stale"
# T13d: a present-but-unreadable lock (a directory in its place) → the read must fail
# closed with the documented breadcrumb, not an uncaught OSError traceback.
_cap_fail "#561 T13d review-profile lock unreadable (fail-closed breadcrumb, not traceback)" lock-unreadable generate "lock unreadable" unchanged
# T13e: manifest_version boolean-typed → the explicit isinstance(ver, bool) guard rejects
# it (bool is an int subclass, so a bare isinstance(int) would wrongly accept it).
_cap_fail "#561 T13e manifest_version boolean-typed is rejected as a non-integer"            version-bool    generate "'manifest_version' must be an integer" unchanged
# T13f: review NARROWS below the lock (a review-referenced group loses a non-leading token
# while the lock keeps it) → the boundary check's missing-direction ('would NARROW') arm,
# the sibling of the review-widen row, observes RED.
_cap_fail "#561 T13f review narrows below the lock (missing-direction boundary drift)"       review-narrow   generate "would NARROW the reviewer" unchanged
# T13g/p/q: an injected second assignment that WINS at bash runtime (last-assignment-wins)
# must be refused by --check regardless of how it is separated or quoted — the reviewer-
# boundary widening vector. A statement-position assignment wins whether separated by `;`
# (T13g), plain WHITESPACE (T13p — a bare second assignment word on one simple command),
# or placed on a fresh line in a DIFFERENT quote style (T13q — a double-quoted literal that
# leaves the canonical single-quote line, and thus the banner sha/lock/parse, intact). The
# pre-fix line-anchored single-quote count missed all three; the quote/separator-agnostic
# replacement counter (excluding only the self-referencing `TOOLS="$TOOLS,…"` append)
# refuses each (PR #588 shadow: code-reviewer + silent-failure-hunter).
_cap_fail "#561 T13g --check refuses a SAME-LINE ;-separated duplicated assign (reviewer-boundary vector)" anchor-dup-sameline check "is duplicated"
_cap_fail "#561 T13p --check refuses a WHITESPACE-separated duplicated assign word"                        anchor-dup-space    check "is duplicated"
_cap_fail "#561 T13q --check refuses a DOUBLE-QUOTED literal replacement assignment"                       anchor-dup-dquote   check "is duplicated"
# T13h–n: the manifest-validation adversarial matrix arms that had no mutation — a
# regression deleting any of these fail-closed guards would otherwise ship green (the
# CLAUDE.md best-effort-parser six-shape convention over every manifest read, PR #588).
_cap_fail "#561 T13h manifest_version missing"                    version-missing        generate "'manifest_version' is missing" unchanged
_cap_fail "#561 T13i groups missing / non-object"                 groups-missing         generate "'groups' must be a JSON object" unchanged
_cap_fail "#561 T13j group contains a non-string token"           group-nonstring-token  generate "contains a non-string token" unchanged
_cap_fail "#561 T13k profiles key-set != review/implement/command" profiles-extra-key    generate "must contain exactly review/implement/command" unchanged
_cap_fail "#561 T13l profile spec is not a list"                  profile-spec-nonlist   generate "profile 'command' must be a list" unchanged
_cap_fail "#561 T13m profile contains a non-string entry"         profile-nonstring-entry generate "contains a non-string entry" unchanged
_cap_fail "#561 T13n manifest present-but-unreadable (breadcrumb, not traceback)" manifest-unreadable generate "manifest unreadable" unchanged
# T13o: a present-but-unreadable target workflow → read_wf must fail closed with a named
# breadcrumb, not an uncaught OSError traceback (the lock/manifest reads already do).
_cap_fail "#561 T13o target workflow unreadable (breadcrumb, not traceback)"      workflow-unreadable generate "target workflow unreadable" unchanged

# ── issue #555: the implement-tier bundled-helper grant flow is a CLAUDE.md contract the
# generator's --check enforces mechanically — a helper an implement fence invokes is granted
# by adding its vendored-literal token to the manifest's implement profile and regenerating,
# which syncs matcher-probe.yml's IMPLEMENT baseline with devflow-implement.yml's baked
# baseline. Pin the operative clause narrowly (this is the capability-manifest module, never
# a retired #450 block) so a reword that re-legitimizes hand-editing either literal goes RED.
devflow_module_pin_unique "#555 CLAUDE.md documents the implement-tier bundled-helper grant flow" \
  'Implement-tier bundled-helper grant flow (issue #555)' "$LIB/../CLAUDE.md"
devflow_module_pin_unique "#555 CLAUDE.md forbids hand-editing either generated workflow literal for such a grant" \
  '**Never hand-edit either workflow literal** to add such a grant.' "$LIB/../CLAUDE.md"
