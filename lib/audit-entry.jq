# audit-entry.jq — builds a retrospective entry for an audit-intervention PR.
#
# Input (stdin):
#   A single context bundle object (kind == "audit-intervention") as emitted by
#   fetch-pr-context.sh. The bundle must include a "pattern_tag" field (string
#   or null) identifying the pattern the audit PR is intended to fix.
#
# Output:
#   One compact JSON object: the audit retrospective entry ready to append to
#   retrospectives.jsonl.  When pattern_tag is null, fixes_patterns is [].
#
# Invocation:
#   jq -c -f lib/audit-entry.jq <context-bundle.json

{
  schema_version: 2,
  kind: "audit",
  pr: .pr,
  merged_at: .merged_at,
  fixes_patterns: (if .pattern_tag != null then [.pattern_tag] else [] end)
}
