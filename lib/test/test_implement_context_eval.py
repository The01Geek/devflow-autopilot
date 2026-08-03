#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Focused unit tests for scripts/implement-context-eval.py (issue #1209).

Every acceptance criterion of issue #1209 that the eval or its committed fixtures can
witness maps to at least one assertion here. The written-record ACs (AC5/AC6/AC7) are
discharged by docs/implement-context.md, not by a suite test.

The fixture-derived expected figures are RE-DERIVED from the committed fixtures
(AC4/T1) rather than hard-coded: `_expected_from_fixture` re-computes each expected
value straight from the raw JSONL, so changing a fixture updates the assertion.

Driven serially from lib/test/run.sh.
"""

import io
import importlib.util
import json
import os
import re
import sys
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.abspath(os.path.join(_HERE, "..", ".."))
_EVAL_PATH = os.path.join(_REPO, "scripts", "implement-context-eval.py")
_FIX = os.path.join(_HERE, "fixtures", "implement-eval")


def _load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ICE = _load_module("ice", _EVAL_PATH)


def _write(dirpath, name, lines):
    os.makedirs(dirpath, exist_ok=True)
    with open(os.path.join(dirpath, name), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


# ── Independent re-derivation of the expected figures from the raw fixtures (AC4) ──

def _expected_from_fixture(session_paths):
    """Re-derive the eval's per-run figures straight from raw JSONL session files.

    This is an INDEPENDENT reimplementation of the measurement (context sum, main-thread
    filtering, phase-file basename match) used only by the tests, so an assertion is
    checked against the fixtures' own encoded content rather than a copied constant. It
    intentionally does not share code with the eval.
    """
    runs = []
    for path in sorted(session_paths):
        peaks, phase = [], {label: 0 for label in ICE.PHASE_READ_LABELS}
        attributed = False
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                rec = json.loads(line)
                if rec.get("type") != "assistant":
                    continue
                if rec.get("isSidechain") is True:
                    continue
                if rec.get("attributionSkill") not in ICE.ATTRIBUTION:
                    continue
                attributed = True
                usage = rec["message"].get("usage") or {}
                peaks.append(
                    (usage.get("input_tokens") or 0)
                    + (usage.get("cache_read_input_tokens") or 0)
                    + (usage.get("cache_creation_input_tokens") or 0))
                for block in rec["message"].get("content") or []:
                    if block.get("type") == "tool_use" and block.get("name") == "Read":
                        fp = block.get("input", {}).get("file_path", "")
                        label = ICE.PHASE_FILES.get(os.path.basename(fp))
                        if label is not None:
                            phase[label] += 1
        if attributed:
            runs.append({
                "source": os.path.basename(path),
                "peak_context": max(peaks) if peaks else 0,
                "phase_reads": phase,
                "total_phase_reads": sum(phase.values()),
            })
    return runs


class FixtureDerivedTest(unittest.TestCase):
    """T1: the eval's figures match what the committed fixtures encode, re-derived."""

    def _corpus_sessions(self, corpus):
        root = os.path.join(_FIX, corpus)
        return [os.path.join(dp, f)
                for dp, _d, files in os.walk(root)  # tree-walk-ok: rooted at the fixed committed implement-eval fixtures subdir, not the repo root
                for f in files if f.endswith(".jsonl")]

    def test_corpus_matches_independent_rederivation(self):
        runs, skipped = ICE.eval_corpus(os.path.join(_FIX, "corpus"))
        expected = _expected_from_fixture(self._corpus_sessions("corpus"))
        self.assertEqual(sum(skipped.values()), 0)
        got = {r["source"]: r for r in runs}
        exp = {r["source"]: r for r in expected}
        self.assertEqual(set(got), set(exp))
        for src in exp:
            self.assertEqual(got[src]["peak_context"], exp[src]["peak_context"], src)
            self.assertEqual(got[src]["phase_reads"], exp[src]["phase_reads"], src)
            self.assertEqual(
                got[src]["total_phase_reads"], exp[src]["total_phase_reads"], src)

    def test_aggregate_median_and_max_are_rederivable(self):
        # AC3: median AND max are reported so tail behaviour is visible.
        runs, _ = ICE.eval_corpus(os.path.join(_FIX, "corpus"))
        summary = ICE.aggregate(runs)
        expected = _expected_from_fixture(self._corpus_sessions("corpus"))
        peaks = sorted(r["peak_context"] for r in expected)
        self.assertEqual(summary["run_count"], len(expected))
        self.assertEqual(summary["median_peak_context"], ICE._median(peaks))
        self.assertEqual(summary["max_peak_context"], max(peaks))
        for label in ICE.PHASE_READ_LABELS:
            counts = sorted(r["phase_reads"][label] for r in expected)
            self.assertEqual(summary["median_{}_reads".format(label)], ICE._median(counts))
            self.assertEqual(summary["max_{}_reads".format(label)], max(counts))
            self.assertEqual(summary["total_{}_reads".format(label)], sum(counts))


class PhaseReadCountTest(unittest.TestCase):
    """AC2 + T2: per-phase read count is reported, separate from peak, and counts every
    re-entry rather than the phase once."""

    def test_peak_and_phase_reads_are_distinct_reported_axes(self):
        runs, _ = ICE.eval_corpus(os.path.join(_FIX, "corpus"))
        for r in runs:
            self.assertIn("peak_context", r)
            self.assertIn("phase_reads", r)
            self.assertEqual(set(r["phase_reads"]), set(ICE.PHASE_READ_LABELS))

    def test_phase3_reentry_counts_every_reentry(self):
        # T2: a run that re-enters Phase 3 several times; the phase-3 count reflects
        # every re-entry (4 here), not 1. Re-derived from the fixture.
        runs, _ = ICE.eval_corpus(os.path.join(_FIX, "phase3-reentry"))
        self.assertEqual(len(runs), 1)
        expected = _expected_from_fixture([os.path.join(
            _FIX, "phase3-reentry", "session-phase3-reentry.jsonl")])
        self.assertEqual(runs[0]["phase_reads"]["phase3"],
                         expected[0]["phase_reads"]["phase3"])
        self.assertGreater(runs[0]["phase_reads"]["phase3"], 1,
                           "the fixture must exercise more than one phase-3 re-entry")


class _SingleSessionMixin:
    def _run_one(self, lines):
        with tempfile.TemporaryDirectory() as d:
            _write(d, "s.jsonl", lines)
            return ICE.eval_corpus(d)


class BoundaryTest(_SingleSessionMixin, unittest.TestCase):
    def test_zero_attributed_turns_emits_no_run(self):
        runs, _ = self._run_one([
            '{"type":"assistant","attributionSkill":"other","message":{"usage":{"input_tokens":5}}}',
        ])
        self.assertEqual(runs, [])

    def test_one_turn_run_context_sum(self):
        runs, _ = self._run_one([
            '{"type":"assistant","attributionSkill":"prflow:implement",'
            '"message":{"usage":{"input_tokens":10,"cache_read_input_tokens":20,'
            '"cache_creation_input_tokens":5,"output_tokens":3}}}',
        ])
        self.assertEqual(len(runs), 1)
        self.assertEqual(runs[0]["turn_count"], 1)
        # output_tokens is excluded from the residency axis.
        self.assertEqual(runs[0]["peak_context"], 35)

    def test_null_usage_subfield_treated_as_zero(self):
        runs, _ = self._run_one([
            '{"type":"assistant","attributionSkill":"prflow:implement",'
            '"message":{"usage":{"input_tokens":null,"cache_read_input_tokens":7}}}',
        ])
        self.assertEqual(runs[0]["peak_context"], 7)

    def test_sidechain_read_and_context_excluded(self):
        # A sidechain (subagent) record reading a phase file must not count on either
        # axis: the phase files are read by the orchestrator main thread.
        runs, _ = self._run_one([
            '{"type":"assistant","attributionSkill":"prflow:implement",'
            '"message":{"usage":{"input_tokens":1}}}',
            '{"type":"assistant","isSidechain":true,"attributionSkill":"prflow:implement",'
            '"message":{"usage":{"input_tokens":999},"content":['
            '{"type":"tool_use","id":"s1","name":"Read",'
            '"input":{"file_path":"skills/implement/phases/phase-3-review.md"}}]}}',
        ])
        self.assertEqual(runs[0]["peak_context"], 1)
        self.assertEqual(runs[0]["phase_reads"]["phase3"], 0)

    def test_devflow_namespace_also_attributed(self):
        runs, _ = self._run_one([
            '{"type":"assistant","attributionSkill":"devflow:implement",'
            '"message":{"usage":{"input_tokens":8}}}',
        ])
        self.assertEqual(len(runs), 1)
        self.assertEqual(runs[0]["peak_context"], 8)

    def test_vendored_path_basename_matches(self):
        runs, _ = self._run_one([
            '{"type":"assistant","attributionSkill":"prflow:implement",'
            '"message":{"usage":{"input_tokens":1},"content":['
            '{"type":"tool_use","id":"v1","name":"Read","input":{"file_path":'
            '".prflow/vendor/prflow/skills/implement/phases/phase-1-setup.md"}}]}}',
        ])
        self.assertEqual(runs[0]["phase_reads"]["phase1"], 1)

    def test_non_phase_read_not_counted(self):
        runs, _ = self._run_one([
            '{"type":"assistant","attributionSkill":"prflow:implement",'
            '"message":{"usage":{"input_tokens":1},"content":['
            '{"type":"tool_use","id":"n1","name":"Read",'
            '"input":{"file_path":"skills/implement/SKILL.md"}}]}}',
        ])
        self.assertEqual(runs[0]["total_phase_reads"], 0)

    def test_compaction_counted(self):
        runs, _ = self._run_one([
            '{"type":"system","subtype":"compact_boundary"}',
            '{"type":"assistant","attributionSkill":"prflow:implement",'
            '"message":{"usage":{"input_tokens":1}}}',
        ])
        self.assertEqual(runs[0]["compact_boundary_count"], 1)


class AdversarialTest(_SingleSessionMixin, unittest.TestCase):
    def test_malformed_records_degrade_and_are_reported(self):
        runs, skipped = self._run_one([
            'not json at all',
            '["a","list","not","an","object"]',
            '{"no":"type field"}',
            '{"type":"assistant","attributionSkill":"prflow:implement",'
            '"message":{"usage":{"input_tokens":4}}}',
            '{"type":"assistant","attributionSkill":"prflow:implement"',  # truncated
        ])
        self.assertEqual(len(runs), 1)
        self.assertEqual(runs[0]["turn_count"], 1)
        self.assertEqual(skipped["non_json_line"], 2)
        self.assertEqual(skipped["not_object"], 1)
        self.assertEqual(skipped["no_type"], 1)

    def test_message_wrong_shape_does_not_detonate(self):
        saved = sys.stderr
        sys.stderr = io.StringIO()
        try:
            runs, skipped = self._run_one([
                '{"type":"assistant","attributionSkill":"prflow:implement",'
                '"message":["not","a","dict"]}',
                '{"type":"assistant","attributionSkill":"prflow:implement",'
                '"message":{"usage":{"input_tokens":9}}}',
            ])
        finally:
            sys.stderr = saved
        self.assertEqual(len(runs), 1)
        self.assertEqual(runs[0]["turn_count"], 2)
        self.assertEqual(runs[0]["peak_context"], 9)
        self.assertEqual(sum(skipped.values()), 0)

    def test_read_block_input_wrong_shape_does_not_detonate(self):
        saved = sys.stderr
        sys.stderr = io.StringIO()
        try:
            runs, skipped = self._run_one([
                '{"type":"assistant","attributionSkill":"prflow:implement",'
                '"message":{"usage":{"input_tokens":3},"content":['
                '{"type":"tool_use","id":"u1","name":"Read","input":["not","a","dict"]}]}}',
                '{"type":"assistant","attributionSkill":"prflow:implement",'
                '"message":{"usage":{"input_tokens":5}}}',
            ])
        finally:
            sys.stderr = saved
        self.assertEqual(len(runs), 1)
        self.assertEqual(runs[0]["turn_count"], 2)
        self.assertEqual(sum(skipped.values()), 0)

    def test_defensive_dispatch_tallies_malformed_record(self):
        original = ICE.RunAccumulator.observe_system

        def _boom(self, record):
            if record.get("boom"):
                raise TypeError("synthetic malformed record")
            return original(self, record)

        saved_stderr = sys.stderr
        sys.stderr = io.StringIO()
        ICE.RunAccumulator.observe_system = _boom
        try:
            runs, skipped = self._run_one([
                '{"type":"assistant","attributionSkill":"prflow:implement",'
                '"message":{"usage":{"input_tokens":4}}}',
                '{"type":"system","boom":true}',
                '{"type":"assistant","attributionSkill":"prflow:implement",'
                '"message":{"usage":{"input_tokens":6}}}',
            ])
        finally:
            ICE.RunAccumulator.observe_system = original
            sys.stderr = saved_stderr
        self.assertEqual(len(runs), 1)
        self.assertEqual(runs[0]["turn_count"], 2)
        self.assertEqual(skipped["malformed_record"], 1)

    def test_unreadable_session_file_is_tallied(self):
        with tempfile.TemporaryDirectory() as corpus:
            link = os.path.join(corpus, "broken.jsonl")
            try:
                os.symlink(os.path.join(corpus, "missing-target.jsonl"), link)
            except (OSError, NotImplementedError):
                self.skipTest("symlinks unavailable on this host")
            err = io.StringIO()
            saved = sys.stderr
            sys.stderr = err
            try:
                runs, skipped = ICE.eval_corpus(corpus)
            finally:
                sys.stderr = saved
            self.assertEqual(runs, [])
            self.assertEqual(skipped["unreadable_file"], 1)
            self.assertIn("broken.jsonl", err.getvalue())

    def test_determinism(self):
        a, sa = ICE.eval_corpus(os.path.join(_FIX, "corpus"))
        b, sb = ICE.eval_corpus(os.path.join(_FIX, "corpus"))
        self.assertEqual(a, b)
        self.assertEqual(sa, sb)


class AggregateEmptyPopulationTest(unittest.TestCase):
    def test_empty_corpus_reads_unestablished_except_run_count(self):
        summary = ICE.aggregate([])
        self.assertEqual(summary["run_count"], 0)
        for key, value in summary.items():
            if key == "run_count":
                continue
            self.assertEqual(value, ICE.UNESTABLISHED,
                             "{} must be unestablished on an empty population".format(key))


class RenderAndCliTest(unittest.TestCase):
    def test_text_render_lists_every_summary_field(self):
        runs, skipped = ICE.eval_corpus(os.path.join(_FIX, "corpus"))
        summary = ICE.aggregate(runs)
        text = ICE.render_text(runs, summary, skipped)
        for key in summary:
            self.assertIn(key, text)

    def test_missing_corpus_exits_nonzero_naming_path(self):
        err = io.StringIO()
        saved = sys.stderr
        sys.stderr = err
        try:
            rc = ICE.main(["/no/such/corpus/here"])
        finally:
            sys.stderr = saved
        self.assertEqual(rc, 2)
        self.assertIn("/no/such/corpus/here", err.getvalue())

    def test_json_output_is_valid_and_sorted(self):
        out = io.StringIO()
        saved = sys.stdout
        sys.stdout = out
        try:
            rc = ICE.main([os.path.join(_FIX, "corpus"), "--format", "json"])
        finally:
            sys.stdout = saved
        self.assertEqual(rc, 0)
        parsed = json.loads(out.getvalue())
        self.assertIn("summary", parsed)
        self.assertEqual(parsed["summary"]["run_count"], 3)


# ── Owner-id / transcript-shape scan over every committed file this change adds ──

_SECRET_PATTERNS = [
    re.compile(r"the01geek"),
    re.compile(r"/Users/"),
    re.compile(r"\.claude-3/jobs"),
    re.compile(r"-Users-[a-z0-9]+-repos"),
]


def _scan_for_secrets(text):
    return [p.pattern for p in _SECRET_PATTERNS if p.search(text)]


class SecretDetectorTest(unittest.TestCase):
    def test_detector_fires_on_planted_control(self):
        planted = os.path.join(_FIX, "planted-owner-id.txt")
        with open(planted, encoding="utf-8") as fh:
            hits = _scan_for_secrets(fh.read())
        self.assertTrue(hits, "planted positive control did not trip the secret detector")

    def test_added_files_are_clean(self):
        targets = [_EVAL_PATH, os.path.join(_REPO, "docs", "implement-context.md")]
        for dirpath, _dirs, files in os.walk(_FIX):  # tree-walk-ok: rooted at the fixed committed implement-eval fixtures subdir, not the repo root
            for f in sorted(files):
                if f == "planted-owner-id.txt":
                    continue
                targets.append(os.path.join(dirpath, f))
        for path in targets:
            if not os.path.exists(path):
                continue
            with open(path, encoding="utf-8") as fh:
                hits = _scan_for_secrets(fh.read())
            self.assertFalse(hits, "owner-id/transcript shape {} found in {}".format(hits, path))


class PhaseFileSetCouplingTest(unittest.TestCase):
    """PHASE_FILES is a standalone mirror of the four implement phase files (the eval
    imports nothing from the skill). Reconcile it against the on-disk phases/ directory
    so a phase-file rename/add/remove goes RED here rather than silently under-reporting
    that phase's read count as 0 — the same silent-zero failure mode the derived
    ATTRIBUTION set is built to avoid.
    """

    def test_phase_files_match_the_on_disk_phase_dir(self):
        phase_dir = os.path.join(_REPO, "skills", "implement", "phases")
        on_disk = {f for f in os.listdir(phase_dir) if f.endswith(".md")}
        self.assertEqual(
            set(ICE.PHASE_FILES), on_disk,
            "PHASE_FILES must exactly mirror skills/implement/phases/*.md; a phase "
            "rename/add/remove was not mirrored into scripts/implement-context-eval.py")

    def test_phase_read_labels_are_unique_and_cover_every_phase_file(self):
        # The label set must be a 1:1 image of the basenames — a duplicated label would
        # silently merge two phases' counts into one reported axis.
        self.assertEqual(len(set(ICE.PHASE_FILES.values())), len(ICE.PHASE_FILES))
        self.assertEqual(set(ICE.PHASE_READ_LABELS), set(ICE.PHASE_FILES.values()))


class NoAutoInvocationTest(unittest.TestCase):
    """AC1 + T3: nothing invokes the script automatically; only its own test does."""

    def test_only_the_focused_test_references_the_script(self):
        needle = "implement-context-eval.py"
        offenders = []
        for sub in ("skills", ".github/workflows", "scripts"):
            root = os.path.join(_REPO, sub)
            for dirpath, dirs, files in os.walk(root):  # tree-walk-ok: rooted at fixed subtrees (skills/.github/scripts), not the repo root
                dirs[:] = [d for d in dirs if d != "__pycache__"]
                for f in files:
                    p = os.path.join(dirpath, f)
                    if os.path.basename(p) == "implement-context-eval.py":
                        continue  # the script defining itself is not an invocation
                    try:
                        with open(p, encoding="utf-8", errors="replace") as fh:
                            if needle in fh.read():
                                offenders.append(os.path.relpath(p, _REPO))
                    except OSError:
                        continue
        self.assertEqual(offenders, [],
                         "unexpected reference(s) to the maintainer-only script: "
                         "{}".format(offenders))


if __name__ == "__main__":
    unittest.main(verbosity=2)
