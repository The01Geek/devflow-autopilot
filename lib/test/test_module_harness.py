#!/usr/bin/env python3
"""Focused tests for the full-suite source boundary around test modules."""

# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT

from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
HARNESS = ROOT / "lib/test/module-harness.sh"


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


if __name__ == "__main__":
    unittest.main()
