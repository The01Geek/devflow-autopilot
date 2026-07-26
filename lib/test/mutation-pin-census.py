#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Build an opaque census of legacy generic mutation-pin calls.

The census deliberately treats every call as text.  It never executes or
interprets a mutation, resolves a target, or attempts semantic classification.
"""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path


HELPERS = ("assert_pin_red_under", "devflow_module_pin_red_under")
EXPECTED_SOURCE_COUNT = 12
_WORD = r"[A-Za-z_][A-Za-z0-9_]*"
_DEFINITION_RE = {
    helper: re.compile(rf"^\s*{helper}\s*\(\s*\)\s*\{{")
    for helper in HELPERS
}
_DIRECT_CALL_RE = re.compile(
    rf"^\s*(?:(?:{_WORD})=(?:'(?:[^']*)'|\"(?:\\.|[^\"])*\"|\S+)\s+)*"
    rf"(?P<helper>{'|'.join(HELPERS)})(?=\s|$)"
)
_LEXICAL_CALL_RE = re.compile(
    rf"^\s*(?:(?:{_WORD})=(?:'(?:[^']*)'|\"(?:\\.|[^\"])*\"|\S+)\s+)*"
    rf"(?:command\s+)?(?P<helper>{'|'.join(HELPERS)})(?=\s|$)"
)


class CensusError(RuntimeError):
    """The census population could not be established reliably."""


@dataclass(frozen=True)
class CensusRow:
    path: str
    helper: str
    logical_call: str
    line_start: int
    line_end: int

    @property
    def identity(self) -> str:
        """Opaque identity; source locations are intentionally not included."""
        return json.dumps(
            [self.path, self.helper, self.logical_call],
            ensure_ascii=False,
            separators=(",", ":"),
        )


@dataclass(frozen=True)
class CensusResult:
    sources: tuple[str, ...]
    rows: tuple[CensusRow, ...]
    master_sha256: str

    def helper_count(self, helper: str) -> int:
        return sum(row.helper == helper for row in self.rows)

    def identity_bytes(self) -> bytes:
        if not self.rows:
            return b""
        return ("".join(f"{row.identity}\n" for row in self.rows)).encode("utf-8")


@dataclass(frozen=True)
class _LogicalLine:
    text: str
    line_start: int
    line_end: int


def _read_utf8(path: Path, description: str) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError as exc:
        raise CensusError(f"missing {description}: {path}") from exc
    except UnicodeDecodeError as exc:
        raise CensusError(f"{description} is not valid UTF-8: {path}") from exc
    except OSError as exc:
        raise CensusError(f"cannot read {description}: {path}: {exc}") from exc


def _audited_sources(repo_root: Path) -> tuple[str, ...]:
    linter = repo_root / "lib/test/pin-corpus-lint.py"
    text = _read_utf8(linter, "pin-corpus linter")
    try:
        tree = ast.parse(text, filename=str(linter))
    except SyntaxError as exc:
        raise CensusError(f"cannot parse AUDITED_PIN_SOURCES: {exc}") from exc

    values: list[ast.expr] = []
    for node in tree.body:
        if not isinstance(node, (ast.Assign, ast.AnnAssign)):
            continue
        targets = node.targets if isinstance(node, ast.Assign) else [node.target]
        if not any(
            isinstance(target, ast.Name) and target.id == "AUDITED_PIN_SOURCES"
            for target in targets
        ):
            continue
        value = node.value
        if value is not None:
            values.append(value)
    if len(values) != 1:
        raise CensusError(
            "AUDITED_PIN_SOURCES must have exactly one top-level definition"
        )

    value = values[0]
    if not (
        isinstance(value, ast.Call)
        and isinstance(value.func, ast.Name)
        and value.func.id == "frozenset"
        and len(value.args) == 1
        and not value.keywords
    ):
        raise CensusError("AUDITED_PIN_SOURCES must be a literal frozenset")
    literal = value.args[0]
    if not isinstance(literal, ast.Set):
        raise CensusError("AUDITED_PIN_SOURCES is not a literal string set")
    entries = tuple(
        element.value
        for element in literal.elts
        if isinstance(element, ast.Constant)
        and isinstance(element.value, str)
        and element.value
    )
    if len(entries) != len(literal.elts):
        raise CensusError("AUDITED_PIN_SOURCES is not a literal string set")
    if len(entries) != len(set(entries)):
        raise CensusError("duplicate audited population entry")
    if len(entries) != EXPECTED_SOURCE_COUNT:
        raise CensusError(
            "audited population count disagreement: "
            f"expected {EXPECTED_SOURCE_COUNT}, found {len(entries)}"
        )
    return tuple(sorted(entries))


def _logical_lines(text: str, path: str) -> tuple[_LogicalLine, ...]:
    physical = text.splitlines()
    output: list[_LogicalLine] = []
    index = 0
    while index < len(physical):
        start = index + 1
        pieces: list[str] = []
        while True:
            line = physical[index]
            trailing = len(line) - len(line.rstrip("\\"))
            continued = trailing % 2 == 1
            pieces.append(line[:-1] if continued else line)
            if not continued:
                break
            index += 1
            if index >= len(physical):
                raise CensusError(
                    f"unterminated continuation in {path}:{start}"
                )
        normalized = " ".join(piece.strip() for piece in pieces)
        output.append(_LogicalLine(normalized, start, index + 1))
        index += 1
    return tuple(output)


def _shell_segments(text: str) -> tuple[str, ...]:
    """Split an already joined line at unquoted shell command separators."""
    segments: list[str] = []
    start = 0
    quote: str | None = None
    escaped = False
    index = 0
    while index < len(text):
        char = text[index]
        if quote == "'":
            if char == "'":
                quote = None
            index += 1
            continue
        if quote == '"':
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quote = None
            index += 1
            continue
        if escaped:
            escaped = False
            index += 1
            continue
        if char == "\\":
            escaped = True
            index += 1
            continue
        if char in {"'", '"'}:
            quote = char
            index += 1
            continue
        if char == "#":
            if index == 0 or text[index - 1].isspace():
                text = text[:index]
                break
        separator_length = 0
        if char == ";":
            separator_length = 1
        elif char == "|":
            separator_length = 2 if text[index : index + 2] == "||" else 1
        elif char == "&" and text[index : index + 2] == "&&":
            separator_length = 2
        if separator_length:
            segments.append(text[start:index])
            index += separator_length
            start = index
            continue
        index += 1
    segments.append(text[start:])
    return tuple(segment.strip() for segment in segments if segment.strip())


def _definition_counts(repo_root: Path) -> dict[str, int]:
    counts = dict.fromkeys(HELPERS, 0)
    test_root = repo_root / "lib/test"
    try:
        paths = sorted(test_root.rglob("*.sh"))
    except OSError as exc:
        raise CensusError(f"cannot enumerate helper definitions: {exc}") from exc
    for path in paths:
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            # Binary/adversarial fixtures under lib/test are not shell sources.
            continue
        except OSError as exc:
            raise CensusError(f"cannot read test shell source: {path}: {exc}") from exc
        relative = path.relative_to(repo_root).as_posix()
        for logical in _logical_lines(text, relative):
            for segment in _shell_segments(logical.text):
                for helper, pattern in _DEFINITION_RE.items():
                    if pattern.match(segment):
                        counts[helper] += 1
    return counts


def _extract_source(repo_root: Path, source: str) -> tuple[CensusRow, ...]:
    path = repo_root / source
    text = _read_utf8(path, "audited source")
    rows: list[CensusRow] = []
    for logical in _logical_lines(text, source):
        lexical = 0
        extracted: list[CensusRow] = []
        for segment in _shell_segments(logical.text):
            if any(pattern.match(segment) for pattern in _DEFINITION_RE.values()):
                continue
            lexical_match = _LEXICAL_CALL_RE.match(segment)
            if lexical_match:
                lexical += 1
            direct_match = _DIRECT_CALL_RE.match(segment)
            if not direct_match:
                continue
            helper = direct_match.group("helper")
            call_start = direct_match.start("helper")
            extracted.append(
                CensusRow(
                    path=source,
                    helper=helper,
                    logical_call=segment[call_start:].strip(),
                    line_start=logical.line_start,
                    line_end=logical.line_end,
                )
            )
        if len(extracted) > 1:
            raise CensusError(
                f"multiple supported calls on one logical line: "
                f"{source}:{logical.line_start}"
            )
        if lexical != len(extracted):
            raise CensusError(
                f"lexical/extracted population disagreement at "
                f"{source}:{logical.line_start}: lexical={lexical}, "
                f"extracted={len(extracted)}"
            )
        rows.extend(extracted)
    return tuple(rows)


def build_census(repo_root: Path | str) -> CensusResult:
    root = Path(repo_root).resolve()
    sources = _audited_sources(root)
    for source in sources:
        if not (root / source).is_file():
            raise CensusError(f"missing audited source: {source}")

    definition_counts = _definition_counts(root)
    unexpected = {
        helper: count for helper, count in definition_counts.items() if count != 1
    }
    if unexpected:
        details = ", ".join(
            f"{helper}={count}" for helper, count in sorted(unexpected.items())
        )
        raise CensusError(
            f"unexpected helper definition count (expected exactly one each): {details}"
        )

    rows = sorted(
        (
            row
            for source in sources
            for row in _extract_source(root, source)
        ),
        key=lambda row: row.identity,
    )
    identities = [row.identity for row in rows]
    duplicate = next(
        (
            identity
            for index, identity in enumerate(identities[1:], start=1)
            if identity == identities[index - 1]
        ),
        None,
    )
    if duplicate is not None:
        raise CensusError(f"duplicate identity: {duplicate}")

    provisional = CensusResult(sources=sources, rows=tuple(rows), master_sha256="")
    digest = hashlib.sha256(provisional.identity_bytes()).hexdigest()
    return CensusResult(
        sources=sources,
        rows=tuple(rows),
        master_sha256=digest,
    )


def render_jsonl(result: CensusResult) -> str:
    lines = [
        json.dumps(
            {
                "path": row.path,
                "helper": row.helper,
                "logical_call": row.logical_call,
                "line_start": row.line_start,
                "line_end": row.line_end,
                "identity_sha256": hashlib.sha256(
                    row.identity.encode("utf-8")
                ).hexdigest(),
            },
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        for row in result.rows
    ]
    lines.append(
        json.dumps(
            {"master_sha256": result.master_sha256},
            sort_keys=True,
            separators=(",", ":"),
        )
    )
    return "\n".join(lines) + "\n"


def render_tsv(result: CensusResult) -> str:
    lines = [
        "path\thelper\tlogical_call\tline_start\tline_end\tidentity_sha256"
    ]
    for row in result.rows:
        call = json.dumps(row.logical_call, ensure_ascii=False)
        identity_digest = hashlib.sha256(row.identity.encode("utf-8")).hexdigest()
        lines.append(
            f"{row.path}\t{row.helper}\t{call}\t{row.line_start}\t"
            f"{row.line_end}\t{identity_digest}"
        )
    lines.append(f"# master_sha256\t{result.master_sha256}")
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path("."))
    parser.add_argument("--format", choices=("jsonl", "tsv"), default="jsonl")
    args = parser.parse_args(argv)
    try:
        result = build_census(args.repo_root)
    except CensusError as exc:
        print(f"mutation-pin-census: infrastructure failure: {exc}", file=sys.stderr)
        return 2
    output = render_jsonl(result) if args.format == "jsonl" else render_tsv(result)
    sys.stdout.write(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
