#!/usr/bin/env python3
"""Focused tests for the full-suite source boundary around test modules."""

# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
HARNESS = ROOT / "lib/test/module-harness.sh"
RUNNER = ROOT / "lib/test/run-module.sh"
CREATE_ISSUE_MODULE = ROOT / "lib/test/modules/create-issue-contract.sh"


class FullSuiteModuleHarnessTests(unittest.TestCase):
    def _run_support_driver(self, driver_body: str) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            driver = root / "driver.sh"
            driver.write_text(
                "#!/usr/bin/env bash\n"
                f"RESULTS_FILE={root / 'results'}\n"
                f"MODULE_FAILURES_FILE={root / 'module-failures'}\n"
                f"SKIPS_FILE={root / 'skips'}\n"
                '> "$RESULTS_FILE"\n'
                '> "$MODULE_FAILURES_FILE"\n'
                '> "$SKIPS_FILE"\n'
                "assert_eq() {\n"
                '  if [ "$2" = "$3" ]; then printf "PASS\\n" >> "$RESULTS_FILE";\n'
                '  else printf "FAIL\\n" >> "$RESULTS_FILE"; fi\n'
                "}\n"
                f'. "{HARNESS}"\n'
                + driver_body,
                encoding="utf-8",
            )
            return subprocess.run(
                ["bash", str(driver)],
                cwd=root,
                text=True,
                capture_output=True,
                check=False,
            )

    def _run(
        self,
        module_body: str | None,
        *,
        initial_results: str = "",
        module_failures_are_directory: bool = False,
        minimum_assertions: int | str = 1,
        report_boundary_rc: bool = False,
        report_marker: bool = False,
        results_are_directory: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            module = root / "module.sh"
            if module_body is not None:
                module.write_text(module_body, encoding="utf-8")
            driver = root / "driver.sh"
            results_setup = (
                f"mkdir {root / 'results'}\n"
                if results_are_directory
                else f"printf '%b' {initial_results!r} > {str(root / 'results')!r}\n"
            )
            module_failures_setup = (
                'mkdir "$MODULE_FAILURES_FILE"\n'
                if module_failures_are_directory
                else '> "$MODULE_FAILURES_FILE"\n'
            )
            driver_text = (
                "#!/usr/bin/env bash\n"
                f"RESULTS_FILE={root / 'results'}\n"
                f"MODULE_FAILURES_FILE={root / 'module-failures'}\n"
                f"MODULE_MARKER={root / 'module-marker'}\n"
                + results_setup
                + module_failures_setup
                + f'. "{HARNESS}"\n'
                + f'if devflow_run_full_suite_module "{module}" "sample" {minimum_assertions}; '
                + "then BOUNDARY_RC=0; else BOUNDARY_RC=$?; fi\n"
                + ('echo "BOUNDARY_RC:$BOUNDARY_RC"\n' if report_boundary_rc else "")
                + (
                    'if [ -e "$MODULE_MARKER" ]; then echo MODULE_SOURCED; '
                    "else echo MODULE_NOT_SOURCED; fi\n"
                    if report_marker
                    else ""
                )
                + 'if [ -f "$RESULTS_FILE" ]; then cat "$RESULTS_FILE"; fi\n'
                + 'if [ -f "$MODULE_FAILURES_FILE" ]; then '
                + 'sed "s/^/BOUNDARY:/" "$MODULE_FAILURES_FILE"; fi\n'
            )
            driver.write_text(driver_text, encoding="utf-8")
            return subprocess.run(
                ["bash", str(driver)],
                cwd=root,
                text=True,
                capture_output=True,
                check=False,
            )

    def test_module_with_assertion_contributes_result_without_boundary_failure(self) -> None:
        result = self._run('printf "PASS\\n" >> "$RESULTS_FILE"\n')

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["PASS"])

    def test_module_cannot_rewrite_prior_suite_verdicts(self) -> None:
        result = self._run(
            'printf "PASS\\n" > "$RESULTS_FILE"\n', initial_results="FAIL\n"
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["FAIL", "PASS"])

    def test_boundary_failure_is_folded_into_terminal_failure_count(self) -> None:
        result = self._run_support_driver(
            'MODULE="$RESULTS_FILE.missing"\n'
            'devflow_run_full_suite_module "$MODULE" "missing" 1\n'
            'FAIL="$(devflow_fold_module_failures 0)" || exit 3\n'
            'printf "terminal failures: %s\\n" "$FAIL"\n'
            '[ "$FAIL" -eq 0 ]\n'
        )

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("terminal failures: 1", result.stdout)

    def test_module_failure_fold_fails_closed_when_tally_is_unreadable(self) -> None:
        result = self._run_support_driver(
            'rm -f "$MODULE_FAILURES_FILE"\n'
            'mkdir "$MODULE_FAILURES_FILE"\n'
            'if devflow_fold_module_failures 0; then echo FOLD_OPEN; else echo FOLD_CLOSED; fi\n'
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("FOLD_CLOSED", result.stdout.splitlines())

    def test_module_failure_fold_rejects_malformed_records(self) -> None:
        result = self._run_support_driver(
            'printf "PASS\\n" > "$MODULE_FAILURES_FILE"\n'
            'if devflow_fold_module_failures 0; then echo FOLD_OPEN; else echo FOLD_CLOSED; fi\n'
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("FOLD_CLOSED", result.stdout.splitlines())

    def test_module_failure_fold_rejects_a_non_numeric_operand(self) -> None:
        result = self._run_support_driver(
            'if devflow_fold_module_failures "abc"; then echo FOLD_OPEN; else echo FOLD_CLOSED; fi\n'
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("FOLD_CLOSED", result.stdout.splitlines())

    def test_focused_python_failure_prints_captured_diagnostics(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            failing_test = root / "failing.py"
            captured = root / "captured.out"
            failing_test.write_text(
                'raise RuntimeError("diagnostic sentinel")\n', encoding="utf-8"
            )
            result = self._run_support_driver(
                f'devflow_run_focused_python_test "focused fixture" "{failing_test}" '
                f'"{captured}"\n'
                'cat "$RESULTS_FILE"\n'
            )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("RuntimeError: diagnostic sentinel", result.stdout)
        self.assertIn("FAIL", result.stdout.splitlines())

    def test_missing_module_records_failure_and_keeps_driver_alive(self) -> None:
        result = self._run(None)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("BOUNDARY:FAIL", result.stdout.splitlines())
        self.assertIn("missing or unreadable", result.stderr)

    def test_module_exit_records_failure_and_keeps_driver_alive(self) -> None:
        result = self._run("exit 7\n")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("BOUNDARY:FAIL", result.stdout.splitlines())
        self.assertIn("exited with status 7", result.stderr)

    def test_zero_assertion_module_records_failure(self) -> None:
        result = self._run(":\n")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("BOUNDARY:FAIL", result.stdout.splitlines())
        self.assertIn("executed zero assertions", result.stderr)

    def test_module_below_assertion_floor_records_boundary_failure(self) -> None:
        result = self._run(
            'printf "PASS\\n" >> "$RESULTS_FILE"\n', minimum_assertions=2
        )

        self.assertIn("BOUNDARY:FAIL", result.stdout.splitlines())
        self.assertIn("executed 1 assertions; minimum is 2", result.stderr)

    def test_oversized_assertion_floor_fails_closed_without_arithmetic(self) -> None:
        result = self._run(
            'printf "PASS\\n" >> "$RESULTS_FILE"\n',
            minimum_assertions=10**100,
        )

        self.assertIn("BOUNDARY:FAIL", result.stdout.splitlines())
        self.assertIn("invalid minimum assertion count", result.stderr)

    def test_numeric_assertion_floor_bounds_fail_closed(self) -> None:
        for floor in (0, 1_000_001):
            with self.subTest(floor=floor):
                result = self._run(
                    'printf "PASS\\n" >> "$RESULTS_FILE"\n',
                    minimum_assertions=floor,
                )

                self.assertIn("BOUNDARY:FAIL", result.stdout.splitlines())
                self.assertIn("invalid minimum assertion count", result.stderr)

    def test_padded_zero_assertion_floor_fails_closed(self) -> None:
        result = self._run(
            'printf "PASS\\n" >> "$RESULTS_FILE"\n', minimum_assertions="00"
        )

        self.assertIn("BOUNDARY:FAIL", result.stdout.splitlines())
        self.assertIn("invalid minimum assertion count: 00", result.stderr)

    def test_module_cannot_sabotage_private_boundary_failure_channel(self) -> None:
        result = self._run(
            'if [ -n "${MODULE_FAILURES_FILE+x}" ]; then '
            'rm -f "$MODULE_FAILURES_FILE"; mkdir "$MODULE_FAILURES_FILE"; fi\n'
            'printf "PASS\\n" >> "$RESULTS_FILE"\nexit 7\n'
        )

        self.assertIn("BOUNDARY:FAIL", result.stdout.splitlines())
        self.assertIn("exited with status 7", result.stderr)

    def test_unavailable_boundary_failure_channel_returns_nonzero(self) -> None:
        result = self._run(
            "exit 7\n",
            module_failures_are_directory=True,
            report_boundary_rc=True,
        )

        self.assertIn("BOUNDARY_RC:1", result.stdout.splitlines())
        self.assertIn("could not record boundary failure", result.stderr)

    def test_unbound_variable_records_process_failure_even_for_permissive_caller(self) -> None:
        result = self._run('printf "%s\\n" "$UNBOUND_MODULE_VALUE"\n')

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("BOUNDARY:FAIL", result.stdout.splitlines())
        self.assertIn("exited with status", result.stderr)

    def test_unreadable_tally_before_module_execution_fails_closed(self) -> None:
        result = self._run(
            'printf "sourced\\n" > "$MODULE_MARKER"\n'
            'printf "PASS\\n" >> "$RESULTS_FILE"\n',
            report_marker=True,
            results_are_directory=True,
        )

        self.assertIn("result tally unreadable before module execution", result.stderr)
        self.assertIn("MODULE_NOT_SOURCED", result.stdout.splitlines())

    def test_unreadable_tally_after_module_execution_fails_closed(self) -> None:
        result = self._run(
            'printf "sourced\\n" > "$MODULE_MARKER"\n'
            'rm -f "$RESULTS_FILE"\nmkdir "$RESULTS_FILE"\n'
            'printf "PASS\\n" > "$RESULTS_FILE/record"\n',
            report_marker=True,
        )

        self.assertIn("result tally unreadable after module execution", result.stderr)
        self.assertIn("MODULE_SOURCED", result.stdout.splitlines())
        self.assertIn("BOUNDARY:FAIL", result.stdout.splitlines())

    def test_invalid_tally_before_module_execution_fails_closed(self) -> None:
        result = self._run(
            'printf "sourced\\n" > "$MODULE_MARKER"\n'
            'printf "PASS\\n" >> "$RESULTS_FILE"\n',
            initial_results="INVALID\n",
            report_marker=True,
        )

        self.assertIn("result tally unreadable before module execution", result.stderr)
        self.assertIn("MODULE_NOT_SOURCED", result.stdout.splitlines())

    def test_invalid_tally_after_module_execution_fails_closed(self) -> None:
        result = self._run(
            'printf "sourced\\n" > "$MODULE_MARKER"\n'
            'printf "INVALID\\n" >> "$RESULTS_FILE"\n',
            report_marker=True,
        )

        self.assertIn("result tally unreadable after module execution", result.stderr)
        self.assertIn("MODULE_SOURCED", result.stdout.splitlines())


class SignalCleanupMatrixTests(unittest.TestCase):
    """Signal cleanup is symmetric across focused and complete-suite boundaries."""

    signals = (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)
    scopes = ("parent-only", "module-only", "process-group")
    boundaries = ("focused", "full-suite")

    @staticmethod
    def _pid_exists(pid: int) -> bool:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        return True

    def _wait_for_signal_state(
        self, process: subprocess.Popen[str], required: tuple[Path, ...]
    ) -> None:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if all(path.is_file() and path.stat().st_size > 0 for path in required):
                return
            if process.poll() is not None:
                break
            time.sleep(0.02)
        missing = [
            str(path)
            for path in required
            if not path.is_file() or path.stat().st_size == 0
        ]
        self.fail(
            "signal fixture did not publish its PID/state files; "
            f"missing={missing}, rc={process.poll()}"
        )

    def _build_signal_fixture(self, row: Path) -> tuple[Path, Path, Path]:
        repo = row / "repo"
        test_dir = repo / "lib/test"
        modules_dir = test_dir / "modules"
        scripts_dir = repo / "scripts"
        modules_dir.mkdir(parents=True)
        scripts_dir.mkdir()
        shutil.copy2(RUNNER, test_dir / "run-module.sh")
        shutil.copy2(HARNESS, test_dir / "module-harness.sh")

        module = modules_dir / "signal-create-issue.sh"
        module_text = CREATE_ISSUE_MODULE.read_text(encoding="utf-8")
        insertion_point = "# The implement-skill bundle backs the #467 D2 Phase-2.4 leg"
        signal_pause = (
            '# Test-only signal fixture: the copied module pauses only when the matrix sets '
            'DEVFLOW_TEST_MODULE_STATE_FILE.\n'
            'trap -p INT > "$DEVFLOW_TEST_MODULE_STATE_FILE.trap"\n'
            '_ci_signal_fixture="$_ci_tmp_root/signal-source"\n'
            'printf \'operative\\n\' > "$_ci_signal_fixture"\n'
            'sed() {\n'
            '  printf \'%s\\n\' "$_ci_tmp_root" '
            '> "$DEVFLOW_TEST_MODULE_STATE_FILE" || return 1\n'
            '  while :; do :; done\n'
            '}\n'
            'devflow_module_pin_red_under "signal helper" "operative" '
            '"s/operative//" "$_ci_signal_fixture"\n\n'
        )
        self.assertIn(insertion_point, module_text)
        module.write_text(
            module_text.replace(insertion_point, signal_pause + insertion_point, 1),
            encoding="utf-8",
        )
        registry = {
            "schema_version": 1,
            "workflows": {"placeholder": {}},
            "test_modules": {
                "signal-create-issue": {
                    "path": "lib/test/modules/signal-create-issue.sh",
                    "description": "signal cleanup fixture",
                    "minimum_assertions": 1,
                }
            },
        }
        registry_path = scripts_dir / "workflow-flight-recorder-registry.json"
        registry_path.write_text(json.dumps(registry), encoding="utf-8")
        return repo, module, registry_path

    def _start_row(
        self, boundary: str, row: Path
    ) -> tuple[subprocess.Popen[str], Path, Path, Path, Path, Path, Path, Path]:
        repo, module, registry = self._build_signal_fixture(row)
        controlled_tmp = row / "tmp"
        controlled_tmp.mkdir()
        runner_pid_file = row / "runner.pid"
        module_pid_file = row / "module.pid"
        module_state_file = row / "module.state"
        runner_cleanup_marker = row / "runner-cleanup.marker"
        module_cleanup_marker = row / "module-cleanup.marker"
        caller_exit_marker = row / "caller-exit.marker"
        environment = os.environ.copy()
        for name in (
            "DEVFLOW_TEST_RUNNER_PID_FILE",
            "DEVFLOW_TEST_MODULE_PID_FILE",
            "DEVFLOW_TEST_RUNNER_CLEANUP_MARKER",
            "DEVFLOW_TEST_MODULE_CLEANUP_MARKER",
            "DEVFLOW_TEST_MODULE_STATE_FILE",
        ):
            environment.pop(name, None)
        environment.update(
            {
                "TMPDIR": str(controlled_tmp),
                "DEVFLOW_CREATE_ISSUE_CONTRACT_ROOT": str(ROOT),
                "DEVFLOW_TEST_RUNNER_PID_FILE": str(runner_pid_file),
                "DEVFLOW_TEST_MODULE_PID_FILE": str(module_pid_file),
                "DEVFLOW_TEST_RUNNER_CLEANUP_MARKER": str(runner_cleanup_marker),
                "DEVFLOW_TEST_MODULE_CLEANUP_MARKER": str(module_cleanup_marker),
                "DEVFLOW_TEST_MODULE_STATE_FILE": str(module_state_file),
            }
        )

        if boundary == "focused":
            command = [
                "bash",
                str(repo / "lib/test/run-module.sh"),
                "--registry",
                str(registry),
                "--log-dir",
                str(row / "logs"),
                "signal-create-issue",
            ]
            cwd = repo
        else:
            driver = row / "full-suite-driver.sh"
            results = row / "suite-results"
            failures = row / "module-failures"
            driver.write_text(
                "#!/usr/bin/env bash\n"
                "set -u\n"
                f'LIB="{ROOT / "lib"}"\n'
                f'RESULTS_FILE="{results}"\n'
                f'MODULE_FAILURES_FILE="{failures}"\n'
                f'CALLER_EXIT_MARKER="{caller_exit_marker}"\n'
                '> "$RESULTS_FILE"\n'
                '> "$MODULE_FAILURES_FILE"\n'
                'trap \'printf "caller-exit\\n" >> "$CALLER_EXIT_MARKER"\' EXIT\n'
                "assert_eq() {\n"
                '  if [ "$2" = "$3" ]; then printf "PASS\\n" >> "$RESULTS_FILE";\n'
                '  else printf "FAIL\\n" >> "$RESULTS_FILE"; fi\n'
                "}\n"
                f'. "{repo / "lib/test/module-harness.sh"}"\n'
                f'devflow_run_full_suite_module "{module}" "signal-create-issue" 1\n',
                encoding="utf-8",
            )
            command = ["bash", str(driver)]
            cwd = row

        process = subprocess.Popen(
            command,
            cwd=cwd,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        return (
            process,
            controlled_tmp,
            runner_pid_file,
            module_pid_file,
            module_state_file,
            runner_cleanup_marker,
            module_cleanup_marker,
            caller_exit_marker,
        )

    def _exercise_row(self, boundary: str, signal_number: int, scope: str) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            row = Path(temporary_directory)
            (
                process,
                controlled_tmp,
                runner_pid_file,
                module_pid_file,
                module_state_file,
                runner_cleanup_marker,
                module_cleanup_marker,
                caller_exit_marker,
            ) = self._start_row(boundary, row)
            stdout = ""
            stderr = ""
            try:
                module_int_trap_file = Path(f"{module_state_file}.trap")
                self._wait_for_signal_state(
                    process,
                    (
                        runner_pid_file,
                        module_pid_file,
                        module_state_file,
                        module_int_trap_file,
                    ),
                )
                runner_pid = int(runner_pid_file.read_text(encoding="utf-8").strip())
                module_pid = int(module_pid_file.read_text(encoding="utf-8").strip())
                module_root = Path(
                    module_state_file.read_text(encoding="utf-8").strip()
                )
                helper_scratches = list(module_root.glob("devflow-module-mut.*"))
                self.assertEqual(runner_pid, process.pid)
                self.assertNotEqual(module_pid, runner_pid)
                module_int_trap = module_int_trap_file.read_text(encoding="utf-8")
                self.assertIn("SIGINT", module_int_trap)
                self.assertNotIn("trap -- '' SIGINT", module_int_trap)
                self.assertTrue(module_root.is_dir())
                self.assertEqual(len(helper_scratches), 1)
                helper_scratch = helper_scratches[0]
                self.assertTrue(helper_scratch.is_file())

                if scope == "parent-only":
                    os.kill(runner_pid, signal_number)
                elif scope == "module-only":
                    os.kill(module_pid, signal_number)
                else:
                    os.killpg(runner_pid, signal_number)

                started = time.monotonic()
                bounded = True
                try:
                    stdout, stderr = process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    bounded = False
                elapsed = time.monotonic() - started
                if not bounded:
                    try:
                        os.killpg(runner_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    stdout, stderr = process.communicate(timeout=2)
                self.assertTrue(
                    bounded,
                    f"row exceeded cleanup bound: {boundary}/{signal_number}/{scope}\n"
                    f"stdout={stdout[-2000:]}\nstderr={stderr[-2000:]}",
                )
                self.assertLess(elapsed, 5)

                deadline = time.monotonic() + 2
                while self._pid_exists(module_pid) and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertFalse(self._pid_exists(module_pid), "module subprocess survived")
                self.assertFalse(module_root.exists(), "module scratch root survived")
                self.assertFalse(helper_scratch.exists(), "module helper scratch survived")
                leftovers = sorted(path.name for path in controlled_tmp.iterdir())
                leaked = [
                    name
                    for name in leftovers
                    if name.startswith(
                        (
                            "devflow-module-results.",
                            "devflow-module-details.",
                            "devflow-module-tally.",
                            "devflow-create-issue-contract.",
                            "devflow-module-mut.",
                        )
                    )
                ]
                self.assertEqual(leaked, [], f"cleanup artifacts survived: {leaked}")
                self.assertEqual(
                    runner_cleanup_marker.read_text(encoding="utf-8").splitlines(),
                    ["runner-cleanup"],
                )
                self.assertEqual(
                    module_cleanup_marker.read_text(encoding="utf-8").splitlines(),
                    ["module-cleanup"],
                )
                if boundary == "full-suite":
                    self.assertEqual(
                        caller_exit_marker.read_text(encoding="utf-8").splitlines(),
                        ["caller-exit"],
                    )
            finally:
                if process.poll() is None:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.communicate(timeout=2)

    def test_signal_cleanup_matrix(self) -> None:
        for boundary in self.boundaries:
            for signal_number in self.signals:
                for scope in self.scopes:
                    with self.subTest(
                        boundary=boundary,
                        signal=signal.Signals(signal_number).name,
                        scope=scope,
                    ):
                        self._exercise_row(boundary, signal_number, scope)

    def test_full_suite_boundary_restores_caller_signal_traps(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            module = root / "module.sh"
            marker = root / "marker"
            module.write_text('printf "PASS\\n" >> "$RESULTS_FILE"\n', encoding="utf-8")
            driver = root / "driver.sh"
            driver.write_text(
                "#!/usr/bin/env bash\n"
                f'RESULTS_FILE="{root / "results"}"\n'
                f'MODULE_FAILURES_FILE="{root / "failures"}"\n'
                '> "$RESULTS_FILE"\n'
                '> "$MODULE_FAILURES_FILE"\n'
                f'MARKER="{marker}"\n'
                'trap \'printf "caller-exit\\n" >> "$MARKER"\' EXIT\n'
                'trap \'printf "caller-hup\\n" >> "$MARKER"\' HUP\n'
                'trap \'printf "caller-int\\n" >> "$MARKER"\' INT\n'
                'trap \'printf "caller-term\\n" >> "$MARKER"\' TERM\n'
                "assert_eq() { :; }\n"
                f'. "{HARNESS}"\n'
                f'devflow_run_full_suite_module "{module}" "sample" 1\n'
                'kill -s HUP "$$"\n'
                'kill -s INT "$$"\n'
                'kill -s TERM "$$"\n',
                encoding="utf-8",
            )
            process = subprocess.run(
                ["bash", str(driver)], text=True, capture_output=True, check=False
            )
            records = marker.read_text(encoding="utf-8").splitlines()

        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        self.assertEqual(
            records,
            ["caller-hup", "caller-int", "caller-term", "caller-exit"],
        )


class NamespacedModulePinHelperTests(unittest.TestCase):
    """AC11/AC12: the shared devflow_module_* pin/count/mutation helpers."""

    def _drive(self, body: str) -> tuple[subprocess.CompletedProcess[str], list[str]]:
        # Runs BODY with RESULTS_FILE + a minimal assert_eq + the sourced harness,
        # under a controlled TMPDIR. Returns the process and the RESULTS_FILE
        # verdicts. (Tests that must inspect the TMPDIR after the run keep their own
        # driver open — a helper cannot outlive its TemporaryDirectory.)
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            controlled_tmp = root / "tmp"
            controlled_tmp.mkdir()
            results = root / "results"
            driver = root / "driver.sh"
            driver.write_text(
                "#!/usr/bin/env bash\n"
                f'RESULTS_FILE="{results}"\n'
                f'export TMPDIR="{controlled_tmp}"\n'
                '> "$RESULTS_FILE"\n'
                "assert_eq() {\n"
                '  if [ "$2" = "$3" ]; then printf "PASS\\n" >> "$RESULTS_FILE";\n'
                '  else printf "FAIL\\n" >> "$RESULTS_FILE"; fi\n'
                "}\n"
                f'. "{HARNESS}"\n'
                + body,
                encoding="utf-8",
            )
            process = subprocess.run(
                ["bash", str(driver)],
                cwd=root,
                text=True,
                capture_output=True,
                check=False,
            )
            verdicts = (
                results.read_text(encoding="utf-8").split()
                if results.exists()
                else []
            )
            return process, verdicts

    def test_pin_count_counts_fixed_string_occurrences(self) -> None:
        process, _ = self._drive(
            'F="$(mktemp)"; printf "alpha beta alpha\\nalpha\\n" > "$F"\n'
            'C="$(devflow_module_pin_count "alpha" "$F")"; RC=$?\n'
            'echo "COUNT:$C RC:$RC"\n'
        )
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        self.assertIn("COUNT:3 RC:0", process.stdout)

    def test_pin_count_readable_zero_is_distinct_from_unestablished(self) -> None:
        # A readable file with zero matches returns "0" (rc 0); unreadable input
        # returns "unestablished" (rc 1), never "0" — so a zero-expected assertion
        # PASSES on the readable-zero and turns RED on the unestablished input.
        process, verdicts = self._drive(
            'F="$(mktemp)"; printf "nothing to see\\n" > "$F"\n'
            'Z="$(devflow_module_pin_count "absent" "$F")"; ZRC=$?\n'
            'echo "ZERO:$Z ZRC:$ZRC"\n'
            'assert_eq "readable zero-match" "0" "$Z"\n'
            'U="$(devflow_module_pin_count "absent" "/no/such/file")"; URC=$?\n'
            'echo "UNREAD:$U URC:$URC"\n'
            'assert_eq "unreadable is zero-RED" "0" "$U"\n'
        )
        self.assertIn("ZERO:0 ZRC:0", process.stdout)
        self.assertIn("UNREAD:unestablished URC:1", process.stdout)
        self.assertIn("unreadable file", process.stderr)
        # readable-zero PASSes the zero-expected assertion; unreadable turns it RED.
        self.assertEqual(verdicts, ["PASS", "FAIL"], process.stdout + process.stderr)

    def _drive_with_fake_python3(self, python3_body: str, expect_stderr: str) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fake_bin = root / "fake-bin"
            fake_bin.mkdir()
            fake = fake_bin / "python3"
            fake.write_text("#!/usr/bin/env bash\n" + python3_body, encoding="utf-8")
            fake.chmod(0o755)
            results = root / "results"
            fixture = root / "fixture"
            fixture.write_text("literal literal\n", encoding="utf-8")
            driver = root / "driver.sh"
            driver.write_text(
                "#!/usr/bin/env bash\n"
                f'RESULTS_FILE="{results}"\n'
                f'export PATH="{fake_bin}:$PATH"\n'
                '> "$RESULTS_FILE"\n'
                "assert_eq() {\n"
                '  if [ "$2" = "$3" ]; then printf "PASS\\n" >> "$RESULTS_FILE";\n'
                '  else printf "FAIL\\n" >> "$RESULTS_FILE"; fi\n'
                "}\n"
                f'. "{HARNESS}"\n'
                f'C="$(devflow_module_pin_count "literal" "{fixture}")"; RC=$?\n'
                'echo "COUNT:$C RC:$RC"\n'
                'assert_eq "zero-expected under fake python3" "0" "$C"\n',
                encoding="utf-8",
            )
            process = subprocess.run(
                ["bash", str(driver)],
                cwd=root,
                text=True,
                capture_output=True,
                check=False,
            )
            verdicts = results.read_text(encoding="utf-8").split()
        # Every unestablished-count row: the count is "unestablished" (never 0), the
        # breadcrumb names the kind, and the zero-expected assertion turns RED.
        self.assertIn("COUNT:unestablished RC:1", process.stdout)
        self.assertIn(expect_stderr, process.stderr)
        self.assertEqual(verdicts, ["FAIL"], process.stdout + process.stderr)

    def test_pin_count_missing_or_failed_python3_is_unestablished(self) -> None:
        # "missing Python" (command-not-found rc) and an interpreter fault both
        # surface as a non-zero interpreter exit → unestablished, never 0.
        self._drive_with_fake_python3("exit 127\n", "python3 counter failed")
        self._drive_with_fake_python3("exit 1\n", "python3 counter failed")

    def test_pin_count_malformed_output_is_unestablished(self) -> None:
        self._drive_with_fake_python3(
            'printf "not-a-number\\n"\nexit 0\n', "malformed counter output"
        )

    def test_pin_unique_passes_on_exactly_one_and_reds_otherwise(self) -> None:
        process, verdicts = self._drive(
            'ONE="$(mktemp)"; printf "the marker line\\nother\\n" > "$ONE"\n'
            'devflow_module_pin_unique "unique present" "the marker line" "$ONE"\n'
            'TWO="$(mktemp)"; printf "dup\\ndup\\n" > "$TWO"\n'
            'devflow_module_pin_unique "duplicated -> RED" "dup" "$TWO"\n'
            'devflow_module_pin_unique "unreadable -> RED" "x" "/no/such/file"\n'
        )
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        self.assertEqual(verdicts, ["PASS", "FAIL", "FAIL"], process.stdout + process.stderr)

    def test_pin_present_passes_on_one_or_more_and_reds_on_zero_or_unestablished(self) -> None:
        process, verdicts = self._drive(
            'F="$(mktemp)"; printf "recurs\\nrecurs\\nother\\n" > "$F"\n'
            'devflow_module_pin_present "recurring value present" "recurs" "$F"\n'
            'devflow_module_pin_present "single present" "other" "$F"\n'
            'devflow_module_pin_present "absent -> RED" "nope" "$F"\n'
            'devflow_module_pin_present "unreadable -> RED" "x" "/no/such/file"\n'
        )
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        self.assertEqual(
            verdicts, ["PASS", "PASS", "FAIL", "FAIL"], process.stdout + process.stderr
        )

    def test_pin_red_under_flips_on_operative_mutation_and_cleans_scratch(self) -> None:
        process, verdicts = self._drive(
            'F="$(mktemp)"; printf "operative sentence here\\nkeep\\n" > "$F"\n'
            '# Operative mutation removes the pinned sentence -> PASS->FAIL -> PASS.\n'
            'devflow_module_pin_red_under "operative mutation flips" '
            '"operative sentence here" "s/operative sentence here//" "$F"\n'
            '# A no-op mutation is never a vacuous pass -> RED.\n'
            'devflow_module_pin_red_under "noop mutation is RED" '
            '"operative sentence here" "s/ZZZ_NEVER_MATCHES//" "$F"\n'
            '# An unreadable file -> RED.\n'
            'devflow_module_pin_red_under "unreadable is RED" '
            '"x" "s/x//" "/no/such/file"\n'
            '# A malformed sed program is never a vacuous pass -> RED.\n'
            'devflow_module_pin_red_under "sed error is RED" '
            '"operative sentence here" "s/(/" "$F"\n'
        )
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        self.assertEqual(
            verdicts, ["PASS", "FAIL", "FAIL", "FAIL"], process.stdout + process.stderr
        )

    def test_pin_red_under_mktemp_failure_is_red(self) -> None:
        # The mktemp-failure branch records a RED verdict (never a false PASS) when a
        # scratch copy cannot be allocated. Shadow `mktemp` with a fake that exits 1.
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fake_bin = root / "fake-bin"
            fake_bin.mkdir()
            (fake_bin / "mktemp").write_text(
                "#!/usr/bin/env bash\nexit 1\n", encoding="utf-8"
            )
            (fake_bin / "mktemp").chmod(0o755)
            results = root / "results"
            fixture = root / "fixture"
            fixture.write_text("pinned line\nkeep\n", encoding="utf-8")
            driver = root / "driver.sh"
            driver.write_text(
                "#!/usr/bin/env bash\n"
                f'RESULTS_FILE="{results}"\n'
                f'export PATH="{fake_bin}:$PATH"\n'
                '> "$RESULTS_FILE"\n'
                "assert_eq() {\n"
                '  if [ "$2" = "$3" ]; then printf "PASS\\n" >> "$RESULTS_FILE";\n'
                '  else printf "FAIL\\n" >> "$RESULTS_FILE"; fi\n'
                "}\n"
                f'. "{HARNESS}"\n'
                f'devflow_module_pin_red_under "mktemp failure is RED" '
                f'"pinned line" "s/pinned line//" "{fixture}"\n',
                encoding="utf-8",
            )
            process = subprocess.run(
                ["bash", str(driver)],
                cwd=root,
                text=True,
                capture_output=True,
                check=False,
            )
            verdicts = results.read_text(encoding="utf-8").split()
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        self.assertEqual(verdicts, ["FAIL"], process.stdout + process.stderr)

    def test_pin_red_under_removes_its_scratch_on_every_return_path(self) -> None:
        # Run several return paths (flip, no-op, unreadable, sed-error) and confirm
        # NO devflow-module-mut.* scratch survives in the controlled TMPDIR.
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            controlled_tmp = root / "tmp"
            controlled_tmp.mkdir()
            results = root / "results"
            fixture = root / "fixture"
            fixture.write_text("pinned line\nkeep\n", encoding="utf-8")
            driver = root / "driver.sh"
            driver.write_text(
                "#!/usr/bin/env bash\n"
                f'RESULTS_FILE="{results}"\n'
                f'export TMPDIR="{controlled_tmp}"\n'
                '> "$RESULTS_FILE"\n'
                "assert_eq() { printf 'PASS\\n' >> \"$RESULTS_FILE\"; }\n"
                f'. "{HARNESS}"\n'
                f'devflow_module_pin_red_under "flip" "pinned line" "s/pinned line//" "{fixture}"\n'
                f'devflow_module_pin_red_under "noop" "pinned line" "s/NOPE//" "{fixture}"\n'
                f'devflow_module_pin_red_under "unreadable" "x" "s/x//" "/no/such/file"\n'
                f'devflow_module_pin_red_under "sederr" "pinned line" "s/(/" "{fixture}"\n',
                encoding="utf-8",
            )
            subprocess.run(
                ["bash", str(driver)],
                cwd=root,
                text=True,
                capture_output=True,
                check=False,
            )
            leftover = sorted(
                p.name for p in controlled_tmp.iterdir()
            )
        self.assertEqual(
            [n for n in leftover if n.startswith("devflow-module-mut")],
            [],
            f"mutation scratch survived: {leftover}",
        )


if __name__ == "__main__":
    unittest.main()
