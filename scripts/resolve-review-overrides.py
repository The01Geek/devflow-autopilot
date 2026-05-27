#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Resolve per-subagent model/effort overrides for the /devflow:review engine.

The shared review engine (skills/review/SKILL.md) dispatches up to nine
subagents. Operators tune each one's model/effort via the
`devflow_review.agent_overrides` block in .devflow/config.json. This helper
reads that block (through config-get.sh — DevFlow's single config reader) for
the subagents about to be dispatched and materializes the per-run `--agents`
JSON override map the engine passes at dispatch.

Resolution rules (mirroring the schema + docs/review-agent-overrides.md):
  - Entry-level precedence: a subagent with its own entry uses ONLY that entry;
    the `default` entry does NOT backfill its missing fields. The `default`
    entry supplies model/effort only for subagents with no entry of their own.
  - A subagent with neither its own entry nor a `default` produces no override
    (dispatched exactly as today — global claude_model + session effort).
  - `effort` outside the schema enum is dropped with a warning (falls back to
    the session effort); the run never aborts on a bad effort value.
  - `model` is forwarded as given (free-form; no validation).
  - An entry that resolves to neither a model nor a valid effort emits no
    override for that subagent (nothing to apply).

Usage:
    resolve-review-overrides.py AGENT [AGENT ...] [--config FILE]

Prints the override map as JSON to stdout, e.g.
    {"pr-review-toolkit:code-reviewer": {"model": "claude-opus-4-7", "effort": "high"}}
Prints `{}` when no dispatched subagent has an applicable override (the engine
then emits no --agents block). Warnings go to stderr; exit code is always 0
unless arguments are invalid (the engine must never abort on config shape).
"""

import argparse
import json
import os
import subprocess
import sys

VALID_EFFORTS = ("low", "medium", "high", "xhigh", "max")

# The nine review-engine subagent identifiers, byte-identical to the telemetry
# strings in skills/review-and-fix/SKILL.md and the schema property keys.
KNOWN_AGENTS = (
    "devflow:checklist-generator",
    "devflow:checklist-deduper",
    "devflow:checklist-verifier",
    "pr-review-toolkit:code-reviewer",
    "pr-review-toolkit:silent-failure-hunter",
    "pr-review-toolkit:comment-analyzer",
    "pr-review-toolkit:type-design-analyzer",
    "pr-review-toolkit:pr-test-analyzer",
    "superpowers:requesting-code-review",
)


def resolve_overrides(raw, dispatched):
    """Pure resolution: raw config -> (override_map, warnings).

    `raw` maps an agent id (or "default") to a dict that may carry "model"
    and/or "effort". `dispatched` is the list of agent ids about to be
    dispatched this phase. Returns the override map (only agents with an
    applicable override) and a list of human-readable warning strings.
    """
    warnings = []
    default_entry = raw.get("default") or {}
    result = {}
    for agent in dispatched:
        # Entry-level precedence: own entry wins outright; else fall back to
        # `default`. A present-but-empty own entry ({}) still counts as "has an
        # entry", so `default` does NOT apply to it.
        entry = raw[agent] if agent in raw else default_entry
        source = agent if agent in raw else "default"
        resolved = {}

        model = entry.get("model")
        if isinstance(model, str) and model:
            resolved["model"] = model

        effort = entry.get("effort")
        if effort is not None:
            if effort in VALID_EFFORTS:
                resolved["effort"] = effort
            else:
                warnings.append(
                    f"agent_overrides[{source}].effort={effort!r} is not one of "
                    f"{list(VALID_EFFORTS)}; falling back to session effort for "
                    f"'{agent}'."
                )

        if resolved:
            result[agent] = resolved
    return result, warnings


def _config_get(config_get, config_file, dotted_key):
    """Read one scalar via config-get.sh, returning '' on absent/empty."""
    cmd = [config_get, dotted_key, ""]
    if config_file:
        cmd.append(config_file)
    try:
        out = subprocess.run(
            cmd, capture_output=True, text=True, check=False
        )
    except OSError as exc:
        sys.stderr.write(f"resolve-review-overrides: cannot run {config_get}: {exc}\n")
        return ""
    if out.returncode != 0:
        # config-get.sh exits 2 on bad args / parse error; treat as absent.
        return ""
    return out.stdout.strip()


def read_raw(dispatched, config_get, config_file):
    """Read each dispatched agent's (+ default's) model/effort via config-get.sh."""
    raw = {}
    for agent in list(dispatched) + ["default"]:
        base = f".devflow_review.agent_overrides.{agent}"
        entry = {}
        for field in ("model", "effort"):
            # Agent ids contain ':' but never '.', so they are a single
            # dot-path segment — config-get.sh splits on '.' only.
            value = _config_get(config_get, config_file, f"{base}.{field}")
            if value:
                entry[field] = value
        # A present-but-empty entry ({}) is a real config state that must shadow
        # `default` (entry-level precedence). The leaf reads can't distinguish it
        # from an absent key, so probe the entry object itself: config-get.sh
        # prints a non-empty string ("[object Object]") for a present object and
        # nothing for an absent key. Only probe when no field was read — the
        # common path stays at two reads.
        if entry:
            raw[agent] = entry
        elif _config_get(config_get, config_file, base):
            raw[agent] = {}
    return raw


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("agents", nargs="+", help="subagent ids about to be dispatched")
    parser.add_argument("--config", default=None, help="config file (passed to config-get.sh)")
    parser.add_argument(
        "--config-get",
        default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "config-get.sh"),
        help="path to config-get.sh (default: alongside this script)",
    )
    args = parser.parse_args(argv)

    raw = read_raw(args.agents, args.config_get, args.config)
    result, warnings = resolve_overrides(raw, args.agents)
    for w in warnings:
        sys.stderr.write(f"::warning::resolve-review-overrides: {w}\n")
    sys.stdout.write(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
