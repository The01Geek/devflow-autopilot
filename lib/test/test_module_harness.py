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
        )
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        self.assertEqual(verdicts, ["PASS", "FAIL", "FAIL"], process.stdout + process.stderr)

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
