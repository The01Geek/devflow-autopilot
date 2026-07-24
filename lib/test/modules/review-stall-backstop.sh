# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# shellcheck shell=bash
# Sourceable review stall-backstop contract module (issue #746 tranche).
# Contract: the caller sets LIB and RESULTS_FILE, defines assert_eq, and sources
# lib/test/module-harness.sh first (which defines the namespaced module pin API:
# devflow_module_pin_count / devflow_module_pin_unique / devflow_module_pin_present /
# devflow_module_pin_red_under, plus devflow_module_build_bundle). This module uses
# assert_eq plus that namespaced API — it references NO monolith helper. Every path
# derives from LIB. The module owns its private fixture root and cleanup; it never
# invokes the runner or the full-suite boundary. The inventory in
# review-stall-backstop.inventory.md maps the extracted coverage to its former
# run.sh locations. Modules may not self-skip.
# The `trap _rsb_cleanup EXIT` below relies on a sourcing contract: both callers
# (module-harness.sh's full-suite boundary and run-module.sh) source this module
# inside a ( ... ) subshell, so the trap fires at subshell exit and cannot clobber
# the runner's own EXIT handling. Do not source this module directly in a runner's
# top-level shell without restoring the trap.

# Allocate through the harness's shared owned-directory allocator (template validation
# plus the pre-existing-directory rejection a bare `mktemp -d` cannot make) rather than
# re-implementing that check here. This module keeps a private root because it builds
# one real artifact into it (the review-engine bundle below); the sibling modules in
# this tranche allocate none and rely on the boundary-owned scratch root instead.
_rsb_tmp_root="$(devflow_module_allocate_owned_directory \
  "${TMPDIR:-/tmp}/devflow-review-stall-backstop.XXXXXX")" || {
  assert_eq "review-stall-backstop module: private fixture root allocated" "yes" "no"
  return 0 2>/dev/null || exit 0
}
_rsb_cleanup() {
  rm -rf "$_rsb_tmp_root"
}
trap _rsb_cleanup EXIT

# Two run.sh globals the extracted sections read are re-derived here rather than
# inherited, because a module receives neither:
#   REPO_ROOT     — the monolith computes it the same way, from LIB.
#   REVIEW_BUNDLE — the concatenated review-engine bundle (thin root + every phase
#                   reference). Two #408 pins target it, because the sentences they
#                   pin may live in the root or in any phase reference and the
#                   bundle is what makes the pin location-independent. The stem list
#                   is DERIVED FROM THE TREE (every skills/review/phases/*.md), not
#                   transcribed: a transcribed list would let a phase reference added
#                   later be silently omitted, and the survival pins would then assert
#                   against a bundle missing that prose, passing green over unguarded
#                   text.
# Spelled `"$LIB/.."` rather than the monolith's `"$(cd "$LIB/.." && pwd)"` on
# purpose. Both name the same directory at run time (LIB is already absolute), but
# only this form is statically resolvable by pin-corpus-lint.py's path-variable
# resolver, which understands a `$LIB/relative` assignment and cannot see through a
# command substitution. Nearly every pin below targets a var derived from REPO_ROOT,
# so the substitution form would leave those UNRESOLVED — surfaced on stderr but
# never asserted, i.e. silently exempt from the meta-guard (the extraction hazard
# issue #746 names). With this form they resolve and stay covered. The exception is
# the REVIEW_SKILL408 pins, which target the runtime bundle temp below: no spelling
# here can make those statically resolvable, so run.sh binds them explicitly through
# RSB_MOD_VARS instead.
REPO_ROOT="$LIB/.."
REVIEW_BUNDLE="$_rsb_tmp_root/review-skill-bundle.md"
# The glob is passed straight through with no `[ -r ] || continue` prefilter: the
# builder's contract is that an unusable member lands in the tally as a named RED
# assertion, and a prefilter would drop exactly the member it exists to report. An
# unmatched glob reaches the builder as its own literal and fails there by name too,
# so a phases/ directory that has moved or emptied is a diagnosis rather than a
# silently thinner bundle every survival pin then passes against for the wrong reason.
devflow_module_build_bundle "review-skill" "$REVIEW_BUNDLE" \
  "$REPO_ROOT/skills/review/SKILL.md" "$REPO_ROOT"/skills/review/phases/*.md

# ────────────────────────────────────────────────────────────────────────────
echo "#408 cloud review no-verdict auto-resume backstop"
# ────────────────────────────────────────────────────────────────────────────
# request-review-backstop.sh owns the whole fire/no-fire decision (config read,
# verdict guard, per-head attempt count, App-token guard, marker construction), so
# every arm is drivable here with a stubbed gh + config fixtures. RED pre-change
# (the helper does not exist → `bash <missing>` prints nothing / exits 127, so each
# assert_eq fails). The guarantee-class arm is the decisive one: an incomplete
# verdict with no prior attempts and an App token present MUST decide `fire`, or the
# whole backstop is a no-op on exactly the input it exists to catch.
RRB408="$REPO_ROOT/scripts/request-review-backstop.sh"
T408="$(mktemp -d)"
# gh stubs — single executables (DEVFLOW_GH must be one token). Each answers the
# issue-comments endpoint (marker count) and `repo view`.
cat > "$T408/gh-empty.sh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"/comments"*) echo '[]' ;;
  *"repo view"*) echo 'o/r' ;;
  *) echo '[]' ;;
esac
EOF
cat > "$T408/gh-2markers.sh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"/comments"*) echo '[{"body":"<!-- devflow:review-backstop head=abc attempt=1 -->"},{"body":"<!-- devflow:review-backstop head=abc attempt=2 -->"},{"body":"<!-- devflow:review-backstop head=zzz attempt=9 -->"}]' ;;
  *"repo view"*) echo 'o/r' ;;
  *) echo '[]' ;;
esac
EOF
cat > "$T408/gh-foreign.sh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"/comments"*) echo '[{"body":"<!-- devflow:review-backstop head=zzz attempt=1 -->"}]' ;;
  *"repo view"*) echo 'o/r' ;;
  *) echo '[]' ;;
esac
EOF
cat > "$T408/gh-fail.sh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"/comments"*) echo "HTTP 500" >&2; exit 1 ;;
  *"repo view"*) echo 'o/r' ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$T408"/*.sh
printf '%s\n' '{"devflow_review":{"stall_backstop":{"enabled":false,"max_resume_attempts":2}}}' > "$T408/cfg-disabled.json"
printf '%s\n' '{"devflow_review":{"stall_backstop":{"enabled":true,"max_resume_attempts":2}}}' > "$T408/cfg-enabled.json"
# rrb408 <gh-stub> <verdict> <head> <pr> <repo> <app-present> [config-file] -> emits `decision=` value
rrb408() {
  DEVFLOW_GH="$T408/$1" VERDICT="$2" HEAD_SHA="$3" PR_NUMBER="$4" REPO="$5" APP_TOKEN_PRESENT="$6" CONFIG_FILE="${7:-}" \
    bash "$RRB408" 2>/dev/null | sed -n 's/^decision=//p'
}
rrb408_reason() {
  DEVFLOW_GH="$T408/$1" VERDICT="$2" HEAD_SHA="$3" PR_NUMBER="$4" REPO="$5" APP_TOKEN_PRESENT="$6" CONFIG_FILE="${7:-}" \
    bash "$RRB408" 2>/dev/null | sed -n 's/^reason=//p'
}
# Guarantee-class: success-with-no-verdict must decide fire.
assert_eq "#408 helper: incomplete + under cap + App token -> fire (guarantee-class success-no-verdict path)" \
  "fire" "$(rrb408 gh-empty.sh incomplete abc 5 o/r true "$T408/cfg-enabled.json")"
# A positively-observed verdict is a decided end — never resume (both directions).
assert_eq "#408 helper: verdict approve -> no-fire (never resume a decided verdict)" \
  "no-fire" "$(rrb408 gh-empty.sh approve abc 5 o/r true "$T408/cfg-enabled.json")"
assert_eq "#408 helper: verdict approve -> reason verdict-exists" \
  "verdict-exists" "$(rrb408_reason gh-empty.sh approve abc 5 o/r true "$T408/cfg-enabled.json")"
assert_eq "#408 helper: verdict reject -> no-fire (never resume a decided verdict)" \
  "no-fire" "$(rrb408 gh-empty.sh reject abc 5 o/r true "$T408/cfg-enabled.json")"
# #312 valid-falsy row: a real JSON `false` disables the backstop (an `// true`
# coercion that ignores explicit false would still fire → RED here).
assert_eq "#408 helper: enabled real-JSON-false -> no-fire (the #312 valid-falsy row)" \
  "no-fire" "$(rrb408 gh-empty.sh incomplete abc 5 o/r true "$T408/cfg-disabled.json")"
assert_eq "#408 helper: enabled false -> reason disabled" \
  "disabled" "$(rrb408_reason gh-empty.sh incomplete abc 5 o/r true "$T408/cfg-disabled.json")"
# Cap enforcement: 2 same-head markers at cap 2 -> exhausted (no-fire).
assert_eq "#408 helper: attempts at cap -> no-fire (exhausted)" \
  "no-fire" "$(rrb408 gh-2markers.sh incomplete abc 5 o/r true "$T408/cfg-enabled.json")"
assert_eq "#408 helper: attempts at cap -> reason exhausted" \
  "exhausted" "$(rrb408_reason gh-2markers.sh incomplete abc 5 o/r true "$T408/cfg-enabled.json")"
# Foreign-head markers must NOT count: only a head=zzz marker present, so head=abc
# has 0 attempts -> fire (if foreign counted, this would read exhausted/attempt≠1).
assert_eq "#408 helper: foreign-head marker not counted for this head -> fire" \
  "fire" "$(rrb408 gh-foreign.sh incomplete abc 5 o/r true "$T408/cfg-enabled.json")"
# Unreadable comment count fails CLOSED (never resume on an unknowable count).
assert_eq "#408 helper: comments query failure -> no-fire (count-unreadable, fail closed)" \
  "no-fire" "$(rrb408 gh-fail.sh incomplete abc 5 o/r true "$T408/cfg-enabled.json")"
assert_eq "#408 helper: comments query failure -> reason count-unreadable" \
  "count-unreadable" "$(rrb408_reason gh-fail.sh incomplete abc 5 o/r true "$T408/cfg-enabled.json")"
# No App token: a GITHUB_TOKEN comment never re-triggers, so no-fire (degrade to flip).
assert_eq "#408 helper: no App token -> no-fire (a GITHUB_TOKEN comment cannot re-trigger)" \
  "no-fire" "$(rrb408 gh-empty.sh incomplete abc 5 o/r false "$T408/cfg-enabled.json")"
assert_eq "#408 helper: no App token -> reason no-app-token" \
  "no-app-token" "$(rrb408_reason gh-empty.sh incomplete abc 5 o/r false "$T408/cfg-enabled.json")"
# Empty head SHA cannot scope the markers -> no-fire (never an unbounded resume).
assert_eq "#408 helper: empty HEAD_SHA -> no-fire (unscoped)" \
  "no-fire" "$(rrb408 gh-empty.sh incomplete '' 5 o/r true "$T408/cfg-enabled.json")"
# The fire path emits the head-scoped marker with the next attempt number.
RRB408_FIRE="$(DEVFLOW_GH="$T408/gh-empty.sh" VERDICT=incomplete HEAD_SHA=abc PR_NUMBER=5 REPO=o/r APP_TOKEN_PRESENT=true CONFIG_FILE="$T408/cfg-enabled.json" bash "$RRB408" 2>/dev/null)"
assert_eq "#408 helper: fire emits the head-scoped marker with the next attempt" "yes" \
  "$(printf '%s\n' "$RRB408_FIRE" | grep -qxF 'marker=<!-- devflow:review-backstop head=abc attempt=1 -->' && echo yes || echo no)"
# Always exits 0 (best-effort — caller reads `decision`, not the exit code).
DEVFLOW_GH="$T408/gh-fail.sh" VERDICT=incomplete HEAD_SHA=abc PR_NUMBER=5 REPO=o/r APP_TOKEN_PRESENT=true bash "$RRB408" >/dev/null 2>&1
assert_eq "#408 helper: always exits 0 even on a fail-closed arm" "0" "$?"
# MAX edge rows (the silent-coercion class, #312 discipline): max_resume_attempts=0
# must be honored (0 >= 0 → exhausted even with zero markers — detect-and-flip only),
# and a non-integer cap must fall back to the default 2 (so a fresh head still fires).
printf '%s\n' '{"devflow_review":{"stall_backstop":{"enabled":true,"max_resume_attempts":0}}}' > "$T408/cfg-max0.json"
printf '%s\n' '{"devflow_review":{"stall_backstop":{"enabled":true,"max_resume_attempts":"notanum"}}}' > "$T408/cfg-badmax.json"
assert_eq "#408 helper: max_resume_attempts=0 honored -> no-fire (exhausted, detect-and-flip only)" \
  "exhausted" "$(rrb408_reason gh-empty.sh incomplete abc 5 o/r true "$T408/cfg-max0.json")"
assert_eq "#408 helper: non-integer max_resume_attempts falls back to default 2 -> fire" \
  "fire" "$(rrb408 gh-empty.sh incomplete abc 5 o/r true "$T408/cfg-badmax.json")"
# Empty REPO is derived via `gh repo view` (the standalone/unit path; the workflow
# always passes REPO) — the stub's repo-view arm resolves o/r, so a fresh head fires.
assert_eq "#408 helper: empty REPO derived via gh repo view -> fire" \
  "fire" "$(rrb408 gh-empty.sh incomplete abc 5 '' true "$T408/cfg-enabled.json")"
# Nonzero attempt-increment (PR #410 review gap): 1 prior SAME-head marker under a
# cap of 3 must fire with attempt=2 — the NEXT=ATTEMPTS+1 path was only ever driven
# at ATTEMPTS=0 (attempt=1), so an off-by-one that re-emitted attempt=1 (a duplicate
# marker that never advances the cap → unbounded loop) would have passed. Pins the
# increment AND the emitted marker's attempt number at a nonzero base.
cat > "$T408/gh-1marker.sh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"/comments"*) echo '[{"body":"<!-- devflow:review-backstop head=abc attempt=1 -->"},{"body":"<!-- devflow:review-backstop head=zzz attempt=1 -->"}]' ;;
  *"repo view"*) echo 'o/r' ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$T408/gh-1marker.sh"
printf '%s\n' '{"devflow_review":{"stall_backstop":{"enabled":true,"max_resume_attempts":3}}}' > "$T408/cfg-max3.json"
assert_eq "#408 helper: 1 prior same-head marker under cap -> fire (attempts>0 increment path)" \
  "fire" "$(rrb408 gh-1marker.sh incomplete abc 5 o/r true "$T408/cfg-max3.json")"
RRB408_FIRE2="$(DEVFLOW_GH="$T408/gh-1marker.sh" VERDICT=incomplete HEAD_SHA=abc PR_NUMBER=5 REPO=o/r APP_TOKEN_PRESENT=true CONFIG_FILE="$T408/cfg-max3.json" bash "$RRB408" 2>/dev/null)"
assert_eq "#408 helper: nonzero-base fire emits the NEXT attempt number (attempt=2, not a re-emitted attempt=1)" "yes" \
  "$(printf '%s\n' "$RRB408_FIRE2" | grep -qxF 'marker=<!-- devflow:review-backstop head=abc attempt=2 -->' && echo yes || echo no)"
# Hard config-read failure (PR #410 review gap): a MALFORMED config makes
# config-get.sh hard-fail with empty stdout, and the helper still resolves toward
# firing — the documented honest-failure direction (a review backstop must stay
# armed when the config can't be read, not silently disable the safety net). This
# is defense-in-depth: the malformed->fire direction is held by BOTH the
# `[ -n "$ENABLED" ] || ENABLED=true` fallback AND the exact-match disable guard
# (`[ "$ENABLED" = "false" ]`, so an empty ENABLED is never "disabled"), so
# removing either single guard alone still fires. This asserts the AGGREGATE
# malformed->fire direction (previously untested); it deliberately does NOT isolate
# one fallback line — a regression that instead resolves malformed->no-fire (e.g.
# the fallback set to `false`) flips it RED. The aggregate stays bounded — a fire
# still requires App token + scope + under-cap, all covered above.
printf '%s\n' '{ this is not valid json' > "$T408/cfg-malformed.json"
assert_eq "#408 helper: malformed config hard-fail -> fire (honest-failure resolves toward ENABLED, net stays armed)" \
  "fire" "$(rrb408 gh-empty.sh incomplete abc 5 o/r true "$T408/cfg-malformed.json")"
# MARKER_PREFIX trailing-space disambiguation (PR #410 review gap): the count key is
# `head=<sha> ` WITH a trailing space so a short head cannot prefix-match a longer one
# (`head=ab ` must NOT match a `head=abc ...` marker). The foreign-head fixtures above
# use equal-length non-overlapping heads (abc vs zzz), so deleting that trailing space
# would NOT turn them RED. Drive the collision directly: HEAD_SHA=ab against a marker
# for head=abc must count 0 (fire attempt=1); if the trailing space were dropped,
# `head=ab` would substring-match `head=abc` -> count 1 -> attempt=2.
cat > "$T408/gh-prefixcollide.sh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"/comments"*) echo '[{"body":"<!-- devflow:review-backstop head=abc attempt=9 -->"}]' ;;
  *"repo view"*) echo 'o/r' ;;
  *) echo '[]' ;;
esac
EOF
chmod +x "$T408/gh-prefixcollide.sh"
RRB408_COLLIDE="$(DEVFLOW_GH="$T408/gh-prefixcollide.sh" VERDICT=incomplete HEAD_SHA=ab PR_NUMBER=5 REPO=o/r APP_TOKEN_PRESENT=true CONFIG_FILE="$T408/cfg-enabled.json" bash "$RRB408" 2>/dev/null)"
assert_eq "#408 helper: short head does not prefix-match a longer head's marker (trailing-space disambiguation)" "yes" \
  "$(printf '%s\n' "$RRB408_COLLIDE" | grep -qxF 'marker=<!-- devflow:review-backstop head=ab attempt=1 -->' && echo yes || echo no)"
# VERDICT unset -> defaults to the eligible `incomplete` (PR #410 review gap): the
# header documents this default; drive it (no VERDICT in env) so a regression that
# changed the default to a decided verdict (silently no-firing every headless run)
# goes RED. All other inputs supplied so the aggregate reaches a fire decision.
RRB408_NOVERDICT="$(DEVFLOW_GH="$T408/gh-empty.sh" HEAD_SHA=abc PR_NUMBER=5 REPO=o/r APP_TOKEN_PRESENT=true CONFIG_FILE="$T408/cfg-enabled.json" bash "$RRB408" 2>/dev/null | sed -n 's/^decision=//p')"
assert_eq "#408 helper: VERDICT unset defaults to eligible 'incomplete' -> fire" "fire" "$RRB408_NOVERDICT"
rm -rf "$T408"

# Config coupled peer set (2.3.0a): example ↔ schema must both carry
# devflow_review.stall_backstop.{enabled,max_resume_attempts} with matching
# types/defaults (mirrors the #266 implement-side coherence pin).
CFG408="$(python3 - "$REPO_ROOT" <<'PY' 2>/dev/null || true
import json, sys, pathlib
root = pathlib.Path(sys.argv[1])
ex = json.loads((root / ".devflow/config.example.json").read_text())
sc = json.loads((root / ".devflow/config.schema.json").read_text())
eb = ex.get("devflow_review", {}).get("stall_backstop", {})
sp = sc["properties"]["devflow_review"]["properties"].get("stall_backstop", {})
props = sp.get("properties", {})
ok = (
    eb.get("enabled") is True
    and eb.get("max_resume_attempts") == 2
    and sp.get("type") == "object"
    and sp.get("additionalProperties") is False
    and props.get("enabled", {}).get("type") == "boolean"
    and props.get("enabled", {}).get("default") is True
    and props.get("max_resume_attempts", {}).get("type") == "integer"
    and props.get("max_resume_attempts", {}).get("minimum") == 0
    and props.get("max_resume_attempts", {}).get("default") == 2
)
print("yes" if ok else "no")
PY
)"
assert_eq "#408 config example+schema carry coupled devflow_review.stall_backstop keys (types/defaults/additionalProperties)" "yes" "$CFG408"

# Workflow wiring — devflow-review.yml finalize_check. Content pins over the YAML
# (RED pre-change: the steps did not exist).
WFR408="$REPO_ROOT/.github/workflows/devflow-review.yml"
devflow_module_pin_unique "#408 review-yml: incomplete arm marks the run backstop_eligible" \
  'echo "backstop_eligible=true" >> "$GITHUB_OUTPUT"' "$WFR408"
devflow_module_pin_unique "#408 review-yml: 'Review stall backstop' step present" \
  "name: Review stall backstop" "$WFR408"
# The post-and-annotate glue (decision call + POST + notice/warning selection, incl.
# the request-review-backstop.sh / post-issue-comment.sh calls and the stall-backstop
# header) is now the shared post-review-backstop-comment.sh helper (issue #414); the
# step just calls it (vendored path + repo-path fallback, so the name appears twice).
# The moved helper-content literals are pinned against the helper in the #414 block.
assert_eq "#408/#414 review-yml: step calls the extracted post-and-annotate helper" "yes" \
  "$(grep -qF "post-review-backstop-comment.sh" "$WFR408" && echo yes || echo no)"
devflow_module_pin_unique "#408 review-yml: fresh backstop-token mint step present" \
  "id: backstop-token" "$WFR408"
assert_eq "#408 review-yml: backstop-token mint gated on always()+eligible+DEVFLOW_APP_ID" "1" \
  "$(grep -cF "if: \${{ always() && steps.finalize.outputs.backstop_eligible == 'true' && vars.DEVFLOW_APP_ID != '' }}" "$WFR408")"
# The run-step's OWN if: gate is load-bearing: the step hardcodes VERDICT: incomplete,
# so the helper's verdict guard cannot protect against firing on an approve/reject run
# — the only protection is (a) backstop_eligible set ONLY in the incomplete arm (pinned
# above) and (b) this run-step gate. Pin the run-step if: (a mint-step-only pin misses it).
assert_eq "#408 review-yml: run-step gated on always()+backstop_eligible" "1" \
  "$(grep -cF "if: \${{ always() && steps.finalize.outputs.backstop_eligible == 'true' }}" "$WFR408")"
# Anchor `backstop_eligible=true` INSIDE the incomplete (`*)`) case arm — devflow_module_pin_unique
# only proves it appears once, not that it lives in the incomplete arm; moving it to a
# broader arm would resume decided verdicts undetected. The incomplete arm sits between the
# `*)  # incomplete` label and the `esac`; assert the echo appears in that window.
assert_eq "#408 review-yml: backstop_eligible=true lives in the incomplete case arm" "yes" \
  "$(awk '/\*\)  # incomplete/{f=1} f && /backstop_eligible=true/{print "hit"; exit} f && /^              esac/{exit}' "$WFR408" | grep -q hit && echo yes || echo no)"
# Fix A (issue #408 review): the success ::notice:: must be gated on post-issue-comment.sh's
# exact success breadcrumb (that helper ALWAYS exits 0, so an exit-code check would annotate a
# failed POST as a fired re-trigger). After #414 that selection lives in the shared helper and
# is DRIVEN — not merely presence-pinned — in the #414 block below (fire+success vs fire+silent).

# Workflow wiring — devflow.yml manual /devflow:review dead-run arm.
WFD408="$REPO_ROOT/.github/workflows/devflow.yml"
devflow_module_pin_unique "#408 devflow-yml: 'Review stall backstop' step present on the manual path" \
  "name: Review stall backstop" "$WFD408"
assert_eq "#408/#414 devflow-yml: manual-path step calls the extracted post-and-annotate helper" "yes" \
  "$(grep -qF "post-review-backstop-comment.sh" "$WFD408" && echo yes || echo no)"
assert_eq "#408 devflow-yml: manual-path backstop gated on a /devflow:review command" "yes" \
  "$(grep -A1 'name: Review stall backstop' "$WFD408" | grep -qF "startsWith(needs.gate.outputs.command, '/devflow:review ')" && echo yes || echo no)"
# The manual-path DEAD-RUN trigger clause is the sole logic distinguishing a dead review
# from a healthy or cancelled one; broadening it (e.g. to `!= 'success'`, re-including
# cancelled/superseded) or dropping it would fire spurious auto-resumes. Pin the exact
# conjunction on BOTH the run step and the mint step.
assert_eq "#408 devflow-yml: manual-path backstop gated on the dead-run trigger (is_error/failure)" "1" \
  "$(grep -cF "(steps.engine.outputs.is_error == 'true' || steps.claude.outcome == 'failure') }}" "$WFD408")"
# The manual-path mint step must exist and be gated on DEVFLOW_APP_ID (else the manual path
# would attempt a resume without a workflow-capable token — the inert-GITHUB_TOKEN no-op).
devflow_module_pin_unique "#408 devflow-yml: manual-path fresh backstop-token mint step present" \
  "id: backstop-token" "$WFD408"
assert_eq "#408 devflow-yml: manual-path mint gated on the dead-run trigger + DEVFLOW_APP_ID" "1" \
  "$(grep -cF "(steps.engine.outputs.is_error == 'true' || steps.claude.outcome == 'failure') && vars.DEVFLOW_APP_ID != '' }}" "$WFD408")"
# #498 — review-tier exclusion regression pins (issue #498 AC6). The two review-
# tier backstops already exclude cancellation at source (the #408 pins above
# assert the source-text exclusions); these two behavioral-fix pins prove the
# exclusion catches a resume-on-cancel regression. Each is carried with
# devflow_module_pin_red_under: a sed -E mutation that re-introduces resume-on-cancel
# keying is run and the pin observed RED under it. They guard the source-text
# exclusion (no backstop keys its resume decision on a cancelled run's stall
# signature); they do not claim to close the accepted latched-signal race
# documented in the issue's Desired Behavior.
# Pin A — devflow.yml's `Review stall backstop` `if:` re-trigger condition
# contains the is_error/failure disjuncts and NO cancellation trigger. The
# mutation adds a cancelled disjunct (resume-on-cancel keying); the dead-run
# literal is then absent from the backstop step's if: → PASS->FAIL.
devflow_module_pin_red_under "#498 devflow-yml: Review stall backstop if: excludes cancellation (dead-run trigger only, no cancelled disjunct)" \
  "(steps.engine.outputs.is_error == 'true' || steps.claude.outcome == 'failure') }}" \
  "s/steps\\.claude\\.outcome == 'failure'\\)/steps.claude.outcome == 'failure' || steps.claude.outcome == 'cancelled')/" \
  "$WFD408"
# Pin B — devflow-review.yml emits backstop_eligible=true ONLY in the incomplete
# arm (a second emission — e.g. on the cancelled|skipped arm — would resume a
# cancelled review run). The mutation adds a second backstop_eligible=true
# emission to the cancelled arm (resume-on-cancel keying); the literal is then
# no longer unique → PASS->FAIL.
devflow_module_pin_red_under "#498 review-yml: backstop_eligible=true emitted once (only the incomplete arm — a second emission would resume a cancelled run)" \
  'echo "backstop_eligible=true" >> "$GITHUB_OUTPUT"' \
  's#flip_review "review job cancelled"#echo "backstop_eligible=true" >> "$GITHUB_OUTPUT"; flip_review "review job cancelled"#' \
  "$WFR408"
# Fix A consumer-side breadcrumb selection now lives in the shared helper (issue #414),
# driven in the #414 block below for both the manual and auto-review paths.

# The backstop-marker literal is a coupled contract: request-review-backstop.sh WRITES it (the
# count-prefix AND the emitted marker, so it appears twice) and the extracted
# post-review-backstop-comment.sh helper posts it (issue #414 moved the POST out of the two
# workflow YAMLs into that helper). Assert presence in the writer so a rename there goes RED.
assert_eq "#408 helper: writes the head-scoped review-backstop marker literal" "yes" \
  "$(grep -qF 'devflow:review-backstop head=' "$RRB408" && echo yes || echo no)"

# Rendered-surface pins (#375 discipline — pin the RENDERED grounding block, not the
# source, and prove the headless sentence is behaviorally load-bearing via a mutation).
RGB408="$REPO_ROOT/scripts/render-grounding-block.sh"
GB408_OUT="$(HEAD_SHA=x CI_SUMMARY='c: success' ALLOWED_TOOLS='Read' bash "$RGB408")"
assert_eq "#408 grounding block renders the headless-run semantics sentence" "yes" \
  "$(printf '%s\n' "$GB408_OUT" | grep -qF 'This is a headless run: ending your turn ends the process' && echo yes || echo no)"
assert_eq "#408 grounding block renders the ScheduleWakeup-unavailable rule" "yes" \
  "$(printf '%s\n' "$GB408_OUT" | grep -qF 'ScheduleWakeup' && echo yes || echo no)"
devflow_module_pin_red_under "#408 grounding: deleting the headless-run sentence from the renderer flips its pin RED" \
  'This is a headless run: ending your turn ends the process' \
  '/This is a headless run/d' "$RGB408"
# Parity with the headless-run sentence: the ScheduleWakeup-unavailable rule is
# equally load-bearing and rendered from the same edit, so mutation-pin it too
# (PR #410 review gap: it previously had only a presence grep, weaker than its sibling).
devflow_module_pin_red_under "#408 grounding: deleting the ScheduleWakeup-unavailable rule from the renderer flips its pin RED" \
  'any future task-notification as' \
  '/any future task-notification as/d' "$RGB408"

# Skill-prose behavioral-fix pins — the two operative directives of the headless-wait
# rule (one pin per operative sentence, per the behavioral-fix-pin rule). Each mutation
# removes the operative sentence and must flip its pin RED.
REVIEW_SKILL408="$REVIEW_BUNDLE"
devflow_module_pin_red_under "#408 skill: removing the never-end-turn-with-pending-agent rule flips its pin RED" \
  'Never end your turn while any dispatched agent' \
  '/Never end your turn while any dispatched agent/d' "$REVIEW_SKILL408"
devflow_module_pin_red_under "#408 skill: removing the ScheduleWakeup-unavailable rule flips its pin RED" \
  'Treat `ScheduleWakeup` and any future task-notification as UNAVAILABLE' \
  '/Treat .ScheduleWakeup. and any future task-notification as UNAVAILABLE/d' "$REVIEW_SKILL408"

# ── #415: implement-tier port of the headless-wait discipline ────────────────
# The implement tier hit the same headless early-quit #410 fixed for review. The
# skill rule carries TWO co-equal operative sentences (never-end-turn AND
# ScheduleWakeup-unavailable) — one pin per operative sentence, mirroring the #408
# review-tier block — plus the one-line headless mirror in devflow-implement.yml's
# stall-backstop resume comment (so a resumed run receives it even if it never
# re-reads the skill prose). All must move together in one commit; each is a
# behavioral-fix pin proven RED under a mutation that removes ONLY its operative
# sentence.
IMPL_SKILL415="$REPO_ROOT/skills/implement/SKILL.md"
WFI415="$REPO_ROOT/.github/workflows/devflow-implement.yml"
devflow_module_pin_red_under "#415 implement-skill: removing the never-end-turn-with-pending-agent rule flips its pin RED" \
  'Never end your turn while any dispatched agent' \
  '/Never end your turn while any dispatched agent/d' "$IMPL_SKILL415"
devflow_module_pin_red_under "#415 implement-skill: removing the ScheduleWakeup-unavailable rule flips its pin RED" \
  'Treat `ScheduleWakeup` and any future task-notification as UNAVAILABLE' \
  '/Treat .ScheduleWakeup. and any future task-notification as UNAVAILABLE/d' "$IMPL_SKILL415"
devflow_module_pin_red_under "#415 devflow-implement-yml: removing the headless resume-note line flips its pin RED" \
  'ending the turn ends the process' \
  '/ending the turn ends the process/d' "$WFI415"
# The resume note is a single printf line carrying the premise (pinned above) AND the
# operative instruction; pin the operative instruction too so an in-line reword that keeps
# the premise but drops the never-end-turn directive still turns the suite RED (the whole
# printf is one line, so both mutations target it — the two pins guard different clauses).
devflow_module_pin_red_under "#415 devflow-implement-yml: removing the never-end-turn resume-note directive flips its pin RED" \
  'Never end the turn while any dispatched agent has not returned' \
  '/Never end the turn while any dispatched agent has not returned/d' "$WFI415"

# ── #415 review finding #1 + #2: the schedulewakeup-probe verdict core is extracted
# ── into scripts/schedulewakeup-probe-verdict.py so every arm — and the fail-open
# ── name-match matrix — is DRIVEN, not left inline-in-YAML untestable (same rationale
# ── as describe-denial-count.sh, PR #367). matcher-probe.yml routes the verdict step
# ── through the helper (pinned below), and every four-way arm plus the two fail-open
# ── regressions (lower-cased name, input-less name) is exercised against the real file.
SWV_PY="$REPO_ROOT/scripts/schedulewakeup-probe-verdict.py"
MPROBE415="$REPO_ROOT/.github/workflows/matcher-probe.yml"
devflow_module_pin_unique "#415 matcher-probe.yml routes the ScheduleWakeup verdict through the testable helper" \
  'python3 scripts/schedulewakeup-probe-verdict.py "${EXECUTION_FILE}"' "$MPROBE415"
swv_has_row() {  # fixture expected-row-prefix -> "yes" if the verdict row starts with it
  python3 "$SWV_PY" "$1" 2>/dev/null | grep -qF "$2" && echo yes || echo no
}
swv_has() {  # fixture substring -> "yes" if the rendered output contains it (any line)
  python3 "$SWV_PY" "$1" 2>/dev/null | grep -qF "$2" && echo yes || echo no
}
# Arm: DENIED — permission_denials names ScheduleWakeup (ships).
SWV_F="$(probe_tmp swv.denied)"
printf '%s' '[{"permission_denials":[{"tool":"ScheduleWakeup"}]},{"type":"tool_use","name":"Bash","input":{"command":"grep x /etc/hosts"}}]' > "$SWV_F"
assert_eq "#415 swv: DENIED when permission_denials names ScheduleWakeup (ship)" "yes" \
  "$(swv_has_row "$SWV_F" '| **DENIED** | yes |')"
# Arm: AVAILABLE — a ScheduleWakeup tool_use recorded, not denied (does NOT ship).
printf '%s' '[{"type":"tool_use","name":"Bash","input":{"command":"grep x /etc/hosts"}},{"type":"tool_use","name":"ScheduleWakeup","input":{"delaySeconds":60}},{"type":"tool_use","name":"Bash","input":{"command":"grep x /etc/os-release"}}]' > "$SWV_F"
assert_eq "#415 swv: AVAILABLE when ScheduleWakeup attempted and not denied (no ship)" "yes" \
  "$(swv_has_row "$SWV_F" '| **AVAILABLE** | no |')"
# Arm: REMOVED — no ScheduleWakeup signal AND both controls ran (presumptive, ships).
printf '%s' '[{"type":"tool_use","name":"Bash","input":{"command":"grep x /etc/hosts"}},{"type":"tool_use","name":"Bash","input":{"command":"grep x /etc/os-release"}}]' > "$SWV_F"
assert_eq "#415 swv: REMOVED when tool absent and both controls ran (ship)" "yes" \
  "$(swv_has_row "$SWV_F" '| **REMOVED** | yes |')"
# Arm: INCONCLUSIVE — only the BEFORE control ran; tool-absence cannot be distinguished
# from a skipped attempt. "Unknown is not zero" — must NOT collapse onto the shippable
# REMOVED. This fixture guards the `control_after` conjunct of the REMOVED gate.
printf '%s' '[{"type":"tool_use","name":"Bash","input":{"command":"grep x /etc/hosts"}}]' > "$SWV_F"
assert_eq "#415 swv: INCONCLUSIVE (no ship) when only the before-control ran, not REMOVED" "yes" \
  "$(swv_has_row "$SWV_F" '| **INCONCLUSIVE** | no |')"
# And the else-branch [!WARNING] text is rendered with the controls interpolated in order
# (before=yes, after=no) — guards a garbled/transposed operator diagnostic on this path.
assert_eq "#415 swv: before-only run renders the [!WARNING] 'controls did not both run (before=yes, after=no)' text" "yes" \
  "$(swv_has "$SWV_F" 'The controls did not both run (before=yes, after=no)')"
# Arm: INCONCLUSIVE — only the AFTER control ran (PR #417 shadow — pr-test-analyzer). This
# is the SYMMETRIC partner of the before-only arm and guards the OTHER conjunct of the
# REMOVED gate (`control_before and control_after`): without this fixture, a mutation
# dropping the `control_before` conjunct (`elif control_after:`) would leave every existing
# pin green while shipping a false REMOVED on an after-only run — the dangerous fail-open
# direction. Mutation-proven: `elif control_after:` flips this fixture to REMOVED/ship.
printf '%s' '[{"type":"tool_use","name":"Bash","input":{"command":"grep x /etc/os-release"}}]' > "$SWV_F"
assert_eq "#415 swv: INCONCLUSIVE (no ship) when only the after-control ran, not a fail-open REMOVED" "yes" \
  "$(swv_has_row "$SWV_F" '| **INCONCLUSIVE** | no |')"
# Arm: INCONCLUSIVE — execution file absent (note_top floor). Never REMOVED.
assert_eq "#415 swv: INCONCLUSIVE (no ship) when the execution file is absent" "yes" \
  "$(swv_has_row "/no/such/schedulewakeup-execfile.json" '| **INCONCLUSIVE** | no |')"
# Arm: INCONCLUSIVE — present regular file, wholly unparseable (not JSON, not JSONL) →
# note_top "present but unparseable" floor, never a clean tool-absence REMOVED.
printf '%s\n' 'not json at all, not a single object' > "$SWV_F"
assert_eq "#415 swv: INCONCLUSIVE (no ship) when a present file is wholly unparseable" "yes" \
  "$(swv_has_row "$SWV_F" '| **INCONCLUSIVE** | no |')"
# Arm: INCONCLUSIVE — partial JSONL corruption (both controls parse, one line drops)
# forces the floor rather than reading the surviving lines as a clean tool-absence.
# BOTH controls are present on purpose (PR #417 review — pr-test-analyzer): with both
# controls run and no ScheduleWakeup signal, the ONLY thing keeping this off the
# shippable REMOVED is the `dropped -> note_top -> INCONCLUSIVE` precedence in
# parse_execution_file. A single-control fixture would read INCONCLUSIVE via the
# else-branch (one control) regardless, so it would pass even if that precedence were
# deleted — vacuous. The assert_eq below IS the guard: with both controls present it goes
# RED if `if dropped:` is removed (the fixture then reads REMOVED/ship), so the precedence
# is genuinely pinned (verified by removing `if dropped:` on a scratch copy → REMOVED).
printf '%s\n%s\n%s\n' \
  '{"type":"tool_use","name":"Bash","input":{"command":"grep x /etc/hosts"}}' \
  '{"type":"tool_use","name":"Bash","input":{"command":"grep x /etc/os-release"}}' \
  '{oops-not-json' > "$SWV_F"
assert_eq "#415 swv: INCONCLUSIVE (no ship) on partial JSONL corruption with BOTH controls, not a false REMOVED" "yes" \
  "$(swv_has_row "$SWV_F" '| **INCONCLUSIVE** | no |')"
# Fail-open regression #2a (case): a ScheduleWakeup call recorded under a LOWER-CASED
# name must read as present (AVAILABLE, no ship). Case-sensitive matching would miss it
# and, with both controls run, ship REMOVED — a fail-open in the dangerous direction.
printf '%s' '[{"type":"tool_use","name":"Bash","input":{"command":"grep x /etc/hosts"}},{"type":"tool_use","name":"schedulewakeup","input":{"delaySeconds":60}},{"type":"tool_use","name":"Bash","input":{"command":"grep x /etc/os-release"}}]' > "$SWV_F"
assert_eq "#415 swv: lower-cased tool name still reads AVAILABLE, not a fail-open REMOVED" "yes" \
  "$(swv_has_row "$SWV_F" '| **AVAILABLE** | no |')"
# Fail-open regression #2b (input-less): a ScheduleWakeup tool_use with no `input` key
# must still be recorded by NAME and read AVAILABLE — dropping it would ship REMOVED.
printf '%s' '[{"type":"tool_use","name":"Bash","input":{"command":"grep x /etc/hosts"}},{"type":"tool_use","name":"ScheduleWakeup"},{"type":"tool_use","name":"Bash","input":{"command":"grep x /etc/os-release"}}]' > "$SWV_F"
assert_eq "#415 swv: input-less ScheduleWakeup tool_use still reads AVAILABLE, not REMOVED" "yes" \
  "$(swv_has_row "$SWV_F" '| **AVAILABLE** | no |')"
# The helper always exits 0 (best-effort, like describe-denial-count.sh).
assert_eq "#415 swv: helper exits 0 even on an absent execution file" "0" \
  "$(python3 "$SWV_PY" /no/such/execfile.json >/dev/null 2>&1; echo $?)"
# PR #417 review finding (Important-1): a PRESENT-but-unreadable execution file
# (PermissionError, or a TOCTOU disappearance after the os.path.isfile() check) must
# route to the INCONCLUSIVE floor and still exit 0 — honoring the module's documented
# "Always exits 0" contract — instead of raising an uncaught traceback through
# render()/main() (which under matcher-probe.yml's `set -euo pipefail` verdict step
# yields a red step with NO verdict table, on exactly the degraded run the probe exists
# to handle). Skipped only where chmod 000 does not actually deny reads (running as
# root, or a filesystem ignoring the mode). NOTE (issue #746): since extraction the
# module's assertion floor is an EQUALITY check, so taking that arm now lowers the tally
# and fails the boundary with a count mismatch rather than passing quietly. That is the
# honest signal — a module may not self-skip, so a silent pass would be the worse
# outcome — but it means this arm is a host requirement (non-root), not a portability
# accommodation. Do not read the branch as "green everywhere".
SWV_UNREAD="$(probe_tmp swv.unreadable)"
printf '%s' '[{"type":"tool_use","name":"Bash","input":{"command":"grep x /etc/hosts"}},{"type":"tool_use","name":"Bash","input":{"command":"grep x /etc/os-release"}}]' > "$SWV_UNREAD"
chmod 000 "$SWV_UNREAD"
if python3 -c "open('$SWV_UNREAD').read()" 2>/dev/null; then
  echo "  (skipped #415 swv unreadable-file arm — reads not denied here, e.g. running as root)"
else
  assert_eq "#415 swv: present-but-unreadable execution file -> INCONCLUSIVE (no ship), not a raised traceback" "yes" \
    "$(swv_has_row "$SWV_UNREAD" '| **INCONCLUSIVE** | no |')"
  assert_eq "#415 swv: helper still exits 0 on a present-but-unreadable execution file" "0" \
    "$(python3 "$SWV_PY" "$SWV_UNREAD" >/dev/null 2>&1; echo $?)"
fi
chmod 644 "$SWV_UNREAD" 2>/dev/null || true
rm -f "$SWV_UNREAD"
# PR #417 review (pr-test-analyzer, Important): the render() claude_args-DECISION text is
# the AC4 operator-facing output ("SHIP …" / "DO NOT SHIP …" / "DO NOT ACT …"), selected by
# an if/elif independent of the table row. Every other pin greps only the verdict row, so a
# mis-mapped decision (e.g. AVAILABLE routed into the DO-NOT-ACT else, or SHIP/DO-NOT-SHIP
# transposed) would misdirect the operator while staying green. Pin one decision string per
# class. The `AC4): SHIP` prefix is distinct from `AC4): DO NOT SHIP` (grep -F is literal).
# REMOVED fixture (both controls, no ScheduleWakeup) -> SHIP decision + presumptive [!NOTE].
printf '%s' '[{"type":"tool_use","name":"Bash","input":{"command":"grep x /etc/hosts"}},{"type":"tool_use","name":"Bash","input":{"command":"grep x /etc/os-release"}}]' > "$SWV_F"
assert_eq "#415 swv: REMOVED renders the SHIP claude_args decision (AC4)" "yes" \
  "$(swv_has "$SWV_F" 'AC4): SHIP')"
assert_eq "#415 swv: REMOVED renders the presumptive [!NOTE] caveat block" "yes" \
  "$(swv_has "$SWV_F" '[!NOTE]')"
# AVAILABLE fixture (ScheduleWakeup attempted, both controls) -> DO NOT SHIP decision.
printf '%s' '[{"type":"tool_use","name":"Bash","input":{"command":"grep x /etc/hosts"}},{"type":"tool_use","name":"ScheduleWakeup","input":{"delaySeconds":60}},{"type":"tool_use","name":"Bash","input":{"command":"grep x /etc/os-release"}}]' > "$SWV_F"
assert_eq "#415 swv: AVAILABLE renders the DO NOT SHIP claude_args decision (AC4)" "yes" \
  "$(swv_has "$SWV_F" 'AC4): DO NOT SHIP')"
# INCONCLUSIVE (absent file) -> DO NOT ACT decision + [!WARNING] re-run block.
assert_eq "#415 swv: INCONCLUSIVE renders the DO NOT ACT claude_args decision (AC4)" "yes" \
  "$(swv_has "/no/such/swv-decision.json" 'AC4): DO NOT ACT')"
assert_eq "#415 swv: INCONCLUSIVE renders the [!WARNING] re-run block" "yes" \
  "$(swv_has "/no/such/swv-decision.json" '[!WARNING]')"
# Precedence: ScheduleWakeup BOTH denied AND attempted must resolve DENIED (denial checked
# before attempt in compute_verdict) — a reordering would ship AVAILABLE on a denied tool.
printf '%s' '[{"permission_denials":[{"tool":"ScheduleWakeup"}]},{"type":"tool_use","name":"ScheduleWakeup","input":{"delaySeconds":60}},{"type":"tool_use","name":"Bash","input":{"command":"grep x /etc/hosts"}},{"type":"tool_use","name":"Bash","input":{"command":"grep x /etc/os-release"}}]' > "$SWV_F"
assert_eq "#415 swv: DENIED wins over AVAILABLE when ScheduleWakeup is both denied and attempted" "yes" \
  "$(swv_has_row "$SWV_F" '| **DENIED** | yes |')"
rm -f "$SWV_F"

# ── #610 cloud per-agent-effort SEAM probe verdict — the branch-selecting core is
# ── extracted into scripts/agents-seam-probe-verdict.py so every arm (and the
# ── never-auto-ship-the-applied-arm fail-open guard) is DRIVEN, not left inline-in-YAML
# ── untestable (same rationale as the #415 schedulewakeup helper above). The applied
# ── arm ships ONLY on SEAM_PROVEN, which requires the explicit human
# ── --adjudicated-governed flag — the dangerous direction (shipping on an unproven
# ── seam) must be unreachable without a human in the loop.
ASV_PY="$REPO_ROOT/scripts/agents-seam-probe-verdict.py"
ASPROBE="$REPO_ROOT/.github/workflows/agents-seam-probe.yml"
devflow_module_pin_unique "#610 agents-seam-probe.yml routes the seam verdict through the testable helper" \
  'python3 scripts/agents-seam-probe-verdict.py "${EXECUTION_FILE}"' "$ASPROBE"
asv_has_row() {  # fixture expected-row-prefix -> "yes" if the verdict row starts with it
  python3 "$ASV_PY" "$1" 2>/dev/null | grep -qF "$2" && echo yes || echo no
}
asv_has() {  # fixture substring -> "yes" if the rendered output contains it (any line)
  python3 "$ASV_PY" "$1" 2>/dev/null | grep -qF "$2" && echo yes || echo no
}
asv_has_row_adj() {  # fixture expected-row-prefix (with --adjudicated-governed)
  python3 "$ASV_PY" "$1" --adjudicated-governed 2>/dev/null | grep -qF "$2" && echo yes || echo no
}
ASV_F="$(probe_tmp asv.fixture)"
# Arm: SEAM_FORWARDED — the seam marker was emitted (fact i proven) but fact (ii) is NOT
# adjudicated → does NOT ship the applied arm. This is the primary fail-open guard: a
# forwarded seam must NOT auto-promote to SEAM_PROVEN/ship without the human flag.
printf '%s' '[{"type":"tool_use","name":"Task","input":{"subagent_type":"seam-probe-agent"}},{"type":"tool_use","name":"Bash","input":{"command":"printf %s SEAM_PROBE_FORWARDED_OK SEAM_PROBE_EFFORT=low"}}]' > "$ASV_F"
assert_eq "#610 asv: SEAM_FORWARDED (no ship) when marker present but fact (ii) not adjudicated" "yes" \
  "$(asv_has_row "$ASV_F" '| **SEAM_FORWARDED** | no |')"
# Same fixture WITH --adjudicated-governed → SEAM_PROVEN, ships the applied arm.
assert_eq "#610 asv: SEAM_PROVEN (ship) only when a human adjudicated fact (ii) via --adjudicated-governed" "yes" \
  "$(asv_has_row_adj "$ASV_F" '| **SEAM_PROVEN** | yes |')"
# Arm: SEAM_UNPROVEN — the subagent type was dispatched but no seam marker appeared (the
# `--agents` startup block was not forwarded / the type was unrecognized). Does NOT ship.
printf '%s' '[{"type":"tool_use","name":"Task","input":{"subagent_type":"seam-probe-agent"}},{"type":"tool_use","name":"Bash","input":{"command":"printf %s seam-probe-agent dispatch refused: unknown subagent_type"}}]' > "$ASV_F"
assert_eq "#610 asv: SEAM_UNPROVEN (no ship) when the subagent type was dispatched but emitted no seam marker" "yes" \
  "$(asv_has_row "$ASV_F" '| **SEAM_UNPROVEN** | no |')"
# Even with --adjudicated-governed, SEAM_UNPROVEN must NOT ship: fact (i) forwarding is a
# hard prerequisite the human flag cannot override.
assert_eq "#610 asv: SEAM_UNPROVEN stays no-ship even with --adjudicated-governed (fact (i) is a hard gate)" "yes" \
  "$(asv_has_row_adj "$ASV_F" '| **SEAM_UNPROVEN** | no |')"
# Arm: INCONCLUSIVE — no dispatch of the probe subagent_type was even attempted (the seam
# was never exercised). Never ships.
printf '%s' '[{"type":"tool_use","name":"Bash","input":{"command":"echo unrelated"}}]' > "$ASV_F"
assert_eq "#610 asv: INCONCLUSIVE (no ship) when no dispatch of the probe subagent_type was attempted" "yes" \
  "$(asv_has_row "$ASV_F" '| **INCONCLUSIVE** | no |')"
# Arm: INCONCLUSIVE — execution file absent (note_top floor). "Unknown is not zero" — never
# collapsed onto a shippable verdict.
assert_eq "#610 asv: INCONCLUSIVE (no ship) when the execution file is absent" "yes" \
  "$(asv_has_row "/no/such/agents-seam-execfile.json" '| **INCONCLUSIVE** | no |')"
# Arm: INCONCLUSIVE — present regular file, wholly unparseable → note_top floor.
printf '%s\n' 'not json at all' > "$ASV_F"
assert_eq "#610 asv: INCONCLUSIVE (no ship) when a present file is wholly unparseable" "yes" \
  "$(asv_has_row "$ASV_F" '| **INCONCLUSIVE** | no |')"
# Fail-open regression (case): a LOWER-CASED seam marker must still read as forwarded
# (SEAM_FORWARDED), not fall through to SEAM_UNPROVEN — case-sensitive matching would
# under-read fact (i).
printf '%s' '[{"type":"tool_use","name":"Task","input":{"subagent_type":"seam-probe-agent"}},{"type":"tool_use","name":"Bash","input":{"command":"printf %s seam_probe_forwarded_ok seam_probe_effort=low"}}]' > "$ASV_F"
assert_eq "#610 asv: lower-cased seam marker still reads SEAM_FORWARDED, not SEAM_UNPROVEN" "yes" \
  "$(asv_has_row "$ASV_F" '| **SEAM_FORWARDED** | no |')"
# Arm: INCONCLUSIVE — partial JSONL corruption forces the floor rather than reading the
# surviving lines as a clean measurement (both a dispatch AND a marker line survive, so the
# ONLY thing keeping this off SEAM_FORWARDED is the dropped→note_top precedence).
printf '%s\n%s\n%s\n' \
  '{"type":"tool_use","name":"Task","input":{"subagent_type":"seam-probe-agent"}}' \
  '{"type":"tool_use","name":"Bash","input":{"command":"printf %s SEAM_PROBE_FORWARDED_OK SEAM_PROBE_EFFORT=low"}}' \
  '{oops-not-json' > "$ASV_F"
assert_eq "#610 asv: INCONCLUSIVE (no ship) on partial JSONL corruption, not a false SEAM_FORWARDED" "yes" \
  "$(asv_has_row "$ASV_F" '| **INCONCLUSIVE** | no |')"
# Decision-text pins (the operator-facing AC1 decision line, selected independently of the
# row). One per class so a mis-mapped decision (green row, wrong action) is caught.
printf '%s' '[{"type":"tool_use","name":"Task","input":{"subagent_type":"seam-probe-agent"}},{"type":"tool_use","name":"Bash","input":{"command":"printf %s SEAM_PROBE_FORWARDED_OK SEAM_PROBE_EFFORT=low"}}]' > "$ASV_F"
assert_eq "#610 asv: SEAM_PROVEN renders the SHIP applied-arm decision (AC1)" "yes" \
  "$(python3 "$ASV_PY" "$ASV_F" --adjudicated-governed 2>/dev/null | grep -qF 'AC1): SHIP the spike-gated applied arm' && echo yes || echo no)"
assert_eq "#610 asv: SEAM_FORWARDED renders the DO-NOT-SHIP (fact ii pending) decision (AC1)" "yes" \
  "$(asv_has "$ASV_F" 'fact (ii) (effort governs the dispatch) needs human adjudication')"
printf '%s' '[{"type":"tool_use","name":"Task","input":{"subagent_type":"seam-probe-agent"}},{"type":"tool_use","name":"Bash","input":{"command":"printf %s seam-probe-agent dispatch refused: unknown subagent_type"}}]' > "$ASV_F"
assert_eq "#610 asv: SEAM_UNPROVEN renders the DO-NOT-SHIP (seam not forwarded) decision (AC1)" "yes" \
  "$(asv_has "$ASV_F" 'the startup `--agents` seam was not forwarded')"
assert_eq "#610 asv: INCONCLUSIVE renders the DO NOT ACT decision (AC1)" "yes" \
  "$(asv_has "/no/such/agents-seam-decision.json" 'AC1): DO NOT ACT')"
# The helper always exits 0 (best-effort, like the #415 sibling).
assert_eq "#610 asv: helper exits 0 even on an absent execution file" "0" \
  "$(python3 "$ASV_PY" /no/such/execfile.json >/dev/null 2>&1; echo $?)"
# Fail-open regression (input-less tool_use): a dispatch tool_use recorded under the probe
# subagent NAME but carrying NO `input` key must still read as dispatch_attempted (-> the
# no-marker case resolves SEAM_UNPROVEN), never be dropped (which would fail OPEN into the
# INCONCLUSIVE "measured nothing" floor). collect() records a tool_use even without `input`
# (the named fail-open guard); this fixture pins it. Every other fixture carries an `input`,
# so without this the guard is untested and a regression stays green (PR #667 review, pr-test-analyzer Important).
printf '%s' '[{"type":"tool_use","name":"seam-probe-agent"}]' > "$ASV_F"
assert_eq "#610 asv: input-less probe-subagent tool_use still reads dispatch_attempted -> SEAM_UNPROVEN, not a fail-open INCONCLUSIVE" "yes" \
  "$(asv_has_row "$ASV_F" '| **SEAM_UNPROVEN** | no |')"
# dispatch_attempted via the permission_denials arm (the realistic "dispatch refused" shape):
# the probe agent name appears ONLY in a permission_denials node, never in a tool_use command
# string — exercises the `AGENT_NAME in denial_text` half of the OR (PR #667 review, pr-test-analyzer suggestion).
printf '%s' '[{"permission_denials":[{"tool":"Task","reason":"unknown subagent_type seam-probe-agent"}]}]' > "$ASV_F"
assert_eq "#610 asv: probe name only in permission_denials still reads dispatch_attempted -> SEAM_UNPROVEN" "yes" \
  "$(asv_has_row "$ASV_F" '| **SEAM_UNPROVEN** | no |')"
# Case-insensitivity of the AGENT_NAME match (its own .lower(), distinct from the marker's):
# a MIXED-case dispatch name still reads dispatch_attempted -> SEAM_UNPROVEN (PR #667 review, pr-test-analyzer suggestion).
printf '%s' '[{"type":"tool_use","name":"Task","input":{"subagent_type":"SEAM-Probe-Agent"}}]' > "$ASV_F"
assert_eq "#610 asv: mixed-case probe subagent name still reads dispatch_attempted -> SEAM_UNPROVEN" "yes" \
  "$(asv_has_row "$ASV_F" '| **SEAM_UNPROVEN** | no |')"
# Present-but-unreadable execution file (PermissionError / TOCTOU) must route to the
# INCONCLUSIVE floor and still exit 0 — honoring "always exits 0" — never raise an uncaught
# traceback (which under the workflow's `set -euo pipefail` verdict step yields a red step
# with NO verdict table). Parity with the #415 swv sibling (PR #667 review, pr-test-analyzer).
# Skipped where chmod 000 does not actually deny reads (running as root) so the suite stays green.
ASV_UNREAD="$(probe_tmp asv.unreadable)"
printf '%s' '[{"type":"tool_use","name":"Task","input":{"subagent_type":"seam-probe-agent"}}]' > "$ASV_UNREAD"
chmod 000 "$ASV_UNREAD"
if python3 -c "open('$ASV_UNREAD').read()" 2>/dev/null; then
  echo "  (skipped #610 asv unreadable-file arm — reads not denied here, e.g. running as root)"
else
  assert_eq "#610 asv: present-but-unreadable execution file -> INCONCLUSIVE (no ship), not a raised traceback" "yes" \
    "$(asv_has_row "$ASV_UNREAD" '| **INCONCLUSIVE** | no |')"
  assert_eq "#610 asv: helper still exits 0 on a present-but-unreadable execution file" "0" \
    "$(python3 "$ASV_PY" "$ASV_UNREAD" >/dev/null 2>&1; echo $?)"
fi
chmod 644 "$ASV_UNREAD" 2>/dev/null || true
rm -f "$ASV_UNREAD"
rm -f "$ASV_F"

# mktemp-guard breadcrumb: after #414 the `BODY_FILE="$(mktemp)"` guard lives ONCE in the
# shared helper (no longer a byte-identical mirror across the two YAMLs — the PR #410 review
# gap this coupled-mirror pin guarded is now structurally impossible). It is pinned against
# the helper in the #414 block below.

# ────────────────────────────────────────────────────────────────────────────
echo "#414 review stall-backstop post-and-annotate helper extraction"
# ────────────────────────────────────────────────────────────────────────────
# The ~40-line post-and-annotate glue that both backstop steps duplicated (parse the
# request-review-backstop.sh decision, compose the /devflow:review re-trigger body, POST
# it, then select ::notice:: vs ::warning:: on the POST success breadcrumb) is extracted
# into scripts/post-review-backstop-comment.sh (issue #414) so the suite can DRIVE the
# selection — the load-bearing fail-closed arm (a failed/absent POST must NEVER be
# annotated as a fired re-trigger, issue #408 review) — instead of only presence-pinning a
# breadcrumb literal in each YAML. Same rationale as describe-denial-count.sh.
PRBC="$REPO_ROOT/scripts/post-review-backstop-comment.sh"
assert_eq "#414 post-review-backstop-comment.sh exists and is executable" "yes" \
  "$([ -x "$PRBC" ] && echo yes || echo no)"

# Scratch repo-root with stub helpers the extracted glue resolves cwd-relative
# (.devflow/vendor/... absent -> scripts/... wins). The stubs control the two inputs the
# selection reads (the decision and the POST success breadcrumb) AND capture what the helper
# hands each of them — the RRB stub echoes the five forwarded env inputs (so the marshaling
# is asserted, not stub-blind), and the POST stubs capture $2 (the composed body) plus a
# `post-invoked` sentinel (so the fired re-trigger PAYLOAD and "POST never invoked" are real
# assertions, not inferred from the annotation alone). $T414 is baked into each stub (absolute
# path) so the capture files resolve regardless of the helper's cwd. The helper calls each via
# `bash <path>`, so no +x is required, but chmod anyway for cleanliness.
T414="$(mktemp -d)"
mkdir -p "$T414/scripts"
# FIRE decision stub — also records the forwarded env for the pass-through assertion.
cat > "$T414/scripts/request-review-backstop.sh" <<EOF
#!/usr/bin/env bash
printf 'VERDICT=%s HEAD_SHA=%s PR_NUMBER=%s REPO=%s APP_TOKEN_PRESENT=%s\n' "\$VERDICT" "\$HEAD_SHA" "\$PR_NUMBER" "\$REPO" "\$APP_TOKEN_PRESENT" > "$T414/rrb-env.txt"
printf 'decision=fire\nreason=guarantee-class\nattempt=1\nmarker=<!-- devflow:review-backstop head=abc attempt=1 -->\n'
EOF
# POST stub: capture the composed body ($2) + drop the post-invoked sentinel, then emit the
# EXACT success breadcrumb on stderr (-> ::notice:: posted).
cat > "$T414/scripts/post-issue-comment.sh" <<EOF
#!/usr/bin/env bash
cp "\$2" "$T414/post-body.txt"
: > "$T414/post-invoked"
echo "devflow: posted comment on #\$1" >&2
EOF
chmod +x "$T414/scripts/"*.sh
rm -f "$T414/post-invoked" "$T414/post-body.txt" "$T414/rrb-env.txt"
OUT_OK=$(cd "$T414" && PR_NUMBER=99 HEAD_SHA=abc REPO=o/r VERDICT=incomplete APP_TOKEN_PRESENT=true bash "$PRBC" 2>&1); RC_OK=$?
assert_eq "#414 fire + POST success breadcrumb -> fired-re-trigger ::notice::" "yes" \
  "$(printf '%s\n' "$OUT_OK" | grep -qF '::notice::review stall backstop: posted /devflow:review re-trigger (attempt 1) for PR #99' && echo yes || echo no)"
assert_eq "#414 fire + POST success -> NO 'did NOT post' ::warning::" "no" \
  "$(printf '%s\n' "$OUT_OK" | grep -qF 'did NOT post' && echo yes || echo no)"
assert_eq "#414 helper always exits 0 (success arm)" "0" "$RC_OK"
# Env delivery to the decision helper: the RRB stub echoes the five inputs it received. This
# confirms the helper delivers all five to RRB in its environment — it catches the helper
# scrubbing/clearing the environment before the RRB call (e.g. an `env -i bash "$RRB"`). It
# does NOT isolate the helper's explicit `VERDICT=... HEAD_SHA=... bash "$RRB"` forward from
# plain inheritance: the test sets the five as the helper's own env (prefix assignments bash
# exports), so RRB would inherit them even if the explicit forward were dropped — the forward
# is belt-and-suspenders over inheritance, so no single-input test can distinguish the two.
assert_eq "#414 fire: request-review-backstop.sh receives all five inputs in its environment" \
  "VERDICT=incomplete HEAD_SHA=abc PR_NUMBER=99 REPO=o/r APP_TOKEN_PRESENT=true" \
  "$(cat "$T414/rrb-env.txt" 2>/dev/null)"
# Composed re-trigger BODY (the fired arm's actual payload — a dropped /devflow:review line or a
# mis-interpolated HEAD_SHA/attempt would post a comment that re-triggers nothing while the
# success ::notice:: still fires, since the notice keys only on the POST breadcrumb).
assert_eq "#414 fire: composed body carries the head-scoped marker line" "yes" \
  "$(grep -qxF '<!-- devflow:review-backstop head=abc attempt=1 -->' "$T414/post-body.txt" 2>/dev/null && echo yes || echo no)"
assert_eq "#414 fire: composed body carries the stall-backstop header with HEAD_SHA + attempt interpolated" "yes" \
  "$(grep -qF '**DevFlow review stall backstop** — this cloud review ended with no verdict for `abc`. Auto-resume attempt 1:' "$T414/post-body.txt" 2>/dev/null && echo yes || echo no)"
assert_eq "#414 fire: composed body carries the literal /devflow:review re-trigger line" "yes" \
  "$(grep -qxF '/devflow:review' "$T414/post-body.txt" 2>/dev/null && echo yes || echo no)"

# SAME fire decision, but the POST stub stays SILENT (no success breadcrumb) — the
# load-bearing fail-closed arm (AC3): a failed POST is a ::warning::, NEVER a fired notice.
# (Still captures the body + sentinel: POST WAS invoked here, it just did not succeed.)
cat > "$T414/scripts/post-issue-comment.sh" <<EOF
#!/usr/bin/env bash
cp "\$2" "$T414/post-body.txt"
: > "$T414/post-invoked"
echo "devflow: warning: could not post comment on #\$1 (best-effort, continuing): boom" >&2
EOF
chmod +x "$T414/scripts/post-issue-comment.sh"
rm -f "$T414/post-invoked" "$T414/post-body.txt"
OUT_FAIL=$(cd "$T414" && PR_NUMBER=99 HEAD_SHA=abc REPO=o/r VERDICT=incomplete APP_TOKEN_PRESENT=true bash "$PRBC" 2>&1); RC_FAIL=$?
assert_eq "#414 fire + POST failed (no breadcrumb) -> 'did NOT post' ::warning:: (fail-closed, AC3)" "yes" \
  "$(printf '%s\n' "$OUT_FAIL" | grep -qF '::warning::review stall backstop: the /devflow:review re-trigger comment did NOT post for PR #99' && echo yes || echo no)"
assert_eq "#414 fire + POST failed -> NEVER a fired-re-trigger ::notice:: (fail-closed, AC3)" "no" \
  "$(printf '%s\n' "$OUT_FAIL" | grep -qF '::notice::review stall backstop: posted /devflow:review re-trigger' && echo yes || echo no)"
assert_eq "#414 fire + POST failed -> the POST helper WAS invoked (sentinel present)" "present" \
  "$([ -f "$T414/post-invoked" ] && echo present || echo absent)"
assert_eq "#414 helper always exits 0 (failed-POST arm)" "0" "$RC_FAIL"

# NO-FIRE decision -> no-auto-resume ::notice:: naming the reason; POST genuinely not invoked
# (asserted via the post-invoked sentinel's ABSENCE, not merely the absence of the fired notice).
cat > "$T414/scripts/request-review-backstop.sh" <<'EOF'
#!/usr/bin/env bash
printf 'decision=no-fire\nreason=cap-exhausted\nattempt=\nmarker=\n'
EOF
chmod +x "$T414/scripts/request-review-backstop.sh"
rm -f "$T414/post-invoked" "$T414/post-body.txt"
OUT_NF=$(cd "$T414" && PR_NUMBER=99 HEAD_SHA=abc REPO=o/r VERDICT=approve APP_TOKEN_PRESENT=true bash "$PRBC" 2>&1); RC_NF=$?
assert_eq "#414 no-fire decision -> no-auto-resume ::notice:: naming the reason" "yes" \
  "$(printf '%s\n' "$OUT_NF" | grep -qF '::notice::review stall backstop: no auto-resume (reason: cap-exhausted)' && echo yes || echo no)"
assert_eq "#414 no-fire decision -> POST genuinely not invoked (sentinel absent)" "absent" \
  "$([ -f "$T414/post-invoked" ] && echo present || echo absent)"
assert_eq "#414 no-fire decision -> POST never invoked (no fired-re-trigger notice)" "no" \
  "$(printf '%s\n' "$OUT_NF" | grep -qF 'posted /devflow:review re-trigger' && echo yes || echo no)"
assert_eq "#414 helper always exits 0 (no-fire arm)" "0" "$RC_NF"

# UNPARSED decision -> fail-closed to no-fire (the headline safety property of the sed->bash-
# builtin parse: RRB output that carries NO `decision=` line leaves DECISION empty, and an
# empty DECISION must take the [ "$DECISION" != "fire" ] no-fire arm, never fire). Stub emits
# garbage with no decision= line at all.
cat > "$T414/scripts/request-review-backstop.sh" <<'EOF'
#!/usr/bin/env bash
printf 'reason=whatever\ngarbage line with no key\n'
EOF
chmod +x "$T414/scripts/request-review-backstop.sh"
rm -f "$T414/post-invoked" "$T414/post-body.txt"
OUT_GARBAGE=$(cd "$T414" && PR_NUMBER=99 HEAD_SHA=abc REPO=o/r VERDICT=incomplete APP_TOKEN_PRESENT=true bash "$PRBC" 2>&1); RC_GARBAGE=$?
assert_eq "#414 unparsed decision (no decision= line) -> fail-closed no-auto-resume ::notice::" "yes" \
  "$(printf '%s\n' "$OUT_GARBAGE" | grep -qF '::notice::review stall backstop: no auto-resume' && echo yes || echo no)"
assert_eq "#414 unparsed decision -> NEVER fires (no fired-re-trigger notice)" "no" \
  "$(printf '%s\n' "$OUT_GARBAGE" | grep -qF 'posted /devflow:review re-trigger' && echo yes || echo no)"
assert_eq "#414 unparsed decision -> POST genuinely not invoked (sentinel absent)" "absent" \
  "$([ -f "$T414/post-invoked" ] && echo present || echo absent)"
assert_eq "#414 helper always exits 0 (unparsed-decision arm)" "0" "$RC_GARBAGE"

# request-review-backstop.sh ABSENT -> decision-helper-absent ::warning::.
T414B="$(mktemp -d)"; mkdir -p "$T414B/scripts"
OUT_NORRB=$(cd "$T414B" && PR_NUMBER=99 HEAD_SHA=abc REPO=o/r VERDICT=incomplete APP_TOKEN_PRESENT=true bash "$PRBC" 2>&1); RC_NORRB=$?
assert_eq "#414 request-review-backstop.sh absent -> decision-helper-absent ::warning::" "yes" \
  "$(printf '%s\n' "$OUT_NORRB" | grep -qF '::warning::review stall backstop: request-review-backstop.sh absent' && echo yes || echo no)"
assert_eq "#414 helper always exits 0 (RRB-absent arm)" "0" "$RC_NORRB"

# FIRE decided but post-issue-comment.sh ABSENT -> post-helper-absent ::warning::, and
# NEVER a fired-re-trigger notice.
T414C="$(mktemp -d)"; mkdir -p "$T414C/scripts"
cat > "$T414C/scripts/request-review-backstop.sh" <<'EOF'
#!/usr/bin/env bash
printf 'decision=fire\nreason=guarantee-class\nattempt=1\nmarker=<!-- m -->\n'
EOF
chmod +x "$T414C/scripts/request-review-backstop.sh"
OUT_NOPOST=$(cd "$T414C" && PR_NUMBER=99 HEAD_SHA=abc REPO=o/r VERDICT=incomplete APP_TOKEN_PRESENT=true bash "$PRBC" 2>&1)
assert_eq "#414 post-issue-comment.sh absent -> post-helper-absent ::warning::" "yes" \
  "$(printf '%s\n' "$OUT_NOPOST" | grep -qF '::warning::review stall backstop: post-issue-comment.sh absent' && echo yes || echo no)"
assert_eq "#414 post-absent -> NEVER a fired-re-trigger ::notice::" "no" \
  "$(printf '%s\n' "$OUT_NOPOST" | grep -qF 'posted /devflow:review re-trigger' && echo yes || echo no)"

# Helper-content pins (moved from the #408 workflow-inline pins — coupled-invariant
# reconciliation): the literals the inline glue carried now live ONCE in the helper.
devflow_module_pin_unique "#414 helper: re-trigger body carries the review stall-backstop header" \
  "**DevFlow review stall backstop**" "$PRBC"
devflow_module_pin_unique "#414 helper: success notice gated on the post-comment success breadcrumb" \
  'grep -qxF "devflow: posted comment on #$PR_NUMBER"' "$PRBC"
devflow_module_pin_unique "#414 helper: mktemp guard breadcrumb present" \
  'review stall backstop: mktemp failed; cannot compose the re-trigger comment' "$PRBC"
assert_eq "#414 helper: calls the (unchanged-contract) request-review-backstop.sh decision helper" "yes" \
  "$(grep -qF "request-review-backstop.sh" "$PRBC" && echo yes || echo no)"
assert_eq "#414 helper: posts via the best-effort post-issue-comment.sh REST helper" "yes" \
  "$(grep -qF "post-issue-comment.sh" "$PRBC" && echo yes || echo no)"

# ── #435 AC-5: mktemp-failure arm behaviorally driven (PATH-shadowed failing mktemp) ─────
# The mktemp guard (`BODY_FILE="$(mktemp)" || { ::warning::…; exit 0; }`) was previously
# only presence-pinned (the breadcrumb literal above), so a regression that REACHES the arm
# and then misbehaves — fires the success notice, exits non-zero, invokes the POST anyway —
# would ship green. Drive it: with a fire decision reaching the compose step and `mktemp`
# forced to fail, assert all four — exit 0; the mktemp-specific ::warning::; the POST sentinel
# absent; and NO fired-re-trigger ::notice:: (issue #435 AC-5). This is coverage of an
# existing (believed-correct) guard, not a defect fix.
T435="$(mktemp -d)"; mkdir -p "$T435/scripts" "$T435/shadow"
cat > "$T435/scripts/request-review-backstop.sh" <<'EOF'
#!/usr/bin/env bash
printf 'decision=fire\nreason=guarantee-class\nattempt=1\nmarker=<!-- devflow:review-backstop head=abc attempt=1 -->\n'
EOF
# POST stub: drops a `post-invoked` sentinel if EVER called — AC-5 asserts it is NOT (mktemp
# fails first, before the POST helper is resolved or invoked).
cat > "$T435/scripts/post-issue-comment.sh" <<EOF
#!/usr/bin/env bash
: > "$T435/post-invoked"
echo "devflow: posted comment on #\$1" >&2
EOF
chmod +x "$T435/scripts/"*.sh
# Failing mktemp shim — shadows ONLY mktemp (prepended to PATH for the helper's subshell
# alone, so bash, the builtins, and the stub helpers still resolve normally; the #161
# same-shell function-shadow would NOT propagate into the helper's child bash, making the
# test vacuously green — a PATH shim does propagate). Prints nothing, exits 1 → the helper's
# `BODY_FILE="$(mktemp)"` is empty and the `||` guard fires.
cat > "$T435/shadow/mktemp" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$T435/shadow/mktemp"
rm -f "$T435/post-invoked"
OUT_MKT=$(cd "$T435" && PATH="$T435/shadow:$PATH" PR_NUMBER=99 HEAD_SHA=abc REPO=o/r VERDICT=incomplete APP_TOKEN_PRESENT=true bash "$PRBC" 2>&1); RC_MKT=$?
assert_eq "#435 AC5 mktemp-fail: helper exits 0" "0" "$RC_MKT"
assert_eq "#435 AC5 mktemp-fail: mktemp-specific ::warning:: breadcrumb emitted" "yes" \
  "$(printf '%s\n' "$OUT_MKT" | grep -qF '::warning::review stall backstop: mktemp failed; cannot compose the re-trigger comment' && echo yes || echo no)"
assert_eq "#435 AC5 mktemp-fail: POST helper NOT invoked (sentinel absent)" "absent" \
  "$([ -f "$T435/post-invoked" ] && echo present || echo absent)"
assert_eq "#435 AC5 mktemp-fail: NO fired-re-trigger ::notice::" "no" \
  "$(printf '%s\n' "$OUT_MKT" | grep -qF '::notice::review stall backstop: posted /devflow:review re-trigger' && echo yes || echo no)"

# ── #435 AC-6: devflow.yml manual-path HEAD_SHA prefix is mutation-proof-pinned ──────────
# The manual path derives HEAD_SHA as a step-local shell var and forwards it as a command
# PREFIX (`HEAD_SHA="$HEAD_SHA" bash "$HELPER"`); without the prefix the helper reads an empty
# HEAD_SHA and the decision helper takes its unscoped no-fire arm — the manual-path auto-resume
# is silently defeated (safe direction, but defeated). Pin the prefix through devflow_module_pin_red_under
# with a mutation that DROPS the `HEAD_SHA="$HEAD_SHA" ` prefix, so the suite goes RED the moment
# the prefix is removed (issue #435 AC-6). The auto path (devflow-review.yml) delivers HEAD_SHA via
# the step env: block and needs no prefix — no symmetric PREFIX pin there (a false mirror); its
# own load-bearing delivery, the step-scoped env: line, gets the scoped pin below.
devflow_module_pin_red_under '#435 AC6: devflow.yml manual path forwards HEAD_SHA as a command prefix (drop-prefix mutation → RED)' \
  'HEAD_SHA="$HEAD_SHA" bash "$HELPER"' \
  's/HEAD_SHA="\$HEAD_SHA" bash "\$HELPER"/bash "\$HELPER"/' \
  "$WFD408"

# ── #435 shadow finding: the AUTO path's HEAD_SHA delivery to the backstop step is pinned
# STEP-SCOPED. The literal `HEAD_SHA: ${{ needs.precheck.outputs.head_sha }}` recurs three
# times in devflow-review.yml (create_check, finalize_check, and the backstop step), so a
# whole-file pin (devflow_module_pin_unique / devflow_module_pin_red_under) would stay green when the
# BACKSTOP step's own line is dropped — the drop that silently defeats auto-resume on the
# primary path (the helper reads an empty HEAD_SHA and the decision helper takes its
# unscoped no-fire arm). Extract the step's block (its `- name:` line through the
# `bash "$HELPER"` invocation) and assert the env line inside it; the paired mutation probe
# applies a range-scoped deletion to a COPY and asserts the scoped check goes RED — the
# behavioral-fix-pin evidence, baked into the suite rather than run once by hand.
bstep_headsha() {  # file -> yes|no : HEAD_SHA env line present inside the Review stall backstop step
  awk '/- name: Review stall backstop/,/bash "\$HELPER"/' "$1" | \
    grep -qF -- 'HEAD_SHA: ${{ needs.precheck.outputs.head_sha }}' && echo yes || echo no
}
assert_eq "#435 backstop auto path: HEAD_SHA env delivery present inside the Review stall backstop step" \
  "yes" "$(bstep_headsha "$WFR408")"
# No guard on the assignment: probe_tmp fails CLOSED on its own (it records a suite FAIL
# and prints /dev/null on an mktemp failure — the PRU_FX call-site idiom), so a guard
# testing for empty output would test a contract probe_tmp does not have.
T435WF="$(probe_tmp '#435 backstop env-pin mutation setup')"
sed -E '/- name: Review stall backstop/,/bash "\$HELPER"/{/HEAD_SHA: \$\{\{ needs\.precheck\.outputs\.head_sha \}\}/d;}' \
  "$WFR408" > "$T435WF"
assert_eq "#435 backstop auto path: dropping the step-scoped HEAD_SHA env line turns the scoped pin RED" \
  "no" "$(bstep_headsha "$T435WF")"
rm -f "$T435WF"

