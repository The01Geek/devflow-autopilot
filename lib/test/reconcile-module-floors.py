#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Measure exact module tallies and raise their coupled floors without decreasing them."""

from __future__ import annotations

import argparse
import copy
import difflib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


REGISTRY_PATH = "scripts/workflow-flight-recorder-registry.json"
RUN_PATH = "lib/test/run.sh"
SUMMARY = re.compile(
    r"^Module (?P<module>[a-z0-9][a-z0-9._-]*): "
    r"(?P<passed>[0-9]+) passed, (?P<failed>[0-9]+) failed"
    r"(?:, (?P<skipped>[0-9]+) skipped)?$",
    re.MULTILINE,
)


def _fail(message: str) -> int:
    print(f"floor-reconciliation: INFRASTRUCTURE {message}", file=sys.stderr)
    return 2


def _site_pattern(module_id: str) -> re.Pattern[str]:
    return re.compile(
        rf'(devflow_run_full_suite_module\s+"\$LIB/test/modules/'
        rf'{re.escape(module_id)}[.]sh"\s*\\?\s+"{re.escape(module_id)}"\s+)'
        r"([0-9]+)(;\s*then)",
        re.MULTILINE,
    )


def _patch(root: Path, before: dict[Path, str], after: dict[Path, str]) -> bool:
    chunks: list[str] = []
    for path in before:
        relative = path.relative_to(root).as_posix()
        chunks.extend(
            difflib.unified_diff(
                before[path].splitlines(keepends=True),
                after[path].splitlines(keepends=True),
                fromfile=f"a/{relative}",
                tofile=f"b/{relative}",
            )
        )
    proc = subprocess.run(
        ["git", "apply", "--whitespace=nowarn", "-"],
        cwd=root,
        input="".join(chunks),
        text=True,
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        print(
            "floor-reconciliation: INFRASTRUCTURE the coupled patch was not applied: "
            f"{(proc.stdout + proc.stderr).strip() or '(no output)'}",
            file=sys.stderr,
        )
        return False
    return True


def reconcile(root: Path, runner: Path) -> int:
    registry_path = root / REGISTRY_PATH
    run_path = root / RUN_PATH
    try:
        registry_text = registry_path.read_text(encoding="utf-8")
        registry = json.loads(registry_text)
        run_text = run_path.read_text(encoding="utf-8")
        modules = registry["test_modules"]
    except (OSError, UnicodeError, json.JSONDecodeError, KeyError, TypeError) as error:
        return _fail(f"could not read the coupled floor sources ({error})")

    exact_ids = [
        module_id
        for module_id, mapping in modules.items()
        if isinstance(mapping, dict)
        and mapping.get("assertion_floor_policy") == "exact"
    ]
    if not exact_ids:
        return _fail("the registry selects no exact assertion-floor modules")

    measurements: dict[str, int] = {}
    sites: dict[str, tuple[re.Match[str], int]] = {}
    runner_environment = os.environ.copy()
    if temp_root := runner_environment.get("TMPDIR"):
        runner_environment["TMPDIR"] = temp_root.rstrip("/") or "/"
    measurement_registry = copy.deepcopy(registry)
    for module_id in exact_ids:
        measurement_registry["test_modules"][module_id]["minimum_assertions"] = 1
        matches = list(_site_pattern(module_id).finditer(run_text))
        if len(matches) != 1:
            return _fail(
                f"{module_id}: expected one coupled run.sh boundary, found {len(matches)}"
            )
        sites[module_id] = (matches[0], int(matches[0].group(2)))

    with tempfile.TemporaryDirectory(prefix="devflow-floor-reconcile-") as temporary:
        temporary_path = Path(temporary)
        temporary_registry = temporary_path / "registry.json"
        temporary_registry.write_text(
            json.dumps(measurement_registry, indent=2) + "\n", encoding="utf-8"
        )
        for module_id in exact_ids:
            log_dir = temporary_path / f"logs-{module_id}"
            proc = subprocess.run(
                [
                    "bash",
                    str(runner),
                    "--registry",
                    str(temporary_registry),
                    "--log-dir",
                    str(log_dir),
                    module_id,
                ],
                cwd=root,
                env=runner_environment,
                text=True,
                capture_output=True,
                check=False,
            )
            matches = [
                match
                for match in SUMMARY.finditer(proc.stdout)
                if match.group("module") == module_id
            ]
            if proc.returncode != 0 or len(matches) != 1:
                return _fail(
                    f"{module_id}: focused run was not a single clean measurement "
                    f"(rc={proc.returncode}, summaries={len(matches)})"
                )
            summary = matches[0]
            failed = int(summary.group("failed"))
            skipped = int(summary.group("skipped") or 0)
            if failed != 0 or skipped != 0:
                return _fail(
                    f"{module_id}: measurement was not clean "
                    f"(failed={failed}, skipped={skipped})"
                )
            measurements[module_id] = int(summary.group("passed"))

    decreases = []
    for module_id, measured in measurements.items():
        registry_floor = modules[module_id]["minimum_assertions"]
        run_floor = sites[module_id][1]
        if measured < registry_floor or measured < run_floor:
            decreases.append(
                f"{module_id} measured={measured} registry={registry_floor} run.sh={run_floor}"
            )
    if decreases:
        print(
            "floor-reconciliation: DECREASE REFUSED — " + "; ".join(decreases),
            file=sys.stderr,
        )
        return 1

    updated_registry = copy.deepcopy(registry)
    updated_run = run_text
    raised = []
    for module_id, measured in measurements.items():
        registry_floor = modules[module_id]["minimum_assertions"]
        run_floor = sites[module_id][1]
        if measured > registry_floor or measured > run_floor:
            updated_registry["test_modules"][module_id]["minimum_assertions"] = measured
            updated_run, count = _site_pattern(module_id).subn(
                rf"\g<1>{measured}\g<3>", updated_run
            )
            if count != 1:
                return _fail(f"{module_id}: coupled run.sh site changed during staging")
            raised.append(module_id)

    if not raised:
        print("floor-reconciliation: clean — every measured tally matches both floors")
        return 0

    registry_after = json.dumps(updated_registry, indent=2) + "\n"
    before = {registry_path: registry_text, run_path: run_text}
    after = {registry_path: registry_after, run_path: updated_run}
    if not _patch(root, before, after):
        return 2
    print("floor-reconciliation: RAISED — " + ", ".join(raised))
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", default=None)
    parser.add_argument("--runner", default=None)
    args = parser.parse_args(argv)
    root = (
        Path(args.repo_root).resolve()
        if args.repo_root
        else Path(__file__).resolve().parents[2]
    )
    runner = (
        Path(args.runner).resolve()
        if args.runner
        else Path(
            os.environ.get(
                "DEVFLOW_RECONCILE_MODULE_FLOORS_RUNNER",
                root / "lib/test/run-module.sh",
            )
        ).resolve()
    )
    return reconcile(root, runner)


if __name__ == "__main__":
    raise SystemExit(main())
