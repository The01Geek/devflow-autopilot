#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Behavioral tests for measured, raise-only module-floor reconciliation."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "lib/test/reconcile-module-floors.py"


class FloorReconcilerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        (self.root / "lib/test/modules").mkdir(parents=True)
        (self.root / "scripts").mkdir()
        for module_id in ("alpha", "beta"):
            (self.root / f"lib/test/modules/{module_id}.sh").write_text(
                "# fixture module\n", encoding="utf-8"
            )
        self.registry_path = (
            self.root / "scripts/workflow-flight-recorder-registry.json"
        )
        self.run_path = self.root / "lib/test/run.sh"
        self.settings_path = self.root / "scripts/fake-measurements.json"
        self.runner_path = self.root / "lib/test/run-module.sh"
        self.runner_path.write_text(
            """#!/usr/bin/env bash
python3 - "$PWD" "$@" <<'PY'
import json
import os
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
args = sys.argv[2:]
registry = Path(args[args.index("--registry") + 1])
module_id = args[-1]
mapping = json.loads(registry.read_text())["test_modules"][module_id]
if mapping["minimum_assertions"] != 1:
    print("fixture runner: measurement floor was not lowered", file=sys.stderr)
    raise SystemExit(9)
record = json.loads((root / "scripts/fake-measurements.json").read_text())[module_id]
if record.get("require_trimmed_tmpdir") and os.environ.get("TMPDIR", "").endswith("/"):
    print("fixture runner: TMPDIR retained a trailing separator", file=sys.stderr)
    raise SystemExit(8)
if record.get("mutate_run"):
    run_path = root / "lib/test/run.sh"
    run_text = run_path.read_text(encoding="utf-8")
    run_path.write_text(
        re.sub(
            rf'("{re.escape(module_id)}" )[0-9]+(; then)',
            rf'\\g<1>{record["mutate_run"]}\\g<2>',
            run_text,
        ),
        encoding="utf-8",
    )
if not record.get("omit"):
    for _ in range(record.get("copies", 1)):
        suffix = f', {record.get("skipped", 0)} skipped' if record.get("skipped") else ""
        print(
            f'Module {module_id}: {record["passed"]} passed, '
            f'{record.get("failed", 0)} failed{suffix}'
        )
raise SystemExit(record.get("rc", 0))
PY
""",
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def write_contract(self, alpha_floor: int, beta_floor: int) -> None:
        self.registry_path.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "test_modules": {
                        "alpha": {
                            "path": "lib/test/modules/alpha.sh",
                            "minimum_assertions": alpha_floor,
                            "assertion_floor_policy": "exact",
                        },
                        "beta": {
                            "path": "lib/test/modules/beta.sh",
                            "minimum_assertions": beta_floor,
                        },
                    },
                    "workflows": {"placeholder": {}},
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        self.run_path.write_text(
            """if ! devflow_run_full_suite_module "$LIB/test/modules/alpha.sh" \\
  "alpha" %s; then
  exit 1
fi
if ! devflow_run_full_suite_module "$LIB/test/modules/beta.sh" \\
  "beta" %s; then
  exit 1
fi
"""
            % (alpha_floor, beta_floor),
            encoding="utf-8",
        )

    def run_helper(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "python3",
                str(HELPER),
                "--repo-root",
                str(self.root),
                "--runner",
                str(self.runner_path),
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_measured_increase_raises_both_coupled_sites(self) -> None:
        self.write_contract(alpha_floor=2, beta_floor=3)
        self.settings_path.write_text(
            json.dumps({"alpha": {"passed": 4}}), encoding="utf-8"
        )

        result = self.run_helper()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        registry = json.loads(self.registry_path.read_text(encoding="utf-8"))
        self.assertEqual(registry["test_modules"]["alpha"]["minimum_assertions"], 4)
        self.assertEqual(registry["test_modules"]["beta"]["minimum_assertions"], 3)
        self.assertIn('"alpha" 4; then', self.run_path.read_text(encoding="utf-8"))

    def test_equal_measurement_is_clean_and_writes_nothing(self) -> None:
        self.write_contract(alpha_floor=3, beta_floor=5)
        self.settings_path.write_text(
            json.dumps({"alpha": {"passed": 3}}), encoding="utf-8"
        )
        before = (self.registry_path.read_bytes(), self.run_path.read_bytes())

        result = self.run_helper()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            (self.registry_path.read_bytes(), self.run_path.read_bytes()), before
        )
        self.assertIn("clean", result.stdout)

    def test_measurement_runner_receives_a_normalized_tmpdir(self) -> None:
        self.write_contract(alpha_floor=3, beta_floor=5)
        self.settings_path.write_text(
            json.dumps(
                {"alpha": {"passed": 3, "require_trimmed_tmpdir": True}}
            ),
            encoding="utf-8",
        )

        result = self.run_helper()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_lower_measurement_is_a_nonwriting_judgment(self) -> None:
        self.write_contract(alpha_floor=4, beta_floor=5)
        self.settings_path.write_text(
            json.dumps({"alpha": {"passed": 3}}), encoding="utf-8"
        )
        before = (self.registry_path.read_bytes(), self.run_path.read_bytes())

        result = self.run_helper()

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(
            (self.registry_path.read_bytes(), self.run_path.read_bytes()), before
        )
        self.assertIn("DECREASE REFUSED", result.stderr)

    def test_untrustworthy_measurements_are_infrastructure_and_write_nothing(self) -> None:
        cases = {
            "failed process": {"passed": 4, "rc": 1},
            "failed assertion": {"passed": 3, "failed": 1},
            "skipped assertion": {"passed": 4, "skipped": 1},
            "missing summary": {"passed": 4, "omit": True},
            "duplicate summary": {"passed": 4, "copies": 2},
        }
        for label, record in cases.items():
            with self.subTest(label=label):
                self.write_contract(alpha_floor=2, beta_floor=5)
                self.settings_path.write_text(
                    json.dumps({"alpha": record}), encoding="utf-8"
                )
                before = (self.registry_path.read_bytes(), self.run_path.read_bytes())

                result = self.run_helper()

                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertEqual(
                    (self.registry_path.read_bytes(), self.run_path.read_bytes()), before
                )
                self.assertIn("INFRASTRUCTURE", result.stderr)

    def test_missing_coupled_site_is_infrastructure_and_writes_nothing(self) -> None:
        self.write_contract(alpha_floor=2, beta_floor=5)
        self.run_path.write_text("# no alpha boundary\n", encoding="utf-8")
        self.settings_path.write_text(
            json.dumps({"alpha": {"passed": 4}}), encoding="utf-8"
        )
        before = (self.registry_path.read_bytes(), self.run_path.read_bytes())

        result = self.run_helper()

        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(
            (self.registry_path.read_bytes(), self.run_path.read_bytes()), before
        )

    def test_coupled_patch_failure_does_not_partially_raise_the_registry(self) -> None:
        self.write_contract(alpha_floor=2, beta_floor=5)
        self.settings_path.write_text(
            json.dumps({"alpha": {"passed": 4, "mutate_run": 99}}),
            encoding="utf-8",
        )
        registry_before = self.registry_path.read_bytes()

        result = self.run_helper()

        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(self.registry_path.read_bytes(), registry_before)
        self.assertIn("coupled patch was not applied", result.stderr)


if __name__ == "__main__":
    unittest.main()
