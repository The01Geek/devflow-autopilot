# Native Workflow Transcript Inventory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace automatic Stop-time transcript copying with native-session inventory, metadata-only start capture, and explicit byte-verified import while adding the approved short command aliases.

**Architecture:** Extend `workflow_flight_recorder.py` as the shared parsing and artifact layer. Three thin entry points expose read-only inventory, fail-open `UserPromptSubmit` metadata capture, and explicit import. Claude's JSONL remains authoritative; manifests preserve only ephemeral start state, and existing analysis bundles remain compatible.

**Tech Stack:** Python 3 standard library, Claude Code command hooks, JSON/JSONL, Git CLI, `unittest`, repository shell test harness.

## Global Constraints

- Ship this instrumentation work as one coherent batch.
- Inventory is read-only and metadata-only; it never imports implicitly.
- Native Claude JSONL is the transcript source of truth.
- The observer never copies or parses transcript bytes and always fails open.
- Explicit import is the only automatic path that writes a transcript bundle.
- Unknown values remain `null`/unavailable, never zero.
- Raw transcript and manifest artifacts remain local, ignored, and mode `0600` inside mode `0700` directories.
- The registry is the single source of truth for commands and aliases.
- No short alias is added for `receiving-code-review` in this batch.
- No network access or model invocation occurs during inventory, observation, or import.

---

### Task 1: Registry aliases and first-message classification

**Files:**
- Modify: `scripts/workflow-flight-recorder-registry.json`
- Modify: `scripts/workflow_flight_recorder.py`
- Modify: `lib/test/test_workflow_flight_recorder.py`

**Interfaces:**
- Produces: `first_authoritative_user_event(events: list[Event]) -> Event | None`
- Produces: `classify_inventory_occurrences(events, definitions) -> list[Occurrence]`
- Consumes: existing `_user_invocation`, `_skill_definition`, `_subject`, and `detect_occurrences`

- [ ] **Step 1: Write failing tests for aliases and issue-525 classification**

Add cases proving `/implement`, `/create-issue`, and `/review-and-fix` are top-level commands. Add an issue-525-shaped transcript whose first user text embeds `/devflow:receiving-code-review 525` and whose later assistant `Skill` call matches; assert one top-level occurrence begins at the first user event with subject 525. Add controls for embedded prose without a matching Skill call, a matching command that appears only in a later user turn, and tool-result-only user content.

```python
def test_embedded_first_prompt_is_top_level_only_when_skill_call_corroborates(self) -> None:
    events = parse_events(transcript(
        user("Change PR525 to draft, then run /devflow:receiving-code-review 525"),
        skill_call("devflow:receiving-code-review", "525"),
    ))
    found = classify_inventory_occurrences(events, self.registry)
    self.assertEqual([(item.workflow, item.mode, item.subject) for item in found], [
        ("receiving-code-review", "top-level", {"kind": "pull_request", "number": 525})
    ])
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `python3 -m unittest lib.test.test_workflow_flight_recorder.RegistryAndOccurrenceTests -v`

Expected: failures because short commands are absent and `classify_inventory_occurrences` does not exist.

- [ ] **Step 3: Implement the smallest registry and classifier change**

Add the three aliases to `user_commands`. Implement first-authoritative-user extraction by accepting only non-empty text blocks, excluding tool-result-only content. Exact command/markup uses `_user_invocation`. Embedded command candidates are accepted only when exactly one registered command occurs in the first user text and a later matching assistant Skill call has the same workflow and subject. Promote that corroborated call to a top-level occurrence whose start is the first user event; do not scan later user messages for another root.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run: `python3 -m unittest lib.test.test_workflow_flight_recorder.RegistryAndOccurrenceTests -v`

Expected: all classifier and registry tests pass.

### Task 2: Read-only native transcript inventory

**Files:**
- Create: `scripts/inventory-workflow-transcripts.py`
- Modify: `scripts/workflow_flight_recorder.py`
- Modify: `lib/test/test_workflow_flight_recorder.py`

**Interfaces:**
- Produces: `InventoryRow` dataclass with workflow, subject, session/path/cwd, timestamps, duration/gap, counts, model/effort/branch, association confidence, manifest status, and import status
- Produces: `inventory_native_transcripts(projects_root, repository_root, registry_path) -> InventoryResult`
- CLI: `inventory-workflow-transcripts.py [--json] [--claude-projects-root PATH] [--repo-root PATH] [--registry PATH]`

- [ ] **Step 1: Write failing fixture-based inventory tests**

Create temporary Claude project directories with exact, wrapped, embedded/corroborated, later-only, malformed, unrelated-repository, linked-worktree, and unknown-field transcripts. Assert deterministic row ordering and summary counts; assert unavailable timestamps/model/effort remain `None`; assert no prompt text appears in JSON output.

- [ ] **Step 2: Run the inventory test class and verify RED**

Run: `python3 -m unittest lib.test.test_workflow_flight_recorder.InventoryTests -v`

Expected: import/attribute failures because the inventory API and entry point do not exist.

- [ ] **Step 3: Implement one-file-at-a-time discovery**

Recursively iterate sorted `*.jsonl`, parse one file, call `classify_inventory_occurrences`, verify repository association through recorded cwd/Git common-dir with encoded-directory fallback marked uncertain, and derive metadata from native events. Catch malformed/unreadable files into an error count without stopping the scan. Sort rows by `(started_at is None, started_at, session_id, native_path)`.

- [ ] **Step 4: Implement deterministic table and JSON renderers**

The JSON document contains `schema_version`, `repository_root`, `sessions`, `errors`, and `summary`. The table prints no prompt excerpts. Return non-zero only for an unavailable projects root or when no meaningful scan can occur.

- [ ] **Step 5: Run inventory tests and verify GREEN**

Run: `python3 -m unittest lib.test.test_workflow_flight_recorder.InventoryTests -v`

Expected: all inventory tests pass.

### Task 3: Metadata-only UserPromptSubmit observer

**Files:**
- Create: `scripts/capture-workflow-manifest.py`
- Modify: `scripts/workflow_flight_recorder.py`
- Modify: `lib/test/test_workflow_flight_recorder.py`
- Modify locally (ignored): `.claude/settings.local.json`

**Interfaces:**
- Produces: `capture_prompt_manifest(payload: dict[str, Any], registry_path: Path) -> dict[str, Any]`
- Produces: `fail_open_manifest_main(registry_path: Path, stream: Any = sys.stdin) -> int`
- Manifest: `.devflow/tmp/workflow-manifests/<session-id>.json`

- [ ] **Step 1: Write failing observer tests**

Test exact, wrapper, and embedded candidates; linked-worktree central storage; Git/config/prompt-surface fields; `null` model/effort; unsafe IDs; malformed payloads; non-candidate prompts; and absence of any `transcript.jsonl` or workflow-run bundle. Drive the thin entry point with a real stdin payload and assert exit zero on every failure.

- [ ] **Step 2: Run observer tests and verify RED**

Run: `python3 -m unittest lib.test.test_workflow_flight_recorder.ManifestObserverTests -v`

Expected: failures because the observer API and entry point do not exist.

- [ ] **Step 3: Implement the fail-open manifest observer**

Accept `user_prompt` or `prompt`, validate session/cwd/transcript-path strings without reading transcript bytes, detect one provisional command candidate from the prompt, snapshot repository/config/prompt metadata, and atomically write a schema-versioned manifest. Use the shared storage root and existing `_atomic_write`, `_claude_configuration`, `_provider_classification`, and `measure_prompt_surfaces` primitives.

- [ ] **Step 4: Replace only the local recorder hook wiring**

Remove the flight-recorder command from the local `Stop` group and add a cwd-independent `UserPromptSubmit` command for `capture-workflow-manifest.py`. Leave every non-recorder hook unchanged. Note that active Claude sessions must restart before new hook configuration loads.

- [ ] **Step 5: Run observer tests and verify GREEN**

Run: `python3 -m unittest lib.test.test_workflow_flight_recorder.ManifestObserverTests -v`

Expected: all observer tests pass and no transcript bundle exists.

### Task 4: Explicit native import and partial-bundle refresh

**Files:**
- Create: `scripts/import-workflow-transcript.py`
- Modify: `scripts/workflow_flight_recorder.py`
- Modify: `lib/test/test_workflow_flight_recorder.py`
- Modify: `lib/test/run.sh`

**Interfaces:**
- Produces: `import_inventory_session(session_id, projects_root, repository_root, registry_path) -> Path`
- CLI: `import-workflow-transcript.py SESSION_ID [--claude-projects-root PATH] [--repo-root PATH] [--registry PATH]`
- Consumes: inventory classification and existing bundle/event/prompt writers

- [ ] **Step 1: Write failing import tests using issue-522/525-shaped tails**

Seed a native transcript longer than an existing bundle, import by session ID, and assert source/destination SHA-256 and bytes match, the final tail is present, the occurrence is correctly top-level, start-manifest prompt data wins when present, import-time fallback is warned when absent, attempts append, and directory/file modes are `0700`/`0600`. Test missing and duplicate session IDs fail without mutation.

- [ ] **Step 2: Run import tests and verify RED**

Run: `python3 -m unittest lib.test.test_workflow_flight_recorder.ImportTests -v`

Expected: failures because explicit import does not exist.

- [ ] **Step 3: Extract a reusable bundle writer and implement import**

Refactor the current Stop-capture body into a private writer that accepts already-read native bytes, classified occurrences, repository/storage roots, and optional start manifest. Explicit import inventories to locate exactly one native source, reads it only after selection, writes atomically, re-reads destination to verify byte identity, and appends an `explicit_import` attempt. Keep `capture-implement-session.py` as an unwired compatibility entry point so existing bundles and callers do not break.

- [ ] **Step 4: Replace old shell-harness capture assertions**

Update the flight-recorder block in `lib/test/run.sh` to drive manifest capture, read-only inventory, and explicit import. Pin that the configured recorder hook is `UserPromptSubmit`, that no recorder command remains in the local Stop group documentation/example, and that import—not observation—creates the transcript bundle.

- [ ] **Step 5: Run focused recorder tests and verify GREEN**

Run: `python3 lib/test/test_workflow_flight_recorder.py && bash -n lib/test/run.sh`

Expected: Python recorder tests pass and the shell harness is syntactically valid.

### Task 5: Documentation, live inventory, and full verification

**Files:**
- Modify: `docs/workflow-flight-recorder.md`
- Modify: `docs/DEVFLOW_SYSTEM_OVERVIEW.md`

**Interfaces:**
- Documents: native source-of-truth, manifest lifecycle, explicit import, short aliases, embedded invocation evidence, privacy, and hook restart requirement

- [ ] **Step 1: Update docs concisely**

Replace Stop-copy language with the three-stage flow: native Claude JSONL → metadata manifest → explicit selected import. State that raw native retention is Claude-owned, selected imports remain sensitive, and older bundles remain readable. Preserve the warning that Default vs Explanatory output style is an experimental treatment.

- [ ] **Step 2: Run the new inventory against the real local store**

Run:

```bash
python3 scripts/inventory-workflow-transcripts.py \
  --repo-root /Users/the01geek/repos/devflow-autopilot \
  --claude-projects-root /Users/the01geek/.claude/projects \
  --json
```

Expected: issues 489, 519, 520, 522, and receiving-code-review 525 appear where they satisfy first-message rules; 525 is top-level and reports its complete 190-record native transcript; prompt content is absent.

- [ ] **Step 3: Run focused verification**

Run: `python3 lib/test/test_workflow_flight_recorder.py`

Expected: zero failures.

- [ ] **Step 4: Run the full repository suite**

Run: `./lib/test/run.sh`

Expected: zero failures and no new skips.

- [ ] **Step 5: Review the final diff and operational state**

Run: `git diff --check && git status --short && git diff --stat`

Confirm only the approved instrumentation batch and its documentation changed, `.claude/settings.local.json` is the intentional ignored local hook update, native transcripts are untouched, and no `.devflow/tmp` artifact is staged.
