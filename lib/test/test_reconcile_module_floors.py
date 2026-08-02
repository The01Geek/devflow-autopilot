#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Behavioral tests for measured, raise-only module-floor reconciliation."""

from __future__ import annotations

import json
import os
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
rc = record.get("rc", 0)
if record.get("failed", 0):
    # Mirror the real runner, which sets RUN_RC to 1 whenever FAIL_COUNT is nonzero.
    # Left decoupled, the fake could emit a failed>0 summary alongside rc 0 — a pair
    # the real runner cannot produce — so the case would exercise the reconciler's
    # later not-clean branch instead of the rc gate that actually rejects it first,
    # and the test would attest to a path no real measurement reaches.
    rc = 1
raise SystemExit(rc)
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

    def run_helper(
        self, environment: dict[str, str] | None = None
    ) -> subprocess.CompletedProcess[str]:
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
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_measured_increase_raises_both_coupled_sites(self) -> None:
        # Every expectation below is derived from these three, so the test states the
        # measured raise once instead of transcribing `4` into a bare literal that a
        # reader cannot tie back to the measurement that produced it.
        alpha_floor, beta_floor, measured = 2, 3, 4
        self.write_contract(alpha_floor=alpha_floor, beta_floor=beta_floor)
        self.settings_path.write_text(
            json.dumps({"alpha": {"passed": measured}}), encoding="utf-8"
        )

        result = self.run_helper()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        registry = json.loads(self.registry_path.read_text(encoding="utf-8"))
        self.assertEqual(
            registry["test_modules"]["alpha"]["minimum_assertions"], measured
        )
        self.assertEqual(
            registry["test_modules"]["beta"]["minimum_assertions"], beta_floor
        )
        # Asserting the raised operand reached run.sh is the only thing separating a real
        # coupled raise from one that moved the registry alone.
        self.assertIn(
            f'"alpha" {measured}; then',
            self.run_path.read_text(encoding="utf-8"),
        )

    def test_measured_increase_changes_only_the_selected_numeric_tokens(self) -> None:
        self.write_contract(alpha_floor=2, beta_floor=3)
        registry = json.loads(self.registry_path.read_text(encoding="utf-8"))
        registry["test_modules"]["beta"]["description"] = "kept byte-for-byte — café"
        before = json.dumps(
            registry, ensure_ascii=False, separators=(",", ":")
        ) + "\n"
        self.registry_path.write_text(before, encoding="utf-8")
        self.settings_path.write_text(
            json.dumps({"alpha": {"passed": 4}}), encoding="utf-8"
        )

        result = self.run_helper()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(
            self.registry_path.read_text(encoding="utf-8"),
            before.replace('"minimum_assertions":2', '"minimum_assertions":4', 1),
        )

    def test_measurement_runner_honors_the_devflow_bash_override(self) -> None:
        self.write_contract(alpha_floor=3, beta_floor=5)
        self.settings_path.write_text(
            json.dumps({"alpha": {"passed": 3}}), encoding="utf-8"
        )
        marker = self.root / "devflow-bash-used"
        bash_override = self.root / "selected-bash"
        bash_override.write_text(
            "#!/usr/bin/env bash\n"
            f"printf used > {marker}\n"
            'exec bash "$@"\n',
            encoding="utf-8",
        )
        bash_override.chmod(0o755)
        environment = os.environ.copy()
        environment["DEVFLOW_BASH"] = str(bash_override)

        result = self.run_helper(environment)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(marker.read_text(encoding="utf-8"), "used")

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
            json.dumps({"alpha": {"passed": 3, "require_trimmed_tmpdir": True}}),
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

    def test_untrustworthy_measurements_are_infrastructure_and_write_nothing(
        self,
    ) -> None:
        cases = {
            "failed process": {"passed": 4, "rc": 1},
            # Rejected at the rc gate, because the fake couples rc to failed exactly as
            # the real runner does. The reconciler's later not-clean branch stays
            # covered by the skipped case below, which the real runner CAN emit with
            # rc 0 — skips do not fail a module run.
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
                    (self.registry_path.read_bytes(), self.run_path.read_bytes()),
                    before,
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
