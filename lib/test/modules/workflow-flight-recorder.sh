# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Sourceable workflow-flight-recorder test module.
# Contract: the caller sets LIB and RESULTS_FILE and defines assert_eq.
# The module owns all other fixtures and removes its temporary workspace.

# ────────────────────────────────────────────────────────────────────────────
echo "workflow flight recorder: native inventory, explicit import, and constrained analysis"
# ────────────────────────────────────────────────────────────────────────────
IFR_MANIFEST="$LIB/../scripts/capture-workflow-manifest.py"
IFR_INVENTORY="$LIB/../scripts/inventory-workflow-transcripts.py"
IFR_IMPORT="$LIB/../scripts/import-workflow-transcript.py"
IFR_ANALYZE="$LIB/../scripts/analyze-implement-runs.py"
IFR_PROMPT="$LIB/../scripts/prompts/implement-flight-recorder-analysis.md"
WFR_PROMPT="$LIB/../scripts/prompts/workflow-flight-recorder-analysis.md"
IFR_SETTINGS_FIXTURE="$LIB/test/fixtures/workflow-flight-recorder-settings.local.json"
IFR_ROOT="$(mktemp -d)"
IFR_PROJECTS="$IFR_ROOT/native-projects"
mkdir -p "$IFR_ROOT/nested" "$IFR_PROJECTS" "$IFR_ROOT/skills/implement/phases" \
  "$IFR_ROOT/skills/review" "$IFR_ROOT/skills/review-and-fix" "$IFR_ROOT/skills/docs"
git -C "$IFR_ROOT" init -q
printf '%s\n' '# implement' > "$IFR_ROOT/skills/implement/SKILL.md"
printf '%s\n' '# phase one' > "$IFR_ROOT/skills/implement/phases/phase-1.md"
printf '%s\n' '# review' > "$IFR_ROOT/skills/review/SKILL.md"
printf '%s\n' '# review fix' > "$IFR_ROOT/skills/review-and-fix/SKILL.md"
printf '%s\n' '# docs' > "$IFR_ROOT/skills/docs/SKILL.md"

IFR_TRANSCRIPT="$IFR_PROJECTS/sid-a.jsonl"
IFR_PAYLOAD="$(jq -cn --arg sid sid-a --arg transcript "$IFR_TRANSCRIPT" --arg cwd "$IFR_ROOT/nested" \
  '{session_id:$sid,transcript_path:$transcript,cwd:$cwd,user_prompt:"/devflow:implement 123",model:"claude-start-model",effort:"high"}')"
printf '%s' "$IFR_PAYLOAD" | python3 "$IFR_MANIFEST" 2>"$IFR_ROOT/manifest.err"
IFR_MANIFEST_FILE="$IFR_ROOT/.devflow/tmp/workflow-manifests/sid-a.json"
IFR_BUNDLE="$(cd "$IFR_ROOT" && pwd -P)/.devflow/tmp/workflow-runs/sid-a"
assert_eq "flight recorder: UserPromptSubmit observation writes only the start manifest" "yes" \
  "$([ -f "$IFR_MANIFEST_FILE" ] && [ ! -e "$IFR_BUNDLE" ] && echo yes || echo no)"

printf '%s\n' \
  "$(jq -cn --arg cwd "$IFR_ROOT/nested" '{type:"user",timestamp:"2026-07-15T19:00:00Z",cwd:$cwd,message:{role:"user",content:"/devflow:implement 123"}}')" \
  "$(jq -cn --arg cwd "$IFR_ROOT/nested" '{type:"assistant",timestamp:"2026-07-15T19:01:00Z",cwd:$cwd,message:{role:"assistant",content:"working"}}')" \
  "$(jq -cn --arg cwd "$IFR_ROOT/nested" '{type:"assistant",timestamp:"2026-07-15T19:02:00Z",cwd:$cwd,message:{role:"assistant",content:"ISSUE-525-NATIVE-FINAL-TAIL"}}')" \
  > "$IFR_TRANSCRIPT"
IFR_INVENTORY_JSON="$(python3 "$IFR_INVENTORY" --json --claude-projects-root "$IFR_PROJECTS" --repo-root "$IFR_ROOT")"
assert_eq "flight recorder: read-only inventory finds the native session" "sid-a" \
  "$(printf '%s' "$IFR_INVENTORY_JSON" | jq -r '.sessions[0].session_id')"
assert_eq "flight recorder: inventory reports the start manifest without importing" "present:not_imported" \
  "$(printf '%s' "$IFR_INVENTORY_JSON" | jq -r '.sessions[0] | .manifest_status + ":" + .import_status')"
assert_eq "flight recorder: observation and inventory create no transcript bundle" "no" \
  "$([ -e "$IFR_BUNDLE" ] && echo yes || echo no)"

python3 "$IFR_IMPORT" sid-a --claude-projects-root "$IFR_PROJECTS" --repo-root "$IFR_ROOT" \
  > "$IFR_ROOT/import-path"
assert_eq "flight recorder: explicit import creates the generalized bundle" "yes" \
  "$([ -f "$IFR_BUNDLE/transcript.jsonl" ] && [ -f "$IFR_BUNDLE/metadata.json" ] && \
      [ -f "$IFR_BUNDLE/occurrences.json" ] && [ -f "$IFR_BUNDLE/event-summary.json" ] && \
      [ -f "$IFR_BUNDLE/stop-attempts.jsonl" ] && [ -f "$IFR_BUNDLE/prompt-surfaces.json" ] && echo yes || echo no)"
assert_eq "flight recorder: imported transcript retains the native final tail" "yes" \
  "$(grep -qF 'ISSUE-525-NATIVE-FINAL-TAIL' "$IFR_BUNDLE/transcript.jsonl" && echo yes || echo no)"
assert_eq "flight recorder: nested payload cwd resolves the repository root" "$(cd "$IFR_ROOT" && pwd -P)" \
  "$(jq -r '.repository_root' "$IFR_BUNDLE/metadata.json")"
assert_eq "flight recorder: issue number comes from the inventoried user invocation" "123" \
  "$(jq -r '.[0].subject.number' "$IFR_BUNDLE/occurrences.json")"
assert_eq "flight recorder: prompt manifest records always/phase/nested load classes" "always,nested,phase" \
  "$(jq -r '[.surfaces[].load_class] | unique | join(",")' "$IFR_BUNDLE/prompt-surfaces.json")"
assert_eq "flight recorder: prompt manifest labels its approximate-token heuristic" "true" \
  "$(jq -r '.token_estimate | contains("heuristic, not API-reported")' "$IFR_BUNDLE/prompt-surfaces.json")"
assert_eq "flight recorder: each prompt surface has path/count/hash attribution" "true" \
  "$(jq -r 'all(.surfaces[]; (.path|type)=="string" and (.bytes|type)=="number" and (.lines|type)=="number" and (.words|type)=="number" and (.approx_tokens|type)=="number" and (.sha256|test("^[0-9a-f]{64}$")))' "$IFR_BUNDLE/prompt-surfaces.json")"
IFR_FP1="$(jq -r '.[0].prompt_fingerprint' "$IFR_BUNDLE/occurrences.json")"

# A later explicit import refreshes the same bundle from the longer native source.
printf '%s\n' "$(jq -cn --arg cwd "$IFR_ROOT/nested" '{type:"assistant",timestamp:"2026-07-15T19:03:00Z",cwd:$cwd,message:{role:"assistant",content:"native append after observation"}}')" >> "$IFR_TRANSCRIPT"
printf '%s\n' '# one more prompt byte after UserPromptSubmit' >> "$IFR_ROOT/skills/implement/SKILL.md"
python3 "$IFR_IMPORT" sid-a --claude-projects-root "$IFR_PROJECTS" --repo-root "$IFR_ROOT" >/dev/null
assert_eq "flight recorder: repeated import refreshes rather than duplicates" "4" \
  "$(wc -l < "$IFR_BUNDLE/transcript.jsonl" | tr -d ' ')"
assert_eq "flight recorder: repeated import appends one compact attempt" "2" \
  "$(wc -l < "$IFR_BUNDLE/stop-attempts.jsonl" | tr -d ' ')"
assert_eq "flight recorder: start-manifest prompt fingerprint wins at import" "$IFR_FP1" \
  "$(jq -r '.[0].prompt_fingerprint' "$IFR_BUNDLE/occurrences.json")"
assert_eq "flight recorder: import attempts identify the explicit source" "true" \
  "$(jq -s 'all(.[]; .source == "explicit_import")' "$IFR_BUNDLE/stop-attempts.jsonl")"

assert_eq "flight recorder: configured recorder hook is UserPromptSubmit" "yes" \
  "$(jq -e '[.hooks.UserPromptSubmit[].hooks[].command] | any(contains("capture-workflow-manifest.py"))' \
      "$IFR_SETTINGS_FIXTURE" >/dev/null && echo yes || echo no)"
assert_eq "flight recorder: local recorder fixture has no Stop command" "no" \
  "$(jq -r '.hooks.Stop[]?.hooks[]?.command // empty' "$IFR_SETTINGS_FIXTURE" | \
      grep -Eq 'capture-(implement-session|workflow-manifest)\.py' && echo yes || echo no)"
IFR_STOP_EXAMPLE="$(awk '/^- \*`Stop` hook \(local-tier only\)\.\*/ { found=1 } found { print } found && /^  > \*\*Note/ { exit }' "$LIB/../docs/efficiency-trace.md")"
assert_eq "flight recorder: documented local Stop example has no recorder command" "no" \
  "$(printf '%s' "$IFR_STOP_EXAMPLE" | grep -Eq 'capture-(implement-session|workflow-manifest)\.py' && echo yes || echo no)"

# Claude command markup is accepted only in a user message.
printf '%s\n' "$(jq -cn --arg cwd "$IFR_ROOT" '{type:"user",timestamp:"2026-07-15T20:00:00Z",cwd:$cwd,message:{role:"user",content:"<command-message>devflow:implement</command-message><command-args>456</command-args>"}}')" > "$IFR_PROJECTS/sid-markup.jsonl"
python3 "$IFR_IMPORT" sid-markup --claude-projects-root "$IFR_PROJECTS" --repo-root "$IFR_ROOT" >/dev/null
assert_eq "flight recorder: user command-markup invocation is recognized" "456" \
  "$(jq -r '.[0].subject.number' "$IFR_ROOT/.devflow/tmp/workflow-runs/sid-markup/occurrences.json")"

# Prompt contract: pin the scientific and human-gated controls that deterministic
# driver validation cannot infer from model prose.
for IFR_PIN in \
  'Observed bottlenecks' 'Hypotheses' 'timestamps and event identifiers' \
  'Unknown evidence remains `unknown`, never zero' 'timings `approximate`' \
  'at least two distinct supplied session ids' 'For one run, emit no issue blocks' \
  'external `writing-skills` skill from the Superpowers plugin' 'before/after lines, words, bytes, and approximate tokens' \
  'net reduction by default; justified growth allowed' \
  'prompt growth as a warning' 'not a blocker' \
  'do not edit files, write to GitHub, execute experiments' \
  '<!-- DEVFLOW_REPORT_BEGIN -->' '<!-- DEVFLOW_REPORT_END -->' \
  '<!-- DEVFLOW_ISSUE_BEGIN slug=<safe-slug> runs=<sid1>,<sid2>[,<sid3>] -->' \
  '<!-- DEVFLOW_ISSUE_END -->'; do
  assert_eq "flight recorder prompt: carries '$IFR_PIN'" "1" "$(grep -cF "$IFR_PIN" "$IFR_PROMPT")"
done

for WFR_PIN in \
  'A session is one Claude Code transcript; an occurrence is one registered workflow' \
  'Multiple occurrences in one session are not independent' \
  'top-level' 'nested' 'timing, model, and effort fact is observed, approximate,' \
  'Unknown is `unknown`, never zero' 'event indexes' 'Do not dump transcripts' \
  'Calculate recurrence separately per mode' 'explicit human decision' \
  'external `writing-skills` skill from the Superpowers plugin' \
  'before/after lines, words, bytes, and approximate tokens' \
  'default to net reduction' 'justified prompt growth as a warning' \
  'Do not edit files, write to GitHub' '<!-- DEVFLOW_REPORT_BEGIN -->' \
  '<!-- DEVFLOW_ISSUE_BEGIN slug=<safe-slug> runs=<sid1>,<sid2>[,<sid3>] -->'; do
  assert_eq "workflow recorder prompt: carries '$WFR_PIN'" "1" "$(grep -qF "$WFR_PIN" "$WFR_PROMPT" && echo 1 || echo 0)"
done

# Analyzer uses a fake Claude binary: no model/network call occurs in the suite.
IFR_FAKE="$IFR_ROOT/fake-claude"
printf '%s\n' '#!/usr/bin/env bash' \
  'printf '\''%s\n'\'' "$@" > "$FAKE_ARGS"' \
  'printf '\''%s\n'\'' "$FAKE_OUTPUT"' \
  'exit "${FAKE_RC:-0}"' > "$IFR_FAKE"
chmod +x "$IFR_FAKE"
IFR_ARGS="$IFR_ROOT/fake-args"
IFR_REPORT='<!-- DEVFLOW_REPORT_BEGIN -->
# One-run report
<!-- DEVFLOW_REPORT_END -->'
(cd "$IFR_ROOT" && DEVFLOW_CLAUDE_BIN="$IFR_FAKE" FAKE_ARGS="$IFR_ARGS" FAKE_OUTPUT="$IFR_REPORT" \
  python3 "$IFR_ANALYZE" --acknowledge-provider-access latest >/dev/null)
assert_eq "flight recorder analyzer: latest writes only the selected run report" "yes" \
  "$([ -f "$IFR_ROOT/.devflow/tmp/workflow-runs/sid-markup/run-report.md" ] && echo yes || echo no)"
assert_eq "flight recorder analyzer: launch enables safe mode" "1" "$(grep -cFx -- '--safe-mode' "$IFR_ARGS")"
assert_eq "flight recorder analyzer: launch uses print mode" "1" "$(grep -cFx -- '--print' "$IFR_ARGS")"
assert_eq "flight recorder analyzer: launch denies permission prompts" "1" "$(grep -cFx -- 'dontAsk' "$IFR_ARGS")"
assert_eq "flight recorder analyzer: allowlist contains only read-only tools" "1" "$(grep -cFx -- 'Read,Grep,Glob' "$IFR_ARGS")"
assert_eq "flight recorder analyzer: no write/edit/bash/web tool is granted" "no" \
  "$(grep -Eq '^(Write|Edit|Bash|Web|MCP|GitHub)$' "$IFR_ARGS" && echo yes || echo no)"

# Form a comparable three-run cohort from safe local fixtures.
IFR_COHORT_FP="$(jq -r '.[0].prompt_fingerprint' "$IFR_BUNDLE/occurrences.json")"
for IFR_SID in sid-b sid-c; do
  mkdir -p "$IFR_ROOT/.devflow/tmp/implement-runs/$IFR_SID"
  cp "$IFR_BUNDLE/transcript.jsonl" "$IFR_ROOT/.devflow/tmp/implement-runs/$IFR_SID/transcript.jsonl"
  jq -n --arg sid "$IFR_SID" --arg fp "$IFR_COHORT_FP" \
    '{schema_version:1,session_id:$sid,issue_number:123,prompt_fingerprint:$fp,captured_at:"2026-07-15T00:00:00Z"}' \
    > "$IFR_ROOT/.devflow/tmp/implement-runs/$IFR_SID/metadata.json"
done
jq '.captured_at="2026-07-15T00:00:02Z"' \
  "$IFR_BUNDLE/metadata.json" > "$IFR_ROOT/sid-a-metadata"
mv "$IFR_ROOT/sid-a-metadata" "$IFR_BUNDLE/metadata.json"
# sid-markup is newer but is deliberately made invalid for discovery, leaving the
# intended three-run cohort as the newest valid comparable set.
rm -f "$IFR_ROOT/.devflow/tmp/workflow-runs/sid-markup/transcript.jsonl"
IFR_COHORT_REPORT='<!-- DEVFLOW_REPORT_BEGIN -->
# Cohort report
<!-- DEVFLOW_REPORT_END -->
<!-- DEVFLOW_ISSUE_BEGIN slug=repeated-read runs=sid-a,sid-b -->
# Repeated read
<!-- DEVFLOW_ISSUE_END -->'
(cd "$IFR_ROOT" && DEVFLOW_CLAUDE_BIN="$IFR_FAKE" FAKE_ARGS="$IFR_ARGS" FAKE_OUTPUT="$IFR_COHORT_REPORT" \
  python3 "$IFR_ANALYZE" --acknowledge-provider-access --last 3 > "$IFR_ROOT/analysis-path")
IFR_ANALYSIS="$(cat "$IFR_ROOT/analysis-path")"
assert_eq "flight recorder analyzer: comparable cohort writes a comparison report" "yes" \
  "$([ -f "$IFR_ANALYSIS/comparison-report.md" ] && echo yes || echo no)"
assert_eq "flight recorder analyzer: two supporting runs create one safe issue draft" "yes" \
  "$([ -f "$IFR_ANALYSIS/issue-drafts/repeated-read.md" ] && echo yes || echo no)"
assert_eq "flight recorder analyzer: cohort manifest contains no transcript content" "no" \
  "$(grep -qF '/devflow:implement' "$IFR_ANALYSIS/cohort.json" && echo yes || echo no)"

# A single-run issue block is rejected and cannot replace the prior valid report.
IFR_PRIOR_REPORT="$(cat "$IFR_BUNDLE/run-report.md" 2>/dev/null || true)"
(cd "$IFR_ROOT" && DEVFLOW_CLAUDE_BIN="$IFR_FAKE" FAKE_ARGS="$IFR_ARGS" FAKE_OUTPUT="$IFR_COHORT_REPORT" \
  python3 "$IFR_ANALYZE" --acknowledge-provider-access sid-a >/dev/null 2>"$IFR_ROOT/single-issue.err")
IFR_SINGLE_RC=$?
assert_eq "flight recorder analyzer: a single-run issue block is rejected" "1" "$IFR_SINGLE_RC"
assert_eq "flight recorder analyzer: rejected output publishes no replacement report" "$IFR_PRIOR_REPORT" \
  "$(cat "$IFR_BUNDLE/run-report.md" 2>/dev/null || true)"

python3 "$LIB/test/test_workflow_flight_recorder.py" >"$IFR_ROOT/recorder-unit.out" 2>&1
assert_eq "workflow recorder: focused Python tests pass" "0" "$?"
python3 "$LIB/test/test_workflow_analyzer.py" >"$IFR_ROOT/analyzer-unit.out" 2>&1
assert_eq "workflow analyzer: focused Python tests pass" "0" "$?"

rm -rf "$IFR_ROOT"
