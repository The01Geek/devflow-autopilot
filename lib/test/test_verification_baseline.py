#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Focused tests for the offline verification-launch baseline analyzer (#527)."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import verification_baseline as vb  # noqa: E402
import workflow_flight_recorder as wfr  # noqa: E402
from verification_baseline import (  # noqa: E402
    BindingIdentity,
    VerificationProcessLaunch,
    build_cloud_census,
    build_local_census,
    group_launches,
    join_confidence,
    load_cloud_mappings,
    manual_review_sample,
    main,
    read_cloud_census,
)
from verification_baseline import (  # noqa: E402
    CONFIDENCE_AMBIGUOUS,
    CONFIDENCE_CLASSES,
    CONFIDENCE_EXACT,
    CONFIDENCE_PARTIAL,
    CONFIDENCE_UNMATCHED,
    ELIGIBILITY_CONFIRMED,
    ELIGIBILITY_INELIGIBLE,
    ELIGIBILITY_PROVISIONAL,
    ELIGIBILITY_STATES,
    ELIGIBILITY_UNKNOWN,
    KIND_OTHER_COMMAND,
    KIND_VERIFICATION,
    KIND_VERIFICATION_UNKNOWN,
    REL_CANDIDATE_TRANSPORT_RETRY,
    REL_INDEPENDENT_LIFECYCLE,
    REL_INTENTIONAL_RERUN,
    REL_SINGLE,
    REL_UNCLASSIFIABLE,
    RELATIONSHIP_CLASSES,
    SOURCE_AVAILABLE,
    SOURCE_ELIGIBLE_NOT_IMPORTED,
    SOURCE_IMPORT_FAILED,
    SOURCE_MISSING,
    SOURCE_UNREADABLE,
    SOURCE_UNSUPPORTED,
    START_CANCELLED_PRE,
    START_CLASSES,
    START_CONFIRMED_RESULT_MISSING,
    START_CONFIRMED_TERMINAL,
    START_DENIED_PRE,
    START_UNKNOWN,
)

REGISTRY = ROOT / "scripts/workflow-flight-recorder-registry.json"


# --------------------------------------------------------------------------- #
# Transcript/manifest/bundle builders.
# --------------------------------------------------------------------------- #
def transcript(*records: dict) -> bytes:
    return ("\n".join(json.dumps(r) for r in records) + "\n").encode()


def user(content: str, timestamp: str = "2026-07-16T01:00:00Z") -> dict:
    return {"type": "user", "timestamp": timestamp, "message": {"role": "user", "content": content}}


def bash_call(command: str, tool_use_id: str, timestamp: str = "2026-07-16T01:01:00Z") -> dict:
    return {
        "type": "assistant",
        "timestamp": timestamp,
        "message": {
            "role": "assistant",
            "content": [{"type": "tool_use", "id": tool_use_id, "name": "Bash", "input": {"command": command}}],
        },
    }


def tool_result(tool_use_id: str, content: str, is_error: bool = False, timestamp: str = "2026-07-16T01:02:00Z") -> dict:
    return {
        "type": "user",
        "timestamp": timestamp,
        "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tool_use_id, "is_error": is_error, "content": content}]},
    }


def manifest(sid: str, workflow: str = "implement", provisional: bool = False, submitted_at: str = "2026-07-16T01:00:00Z") -> dict:
    return {
        "schema_version": 1,
        "session_id": sid,
        "native_transcript_path": f"/home/u/.claude/projects/x/{sid}.jsonl",
        "submitted_at": submitted_at,
        "cwd": "/home/u/repo",
        "candidate": {
            "workflow": workflow,
            "subject": {"kind": "issue", "number": 527},
            # Real recorder shape (capture_prompt_manifest): `provisional` is ALWAYS
            # True; `invocation_evidence` is the eligibility discriminator. The
            # `provisional` param selects the embedded (provisional) vs exact
            # (confirmed) evidence kind.
            "invocation_evidence": "embedded_user_command_candidate" if provisional else "exact_user_command",
            "provisional": True,
        },
        "repository_root": "/home/u/repo",
        "storage_root": "/home/u/repo",
        "storage_root_source": "git_common_dir",
        "git": {"head_sha": "abc", "branch": "main", "dirty_tree": False},
        "devflow_version": "1.2.3",
        "claude_code_version": "1.0.0",
        "provider": "anthropic",
        "model_effort": {"requested_model": "claude-sonnet-5"},
    }


def write_manifest(dir_: Path, sid: str, **kw) -> Path:
    p = dir_ / f"{sid}.json"
    p.write_text(json.dumps(manifest(sid, **kw)), encoding="utf-8")
    return p


def write_bundle(bundles: Path, sid: str, transcript_bytes: bytes, meta_sv: int = 2, stop_attempts: list | None = None) -> Path:
    d = bundles / sid
    d.mkdir(parents=True, exist_ok=True)
    (d / "transcript.jsonl").write_bytes(transcript_bytes)
    (d / "metadata.json").write_text(json.dumps({"schema_version": meta_sv, "session_id": sid}), encoding="utf-8")
    if stop_attempts is not None:
        (d / "stop-attempts.jsonl").write_text("\n".join(json.dumps(e) for e in stop_attempts) + "\n", encoding="utf-8")
    return d


def make_launch(
    launch_id: str,
    lifecycle_id: str = "implement-1",
    binding_digest: str = "d1",
    start_auth: str = START_CONFIRMED_TERMINAL,
    ws_coverage: str = "complete",
    secret_affected: bool = False,
    retrigger: bool = False,
    started: str = "2026-07-16T01:01:00Z",
    finished: str = "2026-07-16T01:02:00Z",
    result_presence: bool = True,
) -> VerificationProcessLaunch:
    binding = BindingIdentity(digest=binding_digest, secret_affected=secret_affected, secret_slots=("env:TOKEN",) if secret_affected else (), redacted_display="lib/test/run.sh")
    ws = {
        "covered_roots": ["head", "index", "submodule", "tracked", "untracked", "ignored_gen_dep"] if ws_coverage == "complete" else ["head"],
        "observation_method": "source_event_results",
        "coverage": ws_coverage,
        "mutation_state_unbounded": ws_coverage != "complete",
    }
    timing = {"started_at": started, "finished_at": finished, "duration_ms": 60000, "caller_observed_duration_ms": 60000}
    return VerificationProcessLaunch(
        launch_id=launch_id, request_id="r-" + launch_id, source_event_id="evt:s:" + launch_id,
        lifecycle_id=lifecycle_id, tool_use_id="tu-" + launch_id, consumer_skill="implement",
        phase_checkpoint=None, command_head="lib/test/run.sh", binding=binding, start_authorization=start_auth,
        timing=timing, workspace_state=ws, result_presence=result_presence, exit_evidence=None,
        skipped_check_evidence=None, provenance={"session_id": "s"}, retrigger_evidence=retrigger,
    )


def candidate_pair():
    """Two same-lifecycle, same-binding launches with a prior missing result,
    bounded intervals, complete workspace, and no retrigger -> candidate."""
    a = make_launch("a", start_auth=START_CONFIRMED_RESULT_MISSING)  # prior missing
    b = make_launch("b", start_auth=START_CONFIRMED_TERMINAL)
    return a, b


class _TmpDirTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self._old_cwd = os.getcwd()
        os.chdir(str(ROOT))
        tmp_root = ROOT / ".devflow/tmp"
        tmp_root.mkdir(parents=True, exist_ok=True)
        self.tmp = tempfile.mkdtemp(dir=str(tmp_root))
        self.manifests = Path(self.tmp) / "manifests"
        self.bundles = Path(self.tmp) / "bundles"
        self.out = Path(self.tmp) / "out"
        self.manifests.mkdir()
        self.bundles.mkdir()

    def tearDown(self) -> None:
        os.chdir(self._old_cwd)
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)


# --------------------------------------------------------------------------- #
# Registry + census + eligibility.
# --------------------------------------------------------------------------- #
class RegistryAndCensusTests(_TmpDirTestCase):
    def test_registry_has_review_and_cloud_mappings(self) -> None:
        reg = wfr.load_registry(REGISTRY)
        self.assertIn("review", reg)
        self.assertEqual(reg["review"].user_commands, ("/devflow:review", "/review"))
        cm = load_cloud_mappings(REGISTRY)
        self.assertTrue(any("\x1fclaude" in k for k in cm))
        self.assertEqual(cm[".github/workflows/devflow-implement.yml\x1fclaude"]["consumer"], "implement")

    def test_confirmed_eligible_for_exact_slash_command(self) -> None:
        write_manifest(self.manifests, "sess-1")
        rows = build_local_census(self.manifests, wfr.load_registry(REGISTRY))
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0].eligibility_state, ELIGIBILITY_CONFIRMED)
        self.assertEqual(rows[0].source_status, SOURCE_ELIGIBLE_NOT_IMPORTED)

    def test_provisional_candidate_for_embedded(self) -> None:
        write_manifest(self.manifests, "sess-1", provisional=True)
        rows = build_local_census(self.manifests, wfr.load_registry(REGISTRY))
        self.assertEqual(rows[0].eligibility_state, ELIGIBILITY_PROVISIONAL)

    def test_ineligible_for_unregistered_workflow(self) -> None:
        write_manifest(self.manifests, "sess-1", workflow="not-a-real-workflow")
        rows = build_local_census(self.manifests, wfr.load_registry(REGISTRY))
        self.assertEqual(rows[0].eligibility_state, ELIGIBILITY_INELIGIBLE)

    def test_unknown_for_malformed_manifest(self) -> None:
        (self.manifests / "sess-1.json").write_text("{not json", encoding="utf-8")
        rows = build_local_census(self.manifests, wfr.load_registry(REGISTRY))
        self.assertEqual(rows[0].eligibility_state, ELIGIBILITY_UNKNOWN)
        self.assertEqual(rows[0].source_status, SOURCE_UNREADABLE)

    def test_surrogate_ids_distinct_for_unknown_natural_keys(self) -> None:
        # Two manifests with unknown/empty session ids still get distinct surrogates.
        (self.manifests / "a.json").write_text("{not json", encoding="utf-8")
        (self.manifests / "b.json").write_text("{not json", encoding="utf-8")
        rows = build_local_census(self.manifests, wfr.load_registry(REGISTRY))
        self.assertNotEqual(rows[0].surrogate_id, rows[1].surrogate_id)

    def test_source_missingness_codes(self) -> None:
        reg = wfr.load_registry(REGISTRY)
        # eligible_not_imported: manifest, no bundle.
        write_manifest(self.manifests, "s-imp")
        # source_available: manifest + good bundle.
        write_manifest(self.manifests, "s-ok")
        write_bundle(self.bundles, "s-ok", transcript(user("x"), bash_call("ls", "tu"), tool_result("tu", "ok")))
        # source_missing: bundle dir, no transcript.
        write_manifest(self.manifests, "s-miss")
        (self.bundles / "s-miss" / "metadata.json").parent.mkdir(parents=True, exist_ok=True)
        (self.bundles / "s-miss" / "metadata.json").write_text(json.dumps({"schema_version": 2}), encoding="utf-8")
        # source_unsupported: bad metadata schema.
        write_manifest(self.manifests, "s-unsup")
        write_bundle(self.bundles, "s-unsup", transcript(user("x")), meta_sv=99)
        # source_unreadable: malformed JSONL.
        write_manifest(self.manifests, "s-unr")
        write_bundle(self.bundles, "s-unr", b"{not jsonline\n")
        # import_failed: stop-attempts error, no transcript.
        write_manifest(self.manifests, "s-failed")
        d = self.bundles / "s-failed"
        d.mkdir(parents=True, exist_ok=True)
        (d / "metadata.json").write_text(json.dumps({"schema_version": 2}), encoding="utf-8")
        (d / "stop-attempts.jsonl").write_text(json.dumps({"error": "byte mismatch"}) + "\n", encoding="utf-8")
        rows = build_local_census(self.manifests, reg)
        rows = vb.join_local_imports(rows, self.bundles, 64 * 1024 * 1024)
        by = {r.identity.get("session_id"): r.source_status for r in rows}
        self.assertEqual(by["s-imp"], SOURCE_ELIGIBLE_NOT_IMPORTED)
        self.assertEqual(by["s-ok"], SOURCE_AVAILABLE)
        self.assertEqual(by["s-miss"], SOURCE_MISSING)
        self.assertEqual(by["s-unsup"], SOURCE_UNSUPPORTED)
        self.assertEqual(by["s-unr"], SOURCE_UNREADABLE)
        self.assertEqual(by["s-failed"], SOURCE_IMPORT_FAILED)


# --------------------------------------------------------------------------- #
# Taxonomy + authorization + secret + relationship (end-to-end via bundle).
# --------------------------------------------------------------------------- #
class ExtractionTests(_TmpDirTestCase):
    def _run(self, sid: str, transcript_bytes: bytes) -> dict:
        write_manifest(self.manifests, sid)
        write_bundle(self.bundles, sid, transcript_bytes)
        rc = main(["--manifests-dir", str(self.manifests), "--bundles-dir", str(self.bundles), "--registry", str(REGISTRY), "--out-dir", str(self.out)])
        self.assertEqual(rc, 0)
        runs = sorted(self.out.iterdir())
        self.assertTrue(runs)
        return json.loads((runs[-1] / "verification_baseline.json").read_text(encoding="utf-8"))

    def test_taxonomy_verification_other_unknown(self) -> None:
        b = transcript(
            user("/devflow:implement 527"),
            bash_call("lib/test/run.sh", "tu1"),
            tool_result("tu1", "exit code 0"),
            bash_call("git status", "tu2"),
            tool_result("tu2", "ok"),
            bash_call("obscure-tool --check", "tu3"),
            tool_result("tu3", "done"),
        )
        doc = self._run("s1", b)
        kinds = {r["command_head"]: r["request_kind"] for r in doc["verification_requests"]}
        self.assertEqual(kinds["lib/test/run.sh"], KIND_VERIFICATION)
        self.assertEqual(kinds["git"], KIND_OTHER_COMMAND)
        self.assertEqual(kinds["obscure-tool"], KIND_VERIFICATION_UNKNOWN)

    def test_authorization_start_classes(self) -> None:
        b = transcript(
            user("/devflow:implement 527"),
            bash_call("lib/test/run.sh", "t-denied"),
            tool_result("t-denied", "Error: permission denied", is_error=True),
            bash_call("lib/test/run.sh", "t-cancel"),
            tool_result("t-cancel", "command was cancelled by the user", is_error=True),
            bash_call("lib/test/run.sh", "t-term"),
            tool_result("t-term", "ok; exit code 0"),
            bash_call("lib/test/run.sh", "t-missing"),
            tool_result("t-missing", "running..."),
            bash_call("lib/test/run.sh", "t-noresult"),
        )
        doc = self._run("s2", b)
        starts = {r["tool_use_id"]: r["authorization_start"] for r in doc["verification_requests"]}
        self.assertEqual(starts["t-denied"], START_DENIED_PRE)
        self.assertEqual(starts["t-cancel"], START_CANCELLED_PRE)
        self.assertEqual(starts["t-term"], START_CONFIRMED_TERMINAL)
        self.assertEqual(starts["t-missing"], START_CONFIRMED_RESULT_MISSING)
        self.assertEqual(starts["t-noresult"], START_UNKNOWN)
        # Only t-term and t-missing are confirmed launches (the others are request metrics).
        launch_ids = {launch["tool_use_id"] for launch in doc["verification_process_launches"]}
        self.assertEqual(launch_ids, {"t-term", "t-missing"})

    def test_secret_redaction_boundary(self) -> None:
        binding = vb._binding_identity("TOKEN=abc123 lib/test/run.sh")
        self.assertTrue(binding.secret_affected)
        self.assertIn("env:TOKEN", binding.secret_slots)
        self.assertNotIn("abc123", binding.redacted_display)
        self.assertNotIn("abc123", binding.digest)
        # Same command shape with a different secret -> same redacted digest.
        binding2 = vb._binding_identity("TOKEN=xyz999 lib/test/run.sh")
        self.assertEqual(binding.digest, binding2.digest)
        # Secret-affected same-lifecycle distinct-source -> partial, not exact.
        a = make_launch("a", secret_affected=True)
        b = make_launch("b", secret_affected=True)
        self.assertEqual(join_confidence(a, b), CONFIDENCE_PARTIAL)

    def test_join_confidence_classes(self) -> None:
        a = make_launch("a", lifecycle_id="L1", binding_digest="D")
        b = make_launch("b", lifecycle_id="L1", binding_digest="D")
        self.assertEqual(join_confidence(a, b), CONFIDENCE_EXACT)  # same lifecycle + binding
        c = make_launch("c", lifecycle_id="L2", binding_digest="D")
        self.assertEqual(join_confidence(a, c), CONFIDENCE_PARTIAL)  # distinct lifecycle, same binding
        d = make_launch("d", lifecycle_id="L1", binding_digest="E")
        self.assertEqual(join_confidence(a, d), CONFIDENCE_AMBIGUOUS)  # same lifecycle, different binding
        e = make_launch("e", lifecycle_id="L2", binding_digest="E")
        self.assertEqual(join_confidence(a, e), CONFIDENCE_UNMATCHED)  # distinct lifecycle + binding

    def test_relationship_end_to_end(self) -> None:
        ws = "head main\nindex clean\nsubmodule none\ntracked 5\nuntracked 0\nignored node_modules/"
        b = transcript(
            user("/devflow:implement 527"),
            bash_call("git status --ignored", "tu-git"),
            tool_result("tu-git", ws),
            bash_call("lib/test/run.sh", "tu-1"),
            tool_result("tu-1", "Tests ran; output truncated"),
            bash_call("lib/test/run.sh", "tu-2"),
            tool_result("tu-2", "All good; exit code 0"),
        )
        doc = self._run("s3", b)
        groups = doc["relationship_groups"]
        candidate = [g for g in groups if g["relationship"] == REL_CANDIDATE_TRANSPORT_RETRY]
        self.assertEqual(len(candidate), 1)
        self.assertEqual(candidate[0]["join_confidence"], CONFIDENCE_EXACT)
        self.assertEqual(len(candidate[0]["members"]), 2)

    def test_relationship_independent_for_distinct_lifecycles(self) -> None:
        # Two same-binding launches but the analyzer sees them in ONE lifecycle
        # here; distinct-lifecycle is exercised at the unit level below.
        a = make_launch("a", lifecycle_id="L1", binding_digest="D", start_auth=START_CONFIRMED_RESULT_MISSING)
        b = make_launch("b", lifecycle_id="L2", binding_digest="D", start_auth=START_CONFIRMED_TERMINAL)
        groups = group_launches([a, b])
        # Same binding -> one group; distinct lifecycles -> independent.
        self.assertEqual(len(groups), 1)
        self.assertEqual(groups[0].relationship, REL_INDEPENDENT_LIFECYCLE)


# --------------------------------------------------------------------------- #
# Mutation tests: candidate classification fails closed when evidence removed.
# --------------------------------------------------------------------------- #
class CandidateFailsClosedTests(unittest.TestCase):
    def assert_candidate(self, a, b) -> None:
        groups = group_launches([a, b])
        self.assertEqual(len(groups), 1, "same binding -> one group")
        self.assertEqual(groups[0].relationship, REL_CANDIDATE_TRANSPORT_RETRY, "baseline is a candidate")

    def test_baseline_is_candidate(self) -> None:
        a, b = candidate_pair()
        self.assert_candidate(a, b)

    def test_mutation_lifecycle_removed(self) -> None:
        a, b = candidate_pair()
        b.lifecycle_id = "implement-2"  # distinct lifecycle
        groups = group_launches([a, b])
        self.assertNotEqual(groups[0].relationship, REL_CANDIDATE_TRANSPORT_RETRY)
        self.assertEqual(groups[0].relationship, REL_INDEPENDENT_LIFECYCLE)

    def test_mutation_missing_response_removed(self) -> None:
        a, b = candidate_pair()
        a.start_authorization = START_CONFIRMED_TERMINAL  # no prior missing response
        groups = group_launches([a, b])
        self.assertNotEqual(groups[0].relationship, REL_CANDIDATE_TRANSPORT_RETRY)

    def test_mutation_boundary_removed(self) -> None:
        a, b = candidate_pair()
        for m in (a, b):
            m.workspace_state = {**m.workspace_state, "coverage": "incomplete", "mutation_state_unbounded": True}
        groups = group_launches([a, b])
        self.assertEqual(groups[0].relationship, REL_UNCLASSIFIABLE)

    def test_mutation_binding_removed(self) -> None:
        a, b = candidate_pair()
        b.binding = BindingIdentity(digest="different", secret_affected=False, secret_slots=(), redacted_display="other")
        groups = group_launches([a, b])
        # Different bindings -> two single-member groups, no candidate.
        self.assertEqual(len(groups), 2)
        for g in groups:
            self.assertEqual(g.relationship, REL_SINGLE)

    def test_mutation_retrigger_removed(self) -> None:
        a, b = candidate_pair()
        a.retrigger_evidence = True  # explicit retrigger evidence -> intentional rerun
        groups = group_launches([a, b])
        self.assertEqual(groups[0].relationship, REL_INTENTIONAL_RERUN)


# --------------------------------------------------------------------------- #
# Sampling + report + output + cloud + performance.
# --------------------------------------------------------------------------- #
class SamplingReportOutputTests(_TmpDirTestCase):
    def test_manual_review_sampling_is_deterministic(self) -> None:
        launches = []
        for i in range(40):
            for j, auth in enumerate((START_CONFIRMED_RESULT_MISSING, START_CONFIRMED_TERMINAL)):
                la = make_launch(f"m{i}-{j}", lifecycle_id=f"L{i}", binding_digest=f"D{i}", start_auth=auth)
                la.timing["duration_ms"] = (i + 1) * 1000  # varied so the top decile is a strict subset
                launches.append(la)
        groups = group_launches(launches)
        self.assertEqual(len(groups), 40)
        snap = "deadbeef"
        s1 = manual_review_sample(groups, snap)
        s2 = manual_review_sample(groups, snap)
        self.assertEqual(s1["selected_ids"], s2["selected_ids"])
        self.assertGreater(len(s1["selected_ids"]), 0)
        # Different seed -> different remainder selection.
        s3 = manual_review_sample(groups, "feedface")
        self.assertNotEqual(s1["remainder_selected_ids"], s3["remainder_selected_ids"])

    def test_report_does_not_overclaim_and_cites_source_event_ids(self) -> None:
        write_manifest(self.manifests, "s1")
        write_bundle(self.bundles, "s1", transcript(user("/devflow:implement 527"), bash_call("lib/test/run.sh", "tu"), tool_result("tu", "exit code 0")))
        rc = main(["--manifests-dir", str(self.manifests), "--bundles-dir", str(self.bundles), "--registry", str(REGISTRY), "--out-dir", str(self.out)])
        self.assertEqual(rc, 0)
        run = sorted(self.out.iterdir())[-1]
        report = (run / "report.md").read_text(encoding="utf-8")
        # The report states evidence limitations and disclaims overclaims (AC):
        # it never positively claims launches avoided / authorization safe /
        # active recovery justified — it states the disclaimer, observed counts,
        # candidate counts, and the manual-review sample.
        self.assertIn("does NOT claim", report)
        self.assertIn("candidate counts", report)
        self.assertIn("source_snapshot_hash", report)
        # The baseline record cites source-event IDs (evt:), not raw command text.
        baseline = json.loads((run / "verification_baseline.json").read_text(encoding="utf-8"))
        for launch in baseline["verification_process_launches"]:
            self.assertIn("evt:", launch["source_event_id"])
            self.assertNotIn("lib/test/run.sh", launch["source_event_id"])

    def test_output_permissions_are_0700_0600(self) -> None:
        write_manifest(self.manifests, "s1")
        write_bundle(self.bundles, "s1", transcript(user("/devflow:implement 527")))
        main(["--manifests-dir", str(self.manifests), "--bundles-dir", str(self.bundles), "--registry", str(REGISTRY), "--out-dir", str(self.out)])
        run = sorted(self.out.iterdir())[-1]
        self.assertEqual(stat.S_IMODE(run.stat().st_mode), 0o700)
        for f in run.iterdir():
            self.assertEqual(stat.S_IMODE(f.stat().st_mode), 0o600)

    def test_unknown_is_not_zero(self) -> None:
        # No candidate durations -> estimated repeated-suite wall time is null, not 0.
        write_manifest(self.manifests, "s1")
        write_bundle(self.bundles, "s1", transcript(user("/devflow:implement 527")))
        main(["--manifests-dir", str(self.manifests), "--bundles-dir", str(self.bundles), "--registry", str(REGISTRY), "--out-dir", str(self.out)])
        baseline = json.loads((sorted(self.out.iterdir())[-1] / "verification_baseline.json").read_text(encoding="utf-8"))
        self.assertIsNone(baseline["metrics"]["estimated_repeated_suite_wall_time_ms"])
        # A real zero (no candidates) is honored as 0, not null.
        self.assertEqual(baseline["metrics"]["candidate_retries"], 0)

    def test_cloud_census_unavailable_when_absent(self) -> None:
        rows, cov = build_cloud_census(None, load_cloud_mappings(REGISTRY))
        self.assertEqual(rows, [])
        self.assertTrue(cov["unavailable"])

    def test_cloud_census_eligibility(self) -> None:
        snap = {
            "schema_version": 1,
            "snapshot_hash": "h",
            "query_time": "2026-07-16T01:00:00Z",
            "pagination_complete": True,
            "repository": "The01Geek/devflow-autopilot",
            "rows": [
                {"workflow_file": ".github/workflows/devflow-implement.yml", "job": "claude", "run_id": 1, "run_attempt": 1, "started_at": "2026-07-16T01:00:00Z", "completed_at": "2026-07-16T02:00:00Z", "conclusion": "success", "status": "completed"},
                {"workflow_file": ".github/workflows/devflow-implement.yml", "job": "gate", "run_id": 1, "run_attempt": 1, "started_at": "2026-07-16T01:00:00Z", "conclusion": "success", "status": "completed"},
            ],
        }
        rows, cov = build_cloud_census(snap, load_cloud_mappings(REGISTRY))
        self.assertFalse(cov["unavailable"])
        states = {r.identity["job"]: r.eligibility_state for r in rows}
        self.assertEqual(states["claude"], ELIGIBILITY_CONFIRMED)
        self.assertEqual(states["gate"], ELIGIBILITY_INELIGIBLE)

    def test_performance_limit_skip(self) -> None:
        write_manifest(self.manifests, "s1")
        # A transcript larger than max-source-bytes -> source_unsupported, no crash.
        big = transcript(user("/devflow:implement 527")) + (b"x" * 200)
        write_bundle(self.bundles, "s1", big)
        main(["--manifests-dir", str(self.manifests), "--bundles-dir", str(self.bundles), "--registry", str(REGISTRY), "--out-dir", str(self.out), "--max-source-bytes", "10"])
        baseline = json.loads((sorted(self.out.iterdir())[-1] / "verification_baseline.json").read_text(encoding="utf-8"))
        self.assertEqual(baseline["census"]["local"][0]["source_status"], SOURCE_UNSUPPORTED)
        self.assertGreaterEqual(baseline["performance"]["skipped_unsupported_source_count"], 1)

    def test_cleanup_does_not_touch_native_sources(self) -> None:
        write_manifest(self.manifests, "s1")
        write_bundle(self.bundles, "s1", transcript(user("/devflow:implement 527")))
        main(["--manifests-dir", str(self.manifests), "--bundles-dir", str(self.bundles), "--registry", str(REGISTRY), "--out-dir", str(self.out)])
        self.assertTrue(sorted(self.out.iterdir()))
        rc = main(["--cleanup", "--out-dir", str(self.out)])
        self.assertEqual(rc, 0)
        self.assertEqual(list(self.out.iterdir()), [])
        # Native sources (manifest + bundle) untouched.
        self.assertTrue((self.manifests / "s1.json").exists())
        self.assertTrue((self.bundles / "s1").exists())


class ExportSnapshotTests(unittest.TestCase):
    def test_build_snapshot_round_trips_into_cloud_census(self) -> None:
        import importlib.util
        spec = importlib.util.spec_from_file_location("export_census", ROOT / "scripts/export-workflow-lifecycle-census.py")
        export_census = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(export_census)
        runs = [{"id": 7, "path": ".github/workflows/devflow-implement.yml", "name": "DevFlow Implement", "run_attempt": 1, "created_at": "2026-07-16T01:00:00Z", "run_started_at": "2026-07-16T01:00:05Z", "conclusion": "success", "status": "completed", "html_url": "u"}]
        jobs_by_run = {7: [{"name": "claude", "started_at": "2026-07-16T01:00:10Z", "completed_at": "2026-07-16T02:00:00Z", "conclusion": "success", "status": "completed", "html_url": "u"}]}
        snap = export_census.build_snapshot("The01Geek/devflow-autopilot", [".github/workflows/devflow-implement.yml"], "2026-07-01", "2026-08-01", runs, jobs_by_run, "2026-07-16T03:00:00Z", True)
        # Write to a temp file and read back through the analyzer's reader.
        tmp = ROOT / ".devflow/tmp/vb-snap-test.json"
        tmp.parent.mkdir(parents=True, exist_ok=True)
        tmp.write_text(json.dumps(snap), encoding="utf-8")
        try:
            read, reason = read_cloud_census(tmp)
            self.assertEqual(reason, "ok")
            self.assertIsNotNone(read)
            assert read is not None
            self.assertEqual(read["snapshot_hash"], snap["snapshot_hash"])
            rows, cov = build_cloud_census(read, load_cloud_mappings(REGISTRY))
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0].identity["job"], "claude")
            self.assertEqual(rows[0].eligibility_state, ELIGIBILITY_CONFIRMED)
        finally:
            tmp.unlink(missing_ok=True)


class ReviewFixFollowupTests(unittest.TestCase):
    """Tests added by the Phase 3.3 review-and-fix loop for findings the review
    agents surfaced (secret-pattern coverage, secret-affected group exclusion,
    cloud skipped/pagination/malformed handling, read reasons, the
    interval_bounded candidate guard, and the enum-cardinality pins)."""

    def test_enum_cardinalities(self) -> None:
        # Pins the "exactly these N" comments on each enum so adding a value
        # without updating the comment goes RED at the desk.
        self.assertEqual(len(ELIGIBILITY_STATES), 4)
        self.assertEqual(len(START_CLASSES), 5)
        self.assertEqual(len(CONFIDENCE_CLASSES), 4)
        self.assertEqual(len(RELATIONSHIP_CLASSES), 5)

    def test_secret_flag_catches_compound_forms(self) -> None:
        for flag in ("--api-key", "--auth-token", "--access-key", "--secret-key", "--token", "--key"):
            b = vb._binding_identity(f"{flag} sk-secret123 lib/test/run.sh")
            self.assertTrue(b.secret_affected, f"{flag} should be secret-affected")
            self.assertNotIn("sk-secret123", b.redacted_display)
            self.assertNotIn("sk-secret123", b.digest)
        # --pattern must NOT be flagged (contains 'pat' but is not a secret flag).
        nopat = vb._binding_identity("--pattern '*.py' lib/test/run.sh")
        self.assertFalse(nopat.secret_affected)

    def test_secret_url_and_bearer_redaction(self) -> None:
        url = vb._binding_identity("curl https://alice:s3cr3t@example.com/x lib/test/run.sh")
        self.assertTrue(url.secret_affected)
        self.assertNotIn("s3cr3t", url.redacted_display)
        bearer = vb._binding_identity("gh api -H 'Authorization: Bearer ghp_tok3n' lib/test/run.sh")
        self.assertTrue(bearer.secret_affected)
        self.assertNotIn("ghp_tok3n", bearer.redacted_display)

    def test_secret_affected_group_excluded_from_candidates(self) -> None:
        # A secret-affected same-lifecycle pair must NOT be a candidate transport
        # retry (a redacted digest alone cannot establish an exact match).
        a = make_launch("a", secret_affected=True, start_auth=START_CONFIRMED_RESULT_MISSING)
        b = make_launch("b", secret_affected=True, start_auth=START_CONFIRMED_TERMINAL)
        groups = group_launches([a, b])
        self.assertEqual(len(groups), 1)
        self.assertEqual(groups[0].relationship, REL_UNCLASSIFIABLE)
        self.assertEqual(groups[0].join_confidence, CONFIDENCE_PARTIAL)

    def test_cloud_census_skipped_job_is_ineligible(self) -> None:
        snap = {
            "schema_version": 1, "snapshot_hash": "h", "query_time": "2026-07-16T01:00:00Z",
            "pagination_complete": True, "repository": "o/r",
            "rows": [
                {"workflow_file": ".github/workflows/devflow-implement.yml", "job": "claude", "run_id": 1, "run_attempt": 1, "started_at": "2026-07-16T01:00:10Z", "conclusion": "success", "status": "completed"},
                {"workflow_file": ".github/workflows/devflow-implement.yml", "job": "claude", "run_id": 2, "run_attempt": 1, "started_at": None, "conclusion": "skipped", "status": "completed"},
            ],
        }
        rows, cov = build_cloud_census(snap, load_cloud_mappings(REGISTRY))
        self.assertFalse(cov["unavailable"])
        by_run = {r.identity["run_id"]: r.eligibility_state for r in rows}
        self.assertEqual(by_run[1], ELIGIBILITY_CONFIRMED)
        self.assertEqual(by_run[2], ELIGIBILITY_INELIGIBLE)  # skipped -> never started

    def test_cloud_census_pagination_incomplete_is_unavailable(self) -> None:
        snap = {"schema_version": 1, "snapshot_hash": "h", "query_time": "t", "pagination_complete": False, "repository": "o/r", "rows": []}
        rows, cov = build_cloud_census(snap, load_cloud_mappings(REGISTRY))
        self.assertTrue(cov["unavailable"])
        self.assertEqual(cov["reason"], "pagination incomplete")
        self.assertEqual(rows, [])

    def test_cloud_census_malformed_row_counted(self) -> None:
        snap = {"schema_version": 1, "snapshot_hash": "h", "query_time": "t", "pagination_complete": True, "repository": "o/r",
                "rows": ["not-a-dict", {"workflow_file": ".github/workflows/devflow-implement.yml", "job": "claude", "run_id": 1, "run_attempt": 1, "started_at": "t", "conclusion": "success", "status": "completed"}]}
        rows, cov = build_cloud_census(snap, load_cloud_mappings(REGISTRY))
        self.assertEqual(cov.get("malformed_row_count"), 1)
        self.assertEqual(len(rows), 1)  # the one valid row still built

    def test_read_cloud_census_distinguishes_absent_corrupt_schema(self) -> None:
        self.assertEqual(read_cloud_census(None), (None, "absent"))
        tmp = ROOT / ".devflow/tmp/vb-snap-reasons.json"
        tmp.parent.mkdir(parents=True, exist_ok=True)
        try:
            tmp.write_text("{not json", encoding="utf-8")
            doc, reason = read_cloud_census(tmp)
            self.assertIsNone(doc)
            self.assertIn("unreadable", reason)
            tmp.write_text(json.dumps({"schema_version": 99}), encoding="utf-8")
            doc, reason = read_cloud_census(tmp)
            self.assertIsNone(doc)
            self.assertIn("schema_version", reason)
        finally:
            tmp.unlink(missing_ok=True)

    def test_mutation_interval_bounded_removed(self) -> None:
        # Removing the interval_bounded requirement (both launches unbounded)
        # must NOT still classify as a candidate — proves the guard is operative.
        a = make_launch("a", start_auth=START_CONFIRMED_RESULT_MISSING)
        b = make_launch("b", start_auth=START_CONFIRMED_TERMINAL)
        for m in (a, b):
            m.timing["started_at"] = None
            m.timing["finished_at"] = None
            m.timing["duration_ms"] = None
        groups = group_launches([a, b])
        self.assertNotEqual(groups[0].relationship, REL_CANDIDATE_TRANSPORT_RETRY)


def _load_export_census():
    spec = importlib.util.spec_from_file_location(
        "export_census_regr", ROOT / "scripts/export-workflow-lifecycle-census.py"
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class _RawEvent:
    """Minimal stand-in for a wfr.Event carrying only the `.raw` dict that
    `_workspace_state` reads (a tool_result content shape)."""

    def __init__(self, raw: dict) -> None:
        self.raw = raw


def _result_event(text: str) -> _RawEvent:
    return _RawEvent({"message": {"content": [{"type": "tool_result", "content": text}]}})


class Issue527ReviewFixTests(_TmpDirTestCase):
    """Regression tests for the PR #531 review-and-fix findings (issue #527)."""

    def _run(self, sid: str, transcript_bytes: bytes) -> dict:
        write_manifest(self.manifests, sid)
        write_bundle(self.bundles, sid, transcript_bytes)
        rc = main(["--manifests-dir", str(self.manifests), "--bundles-dir", str(self.bundles),
                   "--registry", str(REGISTRY), "--out-dir", str(self.out)])
        self.assertEqual(rc, 0)
        runs = sorted(self.out.iterdir())
        self.assertTrue(runs)
        return json.loads((runs[-1] / "verification_baseline.json").read_text(encoding="utf-8"))

    # --- F3: cancel/abort words in a SUCCESSFUL command's own output must not
    #         reclassify a real launch out of the counts. --------------------
    def test_successful_output_with_cancel_words_is_still_a_launch(self) -> None:
        b = transcript(
            user("/devflow:implement 527"),
            bash_call("lib/test/run.sh", "t-ran"),
            # is_error=False (successful) AND a real exit code: the "aborted"
            # substring is incidental suite output, not a cancellation.
            tool_result("t-ran", "1 test aborted earlier; suite recovered. exit code 0"),
        )
        doc = self._run("s-cancelwords", b)
        starts = {r["tool_use_id"]: r["authorization_start"] for r in doc["verification_requests"]}
        self.assertEqual(starts["t-ran"], START_CONFIRMED_TERMINAL)
        launch_ids = {ln["tool_use_id"] for ln in doc["verification_process_launches"]}
        self.assertIn("t-ran", launch_ids)

    # --- F4: a malformed manifest keeps its terminal source_unreadable reason
    #         through the left-join instead of being clobbered. --------------
    def test_malformed_manifest_keeps_unreadable_after_join(self) -> None:
        (self.manifests / "sess-1.json").write_text("{not json", encoding="utf-8")
        reg = wfr.load_registry(REGISTRY)
        rows = build_local_census(self.manifests, reg)
        self.assertEqual(rows[0].source_status, SOURCE_UNREADABLE)
        joined = vb.join_local_imports(rows, self.bundles, 64 * 1024 * 1024)
        self.assertEqual(joined[0].source_status, SOURCE_UNREADABLE)

    # --- F5: a present-but-malformed cloud_mappings section is a loud
    #         degradation (breadcrumb), an absent one is silent. -------------
    def test_malformed_cloud_mappings_emits_breadcrumb(self) -> None:
        reg = Path(self.tmp) / "reg-bad-cm.json"
        reg.write_text(json.dumps({
            "schema_version": 1, "workflows": {},
            "cloud_mappings": {"schema_version": 999, "agent_jobs": []},
        }), encoding="utf-8")
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            table = load_cloud_mappings(reg)
        self.assertEqual(table, {})
        self.assertIn("cloud_mappings", buf.getvalue())

    def test_malformed_cloud_mappings_entries_emit_breadcrumb(self) -> None:
        reg = Path(self.tmp) / "reg-bad-entries.json"
        reg.write_text(json.dumps({
            "schema_version": 1, "workflows": {},
            "cloud_mappings": {
                "schema_version": 1,
                "agent_jobs": [
                    {"workflow_file": "a.yml", "job": "j"},   # good
                    {"workflow_file": 123, "job": "j"},        # non-str workflow_file
                    "not-an-object",                            # non-dict entry
                ],
            },
        }), encoding="utf-8")
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            table = load_cloud_mappings(reg)
        self.assertEqual(len(table), 1)  # only the good entry survives
        self.assertIn("dropped 2", buf.getvalue())

    def test_absent_cloud_mappings_is_silent(self) -> None:
        reg = Path(self.tmp) / "reg-no-cm.json"
        reg.write_text(json.dumps({"schema_version": 1, "workflows": {}}), encoding="utf-8")
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            table = load_cloud_mappings(reg)
        self.assertEqual(table, {})
        self.assertEqual(buf.getvalue().strip(), "")

    # --- F7: workspace coverage must not treat the "tracked" substring of
    #         "untracked" as coverage of the tracked root. ------------------
    def test_untracked_text_does_not_cover_tracked_root(self) -> None:
        state = vb._workspace_state([_result_event("5 untracked files present")], 0, 0)
        self.assertIn("untracked", state["covered_roots"])
        self.assertNotIn("tracked", state["covered_roots"])

    def test_tracked_text_still_covers_tracked_root(self) -> None:
        state = vb._workspace_state([_result_event("all tracked files verified")], 0, 0)
        self.assertIn("tracked", state["covered_roots"])

    # --- F8: --cleanup must not report success while a sensitive artifact
    #         could not be removed. -------------------------------------------
    def test_cleanup_fails_loudly_when_an_artifact_cannot_be_removed(self) -> None:
        self.out.mkdir(parents=True, exist_ok=True)
        (self.out / "baseline.json").write_text("{}", encoding="utf-8")
        buf = io.StringIO()
        with mock.patch("pathlib.Path.unlink", side_effect=OSError("locked")):
            with contextlib.redirect_stderr(buf):
                rc = main(["--cleanup", "--out-dir", str(self.out)])
        self.assertNotEqual(rc, 0)
        self.assertIn("fail", buf.getvalue().lower())
        # The unremovable artifact is still present (fix restores real perms in teardown).
        self.assertTrue((self.out / "baseline.json").exists())

    # --- G-A: eligibility must key on invocation_evidence, NOT the always-True
    #          `provisional` flag the recorder hardcodes. -------------------
    def _write_real_manifest(self, sid: str, evidence: str, workflow: str = "implement") -> None:
        # The REAL recorder shape (capture_prompt_manifest): provisional is ALWAYS
        # True; invocation_evidence is the discriminator.
        m = {
            "schema_version": 1, "session_id": sid,
            "submitted_at": "2026-07-16T01:00:00Z", "cwd": "/home/u/repo",
            "candidate": {
                "workflow": workflow, "subject": {"kind": "issue", "number": 527},
                "invocation_evidence": evidence, "provisional": True,
            },
        }
        (self.manifests / f"{sid}.json").write_text(json.dumps(m), encoding="utf-8")

    def test_exact_start_is_confirmed_despite_provisional_true(self) -> None:
        self._write_real_manifest("sess-exact", "exact_user_command")
        rows = build_local_census(self.manifests, wfr.load_registry(REGISTRY))
        self.assertEqual(rows[0].eligibility_state, ELIGIBILITY_CONFIRMED)

    def test_command_markup_start_is_confirmed(self) -> None:
        self._write_real_manifest("sess-markup", "command_markup")
        rows = build_local_census(self.manifests, wfr.load_registry(REGISTRY))
        self.assertEqual(rows[0].eligibility_state, ELIGIBILITY_CONFIRMED)

    def test_embedded_start_is_provisional(self) -> None:
        self._write_real_manifest("sess-embed", "embedded_user_command_candidate")
        rows = build_local_census(self.manifests, wfr.load_registry(REGISTRY))
        self.assertEqual(rows[0].eligibility_state, ELIGIBILITY_PROVISIONAL)

    # --- G8: a non-verification command must not be classified verification
    #         because a test-tool name appears later in the command. --------
    def test_taxonomy_head_first_for_non_verification_commands(self) -> None:
        self.assertEqual(vb._classify_taxonomy("git commit -m 'fix ruff test'"), KIND_OTHER_COMMAND)
        self.assertEqual(vb._classify_taxonomy("cat lib/test/run.sh"), KIND_OTHER_COMMAND)
        self.assertEqual(vb._classify_taxonomy("echo pytest passed"), KIND_OTHER_COMMAND)
        # Real verification commands still classify as verification.
        self.assertEqual(vb._classify_taxonomy("lib/test/run.sh"), KIND_VERIFICATION)
        self.assertEqual(vb._classify_taxonomy("pytest tests/"), KIND_VERIFICATION)
        # A chained command whose wrapper head is non-verification still runs a
        # real verification after `&&` — must not be under-counted as other_command.
        self.assertEqual(vb._classify_taxonomy("cd repo && pytest tests/"), KIND_VERIFICATION)
        # A chained non-verification command (no test tool) stays other_command.
        self.assertEqual(vb._classify_taxonomy("git add -A && git commit -m x"), KIND_OTHER_COMMAND)

    # --- Coverage for the security path-validation boundary (flagged in both
    #     review passes as having zero tests). ---------------------------------
    def test_validate_admitted_path_rejects_escape(self) -> None:
        with self.assertRaises(ValueError):
            vb._validate_admitted_path("/etc/passwd")
        with self.assertRaises(ValueError):
            vb._validate_admitted_path("../../../../etc/passwd")
        with self.assertRaises(ValueError):
            vb._validate_admitted_path("")
        with self.assertRaises(FileNotFoundError):
            vb._validate_admitted_path(".devflow/tmp/does-not-exist-xyz-527", must_exist=True)
        # A valid in-repo path resolves under the repo root.
        resolved = vb._validate_admitted_path(".devflow/tmp")
        self.assertTrue(str(resolved).startswith(str(ROOT.resolve())))

    # --- F1/F2: the census exporter must issue a GET with a single closed
    #            created range (no dropped upper bound). --------------------
    def test_fetch_jobs_paginates_all_pages(self) -> None:
        # A run with >100 jobs must have EVERY job collected (and pagination stay
        # complete) — a single per_page=100 fetch silently truncates the cloud
        # denominator while asserting completeness (issue #527 shadow finding).
        export = _load_export_census()
        calls: list[list[str]] = []

        def fake_gh_json(gh, args):
            calls.append(list(args))
            joined = " ".join(args)
            if "/actions/runs/7/jobs" in joined:
                page = next((a.split("=")[-1] for a in args if a.startswith("--field=page=")), "1")
                if page == "1":
                    return {"total_count": 150, "jobs": [{"name": f"j{i}"} for i in range(100)]}
                return {"total_count": 150, "jobs": [{"name": f"j{i}"} for i in range(100, 150)]}
            # runs endpoint: one run, then stop.
            return {"workflow_runs": [{"id": 7, "path": ".github/workflows/x.yml", "name": "X"}]}

        export._gh_json = fake_gh_json
        runs, jobs_by_run, complete = export.fetch_runs_and_jobs("gh", "o/r", [], "2026-07-01", "2026-08-01")
        self.assertEqual(len(jobs_by_run[7]), 150)
        self.assertTrue(complete)

    def test_fetch_jobs_incomplete_page_marks_unavailable(self) -> None:
        # A jobs page that fails mid-pagination must mark the census incomplete
        # (never a partial-count presented as complete).
        export = _load_export_census()

        def fake_gh_json(gh, args):
            joined = " ".join(args)
            if "/actions/runs/7/jobs" in joined:
                page = next((a.split("=")[-1] for a in args if a.startswith("--field=page=")), "1")
                if page == "1":
                    return {"total_count": 150, "jobs": [{"name": f"j{i}"} for i in range(100)]}
                return None  # transport failure on page 2
            return {"workflow_runs": [{"id": 7, "path": ".github/workflows/x.yml", "name": "X"}]}

        export._gh_json = fake_gh_json
        _, _, complete = export.fetch_runs_and_jobs("gh", "o/r", [], "2026-07-01", "2026-08-01")
        self.assertFalse(complete)

    def test_fetch_runs_uses_get_and_closed_created_range(self) -> None:
        export = _load_export_census()
        calls: list[list[str]] = []

        def fake_gh_json(gh, args):
            calls.append(list(args))
            return {"workflow_runs": []}  # empty first page → stop, no jobs

        export._gh_json = fake_gh_json
        export.fetch_runs_and_jobs("gh", "o/r", [], "2026-07-01", "2026-08-01")
        self.assertTrue(calls)
        runs_call = calls[0]
        self.assertIn("--method", runs_call)
        self.assertEqual(runs_call[runs_call.index("--method") + 1], "GET")
        created_fields = [a for a in runs_call if "created" in a]
        self.assertEqual(len(created_fields), 1, f"expected one created field, got {created_fields}")
        self.assertIn("2026-07-01..2026-08-01", created_fields[0])
        # The old split-on-first-'=' upper-bound param must be gone.
        self.assertFalse(any("created<" in a for a in runs_call))


if __name__ == "__main__":
    unittest.main()
