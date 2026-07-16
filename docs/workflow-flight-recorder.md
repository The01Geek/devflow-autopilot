# Local workflow flight recorder

The workflow flight recorder is opt-in, local instrumentation for improving
DevFlow skills from real Claude Code sessions. Claude's native JSONL under its
projects store remains the transcript source of truth; DevFlow inventories that
store without copying or changing it, records only start metadata automatically,
and imports a selected transcript only on an explicit operator command.

Observation and inventory do not block Claude Code, contact a model provider,
file issues, edit skills, or infer missing measurements. Analysis is a separate,
explicit operation: it sends selected imported evidence to the configured Claude
provider and can use read-only tools against the local filesystem, so review the
bundle and provider policy first.

## Native inventory and manifest lifecycle

The read-only inventory scans Claude's native project store and emits metadata,
not prompts, tool results, or transcript excerpts:

```bash
python3 scripts/inventory-workflow-transcripts.py \
  --repo-root /path/to/repository \
  --claude-projects-root ~/.claude/projects \
  --json
```

A session qualifies only when its first authoritative user message invokes a
registered workflow. The registry recognizes `/devflow:implement` and
`/implement`, `/devflow:create-issue` and `/create-issue`,
`/devflow:review-and-fix` and `/review-and-fix`, and
`/devflow:receiving-code-review`. Plain commands and Claude command markup both
qualify. A command embedded in a larger first message qualifies only when a
later assistant `Skill` call corroborates the same workflow and subject; the
inventory then classifies it as top-level. Later command mentions do not qualify
an otherwise unrelated session.

The local `UserPromptSubmit` observer at
`scripts/capture-workflow-manifest.py` writes candidate metadata to the shared
checkout at `.devflow/tmp/workflow-manifests/<session-id>.json`. The manifest
preserves ephemeral start state such as repository and Git provenance, selected
Claude settings, and prompt-surface fingerprints and sizes. It does not copy or
parse the native transcript, retain submitted prompt content, use the network,
or block prompt submission. Embedded candidates remain provisional until the
native transcript supplies the corroborating `Skill` call. Restart any active
Claude Code session after installing or changing the hook configuration; hooks
are loaded when the session starts.

## Explicit import and compatibility

Import exactly one inventoried session by ID when it is ready for analysis:

```bash
python3 scripts/import-workflow-transcript.py <session-id> \
  --repo-root /path/to/repository \
  --claude-projects-root ~/.claude/projects
```

Import re-reads the complete native JSONL, combines it with the start manifest
when present, writes `.devflow/tmp/workflow-runs/<session-id>/`, and verifies the
copied transcript bytes against the native source. Re-import refreshes the same
bundle and records another import attempt; inventory never imports implicitly,
and import never changes or deletes Claude's native file.

Each imported bundle contains one transcript plus:

- `metadata.json` — repository state, session start/finish, Claude configuration
  provenance, version/provider markers, and capture warnings;
- `occurrences.json` — ordered top-level and nested workflow invocations with
  parentage, subjects, timing confidence, and prompt fingerprints;
- `prompt-surfaces.json` — measured skill/prompt paths and separate load-class
  totals for bytes, lines, words, and approximate tokens;
- `event-summary.json` — privacy-safe counts for tools, errors, permission
  denials, equivalent retries, subagents, compaction, gaps, usage, model, and
  effort where observable;
- `stop-attempts.jsonl` — one compact entry per successful compatibility
  capture or verified explicit import.

`scripts/capture-implement-session.py` remains as an unwired compatibility entry
point for existing callers. Generalized bundles and legacy implement bundles
under `.devflow/tmp/implement-runs/` remain readable by the analyzer; legacy
bundles are normalized in memory and are never rewritten.

## Configuration and experimental validity

Keep Claude Code's `outputStyle` at `Default` for observational baselines.
`Explanatory` changes the system prompt and deliberately produces more prose, so
it can change tokens, latency, and behavior. Test it only as a labeled per-run
treatment against matched Default runs.

`verbose` and `viewMode` primarily affect terminal presentation; session JSONL
already contains messages, tool calls, and tool results. The recorder stores
allowlisted values for `outputStyle`, `verbose`, `viewMode`,
`alwaysThinkingEnabled`, and `showThinkingSummaries`, plus model, effort,
provider, and Claude Code version when observable. File-derived settings are
marked potentially overridden because CLI and managed policy can take
precedence.

For a controlled run, declare the treatment alongside the launch so it survives
worktree/config indirection, for example:

```bash
DEVFLOW_RECORDER_OUTPUT_STYLE=Explanatory DEVFLOW_RECORDER_MODEL=opus \
  DEVFLOW_RECORDER_EFFORT=high claude --settings '{"outputStyle":"Explanatory"}' -w issue-n
```

The declaration is provenance, not proof of the provider's effective model.
`DEVFLOW_RECORDER_OUTPUT_STYLE` and its allowlisted siblings override the
file-derived configuration snapshot. `DEVFLOW_RECORDER_MODEL` and
`DEVFLOW_RECORDER_EFFORT` only fill in what the session did not itself report:
when the host supplies the model or effort, that observation wins and the
declaration is discarded rather than recorded over it. Either way the recorded
value carries an `explicit_recorder_environment` source, so a declared value is
always distinguishable from an observed one.

Do not pool unlike output styles, invocation modes, prompt fingerprints, models,
or effort levels without naming them as confounders.

## Analysis and issue threshold

The analyst runs in safe print mode with only `Read`, `Grep`, and `Glob`. A
caller must pass `--acknowledge-provider-access` to confirm that selected bundle
content may be sent to the configured provider. Transcript content is untrusted;
the analyst is instructed to read only supplied bundle paths, but the tool
allowlist is not a filesystem sandbox. Run analysis only where that read scope is
acceptable.

A single session may produce a report but never an optimization issue. A recurring
issue requires materially matching evidence from at least two distinct session
ids with the same workflow, mode, and non-null prompt fingerprint. Multiple
occurrences inside one session do not count as independent runs.

Top-level and nested runs are analyzed separately by default. Cross-mode
comparison is report-only unless a human explicitly approves pooling them.

Any proposed change to a model-loaded instruction surface must require the
external Superpowers `writing-skills` workflow, measure before/after lines,
words, bytes, and approximate tokens, and default to reducing mandatory prompt
size. Justified growth is a warning requiring recurring-cost rationale, not an
automatic blocker.

## Privacy and cleanup

Claude owns native transcript retention under its project store. An explicitly
imported bundle can contain the full local Claude session transcript and remains
sensitive even though inventory and manifests omit prompt content. Keep
`.devflow/tmp/` ignored, do not attach manifests or bundles to issues or commits,
and share only narrowly redacted evidence when a human approves it. Delete an
imported bundle when it is no longer needed using normal local file-management
practices; manage native retention through Claude's own controls.
