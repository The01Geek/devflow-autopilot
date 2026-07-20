# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# shellcheck shell=bash
# Sourceable create-issue contract module.
# Contract: the caller sets LIB and RESULTS_FILE, defines assert_eq, and sources
# lib/test/module-harness.sh first (which defines the namespaced module pin API:
# devflow_module_pin_count / devflow_module_pin_unique / devflow_module_pin_present /
# devflow_module_pin_red_under).
# The module owns its private fixture root and cleanup; it never invokes the runner
# or the full-suite boundary, and it references NO monolith helper (no monolith temp
# allocator, no pin machinery of its own) — it uses only assert_eq plus the namespaced module API,
# plus its two domain-private classifiers below). The inventory in
# create-issue-contract.inventory.md maps the extracted coverage to its former
# run.sh locations. Modules may not self-skip.
# The cleanup handlers below rely on a sourcing contract: both callers
# (module-harness.sh's full-suite boundary and run-module.sh) source this module
# inside a ( ... ) subshell, so its EXIT/HUP/INT/TERM traps cannot clobber the
# runner's handlers. Do not source this module directly in a runner's top-level
# shell without restoring those traps.

# A caller may point DEVFLOW_CREATE_ISSUE_CONTRACT_ROOT at a scratch repository copy
# for mutation evidence; the normal focused and full-suite paths default to the
# repository containing LIB. Every consumed repository path is derived from LIB here
# (the create-issue skill, issue template, create-issue extension, the review-and-fix
# skill, the system overview, CLAUDE.md, and this module's inventory) — the module
# never reads a path variable initialized by the monolith.
CI_ROOT="${DEVFLOW_CREATE_ISSUE_CONTRACT_ROOT:-${LIB%/lib}}"
CI_SKILL="$CI_ROOT/skills/create-issue/SKILL.md"
CI_TMPL="$CI_ROOT/skills/create-issue/references/issue-template.md"
CI_EXT="$CI_ROOT/.devflow/prompt-extensions/create-issue.md"
CI_OVERVIEW="$CI_ROOT/docs/DEVFLOW_SYSTEM_OVERVIEW.md"
CI_CLAUDE="$CI_ROOT/CLAUDE.md"
CI_CLOUD_SETUP="$CI_ROOT/docs/cloud-setup.md"       # #593 grant-timing bootstrap consumer doc
CI_IMPL_DOC="$CI_ROOT/docs/implement-skill.md"      # #593 grant-timing bootstrap consumer doc
# review-and-fix is a BUNDLE since #530 (thin SKILL.md root + phases in
# references/*.md); the #467 D2 fix-delta-gate sentence now lives in a reference
# member, so the leg pins against the assembled CI_MAXI_BUNDLE (built below,
# after _ci_tmp_root exists) — never the root alone.
CI_INVENTORY="$CI_ROOT/lib/test/modules/create-issue-contract.inventory.md"

_ci_tmp_root_kind="self"
if [ -n "${DEVFLOW_MODULE_OWNED_SCRATCH_ROOT:-}" ]; then
  _ci_tmp_root_kind="boundary"
  _ci_tmp_root="$DEVFLOW_MODULE_OWNED_SCRATCH_ROOT"
  if [ ! -d "$_ci_tmp_root" ] || [ -L "$_ci_tmp_root" ]; then
    printf 'invalid boundary-owned create-issue-contract fixture: %s\n' \
      "$_ci_tmp_root" >&2
    return 1
  fi
else
  _ci_tmp_root="$(devflow_module_allocate_owned_directory \
    "${TMPDIR:-/tmp}/devflow-create-issue-contract.XXXXXX")" || {
    printf 'could not allocate create-issue-contract fixture\n' >&2
    return 1
  }
fi
_ci_tmp_root_is_safe() {
  local expected_parent="" actual_parent=""
  [ -d "$_ci_tmp_root" ] && [ ! -L "$_ci_tmp_root" ] || return 1
  case "$_ci_tmp_root" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$_ci_tmp_root_kind" in
    boundary)
      case "${_ci_tmp_root##*/}" in
        devflow-module-scratch.??????) return 0 ;;
        *) return 1 ;;
      esac
      ;;
    self)
      case "${_ci_tmp_root##*/}" in
        devflow-create-issue-contract.??????) ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
  expected_parent="$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P)" || return 1
  actual_parent="$(cd "$_ci_tmp_root/.." 2>/dev/null && pwd -P)" || return 1
  [ "$actual_parent" = "$expected_parent" ]
}
if ! _ci_tmp_root_is_safe; then
  # The value failed the recursive-cleanup contract. The directory was just
  # allocated, but remove even an empty leaf only when its generated name and
  # physical parent still prove it belongs to this allocation attempt.
  [ "$_ci_tmp_root_kind" != "self" ] || \
    _devflow_discard_unvalidated_owned_directory "$_ci_tmp_root" \
      "devflow-create-issue-contract." "${TMPDIR:-/tmp}" || :
  printf 'invalid create-issue-contract fixture root: %s\n' "$_ci_tmp_root" >&2
  _ci_tmp_root=""
  return 1
fi
# Consumed dynamically by devflow_module_pin_red_under from the sourced harness.
# shellcheck disable=SC2034
DEVFLOW_MODULE_SCRATCH_ROOT="$_ci_tmp_root"
export DEVFLOW_MODULE_SCRATCH_ROOT
_ci_cleanup_done=0
_ci_cleanup_root_done=0
_ci_cleanup_marker_done=0
_ci_cleanup() {
  [ "$_ci_cleanup_done" -eq 0 ] || return 0
  if [ "$_ci_cleanup_root_done" -eq 0 ]; then
    if ! _ci_tmp_root_is_safe; then
      printf 'devflow: refusing invalid create-issue-contract fixture: %s\n' \
        "$_ci_tmp_root" >&2
      return 1
    fi
    if ! rm -rf "$_ci_tmp_root"; then
      printf 'devflow: could not remove create-issue-contract fixture: %s\n' \
        "$_ci_tmp_root" >&2
      return 1
    fi
    _ci_cleanup_root_done=1
  fi
  if [ "$_ci_cleanup_marker_done" -eq 0 ] && \
    [ -n "${DEVFLOW_TEST_MODULE_CLEANUP_MARKER:-}" ]; then
    if ! printf 'module-cleanup\n' >> "$DEVFLOW_TEST_MODULE_CLEANUP_MARKER"; then
      printf 'devflow-test: could not append module cleanup marker to %s\n' \
        "$DEVFLOW_TEST_MODULE_CLEANUP_MARKER" >&2
      return 1
    fi
    _ci_cleanup_marker_done=1
  fi
  _ci_cleanup_done=1
}
_ci_cleanup_on_signal() {
  # The module process group includes the worker and foreground helpers, so the
  # supervisor's delivery releases Bash's deferred trap before this cleanup runs.
  trap '' HUP INT TERM
  _ci_cleanup || :
  trap - EXIT
  exit 1
}
trap _ci_cleanup EXIT
trap _ci_cleanup_on_signal HUP INT TERM

# The implement-skill bundle backs the #467 D2 Phase-2.4 leg (the widened
# best-effort-parser rule must appear exactly once across the implement skill's
# root + phase references). Assembled here from LIB, member by member. This restores
# the monolith `_build_skill_bundle` fail-LOUD-per-member contract (NOT the sibling
# review-and-fix-contract.sh's `cat … 2>/dev/null || :`, which silently swallows a
# missing/empty/unreadable member): a member that is not a readable non-empty file
# records a FAIL through the assertion channel naming that member, so a corrupt
# implement engine file cannot pass the pin green just because the pinned sentence
# survives in a different member. On the clean path no assertion is added (count
# unchanged); a bad member adds exactly one FAIL.
CI_IMPL_BUNDLE="$_ci_tmp_root/implement-skill-bundle.md"
: > "$CI_IMPL_BUNDLE"
for _ci_bundle_member in "$CI_ROOT/skills/implement/SKILL.md" "$CI_ROOT"/skills/implement/phases/*.md; do
  if [ -r "$_ci_bundle_member" ] && [ -s "$_ci_bundle_member" ]; then
    cat "$_ci_bundle_member" >> "$CI_IMPL_BUNDLE"
    printf '\n' >> "$CI_IMPL_BUNDLE"
  else
    assert_eq "ci module: implement-bundle member usable: $_ci_bundle_member" \
      "usable" "missing-empty-or-unreadable"
  fi
done

# The review-and-fix bundle backs the #467 D2 review-and-fix leg. Since #530 the
# skill is a thin SKILL.md root plus step references (phases in references/*.md),
# so the widened fix-delta-gate sentence lives in a reference member, not the
# root. Assemble root + references member by member with the SAME fail-LOUD-per-
# member contract as the implement bundle above: a missing/empty/unreadable
# member records a FAIL naming that member, so a corrupt engine file cannot pass
# the pin green just because the pinned sentence survives elsewhere.
CI_MAXI_BUNDLE="$_ci_tmp_root/review-and-fix-skill-bundle.md"
: > "$CI_MAXI_BUNDLE"
for _ci_maxi_member in "$CI_ROOT/skills/review-and-fix/SKILL.md" "$CI_ROOT"/skills/review-and-fix/references/*.md; do
  if [ -r "$_ci_maxi_member" ] && [ -s "$_ci_maxi_member" ]; then
    cat "$_ci_maxi_member" >> "$CI_MAXI_BUNDLE"
    printf '\n' >> "$CI_MAXI_BUNDLE"
  else
    assert_eq "ci module: review-and-fix-bundle member usable: $_ci_maxi_member" \
      "usable" "missing-empty-or-unreadable"
  fi
done

# ────────────────────────────────────────────────────────────────────────────
echo "create-issue contract: module surfaces and inventory"
# ────────────────────────────────────────────────────────────────────────────
assert_eq "ci module: create-issue skill is readable" "yes" \
  "$([ -r "$CI_SKILL" ] && echo yes || echo no)"
assert_eq "ci module: create-issue template is readable" "yes" \
  "$([ -r "$CI_TMPL" ] && echo yes || echo no)"
assert_eq "ci module: create-issue extension is readable" "yes" \
  "$([ -r "$CI_EXT" ] && echo yes || echo no)"
assert_eq "ci module: coverage inventory is readable" "yes" \
  "$([ -r "$CI_INVENTORY" ] && echo yes || echo no)"
devflow_module_pin_unique "ci module: inventory identifies the source baseline" \
  "553e13da" "$CI_INVENTORY"
devflow_module_pin_unique "ci module: inventory names the Step 3.6 audit group" \
  "Step 3.6 fresh-context audit" "$CI_INVENTORY"
devflow_module_pin_unique "ci module: inventory names the state-owner cutover group" \
  "Canonical draft-file audit + state-owner cutover" "$CI_INVENTORY"
devflow_module_pin_unique "ci module: inventory names the revision-delta guard group" \
  "Revision-delta verification coverage guard" "$CI_INVENTORY"

# ────────────────────────────────────────────────────────────────────────────
echo "create-issue contract: issue #443 Step 3.6 fresh-context audit"
# ────────────────────────────────────────────────────────────────────────────
# ── issue #443: the mandatory Step 3.6 fresh-context audit in /devflow:create-issue ──
# The deliverable is agent-executed skill prose plus one tracked extension file; no runtime
# code path executes in CI, so the automated boundary is the repo's skill-contract mechanism:
# pins over the rendered SKILL surfaces. Each pinned literal below IS the operative contract
# sentence itself (a self-contained skill-prose requirement, not a framing clause introducing
# one), so there is no operative-vs-framing ambiguity for devflow_module_pin_red_under to discriminate
# here. It is still used over plain devflow_module_pin_unique for its NON-VACUITY proof: each mutation
# excises the operative requirement clause (the whole pinned sentence or a fragment of it),
# re-introducing the guarded regression, so every pin is proven to flip PASS->FAIL when that
# clause is removed, not merely to be present. (#375's framing-vs-operative discrimination is
# exercised where the mutation deletes a DIFFERENT line than the pinned literal; here the
# mutation targets the pinned sentence itself, so the flip is a presence-of-the-operative-clause
# proof. The surface-presence pins that follow the mutation pins use plain devflow_module_pin_unique.)
# Verdict-line requirement (maps to the audit-prompt AC): removing "legal values are exactly"
# guts the FILE/REVISE/DRAFT-UNREADABLE verdict contract (issue #522 widened it to three values).
devflow_module_pin_red_under "#443: Step 3.6 mandates the FILE/REVISE/DRAFT-UNREADABLE verdict line" \
  'whose only three legal values are exactly' 's/legal values are exactly//' "$CI_SKILL"
devflow_module_pin_present "#522: Step 3.6 names the VERDICT: DRAFT-UNREADABLE legal value" \
  'VERDICT: DRAFT-UNREADABLE' "$CI_SKILL"
# Presence (not uniqueness): the FILE/REVISE verdict values recur across the template, the
# summary example, and the act-on-the-verdict prose (the third value DRAFT-UNREADABLE is pinned
# separately below) — the verdict-line CONTRACT is pinned uniquely above. Use the >=1
# presence pin, not the exactly-one unique pin, because these values legitimately recur.
devflow_module_pin_present "#443: Step 3.6 names the VERDICT: FILE legal value" \
  'VERDICT: FILE' "$CI_SKILL"
devflow_module_pin_present "#443: Step 3.6 names the VERDICT: REVISE legal value" \
  'VERDICT: REVISE' "$CI_SKILL"
# Information-diet exclusion clause (maps to the information-diet AC): removing it re-anchors
# the auditor on the drafting context — the exact regression the fresh-context mechanism prevents.
devflow_module_pin_red_under "#443: audit prompt omits conversation, Step 1 findings, and the derivation artifact" \
  'omits the drafting conversation, the Step 1 findings report, and the Step 2 derivation artifact' \
  's/omits the drafting conversation//' "$CI_SKILL"
devflow_module_pin_unique '#443: audit prompt refers to "the draft", never "your draft"' 'never "your draft"' "$CI_SKILL"
# Out-of-bounds on-disk artifacts (maps to the information-diet AC): the void clause is what
# stops repository read access from silently re-anchoring the auditor on the drafter's reasoning.
devflow_module_pin_red_under "#443: on-disk drafting artifacts are declared out of bounds (findings void)" \
  'any finding derived from those files is void' 's/derived from those files is void//' "$CI_SKILL"
# Synchronous-dispatch sentence (maps to the dispatch AC): removing the blocking-wait wording
# lets a launch acknowledgment be misread as the auditor's return.
devflow_module_pin_red_under "#443: Step 3.6 dispatch waits for the completed result (synchronous)" \
  "wait for the subagent's completed result before proceeding" \
  's/completed result before proceeding//' "$CI_SKILL"
# Degraded arm (maps to the degraded-arm AC). The #546 cutover moved this arm's ENTRY
# classification into the tool (`query-next-action` answers `dispatch-inline-degraded`, driven
# by run.sh's #546 next_action_budget_rows), so the old enumerated-failures literal is gone.
# What did NOT move is the attempt-first discipline: no state owner can stop an orchestrator
# from pre-detecting a nested context and skipping a dispatch it therefore never makes, so
# this stays a prose-only guarantee and keeps its pin. The mutation excises the never-
# pre-detect clause, re-introducing exactly that pre-detected skip.
devflow_module_pin_red_under "#443: degraded arm is attempt-first, never pre-detected" \
  'never pre-detect a nested context and skip' \
  's/never pre-detect a nested context and skip//' "$CI_SKILL"
# Re-audit offer in the Step 4 revision loop (maps to the revision-loop AC). Repointed by the
# #546 cutover's delta 9, which reordered the loop so the offer resolves BEFORE the confirm/
# edit approval question; the offer itself survives verbatim as a prose obligation (the tool
# owns the ceiling, never whether the orchestrator asks). Inverting the offer into a skip
# re-introduces the ship-an-unaudited-revision channel.
devflow_module_pin_red_under "#443: Step 4 revision loop offers a fresh re-audit" \
  '**offer a fresh re-audit** via the runner' \
  's/\*\*offer a fresh re-audit\*\* via the runner/skip any re-audit and proceed via the runner/' \
  "$CI_SKILL"
# Dispatch-time fresh re-load of the extension (maps to the forwarding-freshness AC): removing
# the fresh re-load lets a compaction-evicted turn-one load silently drop consumer dimensions.
devflow_module_pin_red_under "#443: consumer audit dimensions are re-loaded FRESH at dispatch time" \
  'extract from that **fresh** output any section headed exactly' \
  's/any section headed exactly//' "$CI_SKILL"
# Forwarding-contract heading, pinned as a COUPLED PAIR (maps to the forwarding-contract and
# extension-file ACs): the skill's forwarding sentence and this repo's live extension must both
# carry the exact `## Audit dimensions` heading; either side drifting turns its pin RED.
devflow_module_pin_unique "#443: skill forwarding contract keys on the exact ## Audit dimensions heading" \
  'headed exactly `## Audit dimensions`' "$CI_SKILL"
devflow_module_pin_unique "#443: live create-issue extension carries the exact ## Audit dimensions heading" \
  '## Audit dimensions' "$CI_EXT"
# Generic dimension checklist is consumer-agnostic (maps to the dimension-checklist AC).
devflow_module_pin_unique "#443: generic dimensions name host-OS variance without GNU coreutils" \
  'hosts without GNU coreutils' "$CI_SKILL"
devflow_module_pin_unique "#443: generic dimensions name execution-tier permission-allowlist variance" \
  'including their differing permission allowlists' "$CI_SKILL"
# Reconciliation absence pin (maps to the reconciliation AC): the stale literal must be GONE from
# the skill (it legitimately remains in CHANGELOG.md's historical entry, so this pin is FILE-scoped).
assert_eq "#443: SKILL no longer carries the stale 'no-subagent, all-inline model' literal" \
  "0" "$(devflow_module_pin_count 'no-subagent, all-inline model' "$CI_SKILL")"
# Non-vacuity proof: re-introducing the stale literal makes the absence guard's count non-zero,
# so the guard actually catches the regression rather than passing vacuously.
CI443_MUT="$_ci_tmp_root/ci443-mut"
sed -E '1s/^/REINTRODUCED no-subagent, all-inline model\n/' "$CI_SKILL" > "$CI443_MUT"
assert_eq "#443: absence guard catches a re-introduction of the stale literal (non-vacuous)" \
  "1" "$(devflow_module_pin_count 'no-subagent, all-inline model' "$CI443_MUT")"
rm -f "$CI443_MUT"
# Anti-deadlock guarantee (maps to the VERDICT: REVISE / re-audit AC): removing it re-opens an
# unbounded re-audit loop that could block issue filing.
devflow_module_pin_red_under "#443: bounded re-audit never deadlocks filing" \
  'the audit informs, it never deadlocks filing' 's/never deadlocks filing//' "$CI_SKILL"
# Mandatory never-silent audit summary line (maps to the audit-summary AC): the feature's
# observability contract — a skipped/degraded audit must always render a summary line. The
# #546 cutover moved the summary's FIELD SET to `query-summary` (a tool surface, driven by
# run.sh's #546 cli_roundtrip_restricted_path) but the mandatory-render contract is prose and
# survives the cutover with its pin: the tool can report the fields, it cannot make an
# orchestrator render the line. Repointed to the amended wording ("the audit ran", not "it
# ran"). The mutation excises the operative evidence clause.
devflow_module_pin_red_under "#443: audit summary line is the mandatory never-silent evidence" \
  'the summary line is the evidence the audit ran and which arm it took' \
  's/the evidence the audit ran and which arm it took//' "$CI_SKILL"
# The two surviving halves of the same contract, pinned as surfaces (the AC requires the
# summary-line contract sentence to survive the cutover): the line always renders, and a
# skipped/degraded audit is never silent.
devflow_module_pin_unique "#443: the audit summary line always renders (even on a clean zero-findings FILE)" \
  '**The audit summary line is mandatory and always renders**' "$CI_SKILL"
devflow_module_pin_unique "#443: a skipped or degraded audit is never silent" \
  'A skipped or degraded audit is **never silent**' "$CI_SKILL"
# Step 4 presentation gate (maps to the artifact-gate AC): the seam that makes Step 3.6
# mandatory rather than skippable — removing the presence check lets an un-audited draft show.
devflow_module_pin_red_under "#443: Step 4 presentation gate confirms this run's audit artifact exists" \
  'confirm `.devflow/tmp/issue-audit-<slug>.md` is present' \
  's/is present//' "$CI_SKILL"
# Audit-artifact write with delete-leftover-first (maps to the artifact-gate AC): mirrors the
# Step 2 derivation-artifact discipline so the gated file can only ever be this run's.
devflow_module_pin_red_under "#443: audit artifact deletes any same-slug leftover before writing" \
  'deleting any same-slug leftover first' 's/deleting any same-slug leftover first//' "$CI_SKILL"
# Audit-prompt template surfaces (maps to the audit-prompt AC, which requires EACH surface
# pinned here). These are surface-PRESENCE contracts — the template must carry each named
# element — so plain devflow_module_pin_unique is the honest primitive (a removed/duplicated surface
# flips count away from 1 → RED); no operative-vs-framing distinction applies to a surface pin.
devflow_module_pin_unique "#443: audit prompt carries the adversarial mandate (no credit for good intent)" \
  'no credit for good intent' "$CI_SKILL"
devflow_module_pin_unique "#443: audit prompt carries the pre-mortem frame (write the autopsy)" \
  'write the autopsy' "$CI_SKILL"
devflow_module_pin_unique "#443: per-finding bar requires quoting the exact draft line attacked" \
  'quote the exact draft line it attacks' "$CI_SKILL"
devflow_module_pin_unique "#443: per-finding bar reports an unverifiable claim as unverifiable" \
  'report an unverifiable claim as unverifiable rather than asserting it' "$CI_SKILL"
devflow_module_pin_unique "#443: scope exclusions judge the draft at issue altitude" \
  'judge the draft at **issue altitude**' "$CI_SKILL"
devflow_module_pin_unique "#443: scope exclusions require a concrete trigger scenario per finding" \
  'no finding without a concrete trigger scenario' "$CI_SKILL"
devflow_module_pin_unique "#443: audit prompt caps findings at five" \
  'at most five findings' "$CI_SKILL"
devflow_module_pin_unique "#443: audit prompt reserves exactly one Quiet Killer slot" \
  '"Quiet Killer"' "$CI_SKILL"
devflow_module_pin_unique "#443: the empty 'no actionable findings' output is explicitly legal" \
  'no actionable findings' "$CI_SKILL"
# Audit-summary required contents (maps to the audit-summary AC — the observability contract's
# operative fields, distinct from the never-silent rationale clause pinned above).
devflow_module_pin_unique "#443: audit summary states whether a consumer audit-dimensions section was appended" \
  'whether a consumer `## Audit dimensions` section was appended' "$CI_SKILL"
devflow_module_pin_unique "#443: audit summary renders the word degraded whenever the degraded arm ran" \
  'the word "degraded"' "$CI_SKILL"

# ── issue #522: Step 3.6 audits the canonical DRAFT FILE (not a hand-condensed copy), offers
#    user-chosen audit rounds past the automatic cap, and Step 3.5 self-checks the audit
#    dimensions. Same skill-contract mechanism as #443: pins over the rendered SKILL surface,
#    no runtime code path in CI.
#
#    ISSUE #546 CUTOVER — READ BEFORE ADDING A PIN HERE. The deterministic half of the Step
#    3.6 lifecycle no longer lives in this prose: transition legality, round numbering, the
#    automatic budget, retry bounds and their precedence, dispatch-arm routing, digest and
#    sentinel generation and comparison, the T1/T2 triggers, override records, presentation
#    eligibility, and the audit-summary field set are all owned by `scripts/issue-audit-state.py`.
#    Every #522 pin whose literal asserted one of those guarantees was reconciled in the #546
#    cutover: the guarantee is now driven as a TOOL test (the `#546` blocks in this file and in
#    test_python_scripts.py), not asserted as a sentence a skill could silently paraphrase away.
#    A pin deleted there is named at its replacement below. What SURVIVES here is the prose-only
#    residue — the obligations no in-process tool can force on an orchestrator that simply never
#    calls it (dispatch discipline, the information diet, the auditor's own instructions, the
#    offers, the mandatory summary render) — plus the obey-the-tool contract itself, which is the
#    seam the whole cutover rests on. Do not re-pin a tool-owned guarantee as prose: a prose pin
#    over a value the tool decides is the coupled-mirror hazard, and the tool is the source of
#    truth. Behavioral-fix pins here use devflow_module_pin_red_under with a sed -E mutation that
#    RE-INTRODUCES the named defect (excising or inverting the operative clause so its removal
#    alone re-opens the guarded regression); the rest are surface-presence pins.
#
# (0) OBEY THE TOOL — the headline pin of the #546 cutover, and the one guarantee the tool
#     provably cannot enforce on itself: `query-eligibility` can only answer the runs that call
#     it (the skill's own "Honest scope of this gate" paragraph concedes this). The operative
#     sentence is the one that binds PRESENTATION to the tool's answer; excising it alone
#     re-introduces prose-decided eligibility — an orchestrator that is "certain the draft is
#     clean" presenting on its own judgment, which is exactly issue #546's motivating
#     regression. The surrounding sentences ("the lifecycle is owned by … not by this prose",
#     "the tool's answer *is* the decision") are FRAMING: they describe the ownership without
#     binding any act to an answer, so pinning one of them would stay GREEN under this mutation.
devflow_module_pin_red_under "#546: presentation eligibility is the tool's answer, never prose-decided" \
  'is presented for approval only after `query-eligibility --mode approve` answers `eligible=yes`' \
  's|\*\*A draft you are certain is clean is presented for approval only after `query-eligibility --mode approve` answers `eligible=yes`\.\*\* ||' \
  "$CI_SKILL"
# The obey-the-tool contract's two supporting prose obligations (surfaces, not mutations): the
# record-and-obey loop, and the closed prohibition on re-deriving a tool-owned decision.
devflow_module_pin_unique "#546: the step records each lifecycle event through the tool and obeys its answer" \
  'records each lifecycle event through that tool and obeys the answer it returns' "$CI_SKILL"
devflow_module_pin_unique "#546: no tool-owned decision is ever re-derived from this prose" \
  'Never re-derive a transition, a budget, a retry bound, a dispatch arm, or eligibility from this prose' \
  "$CI_SKILL"
# An illegal-transition rejection is NOT unavailability (SKILL.md's contract line). Without
# this rule a rejected mutation routes to the `state-owner unavailable` fallback — turning the
# tool's fail-closed refusal into a licence to improvise around it, which is the fail-open the
# whole state-owner cutover exists to close.
devflow_module_pin_unique "#546: an illegal-transition rejection is not an unavailability signal" \
  '**An illegal-transition rejection is NOT an unavailability signal.**' "$CI_SKILL"
devflow_module_pin_unique "#546: an illegal transition never routes to the state-owner-unavailable fallback" \
  'Never route an illegal transition to the `state-owner unavailable` fallback below' "$CI_SKILL"
# The `state-owner unavailable` fallback: its DISTINCT marker (distinct from `degraded`, which
# keeps meaning the inline arm — the two never substitute, so the breadcrumb stays honest:
# CLAUDE.md guard-class 2), its closed 2-class entry set, and its one-round/one-question bound.
# The bare marker string recurs (6x in the fallback's own prose), so the marker is pinned via
# its unique defining sentence rather than a bare-literal devflow_module_pin_unique.
devflow_module_pin_unique "#546: the state-owner-unavailable fallback carries its own distinct summary marker" \
  'The audit summary line carries the distinct marker **`state-owner unavailable`**' "$CI_SKILL"
devflow_module_pin_unique "#546: the state-owner-unavailable marker is distinct from the degraded marker" \
  'is **distinct from `degraded`**' "$CI_SKILL"
devflow_module_pin_unique "#546: exactly 2 classes route to the state-owner-unavailable fallback" \
  'Exactly **2 classes** route here, and nothing else' "$CI_SKILL"
devflow_module_pin_unique "#546: the state-owner-unavailable fallback is bounded to one round and one question" \
  'bounded to one round and one question' "$CI_SKILL"
# The fallback is never silent either (the AC's "a fallback lifecycle is never silent"), and it
# never reconstructs a round's findings from memory.
devflow_module_pin_unique "#546: the state-owner-unavailable fallback still renders the mandatory summary line" \
  'A fallback lifecycle is **never silent**' "$CI_SKILL"
devflow_module_pin_unique "#546: a memory-reconstructed findings summary is never a legal discharge" \
  '**A findings summary reconstructed from memory and presented as a round'"'"'s real findings is never a legal discharge.**' \
  "$CI_SKILL"
# (1) Pre-dispatch canonical write — removing it re-opens the condensation-drift channel (the
#     auditor audits a hand-condensed copy instead of the exact file the implementer reads).
devflow_module_pin_red_under "#522: Step 3.6 writes the canonical draft file before every dispatch" \
  'write the current rendered draft title + body to the canonical draft file' \
  's/ to the canonical draft file//' "$CI_SKILL"
# (2) Read-the-file-as-sole-draft-source — removing it lets the auditor judge an embedded/
#     remembered copy, re-opening the same condensation-drift channel.
devflow_module_pin_red_under "#522: audit prompt reads the draft file as the sole draft source" \
  'Read the draft file `{absolute issue-draft-<slug>.md path}` as the sole draft source' \
  's/as the sole draft source//' "$CI_SKILL"
# (3) Narrowed reasoning-artifacts-only out-of-bounds list — putting the draft back on the
#     file-arm out-of-bounds list makes the artifact under audit unreadable to the auditor.
devflow_module_pin_red_under "#522: draft file is NOT on the file-arm out-of-bounds list" \
  'is **not** on the file-arm out-of-bounds list' \
  's/is \*\*not\*\* on the file-arm out-of-bounds list/is on the file-arm out-of-bounds list/' "$CI_SKILL"
# (4) The user-chosen-rounds OFFER at the Step 3.6 → Step 4 boundary. #546 moved the trigger
#     EVALUATION into the tool (`query-triggers` answers `t1=…  t2=…  reason=…`), so the old
#     "evaluate exactly these **2 offer triggers**" literal is gone; T1, T2, and the
#     unestablished-state arm are now driven as tool rows (test_python_scripts.py's #546
#     t1_t2_rows — incl. "unestablished state -> T2 holds"; this file's #546
#     cli_roundtrip_restricted_path T1 row and the stale-.md "T2 holds on unestablished state"
#     row). What stays prose is WHETHER THE RUN ASKS — a tool can answer `t1=hold` all day and
#     never make an orchestrator open its mouth. Inverting the offer into a silent proceed
#     re-opens the ship-unconverged channel this boundary exists to close.
devflow_module_pin_red_under "#522: a held trigger offers one more audit round at the Step 3.6->4 boundary" \
  'While **either** holds, **offer one more audit round via the runner' \
  's/While \*\*either\*\* holds, \*\*offer one more audit round/While either holds, proceed to Step 4 without offering a round/' \
  "$CI_SKILL"
# The offer's non-silent arms, which stay prose obligations on the orchestrator: a silent
# non-response never dispatches and never proceeds (unknown is not consent), and the
# unestablished-state reason is NAMED in the offer rather than collapsed onto "no trigger"
# (unknown is not zero — CLAUDE.md's rule, and the tool's `reason=state-unestablished` is the
# operand this prose must actually surface).
devflow_module_pin_unique "#522: the boundary offer names which trigger fired, and the unestablished state when unknown" \
  'naming the unestablished state when `reason=state-unestablished` — unknown is not zero' \
  "$CI_SKILL"
devflow_module_pin_unique "#522: a silent non-response at the boundary offer never dispatches and never proceeds" \
  '**pause and re-ask in the final chat message; never dispatch and never proceed on silence.**' \
  "$CI_SKILL"
# The per-run ceiling is the tool's (`record-offer` refuses an accepted offer past
# `_USER_ROUND_CAP`; driven by this file's #546 user_round_cap_rows), so the old
# "User-chosen rounds are capped at 3 per run" prose literal is gone. The prose obligation that
# REPLACED it — never count rounds yourself — is what keeps an orchestrator from re-deriving
# the ceiling it just delegated, so it keeps a pin here.
devflow_module_pin_unique "#546: the tool owns the per-run offer ceiling; the run never counts rounds itself" \
  'the tool owns the per-run ceiling and refuses an accepted offer past it, so **never count rounds yourself**' \
  "$CI_SKILL"
# Audit-summary field surfaces. The FIELD SET is the tool's (`query-summary`), so the old
# "the total number of audit rounds run" prose literal is gone (driven by this file's #546
# cli_roundtrip_restricted_path summary row + the eligibility-token round-trip). What survives
# is the prose obligation to render what the query reports rather than a recollected summary —
# the misdirected-breadcrumb guard (CLAUDE.md guard-class 2) — plus each flag literal the
# rendering site must carry.
devflow_module_pin_unique "#546: the summary line's fields are read from query-summary, never recollected" \
  '**Do not assemble its fields from your own recollection of the run — read them from `query-summary`**' \
  "$CI_SKILL"
devflow_module_pin_unique "#522: audit summary carries the declined-further-audit phrase" \
  'user declined further audit' "$CI_SKILL"
devflow_module_pin_unique "#522: Step 3.5 self-checks the draft against the audit dimensions" \
  'Self-check the draft against the Step 3.6 audit dimensions' "$CI_SKILL"
devflow_module_pin_unique "#522: Step 3.5 summary reports the dimension self-check (falsifiable zero)" \
  'no dimension-checklist finding' "$CI_SKILL"
# Template out-of-bounds ENUMERATION pin (closes the narration-vs-template drift the pin (3)
# narration pin alone leaves open — a regression re-adding the draft to the audit-prompt
# TEMPLATE's out-of-bounds list would keep pin (3)'s narration sentence GREEN; this pins the
# template's exact reasoning-artifact list, so re-adding the draft there flips it RED).
# #546 widened the list from 3 files to 4: the state owner's record `issue-audit-state-<slug>.json`
# joined it, and the RETIRED `.md` event log stays named — a pre-cutover leftover on disk
# re-anchors an auditor on prior verdicts exactly as the live file did, and this skill no longer
# writes (or deletes) that path, so only the out-of-bounds declaration covers it.
devflow_module_pin_unique "#522: audit-prompt template out-of-bounds names exactly the 4 reasoning artifacts" \
  'The following on-disk files are **out of bounds** — `.devflow/tmp/issue-derivation-<slug>.md`, `.devflow/tmp/issue-audit-<slug>.md`, `.devflow/tmp/issue-audit-state-<slug>.json`, and `.devflow/tmp/issue-audit-state-<slug>.md`' "$CI_SKILL"
# The retired-.md rationale is itself pinned: it is the one out-of-bounds entry with no live
# producer, so a future reader who "tidies" it away silently re-opens the re-anchoring channel.
devflow_module_pin_unique "#546: the retired .md event log stays declared out of bounds (pre-cutover leftovers re-anchor)" \
  'The retired `.md` path stays named even though this skill no longer writes it' "$CI_SKILL"
# NOTE (#546): the "automatic budget stays one audit plus **at most one** automatic re-audit"
# pin was DELETED here, not repointed — `_MAX_AUTOMATIC_REAUDITS` moved into the tool, so a
# prose pin over it is exactly the coupled-mirror hazard the cutover removes. Its replacement
# is next_action_budget_rows in this file's #546 block, which drives `query-next-action`'s
# retry/budget arms directly — including the ceiling itself: three consecutive REVISE rounds
# must yield one automatic re-audit and then fall through to the user-chosen-offer evaluation.
# Coupled doc site (AC 'Coupled sites updated in the same change'): the §11 item 5 overview
# must carry the new file-first contract, not the retired "only the rendered title and body".
devflow_module_pin_unique "#522: overview §11 item 5 describes the file-first sole-draft-source contract" \
  'reads that file as the sole draft source' "$CI_OVERVIEW"
# File-arm carriage / identity check (closes the write-to-read race — the one uncovered
# operative anti-corruption contract): the auditor must return a full-content git hash-object
# digest of the file it read so the orchestrator can compare and reject foreign bytes —
# a full-content digest catches an interior overwrite that boundary-line sampling would miss.
# AMENDED by #546: the instruction now names `git hash-object --no-filters`. The flag is
# load-bearing, not cosmetic — the tool hashes via `git hash-object --stdin --no-filters` at
# every site, and path-mode hashing applies clean/CRLF filters that diverge from stdin hashing
# on the SAME bytes, so a filter-free auditor instruction is what makes the dispatch digest,
# the auditor-quoted digest, and the eligibility digest agree on every host. Dropping the flag
# would make a clean CRLF draft refuse as a false mismatch — driven by this file's #546
# digest_filter_mode_rows (autocrlf + text=auto fixtures).
devflow_module_pin_unique "#522: file-arm carriage check returns a full-content git hash-object digest for identity compare" \
  'run `git hash-object --no-filters` on the draft file it read and quote the printed object ID verbatim in its return' "$CI_SKILL"
# Template-side git-hash-object instruction (iteration-4 review finding C: narration-vs-template
# drift). The pin above pins the AUTHOR-FACING narration wording; the DISPATCHED audit-prompt
# template carries its own copy (different wording), and a regression removing the template's
# instruction leaves the narration pin GREEN while the auditor is no longer asked to hash —
# silently disabling the whole identity check. Symmetric with the out-of-bounds template pin.
# (AMENDED by #546 to `--no-filters`, for the digest_filter_mode_rows reason above.)
devflow_module_pin_unique "#522: audit-prompt template instructs the auditor to return a git hash-object digest" \
  'run `git hash-object --no-filters` on that draft file and quote the object ID it prints verbatim' "$CI_SKILL"
# Template-side DRAFT-UNREADABLE emit condition (iteration-4 review finding F): the only other
# guard over this token is a non-discriminating devflow_module_pin_count>=1 that stays GREEN as long as the
# token survives anywhere; this pins the template's operative emit-condition sentence so deleting
# the instruction that tells the auditor WHEN to produce the third verdict flips RED.
devflow_module_pin_unique "#522: audit-prompt template states the DRAFT-UNREADABLE emit condition" \
  'If you cannot read the file, return **no findings** and end with' "$CI_SKILL"
# Degraded-arm carve-out: the inline arm has no subagent/file, so it must NOT emit the
# file-arm-only third verdict value — deleting this carve-out re-opens a spurious emit.
devflow_module_pin_unique "#522: degraded inline arm emits no VERDICT: DRAFT-UNREADABLE" \
  'emits **no `VERDICT: DRAFT-UNREADABLE`**' "$CI_SKILL"
# Embed-arm out-of-bounds list (the inverse of the file arm's list — re-adds the draft path):
# symmetric with the file-arm template-enumeration pin above. #546 widened it 4 → 5 files, in
# lockstep with the file arm's 3 → 4: the state `.json` and the retired `.md` are both named.
devflow_module_pin_unique "#522: embed arm out-of-bounds names exactly the 5 files (draft re-added)" \
  'On this arm the out-of-bounds declaration names exactly these 5 files — `.devflow/tmp/issue-derivation-<slug>.md`, `.devflow/tmp/issue-draft-<slug>.md`, `.devflow/tmp/issue-audit-<slug>.md`, `.devflow/tmp/issue-audit-state-<slug>.json`, and the **retired** `.devflow/tmp/issue-audit-state-<slug>.md`' "$CI_SKILL"
# ── #546 RECONCILIATION: the carriage COMPARE, the event log, the retry bounds, and T1/T2.
#
# The #522 block used to pin, as prose, the whole deterministic half of the carriage/identity
# check and the round record. Every one of those literals is gone from the skill, because the
# ORCHESTRATOR no longer performs any of it — `issue-audit-state.py` does. The pins below are
# the surviving prose residue only; each deleted pin's guarantee is named against the tool test
# that now carries it, so the reconciliation is auditable rather than a silent drop:
#
#   deleted prose pin                                  → the tool test that now carries it
#   ---------------------------------------------------------------------------------------
#   compare uses the write-time digest, never a re-hash → py #546 carriage_evidence_rows
#                                                         (+ #546 digest_filter_mode_rows here,
#                                                          which proves the dispatch/auditor/
#                                                          eligibility digests agree)
#   compare fails closed on an absent/unparseable ID   → py #546 carriage_evidence_rows
#                                                         ("carriage mismatched vs. absent — the
#                                                          same classification, fail closed")
#   absent recorded write-time digest at compare time  → py #546 carriage_evidence_rows (same
#                                                         rows: absent evidence == mismatched)
#   file arm routes to embed on unrecorded comparand   → py #546 arm_routing_rows
#                                                         (hash_ok=False → embed/digest-unrecorded)
#   the 3 embed markers (write-failed / file-unreadable → py #546 arm_routing_rows, which asserts
#     / digest-unrecorded) + the summary's marker list    _EMBED_MARKER_TEXT byte-for-byte; the
#                                                         summary re-emits them via query-summary
#   event log records the write-time digest at dispatch → this file's #546
#                                                         cli_roundtrip_restricted_path
#                                                         (record-dispatch prints digest=)
#   revision step writes a revised-after-round-N record → py #546 _TRANSITION_ROWS
#                                                         (revision/after-completed-round legal,
#                                                          revision/no-rounds-recorded illegal)
#   event log is deleted-leftover-first at first dispatch→ this file's #546 reinit_force_rows
#                                                         (the cold-start wipe `init` now owns)
#   canonical write fires at exactly the 4 sites       → subsumed by the surviving pin (1) above
#                                                         (the per-round pre-dispatch write
#                                                          instruction — a within-round retry
#                                                          reuses the round's write),
#                                                         + `query-arm --write-landed`
#   orchestrator string-compares sentinels, rejects     → py #546 carriage_evidence_rows
#     a mismatch                                          (the tool owns the compare now)
#   file-arm DRAFT-UNREADABLE re-dispatches once        → #546 next_action_budget_rows (below)
#   embed-arm DRAFT-UNREADABLE never re-dispatches      → #546 next_action_budget_rows (below)
#     to the file arm
#   T1 fires on the last round's VERDICT: REVISE       → py #546 t1_t2_rows
#   T2 fires when a revision postdates the last round  → py #546 t1_t2_rows
#   audit summary states the total rounds run          → py #546 summary rounds_run
#   user-chosen rounds capped at 3 per run             → #546 user_round_cap_rows (below)
#   automatic budget = 1 audit + at most 1 re-audit    → #546 next_action_budget_rows (below)
#                                                         (the ceiling is driven end-to-end)
#
# What CANNOT move to the tool, and therefore keeps a prose pin: the auditor's own instructions
# (the tool never talks to the auditor), the orchestrator's obligation to FORWARD what the
# auditor quoted instead of comparing or inventing it, and the observation the routing rests on.
#
# Forward-don't-compare (the file arm). The tool owns the comparison, so the orchestrator's only
# remaining job is to hand over what it received verbatim — and, critically, to hand over
# NOTHING when the auditor quoted nothing. Inventing an object ID would manufacture exactly the
# proof the check exists to demand, and the tool would pass the manufactured evidence: this is
# the one carriage fail-open the tool provably cannot close from the inside, which is why it
# stays pinned as prose. The mutation excises the omit-when-absent rule.
devflow_module_pin_red_under "#546: an absent carriage object ID is forwarded as absent, never invented" \
  'Omit `--carriage-object-id` when the return quoted none' \
  's/Omit `--carriage-object-id` when the return quoted none — an absent value is evidence the tool needs, and inventing one would manufacture the proof the check exists to demand\.//' \
  "$CI_SKILL"
devflow_module_pin_unique "#546: the quoted object ID is forwarded verbatim and the tool's classification obeyed" \
  '**Forward that quoted object ID verbatim to `record-return --carriage-object-id <the ID the auditor quoted>` and obey the classification the tool returns.**' \
  "$CI_SKILL"
devflow_module_pin_unique "#546: the orchestrator never compares the carriage digest itself" \
  'Do not compare it yourself: the tool holds the write-time digest it recorded at dispatch and owns the comparison' \
  "$CI_SKILL"
# The write-time-vs-re-hash RATIONALE survives in prose (as the "why" behind a tool behavior that
# IS driven by py #546 carriage_evidence_rows). Pinned as a surface, not a mutation: the
# mechanism is the tool's, so this sentence documents rather than decides.
devflow_module_pin_unique "#546: the tool compares against the dispatch-time digest, never a compare-time re-hash" \
  'never a fresh compare-time re-hash of the on-disk file — a re-hash would see the same foreign bytes the auditor did and pass a concurrent overwrite vacuously' \
  "$CI_SKILL"
# Forward-don't-compare (the embed arm) — the exact mirror, plus the half the tool cannot own:
# the orchestrator must bracket the body with the tokens the TOOL generated. Choosing its own
# tokens would compare against a value the tool never recorded, which the tool would then read
# as a mismatch it can neither explain nor prevent.
devflow_module_pin_red_under "#546: the embed arm brackets the body with the tool-generated sentinels only" \
  'Bracket the embedded body with **exactly those printed tokens** — never tokens you choose yourself' \
  's/ — never tokens you choose yourself, which would compare against a value the tool never recorded//' \
  "$CI_SKILL"
devflow_module_pin_unique "#546: the quoted sentinel pair is forwarded and the tool's classification obeyed" \
  '**Forward the quoted pair to `record-return --carriage-sentinel-open <quoted> --carriage-sentinel-close <quoted>` and obey the classification returned**' \
  "$CI_SKILL"
# Embed-arm auditor QUOTE obligation (iteration-4 review finding G): the half that PRODUCES the
# values the tool compares. Deleting the auditor's quote obligation makes the compare
# compare-against-nothing — and this instruction lives in the dispatch prompt, a surface no tool
# can reach, so it stays prose. (Its file-arm twin is the `--no-filters` hash pin above.)
devflow_module_pin_unique "#522: embed-arm auditor must quote both sentinels plus body boundary lines" \
  'quote both sentinels plus the body'\''s first and last lines verbatim' "$CI_SKILL"
# Write-landing OBSERVATION (issue #522 iteration-3 review I3, repointed by #546). The ROUTING
# moved to `query-arm` (py #546 arm_routing_rows), but the routing's operand did not: whether
# the write landed is an observation only the orchestrator can make, and `query-arm` is only as
# honest as the `--write-landed` it is handed. The original fail-open is unchanged — on a fresh
# `<slug>` with no leftover, a read-only sandbox lets `rm` succeed vacuously while the write
# still fails, so an orchestrator that INFERS landing from the delete reports `--write-landed yes`
# for an unwritten path and the tool routes it to the file arm on false evidence. The mutation
# excises the confirm-explicitly rule, restoring exactly that inference.
devflow_module_pin_red_under "#522: write-landing is confirmed explicitly, never inferred from the delete" \
  'rather than inferring it from the delete — on a fresh `<slug>` with no leftover, a read-only sandbox lets the `rm` succeed vacuously while the write still fails' \
  's/ rather than inferring it from the delete — on a fresh `<slug>` with no leftover, a read-only sandbox lets the `rm` succeed vacuously while the write still fails//' \
  "$CI_SKILL"
# ... and that the observation is REPORTED to the tool rather than acted on: the orchestrator
# observes, the tool decides. This is the seam the arm-routing rows sit behind.
devflow_module_pin_unique "#546: the write-landing observation is reported to the tool, which decides the arm" \
  'pass it as `--write-landed yes|no` to `query-arm`, which decides the arm' "$CI_SKILL"
devflow_module_pin_unique "#546: the dispatch arm is the tool's answer, never the orchestrator's" \
  '**The arm is the tool'\''s answer, never yours.**' "$CI_SKILL"
# Verdict EXTRACTION is LLM work; verdict CLASSIFICATION is not. The tool validates the token
# fail-closed against its closed set (py #546 carriage_evidence_rows / classify_return), but it
# can only classify what it is handed — so "omit --verdict on an unparseable return" and "never
# pass a token the auditor did not emit" are prose obligations, the exact twin of the carriage
# omit-when-absent rule above. Mapping an unparseable return onto a verdict is how a run
# manufactures a clean FILE the auditor never returned.
devflow_module_pin_red_under "#546: an unparseable return is never mapped onto a verdict token" \
  'Never map an unparseable return onto a verdict token yourself, and never pass a token the auditor did not emit' \
  's/Never map an unparseable return onto a verdict token yourself, and never pass a token the auditor did not emit; the tool validates the token fail-closed against its closed set\.//' \
  "$CI_SKILL"
devflow_module_pin_unique "#546: the verdict token's absence is classified by the tool, not by the run" \
  '**Omit `--verdict` entirely when the return carried no parseable `VERDICT:` line**' "$CI_SKILL"
# The next-action answer set is the tool's closed vocabulary, and the prose obligation is to obey
# it verbatim. Pinned as a COUPLED PAIR with the tool: every token named here is driven by #546
# next_action_budget_rows below, and the skill naming a token the tool cannot answer (or the tool
# growing an arm the skill never obeys) is the drift this pin plus those rows catch together.
devflow_module_pin_unique "#546: query-next-action's answer is obeyed verbatim from its closed answer set" \
  '**Obey the answer verbatim** — it is one of `dispatch-embed-retry`, `dispatch-retry-same-arm`, `dispatch-inline-degraded`, `proceed`, `revise-and-reaudit`, `revise-then-evaluate-offer`, `round-open-awaiting-return`, or `round-closed-no-verdict`' \
  "$CI_SKILL"
# A finding can be wrong: the run verifies each against the code before acting. No tool can do
# this — it is the one step in the loop that requires reading the repository.
devflow_module_pin_unique "#546: findings are verified against the code before any revise action" \
  '**verify each finding against the code before acting** (a finding can be wrong)' "$CI_SKILL"

# ── issue #462: three create-issue authoring-discipline rules (prose + pins). Reuses the
#    #312/#443 create-issue file vars (CI_TMPL, CI_SKILL, CI_EXT). Each pinned literal
#    IS the operative contract sentence itself, so devflow_module_pin_unique is the honest primitive
#    (the #312 item-2 coupled-pair pattern). The template↔Step-3.5 coupled pair for the
#    unstated-reliance class is pinned on BOTH sides so a one-sided edit goes RED.
# Rule 1 — value-comparison type-semantics, template AC guidance + its checklist mirror.
devflow_module_pin_unique "#462 rule1: template AC guidance states value-comparison in observed-output terms" \
  "A value-comparison AC states its comparison in the producing surface's observed-output" "$CI_TMPL"
devflow_module_pin_unique "#462 rule1: verified arm requires the probe exercise the distinguishing boundary fixture" \
  'and a probe **silent on the distinguishing axis' "$CI_TMPL"
devflow_module_pin_unique "#462 rule1: obligation arm carries the execution-tier constraint (governs rule 3 too)" \
  'implement-tier verification commands (this governs this value-comparison AC and the Step 3.5' "$CI_TMPL"
devflow_module_pin_unique "#462 rule1: quality-checklist mirror line for the value-comparison rule" \
  "Value-comparison ACs/assertions state the comparison in the producing surface's observed-output terms" "$CI_TMPL"
# Rule 1 also verified in the Step 3.5 steelman (the check that flags a non-conforming AC).
devflow_module_pin_unique "#462 rule1: Step 3.5 checks value-comparison ACs for observed-output grounding" \
  'Value-comparison ACs are checked for observed-output grounding' "$CI_SKILL"
# Rule 2 — convention-matrix reconciliation + the `governing conventions consulted:` discharge
# literal pinned in BOTH the Testing Strategy guidance AND its quality-checklist mirror.
devflow_module_pin_unique "#462 rule2: template Testing Strategy carries the convention-matrix reconciliation rule" \
  'Reconcile an enumerated case matrix against governing conventions' "$CI_TMPL"
devflow_module_pin_unique "#462 rule2: discharge literal in the Testing Strategy guidance" \
  'governing conventions consulted: <sources cited by path' "$CI_TMPL"
devflow_module_pin_unique "#462 rule2: discharge literal mirrored in the quality checklist" \
  'a `governing conventions consulted:` discharge line bounded to' "$CI_TMPL"
# Rule 3 — unstated-mechanism-dependency, coupled template↔Step-3.5 pair + summary/zero arm.
devflow_module_pin_unique "#462 rule3 (coupled/template): template names the unstated-reliance premise class" \
  'Unstated mechanism dependencies are a premise class too' "$CI_TMPL"
devflow_module_pin_unique "#462 rule3 (coupled/SKILL): Step 3.5 gains the mandatory mechanism-dependency hunt" \
  "Sweep the draft's own unstated mechanism dependencies (mandatory)" "$CI_SKILL"
devflow_module_pin_unique "#462 rule3: Step 3.5 summary reports both new sweeps" \
  'The summary additionally reports both new sweeps' "$CI_SKILL"
devflow_module_pin_unique "#462 rule3: zero arm states the falsifiable no-dependencies claim, not a count" \
  'the mechanism invokes no in-repo helpers, resolvers, or gates' "$CI_SKILL"
# Rule 3's template quality-checklist mirror pinned too (symmetry with rule 1's checklist pin) —
# closes the coupled-mirror drift gap the pr-test-analyzer flagged: the checklist line can no
# longer silently drift out of agreement with the premise-class prose it mirrors.
devflow_module_pin_unique "#462 rule3: quality-checklist mirror line for the unstated-mechanism-dependency rule" \
  'are each resolved with a cited probe or an implementer-obligation AC' "$CI_TMPL"
# Step 3.6 — one consolidated generic dimension + the growth policy.
devflow_module_pin_unique "#462 dim: Step 3.6 generic checklist carries the consolidated authoring-discipline dimension" \
  'Authoring-discipline defects** — three related shapes' "$CI_SKILL"
devflow_module_pin_unique "#462 dim: Step 3.6 audit-prompt area states the finding-cap growth policy" \
  'execution-blocking defect classes outrank authoring-discipline classes for the finding-cap slots' "$CI_SKILL"
# Extension — one consolidated DevFlow-specific sharpening.
devflow_module_pin_unique "#462 ext: live create-issue extension carries the consolidated DevFlow sharpening" \
  'Authoring-discipline defects (DevFlow specifics, issue #462)' "$CI_EXT"

# ── issue #467: four create-issue authoring-discipline hardenings (prose + pins). Reuses the
#    #312/#443 create-issue file vars (CI_TMPL, CI_SKILL, CI_EXT). Each pinned literal
#    is drawn verbatim from the operative contract prose (a whole sentence or a load-bearing
#    fragment of one), so devflow_module_pin_unique is the honest primitive — the pin catches removal or
#    rewording of the contract prose, not a behavioral regression (the #312 coupled-pair pattern).
#    The template<->Step-3.5 coupled pairs for the B1
#    occurrence-count and C1 conditional-path premise classes are pinned on BOTH sides so a
#    one-sided edit goes RED.
# Cluster A — universal-claim rule (template AC guidance + checklist), Step 3.5 sweep + zero arm,
# Step 3.6 dimension sharpening (generic checklist size guard-locked below).
devflow_module_pin_unique "#467 A1: template AC guidance carries the universal-claim rule" \
  'about the system under change is grounded' "$CI_TMPL"
devflow_module_pin_unique "#467 A1: universal-claim rule carries the claim-level positive-control obligation" \
  'positive-control obligation** on the' "$CI_TMPL"
devflow_module_pin_unique "#467 A1: quality-checklist mirror for the universal-claim rule" \
  'Every universal quantifier ("never/always/each/every/all/cannot")' "$CI_TMPL"
devflow_module_pin_unique "#467 A2: Step 3.5 runs the universal-quantifier sweep (same carve-out)" \
  'Universal-quantifier sweep (mandatory' "$CI_SKILL"
devflow_module_pin_unique "#467 A2: Step 3.5 item-6 summary states the falsifiable zero arm" \
  'the draft carries no ungrounded universal quantifier' "$CI_SKILL"
devflow_module_pin_unique "#467 A3: Step 3.6 Load-bearing-assumptions dimension names universal quantifiers" \
  'including any **universal quantifier** the draft asserts' "$CI_SKILL"
# A3 count guard — the generic dimension checklist size is guard-locked (dimension-growth policy).
# The count is 9 after issue #464 (merged) appended the "Adversarial third-party input" dimension;
# #467 sharpened the "Load-bearing assumptions" dimension in place, adding no row (the growth-policy
# carve-out #464 pins sanctions that single standalone addition). Pin BOTH sed anchors
# present-and-unique so the count range stays bounded: a start-anchor drift already fails the count
# RED (sed prints nothing -> count 0), but an *end*-anchor drift would let sed run to EOF while the
# count coincidentally stays fixed, passing vacuously — these two pins turn either anchor's
# rename/removal RED at the desk. The devflow_module_pin_unique pins are UNANCHORED substring matches,
# though, while the sed range keys on the LINE-START shape /^\*\*.../ — so a position-only drift
# (an indent or prefix that keeps the substring but breaks ^** ) would slip the substring pins and
# still let sed run to EOF while the count stays 9. The two assert_eq below close that residual hole
# by binding each anchor to the exact ^** column-0 predicate sed uses, so the range can never
# silently un-bound (rename, removal, OR position drift all go RED at the desk).
devflow_module_pin_unique "#467 A3: the generic-dimension-checklist sed START anchor is present and unique" \
  '**Generic dimension checklist' "$CI_SKILL"
devflow_module_pin_unique "#467 A3: the generic-dimension-checklist sed END anchor is present and unique" \
  '**Dimension-list growth policy' "$CI_SKILL"
# Line-anchored anchor checks (close the position-drift hole the substring pins above cannot):
# each heading must match the sed range's ^** column-0 shape exactly once.
assert_eq "#467 A3: the generic-dimension-checklist sed START anchor matches at line-start exactly once" "1" \
  "$(grep -c '^\*\*Generic dimension checklist' "$CI_SKILL")"
assert_eq "#467 A3: the generic-dimension-checklist sed END anchor matches at line-start exactly once" "1" \
  "$(grep -c '^\*\*Dimension-list growth policy' "$CI_SKILL")"
assert_eq "#467 A3: Step 3.6 generic dimension checklist is 9 bullets (8 base + #464's dimension; #467 added none)" "9" \
  "$(sed -n '/^\*\*Generic dimension checklist/,/^\*\*Dimension-list growth policy/p' "$CI_SKILL" | grep -c '^- \*\*')"
# Cluster B — occurrence-count premise class (coupled template<->Step-3.5) + checklist mirror; AC
# mutual-consistency check (Step 3.5 + template AC guidance + checklist mirror).
devflow_module_pin_unique "#467 B1 (coupled/template): template names the occurrence-count/site-list premise class" \
  'Occurrence counts and coupled-site lists are a premise class too' "$CI_TMPL"
devflow_module_pin_unique "#467 B1 (coupled/SKILL): Step 3.5 mirrors the occurrence-count premise class" \
  'Occurrence counts and coupled-site lists are checked the same way' "$CI_SKILL"
devflow_module_pin_unique "#467 B1: quality-checklist mirror for the occurrence-count premise class" \
  'Every in-repo occurrence count or coupled-site list is grounded by an executed whitespace-normalized search' "$CI_TMPL"
devflow_module_pin_unique "#467 B2: Step 3.5 carries the AC mutual-consistency check" \
  'AC mutual-consistency check (mandatory)' "$CI_SKILL"
devflow_module_pin_unique "#467 B2: template AC guidance body carries the AC mutual-consistency rule" \
  "No acceptance criterion forbids a surface another criterion's discharge must touch" "$CI_TMPL"
devflow_module_pin_unique "#467 B2: quality-checklist mirror for the AC mutual-consistency check" \
  'the ACs are mutually consistent' "$CI_TMPL"
# Cluster C — conditional-path (coupled template<->Step-3.5), stated-but-unbound (Step 3.5's item-4 clause),
# trust-boundary closure (template AC guidance + Step 3.5 omission hunt).
devflow_module_pin_unique "#467 C1 (coupled/template): template premise method includes the gates on the path to X" \
  'Verifying "the code does X" includes the gates on the path to X' "$CI_TMPL"
devflow_module_pin_unique "#467 C1 (coupled/SKILL): Step 3.5 mirrors the conditional-path premise check" \
  'A "code does X" premise is verified with its enclosing gates on the path to X' "$CI_SKILL"
devflow_module_pin_unique "#467 C2: Step 3.5 unstated-dependency item extends to stated-but-unbound inputs" \
  'Extend the sweep to stated-but-unbound inputs (mandatory)' "$CI_SKILL"
devflow_module_pin_unique "#467 C3 (template): AC guidance carries the trust-boundary closure rule" \
  'source / exec / import closure' "$CI_TMPL"
devflow_module_pin_unique "#467 C3 (SKILL): Step 3.5 omission hunt carries the trust-boundary closure check" \
  'trust-boundary closure check (mirroring the template' "$CI_SKILL"
# C1/C3 quality-checklist mirrors — pinned for parity with the A1/B1/B2 checklist-mirror pins
# above (AC-E1: every new contract sentence in a pinned surface is presence-pinned), so a future
# edit can no longer silently drop or reword the conditional-path / trust-boundary checklist rows
# while their body rules stay pinned. Literals are unique to the checklist line (the C3 body pin
# 'source / exec / import closure' is the spaced form; the checklist uses the no-space form below).
devflow_module_pin_unique "#467 C1: quality-checklist mirror for the conditional-path premise check" \
  'enclosing gates/conditionals and their defaults on the path to X' "$CI_TMPL"
devflow_module_pin_unique "#467 C3: quality-checklist mirror for the trust-boundary closure rule" \
  'transitive source/exec/import closure of its entry points' "$CI_TMPL"
# Cluster D — Move 2a introduction trigger (template) + waiver-non-conforming clause; the
# three-site best-effort-parser widening (CLAUDE.md, implement Phase 2.4, review-and-fix
# fix-delta gate); extension sharpening (whole-file dimension count held at 9 after the
# deployment-variance dimension added on main; #467 added none, matching the D3 guard below). The six-shape
# SIXSHAPE_SET lockstep pins above stay green — the widening references the set, never restates it.
devflow_module_pin_unique "#467 D1: Move 2a carries the introduction trigger" \
  'Move 2a also fires on *introduction*, not only on narrowing' "$CI_TMPL"
devflow_module_pin_unique "#467 D1: introduction trigger names a blanket testing-scope waiver non-conforming" \
  'blanket testing-scope waiver' "$CI_TMPL"
devflow_module_pin_unique "#467 D2 (CLAUDE.md leg): best-effort-parser gotcha widened to mutable-markdown/external-format" \
  'The governed surface is broader than config JSON' "$CI_CLAUDE"
devflow_module_pin_unique "#467 D2 (Phase 2.4 leg): dry-trace rule widened to mutable-markdown/external-format" \
  'The governed surface is broader than config JSON' "$CI_IMPL_BUNDLE"
devflow_module_pin_unique "#467 D2 (review-and-fix leg): fix-delta matrix widened to mutable-markdown/external-format" \
  'widens to a parser over agent- or human-mutable markdown and a reader of a new external structured format' "$CI_MAXI_BUNDLE"
devflow_module_pin_unique "#467 D3: extension authoring-discipline dimension demands the input-type-appropriate matrix" \
  'input-type analogue** for the widened surfaces' "$CI_EXT"
# D3 count guard — the extension's dimension-bullet count is guard-locked. Since issue #548
# added a separate `## Evidence axes` section (whose axis bullets are also `- **`), this guard
# is scoped to the `## Audit dimensions` section ONLY (heading line to the next `## ` heading),
# so future `## Evidence axes` edits do not re-break it. It is 9: 7 base + #464's "Mutation
# evidence for behavioral-fix pins" dimension + the "Deployment-variance silence" dimension main
# commit 760c0902 appended; #467 sharpened the existing case-matrix bullet in place, adding no row.
devflow_module_pin_unique "base-update: create-issue extension carries the deployment-variance dimension" \
  'Deployment-variance silence.' "$CI_EXT"
assert_eq "#467 D3 (re-scoped by #548): create-issue extension ## Audit dimensions section is 9 dimension bullets" "9" \
  "$(awk '/^## Audit dimensions/{f=1;next} /^## /{f=0} f' "$CI_EXT" | grep -c '^- \*\*')"
# #548 Guard-reconciliation (count moved 4->5 by #593): the `## Evidence axes` section carries the
# DevFlow axis bullets; the old whole-file guard form would have broken here, which is exactly why
# it was re-scoped to this section only. #593 added the "Grant-timing bootstrap" axis bullet,
# moving this section guard from 4 to 5. (No whole-file total is restated here — it is un-pinned
# and would rot on the next dimension/axis add, the PR-553 stale-ordinal class.)
assert_eq "#548 Evidence-axes (count moved to 5 by #593): create-issue extension ## Evidence axes section is 5 axis bullets" "5" \
  "$(awk '/^## Evidence axes/{f=1;next} /^## /{f=0} f' "$CI_EXT" | grep -c '^- \*\*')"

# ── issue #593: grant-timing bootstrap (in-PR tool grants are post-merge-only) + repo-wide
#    mirror-sweep scope. Five surface-presence contract pins (devflow_module_pin_unique / a
#    count-equals-3 guard) on new prose — NOT behavioral-fix pins, so no mutation obligation
#    attaches (matching the #548/#464 surface-presence precedent: these pin sentence *presence*,
#    not a behavioral guarantee whose half-revert re-introduces a named bug).
# (1) CLAUDE.md gotcha operative phrase.
devflow_module_pin_unique "#593: CLAUDE.md grant-timing gotcha states the in-PR-inert rule" \
  'in-PR-inert and post-merge-only' "$CI_CLAUDE"
# (2) Extension's new Grant-timing bootstrap evidence axis.
devflow_module_pin_unique "#593: extension ## Evidence axes carries the Grant-timing bootstrap axis" \
  'Record whether any proposed in-run obligation, probe, or verification command' "$CI_EXT"
# (3) Shared repo-wide-scope sentence — legitimately occurs at three enumeration-mandating sites,
#     so an exactly-once pin cannot hold; a count-equals-3 guard is the harness idiom for a value
#     that recurs. A dropped or wrapped-across-lines site makes this RED (below-3), fail-closed.
#     SEMANTIC SIBLING the count deliberately EXCLUDES (#613): the Consumers-axis evidence floor's
#     sweep leg states the same repo-wide-enumeration contract in PARAPHRASE, not with the canonical
#     sentence above — a recorded decision, because carrying the canonical sentence would break this
#     exactly-3 count. A textual sweep for the canonical sentence therefore cannot find the
#     paraphrase, so the linkage is recorded here instead: an edit to the canonical sentence must
#     reconcile the paraphrase in the same change. The paraphrase's operative scope clause is pinned
#     separately below so it cannot be dropped silently.
assert_eq "#593: extension repo-wide-scope sentence present at exactly 3 enumeration sites" "3" \
  "$(devflow_module_pin_count 'a directory-scoped sweep does not discharge enumeration' "$CI_EXT")"
devflow_module_pin_unique "#613: Consumers-axis floor's sweep-leg paraphrase of the repo-wide-scope contract" \
  'executed repo-wide whitespace-normalized sweep' "$CI_EXT"
# (4) docs/cloud-setup.md consumer timing sentence.
devflow_module_pin_unique "#593: docs/cloud-setup.md states in-PR grants take effect only post-merge" \
  'takes effect only after that PR merges, because the workflows resolve grants at trigger time' "$CI_CLOUD_SETUP"
# (5) docs/implement-skill.md consumer timing sentence.
devflow_module_pin_unique "#593: docs/implement-skill.md states in-PR grants take effect only post-merge" \
  'is live only after that PR merges, because the workflows resolve config grants at trigger time' "$CI_IMPL_DOC"

# ── issue #548: evidence-bundle sub-pass + actionability/convergence contracts (prose pins).
#    All surface-presence contract pins on new feature prose (devflow_module_pin_unique) — NOT
#    behavioral-fix pins, so no devflow_module_pin_red_under mutation obligation attaches (matching the
#    suite's precedent for this pin class; the #546/#548 state-owner behavior is covered
#    behaviorally in lib/test/test_python_scripts.py and the CLI block below).
devflow_module_pin_unique "#548: evidence-bundle axis floor sentence" \
  'covering **at minimum** these generic axes: authoritative producers and the values they emit' "$CI_SKILL"
devflow_module_pin_unique "#548: entry-form — an axis with no entry is not a legal bundle state" \
  'an axis with no entry is not a legal bundle state' "$CI_SKILL"
devflow_module_pin_unique "#548: proportionality scope-inference clause" \
  'N/A — checked: scope inference' "$CI_SKILL"
devflow_module_pin_unique "#548: self-describing header sentence" \
  'opens with a compact fixed header restating the three entry forms' "$CI_SKILL"
devflow_module_pin_unique "#548: bundle-coverage gate fires at the same two sites" \
  'The bundle-coverage gate fires at the **same two sites**' "$CI_SKILL"
devflow_module_pin_unique "#548: bundle-currency three-triggers sentence" \
  'additionally re-checks bundle currency against **three triggers**' "$CI_SKILL"
devflow_module_pin_unique "#548: approach-fork (Recommended)-citation sentence" \
  'one-line why cites at least one bundle entry by axis name' "$CI_SKILL"
devflow_module_pin_unique "#548: unestablished-axes disclosure sentence" \
  'discloses by name every effective-list axis that is' "$CI_SKILL"
devflow_module_pin_unique "#548: no-citation-grade arm withholds the marking visibly" \
  'marking and its rationale states that no citation-grade evidence exists' "$CI_SKILL"
devflow_module_pin_unique "#548: heading-extraction rule (defined once, both hooks)" \
  'duplicate same-heading sections are concatenated in file order' "$CI_SKILL"
devflow_module_pin_unique "#548: dual-heading independence — each hook at its own site" \
  'The two hooks are extracted independently at their own consumption sites' "$CI_SKILL"
devflow_module_pin_unique "#548: loader-failure arm records the dedicated line" \
  'consumer axes: unestablished — loader denied or failed' "$CI_SKILL"
devflow_module_pin_unique "#548: ## Evidence axes forwarding sentence (SKILL contract, exact heading)" \
  'appends any section headed exactly' "$CI_SKILL"
devflow_module_pin_unique "#548: ## Evidence axes forwarding (live extension carries the exact heading)" \
  '## Evidence axes' "$CI_EXT"

# ── issue #611: Step 3.6 ergonomics bundle — surface-presence pins ───────────
# Surface-presence class: these pin that a decided sentence is PRESENT in the prompt
# surface, which is the only property a prose contract has. They carry no mutation
# obligation — the behavioral halves of this
# bundle (the loader's extraction and the tool's arm-selected breadcrumb) are pinned
# by executable tests in lib/test/run.sh and lib/test/test_python_scripts.py, where a
# planted defect really can be driven.

# AC1 — `--round` is required on EVERY record-dispatch arm, not just the inline pair.
# The prose used to state the requirement only in the Degraded/inline bullet, so a run
# following the file-arm or embed-retry sentence verbatim burned a turn on an argparse
# usage error. Pin both amended call sites and the widened note.
devflow_module_pin_unique "#611 AC1: the file-arm dispatch-recording sentence shows --round" \
  'record-dispatch --arm <the answered arm> --round "<round>"' "$CI_SKILL"
devflow_module_pin_unique "#611 AC1: the DRAFT-UNREADABLE embed-retry variant shows --round" \
  'record-dispatch --arm embed --marker file-unreadable --round "<round>"' "$CI_SKILL"
devflow_module_pin_unique "#611 AC1: the flag-requirement note spans every arm, not just the inline pair" \
  'required** on **every** `record-dispatch` arm' "$CI_SKILL"

# AC2 — the edit-sequencing rule, stated ONCE at the digest-binding paragraph. Its
# load-bearing clause is the prohibition: a bare record-revision-then-record-override
# pair would re-arm a user election the user never made, so eligibility would be
# grounded on consent that was never given.
devflow_module_pin_unique "#611 AC2: edit-sequencing rule is stated once, scoped to digest-bound overrides" \
  'Edit-sequencing rule (stated once, here, for digest-bound overrides only)' "$CI_SKILL"
devflow_module_pin_unique "#611 AC2: the recovery never sanctions a bare re-record pair" \
  'never a bare record-revision-then-record-override pair' "$CI_SKILL"
# The two Step 4 override sites must keep REFERENCING the digest binding without
# restating the rule — one specification of record, per AC2.
assert_eq "#611 AC2: the sequencing rule is not restated at the Step 4 override sites" \
  "1" "$(devflow_module_pin_count 'completes **before** a digest-bound override is recorded' "$CI_SKILL")"

# AC6 — the Step 2 sentence stays the specification of record, now carrying the
# terminator precision and naming its single implementation. The '## '-plus-space
# precision is what makes a `###` sub-heading section CONTENT rather than a
# terminator; the older bare-`##` wording admitted the opposite reading.
devflow_module_pin_unique "#611 AC6: the terminator is '## ' — two hashes plus a space" \
  'two hashes PLUS A SPACE' "$CI_SKILL"
devflow_module_pin_unique "#611 AC6: an unclosed fence runs to end of file" \
  'an unclosed fence runs to end of file' "$CI_SKILL"
devflow_module_pin_unique "#611 AC6: the rule names the loader as its single implementation (coupled pair)" \
  'is its single implementation (a coupled pair, edited together)' "$CI_SKILL"
devflow_module_pin_unique "#611 AC6: empty-section vs absent-heading now differ by the stderr breadcrumb" \
  'an empty section stays breadcrumb-free' "$CI_SKILL"
# The four re-load sites name the sectioned form. Two hooks, two sites each.
assert_eq "#611 AC6: two re-load sites request the '## Evidence axes' section" \
  "2" "$(devflow_module_pin_count "load-prompt-extension.sh create-issue --section '## Evidence axes'" "$CI_SKILL")"
assert_eq "#611 AC6: two re-load sites request the '## Audit dimensions' section" \
  "2" "$(devflow_module_pin_count "load-prompt-extension.sh create-issue --section '## Audit dimensions'" "$CI_SKILL")"
# The shared wiring sentence is present at ALL FOUR sites — a report-then-proceed step
# stated at only some of them is exactly the peer-asymmetry defect the repo's
# peer-checkpoint sweep exists to catch, and it would read as correct in a diff.
assert_eq "#611 AC6: the report-then-proceed wiring is present at all four re-load sites" \
  "4" "$(devflow_module_pin_count 'a **report-then-proceed** step, never a stall, a user question, or a degraded-arm claim' "$CI_SKILL")"
assert_eq "#611 AC6: the exit-2-is-unestablished wiring is present at all four re-load sites" \
  "4" "$(devflow_module_pin_count 'never laundered into the designed absent-heading no-op' "$CI_SKILL")"
# The amended no-op sentence, at both of its occurrences (Step 2 and Step 3.6).
assert_eq "#611 AC6: both no-op sentences state the absent heading is now breadcrumbed" \
  "2" "$(devflow_module_pin_count 'that absent heading is now breadcrumbed and reported rather than invisible' "$CI_SKILL")"
# AC8 names this one specifically: the Step 3.6 parenthetical is reduced to a pure
# reference, so no second full statement of the rule survives anywhere in the file.
devflow_module_pin_unique "#611 AC6/AC8: the Step 3.6 restatement is reduced to a pure reference" \
  'that sentence is the specification of record for both hooks and is not restated here' "$CI_SKILL"
# Pin a phrase that EXISTS and whose loss would mean the rule stopped being stated, not the
# absence of a wording that never appeared in the file — an absence pin on a never-present
# string passes under any reworded restatement, so it polices nothing.
assert_eq "#611 AC6: the extraction rule's terminator precision is stated exactly once" \
  "1" "$(devflow_module_pin_count 'two hashes PLUS A SPACE' "$CI_SKILL")"
devflow_module_pin_unique "#548: bounded actionability definitions (must-revise)" \
  'a verified correctness, safety, implementability, unresolved-decision, or load-bearing-premise defect' "$CI_SKILL"
devflow_module_pin_unique "#548: VERDICT: FILE may carry advisory findings" \
  'may carry advisory findings' "$CI_SKILL"
devflow_module_pin_unique "#548: VERDICT: REVISE requires a verified unresolved must-revise finding" \
  'requires at least one verified unresolved must-revise finding' "$CI_SKILL"
devflow_module_pin_unique "#548: Quiet-Killer becomes an assessed one-or-none slot" \
  'report at most one qualifying Quiet Killer, or explicitly report' "$CI_SKILL"
devflow_module_pin_unique "#548: post-adjudication T1 sentence" \
  "T1 consumes the latest completed round's post-adjudication unresolved must-revise findings" "$CI_SKILL"
devflow_module_pin_unique "#548: fail-closed T2 gains the unadjudicated-round arm" \
  'T2 gains one new fail-closed arm (the `unadjudicated-round` arm)' "$CI_SKILL"
devflow_module_pin_unique "#548: convergence-definition sentence" \
  'a converged run is one whose final accepted, post-adjudication verdict is' "$CI_SKILL"
devflow_module_pin_unique "#548: Step 3.5 summary reports the evidence bundle's coverage" \
  "The summary additionally reports the evidence bundle's coverage" "$CI_SKILL"
devflow_module_pin_unique "#548: Step 4 audit summary reports the bundle's coverage + actionability" \
  "The Step 4 audit summary line reports the bundle's coverage" "$CI_SKILL"
# ── issue #465: within-text multi-state-contract reconciliation (prose + pins). Reuses the
#    #312/#443 create-issue file vars (CI_SKILL, CI_TMPL, CI_EXT) + CI_OVERVIEW.
#    Each pin is a behavioral-fix pin: its literal IS an operative sentence whose removal
#    re-introduces the unreconciled-contract gap, so it is expressed through devflow_module_pin_red_under
#    with a `sed -E` mutation that strips a load-bearing fragment of the operative sentence
#    (framing-only survives → RED here). (a)–(d) pin the four coupled-mirror contract surfaces;
#    (e)/(f) additionally pin the Step 3.5 target's scope-honesty and no-burden operative clauses
#    (the "Scope honesty" / "No burden on non-contract issues" ACs), so every AC's operative prose
#    maps to ≥1 assertion — the same bidirectional-orphan discipline this issue itself adds.
# (a) Step 3.5 hunt gains the within-text contract-reconciliation target.
devflow_module_pin_red_under "#465 (a): Step 3.5 names the within-text multi-state-contract reconciliation target" \
  'no summary or table form lists fewer causes for a state than the detailed per-state ACs' \
  's/lists fewer causes for a state/REMOVED/' "$CI_SKILL"
# (b) Template Move 3 orphan sentence folds the enumerated-state→AC clause.
devflow_module_pin_red_under "#465 (b): template folds the every-enumerated-contract-state-maps-to-an-AC clause" \
  'every state a multi-state contract enumerates' \
  's/multi-state contract enumerates/CONTRACT/' "$CI_TMPL"
# (c) Prompt-extension Coupled-mirror-sites gains the source-reconciled-before-propagation sentence.
devflow_module_pin_red_under "#465 (c): extension sharpens Coupled mirror sites — source reconciled before propagation" \
  'the source form must itself be internally reconciled before it is propagated' \
  's/internally reconciled before it is propagated/IGNORED/' "$CI_EXT"
# (d) SYSTEM_OVERVIEW §11 Self-steelman enumeration reconciled to include the new target.
devflow_module_pin_red_under "#465 (d): SYSTEM_OVERVIEW §11 Self-steelman enumeration includes the new target" \
  'unstated scope, and an unreconciled multi-state contract' \
  's/an unreconciled multi-state contract/REMOVED/' "$CI_OVERVIEW"
# (e) Step 3.5 target carries the scope-honesty operative clause ("Scope honesty" AC).
devflow_module_pin_red_under "#465 (e): Step 3.5 target scopes to the draft's own forms (no not-yet-written-implementation claim)" \
  'makes **no** claim to catch a state that only a not-yet-written implementation will emit' \
  's/not-yet-written implementation will emit/REMOVED/' "$CI_SKILL"
# (f) Step 3.5 target carries the no-burden-on-non-contract-issues operative clause ("No burden…" AC).
devflow_module_pin_red_under "#465 (f): Step 3.5 target draws no new hunt/question/revision on a non-contract draft" \
  'a draft that states none draws no new hunt, question, or revision' \
  's/draws no new hunt, question, or revision/REMOVED/' "$CI_SKILL"
# (g) Consumer-agnostic ABSENCE pin (the issue's Testing-Strategy coverage-dimension (e)).
#     (a)–(f) are all positive-presence pins, so a future edit injecting a DevFlow-internal
#     reference into a body that ships into consumer repos would pass them all. Assert the two
#     consumer-installed create-issue bodies name no repo-internal test path / CI job name.
#     `devflow_implement.allowed_tools` is deliberately NOT banned: it is a consumer-facing
#     config key (consumers set it themselves), not a DevFlow-repo-internal token.
for CI465_TOK in 'lib/test/run.sh' 'lib + python tests'; do
  assert_eq "#465 (g): create-issue SKILL stays consumer-agnostic — no '$CI465_TOK'" \
    "0" "$(devflow_module_pin_count "$CI465_TOK" "$CI_SKILL")"
  assert_eq "#465 (g): create-issue template stays consumer-agnostic — no '$CI465_TOK'" \
    "0" "$(devflow_module_pin_count "$CI465_TOK" "$CI_TMPL")"
  # Non-vacuity proof: an absence pin over a token the detector could never match is a guard
  # that cannot fail. Inject the token into a copy and confirm the SAME detector reports it —
  # so the `0` above is evidence of a clean body, not of a blind grep. Asserted as a DELTA
  # (injected count == clean count + 1), not as the absolute `1`: the absolute form silently
  # depends on the source being clean, so a body that already carried the token would fail this
  # proof with the message "injected token is NOT detected" — the exact inverse of what happened.
  CI465_INJ="$_ci_tmp_root/ci465-inj"
  { cat "$CI_SKILL"; printf 'the pins live in %s (injected)\n' "$CI465_TOK"; } > "$CI465_INJ"
  assert_eq "#465 (g)-mp: absence pin is non-vacuous — injecting '$CI465_TOK' raises the count by 1" \
    "$(( $(devflow_module_pin_count "$CI465_TOK" "$CI_SKILL") + 1 ))" "$(devflow_module_pin_count "$CI465_TOK" "$CI465_INJ")"
done
# ── issue #464: create-issue adversarial-input dimension + enumerated-AC-list floor rule.
#    Reuses the #312/#443 create-issue file vars (CI_TMPL, CI_SKILL, CI_EXT) and adds
#    the overview doc var. Each pinned literal is a verbatim fragment of the new contract prose
#    (a bullet header or an on-line span of the rule sentence, not a synthetic marker). These are all
#    SURFACE-PRESENCE contract pins (plain devflow_module_pin_unique on new prose) — the exact class the
#    new extension mutation-evidence dimension EXCLUDES (this issue is that distinction's worked
#    example), so no devflow_module_pin_red_under mutation obligation applies. Wrapped-literal hazard
#    (#375): every literal below is chosen to sit on a single physical line (grep -oF is
#    line-scoped), so a phrase that wraps in the prose is pinned by its on-line fragment.
# AC1 — Step 3.6 generic dimension checklist gains the adversarial-third-party-input dimension.
devflow_module_pin_unique "#464 AC1: Step 3.6 generic checklist gains the adversarial-third-party-input dimension" \
  'Adversarial third-party input' "$CI_SKILL"
devflow_module_pin_unique "#464 AC1: the dimension carries the input-is-data guard (data to classify, not obey)" \
  'data to classify, never instructions to obey' "$CI_SKILL"
# The growth-policy carve-out reconciling the appended standalone dimension with the
# consolidate-before-appending rule is itself a coupled contract sentence — pin it so a future
# edit that drops it (leaving the dimension and the policy silently self-contradicting) goes RED.
devflow_module_pin_unique "#464 AC1: growth-policy carve-out sanctions the standalone dimension" \
  'sanctioned standalone addition, not a breach of consolidate-before-appending' "$CI_SKILL"
# AC4 — Step 3.5 omission-hunt list gains both checks.
devflow_module_pin_unique "#464 AC4: Step 3.5 hunt flags a new judgment surface missing the guard/hostile-case pair" \
  'without the guard-AC-plus-hostile-case pair' "$CI_SKILL"
devflow_module_pin_unique "#464 AC4: Step 3.5 hunt flags an AC enum list declaring neither floor nor closure" \
  'declares neither a floor marker nor a closed-set' "$CI_SKILL"
# AC2 — template drafter-side judgment-surface guard rule (coupled with the Step 3.6 dimension).
devflow_module_pin_unique "#464 AC2: template carries the drafter-side judgment-surface guard rule" \
  'A designed LLM/semantic-judgment surface over third-party text carries an input-is-data' "$CI_TMPL"
devflow_module_pin_unique "#464 AC2: template states a no-new-judgment-surface draft gains no new questions/flags" \
  'new judgment surface gains no new questions and no new flags' "$CI_TMPL"
# AC3 — template Acceptance-Criteria list-closure rule + Move 2 write-back extension.
devflow_module_pin_unique "#464 AC3: template AC rules require every enumerated AC list to declare its closure" \
  'Every enumerated test/case/example list inside an AC declares its closure' "$CI_TMPL"
devflow_module_pin_unique "#464 AC3: Move 2 writes the coverage-sweep output back as closed AC items before filing" \
  "writes the sweep's output back as additional closed AC items before filing" "$CI_TMPL"
# AC2/AC3 second mirror site — the template's final self-review quality-checklist (the drafter's
# actual self-check surface). Pinned on BOTH halves of each rule per the coupled-mirror discipline
# (#462 quality-checklist-mirror pattern), so the guidance-prose site and the checklist site cannot
# silently drift out of agreement.
devflow_module_pin_unique "#464 AC2: quality-checklist mirror line for the judgment-surface guard rule" \
  'carries the input-is-data guard AC paired with a hostile-input' "$CI_TMPL"
devflow_module_pin_unique "#464 AC3: quality-checklist mirror line for the enumerated-AC-list closure rule" \
  'each floor-marked list has had Move 2' "$CI_TMPL"
# AC5 — extension gains the mutation-evidence dimension, scoping surface-presence pins OUT.
devflow_module_pin_unique "#464 AC5: extension gains the mutation-evidence dimension for behavioral-fix pins" \
  'Mutation evidence for behavioral-fix pins (issue #464)' "$CI_EXT"
devflow_module_pin_unique "#464 AC5: mutation-evidence dimension excludes surface-presence contract pins" \
  'Surface-presence contract pins' "$CI_EXT"
# AC6/AC7 — overview §11 documents both seams and records the Stage-B auditor-side deferral.
devflow_module_pin_unique "#464 AC7: overview §11 documents the two new create-issue seams" \
  'Adversarial-input dimension and enumerated-list floor rule (issue #464)' "$CI_OVERVIEW"
devflow_module_pin_unique "#464 AC6: overview §11 records the deliberate Stage-B auditor-side deferral" \
  'extending the audit seams into Stage B is a separate change' "$CI_OVERVIEW"

# ── issue #559: Revision-delta verification — coverage guard + prose pins ──
#    The shared "Revision-delta verification" procedure is stated once in the
#    create-issue skill and referenced by every revise-and-re-gate sentence. This
#    guard is the PERSISTENT wiring enforcement (not a one-shot enumeration): it
#    whitespace-normalizes the skill and classifies EVERY `no-options gate`
#    occurrence into wired-site hit / definition-block occurrence / enumerated
#    non-command allowlist entry, RED on any unresolved occurrence, and RED when the
#    wired-site bin is empty (zero-hit floor). A gate-mentioning revise sentence
#    added/moved/reworded — or a novel-verb variant — arrives RED until wired or
#    knowingly allowlisted. Reuses the #312/#443 create-issue file var CI_SKILL
#    and the shared overview-doc var CI_OVERVIEW.

# ci559_classify FILE -> prints "bin1=N bin2=N bin3=N unresolved=N" on stdout
# (per-unresolved diagnostics to stderr). The two key phrases, the by-name
# reference token, the per-hit adjacency window, the definition-block heading, and
# the enumerated non-command allowlist (the drafting-time explanatory
# `no-options gate` mentions — the ALLOW list below is the source of truth for that
# set) are all defined verbatim below.
ci559_classify() {  # skill-file -> summary line on stdout
  python3 - "$1" <<'PY'
import sys, re
src = open(sys.argv[1], encoding='utf-8').read()
norm = re.sub(r'\s+', ' ', src)
TARGET = 'no-options gate'
KEY_PREFIXES = ['re-run the Step 3 ', 're-run the ']   # the two key phrases (prefix + TARGET)
REF = 'Revision-delta verification'                    # the by-name procedure reference
WINDOW = 64                                            # fixed fail-closed positional contract
DEF_HEAD = '### Revision-delta verification'           # definition-block heading
ALLOW = [                                              # full-context non-command allowlist
    'Draft the issue and pass the **no-options gate** (Step 3)',
    'Steelman the draft against the code, revise, and re-pass the no-options gate (Step 3.5)',
    'the no-options gate (Step 3) still governs the final body',
    '### Step 3: Draft the issue and pass the no-options gate',
    'immediately after the no-options gate passes and before Step 4 presents anything',
    'and neither is a clean no-options gate',
]
ds = norm.find(DEF_HEAD)
de = -1 if ds == -1 else norm.find('### ', ds + len(DEF_HEAD))
if ds != -1 and de == -1:
    de = len(norm)
allow_idx = set()
for e in ALLOW:
    off = e.find(TARGET); start = 0
    while True:
        p = norm.find(e, start)
        if p == -1: break
        allow_idx.add(p + off); start = p + 1
L = len(TARGET)
bin1 = bin2 = bin3 = unresolved = 0
i = 0
while True:
    idx = norm.find(TARGET, i)
    if idx == -1: break
    i = idx + 1; end = idx + L
    if ds != -1 and ds <= idx < de:       # bin 2: definition-block occurrence
        bin2 += 1; continue
    is_kp = any(idx-len(p) >= 0 and norm[idx-len(p):idx] == p for p in KEY_PREFIXES)
    if is_kp:                             # bin 1 candidate: a key-phrase occurrence
        if REF in norm[end:end+WINDOW]:
            bin1 += 1
        else:                            # a wired site missing its adjacent reference
            unresolved += 1
            sys.stderr.write('UNRESOLVED-KEYPHRASE: ...%s...\n' % norm[max(0,idx-25):end+WINDOW])
        continue
    if idx in allow_idx:                  # bin 3: enumerated non-command allowlist entry
        bin3 += 1; continue
    unresolved += 1                       # anything else is unresolved -> RED
    sys.stderr.write('UNRESOLVED-OTHER: ...%s...\n' % norm[max(0,idx-25):end+25])
print('bin1=%d bin2=%d bin3=%d unresolved=%d' % (bin1, bin2, bin3, unresolved))
PY
}

# Extract the integer value of field $2 from a "binN=.. unresolved=.." summary with
# bash builtins. This value decides assertions, so no grep/sed pipeline may silently
# empty it when a non-preflight PATH tool is absent.
ci559_field() {
  local field
  for field in $1; do
    case "$field" in
      "$2="*) printf '%s' "${field#*=}"; return 0 ;;
    esac
  done
  return 1
}

CI559_SUM="$(ci559_classify "$CI_SKILL")"
CI559_B1="$(ci559_field "$CI559_SUM" bin1)"
CI559_B2="$(ci559_field "$CI559_SUM" bin2)"
CI559_U="$(ci559_field "$CI559_SUM" unresolved)"
# Total classification: no `no-options gate` occurrence is left unresolved.
assert_eq "#559: every no-options gate occurrence is classified (0 unresolved)" "0" "$CI559_U"
# Zero-hit floor: the wired-site bin is non-empty — a restructure that eliminates
# every wired site is a loud failure, never a vacuous green.
assert_eq "#559: zero-hit floor — the wired-site bin is non-empty" "ok" \
  "$([ "${CI559_B1:-0}" -ge 1 ] && echo ok || echo empty)"
# The six canonical revise-and-re-gate sites and the one definition-block occurrence
# are exact. These pins close whole-site deletion: deleting a complete command and its
# adjacent reference cannot hide behind the non-empty floor or unresolved=0.
assert_eq "#559: all six canonical revise-and-re-gate sites remain wired" "6" "$CI559_B1"
assert_eq "#559: the definition block contributes exactly one classified occurrence" "1" "$CI559_B2"
# Mutation rows plant their fixtures under the module's private temp root rather
# than skipping: inability to allocate the proof means the detector was not
# exercised, so reporting a skip would weaken the issue's planted-defect AC (and
# modules may not self-skip in any case).
# Planted-defect positive control: an unwired key-phrase sentence planted in a
# mutated copy is an UNRESOLVED occurrence — the guard's detection claim exercised,
# not attested (recorded observed RED in the PR).
CI559_PLANT="$_ci_tmp_root/ci559-plant"
{ cat "$CI_SKILL"; printf '\nThen re-run the Step 3 no-options gate and stop.\n'; } > "$CI559_PLANT"
assert_eq "#559: planted-defect positive control — an unwired key-phrase sentence is unresolved (guard RED)" \
  "1" "$(ci559_field "$(ci559_classify "$CI559_PLANT")" unresolved)"
rm -f "$CI559_PLANT"
# Novel-verb control: a revise sentence phrased with a different verb ('pass the
# revised draft through the no-options gate') is unresolved until wired/allowlisted
# — total classification closes the variant-verb gap.
CI559_NOVEL="$_ci_tmp_root/ci559-novel"
printf 'x pass the revised draft through the no-options gate now.\n' > "$CI559_NOVEL"
assert_eq "#559: total classification flags a novel-verb gate mention as unresolved" \
  "1" "$(ci559_field "$(ci559_classify "$CI559_NOVEL")" unresolved)"
rm -f "$CI559_NOVEL"
# Allowlist-collision control: the live explanatory `re-pass` wording is allowlisted
# only in its full list-item context. Reusing the short phrase as a revision command
# must remain unresolved rather than silently falling into bin 3.
CI559_COLLIDE="$_ci_tmp_root/ci559-collide"
printf 'Revise the draft and re-pass the no-options gate.\n' > "$CI559_COLLIDE"
assert_eq "#559: a command reusing an allowlisted verb does not evade adjacency wiring" \
  "1" "$(ci559_field "$(ci559_classify "$CI559_COLLIDE")" unresolved)"
rm -f "$CI559_COLLIDE"

# Input-shape matrix rows (issue #559 Testing Strategy — the mutable-markdown
# malformed-shape matrix per CLAUDE.md's best-effort-parser convention: the guard is
# a reader of agent-mutable markdown, so each degenerate input shape is asserted to
# fail closed).
# (a) Empty input → the wired-site bin is empty → the zero-hit floor goes RED.
CI559_EMPTY="$_ci_tmp_root/ci559-empty"
: > "$CI559_EMPTY"
assert_eq "#559 shape: empty input → the wired-site bin is empty (zero-hit floor RED)" \
  "0" "$(ci559_field "$(ci559_classify "$CI559_EMPTY")" bin1)"
rm -f "$CI559_EMPTY"
# (b) Absent target file → the classifier prints an empty summary, so the total-
# classification assert compares "0" against "" and goes RED (fail-closed, never a
# vacuous pass) — asserted here as the empty-summary signal that drives that RED.
assert_eq "#559 shape: absent target file → empty summary (total-classification assert would go RED)" \
  "" "$(ci559_field "$(ci559_classify /nonexistent/no-options-gate-file.md 2>/dev/null)" unresolved)"
# (c) Allowlist-bin positive control: the enumerated non-command mentions land in
# bin3 on the live skill. The exact count is deliberate, not a lower bound: every
# allowlist entry must match one live occurrence so stale or duplicate exemptions
# cannot accumulate and silently reclassify a future command.
assert_eq "#559 shape: the enumerated allowlist mentions land in bin3 on the live skill" \
  "6" "$(ci559_field "$CI559_SUM" bin3)"
# (d) Boundary-hostile: a correctly-wired gate mention whose key phrase and by-name
# reference are separated by a period-bearing path literal still classifies as a
# wired site (unresolved=0), proving the contract is positional adjacency — not
# sentence-boundary recovery, which a period-bearing path literal defeats (the reason
# the wiring is adjacency-based).
CI559_BND="$_ci_tmp_root/ci559-bnd"
printf 'x revise, then re-run the no-options gate (see e.g. lib/foo.sh). Then run **Revision-delta verification** now.\n' > "$CI559_BND"
assert_eq "#559 shape: a period-bearing literal between the gate phrase and the reference still classifies as wired (adjacency, not sentence-boundary)" \
  "0" "$(ci559_field "$(ci559_classify "$CI559_BND")" unresolved)"
rm -f "$CI559_BND"

# Prose pins (AC 14). The always-run trigger sentence is a behavioral-fix pin:
# removing the "at every revision event" qualifier re-introduces the #555-class
# regression (a revision reaching filing with only the no-options gate), so it is
# expressed through devflow_module_pin_red_under with a mutation that strips that qualifier.
devflow_module_pin_red_under "#559: always-run trigger carries the at-every-revision-event qualifier" \
  'runs **at every revision event** — before any re-audit dispatch at that site and before any presentation of the revised draft' \
  's/at every revision event/sometimes/' "$CI_SKILL"
# The remaining new load-bearing sentences carry surface-presence pins.
devflow_module_pin_unique "#559: the Revision-delta verification procedure is stated once as a named block" \
  '### Revision-delta verification (shared procedure — referenced by every revise-and-re-gate site)' "$CI_SKILL"
devflow_module_pin_unique "#559: per-class walk records one entry per class, else a stated falsifiable zero" \
  "one compact entry per class — the class's enumerated items, else a stated falsifiable zero" "$CI_SKILL"
devflow_module_pin_unique "#559: an all-zeros walk ends the batch's work at the walk record" \
  "An all-zeros walk ends the batch's work at the walk record." "$CI_SKILL"
devflow_module_pin_unique "#559: the inline fix loop walks the fix and terminates on an all-zeros walk" \
  'walk the fix as its own edit-batch; a batch whose walk is all-zeros ends the loop.' "$CI_SKILL"
devflow_module_pin_unique "#559: closing evidence line — enumerated/verified/fixed format literal" \
  'revision-delta check: <N> enumerated, <V> verified, <F> fixed' "$CI_SKILL"
devflow_module_pin_unique "#559: closing evidence line — no-verifiable-delta format literal" \
  'revision-delta check: no verifiable delta' "$CI_SKILL"
devflow_module_pin_unique "#559: the five per-site evidence-line anchors are enumerated" \
  "at Step 3.5's item 5, immediately after that item's gate re-run; at Step 3.5's item 6, immediately before the initial Step 3.6 dispatch's pre-dispatch draft write" "$CI_SKILL"
# SYSTEM_OVERVIEW §11 documents the procedure in both revise-loop descriptions (AC 13).
devflow_module_pin_unique "#559: overview §11 (Step 3.5 loop) documents the Revision-delta verification procedure" \
  "walks the revision's edit-batch delta across six classes" "$CI_OVERVIEW"
devflow_module_pin_unique "#559: overview §11 (Step 3.6/Step 4 loop) documents the Revision-delta verification procedure" \
  "runs the shared **Revision-delta verification** procedure over the revision's delta" "$CI_OVERVIEW"

# ── issue #613: shift-left evidence disciplines in the live create-issue extension —
#    an executed-sweep floor on the consumers axis, closed-set complement entries, a
#    pre-merge obligation walk, success-path channels, and a self-referential-count gate
#    scan. Surface-presence contract pins on new prose, plus one negative repo-wide sweep
#    (AC10) and its rc-class anti-vacuity rows. Same disposition as the #548/#464/#593 blocks
#    above: none pins a behavioral guarantee whose half-revert re-introduces a named bug, so
#    no devflow_module_pin_red_under mutation obligation attaches.
# AC1 — Consumers-axis evidence floor (## Evidence axes section prose).
devflow_module_pin_unique "#613 AC1: extension ## Evidence axes carries the Consumers-axis evidence floor" \
  'Consumers-axis evidence floor (this repo).' "$CI_EXT"
# Pin the WHOLE verdict phrase, not just the trailing state: `unestablished` is the operative
# token that makes this arm fail closed. A literal of `consumers not swept` alone would stay
# GREEN if the arm were inverted to `Verified: consumers not swept` — the exact
# evidence-laundering the floor exists to prevent.
devflow_module_pin_unique "#613 AC1: the floor's unestablished arm names the un-swept consumers state" \
  'unestablished — consumers not swept' "$CI_EXT"
# The floor is a CONJUNCTION; this clause is what stops a drafter discharging it with reads
# alone. Softening it to "or" would leave the two sweep-leg pins green.
devflow_module_pin_unique "#613 AC1: the floor's two legs are non-substitutable (conjunction, not either-or)" \
  'so neither leg substitutes for the other' "$CI_EXT"
# AC2 — Closed-set complement entries (## Evidence axes section prose).
devflow_module_pin_unique "#613 AC2: extension ## Evidence axes carries the closed-set complement entry rule" \
  'Closed-set complement entries (this repo).' "$CI_EXT"
devflow_module_pin_unique "#613 AC2: the complement rule names its six-shape-matrix sibling relation" \
  'set-membership sibling of the six-shape JSON matrix' "$CI_EXT"
# AC5 — authoring-discipline shape (1) gains the success-path-channel check.
devflow_module_pin_unique "#613 AC5: shape (1) flags a measurement AC naming no success-path channel" \
  'measurement or equality AC that names no success-path channel' "$CI_EXT"
# AC3 — authoring-discipline shape (2) gains the closed-set complement flag.
devflow_module_pin_unique "#613 AC3: shape (2) flags a closed set whose complement is never analyzed" \
  'closed set the draft'"'"'s mechanism defines' "$CI_EXT"
# AC4 — authoring-discipline shape (4) gains the pre-merge temporal walk.
devflow_module_pin_unique "#613 AC4: shape (4) walks the obligation as the pre-merge implementing run resolves it" \
  'as the pre-merge implementing run resolves it' "$CI_EXT"
# AC7 — the self-referential-count defect class, and the count-free parenthetical rewrite.
devflow_module_pin_unique "#613 AC7: authoring-discipline bullet carries defect class (5), self-referential counts" \
  'self-referential count or ordinal' "$CI_EXT"
devflow_module_pin_unique "#613 AC7: the cross-cutting parenthetical is count-free" \
  'not an additional defect class' "$CI_EXT"
assert_eq "#613 AC7: the rotted 'fourth defect class' ordinal is gone from the extension" "0" \
  "$(devflow_module_pin_count 'not a fourth defect class' "$CI_EXT")"
# AC6 — the new no-options-gate scan section, outside both hook sections.
devflow_module_pin_unique "#613 AC6: extension carries the no-options-gate self-referential count scan heading" \
  '## No-options gate — self-referential count scan (this repo)' "$CI_EXT"
devflow_module_pin_unique "#613 AC6: the gate scan states the drift the count class exhibits" \
  'moment a revision adds or removes an item it counts' "$CI_EXT"
# The gate scan defines a closed set (the draft's own self-referential counts); this sentence is
# its COMPLEMENT — the sole false-positive suppressor separating "rewrite the draft's own counts"
# from "rewrite counts in quoted evidence". Leaving it unpinned would ship exactly the unguarded
# complement that AC2/AC3's own closed-set rule, shipped in this same change, forbids.
devflow_module_pin_unique "#613 AC6: the gate scan's complement — quoted external counts are exempt" \
  'Counts inside verbatim-quoted external text are exempt' "$CI_EXT"
# AC10 — the overview's stale axis enumeration is retired repo-wide. The module itself
# necessarily carries the phrase as this grep's own needle, so the sweep excludes this
# file by pathspec; an unexcluded sweep could never reach zero. Any OTHER tracked hit is
# a surviving stale mirror and turns the module RED.
# FAIL-CLOSED, and deliberately not `cd "$CI_ROOT" && git grep … | grep -c . || true`. In that
# form a bad pathspec (or any git fatal) exits 128 while the pipeline still runs, so `grep -c`
# prints the very `0` a zero-expected assertion wants and `|| true` hides the rc — a VACUOUS
# pass, the rc-masquerade hole lib/test/run.sh's rgb_scan documents. (A failed `cd` is not that
# hole: `&&` binds looser than `|`, so the pipeline never runs and the substitution yields ""
# rather than "0" — measured, not assumed. Only the git-fatal arm was vacuous.) So: `git -C`
# keeps git the only rc-bearing command, the expected value is the empty file LIST (naming the
# offending path on failure, not a digit), and an rc > 1 becomes a non-numeric sentinel that can
# never equal "". `grep` is absent from THIS derivation — it is not preflight-guaranteed and
# this value decides an assertion. (Scoped claim: the sibling awk|grep bullet counters above
# predate this block; they fail closed, so they are consistent, not covered by this sentence.)
# Both pathspecs are repo-root-anchored (`:/`, `:(exclude,top)`) so a CI_ROOT override pointing
# inside a repo subtree cannot silently narrow a "repo-wide" sweep to a subdirectory — the very
# thing the extension's own repo-wide-scope sentence forbids.
_ci613_classify() {  # <rc> <hits> -> hits, or the sentinel when the scan itself errored
  if [ "$1" -gt 1 ]; then printf '%s' '<ac10-sweep-errored>'; else printf '%s' "$2"; fi
}
_ci613_scan() {  # <root> <needle> -> the tracked-tree hit list, fail-closed via _ci613_classify
  _ci613_out=$(git -C "$1" grep -F -l "$2" \
    -- ':/' ':(exclude,top)lib/test/modules/create-issue-contract.sh' 2>/dev/null)
  _ci613_rc=$?
  [ "$_ci613_rc" -le 1 ] || printf 'devflow: #613 AC10 sweep errored under %s (git rc=%s)\n' "$1" "$_ci613_rc" >&2
  _ci613_classify "$_ci613_rc" "$_ci613_out"
}
# TWO needles, head and tail: the retired parenthetical was "per-profile cloud allowlists,
# install-channel skew, workpad/retrospective lifecycle surfaces, and the `lib/test/run.sh` pin
# corpus". A head-only needle would let a future mirror quoting just the tail pass, so the tail
# fragment gets its own row. (The trailing "`lib/test/run.sh` pin corpus" is deliberately NOT a
# needle: it is that axis bullet's own title in the extension — the source of truth, not a mirror
# of the enumeration — so a sweep for it would report a permanent false hit.)
assert_eq "#613 AC10: the retired overview axis enumeration (head) has no tracked-tree hits outside this module" "" \
  "$(_ci613_scan "$CI_ROOT" 'per-profile cloud allowlists, install-channel skew')"
assert_eq "#613 AC10: the retired overview axis enumeration (tail) has no tracked-tree hits outside this module" "" \
  "$(_ci613_scan "$CI_ROOT" 'workpad/retrospective lifecycle surfaces, and the')"
# ANTI-VACUITY (CLAUDE.md's hardening rule): the guard above is only worth its comment if its
# removal is detectable. Deleting the `-gt 1` arm leaves a healthy repo green forever, because a
# clean sweep and an errored one both yield empty output — so drive the classifier across the rc
# CLASSES, pinning the threshold itself and not merely "rc 128 fails closed". Mirrors the four
# rc-class rows lib/test/run.sh gives rgb_classify, plus one live non-repo scan end-to-end.
assert_eq "#613 AC10 anti-vacuity: rc 0 (hits found) passes the hit list through" "docs/x.md" \
  "$(_ci613_classify 0 'docs/x.md')"
assert_eq "#613 AC10 anti-vacuity: rc 1 (clean no-match) yields the empty expected value" "" \
  "$(_ci613_classify 1 '')"
assert_eq "#613 AC10 anti-vacuity: rc 2 (smallest error rc) yields the sentinel at the -gt 1 boundary" "<ac10-sweep-errored>" \
  "$(_ci613_classify 2 '')"
assert_eq "#613 AC10 anti-vacuity: rc 128 (git fatal) yields the sentinel" "<ac10-sweep-errored>" \
  "$(_ci613_classify 128 '')"
assert_eq "#613 AC10 anti-vacuity: a live scan of a non-repo path yields the sentinel, never a vacuous pass" "<ac10-sweep-errored>" \
  "$(_ci613_scan "$CI_ROOT/nonexistent-ac10-probe-$$" 'per-profile cloud allowlists' 2>/dev/null)"
unset -f _ci613_classify _ci613_scan
unset _ci613_out _ci613_rc
devflow_module_pin_unique "#613 AC10: overview evidence-axes hook points at the live extension instead of enumerating" \
  'see the live extension'"'"'s `## Evidence axes` section for the current axis list' "$CI_OVERVIEW"

# Complete normal cleanup explicitly so a removal or marker failure changes the
# module status. EXIT remains a fallback for earlier returns and shell errors.
if ! _ci_cleanup; then
  trap - EXIT HUP INT TERM
  return 1
fi
trap - EXIT HUP INT TERM
