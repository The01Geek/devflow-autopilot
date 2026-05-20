# clean-entry.jq — builds a retrospective entry for a mechanically-clean PR.
#
# Input (stdin):
#   A single context bundle object (kind == "implementation") as emitted by
#   fetch-pr-context.sh. The PR must have already passed the cheap-gate.jq
#   predicate (i.e. all signals are clean).
#
# Output:
#   One compact JSON object: the retrospective entry ready to append to
#   retrospectives.jsonl.  All verdict/analysis fields are set to their
#   "clean" defaults — no LLM call required.
#
# Invocation:
#   jq -c -f lib/clean-entry.jq <context-bundle.json

{
  schema_version: 2,
  kind: "implementation",
  pr: .pr,
  issue: .issue_number,
  merged_at: .merged_at,
  branch: .branch,
  head_sha: .head_sha,
  merge_commit_sha: .merge_commit_sha,
  verdict: "clean",
  categories: [],
  descriptors: [],
  signals: .signals,
  summary: "PR merged with no review comments, no outstanding /review REJECT, no substantive human commits after the bot, no CI failures, and a Complete workpad — no retrospective signal.",
  suggested_interventions: []
}
