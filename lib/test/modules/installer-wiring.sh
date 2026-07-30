# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# shellcheck shell=bash
# Sourceable installer / workflow-wiring contract module (issue #695 extraction).
# Contract: the caller sets LIB and RESULTS_FILE, defines assert_eq, and sources
# lib/test/module-harness.sh before this module.
# The `trap _iw_cleanup EXIT` below relies on a sourcing contract: both callers
# (module-harness.sh's full-suite boundary and run-module.sh) source this module
# inside a ( ... ) subshell, so the trap fires at subshell exit and cannot clobber
# the runner's own EXIT handling. Do not source this module directly in a runner's
# top-level shell without restoring the trap.

# The workflows directory is re-derived from the harness-provided LIB rather than
# inherited from lib/test/run.sh's own `WF` global: both runner paths execute a module
# body under `set -u`, so a verbatim extraction that read the monolith's WF would abort
# on the first statement with `WF: unbound variable` before any assertion ran.
# lib/test/run.sh keeps its own WF assignment for the coverage that stays behind.
WF="$LIB/../.github/workflows"

_iw_tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/devflow-installer-wiring.XXXXXX")" || {
  printf 'could not allocate installer-wiring fixture root\n' >&2
  return 1
}
_iw_cleanup() {
  rm -rf "$_iw_tmp_root"
}
trap _iw_cleanup EXIT

# ────────────────────────────────────────────────────────────────────────────
echo "#487/#491/#533/#544/#599/#690 installer + workflow wiring (extracted to installer-wiring module)"
# ────────────────────────────────────────────────────────────────────────────
for _wf487 in devflow-implement devflow; do
  _WFF487="$WF/$_wf487.yml"
  assert_eq "#487 wiring: $_wf487.yml starts the credential refresher" "1" \
    "$(grep -cF 'name: Start credential refresher (optional)' "$_WFF487")"
  assert_eq "#487 wiring: $_wf487.yml installs the fresh-gh wrapper" "1" \
    "$(grep -cF 'name: Install fresh-gh wrapper (optional)' "$_WFF487")"
  assert_eq "#487 wiring: $_wf487.yml retires the refresher (pidfile-kill, if: always())" "1" \
    "$(grep -cF 'name: Stop credential refresher (optional)' "$_WFF487")"
  # The Stop step delegates its branch/message logic to the extracted helper
  # (inline-shell-extraction convention) rather than carrying it inline.
  assert_eq "#487 wiring: $_wf487.yml Stop step invokes the vendored stop-refresher.sh helper" "1" \
    "$(grep -cF '.devflow/vendor/devflow/scripts/stop-refresher.sh' "$_WFF487")"
  assert_eq "#487 wiring: $_wf487.yml invokes the vendored refresher via nohup (detached, not background:)" "1" \
    "$(grep -cF 'nohup bash .devflow/vendor/devflow/scripts/refresh-app-credentials.sh loop' "$_WFF487")"
  # ── /proc/<pid>/environ mitigation (PR #491). The Start step exports the PEM as a
  # step-level env var (to pipe it to the refresher's stdin); that var is inherited
  # into the detached refresher's exec-time environment, where the concurrent same-uid
  # claude step could read the raw PEM via /proc/<pid>/environ (which snapshots the
  # environment at execve and is NOT cleared by an in-process `unset` — proc(5)). The
  # ACTUAL mitigation is launching the refresher with `env -u DEVFLOW_APP_PRIVATE_KEY`,
  # so the long-lived process's environ never holds the PEM. Removal reopens the leak.
  _startblk487="$(mint_blk 'Start credential refresher (optional)' "$_WFF487")"
  _envu_ln="$(printf '%s\n' "$_startblk487" | grep -nF 'env -u DEVFLOW_APP_PRIVATE_KEY' | head -1 | cut -d: -f1)"
  _nohup_ln="$(printf '%s\n' "$_startblk487" | grep -nF 'nohup bash .devflow/vendor/devflow/scripts/refresh-app-credentials.sh loop' | head -1 | cut -d: -f1)"
  assert_eq "#487 wiring: $_wf487.yml launches the refresher with env -u DEVFLOW_APP_PRIVATE_KEY BEFORE nohup (closes the /proc PEM leak)" "yes" \
    "$([ -n "$_envu_ln" ] && [ -n "$_nohup_ln" ] && [ "$_envu_ln" -lt "$_nohup_ln" ] && echo yes || echo no)"
  # No `background:` step key anywhere (would break actionlint).
  assert_eq "#487 wiring: $_wf487.yml uses no 'background:' step key (actionlint-safe)" "0" \
    "$(grep -cE '^[[:space:]]*background:[[:space:]]*true' "$_WFF487")"
  # The refresher/install steps are gated on DEVFLOW_APP_ID (unconfigured no-op).
  assert_eq "#487 wiring: $_wf487.yml refresher start is gated on vars.DEVFLOW_APP_ID" "1" \
    "$(printf '%s\n' "$(mint_blk 'Start credential refresher (optional)' "$_WFF487")" | grep -cF "vars.DEVFLOW_APP_ID != ''")"
  # The install step delegates its whole body to the checked-in seven-output
  # installer (issue #533) — the fingerprint write and GITHUB_PATH prepend now
  # live in scripts/install-gh-wrapper.sh, pinned below outside this loop.
  assert_eq "#533 wiring: $_wf487.yml install step invokes the vendored install-gh-wrapper.sh" "1" \
    "$(printf '%s\n' "$(mint_blk 'Install fresh-gh wrapper (optional)' "$_WFF487")" | grep -cF '.devflow/vendor/devflow/scripts/install-gh-wrapper.sh')"
  # AC10 (issue #533): the install step must NOT export a process-global DEVFLOW_GH —
  # GITHUB_ENV values persist into every later job step, where a non-empty DEVFLOW_GH
  # outranks fixture PATH stubs by resolver design. Wrapper selection is PATH-scoped.
  assert_eq "#533 AC10: $_wf487.yml install step no longer exports DEVFLOW_GH to GITHUB_ENV" "0" \
    "$(printf '%s\n' "$(mint_blk 'Install fresh-gh wrapper (optional)' "$_WFF487")" | grep -cF 'DEVFLOW_GH=')"
  # ── Step ORDERING (PR #491 Suggestion 2): load-bearing but previously unpinned.
  # (a) The refresher and the wrapper install must both precede the claude step, so the
  # agent's >60-min run is already push-/gh-fresh from the start; a reordering that put
  # either after the agent step would leave the run unprotected yet still pass the
  # presence pins above. Compare 1-indexed line numbers within the workflow file.
  _claude_ln="$(grep -nF 'name: Run Claude Code' "$_WFF487" | head -1 | cut -d: -f1)"
  _start_ln="$(grep -nF 'name: Start credential refresher (optional)' "$_WFF487" | head -1 | cut -d: -f1)"
  _inst_ln="$(grep -nF 'name: Install fresh-gh wrapper (optional)' "$_WFF487" | head -1 | cut -d: -f1)"
  assert_eq "#487 wiring: $_wf487.yml starts the refresher BEFORE the claude step" "yes" \
    "$([ -n "$_start_ln" ] && [ -n "$_claude_ln" ] && [ "$_start_ln" -lt "$_claude_ln" ] && echo yes || echo no)"
  assert_eq "#487 wiring: $_wf487.yml installs the fresh-gh wrapper BEFORE the claude step" "yes" \
    "$([ -n "$_inst_ln" ] && [ -n "$_claude_ln" ] && [ "$_inst_ln" -lt "$_claude_ln" ] && echo yes || echo no)"
  # (a2) The refresher must also start AFTER checkout (PR #491 IMP-4): the refresher
  # rewrites the checkout-PERSISTED http.*/.extraheader credential, so that credential
  # must already exist when the first cycle fires. A reorder that put Start above the
  # checkout would leave the first cycle with nothing to rewrite yet still pass the
  # before-claude pins above. Pin `checkout < start`.
  _checkout_ln="$(grep -nF 'name: Checkout repository' "$_WFF487" | head -1 | cut -d: -f1)"
  assert_eq "#491 wiring: $_wf487.yml starts the refresher AFTER checkout (the persisted extraheader must exist to rewrite)" "yes" \
    "$([ -n "$_checkout_ln" ] && [ -n "$_start_ln" ] && [ "$_checkout_ln" -lt "$_start_ln" ] && echo yes || echo no)"
done
# (b) Intra-step ordering, relocated to the installer (issue #533): the real gh's
# ABSOLUTE path must be resolved BEFORE the wrapper dir is appended to GITHUB_PATH —
# otherwise a later name-based `gh` lookup recurses into the wrapper. The install
# step body now lives once in scripts/install-gh-wrapper.sh, so pin the order there.
INSTALL533="$LIB/../scripts/install-gh-wrapper.sh"
_cap_ln533="$(grep -nF 'REAL_GH="$(command -v gh' "$INSTALL533" 2>/dev/null | head -1 | cut -d: -f1)"
_path_ln533="$(grep -nF '>> "$GITHUB_PATH"' "$INSTALL533" 2>/dev/null | head -1 | cut -d: -f1)"
assert_eq "#487 wiring: install-gh-wrapper.sh resolves the real gh before prepending the wrapper to GITHUB_PATH" "yes" \
  "$([ -n "$_cap_ln533" ] && [ -n "$_path_ln533" ] && [ "$_cap_ln533" -lt "$_path_ln533" ] && echo yes || echo no)"
# devflow.yml's gate additionally excludes /devflow:review (read-only, never pushes).
assert_eq "#487 wiring: devflow.yml refresher start excludes /devflow:review commands" "1" \
  "$(printf '%s\n' "$(mint_blk 'Start credential refresher (optional)' "$WF/devflow.yml")" | grep -cF "!startsWith(needs.gate.outputs.command, '/devflow:review ')")"
# The Stop step's review-exclusion ASYMMETRY keeps the Stop gate symmetric with Start:
# devflow.yml's Stop step MUST carry the /devflow:review negation (on the review path the
# refresher was never started, so the step would be a pointless no-op; a false defeat
# warning there is prevented by the DEVFLOW_REFRESH_STARTED=skipped guard — arm17 — not
# by this exclusion), while devflow-implement.yml's Stop step must NOT carry it (it
# always starts the refresher). Pin both directions so a dropped or mis-copied gate goes RED.
assert_eq "#487 wiring: devflow.yml Stop step carries the /devflow:review exclusion" "1" \
  "$(printf '%s\n' "$(mint_blk 'Stop credential refresher (optional)' "$WF/devflow.yml")" | grep -cF "!startsWith(needs.gate.outputs.command, '/devflow:review ')")"
assert_eq "#487 wiring: devflow-implement.yml Stop step does NOT carry a /devflow:review exclusion" "0" \
  "$(printf '%s\n' "$(mint_blk 'Stop credential refresher (optional)' "$WF/devflow-implement.yml")" | grep -cF "/devflow:review")"
# Both Stop steps pass the Start step's outcome so stop-refresher.sh can tell a genuine
# never-started defeat from an upstream early-abort (absent pidfile is expected there).
assert_eq "#487 wiring: devflow.yml Stop step passes steps.refresher.outcome as DEVFLOW_REFRESH_STARTED" "1" \
  "$(printf '%s\n' "$(mint_blk 'Stop credential refresher (optional)' "$WF/devflow.yml")" | grep -cF 'DEVFLOW_REFRESH_STARTED: ${{ steps.refresher.outcome }}')"
assert_eq "#487 wiring: devflow-implement.yml Stop step passes steps.refresher.outcome as DEVFLOW_REFRESH_STARTED" "1" \
  "$(printf '%s\n' "$(mint_blk 'Stop credential refresher (optional)' "$WF/devflow-implement.yml")" | grep -cF 'DEVFLOW_REFRESH_STARTED: ${{ steps.refresher.outcome }}')"
# Coupled literal: the refresher EMITS `cycle OK` and stop-refresher.sh MATCHES it to tell
# a recovered transient from a sustained failure — a reworded producer breadcrumb would
# silently break the consumer's discrimination. Pin the shared marker in both files.
assert_eq "#487 coupled-literal: refresh-app-credentials.sh emits the 'cycle OK' success marker" "1" \
  "$(grep -cF "printf 'refresh-app-credentials: cycle OK" "$LIB/../scripts/refresh-app-credentials.sh")"
assert_eq "#487 coupled-literal: stop-refresher.sh matches the 'cycle OK' marker in its operative case arm" "1" \
  "$(grep -cF '*"cycle OK"*)' "$LIB/../scripts/stop-refresher.sh")"

# ── #491 coupled production-DEFAULT paths (shadow Finding A). Each credential surface is
# written by one file and read by another, and the workflows pass NO override — production
# works ONLY because two independently-defaulted RUNNER_TEMP/<basename> literals agree. Every
# test arm injects matching DEVFLOW_* overrides on both sides, so a one-sided rename of a
# DEFAULT ships green (gh-fresh reads no token / never matches the fingerprint, stop-refresher
# false-fires a defeat). Pin the default BASENAMES agree across writer<->reader — the same
# coupled-literal hazard as the 'cycle OK' marker above, one level down in the wiring.
# Extract-and-compare (not substring grep) so a suffix-append rename is caught too.
_dfbn() { grep -E "$2" "$1" 2>/dev/null | grep -oE 'devflow-[a-zA-Z0-9._-]+' | head -1; }
_w_tok491="$(_dfbn "$LIB/../scripts/refresh-app-credentials.sh" '^TOKEN_FILE=')"
_r_tok491="$(_dfbn "$LIB/../scripts/gh-fresh.sh" '^TOKEN_FILE=')"
assert_eq "#491 coupled-default: token-file default basename agrees (refresh-app-credentials.sh writer <-> gh-fresh.sh reader) [$_w_tok491]" "yes" \
  "$([ -n "$_w_tok491" ] && [ "$_w_tok491" = "$_r_tok491" ] && echo yes || echo no)"
_w_pid491="$(_dfbn "$LIB/../scripts/refresh-app-credentials.sh" '^PIDFILE=')"
_r_pid491="$(_dfbn "$LIB/../scripts/stop-refresher.sh" '^PIDFILE=')"
assert_eq "#491 coupled-default: pidfile default basename agrees (refresh-app-credentials.sh writer <-> stop-refresher.sh reader) [$_w_pid491]" "yes" \
  "$([ -n "$_w_pid491" ] && [ "$_w_pid491" = "$_r_pid491" ] && echo yes || echo no)"
# fingerprint + log defaults are written by the WORKFLOWS (redirect / install-step write) and
# read by gh-fresh.sh / stop-refresher.sh. Assert each reader's default basename appears as an
# exact RUNNER_TEMP/<basename> token the workflow writes (space-bounded, so a suffix-append on
# either side breaks the match), in BOTH workflows.
_r_fp491="$(_dfbn "$LIB/../scripts/gh-fresh.sh" '^FINGERPRINT_FILE=')"
_r_log491="$(_dfbn "$LIB/../scripts/stop-refresher.sh" '^LOG=')"
# The fingerprint WRITER moved from the two workflow YAML bodies into the single
# checked-in installer (issue #533) — compare the writer/reader DEFAULTS directly,
# the same extract-and-compare shape as the token-file/pidfile pins above.
_w_fp533="$(_dfbn "$INSTALL533" '^FINGERPRINT_FILE=')"
assert_eq "#491 coupled-default: fingerprint default basename agrees (install-gh-wrapper.sh writer <-> gh-fresh.sh reader) [$_w_fp533]" "yes" \
  "$([ -n "$_w_fp533" ] && [ "$_w_fp533" = "$_r_fp491" ] && echo yes || echo no)"
for _wf491 in devflow-implement devflow; do
  _wfbns491=" $(grep -oE 'RUNNER_TEMP/devflow-[a-zA-Z0-9._-]+' "$WF/$_wf491.yml" | sed 's#RUNNER_TEMP/##' | sort -u | tr '\n' ' ')"
  assert_eq "#491 coupled-default: $_wf491.yml writes the log basename stop-refresher.sh reads [$_r_log491]" "yes" \
    "$([ -n "$_r_log491" ] && printf '%s' "$_wfbns491" | grep -qF " $_r_log491 " && echo yes || echo no)"
done

# Fail-fast prose rule (surface-presence class, per the issue's Testing Strategy): the
# two-strikes bad-credential rule is present in both skill files. Pinned via
# devflow_module_pin_unique (the sanctioned unique-literal guard, not a raw echo-driven grep).
devflow_module_pin_unique "#487 fail-fast prose: skills/implement/SKILL.md carries the expired-credential two-strikes rule" \
  'Expired-credential fail-fast (two strikes' "$LIB/../skills/implement/SKILL.md"
devflow_module_pin_unique "#487 fail-fast prose: review-and-fix loop-control reference carries the expired-credential two-strikes rule" \
  'Expired-credential fail-fast (two strikes' "$LIB/../skills/review-and-fix/references/loop-control.md"
# The compaction-immune sibling signal (the wrapper diagnostic literal) is named in the prose.
devflow_module_pin_unique "#487 fail-fast prose: implement rule names the gh-fresh.sh diagnostic sibling" \
  'devflow-gh-fresh' "$LIB/../skills/implement/SKILL.md"

# (2) Refresh/cleanup steps — the detached credential refresher (issue #487) is
# retired on EVERY exit path. The existing #487 wiring pin asserts the Stop step
# EXISTS; this pins the always() guard that makes cleanup run even when the claude
# step failed/cancelled. Dropping always() leaks the background refresher.
_ac21_stopblk="$(mint_blk 'Stop credential refresher (optional)' "$WF/devflow-implement.yml")"
assert_eq "#599 AC21(2) refresh/cleanup steps: devflow-implement.yml Stop step is always()-guarded (retires the refresher on every exit path)" "1" \
  "$(printf '%s\n' "$_ac21_stopblk" | grep -cF 'if: ${{ always() && ')"

# Precise checkout-step extraction (NOT mint_blk, which exits only on the next
# `- name:` step and would over-span the runner's `- id:`-only follow-on steps):
# print from the checkout step name until the next 6-space step boundary.
_ac21_coblk="$(awk '
    index($0, "- name: Checkout repository"){f=1; print; next}
    f && /^      - /{exit}
    f{print}' "$WF/devflow-runner.yml")"
# Fail CLOSED: require the checkout step to be FOUND (carries actions/checkout@) AND
# to carry no reviewer-token. If the step is ever renamed the extraction goes empty,
# which must read as RED (a missed check), not a vacuous pass on a zero count.
assert_eq "#599 AC21(5b) direct-review identity split: devflow-runner.yml checkout step is present and never consumes the read-only reviewer token (it is not a write/checkout credential)" "yes" \
  "$(printf '%s\n' "$_ac21_coblk" | grep -qF 'actions/checkout@' && ! printf '%s\n' "$_ac21_coblk" | grep -qF 'reviewer-token' && echo yes || echo no)"

# ── issue #533: workflow CLI scoping — single validated installer, PATH-scoped
# wrapper selection, no process-global DEVFLOW_GH, harness isolation ──────────

# AC14 — the checked-in installer exists and fingerprints via python3 hashlib
# (preflight-guaranteed), never sha256sum/shasum/awk (not PATH-guaranteed on the
# runner; a silent absence would ship an empty fingerprint — guard-class 2).
assert_eq "#533 AC14: scripts/install-gh-wrapper.sh exists" "yes" \
  "$([ -f "$INSTALL533" ] && echo yes || echo no)"
assert_eq "#533 AC14: installer fingerprints via python3 hashlib and never invokes sha256sum/shasum/awk" "yes" \
  "$(grep -vE '^[[:space:]]*#' "$INSTALL533" 2>/dev/null | grep -qF 'hashlib' && ! grep -vE '^[[:space:]]*#' "$INSTALL533" | grep -qE 'sha256sum|shasum|awk' && echo yes || echo no)"
# The AC10 guard's counting recipe lives in ONE function so the AC22 mutation
# proof below exercises the same recipe the guard runs — never a hand copy that
# could drift green while the real guard's pattern rots.
# The `2>/dev/null` below hides grep's own missing-file error, and BOTH counters feed
# assertions whose expected value is `0` — so an absent or renamed target would read as
# "the file is clean" rather than "the file was never read". Guard readability first and
# emit a non-numeric sentinel, so the assert_eq goes RED naming the cause (issue #695
# review): unknown is not zero.
_ac10_count533() { [ -r "$1" ] || { printf 'UNREADABLE:%s\n' "$1"; return; }; grep -cF 'DEVFLOW_GH=' "$1" 2>/dev/null; }
# Whole-workflow sibling: counts process-global DEVFLOW_GH assignments anywhere
# in a file — shell '=' or YAML env ':' form — with whole-line comments stripped.
_ac10_wf_count533() { [ -r "$1" ] || { printf 'UNREADABLE:%s\n' "$1"; return; }; grep -vE '^[[:space:]]*#' "$1" 2>/dev/null | grep -cE 'DEVFLOW_GH[=:]'; }
assert_eq "#533 AC10: install-gh-wrapper.sh writes no bare DEVFLOW_GH= (only DEVFLOW_GH_REAL=)" "0" \
  "$(_ac10_count533 "$INSTALL533")"

# AC17 — the install step stays gated on DEVFLOW_APP_ID in both writer workflows
# (zero-App jobs never install the wrapper; bare-gh/token behavior is untouched).
for _wf533 in devflow-implement devflow; do
  assert_eq "#533 AC17: $_wf533.yml install step is gated on vars.DEVFLOW_APP_ID" "1" \
    "$(printf '%s\n' "$(mint_blk 'Install fresh-gh wrapper (optional)' "$WF/$_wf533.yml")" | grep -cF "vars.DEVFLOW_APP_ID != ''")"
  # AC10 whole-workflow guard: no process-global DEVFLOW_GH assignment ANYWHERE
  # in the file — shell '=' or YAML env ':' form alike (a re-introduction in the
  # claude step's env: block would re-break fixture PATH stubs exactly like the
  # original defect, and the install-step-scoped guard above cannot see it).
  # DEVFLOW_GH_REAL / DEVFLOW_GH_WRAPDIR carry an underscore after GH, so the
  # [=:] delimiter regex skips them; whole-line comments are stripped so prose
  # mentioning the retired export cannot false-fire. The recipe lives in ONE
  # function so the positive controls below exercise the same recipe the guard
  # runs (a hand-copied grep could drift green while the guard's pattern rots).
  assert_eq "#533 AC10: $_wf533.yml carries no process-global DEVFLOW_GH assignment anywhere (= or : form, comments stripped)" "0" \
    "$(_ac10_wf_count533 "$WF/$_wf533.yml")"
  # The installer reads the token from the APP_TOKEN env value — the step must
  # keep passing it in its env: block, or output 5 fails on every App-enabled run.
  assert_eq "#533 AC14: $_wf533.yml install step passes APP_TOKEN in its env: block" "1" \
    "$(printf '%s\n' "$(mint_blk 'Install fresh-gh wrapper (optional)' "$WF/$_wf533.yml")" | grep -cF 'APP_TOKEN: ${{ steps.app-token.outputs.token }}')"
done
# Positive controls for the whole-file recipe: a regex typo must not leave the
# guard green forever. Plant each re-introduction shape in a scratch fixture and
# assert the SAME recipe fires (1), and that a comment-only mention stays 0.
_t533k="$(probe_tmp '#533 AC10 whole-file guard positive control setup')"
printf 'jobs:\n  claude:\n    env:\n      DEVFLOW_GH: leaked\n' > "$_t533k"
assert_eq "#533 AC22: the whole-file AC10 recipe fires on a planted YAML env DEVFLOW_GH: entry" "1" "$(_ac10_wf_count533 "$_t533k")"
printf '          echo "DEVFLOW_GH=$WRAPDIR/gh" >> "$GITHUB_ENV"\n' > "$_t533k"
assert_eq "#533 AC22: the whole-file AC10 recipe fires on a planted shell DEVFLOW_GH= export (the original defect form)" "1" "$(_ac10_wf_count533 "$_t533k")"
printf '      # prose mentioning DEVFLOW_GH=old-export never fires the guard\n' > "$_t533k"
assert_eq "#533 AC22: the whole-file AC10 recipe stays 0 on a whole-line comment mention" "0" "$(_ac10_wf_count533 "$_t533k")"
rm -f "$_t533k"

# AC14 — the seven validated outputs: each induced failure exits 1 with a
# diagnostic naming that output; the full-success arm lands all seven.
D533="$(mktemp -d "$_iw_tmp_root/d533.XXXXXX")" || {
  echo FAIL >> "$RESULTS_FILE"
  record_fail "#533 AC14 fixture root — mktemp -d failed"
  printf '  FAIL  #533 AC14 fixture root — mktemp -d failed; the installer arms cannot run\n' >&2
  D533=/dev/null/unallocated-d533
}
# The real-gh capture is steered through a PATH stub — the same seam production
# uses — never a bypass branch in the installer itself.
mkdir -p "$D533/bin" "$D533/rtmp" "$D533/emptybin"
printf '#!/usr/bin/env bash\necho "REALGH_CALLED $*"\n' > "$D533/bin/gh"; chmod +x "$D533/bin/gh"
: > "$D533/ghenv"; : > "$D533/ghpath"
# The success fixture env, held in ONE place so every runner below (_i533 and the
# #690 stderr-only sibling _i690) shares it. A new installer env seam is added
# here once, rather than in two blocks ~120 lines apart where the second would
# silently keep running against a stale environment and still pass.
_ENV533=(PATH="$D533/bin:$PATH" DEVFLOW_GH_SOURCE_SH="$LIB/../scripts/gh-fresh.sh"
         APP_TOKEN=FIXTURE_TOKEN_533 RUNNER_TEMP="$D533/rtmp" GITHUB_ENV="$D533/ghenv" GITHUB_PATH="$D533/ghpath"
         DEVFLOW_GH_WRAPDIR="$D533/wrapdir" DEVFLOW_GH_FINGERPRINT_FILE="$D533/rtmp/devflow-gh-fingerprint")
_i533() {  # run the installer with the success fixture env, overriding via "$@"
  env "${_ENV533[@]}" "$@" bash "$INSTALL533" 2>&1
}
# output 1: no executable real gh (gh-less PATH).
_o533_1="$(env APP_TOKEN=t GITHUB_ENV="$D533/ghenv" GITHUB_PATH="$D533/ghpath" \
  RUNNER_TEMP="$D533/rtmp" PATH="$D533/emptybin" "$BASH" "$INSTALL533" 2>&1)"; _rc533_1=$?
assert_eq "#533 AC14 output 1: missing real gh fails rc 1 naming real-gh-resolve" "1 yes" \
  "$_rc533_1 $(printf '%s' "$_o533_1" | grep -qF 'output 1/7 FAILED' && printf '%s' "$_o533_1" | grep -qF '(real-gh-resolve)' && echo yes || echo no)"
# output 2: unreadable wrapper source.
_o533_2="$(_i533 DEVFLOW_GH_SOURCE_SH="$D533/missing-src")"; _rc533_2=$?
assert_eq "#533 AC14 output 2: unreadable wrapper source fails rc 1 naming wrapper-source-read" "1 yes" \
  "$_rc533_2 $(printf '%s' "$_o533_2" | grep -qF 'output 2/7 FAILED' && printf '%s' "$_o533_2" | grep -qF '(wrapper-source-read)' && echo yes || echo no)"
# output 3: wrapper dir blocked by a regular file on its parent path.
: > "$D533/blockfile"
_o533_3="$(_i533 DEVFLOW_GH_WRAPDIR="$D533/blockfile/sub")"; _rc533_3=$?
assert_eq "#533 AC14 output 3: uncreatable wrapper dir fails rc 1 naming wrapdir-create" "1 yes" \
  "$_rc533_3 $(printf '%s' "$_o533_3" | grep -qF 'output 3/7 FAILED' && printf '%s' "$_o533_3" | grep -qF '(wrapdir-create)' && echo yes || echo no)"
# output 4: copy target occupied by a directory named gh.
mkdir -p "$D533/wd4/gh"
_o533_4="$(_i533 DEVFLOW_GH_WRAPDIR="$D533/wd4")"; _rc533_4=$?
assert_eq "#533 AC14 output 4: failed wrapper copy fails rc 1 naming wrapper-copy-exec" "1 yes" \
  "$_rc533_4 $(printf '%s' "$_o533_4" | grep -qF 'output 4/7 FAILED' && printf '%s' "$_o533_4" | grep -qF '(wrapper-copy-exec)' && echo yes || echo no)"
# output 5a: empty APP_TOKEN (nothing to fingerprint).
_o533_5a="$(_i533 APP_TOKEN=)"; _rc533_5a=$?
assert_eq "#533 AC14 output 5: empty APP_TOKEN fails rc 1 naming fingerprint-compute" "1 yes" \
  "$_rc533_5a $(printf '%s' "$_o533_5a" | grep -qF 'output 5/7 FAILED' && printf '%s' "$_o533_5a" | grep -qF '(fingerprint-compute)' && echo yes || echo no)"
# output 5b: python3 itself failing (shadowed by a failing stub).
mkdir -p "$D533/badpy"
printf '#!/usr/bin/env bash\nexit 1\n' > "$D533/badpy/python3"; chmod +x "$D533/badpy/python3"
_o533_5b="$(_i533 PATH="$D533/badpy:$D533/bin:$PATH")"; _rc533_5b=$?
assert_eq "#533 AC14 output 5: a failing python3 fails rc 1 naming fingerprint-compute" "1 yes" \
  "$_rc533_5b $(printf '%s' "$_o533_5b" | grep -qF 'output 5/7 FAILED' && printf '%s' "$_o533_5b" | grep -qF '(fingerprint-compute)' && echo yes || echo no)"
# output 5c: python3 runs, exits 0, but writes NOTHING — the [ -s ] non-empty
# guard is what catches it (fingerprint-nonempty), distinct from a crash (5b).
mkdir -p "$D533/emptypy"
printf '#!/usr/bin/env bash\nexit 0\n' > "$D533/emptypy/python3"; chmod +x "$D533/emptypy/python3"
rm -f "$D533/rtmp/devflow-gh-fingerprint"
_o533_5c="$(_i533 PATH="$D533/emptypy:$D533/bin:$PATH")"; _rc533_5c=$?
assert_eq "#533 AC14 output 5: a python3 that succeeds writing nothing fails rc 1 naming fingerprint-nonempty" "1 yes" \
  "$_rc533_5c $(printf '%s' "$_o533_5c" | grep -qF 'output 5/7 FAILED' && printf '%s' "$_o533_5c" | grep -qF '(fingerprint-nonempty)' && echo yes || echo no)"
# outputs 3 & 5, RUNNER_TEMP-unset fail-closed branches: with no RUNNER_TEMP and
# no matching override the guard must fire the NAMED diagnostic, never a bash
# unbound-variable abort (the set -u escape the fail-closed contract forbids).
_o533_3b="$(env -u RUNNER_TEMP PATH="$D533/bin:$PATH" DEVFLOW_GH_SOURCE_SH="$LIB/../scripts/gh-fresh.sh" \
  APP_TOKEN=t GITHUB_ENV="$D533/ghenv" GITHUB_PATH="$D533/ghpath" bash "$INSTALL533" 2>&1)"; _rc533_3b=$?
assert_eq "#533 AC14 output 3: RUNNER_TEMP unset with no WRAPDIR override fails rc 1 naming wrapdir-create (no set -u abort)" "1 yes" \
  "$_rc533_3b $(printf '%s' "$_o533_3b" | grep -qF 'output 3/7 FAILED' && printf '%s' "$_o533_3b" | grep -qF '(wrapdir-create)' && echo yes || echo no)"
_o533_5d="$(env -u RUNNER_TEMP PATH="$D533/bin:$PATH" DEVFLOW_GH_SOURCE_SH="$LIB/../scripts/gh-fresh.sh" \
  APP_TOKEN=t GITHUB_ENV="$D533/ghenv" GITHUB_PATH="$D533/ghpath" DEVFLOW_GH_WRAPDIR="$D533/wrapdir-rt" bash "$INSTALL533" 2>&1)"; _rc533_5d=$?
assert_eq "#533 AC14 output 5: RUNNER_TEMP unset with no FINGERPRINT override fails rc 1 naming fingerprint-compute (no set -u abort)" "1 yes" \
  "$_rc533_5d $(printf '%s' "$_o533_5d" | grep -qF 'output 5/7 FAILED' && printf '%s' "$_o533_5d" | grep -qF '(fingerprint-compute)' && echo yes || echo no)"
# output 2 via the PRODUCTION default chain: from a tree root carrying NEITHER a
# vendored nor a repo-relative gh-fresh.sh, the default source lookup fails
# closed with the named diagnostic (the override-driven arm above cannot see a
# broken default chain).
mkdir -p "$D533/tree0"
_o533_2b="$( cd "$D533/tree0" && env PATH="$D533/bin:$PATH" APP_TOKEN=t RUNNER_TEMP="$D533/rtmp" \
  GITHUB_ENV="$D533/ghenv" GITHUB_PATH="$D533/ghpath" DEVFLOW_GH_WRAPDIR="$D533/wrapdir-t0" bash "$INSTALL533" 2>&1 )"; _rc533_2b=$?
assert_eq "#533 AC14 output 2: the production default source chain fails rc 1 naming wrapper-source-read when neither copy exists" "1 yes" \
  "$_rc533_2b $(printf '%s' "$_o533_2b" | grep -qF 'output 2/7 FAILED' && printf '%s' "$_o533_2b" | grep -qF '(wrapper-source-read)' && echo yes || echo no)"
# output 6: GITHUB_ENV pointing into a nonexistent directory.
_o533_6="$(_i533 GITHUB_ENV="$D533/no-such-dir/ghenv")"; _rc533_6=$?
assert_eq "#533 AC14 output 6: unwritable GITHUB_ENV fails rc 1 naming github-env-write" "1 yes" \
  "$_rc533_6 $(printf '%s' "$_o533_6" | grep -qF 'output 6/7 FAILED' && printf '%s' "$_o533_6" | grep -qF '(github-env-write)' && echo yes || echo no)"
# output 7: GITHUB_PATH pointing into a nonexistent directory.
_o533_7="$(_i533 GITHUB_PATH="$D533/no-such-dir/ghpath")"; _rc533_7=$?
assert_eq "#533 AC14 output 7: unwritable GITHUB_PATH fails rc 1 naming github-path-write" "1 yes" \
  "$_rc533_7 $(printf '%s' "$_o533_7" | grep -qF 'output 7/7 FAILED' && printf '%s' "$_o533_7" | grep -qF '(github-path-write)' && echo yes || echo no)"
# Full success — additionally on a PATH whose sha256sum/shasum/awk all FAIL, proving
# the installer's no-GNU-hash-tools contract behaviorally, not just by grep.
mkdir -p "$D533/noshabin"
for _t533 in sha256sum shasum awk; do
  printf '#!/usr/bin/env bash\nexit 127\n' > "$D533/noshabin/$_t533"; chmod +x "$D533/noshabin/$_t533"
done
: > "$D533/ghenv"; : > "$D533/ghpath"
_o533_ok="$(_i533 PATH="$D533/noshabin:$D533/bin:$PATH")"; _rc533_ok=$?
assert_eq "#533 AC14 success: all seven outputs land (rc 0) on a PATH without working sha256sum/shasum/awk" "0" "$_rc533_ok"
assert_eq "#533 AC10: on success GITHUB_ENV carries DEVFLOW_GH_REAL and no bare DEVFLOW_GH" "1 0" \
  "$(grep -cF "DEVFLOW_GH_REAL=$D533/bin/gh" "$D533/ghenv") $(grep -cF 'DEVFLOW_GH=' "$D533/ghenv")"
assert_eq "#533 AC10: on success GITHUB_PATH carries the wrapper dir" "1" "$(grep -cF "$D533/wrapdir" "$D533/ghpath")"
assert_eq "#533 AC14: installed wrapper is executable" "yes" "$([ -x "$D533/wrapdir/gh" ] && echo yes || echo no)"
_fp533_want="$(printf '%s' FIXTURE_TOKEN_533 | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
assert_eq "#533 AC14: fingerprint content is the python3-hashlib sha256 of APP_TOKEN" "$_fp533_want" \
  "$(cat "$D533/rtmp/devflow-gh-fingerprint")"
assert_eq "#533 AC14: fingerprint file is mode 0600" "600" \
  "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$D533/rtmp/devflow-gh-fingerprint")"

# --- #690: output 5/7's fingerprint-mode gate is platform-aware --------------
# The shipped gate compared the mode to the literal 600 unconditionally, which a
# native-Windows python3 can never satisfy (st_mode's permission bits are
# synthesized from FILE_ATTRIBUTE_READONLY alone), so every Windows writer-tier
# run aborted at output 5/7 before the agent started. These assertions extend
# the #533 block and reuse its $D533 fixture rather than standing up a parallel
# one for the same script and the same output.
#
# The breadcrumb assertions run through _i690, a STDERR-ONLY capture sibling of
# _i533: _i533 ends 2>&1 and merges stderr into stdout, so through it an
# implementer emitting the breadcrumb to stdout would ship green, leaving the
# stream half of the criterion unasserted.
_py690="$(command -v python3)"
mkdir -p "$D533/py690"
_stub690() {  # $1 = the exact line the stubbed python3 prints for the os.name+mode probe
  printf '#!/usr/bin/env bash\ncase "$2" in *os.name*) printf "%%s\\n" "%s"; exit 0;; esac\nexec %s "$@"\n' \
    "$1" "$_py690" > "$D533/py690/python3"
  chmod +x "$D533/py690/python3"
}
_i690() {  # stdout discarded, stderr captured; $1 (optional) overrides the installer path
  rm -f "$D533/rtmp/devflow-gh-fingerprint"; : > "$D533/ghenv"; : > "$D533/ghpath"
  # Reuses _ENV533 (the shared fixture env), prepending the stubbed python3 to
  # PATH and giving these cases their own wrapper dir. It cannot simply call
  # _i533: that helper ends `2>&1`, merging stderr into stdout INSIDE the
  # function, so no outer redirection could recover a stderr-only capture.
  # SC2069: brace-group so stdout is discarded INSIDE the group and only the
  # installer's stderr survives on the group's stdout. Reordering to a trailing
  # `2>&1` would capture the OTHER stream and silently change every assertion
  # this stderr-only capture feeds.
  { env "${_ENV533[@]}" PATH="$D533/py690:$D533/bin:$PATH" DEVFLOW_GH_WRAPDIR="$D533/wrapdir690" \
      bash "${1:-$INSTALL533}" 1>/dev/null; } 2>&1
}
# Passing cases. posix+600 is the unchanged POSIX behavior; nt+666 and nt+444 are
# the two reachable Windows values, each additionally asserting the stderr
# breadcrumb and that the installer proceeded to outputs 6 and 7; the
# unrecognized token passes on the mode VALUE alone, never on the token.
_stub690 'posix 600'; _e690_p6="$(_i690)"; _rc690_p6=$?
assert_eq "#690: stubbed 'posix 600' passes output 5/7 (rc 0) and emits NO could-not-establish breadcrumb" "0 no" \
  "$_rc690_p6 $(printf '%s' "$_e690_p6" | grep -qF 'owner-only' && echo yes || echo no)"
_fp690_want="$(printf '%s' FIXTURE_TOKEN_533 | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')"
for _m690 in 666 444; do
  _stub690 "nt $_m690"; _e690_nt="$(_i690)"; _rc690_nt=$?
  assert_eq "#690: stubbed 'nt $_m690' passes output 5/7 (rc 0) and still writes GITHUB_ENV (output 6) and GITHUB_PATH (output 7)" "0 1 1" \
    "$_rc690_nt $(grep -cF "DEVFLOW_GH_REAL=$D533/bin/gh" "$D533/ghenv") $(grep -cF "$D533/wrapdir690" "$D533/ghpath")"
  # Relaxing the MODE gate must not relax the WRITE: a regression that skipped or
  # short-circuited the fingerprint write on this arm would otherwise stay green
  # on the rc/GITHUB_ENV assertions alone (the #533 AC14 content assertion runs
  # only on the strict posix path, against a different wrapdir).
  assert_eq "#690: stubbed 'nt $_m690' still leaves the correct python3-hashlib sha256 fingerprint on disk" "$_fp690_want" \
    "$(cat "$D533/rtmp/devflow-gh-fingerprint" 2>/dev/null)"
  # The breadcrumb: install-gh-wrapper:-prefixed, on STDERR, naming the observed
  # mode value and stating that access is left to the filesystem's ACLs, which
  # this script neither sets nor verifies.
  assert_eq "#690: stubbed 'nt $_m690' writes the install-gh-wrapper: could-not-establish breadcrumb to STDERR, naming mode $_m690 and the ACL caveat" "yes" \
    "$(printf '%s' "$_e690_nt" | grep -qF 'install-gh-wrapper: the owner-only (0600) mode guarantee could not be established' \
       && printf '%s' "$_e690_nt" | grep -qF "observed (platform-synthesized) mode $_m690" \
       && printf '%s' "$_e690_nt" | grep -qF 'which this script neither sets nor verifies' \
       && echo yes || echo no)"
  # A plain stderr line gets no Actions run-summary annotation, and an unestablished
  # security guarantee is exactly what a reader must not have to grep the raw log for.
  # Under GITHUB_ACTIONS the arm emits an additional ::warning:: annotation; off
  # Actions it emits ONLY the bare-prefixed detail line, so a local run stays clean.
  #
  # BOTH operands set GITHUB_ACTIONS explicitly — the negative one by UNSETTING it in
  # a subshell, never by reusing an ambient-env capture like $_e690_nt. `_i690` runs
  # `env "${_ENV533[@]}"`, which inherits the ambient environment, and the required
  # `lib + python tests` CI job runs with GITHUB_ACTIONS=true: an ambient-env capture
  # would take the annotation branch there and turn this row RED on CI alone, while
  # passing at a desk where the variable is unset. Pinning both states makes the row
  # environment-independent.
  assert_eq "#690: the relaxed arm emits a ::warning:: annotation under GITHUB_ACTIONS, and none when it is unset" "yes no" \
    "$(printf '%s' "$(GITHUB_ACTIONS=true _i690)" | grep -qF '::warning::install-gh-wrapper:' && echo yes || echo no) $(printf '%s' "$(unset GITHUB_ACTIONS; _i690)" | grep -qF '::warning::' && echo yes || echo no)"
done
# The `nt` token with a real 600 must take the FIRST arm (mode value) and emit no
# breadcrumb. Without this row nothing pins the arm ORDER: reordering the `if` so
# the nt test precedes the `600` equality would make an nt host that genuinely
# produced 600 emit a false could-not-be-established line, and every other row
# would stay green.
_stub690 'nt 600'; _e690_n6="$(_i690)"; _rc690_n6=$?
assert_eq "#690: stubbed 'nt 600' passes on the mode value via the FIRST arm (rc 0), emitting no could-not-establish breadcrumb (pins arm order)" "0 no" \
  "$_rc690_n6 $(printf '%s' "$_e690_n6" | grep -qF 'owner-only' && echo yes || echo no)"
_stub690 'zz 600'; _e690_u6="$(_i690)"; _rc690_u6=$?
assert_eq "#690: an unrecognized platform token with mode 600 passes on the mode value alone (rc 0), emitting no breadcrumb" "0 no" \
  "$_rc690_u6 $(printf '%s' "$_e690_u6" | grep -qF 'owner-only' && echo yes || echo no)"
# Failing cases — the closed set, enumerated per platform-token class because the
# nt class has no octal-and-failing member by construction (under nt every octal
# mode passes). Every one exits 1 naming the (fingerprint-mode) slug, so the
# relaxed arm can never be reached by an absent token, an absent mode field, a
# value the producer could not have emitted, or a three-field capture.
for _c690 in 'posix 644' 'posix banana' 'posix' \
             'nt banana' 'nt' 'nt 666 x' \
             'zz 644' 'zz banana' 'zz' \
             ''; do
  _stub690 "$_c690"; _e690_f="$(_i690)"; _rc690_f=$?
  assert_eq "#690: stubbed capture '$_c690' keeps the strict comparison — rc 1 naming (fingerprint-mode)" "1 yes" \
    "$_rc690_f $(printf '%s' "$_e690_f" | grep -qF 'output 5/7 FAILED' && printf '%s' "$_e690_f" | grep -qF '(fingerprint-mode)' && echo yes || echo no)"
done
# Pinned so no execution path can attribute the token and the mode to two
# different interpreters (a second os.stat could observe a different file state).
assert_eq "#690: the platform token and the mode are read by a single python3 invocation from a single os.stat" "1" \
  "$(grep -cF "python3 -c 'import os,sys; print(os.name, oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])'" "$INSTALL533")"
# The relaxed arm is an ALLOWLIST equality against the literal nt. A negated test
# against posix would admit the empty token an unreadable os.stat leaves behind,
# turning the fail-closed unreadable-mode arm into a silent pass on every platform.
assert_eq "#690: the relaxed arm tests equality against the literal nt, never a negation against posix" "1 0" \
  "$(grep -cF '[ "$_fpos" = "nt" ]' "$INSTALL533") $(grep -cF '[ "$_fpos" != "posix" ]' "$INSTALL533")"
# No mode-setting chmod is introduced anywhere: the umask 077 stays the sole
# producer of the fingerprint file's mode, which is what keeps the AC22 mutation
# proof below meaningful (a chmod would repair the mutated copy and turn that
# proof green). Asserted over EVERY non-comment chmod in the file rather than
# only those naming FINGERPRINT on the same line — a `chmod 600 "$f"` reached
# through an intermediate assignment, or placed on a following line, defeats the
# umask proof just as completely and a FINGERPRINT-on-the-same-line grep cannot
# see it. The installer's only legitimate chmod is the `+x` on the copied
# wrapper (output 4/7), so the mode-setting count must be exactly zero.
assert_eq "#690: install-gh-wrapper.sh contains no mode-setting chmod at all (only the wrapper's chmod +x)" "0" \
  "$(grep -vE '^[[:space:]]*#' "$INSTALL533" | grep 'chmod' | grep -vc 'chmod +x')"
# Behavioral mutation proof (issue #690). This executes the mutated file rather than
# merely re-grepping a literal, so it
# cannot observe a behavioral case change verdict. Mirroring the #533 AC22
# mutated-installer block instead — mutate the nt disjunct out of a copy, RUN it
# under the stubbed-nt fixture, and observe the reported bug reappear.
_t690m="$(probe_tmp '#690 mutated-installer setup')"
sed -E 's/\[ "\$_fpos" = "nt" \]/[ "$_fpos" = "IMPOSSIBLE" ]/' "$INSTALL533" > "$_t690m"
_stub690 'nt 666'; _e690_m="$(_i690 "$_t690m")"; _rc690_m=$?
assert_eq "#690: mutating the nt disjunct out of an installer copy re-introduces the reported bug — rc 1 naming (fingerprint-mode) under a stubbed 'nt 666'" "1 yes" \
  "$_rc690_m $(printf '%s' "$_e690_m" | grep -qF '(fingerprint-mode)' && echo yes || echo no)"
rm -f "$_t690m"
rm -rf "$D533/py690"

# AC14 — the DEFAULT wrapper-source resolution (output 2's vendored-or-repo
# chain) is the branch PRODUCTION takes: neither workflow passes
# DEVFLOW_GH_SOURCE_SH, so a regression in the default chain (inverted
# precedence, a typo'd vendored path) would otherwise ship green while every
# consumer install failed. The chain is cwd-keyed, so each case runs the
# installer from a fixture tree root.
mkdir -p "$D533/tree1/.devflow/vendor/devflow/scripts" "$D533/tree1/scripts" "$D533/tree2/scripts"
printf '#!/usr/bin/env bash\necho vendored-copy\n' > "$D533/tree1/.devflow/vendor/devflow/scripts/gh-fresh.sh"
printf '#!/usr/bin/env bash\necho repo-copy\n' > "$D533/tree1/scripts/gh-fresh.sh"
printf '#!/usr/bin/env bash\necho repo-copy\n' > "$D533/tree2/scripts/gh-fresh.sh"
: > "$D533/ghenv"; : > "$D533/ghpath"
( cd "$D533/tree1" && env PATH="$D533/bin:$PATH" APP_TOKEN=FIXTURE_TOKEN_533 RUNNER_TEMP="$D533/rtmp" \
    GITHUB_ENV="$D533/ghenv" GITHUB_PATH="$D533/ghpath" DEVFLOW_GH_WRAPDIR="$D533/wrapdir-src1" \
    DEVFLOW_GH_FINGERPRINT_FILE="$D533/rtmp/devflow-gh-fingerprint" bash "$INSTALL533" >/dev/null 2>&1 )
assert_eq "#533 AC14 default SRC: the vendored copy is preferred when both copies exist" "yes" \
  "$(grep -qF 'vendored-copy' "$D533/wrapdir-src1/gh" 2>/dev/null && echo yes || echo no)"
: > "$D533/ghenv"; : > "$D533/ghpath"
( cd "$D533/tree2" && env PATH="$D533/bin:$PATH" APP_TOKEN=FIXTURE_TOKEN_533 RUNNER_TEMP="$D533/rtmp" \
    GITHUB_ENV="$D533/ghenv" GITHUB_PATH="$D533/ghpath" DEVFLOW_GH_WRAPDIR="$D533/wrapdir-src2" \
    DEVFLOW_GH_FINGERPRINT_FILE="$D533/rtmp/devflow-gh-fingerprint" bash "$INSTALL533" >/dev/null 2>&1 )
assert_eq "#533 AC14 default SRC: the repo-relative copy is the fallback when no vendored copy exists" "yes" \
  "$(grep -qF 'repo-copy' "$D533/wrapdir-src2/gh" 2>/dev/null && echo yes || echo no)"

# AC11 — the three production caller classes reach the PATH-installed wrapper
# (the wrapper is the real gh-fresh.sh copied by the installer above; with no
# GH_TOKEN and an absent token file it degrades to a plain invocation of
# DEVFLOW_GH_REAL — the fixture stub — whose echoed marker proves the chain).
_c533_1="$(DEVFLOW_GH_REAL="$D533/bin/gh" DEVFLOW_GH_TOKEN_FILE="$D533/absent-token" \
  PATH="$D533/wrapdir:$PATH" gh api one 2>/dev/null)"
assert_eq "#533 AC11: a direct gh call reaches the PATH-installed wrapper" "yes" \
  "$(printf '%s' "$_c533_1" | grep -qF 'REALGH_CALLED api one' && echo yes || echo no)"
_c533_2cmd="$(DEVFLOW_GH_REAL="$D533/bin/gh" PATH="$D533/wrapdir:$PATH" bash -c ". \"$LIB/resolve-gh.sh\"; devflow_resolve_gh")"
_c533_2="$(DEVFLOW_GH_REAL="$D533/bin/gh" DEVFLOW_GH_TOKEN_FILE="$D533/absent-token" \
  PATH="$D533/wrapdir:$PATH" "$_c533_2cmd" api two 2>/dev/null)"
assert_eq "#533 AC11: a shell helper via devflow_resolve_gh reaches the PATH-installed wrapper" "gh yes" \
  "$_c533_2cmd $(printf '%s' "$_c533_2" | grep -qF 'REALGH_CALLED api two' && echo yes || echo no)"
_c533_3="$(DEVFLOW_GH_REAL="$D533/bin/gh" DEVFLOW_GH_TOKEN_FILE="$D533/absent-token" \
  PATH="$D533/wrapdir:$PATH" python3 -c 'import os,subprocess; gh=os.environ.get("DEVFLOW_GH") or "gh"; print(subprocess.run([gh,"api","three"],capture_output=True,text=True).stdout,end="")')"
assert_eq "#533 AC11: a Python helper GH selector reaches the PATH-installed wrapper" "yes" \
  "$(printf '%s' "$_c533_3" | grep -qF 'REALGH_CALLED api three' && echo yes || echo no)"

# AC12 — an explicitly scoped non-empty DEVFLOW_GH still outranks PATH for the
# shell resolver AND a Python caller, even with the wrapper dir first on PATH.
printf '#!/usr/bin/env bash\necho "OVERRIDE_CALLED $*"\n' > "$D533/override-gh"; chmod +x "$D533/override-gh"
_c533_ov="$(DEVFLOW_GH="$D533/override-gh" PATH="$D533/wrapdir:$PATH" bash -c ". \"$LIB/resolve-gh.sh\"; devflow_resolve_gh")"
assert_eq "#533 AC12: shell resolver honors an explicit DEVFLOW_GH over the PATH wrapper" "$D533/override-gh" "$_c533_ov"
_c533_ovp="$(DEVFLOW_GH="$D533/override-gh" PATH="$D533/wrapdir:$PATH" python3 -c 'import os,subprocess; gh=os.environ.get("DEVFLOW_GH") or "gh"; print(subprocess.run([gh,"api","ov"],capture_output=True,text=True).stdout,end="")')"
assert_eq "#533 AC12: a Python caller honors an explicit DEVFLOW_GH over the PATH wrapper" "yes" \
  "$(printf '%s' "$_c533_ovp" | grep -qF 'OVERRIDE_CALLED api ov' && echo yes || echo no)"

# gh-fresh writer/reader hash symmetry (#544): with sha256sum/shasum/awk all
# failing on PATH, the wrapper's call-time fingerprint comparison still matches
# the installer-written (python3-hashlib) fingerprint via its own python3 arm —
# so the ambient job-start token is substituted with the refreshed one instead
# of silently deferring on exactly the host class the installer was hardened for.
mkdir -p "$D533/wrapb"
cp "$LIB/../scripts/gh-fresh.sh" "$D533/wrapb/gh"; chmod +x "$D533/wrapb/gh"
printf '#!/usr/bin/env bash\necho "TOKEN_SEEN=${GH_TOKEN:-none}"\n' > "$D533/realgh2"; chmod +x "$D533/realgh2"
printf '%s' FRESH_TOKEN_544 > "$D533/tokfile544"
printf '%s' AMBIENT_T_544 | python3 -c 'import hashlib,sys; sys.stdout.write(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' > "$D533/fp544"
_c544="$(env GH_TOKEN=AMBIENT_T_544 DEVFLOW_GH_REAL="$D533/realgh2" DEVFLOW_GH_TOKEN_FILE="$D533/tokfile544" \
  DEVFLOW_GH_FINGERPRINT_FILE="$D533/fp544" PATH="$D533/noshabin:$PATH" bash "$D533/wrapb/gh" api q 2>/dev/null)"
assert_eq "#544 symmetry: fingerprint match works without sha256sum/shasum/awk (python3 arm) — ambient token substituted" "TOKEN_SEEN=FRESH_TOKEN_544" "$_c544"
# AC16 preserved: with EVERY hash method defeated (failing sha256sum/shasum/awk
# AND a failing python3 first on PATH), decide() still takes the disclosed
# could-not-establish defer arm — breadcrumb emitted, ambient token untouched.
_c544b_out="$(env GH_TOKEN=AMBIENT_T_544 DEVFLOW_GH_REAL="$D533/realgh2" DEVFLOW_GH_TOKEN_FILE="$D533/tokfile544" \
  DEVFLOW_GH_FINGERPRINT_FILE="$D533/fp544" PATH="$D533/noshabin:$D533/badpy:$PATH" bash "$D533/wrapb/gh" api q 2>"$D533/c544b.err")"
assert_eq "#544 symmetry: all hash methods defeated still defers on the ambient token with the disclosed breadcrumb" "TOKEN_SEEN=AMBIENT_T_544 yes" \
  "$_c544b_out $(grep -qF 'could not establish the job-start fingerprint comparison' "$D533/c544b.err" && echo yes || echo no)"

# AC13 — launch the suite itself with a failing-sentinel DEVFLOW_GH: the harness
# entry clears it (probe mode exits right after the clear + resolver check), so
# the fixture-local PATH stub — not the sentinel — is what resolves and runs.
# Probe mode deliberately exits 3 (a leaked DEVFLOW_AC13_PROBE in a CI env must
# fail the required check loudly, never pass it green with zero tests run) —
# assert the rc alongside the resolution so the fail-closed exit is pinned.
_ac13="$(DEVFLOW_GH=/nonexistent/failing-sentinel DEVFLOW_AC13_PROBE=1 bash "$LIB/test/run.sh" 2>/dev/null)"; _ac13_rc=$?
assert_eq "#533 AC13: suite launched with a failing-sentinel DEVFLOW_GH resolves gh via the fixture PATH stub (probe exits 3, never a green zero-test suite)" "3 yes" \
  "$_ac13_rc $(printf '%s' "$_ac13" | grep -qF 'resolved=gh output=AC13_PATH_STUB_INVOKED' && echo yes || echo no)"

# AC22 — planted production defects flip the named assertions RED (copy-based;
# the working tree is never mutated).
# (a) Harness defect: remove the entry clear from a run.sh copy (with the resolver
# siblings beside it so the probe still sources) — the inherited sentinel then
# SURVIVES into the probe, i.e. the AC13 assertion above would go RED.
_m533d="$(mktemp -d "$_iw_tmp_root/m533d.XXXXXX")" || {
  echo FAIL >> "$RESULTS_FILE"
  record_fail "#533 AC22 mutated-harness fixture — mktemp -d failed"
  printf '  FAIL  #533 AC22 mutated-harness fixture — mktemp -d failed\n' >&2
  _m533d=/dev/null/unallocated-m533d
}
mkdir -p "$_m533d/test"
sed -E 's/^unset DEVFLOW_GH$/: # planted defect: inherited override no longer cleared/' "$LIB/test/run.sh" > "$_m533d/test/run.sh"
cp "$LIB/resolve-gh.sh" "$LIB/resolve-bin.sh" "$_m533d/"
_ac13m="$(DEVFLOW_GH=/nonexistent/failing-sentinel DEVFLOW_AC13_PROBE=1 bash "$_m533d/test/run.sh" 2>/dev/null || true)"
assert_eq "#533 AC22: a planted removal of the harness clear surfaces the sentinel (AC13 assertion goes RED on the defect)" "yes" \
  "$(printf '%s' "$_ac13m" | grep -qF 'resolved=/nonexistent/failing-sentinel' && echo yes || echo no)"
rm -rf "$_m533d"
# (b) Installer defect: weaken the fingerprint umask on a copy — the installer's
# own output-5 mode validation catches it, rc 1 naming fingerprint-mode.
_t533i="$(probe_tmp '#533 AC22 mutated-installer setup')"
sed -E 's/umask 077/umask 022/' "$INSTALL533" > "$_t533i"
rm -f "$D533/rtmp/devflow-gh-fingerprint"; : > "$D533/ghenv"; : > "$D533/ghpath"
_o533_mut="$(env PATH="$D533/bin:$PATH" DEVFLOW_GH_SOURCE_SH="$LIB/../scripts/gh-fresh.sh" \
  APP_TOKEN=FIXTURE_TOKEN_533 RUNNER_TEMP="$D533/rtmp" GITHUB_ENV="$D533/ghenv" GITHUB_PATH="$D533/ghpath" \
  DEVFLOW_GH_WRAPDIR="$D533/wrapdir-mut" DEVFLOW_GH_FINGERPRINT_FILE="$D533/rtmp/devflow-gh-fingerprint" \
  bash "$_t533i" 2>&1)"; _rc533_mut=$?
assert_eq "#533 AC22: a planted umask defect in a mutated installer copy fails rc 1 naming fingerprint-mode" "1 yes" \
  "$_rc533_mut $(printf '%s' "$_o533_mut" | grep -qF '(fingerprint-mode)' && echo yes || echo no)"
rm -f "$_t533i"
# (c) Installer defect: a re-introduced bare DEVFLOW_GH export on a copy is caught
# by the AC10 guard's OWN counting recipe (_ac10_count533 — the same function the
# real assertion runs, exercised via probe_assert so the intentional RED never
# hits the suite tally; a hand-copied grep here could drift green while the real
# guard's pattern rots).
_t533j="$(probe_tmp '#533 AC22 mutated-installer AC10 setup')"
sed -E 's/DEVFLOW_GH_REAL=\$REAL_GH/DEVFLOW_GH=\$WRAPDIR\/gh/' "$INSTALL533" > "$_t533j"
assert_eq "#533 AC22: a planted bare DEVFLOW_GH export in a mutated installer copy flips the AC10 guard RED" "FAIL" \
  "$(probe_assert assert_eq 'probe-ac10-mutated' "0" "$(_ac10_count533 "$_t533j")")"
rm -f "$_t533j"
rm -rf "$D533"

# ────────────────────────────────────────────────────────────────────────────
echo "install.sh consumer UPGRADE path: provenance, non-clobbering, dry-run, withheld tier, identifier migration"
# ────────────────────────────────────────────────────────────────────────────
# These arms drive the REAL installer end-to-end over REAL fixture consumer
# repositories. A consumer upgrade cannot be verified by reading code: the whole
# defect class is "the installer overwrote something the consumer had edited", and
# only an actual before/after of an actual tree can catch that.
#
# Network-free: DEVFLOW_SRC hands the installer an already-materialized source tree,
# so no clone is attempted, and nothing on this path invokes gh.
IU_INSTALL="$LIB/../install.sh"
IU_REF="0123456789abcdef0123456789abcdef01234567"

# The source tree the fixtures install FROM: the minimum the installer reads, copied
# from the real repo so the arms exercise the shipped scaffolder, the shipped
# workflows and the shipped composite actions rather than stand-ins.
IU_SRC="$_iw_tmp_root/src"
mkdir -p "$IU_SRC/scripts" "$IU_SRC/lib" "$IU_SRC/.devflow" "$IU_SRC/.github/workflows" "$IU_SRC/.github/actions"
cp "$LIB/../scripts/scaffold-config.sh" "$LIB/../scripts/detect-project-tools.sh" "$IU_SRC/scripts/"
cp "$LIB/resolve-jq.sh" "$LIB/resolve-bin.sh" "$IU_SRC/lib/"
# tool-presets.json lives under .devflow/, which is where detect-project-tools.sh
# resolves it from ($SELF_DIR/../.devflow/tool-presets.json). Copying it to scripts/
# left the fixture source tree missing it, so these arms silently drove the
# presets-absent degraded path instead of the shipped one.
cp "$LIB/../.devflow/config.example.json" "$LIB/../.devflow/config.schema.json" \
   "$LIB/../.devflow/tool-presets.json" "$IU_SRC/.devflow/"
assert_eq "installer-upgrade fixture: the offline source tree carries tool-presets.json where detect-project-tools.sh resolves it" "yes" \
  "$([ -f "$IU_SRC/.devflow/tool-presets.json" ] && echo yes || echo no)"
cp "$LIB/../.github/workflows/devflow.yml" "$LIB/../.github/workflows/devflow-implement.yml" "$IU_SRC/.github/workflows/"
for _iu_a in read-project-config setup-project-env vendor-plugin; do
  cp -R "$LIB/../.github/actions/$_iu_a" "$IU_SRC/.github/actions/"
done
assert_eq "installer-upgrade fixture: the offline source tree carries the shipped scaffolder, workflows and vendor-slice" "yes" \
  "$([ -f "$IU_SRC/scripts/scaffold-config.sh" ] && [ -f "$IU_SRC/.github/workflows/devflow.yml" ] \
     && [ -f "$IU_SRC/.github/actions/vendor-plugin/vendor-slice.sh" ] && echo yes || echo no)"

_iu_consumer() {  # $1 = fixture id -> prints a fresh consumer repo root
  local d="$_iw_tmp_root/consumer-$1"
  rm -rf "$d"; mkdir -p "$d/.git"
  printf '%s' "$d"
}
_iu_run() {  # $1 = consumer root, rest = installer arguments; prints merged output
  local d="$1"; shift
  ( cd "$d" && env DEVFLOW_SRC="$IU_SRC" DEVFLOW_REF="$IU_REF" \
      PATH="${IU_PATH_PREFIX:+$IU_PATH_PREFIX:}$PATH" \
      bash "${IU_INSTALL_BIN:-$IU_INSTALL}" "$@" 2>&1 )
}
# A stub directory whose `python3` is present on PATH but exits non-zero — the state
# `offer_python3_shim` exists to remedy, and the one the installer's provenance layer
# must fail SAFE on. Deterministic and self-contained: the suite builds the stub, and
# it is prepended to PATH only inside the _iu_run subshell, so the harness's own
# python3 helpers (_iu_snapshot / _iu_digest) are unaffected and nothing depends on
# what the host happens to have installed. Present-but-unrunnable rather than absent
# is the STRONGER shape: it defeats a `command -v python3` presence check too, and
# devflow_resolve_python is execution-verified precisely for it.
IU_NOPY="$_iw_tmp_root/nopython3"
mkdir -p "$IU_NOPY"
printf '#!/bin/sh\nexit 127\n' > "$IU_NOPY/python3"
chmod +x "$IU_NOPY/python3"
assert_eq "installer-upgrade fixture: the python3 stub is on PATH yet does not execute (so it defeats a presence-only check)" "yes no" \
  "$([ -x "$IU_NOPY/python3" ] && echo yes || echo no) $("$IU_NOPY/python3" -c 'pass' >/dev/null 2>&1 && echo yes || echo no)"
# A content-addressed snapshot of a fixture tree, so "nothing outside the intended
# set changed" is asserted over BYTES, not over a list of paths a partial write
# would still satisfy.
_IU_SNAP_PY='
import hashlib, os, sys
base = sys.argv[1]
out = []
for root, dirs, files in os.walk(base):  # tree-walk-ok: scoped to a fixture consumer repo under the mktemp root this module owns, never to the repository, so it cannot reach a sibling worktree
    dirs.sort()
    if ".git" in dirs:
        dirs.remove(".git")
    for f in sorted(files):
        fp = os.path.join(root, f)
        # A SYMLINK is snapshotted by its target, not by the bytes it resolves to: the
        # #959 arms plant a DANGLING symlink to induce a digest failure, and reading
        # through it would raise and leave this helper printing NOTHING — which would
        # make the "no pre-existing path changed" comparisons pass by comparing two
        # empty strings. Recording the link target also makes "a symlink was replaced
        # by a regular file" a visible change rather than an invisible one.
        if os.path.islink(fp):
            out.append(os.path.relpath(fp, base).replace(os.sep, "/") + " -> " + os.readlink(fp))
            continue
        with open(fp, "rb") as fh:
            d = hashlib.sha256(fh.read()).hexdigest()
        out.append(os.path.relpath(fp, base).replace(os.sep, "/") + " " + d)
sys.stdout.write("\n".join(sorted(out)))
'
_iu_snapshot() { python3 -c "$_IU_SNAP_PY" "$1"; }
_iu_digest() { python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
# One raw presence command per logical line — the pin-corpus lint rejects two on the same
# site span, and several arms below compare three yes/no operands at once. Routing them
# through these three helpers also puts the yes/no convention in one place.
_iu_has() {  # $1 = file, $2 = literal -> yes|no
  grep -qF -- "$2" "$1" && echo yes || echo no
}
_iu_out_has() {  # $1 = captured output, $2 = literal -> yes|no
  printf '%s' "$1" | grep -qF -- "$2" && echo yes || echo no
}
_iu_out_matches() {  # $1 = captured output, $2 = ERE -> yes|no
  printf '%s\n' "$1" | grep -qE -- "$2" && echo yes || echo no
}

# ── Scenario 1: a first-time install APPLIES, and a pristine re-run is a clean,
# write-free dry run. The documented one-liner must not have become a no-op.
IU_C1="$(_iu_consumer pristine)"
IU_O1="$(_iu_run "$IU_C1")"
assert_eq "installer-upgrade: a first-time install applies without --apply (the documented one-liner is unchanged)" "yes yes yes" \
  "$(_iu_out_has "$IU_O1" 'detected a first-time installation; running in apply mode.') $([ -f "$IU_C1/.github/workflows/devflow.yml" ] && echo yes || echo no) $([ -f "$IU_C1/.devflow/install-manifest.json" ] && echo yes || echo no)"
assert_eq "installer-upgrade: the first install records a provenance digest for every artifact it owns" "yes" \
  "$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
want = {".claude-plugin/marketplace.json", ".github/workflows/devflow.yml",
        ".github/workflows/devflow-implement.yml", ".github/actions/read-project-config",
        ".github/actions/setup-project-env", ".github/actions/vendor-plugin"}
arts = d.get("artifacts", {})
print("yes" if want <= set(arts) and all(isinstance(v, str) and len(v) == 64 for v in arts.values()) else "no")
' "$IU_C1/.devflow/install-manifest.json")"
IU_SNAP1="$(_iu_snapshot "$IU_C1")"
IU_O1B="$(_iu_run "$IU_C1")"
assert_eq "installer-upgrade: re-running over an existing installation is a DRY RUN by default and writes nothing" "yes yes yes" \
  "$(_iu_out_has "$IU_O1B" 'detected an existing installation; running in dry-run mode.') $(_iu_out_has "$IU_O1B" 'nothing in this repository was written') $([ "$IU_SNAP1" = "$(_iu_snapshot "$IU_C1")" ] && echo yes || echo no)"
assert_eq "installer-upgrade: a pristine re-run reports an empty diff (0 files would change)" "1" \
  "$(printf '%s\n' "$IU_O1B" | grep -cF 'devflow-install: 0 file(s) would change.')"

# ── Scenario 2: a hand-modified workflow is PRESERVED, byte-for-byte, and the new
# version is offered beside it. This is the defect the whole provenance layer exists
# to stop, so it is asserted on the APPLY path (a dry run cannot destroy anything).
IU_C2="$(_iu_consumer handedit)"
_iu_run "$IU_C2" >/dev/null
printf '\n# CONSUMER-LOCAL-EDIT-MARKER\n' >> "$IU_C2/.github/workflows/devflow.yml"
IU_WF2_BEFORE="$(_iu_digest "$IU_C2/.github/workflows/devflow.yml")"
IU_O2="$(_iu_run "$IU_C2" --apply)"
assert_eq "installer-upgrade: --apply over a hand-modified workflow leaves it BYTE-FOR-BYTE unchanged and writes the new version to a .devflow-new sidecar" "yes yes yes" \
  "$([ "$IU_WF2_BEFORE" = "$(_iu_digest "$IU_C2/.github/workflows/devflow.yml")" ] && echo yes || echo no) $(_iu_has "$IU_C2/.github/workflows/devflow.yml" 'CONSUMER-LOCAL-EDIT-MARKER') $([ -f "$IU_C2/.github/workflows/devflow.yml.devflow-new" ] && echo yes || echo no)"
assert_eq "installer-upgrade: the preserved artifact is reported as locally modified, naming the sidecar" "yes" \
  "$(_iu_out_has "$IU_O2" 'PRESERVED (locally modified since DevFlow wrote it): .github/workflows/devflow.yml')"
assert_eq "installer-upgrade: the sidecar carries DevFlow's version, not the consumer's edit" "yes no" \
  "$([ "$(_iu_digest "$IU_C2/.github/workflows/devflow.yml.devflow-new")" = "$(_iu_digest "$IU_SRC/.github/workflows/devflow.yml")" ] && echo yes || echo no) $(_iu_has "$IU_C2/.github/workflows/devflow.yml.devflow-new" 'CONSUMER-LOCAL-EDIT-MARKER')"
# The conflict is not silently blessed: the manifest still records the ORIGINAL digest,
# so the next run reports it again instead of adopting the edited bytes as provenance.
assert_eq "installer-upgrade: a preserved conflict is re-reported on the next run (its digest is never re-blessed)" "yes" \
  "$(printf '%s' "$(_iu_run "$IU_C2" --apply)" | grep -qF 'PRESERVED (locally modified' && echo yes || echo no)"
# NEGATIVE CONTROL: the same assertion recipe must be able to say "clobbered". Plant an
# installer copy whose classifier always returns `update` and observe the consumer edit
# disappear — proving the arm above measures preservation, not the absence of any write.
IU_MUT2="$(probe_tmp 'installer-upgrade clobber control setup')"
sed -E 's/if \[ "\$cur" = "\$rec" \]; then printf .update.; else printf .modified.; fi/printf update/' \
  "$IU_INSTALL" > "$IU_MUT2"
IU_C2B="$(_iu_consumer handedit-control)"
_iu_run "$IU_C2B" >/dev/null
printf '\n# CONSUMER-LOCAL-EDIT-MARKER\n' >> "$IU_C2B/.github/workflows/devflow.yml"
IU_INSTALL_BIN="$IU_MUT2" _iu_run "$IU_C2B" --apply >/dev/null 2>&1 || true
assert_eq "installer-upgrade NEGATIVE CONTROL: an installer whose classifier always says update DOES clobber the consumer edit (so the preservation arm above is not vacuous)" "no" \
  "$(_iu_has "$IU_C2B/.github/workflows/devflow.yml" 'CONSUMER-LOCAL-EDIT-MARKER')"
rm -f "$IU_MUT2"

# ── Scenario 3: a hand-edited .devflow/config.json keeps every consumer value. The
# config is never a managed artifact — the shared scaffolder only backfills keys.
IU_C3="$(_iu_consumer configedit)"
_iu_run "$IU_C3" >/dev/null
python3 -c '
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["watched_authors"] = ["consumer-chosen-bot"]
d["devflow"] = d.get("devflow", {})
d["devflow"]["allowed_tools"] = ["Bash(consumer-only-tool:*)"]
json.dump(d, open(p, "w"), indent=2)
' "$IU_C3/.devflow/config.json"
_iu_run "$IU_C3" --apply >/dev/null
assert_eq "installer-upgrade: --apply preserves hand-edited .devflow/config.json values (the scaffolder only backfills)" "consumer-chosen-bot Bash(consumer-only-tool:*)" \
  "$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d["watched_authors"][0], d["devflow"]["allowed_tools"][0])
' "$IU_C3/.devflow/config.json")"

# ── Scenario 4: the withheld automatic-review tier. Reported always; removed only on
# the explicit opt-in; never removed from a file that is not recognizably DevFlow's.
#
# The fixtures reproduce the SIGNATURE each withheld file actually carries — its own
# `name:` header — rather than a stand-in that merely contains the string "devflow".
# That distinction is the whole point of the guard (see the adversarial arm below): a
# fixture that only had to contain "devflow" would keep passing against a substring
# match, which is exactly the over-broad guard this scenario now pins against.
_iu_withheld_file() {  # $1 = withheld-tier id -> DevFlow's own header for that workflow
  case "$1" in
    devflow-review)  printf 'name: Devflow Review (auto-trigger)\non: pull_request\njobs: {}\n' ;;
    devflow-runner)  printf 'name: DevFlow Runner (reusable)\non:\n  workflow_call:\njobs: {}\n' ;;
    telemetry-push)  printf 'name: Telemetry push (trusted relay)\non:\n  workflow_run:\njobs: {}\n' ;;
  esac
}
IU_C4="$(_iu_consumer withheld)"
_iu_run "$IU_C4" >/dev/null
for _iu_w in devflow-review devflow-runner telemetry-push; do
  _iu_withheld_file "$_iu_w" > "$IU_C4/.github/workflows/$_iu_w.yml"
done
# Counted with a glob and a builtin loop, never `ls | grep -c`: the count decides an
# assertion outcome, and a non-preflight PATH tool must not be what derives it.
_iu_count_withheld() {  # $1 = consumer root -> how many withheld-tier workflows survive
  local n=0 w
  for w in devflow-review devflow-runner telemetry-push; do
    [ -f "$1/.github/workflows/$w.yml" ] && n=$((n + 1))
  done
  printf '%s' "$n"
}
IU_O4="$(_iu_run "$IU_C4" --apply)"
assert_eq "installer-upgrade: an installation carrying the withheld review tier is told so, is told it stays exposed, and keeps all three files by default" "yes yes 3" \
  "$(_iu_out_has "$IU_O4" 'carries the withheld automatic-review tier (devflow-review devflow-runner telemetry-push)') $(_iu_out_has "$IU_O4" 'issues #930 and #920') $(_iu_count_withheld "$IU_C4")"
assert_eq "installer-upgrade: the default report names the opt-in flag rather than removing anything" "yes" \
  "$(_iu_out_has "$IU_O4" 're-run with --remove-withheld-review-tier')"
IU_O4B="$(_iu_run "$IU_C4" --apply --remove-withheld-review-tier)"
assert_eq "installer-upgrade: the opt-in deletes the three withheld workflows and turns the review config key off" "0 false" \
  "$(_iu_count_withheld "$IU_C4") $(python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1])).get("workflows",{}).get("devflow-review")))' "$IU_C4/.devflow/config.json")"
assert_eq "installer-upgrade: the removal states the branch-protection step no installer can perform" "yes" \
  "$(printf '%s' "$IU_O4B" | grep -qF "branch protection rule" && echo yes || echo no)"
# Signature guard: a same-named workflow that is NOT DevFlow's is never deleted.
IU_C4C="$(_iu_consumer withheld-foreign)"
_iu_run "$IU_C4C" >/dev/null
printf 'name: someone elses telemetry push\non: push\n' > "$IU_C4C/.github/workflows/telemetry-push.yml"
IU_O4C="$(_iu_run "$IU_C4C" --apply --remove-withheld-review-tier)"
assert_eq "installer-upgrade: the opt-in removal is signature-guarded — a same-named workflow carrying no DevFlow signature is left in place" "yes yes" \
  "$([ -f "$IU_C4C/.github/workflows/telemetry-push.yml" ] && echo yes || echo no) $(_iu_out_has "$IU_O4C" 'carries no DevFlow signature; left it untouched')"
# ADVERSARIAL (#959 review): the arm above only proves a file with NO mention of DevFlow
# survives, which a bare `grep -qi devflow` would also have satisfied. The case that
# matters is a workflow the CONSUMER owns, under a generic name they are entitled to use,
# that legitimately mentions the string — a path filter on `.devflow/**`, a comment, a
# step that reads the config. Under a substring guard that file is `rm -f`'d on the
# opt-in, with a log line claiming a withheld-tier workflow was removed. Three separate
# mentions, one per accepted spelling, so a guard that merely got case-folding wrong is
# caught too.
IU_C4D="$(_iu_consumer withheld-consumer-owned)"
_iu_run "$IU_C4D" >/dev/null
cat > "$IU_C4D/.github/workflows/telemetry-push.yml" <<'IUTP'
name: Push our metrics
# We re-run this when devflow config changes, since DevFlow owns the tool list.
on:
  push:
    paths:
      - '.devflow/**'
jobs:
  push:
    runs-on: ubuntu-latest
    steps:
      - run: ./scripts/push-metrics.sh
IUTP
IU_TP4D_BEFORE="$(_iu_digest "$IU_C4D/.github/workflows/telemetry-push.yml")"
IU_O4D="$(_iu_run "$IU_C4D" --apply --remove-withheld-review-tier)"
assert_eq "installer-upgrade #959: a CONSUMER-OWNED telemetry-push.yml that merely mentions devflow survives the opt-in removal, byte-for-byte" "yes yes yes" \
  "$([ -f "$IU_C4D/.github/workflows/telemetry-push.yml" ] && echo yes || echo no) $([ "$IU_TP4D_BEFORE" = "$(_iu_digest "$IU_C4D/.github/workflows/telemetry-push.yml")" ] && echo yes || echo no) $(_iu_out_has "$IU_O4D" 'carries no DevFlow signature; left it untouched')"
assert_eq "installer-upgrade #959: and the run never claims to have removed it" "no" \
  "$(_iu_out_has "$IU_O4D" 'removed withheld review-tier workflow telemetry-push.yml')"
# NEGATIVE CONTROL: restore the old substring guard on a copy and require that consumer
# file to be DESTROYED. Without this, the arm above passes on any guard that happens to
# reject this one fixture, including by accident.
IU_MUT4="$(probe_tmp '#959 withheld-tier substring-guard control setup')"
python3 -c '
import sys
src, dst = sys.argv[1], sys.argv[2]
body = open(src, encoding="utf-8").read()
guard = (
    "    _sig=\"$(devflow_withheld_tier_signature \"$_wt\")\"\n"
    "    _grc=0\n"
    "    if [ -n \"$_sig\" ]; then\n"
    "      grep -qE \"$_sig\" \".github/workflows/$_wt.yml\" || _grc=$?\n"
    "    else\n"
)
substring = (
    "    _grc=0\n"
    "    grep -qi \x27devflow\x27 \".github/workflows/$_wt.yml\" || _grc=$?\n"
    "    if false; then\n"
)
if guard not in body:
    sys.exit("mutation target not found: the withheld-tier signature guard")
open(dst, "w", encoding="utf-8").write(body.replace(guard, substring, 1))
' "$IU_INSTALL" "$IU_MUT4" || printf 'devflow-test: #959 withheld-tier control mutation FAILED to apply\n'
assert_eq "installer-upgrade #959 NEGATIVE CONTROL: the control copy really does restore the substring guard" "yes no" \
  "$(_iu_has "$IU_MUT4" "grep -qi 'devflow' \".github/workflows/\$_wt.yml\" || _grc=\$?") $(_iu_has "$IU_MUT4" 'grep -qE "$_sig"')"
IU_C4E="$(_iu_consumer withheld-consumer-owned-control)"
_iu_run "$IU_C4E" >/dev/null
cp "$IU_C4D/.github/workflows/telemetry-push.yml" "$IU_C4E/.github/workflows/telemetry-push.yml" 2>/dev/null || true
IU_INSTALL_BIN="$IU_MUT4" _iu_run "$IU_C4E" --apply --remove-withheld-review-tier >/dev/null 2>&1 || true
assert_eq "installer-upgrade #959 NEGATIVE CONTROL: the substring guard DOES delete that consumer-owned workflow (so the arm above is not vacuous)" "no" \
  "$([ -f "$IU_C4E/.github/workflows/telemetry-push.yml" ] && echo yes || echo no)"
rm -f "$IU_MUT4"

# ── Scenario 5: a SKIPPED-VERSION jump. The consumer's artifact is older than the one
# being installed but is provably untouched (its bytes match the recorded digest), so it
# is updated in place rather than preserved.
IU_C5="$(_iu_consumer skipped-version)"
_iu_run "$IU_C5" >/dev/null
python3 -c '
import hashlib, json, sys
root, rel = sys.argv[1], ".github/workflows/devflow.yml"
p = root + "/" + rel
body = open(p, encoding="utf-8").read() + "\n# BYTES FROM AN OLDER DEVFLOW RELEASE\n"
open(p, "w", encoding="utf-8").write(body)
mp = root + "/.devflow/install-manifest.json"
m = json.load(open(mp))
m["devflow_version"] = "1111111111111111111111111111111111111111"
m["artifacts"][rel] = hashlib.sha256(body.encode("utf-8")).hexdigest()
json.dump(m, open(mp, "w"), indent=2)
' "$IU_C5"
IU_O5="$(_iu_run "$IU_C5" --apply)"
assert_eq "installer-upgrade: a skipped-version jump updates an untouched older artifact in place (no sidecar, no half-state)" "yes yes no" \
  "$(_iu_out_has "$IU_O5" 'update: .github/workflows/devflow.yml') $([ "$(_iu_digest "$IU_C5/.github/workflows/devflow.yml")" = "$(_iu_digest "$IU_SRC/.github/workflows/devflow.yml")" ] && echo yes || echo no) $([ -e "$IU_C5/.github/workflows/devflow.yml.devflow-new" ] && echo yes || echo no)"
assert_eq "installer-upgrade: the skipped-version upgrade re-stamps devflow_version to the installed ref" "$IU_REF" \
  "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["devflow_version"])' "$IU_C5/.devflow/config.json")"

# ── Scenario 6: an installation that NEVER upgraded — no provenance on record. Unknown
# is not "unmodified": an artifact whose bytes differ is preserved, while one already
# identical to the shipped version is recorded.
#
# The healing is PARTIAL, and saying so is the point (#959 review): without a recorded
# digest there is nothing to compare against, so EVERY differing artifact takes the
# preserve arm — an edited one and a merely-older one alike — and only the already-
# identical ones reach the `unchanged` arm that records. A pre-manifest consumer
# upgrading across a release that changed a workflow therefore does get a sidecar for
# that workflow. The earlier wording here claimed the opposite ("instead of being handed
# a sidecar for every file they never touched"), which is false against this very
# scenario's own second assertion.
IU_C6="$(_iu_consumer no-manifest)"
_iu_run "$IU_C6" >/dev/null
rm -f "$IU_C6/.devflow/install-manifest.json"
printf '\n# PRE-MANIFEST-LOCAL-EDIT\n' >> "$IU_C6/.github/workflows/devflow-implement.yml"
IU_O6="$(_iu_run "$IU_C6" --apply)"
assert_eq "installer-upgrade: with no manifest, a differing artifact is PRESERVED as provenance-unverified rather than assumed pristine" "yes yes" \
  "$(_iu_out_has "$IU_O6" 'PRESERVED (provenance unverified') $(_iu_has "$IU_C6/.github/workflows/devflow-implement.yml" 'PRE-MANIFEST-LOCAL-EDIT')"
assert_eq "installer-upgrade: with no manifest, an already-identical artifact is left alone and its digest recorded (the manifest heals)" "yes yes" \
  "$(_iu_out_has "$IU_O6" 'unchanged: .github/workflows/devflow.yml') $(python3 -c '
import json, sys
a = json.load(open(sys.argv[1]))["artifacts"]
print("yes" if ".github/workflows/devflow.yml" in a and ".github/workflows/devflow-implement.yml" not in a else "no")
' "$IU_C6/.devflow/install-manifest.json")"

# ── Scenario 7: the consumer deleted something the installer expects. It comes back,
# and the run does not abort part-way through.
IU_C7="$(_iu_consumer deleted)"
_iu_run "$IU_C7" >/dev/null
rm -rf "$IU_C7/.github/actions/vendor-plugin" "$IU_C7/.claude-plugin/marketplace.json" "$IU_C7/.devflow/config.json"
IU_O7="$(_iu_run "$IU_C7" --apply)"; IU_RC7=$?
assert_eq "installer-upgrade: artifacts the consumer deleted are recreated and the run still completes" "0 yes yes yes yes" \
  "$IU_RC7 $([ -f "$IU_C7/.github/actions/vendor-plugin/vendor-slice.sh" ] && echo yes || echo no) $([ -f "$IU_C7/.claude-plugin/marketplace.json" ] && echo yes || echo no) $([ -f "$IU_C7/.devflow/config.json" ] && echo yes || echo no) $(_iu_out_has "$IU_O7" 'done (from')"

# ── Scenario 8: the dry run is a real preview — it reports the SAME classifications the
# apply would, and still writes nothing. Two fixtures in the same starting state: one is
# previewed, one is applied; the preview's plan lines must match the apply's.
IU_C8A="$(_iu_consumer preview-a)"; IU_C8B="$(_iu_consumer preview-b)"
for _iu_c in "$IU_C8A" "$IU_C8B"; do
  _iu_run "$_iu_c" >/dev/null
  printf '\n# LOCAL\n' >> "$_iu_c/.github/workflows/devflow.yml"
  rm -f "$_iu_c/.github/workflows/devflow-implement.yml"
done
IU_SNAP8="$(_iu_snapshot "$IU_C8A")"
IU_PLAN8="$(_iu_run "$IU_C8A" --dry-run | grep -E 'devflow-install: (create|update|unchanged|PRESERVED)')"
IU_APPLIED8="$(_iu_run "$IU_C8B" --apply | grep -E 'devflow-install: (create|update|unchanged|PRESERVED)')"
assert_eq "installer-upgrade: the dry run reports exactly the classifications the apply performs (it runs the same code against a sandbox)" "$IU_APPLIED8" "$IU_PLAN8"
assert_eq "installer-upgrade: the dry run leaves the consumer tree byte-for-byte untouched" "yes" \
  "$([ "$IU_SNAP8" = "$(_iu_snapshot "$IU_C8A")" ] && echo yes || echo no)"
IU_DIFF8="$(_iu_run "$IU_C8A" --dry-run)"
assert_eq "installer-upgrade: the dry run names each file it would ADD with its size, without dumping its whole body as a diff" "yes no" \
  "$(_iu_out_matches "$IU_DIFF8" '^ADD +\.github/workflows/devflow-implement\.yml \([0-9]+ lines\)') $(_iu_out_matches "$IU_DIFF8" '^--- a/\.github/workflows/devflow-implement\.yml')"
# A file that exists on BOTH sides gets a real unified diff body, so the maintainer sees
# the exact bytes before consenting. Staged as a provably-untouched older artifact (the
# skipped-version shape), which is the case the upgrade would rewrite.
IU_C8D="$(_iu_consumer preview-modify)"
_iu_run "$IU_C8D" >/dev/null
python3 -c '
import hashlib, json, sys
root, rel = sys.argv[1], ".github/workflows/devflow.yml"
p = root + "/" + rel
body = open(p, encoding="utf-8").read() + "\n# BYTES FROM AN OLDER DEVFLOW RELEASE\n"
open(p, "w", encoding="utf-8").write(body)
mp = root + "/.devflow/install-manifest.json"
m = json.load(open(mp))
m["artifacts"][rel] = hashlib.sha256(body.encode("utf-8")).hexdigest()
json.dump(m, open(mp, "w"), indent=2)
' "$IU_C8D"
IU_DIFF8D="$(_iu_run "$IU_C8D" --dry-run)"
assert_eq "installer-upgrade: the dry run prints a real unified diff body for a file it would rewrite in place" "yes yes yes" \
  "$(_iu_out_matches "$IU_DIFF8D" '^MODIFY \.github/workflows/devflow\.yml$') $(_iu_out_matches "$IU_DIFF8D" '^--- a/\.github/workflows/devflow\.yml$') $(_iu_out_has "$IU_DIFF8D" '-# BYTES FROM AN OLDER DEVFLOW RELEASE')"
# --dry-run is honored on a FIRST-TIME install too, so a maintainer can preview an
# adoption before any file exists.
IU_C8C="$(_iu_consumer preview-fresh)"
IU_SNAP8C="$(_iu_snapshot "$IU_C8C")"
IU_O8C="$(_iu_run "$IU_C8C" --dry-run)"
assert_eq "installer-upgrade: --dry-run forces the preview on a first-time install and writes nothing" "yes yes" \
  "$(_iu_out_has "$IU_O8C" 'nothing in this repository was written') $([ "$IU_SNAP8C" = "$(_iu_snapshot "$IU_C8C")" ] && echo yes || echo no)"

# ── Scenario 9: nothing outside the intended set changes. Compare the whole-tree
# snapshot across an upgrade and require the delta to be exactly the paths the plan
# named — a partial write or a stray temp file left behind shows up here.
IU_C9="$(_iu_consumer scope)"
_iu_run "$IU_C9" >/dev/null
mkdir -p "$IU_C9/src"
printf 'untouched consumer source\n' > "$IU_C9/src/app.txt"
printf 'consumer CI\n' > "$IU_C9/.github/workflows/consumer-ci.yml"
printf '\n# LOCAL\n' >> "$IU_C9/.github/workflows/devflow.yml"
IU_SNAP9="$(_iu_snapshot "$IU_C9")"
_iu_run "$IU_C9" --apply >/dev/null
assert_eq "installer-upgrade: an upgrade touches only the artifacts it named — the consumer's own files and unrelated workflows are bit-identical afterwards" \
  ".github/workflows/devflow.yml.devflow-new" \
  "$(python3 -c '
import sys
before = dict(l.split(" ", 1) for l in sys.argv[1].splitlines() if l)
after = dict(l.split(" ", 1) for l in sys.argv[2].splitlines() if l)
changed = set(before) ^ set(after)
changed |= {k for k in set(before) & set(after) if before[k] != after[k]}
print("\n".join(sorted(changed)))
' "$IU_SNAP9" "$(_iu_snapshot "$IU_C9")")"

# ── Scenario 10: argument handling. A typo must never select the writing mode.
IU_C10="$(_iu_consumer args)"
_iu_run "$IU_C10" >/dev/null
IU_O10="$(_iu_run "$IU_C10" --dryrun)" && IU_RC10=0 || IU_RC10=$?
assert_eq "installer-upgrade: an unrecognized flag exits 2 naming the accepted set, rather than falling through to a write" "2 yes" \
  "$IU_RC10 $(_iu_out_has "$IU_O10" 'unknown argument --dryrun (accepted: --dry-run, --apply, --remove-withheld-review-tier)')"
assert_eq "installer-upgrade: DEVFLOW_APPLY=1 selects the writing mode for a curl-piped invocation that cannot pass a flag" "yes" \
  "$(printf '%s' "$( cd "$IU_C10" && env DEVFLOW_SRC="$IU_SRC" DEVFLOW_REF="$IU_REF" DEVFLOW_APPLY=1 bash "$IU_INSTALL" 2>&1 )" | grep -qF 'running in apply mode.' && echo yes || echo no)"

# ── Scenario 11: identifier migration stays NAME-AGNOSTIC. The installer spells no
# identifier: it reads the canonical pair and the superseded set out of its generated
# identity region, so declaring an alias in lib/plugin-identity.json is the ONLY edit a
# rename needs. Driven over a temp plugin root whose manifest is renamed and whose
# previous name is declared as an alias, with the region regenerated by the real
# generator — never by patching the installer text.
IU_P11="$(mktemp -d "$_iw_tmp_root/p11.XXXXXX")"
mkdir -p "$IU_P11/lib" "$IU_P11/.claude-plugin" "$IU_P11/.github/actions/vendor-plugin" \
         "$IU_P11/.github/workflows" "$IU_P11/scripts"
cp "$LIB/plugin_identity.py" "$LIB/generate-plugin-identity.py" "$LIB/plugin-identity.json" "$IU_P11/lib/"
cp "$LIB/../.claude-plugin/plugin.json" "$IU_P11/.claude-plugin/"
cp "$IU_INSTALL" "$IU_P11/install.sh"
# The generator rewrites every region it knows about, so give it the other three files
# too; only install.sh is read back.
cp "$LIB/../.github/actions/vendor-plugin/vendor-slice.sh" "$IU_P11/.github/actions/vendor-plugin/"
cp "$LIB/../.github/workflows/devflow-runner.yml" "$IU_P11/.github/workflows/"
cp "$LIB/../scripts/resolve-extra-plugins.sh" "$IU_P11/scripts/"
# Fixture identifiers, deliberately neutral: this arm proves the MECHANISM, and the
# names it uses must not read as a proposed product name.
python3 -c '
import json, sys
root = sys.argv[1]
mp = root + "/.claude-plugin/plugin.json"
m = json.load(open(mp))
previous = m["name"]
m["name"] = "fixture-plugin-two"
json.dump(m, open(mp, "w"), indent=2)
ip = root + "/lib/plugin-identity.json"
i = json.load(open(ip))
i["plugin_aliases"] = [previous]
i["marketplace_aliases"] = [i["marketplace_canonical"]]
i["marketplace_canonical"] = "fixture-market-two"
json.dump(i, open(ip, "w"), indent=2)
' "$IU_P11"
python3 "$IU_P11/lib/generate-plugin-identity.py" >/dev/null 2>&1
assert_eq "installer-upgrade identity: regenerating after a declared rename bakes the NEW canonical pair and the superseded ids into install.sh, with no literal hand-edited" "yes yes yes" \
  "$(_iu_has "$IU_P11/install.sh" "DEVFLOW_PLUGIN_CANONICAL='fixture-plugin-two'") $(_iu_has "$IU_P11/install.sh" "DEVFLOW_MARKETPLACE_CANONICAL='fixture-market-two'") $(_iu_out_matches "$(cat "$IU_P11/install.sh")" "^DEVFLOW_SUPERSEDED_PLUGIN_SPECS='[^']+'")"
# A consumer previously installed under the OLD identifiers, upgrading with the renamed
# installer: the marketplace manifest it owns is rewritten to the canonical pair, and the
# settings file it does NOT own is reported, never written.
IU_C11="$(_iu_consumer rename)"
_iu_run "$IU_C11" >/dev/null                     # install under today's identifiers
mkdir -p "$IU_C11/.claude"
python3 -c '
import json, sys
p = sys.argv[1] + "/.claude/settings.json"
json.dump({"extraKnownMarketplaces": {"devflow-marketplace": {"source": {"source": "github", "repo": "The01Geek/devflow-autopilot"}, "autoUpdate": True},
                                      "unrelated-market": {"source": {"source": "github", "repo": "someone/else"}}},
           "enabledPlugins": {"devflow@devflow-marketplace": True, "other@unrelated-market": True}},
          open(p, "w"), indent=2)
' "$IU_C11"
IU_SET11_BEFORE="$(_iu_digest "$IU_C11/.claude/settings.json")"
IU_O11="$(IU_INSTALL_BIN="$IU_P11/install.sh" _iu_run "$IU_C11" --apply)"
assert_eq "installer-upgrade identity: a superseded registration in .claude/settings.json is REPORTED and the file left byte-for-byte unchanged (install.sh never writes it)" "yes yes yes" \
  "$(_iu_out_has "$IU_O11" 'still registers superseded DevFlow identifiers') $(_iu_out_has "$IU_O11" 'enabledPlugins[devflow@devflow-marketplace]') $([ "$IU_SET11_BEFORE" = "$(_iu_digest "$IU_C11/.claude/settings.json")" ] && echo yes || echo no)"
assert_eq "installer-upgrade identity: the report routes the consumer to the ONE owner of that migration rather than duplicating it" "yes" \
  "$(_iu_out_has "$IU_O11" 'run /devflow:init, whose scripts/provision-local-settings.sh removes the superseded registrations')"
assert_eq "installer-upgrade identity: the marketplace manifest the installer OWNS is migrated to the new canonical pair" "fixture-market-two fixture-plugin-two" \
  "$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d["name"], d["plugins"][0]["name"])
' "$IU_C11/.claude-plugin/marketplace.json")"
assert_eq "installer-upgrade identity: an unrelated marketplace/plugin registration is never named as superseded" "no no" \
  "$(_iu_out_has "$IU_O11" 'unrelated-market') $(_iu_out_has "$IU_O11" 'other@unrelated-market')"
# The SHIPPED installer's own declared alias set is not registered in this consumer's
# settings, so the migration report stays silent: the report is driven by an INTERSECTION
# of the declared superseded ids with what the consumer actually registered, not by the
# mere existence of a declared alias.
assert_eq "installer-upgrade identity: the shipped installer reports nothing superseded when none of its declared superseded ids is registered" "no" \
  "$(printf '%s' "$(_iu_run "$IU_C11" --apply)" | grep -qF 'superseded DevFlow identifiers' && echo yes || echo no)"

rm -rf "$IU_P11"

# ── Scenario 12 (#959): the documented python3-absent FAIL-SAFE, driven end to end.
# This is the arm the original 11 scenarios could not reach, because every one of them
# ran with a working python3 — which is exactly why the installer shipped doing the
# OPPOSITE of its own header for a whole supported host class. devflow_digest() printed
# the empty string when python3 was unavailable, the classifier read an empty current
# digest as "file absent -> create", and the create arm is `rm -rf` + `cp`. So a stock
# Windows / Git-Bash consumer's hand-edits were destroyed, silently, on upgrade.
#
# The contract asserted here is the header's, verbatim: nothing existing is overwritten,
# every present artifact is reported preserved, and the manifest is not written.
IU_C12="$(_iu_consumer nopython3)"
_iu_run "$IU_C12" >/dev/null                        # install while python3 still works
printf '\n# CONSUMER-LOCAL-EDIT-MARKER\n' >> "$IU_C12/.github/workflows/devflow.yml"
IU_WF12_BEFORE="$(_iu_digest "$IU_C12/.github/workflows/devflow.yml")"
IU_MANI12_BEFORE="$(_iu_digest "$IU_C12/.devflow/install-manifest.json")"
IU_SNAP12_BEFORE="$(_iu_snapshot "$IU_C12")"
IU_O12="$(IU_PATH_PREFIX="$IU_NOPY" _iu_run "$IU_C12" --apply)" && IU_RC12=0 || IU_RC12=$?
assert_eq "installer-upgrade #959: an --apply upgrade on a host with no working python3 leaves a hand-edited workflow BYTE-FOR-BYTE intact" "yes yes" \
  "$([ "$IU_WF12_BEFORE" = "$(_iu_digest "$IU_C12/.github/workflows/devflow.yml")" ] && echo yes || echo no) $(_iu_has "$IU_C12/.github/workflows/devflow.yml" 'CONSUMER-LOCAL-EDIT-MARKER')"
# The precise wrong classification: `create` on a path that is right there on disk.
# Asserting its ABSENCE is what makes this arm a regression test for the defect rather
# than for its symptom — a future collapse of unknown onto any writing classification
# has to reintroduce one of these two words.
assert_eq "installer-upgrade #959: no existing artifact is classified create or update when the digest cannot be established" "no no" \
  "$(_iu_out_matches "$IU_O12" '^devflow-install: create: ') $(_iu_out_matches "$IU_O12" '^devflow-install: update: ')"
assert_eq "installer-upgrade #959: each present artifact is reported PRESERVED with provenance UNESTABLISHED, naming the sidecar and the python3 remedy" "yes yes yes" \
  "$(_iu_out_has "$IU_O12" 'PRESERVED (provenance UNESTABLISHED') $(_iu_out_has "$IU_O12" '.github/workflows/devflow.yml — the new version is at .github/workflows/devflow.yml.devflow-new') $(_iu_out_has "$IU_O12" 'There is no working python3 on this host, so NOTHING on this run could be compared')"
# `unverified` ("no recorded digest") is a DIFFERENT diagnosis with a different remedy;
# reporting a python3-less host that way would send the consumer to delete their files.
assert_eq "installer-upgrade #959: the unestablished-digest preserve is not misreported as the no-recorded-digest one" "no" \
  "$(_iu_out_has "$IU_O12" 'PRESERVED (provenance unverified')"
assert_eq "installer-upgrade #959: the run still exits 0 and offers DevFlow's sidecar copy of the artifact it preserved" "0 yes yes" \
  "$IU_RC12 $([ -f "$IU_C12/.github/workflows/devflow.yml.devflow-new" ] && echo yes || echo no) $([ "$(_iu_digest "$IU_C12/.github/workflows/devflow.yml.devflow-new")" = "$(_iu_digest "$IU_SRC/.github/workflows/devflow.yml")" ] && echo yes || echo no)"
assert_eq "installer-upgrade #959: the manifest is left byte-for-byte alone (an unestablishable digest must never be recorded as provenance) and the run says so" "yes yes" \
  "$([ "$IU_MANI12_BEFORE" = "$(_iu_digest "$IU_C12/.devflow/install-manifest.json")" ] && echo yes || echo no) $(_iu_out_has "$IU_O12" 'the install provenance manifest (.devflow/install-manifest.json) was not written')"
# The whole-tree form of "nothing existing is overwritten": every path present before
# the upgrade is bit-identical after it, so the only delta is additions. Asserted over
# BYTES across the entire fixture, not over the handful of paths the arms above name.
assert_eq "installer-upgrade #959: across the whole tree, not one pre-existing path changed its bytes — the delta is additions only (over a snapshot proven non-empty)" "ok:" \
  "$(python3 -c '
import sys
before = dict(l.split(" ", 1) for l in sys.argv[1].splitlines() if l)
after = dict(l.split(" ", 1) for l in sys.argv[2].splitlines() if l)
bad = [k for k in before if k not in after or after[k] != before[k]]
sys.stdout.write(("ok:" if len(before) > 5 else "EMPTY-SNAPSHOT:") + " ".join(sorted(bad)))
' "$IU_SNAP12_BEFORE" "$(_iu_snapshot "$IU_C12")")"
# NEGATIVE CONTROL for the whole of Scenario 12. Reintroduce the exact collapse the fix
# removed — infer absence from an empty digest instead of testing the path — on a copy,
# and require the consumer edit to DISAPPEAR. Without this the arms above could pass on
# an installer that simply never writes anything, and the 11 pre-#959 scenarios are the
# standing proof that a suite can be green while this branch is broken.
IU_MUT12="$(probe_tmp '#959 python3-absent clobber control setup')"
python3 -c '
import sys
src, dst = sys.argv[1], sys.argv[2]
body = open(src, encoding="utf-8").read()
guard = "  if [ ! -e \"$rel\" ] && [ ! -L \"$rel\" ]; then printf \x27create\x27; return 0; fi\n"
collapse = "  cur=\"$(devflow_digest \"$rel\")\" || cur=\"\"\n  [ -n \"$cur\" ] || { printf \x27create\x27; return 0; }\n"
if guard not in body:
    sys.exit("mutation target not found: the existence guard in devflow_artifact_action")
open(dst, "w", encoding="utf-8").write(body.replace(guard, collapse, 1))
' "$IU_INSTALL" "$IU_MUT12" || printf 'devflow-test: #959 control mutation FAILED to apply\n'
# The mutation must be PROVEN to have landed: a rotted pattern would leave the control
# running the fixed installer and silently reporting "preserved" as a pass.
assert_eq "installer-upgrade #959 NEGATIVE CONTROL: the control copy really does reintroduce the empty-digest-means-absent collapse" "yes no" \
  "$(_iu_has "$IU_MUT12" '[ -n "$cur" ] || { printf '"'"'create'"'"'; return 0; }') $(_iu_has "$IU_MUT12" 'if [ ! -e "$rel" ] && [ ! -L "$rel" ]; then')"
IU_C12B="$(_iu_consumer nopython3-control)"
_iu_run "$IU_C12B" >/dev/null
printf '\n# CONSUMER-LOCAL-EDIT-MARKER\n' >> "$IU_C12B/.github/workflows/devflow.yml"
IU_O12B="$(IU_INSTALL_BIN="$IU_MUT12" IU_PATH_PREFIX="$IU_NOPY" _iu_run "$IU_C12B" --apply)" || true
assert_eq "installer-upgrade #959 NEGATIVE CONTROL: the collapsed classifier DOES destroy the consumer edit and calls the existing file create (so Scenario 12 is not vacuous)" "no yes" \
  "$(_iu_has "$IU_C12B/.github/workflows/devflow.yml" 'CONSUMER-LOCAL-EDIT-MARKER') $(_iu_out_matches "$IU_O12B" '^devflow-install: create: \.github/workflows/devflow\.yml$')"
rm -f "$IU_MUT12"

# ── Scenario 13 (#959, same root): a digest ERROR on a PRESENT artifact, with a fully
# working python3. The second reachable form of the same defect — `2>/dev/null || printf
# ''` mapped every interpreter failure onto "absent", so a read error on an existing
# artifact wiped and replaced it while masking the real cause as "this doesn't exist yet".
#
# Both arms are induced with a DANGLING SYMLINK rather than a chmod, deliberately: a
# permission-based unreadable file is not reproducible for a run that happens to be root
# (some CI containers are), and a check whose condition the host can dissolve is a check
# that quietly stops testing anything.
IU_C13="$(_iu_consumer digest-error)"
_iu_run "$IU_C13" >/dev/null
# 13a: a FILE artifact that exists as a dangling symlink. `[ -L ]` sees it, `[ -e ]` does
# not, and python3 reports it absent — an established-absence answer about a path the
# builtin test says is there. That disagreement is itself "unestablished".
rm -f "$IU_C13/.github/workflows/devflow.yml"
ln -s ./no-such-target.yml "$IU_C13/.github/workflows/devflow.yml"
# 13b: a DIRECTORY artifact whose os.walk digest cannot complete, because one entry
# inside it cannot be opened. This is the composite-action shape the review called the
# most likely to fail, and it is also the first coverage of directory-artifact behavior
# at all: every earlier preservation arm edited a single-file workflow.
printf '# INNER-DIRECTORY-MARKER\n' >> "$IU_C13/.github/actions/vendor-plugin/vendor-slice.sh"
ln -s ./no-such-inner-file "$IU_C13/.github/actions/vendor-plugin/dangling"
IU_SNAP13_BEFORE="$(_iu_snapshot "$IU_C13")"
IU_O13="$(_iu_run "$IU_C13" --apply)" && IU_RC13=0 || IU_RC13=$?
assert_eq "installer-upgrade #959: a present FILE artifact whose digest cannot be established is preserved as-is — still a symlink, never replaced by a copy" "0 yes yes" \
  "$IU_RC13 $([ -L "$IU_C13/.github/workflows/devflow.yml" ] && echo yes || echo no) $([ -f "$IU_C13/.github/workflows/devflow.yml.devflow-new" ] && echo yes || echo no)"
assert_eq "installer-upgrade #959: a DIRECTORY artifact whose walk digest errors is preserved with its inner contents intact, and its replacement offered beside it" "yes yes yes" \
  "$(_iu_has "$IU_C13/.github/actions/vendor-plugin/vendor-slice.sh" 'INNER-DIRECTORY-MARKER') $([ -L "$IU_C13/.github/actions/vendor-plugin/dangling" ] && echo yes || echo no) $([ -d "$IU_C13/.github/actions/vendor-plugin.devflow-new" ] && echo yes || echo no)"
assert_eq "installer-upgrade #959: the digest error is reported as an unestablished provenance, not masked as a fresh create" "yes no no" \
  "$(_iu_out_has "$IU_O13" 'PRESERVED (provenance UNESTABLISHED') $(_iu_out_matches "$IU_O13" '^devflow-install: create: \.github/workflows/devflow\.yml$') $(_iu_out_matches "$IU_O13" '^devflow-install: create: \.github/actions/vendor-plugin$')"
# The `ok:` prefix is the anti-vacuity half: a snapshot helper that failed on the planted
# dangling symlink would print nothing, and comparing two empty snapshots would satisfy an
# emptiness assertion while measuring absolutely nothing.
assert_eq "installer-upgrade #959: a digest error touches no pre-existing bytes anywhere in the tree (over a snapshot proven non-empty)" "ok:" \
  "$(python3 -c '
import sys
before = dict(l.split(" ", 1) for l in sys.argv[1].splitlines() if l)
after = dict(l.split(" ", 1) for l in sys.argv[2].splitlines() if l)
bad = [k for k in before if k not in after or after[k] != before[k]]
sys.stdout.write(("ok:" if len(before) > 5 else "EMPTY-SNAPSHOT:") + " ".join(sorted(bad)))
' "$IU_SNAP13_BEFORE" "$(_iu_snapshot "$IU_C13")")"

# ── Scenario 13b (#959 review round 3): the two fail-safe TRIGGERS have different blast
# radii, and every prose surface describing them got that wrong three review rounds
# running. Pin the distinction executably so the next reader can check it instead of
# reasoning it out again:
#   GLOBAL (no python3)  -> nothing digestible: EVERY artifact preserved, NO manifest.
#   PER-ARTIFACT (read error, python3 fine) -> only that path preserved; everything else
#                           written normally, and the manifest IS still written.
# Scenario 12 already covers the global arm's tally; this is the per-artifact contrast,
# which is the half the prose kept over-generalizing from.
IU_C13B="$(_iu_consumer digest-error-radius)"
_iu_run "$IU_C13B" >/dev/null
# Exactly ONE artifact made undigestable, with a fully working python3.
rm -f "$IU_C13B/.github/workflows/devflow.yml"
ln -s ./no-such-target.yml "$IU_C13B/.github/workflows/devflow.yml"
# Give another artifact genuinely new bytes to prove it is still WRITTEN on this run.
printf '\n# BYTES FROM AN OLDER DEVFLOW RELEASE\n' >> "$IU_C13B/.github/workflows/devflow-implement.yml"
python3 -c '
import hashlib, json, sys
root, rel = sys.argv[1], ".github/workflows/devflow-implement.yml"
m = json.load(open(root + "/.devflow/install-manifest.json"))
m["artifacts"][rel] = hashlib.sha256(open(root + "/" + rel, "rb").read()).hexdigest()
json.dump(m, open(root + "/.devflow/install-manifest.json", "w"), indent=2)
' "$IU_C13B"
IU_O13B="$(_iu_run "$IU_C13B" --apply)"
assert_eq "installer-upgrade #959: a per-artifact read error preserves ONLY that artifact — the others are still classified and written" "yes yes" \
  "$(_iu_out_has "$IU_O13B" 'PRESERVED (provenance UNESTABLISHED') $(_iu_out_matches "$IU_O13B" '^devflow-install: update: \.github/workflows/devflow-implement\.yml$')"
# Asserted over the manifest's CONTENT, not its byte-identity: the written-back digest for
# the updated artifact happens to equal what the first install recorded (the update restores
# the shipped bytes), so a whole-file comparison would read "unchanged" on a manifest that
# was genuinely rewritten. What matters is which entries it now holds — the updated artifact
# re-recorded against the shipped bytes, and the erroring one keeping its EARLIER digest
# rather than being re-blessed against bytes nothing could read.
assert_eq "installer-upgrade #959: and the manifest IS still written on a per-artifact read error (unlike the no-python3 trigger, which writes none)" "yes recorded-source kept-earlier" \
  "$(_iu_out_has "$IU_O13B" 'recorded install provenance in .devflow/install-manifest.json') $(python3 -c '
import hashlib, json, sys
root, src = sys.argv[1], sys.argv[2]
arts = json.load(open(root + "/.devflow/install-manifest.json"))["artifacts"]
impl = ".github/workflows/devflow-implement.yml"
want = hashlib.sha256(open(src + "/" + impl, "rb").read()).hexdigest()
wf = ".github/workflows/devflow.yml"
# The erroring artifact keeps a real 64-hex digest from before the error - never dropped,
# and never recomputed from the unreadable path.
kept = isinstance(arts.get(wf), str) and len(arts.get(wf, "")) == 64
sys.stdout.write(("recorded-source" if arts.get(impl) == want else "NOT-RECORDED")
                 + " " + ("kept-earlier" if kept else "LOST"))
' "$IU_C13B" "$IU_SRC")"
# The remedy the message names must match the cause. Telling a consumer whose python3
# works to "resolve a working python3" is the same class of error as the original Critical:
# reporting a fact the code never established.
assert_eq "installer-upgrade #959: the per-artifact message names a READ error on that path, and never the no-python3 remedy" "yes no" \
  "$(_iu_out_has "$IU_O13B" 'python3 works here, so this is a read error on this path') $(_iu_out_has "$IU_O13B" 'There is no working python3 on this host')"
# …and the converse, so neither message can drift into the other's trigger.
assert_eq "installer-upgrade #959: the no-python3 message never claims a per-path read error" "no" \
  "$(_iu_out_has "$IU_O12" 'python3 works here, so this is a read error on this path')"

# ── Scenario 14 (#959): POSITIVE CONTROL. The fix must be "preserve what is there", not
# "never write". A genuinely absent path still has to be created — including on the very
# host that triggered the defect, where no digest is available to prove absence with. If
# this arm ever fails, the fail-safe has turned into a fail-shut and a python3-less
# consumer can no longer install at all.
IU_C14="$(_iu_consumer nopython3-create)"
_iu_run "$IU_C14" >/dev/null
rm -f "$IU_C14/.github/workflows/devflow-implement.yml"
rm -rf "$IU_C14/.github/actions/setup-project-env"
IU_O14="$(IU_PATH_PREFIX="$IU_NOPY" _iu_run "$IU_C14" --apply)"
assert_eq "installer-upgrade #959 POSITIVE CONTROL: with no working python3, a genuinely absent file and directory are still created, and reported as create" "yes yes yes yes" \
  "$([ -f "$IU_C14/.github/workflows/devflow-implement.yml" ] && echo yes || echo no) $([ -d "$IU_C14/.github/actions/setup-project-env" ] && echo yes || echo no) $(_iu_out_matches "$IU_O14" '^devflow-install: create: \.github/workflows/devflow-implement\.yml$') $(_iu_out_matches "$IU_O14" '^devflow-install: create: \.github/actions/setup-project-env$')"
# …and the green-field case: a first-time install on a python3-less host must land the
# whole artifact set, because absence is now decided without the interpreter.
IU_C14B="$(_iu_consumer nopython3-fresh)"
IU_O14B="$(IU_PATH_PREFIX="$IU_NOPY" _iu_run "$IU_C14B")"
assert_eq "installer-upgrade #959 POSITIVE CONTROL: a first-time install on a python3-less host still installs every owned artifact" "yes yes yes yes" \
  "$(_iu_out_has "$IU_O14B" 'detected a first-time installation; running in apply mode.') $([ -f "$IU_C14B/.github/workflows/devflow.yml" ] && echo yes || echo no) $([ -f "$IU_C14B/.claude-plugin/marketplace.json" ] && echo yes || echo no) $([ -d "$IU_C14B/.github/actions/vendor-plugin" ] && echo yes || echo no)"

# ── Scenario 15 (#959): the manifest is a best-effort parser over a file a human can
# hand-corrupt, so it gets the adversarial input-shape matrix CLAUDE.md requires rather
# than only the "deleted it" row Scenario 6 covers. Every malformed shape must degrade to
# an empty recorded digest — never to a spurious match, which would classify a
# hand-edited artifact as `update` and clobber it.
#
# Driven by sourcing the installer under DEVFLOW_SELFTEST=1 and calling the two functions
# directly: the classification is the thing under test, and a full installer run per row
# would obscure which shape produced which answer.
IU_C15="$(_iu_consumer manifest-shapes)"
_iu_run "$IU_C15" >/dev/null
printf '\n# SHAPE-MATRIX-LOCAL-EDIT\n' >> "$IU_C15/.github/workflows/devflow.yml"
_iu_manifest_shape() {  # $1 = literal manifest bytes -> "<recorded> <classification>"
  printf '%s' "$1" > "$IU_C15/.devflow/install-manifest.json"
  # shellcheck disable=SC1090  # sources install.sh at runtime under DEVFLOW_SELFTEST
  ( cd "$IU_C15" && DEVFLOW_SELFTEST=1 . "$IU_INSTALL" \
      && printf '%s %s' \
           "$(devflow_recorded_digest '.github/workflows/devflow.yml' || printf 'RC')" \
           "$(devflow_artifact_action '.github/workflows/devflow.yml' "$IU_SRC/.github/workflows/devflow.yml")" ) 2>/dev/null
}
assert_eq "installer-upgrade #959 manifest matrix: truncated JSON yields no recorded digest and preserves the edited artifact" " unverified" \
  "$(_iu_manifest_shape '{"artifacts": {"a": ')"
assert_eq "installer-upgrade #959 manifest matrix: a non-JSON manifest degrades rather than aborting the installer" " unverified" \
  "$(_iu_manifest_shape 'this is not json at all')"
assert_eq "installer-upgrade #959 manifest matrix: an empty manifest file degrades" " unverified" \
  "$(_iu_manifest_shape '')"
assert_eq "installer-upgrade #959 manifest matrix: a top-level ARRAY is not indexed as a mapping" " unverified" \
  "$(_iu_manifest_shape '[{"artifacts": {}}]')"
assert_eq "installer-upgrade #959 manifest matrix: a top-level scalar degrades" " unverified" \
  "$(_iu_manifest_shape '42')"
assert_eq "installer-upgrade #959 manifest matrix: an artifacts ARRAY is not indexed as a mapping" " unverified" \
  "$(_iu_manifest_shape '{"artifacts": [".github/workflows/devflow.yml"]}')"
assert_eq "installer-upgrade #959 manifest matrix: an artifacts SCALAR degrades" " unverified" \
  "$(_iu_manifest_shape '{"artifacts": "everything"}')"
assert_eq "installer-upgrade #959 manifest matrix: a missing artifacts key degrades" " unverified" \
  "$(_iu_manifest_shape '{"manifest_version": 1}')"
assert_eq "installer-upgrade #959 manifest matrix: a NON-STRING entry is not compared against the digest" " unverified" \
  "$(_iu_manifest_shape '{"artifacts": {".github/workflows/devflow.yml": {"sha256": "x"}}}')"
assert_eq "installer-upgrade #959 manifest matrix: a null entry degrades" " unverified" \
  "$(_iu_manifest_shape '{"artifacts": {".github/workflows/devflow.yml": null}}')"
# The matrix must be able to say something OTHER than `unverified`, or every row above is
# satisfied by a function that returns the same word unconditionally. A well-formed
# manifest recording the artifact's PREVIOUS digest classifies the same edited file
# `modified` — a different word, from a real comparison.
assert_eq "installer-upgrade #959 manifest matrix CONTROL: a well-formed manifest yields a real digest and a real comparison" "yes modified" \
  "$(printf '%s' "$(_iu_manifest_shape "$(python3 -c '
import hashlib, json, sys
src = sys.argv[1]
body = open(src, "rb").read()
print(json.dumps({"manifest_version": 1, "artifacts": {".github/workflows/devflow.yml": hashlib.sha256(body).hexdigest()}}))
' "$IU_SRC/.github/workflows/devflow.yml")")" | python3 -c '
import re, sys
rec, _, act = sys.stdin.read().strip().partition(" ")
print(("yes" if re.fullmatch(r"[0-9a-f]{64}", rec) else "no"), act)
')"

# ── Scenario 16 (#959): a DIRECTORY artifact whose inner file was hand-edited is
# preserved, with a working python3. The directory digest walks the tree, so an inner
# edit has to move it — a claim the shipped code made only in a comment until now.
IU_C16="$(_iu_consumer dir-handedit)"
_iu_run "$IU_C16" >/dev/null
printf '\n# COMPOSITE-ACTION-LOCAL-EDIT\n' >> "$IU_C16/.github/actions/vendor-plugin/vendor-slice.sh"
IU_O16="$(_iu_run "$IU_C16" --apply)"
assert_eq "installer-upgrade #959: an inner-file edit inside a composite action marks the whole directory modified and preserves it" "yes yes yes" \
  "$(_iu_out_has "$IU_O16" 'PRESERVED (locally modified since DevFlow wrote it): .github/actions/vendor-plugin') $(_iu_has "$IU_C16/.github/actions/vendor-plugin/vendor-slice.sh" 'COMPOSITE-ACTION-LOCAL-EDIT') $([ -d "$IU_C16/.github/actions/vendor-plugin.devflow-new" ] && echo yes || echo no)"
assert_eq "installer-upgrade #959: the directory sidecar carries DevFlow's copy, not the consumer's edited one" "no" \
  "$(_iu_has "$IU_C16/.github/actions/vendor-plugin.devflow-new/vendor-slice.sh" 'COMPOSITE-ACTION-LOCAL-EDIT')"
# A file ADDED inside the directory moves the digest too (the walk is over the whole set,
# not over the files DevFlow shipped), so a consumer's extra file is not silently wiped
# by the `rm -rf`+`cp -R` the update arm performs.
IU_C16B="$(_iu_consumer dir-addfile)"
_iu_run "$IU_C16B" >/dev/null
printf 'consumer addition\n' > "$IU_C16B/.github/actions/vendor-plugin/consumer-extra.sh"
_iu_run "$IU_C16B" --apply >/dev/null
assert_eq "installer-upgrade #959: a file the consumer ADDED inside a composite action survives the upgrade" "yes" \
  "$([ -f "$IU_C16B/.github/actions/vendor-plugin/consumer-extra.sh" ] && echo yes || echo no)"

# ── Scenario 17 (#959): the withheld-tier config disabler is a best-effort parser too.
# Scenario 4 covers only its success arm; these are the two non-happy exits — a config
# that is not a JSON object (rc 3) and one where the key is already false (rc 4) — which
# must produce their own distinct breadcrumbs and never restructure the consumer's config.
IU_C17="$(_iu_consumer withheld-shapes)"
_iu_run "$IU_C17" >/dev/null
_iu_withheld_file devflow-review > "$IU_C17/.github/workflows/devflow-review.yml"
printf '[1, 2, 3]\n' > "$IU_C17/.devflow/config.json"
IU_CFG17_BEFORE="$(_iu_digest "$IU_C17/.devflow/config.json")"
IU_O17="$(_iu_run "$IU_C17" --apply --remove-withheld-review-tier)"
assert_eq "installer-upgrade #959: a non-object .devflow/config.json is reported and left byte-for-byte alone, never restructured" "yes yes" \
  "$(_iu_out_has "$IU_O17" 'it is missing, malformed, or holds a non-object at that key') $([ "$IU_CFG17_BEFORE" = "$(_iu_digest "$IU_C17/.devflow/config.json")" ] && echo yes || echo no)"
IU_C17B="$(_iu_consumer withheld-already-false)"
_iu_run "$IU_C17B" >/dev/null
_iu_withheld_file devflow-review > "$IU_C17B/.github/workflows/devflow-review.yml"
python3 -c '
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["workflows"] = dict(d.get("workflows") or {}, **{"devflow-review": False})
json.dump(d, open(p, "w"), indent=2)
' "$IU_C17B/.devflow/config.json"
IU_O17B="$(_iu_run "$IU_C17B" --apply --remove-withheld-review-tier)"
assert_eq "installer-upgrade #959: an already-false review key is reported as already-false, distinctly from a failure" "yes no" \
  "$(_iu_out_has "$IU_O17B" 'is already false in .devflow/config.json') $(_iu_out_has "$IU_O17B" 'could not set workflows')"
# A non-object `workflows` value takes the same rc-3 arm — the config is not rewritten
# underneath the consumer just because one key holds the wrong type.
IU_C17C="$(_iu_consumer withheld-nonobject-workflows)"
_iu_run "$IU_C17C" >/dev/null
_iu_withheld_file devflow-review > "$IU_C17C/.github/workflows/devflow-review.yml"
python3 -c '
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["workflows"] = "all of them"
json.dump(d, open(p, "w"), indent=2)
' "$IU_C17C/.devflow/config.json"
IU_O17C="$(_iu_run "$IU_C17C" --apply --remove-withheld-review-tier)"
assert_eq "installer-upgrade #959: a non-object workflows value is reported and the config left with that value intact" "yes all of them" \
  "$(_iu_out_has "$IU_O17C" 'it is missing, malformed, or holds a non-object at that key') $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["workflows"])' "$IU_C17C/.devflow/config.json")"

# ── Scenario 18 (#959 review, suggestion 1): the dry run must SHOW the one deletion it
# performs outside .github. prune_stale_vendored_plugin removes a pre-relocation
# .claude/plugins/devflow tree; devflow_build_preview already copies that subtree into
# the sandbox so the prune runs there, but until .claude/plugins entered the DIFF scope
# the renderer never walked it — so the promised "unified diff of every byte it would
# change" silently omitted a recursive delete. Same class as this round's Critical: a
# promise the code did not keep.
IU_C18="$(_iu_consumer preview-prune)"
_iu_run "$IU_C18" >/dev/null
mkdir -p "$IU_C18/.claude/plugins/devflow/.claude-plugin"
printf '{\n  "name": "devflow",\n  "version": "0.0.1"\n}\n' > "$IU_C18/.claude/plugins/devflow/.claude-plugin/plugin.json"
printf 'stale vendored payload\n' > "$IU_C18/.claude/plugins/devflow/marker.txt"
IU_SNAP18="$(_iu_snapshot "$IU_C18")"
IU_O18="$(_iu_run "$IU_C18" --dry-run)"
assert_eq "installer-upgrade #959: the dry run shows the stale-plugin deletion in its diff, not only in the plan log" "yes yes" \
  "$(_iu_out_has "$IU_O18" 'removed stale committed plugin at .claude/plugins/devflow') $(_iu_out_matches "$IU_O18" '^DELETE \.claude/plugins/devflow/marker\.txt$')"
assert_eq "installer-upgrade #959: and that dry run still writes nothing at all" "yes" \
  "$([ "$IU_SNAP18" = "$(_iu_snapshot "$IU_C18")" ] && echo yes || echo no)"
# The consumer's wider .claude/ is NOT diffed: only `plugins` is in scope, so a settings
# file the installer never writes never appears in the preview.
mkdir -p "$IU_C18/.claude"
printf '{"consumerOnly": true}\n' > "$IU_C18/.claude/settings.json"
assert_eq "installer-upgrade #959: the preview scope stays narrowed to .claude/plugins — the consumer's own .claude files are never diffed" "no" \
  "$(_iu_out_has "$(_iu_run "$IU_C18" --dry-run)" '.claude/settings.json')"
# The apply performs exactly what the preview showed.
_iu_run "$IU_C18" --apply >/dev/null
assert_eq "installer-upgrade #959: the apply really does remove the stale tree the preview named" "no" \
  "$([ -e "$IU_C18/.claude/plugins/devflow" ] && echo yes || echo no)"

# ── Scenario 19 (#959 review, suggestion 2): the withheld-tier opt-in disables the config
# key BEFORE deleting the workflow files. The two interrupted states are not symmetric —
# "files gone, key still true" is unrecoverable, because devflow_remove_withheld_tier
# returns at its own `present` gate on every later run and never reaches the config edit
# again. Asserted through the ORDER of the emitted lines, which is the only externally
# visible evidence of the sequence.
IU_C19="$(_iu_consumer withheld-order)"
_iu_run "$IU_C19" >/dev/null
for _iu_w in devflow-review devflow-runner telemetry-push; do
  _iu_withheld_file "$_iu_w" > "$IU_C19/.github/workflows/$_iu_w.yml"
done
# A repository that still RUNS the withheld tier has the key true — the shipped example
# already ships it false, so without this the rc-4 "already false" arm fires and the
# ordering would be asserted over the wrong branch.
python3 -c '
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["workflows"] = dict(d.get("workflows") or {}, **{"devflow-review": True})
json.dump(d, open(p, "w"), indent=2)
' "$IU_C19/.devflow/config.json"
IU_O19="$(_iu_run "$IU_C19" --apply --remove-withheld-review-tier)"
assert_eq "installer-upgrade #959: the opt-in really does flip a true review key to false" "False" \
  "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["workflows"]["devflow-review"])' "$IU_C19/.devflow/config.json")"
assert_eq "installer-upgrade #959: the config key is turned off BEFORE the workflow files are deleted (the only self-healing order)" "config-first" \
  "$(printf '%s\n' "$IU_O19" | python3 -c '
import sys
# Either config-half emission counts — the rc-0 flip or the rc-4 already-false report.
# The arm under test is the ORDER of the two halves, not which branch the config edit took.
CONFIG = ("devflow-review\"]=false", "devflow-review\"] is already false")
key = files = None
for i, line in enumerate(sys.stdin):
    if key is None and any(c in line for c in CONFIG):
        key = i
    if files is None and "removed withheld review-tier workflow" in line:
        files = i
if key is None or files is None:
    print("MISSING key=%s files=%s" % (key, files))
else:
    print("config-first" if key < files else "files-first")
')"
# The recovery property the order buys: with the key already false and the files still
# present (the interrupted state the safe order produces), a re-run completes the removal.
IU_C19B="$(_iu_consumer withheld-order-resume)"
_iu_run "$IU_C19B" >/dev/null
for _iu_w in devflow-review devflow-runner telemetry-push; do
  _iu_withheld_file "$_iu_w" > "$IU_C19B/.github/workflows/$_iu_w.yml"
done
python3 -c '
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["workflows"] = dict(d.get("workflows") or {}, **{"devflow-review": False})
json.dump(d, open(p, "w"), indent=2)
' "$IU_C19B/.devflow/config.json"
_iu_run "$IU_C19B" --apply --remove-withheld-review-tier >/dev/null
assert_eq "installer-upgrade #959: an interrupted removal that already flipped the key still completes on the next run" "0" \
  "$(_iu_count_withheld "$IU_C19B")"
# ── (#959 review round 3, finding 4) Ordering alone does not make the stranded state
# impossible — the config edit can FAIL. When it does, the files must NOT be deleted:
# doing so lands in exactly the "files gone, key still true" state the ordering exists to
# prevent, and with `present` then empty no later run can retry. The invariant the comment
# asserts is now the invariant the code enforces.
IU_C19C="$(_iu_consumer withheld-order-disable-fails)"
_iu_run "$IU_C19C" >/dev/null
for _iu_w in devflow-review devflow-runner telemetry-push; do
  _iu_withheld_file "$_iu_w" > "$IU_C19C/.github/workflows/$_iu_w.yml"
done
printf '[1, 2, 3]\n' > "$IU_C19C/.devflow/config.json"   # a shape the disabler refuses to edit
IU_O19C="$(_iu_run "$IU_C19C" --apply --remove-withheld-review-tier)"
assert_eq "installer-upgrade #959: when the config key cannot be turned off, the workflow files are KEPT rather than stranding the key true" "3 yes yes" \
  "$(_iu_count_withheld "$IU_C19C") $(_iu_out_has "$IU_O19C" 'leaving the withheld review-tier workflow files in place') $(_iu_out_has "$IU_O19C" 'removing the files first would strand that key true')"
assert_eq "installer-upgrade #959: and it never reports having removed one" "no" \
  "$(_iu_out_has "$IU_O19C" 'removed withheld review-tier workflow')"
# A repo with NO config file at all has no key to strand, so removal proceeds — the gate
# is "is the key provably not left true", not "does a config exist".
IU_C19D="$(_iu_consumer withheld-order-no-config)"
_iu_run "$IU_C19D" >/dev/null
for _iu_w in devflow-review devflow-runner telemetry-push; do
  _iu_withheld_file "$_iu_w" > "$IU_C19D/.github/workflows/$_iu_w.yml"
done
rm -f "$IU_C19D/.devflow/config.json"
_iu_run "$IU_C19D" --apply --remove-withheld-review-tier >/dev/null
assert_eq "installer-upgrade #959: with no config file there is no key to strand, so the removal still proceeds" "0" \
  "$(_iu_count_withheld "$IU_C19D")"
# ── (#959 review round 3, finding 5) grep's rc is three-valued, and rc 2 (could not read
# the file) is not rc 1 (read it, no match). Folding them together reports a content
# judgement the code never made.
#
# Driven at the FUNCTION level, because the whole-installer path cannot reach this arm:
# devflow_withheld_tier_present gates on `[ -f ]`, so anything unreadable-by-being-absent
# never enters `present`. Handing the function a `present` entry whose file is gone models
# the real case — the file vanished between the presence scan and the removal — and makes
# grep return a genuine rc 2 deterministically, without a chmod that dissolves under root.
IU_C19E="$(_iu_consumer withheld-unreadable)"
_iu_run "$IU_C19E" >/dev/null
_iu_withheld_file devflow-review > "$IU_C19E/.github/workflows/devflow-review.yml"
# shellcheck disable=SC1090  # sources install.sh at runtime under DEVFLOW_SELFTEST
IU_O19E="$( cd "$IU_C19E" && DEVFLOW_SELFTEST=1 . "$IU_INSTALL" \
    && REMOVE_WITHHELD=1 devflow_remove_withheld_tier 'devflow-review telemetry-push' 2>&1 )"
assert_eq "installer-upgrade #959: an UNREADABLE withheld-tier path is reported as a read failure, explicitly not as a judgement that it is not DevFlow's" "yes yes" \
  "$(_iu_out_has "$IU_O19E" 'could not read .github/workflows/telemetry-push.yml to check its signature') $(_iu_out_has "$IU_O19E" 'This is a read failure, NOT a judgement')"
assert_eq "installer-upgrade #959: the unreadable path is not folded into the no-signature message, while a genuinely matching sibling IS still removed" "no no" \
  "$(_iu_out_has "$IU_O19E" 'telemetry-push.yml carries no DevFlow signature') $([ -f "$IU_C19E/.github/workflows/devflow-review.yml" ] && echo yes || echo no)"
# Control: the rc-1 arm still reports the content judgement, so the two are genuinely
# distinguished rather than the rc-2 wording having simply replaced both.
printf 'name: someone elses telemetry push\non: push\n' > "$IU_C19E/.github/workflows/telemetry-push.yml"
# shellcheck disable=SC1090  # sources install.sh at runtime under DEVFLOW_SELFTEST
IU_O19F="$( cd "$IU_C19E" && DEVFLOW_SELFTEST=1 . "$IU_INSTALL" \
    && REMOVE_WITHHELD=1 devflow_remove_withheld_tier 'telemetry-push' 2>&1 )"
assert_eq "installer-upgrade #959 CONTROL: a readable non-matching file still reports the no-signature judgement, not the read failure" "yes no yes" \
  "$(_iu_out_has "$IU_O19F" 'telemetry-push.yml carries no DevFlow signature') $(_iu_out_has "$IU_O19F" 'This is a read failure') $([ -f "$IU_C19E/.github/workflows/telemetry-push.yml" ] && echo yes || echo no)"

# ── Scenario 20 (#959 review, suggestion 3): fail-safe/warning arms that are consumer-
# facing documented behavior but had no coverage. None of these is in the clobber-
# prevention core; they are the branches a consumer actually SEES when something is wrong.
# (a) the dry-run diff renderer with no working python3 — the documented "the plan lines
#     above are the whole preview" degradation.
IU_C20="$(_iu_consumer render-nopython3)"
_iu_run "$IU_C20" >/dev/null
IU_O20="$(IU_PATH_PREFIX="$IU_NOPY" _iu_run "$IU_C20" --dry-run)"
assert_eq "installer-upgrade #959: a dry run with no working python3 says the diff cannot be rendered and names the plan lines as the whole preview" "yes yes" \
  "$(_iu_out_has "$IU_O20" 'cannot render the dry-run diff. The plan lines above are the whole preview') $(_iu_out_has "$IU_O20" 'nothing in this repository was written')"
# (b) a DRY RUN of the destructive opt-in previews the removal and deletes nothing.
IU_C20B="$(_iu_consumer withheld-dryrun)"
_iu_run "$IU_C20B" >/dev/null
for _iu_w in devflow-review devflow-runner telemetry-push; do
  _iu_withheld_file "$_iu_w" > "$IU_C20B/.github/workflows/$_iu_w.yml"
done
IU_SNAP20B="$(_iu_snapshot "$IU_C20B")"
IU_O20B="$(_iu_run "$IU_C20B" --dry-run --remove-withheld-review-tier)"
assert_eq "installer-upgrade #959: a dry run of --remove-withheld-review-tier previews all three deletions and removes none of them" "yes 3 yes" \
  "$(_iu_out_has "$IU_O20B" 'removed withheld review-tier workflow devflow-review.yml') $(_iu_count_withheld "$IU_C20B") $([ "$IU_SNAP20B" = "$(_iu_snapshot "$IU_C20B")" ] && echo yes || echo no)"
# (c) devflow_write_manifest's python3-PRESENT write-failure arm. Induced by making the
#     manifest path a DIRECTORY, so os.replace fails — deterministic and root-immune,
#     unlike a chmod. The install must still complete and warn about the consequence.
IU_C20C="$(_iu_consumer manifest-write-fail)"
_iu_run "$IU_C20C" >/dev/null
rm -f "$IU_C20C/.devflow/install-manifest.json"
mkdir -p "$IU_C20C/.devflow/install-manifest.json"
IU_O20C="$(_iu_run "$IU_C20C" --apply)" && IU_RC20C=0 || IU_RC20C=$?
assert_eq "installer-upgrade #959: an unwritable manifest warns that the next upgrade will preserve everything, and never aborts the install" "0 yes yes" \
  "$IU_RC20C $(_iu_out_has "$IU_O20C" 'could not write .devflow/install-manifest.json; the next upgrade will preserve every existing artifact rather than update it') $(_iu_out_has "$IU_O20C" 'done (from')"
