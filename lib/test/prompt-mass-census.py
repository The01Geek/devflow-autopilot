#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Audit DevFlow's committed prompt-byte mirror and cutover artifacts."""

from __future__ import annotations

import argparse
from collections.abc import Mapping
import json
import os
from pathlib import Path, PurePosixPath
import sys
from typing import NoReturn


DEFAULT_MANIFEST = "lib/test/prompt-mass-manifest.json"
DEFAULT_BASELINE = "lib/test/prompt-mass-baseline.json"
PROCEDURE_POINTER = '.devflow/prompt-extensions/implement.md "Prose cutover"'
SWEEP_PATTERNS = (
    "skills/*/SKILL.md",
    "skills/*/phases/*.md",
    "skills/*/references/*.md",
    "agents/*.md",
    ".devflow/prompt-extensions/*.md",
    "CLAUDE.md",
)
GROUP_CLASSES = frozenset({"mandatory", "reference"})
ARTIFACT_KINDS = frozenset({"cutover", "trim", "growth", "relocate"})
SCHEMA_HEADINGS: dict[int, dict[str, tuple[str, ...]]] = {
    1: {
        "cutover": (
            "Files",
            "Consuming paths",
            "Branch coverage",
            "Grants and probes",
            "Shipping coupling",
            "Mutation evidence",
            "Pin disposition",
        ),
        "trim": ("Files", "Rationale", "Ownership"),
        "growth": ("Files", "Justification"),
        "relocate": ("Source rows", "Destinations"),
    }
}


class CensusError(Exception):
    """An attributable, fail-closed input error."""


def _fail(message: str) -> NoReturn:
    raise CensusError(message)


def _load_json(path: Path, label: str) -> object:
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        _fail(f"{label} {path}: not found")
    except (OSError, UnicodeError) as exc:
        _fail(f"{label} {path}: unreadable: {exc}")
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        _fail(f"{label} {path}: malformed JSON: {exc.msg}")


def _is_int(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _validate_relative_path(value: object, *, where: str) -> str:
    if not isinstance(value, str) or not value:
        _fail(f"{where}: path must be a non-empty string")
    pure = PurePosixPath(value)
    if pure.is_absolute() or ".." in pure.parts or "\\" in value:
        _fail(f"{where}: {value!r} must be a normalized repo-relative POSIX path")
    if value != pure.as_posix() or value.startswith("./"):
        _fail(f"{where}: {value!r} must be a normalized repo-relative POSIX path")
    return value


def _validate_version(value: object, *, label: str) -> None:
    if not _is_int(value) or value != 1:
        _fail(f"{label}: version must be the integer 1")


def _parse_manifest(raw: object, manifest_path: Path) -> dict[str, dict[str, object]]:
    if not isinstance(raw, Mapping):
        _fail(f"manifest {manifest_path}: manifest root must be an object")
    _validate_version(raw.get("version"), label=f"manifest {manifest_path}")
    classification = raw.get("classification_rule")
    if not isinstance(classification, str) or not classification.strip():
        _fail(
            f"manifest {manifest_path}: classification_rule must be a non-empty string"
        )
    groups = raw.get("groups")
    if not isinstance(groups, Mapping):
        _fail(f"manifest {manifest_path}: groups must be an object")

    parsed: dict[str, dict[str, object]] = {}
    for group_name, group in groups.items():
        if not isinstance(group_name, str) or not group_name:
            _fail(f"manifest {manifest_path}: group names must be non-empty strings")
        if not isinstance(group, Mapping):
            _fail(f"manifest {manifest_path}: group {group_name!r} must be an object")
        group_class = group.get("class")
        if group_class not in GROUP_CLASSES:
            _fail(
                f"manifest {manifest_path}: group {group_name!r} has unknown group "
                f"class {group_class!r}; expected mandatory or reference"
            )
        files = group.get("files")
        if not isinstance(files, list):
            _fail(
                f"manifest {manifest_path}: group {group_name!r} files must be an array"
            )
        parsed_files = [
            _validate_relative_path(
                value, where=f"manifest {manifest_path} group {group_name!r}"
            )
            for value in files
        ]
        if len(parsed_files) != len(set(parsed_files)):
            _fail(
                f"manifest {manifest_path}: group {group_name!r} lists a file more than once"
            )
        parsed[group_name] = {"class": group_class, "files": parsed_files}
    return parsed


def _parse_baseline(raw: object, baseline_path: Path) -> dict[str, int]:
    if not isinstance(raw, Mapping):
        _fail(f"baseline {baseline_path}: baseline root must be an object")
    _validate_version(raw.get("version"), label=f"baseline {baseline_path}")
    files = raw.get("files")
    if not isinstance(files, Mapping):
        _fail(f"baseline {baseline_path}: files must be an object")
    parsed: dict[str, int] = {}
    for raw_path, raw_bytes in files.items():
        relative = _validate_relative_path(
            raw_path, where=f"baseline {baseline_path} files"
        )
        if not _is_int(raw_bytes) or raw_bytes < 0:
            _fail(
                f"baseline {baseline_path}: byte value for {relative} must be a "
                "non-negative integer"
            )
        parsed[relative] = raw_bytes
    return parsed


def _manifest_files(groups: Mapping[str, Mapping[str, object]]) -> set[str]:
    return {
        relative
        for group in groups.values()
        for relative in group["files"]  # type: ignore[union-attr]
    }


def _measure_files(root: Path, files: set[str]) -> dict[str, int]:
    measured: dict[str, int] = {}
    resolved_root = root.resolve()
    for relative in sorted(files):
        path = root / relative
        try:
            resolved = path.resolve(strict=True)
        except FileNotFoundError:
            _fail(f"manifest-listed file is absent: {relative}")
        except OSError as exc:
            _fail(f"manifest-listed file is unreadable: {relative}: {exc}")
        if not resolved.is_relative_to(resolved_root):
            _fail(f"manifest-listed path escapes the repo root: {relative}")
        if not path.is_file():
            _fail(f"manifest-listed path is not a regular file: {relative}")
        try:
            measured[relative] = os.path.getsize(path)
        except OSError as exc:
            _fail(f"manifest-listed file is unreadable: {relative}: {exc}")
    return measured


def _swept_files(root: Path) -> set[str]:
    swept: set[str] = set()
    for pattern in SWEEP_PATTERNS:
        for path in root.glob(pattern):  # tree-walk-ok: pattern is a SWEEP_PATTERNS member; every pattern is prefix-scoped under skills/, agents/, .devflow/ or a bare filename
            if path.is_file():
                swept.add(path.relative_to(root).as_posix())
    return swept


def _validate_completeness(root: Path, measured_files: set[str]) -> None:
    missing = sorted(_swept_files(root) - measured_files)
    if missing:
        rendered = "\n  - ".join(missing)
        _fail(
            "manifest completeness failure: each path below matches sweep pattern "
            f"{', '.join(SWEEP_PATTERNS)} but appears in no declared group:\n  - "
            f"{rendered}"
        )


def _artifact_error(path: Path, defect: str, missing: tuple[str, ...] | None) -> NoReturn:
    if missing is None:
        missing_text = "unable to determine until schema and kind are valid"
    elif missing:
        missing_text = ", ".join(f"## {heading}" for heading in missing)
    else:
        missing_text = "none"
    _fail(
        f"cutover artifact {path}: {defect}; missing required headings: {missing_text}"
    )


def _parse_frontmatter(path: Path, text: str) -> tuple[int, str, list[str]]:
    lines = text.splitlines()
    if not lines or lines[0] != "---":
        _artifact_error(path, "frontmatter must start with ---", None)
    try:
        closing = lines.index("---", 1)
    except ValueError:
        _artifact_error(path, "frontmatter has no closing ---", None)
    values: dict[str, list[str]] = {}
    for line in lines[1:closing]:
        if not line.strip():
            continue
        if ":" not in line:
            _artifact_error(path, f"malformed frontmatter line {line!r}", None)
        key, value = line.split(":", 1)
        values.setdefault(key.strip(), []).append(value.strip())
    for key in ("schema", "kind"):
        count = len(values.get(key, []))
        if count != 1:
            _artifact_error(path, f"expected exactly one {key}: key, found {count}", None)
    unknown_keys = sorted(set(values) - {"schema", "kind"})
    if unknown_keys:
        _artifact_error(
            path,
            f"frontmatter has unknown keys: {', '.join(unknown_keys)}",
            None,
        )
    schema_text = values["schema"][0]
    try:
        schema = int(schema_text)
    except ValueError:
        _artifact_error(path, f"schema {schema_text!r} is not an integer", None)
    if str(schema) != schema_text or schema not in SCHEMA_HEADINGS:
        _artifact_error(path, f"unknown artifact schema {schema_text}", None)
    kind = values["kind"][0]
    if kind not in ARTIFACT_KINDS:
        _artifact_error(path, f"unknown artifact kind {kind!r}", None)
    return schema, kind, lines[closing + 1 :]


def _validate_artifact(path: Path) -> None:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        _artifact_error(path, f"unreadable: {exc}", None)
    schema, kind, body_lines = _parse_frontmatter(path, text)
    required = SCHEMA_HEADINGS[schema][kind]
    heading_positions: dict[str, list[int]] = {}
    for index, line in enumerate(body_lines):
        if line.startswith("## "):
            heading_positions.setdefault(line.removeprefix("## ").strip(), []).append(
                index
            )
    missing = tuple(heading for heading in required if heading not in heading_positions)
    if missing:
        _artifact_error(path, "required section heading is absent", missing)
    for heading in required:
        positions = heading_positions[heading]
        if len(positions) != 1:
            _artifact_error(
                path,
                f"required heading ## {heading} appears {len(positions)} times",
                (),
            )
        start = positions[0] + 1
        end = next(
            (
                index
                for index in range(start, len(body_lines))
                if body_lines[index].startswith("## ")
            ),
            len(body_lines),
        )
        if not any(
            line.strip() and not line.startswith("#") and line.strip() != "---"
            for line in body_lines[start:end]
        ):
            _artifact_error(path, f"section ## {heading} contains no evidence", ())


def _validate_artifacts(root: Path) -> None:
    artifact_dir = root / "docs/cutovers"
    if not artifact_dir.exists():
        return
    if not artifact_dir.is_dir():
        _fail(f"cutover artifact path {artifact_dir}: expected a directory")
    for path in sorted(artifact_dir.glob("*.md")):
        _validate_artifact(path)


def _baseline_json(measured: Mapping[str, int]) -> str:
    payload = {"version": 1, "files": dict(sorted(measured.items()))}
    return json.dumps(payload, indent=2, ensure_ascii=False) + "\n"


def _compare_baseline(
    baseline: Mapping[str, int], measured: Mapping[str, int]
) -> list[str]:
    failures: list[str] = []
    for relative in sorted(measured.keys() - baseline.keys()):
        failures.append(
            f"{relative}: baseline row missing (current {measured[relative]} bytes)"
        )
    for relative in sorted(baseline.keys() - measured.keys()):
        failures.append(
            f"{relative}: baseline row is no longer measured (recorded {baseline[relative]} bytes)"
        )
    for relative in sorted(measured.keys() & baseline.keys()):
        before = baseline[relative]
        after = measured[relative]
        if before == after:
            continue
        delta = after - before
        direction = "growth" if delta > 0 else "reduction"
        failures.append(
            f"{relative}: {direction} {delta:+d} bytes "
            f"(baseline {before}, current {after})"
        )
    return failures


def _render_group_totals(
    groups: Mapping[str, Mapping[str, object]], measured: Mapping[str, int]
) -> str:
    lines = ["prompt-mass census: exact baseline match"]
    for group_name, group in groups.items():
        total = sum(measured[relative] for relative in group["files"])  # type: ignore[union-attr]
        lines.append(f"{group_name} [{group['class']}]: {total} bytes")
    return "\n".join(lines)


def _path_from_root(root: Path, value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else root / path


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        default=str(Path(__file__).resolve().parents[2]),
        help="repository root (defaults to the checkout containing this script)",
    )
    parser.add_argument("--manifest", default=DEFAULT_MANIFEST)
    parser.add_argument("--baseline", default=DEFAULT_BASELINE)
    parser.add_argument(
        "--write-baseline",
        action="store_true",
        help="print canonical replacement baseline JSON without reading the old baseline",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    root = Path(args.root)
    if not root.is_dir():
        print(f"repository root {root}: not found or not a directory", file=sys.stderr)
        return 1
    manifest_path = _path_from_root(root, args.manifest)
    baseline_path = _path_from_root(root, args.baseline)
    try:
        groups = _parse_manifest(_load_json(manifest_path, "manifest"), manifest_path)
        files = _manifest_files(groups)
        measured = _measure_files(root, files)
        _validate_completeness(root, files)
        _validate_artifacts(root)
        replacement = _baseline_json(measured)
        if args.write_baseline:
            sys.stdout.write(replacement)
            return 0
        baseline = _parse_baseline(_load_json(baseline_path, "baseline"), baseline_path)
        failures = _compare_baseline(baseline, measured)
        if failures:
            print("prompt-mass census: committed baseline differs from the tree", file=sys.stderr)
            for failure in failures:
                print(f"  - {failure}", file=sys.stderr)
            print("exact replacement baseline rows (JSON):", file=sys.stderr)
            print(replacement, file=sys.stderr, end="")
            print(f"Remedy: follow {PROCEDURE_POINTER}.", file=sys.stderr)
            return 1
        print(_render_group_totals(groups, measured))
        return 0
    except CensusError as exc:
        print(f"prompt-mass census: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
