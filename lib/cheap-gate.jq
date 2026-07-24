# cheap-gate.jq — mechanical "clean PR" predicate for the devflow retrospective.
#
# Decides whether a PR context bundle can be skipped by the LLM analysis
# because all observable signals are clean. This is a pure filter with no
# side-effects; it never touches disk or network.
#
# Deliberately UNWIRED to the `Verification evidence:` marker (issue #730): that
# marker is recorded on the local/interactive tier only, but this gate's input
# population — via lib/scan.sh — is merged, predominantly-cloud watched-author
# PRs, the exact population the marker's local/interactive scoping excludes. A
# clause reading it here would read as armed yet almost never legitimately fire.
# The marker's runtime consumer is instead the shared review engine's tier-scoped
# advisory (.devflow/prompt-extensions/review.md and its byte-identical twin
# review-and-fix.md), whose per-PR input population contains those surfaces.
#
# Invocation:
#   jq -c -f lib/cheap-gate.jq <context-bundle.json
#
# Input (stdin):
#   A single context bundle object as emitted by fetch-pr-context.sh, which
#   must contain a ".signals" object with these fields:
#     review_comments_count     <int>    — human review comments left on the PR
#     post_bot_commits          <int>    — commits pushed after the last bot push
#     ci_failures_during_pr     <int>    — CI runs that failed while the PR was open
#     workpad_final_status      <string|null> — final workpad status tag
#     review_reject_outstanding <bool>   — true if a /review REJECT has not been
#                                          superseded by a later APPROVE
#     ci_status_unknown         <bool>   — true if CI check-runs could not be read
#                                          (fail-safe: such a PR is never "clean")
#   plus two TOP-LEVEL fields (siblings of .signals):
#     reflections               <array>  — the workpad's `## Devflow Reflection`
#                                          bullets (flat string array; defaulted
#                                          to [] when absent — older bundles).
#     reflections_friction_count <int|absent> — how many of those bullets are
#                                          FRICTION (every reflection kind EXCEPT
#                                          the informational `note`). Only friction
#                                          forces analysis: a run whose reflections
#                                          are all `note`-kind is treated as clean.
#                                          Emitted by fetch-pr-context.sh. When
#                                          ABSENT (an older bundle, or a bundle
#                                          whose emission failed) the gate FAILS
#                                          CLOSED — it falls back to the legacy
#                                          "any reflection trips" behavior
#                                          (reflections | length > 0), so a missing
#                                          signal over-analyzes, never silently
#                                          skips a friction PR.
#
# Output:
#   One compact JSON object:
#     { "clean": <bool>, "reason": <string> }
#
#   "clean" is true iff ALL of the following hold:
#     • review_reject_outstanding == false
#     • ci_status_unknown        == false
#     • ci_failures_during_pr    == 0
#     • post_bot_commits         == 0
#     • review_comments_count    == 0
#     • workpad_final_status     is "Complete" (an absent workpad — "", null, or
#                                 an absent key — fails closed with the reason
#                                 "workpad absent or status unknown"; any other
#                                 non-"Complete" string keeps "workpad status not
#                                 Complete")
#     • no FRICTION reflections  (reflections_friction_count == 0; or, when that
#                                 field is absent, reflections is empty)
#
#   "reason" names the FIRST failing check when clean=false, or
#   "all clean signals" when clean=true. Check order matches the priority
#   used in the LLM triage prompt (most-blocking first). The reflection check
#   is last: a run that left a FRICTION bullet on its workpad is forced into
#   LLM analysis even when every other signal is clean — that self-reported
#   friction is exactly the signal the retrospective exists to learn from. A run
#   whose only reflections are informational `note`-kind bullets is NOT friction
#   and is treated as clean (the note is still recorded verbatim by
#   clean-entry.jq). `reflections` and `reflections_friction_count` are top-level
#   bundle fields (siblings of .signals), read directly.

.signals as $s
| ((.reflections // []) | length) as $reflection_count
# Fail closed: when the friction field is ABSENT (null — an older bundle or a
# failed emission), fall back to the legacy "any reflection trips" count so a
# missing signal over-analyzes rather than reading as zero friction.
| (if (.reflections_friction_count == null) then $reflection_count
   else .reflections_friction_count end) as $friction_count
# The clean set is "Complete" ONLY (issue #626). An absent workpad — the empty
# string "" or JSON null (or an absent key, which jq reads as null) — is NOT
# clean: it fails closed with a distinct reason, symmetric with the present-but-
# corrupt `Unparsed` case, so a run that left no audit trail is surfaced rather
# than laundered past analysis. A non-empty non-"Complete" string (Unparsed /
# Blocked / Failed / Cancelled / any future word) keeps the existing reason.
| ($s.workpad_final_status == "Complete") as $workpad_ok
| (($s.workpad_final_status == "") or ($s.workpad_final_status == null)) as $workpad_absent
|
  if   $s.review_reject_outstanding               then { clean: false, reason: "outstanding /review REJECT" }
  elif ($s.ci_status_unknown // false)            then { clean: false, reason: "CI status could not be read" }
  elif $s.ci_failures_during_pr   > 0             then { clean: false, reason: "CI failures during PR" }
  elif $s.post_bot_commits        > 0             then { clean: false, reason: "human commits after the bot" }
  elif $s.review_comments_count   > 0             then { clean: false, reason: "review comments present" }
  elif $workpad_absent                            then { clean: false, reason: "workpad absent or status unknown" }
  elif ($workpad_ok | not)                        then { clean: false, reason: "workpad status not Complete" }
  elif $friction_count            > 0             then { clean: false, reason: "friction reflections present" }
  else                                                 { clean: true,  reason: "all clean signals" }
  end
