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
    def _run(
        self,
        module_body: str | None,
        *,
        initial_results: str = "",
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
                else f"printf '%s' {initial_results!r} > {str(root / 'results')!r}\n"
            )
            driver_text = (
                "#!/usr/bin/env bash\n"
                f"RESULTS_FILE={root / 'results'}\n"
                f"MODULE_MARKER={root / 'module-marker'}\n"
                + results_setup
                + f'. "{HARNESS}"\n'
                + f'devflow_run_full_suite_module "{module}" "sample"\n'
                + (
                    'if [ -e "$MODULE_MARKER" ]; then echo MODULE_SOURCED; '
                    "else echo MODULE_NOT_SOURCED; fi\n"
                    if report_marker
                    else ""
                )
                + 'if [ -f "$RESULTS_FILE" ]; then cat "$RESULTS_FILE"; fi\n'
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

    def test_missing_module_records_failure_and_keeps_driver_alive(self) -> None:
        result = self._run(None)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("FAIL", result.stdout.splitlines())
        self.assertIn("missing or unreadable", result.stderr)

    def test_module_exit_records_failure_and_keeps_driver_alive(self) -> None:
        result = self._run("exit 7\n")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("FAIL", result.stdout.splitlines())
        self.assertIn("exited with status 7", result.stderr)

    def test_zero_assertion_module_records_failure(self) -> None:
        result = self._run(":\n")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("FAIL", result.stdout.splitlines())
        self.assertIn("executed zero assertions", result.stderr)

    def test_unbound_variable_records_process_failure_even_for_permissive_caller(self) -> None:
        result = self._run('printf "%s\\n" "$UNBOUND_MODULE_VALUE"\n')

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("FAIL", result.stdout.splitlines())
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
