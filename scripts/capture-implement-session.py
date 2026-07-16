#!/usr/bin/env python3
"""Stable compatibility entry point for the generic workflow recorder."""

from pathlib import Path
import sys

from workflow_flight_recorder import fail_open_main


if __name__ == "__main__":
    raise SystemExit(
        fail_open_main(Path(__file__).with_name("workflow-flight-recorder-registry.json"), sys.stdin)
    )
