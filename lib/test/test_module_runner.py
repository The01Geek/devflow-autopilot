#!/usr/bin/env python3
"""Focused tests for the experimental pre-source test-module runner."""

# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
RUNNER_SOURCE = ROOT / "lib/test/run-module.sh"
HARNESS_SOURCE = ROOT / "lib/test/module-harness.sh"
WORKFLOW_MODULE_SOURCE = ROOT / "lib/test/modules/workflow-flight-recorder.sh"
REVIEW_AND_FIX_MODULE_SOURCE = ROOT / "lib/test/modules/review-and-fix-contract.sh"
CREATE_ISSUE_MODULE_SOURCE = ROOT / "lib/test/modules/create-issue-contract.sh"

# The extracted create-issue module must reference NO monolith run.sh helper — it
# uses only assert_eq plus the namespaced devflow_module_* API and its own private
# helpers. This matches each banned helper as a standalone token, so the namespaced
# names (devflow_module_pin_count, …) whose `pin_count` substring is preceded by `_`
# never trip it.
MONOLITH_HELPER_RE = re.compile(
    r"(?:^|[^A-Za-z0-9_])"
    r"(pin_count|probe_tmp|probe_assert|grep_present"
    r"|assert_pin_unique|assert_pin_red_under|assert_pin_red_on_removal)"
    r"(?:[^A-Za-z0-9_]|$)"
)


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
        if HARNESS_SOURCE.exists():
            shutil.copy2(HARNESS_SOURCE, self.test_dir / "module-harness.sh")

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
            "invalid-tally.sh",
            'printf "INVALID\\n" >> "$RESULTS_FILE"\n'
            'assert_eq "valid assertion after invalid record" "expected" "expected"\n',
        )
        self._write_module(
            "blocking.sh",
            'printf "ready\\n" > "$READY_MARKER"\n'
            'sleep 5\n'
            'assert_eq "blocking assertion" "expected" "expected"\n',
        )
        shutil.copy2(
            WORKFLOW_MODULE_SOURCE,
            self.modules_dir / "workflow-flight-recorder.sh",
        )
        self._write_registry(
            {
                "sample": {"path": "lib/test/modules/sample.sh"},
                "empty": {"path": "lib/test/modules/empty.sh"},
                "crash": {"path": "lib/test/modules/crash.sh"},
                "invalid-tally": {"path": "lib/test/modules/invalid-tally.sh"},
                "blocking": {"path": "lib/test/modules/blocking.sh"},
                "workflow-flight-recorder": {
                    "path": "lib/test/modules/workflow-flight-recorder.sh"
                },
            }
        )

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def _write_module(self, name: str, body: str) -> None:
        (self.modules_dir / name).write_text(body, encoding="utf-8")

    def _write_registry(self, modules: object) -> None:
        if isinstance(modules, dict):
            modules = {
                module_id: (
                    {**mapping, "minimum_assertions": mapping.get("minimum_assertions", 1)}
                    if isinstance(mapping, dict)
                    else mapping
                )
                for module_id, mapping in modules.items()
            }
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

    def test_repository_runner_supports_required_direct_invocation(self) -> None:
        self.assertTrue(os.access(RUNNER_SOURCE, os.X_OK))

        result = subprocess.run(
            [str(RUNNER_SOURCE), "--help"],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Usage:", result.stderr)

    def test_repository_module_runs_green_through_the_real_runner(self) -> None:
        # The focused path the prompt extensions steer agents to: the REAL
        # runner + REAL registry + REAL module, end to end. This is the only
        # execution proving the runner's environment contract (LIB,
        # RESULTS_FILE, assert_eq, sourced harness) satisfies the module's
        # actual needs — the full suite exercises the module only through the
        # harness boundary, not through this runner.
        environment = os.environ.copy()
        environment.pop("DEVFLOW_TEST_EXPERIMENT_FORCE_FAILURE", None)
        with tempfile.TemporaryDirectory() as log_dir:
            result = subprocess.run(
                [
                    "bash",
                    str(RUNNER_SOURCE),
                    "--log-dir",
                    log_dir,
                    "workflow-flight-recorder",
                ],
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(
                result.returncode,
                0,
                result.stdout[-4000:] + result.stderr[-4000:],
            )
            self.assertRegex(
                result.stdout,
                r"Module workflow-flight-recorder: [0-9]+ passed, 0 failed",
            )
            self.assertTrue(list(Path(log_dir).iterdir()))

    def test_review_and_fix_contract_module_runs_green_through_the_real_runner(self) -> None:
        """The documented local RAF path uses the real registry and module API."""
        registry = json.loads(
            (ROOT / "scripts/workflow-flight-recorder-registry.json").read_text(
                encoding="utf-8"
            )
        )
        floor = registry["test_modules"]["review-and-fix-contract"][
            "minimum_assertions"
        ]
        environment = os.environ.copy()
        environment.pop("DEVFLOW_TEST_EXPERIMENT_FORCE_FAILURE", None)
        with tempfile.TemporaryDirectory() as log_dir:
            result = subprocess.run(
                [
                    "bash",
                    str(RUNNER_SOURCE),
                    "--log-dir",
                    log_dir,
                    "review-and-fix-contract",
                ],
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(
                result.returncode,
                0,
                result.stdout[-4000:] + result.stderr[-4000:],
            )
            self.assertIn(
                f"Module review-and-fix-contract: {floor} passed, 0 failed",
                result.stdout,
            )
            self.assertTrue(list(Path(log_dir).iterdir()))

    def test_relative_registry_and_log_dir_resolve_against_repo_root(self) -> None:
        custom_dir = self.root / "custom"
        custom_dir.mkdir()
        (custom_dir / "reg.json").write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "workflows": {"placeholder": {}},
                    "test_modules": {
                        "sample": {
                            "path": "lib/test/modules/sample.sh",
                            "minimum_assertions": 1,
                        }
                    },
                }
            ),
            encoding="utf-8",
        )

        # Run from a SUBDIRECTORY cwd so REPO_ROOT-anchoring is distinguishable
        # from cwd-anchoring on every platform (with cwd == repo root the two
        # coincide except behind macOS's /var symlink).
        environment = os.environ.copy()
        environment.pop("DEVFLOW_TEST_EXPERIMENT_FORCE_FAILURE", None)
        environment["SOURCE_MARKER"] = str(self.marker)
        result = subprocess.run(
            [
                "bash",
                str(self.runner),
                "--registry",
                "custom/reg.json",
                "--log-dir",
                "custom-logs",
                "sample",
            ],
            cwd=custom_dir,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        log = self._log_path(result)
        # Compare physical paths: the runner resolves REPO_ROOT with pwd -P,
        # while the sandbox root may sit behind a symlink (macOS /var -> /private/var).
        self.assertEqual(log.parent, (self.root / "custom-logs").resolve())
        self.assertFalse((custom_dir / "custom-logs").exists())
        self.assertTrue(log.is_file())

    def test_missing_harness_fails_closed_before_selection(self) -> None:
        # Guard-class 1 (existence-vs-sourceability): a failed top-level source
        # must stop the runner — bash otherwise continues, and with any floor
        # slack the module would run green while the harness helpers silently
        # never execute.
        (self.test_dir / "module-harness.sh").unlink()

        result = self._run("sample")

        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("could not source", result.stderr)
        self.assertFalse(self.marker.exists())
        self.assertFalse((self.root / ".devflow/tmp/test-module-logs").exists())

    def test_harness_missing_contract_function_fails_closed(self) -> None:
        # Outcome check, not just source rc: a harness copy that sources
        # cleanly but no longer defines its contract functions must refuse.
        (self.test_dir / "module-harness.sh").write_text(
            "# stub harness with no contract functions\n", encoding="utf-8"
        )

        result = self._run("sample")

        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn(
            "did not define devflow_run_focused_python_test", result.stderr
        )
        self.assertFalse(self.marker.exists())

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
                        "alternate": {
                            "path": "lib/test/modules/sample.sh",
                            "minimum_assertions": 1,
                        }
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

    def test_missing_assertion_floor_invalidates_registry(self) -> None:
        registry = self.scripts_dir / "workflow-flight-recorder-registry.json"
        registry.write_text(
            '{"schema_version":1,"test_modules":{'
            '"sample":{"path":"lib/test/modules/sample.sh"}}}',
            encoding="utf-8",
        )

        result = self._run("sample")

        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn(
            "minimum_assertions must be an integer from 1 to 1000000",
            result.stderr,
        )
        self.assertFalse(self.marker.exists())

    def test_nonpositive_and_noninteger_assertion_floors_invalidate_registry(self) -> None:
        for floor in (0, -1, "1", True):
            with self.subTest(floor=floor):
                self._write_registry(
                    {
                        "sample": {
                            "path": "lib/test/modules/sample.sh",
                            "minimum_assertions": floor,
                        }
                    }
                )

                result = self._run("sample")

                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn(
                    "minimum_assertions must be an integer from 1 to 1000000",
                    result.stderr,
                )
                self.assertFalse(self.marker.exists())

    def test_nonobject_registry_shapes_fail_before_source(self) -> None:
        registry = self.scripts_dir / "workflow-flight-recorder-registry.json"
        for document in ([], {"schema_version": 1, "test_modules": []}):
            with self.subTest(document=document):
                registry.write_text(json.dumps(document), encoding="utf-8")

                result = self._run("sample")

                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertFalse(self.marker.exists())

    def test_oversized_assertion_floor_invalidates_registry(self) -> None:
        self._write_registry(
            {
                "sample": {
                    "path": "lib/test/modules/sample.sh",
                    "minimum_assertions": 10**100,
                }
            }
        )

        result = self._run("sample")

        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("minimum_assertions must be an integer from 1 to 1000000", result.stderr)
        self.assertFalse(self.marker.exists())

    def test_invalid_sibling_module_id_invalidates_whole_registry(self) -> None:
        self._write_registry(
            {
                "sample": {"path": "lib/test/modules/sample.sh"},
                "../broken": {"path": "lib/test/modules/empty.sh"},
            }
        )

        result = self._run("sample")

        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("registry contains invalid module id '../broken'", result.stderr)
        self.assertFalse(self.marker.exists())

    def test_duplicate_registry_key_invalidates_whole_registry(self) -> None:
        registry = self.scripts_dir / "workflow-flight-recorder-registry.json"
        registry.write_text(
            '{"schema_version":1,"test_modules":{'
            '"sample":{"path":"lib/test/modules/sample.sh"},'
            '"sample":{"path":"lib/test/modules/empty.sh"}}}',
            encoding="utf-8",
        )

        result = self._run("sample")

        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("registry is unreadable or malformed", result.stderr)
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

    def test_unreadable_module_file_is_rejected_before_source(self) -> None:
        module = self.modules_dir / "sample.sh"
        module.chmod(0)
        # Probe actual readability instead of euid, and assert the readability
        # gate's correct-for-THIS-host behavior on every host — never a
        # laundered skip (#456: unittest's skipIf reports OK/rc-0, which run.sh
        # records as a clean pass). A euid-keyed skipIf also AttributeErrors at
        # class-definition time on native Windows, where os.geteuid does not
        # exist. Root and permission-less filesystems (native Windows) can read
        # a chmod-0 file: there the `[ -r ]` gate must pass it straight through
        # to normal sourcing; elsewhere it must reject before sourcing.
        host_can_read_unreadable = os.access(module, os.R_OK)
        try:
            result = self._run("sample")
        finally:
            module.chmod(0o600)

        if host_can_read_unreadable:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(self.marker.is_file())
            self.assertIn("Module sample: 1 passed, 0 failed", result.stdout)
        else:
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

    def test_invalid_tally_record_is_nonzero_and_recapped(self) -> None:
        result = self._run("invalid-tally")

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Module invalid-tally: 1 passed, 1 failed", result.stdout)
        self.assertIn("assertion tally contained 1 invalid record(s)", result.stdout)

    def test_selected_module_below_assertion_floor_cannot_report_green(self) -> None:
        self._write_registry(
            {
                "sample": {
                    "path": "lib/test/modules/sample.sh",
                    "minimum_assertions": 2,
                }
            }
        )

        result = self._run("sample")

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Module sample: 1 passed, 1 failed", result.stdout)
        self.assertIn("module executed 1 assertions; minimum is 2", result.stdout)

    def _run_with_fake_directory_mktemp(
        self, fake_directory_result: str
    ) -> subprocess.CompletedProcess[str]:
        fake_bin = self.root / "fake-bin"
        fake_bin.mkdir(exist_ok=True)
        controlled_tmp = self.root / "fake-tmp"
        controlled_tmp.mkdir(exist_ok=True)
        fake_mktemp = fake_bin / "mktemp"
        real_mktemp = shutil.which("mktemp")
        self.assertIsNotNone(real_mktemp)
        fake_mktemp.write_text(
            "#!/usr/bin/env bash\n"
            'if [ "${1:-}" = "-d" ]; then '
            + fake_directory_result
            + "; fi\n"
            f'exec "{real_mktemp}" "$@"\n',
            encoding="utf-8",
        )
        fake_mktemp.chmod(0o755)

        return self._run(
            "workflow-flight-recorder",
            extra_env={
                "PATH": f"{fake_bin}:{os.environ['PATH']}",
                "TMPDIR": str(controlled_tmp),
            },
        )

    def test_module_workspace_allocation_failure_is_explicit(self) -> None:
        result = self._run_with_fake_directory_mktemp("exit 9")

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("could not allocate workflow-flight-recorder workspace", result.stdout)
        self.assertNotIn("mkdir: /nested", result.stdout)

    def test_module_workspace_rejects_unsafe_successful_mktemp_output(self) -> None:
        unsafe_results = (
            "printf '/\\n'; exit 0",
            'candidate="${2%XXXXXX}fixture"; mkdir -p "$candidate"; '
            'printf "%s/..\\n" "$candidate"; exit 0',
            'target="${2%XXXXXX}target"; link="${2%XXXXXX}link"; '
            'mkdir -p "$target"; ln -s "$target" "$link"; '
            'printf "%s\\n" "$link"; exit 0',
        )
        for fake_result in unsafe_results:
            with self.subTest(fake_result=fake_result):
                result = self._run_with_fake_directory_mktemp(fake_result)

                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(
                    "could not allocate workflow-flight-recorder workspace",
                    result.stdout,
                )
                self.assertNotIn("mkdir: /nested", result.stdout)

    def test_abnormal_module_exit_removes_allocated_workspace(self) -> None:
        module = self.modules_dir / "workflow-flight-recorder.sh"
        module_text = module.read_text(encoding="utf-8")
        post_allocation = 'IFR_PROJECTS="$IFR_ROOT/native-projects"\n'
        self.assertEqual(module_text.count(post_allocation), 1)
        module.write_text(
            module_text.replace(post_allocation, "exit 97\n", 1),
            encoding="utf-8",
        )
        controlled_tmp = self.root / "abnormal-exit-tmp"
        controlled_tmp.mkdir()

        result = self._run(
            "workflow-flight-recorder",
            extra_env={"TMPDIR": str(controlled_tmp)},
        )

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("module process exited with status 97", result.stdout)
        self.assertEqual(list(controlled_tmp.glob("devflow-wfr.*")), [])

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
            # The runner's HUP/INT/TERM trap runs only after the module's
            # foreground command (sleep 5) returns, so give SIGTERM time to be
            # honored and fall back to SIGKILL rather than hanging the test.
            process.terminate()
            try:
                process.communicate(timeout=8)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate()

    def test_forced_failure_injection_fires_only_when_the_flag_is_present(self) -> None:
        # RED half: the flag deliberately passed through fires the injection.
        # (extra_env is applied after the helper's scrub, so this reaches bash.)
        forced = self._run(
            "sample", extra_env={"DEVFLOW_TEST_EXPERIMENT_FORCE_FAILURE": "1"}
        )
        self.assertNotEqual(forced.returncode, 0, forced.stdout + forced.stderr)
        self.assertIn(
            "controlled experimental failure injection", forced.stdout
        )

        # GREEN half / no-fire control: without the flag the same module is clean.
        unforced = self._run("sample")
        self.assertEqual(unforced.returncode, 0, unforced.stdout + unforced.stderr)
        self.assertIn("Module sample: 1 passed, 0 failed", unforced.stdout)
        self.assertNotIn(
            "controlled experimental failure injection", unforced.stdout
        )

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
        self.assertEqual(
            registry["test_modules"]["workflow-flight-recorder"][
                "minimum_assertions"
            ],
            68,
        )
        module = ROOT / "lib/test/modules/workflow-flight-recorder.sh"
        self.assertTrue(module.is_file())
        run_text = (ROOT / "lib/test/run.sh").read_text(encoding="utf-8")
        self.assertIn(
            'devflow_run_full_suite_module "$LIB/test/modules/workflow-flight-recorder.sh"',
            run_text,
        )
        floor_match = re.search(
            r'"workflow-flight-recorder" ([0-9]+); then', run_text
        )
        self.assertIsNotNone(floor_match)
        self.assertEqual(
            int(floor_match.group(1)),
            registry["test_modules"]["workflow-flight-recorder"][
                "minimum_assertions"
            ],
        )
        self.assertIn('FAIL="$(devflow_fold_module_failures "$FAIL")"', run_text)
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
        self.assertEqual(module_text.count("devflow_run_focused_python_test"), 2)
        ci_text = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn("lib/test/modules/workflow-flight-recorder.sh", ci_text)
        self.assertIn(
            "The registry and this full-suite call share the same lower-bound contract",
            run_text,
        )
        overview_text = (ROOT / "docs/DEVFLOW_SYSTEM_OVERVIEW.md").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            "a failure recap whenever an assertion or module boundary fails",
            overview_text,
        )
        trap_tail = run_text.split('IMPL_SKILL_BUNDLE="$(mktemp)"', maxsplit=1)[1]
        result_tally_traps = [
            line
            for line in trap_tail.splitlines()
            if line.startswith("trap ") and '"$RESULTS_FILE"' in line
        ]
        self.assertTrue(result_tally_traps)
        self.assertTrue(
            all(
                '"$IMPL_SKILL_BUNDLE"' in line
                and '"$MODULE_FAILURES_FILE"' in line
                and '"$SKIPS_FILE"' in line
                for line in result_tally_traps
            ),
            result_tally_traps,
        )

    def test_repository_registry_maps_the_review_and_fix_contract_module(self) -> None:
        registry = json.loads(
            (ROOT / "scripts/workflow-flight-recorder-registry.json").read_text(
                encoding="utf-8"
            )
        )
        mapping = registry["test_modules"]["review-and-fix-contract"]
        self.assertEqual(
            mapping["path"], "lib/test/modules/review-and-fix-contract.sh"
        )
        floor = mapping["minimum_assertions"]
        self.assertIsInstance(floor, int)
        self.assertGreater(floor, 0)
        self.assertTrue(REVIEW_AND_FIX_MODULE_SOURCE.is_file())

        run_text = (ROOT / "lib/test/run.sh").read_text(encoding="utf-8")
        self.assertIn(
            'devflow_run_full_suite_module "$LIB/test/modules/review-and-fix-contract.sh"',
            run_text,
        )
        floor_match = re.search(
            r'"review-and-fix-contract" ([0-9]+); then', run_text
        )
        self.assertIsNotNone(floor_match)
        self.assertEqual(int(floor_match.group(1)), floor)
        self.assertIn('python3 "$LIB/test/test_module_runner.py"', run_text)

        module_text = REVIEW_AND_FIX_MODULE_SOURCE.read_text(encoding="utf-8")
        self.assertTrue(
            module_text.startswith(
                "# SPDX-FileCopyrightText: 2026 Daniel Radman\n"
                "# SPDX-License-Identifier: MIT\n"
            )
        )
        self.assertIn("Contract: the caller sets LIB and RESULTS_FILE", module_text)
        self.assertNotIn('python3 "$LIB/test/test_module_runner.py"', module_text)
        self.assertNotIn("devflow_run_full_suite_module", module_text)
        self.assertIn("review-and-fix-contract.inventory.md", module_text)
        self.assertIn(
            "lib/test/modules/review-and-fix-contract.sh",
            (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8"),
        )

    def test_repository_registry_maps_the_create_issue_contract_module(self) -> None:
        registry = json.loads(
            (ROOT / "scripts/workflow-flight-recorder-registry.json").read_text(
                encoding="utf-8"
            )
        )
        mapping = registry["test_modules"]["create-issue-contract"]
        self.assertEqual(
            mapping["path"], "lib/test/modules/create-issue-contract.sh"
        )
        floor = mapping["minimum_assertions"]
        self.assertIsInstance(floor, int)
        self.assertGreater(floor, 0)
        self.assertTrue(CREATE_ISSUE_MODULE_SOURCE.is_file())

        run_text = (ROOT / "lib/test/run.sh").read_text(encoding="utf-8")
        self.assertIn(
            'devflow_run_full_suite_module "$LIB/test/modules/create-issue-contract.sh"',
            run_text,
        )
        # The full-suite call operand and the registry floor are one coupled contract.
        floor_match = re.search(
            r'"create-issue-contract" ([0-9]+); then', run_text
        )
        self.assertIsNotNone(floor_match)
        self.assertEqual(int(floor_match.group(1)), floor)
        self.assertIn('python3 "$LIB/test/test_module_runner.py"', run_text)

        module_text = CREATE_ISSUE_MODULE_SOURCE.read_text(encoding="utf-8")
        self.assertTrue(
            module_text.startswith(
                "# SPDX-FileCopyrightText: 2026 Daniel Radman\n"
                "# SPDX-License-Identifier: MIT\n"
            )
        )
        self.assertIn("Contract: the caller sets LIB and RESULTS_FILE", module_text)
        # A module never invokes the runner or the full-suite boundary itself.
        self.assertNotIn("devflow_run_full_suite_module", module_text)
        self.assertIn("create-issue-contract.inventory.md", module_text)
        self.assertIn(
            "lib/test/modules/create-issue-contract.sh",
            (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8"),
        )
        # The provenance inventory exists and is not a second behavioral source.
        inventory = ROOT / "lib/test/modules/create-issue-contract.inventory.md"
        self.assertTrue(inventory.is_file())

    def test_create_issue_contract_module_runs_green_through_the_real_runner(self) -> None:
        """The documented local create-issue path uses the real registry + module API."""
        registry = json.loads(
            (ROOT / "scripts/workflow-flight-recorder-registry.json").read_text(
                encoding="utf-8"
            )
        )
        floor = registry["test_modules"]["create-issue-contract"][
            "minimum_assertions"
        ]
        environment = os.environ.copy()
        environment.pop("DEVFLOW_TEST_EXPERIMENT_FORCE_FAILURE", None)
        with tempfile.TemporaryDirectory() as log_dir:
            result = subprocess.run(
                [
                    "bash",
                    str(RUNNER_SOURCE),
                    "--log-dir",
                    log_dir,
                    "create-issue-contract",
                ],
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(
                result.returncode,
                0,
                result.stdout[-4000:] + result.stderr[-4000:],
            )
            self.assertIn(
                f"Module create-issue-contract: {floor} passed, 0 failed",
                result.stdout,
            )
            self.assertTrue(list(Path(log_dir).iterdir()))

    def test_create_issue_module_references_no_monolith_helper(self) -> None:
        # AC7: the extracted assertions use only assert_eq plus the namespaced module
        # API — a reference to pin_count / probe_tmp / another monolith helper (which
        # would not exist when the runner or the full-suite boundary source the module)
        # must make this contract test fail.
        text = CREATE_ISSUE_MODULE_SOURCE.read_text(encoding="utf-8")
        hits = sorted({match.group(1) for match in MONOLITH_HELPER_RE.finditer(text)})
        self.assertEqual(
            hits, [], f"create-issue module references monolith helper(s): {hits}"
        )

    def test_monolith_helper_contract_check_is_non_vacuous(self) -> None:
        # The check FAILS on a planted monolith-helper reference (so the test above
        # is a real guard, not a vacuous pass) …
        for planted in (
            "x=$(pin_count 'a' \"$F\")\n",
            "t=$(probe_tmp 'a')\n",
            "assert_pin_unique n l f\n",
            "assert_pin_red_under n l m f\n",
            "b=$(probe_assert assert_pin_unique p l f)\n",
        ):
            self.assertIsNotNone(
                MONOLITH_HELPER_RE.search(planted), f"missed planted ref: {planted!r}"
            )
        # … and it does NOT false-positive on the sanctioned namespaced API, whose
        # `pin_count` substring is preceded by `_`.
        for sanctioned in (
            "devflow_module_pin_count 'a' \"$F\"\n",
            "devflow_module_pin_unique n l f\n",
            "devflow_module_pin_red_under n l m f\n",
        ):
            self.assertIsNone(
                MONOLITH_HELPER_RE.search(sanctioned),
                f"false positive on namespaced API: {sanctioned!r}",
            )

    def test_create_issue_bundle_records_fail_on_a_missing_implement_member(self) -> None:
        # The module's implement-bundle build loop restores the fail-LOUD-per-member
        # contract: a missing/empty/unreadable implement bundle member records a FAIL
        # (never the sibling module's silent `cat 2>/dev/null || :`). Pin it with an
        # automated mutation — point CI_ROOT at a scratch tree that symlinks every
        # real surface the module reads (so its 206 genuine pins still pass) but whose
        # implement `phases/` carries one EMPTY member (`[ -s ]` false → FAIL). The
        # emptied member is NOT the one holding the #467 D2 pinned sentence, so only
        # the bundle-member guard fires — isolating this branch.
        with tempfile.TemporaryDirectory() as temporary_directory:
            scratch = Path(temporary_directory) / "root"
            (scratch / "skills").mkdir(parents=True)
            (scratch / "lib/test").mkdir(parents=True)
            # Symlink every surface the module reads, except implement (partial copy).
            (scratch / "skills/create-issue").symlink_to(ROOT / "skills/create-issue")
            (scratch / "skills/review-and-fix").symlink_to(ROOT / "skills/review-and-fix")
            (scratch / "docs").symlink_to(ROOT / "docs")
            (scratch / ".devflow").symlink_to(ROOT / ".devflow")
            (scratch / "CLAUDE.md").symlink_to(ROOT / "CLAUDE.md")
            (scratch / "lib/test/modules").symlink_to(ROOT / "lib/test/modules")
            # implement: real SKILL.md, real phases EXCEPT one emptied member.
            impl = scratch / "skills/implement"
            (impl / "phases").mkdir(parents=True)
            (impl / "SKILL.md").symlink_to(ROOT / "skills/implement/SKILL.md")
            sentence = "The governed surface is broader than config JSON"  # #467 D2 pin
            emptied = None
            for phase in sorted((ROOT / "skills/implement/phases").glob("*.md")):
                text = phase.read_text(encoding="utf-8")
                if sentence in text or emptied is not None:
                    (impl / "phases" / phase.name).write_text(text, encoding="utf-8")
                else:
                    (impl / "phases" / phase.name).write_text("", encoding="utf-8")
                    emptied = phase.name
            self.assertIsNotNone(emptied, "no non-D2-pin phase to empty")

            environment = os.environ.copy()
            environment.pop("DEVFLOW_TEST_EXPERIMENT_FORCE_FAILURE", None)
            environment["DEVFLOW_CREATE_ISSUE_CONTRACT_ROOT"] = str(scratch)
            with tempfile.TemporaryDirectory() as log_dir:
                result = subprocess.run(
                    [
                        "bash",
                        str(RUNNER_SOURCE),
                        "--log-dir",
                        log_dir,
                        "create-issue-contract",
                    ],
                    cwd=ROOT,
                    env=environment,
                    text=True,
                    capture_output=True,
                    check=False,
                )

        self.assertEqual(result.returncode, 1, result.stdout[-4000:] + result.stderr[-4000:])
        self.assertIn("implement-bundle member usable", result.stdout)
        self.assertIn(emptied, result.stdout)

    def test_create_issue_module_runs_clean_under_nounset_with_legacy_vars_unset(self) -> None:
        # AC9: a clean-environment contract test. Source the module under `set -u`
        # with every legacy monolith variable explicitly unset, supplying only LIB,
        # RESULTS_FILE, assert_eq, and the namespaced harness API. The module must
        # derive every path from LIB and run without an unbound-variable exit.
        with tempfile.TemporaryDirectory() as temporary_directory:
            work = Path(temporary_directory)
            results = work / "results"
            driver = work / "driver.sh"
            driver.write_text(
                "#!/usr/bin/env bash\n"
                "set -u\n"
                "unset CI312_SKILL CI312_TMPL CI443_SKILL CI443_EXT CI522_OVERVIEW \\\n"
                "  CI464_OVERVIEW CI559_SKILL OG_OVERVIEW_DOC IMPL_SKILL_BUNDLE \\\n"
                "  MAXI_SKILL 2>/dev/null || true\n"
                f'LIB="{ROOT}/lib"\n'
                f'RESULTS_FILE="{results}"\n'
                '> "$RESULTS_FILE"\n'
                "assert_eq() {\n"
                '  if [ "$2" = "$3" ]; then printf "PASS\\n" >> "$RESULTS_FILE";\n'
                '  else printf "FAIL\\n" >> "$RESULTS_FILE"; fi\n'
                "}\n"
                f'. "{ROOT}/lib/test/module-harness.sh"\n'
                f'. "{ROOT}/lib/test/modules/create-issue-contract.sh"\n',
                encoding="utf-8",
            )
            result = subprocess.run(
                ["bash", str(driver)],
                cwd=work,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn("unbound variable", result.stderr)
            verdicts = results.read_text(encoding="utf-8").split()

        self.assertNotIn("FAIL", verdicts, result.stdout + result.stderr)
        self.assertGreater(len(verdicts), 0)

    def _write_mutant_create_issue_module(self, destination: Path) -> None:
        # A controlled create-issue module mutation: the real module plus one
        # deterministic failing assertion. DEVFLOW_CREATE_ISSUE_CONTRACT_ROOT points
        # the copy at the real repository so its genuine pins all pass and only the
        # planted assertion fails — isolating the mutation's single-FAIL delta.
        text = CREATE_ISSUE_MODULE_SOURCE.read_text(encoding="utf-8")
        text += '\nassert_eq "controlled create-issue mutation" "expected" "mutated"\n'
        destination.write_text(text, encoding="utf-8")

    def test_create_issue_focused_run_fails_closed_on_a_controlled_failure(self) -> None:
        # AC16: a create-issue module run whose assertion fails is caught and recapped
        # by the REAL focused runner (fail-closed, non-zero) — proving the runner's
        # crash/failure handling applies to the create-issue module, not only to the
        # synthetic sample/crash/empty modules exercised above.
        environment = os.environ.copy()
        environment["DEVFLOW_TEST_EXPERIMENT_FORCE_FAILURE"] = "1"
        with tempfile.TemporaryDirectory() as log_dir:
            result = subprocess.run(
                [
                    "bash",
                    str(RUNNER_SOURCE),
                    "--log-dir",
                    log_dir,
                    "create-issue-contract",
                ],
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )

        self.assertEqual(result.returncode, 1, result.stdout[-4000:] + result.stderr[-4000:])
        self.assertIn("controlled experimental failure injection", result.stdout)
        self.assertRegex(
            result.stdout, r"Module create-issue-contract: [0-9]+ passed, 1 failed"
        )

    def test_controlled_mutation_fails_on_both_focused_and_full_suite_boundaries(self) -> None:
        # AC17: the focused runner and the complete-suite boundary observe the SAME
        # failing outcome from one controlled create-issue module mutation.
        mutant = self.modules_dir / "create-issue-mutant.sh"
        self._write_mutant_create_issue_module(mutant)
        self._write_registry(
            {
                "create-issue-mutant": {
                    "path": "lib/test/modules/create-issue-mutant.sh",
                    "minimum_assertions": 1,
                }
            }
        )
        base_env = {"DEVFLOW_CREATE_ISSUE_CONTRACT_ROOT": str(ROOT)}

        # Focused runner boundary.
        focused = self._run("create-issue-mutant", extra_env=base_env)
        self.assertEqual(focused.returncode, 1, focused.stdout + focused.stderr)
        self.assertIn("controlled create-issue mutation", focused.stdout)

        # Full-suite module boundary (module-harness.sh's devflow_run_full_suite_module).
        # A failing assertion lands in the shared RESULTS_FILE tally the way run.sh's own
        # FAIL loop counts it (the boundary's MODULE_FAILURES_FILE fold is reserved for
        # crash/floor/tally faults), so the boundary's observed failure is the FAIL record
        # the module appended to RESULTS_FILE — count that.
        with tempfile.TemporaryDirectory() as work_name:
            work = Path(work_name)
            results = work / "results"
            driver = work / "driver.sh"
            driver.write_text(
                "#!/usr/bin/env bash\n"
                f'RESULTS_FILE="{results}"\n'
                f'MODULE_FAILURES_FILE="{work / "module-failures"}"\n'
                '> "$RESULTS_FILE"\n'
                '> "$MODULE_FAILURES_FILE"\n'
                "assert_eq() {\n"
                '  if [ "$2" = "$3" ]; then printf "PASS\\n" >> "$RESULTS_FILE";\n'
                '  else printf "FAIL\\n" >> "$RESULTS_FILE"; fi\n'
                "}\n"
                f'. "{HARNESS_SOURCE}"\n'
                f'devflow_run_full_suite_module "{mutant}" "create-issue-mutant" 1\n',
                encoding="utf-8",
            )
            environment = os.environ.copy()
            environment.update(base_env)
            full_suite = subprocess.run(
                ["bash", str(driver)],
                cwd=work,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(
                full_suite.returncode, 0, full_suite.stdout + full_suite.stderr
            )
            boundary_verdicts = results.read_text(encoding="utf-8").split()

        # Same outcome: the full-suite boundary's tally carries the mutation's FAIL,
        # exactly as the focused runner reported it non-zero above.
        self.assertIn("FAIL", boundary_verdicts, full_suite.stdout + full_suite.stderr)


if __name__ == "__main__":
    unittest.main()
