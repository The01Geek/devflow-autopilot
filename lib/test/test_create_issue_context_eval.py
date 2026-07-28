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
            # Issue #889 axes. The corpus carries no state file, so every per-kind /
            # scope-escape / post-filing / wall-clock figure reads `unestablished`
            # (never a number) and the auditor-cost median is 0 (no sidechain records).
            "median_attributed_auditor_cost": 0,
            "median_auditor_cost_discovery": "unestablished",
            "median_auditor_cost_targeted": "unestablished",
            "total_record_reopen": 0,
            "scope_escape": {"count": "unestablished", "unattributable": "unestablished"},
            "post_filing_escapes": "unestablished",
            "wall_clock": "unestablished",
        })


class RealisticFixtureTest(unittest.TestCase):
    def test_realistic_transcript_excerpt_is_processed(self):
        # Issue #767 AC: the parser processes a real transcript excerpt. These values
        # are the parser's actual output over the committed fixture (verified live), not
        # hand-picked numbers.
        runs, skipped = CICE.eval_corpus(os.path.join(_FIX, "realistic"))
        self.assertEqual(len(runs), 1)
        r = runs[0]
        self.assertEqual(r["peak_context"], 125500)
        self.assertEqual(r["compact_boundary_count"], 1)
        self.assertEqual(r["repeated_read_count"], 0)
        # The isSidechain assistant record is excluded from the attributed turn count.
        self.assertEqual(r["turn_count"], 2)
        self.assertEqual(sum(skipped.values()), 0)


class ReductionDetectionTest(unittest.TestCase):
    def test_after_fixture_has_strictly_lower_peak_and_reemission(self):
        # Proves the eval DETECTS a modeled reduction (passes by construction; NOT a
        # claim that the shipped skill edit reduces real runs). The reemission_count
        # drop carries the real reduction signal; peak_context is the residency proxy.
        before, _ = CICE.eval_corpus(os.path.join(_FIX, "before"))
        after, _ = CICE.eval_corpus(os.path.join(_FIX, "after"))
        self.assertEqual(len(before), 1)
        self.assertEqual(len(after), 1)
        self.assertLess(after[0]["peak_context"], before[0]["peak_context"])
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

    def test_message_wrong_shape_does_not_detonate(self):
        # `message` as a truthy non-dict (a list here) must NOT raise AttributeError and
        # abort the corpus walk: the isinstance guard degrades it cleanly and the
        # following well-formed attributed record still processes.
        import sys
        saved = sys.stderr
        sys.stderr = io.StringIO()
        try:
            runs, skipped = self._run_one([
                '{"type":"assistant","attributionSkill":"devflow:create-issue",'
                '"message":["not","a","dict"]}',
                '{"type":"assistant","attributionSkill":"devflow:create-issue",'
                '"message":{"usage":{"input_tokens":9}}}',
            ])
        finally:
            sys.stderr = saved
        self.assertEqual(len(runs), 1)
        self.assertEqual(runs[0]["turn_count"], 2)
        self.assertEqual(runs[0]["peak_context"], 9)
        # No detonation: the isinstance guard handled the bad shape without a skip.
        self.assertEqual(sum(skipped.values()), 0)

    def test_read_block_input_wrong_shape_does_not_detonate(self):
        # A Read tool_use whose `input` is a list (not a dict) must not raise; the block
        # is skipped for path tracking and the walk completes with the record counted.
        import sys
        saved = sys.stderr
        sys.stderr = io.StringIO()
        try:
            runs, skipped = self._run_one([
                '{"type":"assistant","attributionSkill":"devflow:create-issue",'
                '"message":{"usage":{"input_tokens":3},"content":['
                '{"type":"tool_use","id":"u1","name":"Read","input":["not","a","dict"]}]}}',
                '{"type":"assistant","attributionSkill":"devflow:create-issue",'
                '"message":{"usage":{"input_tokens":5}}}',
            ])
        finally:
            sys.stderr = saved
        self.assertEqual(len(runs), 1)
        self.assertEqual(runs[0]["turn_count"], 2)
        self.assertEqual(sum(skipped.values()), 0)

    def test_defensive_dispatch_tallies_malformed_record(self):
        # Backstop for any record shape the isinstance guards do not anticipate: the
        # per-record try/except in eval_corpus tallies `malformed_record` and the walk
        # completes rather than aborting. We force the guarded path by monkeypatching an
        # observer to raise on a specific record, proving the dispatch-level guard tallies
        # and the following good record still processes.
        import sys
        original = CICE.RunAccumulator.observe_user

        def _boom(self, record):
            if record.get("boom"):
                raise TypeError("synthetic malformed record")
            return original(self, record)

        saved_stderr = sys.stderr
        sys.stderr = io.StringIO()
        CICE.RunAccumulator.observe_user = _boom
        try:
            runs, skipped = self._run_one([
                '{"type":"assistant","attributionSkill":"devflow:create-issue",'
                '"message":{"usage":{"input_tokens":4}}}',
                '{"type":"user","boom":true,"message":{"content":[]}}',
                '{"type":"assistant","attributionSkill":"devflow:create-issue",'
                '"message":{"usage":{"input_tokens":6}}}',
            ])
        finally:
            CICE.RunAccumulator.observe_user = original
            sys.stderr = saved_stderr
        self.assertEqual(len(runs), 1)
        self.assertEqual(runs[0]["turn_count"], 2)
        self.assertEqual(skipped["malformed_record"], 1)

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

    def test_symlink_escape_is_tallied_and_breadcrumbed(self):
        # The escape is not merely skipped from reading — it is TALLIED under
        # `escaped_path` and breadcrumbed to stderr, never silently dropped.
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
                err = io.StringIO()
                import sys
                saved = sys.stderr
                sys.stderr = err
                try:
                    runs, skipped = CICE.eval_corpus(corpus)
                finally:
                    sys.stderr = saved
                self.assertEqual(runs, [])
                self.assertEqual(skipped["escaped_path"], 1)
                self.assertIn("escape.jsonl", err.getvalue())

    def test_walk_error_is_recorded(self):
        # An os.walk that cannot descend a directory (permission denied) records the
        # error via the onerror callback under `walk_error` — default onerror=None
        # would swallow it silently.
        if hasattr(os, "geteuid") and os.geteuid() == 0:
            self.skipTest("running as root: chmod-based permission block is ineffective")
        with tempfile.TemporaryDirectory() as corpus:
            blocked = os.path.join(corpus, "blocked")
            os.makedirs(blocked)
            with open(os.path.join(blocked, "s.jsonl"), "w", encoding="utf-8") as fh:
                fh.write('{"type":"assistant","attributionSkill":"devflow:create-issue",'
                         '"message":{"usage":{"input_tokens":1}}}\n')
            os.chmod(blocked, 0o000)
            try:
                # Verify the host actually enforces the permission block; skip if not.
                try:
                    os.listdir(blocked)
                    self.skipTest("host does not enforce dir permission block")
                except OSError:
                    pass
                err = io.StringIO()
                import sys
                saved = sys.stderr
                sys.stderr = err
                try:
                    runs, skipped = CICE.eval_corpus(corpus)
                finally:
                    sys.stderr = saved
                self.assertEqual(skipped["walk_error"], 1)
                self.assertIn("blocked", err.getvalue())
            finally:
                os.chmod(blocked, 0o700)


class RoundAttributionTest(_SingleSessionMixin, unittest.TestCase):
    """Issue #889: sidechain (auditor) cost is attributed to transcript-derived rounds."""

    def test_sidechain_cost_attributed_to_current_round(self):
        runs, _ = self._run_one([
            '{"type":"assistant","attributionSkill":"devflow:create-issue",'
            '"message":{"usage":{"input_tokens":1},"content":['
            '{"type":"tool_use","name":"Bash","id":"b1",'
            '"input":{"command":"issue-audit-state.py record-dispatch --round 1 --kind discovery"}}]}}',
            '{"type":"assistant","isSidechain":true,"attributionSkill":"devflow:create-issue",'
            '"message":{"usage":{"input_tokens":100,"cache_read_input_tokens":200,'
            '"cache_creation_input_tokens":50,"output_tokens":10}}}',
        ])
        self.assertEqual(len(runs), 1)
        # The auditor cost is the full token total (context sub-fields + output).
        self.assertEqual(runs[0]["round_auditor_cost"], {1: 360})
        self.assertEqual(runs[0]["attributed_auditor_cost"], 360)
        # The sidechain record is NOT a main-thread turn.
        self.assertEqual(runs[0]["turn_count"], 1)

    def test_sidechain_before_any_dispatch_is_unrounded_not_round_one(self):
        # A sidechain turn before any record-dispatch marker cannot be keyed to a
        # round; it is held separately, never silently folded into round 1.
        runs, _ = self._run_one([
            '{"type":"assistant","isSidechain":true,"attributionSkill":"devflow:create-issue",'
            '"message":{"usage":{"input_tokens":7}}}',
            '{"type":"assistant","attributionSkill":"devflow:create-issue",'
            '"message":{"usage":{"input_tokens":1}}}',
        ])
        self.assertEqual(runs[0]["round_auditor_cost"], {})
        self.assertEqual(runs[0]["unrounded_auditor_cost"], 7)
        self.assertEqual(runs[0]["attributed_auditor_cost"], 7)

    def test_round_boundary_switches_on_new_dispatch(self):
        runs, _ = self._run_one([
            '{"type":"assistant","attributionSkill":"devflow:create-issue",'
            '"message":{"usage":{"input_tokens":1},"content":['
            '{"type":"tool_use","name":"Bash","id":"b1",'
            '"input":{"command":"issue-audit-state.py record-dispatch --round 1 --kind discovery"}}]}}',
            '{"type":"assistant","isSidechain":true,"attributionSkill":"devflow:create-issue",'
            '"message":{"usage":{"input_tokens":100}}}',
            '{"type":"assistant","attributionSkill":"devflow:create-issue",'
            '"message":{"usage":{"input_tokens":1},"content":['
            '{"type":"tool_use","name":"Bash","id":"b2",'
            '"input":{"command":"issue-audit-state.py record-dispatch --round 2 --kind targeted"}}]}}',
            '{"type":"assistant","isSidechain":true,"attributionSkill":"devflow:create-issue",'
            '"message":{"usage":{"input_tokens":40}}}',
        ])
        self.assertEqual(runs[0]["round_auditor_cost"], {1: 100, 2: 40})
        self.assertEqual(runs[0]["dispatch_rounds"], [1, 2])

    def test_record_reopen_counted(self):
        runs, _ = self._run_one([
            '{"type":"assistant","attributionSkill":"devflow:create-issue",'
            '"message":{"usage":{"input_tokens":1},"content":['
            '{"type":"tool_use","name":"Bash","id":"b1",'
            '"input":{"command":"issue-audit-state.py record-reopen --round 2 --finding 1.1"}}]}}',
        ])
        self.assertEqual(runs[0]["record_reopen_count"], 1)

    def test_non_create_issue_sidechain_not_attributed(self):
        runs, _ = self._run_one([
            '{"type":"assistant","attributionSkill":"devflow:create-issue",'
            '"message":{"usage":{"input_tokens":1},"content":['
            '{"type":"tool_use","name":"Bash","id":"b1",'
            '"input":{"command":"issue-audit-state.py record-dispatch --round 1 --kind discovery"}}]}}',
            '{"type":"assistant","isSidechain":true,"attributionSkill":"other-skill",'
            '"message":{"usage":{"input_tokens":9999}}}',
        ])
        self.assertEqual(runs[0]["attributed_auditor_cost"], 0)


class StateReaderBestEffortTest(unittest.TestCase):
    """Issue #889 AC8: every degraded state-file shape -> unestablished, never a crash."""

    def _state(self, payload):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            fh.write(payload)
            return fh.name

    def test_absent_state_is_none(self):
        self.assertIsNone(CICE.read_state(None))
        self.assertIsNone(CICE.read_state("/no/such/state.json"))

    def test_degraded_shapes_read_as_none(self):
        degraded = [
            "",                                   # empty
            "   \n",                              # whitespace-only
            "{ not json",                         # malformed
            "[1,2,3]",                            # not an object
            '{"rounds": "notalist"}',             # wrong-typed rounds container
            '{"rounds": [ "notanobject" ]}',      # a round that is not an object
            '{"rounds": [ {"round": 1} ]}',       # a round with no recognized kind
            '{"rounds": [ {"round": 1, "kind": "bogus"} ]}',  # unrecognized kind
            '{"rounds": [ {"round": true, "kind": "discovery"} ]}',  # bool round num
            '{"rounds": [ {"round": "x", "kind": "discovery"} ]}',  # non-int round num, valid kind
            '{"rounds": [ {"kind": "discovery"} ]}',  # missing round num, valid kind
        ]
        for payload in degraded:
            path = self._state(payload)
            self.assertIsNone(CICE.read_state(path),
                              "degraded payload should read as None: {!r}".format(payload))

    def test_degraded_state_makes_per_kind_and_scope_unestablished(self):
        runs, _ = CICE.eval_corpus(
            os.path.join(_FIX, "after-rounds"))
        summary = CICE.aggregate(runs, CICE.read_state("/no/such/state.json"))
        self.assertEqual(summary["median_auditor_cost_discovery"], "unestablished")
        self.assertEqual(summary["median_auditor_cost_targeted"], "unestablished")
        self.assertEqual(summary["scope_escape"],
                         {"count": "unestablished", "unattributable": "unestablished"})

    def test_valid_state_reads_rounds(self):
        state = CICE.read_state(os.path.join(_FIX, "states", "after-state.json"))
        self.assertIsNotNone(state)
        self.assertEqual(state[1]["kind"], "discovery")
        self.assertEqual(state[2]["kind"], "targeted")
        self.assertEqual(state[2]["scope"]["draft_lines"], [10, 50])


class PerKindAndProxyTest(unittest.TestCase):
    """Issue #889 AC6/AC9/AC11: per-kind medians and the three escaped-defect proxies."""

    def _summary(self, corpus, state_name):
        runs, _ = CICE.eval_corpus(os.path.join(_FIX, corpus))
        state = CICE.read_state(os.path.join(_FIX, "states", state_name))
        return runs, CICE.aggregate(runs, state)

    def test_per_kind_medians(self):
        _runs, summary = self._summary("after-rounds", "after-state.json")
        # discovery rounds: r1=139000, r3=50000 -> median 94500; targeted: r2=26800.
        self.assertEqual(summary["median_auditor_cost_discovery"], 94500)
        self.assertEqual(summary["median_auditor_cost_targeted"], 26800)

    def test_reopen_proxy(self):
        _runs, summary = self._summary("after-rounds", "after-state.json")
        self.assertEqual(summary["total_record_reopen"], 1)

    def test_scope_escape_proxy_and_denominator(self):
        _runs, summary = self._summary("after-rounds", "after-state.json")
        # One later-round finding (line 30) falls inside the earlier targeted [10,50]
        # scope; one later-round finding carries no draft line (unattributable).
        self.assertEqual(summary["scope_escape"], {"count": 1, "unattributable": 1})

    def test_post_filing_and_wall_clock_are_unestablished(self):
        _runs, summary = self._summary("after-rounds", "after-state.json")
        self.assertEqual(summary["post_filing_escapes"], "unestablished")
        self.assertEqual(summary["wall_clock"], "unestablished")

    def test_before_has_no_targeted_scope_so_zero_escapes(self):
        _runs, summary = self._summary("before-rounds", "before-state.json")
        self.assertEqual(summary["scope_escape"], {"count": 0, "unattributable": 0})
        self.assertEqual(summary["median_auditor_cost_targeted"], "unestablished")


class PairedDeltaTest(unittest.TestCase):
    """Issue #889 AC7/AC12: paired before/after deltas and the reduction inequality."""

    def _paired(self):
        return CICE.build_paired_report(
            os.path.join(_FIX, "before-rounds"),
            os.path.join(_FIX, "after-rounds"),
            os.path.join(_FIX, "states", "before-state.json"),
            os.path.join(_FIX, "states", "after-state.json"),
        )

    def test_reduction_detected_with_strict_inequality(self):
        report = self._paired()
        before_cost = report["before"]["runs"][0]["attributed_auditor_cost"]
        after_cost = report["after"]["runs"][0]["attributed_auditor_cost"]
        # The reduction is asserted LIVE from the committed fixtures with a strict
        # inequality, never from a transcribed figure.
        self.assertLess(after_cost, before_cost)

    def test_paired_delta_fields(self):
        report = self._paired()
        delta = report["delta"]
        self.assertEqual(set(delta), {
            "attributed_auditor_cost", "per_run_context", "round_count", "finding_count",
        })
        # Latency is deliberately NOT a delta field (wall-clock is unestablished).
        self.assertNotIn("latency", delta)
        self.assertLess(delta["attributed_auditor_cost"], 0)
        self.assertEqual(delta["finding_count"], 2)

    def test_paired_delta_omits_latency_even_in_json(self):
        report = self._paired()
        self.assertNotIn("latency", report["delta"])
        self.assertNotIn("wall_clock", report["delta"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
