# Workflow Transcript Inventory and Short-Command Capture

**Date:** 2026-07-15  
**Status:** Conversational design approved; written review pending  
**Scope:** Local Claude Code transcripts for DevFlow's registered workflow recorder

## 1. Summary

DevFlow will add a read-only inventory command that discovers historical Claude Code sessions whose first authoritative user message invoked a registered workflow. The inventory reports metadata useful for selecting analysis cohorts but never copies, modifies, deletes, or analyzes transcript content. In parallel, the live recorder registry will recognize the approved short command forms so future sessions invoked without the `devflow:` namespace are captured.

## 2. Command recognition

The registry remains the single source of truth for user-command recognition. Add these aliases to the existing namespaced commands:

| Workflow | Recognized user commands |
|---|---|
| `implement` | `/devflow:implement`, `/implement` |
| `create-issue` | `/devflow:create-issue`, `/create-issue` |
| `review-and-fix` | `/devflow:review-and-fix`, `/review-and-fix` |
| `receiving-code-review` | `/devflow:receiving-code-review` |

No short alias is added for `receiving-code-review` in this change because it was not part of the approved request. Both plain slash-command text and Claude's `<command-message>` / `<command-args>` wrapper are recognized through the existing parser.

The live recorder continues to detect every authoritative top-level invocation in a session. Historical discovery is deliberately stricter: it classifies a session only from its first authoritative user message, preventing later skill prose, tool results, quoted commands, or nested workflow activity from turning an unrelated session into a candidate.

## 3. First authoritative user message

For inventory purposes, the first authoritative user message is the earliest transcript record whose effective role is `user` and whose message content contains non-empty user text. The scanner ignores attachment-only records, tool-result-only content arrays, empty records, and non-user records. It does not search later user messages after this first qualifying record.

The first message qualifies only when its complete command invocation matches a registered `user_commands` entry, with optional arguments. A command merely mentioned inside prose does not qualify. Claude command wrapper markup qualifies when its command exactly matches a registered entry.

Malformed or unreadable JSONL is reported as an inventory error for that file and does not stop the remaining scan.

## 4. Inventory interface and output

Add a Python entry point under `scripts/` with a default human-readable table and a deterministic `--json` form suitable for later automation. Its inputs are:

- `--claude-projects-root`, defaulting to the local Claude project store at `~/.claude/projects`;
- `--repo-root`, defaulting to the current repository root;
- the committed workflow registry path, with a test-only override.

The command recursively examines `*.jsonl` files below the Claude project store. It emits one row per qualifying session with:

- workflow and parsed subject;
- session ID and native transcript path;
- originating `cwd` or worktree when present;
- first and last valid timestamps and derived wall-clock duration;
- largest observed inter-event gap, so paused/resumed sessions can be separated from one-shot runs;
- event count and transcript byte size;
- observed model and effort values when present;
- Git branch when present;
- whether `.devflow/tmp/workflow-runs/<session-id>/transcript.jsonl` already exists.

Unavailable fields are `null` in JSON and visibly unavailable in the table, never zero. Rows sort deterministically by start timestamp and session ID. A summary groups counts by workflow and reports scanned, matched, already-bundled, and unreadable files.

The command does not print the first prompt, tool outputs, transcript excerpts, or environment data. It performs no network access and writes no files.

## 5. Repository association

The scan may encounter DevFlow commands used in other repositories. A row belongs to the requested repository when the transcript's recorded `cwd` resolves to the repository root or one of its linked worktrees. When `cwd` is unavailable or no longer exists, the scanner may use the Claude project-directory encoding as supporting evidence; uncertain repository association is surfaced explicitly rather than silently accepted.

Linked worktrees are associated through Git's common directory when it is resolvable. This lets issue worktrees remain discoverable after the recorder itself was centralized, while avoiding a brittle assumption that every session was launched from the main checkout.

## 6. Privacy, safety, and performance

The inventory is metadata-only and read-only. Native transcript files remain in place with their existing permissions. The command never creates flight-recorder bundles; importing or copying a selected historical transcript remains a separate, explicit action.

Scanning is streaming per file rather than loading the entire Claude history into memory at once. A malformed file is isolated to one error row. Permission failures and missing roots produce actionable diagnostics and a non-zero exit only when the requested inventory cannot be meaningfully performed.

## 7. Verification

Tests must establish, with fixtures rather than the user's real transcript store, that:

1. all three approved short aliases and their namespaced forms are detected by the live recorder parser;
2. a short command in the first authoritative user message is inventoried;
3. command wrapper markup is inventoried;
4. attachments, tool results, and empty user records are skipped while finding the first authoritative message;
5. commands appearing only in later messages or prose do not qualify;
6. unrelated repositories are excluded and linked worktrees are included;
7. timestamps, maximum gaps, model, effort, size, and bundle status are reported without inventing zeros;
8. malformed JSONL is isolated and reported;
9. output ordering and JSON shape are deterministic;
10. the full repository test suite remains green.

The implementation follows test-driven development: each behavior is first demonstrated by a focused failing test, then satisfied with the smallest code or registry change.
