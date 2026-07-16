#!/usr/bin/env python3
"""Compatibility entry point for implement-only workflow analysis."""

from pathlib import Path
import os
import sys


if __name__ == "__main__":
    analyzer = Path(__file__).with_name("analyze-workflow-runs.py")
    os.execv(sys.executable, [sys.executable, str(analyzer), "--workflow", "implement", *sys.argv[1:]])
