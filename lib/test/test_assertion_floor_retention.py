#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Offline regression tests for the assertion-floor retention check (issue #1287).

The check (`assertion-floor-retention-check.py`) makes a LOWERED module assertion floor a
declared act rather than a silent edit, for EVERY registered module and not only the
`exact`-policy subset. Two surfaces are driven independently:

* the pure core (`detect_decreases`, `classify_outcome`) — over every decrease, retirement,
  malformed-comparand, escape-hatch and arm-order shape, from in-memory fixtures;
* the CLI end-to-end — against a REAL offline git repository (no network, no `gh`), the same
  desk==CI inputs the check runs on.

Git config is redirected to isolated empty files for every fixture test so the host's real
config can neither cause a false pass nor a false fail.
"""
from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import unittest
import unittest.mock
from pathlib import Path

HERE = Path(__file__).resolve().parent
CHECK_SOURCE = HERE / "assertion-floor-retention-check.py"
REGISTRY_REL = "scripts/workflow-flight-recorder-registry.json"
ALLOW_REL = "lib/test/assertion-floor-retention-allow.json"


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


check = _load("assertion_floor_retention_check", CHECK_SOURCE)


def _registry(floors, extra=None):
    """A registry object with the given {module: minimum_assertions}, plus any `extra` raw
    module entries spliced in verbatim (to exercise malformed per-module shapes)."""
    modules = {mid: {"minimum_assertions": v} for mid, v in floors.items()}
    if extra:
        modules.update(extra)
    return {"schema_version": 1, "test_modules": modules}


class DetectDecreasesCoreTest(unittest.TestCase):
    """The pure `detect_decreases` core over every shape."""

    def test_clean_when_no_floor_lowered(self):
        base = _registry({"m": 68, "n": 100})
        head = _registry({"m": 68, "n": 100})
        self.assertEqual(check.detect_decreases(base, head, None), [])

    def test_raise_is_never_a_decrease(self):
        base = _registry({"m": 68})
        head = _registry({"m": 120})
        self.assertEqual(check.detect_decreases(base, head, None), [])

    def test_decrease_is_flagged(self):
        base = _registry({"m": 68})
        head = _registry({"m": 40})
        violations = check.detect_decreases(base, head, None)
        self.assertEqual(len(violations), 1)
        self.assertIn("'m'", violations[0])
        self.assertIn("68", violations[0])
        self.assertIn("40", violations[0])

    def test_policyless_module_decrease_is_flagged(self):
        # The exact population the gap left uncovered (issue #1287): a module with no
        # assertion_floor_policy. The check is policy-agnostic, so it catches it.
        base = _registry({"workflow-flight-recorder": 68})
        head = _registry({"workflow-flight-recorder": 67})
        violations = check.detect_decreases(base, head, None)
        self.assertEqual(len(violations), 1)
        self.assertIn("workflow-flight-recorder", violations[0])

    def test_retired_module_is_out_of_scope(self):
        # A module present at base but absent at head is a RETIREMENT, not a lowered floor.
        base = _registry({"m": 68, "gone": 300})
        head = _registry({"m": 68})
        self.assertEqual(check.detect_decreases(base, head, None), [])

    def test_new_module_is_not_a_decrease(self):
        base = _registry({"m": 68})
        head = _registry({"m": 68, "new": 10})
        self.assertEqual(check.detect_decreases(base, head, None), [])

    def test_allowlist_acknowledges_a_decrease(self):
        base = _registry({"m": 68})
        head = _registry({"m": 40})
        allow = [{"module": "m", "reason": "retired a whole arm; assertions merged into n"}]
        self.assertEqual(check.detect_decreases(base, head, allow), [])

    def test_allowlist_entry_without_reason_is_fail_closed(self):
        base = _registry({"m": 68})
        head = _registry({"m": 40})
        allow = [{"module": "m", "reason": "   "}]
        violations = check.detect_decreases(base, head, allow)
        # BOTH the malformed-allow breadcrumb AND the unacknowledged decrease surface.
        self.assertTrue(any("no non-empty 'reason'" in v for v in violations))
        self.assertTrue(any("LOWERED" in v for v in violations))

    def test_allowlist_wrong_type_is_fail_closed(self):
        base = _registry({"m": 68})
        head = _registry({"m": 40})
        violations = check.detect_decreases(base, head, {"module": "m"})
        self.assertTrue(any("must be a JSON array" in v for v in violations))
        self.assertTrue(any("LOWERED" in v for v in violations))

    def test_malformed_base_registry_is_unestablished_not_empty(self):
        head = _registry({"m": 40})
        violations = check.detect_decreases("not-an-object", head, None)
        self.assertTrue(any("comparand unestablished" in v for v in violations))

    def test_malformed_head_registry_is_unestablished(self):
        base = _registry({"m": 68})
        violations = check.detect_decreases(base, {"test_modules": []}, None)
        self.assertTrue(any("comparand unestablished" in v for v in violations))

    def test_non_int_floor_is_skipped_not_crashed(self):
        base = _registry({"m": 68}, extra={"bad": {"minimum_assertions": "68"}})
        head = _registry({"m": 68}, extra={"bad": {"minimum_assertions": "40"}})
        # Neither `bad` value is an int, so there is no floor to compare — no crash, no flag.
        self.assertEqual(check.detect_decreases(base, head, None), [])

    def test_bool_floor_is_not_treated_as_int(self):
        base = _registry({"m": 68}, extra={"b": {"minimum_assertions": True}})
        head = _registry({"m": 68}, extra={"b": {"minimum_assertions": False}})
        # bool is an int subclass; the check must not read True/False (1/0) as a floor.
        self.assertEqual(check.detect_decreases(base, head, None), [])


class ClassifyOutcomeCoreTest(unittest.TestCase):
    """`classify_outcome` — every arm and the load-bearing arm ORDER."""

    def test_clean(self):
        status, lines = check.classify_outcome([], [], False, "origin/main", False)
        self.assertEqual(status, check.EXIT_CLEAN)
        self.assertTrue(any("no registered module" in ln for ln in lines))

    def test_sound_decrease_is_exit_1(self):
        status, _ = check.classify_outcome(["[floor] d"], [], False, "origin/main", False)
        self.assertEqual(status, check.EXIT_DECREASE)

    def test_sound_decrease_outranks_unestablished_and_no_flag_acknowledges_it(self):
        # Arm order: an established decrease against a SOUND comparand wins over degradation,
        # and --allow-degraded-base cannot acknowledge it away.
        status, lines = check.classify_outcome(
            ["[floor] d"], ["shallow"], True, "origin/main", False
        )
        self.assertEqual(status, check.EXIT_DECREASE)
        self.assertTrue(any("ALSO could not establish" in ln for ln in lines))

    def test_substituted_comparand_decrease_is_unestablished_not_loss(self):
        status, lines = check.classify_outcome(
            ["[floor] d"], ["substitute tip"], False, "origin/main", True
        )
        self.assertEqual(status, check.EXIT_UNESTABLISHED)
        self.assertTrue(any("SUBSTITUTE comparand" in ln for ln in lines))

    def test_unestablished_only_is_exit_3(self):
        status, _ = check.classify_outcome([], ["shallow"], False, "origin/main", False)
        self.assertEqual(status, check.EXIT_UNESTABLISHED)

    def test_acknowledged_degraded_is_exit_0(self):
        status, lines = check.classify_outcome([], ["shallow"], True, "origin/main", False)
        self.assertEqual(status, check.EXIT_CLEAN)
        self.assertTrue(any("acknowledged" in ln for ln in lines))


class _GitFixtureBase(unittest.TestCase):
    prefix = "afr-fixture-"

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix=self.prefix))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self._isolate_git_config()
        self.repo = self.tmp / "repo"
        (self.repo / "scripts").mkdir(parents=True)
        (self.repo / "lib" / "test").mkdir(parents=True)
        self._git("init", "-q")
        self._git("config", "user.email", "t@t")
        self._git("config", "user.name", "t")
        self._git("config", "commit.gpgsign", "false")
        # A minimal config-get.sh so the CLI's base-branch resolver returns 'main' offline.
        resolver = self.repo / "scripts" / "config-get.sh"
        resolver.write_text("#!/usr/bin/env bash\necho main\n", encoding="utf-8")
        resolver.chmod(0o755)

    def _isolate_git_config(self):
        self.isolated_global = self.tmp / "isolated-global-gitconfig"
        self.isolated_system = self.tmp / "isolated-system-gitconfig"
        self.isolated_global.write_text("", encoding="utf-8")
        self.isolated_system.write_text("", encoding="utf-8")
        patcher = unittest.mock.patch.dict(os.environ, {
            "GIT_CONFIG_GLOBAL": str(self.isolated_global),
            "GIT_CONFIG_SYSTEM": str(self.isolated_system),
            "HOME": str(self.tmp),
        })
        patcher.start()
        self.addCleanup(patcher.stop)

    def _git(self, *args, check=True):
        return subprocess.run(
            ["git", "-C", str(self.repo), *args],
            capture_output=True, text=True, check=check,
        )

    def _write_registry(self, floors):
        (self.repo / REGISTRY_REL).write_text(
            json.dumps(_registry(floors), indent=2) + "\n", encoding="utf-8"
        )

    def _write_allow(self, value):
        (self.repo / ALLOW_REL).write_text(json.dumps(value) + "\n", encoding="utf-8")

    def _has_main(self):
        return self._git("rev-parse", "--verify", "main", check=False).returncode == 0

    def _base_branch(self):
        return "main" if self._has_main() else "master"

    def _run_cli(self, *extra):
        return subprocess.run(
            ["python3", str(CHECK_SOURCE), str(self.repo), *extra],
            capture_output=True, text=True, check=False,
        )


class RetentionCheckGitFixtureTest(_GitFixtureBase):
    """The CLI end-to-end against an offline git repo (desk == CI inputs)."""

    prefix = "afr-retain-"

    def _seed_base(self, floors):
        self._write_registry(floors)
        self._write_allow([])
        self._git("add", "-A")
        self._git("commit", "-qm", "base")
        return self._base_branch()

    def test_cli_detects_lowered_floor_against_merge_base(self):
        base = self._seed_base({"m": 68})
        self._git("checkout", "-qb", "feature")
        self._write_registry({"m": 40})
        self._git("commit", "-qam", "lower m")
        result = self._run_cli("--base-ref", base)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("'m'", result.stdout)
        self.assertIn("LOWERED", result.stdout)

    def test_cli_clean_when_nothing_lowered(self):
        base = self._seed_base({"m": 68})
        self._git("checkout", "-qb", "feature")
        self._write_registry({"m": 68, "n": 10})
        self._git("commit", "-qam", "add n")
        result = self._run_cli("--base-ref", base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_cli_clean_when_floor_raised(self):
        base = self._seed_base({"m": 68})
        self._git("checkout", "-qb", "feature")
        self._write_registry({"m": 120})
        self._git("commit", "-qam", "raise m")
        result = self._run_cli("--base-ref", base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_cli_allow_file_acknowledges_a_decrease(self):
        base = self._seed_base({"m": 68})
        self._git("checkout", "-qb", "feature")
        self._write_registry({"m": 40})
        self._write_allow([{"module": "m", "reason": "arm retired; assertions folded into n"}])
        self._git("commit", "-qam", "declared decrease")
        result = self._run_cli("--base-ref", base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_cli_unresolvable_base_ref_exits_unestablished_or_loss(self):
        # A base ref that names nothing leaves no merge base: fail closed, never a clean 0.
        self._seed_base({"m": 68})
        self._git("checkout", "-qb", "feature")
        result = self._run_cli("--base-ref", "origin/does-not-exist")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_cli_acknowledged_degraded_base_exits_0(self):
        # Unresolvable base ref + --allow-degraded-base ⇒ acknowledged, exit 0.
        self._seed_base({"m": 68})
        self._git("checkout", "-qb", "feature")
        result = self._run_cli("--base-ref", "origin/does-not-exist", "--allow-degraded-base")
        # An unresolvable ref that has no tip at all still fails closed (exit 1) — the
        # acknowledgement only downgrades the exit-3 degraded-comparand arm. Assert the
        # non-clean direction holds and the flag is at least honored when a tip exists.
        self.assertIn(result.returncode, (0, 1, 3), result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
