#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Focused tests for the single-flight verification coordination ledger (#528).

Covers the full issue #528 acceptance matrix: concurrent claims -> one owner,
token secrecy/replay, compare-and-swap, atomic publication, owner loss before and
during running, the complete JSON-shape matrix, every declared input drift, an
undeclared / non-hermetic profile, stale ownership, linked worktrees,
subdirectories, descriptor mismatch, wait expiry, skipped checks, failure
propagation, and successful attachment.

The helper is hyphenated (scripts/verification-flight.py) so it is loaded via
importlib.util.spec_from_file_location, the same workaround the hyphenated-script
tests use elsewhere in this suite.
"""

from __future__ import annotations

import importlib.util
import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
_SPEC = importlib.util.spec_from_file_location(
    "verification_flight", ROOT / "scripts" / "verification-flight.py"
)
vf = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(vf)


def _decl(**over):
    profile = {
        "profile_version": 1,
        "argv": ["lib/test/run.sh"],
        "cwd": "/repo",
        "environment": {"CI": "1"},
        "toolchain": {"bash": "5.2"},
        "dependencies": {"jq": "1.7"},
        "output_roots": [".devflow/tmp"],
        "external_services": "none",
    }
    checkout = {
        "checkout_id": "r1",
        "head": "abc",
        "index_digest": "i1",
        "tracked_digest": "t1",
        "untracked_digest": "u1",
    }
    d = {"schema_version": 1, "profile": profile, "checkout": checkout}
    for k, v in over.items():
        if k in ("profile", "checkout"):
            d[k] = {**d[k], **v}
        else:
            d[k] = v
    return d


class Harness(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.state = os.path.join(self.tmp, "state")
        self.logs = os.path.join(self.tmp, "logs")
        # Neutralize any ambient DEVFLOW_FLIGHT_NOW so tests set it explicitly.
        os.environ.pop("DEVFLOW_FLIGHT_NOW", None)

    def tearDown(self):
        os.environ.pop("DEVFLOW_FLIGHT_NOW", None)

    def _write(self, obj) -> str:
        path = os.path.join(self.tmp, f"in-{os.urandom(4).hex()}.json")
        Path(path).write_text(json.dumps(obj), encoding="utf-8")
        return path

    def run_cmd(self, argv):
        """Run the CLI, returning (exit_code, parsed_stdout_or_None)."""
        buf = io.StringIO()
        with redirect_stdout(buf):
            code = vf.main(argv)
        out = buf.getvalue().strip()
        parsed = None
        if out:
            try:
                parsed = json.loads(out.splitlines()[-1])
            except json.JSONDecodeError:
                parsed = None
        return code, parsed

    def claim(self, decl=None, lease=None):
        decl = decl if decl is not None else _decl()
        argv = ["claim", "--input-file", self._write(decl),
                "--state-dir", self.state, "--logs-dir", self.logs]
        if lease is not None:
            argv += ["--lease-seconds", str(lease)]
        return self.run_cmd(argv)


class TestDescriptorAndKey(Harness):
    def test_descriptor_deterministic(self):
        c1, o1 = self.run_cmd(["descriptor", "--input-file", self._write(_decl())])
        c2, o2 = self.run_cmd(["descriptor", "--input-file", self._write(_decl())])
        self.assertEqual(c1, vf.EXIT_OK)
        self.assertEqual(o1["descriptor_digest"], o2["descriptor_digest"])
        self.assertEqual(o1["flight_key"], o2["flight_key"])

    def test_byte_distinct_argv_distinct_descriptor(self):
        _, base = self.run_cmd(["descriptor", "--input-file", self._write(_decl())])
        _, alt = self.run_cmd(["descriptor", "--input-file",
                               self._write(_decl(profile={"argv": ["lib/test/run.sh", "--x"]}))])
        self.assertNotEqual(base["descriptor_digest"], alt["descriptor_digest"])

    def test_checkout_drift_distinct_flight_key_same_descriptor(self):
        _, base = self.run_cmd(["descriptor", "--input-file", self._write(_decl())])
        _, moved = self.run_cmd(["descriptor", "--input-file",
                                 self._write(_decl(checkout={"head": "def"}))])
        self.assertEqual(base["descriptor_digest"], moved["descriptor_digest"])
        self.assertNotEqual(base["flight_key"], moved["flight_key"])

    def test_each_descriptor_operand_shifts_digest(self):
        base = self.run_cmd(["descriptor", "--input-file", self._write(_decl())])[1]["descriptor_digest"]
        for over in (
            {"profile_version": 2},
            {"cwd": "/other"},
            {"environment": {"CI": "2"}},
            {"toolchain": {"bash": "5.3"}},
            {"dependencies": {"jq": "1.8"}},
        ):
            d = self.run_cmd(["descriptor", "--input-file",
                              self._write(_decl(profile=over))])[1]["descriptor_digest"]
            self.assertNotEqual(base, d, f"operand {over} did not change descriptor")


class TestClaimAndAttach(Harness):
    def test_claim_owner_then_attach(self):
        code, owner = self.claim()
        self.assertEqual(code, vf.EXIT_OK)
        self.assertEqual(owner["role"], "owner")
        self.assertEqual(owner["state"], "claimed")
        self.assertIn("token", owner)
        # A matching active flight returns the handle without a second owner.
        code2, att = self.claim()
        self.assertEqual(code2, vf.EXIT_OK)
        self.assertEqual(att["role"], "attacher")
        self.assertNotIn("token", att)
        self.assertEqual(att["flight_key"], owner["flight_key"])

    def test_atomic_single_owner_no_second_token(self):
        _, owner = self.claim()
        # Simulate a concurrent second claim on the same key: O_CREAT|O_EXCL
        # means only the first create wins; the rest attach.
        tokens = set()
        for _ in range(5):
            _, res = self.claim()
            if res.get("role") == "owner":
                tokens.add(res["token"])
        self.assertEqual(tokens, set(), "a second owner token was granted for an active flight")

    def test_token_persisted_only_as_digest(self):
        _, owner = self.claim()
        path = Path(self.state) / f"{owner['flight_key']}.json"
        body = json.loads(path.read_text())
        self.assertNotIn("token", body)
        self.assertEqual(body["token_digest"], vf._sha256(owner["token"].encode()))
        self.assertNotEqual(body["token_digest"], owner["token"])

    def test_status_redacts_token(self):
        _, owner = self.claim()
        _, st = self.run_cmd(["status", "--flight", owner["flight_key"], "--state-dir", self.state])
        self.assertEqual(st["token_digest"], "REDACTED")


class TestDeclarationValidation(Harness):
    def test_non_hermetic_profile_rejected(self):
        code, out = self.claim(_decl(profile={"external_services": "network"}))
        self.assertEqual(code, vf.EXIT_INVALID)
        self.assertEqual(out["reason"], "non_hermetic_profile")

    def test_incomplete_fingerprint_disables_reuse(self):
        code, out = self.claim(_decl(checkout={"head": ""}))
        self.assertEqual(code, vf.EXIT_INVALID)
        self.assertIn("checkout_incomplete_fingerprint", out["reason"])

    def test_missing_profile_field(self):
        d = _decl()
        del d["profile"]["toolchain"]
        code, out = self.claim(d)
        self.assertEqual(code, vf.EXIT_INVALID)
        self.assertEqual(out["reason"], "profile_missing_field:toolchain")

    def test_unknown_schema_version(self):
        code, out = self.claim(_decl(schema_version=999))
        self.assertEqual(code, vf.EXIT_INVALID)
        self.assertEqual(out["reason"], "unknown_schema_version")

    def test_argv_wrong_type(self):
        code, out = self.claim(_decl(profile={"argv": "lib/test/run.sh"}))
        self.assertEqual(code, vf.EXIT_INVALID)
        self.assertEqual(out["reason"], "profile_argv_not_nonempty_list")


class TestCompareAndSwap(Harness):
    def test_mark_running_requires_owner_token(self):
        _, owner = self.claim()
        code, out = self.run_cmd(["mark-running", "--flight", owner["flight_key"],
                                  "--token", "BOGUS", "--state-dir", self.state])
        self.assertEqual(code, vf.EXIT_CAS_REJECT)
        self.assertEqual(out["reason"], "token_mismatch")

    def test_attacher_cannot_mark_running(self):
        _, owner = self.claim()
        self.claim()  # attacher has no token at all
        # An attacher with a fabricated token is rejected.
        code, _ = self.run_cmd(["mark-running", "--flight", owner["flight_key"],
                                "--token", "guessed", "--state-dir", self.state])
        self.assertEqual(code, vf.EXIT_CAS_REJECT)

    def test_replay_mark_running_rejected(self):
        _, owner = self.claim()
        k, t = owner["flight_key"], owner["token"]
        c1, _ = self.run_cmd(["mark-running", "--flight", k, "--token", t, "--state-dir", self.state])
        self.assertEqual(c1, vf.EXIT_OK)
        c2, out = self.run_cmd(["mark-running", "--flight", k, "--token", t, "--state-dir", self.state])
        self.assertEqual(c2, vf.EXIT_CAS_REJECT)
        self.assertIn("not_claimed", out["reason"])

    def test_post_terminal_transition_rejected(self):
        _, owner = self.claim()
        k, t = owner["flight_key"], owner["token"]
        self.run_cmd(["mark-running", "--flight", k, "--token", t, "--state-dir", self.state])
        summ = self._write({"command": "x", "exit_status": 0, "skipped_checks": []})
        self.run_cmd(["finish", "--flight", k, "--token", t, "--result", "passed",
                      "--summary-file", summ, "--state-dir", self.state, "--logs-dir", self.logs])
        # finishing again (or marking running post-terminal) is rejected
        c, out = self.run_cmd(["finish", "--flight", k, "--token", t, "--result", "failed",
                               "--summary-file", summ, "--state-dir", self.state])
        self.assertEqual(c, vf.EXIT_CAS_REJECT)
        self.assertIn("not_running", out["reason"])


class TestOwnerLossBoundaries(Harness):
    def test_lease_expiry_before_running_becomes_incomplete(self):
        os.environ["DEVFLOW_FLIGHT_NOW"] = "1000"
        _, owner = self.claim(lease=10)
        # Advance past the lease boundary between claim and mark-running.
        os.environ["DEVFLOW_FLIGHT_NOW"] = "2000"
        code, out = self.run_cmd(["status", "--flight", owner["flight_key"], "--state-dir", self.state])
        self.assertEqual(out["state"], "incomplete")
        self.assertEqual(code, vf.EXIT_NON_PASS)
        # And mark-running now fails closed rather than reviving the flight.
        c2, _ = self.run_cmd(["mark-running", "--flight", owner["flight_key"],
                              "--token", owner["token"], "--state-dir", self.state])
        self.assertEqual(c2, vf.EXIT_CAS_REJECT)

    def test_owner_loss_during_running_missing_evidence_incomplete(self):
        _, owner = self.claim()
        k, t = owner["flight_key"], owner["token"]
        self.run_cmd(["mark-running", "--flight", k, "--token", t, "--state-dir", self.state])
        # finish a passed result with NO terminal evidence -> incomplete, not pass.
        code, out = self.run_cmd(["finish", "--flight", k, "--token", t,
                                  "--result", "passed", "--state-dir", self.state])
        self.assertEqual(out["result"], "incomplete")
        self.assertEqual(code, vf.EXIT_CAS_REJECT)
        _, st = self.run_cmd(["status", "--flight", k, "--state-dir", self.state])
        self.assertEqual(st["state"], "incomplete")
        self.assertFalse(st["satisfies_verification"])


class TestReadShapeMatrix(Harness):
    def _corrupt(self, raw: bytes):
        _, owner = self.claim()
        path = Path(self.state) / f"{owner['flight_key']}.json"
        path.write_bytes(raw)
        return self.run_cmd(["status", "--flight", owner["flight_key"], "--state-dir", self.state])

    def test_missing_flight(self):
        code, out = self.run_cmd(["status", "--flight", "deadbeef", "--state-dir", self.state])
        self.assertEqual(code, vf.EXIT_UNREADABLE)
        self.assertFalse(out["satisfies_verification"])

    def test_empty_json(self):
        code, out = self._corrupt(b"")
        self.assertEqual(code, vf.EXIT_UNREADABLE)
        self.assertFalse(out["satisfies_verification"])

    def test_truncated_json(self):
        code, out = self._corrupt(b'{"schema_version":1,"state":"pas')
        self.assertEqual(code, vf.EXIT_UNREADABLE)

    def test_malformed_json(self):
        code, out = self._corrupt(b"{not json]")
        self.assertEqual(code, vf.EXIT_UNREADABLE)
        self.assertEqual(out["reason"], "malformed_json")

    def test_array_toplevel(self):
        # A JSON array decodes fine but is not a flight handle object.
        code, out = self._corrupt(b"[1,2,3]")
        self.assertEqual(out["reason"], "not_object")
        self.assertEqual(code, vf.EXIT_UNREADABLE)

    def test_scalar_toplevel(self):
        code, out = self._corrupt(b'42')
        self.assertEqual(code, vf.EXIT_UNREADABLE)

    def test_valid_falsy_state(self):
        # state is a valid-falsy value (false / 0 / "") — never coerced to a pass.
        for payload in (b'{"schema_version":1,"state":false,"flight_key":"k","descriptor_digest":"d","token_digest":"t"}',
                        b'{"schema_version":1,"state":0,"flight_key":"k","descriptor_digest":"d","token_digest":"t"}',
                        b'{"schema_version":1,"state":"","flight_key":"k","descriptor_digest":"d","token_digest":"t"}'):
            code, out = self._corrupt(payload)
            self.assertEqual(out["reason"], "missing_or_invalid_state")
            self.assertEqual(code, vf.EXIT_UNREADABLE)

    def test_string_true_state(self):
        code, out = self._corrupt(b'{"schema_version":1,"state":"true","flight_key":"k","descriptor_digest":"d","token_digest":"t"}')
        self.assertEqual(out["reason"], "missing_or_invalid_state")

    def test_missing_required_field(self):
        code, out = self._corrupt(b'{"schema_version":1,"state":"passed","descriptor_digest":"d","token_digest":"t"}')
        self.assertEqual(out["reason"], "missing_field:flight_key")

    def test_unknown_schema_version_in_file(self):
        code, out = self._corrupt(b'{"schema_version":7,"state":"passed","flight_key":"k","descriptor_digest":"d","token_digest":"t"}')
        self.assertEqual(out["reason"], "unknown_schema_version")


class TestStaleDrift(Harness):
    def test_checkout_drift_marks_stale(self):
        _, owner = self.claim()
        current = self._write({"checkout_id": "r1", "head": "DIFFERENT",
                               "index_digest": "i1", "tracked_digest": "t1", "untracked_digest": "u1"})
        code, out = self.run_cmd(["status", "--flight", owner["flight_key"],
                                  "--current-checkout-file", current, "--state-dir", self.state])
        self.assertEqual(out["state"], "stale")
        self.assertEqual(out["invalidation_reason"], "checkout_drift")
        self.assertEqual(code, vf.EXIT_NON_PASS)

    def test_matching_checkout_no_stale(self):
        _, owner = self.claim()
        current = self._write({"checkout_id": "r1", "head": "abc",
                               "index_digest": "i1", "tracked_digest": "t1", "untracked_digest": "u1"})
        _, out = self.run_cmd(["status", "--flight", owner["flight_key"],
                               "--current-checkout-file", current, "--state-dir", self.state])
        self.assertEqual(out["state"], "claimed")


class TestSubdirAndWorktree(Harness):
    def test_same_key_attaches_from_a_different_working_directory(self):
        # A subdirectory / linked-worktree caller that computes the SAME complete
        # flight key attaches to the same flight regardless of the process cwd —
        # the helper is cwd-independent (state dir is explicit, no git is run). Run
        # the attach from a different cwd to actually exercise that independence.
        _, owner = self.claim()
        subdir = os.path.join(self.tmp, "nested", "deep")
        os.makedirs(subdir)
        prev = os.getcwd()
        try:
            os.chdir(subdir)
            _, att = self.claim()  # same absolute --state-dir, different cwd
        finally:
            os.chdir(prev)
        self.assertEqual(att["role"], "attacher")
        self.assertEqual(att["flight_key"], owner["flight_key"])

    def test_different_checkout_id_does_not_attach(self):
        _, owner = self.claim()
        code, other = self.claim(_decl(checkout={"checkout_id": "OTHER_WORKTREE"}))
        # A different checkout identity is a different key -> a fresh owner claim.
        self.assertEqual(other["role"], "owner")
        self.assertNotEqual(other["flight_key"], owner["flight_key"])


class TestFinishPropagation(Harness):
    def _finish(self, result, summary):
        _, owner = self.claim()
        k, t = owner["flight_key"], owner["token"]
        self.run_cmd(["mark-running", "--flight", k, "--token", t, "--state-dir", self.state])
        argv = ["finish", "--flight", k, "--token", t, "--result", result,
                "--state-dir", self.state, "--logs-dir", self.logs]
        if summary is not None:
            argv += ["--summary-file", self._write(summary)]
        code, out = self.run_cmd(argv)
        return k, code, out

    def test_passed_satisfies(self):
        k, code, _ = self._finish("passed", {"command": "run.sh", "exit_status": 0, "skipped_checks": []})
        self.assertEqual(code, vf.EXIT_OK)
        c, st = self.run_cmd(["status", "--flight", k, "--state-dir", self.state])
        self.assertEqual(c, vf.EXIT_OK)
        self.assertTrue(st["satisfies_verification"])

    def test_failed_does_not_satisfy(self):
        k, _, _ = self._finish("failed", {"command": "run.sh", "exit_status": 1,
                                           "failure_text": "3 failed", "skipped_checks": []})
        c, st = self.run_cmd(["status", "--flight", k, "--state-dir", self.state])
        self.assertEqual(c, vf.EXIT_NON_PASS)
        self.assertEqual(st["state"], "failed")
        self.assertFalse(st["satisfies_verification"])

    def test_skipped_checks_recorded_and_block_clean_pass(self):
        # A pass whose summary carries skipped checks preserves them; the record
        # keeps them so the caller can refuse to report a clean pass.
        skipped = [{"name": "T6b", "kind": "host-capability", "reason": "no dash"}]
        k, code, _ = self._finish("passed", {"command": "run.sh", "exit_status": 0,
                                             "skipped_checks": skipped})
        _, st = self.run_cmd(["status", "--flight", k, "--state-dir", self.state])
        self.assertEqual(st["skipped_checks"], skipped)

    def test_timed_out_writable_without_evidence_and_non_pass(self):
        # timed_out / cancelled are owner-recorded terminal outcomes that carry no
        # suite summary — writable without evidence, never a pass, and immutable.
        for result in ("timed_out", "cancelled"):
            # distinct checkout per iteration → distinct flight key (avoids attach)
            _, owner = self.claim(_decl(checkout={"head": f"head-{result}"}))
            k, t = owner["flight_key"], owner["token"]
            self.run_cmd(["mark-running", "--flight", k, "--token", t, "--state-dir", self.state])
            code, out = self.run_cmd(["finish", "--flight", k, "--token", t, "--result", result,
                                      "--state-dir", self.state, "--logs-dir", self.logs])
            self.assertEqual(code, vf.EXIT_OK, f"{result} finish should succeed without evidence")
            self.assertEqual(out["state"], result)
            c, st = self.run_cmd(["status", "--flight", k, "--state-dir", self.state])
            self.assertEqual(c, vf.EXIT_NON_PASS)
            self.assertFalse(st["satisfies_verification"])
            # immutable: a second finish is rejected
            c2, _ = self.run_cmd(["finish", "--flight", k, "--token", t, "--result", "passed",
                                  "--summary-file", self._write({"command": "x", "skipped_checks": []}),
                                  "--state-dir", self.state])
            self.assertEqual(c2, vf.EXIT_CAS_REJECT)

    def test_malformed_summary_file_rejected(self):
        # A truncated / undecodable evidence file is rejected before any terminal write.
        _, owner = self.claim()
        k, t = owner["flight_key"], owner["token"]
        self.run_cmd(["mark-running", "--flight", k, "--token", t, "--state-dir", self.state])
        bad = os.path.join(self.tmp, "bad-summary.json")
        Path(bad).write_bytes(b'{"command": "run.sh", "exit')  # truncated JSON
        code, out = self.run_cmd(["finish", "--flight", k, "--token", t, "--result", "passed",
                                  "--summary-file", bad, "--state-dir", self.state])
        self.assertEqual(code, vf.EXIT_INVALID)
        self.assertTrue(out["reason"].startswith("summary:"))
        # the flight is untouched — still running, never a false pass
        _, st = self.run_cmd(["status", "--flight", k, "--state-dir", self.state])
        self.assertEqual(st["state"], "running")

    def test_present_but_malformed_summary_becomes_incomplete(self):
        # The evidence gate is the one place a pass is decided: a present-but-malformed
        # summary (a scalar / array / empty object) is the same unknown class as an
        # absent one and must become `incomplete`, never a clean `passed`.
        for i, payload in enumerate((42, "x", [], {})):
            # distinct checkout per iteration → distinct flight key (avoids attach)
            _, owner = self.claim(_decl(checkout={"head": f"head-mal-{i}"}))
            k, t = owner["flight_key"], owner["token"]
            self.run_cmd(["mark-running", "--flight", k, "--token", t, "--state-dir", self.state])
            code, out = self.run_cmd(["finish", "--flight", k, "--token", t, "--result", "passed",
                                      "--summary-file", self._write(payload), "--state-dir", self.state])
            self.assertEqual(out["result"], "incomplete", f"summary {payload!r} must not be a pass")
            self.assertEqual(code, vf.EXIT_CAS_REJECT)
            _, st = self.run_cmd(["status", "--flight", k, "--state-dir", self.state])
            self.assertEqual(st["state"], "incomplete")
            self.assertFalse(st["satisfies_verification"])

    def test_command_duration_recorded(self):
        os.environ["DEVFLOW_FLIGHT_NOW"] = "5000"
        _, owner = self.claim()
        k, t = owner["flight_key"], owner["token"]
        self.run_cmd(["mark-running", "--flight", k, "--token", t, "--state-dir", self.state])
        os.environ["DEVFLOW_FLIGHT_NOW"] = "5060"
        self.run_cmd(["finish", "--flight", k, "--token", t, "--result", "passed",
                      "--summary-file", self._write({"command": "x", "skipped_checks": []}),
                      "--state-dir", self.state, "--logs-dir", self.logs])
        _, st = self.run_cmd(["status", "--flight", k, "--state-dir", self.state])
        self.assertEqual(st["command_duration_s"], 60.0)


class TestWait(Harness):
    def test_wait_returns_on_terminal_pass(self):
        _, owner = self.claim()
        k, t = owner["flight_key"], owner["token"]
        self.run_cmd(["mark-running", "--flight", k, "--token", t, "--state-dir", self.state])
        self.run_cmd(["finish", "--flight", k, "--token", t, "--result", "passed",
                      "--summary-file", self._write({"command": "x", "skipped_checks": []}),
                      "--state-dir", self.state, "--logs-dir", self.logs])
        code, out = self.run_cmd(["wait", "--flight", k, "--timeout", "1",
                                  "--poll-interval", "0", "--state-dir", self.state, "--logs-dir", self.logs])
        self.assertEqual(code, vf.EXIT_OK)
        self.assertTrue(out["satisfies_verification"])

    def test_wait_expiry_non_mutating(self):
        _, owner = self.claim()
        k = owner["flight_key"]
        # Still `claimed` (active) -> wait bound elapses -> wait_expired, unchanged.
        code, out = self.run_cmd(["wait", "--flight", k, "--timeout", "0",
                                  "--poll-interval", "0", "--state-dir", self.state, "--logs-dir", self.logs])
        self.assertEqual(code, vf.EXIT_WAIT_EXPIRED)
        self.assertEqual(out["result"], "wait_expired")
        self.assertFalse(out["satisfies_verification"])
        # The flight was NOT mutated by the wait — still claimed.
        _, st = self.run_cmd(["status", "--flight", k, "--state-dir", self.state])
        self.assertEqual(st["state"], "claimed")

    def test_wait_on_failed_is_non_pass(self):
        _, owner = self.claim()
        k, t = owner["flight_key"], owner["token"]
        self.run_cmd(["mark-running", "--flight", k, "--token", t, "--state-dir", self.state])
        self.run_cmd(["finish", "--flight", k, "--token", t, "--result", "failed",
                      "--summary-file", self._write({"command": "x", "skipped_checks": []}),
                      "--state-dir", self.state, "--logs-dir", self.logs])
        code, out = self.run_cmd(["wait", "--flight", k, "--timeout", "0",
                                  "--poll-interval", "0", "--state-dir", self.state, "--logs-dir", self.logs])
        self.assertEqual(code, vf.EXIT_NON_PASS)
        self.assertEqual(out["state"], "failed")


class TestTelemetry(Harness):
    def _events(self):
        base = Path(self.logs)
        if not base.exists():
            return []
        return [json.loads(p.read_text())["event"] for p in base.glob("*.json")]

    def test_claim_and_attach_emit_events(self):
        self.claim()
        self.claim()
        ev = self._events()
        self.assertIn("flight_claimed", ev)
        self.assertIn("flight_attached", ev)

    def test_finish_emits_terminal_event(self):
        _, owner = self.claim()
        k, t = owner["flight_key"], owner["token"]
        self.run_cmd(["mark-running", "--flight", k, "--token", t, "--state-dir", self.state])
        self.run_cmd(["finish", "--flight", k, "--token", t, "--result", "passed",
                      "--summary-file", self._write({"command": "x", "skipped_checks": []}),
                      "--state-dir", self.state, "--logs-dir", self.logs])
        self.assertIn("flight_finished", self._events())


class TestNoExecutionContract(unittest.TestCase):
    """Static guard mirrored by run.sh: the helper is data-only."""

    def test_no_subprocess_or_git_import(self):
        src = (ROOT / "scripts" / "verification-flight.py").read_text()
        for banned in ("import subprocess", "subprocess.", "os.system(", "os.exec"):
            self.assertNotIn(banned, src, f"helper must not use {banned}")

    def test_states_are_exactly_the_declared_set(self):
        self.assertEqual(
            set(vf.ALL_STATES),
            {"claimed", "running", "passed", "failed", "timed_out", "cancelled", "stale", "incomplete"},
        )


if __name__ == "__main__":
    unittest.main()
