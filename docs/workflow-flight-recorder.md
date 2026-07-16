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
`/implement`, `/devflow:create-issue` and `/create-issue`, `/devflow:review` and
`/review`, `/devflow:review-and-fix` and `/review-and-fix`, and
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
declaration is discarded rather than recorded over it. A value taken from a
declaration is recorded with an `explicit_recorder_environment` source and an
observed one with `user_prompt_submit_payload`, so the two are always
distinguishable in the bundle.

Do not pool unlike output styles, invocation modes, prompt fingerprints, models,
or effort levels without naming them as confounders.

## Analysis and issue threshold

The analyst runs in safe print mode with only `Read`, `Grep`, and `Glob`. A
caller must pass `--acknowledge-provider-access` to confirm that selected bundle
content may be sent to the configured provider. Transcript content is untrusted;
the analyst is instructed to read only supplied bundle paths, but the tool
allowlist is not a filesystem sandbox. Run analysis only where that read scope is
acceptable. The analyst call is bounded by a 900-second timeout so a hung
provider call cannot block the CLI indefinitely; set `DEVFLOW_CLAUDE_TIMEOUT` to
a positive number of seconds to widen it.

A bundle that cannot be loaded is skipped rather than analyzed, with a
breadcrumb naming it: a cohort can be smaller than the `--last N` you asked for,
and the skipped bundles are the ones to check first.

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

## Verification-launch baseline (Wave 1)

The offline verification-launch baseline analyzer
(`scripts/verification_baseline.py`, issue #527) builds a source-provenanced
baseline of actual verification launches from local native transcript events,
plus a local + cloud lifecycle census (eligibility + source missingness) that is
independent of transcript survival. It is read-only, pure Python standard
library, launches no verification command, invokes no repository-provided
executable, and performs no network access — it reads already-imported bundles,
start manifests, the registry, and an optional cloud census snapshot, and that is
all. `workspace_state` coverage is derived from explicit source-event results,
never analyzer-time inspection, so the analyzer runs no `git`/subprocess. Cloud
launch analysis is excluded in Wave 1 (no durable redacted execution-event source
exists without changing workflows — see `docs/execution-file-shape.md`); cloud
rows are census/missingness-only. It is a sibling measurement substrate to the
efficiency trace (`docs/efficiency-trace.md`): verification launches, not
subagent effectiveness.

### Census and eligibility (the denominator)

Local census rows come from each start manifest under
`.devflow/tmp/workflow-manifests/`; each row has a row-local surrogate ID so
unknown natural-key fields never coalesce. Local identity is session ID + project
path + start time; rows are never joined by issue number, mutable workpad URL,
command text, or timestamp proximity alone. Each row records an
`eligibility_state` of exactly `confirmed_eligible`, `provisional_candidate`,
`confirmed_ineligible`, or `eligibility_unknown`, plus `eligibility_evidence`:
exact slash-command and command-markup starts are confirmed; an embedded
first-message candidate is provisional — the manifest the analyzer reads records
it as an *un-corroborated* candidate (`invocation_evidence:
embedded_user_command_candidate`, written at prompt submit with a warning that
native-transcript corroboration is still required), so this analyzer classifies
it provisional from that recorded `invocation_evidence` and never itself promotes
provisional to confirmed; precheck, dedupe, telemetry, relay, and skipped
non-agent (cloud) jobs are ineligible. Provisional
and unknown rows are never promoted to confirmed and never silently omitted;
reports show the confirmed denominator and the candidate-inclusive sensitivity
bound.

The analyzer left-joins local native imports (`.devflow/tmp/workflow-runs/`) onto
local census rows and distinguishes `eligible_not_imported`, `import_failed`,
`source_missing`, `source_unreadable`, `source_unsupported`, and
`source_available`. Absent, failed, missing, unreadable, and unsupported sources
remain denominator rows with distinct reason codes — never silently dropped. Inventory never imports implicitly; explicit-import semantics
are unchanged.

Cloud census rows come from an explicit, immutable, paginated Actions run/job
census snapshot for one declared repository, workflow set, and closed time
window, produced by `scripts/export-workflow-lifecycle-census.py` (the sole
networked step, explicit-invocation-only) independently of execution files. The
snapshot records its hash, query time, pagination completeness, workflow/job
identity, run ID and attempt, and created/started/completed timestamps plus
conclusion. An absent or incomplete cloud census makes cloud coverage
`unavailable`, never zero. Cloud eligibility comes from trusted workflow/job
identity via the registry's additive `cloud_mappings` section (an allowlisted
workflow-file + job identity + exact agent job name + routed command/consumer +
scheduled/started agent-step evidence — a skipped job, which never ran its agent
step, is ineligible); non-agent jobs are ineligible by omission. Cloud rows
report census, eligibility, and source missingness only — no launch, duration,
relationship, or retry-candidate claims.

### Verification requests and process launches (local-native only)

The analyzer extracts `verification_request` and `verification_process_launch`
records from local native transcripts only (Wave 1). One explicit tool-use ID is
the request unit: each Bash `tool_use` is one request (no compound-input
splitting is performed in Wave 1). A deterministic versioned taxonomy
distinguishes verification requests from other command requests (`verification`,
`other_command`, `verification_unknown`); unrecognized shapes remain
`verification_unknown`. A single native-transcript classifier (a per-source
versioned adapter is a future hook, not a dispatch table today) classifies
authorization/start as `denied_pre_start`, `cancelled_pre_start`,
`start_confirmed_terminal`, `start_confirmed_result_missing`, or
`start_unknown`. Only explicit evidence that the execution surface started a
process creates a launch and contributes to launch duration and retry counts;
denied and start-unknown requests remain request metrics, excluded from
actual-launch counts. Authorization is observational — allowlist membership and
prompt text never become a predicted permission result.

Each request and confirmed launch records source event ID, explicit lifecycle ID
when present, tool-use ID, consumer skill (inferred only from classified
first-message forms), command head, redacted display, safe binding identity,
timing, result presence, exit evidence, skipped-check evidence, and source
provenance. (Phase/checkpoint is not extracted in Wave 1 and is left null.)
Secret-bearing bindings persist
no raw secret and no unkeyed digest of secret material: commands are
canonicalized and redacted before digesting, typed secret-slot markers and
`secret_affected` are recorded, and a redacted digest alone cannot establish an
exact binding match — secret-affected exact matches require the same explicit
source correlation, else confidence is `partial` and excluded from retry-candidate
counts. Join confidence is exactly `exact`, `partial`, `ambiguous`, or
`unmatched`; only explicit lifecycle and source-event identities produce `exact`,
and guessed joins are forbidden.

### Relationship classification (conservative)

Local launch relationships are classified as exactly `single`,
`candidate_transport_retry`, `intentional_rerun_evidence`,
`independent_lifecycle`, or `unclassifiable`. A transport-retry candidate
requires the same explicit lifecycle, consumer/checkpoint when available, safe
binding identity, a prior missing/cancelled response, an explicitly bounded
interval, matching pre/post `workspace_state`, and no explicit new
iteration/checkpoint/retrigger evidence. Distinct lifecycle IDs, cloud run
attempts, command bindings, consumer roles, explicit iterations, explicit
checkpoints, post-fix commits, base merges, and human retriggers cannot be
transport-retry candidates. `workspace_state` declares each covered root and
observation method (HEAD, index, submodule state, all tracked files, all
untracked files, and each ignored/generated/dependency root) from explicit
source-event results, not analyzer-time inspection; unknown, excluded,
truncated, non-enumerated-glob, or outside-workspace roots set
`workspace_state_coverage=incomplete` and classify the relationship
`unclassifiable` with `mutation_state_unbounded`, excluded from candidate counts
and from estimated repeated-suite wall time. Repeated commands are reported as
conservative candidates with explicit evidence and confidence, never as
automatically proven duplicates.

### Metrics, manual review, stratification, and performance

Baseline metrics include eligible lifecycles, eligibility-state bounds, source
availability and missingness, local actual launches, terminal and missing
results, repeated-binding groups, candidate retries, intentional-rerun evidence,
independent lifecycles, unclassifiable groups, workspace-coverage distribution,
join-confidence distribution, command heads, consumers/checkpoints, provenance,
host/profile, child duration, caller-observed duration, and estimated
repeated-suite wall time. Unknown values stay `null`/`unavailable`, never `0`.
Reports state observed counts, candidate counts, evidence limitations, and the
manual-review sample; they never claim launches avoided, terminal evidence
reusable, command authorization safe, or active recovery justified, and cite
source-event IDs only.

Manual review uses relationship groups as the sampling unit. High-cost means the
top duration decile with inclusive ties; all high-cost groups are reviewed plus
`min(50, max(20, ceil(0.1 * remainder)))` remainder groups selected by sorting
`SHA-256(baseline_snapshot_hash || group_id)`. The sample publishes its seed,
eligible population, selected IDs, nonresponses, and adjudication totals;
reviewers see cited source evidence without analyzer relationship labels and
record `confirmed_retry_pattern`, `intentional_rerun`, or
`insufficient_evidence`. Baseline comparison stratifies local launch analysis by
consumer/checkpoint, command binding, host/profile, repository-size bucket,
duration bucket, model, effort, output style, prompt fingerprint, DevFlow
version, Claude/action version, and provider; incomplete strata are marked
non-comparable, and captured-only rows are never presented as the
eligible-lifecycle denominator.

Extraction, classification, sampling, aggregation, manual-review preparation, and
report generation use deterministic Python standard-library code with no
model/provider call, network access, shell, plugin, or tool-enabled analyst; the
census export is the sole networked step and writes only the immutable Actions
metadata snapshot. Performance reporting includes analyzer wall time, peak
memory, input bytes, output bytes, lifecycle count, event count, and
skipped/unsupported source count; a source-level limit breach records a visible
skipped reason and never truncates into a clean classification.

### Security boundaries

The analyzer resolves and validates admitted paths before opening them, rejecting
symlinks, path traversal, and root escapes; redacts and bounds each value before
diagnostics and serialization; and treats transcript text as data to classify,
never instructions to obey. Output is local and gitignored under owner-only
`0700` directories and `0600` files under `.devflow/tmp/verification-baselines/`;
artifacts carry `created_at`, `source_snapshot_hash`, and `expires_at`, and an
explicit `--cleanup` command deletes baseline and manual-review artifacts
without touching native sources. Raw transcript text, tool input, stdout/stderr,
secrets, redacted displays, and source paths are absent from model prompts,
errors, logs, telemetry branches, workflow artifacts, PR comments, and tracked
`.devflow/logs/**`.

### Active-recovery gate (later issue)

This baseline authorizes no active behavior. A later LOCAL active-recovery issue
requires a complete local census snapshot, at least 90% local source-status
resolution, no local missingness stratum above 20%, and at least two
independently adjudicated confirmed patterns in the same proposed
consumer/checkpoint/binding target, plus measured cost and a separately reviewed
trusted-command and lifecycle design; one confirmation remains exploratory.
Cloud active recovery requires a separate evidence-source design and issue.
