#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Unit tests for the coverage-map ratchet guard (issue #591).

Each of the guard's arms is driven with a synthetic (tracked_files, map,
registry) fixture, following test_module_runner.py's fixture style. T-green
confirms the shipped tree + map passes; the named controls (T-planted, T-stale,
T-owner, T-shape, T-shape-registry, T-extension, T-subdir, T-misfile) each prove
the arm records a FAIL naming the offending path/entry."""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
GUARD_SOURCE = HERE / "coverage_map_guard.py"

_spec = importlib.util.spec_from_file_location("coverage_map_guard", GUARD_SOURCE)
guard = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(guard)


def _map(files=None, non_code_exempt=None, exempt_subtrees=None, run_sh_blocks=None):
    return {
        "schema_version": 1,
        "generated_by": "python3 -c '...'",
        "exempt_subtrees": ["lib/test/"] if exempt_subtrees is None else exempt_subtrees,
        "non_code_exempt": [] if non_code_exempt is None else non_code_exempt,
        "files": {} if files is None else files,
        "run_sh_blocks": {"unlabeled": {"owner": "unmodularized", "note": ""}}
        if run_sh_blocks is None
        else run_sh_blocks,
    }


def _registry(ids=("capability-profiles",)):
    return {"schema_version": 1, "test_modules": {i: {"path": f"lib/test/modules/{i}.sh"} for i in ids}}


def _owned(owner="unmodularized"):
    return {"owner": owner, "note": ""}


class CoverageMapGuardTest(unittest.TestCase):
    def _arms(self, violations):
        return {v.split("]", 1)[0].lstrip("[") for v in violations}

    # ── T-green: the shipped tree + committed map + registry passes cleanly. ──
    def test_green_shipped_tree(self):
        map_value = json.loads((ROOT / guard.MAP_REL).read_text(encoding="utf-8"))
        registry_value = json.loads((ROOT / guard.REGISTRY_REL).read_text(encoding="utf-8"))
        tracked = subprocess.run(
            ["git", "-C", str(ROOT), "ls-files"], capture_output=True, text=True, check=True
        ).stdout.split()
        self.assertEqual(guard.evaluate(tracked, map_value, registry_value), [])

    # ── T-planted (arm 1): an unlisted depth-1 pattern unit records FAIL naming it. ──
    def test_planted_unlisted_depth1_unit(self):
        tracked = ["lib/newthing.sh"]
        v = guard.evaluate(tracked, _map(files={}), _registry())
        self.assertEqual(self._arms(v), {"arm1"})
        self.assertIn("lib/newthing.sh", v[0])

    # ── T-stale (arm 2): a map entry naming an untracked path records FAIL. ──
    def test_stale_untracked_files_entry(self):
        tracked = ["lib/real.sh"]
        v = guard.evaluate(tracked, _map(files={"lib/real.sh": _owned(), "lib/gone.sh": _owned()}), _registry())
        self.assertEqual(self._arms(v), {"arm2"})
        self.assertIn("lib/gone.sh", "".join(v))

    def test_stale_untracked_non_code_exempt_entry(self):
        tracked = ["lib/real.sh"]
        v = guard.evaluate(tracked, _map(files={"lib/real.sh": _owned()}, non_code_exempt=["lib/gone.json"]), _registry())
        self.assertEqual(self._arms(v), {"arm2"})
        self.assertIn("lib/gone.json", "".join(v))

    # ── T-owner (arm 3): an owner neither a registered id nor `unmodularized`. ──
    def test_owner_not_registered(self):
        tracked = ["lib/real.sh"]
        v = guard.evaluate(tracked, _map(files={"lib/real.sh": _owned("bogus-module")}), _registry())
        self.assertEqual(self._arms(v), {"arm3"})
        self.assertIn("bogus-module", "".join(v))

    def test_owner_registered_id_passes(self):
        tracked = ["lib/real.sh"]
        v = guard.evaluate(tracked, _map(files={"lib/real.sh": _owned("capability-profiles")}), _registry())
        self.assertEqual(v, [])

    def test_owner_in_run_sh_blocks_checked(self):
        tracked = ["lib/real.sh"]
        blocks = {"561": _owned("bogus"), "unlabeled": _owned()}
        v = guard.evaluate(tracked, _map(files={"lib/real.sh": _owned()}, run_sh_blocks=blocks), _registry())
        self.assertEqual(self._arms(v), {"arm3"})

    # ── T-shape (arm 4): the six governing shapes over the MAP input. ──
    def test_shape_matrix_map(self):
        tracked = ["lib/real.sh"]
        reg = _registry()
        # valid object → passes (arm 1 fires because files is empty, proving valid-falsy is non-vacuous)
        v = guard.evaluate(tracked, _map(files={"lib/real.sh": _owned()}), reg)
        self.assertEqual(v, [])
        # array
        self.assertEqual(self._arms(guard.evaluate(tracked, [], reg)), {"arm4"})
        # scalar
        self.assertEqual(self._arms(guard.evaluate(tracked, 7, reg)), {"arm4"})
        # valid-falsy: files:{} is a LEGAL shape whose emptiness makes every unit
        # unlisted — must NOT pass vacuously (arm 1, not arm 4).
        self.assertEqual(self._arms(guard.evaluate(tracked, _map(files={}), reg)), {"arm1"})
        # missing file (read error)
        self.assertEqual(
            self._arms(guard.evaluate(tracked, None, reg, map_read_error="coverage-map.json not found")),
            {"arm4"},
        )
        # wrong-type value: files not a dict
        bad = _map()
        bad["files"] = ["lib/real.sh"]
        self.assertEqual(self._arms(guard.evaluate(tracked, bad, reg)), {"arm4"})
        # wrong-type value: an entry owner not a string
        bad2 = _map(files={"lib/real.sh": {"owner": 7, "note": ""}})
        self.assertEqual(self._arms(guard.evaluate(tracked, bad2, reg)), {"arm4"})

    def test_shape_map_breadcrumb_names_file_and_remedy(self):
        v = guard.evaluate(["lib/real.sh"], [], _registry())
        self.assertTrue(any(guard.MAP_REL in line and "CONTRIBUTING" in line for line in v))

    # ── T-shape-registry (arm 8): the six governing shapes over the REGISTRY input. ──
    def test_shape_matrix_registry(self):
        tracked = ["lib/real.sh"]
        m = _map(files={"lib/real.sh": _owned()})
        # valid object
        self.assertEqual(guard.evaluate(tracked, m, _registry()), [])
        # array
        self.assertIn("arm8", self._arms(guard.evaluate(tracked, m, [])))
        # scalar
        self.assertIn("arm8", self._arms(guard.evaluate(tracked, m, 7)))
        # valid-falsy: test_modules:{} — a legal empty object; owners default to
        # unmodularized so no owner fails, and an empty id-set is a valid shape (arm 8
        # keys on non-object, not on emptiness).
        self.assertEqual(guard.evaluate(tracked, m, {"schema_version": 1, "test_modules": {}}), [])
        # missing file (read error)
        self.assertIn(
            "arm8",
            self._arms(guard.evaluate(tracked, m, None, registry_read_error="registry not found")),
        )
        # wrong-type: test_modules not an object
        self.assertIn("arm8", self._arms(guard.evaluate(tracked, m, {"test_modules": ["x"]})))

    def test_shape_registry_breadcrumb_names_registry(self):
        v = guard.evaluate(["lib/real.sh"], _map(files={"lib/real.sh": _owned()}), {"test_modules": 3})
        self.assertTrue(any(guard.REGISTRY_REL in line for line in v))

    # ── T-extension (arm 5): a depth-1 code file of an out-of-set extension. ──
    def test_extension_scripts_jq_ratcheted(self):
        tracked = ["scripts/x.jq"]
        v = guard.evaluate(tracked, _map(files={}), _registry())
        self.assertEqual(self._arms(v), {"arm5"})
        self.assertIn("scripts/x.jq", "".join(v))
        # the hint steers to extending the pattern set, not to non_code_exempt
        self.assertIn("pattern set", "".join(v))

    def test_non_pattern_non_code_depth1_needs_non_code_exempt(self):
        tracked = ["lib/data.json"]
        # absent from non_code_exempt → arm5
        self.assertEqual(self._arms(guard.evaluate(tracked, _map(), _registry())), {"arm5"})
        # listed → clean
        self.assertEqual(guard.evaluate(tracked, _map(non_code_exempt=["lib/data.json"]), _registry()), [])

    # ── T-subdir (arm 6): a code file in a new subtree outside exempt_subtrees. ──
    def test_subdir_code_file_ratcheted(self):
        tracked = ["scripts/hooks/deploy.sh"]
        v = guard.evaluate(tracked, _map(), _registry())
        self.assertEqual(self._arms(v), {"arm6"})
        self.assertIn("scripts/hooks/deploy.sh", "".join(v))

    def test_subdir_under_exempt_subtree_passes(self):
        tracked = ["lib/test/run.sh", "lib/test/modules/x.sh"]
        self.assertEqual(guard.evaluate(tracked, _map(), _registry()), [])

    # ── T-misfile (arm 7): a code unit misfiled into non_code_exempt. ──
    def test_misfile_code_in_non_code_exempt(self):
        tracked = ["scripts/x.sh"]
        # scripts/x.sh IS a pattern unit, so if it's only in non_code_exempt it also
        # trips arm1 (absent from files) AND arm7 (code ext in non_code_exempt).
        v = guard.evaluate(tracked, _map(non_code_exempt=["scripts/x.sh"]), _registry())
        self.assertIn("arm7", self._arms(v))
        self.assertIn("scripts/x.sh", "".join(line for line in v if line.startswith("[arm7]")))

    # ── Never raises on the fail-closed paths (arm 4 / arm 8 read errors). ──
    def test_both_inputs_unreadable_fails_closed_no_raise(self):
        v = guard.evaluate([], None, None, map_read_error="m gone", registry_read_error="r gone")
        arms = self._arms(v)
        self.assertIn("arm4", arms)
        self.assertIn("arm8", arms)

    # ── Arm 4 sub-shape controls: each structural guard in _map_shape_error fires. ──
    def test_shape_matrix_map_subshapes(self):
        tracked = ["lib/real.sh"]
        reg = _registry()

        def mutated(**overrides):
            m = _map(files={"lib/real.sh": _owned()})
            m.update(overrides)
            return m

        cases = [
            mutated(schema_version=2),  # schema_version != 1
            mutated(schema_version=True),  # bool is an int subclass; True == 1 must NOT pass
            mutated(run_sh_blocks=[]),  # run_sh_blocks not a dict
            mutated(run_sh_blocks={"561": {"owner": 7, "note": ""}}),  # non-string owner
            mutated(non_code_exempt=[7]),  # non_code_exempt non-string item
            mutated(exempt_subtrees=[7]),  # exempt_subtrees non-string item
            mutated(generated_by=7),  # generated_by not a string
        ]
        for m in cases:
            self.assertEqual(self._arms(guard.evaluate(tracked, m, reg)), {"arm4"})

    # ── Arm 3 registry-unavailable suppression: a wrong-shape registry records arm 8 only,
    # and does NOT double-report arm 3 on an owner that would otherwise be invalid. ──
    def test_arm3_suppressed_when_registry_unreadable(self):
        tracked = ["lib/real.sh"]
        m = _map(files={"lib/real.sh": _owned("would-be-invalid")})
        # wrong-shape registry (test_modules non-object) → arm8, arm3 suppressed
        self.assertEqual(self._arms(guard.evaluate(tracked, m, {"test_modules": ["x"]})), {"arm8"})
        # registry read error → same suppression
        self.assertEqual(
            self._arms(guard.evaluate(tracked, m, None, registry_read_error="gone")), {"arm8"}
        )

    # ── Cardinality: a violation loop names EVERY offender, not just the first (a `break`
    # regression would still pass a set-keyed assertion). ──
    def test_arm1_reports_every_offender(self):
        tracked = ["lib/one.sh", "lib/two.sh"]
        v = guard.evaluate(tracked, _map(files={}), _registry())
        self.assertEqual(self._arms(v), {"arm1"})
        joined = "".join(v)
        self.assertIn("lib/one.sh", joined)
        self.assertIn("lib/two.sh", joined)

    # ── Arm 6 boundary: an exempt_subtrees entry without a trailing slash exempts its own
    # subtree but NOT a sibling sharing the prefix (lib/test exempts lib/test/x, not
    # lib/testfoo/x). ──
    def test_arm6_prefix_is_slash_bounded(self):
        tracked = ["lib/testfoo/x.sh"]
        # exempt entry "lib/test" (no slash) must NOT exempt lib/testfoo/x.sh
        v = guard.evaluate(tracked, _map(exempt_subtrees=["lib/test"]), _registry())
        self.assertEqual(self._arms(v), {"arm6"})
        # but it DOES exempt its own subtree
        self.assertEqual(guard.evaluate(["lib/test/x.sh"], _map(exempt_subtrees=["lib/test"]), _registry()), [])

    # ── CLI / IO layer: main() returns non-zero and prints the arm on a violating tree,
    # and _load_json produces (not just consumes) each read-error breadcrumb. ──
    def test_cli_main_and_load_json_error_arms(self):
        # _load_json error arms — the breadcrumbs arms 4/8 rely on are actually PRODUCED here.
        with tempfile.TemporaryDirectory() as d:
            dp = Path(d)
            self.assertEqual(guard._load_json(dp / "missing.json")[0], None)
            self.assertIn("not found", guard._load_json(dp / "missing.json")[1])
            bad = dp / "bad.json"
            bad.write_text("{ not json", encoding="utf-8")
            self.assertEqual(guard._load_json(bad)[0], None)
            self.assertIn("malformed JSON", guard._load_json(bad)[1])
            adir = dp / "adir.json"
            adir.mkdir()
            self.assertEqual(guard._load_json(adir)[0], None)  # a directory is unreadable, not parsed
        # main() negative control: a real git tree with a planted unlisted depth-1 unit +
        # a map that doesn't list it → rc 1 and the arm-1 line on stdout.
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            subprocess.run(["git", "-C", str(root), "init", "-q"], check=True)
            (root / "lib" / "test" / "modules").mkdir(parents=True)
            (root / "scripts").mkdir()
            (root / "lib" / "planted.sh").write_text("#!/usr/bin/env bash\n", encoding="utf-8")
            (root / "lib" / "test" / "modules" / "coverage-map.json").write_text(
                json.dumps(_map(files={})), encoding="utf-8"
            )
            (root / "scripts" / "workflow-flight-recorder-registry.json").write_text(
                json.dumps(_registry()), encoding="utf-8"
            )
            subprocess.run(["git", "-C", str(root), "add", "-A"], check=True)
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                rc = guard.main(["coverage_map_guard.py", str(root)])
            self.assertEqual(rc, 1)
            self.assertIn("lib/planted.sh", out.getvalue())
            self.assertIn("[arm1]", out.getvalue())

    # ── main() fail-closed git branch: git ls-files failing → rc 1 + the named
    # breadcrumb (the only advertised fail-closed arm without a positive control).
    # Point main() at a non-existent directory under a fresh tempdir so `git -C <path>`
    # fails deterministically (cannot chdir) — independent of any ambient repo around
    # the test's cwd. Assert the breadcrumb, not just rc, so a silenced branch is caught.
    def test_cli_main_git_failure_fails_closed(self):
        with tempfile.TemporaryDirectory() as d:
            missing = Path(d) / "no-such-dir"
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                rc = guard.main(["coverage_map_guard.py", str(missing)])
            self.assertEqual(rc, 1)
            self.assertIn("[input-error]", out.getvalue())
            self.assertIn("git ls-files failed", out.getvalue())


if __name__ == "__main__":
    unittest.main()
