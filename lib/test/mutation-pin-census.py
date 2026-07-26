#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Build an opaque census of legacy mutation-pin calls.

The census deliberately treats every call as text.  It never executes or
interprets a mutation, resolves a target, or attempts semantic classification.
"""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


HELPERS = (
    "assert_pin_red_under",
    "devflow_module_pin_red_under",
    "assert_count_red_under",
    "_ra_conflict_red_under",
)
GENERIC_HELPERS = frozenset(
    {"assert_pin_red_under", "devflow_module_pin_red_under"}
)
HELPER_INFRASTRUCTURE_BOUNDARY_IDENTITIES = frozenset(
    {
        "1f259de9a0422496fc20644eb0076768593e5e550b2ceba58426abfe15efde6e",
        "22b65906375a646b8097e5841c1164d84935e0ba443ea027d8a64439bce86b09",
        "3a2939778279bc8795054a9ba4f621d35269448d24e86b23327b30e694ff8a2b",
        "84c69a5462a0cc22d3b0dfd9a4cbd938c997b3fcb64298a1167dba2457ec992b",
        "e84f0528067b424dd327ac1360f7cedf8da6b7ebe5c033d88456ce1329517800",
        "eb7c051b48605c0c70d903dbd87b484135d214e2372353e70f480b8a93455781",
        "f700b7cc0f0c52b2708f2145a229450da40bc64371bec5cbd8c0ba40c37a584c",
    }
)
EXECUTABLE_BOUNDARY_IDENTITIES = frozenset(
    {
        "2d8275d45a27368198dead82dff33049279641d0dfb11b97c711301137f94c71",
        "6493953617fbc0748f1d528a769129bddd706736871213498c218671d0bdab30",
        "773c694960dc8b3d0157098b277e5ce69e70b8e298ddb2ed7afa194a9114a136",
        "9a3ff928b4ef3fb130d1b4b93584de8137b3fa6869366829c2b6b1499587341b",
        "b6306602df7f51703c351ef1681e955ec00435629532ea9df2bbbfeaa7bd0433",
        "bf9fad8a7a3e1f7eabfef637531c647c877bd442ff8d033d0f0c0e3cc73a97b2",
        "cd000a5735a98dab2d7cf4af6167a823ab55b8bd1649ba99f7f18ebcd95fbdcd",
        "e1b06d78765f7b4af817de611bcadebbaa2868a5ae41d9c83038bb5e8af9fd5f",
    }
)
RETAINED_BOUNDARY_IDENTITIES = (
    HELPER_INFRASTRUCTURE_BOUNDARY_IDENTITIES
    | EXECUTABLE_BOUNDARY_IDENTITIES
)
EXPECTED_SOURCE_COUNT = 12
_WORD = r"[A-Za-z_][A-Za-z0-9_]*"
_DEFINITION_RE = {
    helper: re.compile(rf"^\s*{helper}\s*\(\s*\)\s*\{{")
    for helper in HELPERS
}
_ASSIGNMENT = rf"(?:{_WORD})=(?:'(?:[^']*)'|\"(?:\\.|[^\"])*\"|\S+)"
_REDIRECTION = r"[0-9]*(?:<>|>>|>|<<|<)\S*"
_DIRECT_CALL_RE = re.compile(
    rf"^\s*(?:(?:{_ASSIGNMENT}|{_REDIRECTION})\s+)*"
    rf"(?P<helper>{'|'.join(HELPERS)})(?=\s|$)"
)
_PROBE_CALL_RE = re.compile(
    rf"^\s*(?:probe_assert|_acru_probe|probe_two_line)\s+"
    rf"(?P<helper>{'|'.join(HELPERS)})(?=\s|$)"
)
_SHELL_TOKEN_RE = re.compile(r"&&|\|\||;;|[;|&(){}!]|[^\s;|&(){}!]+")


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
class Adjudication:
    disposition: str
    rationale: str


@dataclass(frozen=True)
class _LogicalLine:
    text: str
    physical: str
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
        output.append(
            _LogicalLine(
                normalized,
                "\n".join(physical[start - 1 : index + 1]),
                start,
                index + 1,
            )
        )
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
    return tuple(segment for segment in segments if segment.strip())


def _unquoted_shell_tokens(segment: str) -> tuple[str, ...]:
    visible: list[str] = []
    quote: str | None = None
    escaped = False
    index = 0
    while index < len(segment):
        char = segment[index]
        if quote == "'":
            visible.append(" ")
            if char == "'":
                quote = None
            index += 1
            continue
        if quote == '"':
            visible.append(" ")
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quote = None
            index += 1
            continue
        if escaped:
            visible.append(" ")
            escaped = False
            index += 1
            continue
        if char == "\\":
            visible.append(" ")
            escaped = True
            index += 1
            continue
        if char in {"'", '"'}:
            visible.append(" ")
            quote = char
            index += 1
            continue
        if char == "#" and (index == 0 or segment[index - 1].isspace()):
            break
        visible.append(char)
        index += 1
    return tuple(_SHELL_TOKEN_RE.findall("".join(visible)))


def _lexical_helper_count(segment: str) -> int:
    return sum(token in HELPERS for token in _unquoted_shell_tokens(segment))


def _definition_counts(repo_root: Path) -> dict[str, int]:
    counts = dict.fromkeys(HELPERS, 0)
    try:
        result = subprocess.run(
            ["git", "ls-files", "-z", "--", "lib/test"],
            cwd=repo_root,
            capture_output=True,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise CensusError(
            f"cannot enumerate tracked helper definitions: {exc}"
        ) from exc
    if result.returncode != 0:
        stderr = (
            result.stderr.decode("utf-8", errors="replace")
            if isinstance(result.stderr, bytes)
            else result.stderr
        ).strip()
        raise CensusError(
            "tracked helper-definition enumeration failed "
            f"(exit {result.returncode}): {stderr or '(no stderr)'}"
        )
    if not result.stdout or not result.stdout.endswith(b"\0"):
        raise CensusError(
            "tracked helper-definition enumeration is empty or malformed"
        )
    raw_paths = result.stdout[:-1].split(b"\0")
    try:
        relative_paths = [raw.decode("utf-8") for raw in raw_paths]
    except UnicodeDecodeError as exc:
        raise CensusError(
            "tracked helper-definition path is not valid UTF-8"
        ) from exc
    if (
        any(not path or "\0" in path for path in relative_paths)
        or len(relative_paths) != len(set(relative_paths))
    ):
        raise CensusError(
            "tracked helper-definition enumeration contains malformed or "
            "duplicate paths"
        )
    paths = [
        repo_root / relative
        for relative in sorted(relative_paths)
        if relative.startswith("lib/test/") and relative.endswith(".sh")
    ]
    if not paths:
        raise CensusError(
            "tracked helper-definition enumeration selected no shell sources"
        )
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
            for segment in _shell_segments(logical.physical):
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
        for segment in _shell_segments(logical.physical):
            if any(pattern.match(segment) for pattern in _DEFINITION_RE.values()):
                continue
            segment_lexical = _lexical_helper_count(segment)
            lexical += segment_lexical
            direct_match = _DIRECT_CALL_RE.match(segment) or _PROBE_CALL_RE.match(
                segment
            )
            if not direct_match or segment_lexical == 0:
                continue
            helper = direct_match.group("helper")
            extracted.append(
                CensusRow(
                    path=source,
                    helper=helper,
                    logical_call=segment,
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


def _identity_sha256(row: CensusRow) -> str:
    return hashlib.sha256(row.identity.encode("utf-8")).hexdigest()


def adjudicate(row: CensusRow) -> Adjudication:
    identity_sha256 = _identity_sha256(row)
    if identity_sha256 in HELPER_INFRASTRUCTURE_BOUNDARY_IDENTITIES:
        return Adjudication(
            "retain_helper_infrastructure_boundary",
            "outer executable assertion verifies helper failure diagnostics",
        )
    if identity_sha256 in EXECUTABLE_BOUNDARY_IDENTITIES:
        return Adjudication(
            "retain_executable_boundary",
            "purpose-built helper observes mutated behavior",
        )
    if row.helper in GENERIC_HELPERS:
        return Adjudication(
            "retire_presence_equivalent",
            "generic helper observes only pinned-literal cardinality in scratch copy",
        )
    return Adjudication(
        "reject_unadjudicated_mutation_site",
        "mutation-taking call is not an explicitly retained boundary",
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
                "identity_sha256": _identity_sha256(row),
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


def _validate_source_revision(source_revision: str) -> None:
    if not re.fullmatch(r"[0-9a-f]{40,64}", source_revision):
        raise CensusError("source revision must be a full hexadecimal object ID")


def render_tsv(
    result: CensusResult, source_revision: str | None = None
) -> str:
    lines: list[str] = []
    if source_revision is not None:
        _validate_source_revision(source_revision)
        lines.append(f"# source_revision\t{source_revision}")
    lines.append(
        "path\thelper\tlogical_call\tline_start\tline_end\tidentity_sha256"
    )
    for row in result.rows:
        call = json.dumps(row.logical_call, ensure_ascii=False)
        identity_digest = _identity_sha256(row)
        lines.append(
            f"{row.path}\t{row.helper}\t{call}\t{row.line_start}\t"
            f"{row.line_end}\t{identity_digest}"
        )
    lines.append(f"# master_sha256\t{result.master_sha256}")
    return "\n".join(lines) + "\n"


def render_adjudication_tsv(
    result: CensusResult, source_revision: str
) -> str:
    _validate_source_revision(source_revision)
    lines = [
        f"# source_revision\t{source_revision}",
        f"# master_sha256\t{result.master_sha256}",
        (
            "path\thelper\tlogical_call\tline_start\tline_end\t"
            "identity_sha256\tdisposition\trationale"
        ),
    ]
    for row in result.rows:
        decision = adjudicate(row)
        lines.append(
            f"{row.path}\t{row.helper}\t"
            f"{json.dumps(row.logical_call, ensure_ascii=False)}\t"
            f"{row.line_start}\t{row.line_end}\t{_identity_sha256(row)}\t"
            f"{decision.disposition}\t{decision.rationale}"
        )
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path("."))
    parser.add_argument(
        "--format",
        choices=("jsonl", "tsv", "adjudication-tsv"),
        default="jsonl",
    )
    parser.add_argument("--source-revision")
    args = parser.parse_args(argv)
    try:
        result = build_census(args.repo_root)
        if args.format == "adjudication-tsv" and not args.source_revision:
            raise CensusError(
                "adjudication-tsv requires --source-revision"
            )
    except CensusError as exc:
        print(f"mutation-pin-census: infrastructure failure: {exc}", file=sys.stderr)
        return 2
    if args.format == "jsonl":
        output = render_jsonl(result)
    elif args.format == "tsv":
        output = render_tsv(result, args.source_revision)
    else:
        output = render_adjudication_tsv(result, args.source_revision)
    sys.stdout.write(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
