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
import sys
import tempfile
import time
from dataclasses import dataclass
from typing import Literal, TypeAlias
import unittest


ROOT = Path(__file__).resolve().parents[2]
HARNESS = ROOT / "lib/test/module-harness.sh"
RUNNER = ROOT / "lib/test/run-module.sh"
CREATE_ISSUE_MODULE = ROOT / "lib/test/modules/create-issue-contract.sh"

SignalBoundary: TypeAlias = Literal["focused", "full-suite"]
SignalName: TypeAlias = Literal["SIGHUP", "SIGINT", "SIGTERM"]
SignalScope: TypeAlias = Literal["parent-only", "module-only", "process-group"]
POSIX_SIGNAL_MATRIX_AVAILABLE = os.name == "posix" and all(
    hasattr(signal, name) for name in ("SIGHUP", "SIGINT", "SIGTERM")
) and hasattr(os, "killpg")


def signal_matrix_capability_skip_reason(available: bool) -> str | None:
    if available:
        return None
    return "POSIX signals and process groups are required"


@dataclass(frozen=True, kw_only=True)
class SignalRowState:
    process: subprocess.Popen[str]
    boundary: SignalBoundary
    controlled_tmp: Path
    runner_pid_file: Path
    module_pid_file: Path
    worker_pid_file: Path
    helper_pid_file: Path
    module_state_file: Path
    generic_scratch_file: Path
    runner_cleanup_marker: Path
    module_cleanup_marker: Path
    caller_exit_marker: Path
    results_file: Path
    failures_file: Path
    launch_window_file: Path


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

    def test_rejected_relative_scratch_allocation_is_removed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            relative_tmp = root / "relative-tmp"
            relative_tmp.mkdir()
            module = root / "module.sh"
            module.write_text('printf "PASS\\n" >> "$RESULTS_FILE"\n', encoding="utf-8")
            driver = root / "driver.sh"
            driver.write_text(
                "#!/usr/bin/env bash\n"
                'export TMPDIR="relative-tmp"\n'
                'RESULTS_FILE="results"\n'
                'MODULE_FAILURES_FILE="failures"\n'
                '> "$RESULTS_FILE"\n'
                '> "$MODULE_FAILURES_FILE"\n'
                "assert_eq() { :; }\n"
                f'. "{HARNESS}"\n'
                f'devflow_run_full_suite_module "{module}" "sample" 1\n',
                encoding="utf-8",
            )
            result = subprocess.run(
                ["bash", str(driver)],
                cwd=root,
                text=True,
                capture_output=True,
                check=False,
            )
            leftovers = list(relative_tmp.glob("devflow-module-scratch.*"))

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(leftovers, [])

    def test_preexisting_well_shaped_scratch_is_never_claimed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            controlled_tmp = root / "tmp"
            controlled_tmp.mkdir()
            victim = controlled_tmp / "devflow-module-scratch.ABC123"
            victim.mkdir()
            sentinel = victim / "sentinel"
            sentinel.write_text("keep\n", encoding="utf-8")
            fake_bin = root / "fake-bin"
            fake_bin.mkdir()
            real_mktemp = shutil.which("mktemp")
            self.assertIsNotNone(real_mktemp)
            fake_mktemp = fake_bin / "mktemp"
            fake_mktemp.write_text(
                "#!/usr/bin/env bash\n"
                'if [ "${1:-}" = "-d" ] && '
                'case "${2:-}" in *devflow-module-scratch.*) true ;; '
                "*) false ;; esac; then\n"
                f'  printf "%s\\n" "{victim}"\n'
                "  exit 0\n"
                "fi\n"
                f'exec "{real_mktemp}" "$@"\n',
                encoding="utf-8",
            )
            fake_mktemp.chmod(0o755)
            module = root / "module.sh"
            marker = root / "module-sourced"
            module.write_text(
                f'printf "sourced\\n" > "{marker}"\n'
                'printf "PASS\\n" >> "$RESULTS_FILE"\n',
                encoding="utf-8",
            )
            driver = root / "driver.sh"
            driver.write_text(
                "#!/usr/bin/env bash\n"
                f'export TMPDIR="{controlled_tmp}"\n'
                f'export PATH="{fake_bin}:$PATH"\n'
                f'RESULTS_FILE="{root / "results"}"\n'
                f'MODULE_FAILURES_FILE="{root / "failures"}"\n'
                '> "$RESULTS_FILE"\n'
                '> "$MODULE_FAILURES_FILE"\n'
                "assert_eq() { :; }\n"
                f'. "{HARNESS}"\n'
                f'devflow_run_full_suite_module "{module}" "sample" 1\n',
                encoding="utf-8",
            )

            result = subprocess.run(
                ["bash", str(driver)],
                cwd=root,
                text=True,
                capture_output=True,
                check=False,
            )
            sentinel_survived = sentinel.is_file()
            module_was_sourced = marker.exists()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("could not allocate private scratch root", result.stderr)
        self.assertTrue(sentinel_survived, result.stdout + result.stderr)
        self.assertFalse(module_was_sourced, result.stdout + result.stderr)

    def test_module_cannot_rewrite_prior_suite_verdicts(self) -> None:
        result = self._run(
            'printf "PASS\\n" > "$RESULTS_FILE"\n', initial_results="FAIL\n"
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["FAIL", "PASS"])

    def _run_bundle_driver(self, driver_body: str) -> subprocess.CompletedProcess[str]:
        """Like _run_support_driver, but the assert_eq stub records each assertion's
        LABEL. devflow_module_build_bundle's whole reason for existing over the
        monolith's _build_skill_bundle is that a bad member lands as a *named* RED
        assertion instead of an anonymous raw RESULTS_FILE write — a PASS/FAIL-only
        stub cannot tell those apart, so it could not bind that property."""
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            driver = root / "driver.sh"
            driver.write_text(
                "#!/usr/bin/env bash\n"
                f"RESULTS_FILE={root / 'results'}\n"
                '> "$RESULTS_FILE"\n'
                "assert_eq() {\n"
                '  if [ "$2" = "$3" ]; then printf "PASS|%s\\n" "$1" >> "$RESULTS_FILE";\n'
                '  else printf "FAIL|%s\\n" "$1" >> "$RESULTS_FILE"; fi\n'
                "}\n"
                f'. "{HARNESS}"\n'
                + driver_body
                + 'cat "$RESULTS_FILE"\n',
                encoding="utf-8",
            )
            return subprocess.run(
                ["bash", str(driver)],
                cwd=root,
                text=True,
                capture_output=True,
                check=False,
            )

    def test_build_bundle_concatenates_usable_members_without_asserting(self) -> None:
        """Issue #746: the clean path adds NO assertion — a module's registry floor is an
        equality check, so a builder that emitted a per-member PASS would inflate every
        bundle-building module's tally by its member count."""
        result = self._run_bundle_driver(
            'printf "alpha\\n" > a.md\n'
            'printf "beta\\n" > b.md\n'
            'devflow_module_build_bundle "fx" out.txt a.md b.md; echo "RC:$?"\n'
            'printf "BUNDLE:"; tr "\\n" "," < out.txt; printf "\\n"\n'
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("RC:0", result.stdout)
        self.assertIn("BUNDLE:alpha,,beta,,", result.stdout)
        self.assertEqual(
            [line for line in result.stdout.splitlines() if "|" in line],
            [],
            "the clean path must add no assertion",
        )

    def test_build_bundle_reports_each_bad_member_by_name_and_keeps_going(self) -> None:
        """Issue #746: the failure channel is the reason this helper exists. Every
        unusable member must produce its OWN named RED — so one missing reference cannot
        mask the next — and the return must be non-zero. The unmatched-glob case arrives
        as the glob's own literal and is reported the same way, which is what makes an
        emptied phases/ directory a diagnosis rather than a silently thinner bundle."""
        result = self._run_bundle_driver(
            'printf "alpha\\n" > a.md\n'
            'printf "" > empty.md\n'
            'printf "omega\\n" > omega.md\n'
            'devflow_module_build_bundle "fx" out.txt a.md missing.md empty.md '
            'nomatch-*.md omega.md; echo "RC:$?"\n'
            'printf "BUNDLE:"; tr "\\n" "," < out.txt; printf "\\n"\n'
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("RC:1", result.stdout)
        failures = [
            line for line in result.stdout.splitlines() if line.startswith("FAIL|")
        ]
        # Three distinct bad members, three distinct named REDs — not one aggregate.
        self.assertEqual(len(failures), 3, result.stdout)
        self.assertIn("FAIL|fx member usable: missing.md", failures)
        self.assertIn("FAIL|fx member usable: empty.md", failures)
        self.assertIn("FAIL|fx member usable: nomatch-*.md", failures)
        # A good member placed AFTER every bad one still lands, so the whole ordered
        # bundle is "alpha,,omega,,". This is what proves the loop runs to completion —
        # rc=1 plus three named REDs alone cannot tell "kept going and appended a later
        # good member" from "aborted after the last failure"; only a good member sitting
        # downstream of the failures can.
        self.assertIn("BUNDLE:alpha,,omega,,", result.stdout)

    def test_build_bundle_reports_unreadable_present_member_distinctly(self) -> None:
        """Issue #746: the `[ -r "$member" ]`-false-but-present case (a chmod 000 file)
        is its OWN arm of the member guard, distinct from missing/empty. Exercise it on
        its own so a regression dropping the readability check — while missing/empty still
        rejected — cannot ship green. Root bypasses the permission bits (`[ -r ]` stays
        true), so the file is readable there and this arm cannot fire; skip under root
        rather than assert a rejection that will not happen, mirroring the module-side
        locked-file arms."""
        if os.geteuid() == 0:
            self.skipTest("chmod 000 does not deny reads under root")
        result = self._run_bundle_driver(
            'printf "alpha\\n" > a.md\n'
            'printf "locked\\n" > locked.md\n'
            'chmod 000 locked.md\n'
            'devflow_module_build_bundle "fx" out.txt a.md locked.md; echo "RC:$?"\n'
            'chmod 644 locked.md\n'
            'printf "BUNDLE:"; tr "\\n" "," < out.txt; printf "\\n"\n'
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("RC:1", result.stdout)
        failures = [
            line for line in result.stdout.splitlines() if line.startswith("FAIL|")
        ]
        # Present-but-unreadable is reported by name like any other unusable member —
        # and only that member, so the readability arm is exercised in isolation.
        self.assertEqual(failures, ["FAIL|fx member usable: locked.md"], result.stdout)
        # The bundle is exactly the good member: the unreadable file's content never
        # leaked in, and the earlier good member still landed.
        bundle_line = next(
            line for line in result.stdout.splitlines() if line.startswith("BUNDLE:")
        )
        self.assertEqual(bundle_line, "BUNDLE:alpha,,", result.stdout)

    def test_build_bundle_reports_unwritable_output_file(self) -> None:
        """Issue #746: the output-file-not-writable branch (`: > "$out"` fails) has its
        own named assertion and an early `return 1` before the member loop. Pin both: a
        directory can never be truncated as a file — not even by root — so this fixture is
        permission-bit-independent and needs no root skip. A regression dropping the
        `return 1` (letting the loop run against an unwritable target) or mislabeling the
        assertion would otherwise ship green."""
        result = self._run_bundle_driver(
            'printf "alpha\\n" > a.md\n'
            'mkdir out.dir\n'
            'devflow_module_build_bundle "fx" out.dir a.md; echo "RC:$?"\n'
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("RC:1", result.stdout)
        failures = [
            line for line in result.stdout.splitlines() if line.startswith("FAIL|")
        ]
        # Exactly the writability assertion fires, and nothing else: the early return
        # means the member loop never runs, so there is no per-member assertion.
        self.assertEqual(failures, ["FAIL|fx output file writable"], result.stdout)

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


class SignalCapabilityReportingTests(unittest.TestCase):
    def test_unavailable_matrix_has_a_host_capability_reason(self) -> None:
        self.assertIsNone(signal_matrix_capability_skip_reason(True))
        self.assertEqual(
            signal_matrix_capability_skip_reason(False),
            "POSIX signals and process groups are required",
        )


@unittest.skipUnless(
    POSIX_SIGNAL_MATRIX_AVAILABLE,
    "host-capability: POSIX signals and process groups are required",
)
class SignalCleanupMatrixTests(unittest.TestCase):
    """Signal cleanup is symmetric across focused and complete-suite boundaries."""

    signal_names: tuple[SignalName, ...] = ("SIGHUP", "SIGINT", "SIGTERM")
    scopes: tuple[SignalScope, ...] = (
        "parent-only",
        "module-only",
        "process-group",
    )
    boundaries: tuple[SignalBoundary, ...] = ("focused", "full-suite")

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

    def _build_signal_fixture(self, row: Path) -> tuple[Path, Path, Path, Path]:
        repo = row / "repo"
        test_dir = repo / "lib/test"
        modules_dir = test_dir / "modules"
        scripts_dir = repo / "scripts"
        fake_bin = row / "fake-bin"
        modules_dir.mkdir(parents=True)
        scripts_dir.mkdir()
        fake_bin.mkdir()
        shutil.copy2(RUNNER, test_dir / "run-module.sh")
        shutil.copy2(HARNESS, test_dir / "module-harness.sh")

        sed_helper = fake_bin / "sed"
        sed_helper.write_text(
            "#!/usr/bin/env bash\n"
            '_generic_scratch="$(mktemp -d "${TMPDIR:-/tmp}/devflow-generic-module.XXXXXX")" '
            "|| exit 1\n"
            'printf "%s\\n" "$_generic_scratch" '
            '> "$DEVFLOW_TEST_GENERIC_SCRATCH_FILE"\n'
            'printf "%s\\n" "$DEVFLOW_MODULE_SCRATCH_ROOT" '
            '> "$DEVFLOW_TEST_MODULE_STATE_FILE"\n'
            'printf "%s\\n" "$$" > "$DEVFLOW_TEST_HELPER_PID_FILE"\n'
            'if [ "${DEVFLOW_TEST_SIGNAL_RESISTANT_HELPER:-0}" = "1" ]; then\n'
            "  trap '' HUP INT TERM\n"
            "fi\n"
            "while :; do sleep 1; done\n",
            encoding="utf-8",
        )
        sed_helper.chmod(0o755)

        module = modules_dir / "signal-create-issue.sh"
        module_text = CREATE_ISSUE_MODULE.read_text(encoding="utf-8")
        insertion_point = "# The implement-skill bundle backs the #467 D2 Phase-2.4 leg"
        signal_pause = (
            "# Test-only signal fixture: exercise a real foreground helper process.\n"
            'trap -p INT > "$DEVFLOW_TEST_MODULE_STATE_FILE.trap"\n'
            '_ci_signal_fixture="$_ci_tmp_root/signal-source"\n'
            'printf \'operative\\n\' > "$_ci_signal_fixture"\n'
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
        return repo, module, registry_path, fake_bin

    def _start_row(
        self,
        boundary: SignalBoundary,
        row: Path,
        *,
        resistant_helper: bool = False,
        launch_window: bool = False,
    ) -> SignalRowState:
        repo, module, registry, fake_bin = self._build_signal_fixture(row)
        controlled_tmp = row / "tmp"
        controlled_tmp.mkdir()
        runner_pid_file = row / "runner.pid"
        module_pid_file = row / "module.pid"
        worker_pid_file = row / "worker.pid"
        helper_pid_file = row / "helper.pid"
        module_state_file = row / "module.state"
        generic_scratch_file = row / "generic-scratch.state"
        runner_cleanup_marker = row / "runner-cleanup.marker"
        module_cleanup_marker = row / "module-cleanup.marker"
        caller_exit_marker = row / "caller-exit.marker"
        results_file = row / "suite-results"
        failures_file = row / "module-failures"
        launch_window_file = row / "launch-window"
        environment = os.environ.copy()
        for name in (
            "DEVFLOW_TEST_RUNNER_PID_FILE",
            "DEVFLOW_TEST_MODULE_PID_FILE",
            "DEVFLOW_TEST_MODULE_WORKER_PID_FILE",
            "DEVFLOW_TEST_HELPER_PID_FILE",
            "DEVFLOW_TEST_RUNNER_CLEANUP_MARKER",
            "DEVFLOW_TEST_MODULE_CLEANUP_MARKER",
            "DEVFLOW_TEST_MODULE_STATE_FILE",
            "DEVFLOW_TEST_GENERIC_SCRATCH_FILE",
            "DEVFLOW_TEST_SIGNAL_RESISTANT_HELPER",
            "DEVFLOW_TEST_LAUNCH_WINDOW_FILE",
        ):
            environment.pop(name, None)
        environment.update(
            {
                "PATH": f"{fake_bin}{os.pathsep}{environment['PATH']}",
                "TMPDIR": str(controlled_tmp),
                "DEVFLOW_CREATE_ISSUE_CONTRACT_ROOT": str(ROOT),
                "DEVFLOW_TEST_RUNNER_PID_FILE": str(runner_pid_file),
                "DEVFLOW_TEST_MODULE_PID_FILE": str(module_pid_file),
                "DEVFLOW_TEST_MODULE_WORKER_PID_FILE": str(worker_pid_file),
                "DEVFLOW_TEST_HELPER_PID_FILE": str(helper_pid_file),
                "DEVFLOW_TEST_RUNNER_CLEANUP_MARKER": str(runner_cleanup_marker),
                "DEVFLOW_TEST_MODULE_CLEANUP_MARKER": str(module_cleanup_marker),
                "DEVFLOW_TEST_MODULE_STATE_FILE": str(module_state_file),
                "DEVFLOW_TEST_GENERIC_SCRATCH_FILE": str(generic_scratch_file),
                "DEVFLOW_TEST_SIGNAL_RESISTANT_HELPER": (
                    "1" if resistant_helper else "0"
                ),
            }
        )
        if launch_window:
            environment["DEVFLOW_TEST_LAUNCH_WINDOW_FILE"] = str(launch_window_file)

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
        elif boundary == "full-suite":
            driver = row / "full-suite-driver.sh"
            driver.write_text(
                "#!/usr/bin/env bash\n"
                "set -u\n"
                f'LIB="{ROOT / "lib"}"\n'
                f'RESULTS_FILE="{results_file}"\n'
                f'MODULE_FAILURES_FILE="{failures_file}"\n'
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
        else:
            self.fail(f"unsupported boundary: {boundary}")

        process = subprocess.Popen(
            command,
            cwd=cwd,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        return SignalRowState(
            process=process,
            boundary=boundary,
            controlled_tmp=controlled_tmp,
            runner_pid_file=runner_pid_file,
            module_pid_file=module_pid_file,
            worker_pid_file=worker_pid_file,
            helper_pid_file=helper_pid_file,
            module_state_file=module_state_file,
            generic_scratch_file=generic_scratch_file,
            runner_cleanup_marker=runner_cleanup_marker,
            module_cleanup_marker=module_cleanup_marker,
            caller_exit_marker=caller_exit_marker,
            results_file=results_file,
            failures_file=failures_file,
            launch_window_file=launch_window_file,
        )

    @staticmethod
    def _read_pid(path: Path) -> int | None:
        if not path.is_file():
            return None
        value = path.read_text(encoding="utf-8").strip()
        return int(value) if value.isdigit() else None

    def _terminate_state(self, state: SignalRowState) -> None:
        for path in (state.worker_pid_file, state.module_pid_file):
            pid = self._read_pid(path)
            if pid is None:
                continue
            try:
                os.killpg(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if state.process.poll() is None:
            try:
                os.killpg(state.process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def _assert_no_signal_leaks(self, state: SignalRowState) -> None:
        leftovers = sorted(path.name for path in state.controlled_tmp.iterdir())
        leaked = [
            name
            for name in leftovers
            if name.startswith(
                (
                    "devflow-module-results.",
                    "devflow-module-details.",
                    "devflow-module-tally.",
                    "devflow-module-scratch.",
                    "devflow-create-issue-contract.",
                    "devflow-module-mut.",
                )
            )
        ]
        self.assertEqual(leaked, [], f"cleanup artifacts survived: {leaked}")

    def _exercise_row(
        self,
        boundary: SignalBoundary,
        signal_name: SignalName,
        scope: SignalScope,
        *,
        resistant_helper: bool = False,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            row = Path(temporary_directory)
            state = self._start_row(
                boundary, row, resistant_helper=resistant_helper
            )
            process = state.process
            stdout = ""
            stderr = ""
            try:
                module_int_trap_file = Path(f"{state.module_state_file}.trap")
                self._wait_for_signal_state(
                    process,
                    (
                        state.runner_pid_file,
                        state.module_pid_file,
                        state.worker_pid_file,
                        state.helper_pid_file,
                        state.module_state_file,
                        state.generic_scratch_file,
                        module_int_trap_file,
                    ),
                )
                runner_pid = int(
                    state.runner_pid_file.read_text(encoding="utf-8").strip()
                )
                module_pid = int(
                    state.module_pid_file.read_text(encoding="utf-8").strip()
                )
                worker_pid = int(
                    state.worker_pid_file.read_text(encoding="utf-8").strip()
                )
                helper_pid = int(
                    state.helper_pid_file.read_text(encoding="utf-8").strip()
                )
                module_root = Path(
                    state.module_state_file.read_text(encoding="utf-8").strip()
                )
                generic_scratch = Path(
                    state.generic_scratch_file.read_text(encoding="utf-8").strip()
                )
                helper_scratches = list(module_root.glob("devflow-module-mut.*"))
                self.assertEqual(runner_pid, process.pid)
                self.assertNotEqual(module_pid, runner_pid)
                self.assertNotEqual(worker_pid, module_pid)
                self.assertNotIn(helper_pid, (runner_pid, module_pid, worker_pid))
                self.assertEqual(os.getpgid(module_pid), module_pid)
                self.assertEqual(os.getpgid(worker_pid), module_pid)
                self.assertEqual(os.getpgid(helper_pid), module_pid)
                module_int_trap = module_int_trap_file.read_text(encoding="utf-8")
                self.assertIn("SIGINT", module_int_trap)
                self.assertNotIn("trap -- '' SIGINT", module_int_trap)
                self.assertTrue(module_root.is_dir())
                self.assertTrue(generic_scratch.is_dir())
                self.assertEqual(len(helper_scratches), 1)
                helper_scratch = helper_scratches[0]
                self.assertTrue(helper_scratch.is_file())

                signal_number = getattr(signal, signal_name)
                if scope == "parent-only":
                    os.kill(runner_pid, signal_number)
                elif scope == "module-only":
                    os.kill(module_pid, signal_number)
                elif scope == "process-group":
                    os.killpg(module_pid, signal_number)
                else:
                    self.fail(f"unsupported signal scope: {scope}")

                started = time.monotonic()
                bounded = True
                try:
                    stdout, stderr = process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    bounded = False
                elapsed = time.monotonic() - started
                if not bounded:
                    self._terminate_state(state)
                    stdout, stderr = process.communicate(timeout=2)
                self.assertTrue(
                    bounded,
                    f"row exceeded cleanup bound: {boundary}/{signal_name}/{scope}\n"
                    f"stdout={stdout[-2000:]}\nstderr={stderr[-2000:]}",
                )
                self.assertLess(elapsed, 5)

                expected_rc = 1 if boundary == "focused" or scope == "parent-only" else 0
                self.assertEqual(
                    process.returncode,
                    expected_rc,
                    f"stdout={stdout[-2000:]}\nstderr={stderr[-2000:]}",
                )
                if boundary == "full-suite" and scope != "parent-only":
                    failure_records = state.failures_file.read_text(
                        encoding="utf-8"
                    ).splitlines()
                    self.assertGreaterEqual(len(failure_records), 1)
                    self.assertEqual(set(failure_records), {"FAIL"})

                deadline = time.monotonic() + 2
                supervised_pids = (module_pid, worker_pid, helper_pid)
                while any(self._pid_exists(pid) for pid in supervised_pids) and (
                    time.monotonic() < deadline
                ):
                    time.sleep(0.02)
                for pid in supervised_pids:
                    self.assertFalse(self._pid_exists(pid), f"subprocess survived: {pid}")
                self.assertFalse(module_root.exists(), "module scratch root survived")
                self.assertFalse(generic_scratch.exists(), "generic module scratch survived")
                self.assertFalse(helper_scratch.exists(), "module helper scratch survived")
                self._assert_no_signal_leaks(state)
                self.assertEqual(
                    state.runner_cleanup_marker.read_text(
                        encoding="utf-8"
                    ).splitlines(),
                    ["runner-cleanup"],
                )
                self.assertEqual(
                    state.module_cleanup_marker.read_text(
                        encoding="utf-8"
                    ).splitlines(),
                    ["module-cleanup"],
                )
                if boundary == "full-suite":
                    self.assertEqual(
                        state.caller_exit_marker.read_text(
                            encoding="utf-8"
                        ).splitlines(),
                        ["caller-exit"],
                    )
            finally:
                self._terminate_state(state)
                if process.poll() is None:
                    process.communicate(timeout=2)

    def test_signal_cleanup_matrix(self) -> None:
        rows = [
            (boundary, signal_name, scope)
            for boundary in self.boundaries
            for signal_name in self.signal_names
            for scope in self.scopes
        ]
        self.assertEqual(len(rows), 18)
        for boundary, signal_name, scope in rows:
            with self.subTest(
                boundary=boundary,
                signal=signal_name,
                scope=scope,
            ):
                self._exercise_row(boundary, signal_name, scope)

    def test_signal_resistant_foreground_helper_is_escalated(self) -> None:
        for boundary, scope in (
            ("focused", "module-only"),
            ("focused", "parent-only"),
            ("full-suite", "parent-only"),
        ):
            with self.subTest(boundary=boundary, scope=scope):
                self._exercise_row(
                    boundary, "SIGTERM", scope, resistant_helper=True
                )

    def test_signal_during_launch_window_is_not_lost(self) -> None:
        for boundary in self.boundaries:
            with self.subTest(boundary=boundary):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    state = self._start_row(
                        boundary,
                        Path(temporary_directory),
                        launch_window=True,
                    )
                    try:
                        self._wait_for_signal_state(
                            state.process,
                            (state.runner_pid_file, state.launch_window_file),
                        )
                        runner_pid = int(
                            state.runner_pid_file.read_text(encoding="utf-8").strip()
                        )
                        os.kill(runner_pid, signal.SIGTERM)
                        stdout, stderr = state.process.communicate(timeout=5)
                        self.assertEqual(
                            state.process.returncode,
                            1,
                            f"stdout={stdout[-2000:]}\nstderr={stderr[-2000:]}",
                        )
                        self._assert_no_signal_leaks(state)
                        self.assertEqual(
                            state.runner_cleanup_marker.read_text(
                                encoding="utf-8"
                            ).splitlines(),
                            ["runner-cleanup"],
                        )
                        self.assertEqual(
                            state.module_cleanup_marker.read_text(
                                encoding="utf-8"
                            ).splitlines(),
                            ["module-cleanup"],
                        )
                    finally:
                        self._terminate_state(state)
                        if state.process.poll() is None:
                            state.process.communicate(timeout=2)

    def test_worker_stays_in_supervisor_group_with_a_controlling_tty(self) -> None:
        import pty

        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            supervisor_pid_file = root / "supervisor.pid"
            worker_pid_file = root / "worker.pid"
            release = root / "release"
            driver = root / "driver.sh"
            driver.write_text(
                "#!/usr/bin/env bash\n"
                "set -m\n"
                f'. "{HARNESS}"\n'
                f'RELEASE="{release}"\n'
                'body() { while [ ! -e "$RELEASE" ]; do sleep 0.01; done; }\n'
                f'printf "%s\\n" "$BASHPID" > "{supervisor_pid_file}"\n'
                f'_devflow_supervise_module body "{supervisor_pid_file}" '
                f'"{worker_pid_file}"\n',
                encoding="utf-8",
            )
            child_pid, master_fd = pty.fork()
            if child_pid == 0:
                os.execvp("bash", ["bash", str(driver)])
            try:
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    if (
                        supervisor_pid_file.is_file()
                        and worker_pid_file.is_file()
                        and worker_pid_file.stat().st_size > 0
                    ):
                        break
                    time.sleep(0.02)
                self.assertTrue(worker_pid_file.is_file(), "worker PID was not published")
                supervisor_pid = int(
                    supervisor_pid_file.read_text(encoding="utf-8").strip()
                )
                worker_pid = int(worker_pid_file.read_text(encoding="utf-8").strip())
                self.assertEqual(os.getpgid(supervisor_pid), supervisor_pid)
                self.assertEqual(os.getpgid(worker_pid), supervisor_pid)
            finally:
                release.touch()
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    waited, _ = os.waitpid(child_pid, os.WNOHANG)
                    if waited == child_pid:
                        break
                    time.sleep(0.02)
                else:
                    try:
                        os.killpg(child_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    os.waitpid(child_pid, 0)
                os.close(master_fd)

    def test_sigint_terminates_every_pooled_child(self) -> None:
        # issue #720: a SIGINT delivered to the suite's foreground process group must
        # terminate EVERY pooled python3 child — each launched into its own supervisor
        # process group — leaving nothing running against the checkout. This exercises
        # the generalized run-wide live-child registry: the single scalar module_pid
        # slot could terminate one group, so with three pooled children a single-slot
        # handler would orphan two. The handler forwards to every registered child.
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            fixtures = root / "fix"
            ready = root / "ready"
            controlled_tmp = root / "tmp"
            for directory in (fixtures, ready, controlled_tmp):
                directory.mkdir()
            sleeper = fixtures / "sleeper.py"
            sleeper.write_text(
                "import os, time\n"
                f'open(os.path.join(r"{ready}", str(os.getpid())), "w").close()\n'
                "time.sleep(60)\n",
                encoding="utf-8",
            )
            driver = root / "pool-driver.sh"
            driver.write_text(
                "#!/usr/bin/env bash\n"
                "set -u\n"
                f'RESULTS_FILE="{root / "results"}"\n'
                f'MODULE_FAILURES_FILE="{root / "failures"}"\n'
                f'SKIPS_FILE="{root / "skips"}"\n'
                '> "$RESULTS_FILE"; > "$MODULE_FAILURES_FILE"; > "$SKIPS_FILE"\n'
                'assert_eq() { if [ "$2" = "$3" ]; then printf "PASS\\n" >> "$RESULTS_FILE"; '
                'else printf "FAIL\\n" >> "$RESULTS_FILE"; fi; }\n'
                f'. "{HARNESS}"\n'
                "DEVFLOW_POOL_WIDTH=3 devflow_pool_open \\\n"
                f'  s1 "{sleeper}" single-verdict \\\n'
                f'  s2 "{sleeper}" single-verdict \\\n'
                f'  s3 "{sleeper}" single-verdict\n'
                "devflow_pool_join\n",
                encoding="utf-8",
            )
            environment = os.environ.copy()
            environment["TMPDIR"] = str(controlled_tmp)
            process = subprocess.Popen(
                ["bash", str(driver)],
                cwd=root,
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
            try:
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline:
                    if len(list(ready.iterdir())) >= 3 or process.poll() is not None:
                        break
                    time.sleep(0.05)
                child_pids = sorted(
                    int(path.name) for path in ready.iterdir() if path.name.isdigit()
                )
                self.assertEqual(
                    len(child_pids),
                    3,
                    f"pooled children did not all start; pids={child_pids}, "
                    f"rc={process.poll()}",
                )
                for pid in child_pids:
                    self.assertTrue(
                        self._pid_exists(pid), f"child {pid} not running pre-signal"
                    )
                # Deliver SIGINT to the driver's foreground process group. The pooled
                # children sit in SEPARATE supervisor groups, so only the driver's
                # handler forwarding can reach them — which is the property under test.
                os.killpg(process.pid, signal.SIGINT)
                stdout, stderr = process.communicate(timeout=30)
                self.assertNotEqual(
                    process.returncode,
                    0,
                    f"stdout={stdout[-2000:]}\nstderr={stderr[-2000:]}",
                )
                grace = time.monotonic() + 8
                while time.monotonic() < grace and any(
                    self._pid_exists(pid) for pid in child_pids
                ):
                    time.sleep(0.05)
                survivors = [pid for pid in child_pids if self._pid_exists(pid)]
                self.assertEqual(
                    survivors, [], f"pooled children survived SIGINT: {survivors}"
                )
            finally:
                if process.poll() is None:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.communicate(timeout=3)
                for path in ready.iterdir():
                    if path.name.isdigit():
                        try:
                            os.kill(int(path.name), signal.SIGKILL)
                        except ProcessLookupError:
                            pass

    def test_full_suite_cleanup_failures_record_boundary_failure(self) -> None:
        for target, pattern in (
            ("scratch", "*devflow-module-scratch.*"),
            ("tally", "*devflow-module-tally.*"),
        ):
            with self.subTest(target=target):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    root = Path(temporary_directory)
                    module = root / "module.sh"
                    module.write_text(
                        'printf "PASS\\n" >> "$RESULTS_FILE"\n', encoding="utf-8"
                    )
                    results = root / "results"
                    failures = root / "failures"
                    driver = root / "driver.sh"
                    driver.write_text(
                        "#!/usr/bin/env bash\n"
                        f'RESULTS_FILE="{results}"\n'
                        f'MODULE_FAILURES_FILE="{failures}"\n'
                        '> "$RESULTS_FILE"\n'
                        '> "$MODULE_FAILURES_FILE"\n'
                        "assert_eq() { :; }\n"
                        "rm() {\n"
                        f'  case "$*" in {pattern}) return 1 ;; esac\n'
                        '  command rm "$@"\n'
                        "}\n"
                        f'. "{HARNESS}"\n'
                        f'devflow_run_full_suite_module "{module}" "sample" 1\n',
                        encoding="utf-8",
                    )
                    process = subprocess.run(
                        ["bash", str(driver)],
                        text=True,
                        capture_output=True,
                        check=False,
                    )
                    self.assertEqual(process.returncode, 0)
                    self.assertEqual(
                        failures.read_text(encoding="utf-8").splitlines(), ["FAIL"]
                    )
                    self.assertIn("could not remove private", process.stderr)

    def test_missing_supervisor_pid_rendezvous_fails_boundedly(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            driver = root / "driver.sh"
            driver.write_text(
                "#!/usr/bin/env bash\n"
                "body() { :; }\n"
                f'. "{HARNESS}"\n'
                f'_devflow_supervise_module body "{root / "missing.pid"}" '
                f'"{root / "worker.pid"}"\n',
                encoding="utf-8",
            )
            started = time.monotonic()
            process = subprocess.run(
                ["bash", str(driver)],
                text=True,
                capture_output=True,
                check=False,
                timeout=5,
            )
            elapsed = time.monotonic() - started

        self.assertEqual(process.returncode, 1)
        # The rendezvous is wall-clock bounded (module-harness.sh's
        # rendezvous_deadline_seconds=3, fired via SECONDS). Pin both ends of the
        # ~3s budget, not just the old 5s ceiling: the upper bound catches a
        # regression that inflates the deadline or reintroduces a fork-cost-
        # sensitive bound; the lower bound catches a deadline collapsing to ~0
        # (e.g. SECONDS=0 dropped, or -ge flipped) that would still exit rc 1 with
        # the same message. The lower bound is 1.5 (not ~3) because SECONDS'
        # integer granularity makes the real fire time [deadline-1, deadline),
        # i.e. as low as ~2s + startup — 1.5 clears that legitimate floor while
        # still failing an instant (~0s) collapse.
        self.assertGreater(elapsed, 1.5)
        self.assertLess(elapsed, 4)
        self.assertIn("supervisor PID rendezvous timed out", process.stderr)

    def test_full_suite_boundary_restores_caller_signal_traps(self) -> None:
        for initial_monitor in ("off", "on"):
            with self.subTest(initial_monitor=initial_monitor):
                with tempfile.TemporaryDirectory() as temporary_directory:
                    root = Path(temporary_directory)
                    module = root / "module.sh"
                    marker = root / "marker"
                    monitor = root / "monitor"
                    module.write_text(
                        'printf "PASS\\n" >> "$RESULTS_FILE"\n', encoding="utf-8"
                    )
                    driver = root / "driver.sh"
                    driver.write_text(
                        "#!/usr/bin/env bash\n"
                        f'RESULTS_FILE="{root / "results"}"\n'
                        f'MODULE_FAILURES_FILE="{root / "failures"}"\n'
                        '> "$RESULTS_FILE"\n'
                        '> "$MODULE_FAILURES_FILE"\n'
                        f'MARKER="{marker}"\n'
                        f'MONITOR="{monitor}"\n'
                        + ("set -m\n" if initial_monitor == "on" else "set +m\n")
                        + 'case "$-" in *m*) printf "on\\n" ;; *) printf "off\\n" ;; esac > "$MONITOR"\n'
                        'trap \'printf "caller-exit\\n" >> "$MARKER"\' EXIT\n'
                        'trap \'printf "caller-hup\\n" >> "$MARKER"\' HUP\n'
                        'trap \'printf "caller-int\\n" >> "$MARKER"\' INT\n'
                        'trap \'printf "caller-term\\n" >> "$MARKER"\' TERM\n'
                        "assert_eq() { :; }\n"
                        f'. "{HARNESS}"\n'
                        f'devflow_run_full_suite_module "{module}" "sample" 1\n'
                        'case "$-" in *m*) printf "on\\n" ;; *) printf "off\\n" ;; esac >> "$MONITOR"\n'
                        'kill -s HUP "$$"\n'
                        'kill -s INT "$$"\n'
                        'kill -s TERM "$$"\n',
                        encoding="utf-8",
                    )
                    process = subprocess.run(
                        ["bash", str(driver)],
                        text=True,
                        capture_output=True,
                        check=False,
                    )
                    records = marker.read_text(encoding="utf-8").splitlines()
                    monitor_records = monitor.read_text(encoding="utf-8").splitlines()

                self.assertEqual(
                    process.returncode, 0, process.stdout + process.stderr
                )
                self.assertEqual(
                    records,
                    ["caller-hup", "caller-int", "caller-term", "caller-exit"],
                )
                self.assertEqual(monitor_records, [initial_monitor, initial_monitor])


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

    def test_pin_red_under_overbroad_blank_mutation_is_red(self) -> None:
        # #666 overbreadth guard sibling assertion (one per guarded helper). A
        # blank-the-file mutation (`1,$d` deletes every line; `s/.*//` empties every
        # line, line count unchanged) retains ~0 non-whitespace and must trip the
        # `mutation-overbroad` RED — the reject arm the count/module guards would
        # otherwise leave unverified. Both spellings are exercised so the guard is
        # proven to fire, not merely that its regression controls stay green.
        process, verdicts = self._drive(
            'F="$(mktemp)"; printf "operative sentence here\\nkeep line two here\\n" > "$F"\n'
            '# Blank-the-file via delete-every-line -> mutation-overbroad -> RED.\n'
            'devflow_module_pin_red_under "blank delete mutation is RED" '
            '"operative sentence here" "1,\\$d" "$F"\n'
            '# Blank-the-file via empty-every-line (line count unchanged) -> RED.\n'
            'devflow_module_pin_red_under "blank substitute mutation is RED" '
            '"operative sentence here" "s/.*//" "$F"\n'
            '# An operative single-line mutation still flips PASS->FAIL (regression control).\n'
            'devflow_module_pin_red_under "operative mutation still flips" '
            '"operative sentence here" "s/operative sentence here//" "$F"\n'
        )
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        self.assertEqual(
            verdicts, ["FAIL", "FAIL", "PASS"], process.stdout + process.stderr
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
    if sys.argv[1:] == ["--signal-matrix-capability"]:
        capability_reason = signal_matrix_capability_skip_reason(
            POSIX_SIGNAL_MATRIX_AVAILABLE
        )
        if capability_reason is not None:
            print(capability_reason)
            raise SystemExit(1)
        raise SystemExit(0)
    unittest.main()
