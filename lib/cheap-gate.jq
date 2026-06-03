# cheap-gate.jq — mechanical "clean PR" predicate for the devflow retrospective.
#
# Decides whether a PR context bundle can be skipped by the LLM analysis
# because all observable signals are clean. This is a pure filter with no
# side-effects; it never touches disk or network.
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
#     • workpad_final_status     is "Complete", "", or null
#     • reflections              is empty (no `## Devflow Reflection` bullets)
#
#   "reason" names the FIRST failing check when clean=false, or
#   "all clean signals" when clean=true. Check order matches the priority
#   used in the LLM triage prompt (most-blocking first). The reflection check
#   is last: a run that left a friction bullet on its workpad is forced into
#   LLM analysis even when every other signal is clean — that self-reported
#   friction is exactly the signal the retrospective exists to learn from.
#   `reflections` is a top-level bundle field (sibling of .signals), so it is
#   read directly and defaulted to [] when absent (older bundles lack it).

.signals as $s
| ((.reflections // []) | length) as $reflection_count
| (($s.workpad_final_status == "Complete")
   or ($s.workpad_final_status == "")
   or ($s.workpad_final_status == null)) as $workpad_ok
|
  if   $s.review_reject_outstanding               then { clean: false, reason: "outstanding /review REJECT" }
  elif ($s.ci_status_unknown // false)            then { clean: false, reason: "CI status could not be read" }
  elif $s.ci_failures_during_pr   > 0             then { clean: false, reason: "CI failures during PR" }
  elif $s.post_bot_commits        > 0             then { clean: false, reason: "human commits after the bot" }
  elif $s.review_comments_count   > 0             then { clean: false, reason: "review comments present" }
  elif ($workpad_ok | not)                        then { clean: false, reason: "workpad status not Complete" }
  elif $reflection_count          > 0             then { clean: false, reason: "workpad reflections present" }
  else                                                 { clean: true,  reason: "all clean signals" }
  end
