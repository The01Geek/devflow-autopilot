#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Run deterministic Phase 1 preflight checks for /devflow:implement.

The dependency subcommand owns the declared sequencing-dependency recognizer.
It prints one machine-readable outcome so the Phase 1 procedure can decide
before any branch setup begins.
"""

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import NoReturn


GH = os.environ.get("DEVFLOW_GH") or "gh"
DEPENDENCY_HEADING = re.compile(r"^##\s+Dependencies\s*$", re.IGNORECASE)
HEADING = re.compile(r"^#{1,6}\s+")
ISSUE_REF = re.compile(r"#(\d+)")
# Each declaration keyword may be followed by a run of additional numbers joined
# by "and"/",", so a single declaration can name several dependencies:
# `blocked by #10 and #11`, `depends on #1, #2`. The number run is captured by a
# uniform `re.findall(ISSUE_REF, match.group(0))` over the whole matched span
# rather than per-pattern capture groups (issue #547 Critical + Important #2) —
# so no declaration form silently drops all but its first number.
_NUMBER_RUN = r"#\d+(?:\s*(?:,|and)\s+#\d+)*"
DECLARATIONS = tuple(
    re.compile(rf"\b{keyword}\s+{_NUMBER_RUN}", re.IGNORECASE)
    for keyword in (r"depends on", r"must merge after", r"blocked by", r"follow-up to")
)
# The bare `after #N` form is the weakest declaration: `cleanup after #5 was
# merged` / `renamed after #5` are provenance, not sequencing dependencies
# (issue #547 Important #3). Anchor it to the start of the line/bullet so an
# incidental mid-sentence "after #N" no longer spuriously BLOCKs; a genuine
# free-prose declaration ("After #5 lands, …") opens its line, and the
# `## Dependencies` section scan below still catches an in-section `after #N`
# regardless of position.
AFTER_DECLARATION = re.compile(rf"^[ \t>*\-]*after\s+{_NUMBER_RUN}", re.IGNORECASE)
# Dependency-flavoured phrasings the fixed vocabulary does NOT recognize. When a
# `#N` sits next to one of these and no declaration matched the line, emit a
# stderr breadcrumb so a missed declaration is observable (issue #547 Important
# #6) — observability only, never a new BLOCK (the line still yields no number).
SOFT_KEYWORDS = re.compile(
    r"\b(?:requires|require|needs|need|waiting on|gated on|predicated on|"
    r"prerequisite|depends upon|built on top of|built upon|based on)\b",
    re.IGNORECASE,
)


def dependency_numbers(body: str) -> list[str]:
    """Return unique declared dependency numbers in source order."""
    found: list[str] = []

    def add(number: str) -> None:
        if number not in found:
            found.append(number)

    in_dependencies = False
    for line in body.splitlines():
        if DEPENDENCY_HEADING.match(line):
            in_dependencies = True
            continue
        if in_dependencies and HEADING.match(line):
            in_dependencies = False
        if in_dependencies:
            for number in ISSUE_REF.findall(line):
                add(number)
            continue
        # Accumulate every declaration match on the line (no early `break`): a
        # line can carry more than one declaration — `depends on #1, blocked by
        # #2` names both (issue #547 Important #2).
        spans = [m.group(0) for pattern in DECLARATIONS for m in pattern.finditer(line)]
        after_match = AFTER_DECLARATION.match(line)
        if after_match:
            spans.append(after_match.group(0))
        for span in spans:
            for number in ISSUE_REF.findall(span):
                add(number)
        if not spans and SOFT_KEYWORDS.search(line):
            for number in ISSUE_REF.findall(line):
                print(
                    f"preflight.py: unrecognized dependency-flavoured reference to "
                    f"#{number} — not a declared sequencing dependency; if it is one, "
                    f"restate it as `depends on #{number}` / `blocked by #{number}` "
                    f"or list it under a `## Dependencies` section",
                    file=sys.stderr,
                )
    return found


def _gh_issue_view(number: object, field: str) -> str:
    """Run `gh issue view <number> --json <field> -q .<field>` and return stdout.

    encoding="utf-8" so non-ASCII issue bodies decode; the caller owns the error
    policy (issue_body raises, issue_state swallows).
    """
    result = subprocess.run(
        [GH, "issue", "view", str(number), "--json", field, "-q", f".{field}"],
        check=True,
        capture_output=True,
        encoding="utf-8",
    )
    return result.stdout


def issue_body(issue: int) -> str:
    try:
        return _gh_issue_view(issue, "body")
    except (OSError, subprocess.CalledProcessError) as exc:
        detail = exc.stderr.strip() if isinstance(exc, subprocess.CalledProcessError) else str(exc)
        raise RuntimeError(f"could not read issue body: {detail}") from exc


def issue_state(number: str) -> str | None:
    try:
        state = _gh_issue_view(number, "state").strip()
    except (OSError, subprocess.CalledProcessError):
        return None
    return state if state in {"OPEN", "CLOSED", "MERGED"} else None


def dependencies(args: argparse.Namespace) -> int:
    if args.body_file:
        try:
            body = Path(args.body_file).read_text(encoding="utf-8")
        except OSError as exc:
            print(f"preflight.py: could not read dependency body: {exc}", file=sys.stderr)
            print("UNAVAILABLE body", flush=True)
            return 3
    else:
        try:
            body = issue_body(args.issue)
        except RuntimeError as exc:
            print(f"preflight.py: {exc}", file=sys.stderr)
            print("UNAVAILABLE issue", flush=True)
            return 3

    numbers = dependency_numbers(body)
    if not numbers:
        print("PROCEED")
        return 0

    open_numbers: list[str] = []
    for number in numbers:
        state = issue_state(number)
        if state is None:
            print(f"preflight.py: could not resolve declared dependency #{number}", file=sys.stderr)
            print(f"UNAVAILABLE {number}")
            return 3
        if state == "OPEN":
            open_numbers.append(number)

    if open_numbers:
        print(f"BLOCKED {','.join(open_numbers)}")
        return 2

    print(f"PROCEED {','.join(numbers)}")
    return 0


class _Parser(argparse.ArgumentParser):
    """Exit usage errors with code 3, not argparse's default 2.

    Exit 2 is the `BLOCKED` contract code the Phase 1 §1.3.5 gate maps to "named
    dependencies are still open". A malformed invocation (bad/empty --issue,
    neither input flag) must not masquerade as that verdict — it is an
    unestablished measurement, so route it to the UNAVAILABLE class (exit 3).
    """

    def error(self, message: str) -> NoReturn:
        self.print_usage(sys.stderr)
        self.exit(3, f"{self.prog}: error: {message}\n")


def main() -> int:
    parser = _Parser(description=__doc__)
    # Make the exit-3 (UNAVAILABLE) contract explicit rather than relying on
    # add_subparsers() defaulting parser_class to type(self): the subparser is
    # what raises `--issue notanint` / both-flags usage errors, so its exit code
    # must route through _Parser.error() → exit 3, not argparse's default 2
    # (which is the BLOCKED contract code). Issue #547 Important #5.
    subparsers = parser.add_subparsers(dest="command", required=True, parser_class=_Parser)
    dependency_parser = subparsers.add_parser("dependencies")
    input_group = dependency_parser.add_mutually_exclusive_group(required=True)
    input_group.add_argument("--issue", type=int)
    input_group.add_argument("--body-file")
    dependency_parser.set_defaults(func=dependencies)
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
