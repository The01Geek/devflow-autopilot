# classify-pr-kind.jq — branch-prefix dispatcher for the devflow retrospective.
#
# fetch-pr-context.sh consults this filter to decide which retro variant
# (if any) applies to a freshly-merged PR, and stores the result as `.kind`
# in the context bundle.
#
# Invocation (named args, no stdin needed):
#   jq -rn --arg branch "claude/issue-773-..." --argjson watched true \
#     --arg impl_prefix "claude/" -f lib/classify-pr-kind.jq
#
# $impl_prefix is the adopter's implementation-bot branch prefix
# (devflow_retrospective.implementation_branch_prefix, default "claude/").
# The devflow/* prefixes below are DevFlow's own internal branch conventions
# and are intentionally fixed.
#
# Output: a single string — one of:
#   "implementation"      -- run the full per-PR retrospective
#   "audit-intervention"  -- run the audit-PR variant (flips patterns to fixed)
#   "skip"                -- not a retrospected branch (state-carrier or unrelated)

if   ($branch | startswith("devflow/learnings-")) then "skip"
elif ($branch | startswith("devflow/audit-"))     then (if $watched then "audit-intervention" else "skip" end)
elif ($branch | startswith($impl_prefix))         then (if $watched then "implementation"     else "skip" end)
else "skip"
end
