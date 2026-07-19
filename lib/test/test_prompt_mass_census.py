# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Behavioral fixtures for prompt-mass-census.py (issue #551)."""

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
SCRIPT = ROOT / "lib/test/prompt-mass-census.py"
CLASSIFICATION_RULE = (
    "Files loaded unconditionally on any flow's normal path are mandatory; "
    "reference is reserved for genuinely conditional rare-path files."
)


class PromptMassCensusTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def write(self, relative: str, text: str) -> Path:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def write_json(self, relative: str, value: object) -> Path:
        return self.write(relative, json.dumps(value, indent=2) + "\n")

    def manifest(
        self,
        files: list[str],
        *,
        group_class: str = "mandatory",
        group_name: str = "fixture-flow",
    ) -> dict[str, object]:
        return {
            "version": 1,
            "classification_rule": CLASSIFICATION_RULE,
            "groups": {
                group_name: {
                    "class": group_class,
                    "files": files,
                }
            },
        }

    def baseline(self, files: list[str]) -> dict[str, object]:
        return {
            "version": 1,
            "files": {
                relative: os.path.getsize(self.root / relative) for relative in files
            },
        }

    def seed_single(self, text: str = "abc\n") -> str:
        relative = "skills/fixture/SKILL.md"
        self.write(relative, text)
        self.write_json("manifest.json", self.manifest([relative]))
        self.write_json("baseline.json", self.baseline([relative]))
        return relative

    def run_census(self, *extra: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--root",
                str(self.root),
                "--manifest",
                "manifest.json",
                "--baseline",
                "baseline.json",
                *extra,
            ],
            check=False,
            capture_output=True,
            text=True,
        )

    def assert_failed_with(self, result: subprocess.CompletedProcess[str], *parts: str) -> None:
        self.assertNotEqual(result.returncode, 0, result.stdout)
        combined = result.stdout + result.stderr
        for part in parts:
            self.assertIn(part, combined)

    def valid_artifact(self, kind: str) -> str:
        headings = {
            "cutover": [
                ("Files", "- `skills/fixture/SKILL.md`"),
                ("Consuming paths", "- local, cloud review, cloud implement"),
                ("Branch coverage", "- `test_all_helper_arms`"),
                ("Grants and probes", "- existing probe-proven invocation"),
                ("Shipping coupling", "- no vendored boundary"),
                ("Mutation evidence", "- planted defect turns the suite red"),
                ("Pin disposition", "- old pin -> `test_all_helper_arms`"),
            ],
            "trim": [
                ("Files", "- `skills/fixture/SKILL.md`"),
                ("Rationale", "- Remove repetition."),
                ("Ownership", "- No ownership change."),
            ],
            "growth": [
                ("Files", "- `skills/fixture/SKILL.md`"),
                ("Justification", "- The new gate is mandatory."),
            ],
            "relocate": [
                ("Source rows", "- `skills/fixture/SKILL.md`"),
                ("Destinations", "- `skills/fixture/reference.md` in `rare`"),
            ],
        }[kind]
        body = "\n\n".join(f"## {heading}\n{content}" for heading, content in headings)
        return f"---\nschema: 1\nkind: {kind}\n---\n\n{body}\n"

    def test_t1_growth_reports_direction_delta_rows_and_remedy(self) -> None:
        relative = self.seed_single()
        self.write(relative, "abcdef\n")
        result = self.run_census()
        self.assert_failed_with(
            result,
            relative,
            "growth",
            "+3 bytes",
            '"files": {',
            '"skills/fixture/SKILL.md": 7',
            '.devflow/prompt-extensions/implement.md "Prose cutover"',
        )

    def test_t2_exact_match_passes_and_reports_group_totals(self) -> None:
        self.seed_single()
        result = self.run_census()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("fixture-flow [mandatory]: 4 bytes", result.stdout)

    def test_t3_reduction_reports_direction_and_delta(self) -> None:
        relative = self.seed_single("abcdef\n")
        self.write(relative, "abc\n")
        result = self.run_census()
        self.assert_failed_with(result, relative, "reduction", "-3 bytes")

    def test_t4_absent_manifest_fails_closed(self) -> None:
        self.write_json("baseline.json", {"version": 1, "files": {}})
        self.assert_failed_with(self.run_census(), "manifest.json", "not found")

    def test_t5_malformed_manifest_fails_closed(self) -> None:
        self.write("manifest.json", "{broken")
        self.write_json("baseline.json", {"version": 1, "files": {}})
        self.assert_failed_with(self.run_census(), "manifest.json", "malformed JSON")

    def test_t6_absent_baseline_fails_closed(self) -> None:
        self.write_json("manifest.json", self.manifest([]))
        self.assert_failed_with(self.run_census(), "baseline.json", "not found")

    def test_t7_malformed_baseline_fails_closed(self) -> None:
        self.write_json("manifest.json", self.manifest([]))
        self.write("baseline.json", "[")
        self.assert_failed_with(self.run_census(), "baseline.json", "malformed JSON")

    def test_t8_manifest_listed_missing_file_fails_closed(self) -> None:
        relative = "skills/fixture/SKILL.md"
        self.write_json("manifest.json", self.manifest([relative]))
        self.write_json("baseline.json", {"version": 1, "files": {relative: 1}})
        self.assert_failed_with(self.run_census(), relative, "listed file is absent")

    def test_t9_completeness_sweep_rejects_unlisted_prompt_file(self) -> None:
        self.write("skills/fixture/SKILL.md", "x")
        self.write_json("manifest.json", self.manifest([]))
        self.write_json("baseline.json", {"version": 1, "files": {}})
        self.assert_failed_with(
            self.run_census(), "skills/fixture/SKILL.md", "matches sweep pattern"
        )

    def test_t10_completeness_positive_control_passes(self) -> None:
        self.seed_single("")
        result = self.run_census()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_t11_json_shape_matrix_and_type_boundaries_fail_closed(self) -> None:
        cases: list[tuple[str, object, object, str]] = [
            (
                "manifest-array",
                [],
                {"version": 1, "files": {}},
                "manifest root must be an object",
            ),
            (
                "manifest-scalar",
                0,
                {"version": 1, "files": {}},
                "manifest root must be an object",
            ),
            (
                "groups-wrong-type",
                {"version": 1, "classification_rule": CLASSIFICATION_RULE, "groups": []},
                {"version": 1, "files": {}},
                "groups must be an object",
            ),
            (
                "baseline-array",
                self.manifest([]),
                [],
                "baseline root must be an object",
            ),
            (
                "baseline-string-byte",
                self.manifest([]),
                {"version": 1, "files": {"x": "233903"}},
                "byte value for x must be a non-negative integer",
            ),
            (
                "unknown-class",
                self.manifest([], group_class="sometimes"),
                {"version": 1, "files": {}},
                "unknown group class",
            ),
        ]
        for name, manifest, baseline, expected in cases:
            with self.subTest(name=name):
                self.write_json("manifest.json", manifest)
                self.write_json("baseline.json", baseline)
                self.assert_failed_with(self.run_census(), expected)

    def test_t11_valid_falsy_shapes_pass(self) -> None:
        self.write_json("manifest.json", self.manifest([]))
        self.write_json("baseline.json", {"version": 1, "files": {}})
        self.assertEqual(self.run_census().returncode, 0)
        self.seed_single("")
        self.assertEqual(self.run_census().returncode, 0)

    def test_t12_path_hygiene_rejects_absolute_and_parent_entries(self) -> None:
        for entry in ["/absolute.md", "skills/../escape.md"]:
            with self.subTest(entry=entry):
                self.write_json("manifest.json", self.manifest([entry]))
                self.write_json("baseline.json", {"version": 1, "files": {entry: 0}})
                self.assert_failed_with(self.run_census(), entry, "repo-relative")

    def test_t13_unchanged_runs_are_idempotent(self) -> None:
        self.seed_single()
        first = self.run_census()
        second = self.run_census()
        self.assertEqual((first.returncode, first.stdout, first.stderr), (second.returncode, second.stdout, second.stderr))

    @unittest.skipUnless(shutil.which("git"), "git is required for the concurrency fixture")
    def test_t15_nonadjacent_rows_merge_and_same_row_conflicts_reauthor_cleanly(self) -> None:
        files = [f"payload/file-{index:02}.txt" for index in range(20)]
        for relative in files:
            self.write(relative, "base\n")
        self.write_json("manifest.json", self.manifest(files))
        self.write_json("baseline.json", self.baseline(files))
        # Pin the initial branch name rather than inheriting the host's
        # `init.defaultBranch`: a desk configured to `main` (the modern git default)
        # made the `checkout master` below fail, turning this fixture RED for a
        # reason that has nothing to do with the census under test.
        self.git("init", "-q", "-b", "master")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "user.name", "Fixture")
        self.git("add", ".")
        self.git("commit", "-qm", "base")
        self.git("branch", "branch-b")

        self.write(files[1], "branch-a\n")
        self.write_json("baseline.json", self.baseline(files))
        self.git("add", ".")
        self.git("commit", "-qm", "branch a")

        self.git("checkout", "-q", "branch-b")
        self.write(files[16], "branch-b\n")
        self.write_json("baseline.json", self.baseline(files))
        self.git("add", ".")
        self.git("commit", "-qm", "branch b")
        self.git("checkout", "-q", "master")
        merged = self.git("merge", "--no-edit", "branch-b", check=False)
        self.assertEqual(merged.returncode, 0, merged.stderr)
        self.assertEqual(self.run_census().returncode, 0)

        self.git("checkout", "-qb", "same-a", "HEAD~2")
        self.write(files[5], "same-a\n")
        self.write_json("baseline.json", self.baseline(files))
        self.git("add", ".")
        self.git("commit", "-qm", "same a")
        self.git("checkout", "-qb", "same-b", "HEAD~1")
        self.write(files[5], "same-b-longer\n")
        self.write_json("baseline.json", self.baseline(files))
        self.git("add", ".")
        self.git("commit", "-qm", "same b")
        self.git("checkout", "-q", "same-a")
        conflict = self.git("merge", "--no-edit", "same-b", check=False)
        self.assertNotEqual(conflict.returncode, 0)
        self.git("merge", "--abort")
        replacement = self.run_census("--write-baseline")
        self.assertEqual(replacement.returncode, 0, replacement.stderr)
        self.write("baseline.json", replacement.stdout)
        self.assertEqual(self.run_census().returncode, 0)

    def git(self, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *args],
            cwd=self.root,
            check=check,
            capture_output=True,
            text=True,
        )

    def test_t16_mandatory_to_reference_relocation_is_visible_and_exact(self) -> None:
        mandatory = "payload/mandatory.md"
        reference = "payload/reference.md"
        self.write(mandatory, "m\n")
        self.write(reference, "reference grew\n")
        manifest = {
            "version": 1,
            "classification_rule": CLASSIFICATION_RULE,
            "groups": {
                "normal": {"class": "mandatory", "files": [mandatory]},
                "rare": {"class": "reference", "files": [reference]},
            },
        }
        self.write_json("manifest.json", manifest)
        self.write_json("baseline.json", self.baseline([mandatory, reference]))
        result = self.run_census()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("normal [mandatory]", result.stdout)
        self.assertIn("rare [reference]", result.stdout)

    def test_t17_hostile_artifact_matrix_fails_with_actionable_diagnostics(self) -> None:
        self.seed_single()
        hostile = {
            "vacuous": "",
            "missing-schema": "---\nkind: growth\n---\n\n## Files\n- x\n",
            "bad-kind": "---\nschema: 1\nkind: cutove\n---\n\nbody\n",
            "duplicate-kind": "---\nschema: 1\nkind: growth\nkind: trim\n---\n\nbody\n",
            "unknown-frontmatter": (
                "---\nschema: 1\nkind: growth\nowner: nobody\n---\n\n"
                "## Files\n- x\n\n## Justification\n- needed\n"
            ),
            "missing-heading": "---\nschema: 1\nkind: cutover\n---\n\n## Files\n- x\n",
            "empty-required-section": (
                "---\nschema: 1\nkind: growth\n---\n\n"
                "## Files\n- x\n\n## Justification\n"
            ),
            "duplicate-required-heading": (
                "---\nschema: 1\nkind: growth\n---\n\n"
                "## Files\n- x\n\n## Files\n- y\n\n## Justification\n- needed\n"
            ),
        }
        for name, body in hostile.items():
            with self.subTest(name=name):
                artifact = self.write("docs/cutovers/x.md", body)
                result = self.run_census()
                self.assert_failed_with(
                    result,
                    "docs/cutovers/x.md",
                    "missing required headings:",
                )
                artifact.unlink()

    def test_t17_each_schema_one_artifact_kind_passes(self) -> None:
        self.seed_single()
        for kind in ["cutover", "trim", "growth", "relocate"]:
            with self.subTest(kind=kind):
                artifact = self.write(
                    f"docs/cutovers/{kind}.md", self.valid_artifact(kind)
                )
                result = self.run_census()
                self.assertEqual(result.returncode, 0, result.stderr)
                artifact.unlink()

    def test_t18_unknown_schema_fails_but_schema_one_remains_frozen(self) -> None:
        self.seed_single()
        artifact = self.write(
            "docs/cutovers/x.md",
            self.valid_artifact("growth").replace("schema: 1", "schema: 99"),
        )
        self.assert_failed_with(self.run_census(), "schema 99", "missing required headings:")
        artifact.write_text(self.valid_artifact("growth"), encoding="utf-8")
        self.write("template-v2.md", "## A future schema may use different headings.\n")
        self.assertEqual(self.run_census().returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
