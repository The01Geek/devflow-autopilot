# efficiency-trace.jq — derives the per-run subagent effectiveness view from
# the /devflow:review-and-fix per-iteration workpads.
#
# This is the mechanical heart of the telemetry feature: it reads the
# `iter-<N>.json` workpads (already on disk under .devflow/tmp/review/<slug>/),
# assigns each dispatched Phase-3 subagent exactly one of four effectiveness
# verdicts, and emits EITHER a rendered Markdown trace ($mode == "trace") OR a
# single per-run JSON record ($mode == "record"). No LLM, no side effects —
# matching how the weekly retrospective does all mechanical work in lib/.
#
# Invocation (via lib/efficiency-trace.sh, which validates inputs first):
#   jq -s -f lib/efficiency-trace.jq \
#      --arg mode {trace|record} --arg slug <slug> \
#      --arg generated_at <iso8601> --argjson cut_candidate_min_dispatch <int> \
#      iter-1.json iter-2.json ...
#
# Inputs:
#   stdin: array of per-iteration workpad objects (pass -s to slurp the
#          separate iter-*.json files into one array). May be empty.
#   $mode: "trace" → Markdown string; "record" → the JSON record object.
#   $slug: the run slug (pr-<N> or sanitized branch name).
#   $generated_at: ISO-8601 UTC timestamp for the record.
#   $cut_candidate_min_dispatch: carried into the record for the cross-run
#          analyzer (this filter does not act on it).
#
# Effectiveness taxonomy (4-way, per dispatched subagent, per iteration):
#   unique-effective — raised a finding that led to an applied fix and that no
#                      sibling agent corroborated (corroboration_count < 2).
#   corroborating    — its finding led to an applied fix but ≥1 other agent
#                      raised the same defect (corroboration_count ≥ 2).
#   noise            — its only findings were pushed back / demoted to advisory
#                      (fix_decision ∈ {pushed_back, advisory}); none applied.
#   null             — dispatched but raised nothing, or nothing that survived
#                      to an applied fix or a noise classification (e.g. only
#                      deferred findings).
#
# Verdict precedence (highest wins, so each agent gets exactly one):
#   unique-effective > corroborating > noise > null.
#
# Graceful degradation: a workpad missing `phase3_dispatched` still classifies
# the agents that appear in its `phase3_findings` (the roster is the union of
# `phase3_dispatched` and the agents seen in findings) — only genuinely-silent
# agents become invisible without the roster, which is the documented limit.

# The agent identifier for a single phase3_findings entry.
def finding_agent: .agent;

# Classify one agent's findings (an array of phase3_findings rows for that
# agent in one iteration) into a single verdict.
def verdict_for($findings):
  ($findings | map(.fix_decision)) as $decisions
  | ($findings | map(select(.fix_decision == "applied"))) as $applied
  # corroboration_count missing → treat as 1 (unique / single-source).
  | if ($applied | any(((.corroboration_count // 1)) < 2)) then "unique-effective"
    elif ($applied | length) > 0 then "corroborating"
    elif ($decisions | any(. == "pushed_back" or . == "advisory")) then "noise"
    else "null"
    end;

# Per-iteration derived view.
def iter_view:
  . as $it
  | (($it.phase3_findings) // []) as $findings
  | (($it.phase3_dispatched) // []) as $dispatched
  | (($it.checklist) // []) as $checklist
  | (($it.convergence_inputs.fixes_applied) // 0) as $fixes_applied
  # Roster = dispatched ∪ agents-seen-in-findings (degradation safety).
  | (($dispatched + ($findings | map(finding_agent))) | unique) as $roster
  | {
      iter: ($it.iter // null),
      phase3_dispatched: $dispatched,
      phase3_dispatched_count: ($dispatched | length),
      checklist_lite_count:  ([$checklist[] | select(.verification_mode == "lite")]  | length),
      checklist_agent_count: ([$checklist[] | select(.verification_mode == "agent")] | length),
      fixes_applied: $fixes_applied,
      added_nothing: ($fixes_applied == 0),
      # The roster is "present" iff the field exists at all. A legitimately-empty
      # roster ("phase3_dispatched": []) is still present — only a genuinely
      # absent field triggers the degradation warning in the trace.
      phase3_dispatched_present: ($it | has("phase3_dispatched")),
      agent_verdicts: [
        $roster[] as $agent
        | {
            agent: $agent,
            verdict: verdict_for([$findings[] | select(finding_agent == $agent)])
          }
      ],
      telemetry: ($it.telemetry // null)
    };

# ── Build the ordered per-iteration array ───────────────────────────────────
(. | map(iter_view) | sort_by(.iter // 0)) as $iters

# ── record mode: the single per-run JSON record ─────────────────────────────
| if $mode == "record" then
    {
      schema_version: 1,
      slug: $slug,
      generated_at: $generated_at,
      cut_candidate_min_dispatch: $cut_candidate_min_dispatch,
      iterations: ($iters | length),
      per_iteration: ($iters | map({
        iter: .iter,
        phase3_dispatched: .phase3_dispatched,
        phase3_dispatched_count: .phase3_dispatched_count,
        checklist_lite_count: .checklist_lite_count,
        checklist_agent_count: .checklist_agent_count,
        fixes_applied: .fixes_applied,
        added_nothing: .added_nothing,
        agent_verdicts: .agent_verdicts
      })),
      # Cost telemetry carried forward from each workpad so it is no longer lost
      # when .devflow/tmp/ is destroyed at GH-runner teardown.
      telemetry: ($iters | map({iter: .iter, phases: .telemetry}))
    }

# ── trace mode: the rendered Markdown effectiveness trace ───────────────────
  elif $mode == "trace" then
    (
      ["## Subagent effectiveness trace", ""]
      + (
          if ($iters | length) == 0 then
            ["_No iteration workpads were readable — effectiveness trace unavailable._"]
          else
            ($iters | map(
              [ "### Iteration \(.iter)",
                "- Phase 3 agents dispatched: \(.phase3_dispatched_count)",
                "- Checklist verifiers: \(.checklist_lite_count) lite, \(.checklist_agent_count) agent",
                "- Fixes applied: \(.fixes_applied)"
              ]
              + (.agent_verdicts | map("  - \(.agent) — \(.verdict)") | (if length == 0 then ["- Agent verdicts: (none dispatched)"] else ["- Agent verdicts:"] + . end))
              + (if .added_nothing then ["- ⚠ Marginal yield: this iteration applied 0 fixes — added nothing."] else [] end)
              + (if (.phase3_dispatched_present | not) then ["- ⚠ `phase3_dispatched` absent — null agents (dispatched but silent) cannot be shown for this iteration."] else [] end)
              + [""]
            ) | add)
          end
        )
    ) | join("\n")

  else
    error("efficiency-trace.jq: unknown $mode '\($mode)' (expected 'trace' or 'record')")
  end
