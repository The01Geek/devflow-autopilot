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
  - A non-empty string `model` is forwarded as given (no value validation); a
    present-but-unusable model (empty/non-string) is dropped with a warning,
    mirroring the invalid-effort path.
  - An entry that resolves to neither a model nor a valid effort emits no
    override for that subagent (nothing to apply).
  - A non-object entry (e.g. a hand-edited `"agent": "high"` or a list) is
    ignored with a warning rather than crashing — the engine never aborts on
    config shape.

Usage:
    resolve-review-overrides.py AGENT [AGENT ...] [--config FILE] [--config-get PATH]

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

# config-get.sh stringifies a config value via Node's String(); a JSON object
# yields this sentinel. read_raw uses it to tell a present-but-empty object
# entry ({}) from a scalar/array entry the operator hand-edited in.
_OBJECT_SENTINEL = "[object Object]"

# The nine review-engine subagent identifiers. Byte-identical to the schema
# property keys and the dispatch ids in skills/review/SKILL.md; the six Phase-3
# ids additionally match the telemetry strings (phase3_dispatched / finding
# `agent`) in skills/review-and-fix/SKILL.md.
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
    default_entry = raw.get("default")
    if default_entry is not None and not isinstance(default_entry, dict):
        warnings.append(
            f"agent_overrides[default]={default_entry!r} is not an object; "
            "ignoring it."
        )
        default_entry = None
    default_entry = default_entry or {}
    result = {}
    for agent in dispatched:
        # Entry-level precedence: own entry wins outright; else fall back to
        # `default`. A present-but-empty own entry ({}) still counts as "has an
        # entry", so `default` does NOT apply to it.
        entry = raw[agent] if agent in raw else default_entry
        source = agent if agent in raw else "default"
        # A non-object entry (hand-edited config bypassing schema validation,
        # e.g. `"agent": "high"` or a list) must not crash resolution — the
        # engine never aborts on config shape. Warn and treat it as no override.
        if not isinstance(entry, dict):
            warnings.append(
                f"agent_overrides[{source}]={entry!r} is not an object; "
                f"ignoring it (no override for '{agent}')."
            )
            continue
        resolved = {}

        model = entry.get("model")
        if model is not None:
            if isinstance(model, str) and model:
                resolved["model"] = model
            else:
                warnings.append(
                    f"agent_overrides[{source}].model={model!r} is not a "
                    f"non-empty string; ignoring it for '{agent}'."
                )

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


def _config_get(config_get, config_file, dotted_key, warnings):
    """Read one scalar via config-get.sh, returning '' on absent/empty.

    We always pass a default ("") to config-get.sh, so an absent key/file is a
    clean exit 0 with empty stdout — NOT an error. A non-zero exit therefore
    signals a genuine failure (malformed config.json → exit 2, missing `node` →
    exit 2, bad args → exit 2), which we surface as a warning rather than
    silently collapsing to "absent" (a fat-fingered config would otherwise drop
    every override with no diagnostic). Appends to `warnings`; never raises.
    """
    cmd = [config_get, dotted_key, ""]
    if config_file:
        cmd.append(config_file)
    try:
        out = subprocess.run(
            cmd, capture_output=True, text=True, check=False
        )
    except OSError as exc:
        warnings.append(f"cannot run {config_get}: {exc}")
        return ""
    if out.returncode != 0:
        # Cause-focused (no per-key detail): a parse error / missing-node /
        # bad-args failure is the same root cause for every key we probe, so an
        # identical message dedupes to one actionable line in read_raw rather
        # than one per agent×field.
        warnings.append(
            f"config-get.sh failed (exit {out.returncode}): {out.stderr.strip()}"
        )
        return ""
    return out.stdout.strip()


def read_raw(dispatched, config_get, config_file):
    """Read each dispatched agent's (+ default's) model/effort via config-get.sh.

    Returns (raw, warnings). Reader warnings are deduplicated so a single broken
    `config_get` path surfaces one actionable line, not one per leaf read.
    """
    raw = {}
    warnings = []
    for agent in list(dispatched) + ["default"]:
        base = f".devflow_review.agent_overrides.{agent}"
        entry = {}
        for field in ("model", "effort"):
            # Agent ids contain ':' but never '.', so they are a single
            # dot-path segment — config-get.sh splits on '.' only.
            value = _config_get(config_get, config_file, f"{base}.{field}", warnings)
            if value:
                entry[field] = value
        # A present-but-empty entry ({}) is a real config state that must shadow
        # `default` (entry-level precedence). The leaf reads can't distinguish it
        # from an absent key, so probe the entry object itself. config-get.sh
        # stringifies the value: a JSON object prints the sentinel
        # "[object Object]" (Node's String({})), a scalar/array prints its own
        # stringification, and an absent key prints nothing. So:
        #   - sentinel       → present object, no model/effort → {} (shadows default)
        #   - other non-empty → a non-object entry (hand-edited config bypassing
        #     schema validation, e.g. `"agent": "high"`) → warn and treat as
        #     no-entry so `default` still applies; never crash.
        #   - empty          → absent key → no entry.
        # Only probe when no field was read — the common path stays at two reads.
        if entry:
            raw[agent] = entry
        else:
            probe = _config_get(config_get, config_file, base, warnings)
            if probe == _OBJECT_SENTINEL:
                raw[agent] = {}
            elif probe:
                warnings.append(
                    f"agent_overrides[{agent}]={probe!r} is not an object; "
                    f"ignoring it (no override for '{agent}'; default still applies)."
                )
    # Dedupe while preserving first-seen order (a missing/mispathed helper would
    # otherwise emit the same line ~2-3x per agent).
    deduped = list(dict.fromkeys(warnings))
    return raw, deduped


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

    # A dispatched id not in the known roster is almost always a drift between
    # SKILL.md's hardcoded strings and the canonical roster, or an operator typo
    # in agent_overrides — warn (don't abort) so it isn't a silent no-op.
    unknown = list(dict.fromkeys(a for a in args.agents if a not in KNOWN_AGENTS))

    raw, read_warnings = read_raw(args.agents, args.config_get, args.config)
    result, resolve_warnings = resolve_overrides(raw, args.agents)
    for a in unknown:
        sys.stderr.write(
            f"::warning::resolve-review-overrides: '{a}' is not a known "
            "review-engine subagent id (KNOWN_AGENTS); any override for it is "
            "resolved but it may indicate a typo or dispatch/roster drift.\n"
        )
    for w in read_warnings + resolve_warnings:
        sys.stderr.write(f"::warning::resolve-review-overrides: {w}\n")
    sys.stdout.write(json.dumps(result) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
