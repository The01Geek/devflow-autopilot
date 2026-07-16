# Workflow Transcript Inventory and Short-Command Capture

**Date:** 2026-07-15
**Status:** Approved
**Scope:** Local Claude Code transcripts for DevFlow's registered workflow recorder

## 1. Summary

DevFlow will add a read-only inventory command that discovers historical Claude Code sessions whose first authoritative user message invoked a registered workflow. Claude's native JSONL remains the transcript source of truth. The inventory reports metadata useful for selecting analysis cohorts but never copies, modifies, deletes, or analyzes transcript content.

A lightweight `UserPromptSubmit` observer records only ephemeral start-time metadata that cannot be reconstructed reliably later. An explicit import command copies a selected native transcript into an analysis bundle. The automatic `Stop` observer no longer copies transcripts: issues 522 and 525 proved that Claude can append records after the observer reads the file, leaving the automatic copy shorter than the native source.

The live registry also recognizes the approved short command forms so future sessions invoked without the `devflow:` namespace are classified consistently.

## 2. Command recognition

The registry remains the single source of truth for user-command recognition. Add these aliases to the existing namespaced commands:

| Workflow | Recognized user commands |
|---|---|
| `implement` | `/devflow:implement`, `/implement` |
| `create-issue` | `/devflow:create-issue`, `/create-issue` |
| `review-and-fix` | `/devflow:review-and-fix`, `/review-and-fix` |
| `receiving-code-review` | `/devflow:receiving-code-review` |

No short alias is added for `receiving-code-review` in this change because it was not part of the approved request. Both plain slash-command text and Claude's `<command-message>` / `<command-args>` wrapper are recognized through the existing parser.

Historical discovery classifies a session only from its first authoritative user message, preventing later skill prose, tool results, quoted commands, or nested workflow activity from turning an unrelated session into a candidate. A bare command or Claude command wrapper is sufficient. When the first message embeds the command in a larger instruction, the inventory requires a later matching assistant `Skill` invocation as corroboration and classifies that occurrence as top-level rather than as an orphaned nested workflow.

## 3. First authoritative user message

For inventory purposes, the first authoritative user message is the earliest transcript record whose effective role is `user` and whose message content contains non-empty user text. The scanner ignores attachment-only records, tool-result-only content arrays, empty records, and non-user records. It does not search later user messages after this first qualifying record.

The first message qualifies through one of two evidence paths:

1. Its complete command invocation matches a registered `user_commands` entry, with optional arguments, or Claude command wrapper markup names that exact command.
2. It contains one unambiguous registered command invocation with arguments inside a larger instruction, and the transcript later contains an assistant `Skill` tool call for the same workflow and subject.

A command merely mentioned inside prose without the matching execution evidence does not qualify. The second path covers real prompts such as `Change PR525 to draft, then run /devflow:receiving-code-review 525` without admitting documentation examples or later command mentions.

Malformed or unreadable JSONL is reported as an inventory error for that file and does not stop the remaining scan.

## 4. Inventory interface and output

Add a Python inventory entry point under `scripts/` with a default human-readable table and a deterministic `--json` form suitable for later automation. Its inputs are:

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
- whether a start-time manifest exists;
- whether `.devflow/tmp/workflow-runs/<session-id>/transcript.jsonl` was explicitly imported already.

Unavailable fields are `null` in JSON and visibly unavailable in the table, never zero. Rows sort deterministically by start timestamp and session ID. A summary groups counts by workflow and reports scanned, matched, already-bundled, and unreadable files.

The command does not print the first prompt, tool outputs, transcript excerpts, or environment data. It performs no network access and writes no files.

## 5. Metadata-only start observer

Replace the transcript-copying Stop observer with a deterministic `UserPromptSubmit` command observer. It reads the hook payload from stdin and exits immediately unless the submitted first prompt contains a registered command candidate. For a candidate it writes one central manifest under `.devflow/tmp/workflow-manifests/<session-id>.json`, resolving linked worktrees through Git's common directory just as the repaired recorder launcher does.

The manifest records only contemporaneous metadata:

- session ID, native transcript path, submitted-at timestamp, and originating `cwd`;
- provisional workflow, subject, and invocation evidence;
- repository root, Git HEAD, branch, and dirty-state boolean;
- DevFlow/plugin version and selected Claude configuration when locally readable;
- prompt-surface fingerprints and line, word, byte, and approximate-token totals;
- model and effort only when the hook payload supplies them, otherwise `null`.

It does not copy or parse the transcript, launch a model, use the network, or block prompt submission. Embedded candidates remain provisional until the inventory corroborates them with the assistant `Skill` call.

Hook commands are cwd-independent, quote all paths, and resolve the shared checkout from Git's absolute common directory. The observer is fail-open and emits one concise stderr breadcrumb on failure. Existing non-recorder Stop hooks keep their current behavior.

## 6. Explicit import

Add a separate command that accepts one inventory session ID and copies that native JSONL into `.devflow/tmp/workflow-runs/<session-id>/` for analysis. Import re-reads the complete native file, combines it with the start manifest when present, creates the existing metadata/occurrence/event-summary/prompt-surface artifacts, and verifies the destination bytes against the source before reporting success.

Import is idempotent and refreshes a shorter historical bundle in place while appending an attempt record. It never changes or deletes the native source. The read-only inventory command never imports implicitly.

## 7. Repository association

The scan may encounter DevFlow commands used in other repositories. A row belongs to the requested repository when the transcript's recorded `cwd` resolves to the repository root or one of its linked worktrees. When `cwd` is unavailable or no longer exists, the scanner may use the Claude project-directory encoding as supporting evidence; uncertain repository association is surfaced explicitly rather than silently accepted.

Linked worktrees are associated through Git's common directory when it is resolvable. This lets issue worktrees remain discoverable after the recorder itself was centralized, while avoiding a brittle assumption that every session was launched from the main checkout.

## 8. Privacy, safety, and performance

The inventory is metadata-only and read-only. Native transcript files remain in place with their existing permissions. Only the explicit import command creates or refreshes flight-recorder bundles.

Scanning is streaming per file rather than loading the entire Claude history into memory at once. A malformed file is isolated to one error row. Permission failures and missing roots produce actionable diagnostics and a non-zero exit only when the requested inventory cannot be meaningfully performed.

## 9. Batched delivery policy

This instrumentation work ships as one coherent batch: registry aliases, native inventory, metadata-only observer, explicit import, classification correction, tests, and documentation. Later performance changes are grouped into hypothesis-coherent batches rather than forced into one-change-at-a-time delivery. Each batch has a baseline, expected cumulative effect, quality guardrails, and rollback point. Fine-grained ablation is reserved for a regression or an ambiguous batch result.

## 10. Verification

Tests must establish, with fixtures rather than the user's real transcript store, that:

1. all three approved short aliases and their namespaced forms are detected by the live recorder parser;
2. a short command in the first authoritative user message is inventoried;
3. command wrapper markup is inventoried;
4. attachments, tool results, and empty user records are skipped while finding the first authoritative message;
5. an embedded first-message command plus matching assistant `Skill` call qualifies as top-level, while prose without corroboration and commands appearing only in later messages do not;
6. unrelated repositories are excluded and linked worktrees are included;
7. timestamps, maximum gaps, model, effort, size, manifest status, and import status are reported without inventing zeros;
8. malformed JSONL is isolated and reported;
9. output ordering and JSON shape are deterministic;
10. the metadata observer writes no transcript bytes and fails open;
11. explicit import refreshes a shorter bundle from the complete native source, is byte-identical, and preserves mode `0600`;
12. issue-522/525-shaped fixtures prove that the inventory and import use the native tail rather than a shorter Stop-time snapshot;
13. the full repository test suite remains green.

The implementation follows test-driven development: each behavior is first demonstrated by a focused failing test, then satisfied with the smallest code or registry change.
