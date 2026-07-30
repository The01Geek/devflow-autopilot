#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Focused tests for the issue-798 pin-corpus classifier."""

from __future__ import annotations

import csv
from collections import Counter
import importlib.util
import io
import json
import shlex
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
CLASSIFIER = HERE / "pin-corpus-classifier.py"


def load_classifier():
    spec = importlib.util.spec_from_file_location("pin_corpus_classifier", CLASSIFIER)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def encode_tracked_paths(paths: list[str]) -> bytes:
    """Encode Git paths without newline or platform line-ending ambiguity."""
    return b"".join(path.encode("utf-8") + b"\0" for path in paths)


class PinCorpusClassifierTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_classifier()

    def test_mechanical_bucket_boundaries_and_precedence(self):
        classify = self.mod.classify_mechanical
        self.assertEqual(
            "unclear",
            classify(None, (), (), config_keys=frozenset()),
        )
        self.assertEqual(
            "unclear",
            classify("missing", (), (), config_keys=frozenset()),
        )
        self.assertEqual(
            "suite-internal",
            classify(
                "inside",
                ("lib/test/fixture.txt",),
                (),
                config_keys=frozenset(),
            ),
        )
        self.assertEqual(
            "required-copy",
            classify(
                "copy",
                ("skills/receiving-code-review/SKILL.md", "docs/copy.md"),
                ("skills/receiving-code-review/SKILL.md", "docs/copy.md"),
                config_keys=frozenset(),
            ),
        )
        self.assertEqual(
            "generated",
            classify(
                "generated",
                ("scripts/workflow-flight-recorder-registry.json",),
                ("scripts/workflow-flight-recorder-registry.json",),
                config_keys=frozenset(),
            ),
        )
        self.assertEqual(
            "config-key",
            classify(
                "feature_flag",
                ("docs/config.md",),
                ("docs/config.md",),
                config_keys=frozenset({"feature_flag"}),
            ),
        )
        self.assertEqual(
            "prose-sole-copy",
            classify(
                "one",
                ("docs/one.md",),
                ("docs/one.md",),
                config_keys=frozenset(),
            ),
        )
        self.assertEqual(
            "prose-multi-copy",
            classify(
                "many",
                ("docs/one.md", "skills/x/SKILL.md", "README.md"),
                ("docs/one.md", "skills/x/SKILL.md", "README.md"),
                config_keys=frozenset(),
            ),
        )

    def test_boundary_path_fails_closed_and_boundary_is_not_mechanical(self):
        bucket = self.mod.classify_mechanical(
            "permissions: write",
            (".github/workflows/devflow.yml",),
            (".github/workflows/devflow.yml",),
            config_keys=frozenset({"permissions: write"}),
        )
        self.assertEqual("unclear", bucket)
        self.assertNotEqual("boundary", bucket)

    def test_site_extraction_reuses_helpers_and_physical_spans(self):
        source = """\
MAXI_SKILL="$LIB/maxi.md"
assert_pin_unique "plain" 'alpha' "$LIB/a.md"
assert_pin_red_on_removal \\
  "removal" \\
  'beta'
devflow_module_pin_unique "module unique" 'gamma' "$LIB/c.md"
devflow_module_pin_present "module present" 'delta' "$LIB/d.md"
# assert_pin_unique "comment" 'ignored' "$LIB/no.md"
assert_pin_unique() { :; }
"""
        rows = self.mod.extract_existence_sites(
            source,
            "lib/test/run.sh",
            "/repo/lib",
            {"MAXI_SKILL": "/__pin_corpus_runtime__/MAXI_SKILL"},
        )
        self.assertEqual(4, len(rows))
        self.assertEqual(
            [
                "assert_pin_unique",
                "assert_pin_red_on_removal",
                "devflow_module_pin_unique",
                "devflow_module_pin_present",
            ],
            [row.helper for row in rows],
        )
        self.assertEqual("plain", rows[0].assertion_name)
        self.assertEqual((2, 2), (rows[0].line_start, rows[0].line_end))
        self.assertEqual("lib/a.md", rows[0].resolved_target)
        self.assertEqual((3, 5), (rows[1].line_start, rows[1].line_end))
        self.assertTrue(rows[1].target_defaulted)
        self.assertEqual("/__pin_corpus_runtime__/MAXI_SKILL", rows[1].resolved_target)

    def test_module_private_presence_wrapper_is_a_census_site(self):
        # Break caught (issue #946): a module routing its pins through a private
        # presence wrapper had no census row at all, so the retirement gate could
        # not answer for any of them. A count-family wrapper must stay OUT, or
        # sites that were never existence pins would silently join the census.
        source = """\
_raf_pin_count() {
  grep -oF -- "$1" "$2" | grep -c .
}
_raf_pin_unique() {
  assert_eq "$1" "1" "$(_raf_pin_count "$2" "$3")"
}
raf_illegal_count() {
  pin_count 'fixed literal' "$1"
}
_raf_pin_unique "wrapped" 'alpha' "$LIB/a.md"
assert_pin_unique "plain" 'beta' "$LIB/b.md"
assert_eq "counted" "0" "$(raf_illegal_count "$LIB/c.md")"
"""
        helpers, specs = self.mod.source_existence_helpers(source)
        self.assertIn("_raf_pin_unique", helpers)
        self.assertNotIn("_raf_pin_count", helpers)
        self.assertNotIn("raf_illegal_count", helpers)
        # The sibling suffix earns the same admission — the convention is the pair,
        # not just the one member review-and-fix-contract.sh happens to use.
        present_helpers, present_specs = self.mod.source_existence_helpers(
            "_mod_pin_present() {\n"
            '  assert_eq "$1" "yes" "$(grep_present "$2" "$3")"\n'
            "}\n"
            "_mod_pin_present \"named\" 'gamma' \"$LIB/g.md\"\n"
        )
        self.assertIn("_mod_pin_present", present_helpers)
        self.assertEqual((1, 2, None), present_specs["_mod_pin_present"])
        self.assertEqual((1, 2, None), specs["_raf_pin_unique"])
        rows = self.mod.extract_existence_sites(
            source, "lib/test/modules/example.sh", "/repo/lib", {}
        )
        self.assertEqual(
            ["_raf_pin_unique", "assert_pin_unique"], [row.helper for row in rows]
        )
        self.assertEqual("wrapped", rows[0].assertion_name)
        self.assertEqual("alpha", rows[0].literal)
        self.assertEqual("lib/a.md", rows[0].resolved_target)
        self.assertFalse(rows[0].target_defaulted)
        self.assertEqual(
            "lib/test/modules/review-and-fix-contract.sh",
            self.mod.PIN_CORPUS_SOURCES[-1],
        )

    def test_presence_suffixed_fixed_literal_wrapper_is_rejected_at_the_seam(self):
        # A wrapper whose NAME claims the presence convention but whose inferred
        # spec carries a fixed literal instead of a positional index cannot be
        # resolved by the shared extraction pass, which skips it. Admitting it
        # would make the two passes disagree and surface as a cardinality
        # "mismatch" naming the wrong cause; dropping it silently would let its
        # pins escape the census. Both are wrong, so admission raises — and the
        # message must name the wrapper and the shape it needs.
        source = """\
_bad_pin_unique() {
  pin_count 'a fixed literal' "$1"
}
_bad_pin_unique "$LIB/x.md"
"""
        with self.assertRaises(ValueError) as caught:
            self.mod.source_existence_helpers(source)
        message = str(caught.exception)
        self.assertIn("_bad_pin_unique", message)
        self.assertIn("fixed-literal spec", message)
        # Negative control: the same body under a name outside the suffix set is
        # simply not a presence wrapper, and must NOT raise.
        helpers, _ = self.mod.source_existence_helpers(
            source.replace("_bad_pin_unique", "_bad_counter")
        )
        self.assertNotIn("_bad_counter", helpers)

    def test_override_name_recovery_binds_synthetic_nontracked_paths(self):
        source = """\
_PCL_ARGS=(
  --var "MAXI_SKILL=$MAXI_BUNDLE"
  --var "REPO_ROOT=$SOMETHING"
)
assert_pin_unique "x" 'literal' "$REPO_ROOT/docs/file.md"
"""
        overrides = self.mod.recover_override_names(source)
        self.assertEqual(
            "/__pin_corpus_runtime__/MAXI_SKILL", overrides["MAXI_SKILL"]
        )
        self.assertEqual(
            "/__pin_corpus_runtime__/REPO_ROOT", overrides["REPO_ROOT"]
        )

    def test_command_substitution_pin_counts_are_found(self):
        source = """\
assert_eq "count one" 1 "$(pin_count 'a (b)' "$LIB/a.md")"
assert_eq "count two" 1 "$(devflow_module_pin_count '--lead' "$LIB/b.md")"
"""
        counts = self.mod.extract_exact_count_literals(source, "/repo/lib", {})
        self.assertEqual({"a (b)": 1, "--lead": 1}, counts)

    def test_tsv_cells_are_json_encoded_and_round_trip_adversarial_text(self):
        values = ["--leading", "tab\tinside", "line\ninside", "quote'\"inside", r"a\b"]
        encoded = [self.mod.encode_cell(value) for value in values]
        self.assertEqual(values, [json.loads(value) for value in encoded])
        output = io.StringIO()
        writer = csv.writer(output, delimiter="\t", lineterminator="\n")
        writer.writerow(encoded)
        self.assertEqual(encoded, next(csv.reader(io.StringIO(output.getvalue()), delimiter="\t")))

    def test_literal_entanglements_include_mutation_counts_and_regions(self):
        source = """\
# PARKCAL_GUARD_REGION_BEGIN
assert_pin_unique "existence" 'shared literal' "$LIB/a.md"
assert_pin_red_under "mutation" 'shared literal' 's/x/y/' "$LIB/a.md"
# PARKCAL_GUARD_REGION_END
"""
        mutations = self.mod._mutation_counts(
            {"lib/test/run.sh": source}, "/repo/lib", {}
        )
        self.assertEqual(Counter({"shared literal": 1}), mutations)
        ranges = self.mod._region_ranges(source)
        site = self.mod.extract_existence_sites(
            source, "lib/test/run.sh", "/repo/lib", {}
        )[0]
        self.assertEqual("park-calibration", self.mod._region_for(site, ranges))

    def test_adjudications_fail_closed_and_project_per_literal(self):
        key = self.mod.literal_adjudication_key("same literal")
        parsed = self.mod.parse_adjudications(
            f"adjudication_key\tbucket_final\trationale\n"
            f"{key}\tboundary\t security interface contract \n"
        )
        self.assertEqual(
            ("boundary", " security interface contract "),
            parsed[key],
        )
        with self.assertRaisesRegex(ValueError, "duplicate key"):
            self.mod.parse_adjudications(
                "adjudication_key\tbucket_final\trationale\n"
                f"{key}\tboundary\tone\n"
                f"{key}\tboundary\ttwo\n"
            )
        with self.assertRaisesRegex(ValueError, "invalid final bucket"):
            self.mod.parse_adjudications(
                "adjudication_key\tbucket_final\trationale\n"
                f"{key}\tunclear\tstill unclear\n"
            )
        for invalid in (
            (
                "bucket_final\tadjudication_key\trationale\n"
                f"boundary\t{key}\treordered\n"
            ),
            f"adjudication_key\tbucket_final\trationale\n{key}\tboundary\twhy\textra\n",
            (
                "adjudication_key\tbucket_final\trationale\n"
                f"tombstone:{key}\ttombstone\tretired\n"
            ),
            (
                "adjudication_key\tbucket_final\trationale\n"
                f"supersede:{key}\tboundary\treplacement\n"
            ),
        ):
            with self.subTest(invalid=invalid):
                with self.assertRaises(ValueError):
                    self.mod.parse_adjudications(invalid)

    def test_complete_explicit_source_scope_canonicalizes_to_default_command(self):
        remaining = ["--repo-root", ".", "--output", "inventory.tsv"]
        explicit = []
        for source in self.mod.DEFAULT_SOURCES:
            explicit.extend(("--source", source))
        self.assertEqual(
            remaining,
            self.mod._canonical_command_argv(
                [*explicit, *remaining], self.mod.DEFAULT_SOURCES
            ),
        )
        self.assertEqual(
            ["--source", "lib/test/run.sh", *remaining],
            self.mod._canonical_command_argv(
                ["--source", "lib/test/run.sh", *remaining],
                ("lib/test/run.sh",),
            ),
        )

    def test_historical_tracked_path_fixture_is_nul_delimited(self):
        encoded = encode_tracked_paths(["plain/path", "legal\nnewline"])
        self.assertEqual(b"plain/path\0legal\nnewline\0", encoded)
        self.assertNotIn(b"\r", encoded)
        self.assertEqual(
            ["plain/path", "legal\nnewline"],
            [part.decode("utf-8") for part in encoded.split(b"\0") if part],
        )

    def test_cli_debundles_homes_applies_only_exact_count_exclusions(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "lib/test").mkdir(parents=True)
            (root / "docs").mkdir()
            (root / ".devflow/logs").mkdir(parents=True)
            (root / "skills/x").mkdir(parents=True)
            source = root / "lib/test/run.sh"
            source.write_text(
                """\
MAXI_SKILL="/tmp/runtime-bundle"
assert_pin_unique "one home" 'literal [one]' "$MAXI_SKILL"
assert_pin_red_on_removal "docs count" 'literal docs' "$MAXI_SKILL"
""",
                encoding="utf-8",
            )
            (root / "skills/x/SKILL.md").write_text("literal [one]\n", encoding="utf-8")
            (root / ".devflow/logs/history.txt").write_text(
                "literal [one]\n", encoding="utf-8"
            )
            (root / "skills/x/OTHER.md").write_text("literal docs\n", encoding="utf-8")
            (root / "docs/copy.md").write_text("literal docs\n", encoding="utf-8")
            tracked = root / "tracked.txt"
            tracked.write_text(
                "\n".join(
                    [
                        "lib/test/run.sh",
                        "skills/x/SKILL.md",
                        ".devflow/logs/history.txt",
                        "skills/x/OTHER.md",
                        "docs/copy.md",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            adjudications = root / "adjudications.tsv"
            adjudications.write_text(
                "adjudication_key\tbucket_final\trationale\n", encoding="utf-8"
            )
            output = root / "inventory.tsv"
            command = [
                sys.executable,
                str(CLASSIFIER),
                "--repo-root",
                str(root),
                "--source",
                "lib/test/run.sh",
                "--tracked-files",
                str(tracked),
                "--adjudications",
                str(adjudications),
                "--output",
                str(output),
                "--revision",
                "a" * 40,
                "--expected-out-of-scope",
                "0",
            ]
            result = subprocess.run(command, text=True, capture_output=True, check=False)
            self.assertEqual(0, result.returncode, result.stderr)
            data_lines = [
                line
                for line in output.read_text(encoding="utf-8").splitlines()
                if not line.startswith("#")
            ]
            rows = list(csv.DictReader(data_lines, delimiter="\t"))
            self.assertEqual(2, len(rows))
            self.assertEqual("prose-sole-copy", rows[0]["bucket_mechanical"])
            self.assertEqual(1, int(rows[0]["counted_occurrences"]))
            self.assertEqual("prose-multi-copy", rows[1]["bucket_mechanical"])
            self.assertEqual(2, int(rows[1]["counted_occurrences"]))
            self.assertEqual(
                [
                    ".devflow/logs/history.txt",
                    "lib/test/run.sh",
                    "skills/x/SKILL.md",
                ],
                json.loads(rows[0]["homes"]),
            )
            self.assertIn("total_sites=2", result.stderr)

    def test_cli_emits_all_four_entanglements_end_to_end(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "lib/test/modules").mkdir(parents=True)
            (root / "docs").mkdir()
            source = root / "lib/test/run.sh"
            source.write_text(
                """\
# PARKCAL_GUARD_REGION_BEGIN
assert_pin_unique "existence" 'shared literal' "$LIB/a.md"
assert_pin_red_under "mutation" 'shared literal' 's/x/y/' "$LIB/a.md"
assert_eq "nested count" 1 "$(printf '%s' "$(pin_count 'shared literal' "$LIB/a.md")")"
# PARKCAL_GUARD_REGION_END
""",
                encoding="utf-8",
            )
            outside = root / "lib/test/modules/installer-wiring.sh"
            outside.write_text(
                """\
devflow_module_pin_present "outside" 'shared literal' "$LIB/a.md"
devflow_module_pin_red_under "outside mutation" 'shared literal' 's/x/y/' "$LIB/a.md"
""",
                encoding="utf-8",
            )
            (root / "docs/home.md").write_text("shared literal\n", encoding="utf-8")
            tracked = root / "tracked.txt"
            tracked.write_text(
                "\n".join(
                    [
                        "docs/home.md",
                        "lib/test/run.sh",
                        "lib/test/modules/installer-wiring.sh",
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            adjudications = root / "adjudications.tsv"
            adjudications.write_text(
                "adjudication_key\tbucket_final\trationale\n", encoding="utf-8"
            )
            output = root / "inventory.tsv"
            result = subprocess.run(
                [
                    sys.executable,
                    str(CLASSIFIER),
                    "--repo-root",
                    str(root),
                    "--source",
                    "lib/test/run.sh",
                    "--tracked-files",
                    str(tracked),
                    "--adjudications",
                    str(adjudications),
                    "--output",
                    str(output),
                    "--revision",
                    "a" * 40,
                    "--expected-out-of-scope",
                    "1",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(0, result.returncode, result.stderr)
            data_lines = [
                line
                for line in output.read_text(encoding="utf-8").splitlines()
                if not line.startswith("#")
            ]
            row = next(csv.DictReader(data_lines, delimiter="\t"))
            self.assertEqual("2", row["mutation_pin_count"])
            self.assertEqual("1", row["exact_count_pin_count"])
            self.assertEqual("park-calibration", json.loads(row["registered_pin_region"]))
            self.assertEqual("1", row["out_of_scope_pin_count"])

    def test_revision_reads_git_tree_instead_of_live_worktree(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "lib/test").mkdir(parents=True)
            (root / "docs").mkdir()
            source = root / "lib/test/source.sh"
            source.write_text(
                "assert_pin_unique \"snapshot\" 'snapshot literal' \"$LIB/a.md\"\n",
                encoding="utf-8",
            )
            (root / "docs/home.md").write_text("snapshot literal\n", encoding="utf-8")
            adjudications = root / "adjudications.tsv"
            adjudications.write_text(
                "adjudication_key\tbucket_final\trationale\n", encoding="utf-8"
            )
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            subprocess.run(
                ["git", "config", "user.email", "fixture@example.invalid"],
                cwd=root,
                check=True,
            )
            subprocess.run(
                ["git", "config", "user.name", "Fixture"],
                cwd=root,
                check=True,
            )
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "snapshot"], cwd=root, check=True)
            revision = subprocess.run(
                ["git", "rev-parse", "HEAD"],
                cwd=root,
                text=True,
                capture_output=True,
                check=True,
            ).stdout.strip()
            source.write_text(
                "assert_pin_unique \"working\" 'working literal' \"$LIB/a.md\"\n",
                encoding="utf-8",
            )
            (root / "docs/home.md").write_text("working literal\n", encoding="utf-8")
            output = root / "inventory.tsv"
            result = subprocess.run(
                [
                    sys.executable,
                    str(CLASSIFIER),
                    "--repo-root",
                    str(root),
                    "--source",
                    "lib/test/source.sh",
                    "--adjudications",
                    str(adjudications),
                    "--output",
                    str(output),
                    "--revision",
                    revision,
                    "--expected-out-of-scope",
                    "0",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(0, result.returncode, result.stderr)
            data_lines = [
                line
                for line in output.read_text(encoding="utf-8").splitlines()
                if not line.startswith("#")
            ]
            row = next(csv.DictReader(data_lines, delimiter="\t"))
            self.assertEqual("snapshot literal", json.loads(row["literal"]))
            self.assertEqual(["docs/home.md", "lib/test/source.sh"], json.loads(row["homes"]))

    def test_failed_validation_does_not_replace_existing_inventory(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            (root / "lib/test").mkdir(parents=True)
            (root / ".github/workflows").mkdir(parents=True)
            (root / "lib/test/source.sh").write_text(
                "assert_pin_unique \"boundary\" 'permissions: write' \"$LIB/a.md\"\n",
                encoding="utf-8",
            )
            (root / ".github/workflows/example.yml").write_text(
                "permissions: write\n", encoding="utf-8"
            )
            tracked = root / "tracked.txt"
            tracked.write_text(
                "lib/test/source.sh\n.github/workflows/example.yml\n",
                encoding="utf-8",
            )
            adjudications = root / "adjudications.tsv"
            adjudications.write_text(
                "adjudication_key\tbucket_final\trationale\n", encoding="utf-8"
            )
            output = root / "inventory.tsv"
            output.write_text("previous complete inventory\n", encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable,
                    str(CLASSIFIER),
                    "--repo-root",
                    str(root),
                    "--source",
                    "lib/test/source.sh",
                    "--tracked-files",
                    str(tracked),
                    "--adjudications",
                    str(adjudications),
                    "--output",
                    str(output),
                    "--revision",
                    "a" * 40,
                    "--expected-out-of-scope",
                    "0",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(2, result.returncode)
            self.assertEqual(
                "previous complete inventory\n",
                output.read_text(encoding="utf-8"),
            )

    def test_frozen_inventory_matches_its_recorded_revision(self):
        repo_root = HERE.parent.parent
        inventory = repo_root / ".devflow/logs/pin-corpus-inventory.tsv"
        raw_lines = inventory.read_text(encoding="utf-8").splitlines()
        metadata = {}
        for line in raw_lines:
            if line.startswith("# "):
                key, _, value = line[2:].partition(": ")
                metadata[key] = value
        revision = metadata["revision"]
        self.assertRegex(revision, r"^[0-9a-f]{40}$")
        self.assertIn(f"--revision {revision}", metadata["producing-command"])
        self.assertEqual(
            self.mod.COUNTED_EXCLUSION_HEADER,
            metadata["counted-file-exclusions"],
        )
        self.assertEqual(";".join(self.mod.DEFAULT_SOURCES), metadata["in-scope"])
        self.assertEqual(
            "0 sites in 0 unselected candidate sources",
            metadata["out-of-scope"],
        )
        # This alternation is an INDEPENDENT restatement of the census's
        # existence-helper population, so it names each helper literally rather
        # than importing the module's own set. `_raf_pin_unique` is
        # review-and-fix-contract.sh's module-private presence wrapper (issue
        # #946); the trailing `[[:space:]]` keeps its `_raf_pin_unique()`
        # definition line out of the count, since only call sites are census rows.
        grep = subprocess.run(
            [
                "git",
                "grep",
                "-nE",
                (
                    "^[[:space:]]*(assert_pin_unique|assert_pin_red_on_removal|"
                    "devflow_module_pin_unique|devflow_module_pin_present|"
                    "_raf_pin_unique)"
                    "[[:space:]]"
                ),
                revision,
                "--",
                *self.mod.DEFAULT_SOURCES,
            ],
            cwd=repo_root,
            text=True,
            capture_output=True,
            check=True,
        )
        expected = len(grep.stdout.splitlines())
        data_lines = [line for line in raw_lines if not line.startswith("#")]
        rows = list(csv.DictReader(data_lines, delimiter="\t"))
        self.assertEqual(expected, len(rows))
        inventory_path = inventory.relative_to(repo_root).as_posix()
        for row in rows:
            self.assertNotIn(inventory_path, json.loads(row["homes"]))
        self.assertEqual(
            {
                "suite-internal",
                "required-copy",
                "boundary",
                "generated",
                "config-key",
                "prose-sole-copy",
                "prose-multi-copy",
                "unclear",
            },
            self.mod.MECHANICAL_BUCKETS,
        )
        self.assertEqual(
            self.mod.MECHANICAL_BUCKETS - {"unclear"}, self.mod.FINAL_BUCKETS
        )
        self.assertTrue(
            {row["bucket_mechanical"] for row in rows}
            <= self.mod.MECHANICAL_BUCKETS
        )
        self.assertTrue(
            {row["bucket_final"] for row in rows} <= self.mod.FINAL_BUCKETS
        )
        self.assertNotIn("unclear", {row["bucket_final"] for row in rows})
        literal_buckets = {}
        for row in rows:
            literal = json.loads(row["literal"])
            if literal is not None:
                literal_buckets.setdefault(literal, set()).add(row["bucket_final"])
        self.assertTrue(all(len(buckets) == 1 for buckets in literal_buckets.values()))
        for boundary_literal in (
            "whether by a Phase-3 review finding **or by the issue",
            (
                '"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner '
                'reports in context>}"/../../scripts/config-get.sh .docs.internal'
            ),
        ):
            self.assertEqual({"boundary"}, literal_buckets[boundary_literal])
        self.assertNotIn(str(repo_root), inventory.read_text(encoding="utf-8"))

        with tempfile.TemporaryDirectory() as raw:
            scratch = Path(raw)
            reproduced = scratch / "inventory.tsv"
            command = shlex.split(metadata["producing-command"])
            archive = subprocess.run(
                ["git", "archive", "--format=tar", revision],
                cwd=repo_root,
                capture_output=True,
                check=True,
            ).stdout
            tracked_paths = []
            with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as tar:
                for member in tar:
                    if not member.isfile():
                        continue
                    extracted = tar.extractfile(member)
                    self.assertIsNotNone(extracted)
                    destination = scratch / member.name
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.write_bytes(extracted.read())
                    tracked_paths.append(member.name)
            for relative in (
                "lib/test/pin-corpus-classifier.py",
                "lib/test/pin-corpus-lint.py",
                "lib/test/pin-corpus-adjudications.tsv",
            ):
                self.assertIn(relative, tracked_paths)
            tracked = scratch / "tracked-files.txt"
            tracked.write_bytes(encode_tracked_paths(tracked_paths))
            command[1] = str(scratch / "lib/test/pin-corpus-classifier.py")
            repo_index = command.index("--repo-root") + 1
            command[repo_index] = str(scratch)
            adjudications_index = command.index("--adjudications") + 1
            command[adjudications_index] = str(
                scratch / "lib/test/pin-corpus-adjudications.tsv"
            )
            output_index = command.index("--output") + 1
            command[output_index] = str(reproduced)
            command.extend(("--tracked-files", str(tracked)))
            result = subprocess.run(
                command,
                cwd=scratch,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(0, result.returncode, result.stderr)
            reproduced_lines = reproduced.read_text(encoding="utf-8").splitlines()
            producing_index = next(
                index
                for index, line in enumerate(reproduced_lines)
                if line.startswith("# producing-command: ")
            )
            reproduced_lines[producing_index] = (
                f"# producing-command: {metadata['producing-command']}"
            )
            self.assertEqual(raw_lines, reproduced_lines)

if __name__ == "__main__":
    unittest.main()
