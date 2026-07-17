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


def issue_body(issue: int) -> str:
    try:
        result = subprocess.run(
            [GH, "issue", "view", str(issue), "--json", "body", "-q", ".body"],
            check=True,
            capture_output=True,
            encoding="utf-8",
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        detail = exc.stderr.strip() if isinstance(exc, subprocess.CalledProcessError) else str(exc)
        raise RuntimeError(f"could not read issue body: {detail}") from exc
    return result.stdout


def issue_state(number: str) -> str | None:
    try:
        result = subprocess.run(
            [GH, "issue", "view", number, "--json", "state", "-q", ".state"],
            check=True,
            capture_output=True,
            encoding="utf-8",
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    state = result.stdout.strip()
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
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
