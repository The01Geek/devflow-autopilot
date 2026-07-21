# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# shellcheck shell=bash
# Sourceable installer / workflow-wiring contract module (issue #695 extraction).
# Contract: the caller sets LIB and RESULTS_FILE, defines assert_eq, and sources
# lib/test/module-harness.sh first (which defines the namespaced module pin API —
# devflow_module_pin_count / devflow_module_pin_unique / devflow_module_pin_present /
# devflow_module_pin_red_under — and the shared fixture helpers mint_blk / probe_tmp /
# probe_assert promoted out of lib/test/run.sh by this same change). This module uses
# assert_eq plus those harness helpers and its own domain-private helpers below
# (_dfbn, _ac10_count533, _ac10_wf_count533, _i533, _stub690, _i690) — it references NO
# helper that lives only in lib/test/run.sh. The module owns its private fixture root
# and cleanup; it never invokes the runner or the full-suite boundary. The inventory in
# installer-wiring.inventory.md maps the extracted coverage to its former run.sh
# locations. Modules may not self-skip.
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
  # Behavioral-fix pin: deleting the `env -u DEVFLOW_APP_PRIVATE_KEY` line reintroduces
  # the /proc/<pid>/environ PEM exposure, so it must flip the pin RED.
  devflow_module_pin_red_under "#487 wiring: $_wf487.yml env -u DEVFLOW_APP_PRIVATE_KEY present (deleting it reopens the /proc PEM leak)" \
    'env -u DEVFLOW_APP_PRIVATE_KEY' '/env -u DEVFLOW_APP_PRIVATE_KEY/d' "$_WFF487"
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

# ── issue #599 AC21: preserved producer safety contracts (numbered (1)–(5) below) ──
# The deferred cloud-writer call-site rework (the other ACs of #599) reworks helper
# instructions and tool grants across the writer skill/workflow graph. These pins
# ensure that rework cannot SILENTLY break the producer-side safety contracts it
# rides on — each guards a distinct workflow/wrapper safety surface. Where the
# operative text is a single file-unique literal the pin is a behavioral-fix pin
# (devflow_module_pin_red_under) whose sed mutation re-introduces the NAMED regression; where
# the property is a scoped presence/absence (an always()-guard inside one step, or a
# credential absent from one step block) it is a scoped count guard — the copy-based
# mutation evidence for those two is recorded in the issue #599 workpad.

# (1) Workflow token permissions — the version-consolidate bump-commit push must
# authenticate as the DevFlow App (a ruleset bypass actor), NOT the default
# GITHUB_TOKEN (github-actions[bot], which main's required-checks ruleset rejects,
# GH013). This file is outside the #357 checkout-token loop above, so pin it here:
# unseeding the App token from checkout reintroduces the rejected bump push (#294/#357).
devflow_module_pin_red_under "#599 AC21(1) workflow token permissions: version-consolidate.yml seeds the App token into checkout (unseeding it runs the bump push as github-actions[bot], rejected by main's ruleset)" \
  'token: ${{ steps.app-token.outputs.token }}' \
  's/token: \$\{\{ steps\.app-token\.outputs\.token \}\}/token: \$\{\{ secrets.GITHUB_TOKEN \}\}/' \
  "$WF/version-consolidate.yml"

# (2) Refresh/cleanup steps — the detached credential refresher (issue #487) is
# retired on EVERY exit path. The existing #487 wiring pin asserts the Stop step
# EXISTS; this pins the always() guard that makes cleanup run even when the claude
# step failed/cancelled. Dropping always() leaks the background refresher.
_ac21_stopblk="$(mint_blk 'Stop credential refresher (optional)' "$WF/devflow-implement.yml")"
assert_eq "#599 AC21(2) refresh/cleanup steps: devflow-implement.yml Stop step is always()-guarded (retires the refresher on every exit path)" "1" \
  "$(printf '%s\n' "$_ac21_stopblk" | grep -cF 'if: ${{ always() && ')"

# (3) Secret-file permissions — the mode-0600 token file the gh wrapper reads is
# written under umask 077 (issue #487/#491). No prior pin covered this surface;
# relaxing the umask leaks the App installation token to same-uid readers.
devflow_module_pin_red_under "#599 AC21(3) secret-file permissions: refresh-app-credentials.sh writes the token file under umask 077 (relaxing it leaks the token to same-uid readers)" \
  '( umask 077; printf '"'"'%s'"'"' "$token" > "$tmp" )' \
  's/umask 077/umask 022/' \
  "$LIB/../scripts/refresh-app-credentials.sh"

# (4) Bad-credential two-strike diagnostics — the gh-fresh.sh wrapper (issue #487)
# recognizes the expired/bad-credential signature that drives the two-strike stop and
# the compaction-immune diagnostic. Existing arms pin the DIAG_LINE EMISSION; this
# pins the SIG signature that triggers it — weakening it silences the whole surface.
devflow_module_pin_red_under "#599 AC21(4) bad-credential two-strike diagnostics: gh-fresh.sh SIG matches HTTP 401 / Bad credentials / Authentication failed (weakening it silences the fail-fast signal)" \
  "SIG='HTTP 401|Bad credentials|fatal: Authentication failed for'" \
  's/Bad credentials\|fatal: Authentication failed for/NEVER_MATCHES/' \
  "$LIB/../scripts/gh-fresh.sh"

# (5) Direct-review identity split — the read-only DevFlow-Reviewer token (issue
# #300/#402) is handed to the review action's github_token, but is NEVER seeded into
# checkout as a write credential. (a) the action consumes the downscoped reviewer
# token; (b) the review job's checkout step block carries no reviewer-token at all.
devflow_module_pin_red_under "#599 AC21(5a) direct-review identity split: devflow-runner.yml review action consumes the downscoped reviewer token (dropping it collapses review posts back onto github-actions)" \
  'github_token: ${{ steps.reviewer-token.outputs.token || secrets.GITHUB_TOKEN }}' \
  's/steps\.reviewer-token\.outputs\.token \|\| //' \
  "$WF/devflow-runner.yml"
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
# Behavioral mutation proof (issue #690). devflow_module_pin_red_under cannot express this:
# it seds a copy and re-greps a literal, never EXECUTING the mutated file, so it
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
