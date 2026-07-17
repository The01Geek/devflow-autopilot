#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Focused tests for the offline verification-launch baseline analyzer (#527)."""

from __future__ import annotations

import contextlib
import dataclasses
import importlib.util
import hashlib
import io
import json
import os
import re
from pathlib import Path
import stat
import sys
import tempfile
import time
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
        # Real recorder shape: these three are {"value","source"} dicts, not bare
        # strings (capture_prompt_manifest). Using the real shape here exercises
        # host_profile's dict extraction.
        "devflow_version": {"value": "1.2.3", "source": "plugin_manifest"},
        "claude_code_version": {"value": "1.0.0", "source": "cli"},
        "provider": {"value": "anthropic", "source": "env"},
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
    # BindingIdentity now validates its digest shape at construction; derive a
    # real sha256 from the seed so distinct seeds stay distinct bindings.
    binding = BindingIdentity(digest=hashlib.sha256(binding_digest.encode("utf-8")).hexdigest(), secret_affected=secret_affected, secret_slots=("env:TOKEN",) if secret_affected else (), redacted_display="lib/test/run.sh")
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
        # Required (no default) by design: a defaulted ELIGIBILITY_UNKNOWN would
        # pass validation and silently bucket an omitting call site with rows
        # whose eligibility genuinely could not be established. This fixture
        # models the ordinary case — a launch extracted from an eligible row.
        owning_lifecycle_eligibility_state=ELIGIBILITY_CONFIRMED,
    )


def candidate_pair():
    """Two same-lifecycle, same-binding launches with a prior missing result,
    bounded intervals, complete workspace, and no retrigger -> candidate."""
    a = make_launch("a", start_auth=START_CONFIRMED_RESULT_MISSING)  # prior missing
    b = make_launch("b", start_auth=START_CONFIRMED_TERMINAL)
    return a, b


def _candidate_pair_with_consumers(consumer_a, consumer_b):
    """candidate_pair() with only consumer_skill varied — built by replacing on
    the real fixture so the pair cannot drift from the genuine candidate shape
    (a hand-rolled near-miss would make the guard's test vacuous)."""
    a, b = candidate_pair()
    return (dataclasses.replace(a, consumer_skill=consumer_a),
            dataclasses.replace(b, consumer_skill=consumer_b))


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
        # PR #531 iter-1 VC-40: devflow-review.yml's `review` job is a reusable-
        # workflow call (uses: devflow-runner.yml) — the Actions jobs API reports
        # the nested agent job as "review / run" (caller-job / called-job), so the
        # mapping must key on that literal or every auto-review census row is
        # silently non-agent. The bare "review" key must NOT be present, and the
        # workflow_call-only devflow-runner.yml never appears as its own run.
        self.assertIn(".github/workflows/devflow-review.yml\x1freview / run", cm)
        self.assertNotIn(".github/workflows/devflow-review.yml\x1freview", cm)
        self.assertFalse(any(k.startswith(".github/workflows/devflow-runner.yml\x1f") for k in cm))

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
        # import_failed: a stop-attempts log in the REAL writer shape
        # (_append_bundle_attempt emits success-only {result: "captured", ...}
        # entries) claiming a capture, but no transcript survived — the
        # capture-claimed-artifact-gone inconsistency (PR #531 iter-1 VC-5:
        # the old fixture used error/bytes_verified/ok keys the recorder never
        # writes, so the reader's failure arm matched a shape no writer produces).
        write_manifest(self.manifests, "s-failed")
        d = self.bundles / "s-failed"
        d.mkdir(parents=True, exist_ok=True)
        (d / "metadata.json").write_text(json.dumps({"schema_version": 2}), encoding="utf-8")
        (d / "stop-attempts.jsonl").write_text(
            json.dumps({"captured_at": "2026-07-16T01:00:00Z", "transcript_bytes": 123,
                        "transcript_sha256": "aa", "event_count": 2,
                        "result": "captured", "source": "stop_hook"}) + "\n",
            encoding="utf-8")
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
        # assertNotIn(secret, digest) alone is vacuous — a 64-char sha256 hex
        # almost never CONTAINS the secret whether or not redaction ran (PR #531
        # review, test-quality note). Pin the real property instead: the digest
        # is computed over the REDACTED form (== sha256(redacted_display here —
        # the command is short, so display == redacted)), and is NOT the digest
        # of the raw canonical command (no unkeyed digest of secret material).
        self.assertEqual(binding.digest, hashlib.sha256(binding.redacted_display.encode("utf-8")).hexdigest())
        self.assertNotEqual(binding.digest, hashlib.sha256(vb._canonical_command("TOKEN=abc123 lib/test/run.sh").encode("utf-8")).hexdigest())
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
        b = dataclasses.replace(b, lifecycle_id="implement-2")  # distinct lifecycle (records are frozen)
        groups = group_launches([a, b])
        self.assertNotEqual(groups[0].relationship, REL_CANDIDATE_TRANSPORT_RETRY)
        self.assertEqual(groups[0].relationship, REL_INDEPENDENT_LIFECYCLE)

    def test_mutation_missing_response_removed(self) -> None:
        a, b = candidate_pair()
        a = dataclasses.replace(a, start_authorization=START_CONFIRMED_TERMINAL)  # no prior missing response
        groups = group_launches([a, b])
        self.assertNotEqual(groups[0].relationship, REL_CANDIDATE_TRANSPORT_RETRY)

    def test_mutation_boundary_removed(self) -> None:
        a, b = candidate_pair()
        a, b = (
            dataclasses.replace(m, workspace_state={**m.workspace_state, "coverage": "incomplete", "mutation_state_unbounded": True})
            for m in (a, b)
        )
        groups = group_launches([a, b])
        self.assertEqual(groups[0].relationship, REL_UNCLASSIFIABLE)

    def test_mutation_binding_removed(self) -> None:
        a, b = candidate_pair()
        b = dataclasses.replace(b, binding=BindingIdentity(digest=hashlib.sha256(b"different").hexdigest(), secret_affected=False, secret_slots=(), redacted_display="other"))
        groups = group_launches([a, b])
        # Different bindings -> two single-member groups, no candidate.
        self.assertEqual(len(groups), 2)
        for g in groups:
            self.assertEqual(g.relationship, REL_SINGLE)

    def test_mutation_retrigger_removed(self) -> None:
        a, b = candidate_pair()
        a = dataclasses.replace(a, retrigger_evidence=True)  # explicit retrigger evidence -> intentional rerun
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
        # BOTH halves of the claimed hardening: the parent baseline dir AND the
        # per-run subdir are 0700 (PR #531 iter-1: the parent-half of the chmod
        # loop was unasserted, so dropping out_dir from it stayed green).
        self.assertEqual(stat.S_IMODE(self.out.stat().st_mode), 0o700)
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
            # The NotIn-digest form alone is vacuous (see
            # test_secret_redaction_boundary); pin that the digest is not the
            # digest of the raw canonical command instead.
            self.assertNotEqual(
                b.digest,
                hashlib.sha256(vb._canonical_command(f"{flag} sk-secret123 lib/test/run.sh").encode("utf-8")).hexdigest(),
                f"{flag}: digest must be of the redacted form, not the raw command")
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
        # The unremovable artifact is still present (unlink is mocked; nothing on disk was actually removed).
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

    # --- J2: the segment split must be quote-aware — a delimiter inside a quoted
    #         argument must not manufacture a verification segment. -----------
    def test_taxonomy_split_is_quote_aware(self) -> None:
        self.assertEqual(vb._classify_taxonomy('git commit -m "refactor && pytest later"'), KIND_OTHER_COMMAND)
        self.assertEqual(vb._classify_taxonomy('echo "step one; pytest next"'), KIND_OTHER_COMMAND)
        self.assertEqual(vb._classify_taxonomy("git commit -m 'note; ruff clean'"), KIND_OTHER_COMMAND)
        # A REAL top-level chained verification still classifies as verification.
        self.assertEqual(vb._classify_taxonomy('echo "prep" && pytest tests/'), KIND_VERIFICATION)

    # --- J1: the exporter must write a JOB-level started_at only (null when the
    #         job never started), not fold in the run-level start. -----------
    def test_export_started_at_is_job_level_only(self) -> None:
        export = _load_export_census()
        runs = [{"id": 7, "path": ".github/workflows/x.yml", "name": "X", "run_attempt": 1,
                 "created_at": "t", "run_started_at": "2026-07-16T01:00:00Z",
                 "conclusion": "success", "status": "completed"}]
        # A job with NO job-level started_at must NOT inherit the run-level start.
        jobs_by_run = {7: [{"name": "claude", "started_at": None, "completed_at": "t2",
                            "conclusion": "cancelled", "status": "completed"}]}
        snap = export.build_snapshot("o/r", [], "a", "b", runs, jobs_by_run, "qt", True)
        row = snap["rows"][0]
        self.assertIsNone(row["started_at"])
        self.assertEqual(row["run_started_at"], "2026-07-16T01:00:00Z")

    # --- I1: two independent sessions each running the same verification command
    #         must NOT be grouped into a transport-retry candidate (the
    #         session-local occurrence_id must not collide across sessions). ----
    def test_two_sessions_same_command_are_independent_lifecycles(self) -> None:
        b = transcript(
            user("/devflow:implement 527"),
            bash_call("lib/test/run.sh", "tu1"),
            tool_result("tu1", "ok; exit code 0"),
        )
        # Two separate sessions, each a full implement lifecycle running the suite.
        for sid in ("sess-A", "sess-B"):
            write_manifest(self.manifests, sid)
            write_bundle(self.bundles, sid, b)
        rc = main(["--manifests-dir", str(self.manifests), "--bundles-dir", str(self.bundles),
                   "--registry", str(REGISTRY), "--out-dir", str(self.out)])
        self.assertEqual(rc, 0)
        runs = sorted(self.out.iterdir())
        doc = json.loads((runs[-1] / "verification_baseline.json").read_text(encoding="utf-8"))
        # Both launches share a binding digest -> one group. It must be classified
        # independent (distinct lifecycles), NOT a transport-retry candidate.
        self.assertEqual(doc["metrics"]["candidate_retries"], 0)
        groups = doc["relationship_groups"]
        multi = [g for g in groups if len(g["members"]) > 1]
        self.assertTrue(multi, "expected the two same-command launches to group together")
        for g in multi:
            # Distinct sessions -> distinct lifecycle IDs -> independent (NOT
            # candidate, NOT the pre-fix 'unclassifiable' from a collapsed lifecycle).
            self.assertEqual(g["relationship"], REL_INDEPENDENT_LIFECYCLE)

    # --- I4: a chained command whose segments are all read-only tools must not
    #         be counted as a verification launch (regression from the G8
    #         chaining fix); grep/cat/etc. with a test-tool name in args too. ---
    def test_chained_readonly_commands_are_not_verification(self) -> None:
        self.assertEqual(vb._classify_taxonomy("cat lib/test/run.sh && echo done"), KIND_OTHER_COMMAND)
        self.assertEqual(vb._classify_taxonomy("grep -r pytest . && ls"), KIND_OTHER_COMMAND)
        self.assertEqual(vb._classify_taxonomy("grep -r pytest ."), KIND_OTHER_COMMAND)
        # A real verification segment in a chain is still verification.
        self.assertEqual(vb._classify_taxonomy("cd repo && pytest tests/"), KIND_VERIFICATION)
        self.assertEqual(vb._classify_taxonomy("ruff check && git commit -m x"), KIND_VERIFICATION)

    # --- I5: the exit-code heuristic must not bind an incidental number from
    #         prose like "will exit 5 minutes". ------------------------------
    def test_exit_code_regex_ignores_incidental_prose(self) -> None:
        self.assertIsNone(vb._exit_evidence({"is_error": False, "content": "will exit 5 minutes"})["exit_code"])
        self.assertEqual(vb._exit_evidence({"is_error": False, "content": "done; exit code 0"})["exit_code"], 0)
        self.assertEqual(vb._exit_evidence({"is_error": False, "content": "rc: 2"})["exit_code"], 2)

    # --- H1: a skipped cloud job is ineligible EVEN WHEN the API populated a
    #         started_at (the guard must not fail open on that assumption). ----
    def test_skipped_cloud_job_with_started_at_is_ineligible(self) -> None:
        snap = {
            "schema_version": 1, "snapshot_hash": "h", "query_time": "t",
            "pagination_complete": True, "repository": "o/r",
            "rows": [
                # A skipped job that DOES carry a started_at — must still be ineligible.
                {"workflow_file": ".github/workflows/devflow-implement.yml", "job": "claude",
                 "run_id": 9, "run_attempt": 1, "started_at": "2026-07-16T01:00:10Z",
                 "conclusion": "skipped", "status": "completed"},
            ],
        }
        rows, _ = build_cloud_census(snap, load_cloud_mappings(REGISTRY))
        self.assertEqual(rows[0].eligibility_state, ELIGIBILITY_INELIGIBLE)

    # --- H2: HEAD coverage must use a word boundary too — 'ahead of' (git
    #         status) must NOT mark the HEAD root covered. -------------------
    def test_head_root_not_covered_by_ahead(self) -> None:
        state = vb._workspace_state([_result_event("Your branch is ahead of 'origin/main' by 1 commit.")], 0, 0)
        self.assertNotIn("head", state["covered_roots"])

    def test_head_root_covered_by_real_head_mention(self) -> None:
        state = vb._workspace_state([_result_event("HEAD detached at abc123")], 0, 0)
        self.assertIn("head", state["covered_roots"])

    # --- H3: host_profile must extract .value from the recorder's
    #         {"value","source"} dict shape, not require a bare string. -------
    def test_host_profile_reads_value_source_dicts(self) -> None:
        doc = {
            "provider": {"value": "bedrock", "source": "env"},
            "devflow_version": {"value": "2.1.0", "source": "plugin_manifest"},
            "claude_code_version": {"value": "1.0.0", "source": "cli"},
            "model_effort": {"requested_model": "claude-sonnet-5"},
            "git": {"branch": "main"},
        }
        hp = vb._host_profile_from_manifest(doc)
        self.assertEqual(hp["provider"], "bedrock")
        self.assertEqual(hp["devflow_version"], "2.1.0")
        self.assertEqual(hp["claude_code_version"], "1.0.0")
        self.assertEqual(hp["model"], "claude-sonnet-5")

    # --- Test-gap fills flagged in both shadow passes. ----------------------
    def test_fetch_jobs_total_count_undercount_marks_incomplete(self) -> None:
        # A final short page whose accumulated count is < the API-reported
        # total_count must flip pagination_complete=False (silent short census).
        export = _load_export_census()

        def fake_gh_json(gh, args):
            joined = " ".join(args)
            if "/actions/runs/7/jobs" in joined:
                # total_count=200 but only 150 jobs across the pages we return.
                page = next((a.split("=")[-1] for a in args if a.startswith("--field=page=")), "1")
                if page == "1":
                    return {"total_count": 200, "jobs": [{"name": f"j{i}"} for i in range(100)]}
                return {"total_count": 200, "jobs": [{"name": f"j{i}"} for i in range(100, 150)]}
            return {"workflow_runs": [{"id": 7, "path": ".github/workflows/x.yml", "name": "X"}]}

        export._gh_json = fake_gh_json
        _, jobs_by_run, complete = export.fetch_runs_and_jobs("gh", "o/r", [], "2026-07-01", "2026-08-01")
        self.assertEqual(len(jobs_by_run[7]), 150)  # data retained
        self.assertFalse(complete)  # but marked incomplete (150 < 200)

    def test_validate_admitted_path_rejects_symlink_escape(self) -> None:
        # Plant a symlink under .devflow/tmp pointing outside the repo root and
        # assert it is rejected (the function's headline security promise).
        link = Path(self.tmp) / "escape-link"
        try:
            link.symlink_to("/etc")
        except OSError:
            self.skipTest("symlinks unsupported on this platform")
        rel = link.relative_to(ROOT)
        with self.assertRaises(ValueError):
            vb._validate_admitted_path(str(rel / "passwd"))

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


class Pr531ReceivingReviewFixTests(_TmpDirTestCase):
    """Regression tests for the PR #531 receiving-code-review fixes (the
    APPROVE-with-notes Important/Suggestion findings)."""

    # --- Important 1: non-UTF-8 inputs degrade to denominator rows, never an
    #     analyzer abort (UnicodeDecodeError is a ValueError, not OSError). ----
    def test_non_utf8_manifest_is_unknown_unreadable_row(self) -> None:
        (self.manifests / "sess-bad.json").write_bytes(b"\xff\xfe{not utf8")
        rows = build_local_census(self.manifests, wfr.load_registry(REGISTRY))
        self.assertEqual(rows[0].eligibility_state, ELIGIBILITY_UNKNOWN)
        self.assertEqual(rows[0].source_status, SOURCE_UNREADABLE)

    def test_non_utf8_bundle_metadata_is_unreadable(self) -> None:
        write_manifest(self.manifests, "s-bm")
        d = self.bundles / "s-bm"
        d.mkdir(parents=True)
        (d / "metadata.json").write_bytes(b"\xff\xfe{bad")
        (d / "transcript.jsonl").write_bytes(transcript(user("x")))
        rows = build_local_census(self.manifests, wfr.load_registry(REGISTRY))
        rows = vb.join_local_imports(rows, self.bundles, 64 * 1024 * 1024)
        self.assertEqual(rows[0].source_status, SOURCE_UNREADABLE)

    # --- Suggestion 1 + Important 1: an unreadable/non-UTF-8 stop-attempts log
    #     routes to source_unreadable, never coerced to "no failure". ---------
    def test_non_utf8_stop_attempts_routes_unreadable(self) -> None:
        write_manifest(self.manifests, "s-sa")
        write_bundle(self.bundles, "s-sa", transcript(user("x")))
        (self.bundles / "s-sa" / "stop-attempts.jsonl").write_bytes(b"\xff\xfe not utf8")
        rows = build_local_census(self.manifests, wfr.load_registry(REGISTRY))
        rows = vb.join_local_imports(rows, self.bundles, 64 * 1024 * 1024)
        self.assertEqual(rows[0].source_status, SOURCE_UNREADABLE)

    def test_import_failed_tri_state_none_on_oserror(self) -> None:
        d = self.bundles / "s-tri"
        d.mkdir(parents=True)
        # Real writer shape: an attempts log whose entries never reached
        # `result: "captured"` is an attempted-but-never-successful import.
        (d / "stop-attempts.jsonl").write_text(json.dumps({"result": "started", "source": "stop_hook"}) + "\n", encoding="utf-8")
        # Positive control on the same fixture: readable log with no captured
        # entry -> True (the tri-state's failure arm still works).
        self.assertIs(vb._import_failed(d), True)
        with mock.patch("pathlib.Path.read_text", side_effect=OSError("denied")):
            self.assertIsNone(vb._import_failed(d))

    def test_non_utf8_cloud_census_reads_unreadable_reason(self) -> None:
        tmp = Path(self.tmp) / "census-bad.json"
        tmp.write_bytes(b"\xff\xfe{bad")
        doc, reason = read_cloud_census(tmp)
        self.assertIsNone(doc)
        self.assertIn("unreadable", reason)

    def test_non_utf8_registry_cloud_mappings_returns_empty(self) -> None:
        reg = Path(self.tmp) / "reg-bad-utf8.json"
        reg.write_bytes(b"\xff\xfe{bad")
        self.assertEqual(load_cloud_mappings(reg), {})

    # --- Important 2: a per-transcript extraction failure degrades only that
    #     row (source_unsupported + breadcrumb); healthy bundles survive. -----
    def test_extraction_isolates_per_transcript_failures(self) -> None:
        b = transcript(
            user("/devflow:implement 527"),
            bash_call("lib/test/run.sh", "tu1"),
            tool_result("tu1", "ok; exit code 0"),
        )
        for sid in ("sess-boom", "sess-fine"):
            write_manifest(self.manifests, sid)
            write_bundle(self.bundles, sid, b)
        rows = build_local_census(self.manifests, wfr.load_registry(REGISTRY))
        rows = vb.join_local_imports(rows, self.bundles, 64 * 1024 * 1024)
        real_detect = vb.wfr.detect_occurrences
        calls = {"n": 0}

        def boom_first(events, registry):
            calls["n"] += 1
            if calls["n"] == 1:
                raise KeyError("unexpected-but-JSON-valid event shape")
            return real_detect(events, registry)

        buf = io.StringIO()
        with mock.patch.object(vb.wfr, "detect_occurrences", side_effect=boom_first):
            with contextlib.redirect_stderr(buf):
                requests, launches, rows = vb.extract_verification_lifecycles(
                    rows, self.bundles, wfr.load_registry(REGISTRY), 64 * 1024 * 1024
                )
        by = {r.identity.get("session_id"): r.source_status for r in rows}
        self.assertEqual(by["sess-boom"], SOURCE_UNSUPPORTED)
        self.assertEqual(by["sess-fine"], SOURCE_AVAILABLE)
        # The healthy bundle still produced its launch; the breadcrumb names
        # the degraded session + exception type (never raw transcript text).
        self.assertEqual(len(launches), 1)
        self.assertIn("sess-boom", buf.getvalue())
        self.assertIn("KeyError", buf.getvalue())

    # --- Important 3: performance.input_bytes counts the bytes actually read
    #     (transcripts + manifests + registry), not evidence-string lengths. --
    def test_input_bytes_counts_transcript_bytes(self) -> None:
        b = transcript(
            user("/devflow:implement 527"),
            bash_call("lib/test/run.sh", "tu1"),
            tool_result("tu1", "padding " * 500 + "; exit code 0"),
        )
        write_manifest(self.manifests, "s-ib")
        write_bundle(self.bundles, "s-ib", b)
        rc = main(["--manifests-dir", str(self.manifests), "--bundles-dir", str(self.bundles),
                   "--registry", str(REGISTRY), "--out-dir", str(self.out)])
        self.assertEqual(rc, 0)
        baseline = json.loads((sorted(self.out.iterdir())[-1] / "verification_baseline.json").read_text(encoding="utf-8"))
        # The transcript alone is > its own size; evidence strings are ~40 bytes.
        self.assertGreaterEqual(baseline["performance"]["input_bytes"], len(b))

    # --- Important 4: coverage="complete" requires a SINGLE result covering
    #     every required root; scattered keywords never assemble it. ---------
    def test_workspace_complete_requires_single_result_enumeration(self) -> None:
        full = "head main; index clean; submodule none; tracked 5; untracked 0; ignored node_modules/"
        state = vb._workspace_state([_result_event(full)], 0, 0)
        self.assertEqual(state["coverage"], "complete")
        # The same keywords split across two unrelated results: union still
        # reported, but coverage stays incomplete (mutation_state_unbounded).
        half_a = "head main; index clean; submodule none"
        half_b = "tracked 5; untracked 0; ignored node_modules/"
        state = vb._workspace_state([_result_event(half_a), _result_event(half_b)], 0, 1)
        self.assertEqual(state["coverage"], "incomplete")
        self.assertTrue(state["mutation_state_unbounded"])
        self.assertIn("head", state["covered_roots"])
        self.assertIn("untracked", state["covered_roots"])

    # --- Important 5: taxonomy fields validate at construction; extraction
    #     records are frozen. ------------------------------------------------
    def test_dataclass_taxonomy_validation_and_frozen(self) -> None:
        with self.assertRaises(ValueError):
            make_launch("x", start_auth="not-a-start-class")
        launch = make_launch("ok")
        with self.assertRaises(dataclasses.FrozenInstanceError):
            launch.start_authorization = START_CONFIRMED_TERMINAL
        with self.assertRaises(ValueError):
            dataclasses.replace(launch, retrigger_evidence="false")  # not a bool
        with self.assertRaises(ValueError):
            vb.RelationshipGroup(
                group_id="g", members=["a"], relationship="bogus-class",
                join_confidence=CONFIDENCE_EXACT, workspace_state={}, binding_digest=None,
                consumer=None, duration_ms=None, provenance={},
            )
        with self.assertRaises(ValueError):
            vb.EligibleLifecycle(
                source="local", surrogate_id="s", consumer=None, subject=None,
                identity={}, eligibility_state="bogus", eligibility_evidence="",
                host_profile=None, source_status=SOURCE_MISSING, provenance={},
            )

    # --- Important 6: stratify() coverage (previously untested) + the
    #     deliberate always-None host_os dimension. --------------------------
    def test_stratify_builds_strata_and_counts_incomplete(self) -> None:
        rows = build_local_census(self.manifests, wfr.load_registry(REGISTRY))
        a = make_launch("a", binding_digest="D1")
        b = make_launch("b", binding_digest="D2")
        strat = vb.stratify([a, b], rows)
        self.assertEqual(strat["strata_count"], 2)
        self.assertEqual(sum(strat["strata"].values()), 2)
        # Every Wave-1 stratum has null dimensions (host_os, effort, ...) so all
        # launches count incomplete/non-comparable.
        self.assertEqual(strat["incomplete_strata_launches"], 2)
        self.assertIn("non-comparable", strat["non_comparable_note"])

    def test_stratify_host_profile_dimension_is_always_incomplete(self) -> None:
        # _host_profile_from_manifest deliberately never writes host_os in Wave 1
        # (not derivable without a subprocess): the dimension must be None even
        # for a fully-populated real-shape manifest, keeping the stratum
        # incomplete (unknown-is-not-zero for stratification).
        hp = vb._host_profile_from_manifest(manifest("sess-1"))
        self.assertNotIn("host_os", hp)
        write_manifest(self.manifests, "s-h")
        rows = build_local_census(self.manifests, wfr.load_registry(REGISTRY))
        launch = make_launch("h1")
        launch.provenance["session_id"] = "s-h"
        strat = vb.stratify([launch], rows)
        self.assertEqual(strat["incomplete_strata_launches"], 1)

    # --- Suggestion 2: a corrupt --cloud-census counts as an unavailable cloud
    #     measurement in source_missingness (report and counter agree). ------
    def test_corrupt_cloud_census_counts_unavailable(self) -> None:
        write_manifest(self.manifests, "s-cc")
        bad = Path(self.tmp) / "census-corrupt.json"
        bad.write_text("{not json", encoding="utf-8")
        rc = main(["--manifests-dir", str(self.manifests), "--bundles-dir", str(self.bundles),
                   "--registry", str(REGISTRY), "--out-dir", str(self.out),
                   "--cloud-census", str(bad)])
        self.assertEqual(rc, 0)
        baseline = json.loads((sorted(self.out.iterdir())[-1] / "verification_baseline.json").read_text(encoding="utf-8"))
        self.assertTrue(baseline["cloud_coverage"]["unavailable"])
        self.assertEqual(baseline["metrics"]["source_availability_and_missingness"]["unavailable"], 1)

    def test_no_cloud_flag_leaves_unavailable_counter_zero(self) -> None:
        # Positive control for the counter: no --cloud-census means no cloud
        # measurement was attempted — nothing unavailable to count.
        write_manifest(self.manifests, "s-nc")
        rc = main(["--manifests-dir", str(self.manifests), "--bundles-dir", str(self.bundles),
                   "--registry", str(REGISTRY), "--out-dir", str(self.out)])
        self.assertEqual(rc, 0)
        baseline = json.loads((sorted(self.out.iterdir())[-1] / "verification_baseline.json").read_text(encoding="utf-8"))
        self.assertEqual(baseline["metrics"]["source_availability_and_missingness"]["unavailable"], 0)

    # --- Suggestion 3: queued/not-evidenced-started agent jobs are provisional,
    #     never confirmed (no over-claimed confirmed denominator). -----------
    def test_queued_and_unstamped_cloud_jobs_are_provisional(self) -> None:
        snap = {
            "schema_version": 1, "snapshot_hash": "h", "query_time": "t",
            "pagination_complete": True, "repository": "o/r",
            "rows": [
                {"workflow_file": ".github/workflows/devflow-implement.yml", "job": "claude",
                 "run_id": 1, "run_attempt": 1, "started_at": None, "conclusion": None, "status": "queued"},
                {"workflow_file": ".github/workflows/devflow-implement.yml", "job": "claude",
                 "run_id": 2, "run_attempt": 1, "started_at": None, "conclusion": None, "status": "in_progress"},
                {"workflow_file": ".github/workflows/devflow-implement.yml", "job": "claude",
                 "run_id": 3, "run_attempt": 1, "started_at": "2026-07-16T01:00:10Z", "conclusion": None, "status": "in_progress"},
                {"workflow_file": ".github/workflows/devflow-implement.yml", "job": "claude",
                 "run_id": 4, "run_attempt": 1, "started_at": "2026-07-16T01:00:10Z", "conclusion": "success", "status": "completed"},
            ],
        }
        rows, _ = build_cloud_census(snap, load_cloud_mappings(REGISTRY))
        by_run = {r.identity["run_id"]: r.eligibility_state for r in rows}
        self.assertEqual(by_run[1], ELIGIBILITY_PROVISIONAL)  # queued
        self.assertEqual(by_run[2], ELIGIBILITY_PROVISIONAL)  # in_progress, no job start
        self.assertEqual(by_run[3], ELIGIBILITY_CONFIRMED)    # in_progress + job started
        self.assertEqual(by_run[4], ELIGIBILITY_CONFIRMED)    # completed + real conclusion

    # --- Suggestion 4: the symlink branch in _validate_admitted_path exists for
    #     unresolvable symlinks (a loop) and fails closed on them. ------------
    def test_validate_admitted_path_rejects_symlink_loop(self) -> None:
        loop = Path(self.tmp) / "loop-link"
        try:
            loop.symlink_to(loop.name)  # self-referential loop
        except OSError:
            self.skipTest("symlinks unsupported on this platform")
        rel = loop.relative_to(ROOT)
        with self.assertRaises(ValueError):
            vb._validate_admitted_path(str(rel))

    # --- Suggestion 5: `env FOO=bar pytest` unwraps to the real head; bare
    #     `env` stays other_command; find -exec remains a documented gap. ----
    def test_env_wrapper_unwraps_to_real_head(self) -> None:
        self.assertEqual(vb._classify_taxonomy("env FOO=1 pytest tests/"), KIND_VERIFICATION)
        self.assertEqual(vb._command_head("env FOO=1 pytest tests/"), "pytest")
        self.assertEqual(vb._classify_taxonomy("env FOO=1 git status"), KIND_OTHER_COMMAND)
        self.assertEqual(vb._classify_taxonomy("env"), KIND_OTHER_COMMAND)
        # Documented Wave-1 wrapper-head gap (accepted limitation, pinned so a
        # behavior change is a deliberate edit): find -exec is read-only-headed.
        self.assertEqual(vb._classify_taxonomy("find . -name '*.py' -exec pytest {} +"), KIND_OTHER_COMMAND)


class ExporterSubprocessTests(_TmpDirTestCase):
    """Important 6 (part 2): drive the exporter's real subprocess wrapper
    `_gh_json` and `main()` end-to-end through on-disk stub gh executables —
    not monkeypatched fakes — so the rc/stdout/missing-binary branches are
    exercised through the code that actually ships."""

    def _stub(self, name: str, body: str) -> str:
        path = Path(self.tmp) / name
        path.write_text("#!/bin/sh\n" + body + "\n", encoding="utf-8")
        path.chmod(0o700)
        return str(path)

    def test_gh_json_real_subprocess_branches(self) -> None:
        export = _load_export_census()
        ok = self._stub("gh-ok", "echo '{\"workflow_runs\": []}'")
        self.assertEqual(export._gh_json(ok, ["api", "x"]), {"workflow_runs": []})
        # rc != 0 -> None + stderr breadcrumb naming the rc.
        fail = self._stub("gh-fail", "echo 'HTTP 401' >&2; exit 1")
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            self.assertIsNone(export._gh_json(fail, ["api", "x"]))
        self.assertIn("rc=1", buf.getvalue())
        self.assertIn("401", buf.getvalue())
        # Malformed stdout -> None + breadcrumb.
        bad = self._stub("gh-bad", "echo 'not json'")
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            self.assertIsNone(export._gh_json(bad, ["api", "x"]))
        self.assertIn("malformed", buf.getvalue())
        # Missing binary -> None + breadcrumb (FileNotFoundError branch).
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            self.assertIsNone(export._gh_json(str(Path(self.tmp) / "gh-missing"), ["api", "x"]))
        self.assertIn("not found", buf.getvalue())

    def test_export_main_end_to_end_with_stub_gh(self) -> None:
        export = _load_export_census()
        out = Path(self.tmp) / "census.json"
        # Empty window, complete pagination: snapshot written, complete.
        ok = self._stub("gh-empty", "echo '{\"workflow_runs\": []}'")
        rc = export.main(["--repo", "o/r", "--created-after", "2026-07-01", "--created-before", "2026-07-02",
                          "--out", str(out), "--gh", ok])
        self.assertEqual(rc, 0)
        snap = json.loads(out.read_text(encoding="utf-8"))
        self.assertTrue(snap["pagination_complete"])
        self.assertEqual(snap["row_count"], 0)
        # Degradation: gh fails -> snapshot still written, pagination_complete
        # False, loud WARNING on stderr (rc stays 0 by design — the degraded
        # snapshot is usable and the analyzer reads it as unavailable).
        fail = self._stub("gh-down", "exit 1")
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            rc = export.main(["--repo", "o/r", "--created-after", "2026-07-01", "--created-before", "2026-07-02",
                              "--out", str(out), "--gh", fail])
        self.assertEqual(rc, 0)
        snap = json.loads(out.read_text(encoding="utf-8"))
        self.assertFalse(snap["pagination_complete"])
        # Reconciled with the reworded warning (PR #531 review-and-fix iter-1):
        # the message now names WHICH cause fired, because "pagination
        # incomplete" alone misdiagnosed a clean-transport dropped-row census.
        # Still pins the two things this test is about — the warning fires, and
        # it attributes the degradation to the transport failure the stub caused.
        self.assertIn("snapshot incomplete", buf.getvalue())
        self.assertIn("transport failure", buf.getvalue())


class Pr531Iter1FixLoopTests(_TmpDirTestCase):
    """Regression tests for the PR #531 review-and-fix iteration-1 findings."""

    # --- VC-21: secret redaction must cover quoted values and curl -u creds. ---
    def test_quoted_env_secret_value_fully_redacted(self) -> None:
        b = vb._binding_identity('export TOKEN="my secret value" && lib/test/run.sh')
        self.assertTrue(b.secret_affected)
        for fragment in ("my secret value", "secret value", "my secret"):
            self.assertNotIn(fragment, b.redacted_display)
        # The digest is computed over the redacted form: same shape with a
        # different quoted secret -> same digest (no secret material digested).
        b2 = vb._binding_identity('export TOKEN="other hidden words" && lib/test/run.sh')
        self.assertEqual(b.digest, b2.digest)

    def test_single_quoted_env_secret_value_fully_redacted(self) -> None:
        b = vb._binding_identity("PASSWORD='p q r' lib/test/run.sh")
        self.assertTrue(b.secret_affected)
        self.assertNotIn("p q r", b.redacted_display)

    def test_quoted_flag_secret_value_fully_redacted(self) -> None:
        b = vb._binding_identity('mytool --token="quoted secret words" lib/test/run.sh')
        self.assertTrue(b.secret_affected)
        self.assertNotIn("quoted secret words", b.redacted_display)

    def test_curl_short_u_credentials_redacted(self) -> None:
        b = vb._binding_identity("curl -u deploy:MYPASS123 https://example.invalid/x")
        self.assertTrue(b.secret_affected)
        self.assertNotIn("MYPASS123", b.redacted_display)
        self.assertIn("url-cred" if "url-cred" in b.secret_slots else "flag:u", b.secret_slots)

    # --- F4: a cancelled/action_required completed job with no job-level
    #         started_at must never read confirmed_eligible. -----------------
    def _census_row_state(self, conclusion: str, started_at: "str | None") -> str:
        snapshot = {
            "schema_version": 1, "snapshot_hash": "h", "query_time": "t",
            "pagination_complete": True, "repository": "o/r",
            "rows": [{"workflow_file": ".github/workflows/devflow-implement.yml",
                      "job": "claude", "run_id": 1, "run_attempt": 1,
                      "started_at": started_at, "status": "completed",
                      "conclusion": conclusion}],
        }
        cm = load_cloud_mappings(REGISTRY)
        rows, _cov = vb.build_cloud_census(snapshot, cm)
        return rows[0].eligibility_state

    def test_cancelled_never_started_cloud_job_not_confirmed(self) -> None:
        # A run cancelled while the job was queued: status=completed,
        # conclusion=cancelled, started_at=None — the agent step never ran.
        self.assertEqual(self._census_row_state("cancelled", None), ELIGIBILITY_INELIGIBLE)

    def test_action_required_never_started_cloud_job_not_confirmed(self) -> None:
        self.assertEqual(self._census_row_state("action_required", None), ELIGIBILITY_INELIGIBLE)

    def test_cancelled_with_job_start_is_confirmed(self) -> None:
        # Cancellation AFTER the job started is genuine start evidence.
        self.assertEqual(self._census_row_state("cancelled", "2026-07-16T01:00:00Z"), ELIGIBILITY_CONFIRMED)

    # --- F3: "prior missing/cancelled response" requires the missing evidence
    #         on a member that is NOT the temporally last launch. ------------
    def test_missing_response_on_last_launch_is_not_prior(self) -> None:
        first = make_launch("a", start_auth=START_CONFIRMED_TERMINAL,
                            started="2026-07-16T01:01:00Z", finished="2026-07-16T01:02:00Z")
        last = make_launch("b", start_auth=START_CONFIRMED_RESULT_MISSING,
                           started="2026-07-16T01:03:00Z", finished="2026-07-16T01:04:00Z")
        rel, _conf = vb._classify_relationship([first, last])
        self.assertNotEqual(rel, REL_CANDIDATE_TRANSPORT_RETRY)

    def test_missing_response_before_relaunch_is_still_candidate(self) -> None:
        first = make_launch("a", start_auth=START_CONFIRMED_RESULT_MISSING,
                            started="2026-07-16T01:01:00Z", finished="2026-07-16T01:02:00Z")
        last = make_launch("b", start_auth=START_CONFIRMED_TERMINAL,
                           started="2026-07-16T01:03:00Z", finished="2026-07-16T01:04:00Z")
        rel, conf = vb._classify_relationship([first, last])
        self.assertEqual(rel, REL_CANDIDATE_TRANSPORT_RETRY)
        self.assertEqual(conf, CONFIDENCE_EXACT)

    def test_list_order_is_the_fallback_when_timestamps_unparseable(self) -> None:
        # Both members carry BOUNDED timing (so the interval guard is satisfied
        # and only ordering decides), but the started_at values are unparseable
        # strings — the sort cannot run, so list position decides "last". The
        # missing-response member is list-last -> not prior -> not a candidate.
        first = make_launch("a", start_auth=START_CONFIRMED_TERMINAL,
                            started="not-a-time-1", finished="2026-07-16T01:02:00Z")
        last = make_launch("b", start_auth=START_CONFIRMED_RESULT_MISSING,
                           started="not-a-time-2", finished="2026-07-16T01:04:00Z")
        rel, _conf = vb._classify_relationship([first, last])
        self.assertNotEqual(rel, REL_CANDIDATE_TRANSPORT_RETRY)
        # Control on the same fixture shape: missing member list-FIRST -> candidate.
        rel2, _conf2 = vb._classify_relationship([last, first])
        self.assertEqual(rel2, REL_CANDIDATE_TRANSPORT_RETRY)

    def test_temporal_order_beats_list_order_when_timestamps_parse(self) -> None:
        # Differential pin on the SORT itself (PR #531 iter-1 gate finding 3/4):
        # the missing-response member is list-FIRST but temporally LAST via a
        # sub-second timestamp that breaks a lexicographic string sort
        # ("...:00.500Z" < "...:00Z" bytewise, though it is 500ms LATER).
        # Deleting the sort (list order) or sorting lexicographically both
        # wrongly classify this a candidate.
        miss_temporally_last = make_launch("m", start_auth=START_CONFIRMED_RESULT_MISSING,
                                           started="2026-07-16T01:01:00.500Z",
                                           finished="2026-07-16T01:02:00Z")
        ok_temporally_first = make_launch("k", start_auth=START_CONFIRMED_TERMINAL,
                                          started="2026-07-16T01:01:00Z",
                                          finished="2026-07-16T01:02:00Z")
        rel, _conf = vb._classify_relationship([miss_temporally_last, ok_temporally_first])
        self.assertNotEqual(rel, REL_CANDIDATE_TRANSPORT_RETRY)
        # Reverse: missing member temporally FIRST though list-last -> candidate.
        miss_first = make_launch("m2", start_auth=START_CONFIRMED_RESULT_MISSING,
                                 started="2026-07-16T01:01:00Z", finished="2026-07-16T01:01:30Z")
        ok_last = make_launch("k2", start_auth=START_CONFIRMED_TERMINAL,
                              started="2026-07-16T01:01:00.500Z", finished="2026-07-16T01:02:00Z")
        rel2, conf2 = vb._classify_relationship([ok_last, miss_first])
        self.assertEqual(rel2, REL_CANDIDATE_TRANSPORT_RETRY)
        self.assertEqual(conf2, CONFIDENCE_EXACT)
        # Mixed offset spellings (+00:00 vs Z) must also order temporally.
        miss_z_last = make_launch("m3", start_auth=START_CONFIRMED_RESULT_MISSING,
                                  started="2026-07-16T01:02:00+00:00", finished="2026-07-16T01:03:00Z")
        ok_earlier = make_launch("k3", start_auth=START_CONFIRMED_TERMINAL,
                                 started="2026-07-16T01:01:00Z", finished="2026-07-16T01:01:30Z")
        rel3, _conf3 = vb._classify_relationship([miss_z_last, ok_earlier])
        self.assertNotEqual(rel3, REL_CANDIDATE_TRANSPORT_RETRY)

    # --- Gate findings 1-2: adjacent-concatenation and quoted -u values must
    #     redact whole (the quoted-first alternation stopped at the close). ---
    def test_adjacent_concatenation_secret_value_fully_redacted(self) -> None:
        b = vb._binding_identity('TOKEN="abc"def lib/test/run.sh')
        self.assertTrue(b.secret_affected)
        self.assertNotIn("def", b.redacted_display.replace("<env:TOKEN>", ""))
        b2 = vb._binding_identity('mytool --token="abc"tail lib/test/run.sh')
        self.assertTrue(b2.secret_affected)
        self.assertNotIn("tail", b2.redacted_display.replace("<flag:--token>", "").replace("flag:", ""))

    def test_unterminated_quote_secret_consumes_to_end(self) -> None:
        # Re-gate finding 1: an opening quote with no close (typo, truncation)
        # must consume to end-of-string — in shell the open quote DOES swallow
        # the rest, so redacting to EOL is the faithful (and safe) reading.
        b = vb._binding_identity('TOKEN="secret with spaces that got truncated mid-valu')
        self.assertTrue(b.secret_affected)
        for fragment in ("with spaces", "truncated", "mid-valu"):
            self.assertNotIn(fragment, b.redacted_display)

    def test_attached_short_u_credential_redacted(self) -> None:
        # Re-gate finding 2: curl's compact attached spelling -uuser:pass.
        b = vb._binding_identity("curl -uuser:pass https://example.invalid/")
        self.assertTrue(b.secret_affected)
        self.assertNotIn("user:pass", b.redacted_display)
        # Quoted user half with a space.
        b2 = vb._binding_identity('curl -u "user name":pass https://example.invalid/')
        self.assertTrue(b2.secret_affected)
        self.assertNotIn(":pass", b2.redacted_display)
        # --user long flag and bare `sort -u` must NOT false-positive.
        b3 = vb._binding_identity("sort -u lib/test/run.sh")
        self.assertFalse(b3.secret_affected)

    def test_negative_byte_claim_is_unestablishable(self) -> None:
        # Re-gate finding 3: the writer emits len(raw) >= 0, so a negative int
        # is corrupt exactly like a string claim — unestablishable, fails closed.
        write_manifest(self.manifests, "s-neg-tb")
        write_bundle(self.bundles, "s-neg-tb", b"",
                     stop_attempts=[{"result": "captured", "transcript_bytes": -5}])
        rows = build_local_census(self.manifests, wfr.load_registry(REGISTRY))
        rows = vb.join_local_imports(rows, self.bundles, 64 * 1024 * 1024)
        self.assertEqual(rows[0].source_status, SOURCE_IMPORT_FAILED)

    def test_short_u_quoted_password_with_space_fully_redacted(self) -> None:
        b = vb._binding_identity('curl -u user:"pass word" https://example.invalid/')
        self.assertTrue(b.secret_affected)
        for fragment in ("pass word", " word"):
            self.assertNotIn(fragment, b.redacted_display)

    # --- Gate issue #527 review, Important 1: a WHOLE-operand-quoted `-u`
    #     credential hides the separator colon inside the quotes. The prior
    #     halves-oriented pattern needed a TOP-level colon, so it did not fire
    #     and the raw credential reached redacted_display AND the digest input
    #     with secret_affected False. Every spelling below is the recognized
    #     `-u` class the _redact_secrets docstring promises to redact. ---------
    def test_short_u_whole_operand_quoted_credential_redacted(self) -> None:
        for command, leak in (
            ('curl -u "user:pass" https://example.invalid/', "pass"),
            ("curl -u 'user:pass' https://example.invalid/", "pass"),
            ('curl -u"user:pass" https://example.invalid/', "pass"),   # compact + quoted
            ('curl -u "user:pa:ss" https://example.invalid/', "pa:ss"),  # first colon separates
            ('curl -u "user:pass', "pass"),                              # unterminated -> EOL
        ):
            with self.subTest(command=command):
                b = vb._binding_identity(command)
                self.assertTrue(b.secret_affected)
                self.assertIn("flag:u", b.secret_slots)
                self.assertNotIn(leak, b.redacted_display)
                # The digest is taken over the redacted form, so a leak in the
                # display is also a leak into the persisted binding identity.
                self.assertNotIn(leak, vb._binding_identity(command).redacted_display)

    def test_short_u_whole_operand_quoted_negative_controls(self) -> None:
        # Positive control for the fixture shape above: the same `-u` flag with
        # a colon-free operand must NOT redact, so the redaction proven above is
        # attributable to the credential shape and not to `-u` firing on sight.
        for command in ("sort -u lib/test/run.sh", 'curl -u "username" https://example.invalid/'):
            with self.subTest(command=command):
                b = vb._binding_identity(command)
                self.assertFalse(b.secret_affected)
                self.assertFalse(b.secret_slots)
                self.assertEqual(b.redacted_display, command)

    # --- Gate issue #527 review, Suggestion 1 (same recall class as Important
    #     1): a URL password containing `/` or `@`. The old `[^/\s:@]+` password
    #     class did not match `pa/ss` at all (whole credential leaked) and
    #     truncated `pa@ss` at the first `@` (tail leaked). ---------------------
    def test_secret_url_password_with_slash_or_at_redacted(self) -> None:
        # Each password carries a DISTINCTIVE trailing token so the assertion
        # pins the fragment the pre-fix pattern actually leaked, not merely the
        # whole password string: `[^/\s:@]+` truncated the match at the first
        # `@`, so `https://user:pa@SSTAIL@host` redacted to `<url-cred>@SSTAIL@`
        # — a display in which the *contiguous* password "pa@SSTAIL" is absent
        # while SSTAIL itself leaks. Asserting the whole password would pass
        # vacuously against that mutant.
        for command, leaks in (
            ("curl https://user:pa/SLASHTAIL@host.invalid/x lib/test/run.sh", ("pa/SLASHTAIL", "SLASHTAIL")),
            ("curl https://user:pa@SSTAIL@host.invalid/x lib/test/run.sh", ("pa@SSTAIL", "SSTAIL")),
            ("curl https://user:p/a@s:MIXTAIL@host.invalid/x lib/test/run.sh", ("p/a@s:MIXTAIL", "MIXTAIL")),
        ):
            with self.subTest(command=command):
                b = vb._binding_identity(command)
                self.assertTrue(b.secret_affected)
                for leak in leaks:
                    self.assertNotIn(leak, b.redacted_display)

    def test_secret_url_pathy_colon_is_not_a_credential(self) -> None:
        # The user half still excludes `/`, so a colon in a PATH does not turn
        # the URL into a false credential match (the precision the widened
        # password class must not cost).
        b = vb._binding_identity("curl https://host.invalid/a:b@c lib/test/run.sh")
        self.assertFalse(b.secret_affected)
        self.assertFalse(b.secret_slots)
        self.assertEqual(b.redacted_display, "curl https://host.invalid/a:b@c lib/test/run.sh")

    # --- Gate finding 5: a captured claim whose byte field is unusable beside
    #     an empty transcript is unestablishable, never clean. ----------------
    def test_empty_transcript_with_corrupt_byte_claim_fails_closed(self) -> None:
        for tb in ("999", 999.0, None):
            with self.subTest(tb=tb):
                sid = f"s-corrupt-tb-{str(tb).replace('.', '-')}"
                write_manifest(self.manifests, sid)
                entry = {"result": "captured"}
                if tb is not None:
                    entry["transcript_bytes"] = tb
                write_bundle(self.bundles, sid, b"", stop_attempts=[entry])
                rows = build_local_census(self.manifests, wfr.load_registry(REGISTRY))
                rows = vb.join_local_imports(rows, self.bundles, 64 * 1024 * 1024)
                by = {r.identity.get("session_id"): r.source_status for r in rows}
                self.assertEqual(by[sid], SOURCE_IMPORT_FAILED)

    def test_empty_transcript_with_uncaptured_log_is_import_failed(self) -> None:
        # Symmetry with the no-transcript path: an attempted-never-captured log
        # beside a 0-byte transcript is an interrupted import, not a clean
        # empty session.
        write_manifest(self.manifests, "s-unc-empty")
        write_bundle(self.bundles, "s-unc-empty", b"", stop_attempts=[{"result": "started"}])
        rows = build_local_census(self.manifests, wfr.load_registry(REGISTRY))
        rows = vb.join_local_imports(rows, self.bundles, 64 * 1024 * 1024)
        self.assertEqual(rows[0].source_status, SOURCE_IMPORT_FAILED)

    # --- F8: a backslash-escaped quote inside a double-quoted argument must
    #         not flip quote state and manufacture a verification segment. ---
    def test_escaped_quote_does_not_split_segments(self) -> None:
        self.assertEqual(
            vb._classify_taxonomy('git commit -m "note \\" and && pytest later"'),
            KIND_OTHER_COMMAND)

    def test_odd_escaped_quote_count_stays_one_segment(self) -> None:
        self.assertEqual(
            vb._classify_taxonomy('git commit -m "a \\" b \\" c \\" && pytest d"'),
            KIND_OTHER_COMMAND)

    def test_unquoted_chain_still_splits(self) -> None:
        self.assertEqual(vb._classify_taxonomy('echo "x" && pytest tests/'), KIND_VERIFICATION)

    # --- VC-5/SFH-2/SFH-3: stop-attempts reader aligned to the real writer. --
    def test_all_corrupt_stop_attempts_routes_unreadable(self) -> None:
        write_manifest(self.manifests, "s-corrupt")
        d = self.bundles / "s-corrupt"
        d.mkdir(parents=True, exist_ok=True)
        (d / "metadata.json").write_text(json.dumps({"schema_version": 2}), encoding="utf-8")
        # Valid UTF-8, non-blank lines, zero parseable JSON entries: the failure
        # log itself is unusable — never "no failure evidence".
        (d / "stop-attempts.jsonl").write_text("{truncated\n%%%garbage\n", encoding="utf-8")
        rows = build_local_census(self.manifests, wfr.load_registry(REGISTRY))
        rows = vb.join_local_imports(rows, self.bundles, 64 * 1024 * 1024)
        self.assertEqual(rows[0].source_status, SOURCE_UNREADABLE)

    def test_captured_claim_with_missing_transcript_is_import_failed(self) -> None:
        write_manifest(self.manifests, "s-gone")
        d = self.bundles / "s-gone"
        d.mkdir(parents=True, exist_ok=True)
        (d / "metadata.json").write_text(json.dumps({"schema_version": 2}), encoding="utf-8")
        (d / "stop-attempts.jsonl").write_text(
            json.dumps({"result": "captured", "transcript_bytes": 999}) + "\n", encoding="utf-8")
        rows = build_local_census(self.manifests, wfr.load_registry(REGISTRY))
        rows = vb.join_local_imports(rows, self.bundles, 64 * 1024 * 1024)
        self.assertEqual(rows[0].source_status, SOURCE_IMPORT_FAILED)

    def test_empty_transcript_with_nonzero_capture_claim_is_import_failed(self) -> None:
        write_manifest(self.manifests, "s-empty")
        write_bundle(self.bundles, "s-empty", b"",
                     stop_attempts=[{"result": "captured", "transcript_bytes": 999}])
        rows = build_local_census(self.manifests, wfr.load_registry(REGISTRY))
        rows = vb.join_local_imports(rows, self.bundles, 64 * 1024 * 1024)
        self.assertEqual(rows[0].source_status, SOURCE_IMPORT_FAILED)

    def test_empty_transcript_with_zero_byte_capture_is_available(self) -> None:
        write_manifest(self.manifests, "s-empty0")
        write_bundle(self.bundles, "s-empty0", b"",
                     stop_attempts=[{"result": "captured", "transcript_bytes": 0}])
        rows = build_local_census(self.manifests, wfr.load_registry(REGISTRY))
        rows = vb.join_local_imports(rows, self.bundles, 64 * 1024 * 1024)
        self.assertEqual(rows[0].source_status, SOURCE_AVAILABLE)

    # --- F13: an extraction failure is counted and attributed, and a
    #         total-failure run announces itself. ----------------------------
    def test_extraction_failure_counter_and_provenance(self) -> None:
        write_manifest(self.manifests, "s-iso")
        write_bundle(self.bundles, "s-iso", transcript(
            user("/devflow:implement 527"), bash_call("lib/test/run.sh", "tu1"),
            tool_result("tu1", "exit code 0")))
        rows = build_local_census(self.manifests, wfr.load_registry(REGISTRY))
        rows = vb.join_local_imports(rows, self.bundles, 64 * 1024 * 1024)
        stats: dict = {}
        with mock.patch.object(vb.wfr, "detect_occurrences", side_effect=KeyError("boom")):
            import io as _io
            buf = _io.StringIO()
            with contextlib.redirect_stderr(buf):
                _reqs, _launches, rows = vb.extract_verification_lifecycles(
                    rows, self.bundles, wfr.load_registry(REGISTRY), 64 * 1024 * 1024, stats)
        self.assertEqual(stats.get("extraction_failure_count"), 1)
        self.assertEqual(rows[0].provenance.get("extraction_error"), "KeyError")

    # --- F5: the exporter's conclusion/status are job-level only; run-level
    #         values ride in separate reference keys (like run_started_at). --
    def test_export_conclusion_and_status_are_job_level_only(self) -> None:
        exp = _load_export_census()
        runs = [{"id": 7, "path": ".github/workflows/devflow-implement.yml", "name": "DevFlow Implement",
                 "run_attempt": 1, "created_at": "c", "run_started_at": "rs",
                 "conclusion": "success", "status": "completed", "html_url": "u"}]
        jobs = {7: [{"name": "claude", "started_at": None, "completed_at": None,
                     "conclusion": None, "status": None, "html_url": None}]}
        snap = exp.build_snapshot("o/r", ["wf"], "a", "b", runs, jobs, "t", True)
        row = snap["rows"][0]
        self.assertIsNone(row["conclusion"])
        self.assertIsNone(row["status"])
        self.assertEqual(row["run_conclusion"], "success")
        self.assertEqual(row["run_status"], "completed")

    # --- Type-design hardening: BindingIdentity validates its own invariants. -
    def test_binding_identity_post_init_validation(self) -> None:
        with self.assertRaises(ValueError):
            BindingIdentity(digest="not-hex!", secret_affected=False, secret_slots=(), redacted_display="x")
        with self.assertRaises(ValueError):
            BindingIdentity(digest="a" * 64, secret_affected=True, secret_slots=(), redacted_display="x")
        with self.assertRaises(ValueError):
            BindingIdentity(digest="a" * 64, secret_affected=False, secret_slots=("env:T",), redacted_display="x")
        with self.assertRaises(ValueError):
            BindingIdentity(digest="a" * 64, secret_affected=False, secret_slots=(), redacted_display="x" * 501)

    # --- Coupled-mirror guard: every record field survives into to_dict(). ---
    def test_to_dict_carries_every_field(self) -> None:
        import dataclasses as _dc
        launch = make_launch("a")
        req = vb.VerificationRequest(
            request_id="r", source_event_id="e", lifecycle_id=None, tool_use_id="t",
            consumer_skill=None, phase_checkpoint=None, command_head="x",
            binding=launch.binding, request_kind=KIND_VERIFICATION,
            authorization_start=START_UNKNOWN, timing={}, result_presence=None,
            exit_evidence=None, skipped_check_evidence=None, provenance={},
        )
        for rec in (launch, req, launch.binding):
            keys = set(rec.to_dict().keys())
            for f in _dc.fields(rec):
                self.assertIn(f.name, keys, f"{type(rec).__name__}.{f.name} missing from to_dict")


class Pr531Iter2ShadowFixTests(_TmpDirTestCase):
    """Regression tests for the PR #531 early-shadow findings (iteration 2)."""

    # --- Shadow Critical: SECRET_SHORT_U ReDoS on quote-dense colon-less input. -
    def test_secret_short_u_no_redos_on_quote_dense_input(self) -> None:
        import time as _t
        for payload in ("-u " + '"a"' * 200, "-u " + "'a'" * 200, "id -u " + '"x"' * 200):
            t0 = _t.monotonic()
            vb._binding_identity(payload)
            self.assertLess(_t.monotonic() - t0, 0.5, f"ReDoS on {payload[:12]!r}")

    def test_secret_value_no_redos_defense_in_depth(self) -> None:
        import time as _t
        t0 = _t.monotonic()
        vb._binding_identity('TOKEN=' + '"a"' * 300)
        self.assertLess(_t.monotonic() - t0, 0.5)
        # Behavior preserved: adjacent concatenation still redacts whole.
        b = vb._binding_identity('TOKEN="abc"def lib/test/run.sh')
        self.assertNotIn("def", b.redacted_display.replace("<env:TOKEN>", ""))

    # --- Shadow Critical: real Claude Code tool-rejection is a denial, not a
    #     launch; incidental in-output denial words don't reclassify a launch. --
    def _auth(self, text: str, is_error: bool, exit_code=None, terminal=True) -> str:
        result = {"is_error": is_error, "content": text}
        ev = {"exit_code": exit_code, "terminal_signal_present": terminal}
        return vb._classify_authorization_start(result, ev)

    def test_real_tool_rejection_is_denied_not_launch(self) -> None:
        rej = "The user doesn't want to proceed with this tool use. The tool use was rejected."
        # A genuine Claude Code tool rejection is always delivered with is_error.
        self.assertEqual(self._auth(rej, is_error=True), vb.START_DENIED_PRE)

    def test_successful_command_echoing_rejection_phrase_is_a_launch(self) -> None:
        # A SUCCESSFUL command (is_error False) whose own output merely quotes the
        # rejection phrase — e.g. a transcript of running this repo's own tests,
        # which contain the literal string — must NOT be dropped as a denial
        # (fix-delta gate: the phrase check must be is_error-gated).
        echo = "tool use was rejected"
        self.assertEqual(self._auth(echo, is_error=False), vb.START_CONFIRMED_RESULT_MISSING)

    def test_incidental_denial_word_deep_in_output_is_not_denial(self) -> None:
        # A failing test whose traceback mentions "Permission denied" far into the
        # output must NOT be reclassified as a pre-start denial.
        deep = "collecting tests\n" + ("x" * 600) + "\nPermissionError: [Errno 13] Permission denied"
        self.assertEqual(self._auth(deep, is_error=True), vb.START_CONFIRMED_RESULT_MISSING)

    def test_leading_denial_word_still_classifies_denied(self) -> None:
        self.assertEqual(self._auth("Permission denied: cannot run", is_error=True), vb.START_DENIED_PRE)

    def test_exit_code_beats_incidental_rejection_words(self) -> None:
        self.assertEqual(
            self._auth("the tool use was rejected earlier; exit code 0", is_error=True, exit_code=0),
            vb.START_CONFIRMED_TERMINAL)

    # --- Shadow Important: SECRET_ENV_ASSIGNMENT must not fire on PATH=/PATTERN=. -
    def test_env_secret_keyword_suffix_anchored(self) -> None:
        for benign in ('PATH="/a:/b" x', 'PATTERN="*.py" x', 'KEYWORDS="a b" x', 'PASSTHROUGH=1 x'):
            b = vb._binding_identity(benign)
            self.assertFalse(b.secret_affected, f"{benign!r} must not be secret-affected")
        for real in ('GITHUB_TOKEN=abc x', 'APIKEY=abc x', 'API_KEY=abc x', 'MY_PAT=abc x',
                     'PASSWORD=abc x', 'AWS_SECRET_ACCESS_KEY=abc x',
                     # Plural/compound forms (fix-delta gate recall regression):
                     'API_KEYS=abc x', 'GITHUB_TOKENS=abc x', 'SECRETS=abc x'):
            b = vb._binding_identity(real)
            self.assertTrue(b.secret_affected, f"{real!r} must be secret-affected")
            self.assertNotIn("abc", b.redacted_display)

    # --- Shadow finding: a group with no explicit lifecycle is not a candidate. -
    def test_no_explicit_lifecycle_is_not_candidate(self) -> None:
        a = make_launch("a", lifecycle_id="", start_auth=START_CONFIRMED_RESULT_MISSING,
                        started="2026-07-16T01:01:00Z", finished="2026-07-16T01:02:00Z")
        b = make_launch("b", lifecycle_id="", start_auth=START_CONFIRMED_TERMINAL,
                        started="2026-07-16T01:03:00Z", finished="2026-07-16T01:04:00Z")
        rel, _conf = vb._classify_relationship([a, b])
        self.assertNotEqual(rel, REL_CANDIDATE_TRANSPORT_RETRY)
        # Assert the exact resulting class, not just the negative (conv-shadow
        # weak-assertion note): a no-explicit-lifecycle group is unclassifiable.
        self.assertEqual(rel, REL_UNCLASSIFIABLE)

    # --- Shadow Medium: read_cloud_census must verify snapshot_hash. ----------
    def _write_snapshot(self, rows, tamper: bool = False) -> Path:
        import hashlib as _h
        payload = json.dumps(rows, sort_keys=True, separators=(",", ":")).encode("utf-8")
        h = _h.sha256(payload).hexdigest()
        if tamper:
            rows = rows + [{"workflow_file": "x", "job": "y", "run_id": 9, "run_attempt": 1,
                            "started_at": None, "status": "completed", "conclusion": "success"}]
        snap = {"schema_version": 1, "snapshot_hash": h, "query_time": "t",
                "pagination_complete": True, "repository": "o/r", "rows": rows}
        p = Path(self.out) / "snap.json"
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(snap), encoding="utf-8")
        return p

    def test_read_cloud_census_rejects_tampered_rows(self) -> None:
        p = self._write_snapshot([{"workflow_file": "a", "job": "b", "run_id": 1, "run_attempt": 1,
                                   "started_at": None, "status": "completed", "conclusion": "success"}], tamper=True)
        doc, reason = vb.read_cloud_census(p)
        self.assertIsNone(doc)
        self.assertIn("hash", reason.lower())

    def test_read_cloud_census_accepts_intact_rows(self) -> None:
        p = self._write_snapshot([{"workflow_file": "a", "job": "b", "run_id": 1, "run_attempt": 1,
                                   "started_at": None, "status": "completed", "conclusion": "success"}])
        doc, reason = vb.read_cloud_census(p)
        self.assertIsNotNone(doc)
        self.assertEqual(reason, "ok")

    def test_read_cloud_census_rows_present_but_hash_absent_fails_closed(self) -> None:
        # A rows-present snapshot whose snapshot_hash was stripped (or set
        # non-string) is integrity-UNVERIFIABLE: the guard's comparand is absent,
        # so it must fail CLOSED (unavailable), never return "ok" on unverified
        # rows (convergence-shadow: the absent-comparand fail-open in the
        # iteration-2 hash check).
        rows = [{"workflow_file": "a", "job": "b", "run_id": 1, "run_attempt": 1,
                 "started_at": None, "status": "completed", "conclusion": "success"}]
        for bad_hash in (None, 123, [], {}):  # missing (None-drop below), or non-string
            snap = {"schema_version": 1, "query_time": "t", "pagination_complete": True,
                    "repository": "o/r", "rows": rows}
            if bad_hash is not None:
                snap["snapshot_hash"] = bad_hash
            p = Path(self.out) / "snap-nohash.json"
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(json.dumps(snap), encoding="utf-8")
            doc, reason = vb.read_cloud_census(p)
            self.assertIsNone(doc, f"bad_hash={bad_hash!r} must fail closed")
            self.assertIn("hash", reason.lower())

    # --- Shadow Medium: an all-malformed-rows census is unavailable, breadcrumbed. -
    def test_all_malformed_rows_census_is_unavailable(self) -> None:
        snapshot = {"schema_version": 1, "snapshot_hash": "h", "query_time": "t",
                    "pagination_complete": True, "repository": "o/r",
                    "rows": ["not-a-dict", 123, None]}
        import io as _io
        buf = _io.StringIO()
        with contextlib.redirect_stderr(buf):
            rows, cov = vb.build_cloud_census(snapshot, {})
        self.assertTrue(cov["unavailable"])
        self.assertEqual(cov.get("malformed_row_count"), 3)
        self.assertIn("malformed", buf.getvalue().lower())

    def test_partly_malformed_rows_census_stays_available_with_count(self) -> None:
        cm = load_cloud_mappings(REGISTRY)
        snapshot = {"schema_version": 1, "snapshot_hash": "h", "query_time": "t",
                    "pagination_complete": True, "repository": "o/r",
                    "rows": ["bad", {"workflow_file": ".github/workflows/devflow-implement.yml",
                                     "job": "claude", "run_id": 1, "run_attempt": 1,
                                     "started_at": "2026-07-16T01:00:00Z", "status": "completed",
                                     "conclusion": "success"}]}
        rows, cov = vb.build_cloud_census(snapshot, cm)
        self.assertFalse(cov["unavailable"])
        self.assertEqual(cov.get("malformed_row_count"), 1)
        self.assertEqual(len(rows), 1)

    # --- Shadow Medium: a partially-corrupt stop-attempts log fails closed on
    #     the consistency-check (empty-transcript) arm. -----------------------
    def test_partial_corrupt_stop_attempts_beside_empty_transcript_fails_closed(self) -> None:
        write_manifest(self.manifests, "s-pc")
        d = self.bundles / "s-pc"
        d.mkdir(parents=True, exist_ok=True)
        (d / "metadata.json").write_text(json.dumps({"schema_version": 2}), encoding="utf-8")
        (d / "transcript.jsonl").write_bytes(b"")
        (d / "stop-attempts.jsonl").write_text(
            json.dumps({"result": "captured", "transcript_bytes": 0}) + "\n{corrupt line\n", encoding="utf-8")
        rows = build_local_census(self.manifests, wfr.load_registry(REGISTRY))
        rows = vb.join_local_imports(rows, self.bundles, 64 * 1024 * 1024)
        self.assertEqual(rows[0].source_status, SOURCE_IMPORT_FAILED)

    # --- Shadow documented_falsehood: manual_review.json carries the TTL fields. -
    def test_manual_review_artifact_carries_ttl_fields(self) -> None:
        write_manifest(self.manifests, "s1")
        write_bundle(self.bundles, "s1", transcript(user("/devflow:implement 527")))
        main(["--manifests-dir", str(self.manifests), "--bundles-dir", str(self.bundles),
              "--registry", str(REGISTRY), "--out-dir", str(self.out)])
        run = sorted(self.out.iterdir())[-1]
        mr = json.loads((run / "manual_review.json").read_text(encoding="utf-8"))
        for field in ("created_at", "source_snapshot_hash", "expires_at"):
            self.assertIn(field, mr, f"manual_review.json missing {field}")

    # --- Shadow Medium: exporter drops corrupt/id-less runs, folds into
    #     pagination_complete, and counts them (not silently omitted). --------
    def test_exporter_drops_corrupt_runs_and_marks_incomplete(self) -> None:
        exp = _load_export_census()
        runs = ["not-a-dict", {"path": "wf", "run_attempt": 1},  # id-less
                {"id": 7, "path": "wf", "name": "W", "run_attempt": 1,
                 "created_at": "c", "conclusion": "success", "status": "completed"}]
        jobs = {7: [{"name": "job", "started_at": "s", "completed_at": "e",
                     "conclusion": "success", "status": "completed"}]}
        import io as _io
        buf = _io.StringIO()
        with contextlib.redirect_stderr(buf):
            snap = exp.build_snapshot("o/r", ["wf"], "a", "b", runs, jobs, "t", True)
        self.assertFalse(snap["pagination_complete"])  # dropped runs => not complete
        self.assertEqual(snap["dropped_run_count"], 2)
        self.assertEqual(snap["row_count"], 1)
        self.assertIn("dropped", buf.getvalue().lower())


class Pr531ReviewAndFixIter1Tests(_TmpDirTestCase):
    """Iteration-1 findings of the /devflow:review-and-fix run on PR #531."""

    # --- Phase-2 VC-6 FAIL: a backslash-escaped space is not a word boundary in
    #     shell, but the bare-char alternative of _SECRET_VALUE stops at it, so
    #     the secret's tail survived in redacted_display AND in the digest while
    #     secret_affected=True falsely asserted redaction was complete. Same
    #     recall class as the quoted-value (iter-1) and URL-password fixes, in
    #     the escaped-value shape; fixed as a class, not per cited instance. ----
    def test_escaped_whitespace_secret_value_fully_redacted(self) -> None:
        for command, leaks in (
            (r"TOKEN=sec\ ret pytest", ("ret",)),
            (r"API_KEY=my\ secret\ value pytest", ("secret", "value")),
            (r"mytool --api-key my\ secret\ value", ("secret", "value")),
            (r"curl -u user:pa\ ss https://example.invalid/", ("ss",)),
            (r'TOKEN="a\"b c" pytest', ("c",)),  # escaped quote inside dquotes
            # The URL and Bearer classes belong in this matrix — this test's own
            # header names the URL-password fix as the precedent for fixing "the
            # whole class", yet no row exercised it, so SECRET_URL stayed
            # escape-blind through four rounds of fixing its siblings and leaked
            # the WHOLE credential with secret_affected=False (worse than the
            # others: it also skipped the secret-affected carve-outs). The
            # untested sibling is the one that regressed.
            (r"curl https://user:pa\ ss@host/x", ("ss",)),
            (r"curl https://us\ er:pass@host/x", ("pass",)),
            (r"curl -H 'Authorization: Bearer ab\ cd' https://host/", ("cd",)),
        ):
            with self.subTest(command=command):
                b = vb._binding_identity(command)
                self.assertTrue(b.secret_affected,
                                f"secret_affected False for {command!r} — the leak would also "
                                "skip the secret-affected carve-outs")
                # Strip EVERY slot spelling, not just env/flag: a strip that
                # misses <url-cred>/<bearer> would let their own placeholder text
                # satisfy the assertion and hide a real leak.
                stripped = re.sub(r"<(env|flag):[^>]*>|<url-cred>|<bearer>", "", b.redacted_display)
                for leak in leaks:
                    self.assertNotIn(leak, stripped,
                                     f"secret fragment {leak!r} survived in {b.redacted_display!r}")

    # --- Blinded fix-delta gate: the FIRST attempt at the escape fix routed the
    #     halves alternative of SECRET_SHORT_U through the new escape-aware
    #     chunks but left its two WHOLE-OPERAND-quoted siblings, one line away,
    #     on the old escape-blind classes — so `-u "user:pa\"ss"` still leaked
    #     the tail into redacted_display AND the digest with secret_affected
    #     True, falsifying the very "fixed for the whole class" claim. The
    #     original test only drove the unquoted `-u` shape, so the gap shipped
    #     un-pinned; this is that missing pin. ---------------------------------
    def test_short_u_quoted_operand_with_escapes_fully_redacted(self) -> None:
        for command, leak in (
            (r'curl -u "user:pa\"ss" rest', "ss"),      # escaped quote inside dquotes
            (r"curl -u 'user:pa\'ss' rest", "ss"),      # POSIX adjacent concatenation
            (r'curl -u "user:pa\ ss" rest', "ss"),      # escaped space inside dquotes
            (r'curl -u "us\"er:pass" rest', "pass"),    # escape in the USER half
        ):
            with self.subTest(command=command):
                b = vb._binding_identity(command)
                self.assertTrue(b.secret_affected)
                self.assertIn("flag:u", b.secret_slots)
                stripped = b.redacted_display.replace("<flag:u>", "")
                self.assertNotIn(leak, stripped,
                                 f"secret fragment {leak!r} survived in {b.redacted_display!r}")

    def test_short_u_quoted_operand_negative_controls(self) -> None:
        # Positive controls for the guard above: it must not over-fire. A bare
        # `sort -u` with a colon-free operand is not a credential, and the
        # already-covered plain quoted spellings must still redact whole.
        self.assertFalse(vb._binding_identity("sort -u lib/test/run.sh").secret_affected)
        for command in ('curl -u "user:pass" https://example.invalid/',
                        "curl -u 'user:pass' https://example.invalid/",
                        'curl -u"user:pass" https://example.invalid/'):
            with self.subTest(command=command):
                b = vb._binding_identity(command)
                self.assertTrue(b.secret_affected)
                self.assertNotIn("pass", b.redacted_display.replace("<flag:u>", ""))

    # --- Convergence shadow, Critical: SECRET_ENV_ASSIGNMENT carries a trailing
    #     `S?` precisely so plural/compound names (API_KEYS=, GITHUB_TOKENS=,
    #     SECRETS=) stay covered — a fix an earlier iteration made after
    #     suffix-anchoring dropped them. Its sibling SECRET_FLAG never got the
    #     same admission, so `--tokens`/`--api-keys`/`--secrets`/`--credentials`
    #     did not fire at all: the raw value reached redacted_display AND the
    #     digest with secret_affected=False, which additionally skips the
    #     secret-affected carve-outs in join_confidence/_classify_relationship,
    #     so a credential-bearing binding was treated as a clean `exact` match.
    #     The same class fix, one sibling regex over. -------------------------
    def test_plural_flag_secrets_are_redacted(self) -> None:
        for command, leak in (
            ("mytool --tokens abc123def", "abc123def"),
            ("mytool --api-keys sk-xyz789", "sk-xyz789"),
            ("tool --secrets hunter2", "hunter2"),
            ("tool --credentials pw1", "pw1"),
            ("tool --passwords pw2", "pw2"),
            ("tool --auth-tokens tok3", "tok3"),
        ):
            with self.subTest(command=command):
                b = vb._binding_identity(command)
                self.assertTrue(b.secret_affected,
                                f"secret_affected False for {command!r} — the leak also skips "
                                "the secret-affected carve-outs")
                self.assertNotIn(leak, b.redacted_display,
                                 f"secret {leak!r} survived in {b.redacted_display!r}")

    def test_singular_flag_secrets_still_redacted_and_no_false_positives(self) -> None:
        # Positive controls: the plural admission must not break the singular
        # forms, nor start firing on ordinary non-secret flags.
        for command, leak in (("mytool --token abc123def", "abc123def"),
                              ("mytool --api-key sk-xyz789", "sk-xyz789")):
            with self.subTest(command=command):
                b = vb._binding_identity(command)
                self.assertTrue(b.secret_affected)
                self.assertNotIn(leak, b.redacted_display)
        for command in ("grep --pattern foo lib/", "tool --keystore /etc/ks",
                        "lib/test/run.sh", "pytest -k tokens"):
            with self.subTest(command=command):
                self.assertFalse(vb._binding_identity(command).secret_affected,
                                 f"false positive on {command!r}")

    def test_escaped_value_redaction_is_not_redos_prone(self) -> None:
        # The escape alternative must not re-admit the backtracking pair the
        # quote-exclusion closed: a backslash is consumable by exactly ONE
        # alternative, so a backslash-dense operand stays linear.
        for payload in ("TOKEN=" + "\\" * 4000, "curl -u " + "\\" * 4000,
                        "TOKEN=" + '\\"' * 2000):
            with self.subTest(payload=payload[:16]):
                start = time.monotonic()
                vb._redact_secrets(payload)
                self.assertLess(time.monotonic() - start, 1.0)

    # --- code-reviewer Critical: build_snapshot's malformed-run guard is
    #     UNREACHABLE from the real fetch path. With --workflows set the
    #     comprehension discarded the non-dict uncounted (dropped_runs stayed 0,
    #     so the snapshot self-certified complete on a shrunk denominator); with
    #     it empty the non-dict reached run.get("id") and raised AttributeError.
    #     The existing exporter test called build_snapshot directly, bypassing
    #     exactly the layer that swallowed it. -----------------------------------
    def _fetch_with_page(self, page_runs: list) -> tuple:
        exp = _load_export_census()
        calls = {"n": 0}

        def fake_gh_json(gh, args):
            calls["n"] += 1
            if "jobs" in " ".join(args):
                return {"jobs": [], "total_count": 0}
            return {"workflow_runs": page_runs} if calls["n"] == 1 else {"workflow_runs": []}

        exp._gh_json = fake_gh_json
        return exp, exp.fetch_runs_and_jobs("gh", "o/r", ["wf.yml"], "a", "b")

    def test_fetch_layer_does_not_silently_discard_malformed_run(self) -> None:
        good = {"id": 7, "path": "wf.yml", "name": "W", "run_attempt": 1,
                "created_at": "c", "conclusion": "success", "status": "completed"}
        exp, (runs, jobs, complete) = self._fetch_with_page(["not-a-dict", good])
        # The malformed row must reach build_snapshot so its counting guard runs.
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            snap = exp.build_snapshot("o/r", ["wf.yml"], "a", "b", runs, jobs, "t", complete)
        self.assertEqual(snap["dropped_run_count"], 1,
                         "malformed run was discarded uncounted before build_snapshot")
        self.assertFalse(snap["pagination_complete"],
                         "shape-drifted census self-certified complete")

    def test_fetch_layer_survives_malformed_run_without_workflow_filter(self) -> None:
        # The `else list(page_runs)` branch passed the non-dict to run.get("id").
        exp = _load_export_census()
        calls = {"n": 0}

        def fake_gh_json(gh, args):
            calls["n"] += 1
            if "jobs" in " ".join(args):
                return {"jobs": [], "total_count": 0}
            return {"workflow_runs": ["not-a-dict"]} if calls["n"] == 1 else {"workflow_runs": []}

        exp._gh_json = fake_gh_json
        runs, jobs, complete = exp.fetch_runs_and_jobs("gh", "o/r", [], "a", "b")
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            snap = exp.build_snapshot("o/r", [], "a", "b", runs, jobs, "t", complete)
        self.assertEqual(snap["dropped_run_count"], 1)
        self.assertFalse(snap["pagination_complete"])

    # --- Shadow (pr-test-analyzer): AC #527-2 ("launches no verification
    #     command and invokes no repository-provided executable") was pinned
    #     only TEXTUALLY — two run.sh grep counts over the module's source.
    #     Those catch the realistic regression (a developer reintroducing
    #     `subprocess.run`) but are blind to any spelling they do not enumerate,
    #     including dynamic construction: appending
    #     `importlib.import_module("subpro"+"cess")` leaves BOTH pins reading 0.
    #     A guarantee about what the code DOES should be proven by what it does,
    #     so this drives the real entry point with every process-spawning
    #     primitive tripwired. This is the behavioral half the grep pins cannot
    #     give; they stay as the cheap desk-speed backstop. -------------------
    def test_analyzer_spawns_no_process_end_to_end(self) -> None:
        import multiprocessing
        import subprocess as _sp

        write_manifest(self.manifests, "s-offline")
        # bash_call is (command, tool_use_id) — passing them swapped made the
        # fixture's command the literal "t1", so the run extracted 0 launches and
        # this test drove a near-empty path while its comment claimed to cover
        # launch extraction. A negative assertion over code that never runs is
        # the vacuity this test exists to avoid, so the fixture must actually
        # reach the analyzer's real work (asserted below).
        write_bundle(self.bundles, "s-offline",
                     transcript(user("/devflow:implement #1"),
                                bash_call("pytest tests/", "t1"),
                                tool_result("t1", "exit code 0")))
        spawned: list[str] = []

        def tripwire(name):
            def _boom(*a, **k):
                spawned.append(name)
                raise AssertionError(f"analyzer spawned a process via {name}: {a!r}")
            return _boom

        # The process-spawning primitives reachable through the stdlib module
        # objects, which is strictly more than the spelled-out forms the grep
        # pins enumerate. Patched on the MODULES, so a dynamically-imported
        # reference (importlib.import_module("subpro"+"cess") returns this same
        # module object) is tripwired too — exactly the evasion the textual pins
        # cannot see. NOT exhaustive, and deliberately not claimed to be: a
        # ctypes-mediated direct libc system()/execve() bypasses every module
        # object and so is out of this mechanism's reach. The claim this test
        # supports is "no spawn through the stdlib process APIs", not "no spawn
        # by any means" — overclaiming here would be the same documented
        # falsehood the engine grades elsewhere in this diff.
        targets = [
            (_sp, "run"), (_sp, "Popen"), (_sp, "call"), (_sp, "check_call"),
            (_sp, "check_output"), (_sp, "getoutput"),
            (os, "system"), (os, "popen"), (os, "execv"), (os, "execve"),
            (os, "execvp"), (os, "execvpe"), (os, "posix_spawn"),
            (os, "posix_spawnp"), (os, "fork"), (os, "forkpty"),
            (multiprocessing, "Process"),
        ]
        with contextlib.ExitStack() as stack:
            for mod, attr in targets:
                if hasattr(mod, attr):
                    stack.enter_context(
                        mock.patch.object(mod, attr, tripwire(f"{mod.__name__}.{attr}")))
            out = Path(self.tmp) / "offline-out"
            rc = main(["--manifests", str(self.manifests), "--bundles", str(self.bundles),
                       "--registry", str(REGISTRY), "--out-dir", str(out)])
        self.assertEqual(rc, 0)
        self.assertEqual(spawned, [], f"analyzer spawned process(es): {spawned}")
        # Positive control: prove the run actually did the analyzer's work
        # rather than passing because it never reached the code that could
        # spawn. Without this a fixture regression (a mis-built transcript, a
        # renamed key) silently degrades the test to a near-no-op that still
        # reports a clean "no spawn" — the exact vacuity a negative assertion
        # over an unexercised path produces.
        run_dir = sorted(out.iterdir())[-1]
        baseline = json.loads((run_dir / "verification_baseline.json").read_text(encoding="utf-8"))
        self.assertEqual(baseline["metrics"]["local_actual_launches"], 1,
                         "fixture did not reach launch extraction — the no-spawn assertion would be vacuous")
        self.assertTrue(baseline["verification_process_launches"],
                        "no launches extracted; the spawn-free path under test was not exercised")

    # --- Shadow Important: the owning-lifecycle eligibility state is the value
    #     the VC-2 fix exists to make visible, but it was smuggled through the
    #     untyped `provenance` bag with a silent `or "unrecorded"` fallback on
    #     read — so a future call site that forgot it, or a renamed key, would
    #     degrade silently into the same bucket as a genuine omission. Every
    #     other taxonomy value on this class is _require_member-validated at
    #     construction; this one asserted its invariant in prose only. --------
    def test_owning_lifecycle_eligibility_state_is_a_validated_field(self) -> None:
        a, _b = candidate_pair()
        self.assertIn(a.owning_lifecycle_eligibility_state, vb.ELIGIBILITY_STATES)
        # An invalid value is a loud ValueError at the producer, not a silent row.
        with self.assertRaises(ValueError):
            dataclasses.replace(a, owning_lifecycle_eligibility_state="typo_state")
        # It reaches the serialized output (the surface a reader consumes).
        self.assertIn("owning_lifecycle_eligibility_state", a.to_dict())

    # --- Shadow Important: main() reported the FETCH-level pagination_complete
    #     local, not the value build_snapshot recorded (which folds in dropped
    #     rows). So a dropped-row census printed "pagination_complete=True" while
    #     the artifact it had just written said false, and the "the operator must
    #     see it" warning never fired — the loud-degradation contract left
    #     half-closed at the reporting boundary. ------------------------------
    def test_export_main_reports_the_recorded_completeness_not_the_fetch_local(self) -> None:
        exp = _load_export_census()
        calls = {"n": 0}

        def fake_gh_json(gh, args):
            calls["n"] += 1
            if "jobs" in " ".join(args):
                return {"jobs": [], "total_count": 0}
            if calls["n"] == 1:
                return {"workflow_runs": ["not-a-dict", {
                    "id": 7, "path": "wf.yml", "name": "W", "run_attempt": 1,
                    "created_at": "c", "conclusion": "success", "status": "completed"}]}
            return {"workflow_runs": []}

        exp._gh_json = fake_gh_json
        out = Path(self.tmp) / "snap.json"
        err, sout = io.StringIO(), io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(sout):
            rc = exp.main(["--repo", "o/r", "--workflows", "wf.yml",
                           "--created-after", "a", "--created-before", "b",
                           "--out", str(out)])
        self.assertEqual(rc, 0)
        recorded = json.loads(out.read_text(encoding="utf-8"))["pagination_complete"]
        self.assertFalse(recorded, "the artifact must record the dropped row as incomplete")
        self.assertNotIn("pagination_complete=True", sout.getvalue(),
                         "stdout contradicted the artifact it just wrote")
        self.assertIn("WARNING", err.getvalue(),
                      "dropped-row degradation was silent — the operator must see it")

    # --- Convergence shadow, Important: `id` was null-checked but never
    #     shape-checked, and it is used as a dict key (jobs_by_run). A
    #     shape-drifted non-scalar id is unhashable, so it raised TypeError out
    #     of fetch_runs_and_jobs and killed the whole export with NO snapshot
    #     written — the "incomplete snapshot reads unavailable, never zero"
    #     contract never got the chance to apply. Same failure class as the
    #     non-dict guard one branch over; shape drift is this file's declared
    #     threat model, so a non-scalar id sits inside it. ---------------------
    def test_boolean_run_id_does_not_collide_with_a_real_run(self) -> None:
        # bool is an int subclass and True == 1 hashes identically, so a
        # shape-drifted `"id": true` row passed a bare isinstance(id,(int,str))
        # check and then OVERWROTE the jobs of the genuine run whose id is 1 —
        # misattributing jobs between two runs instead of being counted as
        # malformed. Drive the real fetch layer so the collision would actually
        # occur (both rows must reach jobs_by_run).
        exp = _load_export_census()
        calls = {"n": 0}

        def fake_gh_json(gh, args):
            calls["n"] += 1
            if "jobs" in " ".join(args):
                return {"jobs": [{"name": "job-of-run-1", "started_at": "s",
                                  "completed_at": "e", "conclusion": "success",
                                  "status": "completed"}], "total_count": 1}
            if calls["n"] == 1:
                return {"workflow_runs": [
                    {"id": True, "path": "wf.yml"},            # drifted
                    {"id": 1, "path": "wf.yml", "name": "W", "run_attempt": 1,
                     "created_at": "c", "conclusion": "success", "status": "completed"}]}
            return {"workflow_runs": []}

        exp._gh_json = fake_gh_json
        runs, jobs, complete = exp.fetch_runs_and_jobs("gh", "o/r", ["wf.yml"], "a", "b")
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            snap = exp.build_snapshot("o/r", ["wf.yml"], "a", "b", runs, jobs, "t", complete)
        self.assertEqual(snap["dropped_run_count"], 1,
                         "a boolean id must be counted malformed, not accepted as a key")
        self.assertFalse(snap["pagination_complete"])
        # The genuine run id 1 must keep its own job, un-clobbered.
        self.assertEqual(snap["row_count"], 1)
        self.assertEqual(snap["rows"][0]["run_id"], 1)
        self.assertEqual(snap["rows"][0]["job"], "job-of-run-1")

    def test_non_scalar_run_id_is_counted_not_fatal(self) -> None:
        for bad_id in ({"node_id": "x"}, ["list"], {"a": 1}):
            with self.subTest(bad_id=bad_id):
                exp = _load_export_census()
                calls = {"n": 0}

                def fake_gh_json(gh, args, _b=bad_id):
                    calls["n"] += 1
                    if "jobs" in " ".join(args):
                        # A real job, so the GOOD run actually yields a census row
                        # (rows are per-job) — otherwise "the good row survives"
                        # would assert nothing.
                        return {"jobs": [{"name": "job", "started_at": "s",
                                          "completed_at": "e", "conclusion": "success",
                                          "status": "completed"}], "total_count": 1}
                    if calls["n"] == 1:
                        return {"workflow_runs": [
                            {"id": _b, "path": "wf.yml"},
                            {"id": 7, "path": "wf.yml", "name": "W", "run_attempt": 1,
                             "created_at": "c", "conclusion": "success", "status": "completed"}]}
                    return {"workflow_runs": []}

                exp._gh_json = fake_gh_json
                # Must not raise: the export surviving is the whole point.
                runs, jobs, complete = exp.fetch_runs_and_jobs("gh", "o/r", ["wf.yml"], "a", "b")
                buf = io.StringIO()
                with contextlib.redirect_stderr(buf):
                    snap = exp.build_snapshot("o/r", ["wf.yml"], "a", "b", runs, jobs, "t", complete)
                self.assertEqual(snap["dropped_run_count"], 1,
                                 "the shape-drifted row must be counted, not silently dropped")
                self.assertFalse(snap["pagination_complete"],
                                 "a dropped row must make the census read unavailable")
                self.assertEqual(snap["row_count"], 1, "the good row must still be censused")

    # --- Shadow (pr-test-analyzer): two fetch-layer branches were undriven.
    #     Both decide `pagination_complete`, which is the operand the analyzer
    #     reads as "cloud coverage unavailable, never zero" — an untested branch
    #     here is an untested arm of that whole contract. ---------------------
    def test_first_runs_page_transport_failure_marks_incomplete(self) -> None:
        # Only a JOBS-page failure was covered; a failure on the FIRST runs page
        # (gh down / non-dict response) was never exercised.
        for bad in (None, "not-a-dict", {"workflow_runs": "not-a-list"}):
            with self.subTest(bad=bad):
                exp = _load_export_census()
                exp._gh_json = lambda gh, args, _b=bad: _b
                runs, jobs, complete = exp.fetch_runs_and_jobs("gh", "o/r", ["wf.yml"], "a", "b")
                self.assertFalse(complete, "a first-page transport failure must mark the census incomplete")
                self.assertEqual(runs, [])

    def test_runs_pagination_hard_cap_marks_incomplete(self) -> None:
        # The `page > 200` hard cap flips pagination_complete to False. Undriven,
        # so a cap that silently returned a partial census as complete would not
        # have been caught. Every page is full (== per_page) so the loop never
        # breaks on a short page and must terminate on the cap alone.
        exp = _load_export_census()
        full_page = [{"id": i, "path": "wf.yml", "name": "W", "run_attempt": 1,
                      "created_at": "c", "conclusion": "success", "status": "completed"}
                     for i in range(100)]
        calls = {"n": 0}

        def fake_gh_json(gh, args):
            if "jobs" in " ".join(args):
                return {"jobs": [], "total_count": 0}
            calls["n"] += 1
            return {"workflow_runs": full_page}

        exp._gh_json = fake_gh_json
        runs, jobs, complete = exp.fetch_runs_and_jobs("gh", "o/r", ["wf.yml"], "a", "b")
        self.assertFalse(complete, "the page>200 hard cap must mark the census incomplete")
        self.assertLessEqual(calls["n"], 201, "the hard cap must bound the runs loop")

    # --- Phase-2 VC-33 FAIL: consumer_approximate is dropped by its only
    #     reader, so a stratifier cannot tell devflow.yml's multiplexed
    #     `command` attribution from an exact one — the registry comment
    #     instructs downstream not to treat it as exact, but nothing carries it.
    def test_consumer_approximate_is_carried_by_its_reader(self) -> None:
        table = vb.load_cloud_mappings(REGISTRY)
        key = ".github/workflows/devflow.yml\x1fcommand"
        self.assertIn(key, table)
        self.assertTrue(table[key].get("consumer_approximate"),
                        "consumer_approximate dropped by load_cloud_mappings")
        exact = table[".github/workflows/devflow-implement.yml\x1fclaude"]
        self.assertFalse(exact.get("consumer_approximate"))

    # --- code-reviewer Important: `eligible_lifecycles` counted EVERY census
    #     row, confirmed-ineligible included, under a name asserting otherwise.
    def _rows(self, states: list[str]) -> list:
        return [
            vb.EligibleLifecycle(
                source=vb.SOURCE_LOCAL, surrogate_id=f"s{i}", consumer=None, subject=None,
                identity={"session_id": f"s{i}"}, eligibility_state=state,
                eligibility_evidence="test", host_profile=None,
                source_status=vb.SOURCE_MISSING, provenance={},
            )
            for i, state in enumerate(states)
        ]

    def test_eligible_lifecycles_excludes_confirmed_ineligible(self) -> None:
        rows = self._rows([vb.ELIGIBILITY_CONFIRMED, vb.ELIGIBILITY_INELIGIBLE,
                           vb.ELIGIBILITY_INELIGIBLE, vb.ELIGIBILITY_PROVISIONAL])
        m = vb.compute_metrics(rows, [], [], [], has_cloud_snapshot=False,
                               cloud_attempted=False, cloud_unavailable=False)
        self.assertEqual(m["census_rows"], 4, "census_rows must carry the full row total")
        self.assertEqual(m["eligible_lifecycles"], 2,
                         "eligible_lifecycles must count confirmed+provisional, not every row")
        # The full per-state split stays published — nothing is hidden by the split.
        self.assertEqual(m["eligibility_state_bounds"][vb.ELIGIBILITY_INELIGIBLE], 2)

    # --- Park-calibration gate (the shadow re-raised a finding iteration 1 had
    #     parked, so it was mis-graded): EligibleLifecycle is deliberately NOT
    #     frozen — the left-join contract mutates source_status in place — but
    #     __post_init__ runs ONCE, so the class's own documented guarantee ("an
    #     invalid enum value is a loud ValueError at the producer, not a silent
    #     stringly-typed row that degrades downstream tallies") held only for the
    #     row's first millisecond. The six in-place assignment sites bypassed the
    #     check entirely, so a typo'd or cloud-only status assigned onto a local
    #     row would sail through — the invariant asserted in prose, unenforced
    #     across the lifetime it actually matters for. -------------------------
    def test_source_status_mutation_is_revalidated(self) -> None:
        row = vb.EligibleLifecycle(
            source=vb.SOURCE_LOCAL, surrogate_id="s0", consumer=None, subject=None,
            identity={"session_id": "s0"}, eligibility_state=vb.ELIGIBILITY_CONFIRMED,
            eligibility_evidence="test", host_profile=None,
            source_status=vb.SOURCE_ELIGIBLE_NOT_IMPORTED, provenance={},
        )
        # A valid in-set transition still works (the join contract is preserved).
        row.set_source_status(vb.SOURCE_AVAILABLE)
        self.assertEqual(row.source_status, vb.SOURCE_AVAILABLE)
        # A typo is a loud ValueError at the producer, not a silent row.
        with self.assertRaises(ValueError):
            row.set_source_status("sorce_avilable")
        # A CLOUD-only status on a LOCAL row is the cross-field invariant
        # __post_init__ enforces at construction; it must hold on mutation too.
        with self.assertRaises(ValueError):
            row.set_source_status(vb.SOURCE_UNAVAILABLE)
        self.assertEqual(row.source_status, vb.SOURCE_AVAILABLE,
                         "a rejected mutation must leave the row unchanged")
        # __setattr__ enforcement (PR #531 standalone review, type-design
        # suggestion 2): the field is publicly assignable, so the invariant held
        # only by the convention that every site calls set_source_status. A
        # DIRECT assignment must be validated identically — by construction,
        # not convention.
        with self.assertRaises(ValueError):
            row.source_status = "sorce_avilable"
        with self.assertRaises(ValueError):
            row.source_status = vb.SOURCE_UNAVAILABLE  # cloud-only on a local row
        self.assertEqual(row.source_status, vb.SOURCE_AVAILABLE,
                         "a rejected direct assignment must leave the row unchanged")
        row.source_status = vb.SOURCE_MISSING  # a valid direct assignment still works
        self.assertEqual(row.source_status, vb.SOURCE_MISSING)

    # --- Final convergence shadow, LIVE: build_local_census returned [] with no
    #     breadcrumb when the manifests dir was absent. It is the sole producer
    #     of the entire local denominator, so a typo'd --manifests-dir, a stale
    #     path, or a wrong cwd produced census_rows: 0 / eligible_lifecycles: 0
    #     and exit 0 — a report reading exactly like "we measured a genuinely
    #     empty corpus". That is this module's own "unknown is not zero" contract
    #     broken at the one place it matters most, and the one degradation in the
    #     file left completely silent while every sibling breadcrumbs. --------
    def test_absent_manifests_dir_is_announced_not_silently_empty(self) -> None:
        registry = wfr.load_registry(REGISTRY)
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            rows = build_local_census(Path(self.tmp) / "typo-does-not-exist", registry)
        self.assertEqual(rows, [])
        err = buf.getvalue()
        self.assertIn("typo-does-not-exist", err,
                      "an absent manifests dir must name itself — a silent empty census is "
                      "indistinguishable from a genuinely empty corpus")
        self.assertTrue(err.strip(), "the sole producer of the local denominator degraded silently")

    def test_manifests_dir_that_is_a_file_is_announced(self) -> None:
        # The .is_dir() arm swallows a file-instead-of-directory misconfiguration
        # into the same silent [] — same contract, different operator mistake.
        not_a_dir = Path(self.tmp) / "manifests-is-a-file"
        not_a_dir.write_text("oops", encoding="utf-8")
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            rows = build_local_census(not_a_dir, wfr.load_registry(REGISTRY))
        self.assertEqual(rows, [])
        self.assertIn("manifests-is-a-file", buf.getvalue())

    def test_present_manifests_dir_stays_quiet(self) -> None:
        # Positive control: a real (even genuinely empty) dir must NOT breadcrumb,
        # or the signal is noise and an operator learns to ignore it.
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            build_local_census(self.manifests, wfr.load_registry(REGISTRY))
        self.assertEqual(buf.getvalue(), "",
                         "a present manifests dir must not warn — a genuinely empty corpus is "
                         "a real measurement, not a degradation")

    def test_baseline_schema_version_moved_with_the_metric_rename(self) -> None:
        # eligible_lifecycles changed MEANING; a reader treating it as the row
        # total would silently mis-read. Not additive => version moves.
        self.assertGreaterEqual(vb.VERIFICATION_BASELINE_SCHEMA, 2)

    # --- Phase-2 VC-4 FAIL: the issue's AC enumerates nine dimensions that
    #     "cannot be classified as transport-retry candidates". Eight are
    #     foreclosed (lifecycle -> independent_lifecycle; command binding ->
    #     structurally, groups are keyed by digest; iterations/checkpoints/
    #     post-fix commits/base merges/human retriggers -> retrigger_evidence;
    #     cloud run attempts -> not applicable in Wave 1). CONSUMER ROLES were
    #     foreclosed by nothing: _classify_relationship never read consumer_skill
    #     at all, so two DIFFERENT consumers running the same command in one
    #     lifecycle classified as candidate_transport_retry. ---------------------
    def test_distinct_consumer_roles_are_never_a_transport_retry_candidate(self) -> None:
        a, b = _candidate_pair_with_consumers("implement", "review")
        rel, conf = vb._classify_relationship([a, b])
        self.assertNotEqual(rel, vb.REL_CANDIDATE_TRANSPORT_RETRY,
                            "distinct consumer roles classified as a transport-retry candidate")

    def test_same_consumer_role_still_reaches_candidate(self) -> None:
        # The positive control: the guard must foreclose ONLY the distinct-role
        # case, not defeat candidate classification wholesale (a guard that
        # rejects everything would pass the test above while asserting nothing).
        a, b = _candidate_pair_with_consumers("implement", "implement")
        rel, _conf = vb._classify_relationship([a, b])
        self.assertEqual(rel, vb.REL_CANDIDATE_TRANSPORT_RETRY,
                         "same-consumer candidate pair no longer classifies as a candidate")

    def test_unrecorded_consumer_role_does_not_foreclose(self) -> None:
        # Wave-1 rows can carry consumer=None; two None roles are not evidence
        # of DISTINCT roles, so they must not silently foreclose the candidate.
        a, b = _candidate_pair_with_consumers(None, None)
        rel, _conf = vb._classify_relationship([a, b])
        self.assertEqual(rel, vb.REL_CANDIDATE_TRANSPORT_RETRY)

class Pr531StandaloneReviewFindingsTests(_TmpDirTestCase):
    """Fixes for PR #531's standalone review verdict (APPROVE with notes)."""

    # --- Important 1: metrics.local_actual_launches_by_lifecycle_eligibility
    #     and the report's ⚠️ ineligible-launch warning were validated only as
    #     a field, never end-to-end — a regression dropping the warning branch
    #     or mis-bucketing the numerator stayed green. Drive the whole pipeline:
    #     an ineligible-but-importable row's launch must land in the ineligible
    #     bucket AND surface the incoherent-numerator warning in report.md. ----
    def test_ineligible_launch_buckets_and_warns_end_to_end(self) -> None:
        write_manifest(self.manifests, "s1", workflow="not-a-real-workflow")
        write_bundle(self.bundles, "s1", transcript(
            user("/devflow:implement 527"),
            bash_call("lib/test/run.sh", "tu"),
            tool_result("tu", "exit code 0")))
        rc = main(["--manifests-dir", str(self.manifests), "--bundles-dir", str(self.bundles),
                   "--registry", str(REGISTRY), "--out-dir", str(self.out)])
        self.assertEqual(rc, 0)
        run = sorted(self.out.iterdir())[-1]
        baseline = json.loads((run / "verification_baseline.json").read_text(encoding="utf-8"))
        by_elig = baseline["metrics"]["local_actual_launches_by_lifecycle_eligibility"]
        self.assertEqual(by_elig[vb.ELIGIBILITY_INELIGIBLE], 1,
                         "the launch's owning row is confirmed_ineligible; it must bucket there")
        self.assertEqual(by_elig[vb.ELIGIBILITY_CONFIRMED], 0)
        self.assertEqual(baseline["metrics"]["eligible_lifecycles"], 0)
        self.assertEqual(baseline["metrics"]["local_actual_launches"], 1)
        report = (run / "report.md").read_text(encoding="utf-8")
        self.assertIn("NOT in the eligible denominator", report,
                      "the incoherent-numerator warning must be readable in the report")
        self.assertIn("non-comparable", report)

    def test_coherent_numerator_report_carries_no_warning(self) -> None:
        # Positive control on the same fixture shape: an ELIGIBLE row's launch
        # buckets confirmed and the warning branch stays silent — so the test
        # above is attributing the warning to the ineligible launch, not to an
        # always-on line.
        write_manifest(self.manifests, "s1")
        write_bundle(self.bundles, "s1", transcript(
            user("/devflow:implement 527"),
            bash_call("lib/test/run.sh", "tu"),
            tool_result("tu", "exit code 0")))
        rc = main(["--manifests-dir", str(self.manifests), "--bundles-dir", str(self.bundles),
                   "--registry", str(REGISTRY), "--out-dir", str(self.out)])
        self.assertEqual(rc, 0)
        run = sorted(self.out.iterdir())[-1]
        baseline = json.loads((run / "verification_baseline.json").read_text(encoding="utf-8"))
        by_elig = baseline["metrics"]["local_actual_launches_by_lifecycle_eligibility"]
        self.assertEqual(by_elig[vb.ELIGIBILITY_CONFIRMED], 1)
        self.assertEqual(by_elig[vb.ELIGIBILITY_INELIGIBLE], 0)
        report = (run / "report.md").read_text(encoding="utf-8")
        self.assertNotIn("NOT in the eligible denominator", report)

    # --- Important 2: manual_review_sample composition (top-duration decile
    #     with inclusive ties, the min(50, max(20, ceil(0.1*remainder))) clamp,
    #     high-cost/remainder disjointness) was unasserted beyond determinism. -
    def _duration_groups(self, durations: "tuple[int, ...]") -> list:
        launches = []
        for i, dur in enumerate(durations):
            for j, auth in enumerate((START_CONFIRMED_RESULT_MISSING, START_CONFIRMED_TERMINAL)):
                la = make_launch(f"m{i}-{j}", lifecycle_id=f"L{i}", binding_digest=f"D{i}", start_auth=auth)
                la.timing["duration_ms"] = dur
                launches.append(la)
        return group_launches(launches)

    def test_manual_review_sample_composition(self) -> None:
        groups = self._duration_groups(tuple((i + 1) * 1000 for i in range(40)))
        self.assertEqual(len(groups), 40)
        s = manual_review_sample(groups, "deadbeef")
        # Top decile: ceil(0.1 * 40) = 4 -> exactly the four longest durations.
        expected_high = {g.group_id for g in groups if g.duration_ms >= 37000}
        self.assertEqual(set(s["high_cost_ids"]), expected_high)
        self.assertEqual(len(s["high_cost_ids"]), 4)
        # Clamp: remainder = 36 -> min(50, max(20, ceil(3.6))) = 20.
        self.assertEqual(len(s["remainder_selected_ids"]), 20)
        # Disjointness + union: selected = high_cost ++ remainder, no overlap.
        self.assertFalse(set(s["high_cost_ids"]) & set(s["remainder_selected_ids"]))
        self.assertEqual(s["selected_ids"], s["high_cost_ids"] + s["remainder_selected_ids"])
        self.assertEqual(len(s["eligible_population"]), 40)

    def test_manual_review_sample_decile_includes_ties(self) -> None:
        # Five groups, three tied at the max duration: decile_count =
        # max(1, ceil(0.5)) = 1, threshold = the max, and ALL THREE tied groups
        # are high-cost (the AC's "top duration decile with inclusive ties"),
        # not just one. The remainder clamp is additionally capped at the
        # remainder population: max(20, ceil(0.2)) = 20 -> min(20, 2) = 2.
        groups = self._duration_groups((9000, 9000, 9000, 2000, 1000))
        s = manual_review_sample(groups, "deadbeef")
        self.assertEqual(len(s["high_cost_ids"]), 3, "inclusive ties: every group at the threshold")
        self.assertEqual(len(s["remainder_selected_ids"]), 2, "clamp capped at len(remainder)")
        self.assertEqual(len(s["selected_ids"]), 5)

    # --- Suggestion 4: SECRET_FLAG's `[ =]` separator mis-parsed space-padded
    #     `=`: `--token = x` consumed the bare `=` AS the value (real secret
    #     leaked with secret_affected=True), and `--token= x` matched nothing
    #     (leaked with secret_affected=False). Fixed for both siblings. --------
    def test_space_padded_flag_secret_separator_redacted(self) -> None:
        for cmd in ("deploy --token = hunter2 lib/test/run.sh",
                    "deploy --token= hunter2 lib/test/run.sh",
                    "deploy --token =hunter2 lib/test/run.sh"):
            b = vb._binding_identity(cmd)
            self.assertTrue(b.secret_affected, cmd)
            self.assertNotIn("hunter2", b.redacted_display, cmd)
            self.assertNotEqual(
                b.digest,
                hashlib.sha256(vb._canonical_command(cmd).encode("utf-8")).hexdigest(),
                f"{cmd}: digest must be of the redacted form")
        # Negative control: a non-secret flag with the same padded shape stays
        # untouched (the segment-boundary anchor still rejects `--pattern`).
        n = vb._binding_identity("grep --pattern = foo lib/test/run.sh")
        self.assertFalse(n.secret_affected)

    # --- Suggestion 1: the baseline envelope now holds the TYPED records until
    #     to_dict() (the write boundary), so the validated-record guarantees
    #     survive up to serialization instead of being erased at construction. -
    def test_baseline_envelope_holds_typed_records(self) -> None:
        write_manifest(self.manifests, "s1")
        write_bundle(self.bundles, "s1", transcript(
            user("/devflow:implement 527"),
            bash_call("lib/test/run.sh", "tu"),
            tool_result("tu", "exit code 0")))
        rc = main(["--manifests-dir", str(self.manifests), "--bundles-dir", str(self.bundles),
                   "--registry", str(REGISTRY), "--out-dir", str(self.out)])
        self.assertEqual(rc, 0)
        # The serialized artifact is unchanged in shape (dicts all the way down).
        run = sorted(self.out.iterdir())[-1]
        baseline = json.loads((run / "verification_baseline.json").read_text(encoding="utf-8"))
        self.assertIsInstance(baseline["verification_process_launches"][0], dict)
        # And the envelope's own contract: to_dict() converts typed records.
        annots = vb.VerificationBaseline.__annotations__
        self.assertEqual(annots["verification_process_launches"], "list[VerificationProcessLaunch]")
        self.assertEqual(annots["relationship_groups"], "list[RelationshipGroup]")


if __name__ == "__main__":
    unittest.main()
