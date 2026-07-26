#!/usr/bin/env python3
"""Regression tests for the opaque legacy mutation-pin census."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent
SCRIPT = HERE / "mutation-pin-census.py"
SPEC = importlib.util.spec_from_file_location("mutation_pin_census", SCRIPT)
assert SPEC and SPEC.loader
CENSUS = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CENSUS
SPEC.loader.exec_module(CENSUS)

AUDITED = (
    "lib/test/run.sh",
    "lib/test/modules/workflow-flight-recorder.sh",
    "lib/test/modules/review-and-fix-contract.sh",
    "lib/test/modules/create-issue-contract.sh",
    "lib/test/modules/capability-profiles.sh",
    "lib/test/modules/regenerate-artifacts.sh",
    "lib/test/modules/installer-wiring.sh",
    "lib/test/modules/harness-python-guards.sh",
    "lib/test/modules/prompt-extension-reader.sh",
    "lib/test/modules/review-trigger-helpers.sh",
    "lib/test/modules/review-stall-backstop.sh",
    "lib/test/modules/experiment-records.sh",
)
DEFINITIONS = (
    "assert_pin_red_under() { :; }\n"
    "devflow_module_pin_red_under() { :; }\n"
    "assert_count_red_under() { :; }\n"
    "_ra_conflict_red_under() { :; }\n"
)


class FixtureRepo:
    def __init__(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        for source in AUDITED:
            path = self.root / source
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("", encoding="utf-8")
        linter = self.root / "lib/test/pin-corpus-lint.py"
        values = ",\n        ".join(repr(path) for path in AUDITED)
        linter.write_text(
            "AUDITED_PIN_SOURCES = frozenset(\n"
            "    {\n"
            f"        {values},\n"
            "    }\n"
            ")\n",
            encoding="utf-8",
        )
        harness = self.root / "lib/test/module-harness.sh"
        harness.write_text(DEFINITIONS, encoding="utf-8")

    def close(self) -> None:
        self._tmp.cleanup()

    def write(self, relative: str, text: str) -> None:
        (self.root / relative).write_text(text, encoding="utf-8")

    def census(self):
        return CENSUS.build_census(self.root)


class MutationPinCensusTests(unittest.TestCase):
    def setUp(self) -> None:
        self.repo = FixtureRepo()

    def tearDown(self) -> None:
        self.repo.close()

    def test_real_tree_census_is_deterministic_and_nonvacuous(self) -> None:
        first = CENSUS.build_census(REPO_ROOT)
        second = CENSUS.build_census(REPO_ROOT)
        self.assertEqual(first, second)
        self.assertEqual(tuple(first.sources), tuple(sorted(AUDITED)))
        self.assertEqual(len(first.rows), 646)
        self.assertEqual(
            {helper: first.helper_count(helper) for helper in CENSUS.HELPERS},
            {
                "assert_pin_red_under": 543,
                "devflow_module_pin_red_under": 94,
                "assert_count_red_under": 4,
                "_ra_conflict_red_under": 5,
            },
        )
        self.assertRegex(first.master_sha256, r"^[0-9a-f]{64}$")
        self.assertEqual(
            first.master_sha256,
            hashlib.sha256(first.identity_bytes()).hexdigest(),
        )

    def test_identity_uses_path_helper_and_normalized_call_not_locator(self) -> None:
        source = AUDITED[1]
        self.repo.write(
            source,
            "devflow_module_pin_red_under 'name' \\\n"
            "  'literal' \\\n"
            "  's/x/y/' target\n",
        )
        result = self.repo.census()
        row = result.rows[0]
        self.assertEqual(row.path, source)
        self.assertEqual(row.helper, "devflow_module_pin_red_under")
        self.assertEqual(
            row.logical_call,
            "devflow_module_pin_red_under 'name' 'literal' 's/x/y/' target",
        )
        self.assertEqual((row.line_start, row.line_end), (1, 3))
        moved = CENSUS.CensusRow(
            path=row.path,
            helper=row.helper,
            logical_call=row.logical_call,
            line_start=40,
            line_end=42,
        )
        self.assertEqual(row.identity, moved.identity)

    def test_sorted_jsonl_and_tsv_are_deterministic(self) -> None:
        self.repo.write(
            AUDITED[2],
            "devflow_module_pin_red_under z z z z\n"
            "devflow_module_pin_red_under a a a a\n",
        )
        result = self.repo.census()
        jsonl = CENSUS.render_jsonl(result)
        tsv = CENSUS.render_tsv(result)
        self.assertEqual(jsonl, CENSUS.render_jsonl(self.repo.census()))
        self.assertEqual(tsv, CENSUS.render_tsv(self.repo.census()))
        objects = [json.loads(line) for line in jsonl.splitlines()]
        self.assertEqual(objects[-1], {"master_sha256": result.master_sha256})
        self.assertEqual(tsv.splitlines()[-1], f"# master_sha256\t{result.master_sha256}")
        self.assertLess(objects[0]["logical_call"], objects[1]["logical_call"])

    def test_missing_source_fails_closed(self) -> None:
        (self.repo.root / AUDITED[-1]).unlink()
        with self.assertRaisesRegex(CENSUS.CensusError, "missing audited source"):
            self.repo.census()

    def test_missing_or_duplicate_audited_population_entry_fails_closed(self) -> None:
        linter = self.repo.root / "lib/test/pin-corpus-lint.py"
        for population, message in (
            (AUDITED[:-1], "count disagreement"),
            ((*AUDITED, AUDITED[0]), "duplicate audited population entry"),
        ):
            values = ",\n        ".join(repr(path) for path in population)
            linter.write_text(
                "AUDITED_PIN_SOURCES = frozenset(\n"
                "    {\n"
                f"        {values},\n"
                "    }\n"
                ")\n",
                encoding="utf-8",
            )
            with self.subTest(message=message):
                with self.assertRaisesRegex(CENSUS.CensusError, message):
                    self.repo.census()

    def test_malformed_utf8_fails_closed(self) -> None:
        (self.repo.root / AUDITED[-1]).write_bytes(b"\xff")
        with self.assertRaisesRegex(CENSUS.CensusError, "UTF-8"):
            self.repo.census()

    def test_duplicate_identity_fails_closed(self) -> None:
        call = "devflow_module_pin_red_under n l m f\n"
        self.repo.write(AUDITED[2], call + call)
        with self.assertRaisesRegex(CENSUS.CensusError, "duplicate identity"):
            self.repo.census()

    def test_multiple_supported_calls_on_logical_line_fail_closed(self) -> None:
        self.repo.write(
            AUDITED[2],
            "devflow_module_pin_red_under a b c d; "
            "devflow_module_pin_red_under e f g h\n",
        )
        with self.assertRaisesRegex(CENSUS.CensusError, "multiple supported calls"):
            self.repo.census()

    def test_lexical_extracted_disagreement_fails_closed(self) -> None:
        self.repo.write(
            AUDITED[2],
            "command devflow_module_pin_red_under a b c d\n",
        )
        with self.assertRaisesRegex(CENSUS.CensusError, "lexical/extracted"):
            self.repo.census()

    def test_unexpected_and_duplicate_helper_definitions_fail_closed(self) -> None:
        (self.repo.root / "lib/test/module-harness.sh").unlink()
        with self.assertRaisesRegex(CENSUS.CensusError, "helper definition count"):
            self.repo.census()
        (self.repo.root / "lib/test/module-harness.sh").write_text(
            DEFINITIONS + "devflow_module_pin_red_under() { :; }\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(CENSUS.CensusError, "helper definition count"):
            self.repo.census()

    def test_unterminated_continuation_fails_closed(self) -> None:
        self.repo.write(AUDITED[3], "assert_pin_red_under a b c d \\")
        with self.assertRaisesRegex(CENSUS.CensusError, "continuation"):
            self.repo.census()

    def test_all_eight_pr819_synthetic_calls_are_opaque_rows(self) -> None:
        calls = [
            f"devflow_module_pin_red_under '819-{index}' 'literal-{index}' "
            f"'s/old-{index}/new-{index}/' target-{index}"
            for index in range(1, 9)
        ]
        self.repo.write(AUDITED[3], "\n".join(calls) + "\n")
        result = self.repo.census()
        self.assertEqual(len(result.rows), 8)
        self.assertEqual(
            {row.logical_call for row in result.rows},
            set(calls),
        )

    def test_census_does_not_spawn_or_interpret_mutation_tools(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn("subprocess", source)
        self.assertNotIn("sed ", source)
        self.assertNotIn("grep ", source)
        self.repo.write(
            AUDITED[4],
            "devflow_module_pin_red_under n l 'arbitrary opaque bytes' f\n",
        )
        with mock.patch.object(subprocess, "run", side_effect=AssertionError):
            self.assertEqual(len(self.repo.census().rows), 1)

    def test_cli_outputs_jsonl_and_tsv_with_master_digest(self) -> None:
        self.repo.write(AUDITED[5], "devflow_module_pin_red_under n l m f\n")
        for fmt in ("jsonl", "tsv"):
            proc = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--repo-root",
                    str(self.repo.root),
                    "--format",
                    fmt,
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("master_sha256", proc.stdout)


if __name__ == "__main__":
    unittest.main()
