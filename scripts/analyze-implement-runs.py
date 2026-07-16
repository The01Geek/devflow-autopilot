#!/usr/bin/env python3
"""Compatibility entry point for implement-only workflow analysis."""

# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT

from pathlib import Path
import os
import sys


if __name__ == "__main__":
    analyzer = Path(__file__).with_name("analyze-workflow-runs.py")
    try:
        os.execv(
            sys.executable,
            [sys.executable, str(analyzer), "--workflow", "implement", *sys.argv[1:]],
        )
    except OSError as exc:
        # execv only returns by failing. Report it in the devflow breadcrumb convention
        # rather than as a raw traceback, and name the analyzer that could not be run.
        print(f"devflow: implement-run-analysis: cannot run {analyzer}: {exc}", file=sys.stderr)
        sys.exit(1)
