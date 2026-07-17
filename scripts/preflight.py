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
DECLARATIONS = (
    re.compile(r"\bdepends on\s+#(\d+)(?:\s+and\s+#(\d+))?\b", re.IGNORECASE),
    re.compile(r"\bmust merge after\s+#(\d+)\b", re.IGNORECASE),
    re.compile(r"\bblocked by\s+#(\d+)\b", re.IGNORECASE),
    re.compile(r"\bfollow-up to\s+#(\d+)\b", re.IGNORECASE),
    re.compile(r"\bafter\s+#(\d+)(?:\s+and\s+#(\d+))?\b", re.IGNORECASE),
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
            for number in re.findall(r"#(\d+)\b", line):
                add(number)
            continue
        for declaration in DECLARATIONS:
            match = declaration.search(line)
            if match:
                for number in match.groups():
                    if number:
                        add(number)
                break
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
    subparsers = parser.add_subparsers(dest="command", required=True)
    dependency_parser = subparsers.add_parser("dependencies")
    input_group = dependency_parser.add_mutually_exclusive_group(required=True)
    input_group.add_argument("--issue", type=int)
    input_group.add_argument("--body-file")
    dependency_parser.set_defaults(func=dependencies)
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
