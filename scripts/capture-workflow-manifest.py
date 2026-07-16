#!/usr/bin/env python3
"""Fail-open UserPromptSubmit entry point for workflow start manifests."""

# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT

from pathlib import Path
import sys

from workflow_flight_recorder import fail_open_manifest_main


if __name__ == "__main__":
    raise SystemExit(
        fail_open_manifest_main(
            Path(__file__).with_name("workflow-flight-recorder-registry.json"),
            sys.stdin,
        )
    )
