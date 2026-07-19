#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Coverage-map ratchet guard (issue #591).

Fails RED — never a skip, never a silent pass — when the module coverage map
(`lib/test/modules/coverage-map.json`) falls out of sync with the git-tracked
`lib/` / `scripts/` surface or the module registry, so a new code unit cannot
ship without a recorded coverage decision.

Selection path derives every decision through `git` and `python3` ONLY (both
preflight-guaranteed; CLAUDE.md guard-class 2 forbids a non-preflight PATH tool
deciding a selection): git-tracked paths come from `git ls-files` (an index read,
shallow-clone-safe, reads no history), and all shape/membership logic is Python.

The guard is importable — `evaluate(...)` is a pure function over
(tracked_files, map value, registry value) so `test_coverage_map_guard.py` can
drive every one of its 8 arms with synthetic fixtures — and runnable as a CLI:
`python3 lib/test/coverage_map_guard.py [repo_root]` prints one violation per
line to stdout and exits non-zero on any violation (or a fail-closed input
error), 0 when clean.
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

MAP_REL = "lib/test/modules/coverage-map.json"
REGISTRY_REL = "scripts/workflow-flight-recorder-registry.json"

# The five depth-1 patterns, as (top-level dir, extension) pairs. Complete by
# construction at seeding time (issue #591 AC). Note scripts/*.jq is deliberately
# NOT a pattern — a depth-1 scripts/*.jq is a code unit outside the set, caught by
# arm 5 (absent from non_code_exempt) so the pattern set itself is ratcheted.
PATTERNS = frozenset(
    {("lib", ".sh"), ("lib", ".jq"), ("lib", ".py"), ("scripts", ".sh"), ("scripts", ".py")}
)
CODE_EXTS = frozenset({".sh", ".jq", ".py"})
TOP_DIRS = frozenset({"lib", "scripts"})
UNMODULARIZED = "unmodularized"

MAP_REMEDY = (
    f"repair or regenerate {MAP_REL} per CONTRIBUTING.md's module-authoring "
    "checklist (schema_version 1; files/run_sh_blocks objects; "
    "non_code_exempt/exempt_subtrees arrays; generated_by string)"
)
REGISTRY_REMEDY = (
    f"repair {REGISTRY_REL} so test_modules is a JSON object of module entries"
)


def _depth1(path: str) -> bool:
    parts = path.split("/")
    return len(parts) == 2 and parts[0] in TOP_DIRS


def _ext(path: str) -> str:
    name = path.rsplit("/", 1)[-1]
    dot = name.rfind(".")
    return name[dot:] if dot > 0 else ""


def _matches_pattern(path: str) -> bool:
    return _depth1(path) and (path.split("/")[0], _ext(path)) in PATTERNS


def _under_lib_or_scripts(path: str) -> bool:
    return path.split("/")[0] in TOP_DIRS and "/" in path


def _valid_owner(owner: object, valid_ids: "set[str] | None") -> bool:
    if owner == UNMODULARIZED:
        return True
    if valid_ids is None:
        # Registry unreadable/wrong-shape: the comparand set is unavailable, so
        # owner validity cannot be established. Arm 8 already recorded the
        # registry failure; do not double-report every owner here.
        return True
    return isinstance(owner, str) and owner in valid_ids


def _registry_module_ids(registry_value: object) -> "set[str] | None":
    """Return the set of registered test_modules ids, or None if the registry is
    absent/unreadable/wrong-shape (including a non-object test_modules section)."""
    if not isinstance(registry_value, dict):
        return None
    modules = registry_value.get("test_modules")
    if not isinstance(modules, dict):
        return None
    return set(modules.keys())


def _map_shape_error(map_value: object) -> "str | None":
    """Return a specific breadcrumb if the map is not a well-shaped object, else None.

    Structural types only — arm 4. Owner *values* are checked by arm 3, and an
    empty-but-legal `files: {}` is a valid shape (it makes every unit unlisted,
    caught non-vacuously by arm 1), so it is NOT a shape error here."""
    if not isinstance(map_value, dict):
        return f"coverage-map is not a JSON object; {MAP_REMEDY}"
    if map_value.get("schema_version") != 1 or not isinstance(map_value.get("schema_version"), int):
        return f"coverage-map schema_version must be integer 1; {MAP_REMEDY}"
    if not isinstance(map_value.get("files"), dict):
        return f"coverage-map 'files' must be a JSON object; {MAP_REMEDY}"
    if not isinstance(map_value.get("run_sh_blocks"), dict):
        return f"coverage-map 'run_sh_blocks' must be a JSON object; {MAP_REMEDY}"
    if not isinstance(map_value.get("non_code_exempt"), list):
        return f"coverage-map 'non_code_exempt' must be a JSON array; {MAP_REMEDY}"
    if not isinstance(map_value.get("exempt_subtrees"), list):
        return f"coverage-map 'exempt_subtrees' must be a JSON array; {MAP_REMEDY}"
    if not isinstance(map_value.get("generated_by"), str):
        return f"coverage-map 'generated_by' must be a string; {MAP_REMEDY}"
    for key, entry in map_value["files"].items():
        if not isinstance(entry, dict) or not isinstance(entry.get("owner"), str):
            return f"coverage-map files entry {key!r} must be an object with a string 'owner'; {MAP_REMEDY}"
    for key, entry in map_value["run_sh_blocks"].items():
        if not isinstance(entry, dict) or not isinstance(entry.get("owner"), str):
            return f"coverage-map run_sh_blocks entry {key!r} must be an object with a string 'owner'; {MAP_REMEDY}"
    for item in map_value["non_code_exempt"]:
        if not isinstance(item, str):
            return f"coverage-map non_code_exempt entries must be strings; {MAP_REMEDY}"
    for item in map_value["exempt_subtrees"]:
        if not isinstance(item, str):
            return f"coverage-map exempt_subtrees entries must be strings; {MAP_REMEDY}"
    return None


def evaluate(
    tracked_files,
    map_value,
    registry_value,
    *,
    map_read_error: "str | None" = None,
    registry_read_error: "str | None" = None,
):
    """Return a list of violation breadcrumbs (empty ⇒ clean). Never raises.

    Each of the 8 arms records a FAIL line. `map_read_error` / `registry_read_error`
    carry a read/parse failure the CLI already hit (arms 4 / 8 fail closed on an
    absent/unreadable file too, not only a wrong shape)."""
    violations = []

    # ── Arm 8: registry absent/unreadable/wrong-shape (incl. non-object test_modules)
    if registry_read_error is not None:
        violations.append(f"[arm8] registry unreadable: {registry_read_error}; {REGISTRY_REMEDY}")
        valid_ids = None
    else:
        valid_ids = _registry_module_ids(registry_value)
        if valid_ids is None:
            violations.append(
                f"[arm8] registry {REGISTRY_REL} is wrong-shape (test_modules is not a JSON object); {REGISTRY_REMEDY}"
            )

    # ── Arm 4: map absent/unreadable/wrong-shape → fail closed, skip map-dependent arms
    if map_read_error is not None:
        violations.append(f"[arm4] coverage-map unreadable: {map_read_error}; {MAP_REMEDY}")
        return violations
    shape_error = _map_shape_error(map_value)
    if shape_error is not None:
        violations.append(f"[arm4] {shape_error}")
        return violations

    files = map_value["files"]
    non_code_exempt = list(map_value["non_code_exempt"])
    exempt_subtrees = list(map_value["exempt_subtrees"])
    run_sh_blocks = map_value["run_sh_blocks"]
    tracked = set(tracked_files)
    non_code_set = set(non_code_exempt)

    # ── Arm 1: a git-tracked depth-1 pattern unit absent from `files`
    for path in sorted(tracked):
        if _matches_pattern(path) and path not in files:
            violations.append(
                f"[arm1] git-tracked depth-1 unit {path!r} matches a coverage pattern but is absent from coverage-map 'files' — add it with an owner"
            )

    # ── Arm 5: a git-tracked depth-1 file matching NO pattern, absent from non_code_exempt
    for path in sorted(tracked):
        if _depth1(path) and not _matches_pattern(path) and path not in non_code_set:
            hint = (
                " (it carries a code extension — extend the pattern set in map+guard+convention, never list a code file in non_code_exempt)"
                if _ext(path) in CODE_EXTS
                else ""
            )
            violations.append(
                f"[arm5] git-tracked depth-1 file {path!r} matches none of the five patterns and is absent from non_code_exempt{hint}"
            )

    # ── Arm 6: a git-tracked code file deeper than depth-1, outside every exempt subtree
    for path in sorted(tracked):
        if _under_lib_or_scripts(path) and not _depth1(path) and _ext(path) in CODE_EXTS:
            if not any(path.startswith(sub) for sub in exempt_subtrees):
                violations.append(
                    f"[arm6] git-tracked code file {path!r} is deeper than depth-1 and outside every exempt_subtrees entry — cover it or add its subtree to exempt_subtrees"
                )

    # ── Arm 2: a files or non_code_exempt entry naming a non-git-tracked path
    for path in sorted(files):
        if path not in tracked:
            violations.append(f"[arm2] coverage-map files entry {path!r} is not a git-tracked file")
    for path in non_code_exempt:
        if path not in tracked:
            violations.append(f"[arm2] coverage-map non_code_exempt entry {path!r} is not a git-tracked file")

    # ── Arm 7: a non_code_exempt entry whose path carries a code extension
    for path in non_code_exempt:
        if _ext(path) in CODE_EXTS:
            violations.append(
                f"[arm7] coverage-map non_code_exempt entry {path!r} carries a code extension — a code unit misfiled as non-code; move it to 'files' with an owner"
            )

    # ── Arm 3: an owner value that is neither a registered module id nor `unmodularized`
    for path in sorted(files):
        owner = files[path].get("owner")
        if not _valid_owner(owner, valid_ids):
            violations.append(
                f"[arm3] coverage-map files entry {path!r} owner {owner!r} is neither a registered test_modules id nor {UNMODULARIZED!r}"
            )
    for label in sorted(run_sh_blocks):
        owner = run_sh_blocks[label].get("owner")
        if not _valid_owner(owner, valid_ids):
            violations.append(
                f"[arm3] coverage-map run_sh_blocks entry {label!r} owner {owner!r} is neither a registered test_modules id nor {UNMODULARIZED!r}"
            )

    return violations


def _git_tracked(repo_root: Path):
    """git-tracked repo-relative paths (index read; reads no history)."""
    result = subprocess.run(
        ["git", "-C", str(repo_root), "ls-files"],
        capture_output=True,
        text=True,
        check=True,
    )
    return [line for line in result.stdout.split("\n") if line]


def _load_json(path: Path):
    """Return (value, error). A read/parse failure returns (None, breadcrumb)."""
    try:
        return json.loads(path.read_text(encoding="utf-8")), None
    except FileNotFoundError:
        return None, f"{path} not found"
    except (OSError, UnicodeError) as error:
        return None, f"{path} unreadable ({error})"
    except json.JSONDecodeError as error:
        return None, f"{path} is malformed JSON ({error})"


def main(argv):
    repo_root = Path(argv[1]).resolve() if len(argv) > 1 else Path.cwd()
    tracked = _git_tracked(repo_root)
    map_value, map_error = _load_json(repo_root / MAP_REL)
    registry_value, registry_error = _load_json(repo_root / REGISTRY_REL)
    violations = evaluate(
        tracked,
        map_value,
        registry_value,
        map_read_error=map_error,
        registry_read_error=registry_error,
    )
    for line in violations:
        print(line)
    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
