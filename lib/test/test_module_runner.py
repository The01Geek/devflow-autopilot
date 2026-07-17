#!/usr/bin/env python3
"""Focused tests for the experimental pre-source test-module runner."""

# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
RUNNER_SOURCE = ROOT / "lib/test/run-module.sh"


class ModuleRunnerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.test_dir = self.root / "lib/test"
        self.modules_dir = self.test_dir / "modules"
        self.scripts_dir = self.root / "scripts"
        self.modules_dir.mkdir(parents=True)
        self.scripts_dir.mkdir()

        self.runner = self.test_dir / "run-module.sh"
        if RUNNER_SOURCE.exists():
            shutil.copy2(RUNNER_SOURCE, self.runner)

        self.marker = self.root / "module-sourced"
        self._write_module(
            "sample.sh",
            'printf "sourced\\n" > "$SOURCE_MARKER"\n'
            'assert_eq "sample assertion" "expected" "expected"\n',
        )
        self._write_module(
            "empty.sh",
            'printf "sourced\\n" > "$SOURCE_MARKER"\n',
        )
        self._write_module(
            "crash.sh",
            'printf "sourced\\n" > "$SOURCE_MARKER"\nexit 7\n',
        )
        self._write_module(
            "blocking.sh",
            'printf "ready\\n" > "$READY_MARKER"\n'
            'sleep 5\n'
            'assert_eq "blocking assertion" "expected" "expected"\n',
        )
        self._write_registry(
            {
                "sample": {"path": "lib/test/modules/sample.sh"},
                "empty": {"path": "lib/test/modules/empty.sh"},
                "crash": {"path": "lib/test/modules/crash.sh"},
                "blocking": {"path": "lib/test/modules/blocking.sh"},
            }
        )

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def _write_module(self, name: str, body: str) -> None:
        (self.modules_dir / name).write_text(body, encoding="utf-8")

    def _write_registry(self, modules: object) -> None:
        document = {
            "schema_version": 1,
            "workflows": {"placeholder": {}},
            "test_modules": modules,
        }
        (self.scripts_dir / "workflow-flight-recorder-registry.json").write_text(
            json.dumps(document), encoding="utf-8"
        )

    def _run_args(
        self, *args: str, extra_env: dict[str, str] | None = None
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment.pop("DEVFLOW_TEST_EXPERIMENT_FORCE_FAILURE", None)
        environment["SOURCE_MARKER"] = str(self.marker)
        if extra_env:
            environment.update(extra_env)
        return subprocess.run(
            ["bash", str(self.runner), *args],
            cwd=self.root,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )

    def _run(
        self, module: str, *, extra_env: dict[str, str] | None = None
    ) -> subprocess.CompletedProcess[str]:
        return self._run_args(module, extra_env=extra_env)

    def _log_path(self, result: subprocess.CompletedProcess[str]) -> Path:
        for line in result.stdout.splitlines():
            if line.startswith("Log: "):
                return Path(line.removeprefix("Log: "))
        self.fail(f"runner output did not name its log:\n{result.stdout}")

    def test_exact_selection_runs_one_module_and_persists_its_log(self) -> None:
        result = self._run("sample")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.marker.is_file())
        log = self._log_path(result)
        self.assertTrue(log.is_file())
        self.assertIn("sample assertion", log.read_text(encoding="utf-8"))
        self.assertIn("Module sample: 1 passed, 0 failed", result.stdout)
        self.assertIn(f"Log: {log}", result.stdout)

    def test_unknown_selector_fails_before_any_module_body_or_log(self) -> None:
        result = self._run("unknown")

        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("selector error: unknown test module 'unknown'", result.stderr)
        self.assertFalse(self.marker.exists())
        self.assertFalse((self.root / ".devflow/tmp/test-module-logs").exists())

    def test_help_and_argument_errors_are_explicit(self) -> None:
        help_result = self._run_args("--help")
        no_module = self._run_args()
        two_modules = self._run_args("sample", "empty")
        unknown_option = self._run_args("--unknown")
        missing_registry_value = self._run_args("--registry")
        missing_log_dir_value = self._run_args("--log-dir")

        self.assertEqual(help_result.returncode, 0, help_result.stderr)
        self.assertIn("Usage:", help_result.stderr)
        for result in (
            no_module,
            two_modules,
            unknown_option,
            missing_registry_value,
            missing_log_dir_value,
        ):
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertIn("selector error:", result.stderr)
            self.assertFalse(self.marker.exists())

    def test_registry_and_log_dir_options_control_the_selected_run(self) -> None:
        alternate_registry = self.root / "alternate-registry.json"
        alternate_registry.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "workflows": {"placeholder": {}},
                    "test_modules": {
                        "alternate": {"path": "lib/test/modules/sample.sh"}
                    },
                }
            ),
            encoding="utf-8",
        )
        alternate_logs = self.root / "alternate-logs"

        result = self._run_args(
            "--registry",
            str(alternate_registry),
            "--log-dir",
            str(alternate_logs),
            "alternate",
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self._log_path(result).parent, alternate_logs)

    def test_invalid_module_id_fails_before_source(self) -> None:
        result = self._run("../sample")

        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("invalid module id", result.stderr)
        self.assertFalse(self.marker.exists())

    def test_empty_module_mapping_fails_closed_before_source(self) -> None:
        self._write_registry({})

        result = self._run("sample")

        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("test_modules must be a non-empty object", result.stderr)
        self.assertFalse(self.marker.exists())

    def test_malformed_registry_fails_closed_before_source(self) -> None:
        (self.scripts_dir / "workflow-flight-recorder-registry.json").write_text(
            "{not-json", encoding="utf-8"
        )

        result = self._run("sample")

        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("registry is unreadable or malformed", result.stderr)
        self.assertFalse(self.marker.exists())

    def test_boolean_schema_version_is_not_accepted_as_integer_one(self) -> None:
        document = {
            "schema_version": True,
            "workflows": {"placeholder": {}},
            "test_modules": {"sample": {"path": "lib/test/modules/sample.sh"}},
        }
        (self.scripts_dir / "workflow-flight-recorder-registry.json").write_text(
            json.dumps(document), encoding="utf-8"
        )

        result = self._run("sample")

        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("requires integer schema_version 1", result.stderr)
        self.assertFalse(self.marker.exists())

    def test_invalid_sibling_mapping_invalidates_whole_registry(self) -> None:
        self._write_registry(
            {
                "sample": {"path": "lib/test/modules/sample.sh"},
                "broken": True,
            }
        )

        result = self._run("sample")

        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("mapping for 'broken' must be an object", result.stderr)
        self.assertFalse(self.marker.exists())

    def test_escaping_module_path_is_invalid_and_never_sourced(self) -> None:
        escaped = self.root / "escape.sh"
        escaped.write_text('printf "escaped\\n" > "$SOURCE_MARKER"\n', encoding="utf-8")
        self._write_registry({"sample": {"path": "../escape.sh"}})

        result = self._run("sample")

        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("module path must match lib/test/modules/<name>.sh", result.stderr)
        self.assertFalse(self.marker.exists())

    def test_missing_regex_valid_module_path_fails_before_source(self) -> None:
        self._write_registry(
            {"missing": {"path": "lib/test/modules/missing.sh"}}
        )

        result = self._run("missing")

        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("module path is missing", result.stderr)
        self.assertFalse(self.marker.exists())

    def test_resolved_directory_is_not_accepted_as_readable_module_file(self) -> None:
        (self.modules_dir / "directory.sh").mkdir()
        self._write_registry(
            {"directory": {"path": "lib/test/modules/directory.sh"}}
        )

        result = self._run("directory")

        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("module path is not a readable file", result.stderr)
        self.assertFalse(self.marker.exists())

    def test_symlink_escape_is_rejected_by_canonical_path_confinement(self) -> None:
        escaped = self.root / "escaped.sh"
        escaped.write_text('printf "escaped\\n" > "$SOURCE_MARKER"\n', encoding="utf-8")
        (self.modules_dir / "linked.sh").symlink_to(escaped)
        self._write_registry(
            {"linked": {"path": "lib/test/modules/linked.sh"}}
        )

        result = self._run("linked")

        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("escapes lib/test/modules", result.stderr)
        self.assertFalse(self.marker.exists())

    def test_symlink_escape_in_sibling_mapping_invalidates_whole_registry(self) -> None:
        escaped = self.root / "escaped.sh"
        escaped.write_text('printf "escaped\\n" > "$SOURCE_MARKER"\n', encoding="utf-8")
        (self.modules_dir / "linked.sh").symlink_to(escaped)
        self._write_registry(
            {
                "sample": {"path": "lib/test/modules/sample.sh"},
                "linked": {"path": "lib/test/modules/linked.sh"},
            }
        )

        result = self._run("sample")

        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("mapping for 'linked'", result.stderr)
        self.assertIn("escapes lib/test/modules", result.stderr)
        self.assertFalse(self.marker.exists())

    def test_module_with_zero_assertions_cannot_report_green(self) -> None:
        result = self._run("empty")

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertTrue(self.marker.is_file())
        self.assertIn("Module empty: 0 passed, 1 failed", result.stdout)
        self.assertIn("module executed zero assertions", result.stdout)

    def test_nonzero_module_process_gets_a_failure_recap(self) -> None:
        result = self._run("crash")

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Module crash: 0 passed, 2 failed", result.stdout)
        self.assertIn("module process exited with status 7", result.stdout)
        self.assertIn("module executed zero assertions", result.stdout)

    def test_controlled_failure_is_nonzero_and_recapped_in_the_persisted_log(self) -> None:
        result = self._run(
            "sample", extra_env={"DEVFLOW_TEST_EXPERIMENT_FORCE_FAILURE": "1"}
        )

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Module sample: 1 passed, 1 failed", result.stdout)
        self.assertIn("controlled experimental failure injection", result.stdout)
        self.assertIn("expected: disabled", result.stdout)
        self.assertIn("actual:   enabled", result.stdout)
        log = self._log_path(result)
        self.assertIn("Failure recap:", log.read_text(encoding="utf-8"))

    def test_concurrent_runs_use_distinct_complete_logs(self) -> None:
        environment = os.environ.copy()
        environment.pop("DEVFLOW_TEST_EXPERIMENT_FORCE_FAILURE", None)
        environment["SOURCE_MARKER"] = str(self.marker)
        command = ["bash", str(self.runner), "sample"]

        first = subprocess.Popen(
            command,
            cwd=self.root,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        second = subprocess.Popen(
            command,
            cwd=self.root,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        first_stdout, first_stderr = first.communicate()
        second_stdout, second_stderr = second.communicate()
        first_result = subprocess.CompletedProcess(command, first.returncode, first_stdout, first_stderr)
        second_result = subprocess.CompletedProcess(command, second.returncode, second_stdout, second_stderr)

        self.assertEqual(first_result.returncode, 0, first_stdout + first_stderr)
        self.assertEqual(second_result.returncode, 0, second_stdout + second_stderr)
        first_log = self._log_path(first_result)
        second_log = self._log_path(second_result)
        self.assertNotEqual(first_log, second_log)
        for log in (first_log, second_log):
            self.assertTrue(log.is_file())
            self.assertIn("Module sample: 1 passed, 0 failed", log.read_text(encoding="utf-8"))

    def test_selector_diagnostic_temp_is_removed_before_module_execution(self) -> None:
        controlled_tmp = self.root / "tmp"
        controlled_tmp.mkdir()
        ready = self.root / "module-ready"
        environment = os.environ.copy()
        environment.pop("DEVFLOW_TEST_EXPERIMENT_FORCE_FAILURE", None)
        environment["SOURCE_MARKER"] = str(self.marker)
        environment["READY_MARKER"] = str(ready)
        environment["TMPDIR"] = str(controlled_tmp)
        process = subprocess.Popen(
            ["bash", str(self.runner), "blocking"],
            cwd=self.root,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            deadline = time.monotonic() + 3
            while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(ready.exists(), "blocking module did not start")
            self.assertEqual(len(list(controlled_tmp.iterdir())), 2)
        finally:
            process.terminate()
            process.communicate(timeout=3)

    def test_parent_failure_flag_does_not_contaminate_unforced_child_runs(self) -> None:
        with mock.patch.dict(
            os.environ, {"DEVFLOW_TEST_EXPERIMENT_FORCE_FAILURE": "1"}
        ):
            result = self._run("sample")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Module sample: 1 passed, 0 failed", result.stdout)

    def test_repository_registry_maps_the_extracted_recorder_module(self) -> None:
        registry = json.loads(
            (ROOT / "scripts/workflow-flight-recorder-registry.json").read_text(
                encoding="utf-8"
            )
        )

        self.assertIn("test_modules", registry)
        self.assertEqual(
            registry["test_modules"]["workflow-flight-recorder"]["path"],
            "lib/test/modules/workflow-flight-recorder.sh",
        )
        module = ROOT / "lib/test/modules/workflow-flight-recorder.sh"
        self.assertTrue(module.is_file())
        run_text = (ROOT / "lib/test/run.sh").read_text(encoding="utf-8")
        self.assertIn(
            'devflow_run_full_suite_module "$LIB/test/modules/workflow-flight-recorder.sh"',
            run_text,
        )
        self.assertIn('python3 "$LIB/test/test_module_runner.py"', run_text)
        self.assertNotIn('IFR_MANIFEST="$LIB/../scripts/capture-workflow-manifest.py"', run_text)
        module_text = module.read_text(encoding="utf-8")
        self.assertTrue(
            module_text.startswith(
                "# SPDX-FileCopyrightText: 2026 Daniel Radman\n"
                "# SPDX-License-Identifier: MIT\n"
            )
        )
        self.assertNotIn('python3 "$LIB/test/test_module_runner.py"', module_text)
        self.assertIn(
            'IFR_MANIFEST="$LIB/../scripts/capture-workflow-manifest.py"',
            module_text,
        )


if __name__ == "__main__":
    unittest.main()
