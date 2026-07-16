#!/usr/bin/env python3
"""Focused tests for the local DevFlow workflow flight recorder."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import workflow_flight_recorder as recorder  # noqa: E402

from workflow_flight_recorder import (  # noqa: E402
    build_event_summary,
    capture_stop_payload,
    detect_occurrences,
    load_registry,
    parse_events,
    resolve_boundaries,
)


REGISTRY = ROOT / "scripts/workflow-flight-recorder-registry.json"


def transcript(*records: dict) -> bytes:
    return ("\n".join(json.dumps(record) for record in records) + "\n").encode()


def user(content: str, timestamp: str = "2026-07-16T01:00:00Z") -> dict:
    return {
        "type": "user",
        "timestamp": timestamp,
        "message": {"role": "user", "content": content},
    }


def assistant_text(content: str, timestamp: str = "2026-07-16T01:01:00Z") -> dict:
    return {
        "type": "assistant",
        "timestamp": timestamp,
        "message": {"role": "assistant", "content": content},
    }


def skill_call(skill: str, args: str = "", timestamp: str = "2026-07-16T01:02:00Z") -> dict:
    return {
        "type": "assistant",
        "timestamp": timestamp,
        "message": {
            "role": "assistant",
            "content": [
                {
                    "type": "tool_use",
                    "id": f"skill-{skill}-{timestamp}",
                    "name": "Skill",
                    "input": {"skill": skill, "args": args},
                }
            ],
        },
    }


class RegistryAndOccurrenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.registry = load_registry(REGISTRY)

    def test_registry_has_the_initial_four_workflows(self) -> None:
        self.assertEqual(
            set(self.registry),
            {"implement", "create-issue", "receiving-code-review", "review-and-fix"},
        )

    def test_each_user_command_creates_a_top_level_occurrence(self) -> None:
        cases = [
            ("/devflow:implement 520", "implement", {"kind": "issue", "number": 520}),
            ("/devflow:create-issue improve local capture", "create-issue", {"kind": "topic", "value": "improve local capture"}),
            ("/devflow:receiving-code-review 42", "receiving-code-review", {"kind": "pull_request", "number": 42}),
            ("/devflow:review-and-fix #77", "review-and-fix", {"kind": "pull_request", "number": 77}),
        ]
        for command, workflow, subject in cases:
            with self.subTest(command=command):
                found = detect_occurrences(parse_events(transcript(user(command))), self.registry)
                self.assertEqual(len(found), 1)
                self.assertEqual(found[0].workflow, workflow)
                self.assertEqual(found[0].mode, "top-level")
                self.assertEqual(found[0].subject, subject)
                self.assertEqual(found[0].invocation_source, "user_command")

    def test_short_user_commands_create_top_level_occurrences(self) -> None:
        cases = [
            ("/implement 520", "implement", {"kind": "issue", "number": 520}),
            ("/create-issue improve local capture", "create-issue", {"kind": "topic", "value": "improve local capture"}),
            ("/review-and-fix #77", "review-and-fix", {"kind": "pull_request", "number": 77}),
        ]
        for command, workflow, subject in cases:
            with self.subTest(command=command):
                found = detect_occurrences(parse_events(transcript(user(command))), self.registry)
                self.assertEqual(
                    [(item.workflow, item.mode, item.subject) for item in found],
                    [(workflow, "top-level", subject)],
                )

    def test_embedded_first_prompt_is_top_level_only_when_skill_call_corroborates(self) -> None:
        events = parse_events(
            transcript(
                user("Change PR525 to draft, then run /devflow:receiving-code-review 525"),
                skill_call("devflow:receiving-code-review", "525"),
            )
        )
        found = recorder.classify_inventory_occurrences(events, self.registry)
        self.assertEqual(
            [(item.workflow, item.mode, item.subject) for item in found],
            [("receiving-code-review", "top-level", {"kind": "pull_request", "number": 525})],
        )
        self.assertEqual(found[0].start_event, events[0].index)

    def test_embedded_first_prompt_without_matching_skill_call_does_not_classify(self) -> None:
        events = parse_events(
            transcript(user("Please document /devflow:receiving-code-review 525 for the team"))
        )
        self.assertEqual(recorder.classify_inventory_occurrences(events, self.registry), [])

    def test_matching_command_in_a_later_user_turn_does_not_classify(self) -> None:
        events = parse_events(
            transcript(
                user("Change PR525 to draft"),
                user("/devflow:receiving-code-review 525", "2026-07-16T01:01:00Z"),
                skill_call("devflow:receiving-code-review", "525"),
            )
        )
        self.assertEqual(recorder.classify_inventory_occurrences(events, self.registry), [])

    def test_tool_result_only_user_content_is_not_the_first_authoritative_message(self) -> None:
        events = parse_events(
            transcript(
                {
                    "type": "user",
                    "timestamp": "2026-07-16T01:00:00Z",
                    "message": {
                        "role": "user",
                        "content": [
                            {
                                "type": "tool_result",
                                "tool_use_id": "tool-1",
                                "content": "/implement 999",
                            }
                        ],
                    },
                },
                user("/review-and-fix 525", "2026-07-16T01:01:00Z"),
            )
        )
        self.assertEqual(recorder.first_authoritative_user_event(events), events[1])
        found = recorder.classify_inventory_occurrences(events, self.registry)
        self.assertEqual(
            [(item.workflow, item.mode, item.subject, item.start_event) for item in found],
            [("review-and-fix", "top-level", {"kind": "pull_request", "number": 525}, 1)],
        )

    def test_nested_skill_is_parented_to_top_level_implement(self) -> None:
        events = parse_events(
            transcript(
                user("/devflow:implement 520"),
                skill_call("review-and-fix", "--push-each-iteration"),
                skill_call("review-and-fix", "--push-each-iteration", "2026-07-16T01:03:00Z"),
            )
        )
        found = detect_occurrences(events, self.registry)
        self.assertEqual([item.occurrence_id for item in found], ["implement-1", "review-and-fix-1", "review-and-fix-2"])
        self.assertEqual(found[1].mode, "nested")
        self.assertEqual(found[1].parent_occurrence_id, "implement-1")
        self.assertEqual(found[2].parent_occurrence_id, "implement-1")

    def test_assistant_prose_and_tool_output_do_not_classify(self) -> None:
        records = [
            assistant_text("Try /devflow:review-and-fix 77"),
            user("I often run /devflow:review-and-fix 77"),
            {
                "type": "tool_result",
                "timestamp": "2026-07-16T01:02:00Z",
                "content": "/devflow:create-issue not an invocation",
            },
        ]
        self.assertEqual(detect_occurrences(parse_events(transcript(*records)), self.registry), [])

    def test_nested_parent_does_not_cross_a_new_top_level_root(self) -> None:
        events = parse_events(
            transcript(
                user("/devflow:implement 520"),
                user("/devflow:create-issue improve capture", "2026-07-16T01:01:00Z"),
                skill_call("review-and-fix", "520"),
            )
        )
        found = detect_occurrences(events, self.registry)
        self.assertIsNone(found[-1].parent_occurrence_id)

    def test_message_role_is_authoritative_over_contradictory_type(self) -> None:
        contradictory = skill_call("review-and-fix", "520")
        contradictory["message"]["role"] = "user"
        self.assertEqual(detect_occurrences(parse_events(transcript(contradictory)), self.registry), [])

    def test_command_markup_is_user_evidence(self) -> None:
        content = (
            "<command-message>devflow:implement</command-message>"
            "<command-args>521</command-args>"
        )
        found = detect_occurrences(parse_events(transcript(user(content))), self.registry)
        self.assertEqual(found[0].subject, {"kind": "issue", "number": 521})

    def test_malformed_jsonl_tail_is_rejected(self) -> None:
        raw = transcript(user("/devflow:implement 520")) + b"{broken\n"
        with self.assertRaisesRegex(ValueError, "line 2"):
            parse_events(raw)


class TimingAndSummaryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.registry = load_registry(REGISTRY)

    def test_exact_completion_marker_sets_normalized_boundary(self) -> None:
        records = [
            user("/devflow:implement 520", "2026-07-15T19:00:00-06:00"),
            skill_call("review-and-fix", "520", "2026-07-16T01:03:00Z"),
            {
                "type": "assistant",
                "timestamp": "2026-07-16T01:05:00.125Z",
                "workflow_completion": {"workflow": "review-and-fix"},
                "message": {"role": "assistant", "content": "done"},
            },
        ]
        events = parse_events(transcript(*records))
        occurrences = detect_occurrences(events, self.registry)
        resolve_boundaries(events, occurrences)
        implement, review = occurrences
        self.assertEqual(implement.started_at, "2026-07-16T01:00:00.000Z")
        self.assertEqual(review.finished_at, "2026-07-16T01:05:00.125Z")
        self.assertEqual(review.duration_ms, 120125)
        self.assertEqual(review.boundary_confidence, "exact")
        self.assertEqual(review.finish_timestamp_source, "explicit_completion_marker")

    def test_parent_continuation_is_approximate_and_missing_time_stays_unknown(self) -> None:
        records = [
            user("/devflow:implement 520"),
            skill_call("review-and-fix", "520", timestamp=""),
            {
                "type": "assistant",
                "timestamp": "2026-07-16T01:04:00Z",
                "parent_continuation": "implement",
                "message": {"role": "assistant", "content": "continuing parent"},
            },
        ]
        events = parse_events(transcript(*records))
        occurrences = detect_occurrences(events, self.registry)
        resolve_boundaries(events, occurrences)
        nested = occurrences[1]
        self.assertEqual(nested.end_event, 2)
        self.assertEqual(nested.boundary_confidence, "approximate")
        self.assertEqual(nested.finished_at, "2026-07-16T01:04:00.000Z")
        self.assertIsNone(nested.duration_ms)

    def test_terminal_stop_is_an_approximate_real_boundary_with_occurrence_model_effort(self) -> None:
        records = [
            user("/devflow:implement 520", "2026-07-16T01:00:00Z"),
            {
                "type": "assistant",
                "timestamp": "2026-07-16T01:00:01Z",
                "model": "claude-opus-4-6",
                "effort": "high",
                "message": {"role": "assistant", "content": "working"},
            },
            assistant_text("stopped", "2026-07-16T01:05:00Z"),
        ]
        events = parse_events(transcript(*records))
        occurrences = detect_occurrences(events, self.registry)
        resolve_boundaries(events, occurrences)
        occurrence = occurrences[0]
        self.assertEqual(occurrence.finish_timestamp_source, "terminal_stop_boundary")
        self.assertEqual(occurrence.boundary_confidence, "approximate")
        self.assertEqual(occurrence.finished_at, "2026-07-16T01:05:00.000Z")
        self.assertEqual(occurrence.duration_ms, 300000)
        self.assertEqual(occurrence.observed_models, ["claude-opus-4-6"])
        self.assertEqual(occurrence.observed_effort, ["high"])
        self.assertEqual(occurrence.model_effort_source, "events_within_boundary")

    def test_next_top_level_root_bounds_prior_occurrence_at_previous_event(self) -> None:
        records = [
            user("/devflow:implement 520", "2026-07-16T01:00:00Z"),
            {"type": "assistant", "timestamp": "2026-07-16T01:01:00Z", "model": "model-a", "message": {"role": "assistant", "content": "implement work"}},
            user("/devflow:create-issue another topic", "2026-07-16T01:02:00Z"),
            {"type": "assistant", "timestamp": "2026-07-16T01:03:00Z", "model": "model-b", "message": {"role": "assistant", "content": "issue work"}},
        ]
        events = parse_events(transcript(*records))
        occurrences = detect_occurrences(events, self.registry)
        resolve_boundaries(events, occurrences)
        implement, create_issue = occurrences
        self.assertEqual(implement.end_event, 1)
        self.assertEqual(implement.finish_timestamp_source, "next_top_level_boundary")
        self.assertEqual(implement.observed_models, ["model-a"])
        self.assertNotIn("model-b", implement.observed_models)
        self.assertEqual(create_issue.finish_timestamp_source, "terminal_stop_boundary")

    def test_summary_records_model_effort_usage_tools_and_gaps(self) -> None:
        records = [
            user("/devflow:implement 520"),
            {
                "type": "assistant",
                "timestamp": "2026-07-16T01:00:01Z",
                "model": "claude-opus-4-6",
                "effort": "high",
                "usage": {"input_tokens": 120, "output_tokens": 30},
                "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "false"}}]},
            },
            {
                "type": "user",
                "timestamp": "2026-07-16T01:00:03Z",
                "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "is_error": True, "content": "permission denied"}]},
            },
            {
                "type": "assistant",
                "timestamp": "2026-07-16T01:00:04Z",
                "model": "claude-opus-4-6",
                "effort": "high",
                "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "t2", "name": "Bash", "input": {"command": "false"}}]},
            },
            {
                "type": "assistant",
                "timestamp": "2026-07-16T01:10:04Z",
                "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "a1", "name": "Agent", "input": {"prompt": "review"}}]},
            },
            {"type": "system", "timestamp": "2026-07-16T01:10:05Z", "subtype": "compact_boundary", "message": {"role": "system", "content": "summary omitted"}},
        ]
        events = parse_events(transcript(*records))
        occurrences = detect_occurrences(events, self.registry)
        summary = build_event_summary(events, occurrences)
        self.assertEqual(summary["model_effort"]["observed_models"], ["claude-opus-4-6"])
        self.assertEqual(summary["model_effort"]["observed_effort"], ["high"])
        self.assertEqual(summary["usage"]["shape"], "real")
        self.assertEqual(summary["usage"]["figures"]["input_tokens"], 120)
        self.assertEqual(summary["tool_calls"]["by_name"], {"Agent": 1, "Bash": 2})
        self.assertEqual(summary["tool_calls"]["failed"], 1)
        self.assertEqual(summary["tool_calls"]["permission_denials"], 1)
        self.assertEqual(summary["tool_calls"]["equivalent_retries"], 1)
        self.assertEqual(summary["tool_calls"]["paired_duration_count"], 1)
        self.assertEqual(summary["subagents"]["dispatched"], 1)
        self.assertEqual(summary["compactions"]["count"], 1)
        self.assertEqual(summary["gaps"]["longest_ms"], 600000)
        self.assertNotIn("permission denied", json.dumps(summary))

    def test_placeholder_usage_and_decreasing_time_are_not_claimed_real(self) -> None:
        records = [
            {"type": "assistant", "timestamp": "2026-07-16T01:00:02Z", "usage": {"input_tokens": 0, "output_tokens": 0}, "message": {"role": "assistant", "content": "a"}},
            {"type": "assistant", "timestamp": "2026-07-16T01:00:01Z", "message": {"role": "assistant", "content": "b"}},
        ]
        summary = build_event_summary(parse_events(transcript(*records)), [])
        self.assertEqual(summary["usage"]["shape"], "placeholder")
        self.assertIsNone(summary["usage"]["figures"])
        self.assertIsNone(summary["gaps"]["longest_ms"])
        self.assertTrue(any(item["kind"] == "decreasing_timestamp" for item in summary["evidence"]))


class CaptureTests(unittest.TestCase):
    def test_linked_worktree_launches_shared_recorder_and_stores_centrally(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sandbox = Path(temporary)
            shared = sandbox / "shared"
            linked = sandbox / "linked"
            shared.mkdir()

            def git(*args: str, cwd: Path = shared) -> str:
                result = subprocess.run(
                    ["git", *args],
                    cwd=cwd,
                    check=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                return result.stdout.strip()

            git("init", "-q")
            git("config", "user.email", "recorder-test@example.invalid")
            git("config", "user.name", "Recorder Test")
            for relative in [
                "skills/implement/SKILL.md",
                "skills/implement/phases/setup.md",
                "skills/review/SKILL.md",
                "skills/review-and-fix/SKILL.md",
                "skills/docs/SKILL.md",
            ]:
                path = shared / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(f"# linked {relative}\n", encoding="utf-8")
            git("add", "skills")
            git("commit", "-qm", "base without recorder")
            base_sha = git("rev-parse", "HEAD")

            for name in [
                "capture-implement-session.py",
                "workflow_flight_recorder.py",
                "workflow-flight-recorder-registry.json",
            ]:
                destination = shared / "scripts" / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / "scripts" / name, destination)
            git("add", "scripts")
            git("commit", "-qm", "add recorder only to shared checkout")
            git("worktree", "add", "-q", "--detach", str(linked), base_sha)
            (linked / "nested").mkdir()
            transcript_path = linked / "session.jsonl"
            transcript_path.write_bytes(transcript(user("/devflow:implement 520")))

            self.assertFalse((linked / "scripts/capture-implement-session.py").exists())
            payload = json.dumps(
                {
                    "session_id": "sid-linked",
                    "transcript_path": str(transcript_path),
                    "cwd": str(linked / "nested"),
                }
            )
            command = (
                'python3 "$(git rev-parse --path-format=absolute '
                '--git-common-dir 2>/dev/null)/../scripts/capture-implement-session.py"'
            )
            launched = subprocess.run(
                command,
                cwd=linked / "nested",
                shell=True,
                executable="/bin/bash",
                input=payload,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
            )
            self.assertEqual(launched.returncode, 0, launched.stderr)

            central_bundle = shared / ".devflow/tmp/workflow-runs/sid-linked"
            self.assertTrue((central_bundle / "transcript.jsonl").is_file())
            self.assertFalse((linked / ".devflow/tmp/workflow-runs/sid-linked").exists())
            metadata = json.loads((central_bundle / "metadata.json").read_text())
            self.assertEqual(metadata["repository_root"], str(linked.resolve()))
            self.assertEqual(metadata["storage_root"], str(shared.resolve()))
            self.assertEqual(metadata["storage_root_source"], "git_common_dir_parent")
            manifest = json.loads((central_bundle / "prompt-surfaces.json").read_text())
            self.assertTrue(
                any(item["path"] == "skills/implement/SKILL.md" for item in manifest["surfaces"])
            )

    def test_one_generic_bundle_stores_multiple_occurrences_and_config_provenance(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / ".git").mkdir()
            (root / "skills/implement/phases").mkdir(parents=True)
            (root / "skills/review").mkdir(parents=True)
            (root / "skills/review-and-fix").mkdir(parents=True)
            (root / "skills/docs").mkdir(parents=True)
            (root / ".claude").mkdir()
            for relative in [
                "skills/implement/SKILL.md",
                "skills/implement/phases/setup.md",
                "skills/review/SKILL.md",
                "skills/review-and-fix/SKILL.md",
                "skills/docs/SKILL.md",
            ]:
                path = root / relative
                path.write_text(f"# {relative}\n", encoding="utf-8")
            (root / ".claude/settings.local.json").write_text(
                json.dumps({"outputStyle": "Default", "verbose": True, "viewMode": "verbose"}),
                encoding="utf-8",
            )
            transcript_path = root / "session.jsonl"
            transcript_path.write_bytes(
                transcript(user("/devflow:implement 520"), skill_call("review-and-fix", "520"))
            )
            result = capture_stop_payload(
                {"session_id": "sid-capture", "transcript_path": str(transcript_path), "cwd": str(root)},
                REGISTRY,
            )
            self.assertTrue(result["captured"])
            bundle = root / ".devflow/tmp/workflow-runs/sid-capture"
            self.assertEqual(json.loads((bundle / "occurrences.json").read_text())[1]["workflow"], "review-and-fix")
            metadata = json.loads((bundle / "metadata.json").read_text())
            self.assertEqual(metadata["occurrence_count"], 2)
            self.assertEqual(metadata["repository_root"], str(root.resolve()))
            self.assertEqual(metadata["storage_root"], str(root.resolve()))
            self.assertEqual(metadata["storage_root_source"], "repository_root_fallback")
            self.assertEqual(metadata["claude_configuration"]["outputStyle"]["value"], "Default")
            self.assertEqual(metadata["claude_configuration"]["outputStyle"]["source"], "project_local_settings")
            manifests = json.loads((bundle / "prompt-surfaces.json").read_text())
            self.assertIn("implement", manifests["fingerprints"])
            physical_bytes = sum(
                len((root / relative).read_bytes())
                for relative in {
                    "skills/implement/SKILL.md",
                    "skills/implement/phases/setup.md",
                    "skills/review/SKILL.md",
                    "skills/review-and-fix/SKILL.md",
                    "skills/docs/SKILL.md",
                }
            )
            self.assertEqual(manifests["session_unique_totals"]["bytes"], physical_bytes)
            self.assertEqual((bundle / "transcript.jsonl").read_bytes(), transcript_path.read_bytes())

    def test_non_workflow_session_creates_no_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / ".git").mkdir()
            transcript_path = root / "session.jsonl"
            transcript_path.write_bytes(transcript(user("hello")))
            result = capture_stop_payload(
                {"session_id": "sid-none", "transcript_path": str(transcript_path), "cwd": str(root)},
                REGISTRY,
            )
            self.assertFalse(result["captured"])
            self.assertFalse((root / ".devflow/tmp/workflow-runs/sid-none").exists())


if __name__ == "__main__":
    unittest.main()
