#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Tests for scripts/import-review-verdict-handoff.py (issue #1314).

The importer is the trust boundary between the untrusted review *producer* and
the trusted *emitter*: it validates the handoff as adversarial input and
publishes a normalized artifact ONLY when every check passes. These tests drive
the accepted shape and each documented rejection class (AC5), and assert the
security-critical invariant that a rejection publishes NO output artifact — so
the emitter can never be scheduled on bad input.

Run directly (`lib/test/test_import_review_verdict_handoff.py`) or via the suite.
"""
from __future__ import annotations

import importlib.util
import json
import os
import re
import tempfile
import unittest
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parents[2]
_MODULE_PATH = _REPO_ROOT / "scripts" / "import-review-verdict-handoff.py"

_spec = importlib.util.spec_from_file_location("import_review_verdict_handoff", _MODULE_PATH)
assert _spec and _spec.loader
mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mod)


VALID = {
    "schema_version": 1,
    "complete": True,
    "review_event": "REQUEST_CHANGES",
    "marker_verdict": "REJECT",
}


class ImporterTestBase(unittest.TestCase):
    def setUp(self) -> None:
        self._dir = tempfile.TemporaryDirectory()
        self.dir = Path(self._dir.name)
        self.addCleanup(self._dir.cleanup)

    def write(self, name: str, content: str) -> str:
        p = self.dir / name
        p.write_text(content, encoding="utf-8")
        return str(p)

    def write_bytes(self, name: str, content: bytes) -> str:
        p = self.dir / name
        p.write_bytes(content)
        return str(p)

    def handoff(self, obj) -> str:
        return self.write("handoff.json", json.dumps(obj))

    def call(self, handoff_path: str, **kw):
        """Return (rc, out_path_or_None). Runs main() with an --out target."""
        out = str(self.dir / "out.json")
        argv = ["--handoff", handoff_path, "--out", out]
        for k, v in kw.items():
            argv.extend([f"--{k.replace('_', '-')}", str(v)])
        rc = mod.main(argv)
        return rc, out


class TestAccepted(ImporterTestBase):
    def test_valid_reject_pair_accepted_and_published(self) -> None:
        rc, out = self.call(self.handoff(VALID))
        self.assertEqual(rc, 0)
        published = json.loads(Path(out).read_text())
        self.assertEqual(published, VALID)

    def test_all_three_legal_pairs(self) -> None:
        for event, verdict in [
            ("REQUEST_CHANGES", "REJECT"),
            ("APPROVE", "APPROVE"),
            ("COMMENT", "APPROVE"),
        ]:
            obj = dict(VALID, review_event=event, marker_verdict=verdict)
            rc, out = self.call(self.handoff(obj))
            self.assertEqual(rc, 0, f"{event}/{verdict} should be accepted")
            self.assertEqual(json.loads(Path(out).read_text())["review_event"], event)

    def test_body_validated_and_published(self) -> None:
        hp = self.handoff(VALID)
        bp = self.write("body.md", "## Review\n\nLooks good.\n")
        outb = str(self.dir / "out-body.md")
        rc = mod.main(["--handoff", hp, "--body", bp, "--out", str(self.dir / "o.json"),
                       "--out-body", outb])
        self.assertEqual(rc, 0)
        self.assertEqual(Path(outb).read_text(), "## Review\n\nLooks good.\n")


class TestRejectionsPublishNothing(ImporterTestBase):
    def assert_rejected(self, handoff_path: str, token: str, **kw) -> None:
        """Run main() once: assert rc==1, no artifact published, and the token."""
        import contextlib
        import io
        out = str(self.dir / "out.json")
        argv = ["--handoff", handoff_path, "--out", out]
        for k, v in kw.items():
            argv.extend([f"--{k.replace('_', '-')}", str(v)])
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            rc = mod.main(argv)
        self.assertEqual(rc, 1, f"expected rejection for {token}")
        self.assertFalse(os.path.exists(out), "rejection must publish no artifact")
        first = buf.getvalue().splitlines()[0]
        self.assertTrue(first.startswith("REJECTED "), first)
        self.assertEqual(first.split()[1], token)

    def test_string_true_against_boolean(self) -> None:
        self.assert_rejected(self.handoff(dict(VALID, complete="true")), "bad-complete")

    def test_string_schema_version(self) -> None:
        self.assert_rejected(self.handoff(dict(VALID, schema_version="1")), "bad-schema-version")

    def test_bool_schema_version(self) -> None:
        self.assert_rejected(self.handoff(dict(VALID, schema_version=True)), "bad-schema-version")

    def test_wrong_schema_version(self) -> None:
        self.assert_rejected(self.handoff(dict(VALID, schema_version=2)), "bad-schema-version")

    def test_complete_integer_one(self) -> None:
        self.assert_rejected(self.handoff(dict(VALID, complete=1)), "bad-complete")

    def test_unknown_field(self) -> None:
        self.assert_rejected(self.handoff(dict(VALID, repo="a/b")), "unknown-field")

    def test_missing_field(self) -> None:
        obj = dict(VALID)
        del obj["marker_verdict"]
        self.assert_rejected(self.handoff(obj), "missing-field")

    def test_bad_review_event(self) -> None:
        self.assert_rejected(self.handoff(dict(VALID, review_event="MERGE")), "bad-review-event")

    def test_bad_marker_verdict(self) -> None:
        self.assert_rejected(self.handoff(dict(VALID, marker_verdict="MAYBE")), "bad-marker-verdict")

    def test_illegal_pair(self) -> None:
        self.assert_rejected(
            self.handoff(dict(VALID, review_event="APPROVE", marker_verdict="REJECT")),
            "illegal-event-verdict-pair",
        )

    def test_not_object(self) -> None:
        self.assert_rejected(self.write("handoff.json", "[1,2,3]"), "not-object")

    def test_not_json(self) -> None:
        self.assert_rejected(self.write("handoff.json", "{not json"), "not-json")

    def test_invalid_utf8(self) -> None:
        self.assert_rejected(self.write_bytes("handoff.json", b"\xff\xfe{"), "invalid-utf8")

    def test_nul_byte(self) -> None:
        self.assert_rejected(self.write_bytes("handoff.json", b'{"a":\x00}'), "nul-byte")

    def test_disallowed_control(self) -> None:
        # A bare BEL (U+0007) inside the JSON text.
        self.assert_rejected(self.write_bytes("handoff.json", b'{"a":\x07}'), "disallowed-control")

    def test_oversized(self) -> None:
        self.assert_rejected(self.handoff(VALID), "oversized", max_handoff_bytes=10)

    def test_symlink_rejected(self) -> None:
        real = self.handoff(VALID)
        link = self.dir / "link.json"
        os.symlink(real, link)
        self.assert_rejected(str(link), "symlink")

    def test_extra_hard_link_rejected(self) -> None:
        real = self.handoff(VALID)
        hard = self.dir / "hard.json"
        os.link(real, hard)
        # Both names now have st_nlink == 2.
        self.assert_rejected(str(hard), "extra-hard-links")

    def test_non_regular_file_rejected(self) -> None:
        # A directory is the always-available non-regular file: O_NOFOLLOW opens
        # it, and the S_ISREG check refuses it.
        self.assert_rejected(str(self.dir), "not-regular-file")

    def test_unreadable_missing_file_rejected(self) -> None:
        # The non-ELOOP open-failure branch (missing file / permission).
        self.assert_rejected(str(self.dir / "does-not-exist.json"), "unreadable")

    def test_unstable_metadata_rejected(self) -> None:
        # The TOCTOU re-stat defense: the descriptor's metadata changes across the
        # read. Drive it by making the second os.fstat report a bumped mtime — the
        # swap-after-validation attack the threat model calls out.
        real_fstat = mod.os.fstat
        calls = {"n": 0}

        class FakeStat:
            def __init__(self, base, mtime_ns):
                self.st_mode = base.st_mode
                self.st_nlink = 1
                self.st_size = base.st_size
                self.st_ino = base.st_ino
                self.st_dev = base.st_dev
                self.st_mtime_ns = mtime_ns
                self.st_ctime_ns = base.st_ctime_ns

        def fake_fstat(fd):
            calls["n"] += 1
            base = real_fstat(fd)
            # First fstat: true mtime. Second: drifted mtime → unstable.
            return FakeStat(base, base.st_mtime_ns + (0 if calls["n"] == 1 else 1))

        mod.os.fstat = fake_fstat
        try:
            self.assert_rejected(self.handoff(VALID), "unstable-metadata")
        finally:
            mod.os.fstat = real_fstat


class TestBodyRejections(ImporterTestBase):
    def test_body_nul_rejected_no_publish(self) -> None:
        hp = self.handoff(VALID)
        bp = self.write_bytes("body.md", b"ok\x00bad")
        out = str(self.dir / "o.json")
        outb = str(self.dir / "ob.md")
        rc = mod.main(["--handoff", hp, "--body", bp, "--out", out, "--out-body", outb])
        self.assertEqual(rc, 1)
        self.assertFalse(os.path.exists(out))
        self.assertFalse(os.path.exists(outb))

    def test_body_oversized_rejected_no_publish(self) -> None:
        hp = self.handoff(VALID)
        bp = self.write("body.md", "x" * 100)
        out = str(self.dir / "o.json")
        outb = str(self.dir / "ob.md")
        rc = mod.main(["--handoff", hp, "--body", bp, "--out", out,
                       "--out-body", outb, "--max-body-bytes", "10"])
        self.assertEqual(rc, 1)
        self.assertFalse(os.path.exists(out))
        self.assertFalse(os.path.exists(outb))

    def test_out_body_without_body_is_usage_error(self) -> None:
        rc = mod.main(["--handoff", self.handoff(VALID), "--out-body", str(self.dir / "x")])
        self.assertEqual(rc, 2)


# The review-event <-> marker-verdict mapping is declared TWICE: here in the
# importer's LEGAL_PAIRS (the trust-boundary validator) and in
# scripts/post-review-verdict.sh's `case "$VERDICT"` arms (the delivery mapper).
# Part 1's review (#1314) recorded that these two must not drift; #1319 wires the
# emitter delivery mode, which makes a silent divergence a real hazard — the
# importer would accept a (event, verdict) pair the poster never produces, or
# reject one it does. Rather than route the security-critical importer through a
# runtime file read, this reconciliation test asserts the two hand-maintained
# declarations stay identical, so a change to one that is not mirrored in the
# other turns the suite RED.
_POST_VERDICT_PATH = _REPO_ROOT / "scripts" / "post-review-verdict.sh"

# Match `EVENT=<X>; MARKER_VERDICT=<Y>` on a single case arm, tolerant of the
# column-aligning whitespace the shell source uses between the assignments.
_CASE_ARM_RE = re.compile(
    r"EVENT=([A-Z_]+);\s*MARKER_VERDICT=([A-Z_]+)"
)


def _shell_legal_pairs() -> set:
    text = _POST_VERDICT_PATH.read_text(encoding="utf-8")
    return {(m.group(1), m.group(2)) for m in _CASE_ARM_RE.finditer(text)}


class TestLegalPairReconciliation(unittest.TestCase):
    """The importer's LEGAL_PAIRS and post-review-verdict.sh's case arms are two
    hand-maintained copies of the same (review_event, marker_verdict) table; this
    asserts they cannot silently diverge (#1319 design-note debt from #1314)."""

    def test_shell_arms_match_importer_legal_pairs(self) -> None:
        shell_pairs = _shell_legal_pairs()
        # The shell must actually declare its arms — an empty parse would make the
        # equality below pass vacuously if LEGAL_PAIRS were ever emptied too.
        self.assertTrue(
            shell_pairs,
            "parsed no EVENT=/MARKER_VERDICT= arms from post-review-verdict.sh — "
            "the case block moved or changed shape; update _CASE_ARM_RE",
        )
        self.assertEqual(
            shell_pairs,
            set(mod.LEGAL_PAIRS),
            "the (review_event, marker_verdict) mapping drifted between "
            "post-review-verdict.sh's case arms and the importer's LEGAL_PAIRS",
        )

    def test_shell_events_and_verdicts_are_in_importer_vocabularies(self) -> None:
        for event, verdict in _shell_legal_pairs():
            self.assertIn(event, mod.REVIEW_EVENTS)
            self.assertIn(verdict, mod.MARKER_VERDICTS)


if __name__ == "__main__":
    unittest.main()
