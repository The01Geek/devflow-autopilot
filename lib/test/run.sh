#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Tests for the lib/ jq filters and bash helpers. Run from repo root:
#   bash lib/test/run.sh
#
# Each test asserts a specific load-bearing invariant. A failure here means a
# downstream regression in the /devflow:retrospective-weekly orchestrator or the
# retrospective / retrospective-audit subagent briefs — keep these small and
# targeted, not exhaustive.

set -u

LIB="$(cd "$(dirname "$0")/.." && pwd)"

# Results are recorded to a file (one PASS/FAIL line each) rather than to shell
# variables, so assertions that run inside ( … ) subshells — the config-source.sh and
# render-report.sh blocks, sourced in subshells to contain their `set -e` — are
# counted in the final tally too. Counting in-memory would silently drop them.
RESULTS_FILE="$(mktemp)"
trap 'rm -f "$RESULTS_FILE"' EXIT   # protect RESULTS_FILE immediately; widened below once the bundle temp exists

# issue #218: the /devflow:implement skill is split into a thin orchestrator
# (skills/implement/SKILL.md) plus the four phases/<stem>.md reference files named in
# IMPL_PHASE_STEMS, read on-demand at phase entry. The ~120 load-bearing IMPL_SKILL/
# DEF_SKILL pins below — and the raw presence/absence/count guards that bypass pin_count —
# target the WHOLE implement skill, not one file. Concatenate the orchestrator + the four
# phase files into one temp "bundle" view (newline-separated, so a file's last line cannot
# merge with the next file's first) and point IMPL_SKILL/DEF_SKILL at it, so every
# content-presence/uniqueness/count call site that reads $IMPL_SKILL/$DEF_SKILL keeps
# working UNCHANGED while now asserting over the relocated content; "exactly one occurrence"
# becomes a global uniqueness check across the whole implement skill. (A *positional* /
# line-ordering guard must NOT use the bundle — it must grep the single owning phase file,
# because the multi-file bundle has no single coordinate space; see the IPS_BACKSTOP_LN /
# IPS_GATE_LN guard for why a bundle `head -1` would pass vacuously.) IMPL_PHASE_STEMS is the
# single source of the phase set: the bundle members, the per-phase structural assertions,
# AND the directory-reconciliation assertion all derive from it, so a phase file can never
# be registered in one place and silently dropped from another. Built FAIL-CLOSED: a failed
# mktemp hard-exits, and a missing / empty / UNREADABLE member (a stripped read bit, a `cat`
# that errors) records a suite FAIL — never a silent partial bundle, which would turn the
# absence/zero-expecting guards (which assert a literal is GONE or a count is 0) into
# vacuous passes.
IMPL_PHASE_STEMS="phase-1-setup phase-2-implement phase-3-review phase-4-documentation"
# Fail-closed bundle-member predicate, FACTORED so the bundle build below AND the F1
# standing anti-vacuity proofs (in the structural-assertions block) exercise the EXACT same
# logic — a replica would risk drifting from the real check. A member must be readable AND
# non-empty to contribute; the `cat` exit status (read errors mid-stream) is checked
# separately at the call site since it performs the actual append.
_impl_bundle_member_usable() { [ -r "$1" ] && [ -s "$1" ]; }
IMPL_SKILL_BUNDLE="$(mktemp)" || { echo "run.sh: could not allocate the implement-skill bundle temp" >&2; exit 1; }
trap 'rm -f "$RESULTS_FILE" "$IMPL_SKILL_BUNDLE"' EXIT
# Build the member list as an ARRAY (not a space-joined string) so a checkout path
# containing a space is preserved rather than word-split — the stems in IMPL_PHASE_STEMS
# are space-free identifiers, but $LIB (the checkout dir) is not guaranteed to be.
_bundle_members=("$LIB/../skills/implement/SKILL.md")
for _s in $IMPL_PHASE_STEMS; do
  _bundle_members+=("$LIB/../skills/implement/phases/${_s}.md")
done
for _m in "${_bundle_members[@]}"; do
  # A member that is missing, empty, OR unreadable (or whose read errors mid-stream) records
  # a FAIL instead of silently contributing nothing — the fail-closed property the header
  # comment promises. The predicate covers missing/empty/unreadable; `&& cat` covers a
  # mid-stream read error.
  if _impl_bundle_member_usable "$_m" && cat "$_m" >> "$IMPL_SKILL_BUNDLE"; then
    printf '\n' >> "$IMPL_SKILL_BUNDLE"
  else
    printf '  FAIL  implement-skill bundle member missing, empty, or unreadable: %s\n' "$_m"
    echo FAIL >> "$RESULTS_FILE"
  fi
done

PASS=0
FAIL=0

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo PASS >> "$RESULTS_FILE"
    printf '  PASS  %s\n' "$name"
  else
    echo FAIL >> "$RESULTS_FILE"
    printf '  FAIL  %s\n         expected: %s\n         actual:   %s\n' \
      "$name" "$expected" "$actual"
  fi
}

# Count the OCCURRENCES of a fixed-string LITERAL in FILE (substring, not whole-line and
# NOT per-line: `grep -oF` prints one line per match, so a literal appearing twice on a
# SINGLE line counts as 2, closing the line-granular `grep -cF` hole where two same-line
# occurrences would read as "1" / falsely-unique). Pure predicate — no RESULTS_FILE side
# effect — so mutation proofs can assert on the raw count against a mutated temp copy
# without polluting the suite tally. `-F` treats LITERAL as a fixed string (regex
# metacharacters are literal). Always prints a SINGLE canonical integer: a present-file-
# but-absent-literal, a missing/unreadable file, and a match all collapse to one line —
# `grep -c .` counts the match lines `grep -oF` emitted (0 when none). On an absent literal
# `grep -c .` both prints `0` and exits 1, so `|| n=0` DOES fire and reassigns the same `0` —
# the captured value and the fallback coincide, so the result is a single clean `0` either
# way (no double-"0"). An absent literal thus yields a clean 0 (the helper below then fails
# it as non-unique, not as a pass).
pin_count() {  # literal file -> prints occurrence count (always a single integer)
  local n
  n="$(grep -oF "$1" "$2" 2>/dev/null | grep -c .)" || n=0
  printf '%s\n' "${n:-0}"
}

# Allocate a temp file for a mutation proof, failing the SUITE (not vacuously passing) if
# mktemp fails. The AC3 anti-vacuity proofs below build mutated temp copies; under `set -u`
# without `set -e` a bare `VAR="$(mktemp)"` failure would leave VAR empty, and a control
# that then reads an empty path silently degrades to its EXPECTED value (e.g. grep over ""
# prints 0, which a "expected 0" control accepts) — the anti-vacuity proof itself going
# vacuous, the exact class this change exists to kill. On mktemp failure this records a
# suite FAIL under NAME, prints the human breadcrumb to STDERR (so it reaches the operator
# instead of being captured into the caller's `$(…)`), and prints the safe sink path
# `/dev/null` to STDOUT. The `/dev/null` is deliberate: an unguarded caller that then does
# `printf … > "$path"` or greps "$path" causes NO working-tree pollution and no spurious
# redirect error (an earlier form printed the breadcrumb itself, which a `> "$breadcrumb"`
# turned into a junk file in the repo cwd). The recorded FAIL still makes the suite go RED,
# so the proof remains fail-closed whether or not the caller checks the rc 1.
probe_tmp() {  # assertion-name -> prints a temp path (rc 0); on mktemp failure records a
               # suite FAIL, prints the breadcrumb to stderr, and prints /dev/null (rc 1)
  local t
  t="$(mktemp)" && { printf '%s\n' "$t"; return 0; }
  echo FAIL >> "$RESULTS_FILE"
  printf '  FAIL  %s — mktemp failed (mutation proof could not run; not a vacuous pass)\n' "$1" >&2
  printf '/dev/null\n'
  return 1
}

# Drift-guard helper: assert LITERAL occurs EXACTLY ONCE in FILE. This is the
# deterministic (guarantee-class) form of the prose "pin a target-unique phrase" rule —
# it closes the PR #154 vacuous-guard hole where a raw `grep -qF` whole-file scan stayed
# GREEN even with the guarded content deleted, because the pinned literal also appeared
# elsewhere in the file. A non-unique (count >= 2) OR absent (count 0) literal FAILs:
# both mean the pin no longer uniquely identifies the guarded content.
assert_pin_unique() {  # name literal file
  local name="$1" literal="$2" file="$3" count
  count="$(pin_count "$literal" "$file")"
  if [ "$count" = "1" ]; then
    echo PASS >> "$RESULTS_FILE"
    printf '  PASS  %s\n' "$name"
  else
    echo FAIL >> "$RESULTS_FILE"
    printf '  FAIL  %s\n         expected exactly 1 occurrence, got: %s\n         literal: %s\n         file: %s\n' \
      "$name" "$count" "$literal" "$file"
  fi
}

# Presence-or-absence check echoing yes/no — for the COMPOUND fail-closed guards
# (`[ -f FILE ] && { … } || echo MISSING-FILE`) where assert_pin_unique cannot apply:
# the pin is either legitimately NON-UNIQUE in the target (a `yes` presence pin whose
# literal recurs) or an ABSENCE pin (expects `no`), and the guard also wraps an
# existence check with a MISSING-FILE sentinel that a uniqueness-only check would
# discard. These two live on a backslash-continuation line that cannot carry an inline
# allowlist comment, so routing them through this NAMED helper (no bare `grep ` token
# on the call site) keeps them out of the repo-wide raw-guard audit below without an
# inline marker. A deliberate, documented escape hatch — NOT a substitute for
# assert_pin_unique on a plain unique presence pin.
grep_present() {  # literal file -> echoes yes if present, no otherwise
  grep -qF "$1" "$2" && echo yes || echo no
}

# Run a single assertion function against an ISOLATED results file and echo its verdict
# (PASS/FAIL) instead of recording it in the suite tally. Used by the AC3 mutation proofs
# to actually exercise assert_pin_unique against a mutated target and confirm it goes RED,
# without that intentional RED counting as a suite failure. The `RESULTS_FILE=…` prefix on
# a function call sets the var only for that call's environment (functions are not special
# builtins), so the global RESULTS_FILE is untouched.
probe_assert() {  # assertion-fn args... -> prints PASS or FAIL (the probed verdict)
  # Guard mktemp (harness is `set -u` without `set -e`, so a bare failure would not abort):
  # an empty $probe would make `tail ""` error and the probe echo empty, surfacing as a
  # MISLEADING wrong-verdict mismatch instead of an environment failure. Emit a distinct
  # breadcrumb token so the cause is unambiguous — note it surfaces as an `assert_eq` mismatch
  # (expected PASS/FAIL, got PROBE_MKTEMP_FAILED), not a recorded suite FAIL, so the proof
  # still goes RED but via the comparison rather than the tally.
  local probe; probe="$(mktemp)" || { echo "PROBE_MKTEMP_FAILED"; return 0; }
  RESULTS_FILE="$probe" "$@" >/dev/null 2>&1
  tail -n 1 "$probe"
  rm -f "$probe"
}

# Allocate a verified-isolated temp DIRECTORY for a git-mutating test, failing the
# SUITE (not vacuously, and NEVER in the real repo) if `mktemp -d` fails. The
# directory twin of probe_tmp: several tests below run `git init/add/commit` — or a
# helper that commits via `git -C "$root"` — inside a throwaway repo. Under this
# harness's `set -u` WITHOUT `set -e`, a bare `DIR="$(mktemp -d)"` failure leaves DIR
# the empty string (set, not unset, so `set -u` does not abort), and BOTH `cd "$DIR"`
# AND `git -C "$DIR"` then silently operate on the CURRENT directory — the real repo —
# so the test's commit lands on the real branch. (`git -C ""` leaves the cwd unchanged
# per git(1)'s -C semantics; it is NOT safer than `cd ""`, which is why this guard
# protects the `git -C` sites too, not only the `cd` ones.)
#
# On `mktemp -d` failure (or an empty / non-directory result) this records a suite FAIL
# under NAME, prints the breadcrumb to STDERR (so it never lands in the caller's `$(…)`),
# and prints a guaranteed-non-directory sentinel path ROOTED AT /dev/null to STDOUT. The
# sentinel is the load-bearing safety: `cd`, `git -C`, and `mkdir -p` on any path under
# /dev/null all fail with ENOTDIR (kernel-enforced — even as root, since /dev/null can
# never become a directory), so an unguarded caller that then runs `git -C "$DIR" …`,
# `( cd "$DIR" && … )`, or `mkdir -p "$DIR/…"` fails CLOSED with ZERO real-repo mutation
# instead of falling back to the cwd. The recorded FAIL makes the suite go RED whether or
# not the caller checks the rc 1 — fail-closed either way (mirrors probe_tmp's /dev/null
# safe-sink discipline, applied to directories).
#
# Caller contract: callers do NOT each need to guard the return — routing the temp-dir
# allocation through this helper is sufficient. On `mktemp -d` failure the helper records
# ONE per-site suite FAIL with a site-named breadcrumb (that pair is the authoritative
# signal), and the sentinel makes every downstream `git -C`/`cd`/`mkdir` at an unguarded
# call site fail closed (ENOTDIR) on its own. An unguarded site's *subsequent* assertions
# may then go RED too (their setup didn't run) — that secondary cascade is harmless extra
# RED, never a real-repo mutation, and is the deliberate trade for keeping each call-site
# conversion a one-line change rather than wrapping every fixture in a guard. (`rgb_scan`
# guards explicitly only because it also needs to branch on `git init` success and clean
# up its dir; that extra guard is about cleanup, not safety.)
#
# Dependency: like assert_eq / probe_tmp, the failure path writes the FAIL via
# `echo FAIL >> "$RESULTS_FILE"`, so callers must have RESULTS_FILE in scope — it is set
# globally (the suite tally file) and never unset, so every call site qualifies. The AC3
# probes deliberately override it per-call (`RESULTS_FILE=… git_sandbox …`) to divert the
# intentional FAIL into an isolated file; that is the only supported reason to rebind it.
git_sandbox() {  # assertion-name -> prints an isolated temp dir (rc 0); on mktemp -d
                 # failure records a suite FAIL, prints the breadcrumb to stderr, and
                 # prints the /dev/null-rooted sentinel (rc 1) so a downstream
                 # git -C / cd / mkdir fails CLOSED rather than hitting the real repo
  local d
  d="$(mktemp -d)" && [ -n "$d" ] && [ -d "$d" ] && { printf '%s\n' "$d"; return 0; }
  echo FAIL >> "$RESULTS_FILE"
  printf '  FAIL  %s — mktemp -d failed (git sandbox unavailable; git work aborted, not run in the real repo)\n' "$1" >&2
  printf '/dev/null/devflow-git-sandbox-unavailable\n'
  return 1
}
# ────────────────────────────────────────────────────────────────────────────
echo "git_sandbox (test-isolation guard for git-mutating tests)"
# ────────────────────────────────────────────────────────────────────────────
# AC3 (#161): with `mktemp -d` forced to fail, git_sandbox must (a) record a suite FAIL
# (RED, not a vacuous pass) and (b) hand back a sentinel that fails EVERY downstream
# git / cd / mkdir CLOSED, so a git-mutating test produces ZERO commits, branch changes,
# or working-tree mutations in the REAL repo. Mutation-proven: shadow `mktemp` to fail
# inside a subshell, drive git_sandbox plus a representative `git init` + `commit`
# (both the `git -C "$DIR"` and the `( cd "$DIR" && git … )` idioms) through it, and
# assert the real repo is byte-for-byte unchanged. The recorded FAIL is diverted to an
# ISOLATED results file (like probe_assert) so this intentional RED is not added to the
# suite tally; a SEPARATE assert_eq then confirms that FAIL was recorded.
GS_REPO_ROOT="$(cd "$LIB/.." && pwd)"
GS_STATUS_BEFORE="$(git -C "$GS_REPO_ROOT" status --porcelain 2>/dev/null)"
GS_HEAD_BEFORE="$(git -C "$GS_REPO_ROOT" rev-parse HEAD 2>/dev/null)"
GS_COUNT_BEFORE="$(git -C "$GS_REPO_ROOT" rev-list --count HEAD 2>/dev/null)"
GS_PROBE="$(mktemp)"   # real mktemp, captured BEFORE the shadow below
(
  mktemp() { return 1; }            # shadow mktemp (incl. `mktemp -d`) for this subshell only
  RESULTS_FILE="$GS_PROBE"          # divert git_sandbox's recorded FAIL away from the suite tally
  d="$(git_sandbox "AC3 forced-mktemp-fail proof")"   # records FAIL to $GS_PROBE, returns the sentinel
  # Representative git-mutating sequence a real test would run — every one must fail
  # CLOSED on the sentinel (ENOTDIR), touching nothing in the real repo:
  git -C "$d" init -q 2>/dev/null
  git -C "$d" -c user.email=t@t -c user.name=t commit --allow-empty -qm "leak attempt (git -C)" 2>/dev/null
  ( cd "$d" 2>/dev/null && git init -q && git -c user.email=t@t -c user.name=t commit --allow-empty -qm "leak attempt (cd)" ) 2>/dev/null
  mkdir -p "$d/.devflow/tmp" 2>/dev/null
) 2>/dev/null
assert_eq "#161 git_sandbox: forced mktemp failure records a suite FAIL (RED, not vacuous)" \
  "FAIL" "$(tail -n 1 "$GS_PROBE")"
rm -f "$GS_PROBE"
assert_eq "#161 git_sandbox: forced mktemp failure leaves the real-repo working tree unchanged" \
  "$GS_STATUS_BEFORE" "$(git -C "$GS_REPO_ROOT" status --porcelain 2>/dev/null)"
assert_eq "#161 git_sandbox: forced mktemp failure leaves the real-repo HEAD unchanged" \
  "$GS_HEAD_BEFORE" "$(git -C "$GS_REPO_ROOT" rev-parse HEAD 2>/dev/null)"
assert_eq "#161 git_sandbox: forced mktemp failure adds no commit to the real repo" \
  "$GS_COUNT_BEFORE" "$(git -C "$GS_REPO_ROOT" rev-list --count HEAD 2>/dev/null)"
# Pin the fail-closed CONTRACT directly at the helper boundary (not only via the absence
# of a downstream mutation above): for each of the three BAD `mktemp -d` outcomes the guard
# `d="$(mktemp -d)" && [ -n "$d" ] && [ -d "$d" ]` must reject, the helper must (a) return a
# /dev/null-rooted sentinel and (b) record a suite FAIL. Drive git_sandbox under three
# `mktemp` shadows, one per bad outcome:
#   1. rc≠0            — mktemp itself failed
#   2. rc 0, empty out — the set-u-without-set-e empty-var hazard (the bug this whole change targets)
#   3. rc 0, non-dir   — mktemp printed a path that is not a directory
# These pin the rejection BEHAVIOR, not a specific operator. `[ -n "$d" ]` is belt-and-
# suspenders redundant with `[ -d "$d" ]` here (`[ -d "" ]` is already false), kept only to
# match the file's established `[ -n ] && [ -d ]` fail-closed idiom. Verified mutation
# sensitivity of the resulting arms: dropping `[ -d "$d" ]` turns the non-directory arm RED;
# dropping BOTH guards additionally turns the empty-output arm RED; dropping `[ -n "$d" ]`
# alone turns NO arm RED (it is fully subsumed by `[ -d ]`). So no arm isolates `[ -n ]` —
# the arms guard the observable contract (a bad mktemp output is rejected), which is what
# matters, not the identity of the operator that rejects it. The probes capture only the return value
# (no git ops), so they cannot mutate anything regardless of outcome, and git_sandbox's
# intentional breadcrumb is suppressed (`2>/dev/null`) so a passing run leaves a clean
# stderr — matching the forced-fail proof block above, whose breadcrumb is likewise hidden.
# The non-directory shadow emits `/dev/null` itself: a guaranteed non-directory (char device)
# that does NOT match the `/dev/null/*` sentinel glob, so BOTH its assertions stay non-vacuous
# when `[ -d ]` is dropped (the helper would then echo `/dev/null` → sentinel-shape RED → and
# return 0 without recording FAIL → FAIL-recorded RED).
for GS_ARM in "rc-nonzero:mktemp() { return 1; }" \
              "empty-output:mktemp() { printf '\\n'; return 0; }" \
              "non-directory:mktemp() { printf '/dev/null\\n'; return 0; }"; do
  GS_ARM_NAME="${GS_ARM%%:*}"; GS_ARM_SHADOW="${GS_ARM#*:}"
  GS_ARM_PROBE="$(mktemp)"
  GS_ARM_OUT="$( eval "$GS_ARM_SHADOW"; RESULTS_FILE="$GS_ARM_PROBE" git_sandbox "AC3 ${GS_ARM_NAME} arm" 2>/dev/null )"
  GS_ARM_VERDICT=no
  case "$GS_ARM_OUT" in /dev/null/*) GS_ARM_VERDICT=yes ;; esac
  assert_eq "#161 git_sandbox: ${GS_ARM_NAME} arm returns a /dev/null-rooted sentinel (fail-closed)" \
    "yes" "$GS_ARM_VERDICT"
  assert_eq "#161 git_sandbox: ${GS_ARM_NAME} arm records the suite FAIL" \
    "FAIL" "$(tail -n 1 "$GS_ARM_PROBE")"
  rm -f "$GS_ARM_PROBE"
done
# Happy path: a normal call returns a real, isolated directory that is NEITHER the sentinel
# NOR the repo root. The repo-root check is the success-side twin of the sentinel pin: it
# catches a regression where git_sandbox echoed `.` / "" on the SUCCESS path, which `[ -d ]`
# alone would accept and silently resolve to the real repo (a git-mutating caller would then
# hit the real branch on a *passing* suite).
GS_OK_DIR="$(git_sandbox "#161 git_sandbox happy-path")"
GS_OK_VERDICT=no
if [ -d "$GS_OK_DIR" ]; then
  case "$GS_OK_DIR" in
    /dev/null/*) ;;
    *) [ "$(cd "$GS_OK_DIR" && pwd)" != "$GS_REPO_ROOT" ] && GS_OK_VERDICT=yes ;;
  esac
fi
assert_eq "#161 git_sandbox: a normal call returns a real isolated dir (not the sentinel, not the repo root)" \
  "yes" "$GS_OK_VERDICT"
[ -d "$GS_OK_DIR" ] && rm -rf "$GS_OK_DIR"
# ────────────────────────────────────────────────────────────────────────────
echo "classify-pr-kind.jq"
# ────────────────────────────────────────────────────────────────────────────

classify() {  # branch watched [impl_prefix] [labels-json] [closing-json]
  jq -nr --arg branch "$1" --argjson watched "$2" --arg impl_prefix "${3:-claude/}" \
    --argjson labels "${4:-[]}" --argjson closing "${5:-[]}" \
    -f "$LIB/classify-pr-kind.jq"
}

assert_eq "claude/ branch is implementation" \
  "implementation" \
  "$(classify "claude/issue-123-fix-thing" "true")"

# #152: the audit-intervention path is pruned. A devflow/audit-* branch is no
# longer special-cased — it classifies like any other branch (implementation iff
# it carries the DevFlow label or closes an issue; otherwise skip).
assert_eq "#152: devflow/audit- branch is no longer audit-intervention (no label → skip)" \
  "skip" \
  "$(classify "devflow/audit-foo-2026-05-01-abc1234" "true")"
assert_eq "#152: DevFlow-labelled devflow/audit- branch is implementation" \
  "implementation" \
  "$(classify "devflow/audit-foo-2026-05-01-abc1234" "true" "claude/" '[{"name":"DevFlow"}]' '[]')"

assert_eq "claude/ branch with watched=false is skip" \
  "skip" \
  "$(classify "claude/issue-123-fix-thing" "false")"

assert_eq "devflow/learnings- branch is skip" \
  "skip" \
  "$(classify "devflow/learnings-2026-W18" "true")"

# #97: classifier mirrors scan's union predicate so scan-selected PRs are not
# dropped at fetch. A DevFlow-labelled PR on a non-prefix branch → implementation.
assert_eq "#97 classify: DevFlow-label PR on issue-* branch is implementation" \
  "implementation" \
  "$(classify "issue-97-foo" "true" "claude/" '[{"name":"DevFlow"}]' '[]')"
# A watched-author PR that closes an issue, on a non-prefix branch → implementation.
assert_eq "#97 classify: closes-issue PR on issue-* branch is implementation" \
  "implementation" \
  "$(classify "issue-97-foo" "true" "claude/" '[]' '[{"number":97}]')"
# True negative: no label, closes nothing, branch matches no prefix → skip.
assert_eq "#97 classify: no label/closes/prefix → skip" \
  "skip" \
  "$(classify "issue-97-foo" "true" "claude/" '[]' '[]')"
# Empty prefix must NOT match-all: an unrelated branch with no label/closes → skip.
assert_eq "#97 classify: empty prefix is not match-all (unrelated branch → skip)" \
  "skip" \
  "$(classify "feature/unrelated" "true" "" '[]' '[]')"
# Empty prefix still honors the closes-issue path → implementation.
assert_eq "#97 classify: empty prefix still selects via closes-issue" \
  "implementation" \
  "$(classify "issue-97-foo" "true" "" '[]' '[{"number":97}]')"
# #152: a devflow/audit-* branch with watched=false and no label/closes → skip
# (the pruned audit arm no longer forces it onto a retrospected path).
assert_eq "#152 classify: audit branch with watched=false and no label/closes is skip" \
  "skip" \
  "$(classify "devflow/audit-foo-2026-05-01-abc1234" "false" "claude/" '[]' '[]')"

# ────────────────────────────────────────────────────────────────────────────
echo "compute-patterns.jq"
# ────────────────────────────────────────────────────────────────────────────

cp_run() {
  local entries="$1" overrides="$2"
  printf '%s\n' "$entries" \
  | jq -s --slurpfile overrides <(printf '%s' "$overrides") \
      -f "$LIB/compute-patterns.jq"
}

# Two open occurrences (schema-v2 `categories`) → status "open", count 2,
# and the descriptors of both occurrences are unioned into the pattern view.
RESULT=$(cp_run \
  '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-04-01T00:00:00Z","verdict":"imperfect","categories":["incomplete-edit"],"descriptors":["orphaned fetch in handleEvent"]}
{"schema_version":2,"kind":"implementation","pr":2,"merged_at":"2026-04-10T00:00:00Z","verdict":"imperfect","categories":["incomplete-edit","doc-accuracy"],"descriptors":["stale count not propagated"]}' \
  '{"schema_version":1,"dismissed":{}}')
assert_eq "two open occurrences → status=open" \
  "open" \
  "$(echo "$RESULT" | jq -r '.["incomplete-edit"].status')"
assert_eq "two open occurrences → count=2" \
  "2" \
  "$(echo "$RESULT" | jq -r '.["incomplete-edit"].occurrence_count')"
assert_eq "descriptors unioned across occurrences" \
  "orphaned fetch in handleEvent|stale count not propagated" \
  "$(echo "$RESULT" | jq -r '.["incomplete-edit"].descriptors | sort | join("|")')"
assert_eq "a second category from the same PR forms its own pattern" \
  "1" \
  "$(echo "$RESULT" | jq -r '.["doc-accuracy"].occurrence_count')"

# Legacy schema-v1 `theme_tags` entries still count (the `// .theme_tags`
# fallback in compute-patterns.jq) and slugify the same way as v2 categories,
# so a mixed file (pre- and post-migration entries) Just Works.
RESULT=$(cp_run \
  '{"schema_version":1,"kind":"implementation","pr":1,"merged_at":"2026-04-01T00:00:00Z","verdict":"imperfect","theme_tags":["doc-accuracy"]}
{"schema_version":2,"kind":"implementation","pr":2,"merged_at":"2026-04-10T00:00:00Z","verdict":"imperfect","categories":["doc-accuracy"]}' \
  '{"schema_version":1,"dismissed":{}}')
assert_eq "v1 theme_tags + v2 categories grouped together (count=2)" \
  "2" \
  "$(echo "$RESULT" | jq -r '.["doc-accuracy"].occurrence_count')"

# One occ + later audit fix → status "fixed"
RESULT=$(cp_run \
  '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-04-01T00:00:00Z","verdict":"imperfect","categories":["lenient-verdict"]}
{"schema_version":2,"kind":"audit","pr":2,"merged_at":"2026-04-15T00:00:00Z","fixes_patterns":["lenient-verdict"]}' \
  '{"schema_version":1,"dismissed":{}}')
assert_eq "occ then fix → status=fixed" \
  "fixed" \
  "$(echo "$RESULT" | jq -r '.["lenient-verdict"].status')"

# Successor-slug split (#129): each of the three slugs that replaced the removed
# coarse review/gate slug aggregates as its own pattern, and the removed slug
# never appears.
RESULT=$(cp_run \
  '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-05-01T00:00:00Z","verdict":"imperfect","categories":["outstanding-reject"]}
{"schema_version":2,"kind":"implementation","pr":2,"merged_at":"2026-05-02T00:00:00Z","verdict":"imperfect","categories":["lenient-verdict"]}
{"schema_version":2,"kind":"implementation","pr":3,"merged_at":"2026-05-03T00:00:00Z","verdict":"imperfect","categories":["deferred-verification"]}' \
  '{"schema_version":1,"dismissed":{}}')
assert_eq "split slug outstanding-reject aggregates (count=1)" \
  "1" "$(echo "$RESULT" | jq -r '.["outstanding-reject"].occurrence_count')"
assert_eq "split slug lenient-verdict aggregates (count=1)" \
  "1" "$(echo "$RESULT" | jq -r '.["lenient-verdict"].occurrence_count')"
assert_eq "split slug deferred-verification aggregates (count=1)" \
  "1" "$(echo "$RESULT" | jq -r '.["deferred-verification"].occurrence_count')"
assert_eq "removed split slug never aggregates" \
  "null" "$(echo "$RESULT" | jq -r '.["review-gate" + "-bypass"].occurrence_count')"

# Boundary case: a gate-absent / human-authored PR (no review-related slug) maps to
# NONE of the three successor slugs.
RESULT=$(cp_run \
  '{"schema_version":2,"kind":"implementation","pr":9,"merged_at":"2026-05-09T00:00:00Z","verdict":"imperfect","categories":["other"]}' \
  '{"schema_version":1,"dismissed":{}}')
assert_eq "gate-absent PR → no outstanding-reject pattern" \
  "null" "$(echo "$RESULT" | jq -r '.["outstanding-reject"].occurrence_count')"
assert_eq "gate-absent PR → no lenient-verdict pattern" \
  "null" "$(echo "$RESULT" | jq -r '.["lenient-verdict"].occurrence_count')"
assert_eq "gate-absent PR → no deferred-verification pattern" \
  "null" "$(echo "$RESULT" | jq -r '.["deferred-verification"].occurrence_count')"

# Lockstep guard (#129): NO tracked surface may reference the removed slug, except
# CHANGELOG.md (append-only release history that records it by its then-name). A
# repo-wide `git grep` auto-discovers every tracked surface, so this guard cannot
# drift as vocab surfaces are added/renamed — unlike a hand-maintained path list,
# which had already missed skills/retrospective-weekly/SKILL.md. Scope is git's
# tracked content (working-tree tracked files + staged), so a reintroduction in an
# as-yet-untracked new file is caught only once it is added — acceptable, since the
# retrospective/implement flow commits its surfaces. The pattern is concatenated
# from two literals so this guard itself does not contain the contiguous string
# (which would self-match the git grep).
RGB_PAT="review-gate""-bypass"
# Single scan helper so the live guard AND its fail-closed contract test below
# exercise the SAME rc-handling — not two copies. (An earlier version duplicated the
# rc transform inline in the test, so a refactor of the live guard would have left
# the test green while re-opening the fail-open hole; sharing one helper is what
# actually delivers the refactor-resistance.) It echoes the matching file list on a
# hit (git rc 0), empty on a clean no-match (rc 1 — the PASS case, safe under run.sh's
# `set -u`, not `set -e`), or the fixed sentinel `<rgb-guard-errored>` on a real git
# error (rc >1). `git -C "$root"` keeps git the only rc-bearing command: a failed
# `cd "$root" && git grep` would short-circuit `&&` and leave rc 1 + empty stdout,
# masquerading as a clean no-match and re-opening the fail-open hole one command
# upstream — the very fail-open class this PR exists to close. On error it also prints
# an rc-bearing breadcrumb to stderr so the cause survives independently of assert_eq's
# value-echo (an infra error must not read as a real slug reintroduction).
# rgb_classify is the pure rc→verdict transform, split out from the git call so it
# can be driven against ANY rc — not just the rc=128 a nonexistent path happens to
# produce. It is the single owner of the three-valued contract: empty on a clean
# no-match (git rc 1 — the PASS case, safe under run.sh's `set -u`, not `set -e`),
# the hits string on a match (rc 0), or the fixed sentinel `<rgb-guard-errored>` on
# ANY git error (rc >1). The `-gt 1` threshold — not `-gt 2`, not `== 128` — is what
# makes the smallest error rc (rc 2, distinct from no-match=1; git itself reports
# fatal/usage as 128/129, but the predicate must catch every rc above 1) fail closed;
# the boundary tests below pin that exact threshold so an off-by-one weakening turns
# the suite red. On error it prints an rc-bearing stderr breadcrumb so the cause
# survives independently of assert_eq's value-echo (an infra error must not read as a
# real slug reintroduction).
rgb_classify() {
  local rc="$1" hits="$2"
  if [ "$rc" -gt 1 ]; then
    printf 'devflow: RGB lockstep guard could not run (git rc=%s) — guard did not run\n' "$rc" >&2
    printf '<rgb-guard-errored>'
    return 0
  fi
  printf '%s' "$hits"
}
rgb_scan() {
  local root="$1" hits rc
  # `git -C "$root"` keeps git the only rc-bearing command: a failed
  # `cd "$root" && git grep` would short-circuit `&&` and leave rc 1 + empty stdout,
  # masquerading as a clean no-match and re-opening the fail-open hole one command up.
  hits="$(git -C "$root" grep -lF "$RGB_PAT" -- ':!CHANGELOG.md' 2>/dev/null)"; rc=$?
  rgb_classify "$rc" "$hits"
}
# Live guard: NO tracked surface may reference the removed slug, except CHANGELOG.md
# (append-only release history that records it by its then-name). A repo-wide
# `git grep` auto-discovers every tracked surface, so the guard cannot drift as vocab
# surfaces are added/renamed — unlike a hand-maintained path list, which had already
# missed skills/retrospective-weekly/SKILL.md. Scope is git-tracked content (working-
# tree tracked files + staged), so a reintroduction in an as-yet-untracked new file is
# caught only once it is added — acceptable, since the retrospective/implement flow
# commits its surfaces. RGB_PAT is split into two literals so this file does not
# self-match the grep. A real reintroduction surfaces as the offending file list; an
# infra error surfaces as `<rgb-guard-errored>` — both non-empty, both fail loud.
assert_eq "no tracked surface references the removed split slug (CHANGELOG history excepted)" \
  "" "$(rgb_scan "$LIB/..")"

# Fail-closed contract test (#129): drive the SAME rgb_scan against a non-repo path
# (git -C → rc 128) and assert it returns the exact error sentinel — not empty (a
# silent PASS) and not a mere "non-empty" check (which a stray hit could also satisfy).
# Because both this and the live guard call rgb_scan, reverting to `cd && git grep`
# (the rc-1 masquerade) turns THIS assertion red. The probe path is PID-suffixed so it
# cannot exist; stderr is muted here because the error is deliberate and expected (the
# live guard above keeps stderr visible).
assert_eq "RGB guard fails closed on a git error (returns the error sentinel, not a silent PASS)" \
  "<rgb-guard-errored>" "$(rgb_scan "$LIB/../nonexistent-rgb-probe-$$" 2>/dev/null)"

# Threshold boundary tests (#129): the contract test above only ever exercises rc 128,
# so it pins "an errored git fails closed" but NOT the `-gt 1` THRESHOLD itself — a
# weakening to `-gt 2` (so rc 2 falls through to the PASS path, re-opening fail-open on
# the next git error code above no-match) would leave it green. Drive rgb_classify —
# the same transform the live guard runs through rgb_scan — across every rc class so
# the exact `[rc -gt 1]` predicate is pinned: rc 0 → the hits, rc 1 → empty (PASS), and
# rc 2 (the smallest error rc the threshold must catch) and rc 128 → the sentinel.
# Each row catches a different mutation: a `-gt 2` or `== 128` weakening turns the rc-2
# row red (rc 2 wrongly passes), while an `-ne 1`-style widening turns the rc-0 row red
# (a real hit wrongly classified as an error). rc 2 is a representative >1 value, not a
# code `git grep` necessarily emits (it uses 0/1 for match/no-match and 128/129 for
# fatal/usage); the point is the predicate, not the specific producer code. stderr
# muted: the >1 rows print an expected breadcrumb.
assert_eq "rgb_classify rc=0 (hit) → returns the offending file list" \
  "skills/foo.md" "$(rgb_classify 0 "skills/foo.md" 2>/dev/null)"
assert_eq "rgb_classify rc=1 (clean no-match) → empty (PASS)" \
  "" "$(rgb_classify 1 "" 2>/dev/null)"
assert_eq "rgb_classify rc=2 (smallest error rc) → sentinel (fails closed at the -gt 1 boundary)" \
  "<rgb-guard-errored>" "$(rgb_classify 2 "" 2>/dev/null)"
assert_eq "rgb_classify rc=128 (git fatal) → sentinel (fails closed)" \
  "<rgb-guard-errored>" "$(rgb_classify 128 "" 2>/dev/null)"

# End-to-end reintroduction test (#129): the live guard above only ever observes
# rgb_scan returning empty (the real repo is clean) and the contract test only its
# rc-128 error path — so rgb_scan's OWN `git grep` line (the `hits=…; rc=$?` seam, the
# `-l` flag, the `:!CHANGELOG.md` pathspec) is never seen to produce a real positive
# hit. Drive it end-to-end against a throwaway repo that genuinely contains the slug
# and assert rgb_scan returns the offending filename (rc 0 → non-empty → the live guard
# would fail loud). This pins the one path the unit-level rgb_classify rc=0 row cannot:
# a regression in rgb_scan's git invocation (dropped `-l`, mis-scoped pathspec) that
# silently stops matching. Use the file's own name as the probe so this file does not
# self-match; the slug is assembled from two literals for the same reason.
# Guard the setup so a failed `mktemp -d` can NEVER reach the `> "$RGB_E2E/probe.md"`
# redirect. git_sandbox returns the `/dev/null/…` sentinel (not an empty string) on
# failure and records the suite FAIL itself, so `git -C "$RGB_E2E" init -q` fails closed
# with ENOTDIR and the `&&` short-circuits into the else branch before any redirect runs —
# no stray root-relative `> "/probe.md"` write is even reachable. The else branch records
# only the DISTINCT git-init-failure case (gated on `[ -d ]` so it doesn't double-count the
# mktemp FAIL git_sandbox already logged) and skips the block. Cleanup runs on every
# guarded exit of the block, always gated on `[ -d ]` so the sentinel never reaches `rm -rf`.
if RGB_E2E="$(git_sandbox "rgb_scan e2e setup")" && git -C "$RGB_E2E" init -q; then
  printf 'has the %s%s slug\n' "review-gate" "-bypass" > "$RGB_E2E/probe.md"
  if git -C "$RGB_E2E" add probe.md; then
    assert_eq "rgb_scan reports a real reintroduction in a tracked file (rc 0 → filename)" \
      "probe.md" "$(rgb_scan "$RGB_E2E")"
    # And confirm the CHANGELOG.md pathspec exception genuinely excludes a hit there.
    printf 'historical %s%s reference\n' "review-gate" "-bypass" > "$RGB_E2E/CHANGELOG.md"
    if git -C "$RGB_E2E" add CHANGELOG.md; then
      assert_eq "rgb_scan still flags probe.md but NOT CHANGELOG.md (pathspec exception holds)" \
        "probe.md" "$(rgb_scan "$RGB_E2E")"
    else
      assert_eq "rgb_scan e2e setup (git add CHANGELOG.md)" "ok" "setup failed — git add errored"
    fi
  else
    assert_eq "rgb_scan e2e setup (git add probe.md)" "ok" "setup failed — git add errored"
  fi
  rm -rf "$RGB_E2E"
else
  # git_sandbox already recorded a suite FAIL on an mktemp failure (RGB_E2E is then the
  # /dev/null sentinel, not a directory). Only record the distinct git-init-failure case
  # here — gated on RGB_E2E being a real dir — so a single mktemp failure is not
  # double-counted, and the sentinel never reaches a redirect or `rm -rf`.
  [ -d "${RGB_E2E:-}" ] && assert_eq "rgb_scan e2e setup (git init)" "ok" "setup failed — git init errored"
  [ -d "${RGB_E2E:-}" ] && rm -rf "$RGB_E2E"
fi

# Fix then later occ → status "regressed"
RESULT=$(cp_run \
  '{"schema_version":2,"kind":"audit","pr":1,"merged_at":"2026-04-01T00:00:00Z","fixes_patterns":["convention-violation"]}
{"schema_version":2,"kind":"implementation","pr":2,"merged_at":"2026-04-15T00:00:00Z","verdict":"imperfect","categories":["convention-violation"]}' \
  '{"schema_version":1,"dismissed":{}}')
assert_eq "fix then occ → status=regressed" \
  "regressed" \
  "$(echo "$RESULT" | jq -r '.["convention-violation"].status')"

# Override → status "dismissed"
RESULT=$(cp_run \
  '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-04-01T00:00:00Z","verdict":"imperfect","categories":["tooling-gap"]}' \
  '{"schema_version":1,"dismissed":{"tooling-gap":{"reason":"meta-plugin-issue"}}}')
assert_eq "override → status=dismissed" \
  "dismissed" \
  "$(echo "$RESULT" | jq -r '.["tooling-gap"].status')"

# verdict:"blocked" entries also count as occurrences (alongside "imperfect").
# A simplification of the filter to drop "blocked" would silently make the
# whole "Blocked" workpad-status branch invisible to the audit.
RESULT=$(cp_run \
  '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-04-01T00:00:00Z","verdict":"blocked","categories":["unmet-acceptance-criteria"]}' \
  '{"schema_version":1,"dismissed":{}}')
assert_eq "blocked verdict counts as occurrence" \
  "1" \
  "$(echo "$RESULT" | jq -r '.["unmet-acceptance-criteria"].occurrence_count')"

# Slug normalization is still applied defensively: a legacy mixed-case
# theme_tag slugifies to lowercase and matches a lowercase fixes_pattern.
RESULT=$(cp_run \
  '{"schema_version":1,"kind":"implementation","pr":1,"merged_at":"2026-04-01T00:00:00Z","verdict":"imperfect","theme_tags":["Foo-Bar-IN-Clause"]}
{"schema_version":2,"kind":"audit","pr":2,"merged_at":"2026-04-15T00:00:00Z","fixes_patterns":["foo-bar-in-clause"]}' \
  '{"schema_version":1,"dismissed":{}}')
assert_eq "slug normalization: mixed-case theme_tag matched by lowercase fixes_pattern → fixed" \
  "fixed" \
  "$(echo "$RESULT" | jq -r '.["foo-bar-in-clause"].status')"

# Missing merged_at MUST NOT contaminate first_seen/last_seen.
# An entry with no merged_at should be excluded from occurrences.
RESULT=$(cp_run \
  '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-04-15T00:00:00Z","verdict":"imperfect","categories":["other"]}
{"schema_version":2,"kind":"implementation","pr":2,"verdict":"imperfect","categories":["other"]}' \
  '{"schema_version":1,"dismissed":{}}')
assert_eq "missing merged_at filtered out (count=1)" \
  "1" \
  "$(echo "$RESULT" | jq -r '.["other"].occurrence_count')"
assert_eq "missing merged_at does not poison first_seen" \
  "2026-04-15T00:00:00Z" \
  "$(echo "$RESULT" | jq -r '.["other"].first_seen')"

# ────────────────────────────────────────────────────────────────────────────
echo "config-get.sh (resolver, direct)"
# ────────────────────────────────────────────────────────────────────────────
# The resolver is the single config-reading implementation (config-source.sh, workpad.py,
# match-deferrals.py all delegate to it), so its contract is tested directly here
# — config-source.sh's tests below can't observe exit codes (it swallows them by design).
CG="$LIB/../scripts/config-get.sh"
FIX="$LIB/test/fixtures/config.json"

assert_eq "cg: present scalar"          "claude,example-bot" "$("$CG" .devflow.allowed_bots '' "$FIX")"
assert_eq "cg: nested int"              "2"                   "$("$CG" .devflow_retrospective.min_occurrences '' "$FIX")"
assert_eq "cg: array → comma-join"      "claude,example-bot" "$("$CG" .devflow_retrospective.watched_authors '' "$FIX")"
assert_eq "cg: leading dot optional"    "2"                   "$("$CG" devflow_retrospective.min_occurrences '' "$FIX")"
assert_eq "cg: missing key → default"   "fallback"           "$("$CG" .a.b.c fallback "$FIX")"
assert_eq "cg: descend into scalar → default" "dfl"          "$("$CG" .devflow.allowed_bots.nope dfl "$FIX")"
assert_eq "cg: missing file → default"  "dfl"                "$("$CG" .x dfl /no/such/config.json)"

# Exit-code contract (run.sh uses `set -u`, not `set -e`, so a nonzero is safe).
"$CG" .a.b.c '' "$FIX" >/dev/null 2>&1
assert_eq "cg: missing key + empty default → exit 0" "0" "$?"
# Run from an empty cwd so the default config path is deterministically absent
# (don't couple this to the repo's live .devflow/config.json being valid JSON).
( cd "$(mktemp -d)" && "$CG" .nope.nope >/dev/null 2>&1 )
assert_eq "cg: missing key/file + no default → exit 1" "1" "$?"
"$CG" "" >/dev/null 2>&1
assert_eq "cg: empty KEY → exit 2" "2" "$?"
CG_BAD="$(mktemp)"; printf '{ not valid json' > "$CG_BAD"
"$CG" .a fallback "$CG_BAD" >/dev/null 2>&1
assert_eq "cg: invalid JSON → exit 2" "2" "$?"
rm -f "$CG_BAD"

# node-absent path (issue #220): the resolver now reads config with python3, not
# node. Prove it resolves correctly with `node` OFF PATH (python3 present) — the
# Codex/WSL non-Node-host case the change targets. A curated bin dir holds only
# what config-get.sh needs to run (its `#!/usr/bin/env bash` shebang → env + bash,
# plus python3); node is deliberately omitted. PATH is set per-invocation so the
# mutation can't leak into later assertions (run.sh uses set -u, not set -e).
CG_NABIN="$(mktemp -d)/bin"; mkdir -p "$CG_NABIN"
for _c in env bash python3 mktemp; do
  _p="$(command -v "$_c")" && ln -sf "$_p" "$CG_NABIN/$_c"
done
# Guard: the sandbox must genuinely LACK node, else these assertions prove nothing.
assert_eq "cg(node-absent): node is off the sandbox PATH" "yes" \
  "$(PATH="$CG_NABIN" command -v node >/dev/null 2>&1 && echo no || echo yes)"
assert_eq "cg(node-absent): present scalar resolves" "claude,example-bot" \
  "$(PATH="$CG_NABIN" "$CG" .devflow.allowed_bots '' "$FIX")"
assert_eq "cg(node-absent): array → comma-join resolves" "claude,example-bot" \
  "$(PATH="$CG_NABIN" "$CG" .devflow_retrospective.watched_authors '' "$FIX")"
assert_eq "cg(node-absent): nested int resolves" "2" \
  "$(PATH="$CG_NABIN" "$CG" .devflow_retrospective.min_occurrences '' "$FIX")"
# Boolean PARITY — the one place a python backend could diverge from node: emit
# lowercase true/false, NOT Python's True/False. This gets its own named assertion.
assert_eq "cg(node-absent): boolean emits lowercase 'true' (parity, not Python 'True')" "true" \
  "$(PATH="$CG_NABIN" "$CG" .devflow_retrospective.enabled '' "$FIX")"
assert_eq "cg(node-absent): missing key → default applied" "dfl" \
  "$(PATH="$CG_NABIN" "$CG" .a.b.c dfl "$FIX")"

# python3-absent (symmetric with the old node-absent behavior): exit 2 with a
# python3-specific breadcrumb. config-source.sh's rc==2 handling (below) then
# surfaces it as a ::warning:: and falls back to the default (AC: python3 absent).
CG_PYBIN="$(mktemp -d)/bin"; mkdir -p "$CG_PYBIN"
for _c in env bash mktemp; do
  _p="$(command -v "$_c")" && ln -sf "$_p" "$CG_PYBIN/$_c"   # python3 deliberately omitted
done
CG_PYERR="$(mktemp)"
PATH="$CG_PYBIN" "$CG" .x dfl "$FIX" >/dev/null 2>"$CG_PYERR"
assert_eq "cg(python3-absent): exits 2" "2" "$?"
assert_eq "cg(python3-absent): python3-specific breadcrumb on stderr" "yes" \
  "$(grep -qF "'python3' is required" "$CG_PYERR" && echo yes || echo no)"
rm -f "$CG_PYERR"

# coerce() parity on the python3 backend (issue #220): the hand-written coerce()
# reproduces node String()/Array.join byte-for-byte. The shared fixture has no null,
# no object value, and only string arrays, so exercise the divergence-prone arms with
# an inline config rather than mutating the fixture (which other tests read). Each
# expected value is what node's String()/Array.prototype.join produced.
CG_COERCE="$(mktemp)"
printf '%s' '{"arr":["a",true,2,null,["x","y"],{}],"nul":null,"obj":{"k":1},"flag":false,"num":7}' > "$CG_COERCE"
# Array of mixed element types — coerce() recurses per element: bool→true, null→"",
# nested array→comma-joined, object→[object Object]. Matches JS [..].join(",").
assert_eq "cg(coerce): mixed array joins with node element-coercion parity" "a,true,2,,x,y,[object Object]" \
  "$("$CG" .arr '' "$CG_COERCE")"
# Boolean INSIDE an array emits lowercase (not Python True) — the array-recursion parity.
# Top-level boolean false → lowercase 'false'.
assert_eq "cg(coerce): top-level boolean false → lowercase" "false" \
  "$("$CG" .flag '' "$CG_COERCE")"
# A dot-path terminating on an OBJECT → '[object Object]' — load-bearing: scripts/
# resolve-review-overrides.py keys on this exact literal (_OBJECT_SENTINEL) to tell a
# present-but-empty object apart from a scalar/array. Parity here keeps that consumer working.
assert_eq "cg(coerce): object value → [object Object] sentinel (resolve-review-overrides consumer)" "[object Object]" \
  "$("$CG" .obj '' "$CG_COERCE")"
assert_eq "cg(coerce): nested scalar under an object resolves" "1" \
  "$("$CG" .obj.k '' "$CG_COERCE")"
# null value → empty → default applied (the coerce None arm + the cur-is-None exit).
assert_eq "cg(coerce): explicit null value → default applied" "dfl" \
  "$("$CG" .nul dfl "$CG_COERCE")"
# Descend INTO an array element (non-dict intermediate) → empty → default. The python
# 'not isinstance(cur, dict)' mirrors node's Array.isArray short-circuit.
assert_eq "cg(coerce): descend into array intermediate → default" "dfl" \
  "$("$CG" .arr.0 dfl "$CG_COERCE")"
assert_eq "cg(coerce): bare numeric → digits" "7" \
  "$("$CG" .num '' "$CG_COERCE")"
# Malformed JSON → exit 2 WITH a non-empty 'config-get.sh:' breadcrumb on stderr (AC4;
# the pre-existing exit-2 test asserts only the code, not the python-backend breadcrumb).
CG_PARSEERR="$(mktemp)"
printf '%s' '{ not valid json' > "$CG_COERCE"
"$CG" .a fallback "$CG_COERCE" >/dev/null 2>"$CG_PARSEERR"
assert_eq "cg(coerce): malformed JSON breadcrumb on stderr (python backend)" "yes" \
  "$(grep -qF 'config-get.sh:' "$CG_PARSEERR" && echo yes || echo no)"
rm -f "$CG_COERCE" "$CG_PARSEERR"

# ────────────────────────────────────────────────────────────────────────────
echo "deferred.labels (schema + example + resolution + normalization)"
# ────────────────────────────────────────────────────────────────────────────
# /devflow:implement applies deferred.labels (default DevFlow,Deferred) to the
# follow-up issues it files in Phase 4.0 (deferred ACs) and Phase 4.0.5 (deferred
# review findings). The value is read via config-get.sh and normalized with the same
# split/trim/drop-empties idiom Phase 4.1 uses for docs.labels (issue #118). Pin (a)
# the schema/example contract, (b) the resolver read, (c) the normalization logic via
# a function kept byte-aligned with the SKILL block, and (d) drift guards on the SKILL.
DEF_SCHEMA="$LIB/../.devflow/config.schema.json"
DEF_EXAMPLE="$LIB/../.devflow/config.example.json"
DEF_PROP='.properties.deferred.properties.labels'
assert_eq "deferred.labels: schema type is string" "string" \
  "$(jq -r "$DEF_PROP.type" "$DEF_SCHEMA")"
assert_eq "deferred.labels: schema default is DevFlow,Deferred" "DevFlow,Deferred" \
  "$(jq -r "$DEF_PROP.default" "$DEF_SCHEMA")"
assert_eq "deferred.labels: schema has a non-empty description" "yes" \
  "$(jq -e "$DEF_PROP.description | type == \"string\" and (length > 0)" "$DEF_SCHEMA" >/dev/null && echo yes || echo no)"
assert_eq "deferred.labels: example value matches schema default" \
  "$(jq -r "$DEF_PROP.default" "$DEF_SCHEMA")" \
  "$(jq -r '.deferred.labels' "$DEF_EXAMPLE")"

# Resolver-read behavior (the string the SKILL's Phase 4.0/4.0.5 read).
DEF_CFG="$(mktemp)"
printf '%s' '{"deferred":{"labels":"A,B,C"}}' > "$DEF_CFG"
assert_eq "deferred.labels: configured value read back verbatim" "A,B,C" \
  "$("$CG" .deferred.labels DevFlow,Deferred "$DEF_CFG")"
printf '%s' '{}' > "$DEF_CFG"
assert_eq "deferred.labels: unset key → resolver default DevFlow,Deferred" "DevFlow,Deferred" \
  "$("$CG" .deferred.labels DevFlow,Deferred "$DEF_CFG")"
assert_eq "deferred.labels: missing config file → resolver default DevFlow,Deferred" "DevFlow,Deferred" \
  "$("$CG" .deferred.labels DevFlow,Deferred /no/such/config.json)"
rm -f "$DEF_CFG"

# The SKILL's inline normalization, applied to the resolver output above. Mirrors the
# exact idiom in the implement skill's Phase 4.0/4.0.5 (phases/phase-4-documentation.md;
# and Phase 4.1 docs.labels)
# so the trim / drop-empties / empty-value ACs are exercised, not just asserted in
# prose. Keep byte-aligned with the SKILL block.
deferred_labels_normalize() {
  echo "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | paste -sd, -
}
assert_eq "deferred.labels normalize: default passed through"        "DevFlow,Deferred" "$(deferred_labels_normalize 'DevFlow,Deferred')"
assert_eq "deferred.labels normalize: trims interior spaces"         "DevFlow,Deferred" "$(deferred_labels_normalize 'DevFlow, Deferred')"
assert_eq "deferred.labels normalize: single label"                  "DevFlow"          "$(deferred_labels_normalize 'DevFlow')"
assert_eq "deferred.labels normalize: drops empty entries"           "A,B"              "$(deferred_labels_normalize 'A, ,B,')"
assert_eq "deferred.labels normalize: whitespace-only → empty (no labels)" ""           "$(deferred_labels_normalize ' , ')"
assert_eq "deferred.labels normalize: empty string → empty (no labels)"    ""           "$(deferred_labels_normalize '')"

# Drift guards: the label-resolution/apply bash is prompt markdown (not a script), so a
# SKILL edit could silently drop it. Pin the load-bearing tokens in the real SKILL so a
# regression fails here instead of shipping deferred issues unlabeled.
# issue #218: search the whole implement-skill bundle (orchestrator + phase files), not
# a single file — the deferred.labels idiom these guards pin lives in the Phase 4.0/4.0.5
# detail that relocated to phases/phase-4-documentation.md.
DEF_SKILL="$IMPL_SKILL_BUNDLE"
assert_eq "deferred.labels: SKILL reads via config-get with the DevFlow,Deferred default" "yes" \
  "$(grep -qF 'config-get.sh .deferred.labels DevFlow,Deferred' "$DEF_SKILL" && echo yes || echo no)"  # raw-guard-ok: non-unique: token appears in BOTH deferral channels (4.0+4.0.5)
assert_eq "deferred.labels: SKILL ensures each label exists before applying" "yes" \
  "$(grep -qF 'ensure-label.sh "$lbl"' "$DEF_SKILL" && echo yes || echo no)"  # raw-guard-ok: non-unique: token appears in BOTH deferral channels (4.0+4.0.5)
assert_eq "deferred.labels: SKILL applies labels via best-effort REST apply-labels.sh helper" "yes" \
  "$(grep -qF 'apply-labels.sh "$n" "$CLEAN_DEFERRED_LABELS"' "$DEF_SKILL" && echo yes || echo no)"  # raw-guard-ok: non-unique: token appears in BOTH deferral channels (4.0+4.0.5)
# Both deferral channels must label: Phase 4.0 (no longer "add no --label") and Phase
# 4.0.5. Require the resolution token to appear at least twice (once per channel).
assert_eq "deferred.labels: SKILL resolves the labels in BOTH deferral channels (4.0 + 4.0.5)" "yes" \
  "$([ "$(grep -cF 'config-get.sh .deferred.labels DevFlow,Deferred' "$DEF_SKILL")" -ge 2 ] && echo yes || echo no)"  # raw-guard-ok: count-based: asserts >=2 occurrences (both channels), not single-presence
assert_eq "deferred.labels: SKILL Phase 4.0 no longer instructs 'add no --label' as a maintainer task" "no" \
  "$(grep -qF 'add **no** `--label` (labeling is handled separately by maintainers)' "$DEF_SKILL" && echo yes || echo no)"  # raw-guard-ok: absence pin: asserts the removed 'add no --label' instruction is GONE (expected no)
# Pin the normalization pipeline itself (not just the read/ensure/apply tokens): the
# deferred_labels_normalize() helper above is a hand-copied replica, so without this pin a
# SKILL edit to the trim/drop-empties pipeline would drift silently while the replica
# keeps passing. Scope the count to the DEFERRED assignment (`CLEAN_DEFERRED_LABELS=$(echo
# "$DEFERRED_LABELS" | …`) so it is deferred-unique — the identical pipeline also appears on
# the Phase 4.1 docs.labels line (CLEAN_LABELS / DOCS_LABELS), so a bare pipeline count would
# read 3 and a `>= 2` threshold would still pass if ONE deferred channel lost it. Both
# channels (4.0 + 4.0.5) must carry the exact deferred pipeline → require EXACTLY 2.
assert_eq "deferred.labels: SKILL keeps the exact normalization pipeline in BOTH channels" "yes" \
  "$([ "$(grep -cF 'CLEAN_DEFERRED_LABELS=$(echo "$DEFERRED_LABELS" | tr '"'"','"'"' '"'"'\n'"'"' | sed '"'"'s/^[[:space:]]*//; s/[[:space:]]*$//'"'"' | grep -v '"'"'^$'"'"' | paste -sd, -)' "$DEF_SKILL")" -eq 2 ] && echo yes || echo no)"  # raw-guard-ok: count-based: asserts ==2 occurrences (both channels), not single-presence
# Pin the rc-capture: a hard config-get read failure must be attributable, not silently
# collapsed into the deliberately-empty-value path. The if-condition idiom keeps the
# capture alive under set -e.
assert_eq "deferred.labels: SKILL captures config-get rc (read-failure breadcrumb, set-e-safe)" "yes" \
  "$(grep -qF 'then DEFERRED_LABELS_RC=0; else DEFERRED_LABELS_RC=$?; fi' "$DEF_SKILL" && echo yes || echo no)"  # raw-guard-ok: non-unique: token appears in BOTH deferral channels (4.0+4.0.5)
# Pin the durable (workpad) breadcrumb on a failed label application — the feature's most
# likely real-world failure must not be stderr-only (ephemeral in autonomous cloud runs).
assert_eq "deferred.labels: SKILL routes a failed label-apply to a durable workpad reflection" "yes" \
  "$(grep -qF 'could not apply the configured deferred labels' "$DEF_SKILL" && echo yes || echo no)"  # raw-guard-ok: non-unique: token appears in BOTH deferral channels (4.0+4.0.5)
# Pin the Phase 4.0 empty-numbers breadcrumb (the anti-silent-failure branch that fires
# when deferred work was filed but no issue numbers were captured).
assert_pin_unique "deferred.labels: SKILL Phase 4.0 surfaces an empty-issue-numbers capture" 'captured no issue numbers' "$DEF_SKILL"

# ────────────────────────────────────────────────────────────────────────────
echo "devflow_review_and_fix.max_iterations (schema + resolution)"
# ────────────────────────────────────────────────────────────────────────────
# The /devflow:review-and-fix fix-loop cap is read from config via config-get.sh
# (default 5) and then clamped INLINE in skills/review-and-fix/SKILL.md: a value
# below 1 → floor 1, a non-integer/empty/unparseable value (or a resolver failure)
# → 5, with no upper bound. The clamp itself is prompt bash (not a script — AC3
# mandates the SKILL read directly via config-get.sh), so we pin (a) the
# schema/example contract, (b) the resolver read behavior that feeds the clamp,
# and (c) the clamp logic via a function kept byte-aligned with the SKILL block.
MAXI_SCHEMA="$LIB/../.devflow/config.schema.json"
MAXI_EXAMPLE="$LIB/../.devflow/config.example.json"
MAXI_PROP='.properties.devflow_review_and_fix.properties.max_iterations'
assert_eq "max_iterations: schema type is integer" "integer" \
  "$(jq -r "$MAXI_PROP.type" "$MAXI_SCHEMA")"
assert_eq "max_iterations: schema minimum is 1" "1" \
  "$(jq -r "$MAXI_PROP.minimum" "$MAXI_SCHEMA")"
assert_eq "max_iterations: schema default is 5" "5" \
  "$(jq -r "$MAXI_PROP.default" "$MAXI_SCHEMA")"
assert_eq "max_iterations: schema has a non-empty description" "yes" \
  "$(jq -e "$MAXI_PROP.description | type == \"string\" and (length > 0)" "$MAXI_SCHEMA" >/dev/null && echo yes || echo no)"
assert_eq "max_iterations: example value matches schema default" \
  "$(jq -r "$MAXI_PROP.default" "$MAXI_SCHEMA")" \
  "$(jq -r '.devflow_review_and_fix.max_iterations' "$MAXI_EXAMPLE")"

# Resolver-read behavior (the part the SKILL invokes; the clamp is downstream).
MAXI_CFG="$(mktemp)"
printf '%s' '{"devflow_review_and_fix":{"max_iterations":9}}' > "$MAXI_CFG"
assert_eq "max_iterations: configured integer read back verbatim" "9" \
  "$("$CG" .devflow_review_and_fix.max_iterations 5 "$MAXI_CFG")"
# Key absent → resolver emits the default 5 (the no-config / unset case; AC: default 5).
printf '%s' '{"devflow_review_and_fix":{}}' > "$MAXI_CFG"
assert_eq "max_iterations: unset key → resolver default 5" "5" \
  "$("$CG" .devflow_review_and_fix.max_iterations 5 "$MAXI_CFG")"
assert_eq "max_iterations: missing config file → resolver default 5" "5" \
  "$("$CG" .devflow_review_and_fix.max_iterations 5 /no/such/config.json)"
# A below-floor value (0) and a non-integer ("abc") are passed through verbatim by
# the resolver — the SKILL's inline clamp turns these into 1 and 5 respectively.
printf '%s' '{"devflow_review_and_fix":{"max_iterations":0}}' > "$MAXI_CFG"
assert_eq "max_iterations: below-floor value passed through to clamp (0)" "0" \
  "$("$CG" .devflow_review_and_fix.max_iterations 5 "$MAXI_CFG")"
printf '%s' '{"devflow_review_and_fix":{"max_iterations":"abc"}}' > "$MAXI_CFG"
assert_eq "max_iterations: non-integer value passed through to clamp (abc)" "abc" \
  "$("$CG" .devflow_review_and_fix.max_iterations 5 "$MAXI_CFG")"
rm -f "$MAXI_CFG"

# The SKILL's inline clamp, applied to the resolver output above. Mirrors the exact
# logic in skills/review-and-fix/SKILL.md so the floor/fallback/no-upper-bound ACs
# are exercised, not just asserted in prose. Keep byte-aligned with the SKILL block.
maxi_clamp() {
  local v="$1" rc="${2:-0}"
  if [ "$rc" -ne 0 ] || ! printf '%s' "$v" | grep -Eq '^-?[0-9]+$'; then
    printf '5\n'
  elif [ "$v" -lt 1 ]; then
    printf '1\n'
  else
    printf '%s\n' "$v"
  fi
}
assert_eq "max_iterations clamp: valid value honored"          "9"  "$(maxi_clamp 9)"
assert_eq "max_iterations clamp: large value honored (no cap)"  "42" "$(maxi_clamp 42)"
assert_eq "max_iterations clamp: 0 → floor 1"                  "1"  "$(maxi_clamp 0)"
assert_eq "max_iterations clamp: negative → floor 1"           "1"  "$(maxi_clamp -3)"
assert_eq "max_iterations clamp: non-integer → 5"              "5"  "$(maxi_clamp abc)"
assert_eq "max_iterations clamp: float → 5"                    "5"  "$(maxi_clamp 2.5)"
assert_eq "max_iterations clamp: empty → 5"                    "5"  "$(maxi_clamp '')"
assert_eq "max_iterations clamp: resolver failure (rc≠0) → 5"  "5"  "$(maxi_clamp '' 2)"

# Drift guard: maxi_clamp above is a hand-maintained copy of the SKILL's inline
# clamp, so the clamp assertions would keep passing even if the *shipped* clamp in
# SKILL.md were edited. Pin the load-bearing tokens in the real SKILL so a change to
# the regex (negative-aware), the below-1 floor, or the default-5 fallback fails here
# instead of silently passing against the copy.
MAXI_SKILL="$LIB/../skills/review-and-fix/SKILL.md"
assert_pin_unique "max_iterations clamp: SKILL keeps the negative-aware integer regex" "'^-?[0-9]+\$'" "$MAXI_SKILL"
assert_pin_unique "max_iterations clamp: SKILL keeps the below-1 floor" '"$MAX_ITERS" -lt 1' "$MAXI_SKILL"
assert_pin_unique "max_iterations clamp: SKILL keeps the default-5 fallback" 'MAX_ITERS=5' "$MAXI_SKILL"

# ────────────────────────────────────────────────────────────────────────────
echo "severity thresholds (schema + example + config-get resolution + SKILL pins) (#251)"
# ────────────────────────────────────────────────────────────────────────────
# Three enum-valued keys let a repo tune fixer aggressiveness and verdict strictness.
# Config READING goes through config-get.sh (no new config parser); config-get.sh does
# NOT validate the enum (it coerces any JSON value to a string), so each SKILL validates
# the enum INLINE and falls back to the key's default on rc≠0 or an out-of-enum value.
# Model mirrors the max_iterations block above: (a) schema/example contract, (b) the REAL
# config-get.sh resolution feeding the validation, (c) a byte-aligned copy of the inline
# case (sev_normalize) exercising the fallback matrix, (d) operative-sentence pins that go
# RED if the behavior line is removed from the SKILL.
ST_SCHEMA="$LIB/../.devflow/config.schema.json"
ST_EXAMPLE="$LIB/../.devflow/config.example.json"

ST_FIX_PROP='.properties.devflow_review_and_fix.properties.fix_severity_threshold'
ST_VERDICT_PROP='.properties.devflow_review.properties.verdict_severity_threshold'
ST_RECV_PROP='.properties.receiving_review.properties.fix_severity_threshold'

# schema: each of the three keys is a string enum of exactly the three values, right default
assert_eq "sev: fix_severity_threshold schema type is string" "string" "$(jq -r "$ST_FIX_PROP.type" "$ST_SCHEMA")"
assert_eq "sev: fix_severity_threshold schema enum is exactly the three values" '["critical","important","suggestion"]' "$(jq -c "$ST_FIX_PROP.enum" "$ST_SCHEMA")"
assert_eq "sev: fix_severity_threshold schema default is important" "important" "$(jq -r "$ST_FIX_PROP.default" "$ST_SCHEMA")"
assert_eq "sev: fix_severity_threshold has non-empty description" "yes" "$(jq -e "$ST_FIX_PROP.description | type==\"string\" and (length>0)" "$ST_SCHEMA" >/dev/null && echo yes || echo no)"
assert_eq "sev: verdict_severity_threshold schema type is string" "string" "$(jq -r "$ST_VERDICT_PROP.type" "$ST_SCHEMA")"
assert_eq "sev: verdict_severity_threshold schema enum is exactly the three values" '["critical","important","suggestion"]' "$(jq -c "$ST_VERDICT_PROP.enum" "$ST_SCHEMA")"
assert_eq "sev: verdict_severity_threshold schema default is critical" "critical" "$(jq -r "$ST_VERDICT_PROP.default" "$ST_SCHEMA")"
assert_eq "sev: receiving_review.fix_severity_threshold schema type is string" "string" "$(jq -r "$ST_RECV_PROP.type" "$ST_SCHEMA")"
assert_eq "sev: receiving_review.fix_severity_threshold schema enum is exactly the three values" '["critical","important","suggestion"]' "$(jq -c "$ST_RECV_PROP.enum" "$ST_SCHEMA")"
assert_eq "sev: receiving_review.fix_severity_threshold schema default is critical" "critical" "$(jq -r "$ST_RECV_PROP.default" "$ST_SCHEMA")"

# example mirrors each schema default 1:1
assert_eq "sev: example fix_severity_threshold matches schema default" "$(jq -r "$ST_FIX_PROP.default" "$ST_SCHEMA")" "$(jq -r '.devflow_review_and_fix.fix_severity_threshold' "$ST_EXAMPLE")"
assert_eq "sev: example verdict_severity_threshold matches schema default" "$(jq -r "$ST_VERDICT_PROP.default" "$ST_SCHEMA")" "$(jq -r '.devflow_review.verdict_severity_threshold' "$ST_EXAMPLE")"
assert_eq "sev: example receiving_review.fix_severity_threshold matches schema default" "$(jq -r "$ST_RECV_PROP.default" "$ST_SCHEMA")" "$(jq -r '.receiving_review.fix_severity_threshold' "$ST_EXAMPLE")"

# config-get.sh returns the RAW coerced value and does NOT validate the enum — this is why
# the inline SKILL validation is load-bearing. Prove it on the divergence-prone shapes.
ST_CFG="$(probe_tmp sev.cfg)"
printf '%s' '{"devflow_review_and_fix":{"fix_severity_threshold":"suggestion"}}' > "$ST_CFG"
assert_eq "sev: config-get returns a configured valid value verbatim" "suggestion" "$("$CG" .devflow_review_and_fix.fix_severity_threshold important "$ST_CFG")"
printf '%s' '{"devflow_review_and_fix":{"fix_severity_threshold":5}}' > "$ST_CFG"
assert_eq "sev: config-get returns a raw number unvalidated (validation is the SKILL's job)" "5" "$("$CG" .devflow_review_and_fix.fix_severity_threshold important "$ST_CFG")"
printf '%s' '{"devflow_review_and_fix":{}}' > "$ST_CFG"
assert_eq "sev: config-get returns the default on an unset key" "important" "$("$CG" .devflow_review_and_fix.fix_severity_threshold important "$ST_CFG")"
assert_eq "sev: config-get returns the default on a missing config file" "important" "$("$CG" .devflow_review_and_fix.fix_severity_threshold important /no/such/config.json)"
rm -f "$ST_CFG"

# sev_normalize is a byte-aligned copy of the inline case block in all three SKILLs (kept in
# lockstep via the pins below). Exercises the fallback matrix the SKILLs run at runtime.
sev_normalize() {  # rc raw default -> the validated severity
  case "$1:$2" in
    0:critical|0:important|0:suggestion) printf '%s\n' "$2" ;;
    *) printf '%s\n' "$3" ;;
  esac
}
assert_eq "sev normalize: valid critical kept"                  "critical"   "$(sev_normalize 0 critical important)"
assert_eq "sev normalize: valid suggestion kept"               "suggestion" "$(sev_normalize 0 suggestion important)"
assert_eq "sev normalize: default (important) kept"            "important"  "$(sev_normalize 0 important important)"
# Any non-enum string collapses to the default (one representative here; the object/
# array/number coercion shapes are covered end-to-end against the real config-get.sh in
# the sev_resolve block below, so they aren't re-hardcoded at this pure-logic tier).
assert_eq "sev normalize: unknown string → default"            "important"  "$(sev_normalize 0 blocker important)"
assert_eq "sev normalize: empty → default"                     "important"  "$(sev_normalize 0 '' important)"
assert_eq "sev normalize: resolver failure (rc≠0) → default"   "critical"   "$(sev_normalize 2 '' critical)"
assert_eq "sev normalize: verdict/receiving default is critical" "critical" "$(sev_normalize 0 bogus critical)"

# End-to-end (the REAL config-get.sh runs, then the copied inline validation): the
# adversarial invalid-shape matrix each resolves to the key's default, never aborting.
sev_resolve() {  # json key default -> config-get.sh raw value passed through the inline validation
  local cfg raw rc
  cfg="$(probe_tmp sev_resolve.cfg)"
  printf '%s' "$1" > "$cfg"
  raw="$("$CG" "$2" "$3" "$cfg" 2>/dev/null)"; rc=$?
  rm -f "$cfg"
  sev_normalize "$rc" "$raw" "$3"
}
STK=.devflow_review_and_fix.fix_severity_threshold
assert_eq "sev e2e: configured valid value honored"    "suggestion" "$(sev_resolve '{"devflow_review_and_fix":{"fix_severity_threshold":"suggestion"}}' "$STK" important)"
assert_eq "sev e2e: object value → default"            "important"  "$(sev_resolve '{"devflow_review_and_fix":{"fix_severity_threshold":{"a":1}}}' "$STK" important)"
assert_eq "sev e2e: array value → default"             "important"  "$(sev_resolve '{"devflow_review_and_fix":{"fix_severity_threshold":["critical","important"]}}' "$STK" important)"
assert_eq "sev e2e: number value → default"            "important"  "$(sev_resolve '{"devflow_review_and_fix":{"fix_severity_threshold":5}}' "$STK" important)"
assert_eq "sev e2e: unknown string → default"          "important"  "$(sev_resolve '{"devflow_review_and_fix":{"fix_severity_threshold":"blocker"}}' "$STK" important)"
assert_eq "sev e2e: unset key → default (silent, AC2)"  "important" "$(sev_resolve '{"devflow_review_and_fix":{}}' "$STK" important)"
assert_eq "sev e2e: malformed JSON → default"          "important"  "$(sev_resolve '{ not valid json' "$STK" important)"
# End-to-end over the OTHER two keys, each with its own default — exercises the real
# config-get.sh against the verdict key and the brand-new top-level receiving_review
# section (a section-name/nesting typo in schema/example would surface here), incl. the
# invalid-value fallback so all three keys have live resolution coverage, not just pins.
assert_eq "sev e2e: verdict key configured value honored"   "important" "$(sev_resolve '{"devflow_review":{"verdict_severity_threshold":"important"}}' .devflow_review.verdict_severity_threshold critical)"
assert_eq "sev e2e: verdict key unknown value → default"    "critical"  "$(sev_resolve '{"devflow_review":{"verdict_severity_threshold":"blocker"}}' .devflow_review.verdict_severity_threshold critical)"
assert_eq "sev e2e: receiving section configured value honored" "suggestion" "$(sev_resolve '{"receiving_review":{"fix_severity_threshold":"suggestion"}}' .receiving_review.fix_severity_threshold critical)"
assert_eq "sev e2e: receiving section unset → default"      "critical"  "$(sev_resolve '{"receiving_review":{}}' .receiving_review.fix_severity_threshold critical)"

# operative-sentence pins in the three SKILL.md files (the sentence carrying the behavior)
ST_RAF="$LIB/../skills/review-and-fix/SKILL.md"
ST_REV="$LIB/../skills/review/SKILL.md"
ST_RCV="$LIB/../skills/receiving-code-review/SKILL.md"
# each SKILL reads its key via config-get.sh (already cloud-allowlisted — no new helper)
assert_pin_unique "sev(raf): reads fix_severity_threshold via config-get.sh" 'config-get.sh" .devflow_review_and_fix.fix_severity_threshold important' "$ST_RAF"
assert_pin_unique "sev(rev): reads verdict_severity_threshold via config-get.sh" 'config-get.sh" .devflow_review.verdict_severity_threshold critical' "$ST_REV"
assert_pin_unique "sev(rcv): reads receiving_review key via config-get.sh (anchor pattern)" 'config-get.sh .receiving_review.fix_severity_threshold critical' "$ST_RCV"
# each SKILL enum-validates inline (the case block config-get.sh does not do) — one per file
assert_pin_unique "sev(raf): enum-validates the threshold inline" '0:critical|0:important|0:suggestion' "$ST_RAF"
assert_pin_unique "sev(rev): enum-validates the threshold inline" '0:critical|0:important|0:suggestion' "$ST_REV"
assert_pin_unique "sev(rcv): enum-validates the threshold inline" '0:critical|0:important|0:suggestion' "$ST_RCV"
# routing / verdict / re-open behavior sentences
assert_pin_unique "sev(raf): routes findings at or above the loop threshold" 'any finding whose severity is at or above `$FIX_THRESHOLD`' "$ST_RAF"
assert_pin_unique "sev(raf): REJECT-driver widening tagline" 'no configuration combination produces a REJECT the fixer is configured to ignore' "$ST_RAF"
# The tagline above is the framing; pin the OPERATIVE clause too — removing it alone
# re-introduces the deadlock the AC forbids (verdict threshold more inclusive than fix).
assert_pin_unique "sev(raf): REJECT-driver widening operative clause" 'PLUS every finding that drove the engine' "$ST_RAF"
assert_pin_unique "sev(rev): rule 3 fires at or above the verdict threshold" 'at or above `$VERDICT_THRESHOLD` (excluding deferral-demoted ones) → **REJECT**' "$ST_REV"
assert_pin_unique "sev(rcv): carve-out re-opens at every threshold value" 're-opens the diff at every threshold value' "$ST_RCV"
# each SKILL emits a SPECIFIC out-of-enum fallback breadcrumb (the auditability contract
# the schema descriptions promise) — removing the echo would make the fallback silent
assert_pin_unique "sev(raf): out-of-enum fallback breadcrumb" "is not one of critical/important/suggestion; using default 'important'" "$ST_RAF"
assert_pin_unique "sev(rev): out-of-enum fallback breadcrumb" "is not one of critical/important/suggestion; using default 'critical'" "$ST_REV"
assert_pin_unique "sev(rcv): out-of-enum fallback breadcrumb" "is not one of critical/important/suggestion; using default 'critical'" "$ST_RCV"
# the DISTINCT resolver-failure (rc≠0) breadcrumb is a design point (a malformed config /
# missing python3 must not be misreported as a bad enum value) — pin it too, else deleting
# the rc≠0 echo would silence that path while the out-of-enum pin stayed green
assert_pin_unique "sev(raf): resolver-failure breadcrumb" 'could not read .devflow_review_and_fix.fix_severity_threshold' "$ST_RAF"
assert_pin_unique "sev(rev): resolver-failure breadcrumb" 'could not read .devflow_review.verdict_severity_threshold' "$ST_REV"
assert_pin_unique "sev(rcv): resolver-failure breadcrumb" 'could not read .receiving_review.fix_severity_threshold' "$ST_RCV"
# verdict rule 6 is the coupled partner of rule 3 (below-threshold → APPROVE with notes);
# pin it so it can't desync from the threshold-driven rule 3 into a contradictory partition
assert_pin_unique "sev(rev): rule 6 is threshold-driven (coupled with rule 3)" 'Only findings below `$VERDICT_THRESHOLD` present (excluding deferral-demoted ones) → **APPROVE with notes**' "$ST_REV"
# The "## Verdict Criteria" summary block (the report-template mirror of the numbered
# rules 3/6) is a SECOND site carrying the same threshold-driven partition. Pin BOTH its
# lines so a revert of just the summary to the historical "Any Critical → REJECT" /
# "Only Important/Suggestion → APPROVE with notes" can't ship GREEN and leave the SKILL
# with two contradictory verdict specs (coupled-invariant rule; PR #252 review finding).
assert_pin_unique "sev(rev): Verdict-Criteria summary REJECT line is threshold-driven (mirror of rule 3)" 'at or above the configured verdict threshold ({VERDICT_THRESHOLD}) → REJECT' "$ST_REV"
assert_pin_unique "sev(rev): Verdict-Criteria summary APPROVE-with-notes line is threshold-driven (mirror of rule 6)" 'Only findings below the verdict threshold → APPROVE with notes' "$ST_REV"
# Step 2.5's pre-fix verification gate was widened in lockstep with the routing threshold:
# it now classifies the WHOLE effective fix set, not just Critical/Important. This is the
# load-bearing safety behavior that keeps a Suggestion-level fix (admitted at
# fix_severity_threshold="suggestion") from bypassing the confidently-wrong-claim gate.
# Pin the operative clause so a revert to "each Critical or Important/Major finding" goes
# RED instead of silently stripping the protection (PR #252 review finding).
assert_pin_unique "sev(raf): Step 2.5 gate widened to the whole effective fix set" 'classify **every finding this iteration routed to the fixer**' "$ST_RAF"
# each SKILL falls back to its OWN key's default on BOTH fallback arms (out-of-enum +
# resolver-failure) — a wrong default here would silently loosen/tighten the policy while
# the case-label pin stayed green. Count is 2 (one assignment per fallback arm).
assert_eq "sev(raf): fix threshold falls back to 'important' on both arms" "2" "$(pin_count 'FIX_THRESHOLD=important' "$ST_RAF")"
assert_eq "sev(rev): verdict threshold falls back to 'critical' on both arms" "2" "$(pin_count 'VERDICT_THRESHOLD=critical' "$ST_REV")"
assert_eq "sev(rcv): re-open threshold falls back to 'critical' on both arms" "2" "$(pin_count 'REOPEN_THRESHOLD=critical' "$ST_RCV")"
# the receiving-code-review snippet keeps the vendored body repo-agnostic
assert_eq "sev(rcv): vendored body has no repo-specific test path (lib/test/run.sh)" "no" "$(grep -qF 'lib/test/run.sh' "$ST_RCV" && echo yes || echo no)"
assert_eq "sev(rcv): vendored body has no repo-specific CI job name (lib + python tests)" "no" "$(grep -qF 'lib + python tests' "$ST_RCV" && echo yes || echo no)"

# ────────────────────────────────────────────────────────────────────────────
echo "self-contradicting-diff verdict carve-out (Phase 4.2, threshold-independent) (#263)"
# ────────────────────────────────────────────────────────────────────────────
# #263 adds a threshold- AND severity-independent carve-out to the shared review
# engine's verdict (skills/review/SKILL.md): a finding that a doc/comment/test the
# PR's own diff added or modified is untrue drives REJECT at every
# verdict_severity_threshold value and regardless of severity chip, is non-demotable
# (Phase 4.0), and is corroboration-independent. Rule 3 gains an in-scope qualifier
# (mirroring type-design-analyzer's "diff does not touch" phrasing) that the carve-out
# overrides. The deliverable is LLM-executed skill prose — no automated verdict boundary —
# so these are operative-sentence pins (PASS→FAIL on removal), a coupled-site mirror pin
# (summary ↔ 4.2), a lockstep pin against receiving-code-review's shared definitional
# phrase, and a no-new-key pin. Same idiom as the #251 threshold pins above.

# A1 (carve-out AC): the Phase 4.2 operative sentence carrying "every threshold value /
# regardless of severity chip" — its removal alone re-opens the mechanical escape.
assert_pin_unique "263(A1): Phase 4.2 self-contradicting carve-out is threshold- and severity-independent" \
  'drives **REJECT** at **every** `verdict_severity_threshold` value' "$ST_REV"
# A2 (demotion-exclusion AC): the Phase 4.0 operative sentence — a matched deferral may
# not demote a self-contradicting finding; only a fix clears the REJECT.
assert_pin_unique "263(A2): Phase 4.0 excludes self-contradicting findings from deferral-demotion" \
  'may **not** be demoted to Informational / pre-existing / out-of-scope' "$ST_REV"
# A3 (in-scope qualifier AC): rule 3's "diff does not touch" qualifier AND the override
# clause (the carve-out always wins) — two operative sentences, one pin each.
assert_pin_unique "263(A3): rule 3 gains the 'diff does not touch' in-scope qualifier" \
  'Do not report on pre-existing types the diff does not touch" carve-out' "$ST_REV"
assert_pin_unique "263(A3): the carve-out overrides the in-scope qualifier (always in-scope)" \
  'can never be classified pre-existing' "$ST_REV"
# A4 (summary-match AC): the Phase 4.1 "Verdict Criteria" summary carries its own carve-out
# bullet (its literal is summary-unique), AND the shared definitional phrase occurs at
# exactly 3 sites in the engine (Phase 4.0 exclusion, Phase 4.2 carve-out, Phase 4.1
# summary) — if the summary desyncs from 4.2 and drops the clause, the count falls → RED.
assert_pin_unique "263(A4): Phase 4.1 summary carries the self-contradicting carve-out bullet" \
  'is untrue → REJECT at every threshold value and regardless of severity chip' "$ST_REV"
assert_eq "263(A4): carve-out definitional phrase mirrored across 4.0 + 4.2 + summary (coupled sites)" \
  "3" "$(pin_count 'stale, contradicts HEAD, or contradicts another part of this change' "$ST_REV")"
# A5 (lockstep + repo-agnostic AC): the verdict-engine carve-out and receiving-code-review's
# documented-falsehood carve-out share the SAME definition of "contradicts the diff" — pin
# the definitional phrase in receiving-code-review too, so a divergent redefinition of the
# term on either side goes RED. (The vendored body's repo-agnostic pins are the two above.)
assert_pin_unique "263(A5): receiving-code-review carries the shared 'contradicts the diff' definitional phrase" \
  'stale, contradicts HEAD, or contradicts another part of this change' "$ST_RCV"
# A6 (no-new-key AC): the carve-out is unconditional, not a knob — config.schema.json's
# devflow_review.properties key set is unchanged from #251 (no new threshold property).
assert_eq "263(A6): devflow_review schema gains no new property (carve-out adds no config key)" \
  "agent_overrides live_progress_comment_enabled verdict_severity_threshold" \
  "$(jq -r '.properties.devflow_review.properties | keys | join(" ")' "$ST_SCHEMA")"
# A7 (corroboration-independence AC — AC6): the carve-out blocks a SINGLE-SOURCE
# self-contradicting finding exactly like a corroborated one. This is a distinct enumerated
# deliverable property and the counter to Phase 4.1.5's uncorroborated-single-source
# over-grade shape, so pin its operative sentence — none of A1-A6 contain 'corroborat', so
# deleting this clause would otherwise leave the suite GREEN (PR #276 pr-test-analyzer gap).
assert_pin_unique "263(A7): the carve-out is not conditioned on Phase 3.2 corroboration count" \
  'a single-source self-contradicting finding blocks exactly like a corroborated one' "$ST_REV"

# Issue #182 (convention-violation / unscoped-staging): the review-and-fix fix-commit step
# (Step 3 item 6) must stage only the specific files the fix touched, never `git add -A` /
# `git add .` — an unscoped stage sweeps unrelated working-tree state (a local config edit,
# stray capture files) onto the feature branch (PRs #117, #174). Pin the operative
# prohibition sentence (not a framing clause) so a future simplification/rewrite that drops
# it goes RED. The literal is apostrophe-free and target-unique in the SKILL.
assert_pin_unique "unscoped-staging: review-and-fix fix-commit step prohibits git add -A / git add ." \
  'Never use `git add -A` or `git add .` at the fix-commit step' "$MAXI_SKILL"

# ── issue #254: post-shadow edit gate logs-only exemption. The Loop Exit persist step
# commits the observability artifacts (`.devflow/logs/**`) AFTER the shadow captured
# reviewed_sha, so on every writable converging run HEAD legitimately advances past
# reviewed_sha by exactly that logs-only commit — which formerly tripped the gate's own
# HEAD==reviewed_sha assertion. The gate now exempts a post-shadow commit whose diff
# touches ONLY `.devflow/logs/**`, while any commit touching other paths still trips it.
# Pin the operative exemption sentence removal-proof, plus the counter-assertion that a
# non-logs path still trips the gate (so a half-edit dropping the counter goes RED).
assert_pin_unique "#254: post-shadow gate exempts a logs-only post-shadow commit (operative)" \
  'a post-shadow commit whose diff touches only `.devflow/logs/**` does not constitute an unreviewed edit' "$MAXI_SKILL"
assert_pin_unique "#254: post-shadow gate keeps the counter — a non-logs path still trips the gate" \
  'Any commit touching a path outside `.devflow/logs/**` still trips the gate' "$MAXI_SKILL"
# Review iter 3 (finding: exemption fails OPEN on empty/errored diff — the vacuous-true hole):
# require the changed-path list be NON-EMPTY and treat empty/errored output as non-exempt so
# the gate fails closed, never open. Pin the operative fail-closed sentence removal-proof.
assert_pin_unique "#254: post-shadow gate fails closed on empty/errored diff (non-empty required)" \
  'An empty or errored `git diff` output is NOT exempt' "$MAXI_SKILL"
# (The removal-proof counterparts for both operative sentences live below, after
# assert_pin_red_on_removal is defined — see the "#254 post-shadow gate removal-proofs" block.)

# ── issue #254: the consumer prompt extension carries the two fail-open guard-class
# shapes (existence-vs-sourceability + tr-dependence), each with its #247 reproduction.
# The extension sharpens but never supplants the engine gates — assert the file exists and
# carries both shapes so a future edit that drops a shape (or the local instance that makes
# it actionable) fails here.
RAF_EXT="$LIB/../.devflow/prompt-extensions/review-and-fix.md"
assert_eq "#254: review-and-fix prompt extension exists" "yes" \
  "$([ -f "$RAF_EXT" ] && echo yes || echo no)"
assert_pin_unique "#254: extension carries the existence-vs-sourceability guard shape" \
  'Guard-class shape 1 — existence-vs-sourceability' "$RAF_EXT"
assert_pin_unique "#254: existence-vs-sourceability fix verifies the outcome (type <fn>), not the precondition" \
  'type <fn> >/dev/null 2>&1' "$RAF_EXT"
assert_pin_unique "#254: extension carries the tr-dependence guard shape" \
  'Guard-class shape 2 — tr-dependence' "$RAF_EXT"
assert_pin_unique "#254: tr-dependence shape names its #247 reproduction (derived-through-tr slug degrades)" \
  'degrades on a `PATH` without `tr`' "$RAF_EXT"

# Drift guard: the park-calibration gate is the lenient-verdict catch — it re-reads
# parked findings against three generic under-grade shapes before the review-and-fix
# loop concludes on an APPROVE-family verdict, so every review-and-fix-engine consumer
# benefits (standalone /devflow:review is untouched by construction). Each phrase below
# must be gate-unique: a whole-file scan would stay GREEN even with the gate deleted if
# the literal also appeared elsewhere (the PR #154 vacuous-guard hole). assert_pin_unique
# (PR #155) makes that mechanical — it FAILs unless the literal occurs EXACTLY ONCE in
# the resolved SKILL — so a paraphrase that guts the gate, OR a duplicated literal that
# would re-open the whole-file-scan hole, fails here instead of silently reverting.
#
# SCOPE (stated honestly, not over-claimed): the meta-test further below enforces
# helper-routing ONLY for the SKILL pins inside the PARKCAL_GUARD_REGION delimiters — it
# is a bounded guarantee over the park-calibration guard family, NOT a repo-wide claim
# that every raw SKILL guard (the maxi_clamp pins above, the DEF_SKILL/INIT_SKILL families)
# routes through assert_pin_unique. A new park-calibration guard belongs in this region and
# must use the helper; widening the meta-test to other families is deliberately out of
# scope for issue #155 (converting non-unique literals elsewhere risks unrelated RED).
# PARKCAL_GUARD_REGION_BEGIN — every SKILL pin until the END marker MUST use assert_pin_unique (meta-tested below)
assert_pin_unique "park-calibration: engine gate heading present in review-and-fix SKILL" \
  '#### Park-calibration gate (before any APPROVE-family conclusion)' "$MAXI_SKILL"
assert_pin_unique "park-calibration: engine gate documents the prompt-extension sharpening point" \
  'the extension does not replace this gate' "$MAXI_SKILL"
assert_pin_unique "park-calibration: engine gate keeps the Step 2.5 → Step 3 re-routing of a mis-graded finding" \
  'route the finding back through Step 2.5 → Step 3 as a promoted iteration' "$MAXI_SKILL"
assert_pin_unique "park-calibration: engine gate keeps its firing condition (Decide outcome 1 + Step 4.5 early-exit)" \
  'on the Step 4.5 early-exit path when non-REJECT' "$MAXI_SKILL"
assert_pin_unique "park-calibration: engine gate keeps under-grade shape 1 (fail-open guard / coverage hole)" \
  'Fail-open guard / coverage hole in this' "$MAXI_SKILL"
assert_pin_unique "park-calibration: engine gate keeps under-grade shape 2 (overclaiming breadcrumb/error)" \
  'A breadcrumb/error that overclaims vs. the path emitting it' "$MAXI_SKILL"
assert_pin_unique "park-calibration: engine gate keeps under-grade shape 3 (deferral the matcher will not honor)" \
  'is inert: the finding flows through at full severity' "$MAXI_SKILL"
# AC4: the Step 2.6 mandatory sentinel string — its presence is the gate's required-bullet
# contract; deleting it from SKILL.md turns this RED.
assert_pin_unique "park-calibration: engine gate keeps its mandatory clean-run sentinel contract" \
  'park-calibration gate clean: no parked finding matched' "$MAXI_SKILL"
# AC5: Loop-Exit machinery treats an APPROVE-family conclusion with no sentinel/re-grade
# bullet as non-convergence (the gate did not run to completion).
assert_pin_unique "park-calibration: Loop-Exit treats a missing sentinel bullet as non-convergence" \
  'An APPROVE-family conclusion that carries no park-calibration sentinel or re-grade bullet is treated as non-convergence' "$MAXI_SKILL"
# AC6: explicit firing-site handoffs route the executor into the gate from each declared
# firing site, so a prose-driven loop reaches it by an explicit transition (not only via
# the gate's own "Fires before…" self-declaration).
assert_pin_unique "park-calibration: Decide outcome 1 carries the explicit gate handoff" \
  'first run the Park-calibration gate (it fires before this outcome commits)' "$MAXI_SKILL"
assert_pin_unique "park-calibration: Step 4.5 early-exit carries the explicit gate handoff" \
  'first run the Park-calibration gate on this early-exit path' "$MAXI_SKILL"
# AC7: the mutation-check rule is re-scoped to ANY added/edited test guard, and the
# implement skill's test-writing phase references that discipline. Pin both coupled sites
# so a paraphrase that narrows the rule back to fix-loop-only fails here.
assert_pin_unique "mutation-check: review-and-fix rule covers any added or edited test guard in the diff" \
  'any added or edited test guard in the diff' "$MAXI_SKILL"
assert_pin_unique "mutation-check: implement skill test-writing phase references the discipline" \
  'Mutation-check any test guard you add here' "$DEF_SKILL"
# PARKCAL_GUARD_REGION_END — end of the assert_pin_unique-only park-calibration pin region

# Issue #186 behavioral-fix-pin coverage lives with the other SKILL-prose removal-proof pins
# below (after assert_pin_red_on_removal is defined) — see the "#186" block near the #167
# cluster. (assert_pin_red_on_removal is defined further down, so it cannot be called here.)

# ── Meta-test (AC2): no raw drift guard may bypass assert_pin_unique inside the region.
# The region markers are matched by SPLIT-built literals so this scanner's own source never
# contains the contiguous marker string (otherwise it would mis-delimit when scanning the
# very file it lives in). This is a BOUNDED guarantee over the park-calibration guard family
# only — see the SCOPE note on the region above; it does not police raw guards elsewhere.
PARKCAL_BMARK="PARKCAL_GUARD_REGION_""BEGIN"
PARKCAL_EMARK="PARKCAL_GUARD_REGION_""END"
# Print the lines strictly INSIDE the PARKCAL region of FILE (both markers excluded:
# BEGIN via `next`, END because `inreg` is already cleared when the default-print rule
# runs). The single source of truth for region extraction — every region scanner below
# (#155's count_raw_skill_guards_in_region / count_region_pins and #157's
# count_region_nonhelper_stmts) pipes through this, so the region-delimiting semantics
# live in ONE place instead of a copy per scanner (the coupled-mirror drift this very
# suite exists to catch).
region_lines() {  # file [bmark] [emark] -> the lines strictly inside the region (default PARKCAL)
  # Markers default to the park-calibration region (back-compat for the single-arg callers),
  # but accept an explicit BEGIN/END pair so the SAME delimiter polices every registered
  # region (issue #159 B3 generalization — park-calibration AND fix-delta).
  local file="$1" b="${2:-$PARKCAL_BMARK}" e="${3:-$PARKCAL_EMARK}"
  awk -v b="$b" -v e="$e" \
    'index($0,b){inreg=1;next} index($0,e){inreg=0} inreg' "$file"
}
# Print every line between the BEGIN and END markers of FILE that is a raw `grep`-based
# SKILL drift guard — ANY `grep ` command referencing a SKILL target. The pattern is
# deliberately broad on two axes the review of this very PR flagged in turn: (1) flag
# spelling — it catches `grep -qF`, `grep -Fq`, `grep -qE`, and a count-based `grep -cF`,
# so re-ordering the flags cannot dodge it; (2) target spelling — THREE alternations cover
# every SKILL-target convention in this file: `_SKILL` (a `$DEF_SKILL`/`$MAXI_SKILL`/… var
# or `${CLAUDE_SKILL_DIR}`), `SKILL_` (a `$SKILL_FILE`/`$SKILL_NAME`/`$SKILL_DIR` loop var,
# whose underscore is AFTER `SKILL` so the `_SKILL` arm misses it — the #164-review gap),
# and `SKILL\.md` (a literal `"$LIB/../skills/.../SKILL.md"` path). A correctly-routed
# region routes every pin through assert_pin_unique — those lines carry no `grep` — so it
# yields 0. Markers default to the park-calibration region (back-compat for the AC3 proofs,
# which call file-only), but accept an explicit BEGIN/END pair so the SAME helper polices
# every registered region (issue #159 B3 generalization — park-calibration AND fix-delta).
# `|| true` keeps grep's no-match exit 1 from tripping the `set -u`/pipefail-free harness.
count_raw_skill_guards_in_region() {  # file [bmark] [emark] -> prints count of offending lines
  region_lines "$1" "${2:-$PARKCAL_BMARK}" "${3:-$PARKCAL_EMARK}" \
    | grep -cE 'grep[[:space:]].*(_SKILL|SKILL_|SKILL\.md)' || true
}
# Count the routed assert_pin_unique pins strictly INSIDE the region of FILE (markers
# excluded by `next` on BEGIN). Shared by the live region-non-empty control AND its AC3(f)
# mutation proof, so the proof binds to the SAME expression the control runs (not a parallel
# re-derivation that a refactor of one side could silently desync from the other).
count_region_pins() {  # file [bmark] [emark] -> prints count of in-region assert_pin_unique lines
  # `|| true` mirrors count_raw_skill_guards_in_region: it absorbs grep's no-match exit 1
  # (an emptied region prints 0, exit 1) so the helper stays inert under a future
  # `set -e`/`pipefail` hardening of the harness, matching its sibling rather than aborting
  # the whole script on the legitimate empty-region case AC3(f) deliberately exercises.
  # Markers default to the park-calibration region (back-compat for AC3); accept an explicit
  # pair so it counts pins in any registered region (issue #159 B3 generalization).
  region_lines "$1" "${2:-$PARKCAL_BMARK}" "${3:-$PARKCAL_EMARK}" | grep -cF 'assert_pin_unique' || true
}
SELF_SRC="$LIB/test/run.sh"
# Issue #159 B3: the assert_pin_unique-only invariant is now enforced for EVERY registered
# pin region, not just park-calibration. The fix-delta region (defined with the pins below)
# uses split-built markers so the definition lines carry no contiguous marker string.
FIXDELTA_BMARK="FIXDELTA_GUARD_REGION_""BEGIN"
FIXDELTA_EMARK="FIXDELTA_GUARD_REGION_""END"
# Parametrized per-region discipline check — the four meta(AC2) controls for one region:
# (1) zero raw SKILL guards in-region, (2) BEGIN present exactly once, (3) END present
# exactly once, (4) region non-empty. The marker-presence + non-empty controls close the
# meta-test's OWN fail-open (markers absent → awk scans nothing → raw-guard count is a
# vacuous 0; region emptied of pins → also a vacuous 0). Running it per-region means a new
# region inherits the full anti-vacuity guarantee for free — the B3 generalization.
assert_region_pin_discipline() {  # label bmark emark
  local label="$1" b="$2" e="$3" n
  assert_eq "meta(AC2): $label region routes every SKILL pin through assert_pin_unique (0 raw guards)" \
    "0" "$(count_raw_skill_guards_in_region "$SELF_SRC" "$b" "$e")"
  assert_eq "meta(AC2): $label region BEGIN marker present exactly once (else the scan fails OPEN)" \
    "1" "$(pin_count "$b" "$SELF_SRC")"
  assert_eq "meta(AC2): $label region END marker present exactly once (else the scan fails OPEN)" \
    "1" "$(pin_count "$e" "$SELF_SRC")"
  n=$(count_region_pins "$SELF_SRC" "$b" "$e")
  assert_eq "meta(AC2): $label region is non-empty (routed pins present, not an emptied region)" \
    "yes" "$([ "${n:-0}" -ge 1 ] && echo yes || echo no)"
}
assert_region_pin_discipline "park-calibration" "$PARKCAL_BMARK" "$PARKCAL_EMARK"
assert_region_pin_discipline "fix-delta" "$FIXDELTA_BMARK" "$FIXDELTA_EMARK"

# ── AC3 mutation proofs: each deterministic guard above must demonstrably go RED on the
# defect it exists to catch, then GREEN is the real (unmutated) state. We exercise the
# REAL assert_pin_unique / meta-test against a mutated TEMP copy via probe_assert, so the
# intentional RED never pollutes the suite tally.
#
# AC3(a): assert_pin_unique is GREEN on a unique literal and RED on a non-unique or absent
# one (the PR #154 duplicate-literal shape is the non-unique case).
PINPROBE_ONE="$(probe_tmp 'AC3(a) unique-case setup')"; printf 'PINPROBE_LITERAL\n' > "$PINPROBE_ONE"
PINPROBE_DUP="$(probe_tmp 'AC3(a) duplicate-case setup')"; printf 'PINPROBE_LITERAL\nPINPROBE_LITERAL\n' > "$PINPROBE_DUP"
assert_eq "AC3(a): assert_pin_unique GREEN on a unique literal" \
  "PASS" "$(probe_assert assert_pin_unique 'probe-unique' 'PINPROBE_LITERAL' "$PINPROBE_ONE")"
assert_eq "AC3(a): assert_pin_unique RED on a non-unique (duplicate) literal" \
  "FAIL" "$(probe_assert assert_pin_unique 'probe-dup' 'PINPROBE_LITERAL' "$PINPROBE_DUP")"
assert_eq "AC3(a): assert_pin_unique RED on an absent literal" \
  "FAIL" "$(probe_assert assert_pin_unique 'probe-absent' 'PINPROBE_ABSENT' "$PINPROBE_ONE")"
rm -f "$PINPROBE_ONE" "$PINPROBE_DUP"
#
# AC3(a2): pin_count counts OCCURRENCES, not matching lines — the load-bearing
# `grep -oF | grep -c .` choice (over `grep -cF`). A same-LINE duplicate is the only
# discriminating fixture: `grep -cF` reports it as 1 matching line (letting a non-unique pin
# pass vacuously), while the occurrence counter returns 2 so assert_pin_unique fails it. The
# separate-line AC3(a) dup does not discriminate (both spellings count 2), so a refactor back
# to `grep -cF` would keep AC3(a) GREEN; this case pins the choice.
PINPROBE_SAMELINE="$(probe_tmp 'AC3(a2) same-line-dup setup')"
printf 'PINPROBE_LITERAL PINPROBE_LITERAL\n' > "$PINPROBE_SAMELINE"
assert_eq "AC3(a2): pin_count counts same-line occurrences (2), not matching lines (1)" \
  "2" "$(pin_count 'PINPROBE_LITERAL' "$PINPROBE_SAMELINE")"
rm -f "$PINPROBE_SAMELINE"
#
# AC3(a3): pin_count matches the literal as a FIXED string (the `-F` flag), per issue #155's
# Testing Strategy. A literal carrying a regex metacharacter must match itself only, never act
# as a wildcard: against a line that satisfies the REGEX `a.c` (here `axc`) but not the literal
# `a.c`, the count must be 0 — dropping `-F` would mis-count it as 1. The live pins' only
# metachar is `.` (which matches itself), so without this fixture nothing would catch a lost `-F`.
PINPROBE_RE="$(probe_tmp 'AC3(a3) regex-metachar setup')"
printf 'axc\n' > "$PINPROBE_RE"
assert_eq "AC3(a3): pin_count treats the literal as fixed (-F): a regex metachar does not wildcard" \
  "0" "$(pin_count 'a.c' "$PINPROBE_RE")"
printf 'a.c\n' > "$PINPROBE_RE"
assert_eq "AC3(a3): pin_count still matches the exact metachar literal as a fixed string" \
  "1" "$(pin_count 'a.c' "$PINPROBE_RE")"
rm -f "$PINPROBE_RE"
#
# AC3(b): the meta-test detects a raw SKILL guard injected into the region. Inject a line
# carrying `grep -qF` + a `_SKILL` var right after the BEGIN marker of a temp copy; the
# injected text is passed via awk -v (no \x escapes) to stay portable to BSD/mawk.
PINPROBE_RAW="$(probe_tmp 'AC3(b) injection setup')"
awk -v b="$PARKCAL_BMARK" -v inj='  grep -qF INJECTED_RAW_GUARD "$MAXI_SKILL"' \
  '{ print } index($0, b) { print inj }' "$SELF_SRC" > "$PINPROBE_RAW"
assert_eq "AC3(b): meta-test detects a raw SKILL guard injected into the region (RED)" \
  "1" "$(count_raw_skill_guards_in_region "$PINPROBE_RAW")"
rm -f "$PINPROBE_RAW"
#
# AC3(b2): the broadened detector also catches a VARIANT flag spelling (`grep -Fq` instead
# of `grep -qF`), proving the meta-test is not pinned to one exact flag order (the first
# narrowness axis flagged in review). Same injection mechanism, different flag order.
PINPROBE_RAW2="$(probe_tmp 'AC3(b2) injection setup')"
awk -v b="$PARKCAL_BMARK" -v inj='  grep -Fq INJECTED_VARIANT "$MAXI_SKILL"' \
  '{ print } index($0, b) { print inj }' "$SELF_SRC" > "$PINPROBE_RAW2"
assert_eq "AC3(b2): meta-test detects a variant-spelled raw SKILL guard (grep -Fq) in the region (RED)" \
  "1" "$(count_raw_skill_guards_in_region "$PINPROBE_RAW2")"
rm -f "$PINPROBE_RAW2"
#
# AC3(b3): the broadened detector also catches the LITERAL-PATH target spelling (a raw guard
# written against `"…/skills/.../SKILL.md"` rather than a `$..._SKILL` var) — the second
# narrowness axis flagged in review, the dominant raw-guard convention elsewhere in this
# file. Without the `SKILL\.md` arm this injection would slip through and AC2 pass vacuously.
PINPROBE_RAW3="$(probe_tmp 'AC3(b3) injection setup')"
awk -v b="$PARKCAL_BMARK" -v inj='  grep -qF INJECTED_PATHLIT "$LIB/../skills/review-and-fix/SKILL.md"' \
  '{ print } index($0, b) { print inj }' "$SELF_SRC" > "$PINPROBE_RAW3"
assert_eq "AC3(b3): meta-test detects a literal-path raw SKILL guard (…/SKILL.md) in the region (RED)" \
  "1" "$(count_raw_skill_guards_in_region "$PINPROBE_RAW3")"
rm -f "$PINPROBE_RAW3"
#
# AC3(b4): NEGATIVE-direction scoping proof — a raw SKILL guard injected OUTSIDE the region
# (after the END marker) must yield 0, proving the awk range logic is genuinely region-scoped
# and not a whole-file scan. The AC3(b*) injections all sit after BEGIN (inside the region), so
# a regression widening the scan to the whole file would still pass them while silently flagging
# the many legitimate raw guards elsewhere in this file. Inject after the END marker; expect 0.
PINPROBE_OUTREG="$(probe_tmp 'AC3(b4) out-of-region injection setup')"
awk -v e="$PARKCAL_EMARK" -v inj='  grep -qF INJECTED_OUTOFREGION "$MAXI_SKILL"' \
  '{ print } index($0, e) { print inj }' "$SELF_SRC" > "$PINPROBE_OUTREG"
assert_eq "AC3(b4): meta-test ignores a raw SKILL guard injected OUTSIDE the region (scoped, not whole-file)" \
  "0" "$(count_raw_skill_guards_in_region "$PINPROBE_OUTREG")"
rm -f "$PINPROBE_OUTREG"
#
# AC3(b5): the broadened SKILL_ arm applies to the IN-REGION scanner too (#164-review) — a raw
# guard targeting a `SKILL_`-suffixed loop var ($SKILL_FILE) injected into the region is caught,
# the in-region twin of the repo-wide SKILL_ proof. Under the old `(_SKILL|SKILL\.md)`-only
# pattern this would read 0 (the regression this binds). The in-region scanner has no `.*echo`
# requirement, so the injected guard needs no echo.
# The injected LITERAL must contain no `_SKILL`/`SKILL_`/`SKILL.md` substring, so the ONLY token
# matching the pattern is the `$SKILL_FILE` target via the new SKILL_ arm — otherwise the fixture
# would match under the old pattern too (via the literal) and prove nothing (a vacuous guard).
PINPROBE_RAW5="$(probe_tmp 'AC3(b5) SKILL_ injection setup')"
awk -v b="$PARKCAL_BMARK" -v inj='  grep -qF INJECTED_LOOPVAR_RAW "$SKILL_FILE"' \
  '{ print } index($0, b) { print inj }' "$SELF_SRC" > "$PINPROBE_RAW5"
assert_eq "AC3(b5): meta-test detects a SKILL_-suffixed-var raw SKILL guard (\$SKILL_FILE) in the region (RED)" \
  "1" "$(count_raw_skill_guards_in_region "$PINPROBE_RAW5")"
rm -f "$PINPROBE_RAW5"
#
# AC3(e): the marker-presence positive control fails CLOSED when a region marker is deleted —
# the meta-test's own anti-vacuity proof. Strip the BEGIN marker line from a temp copy and
# confirm its presence count goes to 0 (so the assert_eq "1" control above would turn RED),
# meaning a marker deletion can no longer silently pass AC2 over an unscanned region.
PINPROBE_NOMARK="$(probe_tmp 'AC3(e) marker-strip setup')"
grep -vF "$PARKCAL_BMARK" "$SELF_SRC" > "$PINPROBE_NOMARK"
assert_eq "AC3(e): deleting the region BEGIN marker turns its presence control RED (no vacuous AC2 pass)" \
  "0" "$(pin_count "$PARKCAL_BMARK" "$PINPROBE_NOMARK")"
# Self-protect AC3(e) against its own vacuity: prove the strip removed ONLY the BEGIN marker —
# the END marker must still count 1. Otherwise an empty/unreadable temp copy (pin_count folds a
# grep error into 0) would satisfy the "0" above for the wrong reason, making this proof vacuous
# in isolation rather than relying on the suite-level AC2 marker-presence controls to catch it.
assert_eq "AC3(e): the strip removed ONLY the BEGIN marker (END marker still present — copy not emptied)" \
  "1" "$(pin_count "$PARKCAL_EMARK" "$PINPROBE_NOMARK")"
rm -f "$PINPROBE_NOMARK"
#
# AC3(f): the region-non-empty positive control fails CLOSED if the routed pins are stripped
# from the region (BOTH markers kept, pins moved out) — proving that emptied-region shape RED
# too. The stripper explicitly print+next's each marker line so a marker is never dropped by
# the `assert_pin_unique`-mention rule (the BEGIN/END comment lines both contain that token),
# keeping this the genuine "markers kept, pins gone" shape; then count_region_pins — the SAME
# expression the live control runs — must read 0.
PINPROBE_EMPTY="$(probe_tmp 'AC3(f) empty-region setup')"
awk -v b="$PARKCAL_BMARK" -v e="$PARKCAL_EMARK" '
  index($0,b) { inreg=1; print; next }
  index($0,e) { inreg=0; print; next }
  inreg && /assert_pin_unique/ { next }
  { print }
' "$SELF_SRC" > "$PINPROBE_EMPTY"
assert_eq "AC3(f): emptying the region of routed pins turns the non-empty control RED" \
  "0" "$(count_region_pins "$PINPROBE_EMPTY")"
rm -f "$PINPROBE_EMPTY"
#
# AC3(c)/(d): removing a pinned MAXI_SKILL contract literal turns its pin RED. Both cases
# share the "strip the literal from a temp copy, confirm the real pin goes RED" shape, so
# route them through one helper (the literal is the only variable).
# SELF-CONTAINED mutation proof: assert the full PASS->FAIL transition — the literal is
# present-and-unique on the REAL file (probe PASS) AND goes RED once stripped (probe FAIL).
# Asserting the transition, not just the post-strip FAIL, closes the vacuity a bare
# post-strip check has: a literal that was never present yields FAIL on a no-op strip
# (count 0->0), so the proof would pass vacuously. Checking the `before` PASS too means the
# proof no longer depends on a paired assert_pin_unique to notice a literal that drifted out
# of the target file — each proof stands on its own.
assert_pin_red_on_removal() {  # name literal [file]   (file defaults to $MAXI_SKILL)
  local t file="${3:-$MAXI_SKILL}" before after; t="$(probe_tmp "$1 (removal setup)")" || return 0
  before="$(probe_assert assert_pin_unique 'probe-present' "$2" "$file")"
  grep -vF "$2" "$file" > "$t"
  after="$(probe_assert assert_pin_unique 'probe-removal' "$2" "$t")"
  assert_eq "$1" "PASS->FAIL" "$before->$after"
  rm -f "$t"
}
assert_pin_red_on_removal "AC3(c): deleting the Step 2.6 sentinel contract turns its pin RED" \
  'park-calibration gate clean: no parked finding matched'
assert_pin_red_on_removal "AC3(d): narrowing the mutation-check rule back to fix-only turns its pin RED" \
  'any added or edited test guard in the diff'
# #254 post-shadow gate removal-proofs (the assert_pin_unique presence pins are up in the
# max_iterations/review-and-fix block; these removal-proofs must sit below the helper def).
assert_pin_red_on_removal "#254: post-shadow gate logs-only exemption flips RED on removal" \
  'a post-shadow commit whose diff touches only `.devflow/logs/**` does not constitute an unreviewed edit'
assert_pin_red_on_removal "#254: post-shadow gate non-logs counter-assertion flips RED on removal" \
  'Any commit touching a path outside `.devflow/logs/**` still trips the gate'
#
# AC3(g): the GENERALIZED (issue #159 B3) region meta-test detects a raw SKILL guard injected
# into EACH registered region — proving the parametrized helper is not silently inert for the
# fix-delta region, only proven for park-calibration by AC3(b). For each region: inject a raw
# `grep -qF … "$MAXI_SKILL"` line right after that region's BEGIN marker of a temp copy, then
# confirm count_raw_skill_guards_in_region — invoked with THAT region's markers — reports 1
# (RED). A region whose markers the helper could not see would report 0, so a non-zero proves
# the parametrization actually scopes to the named region.
for _rg in "park-calibration:$PARKCAL_BMARK:$PARKCAL_EMARK" "fix-delta:$FIXDELTA_BMARK:$FIXDELTA_EMARK"; do
  _rglabel="${_rg%%:*}"; _rgrest="${_rg#*:}"; _rgb="${_rgrest%%:*}"; _rge="${_rgrest#*:}"
  _rgtmp="$(probe_tmp "AC3(g) $_rglabel injection setup")"
  awk -v b="$_rgb" -v inj='  grep -qF INJECTED_AC3G "$MAXI_SKILL"' \
    '{ print } index($0, b) { print inj }' "$SELF_SRC" > "$_rgtmp"
  assert_eq "AC3(g): generalized meta-test detects a raw SKILL guard injected into the $_rglabel region (RED)" \
    "1" "$(count_raw_skill_guards_in_region "$_rgtmp" "$_rgb" "$_rge")"
  rm -f "$_rgtmp"
done

# Drift guard: the over-grade calibration gate is the park-calibration gate's mirror on
# the PROMOTE path — it flags a suspected over-graded Critical/Important finding before it
# drives a Decide-outcome-2 promotion and requires a recorded per-finding technical
# evaluation (it never auto-demotes), mechanizing the receiving-code-review
# symmetric-severity-calibration principle. The two gates are halves of one symmetric
# calibration defense, so a silent revert of EITHER half must fail here. These pins use the
# shared assert_pin_unique (name literal file) → exactly one occurrence in the target file:
# unlike a bare grep -qF they also fail closed if the literal is deleted (mutation proof) or
# duplicated by a paraphrase. Each literal is gate-unique and apostrophe-free.
RECV_SKILL="$LIB/../skills/receiving-code-review/SKILL.md"
assert_pin_unique "over-grade: engine gate heading present in review-and-fix SKILL" \
  '#### Over-grade calibration gate (before any Decide outcome 2 promotion)' "$MAXI_SKILL"
assert_pin_unique "over-grade: engine gate keeps its mandatory reflection sentinel" \
  'over-grade calibration gate clean: no promote-path finding flagged' "$MAXI_SKILL"
assert_pin_unique "over-grade: engine gate keeps the never-auto-demote contract (flag + recorded evaluation)" \
  'flags and requires a recorded technical evaluation; it never auto-demotes' "$MAXI_SKILL"
# The over-grade SHAPE DEFINITIONS now have a single source of truth in the shared engine
# (/devflow:review Phase 4.1.5) — issue #195. Pin the canonical shapes against review/SKILL.md,
# pin that review-and-fix REFERENCES (does NOT fork) them, and pin the advisory-annotation
# contract (advisory only; verdict unchanged; never auto-demote).
OG_REVIEW_SKILL="$LIB/../skills/review/SKILL.md"
assert_pin_unique "over-grade: shared engine carries the single-source annotation heading" \
  '### 4.1.5 Over-grade advisory annotation (advisory only — never changes the verdict)' "$OG_REVIEW_SKILL"
assert_pin_unique "over-grade: shared engine declares itself the single source of truth for the shapes" \
  'single source of truth for the over-grade shape definitions' "$OG_REVIEW_SKILL"
assert_pin_unique "over-grade: shared engine carries over-grade shape 1 (suite-RED / fail-closed above blast radius)" \
  'Suite-RED or fail-closed defect graded above its blast radius' "$OG_REVIEW_SKILL"
assert_pin_unique "over-grade: shared engine carries over-grade shape 2 (diagnostic-or-cosmetic-only)" \
  'Diagnostic-or-cosmetic-only finding with no behavioral fail-direction' "$OG_REVIEW_SKILL"
assert_pin_unique "over-grade: shared engine carries over-grade shape 3 (uncorroborated single-source from an empirical over-grader)" \
  'Uncorroborated single-source finding from an empirical over-grader' "$OG_REVIEW_SKILL"
assert_pin_unique "over-grade: standalone annotation is advisory — verdict computation unchanged (AC2)" \
  '**The verdict computation in 4.2 is unchanged**' "$OG_REVIEW_SKILL"
assert_pin_unique "over-grade: standalone annotation never auto-demotes (advisory by construction, AC2)" \
  'it MUST **not auto-demote**' "$OG_REVIEW_SKILL"
assert_pin_unique "over-grade: shared engine clean-scan sentinel present" \
  'over-grade annotation: no finding flagged' "$OG_REVIEW_SKILL"
# No-fork coupling (AC3): review-and-fix's Step 2.6 gate must REFERENCE the canonical shapes,
# not restate them — these pins go RED if the dereference is reverted to an inline copy.
assert_pin_unique "over-grade: review-and-fix gate references the single shared shape definition (no fork, AC3)" \
  'this gate consumes that canonical list and does not restate it here' "$MAXI_SKILL"
assert_pin_unique "over-grade: review-and-fix gate explicitly forbids forking the shapes (AC3)" \
  'Do not fork or re-define the shapes here.' "$MAXI_SKILL"
# AC4: docs/shadow-review.md must scope the standalone annotation as advisory / verdict-untouched.
# AC1: the human-facing annotation template (cites the observable fail-direction) must keep its shape.
# Attach-point: the Phase 4.1 report-injection line that actually wires 4.1.5 into the report
# (without it 4.1.5 is defined-but-inert). Each is a distinct AC-required contract surface.
OG_SHADOW_DOC="$LIB/../docs/shadow-review.md"
assert_pin_unique "over-grade: docs/shadow-review.md scopes the annotation as verdict-untouched (AC4)" \
  'leaves the verdict computation untouched' "$OG_SHADOW_DOC"
assert_pin_unique "over-grade: engine keeps the annotation template citing the observable fail-direction (AC1)" \
  'suspected over-grade: shape {n} — observable fail-direction is {X}, milder than the {severity} label' "$OG_REVIEW_SKILL"
assert_pin_unique "over-grade: Phase 4.1 report wires in the 4.1.5 annotation (attach-point, not inert)" \
  "append its advisory annotation to that finding's line here" "$OG_REVIEW_SKILL"
# AC3 fail-CLOSED against a re-fork (not only the positive reference pins above): the shape
# literals must be ABSENT from review-and-fix. If a future edit re-inlines a shape copy while
# leaving the reference sentence in place, the positive pins stay GREEN but these go RED — the
# coupled-invariant / single-source discipline CLAUDE.md flags as the dominant violation.
assert_eq "over-grade: shape 1 is NOT re-forked into review-and-fix (AC3 fail-closed)" \
  "0" "$(pin_count 'Suite-RED or fail-closed defect graded above its blast radius' "$MAXI_SKILL")"
assert_eq "over-grade: shape 2 is NOT re-forked into review-and-fix (AC3 fail-closed)" \
  "0" "$(pin_count 'Diagnostic-or-cosmetic-only finding with no behavioral fail-direction' "$MAXI_SKILL")"
# AC2's load-bearing clause (the #189 motivating case): an over-graded Critical must STILL REJECT.
# Pinned distinctly from the broader "verdict computation unchanged" so a rewrite that weakens
# only this clause cannot ride out GREEN.
assert_pin_unique "over-grade: annotation never clears or downgrades a REJECT (AC2, #189 case)" \
  'never clears or downgrades a REJECT' "$OG_REVIEW_SKILL"
# Shape 3's discriminating predicate (not just its heading): the 'no Phase-2 FAIL' qualifier is
# what keeps it from firing on a corroborated finding; pin it so a future loosening goes RED.
assert_pin_unique "over-grade: shape 3 keeps its 'no Phase-2 FAIL' discriminating qualifier" \
  'no Phase-2 verification-checklist FAIL covering the same defect' "$OG_REVIEW_SKILL"
assert_pin_unique "over-grade: engine gate names the receiving-code-review principle it mechanizes" \
  'mechanizes the receiving-code-review symmetric-severity-calibration principle' "$MAXI_SKILL"
# Cross-skill coupling: the principle the gate mechanizes must actually exist in the
# vendored receiving-code-review skill (engine-agnostic, no DevFlow machinery named there).
assert_pin_unique "over-grade: receiving-code-review states the symmetric-severity-calibration principle heading" \
  '## Symmetric Severity Calibration' "$RECV_SKILL"
assert_pin_unique "over-grade: receiving-code-review calibrates severity in both directions" \
  'calibrated against the observable fail-direction and impact in both directions' "$RECV_SKILL"
# Pin the gate's two INTEGRATION points, not just its definition. The six pins above
# guard the gate body (heading/shapes/sentinel/contract/principle reference); but a gate
# is dead text unless something invokes it and enforces its block. Both wiring sentences
# can revert while every body pin stays GREEN — the coupled-invariant half-revert CLAUDE.md
# flags as the dominant convention-violation pattern. Pin (1) the Decide-outcome-2 call
# site that fires the gate and (2) the Loop-Exit clause that makes a flagged-but-unevaluated
# finding non-convergence (the fail-closed enforcement, AC3).
assert_pin_unique "over-grade: Decide outcome 2 wires in the gate (call site)" \
  'run the "Over-grade calibration gate" below' "$MAXI_SKILL"
assert_pin_unique "over-grade: Loop-Exit treats a flagged-but-unevaluated finding as non-convergence" \
  'Over-grade gate non-convergence (fail-closed).' "$MAXI_SKILL"
# Pin the new fix_decisions decision value at its enum source-of-truth line: the gate's
# required evidence is unrepresentable in the workpad if this enum drops the value, yet
# every gate-body pin would stay GREEN.
assert_pin_unique "over-grade: severity-calibrated is in the fix_decision enum" \
  'applied | pushed_back | deferred | advisory | severity-calibrated' "$MAXI_SKILL"
# Pin the principle's anti-abuse half in receiving-code-review: the symmetric-direction
# sentence (pinned above) without this clause would let calibration become a
# severity-laundering loophole — it mirrors the engine's pinned never-auto-demote contract.
assert_pin_unique "over-grade: receiving-code-review forbids down-calibrating to dodge the fix" \
  'Never down-calibrate to avoid the fix' "$RECV_SKILL"
# Pin the PRODUCER of severity-calibrated records (Step 3 item 2) and its no-skip_category
# persist invariant (Step 3 item 7). The gate only FLAGS; item 2 is the only place the
# required `decision: "severity-calibrated"` evidence is written, and the "no skip_category"
# property is what keeps the Loop-Exit skip_category-keyed gates from misreading a
# calibration as a skip. Both can revert while every gate-body pin stays GREEN.
assert_pin_unique "over-grade: Step 3 item 2 produces the recorded severity-calibration evidence" \
  'Also calibrate its severity, not just its validity' "$MAXI_SKILL"
assert_pin_unique "over-grade: severity-calibrated record carries no skip_category (Loop-Exit gates ignore it)" \
  'it is a calibration record, not a skip' "$MAXI_SKILL"
# ── Meta-test (#157, AC2): widen the raw-guard audit from the park-calibration
# region fence to the WHOLE suite. #155 enforced helper-routing ONLY inside the
# PARKCAL_GUARD_REGION; the maxi_clamp / DEF_SKILL / IMPL_SKILL / INIT_SKILL /
# RA_SKILL / RW_SKILL / FDROOT guard families outside it could still ship a vacuous
# whole-file presence check (the PR #154 hole) with nothing to catch it. Now every
# raw presence/absence GUARD pin anywhere in this file must EITHER route through
# assert_pin_unique (so it carries no bare grep) OR carry an explicit per-line
# allowlist marker `# raw-guard-ok: <reason>`.
#
# Scope is deliberately the GUARD shape: a SKILL-targeted match whose yes/no outcome drives
# an `echo` ON THE SAME LINE. Two things are therefore out of scope *by construction* —
# their matched line carries no `echo`: a bare `grep -c`/`grep -n` whose count/line-number is
# the assert comparand directly (a bare `grep -cE` whose count IS the comparand, with no `echo`
# on the line — the version/changelog section-count asserts), and the inverting `grep -vF` strip.
# NOT every count guard is exempt this way, though: a `[ "$(grep -cF … "$DEF_SKILL")" -ge 2 ] &&
# echo yes` count guard (the deferred.labels `# raw-guard-ok: count-based` guards) DOES carry
# `echo` and a `_SKILL` target, so the scanner matches it and it is exempted by its
# `# raw-guard-ok: count-based` marker, not "by construction." A guard whose grep is computed on a PRIOR line into a var (`X=$(grep …
# "$SKILL")` then a bare `assert_eq … "$X"`) likewise carries no echo on the grep line and is
# non-idiomatic in this suite; that exact shape IS caught — positively, not by content match —
# inside the park-calibration region by the AC3 control below, where new park-calibration
# guards actually land.
#
# Anti-self-match: the scanner's pattern needs the literal `echo`, but its grep line
# references it as `$ECHO_TOK` (a variable) instead of spelling `echo` inline — so the
# scanner's OWN source line never carries a contiguous `grep…SKILL…echo` and is not
# counted when it scans this very file. It is the *variable indirection* that buys this,
# NOT the token's value (a plain `echo` value works; an inline literal `echo` in the
# pattern would self-match). Token-rot is the fragile spot: if `$ECHO_TOK` is typo'd to a
# non-matching value the pattern matches NOTHING and the SELF scan passes vacuously (a
# fail-OPEN), so the value is pinned by an explicit assert below rather than trusted —
# token-rot then fails RED at that pin, not silently. Marker-rot is the symmetric case and is
# caught by the SAME pin: a typo'd or emptied `RGOK_MARK` diverges from the pinned literal
# `raw-guard-ok` → the token assert goes RED directly. (Note the exclusion is `grep -vF "#
# $RGOK_MARK:"`, so an EMPTY `RGOK_MARK` yields the literal `# :`, NOT the empty string — it
# would not exempt every line; the token-value pin is what makes marker-rot loud, not any
# property of the exclusion on an empty token.)
ECHO_TOK="echo"                 # the scanner pattern's trailing token; referenced as $ECHO_TOK so no literal echo sits on the grep line
RGOK_MARK='raw-guard-ok'        # the per-line allowlist token; format is `# raw-guard-ok: <reason>`
# Pin both scanner tokens to their intended values: a typo in either — the rot the comment
# warns about — turns THIS assert RED, converting ECHO_TOK token-rot from a silent fail-open
# into a loud failure (the property the comment claims, now mechanically guaranteed).
assert_eq "meta(#157 AC2): scanner tokens are intact (ECHO_TOK/RGOK_MARK rot fails RED, not open)" \
  "echo|raw-guard-ok" "$ECHO_TOK|$RGOK_MARK"
count_unallowlisted_raw_skill_guards() {  # file -> count of raw SKILL guard pins neither routed nor allowlisted
  # Exclude only a PROPERLY-FORMATTED `# raw-guard-ok:` marker comment (not a bare substring
  # `raw-guard-ok` anywhere on the line), so a malformed/typo'd marker no longer silently
  # exempts its guard — it falls through to RED, strengthening the rot-guard above.
  grep -nE "grep[[:space:]].*(_SKILL|SKILL_|SKILL\.md).*$ECHO_TOK" "$1" \
    | grep -vF "# $RGOK_MARK:" \
    | grep -c . || true
}
assert_eq "meta(#157 AC2): no single-line echo-driven raw SKILL guard pin escapes assert_pin_unique or an allowlist marker (repo-wide)" \
  "0" "$(count_unallowlisted_raw_skill_guards "$SELF_SRC")"
# AC4 mutation proof: an UNMARKED raw guard written anywhere is detected (RED); the
# SAME line carrying the allowlist marker is exempted (0). The fixture SOURCE lines
# below carry the marker so the LIVE scan above skips them, while the string each
# writes to the temp file is what is actually scanned.
RWPROBE="$(probe_tmp '#157 AC2 unmarked-guard injection')"
printf '%s\n' '  "$(grep -qF UNMARKED_RAW "$MAXI_SKILL" && echo yes || echo no)"' > "$RWPROBE"  # raw-guard-ok: fixture writes an UNMARKED guard to a temp file to prove repo-wide detection
assert_eq "#157 AC2 mutation: an unmarked raw SKILL guard pin anywhere is detected (RED)" \
  "1" "$(count_unallowlisted_raw_skill_guards "$RWPROBE")"
printf '%s\n' '  "$(grep -qF MARKED_RAW "$MAXI_SKILL" && echo yes || echo no)"  # raw-guard-ok: proof' > "$RWPROBE"  # raw-guard-ok: fixture writes a MARKED guard to a temp file to prove the allowlist is honored
assert_eq "#157 AC2 mutation: the allowlist marker exempts a raw guard pin (GREEN, count 0)" \
  "0" "$(count_unallowlisted_raw_skill_guards "$RWPROBE")"
# #164-review gap: a guard targeting a `SKILL_`-suffixed loop var ($SKILL_FILE/$SKILL_NAME/
# $SKILL_DIR) carries no `_SKILL` substring (the underscore is AFTER `SKILL`), so the original
# two-arm pattern was BLIND to it (e.g. the live loop guard now marked `# raw-guard-ok: loop
# body`). Prove the broadened `SKILL_` arm catches it: an UNMARKED $SKILL_FILE guard → count 1.
# Under the old `(_SKILL|SKILL\.md)`-only pattern this fixture would read 0 (the regression this
# binds). The SOURCE line carries the marker so the live SELF scan above stays 0.
printf '%s\n' '  "$([ -f "$SKILL_FILE" ] && grep -qF LOOPVAR_RAW "$SKILL_FILE" && echo yes || echo no)"' > "$RWPROBE"  # raw-guard-ok: fixture writes an UNMARKED $SKILL_FILE guard to prove the broadened SKILL_ arm detects it
assert_eq "#157 AC2 mutation: broadened SKILL_ arm catches a \$SKILL_FILE-suffixed-var guard (not just _SKILL/SKILL.md)" \
  "1" "$(count_unallowlisted_raw_skill_guards "$RWPROBE")"
# #164-review: the THIRD arm — the literal `…/SKILL.md` path — also needs its own echo-driven
# fixture. The _SKILL and SKILL_ arms are proven above; without this, a regression specific to
# the SKILL\.md arm under the `.*echo` requirement could ship green. Unmarked literal-path guard
# with a trailing echo → count 1.
printf '%s\n' '  "$(grep -qF PATHLIT_RAW "$LIB/../skills/review-and-fix/SKILL.md" && echo yes || echo no)"' > "$RWPROBE"  # raw-guard-ok: fixture writes an UNMARKED literal-path …/SKILL.md guard to prove the SKILL.md arm detects it
assert_eq "#157 AC2 mutation: SKILL.md literal-path arm catches an unmarked …/SKILL.md guard (echo-driven)" \
  "1" "$(count_unallowlisted_raw_skill_guards "$RWPROBE")"
rm -f "$RWPROBE"
# #164-review: grep_present is an audit-bypass channel — its call site carries no bare `grep`
# token so the AC2 scanner skips it, and it asserts nothing about uniqueness. Pin the call-site
# count so a future edit cannot quietly route a NEW (possibly unique) pin through it to dodge
# assert_pin_unique; a third call site trips this until consciously bumped. The search token is
# split (concatenated) so THIS counting line does not itself self-match.
GP_CALL_TOK="grep_pres""ent '"
assert_eq "grep_present: invoked at exactly the 2 known compound MISSING-FILE call sites (audit-bypass channel pinned)" \
  "2" "$(grep -cF "$GP_CALL_TOK" "$SELF_SRC")"
# #164 re-review (finding #1): the count pin above stops a THIRD call site, but a future
# edit could repurpose one of the two existing calls to a different (possibly non-unique)
# presence pin — count stays 2, the AC2 scanner still skips it (no bare `grep` token), and a
# vacuous whole-file presence check ships through the bypass channel. Close it by also pinning
# each call's SHAPE — the exact literal it searches for — so neither call can be silently
# re-aimed. Tokens are split (concatenated) so these counting lines do not self-match.
GP_TOK_A="grep_pres""ent '(code-reviewer.md)'"
GP_TOK_B="grep_pres""ent 'plugin is installed in the executing environment'"
assert_eq "grep_present: call site A keeps the code-reviewer.md template literal (shape, not just count)" \
  "1" "$(grep -cF "$GP_TOK_A" "$SELF_SRC")"
assert_eq "grep_present: call site B keeps the review-SKILL presence literal (shape, not just count)" \
  "1" "$(grep -cF "$GP_TOK_B" "$SELF_SRC")"

# ── Meta-test (#157, AC3): a STRICTER in-region control. count_raw_skill_guards_in_region
# only catches a bare `grep … SKILL` ON a region line; it misses a pin whose grep is
# computed on a PRIOR line into a var (e.g. `X=$(grep … "$F")` then `assert_eq … "$X"`)
# — the bypass the #155 shadow pr-test-analyzer flagged. Close it positively: every
# statement-start line inside the region — at ANY indentation — must BEGIN with
# `assert_pin_unique` (the only routing allowed there). The `^[[:space:]]*` lead on both
# greps catches an INDENTED `  X=$(grep …)` assignment too, not just a column-0 one (the
# region's continuation-arg lines start with a quote and its comments with `#`, so neither
# is a statement-start — broadening stays 0 on a clean region). Both the grep-computing
# assignment and its assert_eq consumer are non-helper statement-starts, so either trips this.
# Anti-vacuity is DELEGATED, not standalone: this control reads 0 on a clean region AND on an
# emptied/marker-less one, so it relies on the pre-existing #155 marker-presence pins (the
# `pin_count "$PARKCAL_BMARK"/"$PARKCAL_EMARK" == 1` asserts) + the region-non-empty control to
# fail closed if the BEGIN/END markers are deleted. Do not remove those sibling pins — without
# them a vanished region would let this `== 0` assert pass vacuously.
count_region_nonhelper_stmts() {  # file -> region statement-start lines (any indent) not routed through assert_pin_unique
  region_lines "$1" \
    | grep -E '^[[:space:]]*[A-Za-z_]' \
    | grep -vc '^[[:space:]]*assert_pin_unique ' || true
}
assert_eq "meta(#157 AC3): every park-calibration region statement routes through assert_pin_unique (no grep-on-prior-line bypass)" \
  "0" "$(count_region_nonhelper_stmts "$SELF_SRC")"
# AC4 mutation proof: inject the two-line bypass shape — an INDENTED grep-computed var
# assignment AND its (column-0) assert_eq consumer — at the top of a temp copy's region;
# both are non-helper statement-starts, so the control must read 2 (RED). The indented inj1
# specifically binds the `^[[:space:]]*` broadening: under the old column-0-only anchor it
# would escape and the count would read 1, turning this proof RED. The injected awk strings
# carry no SKILL/echo so they do not perturb the repo-wide AC2 scan of this source.
NHPROBE="$(probe_tmp '#157 AC3 region-bypass injection')"
awk -v b="$PARKCAL_BMARK" \
    -v inj1='  INDENTED_BYPASS=$(grep -c X /dev/null)' \
    -v inj2='assert_eq "bypass" "yes" "$INDENTED_BYPASS"' \
    '{ print } index($0,b){ print inj1; print inj2 }' "$SELF_SRC" > "$NHPROBE"
assert_eq "#157 AC3 mutation: an (indented) grep-on-prior-line bypass in the region is detected (RED, count 2)" \
  "2" "$(count_region_nonhelper_stmts "$NHPROBE")"
rm -f "$NHPROBE"

# Issue #165 Part A + #170: the iter-<N>.json workpad carries a per-iteration
# loop_role field (fix | promoted). #170 gave it a real consumer —
# lib/efficiency-trace.jq derives AND surfaces it per iteration — so the field is
# no longer "legibility-only: no consumer reads it". Pin the field at its schema
# source-of-truth line and the Step 3 item 7 persist rule that writes it every
# iteration; mutation proof = delete either and the suite goes RED.
assert_pin_unique "loop_role: field + value set pinned at iter-N json schema source-of-truth" \
  '"loop_role": "fix | promoted"' "$MAXI_SKILL"
assert_pin_unique "loop_role: Step 3 item 7 persist rule writes it every iteration" \
  'the iteration role from the schema: fix for a normal fix iteration, promoted for a Decide-outcome-2 shadow-promoted iter' "$MAXI_SKILL"
# Issue #170: the loop_role legibility win is realized — efficiency-trace.jq now
# DERIVES + SURFACES loop_role per iteration, so SKILL.md no longer claims it is
# "legibility-only" (that became false the moment the jq surfaced the field). The
# now-false phrasing is gone from BOTH the note and Step 3 item 7 ("legibility-only"
# is unique to those two loop_role sites; the deferrals-manifest note "no consumer reads it" is the
# unrelated surviving occurrence and must stay), and the corrected note names
# efficiency-trace.jq as the deriving/surfacing consumer. Mutation proof =
# reintroduce "legibility-only" or drop the consumer mention → RED.
assert_eq "loop_role #170: SKILL.md no longer claims 'legibility-only' (note + Step 3 item 7 corrected)" "0" \
  "$(pin_count 'legibility-only' "$MAXI_SKILL")"
assert_pin_unique "loop_role #170: SKILL.md note names efficiency-trace.jq as the deriving/surfacing consumer" \
  'derives and surfaces it per iteration' "$MAXI_SKILL"

# Issue #165 Part B: Step 3 carries a recorded source-of-truth verify-step — a
# Phase-3 finding that prescribes changing existing documented behavior must be
# verified against its cited source of truth before it is applied, and a
# prescription that contradicts it is pushed back through the item-5 structured
# flow, not applied. Pin the load-bearing contract phrase and the by-name
# reference to the receiving-code-review principle it applies; mutation proof =
# paraphrase-gut either and the suite goes RED.
assert_pin_unique "verify-step: review-and-fix Step 3 verifies a reclassification against its cited source of truth" \
  'verify the prescription against its cited source of truth' "$MAXI_SKILL"
assert_pin_unique "verify-step: names the receiving-code-review verify-before-implementing principle" \
  'receiving-code-review verify-before-implementing principle' "$MAXI_SKILL"
# Pin Part B's load-bearing CONSEQUENCE clause too, not just the verify trigger:
# a revert that keeps "verify against source of truth" but drops the
# contradiction->pushback (not-applied) routing would otherwise stay GREEN, gutting
# the fail-safe. (pr-test-analyzer, PR #166 review.)
assert_pin_unique "verify-step: a contradicting prescription is pushed back, not applied" \
  'the source of truth is recorded as a pushback' "$MAXI_SKILL"

# Drift guard: issue #159's Step 3.5 fix-delta verification gate is the in-iteration
# delta-regression catch — after each iteration's fix commit a blinded subagent re-reviews
# ONLY the cumulative fix delta (with the loop's prior findings/fix-decisions/fixer reasoning
# withheld), so a fix-introduced #62/#98-class regression is caught in the SAME iteration
# instead of riding out to the end-of-loop shadow. Per issue #159 B3, every pin below routes
# through assert_pin_unique inside the FIXDELTA region (the meta-test above enforces the
# assert_pin_unique-only invariant for this region too), so a non-gate-unique literal FAILS
# by construction. Needles are apostrophe-free (the asserts single-quote them).
RCR_SKILL="$LIB/../skills/receiving-code-review/SKILL.md"
# FIXDELTA_GUARD_REGION_BEGIN — every SKILL pin until the END marker MUST use assert_pin_unique (meta-tested above)
assert_pin_unique "fix-delta gate: Step 3.5 heading present in review-and-fix SKILL" \
  '### Step 3.5: Fix-delta verification gate' "$MAXI_SKILL"
assert_pin_unique "fix-delta gate: fires on every iteration unconditionally" \
  'on **every iteration unconditionally**' "$MAXI_SKILL"
assert_pin_unique "fix-delta gate: blinded subagent reviews only the cumulative fix delta" \
  're-reviews **only the cumulative fix delta of this iteration**' "$MAXI_SKILL"
assert_pin_unique "fix-delta gate: delta is the cumulative iteration fix span (first-fix parent)" \
  'first** fix commit' "$MAXI_SKILL"
assert_pin_unique "fix-delta gate: operand-contract check (accepted-input subset of consumer)" \
  'accepted-input set that is a *subset* of its downstream consumer' "$MAXI_SKILL"
assert_pin_unique "fix-delta gate: surviving Critical/Important routes to same-iteration re-fix" \
  'routes back into the **same-iteration Step 3**' "$MAXI_SKILL"
assert_pin_unique "fix-delta gate: capped at 2 inner attempts" \
  'capped at 2 inner attempts' "$MAXI_SKILL"
assert_pin_unique "fix-delta gate: promote-on-cap to a normal iteration" \
  'promoted to a normal iteration' "$MAXI_SKILL"
assert_pin_unique "fix-delta gate: promoted iteration still terminates under the cap" \
  'still terminates under the cap' "$MAXI_SKILL"
assert_pin_unique "fix-delta gate: at-cap unresolved finding carried into the shadow (fail-closed)" \
  'the unresolved finding is **not** dropped' "$MAXI_SKILL"
assert_pin_unique "fix-delta gate: Suggestion/Minor recorded as advisory, no re-fix" \
  'recorded as advisory and does not trigger a re-fix' "$MAXI_SKILL"
assert_pin_unique "fix-delta gate: not counted toward the cap (verification of current iteration)" \
  'Step 3.5 and its inner attempts are verification of the current iteration' "$MAXI_SKILL"
assert_pin_unique "fix-delta gate: blinded subagent withholds prior findings/decisions/reasoning" \
  'fix decisions, and fixer reasoning' "$MAXI_SKILL"
assert_pin_unique "fix-delta gate: operational blinding withholds fix_decisions rows + rationale" \
  'do **NOT** include any' "$MAXI_SKILL"
assert_pin_unique "fix-delta gate: subagent-failure triggers exactly one bounded re-dispatch" \
  'triggers **exactly one bounded re-dispatch**' "$MAXI_SKILL"
assert_pin_unique "fix-delta gate: subagent-failure then records and proceeds to Step 4" \
  'and **proceed** to Step 4' "$MAXI_SKILL"
assert_pin_unique "fix-delta gate: deterministic delta-base failure gets a distinct breadcrumb" \
  'gate disabled this run, shadow is the backstop' "$MAXI_SKILL"
assert_pin_unique "fix-delta gate: whole-run failure degrades to the shadow (fail-open, no deadlock)" \
  'degrades to the Step 2.6 shadow as the safety net' "$MAXI_SKILL"
assert_pin_unique "fix-delta gate: no-fix iteration skips the gate (no delta to review)" \
  'skip the gate for that iteration' "$MAXI_SKILL"
assert_pin_unique "fix-delta gate: adversarial input-shape matrix check present" \
  'for hand-corruptible inputs' "$MAXI_SKILL"
assert_pin_unique "fix-delta gate: input-shape matrix pins the five-shape set" \
  '{object, array, scalar, missing, wrong-type}' "$MAXI_SKILL"
assert_pin_unique "fix-delta gate: input-shape matrix asserts fail-closed direction (not open)" \
  'not open, on each' "$MAXI_SKILL"
assert_pin_unique "fix-delta gate: per-iteration result recorded as a Devflow Reflection bullet" \
  'fix-delta gate clean' "$MAXI_SKILL"
assert_pin_unique "fix-delta gate: share-the-contract principle in receiving-code-review" \
  'prefer using that consumer as the guard itself' "$RCR_SKILL"
# FIXDELTA_GUARD_REGION_END — end of the assert_pin_unique-only fix-delta pin region

# Drift guard (issue #199): the Step 2.6 EARLY shadow trigger. On an
# `engine_self_modifying` PR the shadow fan-out runs once after iteration 1
# regardless of that iteration's verdict (including REJECT), feeding new blinded
# findings into iteration 2 — the convergence-time trigger is unchanged for all
# PRs and a non-engine PR keeps convergence-time-only. The contract has three
# load-bearing, independently-revertible sentences, each pinned below: (1) the
# fire condition (after-iteration-1, verdict-agnostic, gated on engine_self_modifying);
# (2) the no-double-run guard vs the convergence-time trigger; (3) the iteration
# accounting (early pass uncounted, the promoted iteration 2 counts). These use
# assert_pin_unique (one occurrence) so a deletion or paraphrase fails closed; the
# fire-condition sentence is additionally mutation-proven via assert_pin_red_on_removal.
assert_pin_unique "early-shadow #199: fire condition (after-iter-1, verdict-agnostic, engine_self_modifying-gated)" \
  'run the early shadow once after iteration 1 regardless of that iteration verdict, gated on engine_self_modifying' "$MAXI_SKILL"
assert_pin_red_on_removal "early-shadow #199: deleting the early-trigger fire condition turns its pin RED" \
  'run the early shadow once after iteration 1 regardless of that iteration verdict, gated on engine_self_modifying'
assert_pin_unique "early-shadow #199: no-double-run guard vs the convergence-time trigger (AC3)" \
  'only when the convergence-time trigger did not already run on iteration 1' "$MAXI_SKILL"
assert_pin_unique "early-shadow #199: promoted iteration 2 counts toward the cap; early pass uncounted (AC3)" \
  'promoted iteration 2 it spawns DOES count toward the cap' "$MAXI_SKILL"
# AC2 (review F2): the non-engine contract is carried by the Step 2.6 intro bullet — a
# SEPARATE, independently-revertible sentence from the fire-condition pin above. Without
# its own pin, an edit that broadens the early trigger to all PRs (deleting this clause
# while leaving the gated fire-condition intact) re-introduces the AC2 regression with the
# pins above still green. Pin the operative non-engine sentence.
assert_pin_unique "early-shadow #199: non-engine PR keeps convergence-time-only (AC2)" \
  'never runs the early trigger and keeps the convergence-time trigger only' "$MAXI_SKILL"
# Review F1 (silent-failure-hunter, Important): the early-trigger gate reads a best-effort
# iter-1.json flag whose schema default is false; without an explicit absent-flag rule a
# dropped iter-1 write would silently skip the early audit on exactly the engine PR it
# protects (fail-OPEN). The fix re-derives engine_self_modifying from the diff and trips
# rather than defaulting to false. This is a behavioral fail-open fix, so mutation-prove it.
assert_pin_unique "early-shadow #199: absent flag fails closed (re-derive, do not default false)" \
  're-derive `engine_self_modifying` from the diff itself' "$MAXI_SKILL"
assert_pin_red_on_removal "early-shadow #199: deleting the absent-flag fail-closed rule turns its pin RED" \
  're-derive `engine_self_modifying` from the diff itself'
# Shadow finding A (Important): the Step 4.5 sentence is the ONLY control-flow site that
# INVOKES the early trigger — every pin above guards the declarative subsection, not the
# call site. Reverting just the Step 4.5 wiring (e.g. a future Step 4.5 refactor) ships the
# feature DEAD with all the pins above still green. Pin the invocation site, mutation-proven.
assert_pin_unique "early-shadow #199: Step 4.5 invocation site wires the early trigger into the loop" \
  'run the Step 2.6 *early shadow trigger* first' "$MAXI_SKILL"
assert_pin_red_on_removal "early-shadow #199: deleting the Step 4.5 invocation site turns its pin RED" \
  'run the Step 2.6 *early shadow trigger* first'
# Shadow finding B: the $MAX_ITERS=1 edge clause (collapse to convergence-time-only, no
# orphan promotion) is a named contract clause in the CHANGELOG; pin it so a deletion that
# would let the early trigger promote a non-existent iteration 2 at cap=1 fails closed.
assert_pin_unique "early-shadow #199: \$MAX_ITERS=1 edge collapses to convergence-time-only" \
  'never spawns a pass it has nowhere to feed' "$MAXI_SKILL"

# Drift guard: the step 8 Verification Gate (issue #178; renumbered from step 7 by #196,
# which inserted a RECORD DEFERRALS step before it) — the Iron Law, its scope
# sentence, the code-fence verify entry, the engine re-run attribution, the
# CI-fallback consequence clause, the CI-fallback trigger restriction, the
# Forbidden Responses entry, the local-skip audit note, and the push-vs-observe
# distinction are the gate's load-bearing contracts (9 pins); any can be silently
# deleted or paraphrased without breaking any other pin.
# assert_pin_unique makes that RED.
assert_pin_unique "step8: verification gate Iron Law heading present" \
  'NO COMPLETION CLAIMS WITHOUT FRESH VERIFICATION EVIDENCE' "$RECV_SKILL"
assert_pin_unique "step8: verification gate applies in both interactive and fix-loop contexts" \
  'applies in both interactive sessions and the autonomous' "$RECV_SKILL"
assert_pin_unique "step8: code-fence step 8 entry anchors both mandated actions (diff review + test suite)" \
  'Review diff against addressed findings + run test suite — only then claim completion' "$RECV_SKILL"
assert_pin_unique "step8: loop satisfies diff-review via engine re-run (not Step 3.5)" \
  'the review engine re-runs each iteration' "$RECV_SKILL"
assert_pin_unique "step8: CI-fallback clause requires waiting for green before claiming completion" \
  'do not claim completion until CI confirms green' "$RECV_SKILL"
assert_pin_unique "step8: CI-fallback trigger restricted to genuine denial, not suite failures" \
  'never when the suite runs but fails' "$RECV_SKILL"
assert_pin_unique "step8: forbidden-responses entry prohibits claiming done before step 8" \
  'before step 8 (VERIFY BEFORE DONE) is complete' "$RECV_SKILL"
assert_pin_unique "step8: CI-fallback local-skip requires an auditable recorded note" \
  'Record the local-skip reason as an auditable note' "$RECV_SKILL"
assert_pin_unique "step8: CI-fallback: submitting a push is not the same as observing green" \
  'submitting a push is not the same as observing green' "$RECV_SKILL"

# Drift guards (issue #196): the convergence-discipline additions to the vendored
# receiving-code-review skill — a stopping rule, a Record-Every-Deferral contract, the
# Response-Pattern RECORD DEFERRALS step, and the cross-iteration finding union. Each is
# SKILL prose with no behavioral test surface (the skill ships to consumer repos), so an
# assert_pin_unique on the operative sentence is the drift guard: deleting or paraphrasing
# the load-bearing clause drops the count to 0 and fails closed. Literals are gate-unique,
# apostrophe-free ASCII, and engine-agnostic (no DevFlow machinery named in the pinned text).
assert_pin_unique "convergence #196: stopping-rule section heading present" \
  '## Stop When the Verdict Is Already Non-Blocking' "$RECV_SKILL"
assert_pin_unique "convergence #196: stopping rule re-opens only for Critical/blocking/demonstrable defects" \
  'or a demonstrable correctness defect (one that cites a concrete failing input)' "$RECV_SKILL"
assert_pin_unique "convergence #196: stopping rule bounds advisory re-opens, never address-all-the-notes" \
  'never "address all the notes," which guarantees' "$RECV_SKILL"
assert_pin_unique "convergence #196: stopping rule parks everything else (advisory note does not by itself re-open)" \
  'does not, by itself, re-open the diff' "$RECV_SKILL"
assert_pin_unique "convergence #196: Record Every Deferral section heading present" \
  '## Record Every Deferral' "$RECV_SKILL"
assert_pin_unique "convergence #196: deferral record names WHAT/WHY/revisit-condition" \
  'naming WHAT was deferred, WHY, and the condition that would make it worth revisiting' "$RECV_SKILL"
assert_pin_unique "convergence #196: deferral has a preference-ordered list of trace locations" \
  'in order of preference, to the first channel available' "$RECV_SKILL"
assert_pin_unique "convergence #196: a successful pushback is itself a recorded deferral" \
  'A successful pushback is itself a deferral' "$RECV_SKILL"
assert_pin_unique "convergence #196: Response Pattern gains a RECORD DEFERRALS step before verify/done" \
  '7. RECORD DEFERRALS: For every finding you did NOT fix' "$RECV_SKILL"
assert_pin_unique "convergence #196: cross-iteration union section heading present" \
  '## Union Findings Across Review Iterations' "$RECV_SKILL"
assert_pin_unique "convergence #196: union treats raised-before-never-resolved-still-true as escalating" \
  'raised in a prior run and never resolved, still true' "$RECV_SKILL"
assert_pin_unique "convergence #196: union does not retire a finding a later run ranked lower" \
  'it does not retire just because a later run happened to rank it lower' "$RECV_SKILL"
assert_pin_unique "convergence #196: push-back reinforcement records the pushback as a deferral" \
  'an un-recorded pushback is re-raised identically next run' "$RECV_SKILL"

# ── Drift guards (issue #197): the symmetric premise-verification additions to the vendored
# receiving-code-review skill — (outward) verify a reviewer's cited convention before
# reshaping code to match it, and (inward) verify your own diff's claims against HEAD, with a
# stale-claim/contradicts-HEAD finding classed as blocking. Each is SKILL prose with no
# behavioral test surface (the skill ships to consumer repos), so an assert_pin_unique on the
# operative clause is the mutation-proven drift guard: deleting or paraphrasing the
# load-bearing clause drops the count to 0 and fails closed. Literals are gate-unique,
# apostrophe-free ASCII, and engine-agnostic (no DevFlow machinery named in the pinned text).
# AC1 (outward): the External-Reviewers checklist greps for a cited convention before honoring it.
assert_pin_unique "premise #197: External-Reviewers checklist greps to confirm a cited convention exists" \
  'grep the repo to confirm that convention actually exists before reshaping code to match it' "$RECV_SKILL"
assert_pin_unique "premise #197: push back on a non-existent convention with the file real pattern" \
  'Do not reshape code to match an aspirational or non-existent standard' "$RECV_SKILL"
# AC1 requires the push-back to CITE the file's real pattern as evidence, not merely to
# refuse the reshape — pin that evidence clause too, so a regression dropping it fails RED.
assert_pin_unique "premise #197: push-back cites the file real pattern as evidence" \
  'real, uniform pattern as evidence' "$RECV_SKILL"
# AC2 (inward): the Verification Gate verifies the diff own claims against HEAD before done.
assert_pin_unique "premise #197: Verification Gate verifies own diff claims against HEAD" \
  'Treat every documentation, comment, changelog, or PR-body assertion the change adds or relies on as a claim to verify against HEAD' "$RECV_SKILL"
assert_pin_unique "premise #197: own-claim gate calls out the remains-unscoped/still-broken/unhandled shape" \
  'X remains unscoped / is still broken / is unhandled' "$RECV_SKILL"
# AC3 (triage): a stale-claim/contradicts-HEAD/contradicts-this-change finding is blocking, never advisory.
# Pin the FULL three-arm enumeration (stale / contradicts HEAD / contradicts another part)
# together with the blocking classification, so dropping ANY arm — not just the tail — fails
# the pin RED (AC3 enumerates all three arms; a tail-only pin would under-cover the contract).
assert_pin_unique "premise #197: triage classes a stale/contradicts-HEAD claim finding as blocking" \
  'stale, contradicts HEAD, or contradicts another part of this change is blocking' "$RECV_SKILL"
# PR #211 review notes: pin the two operative CONSEQUENCE clauses that make the contract
# actionable — a paraphrase keeping the framing while softening these would gut the contract
# with the pins above still GREEN. (1) AC3's re-open consequence (the tail that forces the diff
# back open on an already-passing verdict); (2) AC2's severity framing (what makes a documented
# falsehood actionable rather than cosmetic).
assert_pin_unique "premise #197: stale-claim finding re-opens the diff even on an already-passing verdict" \
  'it re-opens the diff even on an otherwise already-passing verdict' "$RECV_SKILL"
assert_pin_unique "premise #197: own-claim gate frames a documented falsehood as a correctness defect, not cosmetic" \
  'A documented falsehood is a correctness defect in the deliverable, not a cosmetic nit' "$RECV_SKILL"

# ── Drift guards: the "A Fix Is New Code" section in the vendored receiving-code-review
# skill — generalizes the "treat your fix as new code; do not punt a fix-introduced defect
# to the next pass" disposition beyond the Share-the-Contract guard case to the deletion-strands,
# contract-ripple, and silent-failure classes. SKILL prose with no behavioral test surface (the
# skill ships to consumer repos), so an assert_pin_unique on each operative clause is the
# mutation-proven drift guard: deleting or paraphrasing it drops the count to 0 and fails closed.
# Literals are gate-unique, apostrophe-free ASCII, and engine-agnostic (no DevFlow machinery in
# the pinned text — the section keeps "an automated fix-delta gate, if your loop has one" generic).
assert_pin_unique "fix-as-new-code: section heading present in receiving-code-review" \
  '## A Fix Is New Code' "$RECV_SKILL"
assert_pin_unique "fix-as-new-code: core disposition scrutinizes the fix delta as new code" \
  'give the fix delta the same scrutiny you would give any new code you wrote' "$RECV_SKILL"
assert_pin_unique "fix-as-new-code: deletion class re-reads the unit and greps for stranded references" \
  'grep for references to anything you removed' "$RECV_SKILL"
assert_pin_unique "fix-as-new-code: anti-punt clause (do not lean on a later pass to find a fix-introduced defect)" \
  'to find a defect your fix introduced' "$RECV_SKILL"

# ── Drift guards (issue #167): the completeness-critic pass (shared engine) and the
# mechanism-scoped self-authored-claim re-sweep (fix loop). Both are SKILL-prose engine
# behaviors; pin the load-bearing contract literals so a silent paraphrase or deletion that
# guts either check fails the suite. Each literal is target-unique and apostrophe-free (the
# CLAUDE.md single-quote gotcha), so assert_pin_unique fails closed on a deleted OR
# duplicated literal. REVIEW_SKILL is the shared engine; the two checks must NOT be
# paraphrased across the two skills (the fix loop inherits the engine by reference).
REVIEW_SKILL="$LIB/../skills/review/SKILL.md"
SHADOW_DOC="$LIB/../docs/shadow-review.md"
# AC1: Phase 0.5 classifies the detect-all-audit shape with a concrete, twice-applicable rule
# (the enumerate-a-population AND assert-completeness combination is the load-bearing signal).
assert_pin_unique "#167 critic: Phase 0.5 states the detect-all-audit classification rule concretely" \
  'enumerate-a-population* AND *assert-it-is-complete' "$REVIEW_SKILL"
# AC2: the forced completeness-critic pass exists, re-enumerates INDEPENDENTLY of the audit's
# own pattern, and records an uncovered member as a review finding.
assert_pin_unique "#167 critic: Phase 3.1.5 completeness-critic pass heading present" \
  '### 3.1.5 Completeness-critic pass (forced when' "$REVIEW_SKILL"
assert_pin_unique "#167 critic: pass re-enumerates by an INDEPENDENT signal (not the audit's pattern)" \
  're-enumerate that population by a signal OTHER than the' "$REVIEW_SKILL"
assert_pin_unique "#167 critic: an uncovered member of the independent set is a review finding" \
  'Every member of the independent set that the audit does not cover is a review finding' "$REVIEW_SKILL"
# Pin the superset-comparison FRAMING itself (the verdict step), not only its finding
# clause: a reword to a weaker check (e.g. "spot-check a few members") that left the
# finding sentence intact would otherwise stay GREEN.
assert_pin_unique "#167 critic: pass asserts the audit matched set is a SUPERSET of the independent enumeration" \
  '⊇ your independent enumeration' "$REVIEW_SKILL"
# AC3: the critic lives in the shared engine (reachable from both skills) AND is not
# paraphrased into the fix-loop skill — the pass heading must be absent from review-and-fix.
assert_pin_unique "#167 critic: shared engine states both skills apply it without a fix-loop paraphrase" \
  'apply it without any paraphrase in the fix-loop skill' "$REVIEW_SKILL"
# Guard the two absence pins below against vacuous-pass (pin_count returns 0 on a missing
# file): prove $MAXI_SKILL is readable and non-empty before asserting absence of a literal.
assert_eq "#167 critic: MAXI_SKILL file is readable (sentinel for absence-pin vacuity guard)" \
  "1" "$(pin_count 'Mechanism-scoped self-authored-claim re-sweep' "$MAXI_SKILL")"
assert_eq "#167 critic: completeness-critic pass heading is NOT paraphrased into review-and-fix SKILL" \
  "0" "$(pin_count '### 3.1.5 Completeness-critic pass (forced when' "$MAXI_SKILL")"
# The exact-heading absence above catches only a verbatim heading copy; a genuine reworded
# paraphrase of the critic PROCEDURE would slip it. Add a paraphrase-resistant negative
# pin: the critic's distinctive independent-enumeration clause must also be absent from the
# fix-loop skill (it is procedure text, not a by-name reference, so a legitimate pointer to
# "the completeness-critic pass" does not trip it — only a copied procedure would).
assert_eq "#167 critic: critic PROCEDURE (independent-enumeration clause) is NOT paraphrased into review-and-fix SKILL" \
  "0" "$(pin_count 're-enumerate that population by a signal OTHER than the' "$MAXI_SKILL")"
# AC4: the fix loop (Step 3) specifies the mechanism-scoped re-sweep, located by the
# mechanism's identifiers across the touched files (identifier-located, not hunk-located).
assert_pin_unique "#167 re-sweep: Step 3 names the mechanism-scoped self-authored-claim re-sweep" \
  'Mechanism-scoped self-authored-claim re-sweep' "$MAXI_SKILL"
assert_pin_unique "#167 re-sweep: located by identifiers across touched files, not the fix's hunks" \
  'identifier-located, not hunk-located' "$MAXI_SKILL"
# AC5: the re-sweep is the existing comment-analyzer dispatch (no new agent), and a comment
# still describing the pre-change mechanism is a finding.
assert_pin_unique "#167 re-sweep: re-dispatches the existing devflow:comment-analyzer agent" \
  'Re-dispatch `devflow:comment-analyzer`' "$MAXI_SKILL"
assert_pin_unique "#167 re-sweep: no new agent is introduced" \
  'no new agent is introduced' "$MAXI_SKILL"
assert_pin_unique "#167 re-sweep: a comment still describing the pre-change mechanism is a finding" \
  'A comment that still describes the pre-change mechanism is a finding' "$MAXI_SKILL"
# AC6: docs/shadow-review.md describes both checks at the guarantee level they provide — and
# does NOT overstate (the two guarantee-scope caveats are the no-catch-all anchors).
assert_pin_unique "#167 docs: completeness-critic guarantee-scope caveat (not exhaustive)" \
  'It does not prove the audit is exhaustive' "$SHADOW_DOC"
assert_pin_unique "#167 docs: re-sweep guarantee-scope caveat (not a repo-wide audit)" \
  'It is not a repo-wide comment audit' "$SHADOW_DOC"
# Core-invariant pins (the contracts that make the new behavior actually fire/aggregate):
# (a) detect_all_audit is ADDITIVE — a revert that demoted it to an override (or let a lean
#     profile suppress the critic pass) would silently re-open the exact "detect-all audit on
#     a small diff escapes review" defect #167 exists to close, with the suite still green;
# (b) the critic finding is COLLECTED in Phase 3.2 (the bridge into Phase 4 aggregation) —
#     drop it and the pass runs but its finding never enters the graded set (inert);
# (c) the re-sweep's comment-analyzer dispatch is ADVISORY-only — the clause reconciling it
#     with the fix-loop "fixes are never delegated to a subagent" rule.
assert_pin_unique "#167 critic: detect_all_audit is additive (never suppressed by a lean profile)" \
  'additive, never suppressed' "$REVIEW_SKILL"
assert_pin_unique "#167 critic: the critic finding is collected in Phase 3.2 (flows into aggregation)" \
  'completeness-critic pass ran and produced a finding' "$REVIEW_SKILL"
assert_pin_unique "#167 re-sweep: the comment-analyzer dispatch is advisory (analyzes and reports only)" \
  'analyzes and reports only' "$MAXI_SKILL"
assert_pin_unique "#167 re-sweep: the advisory dispatch does not violate the no-subagent-fix rule (reconciliation clause)" \
  'does not violate the rule that fixes are applied directly and never delegated to a subagent' "$MAXI_SKILL"
# Suggestion S1 (PR #175 review): pin the two critic procedure steps that were unpinned —
# step 1 (name the target population) and step 4 (not-a-proof-of-exhaustiveness caveat).
# A rewrite that drops step 1 would silently remove the explicit population-naming mandate;
# a rewrite that drops step 4 would let the clean-critic note overclaim exhaustiveness.
assert_pin_unique "#167 critic: step 1 requires naming the target population and completeness property" \
  'Name the audit'\''s target population and its completeness property' "$REVIEW_SKILL"
assert_pin_unique "#167 critic: step 4 caveat — a clean result is not a proof of exhaustiveness" \
  'This is **not** a proof of exhaustiveness' "$REVIEW_SKILL"
# (d) the Phase 0.5 *table row* is the operative dispatch contract an orchestrator reads to
#     decide the profile — pin the ROW itself, not only its prose restatement
#     (the `additive, never suppressed` pin above). A revert that demoted the row to an
#     override (re-opening the "detect-all audit on a lean diff escapes review" defect) would
#     leave the prose pin GREEN while the actual lookup table no longer forces the pass.
# (e) the Phase 0.5 rule's negative-shape exclusion — a paraphrase that dropped it would
#     silently WIDEN detect_all_audit to fire on every grep (forcing the critic on ordinary
#     diffs), and stay green.
assert_pin_unique "#167 critic: Phase 0.5 TABLE ROW forces the pass (a forced extra pass, never an override)" \
  'a *forced extra pass*, not a checklist or cost override' "$REVIEW_SKILL"
assert_pin_unique "#167 critic: Phase 0.5 rule excludes the false-positive shapes (single-target grep / fixed list)" \
  'a check over a fixed hand-listed set is **not** this shape' "$REVIEW_SKILL"
# Mutation proofs (AC2/AC7 guarantee-class): deleting a load-bearing contract literal turns
# its pin RED. The third arg routes the removal through the relevant file (the generalized
# helper defaults to $MAXI_SKILL when omitted). These exercise the engine-prose pins above on
# the path each is meant to catch — a paraphrase that drops the independence requirement, the
# finding clause, or the re-sweep contract goes RED, not silently GREEN.
assert_pin_red_on_removal "#167 AC3-mp: deleting the independent-enumeration requirement turns its critic pin RED" \
  're-enumerate that population by a signal OTHER than the' "$REVIEW_SKILL"
assert_pin_red_on_removal "#167 AC3-mp: deleting the uncovered-member-is-a-finding clause turns its critic pin RED" \
  'Every member of the independent set that the audit does not cover is a review finding' "$REVIEW_SKILL"
assert_pin_red_on_removal "#167 AC3-mp: deleting the re-sweep identifier-located clause turns its pin RED" \
  'identifier-located, not hunk-located'
assert_pin_red_on_removal "#167 AC3-mp: deleting the stale-comment-is-a-finding clause turns its pin RED" \
  'A comment that still describes the pre-change mechanism is a finding'
assert_pin_red_on_removal "#167 AC2-mp: deleting the superset-comparison framing turns its pin RED" \
  '⊇ your independent enumeration' "$REVIEW_SKILL"
assert_pin_red_on_removal "#167 core-mp: deleting the additive/never-suppressed rule turns its pin RED" \
  'additive, never suppressed' "$REVIEW_SKILL"
assert_pin_red_on_removal "#167 core-mp: deleting the Phase 3.2 critic-finding inclusion clause turns its pin RED" \
  'completeness-critic pass ran and produced a finding' "$REVIEW_SKILL"
assert_pin_red_on_removal "#167 core-mp: deleting the re-sweep advisory-only clause turns its pin RED" \
  'analyzes and reports only'
assert_pin_red_on_removal "#167 core-mp: deleting the Phase 0.5 table-row dispatch contract turns its pin RED" \
  'a *forced extra pass*, not a checklist or cost override' "$REVIEW_SKILL"
assert_pin_red_on_removal "#167 core-mp: deleting the false-positive-shape exclusion turns its pin RED" \
  'a check over a fixed hand-listed set is **not** this shape' "$REVIEW_SKILL"
# #186: the implement skill's behavioral-fix-pin sub-rule is itself a multi-sentence behavioral
# property, so by its own "at least one pin per operative sentence" rule each DIRECTIVE sentence
# (the text that tells the implementer what to DO) gets its own removal-proof pin; the
# definitions/rationale/history that merely elaborate them stay unpinned (pinning every clause
# is the over-pinning treadmill the issue warns against). assert_pin_red_on_removal (not bare
# assert_pin_unique) bakes step (c) of the rule — "half-revert and confirm RED" — into the
# suite permanently, instead of leaving it a one-time authoring act. ($DEF_SKILL = the implement
# SKILL.md; defined at the top of this file.)
assert_pin_red_on_removal "#186 behavioral-fix-pin: deleting 'pin the operative sentence, not framing' turns its pin RED" \
  'pin the operative sentence, not an adjacent framing clause' "$DEF_SKILL"
assert_pin_red_on_removal "#186 behavioral-fix-pin: deleting the (a)/(b)/(c) counterfactual procedure turns its pin RED" \
  'counterfactually half-revert' "$DEF_SKILL"
assert_pin_red_on_removal "#186 behavioral-fix-pin: deleting the at-least-one-pin-per-operative-sentence rule turns its pin RED" \
  'at least one pin per operative sentence' "$DEF_SKILL"
assert_pin_red_on_removal "#186 behavioral-fix-pin: deleting the behavioral-fix-pin scope limiter turns its pin RED" \
  'literal constants, token names, count-based guards, absence pins' "$DEF_SKILL"
# #194: two additions HARDEN the #186 mutation-check guidance — each is its own operative
# DIRECTIVE sentence, so each gets a removal-proof pin (the rule pins itself). (A) bake the
# half-revert into the suite via the framework's removal-proof assertion, not a one-time manual
# act; (B) confirm a newly-added guard REGISTERED — its named assertion appears as PASS and the
# assertion count rose — because a green suite alone does not prove a guard ran. Both additions
# are COUPLED across the two skills (implement = $DEF_SKILL, review-and-fix = $MAXI_SKILL), so the
# same operative literal pins each file; assert_pin_red_on_removal requires it appear exactly once
# per file. Pinning (B)'s sentence with a *registering* assertion dogfoods the rule it states.
assert_pin_red_on_removal "#194 (A) implement: deleting the bake-via-removal-proof-assertion directive turns its pin RED" \
  "your framework's removal-proof assertion" "$DEF_SKILL"
assert_pin_red_on_removal "#194 (B) implement: deleting the confirm-guard-registered directive turns its pin RED" \
  'confirm the guard registered' "$DEF_SKILL"
assert_pin_red_on_removal "#194 (A) review-and-fix: deleting the bake-via-removal-proof-assertion directive turns its pin RED" \
  "your framework's removal-proof assertion" "$MAXI_SKILL"
assert_pin_red_on_removal "#194 (B) review-and-fix: deleting the confirm-guard-registered directive turns its pin RED" \
  'confirm the guard registered' "$MAXI_SKILL"
# (B) is a two-conjunct directive ("named assertion appears as PASS" AND "the assertion
# count rose") — by the rule's own "at least one pin per operative sentence", the count-rose
# conjunct is a distinct operative clause (the anti-vacuity signal a guard actually REGISTERED,
# not merely that some PASS line is present), so it carries its own pin literal: a future edit that
# drops only that clause makes the literal absent, turning this pin RED on the next suite run, rather
# than leaving (B) silently weakened to a presence-only check. (The helper's grep -vF strips the whole
# physical line; what each pin proves is its own literal's present->absent => PASS->FAIL transition.)
assert_pin_red_on_removal "#194 (B) implement: deleting the assertion-count-rose conjunct turns its pin RED" \
  "the suite's assertion count rose" "$DEF_SKILL"
assert_pin_red_on_removal "#194 (B) review-and-fix: deleting the assertion-count-rose conjunct turns its pin RED" \
  "the suite's assertion count rose" "$MAXI_SKILL"
# (B)'s OTHER conjunct — "its named assertion appears in the run as a PASS" — is operatively
# distinct from count-rose (it catches the case where the count rose but the assertion that
# passed is not the one you added; count-rose catches the case where nothing new ran), so by
# the same one-pin-per-operative-sentence rule it gets its own per-file pin. The two skills word
# the clause slightly differently (implement: "actually appears"; review-and-fix: "appears"),
# so the per-file literals differ — each verified to appear exactly once in its own file.
assert_pin_red_on_removal "#194 (B) implement: deleting the named-assertion-appears-as-PASS conjunct turns its pin RED" \
  'its named assertion actually appears in the run as a PASS' "$DEF_SKILL"
assert_pin_red_on_removal "#194 (B) review-and-fix: deleting the named-assertion-appears-as-PASS conjunct turns its pin RED" \
  'its named assertion appears in the run as a PASS' "$MAXI_SKILL"
# #235 (finding A): the forced per-behavioral-fix-pin operative-sentence NOTE — before writing
# a behavioral-fix pin the author records a one-line workpad --note naming the operative
# sentence and asserting the pin literal is a substring of it (the same auditable-commitment
# idiom as the sweep-selection / test-first notes). COUPLED across the implement skill's Phase
# 2.3 (phase-2-implement.md, inside $DEF_SKILL) and the review-and-fix fix loop's Step 3 item 4
# ($MAXI_SKILL), so the same operative literal pins each — a half-revert that drops the
# directive from either file turns its pin RED. This clause is itself a behavioral-fix pin, so
# per finding A's own rule the literal targets the operative NOTE directive, not its framing.
assert_pin_red_on_removal "#235 (A) implement: deleting the forced operative-sentence-note directive turns its pin RED" \
  'naming the operative sentence and asserting the pin literal is a substring of it' "$DEF_SKILL"
assert_pin_red_on_removal "#235 (A) review-and-fix: deleting the forced operative-sentence-note directive turns its pin RED" \
  'naming the operative sentence and asserting the pin literal is a substring of it' "$MAXI_SKILL"
# #235 (finding B): the Phase 3.3 observability-persistence backstop — after the inline
# review-and-fix loop returns, verify the run's telemetry artifacts were persisted, run
# lib/efficiency-trace.sh --persist when they are missing, and record a dropped-failed
# reflection when even --persist has no iter-*.json inputs. Two operative DIRECTIVE sentences
# (run-the-backstop / record-the-gap), so one removal-proof pin each (per finding A's own
# "at least one pin per operative sentence" rule the new clause must obey). Both sentences
# live in phases/phase-3-review.md, i.e. inside $DEF_SKILL (the implement bundle).
assert_pin_red_on_removal "#235 (B) phase-3.3: deleting the run-the-persist-backstop directive turns its pin RED" \
  'run the efficiency-trace persist backstop when they are missing' "$DEF_SKILL"
assert_pin_red_on_removal "#235 (B) phase-3.3: deleting the dropped-failed-reflection directive turns its pin RED" \
  'reflection naming the observability gap' "$DEF_SKILL"
# #235 (finding B, executable surface): the two prose pins above pin the DIRECTIVE; a
# half-revert could break the actual bash code block that IMPLEMENTS the backstop while the
# prose stays intact (the exact framing-only-pin class this PR closes, applied to code). So
# pin the executable tokens the backstop stands on — the --persist invocation, the
# this-run-scoped no-inputs detector, and the dropped-failed reflection emission.
# These are literal-constant/token pins (not operative-sentence pins), so assert_pin_unique
# is the right form and no operative-vs-framing note is required (the finding-A carve-out).
assert_pin_unique "#235 (B) phase-3.3: the --persist backstop command is actually invoked" \
  '"$LIB/efficiency-trace.sh" --persist' "$DEF_SKILL"
# The "no inputs" detector is THIS-RUN-SCOPED (#236 review): it snapshots the pre-existing
# iter-*.json BEFORE the inline loop and, after, records a loss only when NO NEW iter-*.json
# appeared (comm -13 vs the snapshot). A whole-tree presence check would let a prior-run
# leftover on the persistent local tier mask a genuine loss. The glob now appears in TWO
# lines (snapshot + detector), so the bare glob substring is no longer unique — pin each full
# line instead. The detector-line pin also captures the operative condition SENSE (`[ -z … ]`
# over the comm-diff): a half-revert flipping the sense (-z→-n) or dropping the snapshot diff
# turns the suite RED — closing the framing-only-pin gap on the guard's condition itself
# (this PR's own lesson, applied to the detector sense; #236 pr-test-analyzer note).
assert_pin_unique "#235 (B) phase-3.3: pre-loop snapshot captures pre-existing iter-*.json before the inline loop" \
  'compgen -G "$ROOT/.devflow/tmp/review/*/*/iter-*.json" 2>/dev/null | sort > "$ROOT/.devflow/tmp/.phase33-iters-before"' "$DEF_SKILL"
assert_pin_unique "#235 (B) phase-3.3: no-inputs detector is this-run-scoped (comm -13 vs snapshot) AND fail-closed on empty (-z)" \
  'if [ -z "$(compgen -G "$ROOT/.devflow/tmp/review/*/*/iter-*.json" 2>/dev/null | sort | comm -13 "$BEFORE" -)" ]; then' "$DEF_SKILL"
assert_pin_unique "#235 (B) phase-3.3: the no-inputs case emits the dropped-failed telemetry-lost reflection" \
  'lib/efficiency-trace.sh --persist had no inputs' "$DEF_SKILL"
# The detector references $ROOT and $BEFORE literally, so it stays GREEN even if the $ROOT
# *derivation* were reverted to a cwd-relative form (e.g. `ROOT=$(pwd)`), silently defeating
# the repo-root anchoring that keeps the detector congruent with --persist. $ROOT is now
# derived in BOTH backstop bash blocks (the pre-loop snapshot and the post-return detector,
# separate shells), so pin the derivation with a count of exactly 2 — a half-revert of either
# occurrence turns the suite RED, the same framing-vs-fix lesson applied to the producer line.
assert_eq "#235 (B) phase-3.3: the no-inputs detector root is derived from the git toplevel (not cwd), in both blocks" \
  "2" "$(pin_count 'ROOT=$(git rev-parse --show-toplevel' "$DEF_SKILL")"
# Symmetric to the $ROOT-derivation pin: the `"$LIB/efficiency-trace.sh" --persist` invocation
# pinned above depends on the `LIB=` derivation that resolves it. Pin that derivation too so a
# half-revert of the anchor (breaking the backstop invocation while the invocation-token pin
# stays GREEN) turns the suite RED — the same half-revert class the $ROOT pin closes.
assert_pin_unique "#235 (B) phase-3.3: the --persist backstop's LIB anchor is derived from the skill dir" \
  'LIB="${CLAUDE_SKILL_DIR}/../../lib"' "$DEF_SKILL"
# #236 review (iteration 3): the snapshot-absent degrade path is a documented-falsehood defect —
# the adjacent comment claimed "fail-toward-surfacing, never masking" while the code actually
# CAN mask a real this-run loss (an empty BEFORE snapshot makes comm -13 count any leftover
# iter-*.json from a prior local run as "new", suppressing the -z reflection check even when
# this run wrote nothing). The fix corrects the comment AND emits a distinct ::warning:: on the
# snapshot-absent path so the degrade is visible on the run log instead of being silently
# indistinguishable from the healthy case. Pin both halves: the false claim must be gone, and
# the new warning breadcrumb must be present.
assert_eq "#235/#236 (B) phase-3.3: the false 'fail-toward-surfacing, never masking' claim is gone" \
  "0" "$(pin_count 'fail-toward-surfacing, never masking' "$DEF_SKILL")"
assert_pin_unique "#235/#236 (B) phase-3.3: snapshot-absent degrade emits a distinct MASK warning breadcrumb" \
  'no-inputs detector degrades to whole-tree presence, which can MASK a real this-run telemetry loss' "$DEF_SKILL"
# #236 review (iteration 4, silent-failure-hunter Finding 2 + pr-test-analyzer mutation-tested
# gap): two hardenings to the Phase 3.3 observability backstop.
#
# (a) ORDERING: the backstop's core invariant is that it runs UNCONDITIONALLY — "regardless of
# the verdict" — before the verdict branches, not only on an approve-family outcome. Presence-only
# pins on the two directive sentences stay GREEN even if a half-revert moved the backstop inside
# the approve branch (mutation-tested by the #236 review's pr-test-analyzer: swapping "regardless
# of the verdict" for "only on approve" left the full suite green). Assert the ordering
# positionally in the OWNING file (phase-3-review.md), not the multi-file bundle, so both
# endpoints are unique in one coordinate space (mirrors the "implement_pr_state: clean-tree
# backstop precedes the publish gate" positional pin elsewhere in this file).
P33_BACKSTOP_LN=$(grep -nF 'So regardless of the verdict, first' "$LIB/../skills/implement/phases/phase-3-review.md" | head -1 | cut -d: -f1)
P33_VERDICT_BRANCH_LN=$(grep -nF 'After the skill completes with a clean approve-family verdict' "$LIB/../skills/implement/phases/phase-3-review.md" | head -1 | cut -d: -f1)
assert_eq "#236 (B) phase-3.3: observability backstop directive precedes the approve-family verdict branch (runs unconditionally)" "yes" \
  "$([ -n "$P33_BACKSTOP_LN" ] && [ -n "$P33_VERDICT_BRANCH_LN" ] && [ "$P33_BACKSTOP_LN" -lt "$P33_VERDICT_BRANCH_LN" ] && echo yes || echo no)"
# (b) RECORD-WRITE-FAILURE detection: the no-new-inputs detector above only catches a dropped Loop
# Exit (no iter-*.json written at all); it is blind to the sibling case where iter-*.json WAS
# written but --persist's own record derivation/write failed (efficiency-trace.sh's own internal
# failure paths leave a "record not written" breadcrumb on stderr while exiting 0 by design). Pin
# that the backstop captures --persist's stderr and checks it for that literal.
assert_pin_unique "#236 (B) phase-3.3: backstop captures --persist stderr for the record-write-failure check" \
  '"$LIB/efficiency-trace.sh" --persist 2>"$PERSIST_ERR" || true' "$DEF_SKILL"
# The single-literal grep above was itself a #236-review fix-delta-gate finding: jq-derivation
# and mkdir failures both end "...record not written[ for ...]", but the disk/permission
# write failure (write-after-mkdir-succeeded: ENOSPC/EROFS/quota/perms) reads "...failed
# (disk/permission); not persisted for ..." instead — a grep on "record not written" alone
# silently misses that third failure mode. Pin BOTH alternatives so a regression back to the
# single-literal form (or a dropped alternative) turns the suite RED.
assert_pin_unique "#236 (B) phase-3.3: record-write-failure detector matches the jq/mkdir 'record not written' breadcrumb via grep -qE" \
  'grep -qE '\''record not written|failed' "$DEF_SKILL"
assert_pin_unique "#236 (B) phase-3.3: record-write-failure detector ALSO matches the disk/permission-write breadcrumb (the single-literal grep this fix replaced silently missed it)" \
  'failed \(disk/permission\); not persisted for'\''' "$DEF_SKILL"
# #236 review (latest shadow pass, requesting-code-review — Important-1): the two breadcrumb
# literals the consumer grep above depends on were pinned ONLY on the CONSUMER side ($DEF_SKILL,
# just above). The PRODUCER side — lib/efficiency-trace.sh, which actually EMITS those literals on
# its record-derivation/write failure paths — was unpinned, so a reword there would silently break
# the consumer grep, stop the second dropped-failed reflection firing, and leave this suite GREEN:
# the coupled-invariant / "guard whose comparand can be absent" class CLAUDE.md warns about. Pin
# the PRODUCER end of BOTH literals so the two ends of the contract cannot drift apart (the
# jq/mkdir "record not written" literal legitimately recurs across two failure paths — a count
# pin, not unique; the disk/permission literal is unique).
assert_eq "#236 (B) producer-side coupled pin: efficiency-trace.sh EMITS the 'record not written' breadcrumb the consumer greps (both failure paths)" "2" \
  "$(pin_count 'record not written' "$LIB/efficiency-trace.sh")"
assert_pin_unique "#236 (B) producer-side coupled pin: efficiency-trace.sh EMITS the disk/permission-write breadcrumb the consumer greps" \
  'failed (disk/permission); not persisted for' "$LIB/efficiency-trace.sh"
# #236 review (latest shadow pass, pr-test-analyzer — Important-3 + Suggestions 1-2): removal-proofs
# were missing on the best-effort observability lines that carry the backstop's non-swallowing +
# loss-record behavior — the PR's own operative-vs-framing lesson applied to code. Pin each so a
# half-revert turns the suite RED:
#  (1) `cat "$PERSIST_ERR" >&2` is the ONLY line re-surfacing --persist's captured breadcrumbs to
#      the run log; deleting it re-swallows every breadcrumb into a temp file that is then rm -f'd.
assert_pin_unique "#236 (B) phase-3.3: --persist captured stderr is re-surfaced to the run log (non-swallowing)" \
  'cat "$PERSIST_ERR" >&2' "$DEF_SKILL"
#  (2) BOTH dropped-failed `|| echo "::warning::"` loss-record guards (the "double silent failure"
#      tails for a failing workpad.py write) — either tail dropped ships green, so count both.
assert_eq "#236 (B) phase-3.3: BOTH dropped-failed reflection loss-record guards present (either tail dropped -> RED)" "2" \
  "$(pin_count 'this run'\''s effectiveness telemetry is lost AND its loss-record could not be written' "$DEF_SKILL")"
#  (3) the pre-loop snapshot's mkdir-failure breadcrumb that names the actual root cause.
assert_pin_unique "#236 (B) phase-3.3: pre-loop snapshot mkdir-failure emits its distinct root-cause breadcrumb" \
  'could not create $ROOT/.devflow/tmp (permissions/read-only-fs/disk-full?)' "$DEF_SKILL"
# #236 review (iteration 2 fix-delta gate, pr-test-analyzer): the $PERSIST_ERR_IS_DEVNULL
# mktemp-degrade path this fix introduced had NO removal-proof coverage — a half-revert
# collapsing it back to a bare `PERSIST_ERR=$(mktemp)`, or one flipping the `-eq 1 ||` sense on
# the cleanup guard, would ship green despite reintroducing the exact `rm -f /dev/null`
# device-deletion hazard the guard exists to prevent (severe: under a root shell with a
# writable /dev this breaks every other command in the environment that redirects to
# /dev/null). Pin the rm-f cleanup guard's sense directly (assert_pin_red_on_removal on the
# operative sentence: the code IS the fix, so the removal-proof target is the guard line
# itself) and the mktemp-degrade warning breadcrumb's presence.
assert_pin_red_on_removal "#236 (B) phase-3.3: deleting the /dev/null-safe rm-f cleanup guard turns its pin RED" \
  '[ "$PERSIST_ERR_IS_DEVNULL" -eq 1 ] || rm -f "$PERSIST_ERR"' "$DEF_SKILL"
assert_pin_unique "#236 (B) phase-3.3: mktemp-failure degrade emits its own distinct ::warning:: breadcrumb" \
  'could not allocate a temp file for --persist'\''s stderr (mktemp failed)' "$DEF_SKILL"
# #236 review (shadow pass, pr-test-analyzer): the `[ "$PERSIST_ERR_IS_DEVNULL" -eq 0 ] &&`
# guard gating the record-write-failure grep was UNPINNED — mutation-tested by the reviewer
# (dropping the guard clause left the full suite green, since $PERSIST_ERR literally equals
# /dev/null when the flag is 1 and grep against /dev/null always no-matches today). Currently
# behaviorally redundant, but a future refactor reassigning $PERSIST_ERR away from the literal
# path /dev/null while forgetting to update this guard would silently reintroduce a live bug
# with nothing to catch it. Pin the guarded grep line as a whole so the conjunct can't be
# silently dropped.
assert_pin_unique "#236 (B) phase-3.3: record-write-failure grep is gated on the PERSIST_ERR_IS_DEVNULL guard (not run unconditionally)" \
  'if [ "$PERSIST_ERR_IS_DEVNULL" -eq 0 ] && grep -qE' "$DEF_SKILL"
# (c) BOUNDED RE-REVIEW coverage: the AWUSF path can drive a SECOND, separate inline
# review-and-fix invocation (the bounded re-review) whose own Loop Exit is just as droppable as
# the first invocation's — but the original backstop only ran once, after the FIRST invocation,
# leaving the second entirely unguarded (silent-failure-hunter's #236 review Finding 2). Pin that
# the bounded re-review step re-runs both halves of the backstop (a fresh snapshot before, the
# persistence check after) rather than relying on the first invocation's now-stale snapshot.
assert_pin_unique "#236 (B) phase-3.3: bounded re-review re-takes a fresh pre-invocation snapshot" \
  're-run the pre-invocation snapshot block from 3.3 above' "$DEF_SKILL"
assert_pin_unique "#236 (B) phase-3.3: bounded re-review re-runs the observability-persistence backstop" \
  're-run the observability-persistence backstop block from 3.3 above' "$DEF_SKILL"
# ── #192: review/analysis agents must never mutate the live working tree ──────────────
# Two coupled layers, each pinned with a mutation-proven assert_pin_red_on_removal so a
# half-applied removal of the contract turns the suite RED (issue #192 AC4):
#   (1) each first-party review/analysis agent definition carries the never-mutate /
#       use-`mktemp`-copy mandate, and
#   (2) skills/review/SKILL.md's shared Phase 3.1/3.2 dirty-tree backstop snapshots the
#       tree before dispatch, compares after, surfaces the divergence as a finding with an
#       attributable breadcrumb, and restores only the snapshot delta.
# The operative agent-mandate literal is identical across all six definition files, so the
# same literal pins each (assert_pin_unique requires it appear exactly once PER FILE).
REVIEW_AGENT_MANDATE='on a temporary copy made with `mktemp`, never in place'
# The PRIMARY write-prohibition (AC1's core contract) is a distinct operative sentence from
# the mktemp clause — pin it too, else the prohibition could be deleted while the mktemp pin
# stays GREEN. The five first-party agents share this exact sentence; the vendored final-pass
# carries the equivalent prohibition in its own pre-existing wording, pinned separately below.
REVIEW_AGENT_PROHIBITION='modify working-tree source files, the index, HEAD, or branch state'
for review_agent in code-reviewer silent-failure-hunter comment-analyzer type-design-analyzer pr-test-analyzer; do
  assert_pin_red_on_removal "#192 agent-mandate: deleting the never-mutate/mktemp-copy mandate from $review_agent turns its pin RED" \
    "$REVIEW_AGENT_MANDATE" "$LIB/../agents/$review_agent.md"
  assert_pin_red_on_removal "#192 agent-mandate: deleting the primary write-prohibition from $review_agent turns its pin RED" \
    "$REVIEW_AGENT_PROHIBITION" "$LIB/../agents/$review_agent.md"
done
assert_pin_red_on_removal "#192 agent-mandate: deleting the never-mutate/mktemp-copy mandate from the requesting-code-review final-pass turns its pin RED" \
  "$REVIEW_AGENT_MANDATE" "$LIB/../skills/requesting-code-review/code-reviewer.md"
assert_pin_red_on_removal "#192 agent-mandate: deleting the primary write-prohibition from the requesting-code-review final-pass turns its pin RED" \
  'Do not mutate the working tree, the index, HEAD, or branch state in any way' "$LIB/../skills/requesting-code-review/code-reviewer.md"
# Backstop operative sentences — one pin per operative directive (operative-vs-framing rule).
# The Phase 3.1/3.2 backstop now snapshots with `git status --porcelain -z` into temp FILES
# (NUL-delimited, UNQUOTED paths — a bash $(...) var cannot hold the NUL bytes), so a
# spaced/special path is a real pathspec the restore can act on; only a true rename/copy
# remains surfaced-not-restored (#216). Each pinned literal is target-unique and contains no
# ASCII single-quote delimiters, so the single-quoted run.sh arg stays intact (the older
# `sed 's/^...//'` pin had to be avoided because its program is wrapped in single-quote
# delimiters that the literal cannot carry — the `-z` rework removes that `sed` entirely).
assert_pin_red_on_removal "#216 backstop: deleting the pre-dispatch -z snapshot capture turns its pin RED" \
  'git status --porcelain -z > "$GIT_SNAP_BEFORE"' "$REVIEW_SKILL"
assert_pin_red_on_removal "#216 backstop: deleting the after-dispatch -z snapshot capture turns its pin RED" \
  'git status --porcelain -z > "$GIT_SNAP_AFTER"' "$REVIEW_SKILL"
assert_pin_red_on_removal "#216 backstop: deleting the cmp-based compare-after divergence trigger turns its pin RED" \
  'cmp -s "$GIT_SNAP_BEFORE" "$GIT_SNAP_AFTER"' "$REVIEW_SKILL"
assert_pin_red_on_removal "#192 backstop: deleting the attributable dirty-tree breadcrumb turns its pin RED" \
  'a Phase 3.1 review-agent dispatch modified the working tree' "$REVIEW_SKILL"
assert_pin_red_on_removal "#192 backstop: deleting the snapshot-delta-scoped restore turns its pin RED" \
  'restore only the snapshot-delta paths' "$REVIEW_SKILL"
assert_pin_red_on_removal "#192 backstop: deleting the surface-as-a-finding fail-safe clause turns its pin RED" \
  'record it as a finding (never discard it silently)' "$REVIEW_SKILL"
assert_pin_red_on_removal "#192 backstop: deleting the Phase-3-aggregation finding-injection sentence turns its pin RED" \
  'add an **Important** finding to the Phase 3 findings set' "$REVIEW_SKILL"
assert_pin_red_on_removal "#192 backstop: deleting the untracked-file-never-auto-deleted safety rule turns its pin RED" \
  'never auto-deleted; git said' "$REVIEW_SKILL"
# Set-difference DIRECTION: the restore set is paths in AFTER NOT present in BEFORE (`! grep`
# membership against the BEFORE set). Flipping to a positive `grep` (restore BEFORE-present
# paths) would clobber the orchestrator's own concurrent edits — the hazard the old `comm -13`
# direction guarded. (The pin line carries `grep` but no `echo`, so the repo-wide raw-guard
# scanner — which keys on a `grep…SKILL…echo` line — does not match it.)
# The membership test is `grep -qzxF <path> BEFORE_PATHS`, and the restore DIRECTION is
# "restore only on grep rc 1 (absent from BEFORE → newly dirty)". Pin BOTH the membership
# probe and the rc-1 restore branch: dropping the probe, or flipping the direction to
# restore-on-present (rc 0), would restore already-dirty paths and clobber live orchestrator
# edits — the hazard the old `comm -13` direction guarded. (Each pin line carries `grep`/no
# `echo`, so the repo-wide raw-guard scanner — which keys on a `grep…SKILL…echo` line — misses it.)
assert_pin_red_on_removal "#216 backstop: deleting the by-path BEFORE-membership probe turns its pin RED" \
  'grep -qzxF -- "${rec:3}" "$BEFORE_PATHS"' "$REVIEW_SKILL"
assert_pin_red_on_removal "#216 backstop: flipping the restore direction off the grep-rc-1 (absent) branch turns its pin RED" \
  '[ "$gmrc" -eq 1 ]' "$REVIEW_SKILL"
# Fail-closed guards added when hardening the restore (each must NOT read an error as a
# restorable divergence): grep-membership ERROR (rc>=2) must not be treated as "absent →
# restore"; a failed temp-file alloc must skip the restore; a `cmp` ERROR must not be read as
# divergence. Pin each breadcrumb so deleting a fail-closed guard turns its pin RED.
assert_pin_red_on_removal "#216 backstop: deleting the grep-membership-error fail-closed guard turns its pin RED" \
  'NOT auto-restoring it (fail-closed)' "$REVIEW_SKILL"
assert_pin_red_on_removal "#216 backstop: deleting the temp-alloc-failure fail-closed breadcrumb turns its pin RED" \
  'could not allocate temp files for the dirty-tree restore' "$REVIEW_SKILL"
assert_pin_red_on_removal "#216 backstop: deleting the cmp-error fail-closed breadcrumb turns its pin RED" \
  'dirty-tree comparison SKIPPED this dispatch' "$REVIEW_SKILL"
# Rename/copy two-path `-z` entries are surfaced-not-restored — routed to a separate file,
# never into the auto-restore set. Deleting the routing or the breadcrumb silently drops them.
assert_pin_red_on_removal "#216 backstop: deleting the rename surfaced-not-restored routing turns its pin RED" \
  '>> "$RENAMED_PATHS_FILE"' "$REVIEW_SKILL"
assert_pin_red_on_removal "#216 backstop: deleting the rename surfaced-not-restored breadcrumb turns its pin RED" \
  'not auto-restored (a staged rename needs index surgery)' "$REVIEW_SKILL"
# The empty-restore-set branch is the OPERATIVE directive (the breadcrumb pin below is its
# message); pin the `[ ! -s ... ]` condition too so inverting/removing it can't stay GREEN.
assert_pin_red_on_removal "#216 backstop: deleting the empty-restore-set branch condition turns its pin RED" \
  '[ ! -s "$CHANGED_PATHS_FILE" ]' "$REVIEW_SKILL"
assert_pin_red_on_removal "#192 backstop: deleting the fail-closed before-snapshot disable turns its pin RED" \
  'dirty-tree backstop DISABLED for this dispatch' "$REVIEW_SKILL"
assert_pin_red_on_removal "#192 backstop: deleting the after-snapshot fail-distinct breadcrumb turns its pin RED" \
  'could not snapshot the working tree after the Phase 3.1 dispatch' "$REVIEW_SKILL"
# Pin the EXECUTABLE restore action (restore from HEAD, not the INDEX) and the post-restore
# tree-state RE-CHECK (trust the tree, not the exit code) — deleting either downgrades the
# backstop from "detect AND restore (verified)" to "detect only" while every prose pin stays GREEN.
assert_pin_red_on_removal "#192 backstop: deleting the restore-from-HEAD checkout action turns its pin RED" \
  'git checkout HEAD -- "$p"' "$REVIEW_SKILL"
assert_pin_red_on_removal "#192 backstop: deleting the post-restore tree-state re-check turns its pin RED" \
  '[ -n "$(git status --porcelain -- "$p")" ]' "$REVIEW_SKILL"
# AC4 (#216): the empty-delta breadcrumb no longer asserts a single cause it cannot prove —
# it states the divergence + empty restore set and names BOTH possible causes (a status-byte
# change OR a dirty->clean transition), since `cmp` cannot distinguish them.
assert_pin_red_on_removal "#216 backstop: deleting the empty-delta no-single-cause breadcrumb turns its pin RED" \
  'the by-path restore set is empty (an already-dirty path' "$REVIEW_SKILL"
# AC3 (#216) drift guards — coupled multi-site operative directives, pinned by occurrence
# count so dropping any one site drifts the count RED (assert_pin_red_on_removal cannot apply
# to a literal that appears more than once by design):
#  - the pathname-safe NUL read loop `IFS= read -r -d ''` at all THREE sites (BEFORE extract,
#    AFTER extract, restore loop) — a regression to a newline `read -r` at any site drops the count;
#  - the `sort -z` operand at BOTH extraction sorts — dropping `-z` collapses NUL data to one line;
#  - the `\x01`-prefixed fail-closed sentinel VALUE at all THREE sites (set in 3.1, the 3.2
#    short-circuit read, the 3.2 cleanup guard). A bare-NAME count (matching just
#    `__DIRTY_TREE_BACKSTOP_DISABLED__`) would couple the NAME but NOT the `\x01` byte that
#    makes the sites compare equal (#216), so this guard pins the FULL value
#    `\x01__DIRTY_TREE_BACKSTOP_DISABLED__` instead — a one-sided `\x01` drop then drifts the
#    count RED (a bare-name count would stay GREEN on exactly that regression).
assert_eq "#216 backstop: the pathname-safe NUL read loop is present at all three sites" "yes" \
  "$([ "$(grep -cF 'IFS= read -r -d' "$REVIEW_SKILL")" -eq 3 ] && echo yes || echo no)"  # raw-guard-ok: count-based: asserts ==3 NUL read loops (BEFORE/AFTER extract + restore)
assert_eq "#216 backstop: the sort -z operand is present at both extraction sorts" "yes" \
  "$([ "$(grep -cF 'sort -z' "$REVIEW_SKILL")" -eq 2 ] && echo yes || echo no)"  # raw-guard-ok: count-based: asserts ==2 sort -z operands
assert_eq "#216 backstop: the byte-prefixed fail-closed sentinel value stays coupled across its three sites" "yes" \
  "$([ "$(grep -cF '\x01__DIRTY_TREE_BACKSTOP_DISABLED__' "$REVIEW_SKILL")" -eq 3 ] && echo yes || echo no)"  # raw-guard-ok: count-based: asserts ==3 occurrences of the FULL \x01-prefixed sentinel (3.1 set + 3.2 read + 3.2 cleanup)
# ── #216: dirty-tree backstop -z rework — git_sandbox integration proof ────────────────
# AC2 (#216): a spaced-path agent mutation is correctly RESTORED (no silent no-op), a true
# rename is SURFACED-not-restored, and the spaced-path restore is COUPLED to the `-z` rework
# (RED with quoted plain-porcelain snapshots, GREEN with `-z`). The proof EXTRACTS the
# self-contained restore region from skills/review/SKILL.md and runs it against a real
# throwaway git repo (git_sandbox), so a regression of the region's NUL-handling back to the
# quoting-vulnerable shape turns this RED. The markers are referenced via vars so this source
# line never carries the contiguous marker string the extractor scans for.
DT_REGION="$(probe_tmp "#216 backstop region extraction")"
DT_BEGIN="devflow:dirty-tree-restore ""BEGIN"
DT_END="devflow:dirty-tree-restore ""END"
# Reuse the single-source-of-truth region extractor (markers excluded the same way every
# other region scanner excludes them) rather than re-rolling the region awk inline.
region_lines "$REVIEW_SKILL" "$DT_BEGIN" "$DT_END" > "$DT_REGION"
assert_eq "#216 backstop: restore region extracted from SKILL.md is non-empty" "yes" \
  "$([ -s "$DT_REGION" ] && echo yes || echo no)"
# Build a fresh sandbox repo with a committed spaced-path file + a plain file (fail-closed on
# mktemp -d failure via git_sandbox's /dev/null sentinel — a caller's `[ -d ]` guard then skips).
dt_make_repo() {  # -> prints repo dir
  local d; d="$(git_sandbox "#216 backstop fixture")" || { printf '%s\n' "$d"; return 1; }
  git -C "$d" init -q; git -C "$d" config user.email t@t; git -C "$d" config user.name t
  printf orig > "$d/my file.txt"; printf plain > "$d/plain.txt"
  git -C "$d" add -A; git -C "$d" commit -qm init
  printf '%s\n' "$d"
}
# Case A — spaced-path modify with `-z` snapshots: RESTORED (GREEN).
DT_A="$(dt_make_repo)"
if [ -d "$DT_A" ]; then
  DT_A_B="$(probe_tmp "#216 case-A before")"; DT_A_AF="$(probe_tmp "#216 case-A after")"
  git -C "$DT_A" status --porcelain -z > "$DT_A_B"
  printf changed > "$DT_A/my file.txt"
  git -C "$DT_A" status --porcelain -z > "$DT_A_AF"
  ( cd "$DT_A" && GIT_SNAP_BEFORE="$DT_A_B" GIT_SNAP_AFTER="$DT_A_AF" bash "$DT_REGION" ) >/dev/null 2>&1
  assert_eq "#216 backstop: a spaced-path agent modification is restored (-z snapshots)" \
    "orig" "$(cat "$DT_A/my file.txt" 2>/dev/null)"
  rm -rf "$DT_A" "$DT_A_B" "$DT_A_AF"
fi
# Case B — SAME mutation but QUOTED plain-porcelain snapshots: NOT restored. This is the
# pre-rework (RED) state — it proves the `-z` capture is load-bearing, not incidental.
DT_BR="$(dt_make_repo)"
if [ -d "$DT_BR" ]; then
  DT_BR_B="$(probe_tmp "#216 case-B before")"; DT_BR_AF="$(probe_tmp "#216 case-B after")"
  git -C "$DT_BR" status --porcelain > "$DT_BR_B"     # no -z: the spaced path is C-quoted
  printf changed > "$DT_BR/my file.txt"
  git -C "$DT_BR" status --porcelain > "$DT_BR_AF"
  ( cd "$DT_BR" && GIT_SNAP_BEFORE="$DT_BR_B" GIT_SNAP_AFTER="$DT_BR_AF" bash "$DT_REGION" ) >/dev/null 2>&1
  assert_eq "#216 backstop: quoted (non--z) snapshots do NOT restore the spaced path (why -z is required)" \
    "changed" "$(cat "$DT_BR/my file.txt" 2>/dev/null)"
  rm -rf "$DT_BR" "$DT_BR_B" "$DT_BR_AF"
fi
# Case C — true staged rename: SURFACED, NOT auto-restored (the file stays renamed).
DT_C="$(dt_make_repo)"
if [ -d "$DT_C" ]; then
  DT_C_B="$(probe_tmp "#216 case-C before")"; DT_C_AF="$(probe_tmp "#216 case-C after")"
  git -C "$DT_C" status --porcelain -z > "$DT_C_B"
  git -C "$DT_C" mv "plain.txt" "renamed plain.txt"
  git -C "$DT_C" status --porcelain -z > "$DT_C_AF"
  ( cd "$DT_C" && GIT_SNAP_BEFORE="$DT_C_B" GIT_SNAP_AFTER="$DT_C_AF" bash "$DT_REGION" ) >/dev/null 2>&1
  assert_eq "#216 backstop: a true rename is surfaced-not-restored (renamed file remains)" \
    "plain" "$(cat "$DT_C/renamed plain.txt" 2>/dev/null)"
  assert_eq "#216 backstop: a true rename leaves the original path removed (not auto-recreated)" \
    "no" "$([ -e "$DT_C/plain.txt" ] && echo yes || echo no)"
  rm -rf "$DT_C" "$DT_C_B" "$DT_C_AF"
fi
# Case D — the CENTRAL by-path safety property end-to-end: a path the orchestrator had
# ALREADY modified before dispatch is left untouched (NOT clobbered) while a DIFFERENT path an
# agent newly dirtied during the window IS restored. This exercises the `! grep`/rc-1
# membership direction against a non-empty BEFORE set — the one scenario cases A/B/C don't
# build — so a subtle regression in BEFORE-set construction or the membership direction that
# clobbers a concurrent edit fails here, not only at the literal-presence direction pin.
DT_D="$(dt_make_repo)"
if [ -d "$DT_D" ]; then
  DT_D_B="$(probe_tmp "#216 case-D before")"; DT_D_AF="$(probe_tmp "#216 case-D after")"
  printf 'concurrent edit' > "$DT_D/my file.txt"   # orchestrator's OWN edit — dirty BEFORE dispatch
  git -C "$DT_D" status --porcelain -z > "$DT_D_B"
  printf 'agent edit' > "$DT_D/plain.txt"          # a DIFFERENT path an agent dirties DURING the window
  git -C "$DT_D" status --porcelain -z > "$DT_D_AF"
  ( cd "$DT_D" && GIT_SNAP_BEFORE="$DT_D_B" GIT_SNAP_AFTER="$DT_D_AF" bash "$DT_REGION" ) >/dev/null 2>&1
  assert_eq "#216 backstop: an already-dirty path (clean->dirty BEFORE dispatch) is NOT clobbered by the restore" \
    "concurrent edit" "$(cat "$DT_D/my file.txt" 2>/dev/null)"
  assert_eq "#216 backstop: a newly-dirtied path (dirtied DURING the window) IS restored to HEAD" \
    "plain" "$(cat "$DT_D/plain.txt" 2>/dev/null)"
  rm -rf "$DT_D" "$DT_D_B" "$DT_D_AF"
fi
rm -f "$DT_REGION"
# Coupled-invariant drift guard: the "detect_all_audit is intentionally not persisted
# into diff_profile" contract spans two mirror sites — the SKILL.md schema comment and
# docs/efficiency-trace.md. Both must agree; pin each with its stable site-specific phrase.
TRACE_DOC="$LIB/../docs/efficiency-trace.md"
assert_pin_unique "#167 coupled-site: SKILL.md states detect_all_audit is intentionally not persisted" \
  'detect_all_audit`, is intentionally **not** persisted here' "$MAXI_SKILL"
assert_pin_unique "#167 coupled-site: efficiency-trace.md states detect_all_audit only forces the critic pass (never shapes the profile)" \
  'it only forces the completeness-critic pass and never shapes the profile' "$TRACE_DOC"

# Drift guard: the Phase 2.3 sweep list lives in three places that must stay in
# sync — the sweep body in the implement skill (phases/phase-2-implement.md), the "Sweep selection" always-run
# index in the same file, and the rationale table in docs/implement-skill.md. The
# error-handling & silent-failure sweep (2.3.6) front-loads the Phase 3.3
# silent-failure-hunter agent; if any of the three loses it the catch reverts to
# the contingent, inconsistent homing the baseline showed. Pin all three so a
# half-applied removal fails here instead of silently shipping.
IMPL_SKILL="$IMPL_SKILL_BUNDLE"   # issue #218: the whole implement-skill bundle (orchestrator + 4 phase files)
IMPL_DOC="$LIB/../docs/implement-skill.md"

# ── issue #218: implement skill split into orchestrator + per-phase reference files ──
# The implement skill is now a thin orchestrator (skills/implement/SKILL.md) plus four
# phases/phase-N-*.md reference files read on-demand at phase entry; IMPL_SKILL/DEF_SKILL
# above point at the CONCATENATED bundle of all five so the content pins are
# location-agnostic within the implement skill. These structural assertions guard the
# split itself, against the real orchestrator file and phases/ dir (NOT the bundle): the
# phase files exist & are non-empty; no phase file can be mistaken for an auto-discovered
# nested skill (none named SKILL.md under phases/); and the orchestrator carries an
# entry-gate read-instruction for each phase file, so a future edit cannot silently drop a
# phase's load step (which would make the engine improvise that phase from its thin stub).
IMPL_ORCH="$LIB/../skills/implement/SKILL.md"
IMPL_PHASES_DIR="$LIB/../skills/implement/phases"
# Shared phase-file path, colocated with its parent IMPL_PHASES_DIR so the #232 and #230
# pin blocks below reference one source of truth for the path (not two differently-named locals).
P4_FILE="$IMPL_PHASES_DIR/phase-4-documentation.md"
# Directory-reconciliation: the actual phases/*.md files must equal IMPL_PHASE_STEMS — the
# single registered phase set the bundle members and the per-phase loop both derive from. A
# future phase file added to the directory (and wired into the orchestrator) WITHOUT being
# registered in IMPL_PHASE_STEMS would otherwise be silently dropped from the bundle and the
# per-phase coverage (its content pins/guards would under-cover it with zero RED); this fails
# RED instead. Reconciling against the directory, not just hand-listing, is what closes the
# coupled-site hazard of two hand-maintained mirrors. (`-maxdepth 1`: phases/ is flat; the
# misregistration guard below separately forbids a nested SKILL.md.)
_actual_phase_stems=$(find "$IMPL_PHASES_DIR" -maxdepth 1 -name '*.md' -type f -exec basename {} .md \; 2>/dev/null | sort | tr '\n' ' ' | sed 's/ *$//')
_registered_phase_stems=$(printf '%s\n' $IMPL_PHASE_STEMS | sort | tr '\n' ' ' | sed 's/ *$//')
assert_eq "implement split: phases/ dir holds exactly the registered phase set (no unregistered / missing phase file)" \
  "$_registered_phase_stems" "$_actual_phase_stems"
# The resolve-once preamble above the per-phase loop carries its OWN fail-closed contract
# (the ${CLAUDE_SKILL_DIR}-empty stop, and "the stubs are deliberately non-actionable" —
# the imperative that a phase must never run from its thin stub alone). Each per-phase gate
# below is independently pinned (path + mandatory-read framing + halt clause), so a future
# edit that weakens ONLY this shared preamble has a narrower blast radius than losing a
# phase gate — but it is still a real, locatable coverage gap (this is the same
# "pin only the path, not the imperative" hole the per-phase loop's own comment calls out,
# applied to the preamble it doesn't cover). Pin both load-bearing clauses here, once, since
# the preamble itself appears once in the orchestrator (not once per phase).
assert_pin_unique "implement split: orchestrator preamble fails closed when \${CLAUDE_SKILL_DIR} does not resolve" \
  "did not resolve" "$IMPL_ORCH"
assert_pin_unique "implement split: orchestrator preamble states the stubs are deliberately non-actionable" \
  "the stubs are deliberately non-actionable" "$IMPL_ORCH"
# One loop over the single phase-stem list checks each per-phase invariant: the phase file
# exists & is non-empty; the orchestrator names its entry-gate read EXACTLY ONCE; AND the
# orchestrator carries the entry-gate's fail-closed *imperative* (the "halt … with an
# attributable breadcrumb" clause) — pinning only the path string would stay GREEN if a
# future edit downgraded the mandatory-read gate to an inert "see also phases/…" mention,
# losing the mandatory-read / fail-closed semantics the split depends on. One loop header → one place the stem
# list is maintained.
for _pf in $IMPL_PHASE_STEMS; do
  _n="${_pf#phase-}"; _n="${_n%%-*}"   # phase-1-setup -> 1
  assert_eq "implement split: phases/${_pf}.md exists and is non-empty" "yes" \
    "$([ -s "$IMPL_PHASES_DIR/${_pf}.md" ] && echo yes || echo no)"
  assert_pin_unique "implement split: orchestrator names the ${_pf}.md entry-gate read" \
    "phases/${_pf}.md" "$IMPL_ORCH"
  # Pin the mandatory-read framing token AND the fail-closed halt, not just the path: with all
  # three pinned per phase, a future edit cannot downgrade the gate to an inert "see also
  # phases/…" mention (which would drop "before any Phase N action" and the halt clause) while
  # keeping any single literal — closing the co-location gap a path-only pin left open.
  assert_pin_unique "implement split: orchestrator carries the mandatory-read framing for Phase ${_n}" \
    "before any Phase ${_n} action" "$IMPL_ORCH"
  assert_pin_unique "implement split: orchestrator carries the fail-closed entry-gate halt for Phase ${_n}" \
    "halt Phase ${_n} with an attributable breadcrumb" "$IMPL_ORCH"
  # Phase-identity check (shadow-pass finding): every other pin above is content-presence
  # ANYWHERE in the bundle, so a same-length cross-phase swap (e.g. phase-2-implement.md and
  # phase-3-review.md bodies accidentally exchanged) would leave them green — the tokens are
  # still present somewhere in the bundle. Grep the OWNING FILE directly (not the bundle) for
  # its own phase heading, the one thing that must live in THAT file and no other.
  # Anchored to the START of the line (`^`), not a bare substring match (fix-delta gate
  # finding): an unanchored match would false-PASS a swap whose real heading was lost but
  # whose phase number still happened to appear elsewhere in the body (a stray prose
  # cross-reference, a TOC entry) — the predicate must match the structural heading
  # position, not just "the digit appears somewhere in the file".
  assert_eq "implement split: phases/${_pf}.md carries its own Phase ${_n} heading (not a cross-phase swap)" "yes" \
    "$(grep -qE "^## Phase ${_n}:" "$IMPL_PHASES_DIR/${_pf}.md" && echo yes || echo no)"
done
# Misregistration guard: a present-but-empty stdout from find means NO SKILL.md under
# phases/. find over a missing dir also prints nothing (2>/dev/null), but the existence
# assertions above independently fail closed when the dir/files are absent, so this guard
# is non-vacuous once the split exists (mutation-proven by transiently adding phases/SKILL.md).
assert_eq "implement split: no SKILL.md under phases/ (no nested auto-discovered skill)" "" \
  "$(find "$IMPL_PHASES_DIR" -name SKILL.md 2>/dev/null)"

# ── F1 (review): STANDING anti-vacuity proofs for the new fail-closed guards ───────────────
# The guards above are non-vacuous by construction, but the project discipline (the
# git_sandbox AC3 probes, "bake the half-revert into the suite — do not leave it a one-time
# manual act") requires that fail-closed property to be a STANDING test, not a one-time
# manual mutation. Each proof exercises the guard's real predicate/pipeline on a synthetic
# mutated input and asserts the fail-closed DIRECTION, so a future refactor that weakens a
# guard (drops the `[ -r ]`/`[ -s ]` clause, breaks the reconciliation comparison, or
# narrows the SKILL.md find) turns the suite RED here instead of silently passing.
# (a) the FACTORED bundle-member predicate (the EXACT function the bundle build calls, so no
#     replica drift) fails CLOSED on missing / empty / unreadable, and PASSES on a real file.
_f1_missing="$IMPL_PHASES_DIR/.f1-nonexistent-$$"
assert_eq "F1: bundle-member predicate fails closed on a MISSING member" "no" \
  "$(_impl_bundle_member_usable "$_f1_missing" && echo yes || echo no)"
_f1_empty=$(probe_tmp "F1 empty-member proof"); : > "$_f1_empty"
assert_eq "F1: bundle-member predicate fails closed on an EMPTY member" "no" \
  "$(_impl_bundle_member_usable "$_f1_empty" && echo yes || echo no)"
assert_eq "F1: bundle-member predicate PASSES on a real readable non-empty phase file (not trivially false)" "yes" \
  "$(_impl_bundle_member_usable "$IMPL_PHASES_DIR/phase-1-setup.md" && echo yes || echo no)"
# the unreadable arm (S1's specific case) only when non-root — `[ -r ]` is always true as root.
if [ "$(id -u)" != 0 ]; then
  _f1_unreadable=$(probe_tmp "F1 unreadable-member proof"); printf 'x\n' > "$_f1_unreadable"; chmod a-r "$_f1_unreadable"
  assert_eq "F1: bundle-member predicate fails closed on an UNREADABLE member" "no" \
    "$(_impl_bundle_member_usable "$_f1_unreadable" && echo yes || echo no)"
  chmod u+rw "$_f1_unreadable" 2>/dev/null || true
fi
# (b) the directory-reconciliation pipeline detects an unregistered stem — a synthetic dir
#     holding a rogue phase file yields an actual set != the registered set (RED). Exercises
#     the same find|sort|tr|sed pipeline shape the real reconciliation uses.
# Allocate via git_sandbox (not a bare `if mktemp -d`): a denied `mktemp -d` must FAIL the
# suite, not silently skip the proof — the exact fail-open this anti-vacuity block exists to
# prevent. git_sandbox records a suite FAIL and returns a /dev/null-rooted sentinel, so the
# `: >`/`find` below fail closed (ENOTDIR) with zero real-repo mutation.
_f1_recon=$(git_sandbox "F1 reconciliation-pipeline anti-vacuity proof")
: > "$_f1_recon/phase-1-setup.md"; : > "$_f1_recon/phase-9-rogue.md"
_f1_actual=$(find "$_f1_recon" -maxdepth 1 -name '*.md' -type f -exec basename {} .md \; 2>/dev/null | sort | tr '\n' ' ' | sed 's/ *$//')
# POSITIVE assertion (not "!= single-stem", which an empty/garbled pipeline output would
# also satisfy vacuously): the pipeline must enumerate EXACTLY the synthetic two-stem set,
# proving the enumeration works AND that the rogue stem makes the set differ from any
# 4-stem registered set — so the real reconciliation's assert_eq would go RED.
assert_eq "F1: reconciliation pipeline enumerates a synthetic dir's exact stem set (incl. the rogue, differs from registered)" \
  "phase-1-setup phase-9-rogue" "$_f1_actual"
rm -rf "$_f1_recon"
# (c) the no-SKILL.md misregistration guard detects an injected SKILL.md (find non-empty → != "").
#     Same fail-closed allocation discipline as (b).
_f1_skilldir=$(git_sandbox "F1 misregistration-guard anti-vacuity proof")
: > "$_f1_skilldir/SKILL.md"
assert_eq "F1: misregistration guard detects an injected SKILL.md (find non-empty → RED)" "no" \
  "$([ -z "$(find "$_f1_skilldir" -name SKILL.md 2>/dev/null)" ] && echo yes || echo no)"
rm -rf "$_f1_skilldir"
# ── end issue #218 structural assertions ──
# ── issue #232: terminal-status self-check (SKILL.md orchestrator) + Phase 4.1 post-subagent
# re-anchor (phase-4-documentation.md) — two halves of one guard family against a run that
# stops before Phase 4 finalization (workpad frozen at an in-progress Status, un-described
# draft PR). Coupled to the skill clauses: removing either clause turns the suite RED.
# Presence via assert_pin_unique (exactly-once); non-vacuity via assert_pin_red_on_removal
# (the suite ITSELF demonstrates PASS->FAIL on removal), per the issue's PASS->FAIL->PASS AC.
# (P4_FILE is the shared phase-file path hoisted next to IMPL_PHASES_DIR above.)
# (1) SKILL.md terminal-status self-check — AC1 (must not end on an in-progress Status) +
#     AC2 (keyed on workpad Status, explicitly not PR draft state).
assert_pin_unique "#232: SKILL terminal-status self-check heading present" \
  '### Terminal-status self-check (before your run-final message)' "$IMPL_ORCH"
assert_pin_unique "#232: SKILL self-check forbids ending on an in-progress Status (operative)" \
  'the run is not finished — return to the phase that owns the remaining work' "$IMPL_ORCH"
assert_pin_unique "#232: SKILL self-check keys on workpad Status, not PR draft state (AC2)" \
  'keys on the workpad `Status`, not on PR draft state' "$IMPL_ORCH"
assert_pin_red_on_removal "#232: SKILL self-check operative clause flips RED on removal" \
  'the run is not finished — return to the phase that owns the remaining work' "$IMPL_ORCH"
assert_pin_red_on_removal "#232: SKILL Status-not-draft clause flips RED on removal" \
  'keys on the workpad `Status`, not on PR draft state' "$IMPL_ORCH"
# (2) phase-4-documentation.md Phase 4.1 post-subagent re-anchor — AC3 (re-read the phase
#     file before §4.2 after the docs subagent returns) + AC4 (scoped to the Phase 4.1
#     docs subagent return only, not the Phase 2/3 subagent returns).
assert_pin_unique "#232: phase-4 re-anchor operative clause present (re-read before §4.2)" \
  're-anchoring the remaining §4.2 (PR description) and §4.3 (finalize) procedure' "$P4_FILE"
assert_pin_unique "#232: phase-4 re-anchor scoped to the Phase 4.1 docs subagent return only (AC4)" \
  'scoped to the Phase 4.1 docs subagent return **only**' "$P4_FILE"
assert_pin_red_on_removal "#232: phase-4 re-anchor operative clause flips RED on removal" \
  're-anchoring the remaining §4.2 (PR description) and §4.3 (finalize) procedure' "$P4_FILE"
assert_pin_red_on_removal "#232: phase-4 re-anchor scope clause flips RED on removal" \
  'scoped to the Phase 4.1 docs subagent return **only**' "$P4_FILE"
# review iter-1 (pr-test-analyzer): pin the OPERATIVE directives, not only their framing —
# a same-line surgical edit that drops the actual instruction while keeping the descriptive
# appendix would otherwise ship GREEN (the recurring framing-only-pin hole).
# AC3 operative: the mandatory re-`Read` directive itself (not the "re-anchoring …" appendix).
assert_pin_unique "#232: phase-4 re-anchor keeps the operative re-Read directive" \
  'again and follow it exactly' "$P4_FILE"
assert_pin_red_on_removal "#232: phase-4 operative re-Read directive flips RED on removal" \
  'again and follow it exactly' "$P4_FILE"
# AC1 operative: the normative prohibition sentence (not only its corrective consequence).
assert_pin_unique "#232: SKILL self-check keeps the run-final-message prohibition (operative)" \
  'Do not emit your run-final message while the workpad' "$IMPL_ORCH"
assert_pin_red_on_removal "#232: SKILL run-final-message prohibition flips RED on removal" \
  'Do not emit your run-final message while the workpad' "$IMPL_ORCH"
# review iter-1 (silent-failure-hunter F1/F2): the two robustness hardenings — the self-check
# binds EVERY termination path (not only a deliberate wrap-up), and the Phase 4.1 re-anchor
# TRIGGER is repeated in the always-loaded orchestrator so a subagent-return eviction cannot
# remove it. Pin both so a later edit cannot silently drop the hardening.
assert_pin_unique "#232: SKILL self-check binds every termination path (SFH F1)" \
  'This guard binds **every** way the run can end' "$IMPL_ORCH"
assert_pin_red_on_removal "#232: SKILL every-termination-path clause flips RED on removal" \
  'This guard binds **every** way the run can end' "$IMPL_ORCH"
assert_pin_unique "#232: orchestrator repeats the Phase 4.1 re-anchor trigger in the always-loaded body (SFH F2)" \
  'repeated here in the always-resident orchestrator' "$IMPL_ORCH"
assert_pin_red_on_removal "#232: always-loaded re-anchor trigger flips RED on removal" \
  'repeated here in the always-resident orchestrator' "$IMPL_ORCH"
# review iter-2 (shadow pr-test-analyzer): the F2 pin above sits on the JUSTIFICATION clause;
# pin the OPERATIVE instruction sentence itself so a surgical edit dropping the re-Read
# directive (while keeping "…repeated here…") can't ship GREEN — the framing-only hole,
# one clause over from the phase file it was first closed on.
assert_pin_unique "#232: orchestrator keeps the OPERATIVE always-loaded re-Read directive (SFH F2)" \
  'the phase file before continuing to §4.2 (resume from §4.2' "$IMPL_ORCH"
assert_pin_red_on_removal "#232: orchestrator operative always-loaded re-Read directive flips RED on removal" \
  'the phase file before continuing to §4.2 (resume from §4.2' "$IMPL_ORCH"
# AC4 scope constraint is mirrored in the always-loaded orchestrator too; pin that copy so the
# "not the Phase 2/3 returns" guardrail can't be dropped from the resident mirror unnoticed.
assert_pin_unique "#232: orchestrator mirror keeps the AC4 Phase-4.1-only scope (SFH F2 mirror)" \
  'scoped to the Phase 4.1 docs subagent return only, not the Phase 2/3 returns' "$IMPL_ORCH"
assert_pin_red_on_removal "#232: orchestrator AC4 scope mirror flips RED on removal" \
  'scoped to the Phase 4.1 docs subagent return only, not the Phase 2/3 returns' "$IMPL_ORCH"
# ── issue #254: Phase 4.0.5 deferrals-manifest discovery must search BOTH the pr-<N>
# slug dir and the sanitized-current-branch slug dir — a current-branch-mode
# /devflow:review-and-fix run writes its manifest under the branch slug, so a
# pr-<N>-only find silently misses those deferrals. The operative arm is the one that
# actually adds the branch-slug dir to the search set; pin it removal-proof so deleting
# the branch-slug arm goes RED. Also pin the BRANCH_SLUG derivation (its producer).
assert_pin_unique "#254: Phase 4.0.5 reads the current branch once into CUR_BRANCH" \
  'CUR_BRANCH=$(git branch --show-current)' "$P4_FILE"
assert_pin_unique "#254: Phase 4.0.5 derives the sanitized branch slug from CUR_BRANCH" \
  'BRANCH_SLUG=$(printf '"'"'%s'"'"' "$CUR_BRANCH" | tr' "$P4_FILE"
assert_pin_unique "#254: Phase 4.0.5 adds the branch-slug dir to the manifest search set (operative)" \
  'SEARCH_DIRS="$SLUG_DIR $BRANCH_DIR"' "$P4_FILE"
assert_pin_red_on_removal "#254: Phase 4.0.5 branch-slug discovery arm flips RED on removal" \
  'SEARCH_DIRS="$SLUG_DIR $BRANCH_DIR"' "$P4_FILE"
# The aggregate must still be written at pr-<N>/deferrals.json (the path /pr-description reads).
assert_pin_unique "#254: Phase 4.0.5 keeps the aggregate at the pr-<N> slug path" \
  'AGG="${SLUG_DIR}/deferrals.json"' "$P4_FILE"
# tr-dependence observability (this repo's review-and-fix guard-class 2): BRANCH_SLUG is
# derived through `tr` on PATH, so a `tr`-degraded host yields an empty slug and the branch-
# slug arm is silently dropped. The extension MANDATES making that degradation observable,
# so the empty-slug breadcrumb must not be droppable unnoticed — pin it removal-proof (the
# existing SEARCH_DIRS pin covers the arm's RHS only, not this guard/breadcrumb).
assert_pin_red_on_removal "#254: Phase 4.0.5 tr-degraded empty-slug breadcrumb flips RED on removal" \
  'current branch produced an empty slug' "$P4_FILE"
assert_pin_unique "#254: Phase 4.0.5 guards the branch-slug arm on a non-empty slug" \
  '[ -n "$BRANCH_SLUG" ] && [ "$BRANCH_DIR" != "$SLUG_DIR" ]' "$P4_FILE"
assert_pin_unique "sweep 2.3.6: implement SKILL keeps the sweep body" '#### 2.3.6 Error-handling & silent-failure sweep' "$IMPL_SKILL"
assert_pin_unique "sweep 2.3.6: implement SKILL lists it in the always-run index" '**2.3.6** (error-handling & silent-failure)' "$IMPL_SKILL"
assert_eq "sweep 2.3.6: docs/implement-skill.md keeps the rationale table row" "yes" \
  "$(grep -qF '| 2.3.6 Error-handling & silent-failure |' "$IMPL_DOC" && echo yes || echo no)"
# Heading/index/table pins above catch a half-applied *removal* but not a semantic
# gutting that leaves the heading while deleting the sweep's load-bearing steps.
# Pin one step token unique to the 2.3.6 procedure (the false-success rule) so a
# reviewer who guts the steps but keeps the heading still trips the suite.
assert_pin_unique "sweep 2.3.6: implement SKILL keeps the false-success step rule" "never prints success for work that didn't happen" "$IMPL_SKILL"

# Issue #200 / PR #202: silent-failure-hunter gains a prompt-instruction-artifact lens for
# inert guards (a guard that reads as handled but fails open as written). Pin the operative
# text of each new detection so a later edit that silently guts the lens trips here. Each
# literal is an operative clause of the new lens, pinned through assert_pin_red_on_removal
# so the suite ITSELF demonstrates the PASS->FAIL mutation proof (present-and-unique now,
# RED once the LINE carrying the clause is stripped) — not just a manual one-off —
# satisfying the issue AC that each pin be shown to flip RED on removal. (Removal is
# line-granular: the fail-open and proportional-severity clauses share one source line, so
# stripping that line trips both their pins; each pin still independently observes PASS->FAIL.)
SFH_AGENT="$LIB/../agents/silent-failure-hunter.md"
assert_pin_red_on_removal "#200 SFH: keeps the policy-without-mechanism detection (no detection mechanism supplied)" \
  'supplies no executable mechanism to observe that condition' "$SFH_AGENT"
assert_pin_red_on_removal "#200 SFH: keeps the guard-ordered-after-its-exit detection" \
  'positioned after the early-exit, no-op, or "proceed" short-circuit it is meant to gate' "$SFH_AGENT"
assert_pin_red_on_removal "#200 SFH: keeps the repo-agnostic scope clause (lens applies only to prompt-instruction artifacts)" \
  'Apply the two detections in this step **only to prompt-instruction artifacts**' "$SFH_AGENT"
assert_pin_red_on_removal "#200 SFH: keeps the explicit fail-open direction for an inert prompt guard" \
  'An inert prompt guard **fails open**' "$SFH_AGENT"
assert_pin_red_on_removal "#200 SFH: keeps the proportional-severity calibration clause (no single fixed severity)" \
  'Do not assign a single fixed severity.' "$SFH_AGENT"
assert_pin_red_on_removal "#200 SFH: output format labels the inert-guard finding's sub-class" \
  'which sub-class it is — policy-without-mechanism, or ordered-after-exit' "$SFH_AGENT"
# PR #202 review (Important): the positive scope clause was pinned above, but the NEGATIVE
# exclusion ("ordinary code/config/README/descriptive-markdown is out of scope") was not —
# a future edit could soften the exclusion while keeping the positive half and no pin would
# trip, re-opening the false-positive surface the exclusion guards. Pin the exclusion too.
assert_pin_red_on_removal "#200 SFH: keeps the negative scope-exclusion clause (ordinary code/config/README/descriptive-markdown out of scope)" \
  'an ordinary code, config, README, or descriptive-markdown change' "$SFH_AGENT"
# PR #202 review (Suggestion): the operative diagnostic prompts and the silent-failure
# classification phrase share source lines with already-pinned literals but carry distinct
# behavior; pin them so a surgical reword that guts the diagnostic while keeping the headline
# trips the suite. The (a)/(b) "Ask:" prompts are the agent's actual detection procedure.
assert_pin_red_on_removal "#200 SFH: keeps the policy-without-mechanism diagnostic prompt" \
  'did the same artifact give the agent a concrete way to *detect* the failure it must react to?' "$SFH_AGENT"
assert_pin_red_on_removal "#200 SFH: keeps the ordered-after-exit diagnostic prompt" \
  'does any guard in this artifact sit downstream of a short-circuit it is supposed to control?' "$SFH_AGENT"
assert_pin_red_on_removal "#200 SFH: keeps the silent-failure classification of an inert prompt guard" \
  'so treat it as a silent failure' "$SFH_AGENT"
# PR #202 shadow review (Important): the scope clauses (positive + negative) state the in/out
# BOUNDARY, but the operative DISCRIMINATOR the agent applies to classify a changed file —
# "addresses an agent in the imperative" — was unpinned, so a future edit could gut the lens's
# actual classification test while both boundary pins still PASS. Pin the discriminator too.
assert_pin_red_on_removal "#200 SFH: keeps the imperative-vs-descriptive scope discriminator" \
  'addresses an agent in the imperative' "$SFH_AGENT"
# PR #202 shadow review (Suggestion): the sub-class slug DEFINITION sites (a)/(b) are the
# source of truth for the slugs the output-format label (already pinned) tells the reader to
# use; an in-place rename at a definition site would desync from the label without tripping any
# pin (the detection pins on those lines target other substrings). Pin each slug definition so
# the definition<->label pair is guarded as one coupled site (CLAUDE.md coupled-invariant rule).
assert_pin_red_on_removal "#200 SFH: keeps the policy-without-mechanism slug definition" \
  'sub-class slug `policy-without-mechanism`' "$SFH_AGENT"
assert_pin_red_on_removal "#200 SFH: keeps the ordered-after-exit slug definition" \
  'sub-class slug `ordered-after-exit`' "$SFH_AGENT"
# PR #202 shadow review iter 2 (Important): the output-format severity ladder reconciliation
# is a TWO-SIDED coupled invariant — step 5's 'Do not assign a single fixed severity.' (pinned
# above) is only ONE half; the other half lives in the "## Your Output Format" item-2 carve-out.
# Without pinning that half, a future edit could strip the carve-out and silently revert an
# inert-guard finding to the fixed 'silent failure -> CRITICAL' rung, re-opening the contradiction
# this PR closed, with no pin tripping. Pin the output-format half so the pair is guarded as one.
assert_pin_red_on_removal "#200 SFH: keeps the output-format CRITICAL-de-escalation carve-out" \
  'do not auto-escalate to CRITICAL merely because it is a silent failure' "$SFH_AGENT"

# Issue #198: the two observability sub-checks added to 2.3.4a and 2.3.6. Each pin
# targets the OPERATIVE instruction (the minimal text whose removal alone re-opens the
# gap, per #186), NOT a framing clause — gut the sub-check while keeping its heading and
# these go RED. 2.3.4a clean-path evidence: a step claiming to enumerate/verify/scan must
# log a summary even on the clean path. 2.3.6 per-branch breadcrumb: each branch of a
# multi-branch no-op path must emit a distinct, condition-naming diagnostic.
assert_pin_unique "sweep 2.3.4a: implement SKILL keeps the clean-path-evidence sub-check" \
  "log a summary (the count checked, the result) even on the clean path where nothing needs changing" "$IMPL_SKILL"
assert_pin_unique "sweep 2.3.6: implement SKILL keeps the per-branch-breadcrumb sub-check" \
  "confirm each branch emits a distinct diagnostic naming which condition fired" "$IMPL_SKILL"
# Coupled-invariant: the same two sub-checks are mirrored in docs/implement-skill.md
# (the SKILL <-> docs pair CLAUDE.md names as a coupled invariant). Pin the doc half too
# so a one-sided revert/gutting of either mirror clause trips the suite instead of letting
# the SKILL and its doc rationale silently desync.
assert_pin_unique "sweep 2.3.4a: docs/implement-skill.md mirrors the clean-path-evidence sub-check" \
  "(count, result) even when nothing needs changing" "$IMPL_DOC"
assert_pin_unique "sweep 2.3.6: docs/implement-skill.md mirrors the per-branch-breadcrumb sub-check" \
  "it confirms each branch emits a distinct diagnostic naming which condition fired" "$IMPL_DOC"

# Drift guard: issue #159 B2's severity-aware exit in Phase 3.3 — the implement run must NOT
# fully Block after the AWUSF + bounded-re-review "two consecutive fails"; it soft-proceeds
# (PR review-ready, residual surfaced) UNLESS a genuine unresolved Critical (or ungradeable/
# unparseable verdict) remains. Pinned via assert_pin_unique so each clause is mutation-checked
# exactly-once. A paraphrase reverting to the old hard-block (or widening the block back past
# genuine-Critical, or letting an ungradeable residual fall through to soft-proceed) fails here.
assert_pin_unique "phase 3.3: severity-aware exit (does not fully block on diminishing-returns)" \
  'Severity-aware exit (do not fully block on diminishing-returns)' "$IMPL_SKILL"
assert_pin_unique "phase 3.3: soft-proceed keeps the PR review-ready, not auto-merged" \
  'soft-proceeded on non-Critical residual findings' "$IMPL_SKILL"
assert_pin_unique "phase 3.3: only a genuine unresolved Critical takes the Blocked path" \
  'Blocked path (genuine unresolved Critical only)' "$IMPL_SKILL"
assert_pin_unique "phase 3.3: non-Critical residual routes to soft-proceed, not Block" \
  'the residual is only advisory / Suggestion / `severity-calibrated`-down' "$IMPL_SKILL"
assert_pin_unique "phase 3.3: an ungradeable residual fails closed to Blocked (not soft-proceed)" \
  'an ungradeable residual fails **closed** to the Blocked path' "$IMPL_SKILL"
assert_pin_unique "phase 3.3: option-2 / first-run-REJECT applies over-grade calibration itself" \
  'apply the same flag-and-evaluate calibration yourself' "$IMPL_SKILL"
assert_pin_unique "phase 3.3: REJECT routes through the severity-aware exit (Critical still Blocks)" \
  'a REJECT whose unresolved triggers are all non-Critical' "$IMPL_SKILL"
assert_pin_unique "phase 3.3: soft-proceed records each residual finding durably in the workpad" \
  'unresolved after bounded re-review (non-Critical, surfaced for human review)' "$IMPL_SKILL"

# Drift guard: issue #193 — Phase 3.2 must triage each /simplify finding against the
# issue's in-scope ACs before applying it, skipping AC-conflicting findings with a
# recorded rationale. The OPERATIVE pin is the skip+record sentence (the behavioral fix):
# deleting it alone re-introduces the bug where AC-violating cleanups get applied silently.
# Per the behavioral-fix-pin convention (#186/#192/#194), the operative pin uses
# assert_pin_red_on_removal — the suite itself half-reverts the sentence and confirms the
# pin goes RED, baking the mutation-proof into CI rather than relying on a one-time dev check.
# The scope pin (issue-context-only) and the stale-AC carve-out pin (Phase 2.2.6, not a silent
# skip) stay assert_pin_unique presence guards — they are framing/scope, not the behavioral fix.
assert_pin_red_on_removal "phase 3.2: /simplify findings triaged — operative skip+record sentence (mutation-proven)" \
  'skip the finding and record the AC conflict as the skip rationale' "$IMPL_SKILL"
assert_pin_unique "phase 3.2: triage scoped to the issue-context /devflow:implement path only" \
  'exists only on the issue-context' "$IMPL_SKILL"
assert_pin_unique "phase 3.2: stale-AC conflict routes to Phase 2.2.6, not a silent skip" \
  'that is Phase 2.2.6 AC-rewrite territory' "$IMPL_SKILL"

# Same drift guard for the 2.3.0a peer-checkpoint-completeness sweep: the additive
# twin of 2.3.0 lives in the same three places (sweep body, "Sweep selection" index,
# rationale table) and must stay in sync. It homes the recurring incomplete-edit
# sub-pattern (a rule added at only some of its co-equal peer sites); if any of the
# three loses it, that catch reverts to a review REJECT or a post-bot fix.
assert_pin_unique "sweep 2.3.0a: implement SKILL keeps the sweep body" '#### 2.3.0a Peer-checkpoint completeness sweep' "$IMPL_SKILL"
assert_pin_unique "sweep 2.3.0a: implement SKILL lists it in the always-run index" 'run **2.3.0a**' "$IMPL_SKILL"
assert_eq "sweep 2.3.0a: docs/implement-skill.md keeps the rationale table row" "yes" \
  "$(grep -qF '| 2.3.0a Peer-checkpoint completeness |' "$IMPL_DOC" && echo yes || echo no)"
# Pin one step token unique to the 2.3.0a procedure (the grep-the-peer-set rule) so a
# reviewer who guts the steps but keeps the heading still trips the suite.
assert_pin_unique "sweep 2.3.0a: implement SKILL keeps the enumerate-by-grep step" 'Enumerate the peer set by grep, not from memory' "$IMPL_SKILL"

# Issue #165 Part C: four-mirror-site drift guard for the new 2.3.0b
# enum-enumeration reconciliation sweep — the sibling of 2.3.0a for "a value was
# added to an enumerated set". It lives in four places (sweep body, "Sweep
# selection" index, rationale table, and the DEVFLOW_SYSTEM_OVERVIEW.md sweep-list
# entry pinned below) and must stay in sync; if any loses it, the catch for a
# stale doc/comment enumeration or fall-through consumer reverts to a shadow-review
# finding or a post-bot fix.
# The three SKILL-body pins use assert_pin_unique (exactly-once), matching the 2.3.0a/2.3.6
# sibling sweep-body pins above — not the raw single-line presence form, which #157 AC2's
# repo-wide scanner flags as an un-routed raw SKILL guard. (#166 landed them in the raw form;
# this is the cross-PR reconciliation to #157's widened rule.) The IMPL_DOC / OVERVIEW mirrors
# below stay in presence form like their sibling doc-row pins — the AC2 scanner does not cover
# non-SKILL files.
assert_pin_unique "sweep 2.3.0b: implement SKILL keeps the sweep body" '#### 2.3.0b Enum-enumeration reconciliation sweep' "$IMPL_SKILL"
assert_pin_unique "sweep 2.3.0b: implement SKILL lists it in the Sweep-selection index" 'run **2.3.0b**' "$IMPL_SKILL"
assert_eq "sweep 2.3.0b: docs/implement-skill.md keeps the rationale table row" "yes" \
  "$(grep -qF '| 2.3.0b Enum-enumeration reconciliation |' "$IMPL_DOC" && echo yes || echo no)"
# Pin one step token unique to the 2.3.0b procedure (the grep-every-enumerating-site
# rule) so a reviewer who guts the steps but keeps the heading still trips the suite.
assert_pin_unique "sweep 2.3.0b: implement SKILL keeps the enumerate-every-site step" 'Enumerate every site that names a member of the set, by grep' "$IMPL_SKILL"
# Fourth mirror site (unique to 2.3.0b — 2.3.0a/2.3.6 have no OVERVIEW entry): Part C
# added a sweep-list line in docs/DEVFLOW_SYSTEM_OVERVIEW.md. This PR's own iteration-1
# review caught that line stale, proving it is a coupled mirror — so pin it too, or a
# later edit could silently drop 2.3.0b from the OVERVIEW and the suite would stay green.
assert_eq "sweep 2.3.0b: DEVFLOW_SYSTEM_OVERVIEW keeps the sweep-list entry" "yes" \
  "$(grep -qF '**2.3.0b** Enum-enumeration reconciliation sweep (added value to an enumerated set' "$LIB/../docs/DEVFLOW_SYSTEM_OVERVIEW.md" && echo yes || echo no)"

# Substrate-agnostic re-anchor (issue #171): the "Sweep selection (run first)" preamble
# must state that its trigger shapes apply to prose/SKILL/doc/config as much as to code,
# so an add-only prose/doc/config diff that replicates a peer rule, an enumerated-set
# member, or a mirrored contract literal across sites still trips the contract-completeness
# sweeps (2.3.0 / 2.3.0a / 2.3.0b) rather than falling through to "just the five always-on sweeps".
# Coupled invariant: the re-anchor lives in BOTH the SKILL preamble and its
# docs/implement-skill.md mirror, so pin BOTH sites — a one-sided revert of either back to
# the code-only framing then fails closed (the dominant convention-violation half-revert
# pattern). assert_pin_unique asserts the literal occurs EXACTLY once, so each pin goes RED
# on removal (count 0) AND on accidental duplication (count > 1) — stronger than a bare grep.
# Both literals are ASCII + apostrophe-free per the embedded-jq/SC11xx single-quote trap.
# The mutation property is proven by the assert_pin_unique removal semantics (meta-tested
# elsewhere in this suite).
assert_pin_unique "sweep selection: implement SKILL re-anchors classification on cross-site replication (substrate-agnostic)" \
  "classify by what the change replicates across sites, not by whether it is code" \
  "$IMPL_SKILL"
assert_pin_unique "sweep selection: docs/implement-skill.md mirror carries the substrate-agnostic re-anchor (coupled invariant)" \
  "so the preamble classifies by *what the change replicates across sites*, not by whether it is code" \
  "$IMPL_DOC"
# Pin the OPERATIVE qualifier too, not just the framing clause above: the behavioral fix
# is the sentence that says an add-only prose/doc/config diff still trips 2.3.0/2.3.0a/2.3.0b
# (exactly the PR #166 regression). Reverting only that qualifier back to the unconditional
# "just the five always-on sweeps" — while leaving the pinned re-anchor clause intact — is a
# half-revert that ships the regression; the framing pins above do not catch it. Pin the
# qualifier at BOTH coupled sites so that half-revert fails closed.
assert_pin_unique "sweep selection: implement SKILL qualifies the five-always-on sentence so a replicating prose/doc/config diff still trips the contract sweeps" \
  "still trips the contract-completeness sweeps (**2.3.0** / **2.3.0a** / **2.3.0b**), not just the five" \
  "$IMPL_SKILL"
assert_pin_unique "sweep selection: docs/implement-skill.md mirror qualifies the five-always-on sentence (coupled invariant)" \
  "still runs the contract-completeness sweeps (2.3.0 / 2.3.0a / 2.3.0b)" \
  "$IMPL_DOC"
# Cross-site enumeration check: both sites must name the SAME contract-sweep set.
# Each per-site pin above only checks its own local literal — a site could silently
# drop 2.3.0b while the other keeps it and both pins still pass. Extract the sweep
# IDs (strip markdown bold markers) from each qualifying sentence and assert equality.
_skill_sweeps=$(grep -oE 'still trips the contract-completeness sweeps \([^)]+\)' "$IMPL_SKILL" \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[a-z]*' | sort | tr '\n' ' ' | sed 's/ $//')
_docs_sweeps=$(grep -oE 'still runs the contract-completeness sweeps \([^)]+\)' "$IMPL_DOC" \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[a-z]*' | sort | tr '\n' ' ' | sed 's/ $//')
assert_eq "sweep selection: SKILL and docs enumerate the same contract-sweep set (cross-site)" \
  "$_skill_sweeps" "$_docs_sweeps"

# Drift guard: the base_branch read in the implement skill (phases/phase-1-setup.md) Phase 1.4 is
# a load-bearing inline-bash block in the skill (Phase 3.1's §3.1 re-derivation below is another) — like the max_iterations clamp above, the
# tokens it relies on can be silently broken by a SKILL edit (drop the `|| BASE=""`
# and `git fetch origin ""` runs; drop the fetch guard and a bad base fails with a
# bare git error instead of an attributable DevFlow breadcrumb). Pin the tokens so
# a refactor of the block fails here rather than shipping a silent regression.
# NOTE: the two read+guard literals below (`config-get.sh .base_branch main` and
# `[ -n "$BASE" ]`) now ALSO appear in phases/phase-3-review.md §3.1, which re-derives
# BASE before `gh pr create` (issue #224). So these two pins are scoped to the
# phase-1-setup.md file (where Phase 1.4 lives) rather than the whole bundle, keeping
# them unique-per-file; the phase-3 re-derivation has its own pins further below.
assert_pin_unique "base_branch read: Phase 1.4 reads via config-get with the main default" 'config-get.sh .base_branch main' "$IMPL_PHASES_DIR/phase-1-setup.md"
assert_pin_unique "base_branch read: Phase 1.4 guards the empty read" '[ -n "$BASE" ]' "$IMPL_PHASES_DIR/phase-1-setup.md"
assert_pin_unique "base_branch read: SKILL fetches origin/\$BASE (not hard-coded main)" 'git fetch origin "$BASE"' "$IMPL_SKILL"
assert_pin_unique "base_branch read: SKILL checks out origin/\$BASE" 'git checkout -b "$BRANCH" "origin/$BASE"' "$IMPL_SKILL"
assert_pin_unique "base_branch read: SKILL keeps the attributable fetch-failure breadcrumb" 'could not fetch base branch' "$IMPL_SKILL"
assert_pin_unique "#168 create-path: SKILL guards branch-for-issue.py exit status" \
  'branch-for-issue.py failed' "$IMPL_SKILL"
assert_pin_unique "#168 create-path: SKILL guards against an empty BRANCH name" \
  '[ -n "$BRANCH" ]' "$IMPL_SKILL"

# Issue #224: Phase 3.1 (phases/phase-3-review.md) opens the draft PR against the
# CONFIGURED base_branch, not the GitHub default branch. Because each phase's bash
# block is a SEPARATE shell, Phase 1.4's $BASE is out of scope at 3.1, so 3.1 must
# RE-DERIVE it (same config-get read + fail-closed guard) and pass --base "$BASE" to
# `gh pr create`. Pin both halves against the phase-3 file specifically: dropping the
# --base flag OR the re-derivation guard turns the suite RED (the operand-traceability
# pin ensures the --base pin can't pass with an empty $BASE — the exact bug class).
P3_REVIEW="$IMPL_PHASES_DIR/phase-3-review.md"
# Include the leading `create ` so the pinned literal does not start with `--`
# (pin_count's `grep -oF` would otherwise parse a `--base…` pattern as grep options
# and match nothing): this pins the flag ON the `gh pr create` invocation specifically.
assert_pin_unique "#224 Phase 3.1: gh pr create passes --base \"\$BASE\"" 'create --base "$BASE"' "$P3_REVIEW"
assert_pin_unique "#224 Phase 3.1: re-derives BASE via config-get with the main default" 'config-get.sh .base_branch main' "$P3_REVIEW"
assert_pin_unique "#224 Phase 3.1: re-derives BASE with the fail-closed empty-read guard" '[ -n "$BASE" ]' "$P3_REVIEW"
# The guard PREDICATE `[ -n "$BASE" ]` is only half the fail-closed contract; its
# CONSEQUENT — the `BASE=main` fallback assignment — is what actually keeps `--base`
# from going out empty. Pin it too: a refactor that keeps the predicate but drops the
# `|| { …; BASE=main; }` action would ship `gh pr create --base ""` (the silent
# mistarget this PR exists to prevent) while every predicate/ordering pin stayed GREEN.
assert_pin_unique "#224 Phase 3.1: empty-read guard falls back to main (fail-closed consequent)" 'BASE=main' "$P3_REVIEW"
# Ordering/same-block guard (issue #224 iter 2): the pins above prove the tokens EXIST
# but are positionally independent — a refactor that put `gh pr create --base "$BASE"`
# BEFORE the re-derivation, or split them into separate ```bash fences, would leave them
# all GREEN while $BASE is empty/unset at create time: the exact shell-boundary
# mistarget (`--base ""`) §3.1's prose forbids. Assert the full producer→guard→fallback
# →consumer order WITHIN ONE fenced bash block: the producer (config-get read `d`), the
# fail-closed empty-read guard `[ -n "$BASE" ]` (`g`), AND its `BASE=main` fallback
# action (`f`) all precede the consumer `gh pr create --base "$BASE"` (`c`), in the order
# d < g < f < c. Pinning the fallback action's position too (not just the predicate's)
# catches a refactor that relocates the guard OR drops the fallback action out of the
# create-block — the "guard whose comparand can be absent fails open" class CLAUDE.md
# flags. RED if reordered, split across blocks, or the guard/fallback is moved out of /
# after the create.
assert_eq "#224 Phase 3.1: re-derivation + empty-read guard + main-fallback precede gh pr create in the SAME bash block" "yes" \
  "$(python3 -c '
import sys, re
t = open(sys.argv[1]).read()
ok = "no"
for m in re.finditer(r"```bash\n(.*?)```", t, re.S):
    b = m.group(1)
    if "gh pr create --base \"$BASE\"" in b:
        d = b.find("config-get.sh .base_branch main")
        g = b.find("[ -n \"$BASE\" ]")
        f = b.find("BASE=main")
        c = b.find("gh pr create --base \"$BASE\"")
        if -1 not in (d, g, f, c) and d < g < f < c:
            ok = "yes"
        break
print(ok)
' "$P3_REVIEW")"
# Deferred (issue #224 review, Suggestion): we do NOT pin that §3.1 OMITS --head.
# Low value — `gh pr create` defaults --head to the checked-out branch, which is the
# correct feature branch at Phase 3.1; a future edit adding --head would not corrupt
# the base targeting this fix protects. Revisit only if --head is ever passed here.

# Versioning is per-repo policy, not the engine's job: implement/SKILL.md must carry NO
# version-bump step. A repo that wants version management opts in via its consumer prompt
# extension (.devflow/prompt-extensions/implement.md), which the loader appends to the skill.
# Pin (1) both removed section headings to 0, (2) no stray Phase-2.6/3.1.5 cross-refs, and
# (3) that DevFlow itself re-homes its own rule into that extension so the dogfooded behavior
# is not silently lost. ("Step 2.6" refs elsewhere belong to review-and-fix, not here.)
assert_eq "implement: no version-bump section (versioning is per-repo, not the engine)" "0" \
  "$(grep -cE '^### (2\.6 Version & changelog|3\.1\.5 Apply the version bump)' "$IMPL_SKILL")"
assert_eq "implement: no stray version-phase cross-refs (Phase 2.6 / 3.1.5)" "0" \
  "$(grep -cE '3\.1\.5|Phase 2\.6' "$IMPL_SKILL")"
assert_eq "implement: DevFlow re-homes its versioning rule to the implement prompt extension" "yes" \
  "$(EXT="$LIB/../.devflow/prompt-extensions/implement.md"; [ -s "$EXT" ] && grep -qF 'plugin.json' "$EXT" && grep -qiF 'changelog' "$EXT" && echo yes || echo no)"

# Behavioral coverage for the base_branch read+guard (token pins above catch a
# refactor that DROPS a token, but not a semantic regression in config-get's
# soft/hard contract that the guard depends on). Mirrors the max_iterations
# resolver+clamp pattern: exercise config-get's real exit behavior, then the
# SKILL's inline guard logic against it. Keep byte-aligned with the SKILL block.
BB_CFG="$(mktemp)"
printf '%s' '{"base_branch":"develop"}' > "$BB_CFG"
assert_eq "base_branch: configured value read back verbatim" "develop" \
  "$("$CG" .base_branch main "$BB_CFG")"
printf '%s' '{"devflow":{"effort":"high"}}' > "$BB_CFG"
assert_eq "base_branch: absent key → resolver soft-defaults to main (exit 0)" "main" \
  "$("$CG" .base_branch main "$BB_CFG")"
assert_eq "base_branch: missing config file → resolver soft-defaults to main (exit 0)" "main" \
  "$("$CG" .base_branch main /no/such/config.json)"
# Hard path: a malformed config must exit NON-ZERO with EMPTY stdout (the default is
# NOT applied) — this is the exact contract the inline guard relies on. A regression
# that made config-get emit `main` here would silently mask a malformed-config repo
# onto main; this assertion fails loudly if that contract ever drifts.
printf '%s' '{bad json' > "$BB_CFG"
BB_OUT="$("$CG" .base_branch main "$BB_CFG" 2>/dev/null)"; BB_RC=$?
assert_eq "base_branch: malformed config → resolver exits non-zero, empty stdout" "nonzero-empty" \
  "$([ "$BB_RC" -ne 0 ] && [ -z "$BB_OUT" ] && echo nonzero-empty || echo "rc=$BB_RC out='$BB_OUT'")"
rm -f "$BB_CFG"

# The SKILL's inline empty-read guard (Phase 1.4): an empty OR failed read → 'main'.
# Mirrors `BASE=$(config-get.sh …) || BASE=""; [ -n "$BASE" ] || BASE=main` so the
# fallback is exercised as behavior, not just asserted as text.
base_guard() {
  local v="$1" rc="${2:-0}"
  { [ "$rc" -eq 0 ] && [ -n "$v" ]; } && { printf '%s\n' "$v"; return; }
  printf 'main\n'
}
assert_eq "base_branch guard: configured value honored"            "develop" "$(base_guard develop)"
assert_eq "base_branch guard: empty read (rc 0) → main"            "main"    "$(base_guard '')"
assert_eq "base_branch guard: hard-failure read (rc≠0, empty) → main" "main" "$(base_guard '' 2)"

# Worktree-branch detection (#168): Phase 1.4 must reuse the branch a linked git
# worktree was pre-created on (whatever its name) instead of creating a SECOND
# branch. The signal is naming-independent — a linked worktree's --git-common-dir
# (the main repo's .git) differs from its --git-dir (.git/worktrees/<name>); in the
# main working tree they are equal. Token pins so a SKILL refactor that drops the
# mechanism fails HERE rather than silently regressing to a second branch.
assert_pin_unique "#168 worktree detect: SKILL captures CUR via git branch --show-current" \
  'CUR=$(git branch --show-current 2>/dev/null) || CUR=""' "$IMPL_SKILL"
assert_pin_unique "#168 worktree detect: SKILL reads --git-common-dir in absolute form" \
  'git rev-parse --path-format=absolute --git-common-dir' "$IMPL_SKILL"
assert_pin_unique "#168 worktree detect: SKILL reads --git-dir in absolute form" \
  'git rev-parse --path-format=absolute --git-dir' "$IMPL_SKILL"
assert_pin_unique "#168 worktree detect: SKILL guards reuse against the base branch (never builds on trunk)" \
  '"$CUR" != "$BASE"' "$IMPL_SKILL"
# The base/detached-HEAD guard must wrap BOTH reuse signals (Signal 2's name match too),
# so a base branch named like a feature branch (base_branch=issue-next) still CREATEs.
# Pin the breadcrumb so the silent-degrade path stays attributable.
# Wording covers both symmetric (both-empty) and asymmetric (one-empty) trigger cases.
assert_pin_unique "#168 worktree detect: SKILL leaves a breadcrumb when git-dir paths are empty" \
  'one or both git-dir path values are empty' "$IMPL_SKILL"
assert_pin_unique "#168 worktree detect: SKILL breadcrumb names asymmetric env-override as a cause" \
  'injected GIT_DIR/GIT_COMMON_DIR env override' "$IMPL_SKILL"
assert_pin_unique "#168 create-path: SKILL gates create block on USE_CURRENT being unset" \
  '[ -z "$USE_CURRENT" ]' "$IMPL_SKILL"
assert_eq "#168 worktree detect: SKILL names the linked-worktree signal" "yes" \
  "$(grep -qF 'linked worktree' "$IMPL_SKILL" && echo yes || echo no)"  # raw-guard-ok: non-unique: token appears in both prose and code (4 occurrences)
assert_pin_unique "#168 worktree detect: SKILL keeps the cloud-tier name match as a second skip condition" \
  'claude/issue-*|issue-*) USE_CURRENT=1' "$IMPL_SKILL"

# Behavioral coverage: mirror Phase 1.4's reuse-vs-create decision and exercise the
# whole matrix. Keep behaviorally aligned with the SKILL block (it is a restructured
# mirror — early-return form — not a byte-for-byte copy). Echoes "reuse" (skip creation,
# use CUR) or "create" (fall through to branch-for-issue.py). The non-empty + != base
# guards wrap BOTH signals exactly as the SKILL hoists them; an empty common==gitdir
# (rev-parse failed) collapses Signal 1 to "not a worktree" → create (fail-closed).
# Source of truth: SKILL Phase 1.4 (F-8 deferred: token pins catch removal but not a
# predicate-shape change; F-9 deferred: --path-format=absolute normalization is not
# exercised here — the mirror receives pre-resolved strings; a real-git integration test
# would be needed to cover the rev-parse call itself).
#   decide_branch <git-common-dir> <git-dir> <CUR> <BASE>
decide_branch() {
  local common="$1" gitdir="$2" cur="$3" base="$4"
  # Guards apply to BOTH reuse signals: never reuse a detached HEAD (empty CUR) or the
  # base branch (build on trunk), regardless of which signal would otherwise match.
  if [ -n "$cur" ] && [ "$cur" != "$base" ]; then
    # Signal 1 — linked worktree: common-dir != git-dir (both absolute, both non-empty).
    [ -n "$common" ] && [ -n "$gitdir" ] && [ "$common" != "$gitdir" ] && { echo reuse; return; }
    # Signal 2 — cloud-tier name match (GitHub Action path; not a worktree).
    case "$cur" in
      claude/issue-*|issue-*) echo reuse; return ;;
    esac
  fi
  echo create
}
# AC1+AC2: in a linked worktree, a harness branch whose name matches NEITHER pattern
# is still reused via the worktree signal — exactly the case that used to create a
# second branch.
assert_eq "#168 worktree detect: worktree + worktree-issue-165 (name matches neither) → reuse" "reuse" \
  "$(decide_branch /repo/.git /repo/.git/worktrees/issue-165 worktree-issue-165 main)"
# Overlap: worktree AND a name-matching branch (both signals true) → reuse (locks the
# both-true path so a future refactor can't make the signals mutually exclusive).
assert_eq "#168 worktree detect: worktree + issue-9 (both signals true) → reuse" "reuse" \
  "$(decide_branch /repo/.git /repo/.git/worktrees/x issue-9 main)"
# AC3: cloud-tier name detection still skips creation, in the main working tree (no worktree).
assert_eq "#168 worktree detect: main tree + issue-5 → reuse (name match)" "reuse" \
  "$(decide_branch /repo/.git /repo/.git issue-5 main)"
assert_eq "#168 worktree detect: main tree + claude/issue-5 → reuse (name match)" "reuse" \
  "$(decide_branch /repo/.git /repo/.git claude/issue-5 main)"
# AC4 (fail-closed): inside a worktree but ON the base branch → CREATE, never reuse —
# the change must never build directly on trunk.
assert_eq "#168 worktree detect: worktree + base branch (main) → create [fail-closed]" "create" \
  "$(decide_branch /repo/.git /repo/.git/worktrees/x main main)"
assert_eq "#168 worktree detect: worktree + base branch (develop) → create [fail-closed]" "create" \
  "$(decide_branch /repo/.git /repo/.git/worktrees/x develop develop)"
# AC4 (peer completeness): the base guard wraps Signal 2 too — a base branch NAMED like a
# feature branch (base_branch=issue-5) must still CREATE, not reuse via the name match,
# in the main tree AND inside a worktree.
assert_eq "#168 worktree detect: main tree + base named issue-5 (CUR==BASE) → create [fail-closed]" "create" \
  "$(decide_branch /repo/.git /repo/.git issue-5 issue-5)"
assert_eq "#168 worktree detect: worktree + base named issue-5 (CUR==BASE) → create [fail-closed]" "create" \
  "$(decide_branch /repo/.git /repo/.git/worktrees/x issue-5 issue-5)"
# Fail-closed: detached HEAD inside a worktree (empty CUR) → CREATE, never reuse an empty branch.
assert_eq "#168 worktree detect: worktree + detached HEAD (empty CUR) → create [fail-closed]" "create" \
  "$(decide_branch /repo/.git /repo/.git/worktrees/x '' main)"
# Fail-closed: git rev-parse FAILED (empty common == empty gitdir) → Signal 1 collapses
# to "not a worktree"; a non-matching name then CREATEs (with the SKILL breadcrumb).
assert_eq "#168 worktree detect: rev-parse failure (empty dirs) + worktree-issue-165 → create [fail-closed]" "create" \
  "$(decide_branch '' '' worktree-issue-165 main)"
# Asymmetric rev-parse (one empty, one populated — injected GIT_DIR or transient failure)
# must also create, not false-positive-reuse via Signal 1 (the != inequality is vacuously
# true when one operand is empty; the non-empty guard closes this).
assert_eq "#168 worktree detect: asymmetric rev-parse (common empty, gitdir set) → create [fail-closed]" "create" \
  "$(decide_branch '' '/repo/.git/worktrees/x' worktree-issue-165 main)"
assert_eq "#168 worktree detect: asymmetric rev-parse (common set, gitdir empty) → create [fail-closed]" "create" \
  "$(decide_branch '/repo/.git' '' worktree-issue-165 main)"
# AC5: not in a worktree and not a recognized feature branch → CREATE (branch-for-issue.py path).
assert_eq "#168 worktree detect: main tree + feature-x (no worktree, no name match) → create" "create" \
  "$(decide_branch /repo/.git /repo/.git feature-x main)"
assert_eq "#168 worktree detect: main tree + base branch → create" "create" \
  "$(decide_branch /repo/.git /repo/.git main main)"

# ────────────────────────────────────────────────────────────────────────────
echo "devflow_implement.implement_pr_state (schema + resolution + Phase 4.3 gate)"
# ────────────────────────────────────────────────────────────────────────────
# implement_pr_state gates whether /devflow:implement Phase 4.3 publishes the PR
# (runs `gh pr ready`) or leaves it the draft created in Phase 3.1. The resolution
# boundary is config-get.sh (a deterministic string), so it is unit-testable here;
# the Phase 4.3 prose change (whether `gh pr ready` runs) is non-executable skill
# instructions, pinned below by token + an executable publish-decision guard that
# mirrors the SKILL's single literal-`draft` comparison. Default-to-publish is the
# safe direction: only the exact literal `draft` suppresses publishing.
IPS_SCHEMA="$LIB/../.devflow/config.schema.json"
IPS_EXAMPLE="$LIB/../.devflow/config.example.json"
IPS_PROP='.properties.devflow_implement.properties.implement_pr_state'
assert_eq "implement_pr_state: schema type is string" "string" \
  "$(jq -r "$IPS_PROP.type" "$IPS_SCHEMA")"
assert_eq "implement_pr_state: schema enum is [ready_for_review, draft]" "ready_for_review,draft" \
  "$(jq -r "$IPS_PROP.enum | join(\",\")" "$IPS_SCHEMA")"
assert_eq "implement_pr_state: schema default is ready_for_review" "ready_for_review" \
  "$(jq -r "$IPS_PROP.default" "$IPS_SCHEMA")"
assert_eq "implement_pr_state: schema has a non-empty description" "yes" \
  "$(jq -e "$IPS_PROP.description | type == \"string\" and (length > 0)" "$IPS_SCHEMA" >/dev/null && echo yes || echo no)"
assert_eq "implement_pr_state: example value matches schema default" \
  "$(jq -r "$IPS_PROP.default" "$IPS_SCHEMA")" \
  "$(jq -r '.devflow_implement.implement_pr_state' "$IPS_EXAMPLE")"

# Resolver-read behavior (the string the SKILL's Phase 4.3 reads). config-get maps an
# absent key OR an empty-string value to the supplied default (ready_for_review); any
# other value is returned verbatim and the SKILL treats non-`draft` as publish.
IPS_CFG="$(mktemp)"
printf '%s' '{"devflow_implement":{"implement_pr_state":"draft"}}' > "$IPS_CFG"
assert_eq "implement_pr_state: configured 'draft' read back verbatim" "draft" \
  "$("$CG" .devflow_implement.implement_pr_state ready_for_review "$IPS_CFG")"
printf '%s' '{"devflow_implement":{"implement_pr_state":"ready_for_review"}}' > "$IPS_CFG"
assert_eq "implement_pr_state: configured 'ready_for_review' read back verbatim" "ready_for_review" \
  "$("$CG" .devflow_implement.implement_pr_state ready_for_review "$IPS_CFG")"
printf '%s' '{"devflow_implement":{}}' > "$IPS_CFG"
assert_eq "implement_pr_state: absent key → resolver default ready_for_review" "ready_for_review" \
  "$("$CG" .devflow_implement.implement_pr_state ready_for_review "$IPS_CFG")"
printf '%s' '{"devflow_implement":{"implement_pr_state":""}}' > "$IPS_CFG"
assert_eq "implement_pr_state: empty-string value → resolver default ready_for_review" "ready_for_review" \
  "$("$CG" .devflow_implement.implement_pr_state ready_for_review "$IPS_CFG")"
printf '%s' '{"devflow_implement":{"implement_pr_state":"published"}}' > "$IPS_CFG"
assert_eq "implement_pr_state: unrecognized value read back verbatim (SKILL treats as publish)" "published" \
  "$("$CG" .devflow_implement.implement_pr_state ready_for_review "$IPS_CFG")"
assert_eq "implement_pr_state: missing config file → resolver default ready_for_review" "ready_for_review" \
  "$("$CG" .devflow_implement.implement_pr_state ready_for_review /no/such/config.json)"
# Hard read failure (malformed JSON): config-get exits NON-zero with EMPTY stdout — the
# exact contract the SKILL's `PR_STATE=$(…) || PR_STATE=ready_for_review` fallback leans
# on. This is the headline safety property (default-to-publish on a corrupt config); pin
# the resolver half here and the end-to-end half in the guard below.
printf '%s' '{bad json' > "$IPS_CFG"
IPS_OUT="$("$CG" .devflow_implement.implement_pr_state ready_for_review "$IPS_CFG" 2>/dev/null)"; IPS_RC=$?
assert_eq "implement_pr_state: malformed config → resolver exits non-zero, empty stdout" "nonzero-empty" \
  "$([ "$IPS_RC" -ne 0 ] && [ -z "$IPS_OUT" ] && echo nonzero-empty || echo "rc=$IPS_RC out='$IPS_OUT'")"
rm -f "$IPS_CFG"

# SKILL Phase 4.3 token pins: the gate is one piece of load-bearing inline bash in
# the implement skill (phases/phase-4-documentation.md). Pin the tokens so a refactor that drops them fails here rather
# than silently always-publishing (or always-drafting).
assert_pin_unique "implement_pr_state: SKILL reads via config-get with the ready_for_review default" 'config-get.sh .devflow_implement.implement_pr_state ready_for_review' "$IMPL_SKILL"
assert_pin_unique "implement_pr_state: SKILL gates publish on the literal draft" '[ "$PR_STATE" = "draft" ]' "$IMPL_SKILL"
# Pin the *command* form, not the bare token: a plain `grep -qF 'gh pr ready'` is also
# satisfied by the draft-branch diagnostic echo and the explanatory prose, so it would
# stay green even if the actual publish invocation were deleted. Pin the guarded
# `elif gh pr ready; then` so this asserts the publish command itself survives.
assert_pin_unique "implement_pr_state: SKILL keeps the guarded publish invocation (elif gh pr ready)" 'elif gh pr ready; then' "$IMPL_SKILL"
assert_pin_unique "implement_pr_state: SKILL keeps the clean-tree backstop above the gate" 'git status --porcelain' "$IMPL_SKILL"
assert_pin_unique "implement_pr_state: SKILL has draft-aware finalize wording" 'left as draft' "$IMPL_SKILL"

# Executable publish-decision guard — logic-equivalent to the SKILL's single literal-`draft`
# comparison (semantically mirrors `[ "$PR_STATE" = "draft" ]`; `$1` stands in for
# `$PR_STATE`) so the dry-trace matrix {draft, ready_for_review, "", published} is
# exercised as behavior, not just asserted as prose (the absent/default row is the
# resolver matrix above feeding `ready_for_review` into this guard; the publish arm's
# success/failure split is modeled separately by `ips_outcome` below).
ips_publishes() {
  [ "$1" = "draft" ] && { printf 'draft\n'; return; }
  printf 'publish\n'
}
assert_eq "implement_pr_state gate: 'draft' → leave draft"             "draft"   "$(ips_publishes draft)"
assert_eq "implement_pr_state gate: 'ready_for_review' → publish"      "publish" "$(ips_publishes ready_for_review)"
assert_eq "implement_pr_state gate: empty string → publish"           "publish" "$(ips_publishes '')"
assert_eq "implement_pr_state gate: unrecognized 'published' → publish" "publish" "$(ips_publishes published)"

# End-to-end read+guard, mirroring the SKILL's full Phase 4.3 line
# `PR_STATE=$(config-get … ready_for_review) || PR_STATE=ready_for_review` then the
# literal-`draft` decision. This exercises the load-bearing safety property — a hard
# resolver failure (malformed config) falls back to PUBLISH — through the real resolver,
# which the `ips_publishes` matrix alone does not cover.
ips_state_decision() {
  local st
  st="$("$CG" .devflow_implement.implement_pr_state ready_for_review "$1" 2>/dev/null)" || st=ready_for_review
  ips_publishes "$st"
}
IPS_E2E="$(mktemp)"
printf '%s' '{"devflow_implement":{"implement_pr_state":"draft"}}' > "$IPS_E2E"
assert_eq "implement_pr_state e2e: configured draft → leave draft"        "draft"   "$(ips_state_decision "$IPS_E2E")"
printf '%s' '{"devflow_implement":{}}' > "$IPS_E2E"
assert_eq "implement_pr_state e2e: absent key → publish"                  "publish" "$(ips_state_decision "$IPS_E2E")"
printf '%s' '{bad json' > "$IPS_E2E"
assert_eq "implement_pr_state e2e: malformed config (resolver hard-fail) → publish" "publish" "$(ips_state_decision "$IPS_E2E")"
rm -f "$IPS_E2E"

# Outcome guard mirroring the SKILL's FOUR-arm Phase 4.3 chain:
#   1. PR_STATE=draft                          → draft (no gh pr ready)
#   2. gh pr ready succeeds                     → published
#   3. gh pr ready fails BUT PR is non-draft    → published (idempotent re-run: gh pr ready
#                                                 returns non-zero on an already-ready PR)
#   4. else (still draft, or state unknown)     → publish_failed (fail-safe direction)
# The publish_failed capture (the workpad never falsely claims a PR was published on a
# `gh pr ready` failure) and the idempotent arm (a re-run of an already-published PR is
# NOT a failure) are the headline correctness properties of this change. Modelling all
# four arms here — plus the token pins below for the idempotent re-check command and
# breadcrumb — means a refactor that dropped the `else` arm OR the idempotent arm is
# caught. $1 = PR_STATE, $2 = simulated `gh pr ready` exit (0 ok / non-0), $3 = simulated
# `isDraft` re-check result ("true"/"false"/"" when the re-check itself errored).
ips_outcome() {
  [ "$1" = "draft" ] && { printf 'draft\n'; return; }
  if [ "${2:-0}" -eq 0 ]; then printf 'published\n'; return; fi
  [ "${3:-}" = "false" ] && { printf 'published\n'; return; }   # gh failed but PR already non-draft
  printf 'publish_failed\n'                                     # still draft, or state unconfirmed
}
assert_eq "implement_pr_state outcome: draft → draft (no gh pr ready)"                  "draft"          "$(ips_outcome draft 0)"
assert_eq "implement_pr_state outcome: publish + gh pr ready ok → published"            "published"      "$(ips_outcome ready_for_review 0)"
assert_eq "implement_pr_state outcome: gh fails + PR still draft → publish_failed"      "publish_failed" "$(ips_outcome ready_for_review 1 true)"
assert_eq "implement_pr_state outcome: gh fails + PR already non-draft → published (idempotent)" "published" "$(ips_outcome ready_for_review 1 false)"
assert_eq "implement_pr_state outcome: gh fails + state unconfirmed (re-check errored) → publish_failed (fail-safe)" "publish_failed" "$(ips_outcome ready_for_review 1 '')"

# Token pins for the publish_failed failure-capture branch, the idempotent re-run arm, and
# the outcome-specific finalize wording — the prior pass pinned only the draft note
# (`left as draft`), leaving the load-bearing "never falsely claim published" path and the
# idempotent re-check uncovered (a refactor dropping the isDraft arm would stay green).
assert_eq "implement_pr_state: SKILL captures the publish_failed outcome (gh pr ready failure not swallowed)" "yes" \
  "$(grep -qF 'PR_OUTCOME=publish_failed' "$IMPL_SKILL" && echo yes || echo no)"  # raw-guard-ok: non-unique: appears twice in implement SKILL (publish-failed paths)
assert_eq "implement_pr_state: SKILL leaves a gh-pr-ready failure breadcrumb" "yes" \
  "$(grep -qF 'gh pr ready FAILED' "$IMPL_SKILL" && echo yes || echo no)"  # raw-guard-ok: non-unique: appears twice in implement SKILL (publish-failed paths)
assert_pin_unique "implement_pr_state: SKILL keeps the idempotent already-non-draft re-check" 'gh pr view --json isDraft' "$IMPL_SKILL"
assert_eq "implement_pr_state: SKILL labels the idempotent re-run breadcrumb" "yes" \
  "$(grep -qF 'idempotent re-run' "$IMPL_SKILL" && echo yes || echo no)"  # raw-guard-ok: non-unique: 'idempotent re-run' appears twice in implement SKILL
# Couple the fail-safe construct: the re-check must redirect stderr (empty-on-error) AND
# compare against the literal `= "false"` — so an unconfirmed/errored re-check (empty
# substitution) is `!= "false"` and falls through to publish_failed (the conservative
# direction). Pinning the two together catches a silent fail-safe inversion (e.g. someone
# rewriting it as `!= "true"`, under which an empty result would wrongly read as published).
assert_pin_unique "implement_pr_state: SKILL idempotent re-check is fail-safe (2>/dev/null coupled to = \"false\")" '2>/dev/null)" = "false" ]' "$IMPL_SKILL"
assert_pin_unique "implement_pr_state: SKILL has a distinct published-outcome note" 'PR published (gh pr ready)' "$IMPL_SKILL"
assert_pin_unique "implement_pr_state: draft case posts no extra PR-thread comment (AC7)" 'no additional comment' "$IMPL_SKILL"

# Positional check: the clean-tree backstop must run ABOVE the publish gate (the diff's
# behavioral change is that it runs unconditionally in BOTH publish and draft cases), not
# merely be present somewhere. Assert line ordering, not bare presence.
# issue #218: grep the OWNING phase file, NOT the bundle. Both literals live in Phase 4.3
# (phases/phase-4-documentation.md). A POSITIONAL guard needs a single coordinate space with
# both endpoints unique; on the multi-file bundle, `head -1` of the generic `git status
# --porcelain` idiom could grab a future earlier-phase occurrence (lower bundle line number),
# making `-lt` pass vacuously. The owning file is the only space where both endpoints stay unique.
IPS_BACKSTOP_LN=$(grep -nF 'git status --porcelain' "$IMPL_PHASES_DIR/phase-4-documentation.md" | head -1 | cut -d: -f1)
IPS_GATE_LN=$(grep -nF '[ "$PR_STATE" = "draft" ]' "$IMPL_PHASES_DIR/phase-4-documentation.md" | head -1 | cut -d: -f1)
assert_eq "implement_pr_state: clean-tree backstop precedes the publish gate (runs in both cases)" "yes" \
  "$([ -n "$IPS_BACKSTOP_LN" ] && [ -n "$IPS_GATE_LN" ] && [ "$IPS_BACKSTOP_LN" -lt "$IPS_GATE_LN" ] && echo yes || echo no)"

# Cross-file Progress-label consistency. The Phase 4.3 finalize `--tick-progress` label
# in phases/phase-4-documentation.md MUST match the `## Progress` row label that scripts/workpad.py
# OWNS (its cmd_new_body template + _PROGRESS_PHASES tuple + _STATUS_TO_PROGRESS_PHASE
# 'complete' map) — workpad.py both renders the row and ticks it by substring, so if the
# two sides drift the finalize finds no matching unticked row and the Phase 4.3 update
# ABORTS. (This guards the exact desync a mid-review rename of the row to "PR finalized"
# introduced: SKILL renamed, workpad.py not.) Both sides are pinned to the same literal,
# so renaming one without the other goes red here.
WP_PY="$LIB/../scripts/workpad.py"
# NB: `--` ends grep's option parsing — the pattern begins with `--tick-progress`, which
# grep would otherwise treat as an (invalid) long option.
assert_eq "implement finalize: SKILL ticks the workpad.py-owned 'PR marked ready' label" "yes" \
  "$(grep -qF -- '--tick-progress "PR marked ready"' "$IMPL_SKILL" && echo yes || echo no)"  # raw-guard-ok: literal begins with --; incompatible with pin_count's unguarded grep -oF
assert_eq "implement finalize: workpad.py owns the 'PR marked ready' label (template + _PROGRESS_PHASES agree)" "yes" \
  "$(grep -qF '**PR marked ready**' "$WP_PY" && grep -qF "'PR marked ready'" "$WP_PY" && echo yes || echo no)"

# ── issue #169: workpad.py tick failure-isolation + index ticking ─────────────
# Coupled contract across three files: scripts/workpad.py (the volatile-vs-structural
# behavior + the new --tick-ac-n/--tick-plan-n flags) ↔ the implement-skill bundle (the
# `workpad.py update` flag-table in the orchestrator SKILL.md AND the Phase 3.4 AC-tick
# call sites in phases/phase-3-review.md) ↔ this suite.
# The flag-table must document the index flags and the failure-isolation
# contract, and the Phase 3.4 gate must tick ACs by index rather than hand-picked
# substrings (the eight-fragile-substring foot-gun this issue removes). Editing one
# side without the others goes red here. (workpad.py's runtime behavior is pinned
# exhaustively in lib/test/test_python_scripts.py; these are the doc-mirror pins.)
assert_eq "#169: workpad.py defines the --tick-ac-n / --tick-plan-n index flags" "yes" \
  "$(grep -qF -- '--tick-ac-n' "$WP_PY" && grep -qF -- '--tick-plan-n' "$WP_PY" && echo yes || echo no)"
# SKILL-targeted pins route through assert_pin_unique (#157 AC2 raw-guard rule): the
# flag-table ROW literal is target-unique (count 1), so it pins exactly the doc row —
# stronger than a bare flag mention (which recurs across the table + call sites).
assert_pin_unique "#169: implement/SKILL.md flag-table documents --tick-ac-n (index AC tick)" \
  '| `--tick-ac-n N`' "$IMPL_SKILL"
assert_pin_unique "#169: implement/SKILL.md flag-table documents --tick-plan-n (index Plan tick)" \
  '| `--tick-plan-n N`' "$IMPL_SKILL"
# The named contract heading is target-unique (a bare 'volatile' grep would stay green
# if the contract paragraph were deleted but the word survived elsewhere).
assert_pin_unique "#169: implement/SKILL.md carries the named volatile-vs-structural failure-isolation contract" \
  'Failure-isolation contract (volatile vs. structural)' "$IMPL_SKILL"
# ABSENCE pin (the hand-picked substring example must be GONE) — assert_pin_unique
# (count==1) cannot express absence, so it carries an explicit #157 allowlist marker.
assert_eq "#169: Phase 3.4 AC-tick uses the index form (no hand-picked '{substring of AC text}')" "yes" \
  "$(grep -qF -- '--tick-ac "{substring of AC text}"' "$IMPL_SKILL" && echo no || echo yes)"  # raw-guard-ok: absence pin — the superseded substring example must be GONE
# Finding 1 (review): the gate must CONSUME the new non-zero-exit contract — the SKILL
# tells callers a tick's non-zero exit means it did not land (never advance on the
# stdout body alone). Target-unique phrase → assert_pin_unique.
assert_pin_unique "#169: implement/SKILL.md tells callers to check the tick exit code, not the stdout body alone" \
  'never advance on the stdout body alone' "$IMPL_SKILL"
# Finding 4 (review): ABSENCE pin — the stale '--tick-ac later' note must be gone
# (replaced by '--tick-ac-n'); allowlist marker per #157 (absence is not expressible
# via assert_pin_unique).
assert_eq "#169: implement/SKILL.md 2.2.6 note references the index gate-tick flag (no stale '--tick-ac later')" "yes" \
  "$(grep -qF 'will tick via `--tick-ac` later' "$IMPL_SKILL" && echo no || echo yes)"  # raw-guard-ok: absence pin — the superseded '--tick-ac later' note must be GONE
# Shadow Finding 2 (review): the SKILL tells callers a volatile miss already PATCHed the
# status/notes, so on a non-zero exit they re-tick ONLY the row(s) and do not re-send the
# whole call (which would double-write append-only notes). Coupled with workpad.py's
# breadcrumb wording, which test_python_scripts.py shadow-F2 pins. Target-unique phrase.
assert_pin_unique "#169: implement/SKILL.md warns re-tick-only (don't re-send the whole call on a volatile miss)" \
  'do not blindly re-send the whole call' "$IMPL_SKILL"
# Shadow Finding 1 (review): workpad.py reports volatile misses on the gh-PATCH-failure
# path too (not just the structural-abort and clean-PATCH paths), via the single
# _report_failed_ticks chokepoint — so a miss collected before a 5xx/auth PATCH failure
# is never silently dropped. test_python_scripts.py shadow-F1 pins the behavior.
assert_eq "#169: workpad.py routes volatile misses through _report_failed_ticks (PATCH-failure echo)" "yes" \
  "$(grep -qF 'def _report_failed_ticks' "$WP_PY" && grep -qF 'NO workpad change was persisted' "$WP_PY" && echo yes || echo no)"

# ── issue #258: terminal --status Complete self-record gate ───────────────────
# scripts/workpad.py, on a `--status Complete` write, must reconcile the workpad's
# self-record against reality: hard-fail (structural: non-zero exit, NO PATCH,
# Status not flipped) when any NON-post-merge ## Acceptance Criteria row is still
# `- [ ]`, and emit a NON-blocking stderr warning naming any unticked ## Plan row
# while still finalizing. The gate fires ONLY for --status Complete; it never
# modifies a `- [ ]` row. Exercised here as a real CLI subprocess against a gh
# stub (the five AC-7 scenarios), and pinned exhaustively at the _apply_mutations
# level in lib/test/test_python_scripts.py. Two scenarios go RED against the
# pre-gate workpad.py — (a): old code PATCHed Complete over an unticked AC; (c):
# old code emitted no Plan warning. (b)/(d)/(e) are controls that pass identically
# on old and new code — they guard against the gate OVER-firing (post-merge-only,
# all-ticked, and --status Blocked must NOT be blocked or warned).
S258="$(mktemp -d)"
cat > "$S258/gh" <<'STUB'
#!/usr/bin/env bash
# Minimal gh stub for workpad.py update: repo view, comments list (marker match),
# body fetch, and PATCH (records that a PATCH happened + echoes the patched body).
j="$*"
if [[ "$j" == *"repo view"* ]]; then echo "owner/repo"; exit 0; fi
if [[ "$j" == *"-X PATCH"* ]]; then
  echo p >> "$WP_PATCHLOG"
  for a in "$@"; do case "$a" in body=@*) cat "${a#body=@}";; esac; done
  exit 0
fi
if [[ "$j" == *"issues/comments/7"* ]]; then cat "$WP_BODY"; exit 0; fi
if [[ "$j" == *"issues/999/comments"* ]]; then echo '[{"id":7,"body":"<!-- devflow:workpad -->"}]'; exit 0; fi
echo '[]'
STUB
chmod +x "$S258/gh"

# Fixture bodies. Base = every Plan/AC row ticked (the clean-run shape).
cat > "$S258/all-ticked.md" <<'WPMD'
<!-- devflow:workpad -->
# DevFlow Workpad — Issue #999

**Status:** 🚀 Documenting
**Last updated:** 2026-05-15T00:00:00Z

## Progress
- [x] **Setup**

## Plan
- [x] Plan step one
- [x] Plan step two

## Acceptance Criteria
- [x] AC one
- [x] AC two
WPMD
# (a) a non-post-merge AC row still unticked.
sed 's/- \[x\] AC two/- [ ] AC two/' "$S258/all-ticked.md" > "$S258/ac-unticked.md"
# (b) the ONLY outstanding AC row carries the (post-merge) marker.
sed 's/- \[x\] AC two/- [ ] AC two (post-merge)/' "$S258/all-ticked.md" > "$S258/ac-postmerge.md"
# (c) a ## Plan row unticked, every AC ticked.
sed 's/- \[x\] Plan step two/- [ ] Plan step two/' "$S258/all-ticked.md" > "$S258/plan-unticked.md"

# run258 <body-file> <args...> → prints the exit code; leaves out/err/patchlog on disk.
run258() {
  local body="$1"; shift
  : > "$S258/patchlog"
  WP_BODY="$body" WP_PATCHLOG="$S258/patchlog" DEVFLOW_GH="$S258/gh" \
    python3 "$WP_PY" update 999 "$@" >"$S258/out" 2>"$S258/err"
  echo $?
}

# (a) --status Complete aborts non-zero with NO PATCH when a non-post-merge AC is [ ].
_c="$(run258 "$S258/ac-unticked.md" --status Complete)"
assert_eq "#258(a): --status Complete aborts non-zero on an unticked non-post-merge AC" "no" \
  "$([ "$_c" = "0" ] && echo yes || echo no)"
assert_eq "#258(a): the abort made NO PATCH (self-record not flipped to Complete)" "yes" \
  "$([ -s "$S258/patchlog" ] && echo no || echo yes)"
assert_eq "#258(a): the abort names the offending AC row on stderr" "yes" \
  "$(grep -q 'AC two' "$S258/err" && echo yes || echo no)"

# (b) only outstanding AC is (post-merge) → finalizes normally (PATCH, Status flipped).
_c="$(run258 "$S258/ac-postmerge.md" --status Complete)"
assert_eq "#258(b): a post-merge-only outstanding AC finalizes (exit 0)" "0" "$_c"
assert_eq "#258(b): the post-merge-only finalize PATCHed the Status to Complete" "yes" \
  "$(grep -q '🎉 Complete' "$S258/out" && echo yes || echo no)"

# (c) a ## Plan row unticked → succeeds-with-warning (non-blocking), Status flips.
_c="$(run258 "$S258/plan-unticked.md" --status Complete)"
assert_eq "#258(c): an unticked Plan row does NOT block finalize (exit 0)" "0" "$_c"
assert_eq "#258(c): finalize emits a non-blocking Plan warning naming the unticked row" "yes" \
  "$(grep -qi 'plan' "$S258/err" && grep -q 'Plan step two' "$S258/err" && echo yes || echo no)"
assert_eq "#258(c): the Plan-warning finalize still flipped Status to Complete" "yes" \
  "$(grep -q '🎉 Complete' "$S258/out" && echo yes || echo no)"

# (d) all rows ticked → succeeds silently (no AC abort, no Plan warning).
_c="$(run258 "$S258/all-ticked.md" --status Complete)"
assert_eq "#258(d): a fully-ticked run finalizes (exit 0)" "0" "$_c"
assert_eq "#258(d): a fully-ticked finalize emits NO Plan/AC gate warning" "yes" \
  "$(grep -qiE 'unticked|refusing to finalize' "$S258/err" && echo no || echo yes)"

# (e) --status Blocked with an unticked AC is NEVER gated (behaves as today).
_c="$(run258 "$S258/ac-unticked.md" --status Blocked)"
assert_eq "#258(e): --status Blocked with an unticked AC is not gated (exit 0)" "0" "$_c"
assert_eq "#258(e): --status Blocked with an unticked AC still PATCHed (Status → Blocked)" "yes" \
  "$([ -s "$S258/patchlog" ] && grep -q '👎 Blocked' "$S258/out" && echo yes || echo no)"

# Source pin: the terminal gate + its post-merge exclusion live in workpad.py.
assert_eq "#258: workpad.py carries the terminal --status Complete self-record gate" "yes" \
  "$(grep -q '_terminal_complete_gate' "$WP_PY" && grep -q "(post-merge)" "$WP_PY" && echo yes || echo no)"
rm -rf "$S258"

# ── Issue #184: Phase 1.6 Issue-Claim Audit ──────────────────────────────
# Five assert_pin_red_on_removal guards + five assert_pin_unique pins.
# assert_pin_red_on_removal: presence+uniqueness (PASS-before) + deletion
# (FAIL-after) in one probe, satisfying AC7 — it guards the audit heading,
# the three claim-type literals (count/negative-scope/policy-referencing),
# and the mandatory cloud-tier check. assert_pin_unique guards five
# behavioral contracts: the --status Blocked contract on the Pass 3
# contradiction path, the cloud-tier vendored-copy existence test and its
# absent-vs-no-impact disambiguation (no fail-open), the use of the verified
# count as the working assumption, and the plan-expansion action.
assert_pin_unique "#184: Phase 1.6 blocked path carries --status Blocked on the policy-contradiction call" \
  'update $ISSUE_NUMBER --status Blocked --reflection-kind blocked --reflection "issue-claim audit (policy)' "$IMPL_SKILL"
assert_pin_red_on_removal "#184: deleting the cloud-tier mandatory check turns its pin RED" \
  'Cloud-tier workflow impact check (mandatory when editing any' "$IMPL_SKILL"
# Review (1/5 agents): the vendored-copy grep must NOT fail open — an absent vendored
# file (commonly absent) must be distinguishable from "helper missing from TOOLS=".
# Pin the existence-test guard + the explicit "NOT a no-impact result" disambiguation
# so a regression back to a stderr-suppressed `grep … 2>/dev/null` goes RED here.
assert_pin_unique "#184: cloud-tier check tests the vendored copy for existence (no fail-open on absent file)" \
  'if [ -f "$VENDORED" ]; then' "$IMPL_SKILL"
assert_pin_unique "#184: cloud-tier check disambiguates absent-vendored-file from a no-impact result" \
  'absent — check not applicable (NOT a no-impact result)' "$IMPL_SKILL"
assert_pin_unique "#184: Pass 1 discrepancy uses verified count as working assumption (not issue body count)" \
  'Use the verified count as the working assumption from Phase 2 onward' "$IMPL_SKILL"
assert_pin_unique "#184: Pass 2 discrepancy adds missed surface to working plan (not just records a note)" \
  'add the missed surface to the working plan before 2.2 begins' "$IMPL_SKILL"
assert_pin_red_on_removal "#184: deleting the audit heading turns its pin RED" \
  '### 1.6 Issue-Claim Audit' "$IMPL_SKILL"
assert_pin_red_on_removal "#184: deleting the count-claim type literal turns its pin RED" \
  'Count or enumeration claims' "$IMPL_SKILL"
assert_pin_red_on_removal "#184: deleting the negative-scope type literal turns its pin RED" \
  'explicit surface exclusions' "$IMPL_SKILL"
assert_pin_red_on_removal "#184: deleting the policy-referencing type literal turns its pin RED" \
  'Policy-referencing claims in ACs' "$IMPL_SKILL"
# ── issue #254: Phase 1.6 gains Pass 4 — declared sequencing-dependency claims.
# An issue stating it "must merge after #N" is verified deterministically: each
# declared dependency's state is read via gh issue view; all-closed records a
# confirmation note, an OPEN (or unresolvable) dependency routes to the Blocked
# path with the 👎 outcome reaction. Pin the pass heading removal-proof, and the
# two operative contracts (the state read and the Blocked-on-open path).
assert_pin_red_on_removal "#254: deleting the Pass 4 dependency-claims heading turns its pin RED" \
  'Declared sequencing-dependency claims' "$IMPL_SKILL"
assert_pin_unique "#254: Pass 4 checks each declared dependency's state via gh issue view" \
  "gh issue view N --json state,title --jq '.state'" "$IMPL_SKILL"
assert_pin_unique "#254: Pass 4 routes an OPEN declared dependency to the Blocked path" \
  'issue-claim audit (dependency): declared dependency #N is still OPEN' "$IMPL_SKILL"
# Review iter 3: the unresolvable-dependency → Blocked arm is the most safety-relevant
# route (fail-closed on a `gh issue view` failure that says nothing about state); pin it
# removal-proof too, not just the heading and the OPEN arm.
assert_pin_unique "#254: Pass 4 fails closed (Blocked) when a declared dependency cannot be resolved" \
  'issue-claim audit (dependency): could not resolve declared dependency #N state' "$IMPL_SKILL"
# Review iter (PR #255): `gh issue view` returns MERGED (not CLOSED) for a merged PR
# dependency — the satisfied case. Pin the operative clause that a landed prerequisite is
# CLOSED **or** MERGED so a later edit cannot silently drop MERGED and mis-Block a merged
# prerequisite (the fail-closed-but-wrong direction the review flagged).
assert_pin_unique "#254: Pass 4 treats a MERGED dependency as satisfied (landed = CLOSED or MERGED)" \
  'when it is `CLOSED` **or** `MERGED`' "$IMPL_SKILL"
# ── issue #185 (+ Addendum): Phase 4.1 Documentation Needed cross-check ─────
# Phase 4.1 enforces named documentation deliverables in two stages:
#   Stage 1 pre-flight: extract the Documentation Needed paths and inject them
#     into the docs subagent dispatch instruction as required deliverables.
#   Stage 2 post-hoc: cross-check each path against the PR diff; self-heal or
#     route to Blocked for absent paths.
# The Addendum (2026-06-29) SUPERSEDES LLM prose-extraction: a deterministic
# helper (scripts/extract-doc-needed-paths.sh) is the single extraction boundary
# BOTH stages consume, and its behavior is verified by the fixture matrix below
# (not by prose pins). The prose pins here lock the load-bearing operative
# sentences of each stage's control flow; they are intentionally NOT a tally,
# so this comment names them structurally rather than by count (a hardcoded
# count drifts the moment an arm is added or removed):
#   Stage 1 — deterministic-extraction mandate + mandatory-deliverable dispatch
#             phrase + present-bullet-but-no-paths audit note.
#   Stage 2 — single-source-of-truth re-run, no-op escape, bare-filename match,
#             self-heal condition, three-dot diff range, Blocked arm, $BASE
#             non-empty fallback, rc-vs-empty-stdout distinction, broken-command
#             fail-closed floor, and remote-anchored self-heal re-check.
assert_pin_unique "#185: Phase 4.1 Stage 1 requires docs subagent to treat named paths as mandatory (D)" \
  'treat each as a mandatory deliverable' "$IMPL_SKILL"
# Addendum: Stage 1 extraction is deterministic (helper), not LLM prose-reading.
assert_pin_unique "#185A: Phase 4.1 Stage 1 mandates deterministic (not LLM) extraction" \
  'do not interpret the prose yourself' "$IMPL_SKILL"
# Addendum: both stages consume the SAME deterministic helper (not re-derived).
assert_eq "#185A: Phase 4.1 calls extract-doc-needed-paths.sh in BOTH stages" \
  "2" "$(pin_count 'extract-doc-needed-paths.sh' "$IMPL_SKILL")"
assert_pin_unique "#185A: Phase 4.1 Stage 2 re-runs the helper as the single source of truth" \
  're-running the helper is the single source of truth' "$IMPL_SKILL"
# #190 suggestion 1: a present-but-empty Documentation Needed bullet must leave an
# auditable breadcrumb rather than silently disabling enforcement.
assert_pin_unique "#190: Phase 4.1 Stage 1 records a note when the bullet has no extractable paths (H)" \
  'the extractor found no file paths' "$IMPL_SKILL"
assert_pin_unique "#185: Phase 4.1 Stage 2 no-op escape hatch when no paths extracted (E)" \
  'this cross-check is a no-op' "$IMPL_SKILL"
assert_pin_unique "#185: Phase 4.1 Stage 2 bare-filename matching rule (F)" \
  'whose basename matches it counts as satisfied' "$IMPL_SKILL"
assert_pin_unique "#185: Phase 4.1 Stage 2 keeps the absent-file self-heal condition (A)" \
  'absent from the diff, perform the missing update' "$IMPL_SKILL"
assert_pin_unique "#185: Phase 4.1 Stage 2 uses the three-dot origin/\$BASE...HEAD diff range (B)" \
  'git diff --name-only "origin/$BASE...HEAD"' "$IMPL_SKILL"
assert_pin_unique "#185: Phase 4.1 Stage 2 Blocked arm names the missing-content condition (C)" \
  'Documentation Needed file content cannot be determined' "$IMPL_SKILL"
# #190 finding 2: $BASE-empty recovery must mirror the Phase 1.4 fallback, not
# just the config-get.sh read (the read alone returns nothing on malformed config).
assert_pin_unique "#190: Phase 4.1 Stage 2 \$BASE recovery mirrors the Phase 1.4 fallback (I)" \
  'applying its non-empty fallback and not just the config read' "$IMPL_SKILL"
# #190 finding 3 (re-stated per review Critical #2): the FAILURE signal is the exit
# status, never stdout emptiness — an rc-0 empty diff is a genuine all-absent result.
assert_pin_unique "#190: Phase 4.1 Stage 2 distinguishes rc-0 empty stdout from a command failure (J)" \
  'an rc-0 result with empty stdout is NOT a failure' "$IMPL_SKILL"
# Review suggestion 1: a re-fetch that itself fails must fail CLOSED (Blocked),
# never fall through to a path-absent verdict on a broken command.
assert_pin_unique "#190: Phase 4.1 Stage 2 fails closed when the diff command stays broken" \
  'never fall through to a path-absent verdict on a broken command' "$IMPL_SKILL"
# #190 finding 1 (re-stated per review Important #3): the self-heal re-check is
# remote-anchored — HEAD must match @{u}, so a no-op/rejected push cannot satisfy
# the gate off a still-local commit.
assert_pin_unique "#190: Phase 4.1 Stage 2 self-heal re-check is remote-anchored (K)" \
  'the local branch is in sync with its upstream' "$IMPL_SKILL"
# PR #190 fix-loop: the EXTRACTION side (gh issue view | helper) must read the
# exit status, not stdout emptiness — a failed gh issue view (auth/network/wrong
# number) emits empty stdout indistinguishable from a genuinely empty bullet and
# would silently disable the whole gate. Both stages capture GH_RC/HELPER_RC and
# fail closed; assert the shared contract appears in BOTH stages (coupled site).
assert_eq "#190 fix-loop: Phase 4.1 captures GH_RC on the extraction read in BOTH stages" \
  "2" "$(pin_count 'GH_RC=$?' "$IMPL_SKILL")"
assert_eq "#190 fix-loop: Phase 4.1 fail-closed extraction contract pinned in BOTH stages" \
  "2" "$(pin_count 'never treat its empty stdout as a no-op' "$IMPL_SKILL")"

# ── issue #230: narrative is a starting point; only Desired Behavior + ACs are ──
# authoritative downstream, and the Documentation Needed bullet is a floor-not-a-
# ceiling. These are load-bearing guidance prose, so pin their operative sentences
# in the OWNING phase file directly (not the merged bundle) — AC7 requires a
# presence pin in EACH edited phase file. Each pinned literal is the operative
# sentence whose removal alone re-introduces the gap, not an adjacent framing
# clause: assert_pin_unique's count==1 contract is the standing removal-proof.
P2_FILE="$IMPL_PHASES_DIR/phase-2-implement.md"
# P4_FILE is defined once next to IMPL_PHASES_DIR above (shared by the #232 and #230 blocks).
assert_pin_unique "#230: phase-2 §2.1 names the narrative as a non-authoritative starting point (AC1)" \
  'non-authoritative starting point to verify' "$P2_FILE"
assert_pin_unique "#230: phase-2 §2.1 scopes 'code wins' so it never overrides the decided spec (AC2)" \
  'never overrides Desired Behavior or Acceptance Criteria' "$P2_FILE"
# AC2's load-bearing discriminator is the SCOPING word `descriptive`, not the consequence
# clause above: a reword that drops "applies to descriptive claims only" while keeping the
# "never overrides …" tail would re-broaden "code wins" over the decided spec (the exact
# #230 bug class) yet stay GREEN. Pin the scoping clause itself so its removal goes RED.
assert_pin_unique "#230: phase-2 §2.1 keeps the 'code wins' scoping qualifier (descriptive-only) (AC2 discriminator)" \
  'applies to **descriptive** claims only' "$P2_FILE"
# AC1's operational meaning of "non-authoritative" is the 'narrow or suppress' clause — the
# direct encoding of the #230 fix (a contradictory narrative must not talk a phase out of
# warranted work). The 'non-authoritative starting point to verify' label pin above guards
# the term; this guards what the term *operationally forbids*, so a reword collapsing it back
# to "ignore it" goes RED.
assert_pin_unique "#230: phase-2 §2.1 keeps the operational 'narrow or suppress' prohibition (AC1 meaning)" \
  'narrow or suppress' "$P2_FILE"
assert_pin_unique "#230: phase-4 §4.1 narrative never suppresses the routine doc pass (AC3)" \
  'suppresses the routine documentation pass' "$P4_FILE"
# AC3's regression-specific discriminator is the absent/empty/contradictory trigger list —
# the three bullet shapes #230 exploited. The general "never suppresses" pin above does not
# guard it: dropping the enumeration would re-open the exact suppression path while staying
# GREEN. Pin the trigger enumeration so its removal goes RED.
assert_pin_unique "#230: phase-4 §4.1 keeps the absent/empty/contradictory trigger enumeration (AC3 discriminator)" \
  'absent, empty, or contradictory' "$P4_FILE"
assert_pin_unique "#230: phase-4 §4.1 Documentation Needed is a floor, never a ceiling (AC4)" \
  'never a ceiling that authorizes skipping otherwise-warranted documentation' "$P4_FILE"
# §2.1 and §4.1 are coupled mirror sites of one authority hierarchy; §4.1 ties back via the
# 'mirrors the §2.1 authority hierarchy' anchor. Pin that anchor so a reword that desyncs the
# two files' framing (the dominant CLAUDE.md coupled-invariant bug class) goes RED rather than
# leaving the mirror sites silently disagreeing.
assert_pin_unique "#230: phase-4 §4.1 keeps the §2.1 cross-reference anchor (mirror-site coupling)" \
  'mirrors the §2.1 authority hierarchy' "$P4_FILE"
# docs/implement-skill.md is the THIRD coupled mirror site (AC6 requires its Phase 4.1
# section carry the floor-not-ceiling framing). Pin its operative clause so a future edit
# that reverts/contradicts the doc while the phase files stay intact goes RED — the same
# coupled-mirror discipline the phase-file pins above apply, extended to the doc (precedent:
# the docs/implement-skill.md mirrors already pinned earlier in this file via $IMPL_DOC).
assert_pin_unique "#230: docs/implement-skill.md mirrors the floor-not-ceiling framing (AC6)" \
  'never read as a ceiling that authorizes' "$IMPL_DOC"

# ── issue #185 Addendum: deterministic extraction helper (fixture matrix) ────
# The helper is the deterministic boundary the Addendum mandates; test its
# BEHAVIOR over the required input-shape matrix (bullet-with-paths, no-paths,
# absent, path-in-another-section-NOT-extracted) rather than relying on the
# shadow review to catch extraction misses. This is the adversarial input-shape
# sweep the CLAUDE.md best-effort-parser convention calls for.
EXTRACT_HELPER="$LIB/../scripts/extract-doc-needed-paths.sh"
assert_eq "#185A helper exists and is executable" "yes" \
  "$([ -x "$EXTRACT_HELPER" ] && echo yes || echo no)"

# Case 1: a bullet naming paths emits exactly those paths — and ONLY those:
# a path in another bullet (Approach/Potential Gotchas) and a non-path skill
# token (devflow:docs) inside the bullet are both excluded.
fx_paths="## Implementation Notes

- **Approach** — edit \`scripts/foo.sh\`.
- **Documentation Needed** — update \`docs/DEVFLOW_SYSTEM_OVERVIEW.md\` and docs/implement-skill.md; also \`README.md\` via the \`devflow:docs\` subagent.
- **Potential Gotchas** — see path/to/ignored.py"
assert_eq "#185A matrix: bullet-with-paths emits exactly the named paths (scoped, no skill token)" \
  "$(printf 'README.md\ndocs/DEVFLOW_SYSTEM_OVERVIEW.md\ndocs/implement-skill.md')" \
  "$(printf '%s\n' "$fx_paths" | bash "$EXTRACT_HELPER")"

# Case 2: a bullet with no file paths is a no-op (empty output).
fx_none="## Implementation Notes

- **Documentation Needed** — No external or customer docs affected."
assert_eq "#185A matrix: bullet-with-no-paths emits nothing" "" \
  "$(printf '%s\n' "$fx_none" | bash "$EXTRACT_HELPER")"

# Case 3: an absent Documentation Needed bullet is a no-op (empty output).
fx_absent="## Technical Context

- references docs/should-not.md"
assert_eq "#185A matrix: absent Documentation Needed bullet emits nothing" "" \
  "$(printf '%s\n' "$fx_absent" | bash "$EXTRACT_HELPER")"

# Case 4: a path mentioned in ANOTHER section must NOT be extracted (scope).
fx_other="## Current Behavior

refs docs/should-not-extract.md

## Implementation Notes

- **Documentation Needed** — update \`docs/yes.md\`."
assert_eq "#185A matrix: a path in another section is NOT extracted" "docs/yes.md" \
  "$(printf '%s\n' "$fx_other" | bash "$EXTRACT_HELPER")"

# Case 5 (regression — caught dogfooding the real issue #185 body): a LATER
# bullet whose prose MENTIONS "**Documentation Needed**" (the issue template's
# own Potential Gotchas bullet does exactly this) must close the scope, not
# re-open it. The open-match is anchored to the bullet label; only docs/real.md
# (named in the actual Documentation Needed bullet) is extracted, and a bare
# extension reference (\`.md\`) in the mentioning bullet is not.
fx_mention="## Implementation Notes

- **Documentation Needed** — update \`docs/real.md\`.
- **Potential Gotchas** — the \`**Documentation Needed**\` bullet lives within \`## Implementation Notes\`; do not extract \`other/leak.md\` named here, and ignore bare \`.md\` / \`.sh\` tokens."
assert_eq "#185A matrix: a later bullet mentioning the label in prose does NOT re-open scope" \
  "docs/real.md" \
  "$(printf '%s\n' "$fx_mention" | bash "$EXTRACT_HELPER")"

# Case 6 (PR #190 fix-loop): a bare, un-backticked filename at a sentence
# boundary must still be extracted. The tokenizer glues the trailing sentence
# period (`CHANGELOG.md.`); the helper trims it so the extension test matches.
# Without the trim the deliverable is silently dropped — under-enforcing in the
# gate's own lenient basename-match domain.
fx_period="## Implementation Notes

- **Documentation Needed** — update CHANGELOG.md."
assert_eq "#190 fix-loop: un-backticked filename with a trailing sentence period IS extracted" \
  "CHANGELOG.md" \
  "$(printf '%s\n' "$fx_period" | bash "$EXTRACT_HELPER")"

# Case 7 (issue #254): the real issue #247 Documentation Needed bullet. The
# tokenizer splits the skill-invocation reference \`/claude-md-management:revise-claude-md\`
# on the colon into \`/claude-md-management\` (rooted, no extension, names no
# in-tree file) — which the OLD contains-a-slash test wrongly emitted. The
# fixture must yield EXACTLY the three real doc files, dropping the skill-ref.
fx_247="## Implementation Notes

- **Approach** — do the thing.
- **Documentation Needed**
  - Document \`DEVFLOW_JQ\` as the Windows \`jq\` escape hatch in
    \`docs/install.md\` / \`README.md\` requirements.
  - Record the shared resolver-family expansion (\`jq\` + \`gh\`) and the path
    normalizer in the \`CLAUDE.md\` tool-resolution gotcha, via
    \`/claude-md-management:revise-claude-md\`.
- **Potential Gotchas** — none."
assert_eq "#254: the #247 body yields exactly CLAUDE.md, README.md, docs/install.md (skill-ref dropped)" \
  "$(printf 'CLAUDE.md\nREADME.md\ndocs/install.md')" \
  "$(printf '%s\n' "$fx_247" | bash "$EXTRACT_HELPER")"

# Case 8 (issue #254): bare-directory tokens (trailing-slash and extensionless
# dir path) and rooted non-file tokens are all dropped; only the real file
# path with a recognized extension survives.
fx_dirs="## Implementation Notes

- **Documentation Needed** — touch \`docs/\`, \`docs/internal\`, \`/pr-description\`, and \`README.md\`."
assert_eq "#254: bare dirs (docs/, docs/internal) and rooted skill-ref (/pr-description) dropped; file kept" \
  "README.md" \
  "$(printf '%s\n' "$fx_dirs" | bash "$EXTRACT_HELPER")"

# Case 9 (issue #254 review): the extensionless-rescue must be BOTH a regular file
# AND in-tree — guarding the two fail-open shapes the review surfaced. `LICENSE`
# (extensionless, tracked) is rescued; `/README.md` is rooted, so it is dropped even
# though `README.md` exists relative (the "drops tokens beginning with `/`" contract —
# a bare `[ -f ]` on the host FS would have accepted an out-of-tree `/etc/hostname`);
# and a bare directory token `docs` must NOT leak (`git ls-files --error-unmatch docs`
# succeeds by matching the tracked files INSIDE `docs/`, so the `[ -f ]` regular-file
# check is what rejects it). Hermetic: LICENSE, README.md, docs all exist in this repo.
fx_intree="## Implementation Notes

- **Documentation Needed** — update \`LICENSE\`, \`/README.md\`, and \`docs\`."
assert_eq "#254: extensionless in-tree file rescued; rooted token and bare dir dropped (fail-open closed)" \
  "LICENSE" \
  "$(printf '%s\n' "$fx_intree" | bash "$EXTRACT_HELPER")"

# Case 10 (issue #254 review): ACCEPTED-tradeoff pin. A deterministic extractor cannot
# tell a to-be-created EXTENSIONLESS file (`docs/newthing`, no extension, not yet on disk)
# apart from a bare-directory token, so the in-tree-regular-file rescue drops it — an
# extension-bearing deliverable (`docs/newthing.md`) is still emitted regardless of whether
# it exists yet. This pins the drop as intended behavior (not a silent regression to chase):
# the overwhelmingly-common doc deliverable carries an extension; only a brand-new
# extensionless path is affected, and it fails CLOSED (dropped, never mis-emitted).
fx_tobecreated="## Implementation Notes

- **Documentation Needed** — create \`docs/newthing\` and \`docs/newthing.md\`."
assert_eq "#254: to-be-created extensionless deliverable dropped (accepted); extension-bearing kept" \
  "docs/newthing.md" \
  "$(printf '%s\n' "$fx_tobecreated" | bash "$EXTRACT_HELPER")"

# Case 11 (review iter 3): a parent-dir-escaping token WITH a recognized extension
# (`../notes.md`, `docs/../secret.md`) must be dropped. The extension branch emits on
# the extension ALONE and never runs the `[ -f ]` + git in-tree check, so without the
# `../*|*/../*` case arm an out-of-tree `../x.md` would be emitted — the same out-of-tree
# fail-open the extensionless rescue (Case 9) was hardened against. An in-tree filename
# that merely CONTAINS dots but no `/../` segment (`foo..md`) is NOT an escape and is kept.
fx_escape="## Implementation Notes

- **Documentation Needed** — update \`../notes.md\`, \`docs/../secret.md\`, \`foo..md\`, and \`CLAUDE.md\`."
assert_eq "#254: parent-dir-escaping extension tokens dropped (out-of-tree fail-open closed); in-tree kept" \
  "CLAUDE.md
foo..md" \
  "$(printf '%s\n' "$fx_escape" | bash "$EXTRACT_HELPER")"

# Case 12 (issue #254 review — test gap): extensionless real-but-UNTRACKED file drop with
# git PRESENT. cwd is inside a fresh git work tree (git_rescue_ok=1); the token names a real
# on-disk regular file (`[ -f ]` passes) but `git ls-files --error-unmatch` fails because it
# is untracked → dropped with NO breadcrumb (a legitimate "not a repo deliverable" decision,
# not a tool-absence degradation — the exact discrimination the two-part rescue exists to make).
fx_untracked_dir="$(mktemp -d)"
( cd "$fx_untracked_dir" && git init -q && : > adhoc_notes )
fx_untracked_body="## Implementation Notes

- **Documentation Needed** — update \`adhoc_notes\` and \`CLAUDE.md\`."
fx_untracked_out="$( cd "$fx_untracked_dir" && printf '%s\n' "$fx_untracked_body" | bash "$EXTRACT_HELPER" 2>"$fx_untracked_dir/err" )"
assert_eq "#254: extensionless untracked real file dropped (git present, [ -f ] passes, ls-files fails)" \
  "CLAUDE.md" "$fx_untracked_out"
assert_eq "#254: untracked-drop emits NO git-unavailable breadcrumb (git present)" \
  "0" "$(grep -c 'git unavailable' "$fx_untracked_dir/err")"
rm -rf "$fx_untracked_dir"

# Case 13 (issue #254 review — test gap): git-unavailable degraded-rescue breadcrumb. cwd is
# OUTSIDE any git work tree (a bare temp dir → git_rescue_ok=0). An extensionless token naming
# a real on-disk file (`[ -f ]` passes) is dropped, but because the drop is due to git being
# unable to run — not because the file is untracked — the helper emits ONE `git unavailable`
# breadcrumb so the drop is observable (guard-class-2 tr-dependence standard, this PR's own
# review-extension contract). The extension-bearing token is still emitted, unaffected.
fx_nogit_dir="$(mktemp -d)"
fx_nogit_ceiling="$(dirname "$fx_nogit_dir")"
: > "$fx_nogit_dir/adhoc_notes"
fx_nogit_body="## Implementation Notes

- **Documentation Needed** — update \`adhoc_notes\` and \`CLAUDE.md\`."
fx_nogit_out="$( printf '%s\n' "$fx_nogit_body" | ( cd "$fx_nogit_dir" && GIT_CEILING_DIRECTORIES="$fx_nogit_ceiling" bash "$EXTRACT_HELPER" 2>"$fx_nogit_dir/err" ) )"
assert_eq "#254: extensionless real file dropped when git unavailable (cwd outside work tree)" \
  "CLAUDE.md" "$fx_nogit_out"
assert_eq "#254: git-unavailable drop emits the degraded-rescue breadcrumb exactly once" \
  "1" "$(grep -c 'git unavailable' "$fx_nogit_dir/err")"
rm -rf "$fx_nogit_dir"

# ────────────────────────────────────────────────────────────────────────────
echo "scaffold-config.sh"
# ────────────────────────────────────────────────────────────────────────────
# Single shared scaffolder used by BOTH install.sh and the /devflow:init skill.
# Templates resolve relative to the script (../.devflow), so we point it at a
# throwaway TARGET root and assert against the repo's real template files.
SC="$LIB/../scripts/scaffold-config.sh"
TPL_DIR="$LIB/../.devflow"

# 1. Fresh target → scaffolds config.json (from the example) + schema.
SC_FRESH="$(mktemp -d)"
bash "$SC" "$SC_FRESH" >/dev/null 2>&1
assert_eq "scaffold: fresh exit 0" "0" "$?"
assert_eq "scaffold: config.json created" "yes" \
  "$([ -f "$SC_FRESH/.devflow/config.json" ] && echo yes || echo no)"
assert_eq "scaffold: config.json == example template" \
  "$(cat "$TPL_DIR/config.example.json")" "$(cat "$SC_FRESH/.devflow/config.json")"
assert_eq "scaffold: schema created" "yes" \
  "$([ -f "$SC_FRESH/.devflow/config.schema.json" ] && echo yes || echo no)"
# Scoped scratch ignore: created, ignores ONLY tmp/ (so config.json + learnings
# stay committable — never the .devflow/ root).
assert_eq "scaffold: .devflow/.gitignore created" "yes" \
  "$([ -f "$SC_FRESH/.devflow/.gitignore" ] && echo yes || echo no)"
assert_eq "scaffold: .gitignore ignores tmp/" "yes" \
  "$(grep -qxF '/tmp/' "$SC_FRESH/.devflow/.gitignore" && echo yes || echo no)"
assert_eq "scaffold: .gitignore does NOT ignore the .devflow root" "no" \
  "$(grep -qE '^/?\*?$|^\.$' "$SC_FRESH/.devflow/.gitignore" && echo yes || echo no)"

# 2. Existing config.json + .gitignore → the user's value is NEVER clobbered
#    (missing keys are backfilled — see block 5); schema still refreshed.
SC_KEEP="$(mktemp -d)"
mkdir -p "$SC_KEEP/.devflow"
printf '{"sentinel":true}' > "$SC_KEEP/.devflow/config.json"
printf 'STALE' > "$SC_KEEP/.devflow/config.schema.json"
printf 'CUSTOM-IGNORE\n' > "$SC_KEEP/.devflow/.gitignore"
bash "$SC" "$SC_KEEP" >/dev/null 2>&1
assert_eq "scaffold: existing custom value preserved through backfill" \
  "true" "$(jq -r '.sentinel' "$SC_KEEP/.devflow/config.json")"
assert_eq "scaffold: schema refreshed over stale" \
  "$(cat "$TPL_DIR/config.schema.json")" "$(cat "$SC_KEEP/.devflow/config.schema.json")"
assert_eq "scaffold: existing .gitignore preserved" \
  'CUSTOM-IGNORE' "$(cat "$SC_KEEP/.devflow/.gitignore")"

# 3. Idempotent: a second run leaves the scaffolded config.json AND the
#    scaffolder's OWN .gitignore byte-identical (guards the `if [ ! -f ]` create
#    guard against a regression that re-writes/appends on every run).
SC_B1="$(cat "$SC_FRESH/.devflow/config.json")"
SC_GI1="$(cat "$SC_FRESH/.devflow/.gitignore")"
bash "$SC" "$SC_FRESH" >/dev/null 2>&1
assert_eq "scaffold: idempotent re-run keeps config" \
  "$SC_B1" "$(cat "$SC_FRESH/.devflow/config.json")"
assert_eq "scaffold: idempotent re-run keeps .gitignore" \
  "$SC_GI1" "$(cat "$SC_FRESH/.devflow/.gitignore")"

# 4. Templates missing next to the script → fail loudly (exit 2), no guessing.
SC_NOTPL="$(mktemp -d)"; mkdir -p "$SC_NOTPL/scripts"
cp "$SC" "$SC_NOTPL/scripts/scaffold-config.sh"
SC_NOTPL_TGT="$(mktemp -d)"
bash "$SC_NOTPL/scripts/scaffold-config.sh" "$SC_NOTPL_TGT" >/dev/null 2>&1
assert_eq "scaffold: missing templates → exit 2" "2" "$?"

# 5. Config-key backfill on an existing config: a recursive deep-merge adds keys
#    newly introduced in the example (at any depth) while preserving the user's
#    values and arrays. No language markers in these throwaway dirs, so the
#    detect step is a no-op and only the backfill is under test.
SC_BF="$(mktemp -d)"; mkdir -p "$SC_BF/.devflow"
# An old config predating devflow_runner.provision_env: a custom top-level value,
# a custom nested value, and a user-tuned array we must not touch.
printf '%s' '{"base_branch":"release","devflow_runner":{"effort":"high"},"devflow":{"allowed_tools":["Bash(make:*)","Bash(npm:*)"]}}' \
  > "$SC_BF/.devflow/config.json"
# Capture stdout so we can also assert the backfill log line the /devflow:init
# skill (skills/init/SKILL.md) keys its "After running" guidance off of.
SC_BF_OUT="$(bash "$SC" "$SC_BF" 2>&1)"
assert_eq "scaffold-backfill: nested missing key added (devflow_runner.provision_env)" \
  "false" "$(jq -r '.devflow_runner.provision_env' "$SC_BF/.devflow/config.json")"
assert_eq "scaffold-backfill: top-level missing key added (claude_model)" \
  "claude-opus-4-8" "$(jq -r '.claude_model' "$SC_BF/.devflow/config.json")"
assert_eq "scaffold-backfill: existing top-level value preserved (base_branch)" \
  "release" "$(jq -r '.base_branch' "$SC_BF/.devflow/config.json")"
assert_eq "scaffold-backfill: existing nested value preserved (devflow_runner.effort)" \
  "high" "$(jq -r '.devflow_runner.effort' "$SC_BF/.devflow/config.json")"
# jq `*` replaces arrays with the right operand (the user's), never merging or
# deduping — so the user's array survives with its exact elements and order
# (read back via `jq -c`, which normalizes whitespace but not contents).
assert_eq "scaffold-backfill: existing array left unchanged (allowed_tools)" \
  '["Bash(make:*)","Bash(npm:*)"]' \
  "$(jq -c '.devflow.allowed_tools' "$SC_BF/.devflow/config.json")"
# The documented log line fires when a backfill actually happens.
assert_eq "scaffold-backfill: backfill emits the documented log line" "yes" \
  "$(printf '%s' "$SC_BF_OUT" | grep -q 'backfilled newly-added keys' && echo yes || echo no)"

# 5b. A config already holding every example key is a no-op: byte-for-byte
#     identical afterwards (the merge changed nothing, so the file isn't rewritten)
#     and the backfill log line is NOT emitted.
SC_NOOP="$(mktemp -d)"; mkdir -p "$SC_NOOP/.devflow"
cp "$TPL_DIR/config.example.json" "$SC_NOOP/.devflow/config.json"
SC_NOOP_BEFORE="$(cat "$SC_NOOP/.devflow/config.json")"
SC_NOOP_OUT="$(bash "$SC" "$SC_NOOP" 2>&1)"
assert_eq "scaffold-backfill: complete config is a byte-identical no-op" \
  "$SC_NOOP_BEFORE" "$(cat "$SC_NOOP/.devflow/config.json")"
assert_eq "scaffold-backfill: no-op does NOT emit the backfill log line" "no" \
  "$(printf '%s' "$SC_NOOP_OUT" | grep -q 'backfilled newly-added keys' && echo yes || echo no)"
# The shipped example pins Sonnet 4.6 (no Haiku override), so a fresh scaffold of
# it must never emit the Haiku effort-cleanup log line — locks the clean path so
# a regression that re-pins Haiku-with-effort in the example is caught.
assert_eq "scaffold-migration: clean shipped example emits no Haiku cleanup log line" "no" \
  "$(printf '%s' "$SC_NOOP_OUT" | grep -q "removed unsupported 'effort' from Haiku-pinned" && echo yes || echo no)"

# 5c. jq unavailable → backfill skipped, scaffold still succeeds and leaves the
#     config untouched. Run under a PATH that resolves the coreutils the scaffold
#     needs but NOT jq, so `command -v jq` fails exactly as on a host without jq.
#     The symlink set below must track every external command scaffold-config.sh
#     (and its detect-project-tools.sh callee) reaches on the jq-absent path; git
#     is intentionally absent because TARGET_ROOT is passed explicitly ($1), and
#     mv/find/grep are not reached once `command -v jq` short-circuits.
SC_NOJQ="$(mktemp -d)"; mkdir -p "$SC_NOJQ/.devflow"
printf '%s' '{"sentinel":true}' > "$SC_NOJQ/.devflow/config.json"
NOJQ_BIN="$(mktemp -d)"
for b in bash dirname mkdir cp rm cat printf find grep diff mktemp; do
  src="$(command -v "$b")" && ln -s "$src" "$NOJQ_BIN/$b"
done
BASH_BIN="$(command -v bash)"
PATH="$NOJQ_BIN" "$BASH_BIN" "$SC" "$SC_NOJQ" >/dev/null 2>&1
assert_eq "scaffold-backfill: jq unavailable → scaffold exits 0 (best-effort)" \
  "0" "$?"
assert_eq "scaffold-backfill: jq unavailable → config left as-is (no backfill)" \
  '{"sentinel":true}' "$(cat "$SC_NOJQ/.devflow/config.json")"

# 5d. Malformed (invalid-JSON) existing config → backfill skipped, scaffold still
#     succeeds, the malformed bytes are left untouched (no clobber/truncation),
#     and the schema is still refreshed (proving the scaffold proceeded past the
#     skip). Guards the `jq -e .` validity branch.
SC_BAD="$(mktemp -d)"; mkdir -p "$SC_BAD/.devflow"
printf '%s' '{ not valid json' > "$SC_BAD/.devflow/config.json"
bash "$SC" "$SC_BAD" >/dev/null 2>&1
assert_eq "scaffold-backfill: malformed config → scaffold exits 0 (best-effort)" \
  "0" "$?"
assert_eq "scaffold-backfill: malformed config left untouched (no clobber)" \
  '{ not valid json' "$(cat "$SC_BAD/.devflow/config.json")"
assert_eq "scaffold-backfill: malformed config → schema still refreshed" \
  "$(cat "$TPL_DIR/config.schema.json")" "$(cat "$SC_BAD/.devflow/config.schema.json")"

rm -rf "$SC_FRESH" "$SC_KEEP" "$SC_NOTPL" "$SC_NOTPL_TGT" "$SC_BF" "$SC_NOOP" "$SC_NOJQ" "$NOJQ_BIN" "$SC_BAD"

# 6. Haiku effort-cleanup migration on an EXISTING config: scaffold-config.sh
#    strips `effort` from any agent_overrides entry whose model is a Haiku id.
#    An earlier release removed that effort key from the example, but the add-only
#    backfill can never propagate a removal to a pre-existing config, so the
#    dedicated cleanup is what repairs an adopter's stale HTTP-400 combo. Mirrors
#    the SC_BF inline-mktemp pattern; no language markers, so detect is a no-op.
SC_MIG="$(mktemp -d)"; mkdir -p "$SC_MIG/.devflow"
# A legacy config: Haiku deduper carrying the HTTP-400 effort key, a SECOND
# Haiku-pinned entry on a different agent (proving the cleanup generalizes to
# any Haiku override, not just the deduper — a regression that hard-coded the
# deduper key would otherwise pass green), plus a non-Haiku override whose
# effort must be left untouched.
printf '%s' '{"devflow_review":{"agent_overrides":{"default":{"effort":"medium"},"devflow:checklist-deduper":{"model":"claude-haiku-4-5-20251001","effort":"low"},"devflow:checklist-generator":{"model":"claude-haiku-4-5-20251001","effort":"high"},"devflow:code-reviewer":{"model":"claude-opus-4-8","effort":"high"}}}}' \
  > "$SC_MIG/.devflow/config.json"
SC_MIG_OUT="$(bash "$SC" "$SC_MIG" 2>&1)"
assert_eq "scaffold-migration: Haiku deduper effort stripped" \
  "false" "$(jq '.devflow_review.agent_overrides["devflow:checklist-deduper"] | has("effort")' "$SC_MIG/.devflow/config.json")"
assert_eq "scaffold-migration: Haiku deduper model preserved" \
  "claude-haiku-4-5-20251001" "$(jq -r '.devflow_review.agent_overrides["devflow:checklist-deduper"].model' "$SC_MIG/.devflow/config.json")"
assert_eq "scaffold-migration: second Haiku-pinned entry (non-deduper) also stripped" \
  "false" "$(jq '.devflow_review.agent_overrides["devflow:checklist-generator"] | has("effort")' "$SC_MIG/.devflow/config.json")"
assert_eq "scaffold-migration: non-Haiku override effort left untouched" \
  "high" "$(jq -r '.devflow_review.agent_overrides["devflow:code-reviewer"].effort' "$SC_MIG/.devflow/config.json")"
# The model-less `default` entry must survive: `(.value.model // "")` yields ""
# which fails the Haiku predicate, so its effort is kept. Asserted on the FIRST
# run directly (not just via the idempotent no-op below, which would pass even
# if both runs stripped it identically), so a regression dropping the model
# guard is caught loudly.
assert_eq "scaffold-migration: model-less default override effort left untouched" \
  "medium" "$(jq -r '.devflow_review.agent_overrides.default.effort' "$SC_MIG/.devflow/config.json")"
assert_eq "scaffold-migration: cleanup emits the documented log line" "yes" \
  "$(printf '%s' "$SC_MIG_OUT" | grep -q "removed unsupported 'effort' from Haiku-pinned" && echo yes || echo no)"
# Second run is a no-churn no-op: config already clean → byte-identical and the
# cleanup log line is NOT re-emitted.
SC_MIG_BEFORE="$(cat "$SC_MIG/.devflow/config.json")"
SC_MIG_OUT2="$(bash "$SC" "$SC_MIG" 2>&1)"
assert_eq "scaffold-migration: second run is a byte-identical no-op" \
  "$SC_MIG_BEFORE" "$(cat "$SC_MIG/.devflow/config.json")"
assert_eq "scaffold-migration: clean config does NOT re-emit the cleanup log line" "no" \
  "$(printf '%s' "$SC_MIG_OUT2" | grep -q "removed unsupported 'effort' from Haiku-pinned" && echo yes || echo no)"
rm -rf "$SC_MIG"

# 6b. jq unavailable during the Haiku effort-cleanup: a config that DOES carry a
#     stale Haiku+effort combo must be LEFT UNTOUCHED (cleanup skipped, not
#     silently "nothing to do"), and the skip breadcrumb must fire. The SC_NOJQ
#     case above uses a non-Haiku config, so it cannot tell "correctly skipped"
#     from "no work"; this fixture closes that gap. Same PATH-without-jq trick.
SC_MIG_NOJQ="$(mktemp -d)"; mkdir -p "$SC_MIG_NOJQ/.devflow"
printf '%s' '{"devflow_review":{"agent_overrides":{"devflow:checklist-deduper":{"model":"claude-haiku-4-5-20251001","effort":"low"}}}}' \
  > "$SC_MIG_NOJQ/.devflow/config.json"
MIG_NOJQ_BIN="$(mktemp -d)"
for b in bash dirname mkdir cp rm cat printf find grep diff mktemp; do
  src="$(command -v "$b")" && ln -s "$src" "$MIG_NOJQ_BIN/$b"
done
MIG_BASH_BIN="$(command -v bash)"
SC_MIG_NOJQ_OUT="$(PATH="$MIG_NOJQ_BIN" "$MIG_BASH_BIN" "$SC" "$SC_MIG_NOJQ" 2>&1)"
# Read back with the test's normal (jq-present) PATH; only the scaffold RAN jq-less.
assert_eq "scaffold-migration: jq unavailable → Haiku+effort combo left untouched (skipped, not a no-op)" \
  "low" "$(jq -r '.devflow_review.agent_overrides["devflow:checklist-deduper"].effort' "$SC_MIG_NOJQ/.devflow/config.json")"
assert_eq "scaffold-migration: jq unavailable → emits the cleanup-skipped breadcrumb" "yes" \
  "$(printf '%s' "$SC_MIG_NOJQ_OUT" | grep -q 'skipping Haiku effort-cleanup' && echo yes || echo no)"
rm -rf "$SC_MIG_NOJQ" "$MIG_NOJQ_BIN"

# 6c. agent_overrides hand-corrupted to a non-object (array): the cleanup filter
#     no-ops via its `else .` arm, but the anti-silent-failure breadcrumb must
#     fire so the silence is not an ambiguous "nothing to do". The backfill leaves
#     the array in place (jq `*` lets the right operand win on a type mismatch).
SC_AO_BAD="$(mktemp -d)"; mkdir -p "$SC_AO_BAD/.devflow"
printf '%s' '{"devflow_review":{"agent_overrides":["oops"]}}' > "$SC_AO_BAD/.devflow/config.json"
SC_AO_BAD_OUT="$(bash "$SC" "$SC_AO_BAD" 2>&1)"
assert_eq "scaffold-migration: non-object agent_overrides emits the skip breadcrumb" "yes" \
  "$(printf '%s' "$SC_AO_BAD_OUT" | grep -q 'agent_overrides is present but not an object' && echo yes || echo no)"
rm -rf "$SC_AO_BAD"

# 6c-bis. devflow_review ITSELF is a non-object (a string). It is valid JSON (so it
#     passes the jq -e . gate), but `.devflow_review.agent_overrides` then ERRORS
#     rather than yielding null. The breadcrumb probe must surface that as its own
#     specific "could not inspect ... (jq error ...)" line — not fold the error into
#     "null" and stay silent (the silent-failure-hunter gap). The scaffold still
#     exits 0 (best-effort) and leaves the malformed value untouched.
SC_DR_BAD="$(mktemp -d)"; mkdir -p "$SC_DR_BAD/.devflow"
printf '%s' '{"devflow_review":"oops"}' > "$SC_DR_BAD/.devflow/config.json"
SC_DR_BAD_OUT="$(bash "$SC" "$SC_DR_BAD" 2>&1)"; SC_DR_BAD_RC=$?
assert_eq "scaffold-migration: non-object devflow_review → scaffold still exits 0 (best-effort)" \
  "0" "$SC_DR_BAD_RC"
assert_eq "scaffold-migration: non-object devflow_review emits the probe-error breadcrumb (not swallowed to 'null')" "yes" \
  "$(printf '%s' "$SC_DR_BAD_OUT" | grep -q 'could not inspect .devflow_review.agent_overrides' && echo yes || echo no)"
# A scalar devflow_review must not DETONATE the backfill or cleanup jq into a
# misdirected generic failure. The backfill still merges the other top-level keys
# (a non-object devflow_review short-circuits the graft-guard's `if` to `else .`),
# and the cleanup no-ops cleanly — so neither the "merge failed" nor the "cleanup
# failed" generic breadcrumb fires; only the accurate probe breadcrumb above does.
assert_eq "scaffold-migration: non-object devflow_review does NOT emit the misdirected backfill 'merge failed'" "no" \
  "$(printf '%s' "$SC_DR_BAD_OUT" | grep -q 'config-key backfill merge failed' && echo yes || echo no)"
assert_eq "scaffold-migration: non-object devflow_review does NOT emit the misdirected 'cleanup failed'" "no" \
  "$(printf '%s' "$SC_DR_BAD_OUT" | grep -q 'Haiku effort-cleanup failed' && echo yes || echo no)"
rm -rf "$SC_DR_BAD"

# 6d. Graft guard: a config that re-pins the deduper to a Haiku id WITHOUT effort
#     must NOT gain an effort key from the example's Sonnet-4.6+effort deduper
#     default via the backfill deep-merge (Haiku rejects effort with HTTP 400; an
#     ungated graft would re-fire on every re-scaffold and churn against the
#     cleanup). Start from a COMPLETE example-derived config so the ONLY thing the
#     backfill could change is the grafted effort — making this a precise probe.
SC_GRAFT="$(mktemp -d)"; mkdir -p "$SC_GRAFT/.devflow"
jq '.devflow_review.agent_overrides["devflow:checklist-deduper"] = {"model":"claude-haiku-4-5-20251001"}' \
  "$TPL_DIR/config.example.json" > "$SC_GRAFT/.devflow/config.json"
SC_GRAFT_BEFORE="$(cat "$SC_GRAFT/.devflow/config.json")"
SC_GRAFT_OUT="$(bash "$SC" "$SC_GRAFT" 2>&1)"
assert_eq "scaffold-graft-guard: backfill does NOT graft effort onto a Haiku deduper" \
  "false" "$(jq '.devflow_review.agent_overrides["devflow:checklist-deduper"] | has("effort")' "$SC_GRAFT/.devflow/config.json")"
assert_eq "scaffold-graft-guard: Haiku deduper model preserved" \
  "claude-haiku-4-5-20251001" "$(jq -r '.devflow_review.agent_overrides["devflow:checklist-deduper"].model' "$SC_GRAFT/.devflow/config.json")"
assert_eq "scaffold-graft-guard: re-scaffold is a byte-identical quiet no-op" \
  "$SC_GRAFT_BEFORE" "$(cat "$SC_GRAFT/.devflow/config.json")"
assert_eq "scaffold-graft-guard: quiet no-op emits neither backfill nor cleanup log" "yes" \
  "$(printf '%s' "$SC_GRAFT_OUT" | grep -qE "backfilled newly-added keys|removed unsupported 'effort'" && echo no || echo yes)"
rm -rf "$SC_GRAFT"

# 6e. Graft-guard PRESERVE branch: a user who pins the deduper to a Haiku id WITH
#     their OWN effort must have that effort PRESERVED by the backfill (the
#     graft-guard strips only a *grafted* effort, never the user's) and removed by
#     the dedicated CLEANUP instead. SC_MIG only asserts the end state (effort
#     gone), which cannot tell "graft-guard preserved + cleanup stripped" from a
#     regression where "graft-guard wrongly stripped + cleanup no-op" — both leave
#     effort absent. Discriminate via the CLEANUP log: it fires only if the effort
#     SURVIVED the backfill into the cleanup. Start from a COMPLETE example-derived
#     config so the backfill is otherwise a byte-identical no-op.
SC_PRESERVE="$(mktemp -d)"; mkdir -p "$SC_PRESERVE/.devflow"
jq '.devflow_review.agent_overrides["devflow:checklist-deduper"] = {"model":"claude-haiku-4-5-20251001","effort":"low"}' \
  "$TPL_DIR/config.example.json" > "$SC_PRESERVE/.devflow/config.json"
SC_PRESERVE_OUT="$(bash "$SC" "$SC_PRESERVE" 2>&1)"
# The discriminator: the cleanup log fires ⇒ the user's effort survived the backfill
# (graft-guard left it alone) and the dedicated cleanup is what stripped it. A
# regression that strips a user's own effort in the backfill would make the backfill
# log fire and the cleanup a silent no-op — failing this assertion.
assert_eq "scaffold-graft-guard: user's OWN Haiku effort survives backfill and is stripped by the cleanup" \
  "yes" "$(printf '%s' "$SC_PRESERVE_OUT" | grep -q "removed unsupported 'effort' from Haiku-pinned" && echo yes || echo no)"
assert_eq "scaffold-graft-guard: preserve-branch sees no backfill rewrite (graft-guard touched nothing)" \
  "no" "$(printf '%s' "$SC_PRESERVE_OUT" | grep -q 'backfilled newly-added keys' && echo yes || echo no)"
assert_eq "scaffold-graft-guard: preserve-branch effort ultimately removed" \
  "false" "$(jq '.devflow_review.agent_overrides["devflow:checklist-deduper"] | has("effort")' "$SC_PRESERVE/.devflow/config.json")"
assert_eq "scaffold-graft-guard: preserve-branch Haiku model kept through both passes" \
  "claude-haiku-4-5-20251001" "$(jq -r '.devflow_review.agent_overrides["devflow:checklist-deduper"].model' "$SC_PRESERVE/.devflow/config.json")"
rm -rf "$SC_PRESERVE"

# 6f. Robustness: a non-string `model` on ONE agent_overrides entry must not
#     detonate the whole backfill/cleanup jq and leave sibling Haiku entries
#     un-repaired. Without the `(.value.model | strings)` guard, `startswith` on a
#     non-string model errors (rc=5), aborting the filter for ALL entries — so a
#     valid Haiku+effort sibling keeps its HTTP-400 combo and the only breadcrumb
#     is a misdirected generic "jq error". The guard makes a non-string model fall
#     through `else .` (unmatched) so siblings are still repaired. Fixture: a
#     complete example-derived config with a valid Haiku+effort entry AND a
#     non-string-model entry.
SC_BADMODEL="$(mktemp -d)"; mkdir -p "$SC_BADMODEL/.devflow"
jq '.devflow_review.agent_overrides["devflow:checklist-generator"] = {"model":"claude-haiku-4-5-20251001","effort":"high"}
    | .devflow_review.agent_overrides["devflow:checklist-verifier"] = {"model":{"oops":true},"effort":"low"}' \
  "$TPL_DIR/config.example.json" > "$SC_BADMODEL/.devflow/config.json"
SC_BADMODEL_OUT="$(bash "$SC" "$SC_BADMODEL" 2>&1)"; SC_BADMODEL_RC=$?
assert_eq "scaffold-robustness: non-string model entry does not abort the scaffold (exit 0)" \
  "0" "$SC_BADMODEL_RC"
assert_eq "scaffold-robustness: valid Haiku sibling still has its effort stripped despite a non-string-model entry" \
  "false" "$(jq '.devflow_review.agent_overrides["devflow:checklist-generator"] | has("effort")' "$SC_BADMODEL/.devflow/config.json")"
assert_eq "scaffold-robustness: the non-string-model entry is left untouched (unmatched, did not detonate the filter)" \
  "low" "$(jq -r '.devflow_review.agent_overrides["devflow:checklist-verifier"].effort' "$SC_BADMODEL/.devflow/config.json")"
rm -rf "$SC_BADMODEL"

# 6g. Unit-test the rewrite_config_if_changed helper in ISOLATION, sourced via the
#     library-only hook (DEVFLOW_SCAFFOLD_LIB_ONLY) so the helpers load without the
#     scaffold body running. This locks the two robustness arms the main flow's
#     validity gate keeps unreachable once it has passed: a normalization (jq)
#     failure must NOT phantom-rewrite, and a write (mv) failure must
#     log-and-continue. Run in a subshell so the helper's `set -euo pipefail` and
#     its log()/die() definitions never leak into the rest of the suite.
( export DEVFLOW_SCAFFOLD_LIB_ONLY=1
  # shellcheck disable=SC1090
  . "$SC"
  set +e +o pipefail
  # (a) cmpfail arm — the bug the helper exists to prevent: a left-hand (cfg)
  #     normalization failure must log the comparison-untrusted message and leave
  #     cfg untouched, NOT mv the candidate over it (the process-substitution
  #     phantom-rewrite trap).
  HU="$(mktemp -d)"
  printf '%s' 'not json' > "$HU/cfg.json"      # cfg fails jq --sort-keys
  printf '%s' '{"a":2}'  > "$HU/cand.json"      # cand is valid and differs
  HU_BEFORE="$(cat "$HU/cfg.json")"
  HU_OUT="$(rewrite_config_if_changed "$HU/cfg.json" "$HU/cand.json" "HELPERTEST-CHANGED" "HELPERTEST-CMPFAIL" 2>&1)"
  HU_RC=$?
  assert_eq "rewrite-helper: cmpfail arm returns 0 (does not abort the scaffold)" "0" "$HU_RC"
  assert_eq "rewrite-helper: cmpfail arm emits the comparison-untrusted message" "yes" \
    "$(printf '%s' "$HU_OUT" | grep -q 'HELPERTEST-CMPFAIL' && echo yes || echo no)"
  assert_eq "rewrite-helper: cmpfail arm does NOT phantom-rewrite (cfg bytes survive)" \
    "$HU_BEFORE" "$(cat "$HU/cfg.json")"
  assert_eq "rewrite-helper: cmpfail arm does NOT emit the changed message" "no" \
    "$(printf '%s' "$HU_OUT" | grep -q 'HELPERTEST-CHANGED' && echo yes || echo no)"
  rm -rf "$HU"

  # (b) happy path: two differing valid configs ARE rewritten, changed message fires.
  HU_OK="$(mktemp -d)"
  printf '%s' '{"a":1}' > "$HU_OK/cfg.json"
  printf '%s' '{"a":2}' > "$HU_OK/cand.json"
  HU_OK_OUT="$(rewrite_config_if_changed "$HU_OK/cfg.json" "$HU_OK/cand.json" "HELPERTEST-CHANGED" "HELPERTEST-CMPFAIL" 2>&1)"
  assert_eq "rewrite-helper: happy path rewrites the config (cand wins)" "2" \
    "$(jq -r '.a' "$HU_OK/cfg.json")"
  assert_eq "rewrite-helper: happy path emits the changed message" "yes" \
    "$(printf '%s' "$HU_OK_OUT" | grep -q 'HELPERTEST-CHANGED' && echo yes || echo no)"
  rm -rf "$HU_OK"

  # (c) mv-failure arm: a write failure must log-and-continue (return 0), leaving
  #     the original bytes — not abort under set -euo pipefail. Provoked by making
  #     cfg's directory unwritable, which only bites a non-root user; root bypasses
  #     permission bits, so skip there (CI runs non-root and exercises this).
  if [ "$(id -u)" -ne 0 ]; then
    HU_RO="$(mktemp -d)"
    printf '%s' '{"a":1}' > "$HU_RO/cfg.json"
    HU_CAND="$(mktemp)"
    printf '%s' '{"a":2}' > "$HU_CAND"
    HU_RO_BEFORE="$(cat "$HU_RO/cfg.json")"
    chmod a-w "$HU_RO"
    HU_RO_OUT="$(rewrite_config_if_changed "$HU_RO/cfg.json" "$HU_CAND" "HELPERTEST-CHANGED" "HELPERTEST-CMPFAIL" 2>&1)"
    HU_RO_RC=$?
    chmod u+w "$HU_RO"
    assert_eq "rewrite-helper: mv-failure arm returns 0 (logs-and-continues)" "0" "$HU_RO_RC"
    assert_eq "rewrite-helper: mv-failure arm emits the could-not-write message" "yes" \
      "$(printf '%s' "$HU_RO_OUT" | grep -q 'could not write' && echo yes || echo no)"
    assert_eq "rewrite-helper: mv-failure arm leaves the original bytes intact" \
      "$HU_RO_BEFORE" "$(cat "$HU_RO/cfg.json")"
    rm -rf "$HU_RO" "$HU_CAND"
  fi
)

# 6h. Positive jq-EXECUTION-failure path for the backfill arm: a CORRUPT
#     config.example.json next to a COPY of the scaffolder makes the backfill's
#     `jq -n --slurpfile ex ...` fail to PARSE the template (not merely be absent),
#     so the "merge failed (jq error)" arm fires for real — it previously had only
#     negative assertions. The existing valid config.json is left untouched and the
#     scaffold still exits 0 (best-effort). Mirrors the SC_NOTPL copy-the-script
#     layout so the template resolves next to the copy.
SC_JQERR="$(mktemp -d)"; mkdir -p "$SC_JQERR/scripts" "$SC_JQERR/.devflow"
cp "$SC" "$SC_JQERR/scripts/scaffold-config.sh"
printf '%s' '{ corrupt example'   > "$SC_JQERR/.devflow/config.example.json"
cp "$TPL_DIR/config.schema.json"    "$SC_JQERR/.devflow/config.schema.json"
SC_JQERR_TGT="$(mktemp -d)"; mkdir -p "$SC_JQERR_TGT/.devflow"
printf '%s' '{"sentinel":true}'    > "$SC_JQERR_TGT/.devflow/config.json"
SC_JQERR_OUT="$(bash "$SC_JQERR/scripts/scaffold-config.sh" "$SC_JQERR_TGT" 2>&1)"; SC_JQERR_RC=$?
assert_eq "scaffold-jqerr: corrupt example template → scaffold still exits 0 (best-effort)" \
  "0" "$SC_JQERR_RC"
assert_eq "scaffold-jqerr: corrupt example template → the backfill 'merge failed (jq error)' arm fires" "yes" \
  "$(printf '%s' "$SC_JQERR_OUT" | grep -q 'config-key backfill merge failed (jq error)' && echo yes || echo no)"
assert_eq "scaffold-jqerr: corrupt example template → existing config left untouched (no clobber)" \
  '{"sentinel":true}' "$(cat "$SC_JQERR_TGT/.devflow/config.json")"
rm -rf "$SC_JQERR" "$SC_JQERR_TGT"

# ────────────────────────────────────────────────────────────────────────────
echo "scaffold-config.sh: scaffolds an inert prompt-extension example for EVERY skill"
# ────────────────────────────────────────────────────────────────────────────
# Scaffolding must create .devflow/prompt-extensions/<skill>.md.example for every
# skill under skills/ (issue #95), not just create-issue. Each example is INERT:
# the `.example` suffix keeps it from matching the live `<skill>.md` that
# load-prompt-extension.sh treats as an extension, and its whole body is an HTML
# comment so even a misrename that drops `.example` injects no actionable text. The
# expected skill set is DERIVED from skills/*/ (the same source of truth the
# SKILL.md coverage guard uses), so this doubles as a drift guard: a new skill the
# scaffolder's authored list forgets fails the per-skill assertions below.
SC="$LIB/../scripts/scaffold-config.sh"
LPE="$LIB/../scripts/load-prompt-extension.sh"
SC_PE="$(mktemp -d)"
SC_PE_OUT="$(bash "$SC" "$SC_PE" 2>&1)"
SC_PE_DIR="$SC_PE/.devflow/prompt-extensions"

assert_eq "scaffold-pe: .devflow/prompt-extensions/ created" "yes" \
  "$([ -d "$SC_PE_DIR" ] && echo yes || echo no)"

SC_PE_MISSING=""; SC_PE_NOTCOMMENT=""; SC_PE_NOHINT=""; SC_PE_EMPTYHINT=""; SC_PE_LIVE=""; SC_PE_NOTINERT=""
for SKILL_DIR in "$LIB"/../skills/*/; do
  skill="$(basename "$SKILL_DIR")"
  f="$SC_PE_DIR/$skill.md.example"
  if [ -f "$f" ]; then
    # AC 3: body is a SINGLE comment block — first non-blank line opens `<!--`,
    # last non-blank line closes `-->`. Read the file once, then slice.
    nonblank="$(grep -v '^[[:space:]]*$' "$f")"
    first="$(printf '%s\n' "$nonblank" | head -n1)"
    last="$(printf '%s\n' "$nonblank" | tail -n1)"
    case "$first" in '<!--'*) : ;; *) SC_PE_NOTCOMMENT="$SC_PE_NOTCOMMENT $skill" ;; esac
    case "$last"  in *'-->')  : ;; *) SC_PE_NOTCOMMENT="$SC_PE_NOTCOMMENT $skill" ;; esac
    # AC 4: a per-skill hint line naming the skill, distinct from the boilerplate.
    grep -qF "Useful extension for $skill:" "$f" || SC_PE_NOHINT="$SC_PE_NOHINT $skill"
    # AC 4 (strengthened): the hint must be NON-EMPTY — `Useful extension for <skill>: `
    # with nothing after the colon-space would pass the bare presence check above but
    # ship a hint-less example. Require at least one char after the literal prefix.
    grep -qE "Useful extension for $skill: .+" "$f" || SC_PE_EMPTYHINT="$SC_PE_EMPTYHINT $skill"
  else
    SC_PE_MISSING="$SC_PE_MISSING $skill"   # AC 1
  fi
  # AC 2: the .example suffix means no live `<skill>.md` is ever scaffolded.
  [ -e "$SC_PE_DIR/$skill.md" ] && SC_PE_LIVE="$SC_PE_LIVE $skill"
  # AC 5: the REAL reader treats the scaffolded example as an inert no-op
  # (empty stdout + exit 0) — exercised, not mocked.
  RDR_OUT="$(cd "$SC_PE" && bash "$LPE" "$skill" 2>/dev/null)"; RDR_RC=$?
  { [ -z "$RDR_OUT" ] && [ "$RDR_RC" -eq 0 ]; } || SC_PE_NOTINERT="$SC_PE_NOTINERT $skill"
done
assert_eq "scaffold-pe: an example exists for every skill (AC 1)" "" "$SC_PE_MISSING"
assert_eq "scaffold-pe: every example body is a single HTML comment block (AC 3)" "" "$SC_PE_NOTCOMMENT"
assert_eq "scaffold-pe: every example carries a per-skill hint line (AC 4)" "" "$SC_PE_NOHINT"
assert_eq "scaffold-pe: every per-skill hint is non-empty (AC 4)" "" "$SC_PE_EMPTYHINT"
assert_eq "scaffold-pe: no live <skill>.md scaffolded — only .example (AC 2)" "" "$SC_PE_LIVE"
assert_eq "scaffold-pe: real load-prompt-extension reader is inert no-op for every skill (AC 5)" "" "$SC_PE_NOTINERT"
# Drift guard (bidirectional): the set of scaffolded `<skill>.md.example` basenames must
# EQUAL the set of skills under skills/*/ — catching BOTH a forgotten skill (forward
# drift: a skills/ dir with no example) AND a stale heredoc row (reverse drift: an
# orphan example for a renamed/removed skill that the per-skill loop above never visits).
SC_PE_EXPECTED="$(for d in "$LIB"/../skills/*/; do basename "$d"; done | sort | tr '\n' ' ')"
SC_PE_GOT="$(for ex in "$SC_PE_DIR"/*.md.example; do b="$(basename "$ex")"; printf '%s\n' "${b%.md.example}"; done | sort | tr '\n' ' ')"
assert_eq "scaffold-pe: scaffolded example set EQUALS skills/*/ (no missing, no orphan)" \
  "$SC_PE_EXPECTED" "$SC_PE_GOT"
# Atomic-write contract: the scaffolder writes each example to `<skill>.md.example.tmp`
# and `mv`s it into place, so a successful scaffold leaves NO `.tmp` behind (the mv
# consumed it). Pin it — every other glob here filters to `*.md.example`, so a
# regression (e.g. cp instead of mv, or a dropped rm -f) that stranded a temp would
# otherwise be invisible. Glob + [ -e ] (nullglob-off leaves the literal pattern, which
# [ -e ] rejects) rather than spawning ls.
assert_eq "scaffold-pe: no .tmp temp survives a successful scaffold (atomic mv consumed it)" "no" \
  "$(set -- "$SC_PE_DIR"/*.md.example.tmp; [ -e "$1" ] && echo yes || echo no)"
# AC 9 (created half): a creation log line is emitted on a fresh scaffold. Match the
# literal "prompt-extension example" — NOT just the dir path "prompt-extensions/",
# which any mention would satisfy — so the assertion pins the new reporting line.
assert_eq "scaffold-pe: emits a creation log line on a fresh scaffold (AC 9)" "yes" \
  "$(printf '%s\n' "$SC_PE_OUT" | grep -qF 'prompt-extension example' && echo yes || echo no)"

# AC 7 + AC 9 (no-op half): a second run rewrites nothing (every example
# byte-identical) and emits NO creation log line.
SC_PE_SUM1="$(find "$SC_PE_DIR" -type f -name '*.example' | sort | xargs cksum)"
SC_PE_OUT2="$(bash "$SC" "$SC_PE" 2>&1)"
SC_PE_SUM2="$(find "$SC_PE_DIR" -type f -name '*.example' | sort | xargs cksum)"
assert_eq "scaffold-pe: idempotent re-run keeps every example byte-identical (AC 7)" \
  "$SC_PE_SUM1" "$SC_PE_SUM2"
assert_eq "scaffold-pe: no creation log line on an all-present no-op re-run (AC 9)" "no" \
  "$(printf '%s\n' "$SC_PE_OUT2" | grep -qF 'prompt-extension example' && echo yes || echo no)"
rm -rf "$SC_PE"

# AC 6 (partial backfill): a dir that already holds ONLY create-issue.md.example
# (an adopter who ran /devflow:init before issue #95) gets the other skills backfilled,
# and the pre-existing create-issue.md.example is left byte-identical (never clobbered).
# (AC 8 — adopter live-file safety — is asserted in the separate block further below.)
SC_PE_BF="$(mktemp -d)"
mkdir -p "$SC_PE_BF/.devflow/prompt-extensions"
printf 'SENTINEL-PREEXISTING-EXAMPLE\n' > "$SC_PE_BF/.devflow/prompt-extensions/create-issue.md.example"
SC_PE_BF_SENT="$(cat "$SC_PE_BF/.devflow/prompt-extensions/create-issue.md.example")"
bash "$SC" "$SC_PE_BF" >/dev/null 2>&1
SC_PE_BF_MISSING=""
for SKILL_DIR in "$LIB"/../skills/*/; do
  skill="$(basename "$SKILL_DIR")"
  [ "$skill" = "create-issue" ] && continue
  [ -f "$SC_PE_BF/.devflow/prompt-extensions/$skill.md.example" ] || SC_PE_BF_MISSING="$SC_PE_BF_MISSING $skill"
done
assert_eq "scaffold-pe: partial backfill creates the other examples (AC 6)" "" "$SC_PE_BF_MISSING"
assert_eq "scaffold-pe: partial backfill leaves the pre-existing example byte-identical (AC 6)" \
  "$SC_PE_BF_SENT" "$(cat "$SC_PE_BF/.devflow/prompt-extensions/create-issue.md.example")"
rm -rf "$SC_PE_BF"

# AC 8 (adopter live-file safety): a real review.md the adopter authored (no .example
# suffix → a LIVE extension) is never overwritten/deleted, and — because a live
# extension already exists for that skill — the scaffolder does NOT drop a redundant
# review.md.example beside it (issue #118). The guard is per-skill, so the OTHER skills
# still get their .example backfilled.
SC_PE_LV="$(mktemp -d)"
mkdir -p "$SC_PE_LV/.devflow/prompt-extensions"
printf 'ADOPTER LIVE REVIEW RULES\n' > "$SC_PE_LV/.devflow/prompt-extensions/review.md"
SC_PE_LV_SENT="$(cat "$SC_PE_LV/.devflow/prompt-extensions/review.md")"
bash "$SC" "$SC_PE_LV" >/dev/null 2>&1
assert_eq "scaffold-pe: adopter's live review.md is untouched (AC 8)" \
  "$SC_PE_LV_SENT" "$(cat "$SC_PE_LV/.devflow/prompt-extensions/review.md")"
assert_eq "scaffold-pe: NO review.md.example created when a live review.md exists (AC 8)" "no" \
  "$([ -e "$SC_PE_LV/.devflow/prompt-extensions/review.md.example" ] && echo yes || echo no)"
# The live-extension guard is scoped to that one skill — other skills still get examples.
assert_eq "scaffold-pe: other skills still get .example beside a live review.md (AC 8)" "yes" \
  "$([ -f "$SC_PE_LV/.devflow/prompt-extensions/docs.md.example" ] && echo yes || echo no)"
rm -rf "$SC_PE_LV"

# AC 8 (compose): both a live review.md AND a pre-existing review.md.example present →
# neither is modified or deleted. The live-.md guard and the pre-existing-.example guard
# compose; the scaffolder stays non-destructive on both.
SC_PE_BOTH="$(mktemp -d)"
mkdir -p "$SC_PE_BOTH/.devflow/prompt-extensions"
printf 'ADOPTER LIVE REVIEW RULES\n' > "$SC_PE_BOTH/.devflow/prompt-extensions/review.md"
printf 'SENTINEL-PREEXISTING-REVIEW-EXAMPLE\n' > "$SC_PE_BOTH/.devflow/prompt-extensions/review.md.example"
SC_PE_BOTH_MD="$(cat "$SC_PE_BOTH/.devflow/prompt-extensions/review.md")"
SC_PE_BOTH_EX="$(cat "$SC_PE_BOTH/.devflow/prompt-extensions/review.md.example")"
bash "$SC" "$SC_PE_BOTH" >/dev/null 2>&1
assert_eq "scaffold-pe: live review.md untouched when its .example also exists (AC 8 compose)" \
  "$SC_PE_BOTH_MD" "$(cat "$SC_PE_BOTH/.devflow/prompt-extensions/review.md")"
assert_eq "scaffold-pe: pre-existing review.md.example untouched beside a live review.md (AC 8 compose)" \
  "$SC_PE_BOTH_EX" "$(cat "$SC_PE_BOTH/.devflow/prompt-extensions/review.md.example")"
rm -rf "$SC_PE_BOTH"

# Write-failure path (best-effort / silent-failure contract): a per-file write that
# fails must NOT abort the scaffold — it logs a breadcrumb naming the file and
# continues (matching rewrite_config_if_changed and the jq blocks). Make the
# prompt-extensions dir read-only so every write fails; assert the scaffolder still
# exits 0, emits a "could not write" breadcrumb, and leaves no .example at the guarded
# path. The scaffolder writes to a temp and mv's it into place atomically, so a failed
# write can NEVER leave a partial/zero-byte <skill>.md.example that the [ -e ] guard
# would then treat as present and never retry — the no-leftover assertion below holds by
# construction (atomicity), not by hoping a failed redirect wrote nothing. Root bypasses
# the perm bits, so skip under root (as the lpe unreadable test does).
SC_PE_WF="$(mktemp -d)"
mkdir -p "$SC_PE_WF/.devflow/prompt-extensions"
chmod 555 "$SC_PE_WF/.devflow/prompt-extensions"
if [ "$(id -u)" -ne 0 ] && [ ! -w "$SC_PE_WF/.devflow/prompt-extensions" ]; then
  SC_PE_WF_OUT="$(bash "$SC" "$SC_PE_WF" 2>&1)"; SC_PE_WF_RC=$?
  assert_eq "scaffold-pe: a write failure does not abort the scaffold (exit 0)" "0" "$SC_PE_WF_RC"
  assert_eq "scaffold-pe: a write failure emits a 'could not write' breadcrumb" "yes" \
    "$(printf '%s\n' "$SC_PE_WF_OUT" | grep -qF 'could not write' && echo yes || echo no)"
  assert_eq "scaffold-pe: a write failure leaves no zero-byte .example leftover" "no" \
    "$(set -- "$SC_PE_WF/.devflow/prompt-extensions/"*.md.example; [ -e "$1" ] && echo yes || echo no)"
  assert_eq "scaffold-pe: a write failure leaves no .tmp temp behind" "no" \
    "$(set -- "$SC_PE_WF/.devflow/prompt-extensions/"*.md.example.tmp; [ -e "$1" ] && echo yes || echo no)"
fi
chmod 755 "$SC_PE_WF/.devflow/prompt-extensions"
rm -rf "$SC_PE_WF"

# ────────────────────────────────────────────────────────────────────────────
echo "load-prompt-extension.sh (consumer prompt-extension reader)"
# ────────────────────────────────────────────────────────────────────────────
# The helper prints .devflow/prompt-extensions/<skill>.md verbatim (relative to
# CWD) when present, nothing otherwise; it validates the skill-name argument and
# refuses any value containing '/' or '..' before touching the filesystem.
# (issue #84, AC 1–5, AC 8.)
LPE="$LIB/../scripts/load-prompt-extension.sh"
LPE_DIR="$(mktemp -d)"
mkdir -p "$LPE_DIR/.devflow/prompt-extensions"

# AC 1: present → stdout equals the file, exit 0.
printf 'line one\nline two\n' > "$LPE_DIR/.devflow/prompt-extensions/implement.md"
LPE_OUT="$(cd "$LPE_DIR" && bash "$LPE" implement 2>/dev/null)"; LPE_RC=$?
assert_eq "lpe: present → verbatim stdout (newlines trimmed by \$())" \
  "$(printf 'line one\nline two')" "$LPE_OUT"
assert_eq "lpe: present → exit 0" "0" "$LPE_RC"

# AC 4: byte-for-byte verbatim incl. multi-byte UTF-8, NO trailing newline added
# when the file has none. cmp the helper's raw bytes against the source file.
printf 'café 日本語 🎉 no-trailing-newline' > "$LPE_DIR/.devflow/prompt-extensions/review.md"
( cd "$LPE_DIR" && bash "$LPE" review 2>/dev/null ) > "$LPE_DIR/out-utf8.bin"
assert_eq "lpe: UTF-8 verbatim, no trailing newline added (cmp byte-exact)" "yes" \
  "$(cmp -s "$LPE_DIR/.devflow/prompt-extensions/review.md" "$LPE_DIR/out-utf8.bin" && echo yes || echo no)"
# AC 4 (other direction): a file WITH a trailing newline round-trips unchanged.
printf 'has trailing newline\n' > "$LPE_DIR/.devflow/prompt-extensions/docs.md"
( cd "$LPE_DIR" && bash "$LPE" docs 2>/dev/null ) > "$LPE_DIR/out-nl.bin"
assert_eq "lpe: trailing-newline file round-trips byte-for-byte" "yes" \
  "$(cmp -s "$LPE_DIR/.devflow/prompt-extensions/docs.md" "$LPE_DIR/out-nl.bin" && echo yes || echo no)"

# AC 2: absent file → empty stdout, exit 0 (no-op path).
LPE_ABS_OUT="$(cd "$LPE_DIR" && bash "$LPE" pr-description 2>/dev/null)"; LPE_ABS_RC=$?
assert_eq "lpe: absent → empty stdout" "" "$LPE_ABS_OUT"
assert_eq "lpe: absent → exit 0" "0" "$LPE_ABS_RC"

# AC 3: empty file → empty stdout, exit 0.
: > "$LPE_DIR/.devflow/prompt-extensions/create-issue.md"
LPE_EMP_OUT="$(cd "$LPE_DIR" && bash "$LPE" create-issue 2>/dev/null)"; LPE_EMP_RC=$?
assert_eq "lpe: empty file → empty stdout" "" "$LPE_EMP_OUT"
assert_eq "lpe: empty file → exit 0" "0" "$LPE_EMP_RC"

# AC 5: path-traversal — reject '/' and '..' BEFORE any read, exit non-zero,
# print nothing. Sentinels the helper would leak if validation were absent:
#   name '../config'  → .devflow/prompt-extensions/../config.md = .devflow/config.md
printf 'SECRET-OUTSIDE' > "$LPE_DIR/.devflow/config.md"
for bad in "a/b" ".." "../config" "../../etc/passwd" "foo/../bar"; do
  BAD_OUT="$(cd "$LPE_DIR" && bash "$LPE" "$bad" 2>/dev/null)"; BAD_RC=$?
  assert_eq "lpe: reject '$bad' → exit non-zero" "yes" \
    "$([ "$BAD_RC" -ne 0 ] && echo yes || echo no)"
  assert_eq "lpe: reject '$bad' → reads nothing outside (empty stdout)" "" "$BAD_OUT"
done
# Empty skill name → bad arguments, exit non-zero.
EMPTY_NAME_OUT="$(cd "$LPE_DIR" && bash "$LPE" "" 2>/dev/null)"; EMPTY_NAME_RC=$?
assert_eq "lpe: empty skill name → exit non-zero" "yes" \
  "$([ "$EMPTY_NAME_RC" -ne 0 ] && echo yes || echo no)"
assert_eq "lpe: empty skill name → empty stdout" "" "$EMPTY_NAME_OUT"

# Present-but-unreadable file → refused LOUDLY (exit 2 + breadcrumb), never the
# silent empty no-op the calling skill reads as "proceed unchanged" (which would
# drop the consumer's extension). Root bypasses the permission bits, so this only
# asserts for an ordinary user — skip under root rather than reporting a false FAIL.
printf 'unreadable content' > "$LPE_DIR/.devflow/prompt-extensions/locked.md"
chmod 000 "$LPE_DIR/.devflow/prompt-extensions/locked.md"
if [ "$(id -u)" -ne 0 ] && [ ! -r "$LPE_DIR/.devflow/prompt-extensions/locked.md" ]; then
  LOCK_OUT="$(cd "$LPE_DIR" && bash "$LPE" locked 2>/tmp/devflow-lpe-lock.err)"; LOCK_RC=$?
  assert_eq "lpe: unreadable present file → exit non-zero (not a silent no-op)" "yes" \
    "$([ "$LOCK_RC" -ne 0 ] && echo yes || echo no)"
  assert_eq "lpe: unreadable present file → no content leaked to stdout" "" "$LOCK_OUT"
  assert_eq "lpe: unreadable present file → breadcrumb says 'not readable'" "yes" \
    "$(grep -qF 'not readable' /tmp/devflow-lpe-lock.err && echo yes || echo no)"
fi
chmod 644 "$LPE_DIR/.devflow/prompt-extensions/locked.md"   # restore so rm -rf can clean up

# Broken symlink (present link, missing target) → refused LOUDLY (exit 2 +
# breadcrumb), not the silent no-op a bare `-f` test would yield — same silent-drop
# class as the unreadable guard, for an unresolvable link.
ln -s "./this-target-does-not-exist.md" "$LPE_DIR/.devflow/prompt-extensions/broken.md"
BROKEN_OUT="$(cd "$LPE_DIR" && bash "$LPE" broken 2>/tmp/devflow-lpe-broken.err)"; BROKEN_RC=$?
assert_eq "lpe: broken symlink (missing target) → exit non-zero (not silent no-op)" "yes" \
  "$([ "$BROKEN_RC" -ne 0 ] && echo yes || echo no)"
assert_eq "lpe: broken symlink → empty stdout" "" "$BROKEN_OUT"
assert_eq "lpe: broken symlink → breadcrumb names the missing target" "yes" \
  "$(grep -qF 'missing target' /tmp/devflow-lpe-broken.err && echo yes || echo no)"
rm -f "$LPE_DIR/.devflow/prompt-extensions/broken.md"

# Present-but-not-a-regular-file → refused LOUDLY, not a silent no-op: a directory
# at <skill>.md (a fat-fingered `mkdir`) and a symlink resolving to a directory both
# have -f false and would otherwise drop the extension silently (same class).
mkdir "$LPE_DIR/.devflow/prompt-extensions/adir.md"
ADIR_OUT="$(cd "$LPE_DIR" && bash "$LPE" adir 2>/tmp/devflow-lpe-adir.err)"; ADIR_RC=$?
assert_eq "lpe: directory at <skill>.md → exit non-zero (not silent no-op)" "yes" \
  "$([ "$ADIR_RC" -ne 0 ] && echo yes || echo no)"
assert_eq "lpe: directory at <skill>.md → breadcrumb 'not a regular file'" "yes" \
  "$(grep -qF 'not a regular file' /tmp/devflow-lpe-adir.err && echo yes || echo no)"
mkdir "$LPE_DIR/realdir"
ln -s "../../realdir" "$LPE_DIR/.devflow/prompt-extensions/dirlink.md"
DIRLINK_OUT="$(cd "$LPE_DIR" && bash "$LPE" dirlink 2>/tmp/devflow-lpe-dirlink.err)"; DIRLINK_RC=$?
assert_eq "lpe: symlink resolving to a directory → exit non-zero (not silent no-op)" "yes" \
  "$([ "$DIRLINK_RC" -ne 0 ] && echo yes || echo no)"
assert_eq "lpe: symlink-to-directory → empty stdout" "" "$DIRLINK_OUT"
# Pin WHICH guard fired (the non-regular guard, not the broken-symlink one) so a
# future refactor can't silently reroute this shape through the wrong branch.
assert_eq "lpe: symlink-to-directory → breadcrumb 'not a regular file'" "yes" \
  "$(grep -qF 'not a regular file' /tmp/devflow-lpe-dirlink.err && echo yes || echo no)"
rm -rf "$LPE_DIR/.devflow/prompt-extensions/adir.md" "$LPE_DIR/.devflow/prompt-extensions/dirlink.md" "$LPE_DIR/realdir"

# Intended symlink behavior (pins a DECISION, not an accident): the name guard
# constrains the model-supplied NAME, not the resolved target. A symlink the repo
# owner commits inside the consumer-owned extensions dir IS followed by `cat` — the
# directory's contents are trusted by design. This documents that AC 5's "reads no
# file outside" is a name-confinement guarantee, not symlink-target confinement.
printf 'TARGET-OF-SYMLINK' > "$LPE_DIR/symlink-target.txt"
ln -s "../../symlink-target.txt" "$LPE_DIR/.devflow/prompt-extensions/linked.md"
LINK_OUT="$(cd "$LPE_DIR" && bash "$LPE" linked 2>/dev/null)"; LINK_RC=$?
assert_eq "lpe: symlinked extension inside the dir is followed (consumer-owned, by design)" \
  "TARGET-OF-SYMLINK" "$LINK_OUT"
assert_eq "lpe: symlinked extension → exit 0" "0" "$LINK_RC"

# AC 8: read-only + idempotent — identical output on re-run, source file unchanged.
printf 'idem\n' > "$LPE_DIR/.devflow/prompt-extensions/init.md"
LPE_IDEM1="$(cd "$LPE_DIR" && bash "$LPE" init 2>/dev/null)"
LPE_CKSUM_BEFORE="$(cksum "$LPE_DIR/.devflow/prompt-extensions/init.md")"
LPE_IDEM2="$(cd "$LPE_DIR" && bash "$LPE" init 2>/dev/null)"
LPE_CKSUM_AFTER="$(cksum "$LPE_DIR/.devflow/prompt-extensions/init.md")"
assert_eq "lpe: idempotent — identical output on re-run" "$LPE_IDEM1" "$LPE_IDEM2"
assert_eq "lpe: read-only — source file unchanged after run" \
  "$LPE_CKSUM_BEFORE" "$LPE_CKSUM_AFTER"
rm -rf "$LPE_DIR"

# ────────────────────────────────────────────────────────────────────────────
echo "load-prompt-extension.sh: every skills/*/SKILL.md carries the standardized step"
# ────────────────────────────────────────────────────────────────────────────
# Coverage / drift guard (issue #84, AC 6 + AC 7). The standardized step spans
# every skill's SKILL.md; this enumeration is the enforcement that keeps them in
# sync (a cross-file drift hazard). Pin BOTH the
# canonical helper path-suffix AND the skill's own directory name so a copy-paste
# of the wrong skill name, a half-applied removal, or a path drift all fail here
# rather than shipping silently. Fails when a future skill omits the step.
LPE_SKILL_COUNT=0
for SKILL_DIR in "$LIB"/../skills/*/; do
  SKILL_NAME="$(basename "$SKILL_DIR")"
  SKILL_FILE="$SKILL_DIR/SKILL.md"
  LPE_SKILL_COUNT=$((LPE_SKILL_COUNT + 1))
  # Match the FULL canonical invocation as a whole line (grep -Fx), per AC 6's
  # `${CLAUDE_SKILL_DIR}/../../scripts/load-prompt-extension.sh <skill-name>` form.
  # Whole-line fixed-string matching (a) pins each skill's OWN name so a short name
  # that is a prefix of a sibling (docs vs docs-verify, review vs review-and-fix)
  # cannot vacuously match, and (b) rejects a prose mention or a commented-out /
  # HTML-comment-wrapped reference — only a live, exact invocation line passes, so
  # a future edit that comments out the step (leaving a stale reference) fails here.
  # create-issue (issue #241) resolves a portable anchor ($SKILL_DIR) once, near the
  # top, instead of the bare ${CLAUDE_SKILL_DIR} expansion, so its invocation line uses
  # the "$SKILL_DIR"/../../ form; every other skill still carries the canonical bare
  # form. Both are pinned whole-line (grep -Fx), so a name/path drift still fails here.
  if [ "$SKILL_NAME" = "create-issue" ]; then
    LPE_EXPECT_LINE='"$SKILL_DIR"/../../scripts/load-prompt-extension.sh '"$SKILL_NAME"
  else
    LPE_EXPECT_LINE='${CLAUDE_SKILL_DIR}/../../scripts/load-prompt-extension.sh '"$SKILL_NAME"
  fi
  assert_eq "lpe-coverage: $SKILL_NAME/SKILL.md invokes the helper for its own name" "yes" \
    "$([ -f "$SKILL_FILE" ] && grep -Fxq "$LPE_EXPECT_LINE" "$SKILL_FILE" && echo yes || echo no)"  # raw-guard-ok: loop body: SKILL target is the $SKILL_FILE loop variable, not a static pin
  # The invocation line alone is half the contract — the step must also tell the
  # model to HONOR the helper's exit code (surface a non-zero exit, don't silently
  # proceed). Pin a BLOCK-UNIQUE fragment of that prose, NOT a generic one: the
  # phrase "exits non-zero" recurs elsewhere in review/SKILL.md and
  # review-and-fix/SKILL.md (their dismiss-stale / config-get prose), so a generic
  # grep would false-pass for those two skills even if the prompt-extension block's
  # own exit-code prose were deleted. This fragment appears ONLY in the block, so
  # the guard goes red iff the block's exit-code handling is actually removed.
  assert_eq "lpe-coverage: $SKILL_NAME/SKILL.md honors the helper exit code (prose)" "yes" \
    "$([ -f "$SKILL_FILE" ] && grep -qF 'a consumer extension exists but could not be loaded' "$SKILL_FILE" && echo yes || echo no)"  # raw-guard-ok: loop body — $SKILL_FILE is the per-skill loop target, not a static target-unique pin
done
# The two strict-JSON-stdout subagents carry an EXTRA caveat (absent from the other
# 14) that a consumer extension must not break their one-JSON-object contract. Pin
# it so a copy-paste of the generic block over them can't silently erase it.
for SUB in retrospective retrospective-audit; do
  assert_eq "lpe-coverage: $SUB keeps the strict-JSON-contract caveat" "yes" \
    "$(grep -qF 'must not break that contract' "$LIB/../skills/$SUB/SKILL.md" && echo yes || echo no)"  # raw-guard-ok: loop body: SKILL target is the $SUB loop variable, not a static pin
done
# Guard against the loop becoming a vacuous no-op: if the skills/*/ glob ever
# matched nothing (a path typo, a restructure, a wrong CWD), the loop above would
# run zero assertions and the drift guard would silently pass. The guard's entire
# value is catching a future skill that ships without the step, so assert it
# actually enumerated the skills (>0; floor matches the current 16, kept as ≥1 so
# adding a skill never trips it).
assert_eq "lpe-coverage: enumeration is non-vacuous (skills/*/ glob matched)" "yes" \
  "$([ "$LPE_SKILL_COUNT" -ge 1 ] && echo yes || echo no)"

# ────────────────────────────────────────────────────────────────────────────
echo "init project-memory nudge: skills/init/SKILL.md carries the advisory CLAUDE.md step"
# ────────────────────────────────────────────────────────────────────────────
# Content / drift guard (issue #90). The deliverable is LLM-directing prose in a
# SKILL.md — there is no runtime code path to exercise — so the repo's established
# stand-in (mirroring the lpe-coverage and exit-code-contract grep guards above) is
# a content guard pinning the load-bearing instruction tokens. It goes red if the
# advisory step is dropped, reworded away, or loses one of its detected filenames /
# the @-import guidance / the never-write-never-block discipline. Each fragment
# below is BLOCK-UNIQUE to the new step (verified absent from the rest of the SKILL),
# so a match means the step itself is present, not some unrelated prose.
INIT_SKILL="$LIB/../skills/init/SKILL.md"
assert_eq "init-memory-nudge: advisory step heading present" "yes" \
  "$(grep -qF 'advisory project-memory check' "$INIT_SKILL" && echo yes || echo no)"  # raw-guard-ok: non-unique: 'advisory project-memory check' appears twice in init SKILL
# Every detected agent-instruction filename (AC3) plus the CLAUDE.md target itself
# must be named, or the four-case behavior matrix can't be followed.
for FN in 'CLAUDE.md' '.github/copilot-instructions.md' 'AGENTS.md' 'GEMINI.md' '.cursorrules'; do
  assert_eq "init-memory-nudge: names detected file token ($FN)" "yes" \
    "$(grep -qF "$FN" "$INIT_SKILL" && echo yes || echo no)"  # raw-guard-ok: loop body: literal is the $FN loop variable, not a static pin
done
# AGENTS.md is matched across common spellings — case-insensitive (agents.md) plus
# the singular form (agent.md) — AC3. Pin BOTH the prose claim AND a behavioral token
# (the lowercase `agents.md` variant the step actually probes): the word alone could
# survive a regression that trims the variant list down to just `AGENTS.md`, so the
# lowercase form is what proves the spelling/case handling is really there.
assert_eq "init-memory-nudge: AGENTS.md detection is case-insensitive (prose)" "yes" \
  "$(grep -qiF 'case-insensitive' "$INIT_SKILL" && echo yes || echo no)"  # raw-guard-ok: case-insensitive (grep -qi); pin_count is case-sensitive -F
assert_eq "init-memory-nudge: case-insensitive AGENTS variant probed (agents.md)" "yes" \
  "$(grep -qF 'agents.md' "$INIT_SKILL" && echo yes || echo no)"  # raw-guard-ok: non-unique: 'agents.md' appears 3x in init SKILL
# The AGENTS.md spelling/case variants denote one logical convention; on a case-insensitive
# filesystem (macOS) a file's case-variants all match `test -f`, so the step must collapse
# them to a single detection or it would emit a duplicate @-import nudge. Pin the dedup
# instruction so a reword can't silently re-introduce the duplicate-nudge defect.
assert_pin_unique "init-memory-nudge: AGENTS.md case-variants deduped to one (at most once)" 'AT MOST ONCE' "$INIT_SKILL"
# The defensive repo-root guard is the one piece of load-bearing executable shell in the
# step: without it an unresolvable root collapses $ROOT to empty and every probe tests
# "/CLAUDE.md", emitting a misleading nudge. Pin the guard prose so a reword/deletion fails.
assert_pin_unique "init-memory-nudge: defends against an unresolvable repo root" 'Resolve the root defensively' "$INIT_SKILL"
# Case 2 (no CLAUDE.md, agent files present) must not re-expand the deduped detection
# into per-spelling nudges — pin the consumer-side one-nudge-per-physical-file rule so a
# reword can't undo the dedup on the agent-files-present path.
assert_pin_unique "init-memory-nudge: case 2 emits one nudge per physical file" 'nudge per *physical* file' "$INIT_SKILL"
# The unreferenced-import check must distinguish a grep read error (rc>=2) from a genuine
# no-match (rc 1) so a vanished/unreadable CLAUDE.md is not misreported as unreferenced.
assert_pin_unique "init-memory-nudge: grep read-error path stays silent (rc>=2)" 'grep read error' "$INIT_SKILL"
# The @-import reuse guidance (AC4/AC5): pin two concrete repo-root-relative paths,
# including the dotted .github one (the easiest to get wrong).
assert_eq "init-memory-nudge: @-import example for AGENTS.md present" "yes" \
  "$(grep -qF '@AGENTS.md' "$INIT_SKILL" && echo yes || echo no)"  # raw-guard-ok: non-unique: '@AGENTS.md' appears 3x in init SKILL
assert_pin_unique "init-memory-nudge: @-import path for copilot-instructions present" '@.github/copilot-instructions.md' "$INIT_SKILL"
# AC2: the absent-everything case nudges toward the BUILT-IN /init.
assert_eq "init-memory-nudge: recommends the built-in /init" "yes" \
  "$(grep -qF 'built-in `/init`' "$INIT_SKILL" && echo yes || echo no)"  # raw-guard-ok: non-unique: 'built-in /init' appears 3x in init SKILL
# AC7: strictly advisory — never writes any file, never blocks/fails init.
assert_pin_unique "init-memory-nudge: never writes/edits any agent file (advisory)" 'never creates, writes, or edits' "$INIT_SKILL"
assert_pin_unique "init-memory-nudge: never blocks or fails init" 'never blocks or fails init' "$INIT_SKILL"
# AC6 — the silence discipline (no output when nothing is actionable) keeps successful
# re-runs clean; pin it so a reword can't drop the quiet-when-nothing-to-say rule.
assert_pin_unique "init-memory-nudge: stays silent when nothing is actionable (AC6)" 'say nothing when nothing is actionable' "$INIT_SKILL"
# AC5 — the CLAUDE.md-present-but-unreferenced case (matrix case 3). Pin a block-unique
# fragment of that bullet so dropping the 'suggest adding the @-import' branch fails here.
assert_pin_unique "init-memory-nudge: covers CLAUDE.md-present-but-unreferenced case (AC5)" 'does not already reference' "$INIT_SKILL"

# ────────────────────────────────────────────────────────────────────────────
echo "shipped agent_overrides: deduper pins Sonnet 4.6 w/ effort; no Haiku override carries effort"
# ────────────────────────────────────────────────────────────────────────────
# The shipped checklist-deduper override pins Claude Sonnet 4.6 (which DOES
# support `effort`) with effort "medium" — Sonnet 4.6's recommended default, and
# effort must be set explicitly on Sonnet 4.6 to avoid unexpected latency. A
# positive sentinel, not a bare has("effort"): a refactor that drops/renames the
# entry, swaps the model, or strips the effort each FAIL loudly rather than
# sailing through green. The entry must positively EXIST, be object-typed, pin
# claude-sonnet-4-6, AND carry an `effort` key — so a dropped/renamed entry
# ("missing-entry"), a model no longer Sonnet 4.6 ("not-sonnet"), or a removed
# effort ("no-effort") each FAIL loudly.
assert_eq "agent_overrides: shipped deduper override exists, pins Sonnet 4.6, and carries an effort key" \
  "ok" \
  "$(jq -r '
      (.devflow_review.agent_overrides["devflow:checklist-deduper"]) as $d
      | if ($d | type) != "object" then "missing-entry"
        elif (($d.model // "") != "claude-sonnet-4-6") then "not-sonnet"
        elif ($d | has("effort") | not) then "no-effort"
        else "ok" end' "$TPL_DIR/config.example.json")"
# Claude Haiku rejects `effort` with HTTP 400 (supported only on Opus 4.5–4.8 /
# Sonnet 4.6). The shipped example no longer pins Haiku anywhere, but this guard
# keeps the invariant the scaffold-config.sh cleanup protects: should any shipped
# override ever pin a Haiku model, it must NOT also carry an `effort` key.
assert_eq "agent_overrides: no shipped Haiku-pinned override carries an effort key" \
  "ok" \
  "$(jq -r '
      [ (.devflow_review.agent_overrides // {}) | to_entries[]
        | select((.value | type) == "object")
        | select(((.value.model // "") | startswith("claude-haiku-")) and (.value | has("effort"))) ]
      | if length == 0 then "ok" else "haiku-with-effort" end' "$TPL_DIR/config.example.json")"

# ────────────────────────────────────────────────────────────────────────────
echo "config.example.json ⊇ config.schema.json (superset invariant)"
# ────────────────────────────────────────────────────────────────────────────
# config.example.json drives the scaffold/backfill (scaffold-config.sh copies it
# verbatim to a fresh config.json); config.schema.json drives editor validation.
# They are hand-maintained independently, so a key in one but not the other
# silently either won't backfill (a schema default with no example entry never
# reaches a scaffolded config) or is an undocumented/typo'd key the schema does
# not describe. These two assertions pin the relation in both directions:
#   1. every object key in the example is a property the schema defines (catches
#      typo'd / undocumented keys — the schema is additionalProperties:true, so
#      such a key would still *validate*, it would just go unnoticed).
#   2. every schema property carrying a `default` is present in the example (so a
#      backfilled config.json actually carries every defaulted key).
# Scope of the comparison (what is and isn't checked):
#   - Only OBJECT-key paths are compared. Keys nested inside example array
#     ELEMENTS are out of scope — the example has no array-of-object entries
#     (setup.install is a scalar array), and such keys would validate under
#     additionalProperties anyway; kpaths drops array-index paths accordingly.
#   - Optional schema properties with NO default (php_*, services,
#     watched_authors, node_working_directory, …) are intentionally omitted from
#     the example and so are NOT required by check 2.
#   - Defaults are collected from object properties only — dpaths does not
#     descend into array `items`: a default on an array element cannot be
#     satisfied by the (element-less) example, so check 2 would otherwise be
#     permanently unsatisfiable. spaths DOES descend into items so check 1's
#     allowed-key set stays complete (e.g. setup.services.[].image).
# A non-empty list on either side is the drift.
CFG_EXAMPLE="$TPL_DIR/config.example.json"
CFG_SCHEMA="$TPL_DIR/config.schema.json"
CFG_DRIFT="$(jq -n '
  # Property-name paths the schema DEFINES (descends into .properties + .items).
  def spaths:
    def recur($p):
      ( (.properties // {}) | to_entries[] | ($p+[.key]) as $q
        | ($q|join(".")), (.value|recur($q)) ),
      ( (.items // empty) | recur($p+["[]"]) );
    [ recur([]) ];
  # Schema OBJECT-property paths that declare a `default` (the backfillable
  # keys). Deliberately does NOT descend into array `items` — see the scope
  # note above for why an array-element default would make check 2 unsatisfiable.
  def dpaths:
    def recur($p):
      (.properties // {}) | to_entries[] | ($p+[.key]) as $q
      | (if (.value | (type=="object" and has("default"))) then ($q|join(".")) else empty end),
        (.value|recur($q));
    [ recur([]) ];
  # Object-key paths present in the example (array indices excluded).
  def kpaths:
    [ paths | select(all(.[]; type=="string")) | join(".") ];
  input as $ex | input as $sch
  | { example_not_in_schema:        (($ex|kpaths) - ($sch|spaths) | sort),
      schema_default_not_in_example: (($sch|dpaths) - ($ex|kpaths) | sort) }
' "$CFG_EXAMPLE" "$CFG_SCHEMA")"
assert_eq "config: every example key is defined in the schema" "[]" \
  "$(echo "$CFG_DRIFT" | jq -c '.example_not_in_schema')"
assert_eq "config: every schema default appears in the example" "[]" \
  "$(echo "$CFG_DRIFT" | jq -c '.schema_default_not_in_example')"

# ────────────────────────────────────────────────────────────────────────────
echo "detect-project-tools.sh"
# ────────────────────────────────────────────────────────────────────────────
# Language auto-detection: scans a throwaway repo for marker files and merges
# the matching presets (from the repo's real .devflow/tool-presets.json) into a
# .devflow/config.json. Run by scaffold-config.sh, so a regression here silently
# wires the wrong tools into the cloud reviewer.
DPT="$LIB/../scripts/detect-project-tools.sh"

# Helper: does an allowlist contain a tool pattern?
dpt_has() { jq -e --arg t "$2" "$1 | index(\$t) != null" "$3" >/dev/null 2>&1 && echo yes || echo no; }

# 1. Node + npm lockfile → tools land in ALL THREE paths; node_version filled;
#    `npm ci` chosen from package-lock.json; an existing custom entry is kept
#    at the front (ordered union, not alphabetical); install order preserved.
DT1="$(mktemp -d)"; mkdir -p "$DT1/.devflow"
printf '{"name":"x"}' > "$DT1/package.json"
printf '{}' > "$DT1/package-lock.json"
printf '{"devflow":{"allowed_tools":["Bash(make:*)"]},"setup":{"node_version":"","install":["python -m pip install pyyaml"]}}' > "$DT1/.devflow/config.json"
bash "$DPT" "$DT1" >/dev/null 2>&1
assert_eq "detect: npm tool in devflow path"   "yes" "$(dpt_has .devflow.allowed_tools           'Bash(npm:*)' "$DT1/.devflow/config.json")"
assert_eq "detect: npm tool in implement path" "yes" "$(dpt_has .devflow_implement.allowed_tools 'Bash(npm:*)' "$DT1/.devflow/config.json")"
assert_eq "detect: npm tool in runner path"    "yes" "$(dpt_has .devflow_runner.allowed_tools    'Bash(npm:*)' "$DT1/.devflow/config.json")"
assert_eq "detect: node_version filled from empty" "20" \
  "$(jq -r '.setup.node_version' "$DT1/.devflow/config.json")"
assert_eq "detect: npm ci chosen from package-lock.json" "yes" \
  "$(jq -e '.setup.install | index("npm ci") != null' "$DT1/.devflow/config.json" >/dev/null && echo yes || echo no)"
assert_eq "detect: existing custom tool preserved at front (ordered union)" "Bash(make:*)" \
  "$(jq -r '.devflow.allowed_tools[0]' "$DT1/.devflow/config.json")"
assert_eq "detect: pyyaml install line kept first (order preserved)" "python -m pip install pyyaml" \
  "$(jq -r '.setup.install[0]' "$DT1/.devflow/config.json")"
# Negative assertion: the rename must not leave a phantom `claude` object behind
# (a stale `.claude = (.claude // {})` jq initializer would silently inject one).
assert_eq "detect: no stray legacy 'claude' key written" "true" \
  "$(jq -e '.claude == null' "$DT1/.devflow/config.json" >/dev/null && echo true || echo false)"

# 2. Idempotent: a second run changes nothing.
DT1_HASH="$(jq -S . "$DT1/.devflow/config.json" | sha256sum)"
bash "$DPT" "$DT1" >/dev/null 2>&1
assert_eq "detect: idempotent re-run is a no-op" \
  "$DT1_HASH" "$(jq -S . "$DT1/.devflow/config.json" | sha256sum)"

# 3. A pinned node_version is NEVER overridden; no lockfile → `npm install`.
DT2="$(mktemp -d)"; mkdir -p "$DT2/.devflow"
printf '{"name":"y"}' > "$DT2/package.json"
printf '{"setup":{"node_version":"18","install":[]}}' > "$DT2/.devflow/config.json"
bash "$DPT" "$DT2" >/dev/null 2>&1
assert_eq "detect: pinned node_version not overridden" "18" \
  "$(jq -r '.setup.node_version' "$DT2/.devflow/config.json")"
assert_eq "detect: no lockfile → npm install" "yes" \
  "$(jq -e '.setup.install | index("npm install") != null' "$DT2/.devflow/config.json" >/dev/null && echo yes || echo no)"

# 4. False-positive guard: a marker ONLY inside node_modules must NOT match —
#    config stays exactly the empty object it started as.
DT3="$(mktemp -d)"; mkdir -p "$DT3/.devflow" "$DT3/node_modules/foo"
printf '{"x":1}' > "$DT3/node_modules/foo/package.json"
printf '{}' > "$DT3/.devflow/config.json"
bash "$DPT" "$DT3" >/dev/null 2>&1
assert_eq "detect: vendored node_modules marker does not trigger" "{}" \
  "$(jq -c . "$DT3/.devflow/config.json")"

# 5. Glob marker (*.csproj) matches dotnet.
DT4="$(mktemp -d)"; mkdir -p "$DT4/.devflow"
printf '<Project/>' > "$DT4/App.csproj"
printf '{}' > "$DT4/.devflow/config.json"
bash "$DPT" "$DT4" >/dev/null 2>&1
assert_eq "detect: *.csproj glob matches dotnet" "yes" \
  "$(dpt_has .devflow_runner.allowed_tools 'Bash(dotnet:*)' "$DT4/.devflow/config.json")"

# 6. PHP (composer.json) → php tools in all paths AND a composer install line.
DT5="$(mktemp -d)"; mkdir -p "$DT5/.devflow"
printf '{"require":{"php":">=8.2"}}' > "$DT5/composer.json"
printf '{}' > "$DT5/.devflow/config.json"
bash "$DPT" "$DT5" >/dev/null 2>&1
assert_eq "detect: composer tool in runner path" "yes" \
  "$(dpt_has .devflow_runner.allowed_tools 'Bash(composer:*)' "$DT5/.devflow/config.json")"
assert_eq "detect: composer install line added" "yes" \
  "$(jq -e '.setup.install | index("composer install --no-interaction --prefer-dist --no-progress") != null' "$DT5/.devflow/config.json" >/dev/null && echo yes || echo no)"

# 7. Subdirectory Node build (package.json + lockfile under jsx/) → detection
#    sets node_working_directory to the subdir AND scopes the install line into
#    it with a subshell `cd` (not a root-level npm ci that would no-op).
DT6="$(mktemp -d)"; mkdir -p "$DT6/.devflow" "$DT6/jsx"
printf '{"name":"bundle"}' > "$DT6/jsx/package.json"
printf '{}' > "$DT6/jsx/package-lock.json"
printf '{"setup":{"node_version":"","install":[]}}' > "$DT6/.devflow/config.json"
bash "$DPT" "$DT6" >/dev/null 2>&1
assert_eq "detect: subdir build sets node_working_directory" "jsx" \
  "$(jq -r '.setup.node_working_directory' "$DT6/.devflow/config.json")"
assert_eq "detect: subdir install line is subshell-scoped into the dir (quoted)" "yes" \
  "$(jq -e '.setup.install | index("(cd '\''jsx'\'' && npm ci)") != null' "$DT6/.devflow/config.json" >/dev/null && echo yes || echo no)"

# 8. Root Node build → node_working_directory is NEVER written (byte-identical
#    to the pre-feature behavior) and the install line stays a bare npm ci.
DT7="$(mktemp -d)"; mkdir -p "$DT7/.devflow"
printf '{"name":"rootapp"}' > "$DT7/package.json"
printf '{}' > "$DT7/package-lock.json"
printf '{"setup":{"node_version":"","install":[]}}' > "$DT7/.devflow/config.json"
bash "$DPT" "$DT7" >/dev/null 2>&1
assert_eq "detect: root build writes no node_working_directory key" "true" \
  "$(jq -e '.setup | has("node_working_directory") | not' "$DT7/.devflow/config.json" >/dev/null && echo true || echo false)"
assert_eq "detect: root build install line is bare npm ci (no cd)" "yes" \
  "$(jq -e '.setup.install | index("npm ci") != null' "$DT7/.devflow/config.json" >/dev/null && echo yes || echo no)"

# 9. Subdirectory npm-shrinkwrap.json (the 4th lockfile) → detected just like
#    package-lock.json, mapping to `npm ci`, so detection stays consistent with
#    resolve-node-cache.sh / action.yml (which both honor shrinkwrap).
DT8="$(mktemp -d)"; mkdir -p "$DT8/.devflow" "$DT8/jsx"
printf '{"name":"bundle"}' > "$DT8/jsx/package.json"
printf '{}' > "$DT8/jsx/npm-shrinkwrap.json"
printf '{"setup":{"node_version":"","install":[]}}' > "$DT8/.devflow/config.json"
bash "$DPT" "$DT8" >/dev/null 2>&1
assert_eq "detect: subdir npm-shrinkwrap.json sets node_working_directory" "jsx" \
  "$(jq -r '.setup.node_working_directory' "$DT8/.devflow/config.json")"
assert_eq "detect: subdir shrinkwrap install line is (cd 'jsx' && npm ci)" "yes" \
  "$(jq -e '.setup.install | index("(cd '\''jsx'\'' && npm ci)") != null' "$DT8/.devflow/config.json" >/dev/null && echo yes || echo no)"

# 10. A subdirectory name containing a space is single-quoted in the generated
#     install line, so it survives the `bash -c` exec in the action verbatim.
DT9="$(mktemp -d)"; mkdir -p "$DT9/.devflow" "$DT9/my app"
printf '{"name":"bundle"}' > "$DT9/my app/package.json"
printf '{}' > "$DT9/my app/package-lock.json"
printf '{"setup":{"node_version":"","install":[]}}' > "$DT9/.devflow/config.json"
bash "$DPT" "$DT9" >/dev/null 2>&1
assert_eq "detect: spaced subdir name is quoted in install line" "yes" \
  "$(jq -e '.setup.install | index("(cd '\''my app'\'' && npm ci)") != null' "$DT9/.devflow/config.json" >/dev/null && echo yes || echo no)"
assert_eq "detect: spaced subdir name written verbatim to node_working_directory" "my app" \
  "$(jq -r '.setup.node_working_directory' "$DT9/.devflow/config.json")"

# 11. Best-effort shape guard: a malformed pre-existing config (numeric
#     node_version, which the schema types as a string) is carried through the
#     merge into valid-but-wrong-shaped JSON. The guard must REFUSE to write it —
#     the user's config is left byte-identical — and the script must still exit 0
#     (best-effort, never blocks the surrounding scaffold).
DT10="$(mktemp -d)"; mkdir -p "$DT10/.devflow"
printf '{"name":"z"}' > "$DT10/package.json"
printf '{}' > "$DT10/package-lock.json"
printf '{"setup":{"node_version":20,"install":[]}}' > "$DT10/.devflow/config.json"
DT10_BEFORE="$(cat "$DT10/.devflow/config.json")"
bash "$DPT" "$DT10" >/dev/null 2>&1
assert_eq "detect: shape-drifted merge still exits 0 (best-effort)" "0" "$?"
assert_eq "detect: shape-drifted merge leaves config untouched" \
  "$DT10_BEFORE" "$(cat "$DT10/.devflow/config.json")"

# 12. The shape guard does NOT block a well-formed merge: a valid empty config
#     with a node marker is merged and written (npm tools land), confirming the
#     guard is a safety net, not a gate on the happy path.
DT11="$(mktemp -d)"; mkdir -p "$DT11/.devflow"
printf '{"name":"ok"}' > "$DT11/package.json"
printf '{}' > "$DT11/package-lock.json"
printf '{}' > "$DT11/.devflow/config.json"
bash "$DPT" "$DT11" >/dev/null 2>&1
assert_eq "detect: well-formed merge passes the guard and is written" "yes" \
  "$(dpt_has .devflow.allowed_tools 'Bash(npm:*)' "$DT11/.devflow/config.json")"

# 13. Windows regression: the native Windows jq build (winget jqlang.jq, run
#     under Git Bash) terminates every stdout line with CRLF. The marker/preset
#     read loops must strip the trailing CR — otherwise `read` captures keys like
#     $'node\r', the `.presets[$k]` lookup asks for a key that doesn't exist, and
#     a repo with valid markers is reported as "no known language markers". We
#     can't install a Windows jq in CI, so we shadow jq on PATH with a wrapper
#     that appends a CR to every output line (a faithful stand-in) and confirm a
#     plain Node repo is still detected end-to-end.
DT12="$(mktemp -d)"; mkdir -p "$DT12/.devflow" "$DT12/bin"
printf '{"name":"win"}' > "$DT12/package.json"
printf '{}' > "$DT12/package-lock.json"
printf '{}' > "$DT12/.devflow/config.json"
DT12_REAL_JQ="$(command -v jq)"
cat > "$DT12/bin/jq" <<EOF
#!/usr/bin/env bash
# Stand-in for the native Windows jq: delegate to real jq, then CRLF every line.
"$DT12_REAL_JQ" "\$@" | awk '{ printf "%s\r\n", \$0 }'
EOF
chmod +x "$DT12/bin/jq"
# Sanity guard: confirm the shim actually injects CRLF. Without this, a future
# break in the wrapper would turn the regression test below into a passing
# no-op (it would assert "yes" even with the fix removed). If this fails, the
# CRLF path is no longer being exercised — fix the shim, not the assertion.
assert_eq "detect(DT12 control): jq shim emits CRLF" "yes" \
  "$(PATH="$DT12/bin:$PATH" jq -n '1' | grep -q $'\r' && echo yes || echo no)"
PATH="$DT12/bin:$PATH" bash "$DPT" "$DT12" >/dev/null 2>&1
assert_eq "detect: CRLF jq stdout (Windows) exits 0" "0" "$?"
assert_eq "detect: CRLF jq stdout (Windows) still detects node markers" "yes" \
  "$(dpt_has .devflow.allowed_tools 'Bash(npm:*)' "$DT12/.devflow/config.json")"

rm -rf "$DT1" "$DT2" "$DT3" "$DT4" "$DT5" "$DT6" "$DT7" "$DT8" "$DT9" "$DT10" "$DT11" "$DT12"

# ────────────────────────────────────────────────────────────────────────────
echo "resolve-node-cache.sh (setup-project-env helper)"
# ────────────────────────────────────────────────────────────────────────────
# Resolves setup-node's `cache` / `cache-dependency-path` for a Node project
# that may live in a subdirectory. The script probes lockfiles relative to cwd,
# so each case runs it from a throwaway repo root. A regression here silently
# disables caching for subdir builds or — worse — regresses root-based ones.
RNC="$LIB/../.github/actions/setup-project-env/resolve-node-cache.sh"
rnc() { ( cd "$1" && bash "$RNC" "$2" "${3:-}" ); }

# Subdirectory lockfile + node_working_directory set → caching enabled, path
# qualified by the directory.
RNC_SUB="$(mktemp -d)"; mkdir -p "$RNC_SUB/jsx"; : > "$RNC_SUB/jsx/package-lock.json"
RNC_OUT="$(rnc "$RNC_SUB" 20 jsx)"
assert_eq "rnc: subdir lockfile → npm cache"        "node_cache=npm" \
  "$(printf '%s\n' "$RNC_OUT" | grep '^node_cache=')"
assert_eq "rnc: subdir lockfile → qualified path"   "node_cache_path=jsx/package-lock.json" \
  "$(printf '%s\n' "$RNC_OUT" | grep '^node_cache_path=')"
# Trailing slash on the directory is normalized (no doubled slash in the path).
RNC_OUT_TS="$(rnc "$RNC_SUB" 20 jsx/)"
assert_eq "rnc: trailing slash normalized"          "node_cache_path=jsx/package-lock.json" \
  "$(printf '%s\n' "$RNC_OUT_TS" | grep '^node_cache_path=')"

# Root lockfile, empty working directory → identical to the historical
# root-based outputs (no regression).
RNC_ROOT="$(mktemp -d)"; : > "$RNC_ROOT/yarn.lock"
RNC_OUT="$(rnc "$RNC_ROOT" 20 "")"
assert_eq "rnc: root yarn.lock → yarn cache"        "node_cache=yarn" \
  "$(printf '%s\n' "$RNC_OUT" | grep '^node_cache=')"
assert_eq "rnc: root yarn.lock → bare path"         "node_cache_path=yarn.lock" \
  "$(printf '%s\n' "$RNC_OUT" | grep '^node_cache_path=')"

# pnpm wins over a co-present npm lockfile (precedence preserved).
RNC_PREC="$(mktemp -d)"; : > "$RNC_PREC/pnpm-lock.yaml"; : > "$RNC_PREC/package-lock.json"
assert_eq "rnc: pnpm precedence over npm"           "node_cache=pnpm" \
  "$(rnc "$RNC_PREC" 20 "" | grep '^node_cache=')"

# npm-shrinkwrap.json (the 4th lockfile) → npm cache, qualified path.
RNC_SHR="$(mktemp -d)"; mkdir -p "$RNC_SHR/jsx"; : > "$RNC_SHR/jsx/npm-shrinkwrap.json"
RNC_OUT="$(rnc "$RNC_SHR" 20 jsx)"
assert_eq "rnc: subdir shrinkwrap → npm cache"      "node_cache=npm" \
  "$(printf '%s\n' "$RNC_OUT" | grep '^node_cache=')"
assert_eq "rnc: subdir shrinkwrap → qualified path" "node_cache_path=jsx/npm-shrinkwrap.json" \
  "$(printf '%s\n' "$RNC_OUT" | grep '^node_cache_path=')"

# Working directory set but no lockfile in it (config drift: dir named but
# lockfile not committed there) → caching off, so setup-node never errors.
RNC_WDNF="$(mktemp -d)"; mkdir -p "$RNC_WDNF/jsx"
assert_eq "rnc: working dir set but no lockfile → empty cache" "node_cache=" \
  "$(rnc "$RNC_WDNF" 20 jsx | grep '^node_cache=')"

# No lockfile → caching disabled (empty), so setup-node never errors.
RNC_NONE="$(mktemp -d)"
RNC_OUT="$(rnc "$RNC_NONE" 20 "")"
assert_eq "rnc: no lockfile → empty cache"          "node_cache=" \
  "$(printf '%s\n' "$RNC_OUT" | grep '^node_cache=')"
assert_eq "rnc: no lockfile → empty path"           "node_cache_path=" \
  "$(printf '%s\n' "$RNC_OUT" | grep '^node_cache_path=')"

# Empty node_version → caching off even when a lockfile is present (the "Node
# not provisioned" case — setup-node won't run, so a cache key is meaningless).
assert_eq "rnc: empty node_version → no cache"      "node_cache=" \
  "$(rnc "$RNC_ROOT" "" "" | grep '^node_cache=')"

rm -rf "$RNC_SUB" "$RNC_ROOT" "$RNC_PREC" "$RNC_SHR" "$RNC_WDNF" "$RNC_NONE"

# ────────────────────────────────────────────────────────────────────────────
echo "config-source.sh"
# ────────────────────────────────────────────────────────────────────────────
( export DEVFLOW_CONFIG_FILE="$LIB/test/fixtures/config.json"
  . "$LIB/config-source.sh"
  assert_eq "watched authors from config" "claude,example-bot" "$(devflow_watched_authors)"
  assert_eq "min_occurrences from config" "2" "$(devflow_conf '.devflow_retrospective.min_occurrences' 99)"
  assert_eq "missing key → default" "fallback" "$(devflow_conf '.devflow_retrospective.nonexistent_key_xyz' fallback)"
)
# Resilience: config-source.sh runs under `set -e`; a missing or malformed config must
# return the default without aborting the sourcing chain.
( export DEVFLOW_CONFIG_FILE="/no/such/devflow/config.json"
  . "$LIB/config-source.sh"
  assert_eq "conf: missing file → default (no abort)" "dflt" "$(devflow_conf '.anything' dflt)"
)
( wp="$(mktemp)"; printf '{ not valid json' > "$wp"
  export DEVFLOW_CONFIG_FILE="$wp"
  . "$LIB/config-source.sh"
  assert_eq "conf: malformed JSON → default (warns, no abort)" "dflt" "$(devflow_conf '.anything' dflt 2>/dev/null)"
  rm -f "$wp"
)
# watched_authors falls back to devflow.allowed_bots when the override array is absent.
( wp="$(mktemp)"; printf '{"devflow":{"allowed_bots":"claude,fallback-bot"}}' > "$wp"
  export DEVFLOW_CONFIG_FILE="$wp"
  . "$LIB/config-source.sh"
  assert_eq "conf: watched_authors → allowed_bots fallback" "claude,fallback-bot" "$(devflow_watched_authors)"
  rm -f "$wp"
)

# ────────────────────────────────────────────────────────────────────────────
echo "scan.sh"
# ────────────────────────────────────────────────────────────────────────────
SCAN_TMP="$(mktemp -d)"
cat > "$SCAN_TMP/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"repo view"*) echo "acme/example-repo" ;;
  *"pr list"*"author:claude"*)
    echo '[{"number":1,"headRefName":"claude/issue-1-a","author":{"login":"claude"},"mergedAt":"2026-05-01T00:00:00Z"},
           {"number":3,"headRefName":"claude/issue-3-c","author":{"login":"claude"},"mergedAt":"2026-05-03T00:00:00Z"},
           {"number":9,"headRefName":"devflow/learnings-2026-W18","author":{"login":"example-bot"},"mergedAt":"2026-05-02T00:00:00Z"}]' ;;
  *"pr list"*) echo '[]' ;;
  *"api"*"retrospectives.jsonl?ref=main"*)
    BODY="$(printf '{"pr":1}\n{"pr":2}\n' | base64 | tr -d "\n")"
    printf 'HTTP/2.0 200 OK\r\n\r\n{"content":"%s"}\n' "$BODY" ;;
  *) echo '[]' ;;
esac
STUB
chmod +x "$SCAN_TMP/gh"
SCAN_OUT="$(DEVFLOW_CONFIG_FILE="$LIB/test/fixtures/config.json" DEVFLOW_GH="$SCAN_TMP/gh" bash "$LIB/scan.sh" 2>/dev/null)"
assert_eq "scan includes unprocessed PR 3"        "true"  "$(echo "$SCAN_OUT" | jq 'any(.[]; .number==3)')"
assert_eq "scan excludes already-recorded PR 1"   "false" "$(echo "$SCAN_OUT" | jq 'any(.[]; .number==1)')"
assert_eq "scan excludes devflow/learnings branch" "false" "$(echo "$SCAN_OUT" | jq 'any(.[]; .number==9)')"

# #7a: --prs ad-hoc mode — explicit numbers, no search, no processed-filter;
# still drops non-merged / non-retrospected branches.
cat > "$SCAN_TMP/gh2" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"repo view"*) echo "acme/example-repo" ;;
  *"pr view 1 --repo"*) echo '{"number":1,"headRefName":"claude/issue-1-a","mergedAt":"2026-05-01T00:00:00Z","state":"MERGED"}' ;;
  *"pr view 2 --repo"*) echo '{"number":2,"headRefName":"feature/hand-written","mergedAt":"2026-05-02T00:00:00Z","state":"MERGED"}' ;;
  *"pr view 3 --repo"*) echo '{"number":3,"headRefName":"claude/issue-3-c","mergedAt":"2026-05-03T00:00:00Z","state":"OPEN"}' ;;
  *) echo '[]' ;;
esac
STUB
chmod +x "$SCAN_TMP/gh2"
PRS_OUT="$(DEVFLOW_GH="$SCAN_TMP/gh2" bash "$LIB/scan.sh" --prs "1,2,3" 2>/dev/null)"
assert_eq "--prs includes explicit merged retrospected PR 1" "true"  "$(echo "$PRS_OUT" | jq 'any(.[]; .number==1)')"
assert_eq "--prs drops non-retrospected branch PR 2"        "false" "$(echo "$PRS_OUT" | jq 'any(.[]; .number==2)')"
assert_eq "--prs drops non-merged PR 3"                     "false" "$(echo "$PRS_OUT" | jq 'any(.[]; .number==3)')"
assert_eq "--prs ignores already-processed retrospectives.jsonl (PR 1 from gh stub matches an EXISTING pr in weekly mode but here is kept)" "1" "$(echo "$PRS_OUT" | jq 'length')"

# #103 I-2: in --prs mode, a jq PREDICATE EVALUATION failure must emit a distinct
# "predicate evaluation failed" breadcrumb, not be misreported as a clean "matches
# no retrospection path" exclusion (which asserts the PR was evaluated-and-excluded
# when the predicate may never have run). Force the jq error with a non-array
# `labels` shape: the predicate's `(.labels // [])` guard defaults only null/false,
# so `map(...)` over a string aborts the filter (exit non-zero).
cat > "$SCAN_TMP/gh3" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"repo view"*) echo "acme/example-repo" ;;
  *"pr view 5 --repo"*) echo '{"number":5,"headRefName":"claude/issue-5","mergedAt":"2026-05-01T00:00:00Z","state":"MERGED","labels":"not-an-array","closingIssuesReferences":[],"author":{"login":"x"}}' ;;
  *) echo '[]' ;;
esac
STUB
chmod +x "$SCAN_TMP/gh3"
PRS_ERR_OUT="$(DEVFLOW_CONFIG_FILE="$LIB/test/fixtures/config.json" DEVFLOW_GH="$SCAN_TMP/gh3" bash "$LIB/scan.sh" --prs "5" 2>&1 >/dev/null)"
assert_eq "#103 I-2: --prs jq predicate error emits 'predicate evaluation failed' breadcrumb" "true" \
  "$(echo "$PRS_ERR_OUT" | grep -q 'predicate evaluation failed' && echo true || echo false)"
assert_eq "#103 I-2: --prs jq predicate error is NOT misreported as 'matches no retrospection path'" "false" \
  "$(echo "$PRS_ERR_OUT" | grep -q 'matches no retrospection path' && echo true || echo false)"
# F1 (review): the breadcrumb names the actual jq cause (exit code + diagnostic),
# not just "failed" — `jq exit <n>:` is the format that carries the captured stderr.
assert_eq "#103 F1: --prs predicate-error breadcrumb names the jq exit code + diagnostic" "true" \
  "$(echo "$PRS_ERR_OUT" | grep -Eq 'jq exit [0-9]+:' && echo true || echo false)"

# #103 I-2 (negative): a genuine non-match still emits the "matches no retrospection
# path" breadcrumb (and NOT the predicate-failure one) — the split must not collapse
# the two cases in the other direction.
cat > "$SCAN_TMP/gh3b" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"repo view"*) echo "acme/example-repo" ;;
  *"pr view 6 --repo"*) echo '{"number":6,"headRefName":"feature/plain","mergedAt":"2026-05-01T00:00:00Z","state":"MERGED","labels":[],"closingIssuesReferences":[],"author":{"login":"x"}}' ;;
  *) echo '[]' ;;
esac
STUB
chmod +x "$SCAN_TMP/gh3b"
PRS_NM="$(DEVFLOW_CONFIG_FILE="$LIB/test/fixtures/config.json" DEVFLOW_GH="$SCAN_TMP/gh3b" bash "$LIB/scan.sh" --prs "6" 2>&1 >/dev/null)"
assert_eq "#103 I-2: genuine non-match still says 'matches no retrospection path'" "true" \
  "$(echo "$PRS_NM" | grep -q 'matches no retrospection path' && echo true || echo false)"
assert_eq "#103 I-2: genuine non-match does NOT say 'predicate evaluation failed'" "false" \
  "$(echo "$PRS_NM" | grep -q 'predicate evaluation failed' && echo true || echo false)"

# #103 I-3: in weekly mode, a candidate-source fetch hard-failure (here the
# DevFlow-label `gh pr list`) must force a NON-ZERO exit, so a partial GitHub
# outage cannot masquerade as "0 new PRs" and let a cron see success.
cat > "$SCAN_TMP/gh4" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"repo view"*) echo "acme/example-repo" ;;
  *"pr list"*"--label DevFlow"*) echo "boom: gh outage" >&2; exit 1 ;;
  *"pr list"*) echo '[]' ;;
  *"api"*"retrospectives.jsonl?ref=main"*) printf 'HTTP/2.0 404 Not Found\r\n\r\n' ;;
  *) echo '[]' ;;
esac
STUB
chmod +x "$SCAN_TMP/gh4"
SCAN_DEG="$(DEVFLOW_CONFIG_FILE="$LIB/test/fixtures/config.json" DEVFLOW_GH="$SCAN_TMP/gh4" bash "$LIB/scan.sh" 2>&1 >/dev/null)"; SCAN_DEG_RC=$?
assert_eq "#103 I-3: weekly label-fetch hard failure exits non-zero (no silent under-count)" "1" "$SCAN_DEG_RC"
assert_eq "#103 I-3: weekly degraded run emits an ::error:: breadcrumb" "true" \
  "$(echo "$SCAN_DEG" | grep -q '::error::scan:' && echo true || echo false)"
# F2 (review): the per-source ::warning:: names the actual gh cause, not just "failed".
assert_eq "#103 F2: weekly degraded breadcrumb names the underlying gh cause" "true" \
  "$(echo "$SCAN_DEG" | grep -q 'boom: gh outage' && echo true || echo false)"

# #103 I-3 / T1 (review): the watched-author path also degrades. Only the
# label-fetch path was exercised above; here a watched-author `pr list` returns a
# non-array, so the author-side jq RESHAPE aborts (`.labels` on a string), which
# must set DEGRADED and exit non-zero exactly like the label path.
cat > "$SCAN_TMP/gh6" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"repo view"*) echo "acme/example-repo" ;;
  *"pr list"*"--label DevFlow"*) echo '[]' ;;
  *"pr list"*"author:"*) echo '{"not":"an-array"}' ;;
  *"pr list"*) echo '[]' ;;
  *"api"*"retrospectives.jsonl?ref=main"*) printf 'HTTP/2.0 404 Not Found\r\n\r\n' ;;
  *) echo '[]' ;;
esac
STUB
chmod +x "$SCAN_TMP/gh6"
DEVFLOW_CONFIG_FILE="$LIB/test/fixtures/config.json" DEVFLOW_GH="$SCAN_TMP/gh6" bash "$LIB/scan.sh" >/dev/null 2>&1; SCAN_AUTHOR_DEG_RC=$?
assert_eq "#103 I-3/T1: weekly watched-author reshape failure exits non-zero too" "1" "$SCAN_AUTHOR_DEG_RC"

# #103 I-3/T1 (shadow): complete the 2x2 degraded matrix (label|author x fetch|reshape).
# gh4=label-fetch, gh6=author-reshape above; here gh7=label-RESHAPE (a non-array label
# batch aborts the reshape jq) and gh8=author-FETCH (author `pr list` exits non-zero).
cat > "$SCAN_TMP/gh7" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"repo view"*) echo "acme/example-repo" ;;
  *"pr list"*"--label DevFlow"*) echo '{"not":"an-array"}' ;;
  *"pr list"*) echo '[]' ;;
  *"api"*"retrospectives.jsonl?ref=main"*) printf 'HTTP/2.0 404 Not Found\r\n\r\n' ;;
  *) echo '[]' ;;
esac
STUB
chmod +x "$SCAN_TMP/gh7"
DEVFLOW_CONFIG_FILE="$LIB/test/fixtures/config.json" DEVFLOW_GH="$SCAN_TMP/gh7" bash "$LIB/scan.sh" >/dev/null 2>&1; SCAN_LBL_RESHAPE_RC=$?
assert_eq "#103 I-3/T1: weekly label-reshape failure exits non-zero" "1" "$SCAN_LBL_RESHAPE_RC"
cat > "$SCAN_TMP/gh8" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"repo view"*) echo "acme/example-repo" ;;
  *"pr list"*"--label DevFlow"*) echo '[]' ;;
  *"pr list"*"author:"*) echo "author fetch outage" >&2; exit 1 ;;
  *"pr list"*) echo '[]' ;;
  *"api"*"retrospectives.jsonl?ref=main"*) printf 'HTTP/2.0 404 Not Found\r\n\r\n' ;;
  *) echo '[]' ;;
esac
STUB
chmod +x "$SCAN_TMP/gh8"
DEVFLOW_CONFIG_FILE="$LIB/test/fixtures/config.json" DEVFLOW_GH="$SCAN_TMP/gh8" bash "$LIB/scan.sh" >/dev/null 2>&1; SCAN_AUTHOR_FETCH_RC=$?
assert_eq "#103 I-3/T1: weekly watched-author fetch failure exits non-zero" "1" "$SCAN_AUTHOR_FETCH_RC"

# #103 I-3 (regression): a fully-healthy weekly run still exits 0.
DEVFLOW_CONFIG_FILE="$LIB/test/fixtures/config.json" DEVFLOW_GH="$SCAN_TMP/gh" bash "$LIB/scan.sh" >/dev/null 2>&1; SCAN_OK_RC=$?
assert_eq "#103 I-3: healthy weekly run still exits 0" "0" "$SCAN_OK_RC"

# #100: retrospectives.jsonl HTTP-200 decode is loud on a decode/parse MISS, not
# silently collapsed to [] (which would re-queue the whole backlog and create
# duplicate retrospectives). Adversarial input-shape matrix over the 200 branch:
#   content {valid-jsonl-no-pr, base64-of-non-json, invalid-base64, ""+download_url, ""+none}.
# One stub serves all shapes; the per-shape response is injected via $SCAN_RESP
# (read at runtime, so embedded quotes never traverse the stub's bash quoting).
cat > "$SCAN_TMP/gh-100" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"repo view"*) echo "acme/example-repo" ;;
  *"api"*"retrospectives.jsonl?ref=main"*) printf '%b' "$SCAN_RESP" ;;
  *"api"*"raw/retro.jsonl"*) printf '{"pr":1}\n{"pr":2}\n' ;;   # download_url: real records
  *"api"*"raw/nopr.jsonl"*) printf '{"notpr":1}\n' ;;           # download_url: parseable, zero pr records
  *"api"*"raw/fail.jsonl"*) exit 1 ;;                           # download_url: fetch failure
  *"pr list"*) echo '[]' ;;
  *) echo '[]' ;;
esac
STUB
chmod +x "$SCAN_TMP/gh-100"

# Driver (house style: cf. rnc/ex/di): run scan.sh against the gh-100 stub with
# the given 200-response injected as $SCAN_RESP. Captures scan's stderr into the
# global $SCAN_ERR (stdout discarded); the call's own $? carries scan's exit, so
# a caller does `scan100 '...'; RC=$?` then asserts on $RC and $SCAN_ERR.
scan100() {  # $1 = $SCAN_RESP value (printf %b-interpreted by the stub)
  SCAN_ERR="$(SCAN_RESP="$1" DEVFLOW_CONFIG_FILE="$LIB/test/fixtures/config.json" \
    DEVFLOW_GH="$SCAN_TMP/gh-100" bash "$LIB/scan.sh" 2>&1 >/dev/null)"
}
# Substring membership → "yes"/"no" (assert_eq is the only assertion helper), so
# each loud-failure case can assert the SPECIFIC breadcrumb, not just exit 1 —
# CLAUDE.md: a generic/misdirected breadcrumb is itself the bug for this code.
have() {  # $1 = needle, $2 = haystack
  case "$2" in *"$1"*) echo yes ;; *) echo no ;; esac
}

# Build the base64 payloads with the local base64 so the test is host-portable.
B64_NOPR="$(printf '{"notpr":1}\n{"other":2}\n' | base64 | tr -d '\n')"
B64_NONJSON="$(printf 'this is not json\nat all\n' | base64 | tr -d '\n')"
B64_PR="$(printf '{"pr":1}\n{"pr":2}\n' | base64 | tr -d '\n')"

scan100 'HTTP/2.0 200 OK\r\n\r\n{"content":"'"$B64_NOPR"'"}\n'; RC=$?
assert_eq "scan #100: inline content with zero pr records exits loud" "1" "$RC"
assert_eq "scan #100: zero-record breadcrumb names the collapse" "yes" "$(have 'zero pr records' "$SCAN_ERR")"
assert_eq "scan #100: zero-record breadcrumb names the inline source" "yes" "$(have '(inline content)' "$SCAN_ERR")"

scan100 'HTTP/2.0 200 OK\r\n\r\n{"content":"'"$B64_NONJSON"'"}\n'; RC=$?
assert_eq "scan #100: base64-of-non-json content (jq parse miss) exits loud" "1" "$RC"
assert_eq "scan #100: parse-miss breadcrumb names parsing failure" "yes" "$(have 'parsing retrospectives.jsonl (inline content) failed' "$SCAN_ERR")"

scan100 'HTTP/2.0 200 OK\r\n\r\n{"content":"@@not-valid-base64@@"}\n'; RC=$?
assert_eq "scan #100: invalid base64 content (decode miss) exits loud" "1" "$RC"
assert_eq "scan #100: decode-miss breadcrumb names base64" "yes" "$(have 'base64 decode' "$SCAN_ERR")"

scan100 'HTTP/2.0 200 OK\r\n\r\n{"content":"","foo":1}\n'; RC=$?
assert_eq "scan #100: HTTP 200 with neither content nor download_url exits loud" "1" "$RC"
assert_eq "scan #100: no-fallback breadcrumb names the missing surfaces" "yes" "$(have 'neither inline content nor a download_url' "$SCAN_ERR")"

# An unparseable 200 envelope (non-JSON body) fails with its OWN accurate
# breadcrumb, not the misleading "neither content nor download_url" one.
scan100 'HTTP/2.0 200 OK\r\n\r\nthis is not a json envelope\n'; RC=$?
assert_eq "scan #100: unparseable HTTP-200 envelope exits loud" "1" "$RC"
assert_eq "scan #100: unparseable-envelope breadcrumb is specific" "yes" "$(have 'envelope was not parseable JSON' "$SCAN_ERR")"

# download_url (>1 MB) branch now shares the zero-record collapse guard: a
# parseable body carrying zero pr records must fail loud, not silently re-queue.
scan100 'HTTP/2.0 200 OK\r\n\r\n{"content":"","download_url":"https://example.test/raw/nopr.jsonl"}\n'; RC=$?
assert_eq "scan #100: download_url body with zero pr records exits loud" "1" "$RC"
assert_eq "scan #100: download_url zero-record breadcrumb names the source" "yes" "$(have '(download_url)' "$SCAN_ERR")"

# download_url branch: a failed fetch of the large file exits loud with a specific cause.
scan100 'HTTP/2.0 200 OK\r\n\r\n{"content":"","download_url":"https://example.test/raw/fail.jsonl"}\n'; RC=$?
assert_eq "scan #100: download_url fetch failure exits loud" "1" "$RC"
assert_eq "scan #100: download_url fetch-failure breadcrumb is specific" "yes" "$(have 'via download_url failed' "$SCAN_ERR")"

# Non-200/404 HTTP status is fatal — never proceed on an empty processed-set.
scan100 'HTTP/2.0 500 Internal Server Error\r\n\r\n{}\n'; RC=$?
assert_eq "scan #100: HTTP 500 exits loud" "1" "$RC"
assert_eq "scan #100: HTTP-500 breadcrumb names the status" "yes" "$(have 'HTTP 500' "$SCAN_ERR")"

# Regression: the >1 MB download_url fallback path still parses cleanly (exit 0)
# when the fetched body carries real pr records.
scan100 'HTTP/2.0 200 OK\r\n\r\n{"content":"","download_url":"https://example.test/raw/retro.jsonl"}\n'; RC=$?
assert_eq "scan #100: download_url fallback with real records succeeds (exit 0)" "0" "$RC"

# Regression: the original happy path (valid jsonl with pr records) still exits 0.
scan100 'HTTP/2.0 200 OK\r\n\r\n{"content":"'"$B64_PR"'"}\n'; RC=$?
assert_eq "scan #100: valid jsonl with pr records still succeeds (exit 0)" "0" "$RC"

rm -rf "$SCAN_TMP"

# ────────────────────────────────────────────────────────────────────────────
echo "fetch-pr-context.sh"
# ────────────────────────────────────────────────────────────────────────────
GH_STUB="$LIB/test/fixtures/gh-stub.sh"
OUT="$(DEVFLOW_GH="$GH_STUB" DEVFLOW_FIXTURE_PR=793 bash "$LIB/fetch-pr-context.sh" 793)"
CTX="$(cat "$OUT")"
assert_eq "kind=implementation"            "implementation" "$(jq -r .kind            <<<"$CTX")"
assert_eq "issue_number parsed"            "790"            "$(jq -r '.issue_number'   <<<"$CTX")"
assert_eq "review_comments_count=0"        "0"              "$(jq -r '.signals.review_comments_count' <<<"$CTX")"
assert_eq "post_bot_commits=4"             "4"              "$(jq -r '.signals.post_bot_commits'      <<<"$CTX")"
assert_eq "ci_failures=1"                  "1"              "$(jq -r '.signals.ci_failures_during_pr' <<<"$CTX")"
assert_eq "workpad_final_status=Complete"  "Complete"       "$(jq -r '.signals.workpad_final_status'  <<<"$CTX")"
assert_eq "review_reject_outstanding=true" "true"           "$(jq -r '.signals.review_reject_outstanding' <<<"$CTX")"
OUTC="$(DEVFLOW_GH="$GH_STUB" DEVFLOW_FIXTURE_PR=CLEAN bash "$LIB/fetch-pr-context.sh" 4242)"
CTXC="$(cat "$OUTC")"
assert_eq "clean: reject_outstanding=false" "false" "$(jq -r '.signals.review_reject_outstanding' <<<"$CTXC")"
assert_eq "clean: post_bot_commits=0"       "0"     "$(jq -r '.signals.post_bot_commits'      <<<"$CTXC")"
assert_eq "clean: ci_failures=0"            "0"     "$(jq -r '.signals.ci_failures_during_pr' <<<"$CTXC")"
assert_eq "ci_status_unknown=false (793 fixture)"   "false" "$(jq -r '.signals.ci_status_unknown' <<<"$CTX")"
assert_eq "ci_status_unknown=false (CLEAN fixture)"  "false" "$(jq -r '.signals.ci_status_unknown' <<<"$CTXC")"
# Fix 2: diff field must be a non-null string when the fixture has content
assert_eq "diff is a non-empty string" "string" "$(jq -r '.diff | type' <<<"$CTX")"
assert_eq "diff not null"              "false"  "$(jq -r '.diff == null' <<<"$CTX")"

# #1: post_bot_commits / human_postbot SHA list count only *substantive* (non-merge)
# commits after the bot's last commit. A `git merge main` by a human (parents>1)
# is branch hygiene, not a fixup, and must not be counted.
_postbot_count() {  # stdin: COMMITS-shaped array; arg1: PR-author login
  jq --arg author "$1" '
    to_entries
    | [.[] | select(
        (.value.author_login | endswith("[bot]"))
        or (.value.committer_login | endswith("[bot]"))
        or (.value.author_login == $author)
        or (.value.committer_login == $author)
      ) | .key
    ] as $bot
    | if ($bot | length) == 0 then 0
      else ([.[($bot | last) + 1:][] | select((.value.parents_count // 1) <= 1)] | length)
      end'
}
assert_eq "post_bot: merge commit excluded, real fixup counted" "1" \
  "$(echo '[{"author_login":"claude[bot]","committer_login":"web-flow","parents_count":1},{"author_login":"alice","committer_login":"alice","parents_count":2},{"author_login":"alice","committer_login":"alice","parents_count":1}]' | _postbot_count someoneelse)"
assert_eq "post_bot: only a human merge after the bot → 0" "0" \
  "$(echo '[{"author_login":"claude[bot]","committer_login":"web-flow","parents_count":1},{"author_login":"alice","committer_login":"alice","parents_count":2}]' | _postbot_count someoneelse)"
assert_eq "post_bot: missing parents_count treated as non-merge (counted)" "1" \
  "$(echo '[{"author_login":"claude[bot]","committer_login":"web-flow"},{"author_login":"alice","committer_login":"alice"}]' | _postbot_count someoneelse)"

# #4: the /review verdict parser must recognize BOTH the standalone `/review`
# report heading (`## Verdict: APPROVE (…)`) and the CI `@claude run /review`
# wrapper heading (`### /review — Verdict: **REJECT**`), and must NOT fire on a
# prose mention of the word "verdict".
_vparse() {
  jq -r '
    [ .[] | . as $c | (.body//"") | split("\n")[] | rtrimstr("\r")
      | select(test("^#{1,6}[ \t]*(/review[ \t]*[—–-]+[ \t]*)?Verdict:[ \t]*\\**[ \t]*(APPROVE|REJECT)"; "i"))
      | capture("Verdict:[ \t]*\\**[ \t]*(?<verdict>APPROVE|REJECT)"; "i")
      | {verdict:(.verdict|ascii_upcase), createdAt:$c.created_at} ]
    | (.[-1].verdict // "NONE")'
}
assert_eq "verdict parser: CI wrapper format" "REJECT" \
  "$(echo '[{"body":"**Claude finished** ——\n\n---\n### /review — Verdict: **REJECT**\n\nblah","created_at":"2026-01-01T00:00:00Z"}]' | _vparse)"
assert_eq "verdict parser: standalone format" "APPROVE" \
  "$(echo '[{"body":"# Review Report\n\n## Verdict: APPROVE (looks good)\n","created_at":"2026-01-02T00:00:00Z"}]' | _vparse)"
assert_eq "verdict parser: APPROVE WITH CAVEAT → APPROVE" "APPROVE" \
  "$(echo '[{"body":"## Verdict: APPROVE WITH CAVEAT — checklist not generated\n","created_at":"2026-01-03T00:00:00Z"}]' | _vparse)"
assert_eq "verdict parser: prose mention ignored" "NONE" \
  "$(echo '[{"body":"I think the verdict: REJECT was harsh.","created_at":"2026-01-04T00:00:00Z"}]' | _vparse)"

# #5: fetch-pr-context elides generated/vendored file bodies from the embedded
# diff but keeps every path in changed_files.
_DIFF_SAMPLE='diff --git a/src/Foo.php b/src/Foo.php
@@ -1 +1 @@
-x
+y
diff --git a/package-lock.json b/package-lock.json
@@ -1,9 +1,9 @@
- noise
+ noise
diff --git a/jsx/dist/app.min.js b/jsx/dist/app.min.js
@@ -1 +1 @@
-a
+b'
_DIFF_TRIMMED="$(printf '%s' "$_DIFF_SAMPLE" | python3 -c '
import sys, re
diff = sys.stdin.read()
noise = re.compile(r"(^|/)(package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|composer\.lock|Gemfile\.lock|poetry\.lock|Cargo\.lock|go\.sum)$|\.min\.(js|css|mjs)$|\.map$|(^|/)(node_modules|vendor|dist|build)/")
out, elide = [], False
for line in diff.split("\n"):
    if line.startswith("diff --git "):
        parts = line.split(" ", 3)
        path = parts[2][2:] if len(parts) > 2 and parts[2].startswith("a/") else ""
        elide = bool(path and noise.search(path))
        if elide:
            out.append(line); out.append("[elided: %s]" % path); continue
    if not elide: out.append(line)
sys.stdout.write("\n".join(out))
')"
assert_eq "diff trim: real source kept"       "true"  "$(printf '%s' "$_DIFF_TRIMMED" | grep -qx -- '+y' && echo true || echo false)"
assert_eq "diff trim: lockfile body elided"   "true"  "$(printf '%s' "$_DIFF_TRIMMED" | grep -q '\[elided: package-lock.json\]' && echo true || echo false)"
assert_eq "diff trim: lockfile noise removed"  "false" "$(printf '%s' "$_DIFF_TRIMMED" | grep -q -- '- noise' && echo true || echo false)"
assert_eq "diff trim: minified bundle elided"  "true"  "$(printf '%s' "$_DIFF_TRIMMED" | grep -q '\[elided: jsx/dist/app.min.js\]' && echo true || echo false)"

# ────────────────────────────────────────────────────────────────────────────
echo "cheap-gate.jq"
# ────────────────────────────────────────────────────────────────────────────
gate() { jq -c -f "$LIB/cheap-gate.jq"; }
BASE='{"signals":{"review_comments_count":0,"post_bot_commits":0,"ci_failures_during_pr":0,"ci_status_unknown":false,"workpad_final_status":"Complete","review_reject_outstanding":false}}'
assert_eq "all clean → clean=true"            "true"  "$(echo "$BASE" | gate | jq -r .clean)"
assert_eq "reject outstanding → clean=false"  "false" "$(echo "$BASE" | jq '.signals.review_reject_outstanding=true' | gate | jq -r .clean)"
assert_eq "ci failure → clean=false"          "false" "$(echo "$BASE" | jq '.signals.ci_failures_during_pr=1' | gate | jq -r .clean)"
assert_eq "ci_status_unknown=true → clean=false" "false" "$(echo "$BASE" | jq '.signals.ci_status_unknown=true' | gate | jq -r .clean)"
assert_eq "ci_status_unknown=true reason"     "CI status could not be read" "$(echo "$BASE" | jq '.signals.ci_status_unknown=true' | gate | jq -r .reason)"
assert_eq "human commit → clean=false"        "false" "$(echo "$BASE" | jq '.signals.post_bot_commits=2' | gate | jq -r .clean)"
assert_eq "review comment → clean=false"      "false" "$(echo "$BASE" | jq '.signals.review_comments_count=1' | gate | jq -r .clean)"
assert_eq "workpad Blocked → clean=false"     "false" "$(echo "$BASE" | jq '.signals.workpad_final_status="Blocked"' | gate | jq -r .clean)"
assert_eq "workpad empty string → clean=true" "true"  "$(echo "$BASE" | jq '.signals.workpad_final_status=""' | gate | jq -r .clean)"
assert_eq "workpad null → clean=true"         "true"  "$(echo "$BASE" | jq '.signals.workpad_final_status=null' | gate | jq -r .clean)"

# ────────────────────────────────────────────────────────────────────────────
echo "issue #97: reserved DevFlow label + issue-workpad reflection ingestion"
# ────────────────────────────────────────────────────────────────────────────

# ── ensure-label.sh: REST create, idempotent, always exit 0 (best-effort) ────
# The helper now creates via `gh api --method POST repos/{owner}/{repo}/labels`
# (repo-scope only) rather than `gh label create` (org-scoped GraphQL). The stub
# matches the REST POST: first call succeeds (created); a marker makes the second
# report HTTP 422 / already_exists (the REST already-exists shape); a separate
# stub forces a hard failure. Each run still exits 0 with its own breadcrumb.
EL_TMP="$(mktemp -d)"
cat > "$EL_TMP/gh" <<'STUB'
#!/usr/bin/env bash
# Record argv so the test can assert the REST endpoint + fields are targeted.
printf '%s' "$*" > "$(dirname "$0")/create-args"
MARK="$(dirname "$0")/.created"
case "$*" in
  *"--method POST"*"/labels"*)
    if [ -f "$MARK" ]; then echo '{"message":"Validation Failed","errors":[{"resource":"Label","code":"already_exists","field":"name"}],"status":"422"}' >&2; echo "gh: Validation Failed (HTTP 422)" >&2; exit 1; fi
    touch "$MARK"; echo '{}'; exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$EL_TMP/gh"
EL_E1="$(DEVFLOW_GH="$EL_TMP/gh" bash "$LIB/../scripts/ensure-label.sh" DevFlow 2>&1 >/dev/null)"; EL_R1=$?
EL_E2="$(DEVFLOW_GH="$EL_TMP/gh" bash "$LIB/../scripts/ensure-label.sh" DevFlow 2>&1 >/dev/null)"; EL_R2=$?
assert_eq "ensure-label: first run exits 0 (created)"            "0" "$EL_R1"
assert_eq "ensure-label: second run exits 0 (already exists)"    "0" "$EL_R2"
assert_eq "ensure-label: targets REST POST repos/{owner}/{repo}/labels (not gh label create)" "yes" \
  "$(grep -qF -- 'api --method POST repos/{owner}/{repo}/labels' "$EL_TMP/create-args" && echo yes || echo no)"
assert_eq "ensure-label: passes the label name as a -f field" "yes" \
  "$(grep -qF -- 'name=DevFlow' "$EL_TMP/create-args" && echo yes || echo no)"
assert_eq "ensure-label: passes the description as a -f field" "yes" \
  "$(grep -qF -- 'description=Created by DevFlow automation' "$EL_TMP/create-args" && echo yes || echo no)"
assert_eq "ensure-label: first run breadcrumb says created" "yes" \
  "$(printf '%s' "$EL_E1" | grep -qiF 'created label' && echo yes || echo no)"
assert_eq "ensure-label: second run breadcrumb says already exists (HTTP 422)" "yes" \
  "$(printf '%s' "$EL_E2" | grep -qiF 'already exists' && echo yes || echo no)"
cat > "$EL_TMP/ghfail" <<'STUB'
#!/usr/bin/env bash
echo "HTTP 500: server error" >&2; exit 1
STUB
chmod +x "$EL_TMP/ghfail"
EL_E3="$(DEVFLOW_GH="$EL_TMP/ghfail" bash "$LIB/../scripts/ensure-label.sh" DevFlow 2>&1 >/dev/null)"; EL_R3=$?
assert_eq "ensure-label: hard gh failure still exits 0 (best-effort)" "0" "$EL_R3"
assert_eq "ensure-label: hard-failure breadcrumb names the failure" "yes" \
  "$(printf '%s' "$EL_E3" | grep -qiF 'could not ensure label' && echo yes || echo no)"
# A 422 for a DIFFERENT validation reason (no `already_exists` code) must NOT be
# swallowed as "already exists" — it routes to the failure breadcrumb. Guards the
# /simplify narrowing that dropped the over-broad bare `HTTP 422` match.
cat > "$EL_TMP/gh422" <<'STUB'
#!/usr/bin/env bash
echo '{"message":"Validation Failed","errors":[{"resource":"Label","code":"invalid","field":"name"}],"status":"422"}' >&2
echo "gh: Validation Failed (HTTP 422)" >&2; exit 1
STUB
chmod +x "$EL_TMP/gh422"
EL_E4="$(DEVFLOW_GH="$EL_TMP/gh422" bash "$LIB/../scripts/ensure-label.sh" DevFlow 2>&1 >/dev/null)"; EL_R4=$?
assert_eq "ensure-label: non-already_exists 422 still exits 0 (best-effort)" "0" "$EL_R4"
assert_eq "ensure-label: non-already_exists 422 is NOT swallowed as already-exists" "yes" \
  "$(printf '%s' "$EL_E4" | grep -qiF 'could not ensure label' && ! printf '%s' "$EL_E4" | grep -qiF 'already exists' && echo yes || echo no)"
rm -rf "$EL_TMP"

# ── apply-labels.sh: REST label-apply helper (best-effort, always exit 0) ─────
# Applies via POST repos/{owner}/{repo}/issues/{n}/labels (repo-scope only). The
# stub records argv so we can assert the endpoint + labels[] fields; a failing
# stub proves the best-effort exit-0 + breadcrumb contract; an empty label set
# proves no POST is made.
AL_TMP="$(mktemp -d)"
cat > "$AL_TMP/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s' "$*" >> "$(dirname "$0")/apply-args"
echo '[]'; exit 0
STUB
chmod +x "$AL_TMP/gh"
: > "$AL_TMP/apply-args"
DEVFLOW_GH="$AL_TMP/gh" bash "$LIB/../scripts/apply-labels.sh" 42 DevFlow >/dev/null 2>&1; AL_R1=$?
assert_eq "apply-labels: exits 0 on success" "0" "$AL_R1"
assert_eq "apply-labels: targets REST POST issues/{n}/labels (not gh issue/pr edit)" "yes" \
  "$(grep -qF -- 'api --method POST repos/{owner}/{repo}/issues/42/labels' "$AL_TMP/apply-args" && echo yes || echo no)"
assert_eq "apply-labels: single label rides as a labels[] field" "yes" \
  "$(grep -qF -- 'labels[]=DevFlow' "$AL_TMP/apply-args" && echo yes || echo no)"
assert_eq "apply-labels: never falls back to gh issue/pr edit porcelain" "yes" \
  "$(grep -qF -- 'issue edit' "$AL_TMP/apply-args" || grep -qF -- 'pr edit' "$AL_TMP/apply-args" ; [ $? -ne 0 ] && echo yes || echo no)"
# Multi-label (separate args) and comma-separated single arg both expand every label.
: > "$AL_TMP/apply-args"
DEVFLOW_GH="$AL_TMP/gh" bash "$LIB/../scripts/apply-labels.sh" 42 DevFlow Retrospective >/dev/null 2>&1
assert_eq "apply-labels: multi-arg applies every label (DevFlow)" "yes" \
  "$(grep -qF -- 'labels[]=DevFlow' "$AL_TMP/apply-args" && echo yes || echo no)"
assert_eq "apply-labels: multi-arg applies every label (Retrospective)" "yes" \
  "$(grep -qF -- 'labels[]=Retrospective' "$AL_TMP/apply-args" && echo yes || echo no)"
: > "$AL_TMP/apply-args"
DEVFLOW_GH="$AL_TMP/gh" bash "$LIB/../scripts/apply-labels.sh" 42 "DevFlow,Deferred" >/dev/null 2>&1
assert_eq "apply-labels: comma-separated arg splits into every label (DevFlow)" "yes" \
  "$(grep -qF -- 'labels[]=DevFlow' "$AL_TMP/apply-args" && echo yes || echo no)"
assert_eq "apply-labels: comma-separated arg splits into every label (Deferred)" "yes" \
  "$(grep -qF -- 'labels[]=Deferred' "$AL_TMP/apply-args" && echo yes || echo no)"
# Empty / whitespace-only label set → no POST at all.
: > "$AL_TMP/apply-args"
DEVFLOW_GH="$AL_TMP/gh" bash "$LIB/../scripts/apply-labels.sh" 42 "   " >/dev/null 2>&1; AL_RE=$?
assert_eq "apply-labels: whitespace-only label set exits 0" "0" "$AL_RE"
assert_eq "apply-labels: whitespace-only label set makes no POST" "yes" \
  "$([ ! -s "$AL_TMP/apply-args" ] && echo yes || echo no)"
# Label value with a space/metachar rides as ONE literal labels[] field (no word-split,
# no shell expansion) — proves the "passed literally" contract the helper comment promises.
: > "$AL_TMP/apply-args"
DEVFLOW_GH="$AL_TMP/gh" bash "$LIB/../scripts/apply-labels.sh" 42 "needs review" >/dev/null 2>&1
assert_eq "apply-labels: a space-containing label is one literal labels[] field (no word-split)" "yes" \
  "$(grep -qF -- 'labels[]=needs review' "$AL_TMP/apply-args" && echo yes || echo no)"
# Best-effort: a failing gh still exits 0 and leaves a specific breadcrumb. The failure
# stub RECORDS its argv so "no porcelain fallback" is proven on the FAILURE path too — a
# future `|| gh issue edit …` retry on the RC≠0 branch would land here and trip the pin.
cat > "$AL_TMP/ghfail" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/fail-args"
echo "HTTP 500: server error" >&2; exit 1
STUB
chmod +x "$AL_TMP/ghfail"
: > "$AL_TMP/fail-args"
AL_EF="$(DEVFLOW_GH="$AL_TMP/ghfail" bash "$LIB/../scripts/apply-labels.sh" 42 DevFlow 2>&1 >/dev/null)"; AL_RF=$?
assert_eq "apply-labels: hard gh failure still exits 0 (best-effort)" "0" "$AL_RF"
assert_eq "apply-labels: failure breadcrumb names the target and label(s)" "yes" \
  "$(printf '%s' "$AL_EF" | grep -qF '#42' && printf '%s' "$AL_EF" | grep -qF 'DevFlow' && echo yes || echo no)"
assert_eq "apply-labels: no porcelain fallback on the FAILURE path (no gh issue/pr edit retry)" "yes" \
  "$(! grep -qE 'issue edit|pr edit' "$AL_TMP/fail-args" && echo yes || echo no)"
rm -rf "$AL_TMP"

# ── scan.sh: union detection predicate (label / closes-issue / audit / prefix) ─
S97="$(mktemp -d)"
cat > "$S97/cfg.json" <<'CFG'
{"devflow":{"allowed_bots":"claude"},"devflow_retrospective":{"watched_authors":["claude"],"implementation_branch_prefix":"claude/"}}
CFG
cat > "$S97/cfg-noprefix.json" <<'CFG'
{"devflow":{"allowed_bots":"claude"},"devflow_retrospective":{"watched_authors":["claude"],"implementation_branch_prefix":""}}
CFG

# (a) label path is author- AND branch-agnostic
cat > "$S97/gh-label" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"repo view"*) echo "acme/example-repo" ;;
  *"pr list"*"--label DevFlow"*) echo '[{"number":777,"headRefName":"random/whatever","mergedAt":"2026-05-20T00:00:00Z"}]' ;;
  *"pr list"*"author:"*) echo '[]' ;;
  *"pr list"*) echo '[]' ;;
  *"api"*"retrospectives.jsonl?ref=main"*) printf 'HTTP/2.0 404 Not Found\r\n\r\n' ;;
  *) echo '[]' ;;
esac
STUB
chmod +x "$S97/gh-label"
SCAN_L="$(DEVFLOW_CONFIG_FILE="$S97/cfg.json" DEVFLOW_GH="$S97/gh-label" bash "$LIB/scan.sh" 2>/dev/null)"
assert_eq "scan #97: DevFlow-label PR selected (author/branch-agnostic)" "true" \
  "$(echo "$SCAN_L" | jq 'any(.[]; .number==777)')"

# (b) closes-issue fallback with NO prefix and NO label (guarantee-class) + true negative
cat > "$S97/gh-closes" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"repo view"*) echo "acme/example-repo" ;;
  *"pr list"*"--label DevFlow"*) echo '[]' ;;
  *"pr list"*"author:"*) echo '[{"number":61,"headRefName":"issue-61-x","author":{"login":"claude"},"mergedAt":"2026-05-21T00:00:00Z","labels":[],"closingIssuesReferences":[{"number":60}]},{"number":99,"headRefName":"feature/hand","author":{"login":"claude"},"mergedAt":"2026-05-21T00:00:00Z","labels":[],"closingIssuesReferences":[]}]' ;;
  *"pr list"*) echo '[]' ;;
  *"api"*"retrospectives.jsonl?ref=main"*) printf 'HTTP/2.0 404 Not Found\r\n\r\n' ;;
  *) echo '[]' ;;
esac
STUB
chmod +x "$S97/gh-closes"
SCAN_B="$(DEVFLOW_CONFIG_FILE="$S97/cfg-noprefix.json" DEVFLOW_GH="$S97/gh-closes" bash "$LIB/scan.sh" 2>/dev/null)"
assert_eq "scan #97: closes-issue path selects PR on issue-* with empty prefix/no label" "true" \
  "$(echo "$SCAN_B" | jq 'any(.[]; .number==61)')"
assert_eq "scan #97: true negative (no label/closes/audit/prefix) excluded; empty prefix ≠ match-all" "false" \
  "$(echo "$SCAN_B" | jq 'any(.[]; .number==99)')"

# (d) dedupe: a PR matching BOTH label and closes paths appears once
cat > "$S97/gh-dedupe" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"repo view"*) echo "acme/example-repo" ;;
  *"pr list"*"--label DevFlow"*) echo '[{"number":55,"headRefName":"issue-55-x","mergedAt":"2026-05-22T00:00:00Z"}]' ;;
  *"pr list"*"author:"*) echo '[{"number":55,"headRefName":"issue-55-x","author":{"login":"claude"},"mergedAt":"2026-05-22T00:00:00Z","labels":[{"name":"DevFlow"}],"closingIssuesReferences":[{"number":54}]}]' ;;
  *"pr list"*) echo '[]' ;;
  *"api"*"retrospectives.jsonl?ref=main"*) printf 'HTTP/2.0 404 Not Found\r\n\r\n' ;;
  *) echo '[]' ;;
esac
STUB
chmod +x "$S97/gh-dedupe"
SCAN_D="$(DEVFLOW_CONFIG_FILE="$S97/cfg.json" DEVFLOW_GH="$S97/gh-dedupe" bash "$LIB/scan.sh" 2>/dev/null)"
assert_eq "scan #97: PR matching both label+closes appears once (dedupe)" "1" \
  "$(echo "$SCAN_D" | jq '[.[] | select(.number==55)] | length')"

# the 6 existing bot PRs are selected via path (b) with no prefix and no backfill
cat > "$S97/gh-six" <<'STUB'
#!/usr/bin/env bash
SIX='[{"number":62,"headRefName":"issue-62-a","author":{"login":"claude"},"mergedAt":"2026-05-01T00:00:00Z","labels":[],"closingIssuesReferences":[{"number":162}]},
      {"number":64,"headRefName":"issue-64-b","author":{"login":"claude"},"mergedAt":"2026-05-02T00:00:00Z","labels":[],"closingIssuesReferences":[{"number":164}]},
      {"number":71,"headRefName":"issue-71-c","author":{"login":"claude"},"mergedAt":"2026-05-03T00:00:00Z","labels":[],"closingIssuesReferences":[{"number":171}]},
      {"number":72,"headRefName":"issue-72-d","author":{"login":"claude"},"mergedAt":"2026-05-04T00:00:00Z","labels":[],"closingIssuesReferences":[{"number":172}]},
      {"number":73,"headRefName":"issue-73-e","author":{"login":"claude"},"mergedAt":"2026-05-05T00:00:00Z","labels":[],"closingIssuesReferences":[{"number":173}]},
      {"number":87,"headRefName":"issue-87-f","author":{"login":"claude"},"mergedAt":"2026-05-06T00:00:00Z","labels":[],"closingIssuesReferences":[{"number":187}]}]'
case "$*" in
  *"repo view"*) echo "acme/example-repo" ;;
  *"pr list"*"--label DevFlow"*) echo '[]' ;;
  *"pr list"*"author:"*) echo "$SIX" ;;
  *"pr list"*) echo '[]' ;;
  *"api"*"retrospectives.jsonl?ref=main"*) printf 'HTTP/2.0 404 Not Found\r\n\r\n' ;;
  *) echo '[]' ;;
esac
STUB
chmod +x "$S97/gh-six"
SCAN_SIX="$(DEVFLOW_CONFIG_FILE="$S97/cfg-noprefix.json" DEVFLOW_GH="$S97/gh-six" bash "$LIB/scan.sh" 2>/dev/null)"
assert_eq "scan #97: the 6 bot PRs selected via closes-issue path (no prefix, no backfill)" "62 64 71 72 73 87" \
  "$(echo "$SCAN_SIX" | jq -r '[.[].number] | sort | join(" ")')"

# Empty watched-authors list: the label pass still runs and must NOT early-exit
# to '[]' — the no-op-prevention guarantee. (Guards a regression that restored
# the old `[ -z "$WATCHED" ] → echo '[]'; exit 0`.)
cat > "$S97/cfg-nowatched.json" <<'CFG'
{"devflow":{"allowed_bots":""},"devflow_retrospective":{"watched_authors":[],"implementation_branch_prefix":"claude/"}}
CFG
SCAN_NW="$(DEVFLOW_CONFIG_FILE="$S97/cfg-nowatched.json" DEVFLOW_GH="$S97/gh-label" bash "$LIB/scan.sh" 2>/dev/null)"
assert_eq "scan #97: label pass runs with empty watched-authors (no silent no-op)" "true" \
  "$(echo "$SCAN_NW" | jq 'any(.[]; .number==777)')"

# --prs ad-hoc mode applies the union predicate too: a DevFlow-labelled PR on a
# non-prefix branch (no closes) is selected; a true-negative is dropped.
cat > "$S97/gh-prs" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"repo view"*) echo "acme/example-repo" ;;
  *"pr view 800 --repo"*) echo '{"number":800,"headRefName":"random/x","mergedAt":"2026-05-25T00:00:00Z","state":"MERGED","labels":[{"name":"DevFlow"}],"closingIssuesReferences":[],"author":{"login":"nonwatched"}}' ;;
  *"pr view 801 --repo"*) echo '{"number":801,"headRefName":"feature/plain","mergedAt":"2026-05-26T00:00:00Z","state":"MERGED","labels":[],"closingIssuesReferences":[],"author":{"login":"nonwatched"}}' ;;
  *"pr view 802 --repo"*) echo '{"number":802,"headRefName":"issue-802-x","mergedAt":"2026-05-27T00:00:00Z","state":"MERGED","labels":[],"closingIssuesReferences":[{"number":702}],"author":{"login":"claude"}}' ;;
  *"pr view 803 --repo"*) echo '{"number":803,"headRefName":"issue-803-x","mergedAt":"2026-05-28T00:00:00Z","state":"MERGED","labels":[],"closingIssuesReferences":[{"number":703}],"author":{"login":"nonwatched"}}' ;;
  *) echo '[]' ;;
esac
STUB
chmod +x "$S97/gh-prs"
PRS97="$(DEVFLOW_CONFIG_FILE="$S97/cfg.json" DEVFLOW_GH="$S97/gh-prs" bash "$LIB/scan.sh" --prs "800,801,802,803" 2>/dev/null)"
assert_eq "scan #97 --prs: DevFlow-labelled PR on non-prefix branch selected" "true" \
  "$(echo "$PRS97" | jq 'any(.[]; .number==800)')"
assert_eq "scan #97 --prs: true-negative (no label/closes/prefix) dropped" "false" \
  "$(echo "$PRS97" | jq 'any(.[]; .number==801)')"
# --prs closes-issue path is author-gated by _author_is_watched: a WATCHED
# author that closes an issue (no label/prefix) is selected; a non-watched
# author with the same closes-only shape is dropped.
assert_eq "scan #97 --prs: watched-author closes-issue on non-prefix branch selected" "true" \
  "$(echo "$PRS97" | jq 'any(.[]; .number==802)')"
assert_eq "scan #97 --prs: non-watched closes-only dropped (path b is author-gated)" "false" \
  "$(echo "$PRS97" | jq 'any(.[]; .number==803)')"
rm -rf "$S97"

# ── fetch-pr-context.sh: workpad + reflections sourced from the ISSUE thread ──
F97="$(mktemp -d)"
cat > "$F97/prview.json" <<'PV'
{"number":900,"headRefName":"claude/issue-901-x","baseRefName":"main","headRefOid":"sha900beef","mergeCommit":{"oid":"merge900"},"mergedAt":"2026-05-08T16:31:00Z","createdAt":"2026-05-08T07:00:00Z","author":{"login":"example-bot"},"title":"t","body":"Closes #901","additions":1,"deletions":0,"files":[{"path":"x.txt"}],"labels":[]}
PV
cat > "$F97/issue.json" <<'IJ'
{"number":901,"title":"i","body":"b","labels":[],"comments":[]}
IJ
# Stub distinguishes the ISSUE thread (issues/901/comments — workpad lives here)
# from the PR thread (issues/900/comments — empty). Reads whatever
# issuecomments.json currently holds so scenarios can be swapped in place.
cat > "$F97/gh" <<'STUB'
#!/usr/bin/env bash
FX="${DEVFLOW_FX}"
case "$*" in
  *"repo view"*) echo "acme/example-repo" ;;
  *"pr view"*) cat "$FX/prview.json" ;;
  *"pr diff"*) echo 'diff --git a/x.txt b/x.txt' ;;
  *"pulls/"*"/comments"*) echo '[]' ;;
  *"pulls/"*"/reviews"*) echo '[]' ;;
  *"pulls/"*"/commits"*) echo '[]' ;;
  *"check-runs"*) echo '{"check_runs":[]}' ;;
  *"issues/901/comments"*) cat "$FX/issuecomments.json" ;;
  *"issues/900/comments"*) echo '[]' ;;
  *"issues/"*"/comments"*) echo '[]' ;;
  *"issues/901"*) cat "$FX/issue.json" ;;
  *"commits/"*) echo '{"files":[]}' ;;
  *) echo '[]' ;;
esac
STUB
chmod +x "$F97/gh"

# Scenario 1: Status 🎉 Complete + two reflection bullets (one with backticks/$).
cat > "$F97/workpad.md" <<'WPMD'
<!-- devflow:workpad -->
# DevFlow Workpad — Issue #901

**Status:** 🎉 Complete

## Progress
- [x] **Setup**

## Devflow Reflection
<details>
<summary>Devflow Reflection (click to expand)</summary>

- permission classifier blocked `bash lib/test/run.sh` ($CLAUDE_CODE classifier denied local test exec)
- scope narrowed: deferred part X to a follow-up
</details>
WPMD
jq -Rs '[{user:{login:"example-bot"},body:.,created_at:"2026-05-08T10:00:00Z"}]' < "$F97/workpad.md" > "$F97/issuecomments.json"
F_OUT="$(DEVFLOW_FX="$F97" DEVFLOW_GH="$F97/gh" bash "$LIB/fetch-pr-context.sh" 900 2>/dev/null)"
F_CTX="$(cat "$F_OUT")"
assert_eq "fetch #97: workpad_final_status sourced from ISSUE, glyph stripped → Complete" "Complete" \
  "$(jq -r '.signals.workpad_final_status' <<<"$F_CTX")"
assert_eq "fetch #97: reflections[] has the two bullets" "2" \
  "$(jq '.reflections | length' <<<"$F_CTX")"
EXP_REFL='permission classifier blocked `bash lib/test/run.sh` ($CLAUDE_CODE classifier denied local test exec)'
assert_eq "fetch #97: reflection bullet byte-for-byte (backticks/\$ survive)" "$EXP_REFL" \
  "$(jq -r '.reflections[0]' <<<"$F_CTX")"

# Scenario 2: empty Devflow Reflection block → reflections == []
cat > "$F97/workpad-empty.md" <<'WPMD'
<!-- devflow:workpad -->
# DevFlow Workpad — Issue #901
**Status:** 🚀 Implementing
## Devflow Reflection
<details>
<summary>Devflow Reflection (click to expand)</summary>

</details>
WPMD
jq -Rs '[{user:{login:"example-bot"},body:.,created_at:"2026-05-08T10:00:00Z"}]' < "$F97/workpad-empty.md" > "$F97/issuecomments.json"
F_OUT2="$(DEVFLOW_FX="$F97" DEVFLOW_GH="$F97/gh" bash "$LIB/fetch-pr-context.sh" 900 2>/dev/null)"
assert_eq "fetch #97: empty reflection block → reflections == []" "0" \
  "$(jq '.reflections | length' < "$F_OUT2")"

# Scenario 3: malformed block (no closing </details>) degrades without detonating
cat > "$F97/workpad-malformed.md" <<'WPMD'
<!-- devflow:workpad -->
**Status:** 🚀 Reviewing
## Devflow Reflection
<details>
<summary>Devflow Reflection (click to expand)</summary>

- a malformed-block bullet
WPMD
jq -Rs '[{user:{login:"example-bot"},body:.,created_at:"2026-05-08T10:00:00Z"}]' < "$F97/workpad-malformed.md" > "$F97/issuecomments.json"
F_OUT3="$(DEVFLOW_FX="$F97" DEVFLOW_GH="$F97/gh" bash "$LIB/fetch-pr-context.sh" 900 2>/dev/null)"; F_RC3=$?
assert_eq "fetch #97: malformed reflection block exits 0 (no detonation)" "0" "$F_RC3"
assert_eq "fetch #97: malformed reflection block degrades to a valid array" "array" \
  "$(jq -r '.reflections | type' < "$F_OUT3")"

# Scenario 4: Blocked workpad (from issue) → end-to-end gate clean=false (signal live)
cat > "$F97/workpad-blocked.md" <<'WPMD'
<!-- devflow:workpad -->
**Status:** 👎 Blocked
## Devflow Reflection
<details>
<summary>Devflow Reflection (click to expand)</summary>

</details>
WPMD
jq -Rs '[{user:{login:"example-bot"},body:.,created_at:"2026-05-08T10:00:00Z"}]' < "$F97/workpad-blocked.md" > "$F97/issuecomments.json"
F_OUT4="$(DEVFLOW_FX="$F97" DEVFLOW_GH="$F97/gh" bash "$LIB/fetch-pr-context.sh" 900 2>/dev/null)"
assert_eq "fetch #97: Blocked status sourced from ISSUE → Blocked" "Blocked" \
  "$(jq -r '.signals.workpad_final_status' < "$F_OUT4")"
assert_eq "gate #97: Blocked workpad (from issue) → clean=false (signal live again)" "false" \
  "$(jq -c -f "$LIB/cheap-gate.jq" < "$F_OUT4" | jq -r .clean)"

# Scenario 5 (#103 S-1): the status strip removes the leading workpad glyph by the
# known glyph SET (🚀/🎉/👎), NOT by taking the last whitespace token. A multi-word
# status must survive intact — the old `awk '{print $NF}'` silently truncated it to
# its final word ("In Progress" → "Progress").
cat > "$F97/workpad-multiword.md" <<'WPMD'
<!-- devflow:workpad -->
**Status:** 🚀 In Progress
## Devflow Reflection
<details>
<summary>Devflow Reflection (click to expand)</summary>

</details>
WPMD
jq -Rs '[{user:{login:"example-bot"},body:.,created_at:"2026-05-08T10:00:00Z"}]' < "$F97/workpad-multiword.md" > "$F97/issuecomments.json"
F_OUT5="$(DEVFLOW_FX="$F97" DEVFLOW_GH="$F97/gh" bash "$LIB/fetch-pr-context.sh" 900 2>/dev/null)"
assert_eq "fetch #103 S-1: multi-word status preserved (glyph-set strip, not last-token)" "In Progress" \
  "$(jq -r '.signals.workpad_final_status' < "$F_OUT5")"
# Single-word glyphed status still strips cleanly (no regression of the common case).
cat > "$F97/workpad-single.md" <<'WPMD'
<!-- devflow:workpad -->
**Status:** 🎉 Complete
## Devflow Reflection
<details>
<summary>Devflow Reflection (click to expand)</summary>

</details>
WPMD
jq -Rs '[{user:{login:"example-bot"},body:.,created_at:"2026-05-08T10:00:00Z"}]' < "$F97/workpad-single.md" > "$F97/issuecomments.json"
F_OUT6="$(DEVFLOW_FX="$F97" DEVFLOW_GH="$F97/gh" bash "$LIB/fetch-pr-context.sh" 900 2>/dev/null)"
assert_eq "fetch #103 S-1: single-word glyphed status still strips to bare word" "Complete" \
  "$(jq -r '.signals.workpad_final_status' < "$F_OUT6")"
# S-1 (review T2): a status with an UNKNOWN leading symbol (not in the glyph set)
# is PRESERVED, not normalized to a clean-looking word. This locks the deliberate
# choice to enumerate the glyph set rather than strip any leading symbol — a
# "simplify to strip any leading non-alnum" regression would turn "? Mystery"
# into "Mystery". The preserved value is not "Complete", so it gates not-clean
# (fail toward analysis).
cat > "$F97/workpad-unknownsym.md" <<'WPMD'
<!-- devflow:workpad -->
**Status:** ? Mystery
## Devflow Reflection
<details>
<summary>Devflow Reflection (click to expand)</summary>

</details>
WPMD
jq -Rs '[{user:{login:"example-bot"},body:.,created_at:"2026-05-08T10:00:00Z"}]' < "$F97/workpad-unknownsym.md" > "$F97/issuecomments.json"
F_OUT7="$(DEVFLOW_FX="$F97" DEVFLOW_GH="$F97/gh" bash "$LIB/fetch-pr-context.sh" 900 2>/dev/null)"
assert_eq "fetch #103 S-1: unknown leading symbol preserved (enumerated set, not strip-any-symbol)" "? Mystery" \
  "$(jq -r '.signals.workpad_final_status' < "$F_OUT7")"
rm -rf "$F97"

# S-1 (review, corroborated x4): the inline glyph set in fetch-pr-context.sh must
# stay in sync with workpad.py's _STATUS_GLYPHS (the single source of truth that
# WRITES the glyph). Same derive-one-side-from-the-other sync-test discipline:
# assert the two glyph sets are equal, so a glyph added to workpad.py without
# updating the strip (which would silently stop stripping it) fails CI.
GLYPH_SYNC="$(python3 - "$LIB/../scripts/workpad.py" "$LIB/fetch-pr-context.sh" <<'PY'
import sys, re
wp = open(sys.argv[1], encoding='utf-8').read()
fpc = open(sys.argv[2], encoding='utf-8').read()
m = re.search(r"_STATUS_GLYPHS\s*=\s*\(([^)]*)\)", wp)
wp_glyphs = set(re.findall(r"'([^']+)'", m.group(1))) if m else set()
m2 = re.search(r"\[\[:space:\]\]\*\(([^)]*)\)\?\[\[:space:\]\]", fpc)
fpc_glyphs = set(m2.group(1).split('|')) if m2 else set()
print('yes' if wp_glyphs and wp_glyphs == fpc_glyphs else 'no')
PY
)"
assert_eq "#103 S-1: fetch-pr-context glyph set stays in sync with workpad.py _STATUS_GLYPHS" "yes" "$GLYPH_SYNC"

# Integration: a PR scan selects via the label/closes-issue path — on an issue-*
# branch matching NO prefix — must NOT be dropped at fetch (classify-pr-kind.jq
# now mirrors scan's union predicate; pre-fix it returned "skip" → exit 2).
FI97="$(mktemp -d)"
cat > "$FI97/prview.json" <<'PV'
{"number":950,"headRefName":"issue-97-foo","baseRefName":"main","headRefOid":"sha950","mergeCommit":{"oid":"m950"},"mergedAt":"2026-05-27T00:00:00Z","createdAt":"2026-05-27T00:00:00Z","author":{"login":"claude[bot]"},"title":"t","body":"Closes #97","additions":1,"deletions":0,"files":[{"path":"x.txt"}],"labels":[{"name":"DevFlow"}],"closingIssuesReferences":[{"number":97}]}
PV
cat > "$FI97/issue.json" <<'IJ'
{"number":97,"title":"i","body":"b","labels":[],"comments":[]}
IJ
cat > "$FI97/gh" <<'STUB'
#!/usr/bin/env bash
FX="${DEVFLOW_FX}"
case "$*" in
  *"repo view"*) echo "acme/example-repo" ;;
  *"pr view"*) cat "$FX/prview.json" ;;
  *"pr diff"*) echo 'diff --git a/x.txt b/x.txt' ;;
  *"pulls/"*"/comments"*) echo '[]' ;;
  *"pulls/"*"/reviews"*) echo '[]' ;;
  *"pulls/"*"/commits"*) echo '[]' ;;
  *"check-runs"*) echo '{"check_runs":[]}' ;;
  *"issues/"*"/comments"*) echo '[]' ;;
  *"issues/97"*) cat "$FX/issue.json" ;;
  *"commits/"*) echo '{"files":[]}' ;;
  *) echo '[]' ;;
esac
STUB
chmod +x "$FI97/gh"
FI_OUT="$(DEVFLOW_FX="$FI97" DEVFLOW_GH="$FI97/gh" bash "$LIB/fetch-pr-context.sh" 950 2>/dev/null)"; FI_RC=$?
assert_eq "fetch #97: label/closes PR on non-prefix branch is NOT skipped (exit 0)" "0" "$FI_RC"
assert_eq "fetch #97: label/closes PR on non-prefix branch → kind=implementation" "implementation" \
  "$([ -n "$FI_OUT" ] && jq -r '.kind' < "$FI_OUT" || echo MISSING)"
rm -rf "$FI97"

# Issue-number derivation falls back to GitHub's own linkage (#98 finding I-1):
# a DevFlow PR on an `issue-<N>-<slug>` branch (NOT `claude/issue-<N>`) whose body
# carries no Closes/Fixes/Resolves keyword — linked only via the UI — is selected
# by the union predicate yet would source an EMPTY workpad without this fallback.
# closingIssuesReferences[0].number must supply the issue number.
FCL="$(mktemp -d)"
cat > "$FCL/prview.json" <<'PV'
{"number":960,"headRefName":"issue-712-foo","baseRefName":"main","headRefOid":"sha960","mergeCommit":{"oid":"m960"},"mergedAt":"2026-05-27T00:00:00Z","createdAt":"2026-05-27T00:00:00Z","author":{"login":"claude[bot]"},"title":"t","body":"no keyword linkage here","additions":1,"deletions":0,"files":[{"path":"x.txt"}],"labels":[{"name":"DevFlow"}],"closingIssuesReferences":[{"number":712}]}
PV
cat > "$FCL/issue.json" <<'IJ'
{"number":712,"title":"i","body":"b","labels":[],"comments":[]}
IJ
cat > "$FCL/gh" <<'STUB'
#!/usr/bin/env bash
FX="${DEVFLOW_FX}"
case "$*" in
  *"repo view"*) echo "acme/example-repo" ;;
  *"pr view"*) cat "$FX/prview.json" ;;
  *"pr diff"*) echo 'diff --git a/x.txt b/x.txt' ;;
  *"pulls/"*"/comments"*) echo '[]' ;;
  *"pulls/"*"/reviews"*) echo '[]' ;;
  *"pulls/"*"/commits"*) echo '[]' ;;
  *"check-runs"*) echo '{"check_runs":[]}' ;;
  *"issues/"*"/comments"*) echo '[]' ;;
  *"issues/712"*) cat "$FX/issue.json" ;;
  *"commits/"*) echo '{"files":[]}' ;;
  *) echo '[]' ;;
esac
STUB
chmod +x "$FCL/gh"
FCL_OUT="$(DEVFLOW_FX="$FCL" DEVFLOW_GH="$FCL/gh" bash "$LIB/fetch-pr-context.sh" 960 2>/dev/null)"
assert_eq "fetch I-1: issue# falls back to closingIssuesReferences when branch+body miss" "712" \
  "$([ -n "$FCL_OUT" ] && jq -r '.issue_number' < "$FCL_OUT" || echo MISSING)"
rm -rf "$FCL"

# ── cheap-gate.jq: a non-empty reflections[] forces analysis even when clean ──
assert_eq "gate #97: reflections non-empty → clean=false (all signals clean)" "false" \
  "$(echo "$BASE" | jq '.reflections=["friction note"]' | gate | jq -r .clean)"
assert_eq "gate #97: reflection reason names the signal" "workpad reflections present" \
  "$(echo "$BASE" | jq '.reflections=["friction note"]' | gate | jq -r .reason)"

# ════════════════════════════════════════════════════════════════════════════
echo "issue #126: --reflection-kind grouped Devflow Reflection rendering"
# ════════════════════════════════════════════════════════════════════════════
# The workpad.py rendering boundary (grouped Markdown from --reflection-kind) is
# exercised exhaustively in lib/test/test_python_scripts.py (it drives
# _apply_mutations directly with exact-Markdown asserts). Here we cover the OTHER
# boundary: lib/fetch-pr-context.sh parse — the grouped shape must parse into
# reflections[] (### sub-headings excluded, terminates at </details>), legacy flat
# blocks parse unchanged, and the gate stays invariant — plus SKILL/docs pins.
WP_PY="$LIB/../scripts/workpad.py"

# ── fetch-pr-context.sh parse + gate invariance ──────────────────────────────
F126="$(mktemp -d)"
cat > "$F126/prview.json" <<'PV'
{"number":900,"headRefName":"claude/issue-901-x","baseRefName":"main","headRefOid":"sha900","mergeCommit":{"oid":"m900"},"mergedAt":"2026-06-01T16:31:00Z","createdAt":"2026-06-01T07:00:00Z","author":{"login":"example-bot"},"title":"t","body":"Closes #901","additions":1,"deletions":0,"files":[{"path":"x.txt"}],"labels":[]}
PV
cat > "$F126/issue.json" <<'IJ'
{"number":901,"title":"i","body":"b","labels":[],"comments":[]}
IJ
cat > "$F126/gh" <<'STUB'
#!/usr/bin/env bash
FX="${DEVFLOW_FX}"
case "$*" in
  *"repo view"*) echo "acme/example-repo" ;;
  *"pr view"*) cat "$FX/prview.json" ;;
  *"pr diff"*) echo 'diff --git a/x.txt b/x.txt' ;;
  *"pulls/"*"/comments"*) echo '[]' ;;
  *"pulls/"*"/reviews"*) echo '[]' ;;
  *"pulls/"*"/commits"*) echo '[]' ;;
  *"check-runs"*) echo '{"check_runs":[]}' ;;
  *"issues/901/comments"*) cat "$FX/issuecomments.json" ;;
  *"issues/900/comments"*) echo '[]' ;;
  *"issues/"*"/comments"*) echo '[]' ;;
  *"issues/901"*) cat "$FX/issue.json" ;;
  *"commits/"*) echo '{"files":[]}' ;;
  *) echo '[]' ;;
esac
STUB
chmod +x "$F126/gh"

# Grouped shape: four kind bullets across two ### sub-sections.
cat > "$F126/workpad-grouped.md" <<'WPMD'
<!-- devflow:workpad -->
# DevFlow Workpad — Issue #901

**Status:** 🎉 Complete

## Progress
- [x] **Setup**

## Devflow Reflection
<details>
<summary>Devflow Reflection (click to expand)</summary>

### ⚠️ Action required
- ⛔ **Blocked:** could not reproduce
- ⏭️ **Deferred:** part X to follow-up
- ❗ **Dropped/Failed:** manifest group dropped

### ℹ️ Notes
- ℹ️ **Note:** subagent retried once
</details>
WPMD
jq -Rs '[{user:{login:"example-bot"},body:.,created_at:"2026-06-01T10:00:00Z"}]' < "$F126/workpad-grouped.md" > "$F126/issuecomments.json"
F126_OUT="$(DEVFLOW_FX="$F126" DEVFLOW_GH="$F126/gh" bash "$LIB/fetch-pr-context.sh" 900 2>/dev/null)"
F126_CTX="$(cat "$F126_OUT")"
assert_eq "#126 fetch: grouped shape → 4 kind bullets captured (### sub-headings excluded)" "4" \
  "$(jq '.reflections | length' <<<"$F126_CTX")"
assert_eq "#126 fetch: no captured reflection is a ### sub-heading" "0" \
  "$(jq -r '.reflections[]' <<<"$F126_CTX" | grep -c '^###')"
assert_eq "#126 fetch: first bullet keeps its glyph+label prefix intact" '⛔ **Blocked:** could not reproduce' \
  "$(jq -r '.reflections[0]' <<<"$F126_CTX")"
assert_eq "#126 gate: grouped shape with ≥1 bullet → clean=false (forces analysis)" "false" \
  "$(jq -c -f "$LIB/cheap-gate.jq" < "$F126_OUT" | jq -r .clean)"

# Legacy flat block (no kind prefix, no ### sub-headings) parses unchanged.
cat > "$F126/workpad-legacy.md" <<'WPMD'
<!-- devflow:workpad -->
# DevFlow Workpad — Issue #901

**Status:** 🎉 Complete

## Devflow Reflection
<details>
<summary>Devflow Reflection (click to expand)</summary>

- a flat legacy bullet
- another flat bullet
</details>
WPMD
jq -Rs '[{user:{login:"example-bot"},body:.,created_at:"2026-06-01T10:00:00Z"}]' < "$F126/workpad-legacy.md" > "$F126/issuecomments.json"
F126_OUT2="$(DEVFLOW_FX="$F126" DEVFLOW_GH="$F126/gh" bash "$LIB/fetch-pr-context.sh" 900 2>/dev/null)"
assert_eq "#126 fetch: legacy flat reflection block → 2 bullets, parsed unchanged" "2" \
  "$(jq '.reflections | length' < "$F126_OUT2")"
assert_eq "#126 gate: legacy flat block with ≥1 bullet → clean=false (gate invariant)" "false" \
  "$(jq -c -f "$LIB/cheap-gate.jq" < "$F126_OUT2" | jq -r .clean)"

# Empty reflection section → reflections == [] → gate stays clean for both shapes.
cat > "$F126/workpad-empty.md" <<'WPMD'
<!-- devflow:workpad -->
# DevFlow Workpad — Issue #901

**Status:** 🎉 Complete

## Devflow Reflection
<details>
<summary>Devflow Reflection (click to expand)</summary>

</details>
WPMD
jq -Rs '[{user:{login:"example-bot"},body:.,created_at:"2026-06-01T10:00:00Z"}]' < "$F126/workpad-empty.md" > "$F126/issuecomments.json"
F126_OUT3="$(DEVFLOW_FX="$F126" DEVFLOW_GH="$F126/gh" bash "$LIB/fetch-pr-context.sh" 900 2>/dev/null)"
assert_eq "#126 gate: empty reflection section → reflections == [] → clean=true" "true" \
  "$(jq -c -f "$LIB/cheap-gate.jq" < "$F126_OUT3" | jq -r .clean)"
rm -rf "$F126"

# SKILL.md call-site pin: every line that uses the executable `--reflection `
# flag must carry a --reflection-kind on that SAME line (the AC: every call-site
# passes the matching kind). Exclude lines that mention the flag without invoking
# it — the markdown doc-table row (content starts with `|`) and prose comment
# lines (content starts with `#`). REFL_UNKINDED holds any offending call-site;
# the assert demands it be empty. This actually enforces the AC — the old
# `--reflection-kind count >= 1` check passed as long as ONE kind appeared
# anywhere, so a new --reflection call-site added without a kind (silently
# degrading to the `note` default) would have slipped through.
# issue #218: grep the BUNDLE, not the thin orchestrator — most --reflection call-sites
# moved into the phase files, so checking SKILL.md alone would silently under-cover
# (this coverage guard would pass vacuously on the call-sites it must police).
REFL_UNKINDED="$(grep -n -- '--reflection ' "$IMPL_SKILL_BUNDLE" \
  | grep -vE '^[0-9]*:[[:space:]]*[|#]' \
  | grep -v -- '--reflection-kind' || true)"
assert_eq "#126 pin: workpad.py documents the --reflection-kind flag" "yes" \
  "$(grep -q -- '--reflection-kind' "$WP_PY" && echo yes || echo no)"
assert_eq "#126 pin: every --reflection call-site in the implement skill carries a --reflection-kind" "" \
  "$REFL_UNKINDED"
assert_eq "#126 pin: docs describe the grouped reflection structure + --reflection-kind" "yes" \
  "$(grep -q -- '--reflection-kind' "$LIB/../docs/implement-skill.md" && grep -q -- '--reflection-kind' "$LIB/../docs/DEVFLOW_SYSTEM_OVERVIEW.md" && echo yes || echo no)"

# ── SKILL.md / config contract pins (grep) ───────────────────────────────────
# ── #242: create-issue clarification step is portable across runners' user-question tools ──
# A1 (AC1–AC4): the clarification step names the runner's user-question tool generically
# (AskUserQuestion as canonical example), makes batching conditional, states a
# runner-neutral total-question budget, and enumerates options in-text when the tool has
# no structured-choice affordance. Removal-proof presence pins (assert_pin_unique fails
# closed if the literal is deleted or paraphrased). Literals are apostrophe-free + unique.
CI_SKILL_242="$LIB/../skills/create-issue/SKILL.md"
CI_OVERVIEW_242="$LIB/../docs/DEVFLOW_SYSTEM_OVERVIEW.md"
assert_pin_unique "#242 A1: create-issue names AskUserQuestion as the canonical example (runner-neutral)" \
  '`AskUserQuestion` (Claude Code, the canonical example)' "$CI_SKILL_242"
assert_pin_unique "#242 A1: create-issue makes batching conditional (one-question-per-call → sequential)" \
  'where it is one-question-per-call, ask them sequentially' "$CI_SKILL_242"
assert_pin_unique "#242 A1: create-issue caps clarification with a runner-neutral total-question budget" \
  'runner-neutral total-clarifying-question budget' "$CI_SKILL_242"
assert_pin_unique "#242 A1: create-issue enumerates options in-text when the tool has no structured choices" \
  'Where the tool cannot present structured choices' "$CI_SKILL_242"
# AC5: both derivation-gate timing anchors reworded off the literal tool while preserving
# gate semantics (fires before the first clarification question AND before Step 3 drafting).
assert_pin_unique "#242 AC5: gate anchor 1 fires before the first clarification question" \
  'Before the first clarification question' "$CI_SKILL_242"
assert_pin_unique "#242 AC5: drafting-precondition anchor references the first-clarification-question trigger" \
  'first-clarification-question trigger' "$CI_SKILL_242"
# AC6: on Claude Code the behavior is unchanged — the positive batching arm (2–4 per call)
# must survive, not just the runner-neutral/sequential wording. Without this, a future edit
# could delete the "2–4 per call" clause (collapsing everything to sequential) and every
# other pin would still pass, silently regressing the Claude-Code-unchanged guarantee.
assert_pin_unique "#242 AC6: Claude-Code path still batches 2–4 questions per call (positive arm)" \
  'batch 2–4 related questions per call' "$CI_SKILL_242"
# AC1 completeness: the other three reworded user-question sites (disengagement push-back,
# truncation warning, Step 4 sub-step 6 implement-offer) also carry removal-proof pins, so a
# partial revert of any one back to a hard-coded AskUserQuestion mandate is caught — without
# these, a revert of just one site passes every other pin, silently regressing AC1.
assert_pin_unique "#242 AC1: disengagement push-back uses the runner's user-question tool" \
  'one batch where it batches, sequentially where it is one-question-per-call' "$CI_SKILL_242"
assert_pin_unique "#242 AC1: truncation warning uses the runner's user-question tool" \
  'or its runner equivalent) to stand in for showing the body' "$CI_SKILL_242"
assert_pin_unique "#242 AC1: Step 4 implement-offer prompt uses the runner's user-question tool" \
  'on Claude Code, as used in Step 2' "$CI_SKILL_242"
# A2 (regression, AC1/AC5/AC6/AC7): the skill no longer MANDATES AskUserQuestion as the
# sole user-question tool, no longer anchors the gate on the literal "AskUserQuestion call",
# and no longer states the round-based "~6 rounds" cap. Absence pins (the literals are GONE).
assert_eq "#242 A2: create-issue dropped the sole-mandate + literal-tool gate anchor + round cap" "yes" \
  "$(! grep -qF 'Use the **AskUserQuestion** tool' "$CI_SKILL_242" \
    && ! grep -qF 'Before the first `AskUserQuestion` call' "$CI_SKILL_242" \
    && ! grep -qF 'Cap at ~6 rounds' "$CI_SKILL_242" \
    && echo yes || echo no)"  # raw-guard-ok: compound absence pin — three removed literals must all be GONE
# AC (docs): the overview's create-issue sentence is runner-neutral, not "Uses AskUserQuestion, capped at ~6 rounds".
assert_pin_unique "#242 docs: overview states the runner-neutral total-question budget" \
  'runner-neutral total-clarifying-question budget' "$CI_OVERVIEW_242"
assert_eq "#242 docs: overview dropped the round-based cap phrasing" "yes" \
  "$(! grep -qF 'capped at ~6 rounds' "$CI_OVERVIEW_242" && echo yes || echo no)"  # raw-guard-ok: absence pin — old round-cap phrasing GONE
# ── #256: a silent no-response is NOT disengagement (question-tool timeout ≠ hand-off) ──
# The operative fix is behavioral: silence (a question-tool timeout / No response after 60s /
# the user stepping away) must NOT be classified as disengagement — the agent pauses and
# re-asks, and only an EXPLICIT reply engages the draft-from-decided / Blocked path. These
# are removal-proof presence pins on the operative sentences (assert_pin_unique fails closed
# if the literal is deleted or paraphrased), per the issue's testing strategy: pin the
# behavior, not merely the absence of "goes quiet". Literals are apostrophe-free + unique.
CI_SKILL_256="$LIB/../skills/create-issue/SKILL.md"
assert_pin_unique "#256 AC2: create-issue classifies a silent non-response as NOT disengagement" \
  'A silent non-response is not disengagement — never proceed on silence' "$CI_SKILL_256"
assert_pin_unique "#256 AC2: create-issue requires re-asking the unanswered question in the final chat message" \
  'pause and re-ask that question in your final chat message' "$CI_SKILL_256"
assert_pin_unique "#256 AC3: only an explicit reply engages the draft-from-decided / Blocked path" \
  'engages the disengagement / draft-from-decided / Blocked path below' "$CI_SKILL_256"
# AC3 exclusivity head — anchor the "Only an **explicit** reply" token itself, not just the
# sentence tail above: a paraphrase like "A silent non-response can also engage … the
# … Blocked path below" would keep the tail pin GREEN while reintroducing #256's bug.
assert_pin_unique "#256 AC3: the exclusivity head pins 'Only an explicit reply' (silence cannot engage)" \
  'Only an **explicit** reply from the user' "$CI_SKILL_256"
# AC3 second operative site — the disengagement-list header's exclusivity clause.
assert_pin_unique "#256 AC3: the disengagement-list header scopes triggers to explicit user replies" \
  'these three explicit replies are the *only* user-reply disengagement triggers' "$CI_SKILL_256"
# AC4 primary clause — anchor the "count of **answered** questions" reconciliation itself,
# not only its silence corollary below: a revert of line 78 to "a count of questions asked"
# would keep the corollary pin GREEN while re-opening the budget-vs-silence defect.
assert_pin_unique "#256 AC4: the budget counts answered questions, not questions merely asked" \
  'a *count of **answered** questions*, not a count of rounds or of questions merely asked' "$CI_SKILL_256"
assert_pin_unique "#256 AC4: a silent timeout never counts toward or trips the disengagement budget" \
  'never counts toward the budget and never trips' "$CI_SKILL_256"
# AC2 sub-clause — anchor the specific prohibited actions on silence (guess-a-default / Blocked),
# so a paraphrase that keeps "never proceed" but drops these cannot regress GREEN.
assert_pin_unique "#256 AC2: on silence the agent must not guess a default or route to Blocked" \
  'guess a default, or route the item to the Blocked section on that basis' "$CI_SKILL_256"
# AC5 — the new rule reconciles with the Step 4 confirmation gate (stay paused on no response).
assert_pin_unique "#256 AC5: the silent-non-response rule mirrors the Step 4 confirmation gate" \
  'This mirrors the Step 4 confirmation gate' "$CI_SKILL_256"
# AC1 (regression): "goes quiet" is GONE — silence is no longer a disengagement trigger.
assert_eq "#256 AC1: create-issue removed the goes-quiet disengagement trigger" "yes" \
  "$(! grep -qF 'goes quiet' "$CI_SKILL_256" && echo yes || echo no)"  # raw-guard-ok: absence pin — the removed trigger literal must be GONE
# ── #272: create-issue gains UI-change visual-specification awareness ──
# The change is prose guidance (Step 2 of the skill) + a template section + a docs
# mirror — a coupled trio (SKILL.md ↔ references/issue-template.md ↔ SYSTEM_OVERVIEW
# §11) that must stay mutually consistent (AC10). These are removal-proof presence
# pins (assert_pin_unique fails closed if the literal is deleted or paraphrased);
# literals are apostrophe-free + unique per file, per the issue's testing strategy:
# pin the template section heading + its Quality-checklist line (coupled-pin, so a
# half-edit goes RED), and the SKILL.md Step 2 UI-visual guidance — orchestrator-inferred
# UI detection (AC1), screenshot-resource check (AC2), record-embed-or-reference (AC3),
# ask-when-absent (AC4), the verbal-verification dimensions (AC5) and the
# preferred-not-mandatory substitute rule (AC7), the non-UI false-positive guard (AC8),
# and the Blocked-section route (AC9). Every #272 AC maps to at least one pin (AC3/AC4/AC5
# added after a Phase-3 review found them orphaned and the header over-claiming AC5).
CI_SKILL_272="$LIB/../skills/create-issue/SKILL.md"
CI_TEMPLATE_272="$LIB/../skills/create-issue/references/issue-template.md"
CI_OVERVIEW_272="$LIB/../docs/DEVFLOW_SYSTEM_OVERVIEW.md"
# AC6: the template carries the new Visual Specification section heading …
assert_pin_unique "#272 AC6: issue-template has the Visual Specification section heading" \
  '## Visual Specification' "$CI_TEMPLATE_272"
# … and its matching Quality-checklist line (coupled-pin — a half-edit goes RED).
assert_pin_unique "#272 AC6: issue-template Quality-checklist line for the Visual Specification section" \
  'the Visual Specification section records a screenshot/mockup or a verbally-verified placement spec' "$CI_TEMPLATE_272"
# AC1: orchestrator-inferred UI detection (not a dedicated is-this-UI question).
assert_pin_unique "#272 AC1: create-issue Step 2 infers UI changes as part of scope assessment" \
  'Infer whether the issue involves user-visible UI changes' "$CI_SKILL_272"
# AC2: on a UI change, check the user-provided resources for a screenshot/mockup.
assert_pin_unique "#272 AC2: create-issue Step 2 checks user-provided resources for a screenshot/mockup" \
  'On a UI change, check the user-provided resources/context' "$CI_SKILL_272"
# AC3: a present screenshot is recorded — embedded when a hosted URL exists, else referenced.
assert_pin_unique "#272 AC3: create-issue Step 2 records a present screenshot (embed-when-hosted, else reference)" \
  'embed it when a hosted URL is available, otherwise reference it' "$CI_SKILL_272"
# AC4: when none is present, ask the user to provide a screenshot or mockup.
assert_pin_unique "#272 AC4: create-issue Step 2 asks for a screenshot/mockup when none is present" \
  'ask the user to provide a screenshot or mockup' "$CI_SKILL_272"
# AC5: when the user has none, verbally verify the visual details (the dimensions checklist).
assert_pin_unique "#272 AC5: create-issue Step 2 verbally verifies the visual-detail dimensions" \
  'visual states (hover/focus/error/empty/loading/disabled), responsive behavior across breakpoints' "$CI_SKILL_272"
# AC7: a screenshot is preferred, not mandatory — verbal verification substitutes.
assert_pin_unique "#272 AC7: create-issue Step 2 treats a screenshot as preferred, verbal verification as substitute" \
  'preferred, not mandatory** — verbal verification is an accepted substitute' "$CI_SKILL_272"
# AC8 false-positive guard: non-UI issues skip the whole path and gain no new questions.
assert_pin_unique "#272 AC8: create-issue Step 2 skips the whole path for non-UI issues (no new questions)" \
  'the whole path below is skipped and adds no new questions' "$CI_SKILL_272"
# AC9: an unresolved UI-placement detail routes to the existing Blocked section (no new gate).
assert_pin_unique "#272 AC9: unresolved UI-placement detail flows to the existing Blocked section" \
  'flows to the existing `## 🚫 Blocked` section like any other unresolved decision' "$CI_SKILL_272"
# AC10 (coupled trio): SYSTEM_OVERVIEW §11 mirrors the new visual-specification behavior.
assert_pin_unique "#272 AC10: overview §11 mirrors the visual-specification behavior" \
  'infers an issue involves user-visible UI changes' "$CI_OVERVIEW_272"
assert_eq "#97 pin: ensure-label.sh exists" "yes" \
  "$([ -f "$LIB/../scripts/ensure-label.sh" ] && echo yes || echo no)"
assert_eq "#97 pin: create-issue ensures+applies DevFlow label via REST helper" "yes" \
  "$(grep -q 'ensure-label.sh DevFlow' "$LIB/../skills/create-issue/SKILL.md" && grep -qF 'apply-labels.sh <issue_number> DevFlow' "$LIB/../skills/create-issue/SKILL.md" && echo yes || echo no)"  # raw-guard-ok: compound: two greps && on one line (provenance: ensure-label + REST apply-labels)
# ── #241: create-issue resolves its helper-scripts anchor portably across runners ──
# A1 (AC1, AC5): the portable-resolution recipe is present — the anchor is set to
# $CLAUDE_SKILL_DIR when non-empty (the `:-` expansion also covers the empty case, AC3)
# and otherwise the runner-reported skill base dir. The literal recurs by design: each
# helper's bash fence re-establishes the anchor (fresh-shell-safe), so this is a `yes`
# presence pin whose literal legitimately appears at more than one site, not a
# uniqueness pin.
assert_eq "#241 pin (A1): create-issue resolves a portable helper anchor (\$CLAUDE_SKILL_DIR-preferred, runner-base-dir fallback)" "yes" \
  "$(grep -qF 'SKILL_DIR="${CLAUDE_SKILL_DIR:-' "$LIB/../skills/create-issue/SKILL.md" && echo yes || echo no)"  # raw-guard-ok: presence pin — literal recurs across the self-contained helper fences by design (not unique)
# A1b (review PR #243 Important note): the anchor must be RE-ESTABLISHED in BOTH bash
# fences (each Bash call is a fresh shell). A1 alone is satisfied by one occurrence, so
# a future edit that trims the "redundant" second assignment would keep every pin green
# while that fence's helpers run with an unset $SKILL_DIR — a regression strictly worse
# than #241 (it breaks on Claude Code too). Mutation-verified: deleting either fence's
# assignment line drops the count to 1 and fails this pin.
assert_eq "#241 pin (A1b): the anchor assignment appears exactly twice (one per bash fence)" "2" \
  "$(grep -cF 'SKILL_DIR="${CLAUDE_SKILL_DIR:-' "$LIB/../skills/create-issue/SKILL.md")"  # raw-guard-ok: count pin — exactly one anchor re-establishment per fence
# A2 (AC2): the regression-reproducing absence pin — NO bare (braced OR unbraced)
# $CLAUDE_SKILL_DIR/../../scripts expansion may remain. RED provenance: three braced
# occurrences existed in the pre-#241 file; the pin was authored failing against that
# state and went GREEN when every call site was routed through the resolved anchor.
# The ERE also catches the unbraced form ($CLAUDE_SKILL_DIR/../../scripts), which
# collapses identically on empty-var runners but the old -F braced literal missed.
# The inner grep must find NO bare expansion; the leading `!` negates it, so the
# assert_eq passes with `yes` when the pattern is absent (do not misread this as an
# assert_eq expecting `no`).
assert_eq "#241 pin (A2): create-issue has no bare braced-or-unbraced \$CLAUDE_SKILL_DIR/../../scripts expansion" "yes" \
  "$(! grep -qE '\$\{?CLAUDE_SKILL_DIR\}?/\.\./\.\./scripts' "$LIB/../skills/create-issue/SKILL.md" && echo yes || echo no)"  # raw-guard-ok: absence pin — the broken expansion (either brace form) must be GONE
# A2b (AC2, positive companion to A2): A2 proves NO bare expansion remains file-wide, but
# that is a negative fact — it would still pass if the Step-4 label helpers were dropped
# entirely. Pin each label call site POSITIVELY through the resolved anchor so "every
# helper invocation uses that single resolved anchor" (AC2) is asserted, not just implied.
assert_pin_unique "#241 pin (A2b): create-issue invokes ensure-label.sh through the resolved anchor" \
  '"$SKILL_DIR"/../../scripts/ensure-label.sh DevFlow' "$LIB/../skills/create-issue/SKILL.md"
assert_pin_unique "#241 pin (A2b): create-issue invokes apply-labels.sh through the resolved anchor" \
  '"$SKILL_DIR"/../../scripts/apply-labels.sh <issue_number> DevFlow' "$LIB/../skills/create-issue/SKILL.md"
# A2b (traceability companion): the third migrated call site — the preamble
# load-prompt-extension.sh invocation — is also pinned HERE so all three positive
# call-site pins live in one block; the lpe-coverage loop (issue #97/#218 region)
# independently enforces the same line as create-issue's expected LPE form.
assert_pin_unique "#241 pin (A2b): create-issue invokes load-prompt-extension.sh through the resolved anchor" \
  '"$SKILL_DIR"/../../scripts/load-prompt-extension.sh create-issue' "$LIB/../skills/create-issue/SKILL.md"
# A3 (review PR #243 Important note): sub-step 5a carries the same anchor-resolution-vs-
# helper-outcome discrimination guard the preamble has, so a broken-anchor "No such file"
# (the helper never ran; the always-exit-0 contract never engaged) is not swallowed by
# the "continue regardless of the label outcome" prose as a benign label hiccup.
assert_pin_unique "#241 pin (A3): sub-step 5a discriminates anchor-resolution failure from a benign label outcome" \
  'The always-exit-0 contract applies only once a helper actually runs' "$LIB/../skills/create-issue/SKILL.md"
# A3b (review PR #243 Important note): when the anchor is genuinely UNRESOLVABLE on a
# runner (neither $CLAUDE_SKILL_DIR nor a runner-reported base dir), the guard must not
# fail open into "Continue to sub-step 6 regardless" — sub-step 5a surfaces the
# degradation explicitly (issue created, provenance label NOT applied) so the silently
# dropped DevFlow label never vanishes from the retrospective detection unnoticed.
assert_pin_unique "#241 pin (A3b): sub-step 5a surfaces an unresolvable anchor as an explicit degradation, not a silent skip" \
  'provenance label NOT applied' "$LIB/../skills/create-issue/SKILL.md"
assert_eq "#97 pin: implement applies DevFlow label at PR create via REST helper" "yes" \
  "$(grep -q 'ensure-label.sh DevFlow' "$IMPL_SKILL_BUNDLE" && grep -qF 'apply-labels.sh "$PR_NUM" DevFlow' "$IMPL_SKILL_BUNDLE" && echo yes || echo no)"  # raw-guard-ok: compound: two greps && on one line (provenance: ensure-label + REST apply-labels); issue #218: bundle (label idiom in phases/phase-3-review.md)
assert_eq "#152 pin: meta-issue.sh ensures+applies DevFlow and Retrospective labels via REST helper" "yes" \
  "$(grep -q 'ensure-label.sh' "$LIB/meta-issue.sh" && grep -qF 'apply-labels.sh' "$LIB/meta-issue.sh" && grep -qF 'DevFlow Retrospective' "$LIB/meta-issue.sh" && echo yes || echo no)"
assert_eq "#97 pin: init creates the reserved DevFlow provenance label" "yes" \
  "$(grep -q 'ensure-label.sh DevFlow' "$LIB/../skills/init/SKILL.md" && grep -qi 'provenance' "$LIB/../skills/init/SKILL.md" && echo yes || echo no)"  # raw-guard-ok: compound: two greps && on one line (provenance: ensure-label + provenance)
# ── #228: REST migration — no org-scoped GraphQL porcelain on any migrated path ──
# The removed invocation LITERALS (command + their args) must be gone. These exact
# forms never appear in the now-present contrastive prose (which references the bare
# `gh issue edit --add-label` without args), so an absence pin here cannot false-match.
assert_eq "#228: ensure-label.sh creates via REST gh api, not gh label create" "yes" \
  "$(grep -qF 'api --method POST' "$LIB/../scripts/ensure-label.sh" && ! grep -qF 'label create "$NAME"' "$LIB/../scripts/ensure-label.sh" && echo yes || echo no)"
assert_eq "#228: apply-labels.sh applies via REST gh api, never gh issue/pr edit" "yes" \
  "$(grep -qF 'api --method POST' "$LIB/../scripts/apply-labels.sh" && ! grep -qE '"\$DEVFLOW_GH" (issue|pr) edit' "$LIB/../scripts/apply-labels.sh" && echo yes || echo no)"
assert_eq "#228: meta-issue.sh no longer invokes 'gh issue edit' for labels" "yes" \
  "$(! grep -qF '"$DEVFLOW_GH" issue edit' "$LIB/meta-issue.sh" && echo yes || echo no)"
assert_eq "#228: create-issue removed the gh issue edit --add-label command" "yes" \
  "$(! grep -qF 'gh issue edit <issue_number> --add-label DevFlow' "$LIB/../skills/create-issue/SKILL.md" && echo yes || echo no)"  # raw-guard-ok: absence pin — asserts the removed porcelain command literal is GONE (negated grep, not a presence pin)
assert_eq "#228: phase-3 removed the gh pr edit --add-label command" "yes" \
  "$(! grep -qF 'gh pr edit "$PR_NUM" --add-label DevFlow' "$IMPL_SKILL_BUNDLE" && echo yes || echo no)"  # raw-guard-ok: absence pin — asserts the removed porcelain command literal is GONE (negated grep, not a presence pin)
assert_eq "#228: phase-4 removed the gh issue edit --add-label deferred command" "yes" \
  "$(! grep -qF 'gh issue edit "$n" --add-label "$CLEAN_DEFERRED_LABELS"' "$IMPL_SKILL_BUNDLE" && echo yes || echo no)"  # raw-guard-ok: absence pin — asserts the removed porcelain command literal is GONE (negated grep, not a presence pin)
assert_eq "#228: phase-4 removed the gh pr edit --add-label docs-label command" "yes" \
  "$(! grep -qF 'gh pr edit --add-label "$CLEAN_LABELS"' "$IMPL_SKILL_BUNDLE" && echo yes || echo no)"  # raw-guard-ok: absence pin — asserts the removed porcelain command literal is GONE (negated grep, not a presence pin)
assert_eq "#228: phase-4 docs-label routes through apply-labels.sh (symmetric presence pin)" "yes" \
  "$(grep -qF 'apply-labels.sh "$DOCS_PR_NUM" "$CLEAN_LABELS"' "$IMPL_SKILL_BUNDLE" && echo yes || echo no)"  # raw-guard-ok: presence pin pairs with the docs-label absence pin above so a typo'd new invocation can't pass all phase-4 pins
assert_eq "#228: pr-description edits the body via REST gh api PATCH, not gh pr edit --body" "yes" \
  "$(grep -qF 'api --method PATCH' "$LIB/../skills/pr-description/SKILL.md" && ! grep -qF 'gh pr edit $PR_NUMBER --body' "$LIB/../skills/pr-description/SKILL.md" && echo yes || echo no)"  # raw-guard-ok: compound presence+absence pin (REST PATCH present AND old porcelain gone), not a single target-unique pin
# Positively pin the migrated body-write SHAPE: `-F body=@-` reads the field literally
# from stdin (the heredoc), the form that replaced `--body-file`'s no-expansion guarantee.
# Distinguishable from the contrastive prose (which says bare `gh pr edit --body`), so this
# is the real tripwire a porcelain reintroduction would have to defeat.
assert_eq "#228: pr-description body PATCH uses the literal -F body=@- stdin form" "yes" \
  "$(grep -qF -- '-F body=@-' "$LIB/../skills/pr-description/SKILL.md" && echo yes || echo no)"  # raw-guard-ok: presence pin on the migrated literal-read body-write form
assert_eq "#97 pin: retrospective Stage A consumes reflections" "yes" \
  "$(grep -qi 'reflection' "$LIB/../skills/retrospective/SKILL.md" && echo yes || echo no)"  # raw-guard-ok: case-insensitive (grep -qi); pin_count is case-sensitive -F
assert_eq "#97 pin: cheap-gate carries the reflection reason string" "yes" \
  "$(grep -q 'workpad reflections present' "$LIB/cheap-gate.jq" && echo yes || echo no)"
assert_eq "#97 pin: config.example.json docs.labels reverted to Documented" "Documented" \
  "$(jq -r '.docs.labels' "$LIB/../.devflow/config.example.json")"

# ── #152: propose-not-dispose contract pins (grep) ───────────────────────────
# Stage B (retrospective-audit) is now a pure {title, body} spec generator: zero
# worktrees, zero edits, no two-form excluded/targets contract.
RA_SKILL="$LIB/../skills/retrospective-audit/SKILL.md"
assert_eq "#152: Stage B emits the {title, body} contract" "yes" \
  "$(grep -qF '{title, body}' "$RA_SKILL" && echo yes || echo no)"  # raw-guard-ok: non-unique: '{title, body}' appears 4x in retrospective-audit SKILL
assert_eq "#152: Stage B runs no git worktree" "yes" \
  "$(grep -q 'git worktree' "$RA_SKILL" && echo no || echo yes)"  # raw-guard-ok: absence pin: asserts Stage B runs no git worktree (expected absent)
assert_eq "#152: Stage B drops the targets[] return field" "yes" \
  "$(grep -qF '"targets"' "$RA_SKILL" && echo no || echo yes)"  # raw-guard-ok: absence pin: asserts Stage B drops the targets[] field (expected absent)
assert_eq "#152: Stage B drops the excluded return field" "yes" \
  "$(grep -qF '"excluded"' "$RA_SKILL" && echo no || echo yes)"  # raw-guard-ok: absence pin: asserts Stage B drops the excluded field (expected absent)
# Orchestrator (retrospective-weekly) Step 8 files issues, opens zero PRs, runs no
# worktrees, and never auto-posts /devflow:implement.
RW_SKILL="$LIB/../skills/retrospective-weekly/SKILL.md"
assert_eq "#152: orchestrator invokes meta-issue.sh" "yes" \
  "$(grep -q 'meta-issue.sh' "$RW_SKILL" && echo yes || echo no)"  # raw-guard-ok: non-unique: 'meta-issue.sh' appears many times in retrospective-weekly SKILL
assert_eq "#152: orchestrator accumulates intervention_issues" "yes" \
  "$(grep -q 'intervention_issues' "$RW_SKILL" && echo yes || echo no)"  # raw-guard-ok: non-unique: 'intervention_issues' appears many times in retrospective-weekly SKILL
assert_eq "#152: orchestrator opens no PR (no gh pr create)" "yes" \
  "$(grep -q 'gh pr create' "$RW_SKILL" && echo no || echo yes)"  # raw-guard-ok: absence pin: asserts the orchestrator opens no PR (expected absent)
assert_eq "#152: orchestrator runs no git worktree" "yes" \
  "$(grep -q 'git worktree' "$RW_SKILL" && echo no || echo yes)"  # raw-guard-ok: absence pin: asserts the orchestrator runs no git worktree (expected absent)
# AC6: the loop never auto-triggers implementation. The orchestrator posts NO
# comment to a filed issue (it may reference the pipeline by name in prose, which
# is fine) — the structural guard is the absence of any gh issue/pr comment that
# would carry an auto-trigger.
assert_eq "#152: orchestrator posts no gh issue/pr comment (no auto-trigger)" "yes" \
  "$(grep -qE 'gh (issue|pr) comment' "$RW_SKILL" && echo no || echo yes)"  # raw-guard-ok: absence pin: asserts no auto-trigger gh issue/pr comment (expected absent)
assert_eq "#152: orchestrator states filed issues await human triage" "yes" \
  "$(grep -qi 'await human triage' "$RW_SKILL" && echo yes || echo no)"  # raw-guard-ok: case-insensitive (grep -qi); pin_count is case-sensitive -F
# #152: the load-bearing "never report a pattern as filed when it was not"
# invariant — a malformed Stage B result OR a meta-issue.sh non-zero exit must
# record a blocker and file NOTHING. Pin BOTH failure branches' concrete blocker
# appends so a refactor cannot silently drop the file-nothing path (the orchestrator
# glue the standalone review flagged as untested). The malformed branch keys on the
# "malformed JSON" blocker; the exit-non-zero branch keys on "failed to file".
assert_eq "#152: orchestrator records a blocker on a malformed Stage B result" "yes" \
  "$(grep -q 'blockers+=.*malformed JSON' "$RW_SKILL" && echo yes || echo no)"  # raw-guard-ok: regex grep (no -F): asserts a regex match (blockers+=.*), not a fixed literal
assert_eq "#152: orchestrator records a blocker (files nothing) on meta-issue.sh failure" "yes" \
  "$(grep -q 'blockers+=.*failed to file the issue' "$RW_SKILL" && echo yes || echo no)"  # raw-guard-ok: regex grep (no -F): asserts a regex match (blockers+=.*), not a fixed literal
assert_eq "#152: orchestrator pins the never-report-unfiled-as-filed invariant" "yes" \
  "$(grep -qi 'Never report a pattern as filed when it was not' "$RW_SKILL" && echo yes || echo no)"  # raw-guard-ok: case-insensitive (grep -qi); pin_count is case-sensitive -F
# Prune: no operative engine surface references the removed audit-intervention
# kind or the devflow/audit-* branch convention (CHANGELOG history + this test
# suite's own classify-input strings are intentionally excluded — note git
# pathspec `*` crosses `/`, so lib/test/ is excluded explicitly).
PRUNE_SCAN=$( cd "$LIB/.." && git grep -lFe 'audit-intervention' -e 'devflow/audit' -- \
    'lib/*.sh' 'lib/*.jq' 'skills/*/SKILL.md' 'docs/DEVFLOW_SYSTEM_OVERVIEW.md' \
    'CLAUDE.md' '.devflow/config.schema.json' 'lib/intervention-surfaces.md' \
    ':(exclude)lib/test/' 2>/dev/null || true )
assert_eq "#152: no operative file references audit-intervention / devflow-audit" "" "$PRUNE_SCAN"
# Coupled site: the de-dup title meta-issue.sh writes is re-parsed by
# actionable-patterns.sh's cooldown map. Pin the round-trip so a format drift on
# either side goes red here, before cooldown silently stops matching.
RT_SLUG="incomplete-edit"
RT_TITLE="[devflow-retrospective] meta: ${RT_SLUG} — strengthen the gate"
RT_PARSED="$(jq -rn --arg t "$RT_TITLE" '$t | capture("\\[devflow-retrospective\\] meta: (?<slug>[A-Za-z0-9_-]+)") | .slug')"
assert_eq "#152: meta-issue title round-trips through the cooldown slug regex" "$RT_SLUG" "$RT_PARSED"
assert_eq "#152: actionable-patterns carries the meta-title slug regex" "yes" \
  "$(grep -qF 'meta: (?<slug>' "$LIB/actionable-patterns.sh" && echo yes || echo no)"

# ────────────────────────────────────────────────────────────────────────────
echo "clean-entry.jq / actionable-patterns.sh"
# ────────────────────────────────────────────────────────────────────────────
CTX_CLEAN='{"pr":42,"kind":"implementation","issue_number":40,"merged_at":"2026-05-01T00:00:00Z","branch":"claude/issue-40-x","head_sha":"abc","merge_commit_sha":"def","signals":{"review_comments_count":0,"post_bot_commits":0,"ci_failures_during_pr":0,"workpad_final_status":"Complete","review_reject_outstanding":false}}'
E="$(echo "$CTX_CLEAN" | jq -c -f "$LIB/clean-entry.jq")"
assert_eq "clean-entry verdict=clean"       "clean" "$(echo "$E" | jq -r .verdict)"
assert_eq "clean-entry pr=42"               "42"    "$(echo "$E" | jq -r .pr)"
assert_eq "clean-entry schema_version=2"    "2"     "$(echo "$E" | jq -r .schema_version)"
assert_eq "clean-entry categories=[]"       "0"     "$(echo "$E" | jq '.categories|length')"
assert_eq "clean-entry descriptors=[]"      "0"     "$(echo "$E" | jq '.descriptors|length')"
assert_eq "clean-entry no theme_tags field" "true"  "$(echo "$E" | jq 'has("theme_tags") | not')"
assert_eq "clean-entry signals carried"     "0"     "$(echo "$E" | jq -r .signals.post_bot_commits)"
# #152: audit-entry.jq is pruned along with the audit-intervention path.
assert_eq "#152: audit-entry.jq is removed" "true" \
  "$([ ! -f "$LIB/audit-entry.jq" ] && echo true || echo false)"
# actionable-patterns: incomplete-edit 2x imperfect, doc-accuracy 1x
AP_TMP="$(mktemp -d)"
printf '%s\n' \
  '{"schema_version":2,"kind":"implementation","pr":1,"merged_at":"2026-04-01T00:00:00Z","verdict":"imperfect","categories":["incomplete-edit"],"descriptors":["orphaned fetch left after deletion"]}' \
  '{"schema_version":2,"kind":"implementation","pr":2,"merged_at":"2026-04-10T00:00:00Z","verdict":"imperfect","categories":["incomplete-edit"],"descriptors":["stale count not propagated"]}' \
  '{"schema_version":2,"kind":"implementation","pr":3,"merged_at":"2026-04-11T00:00:00Z","verdict":"imperfect","categories":["doc-accuracy"]}' \
  > "$AP_TMP/r.jsonl"
echo '{"schema_version":1,"dismissed":{}}' > "$AP_TMP/o.json"
cat > "$AP_TMP/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in *"pr list"*) echo '[]' ;; *) echo '[]' ;; esac
STUB
chmod +x "$AP_TMP/gh"
AP="$(DEVFLOW_GH="$AP_TMP/gh" bash "$LIB/actionable-patterns.sh" "$AP_TMP/r.jsonl" "$AP_TMP/o.json")"
assert_eq "actionable includes incomplete-edit"        "true"  "$(echo "$AP" | jq 'any(.[]; .tag=="incomplete-edit")')"
assert_eq "actionable excludes doc-accuracy (1<2)"     "false" "$(echo "$AP" | jq 'any(.[]; .tag=="doc-accuracy")')"
assert_eq "incomplete-edit occurrence_count=2"         "2"     "$(echo "$AP" | jq '.[] | select(.tag=="incomplete-edit") | .occurrence_count')"
assert_eq "incomplete-edit descriptors passed through" "orphaned fetch left after deletion|stale count not propagated" \
  "$(echo "$AP" | jq -r '.[] | select(.tag=="incomplete-edit") | .descriptors | sort | join("|")')"
assert_eq "incomplete-edit cooldown_active=false"      "false" "$(echo "$AP" | jq '.[] | select(.tag=="incomplete-edit") | .cooldown_active')"
# #152: cooldown is now driven by an open FILED retrospective issue (not an audit
# PR). An open "[devflow-retrospective] meta: incomplete-edit — …" issue created
# today → cooldown_active true.
cat > "$AP_TMP/gh" <<STUB
#!/usr/bin/env bash
case "\$*" in *"issue list"*) echo '[{"number":500,"title":"[devflow-retrospective] meta: incomplete-edit — strengthen the gate","createdAt":"'"$(date -u +%FT%TZ)"'"}]' ;; *) echo '[]' ;; esac
STUB
chmod +x "$AP_TMP/gh"
AP2="$(DEVFLOW_GH="$AP_TMP/gh" bash "$LIB/actionable-patterns.sh" "$AP_TMP/r.jsonl" "$AP_TMP/o.json")"
assert_eq "incomplete-edit cooldown_active=true after recent filed issue" "true" "$(echo "$AP2" | jq '.[] | select(.tag=="incomplete-edit") | .cooldown_active')"
# #152: cooldown EXPIRY boundary — an open filed issue OLDER than cooldown_days
# (default 3) → cooldown_active=false, so the pattern is re-filed. Guards the
# createdAt>=cooldown_epoch comparison (a flipped operator / epoch-sign bug would
# pin the pattern in permanent cooldown or never honor it, and the today/never
# fixtures above cannot catch it). Use 30 days ago — safely past any default.
_AP_OLD="$(python3 -c "import datetime as d; print((d.datetime.now(d.timezone.utc)-d.timedelta(days=30)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
cat > "$AP_TMP/gh" <<STUB
#!/usr/bin/env bash
case "\$*" in *"issue list"*) echo '[{"number":501,"title":"[devflow-retrospective] meta: incomplete-edit — strengthen the gate","createdAt":"${_AP_OLD}"}]' ;; *) echo '[]' ;; esac
STUB
chmod +x "$AP_TMP/gh"
AP3="$(DEVFLOW_GH="$AP_TMP/gh" bash "$LIB/actionable-patterns.sh" "$AP_TMP/r.jsonl" "$AP_TMP/o.json")"
assert_eq "incomplete-edit cooldown_active=false when filed issue is older than cooldown_days" "false" "$(echo "$AP3" | jq '.[] | select(.tag=="incomplete-edit") | .cooldown_active')"
# #152: a gh contract drift emitting an open issue with a null / malformed
# `createdAt` must be DROPPED at the cooldown-map producer (so it never reaches
# strptime and aborts the final jq), not crash the run. The producer parses with
# strptime itself, so the drop is total against strptime's real contract — the
# adversarial matrix here spans null, empty, fractional-seconds, non-Z offset,
# AND in-shape-but-out-of-range (month 13 / hour 99), which a mere shape regex
# would admit. Every drifted row is dropped → no open issue → cooldown_active=false.
cat > "$AP_TMP/gh" <<STUB
#!/usr/bin/env bash
case "\$*" in *"issue list"*) echo '[{"number":502,"title":"[devflow-retrospective] meta: incomplete-edit — x","createdAt":null},{"number":503,"title":"[devflow-retrospective] meta: incomplete-edit — x","createdAt":"2026-06-28T12:00:00.5Z"},{"number":504,"title":"[devflow-retrospective] meta: incomplete-edit — x","createdAt":""},{"number":505,"title":"[devflow-retrospective] meta: incomplete-edit — x","createdAt":"2026-06-28T12:00:00+00:00"},{"number":506,"title":"[devflow-retrospective] meta: incomplete-edit — x","createdAt":"2026-13-99T99:99:99Z"}]' ;; *) echo '[]' ;; esac
STUB
chmod +x "$AP_TMP/gh"
AP4="$(DEVFLOW_GH="$AP_TMP/gh" bash "$LIB/actionable-patterns.sh" "$AP_TMP/r.jsonl" "$AP_TMP/o.json")"; AP4_RC=$?
assert_eq "actionable: malformed createdAt rows are dropped, not crashed-on (exit 0)" "true" \
  "$([ "$AP4_RC" -eq 0 ] && echo true || echo false)"
assert_eq "actionable: malformed-createdAt open issue does not set cooldown_active" "false" \
  "$(echo "$AP4" | jq '.[] | select(.tag=="incomplete-edit") | .cooldown_active')"
# Missing overrides.json → should still emit the actionable array, not error
AP_NOOV="$(DEVFLOW_GH="$AP_TMP/gh" bash "$LIB/actionable-patterns.sh" "$AP_TMP/r.jsonl" "/tmp/devflow-nonexistent-overrides-$$-$RANDOM.json")" \
  && assert_eq "actionable: missing overrides → incomplete-edit still present" "true" "$(echo "$AP_NOOV" | jq 'any(.[]; .tag=="incomplete-edit")')" \
  || { echo FAIL >> "$RESULTS_FILE"; printf '  FAIL  actionable: missing overrides → script errored\n'; }
# #152: the open-issue cooldown lookup must FAIL CLOSED, not fail open. A `gh issue
# list` error (auth/rate-limit/network) that silently yielded an empty cooldown map
# would re-file a duplicate for every pattern — the fail-open-where-it-claims-closed
# class CLAUDE.md flags (#62/#98). The lookup-failure and non-JSON-body guards must
# each exit non-zero with a SPECIFIC breadcrumb naming the cooldown step.
cat > "$AP_TMP/gh-listfail" <<'STUB'
#!/usr/bin/env bash
case "$*" in *"issue list"*) exit 1 ;; *) echo '[]' ;; esac
STUB
chmod +x "$AP_TMP/gh-listfail"
DEVFLOW_GH="$AP_TMP/gh-listfail" bash "$LIB/actionable-patterns.sh" "$AP_TMP/r.jsonl" "$AP_TMP/o.json" >/dev/null 2>"$AP_TMP/listfail.err"; AP_LF_RC=$?
assert_eq "actionable: gh issue-list failure fails closed (non-zero exit)" "true" \
  "$([ "$AP_LF_RC" -ne 0 ] && echo true || echo false)"
assert_eq "actionable: gh issue-list failure leaves a cooldown-lookup breadcrumb" "true" \
  "$(grep -q 'cooldown lookup failed' "$AP_TMP/listfail.err" && echo true || echo false)"
cat > "$AP_TMP/gh-nonjson" <<'STUB'
#!/usr/bin/env bash
case "$*" in *"issue list"*) echo 'gh: not authenticated' ;; *) echo '[]' ;; esac
STUB
chmod +x "$AP_TMP/gh-nonjson"
DEVFLOW_GH="$AP_TMP/gh-nonjson" bash "$LIB/actionable-patterns.sh" "$AP_TMP/r.jsonl" "$AP_TMP/o.json" >/dev/null 2>"$AP_TMP/nonjson.err"; AP_NJ_RC=$?
assert_eq "actionable: non-JSON open-issue body fails closed (non-zero exit)" "true" \
  "$([ "$AP_NJ_RC" -ne 0 ] && echo true || echo false)"
assert_eq "actionable: non-JSON open-issue body leaves a parse breadcrumb" "true" \
  "$(grep -q 'could not parse the open-issue list as JSON' "$AP_TMP/nonjson.err" && echo true || echo false)"
# #152: a drifted-slug title (carries the de-dup prefix but the slug token does not
# match the capture grammar) must be COUNTED and surfaced via ::warning::, not
# silently dropped from the cooldown map — a silent drop would re-file duplicates.
cat > "$AP_TMP/gh-drift" <<'STUB'
#!/usr/bin/env bash
case "$*" in *"issue list"*) echo '[{"number":7,"title":"[devflow-retrospective] meta: !!bad — x","createdAt":"2026-04-01T00:00:00Z"}]' ;; *) echo '[]' ;; esac
STUB
chmod +x "$AP_TMP/gh-drift"
DEVFLOW_GH="$AP_TMP/gh-drift" bash "$LIB/actionable-patterns.sh" "$AP_TMP/r.jsonl" "$AP_TMP/o.json" >/dev/null 2>"$AP_TMP/drift.err"
assert_eq "actionable: unparseable-slug open issue surfaces a drift ::warning::" "true" \
  "$(grep -q 'unparseable slug' "$AP_TMP/drift.err" && echo true || echo false)"
rm -rf "$AP_TMP"

# ────────────────────────────────────────────────────────────────────────────
echo "materialize-retrospectives.sh"
# ────────────────────────────────────────────────────────────────────────────
M_TMP="$(mktemp -d)"
printf '%s\n' \
  '{"pr":1,"kind":"implementation","verdict":"clean","note":"old"}' \
  '{"pr":2,"kind":"implementation","verdict":"imperfect"}' \
  > "$M_TMP/r.jsonl"
printf '%s\n' \
  '{"pr":1,"kind":"implementation","verdict":"imperfect","note":"new"}' \
  '{"pr":5,"kind":"implementation","verdict":"clean"}' \
  '{"pr":2,"kind":"audit","fixes_patterns":["t-z"]}' \
  > "$M_TMP/new.jsonl"
SUMMARY="$(bash "$LIB/materialize-retrospectives.sh" "$M_TMP/new.jsonl" "$M_TMP/r.jsonl")"
assert_eq "materialize: 4 lines after merge"      "4" "$(wc -l < "$M_TMP/r.jsonl" | tr -d ' ')"
assert_eq "materialize: pr1 replaced (note=new)"  "new" "$(grep '"pr":1' "$M_TMP/r.jsonl" | jq -r 'select(.pr==1 and .kind=="implementation") | .note')"
assert_eq "materialize: pr5 appended"             "true" "$([ -n "$(jq -c 'select(.pr==5)' "$M_TMP/r.jsonl")" ] && echo true || echo false)"
assert_eq "materialize: pr2 audit appended (impl kept)" "2" "$(jq -s '[.[]|select(.pr==2)]|length' "$M_TMP/r.jsonl")"
assert_eq "materialize: valid jsonl" "0" "$(jq -c . "$M_TMP/r.jsonl" >/dev/null 2>&1; echo $?)"
assert_eq "materialize: summary mentions replaced 1" "1" "$(echo "$SUMMARY" | grep -oE 'replaced [0-9]+' | grep -oE '[0-9]+')"
# Fix 5: missing new-entries file → should print "materialized: appended 0, replaced 0" and exit 0
M_NOFILE_TMP="$(mktemp -d)"
printf '%s\n' '{"pr":10,"kind":"implementation","verdict":"clean"}' > "$M_NOFILE_TMP/existing.jsonl"
M_NOFILE_OUT="$(bash "$LIB/materialize-retrospectives.sh" "/tmp/devflow-nonexistent-new-entries-$$-$RANDOM.jsonl" "$M_NOFILE_TMP/existing.jsonl")"
assert_eq "materialize: missing new-entries → appended 0, replaced 0" "materialized: appended 0, replaced 0" "$M_NOFILE_OUT"
assert_eq "materialize: missing new-entries → target untouched" "1" "$(wc -l < "$M_NOFILE_TMP/existing.jsonl" | tr -d ' ')"
rm -rf "$M_NOFILE_TMP"
rm -rf "$M_TMP"

# ────────────────────────────────────────────────────────────────────────────
echo "meta-issue.sh"
# ────────────────────────────────────────────────────────────────────────────
MI_TMP="$(mktemp -d)"
echo '{"schema_version":1,"dismissed":{}}' > "$MI_TMP/ov.json"
# #152: the body is the Stage-B-authored issue spec, filed VERBATIM. Use a body
# with backticks, $, and newlines to prove it round-trips unmangled (written to a
# file, never inlined into shell) and is NOT wrapped in any prepend/append.
printf '## Problem Statement\nStrengthen `cheap-gate.jq` so $VAR shapes do not slip.\n\nMulti-line.\n' > "$MI_TMP/body.md"
# Stub writes its capture files into its own dir ($MI_TMP) so a quoted heredoc can
# stay free of run.sh shell-var interpolation. Handles label create / issue edit
# (the best-effort label stamping) in addition to list/create/comment.
cat > "$MI_TMP/gh" <<'STUB'
#!/usr/bin/env bash
D="$(dirname "$0")"
case "$*" in
  *"issue list"*) echo '' ;;                                # no existing issue
  *"issue create"*)
     printf '%s' "$*" > "$D/create-args"
     prev=""
     for a in "$@"; do
       [ "$prev" = "--body-file" ] && cat "$a" > "$D/created-body.md"
       prev="$a"
     done
     echo 'https://github.com/acme/example-repo/issues/4242' ;;
  *"issue comment"*) echo 'commented' ;;
  *"issues/"*"/labels"*) printf '%s' "$*" > "$D/edit-args" ;;   # REST label apply (apply-labels.sh)
  *"--method POST"*"/labels"*) echo '{}' ;;                       # REST label create (ensure-label.sh)
  *) echo '' ;;
esac
STUB
chmod +x "$MI_TMP/gh"
URL="$(DEVFLOW_GH="$MI_TMP/gh" bash "$LIB/meta-issue.sh" --tag review-reject-bypassed --slug review-reject-bypassed --title "audit(devflow): x" --body-file "$MI_TMP/body.md" --overrides "$MI_TMP/ov.json" 2>/dev/null)"
assert_eq "meta-issue returns the new URL" "https://github.com/acme/example-repo/issues/4242" "$URL"
# Created title must keep the de-dup key prefix (Step-1 search matches it) AND
# carry the caller's --title (regression: --title was previously discarded).
assert_eq "create title keeps the de-dup key" "true" \
  "$(grep -qF -- '--title [devflow-retrospective] meta: review-reject-bypassed' "$MI_TMP/create-args" && echo true || echo false)"
assert_eq "create title carries the caller --title" "true" \
  "$(grep -qF -- 'audit(devflow): x' "$MI_TMP/create-args" && echo true || echo false)"
# #152: the filed body equals the input verbatim — no `## Pattern:` prepend, no
# "can't be an auto-opened PR" boilerplate, backticks/$/newlines intact.
assert_eq "meta-issue files the body verbatim" "true" \
  "$(diff -q "$MI_TMP/body.md" "$MI_TMP/created-body.md" >/dev/null 2>&1 && echo true || echo false)"
# #152: both the DevFlow provenance label and the Retrospective marker are stamped
# (best-effort) on the freshly filed issue (#4242, derived from the created URL).
assert_eq "meta-issue stamps DevFlow label (REST labels[] field)" "true" \
  "$(grep -qF -- 'labels[]=DevFlow' "$MI_TMP/edit-args" && echo true || echo false)"
assert_eq "meta-issue stamps Retrospective label (REST labels[] field)" "true" \
  "$(grep -qF -- 'labels[]=Retrospective' "$MI_TMP/edit-args" && echo true || echo false)"
assert_eq "meta-issue applies via REST issues/4242/labels (not gh issue edit)" "true" \
  "$(grep -qF -- 'issues/4242/labels' "$MI_TMP/edit-args" && echo true || echo false)"
assert_eq "override recorded with url"     "https://github.com/acme/example-repo/issues/4242" "$(jq -r '.dismissed["review-reject-bypassed"].meta_issue' "$MI_TMP/ov.json")"
assert_eq "override reason"                "meta-plugin-issue" "$(jq -r '.dismissed["review-reject-bypassed"].reason' "$MI_TMP/ov.json")"
assert_eq "override dismissed_by"          "retrospective-weekly"    "$(jq -r '.dismissed["review-reject-bypassed"].dismissed_by' "$MI_TMP/ov.json")"
# existing-issue path (de-dup): comments instead of re-filing, still stamps labels
rm -f "$MI_TMP/edit-args"
cat > "$MI_TMP/gh" <<'STUB'
#!/usr/bin/env bash
D="$(dirname "$0")"
case "$*" in
  *"issue list"*) echo '[{"number":99,"url":"https://github.com/acme/example-repo/issues/99","title":"[devflow-retrospective] meta: t-existing — x"}]' ;;
  *"issue comment"*) echo 'commented' ;;
  *"issues/"*"/labels"*) printf '%s' "$*" > "$D/edit-args" ;;   # REST label apply (apply-labels.sh)
  *"--method POST"*"/labels"*) echo '{}' ;;                       # REST label create (ensure-label.sh)
  *) echo '' ;;
esac
STUB
chmod +x "$MI_TMP/gh"
URL2="$(DEVFLOW_GH="$MI_TMP/gh" bash "$LIB/meta-issue.sh" --tag t-existing --slug t-existing --title "x" --body-file "$MI_TMP/body.md" --overrides "$MI_TMP/ov.json" 2>/dev/null)"
assert_eq "meta-issue reuses existing URL" "https://github.com/acme/example-repo/issues/99" "$URL2"
assert_eq "meta-issue stamps labels on the existing issue #99 (REST issues/99/labels)" "true" \
  "$(grep -qF -- 'issues/99/labels' "$MI_TMP/edit-args" && echo true || echo false)"
# #152: fail CLOSED on a create that returns no usable issue URL. `gh issue create`
# can exit 0 with empty/garbage stdout; without the URL-shape guard meta-issue.sh
# would report a phantom filing AND write a permanent overrides.json cooldown for
# an issue that never existed (the "never report unfiled as filed" invariant). The
# guard must exit non-zero so the orchestrator records a blocker, and must NOT have
# written a dismissal for the slug.
echo '{"schema_version":1,"dismissed":{}}' > "$MI_TMP/ov2.json"
cat > "$MI_TMP/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"issue list"*) echo '' ;;            # no existing issue → create path
  *"issue create"*) echo '' ;;          # exit 0 but NO url
  *) echo '' ;;
esac
STUB
chmod +x "$MI_TMP/gh"
DEVFLOW_GH="$MI_TMP/gh" bash "$LIB/meta-issue.sh" --tag empty-url --slug empty-url --title "x" --body-file "$MI_TMP/body.md" --overrides "$MI_TMP/ov2.json" >/dev/null 2>&1; EMPTY_RC=$?
assert_eq "meta-issue fails closed on empty create URL (non-zero exit)" "true" \
  "$([ "$EMPTY_RC" -ne 0 ] && echo true || echo false)"
assert_eq "meta-issue wrote NO cooldown on empty create URL" "false" \
  "$(jq -e '.dismissed | has("empty-url")' "$MI_TMP/ov2.json" >/dev/null 2>&1 && echo true || echo false)"
# garbage (non-URL) stdout → same fail-closed
cat > "$MI_TMP/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"issue list"*) echo '' ;;
  *"issue create"*) echo 'could not create issue: HTTP 403' ;;
  *) echo '' ;;
esac
STUB
chmod +x "$MI_TMP/gh"
DEVFLOW_GH="$MI_TMP/gh" bash "$LIB/meta-issue.sh" --tag garbage-url --slug garbage-url --title "x" --body-file "$MI_TMP/body.md" --overrides "$MI_TMP/ov2.json" >/dev/null 2>&1; GARBAGE_RC=$?
assert_eq "meta-issue fails closed on garbage create stdout (non-zero exit)" "true" \
  "$([ "$GARBAGE_RC" -ne 0 ] && echo true || echo false)"
# de-dup lookup failure (gh issue list non-zero) → exit 1 (orchestrator blocker trigger)
cat > "$MI_TMP/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"issue list"*) exit 1 ;;
  *) echo '' ;;
esac
STUB
chmod +x "$MI_TMP/gh"
DEVFLOW_GH="$MI_TMP/gh" bash "$LIB/meta-issue.sh" --tag lookup-fail --slug lookup-fail --title "x" --body-file "$MI_TMP/body.md" --overrides "$MI_TMP/ov2.json" >/dev/null 2>&1; LOOKUP_RC=$?
assert_eq "meta-issue fails closed on de-dup lookup error (non-zero exit)" "true" \
  "$([ "$LOOKUP_RC" -ne 0 ] && echo true || echo false)"
# #152: de-dup lookup that exits 0 with a NON-JSON body (auth/upgrade warning on
# stdout, HTML error page) must fail CLOSED at the jq parse, not flow on as "no
# existing issue" and re-file a duplicate. Mirrors actionable-patterns.sh's
# non-JSON cooldown guard (the sibling consumer of the same gh contract).
cat > "$MI_TMP/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"issue list"*) echo 'gh: not authenticated' ;;   # exit 0 but non-JSON
  *) echo '' ;;
esac
STUB
chmod +x "$MI_TMP/gh"
DEVFLOW_GH="$MI_TMP/gh" bash "$LIB/meta-issue.sh" --tag nonjson-lookup --slug nonjson-lookup --title "x" --body-file "$MI_TMP/body.md" --overrides "$MI_TMP/ov2.json" >/dev/null 2>&1; NONJSON_RC=$?
assert_eq "meta-issue fails closed on a non-JSON de-dup body (non-zero exit)" "true" \
  "$([ "$NONJSON_RC" -ne 0 ] && echo true || echo false)"
# --dry-run: records the DRYRUN sentinel, invokes NO issue create / issue edit
echo '{"schema_version":1,"dismissed":{}}' > "$MI_TMP/ov3.json"
cat > "$MI_TMP/gh" <<'STUB'
#!/usr/bin/env bash
D="$(dirname "$0")"
case "$*" in
  *"issue list"*) echo '' ;;
  *"issue create"*) echo "CREATE_CALLED" >> "$D/calls" ; echo '' ;;
  *"issue edit"*) echo "EDIT_CALLED" >> "$D/calls" ;;
  *) echo '' ;;
esac
STUB
chmod +x "$MI_TMP/gh"
rm -f "$MI_TMP/calls"
DRY_URL="$(DEVFLOW_GH="$MI_TMP/gh" bash "$LIB/meta-issue.sh" --dry-run --tag dry --slug dry --title "x" --body-file "$MI_TMP/body.md" --overrides "$MI_TMP/ov3.json" 2>/dev/null)"
assert_eq "meta-issue --dry-run prints the DRYRUN sentinel" "https://example.invalid/issues/DRYRUN" "$DRY_URL"
assert_eq "meta-issue --dry-run invokes no gh create/edit" "true" \
  "$([ ! -f "$MI_TMP/calls" ] && echo true || echo false)"
# #152: de-dup HIT path also fails closed on a garbage url/number (gh --json drift
# emitting a null number/url) — mirrors the create-path guard.
cat > "$MI_TMP/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"issue list"*) echo '[{"number":null,"url":null,"title":"[devflow-retrospective] meta: dedup-null — x"}]' ;;   # contract drift: nulls
  *) echo '' ;;
esac
STUB
chmod +x "$MI_TMP/gh"
DEVFLOW_GH="$MI_TMP/gh" bash "$LIB/meta-issue.sh" --tag dedup-null --slug dedup-null --title "x" --body-file "$MI_TMP/body.md" --overrides "$MI_TMP/ov2.json" >/dev/null 2>&1; DEDUP_RC=$?
assert_eq "meta-issue fails closed on a de-dup hit with null url/number" "true" \
  "$([ "$DEDUP_RC" -ne 0 ] && echo true || echo false)"
# #152: the tokenized GitHub --search can surface an issue whose title does NOT
# literally carry `meta: ${TAG}` (a loose token hit). meta-issue.sh must STRICTLY
# re-parse the slug and reject the loose match — filing a NEW issue (create path)
# rather than commenting on / pinning the cooldown to the wrong issue. Here the
# only open issue's slug is `widget-foobar`; the requested tag is `widget` →
# no exact match → create path (returns the freshly created URL, not #88).
echo '{"schema_version":1,"dismissed":{}}' > "$MI_TMP/ov-loose.json"
cat > "$MI_TMP/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"issue list"*) echo '[{"number":88,"url":"https://github.com/acme/example-repo/issues/88","title":"[devflow-retrospective] meta: widget-foobar — loose"}]' ;;
  *"issue create"*) echo 'https://github.com/acme/example-repo/issues/4343' ;;
  *"issue edit"*) : ;;
  *"label create"*) echo 'created' ;;
  *) echo '' ;;
esac
STUB
chmod +x "$MI_TMP/gh"
LOOSE_URL="$(DEVFLOW_GH="$MI_TMP/gh" bash "$LIB/meta-issue.sh" --tag widget --slug widget --title "x" --body-file "$MI_TMP/body.md" --overrides "$MI_TMP/ov-loose.json" 2>/dev/null)"
assert_eq "meta-issue strict-rejects a loose --search slug match (files new, not #88)" "https://github.com/acme/example-repo/issues/4343" "$LOOSE_URL"
# #152: overrides-write failure AFTER a successful create reports FILED, not
# blocked — a corrupt overrides file makes the jq cooldown write fail, but the
# issue genuinely exists, so meta-issue.sh must exit 0 with the URL on stdout
# (the orchestrator records the filing) and leave a loud ::error:: breadcrumb;
# the open-issue de-dupe self-heals the missing cooldown next run. Reporting
# "not filed" here would lose a real issue.
printf 'not json{' > "$MI_TMP/ov-corrupt.json"
cat > "$MI_TMP/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"issue list"*) echo '' ;;
  *"issue create"*) echo 'https://github.com/acme/example-repo/issues/7777' ;;
  *"issue edit"*) : ;;
  *"label create"*) echo 'created' ;;
  *) echo '' ;;
esac
STUB
chmod +x "$MI_TMP/gh"
OVFAIL_OUT="$(DEVFLOW_GH="$MI_TMP/gh" bash "$LIB/meta-issue.sh" --tag ov-fail --slug ov-fail --title "x" --body-file "$MI_TMP/body.md" --overrides "$MI_TMP/ov-corrupt.json" 2>"$MI_TMP/ov-fail.err")"; OVFAIL_RC=$?
assert_eq "meta-issue reports FILED on a cooldown-write failure (exit 0)" "true" \
  "$([ "$OVFAIL_RC" -eq 0 ] && echo true || echo false)"
assert_eq "meta-issue still prints the filed URL on a cooldown-write failure" "https://github.com/acme/example-repo/issues/7777" "$OVFAIL_OUT"
assert_eq "meta-issue leaves a 'WAS filed' breadcrumb on a cooldown-write failure" "true" \
  "$(grep -q 'issue WAS filed' "$MI_TMP/ov-fail.err" && echo true || echo false)"

# #152: --dry-run must NOT mutate the real overrides.json — a dry run that records
# the DRYRUN sentinel as a dismissal would make a later live run skip the real
# filing. The dismissed map must stay empty after a dry run.
echo '{"schema_version":1,"dismissed":{}}' > "$MI_TMP/ov-dry.json"
cat > "$MI_TMP/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"issue list"*) echo '' ;;
  *) echo '' ;;
esac
STUB
chmod +x "$MI_TMP/gh"
DEVFLOW_GH="$MI_TMP/gh" bash "$LIB/meta-issue.sh" --dry-run --tag dry-ov --slug dry-ov --title "x" --body-file "$MI_TMP/body.md" --overrides "$MI_TMP/ov-dry.json" >/dev/null 2>&1
assert_eq "meta-issue --dry-run writes NO cooldown to overrides" "false" \
  "$(jq -e '.dismissed | has("dry-ov")' "$MI_TMP/ov-dry.json" >/dev/null 2>&1 && echo true || echo false)"

# #152: TAG carrying a GitHub search qualifier / whitespace is rejected at
# arg-parse (before it reaches the de-dupe --search), so a drift fails loud
# instead of mis-routing the lookup and re-filing a duplicate.
DEVFLOW_GH="$MI_TMP/gh" bash "$LIB/meta-issue.sh" --tag 'foo in:body' --slug foo --title "x" --body-file "$MI_TMP/body.md" --overrides "$MI_TMP/ov-dry.json" >/dev/null 2>&1; BADTAG_RC=$?
assert_eq "meta-issue rejects a non-slug --tag (non-zero exit)" "true" \
  "$([ "$BADTAG_RC" -ne 0 ] && echo true || echo false)"
# #152: the overrides `dismissed_at` records WHEN the pattern was first dismissed
# (a permanent cross-run exclusion an auditor reads). The Step-1 de-dupe re-runs
# the Step-2 write on every recurrence, so the ORIGINAL stamp must be PRESERVED,
# never bumped to "now" — otherwise the dismissal age drifts perpetually forward.
echo '{"schema_version":1,"dismissed":{"recur":{"dismissed_at":"2020-01-01T00:00:00Z","dismissed_by":"retrospective-weekly","reason":"meta-plugin-issue","meta_issue":"https://github.com/acme/example-repo/issues/55"}}}' > "$MI_TMP/ov-recur.json"
cat > "$MI_TMP/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"issue list"*) echo '[{"number":55,"url":"https://github.com/acme/example-repo/issues/55","title":"[devflow-retrospective] meta: recur — x"}]' ;;  # de-dup HIT
  *"issue comment"*) echo 'commented' ;;
  *"issue edit"*) : ;;
  *"label create"*) echo 'created' ;;
  *) echo '' ;;
esac
STUB
chmod +x "$MI_TMP/gh"
DEVFLOW_GH="$MI_TMP/gh" bash "$LIB/meta-issue.sh" --tag recur --slug recur --title "x" --body-file "$MI_TMP/body.md" --overrides "$MI_TMP/ov-recur.json" >/dev/null 2>&1
assert_eq "meta-issue preserves the original dismissed_at on a recurrence" "2020-01-01T00:00:00Z" \
  "$(jq -r '.dismissed["recur"].dismissed_at' "$MI_TMP/ov-recur.json")"
rm -rf "$MI_TMP"

# ────────────────────────────────────────────────────────────────────────────
echo "render-report.sh / open-state-pr.sh / post-status.sh"
# ────────────────────────────────────────────────────────────────────────────
( . "$LIB/render-report.sh"
  # #152: the loop files issues, not PRs — a single intervention_issues[] list
  # ({tag, url}) replaces the old intervention_prs[] + meta_issues[] split.
  SUM='{"prs_scanned":8,"clean_count":3,"analyzed_count":5,"intervention_issues":[{"tag":"implement-review-miss","url":"https://x/issues/901"},{"tag":"review-reject-bypassed","url":"https://x/issues/9"}],"cooldown_skipped":["doc-inventory-inaccuracy"],"blockers":[],"state_pr":900}'
  REPORT="$(devflow_render_report "$SUM")"
  assert_eq "report has marker"        "true" "$(echo "$REPORT" | head -1 | grep -qF '<!-- devflow:audit-report -->' && echo true || echo false)"
  assert_eq "report shows prs_scanned"  "true" "$(echo "$REPORT" | grep -q '8' && echo true || echo false)"
  assert_eq "report has Issues filed section" "true" "$(echo "$REPORT" | grep -q '## Issues filed' && echo true || echo false)"
  assert_eq "report lists filed issue tag" "true" "$(echo "$REPORT" | grep -q 'implement-review-miss' && echo true || echo false)"
  assert_eq "report lists second filed tag" "true" "$(echo "$REPORT" | grep -q 'review-reject-bypassed' && echo true || echo false)"
  assert_eq "report lists cooldown tag" "true" "$(echo "$REPORT" | grep -q 'doc-inventory-inaccuracy' && echo true || echo false)"
  # #152: the pruned audit path leaves no "Intervention PRs" / "Meta-issues" headers
  assert_eq "no Intervention PRs section" "false" "$(echo "$REPORT" | grep -q '## Intervention PRs' && echo true || echo false)"
  assert_eq "no Meta-issues section"      "false" "$(echo "$REPORT" | grep -q '## Meta-issues filed' && echo true || echo false)"
  # empty filed list → explicit "_None filed._"
  SUM_NONE='{"prs_scanned":1,"clean_count":1,"analyzed_count":0,"intervention_issues":[],"cooldown_skipped":[],"blockers":[],"state_pr":1}'
  assert_eq "empty Issues filed shows None" "true" "$(devflow_render_report "$SUM_NONE" | grep -qF '_None filed._' && echo true || echo false)"
  # #7c: omit the new sections when the keys aren't supplied
  assert_eq "no Analyzed section without data" "false" "$(echo "$REPORT" | grep -q '### Analyzed PRs' && echo true || echo false)"
  assert_eq "no Patterns section without data" "false" "$(echo "$REPORT" | grep -q '## Patterns this run' && echo true || echo false)"
  # #7c: render them when supplied
  SUM2='{"prs_scanned":2,"clean_count":0,"analyzed_count":2,"analyzed":[{"pr":771,"verdict":"imperfect","summary":"merged over an outstanding /review REJECT"},{"pr":789,"verdict":"imperfect","summary":"internal doc listed files that no longer match"}],"patterns":[{"tag":"merged-over-review-reject","slug":"merged-over-review-reject","occurrence_count":2,"status":"open","cooldown_active":false},{"tag":"old-pattern","slug":"old-pattern","occurrence_count":3,"status":"open","cooldown_active":true}],"intervention_issues":[],"cooldown_skipped":["old-pattern"],"blockers":[],"state_pr":810}'
  REPORT2="$(devflow_render_report "$SUM2")"
  assert_eq "Analyzed section present"        "true" "$(echo "$REPORT2" | grep -q '### Analyzed PRs' && echo true || echo false)"
  assert_eq "Analyzed line for PR 771"        "true" "$(echo "$REPORT2" | grep -q '#771 — imperfect: merged over an outstanding' && echo true || echo false)"
  assert_eq "Patterns section present"        "true" "$(echo "$REPORT2" | grep -q '## Patterns this run' && echo true || echo false)"
  assert_eq "Patterns sorted by count desc"   "true" "$(echo "$REPORT2" | grep -A2 '## Patterns this run' | grep -q 'old-pattern.*3×' && echo true || echo false)"
  assert_eq "cooldown pattern annotated"      "true" "$(echo "$REPORT2" | grep -q 'old-pattern.*cooldown, skipped this run' && echo true || echo false)"
)
OSPR="$(bash "$LIB/open-state-pr.sh" --branch devflow/learnings-test --dry-run 2>/dev/null)"
assert_eq "open-state-pr dry-run echoes DRYRUN" "true" "$(echo "$OSPR" | grep -q 'DRYRUN' && echo true || echo false)"
assert_eq "open-state-pr dry-run mentions git push" "true" "$(echo "$OSPR" | grep -qi 'git push' && echo true || echo false)"
PSR="$(echo '<!-- devflow:audit-report -->' > /tmp/devflow-test-report.md; bash "$LIB/post-status.sh" --pr 900 --report-file /tmp/devflow-test-report.md --dry-run 2>/dev/null; rm -f /tmp/devflow-test-report.md)"
assert_eq "post-status dry-run echoes DRYRUN" "true" "$(echo "$PSR" | grep -q 'DRYRUN' && echo true || echo false)"

# ────────────────────────────────────────────────────────────────────────────
echo "dismiss-stale-rejections.sh"
# ────────────────────────────────────────────────────────────────────────────
DSR="$LIB/../scripts/dismiss-stale-rejections.sh"

( bash "$DSR" >/dev/null 2>&1 ); DSR_RC=$?
assert_eq "no args → exit 2" "2" "$DSR_RC"

# Security-critical: the review-selection filter must dismiss ONLY open
# Devflow-report reviews — never a human --request-changes (id 2), an
# already-dismissed one (id 3), or a null-body row (id 4).
DSR_SEL="$(printf '%s' '[
 {"id":1,"state":"CHANGES_REQUESTED","body":"# Review Report\n## Verdict: REJECT"},
 {"id":2,"state":"CHANGES_REQUESTED","body":"please fix the typo"},
 {"id":3,"state":"DISMISSED","body":"# Review Report\n## Verdict: REJECT"},
 {"id":4,"state":"CHANGES_REQUESTED","body":null}
]' | jq -r '.[] | select(.state=="CHANGES_REQUESTED" and ((.body // "") | startswith("# Review Report"))) | .id' | tr '\n' ',')"
assert_eq "filter selects only open Devflow-report rejects" "1," "$DSR_SEL"

DSR_STUB="/tmp/devflow-gh-stub-dsr.$$.sh"
cat > "$DSR_STUB" <<'EOS'
#!/usr/bin/env bash
# dismissals URLs also contain "/reviews" — match the more specific arm
# first, and give every arm a deterministic exit status.
case "$*" in
  *"dismissals"*)         [ "${DSR_STUB_PUT_RC:-0}" = 0 ] || { echo "HTTP 422" >&2; exit 1; }; exit 0 ;;
  *"repo view"*)          echo "o/r"; exit 0 ;;
  *"pulls/"*"/reviews"*)  if [ -n "${DSR_STUB_IDS:-}" ]; then echo "$DSR_STUB_IDS"; fi; exit 0 ;;
esac
exit 0
EOS
chmod +x "$DSR_STUB"

( DSR_STUB_IDS="" DEVFLOW_GH="$DSR_STUB" bash "$DSR" 123 o/r >/dev/null 2>&1 ); DSR_RC=$?
assert_eq "empty selection → exit 0 no-op" "0" "$DSR_RC"

( DSR_STUB_IDS="77" DSR_STUB_PUT_RC=0 DEVFLOW_GH="$DSR_STUB" bash "$DSR" 123 o/r >/dev/null 2>&1 ); DSR_RC=$?
assert_eq "successful dismissal → exit 0" "0" "$DSR_RC"

( DSR_STUB_IDS="77" DSR_STUB_PUT_RC=1 DEVFLOW_GH="$DSR_STUB" bash "$DSR" 123 o/r >/dev/null 2>&1 ); DSR_RC=$?
assert_eq "dismissal failure → exit 1" "1" "$DSR_RC"
rm -f "$DSR_STUB"

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
di() { DEVFLOW_GH="$DI_STUB/gh" REPO=o/r RUN_ID="$1" CONTEXT_NUMBER="$2" \
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
  "$(DEVFLOW_GH="$DI_STUB/gh" REPO=o/r RUN_ID=200 CONTEXT_NUMBER=42 DEDUPE_GH_RC=1 bash "$DIR" 2>/dev/null)"

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
DEVFLOW_GH="$DI_STUB/gh" REPO=o/r RUN_ID=200 CONTEXT_NUMBER=42 DEDUPE_RUNS_JSON='[]' \
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
echo "resolve-command-trigger.sh"
# ────────────────────────────────────────────────────────────────────────────
# Light command dispatch (review / review-and-fix / pr-description) in AGENT
# mode. Authorizes the sender (allowed bot bypasses gh; otherwise allowed_users
# + collaborator), detects the command, and resolves a target number. Reuses
# gh-stub.sh (alice → write collaborator; any other actor → HTTP 404).
RCT="$LIB/../scripts/resolve-command-trigger.sh"
RCT_STUB="$(mktemp -d)"; cp "$LIB/test/fixtures/gh-stub.sh" "$RCT_STUB/gh"; chmod +x "$RCT_STUB/gh"

# 1. Allowed bot, /devflow:review with explicit number → review command.
OUT="$(PATH="$RCT_STUB:$PATH" ACTOR="devflow-bot" ALLOWED_BOTS="devflow-bot" \
  REPO="o/r" GH_TOKEN="x" CONTEXT_NUMBER="99" \
  TRIGGER_TEXT="/devflow:review #42" bash "$RCT")"
assert_eq "rct: review w/ explicit number → should_run" \
  "should_run=true" "$(echo "$OUT" | grep '^should_run=')"
assert_eq "rct: review w/ explicit number → command" \
  "command=/devflow:review 42" "$(echo "$OUT" | grep '^command=')"

# 2. review-and-fix must win over the /devflow:review substring it contains.
OUT="$(PATH="$RCT_STUB:$PATH" ACTOR="devflow-bot" ALLOWED_BOTS="devflow-bot" \
  REPO="o/r" GH_TOKEN="x" CONTEXT_NUMBER="7" \
  TRIGGER_TEXT="please run /devflow:review-and-fix now" bash "$RCT")"
assert_eq "rct: review-and-fix beats review substring → command" \
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

rm -rf "$RCT_STUB"

# ────────────────────────────────────────────────────────────────────────────
echo "react-to-trigger.sh"
# ────────────────────────────────────────────────────────────────────────────
# Early-ack reaction. Picks the reactions endpoint by event type, defaults the
# content to `rocket`, and skips events with no reactions API (reviews). A `gh`
# stub records the `api` call args to $REACT_REC so we can assert the endpoint.
RT="$LIB/../scripts/react-to-trigger.sh"
RT_STUB="$(mktemp -d)"
cat > "$RT_STUB/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$REACT_REC"
STUB
chmod +x "$RT_STUB/gh"

# Per-case vars go through `env` because words from "$@" expansion are NOT
# honored as assignment prefixes (POSIX recognizes only literal tokens).
react() { REACT_REC="$(mktemp)"; PATH="$RT_STUB:$PATH" REACT_REC="$REACT_REC" GH_TOKEN=x env "$@" bash "$RT" >/dev/null 2>&1; }

# 1. issue_comment → react on the issue comment, default content rocket.
react EVENT_NAME=issue_comment REPO=o/r COMMENT_ID=555
assert_eq "react: issue_comment → issues/comments endpoint w/ rocket" \
  "1" "$(grep -c 'repos/o/r/issues/comments/555/reactions.*content=rocket' "$REACT_REC")"
rm -f "$REACT_REC"

# 2. pull_request_review_comment → react on the PR review comment.
react EVENT_NAME=pull_request_review_comment REPO=o/r COMMENT_ID=777
assert_eq "react: review comment → pulls/comments endpoint" \
  "1" "$(grep -c 'repos/o/r/pulls/comments/777/reactions' "$REACT_REC")"
rm -f "$REACT_REC"

# 3. issues (opened) → react on the issue itself.
react EVENT_NAME=issues REPO=o/r ISSUE_NUMBER=42
assert_eq "react: issues event → issues/<n> endpoint" \
  "1" "$(grep -c 'repos/o/r/issues/42/reactions' "$REACT_REC")"
rm -f "$REACT_REC"

# 4. pull_request_review has no reactions API → no call at all.
react EVENT_NAME=pull_request_review REPO=o/r COMMENT_ID=1
assert_eq "react: review event makes no api call" \
  "0" "$(grep -c 'reactions' "$REACT_REC")"
rm -f "$REACT_REC"

# 5. REACTION env overrides the default content.
react EVENT_NAME=issue_comment REPO=o/r COMMENT_ID=9 REACTION=eyes
assert_eq "react: REACTION env overrides default content" \
  "1" "$(grep -c 'content=eyes' "$REACT_REC")"
rm -f "$REACT_REC"

# 6. gh failure (e.g. HTTP 403 from a missing write scope) must NOT fail the
# step — best-effort: the script swallows it, exits 0, and warns to stderr with
# the gh error one-lined. This is the load-bearing error branch the success
# stub above can't reach (it always exits 0). A separate stub that prints a
# multi-line error to stderr and exits 1 exercises both the exit-0 guarantee
# and the `${err//$'\n'/ }` collapse.
FAIL_STUB="$(mktemp -d)"
cat > "$FAIL_STUB/gh" <<'STUB'
#!/usr/bin/env bash
printf 'HTTP 403: Resource not accessible by integration\n(check issues/pull-requests write)\n' >&2
exit 1
STUB
chmod +x "$FAIL_STUB/gh"
# DEVFLOW_GH points at the stub EXPLICITLY: the stub fails `--version` (it exits 1
# for every arg), so with DEVFLOW_GH unset the resolver would reject it and — on a
# WSL host with Windows gh.exe interop — fall through to the REAL gh.exe, making a
# live network call and failing this test. The override path exists precisely to
# keep test stubs untouched; any PATH-only gh stub that does not answer
# `--version` with rc 0 must set DEVFLOW_GH the same way.
react_err="$(DEVFLOW_GH="$FAIL_STUB/gh" PATH="$FAIL_STUB:$PATH" GH_TOKEN=x EVENT_NAME=issue_comment REPO=o/r COMMENT_ID=1 bash "$RT" 2>&1 >/dev/null)"
assert_eq "react: gh failure still exits 0 (best-effort, never blocks the run)" "0" "$?"
assert_eq "react: gh failure warns to stderr" \
  "1" "$(printf '%s\n' "$react_err" | grep -c '::warning::react: could not add')"
assert_eq "react: multi-line gh error is collapsed to one log line" \
  "1" "$(printf '%s\n' "$react_err" | grep -c 'integration (check issues')"
rm -rf "$FAIL_STUB"

rm -rf "$RT_STUB"

# ────────────────────────────────────────────────────────────────────────────
echo "install.sh: prune_stale_devflow_workflows"
# ────────────────────────────────────────────────────────────────────────────
# On upgrade, install.sh must remove DevFlow's OWN superseded claude*.yml but
# NEVER an Anthropic-owned claude.yml. Source the installer with
# DEVFLOW_SELFTEST=1 (defines the functions, skips the installer body) and run
# the prune function against throwaway repos.
INSTALL="$LIB/../install.sh"

# Case A: DevFlow-signed claude.yml + stale runner/implement → all removed.
WORK="$(mktemp -d)"; mkdir -p "$WORK/.github/workflows"
printf '%s\n' "name: Claude Code" "  review_dedupe:" > "$WORK/.github/workflows/claude.yml"
echo "name: Claude Runner (reusable)" > "$WORK/.github/workflows/claude-runner.yml"
echo "name: Claude Code (implement)" > "$WORK/.github/workflows/claude-implement.yml"
# shellcheck disable=SC1090  # sources install.sh at runtime under DEVFLOW_SELFTEST
( cd "$WORK" && DEVFLOW_SELFTEST=1 . "$INSTALL" && prune_stale_devflow_workflows ) >/dev/null 2>&1
assert_eq "install: devflow-signed claude.yml removed" \
  "absent" "$([ -f "$WORK/.github/workflows/claude.yml" ] && echo present || echo absent)"
assert_eq "install: stale claude-runner.yml removed" \
  "absent" "$([ -f "$WORK/.github/workflows/claude-runner.yml" ] && echo present || echo absent)"
assert_eq "install: stale claude-implement.yml removed" \
  "absent" "$([ -f "$WORK/.github/workflows/claude-implement.yml" ] && echo present || echo absent)"
rm -rf "$WORK"

# Case B: Anthropic's own claude.yml (no DevFlow signature) → preserved.
WORK="$(mktemp -d)"; mkdir -p "$WORK/.github/workflows"
printf '%s\n' "name: Claude Code" "  claude:" "    uses: anthropics/claude-code-action@v1" \
  > "$WORK/.github/workflows/claude.yml"
# shellcheck disable=SC1090
( cd "$WORK" && DEVFLOW_SELFTEST=1 . "$INSTALL" && prune_stale_devflow_workflows ) >/dev/null 2>&1
assert_eq "install: Anthropic claude.yml preserved" \
  "present" "$([ -f "$WORK/.github/workflows/claude.yml" ] && echo present || echo absent)"
rm -rf "$WORK"

# ────────────────────────────────────────────────────────────────────────────
echo "install.sh: prune_stale_vendored_plugin"
# ────────────────────────────────────────────────────────────────────────────
# On upgrade, install.sh must remove a stale committed plugin at the OLD
# .claude/plugins/devflow location (relocated to .devflow/vendor/devflow), but
# ONLY when it is actually DevFlow's plugin, and must never remove a non-empty
# user .claude/ directory.

# Case A: a DevFlow-signed tree at the old path → removed, empty parents pruned.
WORK="$(mktemp -d)"; mkdir -p "$WORK/.claude/plugins/devflow/.claude-plugin"
printf '{"name":"devflow"}' > "$WORK/.claude/plugins/devflow/.claude-plugin/plugin.json"
# shellcheck disable=SC1090
( cd "$WORK" && DEVFLOW_SELFTEST=1 . "$INSTALL" && prune_stale_vendored_plugin ) >/dev/null 2>&1
assert_eq "install: stale committed .claude/plugins/devflow removed" \
  "absent" "$([ -d "$WORK/.claude/plugins/devflow" ] && echo present || echo absent)"
assert_eq "install: emptied .claude/ pruned" \
  "absent" "$([ -d "$WORK/.claude" ] && echo present || echo absent)"
rm -rf "$WORK"

# Case B: a non-DevFlow plugin.json at that path → preserved (signature guard).
WORK="$(mktemp -d)"; mkdir -p "$WORK/.claude/plugins/devflow/.claude-plugin"
printf '{"name":"not-devflow"}' > "$WORK/.claude/plugins/devflow/.claude-plugin/plugin.json"
# shellcheck disable=SC1090
( cd "$WORK" && DEVFLOW_SELFTEST=1 . "$INSTALL" && prune_stale_vendored_plugin ) >/dev/null 2>&1
assert_eq "install: non-devflow .claude/plugins/devflow preserved" \
  "present" "$([ -d "$WORK/.claude/plugins/devflow" ] && echo present || echo absent)"
rm -rf "$WORK"

# Case C: DevFlow tree removed but a non-empty .claude/ (other content) is kept.
WORK="$(mktemp -d)"; mkdir -p "$WORK/.claude/plugins/devflow/.claude-plugin" "$WORK/.claude/skills"
printf '{"name":"devflow"}' > "$WORK/.claude/plugins/devflow/.claude-plugin/plugin.json"
printf 'x' > "$WORK/.claude/skills/keep.md"
# shellcheck disable=SC1090
( cd "$WORK" && DEVFLOW_SELFTEST=1 . "$INSTALL" && prune_stale_vendored_plugin ) >/dev/null 2>&1
assert_eq "install: devflow tree removed under non-empty .claude" \
  "absent" "$([ -d "$WORK/.claude/plugins/devflow" ] && echo present || echo absent)"
assert_eq "install: emptied .claude/plugins parent pruned, non-empty .claude kept" \
  "absent-present" "$([ -d "$WORK/.claude/plugins" ] && echo present || echo absent)-$([ -d "$WORK/.claude" ] && echo present || echo absent)"
assert_eq "install: non-empty user .claude/ preserved" \
  "present" "$([ -f "$WORK/.claude/skills/keep.md" ] && echo present || echo absent)"
rm -rf "$WORK"

# Case D: no old tree at all (the common thin-install path) → clean no-op, exit 0,
# and an unrelated .claude/ is untouched.
WORK="$(mktemp -d)"; mkdir -p "$WORK/.claude/skills"; printf 'x' > "$WORK/.claude/skills/keep.md"
# shellcheck disable=SC1090
( cd "$WORK" && DEVFLOW_SELFTEST=1 . "$INSTALL" && prune_stale_vendored_plugin ) >/dev/null 2>&1
assert_eq "install: prune is a clean no-op when no old tree exists" "0" "$?"
assert_eq "install: prune leaves unrelated .claude/ untouched when no old tree" \
  "present" "$([ -f "$WORK/.claude/skills/keep.md" ] && echo present || echo absent)"
rm -rf "$WORK"

# Case E: old dir exists but carries no devflow plugin.json (partial/interrupted
# install) → left in place (not blindly removed), exit 0.
WORK="$(mktemp -d)"; mkdir -p "$WORK/.claude/plugins/devflow/scripts"
printf 'x' > "$WORK/.claude/plugins/devflow/scripts/stray.sh"
# shellcheck disable=SC1090
( cd "$WORK" && DEVFLOW_SELFTEST=1 . "$INSTALL" && prune_stale_vendored_plugin ) >/dev/null 2>&1
assert_eq "install: unsigned old tree is a clean exit" "0" "$?"
assert_eq "install: unsigned old tree is left untouched" \
  "present" "$([ -d "$WORK/.claude/plugins/devflow" ] && echo present || echo absent)"
rm -rf "$WORK"

# ────────────────────────────────────────────────────────────────────────────
echo "install.sh: manage_vendor_gitignore"
# ────────────────────────────────────────────────────────────────────────────
# Thin installs must ignore the runtime-vendored .devflow/vendor/ tree so a
# cloud run's `git add -A` never commits it; DEVFLOW_VENDOR=1 commits it on
# purpose, so the ignore line must be absent there. Patterns are relative to
# .devflow/, matching the scaffolded `/tmp/` entry.

# Case A: thin install (DEVFLOW_VENDOR unset) → /vendor/ appended, /tmp/ kept.
WORK="$(mktemp -d)"; mkdir -p "$WORK/.devflow"; printf '/tmp/\n' > "$WORK/.devflow/.gitignore"
# shellcheck disable=SC1090
( cd "$WORK" && DEVFLOW_SELFTEST=1 . "$INSTALL" && manage_vendor_gitignore ) >/dev/null 2>&1
assert_eq "install: thin install ignores /vendor/" \
  "yes" "$(grep -qxF '/vendor/' "$WORK/.devflow/.gitignore" && echo yes || echo no)"
assert_eq "install: thin install keeps /tmp/" \
  "yes" "$(grep -qxF '/tmp/' "$WORK/.devflow/.gitignore" && echo yes || echo no)"
# Idempotent: a second run does not duplicate the line.
# shellcheck disable=SC1090
( cd "$WORK" && DEVFLOW_SELFTEST=1 . "$INSTALL" && manage_vendor_gitignore ) >/dev/null 2>&1
assert_eq "install: thin /vendor/ ignore is idempotent" \
  "1" "$(grep -cxF '/vendor/' "$WORK/.devflow/.gitignore")"
rm -rf "$WORK"

# Case B: DEVFLOW_VENDOR=1 → a previously-added /vendor/ line is removed, /tmp/ kept.
WORK="$(mktemp -d)"; mkdir -p "$WORK/.devflow"; printf '/tmp/\n/vendor/\n' > "$WORK/.devflow/.gitignore"
# shellcheck disable=SC1090
( cd "$WORK" && DEVFLOW_SELFTEST=1 . "$INSTALL" && DEVFLOW_VENDOR=1 manage_vendor_gitignore ) >/dev/null 2>&1
assert_eq "install: DEVFLOW_VENDOR=1 un-ignores /vendor/" \
  "no" "$(grep -qxF '/vendor/' "$WORK/.devflow/.gitignore" && echo yes || echo no)"
assert_eq "install: DEVFLOW_VENDOR=1 keeps /tmp/" \
  "yes" "$(grep -qxF '/tmp/' "$WORK/.devflow/.gitignore" && echo yes || echo no)"
rm -rf "$WORK"

# Case C: no scaffolded .gitignore → no-op, no crash (exit 0).
WORK="$(mktemp -d)"; mkdir -p "$WORK/.devflow"
# shellcheck disable=SC1090
( cd "$WORK" && DEVFLOW_SELFTEST=1 . "$INSTALL" && manage_vendor_gitignore ) >/dev/null 2>&1
assert_eq "install: missing .gitignore is a clean no-op" \
  "0" "$?"
assert_eq "install: no .gitignore created when absent" \
  "absent" "$([ -f "$WORK/.devflow/.gitignore" ] && echo present || echo absent)"
rm -rf "$WORK"

# Case D: DEVFLOW_VENDOR=1 when /vendor/ is already absent → steady-state no-op,
# /tmp/ kept (symmetric to the thin-side idempotency check above).
WORK="$(mktemp -d)"; mkdir -p "$WORK/.devflow"; printf '/tmp/\n' > "$WORK/.devflow/.gitignore"
# shellcheck disable=SC1090
( cd "$WORK" && DEVFLOW_SELFTEST=1 . "$INSTALL" && DEVFLOW_VENDOR=1 manage_vendor_gitignore ) >/dev/null 2>&1
assert_eq "install: DEVFLOW_VENDOR=1 with /vendor/ already absent keeps it absent" \
  "no" "$(grep -qxF '/vendor/' "$WORK/.devflow/.gitignore" && echo yes || echo no)"
assert_eq "install: DEVFLOW_VENDOR=1 steady-state keeps /tmp/" \
  "yes" "$(grep -qxF '/tmp/' "$WORK/.devflow/.gitignore" && echo yes || echo no)"
rm -rf "$WORK"

# Case E: DEVFLOW_VENDOR=1 when /vendor/ is the ONLY line (the empty-filter edge
# the grep-exit-1 handling exists for) → removed cleanly, file left empty, exit 0.
WORK="$(mktemp -d)"; mkdir -p "$WORK/.devflow"; printf '/vendor/\n' > "$WORK/.devflow/.gitignore"
# shellcheck disable=SC1090
( cd "$WORK" && DEVFLOW_SELFTEST=1 . "$INSTALL" && DEVFLOW_VENDOR=1 manage_vendor_gitignore ) >/dev/null 2>&1
assert_eq "install: DEVFLOW_VENDOR=1 removes /vendor/ when it is the only line" "0" "$?"
assert_eq "install: only-line /vendor/ removal leaves no /vendor/" \
  "no" "$(grep -qxF '/vendor/' "$WORK/.devflow/.gitignore" && echo yes || echo no)"
rm -rf "$WORK"

# ────────────────────────────────────────────────────────────────────────────
echo "no stale .claude/plugins/devflow reference in shipped cloud-tier files"
# ────────────────────────────────────────────────────────────────────────────
# Locks the invariant this relocation establishes: the runtime-vendored plugin
# lives at .devflow/vendor/devflow, so no workflow, composite action, or config
# schema may reference the old .claude/plugins/devflow path (a stale reference
# fails closed at runtime — "resolver not found" / wiped plugin). install.sh and
# the test file are not in the scan scope (it covers only `.github` +
# config.schema.json) — they legitimately name the old path (the prune migration
# that removes it, and these tests), and there is no exclusion filter to maintain.
# NB: no `xargs -r` — that flag is GNU-only (BSD/macOS xargs rejects it), and
# CONTRIBUTING bans GNU-only flags. The `git ls-files` input is always non-empty
# (.devflow/config.schema.json + the .github workflows are tracked), so the
# no-run-if-empty behavior `-r` provides is never needed here.
STALE=$(cd "$LIB/.." && git ls-files .github .devflow/config.schema.json \
  | xargs grep -lF '.claude/plugins/devflow' 2>/dev/null || true)
assert_eq "install: no shipped cloud-tier file references the old vendored path" \
  "" "$STALE"

# The generated marketplace.json `source` is the one path-bearing installer
# output with no other coverage; a heredoc typo reverting it would ship to fresh
# consumers uncaught. Assert it matches the relocated vendor destination.
assert_eq "install: marketplace.json source matches the vendored path" \
  "1" "$(grep -cF '"source": "./.devflow/vendor/devflow"' "$LIB/../install.sh")"

# ────────────────────────────────────────────────────────────────────────────
echo "workflow partition invariant"
# ────────────────────────────────────────────────────────────────────────────
# Every gate `if:` line that matches a /devflow: command trigger must ALSO
# negate @claude on that same line, so no comment can fire both a DevFlow
# workflow and Anthropic's claude.yml. Covers devflow.yml (review/pr-description)
# and devflow-implement.yml (/devflow:implement).
WF="$LIB/../.github/workflows"
for f in devflow devflow-implement; do
  bad="$(grep -nE "contains\((github\.event[^)]*),[[:space:]]*'/devflow:(review|pr-description|implement)'\)" "$WF/$f.yml" \
        | grep -v "@claude" || true)"
  assert_eq "partition: $f.yml /devflow triggers all negate @claude" "" "$bad"
done

# The label trigger is gone: neither workflow may listen on `labeled`.
for f in devflow devflow-implement; do
  bad="$(grep -nE "^[[:space:]]*types:.*labeled" "$WF/$f.yml" || true)"
  assert_eq "partition: $f.yml has no labeled trigger" "" "$bad"
done

# Comment-only triggers: a /devflow:* phrase in an issue/PR DESCRIPTION must
# never start a run. Neither workflow may (a) listen on the `issues` event, nor
# (b) match the trigger phrase against an issue body/title in its gate `if:`.
# Only real comment/review bodies are valid trigger sources.
for f in devflow devflow-implement; do
  bad="$(grep -nE "^[[:space:]]*issues:[[:space:]]*$" "$WF/$f.yml" || true)"
  assert_eq "partition: $f.yml does not listen on the issues event" "" "$bad"
  # No gate matching against issue.body / issue.title (those are descriptions).
  bad="$(grep -nE "contains\(github\.event\.issue\.(body|title)" "$WF/$f.yml" || true)"
  assert_eq "partition: $f.yml gate never matches an issue body/title" "" "$bad"
  # TRIGGER_TEXT must be sourced only from comment/review bodies.
  bad="$(grep -nE "TRIGGER_TEXT:.*github\.event\.issue\.(body|title)" "$WF/$f.yml" || true)"
  assert_eq "partition: $f.yml TRIGGER_TEXT excludes issue body/title" "" "$bad"
done

# Issues-only scoping of the HEAVY path (issue #124). The primary defense lives
# in the workflow, not just the resolver unit tests above — so pin it here, or a
# future workflow edit could silently reopen #124 (a PR comment is also an
# issue_comment, so the audit-report comment self-triggers on the state PR) while
# the resolver-only tests stay green.
IMPL="$WF/devflow-implement.yml"
# (a) The heavy path must NOT subscribe to the PR-only review events at all.
assert_eq "partition: devflow-implement.yml is issues-only (no PR-review subscriptions)" \
  "0" "$(grep -cE 'pull_request_review(_comment)?:' "$IMPL")"
# (a+) Positive complement to (a): the heavy path MUST still subscribe to
#      issue_comment — its SOLE event entry point now. (a) is a negative check, so
#      without this a future edit that DELETES or renames the issue_comment
#      subscription would make the whole heavy path silently inert
#      (/devflow:implement never fires on any thread) while (a) still reads 0 and
#      every other test stays green — the over-narrowing twin of the bug (a) guards.
assert_eq "partition: devflow-implement.yml subscribes to issue_comment (sole event entry point)" \
  "1" "$(grep -cE '^[[:space:]]*issue_comment:[[:space:]]*$' "$IMPL")"
# (b) The gate if: must carry the PR-context filter (comment is on an issue, not
#     a PR). Match the gate-conjunct form (trailing ` &&`) so the prose mention of
#     the same expression in the header comment isn't counted.
assert_eq "partition: devflow-implement.yml gate if: filters PR comments (issue.pull_request == null)" \
  "1" "$(grep -cF 'github.event.issue.pull_request == null &&' "$IMPL")"
# (c) The resolver backstop is only wired if the workflow passes IS_PULL_REQUEST
#     from the canonical discriminator; a wrong expression (e.g. == null) would
#     invert the guard and decline issues instead of PRs.
assert_eq "partition: devflow-implement.yml wires IS_PULL_REQUEST from issue.pull_request != null" \
  "1" "$(grep -cF 'IS_PULL_REQUEST: ${{ github.event.issue.pull_request != null }}' "$IMPL")"
# (d) Complement (AC #5): the LIGHT path stays PR-aware — /devflow:review and
#     /devflow:pr-description act on PRs, so devflow.yml MUST keep its PR-review
#     subscriptions. Guards against an over-eager edit stripping them too.
assert_eq "partition: devflow.yml stays PR-aware (keeps PR-review subscriptions)" \
  "2" "$(grep -cE 'pull_request_review(_comment)?:' "$WF/devflow.yml")"

# Early-ack reaction must stay correctly wired in BOTH gate jobs. These guard
# the load-bearing properties that the react-to-trigger.sh unit tests above
# CANNOT see (they exercise the script in isolation): it must run only after
# authorization, the gate must hold the write scopes the POST needs, and it must
# be `bash`-invoked so it doesn't depend on the vendored copy's exec bit. Slice
# out just the gate job — `issues:/pull-requests: write` also appear on the
# heavy command/claude jobs, so a whole-file grep would not prove gate scoping.
gate_block() {
  awk '
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { inblock = ($0 ~ /^  gate:/) }
    inblock { print }
  ' "$1"
}
for f in devflow devflow-implement; do
  blk="$(gate_block "$WF/$f.yml")"
  # 1. Ack step is gated on resolver authorization — never reacts before should_run.
  guard="$(printf '%s\n' "$blk" | awk '/name: Acknowledge trigger/{f=1} f && /should_run ==/ {print "ok"; exit}')"
  assert_eq "react: $f.yml ack step gated on should_run" "ok" "$guard"
  # 2. Gate grants exactly the scopes the reactions POST needs.
  assert_eq "react: $f.yml gate grants issues:write" "1" \
    "$(printf '%s\n' "$blk" | grep -cE '^[[:space:]]+issues:[[:space:]]*write')"
  assert_eq "react: $f.yml gate grants pull-requests:write" "1" \
    "$(printf '%s\n' "$blk" | grep -cE '^[[:space:]]+pull-requests:[[:space:]]*write')"
  # 3. Invoked via `bash` (no exec-bit dependency on the vendored copy).
  bad="$(printf '%s\n' "$blk" | grep -nE 'run:.*react-to-trigger\.sh' | grep -v 'bash ' || true)"
  assert_eq "react: $f.yml invokes react-to-trigger.sh via bash" "" "$bad"
done

# ────────────────────────────────────────────────────────────────────────────
echo "opt-in GitHub App workflow-capable token (issue #201)"
# ────────────────────────────────────────────────────────────────────────────
# DevFlow's two CLOUD WRITERS — devflow-implement.yml (/devflow:implement) and the
# write-capable `command` job in devflow.yml (/devflow:review-and-fix) — push to the
# feature branch with the built-in GITHUB_TOKEN, which GitHub hard-blocks from
# editing .github/workflows/ files. An OPT-IN GitHub App credential lets those pushes
# succeed: each writer mints a short-lived App installation token (Contents: write +
# Workflows: write), gated on `vars.DEVFLOW_APP_ID != ''` so it is inert unless an
# operator configures it, and falls back to GITHUB_TOKEN when unset — byte-for-byte
# unchanged for consumers who do not opt in. The READ-ONLY runner (devflow-runner.yml)
# never edits files and MUST NOT receive a write-capable token, so it carries no mint
# step. These assertions pin the opt-in contract for all three workflows; they are the
# change's observable boundary (the issue's Testing Strategy maps each to an AC).
for f in devflow-implement devflow; do
  WFF="$WF/$f.yml"
  # (1) The conditional mint step exists, gated on the opt-in variable (AC 1, AC 3).
  assert_eq "app-token: $f.yml mints via actions/create-github-app-token" "1" \
    "$(grep -cE 'uses:[[:space:]]*actions/create-github-app-token@' "$WFF")"
  assert_eq "app-token: $f.yml mint step is gated on vars.DEVFLOW_APP_ID != ''" "1" \
    "$(grep -cF "vars.DEVFLOW_APP_ID != ''" "$WFF")"
  # (2) The mint step wires app-id from the variable and private-key from the secret
  #     (the coupled var/secret literals carried identically across .yml/.md/.sh).
  assert_eq "app-token: $f.yml mint step reads app-id from vars.DEVFLOW_APP_ID" "1" \
    "$(grep -cF 'app-id: ${{ vars.DEVFLOW_APP_ID }}' "$WFF")"
  assert_eq "app-token: $f.yml mint step reads private-key from secrets.DEVFLOW_APP_PRIVATE_KEY" "1" \
    "$(grep -cF 'private-key: ${{ secrets.DEVFLOW_APP_PRIVATE_KEY }}' "$WFF")"
  # (3) The claude-code-action step consumes the minted token with the GITHUB_TOKEN
  #     fallback — this fallback IS the unset-opt-in path that keeps behavior identical
  #     for non-adopters (AC 2, AC 5).
  assert_eq "app-token: $f.yml github_token falls back to secrets.GITHUB_TOKEN" "1" \
    "$(grep -cF 'github_token: ${{ steps.app-token.outputs.token || secrets.GITHUB_TOKEN }}' "$WFF")"
  # (4) Fail-loud (AC 6): the mint step must NOT carry continue-on-error, so a
  #     configured-but-broken App fails the job rather than silently degrading.
  blk="$(awk '/name: Mint workflow-capable token/{f=1} f{print} f&&/^      - name:/&&!/Mint workflow-capable/{exit}' "$WFF")"
  assert_eq "app-token: $f.yml mint step is fail-loud (no continue-on-error)" "" \
    "$(printf '%s\n' "$blk" | grep -E 'continue-on-error' || true)"
  # (4a) The step-id ↔ output-reference coupling (AC 2). The mint step MUST carry
  #      `id: app-token`, because the github_token expression consumes
  #      `steps.app-token.outputs.token`. Renaming the id (leaving the consumer line
  #      untouched) would resolve the output to empty on every run and silently and
  #      permanently fall the opt-in back to GITHUB_TOKEN — the exact silent
  #      degradation AC 6 exists to prevent, reached via a wiring typo. Pin the id
  #      inside the extracted mint-step block so the two coupled sites can't drift
  #      apart while the suite stays green.
  assert_eq "app-token: $f.yml mint step carries id: app-token (couples to steps.app-token.outputs.token)" "1" \
    "$(printf '%s\n' "$blk" | grep -cE '^[[:space:]]*id:[[:space:]]*app-token[[:space:]]*$')"
done
# (5) The read-only runner stays untouched: NO App-token mint step, and it keeps its
#     plain GITHUB_TOKEN (AC 4, AC 10).
assert_eq "app-token: devflow-runner.yml has NO create-github-app-token mint step" "0" \
  "$(grep -cE 'uses:[[:space:]]*actions/create-github-app-token@' "$WF/devflow-runner.yml")"
assert_eq "app-token: devflow-runner.yml mentions no DEVFLOW_APP_ID opt-in" "0" \
  "$(grep -cF 'DEVFLOW_APP_ID' "$WF/devflow-runner.yml")"
# (6) Docs carry the opt-in contract: the var, the secret, and BOTH required App
#     permissions (AC 7, AC 8, AC 9).
CS="$LIB/../docs/cloud-setup.md"
for tok in 'DEVFLOW_APP_ID' 'DEVFLOW_APP_PRIVATE_KEY'; do
  assert_eq "app-token: cloud-setup.md documents $tok" "yes" \
    "$(grep -qF "$tok" "$CS" && echo yes || echo no)"
done
assert_eq "app-token: cloud-setup.md documents Contents: write App permission" "yes" \
  "$(grep -qiE 'Contents:[[:space:]]*write' "$CS" && echo yes || echo no)"
assert_eq "app-token: cloud-setup.md documents Workflows: write App permission" "yes" \
  "$(grep -qiE 'Workflows:[[:space:]]*write' "$CS" && echo yes || echo no)"
# §15 of the overview must no longer claim a bare "No GitHub App" without the
# required/optional qualifier (AC 8).
OV="$LIB/../docs/DEVFLOW_SYSTEM_OVERVIEW.md"
assert_eq "app-token: overview §15 no longer asserts a bare 'No GitHub App.'" "0" \
  "$(grep -cF 'No GitHub App.' "$OV")"
# Positive complement to the negative check above (AC 8): the §15 reframe must
# actually mention the optional App by its opt-in variable, so the bullet can't lose
# all mention of the optional App and still pass on the old-string-absent check alone.
assert_eq "app-token: overview §15 positively documents the optional App (DEVFLOW_APP_ID)" "yes" \
  "$(grep -qF 'DEVFLOW_APP_ID' "$OV" && echo yes || echo no)"

# ────────────────────────────────────────────────────────────────────────────
echo "devflow-review.yml first-ready gate invariant"
# ────────────────────────────────────────────────────────────────────────────
# The first-ready gate counts pre-existing `Devflow Review` check-runs to enforce
# auto-review-exactly-once. A skipped job still emits a `Devflow Review` check-run
# (conclusion: skipped) — from the dual pull_request/pull_request_target dedupe
# loser and from draft/synchronize deferrals — so both gate queries (head-SHA and
# commit-list backstop) MUST exclude `conclusion == "skipped"`, or the gate
# counts its own deferrals as "already ran" and the review never fires. The
# sibling synchronize cost-guard keeps its narrower `conclusion=="success"` filter
# (correct for that path); this guard asserts exactly two gate queries carry the
# skipped-exclusion form.
#
# The regexes tolerate optional whitespace around `==` / `!=` (` *==? *`) so a
# jq reformat of the workflow doesn't produce a false failure. The load-bearing
# protection is the bare-query guard below: it pins the actual issue-#32
# regression (a first-ready-gate select on the name alone, with no conclusion
# filter, that recounts skipped deferrals as "already ran") to zero occurrences.
REVIEW_WF="$WF/devflow-review.yml"
# (1) No first-ready-gate query may count check-runs unconditionally — a name-only
# select with nothing after it is exactly the issue-#32 bug.
bare_gate_query_count="$(grep -cE \
  'select\(\.name *== *"Devflow Review"\) *\|' \
  "$REVIEW_WF" || true)"
assert_eq "first-ready gate: no unfiltered Devflow Review check-run query" \
  "0" "$bare_gate_query_count"
# (2) Both gate queries (head-SHA + commit-list backstop) exclude skipped check-runs.
gate_skipped_filter_count="$(grep -cE \
  'select\(\.name *== *"Devflow Review" and \.conclusion *!= *"skipped"\)' \
  "$REVIEW_WF" || true)"
assert_eq "first-ready gate: both queries exclude conclusion==skipped" \
  "2" "$gate_skipped_filter_count"
# (3) The synchronize cost-guard must NOT be widened to != "skipped" — it stays
# scoped to conclusion=="success".
sync_success_filter_count="$(grep -cE \
  'select\(\.name *== *"Devflow Review" and \.conclusion *== *"success"\)' \
  "$REVIEW_WF" || true)"
assert_eq "synchronize cost-guard keeps conclusion==success filter" \
  "1" "$sync_success_filter_count"

# ────────────────────────────────────────────────────────────────────────────
echo "efficiency-trace.jq / efficiency-trace.sh"
# ────────────────────────────────────────────────────────────────────────────
# Per-run subagent effectiveness telemetry for /devflow:review-and-fix.
# Derivation is mechanical (jq); the wrapper validates inputs, reads the gating
# flag, and dispatches per mode. Fixtures exercise: 4-way verdict derivation,
# the per-iteration marginal-yield line, flag-off → no writes, and graceful
# degradation when phase3_dispatched is absent.
ET_DIR="$(mktemp -d)"
# Iter 1: a unique-effective applied finding (corroboration 1), a corroborating
# applied finding (corroboration 2), one dispatched-but-silent agent (null), and
# a mix of lite/agent checklist items. 4 fixes applied.
cat > "$ET_DIR/iter-1.json" <<'EOF'
{
  "iter": 1,
  "checklist": [
    {"id":"VC-1","verification_mode":"lite","verdict":"PASS"},
    {"id":"VC-2","verification_mode":"lite","verdict":"FAIL"},
    {"id":"VC-3","verification_mode":"agent","verdict":"PASS"}
  ],
  "phase3_dispatched": ["devflow:code-reviewer","devflow:silent-failure-hunter","devflow:comment-analyzer"],
  "phase3_findings": [
    {"agent":"devflow:code-reviewer","corroboration_count":1,"fix_decision":"applied"},
    {"agent":"devflow:silent-failure-hunter","corroboration_count":2,"fix_decision":"applied"}
  ],
  "convergence_inputs": {"fixes_applied": 4},
  "telemetry": {"phase_3": {"calls": 3, "tokens": 48000, "wall_clock_s": 180}}
}
EOF
# Iter 2: zero fixes (marginal-yield), one pushed-back finding (noise), one
# dispatched-but-silent agent (null).
cat > "$ET_DIR/iter-2.json" <<'EOF'
{
  "iter": 2,
  "checklist": [],
  "phase3_dispatched": ["devflow:code-reviewer","devflow:comment-analyzer"],
  "phase3_findings": [
    {"agent":"devflow:code-reviewer","corroboration_count":1,"fix_decision":"pushed_back"}
  ],
  "convergence_inputs": {"fixes_applied": 0},
  "telemetry": {"phase_3": {"calls": 2, "tokens": 12000, "wall_clock_s": 60}}
}
EOF

ET_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_DIR" --slug "pr-15" --mode record)"
ET_verdict() { echo "$ET_REC" | jq -r --argjson i "$1" --arg a "$2" '.per_iteration[] | select(.iter==$i) | .agent_verdicts[] | select(.agent==$a) | .verdict'; }
assert_eq "et: applied + corroboration<2 → unique-effective" "unique-effective" "$(ET_verdict 1 'devflow:code-reviewer')"
assert_eq "et: applied + corroboration>=2 → corroborating"   "corroborating"    "$(ET_verdict 1 'devflow:silent-failure-hunter')"
assert_eq "et: dispatched but silent → null"                 "null"             "$(ET_verdict 1 'devflow:comment-analyzer')"
assert_eq "et: only pushed_back finding → noise"             "noise"            "$(ET_verdict 2 'devflow:code-reviewer')"
assert_eq "et: roster-minus-findings null on a LATER iteration" "null"          "$(ET_verdict 2 'devflow:comment-analyzer')"
# The silent-agent verdict must be JSON null, not the string "null" — so a
# cross-run analyzer can use idiomatic `select(.verdict == null)`. `jq -r`
# renders both as "null", so assert the JSON type explicitly.
ET_verdict_type() { echo "$ET_REC" | jq -r --argjson i "$1" --arg a "$2" '.per_iteration[] | select(.iter==$i) | .agent_verdicts[] | select(.agent==$a) | .verdict | type'; }
assert_eq "et: silent-agent verdict is JSON null, not string" "null" "$(ET_verdict_type 1 'devflow:comment-analyzer')"
assert_eq "et: record carries cost telemetry forward (iter1 phase_3 tokens)" "48000" \
  "$(echo "$ET_REC" | jq -r '.telemetry[] | select(.iter==1) | .phases.phase_3.tokens')"
assert_eq "et: record schema_version=1" "1" "$(echo "$ET_REC" | jq -r '.schema_version')"
assert_eq "et: cut_candidate_min_dispatch carried into record (default 3)" "3" \
  "$(echo "$ET_REC" | jq -r '.cut_candidate_min_dispatch')"
assert_eq "et: checklist split lite=2" "2" "$(echo "$ET_REC" | jq -r '.per_iteration[] | select(.iter==1) | .checklist_lite_count')"
assert_eq "et: checklist split agent=1" "1" "$(echo "$ET_REC" | jq -r '.per_iteration[] | select(.iter==1) | .checklist_agent_count')"

# diff_profile + verification posture: the Phase 0.5 classification is carried
# into the record (so the cross-run analyzer can segment by diff shape), and the
# orchestrator's no-subagent cost decision is logged as an explicit posture
# rather than a bare "0 verifiers".
ET_PROF="$(mktemp -d)"
# iter-1: engine_self_modifying diff, verification done via lite probes only (no agents).
cat > "$ET_PROF/iter-1.json" <<'EOF'
{"iter":1,"diff_profile":{"small_diff":false,"config_only":false,"has_new_types":false,"engine_self_modifying":true,"checklist_skipped":null},
"checklist":[{"verification_mode":"lite","verdict":"PASS"},{"verification_mode":"lite","verdict":"PASS"}],
"phase3_dispatched":["devflow:code-reviewer"],"phase3_findings":[],"convergence_inputs":{"fixes_applied":0},"telemetry":null}
EOF
# iter-2: small_diff+config_only, Phase 0.5 intentionally skipped the checklist.
cat > "$ET_PROF/iter-2.json" <<'EOF'
{"iter":2,"diff_profile":{"small_diff":true,"config_only":true,"has_new_types":false,"engine_self_modifying":false,"checklist_skipped":"intentional"},
"checklist":[],"phase3_dispatched":["devflow:code-reviewer"],
"phase3_findings":[{"agent":"devflow:code-reviewer","corroboration_count":1,"fix_decision":"applied"}],
"convergence_inputs":{"fixes_applied":1},"telemetry":null}
EOF
ET_PROF_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_PROF" --slug pr-15 --mode record)"
assert_eq "et: diff_profile carried into record (engine_self_modifying)" "true" \
  "$(echo "$ET_PROF_REC" | jq -r '.per_iteration[] | select(.iter==1) | .diff_profile.engine_self_modifying')"
assert_eq "et: lite-only verification posture (no subagents dispatched)" "lite-only" \
  "$(echo "$ET_PROF_REC" | jq -r '.per_iteration[] | select(.iter==1) | .verification_posture')"
assert_eq "et: Phase 0.5 intentional skip → skipped-intentional posture" "skipped-intentional" \
  "$(echo "$ET_PROF_REC" | jq -r '.per_iteration[] | select(.iter==2) | .verification_posture')"
ET_PROF_TRACE="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_PROF" --slug pr-15 --mode trace)"
assert_eq "et: trace logs the no-subagent decision (lite-only line)" "true" \
  "$(echo "$ET_PROF_TRACE" | grep -q 'without dispatching verifier subagents' && echo true || echo false)"
assert_eq "et: trace logs intentional Phase 0.5 skip" "true" \
  "$(echo "$ET_PROF_TRACE" | grep -q 'skipped by Phase 0.5' && echo true || echo false)"
assert_eq "et: trace renders diff profile line" "true" \
  "$(echo "$ET_PROF_TRACE" | grep -q 'Diff profile: engine_self_modifying' && echo true || echo false)"
# Absent diff_profile degrades gracefully: posture falls back to raw counts, label "not recorded".
ET_NOPROF="$(mktemp -d)"
cat > "$ET_NOPROF/iter-1.json" <<'EOF'
{"iter":1,"checklist":[{"verification_mode":"agent","verdict":"PASS"}],"phase3_dispatched":["a"],"phase3_findings":[],"convergence_inputs":{"fixes_applied":0},"telemetry":null}
EOF
ET_NOPROF_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_NOPROF" --slug s --mode record)"
assert_eq "et: absent diff_profile → null in record" "null" \
  "$(echo "$ET_NOPROF_REC" | jq -r '.per_iteration[0].diff_profile')"
assert_eq "et: absent diff_profile → posture from raw counts (agent-only)" "agent-only" \
  "$(echo "$ET_NOPROF_REC" | jq -r '.per_iteration[0].verification_posture')"
rm -rf "$ET_PROF" "$ET_NOPROF"

# Engine-PR analyzer gating (issue #52): the gating change is prose in
# skills/review/SKILL.md; its observable contract is the phase3_dispatched
# roster the orchestrator writes. Assert the roster flows through the trace so
# a gated-out type/test analyzer is absent on an engine-self-modifying diff with
# nothing for them to analyze, and present when the engine PR adds testable code.
ET_GATE="$(mktemp -d)"
# iter-1: engine_self_modifying, has_new_types=false, no test/code-logic changes
# → only the four always-on agents dispatched; type/test analyzers gated out.
cat > "$ET_GATE/iter-1.json" <<'EOF'
{"iter":1,"diff_profile":{"small_diff":false,"config_only":true,"has_new_types":false,"engine_self_modifying":true,"checklist_skipped":null},
"checklist":[{"verification_mode":"lite","verdict":"PASS"}],
"phase3_dispatched":["devflow:code-reviewer","devflow:silent-failure-hunter","devflow:comment-analyzer","devflow:requesting-code-review"],
"phase3_findings":[],"convergence_inputs":{"fixes_applied":0},"telemetry":{"phase_3":{"calls":4,"tokens":40000,"wall_clock_s":120}}}
EOF
# iter-2: engine_self_modifying diff that adds testable code logic → pr-test-analyzer
# is dispatched (test-relevance predicate branch 2); type-design still gated out.
cat > "$ET_GATE/iter-2.json" <<'EOF'
{"iter":2,"diff_profile":{"small_diff":false,"config_only":false,"has_new_types":false,"engine_self_modifying":true,"checklist_skipped":null},
"checklist":[{"verification_mode":"agent","verdict":"PASS"}],
"phase3_dispatched":["devflow:code-reviewer","devflow:silent-failure-hunter","devflow:comment-analyzer","devflow:requesting-code-review","devflow:pr-test-analyzer"],
"phase3_findings":[],"convergence_inputs":{"fixes_applied":0},"telemetry":{"phase_3":{"calls":5,"tokens":52000,"wall_clock_s":160}}}
EOF
ET_GATE_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_GATE" --slug "pr-15" --mode record)"
# Exact array-membership (jq `index`), not substring grep — so an exclusion
# assertion can't be fooled by a longer agent id that merely contains the name.
# These assert the trace's roster PASSTHROUGH for the rosters the gating prose
# produces; the gating decision itself is LLM-prose in skills/review/SKILL.md
# (not harness-reachable), so this guards that a gated roster survives the trace.
ET_has() { echo "$ET_GATE_REC" | jq -r --argjson i "$1" --arg a "$2" '.per_iteration[] | select(.iter==$i) | (.phase3_dispatched | index($a) != null)'; }
assert_eq "et(#52): engine-PR no-types/no-tests roster passthrough excludes type-design-analyzer" "false" \
  "$(ET_has 1 'devflow:type-design-analyzer')"
assert_eq "et(#52): engine-PR no-types/no-tests roster passthrough excludes pr-test-analyzer" "false" \
  "$(ET_has 1 'devflow:pr-test-analyzer')"
assert_eq "et(#52): engine-PR no-types/no-tests dispatched count = 4 always-on" "4" \
  "$(echo "$ET_GATE_REC" | jq -r '.per_iteration[] | select(.iter==1) | .phase3_dispatched_count')"
assert_eq "et(#52): engine-PR adding testable code roster passthrough includes pr-test-analyzer" "true" \
  "$(ET_has 2 'devflow:pr-test-analyzer')"
assert_eq "et(#52): engine-PR adding testable code still excludes type-design-analyzer" "false" \
  "$(ET_has 2 'devflow:type-design-analyzer')"
rm -rf "$ET_GATE"

# none-recorded posture remains reachable for the genuine degraded case the
# writer-gap-closing prose now leans on: Phase 1+2 ran (checklist_skipped null)
# but the checklist array is empty / no items recorded. This is the "real
# regression worth investigating" branch — lock it so it can't silently change.
ET_NR="$(mktemp -d)"
cat > "$ET_NR/iter-1.json" <<'EOF'
{"iter":1,"diff_profile":{"small_diff":false,"config_only":false,"has_new_types":false,"engine_self_modifying":false,"checklist_skipped":null},
"checklist":[],"phase3_dispatched":["devflow:code-reviewer"],"phase3_findings":[],"convergence_inputs":{"fixes_applied":0},"telemetry":null}
EOF
ET_NR_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_NR" --slug "pr-15" --mode record)"
assert_eq "et(#52): Phase 1+2 ran but zero checklist items → none-recorded (genuine gap)" "none-recorded" \
  "$(echo "$ET_NR_REC" | jq -r '.per_iteration[0].verification_posture')"
rm -rf "$ET_NR"

# Partial telemetry resilience: a workpad whose telemetry block has one phase
# present (others absent) still yields a non-null telemetry[].phases — mirroring
# the writer contract that a missing per-source token never nulls the whole block.
ET_PT="$(mktemp -d)"
cat > "$ET_PT/iter-1.json" <<'EOF'
{"iter":1,"checklist":[{"verification_mode":"lite","verdict":"PASS"}],"phase3_dispatched":["a"],"phase3_findings":[],"convergence_inputs":{"fixes_applied":0},"telemetry":{"phase_3":{"calls":1,"wall_clock_s":10}}}
EOF
ET_PT_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_PT" --slug "pr-15" --mode record)"
assert_eq "et(#52): partial telemetry (one phase, no tokens) → phases non-null" "false" \
  "$(echo "$ET_PT_REC" | jq -r '.telemetry[] | select(.iter==1) | .phases' | grep -q '^null$' && echo true || echo false)"
assert_eq "et(#52): partial telemetry preserves the present phase's calls" "1" \
  "$(echo "$ET_PT_REC" | jq -r '.telemetry[] | select(.iter==1) | .phases.phase_3.calls')"
rm -rf "$ET_PT"

# Executable-bit guard (corroborated review finding): direct invocation of the
# helper depends on lib/efficiency-trace.sh keeping its committed +x bit through
# vendoring. The harness invokes it `bash "$LIB/..."`, which masks a lost bit, so
# assert the committed mode is 100755 — a lost bit fails CI rather than silently
# disabling headless telemetry in production.
assert_eq "et(#52): lib/efficiency-trace.sh committed executable (100755)" "100755" \
  "$(cd "$LIB/.." && git ls-files -s lib/efficiency-trace.sh | cut -d' ' -f1)"

# ── Review-mode derivation (issue #55) ──────────────────────────────────────
# Standalone /devflow:review never applies a fix, so its records carry
# `contributed_to_verdict` (bool) per finding instead of `fix_decision`.
# verdict_for selects the review-mode branch off the run-level source:"review"
# (not per-finding field presence — see the ET_RMIX omitted-field case below):
# contributed (corr<2)→unique-effective, contributed (corr>=2)→corroborating,
# only-demoted→noise, silent→null. And the record carries source:"review".
ET_REV="$(mktemp -d)"
cat > "$ET_REV/iter-1.json" <<'EOF'
{
  "iter": 1,
  "source": "review",
  "checklist": [{"verification_mode":"lite","verdict":"PASS"},{"verification_mode":"agent","verdict":"FAIL"}],
  "phase3_dispatched": ["rev-unique","rev-corrob","rev-demoted","rev-silent"],
  "phase3_findings": [
    {"agent":"rev-unique","corroboration_count":1,"contributed_to_verdict":true},
    {"agent":"rev-corrob","corroboration_count":3,"contributed_to_verdict":true},
    {"agent":"rev-demoted","corroboration_count":1,"contributed_to_verdict":false}
  ],
  "convergence_inputs": {"fixes_applied": 0},
  "telemetry": {"phase_3": {"calls": 4, "tokens": 30000, "wall_clock_s": 90}}
}
EOF
ET_REV_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_REV" --slug "pr-99" --mode record)"
ET_rv() { echo "$ET_REV_REC" | jq -r --arg a "$1" '.per_iteration[0].agent_verdicts[] | select(.agent==$a) | .verdict'; }
assert_eq "et(#55): review-mode contributed + corr<2 → unique-effective" "unique-effective" "$(ET_rv 'rev-unique')"
assert_eq "et(#55): review-mode contributed + corr>=2 → corroborating"    "corroborating"    "$(ET_rv 'rev-corrob')"
assert_eq "et(#55): review-mode only-demoted finding → noise"             "noise"            "$(ET_rv 'rev-demoted')"
assert_eq "et(#55): review-mode dispatched-but-silent → null"             "null"             "$(ET_rv 'rev-silent')"
assert_eq "et(#55): review-mode silent verdict is JSON null (not string)" "null" \
  "$(echo "$ET_REV_REC" | jq -r '.per_iteration[0].agent_verdicts[] | select(.agent=="rev-silent") | .verdict | type')"
assert_eq "et(#55): record carries source: review" "review" \
  "$(echo "$ET_REV_REC" | jq -r '.source')"
rm -rf "$ET_REV"

# A review-and-fix record (fix_decision, no contributed_to_verdict) is unaffected
# by the review-mode branch and defaults source to review-and-fix.
ET_RAF="$(mktemp -d)"
cat > "$ET_RAF/iter-1.json" <<'EOF'
{"iter":1,"checklist":[],"phase3_dispatched":["a"],
"phase3_findings":[{"agent":"a","corroboration_count":1,"fix_decision":"applied"}],
"convergence_inputs":{"fixes_applied":1},"telemetry":null}
EOF
ET_RAF_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_RAF" --slug "pr-1" --mode record)"
assert_eq "et(#55): review-and-fix record still classifies off fix_decision (applied→unique-effective)" "unique-effective" \
  "$(echo "$ET_RAF_REC" | jq -r '.per_iteration[0].agent_verdicts[] | select(.agent=="a") | .verdict')"
assert_eq "et(#55): absent source defaults to review-and-fix" "review-and-fix" \
  "$(echo "$ET_RAF_REC" | jq -r '.source')"
rm -rf "$ET_RAF"

# Review-mode per-agent aggregation (issue #55 review hardening): the verdict is
# keyed off the run-level source ("review"), not per-finding field presence, so
# these stress the branch ordering and the omitted-field → noise path that the
# one-finding-per-agent fixtures above don't reach.
ET_RMIX="$(mktemp -d)"
cat > "$ET_RMIX/iter-1.json" <<'EOF'
{
  "iter": 1,
  "source": "review",
  "checklist": [],
  "phase3_dispatched": ["mix-unique","mix-corrob","omit-demoted","mixcorr","allcorr","str-true"],
  "phase3_findings": [
    {"agent":"mix-unique","corroboration_count":1,"contributed_to_verdict":true},
    {"agent":"mix-unique","corroboration_count":1,"contributed_to_verdict":false},
    {"agent":"mix-corrob","corroboration_count":3,"contributed_to_verdict":true},
    {"agent":"mix-corrob","corroboration_count":1,"contributed_to_verdict":false},
    {"agent":"omit-demoted","corroboration_count":1},
    {"agent":"mixcorr","corroboration_count":3,"contributed_to_verdict":true},
    {"agent":"mixcorr","corroboration_count":1,"contributed_to_verdict":true},
    {"agent":"allcorr","corroboration_count":2,"contributed_to_verdict":true},
    {"agent":"allcorr","corroboration_count":3,"contributed_to_verdict":true},
    {"agent":"str-true","corroboration_count":1,"contributed_to_verdict":"true"}
  ],
  "convergence_inputs": {"fixes_applied": 0},
  "telemetry": null
}
EOF
ET_RMIX_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_RMIX" --slug "pr-99" --mode record)"
ET_mv() { echo "$ET_RMIX_REC" | jq -r --arg a "$1" '.per_iteration[0].agent_verdicts[] | select(.agent==$a) | .verdict'; }
assert_eq "et(#55): contributing finding wins over a co-located demoted one (corr<2)" "unique-effective" "$(ET_mv 'mix-unique')"
assert_eq "et(#55): contributing finding wins over a co-located demoted one (corr>=2)" "corroborating" "$(ET_mv 'mix-corrob')"
# The regression test for the corroborated review finding: a demoted finding that
# OMITS contributed_to_verdict must still classify noise (not null) — the agent
# raised something, it just didn't contribute.
assert_eq "et(#55): omitted contributed_to_verdict on a raised finding → noise (not null)" "noise" "$(ET_mv 'omit-demoted')"
# Mixed corroboration within contributing findings: any unique (corr<2) → unique-effective.
assert_eq "et(#55): mixed corroboration among contributing findings → unique-effective" "unique-effective" "$(ET_mv 'mixcorr')"
# 2+ contributing findings, ALL corroborated (corr>=2) → stays corroborating (no
# unique discoverer among them). Guards the precedence boundary the single-finding
# rev-corrob fixture above can't reach.
assert_eq "et(#55): 2+ contributing findings all corr>=2 → corroborating" "corroborating" "$(ET_mv 'allcorr')"
# Malformed contributed_to_verdict (a stringified "true" from an LLM-authored
# record) is NOT truthy: the `== true` gate is strict, so the agent raised a
# finding that didn't contribute → noise (not unique-effective, not null). Pins
# the deliberate strict-boolean contract documented in verdict_for.
assert_eq "et(#55): stringified \"true\" contributed_to_verdict → noise (strict == true gate)" "noise" "$(ET_mv 'str-true')"
# Review-mode verdicts must also surface in the --mode trace Markdown (the live-
# comment surface), not just the --mode record JSON exercised above.
ET_RMIX_TRACE="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_RMIX" --slug "pr-99" --mode trace)"
assert_eq "et(#55): review-mode verdicts render in --mode trace Markdown" "true" \
  "$(echo "$ET_RMIX_TRACE" | grep -qiE 'corroborating|unique-effective' && echo true || echo false)"
# Review-mode render (issue #56 review): the fixes-oriented summary/warning lines
# are adapted for review mode — show the verdict-contribution signal, NOT the
# misleading "Fixes applied: 0" / fix-based "added nothing" that would contradict
# the unique-effective/corroborating verdicts a healthy review prints.
assert_eq "et(#56): review-mode trace shows the verdict-contribution signal" "true" \
  "$(echo "$ET_RMIX_TRACE" | grep -q 'Effectiveness signal: verdict contribution' && echo true || echo false)"
assert_eq "et(#56): review-mode trace omits the fixes-oriented 'Fixes applied' line" "true" \
  "$(echo "$ET_RMIX_TRACE" | grep -q 'Fixes applied' && echo false || echo true)"
assert_eq "et(#56): review-mode trace (agents contributed) omits the fix-based 'added nothing' warning" "true" \
  "$(echo "$ET_RMIX_TRACE" | grep -q 'added nothing' && echo false || echo true)"
rm -rf "$ET_RMIX"

# Multi-iteration run-level source resolution: iter-1 carries no source, iter-2
# carries "review" → the run-level source is "review" (first non-null), and each
# iteration still classifies off its own source.
ET_RMI="$(mktemp -d)"
cat > "$ET_RMI/iter-1.json" <<'EOF'
{"iter":1,"checklist":[],"phase3_dispatched":["a"],"phase3_findings":[{"agent":"a","corroboration_count":1,"fix_decision":"applied"}],"convergence_inputs":{"fixes_applied":1},"telemetry":null}
EOF
cat > "$ET_RMI/iter-2.json" <<'EOF'
{"iter":2,"source":"review","checklist":[],"phase3_dispatched":["b"],"phase3_findings":[{"agent":"b","corroboration_count":1,"contributed_to_verdict":true}],"convergence_inputs":{"fixes_applied":0},"telemetry":null}
EOF
ET_RMI_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_RMI" --slug "pr-99" --mode record)"
assert_eq "et(#55): run-level source is first non-null across iters (review)" "review" \
  "$(echo "$ET_RMI_REC" | jq -r '.source')"
assert_eq "et(#55): iter-1 (fix_decision, no source) classifies off its own shape" "unique-effective" \
  "$(echo "$ET_RMI_REC" | jq -r '.per_iteration[] | select(.iter==1) | .agent_verdicts[0].verdict')"
assert_eq "et(#55): iter-2 (source review) classifies review-mode" "unique-effective" \
  "$(echo "$ET_RMI_REC" | jq -r '.per_iteration[] | select(.iter==2) | .agent_verdicts[0].verdict')"
rm -rf "$ET_RMI"

# Mixed-source future-proofing warning (issue #55 review hardening): a run whose
# iterations carry genuinely divergent `source` values is not currently produced,
# but if it ever is, the wrapper warns (best-effort, never aborts) — the record's
# run-level source collapses to the first non-null and would otherwise silently
# mislabel the run. No fixture exercised this guard before.
ET_MIXSRC="$(mktemp -d)"
cat > "$ET_MIXSRC/iter-1.json" <<'EOF'
{"iter":1,"source":"review","checklist":[],"phase3_dispatched":["a"],"phase3_findings":[{"agent":"a","corroboration_count":1,"contributed_to_verdict":true}],"convergence_inputs":{"fixes_applied":0},"telemetry":null}
EOF
cat > "$ET_MIXSRC/iter-2.json" <<'EOF'
{"iter":2,"source":"review-and-fix","checklist":[],"phase3_dispatched":["b"],"phase3_findings":[{"agent":"b","corroboration_count":1,"fix_decision":"applied"}],"convergence_inputs":{"fixes_applied":1},"telemetry":null}
EOF
ET_MIXSRC_ERR="$(mktemp)"
ET_MIXSRC_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_MIXSRC" --slug "pr-99" --mode record 2>"$ET_MIXSRC_ERR")"; ET_MIXSRC_RC=$?
assert_eq "et(#55): mixed explicit sources → wrapper still exits 0 (best-effort)" "0" "$ET_MIXSRC_RC"
assert_eq "et(#55): mixed explicit sources (review + review-and-fix) → warns" "true" \
  "$(grep -q "::warning::.*mixed 'source'" "$ET_MIXSRC_ERR" && echo true || echo false)"
assert_eq "et(#55): mixed-source record still collapses run-level source to first non-null (review)" "review" \
  "$(echo "$ET_MIXSRC_REC" | jq -r '.source')"
# A `review` iter mixed with a source-LESS iter must ALSO warn: the absent source
# is counted as the run-level default (review-and-fix), so the run is genuinely
# mixed even though one iter omits the field. Guards the `.source // "review-and-fix"`
# counting — a bare `.source // empty` would drop the absent iter and stay silent.
cat > "$ET_MIXSRC/iter-2.json" <<'EOF'
{"iter":2,"checklist":[],"phase3_dispatched":["b"],"phase3_findings":[{"agent":"b","corroboration_count":1,"fix_decision":"applied"}],"convergence_inputs":{"fixes_applied":1},"telemetry":null}
EOF
ET_MIXSRC_ERR2="$(mktemp)"
bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_MIXSRC" --slug "pr-99" --mode record >/dev/null 2>"$ET_MIXSRC_ERR2"
assert_eq "et(#55): review + source-less iter → also warns (absent counts as default)" "true" \
  "$(grep -q "::warning::.*mixed 'source'" "$ET_MIXSRC_ERR2" && echo true || echo false)"
rm -rf "$ET_MIXSRC"; rm -f "$ET_MIXSRC_ERR" "$ET_MIXSRC_ERR2"

# Regression guard for the new counting: a uniform single-source run must NOT warn.
# Two source-less iters both default to review-and-fix → one distinct value → silent
# (this is the common /devflow:review-and-fix loop, which must stay warning-free).
ET_SAMESRC="$(mktemp -d)"
cat > "$ET_SAMESRC/iter-1.json" <<'EOF'
{"iter":1,"checklist":[],"phase3_dispatched":["a"],"phase3_findings":[{"agent":"a","corroboration_count":1,"fix_decision":"applied"}],"convergence_inputs":{"fixes_applied":1},"telemetry":null}
EOF
cat > "$ET_SAMESRC/iter-2.json" <<'EOF'
{"iter":2,"checklist":[],"phase3_dispatched":["b"],"phase3_findings":[{"agent":"b","corroboration_count":1,"fix_decision":"applied"}],"convergence_inputs":{"fixes_applied":1},"telemetry":null}
EOF
ET_SAMESRC_ERR="$(mktemp)"
bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_SAMESRC" --slug "pr-1" --mode record >/dev/null 2>"$ET_SAMESRC_ERR"
assert_eq "et(#55): uniform source-less run → does NOT warn" "false" \
  "$(grep -q "::warning::.*mixed 'source'" "$ET_SAMESRC_ERR" && echo true || echo false)"
rm -rf "$ET_SAMESRC"; rm -f "$ET_SAMESRC_ERR"

# Populated checklist/telemetry writer gap closed (issue #52): a workpad where
# Phase 1+2 ran yields a real lite/agent split, a non-none-recorded posture, and
# non-null telemetry[].phases — i.e. none-recorded/null phases now signal genuine
# degradation only, never a normal full-engine run.
assert_eq "et(#52): populated checklist → posture is not none-recorded" "false" \
  "$(echo "$ET_REC" | jq -r '.per_iteration[] | select(.iter==1) | .verification_posture' | grep -q 'none-recorded' && echo true || echo false)"
assert_eq "et(#52): populated checklist → posture mixed (lite+agent)" "mixed" \
  "$(echo "$ET_REC" | jq -r '.per_iteration[] | select(.iter==1) | .verification_posture')"
assert_eq "et(#52): populated telemetry block → telemetry[].phases non-null" "false" \
  "$(echo "$ET_REC" | jq -r '.telemetry[] | select(.iter==1) | .phases' | grep -q '^null$' && echo true || echo false)"

# Marginal-yield line: iter 2 applied 0 fixes → trace flags "added nothing".
ET_TRACE="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_DIR" --slug "pr-15" --mode trace)"
assert_eq "et: marginal-yield line for zero-fix iteration" "true" \
  "$(echo "$ET_TRACE" | grep -q 'Marginal yield: this iteration applied 0 fixes' && echo true || echo false)"
assert_eq "et: trace shows dispatched count" "true" \
  "$(echo "$ET_TRACE" | grep -q 'Phase 3 agents dispatched: 3' && echo true || echo false)"

# Flag-off → no output in either mode (so the SKILL.md write produces no file).
ET_CFG="$(mktemp)"; printf '{"devflow_review_and_fix":{"efficiency_telemetry_enabled":false}}' > "$ET_CFG"
ET_OFF_REC="$(DEVFLOW_CONFIG_FILE="$ET_CFG" bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_DIR" --slug "pr-15" --mode record)"
ET_OFF_TRACE="$(DEVFLOW_CONFIG_FILE="$ET_CFG" bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_DIR" --slug "pr-15" --mode trace)"
assert_eq "et: flag-off → record empty" "" "$ET_OFF_REC"
assert_eq "et: flag-off → trace empty"  "" "$ET_OFF_TRACE"

# Graceful degradation: a workpad WITHOUT phase3_dispatched still classifies the
# agents that appear in phase3_findings; the trace flags the missing roster.
ET_DEG="$(mktemp -d)"
cat > "$ET_DEG/iter-1.json" <<'EOF'
{"iter":1,"checklist":[],"phase3_findings":[{"agent":"devflow:code-reviewer","corroboration_count":1,"fix_decision":"applied"}],"convergence_inputs":{"fixes_applied":1},"telemetry":null}
EOF
ET_DEG_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_DEG" --slug "branch-x" --mode record)"
assert_eq "et: degraded (no phase3_dispatched) still classifies finding agent" "unique-effective" \
  "$(echo "$ET_DEG_REC" | jq -r '.per_iteration[0].agent_verdicts[] | select(.agent=="devflow:code-reviewer") | .verdict')"
assert_eq "et: degraded dispatched_count=0 (roster absent)" "0" \
  "$(echo "$ET_DEG_REC" | jq -r '.per_iteration[0].phase3_dispatched_count')"
ET_DEG_TRACE="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_DEG" --slug "branch-x" --mode trace)"
assert_eq "et: degraded trace flags absent phase3_dispatched" "true" \
  "$(echo "$ET_DEG_TRACE" | grep -q 'absent.*null agents (dispatched but silent) cannot be shown' && echo true || echo false)"

# Present-but-empty roster ("phase3_dispatched": []) is NOT "absent" — the
# degradation warning must not fire (regression guard for has() vs length>0).
ET_EMPTYROSTER="$(mktemp -d)"
cat > "$ET_EMPTYROSTER/iter-1.json" <<'EOF'
{"iter":1,"checklist":[],"phase3_dispatched":[],"phase3_findings":[],"convergence_inputs":{"fixes_applied":0},"telemetry":null}
EOF
ET_ER_TRACE="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_EMPTYROSTER" --slug "pr-15" --mode trace)"
assert_eq "et: empty-but-present roster does NOT flag 'absent'" "false" \
  "$(echo "$ET_ER_TRACE" | grep -q 'null agents (dispatched but silent) cannot be shown' && echo true || echo false)"
rm -rf "$ET_EMPTYROSTER"

# A valid-but-non-object workpad (stray array) is skipped, not crashed on
# (best-effort never-abort contract). The wrapper must still exit 0.
ET_BADSHAPE="$(mktemp -d)"
printf '[1,2,3]' > "$ET_BADSHAPE/iter-1.json"
ET_BS_TRACE="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_BADSHAPE" --slug "pr-15" --mode trace 2>/dev/null)"; ET_BS_RC=$?
assert_eq "et: non-object workpad → wrapper exits 0 (never aborts)" "0" "$ET_BS_RC"
assert_eq "et: non-object workpad → degrades to unavailable notice" "true" \
  "$(echo "$ET_BS_TRACE" | grep -q 'effectiveness trace unavailable' && echo true || echo false)"
rm -rf "$ET_BADSHAPE"

# No readable workpads → trace degrades to a one-line notice, never errors.
ET_EMPTY="$(mktemp -d)"
ET_EMPTY_TRACE="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_EMPTY" --slug "branch-x" --mode trace)"
assert_eq "et: empty workpad dir → graceful notice" "true" \
  "$(echo "$ET_EMPTY_TRACE" | grep -q 'effectiveness trace unavailable' && echo true || echo false)"
# record mode with zero readable iterations emits NOTHING (not a contentless
# skeleton) so the caller's `[ -s ]` guard removes the 0-byte file — symmetric
# with the flag-off contract.
ET_EMPTY_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_EMPTY" --slug "branch-x" --mode record)"
assert_eq "et: zero-iteration record emits empty (no skeleton)" "" "$ET_EMPTY_REC"

# Verdict-precedence + branch coverage on a single mixed fixture. Each agent
# below isolates one path through verdict_for that the happy-path fixtures miss.
ET_PREC="$(mktemp -d)"
cat > "$ET_PREC/iter-1.json" <<'EOF'
{
  "iter": 1,
  "checklist": [],
  "phase3_dispatched": ["agent-mixed-unique","agent-mixed-corr","agent-advisory","agent-deferred","agent-sevcal","agent-nocorr"],
  "phase3_findings": [
    {"agent":"agent-mixed-unique","corroboration_count":1,"fix_decision":"applied"},
    {"agent":"agent-mixed-unique","corroboration_count":1,"fix_decision":"pushed_back"},
    {"agent":"agent-mixed-corr","corroboration_count":3,"fix_decision":"applied"},
    {"agent":"agent-mixed-corr","corroboration_count":1,"fix_decision":"advisory"},
    {"agent":"agent-advisory","corroboration_count":1,"fix_decision":"advisory"},
    {"agent":"agent-deferred","corroboration_count":1,"fix_decision":"deferred"},
    {"agent":"agent-sevcal","corroboration_count":1,"fix_decision":"severity-calibrated"},
    {"agent":"agent-nocorr","fix_decision":"applied"}
  ],
  "convergence_inputs": {"fixes_applied": 3},
  "telemetry": null
}
EOF
ET_PREC_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_PREC" --slug "pr-15" --mode record)"
ET_pv() { echo "$ET_PREC_REC" | jq -r --arg a "$1" '.per_iteration[0].agent_verdicts[] | select(.agent==$a) | .verdict'; }
assert_eq "et: precedence applied(corr1)+pushed_back → unique-effective" "unique-effective" "$(ET_pv 'agent-mixed-unique')"
assert_eq "et: precedence applied(corr3)+advisory → corroborating (applied dominates noise)" "corroborating" "$(ET_pv 'agent-mixed-corr')"
assert_eq "et: advisory-only finding → noise" "noise" "$(ET_pv 'agent-advisory')"
assert_eq "et: deferred-only finding → null (not noise)" "null" "$(ET_pv 'agent-deferred')"
# severity-calibrated is a real-but-not-applied outcome (over-graded, calibrated down) — like
# deferred it must classify null, NOT noise (noise is reserved for pushed_back/advisory
# false-positives). This behaviorally locks the verdict_for `else null` fall-through so a
# future edit that adds severity-calibrated to the noise any() set goes RED instead of
# silently mis-bucketing a calibrated finding as reviewer noise (#160).
assert_eq "et: severity-calibrated-only finding → null (not noise)" "null" "$(ET_pv 'agent-sevcal')"
assert_eq "et: applied with missing corroboration_count → unique-effective (// 1 default)" "unique-effective" "$(ET_pv 'agent-nocorr')"
rm -rf "$ET_PREC"

# THRESHOLD: a valid custom integer is carried into the record; a non-numeric
# operator value falls back to the default 3 WITHOUT aborting the wrapper.
ET_TCFG="$(mktemp)"; printf '{"devflow_review_and_fix":{"efficiency_cut_candidate_min_dispatch":7}}' > "$ET_TCFG"
ET_T7="$(DEVFLOW_CONFIG_FILE="$ET_TCFG" bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_DIR" --slug "pr-15" --mode record)"
assert_eq "et: custom threshold 7 carried into record" "7" "$(echo "$ET_T7" | jq -r '.cut_candidate_min_dispatch')"
ET_TBAD="$(mktemp)"; printf '{"devflow_review_and_fix":{"efficiency_cut_candidate_min_dispatch":"abc"}}' > "$ET_TBAD"
ET_TB="$(DEVFLOW_CONFIG_FILE="$ET_TBAD" bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_DIR" --slug "pr-15" --mode record 2>/dev/null)"; ET_TB_RC=$?
assert_eq "et: non-numeric threshold → wrapper still exits 0" "0" "$ET_TB_RC"
assert_eq "et: non-numeric threshold → falls back to 3 in record" "3" "$(echo "$ET_TB" | jq -r '.cut_candidate_min_dispatch')"
# A below-minimum value (0) is clamped to the default 3 (schema declares minimum:1).
ET_TZERO="$(mktemp)"; printf '{"devflow_review_and_fix":{"efficiency_cut_candidate_min_dispatch":0}}' > "$ET_TZERO"
ET_TZ="$(DEVFLOW_CONFIG_FILE="$ET_TZERO" bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_DIR" --slug "pr-15" --mode record)"
assert_eq "et: threshold 0 (below schema minimum:1) → clamped to 3" "3" "$(echo "$ET_TZ" | jq -r '.cut_candidate_min_dispatch')"
rm -f "$ET_TCFG" "$ET_TBAD" "$ET_TZERO"

# CLI contract: an invalid --mode is rejected with exit 2 (protects SKILL.md's
# dependence on the trace/record flag names).
bash "$LIB/efficiency-trace.sh" --workpad-dir "$ET_DIR" --slug "pr-15" --mode bogus >/dev/null 2>&1; ET_MODE_RC=$?
assert_eq "et: invalid --mode → exit 2" "2" "$ET_MODE_RC"

rm -rf "$ET_DIR" "$ET_DEG" "$ET_EMPTY"; rm -f "$ET_CFG"

# ────────────────────────────────────────────────────────────────────────────
echo "efficiency-trace.sh --persist / --self-check (issue #80)"
# ────────────────────────────────────────────────────────────────────────────
# Layer 2 (--self-check, warn-only) + Layer 3 (--persist, deterministic backstop)
# that make /devflow:review-and-fix Loop Exit observability persistence
# non-droppable. Both are best-effort: they MUST always exit 0 and never abort.
#
# Adversarial input-shape matrix exercised below (the bug class is "a shape
# detonates the helper or yields a misdirected/silent breadcrumb"):
#   workpad dir:   {present + iter-*.json, present + no iter, absent tmp tree}
#   workpad shape: {valid object, malformed/non-object, review-mode source}
#   record state:  {absent → derive+commit, already-present → no-op}
#   telemetry:     {on → record, off → no record but durable copy still made}
#   re-run:        {second --persist → no new commit (idempotent)}

# A throwaway git repo so --persist's add/commit have somewhere real to land
# (the helper resolves the repo root and commits via `git -C "$root"`).
ETP_REPO="$(git_sandbox "et-persist repo")"
git -C "$ETP_REPO" init -q
git -C "$ETP_REPO" config user.email devflow-test@example.com
git -C "$ETP_REPO" config user.name "devflow test"
ETP_RUN="$ETP_REPO/.devflow/tmp/review/pr-77/run-abc"
mkdir -p "$ETP_RUN"
cat > "$ETP_RUN/iter-1.json" <<'EOF'
{"iter":1,"checklist":[{"verification_mode":"lite","verdict":"PASS"}],
"phase3_dispatched":["devflow:code-reviewer"],
"phase3_findings":[{"agent":"devflow:code-reviewer","corroboration_count":1,"fix_decision":"applied"}],
"convergence_inputs":{"fixes_applied":1},"telemetry":{"phase_3":{"calls":1,"tokens":1000,"wall_clock_s":10}}}
EOF
# A non-iter scratch sibling confirms the durable copy carries *.json siblings,
# while discovery/derivation key only off iter-*.json.
printf '{"deferrals":[]}' > "$ETP_RUN/deferrals.json"

# --persist (discovery): derive the record + durable copy + ONE chore: commit.
( cd "$ETP_REPO" && bash "$LIB/efficiency-trace.sh" --persist ) >/dev/null 2>&1; ETP_RC=$?
assert_eq "et-persist: always exits 0" "0" "$ETP_RC"
assert_eq "et-persist: record written at run-id-keyed path" "yes" \
  "$([ -f "$ETP_REPO/.devflow/logs/efficiency/pr-77-run-abc.json" ] && echo yes || echo no)"
assert_eq "et-persist: durable workpad copy written" "yes" \
  "$([ -f "$ETP_REPO/.devflow/logs/review/pr-77/run-abc/iter-1.json" ] && echo yes || echo no)"
assert_eq "et-persist: durable copy carries deferrals.json sibling" "yes" \
  "$([ -f "$ETP_REPO/.devflow/logs/review/pr-77/run-abc/deferrals.json" ] && echo yes || echo no)"
assert_eq "et-persist: artifacts committed in a scoped chore: commit" \
  "chore: persist review-and-fix observability artifacts" \
  "$(git -C "$ETP_REPO" log -1 --format=%s)"
assert_eq "et-persist: record is tracked (committed, not left untracked)" "yes" \
  "$(git -C "$ETP_REPO" ls-files -- .devflow/logs/efficiency/pr-77-run-abc.json | grep -q . && echo yes || echo no)"
assert_eq "et-persist: committed record is a real derivation (schema_version)" "1" \
  "$(jq -r '.schema_version' "$ETP_REPO/.devflow/logs/efficiency/pr-77-run-abc.json")"

# --persist idempotency: a second run is a clean no-op (no new / empty commit).
ETP_COUNT1="$(git -C "$ETP_REPO" rev-list --count HEAD)"
( cd "$ETP_REPO" && bash "$LIB/efficiency-trace.sh" --persist ) >/dev/null 2>&1; ETP_RC2=$?
ETP_COUNT2="$(git -C "$ETP_REPO" rev-list --count HEAD)"
assert_eq "et-persist: re-run exits 0" "0" "$ETP_RC2"
assert_eq "et-persist: re-run creates NO new commit (idempotent, no empty commit)" \
  "$ETP_COUNT1" "$ETP_COUNT2"

# --persist telemetry OFF: no record derived, but the durable copy still persists
# (the durable copy is writable-run-gated, not telemetry-gated — mirrors SKILL.md).
ETP_OFF_REPO="$(git_sandbox "et-persist telemetry-off repo")"
git -C "$ETP_OFF_REPO" init -q
git -C "$ETP_OFF_REPO" config user.email t@e.com; git -C "$ETP_OFF_REPO" config user.name t
mkdir -p "$ETP_OFF_REPO/.devflow/tmp/review/pr-9/run-x"
cp "$ETP_RUN/iter-1.json" "$ETP_OFF_REPO/.devflow/tmp/review/pr-9/run-x/iter-1.json"
ETP_OFF_CFG="$(mktemp)"; printf '{"devflow_review_and_fix":{"efficiency_telemetry_enabled":false}}' > "$ETP_OFF_CFG"
( cd "$ETP_OFF_REPO" && DEVFLOW_CONFIG_FILE="$ETP_OFF_CFG" bash "$LIB/efficiency-trace.sh" --persist ) >/dev/null 2>&1
assert_eq "et-persist: telemetry off → NO efficiency record derived" "no" \
  "$([ -e "$ETP_OFF_REPO/.devflow/logs/efficiency/pr-9-run-x.json" ] && echo yes || echo no)"
assert_eq "et-persist: telemetry off → durable copy STILL made" "yes" \
  "$([ -f "$ETP_OFF_REPO/.devflow/logs/review/pr-9/run-x/iter-1.json" ] && echo yes || echo no)"
rm -f "$ETP_OFF_CFG"; rm -rf "$ETP_OFF_REPO"

# --persist review-mode run (source=="review") is out of scope → skipped entirely.
ETP_REV_REPO="$(git_sandbox "et-persist review-mode repo")"
git -C "$ETP_REV_REPO" init -q
git -C "$ETP_REV_REPO" config user.email t@e.com; git -C "$ETP_REV_REPO" config user.name t
mkdir -p "$ETP_REV_REPO/.devflow/tmp/review/pr-5/run-r"
printf '{"iter":1,"source":"review","phase3_findings":[]}' \
  > "$ETP_REV_REPO/.devflow/tmp/review/pr-5/run-r/iter-1.json"
( cd "$ETP_REV_REPO" && bash "$LIB/efficiency-trace.sh" --persist ) >/dev/null 2>&1
assert_eq "et-persist: review-mode run skipped → no record" "no" \
  "$([ -e "$ETP_REV_REPO/.devflow/logs/efficiency/pr-5-run-r.json" ] && echo yes || echo no)"
assert_eq "et-persist: review-mode run skipped → no durable copy" "no" \
  "$([ -d "$ETP_REV_REPO/.devflow/logs/review/pr-5" ] && echo yes || echo no)"
rm -rf "$ETP_REV_REPO"

# --persist malformed-only workpad (non-object) → exit 0, no record written.
ETP_BAD_REPO="$(git_sandbox "et-persist malformed-workpad repo")"
git -C "$ETP_BAD_REPO" init -q
git -C "$ETP_BAD_REPO" config user.email t@e.com; git -C "$ETP_BAD_REPO" config user.name t
mkdir -p "$ETP_BAD_REPO/.devflow/tmp/review/pr-3/run-b"
printf '[]' > "$ETP_BAD_REPO/.devflow/tmp/review/pr-3/run-b/iter-1.json"
( cd "$ETP_BAD_REPO" && bash "$LIB/efficiency-trace.sh" --persist ) >/dev/null 2>&1; ETP_BAD_RC=$?
assert_eq "et-persist: malformed-only workpad → exit 0" "0" "$ETP_BAD_RC"
assert_eq "et-persist: malformed-only workpad → no record (empty derivation)" "no" \
  "$([ -e "$ETP_BAD_REPO/.devflow/logs/efficiency/pr-3-run-b.json" ] && echo yes || echo no)"
rm -rf "$ETP_BAD_REPO"

# --persist with no review activity at all → clean no-op (no commit).
ETP_EMPTY_REPO="$(git_sandbox "et-persist no-activity repo")"
git -C "$ETP_EMPTY_REPO" init -q
git -C "$ETP_EMPTY_REPO" config user.email t@e.com; git -C "$ETP_EMPTY_REPO" config user.name t
( cd "$ETP_EMPTY_REPO" && bash "$LIB/efficiency-trace.sh" --persist ) >/dev/null 2>&1; ETP_EMPTY_RC=$?
assert_eq "et-persist: no review activity → exit 0" "0" "$ETP_EMPTY_RC"
assert_eq "et-persist: no review activity → no commit created" "no" \
  "$(git -C "$ETP_EMPTY_REPO" rev-parse HEAD >/dev/null 2>&1 && echo yes || echo no)"
rm -rf "$ETP_EMPTY_REPO"

# --self-check (warn-only). Telemetry-off silence is the shell-enforceable half
# of the AC's "silent when telemetry disabled / read-only"; read-only silence is
# structural — SKILL.md only invokes the self-check on writable runs.
ETSC_REPO="$(git_sandbox "et-selfcheck repo")"
git -C "$ETSC_REPO" init -q
ETSC_RUN="$ETSC_REPO/.devflow/tmp/review/pr-12/run-y"
mkdir -p "$ETSC_RUN"
printf '{"iter":1,"phase3_findings":[]}' > "$ETSC_RUN/iter-1.json"
ETSC_OUT="$( ( cd "$ETSC_REPO" && bash "$LIB/efficiency-trace.sh" --self-check --workpad-dir "$ETSC_RUN" --slug pr-12 ) 2>&1 )"; ETSC_RC=$?
assert_eq "et-selfcheck: always exits 0" "0" "$ETSC_RC"
assert_eq "et-selfcheck: workpads present but no record → warns 'was NOT persisted'" "yes" \
  "$(printf '%s' "$ETSC_OUT" | grep -qF 'was NOT persisted' && echo yes || echo no)"
assert_eq "et-selfcheck: warning names the run-id-keyed record path" "yes" \
  "$(printf '%s' "$ETSC_OUT" | grep -qF 'pr-12-run-y.json' && echo yes || echo no)"
ETSC_EMPTY="$ETSC_REPO/.devflow/tmp/review/pr-12/run-empty"
mkdir -p "$ETSC_EMPTY"
ETSC_OUT2="$( ( cd "$ETSC_REPO" && bash "$LIB/efficiency-trace.sh" --self-check --workpad-dir "$ETSC_EMPTY" --slug pr-12 ) 2>&1 )"
assert_eq "et-selfcheck: zero workpads → warns NO iter-*.json captured" "yes" \
  "$(printf '%s' "$ETSC_OUT2" | grep -qF 'NO iter-*.json workpad' && echo yes || echo no)"
ETSC_OFF_CFG="$(mktemp)"; printf '{"devflow_review_and_fix":{"efficiency_telemetry_enabled":false}}' > "$ETSC_OFF_CFG"
ETSC_OUT3="$( ( cd "$ETSC_REPO" && DEVFLOW_CONFIG_FILE="$ETSC_OFF_CFG" bash "$LIB/efficiency-trace.sh" --self-check --workpad-dir "$ETSC_RUN" --slug pr-12 ) 2>&1 )"
assert_eq "et-selfcheck: telemetry disabled → silent (no warning)" "" "$ETSC_OUT3"
# --self-check on a --workpad-dir that does not exist at all (the `! -d` half of
# the guard, distinct from the empty-but-existing dir above).
ETSC_OUT4="$( ( cd "$ETSC_REPO" && bash "$LIB/efficiency-trace.sh" --self-check --workpad-dir "$ETSC_REPO/.devflow/tmp/review/pr-12/nope" --slug pr-12 ) 2>&1 )"; ETSC_RC4=$?
assert_eq "et-selfcheck: nonexistent workpad dir → exit 0" "0" "$ETSC_RC4"
assert_eq "et-selfcheck: nonexistent workpad dir → warns NO iter-*.json" "yes" \
  "$(printf '%s' "$ETSC_OUT4" | grep -qF 'NO iter-*.json workpad' && echo yes || echo no)"
rm -f "$ETSC_OFF_CFG"; rm -rf "$ETSC_REPO" "$ETP_REPO"

# A minimal valid review-and-fix iter workpad (no `source` → defaults review-and-fix).
ETP_ITER='{"iter":1,"phase3_dispatched":["a"],"phase3_findings":[],"convergence_inputs":{"fixes_applied":0},"telemetry":null}'

# --persist TARGETED mode (--workpad-dir/--slug): exercises do_persist's first
# branch (slug from --slug, run-id from the workpad-dir basename) — discovery
# never reaches it.
ETPT_REPO="$(git_sandbox "et-persist targeted repo")"
git -C "$ETPT_REPO" init -q
git -C "$ETPT_REPO" config user.email t@e.com; git -C "$ETPT_REPO" config user.name t
mkdir -p "$ETPT_REPO/.devflow/tmp/review/pr-22/run-t"
printf '%s' "$ETP_ITER" > "$ETPT_REPO/.devflow/tmp/review/pr-22/run-t/iter-1.json"
( cd "$ETPT_REPO" && bash "$LIB/efficiency-trace.sh" --persist --workpad-dir "$ETPT_REPO/.devflow/tmp/review/pr-22/run-t" --slug pr-22 ) >/dev/null 2>&1
assert_eq "et-persist: targeted --workpad-dir/--slug writes the run-id-keyed record" "yes" \
  "$([ -f "$ETPT_REPO/.devflow/logs/efficiency/pr-22-run-t.json" ] && echo yes || echo no)"
# --slug ABSENT → slug falls back to basename(dirname(workpad-dir)).
mkdir -p "$ETPT_REPO/.devflow/tmp/review/pr-23/run-u"
printf '%s' "$ETP_ITER" > "$ETPT_REPO/.devflow/tmp/review/pr-23/run-u/iter-1.json"
( cd "$ETPT_REPO" && bash "$LIB/efficiency-trace.sh" --persist --workpad-dir "$ETPT_REPO/.devflow/tmp/review/pr-23/run-u" ) >/dev/null 2>&1
assert_eq "et-persist: targeted --slug-absent → slug from parent dir name" "yes" \
  "$([ -f "$ETPT_REPO/.devflow/logs/efficiency/pr-23-run-u.json" ] && echo yes || echo no)"
rm -rf "$ETPT_REPO"

# Mixed valid + malformed iters where the lexicographically-LAST (probed) iter is
# the malformed one: the source probe fails, defaults to review-and-fix (the safe
# direction — the run is NOT wrongly skipped), leaves a breadcrumb, and the record
# is still derived from the surviving valid iter.
ETMX_REPO="$(git_sandbox "et-persist mixed-iters repo")"
git -C "$ETMX_REPO" init -q
git -C "$ETMX_REPO" config user.email t@e.com; git -C "$ETMX_REPO" config user.name t
mkdir -p "$ETMX_REPO/.devflow/tmp/review/pr-40/run-m"
printf '%s' "$ETP_ITER" > "$ETMX_REPO/.devflow/tmp/review/pr-40/run-m/iter-1.json"
printf '[]' > "$ETMX_REPO/.devflow/tmp/review/pr-40/run-m/iter-2.json"   # malformed, sorts last
ETMX_OUT="$( ( cd "$ETMX_REPO" && bash "$LIB/efficiency-trace.sh" --persist ) 2>&1 )"; ETMX_RC=$?
assert_eq "et-persist: malformed-newest probe → exit 0 (not wrongly skipped)" "0" "$ETMX_RC"
assert_eq "et-persist: malformed-newest → record still derived from valid iter" "yes" \
  "$([ -f "$ETMX_REPO/.devflow/logs/efficiency/pr-40-run-m.json" ] && echo yes || echo no)"
assert_eq "et-persist: malformed-newest source probe leaves a breadcrumb" "yes" \
  "$(printf '%s' "$ETMX_OUT" | grep -qF "could not read 'source'" && echo yes || echo no)"
rm -rf "$ETMX_REPO"

# Discovery over MULTIPLE run dirs → exactly ONE batched chore: commit, with a
# review-mode sibling that must be skipped (makes the review-skip discriminating:
# the two review-and-fix dirs persist while the review dir does not, in the SAME
# repo, so the skip can't pass merely because the whole copy step is broken).
ETMD_REPO="$(git_sandbox "et-persist multi-dir repo")"
git -C "$ETMD_REPO" init -q
git -C "$ETMD_REPO" config user.email t@e.com; git -C "$ETMD_REPO" config user.name t
mkdir -p "$ETMD_REPO/.devflow/tmp/review/pr-30/run-a" "$ETMD_REPO/.devflow/tmp/review/pr-31/run-b" "$ETMD_REPO/.devflow/tmp/review/pr-32/run-c"
printf '%s' "$ETP_ITER" > "$ETMD_REPO/.devflow/tmp/review/pr-30/run-a/iter-1.json"
printf '%s' "$ETP_ITER" > "$ETMD_REPO/.devflow/tmp/review/pr-31/run-b/iter-1.json"
printf '{"iter":1,"source":"review","phase3_findings":[]}' > "$ETMD_REPO/.devflow/tmp/review/pr-32/run-c/iter-1.json"
( cd "$ETMD_REPO" && bash "$LIB/efficiency-trace.sh" --persist ) >/dev/null 2>&1
assert_eq "et-persist: multi-dir discovery persists run dir A" "yes" \
  "$([ -f "$ETMD_REPO/.devflow/logs/efficiency/pr-30-run-a.json" ] && echo yes || echo no)"
assert_eq "et-persist: multi-dir discovery persists run dir B" "yes" \
  "$([ -f "$ETMD_REPO/.devflow/logs/efficiency/pr-31-run-b.json" ] && echo yes || echo no)"
assert_eq "et-persist: review-mode sibling skipped while siblings persist" "no" \
  "$([ -e "$ETMD_REPO/.devflow/logs/efficiency/pr-32-run-c.json" ] && echo yes || echo no)"
assert_eq "et-persist: N records committed in exactly ONE batched commit" "1" \
  "$(git -C "$ETMD_REPO" rev-list --count HEAD)"
rm -rf "$ETMD_REPO"

# Durable-copy refresh: the record is presence-frozen, but a NEW iter appearing
# after the first persist must still be copied into the durable tree and produce
# a new commit — proving the copy is not gated by the frozen record.
ETDR_REPO="$(git_sandbox "et-persist durable-refresh repo")"
git -C "$ETDR_REPO" init -q
git -C "$ETDR_REPO" config user.email t@e.com; git -C "$ETDR_REPO" config user.name t
mkdir -p "$ETDR_REPO/.devflow/tmp/review/pr-50/run-d"
printf '%s' "$ETP_ITER" > "$ETDR_REPO/.devflow/tmp/review/pr-50/run-d/iter-1.json"
( cd "$ETDR_REPO" && bash "$LIB/efficiency-trace.sh" --persist ) >/dev/null 2>&1
ETDR_COUNT1="$(git -C "$ETDR_REPO" rev-list --count HEAD)"
# A second iteration appears, then re-persist.
printf '{"iter":2,"phase3_dispatched":["a"],"phase3_findings":[],"convergence_inputs":{"fixes_applied":0},"telemetry":null}' \
  > "$ETDR_REPO/.devflow/tmp/review/pr-50/run-d/iter-2.json"
( cd "$ETDR_REPO" && bash "$LIB/efficiency-trace.sh" --persist ) >/dev/null 2>&1
ETDR_COUNT2="$(git -C "$ETDR_REPO" rev-list --count HEAD)"
assert_eq "et-persist: first persist made exactly 1 commit" "1" "$ETDR_COUNT1"
assert_eq "et-persist: new iter after persist → durable copy refreshed (iter-2 present)" "yes" \
  "$([ -f "$ETDR_REPO/.devflow/logs/review/pr-50/run-d/iter-2.json" ] && echo yes || echo no)"
assert_eq "et-persist: durable refresh produces a new commit (record frozen, copy not)" "2" "$ETDR_COUNT2"
assert_eq "et-persist: frozen record was NOT re-derived (iterations stays 1)" "1" \
  "$(jq -r '.iterations' "$ETDR_REPO/.devflow/logs/efficiency/pr-50-run-d.json")"
rm -rf "$ETDR_REPO"

# ── Issue #170: loop_role derivation + --self-check field validation ─────────
# (1) efficiency-trace.jq DERIVES loop_role per iteration of the per-run record:
#     iter 1 → fix; iter N → promoted when iter N-1's shadow.promoted_to_iter_next
#     is true. The fixtures OMIT loop_role entirely, proving the derivation holds
#     on the dropped-persist path (the reason the backstop exists).
LR_DIR="$(mktemp -d)"
printf '{"iter":1,"phase3_findings":[],"shadow":{"promoted_to_iter_next":true}}' > "$LR_DIR/iter-1.json"
printf '{"iter":2,"phase3_findings":[]}'                                         > "$LR_DIR/iter-2.json"
LR_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$LR_DIR" --slug pr-70 --mode record)"; LR_RC=$?
assert_eq "loop_role #170: record mode exits 0" "0" "$LR_RC"
assert_eq "loop_role #170: per-run record surfaces loop_role per iteration (real consumer)" "true" \
  "$(printf '%s' "$LR_REC" | jq -r '[.per_iteration[] | has("loop_role")] | all')"
assert_eq "loop_role #170: iter 1 derives fix (dropped-persist path: field omitted in fixture)" "fix" \
  "$(printf '%s' "$LR_REC" | jq -r '.per_iteration[] | select(.iter==1) | .loop_role')"
assert_eq "loop_role #170: iter 2 derives promoted (prior shadow.promoted_to_iter_next=true)" "promoted" \
  "$(printf '%s' "$LR_REC" | jq -r '.per_iteration[] | select(.iter==2) | .loop_role')"
rm -rf "$LR_DIR"

# (2) A persisted non-empty loop_role is PRESERVED over the derived value.
LR_P="$(mktemp -d)"
printf '{"iter":1,"phase3_findings":[],"shadow":{"promoted_to_iter_next":false}}' > "$LR_P/iter-1.json"
printf '{"iter":2,"phase3_findings":[],"loop_role":"promoted"}'                    > "$LR_P/iter-2.json"
LR_P_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$LR_P" --slug pr-71 --mode record)"
assert_eq "loop_role #170: persisted loop_role preserved (derived would be fix, persisted=promoted wins)" "promoted" \
  "$(printf '%s' "$LR_P_REC" | jq -r '.per_iteration[] | select(.iter==2) | .loop_role')"
rm -rf "$LR_P"

# (3) Graceful degradation: lone iter 1 with no shadow + no loop_role → fix; an
#     unparseable iter is dropped (object-gate) yet the record still derives,
#     exit 0; a missing run dir → exit 0. Never aborts (the efficiency-trace
#     "every mode never aborts" contract).
LR_D="$(mktemp -d)"
printf '{"iter":1,"phase3_findings":[]}' > "$LR_D/iter-1.json"
printf 'not json'                        > "$LR_D/iter-2.json"
LR_D_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$LR_D" --slug pr-72 --mode record)"; LR_D_RC=$?
assert_eq "loop_role #170: unparseable iter present → record mode still exits 0" "0" "$LR_D_RC"
assert_eq "loop_role #170: lone iter 1, no shadow/no loop_role → fix default" "fix" \
  "$(printf '%s' "$LR_D_REC" | jq -r '.per_iteration[] | select(.iter==1) | .loop_role')"
rm -rf "$LR_D"
LR_MISS="$(mktemp -d)"; rmdir "$LR_MISS"
bash "$LIB/efficiency-trace.sh" --workpad-dir "$LR_MISS" --slug pr-73 --mode record >/dev/null 2>&1; LR_MISS_RC=$?
assert_eq "loop_role #170: missing run dir → record mode exits 0" "0" "$LR_MISS_RC"

# (4) --self-check WARNS (best-effort, exit 0, no writes) when an iter workpad is
#     missing an expected field — naming the field + the iter file — and leaves
#     the iter file byte-identical. Fixture carries every expected field EXCEPT
#     telemetry (a non-derivable expected field).
LR_SC_REPO="$(mktemp -d)"
git -C "$LR_SC_REPO" init -q
LR_SC_RUN="$LR_SC_REPO/.devflow/tmp/review/pr-74/run-z"
mkdir -p "$LR_SC_RUN"
printf '{"iter":1,"started_at":"x","fix_commit_sha":"x","fix_files":[],"loop_role":"fix","checklist":[],"phase3_dispatched":[],"diff_profile":{},"phase3_findings":[],"fix_decisions":[],"convergence_inputs":{},"cap_drops":{}}' > "$LR_SC_RUN/iter-1.json"
cp "$LR_SC_RUN/iter-1.json" "$LR_SC_REPO/iter-1.bak"
LR_SC_OUT="$( ( cd "$LR_SC_REPO" && bash "$LIB/efficiency-trace.sh" --self-check --workpad-dir "$LR_SC_RUN" --slug pr-74 ) 2>&1 )"; LR_SC_RC=$?
assert_eq "loop_role #170: --self-check exits 0 on a missing field" "0" "$LR_SC_RC"
assert_eq "loop_role #170: --self-check ::warning:: names the missing field + iter file on one line" "yes" \
  "$(printf '%s' "$LR_SC_OUT" | grep -F '::warning::' | grep -F 'telemetry' | grep -qF 'iter-1.json' && echo yes || echo no)"
assert_eq "loop_role #170: --self-check never mutates the iter file (byte-identical)" "yes" \
  "$(cmp -s "$LR_SC_REPO/iter-1.bak" "$LR_SC_RUN/iter-1.json" && echo yes || echo no)"
rm -rf "$LR_SC_REPO"

# (5) Single-source field set ↔ SKILL.md schema divergence guard (AC #6).
#     ITER_EXPECTED_FIELDS in efficiency-trace.sh is the ONE place the expected
#     iter-field set is defined; it MUST equal the iter-<N>.json schema's
#     top-level fields in SKILL.md minus `shadow` (appended later by Step 2.6,
#     legitimately absent). FAILs if a field is added/removed on either side.
LR_CONST="$(grep -E '^ITER_EXPECTED_FIELDS=' "$LIB/efficiency-trace.sh" | sed -E 's/^ITER_EXPECTED_FIELDS=//; s/"//g' | tr ' ' '\n' | grep -v '^$' | sort -u)"
LR_SCHEMA="$(sed -n '/^### Schema$/,/^```$/p' "$MAXI_SKILL" | grep -E '^  "[A-Za-z0-9_]+":' | sed -E 's/^  "([A-Za-z0-9_]+)":.*/\1/' | grep -v '^shadow$' | sort -u)"
assert_eq "loop_role #170: ITER_EXPECTED_FIELDS single-source == SKILL.md schema top-level minus shadow" \
  "$LR_SCHEMA" "$LR_CONST"

# (6) --self-check NEVER ABORTS on an unparseable iter file (issue #170 AC: every
#     new path exits 0 on an unparseable iter-N.json). The script runs under
#     `set -euo pipefail`, so a bare `missing=$(jq ...)` assignment would trip set -e
#     when jq fails to parse — this asserts the `if !`-guarded assignment keeps the
#     contract. A valid iter alongside the malformed one still gets its missing-field
#     warnings. (Regression test for a /simplify-introduced abort.)
LR_SCM_REPO="$(mktemp -d)"
git -C "$LR_SCM_REPO" init -q
LR_SCM_RUN="$LR_SCM_REPO/.devflow/tmp/review/pr-75/run-w"
mkdir -p "$LR_SCM_RUN"
printf '{"iter":1,"loop_role":"fix"}'   > "$LR_SCM_RUN/iter-1.json"   # valid object, many fields missing
printf 'not json at all'                > "$LR_SCM_RUN/iter-2.json"   # unparseable — must NOT abort the pass
LR_SCM_OUT="$( ( cd "$LR_SCM_REPO" && bash "$LIB/efficiency-trace.sh" --self-check --workpad-dir "$LR_SCM_RUN" --slug pr-75 ) 2>&1 )"; LR_SCM_RC=$?
assert_eq "loop_role #170: --self-check exits 0 with an unparseable iter present (never aborts under set -e)" "0" "$LR_SCM_RC"
assert_eq "loop_role #170: --self-check still warns on the VALID iter's missing fields despite a malformed sibling" "yes" \
  "$(printf '%s' "$LR_SCM_OUT" | grep -F '::warning::' | grep -F 'telemetry' | grep -qF 'iter-1.json' && echo yes || echo no)"
# (6a) PR #177 review: an unparseable/unreadable iter must NOT pass silently in a
#      standalone --self-check (the --persist/--mode breadcrumb paths have not run).
#      The malformed iter-2.json above must itself draw a distinct warning naming it.
assert_eq "loop_role #170: --self-check WARNS on the unparseable iter (not silent corruption)" "yes" \
  "$(printf '%s' "$LR_SCM_OUT" | grep -F '::warning::' | grep -F 'iter-2.json' | grep -qF 'not valid JSON' && echo yes || echo no)"
rm -rf "$LR_SCM_REPO"

# (6b) PR #177 review: a parsed-but-NON-OBJECT iter (valid JSON [], null, "x") must
#      NOT masquerade as a complete workpad — it takes a distinct sentinel warning,
#      never the silent "no missing fields" arm. Exit 0 preserved (warn-only).
LR_SCN_REPO="$(mktemp -d)"
git -C "$LR_SCN_REPO" init -q
LR_SCN_RUN="$LR_SCN_REPO/.devflow/tmp/review/pr-77/run-n"
mkdir -p "$LR_SCN_RUN"
printf '[]'                              > "$LR_SCN_RUN/iter-1.json"   # valid JSON, wrong shape (array)
printf '"a bare string"'                 > "$LR_SCN_RUN/iter-2.json"   # valid JSON, wrong shape (string)
printf '{"iter":3,"loop_role":"fix"}'    > "$LR_SCN_RUN/iter-3.json"   # valid object — fields missing
LR_SCN_OUT="$( ( cd "$LR_SCN_REPO" && bash "$LIB/efficiency-trace.sh" --self-check --workpad-dir "$LR_SCN_RUN" --slug pr-77 ) 2>&1 )"; LR_SCN_RC=$?
assert_eq "loop_role #170: --self-check exits 0 on a non-object iter (never aborts)" "0" "$LR_SCN_RC"
assert_eq "loop_role #170: --self-check WARNS the non-object array iter is not an object" "yes" \
  "$(printf '%s' "$LR_SCN_OUT" | grep -F '::warning::' | grep -F 'iter-1.json' | grep -qF 'not an object' && echo yes || echo no)"
assert_eq "loop_role #170: --self-check WARNS the non-object string iter is not an object" "yes" \
  "$(printf '%s' "$LR_SCN_OUT" | grep -F '::warning::' | grep -F 'iter-2.json' | grep -qF 'not an object' && echo yes || echo no)"
# the non-object arm must NOT be misreported as a missing-field list
assert_eq "loop_role #170: --self-check does NOT emit a 'missing expected field' line for a non-object iter" "no" \
  "$(printf '%s' "$LR_SCN_OUT" | grep -F 'iter-1.json' | grep -qF 'missing expected field' && echo yes || echo no)"
# the valid object sibling still gets its real missing-field validation
assert_eq "loop_role #170: --self-check still validates the valid object sibling's fields" "yes" \
  "$(printf '%s' "$LR_SCN_OUT" | grep -F '::warning::' | grep -F 'iter-3.json' | grep -qF 'missing expected field' && echo yes || echo no)"
rm -rf "$LR_SCN_REPO"

# (7) Promotion does NOT propagate/latch: in a 3-iter chain where iter-1 promotes
#     but iter-2 does not, the derived roles are fix, promoted, fix — each iter's
#     role keys only on its IMMEDIATELY-preceding iter's shadow_promoted.
LR_3="$(mktemp -d)"
printf '{"iter":1,"phase3_findings":[],"shadow":{"promoted_to_iter_next":true}}'  > "$LR_3/iter-1.json"
printf '{"iter":2,"phase3_findings":[],"shadow":{"promoted_to_iter_next":false}}' > "$LR_3/iter-2.json"
printf '{"iter":3,"phase3_findings":[]}'                                          > "$LR_3/iter-3.json"
LR_3_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$LR_3" --slug pr-76 --mode record)"
assert_eq "loop_role #170: 3-iter chain role sequence is fix/promoted/fix (no latch/propagation)" "fix promoted fix" \
  "$(printf '%s' "$LR_3_REC" | jq -r '[.per_iteration[] | .loop_role] | join(" ")')"
rm -rf "$LR_3"

# (8) An empty-string persisted loop_role falls back to derivation (the `length > 0`
#     half of the type-guard) — iter 2 with loop_role:"" and a prior promotion derives
#     "promoted", not the persisted empty string.
LR_E="$(mktemp -d)"
printf '{"iter":1,"phase3_findings":[],"shadow":{"promoted_to_iter_next":true}}' > "$LR_E/iter-1.json"
printf '{"iter":2,"phase3_findings":[],"loop_role":""}'                          > "$LR_E/iter-2.json"
LR_E_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$LR_E" --slug pr-77 --mode record)"
assert_eq "loop_role #170: empty-string persisted loop_role falls back to derivation (not preserved)" "promoted" \
  "$(printf '%s' "$LR_E_REC" | jq -r '.per_iteration[] | select(.iter==2) | .loop_role')"
rm -rf "$LR_E"

# (9) shadow_promoted is a STRICT boolean: a malformed non-boolean
#     promoted_to_iter_next (e.g. the string "yes") must NOT over-classify the next
#     iter as promoted — it coerces to false, so iter 2 derives fix. Locks the
#     `== true` guard the comment promises (mutation: drop `== true` → iter 2 flips
#     to promoted, RED).
LR_B="$(mktemp -d)"
printf '{"iter":1,"phase3_findings":[],"shadow":{"promoted_to_iter_next":"yes"}}' > "$LR_B/iter-1.json"
printf '{"iter":2,"phase3_findings":[]}'                                          > "$LR_B/iter-2.json"
LR_B_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$LR_B" --slug pr-78 --mode record)"
assert_eq "loop_role #170: malformed non-boolean promoted_to_iter_next ('yes') does NOT over-classify next iter (strict == true)" "fix" \
  "$(printf '%s' "$LR_B_REC" | jq -r '.per_iteration[] | select(.iter==2) | .loop_role')"
rm -rf "$LR_B"

# (10) A non-STRING persisted loop_role (the `type == "string"` half of the guard,
#      vs the length>0 half in test 8) falls back to derivation — a numeric
#      loop_role:5 on iter 2 with a prior promotion derives "promoted", not 5.
LR_N="$(mktemp -d)"
printf '{"iter":1,"phase3_findings":[],"shadow":{"promoted_to_iter_next":true}}' > "$LR_N/iter-1.json"
printf '{"iter":2,"phase3_findings":[],"loop_role":5}'                           > "$LR_N/iter-2.json"
LR_N_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$LR_N" --slug pr-79 --mode record)"
assert_eq "loop_role #170: non-string persisted loop_role (numeric) falls back to derivation (type guard)" "promoted" \
  "$(printf '%s' "$LR_N_REC" | jq -r '.per_iteration[] | select(.iter==2) | .loop_role')"
rm -rf "$LR_N"

# (11) --self-check emits NO field-validation ::warning:: on a fully-complete iter
#      (all 13 expected fields present; no shadow key — shadow is exempt from
#      ITER_EXPECTED_FIELDS, so a complete iter lacking shadow must still produce
#      no field warnings). The effectiveness-record warning is suppressed by
#      pre-creating the record so only field-validation output can appear. Guards
#      against an inverted set-difference operand that would pass missing-field
#      assertions while being wrong for the clean case.
LR_CLEAN="$(mktemp -d)"
git -C "$LR_CLEAN" init -q
LR_CLEAN_RUN="$LR_CLEAN/.devflow/tmp/review/pr-80/run-n"
mkdir -p "$LR_CLEAN_RUN"
# Pre-create the effectiveness record so the "was NOT persisted" warning is suppressed;
# only field-validation output can then appear.
mkdir -p "$LR_CLEAN/.devflow/logs/efficiency"
printf '{}' > "$LR_CLEAN/.devflow/logs/efficiency/pr-80-run-n.json"
# All 13 ITER_EXPECTED_FIELDS present; no shadow key (shadow is exempt).
printf '%s' '{"iter":1,"started_at":"t","fix_commit_sha":"abc","fix_files":[],"loop_role":"fix","checklist":[],"phase3_dispatched":3,"diff_profile":"x","phase3_findings":[],"fix_decisions":[],"convergence_inputs":{},"cap_drops":[],"telemetry":{}}' \
  > "$LR_CLEAN_RUN/iter-1.json"
LR_CLEAN_OUT="$( ( cd "$LR_CLEAN" && bash "$LIB/efficiency-trace.sh" --self-check --workpad-dir "$LR_CLEAN_RUN" --slug pr-80 ) 2>&1 )"; LR_CLEAN_RC=$?
assert_eq "loop_role #177: --self-check exits 0 on a complete iter (all fields present)" "0" "$LR_CLEAN_RC"
assert_eq "loop_role #177: --self-check emits no field-validation warning on a complete iter (no ::warning:: on fields)" "0" \
  "$(printf '%s' "$LR_CLEAN_OUT" | grep -F '::warning::' | grep -cvF 'was NOT persisted' || true)"
rm -rf "$LR_CLEAN"

# (12) Mid-chain promotion: two consecutive promotions (iter-1 promotes, iter-2
#      also promotes, iter-3 follows). Expected roles: fix/promoted/promoted.
#      Locks the positional-prior indexing — an off-by-one (taking iter-1 as
#      prior for iter-3) would incorrectly derive promoted for iter-3.
LR_PP="$(mktemp -d)"
printf '{"iter":1,"phase3_findings":[],"shadow":{"promoted_to_iter_next":true}}'  > "$LR_PP/iter-1.json"
printf '{"iter":2,"phase3_findings":[],"shadow":{"promoted_to_iter_next":true}}'  > "$LR_PP/iter-2.json"
printf '{"iter":3,"phase3_findings":[]}'                                           > "$LR_PP/iter-3.json"
LR_PP_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$LR_PP" --slug pr-81 --mode record)"
assert_eq "loop_role #177: mid-chain double-promotion yields fix/promoted/promoted" "fix promoted promoted" \
  "$(printf '%s' "$LR_PP_REC" | jq -r '[.per_iteration[] | .loop_role] | join(" ")')"
rm -rf "$LR_PP"

# (13) Persisted "fix" suppresses a derived promotion: iter-2 has loop_role:"fix"
#      persisted AND a prior shadow_promoted=true — the persisted-wins rule must
#      honour the stored "fix", not override it with the derived "promoted". Mirror
#      of test (8) (persisted "promoted" survives a non-promoting prior).
LR_PF="$(mktemp -d)"
printf '{"iter":1,"phase3_findings":[],"shadow":{"promoted_to_iter_next":true}}' > "$LR_PF/iter-1.json"
printf '{"iter":2,"phase3_findings":[],"loop_role":"fix"}'                       > "$LR_PF/iter-2.json"
LR_PF_REC="$(bash "$LIB/efficiency-trace.sh" --workpad-dir "$LR_PF" --slug pr-82 --mode record)"
assert_eq "loop_role #177: persisted 'fix' suppresses derived promotion (persisted-wins)" "fix" \
  "$(printf '%s' "$LR_PF_REC" | jq -r '.per_iteration[] | select(.iter==2) | .loop_role')"
rm -rf "$LR_PF"

# ────────────────────────────────────────────────────────────────────────────
echo "devflow-runner.yml: opt-in environment provisioning (issues #18, #21)"
# ────────────────────────────────────────────────────────────────────────────
# The automated reviewer gains a build environment + build-tool allowlist ONLY
# when the TRUSTED base config sets devflow_runner.provision_env: true. These
# assertions pin the load-bearing invariants: (1) provisioning is gated on the
# base-ref flag, (2) the build allowlist is appended ONLY under that guard so
# the default profile stays byte-for-byte read-only, (3) both the flag and the
# setup block are sourced from the base ref (never the PR head) so a PR cannot
# enable provisioning or inject install commands into the write-token job.
RUNNER="$LIB/../.github/workflows/devflow-runner.yml"

# The read-only base profile line must NOT contain ANY of the 8 build tools —
# this is the "byte-for-byte read-only when disabled" guarantee. Check all eight
# (not just npm): a regression that moved a less-npm-shaped token like
# Bash(make:*) or Bash(php:*) onto the base line would slip a single-tool grep
# while breaking the security invariant. (The build tokens live only on the
# separate, PROVISION_ENV-guarded append line below.)
assert_eq "provision: read-only base profile has no build tools (all 8)" "0" \
  "$(grep "TOOLS='Read,Glob,Grep" "$RUNNER" \
     | grep -cE 'Bash\((npm|npx|node|yarn|pnpm|composer|php|make):\*\)' || true)"

# Issue #21: the build append is now the FREEFORM devflow_runner.allowed_tools
# list (read from the trusted base ref), not the old hard-coded npm…make set.
# (1) The fixed 8-tool append line must be GONE — listing build tools is now the
# adopter's config job, language-agnostic.
# Fixed-string match (-F): the literal contains `$TOOLS` and `(`/`)`/`*`; under a
# strict-POSIX/ugrep `grep` a mid-pattern `$` would anchor and the line would
# silently not match. -F keeps it portable.
assert_eq "provision: hard-coded npm…make build append removed" "0" \
  "$(grep -cF 'TOOLS="$TOOLS,Bash(npm:*),Bash(npx:*),Bash(node:*),Bash(yarn:*),Bash(pnpm:*),Bash(composer:*),Bash(php:*),Bash(make:*)"' "$RUNNER" || true)"

# (2) baseprovision emits runner_tools from the TRUSTED base ref ($BASE_JSON),
# joined to a comma string — the same trust channel as provision_env.
assert_eq "provision: runner_tools read from base config (BASE_JSON)" "1" \
  "$(grep -cF '.devflow_runner.allowed_tools // [] | map(strings) | join(",")' "$RUNNER" || true)"
assert_eq "provision: runner_tools written to GITHUB_OUTPUT (heredoc)" "1" \
  "$(grep -cF "printf 'runner_tools<<%s" "$RUNNER" || true)"
# The runner_tools value goes through a heredoc (not a single-line key=value
# echo), so a newline in a hand-edited base allowed_tools entry can't truncate
# the value or inject further step outputs.
assert_eq "provision: runner_tools value forwarded verbatim via heredoc" "1" \
  "$(grep -cF "printf '%s\\n' \"\$RUNNER_TOOLS\"" "$RUNNER" || true)"
# The Resolve-profile step's RUNNER_TOOLS env is wired to that base-ref output —
# never a PR-head source.
assert_eq "provision: RUNNER_TOOLS env wired to baseprovision output" "1" \
  "$(grep -cF 'RUNNER_TOOLS: ${{ steps.baseprovision.outputs.runner_tools }}' "$RUNNER" || true)"

# (3) The freeform list is appended (the filtered remainder) and that append is
# guarded by `if [ "$PROVISION_ENV" = "true" ]`, so the default profile stays
# byte-for-byte read-only. Locate the append line and confirm the guard precedes
# the deny-list filter block it lives in.
assert_eq "provision: freeform allowed_tools appended to profile" "1" \
  "$(grep -cF 'TOOLS="$TOOLS,$FILTERED"' "$RUNNER" || true)"
assert_eq "provision: freeform append guarded by PROVISION_ENV == true" "1" \
  "$(grep -c 'if \[ "\$PROVISION_ENV" = "true" \]' "$RUNNER" || true)"
# Structural: the append must sit AFTER the PROVISION_ENV guard, not merely
# coexist in the file — else a future dedent could append build tools to the
# default read-only profile while both greps above still pass. Pin line order.
APPEND_LN=$(grep -nF 'TOOLS="$TOOLS,$FILTERED"' "$RUNNER" | head -1 | cut -d: -f1)
GUARD_LN=$(grep -n 'if \[ "\$PROVISION_ENV" = "true" \]' "$RUNNER" | head -1 | cut -d: -f1)
assert_eq "provision: freeform append is inside the PROVISION_ENV guard (guard precedes append)" "yes" \
  "$([ -n "$APPEND_LN" ] && [ -n "$GUARD_LN" ] && [ "$GUARD_LN" -lt "$APPEND_LN" ] && echo yes || echo no)"

# (4) Deny-list floor: the catastrophic tier is stripped before appending. Pin
# the exact-name denies, the command-word denies, and both warnings.
assert_eq "provision: deny-list names present (Edit/Write/MultiEdit/NotebookEdit)" "1" \
  "$(grep -cF "DENY_NAMES='Edit Write MultiEdit NotebookEdit'" "$RUNNER" || true)"
assert_eq "provision: deny-list shells/eval/privilege present" "1" \
  "$(grep -c "DENY_CMDS='bash sh zsh" "$RUNNER" || true)"
assert_eq "provision: stripped deny-listed entries warned" "1" \
  "$(grep -c 'stripped deny-listed entries' "$RUNNER" || true)"
assert_eq "provision: empty-after-strip warns build-aware review has no tools" "1" \
  "$(grep -c 'build-aware review is enabled with NO build tools' "$RUNNER" || true)"

# The setup-project-env step is gated on the base-ref provision flag.
assert_eq "provision: setup-project-env step present" "1" \
  "$(grep -c 'uses: ./.github/actions/setup-project-env' "$RUNNER" || true)"
assert_eq "provision: setup-project-env gated on base provision_env" "1" \
  "$(grep -c "if: steps.baseprovision.outputs.provision_env == 'true'" "$RUNNER" || true)"

# Coupling: the tool-profile guard and the provision step must read the SAME
# gate. Pin that the tools step's PROVISION_ENV env is wired to
# steps.baseprovision.outputs.provision_env — if it were ever pointed at a
# stale/different source, build tools could be granted without (or without
# matching) a provisioned env, and every other assertion would stay green.
assert_eq "provision: PROVISION_ENV env wired to baseprovision output" "1" \
  "$(grep -cF 'PROVISION_ENV: ${{ steps.baseprovision.outputs.provision_env }}' "$RUNNER" || true)"

# Issue #21 inverted this invariant: the runner now DOES consume
# devflow_runner.allowed_tools (gated on provision_env, deny-list-floored). At
# least one read must be present — if a future change drops it, build-aware
# review silently regresses to read-only and this fails.
assert_eq "provision: runner consumes devflow_runner.allowed_tools" "1" \
  "$(grep -cE 'devflow_runner\.allowed_tools' "$RUNNER" | awk '{print ($1>=1)?1:0}')"
# The schema must no longer mark the key deprecated (it is live again).
assert_eq "provision: schema does not mark allowed_tools deprecated" "null" \
  "$(jq -r '.properties.devflow_runner.properties.allowed_tools.deprecated' "$LIB/../.devflow/config.schema.json")"

# Fast-feedback deny-list guard in detect-project-tools.sh: the runner write must
# go through the filtered $runner_tools var (not raw $tools), and a `denylisted`
# filter must be defined — so /devflow:init never writes a deny-listed tool into
# devflow_runner.allowed_tools.
DETECT="$LIB/../scripts/detect-project-tools.sh"
assert_eq "provision: detect defines a denylisted jq filter" "1" \
  "$(grep -c 'def denylisted:' "$DETECT" || true)"
assert_eq "provision: detect filters runner write through denylisted" "1" \
  "$(grep -cF 'select(denylisted | not)' "$DETECT" || true)"
assert_eq "provision: detect runner write uses filtered \$runner_tools" "1" \
  "$(grep -cF '.devflow_runner.allowed_tools    = ((.devflow_runner.allowed_tools    // []) + $runner_tools' "$DETECT" || true)"

# Behavioral: actually RUN the 'tools' step's deny-list filter. The static greps
# above only prove the deny-list STRINGS exist, not that filtering works — and
# this is a security boundary, so logic regressions (a broken command-word split,
# the multi-word bypass Bash(sudo rm:*), a guard that stops gating) must fail the
# suite. We extract the step's run: script and exercise it under several inputs.
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
  TOOLS_STEP=$(mktemp)
  python3 - "$RUNNER" >"$TOOLS_STEP" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
for job in doc["jobs"].values():
    for s in job.get("steps", []):
        if s.get("id") == "tools" and "run" in s:
            sys.stdout.write("#!/usr/bin/env bash\nset -euo pipefail\n" + s["run"])
            raise SystemExit
raise SystemExit("tools step not found")
PY
  # Emit the full resolved TOOLS string for a given provision flag + runner list.
  # Capture the exit code: a crashed step (e.g. a set -e abort mid-filter) must
  # NOT masquerade as "nothing appended" and let a stripping assertion pass — on
  # failure we emit a sentinel so the assertion fails loudly.
  emit_tools() {  # $1=PROVISION_ENV  $2=RUNNER_TOOLS
    local out rc; out=$(mktemp)
    PROFILE=review PROVISION_ENV="$1" RUNNER_TOOLS="$2" GITHUB_OUTPUT="$out" \
      bash "$TOOLS_STEP" >/dev/null 2>&1; rc=$?
    if [ "$rc" -ne 0 ]; then printf '__EMIT_FAILED_rc=%s__' "$rc"; rm -f "$out"; return; fi
    awk '/^tools<</{f=1;next} (f && /^EOF_/){f=0} f' "$out"
    rm -f "$out"
  }
  # The read-only base = provisioning off; the freeform append is everything the
  # filter adds on top of it.
  BASE_TOOLS=$(emit_tools false '')
  append_of() { local full; full=$(emit_tools "$1" "$2"); printf '%s' "${full#"$BASE_TOOLS"}"; }
  # Guards a "stripped" case can't pass via a crash: the read-only base must still
  # be fully present (proving the step ran to completion and ONLY dropped denies).
  base_intact() { case "$(emit_tools "$1" "$2")" in "$BASE_TOOLS"*) echo yes ;; *) echo no ;; esac; }

  # The base itself must be the real read-only profile, not an empty/garbled value
  # (otherwise the prefix-strip lens would hide base-profile regressions).
  assert_eq "provision(behavior): base profile is the read-only anchor" "yes" \
    "$(case "$BASE_TOOLS" in Read,Glob,Grep*) echo yes ;; *) echo no ;; esac)"

  # Multi-word raw-shell / privilege entries are stripped (deny by the binary).
  assert_eq "provision(behavior): Bash(sudo rm:*) stripped" "" \
    "$(append_of true 'Bash(sudo rm:*)')"
  assert_eq "provision(behavior): Bash(sh -c:*) stripped" "" \
    "$(append_of true 'Bash(sh -c:*)')"
  # Wrapper / path / env-assignment / bare-or-empty evasions are all stripped.
  assert_eq "provision(behavior): Bash(env bash:*) wrapper stripped" "" \
    "$(append_of true 'Bash(env bash:*)')"
  assert_eq "provision(behavior): Bash(/bin/bash:*) path-form stripped" "" \
    "$(append_of true 'Bash(/bin/bash:*)')"
  assert_eq "provision(behavior): Bash(xargs sh -c:*) wrapper stripped" "" \
    "$(append_of true 'Bash(xargs sh -c:*)')"
  assert_eq "provision(behavior): Bash(FOO=1 bash:*) env-assignment stripped" "" \
    "$(append_of true 'Bash(FOO=1 bash:*)')"
  assert_eq "provision(behavior): bare Bash stripped" "" \
    "$(append_of true 'Bash')"
  assert_eq "provision(behavior): Bash(:*) empty-cmd stripped" "" \
    "$(append_of true 'Bash(:*)')"
  # Newline-smuggled second tool: the producer forwards newlines verbatim, so the
  # consumer must normalize them — the embedded Bash(sudo:*) must be stripped.
  assert_eq "provision(behavior): newline-smuggled Bash(sudo:*) stripped" ",Bash(go:*)" \
    "$(append_of true "$(printf 'Bash(go:*)\nBash(sudo:*)')")"
  # Each stripped case ran to completion (base profile intact), not crashed.
  assert_eq "provision(behavior): base intact after stripping env-wrapper" "yes" \
    "$(base_intact true 'Bash(env bash:*)')"
  assert_eq "provision(behavior): base intact after stripping path-form" "yes" \
    "$(base_intact true 'Bash(/bin/bash:*)')"
  # Bare-word denies + a file-mutation tool are stripped.
  assert_eq "provision(behavior): Write + Bash(bash:*) stripped" "" \
    "$(append_of true 'Write,Bash(bash:*)')"
  # Legitimate build tools survive — including an internal space and a lookalike
  # prefix (shellcheck must NOT be caught by the 'sh' deny).
  assert_eq "provision(behavior): clean build tools survive" ",Bash(go:*),Bash(go build:*),Bash(shellcheck:*)" \
    "$(append_of true 'Bash(go:*),Bash(go build:*),Bash(shellcheck:*)')"
  # Provisioning off → nothing appended even with a non-empty list (read-only).
  assert_eq "provision(behavior): provision_env=false appends nothing" "" \
    "$(append_of false 'Bash(go:*),Bash(cargo:*)')"
  # Provisioning on + empty list → nothing appended (the warning is grepped above).
  assert_eq "provision(behavior): provision_env=true empty list appends nothing" "" \
    "$(append_of true '')"
  # Mixed list: denies dropped, clean kept, order preserved.
  assert_eq "provision(behavior): mixed list keeps only clean entries" ",Bash(go:*),Bash(make:*)" \
    "$(append_of true 'Bash(go:*),Bash(sudo:*),Edit,Bash(make:*)')"
  # Regression guard (must NOT over-strip): a deny word as a SUBCOMMAND or arg of a
  # non-wrapper command, or as a path arg, is legitimate and must survive — only
  # the command-position binary is inspected.
  assert_eq "provision(behavior): Bash(docker exec:*) kept (exec is a docker subcommand)" ",Bash(docker exec:*)" \
    "$(append_of true 'Bash(docker exec:*)')"
  assert_eq "provision(behavior): Bash(make CC=gcc:*) kept (= is a make arg, not a leading assignment)" ",Bash(make CC=gcc:*)" \
    "$(append_of true 'Bash(make CC=gcc:*)')"
  assert_eq "provision(behavior): Bash(go run ./cmd/sh:*) kept (sh is a path arg)" ",Bash(go run ./cmd/sh:*)" \
    "$(append_of true 'Bash(go run ./cmd/sh:*)')"
  # Shell-metacharacter entries are stripped (classic "append a second command").
  assert_eq "provision(behavior): Bash(go;sudo:*) metachar stripped" "" \
    "$(append_of true 'Bash(go;sudo:*)')"
  assert_eq "provision(behavior): Bash(cat x|sh:*) pipe-to-shell stripped" "" \
    "$(append_of true 'Bash(cat x|sh:*)')"
  # Closing-paren-before-colon form is stripped (shell must match the jq mirror).
  assert_eq "provision(behavior): Bash(sh):* stripped" "" \
    "$(append_of true 'Bash(sh):*')"
  # Leading env-assignment with non-identifier name (go.x=1) stripped, matching jq.
  assert_eq "provision(behavior): Bash(go.x=1:*) leading-assignment stripped" "" \
    "$(append_of true 'Bash(go.x=1:*)')"
  rm -f "$TOOLS_STEP"

  # Behavioral test of the detect-project-tools.sh jq deny mirror: extract the
  # `denylisted` def from the script (so this tracks the real filter, not a copy)
  # and assert it agrees with the runner on the same evasion corpus.
  DENYDEF=$(awk '/def denylisted:/{f=1} f{print} f&&/end;/{exit}' "$DETECT")
  jq_deny() { jq -rn --arg e "$1" "$DENYDEF"' ($e | denylisted)'; }
  assert_eq "provision(jq-mirror): Edit denied" "true" "$(jq_deny 'Edit')"
  assert_eq "provision(jq-mirror): Bash(sudo rm:*) denied" "true" "$(jq_deny 'Bash(sudo rm:*)')"
  assert_eq "provision(jq-mirror): Bash(env bash:*) denied" "true" "$(jq_deny 'Bash(env bash:*)')"
  assert_eq "provision(jq-mirror): Bash(/bin/bash:*) denied" "true" "$(jq_deny 'Bash(/bin/bash:*)')"
  assert_eq "provision(jq-mirror): Bash(FOO=1 bash:*) denied" "true" "$(jq_deny 'Bash(FOO=1 bash:*)')"
  assert_eq "provision(jq-mirror): bare Bash denied" "true" "$(jq_deny 'Bash')"
  assert_eq "provision(jq-mirror): Bash(go;sudo:*) metachar denied" "true" "$(jq_deny 'Bash(go;sudo:*)')"
  assert_eq "provision(jq-mirror): Bash(sh):* denied (paren-before-colon)" "true" "$(jq_deny 'Bash(sh):*')"
  assert_eq "provision(jq-mirror): Bash(go:*) allowed" "false" "$(jq_deny 'Bash(go:*)')"
  assert_eq "provision(jq-mirror): Bash(go build:*) allowed" "false" "$(jq_deny 'Bash(go build:*)')"
  assert_eq "provision(jq-mirror): Bash(shellcheck:*) allowed (lookalike)" "false" "$(jq_deny 'Bash(shellcheck:*)')"
  assert_eq "provision(jq-mirror): Bash(docker exec:*) allowed (subcommand)" "false" "$(jq_deny 'Bash(docker exec:*)')"
  assert_eq "provision(jq-mirror): Bash(make CC=gcc:*) allowed (arg assignment)" "false" "$(jq_deny 'Bash(make CC=gcc:*)')"
  # Env-assignment regex aligned with the runner's `[A-Za-z_]*=*` glob: a leading
  # assignment whose name has non-identifier chars (go.x=1) must deny in BOTH.
  assert_eq "provision(jq-mirror): Bash(go.x=1:*) leading-assignment denied" "true" "$(jq_deny 'Bash(go.x=1:*)')"
else
  echo "  SKIP  provision(behavior): python3+pyyaml unavailable; static assertions only"
fi

# Trust boundary on the SETUP channel (the one that carries setup.install): the
# provision step's config_json must come from steps.baseprovision (base ref),
# NOT steps.cfg / steps.extract (the PR-head config). A regression here would
# re-open setup.install injection while every flag-side assertion stayed green.
assert_eq "provision: setup config_json sourced from base (steps.baseprovision)" "1" \
  "$(grep -cF 'config_json: ${{ steps.baseprovision.outputs.config_json }}' "$RUNNER" || true)"

# The malformed/non-object base-config fallback must reset BASE_JSON to '{}' and
# warn (collapse to read-only), not abort the job. Pin both halves of that arm.
assert_eq "provision: malformed base config resets BASE_JSON to {}" "1" \
  "$(grep -c "BASE_JSON='{}'" "$RUNNER" | awk '{print ($1>=1)?1:0}')"
assert_eq "provision: malformed/non-object base config warns + read-only" "1" \
  "$(grep -c 'malformed or non-object .devflow/config.json' "$RUNNER" || true)"

# Trust boundary: the flag and setup block come from the base ref. BASE_REF is
# sourced from the trusted event payload, fetched from origin, and read out of
# FETCH_HEAD — never the checked-out PR head.
assert_eq "provision: base ref from trusted event payload" "1" \
  "$(grep -c 'github.event.pull_request.base.ref || github.event.repository.default_branch' "$RUNNER" || true)"
assert_eq "provision: base config fetched from origin BASE_REF" "1" \
  "$(grep -c 'git fetch --depth=1 origin "\$BASE_REF"' "$RUNNER" || true)"
assert_eq "provision: provision_env read from FETCH_HEAD base config" "1" \
  "$(grep -c 'FETCH_HEAD:.devflow/config.json' "$RUNNER" || true)"

# Security: the flag is read EXACTLY ONCE, and only from the base-ref config
# ($BASE_JSON) — never from the PR-head config ($CONFIG_JSON, the extract step).
# We locate every jq read of `.devflow_runner.provision_env`: there must be one,
# and it must pipe from BASE_JSON (and not CONFIG_JSON). A same-line CONFIG_JSON
# negative alone was too weak — a refactor reading the flag from the head config
# via an intermediate variable would slip past it and silently re-open the
# self-escalation hole.
PROV_READS=$(grep -nE '\.devflow_runner\.provision_env' "$RUNNER" | grep 'jq ' || true)
assert_eq "provision: flag read exactly once (jq)" "1" \
  "$(printf '%s\n' "$PROV_READS" | grep -c '^[0-9]' || true)"
assert_eq "provision: flag read from base config (BASE_JSON), not PR-head CONFIG_JSON" "yes" \
  "$(printf '%s\n' "$PROV_READS" | grep -q 'BASE_JSON' \
     && ! printf '%s\n' "$PROV_READS" | grep -q 'CONFIG_JSON' && echo yes || echo no)"
# The read uses the `== true` clamp, so the emitted GITHUB_OUTPUT token is always
# the literal `true`/`false` that both consumers (the step `if:` and the shell
# guard) compare against — and only a real boolean true enables provisioning.
assert_eq "provision: flag read uses the '== true' clamp" "yes" \
  "$(printf '%s\n' "$PROV_READS" | grep -q 'provision_env == true' && echo yes || echo no)"

# Schema + example: the property is declared (boolean, default false) and the
# example config carries it so editors and adopters see it.
assert_eq "provision: schema declares provision_env boolean" "boolean" \
  "$(jq -r '.properties.devflow_runner.properties.provision_env.type' "$LIB/../.devflow/config.schema.json")"
assert_eq "provision: schema default is false" "false" \
  "$(jq -r '.properties.devflow_runner.properties.provision_env.default' "$LIB/../.devflow/config.schema.json")"
assert_eq "provision: config.example.json sets provision_env false" "false" \
  "$(jq -r '.devflow_runner.provision_env' "$LIB/../.devflow/config.example.json")"

# ────────────────────────────────────────────────────────────────────────────
echo "docs per-step toggles (docs.internal_enabled / docs.external_enabled)"
# ────────────────────────────────────────────────────────────────────────────
# The /devflow:docs pass gates Step 1 (internal) and Step 2 (external) on these
# booleans (default true). Pin the schema declaration, the example, and — most
# importantly — that config-get.sh returns a literal "false" for a false flag
# (not coerced to the default), since the skill's skip decision compares against
# "false". A regression that coerced false→default would silently re-enable a
# disabled step.
SCHEMA="$LIB/../.devflow/config.schema.json"
for key in internal_enabled external_enabled; do
  assert_eq "docs toggle: schema declares $key boolean" "boolean" \
    "$(jq -r ".properties.docs.properties.${key}.type" "$SCHEMA")"
  assert_eq "docs toggle: schema default $key is true" "true" \
    "$(jq -r ".properties.docs.properties.${key}.default" "$SCHEMA")"
done
# config-get.sh must surface a false flag as the literal string "false".
DOCS_CFG="$(mktemp)"; printf '{"docs":{"internal_enabled":false,"external_enabled":true}}' > "$DOCS_CFG"
assert_eq "docs toggle: config-get returns literal false (not the default)" "false" \
  "$(bash "$LIB/../scripts/config-get.sh" .docs.internal_enabled true "$DOCS_CFG")"
assert_eq "docs toggle: config-get returns true when set true" "true" \
  "$(bash "$LIB/../scripts/config-get.sh" .docs.external_enabled false "$DOCS_CFG")"
DOCS_CFG_BARE="$(mktemp)"; printf '{"docs":{}}' > "$DOCS_CFG_BARE"
assert_eq "docs toggle: config-get falls back to default when key absent" "true" \
  "$(bash "$LIB/../scripts/config-get.sh" .docs.internal_enabled true "$DOCS_CFG_BARE")"
rm -f "$DOCS_CFG" "$DOCS_CFG_BARE"
# The docs skill must actually consult both toggles (guards against silent drift
# where the schema declares a flag the skill never reads).
DOCS_SKILL="$LIB/../skills/docs/SKILL.md"
assert_eq "docs toggle: skill reads .docs.internal_enabled" "1" \
  "$(grep -c '\.docs\.internal_enabled' "$DOCS_SKILL" || true)"
assert_eq "docs toggle: skill reads .docs.external_enabled" "1" \
  "$(grep -c '\.docs\.external_enabled' "$DOCS_SKILL" || true)"

# ────────────────────────────────────────────────────────────────────────────
echo "vendor-slice.sh (runtime plugin materialization: committed → self → fetch)"
# ────────────────────────────────────────────────────────────────────────────
VENDOR="$LIB/../.github/actions/vendor-plugin/vendor-slice.sh"
REPO_ROOT="$(cd "$LIB/.." && pwd)"
vexists() { [ -e "$1" ] && echo yes || echo no; }

# committed branch — a pre-populated dest (already has scripts/) is left as-is.
VS_COMMIT="$(mktemp -d)/dest"; mkdir -p "$VS_COMMIT/scripts"; : > "$VS_COMMIT/scripts/sentinel"
( cd "$(mktemp -d)" && DEVFLOW_DEST="$VS_COMMIT" bash "$VENDOR" >/dev/null 2>&1 )
assert_eq "vendor: committed branch is a no-op (sentinel survives)" "yes" "$(vexists "$VS_COMMIT/scripts/sentinel")"

# self branch — cwd is the repo root (has scripts/ + skills/ + plugin.json), so
# the in-tree plugin is copied into dest through the shared slice definition.
VS_SELF="$(mktemp -d)/dest"
( cd "$REPO_ROOT" && DEVFLOW_DEST="$VS_SELF" bash "$VENDOR" >/dev/null 2>&1 )
assert_eq "vendor: self branch copies scripts from checkout root" "yes" "$(vexists "$VS_SELF/scripts/resolve-implement-trigger.sh")"
assert_eq "vendor: self branch drops the vendored marketplace.json" "no" "$(vexists "$VS_SELF/.claude-plugin/marketplace.json")"
assert_eq "vendor: self branch keeps plugin.json" "yes" "$(vexists "$VS_SELF/.claude-plugin/plugin.json")"
assert_eq "vendor: self branch copies the .devflow templates" "yes" "$(vexists "$VS_SELF/.devflow/config.schema.json")"

# fetch branch — no plugin in cwd; clone a local fixture remote (offline) and
# copy its slice in. Exercises the clone-by-ref + copy path without the network.
# Only VS_REMOTE routes through git_sandbox: it is the one site this block git-init/commits
# into, so an empty-mktemp leak there would land a fixture commit on the real branch — the
# exact bug #161 targets. The sibling `$(mktemp -d)/dest` clone DESTINATIONS and the
# `( cd "$(mktemp -d)" && … bash "$VENDOR" )` cwd dirs below stay on bare `mktemp -d` on
# purpose: `vendor-slice.sh` clones into its OWN internal temp tree and copies into
# DEVFLOW_DEST — it never `git`-mutates its cwd — so a failed mktemp there cannot leak a
# commit to the real repo (it is out of #161's git-mutation scope). Converting a clone dest
# to git_sandbox would also break `git clone`, which requires its target to NOT pre-exist.
VS_REMOTE="$(git_sandbox "vendor fetch fixture remote")"
mkdir -p "$VS_REMOTE"/.claude-plugin "$VS_REMOTE"/agents "$VS_REMOTE"/docs \
        "$VS_REMOTE"/lib "$VS_REMOTE"/scripts "$VS_REMOTE"/skills "$VS_REMOTE"/.devflow
printf '{}' > "$VS_REMOTE/.claude-plugin/plugin.json"
printf '{}' > "$VS_REMOTE/.claude-plugin/marketplace.json"
: > "$VS_REMOTE/scripts/resolve-implement-trigger.sh"
# git won't track empty dirs — give each slice dir a file so the clone carries
# the whole slice (mirrors the real repo, where none of these dirs are empty).
: > "$VS_REMOTE/agents/placeholder.md"
: > "$VS_REMOTE/docs/efficiency-trace.md"
: > "$VS_REMOTE/lib/placeholder.sh"
: > "$VS_REMOTE/skills/placeholder.md"
printf '{}' > "$VS_REMOTE/.devflow/config.example.json"
printf '{}' > "$VS_REMOTE/.devflow/config.schema.json"
printf '{}' > "$VS_REMOTE/.devflow/tool-presets.json"
( cd "$VS_REMOTE" && git init -q -b main && git add -A \
    && git -c user.email=t@t -c user.name=t commit -qm fixture ) >/dev/null 2>&1
# Capture the BASE (non-tip) commit, then add a second commit carrying a
# tip-only marker inside the slice. `git clone --branch` rejects ANY raw commit
# SHA (it accepts only branch/tag names), so pinning a SHA always forces the
# full-clone + checkout fallback regardless of which commit it is. Using a
# NON-TIP SHA is what makes that checkout VERIFIABLE: the tip-only marker's
# absence in the copied slice proves the fallback checked out the pinned base
# commit rather than the clone's default tip.
VS_BASE_SHA="$(git -C "$VS_REMOTE" rev-parse HEAD)"
: > "$VS_REMOTE/scripts/tip-only-marker.sh"
( cd "$VS_REMOTE" && git add -A \
    && git -c user.email=t@t -c user.name=t commit -qm 'tip commit' ) >/dev/null 2>&1
VS_FETCH="$(mktemp -d)/dest"
( cd "$(mktemp -d)" && env -u DEVFLOW_REF \
    DEVFLOW_DEST="$VS_FETCH" DEVFLOW_REPO_URL="$VS_REMOTE" DEVFLOW_REF="main" \
    bash "$VENDOR" >/dev/null 2>&1 )
assert_eq "vendor: fetch branch clones the pinned ref and copies the slice" "yes" "$(vexists "$VS_FETCH/scripts/resolve-implement-trigger.sh")"
assert_eq "vendor: fetch branch drops the vendored marketplace.json" "no" "$(vexists "$VS_FETCH/.claude-plugin/marketplace.json")"
# docs/ must travel with the slice so skills' relative ../../docs/… links resolve
# offline in the materialized plugin (no web access in the runner sandbox).
assert_eq "vendor: fetch branch copies docs/ (offline skill links resolve)" "yes" "$(vexists "$VS_FETCH/docs/efficiency-trace.md")"

# fetch branch pinned to a NON-TIP commit SHA. `--branch` rejects any raw SHA,
# so this always takes the full-clone + checkout fallback (the path install.sh's
# default SHA pin hits); the non-tip pin additionally lets the marker-absence
# assertion below prove the checkout landed on the pinned commit.
VS_FETCH_SHA="$(mktemp -d)/dest"
( cd "$(mktemp -d)" && env -u DEVFLOW_REF \
    DEVFLOW_DEST="$VS_FETCH_SHA" DEVFLOW_REPO_URL="$VS_REMOTE" DEVFLOW_REF="$VS_BASE_SHA" \
    bash "$VENDOR" >/dev/null 2>&1 )
assert_eq "vendor: fetch branch resolves a commit SHA via the clone fallback" "yes" "$(vexists "$VS_FETCH_SHA/scripts/resolve-implement-trigger.sh")"
# The tip-only marker (added in the second commit) must be ABSENT — proves the
# fallback checked out the pinned base commit, not the clone's default tip.
assert_eq "vendor: SHA fallback checks out the pinned non-tip commit (no tip-only marker)" "no" "$(vexists "$VS_FETCH_SHA/scripts/tip-only-marker.sh")"

# fetch branch with no ref — fails loud rather than tracking mutable main.
VS_NOREF_RC=0
( cd "$(mktemp -d)" && env -u DEVFLOW_REF DEVFLOW_DEST="$(mktemp -d)/dest" \
    bash "$VENDOR" >/dev/null 2>&1 ) || VS_NOREF_RC=$?
assert_eq "vendor: fetch branch with no ref fails loud" "yes" \
  "$([ "$VS_NOREF_RC" -ne 0 ] && echo yes || echo no)"

# AC2 drift-guards: install.sh and the composite action both go through the ONE
# shared slice definition, so the copied file set can never diverge.
# Match the executable source line, not the shellcheck-directive comment above it.
assert_eq "vendor: install.sh sources the shared slice script" "1" \
  "$(grep -cE '^[^#]*vendor-slice\.sh' "$REPO_ROOT/install.sh" || true)"
assert_eq "vendor: install.sh calls the shared copy function" "1" \
  "$(grep -c 'devflow_copy_slice "\$SRC"' "$REPO_ROOT/install.sh" || true)"
# Match the run: invocation, not the description prose that also names the script.
assert_eq "vendor: composite action runs the shared slice script" "1" \
  "$(grep -cE 'run:.*vendor-slice\.sh' "$REPO_ROOT/.github/actions/vendor-plugin/action.yml" || true)"
# install.sh must COMMIT the vendor-plugin action even on a thin install — the
# workflows reference it, so a missing copy breaks every cloud run.
assert_eq "vendor: install.sh copies the vendor-plugin composite action" "1" \
  "$(grep -cE 'for a in .*vendor-plugin' "$REPO_ROOT/install.sh" || true)"
# AC8 placement drift-guard: the vendor-plugin composite action reads files at
# ./.github/actions/…, so the repo must be checked out BEFORE it runs in every
# plugin-using job (six across the four workflows). Scan each workflow, reset the
# "checkout seen" flag at each 2-space job/section boundary, and tally each
# vendor-plugin use as ok only if an actions/checkout preceded it in the same job.
VP_PLACEMENT="$(awk '
  FNR==1 { seen=0 }
  /^  [A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*$/ { seen=0 }
  /uses:[[:space:]]*actions\/checkout/ { seen=1 }
  /uses:[[:space:]]*\.\/\.github\/actions\/vendor-plugin/ { if (seen) ok++; else bad++ }
  END { print (ok+0)"/"(bad+0) }
' "$REPO_ROOT"/.github/workflows/*.yml)"
assert_eq "vendor: vendor-plugin runs after checkout in all six plugin jobs" "6/0" "$VP_PLACEMENT"

# AC3 finalize_check drift-guard: the dismiss call must be preceded by an
# explicit executability check so a vendoring miss (absent script, exit 127)
# is reported distinctly from a present-but-errored run. A workflow-level grep
# guard (the script-absent branch cannot be exercised by the shell harness):
# the `[ ! -x … ]` test and a distinct "absent" warning string must both be
# present in devflow-review.yml.
assert_eq "review: finalize_check guards dismiss with [ -x ] before invoking" "1" \
  "$(grep -c '\[ ! -x "\$DISMISS" \]' "$REVIEW_WF" || true)"
assert_eq "review: finalize_check emits a distinct script-absent warning" "1" \
  "$(grep -c 'dismiss-stale-rejections.sh absent — vendoring did not materialize it' "$REVIEW_WF" || true)"

# devflow_version pin (AC7): declared in the schema and present in the example.
assert_eq "vendor: schema declares devflow_version string" "string" \
  "$(jq -r '.properties.devflow_version.type' "$REPO_ROOT/.devflow/config.schema.json")"
assert_eq "vendor: config.example.json carries devflow_version" "1" \
  "$(jq 'has("devflow_version")' "$REPO_ROOT/.devflow/config.example.json" | grep -c true || true)"
# install.sh stamps it without clobbering other keys (helper present + invoked).
assert_eq "vendor: install.sh defines set_config_version" "1" \
  "$(grep -c 'set_config_version()' "$REPO_ROOT/install.sh" || true)"
assert_eq "vendor: install.sh invokes set_config_version on the config" "1" \
  "$(grep -c 'set_config_version "\.devflow/config\.json"' "$REPO_ROOT/install.sh" || true)"

# committed branch WINS over self: run from the repo root (self-branch markers
# all present) with a pre-populated dest — the committed short-circuit must fire
# so the sentinel survives. Proves precedence, not just an isolated empty-cwd no-op.
VS_PREC="$(mktemp -d)/dest"; mkdir -p "$VS_PREC/scripts"; : > "$VS_PREC/scripts/sentinel"
( cd "$REPO_ROOT" && DEVFLOW_DEST="$VS_PREC" bash "$VENDOR" >/dev/null 2>&1 )
assert_eq "vendor: committed branch beats self (precedence)" "yes" "$(vexists "$VS_PREC/scripts/sentinel")"

# self branch copies the FULL slice, not just scripts/ (a dropped cp arg would
# silently ship a plugin missing agents/lib/skills or the tool registry).
assert_eq "vendor: self copies agents/" "yes" "$(vexists "$VS_SELF/agents")"
assert_eq "vendor: self copies docs/" "yes" "$(vexists "$VS_SELF/docs")"
# A known doc lands, so the skills' relative ../../docs/efficiency-trace.md link
# resolves to a real file in the materialized plugin.
assert_eq "vendor: self copies docs/efficiency-trace.md" "yes" "$(vexists "$VS_SELF/docs/efficiency-trace.md")"
assert_eq "vendor: self copies lib/" "yes" "$(vexists "$VS_SELF/lib")"
assert_eq "vendor: self copies skills/" "yes" "$(vexists "$VS_SELF/skills")"
assert_eq "vendor: self copies .devflow/tool-presets.json" "yes" "$(vexists "$VS_SELF/.devflow/tool-presets.json")"

# self-branch NEGATIVE: a consumer repo with its OWN top-level scripts/+skills/
# but a non-devflow plugin.json must NOT be mistaken for the source repo — it
# falls through to fetch. Guards the plugin.json name discriminator.
VS_DECOY="$(mktemp -d)"; mkdir -p "$VS_DECOY/scripts" "$VS_DECOY/skills" "$VS_DECOY/.claude-plugin"
printf '{"name":"not-devflow"}' > "$VS_DECOY/.claude-plugin/plugin.json"
: > "$VS_DECOY/scripts/their-own-tool.sh"
VS_DECOY_DEST="$(mktemp -d)/dest"
( cd "$VS_DECOY" && env -u DEVFLOW_REF \
    DEVFLOW_DEST="$VS_DECOY_DEST" DEVFLOW_REPO_URL="$VS_REMOTE" DEVFLOW_REF="main" \
    bash "$VENDOR" >/dev/null 2>&1 )
assert_eq "vendor: decoy consumer falls through to fetch (not self)" "yes" "$(vexists "$VS_DECOY_DEST/scripts/resolve-implement-trigger.sh")"
assert_eq "vendor: decoy consumer's own scripts/ not taken as the plugin" "no" "$(vexists "$VS_DECOY_DEST/scripts/their-own-tool.sh")"

# fetch with an unreachable ref fails loud (no silent empty/partial dest).
VS_BADREF_RC=0
( cd "$(mktemp -d)" && env -u DEVFLOW_REF \
    DEVFLOW_DEST="$(mktemp -d)/dest" DEVFLOW_REPO_URL="$VS_REMOTE" DEVFLOW_REF="no-such-ref-xyz" \
    bash "$VENDOR" >/dev/null 2>&1 ) || VS_BADREF_RC=$?
assert_eq "vendor: fetch with unreachable ref fails loud" "yes" \
  "$([ "$VS_BADREF_RC" -ne 0 ] && echo yes || echo no)"

# Clone-failure diagnostics (AC1/AC2): a genuine fetch failure must surface its
# real cause in the die message, and a failed checkout after a successful clone
# must be textually distinguishable from a total clone failure. Capture stderr
# (the die stream) rather than discarding it, and assert the distinct phrasing.
# (Exercises the shared clone-chain logic that install.sh mirrors verbatim.)
#
# checkout-fail: a valid remote but an unreachable ref — the fast --branch
# attempt fails quietly, the fallback full-clone succeeds, the checkout fails.
VS_CKOUT_ERR="$( ( cd "$(mktemp -d)" && env -u DEVFLOW_REF \
    DEVFLOW_DEST="$(mktemp -d)/dest" DEVFLOW_REPO_URL="$VS_REMOTE" DEVFLOW_REF="no-such-ref-xyz" \
    bash "$VENDOR" ) 2>&1 >/dev/null )" || true
assert_eq "vendor: unreachable ref surfaces 'clone succeeded but checkout failed'" "yes" \
  "$(printf '%s' "$VS_CKOUT_ERR" | grep -q 'clone succeeded but checkout failed' && echo yes || echo no)"
# total clone failure: an unreachable URL — both clone attempts fail, so the die
# reports 'clone failed' and must NOT be mislabeled as a checkout failure.
VS_CLONE_ERR="$( ( cd "$(mktemp -d)" && env -u DEVFLOW_REF \
    DEVFLOW_DEST="$(mktemp -d)/dest" DEVFLOW_REPO_URL="$(mktemp -d)/no-such-repo.git" DEVFLOW_REF="main" \
    bash "$VENDOR" ) 2>&1 >/dev/null )" || true
assert_eq "vendor: unreachable URL surfaces 'clone failed'" "yes" \
  "$(printf '%s' "$VS_CLONE_ERR" | grep -q 'clone failed' && echo yes || echo no)"
assert_eq "vendor: total clone failure is not mislabeled as a checkout failure" "no" \
  "$(printf '%s' "$VS_CLONE_ERR" | grep -q 'checkout failed' && echo yes || echo no)"

# devflow_copy_slice no-partial-copy guarantee: an incomplete source must abort
# non-zero AND leave $dest untouched — $dest is only ever created by the final
# atomic mv, so a partial copy never lands where the committed-branch check would
# later mistake it for a valid plugin. Two abort paths back this guarantee, and
# we cover BOTH:
#   (a) a missing slice dir trips `cp -R "$src/scripts"` under set -e (the abort
#       fires at the cp, before the explicit floor check); and
#   (b) the explicit sanity floor (vendor-slice.sh) fires when cp SUCCEEDS but a
#       load-bearing member (plugin.json) didn't land.
# Source the shared definition (DEVFLOW_VENDOR_SOURCE=1 returns without running).
#
# (a) source missing scripts/ — cp aborts under set -e (matches AC: "source
#     missing scripts/ → non-zero exit AND $dest non-existent").
VS_BADSRC="$(mktemp -d)"
mkdir -p "$VS_BADSRC"/.claude-plugin "$VS_BADSRC"/agents "$VS_BADSRC"/docs \
        "$VS_BADSRC"/lib "$VS_BADSRC"/skills "$VS_BADSRC"/.devflow   # NOTE: no scripts/
printf '{}' > "$VS_BADSRC/.claude-plugin/plugin.json"
printf '{}' > "$VS_BADSRC/.devflow/config.example.json"
printf '{}' > "$VS_BADSRC/.devflow/config.schema.json"
printf '{}' > "$VS_BADSRC/.devflow/tool-presets.json"
VS_FLOOR_DEST="$(mktemp -d)/dest"   # parent exists; dest itself must NOT be created
VS_FLOOR_RC=0
# shellcheck disable=SC1090
( DEVFLOW_VENDOR_SOURCE=1 . "$VENDOR" && devflow_copy_slice "$VS_BADSRC" "$VS_FLOOR_DEST" ) >/dev/null 2>&1 || VS_FLOOR_RC=$?
assert_eq "vendor: missing scripts/ aborts the copy (cp-under-set-e guard)" "yes" \
  "$([ "$VS_FLOOR_RC" -ne 0 ] && echo yes || echo no)"
assert_eq "vendor: missing scripts/ leaves dest non-existent (no partial copy lands)" "no" \
  "$(vexists "$VS_FLOOR_DEST")"

# (b) source whose dirs all copy cleanly but with NO plugin.json — cp succeeds,
#     so this genuinely reaches and trips the explicit sanity-floor check.
VS_FLOORSRC="$(mktemp -d)"
mkdir -p "$VS_FLOORSRC"/.claude-plugin "$VS_FLOORSRC"/agents "$VS_FLOORSRC"/docs \
        "$VS_FLOORSRC"/lib "$VS_FLOORSRC"/scripts "$VS_FLOORSRC"/skills "$VS_FLOORSRC"/.devflow
# NOTE: no .claude-plugin/plugin.json — the floor's plugin.json check must fire.
printf '{}' > "$VS_FLOORSRC/.devflow/config.example.json"
printf '{}' > "$VS_FLOORSRC/.devflow/config.schema.json"
printf '{}' > "$VS_FLOORSRC/.devflow/tool-presets.json"
VS_FLOORSRC_DEST="$(mktemp -d)/dest"
VS_FLOORSRC_RC=0
# Capture stderr (the die stream) so we can assert the abort came from the FLOOR,
# not an early cp-under-set-e abort. Without this, a future change that added a
# required member to devflow_copy_slice's cp list (without adding it to this
# fixture) would silently degrade case (b) into a duplicate of case (a) and lose
# all coverage of the explicit floor branch while staying green.
# shellcheck disable=SC1090
VS_FLOORSRC_ERR="$( ( DEVFLOW_VENDOR_SOURCE=1 . "$VENDOR" \
    && devflow_copy_slice "$VS_FLOORSRC" "$VS_FLOORSRC_DEST" ) 2>&1 >/dev/null )" || VS_FLOORSRC_RC=$?
assert_eq "vendor: sanity floor aborts when plugin.json didn't land (cp succeeded)" "yes" \
  "$([ "$VS_FLOORSRC_RC" -ne 0 ] && echo yes || echo no)"
assert_eq "vendor: floor abort is the floor's doing, not a cp-under-set-e abort" "yes" \
  "$(printf '%s' "$VS_FLOORSRC_ERR" | grep -q 'incomplete plugin slice copied' && echo yes || echo no)"
assert_eq "vendor: sanity floor leaves dest non-existent (no partial copy lands)" "no" \
  "$(vexists "$VS_FLOORSRC_DEST")"
rm -rf "$VS_BADSRC" "$(dirname "$VS_FLOOR_DEST")" "$VS_FLOORSRC" "$(dirname "$VS_FLOORSRC_DEST")"

# set_config_version (install.sh) BEHAVIORAL: pins devflow_version without
# clobbering other keys, and a present-but-failing tool (malformed config)
# degrades to a warning + return 0 rather than aborting the install.
if command -v jq >/dev/null 2>&1; then
  SCV_INSTALL="$LIB/../install.sh"
  SCV_CFG="$(mktemp)"; printf '{"base_branch":"main","devflow":{"effort":"high"}}' > "$SCV_CFG"
  # shellcheck disable=SC1090
  ( DEVFLOW_SELFTEST=1 . "$SCV_INSTALL" && set_config_version "$SCV_CFG" "abc123" ) >/dev/null 2>&1
  assert_eq "scv: pins devflow_version" "abc123" "$(jq -r '.devflow_version' "$SCV_CFG")"
  assert_eq "scv: preserves sibling top-level key" "main" "$(jq -r '.base_branch' "$SCV_CFG")"
  assert_eq "scv: preserves nested key" "high" "$(jq -r '.devflow.effort' "$SCV_CFG")"
  SCV_BAD="$(mktemp)"; printf '{ not valid json' > "$SCV_BAD"
  SCV_RC=0
  # shellcheck disable=SC1090
  ( DEVFLOW_SELFTEST=1 . "$SCV_INSTALL" && set_config_version "$SCV_BAD" "abc123" ) >/dev/null 2>&1 || SCV_RC=$?
  assert_eq "scv: malformed config → returns 0 (degrades, never aborts)" "0" "$SCV_RC"
  rm -f "$SCV_CFG" "$SCV_BAD"

  # A hand-set devflow_version that does NOT look like a commit SHA (e.g. "main"
  # to deliberately track the branch, or a tag) is a user pin, not a previous
  # auto-stamp — re-running the installer must not clobber it back to a SHA.
  SCV_MAIN="$(mktemp)"; printf '{"devflow_version":"main"}' > "$SCV_MAIN"
  # shellcheck disable=SC1090
  SCV_MAIN_OUT="$( ( DEVFLOW_SELFTEST=1 . "$SCV_INSTALL" && set_config_version "$SCV_MAIN" "deadbeef1234" ) 2>&1 )"
  SCV_MAIN_RC=$?
  assert_eq "scv: hand-set non-SHA devflow_version (main) is preserved, not re-stamped" "main" \
    "$(jq -r '.devflow_version' "$SCV_MAIN")"
  # Value-unchanged alone can't distinguish "correctly detected a deliberate pin"
  # from "aborted early for an unrelated reason" (a set -e trap would leave the
  # value unchanged too, while returning non-zero and never logging "kept").
  assert_eq "scv: hand-set non-SHA (main) preserve returns 0 (never aborts)" "0" "$SCV_MAIN_RC"
  assert_eq "scv: hand-set non-SHA (main) preserve logs 'kept existing...deliberate pin'" "yes" \
    "$(printf '%s' "$SCV_MAIN_OUT" | grep -q 'kept existing devflow_version' && echo yes || echo no)"
  rm -f "$SCV_MAIN"

  # A previously auto-stamped SHA-like devflow_version IS re-stamped on re-run —
  # that's the whole point of pinning to the newly-installed commit.
  SCV_SHA="$(mktemp)"; printf '{"devflow_version":"abc1234"}' > "$SCV_SHA"
  # shellcheck disable=SC1090
  ( DEVFLOW_SELFTEST=1 . "$SCV_INSTALL" && set_config_version "$SCV_SHA" "deadbeef1234" ) >/dev/null 2>&1
  assert_eq "scv: previously auto-stamped SHA devflow_version IS re-stamped" "deadbeef1234" \
    "$(jq -r '.devflow_version' "$SCV_SHA")"
  rm -f "$SCV_SHA"

  # Idempotent re-run: the existing value is ALREADY the SHA being installed.
  # The classification must key off whether the existing value looks like a
  # SHA (eligible), not off whether the write changed anything — otherwise
  # this exact case logs the "kept as a deliberate pin" message even though
  # it's a SHA stamp, contradicting the python3 backend's "pinned" message
  # for the identical input.
  SCV_SAME="$(mktemp)"; printf '{"devflow_version":"deadbeef1234"}' > "$SCV_SAME"
  # shellcheck disable=SC1090
  SCV_SAME_OUT="$( ( DEVFLOW_SELFTEST=1 . "$SCV_INSTALL" && set_config_version "$SCV_SAME" "deadbeef1234" ) 2>&1 )"
  assert_eq "scv: idempotent same-SHA re-run leaves the value unchanged" "deadbeef1234" \
    "$(jq -r '.devflow_version' "$SCV_SAME")"
  assert_eq "scv: idempotent same-SHA re-run logs 'pinned', not 'kept as deliberate pin'" "yes" \
    "$(printf '%s' "$SCV_SAME_OUT" | grep -q 'pinned devflow_version=deadbeef1234' && echo yes || echo no)"
  rm -f "$SCV_SAME"

  # First-install shape: devflow_version present but EXPLICITLY an empty string
  # (as opposed to the absent-key case already covered above by SCV_CFG) — the
  # `$cur == ""` arm of the eligibility predicate. Assert the log message too,
  # not just the on-disk value, so a regression that skips this arm can't hide
  # behind "the value happened to end up right anyway".
  SCV_EMPTY="$(mktemp)"; printf '{"devflow_version":""}' > "$SCV_EMPTY"
  # shellcheck disable=SC1090
  SCV_EMPTY_OUT="$( ( DEVFLOW_SELFTEST=1 . "$SCV_INSTALL" && set_config_version "$SCV_EMPTY" "deadbeef1234" ) 2>&1 )"
  assert_eq "scv: empty-string devflow_version is stamped" "deadbeef1234" \
    "$(jq -r '.devflow_version' "$SCV_EMPTY")"
  assert_eq "scv: empty-string devflow_version stamp logs 'pinned'" "yes" \
    "$(printf '%s' "$SCV_EMPTY_OUT" | grep -q 'pinned devflow_version=deadbeef1234' && echo yes || echo no)"
  rm -f "$SCV_EMPTY"
fi

# set_config_version cross-language backends: jq is selected first on CI, so the
# python3 arm never runs under the block above. Force the lower backend by
# shadowing jq off PATH — a curated bin dir holding only the tools python3 needs
# (jq deliberately omitted). The `node` arm was removed (node is no longer a
# DevFlow config dependency), so the cascade is now jq → python3.
# Scoped to a subshell so the PATH mutation can't leak into later assertions.
SCV_INSTALL="$LIB/../install.sh"
scv_mkbin() {  # $1=dest bin dir; rest=command names to symlink from the real PATH
  # PATH is fully REPLACED with this dir in the caller, so list every external
  # command the backend invokes. Fail loud on an unresolvable tool — a silently
  # incomplete bin dir would make set_config_version degrade to its warning path
  # and surface as an opaque assertion mismatch rather than a clear setup error.
  local d="$1" c p; shift; mkdir -p "$d"
  for c in "$@"; do
    p="$(command -v "$c")" || { echo "scv_mkbin: required command not found: $c" >&2; return 1; }
    ln -sf "$p" "$d/$c"
  done
}
# python3 backend — jq absent, python3 present (node arm removed entirely).
if command -v python3 >/dev/null 2>&1; then
  SCV_PY_BIN="$(mktemp -d)/bin"
  scv_mkbin "$SCV_PY_BIN" python3 mktemp mv rm   # jq deliberately omitted
  SCV_PY_CFG="$(mktemp)"; printf '{"base_branch":"main","devflow":{"effort":"high"}}' > "$SCV_PY_CFG"
  # shellcheck disable=SC1090
  ( PATH="$SCV_PY_BIN"; DEVFLOW_SELFTEST=1 . "$SCV_INSTALL" \
      && set_config_version "$SCV_PY_CFG" "py-sha" ) >/dev/null 2>&1
  assert_eq "scv(python3): pins devflow_version" "py-sha" "$(jq -r '.devflow_version' "$SCV_PY_CFG")"
  assert_eq "scv(python3): preserves sibling top-level key" "main" "$(jq -r '.base_branch' "$SCV_PY_CFG")"
  assert_eq "scv(python3): preserves nested key" "high" "$(jq -r '.devflow.effort' "$SCV_PY_CFG")"
  rm -f "$SCV_PY_CFG"

  # Mirror the jq preserve/re-stamp assertions above for the python3 backend —
  # both arms of the empty/SHA/non-SHA branch live only in the untested python3
  # code path once jq is shadowed off PATH, so a regression there would pass CI.
  SCV_PY_MAIN="$(mktemp)"; printf '{"devflow_version":"main"}' > "$SCV_PY_MAIN"
  # shellcheck disable=SC1090
  SCV_PY_MAIN_OUT="$( ( PATH="$SCV_PY_BIN"; DEVFLOW_SELFTEST=1 . "$SCV_INSTALL" \
      && set_config_version "$SCV_PY_MAIN" "deadbeef1234" ) 2>&1 )"
  SCV_PY_MAIN_RC=$?
  assert_eq "scv(python3): hand-set non-SHA devflow_version (main) is preserved, not re-stamped" "main" \
    "$(jq -r '.devflow_version' "$SCV_PY_MAIN")"
  assert_eq "scv(python3): hand-set non-SHA (main) preserve returns 0 (never aborts)" "0" "$SCV_PY_MAIN_RC"
  assert_eq "scv(python3): hand-set non-SHA (main) preserve logs 'kept existing...deliberate pin'" "yes" \
    "$(printf '%s' "$SCV_PY_MAIN_OUT" | grep -q 'kept existing devflow_version' && echo yes || echo no)"
  rm -f "$SCV_PY_MAIN"

  SCV_PY_SHA="$(mktemp)"; printf '{"devflow_version":"abc1234"}' > "$SCV_PY_SHA"
  # shellcheck disable=SC1090
  ( PATH="$SCV_PY_BIN"; DEVFLOW_SELFTEST=1 . "$SCV_INSTALL" \
      && set_config_version "$SCV_PY_SHA" "deadbeef1234" ) >/dev/null 2>&1
  assert_eq "scv(python3): previously auto-stamped SHA devflow_version IS re-stamped" "deadbeef1234" \
    "$(jq -r '.devflow_version' "$SCV_PY_SHA")"
  rm -f "$SCV_PY_SHA"

  # jq/python3 parity for the idempotent same-SHA re-run (see the "scv: idempotent
  # same-SHA re-run" jq assertions above) — both backends must log "pinned" for
  # the identical input.
  SCV_PY_SAME="$(mktemp)"; printf '{"devflow_version":"deadbeef1234"}' > "$SCV_PY_SAME"
  # shellcheck disable=SC1090
  SCV_PY_SAME_OUT="$( ( PATH="$SCV_PY_BIN"; DEVFLOW_SELFTEST=1 . "$SCV_INSTALL" \
      && set_config_version "$SCV_PY_SAME" "deadbeef1234" ) 2>&1 )"
  assert_eq "scv(python3): idempotent same-SHA re-run leaves the value unchanged" "deadbeef1234" \
    "$(jq -r '.devflow_version' "$SCV_PY_SAME")"
  assert_eq "scv(python3): idempotent same-SHA re-run logs 'pinned', not 'kept as deliberate pin'" "yes" \
    "$(printf '%s' "$SCV_PY_SAME_OUT" | grep -q 'pinned devflow_version=deadbeef1234' && echo yes || echo no)"
  rm -f "$SCV_PY_SAME"

  # python3 mirror of the jq "empty-string devflow_version" coverage above —
  # the `cur == ""` arm lives only in this backend once jq is shadowed off PATH.
  SCV_PY_EMPTY="$(mktemp)"; printf '{"devflow_version":""}' > "$SCV_PY_EMPTY"
  # shellcheck disable=SC1090
  SCV_PY_EMPTY_OUT="$( ( PATH="$SCV_PY_BIN"; DEVFLOW_SELFTEST=1 . "$SCV_INSTALL" \
      && set_config_version "$SCV_PY_EMPTY" "deadbeef1234" ) 2>&1 )"
  assert_eq "scv(python3): empty-string devflow_version is stamped" "deadbeef1234" \
    "$(jq -r '.devflow_version' "$SCV_PY_EMPTY")"
  assert_eq "scv(python3): empty-string devflow_version stamp logs 'pinned'" "yes" \
    "$(printf '%s' "$SCV_PY_EMPTY_OUT" | grep -q 'pinned devflow_version=deadbeef1234' && echo yes || echo no)"
  rm -f "$SCV_PY_EMPTY"
fi

# jq backend POSITIVE regression pin: the jq success-path arm is otherwise only
# exercised INCIDENTALLY by the default-PATH scv block above (jq happens to be
# first-selected on CI). On a host without jq that block silently falls to the
# python3 backend and the jq arm goes untested with every assertion still green.
# Force the jq arm hermetically via a curated bin dir holding jq (python3
# deliberately omitted), symmetric with the python3 forced-PATH block above, so a
# regression that broke the jq success arm can no longer pass by falling through.
if command -v jq >/dev/null 2>&1; then
  SCV_JQ_BIN="$(mktemp -d)/bin"
  scv_mkbin "$SCV_JQ_BIN" jq mktemp mv rm   # python3 deliberately omitted
  SCV_JQ_CFG="$(mktemp)"; printf '{"base_branch":"main","devflow":{"effort":"high"}}' > "$SCV_JQ_CFG"
  # shellcheck disable=SC1090
  ( PATH="$SCV_JQ_BIN"; DEVFLOW_SELFTEST=1 . "$SCV_INSTALL" \
      && set_config_version "$SCV_JQ_CFG" "jq-sha1234" ) >/dev/null 2>&1
  assert_eq "scv(jq): pins devflow_version (python3 shadowed off PATH)" "jq-sha1234" \
    "$(jq -r '.devflow_version' "$SCV_JQ_CFG")"
  assert_eq "scv(jq): preserves sibling top-level key" "main" "$(jq -r '.base_branch' "$SCV_JQ_CFG")"
  assert_eq "scv(jq): preserves nested key" "high" "$(jq -r '.devflow.effort' "$SCV_JQ_CFG")"
  rm -f "$SCV_JQ_CFG"

  # jq arm preserve-vs-restamp branches, hermetic (python3 unavailable): a
  # hand-set non-SHA value is kept; an empty-string first-install value is stamped.
  SCV_JQ_MAIN="$(mktemp)"; printf '{"devflow_version":"main"}' > "$SCV_JQ_MAIN"
  # shellcheck disable=SC1090
  SCV_JQ_MAIN_OUT="$( ( PATH="$SCV_JQ_BIN"; DEVFLOW_SELFTEST=1 . "$SCV_INSTALL" \
      && set_config_version "$SCV_JQ_MAIN" "deadbeef1234" ) 2>&1 )"
  SCV_JQ_MAIN_RC=$?
  assert_eq "scv(jq): hand-set non-SHA devflow_version (main) is preserved, not re-stamped" "main" \
    "$(jq -r '.devflow_version' "$SCV_JQ_MAIN")"
  assert_eq "scv(jq): hand-set non-SHA (main) preserve returns 0 (never aborts)" "0" "$SCV_JQ_MAIN_RC"
  assert_eq "scv(jq): hand-set non-SHA (main) preserve logs 'kept existing...deliberate pin'" "yes" \
    "$(printf '%s' "$SCV_JQ_MAIN_OUT" | grep -q 'kept existing devflow_version' && echo yes || echo no)"
  rm -f "$SCV_JQ_MAIN"

  SCV_JQ_EMPTY="$(mktemp)"; printf '{"devflow_version":""}' > "$SCV_JQ_EMPTY"
  # shellcheck disable=SC1090
  SCV_JQ_EMPTY_OUT="$( ( PATH="$SCV_JQ_BIN"; DEVFLOW_SELFTEST=1 . "$SCV_INSTALL" \
      && set_config_version "$SCV_JQ_EMPTY" "deadbeef1234" ) 2>&1 )"
  assert_eq "scv(jq): empty-string devflow_version is stamped" "deadbeef1234" \
    "$(jq -r '.devflow_version' "$SCV_JQ_EMPTY")"
  assert_eq "scv(jq): empty-string devflow_version stamp logs 'pinned'" "yes" \
    "$(printf '%s' "$SCV_JQ_EMPTY_OUT" | grep -q 'pinned devflow_version=deadbeef1234' && echo yes || echo no)"
  rm -f "$SCV_JQ_EMPTY"
  rm -rf "$(dirname "$SCV_JQ_BIN")"
fi

# jq.exe-wins selection pin (the headline Windows path): a present-but-unrunnable
# `jq` shadows PATH while a runnable `jq.exe` is available — install.sh's
# `elif jq.exe --version` arm must select jq.exe and pin. Forced hermetically
# (a non-runnable jq stub + real jq exposed only as jq.exe, python3 omitted) so
# a regression in that arm fails closed instead of shipping CI-green.
if command -v jq >/dev/null 2>&1; then
  SCV_JQE_BIN="$(mktemp -d)/bin"; mkdir -p "$SCV_JQE_BIN"
  printf '#!/bin/sh\nexit 1\n' > "$SCV_JQE_BIN/jq"; chmod +x "$SCV_JQE_BIN/jq"   # unrunnable shadow
  ln -sf "$(command -v jq)" "$SCV_JQE_BIN/jq.exe"                                # real jq, jq.exe-only
  for c in mktemp mv rm; do ln -sf "$(command -v "$c")" "$SCV_JQE_BIN/$c"; done  # python3 deliberately omitted
  SCV_JQE_CFG="$(mktemp)"; printf '{"devflow_version":""}' > "$SCV_JQE_CFG"
  # shellcheck disable=SC1090
  SCV_JQE_OUT="$( ( PATH="$SCV_JQE_BIN"; DEVFLOW_SELFTEST=1 . "$SCV_INSTALL" \
      && set_config_version "$SCV_JQE_CFG" "exe-sha1234" ) 2>&1 )"
  assert_eq "scv(jq.exe): shadowed jq → runnable jq.exe is selected and pins (headline Windows path)" "exe-sha1234" \
    "$(jq -r '.devflow_version' "$SCV_JQE_CFG")"
  assert_eq "scv(jq.exe): pins via the jq.exe arm, logs 'pinned'" "yes" \
    "$(printf '%s' "$SCV_JQE_OUT" | grep -q 'pinned devflow_version=exe-sha1234' && echo yes || echo no)"
  rm -f "$SCV_JQE_CFG"
  rm -rf "$(dirname "$SCV_JQE_BIN")"
fi

# ── Critical regression guard: a failed mv must not report false success ────
# A failed `mv "$tmp" "$cfg"` (read-only destination dir, ENOSPC, cross-device
# rename failure) must fall through to the generic warning + return 0, never
# log "pinned" while leaving the config unpinned. Force the failure
# deterministically via a stub `mv` that always exits 1 — portable across
# root/non-root CI, unlike relying on filesystem permission bits.
scv_mkfailbin() {  # $1=dest bin dir; $2=command to force-fail; rest=commands to pass through for real
  local d="$1" failcmd="$2" c p; shift 2; mkdir -p "$d"
  printf '#!/bin/sh\nexit 1\n' > "$d/$failcmd"
  chmod +x "$d/$failcmd"
  for c in "$@"; do
    p="$(command -v "$c")" || { echo "scv_mkfailbin: required command not found: $c" >&2; return 1; }
    ln -sf "$p" "$d/$c"
  done
}
if command -v jq >/dev/null 2>&1; then
  SCV_MVFAIL_BIN="$(mktemp -d)/bin"
  scv_mkfailbin "$SCV_MVFAIL_BIN" mv jq mktemp rm
  SCV_MVFAIL_CFG="$(mktemp)"; printf '{"devflow_version":"abc1234"}' > "$SCV_MVFAIL_CFG"
  # shellcheck disable=SC1090
  SCV_MVFAIL_OUT="$( ( PATH="$SCV_MVFAIL_BIN"; DEVFLOW_SELFTEST=1 . "$SCV_INSTALL" \
      && set_config_version "$SCV_MVFAIL_CFG" "deadbeef1234" ) 2>&1 )"
  SCV_MVFAIL_RC=$?
  assert_eq "scv: failed mv still returns 0 (degrades, never aborts) (jq)" "0" "$SCV_MVFAIL_RC"
  assert_eq "scv: failed mv falls through to the generic warning (jq)" "yes" \
    "$(printf '%s' "$SCV_MVFAIL_OUT" | grep -q 'warning: could not set devflow_version' && echo yes || echo no)"
  assert_eq "scv: failed mv never logs 'pinned' (jq)" "no" \
    "$(printf '%s' "$SCV_MVFAIL_OUT" | grep -q 'pinned devflow_version=' && echo yes || echo no)"
  assert_eq "scv: failed mv leaves the on-disk value untouched (jq)" "abc1234" \
    "$(jq -r '.devflow_version' "$SCV_MVFAIL_CFG")"
  rm -f "$SCV_MVFAIL_CFG"
  rm -rf "$(dirname "$SCV_MVFAIL_BIN")"
fi
if command -v python3 >/dev/null 2>&1; then
  SCV_PY_MVFAIL_BIN="$(mktemp -d)/bin"
  scv_mkfailbin "$SCV_PY_MVFAIL_BIN" mv python3 mktemp rm   # jq deliberately omitted
  SCV_PY_MVFAIL_CFG="$(mktemp)"; printf '{"devflow_version":"abc1234"}' > "$SCV_PY_MVFAIL_CFG"
  # shellcheck disable=SC1090
  SCV_PY_MVFAIL_OUT="$( ( PATH="$SCV_PY_MVFAIL_BIN"; DEVFLOW_SELFTEST=1 . "$SCV_INSTALL" \
      && set_config_version "$SCV_PY_MVFAIL_CFG" "deadbeef1234" ) 2>&1 )"
  SCV_PY_MVFAIL_RC=$?
  assert_eq "scv(python3): failed mv still returns 0 (degrades, never aborts)" "0" "$SCV_PY_MVFAIL_RC"
  assert_eq "scv(python3): failed mv falls through to the generic warning" "yes" \
    "$(printf '%s' "$SCV_PY_MVFAIL_OUT" | grep -q 'warning: could not set devflow_version' && echo yes || echo no)"
  assert_eq "scv(python3): failed mv never logs 'pinned'" "no" \
    "$(printf '%s' "$SCV_PY_MVFAIL_OUT" | grep -q 'pinned devflow_version=' && echo yes || echo no)"
  assert_eq "scv(python3): failed mv leaves the on-disk value untouched" "abc1234" \
    "$(jq -r '.devflow_version' "$SCV_PY_MVFAIL_CFG")"
  rm -f "$SCV_PY_MVFAIL_CFG"
  rm -rf "$(dirname "$SCV_PY_MVFAIL_BIN")"
fi

# ── Important regression guard: a genuine jq error on the eligibility check
# must not be misreported as "kept as a deliberate pin" ──────────────────────
# jq -e returns exit 1 for a legitimate false/null result but a HIGHER exit
# code (observed: 5) for a parse/runtime error. The eligibility check must
# distinguish these — an actual jq error must fall through to the generic
# warning, not be folded into the "deliberate pin" message meant only for
# genuine ineligible values. Force the error deterministically: a stub `jq`
# fault-injects an error for any `-e` invocation (the eligibility check, which
# runs before the write-filter, so the write-filter call is never reached here)
# and otherwise runs the real binary.
if command -v jq >/dev/null 2>&1; then
  SCV_REALJQ="$(command -v jq)"
  SCV_JQERR_BIN="$(mktemp -d)/bin"; mkdir -p "$SCV_JQERR_BIN"
  cat > "$SCV_JQERR_BIN/jq" <<STUBJQ
#!/bin/sh
for a in "\$@"; do
  if [ "\$a" = "-e" ]; then
    echo "jq: error (fault injected for test)" >&2
    exit 5
  fi
done
exec "$SCV_REALJQ" "\$@"
STUBJQ
  chmod +x "$SCV_JQERR_BIN/jq"
  scv_mkbin "$SCV_JQERR_BIN" mktemp mv rm
  SCV_JQERR_CFG="$(mktemp)"; printf '{"devflow_version":"abc1234"}' > "$SCV_JQERR_CFG"
  # shellcheck disable=SC1090
  SCV_JQERR_OUT="$( ( PATH="$SCV_JQERR_BIN"; DEVFLOW_SELFTEST=1 . "$SCV_INSTALL" \
      && set_config_version "$SCV_JQERR_CFG" "deadbeef1234" ) 2>&1 )"
  SCV_JQERR_RC=$?
  assert_eq "scv: jq eligibility-check error still returns 0 (degrades, never aborts)" "0" "$SCV_JQERR_RC"
  assert_eq "scv: jq eligibility-check error falls through to the generic warning" "yes" \
    "$(printf '%s' "$SCV_JQERR_OUT" | grep -q 'warning: could not set devflow_version' && echo yes || echo no)"
  assert_eq "scv: jq eligibility-check error is NOT misreported as 'kept ... deliberate pin'" "no" \
    "$(printf '%s' "$SCV_JQERR_OUT" | grep -q 'kept existing devflow_version' && echo yes || echo no)"
  assert_eq "scv: jq eligibility-check error leaves the on-disk value untouched" "abc1234" \
    "$(jq -r '.devflow_version' "$SCV_JQERR_CFG")"
  rm -f "$SCV_JQERR_CFG"
  rm -rf "$(dirname "$SCV_JQERR_BIN")"
fi

# ── Important regression guard: non-string/JSON-falsy devflow_version values
# (0, [], {}, true) must degrade safely on BOTH backends, not just jq ───────
# jq's `.devflow_version // ""` treats ONLY false/null as "absent" (0/[]/{}/
# true are all truthy-or-non-substituted in jq), so a non-string value like
# `0` reaches `test()`, which errors on a non-string input (rc>1) and falls
# through to the generic warning. The python3 backend previously used
# `c.get("devflow_version") or ""`, where Python's `or` treats ANY falsy
# value (0, [], {}, "") as "absent" — silently coercing 0/[]/{} to "" and
# overwriting them as if they were legitimately empty. Both backends must
# agree: only null/false count as absent; any other non-string value
# (including `true`, the boolean sibling of the special-cased `false`) falls
# through to the generic warning with the config untouched — never silently
# overwritten. `true` is a deliberate inclusion here, not an oversight: it is
# the one shape a future edit to the `cur is None or cur is False` identity
# check (e.g. widening it to an `isinstance(cur, bool)` check) could silently
# start treating as absent too.
scv_assert_nonstring() {  # $1=test-name suffix $2=PATH override (empty=default) $3=JSON value
  local suffix="$1" pathenv="$2" jsonval="$3" cfg out rc
  cfg="$(mktemp)"; printf '{"devflow_version":%s}' "$jsonval" > "$cfg"
  # shellcheck disable=SC1090
  out="$( ( [ -n "$pathenv" ] && PATH="$pathenv"; DEVFLOW_SELFTEST=1 . "$SCV_INSTALL" \
      && set_config_version "$cfg" "deadbeef1234" ) 2>&1 )"
  rc=$?
  assert_eq "scv$suffix: devflow_version=$jsonval still returns 0 (degrades, never aborts)" "0" "$rc"
  assert_eq "scv$suffix: devflow_version=$jsonval falls through to the generic warning" "yes" \
    "$(printf '%s' "$out" | grep -q 'warning: could not set devflow_version' && echo yes || echo no)"
  assert_eq "scv$suffix: devflow_version=$jsonval never logs 'pinned'" "no" \
    "$(printf '%s' "$out" | grep -q 'pinned devflow_version=' && echo yes || echo no)"
  assert_eq "scv$suffix: devflow_version=$jsonval on-disk value untouched" "$jsonval" \
    "$(jq -c '.devflow_version' "$cfg")"
  rm -f "$cfg"
}
if command -v jq >/dev/null 2>&1; then
  for SCV_NS_VAL in 0 '[]' '{}' true; do
    scv_assert_nonstring "" "" "$SCV_NS_VAL"
  done
fi
if command -v python3 >/dev/null 2>&1; then
  for SCV_NS_VAL in 0 '[]' '{}' true; do
    scv_assert_nonstring "(python3)" "$SCV_PY_BIN" "$SCV_NS_VAL"
  done

  # The jq backend's malformed-config degrade path is covered above (SCV_BAD,
  # gated on `command -v jq`); that guard never exercises the python3 backend's
  # own `json.load()` failure path. Mirror it here with jq shadowed off PATH so
  # a python3-side regression (e.g. an uncaught exception no longer degrading
  # cleanly) doesn't hide behind the jq-only guard on any jq-installed host.
  SCV_PY_BAD="$(mktemp)"; printf '{ not valid json' > "$SCV_PY_BAD"
  SCV_PY_BAD_RC=0
  # shellcheck disable=SC1090
  ( PATH="$SCV_PY_BIN"; DEVFLOW_SELFTEST=1 . "$SCV_INSTALL" \
      && set_config_version "$SCV_PY_BAD" "abc123" ) >/dev/null 2>&1 || SCV_PY_BAD_RC=$?
  assert_eq "scv(python3): malformed config → returns 0 (degrades, never aborts)" "0" "$SCV_PY_BAD_RC"
  rm -f "$SCV_PY_BAD"
fi

# ── devflow_version: false (JSON boolean) — the one falsy-JSON shape whose
# behavior is the OPPOSITE of the 0/[]/{} matrix above: both backends
# explicitly treat null/false (not just any falsy value) as "absent", so
# false must be silently re-stamped, not fall through to the generic warning.
# The python3 fix comment names `cur is False` explicitly as load-bearing;
# assert both sides of that branch so a future edit that narrows or widens
# the null/false special-case is caught on both backends.
if command -v jq >/dev/null 2>&1; then
  SCV_FALSE="$(mktemp)"; printf '{"devflow_version":false}' > "$SCV_FALSE"
  # shellcheck disable=SC1090
  SCV_FALSE_OUT="$( ( DEVFLOW_SELFTEST=1 . "$SCV_INSTALL" && set_config_version "$SCV_FALSE" "deadbeef1234" ) 2>&1 )"
  assert_eq "scv: devflow_version=false is stamped (treated as absent)" "deadbeef1234" \
    "$(jq -r '.devflow_version' "$SCV_FALSE")"
  assert_eq "scv: devflow_version=false stamp logs 'pinned'" "yes" \
    "$(printf '%s' "$SCV_FALSE_OUT" | grep -q 'pinned devflow_version=deadbeef1234' && echo yes || echo no)"
  rm -f "$SCV_FALSE"
fi
if command -v python3 >/dev/null 2>&1; then
  SCV_PY_FALSE="$(mktemp)"; printf '{"devflow_version":false}' > "$SCV_PY_FALSE"
  # shellcheck disable=SC1090
  SCV_PY_FALSE_OUT="$( ( PATH="$SCV_PY_BIN"; DEVFLOW_SELFTEST=1 . "$SCV_INSTALL" \
      && set_config_version "$SCV_PY_FALSE" "deadbeef1234" ) 2>&1 )"
  assert_eq "scv(python3): devflow_version=false is stamped (treated as absent)" "deadbeef1234" \
    "$(jq -r '.devflow_version' "$SCV_PY_FALSE")"
  assert_eq "scv(python3): devflow_version=false stamp logs 'pinned'" "yes" \
    "$(printf '%s' "$SCV_PY_FALSE_OUT" | grep -q 'pinned devflow_version=deadbeef1234' && echo yes || echo no)"
  rm -f "$SCV_PY_FALSE"
fi

rm -rf "$VS_COMMIT" "$VS_SELF" "$VS_REMOTE" "$VS_FETCH" "$VS_FETCH_SHA" \
       "$VS_PREC" "$VS_DECOY" "$VS_DECOY_DEST"

# ────────────────────────────────────────────────────────────────────────────
echo "provision-local-settings.sh (project .claude/settings.json provisioner)"
# ────────────────────────────────────────────────────────────────────────────
# The helper deep-merges DevFlow keys into a consumer repo's project
# .claude/settings.json — additive, non-clobbering, idempotent — and is invoked
# only from /devflow:init (never from scaffold-config.sh / install.sh). It writes
# extraKnownMarketplaces[devflow-marketplace] (autoUpdate true + a github source
# for The01Geek/devflow-autopilot) and enabledPlugins[devflow@devflow-marketplace]
# = true; it never writes permissions.defaultMode and never writes the
# CLAUDE_CODE_ENABLE_AUTO_MODE env var — that var is honored only from user scope
# (~/.claude/settings.json) / managed settings, so writing it to the PROJECT file
# would be a silent no-op; the selectable-auto-mode half lives in the separate
# user-scope provisioner provision-auto-mode.sh (issue #105), tested below.
# Lead with the adversarial existing-shape matrix per the parser-editing gotcha:
#   {missing, empty, whitespace-only, {}, other-marketplaces, other-env-vars,
#    user-defaultMode, unrelated-keys, not-JSON}.  (Issue #88, AC 1, 3-8.)
PLS="$LIB/../scripts/provision-local-settings.sh"
PLS_SC="$LIB/../scripts/scaffold-config.sh"

# AC 1 + AC 3: fresh repo (no .claude/settings.json) → file is created with the
# marketplace + enabledPlugins key groups, NO permissions.defaultMode, and NO
# CLAUDE_CODE_ENABLE_AUTO_MODE env var (deferred — see header); exit 0; breadcrumb
# names what it provisioned.
PLS_FRESH="$(mktemp -d)"
PLS_FRESH_OUT="$(bash "$PLS" "$PLS_FRESH" 2>&1)"; PLS_FRESH_RC=$?
PLS_SF="$PLS_FRESH/.claude/settings.json"
assert_eq "pls: fresh → exit 0" "0" "$PLS_FRESH_RC"
assert_eq "pls: fresh → .claude/settings.json created" "yes" \
  "$([ -f "$PLS_SF" ] && echo yes || echo no)"
assert_eq "pls: fresh → marketplace autoUpdate true (AC1)" "true" \
  "$(jq -r '.extraKnownMarketplaces["devflow-marketplace"].autoUpdate' "$PLS_SF" 2>/dev/null)"
assert_eq "pls: fresh → marketplace source is github (AC1)" "github" \
  "$(jq -r '.extraKnownMarketplaces["devflow-marketplace"].source.source' "$PLS_SF" 2>/dev/null)"
assert_eq "pls: fresh → marketplace repo The01Geek/devflow-autopilot (AC1)" "The01Geek/devflow-autopilot" \
  "$(jq -r '.extraKnownMarketplaces["devflow-marketplace"].source.repo' "$PLS_SF" 2>/dev/null)"
assert_eq "pls: fresh → enabledPlugins devflow true (AC1)" "true" \
  "$(jq -r '.enabledPlugins["devflow@devflow-marketplace"]' "$PLS_SF" 2>/dev/null)"
assert_eq "pls: fresh → CLAUDE_CODE_ENABLE_AUTO_MODE NOT written (deferred; project-scope no-op)" "false" \
  "$(jq -r '(.env // {}) | has("CLAUDE_CODE_ENABLE_AUTO_MODE")' "$PLS_SF" 2>/dev/null)"
assert_eq "pls: fresh → no permissions key written (AC3)" "false" \
  "$(jq -r 'has("permissions")' "$PLS_SF" 2>/dev/null)"
assert_eq "pls: fresh → breadcrumb names what it provisioned (AC8)" "yes" \
  "$(printf '%s' "$PLS_FRESH_OUT" | grep -qiE 'provision|added' && echo yes || echo no)"
assert_eq "pls: fresh → breadcrumb says review before committing (AC8)" "yes" \
  "$(printf '%s' "$PLS_FRESH_OUT" | grep -qi 'review' && echo yes || echo no)"

# AC 4: existing settings with user values → every pre-existing key/value is
# preserved (other marketplace, other env var, user defaultMode, unrelated top
# key) and only the missing DevFlow keys are added.
PLS_KEEP="$(mktemp -d)"; mkdir -p "$PLS_KEEP/.claude"
printf '%s\n' '{"extraKnownMarketplaces":{"other-mp":{"source":{"source":"github","repo":"acme/other"},"autoUpdate":false}},"env":{"FOO":"bar"},"permissions":{"defaultMode":"plan"},"customTopKey":123}' \
  > "$PLS_KEEP/.claude/settings.json"
PLS_KEEP_OUT="$(bash "$PLS" "$PLS_KEEP" 2>&1)"; PLS_KEEP_RC=$?
PLS_SK="$PLS_KEEP/.claude/settings.json"
assert_eq "pls: keep → exit 0" "0" "$PLS_KEEP_RC"
assert_eq "pls: keep → other marketplace repo preserved (AC4)" "acme/other" \
  "$(jq -r '.extraKnownMarketplaces["other-mp"].source.repo' "$PLS_SK" 2>/dev/null)"
assert_eq "pls: keep → other marketplace autoUpdate preserved (AC4)" "false" \
  "$(jq -r '.extraKnownMarketplaces["other-mp"].autoUpdate' "$PLS_SK" 2>/dev/null)"
assert_eq "pls: keep → other env var preserved (AC4)" "bar" \
  "$(jq -r '.env.FOO' "$PLS_SK" 2>/dev/null)"
assert_eq "pls: keep → user defaultMode NOT clobbered (AC4)" "plan" \
  "$(jq -r '.permissions.defaultMode' "$PLS_SK" 2>/dev/null)"
assert_eq "pls: keep → unrelated top-level key preserved (AC4)" "123" \
  "$(jq -r '.customTopKey' "$PLS_SK" 2>/dev/null)"
assert_eq "pls: keep → devflow marketplace added alongside (AC4)" "true" \
  "$(jq -r '.extraKnownMarketplaces["devflow-marketplace"].autoUpdate' "$PLS_SK" 2>/dev/null)"
assert_eq "pls: keep → enabledPlugins added (AC4)" "true" \
  "$(jq -r '.enabledPlugins["devflow@devflow-marketplace"]' "$PLS_SK" 2>/dev/null)"

# AC 5: idempotent re-run → byte-identical file, "nothing changed" breadcrumb,
# no duplicate entries.
PLS_IDEM="$(mktemp -d)"
bash "$PLS" "$PLS_IDEM" >/dev/null 2>&1
PLS_SI="$PLS_IDEM/.claude/settings.json"
PLS_IDEM_FIRST="$(cat "$PLS_SI")"
PLS_IDEM_OUT="$(bash "$PLS" "$PLS_IDEM" 2>&1)"; PLS_IDEM_RC=$?
PLS_IDEM_SECOND="$(cat "$PLS_SI")"
assert_eq "pls: idempotent → second run exit 0 (AC5)" "0" "$PLS_IDEM_RC"
assert_eq "pls: idempotent → file byte-identical after re-run (AC5)" \
  "$PLS_IDEM_FIRST" "$PLS_IDEM_SECOND"
assert_eq "pls: idempotent → 'nothing changed' breadcrumb (AC5)" "yes" \
  "$(printf '%s' "$PLS_IDEM_OUT" | grep -qi 'nothing changed' && echo yes || echo no)"
assert_eq "pls: idempotent → no duplicate marketplace entry (AC5)" "1" \
  "$(jq -r '.extraKnownMarketplaces | length' "$PLS_SI" 2>/dev/null)"

# AC 6: malformed (non-empty invalid JSON) → exit non-zero, specific breadcrumb,
# file left byte-for-byte unchanged (no clobber/partial edit).
PLS_BAD="$(mktemp -d)"; mkdir -p "$PLS_BAD/.claude"
printf '%s' '{ not valid json' > "$PLS_BAD/.claude/settings.json"
PLS_BAD_OUT="$(bash "$PLS" "$PLS_BAD" 2>&1)"; PLS_BAD_RC=$?
assert_eq "pls: malformed → exit non-zero (AC6)" "yes" \
  "$([ "$PLS_BAD_RC" -ne 0 ] && echo yes || echo no)"
assert_eq "pls: malformed → file byte-for-byte unchanged (AC6)" '{ not valid json' \
  "$(cat "$PLS_BAD/.claude/settings.json")"
assert_eq "pls: malformed → breadcrumb names the malformed-settings condition (AC6)" "yes" \
  "$(printf '%s' "$PLS_BAD_OUT" | grep -qiE 'not valid json|malformed' && echo yes || echo no)"

# Present-but-unreadable settings file → exit 2 with a distinct "not readable"
# breadcrumb (not misattributed to invalid JSON), file untouched. Root bypasses
# the perm bits, so assert only for an ordinary user — skip under root rather than
# reporting a false FAIL (same guard the load-prompt-extension block uses).
PLS_UNREAD="$(mktemp -d)"; mkdir -p "$PLS_UNREAD/.claude"
printf '%s' '{"env":{"FOO":"bar"}}' > "$PLS_UNREAD/.claude/settings.json"
chmod 000 "$PLS_UNREAD/.claude/settings.json"
if [ "$(id -u)" -ne 0 ] && [ ! -r "$PLS_UNREAD/.claude/settings.json" ]; then
  PLS_UNREAD_OUT="$(bash "$PLS" "$PLS_UNREAD" 2>&1)"; PLS_UNREAD_RC=$?
  assert_eq "pls: unreadable settings → exit non-zero" "yes" \
    "$([ "$PLS_UNREAD_RC" -ne 0 ] && echo yes || echo no)"
  assert_eq "pls: unreadable settings → breadcrumb says 'not readable' (not 'invalid JSON')" "yes" \
    "$(printf '%s' "$PLS_UNREAD_OUT" | grep -qi 'not readable' && echo yes || echo no)"
fi
chmod 644 "$PLS_UNREAD/.claude/settings.json"   # restore so rm -rf can clean up

# Valid JSON but WRONG SHAPE — a non-object root (array / scalar) or a DevFlow
# container key present as a non-object — is corrupt for provisioning: exit
# non-zero, specific breadcrumb, file byte-for-byte unchanged. These shapes parse
# as JSON (so the not-JSON gate above lets them through) but would otherwise
# either crash the merge (object * array/scalar → jq error) or silently drop the
# DevFlow setting. (Issue #88 review: non-object-root + wrong-typed sub-key.)
PLS_ARR="$(mktemp -d)"; mkdir -p "$PLS_ARR/.claude"
printf '%s' '[1,2,3]' > "$PLS_ARR/.claude/settings.json"
PLS_ARR_OUT="$(bash "$PLS" "$PLS_ARR" 2>&1)"; PLS_ARR_RC=$?
assert_eq "pls: array root → exit non-zero (no uncaught jq crash)" "yes" \
  "$([ "$PLS_ARR_RC" -ne 0 ] && echo yes || echo no)"
assert_eq "pls: array root → file byte-for-byte unchanged" '[1,2,3]' \
  "$(cat "$PLS_ARR/.claude/settings.json")"
assert_eq "pls: array root → specific breadcrumb names the wrong shape" "yes" \
  "$(printf '%s' "$PLS_ARR_OUT" | grep -qiE 'not a JSON object|malformed' && echo yes || echo no)"

PLS_SCALAR="$(mktemp -d)"; mkdir -p "$PLS_SCALAR/.claude"
printf '%s' '42' > "$PLS_SCALAR/.claude/settings.json"
PLS_SCALAR_OUT="$(bash "$PLS" "$PLS_SCALAR" 2>&1)"; PLS_SCALAR_RC=$?
assert_eq "pls: scalar root → exit non-zero" "yes" \
  "$([ "$PLS_SCALAR_RC" -ne 0 ] && echo yes || echo no)"
assert_eq "pls: scalar root → file unchanged" '42' \
  "$(cat "$PLS_SCALAR/.claude/settings.json")"
assert_eq "pls: scalar root → specific breadcrumb names the wrong shape" "yes" \
  "$(printf '%s' "$PLS_SCALAR_OUT" | grep -qiE 'not a JSON object|malformed' && echo yes || echo no)"

# Nested wrong-typed DevFlow object: extraKnownMarketplaces is a valid object (so
# it passes the top-level container check) but the devflow-marketplace entry is a
# non-object. Without the depth guard the merge silently keeps the user's scalar
# and drops DevFlow's marketplace source+autoUpdate while exiting 0 with a success
# breadcrumb. Must exit non-zero, name the devflow-marketplace entry, leave the
# file unchanged. (Issue #88 iter-2 review: nested silent-drop.)
PLS_NESTED="$(mktemp -d)"; mkdir -p "$PLS_NESTED/.claude"
printf '%s' '{"extraKnownMarketplaces":{"devflow-marketplace":"oops"}}' > "$PLS_NESTED/.claude/settings.json"
PLS_NESTED_OUT="$(bash "$PLS" "$PLS_NESTED" 2>&1)"; PLS_NESTED_RC=$?
assert_eq "pls: nested wrong-typed marketplace → exit non-zero (not a silent drop)" "yes" \
  "$([ "$PLS_NESTED_RC" -ne 0 ] && echo yes || echo no)"
assert_eq "pls: nested wrong-typed marketplace → file byte-for-byte unchanged" \
  '{"extraKnownMarketplaces":{"devflow-marketplace":"oops"}}' \
  "$(cat "$PLS_NESTED/.claude/settings.json")"
assert_eq "pls: nested wrong-typed marketplace → breadcrumb names devflow-marketplace" "yes" \
  "$(printf '%s' "$PLS_NESTED_OUT" | grep -qi 'devflow-marketplace' && echo yes || echo no)"

# One level deeper still: devflow-marketplace is a valid object but its `source`
# (a DevFlow-owned object) is wrong-typed. The general object-path guard must
# catch this too (not just the one-level-up case), proving it covers every level
# the merge recurses through rather than a hand-enumerated subset.
PLS_DEEP="$(mktemp -d)"; mkdir -p "$PLS_DEEP/.claude"
printf '%s' '{"extraKnownMarketplaces":{"devflow-marketplace":{"source":"x","autoUpdate":true}}}' > "$PLS_DEEP/.claude/settings.json"
PLS_DEEP_OUT="$(bash "$PLS" "$PLS_DEEP" 2>&1)"; PLS_DEEP_RC=$?
assert_eq "pls: deep wrong-typed source → exit non-zero (general guard covers all levels)" "yes" \
  "$([ "$PLS_DEEP_RC" -ne 0 ] && echo yes || echo no)"
assert_eq "pls: deep wrong-typed source → file byte-for-byte unchanged" \
  '{"extraKnownMarketplaces":{"devflow-marketplace":{"source":"x","autoUpdate":true}}}' \
  "$(cat "$PLS_DEEP/.claude/settings.json")"
assert_eq "pls: deep wrong-typed source → breadcrumb names the source path" "yes" \
  "$(printf '%s' "$PLS_DEEP_OUT" | grep -qi 'source' && echo yes || echo no)"

# Merge-direction (user-wins) guard: a user who set a DevFlow-owned value to a
# NON-default keeps it — provisioning must not clobber it. This pins the operand
# order ($defaults * $existing); an accidental inversion would flip autoUpdate
# back to true and this fails. (The earlier keep test only covers ABSENT DevFlow
# keys, which an inverted merge would still add — so it cannot catch a flip.)
PLS_NODEFAULT="$(mktemp -d)"; mkdir -p "$PLS_NODEFAULT/.claude"
printf '%s' '{"extraKnownMarketplaces":{"devflow-marketplace":{"source":{"source":"github","repo":"The01Geek/devflow-autopilot"},"autoUpdate":false}},"enabledPlugins":{"devflow@devflow-marketplace":false}}' \
  > "$PLS_NODEFAULT/.claude/settings.json"
bash "$PLS" "$PLS_NODEFAULT" >/dev/null 2>&1; PLS_ND_RC=$?
PLS_ND_SF="$PLS_NODEFAULT/.claude/settings.json"
assert_eq "pls: user-set DevFlow non-default → exit 0" "0" "$PLS_ND_RC"
assert_eq "pls: user-set autoUpdate:false NOT clobbered (merge direction)" "false" \
  "$(jq -r '.extraKnownMarketplaces["devflow-marketplace"].autoUpdate' "$PLS_ND_SF" 2>/dev/null)"
assert_eq "pls: user-set enabledPlugins:false NOT clobbered (merge direction)" "false" \
  "$(jq -r '.enabledPlugins["devflow@devflow-marketplace"]' "$PLS_ND_SF" 2>/dev/null)"

# The provisioner never writes the auto-mode env var, so a user's pre-existing
# env block — including a deliberately-disabled CLAUDE_CODE_ENABLE_AUTO_MODE="0" —
# is left exactly as-is (the merge does not touch `env` at all now). Guards against
# a regression that re-introduces an env write and flips a user's consent leaf.
PLS_ENV0="$(mktemp -d)"; mkdir -p "$PLS_ENV0/.claude"
printf '%s' '{"env":{"CLAUDE_CODE_ENABLE_AUTO_MODE":"0"}}' > "$PLS_ENV0/.claude/settings.json"
bash "$PLS" "$PLS_ENV0" >/dev/null 2>&1
assert_eq "pls: user env auto-mode \"0\" left untouched (provisioner writes no env)" "0" \
  "$(jq -r '.env.CLAUDE_CODE_ENABLE_AUTO_MODE' "$PLS_ENV0/.claude/settings.json" 2>/dev/null)"

# null at a DevFlow object-valued path is NOT exempt: jq merge treats a present
# null as a winning value that replaces the defaults subtree (silently dropping
# the setting), so it is rejected exactly like a wrong-typed scalar — exit
# non-zero, file unchanged, path named. Absent paths (getpath also returns null)
# must stay benign, which the fresh/keep/empty cases above already prove.
for nullcase in '{"enabledPlugins":null}' '{"extraKnownMarketplaces":null}' '{"extraKnownMarketplaces":{"devflow-marketplace":null}}'; do
  PLS_NULL="$(mktemp -d)"; mkdir -p "$PLS_NULL/.claude"
  printf '%s' "$nullcase" > "$PLS_NULL/.claude/settings.json"
  PLS_NULL_OUT="$(bash "$PLS" "$PLS_NULL" 2>&1)"; PLS_NULL_RC=$?
  assert_eq "pls: present-null at a DevFlow path ($nullcase) → exit non-zero" "yes" \
    "$([ "$PLS_NULL_RC" -ne 0 ] && echo yes || echo no)"
  assert_eq "pls: present-null ($nullcase) → file byte-for-byte unchanged" "$nullcase" \
    "$(cat "$PLS_NULL/.claude/settings.json")"
  assert_eq "pls: present-null ($nullcase) → breadcrumb names a wrong-shape path" "yes" \
    "$(printf '%s' "$PLS_NULL_OUT" | grep -qiE 'not a JSON object|malformed' && echo yes || echo no)"
  rm -rf "$PLS_NULL"
done

# Wrong-typed DevFlow container key (extraKnownMarketplaces as a string) → exit
# non-zero, named in the breadcrumb, file unchanged, and (critically) the DevFlow
# marketplace is NOT silently dropped behind a false "added" breadcrumb.
PLS_WRONGTYPE="$(mktemp -d)"; mkdir -p "$PLS_WRONGTYPE/.claude"
printf '%s' '{"extraKnownMarketplaces":"oops","other":1}' > "$PLS_WRONGTYPE/.claude/settings.json"
PLS_WT_OUT="$(bash "$PLS" "$PLS_WRONGTYPE" 2>&1)"; PLS_WT_RC=$?
assert_eq "pls: wrong-typed container (extraKnownMarketplaces=string) → exit non-zero" "yes" \
  "$([ "$PLS_WT_RC" -ne 0 ] && echo yes || echo no)"
assert_eq "pls: wrong-typed container → file byte-for-byte unchanged" '{"extraKnownMarketplaces":"oops","other":1}' \
  "$(cat "$PLS_WRONGTYPE/.claude/settings.json")"
assert_eq "pls: wrong-typed container → breadcrumb names the extraKnownMarketplaces path" "yes" \
  "$(printf '%s' "$PLS_WT_OUT" | grep -qi 'extraKnownMarketplaces' && echo yes || echo no)"

# Empty / whitespace-only / {} existing files are benign (treated as {}), NOT
# malformed: DevFlow keys are added, exit 0.
PLS_EMPTY="$(mktemp -d)"; mkdir -p "$PLS_EMPTY/.claude"
: > "$PLS_EMPTY/.claude/settings.json"
PLS_EMPTY_OUT="$(bash "$PLS" "$PLS_EMPTY" 2>&1)"; PLS_EMPTY_RC=$?
assert_eq "pls: empty file → exit 0 (not malformed)" "0" "$PLS_EMPTY_RC"
assert_eq "pls: empty file → marketplace added" "true" \
  "$(jq -r '.extraKnownMarketplaces["devflow-marketplace"].autoUpdate' "$PLS_EMPTY/.claude/settings.json" 2>/dev/null)"

PLS_WS="$(mktemp -d)"; mkdir -p "$PLS_WS/.claude"
printf '   \n\t\n' > "$PLS_WS/.claude/settings.json"
PLS_WS_OUT="$(bash "$PLS" "$PLS_WS" 2>&1)"; PLS_WS_RC=$?
assert_eq "pls: whitespace-only file → exit 0 (treated as empty, not malformed)" "0" "$PLS_WS_RC"
assert_eq "pls: whitespace-only → marketplace added" "true" \
  "$(jq -r '.extraKnownMarketplaces["devflow-marketplace"].autoUpdate' "$PLS_WS/.claude/settings.json" 2>/dev/null)"

PLS_OBJ="$(mktemp -d)"; mkdir -p "$PLS_OBJ/.claude"
printf '%s' '{}' > "$PLS_OBJ/.claude/settings.json"
PLS_OBJ_OUT="$(bash "$PLS" "$PLS_OBJ" 2>&1)"; PLS_OBJ_RC=$?
assert_eq "pls: {} → exit 0" "0" "$PLS_OBJ_RC"
assert_eq "pls: {} → enabledPlugins added" "true" \
  "$(jq -r '.enabledPlugins["devflow@devflow-marketplace"]' "$PLS_OBJ/.claude/settings.json" 2>/dev/null)"

# AC 7: isolation invariant — the cloud path (scaffold-config.sh, as install.sh
# calls it) creates/modifies NO .claude/settings.json.
PLS_ISO="$(mktemp -d)"
bash "$PLS_SC" "$PLS_ISO" >/dev/null 2>&1
assert_eq "pls: isolation → scaffold-config.sh writes no .claude/settings.json (AC7)" "no" \
  "$([ -f "$PLS_ISO/.claude/settings.json" ] && echo yes || echo no)"
assert_eq "pls: isolation → scaffold-config.sh creates no .claude/ dir (AC7)" "no" \
  "$([ -d "$PLS_ISO/.claude" ] && echo yes || echo no)"

rm -rf "$PLS_FRESH" "$PLS_KEEP" "$PLS_IDEM" "$PLS_BAD" "$PLS_EMPTY" "$PLS_WS" \
       "$PLS_OBJ" "$PLS_ISO" "$PLS_ARR" "$PLS_SCALAR" "$PLS_WRONGTYPE" \
       "$PLS_NESTED" "$PLS_NODEFAULT" "$PLS_DEEP" "$PLS_ENV0" "$PLS_UNREAD"

# ────────────────────────────────────────────────────────────────────────────
echo "provision-auto-mode.sh (user-scope ~/.claude/settings.json auto-mode provisioner)"
# ────────────────────────────────────────────────────────────────────────────
# The deferred-from-#88 selectable-auto-mode half (issue #105). CLAUDE_CODE_ENABLE_AUTO_MODE
# is a permission-gating env var honored only from USER scope (~/.claude/settings.json) /
# managed settings, so this helper writes it there (never project scope). It is selectable,
# never on: it writes only env.CLAUDE_CODE_ENABLE_AUTO_MODE="1", never permissions.defaultMode.
# Because ~/.claude/settings.json is user-global, it never writes without explicit consent:
# default (no --apply) prints the copy-paste line and writes nothing; --apply (the caller's
# confirmed consent) performs the same additive, non-clobbering, atomic, fail-closed merge as
# provision-local-settings.sh — incl. NEVER clobbering a deliberately-disabled "0".
# Lead with the adversarial existing-shape matrix per the parser-editing gotcha:
#   {missing, empty, {}, env-with-other-keys, user-"0", user-"1", env-as-string, array-root,
#    not-JSON}. (Issue #105, AC 1-5.)
PAM="$LIB/../scripts/provision-auto-mode.sh"

# Provider gate (issue #130): provision-auto-mode.sh --apply is a NO-OP on Anthropic-direct
# (none of CLAUDE_CODE_USE_{BEDROCK,VERTEX,FOUNDRY} truthy) — the env var it would write only
# affects third-party providers (Bedrock/Vertex/Foundry). Every existing --apply write /
# idempotent / no-clobber / shape-matrix cell below exercises the path PAST that gate, so set a
# third-party provider var for the whole block; the new gate cells (further down) override the
# env per-case with `env -u …` / explicit non-truthy values. The no-`--apply` consent cells are
# gate-independent (the gate is on the --apply path only) but inherit this harmlessly. We unset
# the var at the end of the block so it cannot leak into later test blocks.
export CLAUDE_CODE_USE_BEDROCK=1

# AC 2 (consent gate): default (no --apply) writes NOTHING and surfaces the copy-paste line.
PAM_NOCONSENT="$(mktemp -d)"; PAM_NC_SF="$PAM_NOCONSENT/settings.json"
PAM_NC_OUT="$(bash "$PAM" "$PAM_NC_SF" 2>&1)"; PAM_NC_RC=$?
assert_eq "pam: no --apply → exit 0 (AC2)" "0" "$PAM_NC_RC"
assert_eq "pam: no --apply → file NOT created (no touch without consent, AC2)" "no" \
  "$([ -f "$PAM_NC_SF" ] && echo yes || echo no)"
assert_eq "pam: no --apply → prints the copy-paste env var (AC1 copy-paste path)" "yes" \
  "$(printf '%s' "$PAM_NC_OUT" | grep -q 'CLAUDE_CODE_ENABLE_AUTO_MODE' && echo yes || echo no)"
assert_eq "pam: no --apply → honest 'selectable' framing, not 'on' (AC4)" "yes" \
  "$(printf '%s' "$PAM_NC_OUT" | grep -qi 'selectable' && echo yes || echo no)"
# The copy-paste hint prints the INNER key only ("CLAUDE_CODE_ENABLE_AUTO_MODE": "1"), never a
# full '"env": { … }' wrapper — pasting a second "env" block into an existing env object would
# create a duplicate key. The grep-for-var-name assertion above would still pass on a regressed
# full-wrapper print, so pin the intentional inner-key-only shape: no bare `"env"` wrapper line.
assert_eq "pam: no --apply → prints the INNER key only, not an '\"env\": {' wrapper (no dup-env clobber)" "no" \
  "$(printf '%s' "$PAM_NC_OUT" | grep -qE '"env"[[:space:]]*:' && echo yes || echo no)"

# AC 2 (consent gate over an EXISTING populated file): no --apply still writes nothing —
# a deliberate "0" is left byte-for-byte unchanged (the strongest 'no touch without consent').
PAM_NCEXIST="$(mktemp -d)"; PAM_NCE_SF="$PAM_NCEXIST/settings.json"
printf '%s' '{"env":{"CLAUDE_CODE_ENABLE_AUTO_MODE":"0"}}' > "$PAM_NCE_SF"
PAM_NCE_BEFORE="$(cat "$PAM_NCE_SF")"
bash "$PAM" "$PAM_NCE_SF" >/dev/null 2>&1; PAM_NCE_RC=$?
assert_eq "pam: no --apply over existing '0' → exit 0 (AC2)" "0" "$PAM_NCE_RC"
assert_eq "pam: no --apply over existing file → byte-for-byte unchanged (no touch without consent, AC2)" \
  "$PAM_NCE_BEFORE" "$(cat "$PAM_NCE_SF")"

# AC 1 + AC 4 (apply path): fresh file → env.CLAUDE_CODE_ENABLE_AUTO_MODE="1" written to
# the (user-scope) target, NO permissions.defaultMode, exit 0, breadcrumb says selectable.
PAM_FRESH="$(mktemp -d)"; PAM_F_SF="$PAM_FRESH/settings.json"
PAM_F_OUT="$(bash "$PAM" --apply "$PAM_F_SF" 2>&1)"; PAM_F_RC=$?
assert_eq "pam: --apply fresh → exit 0" "0" "$PAM_F_RC"
assert_eq "pam: --apply fresh → file created" "yes" "$([ -f "$PAM_F_SF" ] && echo yes || echo no)"
assert_eq "pam: --apply fresh → CLAUDE_CODE_ENABLE_AUTO_MODE=1 written (AC1)" "1" \
  "$(jq -r '.env.CLAUDE_CODE_ENABLE_AUTO_MODE' "$PAM_F_SF" 2>/dev/null)"
assert_eq "pam: --apply fresh → no permissions.defaultMode (selectable, not on; AC4)" "false" \
  "$(jq -r 'has("permissions")' "$PAM_F_SF" 2>/dev/null)"
assert_eq "pam: --apply fresh → breadcrumb says 'selectable' (honest, AC4)" "yes" \
  "$(printf '%s' "$PAM_F_OUT" | grep -qi 'selectable' && echo yes || echo no)"

# AC 3 (no-clobber): a deliberately-disabled "0" is preserved (never flipped to "1"),
# even under --apply; other env vars preserved; idempotent breadcrumb.
PAM_ZERO="$(mktemp -d)"; PAM_Z_SF="$PAM_ZERO/settings.json"
printf '%s' '{"env":{"CLAUDE_CODE_ENABLE_AUTO_MODE":"0","FOO":"bar"}}' > "$PAM_Z_SF"
PAM_Z_BEFORE="$(cat "$PAM_Z_SF")"
PAM_Z_OUT="$(bash "$PAM" --apply "$PAM_Z_SF" 2>&1)"; PAM_Z_RC=$?
assert_eq "pam: --apply over user '0' → exit 0" "0" "$PAM_Z_RC"
assert_eq "pam: --apply over user '0' → '0' preserved, never clobbered (AC3)" "0" \
  "$(jq -r '.env.CLAUDE_CODE_ENABLE_AUTO_MODE' "$PAM_Z_SF" 2>/dev/null)"
assert_eq "pam: --apply over user '0' → other env var preserved (AC3)" "bar" \
  "$(jq -r '.env.FOO' "$PAM_Z_SF" 2>/dev/null)"
assert_eq "pam: --apply over user '0' → 'nothing changed' breadcrumb (AC3)" "yes" \
  "$(printf '%s' "$PAM_Z_OUT" | grep -qi 'nothing changed' && echo yes || echo no)"
assert_eq "pam: --apply over user '0' → breadcrumb says NOT selectable, never implies 'on' (honest, AC4)" "yes" \
  "$(printf '%s' "$PAM_Z_OUT" | grep -qi 'NOT selectable' && echo yes || echo no)"
assert_eq "pam: --apply over user '0' → file byte-for-byte unchanged (no-write branch, AC3)" \
  "$PAM_Z_BEFORE" "$(cat "$PAM_Z_SF")"

# AC 3 (no-clobber): an arbitrary non-"0"/non-"1" leaf (e.g. a "true"/"yes" user typo) hits the
# else-branch of the two PRESERVED breadcrumbs and must be preserved-and-reported "NOT
# selectable", same as "0". The "0" cell above exercises only one value of that branch; SKILL.md
# relays this breadcrumb verbatim, so the distinction is contractual for any non-"1" value.
PAM_NONONE="$(mktemp -d)"; PAM_NN_SF="$PAM_NONONE/settings.json"
printf '%s' '{"env":{"CLAUDE_CODE_ENABLE_AUTO_MODE":"true"}}' > "$PAM_NN_SF"
PAM_NN_BEFORE="$(cat "$PAM_NN_SF")"
PAM_NN_OUT="$(bash "$PAM" --apply "$PAM_NN_SF" 2>&1)"; PAM_NN_RC=$?
assert_eq "pam: --apply over user 'true' → exit 0" "0" "$PAM_NN_RC"
assert_eq "pam: --apply over user 'true' → value preserved, never clobbered to '1' (AC3)" "true" \
  "$(jq -r '.env.CLAUDE_CODE_ENABLE_AUTO_MODE' "$PAM_NN_SF" 2>/dev/null)"
assert_eq "pam: --apply over user 'true' → breadcrumb says NOT selectable (else-branch, AC4)" "yes" \
  "$(printf '%s' "$PAM_NN_OUT" | grep -qi 'NOT selectable' && echo yes || echo no)"
assert_eq "pam: --apply over user 'true' → file byte-for-byte unchanged (AC3)" \
  "$PAM_NN_BEFORE" "$(cat "$PAM_NN_SF")"

# AC 4 (honest breadcrumb on a non-string leaf): a JSON NUMBER 1 (legal hand-edited JSON, but
# NOT honored by Claude Code, which honors only the string "1") must be reported "NOT
# selectable" and preserved — never the false "already selectable". `jq -r` collapses numeric 1
# to the same "1" as the string; the helper reads the raw `jq -c` form ('"1"' for the string,
# '1' for the number) precisely so this misreport cannot happen. Mutation: revert the read to
# `jq -r`/compare to "1" and this cell goes RED ("already selectable" leaks for a value Claude
# Code ignores).
PAM_NUM1="$(mktemp -d)"; PAM_N1_SF="$PAM_NUM1/settings.json"
printf '%s' '{"env":{"CLAUDE_CODE_ENABLE_AUTO_MODE":1}}' > "$PAM_N1_SF"
PAM_N1_BEFORE="$(cat "$PAM_N1_SF")"
PAM_N1_OUT="$(bash "$PAM" --apply "$PAM_N1_SF" 2>&1)"; PAM_N1_RC=$?
assert_eq "pam: --apply over numeric 1 → exit 0" "0" "$PAM_N1_RC"
assert_eq "pam: --apply over numeric 1 → NOT falsely 'already selectable' (honest breadcrumb, AC4)" "no" \
  "$(printf '%s' "$PAM_N1_OUT" | grep -qi 'already selectable' && echo yes || echo no)"
assert_eq "pam: --apply over numeric 1 → breadcrumb says NOT selectable (non-string leaf, AC4)" "yes" \
  "$(printf '%s' "$PAM_N1_OUT" | grep -qi 'NOT selectable' && echo yes || echo no)"
assert_eq "pam: --apply over numeric 1 → value preserved, not clobbered (AC3)" "1" \
  "$(jq -r '.env.CLAUDE_CODE_ENABLE_AUTO_MODE' "$PAM_N1_SF" 2>/dev/null)"
assert_eq "pam: --apply over numeric 1 → leaf type still number, never coerced to string (AC3)" "number" \
  "$(jq -r '.env.CLAUDE_CODE_ENABLE_AUTO_MODE | type' "$PAM_N1_SF" 2>/dev/null)"
assert_eq "pam: --apply over numeric 1 → file byte-for-byte unchanged (AC3)" \
  "$PAM_N1_BEFORE" "$(cat "$PAM_N1_SF")"

# AC 4 (honest breadcrumb on a JSON false/null leaf): both are legal, both are non-honored,
# and jq's `//` treats BOTH as empty — so the no-change breadcrumb read must NOT use `// empty`
# or it blanks the preserved value ("…AUTO_MODE= (your value is preserved)…"). Assert the
# literal value is shown (not blank) AND it is reported NOT selectable, for false and null.
# Mutation: re-add `// empty` to the jq -c read and the "shows the literal value" cells go RED.
for _v in false null; do
  PAM_FN="$(mktemp -d)"; PAM_FN_SF="$PAM_FN/settings.json"
  printf '%s' "{\"env\":{\"CLAUDE_CODE_ENABLE_AUTO_MODE\":$_v}}" > "$PAM_FN_SF"
  PAM_FN_OUT="$(bash "$PAM" --apply "$PAM_FN_SF" 2>&1)"; PAM_FN_RC=$?
  assert_eq "pam: --apply over $_v leaf → exit 0" "0" "$PAM_FN_RC"
  assert_eq "pam: --apply over $_v leaf → breadcrumb says NOT selectable (AC4)" "yes" \
    "$(printf '%s' "$PAM_FN_OUT" | grep -qi 'NOT selectable' && echo yes || echo no)"
  assert_eq "pam: --apply over $_v leaf → breadcrumb shows the literal '$_v', not a blank value (AC4)" "yes" \
    "$(printf '%s' "$PAM_FN_OUT" | grep -qE "CLAUDE_CODE_ENABLE_AUTO_MODE=$_v[[:space:]]" && echo yes || echo no)"
  rm -rf "$PAM_FN"
done

# AC 3 (no-clobber): existing env + unrelated top key → auto-mode added alongside, all preserved.
PAM_KEEP="$(mktemp -d)"; PAM_K_SF="$PAM_KEEP/settings.json"
printf '%s' '{"env":{"OTHER":"x"},"customTopKey":123}' > "$PAM_K_SF"
bash "$PAM" --apply "$PAM_K_SF" >/dev/null 2>&1; PAM_K_RC=$?
assert_eq "pam: --apply keep → exit 0" "0" "$PAM_K_RC"
assert_eq "pam: --apply keep → auto-mode added alongside (AC1)" "1" \
  "$(jq -r '.env.CLAUDE_CODE_ENABLE_AUTO_MODE' "$PAM_K_SF" 2>/dev/null)"
assert_eq "pam: --apply keep → other env var preserved (AC3)" "x" \
  "$(jq -r '.env.OTHER' "$PAM_K_SF" 2>/dev/null)"
assert_eq "pam: --apply keep → unrelated top-level key preserved (AC3)" "123" \
  "$(jq -r '.customTopKey' "$PAM_K_SF" 2>/dev/null)"

# AC 3 (idempotent): re-run --apply over an already-provisioned "1" → byte-identical,
# 'nothing changed', no second write.
PAM_IDEM="$(mktemp -d)"; PAM_I_SF="$PAM_IDEM/settings.json"
bash "$PAM" --apply "$PAM_I_SF" >/dev/null 2>&1
PAM_I_FIRST="$(cat "$PAM_I_SF")"
PAM_I_OUT="$(bash "$PAM" --apply "$PAM_I_SF" 2>&1)"; PAM_I_RC=$?
PAM_I_SECOND="$(cat "$PAM_I_SF")"
assert_eq "pam: idempotent → second --apply exit 0 (AC3)" "0" "$PAM_I_RC"
assert_eq "pam: idempotent → file byte-identical (AC3)" "$PAM_I_FIRST" "$PAM_I_SECOND"
assert_eq "pam: idempotent → 'nothing changed' breadcrumb (AC3)" "yes" \
  "$(printf '%s' "$PAM_I_OUT" | grep -qi 'nothing changed' && echo yes || echo no)"

# AC 3 (fail-closed): malformed existing JSON → exit non-zero, file byte-for-byte unchanged.
PAM_BAD="$(mktemp -d)"; PAM_B_SF="$PAM_BAD/settings.json"
printf '%s' '{ not valid json' > "$PAM_B_SF"
PAM_B_OUT="$(bash "$PAM" --apply "$PAM_B_SF" 2>&1)"; PAM_B_RC=$?
assert_eq "pam: --apply malformed → exit non-zero (fail-closed, AC3)" "yes" \
  "$([ "$PAM_B_RC" -ne 0 ] && echo yes || echo no)"
assert_eq "pam: --apply malformed → file byte-for-byte unchanged (AC3)" '{ not valid json' \
  "$(cat "$PAM_B_SF")"
# Pin the target-unique substring 'not valid JSON', not the loose 'not valid json|malformed'
# alternation: 'malformed' is the WRONG-SHAPE path's breadcrumb (the 'is malformed for
# provisioning' warn in provision-auto-mode.sh), so the alternation would also pass if a
# regression misrouted an invalid-JSON file into the shape-guard's generic message. Same
# discipline the env-as-string cell below applies.
assert_eq "pam: --apply malformed → specific breadcrumb says 'not valid JSON' (not the wrong-shape message)" "yes" \
  "$(printf '%s' "$PAM_B_OUT" | grep -qi 'not valid JSON' && echo yes || echo no)"

# AC 3 (fail-closed): `env` present as a non-object → exit non-zero, unchanged, path named.
# Without the depth guard the merge would silently drop DevFlow's env and exit 0.
PAM_ENVSTR="$(mktemp -d)"; PAM_ES_SF="$PAM_ENVSTR/settings.json"
printf '%s' '{"env":"oops"}' > "$PAM_ES_SF"
PAM_ES_OUT="$(bash "$PAM" --apply "$PAM_ES_SF" 2>&1)"; PAM_ES_RC=$?
assert_eq "pam: --apply env-as-string → exit non-zero (no silent drop, AC3)" "yes" \
  "$([ "$PAM_ES_RC" -ne 0 ] && echo yes || echo no)"
assert_eq "pam: --apply env-as-string → file unchanged" '{"env":"oops"}' "$(cat "$PAM_ES_SF")"
# Target-unique substring: a bare grep -qi 'env' would also pass on the generic guard
# breadcrumb ("settings-shape check failed") that does NOT name the env path, so assert
# the specific shape message instead — the test must prove the precise no-silent-drop path.
assert_eq "pam: --apply env-as-string → breadcrumb specifically names the env path" "yes" \
  "$(printf '%s' "$PAM_ES_OUT" | grep -qiE 'env path is present but not a JSON object' && echo yes || echo no)"

# AC 3 (fail-closed): `env` present as JSON `null` → exit non-zero, unchanged, path named.
# This is the subtle sibling of env-as-string: the guard deliberately tests presence via the
# parent has() check (NOT `getpath != null`) precisely so a right-hand `null` is caught — jq's
# `*` treats a right-hand null as a winning value that replaces the whole defaults subtree,
# silently dropping DevFlow's env and exiting 0. A regression reverting the guard to a
# `getpath($p) != null` presence test would still reject env-as-string (that cell passes) yet
# let `{"env":null}` through — this cell is the only thing that would go red. (mutation-checked.)
PAM_ENVNULL="$(mktemp -d)"; PAM_EN_SF="$PAM_ENVNULL/settings.json"
printf '%s' '{"env":null}' > "$PAM_EN_SF"
PAM_EN_OUT="$(bash "$PAM" --apply "$PAM_EN_SF" 2>&1)"; PAM_EN_RC=$?
assert_eq "pam: --apply env-as-null → exit non-zero (no silent subtree drop, AC3)" "yes" \
  "$([ "$PAM_EN_RC" -ne 0 ] && echo yes || echo no)"
assert_eq "pam: --apply env-as-null → file unchanged" '{"env":null}' "$(cat "$PAM_EN_SF")"
assert_eq "pam: --apply env-as-null → breadcrumb specifically names the env path" "yes" \
  "$(printf '%s' "$PAM_EN_OUT" | grep -qiE 'env path is present but not a JSON object' && echo yes || echo no)"

# AC 3 (fail-closed): non-object root (array) → exit non-zero, file unchanged.
PAM_ARR="$(mktemp -d)"; PAM_A_SF="$PAM_ARR/settings.json"
printf '%s' '[1,2,3]' > "$PAM_A_SF"
PAM_A_OUT="$(bash "$PAM" --apply "$PAM_A_SF" 2>&1)"; PAM_A_RC=$?
assert_eq "pam: --apply array root → exit non-zero" "yes" \
  "$([ "$PAM_A_RC" -ne 0 ] && echo yes || echo no)"
assert_eq "pam: --apply array root → file unchanged" '[1,2,3]' "$(cat "$PAM_A_SF")"

# AC 3 (fail-closed): non-object SCALAR root (bare number/string/bool/null) → exit non-zero,
# file unchanged. The array-root sibling above only covers the `type == "array"` arm; a bare
# scalar is the other half of "root is not an object". Without this cell a regression narrowing
# the guard to object-or-array (e.g. `type == "array"` instead of `!= "object"`) would pass
# every other test yet detonate `$defaults * $existing` under `set -u` on a scalar root.
PAM_SCALAR="$(mktemp -d)"; PAM_S_SF="$PAM_SCALAR/settings.json"
printf '%s' '42' > "$PAM_S_SF"
PAM_S_OUT="$(bash "$PAM" --apply "$PAM_S_SF" 2>&1)"; PAM_S_RC=$?
assert_eq "pam: --apply scalar root → exit non-zero (fail-closed, AC3)" "yes" \
  "$([ "$PAM_S_RC" -ne 0 ] && echo yes || echo no)"
assert_eq "pam: --apply scalar root → file byte-for-byte unchanged (AC3)" '42' "$(cat "$PAM_S_SF")"

# AC 3: empty existing file is benign (treated as {}) → key added, exit 0.
PAM_EMPTY="$(mktemp -d)"; PAM_E_SF="$PAM_EMPTY/settings.json"
: > "$PAM_E_SF"
bash "$PAM" --apply "$PAM_E_SF" >/dev/null 2>&1; PAM_E_RC=$?
assert_eq "pam: --apply empty file → exit 0 (benign)" "0" "$PAM_E_RC"
assert_eq "pam: --apply empty file → key added" "1" \
  "$(jq -r '.env.CLAUDE_CODE_ENABLE_AUTO_MODE' "$PAM_E_SF" 2>/dev/null)"

# AC 1 (user scope): with no target arg, the default target is $HOME/.claude/settings.json.
# Use an isolated HOME so the real one is never touched.
PAM_HOME="$(mktemp -d)"
PAM_H_OUT="$(HOME="$PAM_HOME" bash "$PAM" --apply 2>&1)"; PAM_H_RC=$?
assert_eq "pam: --apply default target → exit 0" "0" "$PAM_H_RC"
assert_eq "pam: --apply default target → wrote \$HOME/.claude/settings.json (user scope, AC1)" "1" \
  "$(jq -r '.env.CLAUDE_CODE_ENABLE_AUTO_MODE' "$PAM_HOME/.claude/settings.json" 2>/dev/null)"

# AC 3 (shape-matrix completeness): whitespace-only existing file is benign (treated as
# {}) → key added, exit 0 — the whitespace cell the parser-editing gotcha calls out.
PAM_WS="$(mktemp -d)"; PAM_WS_SF="$PAM_WS/settings.json"
printf '   \n\t\n' > "$PAM_WS_SF"
bash "$PAM" --apply "$PAM_WS_SF" >/dev/null 2>&1; PAM_WS_RC=$?
assert_eq "pam: --apply whitespace-only file → exit 0 (treated as empty, not malformed)" "0" "$PAM_WS_RC"
assert_eq "pam: --apply whitespace-only → key added" "1" \
  "$(jq -r '.env.CLAUDE_CODE_ENABLE_AUTO_MODE' "$PAM_WS_SF" 2>/dev/null)"

# AC 2 / arg contract: a malformed invocation fails closed (exit 2) with a specific
# breadcrumb — never a silent mis-target. The two documented exit-2 arg paths:
PAM_BADOPT_OUT="$(bash "$PAM" --bogus 2>&1)"; PAM_BADOPT_RC=$?
assert_eq "pam: unknown option → exit 2" "2" "$PAM_BADOPT_RC"
assert_eq "pam: unknown option → breadcrumb names the bad option" "yes" \
  "$(printf '%s' "$PAM_BADOPT_OUT" | grep -qi 'unknown option' && echo yes || echo no)"
PAM_EXTRA_OUT="$(bash "$PAM" foo bar 2>&1)"; PAM_EXTRA_RC=$?
assert_eq "pam: extra positional → exit 2 (no silent mis-target)" "2" "$PAM_EXTRA_RC"
assert_eq "pam: extra positional → breadcrumb names the unexpected argument" "yes" \
  "$(printf '%s' "$PAM_EXTRA_OUT" | grep -qi 'unexpected extra argument' && echo yes || echo no)"

# The two exit-2 arg-contract paths are documented as --apply-INDEPENDENT, but the cells above
# exercise them only WITHOUT --apply. Assert the --apply-prefixed forms too: a regression that
# moved arg validation AFTER the consent gate would let `--apply --bogus` / `--apply foo bar`
# slip into the write path uncaught. Both must still fail closed (exit 2) before any write.
PAM_AB_OUT="$(bash "$PAM" --apply --bogus 2>&1)"; PAM_AB_RC=$?
assert_eq "pam: --apply + unknown option → exit 2 (validated regardless of --apply)" "2" "$PAM_AB_RC"
assert_eq "pam: --apply + unknown option → breadcrumb names the bad option" "yes" \
  "$(printf '%s' "$PAM_AB_OUT" | grep -qi 'unknown option' && echo yes || echo no)"
PAM_AE_OUT="$(bash "$PAM" --apply foo bar 2>&1)"; PAM_AE_RC=$?
assert_eq "pam: --apply + extra positional → exit 2 (validated regardless of --apply)" "2" "$PAM_AE_RC"
assert_eq "pam: --apply + extra positional → breadcrumb names the unexpected argument" "yes" \
  "$(printf '%s' "$PAM_AE_OUT" | grep -qi 'unexpected extra argument' && echo yes || echo no)"

# An EXPLICIT empty-string positional must fail closed, NOT silently retarget to the user-scope
# default ($HOME/.claude/settings.json) — `[ -z "$SETTINGS" ]` alone cannot tell `--apply ""`
# from `--apply`. We isolate HOME to a throwaway dir and assert (a) exit 2 with a specific
# breadcrumb AND (b) the user-scope default file was NOT created (the actual mis-target this
# guards). Mutation: drop the empty-arg guard and 'no user-scope write' goes RED (the helper
# would write to $HOME/.claude/settings.json). env -u/HOME isolation keeps the real home safe.
PAM_EMPTYARG_HOME="$(mktemp -d)"
PAM_EMPTYARG_OUT="$(HOME="$PAM_EMPTYARG_HOME" bash "$PAM" --apply "" 2>&1)"; PAM_EMPTYARG_RC=$?
assert_eq "pam: --apply with empty-string target → exit 2 (no silent mis-target)" "2" "$PAM_EMPTYARG_RC"
assert_eq "pam: --apply with empty-string target → breadcrumb names the empty target" "yes" \
  "$(printf '%s' "$PAM_EMPTYARG_OUT" | grep -qi 'empty target path' && echo yes || echo no)"
assert_eq "pam: --apply with empty-string target → did NOT write the user-scope default (mis-target guarded)" "no" \
  "$([ -f "$PAM_EMPTYARG_HOME/.claude/settings.json" ] && echo yes || echo no)"
rm -rf "$PAM_EMPTYARG_HOME"

# AC 1 (user-scope hard-fail): --apply with no target AND HOME unset cannot resolve
# ~/.claude/settings.json → exit 2 with a specific breadcrumb, writes nothing. `env -u`
# is POSIX-portable (macOS/BSD env support it), matching the no-GNU-only-flags rule.
PAM_NOHOME_OUT="$(env -u HOME bash "$PAM" --apply 2>&1)"; PAM_NOHOME_RC=$?
assert_eq "pam: --apply + HOME unset → exit 2 (cannot resolve user scope)" "2" "$PAM_NOHOME_RC"
assert_eq "pam: --apply + HOME unset → breadcrumb says HOME is unset" "yes" \
  "$(printf '%s' "$PAM_NOHOME_OUT" | grep -qi 'HOME is unset' && echo yes || echo no)"

# The NO-consent + HOME-unset branch is the display-only sibling of the cell above: with no
# --apply it must NOT hard-fail (HOME is only needed to write), but fall through to the
# display-only '~/.claude/settings.json' literal, print the copy-paste line, and exit 0. A
# regression that hard-failed without --apply, or that tilde-expanded the literal, would pass
# every other cell — only this one guards the asymmetry.
PAM_NCNOHOME_OUT="$(env -u HOME bash "$PAM" 2>&1)"; PAM_NCNOHOME_RC=$?
assert_eq "pam: no --apply + HOME unset → exit 0 (display-only, non-fatal)" "0" "$PAM_NCNOHOME_RC"
assert_eq "pam: no --apply + HOME unset → still prints the copy-paste env var" "yes" \
  "$(printf '%s' "$PAM_NCNOHOME_OUT" | grep -q 'CLAUDE_CODE_ENABLE_AUTO_MODE' && echo yes || echo no)"

# Present-but-unreadable existing settings → exit 2 with a distinct "not readable"
# breadcrumb (not misattributed to invalid JSON), file untouched. Root bypasses the perm
# bits, so assert only for an ordinary user — skip under root (same guard the pls block uses).
PAM_UNREAD="$(mktemp -d)"; PAM_UR_SF="$PAM_UNREAD/settings.json"
printf '%s' '{"env":{"FOO":"bar"}}' > "$PAM_UR_SF"
chmod 000 "$PAM_UR_SF"
if [ "$(id -u)" -ne 0 ] && [ ! -r "$PAM_UR_SF" ]; then
  PAM_UR_OUT="$(bash "$PAM" --apply "$PAM_UR_SF" 2>&1)"; PAM_UR_RC=$?
  assert_eq "pam: unreadable settings → exit 2" "2" "$PAM_UR_RC"
  assert_eq "pam: unreadable settings → breadcrumb says 'not readable' (not 'invalid JSON')" "yes" \
    "$(printf '%s' "$PAM_UR_OUT" | grep -qi 'not readable' && echo yes || echo no)"
fi
chmod 644 "$PAM_UR_SF"   # restore so rm -rf can clean up

# AC 3 (atomic + fail-closed on the WRITE side): a real change against a read-only target dir
# holding a valid existing file → mktemp in that dir fails → exit 2 with a specific breadcrumb,
# and the original is left byte-for-byte unchanged (the atomicity contract: $SETTINGS is untouched
# until the same-dir mv, so a failed write never tears it). The read side has the unreadable cell
# above; this is the only coverage of the write/mktemp failure path. Root bypasses the dir perm
# bits, so skip under root (same guard as the unreadable cell).
PAM_RODIR="$(mktemp -d)"; PAM_RO_SF="$PAM_RODIR/settings.json"
printf '%s' '{"env":{"FOO":"bar"}}' > "$PAM_RO_SF"   # valid, lacks the key → a real change is needed
PAM_RO_BEFORE="$(cat "$PAM_RO_SF")"
chmod 555 "$PAM_RODIR"   # read+exec but NOT writable → mktemp in-dir fails
if [ "$(id -u)" -ne 0 ] && [ ! -w "$PAM_RODIR" ]; then
  PAM_RO_OUT="$(bash "$PAM" --apply "$PAM_RO_SF" 2>&1)"; PAM_RO_RC=$?
  assert_eq "pam: --apply read-only target dir → exit 2 (write fail-closed, AC3)" "2" "$PAM_RO_RC"
  assert_eq "pam: --apply read-only target dir → breadcrumb names the write/temp failure" "yes" \
    "$(printf '%s' "$PAM_RO_OUT" | grep -qiE 'could not (create a temp file|write)' && echo yes || echo no)"
  assert_eq "pam: --apply read-only target dir → original byte-for-byte unchanged (atomicity, AC3)" \
    "$PAM_RO_BEFORE" "$(cat "$PAM_RO_SF")"
fi
chmod 755 "$PAM_RODIR"   # restore so rm -rf can clean up

# ── Provider gate (issue #130): --apply is a NO-OP on Anthropic-direct. ──────────────
# The env var provision-auto-mode.sh writes (CLAUDE_CODE_ENABLE_AUTO_MODE) has no effect on
# the Anthropic API — auto mode is already available there — and only does anything on the
# third-party providers (Bedrock/Vertex/Foundry). The gate is the FIRST check on the --apply
# path, BEFORE any settings read/parse/shape-validation, so on Anthropic-direct the helper
# writes nothing, leaves the file byte-for-byte unchanged, exits 0, and emits a specific
# `devflow-automode:` breadcrumb naming the provider as the skip reason. (Issue #130, AC 1/3/4/5.)
# The block-level `export CLAUDE_CODE_USE_BEDROCK=1` above is overridden per-case below: the
# Anthropic-direct cells `env -u` all three vars; the third-party cells set exactly one truthy.
PAM_NO3P=(env -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX -u CLAUDE_CODE_USE_FOUNDRY)

# AC 3 (guarantee-class): Anthropic-direct --apply over a pre-existing file → byte-for-byte
# unchanged, exit 0, provider-skip breadcrumb. This is the very path (Anthropic-direct) the
# skill is supposed to have already skipped; the script backstop must fire here regardless.
PAM_GATE_EXIST="$(mktemp -d)"; PAM_GE_SF="$PAM_GATE_EXIST/settings.json"
printf '%s' '{"env":{"FOO":"bar"}}' > "$PAM_GE_SF"
PAM_GE_BEFORE="$(cat "$PAM_GE_SF")"
PAM_GE_OUT="$("${PAM_NO3P[@]}" bash "$PAM" --apply "$PAM_GE_SF" 2>&1)"; PAM_GE_RC=$?
assert_eq "pam: gate Anthropic-direct --apply → exit 0 (skip is success, AC3)" "0" "$PAM_GE_RC"
assert_eq "pam: gate Anthropic-direct --apply → file byte-for-byte unchanged (AC3)" \
  "$PAM_GE_BEFORE" "$(cat "$PAM_GE_SF")"
assert_eq "pam: gate Anthropic-direct --apply → did NOT write the auto-mode key (AC1/AC3)" "false" \
  "$(jq -r '.env | has("CLAUDE_CODE_ENABLE_AUTO_MODE")' "$PAM_GE_SF" 2>/dev/null)"
# Breadcrumb must be the gate's own skip-reason message — not the generic 'nothing changed' no-op
# breadcrumb, which would also fire on the third-party idempotent path and so can't prove the GATE
# fired. Pin the gate-UNIQUE phrase 'nothing to provision' (the bare word 'Anthropic' is weaker —
# it could appear in a future non-gate breadcrumb; 'nothing to provision' is emitted only by the
# gate skip path). The breadcrumb does name the provider (Anthropic API) too, as AC3 requires.
assert_eq "pam: gate Anthropic-direct --apply → breadcrumb is the gate skip-reason (gate-unique phrase, AC3)" "yes" \
  "$(printf '%s' "$PAM_GE_OUT" | grep -qi 'nothing to provision' && echo yes || echo no)"
assert_eq "pam: gate Anthropic-direct --apply → breadcrumb names the provider (Anthropic) as skip reason (AC3)" "yes" \
  "$(printf '%s' "$PAM_GE_OUT" | grep -qi 'anthropic' && echo yes || echo no)"

# AC 3 (guarantee-class, missing target): Anthropic-direct --apply against a MISSING file →
# no file created, exit 0, provider-skip breadcrumb.
PAM_GATE_MISS="$(mktemp -d)"; PAM_GM_SF="$PAM_GATE_MISS/settings.json"
PAM_GM_OUT="$("${PAM_NO3P[@]}" bash "$PAM" --apply "$PAM_GM_SF" 2>&1)"; PAM_GM_RC=$?
assert_eq "pam: gate Anthropic-direct --apply missing target → exit 0 (AC3)" "0" "$PAM_GM_RC"
assert_eq "pam: gate Anthropic-direct --apply missing target → no file created (AC1/AC3)" "no" \
  "$([ -f "$PAM_GM_SF" ] && echo yes || echo no)"
assert_eq "pam: gate Anthropic-direct --apply missing target → breadcrumb is the gate skip-reason (gate-unique phrase, AC3)" "yes" \
  "$(printf '%s' "$PAM_GM_OUT" | grep -qi 'nothing to provision' && echo yes || echo no)"

# AC 5 (gate is FIRST, precedes shape-validation): Anthropic-direct --apply against a MALFORMED
# settings file → exit 0 (the gate short-circuits BEFORE the parse/shape check that would exit 2
# on the third-party path), file unchanged. This is the strongest proof the gate precedes the
# settings read: the same malformed input that exits 2 under BEDROCK=1 (the malformed cell above)
# exits 0 here purely because the provider gate ran first. Mutation: move the gate AFTER the
# settings read and this cell goes RED (exit 2 leaks through on Anthropic-direct).
PAM_GATE_BAD="$(mktemp -d)"; PAM_GB_SF="$PAM_GATE_BAD/settings.json"
printf '%s' '{ not valid json' > "$PAM_GB_SF"
PAM_GB_OUT="$("${PAM_NO3P[@]}" bash "$PAM" --apply "$PAM_GB_SF" 2>&1)"; PAM_GB_RC=$?
assert_eq "pam: gate precedes shape-validation → malformed file exits 0 on Anthropic-direct (AC5)" "0" "$PAM_GB_RC"
assert_eq "pam: gate precedes shape-validation → malformed file left unchanged (AC5)" '{ not valid json' \
  "$(cat "$PAM_GB_SF")"

# AC 4 (non-truthy → Anthropic-direct): a third-party var set to a non-truthy value is treated as
# off → the step is skipped (fresh file not created, exit 0). Covers the two degenerate values
# ("" and "0") AND an arbitrary non-"1"/non-"true" string ("yes") — is_truthy's catch-all maps
# *any* other value to off ("any other value is OFF" per the helper's own contract), so a
# regression that widened the truthy predicate (e.g. a glob, or adding yes/on) would provision a
# user-global write where it must not. Mutation: broaden is_truthy's case arm and the "yes" cell
# goes RED (it would write the key instead of skipping).
for _nt in "" "0" "yes"; do
  PAM_NT="$(mktemp -d)"; PAM_NT_SF="$PAM_NT/settings.json"
  PAM_NT_OUT="$("${PAM_NO3P[@]}" CLAUDE_CODE_USE_BEDROCK="$_nt" bash "$PAM" --apply "$PAM_NT_SF" 2>&1)"; PAM_NT_RC=$?
  assert_eq "pam: gate BEDROCK='$_nt' (non-truthy) → treated as Anthropic-direct, exit 0 (AC4)" "0" "$PAM_NT_RC"
  assert_eq "pam: gate BEDROCK='$_nt' (non-truthy) → step skipped, no file created (AC4)" "no" \
    "$([ -f "$PAM_NT_SF" ] && echo yes || echo no)"
  assert_eq "pam: gate BEDROCK='$_nt' (non-truthy) → breadcrumb is the gate skip-reason (gate-unique phrase, AC4)" "yes" \
    "$(printf '%s' "$PAM_NT_OUT" | grep -qi 'nothing to provision' && echo yes || echo no)"
  rm -rf "$PAM_NT"
done

# AC 2 + AC 4 (truthy → third-party runs): each of the three provider vars, set truthy in
# isolation, makes the step run exactly as today (fresh file → key written, exit 0). Covers
# the "1", lowercase "true", AND mixed/upper-case "TRUE" honored values (is_truthy lowercases
# via `tr`, so it accepts `true`/`TRUE` case-insensitively by design — a script-local defensive
# superset of the `1` Claude Code's docs enable these with), and proves all three vars are
# checked (not just BEDROCK). Mutation: drop the `tr` lowercasing in
# is_truthy and the "TRUE" cell goes RED (a real third-party user setting TRUE would be skipped).
for _spec in "CLAUDE_CODE_USE_BEDROCK=1" "CLAUDE_CODE_USE_VERTEX=1" "CLAUDE_CODE_USE_FOUNDRY=1" "CLAUDE_CODE_USE_VERTEX=true" "CLAUDE_CODE_USE_BEDROCK=TRUE"; do
  PAM_3P="$(mktemp -d)"; PAM_3P_SF="$PAM_3P/settings.json"
  PAM_3P_OUT="$("${PAM_NO3P[@]}" "env" "$_spec" bash "$PAM" --apply "$PAM_3P_SF" 2>&1)"; PAM_3P_RC=$?
  assert_eq "pam: gate $_spec (truthy) → third-party, exit 0 (AC2/AC4)" "0" "$PAM_3P_RC"
  assert_eq "pam: gate $_spec (truthy) → step runs, auto-mode key written (AC2/AC4)" "1" \
    "$(jq -r '.env.CLAUDE_CODE_ENABLE_AUTO_MODE' "$PAM_3P_SF" 2>/dev/null)"
  assert_eq "pam: gate $_spec (truthy) → breadcrumb says 'selectable' (today's behavior, AC2)" "yes" \
    "$(printf '%s' "$PAM_3P_OUT" | grep -qi 'selectable' && echo yes || echo no)"
  rm -rf "$PAM_3P"
done

# AC 4 ("any one of the three set truthy" → third-party): a truthy var alongside non-truthy
# siblings still routes to third-party (the step runs). Proves the OR, not an AND, over the three.
PAM_MIX="$(mktemp -d)"; PAM_MIX_SF="$PAM_MIX/settings.json"
PAM_MIX_OUT="$("${PAM_NO3P[@]}" CLAUDE_CODE_USE_BEDROCK=0 CLAUDE_CODE_USE_VERTEX="" CLAUDE_CODE_USE_FOUNDRY=1 bash "$PAM" --apply "$PAM_MIX_SF" 2>&1)"; PAM_MIX_RC=$?
assert_eq "pam: gate one-of-three truthy (FOUNDRY=1, others off) → third-party, exit 0 (AC4)" "0" "$PAM_MIX_RC"
assert_eq "pam: gate one-of-three truthy → step runs, auto-mode key written (AC4)" "1" \
  "$(jq -r '.env.CLAUDE_CODE_ENABLE_AUTO_MODE' "$PAM_MIX_SF" 2>/dev/null)"
rm -rf "$PAM_MIX"

# AC 6 / regression: the no-`--apply` consent path is gate-INDEPENDENT (the gate is on the
# --apply path only). On Anthropic-direct it still prints the copy-paste line and writes nothing.
PAM_GATE_NC="$(mktemp -d)"; PAM_GNC_SF="$PAM_GATE_NC/settings.json"
PAM_GNC_OUT="$("${PAM_NO3P[@]}" bash "$PAM" "$PAM_GNC_SF" 2>&1)"; PAM_GNC_RC=$?
assert_eq "pam: gate Anthropic-direct, no --apply → exit 0 (consent path unaffected by gate, AC6)" "0" "$PAM_GNC_RC"
assert_eq "pam: gate Anthropic-direct, no --apply → still prints the copy-paste env var (AC6)" "yes" \
  "$(printf '%s' "$PAM_GNC_OUT" | grep -q 'CLAUDE_CODE_ENABLE_AUTO_MODE' && echo yes || echo no)"
assert_eq "pam: gate Anthropic-direct, no --apply → file NOT created (AC6)" "no" \
  "$([ -f "$PAM_GNC_SF" ] && echo yes || echo no)"

unset CLAUDE_CODE_USE_BEDROCK   # don't leak the provider var into later test blocks

rm -rf "$PAM_NOCONSENT" "$PAM_NCEXIST" "$PAM_FRESH" "$PAM_ZERO" "$PAM_NONONE" "$PAM_NUM1" "$PAM_KEEP" "$PAM_IDEM" \
       "$PAM_BAD" "$PAM_ENVSTR" "$PAM_ENVNULL" "$PAM_ARR" "$PAM_SCALAR" "$PAM_EMPTY" "$PAM_HOME" \
       "$PAM_WS" "$PAM_UNREAD" "$PAM_RODIR" \
       "$PAM_GATE_EXIST" "$PAM_GATE_MISS" "$PAM_GATE_BAD" "$PAM_GATE_NC"

# ────────────────────────────────────────────────────────────────────────────
echo "feature-dev internalization (#139)"
# ────────────────────────────────────────────────────────────────────────────
# This PR vendors the two external feature-dev agents (code-explorer, code-architect)
# as first-party DevFlow agents under agents/ and rewires every call-site to the
# devflow: namespace. The assertions below are the mechanical proof the internalization
# is COMPLETE, not partial. They reuse the #129 rgb_classify rc-transform so the SAME
# fail-closed git rc-handling backs these scans too — a refactor that re-opens fail-open
# turns the #129 boundary rows red, not just these. The scan patterns are assembled from
# two string literals (like RGB_PAT) so this file never self-matches its own grep.
FDROOT="$LIB/.."

# Shared fail-closed scan seam (reuses the #129 rgb_classify rc-transform): grep the
# tracked tree for a literal pattern under a pathspec, returning the offending file list
# on a hit (git rc 0), empty on a clean no-match (rc 1 — the PASS case), or the
# <rgb-guard-errored> sentinel on a git error (rc >1). `git -C "$root"` keeps git the
# only rc-bearing command — a `cd "$root" && git grep` would short-circuit `&&` on a cd
# failure and mask a real error as a clean no-match, re-opening the fail-open hole. Both
# #139 reference scans below share this ONE seam instead of each re-implementing the
# git-grep+rc line. (The pre-existing #129 rgb_scan keeps its own one-arg wrapper;
# refactoring that already-tested helper is out of this PR's diff scope.)
tracked_scan() {  # root pattern pathspec...
  local root="$1" pat="$2"; shift 2
  local hits rc
  hits="$(git -C "$root" grep -lF "$pat" -- "$@" 2>/dev/null)"; rc=$?
  rgb_classify "$rc" "$hits"
}

# (1) Reference contract (mirrors issue AC): NO tracked surface may reference the
# namespaced feature-dev agent identifier (the plugin name + colon form). The scan
# excludes `.devflow/logs/`, which is append-only audit scratch that may record the old
# identifier in a future artifact (none do today; the exclusion is forward-looking, not
# a statement that such artifacts presently exist). After the rewire every dispatch is
# devflow:code-explorer / devflow:code-architect, so a real residual reference (a missed
# call-site) surfaces as the offending file list; an infra/git error surfaces as the
# <rgb-guard-errored> sentinel (fails loud, never a silent PASS). Pattern split into two
# literals (like RGB_PAT) so this file never self-matches its own grep.
FD_PAT="feature-""dev:"
assert_eq "#139 no tracked surface references the namespaced feature-dev agent id (.devflow/logs excepted)" \
  "" "$(tracked_scan "$FDROOT" "$FD_PAT" ':!.devflow/logs')"

# (1b) tracked_scan positive-hit test: assertion (1) only ever observes the clean
# no-match (empty) path, so tracked_scan's OWN git-grep hit path (the `-lF` + `--`
# pathspec seam) is never seen to produce a real positive. Drive it against a token that
# genuinely exists in a known file and assert it returns that file — so a regression in
# the git invocation (a dropped `--`, a mis-scoped pathspec) that silently stops matching
# turns this row red. This exercises tracked_scan's rc-0 hit path the way #129's e2e row
# pins rgb_scan's — here via an existing tracked token rather than a throwaway temp repo.
assert_eq "#139 tracked_scan returns the matching file on a real hit (pins the git-grep hit path)" \
  "lib/test/run.sh" "$(tracked_scan "$FDROOT" "rgb_classify" 'lib/test/run.sh')"

# (1c) tracked_scan fail-closed contract test: (1)/(5) only ever observe the empty (clean
# no-match) result, and (1b) only the hit path — so tracked_scan's OWN rc-capture seam
# (its fresh `hits=$(…); rc=$?` at the helper, a separate copy from the #129 rgb_scan that
# the #129 contract test at the rgb_scan block pins) is never exercised on the git-ERROR
# path. Without this row a future regression of tracked_scan's rc capture (a command
# inserted between the git call and `rc=$?`, or a revert to `cd && git grep`) would
# misclassify a real git error as a clean no-match, leaving (1)/(5) silently green on
# infra failure — the exact #62/#98 "assert fail-closed but never exercise the path"
# trap. Drive tracked_scan against a non-repo path and assert the sentinel, mirroring the
# rgb_scan fail-closed contract row. (PID-suffixed probe path cannot exist; stderr muted
# because the git error is deliberate and expected.)
assert_eq "#139 tracked_scan fails closed on a git error (returns the sentinel, not a silent PASS)" \
  "<rgb-guard-errored>" "$(tracked_scan "$FDROOT/nonexistent-fd-probe-$$" "$FD_PAT" ':!.devflow/logs' 2>/dev/null)"

# (2) Vendored-files-exist: both feature-dev agents now live first-party under agents/.
assert_eq "#139 agents/code-explorer.md exists (vendored first-party)" \
  "yes" "$([ -f "$FDROOT/agents/code-explorer.md" ] && echo yes || echo no)"
assert_eq "#139 agents/code-architect.md exists (vendored first-party)" \
  "yes" "$([ -f "$FDROOT/agents/code-architect.md" ] && echo yes || echo no)"

# (2b) Dispatch-resolves contract (the load-bearing invariant the absence-grep above only
# proxies for): for each rewired agent, the implement skill must dispatch the devflow:
# identifier AND a first-party agent of that exact `name:` must exist to resolve it. This
# closes the loop the #62/#98 unverified-assumption bug class warns about — a future typo
# in the subagent_type or a renamed agent `name:` frontmatter would pass (1) and (2) yet
# dead-end the dispatch at runtime; this assertion catches that.
for fdagent in code-explorer code-architect; do
  assert_eq "#139 implement skill dispatches devflow:$fdagent (rewired call-site present)" \
    "yes" "$(grep -qF "subagent_type: devflow:$fdagent" "$IMPL_SKILL_BUNDLE" && echo yes || echo no)"  # raw-guard-ok: loop body: literal interpolates the $fdagent loop variable, not a static pin; issue #218: bundle (the agent dispatches moved to phases/phase-2-implement.md)
  assert_eq "#139 agents/$fdagent.md frontmatter declares name: $fdagent (dispatch target resolves)" \
    "yes" "$(grep -qE "^name: $fdagent\$" "$FDROOT/agents/$fdagent.md" && echo yes || echo no)"
  # (2c) Agent-validity structural markers: `name:` resolving alone does not prove the
  # frontmatter is well-formed — a file that drops the opening `---`, its closing `---`,
  # or its model:/tools: lines still passes the name grep yet may fail to load at runtime.
  # This row asserts the structural markers the cheap-to-check mangles hit: the opening
  # frontmatter `---` (line 1), a CLOSING `---` (a second `^---$` so the block is
  # terminated, not merged into the body), plus top-level model: and tools: keys. The
  # closing-fence count is bounded to the head window (`head -30`), NOT the whole file:
  # an unbounded `grep -c '^---$'` would let a `---` markdown horizontal-rule anywhere in
  # the prompt BODY inflate the count and mask a genuinely-dropped closer (the weak-proxy
  # / #62/#98 trap — the guard would read an operand that does not prove the invariant).
  # Frontmatter + the vendor attribution comment is well under 30 lines, so the closer is
  # always in-window while a body rule below it cannot satisfy the count once the real
  # closer is gone. (It still does not validate full YAML well-formedness, but it closes
  # the common "passes the name grep, dead-ends at load" mangles within that window.)
  assert_eq "#139 agents/$fdagent.md has well-formed frontmatter (open+close ---, model:, tools:)" \
    "yes" "$(head -1 "$FDROOT/agents/$fdagent.md" | grep -qx -- '---' \
            && [ "$(head -30 "$FDROOT/agents/$fdagent.md" | grep -c '^---$')" -ge 2 ] \
            && grep -qE '^model:[[:space:]]' "$FDROOT/agents/$fdagent.md" \
            && grep -qE '^tools:[[:space:]]' "$FDROOT/agents/$fdagent.md" && echo yes || echo no)"
done

# (3) Attribution contract (mirrors issue AC): the vendored agents' upstream Anthropic
# attribution is recorded in LICENSES/feature-dev-LICENSE — the per-file `Vendored from`
# marker comments were removed (commit e398332) to avoid spending context tokens on every
# invocation, so attribution is asserted via the retained LICENSES/ file, not an in-file
# marker. The no-first-party-SPDX-header half is proved by the (3b) property loop below.
assert_eq "#139 LICENSES/feature-dev-LICENSE retains the upstream Apache-2.0 text" \
  "yes" "$([ -f "$FDROOT/LICENSES/feature-dev-LICENSE" ] \
          && grep -q 'Apache License' "$FDROOT/LICENSES/feature-dev-LICENSE" && echo yes || echo no)"

# (3b) Property-based vendoring invariant (catches a forgotten attribution): every VENDORED
# agent must NOT carry the first-party `2026 Daniel Radman` SPDX line. Since the in-file
# `Vendored from` marker was removed (e398332), the vendored set can no longer be detected by
# an in-file property — it is enumerated explicitly here (feature-dev #139 + pr-review-toolkit
# #141, which this loop also covers). The first-party agents (checklist-generator/deduper/
# verifier) are intentionally NOT in this list — they SHOULD carry the SPDX header. Each row
# fails CLOSED on a missing/renamed file via the MISSING-FILE sentinel (!= "no").
for af in code-explorer code-architect code-reviewer silent-failure-hunter comment-analyzer type-design-analyzer pr-test-analyzer; do
  assert_eq "#139 vendored agent $af.md carries no first-party 2026 Daniel Radman SPDX line" \
    "no" "$([ -f "$FDROOT/agents/$af.md" ] \
            && { grep -q 'SPDX-FileCopyrightText: 2026 Daniel Radman' "$FDROOT/agents/$af.md" && echo yes || echo no; } \
            || echo MISSING-FILE)"
done

# (4) Manifest contract (mirrors issue AC): plugin.json `dependencies` no longer lists
# feature-dev. (Formerly this also asserted superpowers was STILL declared — the seam-1/2
# scoped-removal guard. Seam 3 / #142 removed superpowers, the last companion, so that row
# is flipped to assert its removal; the full empty-deps contract is in the #142 block.)
assert_eq "#139 plugin.json dependencies no longer lists feature-dev" \
  "0" "$(jq '[.dependencies[]? | select(.name == "feature-dev")] | length' "$FDROOT/.claude-plugin/plugin.json")"
assert_eq "#142 plugin.json no longer lists superpowers (last companion removed in seam 3)" \
  "0" "$(jq '[.dependencies[]? | select(.name == "superpowers")] | length' "$FDROOT/.claude-plugin/plugin.json")"

# (5) Workflow contract: no cloud workflow installs the feature-dev companion anymore
# (the engine now dispatches the first-party devflow:code-explorer/code-architect, so the
# companion install is dead). Pattern split-literal to avoid self-match; shares the same
# tracked_scan seam as (1).
WF_FD="feature-""dev@claude-plugins-official"
assert_eq "#139 no cloud workflow installs the feature-dev companion plugin" \
  "" "$(tracked_scan "$FDROOT" "$WF_FD" '.github/workflows')"
# (The seam-3 superpowers removal is the same workflow-axis shape — see the #142 (5)
# tracked_scan aggregate below; no per-workflow loop is needed for either companion.)

# ────────────────────────────────────────────────────────────────────────────
echo "pr-review-toolkit internalization (#141)"
# ────────────────────────────────────────────────────────────────────────────
# This PR vendors the five external pr-review-toolkit review agents (code-reviewer,
# silent-failure-hunter, comment-analyzer, type-design-analyzer, pr-test-analyzer) as
# first-party DevFlow agents under agents/ and rewires every call-site to the devflow:
# namespace (seam 2 of #139). These assertions are the mechanical proof the internalization
# is COMPLETE, not partial. They reuse the same fail-closed tracked_scan seam as the #139
# block so the SAME #129 rgb_classify rc-handling backs them. PRT review agents:
PRT_AGENTS="code-reviewer silent-failure-hunter comment-analyzer type-design-analyzer pr-test-analyzer"

# (1) Reference contract (mirrors issue AC): NO tracked OPERATIVE surface may reference the
# namespaced pr-review-toolkit agent id (the plugin name + colon form). After the rewire
# every dispatch/allowlist/config/roster-doc id is devflow:<name>, so a real residual
# reference (a missed call-site) surfaces as the offending file list; an infra/git error
# surfaces as the <rgb-guard-errored> sentinel (fails loud, never a silent PASS). Pattern
# split into two literals (like FD_PAT) so this file never self-matches its own grep.
# Exclusions are append-only HISTORICAL / MIGRATION surfaces where the OLD id legitimately
# survives and rewriting it would falsify the record:
#   - .devflow/logs/                  audit scratch (per the issue AC).
#   - CHANGELOG.md                    release history (past entries describing prior config
#                                     state) PLUS the new #141 entry, which documents the
#                                     breaking rename and so necessarily names the old id.
#   - docs/review-agent-overrides.md  carries the migration table (old-key -> new-key) that
#                                     tells operators what to rename; its OPERATIVE table /
#                                     example are rewired to devflow: (asserted positively
#                                     below), only the migration section names the old id.
PRT_PAT="pr-review-""toolkit:"
assert_eq "#141 no operative surface references the namespaced pr-review-toolkit agent id (logs/CHANGELOG/migration-doc excepted)" \
  "" "$(tracked_scan "$FDROOT" "$PRT_PAT" ':!.devflow/logs' ':!CHANGELOG.md' ':!docs/review-agent-overrides.md')"

# (2/2b/2c) Per-agent vendoring + dispatch-resolves + structural validity. For each of the
# five review agents: the file exists first-party under agents/; the shared review engine
# (skills/review/SKILL.md) dispatches the devflow: id AND a first-party agent of that exact
# `name:` exists to resolve it (closing the #62/#98 dead-end-dispatch gap); the resolver
# allowlists the devflow: id; and the frontmatter is well-formed. NOTE: unlike the #139
# feature-dev agents, these carry NO `tools:` key (they inherit all tools), so 2c asserts
# model: but NOT tools:.
for a in $PRT_AGENTS; do
  assert_eq "#141 agents/$a.md exists (vendored first-party)" \
    "yes" "$([ -f "$FDROOT/agents/$a.md" ] && echo yes || echo no)"
  # Pin the LOAD-BEARING dispatch header `**devflow:<name>**` (the bold per-agent prompt
  # block — the actual dispatch site), NOT a bare `devflow:<name>` substring. The bare form
  # also appears in prose (the Phase 0.5 gate table, the Phase 3.1 gate bullets, the
  # pitfalls list) for the gated analyzers, so a bare grep would stay green even if the
  # real dispatch block were deleted while a prose mention survived — the #62/#98
  # unverified-assumption trap. The header form appears exactly once per agent (its
  # dispatch block), so this tracks the dispatch, not any mention. (Twin of the #139
  # `subagent_type: devflow:$fdagent` pin, adapted to this engine's bold-header convention.)
  assert_eq "#141 review engine dispatches devflow:$a via its **devflow:$a** prompt block (load-bearing call-site present)" \
    "yes" "$(grep -qF "**devflow:$a**" "$FDROOT/skills/review/SKILL.md" && echo yes || echo no)"  # raw-guard-ok: loop body: literal interpolates the $a loop variable, not a static pin
  # Peer-completeness (AC3 names BOTH skills): the fix-loop skill carries the same roster
  # in its phase3_dispatched / shadow-roster / reviewers_dispatched examples, and (1)'s
  # negative scan only catches a leftover OLD id — not a DROPPED devflow: id. Pin it
  # positively so a future edit that desyncs review-and-fix's example roster from the
  # engine's actual dispatch set turns this row red instead of shipping silently.
  assert_eq "#141 fix-loop skill references devflow:$a (review-and-fix roster rewired)" \
    "yes" "$(grep -qF "devflow:$a" "$FDROOT/skills/review-and-fix/SKILL.md" && echo yes || echo no)"  # raw-guard-ok: loop body: literal interpolates the $a loop variable, not a static pin
  assert_eq "#141 agents/$a.md frontmatter declares name: $a (dispatch target resolves)" \
    "yes" "$(grep -qE "^name: $a\$" "$FDROOT/agents/$a.md" && echo yes || echo no)"
  assert_eq "#141 resolver allowlists devflow:$a (override key resolves)" \
    "yes" "$(grep -qF "\"devflow:$a\"" "$FDROOT/scripts/resolve-review-overrides.py" && echo yes || echo no)"
  # Structural markers (open + close ---, model:) within the head window — bounded to
  # head -30 so a body horizontal-rule cannot inflate the closing-fence count and mask a
  # dropped closer. tools: is intentionally NOT required (these agents inherit all tools).
  assert_eq "#141 agents/$a.md has well-formed frontmatter (open+close ---, model:)" \
    "yes" "$(head -1 "$FDROOT/agents/$a.md" | grep -qx -- '---' \
            && [ "$(head -30 "$FDROOT/agents/$a.md" | grep -c '^---$')" -ge 2 ] \
            && grep -qE '^model:[[:space:]]' "$FDROOT/agents/$a.md" && echo yes || echo no)"
  # (3) Attribution contract: the vendored agents' upstream Anthropic attribution is recorded
  # in LICENSES/pr-review-toolkit-LICENSE (asserted below) — the per-file `Vendored from`
  # marker was removed in e398332. The no-first-party-SPDX half is proved by the #139 (3b)
  # property loop, which enumerates these five explicitly.
done

assert_eq "#141 LICENSES/pr-review-toolkit-LICENSE retains the upstream Apache-2.0 text" \
  "yes" "$([ -f "$FDROOT/LICENSES/pr-review-toolkit-LICENSE" ] \
          && grep -q 'Apache License' "$FDROOT/LICENSES/pr-review-toolkit-LICENSE" && echo yes || echo no)"

# (4) Manifest contract (mirrors issue AC): plugin.json `dependencies` no longer lists
# pr-review-toolkit (its agents are first-party now). superpowers staying is the #139 (4)
# scoped-removal guard above.
assert_eq "#141 plugin.json dependencies no longer lists pr-review-toolkit" \
  "0" "$(jq '[.dependencies[]? | select(.name == "pr-review-toolkit")] | length' "$FDROOT/.claude-plugin/plugin.json")"

# --- #191: Phase 3 review agents enumerate every occurrence of a flagged stale phrase ---
# The code-reviewer and comment-analyzer agents must, before submitting a stale-wording /
# semantic-contradiction (resp. repeated stale-comment) finding, exhaustively search the
# affected file and list EVERY matching line number — so the fix step corrects all sites in
# one edit instead of leaving secondary instances for a shadow round. The agent behavior
# fires at LLM-inference time (no deterministic boundary), so the automated gate is a
# mutation-proven assert_pin_unique on the operative imperative in each agent file. Each
# literal pins the operative clause (search-all + enumerate-every-line-number), not a
# framing sentence: deleting it alone re-opens the report-only-the-first-instance defect.
assert_pin_unique "#191 code-reviewer enumerates all occurrences of a flagged stale phrase before submitting" \
  'search the affected file for all occurrences of the flagged phrase, enumerate every matching line number,' "$FDROOT/agents/code-reviewer.md"
assert_pin_unique "#191 comment-analyzer enumerates all occurrences of a repeated stale comment before submitting" \
  'search the affected file for every occurrence of the flagged comment wording, enumerate every matching line number,' "$FDROOT/agents/comment-analyzer.md"
# Pin the secondary semantic-equivalents refinement too — it is a distinct behavioral
# clause from the search-all+enumerate imperative above (a trim to verbatim-only matching
# would leave the pins above GREEN), so it needs its own gate to fail closed on removal.
assert_pin_unique "#191 code-reviewer requires semantic-equivalent matches, not just verbatim" \
  'semantic equivalents of the phrase you can identify from context, not just verbatim matches' "$FDROOT/agents/code-reviewer.md"
assert_pin_unique "#191 comment-analyzer requires semantic-equivalent matches, not just verbatim" \
  'semantic equivalents of the wording you can identify from context, not just verbatim matches' "$FDROOT/agents/comment-analyzer.md"
# Pin the operative DELIVERABLE clause separately (PR #205 review note): a trim that kept the
# search-all + semantic-equivalents pins above but dropped "include the complete location set in
# the finding body" would leave those GREEN while removing the very output #191 exists to produce
# (the full site list the fix step consumes). Per the operative-vs-framing rule it earns its own gate.
assert_pin_unique "#191 code-reviewer includes the complete location set in the finding body before submitting" \
  'include the complete location set in the finding body before submitting' "$FDROOT/agents/code-reviewer.md"
assert_pin_unique "#191 comment-analyzer includes the complete location set in the finding body before submitting" \
  'include the complete location set in the finding body before submitting' "$FDROOT/agents/comment-analyzer.md"

# (5) Workflow contract: no cloud workflow installs the pr-review-toolkit companion anymore
# (the engine dispatches the first-party devflow: review agents). Pattern split-literal to
# avoid self-match; shares the tracked_scan seam as (1).
WF_PRT="pr-review-""toolkit@claude-plugins-official"
assert_eq "#141 no cloud workflow installs the pr-review-toolkit companion plugin" \
  "" "$(tracked_scan "$FDROOT" "$WF_PRT" '.github/workflows')"

# (6) Positive roster-doc rewire (AC8 names three docs that must describe the internalized
# roster). The absence scan (1) catches a leftover OLD id but not a doc that DROPPED the
# roster mention entirely, so pin each AC8 doc positively. review-agent-overrides.md needs
# this most — it is EXCLUDED from (1) (it carries the old-id migration table), so its
# operative override example would otherwise be unguarded; the other two are inside (1)'s
# scan but a dropped-mention regression is still invisible to a negative scan.
assert_eq "#141 docs/review-agent-overrides.md operative example uses the internalized devflow: key" \
  "yes" "$(grep -qF '"devflow:code-reviewer": { "model"' "$FDROOT/docs/review-agent-overrides.md" && echo yes || echo no)"
for d in DEVFLOW_SYSTEM_OVERVIEW.md shadow-review.md; do
  assert_eq "#141 docs/$d describes the internalized first-party review roster (devflow:code-reviewer present)" \
    "yes" "$(grep -qF 'devflow:code-reviewer' "$FDROOT/docs/$d" && echo yes || echo no)"
done

# ────────────────────────────────────────────────────────────────────────────
echo "superpowers internalization (#142)"
# ────────────────────────────────────────────────────────────────────────────
# Seam 3 (final) of #139: vendors the TWO runtime-dispatched superpowers SKILLS —
# requesting-code-review (the review engine's general-purpose final-pass reviewer) and
# receiving-code-review (the fix-loop principles) — as first-party DevFlow skills under
# skills/, rewires their call-sites + the final-pass override key to the devflow: namespace,
# retires the optional using-git-worktrees reference, and removes the LAST companion
# dependency so DevFlow ships ZERO companion-plugin install dependencies. writing-skills is
# DELIBERATELY NOT vendored: it is a development-time SKILL.md-authoring discipline DevFlow's
# own contributors invoke, never something the engine dispatches at runtime, so it stays the
# EXTERNAL superpowers:writing-skills skill (referenced only in CLAUDE.md's conventions) — the
# (1c) un-fork assertions below pin that. Unlike #139/#141 (which vendored AGENTS under
# agents/), this seam vendors SKILLS under skills/, and the upstream is MIT-licensed (Jesse
# Vincent), NOT Apache-2.0/Anthropic. These assertions are the mechanical proof the
# internalization is COMPLETE; they reuse the same fail-closed tracked_scan seam (the #129
# rgb_classify rc-handling backs them).
SP_SKILLS="requesting-code-review receiving-code-review"

# (1) Reference contract (AC4): NO operative surface may reference the old namespaced
# identifier for the two internalized skills (the plugin-name + colon form). Excepted:
# .devflow/logs (append-only audit scratch), CHANGELOG.md (historical entries + the #142
# breaking-rename entry, which necessarily names the old override key), and (for the final-
# pass key only) docs/review-agent-overrides.md (carries the old->new migration table) —
# mirrors the #141 migration-doc exception. Patterns are split-literal so this run.sh never
# self-matches its own grep, and the descriptions avoid the contiguous colon form for the
# same reason (a description literal would itself be a tracked hit). writing-skills is NOT
# here: it stays external, so superpowers:writing-skills is EXPECTED on CLAUDE.md (pinned
# positively in (1c)), not forbidden.
SP_PAT_REQ="superpowers:""requesting-code-review"
SP_PAT_REC="superpowers:""receiving-code-review"
assert_eq "#142 no operative surface references the old namespaced requesting-code-review id (logs/CHANGELOG/migration-doc excepted)" \
  "" "$(tracked_scan "$FDROOT" "$SP_PAT_REQ" ':!.devflow/logs' ':!CHANGELOG.md' ':!docs/review-agent-overrides.md')"
assert_eq "#142 no operative surface references the old namespaced receiving-code-review id (logs/CHANGELOG excepted)" \
  "" "$(tracked_scan "$FDROOT" "$SP_PAT_REC" ':!.devflow/logs' ':!CHANGELOG.md')"

# (1c) writing-skills un-fork contract: writing-skills is a development-time discipline, NOT a
# DevFlow runtime skill, so it must NOT be vendored first-party — the skills/writing-skills/
# tree is absent — and CLAUDE.md's "invoke writing-skills before editing a SKILL.md" convention
# must reference the EXTERNAL superpowers:writing-skills id (a dev-time tool, not a consumer/
# runtime plugin dependency, so the zero-companion-dependency claim is unaffected). Pin both
# directions so a future re-fork — re-adding skills/writing-skills/ or flipping the CLAUDE.md
# reference back to devflow:writing-skills — fails loud here. Split-literal so this run.sh
# never self-matches its own grep.
SP_PAT_WRI_DEV="superpowers:""writing-skills"
assert_eq "#142 writing-skills is NOT vendored first-party (skills/writing-skills/ absent — dev-time tool, not a runtime skill)" \
  "no" "$([ -d "$FDROOT/skills/writing-skills" ] && echo yes || echo no)"
assert_eq "#142 CLAUDE.md references the EXTERNAL superpowers:writing-skills authoring convention (not a vendored devflow: id)" \
  "yes" "$(grep -qF "$SP_PAT_WRI_DEV" "$FDROOT/CLAUDE.md" && echo yes || echo no)"
assert_eq "#142 CLAUDE.md does NOT claim a vendored first-party devflow:writing-skills skill" \
  "no" "$(grep -qF 'devflow:writing-skills' "$FDROOT/CLAUDE.md" && echo yes || echo no)"

# (1d) Broadened residual contract: beyond the two internalized ids, NO operative surface
# may carry ANY bare `superpowers:` namespaced identifier. (1)'s two split-literal scans
# only catch the internalized ids; this fails closed on a stray reference to a *non*-
# internalized superpowers skill too. CLAUDE.md is excepted because it intentionally carries
# the one legitimate external reference — superpowers:writing-skills, the dev-time authoring
# discipline pinned in (1c); the internalized requesting/receiving ids are still covered on
# CLAUDE.md by (1)'s repo-wide scans, and using-git-worktrees by (6), so excepting CLAUDE.md
# here only narrows this net to "no OTHER stray superpowers: ref outside CLAUDE.md." Same
# history/migration exceptions as (1), PLUS lib/test — this suite's own scaffolding
# necessarily names the forbidden pattern to assert its absence, and a guard cannot scan
# itself. Excepting all of lib/test leaves a narrow blind spot: a stray *non-internalized*
# superpowers: id introduced into a non-scaffolding test helper would slip THIS broad scan.
# That residual is mitigated because (1)'s targeted requesting/receiving scans are NOT path-
# scoped (they would still catch the two internalized ids anywhere in lib/test); only a brand-
# new reference to some OTHER superpowers skill, placed in lib/test, would evade detection.
# Pattern split-literal so this run.sh never self-matches outside lib/test.
SP_PAT_NS="superpowers"":"
assert_eq "#142 no operative surface outside CLAUDE.md carries any bare superpowers: namespaced id (non-internalized refs incl.; CLAUDE.md/test scaffolding/history/migration excepted)" \
  "" "$(tracked_scan "$FDROOT" "$SP_PAT_NS" ':!.devflow/logs' ':!CHANGELOG.md' ':!docs/review-agent-overrides.md' ':!lib/test' ':!CLAUDE.md')"

# (2/2b/2c) Per-skill vendoring + structural validity. For each of the two skills the file
# exists first-party under skills/<name>/SKILL.md; its frontmatter declares name: <name> (so
# it resolves as devflow:<name>); and the frontmatter is well-formed (open + close ---, name:,
# bounded to the head window so a body --- horizontal rule cannot inflate the closing-fence
# count and mask a dropped closer). These are SKILLS, so no model:/tools: key is required.
for sk in $SP_SKILLS; do
  assert_eq "#142 skills/$sk/SKILL.md exists (vendored first-party)" \
    "yes" "$([ -f "$FDROOT/skills/$sk/SKILL.md" ] && echo yes || echo no)"
  assert_eq "#142 skills/$sk/SKILL.md frontmatter declares name: $sk (resolves as devflow:$sk)" \
    "yes" "$(grep -qE "^name: $sk\$" "$FDROOT/skills/$sk/SKILL.md" && echo yes || echo no)"  # raw-guard-ok: loop body: SKILL target/literal interpolate the $sk loop variable, not a static pin
  assert_eq "#142 skills/$sk/SKILL.md has well-formed frontmatter (open+close ---, name:)" \
    "yes" "$(head -1 "$FDROOT/skills/$sk/SKILL.md" | grep -qx -- '---' \
            && [ "$(head -30 "$FDROOT/skills/$sk/SKILL.md" | grep -c '^---$')" -ge 2 ] \
            && grep -qE '^name:[[:space:]]' "$FDROOT/skills/$sk/SKILL.md" && echo yes || echo no)"  # raw-guard-ok: loop body: SKILL target interpolates the $sk loop variable, not a static pin
  # (3) Attribution contract (mirrors AC2): the vendored skills' upstream superpowers
  # attribution lives in LICENSES/superpowers-LICENSE (MIT (c) Jesse Vincent — NOT Anthropic/
  # Apache-2.0 like #139/#141), asserted once below — the per-file `Vendored from` marker was
  # removed in e398332. The no-first-party-SPDX half is proved by the (3b) property loop.
  # (2e) scaffold-config.sh registers a prompt-extension example row for this internalized
  # skill, and that row names a skill that actually exists (the skills/$sk/SKILL.md asserted
  # above) — pins the PE row to a real skill dir so a typo'd/renamed scaffold row fails loud
  # instead of scaffolding a <skill>.md.example that resolves to nothing.
  assert_eq "#142 scaffold-config.sh has a PE_SKILLS row for the internalized $sk skill" \
    "yes" "$(grep -qE "^$sk\|" "$FDROOT/scripts/scaffold-config.sh" && echo yes || echo no)"
done

# (2d) Dispatch-resolves call-sites (the load-bearing invariant the absence-grep only proxies
# for): each internalized skill's devflow: identifier must appear at its actual call-site, and
# the resolving skill file (asserted above) exists. Pinned positively so a DROPPED devflow: id
# — invisible to (1)'s negative scan — turns these rows red (the #62/#98 unverified-assumption
# trap). requesting-code-review: the engine invokes it + resolver/schema allowlist its override
# key; receiving-code-review: the fix-loop applies its principles. (writing-skills has no call-
# site here — it is external; its CLAUDE.md reference is pinned in (1c).)
assert_eq "#142 review engine dispatches /devflow:requesting-code-review (final-pass call-site rewired)" \
  "yes" "$(grep -qF '/devflow:requesting-code-review' "$FDROOT/skills/review/SKILL.md" && echo yes || echo no)"  # raw-guard-ok: non-unique: '/devflow:requesting-code-review' appears twice in the target SKILL
assert_eq "#142 resolver allowlists devflow:requesting-code-review (override key resolves)" \
  "yes" "$(grep -qF '"devflow:requesting-code-review"' "$FDROOT/scripts/resolve-review-overrides.py" && echo yes || echo no)"
assert_eq "#142 config schema declares the devflow:requesting-code-review override key" \
  "yes" "$(grep -qF '"devflow:requesting-code-review"' "$FDROOT/.devflow/config.schema.json" && echo yes || echo no)"
assert_eq "#142 fix-loop skill applies devflow:receiving-code-review principles (call-site rewired)" \
  "yes" "$(grep -qF 'devflow:receiving-code-review' "$FDROOT/skills/review-and-fix/SKILL.md" && echo yes || echo no)"  # raw-guard-ok: non-unique: 'devflow:receiving-code-review' appears twice in the target SKILL

# (3b) Property-based vendoring invariant (the skills-tree twin of the #139 agents/*.md loop):
# EVERY file under the two vendored skill dirs must NOT carry the first-party `2026 Daniel Radman`
# SPDX header (the license-preservation half) — proved mechanically over EVERY vendored file incl.
# the requesting-code-review/code-reviewer.md companion, not just SKILL.md. The per-file
# `Vendored from the superpowers plugin` attribution marker was removed (e398332) to save context
# tokens, so attribution is now proved once via LICENSES/superpowers-LICENSE (asserted below), not
# per-file here. NOTE: the per-file loop alone is NOT fail-closed — over an empty find result it
# contributes zero assertions and silently passes; the SP_VENDORED_FILES non-empty assertion
# directly below is what closes that hole, so the two must stay paired. The vendored skill paths
# are alphanumeric/hyphen (no spaces), so the unquoted find word-split is safe.
SP_VENDORED_FILES=$(find "$FDROOT/skills/requesting-code-review" "$FDROOT/skills/receiving-code-review" -type f 2>/dev/null)
# Fail CLOSED on an empty iteration set: if the two vendored trees were deleted/renamed
# wholesale, `find` returns nothing and the loop below would contribute ZERO assertions — a
# silent pass on the exact botched-re-vendor regression this block exists to catch (the
# loop's contract is "every file here MUST be vendored," so an empty set is a false clean,
# not a legitimate no-op like the #139 conditional agents glob). Guard with a non-empty
# assertion before iterating.
assert_eq "#142 vendored skill trees are non-empty (guards the empty-find silent-pass)" \
  "yes" "$([ -n "$SP_VENDORED_FILES" ] && echo yes || echo no)"
# The reviewer-prompt template the requesting-code-review skill renders (review/SKILL.md
# dispatches /devflow:requesting-code-review, which renders this template — it is not inlined) is
# load-bearing — pin its existence explicitly (the 2/2b/2c loop pins each SKILL.md, but a
# supporting-file deletion would otherwise be invisible to the loop, which only iterates
# files that exist).
assert_eq "#142 skills/requesting-code-review/code-reviewer.md exists (the rendered reviewer template)" \
  "yes" "$([ -f "$FDROOT/skills/requesting-code-review/code-reviewer.md" ] && echo yes || echo no)"
# ...AND the SKILL.md still LINKS that template. Existence alone is insufficient: a future edit
# that drops/renames the `[code-reviewer.md](code-reviewer.md)` link would ORPHAN the template —
# the final-pass reviewer renders an empty prompt — while the existence pin above and every other
# #142 row stay green (the dropped-mention asymmetry the 2d/7/8 pins defend elsewhere, and the
# #62/#98 unverified-assumption class). Pin the link positively. Fails CLOSED via the MISSING-FILE
# sentinel if the SKILL.md is renamed/deleted (!= "yes").
assert_eq "#142 skills/requesting-code-review/SKILL.md links its code-reviewer.md template (not orphaned)" \
  "yes" "$([ -f "$FDROOT/skills/requesting-code-review/SKILL.md" ] \
          && grep_present '(code-reviewer.md)' "$FDROOT/skills/requesting-code-review/SKILL.md" \
          || echo MISSING-FILE)"
for sf in $SP_VENDORED_FILES; do
  assert_eq "#142 vendored skill file ${sf#"$FDROOT"/} carries no first-party 2026 Daniel Radman SPDX line" \
    "no" "$(grep -q 'SPDX-FileCopyrightText: 2026 Daniel Radman' "$sf" && echo yes || echo no)"
done
assert_eq "#142 LICENSES/superpowers-LICENSE retains the upstream MIT license text + copyright" \
  "yes" "$([ -f "$FDROOT/LICENSES/superpowers-LICENSE" ] \
          && grep -q 'MIT License' "$FDROOT/LICENSES/superpowers-LICENSE" \
          && grep -q 'Jesse Vincent' "$FDROOT/LICENSES/superpowers-LICENSE" && echo yes || echo no)"

# (4) Manifest contract (mirrors AC5): with the last companion removed, plugin.json
# `dependencies` is now EMPTY and marketplace.json's cross-marketplace allowlist is emptied —
# DevFlow has ZERO companion-plugin install dependencies. (The per-name superpowers-absence
# row in plugin.json lives in the flipped #139 (4) guard above; the workflow axis is (5) below.)
assert_eq "#142 plugin.json dependencies is now empty (zero companion-plugin dependencies)" \
  "0" "$(jq '.dependencies | length' "$FDROOT/.claude-plugin/plugin.json")"
assert_eq "#142 marketplace.json allowCrossMarketplaceDependenciesOn is now empty" \
  "0" "$(jq '.allowCrossMarketplaceDependenciesOn | length' "$FDROOT/.claude-plugin/marketplace.json")"

# (5) Workflow contract: no cloud workflow installs the superpowers companion anymore — the
# same tracked_scan-aggregate shape as the #139 (5) feature-dev guard, and it fails loud on a
# git error via the rgb sentinel (returns the offending workflow file on a real hit).
WF_SP="superpowers""@claude-plugins-official"
assert_eq "#142 no cloud workflow installs the superpowers companion plugin" \
  "" "$(tracked_scan "$FDROOT" "$WF_SP" '.github/workflows')"

# (6) using-git-worktrees retirement (AC6): the using-git-worktrees reference is gone (the
# loop uses raw git worktree). using-git-worktrees is NOT internalized. Scoped REPO-WIDE via
# the fail-closed tracked_scan (not a single-file grep): a single-file `grep ... || echo no`
# asserting "no" would pass falsely if the target file were renamed/deleted (the grep miss
# yields the expected "no"), and would miss a reference that migrated to another file. The
# tracked_scan returns the offending path on a real hit and the rgb sentinel on a git error.
# Pattern split-literal to avoid self-match.
SP_PAT_WT="superpowers:""using-git-worktrees"
assert_eq "#142 no operative surface references the retired using-git-worktrees skill (repo-wide; raw git worktree used instead)" \
  "" "$(tracked_scan "$FDROOT" "$SP_PAT_WT" ':!.devflow/logs' ':!CHANGELOG.md')"

# (6b) Removed-behavior pin (negative-removal, twin of (6)): the final-pass reviewer is now a
# first-party skill that is ALWAYS present wherever DevFlow runs, so the old companion-unavailable
# graceful-degradation framing ("this dispatch assumes the superpowers plugin is installed... fall
# back to the other reviewers if unavailable") was removed from skills/review/SKILL.md — its
# survival is load-bearing for the shadow's always-on-roster invariant (a three-of-four roster is
# never full coverage). A future edit that reintroduces a companion-install assumption would pass
# every other #142 row while silently regressing that invariant, so pin its absence on the
# target-unique phrase. (The phrase appears nowhere else in the file, so this is not vacuous.)
# Existence-guarded so this fails CLOSED: a bare `grep ... || echo no` asserting "no" would
# pass falsely if skills/review/SKILL.md were renamed/deleted (the grep miss yields "no").
# A missing file returns the distinct MISSING-FILE sentinel, which is != "no" and fails loud.
assert_eq "#142 review engine no longer assumes the final-pass reviewer is an installed companion plugin" \
  "no" "$([ -f "$FDROOT/skills/review/SKILL.md" ] \
          && grep_present 'plugin is installed in the executing environment' "$FDROOT/skills/review/SKILL.md" \
          || echo MISSING-FILE)"

# (7) Positive roster-doc rewire (AC8): the docs that describe the final-pass reviewer must
# name the internalized devflow:requesting-code-review id — a negative scan (1) catches a
# leftover OLD id but not a doc that DROPPED the mention. review-agent-overrides.md (excluded
# from (1) for its migration table) needs this most.
assert_eq "#142 docs/review-agent-overrides.md operative table uses the internalized devflow:requesting-code-review key" \
  "yes" "$(grep -qF 'devflow:requesting-code-review' "$FDROOT/docs/review-agent-overrides.md" && echo yes || echo no)"
for d in DEVFLOW_SYSTEM_OVERVIEW.md shadow-review.md; do
  assert_eq "#142 docs/$d references the internalized devflow:requesting-code-review final-pass reviewer" \
    "yes" "$(grep -qF 'devflow:requesting-code-review' "$FDROOT/docs/$d" && echo yes || echo no)"
done

# (8) Positive pin for the implement skill's Phase-3 review-roster line (PR #143 review,
# Minor #2). The implement skill (phases/phase-3-review.md) names the five first-party
# review agents by BARE name (no namespace) in its Phase-3 prose. The absence scan (1) only catches a leftover
# OLD id, not a DROPPED bare name, so the same dropped-mention asymmetry already defended
# for skills/review (the **devflow:<name>** header pin) and skills/review-and-fix (the
# devflow:<name> roster pin) applies here too. Pin the whole parenthesized roster so a
# future edit that drops an agent turns this row red instead of shipping silently.
assert_pin_unique "#141 implement skill names all five review agents in its Phase-3 roster line" '(code-reviewer, silent-failure-hunter, comment-analyzer, type-design-analyzer, pr-test-analyzer)' "$IMPL_SKILL_BUNDLE"  # issue #218: bundle (roster moved to phases/phase-3-review.md)

# (issue #183 / PR #187) CHANGELOG reconciliation step contract pins. Guards four
# load-bearing clauses in docs-release-notes SKILL.md: (a) the all-PRs routing
# contract, (b) the no-op condition, (c) the no-commit clause, and (d) the config-key
# resolution line. Removing or rewording any of these pinned clauses turns the suite RED
# (a presence pin catches deletion/reword, not a purely additive edit that leaves the clause).
assert_pin_unique "#183 docs-release-notes SKILL Step 4b runs regardless of customer-visibility decision" \
  'This step runs regardless of the Step 2 customer-visibility decision' "$FDROOT/skills/docs-release-notes/SKILL.md"
assert_pin_unique "#183 docs-release-notes SKILL contains CHANGELOG reconciliation step with no-op condition" \
  'section heading matching the manifest version, this step is a no-op' "$FDROOT/skills/docs-release-notes/SKILL.md"
assert_pin_unique "#183 docs-release-notes SKILL Step 4b does not commit" \
  'Do not commit — leave committing to the caller, consistent with Step 5' "$FDROOT/skills/docs-release-notes/SKILL.md"
assert_pin_unique "#183 docs-release-notes SKILL resolves changelog_file via config-get.sh" \
  'config-get.sh .docs.changelog_file CHANGELOG.md' "$FDROOT/skills/docs-release-notes/SKILL.md"

# (PR #187 review hardening) Couple the `chore: bump version` commit-message prefix across
# its producer and its consumer so the convention cannot drift on one side only. The
# consumer (docs-release-notes Step 4b) uses this exact prefix ONLY to confirm a version bump
# happened on the branch — it then selects the CHANGELOG section by the `## [version]` heading
# whose version is read from the manifest, never from the commit subject; the producer
# (implement prompt-extension) mandates emitting it. If either renames the prefix without the
# other, Step 4b sees no bump and silently no-ops the reconciliation it exists to perform (the
# fail-open the PR #187 review flagged). Pin the literal in both files.
assert_pin_unique "#187 docs-release-notes Step 4b matches the chore: bump version prefix" \
  'message begins with `chore: bump version`' "$FDROOT/skills/docs-release-notes/SKILL.md"
assert_pin_unique "#187 implement prompt-extension mandates the chore: bump version prefix" \
  'begins with the literal `chore: bump version`' "$FDROOT/.devflow/prompt-extensions/implement.md"

# (PR #187 review round 2 — Critical + Important hardening) Step 4b's version-selection and
# section-locator contract. The Critical the review caught: deriving the version from the bump
# commit's free-text *subject* reconciles the wrong (already-shipped) section when a later
# re-version leaves that subject stale — a silent fail-*wrong*. The version MUST come from the
# authoritative manifest, with the bump commit used only to confirm a bump happened. Pin (a) the
# manifest-sourced version read, (b) the two-dot scan range (this exact line has regressed before
# — the two-dot vs three-dot distinction is load-bearing), and (c) the bracketed `## [version]` heading the consumer
# searches, coupled to the implement extension's `## [x.y.z]` producer so a heading-convention
# drift cannot silently no-op reconciliation on one side only.
assert_pin_unique "#187 docs-release-notes Step 4b reads the shipped version from the plugin.json manifest (not the commit subject)" \
  'run-jq.sh -r .version .claude-plugin/plugin.json' "$FDROOT/skills/docs-release-notes/SKILL.md"
assert_pin_unique "#187 docs-release-notes Step 4b scans the origin/main..HEAD two-dot commit range" \
  'git log --oneline origin/main..HEAD' "$FDROOT/skills/docs-release-notes/SKILL.md"
assert_pin_unique "#187 docs-release-notes Step 4b searches the bracketed Keep-a-Changelog heading (consumer side)" \
  'bracketed Keep-a-Changelog heading `## [<version>]`' "$FDROOT/skills/docs-release-notes/SKILL.md"
assert_pin_unique "#187 implement prompt-extension mandates the bracketed ## [x.y.z] CHANGELOG heading (producer side)" \
  '`## [x.y.z]` entry to `CHANGELOG.md`' "$FDROOT/.devflow/prompt-extensions/implement.md"

# (PR #187 review round 3 — corroborated test_gap + silent-failure hardening) The round-2
# pins above prove the version-from-manifest *mechanism* exists (the `jq` read, the scan, the
# bump-commit confirm) but not that the manifest is the version's *sole authority* — a future
# edit could re-add subject-reading alongside the manifest read and every round-2 pin stays
# GREEN (the additive-regression two review agents corroborated). Pin the **negative invariant**
# (the discriminating clause that carries the fix) so a revert that *drops or softens* the
# explicit prohibition trips RED — a presence pin cannot catch a purely additive re-add that
# leaves the clause intact, but that would leave a self-contradicting skill body for review to
# catch. Also pin the all-PRs reachability contract on BOTH the Objective restatement AND the
# operative Step-2 decision body: the Objective clause (`CHANGELOG reconciliation still runs for
# all PRs`) states the intent, but the site the agent actually obeys mid-Step-2 is the line that
# flips the non-customer-visible exit to "skip Steps 3/3b/4, proceed to Step 4b" (pre-PR it read
# "stop here. Do not modify any files."). Pinning ONLY the Objective restatement would let a
# single-site revert of that operative decision strip the only path to Step 4b on the
# non-customer-visible branch while the suite stayed GREEN (the framing-pinned-not-behavior
# fail-open a review pass flagged). Pin both. Plus the **fail-loud breadcrumb** that keeps a
# failed determination from masquerading as a clean no-op.
assert_pin_unique "#187 docs-release-notes Step 4b pins the negative invariant (version NOT read from the commit subject)" \
  'do not read the version string from its free-text subject' "$FDROOT/skills/docs-release-notes/SKILL.md"
assert_pin_unique "#187 docs-release-notes Objective restates the all-PRs reconciliation contract" \
  'CHANGELOG reconciliation still runs for all PRs' "$FDROOT/skills/docs-release-notes/SKILL.md"
assert_pin_unique "#187 docs-release-notes Step 2 operative decision routes non-customer-visible to Step 4b (not 'stop')" \
  'If the PR is **not customer-visible**, skip Steps 3, 3b, and 4' "$FDROOT/skills/docs-release-notes/SKILL.md"
assert_pin_unique "#187 docs-release-notes Step 4b fails loud on a failed determination (not a masked no-op)" \
  'CHANGELOG reconciliation NOT performed' "$FDROOT/skills/docs-release-notes/SKILL.md"

# (PR #187 review round 4 — pin the reconciliation PAYLOAD, not only its guards) The pins
# above guard Step 4b's control-flow guards (routing, version source, no-op, fail-loud) but
# left the operative *action* unpinned — a half-revert could hollow out the enumerate→trace→
# correct payload and the suite would stay GREEN (the recurring framing-pinned-not-behavior
# class). Pin (a) the trace-against-the-Step-1-diff clause — load-bearing because the Step-1
# diff is the operand Step 4b's trace consumes, and Step 1 runs before the Step 2 branch so the
# operand is reachable on every path — and (b) the correct-in-place mutation clause. Also pin
# the no-bump-commit no-op branch for parity with the no-section branch already pinned above.
assert_pin_unique "#187 docs-release-notes Step 4b traces each claim against the Step-1 diff (operative payload)" \
  'confirm it against the diff already read in Step 1. Do not re-run' "$FDROOT/skills/docs-release-notes/SKILL.md"
assert_pin_unique "#187 docs-release-notes Step 4b enumerates every factual claim (operative payload, parity with trace/correct)" \
  'Enumerate every factual claim' "$FDROOT/skills/docs-release-notes/SKILL.md"
assert_pin_unique "#187 docs-release-notes Step 4b corrects stale claims in place (operative payload)" \
  'Rewrite only the specific sentence or clause that is stale' "$FDROOT/skills/docs-release-notes/SKILL.md"
assert_pin_unique "#187 docs-release-notes Step 4b no-bump-commit no-op branch (parity with the no-section branch)" \
  'no version-bump commit found on branch' "$FDROOT/skills/docs-release-notes/SKILL.md"

# ────────────────────────────────────────────────────────────────────────────
echo "#181 review-engine Phase 0.2 .devflow/logs/** diff-hunk filter"
# ────────────────────────────────────────────────────────────────────────────
# Phase 0.2 of skills/review/SKILL.md strips .devflow/logs/** hunks from the
# cached diff.patch (intentional DevFlow telemetry commits, not code-review
# subjects) BEFORE any Phase 1/2/3 agent sees the diff. The filter is an inline
# awk stage in the existing `… | tee diff.patch` pipeline (it rides the
# allowlisted `gh pr diff`/`git diff` leading token, so the read-only `review`
# profile permits it without a workflow allowlist change — no standalone `mv`).
#
# These assertions EXTRACT the actual awk program from the SKILL and run it
# against synthetic-diff fixtures, so they go RED if the SKILL's filter is
# missing or wrong (not a vacuous re-implementation). The contract pin below
# couples the SKILL text to that behavior.
F181_AWK="$(grep -oE "awk '[^']+'" "$REVIEW_SKILL" 2>/dev/null | grep -F 'in_logs' | head -1 | sed "s/^awk '//; s/'$//")"
# Precondition (RED until the filter is added): the awk program must be
# extractable from the SKILL. Guards every behavioral assertion below against an
# empty-program (`awk ''`) vacuous pass.
assert_eq "#181 filter: awk log-hunk filter program is present/extractable in review/SKILL.md Phase 0.2" \
  "yes" "$([ -n "$F181_AWK" ] && echo yes || echo no)"

# Fixture: a real code hunk, a telemetry-log hunk, then another code hunk.
F181_MIXED="$(printf '%s\n' \
  'diff --git a/src/a.py b/src/a.py' \
  'index 1111111..2222222 100644' \
  '--- a/src/a.py' \
  '+++ b/src/a.py' \
  '@@ -1 +1 @@' \
  '-old a' \
  '+new a' \
  'diff --git a/.devflow/logs/efficiency/pr-1.json b/.devflow/logs/efficiency/pr-1.json' \
  'index 3333333..4444444 100644' \
  '--- a/.devflow/logs/efficiency/pr-1.json' \
  '+++ b/.devflow/logs/efficiency/pr-1.json' \
  '@@ -1 +1 @@' \
  '-{"old":1}' \
  '+{"new":1}' \
  'diff --git a/src/b.py b/src/b.py' \
  'index 5555555..6666666 100644' \
  '--- a/src/b.py' \
  '+++ b/src/b.py' \
  '@@ -1 +1 @@' \
  '-old b' \
  '+new b')"
F181_MIXED_OUT="$(printf '%s\n' "$F181_MIXED" | awk "${F181_AWK:-NONEXTRACTED}" 2>/dev/null)"
# AC-2: the telemetry hunk is gone…
assert_eq "#181 filter: mixed diff drops the .devflow/logs/ hunk" \
  "absent" "$(case "$F181_MIXED_OUT" in *'.devflow/logs/'*) echo present;; *) echo absent;; esac)"
# …and BOTH real code hunks survive, in their original order (a before b).
assert_eq "#181 filter: mixed diff retains both real code hunks in original order" \
  "diff --git a/src/a.py b/src/a.py|diff --git a/src/b.py b/src/b.py" \
  "$(printf '%s\n' "$F181_MIXED_OUT" | grep '^diff --git' | paste -sd'|' -)"

# Fixture: a single logs file carrying TWO @@ hunks (the realistic accreting-telemetry shape),
# followed by a real code hunk (#209 review hardening). The filter's stickiness rides the
# `diff --git` header, NOT the @@ line, so EVERY hunk of a logs file is suppressed. A regression
# that reset in_logs per @@ (instead of per diff --git header) would leak the SECOND hunk's
# content while still passing every single-hunk fixture above — this fixture is the regression catch.
F181_MULTIHUNK="$(printf '%s\n' \
  'diff --git a/.devflow/logs/review/pr-1/run-1/iter-1.json b/.devflow/logs/review/pr-1/run-1/iter-1.json' \
  'index 1111111..2222222 100644' \
  '--- a/.devflow/logs/review/pr-1/run-1/iter-1.json' \
  '+++ b/.devflow/logs/review/pr-1/run-1/iter-1.json' \
  '@@ -1,1 +1,1 @@' \
  '-{"LOGHUNKONE_old":1}' \
  '+{"LOGHUNKONE_new":1}' \
  '@@ -10,1 +10,1 @@' \
  '-{"LOGHUNKTWO_old":2}' \
  '+{"LOGHUNKTWO_new":2}' \
  'diff --git a/src/c.py b/src/c.py' \
  'index 5555555..6666666 100644' \
  '--- a/src/c.py' \
  '+++ b/src/c.py' \
  '@@ -1 +1 @@' \
  '-old c' \
  '+new c')"
F181_MULTIHUNK_OUT="$(printf '%s\n' "$F181_MULTIHUNK" | awk "${F181_AWK:-NONEXTRACTED}" 2>/dev/null)"
# The discriminating assertion: the SECOND logs hunk is dropped too (in_logs sticks across @@).
assert_eq "#181 filter: a logs file's SECOND @@ hunk is also dropped (in_logs sticks across hunks)" \
  "absent" "$(case "$F181_MULTIHUNK_OUT" in *LOGHUNKTWO*) echo present;; *) echo absent;; esac)"
# …and the trailing real code hunk after the multi-hunk logs file still survives intact.
assert_eq "#181 filter: real code hunk after a multi-hunk logs file survives" \
  "diff --git a/src/c.py b/src/c.py" \
  "$(printf '%s\n' "$F181_MULTIHUNK_OUT" | grep '^diff --git' | paste -sd'|' -)"

# Fixture: ONLY a telemetry-log hunk.
F181_LOGS_ONLY="$(printf '%s\n' \
  'diff --git a/.devflow/logs/review/pr-1/run-1/iter-1.json b/.devflow/logs/review/pr-1/run-1/iter-1.json' \
  'index 7777777..8888888 100644' \
  '--- a/.devflow/logs/review/pr-1/run-1/iter-1.json' \
  '+++ b/.devflow/logs/review/pr-1/run-1/iter-1.json' \
  '@@ -1 +1 @@' \
  '-{"a":1}' \
  '+{"a":2}')"
F181_LOGS_OUT="$(printf '%s\n' "$F181_LOGS_ONLY" | awk "${F181_AWK:-NONEXTRACTED}" 2>/dev/null)"
# AC-3: a logs-only diff filters to no `diff --git` headers (empty effective diff).
# Non-vacuous as a pair with the mixed test above (which proves the filter passes
# code hunks through rather than deleting everything).
assert_eq "#181 filter: logs-only diff yields no diff --git headers (empty effective diff)" \
  "0" "$(printf '%s\n' "$F181_LOGS_OUT" | grep -c '^diff --git')"

# Fixture: the FIRST hunk is a logs hunk (flag-initialization edge), and the
# surviving code hunk's body embeds the literal '.devflow/logs/' on a content
# line (the false-positive-immunity edge — the filter keys ONLY on `^diff --git`
# headers, so a source line mentioning the path must NOT be eaten). This pins the
# exact regression a careless future edit would introduce (dropping the
# `/^diff --git/` guard so `in_logs` recomputes per line).
F181_EDGE="$(printf '%s\n' \
  'diff --git a/.devflow/logs/efficiency/pr-2.json b/.devflow/logs/efficiency/pr-2.json' \
  'index aaaaaaa..bbbbbbb 100644' \
  '--- a/.devflow/logs/efficiency/pr-2.json' \
  '+++ b/.devflow/logs/efficiency/pr-2.json' \
  '@@ -1 +1 @@' \
  '-{"x":1}' \
  '+{"x":2}' \
  'diff --git a/src/c.py b/src/c.py' \
  'index ccccccc..ddddddd 100644' \
  '--- a/src/c.py' \
  '+++ b/src/c.py' \
  '@@ -1 +1,2 @@' \
  ' LOG_DIR = ".devflow/logs/efficiency"' \
  '+print(".devflow/logs/ mentioned in source")')"
F181_EDGE_OUT="$(printf '%s\n' "$F181_EDGE" | awk "${F181_AWK:-NONEXTRACTED}" 2>/dev/null)"
# Gap A: a leading logs hunk is dropped; only the code header survives.
assert_eq "#181 filter: leading logs hunk dropped, trailing code hunk survives" \
  "diff --git a/src/c.py b/src/c.py" \
  "$(printf '%s\n' "$F181_EDGE_OUT" | grep '^diff --git' | paste -sd'|' -)"
# Gap B (false-positive immunity): a source CONTENT line embedding '.devflow/logs/'
# is NOT filtered — the filter toggles only on `^diff --git` headers.
assert_eq "#181 filter: a code line embedding '.devflow/logs/' is retained, not eaten" \
  "yes" "$(case "$F181_EDGE_OUT" in *'print(".devflow/logs/ mentioned in source")'*) echo yes;; *) echo no;; esac)"

# AC-1 anchoring: the regex is anchored to the a//b/ diff-prefix boundary, so it
# strips only paths that START WITH .devflow/logs/ (AC #1's exact wording), never a
# non-root path that merely contains that substring (a test fixture or a dir named
# *.devflow/logs/). Both header paths below must SURVIVE — a regression to an
# unanchored /\.devflow\/logs\// would drop them and hide real code from review.
F181_NESTED="$(printf '%s\n' \
  'diff --git a/tests/fixtures/.devflow/logs/sample.json b/tests/fixtures/.devflow/logs/sample.json' \
  '@@ -1 +1 @@' \
  '+{"fixture":1}' \
  'diff --git a/src/foo.devflow/logs/bar.py b/src/foo.devflow/logs/bar.py' \
  '@@ -1 +1 @@' \
  '+code')"
F181_NESTED_OUT="$(printf '%s\n' "$F181_NESTED" | awk "${F181_AWK:-NONEXTRACTED}" 2>/dev/null)"
assert_eq "#181 filter: non-root paths containing '.devflow/logs/' are NOT stripped (anchored to 'starts with')" \
  "diff --git a/tests/fixtures/.devflow/logs/sample.json b/tests/fixtures/.devflow/logs/sample.json|diff --git a/src/foo.devflow/logs/bar.py b/src/foo.devflow/logs/bar.py" \
  "$(printf '%s\n' "$F181_NESTED_OUT" | grep '^diff --git' | paste -sd'|' -)"

# AC-1 / peer-completeness (2.3.0a): the awk filter is present in EVERY diff-source
# variant of the Phase 0.2 tee pipeline (PR mode, current-branch mode, and the
# head_override=local fix-loop variant) — three occurrences, one per variant.
assert_eq "#181 filter: awk log-hunk filter present in all three Phase 0.2 diff-source variants" \
  "3" "$(pin_count '{in_logs=/ [ab]\/\.devflow\/logs\//} !in_logs' "$REVIEW_SKILL")"
# AC-4: the SKILL documents WHY the hunks are filtered (intentional telemetry, not
# code-review subjects).
assert_pin_unique "#181 filter: review/SKILL.md documents why .devflow/logs/ hunks are filtered" \
  'intentional DevFlow telemetry commits, not code-review subjects' "$REVIEW_SKILL"
# AC-1 peer-completeness: the Phase 0.3 changed-file list must derive from the
# FILTERED diff.patch (not an independent --name-only), so Phase 1.1's >10-file
# per-file batch slicing never re-fetches a .devflow/logs/ hunk and feeds it to a
# Phase 1 agent — closing the one downstream path the single 0.2 filter wouldn't.
assert_pin_unique "#181 filter: Phase 0.3 derives the changed-file list from the filtered diff.patch (peer-completeness)" \
  'deriving the file list from it excludes them by construction' "$REVIEW_SKILL"

# ────────────────────────────────────────────────────────────────────────────
echo "issue #222: .gitattributes eol=lf + UTF-8 stream self-defense"
# ────────────────────────────────────────────────────────────────────────────
# The helper toolchain must self-defend on Windows / non-UTF-8 hosts: LF line
# endings forced by .gitattributes (so a shebang never becomes `bash\r`) and
# scripts/*.py forcing their own streams + gh I/O to UTF-8 (so emoji/em-dashes
# never trip cp1252). These assert the .gitattributes contract, the no-CR-in-.sh
# index invariant, and the cp1252 RED->GREEN behavior by SUBPROCESS (the harness
# imports the modules in-process, so the entry-path reconfigure is only
# observable when the script is RUN as a CLI — test_python_scripts.py proves the
# complementary import-no-side-effect half).
U8_ROOT="$LIB/.."
U8_SCRIPTS="$U8_ROOT/scripts"

# AC1: .gitattributes exists and `git check-attr eol` resolves to `lf` for a
# sample *.sh, *.py, and *.jq file.
assert_eq "#222: .gitattributes exists at repo root" "yes" \
  "$( [ -f "$U8_ROOT/.gitattributes" ] && echo yes || echo no )"
for _u8f in scripts/config-get.sh scripts/workpad.py lib/classify-pr-kind.jq; do
  assert_eq "#222: git check-attr eol=lf for $_u8f" "lf" \
    "$(git -C "$U8_ROOT" check-attr eol -- "$_u8f" | sed -E 's/.*: eol: //')"
done

# AC2: no tracked *.sh file carries a CR byte in the index (i/lf for every entry).
# `git ls-files --eol` prints `i/<index-eol> w/<worktree-eol> attr/<attr> <path>`;
# a crlf/mixed in the i/ column is a defect. grep -c prints 0 + exits 1 on no
# match, so `|| true` keeps the clean `0`.
assert_eq "#222: no tracked *.sh has crlf/mixed line endings in the index" "0" \
  "$(git -C "$U8_ROOT" ls-files --eol -- '*.sh' | grep -cE 'i/(crlf|mixed)' || true)"

# AC3/AC5: workpad.py new-body is a pure offline formatter whose default --branch
# carries an ellipsis and whose Status carries the rocket glyph, so non-ASCII
# fires with no flags. Under PYTHONIOENCODING=cp1252 today's UNHARDENED code
# raises UnicodeEncodeError (the reported defect); the hardened code exits 0 with
# valid UTF-8 and NO BOM (closing the UTF-16LE-corruption root).
U8_NB="$(mktemp)"
PYTHONIOENCODING=cp1252 python3 "$U8_SCRIPTS/workpad.py" new-body 1 > "$U8_NB" 2>/dev/null
U8_NB_RC=$?
assert_eq "#222 RED->GREEN: workpad.py new-body exits 0 under cp1252" "0" "$U8_NB_RC"
assert_eq "#222: new-body output contains the UTF-8 rocket glyph (did not crash)" "yes" \
  "$(grep -qF '🚀' "$U8_NB" && echo yes || echo no)"
assert_eq "#222: new-body output carries no BOM (UTF-8-no-BOM, not UTF-16LE)" "yes" \
  "$(head -c3 "$U8_NB" | od -An -tx1 | tr -d ' \n' | grep -qE '^(efbbbf|fffe|feff)' && echo no || echo yes)"
rm -f "$U8_NB"

# parse-acs.py emits non-ASCII only as the em-dash in its near-miss breadcrumb
# (a trailing-colon heading triggers it). NOTE: em-dash (U+2014) and ellipsis
# (U+2026) ARE encodable in cp1252 (0x97 / 0x85), so a cp1252 test of em-dash
# content is VACUOUS — it passes even against the unhardened code. The strictly-
# non-UTF-8 codec under which this content genuinely raises without the fix (a
# real RED->GREEN) is `ascii` (em-dash is outside both ascii and latin-1). The
# reconfigure overrides PYTHONIOENCODING, so the hardened script exits 0.
U8_PAB="$(mktemp)"; printf '## Acceptance Criteria:\n- [ ] x\n' > "$U8_PAB"
U8_PAE="$(mktemp)"
PYTHONIOENCODING=ascii python3 "$U8_SCRIPTS/parse-acs.py" --body-file "$U8_PAB" >/dev/null 2>"$U8_PAE"
U8_PA_RC=$?
assert_eq "#222 RED->GREEN: parse-acs.py exits 0 emitting its em-dash breadcrumb under ascii" "0" "$U8_PA_RC"
assert_eq "#222: parse-acs.py emits the em-dash breadcrumb as UTF-8 (did not crash)" "yes" \
  "$(grep -qF '—' "$U8_PAE" && echo yes || echo no)"
rm -f "$U8_PAB" "$U8_PAE"

# AC7 (write-side encode): file-deferrals.py --dry-run writes the issue TITLE and
# a body preview to stderr. We inject a ROCKET (U+1F680, outside cp1252) into the
# manifest `file` so it lands in the derived title. The RED->GREEN discriminates
# on emitted CONTENT, not on a crash: stderr defaults to the backslashreplace
# error handler, so the unhardened code does NOT raise under cp1252 — it exits 0
# but renders the escaped `\U0001f680` instead of the rocket, so the rocket-present
# assertion below fails RED. The hardened stream-forcing emits the real UTF-8
# rocket (GREEN). (Do NOT "simplify" this to an exit-code/crash check — both the
# hardened and unhardened paths exit 0, so a crash check would be vacuous.) The
# em-dash case would be doubly vacuous (em-dash is cp1252-encodable AND stderr
# never raises), which is why the rocket + content-assert is used here.
U8_MAN="$(mktemp)"
cat > "$U8_MAN" <<'JSON'
{"schema_version": 1, "deferrals": [
  {"file": "src/🚀mod.py", "symbol": "fn", "kind": "perf", "summary": "loop",
   "severity": "Medium", "agent": "a", "category": "scope", "explanation": "deferred"}
]}
JSON
PYTHONIOENCODING=cp1252 python3 "$U8_SCRIPTS/file-deferrals.py" \
  --source-issue 1 --pr 2 --manifest "$U8_MAN" --dry-run >/dev/null 2>"$U8_MAN.err"
U8_FD_RC=$?
assert_eq "#222 RED->GREEN: file-deferrals.py --dry-run exits 0 under cp1252 (write-side encode)" "0" "$U8_FD_RC"
assert_eq "#222: file-deferrals.py --dry-run emits its rocket-bearing title as UTF-8" "yes" \
  "$(grep -qF '🚀' "$U8_MAN.err" && echo yes || echo no)"
rm -f "$U8_MAN" "$U8_MAN.err"

# AC6/AC7 (gh decode + temp-file/stdin encode): these are pinned STATICALLY, not
# by a runtime crash, on purpose. On Linux, CPython's UTF-8 Mode (PEP 540) coerces
# the C/POSIX locale to UTF-8, so a subprocess `text=True` DECODE never raises
# here — the UnicodeDecodeError is genuinely Windows-only (cp1252 ANSI codepage,
# no UTF-8-mode coercion). The portable, deterministic guarantee is that the code
# PINS `encoding="utf-8"` at every gh-I/O and temp-file site, so the codec is
# UTF-8 regardless of the host locale. Removing any pin makes these fail (a real
# mutation check), where a runtime test would pass vacuously on the Linux runner.
assert_eq "#222 AC6: workpad.py _run gh wrapper pins encoding=utf-8 (gh decode/encode)" "yes" \
  "$(grep -qF 'stderr=subprocess.PIPE, encoding="utf-8",' "$U8_SCRIPTS/workpad.py" && echo yes || echo no)"
assert_eq "#222 AC7: workpad.py NamedTemporaryFile body write pins encoding=utf-8" "yes" \
  "$(grep -qF "'w', suffix='.md', delete=False, encoding=\"utf-8\"," "$U8_SCRIPTS/workpad.py" && echo yes || echo no)"
assert_eq "#222 AC6: file-deferrals.py _run gh wrapper pins encoding=utf-8" "yes" \
  "$(grep -qF 'stdout=subprocess.PIPE, stderr=subprocess.PIPE, encoding="utf-8",' "$U8_SCRIPTS/file-deferrals.py" && echo yes || echo no)"
assert_eq "#222 AC7: file-deferrals.py gh issue create pins input encoding=utf-8" "yes" \
  "$(grep -qF 'input=body, check=False, encoding="utf-8",' "$U8_SCRIPTS/file-deferrals.py" && echo yes || echo no)"
assert_eq "#222 AC6: parse-acs.py _fetch_body pins gh decode encoding=utf-8" "yes" \
  "$(grep -qF 'check=True, capture_output=True, encoding="utf-8",' "$U8_SCRIPTS/parse-acs.py" && echo yes || echo no)"
# match-deferrals.py's _run also reads gh PR/issue *bodies* (routinely non-ASCII),
# so its decode is pinned too — closing the same Windows decode-crash path.
assert_eq "#222 AC6: match-deferrals.py _run pins gh body-decode encoding=utf-8" "yes" \
  "$(grep -qF 'stdout=subprocess.PIPE, stderr=subprocess.PIPE, encoding="utf-8",' "$U8_SCRIPTS/match-deferrals.py" && echo yes || echo no)"

# Smoke (not RED->GREEN): a gh stub returns a comment body containing a rocket;
# workpad.py id must still decode it and print the matched id. On the Linux runner
# this passes with or without the pin (UTF-8 Mode), so it is a round-trip smoke
# test that the non-ASCII body doesn't break id resolution — NOT the AC6 proof
# (that is the static pin above).
U8_GHD="$(mktemp -d)"
cat > "$U8_GHD/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"repo view"*) echo "acme/example-repo" ;;
  *"comments"*) printf '%s\n' '[{"id":42,"body":"<!-- devflow:workpad --> 🚀 status"}]' ;;
  *) echo '[]' ;;
esac
STUB
chmod +x "$U8_GHD/gh"
U8_ID_OUT="$(PATH="$U8_GHD:$PATH" python3 "$U8_SCRIPTS/workpad.py" id 1 2>/dev/null)"
assert_eq "#222 smoke: workpad.py id resolves a comment with a non-ASCII body" "42" "$U8_ID_OUT"
rm -rf "$U8_GHD"

# ────────────────────────────────────────────────────────────────────────────
echo "python3 interpreter resolution: resolve-python.sh / provision-python3-shim.sh / preflight.sh (issue #225)"
# ────────────────────────────────────────────────────────────────────────────
# Stock Windows Python (python.org / winget) ships `python` + the `py -3` launcher and NO
# `python3` on PATH, so every literal `python3` call fails. These assertions exercise the
# shared selection contract (lib/resolve-python.sh), the consent-gated shim provisioner, the
# preflight resolution path, and install.sh delegation — using fake-interpreter PATH stubs
# (the suite is offline/gh-stubbed, so a temp-dir PATH with fake `python`/`py` fits the
# harness). The fakes pattern-match the exact `-c` probes resolve-python.sh runs and exec the
# REAL interpreter for a script argument, so the shim's arg/exit-code forwarding is exercised
# end-to-end rather than mocked.
PPS="$LIB/../scripts/provision-python3-shim.sh"
PREFLIGHT_SH="$LIB/preflight.sh"
RESOLVE_SH="$LIB/resolve-python.sh"
REAL_PY="$(command -v python3 2>/dev/null || true)"

if [ -z "$REAL_PY" ]; then
  # No real python3 to back the fakes — the whole suite already requires python3 (the python
  # section below runs under it), so this is unreachable in practice; record a FAIL rather
  # than silently skipping coverage if it ever happens.
  echo FAIL >> "$RESULTS_FILE"
  printf '  FAIL  #225: no python3 available to back the fake-interpreter stubs (cannot run resolution tests)\n'
else
  # Populate DIR with coreutils symlinks + no-op git/gh/jq stubs, but deliberately NO python*
  # (so `command -v python3` fails inside the stub PATH); callers then drop in fake interpreters.
  build_stub_bin() {  # $1=dir
    local d="$1" t src
    for t in bash sh env dirname mktemp grep mkdir chmod mv rm ln cat sed cut tr id head wc sort cp printf; do
      src="$(command -v "$t" 2>/dev/null)" && [ -n "$src" ] && ln -s "$src" "$d/$t" 2>/dev/null
    done
    for t in git gh jq; do
      printf '#!/bin/sh\nexit 0\n' > "$d/$t" && chmod +x "$d/$t"
    done
  }
  # Write a fake Python interpreter at $1 reporting version $2 (major $3, minor $4). It honors
  # -V/--version, the `-c 'pass'` runnability probe, the resolve-python version probe, and
  # `import yaml` (present unless $5 == noyaml); any other args (a script path) exec the REAL
  # python3 so behavior is genuine. Args of the generated script are escaped (\$); $2/$3/$4/$5
  # and $REAL_PY expand now, at generation time.
  make_fake_python() {  # $1=path $2=verstring $3=maj $4=min [$5=noyaml]
    local yaml_rc=0
    [ "${5:-}" = "noyaml" ] && yaml_rc=1
    cat > "$1" <<EOF
#!/usr/bin/env bash
case "\$1" in
  -V|--version) echo "Python $2"; exit 0 ;;
esac
if [ "\$1" = "-c" ]; then
  case "\$2" in
    *"version_info >= (3, 11)"*)
      if [ "$3" -gt 3 ] || { [ "$3" -eq 3 ] && [ "$4" -ge 11 ]; }; then exit 0; else exit 1; fi ;;
    pass) exit 0 ;;
    *"import yaml"*) exit $yaml_rc ;;
    *) exit 0 ;;
  esac
fi
exec "$REAL_PY" "\$@"
EOF
    chmod +x "$1"
  }
  # Write a fake `py` launcher at $1 that supports only `-3` and delegates to the fake python at $2.
  make_fake_py() {  # $1=path $2=delegate
    cat > "$1" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "-3" ]; then shift; exec "$2" "\$@"; fi
echo "py: only -3 supported in this stub" >&2; exit 1
EOF
    chmod +x "$1"
  }

  # ── AC1: provisioner exists, SPDX header, consent-gated, stable breadcrumb. ──
  assert_eq "#225 pps: provisioner file exists (AC1)" "yes" "$([ -f "$PPS" ] && echo yes || echo no)"
  assert_eq "#225 pps: SPDX header present (AC1)" "yes" "$(grep -q 'SPDX-License-Identifier: MIT' "$PPS" && echo yes || echo no)"
  assert_eq "#225 pps: consent-gated via --apply (AC1)" "yes" "$(grep -q -- '--apply' "$PPS" && echo yes || echo no)"
  assert_eq "#225 pps: stable devflow-python: breadcrumb prefix (AC1)" "yes" "$(grep -q 'devflow-python:' "$PPS" && echo yes || echo no)"
  assert_eq "#225 resolve-python.sh: SPDX header present" "yes" "$(grep -q 'SPDX-License-Identifier: MIT' "$RESOLVE_SH" && echo yes || echo no)"

  # ── AC2/AC3: alternate `python` (>=3.11), no python3 → shim installed; forwards args+exit. ──
  T1="$(mktemp -d)"; build_stub_bin "$T1"; make_fake_python "$T1/python" "3.11.5" 3 11
  T1BIN="$(mktemp -d)"
  PPS_OUT="$(PATH="$T1" bash "$PPS" --apply "$T1BIN" 2>&1)"; PPS_RC=$?
  assert_eq "#225 pps: alternate python, no python3 → exit 0 (AC2)" "0" "$PPS_RC"
  assert_eq "#225 pps: shim created at target dir (AC2)" "yes" "$([ -f "$T1BIN/python3" ] && echo yes || echo no)"
  assert_eq "#225 pps: shim execs the alternate, NEVER python3 (no recursion) (AC3)" "yes" \
    "$(grep -q '^exec python "\$@"' "$T1BIN/python3" && echo yes || echo no)"
  assert_eq "#225 pps: shim body does not exec python3 (AC3)" "no" \
    "$(grep -q 'exec python3 ' "$T1BIN/python3" && echo yes || echo no)"
  assert_eq "#225 pps: python3 --version via shim reports the >=3.11 interpreter (AC2)" "Python 3.11.5" \
    "$(PATH="$T1BIN:$T1" python3 --version 2>&1)"
  # The shim carries the DevFlow marker line — the clobber guard's recognition signal, so a
  # regression that wrote a working-but-unmarked shim (which would make re-apply refuse its own
  # shim) is caught directly here, not only transitively via the idempotent-rewrite test.
  assert_eq "#225 pps: written shim carries the DevFlow SHIM_MARKER line" "yes" \
    "$(grep -q 'Generated by DevFlow scripts/provision-python3-shim.sh' "$T1BIN/python3" && echo yes || echo no)"
  # Arg + exit-code forwarding through the shim → fake python → real python3.
  printf 'import sys\nprint("args:" + " ".join(sys.argv[1:]))\nsys.exit(7)\n' > "$T1BIN/check.py"
  FWD_OUT="$(PATH="$T1BIN:$T1" python3 "$T1BIN/check.py" hello 2>&1)"; FWD_RC=$?
  assert_eq "#225 pps: shim forwards exit code (AC3)" "7" "$FWD_RC"
  assert_eq "#225 pps: shim forwards args (AC3)" "args:hello" "$FWD_OUT"

  # Default (no --apply) is consent-respecting: prints the plan, writes NOTHING.
  T1D="$(mktemp -d)"
  PPS_DEF_OUT="$(PATH="$T1" bash "$PPS" "$T1D" 2>&1)"; PPS_DEF_RC=$?
  assert_eq "#225 pps: default (no --apply) → exit 0" "0" "$PPS_DEF_RC"
  assert_eq "#225 pps: default (no --apply) writes NOTHING (consent)" "no" "$([ -f "$T1D/python3" ] && echo yes || echo no)"
  assert_eq "#225 pps: default prints --apply guidance" "yes" "$(printf '%s' "$PPS_DEF_OUT" | grep -q -- '--apply' && echo yes || echo no)"

  # ── AC4: selection picks the FIRST >=3.11 (py -3 over a Python-2 `python`); Python-2 rejected. ──
  T4="$(mktemp -d)"; build_stub_bin "$T4"
  make_fake_python "$T4/python" "2.7.18" 2 7           # `python` → Python 2 (must be rejected)
  make_fake_python "$T4/_py3delegate" "3.11.0" 3 11
  make_fake_py "$T4/py" "$T4/_py3delegate"
  SEL="$(PATH="$T4" bash -c ". \"$RESOLVE_SH\"; devflow_resolve_python")"; SEL_RC=$?
  assert_eq "#225 resolve: picks 'py -3' over a Python-2 'python' (AC4)" "py -3" "$SEL"
  assert_eq "#225 resolve: rc 0 when a >=3.11 alternate exists (AC4)" "0" "$SEL_RC"

  # Python-2 only → rc 1 (a runnable interpreter exists but too old), echoes the runnable one.
  T4B="$(mktemp -d)"; build_stub_bin "$T4B"; make_fake_python "$T4B/python" "2.7.18" 2 7
  SEL2="$(PATH="$T4B" bash -c ". \"$RESOLVE_SH\"; devflow_resolve_python")"; SEL2_RC=$?
  assert_eq "#225 resolve: python2-only → echoes the first runnable invocation" "python" "$SEL2"
  assert_eq "#225 resolve: python2-only → rc 1 (too old, distinct from 'none')" "1" "$SEL2_RC"

  # ── AC2/AC3/AC4: `py -3`-resolved host writes a TWO-WORD `exec py -3 "$@"` shim and forwards
  #    end-to-end. Guards the SC2086 word-split hazard: a regression collapsing "py -3" into a
  #    single quoted token (`exec "py -3" "$@"`) would pass every `python`-form assertion above. ──
  TPY3="$(mktemp -d)"; build_stub_bin "$TPY3"
  make_fake_python "$TPY3/_py3delegate" "3.11.4" 3 11
  make_fake_py "$TPY3/py" "$TPY3/_py3delegate"
  TPY3BIN="$(mktemp -d)"
  PPS_PY3_OUT="$(PATH="$TPY3" bash "$PPS" --apply "$TPY3BIN" 2>&1)"; PPS_PY3_RC=$?
  assert_eq "#225 pps: py -3 host, no python3 → exit 0 (AC4)" "0" "$PPS_PY3_RC"
  assert_eq "#225 pps: py -3 host → shim written (AC2)" "yes" "$([ -f "$TPY3BIN/python3" ] && echo yes || echo no)"
  assert_eq "#225 pps: py -3 host → shim body is the two-word 'exec py -3 \"\$@\"' (AC3)" "yes" \
    "$(grep -q '^exec py -3 "\$@"' "$TPY3BIN/python3" && echo yes || echo no)"
  printf 'import sys\nprint("pyargs:" + " ".join(sys.argv[1:]))\nsys.exit(5)\n' > "$TPY3BIN/pcheck.py"
  PY3_FWD_OUT="$(PATH="$TPY3BIN:$TPY3" python3 "$TPY3BIN/pcheck.py" world 2>&1)"; PY3_FWD_RC=$?
  assert_eq "#225 pps: py -3 shim forwards exit code (AC3)" "5" "$PY3_FWD_RC"
  assert_eq "#225 pps: py -3 shim forwards args (AC3)" "pyargs:world" "$PY3_FWD_OUT"

  # ── Clobber guard (SHIM_MARKER): refuse to overwrite a foreign python3; rewrite a DevFlow shim. ──
  # Foreign (non-DevFlow) python3 already at the target → refuse with exit 2, leave it byte-for-byte.
  TCF="$(mktemp -d)"; build_stub_bin "$TCF"; make_fake_python "$TCF/python" "3.11.9" 3 11
  TCFBIN="$(mktemp -d)"; printf '#!/bin/sh\necho FOREIGN\n' > "$TCFBIN/python3"; chmod +x "$TCFBIN/python3"
  PPS_CF_OUT="$(PATH="$TCF" bash "$PPS" --apply "$TCFBIN" 2>&1)"; PPS_CF_RC=$?
  assert_eq "#225 pps: foreign python3 at target → refuse exit 2 (no clobber)" "2" "$PPS_CF_RC"
  assert_eq "#225 pps: foreign python3 → breadcrumb says 'did not create' (refuse to overwrite)" "yes" \
    "$(printf '%s' "$PPS_CF_OUT" | grep -qi 'did not create' && echo yes || echo no)"
  assert_eq "#225 pps: foreign python3 left byte-for-byte unchanged" "yes" \
    "$(grep -q 'echo FOREIGN' "$TCFBIN/python3" && echo yes || echo no)"
  # A DANGLING python3 symlink at the target: `-e` follows symlinks and reports it non-existent,
  # so the clobber guard's `-L` arm is load-bearing — without it the guard would skip and `mv`
  # would silently replace a symlink DevFlow did not create (and a broken python3 symlink is
  # exactly the corrupt-interpreter class this targets). Assert the guard still refuses (exit 2)
  # and leaves the symlink in place. (Review finding: clobber guard fail-open on dangling links.)
  TCDBIN="$(mktemp -d)"; ln -s /nonexistent-python-target "$TCDBIN/python3"
  PPS_CD_OUT="$(PATH="$TCF" bash "$PPS" --apply "$TCDBIN" 2>&1)"; PPS_CD_RC=$?
  assert_eq "#225 pps: dangling python3 symlink at target → refuse exit 2 (no clobber via -L arm)" "2" "$PPS_CD_RC"
  assert_eq "#225 pps: dangling symlink → breadcrumb says 'did not create'" "yes" \
    "$(printf '%s' "$PPS_CD_OUT" | grep -qi 'did not create' && echo yes || echo no)"
  assert_eq "#225 pps: dangling symlink left in place (still a symlink, not overwritten)" "yes" \
    "$([ -L "$TCDBIN/python3" ] && echo yes || echo no)"
  rm -rf "$TCDBIN"
  # A DevFlow shim a prior run wrote (carries the marker) → re-apply is an idempotent rewrite (exit 0).
  TCRBIN="$(mktemp -d)"
  PATH="$TCF" bash "$PPS" --apply "$TCRBIN" >/dev/null 2>&1   # first apply writes the marked shim
  PPS_RE_OUT="$(PATH="$TCF" bash "$PPS" --apply "$TCRBIN" 2>&1)"; PPS_RE_RC=$?
  assert_eq "#225 pps: re-apply over DevFlow's own shim → exit 0 (idempotent rewrite, AC9)" "0" "$PPS_RE_RC"
  assert_eq "#225 pps: re-applied shim still present and still the alternate exec" "yes" \
    "$(grep -q '^exec python "\$@"' "$TCRBIN/python3" && echo yes || echo no)"

  # ── Malformed invocation: unknown option and extra positional both refuse with exit 2. ──
  PPS_OPT_RC=0; PATH="$TCF" bash "$PPS" --bogus "$(mktemp -d)" >/dev/null 2>&1 || PPS_OPT_RC=$?
  assert_eq "#225 pps: unknown option → exit 2" "2" "$PPS_OPT_RC"
  PPS_XTRA_RC=0; PATH="$TCF" bash "$PPS" "$(mktemp -d)" "$(mktemp -d)" >/dev/null 2>&1 || PPS_XTRA_RC=$?
  assert_eq "#225 pps: extra positional argument → exit 2" "2" "$PPS_XTRA_RC"

  # ── AC4/AC6: provisioner refuses (non-zero, specific version msg) on a too-old-only host. ──
  T6T="$(mktemp -d)"
  PPS_OLD_OUT="$(PATH="$T4B" bash "$PPS" --apply "$T6T" 2>&1)"; PPS_OLD_RC=$?
  assert_eq "#225 pps: too-old-only python → refuse exit 2 (AC6)" "2" "$PPS_OLD_RC"
  assert_eq "#225 pps: too-old → specific 'older than 3.11' message, not 'missing' (AC6)" "yes" \
    "$(printf '%s' "$PPS_OLD_OUT" | grep -qi 'older than 3.11' && echo yes || echo no)"
  assert_eq "#225 pps: too-old → no shim written (AC6)" "no" "$([ -f "$T6T/python3" ] && echo yes || echo no)"

  # ── AC5: preflight, no python3 but a >=3.11 alternate → provisioner pointer, NOT dead end. ──
  T5="$(mktemp -d)"; build_stub_bin "$T5"; make_fake_python "$T5/python" "3.11.7" 3 11
  PF5_OUT="$(PATH="$T5" bash "$PREFLIGHT_SH" 2>&1)"; PF5_RC=$?
  assert_eq "#225 preflight: alt python, no python3 → exit non-zero (literal python3 still missing) (AC5)" "yes" \
    "$([ "$PF5_RC" -ne 0 ] && echo yes || echo no)"
  assert_eq "#225 preflight: alt python → points to provision-python3-shim.sh (AC5)" "yes" \
    "$(printf '%s' "$PF5_OUT" | grep -q 'provision-python3-shim.sh' && echo yes || echo no)"
  assert_eq "#225 preflight: alt python → NOT the bare \"missing required tool 'python3'\" dead end (AC5)" "no" \
    "$(printf '%s' "$PF5_OUT" | grep -q "missing required tool 'python3'" && echo yes || echo no)"

  # ── Broken-but-present python3 (dangling symlink / corrupt install / missing DLL — the
  #    broken-Windows-interpreter class this provisioner targets): preflight's happy path now
  #    probes runnability (`python3 -c 'pass'`), so a python3 that is on PATH but does not
  #    execute must NOT short-circuit into a misleading PyYAML/version message; it falls
  #    through to the resolver, which skips it and points at the provisioner via the >=3.11
  #    `python` alternate. (Important review finding: lib/preflight.sh happy-path runnability.)
  T5B="$(mktemp -d)"; build_stub_bin "$T5B"; make_fake_python "$T5B/python" "3.11.7" 3 11
  printf '#!/bin/sh\nexit 127\n' > "$T5B/python3"; chmod +x "$T5B/python3"  # present but never runs
  PF5B_OUT="$(PATH="$T5B" bash "$PREFLIGHT_SH" 2>&1)"; PF5B_RC=$?
  assert_eq "#225 preflight: broken python3 + alt → exit non-zero" "yes" \
    "$([ "$PF5B_RC" -ne 0 ] && echo yes || echo no)"
  assert_eq "#225 preflight: broken-but-present python3 falls through to the resolver → provisioner pointer" "yes" \
    "$(printf '%s' "$PF5B_OUT" | grep -q 'provision-python3-shim.sh' && echo yes || echo no)"
  assert_eq "#225 preflight: broken python3 → NOT a misleading 'PyYAML not found' message" "no" \
    "$(printf '%s' "$PF5B_OUT" | grep -qi 'PyYAML not found' && echo yes || echo no)"

  # ── AC7: preflight runs the PyYAML check against the RESOLVED interpreter (not a hardcoded python3). ──
  T7="$(mktemp -d)"; build_stub_bin "$T7"; make_fake_python "$T7/python" "3.11.2" 3 11 noyaml
  PF7_OUT="$(PATH="$T7" bash "$PREFLIGHT_SH" 2>&1)"
  assert_eq "#225 preflight: PyYAML checked against the resolved interpreter (AC7)" "yes" \
    "$(printf '%s' "$PF7_OUT" | grep -qi 'PyYAML not found' && echo yes || echo no)"
  assert_eq "#225 preflight: PyYAML hint names the resolved interpreter, not hardcoded python3 (AC7)" "yes" \
    "$(printf '%s' "$PF7_OUT" | grep -q "'python -m pip install pyyaml'" && echo yes || echo no)"

  # ── AC6 (preflight half): too-old-only → specific <3.11 message, never 'missing'. ──
  PF6_OUT="$(PATH="$T4B" bash "$PREFLIGHT_SH" 2>&1)"; PF6_RC=$?
  assert_eq "#225 preflight: too-old python → exit non-zero (AC6)" "yes" "$([ "$PF6_RC" -ne 0 ] && echo yes || echo no)"
  assert_eq "#225 preflight: too-old → specific 'Python 3.11+ required' message (AC6)" "yes" \
    "$(printf '%s' "$PF6_OUT" | grep -q 'Python 3.11+ required' && echo yes || echo no)"
  assert_eq "#225 preflight: too-old → NOT the bare \"missing required tool 'python3'\" message (AC6)" "no" \
    "$(printf '%s' "$PF6_OUT" | grep -q "missing required tool 'python3'" && echo yes || echo no)"
  # Positively pin the rc-1 ALTERNATE branch (python2-only host): its message names 'no working
  # python3 on PATH', distinguishing it from the python3-present-<3.11 version-recheck branch
  # (TOLD below). "no working python3" (not "no python3 on PATH") because python3 may be
  # present-but-broken and rejected by preflight's runnability probe, not strictly absent.
  assert_eq "#225 preflight: alternate-too-old → rc-1 branch message names 'no working python3 on PATH' (AC6)" "yes" \
    "$(printf '%s' "$PF6_OUT" | grep -q 'no working python3 on PATH' && echo yes || echo no)"

  # ── AC9: idempotent no-op when a working python3 >=3.11 already resolves. ──
  T9="$(mktemp -d)"; build_stub_bin "$T9"; make_fake_python "$T9/python3" "3.12.3" 3 12
  T9T="$(mktemp -d)"
  PPS9_OUT="$(PATH="$T9" bash "$PPS" --apply "$T9T" 2>&1)"; PPS9_RC=$?
  assert_eq "#225 pps: python3 already works → exit 0 (AC9)" "0" "$PPS9_RC"
  assert_eq "#225 pps: python3 already works → 'nothing to do' breadcrumb (AC9)" "yes" \
    "$(printf '%s' "$PPS9_OUT" | grep -qi 'nothing to do' && echo yes || echo no)"
  assert_eq "#225 pps: python3 already works → no shim written (AC9/AC10)" "no" "$([ -f "$T9T/python3" ] && echo yes || echo no)"

  # ── AC10: real python3 >=3.11 + deps present → byte-identical pass line, no provisioner pointer. ──
  T10="$(mktemp -d)"; build_stub_bin "$T10"; make_fake_python "$T10/python3" "3.12.1" 3 12
  PF10_OUT="$(PATH="$T10" bash "$PREFLIGHT_SH" 2>&1)"; PF10_RC=$?
  assert_eq "#225 preflight: python3 present + deps → exit 0 (AC10)" "0" "$PF10_RC"
  assert_eq "#225 preflight: byte-identical pass line on python3-present path (AC10)" \
    "devflow preflight: all dependencies present." "$(printf '%s\n' "$PF10_OUT" | tail -1)"
  assert_eq "#225 preflight: no provisioner pointer when python3 resolves (AC10)" "no" \
    "$(printf '%s' "$PF10_OUT" | grep -q 'provision-python3-shim.sh' && echo yes || echo no)"

  # ── AC6 (python3-present-but-too-old): a real python3 <3.11 takes preflight's python3 branch
  #    (NOT the resolved-alternate path) and must fail with the specific version message from the
  #    version re-check — a distinct code path from the `python`(alternate)-too-old case above. ──
  TOLD="$(mktemp -d)"; build_stub_bin "$TOLD"; make_fake_python "$TOLD/python3" "3.10.9" 3 10
  PF_OLD3_OUT="$(PATH="$TOLD" bash "$PREFLIGHT_SH" 2>&1)"; PF_OLD3_RC=$?
  assert_eq "#225 preflight: python3 present but <3.11 → exit non-zero (AC6)" "yes" \
    "$([ "$PF_OLD3_RC" -ne 0 ] && echo yes || echo no)"
  assert_eq "#225 preflight: python3 <3.11 → 'Python 3.11+ required (found ...)' from the version re-check (AC6)" "yes" \
    "$(printf '%s' "$PF_OLD3_OUT" | grep -q 'Python 3.11+ required (found' && echo yes || echo no)"
  assert_eq "#225 preflight: python3 <3.11 → NOT the resolved-alternate 'no working python3 on PATH' message (AC6)" "no" \
    "$(printf '%s' "$PF_OLD3_OUT" | grep -q 'no working python3 on PATH' && echo yes || echo no)"

  # ── rc-3 "no usable Python interpreter at all" (no python3, no py, no python). build_stub_bin
  #    yields a python-free PATH, so this exercises the resolver's rc-3 return end-to-end through
  #    BOTH consumers: the provisioner refuses (exit 2, "no Python interpreter found") and preflight
  #    hits its rc-3 `else` dead-end ("missing required tool 'python3'") — NOT the rc-0 provisioner
  #    pointer (there is no alternate to point at). This is the user's only guidance when they have
  #    no Python at all; without it a regression that mis-routed rc-3 to rc-0/rc-1 would ship green. ──
  TNONE="$(mktemp -d)"; build_stub_bin "$TNONE"     # git/gh/jq + coreutils only — no python/python3/py
  # Provisioner: rc-3 → exit 2 + specific breadcrumb, writes nothing.
  TNONE_T="$(mktemp -d)"
  PPS_NONE_OUT="$(PATH="$TNONE" bash "$PPS" --apply "$TNONE_T" 2>&1)"; PPS_NONE_RC=$?
  assert_eq "#225 pps: no interpreter at all → exit 2 (rc-3)" "2" "$PPS_NONE_RC"
  assert_eq "#225 pps: no interpreter at all → 'no Python interpreter found' breadcrumb (rc-3)" "yes" \
    "$(printf '%s' "$PPS_NONE_OUT" | grep -q 'no Python interpreter found' && echo yes || echo no)"
  assert_eq "#225 pps: no interpreter at all → no shim written (rc-3)" "no" "$([ -f "$TNONE_T/python3" ] && echo yes || echo no)"
  # Preflight: rc-3 → exit non-zero + the bare dead-end message, NOT the rc-0 provisioner pointer.
  PF_NONE_OUT="$(PATH="$TNONE" bash "$PREFLIGHT_SH" 2>&1)"; PF_NONE_RC=$?
  assert_eq "#225 preflight: no interpreter at all → exit non-zero (rc-3)" "yes" \
    "$([ "$PF_NONE_RC" -ne 0 ] && echo yes || echo no)"
  assert_eq "#225 preflight: no interpreter at all → bare \"missing required tool 'python3'\" dead end (rc-3)" "yes" \
    "$(printf '%s' "$PF_NONE_OUT" | grep -q "missing required tool 'python3'" && echo yes || echo no)"
  assert_eq "#225 preflight: no interpreter at all → NOT the provisioner pointer (no alternate to point at) (rc-3)" "no" \
    "$(printf '%s' "$PF_NONE_OUT" | grep -q 'provision-python3-shim.sh' && echo yes || echo no)"
  rm -rf "$TNONE" "$TNONE_T"

  # ── Default target-dir selection (the PRODUCTION path — no explicit TARGET_DIR). ──
  # (a) A writable dir on PATH → the shim lands in the first writable PATH dir, no PATH note.
  TDEF="$(mktemp -d)"; build_stub_bin "$TDEF"; make_fake_python "$TDEF/python" "3.11.3" 3 11
  PPS_DEF2_OUT="$(PATH="$TDEF" bash "$PPS" --apply 2>&1)"; PPS_DEF2_RC=$?
  assert_eq "#225 pps: default target — no TARGET_DIR, writable PATH dir → exit 0" "0" "$PPS_DEF2_RC"
  assert_eq "#225 pps: default target — shim written into the first writable PATH dir" "yes" \
    "$([ -f "$TDEF/python3" ] && echo yes || echo no)"
  assert_eq "#225 pps: default target — no PATH note when the chosen dir is on PATH" "no" \
    "$(printf '%s' "$PPS_DEF2_OUT" | grep -qi 'may not be on your PATH' && echo yes || echo no)"
  # (b) No writable dir on PATH AND HOME unset → refuse with exit 2 + the HOME-unset breadcrumb.
  #     Root bypasses the -w bit (the read-only dir would read writable), so skip under root.
  if [ "$(id -u)" -ne 0 ]; then
    TRO="$(mktemp -d)"; build_stub_bin "$TRO"; make_fake_python "$TRO/python" "3.11.3" 3 11
    chmod 0555 "$TRO"
    if [ ! -w "$TRO" ]; then
      PPS_NH_OUT="$(env -u HOME PATH="$TRO" bash "$PPS" --apply 2>&1)"; PPS_NH_RC=$?
      assert_eq "#225 pps: default target — no writable PATH dir + HOME unset → exit 2" "2" "$PPS_NH_RC"
      assert_eq "#225 pps: default target — HOME-unset breadcrumb names the cause" "yes" \
        "$(printf '%s' "$PPS_NH_OUT" | grep -qi 'HOME is unset' && echo yes || echo no)"
    fi
    chmod 0755 "$TRO"   # restore so cleanup can remove it
  else
    printf '  SKIP  #225 pps: default target — HOME-unset refusal (root bypasses the -w bit; verified on non-root CI)\n'
  fi
  # (a2) POSITIVE pin of the post-write resolution check on the auto-selected-PATH-dir success
  #      path: when the chosen writable dir IS on PATH and nothing shadows the shim, python3 now
  #      resolves to it, so the breadcrumb claims 'now resolves'. (TDEF above had no other python3
  #      on PATH, so command -v python3 finds the shim.)
  assert_eq "#225 pps: default target — success breadcrumb confirms 'now resolves' (post-write check)" "yes" \
    "$(printf '%s' "$PPS_DEF2_OUT" | grep -q 'now resolves' && echo yes || echo no)"

  # (c) SHADOWED shim: the shim is written to a later writable PATH dir, but an EARLIER PATH
  #     entry holds a broken `python3` that still wins `command -v` — so the provisioner must NOT
  #     claim 'now resolves'; it warns that the shim is shadowed and exits 3 (distinct from the
  #     exit-2 "wrote nothing" refusals — the shim WAS written). This is the fail-open the
  #     unconditional success breadcrumb had. Root bypasses the -w bit (the read-only earlier dir
  #     would read writable, so auto-select would land there and clobber-refuse instead), so skip
  #     under root. (Review finding: provisioner success-overclaim vs PATH shadowing.)
  if [ "$(id -u)" -ne 0 ]; then
    TSHADOW_E="$(mktemp -d)"                                  # earlier PATH dir: a broken python3
    printf '#!/bin/sh\nexit 127\n' > "$TSHADOW_E/python3"; chmod +x "$TSHADOW_E/python3"
    chmod 0555 "$TSHADOW_E"                                   # non-writable → auto-select skips it
    TSHADOW_W="$(mktemp -d)"; build_stub_bin "$TSHADOW_W"; make_fake_python "$TSHADOW_W/python" "3.11.6" 3 11
    if [ ! -w "$TSHADOW_E" ]; then
      PPS_SH_OUT="$(PATH="$TSHADOW_E:$TSHADOW_W" bash "$PPS" --apply 2>&1)"; PPS_SH_RC=$?
      assert_eq "#225 pps: shadowed shim (earlier broken python3 wins) → exit 3 (shim written but does not win)" "3" "$PPS_SH_RC"
      assert_eq "#225 pps: shadowed shim → breadcrumb names the shadow, does NOT claim 'now resolves'" "yes" \
        "$(printf '%s' "$PPS_SH_OUT" | grep -q 'shadows the shim' && ! printf '%s' "$PPS_SH_OUT" | grep -q 'now resolves' && echo yes || echo no)"
      assert_eq "#225 pps: shadowed shim → the shim WAS written to the later writable dir" "yes" \
        "$([ -f "$TSHADOW_W/python3" ] && echo yes || echo no)"
    fi
    chmod 0755 "$TSHADOW_E"   # restore so cleanup can remove it
    rm -rf "$TSHADOW_E" "$TSHADOW_W"
  else
    printf '  SKIP  #225 pps: shadowed-shim exit-3 path (root bypasses the -w bit; verified on non-root CI)\n'
  fi

  # (d) PATH_NOTE ~/bin fallback SUCCESS path: no writable dir on PATH but HOME set → the shim is
  #     written into $HOME/bin, PATH_NOTE fires, exit 0, and the 'may not be on your PATH' note is
  #     emitted. The only prior coverage of the fallback was the HOME-unset *refusal*; this pins
  #     the success half. Skip under root (the read-only PATH dir would read writable).
  if [ "$(id -u)" -ne 0 ]; then
    TPN_RO="$(mktemp -d)"; build_stub_bin "$TPN_RO"; make_fake_python "$TPN_RO/python" "3.11.8" 3 11
    chmod 0555 "$TPN_RO"
    TPN_HOME="$(mktemp -d)"
    if [ ! -w "$TPN_RO" ]; then
      PPS_PN_OUT="$(HOME="$TPN_HOME" PATH="$TPN_RO" bash "$PPS" --apply 2>&1)"; PPS_PN_RC=$?
      assert_eq "#225 pps: ~/bin fallback success → exit 0" "0" "$PPS_PN_RC"
      assert_eq "#225 pps: ~/bin fallback success → shim written into \$HOME/bin" "yes" \
        "$([ -f "$TPN_HOME/bin/python3" ] && echo yes || echo no)"
      assert_eq "#225 pps: ~/bin fallback success → 'may not be on your PATH' note emitted" "yes" \
        "$(printf '%s' "$PPS_PN_OUT" | grep -qi 'may not be on your PATH' && echo yes || echo no)"
    fi
    chmod 0755 "$TPN_RO"
    rm -rf "$TPN_RO" "$TPN_HOME"
  else
    printf '  SKIP  #225 pps: ~/bin fallback success path (root bypasses the -w bit; verified on non-root CI)\n'
  fi

  # ── preflight resolves to a two-word `py -3` alternate: the SC2086 word-split hazard on
  #    preflight's unquoted $PYTHON must be exercised on the PREFLIGHT side too (the provisioner
  #    side has TPY3, but a regression that quoted "$PYTHON" would break `py -3` in preflight while
  #    passing the provisioner test). A py-3-only host (fake `py -3` delegate, no python3/python)
  #    with noyaml drives $PYTHON="py -3" through the PyYAML hint printf. (Review finding.) ──
  TPYPRE="$(mktemp -d)"; build_stub_bin "$TPYPRE"
  make_fake_python "$TPYPRE/_py3delegate" "3.11.1" 3 11 noyaml   # noyaml → PyYAML check fails → hint fires
  make_fake_py "$TPYPRE/py" "$TPYPRE/_py3delegate"               # `py -3` resolves; no python3, no python
  PF_PY3_OUT="$(PATH="$TPYPRE" bash "$PREFLIGHT_SH" 2>&1)"
  assert_eq "#225 preflight: py-3-only host → provisioner pointer fires (alternate resolved)" "yes" \
    "$(printf '%s' "$PF_PY3_OUT" | grep -q 'provision-python3-shim.sh' && echo yes || echo no)"
  assert_eq "#225 preflight: py-3-only host → PyYAML hint names the resolved 'py -3' (unquoted \$PYTHON word-splits)" "yes" \
    "$(printf '%s' "$PF_PY3_OUT" | grep -qF "'py -3 -m pip install pyyaml'" && echo yes || echo no)"
  rm -rf "$TPYPRE"

  # ── AC8: install.sh delegates to the provisioner on the no-python3/alternate path; not when python3 works. ──
  INSTALL_SH="$LIB/../install.sh"
  REPO_ROOT="$(cd "$LIB/.." && pwd)"
  T8="$(mktemp -d)"; build_stub_bin "$T8"; make_fake_python "$T8/python" "3.11.0" 3 11
  OFFER_OUT="$(PATH="$T8" bash -c "DEVFLOW_SELFTEST=1 . \"$INSTALL_SH\"; offer_python3_shim \"$REPO_ROOT\"" 2>&1)"
  assert_eq "#225 install.sh: no python3 → delegates to provision-python3-shim.sh (AC8)" "yes" \
    "$(printf '%s' "$OFFER_OUT" | grep -q 'devflow-python:' && echo yes || echo no)"
  T8B="$(mktemp -d)"; build_stub_bin "$T8B"; make_fake_python "$T8B/python3" "3.12.0" 3 12
  OFFER_OUT_B="$(PATH="$T8B" bash -c "DEVFLOW_SELFTEST=1 . \"$INSTALL_SH\"; offer_python3_shim \"$REPO_ROOT\"" 2>&1)"
  assert_eq "#225 install.sh: python3 present → NO delegation (AC8)" "no" \
    "$(printf '%s' "$OFFER_OUT_B" | grep -q 'devflow-python:' && echo yes || echo no)"
  # Broken-but-present python3 + a >=3.11 alternate: offer_python3_shim probes RUNNABILITY
  # (`python3 -c 'pass'`), mirroring preflight's happy-path gate, so a python3 that is on PATH
  # but does not execute must NOT short-circuit the offer — it falls through and delegates to
  # the provisioner. A bare `command -v python3` would wrongly skip the offer on exactly the
  # broken-Windows-interpreter class this change targets. (Review finding: install.sh symmetry.)
  T8C="$(mktemp -d)"; build_stub_bin "$T8C"; make_fake_python "$T8C/python" "3.11.4" 3 11
  printf '#!/bin/sh\nexit 127\n' > "$T8C/python3"; chmod +x "$T8C/python3"  # present but never runs
  OFFER_OUT_C="$(PATH="$T8C" bash -c "DEVFLOW_SELFTEST=1 . \"$INSTALL_SH\"; offer_python3_shim \"$REPO_ROOT\"" 2>&1)"
  assert_eq "#225 install.sh: broken-but-present python3 → still delegates to the provisioner" "yes" \
    "$(printf '%s' "$OFFER_OUT_C" | grep -q 'devflow-python:' && echo yes || echo no)"
  rm -rf "$T8C"
  # A provisioner REFUSAL (non-zero rc) must be surfaced with its rc and NOT abort the install —
  # the `bash "$prov" || { rc=$?; log "...rc $rc..." }` branch. Every other install test runs a
  # >=3.11 host where the plan-mode provisioner exits 0, so this branch was untested. Use a
  # too-old-only host ($T4B: python2/too-old, no python3) → offer delegates (plan-only), the
  # provisioner exits 2 (too-old refusal, before the plan/apply split), the offer surfaces the
  # rc and returns 0. (Review finding: rc-surfaced-continues contract untested.)
  OFFER_OUT_R="$(PATH="$T4B" bash -c "DEVFLOW_SELFTEST=1 . \"$INSTALL_SH\"; offer_python3_shim \"$REPO_ROOT\"; echo \"ret=\$?\"" 2>&1)"
  assert_eq "#225 install.sh: provisioner refusal (rc≠0) → surfaced with the rc, install continues" "yes" \
    "$(printf '%s' "$OFFER_OUT_R" | grep -q 'exited non-zero (rc' && echo yes || echo no)"
  assert_eq "#225 install.sh: provisioner refusal → offer_python3_shim still returns 0 (non-aborting)" "yes" \
    "$(printf '%s' "$OFFER_OUT_R" | grep -q 'ret=0' && echo yes || echo no)"

  # ── AC11 (#225) RETIRED by #271. This was a branch-wide `.github`-freeze
  #    (`git diff --name-only origin/main -- .github` must be empty), written to
  #    assert #225's own python-shim change touched no `.github/` path. As a
  #    STANDING suite assertion it is over-broad: it fires on EVERY later branch
  #    that legitimately edits `.github/` — e.g. #271 itself, which adds the
  #    `Bash(.devflow/vendor/devflow/scripts/run-jq.sh:*)` grant to
  #    devflow-implement.yml + devflow-runner.yml + devflow.yml so the
  #    cloud-governed skills can invoke the run-jq.sh wrapper. It cannot
  #    distinguish #225's diff from any
  #    other, so it can only be satisfied by never changing `.github/` again —
  #    which is not a real invariant. The load-bearing `.github/` invariants that
  #    DO warrant a standing guard (the workflow partition invariant, per-workflow
  #    allowlist correctness, the vendored-path/exec-bit contracts, the react-to-
  #    trigger wiring) are each covered by their own dedicated tests elsewhere in
  #    this suite, so retiring this catch-all loses no real coverage.

  # ── AC12: the three docs document the Windows interpreter-resolution path. ──
  for _doc in CONTRIBUTING.md docs/install.md docs/DEVFLOW_SYSTEM_OVERVIEW.md; do
    assert_eq "#225 docs: $_doc documents the python3 resolution path (AC12)" "yes" \
      "$(grep -q 'provision-python3-shim.sh' "$REPO_ROOT/$_doc" && echo yes || echo no)"
  done
fi

# ────────────────────────────────────────────────────────────────────────────
echo "gh binary resolution: resolve-gh.sh / preflight.sh gh path (issue #245)"
# ────────────────────────────────────────────────────────────────────────────
# The sibling of the #225 python-resolution block, for `gh`. On Windows/WSL a
# non-executable `gh` shim (a Python-provided `gh` with a Windows shebang) can
# shadow the real GitHub CLI: `command -v gh` succeeds but `gh --version` fails
# at exec time. devflow_resolve_gh verifies EXECUTION, not presence, so it rejects
# the shim in favor of a runnable `gh.exe`. Fixtures below use bad-shebang scripts
# (exec bit set, cannot run) to reproduce the #3493 break faithfully.
RESOLVE_GH_SH="$LIB/resolve-gh.sh"
PREFLIGHT_SH="$LIB/preflight.sh"

# Static/source hygiene (mirrors the resolve-python.sh checks).
assert_eq "#245 resolve-gh.sh: file exists" "yes" "$([ -f "$RESOLVE_GH_SH" ] && echo yes || echo no)"
assert_eq "#245 resolve-gh.sh: SPDX header present" "yes" \
  "$(grep -q 'SPDX-License-Identifier: MIT' "$RESOLVE_GH_SH" && echo yes || echo no)"
assert_eq "#245 resolve-gh.sh: defines devflow_resolve_gh" "yes" \
  "$(grep -q 'devflow_resolve_gh()' "$RESOLVE_GH_SH" && echo yes || echo no)"
assert_eq "#245 resolve-gh.sh: probes with '--version' only (network/auth-free)" "yes" \
  "$(grep -q -- '--version' "$RESOLVE_GH_SH" && echo yes || echo no)"
assert_eq "#245 resolve-gh.sh: sets no 'set -e'/'set -u' (safe to source)" "no" \
  "$(grep -qE '^[[:space:]]*set -[eu]' "$RESOLVE_GH_SH" && echo yes || echo no)"
# AC3: the gh.exe fallback candidate is referenced by name only — no absolute or
# owner-specific install path is hardcoded.
assert_eq "#245 resolve-gh.sh: gh.exe candidate referenced by name only (no path separator)" "yes" \
  "$(grep -qE '(^|[^/])gh\.exe' "$RESOLVE_GH_SH" && ! grep -qE '/[^ ]*gh\.exe' "$RESOLVE_GH_SH" && echo yes || echo no)"

# ── T1 (AC1, AC2) — defect reproduction: a non-executable (bad-shebang) `gh`
#    earlier on PATH plus a runnable `gh.exe` resolves to `gh.exe`. ──
GHT1="$(mktemp -d)"
printf '#!/nonexistent/devflow-test-interpreter\necho nope\n' > "$GHT1/gh"; chmod +x "$GHT1/gh"
cat > "$GHT1/gh.exe" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo "gh version 2.stub (stub)"; exit 0; }
exit 0
STUB
chmod +x "$GHT1/gh.exe"
T1_SEL="$(env -u DEVFLOW_GH PATH="$GHT1:$PATH" bash -c ". \"$RESOLVE_GH_SH\"; devflow_resolve_gh")"
assert_eq "#245 T1: bad-shebang gh rejected, runnable gh.exe chosen (execution-verified)" "gh.exe" "$T1_SEL"

# ── T2 (AC4) — DEVFLOW_GH override wins and never probes `gh --version`. ──
GHT2="$(mktemp -d)"
cat > "$GHT2/gh-stub" <<'STUB'
#!/usr/bin/env bash
touch "$(dirname "$0")/.probed"
[ "$1" = "--version" ] && { echo "gh version stub"; exit 0; }
exit 0
STUB
chmod +x "$GHT2/gh-stub"
T2_SEL="$(DEVFLOW_GH="$GHT2/gh-stub" bash -c ". \"$RESOLVE_GH_SH\"; devflow_resolve_gh")"
assert_eq "#245 T2: DEVFLOW_GH override returned verbatim (highest precedence)" "$GHT2/gh-stub" "$T2_SEL"
assert_eq "#245 T2: override path never probes gh --version (stub not invoked)" "no" \
  "$([ -f "$GHT2/.probed" ] && echo yes || echo no)"

# ── T3 (AC8) — a runnable `gh` on PATH resolves to `gh` on the first probe. ──
GHT3="$(mktemp -d)"
cat > "$GHT3/gh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo "gh version 2.stub (stub)"; exit 0; }
exit 0
STUB
chmod +x "$GHT3/gh"
T3_SEL="$(env -u DEVFLOW_GH PATH="$GHT3:$PATH" bash -c ". \"$RESOLVE_GH_SH\"; devflow_resolve_gh")"
assert_eq "#245 T3: runnable gh on PATH resolves to 'gh' (no behavior change on Linux/macOS/cloud)" "gh" "$T3_SEL"

# ── Degenerate (AC1 tail) — no runnable candidate → bare `gh` so the caller's
#    best-effort warning path still fires (rc 0 preserved). ──
GHTD="$(mktemp -d)"; ln -s "$(command -v bash)" "$GHTD/bash"
TD_SEL="$(env -u DEVFLOW_GH PATH="$GHTD" "$GHTD/bash" -c ". \"$RESOLVE_GH_SH\"; devflow_resolve_gh")"; TD_RC=$?
assert_eq "#245 degenerate: no runnable gh/gh.exe → falls back to bare 'gh'" "gh" "$TD_SEL"
assert_eq "#245 degenerate: fallback still exits 0 (best-effort warning path preserved)" "0" "$TD_RC"

# ── T5 (AC4 tail) — an EMPTY DEVFLOW_GH is NOT an override: it falls through to
#    probing (empty ≠ match-all, the CLAUDE.md bug class). Guards a regression of
#    the `[ -n "${DEVFLOW_GH:-}" ]` guard to a set-but-empty test, which would echo
#    the empty string and break every gh-caller while staying green. ──
T5_SEL="$(DEVFLOW_GH="" PATH="$GHT3:$PATH" bash -c ". \"$RESOLVE_GH_SH\"; devflow_resolve_gh")"
assert_eq "#245 T5: empty DEVFLOW_GH falls through to the probe (not echoed verbatim)" "gh" "$T5_SEL"

# ── T6 (AC1 ordering) — when BOTH gh and gh.exe are runnable, gh wins (candidate
#    order gh→gh.exe). T1/T3 both pass under a reversed loop order; this pins it. ──
GHT6="$(mktemp -d)"
cat > "$GHT6/gh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo "gh version 2.stub (stub)"; exit 0; }
exit 0
STUB
cat > "$GHT6/gh.exe" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo "gh version 2.stub (stub-exe)"; exit 0; }
exit 0
STUB
chmod +x "$GHT6/gh" "$GHT6/gh.exe"
T6_SEL="$(env -u DEVFLOW_GH PATH="$GHT6:$PATH" bash -c ". \"$RESOLVE_GH_SH\"; devflow_resolve_gh")"
assert_eq "#245 T6: both runnable → gh chosen over gh.exe (candidate order preserved)" "gh" "$T6_SEL"

# ── AC5 / preflight — a present-but-unrunnable `gh` is reported at preflight with
#    a remedy (execution-verified), not silently passed. Shadow BOTH candidates —
#    bad-shebang gh AND bad-shebang gh.exe — so the resolver's degenerate path is
#    forced on every host. Shadowing only `gh` is NOT hermetic: on a WSL host with
#    Windows gh.exe interop the resolver would find the real /mnt/c/.../gh.exe and
#    preflight would (correctly) pass, failing this test on the very platform the
#    resolver targets. git/jq/python3 stay real (only gh is broken). ──
GHTP="$(mktemp -d)"
printf '#!/nonexistent/devflow-test-interpreter\necho nope\n' > "$GHTP/gh"; chmod +x "$GHTP/gh"
printf '#!/nonexistent/devflow-test-interpreter\necho nope\n' > "$GHTP/gh.exe"; chmod +x "$GHTP/gh.exe"
PF_GH_OUT="$(PATH="$GHTP:$PATH" bash "$PREFLIGHT_SH" 2>&1)"; PF_GH_RC=$?
assert_eq "#245 preflight: unrunnable gh shim → exit non-zero (AC5)" "yes" \
  "$([ "$PF_GH_RC" -ne 0 ] && echo yes || echo no)"
assert_eq "#245 preflight: unrunnable gh shim → \"no working 'gh'\" remedy, not silent pass (AC5)" "yes" \
  "$(printf '%s' "$PF_GH_OUT" | grep -q "no working 'gh'" && echo yes || echo no)"

# ── AC5b / preflight — DEVFLOW_GH set to a BROKEN binary: the resolver echoes the
#    override with no probe (by contract), but preflight's re-probe of the chosen
#    invocation must still catch it and name the resolved string in the remedy. A
#    refactor that skips the re-probe when DEVFLOW_GH is set would fail open
#    silently — this pins the override-wins → re-probe-catches interaction. ──
PF_OVR_OUT="$(DEVFLOW_GH="$GHTP/gh" bash "$PREFLIGHT_SH" 2>&1)"; PF_OVR_RC=$?
assert_eq "#245 preflight: broken DEVFLOW_GH override → exit non-zero (re-probe catches it)" "yes" \
  "$([ "$PF_OVR_RC" -ne 0 ] && echo yes || echo no)"
assert_eq "#245 preflight: broken DEVFLOW_GH override → remedy names the resolved binary" "yes" \
  "$(printf '%s' "$PF_OVR_OUT" | grep -q "no working 'gh'.*$GHTP/gh" && echo yes || echo no)"

# ── T4 (AC6) — a Python helper run with DEVFLOW_GH pointing at a stub invokes the
#    stub, not bare `gh`. parse-acs.py shells `gh issue view … --json body`. ──
GHT4="$(mktemp -d)"
cat > "$GHT4/gh" <<'STUB'
#!/usr/bin/env bash
touch "$(dirname "$0")/.called"
# parse-acs.py calls: gh issue view N --json body -q .body
cat <<'BODY'
## Acceptance Criteria
- [ ] devflow-gh-stub-marker criterion
BODY
exit 0
STUB
chmod +x "$GHT4/gh"
PARSE_ACS="$LIB/../scripts/parse-acs.py"
T4_OUT="$(DEVFLOW_GH="$GHT4/gh" python3 "$PARSE_ACS" --issue 1 2>/dev/null)"
assert_eq "#245 T4: Python helper routes gh through DEVFLOW_GH stub (stub invoked)" "yes" \
  "$([ -f "$GHT4/.called" ] && echo yes || echo no)"
assert_eq "#245 T4: Python helper consumed the stub's output (not bare gh)" "yes" \
  "$(printf '%s' "$T4_OUT" | grep -q 'devflow-gh-stub-marker' && echo yes || echo no)"

# ── T7 (AC4 integration) — a REAL converted shell helper, run with DEVFLOW_GH
#    UNSET under a crafted PATH (bad-shebang gh + runnable gh.exe), actually
#    consults the resolver and invokes gh.exe. Guards a helper that sources the
#    resolver but still hardcodes literal `gh` at its call site — the static
#    peer-completeness grep below would stay green on that regression. ──
GHT7="$(mktemp -d)"
printf '#!/nonexistent/devflow-test-interpreter\necho nope\n' > "$GHT7/gh"; chmod +x "$GHT7/gh"
cat > "$GHT7/gh.exe" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  --version) echo "gh version 2.stub (stub-exe)"; exit 0 ;;
esac
# ensure-label.sh calls `<gh> api --method POST .../labels` — record that gh.exe
# (not bare gh) was the binary invoked, then report the benign already-exists shape.
touch "$(dirname "$0")/.exe-called"
echo '{"errors":[{"code":"already_exists"}]}' >&2; exit 1
STUB
chmod +x "$GHT7/gh.exe"
env -u DEVFLOW_GH PATH="$GHT7:$PATH" bash "$LIB/../scripts/ensure-label.sh" DevFlow >/dev/null 2>&1; T7_RC=$?
assert_eq "#245 T7: unset-DEVFLOW_GH helper consults the resolver and invokes gh.exe (not bare gh)" "yes" \
  "$([ -f "$GHT7/.exe-called" ] && echo yes || echo no)"
assert_eq "#245 T7: helper preserves its best-effort exit 0 under the resolved gh.exe" "0" "$T7_RC"

# ── T8 (AC6 negative) — the Python empty-DEVFLOW_GH fallback: `os.environ.get(
#    "DEVFLOW_GH") or "gh"` treats an EMPTY override as fall-through-to-gh (the
#    Python analogue of T5). A regression to `os.environ.get("DEVFLOW_GH","gh")`
#    would echo "" and break every Python gh-caller while T4 stays green. ──
GHT8="$(mktemp -d)"
cat > "$GHT8/gh" <<'STUB'
#!/usr/bin/env bash
touch "$(dirname "$0")/.called"
cat <<'BODY'
## Acceptance Criteria
- [ ] devflow-gh-empty-marker criterion
BODY
exit 0
STUB
chmod +x "$GHT8/gh"
T8_OUT="$(DEVFLOW_GH="" PATH="$GHT8:$PATH" python3 "$LIB/../scripts/parse-acs.py" --issue 1 2>/dev/null)"
assert_eq "#245 T8: empty DEVFLOW_GH in a Python helper falls back to 'gh' (stub invoked)" "yes" \
  "$([ -f "$GHT8/.called" ] && echo yes || echo no)"
assert_eq "#245 T8: empty-override Python helper consumed the stub's output (not an empty argv0)" "yes" \
  "$(printf '%s' "$T8_OUT" | grep -q 'devflow-gh-empty-marker' && echo yes || echo no)"

# ── T9 (AC6 negative) — the headline #3493 fix, exercised end-to-end: pointing
#    DEVFLOW_GH at a non-executable file makes subprocess.run raise OSError
#    (ENOEXEC), which parse-acs.py's `except (subprocess.CalledProcessError,
#    OSError)` must convert into a structured stderr breadcrumb + non-zero exit —
#    never a raw Python traceback. A regression dropping OSError from that except
#    tuple (or from any of the other three Python gh-callers, per the static
#    per-script pins below) would let a raw traceback escape while every other
#    #245 test — which only ever points DEVFLOW_GH at a *runnable* stub — stays
#    green. ──
GHT9="$(mktemp -d)"
printf '#!/nonexistent/devflow-test-interpreter\necho nope\n' > "$GHT9/gh-broken"; chmod +x "$GHT9/gh-broken"
T9_OUT="$(DEVFLOW_GH="$GHT9/gh-broken" python3 "$LIB/../scripts/parse-acs.py" --issue 1 2>&1 >/dev/null)"; T9_RC=$?
assert_eq "#245 T9: unrunnable DEVFLOW_GH override → non-zero exit (OSError converted, not swallowed)" "yes" \
  "$([ "$T9_RC" -ne 0 ] && echo yes || echo no)"
assert_eq "#245 T9: unrunnable DEVFLOW_GH override → structured breadcrumb, not a raw Python traceback" "yes" \
  "$(printf '%s' "$T9_OUT" | grep -q 'gh issue view failed' && ! printf '%s' "$T9_OUT" | grep -q 'Traceback (most recent call last)' && echo yes || echo no)"

# ── T9b — same OSError-conversion class as T9, but for workpad.py's `_repo_full`
#    (every workpad.py subcommand's first gh call, hence the highest-traffic call
#    site of the four Python gh-callers — flagged separately because a class-level
#    fix for T9 alone would leave this specific, highest-traffic site unverified). ──
T9B_OUT="$(DEVFLOW_GH="$GHT9/gh-broken" python3 "$LIB/../scripts/workpad.py" id 1 2>&1 >/dev/null)"; T9B_RC=$?
assert_eq "#245 T9b: workpad.py _repo_full, unrunnable DEVFLOW_GH override → non-zero exit" "yes" \
  "$([ "$T9B_RC" -ne 0 ] && echo yes || echo no)"
assert_eq "#245 T9b: workpad.py _repo_full, unrunnable DEVFLOW_GH override → structured breadcrumb, not a raw Python traceback" "yes" \
  "$(printf '%s' "$T9B_OUT" | grep -q 'repo lookup' && ! printf '%s' "$T9B_OUT" | grep -q 'Traceback (most recent call last)' && echo yes || echo no)"

# ── T10 (AC5 complement) — preflight's "gh not installed" branch, distinct from
#    the AC5 shim branch above. AC5's fixture always plants a bad-shebang gh/
#    gh.exe, so `command -v gh` always succeeds and preflight's if/else always
#    takes the shim (else) branch — the "nothing named gh/gh.exe on PATH" if
#    branch is never actually exercised, even though both branches share the
#    pinned "no working 'gh'" literal and a broken if-branch message would stay
#    invisible to AC5 alone. Curate a PATH with only the other required tools
#    (no gh/gh.exe anywhere) so `command -v gh` and `command -v gh.exe` both
#    genuinely fail. ──
GHT10="$(mktemp -d)"
for _t10_bin in git jq python3 dirname cat grep sed cut tr head; do
  _t10_path="$(command -v "$_t10_bin" 2>/dev/null)"
  [ -n "$_t10_path" ] && ln -sf "$_t10_path" "$GHT10/$_t10_bin"
done
# `env PATH=<restricted> bash …` execs "bash" by searching the NEW (restricted)
# PATH, not the caller's current one — so bash itself must be resolved to its
# full path first, or the restricted PATH (which deliberately excludes real
# gh) would also make `bash` unresolvable and the test would spuriously fail
# on an `env` error rather than exercising preflight at all.
_T10_BASH_BIN="$(command -v bash)"
PF_NI_OUT="$(env -u DEVFLOW_GH PATH="$GHT10" "$_T10_BASH_BIN" "$PREFLIGHT_SH" 2>&1)"; PF_NI_RC=$?
assert_eq "#245 T10: preflight, gh genuinely absent (no gh/gh.exe on PATH) → exit non-zero" "yes" \
  "$([ "$PF_NI_RC" -ne 0 ] && echo yes || echo no)"
assert_eq "#245 T10: preflight, gh genuinely absent → \"not installed\" wording (not the shim wording)" "yes" \
  "$(printf '%s' "$PF_NI_OUT" | grep -q "no working 'gh' — the GitHub CLI is not installed" && echo yes || echo no)"
assert_eq "#245 T10: preflight, gh genuinely absent → does NOT emit the shim-specific remedy" "no" \
  "$(printf '%s' "$PF_NI_OUT" | grep -q 'does not execute' && echo yes || echo no)"

# ── Peer-completeness pin (2.3.0a): every gh-calling shell helper routes through
#    the resolver — no helper retains the bare `: "${DEVFLOW_GH:=gh}"` default, no
#    non-comment bare `gh <subcommand>` call survives outside the resolver (the
#    grep below — best-effort: diagnostic echo/printf lines are excluded, so a
#    call sharing a line with a diagnostic is not covered; T7 is the dynamic
#    backstop), and every Python gh-caller reads DEVFLOW_GH with no argv0 "gh"
#    literal left behind. ──
DGH_ROOT="$(cd "$LIB/.." && pwd)"
DGH_HARDCODE="$(grep -rlF 'DEVFLOW_GH:=gh}' "$DGH_ROOT/scripts" "$DGH_ROOT/lib" --include='*.sh' 2>/dev/null | grep -v '/test/' | grep -c . || true)"
assert_eq "#245 peer-completeness: no shell helper retains the bare DEVFLOW_GH:=gh default" "0" "$DGH_HARDCODE"
# Exclude the resolver itself from the sourcing count (its own header contains the
# literal 'resolve-gh.sh'); without the exclusion the count self-matches to 14 and
# one converted helper could silently drop the sourcing while >=13 stays green.
DGH_SOURCED="$(grep -rlF 'resolve-gh.sh' "$DGH_ROOT/scripts" "$DGH_ROOT/lib" --include='*.sh' 2>/dev/null | grep -v '/test/' | grep -v 'lib/resolve-gh\.sh$' | grep -c . || true)"
assert_eq "#245 peer-completeness: >=13 helpers source resolve-gh.sh (all gh-callers converted, resolver excluded from its own count)" "yes" \
  "$([ "$DGH_SOURCED" -ge 13 ] && echo yes || echo no)"
# The bare-call grep the block comment promises: no non-comment, non-diagnostic
# `gh <subcommand>` invocation outside the resolver. Catches a helper that sources
# the resolver but hardcodes `gh` at a call site (the pre-conversion shape of
# authorize-actor.sh / react-to-trigger.sh) — the two pins above stay green on it.
DGH_BARE="$(grep -rnE '(^|[[:space:]`;|&(])gh[[:space:]]+(api|pr|issue|label|repo|auth|search|run|workflow)([[:space:]]|$)' \
  "$DGH_ROOT/scripts" "$DGH_ROOT/lib" --include='*.sh' 2>/dev/null \
  | grep -v '/test/' | grep -v 'resolve-gh\.sh:' | grep -vE ':[[:space:]]*#' | grep -vE '(echo|printf) ' | grep -c . || true)"
assert_eq "#245 peer-completeness: no non-comment bare gh <subcommand> call survives outside the resolver" "0" "$DGH_BARE"
# Per-script Python routing pins: each of the four Python gh-callers reads the
# documented DEVFLOW_GH override and keeps no bare-"gh" argv0 literal. T4/T8
# exercise parse-acs.py dynamically; these static pins keep a revert in any of
# the other three (the silent-label-loss regression of #3493) from staying green.
for DGH_PY in workpad.py file-deferrals.py match-deferrals.py parse-acs.py; do
  assert_eq "#245 python routing: $DGH_PY reads DEVFLOW_GH (or-\"gh\" form)" "1" \
    "$(grep -cF 'os.environ.get("DEVFLOW_GH") or "gh"' "$DGH_ROOT/scripts/$DGH_PY" || true)"
  assert_eq "#245 python routing: $DGH_PY keeps no bare-\"gh\" argv0 literal" "0" \
    "$(grep -cE '\[[[:space:]]*['"'"'\"]gh['"'"'\"][[:space:]]*,' "$DGH_ROOT/scripts/$DGH_PY" || true)"
done
rm -rf "$GHT1" "$GHT2" "$GHT3" "$GHTD" "$GHTP" "$GHT4" "$GHT6" "$GHT7" "$GHT8" "$GHT9" "$GHT10"

# ────────────────────────────────────────────────────────────────────────────
echo "shared binary resolver + path normalization: resolve-bin.sh / normalize-path.sh / jq routing (issue #247)"
# ────────────────────────────────────────────────────────────────────────────
# Generalizes the #245 gh pattern: resolve-bin.sh is the single shared
# execution-verified resolver (DEVFLOW_<TOOL> override → <tool>/<tool>.exe
# --version probe → bare fallback), resolve-gh.sh delegates to it, jq routes
# through it (DEVFLOW_JQ), and normalize-path.sh converts Windows-form paths
# to the running shell's POSIX form (wslpath → cygpath → env-detected → echo
# unchanged with a stderr breadcrumb).
RESOLVE_BIN_SH="$LIB/resolve-bin.sh"
NORMALIZE_PATH_SH="$LIB/normalize-path.sh"
RESOLVE_JQ_SH="$LIB/resolve-jq.sh"

# Restricted-PATH sandbox builder shared by the fixtures below: symlink only the
# named tools into the dir so `command -v` genuinely fails for everything else.
_mk_restricted() {  # dir tool...
  local _mr_d="$1" _mr_b _mr_p; shift
  for _mr_b in "$@"; do
    _mr_p="$(command -v "$_mr_b" 2>/dev/null)"
    [ -n "$_mr_p" ] && ln -sf "$_mr_p" "$_mr_d/$_mr_b"
  done
  return 0
}

# Static/source hygiene (mirrors the resolve-gh.sh checks).
assert_eq "#247 resolve-bin.sh: file exists" "yes" "$([ -f "$RESOLVE_BIN_SH" ] && echo yes || echo no)"
assert_eq "#247 resolve-bin.sh: SPDX header present" "yes" \
  "$(grep -q 'SPDX-License-Identifier: MIT' "$RESOLVE_BIN_SH" 2>/dev/null && echo yes || echo no)"
assert_eq "#247 resolve-bin.sh: defines devflow_resolve_bin" "yes" \
  "$(grep -q 'devflow_resolve_bin()' "$RESOLVE_BIN_SH" 2>/dev/null && echo yes || echo no)"
assert_eq "#247 resolve-bin.sh: probes with '--version' only (network/auth-free)" "yes" \
  "$(grep -q -- '--version' "$RESOLVE_BIN_SH" 2>/dev/null && echo yes || echo no)"
assert_eq "#247 resolve-bin.sh: sets no 'set -e'/'set -u' (safe to source)" "no" \
  "$(grep -qE '^[[:space:]]*set -[eu]' "$RESOLVE_BIN_SH" 2>/dev/null && echo yes || echo no)"
assert_eq "#247 resolve-bin.sh: candidates referenced by name only (no path separator before .exe)" "yes" \
  "$([ -f "$RESOLVE_BIN_SH" ] && ! grep -qE '/[^ ]*\.exe' "$RESOLVE_BIN_SH" && echo yes || echo no)"
assert_eq "#247 normalize-path.sh: file exists" "yes" "$([ -f "$NORMALIZE_PATH_SH" ] && echo yes || echo no)"
assert_eq "#247 normalize-path.sh: SPDX header present" "yes" \
  "$(grep -q 'SPDX-License-Identifier: MIT' "$NORMALIZE_PATH_SH" 2>/dev/null && echo yes || echo no)"
assert_eq "#247 normalize-path.sh: defines devflow_normalize_path" "yes" \
  "$(grep -q 'devflow_normalize_path()' "$NORMALIZE_PATH_SH" 2>/dev/null && echo yes || echo no)"
assert_eq "#247 normalize-path.sh: sets no 'set -e'/'set -u' (safe to source)" "no" \
  "$(grep -qE '^[[:space:]]*set -[eu]' "$NORMALIZE_PATH_SH" 2>/dev/null && echo yes || echo no)"
assert_eq "#247 resolve-jq.sh: file exists" "yes" "$([ -f "$RESOLVE_JQ_SH" ] && echo yes || echo no)"
assert_eq "#247 resolve-jq.sh: SPDX header present" "yes" \
  "$(grep -q 'SPDX-License-Identifier: MIT' "$RESOLVE_JQ_SH" 2>/dev/null && echo yes || echo no)"
assert_eq "#247 resolve-jq.sh: sets no 'set -e'/'set -u' (safe to source)" "no" \
  "$(grep -qE '^[[:space:]]*set -[eu]' "$RESOLVE_JQ_SH" 2>/dev/null && echo yes || echo no)"
assert_eq "#247 resolve-jq.sh: delegates via devflow_resolve_bin jq" "yes" \
  "$(grep -qE 'devflow_resolve_bin[[:space:]]+jq' "$RESOLVE_JQ_SH" 2>/dev/null && echo yes || echo no)"

# ── T0 (Linux/macOS/cloud no-change AC) — a runnable `jq` resolves to `jq` on
#    the first probe. ──
JQT0="$(mktemp -d)"
cat > "$JQT0/jq" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo "jq-stub-1.7"; exit 0; }
exit 0
STUB
chmod +x "$JQT0/jq"
T0_SEL="$(env -u DEVFLOW_JQ PATH="$JQT0:$PATH" bash -c ". \"$RESOLVE_BIN_SH\"; devflow_resolve_bin jq")"
assert_eq "#247 T0: runnable jq on PATH resolves to 'jq' (no behavior change on Linux/macOS/cloud)" "jq" "$T0_SEL"
T0B_SEL="$(env -u DEVFLOW_JQ PATH="$JQT0:$PATH" bash -c "set -euo pipefail; . \"$RESOLVE_JQ_SH\"; printf %s \"\$DEVFLOW_JQ\"")"
assert_eq "#247 T0b: sourcing resolve-jq.sh under set -euo pipefail sets DEVFLOW_JQ" "jq" "$T0B_SEL"

# ── T1 (defect reproduction) — a non-executable (bad-shebang) `jq` earlier on
#    PATH plus a runnable `jq.exe` resolves to `jq.exe` (execution-verified). ──
JQT1="$(mktemp -d)"
printf '#!/nonexistent/devflow-test-interpreter\necho nope\n' > "$JQT1/jq"; chmod +x "$JQT1/jq"
cat > "$JQT1/jq.exe" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "--version" ] && { echo "jq-stub-1.7-exe"; exit 0; }
exit 0
STUB
chmod +x "$JQT1/jq.exe"
T1_JQ_SEL="$(env -u DEVFLOW_JQ PATH="$JQT1:$PATH" bash -c ". \"$RESOLVE_BIN_SH\"; devflow_resolve_bin jq")"
assert_eq "#247 T1: bad-shebang jq rejected, runnable jq.exe chosen (execution-verified)" "jq.exe" "$T1_JQ_SEL"

# ── T2 — DEVFLOW_JQ override wins verbatim and never probes `--version`. ──
JQT2="$(mktemp -d)"
cat > "$JQT2/jq-stub" <<'STUB'
#!/usr/bin/env bash
touch "$(dirname "$0")/.probed"
exit 0
STUB
chmod +x "$JQT2/jq-stub"
T2_JQ_SEL="$(DEVFLOW_JQ="$JQT2/jq-stub" bash -c ". \"$RESOLVE_BIN_SH\"; devflow_resolve_bin jq")"
assert_eq "#247 T2: DEVFLOW_JQ override returned verbatim (highest precedence)" "$JQT2/jq-stub" "$T2_JQ_SEL"
assert_eq "#247 T2: override path never probes --version (stub not invoked)" "no" \
  "$([ -f "$JQT2/.probed" ] && echo yes || echo no)"

# ── T2b — an EMPTY DEVFLOW_JQ is NOT an override: falls through to the probe
#    (empty ≠ match-all, the CLAUDE.md bug class; mirrors #245 T5). ──
T2B_SEL="$(DEVFLOW_JQ="" PATH="$JQT0:$PATH" bash -c ". \"$RESOLVE_BIN_SH\"; devflow_resolve_bin jq")"
assert_eq "#247 T2b: empty DEVFLOW_JQ falls through to the probe (not echoed verbatim)" "jq" "$T2B_SEL"

# ── T2d — the override must win WITHOUT tr on PATH (pure-bash derivation for
#    the known tools): a degenerate PATH must never silently bypass
#    DEVFLOW_<TOOL> and probe/execute the stub the contract protects. ──
JQT2D="$(mktemp -d)"
ln -s "$(command -v bash)" "$JQT2D/bash"
T2D_SEL="$(DEVFLOW_JQ=/stub/jq PATH="$JQT2D" "$JQT2D/bash" -c ". \"$RESOLVE_BIN_SH\"; devflow_resolve_bin jq")"
assert_eq "#247 T2d: DEVFLOW_JQ override honored with NO tr on PATH (pure-bash known-tool derivation)" "/stub/jq" "$T2D_SEL"

# ── Degenerate — no runnable candidate → bare tool echoed, rc 0 (best-effort
#    contract preserved: existing error paths downstream stay unchanged). ──
JQTD="$(mktemp -d)"; ln -s "$(command -v bash)" "$JQTD/bash"
ln -s "$(command -v tr)" "$JQTD/tr" 2>/dev/null
TD_JQ_SEL="$(env -u DEVFLOW_JQ PATH="$JQTD" "$JQTD/bash" -c ". \"$RESOLVE_BIN_SH\"; devflow_resolve_bin jq")"; TD_JQ_RC=$?
assert_eq "#247 degenerate: no runnable jq/jq.exe → falls back to bare 'jq'" "jq" "$TD_JQ_SEL"
assert_eq "#247 degenerate: fallback still exits 0 (best-effort contract preserved)" "0" "$TD_JQ_RC"

# ── T3 (gh refactor regression) — resolve-gh.sh now delegates to the shared
#    resolver; DEVFLOW_GH precedence and stub semantics must be unchanged. The
#    full #245 block above is the deep regression net; this pins the delegation
#    itself (resolve-gh.sh sources resolve-bin.sh and stays a thin wrapper). ──
T3_DELEG="$(DEVFLOW_GH=/fake/devflow-gh bash -c ". \"$LIB/resolve-gh.sh\"; devflow_resolve_gh")"
assert_eq "#247 T3: resolve-gh.sh delegation preserves DEVFLOW_GH override precedence" "/fake/devflow-gh" "$T3_DELEG"
assert_eq "#247 T3: resolve-gh.sh sources the shared resolver (delegation, not a second copy)" "yes" \
  "$(grep -q 'resolve-bin\.sh' "$LIB/resolve-gh.sh" && echo yes || echo no)"
assert_eq "#247 T3: resolve-gh.sh delegates via devflow_resolve_bin gh" "yes" \
  "$(grep -qE 'devflow_resolve_bin[[:space:]]+gh' "$LIB/resolve-gh.sh" && echo yes || echo no)"

# ── T4 (path normalization) — Windows-form input under a stub wslpath, a stub
#    cygpath, the env-detected fallback (uname/MSYSTEM), and POSIX passthrough.
#    uname is STUBBED in the env-detect cases so the assertions are hermetic on
#    every host (a real WSL host's `uname -r` contains "microsoft"). ──
NPT4="$(mktemp -d)"
cat > "$NPT4/wslpath" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "-u" ] && { echo "/mnt/c/from/wslpath"; exit 0; }
exit 1
STUB
chmod +x "$NPT4/wslpath"
T4A="$(PATH="$NPT4:$PATH" bash -c ". \"$NORMALIZE_PATH_SH\"; devflow_normalize_path 'C:\\Users\\x'")"
assert_eq "#247 T4a: wslpath preferred when present" "/mnt/c/from/wslpath" "$T4A"

NPT4B="$(mktemp -d)"
cat > "$NPT4B/cygpath" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "-u" ] && { echo "/c/from/cygpath"; exit 0; }
exit 1
STUB
chmod +x "$NPT4B/cygpath"
# Restricted PATH (no wslpath anywhere) so cygpath is genuinely the first tool.
_mk_restricted "$NPT4B" bash tr grep uname dirname
_NP_BASH_BIN="$(command -v bash)"
T4B="$(PATH="$NPT4B" "$_NP_BASH_BIN" -c ". \"$NORMALIZE_PATH_SH\"; devflow_normalize_path 'C:\\Users\\x'")"
assert_eq "#247 T4b: cygpath used when wslpath absent" "/c/from/cygpath" "$T4B"

# Env-detected fallback, WSL flavor: no wslpath/cygpath on PATH, stub uname
# reporting a microsoft kernel → /mnt/c translation.
NPT4C="$(mktemp -d)"
printf '#!/usr/bin/env bash\necho "5.15.0-microsoft-standard-WSL2"\n' > "$NPT4C/uname"; chmod +x "$NPT4C/uname"
_mk_restricted "$NPT4C" bash tr grep dirname
T4C="$(env -u MSYSTEM PATH="$NPT4C" "$_NP_BASH_BIN" -c ". \"$NORMALIZE_PATH_SH\"; devflow_normalize_path 'C:\\Users\\x'")"
assert_eq "#247 T4c: env-detected WSL fallback (uname microsoft, no tools) → /mnt/c form" "/mnt/c/Users/x" "$T4C"

# Env-detected fallback, MSYS flavor: no tools, non-microsoft uname, MSYSTEM set.
NPT4D="$(mktemp -d)"
printf '#!/usr/bin/env bash\necho "generic-kernel"\n' > "$NPT4D/uname"; chmod +x "$NPT4D/uname"
_mk_restricted "$NPT4D" bash tr grep dirname
T4D="$(MSYSTEM=MINGW64 PATH="$NPT4D" "$_NP_BASH_BIN" -c ". \"$NORMALIZE_PATH_SH\"; devflow_normalize_path 'C:\\Users\\x'")"
assert_eq "#247 T4d: env-detected MSYS fallback (MSYSTEM set, no tools) → /c form" "/c/Users/x" "$T4D"

# Last resort: no tools, no env signal → input unchanged (rc 0) + stderr breadcrumb.
NPT4E="$(mktemp -d)"
printf '#!/usr/bin/env bash\necho "generic-kernel"\n' > "$NPT4E/uname"; chmod +x "$NPT4E/uname"
_mk_restricted "$NPT4E" bash tr grep dirname
T4E_OUT="$(env -u MSYSTEM PATH="$NPT4E" "$_NP_BASH_BIN" -c ". \"$NORMALIZE_PATH_SH\"; devflow_normalize_path 'C:\\Users\\x'" 2>"$NPT4E/stderr")"; T4E_RC=$?
T4E_ERR="$(cat "$NPT4E/stderr")"
assert_eq "#247 T4e: no tool + no env signal → input unchanged" 'C:\Users\x' "$T4E_OUT"
assert_eq "#247 T4e: no tool + no env signal → rc 0 (best-effort)" "0" "$T4E_RC"
assert_eq "#247 T4e: no tool + no env signal → stderr breadcrumb emitted" "yes" \
  "$(printf '%s' "$T4E_ERR" | grep -q 'could not normalize' && echo yes || echo no)"

# POSIX-form passthrough: never touched, no tools consulted, no breadcrumb.
T4F="$(bash -c ". \"$NORMALIZE_PATH_SH\"; devflow_normalize_path '/home/user/x'" 2>&1)"
assert_eq "#247 T4f: non-Windows-form input passes through unchanged (no breadcrumb)" "/home/user/x" "$T4F"

# ── T4k — tr absent from the restricted PATH: the env-detected arm fails
#    CLOSED (input unchanged + tr breadcrumb), never a corrupted /mnt//...
#    path; the SKILL.md block behaves identically (lockstep on this branch). ──
NPT4K="$(mktemp -d)"
printf '#!/usr/bin/env bash\necho "5.15.0-microsoft-standard-WSL2"\n' > "$NPT4K/uname"; chmod +x "$NPT4K/uname"
_mk_restricted "$NPT4K" bash grep dirname
T4K_OUT="$(env -u MSYSTEM PATH="$NPT4K" "$_NP_BASH_BIN" -c ". \"$NORMALIZE_PATH_SH\"; devflow_normalize_path 'C:\\Users\\x'" 2>"$NPT4K/err")"
assert_eq "#247 T4k: tr-less env-detect arm → input unchanged (never /mnt//...)" 'C:\Users\x' "$T4K_OUT"
assert_eq "#247 T4k: tr-less arm leaves the tr breadcrumb" "yes" \
  "$(grep -q 'tr unavailable' "$NPT4K/err" && echo yes || echo no)"
# ── T4k-setE — the header's "safe to source under set -e" contract: a set -e
#    caller sourcing the helper on the same tr-less degenerate PATH must NOT
#    abort at the drive-lowercasing assignment before the empty-drive guard
#    runs. Without the `|| drive=""` fallback the tr-less pipeline's non-zero
#    status trips set -e and the guard never runs. ──
T4KSE_OUT="$(env -u MSYSTEM PATH="$NPT4K" "$_NP_BASH_BIN" -c "set -e; . \"$NORMALIZE_PATH_SH\"; devflow_normalize_path 'C:\\Users\\x'; printf 'SE_OK\\n'" 2>/dev/null)"; T4KSE_RC=$?
assert_eq "#247 T4k set -e: tr-less source under set -e reaches the guard, never aborts" "yes" \
  "$(printf '%s' "$T4KSE_OUT" | grep -q 'SE_OK' && echo yes || echo no)"
assert_eq "#247 T4k set -e: returns 0 to the set -e caller" "0" "$T4KSE_RC"
assert_eq "#247 T4k set -e: still yields the input unchanged (fail-closed)" 'C:\Users\x' \
  "$(printf '%s' "$T4KSE_OUT" | head -1)"
# ── Preflight jq — execution-verified via the shared resolver, mirroring the
#    #245 gh two-branch diagnosis. Shadow BOTH candidates (bad-shebang jq AND
#    jq.exe) so the degenerate path is forced on every host. ──
JQTP="$(mktemp -d)"
printf '#!/nonexistent/devflow-test-interpreter\necho nope\n' > "$JQTP/jq"; chmod +x "$JQTP/jq"
printf '#!/nonexistent/devflow-test-interpreter\necho nope\n' > "$JQTP/jq.exe"; chmod +x "$JQTP/jq.exe"
PF_JQ_OUT="$(env -u DEVFLOW_JQ PATH="$JQTP:$PATH" bash "$LIB/preflight.sh" 2>&1)"; PF_JQ_RC=$?
assert_eq "#247 preflight: unrunnable jq shim → exit non-zero" "yes" \
  "$([ "$PF_JQ_RC" -ne 0 ] && echo yes || echo no)"
assert_eq "#247 preflight: unrunnable jq shim → \"no working 'jq'\" remedy naming DEVFLOW_JQ, not silent pass" "yes" \
  "$(printf '%s' "$PF_JQ_OUT" | grep -q "no working 'jq'" && printf '%s' "$PF_JQ_OUT" | grep -q 'DEVFLOW_JQ' && echo yes || echo no)"

# jq genuinely absent (nothing named jq/jq.exe on PATH) → the "not installed"
# branch wording, not the shim wording (mirrors #245 T10's curated PATH).
JQT10="$(mktemp -d)"
_mk_restricted "$JQT10" git gh python3 dirname cat grep sed cut tr head
_JQ10_BASH_BIN="$(command -v bash)"
PF_JQNI_OUT="$(env -u DEVFLOW_JQ PATH="$JQT10" "$_JQ10_BASH_BIN" "$LIB/preflight.sh" 2>&1)"; PF_JQNI_RC=$?
assert_eq "#247 preflight: jq genuinely absent → exit non-zero" "yes" \
  "$([ "$PF_JQNI_RC" -ne 0 ] && echo yes || echo no)"
assert_eq "#247 preflight: jq genuinely absent → \"not installed\" wording (not the shim wording)" "yes" \
  "$(printf '%s' "$PF_JQNI_OUT" | grep -q "no working 'jq' — jq is not installed" && echo yes || echo no)"

# ── T5 (anchor recipe pin) — skills/create-issue/SKILL.md carries the inline
#    Windows-form anchor normalization at BOTH coupled SKILL_DIR sites (the
#    #241 recipe's parked half; inline because the anchor is what locates
#    helpers — it cannot source lib/normalize-path.sh). ──
CI_SKILL="$LIB/../skills/create-issue/SKILL.md"
assert_eq "#247 T5: create-issue SKILL.md carries the inline anchor normalization at both coupled sites" "yes" \
  "$([ "$(grep -c 'Windows-form anchor normalization' "$CI_SKILL" 2>/dev/null)" -ge 2 ] && echo yes || echo no)"  # raw-guard-ok: count-based (two coupled SKILL_DIR sites must both carry the block; uniqueness would be wrong)
# Operative-code pin (not just the comment heading above — a half-revert that
# deletes the normalization code but keeps its comment must go RED): the
# Windows-form detection line itself, present at both coupled sites.
assert_eq "#247 T5b: both sites carry the operative Windows-form detection line (comment-only half-revert goes RED)" "yes" \
  "$([ "$(grep -cF 'if [[ "$SKILL_DIR" =~ ^[A-Za-z]:[\\/] ]]; then' "$CI_SKILL" 2>/dev/null)" -ge 2 ] && echo yes || echo no)"  # raw-guard-ok: count-based (same two coupled sites)
# T5c: the two inline blocks must stay BYTE-IDENTICAL modulo indentation — the
# lockstep contract with lib/normalize-path.sh is only auditable if the in-file
# mirror pair cannot drift apart silently (a translation-logic edit applied to
# one site but not the other would otherwise ship green past T5/T5b).
T5C_EQ="$(awk '
  /# Windows-form anchor normalization/ { on=1; n++ }
  on {
    line=$0; sub(/^[[:space:]]*/, "", line)
    blk[n] = blk[n] line "\n"
    if (u && line == "fi") { on=0; u=0 }
    if (line ~ /^unset _d _np _r$/) u=1
  }
  END { if (n==2 && blk[1]==blk[2]) print "identical"; else print "different:" n }
' "$CI_SKILL")"
assert_eq "#247 T5c: the two inline anchor-normalization blocks are byte-identical (modulo indentation)" "identical" "$T5C_EQ"

# ── T6 (jq call-site integration) — a REAL converted helper, run with
#    DEVFLOW_JQ pointing at a recording stub, invokes the stub rather than bare
#    jq. Scope: the stub records ANY invocation (the first is the usability
#    gate probe), so this proves the helper consults DEVFLOW_JQ at all — the
#    static DJQ_BARE grep below is what holds every data-processing call site
#    to the converted form. ──
JQT6="$(mktemp -d)"
cat > "$JQT6/jq-rec" <<'STUB'
#!/usr/bin/env bash
touch "$(dirname "$0")/.called"
exec jq "$@"
STUB
chmod +x "$JQT6/jq-rec"
DEVFLOW_JQ="$JQT6/jq-rec" bash "$LIB/../scripts/detect-project-tools.sh" "$JQT6" >/dev/null 2>&1 || true
assert_eq "#247 T6: converted helper routes jq through DEVFLOW_JQ (stub invoked)" "yes" \
  "$([ -f "$JQT6/.called" ] && echo yes || echo no)"

# ── T4i — a wslpath that exits 0 but prints NOTHING must not yield an empty
#    path ("the caller always gets a usable string"): falls through to the
#    next tier. ──
NPT4I="$(mktemp -d)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$NPT4I/wslpath"; chmod +x "$NPT4I/wslpath"
printf '#!/usr/bin/env bash\necho "5.15.0-microsoft-standard-WSL2"\n' > "$NPT4I/uname"; chmod +x "$NPT4I/uname"
_mk_restricted "$NPT4I" bash tr grep dirname
T4I="$(env -u MSYSTEM PATH="$NPT4I" "$_NP_BASH_BIN" -c ". \"$NORMALIZE_PATH_SH\"; devflow_normalize_path 'C:\\Users\\x'" 2>/dev/null)"
assert_eq "#247 T4i: empty-but-successful wslpath output falls through (never an empty path)" "/mnt/c/Users/x" "$T4I"

# ── T4j — spaces and a lowercase non-C drive letter through the env-detected
#    arm (real anchors look like d:\Program Files\...). ──
T4J="$(env -u MSYSTEM PATH="$NPT4C" "$_NP_BASH_BIN" -c ". \"$NORMALIZE_PATH_SH\"; devflow_normalize_path 'd:\\Program Files\\x'" 2>/dev/null)"
assert_eq "#247 T4j: spaces + lowercase drive letter normalize (env-detected WSL arm)" "/mnt/d/Program Files/x" "$T4J"

# ── T4g — a PRESENT-but-FAILING wslpath (prints partial output, exits 1) must
#    not contaminate the result: the chain falls through to the next tier and
#    the caller receives ONE clean line (the pre-fix form leaked the partial
#    stdout before the fallback's line). ──
NPT4G="$(mktemp -d)"
printf '#!/usr/bin/env bash\necho "/mnt/partial-garbage"; exit 1\n' > "$NPT4G/wslpath"; chmod +x "$NPT4G/wslpath"
printf '#!/usr/bin/env bash\necho "5.15.0-microsoft-standard-WSL2"\n' > "$NPT4G/uname"; chmod +x "$NPT4G/uname"
_mk_restricted "$NPT4G" bash tr grep dirname
T4G="$(env -u MSYSTEM PATH="$NPT4G" "$_NP_BASH_BIN" -c ". \"$NORMALIZE_PATH_SH\"; devflow_normalize_path 'C:\\Users\\x'" 2>/dev/null)"
assert_eq "#247 T4g: failing wslpath falls through cleanly (no partial-output contamination)" "/mnt/c/Users/x" "$T4G"

# ── T4h — forward-slash Windows form (C:/...) through the env-detected arm
#    (the regex and docs both claim it; pin it so an anchor-on-backslash edit
#    goes RED). ──
T4H="$(env -u MSYSTEM PATH="$NPT4C" "$_NP_BASH_BIN" -c ". \"$NORMALIZE_PATH_SH\"; devflow_normalize_path 'C:/Users/x'")"
assert_eq "#247 T4h: forward-slash Windows form normalizes identically (env-detected WSL arm)" "/mnt/c/Users/x" "$T4H"

# ── T7 — PARTIAL-COPY deployments: resolve-jq.sh / resolve-gh.sh present
#    without their sibling resolve-bin.sh must degrade with a breadcrumb, never
#    leave DEVFLOW_JQ empty (jq) or abort set -e callers at source time (gh). ──
JQT7="$(mktemp -d)"
cp "$RESOLVE_JQ_SH" "$JQT7/resolve-jq.sh"
T7_OUT="$(env -u DEVFLOW_JQ bash -c "set -euo pipefail; . \"$JQT7/resolve-jq.sh\"; printf %s \"\$DEVFLOW_JQ\"" 2>"$JQT7/err")"
assert_eq "#247 T7: partial copy (no resolve-bin.sh) → DEVFLOW_JQ falls back to bare 'jq', not empty" "jq" "$T7_OUT"
assert_eq "#247 T7: partial copy → breadcrumb names the missing resolve-bin.sh" "yes" \
  "$(grep -q 'resolve-bin.sh not found or not sourceable beside resolve-jq.sh' "$JQT7/err" && echo yes || echo no)"
cp "$LIB/resolve-gh.sh" "$JQT7/resolve-gh.sh"
T7B_OUT="$(DEVFLOW_GH=/stub/gh bash -c "set -euo pipefail; . \"$JQT7/resolve-gh.sh\"; devflow_resolve_gh" 2>"$JQT7/err-gh")"
assert_eq "#247 T7b: partial copy (no resolve-bin.sh) → devflow_resolve_gh degrades to DEVFLOW_GH-or-bare-gh" "/stub/gh" "$T7B_OUT"
assert_eq "#247 T7b: partial copy → gh breadcrumb emitted (no raw set -e abort)" "yes" \
  "$(grep -q 'resolve-bin.sh not found or not sourceable beside resolve-gh.sh' "$JQT7/err-gh" && echo yes || echo no)"
T7C_OUT="$(env -u DEVFLOW_GH bash -c "set -euo pipefail; . \"$JQT7/resolve-gh.sh\"; devflow_resolve_gh" 2>/dev/null)"
assert_eq "#247 T7c: partial copy, no override → degraded devflow_resolve_gh defaults to bare 'gh' (set -u safe)" "gh" "$T7C_OUT"

# ── T7d — sourceability, not just existence: an UNREADABLE resolve-bin.sh
#    beside resolve-jq.sh must take the same fallback arm (bare jq +
#    breadcrumb), never leave DEVFLOW_JQ empty. ──
JQT7D="$(mktemp -d)"
cp "$RESOLVE_JQ_SH" "$JQT7D/resolve-jq.sh"
printf 'garbage' > "$JQT7D/resolve-bin.sh"; chmod 000 "$JQT7D/resolve-bin.sh"
T7D_OUT="$(env -u DEVFLOW_JQ bash -c "set -euo pipefail; . \"$JQT7D/resolve-jq.sh\"; printf %s \"\$DEVFLOW_JQ\"" 2>"$JQT7D/err")"
assert_eq "#247 T7d: unreadable resolve-bin.sh → DEVFLOW_JQ falls back to bare 'jq', not empty" "jq" "$T7D_OUT"
assert_eq "#247 T7d: unreadable resolve-bin.sh → fallback breadcrumb fires" "yes" \
  "$(grep -q 'not found or not sourceable beside resolve-jq.sh' "$JQT7D/err" && echo yes || echo no)"
chmod 600 "$JQT7D/resolve-bin.sh"
# Same sourceability class for the OTHER two guard sites: resolve-gh.sh and
# preflight.sh beside an unreadable resolve-bin.sh must take their fallback
# arms too (a regression to a bare `. file` at either site ships green
# without these).
cp "$LIB/resolve-gh.sh" "$JQT7D/resolve-gh.sh"
chmod 000 "$JQT7D/resolve-bin.sh"
T7E_OUT="$(env -u DEVFLOW_GH bash -c "set -euo pipefail; . \"$JQT7D/resolve-gh.sh\"; devflow_resolve_gh" 2>"$JQT7D/err-gh2")"
assert_eq "#247 T7e: unreadable resolve-bin.sh → devflow_resolve_gh degrades to bare 'gh'" "gh" "$T7E_OUT"
assert_eq "#247 T7e: unreadable resolve-bin.sh → gh fallback breadcrumb fires" "yes" \
  "$(grep -q 'not found or not sourceable beside resolve-gh.sh' "$JQT7D/err-gh2" && echo yes || echo no)"
cp "$LIB/preflight.sh" "$LIB/resolve-python.sh" "$JQT7D/"
T7F_ERR="$(env -u DEVFLOW_JQ -u DEVFLOW_GH bash "$JQT7D/preflight.sh" 2>&1)"; T7F_RC=$?
assert_eq "#247 T7f: preflight beside unreadable resolve-bin.sh → degraded breadcrumb, no phantom-shim wording" "yes" \
  "$(printf '%s' "$T7F_ERR" | grep -q 'missing or not sourceable beside preflight.sh' && ! printf '%s' "$T7F_ERR" | grep -q "the resolved '' does not execute" && echo yes || echo no)"
assert_eq "#247 T7f: preflight degraded mode still exits 0 on a healthy host" "0" "$T7F_RC"
chmod 600 "$JQT7D/resolve-bin.sh"

DJQ_ROOT="$(cd "$LIB/.." && pwd)"
# ── Helper-side breadcrumb literal pins — the init-relay pin above holds the
#    SKILL side; these hold the four EMITTING helpers to the same literal so a
#    reworded gate breadcrumb cannot desync the relay silently (two-sided
#    coupling). ──
for _brf in scripts/detect-project-tools.sh scripts/provision-auto-mode.sh scripts/provision-local-settings.sh scripts/scaffold-config.sh; do
  assert_eq "#247 gate breadcrumb literal present in $_brf" "yes" \
    "$(grep -q 'no usable jq (missing or not executable)' "$DJQ_ROOT/$_brf" && echo yes || echo no)"
done

# ── Shim-present negative branch (the defect #247 fixes), behavioral: a
#    bad-shebang jq with no jq.exe and no override must take the graceful
#    breadcrumb path, not detonate mid-script (a revert to `command -v jq`
#    would ship green without this). ──
JQNEG="$(mktemp -d)"
printf '#!/nonexistent/devflow-test-interpreter\necho nope\n' > "$JQNEG/jq"; chmod +x "$JQNEG/jq"
_mk_restricted "$JQNEG" bash tr grep dirname cat mktemp mv rm find sort head sed uniq
JQNEG_ERR="$(env -u DEVFLOW_JQ PATH="$JQNEG" "$_JQ10_BASH_BIN" "$DJQ_ROOT/scripts/detect-project-tools.sh" "$JQNEG" 2>&1)"; JQNEG_RC=$?
assert_eq "#247 shim-negative: detect-project-tools with unrunnable jq → exit 0 (best-effort preserved)" "0" "$JQNEG_RC"
assert_eq "#247 shim-negative: detect-project-tools emits the 'no usable jq' breadcrumb" "yes" \
  "$(printf '%s' "$JQNEG_ERR" | grep -q 'no usable jq (missing or not executable)' && echo yes || echo no)"

# ── Generic resolver arm (future tools): override honored via the tr path,
#    and the tr-less unknown-tool arm fails closed with the derivation
#    breadcrumb (never a mangled DEVFLOW_ lookup or the internal sentinel). ──
GEN_SEL="$(DEVFLOW_GIT=/stub/git bash -c ". \"$RESOLVE_BIN_SH\"; devflow_resolve_bin git")"
assert_eq "#247 generic arm: DEVFLOW_GIT override honored for an unrouted tool" "/stub/git" "$GEN_SEL"
GENTR="$(mktemp -d)"; ln -s "$(command -v bash)" "$GENTR/bash"
GEN_ERR="$(env -u DEVFLOW_GIT PATH="$GENTR" "$GENTR/bash" -c ". \"$RESOLVE_BIN_SH\"; devflow_resolve_bin git" 2>&1 >/dev/null)"
assert_eq "#247 generic arm: tr-less unknown tool → derivation breadcrumb, override not consulted" "yes" \
  "$(printf '%s' "$GEN_ERR" | grep -q 'could not derive the override variable name for \"git\"' && echo yes || echo no)"
assert_eq "#247 generic arm: degenerate breadcrumb names the user-facing override, never the sentinel" "no" \
  "$(printf '%s' "$GEN_ERR" | grep -q '__DEVFLOW_NO_OVERRIDE__' && echo yes || echo no)"

# ── T8 — a converted helper COPIED without lib/ entirely: the call-site `||`
#    fallback fires (breadcrumb + bare jq) and the helper still honors its
#    best-effort exit-0 contract. ──
DJQ_ROOT="$(cd "$LIB/.." && pwd)"
JQT8="$(mktemp -d)"
mkdir -p "$JQT8/scripts"
cp "$DJQ_ROOT/scripts/detect-project-tools.sh" "$JQT8/scripts/"
T8_ERR="$(bash "$JQT8/scripts/detect-project-tools.sh" "$JQT8" 2>&1 >/dev/null)"; T8_RC=$?
assert_eq "#247 T8: helper copied without lib/ → exit 0 (best-effort contract survives the missing resolver)" "0" "$T8_RC"
assert_eq "#247 T8: helper copied without lib/ → call-site fallback breadcrumb fires" "yes" \
  "$(printf '%s' "$T8_ERR" | grep -q 'resolve-jq.sh could not be sourced' && echo yes || echo no)"

# ── T9 — install.sh inline adaptation, defect reproduction: a bad-shebang jq
#    shim (no jq.exe, no override) with a working python3 routes
#    set_config_version to the python3 arm and still pins the version. ──
SCVJ="$(mktemp -d)"
printf '#!/nonexistent/devflow-test-interpreter\necho nope\n' > "$SCVJ/jq"; chmod +x "$SCVJ/jq"
_mk_restricted "$SCVJ" bash python3 mktemp mv cat grep tr dirname rm
printf '{\n  "docs": {}\n}\n' > "$SCVJ/config.json"
_SCV_BASH_BIN="$(command -v bash)"
env -u DEVFLOW_JQ PATH="$SCVJ" "$_SCV_BASH_BIN" -c "DEVFLOW_SELFTEST=1 . \"$DJQ_ROOT/install.sh\" && set_config_version \"$SCVJ/config.json\" abc1234" >/dev/null 2>&1
assert_eq "#247 T9: bad-shebang jq + working python3 → python3 arm pins devflow_version" "yes" \
  "$(grep -q '"devflow_version": "abc1234"' "$SCVJ/config.json" && echo yes || echo no)"

# ── T9b — install.sh, broken explicit DEVFLOW_JQ override: the warning
#    breadcrumb fires AND the python3 arm still pins the version (the one
#    deliberately-divergent contract in the family — pinned so a future
#    "unify with the shared resolver" edit goes RED). ──
SCVO="$(mktemp -d)"
_mk_restricted "$SCVO" bash python3 mktemp mv cat grep tr dirname rm
printf '{\n  "docs": {}\n}\n' > "$SCVO/config.json"
printf '#!/nonexistent/devflow-test-interpreter\necho nope\n' > "$SCVO/broken-jq"; chmod +x "$SCVO/broken-jq"
T9B_ERRLOG="$(DEVFLOW_JQ="$SCVO/broken-jq" PATH="$SCVO" "$_SCV_BASH_BIN" -c "DEVFLOW_SELFTEST=1 . \"$DJQ_ROOT/install.sh\" && set_config_version \"$SCVO/config.json\" beef1234" 2>&1)"
assert_eq "#247 T9b: broken DEVFLOW_JQ override → warning breadcrumb names the override" "yes" \
  "$(printf '%s' "$T9B_ERRLOG" | grep -q "DEVFLOW_JQ is set to .*broken-jq.* but it does not execute" && echo yes || echo no)"
assert_eq "#247 T9b: broken DEVFLOW_JQ override → python3 arm still pins devflow_version" "yes" \
  "$(grep -q '"devflow_version": "beef1234"' "$SCVO/config.json" && echo yes || echo no)"

# ── Preflight, broken DEVFLOW_JQ override: the re-probe catches it and the
#    shim-branch remedy names the resolved value (mirrors #245 AC5b). ──
PF_JQO_OUT="$(DEVFLOW_JQ="$SCVO/broken-jq" bash "$LIB/preflight.sh" 2>&1)"; PF_JQO_RC=$?
assert_eq "#247 preflight: broken DEVFLOW_JQ override → exit non-zero (re-probe catches it)" "yes" \
  "$([ "$PF_JQO_RC" -ne 0 ] && echo yes || echo no)"
assert_eq "#247 preflight: broken DEVFLOW_JQ override → remedy names the resolved binary" "yes" \
  "$(printf '%s' "$PF_JQO_OUT" | grep -q "no working 'jq'.*broken-jq" && echo yes || echo no)"

# ── Preflight partial copy (no resolve-bin.sh beside it): degrades with an
#    attributable breadcrumb and bare-name resolution — never the phantom
#    "the resolved '' does not execute" misdiagnosis. ──
PFPC="$(mktemp -d)"
cp "$LIB/preflight.sh" "$LIB/resolve-python.sh" "$LIB/resolve-gh.sh" "$LIB/resolve-jq.sh" "$PFPC/"
PF_PC_OUT="$(env -u DEVFLOW_JQ -u DEVFLOW_GH bash "$PFPC/preflight.sh" 2>&1)"; PF_PC_RC=$?
assert_eq "#247 preflight partial copy: attributable resolve-bin.sh breadcrumb emitted" "yes" \
  "$(printf '%s' "$PF_PC_OUT" | grep -q 'resolve-bin.sh missing or not sourceable beside preflight.sh' && echo yes || echo no)"
assert_eq "#247 preflight partial copy: bare-name degradation still verifies real tools (exit 0 on a healthy host)" "0" "$PF_PC_RC"
# Override-first degradation: with a WORKING override set and a broken bare jq
# unavailable-to-matter, the degraded preflight must probe the OVERRIDE (the
# value the helpers USE), not the bare name — DETECT/USE parity survives the
# partial copy. Probe with a broken override: preflight must fail and name it.
PF_PC_OVR="$(DEVFLOW_JQ="$SCVO/broken-jq" env -u DEVFLOW_GH bash "$PFPC/preflight.sh" 2>&1)"; PF_PC_OVR_RC=$?
assert_eq "#247 preflight partial copy: degraded mode still honors DEVFLOW_JQ (broken override → non-zero)" "yes" \
  "$([ "$PF_PC_OVR_RC" -ne 0 ] && echo yes || echo no)"
assert_eq "#247 preflight partial copy: degraded remedy names the override value" "yes" \
  "$(printf '%s' "$PF_PC_OVR" | grep -q "no working 'jq'.*broken-jq" && echo yes || echo no)"

# ── T5d — BEHAVIORAL lockstep: extract the first SKILL.md inline block, run it
#    under the same stubbed env as the lib helper, and assert identical output
#    (the regex pin above catches detection-line drift; this catches
#    translation-body drift between lib and the mirrors). ──
T5D="$(mktemp -d)"
printf '#!/usr/bin/env bash\necho "5.15.0-microsoft-standard-WSL2"\n' > "$T5D/uname"; chmod +x "$T5D/uname"
_mk_restricted "$T5D" bash tr grep dirname
awk '
  /# Windows-form anchor normalization/ { n++; if (n==1) on=1 }
  on { line=$0; sub(/^[[:space:]]*/, "", line); print line
       if (u && line == "fi") { on=0 }
       if (line ~ /^unset _d _np _r$/) u=1 }
' "$CI_SKILL" > "$T5D/block.sh"
printf 'SKILL_DIR='"'"'C:\\Users\\dev\\skills\\x'"'"'\n%s\nprintf %%s "$SKILL_DIR"\n' "$(cat "$T5D/block.sh")" > "$T5D/runner.sh"
T5D_SKILL="$(env -u MSYSTEM PATH="$T5D" "$_NP_BASH_BIN" "$T5D/runner.sh" 2>/dev/null)"
T5D_LIB="$(env -u MSYSTEM PATH="$T5D" "$_NP_BASH_BIN" -c ". \"$NORMALIZE_PATH_SH\"; devflow_normalize_path 'C:\\Users\\dev\\skills\\x'" 2>/dev/null)"
assert_eq "#247 T5d: SKILL.md inline block and lib helper translate identically (behavioral lockstep)" "$T5D_LIB" "$T5D_SKILL"
assert_eq "#247 T5d: behavioral lockstep output is the expected WSL form" "/mnt/c/Users/dev/skills/x" "$T5D_LIB"
# Same parity through the MSYS arm (non-microsoft uname + MSYSTEM set), so a
# mirror-only edit to the /c translation cannot ship green either.
T5DM="$(mktemp -d)"
printf '#!/usr/bin/env bash\necho "generic-kernel"\n' > "$T5DM/uname"; chmod +x "$T5DM/uname"
_mk_restricted "$T5DM" bash tr grep dirname
T5DM_SKILL="$(MSYSTEM=MINGW64 PATH="$T5DM" "$_NP_BASH_BIN" "$T5D/runner.sh" 2>/dev/null)"
T5DM_LIB="$(MSYSTEM=MINGW64 PATH="$T5DM" "$_NP_BASH_BIN" -c ". \"$NORMALIZE_PATH_SH\"; devflow_normalize_path 'C:\\Users\\dev\\skills\\x'" 2>/dev/null)"
assert_eq "#247 T5d-msys: SKILL.md block and lib helper agree on the MSYS arm too" "$T5DM_LIB" "$T5DM_SKILL"
assert_eq "#247 T5d-msys: MSYS-arm parity output is the expected /c form" "/c/Users/dev/skills/x" "$T5DM_LIB"
# tr-less parity (the T4k fail-closed branch, SKILL side — runner.sh exists here):
T4K_SKILL="$(env -u MSYSTEM PATH="$NPT4K" "$_NP_BASH_BIN" "$T5D/runner.sh" 2>/dev/null)"
assert_eq "#247 T4k: SKILL.md block also leaves the anchor unchanged without tr (lockstep)" 'C:\Users\dev\skills\x' "$T4K_SKILL"

# ── Lockstep pin — the Windows-form detection regex literal must appear in
#    BOTH lib/normalize-path.sh and the create-issue SKILL.md mirrors, so a
#    translation-logic edit to either side alone goes RED (T5c pins the two
#    in-file mirrors to each other; this pins the lib↔SKILL pair). ──
assert_eq "#247 lockstep: detection regex literal present in lib/normalize-path.sh" "yes" \
  "$(grep -qF '=~ ^[A-Za-z]:[\\/] ]]' "$NORMALIZE_PATH_SH" && echo yes || echo no)"
assert_eq "#247 lockstep: detection regex literal present at both SKILL.md sites" "yes" \
  "$([ "$(grep -cF '=~ ^[A-Za-z]:[\\/] ]]' "$CI_SKILL" 2>/dev/null)" -ge 2 ] && echo yes || echo no)"  # raw-guard-ok: count-based (both coupled SKILL_DIR sites)

# ── Coupled-relay pin — skills/init/SKILL.md relays the jq-gate breadcrumbs of
#    the provision/detect/scaffold helpers; the literal must track the helpers'
#    actual wording (the pre-#247 'jq not found' relay went stale silently). ──
INIT_SKILL="$LIB/../skills/init/SKILL.md"
assert_eq "#247 init relay: init SKILL.md relays the current 'no usable jq' breadcrumb at all three sites" "yes" \
  "$([ "$(grep -c 'no usable jq (missing or not executable)' "$INIT_SKILL" 2>/dev/null)" -ge 3 ] && echo yes || echo no)"  # raw-guard-ok: count-based (three relay sites)
assert_eq "#247 init relay: no stale 'jq not found' relay survives in init SKILL.md" "0" \
  "$(grep -c 'jq not found' "$INIT_SKILL" || true)"  # raw-guard-ok: count-based (absence pin)

# ── Peer-completeness pins (2.3.0a) — every in-scope jq-calling helper sources
#    the shared resolver, and no bare invocation-position `jq` survives outside
#    it. Best-effort grep, mirroring the #245 DGH_BARE discipline: comment lines
#    and diagnostic echo/printf lines are excluded; T6 is the dynamic backstop.
#    scripts/authorize-actor.sh is deliberately out of scope — its `--jq` is a
#    flag of `gh api`, not a jq-binary invocation. ──
DJQ_ROOT="$(cd "$LIB/.." && pwd)"
# 16 = 12 migrated jq-callers (7 lib + 5 scripts) + preflight.sh + resolve-gh.sh
# (both reference the shared resolver) + install.sh (inline mirror — it must run
# standalone before any checkout exists, so it carries the contract by reference
# comment rather than a source line; the DJQ_BARE grep below is what holds its
# call sites to the converted form) + scripts/run-jq.sh (issue #253 — the
# agent-tier jq wrapper skill bodies invoke by path; it sources resolve-jq.sh
# exactly as the .sh helpers do).
DJQ_SOURCED="$(grep -rlE 'resolve-(jq|bin)\.sh' "$DJQ_ROOT/scripts" "$DJQ_ROOT/lib" "$DJQ_ROOT/install.sh" --include='*.sh' 2>/dev/null | grep -v '/test/' | grep -v 'lib/resolve-bin\.sh$' | grep -v 'lib/resolve-jq\.sh$' | grep -c . || true)"
assert_eq "#247 peer-completeness: >=16 helpers reference the shared resolver (all jq-callers + resolve-gh.sh + run-jq.sh converted)" "yes" \
  "$([ "$DJQ_SOURCED" -ge 16 ] && echo yes || echo no)"
# Exclusions are deliberately MINIMAL (a blanket echo/printf line-exclusion
# would mask the repo's dominant `printf ... | jq -r` idiom): full-line
# comments, the resolver's own file, and `--version` probe lines (`<cand>
# --version` IS the resolver mechanism — install.sh's inline adaptation and
# the preflight re-probe — never a data-processing call site; the exclusion
# is anchored to the probe shape `jq(.exe)? --version`, not a whole-line
# --version filter that a filter-string mention would ride). The suffix
# alternation covers flag/quoted-program/path forms AND common bareword
# filters (empty/length/keys/type/to_entries) so `jq empty <<<"$x"`-style
# reintroductions go RED too.
DJQ_BARE="$(grep -rnE '(^|[[:space:]|&;(`])jq[[:space:]]+(-|'"'"'|"|\.|empty|length|keys|type|to_entries)' \
  "$DJQ_ROOT/scripts" "$DJQ_ROOT/lib" "$DJQ_ROOT/install.sh" --include='*.sh' 2>/dev/null \
  | grep -v '/test/' | grep -v 'resolve-bin\.sh:' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -vE 'jq(\.exe)? --version' | grep -c . || true)"
assert_eq "#247 peer-completeness: no bare invocation-position jq call survives outside the resolver" "0" "$DJQ_BARE"

# ── Skills-tier jq pin (issue #253, widened by #271) — the DJQ_BARE grep above
#    is scoped to *.sh and never sees skill bodies, so agent-composed `jq` inside
#    SKILL.md fenced blocks was invisible to the #247 contract. On a shim-shadowed
#    Windows/WSL host a bare agent-typed `jq` hits the same present-but-
#    unrunnable-shim defect #247 fixed for the helpers. This pin holds every
#    executable jq in EVERY skill body to the agent-tier wrapper
#    scripts/run-jq.sh (which sources the shared resolver — DEVFLOW_JQ is not
#    exported to agent shells, so a callable-by-path wrapper is the agent-tier
#    equivalent of the .sh source-once idiom).
#    SCOPE — all skill bodies. #253 originally scoped this to the retrospective
#    family (the LOCAL weekly loop); #271 migrated the remaining cloud-governed
#    executable jq sites (skills/implement/SKILL.md, phases/phase-4-documentation.md,
#    docs-release-notes/SKILL.md) to the wrapper and added the wrapper to the cloud
#    allowlist in .github/workflows/devflow-implement.yml + devflow-runner.yml +
#    devflow.yml, so they are now IN scope: the find below no longer restricts to
#    *retrospective*.
#    (The skills/review/SKILL.md trace example is in INLINE-backtick prose (now
#    `run-jq.sh -n`), not a shell fence, so it is outside this awk-fence pin's reach —
#    #271 migrated it too; its regression guard is the dedicated review-site pin below,
#    and its cloud grant is the coupled allowlist edit, not this awk-fence pin.)
#    Fence scope: lines inside ```bash / ```sh / ```shell fences only, so
#    inline-backtick prose mentions of `jq -n` and non-shell (```json / ```dot /
#    output) fences never false-match. ──
# Positive pin: the wrapper exists and references the shared jq resolver.
assert_eq "#253 skills-jq: scripts/run-jq.sh exists and references the shared jq resolver" "yes" \
  "$([ -f "$LIB/../scripts/run-jq.sh" ] && grep -q 'resolve-jq\.sh' "$LIB/../scripts/run-jq.sh" && echo yes || echo no)"
# The wrapper's whole purpose is a cloud-tier by-path leading-token invocation
# (`.devflow/vendor/devflow/scripts/run-jq.sh …`), which requires the COMMITTED
# file to carry the executable bit — a dropped bit silently breaks the cloud
# invocation with no other failing test (the coverage above runs it via `bash
# "$RJQ_SH"`, which does not exercise the bit). Pin the git INDEX mode (what
# ships), not the working-tree `-x` (which reflects local perms), mirroring the
# comparable by-path helper lib/efficiency-trace.sh. (PR #274 review, Important.)
assert_eq "#253 skills-jq: scripts/run-jq.sh is committed executable (100755)" "100755" \
  "$(cd "$LIB/.." && git ls-files -s scripts/run-jq.sh | awk '{print $1}')"
# Absence pin: no bare invocation-position jq survives inside a shell fenced
# block of ANY skill body. The awk captures only ```bash/```sh/
# ```shell block bodies (state reset per file); the grep shape mirrors DJQ_BARE
# (flag/quoted-program/path/bareword-filter forms), excluding the resolver's own
# `--version` probe shape and the wrapper path itself.
SKILL_JQ_BARE="$(
  find "$LIB/../skills" -type f -name '*.md' 2>/dev/null | while IFS= read -r _f; do
    awk '
      /^[[:space:]]*```(bash|sh|shell)[[:space:]]*$/ { inb=1; next }
      /^[[:space:]]*```[[:space:]]*$/ { inb=0; next }
      inb { print }
    ' "$_f"
  done \
  | grep -v 'run-jq\.sh' \
  | grep -E '(^|[[:space:]|&;(`])jq[[:space:]]+(-|'"'"'|"|\.|empty|length|keys|type|to_entries)' \
  | grep -vE 'jq(\.exe)? --version' | grep -c . || true)"
assert_eq "#253 skills-jq: no bare invocation-position jq survives in any skill shell fenced block" "0" "$SKILL_JQ_BARE"

# ── #271 coupled-invariant pins: the skill-body run-jq.sh migration is one half of a
#    two-sided contract — the cloud-governed skills invoke the wrapper BY PATH as the
#    command's leading token (`.devflow/vendor/devflow/scripts/run-jq.sh`), which the
#    cloud permission profile silently DENIES unless the workflow allowlist grants it
#    (the CLAUDE.md LEADING-token gotcha). Pin the grant at both cloud writer/runner
#    profiles so a dropped/reformatted allowlist entry goes RED here rather than
#    silently no-op'ing the migration in cloud (and because #271 retired the AC11
#    `.github`-freeze, this is now the only guard on this `.github` side of the couple).
IMPL_WF="$LIB/../.github/workflows/devflow-implement.yml"
RUNNER_WF="$LIB/../.github/workflows/devflow-runner.yml"
# devflow.yml is the THIRD governing workflow — the light command listener that
# runs a MANUAL bare `/devflow:review` / `/devflow:review-and-fix` comment, so it
# also executes the migrated skills/review/SKILL.md Phase 4.5 trace-authoring site
# (`run-jq.sh` by path). Its inline allowlist must grant the wrapper too or the
# by-path head is silently denied on that trigger, dropping the telemetry trace a
# bare `jq -n` previously authored (raised by PR #274 review, Important).
LIGHT_WF="$LIB/../.github/workflows/devflow.yml"
assert_eq "#271 coupled: devflow-implement.yml allowlists the run-jq.sh wrapper by vendored path" "1" \
  "$(grep -cF 'Bash(.devflow/vendor/devflow/scripts/run-jq.sh:*)' "$IMPL_WF" || true)"
assert_eq "#271 coupled: devflow-runner.yml (read-only review profile) allowlists the run-jq.sh wrapper" "1" \
  "$(grep -cF 'Bash(.devflow/vendor/devflow/scripts/run-jq.sh:*)' "$RUNNER_WF" || true)"
assert_eq "#271 coupled: devflow.yml (manual-comment review listener) allowlists the run-jq.sh wrapper" "1" \
  "$(grep -cF 'Bash(.devflow/vendor/devflow/scripts/run-jq.sh:*)' "$LIGHT_WF" || true)"
# The skills/review/SKILL.md trace-authoring example sits in INLINE-backtick prose, so the
# awk-fence absence pin above cannot reach it — pin it directly so a revert of that site to
# a bare `jq -n` goes RED (it is one of the four #271-migrated sites and would otherwise have
# no regression guard). Target-unique: `--argjson findings` follows run-jq.sh only in the
# trace example, so assert_pin_unique proves PASS-with-the-literal → FAIL-without-it.
assert_pin_unique "#271 coupled: skills/review/SKILL.md trace example invokes the run-jq.sh wrapper (not bare jq -n)" \
  'scripts/run-jq.sh -n --argjson findings' "$LIB/../skills/review/SKILL.md"
# The implement/SKILL.md reaction-comment read and the phase-4 deferrals merge are
# fenced-block sites covered by the awk absence pin above, but that pin is *negative*
# only — it goes RED on a reintroduced BARE jq, yet stays GREEN if the site is
# refactored away from jq entirely (deleting the migrated wrapper call with it),
# silently dropping the migration at that site with no failing test. Pin each
# positively so a removal/refactor of the wrapper call goes RED too (PR #274 review,
# Suggestion — parity with the review/docs-release-notes sites' positive guards).
# Target-unique substrings: `run-jq.sh -r '.comment.id` occurs only at the reaction
# read; `run-jq.sh -s '.[0] as $f` only at the phase-4 merge.
assert_pin_unique "#271 coupled: skills/implement/SKILL.md reaction-comment read invokes the run-jq.sh wrapper" \
  "scripts/run-jq.sh -r '.comment.id" "$LIB/../skills/implement/SKILL.md"
assert_pin_unique "#271 coupled: phase-4-documentation.md deferrals merge invokes the run-jq.sh wrapper" \
  "scripts/run-jq.sh -s '.[0] as \$f" "$LIB/../skills/implement/phases/phase-4-documentation.md"

# Mutation check: the absence pin above only proves "count is 0 today" — it does not
# prove the awk fence-parser + grep would actually *catch* a reintroduced bare jq (a
# silently-broken fence regex would also read 0 and stay GREEN). Run the identical
# pipeline against a synthetic fixture carrying one bare `jq` call inside a ```bash
# fence and assert the count flips to nonzero, proving the guard fails closed.
SKILL_JQ_BARE_FIXTURE_DIR="$(mktemp -d)"
cat > "$SKILL_JQ_BARE_FIXTURE_DIR/fixture.md" <<'EOF'
# Fixture

```bash
echo hi
jq -r '.x' <<< "$INPUT"
```
EOF
SKILL_JQ_BARE_MUTATED="$(
  find "$SKILL_JQ_BARE_FIXTURE_DIR" -type f -name '*.md' 2>/dev/null | while IFS= read -r _f; do
    awk '
      /^[[:space:]]*```(bash|sh|shell)[[:space:]]*$/ { inb=1; next }
      /^[[:space:]]*```[[:space:]]*$/ { inb=0; next }
      inb { print }
    ' "$_f"
  done \
  | grep -v 'run-jq\.sh' \
  | grep -E '(^|[[:space:]|&;(`])jq[[:space:]]+(-|'"'"'|"|\.|empty|length|keys|type|to_entries)' \
  | grep -vE 'jq(\.exe)? --version' | grep -c . || true)"
assert_eq "#253 skills-jq mutation check: awk fence-parser catches a reintroduced bare jq (guard fails closed, not vacuous)" "1" "$SKILL_JQ_BARE_MUTATED"
rm -rf "$SKILL_JQ_BARE_FIXTURE_DIR"

# ── #253 run-jq.sh behavioral coverage — the wrapper carries logic the #247
#    resolver tests don't reach (pure-bash BASH_SOURCE dir derivation, the
#    source-guard, the partial-deploy fallback, DEVFLOW_JQ honoring on that
#    fallback, and exec stdin/args/exit passthrough). Static existence-pinning
#    alone would stay GREEN if any of those regressed, so exercise them. Stub
#    jq (echoes a marker + its args, then cats stdin) proves the wrapper reached
#    it with args and stdin intact; the DEVFLOW_JQ override is honored without a
#    probe, so these stay hermetic (no real jq needed). ──
RJQ_SH="$DJQ_ROOT/scripts/run-jq.sh"
RJQ_STUB="$(mktemp -d)"
printf '#!/usr/bin/env bash\nprintf "STUBJQ:%%s\\n" "$*"\ncat\n' > "$RJQ_STUB/jq"; chmod +x "$RJQ_STUB/jq"
# (a) DEVFLOW_JQ override honored (no probe) + args + stdin pass through exec.
RJQ_OUT="$(printf 'STDIN_MARK\n' | DEVFLOW_JQ="$RJQ_STUB/jq" bash "$RJQ_SH" -r '.x')"
assert_eq "#253 run-jq.sh: DEVFLOW_JQ override honored, args + stdin pass through exec" "yes" \
  "$(printf '%s' "$RJQ_OUT" | grep -q 'STUBJQ:-r .x' && printf '%s' "$RJQ_OUT" | grep -q 'STDIN_MARK' && echo yes || echo no)"
# (b) exec propagates jq's exit code — a stub exiting 7 makes the wrapper exit 7.
printf '#!/usr/bin/env bash\nexit 7\n' > "$RJQ_STUB/jq7"; chmod +x "$RJQ_STUB/jq7"
DEVFLOW_JQ="$RJQ_STUB/jq7" bash "$RJQ_SH" '.' >/dev/null 2>&1; RJQ_RC=$?
assert_eq "#253 run-jq.sh: exec propagates jq's exit code (7), never masks it as 0" "7" "$RJQ_RC"
# (c) partial deploy — scripts/ copied WITHOUT sibling lib/: the source-guard
#     fails, a specific breadcrumb fires, DEVFLOW_JQ is still honored (never an
#     empty invocation), and the best-effort exit-0 contract survives.
RJQ_PARTIAL="$(mktemp -d)"; mkdir -p "$RJQ_PARTIAL/scripts"; cp "$RJQ_SH" "$RJQ_PARTIAL/scripts/"
RJQ_POUT="$(printf 'X\n' | DEVFLOW_JQ="$RJQ_STUB/jq" bash "$RJQ_PARTIAL/scripts/run-jq.sh" -r '.y' 2>"$RJQ_STUB/perr")"; RJQ_PRC=$?
assert_eq "#253 run-jq.sh: partial deploy (no sibling lib/) still honors DEVFLOW_JQ, no empty exec" "yes" \
  "$(printf '%s' "$RJQ_POUT" | grep -q 'STUBJQ:-r .y' && echo yes || echo no)"
assert_eq "#253 run-jq.sh: partial deploy emits the specific 'could not source lib/resolve-jq.sh' breadcrumb" "yes" \
  "$(grep -q 'could not source lib/resolve-jq.sh beside it' "$RJQ_STUB/perr" && echo yes || echo no)"
assert_eq "#253 run-jq.sh: partial deploy preserves the best-effort exit-0 contract" "0" "$RJQ_PRC"

rm -rf "$JQT0" "$JQT1" "$JQT2" "$JQT2D" "$JQTD" "$NPT4" "$NPT4B" "$NPT4C" "$NPT4D" "$NPT4E" "$NPT4G" "$NPT4I" "$JQTP" "$JQT10" "$JQT6" "$JQT7" "$JQT8" "$SCVJ" "$SCVO" "$PFPC" "$T5D" "$T5DM" "$JQT7D" "$JQNEG" "$GENTR" "$RJQ_STUB" "$RJQ_PARTIAL"

# ────────────────────────────────────────────────────────────────────────────
echo "running-bash diagnostic: preflight.sh devflow-bash breadcrumb + remedy (issue #248)"
# ────────────────────────────────────────────────────────────────────────────
# preflight.sh emits a `devflow-bash:` breadcrumb naming the POSIX bash its .sh
# helpers run under (interpreter path + $BASH_VERSION) and surfaces DEVFLOW_BASH
# when it is set, so a user can confirm the intended bash took effect. When it is
# NOT running under a POSIX bash (empty $BASH_VERSION under sh/dash) it prints a
# remedy naming WSL/Git Bash/MSYS2 bash + the DEVFLOW_BASH override and exits
# non-zero BEFORE the first bash-only construct (`${BASH_SOURCE[0]}`) would abort.
# The breadcrumb goes to stderr; tests capture 2>&1. DEVFLOW_BASH is honored at
# the invocation layer (the agent/runner that shells into bash), NOT selected by
# preflight — so these tests cover the diagnostic, and V1 (the invocation-layer
# behavior) is a documented manual verification, not automatable here.
PF248="$LIB/preflight.sh"

# ── T1 (AC2/AC4): under bash, the breadcrumb names the running bash + the LIVE
#    $BASH_VERSION, the exit-0 contract and byte-identical pass line are unchanged,
#    and an unset DEVFLOW_BASH adds nothing (no-op). Stub PATH + fake python3 so
#    preflight reaches its normal exit 0. ──
T248="$(mktemp -d)"; build_stub_bin "$T248"; make_fake_python "$T248/python3" "3.12.4" 3 12
PF248_OUT="$(PATH="$T248" bash "$PF248" 2>&1)"; PF248_RC=$?
assert_eq "#248 preflight: bash run → exit 0 (AC4 unchanged)" "0" "$PF248_RC"
assert_eq "#248 preflight: emits the devflow-bash breadcrumb naming the running bash (AC2/T1)" "yes" \
  "$(printf '%s' "$PF248_OUT" | grep -q 'devflow-bash: running under bash ' && echo yes || echo no)"
assert_eq "#248 preflight: breadcrumb carries the live \$BASH_VERSION (AC2/T1)" "yes" \
  "$(printf '%s' "$PF248_OUT" | grep -qF "$BASH_VERSION" && echo yes || echo no)"
# Pin the OTHER AC2 breadcrumb component — the interpreter path (${BASH:-unknown}).
# Assert a non-empty path token sits between "running under bash " and " (": a
# regression that dropped ${BASH:-unknown} (reformatting to "running under bash
# ($BASH_VERSION)") leaves "(" immediately after the prefix and goes RED. Pins the
# FIELD's presence without hardcoding the (test-temp, per-run) path value, so it is
# robust rather than fragile. The `unknown` fallback still satisfies it (a present
# field), which is the intended AC2 semantics.
assert_eq "#248 preflight: breadcrumb carries a non-empty interpreter path (AC2/T1)" "yes" \
  "$(printf '%s' "$PF248_OUT" | grep -Eq 'devflow-bash: running under bash [^ (]' && echo yes || echo no)"
assert_eq "#248 preflight: byte-identical pass line still last with the breadcrumb added (AC4)" \
  "devflow preflight: all dependencies present." "$(printf '%s\n' "$PF248_OUT" | tail -1)"
assert_eq "#248 preflight: no DEVFLOW_BASH= in breadcrumb when unset (AC4 no-op)" "no" \
  "$(printf '%s' "$PF248_OUT" | grep -q 'DEVFLOW_BASH=' && echo yes || echo no)"

# ── T2 (AC2 override surfacing): DEVFLOW_BASH set is reflected verbatim in the
#    breadcrumb, and preflight still exits 0. ──
PF248O_OUT="$(DEVFLOW_BASH=/opt/devflow-marker/bash PATH="$T248" bash "$PF248" 2>&1)"; PF248O_RC=$?
assert_eq "#248 preflight: DEVFLOW_BASH set → still exit 0 (AC4)" "0" "$PF248O_RC"
assert_eq "#248 preflight: breadcrumb surfaces the DEVFLOW_BASH value (AC2/T2)" "yes" \
  "$(printf '%s' "$PF248O_OUT" | grep -qF 'DEVFLOW_BASH=/opt/devflow-marker/bash' && echo yes || echo no)"

# ── T2b (AC2/AC4 boundary): a set-but-EMPTY DEVFLOW_BASH is a no-op, exactly like
#    unset — the breadcrumb surfaces no `DEVFLOW_BASH=`. This pins the `[ -n … ]`
#    emptiness guard specifically: a regression swapping it for set-detection
#    (`${DEVFLOW_BASH+set}` / `-v`) would leak an empty `DEVFLOW_BASH=` into the
#    breadcrumb and otherwise ship green. ──
PF248E_OUT="$(DEVFLOW_BASH='' PATH="$T248" bash "$PF248" 2>&1)"; PF248E_RC=$?
assert_eq "#248 preflight: empty DEVFLOW_BASH → still exit 0 (AC4)" "0" "$PF248E_RC"
assert_eq "#248 preflight: empty DEVFLOW_BASH is a no-op — not surfaced (AC2/AC4 boundary)" "no" \
  "$(printf '%s' "$PF248E_OUT" | grep -q 'DEVFLOW_BASH=' && echo yes || echo no)"

# ── T3 (AC3 remedy): under a NON-bash POSIX shell (empty $BASH_VERSION) preflight
#    prints the remedy naming the supported bashes + DEVFLOW_BASH and exits non-zero,
#    BEFORE the bash-only `${BASH_SOURCE[0]}` would abort with a cryptic error.
#    Exercised with a real non-bash sh when one exists (dash/busybox, invoked by
#    absolute path); on a bash-only host the dynamic arm is skipped (recorded, never
#    silently green) and the static pins below still guarantee the remedy strings
#    ship. ──
NONBASH=""
if command -v dash >/dev/null 2>&1; then NONBASH="$(command -v dash)"
elif command -v busybox >/dev/null 2>&1; then NONBASH="$(command -v busybox) sh"
fi
if [ -n "$NONBASH" ]; then
  # shellcheck disable=SC2086  # $NONBASH may be the two words "<path>/busybox sh"
  PF248R_OUT="$($NONBASH "$PF248" 2>&1)"; PF248R_RC=$?
  assert_eq "#248 preflight: non-bash shell → exit non-zero (fail closed, AC3)" "yes" \
    "$([ "$PF248R_RC" -ne 0 ] && echo yes || echo no)"
  assert_eq "#248 preflight: non-bash → 'not running under a POSIX bash' remedy (AC3)" "yes" \
    "$(printf '%s' "$PF248R_OUT" | grep -q 'devflow-bash: not running under a POSIX bash' && echo yes || echo no)"
  assert_eq "#248 preflight: remedy names WSL + Git Bash + MSYS2 (AC3)" "yes" \
    "$(printf '%s' "$PF248R_OUT" | grep -q 'WSL bash' && printf '%s' "$PF248R_OUT" | grep -q 'Git Bash' && printf '%s' "$PF248R_OUT" | grep -q 'MSYS2 bash' && echo yes || echo no)"
  assert_eq "#248 preflight: remedy names the DEVFLOW_BASH override (AC3)" "yes" \
    "$(printf '%s' "$PF248R_OUT" | grep -q 'DEVFLOW_BASH' && echo yes || echo no)"
  assert_eq "#248 preflight: remedy fires BEFORE the bash-only \${BASH_SOURCE[0]} (no array-syntax error leaks)" "no" \
    "$(printf '%s' "$PF248R_OUT" | grep -qi 'bad substitution\|BASH_SOURCE' && echo yes || echo no)"
else
  # No non-bash sh on this host: record an explicit skip so the missing dynamic
  # coverage is visible (never a silent green); the static pins below still fire.
  # Route the recorded PASS through assert_eq (a trivially-true comparison) rather
  # than hand-inlining its tally/print contract, so this site tracks any change to
  # how the helper records a pass.
  assert_eq "#248 preflight: non-bash remedy dynamic arm SKIPPED (no dash/busybox on host) — static pins below cover the remedy strings" "skip" "skip"
fi

# ── Static pins (AC2/AC3/AC7): the breadcrumb + remedy literals ship in the source,
#    so coverage never silently no-ops on a bash-only host. assert_pin_unique doubles
#    as the removal-proof — deleting either pinned line goes RED on every run. ──
assert_pin_unique "#248 pin: devflow-bash breadcrumb literal present in preflight.sh (AC2)" \
  "devflow-bash: running under bash" "$PF248"
assert_pin_unique "#248 pin: non-bash remedy literal present in preflight.sh (AC3)" \
  "devflow-bash: not running under a POSIX bash" "$PF248"
assert_eq "#248 pin: remedy names all three supported bashes + the DEVFLOW_BASH override (AC3)" "yes" \
  "$(grep -q 'WSL bash' "$PF248" && grep -q 'Git Bash' "$PF248" && grep -q 'MSYS2 bash' "$PF248" && grep -q 'DEVFLOW_BASH' "$PF248" && echo yes || echo no)"

rm -rf "$T248"

# ────────────────────────────────────────────────────────────────────────────
echo "#266 cloud /devflow:implement stall backstop"
# ────────────────────────────────────────────────────────────────────────────
# The decision core is extracted into scripts/stall-backstop-decide.sh precisely
# so it is drivable here with stubbed inputs (the YAML step is a thin caller).
# Every branch below is RED against the pre-change state: pre-change the helper
# does not exist, so `bash <missing>` prints nothing to stdout / exits 127 and
# each assert_eq fails. These are behavioral pins over the REAL script, so a
# broken branch in the helper goes RED — no vacuity.
DECIDE_SH266="$REPO_ROOT/scripts/stall-backstop-decide.sh"
decide266() { bash "$DECIDE_SH266" "$@" 2>/dev/null; }
assert_eq "#266 decide: disabled (enabled=false) -> skip" "skip" "$(decide266 false interim 0 2)"
assert_eq "#266 decide: terminal -> noop" "noop" "$(decide266 true terminal 0 2)"
assert_eq "#266 decide: interim under cap -> resume" "resume" "$(decide266 true interim 0 2)"
assert_eq "#266 decide: interim at cap -> fail-exhausted" "fail-exhausted" "$(decide266 true interim 2 2)"
assert_eq "#266 decide: interim cap=0 -> fail-exhausted (no auto-resume)" "fail-exhausted" "$(decide266 true interim 0 0)"
assert_eq "#266 decide: interim mid-cap -> resume" "resume" "$(decide266 true interim 1 2)"
assert_eq "#266 decide: unreadable -> fail-unreadable (fail closed)" "fail-unreadable" "$(decide266 true unreadable 0 2)"
assert_eq "#266 decide: unknown class -> fail-unreadable (fail closed)" "fail-unreadable" "$(decide266 true bogus 0 2)"
assert_eq "#266 decide: unrecognized enabled resolves to enabled (interim -> resume)" "resume" "$(decide266 yes interim 0 2)"
assert_eq "#266 decide: negative cap falls back to default 2 (interim,attempts=1 -> resume)" "resume" "$(decide266 true interim 1 -1)"
assert_eq "#266 decide: non-integer attempts -> 0 (interim,cap=2 -> resume)" "resume" "$(decide266 true interim notanum 2)"
decide266 true interim 0 2 >/dev/null 2>&1
assert_eq "#266 decide: a valid decision exits 0" "0" "$?"

# post-issue-comment.sh best-effort contract (mirrors ensure-label.sh): a bad
# input never aborts — exit 0 + a breadcrumb. DEVFLOW_GH is stubbed so sourcing
# resolve-gh.sh never probes a real gh. RED pre-change (helper absent → rc 127).
POST_SH266="$REPO_ROOT/scripts/post-issue-comment.sh"
POST_RC266_NAN="$(DEVFLOW_GH=true bash "$POST_SH266" notanumber /dev/null >/dev/null 2>&1; echo $?)"
assert_eq "#266 post-issue-comment: non-numeric issue -> exit 0 (best-effort)" "0" "$POST_RC266_NAN"
POST_RC266_NF="$(DEVFLOW_GH=true bash "$POST_SH266" 5 /no/such/body/file >/dev/null 2>&1; echo $?)"
assert_eq "#266 post-issue-comment: missing body file -> exit 0 (best-effort)" "0" "$POST_RC266_NF"
POST_ERR266="$(DEVFLOW_GH=true bash "$POST_SH266" 5 /no/such/body/file 2>&1 >/dev/null)"
assert_eq "#266 post-issue-comment: missing body file leaves a specific breadcrumb" "yes" \
  "$(printf '%s' "$POST_ERR266" | grep -q 'body file not found' && echo yes || echo no)"

# Config keys are a coupled peer set (2.3.0a): example template ↔ schema must
# both carry stall_backstop.{enabled,max_resume_attempts}. Parse structurally so
# a key present in one but not the other goes RED.
CFG266="$(python3 - "$REPO_ROOT" <<'PY' 2>/dev/null || true
import json, sys, pathlib
root = pathlib.Path(sys.argv[1])
ex = json.loads((root / ".devflow/config.example.json").read_text())
sc = json.loads((root / ".devflow/config.schema.json").read_text())
eb = ex.get("devflow_implement", {}).get("stall_backstop", {})
sp = sc["properties"]["devflow_implement"]["properties"].get("stall_backstop", {})
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
assert_eq "#266 config example+schema carry coupled stall_backstop keys (types/defaults/additionalProperties)" "yes" "$CFG266"

# NOTE: the stall-backstop workflow-wiring pins (the step in
# devflow-implement.yml that reads the config keys, calls the decision helper, and
# re-dispatches) are DEFERRED to a follow-up issue: pushing a `.github/workflows/`
# edit needs a token carrying `workflows:write` (the optional DEVFLOW_APP_ID App),
# which #266's run lacked. The reusable primitives below (decision helper, REST
# comment helper, workpad status read, config keys) ship and are fully pinned here;
# the thin workflow caller lands with the follow-up. See the parent issue's Phase 4.0
# follow-up for the exact workflow step + its pins. (The AC11 (#225) `.github`-freeze
# reconciliation this note originally also deferred is no longer pending — #271
# retired that over-broad freeze; see the "AC11 (#225) RETIRED by #271" block above.)

# workpad.py status subcommand is registered (the backstop's status read path).
assert_eq "#266 workpad.py: status subcommand registered (func=cmd_status)" "yes" \
  "$(grep -q 'func=cmd_status' "$REPO_ROOT/scripts/workpad.py" && echo yes || echo no)"

# Behavioral: workpad.py status class derivation (mirrors the #222 gh-stub
# pattern at the top of this file). A glyph-set regression (dropping 👎 from the
# terminal tuple, or inverting terminal/interim) would misclassify a healthy
# terminal run as a stall — the CLASS token is fed verbatim to
# stall-backstop-decide.sh — so pin the mapping and the exit-code contract
# behaviorally, not just the argparse registration. RED pre-change: the `status`
# subcommand didn't exist, so the glyph assertions get argparse's empty stdout.
WP266_GHD="$(mktemp -d)"
cat > "$WP266_GHD/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"repo view"*) echo "acme/example-repo" ;;
  *"comments"*) if [ -n "${STUB_COMMENTS:-}" ]; then printf '%s\n' "$STUB_COMMENTS"; else echo '[]'; fi ;;
  *) echo '[]' ;;
esac
STUB
chmod +x "$WP266_GHD/gh"
WP266_PY="$REPO_ROOT/scripts/workpad.py"
WP266_OUT="$(PATH="$WP266_GHD:$PATH" STUB_COMMENTS='[{"id":1,"body":"<!-- devflow:workpad -->\n**Status:** 🎉 Complete"}]' python3 "$WP266_PY" status 5 2>/dev/null)"
assert_eq "#266 workpad.py status: Complete -> 'terminal 🎉 Complete'" "terminal 🎉 Complete" "$WP266_OUT"
WP266_OUT="$(PATH="$WP266_GHD:$PATH" STUB_COMMENTS='[{"id":1,"body":"<!-- devflow:workpad -->\n**Status:** 👎 Blocked"}]' python3 "$WP266_PY" status 5 2>/dev/null)"
assert_eq "#266 workpad.py status: Blocked -> 'terminal 👎 Blocked'" "terminal 👎 Blocked" "$WP266_OUT"
WP266_OUT="$(PATH="$WP266_GHD:$PATH" STUB_COMMENTS='[{"id":1,"body":"<!-- devflow:workpad -->\n**Status:** 🚀 Reviewing"}]' python3 "$WP266_PY" status 5 2>/dev/null)"
assert_eq "#266 workpad.py status: Reviewing -> 'interim 🚀 Reviewing'" "interim 🚀 Reviewing" "$WP266_OUT"
PATH="$WP266_GHD:$PATH" STUB_COMMENTS='[]' python3 "$WP266_PY" status 5 >/dev/null 2>&1
assert_eq "#266 workpad.py status: no workpad -> exit 2" "2" "$?"
PATH="$WP266_GHD:$PATH" STUB_COMMENTS='[{"id":1,"body":"<!-- devflow:workpad -->\nno status line here"}]' python3 "$WP266_PY" status 5 >/dev/null 2>&1
assert_eq "#266 workpad.py status: present but unreadable Status -> exit 1" "1" "$?"
rm -rf "$WP266_GHD"

# Tally the shell assertions from the results file (authoritative — includes the
# subshell blocks). The python section below adds its own counts on top.
PASS=$(grep -c '^PASS$' "$RESULTS_FILE" || true)
FAIL=$(grep -c '^FAIL$' "$RESULTS_FILE" || true)

# ────────────────────────────────────────────────────────────────────────────
echo "python scripts (workpad._apply_mutations, parse_acs._is_post_merge)"
# ────────────────────────────────────────────────────────────────────────────
PY_OUT="$(python3 "$(dirname "$0")/test_python_scripts.py" 2>&1)"
PY_RC=$?
PY_SUMMARY="$(echo "$PY_OUT" | awk '/passed,/ { p=$1; f=$3 } END { print p" "f }')"
PY_PASS="$(echo "$PY_SUMMARY" | awk '{ print $1 }')"
PY_FAIL="$(echo "$PY_SUMMARY" | awk '{ print $2 }')"
[ -n "$PY_PASS" ] && PASS=$((PASS + PY_PASS))
if [ "$PY_RC" -eq 0 ] && [ -n "$PY_PASS" ]; then
  printf '  PASS  %s python assertions\n' "$PY_PASS"
else
  FAIL=$((FAIL + ${PY_FAIL:-1}))
  echo "$PY_OUT" | sed 's/^/    /'
fi

# ────────────────────────────────────────────────────────────────────────────
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
