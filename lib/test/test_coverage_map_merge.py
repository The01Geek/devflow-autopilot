#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Offline regression tests for the coverage-map merge tooling (issue #1194).

Two mechanisms, tested independently:

* the JSON-aware git merge driver (`coverage-map-merge-driver.py`) — driven against
  REAL `git merge`s in throwaway offline repositories (no network, no `gh`): two
  branches each add a distinct key at the same insertion point (AC1/AC2), and a
  genuine same-key divergence conflicts rather than silently picking a side (AC3).
  The driver is registered in each fixture's OWN local config; the developer's global
  git config is never written (AC4). The AC5 mutation arm runs the same distinct-key
  merge with the driver UNREGISTERED and asserts the textual conflict returns.

* the CI-side key-retention check (`coverage-map-retention-check.py`) — its pure
  `detect_losses` core is driven from in-memory fixtures over every loss shape,
  including a `run_sh_blocks` key with no derivation and a dropped `note`/`owner`
  (AC8), the non-empty-reason escape hatch, and the AC5 defeated-comparison arm.
"""
from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
DRIVER_SOURCE = HERE / "coverage-map-merge-driver.py"
RETAIN_SOURCE = HERE / "coverage-map-retention-check.py"
GUARD_SOURCE = HERE / "coverage_map_guard.py"
POP_SOURCE = HERE / "lint_population.py"
MAP_REL = "lib/test/modules/coverage-map.json"


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


driver = _load("coverage_map_merge_driver", DRIVER_SOURCE)
retain = _load("coverage_map_retention_check", RETAIN_SOURCE)


def _serialize(map_value) -> str:
    return json.dumps(map_value, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def _base_map(run_sh_blocks=None, files=None):
    return {
        "schema_version": 1,
        "generated_by": "test",
        "exempt_subtrees": ["lib/test/"],
        "non_code_exempt": [],
        "files": files or {},
        "run_sh_blocks": run_sh_blocks or {},
    }


class MergeDriverGitFixtureTest(unittest.TestCase):
    """AC1–AC5: the driver against real offline `git merge`s."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="cm-merge-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        self._git("init", "-q")
        self._git("config", "user.email", "t@t")
        self._git("config", "user.name", "t")
        # A repository-local git config only — never the developer's global config (AC4).
        # commit.gpgsign off so signing config on the host machine cannot break fixtures.
        self._git("config", "commit.gpgsign", "false")
        (self.repo / "lib" / "test" / "modules").mkdir(parents=True)
        # The driver imports the coverage guard, which imports lint_population; copy all
        # three so the fixture is self-contained and offline.
        for src in (DRIVER_SOURCE, GUARD_SOURCE, POP_SOURCE):
            shutil.copy(src, self.repo / "lib" / "test" / src.name)
        self._write_map(_base_map(run_sh_blocks={
            "1210": {"note": "n1210", "owner": "unmodularized"},
            "1290": {"note": "n1290", "owner": "unmodularized"},
        }))
        (self.repo / ".gitattributes").write_text(
            f"{MAP_REL} merge=coverage-map-json\n", encoding="utf-8"
        )
        self._git("add", "-A")
        self._git("commit", "-qm", "base")

    def _git(self, *args, check=True):
        return subprocess.run(
            ["git", "-C", str(self.repo), *args],
            capture_output=True,
            text=True,
            check=check,
        )

    def _write_map(self, map_value):
        (self.repo / MAP_REL).write_text(_serialize(map_value), encoding="utf-8")

    def _read_map(self):
        return json.loads((self.repo / MAP_REL).read_text(encoding="utf-8"))

    def _register_driver(self):
        self._git(
            "config", "merge.coverage-map-json.name", "coverage-map JSON-aware merge driver"
        )
        self._git(
            "config",
            "merge.coverage-map-json.driver",
            f"python3 lib/test/{DRIVER_SOURCE.name} %O %A %B",
        )

    def _add_key_on_branch(self, branch, section, key, entry):
        self._git("checkout", "-q", "main" if self._has_main() else "master")
        self._git("checkout", "-qb", branch)
        m = self._read_map()
        m[section][key] = entry
        self._write_map(m)
        self._git("commit", "-qam", f"{branch} adds {key}")

    def _has_main(self):
        r = self._git("rev-parse", "--verify", "main", check=False)
        return r.returncode == 0

    def _default_branch(self):
        return "main" if self._has_main() else "master"

    def _two_distinct_keys(self, section, key_a, key_b):
        self._add_key_on_branch("A", section, key_a, {"note": f"{key_a} note", "owner": "unmodularized"})
        self._add_key_on_branch("B", section, key_b, {"note": f"{key_b} note", "owner": "unmodularized"})
        self._git("checkout", "-q", "A")
        return self._git("merge", "--no-edit", "B", check=False)

    def test_AC1_distinct_run_sh_blocks_keys_both_survive(self):
        self._register_driver()
        result = self._two_distinct_keys("run_sh_blocks", "1211", "1212")
        self.assertEqual(result.returncode, 0, f"merge should be clean:\n{result.stderr}")
        m = self._read_map()
        self.assertEqual(m["run_sh_blocks"]["1211"], {"note": "1211 note", "owner": "unmodularized"})
        self.assertEqual(m["run_sh_blocks"]["1212"], {"note": "1212 note", "owner": "unmodularized"})
        # The two pre-existing adjacent keys are untouched, byte-intact.
        self.assertEqual(m["run_sh_blocks"]["1210"], {"note": "n1210", "owner": "unmodularized"})

    def test_AC2_distinct_files_keys_both_survive(self):
        self._register_driver()
        result = self._two_distinct_keys("files", "lib/aaa.sh", "lib/aab.sh")
        self.assertEqual(result.returncode, 0, f"merge should be clean:\n{result.stderr}")
        m = self._read_map()
        self.assertIn("lib/aaa.sh", m["files"])
        self.assertIn("lib/aab.sh", m["files"])

    def test_AC3_same_key_divergence_conflicts(self):
        self._register_driver()
        # Both branches add the SAME key with different content.
        self._add_key_on_branch("A", "run_sh_blocks", "1250", {"note": "A version", "owner": "unmodularized"})
        self._add_key_on_branch("B", "run_sh_blocks", "1250", {"note": "B version", "owner": "unmodularized"})
        self._git("checkout", "-q", "A")
        result = self._git("merge", "--no-edit", "B", check=False)
        self.assertNotEqual(result.returncode, 0, "same-key divergence must NOT merge silently")
        # The path is left conflicted (unmerged) — a human decision is required.
        status = self._git("status", "--porcelain", MAP_REL)
        self.assertTrue(status.stdout.strip().startswith(("UU", "AA")),
                        f"map should be unmerged, got: {status.stdout!r}")

    def test_AC5_mutation_unregistered_driver_reintroduces_conflict(self):
        # No _register_driver(): the attribute names the driver but git falls back to its
        # line-based three-way merge, which conflicts on the adjacent insertion point.
        result = self._two_distinct_keys("run_sh_blocks", "1211", "1212")
        self.assertNotEqual(
            result.returncode, 0,
            "with the driver UNREGISTERED the adjacent-key merge must conflict (the defect)",
        )

    def test_AC4_no_global_git_config_written(self):
        # Registration writes only the fixture's local config; assert the driver key is
        # absent from the global config after a full registered merge.
        self._register_driver()
        self._two_distinct_keys("run_sh_blocks", "1211", "1212")
        globalcfg = subprocess.run(
            ["git", "config", "--global", "--get", "merge.coverage-map-json.driver"],
            capture_output=True, text=True, check=False,
        )
        self.assertNotEqual(globalcfg.returncode, 0,
                            "the driver must never be written to the global git config")


class MergeDriverUnitTest(unittest.TestCase):
    """The pure `merge_maps` core, independent of git."""

    def test_distinct_keys_union(self):
        base = _base_map(run_sh_blocks={"a": {"note": "", "owner": "unmodularized"}})
        ours = _base_map(run_sh_blocks={"a": {"note": "", "owner": "unmodularized"},
                                        "b": {"note": "B", "owner": "unmodularized"}})
        theirs = _base_map(run_sh_blocks={"a": {"note": "", "owner": "unmodularized"},
                                          "c": {"note": "C", "owner": "unmodularized"}})
        merged = driver.merge_maps(base, ours, theirs)
        self.assertEqual(set(merged["run_sh_blocks"]), {"a", "b", "c"})

    def test_delete_on_one_side_is_honored(self):
        base = _base_map(run_sh_blocks={"a": {"note": "x", "owner": "unmodularized"}})
        ours = _base_map(run_sh_blocks={})  # ours deletes a
        theirs = _base_map(run_sh_blocks={"a": {"note": "x", "owner": "unmodularized"}})
        merged = driver.merge_maps(base, ours, theirs)
        self.assertNotIn("a", merged["run_sh_blocks"])

    def test_same_key_divergence_raises(self):
        base = _base_map(run_sh_blocks={"a": {"note": "base", "owner": "unmodularized"}})
        ours = _base_map(run_sh_blocks={"a": {"note": "ours", "owner": "unmodularized"}})
        theirs = _base_map(run_sh_blocks={"a": {"note": "theirs", "owner": "unmodularized"}})
        with self.assertRaises(driver.MergeConflict):
            driver.merge_maps(base, ours, theirs)

    def test_top_level_divergence_raises(self):
        base = _base_map()
        ours = _base_map()
        ours["generated_by"] = "ours"
        theirs = _base_map()
        theirs["generated_by"] = "theirs"
        with self.assertRaises(driver.MergeConflict):
            driver.merge_maps(base, ours, theirs)


class RetentionCheckTest(unittest.TestCase):
    """AC8 + AC5-retention: the pure `detect_losses` core."""

    def test_clean_when_nothing_dropped(self):
        base = _base_map(run_sh_blocks={"1": {"note": "n", "owner": "unmodularized"}})
        head = _base_map(run_sh_blocks={"1": {"note": "n", "owner": "unmodularized"},
                                        "2": {"note": "n2", "owner": "unmodularized"}})
        self.assertEqual(retain.detect_losses(base, head, None), [])

    def test_removed_run_sh_blocks_key_detected(self):
        base = _base_map(run_sh_blocks={"431": {"note": "curated record", "owner": "unmodularized"}})
        head = _base_map(run_sh_blocks={})
        losses = retain.detect_losses(base, head, None)
        self.assertTrue(any("431" in v and "absent" in v for v in losses), losses)

    def test_removed_files_key_detected(self):
        base = _base_map(files={"lib/x.sh": {"note": "n", "owner": "unmodularized"}})
        head = _base_map(files={})
        losses = retain.detect_losses(base, head, None)
        self.assertTrue(any("lib/x.sh" in v for v in losses), losses)

    def test_dropped_note_content_detected(self):
        base = _base_map(run_sh_blocks={"1": {"note": "two-clause record", "owner": "efficiency-trace"}})
        head = _base_map(run_sh_blocks={"1": {"note": "", "owner": "efficiency-trace"}})
        losses = retain.detect_losses(base, head, None)
        self.assertTrue(any("'note'" in v and "dropped" in v for v in losses), losses)

    def test_dropped_owner_content_detected(self):
        base = _base_map(run_sh_blocks={"1": {"note": "n", "owner": "some-module"}})
        head = _base_map(run_sh_blocks={"1": {"note": "n", "owner": ""}})
        losses = retain.detect_losses(base, head, None)
        self.assertTrue(any("'owner'" in v and "dropped" in v for v in losses), losses)

    def test_owner_change_is_not_a_drop(self):
        base = _base_map(run_sh_blocks={"1": {"note": "n", "owner": "module-a"}})
        head = _base_map(run_sh_blocks={"1": {"note": "n", "owner": "module-b"}})
        self.assertEqual(retain.detect_losses(base, head, None), [])

    def test_escape_hatch_with_reason_permits_removal(self):
        base = _base_map(run_sh_blocks={"431": {"note": "n", "owner": "unmodularized"}})
        head = _base_map(run_sh_blocks={})
        allow = [{"half": "run_sh_blocks", "key": "431", "reason": "block genuinely retired in PR #999"}]
        self.assertEqual(retain.detect_losses(base, head, allow), [])

    def test_escape_hatch_empty_reason_rejected(self):
        base = _base_map(run_sh_blocks={"431": {"note": "n", "owner": "unmodularized"}})
        head = _base_map(run_sh_blocks={})
        allow = [{"half": "run_sh_blocks", "key": "431", "reason": "   "}]
        losses = retain.detect_losses(base, head, allow)
        # Both the malformed-entry breadcrumb AND the unpermitted removal are reported.
        self.assertTrue(any("no non-empty 'reason'" in v for v in losses), losses)
        self.assertTrue(any("absent" in v for v in losses), losses)

    def test_malformed_allowlist_is_fail_closed(self):
        base = _base_map(run_sh_blocks={"431": {"note": "n", "owner": "unmodularized"}})
        head = _base_map(run_sh_blocks={})
        losses = retain.detect_losses(base, head, {"not": "a list"})
        self.assertTrue(any("must be a JSON array" in v for v in losses), losses)
        self.assertTrue(any("absent" in v for v in losses), losses)

    def test_AC5_mutation_defeated_comparison_misses_the_drop(self):
        # Defeating the comparison = comparing head against itself (no base to lose from).
        # With the comparison intact (base carries the key) the drop is caught; with it
        # defeated (base == head) the very same dropped-key input reports clean — the
        # mutation the AC5 arm records.
        head = _base_map(run_sh_blocks={})
        base_with_key = _base_map(run_sh_blocks={"431": {"note": "n", "owner": "unmodularized"}})
        self.assertNotEqual(retain.detect_losses(base_with_key, head, None), [],
                            "intact comparison must catch the drop")
        self.assertEqual(retain.detect_losses(head, head, None), [],
                         "defeated comparison (base==head) misses the drop")


class RetentionCheckGitFixtureTest(unittest.TestCase):
    """The retention CLI end-to-end against an offline git repo (desk == CI inputs)."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="cm-retain-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.repo = self.tmp / "repo"
        (self.repo / "lib" / "test" / "modules").mkdir(parents=True)
        self._git("init", "-q")
        self._git("config", "user.email", "t@t")
        self._git("config", "user.name", "t")
        self._git("config", "commit.gpgsign", "false")

    def _git(self, *args, check=True):
        return subprocess.run(["git", "-C", str(self.repo), *args],
                              capture_output=True, text=True, check=check)

    def _write_map(self, m):
        (self.repo / MAP_REL).write_text(_serialize(m), encoding="utf-8")

    def _run_cli(self):
        return subprocess.run(
            ["python3", str(RETAIN_SOURCE), str(self.repo), "--base-ref", self._base_branch()],
            capture_output=True, text=True, check=False,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        )

    def _base_branch(self):
        r = self._git("rev-parse", "--verify", "main", check=False)
        return "main" if r.returncode == 0 else "master"

    def test_cli_detects_dropped_key_against_merge_base(self):
        self._write_map(_base_map(run_sh_blocks={"431": {"note": "curated", "owner": "unmodularized"}}))
        self._git("add", "-A")
        self._git("commit", "-qm", "base")
        base = self._base_branch()
        self._git("checkout", "-qb", "feature")
        # drop the key
        self._write_map(_base_map(run_sh_blocks={}))
        self._git("commit", "-qam", "drop 431")
        result = subprocess.run(
            ["python3", str(RETAIN_SOURCE), str(self.repo), "--base-ref", base],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("431", result.stdout)

    def test_cli_clean_when_nothing_dropped(self):
        self._write_map(_base_map(run_sh_blocks={"431": {"note": "curated", "owner": "unmodularized"}}))
        self._git("add", "-A")
        self._git("commit", "-qm", "base")
        base = self._base_branch()
        self._git("checkout", "-qb", "feature")
        self._write_map(_base_map(run_sh_blocks={
            "431": {"note": "curated", "owner": "unmodularized"},
            "432": {"note": "new", "owner": "unmodularized"},
        }))
        self._git("commit", "-qam", "add 432")
        result = subprocess.run(
            ["python3", str(RETAIN_SOURCE), str(self.repo), "--base-ref", base],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
