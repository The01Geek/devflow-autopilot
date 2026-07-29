# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# shellcheck shell=bash
# Sourceable review/implement trigger-helper contract module (issue #746 tranche).
# Contract: the caller sets LIB and RESULTS_FILE, defines assert_eq, and sources
# lib/test/module-harness.sh before this module.
#
# No private fixture root and no EXIT trap here, deliberately. The extracted sections
# allocate their own fixture trees with bare `mktemp -d` and remove them on their own
# clean paths, exactly as they did inline in lib/test/run.sh — the move preserves that
# behavior rather than adding a second ownership layer. Both callers already allocate a
# boundary-owned scratch root and export TMPDIR to it, and clean it on every path
# including forced termination, so an extra module-level root would be redundant there.
# It would also not be the "complete crash-path backstop" it looks like: a bare
# `mktemp -d` does NOT honor a runtime TMPDIR override on macOS/BSD (it uses the Darwin
# confstr temp dir — the same portability trap lib/test/run-module.sh documents at its
# own mktemp calls), so a redirect could not contain these call sites anyway.


# The one run.sh global the extracted sections read that a module does not
# receive: the config resolver the #329/#409 key-read assertions invoke. The
# monolith binds it identically, from LIB. Left unbound it expands to the empty
# string, so `"$CG" …` runs the empty command and every one of those assertions
# compares against empty output — the failure this binding exists to prevent.
CG="$LIB/../scripts/config-get.sh"

# ────────────────────────────────────────────────────────────────────────────
# RETIRED (issue #936): derive-review-verdict.sh, derive-review-preconditions.sh and
# describe-skip-title.sh.
#
# All three existed solely to serve .github/workflows/devflow-review.yml — the caller of
# the automatic pull-request-triggered review tier. A sole-caller sweep
# (`git grep -ln "<helper>" -- .github/workflows`) resolved each one to that single file,
# and no other surviving surface INVOKES any of them (the remaining mentions across
# scripts/, lib/ and skills/ are prose references, not invocations). Issue #936 withheld
# that tier and deleted its caller, so all three became unreachable shipped code; they are
# deleted with it rather than left as dead code under live assertions, and these sections
# go with them. Their rows in lib/test/modules/coverage-map.json,
# lib/test/modules/review-trigger-helpers.inventory.md and
# scripts/workflow-flight-recorder-registry.json are removed in the same commit.
#
# Nothing replaces the coverage, deliberately: there is no verdict to derive, no
# precondition to evaluate and no deferral title to render once the tier that consumed
# them is gone.
#
# The #353 AC13 fail-closed absence backstop is retired with them, EXPLICITLY. It asserted
# that .github/workflows/devflow-review.yml exists, paired with a `-DOES-NOT-EXIST`
# negative control, precisely so the sibling absence pin could not pass vacuously on a
# missing file. This change makes that assertion's designed RED condition the intended
# state — the file is meant to be gone — so the backstop, its negative control, and the
# "cancelled sibling run" absence pin it backstopped are all removed together. The AC10
# uniqueness pin it protected targeted describe-skip-title.sh, which is deleted here, so it
# is retired rather than re-anchored.
#
# CONTRIBUTING.md "Retiring existence-only pins" arms, walked per removal: the ordered arms
# retain by default, and every consulted row in .devflow/logs/pin-corpus-inventory.tsv
# reads counted_occurrences < 2 with a `boundary` bucket — the retain value. The removals
# here are NOT authorized by those arms and do not claim to be. They rest on the stated
# exemption instead: the arms govern retiring a pin while its PINNED SUBJECT REMAINS in the
# tree, where dropping the pin drops live coverage. Here the subject itself is deleted, so
# there is no behavior left for the pin to protect and no coverage to lose. That exemption
# is claimed explicitly, once, for this whole block rather than assumed silently.
# ────────────────────────────────────────────────────────────────────────────

# ────────────────────────────────────────────────────────────────────────────
echo "parse-engine-error.sh (#249 execution-log is_error parser feeding engine_is_error)"
# ────────────────────────────────────────────────────────────────────────────
# The producer of devflow-runner.yml's engine_is_error output (extracted from the
# inline workflow jq so its array/object/fail-safe branches are verified). Fail-safe:
# any absent/unparseable field yields "false" (is_error is defense-in-depth; the
# deriver's HEAD-SHA scoping is the primary guard).
PEE="$LIB/../scripts/parse-engine-error.sh"
PEE_TMP="$(mktemp -d)"
# stream-json ARRAY where a type==result element carries is_error (any result with is_error=true wins)
printf '%s' '[{"type":"system"},{"type":"result","is_error":true}]'  > "$PEE_TMP/arr_true.json"
printf '%s' '[{"type":"assistant"},{"type":"result","is_error":false}]' > "$PEE_TMP/arr_false.json"
# a single result OBJECT
printf '%s' '{"type":"result","is_error":true}'  > "$PEE_TMP/obj_true.json"
printf '%s' '{"type":"result","is_error":false}' > "$PEE_TMP/obj_false.json"
# JSONL (one object per line, no enclosing array) — the shape a bare `jq` without
# -s would mis-handle; the -s slurp normalizes it.
printf '{"type":"system"}\n{"type":"assistant"}\n{"type":"result","is_error":true}\n'  > "$PEE_TMP/jsonl_true.json"
printf '{"type":"system"}\n{"type":"result","is_error":false}\n'                       > "$PEE_TMP/jsonl_false.json"
# absent is_error field (object AND array-result), empty array, and unparseable -> false
printf '%s' '{"type":"result"}'  > "$PEE_TMP/obj_missing.json"
printf '%s' '[{"type":"system"},{"type":"result"}]' > "$PEE_TMP/arr_missing.json"
printf '%s' '[]'                 > "$PEE_TMP/empty_arr.json"
printf '%s' 'not json {{'        > "$PEE_TMP/garbage.json"
assert_eq "#249 parse-engine-error: array w/ a result is_error=true -> true"  "true"  "$(bash "$PEE" "$PEE_TMP/arr_true.json")"
assert_eq "#249 parse-engine-error: array w/ a result is_error=false -> false" "false" "$(bash "$PEE" "$PEE_TMP/arr_false.json")"
assert_eq "#249 parse-engine-error: single result object is_error=true -> true"   "true"  "$(bash "$PEE" "$PEE_TMP/obj_true.json")"
assert_eq "#249 parse-engine-error: single result object is_error=false -> false" "false" "$(bash "$PEE" "$PEE_TMP/obj_false.json")"
assert_eq "#249 parse-engine-error: JSONL w/ a result is_error=true -> true"  "true"  "$(bash "$PEE" "$PEE_TMP/jsonl_true.json")"
assert_eq "#249 parse-engine-error: JSONL w/ a result is_error=false -> false" "false" "$(bash "$PEE" "$PEE_TMP/jsonl_false.json")"
assert_eq "#249 parse-engine-error: absent is_error field (object) -> false (fail-safe)" "false" "$(bash "$PEE" "$PEE_TMP/obj_missing.json")"
assert_eq "#249 parse-engine-error: absent is_error field (array result) -> false (fail-safe)" "false" "$(bash "$PEE" "$PEE_TMP/arr_missing.json")"
assert_eq "#249 parse-engine-error: empty array (no result) -> false (fail-safe)" "false" "$(bash "$PEE" "$PEE_TMP/empty_arr.json")"
assert_eq "#249 parse-engine-error: unparseable log -> false (fail-safe)"         "false" "$(bash "$PEE" "$PEE_TMP/garbage.json")"
assert_eq "#249 parse-engine-error: missing file arg -> false (fail-safe)"        "false" "$(bash "$PEE" "$PEE_TMP/does-not-exist.json")"
assert_eq "#249 parse-engine-error: empty arg -> false (fail-safe)"               "false" "$(bash "$PEE" "")"
( bash "$PEE" "$PEE_TMP/arr_true.json" >/dev/null 2>&1 ); assert_eq "#249 parse-engine-error: always exits 0 (best-effort)" "0" "$?"
# nested result object (pins the `..` any-depth recursion the header advertises;
# a refactor to top-level-only `.[]` ships RED)
printf '%s' '[{"type":"system","payload":{"type":"result","is_error":true}}]' > "$PEE_TMP/nested_true.json"
assert_eq "#249 parse-engine-error: NESTED result is_error=true -> true (any-depth recursion pinned)" "true" "$(bash "$PEE" "$PEE_TMP/nested_true.json" 2>/dev/null)"
# the type filter is load-bearing in the OTHER direction too: is_error=true on a
# NON-result object (e.g. a tool_result event) must stay false — dropping the
# select(.type=="result") would over-report engine errors and wedge good runs.
printf '%s' '[{"type":"tool_result","is_error":true},{"type":"result","is_error":false}]' > "$PEE_TMP/tool_err.json"
assert_eq "#249 parse-engine-error: is_error=true on a non-result object -> false (type filter pinned)" "false" "$(bash "$PEE" "$PEE_TMP/tool_err.json" 2>/dev/null)"
# ANY-result-wins across MULTIPLE result events (pins any() vs a last-wins
# refactor: an errored mid-stream result followed by a clean final one -> true)
printf '%s' '[{"type":"result","is_error":true},{"type":"result","is_error":false}]' > "$PEE_TMP/two_results.json"
assert_eq "#249 parse-engine-error: two result events [true,false] -> true (ANY-wins pinned, not last-wins)" "true" "$(bash "$PEE" "$PEE_TMP/two_results.json" 2>/dev/null)"
# Truncated-tail JSONL (engine died mid-write): the -s slurp fails on the whole
# file, so even a complete is_error=true line above the truncation reads false
# + the jq-failure breadcrumb. Deliberate, documented trade-off pinned here:
# is_error is defense-in-depth; the deriver's no-verdict-for-HEAD arm is what
# actually fails the crashed run closed.
printf '{"type":"result","is_error":true}\n{"type":"sys' > "$PEE_TMP/trunc_tail.json"
assert_eq "#249 parse-engine-error: truncated-tail JSONL -> false (fail-safe; deriver HEAD-scoping is the real guard)" "false" "$(bash "$PEE" "$PEE_TMP/trunc_tail.json" 2>/dev/null)"
assert_eq "#249 parse-engine-error: truncated-tail JSONL emits the jq-failure breadcrumb" "yes" \
  "$(bash "$PEE" "$PEE_TMP/trunc_tail.json" 2>&1 1>/dev/null | grep -qF "jq failed parsing" && echo yes || echo no)"
# fail-safe arms leave breadcrumbs, never a silent false: a disarmed signal
# (renamed execution_file output, broken jq) must be visible in the job log.
assert_eq "#249 parse-engine-error: missing-file arm emits the 'execution file absent' breadcrumb" "yes" \
  "$(bash "$PEE" "$PEE_TMP/does-not-exist.json" 2>&1 1>/dev/null | grep -qF "execution file absent or empty" && echo yes || echo no)"
assert_eq "#249 parse-engine-error: unparseable-log arm emits the 'jq failed parsing' breadcrumb" "yes" \
  "$(bash "$PEE" "$PEE_TMP/garbage.json" 2>&1 1>/dev/null | grep -qF "jq failed parsing" && echo yes || echo no)"
rm -rf "$PEE_TMP"

# ────────────────────────────────────────────────────────────────────────────
echo "surface-execution-diagnostics.sh (#329 execution-diagnostics surfacer: run summary + permission denials)"
# ────────────────────────────────────────────────────────────────────────────
# Best-effort read-only surfacer: prints the run summary + permission-denial
# detail from a claude-code-action execution log to stdout (and $GITHUB_STEP_SUMMARY
# when set). Always exits 0. Degrades to count-only when no per-denial array is
# present, and to "no diagnostics available" when the file is absent/empty/
# unparseable or carries neither a result event nor denial detail. An absent
# permission_denials_count (with no denial array) reads "unavailable", never a
# fail-open zero. Mirrors parse-engine-error.sh's slurp-based traversal.
SED="$LIB/../scripts/surface-execution-diagnostics.sh"
SED_TMP="$(mktemp -d)"
# populated: result object carrying the run summary AND a permission_denials array
# with per-denial tool_name + tool_input (the tool_input long enough to truncate).
LONG_INPUT="$(printf 'x%.0s' $(seq 1 300))"
printf '%s' "$(printf '{"type":"result","is_error":false,"num_turns":12,"duration_ms":34567,"total_cost_usd":0.42,"permission_denials_count":2,"permission_denials":[{"tool_name":"Bash","tool_input":"%s"},{"tool_name":"Write","tool_input":"file.txt"}]}' "$LONG_INPUT")" > "$SED_TMP/populated.json"
# count-only: run summary with permission_denials_count but NO permission_denials array
printf '%s' '{"type":"result","is_error":true,"num_turns":3,"duration_ms":100,"total_cost_usd":0.01,"permission_denials_count":7}' > "$SED_TMP/count_only.json"
# zero denials
printf '%s' '{"type":"result","is_error":false,"num_turns":1,"duration_ms":5,"total_cost_usd":0.0,"permission_denials_count":0}' > "$SED_TMP/zero.json"
# JSONL shape carrying the result event on a later line (pins the -s slurp)
printf '{"type":"system"}\n{"type":"result","is_error":false,"num_turns":2,"permission_denials_count":1,"permission_denials":[{"tool_name":"Edit","tool_input":"a.py"}]}\n' > "$SED_TMP/jsonl.json"
# malformed / unparseable
printf '%s' 'not json {{'   > "$SED_TMP/garbage.json"
# empty file
: > "$SED_TMP/empty.json"
# parsed but NO result event and NO denials (message-only) -> the in-jq "no result
# event" arm (distinct from the shell absent/empty guard and the jq-failure arm)
printf '%s' '{"type":"system"}' > "$SED_TMP/msg_only.json"
# result event present but permission_denials_count ABSENT and no denials array:
# count is UNKNOWN, must NOT collapse to a success-shaped "No permission denials"
printf '%s' '{"type":"result","is_error":false,"num_turns":4}' > "$SED_TMP/no_count.json"
# denials array present but NO permission_denials_count field -> count derived from length
printf '%s' '{"type":"result","is_error":false,"permission_denials":[{"tool_name":"Read","tool_input":"x"},{"tool_name":"Bash","tool_input":"y"}]}' > "$SED_TMP/count_from_len.json"
# permission_denials is a bare OBJECT (not an array) -> the `else .` arm normalizes it
printf '%s' '{"type":"result","is_error":false,"permission_denials_count":1,"permission_denials":{"tool_name":"Glob","tool_input":"z"}}' > "$SED_TMP/denial_obj.json"
# result event missing duration_ms -> orna renders "n/a" (the null->n/a branch)
printf '%s' '{"type":"result","is_error":true,"num_turns":2,"permission_denials_count":0}' > "$SED_TMP/missing_field.json"
# denials in a NON-result event, NO result event at all: the tool's core premise
# (detail may live in streamed message events) -> partial block, n/a summary + detail
printf '%s' '[{"type":"system"},{"type":"stream","permission_denials":[{"tool_name":"WebFetch","tool_input":"https://x"}]}]' > "$SED_TMP/denials_no_result.json"
# result event reports count 0 but a message event carries denials: the reconciled
# count must be the larger (1) and the detail must be SURFACED, not suppressed as
# "No permission denials." (the fail-open the shadow pass caught)
printf '%s' '[{"type":"stream","permission_denials":[{"tool_name":"Task","tool_input":"q"}]},{"type":"result","is_error":false,"num_turns":9,"permission_denials_count":0}]' > "$SED_TMP/count0_with_denials.json"
# SAME two denials duplicated across a stream event AND the result event, count 2:
# `unique` must de-dup so the reconciled count is 2, not the double-counted 4
printf '%s' '[{"type":"stream","permission_denials":[{"tool_name":"Bash","tool_input":"a"},{"tool_name":"Edit","tool_input":"b"}]},{"type":"result","is_error":false,"permission_denials_count":2,"permission_denials":[{"tool_name":"Bash","tool_input":"a"},{"tool_name":"Edit","tool_input":"b"}]}]' > "$SED_TMP/dup_denials.json"

# --- AC1: run summary fields surfaced to stdout (capture once, grep the block) ---
SED_POP_OUT="$(bash "$SED" "$SED_TMP/populated.json" 2>/dev/null)"
assert_eq "#329 surface-diag: populated emits Run summary header" "yes" \
  "$(printf '%s' "$SED_POP_OUT" | grep -qF "### Run summary" && echo yes || echo no)"
assert_eq "#329 surface-diag: populated surfaces is_error" "yes" \
  "$(printf '%s' "$SED_POP_OUT" | grep -qF "is_error: false" && echo yes || echo no)"
assert_eq "#329 surface-diag: populated surfaces num_turns" "yes" \
  "$(printf '%s' "$SED_POP_OUT" | grep -qF "num_turns: 12" && echo yes || echo no)"
assert_eq "#329 surface-diag: populated surfaces duration_ms" "yes" \
  "$(printf '%s' "$SED_POP_OUT" | grep -qF "duration_ms: 34567" && echo yes || echo no)"
assert_eq "#329 surface-diag: populated surfaces total_cost_usd" "yes" \
  "$(printf '%s' "$SED_POP_OUT" | grep -qF "total_cost_usd: 0.42" && echo yes || echo no)"
assert_eq "#329 surface-diag: populated surfaces permission_denials_count" "yes" \
  "$(printf '%s' "$SED_POP_OUT" | grep -qF "permission_denials_count: 2" && echo yes || echo no)"
# --- AC1: per-denial detail (tool_name + tool_input) when the array is present ---
assert_eq "#329 surface-diag: populated surfaces per-denial tool_name" "yes" \
  "$(printf '%s' "$SED_POP_OUT" | grep -qF '`Bash`' && echo yes || echo no)"
assert_eq "#329 surface-diag: populated surfaces second per-denial tool_name" "yes" \
  "$(printf '%s' "$SED_POP_OUT" | grep -qF '`Write`' && echo yes || echo no)"
assert_eq "#329 surface-diag: populated truncates a long tool_input" "yes" \
  "$(printf '%s' "$SED_POP_OUT" | grep -qF '(truncated)' && echo yes || echo no)"
# --- count-only degrades to count text, no per-denial detail ---
assert_eq "#329 surface-diag: count-only surfaces count" "yes" \
  "$(bash "$SED" "$SED_TMP/count_only.json" 2>/dev/null | grep -qF "permission_denials_count: 7" && echo yes || echo no)"
assert_eq "#329 surface-diag: count-only emits the no-per-denial-detail line" "yes" \
  "$(bash "$SED" "$SED_TMP/count_only.json" 2>/dev/null | grep -qF "no per-denial detail in execution file" && echo yes || echo no)"
# --- zero denials -> "No permission denials." ---
assert_eq "#329 surface-diag: zero denials emits 'No permission denials.'" "yes" \
  "$(bash "$SED" "$SED_TMP/zero.json" 2>/dev/null | grep -qF "No permission denials." && echo yes || echo no)"
# --- JSONL slurp reaches the later result line ---
assert_eq "#329 surface-diag: JSONL result line surfaced (slurp pinned)" "yes" \
  "$(bash "$SED" "$SED_TMP/jsonl.json" 2>/dev/null | grep -qF '`Edit`' && echo yes || echo no)"
# --- AC3: absent/empty/malformed -> "no diagnostics available" + exit 0 ---
assert_eq "#329 surface-diag: absent file -> no diagnostics available" "yes" \
  "$(bash "$SED" "$SED_TMP/does-not-exist.json" 2>/dev/null | grep -qF "No diagnostics available" && echo yes || echo no)"
assert_eq "#329 surface-diag: empty file -> no diagnostics available" "yes" \
  "$(bash "$SED" "$SED_TMP/empty.json" 2>/dev/null | grep -qF "No diagnostics available" && echo yes || echo no)"
assert_eq "#329 surface-diag: malformed shape -> no diagnostics available" "yes" \
  "$(bash "$SED" "$SED_TMP/garbage.json" 2>/dev/null | grep -qF "No diagnostics available" && echo yes || echo no)"
assert_eq "#329 surface-diag: missing file arg -> no diagnostics available" "yes" \
  "$(bash "$SED" "" 2>/dev/null | grep -qF "No diagnostics available" && echo yes || echo no)"
# --- AC3: always exits 0 on every arm ---
( bash "$SED" "$SED_TMP/populated.json" >/dev/null 2>&1 ); assert_eq "#329 surface-diag: exits 0 (populated)" "0" "$?"
( bash "$SED" "$SED_TMP/garbage.json" >/dev/null 2>&1 );   assert_eq "#329 surface-diag: exits 0 (malformed)" "0" "$?"
( bash "$SED" "$SED_TMP/does-not-exist.json" >/dev/null 2>&1 ); assert_eq "#329 surface-diag: exits 0 (absent)" "0" "$?"
( bash "$SED" "" >/dev/null 2>&1 );                        assert_eq "#329 surface-diag: exits 0 (empty arg)" "0" "$?"
# --- AC3: absent-file / malformed arms leave a breadcrumb (not a silent no-op) ---
assert_eq "#329 surface-diag: absent-file arm emits 'execution file absent' breadcrumb" "yes" \
  "$(bash "$SED" "$SED_TMP/does-not-exist.json" 2>&1 1>/dev/null | grep -qF "execution file absent or empty" && echo yes || echo no)"
assert_eq "#329 surface-diag: malformed arm emits the jq-non-zero breadcrumb" "yes" \
  "$(bash "$SED" "$SED_TMP/garbage.json" 2>&1 1>/dev/null | grep -qF "exited non-zero" && echo yes || echo no)"
# --- fail-open guard: an ABSENT count with no denial array must read 'unavailable', not zero ---
SED_NC_OUT="$(bash "$SED" "$SED_TMP/no_count.json" 2>/dev/null)"
assert_eq "#329 surface-diag: absent count + no array -> 'count unavailable' (not fail-open zero)" "yes" \
  "$(printf '%s' "$SED_NC_OUT" | grep -qF "Permission-denial count unavailable" && echo yes || echo no)"
assert_eq "#329 surface-diag: absent count does NOT print 'No permission denials.'" "no" \
  "$(printf '%s' "$SED_NC_OUT" | grep -qF "No permission denials." && echo yes || echo no)"
assert_eq "#329 surface-diag: absent count renders permission_denials_count: n/a" "yes" \
  "$(printf '%s' "$SED_NC_OUT" | grep -qF "permission_denials_count: n/a" && echo yes || echo no)"
# --- parsed-but-result-less (message-only) -> the in-jq 'no result event' no-diag arm ---
# Grep the ARM-SPECIFIC text so this stays non-vacuous vs the shell _NO_DIAG string.
assert_eq "#329 surface-diag: message-only (no result, no denials) -> in-jq 'no result event' arm" "yes" \
  "$(bash "$SED" "$SED_TMP/msg_only.json" 2>/dev/null | grep -qF "no result event in execution file" && echo yes || echo no)"
( bash "$SED" "$SED_TMP/msg_only.json" >/dev/null 2>&1 ); assert_eq "#329 surface-diag: exits 0 (message-only)" "0" "$?"
# --- partial block: denials present, NO result event (the tool's core premise) ---
SED_DNR_OUT="$(bash "$SED" "$SED_TMP/denials_no_result.json" 2>/dev/null)"
assert_eq "#329 surface-diag: denials-without-result surfaces per-denial detail" "yes" \
  "$(printf '%s' "$SED_DNR_OUT" | grep -qF '`WebFetch`' && echo yes || echo no)"
assert_eq "#329 surface-diag: denials-without-result derives the count" "yes" \
  "$(printf '%s' "$SED_DNR_OUT" | grep -qF "permission_denials_count: 1" && echo yes || echo no)"
assert_eq "#329 surface-diag: denials-without-result renders n/a run-summary fields" "yes" \
  "$(printf '%s' "$SED_DNR_OUT" | grep -qF "is_error: n/a" && echo yes || echo no)"
( bash "$SED" "$SED_TMP/denials_no_result.json" >/dev/null 2>&1 ); assert_eq "#329 surface-diag: exits 0 (denials-without-result)" "0" "$?"
# --- fail-open regression: result count 0 but denials gathered -> detail SHOWN, not suppressed ---
SED_C0D_OUT="$(bash "$SED" "$SED_TMP/count0_with_denials.json" 2>/dev/null)"
assert_eq "#329 surface-diag: count-0-with-denials surfaces detail (not suppressed)" "yes" \
  "$(printf '%s' "$SED_C0D_OUT" | grep -qF '`Task`' && echo yes || echo no)"
assert_eq "#329 surface-diag: count-0-with-denials does NOT print 'No permission denials.'" "no" \
  "$(printf '%s' "$SED_C0D_OUT" | grep -qF "No permission denials." && echo yes || echo no)"
assert_eq "#329 surface-diag: count-0-with-denials reconciles count to the larger (1)" "yes" \
  "$(printf '%s' "$SED_C0D_OUT" | grep -qF "permission_denials_count: 1" && echo yes || echo no)"
# --- dedup: denials duplicated across events must not inflate the reconciled count ---
SED_DUP_OUT="$(bash "$SED" "$SED_TMP/dup_denials.json" 2>/dev/null)"
assert_eq "#329 surface-diag: duplicated denials de-duped -> count 2 (not double-counted 4)" "yes" \
  "$(printf '%s' "$SED_DUP_OUT" | grep -qF "permission_denials_count: 2" && echo yes || echo no)"
assert_eq "#329 surface-diag: duplicated denials -> detail lists 2 (not 4)" "yes" \
  "$(printf '%s' "$SED_DUP_OUT" | grep -qF "2 permission denial(s) with detail:" && echo yes || echo no)"
# --- count derived from the denials-array length when the count field is absent ---
SED_CFL_OUT="$(bash "$SED" "$SED_TMP/count_from_len.json" 2>/dev/null)"
assert_eq "#329 surface-diag: count derived from denial-array length" "yes" \
  "$(printf '%s' "$SED_CFL_OUT" | grep -qF "permission_denials_count: 2" && echo yes || echo no)"
assert_eq "#329 surface-diag: derived-count surfaces per-denial detail" "yes" \
  "$(printf '%s' "$SED_CFL_OUT" | grep -qF '`Read`' && echo yes || echo no)"
# --- a bare-object permission_denials (not an array) is normalized by the `else .` arm ---
assert_eq "#329 surface-diag: single-object permission_denials normalized to detail" "yes" \
  "$(bash "$SED" "$SED_TMP/denial_obj.json" 2>/dev/null | grep -qF '`Glob`' && echo yes || echo no)"
# --- orna null->n/a branch: a result event missing duration_ms/total_cost_usd renders n/a ---
SED_MF_OUT="$(bash "$SED" "$SED_TMP/missing_field.json" 2>/dev/null)"
assert_eq "#329 surface-diag: missing duration_ms renders 'duration_ms: n/a'" "yes" \
  "$(printf '%s' "$SED_MF_OUT" | grep -qF "duration_ms: n/a" && echo yes || echo no)"
assert_eq "#329 surface-diag: missing total_cost_usd renders 'total_cost_usd: n/a'" "yes" \
  "$(printf '%s' "$SED_MF_OUT" | grep -qF "total_cost_usd: n/a" && echo yes || echo no)"
# --- AC2: appends to $GITHUB_STEP_SUMMARY when set & non-empty; stdout-only when not ---
SED_SUMMARY="$SED_TMP/step_summary.md"
: > "$SED_SUMMARY"
( GITHUB_STEP_SUMMARY="$SED_SUMMARY" bash "$SED" "$SED_TMP/populated.json" >/dev/null 2>&1 )
assert_eq "#329 surface-diag: appends the block to GITHUB_STEP_SUMMARY when set" "yes" \
  "$(grep -qF "permission_denials_count: 2" "$SED_SUMMARY" && echo yes || echo no)"
# unset -> no file written; stdout still carries the block (the summary var is empty)
SED_STDOUT="$(GITHUB_STEP_SUMMARY="" bash "$SED" "$SED_TMP/populated.json" 2>/dev/null)"
assert_eq "#329 surface-diag: stdout still carries the block when GITHUB_STEP_SUMMARY unset" "yes" \
  "$(printf '%s' "$SED_STDOUT" | grep -qF "### Run summary" && echo yes || echo no)"
# GITHUB_STEP_SUMMARY pointing at an unwritable path: the append fails with a breadcrumb
# but stdout still carries the block and the helper still exits 0 (best-effort).
SED_BADSUMMARY_OUT="$(GITHUB_STEP_SUMMARY="$SED_TMP/nonexistent-dir/summary.md" bash "$SED" "$SED_TMP/populated.json" 2>/dev/null)"
assert_eq "#329 surface-diag: unwritable GITHUB_STEP_SUMMARY -> stdout still carries the block" "yes" \
  "$(printf '%s' "$SED_BADSUMMARY_OUT" | grep -qF "### Run summary" && echo yes || echo no)"
assert_eq "#329 surface-diag: unwritable GITHUB_STEP_SUMMARY leaves a breadcrumb" "yes" \
  "$(GITHUB_STEP_SUMMARY="$SED_TMP/nonexistent-dir/summary.md" bash "$SED" "$SED_TMP/populated.json" 2>&1 1>/dev/null | grep -qF "could not append to GITHUB_STEP_SUMMARY" && echo yes || echo no)"
( GITHUB_STEP_SUMMARY="$SED_TMP/nonexistent-dir/summary.md" bash "$SED" "$SED_TMP/populated.json" >/dev/null 2>&1 ); assert_eq "#329 surface-diag: exits 0 (unwritable GITHUB_STEP_SUMMARY)" "0" "$?"
# DEVFLOW_JQ override honored (best-effort seam, same as parse-engine-error.sh).
# NON-VACUOUS: point the override at a non-runnable binary and observe the behavioral
# difference — the jq call exits non-zero, so the helper degrades to "no diagnostics
# available" (+ the jq-non-zero breadcrumb) and still exits 0. A helper that ignored
# DEVFLOW_JQ and called bare `jq` would instead surface the run summary, failing this.
SED_BADJQ_OUT="$(DEVFLOW_JQ=/nonexistent/definitely-not-jq bash "$SED" "$SED_TMP/populated.json" 2>/dev/null)"
assert_eq "#329 surface-diag: broken DEVFLOW_JQ override -> no diagnostics available (override honored)" "yes" \
  "$(printf '%s' "$SED_BADJQ_OUT" | grep -qF "No diagnostics available" && echo yes || echo no)"
assert_eq "#329 surface-diag: broken DEVFLOW_JQ override does NOT surface a run summary (non-vacuous)" "no" \
  "$(printf '%s' "$SED_BADJQ_OUT" | grep -qF "### Run summary" && echo yes || echo no)"
( DEVFLOW_JQ=/nonexistent/definitely-not-jq bash "$SED" "$SED_TMP/populated.json" >/dev/null 2>&1 ); assert_eq "#329 surface-diag: exits 0 (broken DEVFLOW_JQ)" "0" "$?"
# --- AC8: the execution_diagnostics_enabled key exists in schema + example (default true) ---
SED_SCHEMA="$LIB/../.devflow/config.schema.json"
SED_EXAMPLE="$LIB/../.devflow/config.example.json"
SED_PROP='.properties.devflow.properties.execution_diagnostics_enabled'
assert_eq "#329 execution_diagnostics_enabled: schema type is boolean" "boolean" \
  "$(jq -r "$SED_PROP.type" "$SED_SCHEMA")"
assert_eq "#329 execution_diagnostics_enabled: schema default is true" "true" \
  "$(jq -r "$SED_PROP.default" "$SED_SCHEMA")"
assert_eq "#329 execution_diagnostics_enabled: schema has a non-empty description" "yes" \
  "$(jq -e "$SED_PROP.description | type == \"string\" and (length > 0)" "$SED_SCHEMA" >/dev/null && echo yes || echo no)"
assert_eq "#329 execution_diagnostics_enabled: example value matches schema default" \
  "$(jq -r "$SED_PROP.default" "$SED_SCHEMA")" \
  "$(jq -r '.devflow.execution_diagnostics_enabled' "$SED_EXAMPLE")"
# resolver read: configured false read back verbatim, absent/missing → default true
SED_CFG="$(mktemp)"
printf '%s' '{"devflow":{"execution_diagnostics_enabled":false}}' > "$SED_CFG"
assert_eq "#329 execution_diagnostics_enabled: configured false read back" "false" \
  "$("$CG" .devflow.execution_diagnostics_enabled true "$SED_CFG")"
printf '%s' '{}' > "$SED_CFG"
assert_eq "#329 execution_diagnostics_enabled: unset key → resolver default true" "true" \
  "$("$CG" .devflow.execution_diagnostics_enabled true "$SED_CFG")"
assert_eq "#329 execution_diagnostics_enabled: missing config file → resolver default true" "true" \
  "$("$CG" .devflow.execution_diagnostics_enabled true /no/such/config.json)"
rm -f "$SED_CFG"
rm -rf "$SED_TMP"

# ────────────────────────────────────────────────────────────────────────────
echo "workflow wiring: Surface execution diagnostics step (#331)"
# ────────────────────────────────────────────────────────────────────────────
# Issue #331 wires scripts/surface-execution-diagnostics.sh (shipped in #329)
# into the three claude-code-action workflows. Each must carry a post-`claude`
# "Surface execution diagnostics" step that: (AC1) runs under always(), reads
# ${{ steps.claude.outputs.execution_file }}, and resolves the helper
# vendored-path-first with a repo-path fallback; (AC2) gates on
# .devflow.execution_diagnostics_enabled (default true) via config-get.sh
# (vendored-first) and skips on the literal "false"; (AC3) adds no permissions
# grant / minted-token scope and uploads no artifact (a pure run-only step).
# Assertions scope to the step block — awk-sliced from its `- name:` to the next
# `- name:` — so `if: always()` is non-vacuous: it must be THIS step's `if:`,
# not a sibling's.
WF_DIR="$LIB/../.github/workflows"
# Slice a named step block out of a workflow file: from the `- name: <step>`
# line to (but not including) the next top-level (6-space-indented) `- name:`.
extract_step() {  # $1=workflow file  $2=exact step name
  awk -v want="- name: $2" '
    index($0, want) { grab=1; print; next }
    grab && /^      - name: / { exit }
    grab { print }
  ' "$1"
}
# Assert needle A's first occurrence precedes needle B's within a block — used to pin
# vendored-path-FIRST *ordering* (a plain presence grep passes even if the two candidates
# were flipped to repo-first, which the "vendored-first" label would then overstate).
block_order_ok() {  # $1=block  $2=earlier-needle  $3=later-needle → echoes yes|no
  local a b
  a=$(printf '%s\n' "$1" | grep -nF "$2" | head -1 | cut -d: -f1)
  b=$(printf '%s\n' "$1" | grep -nF "$3" | head -1 | cut -d: -f1)
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then echo yes; else echo no; fi
}
for WF in devflow-runner.yml devflow-implement.yml devflow.yml; do
  WF_PATH="$WF_DIR/$WF"
  BLK="$(extract_step "$WF_PATH" "Surface execution diagnostics")"
  assert_eq "#331 $WF: has a 'Surface execution diagnostics' step" "yes" \
    "$([ -n "$BLK" ] && echo yes || echo no)"
  # AC1: runs under always()
  assert_eq "#331 $WF: diagnostics step runs under always()" "yes" \
    "$(printf '%s' "$BLK" | grep -qE 'if:[[:space:]]*(\$\{\{[[:space:]]*)?always\(\)' && echo yes || echo no)"
  # AC1: reads the claude step's execution_file output
  assert_eq "#331 $WF: reads steps.claude.outputs.execution_file" "yes" \
    "$(printf '%s' "$BLK" | grep -qF 'steps.claude.outputs.execution_file' && echo yes || echo no)"
  # AC1: resolves the helper vendored-path-first with a repo-path fallback
  assert_eq "#331 $WF: resolves helper vendored-path-first" "yes" \
    "$(printf '%s' "$BLK" | grep -qF '.devflow/vendor/devflow/scripts/surface-execution-diagnostics.sh' && echo yes || echo no)"
  assert_eq "#331 $WF: helper repo-path fallback present" "yes" \
    "$(printf '%s' "$BLK" | grep -qF 'SED=scripts/surface-execution-diagnostics.sh' && echo yes || echo no)"
  # AC1 (order, not just presence): the vendored helper path is tried BEFORE the repo fallback
  assert_eq "#331 $WF: helper vendored path precedes repo fallback" "yes" \
    "$(block_order_ok "$BLK" 'SED=.devflow/vendor/devflow/scripts/surface-execution-diagnostics.sh' 'SED=scripts/surface-execution-diagnostics.sh')"
  # AC2: gates on the config key via config-get.sh, vendored-first with fallback
  assert_eq "#331 $WF: reads .devflow.execution_diagnostics_enabled" "yes" \
    "$(printf '%s' "$BLK" | grep -qF '.devflow.execution_diagnostics_enabled' && echo yes || echo no)"
  assert_eq "#331 $WF: gate uses config-get.sh vendored-first" "yes" \
    "$(printf '%s' "$BLK" | grep -qF '.devflow/vendor/devflow/scripts/config-get.sh' && echo yes || echo no)"
  assert_eq "#331 $WF: config-get.sh repo-path fallback present" "yes" \
    "$(printf '%s' "$BLK" | grep -qF 'CG=scripts/config-get.sh' && echo yes || echo no)"
  # AC2 (order, not just presence): the vendored config-get path is tried BEFORE the repo fallback
  assert_eq "#331 $WF: config-get.sh vendored path precedes repo fallback" "yes" \
    "$(block_order_ok "$BLK" 'CG=.devflow/vendor/devflow/scripts/config-get.sh' 'CG=scripts/config-get.sh')"
  # AC2: disables only on the literal "false" — anchor on the FULL gate shape, not the bare
  # `= "false" ]` substring (which is ALSO contained in `!= "false" ]`, so a gate inverted to
  # `!=` — skip-when-ENABLED, the exact AC2 violation — would pass a bare-substring grep green).
  assert_eq "#331 $WF: skips only on the literal \"false\" (full gate shape, inversion-proof)" "yes" \
    "$(printf '%s' "$BLK" | grep -qF 'if [ "$ENABLED" = "false" ]; then' && echo yes || echo no)"
  # AC2/AC3: the config-get read is `|| true`-guarded so its hard-fail exit (malformed config /
  # missing python3) can't abort the step under GitHub Actions' default `-e` run shell — an
  # unguarded assignment would fail the job, breaking the read-only "never changes the job's
  # pass/fail" contract.
  assert_eq "#331 $WF: config-get read is -e-guarded (|| true)" "yes" \
    "$(printf '%s' "$BLK" | grep -qF '.devflow.execution_diagnostics_enabled true || true)' && echo yes || echo no)"
  # Completeness anchor: the slice reaches the step's run body (the helper invocation).
  # The AC3 assertions below are grep-ABSENT checks that pass vacuously on an empty or
  # short-sliced block, so anchor them on a proven-complete block — a future extract_step
  # mis-scope that truncated the slice would fail HERE (RED) rather than silently making
  # the AC3 guarantees inert while still reading green.
  assert_eq "#331 $WF: slice reaches the run body (helper invocation present)" "yes" \
    "$(printf '%s' "$BLK" | grep -qF 'bash "$SED" "${EXECUTION_FILE:-}"' && echo yes || echo no)"
  # AC3: the helper invocation is `|| echo`-guarded so a partial-copy/truncated vendored
  # helper that exits non-zero can't abort the always() step under GitHub's default -e
  # shell (same read-only "never changes the job's pass/fail" contract as the config-get
  # guard). Pins the guard so a regression dropping it goes RED.
  assert_eq "#331 $WF: helper invocation is -e-guarded (|| echo)" "yes" \
    "$(printf '%s' "$BLK" | grep -qF 'bash "$SED" "${EXECUTION_FILE:-}" || echo' && echo yes || echo no)"
  # AC3: the step is a pure run-only step — no action invocation, so it can neither
  # mint a token (create-github-app-token) nor upload an artifact (upload-artifact).
  assert_eq "#331 $WF: diagnostics step is run-only (no uses:)" "no" \
    "$(printf '%s' "$BLK" | grep -qE '^[[:space:]]*uses:' && echo yes || echo no)"
  # AC3: the step declares no per-step permissions: block
  assert_eq "#331 $WF: diagnostics step declares no permissions: block" "no" \
    "$(printf '%s' "$BLK" | grep -qE '^[[:space:]]*permissions:' && echo yes || echo no)"
  # AC3 (explicit): no artifact upload even if a future edit added a uses:
  assert_eq "#331 $WF: diagnostics step uploads no artifact" "no" \
    "$(printf '%s' "$BLK" | grep -qiF 'upload-artifact' && echo yes || echo no)"
done
unset -f extract_step

# ────────────────────────────────────────────────────────────────────────────
echo "execution transcript artifact: config key + scrub/gate hardening (#409)"
# ────────────────────────────────────────────────────────────────────────────
# Issue #409 (deferred findings from the PR #407 review) hardens the opt-in
# execution-transcript artifact path in devflow-runner.yml. The key gates a
# credential-scrubbed upload of the engine's execution transcript; its polarity
# is default-FALSE and fail-CLOSED (the OPPOSITE of execution_diagnostics_enabled),
# so it must be pinned with the same rigor as its sibling.
TR_SCHEMA="$LIB/../.devflow/config.schema.json"
TR_EXAMPLE="$LIB/../.devflow/config.example.json"
TR_RUNNER="$LIB/../.github/workflows/devflow-runner.yml"
TR_PROP='.properties.devflow.properties.execution_transcript_artifact_enabled'
# --- item 1: schema family mirrors execution_diagnostics_enabled ---
assert_eq "#409 transcript key: schema type is boolean" "boolean" \
  "$(jq -r "$TR_PROP.type" "$TR_SCHEMA")"
assert_eq "#409 transcript key: schema default is false (fail-closed polarity)" "false" \
  "$(jq -r "$TR_PROP.default" "$TR_SCHEMA")"
assert_eq "#409 transcript key: schema has a non-empty description" "yes" \
  "$(jq -e "$TR_PROP.description | type == \"string\" and (length > 0)" "$TR_SCHEMA" >/dev/null && echo yes || echo no)"
assert_eq "#409 transcript key: example value matches schema default" \
  "$(jq -r "$TR_PROP.default" "$TR_SCHEMA")" \
  "$(jq -r '.devflow.execution_transcript_artifact_enabled' "$TR_EXAMPLE")"
# resolver read: configured true read back verbatim; absent/missing → default false
TR_CFG="$(mktemp)"
printf '%s' '{"devflow":{"execution_transcript_artifact_enabled":true}}' > "$TR_CFG"
assert_eq "#409 transcript key: configured true read back" "true" \
  "$("$CG" .devflow.execution_transcript_artifact_enabled false "$TR_CFG")"
printf '%s' '{}' > "$TR_CFG"
assert_eq "#409 transcript key: unset key → resolver default false" "false" \
  "$("$CG" .devflow.execution_transcript_artifact_enabled false "$TR_CFG")"
rm -f "$TR_CFG"
# item 1: the scrub step gates on outputs.transcript == 'true'; the upload step
# gates on the scrub step producing a path (so an empty/failed scrub uploads nothing).
assert_eq "#409 transcript: scrub step gates on diagnostics.outputs.transcript == 'true'" "1" \
  "$(grep -cF "steps.diagnostics.outputs.transcript == 'true'" "$TR_RUNNER" || true)"
assert_eq "#409 transcript: upload step gates on scrub_transcript.outputs.path != ''" "1" \
  "$(grep -cF "steps.scrub_transcript.outputs.path != ''" "$TR_RUNNER" || true)"
# --- item 5: coupled pin — schema retention phrase ↔ upload retention-days agree ---
# The schema description advertises an "N-day run artifact"; the upload step sets
# retention-days: N. If one changes without the other the two derived numbers
# disagree and this assertion goes RED.
# DEFERRED (#409 review, Suggestion, below the `important` fix threshold): both sides
# take `head -1` of their match, so a SECOND incidental `N-day` phrase in the schema
# description or a second `retention-days:` in the workflow could shift the compared
# pair silently. Low risk today (each token occurs exactly once). Revisit only if a
# second occurrence of either token is introduced — then anchor the match to the
# specific property/step instead of first-match.
TR_RET_SCHEMA="$(jq -r "$TR_PROP.description" "$TR_SCHEMA" | grep -oE '[0-9]+-day' | grep -oE '^[0-9]+' | head -1)"
TR_RET_UPLOAD="$(grep -oE 'retention-days: [0-9]+' "$TR_RUNNER" | grep -oE '[0-9]+' | head -1)"
assert_eq "#409 transcript: schema retention phrase present (N-day)" "yes" \
  "$([ -n "$TR_RET_SCHEMA" ] && echo yes || echo no)"
assert_eq "#409 transcript: schema retention phrase agrees with upload retention-days" \
  "$TR_RET_UPLOAD" "$TR_RET_SCHEMA"
# --- items 2/3/4 behavioral: drive the REAL extracted scrub step end-to-end ---
# Extract the scrub_transcript step's run body from the workflow and exercise it
# against a fixture transcript carrying every scrubbed credential shape. Driving
# the real step (not a hand-copied sed) keeps the test honest as the step evolves.
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
  SCRUB_STEP="$(mktemp)"
  python3 - "$TR_RUNNER" >"$SCRUB_STEP" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
for job in doc["jobs"].values():
    for s in job.get("steps", []):
        if s.get("id") == "scrub_transcript" and "run" in s:
            sys.stdout.write("#!/usr/bin/env bash\n" + s["run"])
            raise SystemExit
raise SystemExit("scrub_transcript step not found")
PY
  SCRUB_DIR="$(mktemp -d)"
  SCRUB_EXEC="$SCRUB_DIR/exec.json"
  # A fixture carrying: gh token, PAT, Anthropic key, Bearer header, and the
  # base64 basic-auth header the checkout persists (item 4). The basic-auth line
  # uses the REAL UPPERCASE `AUTHORIZATION:` form actions/checkout's git-auth-helper
  # persists (case-insensitive header match, #409 review) — a mixed-case fixture
  # would pass vacuously against a case-sensitive `Authorization` literal and give
  # false confidence against exactly the header item 4 exists to redact.
  {
    printf '%s\n' 'tok=ghs_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    printf '%s\n' 'pat=github_pat_ABCDEFGHIJKLMNOPQRSTUV0123456789'
    printf '%s\n' 'key=sk-ant-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    printf '%s\n' 'Authorization: Bearer ABCDEFGHIJKLMNOPQRSTUVWXYZ012345'
    printf '%s\n' 'AUTHORIZATION: basic eHgtYWNjZXNzLXRva2VuOmdoc19BQkNERUZHSElKS0xNTk9Q'
  } > "$SCRUB_EXEC"
  SCRUB_GH_OUT="$SCRUB_DIR/gh_output"
  : > "$SCRUB_GH_OUT"
  EXECUTION_FILE="$SCRUB_EXEC" RUNNER_TEMP="$SCRUB_DIR" GITHUB_OUTPUT="$SCRUB_GH_OUT" \
    bash "$SCRUB_STEP" > "$SCRUB_DIR/log" 2>&1 || true
  SCRUB_OUT="$SCRUB_DIR/claude-execution-scrubbed.json"
  # item 4 + existing shapes: every credential redacted, no raw secret survives.
  assert_eq "#409 scrub: ghs_ token redacted" "yes" \
    "$(grep -qF '[REDACTED-GH-TOKEN]' "$SCRUB_OUT" 2>/dev/null && echo yes || echo no)"
  assert_eq "#409 scrub: github_pat_ redacted" "yes" \
    "$(grep -qF '[REDACTED-GH-PAT]' "$SCRUB_OUT" 2>/dev/null && echo yes || echo no)"
  assert_eq "#409 scrub: sk-ant- key redacted" "yes" \
    "$(grep -qF '[REDACTED-ANTHROPIC-KEY]' "$SCRUB_OUT" 2>/dev/null && echo yes || echo no)"
  assert_eq "#409 scrub: Bearer header redacted" "yes" \
    "$(grep -qF 'Bearer [REDACTED]' "$SCRUB_OUT" 2>/dev/null && echo yes || echo no)"
  assert_eq "#409 scrub: base64 basic-auth header redacted (item 4)" "yes" \
    "$(grep -qF 'basic [REDACTED]' "$SCRUB_OUT" 2>/dev/null && echo yes || echo no)"
  assert_eq "#409 scrub: no raw base64 basic-auth token survives (item 4)" "no" \
    "$(grep -qF 'eHgtYWNjZXNzLXRva2Vu' "$SCRUB_OUT" 2>/dev/null && echo yes || echo no)"
  # item 2: caveat header prepended into the artifact + best-effort warning emitted.
  assert_eq "#409 scrub: caveat header prepended into the artifact (item 2)" "yes" \
    "$(grep -qF 'DEVFLOW SCRUB CAVEAT' "$SCRUB_OUT" 2>/dev/null && echo yes || echo no)"
  assert_eq "#409 scrub: incomplete-blocklist warning emitted (item 2)" "yes" \
    "$(grep -qF 'best-effort blocklist covering four credential shapes' "$SCRUB_DIR/log" 2>/dev/null && echo yes || echo no)"
  # item 3: non-empty output advertises a path=.
  assert_eq "#409 scrub: non-empty scrub advertises path= (item 3)" "yes" \
    "$(grep -qF 'path=' "$SCRUB_GH_OUT" 2>/dev/null && echo yes || echo no)"
  # item 3: an empty execution file scrubs to empty → no path advertised, own breadcrumb.
  SCRUB_EMPTY_EXEC="$SCRUB_DIR/empty.json"
  : > "$SCRUB_EMPTY_EXEC"
  SCRUB_GH_OUT2="$SCRUB_DIR/gh_output2"
  : > "$SCRUB_GH_OUT2"
  EXECUTION_FILE="$SCRUB_EMPTY_EXEC" RUNNER_TEMP="$SCRUB_DIR" GITHUB_OUTPUT="$SCRUB_GH_OUT2" \
    bash "$SCRUB_STEP" > "$SCRUB_DIR/log2" 2>&1 || true
  assert_eq "#409 scrub: empty output advertises NO path= (item 3)" "no" \
    "$(grep -qF 'path=' "$SCRUB_GH_OUT2" 2>/dev/null && echo yes || echo no)"
  assert_eq "#409 scrub: empty output leaves its own breadcrumb (item 3)" "yes" \
    "$(grep -qF 'scrubbed transcript is empty' "$SCRUB_DIR/log2" 2>/dev/null && echo yes || echo no)"
  # item 2 fail-closed arm: if the caveat-header write fails, NO path= is advertised
  # and a distinct fail-closed breadcrumb is emitted — a half-written/unscrubbed file
  # must never be uploaded (#409 review: the security fail-closed arm was untested).
  # Drive it by PATH-shadowing `mv` (used only in the caveat prepend) with a failing shim.
  # DEFERRED (#409 review, Suggestion, below the `important` fix threshold): this only
  # shadows `mv`. The caveat write is a single `printf … && cat … && mv …` &&-chain, so
  # a `printf`/`cat` failure takes the IDENTICAL else-branch and the same fail-closed
  # path — the arm is proven closed via `mv`; shadowing the earlier chain members would
  # observe the same branch. Revisit only if the chain gains a DISTINCT per-member
  # branch (then each member needs its own RED observation).
  MV_BIN="$(mktemp -d)"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$MV_BIN/mv"
  chmod +x "$MV_BIN/mv"
  SCRUB_GH_OUT3="$SCRUB_DIR/gh_output3"
  : > "$SCRUB_GH_OUT3"
  ( PATH="$MV_BIN:$PATH" EXECUTION_FILE="$SCRUB_EXEC" RUNNER_TEMP="$SCRUB_DIR" GITHUB_OUTPUT="$SCRUB_GH_OUT3" \
      bash "$SCRUB_STEP" ) > "$SCRUB_DIR/log3" 2>&1 || true
  assert_eq "#409 scrub: caveat-write failure advertises NO path= (fail-closed, item 2)" "no" \
    "$(grep -qF 'path=' "$SCRUB_GH_OUT3" 2>/dev/null && echo yes || echo no)"
  assert_eq "#409 scrub: caveat-write failure emits its fail-closed breadcrumb (item 2)" "yes" \
    "$(grep -qF 'caveat-header write failed' "$SCRUB_DIR/log3" 2>/dev/null && echo yes || echo no)"
  rm -rf "$MV_BIN"
  # absent-execution-file arm: the if: gate guarantees a non-empty output name but not
  # that the file exists, so the `[ ! -f "$EXECUTION_FILE" ]` early-exit is reachable —
  # it emits a notice and no path= (#409 review, Suggestion).
  SCRUB_GH_OUT4="$SCRUB_DIR/gh_output4"
  : > "$SCRUB_GH_OUT4"
  EXECUTION_FILE="$SCRUB_DIR/does-not-exist.json" RUNNER_TEMP="$SCRUB_DIR" GITHUB_OUTPUT="$SCRUB_GH_OUT4" \
    bash "$SCRUB_STEP" > "$SCRUB_DIR/log4" 2>&1 || true
  assert_eq "#409 scrub: absent execution file advertises NO path=" "no" \
    "$(grep -qF 'path=' "$SCRUB_GH_OUT4" 2>/dev/null && echo yes || echo no)"
  assert_eq "#409 scrub: absent execution file leaves its own breadcrumb" "yes" \
    "$(grep -qF 'execution file absent' "$SCRUB_DIR/log4" 2>/dev/null && echo yes || echo no)"
  # outer sed-failure arm: if the sed scrub itself fails, NO path= is advertised and
  # the unscrubbed file is not uploaded (#409 review, last uncovered scrub branch).
  # Drive it by PATH-shadowing `sed` with a failing shim.
  SED_BIN="$(mktemp -d)"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SED_BIN/sed"
  chmod +x "$SED_BIN/sed"
  SCRUB_GH_OUT5="$SCRUB_DIR/gh_output5"
  : > "$SCRUB_GH_OUT5"
  ( PATH="$SED_BIN:$PATH" EXECUTION_FILE="$SCRUB_EXEC" RUNNER_TEMP="$SCRUB_DIR" GITHUB_OUTPUT="$SCRUB_GH_OUT5" \
      bash "$SCRUB_STEP" ) > "$SCRUB_DIR/log5" 2>&1 || true
  assert_eq "#409 scrub: sed-failure advertises NO path= (fail-closed)" "no" \
    "$(grep -qF 'path=' "$SCRUB_GH_OUT5" 2>/dev/null && echo yes || echo no)"
  assert_eq "#409 scrub: sed-failure emits its fail-closed breadcrumb" "yes" \
    "$(grep -qF 'transcript scrub failed' "$SCRUB_DIR/log5" 2>/dev/null && echo yes || echo no)"
  rm -rf "$SED_BIN"
  rm -f "$SCRUB_STEP"
  rm -rf "$SCRUB_DIR"
else
  echo "  SKIP  #409 scrub behavioral tests (python3+pyyaml unavailable)"
fi

# ────────────────────────────────────────────────────────────────────────────
echo "resolve-implement-trigger.sh"
# ────────────────────────────────────────────────────────────────────────────
# The implement trigger runs the action in AGENT mode (explicit prompt), which
# executes for ANY actor — so this resolver is the cost/authorization gate AND
# the issue-number resolver. Tests stub `gh` for the collaborator-permission
# call; the allowed-bot path never reaches `gh`.
RIT="$LIB/../scripts/resolve-implement-trigger.sh"

# Inline gh stub: returns whatever STUB_PERM says for a collaborator-permission
# query (the script passes --jq '.permission'; like gh-stub.sh we ignore --jq
# and emit the already-extracted value), empty otherwise.
RIT_STUB_DIR="$(mktemp -d)"
cat > "$RIT_STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
# STUB_ERR (to stderr) + STUB_RC let a test simulate gh failures (transient or
# 404); default is a clean success echoing STUB_PERM. STUB_RECOVER (with a
# STUB_COUNTER file) fails the FIRST permission call with a 500 and succeeds on
# the second, so a test can prove the resolver's retry loop actually re-attempts.
case "$*" in
  *"collaborators/"*"/permission"*)
    if [ -n "${STUB_RECOVER:-}" ]; then
      n=0; [ -f "${STUB_COUNTER:-/dev/null}" ] && n="$(cat "${STUB_COUNTER:-/dev/null}")"
      n=$((n + 1)); echo "$n" > "${STUB_COUNTER:-/dev/null}"
      if [ "$n" -lt 2 ]; then echo "gh: Internal Server Error (HTTP 500)" >&2; exit 1; fi
      echo "${STUB_PERM:-none}"; exit 0
    fi
    [ -n "${STUB_ERR:-}" ] && echo "$STUB_ERR" >&2
    [ "${STUB_RC:-0}" != 0 ] && exit "${STUB_RC}"
    echo "${STUB_PERM:-none}" ;;
  *) echo "" ;;
esac
STUB
chmod +x "$RIT_STUB_DIR/gh"

# 1. Allowed bot + explicit number in comment → run on that number. `foo[bot]`
#    actor must match the bare `foo` in allowed_bots. No gh call on this path.
OUT="$(ACTOR='foo[bot]' ALLOWED_BOTS='foo,bar' REPO='acme/x' \
  TRIGGER_TEXT='/devflow:implement #42' CONTEXT_NUMBER='7' \
  PATH="$RIT_STUB_DIR:$PATH" bash "$RIT")"
assert_eq "rit: allowed bot, explicit number → should_run" \
  "should_run=true" "$(echo "$OUT" | grep '^should_run=')"
assert_eq "rit: allowed bot, explicit number → number" \
  "number=42" "$(echo "$OUT" | grep '^number=')"

# 2. Write collaborator + explicit number in comment → run on that number.
OUT="$(ACTOR='alice' ALLOWED_BOTS='' REPO='acme/x' \
  TRIGGER_TEXT='/devflow:implement 7' CONTEXT_NUMBER='99' \
  STUB_PERM='write' PATH="$RIT_STUB_DIR:$PATH" bash "$RIT")"
assert_eq "rit: write collaborator, explicit number → should_run" \
  "should_run=true" "$(echo "$OUT" | grep '^should_run=')"
assert_eq "rit: explicit number beats context" \
  "number=7" "$(echo "$OUT" | grep '^number=')"

# 3. Non-collaborator (gh → 'none') → blocked, no number.
OUT="$(ACTOR='stranger' ALLOWED_BOTS='' REPO='acme/x' \
  TRIGGER_TEXT='/devflow:implement 7' CONTEXT_NUMBER='99' \
  STUB_PERM='none' PATH="$RIT_STUB_DIR:$PATH" bash "$RIT")"
assert_eq "rit: non-collaborator → should_run=false" \
  "should_run=false" "$(echo "$OUT" | grep '^should_run=')"
assert_eq "rit: non-collaborator → empty number" \
  "number=" "$(echo "$OUT" | grep '^number=')"

# 4. Authorized but NO number anywhere → blocked (can't implement nothing).
OUT="$(ACTOR='alice' ALLOWED_BOTS='' REPO='acme/x' \
  TRIGGER_TEXT='/devflow:implement please' CONTEXT_NUMBER='' \
  STUB_PERM='admin' PATH="$RIT_STUB_DIR:$PATH" bash "$RIT")"
assert_eq "rit: no resolvable number → should_run=false" \
  "should_run=false" "$(echo "$OUT" | grep '^should_run=')"

# 5. Authorized, no explicit number but a context issue → fall back to context.
OUT="$(ACTOR='alice' ALLOWED_BOTS='' REPO='acme/x' \
  TRIGGER_TEXT='/devflow:implement' CONTEXT_NUMBER='5' \
  STUB_PERM='maintain' PATH="$RIT_STUB_DIR:$PATH" bash "$RIT")"
assert_eq "rit: fallback to context number" \
  "number=5" "$(echo "$OUT" | grep '^number=')"

# 6. Transient collaborator-API failure (non-404) → fails CLOSED with a
#    transient-specific diagnostic, NOT mislabelled as "not a collaborator".
#    RESOLVE_RETRY_DELAY=0 keeps the retry instant.
OUT="$(ACTOR='alice' ALLOWED_BOTS='' REPO='acme/x' \
  TRIGGER_TEXT='/devflow:implement 7' CONTEXT_NUMBER='99' \
  STUB_RC='1' STUB_ERR='gh: Internal Server Error (HTTP 500)' \
  RESOLVE_RETRY_DELAY='0' PATH="$RIT_STUB_DIR:$PATH" bash "$RIT" 2>"$RIT_STUB_DIR/err")"
assert_eq "rit: transient API error → should_run=false" \
  "should_run=false" "$(echo "$OUT" | grep '^should_run=')"
assert_eq "rit: transient API error → honest diagnostic (not mislabelled)" \
  "1" "$(grep -c 'collaborator-permission lookup failed after retry' "$RIT_STUB_DIR/err")"
assert_eq "rit: transient API error → surfaces the real gh error" \
  "1" "$(grep -c 'HTTP 500' "$RIT_STUB_DIR/err")"

# 7. Genuine 404 (not a collaborator) → fails closed as before, no retry stall.
OUT="$(ACTOR='stranger' ALLOWED_BOTS='' REPO='acme/x' \
  TRIGGER_TEXT='/devflow:implement 7' CONTEXT_NUMBER='99' \
  STUB_RC='1' STUB_ERR='gh: Not Found (HTTP 404)' \
  RESOLVE_RETRY_DELAY='0' PATH="$RIT_STUB_DIR:$PATH" bash "$RIT" 2>"$RIT_STUB_DIR/err")"
assert_eq "rit: 404 non-collaborator → should_run=false" \
  "should_run=false" "$(echo "$OUT" | grep '^should_run=')"
assert_eq "rit: 404 treated as non-collaborator, not transient" \
  "1" "$(grep -c 'is not an allowed bot or write/admin/maintain collaborator' "$RIT_STUB_DIR/err")"

# 8. Transient failure on attempt 1, success on attempt 2 → retry RECOVERS the
#    collaborator. A regression collapsing the loop to a single call would fail
#    closed and break this, which case 6 (double-failure) cannot catch.
RIT_COUNTER="$RIT_STUB_DIR/recover_count"; : > "$RIT_COUNTER"
OUT="$(ACTOR='alice' ALLOWED_BOTS='' REPO='acme/x' \
  TRIGGER_TEXT='/devflow:implement 7' CONTEXT_NUMBER='99' \
  STUB_RECOVER='1' STUB_COUNTER="$RIT_COUNTER" STUB_PERM='write' \
  RESOLVE_RETRY_DELAY='0' PATH="$RIT_STUB_DIR:$PATH" bash "$RIT")"
assert_eq "rit: retry recovers collaborator on attempt 2 → should_run" \
  "should_run=true" "$(echo "$OUT" | grep '^should_run=')"
assert_eq "rit: retry recovers → number" \
  "number=7" "$(echo "$OUT" | grep '^number=')"

# 9. Explicit number with leading '#' and mixed-case command → extracted (pins
#    the regex's `#?` arm and grep -i case-insensitivity).
OUT="$(ACTOR='alice' ALLOWED_BOTS='' REPO='acme/x' \
  TRIGGER_TEXT='/DevFlow:Implement #13' CONTEXT_NUMBER='99' \
  STUB_PERM='admin' PATH="$RIT_STUB_DIR:$PATH" bash "$RIT")"
assert_eq "rit: '#'-prefixed mixed-case command → number=13" \
  "number=13" "$(echo "$OUT" | grep '^number=')"

# 10. allowed_bots with surrounding whitespace + bot is NOT the first entry →
#     matched after parameter-expansion trim (pins the trim + loop continuation).
OUT="$(ACTOR='bar[bot]' ALLOWED_BOTS=' foo , bar ' REPO='acme/x' \
  TRIGGER_TEXT='/devflow:implement 8' CONTEXT_NUMBER='8' \
  PATH="$RIT_STUB_DIR:$PATH" bash "$RIT")"
assert_eq "rit: whitespace-trimmed, non-first allowed bot → should_run" \
  "should_run=true" "$(echo "$OUT" | grep '^should_run=')"

# 11. Self-trigger guard: a Devflow-authored workpad comment (leads with the
#     marker, quotes a `/devflow:implement run started` note) must NOT fire a
#     run — even for an allowed bot, since the guard runs BEFORE authorization
#     and number resolution. Covers the issue #25 regression directly.
RIT_WORKPAD_TEXT=$'<!-- devflow:workpad -->\n# DevFlow Workpad — Issue #25\n\n## Decisions / Notes\n### Setup\n- 04:57:07 — /devflow:implement run started'
OUT="$(ACTOR='claude[bot]' ALLOWED_BOTS='claude' REPO='acme/x' \
  TRIGGER_TEXT="$RIT_WORKPAD_TEXT" CONTEXT_NUMBER='25' \
  SELF_COMMENT_MARKER='<!-- devflow:workpad -->' \
  PATH="$RIT_STUB_DIR:$PATH" bash "$RIT")"
assert_eq "rit: workpad-marker body → should_run=false (self-trigger guard)" \
  "should_run=false" "$(echo "$OUT" | grep '^should_run=')"
assert_eq "rit: workpad-marker body → empty number" \
  "number=" "$(echo "$OUT" | grep '^number=')"

# 12. The guard's marker defaults to workpad.py's fallback when
#     SELF_COMMENT_MARKER is unset, so a workpad body is guarded regardless.
OUT="$(ACTOR='claude[bot]' ALLOWED_BOTS='claude' REPO='acme/x' \
  TRIGGER_TEXT="$RIT_WORKPAD_TEXT" CONTEXT_NUMBER='25' \
  PATH="$RIT_STUB_DIR:$PATH" bash "$RIT")"
assert_eq "rit: default marker guards workpad body when SELF_COMMENT_MARKER unset" \
  "should_run=false" "$(echo "$OUT" | grep '^should_run=')"

# 13. Sanity: a genuine command WITHOUT the marker is unaffected — the guard
#     must not over-match (allowed bot, explicit number, marker env present).
OUT="$(ACTOR='claude[bot]' ALLOWED_BOTS='claude' REPO='acme/x' \
  TRIGGER_TEXT='/devflow:implement 25' CONTEXT_NUMBER='25' \
  SELF_COMMENT_MARKER='<!-- devflow:workpad -->' \
  PATH="$RIT_STUB_DIR:$PATH" bash "$RIT")"
assert_eq "rit: no-marker command still runs (guard does not over-match)" \
  "should_run=true" "$(echo "$OUT" | grep '^should_run=')"
assert_eq "rit: no-marker command → parsed number" \
  "number=25" "$(echo "$OUT" | grep '^number=')"

# 14. Pull-request-context guard: a comment on a PR (IS_PULL_REQUEST=true) must
#     NOT start a run, even for an authorized bot with a resolvable context
#     number. Reproduces the weekly audit-report shape — body quotes the literal
#     phrase in prose with NO trailing number, and CONTEXT_NUMBER is the PR
#     number. The guard runs BEFORE authorization/number resolution and fails
#     closed. Covers issue #124 directly.
OUT="$(ACTOR='claude[bot]' ALLOWED_BOTS='claude' REPO='acme/x' \
  TRIGGER_TEXT='the report describes how /devflow:implement publishes its PR' CONTEXT_NUMBER='120' \
  IS_PULL_REQUEST='true' \
  PATH="$RIT_STUB_DIR:$PATH" bash "$RIT" 2>"$RIT_STUB_DIR/pr_err")"
assert_eq "rit: pull-request context → should_run=false (PR guard)" \
  "should_run=false" "$(echo "$OUT" | grep '^should_run=')"
assert_eq "rit: pull-request context → empty number" \
  "number=" "$(echo "$OUT" | grep '^number=')"
# Pin the GitHub Actions ::warning:: annotation prefix AND the disambiguating
# pull-request-context-guard suffix together, so a regression that drops the
# annotation prefix (losing the Actions-UI surface) or rewords the guard into a
# generic message is caught — not merely that the substring "pull-request"
# appears somewhere on stderr.
assert_eq "rit: pull-request context → ::warning:: from the pull-request-context guard on stderr" \
  "1" "$(grep -cE '::warning::.*pull-request-context guard' "$RIT_STUB_DIR/pr_err")"

# 15. PR guard precedes number resolution: even an EXPLICIT /devflow:implement 42
#     in a PR comment is declined (the guard runs before number parsing), so a
#     deliberate command on a PR thread still cannot start an implement run.
OUT="$(ACTOR='claude[bot]' ALLOWED_BOTS='claude' REPO='acme/x' \
  TRIGGER_TEXT='/devflow:implement 42' CONTEXT_NUMBER='120' \
  IS_PULL_REQUEST='true' \
  PATH="$RIT_STUB_DIR:$PATH" bash "$RIT")"
assert_eq "rit: PR context w/ explicit number → still declined" \
  "should_run=false" "$(echo "$OUT" | grep '^should_run=')"
assert_eq "rit: PR context w/ explicit number → empty number" \
  "number=" "$(echo "$OUT" | grep '^number=')"

# 16. Sanity: an explicit issue-context signal (IS_PULL_REQUEST=false) does NOT
#     decline — the guard must not over-match a genuine issue comment.
OUT="$(ACTOR='claude[bot]' ALLOWED_BOTS='claude' REPO='acme/x' \
  TRIGGER_TEXT='/devflow:implement 25' CONTEXT_NUMBER='25' \
  IS_PULL_REQUEST='false' \
  PATH="$RIT_STUB_DIR:$PATH" bash "$RIT")"
assert_eq "rit: issue context (IS_PULL_REQUEST=false) still runs" \
  "should_run=true" "$(echo "$OUT" | grep '^should_run=')"
assert_eq "rit: issue context (IS_PULL_REQUEST=false) → number" \
  "number=25" "$(echo "$OUT" | grep '^number=')"

rm -rf "$RIT_STUB_DIR"

# ────────────────────────────────────────────────────────────────────────────
echo "dedupe-implement-run.sh"
# ────────────────────────────────────────────────────────────────────────────
# Per-thread duplicate detection for /devflow:implement. GitHub has no native
# "skip if already running", so this gate-stage check decides duplicate=true
# when an OLDER active run for the same issue/PR thread exists, letting the
# workflow skip the billable job and leave the in-flight run untouched. The gh
# `run list` call is stubbed via DEVFLOW_GH; DEDUPE_RUNS_JSON feeds the run set
# and DEDUPE_GH_RC simulates a query failure.
DIR="$LIB/../scripts/dedupe-implement-run.sh"
DI_STUB="$(mktemp -d)"
cat > "$DI_STUB/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"run list"*)
    [ -n "${DI_ARGS_REC:-}" ] && echo "$*" >> "$DI_ARGS_REC"
    [ -n "${DEDUPE_GH_RC:-}" ] && exit "$DEDUPE_GH_RC"
    printf '%s' "${DEDUPE_RUNS_JSON:-[]}" ;;
  *) echo "" ;;
esac
STUB
chmod +x "$DI_STUB/gh"
# Neutralize any ambient GITHUB_EVENT_PATH: when this suite runs inside a cloud
# job the runner exports it, and dedupe-implement-run.sh self-derives the
# stall-resume carve-out from the triggering comment's body. If that comment
# carries the stall-backstop-audit marker (e.g. this very suite runs under a
# stall-resumed implement job), the script would bypass dedupe and every
# duplicate=true expectation below would spuriously read duplicate=false. The
# carve-out tests set GITHUB_EVENT_PATH explicitly, so clearing it here (empty →
# the script's `[ -n ... ]` guard skips the self-derive) isolates the default set.
di() { DEVFLOW_GH="$DI_STUB/gh" GITHUB_EVENT_PATH='' REPO=o/r RUN_ID="$1" CONTEXT_NUMBER="$2" \
  DEDUPE_RUNS_JSON="$3" bash "$DIR" 2>/dev/null; }

# 1. An OLDER (smaller databaseId) active run for the same thread → duplicate.
assert_eq "di: older active run, same thread → duplicate" "duplicate=true" \
  "$(di 200 42 '[{"databaseId":100,"displayTitle":"DevFlow implement (issue 42)","status":"in_progress"}]')"

# 2. A queued (not yet started) older run still counts as active → duplicate.
assert_eq "di: older QUEUED run, same thread → duplicate" "duplicate=true" \
  "$(di 200 42 '[{"databaseId":100,"displayTitle":"DevFlow implement (issue 42)","status":"queued"}]')"

# 3. A NEWER run (larger id) is NOT deferred to — this run is the older of the
#    two and proceeds; the newer one will defer to it. Guards against two
#    near-simultaneous commands BOTH skipping.
assert_eq "di: newer run, same thread → not duplicate (this run is older)" "duplicate=false" \
  "$(di 200 42 '[{"databaseId":300,"displayTitle":"DevFlow implement (issue 42)","status":"in_progress"}]')"

# 4. An older active run for a DIFFERENT thread → not a duplicate (per-thread).
assert_eq "di: older run, different thread → not duplicate" "duplicate=false" \
  "$(di 200 42 '[{"databaseId":100,"displayTitle":"DevFlow implement (issue 43)","status":"in_progress"}]')"

# 5. Number-boundary: thread 2 must not match a run-name carrying thread 21.
assert_eq "di: thread 2 does not match 'issue 21'" "duplicate=false" \
  "$(di 200 2 '[{"databaseId":100,"displayTitle":"DevFlow implement (issue 21)","status":"in_progress"}]')"

# 6. A finished run (completed) is not active → not a duplicate.
assert_eq "di: completed run → not duplicate" "duplicate=false" \
  "$(di 200 42 '[{"databaseId":100,"displayTitle":"DevFlow implement (issue 42)","status":"completed"}]')"

# 7. Only this run itself in the list (id == RUN_ID) → not a duplicate.
assert_eq "di: self only → not duplicate" "duplicate=false" \
  "$(di 200 42 '[{"databaseId":200,"displayTitle":"DevFlow implement (issue 42)","status":"in_progress"}]')"

# 8. No active runs at all → not a duplicate.
assert_eq "di: empty run list → not duplicate" "duplicate=false" \
  "$(di 200 42 '[]')"

# 9. gh query failure → fail OPEN (run proceeds), never silently swallowed.
assert_eq "di: gh failure → fail open (not duplicate)" "duplicate=false" \
  "$(DEVFLOW_GH="$DI_STUB/gh" GITHUB_EVENT_PATH='' REPO=o/r RUN_ID=200 CONTEXT_NUMBER=42 DEDUPE_GH_RC=1 bash "$DIR" 2>/dev/null)"

# 10. Missing/invalid CONTEXT_NUMBER → fail open (cannot dedupe without a thread).
assert_eq "di: missing context number → fail open" "duplicate=false" \
  "$(di 200 '' '[]')"

# 11. Active-status set spanning 3+ overlapping runs: the OLDEST proceeds, a
#     middle run defers. Asserts the "exactly one of N proceeds" invariant beyond
#     the pairwise N=2 cases above (no double-skip across a 3-way race).
THREE='[{"databaseId":100,"displayTitle":"DevFlow implement (issue 42)","status":"in_progress"},{"databaseId":200,"displayTitle":"DevFlow implement (issue 42)","status":"in_progress"},{"databaseId":300,"displayTitle":"DevFlow implement (issue 42)","status":"queued"}]'
assert_eq "di: 3-way race, oldest (id 100) → proceeds" "duplicate=false" "$(di 100 42 "$THREE")"
assert_eq "di: 3-way race, middle (id 200) → defers" "duplicate=true"  "$(di 200 42 "$THREE")"
assert_eq "di: 3-way race, newest (id 300) → defers" "duplicate=true"  "$(di 300 42 "$THREE")"

# 12. Malformed JSON (gh returned 200 + non-JSON, e.g. an HTML error page) → jq
#     fails, count is non-numeric → fail OPEN. Distinct path from the gh-exit
#     failure (#9) and missing-input (#10) cases.
assert_eq "di: malformed run-list JSON → fail open (not duplicate)" "duplicate=false" \
  "$(di 200 42 'not-json{')"

# 13. The run list MUST be scoped to --workflow devflow-implement.yml — otherwise
#     a same-numbered run of a DIFFERENT workflow (e.g. /devflow:review) could
#     spuriously suppress a legitimate /devflow:implement. Record the gh argv and
#     assert the flag is present.
DI_REC="$(mktemp)"
DEVFLOW_GH="$DI_STUB/gh" GITHUB_EVENT_PATH='' REPO=o/r RUN_ID=200 CONTEXT_NUMBER=42 DEDUPE_RUNS_JSON='[]' \
  DI_ARGS_REC="$DI_REC" bash "$DIR" >/dev/null 2>&1
assert_eq "di: run list is scoped to --workflow devflow-implement.yml" "1" \
  "$(grep -c -- '--workflow devflow-implement.yml' "$DI_REC")"
rm -f "$DI_REC"

# 14. The duplicate-ignored NOTICE must carry no DevFlow trigger phrase, or the
#     bot's own comment would re-fire devflow-implement.yml (self-trigger loop).
#     Assert the workflow's notice body is phrase-free.
NOTICE_LINE="$(grep -A2 'Notice — duplicate ignored' "$LIB/../.github/workflows/devflow-implement.yml" || true; \
  grep 'NOTE=' "$LIB/../.github/workflows/devflow-implement.yml" || true)"
# Guard against a vacuous pass: if the grep window ever stops capturing the notice
# body, grep -c on empty input returns 0 and the phrase-free checks pass without
# inspecting anything. Assert we actually captured the notice first.
assert_eq "di: notice test captured the notice body (no vacuous pass)" "1" \
  "$(grep -c 'already in progress' <<< "$NOTICE_LINE")"
assert_eq "di: duplicate notice contains no /devflow: phrase" "0" \
  "$(grep -c '/devflow:' <<< "$NOTICE_LINE")"
assert_eq "di: duplicate notice contains no @claude" "0" \
  "$(grep -c '@claude' <<< "$NOTICE_LINE")"

# 15. Stall-backstop-resume carve-out (issue #280, deferred #268 finding): a run
#     triggered by the stall backstop's auto-resume comment must NOT dedupe against
#     the still-winding-down run it is taking over. With IS_STALL_RESUME=true (the
#     explicit override) the script proceeds even though an OLDER active run for the
#     same thread exists (case 1 above would otherwise be duplicate=true).
assert_eq "di: stall-backstop resume bypasses dedupe (older active peer present)" "duplicate=false" \
  "$(DEVFLOW_GH="$DI_STUB/gh" REPO=o/r RUN_ID=200 CONTEXT_NUMBER=42 IS_STALL_RESUME=true \
     DEDUPE_RUNS_JSON='[{"databaseId":100,"displayTitle":"DevFlow implement (issue 42)","status":"in_progress"}]' \
     bash "$DIR" 2>/dev/null)"
# 15b. The carve-out is opt-in: any non-"true" value dedupes normally (older active
#      peer → duplicate=true), so an unrelated command is never let through.
assert_eq "di: IS_STALL_RESUME=false still dedupes normally" "duplicate=true" \
  "$(DEVFLOW_GH="$DI_STUB/gh" REPO=o/r RUN_ID=200 CONTEXT_NUMBER=42 IS_STALL_RESUME=false \
     DEDUPE_RUNS_JSON='[{"databaseId":100,"displayTitle":"DevFlow implement (issue 42)","status":"in_progress"}]' \
     bash "$DIR" 2>/dev/null)"
# 15c. Self-derive from GITHUB_EVENT_PATH (the production path — no workflow env is
#      passed). A triggering comment whose body carries the stall-backstop-audit
#      marker bypasses dedupe; the same event without the marker dedupes normally.
DI_EVT_YES="$(mktemp)"; printf '%s' '{"comment":{"body":"<!-- devflow:stall-backstop-audit -->\n/devflow:implement 42"}}' > "$DI_EVT_YES"
DI_EVT_NO="$(mktemp)";  printf '%s' '{"comment":{"body":"/devflow:implement 42"}}' > "$DI_EVT_NO"
assert_eq "di: event-path comment carrying the stall marker bypasses dedupe" "duplicate=false" \
  "$(DEVFLOW_GH="$DI_STUB/gh" REPO=o/r RUN_ID=200 CONTEXT_NUMBER=42 GITHUB_EVENT_PATH="$DI_EVT_YES" \
     DEDUPE_RUNS_JSON='[{"databaseId":100,"displayTitle":"DevFlow implement (issue 42)","status":"in_progress"}]' \
     bash "$DIR" 2>/dev/null)"
assert_eq "di: event-path comment without the stall marker dedupes normally" "duplicate=true" \
  "$(DEVFLOW_GH="$DI_STUB/gh" REPO=o/r RUN_ID=200 CONTEXT_NUMBER=42 GITHUB_EVENT_PATH="$DI_EVT_NO" \
     DEDUPE_RUNS_JSON='[{"databaseId":100,"displayTitle":"DevFlow implement (issue 42)","status":"in_progress"}]' \
     bash "$DIR" 2>/dev/null)"
rm -f "$DI_EVT_YES" "$DI_EVT_NO"
# 15c-err. Fail-open detection errors (issue #280 hardening): the marker probe reads a
#      runner-provided payload, so a malformed/unreadable/missing GITHUB_EVENT_PATH must
#      NOT be mistaken for a resume — it falls through to ordinary dedupe (duplicate=true
#      when an older active peer exists). A genuine jq error (exit >1: bad JSON, empty
#      file) additionally emits a ::warning:: so the swallow is visible; a marker merely
#      ABSENT (jq exit 1) stays silent. All three run under set -euo pipefail without
#      aborting. The older-active-peer fixture makes the fall-through observable as
#      duplicate=true (a fail-open-to-dedupe result, not a bypass).
DI_PEER='[{"databaseId":100,"displayTitle":"DevFlow implement (issue 42)","status":"in_progress"}]'
DI_EVT_BAD="$(mktemp)"; printf '%s' 'not json{' > "$DI_EVT_BAD"
# malformed payload → jq exit >1 → fall through to dedupe (duplicate=true) + ::warning::
DI_BAD_ERR="$(mktemp)"
assert_eq "di: malformed GITHUB_EVENT_PATH → not a resume, ordinary dedupe applies" "duplicate=true" \
  "$(DEVFLOW_GH="$DI_STUB/gh" REPO=o/r RUN_ID=200 CONTEXT_NUMBER=42 GITHUB_EVENT_PATH="$DI_EVT_BAD" \
     DEDUPE_RUNS_JSON="$DI_PEER" bash "$DIR" 2>"$DI_BAD_ERR")"
assert_eq "di: malformed GITHUB_EVENT_PATH emits a ::warning:: (real error is not silent)" "1" \
  "$(grep -c '::warning::dedupe: could not read the stall-resume marker' "$DI_BAD_ERR")"
rm -f "$DI_EVT_BAD" "$DI_BAD_ERR"
# well-formed-but-wrong-SHAPE payload (top-level array/scalar, not an object): jq's
# `.comment` index raises an error → exit >1 → warning branch, same as malformed text.
# This is a distinct input class from "malformed text" — the adversarial input-shape
# matrix (CLAUDE.md best-effort-parser gotcha) designates a runner-provided payload
# parser subject to the {object, array, scalar, ...} sweep. Guards against a future
# `?`/`try` hardening silently flipping a wrong-type payload from warning to silent.
DI_EVT_ARR="$(mktemp)"; printf '%s' '[]' > "$DI_EVT_ARR"
DI_ARR_ERR="$(mktemp)"
assert_eq "di: wrong-type (array) GITHUB_EVENT_PATH → not a resume, ordinary dedupe applies" "duplicate=true" \
  "$(DEVFLOW_GH="$DI_STUB/gh" REPO=o/r RUN_ID=200 CONTEXT_NUMBER=42 GITHUB_EVENT_PATH="$DI_EVT_ARR" \
     DEDUPE_RUNS_JSON="$DI_PEER" bash "$DIR" 2>"$DI_ARR_ERR")"
assert_eq "di: wrong-type (array) GITHUB_EVENT_PATH emits a ::warning:: (real error is not silent)" "1" \
  "$(grep -c '::warning::dedupe: could not read the stall-resume marker' "$DI_ARR_ERR")"
rm -f "$DI_EVT_ARR" "$DI_ARR_ERR"
# empty-but-readable payload (the "empty file" example the code comment names): passes
# the [ -r ] guard, jq -e on empty input produces no output → exit 4 → warning branch.
DI_EVT_EMPTY="$(mktemp)"; printf '' > "$DI_EVT_EMPTY"
DI_EMPTY_ERR="$(mktemp)"
assert_eq "di: empty GITHUB_EVENT_PATH → not a resume, ordinary dedupe applies" "duplicate=true" \
  "$(DEVFLOW_GH="$DI_STUB/gh" REPO=o/r RUN_ID=200 CONTEXT_NUMBER=42 GITHUB_EVENT_PATH="$DI_EVT_EMPTY" \
     DEDUPE_RUNS_JSON="$DI_PEER" bash "$DIR" 2>"$DI_EMPTY_ERR")"
assert_eq "di: empty GITHUB_EVENT_PATH emits a ::warning:: (real error is not silent)" "1" \
  "$(grep -c '::warning::dedupe: could not read the stall-resume marker' "$DI_EMPTY_ERR")"
rm -f "$DI_EVT_EMPTY" "$DI_EMPTY_ERR"
# unreadable path (nonexistent) → the [ -r ] guard skips the probe → dedupe, no warning
DI_UNREAD_ERR="$(mktemp)"
assert_eq "di: nonexistent GITHUB_EVENT_PATH → not a resume, ordinary dedupe applies" "duplicate=true" \
  "$(DEVFLOW_GH="$DI_STUB/gh" REPO=o/r RUN_ID=200 CONTEXT_NUMBER=42 GITHUB_EVENT_PATH=/nonexistent/devflow-event.json \
     DEDUPE_RUNS_JSON="$DI_PEER" bash "$DIR" 2>"$DI_UNREAD_ERR")"
assert_eq "di: nonexistent GITHUB_EVENT_PATH emits no marker-read warning (guard skips probe)" "0" \
  "$(grep -c 'could not read the stall-resume marker' "$DI_UNREAD_ERR")"
rm -f "$DI_UNREAD_ERR"
# PRESENT-but-unreadable payload (issue #280 shadow finding): a file that EXISTS but
# cannot be read (permission/mount anomaly, a partially-materialised/locked payload) is
# a distinct input class from the NONEXISTENT path above — the [ -r ] guard fails on
# both, but only the present-but-unreadable one is an "unreadable payload" the header
# contract promises to WARN on. It must fall through to ordinary dedupe (duplicate=true
# with an older active peer) AND emit a ::warning:: (never a silent swallow of a
# possible genuine resume), unlike the absent-path case which stays silent. chmod a-r is
# a no-op under root (`[ -r ]` is always true), so guard on non-root like the F1 arm.
if [ "$(id -u)" != 0 ]; then
  DI_EVT_LOCKED="$(mktemp)"; printf '%s' '{"comment":{"body":"<!-- devflow:stall-backstop-audit -->"}}' > "$DI_EVT_LOCKED"; chmod a-r "$DI_EVT_LOCKED"
  DI_LOCKED_ERR="$(mktemp)"
  assert_eq "di: present-but-unreadable GITHUB_EVENT_PATH → not a resume, ordinary dedupe applies" "duplicate=true" \
    "$(DEVFLOW_GH="$DI_STUB/gh" REPO=o/r RUN_ID=200 CONTEXT_NUMBER=42 GITHUB_EVENT_PATH="$DI_EVT_LOCKED" \
       DEDUPE_RUNS_JSON="$DI_PEER" bash "$DIR" 2>"$DI_LOCKED_ERR")"
  assert_eq "di: present-but-unreadable GITHUB_EVENT_PATH emits a ::warning:: (unreadable payload is not silent)" "1" \
    "$(grep -c 'is set but not readable' "$DI_LOCKED_ERR")"
  chmod u+rw "$DI_EVT_LOCKED" 2>/dev/null || true
  rm -f "$DI_EVT_LOCKED" "$DI_LOCKED_ERR"
fi
# well-formed JSON missing .comment.body → marker genuinely absent (jq exit 1) → dedupe,
# no warning (an absent marker is the expected non-resume case, must stay silent).
DI_EVT_NOBODY="$(mktemp)"; printf '%s' '{"issue":{"number":42}}' > "$DI_EVT_NOBODY"
DI_NOBODY_ERR="$(mktemp)"
assert_eq "di: valid payload with no .comment.body → ordinary dedupe applies" "duplicate=true" \
  "$(DEVFLOW_GH="$DI_STUB/gh" REPO=o/r RUN_ID=200 CONTEXT_NUMBER=42 GITHUB_EVENT_PATH="$DI_EVT_NOBODY" \
     DEDUPE_RUNS_JSON="$DI_PEER" bash "$DIR" 2>"$DI_NOBODY_ERR")"
assert_eq "di: absent marker (jq exit 1) emits no warning (expected non-resume is silent)" "0" \
  "$(grep -c 'could not read the stall-resume marker' "$DI_NOBODY_ERR")"
rm -f "$DI_EVT_NOBODY" "$DI_NOBODY_ERR"
# 15d. Coupled cross-file invariant (issue #280): the stall-resume marker the dedupe
#      script keys on MUST stay identical to the marker the stall-backstop step
#      writes into its resume comment. Assert the exact literal is present in both.
DI_WF="$LIB/../.github/workflows/devflow-implement.yml"
assert_eq "di: dedupe script defines the stall-backstop-audit marker" "1" \
  "$(grep -c "STALL_RESUME_MARKER='<!-- devflow:stall-backstop-audit -->'" "$DIR")"
assert_eq "di: same stall-backstop-audit marker literal exists in the workflow (coupling holds)" "true" \
  "$(grep -q "<!-- devflow:stall-backstop-audit -->" "$DI_WF" && echo true || echo false)"

rm -rf "$DI_STUB"

# ────────────────────────────────────────────────────────────────────────────
echo "authorize-actor.sh (allowed_users filter)"
# ────────────────────────────────────────────────────────────────────────────
AUTH="$LIB/../scripts/authorize-actor.sh"
ASTUB="$(mktemp -d)"; cp "$LIB/test/fixtures/gh-stub.sh" "$ASTUB/gh"; chmod +x "$ASTUB/gh"
# Alice is the login the gh stub treats as a write/admin collaborator (mirrors
# the rit write-collaborator case: ACTOR='alice' STUB_PERM='write').
COLLAB="alice"
# shellcheck disable=SC1090,SC2154  # sources authorize-actor.sh at runtime; $authorized set there
run_auth() { ( PATH="$ASTUB:$PATH"; . "$AUTH"; authorize_actor; printf '%s' "$authorized" ); }
# shellcheck disable=SC1090,SC2154  # sources authorize-actor.sh at runtime; $deny_reason set there
run_auth_reason() { ( PATH="$ASTUB:$PATH"; . "$AUTH"; authorize_actor; printf '%s' "$deny_reason" ); }

# 1. Default (ALLOWED_USERS unset → '*') + collaborator → authorized.
A="$(ACTOR="$COLLAB" ALLOWED_BOTS="somebot" REPO="o/r" run_auth)"
assert_eq "auth: unset allowed_users + collaborator → authorized" "true" "$A"

# 2. Explicit '*' + collaborator → authorized.
A="$(ACTOR="$COLLAB" ALLOWED_BOTS="somebot" REPO="o/r" ALLOWED_USERS="*" run_auth)"
assert_eq "auth: '*' + collaborator → authorized" "true" "$A"

# 3. allowed_users lists the actor + collaborator → authorized.
A="$(ACTOR="$COLLAB" ALLOWED_BOTS="somebot" REPO="o/r" ALLOWED_USERS="$COLLAB,other" run_auth)"
assert_eq "auth: actor in allowed_users + collaborator → authorized" "true" "$A"

# 4. allowed_users does NOT list the actor → denied even though collaborator.
A="$(ACTOR="$COLLAB" ALLOWED_BOTS="somebot" REPO="o/r" ALLOWED_USERS="alice-x,bob" run_auth)"
assert_eq "auth: collaborator not in allowed_users → denied" "false" "$A"
R="$(ACTOR="$COLLAB" ALLOWED_BOTS="somebot" REPO="o/r" ALLOWED_USERS="alice-x,bob" run_auth_reason)"
assert_eq "auth: deny_reason cites allowed_users" "is not in the configured allowed_users allowlist" "$R"

# 5. Bot in allowed_bots bypasses allowed_users entirely.
A="$(ACTOR="somebot" ALLOWED_BOTS="somebot" REPO="o/r" ALLOWED_USERS="nobody" run_auth)"
assert_eq "auth: allowed bot bypasses allowed_users → authorized" "true" "$A"

rm -rf "$ASTUB"

# ────────────────────────────────────────────────────────────────────────────
echo "detect-standalone-command.sh"
# ────────────────────────────────────────────────────────────────────────────
# Shared markdown-aware standalone-command detector (issue #314). It fires only
# on a light /devflow:* command that is the sole content of its own line — at
# most three leading spaces, not tab/4+-indented, not inside a fenced block, and
# with the remainder at most an optional #-number — and declines any command
# merely quoted in prose, blockquoted, indented, or fenced. It is the single
# scanner both resolve-command-trigger.sh AND the review_dedupe job route
# through, so the two matchers cannot drift. Reads the body on stdin; emits
# `command=`/`number=`. No gh, no network — pure text.
DSC="$LIB/../scripts/detect-standalone-command.sh"
dsc_cmd() { printf '%s' "$1" | bash "$DSC" | sed -n 's/^command=//p'; }
dsc_num() { printf '%s' "$1" | bash "$DSC" | sed -n 's/^number=//p'; }

# --- Standalone forms FIRE (command resolves) -------------------------------
assert_eq "dsc: bare /devflow:review fires" \
  "/devflow:review" "$(dsc_cmd '/devflow:review')"
assert_eq "dsc: /devflow:review 42 → number 42" \
  "42" "$(dsc_num '/devflow:review 42')"
assert_eq "dsc: /devflow:review #42 → number 42 (# stripped)" \
  "42" "$(dsc_num '/devflow:review #42')"
assert_eq "dsc: review-and-fix disambiguation (never bare review)" \
  "/devflow:review-and-fix" "$(dsc_cmd '/devflow:review-and-fix')"
assert_eq "dsc: /devflow:pr-description fires" \
  "/devflow:pr-description" "$(dsc_cmd '/devflow:pr-description')"
assert_eq "dsc: up to three leading spaces still fires" \
  "/devflow:review" "$(dsc_cmd '   /devflow:review')"
assert_eq "dsc: command alone on line 2 of a multi-line body fires" \
  "/devflow:review" "$(dsc_cmd "$(printf 'hello world\n/devflow:review\nbye')")"

# --- Non-invoking forms are DECLINED (empty command) ------------------------
assert_eq "dsc: leading prose declined" \
  "" "$(dsc_cmd 'please run /devflow:review')"
assert_eq "dsc: trailing prose declined" \
  "" "$(dsc_cmd '/devflow:review please look')"
assert_eq "dsc: > blockquote declined" \
  "" "$(dsc_cmd '> /devflow:review')"
assert_eq "dsc: four-plus-space indent (code block) declined" \
  "" "$(dsc_cmd '    /devflow:review')"
assert_eq "dsc: tab indent (code block) declined" \
  "" "$(dsc_cmd "$(printf '\t/devflow:review')")"
assert_eq "dsc: inside a triple-backtick fenced block (with info string) declined" \
  "" "$(dsc_cmd "$(printf 'text\n```bash\n/devflow:review\n```\nmore')")"
assert_eq "dsc: inside a ~~~ fenced block declined" \
  "" "$(dsc_cmd "$(printf '~~~\n/devflow:review\n~~~')")"
assert_eq "dsc: fail-closed after an UNBALANCED (unclosed) fence" \
  "" "$(dsc_cmd "$(printf '```\n/devflow:review')")"
assert_eq "dsc: reported PR-review-body prose mention declined" \
  "" "$(dsc_cmd 'I ran /devflow:review earlier, see the report')"

# --- #314 review fixes: CRLF, case-insensitivity, mismatched fence type ------
# CRLF: GitHub delivers comment/review bodies with \r\n line endings; a trailing
# \r must not make an end-anchored standalone command silently decline.
assert_eq "dsc: CRLF-terminated bare command still fires" \
  "/devflow:review" "$(dsc_cmd "$(printf '/devflow:review\r')")"
assert_eq "dsc: CRLF-terminated command keeps its number" \
  "42" "$(dsc_num "$(printf '/devflow:review 42\r')")"
assert_eq "dsc: CRLF multi-line body — standalone command on its own \\r\\n line fires" \
  "/devflow:review" "$(dsc_cmd "$(printf 'kick it off\r\n/devflow:review\r\nthanks\r')")"
# Case-insensitivity is documented; pin it so a dropped tolower() goes RED.
assert_eq "dsc: uppercase /DEVFLOW:REVIEW fires (case-insensitive), canonical token emitted" \
  "/devflow:review" "$(dsc_cmd '/DEVFLOW:REVIEW')"
assert_eq "dsc: mixed-case command keeps its number" \
  "7" "$(dsc_num '/Devflow:Review 7')"
# Mismatched fence type: a ~~~ line inside a ``` block (or vice versa) is literal
# content per GFM — it must NOT close the outer fence and expose the command.
assert_eq "dsc: tilde-fence line inside a backtick fence does not expose the command (type-tracked)" \
  "" "$(dsc_cmd "$(printf '%s\n' '```' '~~~' '/devflow:review' '```')")"
assert_eq "dsc: backtick-fence line inside a tilde fence does not expose the command (type-tracked)" \
  "" "$(dsc_cmd "$(printf '%s\n' '~~~' '```' '/devflow:review' '~~~')")"
# review-and-fix with an explicit #number resolves the number (was only pinned for review).
assert_eq "dsc: review-and-fix #number resolves both command and number" \
  "/devflow:review-and-fix" "$(dsc_cmd '/devflow:review-and-fix #9')"
assert_eq "dsc: review-and-fix #number — number extracted" \
  "9" "$(dsc_num '/devflow:review-and-fix #9')"

# ────────────────────────────────────────────────────────────────────────────
echo "resolve-command-trigger.sh"
# ────────────────────────────────────────────────────────────────────────────
# Light command dispatch (review / review-and-fix / pr-description) in AGENT
# mode. Authorizes the sender (allowed bot bypasses gh; otherwise allowed_users
# + collaborator), detects the command, and resolves a target number. Reuses
# gh-stub.sh (alice → write collaborator; any other actor → HTTP 404).
RCT="$LIB/../scripts/resolve-command-trigger.sh"
# Pin TARGETS are spelled as $LIB-relative path VARIABLES, never inlined into the
# pin call as "$LIB/../…". pin-corpus-lint.py resolves a `VAR="$LIB/relative"`
# assignment but cannot resolve an interpolated path sitting directly in the
# argument, so an inlined target leaves the pin UNRESOLVED — surfaced on stderr but
# never asserted, i.e. silently exempt from the pin-in-comment and wrapped-literal
# meta-guards (the extraction hazard issue #746 names). Same file either way at run
# time; only the static resolvability differs.
RCT_WF_DEVFLOW="$LIB/../.github/workflows/devflow.yml"
RCT_STUB="$(mktemp -d)"; cp "$LIB/test/fixtures/gh-stub.sh" "$RCT_STUB/gh"; chmod +x "$RCT_STUB/gh"

# 1. Allowed bot, /devflow:review with explicit number → review command.
OUT="$(PATH="$RCT_STUB:$PATH" ACTOR="devflow-bot" ALLOWED_BOTS="devflow-bot" \
  REPO="o/r" GH_TOKEN="x" CONTEXT_NUMBER="99" \
  TRIGGER_TEXT="/devflow:review #42" bash "$RCT")"
assert_eq "rct: review w/ explicit number → should_run" \
  "should_run=true" "$(echo "$OUT" | grep '^should_run=')"
assert_eq "rct: review w/ explicit number → command" \
  "command=/devflow:review 42" "$(echo "$OUT" | grep '^command=')"

# 2. review-and-fix disambiguation, STANDALONE form. (Rewritten for issue #314:
# the old assertion fed the prose-wrapped "please run /devflow:review-and-fix
# now" and expected it to FIRE — under standalone anchoring that prose form now
# correctly DECLINES, so the input is rewritten to the standalone command.
# review-and-fix must still win over the /devflow:review substring it contains.)
OUT="$(PATH="$RCT_STUB:$PATH" ACTOR="devflow-bot" ALLOWED_BOTS="devflow-bot" \
  REPO="o/r" GH_TOKEN="x" CONTEXT_NUMBER="7" \
  TRIGGER_TEXT="/devflow:review-and-fix" bash "$RCT")"
assert_eq "rct: standalone review-and-fix beats review substring → command" \
  "command=/devflow:review-and-fix 7" "$(echo "$OUT" | grep '^command=')"

# 3. pr-description, no explicit number → falls back to the context number.
OUT="$(PATH="$RCT_STUB:$PATH" ACTOR="devflow-bot" ALLOWED_BOTS="devflow-bot" \
  REPO="o/r" GH_TOKEN="x" CONTEXT_NUMBER="13" \
  TRIGGER_TEXT="/devflow:pr-description" bash "$RCT")"
assert_eq "rct: pr-description falls back to context number → command" \
  "command=/devflow:pr-description 13" "$(echo "$OUT" | grep '^command=')"

# 4. No devflow command present → should_run=false.
OUT="$(PATH="$RCT_STUB:$PATH" ACTOR="devflow-bot" ALLOWED_BOTS="devflow-bot" \
  REPO="o/r" GH_TOKEN="x" CONTEXT_NUMBER="1" \
  TRIGGER_TEXT="just a normal comment" bash "$RCT")"
assert_eq "rct: no command → should_run=false" \
  "should_run=false" "$(echo "$OUT" | grep '^should_run=')"

# 5. Unauthorized actor (gh-stub 404 → not a collaborator) → should_run=false.
OUT="$(PATH="$RCT_STUB:$PATH" ACTOR="random-user" ALLOWED_BOTS="devflow-bot" \
  REPO="o/r" GH_TOKEN="x" CONTEXT_NUMBER="5" \
  TRIGGER_TEXT="/devflow:review" bash "$RCT")"
assert_eq "rct: unauthorized actor → should_run=false" \
  "should_run=false" "$(echo "$OUT" | grep '^should_run=')"

# --- issue #314: standalone anchoring at the resolver boundary ---------------
# A helper that captures BOTH stdout and stderr, so we can assert the auditable
# ::warning:: on the decline paths (an authorized bot, so any decline is the
# ANCHORING/self-marker decision, never an authorization one).
rct_run() {  # trigger-text [context-number] -> sets RCT_OUT / RCT_ERR
  local text="$1" ctx="${2:-99}"
  RCT_ERR="$(mktemp)"
  RCT_OUT="$(PATH="$RCT_STUB:$PATH" ACTOR="devflow-bot" ALLOWED_BOTS="devflow-bot" \
    REPO="o/r" GH_TOKEN="x" CONTEXT_NUMBER="$ctx" \
    TRIGGER_TEXT="$text" bash "$RCT" 2>"$RCT_ERR")"
}

# 6. THE DEFECT / regression pin: a body whose only occurrence is a QUOTED
# mention must decline (should_run=false) AND emit an auditable ::warning:: —
# never the silent should_run=true today's substring resolver produced. This is
# the PASS→FAIL pin: against the pre-#314 substring matcher this asserted
# should_run=true, so it fails there and passes after anchoring.
rct_run "I ran /devflow:review earlier"
assert_eq "rct #314: quoted mention → should_run=false" \
  "should_run=false" "$(echo "$RCT_OUT" | grep '^should_run=')"
assert_eq "rct #314: quoted mention emits an auditable ::warning::" \
  "1" "$(grep -c '::warning::No STANDALONE' "$RCT_ERR")"; rm -f "$RCT_ERR"

# 7. The reported vector: a PR-review-body-shaped prose paragraph quoting
# /devflow:review resolves should_run=false (TRIGGER_TEXT is the review body).
rct_run "Thanks for the fix. As /devflow:review flagged, the edge case is now handled — approving."
assert_eq "rct #314: PR-review-body prose mention → should_run=false" \
  "should_run=false" "$(echo "$RCT_OUT" | grep '^should_run=')"

# 8. Each non-invoking form declines: leading prose, > blockquote, 4-space and
# tab indent, and inside a fenced block (both fence flavors + unclosed).
rct_run "please run /devflow:review"
assert_eq "rct #314: leading prose → should_run=false" \
  "should_run=false" "$(echo "$RCT_OUT" | grep '^should_run=')"; rm -f "$RCT_ERR"
rct_run "> /devflow:review"
assert_eq "rct #314: blockquote → should_run=false" \
  "should_run=false" "$(echo "$RCT_OUT" | grep '^should_run=')"; rm -f "$RCT_ERR"
rct_run "    /devflow:review"
assert_eq "rct #314: four-space indent → should_run=false" \
  "should_run=false" "$(echo "$RCT_OUT" | grep '^should_run=')"; rm -f "$RCT_ERR"
rct_run "$(printf '\t/devflow:review')"
assert_eq "rct #314: tab indent → should_run=false" \
  "should_run=false" "$(echo "$RCT_OUT" | grep '^should_run=')"; rm -f "$RCT_ERR"
rct_run "$(printf 'see below\n```\n/devflow:review\n```')"
assert_eq "rct #314: inside a triple-backtick fence → should_run=false" \
  "should_run=false" "$(echo "$RCT_OUT" | grep '^should_run=')"; rm -f "$RCT_ERR"
rct_run "$(printf '~~~\n/devflow:review\n~~~')"
assert_eq "rct #314: inside a ~~~ fence → should_run=false" \
  "should_run=false" "$(echo "$RCT_OUT" | grep '^should_run=')"; rm -f "$RCT_ERR"
rct_run "$(printf '```\n/devflow:review')"
assert_eq "rct #314: fail-closed after an unclosed fence → should_run=false" \
  "should_run=false" "$(echo "$RCT_OUT" | grep '^should_run=')"; rm -f "$RCT_ERR"

# 9. A STANDALONE command inside a longer multi-line body still fires (the
# anchoring declines only the quoted forms, never a genuine own-line command).
rct_run "$(printf 'Here is the PR summary.\n\n/devflow:review 42\n\nthanks')"
assert_eq "rct #314: standalone command on its own line in a multi-line body fires" \
  "should_run=true" "$(echo "$RCT_OUT" | grep '^should_run=')"
assert_eq "rct #314: …and resolves the explicit number" \
  "command=/devflow:review 42" "$(echo "$RCT_OUT" | grep '^command=')"; rm -f "$RCT_ERR"

# 10. Self-marker decline (defense-in-depth), asserted BEFORE authorization:
# the review-progress marker prefix and the workpad marker each decline with a
# self-trigger ::warning::, even though the body also carries a standalone-looking
# command. (Authorized bot, so this is the marker decision, not authorization.)
rct_run "$(printf '<!-- devflow:review-progress run=123-1 -->\n/devflow:review')"
assert_eq "rct #314: review-progress marker → should_run=false" \
  "should_run=false" "$(echo "$RCT_OUT" | grep '^should_run=')"
assert_eq "rct #314: review-progress marker emits a self-trigger ::warning::" \
  "1" "$(grep -c '::warning::light /devflow:. trigger came from a Devflow-authored comment' "$RCT_ERR")"; rm -f "$RCT_ERR"
rct_run "$(printf '<!-- devflow:workpad -->\n/devflow:review')"
assert_eq "rct #314: workpad marker → should_run=false" \
  "should_run=false" "$(echo "$RCT_OUT" | grep '^should_run=')"; rm -f "$RCT_ERR"

# 11. Missing/unrunnable detector → fail-closed decline with a DISTINCT
# broken-install breadcrumb (not a generic bash error, not the misdirected
# "no standalone command" message). Run a resolver copy from a temp dir with NO
# sibling detect-standalone-command.sh so `$(dirname "$0")/detect-...` is absent.
NODET_DIR="$(mktemp -d)"; cp "$RCT" "$NODET_DIR/resolve-command-trigger.sh"
cp "$LIB/../scripts/authorize-actor.sh" "$NODET_DIR/authorize-actor.sh"
NODET_ERR="$(mktemp)"
NODET_OUT="$(PATH="$RCT_STUB:$PATH" ACTOR="devflow-bot" ALLOWED_BOTS="devflow-bot" \
  REPO="o/r" GH_TOKEN="x" CONTEXT_NUMBER="5" \
  TRIGGER_TEXT="/devflow:review" bash "$NODET_DIR/resolve-command-trigger.sh" 2>"$NODET_ERR")"
assert_eq "rct #314: missing detector → should_run=false (fail-closed)" \
  "should_run=false" "$(echo "$NODET_OUT" | grep '^should_run=')"
assert_eq "rct #314: missing detector emits a distinct broken-install ::warning::" \
  "1" "$(grep -c '::warning::standalone-command detector' "$NODET_ERR")"
rm -rf "$NODET_DIR"; rm -f "$NODET_ERR"

rm -rf "$RCT_STUB"

# --- issue #314: coupled-invariant pin (resolver ↔ shared detector) ----------
# The resolver MUST route through the ONE shared detector; a future divergence
# (re-inlining a substring matcher) is caught here.
devflow_module_pin_unique "rct #314: resolver calls the shared detect-standalone-command.sh" \
  'detector="$(dirname "$0")/detect-standalone-command.sh"' "$RCT"

# --- issue #321: coupled-invariant pin (dedupe ↔ shared detector) ------------
# The twin of the #314 pin above, landed once the workflows-scoped push became
# possible (a human/PAT push the DevFlow bot token cannot make). The
# review_dedupe job in devflow.yml MUST route its body match through the SAME
# vendored detector so the trigger gate and the dedupe matcher cannot drift;
# re-inlining a `case "$BODY"` substring here would re-open that drift.
devflow_module_pin_unique "rct #321: review_dedupe routes through the shared detect-standalone-command.sh" \
  '.devflow/vendor/devflow/scripts/detect-standalone-command.sh' "$RCT_WF_DEVFLOW"

# review_dedupe is fail-OPEN by contract: a present-but-broken detector (or a
# missing sed) must NOT abort the guard step under `set -euo pipefail` — an abort
# fails the job, skipping the downstream `command` job and silently swallowing the
# manual review. Pin the outcome-verifying `if !` wrapper (the operative fix);
# reverting it to a bare `CMD=$(...)` assignment re-opens the fail-CLOSED swallow.
devflow_module_pin_unique "rct #321: review_dedupe detector extraction fails open on a run failure (if!-guarded)" \
  'if ! CMD="$(printf '"'"'%s'"'"' "$BODY" | bash "$DETECTOR" | sed -n '"'"'s/^command=//p'"'"')"' "$RCT_WF_DEVFLOW"
