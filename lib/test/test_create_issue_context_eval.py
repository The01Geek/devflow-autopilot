#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Focused unit + reduction-detection tests for scripts/create-issue-context-eval.py.

Every acceptance criterion of issue #767 that the eval or its committed fixtures can
witness maps to at least one assertion here (the orchestrator-instruction reduction's
preservation is discharged separately by a code-reading obligation + reproducible
check recorded in docs/create-issue-context.md — no issue-audit-state.py-driven suite
test can witness it). Driven serially from lib/test/run.sh.
"""

import importlib.util
import io
import os
import re
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.abspath(os.path.join(_HERE, "..", ".."))
_EVAL_PATH = os.path.join(_REPO, "scripts", "create-issue-context-eval.py")
_FIX = os.path.join(_HERE, "fixtures", "create-issue-eval")


def _load_eval():
    spec = importlib.util.spec_from_file_location("cice", _EVAL_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


CICE = _load_eval()


def _write(dirpath, name, lines):
    os.makedirs(dirpath, exist_ok=True)
    with open(os.path.join(dirpath, name), "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


# Owner-specific / transcript-content shapes that must never appear in a committed
# file this change adds (the eval, the determination doc, the synthetic fixtures).
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
        # Positive control: the planted fixture MUST trip the detector, proving it
        # catches the shape it guards rather than merely passing on a clean tree.
        planted = os.path.join(_FIX, "planted-owner-id.txt")
        with open(planted, encoding="utf-8") as fh:
            hits = _scan_for_secrets(fh.read())
        self.assertTrue(hits, "planted positive control did not trip the secret detector")

    def test_added_files_are_clean(self):
        # The clean scan covers the eval, the determination doc, and every fixture,
        # excluding the positive-control file by name.
        targets = [_EVAL_PATH, os.path.join(_REPO, "docs", "create-issue-context.md")]
        for dirpath, _dirs, files in os.walk(_FIX):  # tree-walk-ok: rooted at the fixed committed create-issue-eval fixtures subdir, not the repo root — never descends into sibling worktrees
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


class MissingCorpusTest(unittest.TestCase):
    def test_missing_corpus_exits_nonzero_naming_path(self):
        err = io.StringIO()
        import sys
        saved = sys.stderr
        sys.stderr = err
        try:
            rc = CICE.main(["/no/such/corpus/here"])
        finally:
            sys.stderr = saved
        self.assertEqual(rc, 2)
        self.assertIn("/no/such/corpus/here", err.getvalue())


class HappyPathTest(unittest.TestCase):
    def test_per_run_fields(self):
        runs, skipped = CICE.eval_corpus(os.path.join(_FIX, "corpus"))
        self.assertEqual(len(runs), 3)
        by = {r["source"]: r for r in runs}
        self.assertEqual(by["run-c.jsonl"]["turn_count"], 4)
        self.assertEqual(by["run-c.jsonl"]["peak_context"], 250000)
        self.assertEqual(by["run-c.jsonl"]["repeated_read_count"], 3)
        self.assertEqual(by["run-b.jsonl"]["reemission_count"], 1)
        self.assertEqual(sum(skipped.values()), 0)

    def test_fixture_derived_aggregate_is_ci_reconcilable(self):
        # The CI-reconcilable companion figure: re-derived live from committed
        # synthetic transcripts (distinct from the corpus-derived snapshot in the doc).
        runs, _ = CICE.eval_corpus(os.path.join(_FIX, "corpus"))
        summary = CICE.aggregate(runs)
        self.assertEqual(summary, {
            "run_count": 3,
            "median_peak_context": 64000,
            "max_peak_context": 250000,
            "runs_over_200k": 1,
            "runs_over_400k": 0,
            "median_repeated_read_count": 0,
            "median_reemission_count": 0,
        })


class ReductionDetectionTest(unittest.TestCase):
    def test_after_fixture_has_strictly_lower_resident_total(self):
        # Proves the eval DETECTS a modeled reduction (passes by construction; NOT a
        # claim that the shipped skill edit reduces real runs).
        before, _ = CICE.eval_corpus(os.path.join(_FIX, "before"))
        after, _ = CICE.eval_corpus(os.path.join(_FIX, "after"))
        self.assertEqual(len(before), 1)
        self.assertEqual(len(after), 1)
        self.assertLess(after[0]["resident_total"], before[0]["resident_total"])
        self.assertLess(after[0]["reemission_count"], before[0]["reemission_count"])


class _SingleSessionMixin:
    """Shared helper: run the eval over a one-session temp corpus built from `lines`."""

    def _run_one(self, lines):
        with tempfile.TemporaryDirectory() as d:
            _write(d, "s.jsonl", lines)
            return CICE.eval_corpus(d)


class BoundaryTest(_SingleSessionMixin, unittest.TestCase):
    def test_zero_attributed_turns_emits_no_run(self):
        runs, _ = self._run_one([
            '{"type":"assistant","attributionSkill":"other","message":{"usage":{"input_tokens":5}}}',
        ])
        self.assertEqual(runs, [])

    def test_one_turn_run(self):
        runs, _ = self._run_one([
            '{"type":"assistant","attributionSkill":"devflow:create-issue",'
            '"message":{"usage":{"input_tokens":10,"cache_read_input_tokens":20,'
            '"cache_creation_input_tokens":0,"output_tokens":3}}}',
        ])
        self.assertEqual(len(runs), 1)
        self.assertEqual(runs[0]["turn_count"], 1)
        self.assertEqual(runs[0]["peak_context"], 30)

    def test_null_usage_subfield_treated_as_zero(self):
        runs, _ = self._run_one([
            '{"type":"assistant","attributionSkill":"devflow:create-issue",'
            '"message":{"usage":{"input_tokens":null,"cache_read_input_tokens":7}}}',
        ])
        self.assertEqual(runs[0]["peak_context"], 7)

    def test_sidechain_excluded(self):
        runs, _ = self._run_one([
            '{"type":"assistant","isSidechain":true,"attributionSkill":"devflow:create-issue",'
            '"message":{"usage":{"input_tokens":999}}}',
        ])
        self.assertEqual(runs, [])

    def test_compaction_counted(self):
        runs, _ = self._run_one([
            '{"type":"system","subtype":"compact_boundary"}',
            '{"type":"assistant","attributionSkill":"devflow:create-issue",'
            '"message":{"usage":{"input_tokens":1}}}',
        ])
        self.assertEqual(runs[0]["compact_boundary_count"], 1)

    def test_changed_content_reread_not_counted(self):
        # Two Reads of the same path whose content CHANGED between reads: authoritative.
        runs, _ = self._run_one([
            '{"type":"assistant","attributionSkill":"devflow:create-issue",'
            '"message":{"usage":{"input_tokens":1},"content":['
            '{"type":"tool_use","id":"u1","name":"Read","input":{"file_path":"/x"}}]}}',
            '{"type":"user","message":{"content":['
            '{"type":"tool_result","tool_use_id":"u1","content":"AAAA"}]}}',
            '{"type":"assistant","attributionSkill":"devflow:create-issue",'
            '"message":{"usage":{"input_tokens":1},"content":['
            '{"type":"tool_use","id":"u2","name":"Read","input":{"file_path":"/x"}}]}}',
            '{"type":"user","message":{"content":['
            '{"type":"tool_result","tool_use_id":"u2","content":"BBBB-changed"}]}}',
        ])
        self.assertEqual(runs[0]["repeated_read_count"], 0)

    def test_identical_content_reread_counted(self):
        runs, _ = self._run_one([
            '{"type":"assistant","attributionSkill":"devflow:create-issue",'
            '"message":{"usage":{"input_tokens":1},"content":['
            '{"type":"tool_use","id":"u1","name":"Read","input":{"file_path":"/x"}}]}}',
            '{"type":"user","message":{"content":['
            '{"type":"tool_result","tool_use_id":"u1","content":"SAME"}]}}',
            '{"type":"assistant","attributionSkill":"devflow:create-issue",'
            '"message":{"usage":{"input_tokens":1},"content":['
            '{"type":"tool_use","id":"u2","name":"Read","input":{"file_path":"/x"}}]}}',
            '{"type":"user","message":{"content":['
            '{"type":"tool_result","tool_use_id":"u2","content":"SAME"}]}}',
        ])
        self.assertEqual(runs[0]["repeated_read_count"], 1)

    def _reread_second_result_block(self, second_result_block):
        # Two Reads of the same path; the SECOND result carries `second_result_block`
        # verbatim. Returns the run so a caller can assert repeated_read_count.
        runs, _ = self._run_one([
            '{"type":"assistant","attributionSkill":"devflow:create-issue",'
            '"message":{"usage":{"input_tokens":1},"content":['
            '{"type":"tool_use","id":"u1","name":"Read","input":{"file_path":"/x"}}]}}',
            '{"type":"user","message":{"content":['
            '{"type":"tool_result","tool_use_id":"u1","content":"SAME"}]}}',
            '{"type":"assistant","attributionSkill":"devflow:create-issue",'
            '"message":{"usage":{"input_tokens":1},"content":['
            '{"type":"tool_use","id":"u2","name":"Read","input":{"file_path":"/x"}}]}}',
            '{"type":"user","message":{"content":[' + second_result_block + ']}}',
        ])
        return runs

    def test_truncated_toolresult_fails_closed(self):
        # A repeated Read whose tool_result content is truncated is NOT folded into the
        # redundant count (fail closed -> authoritative).
        runs = self._reread_second_result_block(
            '{"type":"tool_result","tool_use_id":"u2","content":"SAME","truncated":true}'
        )
        self.assertEqual(runs[0]["repeated_read_count"], 0)

    def test_errored_toolresult_fails_closed(self):
        # An errored tool_result (`is_error: true`) is non-authoritative: a repeat of
        # its bytes must NOT be counted as a redundant repeated-Read.
        runs = self._reread_second_result_block(
            '{"type":"tool_result","tool_use_id":"u2","content":"SAME","is_error":true}'
        )
        self.assertEqual(runs[0]["repeated_read_count"], 0)

    def test_absent_content_toolresult_fails_closed(self):
        # A tool_result with no `content` key (missing/absent) yields None from the
        # comparand extractor -> authoritative, never redundant.
        runs = self._reread_second_result_block(
            '{"type":"tool_result","tool_use_id":"u2"}'
        )
        self.assertEqual(runs[0]["repeated_read_count"], 0)

    def test_nontext_content_toolresult_fails_closed(self):
        # A tool_result whose content is a list containing a non-text (image) block
        # cannot be asserted byte-identical -> fail closed (authoritative).
        runs = self._reread_second_result_block(
            '{"type":"tool_result","tool_use_id":"u2","content":['
            '{"type":"image","source":{}}]}'
        )
        self.assertEqual(runs[0]["repeated_read_count"], 0)


class AdversarialTest(_SingleSessionMixin, unittest.TestCase):
    def test_malformed_records_degrade_and_are_reported(self):
        runs, skipped = self._run_one([
            'not json at all',
            '["a","list","not","an","object"]',
            '{"no":"type field"}',
            '{"type":"assistant","attributionSkill":"devflow:create-issue",'
            '"message":{"usage":{"input_tokens":4}}}',
            '{"type":"assistant","attributionSkill":"devflow:create-issue"',  # truncated line
        ])
        self.assertEqual(len(runs), 1)
        self.assertEqual(runs[0]["turn_count"], 1)
        self.assertEqual(skipped["non_json_line"], 2)  # 'not json' + truncated
        self.assertEqual(skipped["not_object"], 1)
        self.assertEqual(skipped["no_type"], 1)

    def test_unreadable_session_file_is_tallied(self):
        # A file the walker enumerates but cannot open (here a broken symlink whose
        # target is inside the corpus root so it passes the escape guard, then fails
        # to open) is tallied under `unreadable_file`, never silently dropped.
        with tempfile.TemporaryDirectory() as corpus:
            link = os.path.join(corpus, "broken.jsonl")
            try:
                os.symlink(os.path.join(corpus, "missing-target.jsonl"), link)
            except (OSError, NotImplementedError):
                self.skipTest("symlinks unavailable on this host")
            err = io.StringIO()
            import sys
            saved = sys.stderr
            sys.stderr = err
            try:
                runs, skipped = CICE.eval_corpus(corpus)
            finally:
                sys.stderr = saved
            self.assertEqual(runs, [])
            self.assertEqual(skipped["unreadable_file"], 1)
            self.assertIn("broken.jsonl", err.getvalue())

    def test_determinism(self):
        # Re-running over the same corpus yields byte-identical output.
        a, sa = CICE.eval_corpus(os.path.join(_FIX, "corpus"))
        b, sb = CICE.eval_corpus(os.path.join(_FIX, "corpus"))
        self.assertEqual(a, b)
        self.assertEqual(sa, sb)


class SecurityTest(unittest.TestCase):
    def test_symlink_escape_is_not_read(self):
        with tempfile.TemporaryDirectory() as outside:
            with open(os.path.join(outside, "secret.jsonl"), "w", encoding="utf-8") as fh:
                fh.write('{"type":"assistant","attributionSkill":"devflow:create-issue",'
                         '"message":{"usage":{"input_tokens":7}}}\n')
            with tempfile.TemporaryDirectory() as corpus:
                link = os.path.join(corpus, "escape.jsonl")
                try:
                    os.symlink(os.path.join(outside, "secret.jsonl"), link)
                except (OSError, NotImplementedError):
                    self.skipTest("symlinks unavailable on this host")
                runs, _ = CICE.eval_corpus(corpus)
                self.assertEqual(runs, [], "eval read a file outside the corpus root")


if __name__ == "__main__":
    unittest.main(verbosity=2)
