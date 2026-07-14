#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# efficiency-trace.sh — render the /devflow:review-and-fix per-run subagent
# effectiveness trace (Markdown) or the per-run JSON record from a run's
# per-iteration workpads, AND deterministically persist those artifacts. All
# derivation lives in lib/efficiency-trace.jq; this wrapper validates inputs,
# reads the gating config, and dispatches jq.
#
# Usage:
#   bash lib/efficiency-trace.sh --workpad-dir DIR --slug SLUG --mode {trace|record}
#   bash lib/efficiency-trace.sh --self-check --workpad-dir DIR --slug SLUG
#   bash lib/efficiency-trace.sh --persist [--workpad-dir DIR --slug SLUG]
#
# Args:
#   --workpad-dir DIR   directory holding the run's iter-<N>.json workpads
#                       (e.g. .devflow/tmp/review/<slug>/<run-id>/).
#   --slug SLUG         the run slug (pr-<N> or sanitized branch name).
#   --mode trace        emit the rendered Markdown trace to stdout.
#   --mode record       emit the per-run JSON record to stdout.
#   --self-check        Layer 2 backstop: warn (never write, never fail) when a
#                       converged writable run left no iter-*.json workpad or no
#                       persisted effectiveness record. Run-id is the basename of
#                       --workpad-dir. Silent when telemetry is disabled.
#   --persist           Layer 3 backstop: derive the per-run record + the durable
#                       workpad copy from whatever iter-*.json workpads exist on
#                       disk, and persist them to the dedicated telemetry branch
#                       (`telemetry.branch`, default devflow-telemetry) via git
#                       plumbing — it does NOT commit to the current branch and
#                       never touches HEAD or the tracked working tree (#441).
#                       Idempotent: once a run's record is already on the branch,
#                       the tree is unchanged and no new branch commit is made.
#                       With --workpad-dir/--slug it persists just that run;
#                       without them it DISCOVERS every run under
#                       .devflow/tmp/review/<slug>/<run-id>/ and persists each.
#
# Gating: when devflow_review_and_fix.efficiency_telemetry_enabled is false,
# --mode and --self-check emit NOTHING and exit 0, and --persist derives no
# record AND synthesizes no workpad (a synthesized workpad exists only to feed
# the record — issue #381); the durable copy of REAL workpads is not
# telemetry-gated — it runs on every writable run, mirroring the SKILL.md Loop
# Exit split.
#
# Best-effort: a missing dir, zero readable workpads, or an unreadable workpad
# never aborts — every mode degrades gracefully and --persist/--self-check
# always exit 0. The caller (SKILL.md Loop Exit, the Stop hook, the cloud
# wrapper) must itself stay non-fatal.
#
# Environment:
#   DEVFLOW_CONFIG_FILE  override the config path (used by tests).

set -euo pipefail

# jq binary: resolved once via the sourced sibling resolver (issue #247);
# best-effort — a copied/vendored deployment without lib/ falls back to bare
# `jq` with a breadcrumb rather than aborting under set -e.
# shellcheck source=resolve-jq.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resolve-jq.sh" \
  || { echo "devflow: resolve-jq.sh could not be sourced beside ${BASH_SOURCE[0]} — using bare 'jq' (set DEVFLOW_JQ to override)" >&2; : "${DEVFLOW_JQ:=jq}"; }

HERE="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=lib/config-source.sh
. "$HERE/config-source.sh"

# Detached telemetry-branch persistence (issue #441). Sourced beside this script.
# On a copied/vendored deployment missing lib/, sourcing fails; rather than leave
# the devflow_telemetry_* functions UNDEFINED (a later unguarded `$(devflow_telemetry_branch)`
# would then trip `set -e` — the exact abort the best-effort contract forbids), define
# no-op stubs so EVERY consumer degrades uniformly at the source boundary: the branch
# reads return "absent" and the write is a no-op, telemetry is simply not persisted this
# run, and nothing aborts. This is the SOURCE-time signal; do_persist emits a second,
# PERSIST-time breadcrumb (gated on the _DEVFLOW_TELEMETRY_BRANCH_SOURCED sentinel) that
# names the staging root whose artifacts are discarded — the two are complementary, not
# duplicates, and the persist-time one is what tells the operator what was lost.
# shellcheck source=lib/telemetry-branch.sh
. "$HERE/telemetry-branch.sh" || {
  echo "devflow: telemetry-branch.sh could not be sourced beside ${BASH_SOURCE[0]} — --persist cannot reach the telemetry branch this run; using no-op stubs so backstop reads degrade cleanly (best-effort exit-0 preserved)" >&2
  devflow_telemetry_branch()       { printf 'devflow-telemetry\n'; }
  devflow_telemetry_ref()          { printf 'refs/heads/devflow-telemetry\n'; }
  devflow_telemetry_blob_exists()  { return 1; }
  devflow_telemetry_list_blobs()   { return 0; }
  devflow_telemetry_show_blob()    { return 1; }
  devflow_telemetry_persist_tree() { return 0; }
}

WORKPAD_DIR=""
SLUG=""
MODE=""
ACTION=""   # "" → use --mode (trace|record); "persist"; "self-check"

while [ $# -gt 0 ]; do
  case "$1" in
    --workpad-dir) WORKPAD_DIR="$2"; shift 2 ;;
    --slug)        SLUG="$2";        shift 2 ;;
    --mode)        MODE="$2";        shift 2 ;;
    --persist)     ACTION="persist";    shift ;;
    --self-check)  ACTION="self-check"; shift ;;
    *) echo "efficiency-trace.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

# Unsubstituted-placeholder guard, argv half: the phase-3.3 backstop fence
# carries literal `<slug>`/`<run-id>` placeholders the executing agent must
# substitute; run verbatim, they would fabricate a
# `.devflow/tmp/review/<slug>/<run-id>` identity, synthesize the branch's real
# fix commits under it, and the sha exclusion would then lock the
# misattribution in while the new files suppressed the gap reflection — a
# silent, durable corruption. No legitimate slug/run-id/path carries `<` or
# `>`, so refuse them loudly (best-effort exit 0 preserved). This covers the
# ARGV route only; the basename-derived route — a literal `<slug>/<run-id>`
# DIRECTORY reaching discovery mode — is refused by persist_one's twin guard.
# Accepted limitation: a repo checked out under a path that itself contains
# `<`/`>` refuses every targeted invocation here (and discovery refuses each
# dir via persist_one's twin guard) — loudly, exit 0; fail-closed in the safe
# direction for a vanishingly rare layout. Accepted residual: a
# CALLER-side shell redirect (e.g. a verbatim Loop Exit `--mode record >
# "$RECORD"` fence) touches its placeholder-NAMED file before this script
# runs — the guard keeps the file EMPTY (no fabricated content), but cannot
# undo the caller's touch.
case "${WORKPAD_DIR}${SLUG}" in
  *'<'*|*'>'*)
    echo "::warning::efficiency-trace.sh: --workpad-dir/--slug contains an unsubstituted '<placeholder>' (got --workpad-dir '${WORKPAD_DIR}' --slug '${SLUG}'); refusing to run under a placeholder identity — substitute the run's real slug/run-id and rerun" >&2
    exit 0 ;;
esac

# ── Gating flag (on by default). ─────────────────────────────────────────────
ENABLED="$(devflow_conf '.devflow_review_and_fix.efficiency_telemetry_enabled' 'true')"

THRESHOLD="$(devflow_conf '.devflow_review_and_fix.efficiency_cut_candidate_min_dispatch' 3)"
# Guard: a non-numeric / empty operator-supplied value must not make --argjson
# abort jq (and the script under set -e) — fall back to the documented default.
# Also clamp values below the schema's `minimum: 1` (e.g. 0) to the default, so
# the persisted record never carries a value config.schema.json forbids.
case "$THRESHOLD" in
  ''|*[!0-9]*) THRESHOLD=3 ;;
esac
[ "$THRESHOLD" -lt 1 ] && THRESHOLD=3

# ── Derivation helpers (shared by --mode and --persist) ──────────────────────

# Populate the VALID_FILES global with the readable iter-*.json OBJECTS in $1.
# Skips unreadable / non-object files (best-effort), logging a ::warning:: each.
collect_valid_files() {
  local dir="$1" f
  VALID_FILES=()
  if [ -n "$dir" ] && [ -d "$dir" ]; then
    for f in "$dir"/iter-*.json; do
      [ -e "$f" ] || continue                       # no glob match → skip
      # Require a JSON OBJECT, not merely well-formed JSON: the filter indexes the
      # workpad as an object (.phase3_findings etc.), so a valid-but-non-object
      # file (stray array/number/string from a partial write) would crash jq and
      # abort the wrapper under set -e. Skip it instead, honoring best-effort.
      if "$DEVFLOW_JQ" -e 'type == "object"' "$f" >/dev/null 2>&1; then
        VALID_FILES+=("$f")
      else
        echo "::warning::efficiency-trace.sh: skipping unreadable/malformed workpad '$f'" >&2
      fi
    done
  fi
}

# Warn (don't fail) if the collected workpads carry mixed run-level `source`
# values — a run should be single-source (see the long rationale this mirrors).
warn_on_mixed_source() {
  [ "${#VALID_FILES[@]}" -gt 1 ] || return 0
  # No `2>/dev/null`: VALID_FILES already passed the `type == "object"` gate, so
  # this jq cannot fail on malformed input — suppressing its stderr would only hide
  # a genuine jq malfunction. Only a STRING `.source` is a real label; a non-string
  # (array/number/bool from a malformed write) is bucketed as the default, mirroring
  # verdict_for's `== "review"` gate — otherwise its JSON rendering would inflate the
  # distinct count into a false-positive "mixed source" warning.
  if [ "$("$DEVFLOW_JQ" -r 'if (.source | type) == "string" then .source else "review-and-fix" end' "${VALID_FILES[@]}" | sort -u | wc -l)" -gt 1 ]; then
    echo "::warning::efficiency-trace.sh: workpads carry mixed 'source' values; record collapses to the first non-null (a run should be single-source)" >&2
  fi
}

# Compute the config fingerprint (issue #431): a sha256 over the canonicalized
# devflow_review + devflow_review_and_fix config blocks, plus a small map of
# salient key values carried VERBATIM, so a cross-run/experiment analysis can
# attribute each record to the config variant that produced it. Emits a compact
# JSON object `{sha256, partial, salient}` — `partial:true` when only one of the
# two blocks exists (the hash covers what exists) — or the literal `null` when
# python3 or the config is unavailable / neither block exists. Best-effort: it
# NEVER aborts the wrapper (a null fingerprint just means the #431 assembler
# falls back to `git show <merge_sha>:.devflow/config.json` and marks the source).
# Adds NO new command head: python3 is a hard preflight prerequisite and
# config-source.sh (already sourced above) shells to it on every config read. This
# claim is load-bearing, so the body below must stay free of any non-preflight PATH
# tool (`mktemp`, `head`, `tr`, `sed`, …). An earlier revision reached for `mktemp`
# (to capture stderr) and `head` (to truncate it), which both broke that claim AND
# regressed the failure path: on a host without `mktemp` — e.g. the cloud runner,
# where CLAUDE.md records that mktemp writes are blocked — it fell back to the very
# `2>/dev/null` swallow this function exists to avoid, turning a genuine helper
# defect into an invisible null fingerprint on exactly the tier that has it (#431).
compute_config_fingerprint() {
  local cfg="$1" out rc
  # Delegate to the shared scripts/config_fingerprint.py — the SINGLE source of
  # truth this producer and the #431 assembler-reader both use, so their
  # fingerprints are byte-identical by construction (not a hand-kept mirror).
  #
  # config_fingerprint.py fails SOFT (prints `null`, exit 0) for the degradations it can
  # actually SEE — no config file, an unreadable/malformed config, neither block present.
  # It cannot soft-fail a MISSING INTERPRETER: with no python3 the script never executes,
  # so it prints nothing and rc is 127. That is why the two arms below are distinguished
  # rather than both reported as "crashed" — telling an operator whose PATH lacks python3
  # that the *helper* crashed sends them to read a script that never ran (#431 shadow).
  # Either way we degrade to `null` rather than aborting the wrapper under `set -e`
  # (best-effort contract), and the helper's own stderr flows straight to ours — no temp
  # file, no truncation, nothing to clean up — so the real reason lands in the run log.
  if out="$(python3 "$HERE/../scripts/config_fingerprint.py" "$cfg")"; then
    printf '%s\n' "$out"
  else
    rc=$?
    # 127 = not found; 126 = found but NOT EXECUTABLE (a broken Windows/WSL shim, a
    # `noexec` mount, a permissions blip). Both mean the script never ran, so both must
    # take the interpreter arm — routing 126 to the "crashed" arm would send the operator
    # to read a script that never executed, the exact mis-steer this discrimination exists
    # to eliminate, one errno over (#431 delta review).
    case "$rc" in
      126|127)
        printf 'compute_config_fingerprint: python3 not found or not executable (rc=%s) — it is a hard preflight prerequisite (see lib/preflight.sh); degrading to null\n' \
          "$rc" >&2 ;;
      *)
        printf 'compute_config_fingerprint: config_fingerprint.py crashed (rc=%s; its stderr is above) — degrading to null\n' \
          "$rc" >&2 ;;
    esac
    printf 'null\n'
  fi
}

# Run the jq derivation over VALID_FILES for $1 mode ("trace"|"record") and the
# slug $2, to stdout. A fresh GENERATED_AT is stamped per call.
emit_jq() {
  local mode="$1" slug="$2" generated_at config_fingerprint
  generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # Fingerprint the config that produced this run (issue #431). Guard the empty
  # case to a JSON null so --argjson never aborts jq (and the wrapper under set -e).
  config_fingerprint="$(compute_config_fingerprint "$_DEVFLOW_CONFIG")"
  [ -n "$config_fingerprint" ] || config_fingerprint="null"
  # jq -s over zero files yields null, not []; feed an explicit empty array so the
  # filter (which expects an array) degrades to an empty trace / empty record.
  if [ "${#VALID_FILES[@]}" -eq 0 ]; then
    printf '[]\n' | "$DEVFLOW_JQ" --raw-output -f "$HERE/efficiency-trace.jq" \
      --arg mode "$mode" --arg slug "$slug" \
      --arg generated_at "$generated_at" \
      --argjson cut_candidate_min_dispatch "$THRESHOLD" \
      --argjson config_fingerprint "$config_fingerprint"
  else
    "$DEVFLOW_JQ" --raw-output --slurp -f "$HERE/efficiency-trace.jq" \
      --arg mode "$mode" --arg slug "$slug" \
      --arg generated_at "$generated_at" \
      --argjson cut_candidate_min_dispatch "$THRESHOLD" \
      --argjson config_fingerprint "$config_fingerprint" \
      "${VALID_FILES[@]}"
  fi
}

# Repo root (for the .devflow/logs/ destinations and the commit) comes from the
# already-sourced config-source.sh via devflow_repo_root — it caches
# `git rev-parse --show-toplevel || pwd` once, so a non-repo tree falls back to
# cwd and a non-repo commit simply fails best-effort with a breadcrumb.

# Single source of truth for the iter-<N>.json expected field set (issue #170).
# Kept in sync with the iter-<N>.json schema block in skills/review-and-fix/SKILL.md;
# a lib/test/run.sh assertion FAILs if the two diverge. `shadow` is intentionally
# excluded — Step 2.6 appends it later, so it is legitimately absent on iters that
# ran no shadow pass. --self-check warns (best-effort) when any of these is missing
# from a persisted iter workpad. Plain (non-readonly) single-line assignment so the
# run.sh divergence guard can grep `^ITER_EXPECTED_FIELDS=` to extract it.
ITER_EXPECTED_FIELDS="iter started_at fix_commit_sha fix_files loop_role checklist phase3_dispatched diff_profile phase3_findings fix_decisions convergence_inputs cap_drops telemetry"
# The synthesized-record minimal field set (issue #381): what synthesize_iter_workpads
# writes, and what --self-check validates a synthesized:true record against (a
# synthesized record is a recognized degraded class, exempt from the full set above
# but NOT from its own — a truncated synthesized record must still warn).
ITER_SYNTH_EXPECTED_FIELDS="iter fix_commit_sha fix_files loop_role synthesized"
# The synthesized SHADOW-marker minimal field set (issue #426): what
# synthesize_shadow_markers writes into an iter's `shadow` block when the block
# was dropped but promotion evidence survives, and what --self-check validates a
# `shadow_synthesized: true` block against (a recognized degraded class, exempt
# from a real shadow block's full shape but NOT from its own minimal set — a
# truncated synthesized shadow marker must still warn). Plain single-line
# assignment so a run.sh guard can grep `^SHADOW_SYNTH_EXPECTED_FIELDS=`.
SHADOW_SYNTH_EXPECTED_FIELDS="shadow_synthesized promoted_to_iter_next"

# ── Synthesis backstop (Layer 3+): reconstruct a minimal iteration record from
# the branch's fix commits when a run left ZERO iter-*.json (issue #381) ───────
#
# SHARED FIX-COMMIT SUBJECT CONTRACT (coupled two-site invariant — issue #381):
# the fix-commit subject template `fix: address review findings (iteration {N})`
# is WRITTEN by skills/review-and-fix/SKILL.md Step 3 item 6 and PARSED here to
# reconstruct the per-iteration records when the workpads were dropped. Both
# sites must carry the identical literal; lib/test/run.sh pins both and a
# targeted edit to either turns the suite RED. Changing the subject? Edit item 6
# and this selector in the SAME commit.
FIX_COMMIT_SUBJECT_PREFIX="fix: address review findings (iteration"

# Resolve the ref the fix-commit range diffs against (config .base_branch,
# default main). Prefer origin/<base> over the local ref: in this repo's linked-
# worktree flow the local base branch is routinely BEHIND origin (nobody pulls it
# in a worktree), and a stale local base widens base..HEAD to sweep already-merged
# history — misattributing an old merged PR's fix commits to this run. Falls back
# to the local ref (fixtures and offline clones with no origin). Echoes the
# resolved ref, or returns non-zero when neither resolves (fail-closed).
synth_base_ref() {
  local root="$1" base ref
  base="$(devflow_conf '.base_branch' 'main')"
  [ -n "$base" ] || base="main"
  for ref in "origin/$base" "$base"; do
    if git -C "$root" rev-parse --verify --quiet "${ref}^{commit}" >/dev/null 2>&1; then
      printf '%s\n' "$ref"; return 0
    fi
  done
  # Name the tried value on the failure path — "which base was tried" is the
  # one actionable operand, and a present-but-unresolvable value (a typo'd
  # branch, a wrong-type config coerced to a string like "false") must not be
  # misreported as the key being absent.
  echo "::warning::efficiency-trace.sh: neither 'origin/${base}' nor '${base}' resolves to a commit (.base_branch resolved to '${base}' — absent key, typo, wrong-type value, or missing ref)" >&2
  return 1
}

# Validate + emit a fix_commit_sha token (lowercase-hex charset — length
# deliberately unchecked, which is sufficient here: the check exists to keep a
# corrupt string value ("aaa bbb <realsha>", an embedded newline) from smuggling
# whitespace-bearing tokens into the space-delimited exclusion set; space/newline
# both fail the charset class. The producer contract is `git rev-parse HEAD`, so a
# wrong-LENGTH hex token can only weaken the exclusion for an already-corrupt
# workpad, never cause a wrong exclusion of a full-sha match). $1 is the sha,
# $2 the source label used in the not-sha-shaped breadcrumb.
_emit_fix_sha() {
  case "$1" in
    ''|*[!0-9a-f]*) [ -n "$1" ] && echo "::warning::efficiency-trace.sh --persist: fix_commit_sha in ${2} is not sha-shaped; not added to the exclusion set" >&2 ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# Emit every fix_commit_sha already recorded by ANY other run's iter-*.json,
# UNIONED across three sources so a run persisted to the telemetry branch (issue
# #441) stays in the exclusion set and its fix commits are never re-attributed
# (AC12): (1) the live tmp scratch tree, (2) the telemetry branch's durable
# iter-*.json blobs (read via git ls-tree/git show — the branch is where durable
# copies now live), and (3) any legacy tracked working-tree .devflow/logs/review/
# (retained so a consumer's pre-#441 in-tree archive is not dropped). $2 is the
# target run dir's TMP path, excluded from source (1) only — its durable mirror on
# the branch, if a prior persist wrote one, is deliberately NOT excluded (a run
# whose workpads were already persisted reads as already-recorded, which is
# correct). Best-effort: an unreadable/malformed workpad is skipped with a
# breadcrumb (a contained fail-open the breadcrumb makes loud), never truncating
# the rest of the scan.
recorded_fix_shas() {
  local root="$1" skip_dir="$2" f sha_out ref blob_path
  # (1) tmp scratch + (3) legacy tracked working-tree copies.
  for f in "$root"/.devflow/tmp/review/*/*/iter-*.json "$root"/.devflow/logs/review/*/*/iter-*.json; do
    [ -e "$f" ] || continue
    case "$f" in "$skip_dir"/*) continue ;; esac
    if ! sha_out="$("$DEVFLOW_JQ" -r 'if (.fix_commit_sha | type) == "string" then .fix_commit_sha else empty end' "$f" 2>/dev/null)"; then
      echo "::warning::efficiency-trace.sh --persist: could not read fix_commit_sha from ${f} (unreadable or malformed workpad); its sha (if any) cannot be excluded from synthesis" >&2
      continue
    fi
    _emit_fix_sha "$sha_out" "$f"
  done
  # (2) telemetry-branch durable iter-*.json blobs. No `command -v` guard here:
  # the source boundary (top of file) defines no-op stubs when the lib is absent,
  # so devflow_telemetry_* are always callable and list_blobs then yields nothing.
  ref="$(devflow_telemetry_ref)"
  while IFS= read -r blob_path; do
    case "$blob_path" in */iter-*.json) ;; *) continue ;; esac
    if ! sha_out="$(devflow_telemetry_show_blob "$root" "$ref" "$blob_path" | "$DEVFLOW_JQ" -r 'if (.fix_commit_sha | type) == "string" then .fix_commit_sha else empty end' 2>/dev/null)"; then
      echo "::warning::efficiency-trace.sh --persist: could not read fix_commit_sha from ${ref}:${blob_path} (unreadable or malformed telemetry blob); its sha (if any) cannot be excluded from synthesis" >&2
      continue
    fi
    _emit_fix_sha "$sha_out" "${ref}:${blob_path}"
  done < <(devflow_telemetry_list_blobs "$root" "$ref" ".devflow/logs/review/")
  return 0
}

# Reads `sha<TAB>subject` lines (oldest-first) on STDIN — the caller captures
# `git log` output first so a failed log is routed to the rc-3 "never
# established" arm instead of reading as an empty commit list — and emits
# `N<TAB>sha` lines for subjects matching the fix-commit contract, excluding any
# sha in $1 (space-separated already-recorded set). Deterministic, network-free.
# Adversarial subjects each emit an exit-0 stderr breadcrumb and are skipped:
# prefix present but no trailing `)` iteration suffix, a non-numeric iteration
# token, an already-recorded sha, or a duplicate N (first unexcluded occurrence
# wins). Known accepted lenience: `(iteration1)` (missing space) parses as
# iteration 1 — the strip drops at most one optional space. Known limitation:
# iteration numbers restart at 1 per review loop, so a branch carrying TWO
# unrecorded loops keeps only the first loop's commit for each N (duplicate-N
# breadcrumbs name the rest) — acceptable for a minimal floor. Always exits 0.
select_fix_commits() {
  local excl="$1" base_subject sha subj n tab seen_ns=" "
  tab="$(printf '\t')"
  # The fix-loop subject family, derived from the coupled prefix constant (the
  # strip pattern necessarily repeats the constant's ` (iteration` tail — keep
  # the two in lockstep if the subject template is ever reworded): a commit in
  # this family but WITHOUT the `(iteration N)` suffix is breadcrumbed, not
  # silently dropped (issue #381 AC4).
  base_subject="${FIX_COMMIT_SUBJECT_PREFIX% (iteration}"
  # --reverse → oldest-first so a duplicate N keeps the EARLIEST commit.
  while IFS="$tab" read -r sha subj; do
    [ -n "$sha" ] || continue
    case "$subj" in
      "$FIX_COMMIT_SUBJECT_PREFIX"*) ;;          # has the "(iteration" suffix — parse N below
      "$base_subject"*)                           # fix-loop family but no "(iteration N)" suffix
        echo "::warning::efficiency-trace.sh --persist: fix-commit ${sha} is in the fix-loop subject family but has no '(iteration N)' suffix; skipping" >&2; continue ;;
      *) continue ;;                              # unrelated commit — silently skip
    esac
    # Already recorded by another run's workpad (real or previously synthesized,
    # tmp or durable copy) — never re-attribute it to this run (the double-count
    # guard; checked BEFORE duplicate-N dedupe so an excluded commit does not
    # consume its iteration number and shadow this run's own commit with that N).
    case " $excl " in
      *" $sha "*) echo "::warning::efficiency-trace.sh --persist: fix-commit ${sha} is already recorded by another run's iter-*.json workpad; skipping so it is not double-counted" >&2; continue ;;
    esac
    n="${subj#"$FIX_COMMIT_SUBJECT_PREFIX"}"      # -> " N)"
    n="${n# }"                                    # drop one leading space
    case "$n" in
      *")") n="${n%)}" ;;
      *) echo "::warning::efficiency-trace.sh --persist: fix-commit ${sha} matches the fix-subject prefix but does not END with the '(iteration N)' suffix (trailing text after it, or a missing ')'); skipping" >&2; continue ;;
    esac
    case "$n" in
      ''|*[!0-9]*) echo "::warning::efficiency-trace.sh --persist: fix-commit ${sha} has a non-numeric iteration token '${n}'; skipping" >&2; continue ;;
    esac
    # Normalize leading zeros (pure bash — a selection-deciding value must not
    # route through a non-preflight PATH tool): "01" and "1" are the same
    # iteration, so they must collide in the duplicate-N dedupe, and a leading-
    # zero token must never reach `--argjson` (jq builds disagree on leading-zero
    # JSON numbers — acceptance is version-dependent, rejection would be
    # misattributed as a disk write failure).
    while [ "${n#0}" != "$n" ] && [ -n "${n#0}" ]; do n="${n#0}"; done
    case "$seen_ns" in
      *" $n "*) echo "::warning::efficiency-trace.sh --persist: duplicate iteration ${n} (fix-commit ${sha}); keeping the first occurrence, skipping this one" >&2; continue ;;
    esac
    seen_ns="${seen_ns}${n} "
    printf '%s\t%s\n' "$n" "$sha"
  done
  return 0
}

# Synthesize minimal iter-<N>.json workpads into $1 from the branch's fix
# commits (issue #381). Each record carries only iter / fix_commit_sha /
# fix_files / loop_role:"fix" / synthesized:true — a distinct recognized degraded
# class the jq filter and --self-check both ride. The rc is a FOUR-way outcome (0/2/3/4,
# enumerated below) so the caller's breadcrumb never collapses an unestablished measurement
# onto "found none" (the repo's unknown-is-not-zero gotcha): returns 0 iff ≥1 record was
# written; 2 when selection RAN and found no unrecorded matching commit; 3 when
# the search could not run at all (an uncreatable target dir, no base ref
# resolvable, OR the git log enumeration itself failed — either way, whether
# matching commits could be synthesized was never established; the arm-specific
# warning names which); 4 when commits WERE selected but every record write
# failed (per-commit warnings already emitted).
synthesize_iter_workpads() {
  local dir="$1" root="$2" n sha files files_ok base excl log_out jq_err tab attempted=0 wrote=0
  tab="$(printf '\t')"
  # The target dir can be absent on the one shape this floor exists for — a
  # fully-degraded run that never created its tmp dir, reached via the
  # phase-3.3 targeted retry / the breadcrumb-named --workpad-dir escape hatch.
  # Without this, every write below fails ENOENT and the rc-4 arm misreads a
  # missing directory as a disk/write failure.
  if ! mkdir -p "$dir" 2>/dev/null; then
    echo "::warning::efficiency-trace.sh --persist: could not create workpad dir ${dir} (permissions/read-only fs, or on the cloud tier the sandbox's write denial into .devflow/tmp?); cannot synthesize into it" >&2
    return 3
  fi
  if ! base="$(synth_base_ref "$root")"; then
    echo "::warning::efficiency-trace.sh --persist: could not resolve a base branch ref (the warning above names the tried value); cannot select fix commits for synthesis" >&2
    return 3
  fi
  # Capture the log BEFORE parsing, checking its own exit status: a failed
  # `git log` (unborn HEAD, index-lock race, corrupt object store) is "the
  # enumeration never ran" — rc 3, never collapsed onto rc 2's "found none"
  # (the unknown-is-not-zero gotcha, applied to the search itself).
  # Data purity: stderr is discarded, never REDIRECTED into the capture — do
  # not change this to `2>&1`, which would inject a succeeding git advisory
  # (unreadable ~/.config/git, ref warnings) into the parsed commit stream.
  if ! log_out="$(git -C "$root" log --reverse --format="%H${tab}%s" "${base}..HEAD" 2>/dev/null)"; then
    echo "::warning::efficiency-trace.sh --persist: git log ${base}..HEAD failed (rc-checked; its stderr is suppressed to keep the data stream pure — rerun the command manually for detail); whether matching fix commits exist was never established" >&2
    return 3
  fi
  # Join the exclusion set with bash builtins only — it DECIDES which commits are
  # selected, so it must not be derived through a non-preflight PATH tool (the
  # repo's guard-class 2: a missing tool would silently empty the set and re-open
  # the double-count this guard exists to close).
  excl=""
  while IFS= read -r sha; do
    [ -n "$sha" ] && excl="${excl}${sha} "
  done < <(recorded_fix_shas "$root" "$dir")
  while IFS="$tab" read -r n sha; do
    [ -n "$n" ] && [ -n "$sha" ] || continue
    attempted=$((attempted + 1))
    # Guard the fix_files derivation: a failed diff-tree must record
    # fix_files: null (unestablished — distinguishable from a genuine
    # empty/--allow-empty commit's []) with a breadcrumb, never a silent
    # fabricated "this commit touched no files".
    files_ok=1
    if ! files="$(git -C "$root" diff-tree --no-commit-id --name-only -r "$sha" 2>/dev/null)"; then
      echo "::warning::efficiency-trace.sh --persist: could not derive fix_files for ${sha} (git diff-tree failed; stderr suppressed to keep the data stream pure); recording fix_files as null (unestablished)" >&2
      files_ok=0
      files=""
    fi
    # stdout goes to the record file, so stderr is free to capture — unlike the
    # git log/diff-tree data streams above, keeping the failure CAUSE
    # (ENOENT/EACCES/ENOSPC/argjson rejection) costs no data purity here.
    if jq_err="$("$DEVFLOW_JQ" -n --argjson iter "$n" --arg sha "$sha" --arg files "$files" --arg files_ok "$files_ok" \
         '{iter: $iter, fix_commit_sha: $sha,
           fix_files: (if $files_ok == "1" then ($files | split("\n") | map(select(length > 0))) else null end),
           loop_role: "fix", synthesized: true}' 2>&1 > "$dir/iter-$n.json")"; then
      wrote=$((wrote + 1))
    else
      echo "::warning::efficiency-trace.sh --persist: failed to write synthesized iter-${n}.json for ${sha} (${jq_err:-no error text}); skipping" >&2
      rm -f "$dir/iter-$n.json" 2>/dev/null
    fi
  done < <(printf '%s\n' "$log_out" | select_fix_commits "$excl")
  # (printf-pipe, not a heredoc: bash <5.1 heredocs — and over-pipe-buffer ones
  # on newer bash — materialize a temp file, so a denied-TMPDIR host could
  # collapse an already-captured commit list onto the rc-2 "found none" arm —
  # the builtin pipe has no such failure channel.)
  [ "$wrote" -gt 0 ] && return 0
  [ "$attempted" -gt 0 ] && return 4
  return 2
}

# Shadow synthesis floor (Layer 3+, issue #426): when an iter-<N>.json carries no
# `shadow` block but the run holds promotion evidence that iteration N's shadow
# promoted — iter-<N+1>.json exists with loop_role "promoted" — the shadow block
# was dropped (the issue-304 drop shape). Synthesize a minimal marker
# {shadow_synthesized: true, promoted_to_iter_next: true} into iter-<N>.json so
# the promotion is not left silently unattributable. Best-effort, always returns
# 0 (a floor failure never aborts --persist). Two guards keep it faithful: it
# NEVER overwrites an existing `shadow` block (agent-written or already
# synthesized — the read gates on `.shadow` absence), and it writes at most one
# marker per promotion-evidenced iter (no double-count — a second --persist pass
# sees the marker it wrote and declines). STATED LIMITATION: this recovers
# PROMOTED shadows only — a clean outcome-1 shadow whose block dropped leaves no
# promotion evidence to synthesize from; the fused Step 2.6 emit is the primary
# fix and this floor is its backstop, not its equal.
synthesize_shadow_markers() {
  local dir="$1" iter n next has_shadow promoted jq_err mv_err
  for iter in "$dir"/iter-*.json; do
    [ -e "$iter" ] || continue
    # Parse N from the filename with bash builtins only — this DECIDES whether a
    # marker is written, so it must not depend on a non-preflight PATH tool
    # (guard-class 2); a non-numeric stem is skipped, not defaulted.
    n="${iter##*/iter-}"; n="${n%.json}"
    case "$n" in ''|*[!0-9]*) continue ;; esac
    # Never overwrite: synthesize ONLY when `.shadow` is absent (jq `null`); skip
    # any iter that already carries a non-null `shadow` value — an object
    # (agent-written or previously synthesized) OR a malformed partial a truncated
    # write left behind (a string/number). Keying on object-ness alone would
    # clobber such a malformed real block; keying on `== null` fails closed on it
    # while still synthesizing into a genuinely-absent slot. A parse failure is
    # skipped (never clobber an unreadable block) but BREADCRUMBED, not silent —
    # matching recorded_fix_shas' unreadable-workpad breadcrumb and the file's
    # "surfacing failures" convention, so a malformed workpad that dropped a real
    # promoted shadow (the issue-304 drop shape this floor recovers) leaves a signal
    # rather than an unattributed silence.
    if ! has_shadow="$("$DEVFLOW_JQ" -r 'if .shadow == null then "no" else "yes" end' "$iter" 2>/dev/null)"; then
      echo "::warning::efficiency-trace.sh --persist: could not read '.shadow' from $(basename "$iter") (unreadable or malformed workpad); its shadow attribution (if any) cannot be recovered" >&2
      continue
    fi
    [ "$has_shadow" = "no" ] || continue
    # Promotion evidence: the next iter exists AND is a promoted iter. Force base-10
    # on the stem (`10#$n`) so a zero-padded numeric stem (`iter-08.json`) — which the
    # all-digit guard above admits — is not misread by `$(( ))` as invalid octal
    # (`08`/`09` → "value too great for base"); the producer never zero-pads, so this
    # is an adversarial-input guard, consistent with the guard-class-2 discipline.
    next="$dir/iter-$((10#$n + 1)).json"
    [ -e "$next" ] || continue
    if ! promoted="$("$DEVFLOW_JQ" -r 'if .loop_role == "promoted" then "yes" else "no" end' "$next" 2>/dev/null)"; then
      echo "::warning::efficiency-trace.sh --persist: could not read '.loop_role' from $(basename "$next") (unreadable or malformed workpad); cannot confirm promotion evidence for $(basename "$iter")" >&2
      continue
    fi
    [ "$promoted" = "yes" ] || continue
    # Merge the marker in via a temp file + mv (jq cannot edit in place; a direct
    # `> "$iter"` would truncate the source before jq reads it). A failed jq
    # leaves the original untouched with a breadcrumb — never a silent drop.
    if jq_err="$("$DEVFLOW_JQ" '.shadow = {shadow_synthesized: true, promoted_to_iter_next: true}' "$iter" 2>&1 > "$iter.shadowtmp")"; then
      if mv_err="$(mv "$iter.shadowtmp" "$iter" 2>&1)"; then
        echo "::warning::efficiency-trace.sh --persist: synthesized a minimal shadow marker on $(basename "$iter") — its shadow block was dropped but iter-$((10#$n + 1)).json is a promoted iter, so the promotion linkage is recovered (cost figures are unrecoverable after the fact — attribution only, per the floor's promoted-shadows-only limitation)" >&2
      else
        # Surface mv's own errno text (read-only mount, ENOSPC, …) rather than
        # discarding it to /dev/null — symmetric with the jq branch's $jq_err, and
        # the difference between a diagnosable failure and an unexplained one.
        echo "::warning::efficiency-trace.sh --persist: could not move the synthesized shadow marker into $(basename "$iter") (mv failed: ${mv_err:-no error text}); leaving it without one" >&2
        rm -f "$iter.shadowtmp" 2>/dev/null
      fi
    else
      echo "::warning::efficiency-trace.sh --persist: could not synthesize a shadow marker on $(basename "$iter") (${jq_err:-no error text}); leaving it without one" >&2
      rm -f "$iter.shadowtmp" 2>/dev/null
    fi
  done
  return 0
}

# ── --self-check (Layer 2): warn-only, never writes, never fails ─────────────
do_self_check() {
  # Silent when telemetry is disabled — there is no record to expect, so a
  # missing one is correct, not a gap. (Read-only runs are silent by caller
  # construction: SKILL.md only invokes the self-check on writable runs.)
  [ "$ENABLED" = "true" ] || return 0
  if [ -z "$WORKPAD_DIR" ] || [ -z "$SLUG" ]; then
    echo "::warning::efficiency-trace.sh --self-check requires --workpad-dir and --slug" >&2
    return 0
  fi
  local run_id root record
  run_id="$(basename "$WORKPAD_DIR")"
  root="$(devflow_repo_root)"
  # No iter-*.json workpad at all → per-iteration telemetry was never captured.
  if [ ! -d "$WORKPAD_DIR" ] || ! compgen -G "$WORKPAD_DIR"/iter-*.json >/dev/null 2>&1; then
    echo "::warning::devflow review-and-fix self-check: NO iter-*.json workpad was written for run ${SLUG}/${run_id} — per-iteration effectiveness telemetry was not captured this run; recover a minimal floor with 'lib/efficiency-trace.sh --persist --workpad-dir ${WORKPAD_DIR} --slug ${SLUG}' (the targeted form — bare discovery-mode --persist can decline this dir on a multi-slug or not-latest skip), which synthesizes an iteration record from this branch's unrecorded 'fix: address review findings (iteration N)' commits when any exist." >&2
    return 0
  fi
  # Workpads exist but the effectiveness record was not persisted. Presence is
  # tested ON THE TELEMETRY BRANCH now (issue #441) — the record no longer lives
  # in the working tree — via `git cat-file -e <ref>:<path>`, so a correctly
  # persisted run never draws a false "not persisted" warning and a genuinely
  # dropped one still does (AC15).
  local ref
  ref="$(devflow_telemetry_ref)"
  record=".devflow/logs/efficiency/${SLUG}-${run_id}.json"
  if ! devflow_telemetry_blob_exists "$root" "$ref" "$record"; then
    echo "::warning::devflow review-and-fix self-check: effectiveness record '${record}' was NOT persisted to the telemetry branch '${ref#refs/heads/}' for run ${SLUG}/${run_id} — recover it with 'lib/efficiency-trace.sh --persist'." >&2
  fi
  # Per-iteration field validation (issue #170): warn — best-effort, never writes,
  # never aborts — for each iter-<N>.json missing an expected field, naming the
  # field and the iter file so a silently-dropped inline-persist field becomes a
  # visible warning. One jq per file computes the missing set as a set difference
  # (expected fields − the object's keys). The jq call is guarded by `if !` — NOT a
  # bare `missing=$(...)` assignment, which under `set -e` would abort the whole
  # self-check (non-zero `exit`, not exit 0) the moment jq fails to *parse* or *open*
  # one iter file — mirroring how collect_valid_files and --persist guard their jq.
  #
  # Two wrong-shape cases that must NOT pass silently (this is the exact corruption
  # the self-check exists to surface, and in a STANDALONE --self-check run the
  # --persist/--mode parse paths have not run to breadcrumb the bad file first):
  #   (a) jq fails to *parse* or *open* the file (malformed/unreadable) → non-zero
  #       exit → the `if !` arm WARNS and skips the file (no field validation).
  #   (b) the file is valid JSON but NOT an object (e.g. [], null, "x") → jq emits
  #       the `__non_object__` sentinel (no real field is named that), which WARNS
  #       and skips — otherwise a wrong-shape workpad masquerades as complete.
  # An object yields its missing-field names; field names are bare identifiers, so
  # the `for field in $missing` word-split is safe (and emits one warning line each).
  local iter field missing shadow_missing
  for iter in "$WORKPAD_DIR"/iter-*.json; do
    [ -e "$iter" ] || continue
    # A synthesized record (issue #381) is a recognized degraded class — it
    # legitimately carries only iter/fix_commit_sha/fix_files/loop_role/synthesized,
    # so it is validated against THAT minimal set (ITER_SYNTH_EXPECTED_FIELDS),
    # not the full ITER_EXPECTED_FIELDS (a wave of spurious warnings would train
    # operators to ignore the self-check) — and not against nothing, or a
    # truncated/hand-edited synthesized record would validate silently (the
    # writer-controlled flag must not buy a total exemption).
    if ! missing="$("$DEVFLOW_JQ" -r --arg fields "$ITER_EXPECTED_FIELDS" --arg synth_fields "$ITER_SYNTH_EXPECTED_FIELDS" \
                      'if type == "object" then (if (.synthesized == true) then (($synth_fields | split(" ")) - keys)[] else (($fields | split(" ")) - keys)[] end) else "__non_object__" end' \
                      "$iter" 2>/dev/null)"; then
      echo "::warning::devflow review-and-fix self-check: iter workpad '$(basename "$iter")' is unreadable or not valid JSON — cannot validate its fields" >&2
      continue
    fi
    if [ "$missing" = "__non_object__" ]; then
      echo "::warning::devflow review-and-fix self-check: iter workpad '$(basename "$iter")' is valid JSON but not an object — cannot validate its fields" >&2
      continue
    fi
    for field in $missing; do
      echo "::warning::devflow review-and-fix self-check: iter workpad '$(basename "$iter")' is missing expected field '${field}'" >&2
    done
    # Synthesized shadow marker validation (issue #426): a `shadow` block carrying
    # `shadow_synthesized: true` is a recognized degraded class — validate it
    # against its own minimal set (SHADOW_SYNTH_EXPECTED_FIELDS), so a truncated
    # synthesized marker still warns while a complete one passes cleanly. A real
    # (agent-written) shadow block has no `shadow_synthesized` key, so this branch
    # never fires on it — the self-check leaves real shadow blocks unvalidated
    # exactly as before. The earlier `if !`/`continue` (the iter-field check above)
    # already warned about and skipped any unreadable/parse-failed file, so this
    # plain `if` only ever runs on a valid JSON object.
    if shadow_missing="$("$DEVFLOW_JQ" -r --arg sfields "$SHADOW_SYNTH_EXPECTED_FIELDS" \
                          'if ((.shadow | type) == "object") and (.shadow.shadow_synthesized == true) then (($sfields | split(" ")) - (.shadow | keys))[] else empty end' \
                          "$iter" 2>/dev/null)"; then
      for field in $shadow_missing; do
        echo "::warning::devflow review-and-fix self-check: iter workpad '$(basename "$iter")' has a synthesized shadow marker missing expected field '${field}'" >&2
      done
    fi
  done
  return 0
}

# ── --persist (Layer 3): derive + durable-copy → telemetry-branch write ──────

# Persist one run dir's artifacts (best-effort). Returns 0 always.
persist_one() {
  local dir="$1" slug="$2" run_id="$3" root="$4" allow_synth="${5:-1}"
  # Basename-derived identities need the same unsubstituted-placeholder refusal
  # as the argv guard above: a literal `<slug>/<run-id>` DIRECTORY (left by a
  # non-substituting agent running a workpad-dir mkdir fence verbatim) reaches
  # discovery mode without ever passing through argv, and synthesizing into it
  # would fabricate the same placeholder identity the argv guard refuses.
  case "${dir}${slug}${run_id}" in
    *'<'*|*'>'*)
      echo "::warning::efficiency-trace.sh --persist: run dir '${dir}' carries an unsubstituted '<placeholder>' identity (a verbatim '<slug>/<run-id>' directory left by a non-substituting run?); refusing to persist or synthesize under it — remove or rename the directory to recover" >&2
      return 0 ;;
  esac
  local durable record out jq_rc cp_err
  local iters=("$dir"/iter-*.json)
  if [ ! -e "${iters[0]}" ]; then
    # No per-iteration workpad. Layer-3+ synthesis floor (issue #381): reconstruct
    # a minimal record from this branch's fix commits so a fully-dropped run still
    # contributes effectiveness telemetry. Three guards keep a fix commit from
    # being double-counted into (or misattributed across) runs' records: (a)
    # sha-level exclusion — synthesis skips any commit already recorded as a
    # fix_commit_sha by another run's iter-*.json (real or synthesized, tmp tree
    # or committed durable copy), so a workpad-holding sibling run, a later
    # targeted --workpad-dir invocation, and a later discovery pass all decline
    # the same commit; (b) among the workpad-less dirs of one slug, only the
    # lexicographically-latest run-id synthesizes (allow_synth=1) — the rest
    # breadcrumb; and (c) when the workpad-less dirs span MULTIPLE slugs in one
    # discovery pass, ownership of the branch's fix commits is ambiguous offline
    # (a stale slug's leftover empty dir could claim the current branch's
    # commits), so discovery synthesizes into NONE of them (allow_synth=2,
    # breadcrumb naming the targeted escape hatch). The residual window is a run
    # whose EVERY workpad copy (tmp and durable) was deleted after its record
    # was derived — the durable-copy layer exists precisely so that does not
    # happen.
    if [ "$ENABLED" != "true" ]; then
      # Telemetry off: synthesized workpads exist ONLY to feed the (disabled)
      # effectiveness record — unlike REAL workpads, whose flag-off durable copy
      # is a deliberate carve-out — so fabricating them here would commit
      # telemetry artifacts to a repo that switched telemetry off. One gate
      # covers both the targeted and discovery paths.
      echo "::warning::efficiency-trace.sh --persist: run ${slug}/${run_id} has no iter-*.json and efficiency telemetry is disabled; skipping synthesis (a disabled record has no consumer for a synthesized workpad)" >&2
      return 0
    fi
    if [ "$allow_synth" = "2" ]; then
      echo "::warning::efficiency-trace.sh --persist: run ${slug}/${run_id} has no iter-*.json, but workpad-less run dirs span multiple slugs in this discovery pass — the branch's fix commits cannot be attributed to a slug offline, so synthesis is skipped for all of them; to synthesize this run explicitly, rerun with --persist --workpad-dir <dir> --slug ${slug}" >&2
      return 0
    fi
    if [ "$allow_synth" != "1" ]; then
      echo "::warning::efficiency-trace.sh --persist: run ${slug}/${run_id} has no iter-*.json and is not the synthesis target for slug '${slug}' (a later run-id holds it); skipping synthesis so fix commits are not double-counted" >&2
      return 0
    fi
    # Three-way outcome (unknown is never collapsed onto "found none" — the
    # repo's describe-denial-count.sh gotcha): rc 2 = selection ran, nothing
    # unrecorded to synthesize; rc 3 = the search could not run (unresolvable
    # base ref OR a failed git log — whether commits exist was never
    # established); rc 4 = commits were selected but every record write failed.
    local synth_rc=0
    synthesize_iter_workpads "$dir" "$root" || synth_rc=$?
    case "$synth_rc" in
      0) : ;;
      3)
        echo "::warning::efficiency-trace.sh --persist: run ${slug}/${run_id} left no iter-*.json and the fix-commit search could not run (an uncreatable target dir, an unresolvable base ref, or a failed git log enumeration — the warning above names which) — whether matching fix commits exist was never established; telemetry not synthesized" >&2
        return 0 ;;
      4)
        echo "::warning::efficiency-trace.sh --persist: run ${slug}/${run_id} left no iter-*.json; matching fix commits were selected but every synthesized record write failed (see the per-commit warnings above — disk/permissions, or on the cloud tier the sandbox's redirect-write denial into .devflow/tmp) — telemetry not synthesized" >&2
        return 0 ;;
      2)
        echo "::warning::efficiency-trace.sh --persist: run ${slug}/${run_id} left no iter-*.json and no unrecorded 'fix: address review findings (iteration N)' commits were found — per-iteration effectiveness telemetry was not captured this run; nothing to synthesize" >&2
        return 0 ;;
      *)
        # Unknown is not zero: an rc outside the 0/2/3/4 contract (a signal, a
        # future drift) must not be reported as "no commits were found".
        echo "::warning::efficiency-trace.sh --persist: run ${slug}/${run_id} left no iter-*.json and synthesis exited with unexpected rc=${synth_rc} — whether matching fix commits exist was never established; telemetry not synthesized" >&2
        return 0 ;;
    esac
    iters=("$dir"/iter-*.json)
    if [ ! -e "${iters[0]}" ]; then
      # Defensive: unreachable while synthesize_iter_workpads' rc-0 contract
      # guarantees >=1 surviving write into $dir — but if a future edit
      # desynchronizes that contract, dropping the record with zero signal is
      # exactly the silent hole this file exists to close.
      echo "::warning::efficiency-trace.sh --persist: synthesis reported success but no iter-*.json exists in ${dir}; record not derived for ${slug}/${run_id}" >&2
      return 0
    fi
  fi
  # NOTE (issue #441): the historical `source == "review"` skip is GONE. Both
  # standalone /devflow:review (Phase 4.5) and /devflow:review-and-fix now persist
  # through this SAME code path to the SAME telemetry branch — the record is keyed
  # by (slug, run-id) and its jq derivation branches on the workpad's own `source`
  # field, so a review run yields a review-mode record and a fix-loop run a
  # fix-loop record, both idempotent by branch presence. Unifying the paths is the
  # whole point of #441 (one durable store for every writable run), so a review run
  # discovered here is persisted, not skipped.

  # Shadow synthesis floor (issue #426): recover a dropped-but-promoted shadow
  # block as a minimal marker BEFORE the durable copy below, so a synthesized
  # marker is committed alongside the workpads it annotates. Telemetry-gated like
  # the iter floor above — a synthesized marker is a telemetry artifact, so a
  # telemetry-disabled repo gets none. (Runs on the real-workpad path too: a
  # synthesized-iter run is all `loop_role: "fix"` with no promotion evidence, so
  # the floor is a no-op there and only fires when a real promoted iter exists.)
  [ "$ENABLED" = "true" ] && synthesize_shadow_markers "$dir"

  # ── Everything below STAGES into .devflow/tmp/ (never the tracked tree) so the
  # detached telemetry-branch write (do_persist) picks it up (issue #441). The
  # current branch, HEAD, and the working tree are never touched. _TELEMETRY_STAGE
  # is the shared staging root do_persist created; its subtree mirrors the exact
  # .devflow/logs/… layout the branch commit will carry. ────────────────────────

  # Durable workpad copy — NOT telemetry-gated (runs on every writable run).
  # Copies every *.json in the run dir (iter-*.json + deferrals.json), mirroring
  # the SKILL.md Loop Exit durable-copy. Content-idempotent: the branch write's
  # tree-equality no-op guard emits no commit when the bytes are unchanged.
  durable="${_TELEMETRY_STAGE}/.devflow/logs/review/${slug}/${run_id}"
  if ! cp_err="$( { mkdir -p "$durable" && cp -p "$dir"/*.json "$durable"/; } 2>&1 )"; then
    echo "::warning::efficiency-trace.sh --persist: durable workpad copy failed (${dir} -> ${durable}): ${cp_err:-unknown}; best-effort, continuing" >&2
  fi

  # Effectiveness record — telemetry-gated, presence-based idempotency tested ON
  # THE TELEMETRY BRANCH (issue #441 AC14): `git cat-file -e <ref>:<path>`. Never
  # re-derive an existing record — its `generated_at` is stamped at derivation
  # time, so re-deriving would churn the bytes and force a spurious new branch
  # commit, defeating the no-op-on-re-run contract. A record already on the branch
  # (a prior --persist) is not re-DERIVED here: staged for neither derivation nor
  # write BY THIS DISCOVERY PASS. (Issue #475 relaxes the store's strictly-append-
  # only posture: the harness-cost floor's merge arm — apply_harness_floor, run once
  # after this loop in do_persist — reads such a record back and re-stages it with an
  # add-if-absent `harness_cost` key, byte-preserving `generated_at` and every other
  # field. A record already carrying harness_cost is still left untouched, so the
  # backstop re-run remains a tree-equality no-op. This loop's derivation path is
  # unchanged; only the floor mutates an existing path, and it never re-derives.)
  if [ "$ENABLED" = "true" ]; then
    local ref rel_record
    ref="$(devflow_telemetry_ref)"
    rel_record=".devflow/logs/efficiency/${slug}-${run_id}.json"
    if ! devflow_telemetry_blob_exists "$root" "$ref" "$rel_record"; then
      record="${_TELEMETRY_STAGE}/${rel_record}"
      collect_valid_files "$dir"
      # `if !` guards `set -e` on a failing command-substitution assignment, and
      # captures emit_jq's rc so a jq DERIVATION FAILURE (broken filter, jq missing,
      # --argjson rejected) is distinguished from a benign empty derivation (rc 0,
      # zero readable iterations → emit_jq prints nothing, matching the flag-off
      # contract). The former is a real malfunction that would otherwise drop a
      # recoverable record with no signal — exactly the silent hole this issue
      # closes — so warn.
      jq_rc=0
      out="$(emit_jq record "$slug")" || jq_rc=$?
      if [ "$jq_rc" -ne 0 ]; then
        echo "::warning::efficiency-trace.sh --persist: record derivation (jq) failed (rc=${jq_rc}) for ${slug}/${run_id}; record not written" >&2
      elif [ -n "$out" ]; then
        if mkdir -p "$(dirname "$record")" 2>/dev/null; then
          # Check the redirection itself: a write failure after mkdir (ENOSPC,
          # EROFS, quota, perms) must not stage a truncated/partial record for the
          # branch write.
          if ! printf '%s\n' "$out" > "$record"; then
            echo "::warning::efficiency-trace.sh --persist: staging record ${record} failed (disk/permission); not persisted for ${slug}/${run_id}" >&2
            rm -f "$record" 2>/dev/null
          fi
        else
          echo "::warning::efficiency-trace.sh --persist: could not create $(dirname "$record"); record not written for ${slug}/${run_id}" >&2
        fi
      fi
    fi
  fi
  return 0
}

# ── Harness-side cost floor (Layer 4, issue #475) ────────────────────────────
# Merge the claude-code-action execution_file's cost — normalized by the reader
# (scripts/extract-execution-cost.py) and handed in via DEVFLOW_EXECUTION_COST — into
# THIS run's efficiency record as a distinct top-level `harness_cost` object. This is
# the FIRST floor operand NOT fed by an agent-volunteered value: the execution file is
# written harness-side, so a run that dropped every telemetry emit still contributes a
# cost record. The reader is NEVER exec'd from here — doing so would add a python3 exec
# edge to a Stop-hook trusted-closure entry (the #458 constraint) — so the glue helper
# (scripts/prepare-harness-floor.sh) runs the reader and passes its already-normalized
# JSON in via the environment.
#
# Env inputs (all set by prepare-harness-floor.sh + the backstop step):
#   DEVFLOW_EXECUTION_COST  the reader's normalized JSON; presence GATES the whole
#                           floor (unset/empty → silent no-op, --persist byte-identical
#                           to before — the in-run Loop-Exit persist and the Stop-hook
#                           persist both run with it unset by design, AC3).
#   DEVFLOW_EXECUTION_PR    the run's PR number — the skeleton slug (pr-<N>); empty
#                           skips the skeleton arm (the #431 analysis joins merged PRs).
#   DEVFLOW_COMMAND_CLASS   review|review-and-fix|pr-description|implement — the
#                           harness_cost.command field AND the skeleton gate
#                           (pr-description derives no record by design).
#   GITHUB_RUN_ID / GITHUB_RUN_ATTEMPT  the run-id identity the record is keyed by:
#                           <run-id> == ${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}, the same
#                           value skills/review-and-fix/SKILL.md's RUN_ID= line composes.
#   GITHUB_WORKFLOW_REF     the path-pinned workflow identity (harness_cost.workflow).
#
# Telemetry-gated exactly as record derivation is (AC8); best-effort/exit-0 like every
# other --persist arm. Per-phase aggregates never see floor data — harness_cost is a
# distinct TOP-LEVEL key, invisible to _run_cost/_telemetry_complete (AC9).

# Add harness_cost (add-if-absent) to an in-STAGING record file $1, via temp+mv so a
# failed jq leaves the file untouched. $2 is the harness_cost JSON, $3 a display label.
_floor_merge_staged() {
  local file="$1" hc="$2" label="$3" jq_err
  if "$DEVFLOW_JQ" -e 'has("harness_cost")' "$file" >/dev/null 2>&1; then
    echo "devflow: efficiency-trace.sh --persist: harness cost floor: ${label} already carries harness_cost; left untouched" >&2
    return 0
  fi
  if jq_err="$("$DEVFLOW_JQ" --argjson hc "$hc" '.harness_cost = $hc' "$file" 2>&1 > "$file.harnesstmp")"; then
    if mv "$file.harnesstmp" "$file" 2>/dev/null; then
      echo "devflow: efficiency-trace.sh --persist: harness cost floor: attached harness_cost to ${label}" >&2
    else
      echo "::warning::efficiency-trace.sh --persist: harness cost floor: could not move the merged ${label} into place; left without harness_cost" >&2
      rm -f "$file.harnesstmp" 2>/dev/null
    fi
  else
    echo "::warning::efficiency-trace.sh --persist: harness cost floor: could not merge harness_cost into ${label} (${jq_err:-no error text}); left without harness_cost" >&2
    rm -f "$file.harnesstmp" 2>/dev/null
  fi
}

# Consume DEVFLOW_EXECUTION_COST and land it as harness_cost on this run's record
# (merge arm) or a minimal cost skeleton (skeleton arm). $1 root, $2 staging root.
apply_harness_floor() {
  local root="$1" stage="$2"
  # Unset/empty cost → INERT and SILENT: --persist behaves byte-for-byte as before.
  # This guard MUST stay first so the agent-side persist paths emit no breadcrumb (AC3).
  [ -n "${DEVFLOW_EXECUTION_COST:-}" ] || return 0
  # Gated (AC8): sits under efficiency_telemetry_enabled exactly as record derivation
  # does. Set-but-gated-off draws one breadcrumb (the operand WAS supplied) and writes
  # nothing.
  if [ "$ENABLED" != "true" ]; then
    echo "::warning::efficiency-trace.sh --persist: harness cost floor: efficiency telemetry is disabled; DEVFLOW_EXECUTION_COST supplied but not attached this run" >&2
    return 0
  fi
  # Validate the operand is a JSON OBJECT — a malformed value draws one breadcrumb and
  # no floor write (AC3). Never feed an unvalidated env value into a jq --argjson, which
  # would abort the helper under set -e.
  if ! printf '%s' "$DEVFLOW_EXECUTION_COST" | "$DEVFLOW_JQ" -e 'type == "object"' >/dev/null 2>&1; then
    echo "::warning::efficiency-trace.sh --persist: harness cost floor: DEVFLOW_EXECUTION_COST is not a JSON object; no floor write this run" >&2
    return 0
  fi
  # Run-id identity the record is keyed by. On the cloud tier GITHUB_RUN_ID is always
  # set; without it this run cannot be identified, so decline (never attach to an
  # arbitrary record a discovery pass swept — AC3).
  if [ -z "${GITHUB_RUN_ID:-}" ]; then
    echo "::warning::efficiency-trace.sh --persist: harness cost floor: GITHUB_RUN_ID is unset, so this run's record cannot be identified; no floor write" >&2
    return 0
  fi
  local ident="${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT:-1}"
  # engine_version: the .version of plugin.json resolved BESIDE this helper — null with a
  # breadcrumb when unreadable (AC4), never a fabricated value.
  local plugin_json="$HERE/../.claude-plugin/plugin.json" ev=""
  if [ -f "$plugin_json" ] && ev="$("$DEVFLOW_JQ" -r 'if (.version | type) == "string" then .version else empty end' "$plugin_json" 2>/dev/null)" && [ -n "$ev" ]; then
    :
  else
    ev=""
    echo "::warning::efficiency-trace.sh --persist: harness cost floor: could not read .version from ${plugin_json}; engine_version recorded as null" >&2
  fi
  # Build harness_cost (AC4 — EXACTLY these fields): metadata plus the reader's figures
  # spread in. workflow/command are null when their env is empty (unknown-is-not-zero).
  local harness_cost
  if ! harness_cost="$(printf '%s' "$DEVFLOW_EXECUTION_COST" | "$DEVFLOW_JQ" -c \
        --arg ev "$ev" \
        --arg wf "${GITHUB_WORKFLOW_REF:-}" \
        --arg cmd "${DEVFLOW_COMMAND_CLASS:-}" \
        '{cost_source: "execution-file",
          engine_version: (if $ev == "" then null else $ev end),
          workflow: (if $wf == "" then null else $wf end),
          command: (if $cmd == "" then null else $cmd end),
          scope: "whole-job",
          cost_usd: .cost_usd,
          tokens: .tokens,
          model_usage: .model_usage,
          num_turns: .num_turns,
          duration_ms: .duration_ms}' 2>/dev/null)"; then
    echo "::warning::efficiency-trace.sh --persist: harness cost floor: could not assemble the harness_cost object (jq failed); no floor write" >&2
    return 0
  fi

  local eff_dir="${stage}/.devflow/logs/efficiency" f
  # Merge arm (a): a record DERIVED THIS PASS and staged under the run-id identity —
  # `<slug>-<ident>.json`, matched by `*-<ident>.json` so ANY slug (pr-<N>, a branch
  # slug, or a synthesized run) is caught, but ONLY for this run-id (AC3: never a record
  # a discovery pass swept for another run).
  if [ -d "$eff_dir" ]; then
    for f in "$eff_dir"/*-"$ident".json; do
      [ -e "$f" ] || continue
      _floor_merge_staged "$f" "$harness_cost" "staged record $(basename "$f")"
      return 0
    done
  fi
  # Merge arm (b): a record already PERSISTED on the telemetry branch for this run-id (a
  # prior --persist of this run — the in-run Loop-Exit persist landed it without
  # harness_cost, since the execution file does not exist mid-run). Read it back, add
  # harness_cost only when absent, re-stage. A record already carrying harness_cost is
  # left unstaged, so re-running the backstop ends at the tree-equality no-op (AC5).
  local ref rel base blob
  ref="$(devflow_telemetry_ref)"
  while IFS= read -r rel; do
    case "$rel" in *-"$ident".json) ;; *) continue ;; esac
    base="$(basename "$rel")"
    blob="$(devflow_telemetry_show_blob "$root" "$ref" "$rel")" || continue
    [ -n "$blob" ] || continue
    if printf '%s' "$blob" | "$DEVFLOW_JQ" -e 'has("harness_cost")' >/dev/null 2>&1; then
      echo "devflow: efficiency-trace.sh --persist: harness cost floor: record ${rel} already carries harness_cost; leaving it untouched (backstop re-run no-op)" >&2
      return 0
    fi
    mkdir -p "$eff_dir" 2>/dev/null || true
    if printf '%s' "$blob" | "$DEVFLOW_JQ" --argjson hc "$harness_cost" '.harness_cost = $hc' > "${eff_dir}/${base}" 2>/dev/null; then
      echo "devflow: efficiency-trace.sh --persist: harness cost floor: attached harness_cost to already-persisted record ${rel}" >&2
    else
      echo "::warning::efficiency-trace.sh --persist: harness cost floor: could not merge harness_cost into ${rel}; no floor write" >&2
      rm -f "${eff_dir}/${base}" 2>/dev/null
    fi
    return 0
  done < <(devflow_telemetry_list_blobs "$root" "$ref" ".devflow/logs/efficiency/")

  # Skeleton arm (AC6): no record for this run-id anywhere. Only record-DERIVING command
  # classes get a skeleton — pr-description's healthy state is "no record", so it takes a
  # named breadcrumb instead. An empty PR skips (the analysis joins merged PRs only).
  case "${DEVFLOW_COMMAND_CLASS:-}" in
    review|review-and-fix|implement) ;;
    pr-description)
      echo "::warning::efficiency-trace.sh --persist: harness cost floor: no record by design for command class 'pr-description'; no skeleton written" >&2
      return 0 ;;
    *)
      echo "::warning::efficiency-trace.sh --persist: harness cost floor: command class '${DEVFLOW_COMMAND_CLASS:-<unset>}' does not derive records; no skeleton written" >&2
      return 0 ;;
  esac
  if [ -z "${DEVFLOW_EXECUTION_PR:-}" ]; then
    echo "::warning::efficiency-trace.sh --persist: harness cost floor: no record for run-id ${ident} and DEVFLOW_EXECUTION_PR is empty; skeleton skipped (the analysis joins merged PRs only)" >&2
    return 0
  fi
  local slug="pr-${DEVFLOW_EXECUTION_PR}" generated_at skel
  # Skeleton-overwrite guard (issue #475 review): merge-arm-b reaches here by falling through
  # a `while … done < <(devflow_telemetry_list_blobs …)` loop that iterates ZERO times BOTH
  # when the branch genuinely holds no record for this run-id AND when list_blobs swallowed a
  # git failure (it returns empty on a rev-parse/ls-tree error) — an ambiguous signal. If a
  # real, populated record already exists on the branch under the skeleton's OWN filename
  # (`pr-<N>-<ident>.json`, the common review-and-fix collision), writing a contentless
  # skeleton would OVERWRITE it (the union applies a staged path local-wins). So re-check the
  # blob explicitly and decline rather than resting on the empty-list signal: a missed merge
  # (record kept intact, gains harness_cost on a later working re-run) is strictly safer than
  # replacing a real record with an iterations:0 skeleton.
  if [ -n "$ref" ] && devflow_telemetry_blob_exists "$root" "$ref" ".devflow/logs/efficiency/${slug}-${ident}.json" 2>/dev/null; then
    echo "::warning::efficiency-trace.sh --persist: harness cost floor: a record already exists on the telemetry branch at .devflow/logs/efficiency/${slug}-${ident}.json (merge-arm-b's branch listing may have failed silently); declining to overwrite it with a cost skeleton" >&2
    return 0
  fi
  generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mkdir -p "$eff_dir" 2>/dev/null || true
  # source:null (no mode's derivation ran — outside both mode segments); synthesized:true
  # + iterations:0 + source:null + harness_cost.cost_source is what distinguishes a
  # cost-only skeleton from a #381 commit-reconstructed record (AC6).
  if skel="$("$DEVFLOW_JQ" -n --arg slug "$slug" --arg ga "$generated_at" --argjson hc "$harness_cost" \
        '{schema_version: 1, slug: $slug, generated_at: $ga, source: null,
          synthesized: true, iterations: 0, per_iteration: [], telemetry: [],
          harness_cost: $hc}' 2>/dev/null)" && printf '%s\n' "$skel" > "${eff_dir}/${slug}-${ident}.json"; then
    echo "devflow: efficiency-trace.sh --persist: harness cost floor: no record for run-id ${ident}; wrote a minimal cost skeleton ${slug}-${ident}.json (source:null, synthesized:true)" >&2
  else
    echo "::warning::efficiency-trace.sh --persist: harness cost floor: could not write the cost skeleton for ${slug}-${ident}; no floor write" >&2
    rm -f "${eff_dir}/${slug}-${ident}.json" 2>/dev/null
  fi
  return 0
}

do_persist() {
  local root dir slug run_id _TELEMETRY_STAGE
  root="$(devflow_repo_root)"
  # Resolve the telemetry branch ONCE, here in the parent, before anything forks. The
  # resolution is memoized in _DEVFLOW_TELEMETRY_BRANCH_CACHE, and a subshell inherits the
  # parent's variables — but NOT a sibling's. Without this seed the first call happened
  # inside a subshell, so every later subshell re-resolved from scratch: the config was
  # re-read once per fork and, on an invalid `telemetry.branch`, its breadcrumb was printed
  # once per fork (three times in a single --persist). Seed it in the parent and they all
  # inherit one resolution, and one warning. Redirect stdout ONLY — stderr must stay open or
  # this seed would swallow the very breadcrumb it exists to emit exactly once.
  devflow_telemetry_branch >/dev/null || true
  # Shared staging root under gitignored .devflow/tmp/ (issue #441). Every
  # persist_one call stages its record + durable workpad copy here, mirroring the
  # exact .devflow/logs/… layout; after the loop the detached telemetry-branch
  # write consumes the whole tree and this scratch is removed. Nothing is ever
  # materialized in the tracked working tree, so `git status` stays byte-for-byte
  # unchanged (AC2). Unique name via bash builtins (not mktemp — the cloud sandbox
  # blocks it, AC9).
  _TELEMETRY_STAGE="${root}/.devflow/tmp/telemetry-stage-$$-${RANDOM}-${SECONDS}"
  rm -rf "$_TELEMETRY_STAGE" 2>/dev/null || true
  mkdir -p "$_TELEMETRY_STAGE" 2>/dev/null || true
  if [ -n "$WORKPAD_DIR" ]; then
    # Targeted: persist exactly the given run. Slug from --slug, else the parent
    # dir name; run-id is the workpad-dir basename. Derived with bash parameter
    # expansion only — these values DECIDE which run identity receives the
    # record, so they must not depend on PATH tools at all (guard-class 2): a
    # broken/shadowed `basename` on PATH would abort the persist mid-run under
    # set -e (rc 127 — violating the best-effort exit-0 contract and losing the
    # record), and builtins remove that dependency outright. (The script's init
    # line still uses `dirname` to locate itself; a host that broken never gets
    # this far.)
    dir="${WORKPAD_DIR%/}"
    while [ "${dir%/}" != "$dir" ]; do dir="${dir%/}"; done   # collapse any extra trailing slashes
    run_id="${dir##*/}"
    if [ -n "$SLUG" ]; then
      slug="$SLUG"
    else
      slug="${dir%/*}"; slug="${slug##*/}"
    fi
    persist_one "$WORKPAD_DIR" "$slug" "$run_id" "$root" 1
  else
    # Discovery: every .devflow/tmp/review/<slug>/<run-id>/ directory. The trailing
    # slash restricts the glob to directories; an unmatched glob stays literal and
    # the `[ -d ]` guard skips it (no nullglob needed). A dir HOLDING iter-*.json
    # is persisted immediately. A WORKPAD-LESS dir is collected so the issue #381
    # synthesis floor synthesizes into only the lexicographically-latest
    # workpad-less run-id per slug: the glob is sorted, so same-slug dirs are
    # contiguous with run-ids ascending — the LAST workpad-less dir of a slug is
    # its latest, and every earlier one gets allow_synth=0 (breadcrumb). This
    # ordering guard is one of the double-count defenses; the sha-level exclusion
    # inside synthesis (see persist_one) covers the shapes ordering cannot — a
    # workpad-holding sibling run and later passes — and the multi-slug ambiguity
    # guard below covers the shape NEITHER can: workpad-less dirs spanning
    # multiple slugs, where whichever slug sorts first would otherwise claim the
    # current branch's fix commits even when it is a stale leftover from an
    # aborted run of a DIFFERENT branch/PR (misattribution, which the sha
    # exclusion would then lock in). Slug ownership is not derivable offline
    # (a pr-<N> slug cannot be mapped to the checkout without the API), so the
    # ambiguous case fails closed for every candidate, each with a breadcrumb
    # naming the targeted --workpad-dir escape hatch. Known residual for the
    # MISATTRIBUTION direction: a SINGLE stale foreign slug's workpad-less dir,
    # when the current run left no tmp dir at all, is the sole candidate and
    # still claims the branch's fix commits under the wrong slug — guard (c)
    # trips only on multiple slugs, because a lone candidate is
    # indistinguishable offline from the legitimate current run. A sibling
    # residual within one slug: a workpad-less dir sorting EARLIER than a
    # workpad-holding one is that slug's only synthesis candidate, so a stale
    # earlier run-id can receive the record (right slug, wrong run-id; the sha
    # exclusion still prevents any double-count). And a workpad-less dir left by
    # a standalone /devflow:review run is indistinguishable here from a dropped
    # fix loop's — its synthesized record defaults to source "review-and-fix"
    # (a synthesized workpad carries no `source` field, so the probe's else-arm
    # default fires, not the unreadable-file breadcrumb) even though the run
    # that created the dir was a review; content stays correct and the sha
    # exclusion still holds.
    local wl_dirs=() wl_n wl_i next_slug allow d_iters wl_slug_first wl_multi_slug=0
    for dir in "$root"/.devflow/tmp/review/*/*/; do
      [ -d "$dir" ] || continue
      dir="${dir%/}"                                # strip trailing slash
      run_id="${dir##*/}"                           # builtins only (guard-class 2:
      slug="${dir%/*}"; slug="${slug##*/}"          # identity-deciding, no PATH tools)
      d_iters=("$dir"/iter-*.json)
      if [ -e "${d_iters[0]}" ]; then
        persist_one "$dir" "$slug" "$run_id" "$root" 1
      else
        wl_dirs+=("$dir")
      fi
    done
    wl_n=${#wl_dirs[@]}
    wl_slug_first=""
    for ((wl_i = 0; wl_i < wl_n; wl_i++)); do
      slug="${wl_dirs[$wl_i]%/*}"; slug="${slug##*/}"   # builtins only — this
      # comparison DECIDES the multi-slug ambiguity trip, so it must not depend
      # on a PATH tool whose failure would abort or degrade it (guard-class 2).
      if [ -z "$wl_slug_first" ]; then
        wl_slug_first="$slug"
      elif [ "$slug" != "$wl_slug_first" ]; then
        wl_multi_slug=1
      fi
    done
    for ((wl_i = 0; wl_i < wl_n; wl_i++)); do
      dir="${wl_dirs[$wl_i]}"
      run_id="${dir##*/}"
      slug="${dir%/*}"; slug="${slug##*/}"
      if [ "$wl_multi_slug" = "1" ]; then
        allow=2
      else
        next_slug=""
        if [ $((wl_i + 1)) -lt "$wl_n" ]; then
          next_slug="${wl_dirs[$((wl_i + 1))]%/*}"; next_slug="${next_slug##*/}"
        fi
        if [ "$slug" = "$next_slug" ]; then allow=0; else allow=1; fi
      fi
      persist_one "$dir" "$slug" "$run_id" "$root" "$allow"
    done
  fi

  # ── Harness-side cost floor (issue #475): merge the execution file's cost into
  # this run's staged record (or write a minimal cost skeleton) BEFORE the branch
  # write consumes the staging tree. Inert + silent when DEVFLOW_EXECUTION_COST is
  # unset, so the agent-side persist call sites (Loop-Exit, Stop-hook) are byte-
  # identical to before. Best-effort; runs after every run dir has been staged so
  # its run-id targeting sees this pass's staged record if one was derived. ────────
  apply_harness_floor "$root" "$_TELEMETRY_STAGE"

  # ── Detached write of everything staged above to the telemetry branch ──────
  # (issue #441). Replaces the former current-branch `chore:` commit: the shared
  # lib hashes each staged .devflow/logs/… file into the object store, builds a
  # tree parented on the telemetry ref (orphan root on first use), CAS-advances
  # the ref, and pushes with a fetch/re-parent retry loop — never touching the
  # current branch, HEAD, or the working tree. Best-effort/exit-0: a push that
  # can't happen (offline, read-only token/profile, no remote) still advances the
  # local ref and breadcrumbs. Then remove the staging scratch so `git status`
  # stays byte-for-byte unchanged (AC2). devflow_telemetry_persist_tree is a
  # clean no-op when nothing was staged.
  # Gate on the REAL source sentinel telemetry-branch.sh sets on a successful
  # source (_DEVFLOW_TELEMETRY_BRANCH_SOURCED) — NOT `command -v`, which always finds
  # the no-op stubs the source-failure branch defines, making this persist-time
  # "artifacts discarded" warning unreachable dead code. With the sentinel, a
  # vendored deploy missing lib/ takes the else and emits a specific persist-time
  # breadcrumb naming the discarded staging root, instead of silently no-op'ing.
  if [ -n "${_DEVFLOW_TELEMETRY_BRANCH_SOURCED:-}" ]; then
    devflow_telemetry_persist_tree "$root" "$_TELEMETRY_STAGE"
  else
    echo "::warning::efficiency-trace.sh --persist: telemetry-branch.sh was not sourced; cannot persist to the telemetry branch this run — the run's staged artifacts under ${_TELEMETRY_STAGE} are discarded" >&2
  fi
  rm -rf "$_TELEMETRY_STAGE" 2>/dev/null || true
  return 0
}

# ── Dispatch ─────────────────────────────────────────────────────────────────
case "$ACTION" in
  self-check) do_self_check; exit 0 ;;
  persist)    do_persist;    exit 0 ;;
esac

# Default action: --mode trace|record (unchanged contract).
if [ "$MODE" != "trace" ] && [ "$MODE" != "record" ]; then
  echo "efficiency-trace.sh: --mode must be 'trace' or 'record' (or pass --persist / --self-check)" >&2
  exit 2
fi

# Flag off → emit nothing, exit 0 (so a caller writing the record to a file
# produces no file under .devflow/logs/).
if [ "$ENABLED" != "true" ]; then
  exit 0
fi

collect_valid_files "$WORKPAD_DIR"
warn_on_mixed_source
emit_jq "$MODE" "$SLUG"
