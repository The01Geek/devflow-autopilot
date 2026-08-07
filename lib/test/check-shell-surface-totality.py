#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Totality checker for `lib/shell-surface-registry.json` (issue #1277).

The macOS Bash 3.2 lane runs a *selected* portable surface, and a selection is only
as trustworthy as the population it selects from. So the registry is not allowed to
be a hand-maintained subset: this checker derives the repository's shipped shell
entry-point population **independently** — from the git index, never from the
registry — and fails when the two disagree in any direction.

Derivation
----------
The population is `git ls-files '*.sh'` read through
`lib/test/lint_population.LS_FILES_INDEX` (the shared index-reading argv, issue
#724/#711/#1217), minus the single declared exempt prefix `lib/test/fixtures/`,
whose contents are adversarial inputs to other tests rather than shipped shell.
Naming that argv is what states the index-read choice: a working-tree read would
sweep sibling worktrees under `.claude/worktrees/` and make this check's verdict
vary between runs on the same commit.

Failure classes (each reported with its offenders, not just the first)
---------------------------------------------------------------------
* **unclassified**       — a derived path the registry does not classify at all.
* **missing-tracked**    — a registry key naming a path the index no longer tracks.
* **duplicate**          — the same path declared twice in the registry source text.
* **unknown-state**      — a `state` outside the closed set {portable, excluded}.
* **stale-dependency**   — a portable entry's `shared_library_closure` names a path
  that is not in the registry, or names one that is `excluded` (a portable entry
  cannot source Bash-4-only infrastructure and still run under Bash 3.2).
* **glob-leakage**       — a registry key carrying a glob metacharacter. Keys are
  literal paths only: a pattern key that matched the excluded Bash-4 infrastructure
  would also silently swallow a future portable file added beside it, and that file
  would then never be verified while the registry still read as total.
* **schema**             — a wrong `schema_version`, a missing required field for the
  entry's state, or an empty `reason` on an exclusion.

Fail-closed contract
--------------------
This is a best-effort reader of a human-maintained JSON file, so every shape it
cannot interpret — unreadable/empty/non-JSON registry, a non-object `entries`, an
unusable enumeration — exits 1 rather than reporting coverage from whatever parsed.
A red checker forces human attention; a green one on unreadable input would be a
false clean over exactly the artifact that decides what gets verified.

KNOWN LIMITATIONS. (1) `state` is checked against the closed set and required fields
are checked for presence, but the *truth* of a record is not re-derived: this checker
does not re-scan a file's source to confirm its declared `min_bash`, nor that a
declared closure is complete. A record claiming `portable` for a file that in fact
uses a Bash-4 construct is caught by the lane actually running it under Bash 3.2, not
here. (2) The exempt prefix is a single literal (`lib/test/fixtures/`); a new exempt
subtree is a deliberate edit here, which is the intended friction.

Exit 0 = the registry is total and internally consistent (`OK` on stdout).
Exit 1 = a fail-closed condition or a violation (`FAIL: <class>` on stdout, offenders
on stderr).
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import re
import sys
from pathlib import Path

TOOL = "check-shell-surface-totality"

#: Registry keys are literal paths. Any of these characters makes a key a pattern.
GLOB_METACHARACTERS = "*?[]"

#: The single declared exempt prefix — adversarial fixtures, not shipped shell.
EXEMPT_PREFIX = "lib/test/fixtures/"

#: The complete state set. There is no third state, and no "unknown" fallback.
STATES = ("portable", "excluded")

REQUIRED_FIELDS = {
    "portable": ("min_bash", "shared_library_closure", "fixture_command", "owning_test_module"),
    "excluded": ("min_bash", "reason"),
}

SCHEMA_VERSION = 1


def _load_population_reader():
    """Load `lib/test/lint_population.py` by path, the idiom this directory uses."""
    module_path = Path(__file__).resolve().parent / "lint_population.py"
    spec = importlib.util.spec_from_file_location("_ssr_lint_population", module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load the shared population reader at {module_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _fail(reason: str, offenders=()) -> int:
    print(f"FAIL: {reason}")
    for line in offenders:
        print(f"  {line}", file=sys.stderr)
    return 1


def _duplicate_keys(text: str) -> list[str]:
    """Return keys declared more than once in the registry's `entries` object.

    `json.loads` keeps the last of a duplicated key, so a duplicate is invisible after
    parsing — it has to be found in the source text. The scan is deliberately literal
    (a quoted key followed by a colon at the object's indent) rather than a full JSON
    tokenizer: the registry is generated and reformatted by this repository's own
    tooling, so its shape is stable, and a shape this scan cannot read is reported as
    a fail-closed schema error by the parse step above it rather than silently.
    """
    seen: dict[str, int] = {}
    for match in re.finditer(r'^\s{4}"((?:[^"\\]|\\.)*)"\s*:', text, re.MULTILINE):
        key = match.group(1)
        seen[key] = seen.get(key, 0) + 1
    return sorted(k for k, n in seen.items() if n > 1)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Reconcile the shell-surface registry against the tracked tree.")
    parser.add_argument("--list-portable", action="store_true",
                        help="on success, print the portable population one path per line instead of OK")
    population = _load_population_reader()
    population.add_population_arguments(parser)
    args = parser.parse_args(argv)

    root = population.resolve_root(args.root, tool=TOOL)
    registry_path = root / "lib" / "shell-surface-registry.json"

    try:
        raw = registry_path.read_text(encoding="utf-8")
    except OSError as exc:
        return _fail(f"the registry could not be read ({registry_path}): {exc}")
    if not raw.strip():
        return _fail(f"the registry is empty ({registry_path})")
    try:
        document = json.loads(raw)
    except json.JSONDecodeError as exc:
        return _fail(f"the registry is not valid JSON ({registry_path}): {exc}")
    if not isinstance(document, dict):
        return _fail("the registry's top level is not a JSON object")
    if document.get("schema_version") != SCHEMA_VERSION:
        return _fail(
            f"unsupported schema_version {document.get('schema_version')!r} "
            f"(this checker understands {SCHEMA_VERSION})"
        )
    entries = document.get("entries")
    if not isinstance(entries, dict):
        return _fail("the registry has no `entries` object")

    duplicates = _duplicate_keys(raw)
    if duplicates:
        return _fail("duplicate: a path is declared more than once", duplicates)

    globbed = sorted(k for k in entries if any(c in k for c in GLOB_METACHARACTERS))
    if globbed:
        return _fail(
            "glob-leakage: registry keys are literal paths, but these carry a glob "
            "metacharacter — a pattern key silently swallows a future file added beside it",
            globbed,
        )

    # Schema and state, before any reconciliation: an entry whose shape is unusable
    # cannot be reconciled against anything.
    schema_problems: list[str] = []
    unknown_state: list[str] = []
    for path, record in sorted(entries.items()):
        if not isinstance(record, dict):
            schema_problems.append(f"{path}: record is not an object")
            continue
        state = record.get("state")
        if state not in STATES:
            unknown_state.append(f"{path}: state={state!r} (the complete set is {list(STATES)})")
            continue
        for field in REQUIRED_FIELDS[state]:
            if field not in record:
                schema_problems.append(f"{path}: {state} record is missing required field `{field}`")
        if state == "excluded" and not str(record.get("reason", "")).strip():
            schema_problems.append(f"{path}: exclusion carries an empty reason")
        if state == "portable" and not isinstance(record.get("shared_library_closure"), list):
            schema_problems.append(f"{path}: shared_library_closure is not a list")
    if unknown_state:
        return _fail("unknown-state: a state outside the complete set", unknown_state)
    if schema_problems:
        return _fail("schema: a record is missing or malforming a required field", schema_problems)

    try:
        tracked = population.enumerate_population(
            root, Path(args.files_from) if args.files_from else None,
            ls_files_argv=(*population.LS_FILES_INDEX, "*.sh"),
        )
    except population.EnumerationError as exc:
        return _fail(f"the shipped shell population could not be enumerated: {exc}")

    derived = {p for p in tracked if p.endswith(".sh") and not p.startswith(EXEMPT_PREFIX)}

    unclassified = sorted(derived - set(entries))
    if unclassified:
        return _fail(
            "unclassified: a tracked shell entry point the registry does not classify",
            unclassified,
        )

    missing = sorted(set(entries) - derived)
    if missing:
        return _fail(
            "missing-tracked: a registry key naming a path the index no longer tracks "
            "(or one under the exempt fixtures prefix)",
            missing,
        )

    stale: list[str] = []
    for path, record in sorted(entries.items()):
        if record["state"] != "portable":
            continue
        for dependency in record["shared_library_closure"]:
            target = entries.get(dependency)
            if target is None:
                stale.append(f"{path}: closure names {dependency}, which the registry does not classify")
            elif target["state"] == "excluded":
                stale.append(
                    f"{path}: closure names {dependency}, which is excluded "
                    f"({target.get('min_bash')}) — a portable entry cannot source Bash-4-only infrastructure"
                )
    if stale:
        return _fail("stale-dependency: a portable entry's declared closure does not resolve portably", stale)

    portable = sorted(p for p, r in entries.items() if r["state"] == "portable")
    if args.list_portable:
        for path in portable:
            print(path)
        return 0
    print(f"OK: {len(entries)} classified ({len(portable)} portable, "
          f"{len(entries) - len(portable)} excluded); population totals")
    return 0


if __name__ == "__main__":
    sys.exit(main())
