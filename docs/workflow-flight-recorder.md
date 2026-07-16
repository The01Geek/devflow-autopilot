# Local workflow flight recorder

The workflow flight recorder is an opt-in, local observer for improving DevFlow
skills from real Claude Code sessions. It captures sessions containing
`implement`, `create-issue`, `receiving-code-review`, or `review-and-fix`, whether
the workflow is invoked directly or as a nested Skill call.

Capture does not block Claude Code, contact a model provider, file issues, edit
skills, or infer missing measurements. Raw session data stays under the ignored
`.devflow/tmp/` tree. Analysis is a separate, explicit operation: it sends
selected evidence to the configured Claude provider and can use read-only tools
against the local filesystem, so review the bundle and provider policy first.

## Capture

The repository Stop hook keeps the stable entry point:

```text
scripts/capture-implement-session.py
```

Despite its compatibility name, it writes generalized bundles to:

```text
.devflow/tmp/workflow-runs/<session-id>/
```

Each bundle contains one transcript plus:

- `metadata.json` — repository state, session start/finish, Claude configuration
  provenance, version/provider markers, and capture warnings;
- `occurrences.json` — ordered top-level and nested workflow invocations with
  parentage, subjects, timing confidence, and prompt fingerprints;
- `prompt-surfaces.json` — measured skill/prompt paths and separate load-class
  totals for bytes, lines, words, and approximate tokens;
- `event-summary.json` — privacy-safe counts for tools, errors, permission
  denials, equivalent retries, subagents, compaction, gaps, usage, model, and
  effort where observable;
- `stop-attempts.jsonl` — one compact record per Stop attempt.

Legacy implement bundles under `.devflow/tmp/implement-runs/` remain readable
and are never rewritten.

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

Bundles can contain the full local Claude session transcript. Keep
`.devflow/tmp/` ignored, do not attach bundles to issues or commits, and share
only narrowly redacted evidence when a human approves it. Delete a bundle when
it is no longer needed using normal local file-management practices.
