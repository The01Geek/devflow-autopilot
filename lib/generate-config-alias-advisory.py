#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Render the config-side accepted-alias advisory (issue #1028).

After a Tier-1 migration (or a re-scaffold) a consumer's `.prflow/config.json` still
carries the word `devflow` in a handful of places: `agent_overrides` keys under the
`devflow:` namespace, a `devflow`-spelled `workpad_marker`, and `docs.labels` /
`deferred.labels` values naming the `DevFlow` provenance label. Every one of those is a
DELIBERATE, permanently-accepted alias — each reader dual-accepts both spellings — so the
migration leaves them on purpose (it renames top-level keys only, never nested keys or
values). The defect issue #1028 fixes is not that they remain; it is that the consumer
cannot tell they are deliberate, and a consumer primed to "finish the rename by hand" is
one hand-edit away from renaming a `DEVFLOW_*` ENVIRONMENT identifier — which is frozen and
mostly fails silently.

This is the config-side sibling of `lib/generate-env-freeze-advisory.py` (the env half).
It is REPORT-ONLY: it reads the config and never writes it. Its population is DERIVED from
what the config actually contains, so a consumer with no `agent_overrides` block is never
told about override namespaces, and a config with nothing superseded produces no output at
all — this repo's scaffolder ethos of staying silent when nothing is actionable.

It deliberately does NOT restate the `DEVFLOW_*` inventory: it names the environment-freeze
hazard and points at `lib/rename-map.json`'s `frozen.env_identifiers` and the env-half
generator, so it never reads as a rename table.

EXIT CODES
  0  ran; the advisory was printed to stdout iff a superseded spelling was present
     (empty stdout when the config is a clean object with nothing to report)
  2  input failure — the config could not be read, is not JSON, or is not a JSON object.
     Nothing is printed to stdout; a breadcrumb goes to stderr. The caller treats this as
     "could not advise" and continues (the advisory is best-effort and never blocks a
     scaffold).
"""

from __future__ import annotations

import argparse
import json
import sys

# The superseded provenance-label literal, matched case-insensitively against a label
# value. The alias namespace `devflow:` covers the override keys and the workpad marker.
SUPERSEDED_TOKEN = "devflow"


class InputError(Exception):
    """The config could not be read or is not an object. Routed to exit 2, not 0."""


def load_config(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            raw = fh.read()
    except OSError as exc:
        raise InputError(f"config unreadable: {exc}") from exc
    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, ValueError) as exc:
        raise InputError(f"config is not valid JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise InputError("config is not a JSON object")
    return data


def _nested_object(cfg: dict, *keys: str) -> dict | None:
    """Return cfg[k] for the first key whose value is a JSON object, else None.

    Both the canonical (`prflow*`) and superseded (`devflow*`) top-level spellings are
    probed, because a consumer whose Tier-1 migration has not run yet still keys its blocks
    under the superseded name. Every access is type-guarded — a scalar, array, or missing
    block simply contributes nothing, never a crash.
    """
    for key in keys:
        value = cfg.get(key)
        if isinstance(value, dict):
            return value
    return None


def _string(container: dict | None, key: str) -> str | None:
    if not isinstance(container, dict):
        return None
    value = container.get(key)
    return value if isinstance(value, str) else None


def detect(cfg: dict) -> list[str]:
    """Derive one advisory line per superseded-alias category actually present.

    Returns the list of category lines (empty when nothing is superseded).
    """
    lines: list[str] = []

    # 1. agent_overrides namespace — keys spelled `devflow:<agent>`.
    review = _nested_object(cfg, "prflow_review", "devflow_review")
    overrides = review.get("agent_overrides") if isinstance(review, dict) else None
    if isinstance(overrides, dict):
        alias_keys = sorted(
            k for k in overrides if isinstance(k, str) and k.startswith("devflow:")
        )
        if alias_keys:
            lines.append(
                "the `agent_overrides` namespace — "
                + ", ".join(f"`{k}`" for k in alias_keys)
                + " (both the `prflow:` and `devflow:` spellings resolve, canonical "
                "first, with deterministic precedence)"
            )

    # 2. workpad marker — a `devflow`-spelled marker string.
    top = _nested_object(cfg, "prflow", "devflow")
    marker = _string(top, "workpad_marker")
    if marker is not None and SUPERSEDED_TOKEN in marker.lower():
        lines.append(
            f"the workpad marker — `{marker}` (readers dual-map either namespace, so "
            "workpads written under it still resolve)"
        )

    # 3. provenance labels — `docs.labels` / `deferred.labels` naming `DevFlow`.
    label_hits: list[str] = []
    for block, key in (("docs", "labels"), ("deferred", "labels")):
        value = _string(cfg.get(block) if isinstance(cfg.get(block), dict) else None, key)
        if value is not None and SUPERSEDED_TOKEN in value.lower():
            label_hits.append(f"`{block}.labels` = `{value}`")
    if label_hits:
        lines.append(
            "the provenance label values — "
            + ", ".join(label_hits)
            + " (selection dual-accepts `PRFlow` and `DevFlow`; only the label APPLIED to "
            "new artifacts is affected)"
        )

    return lines


def render(config_path: str, lines: list[str]) -> str:
    out: list[str] = []
    out.append(
        f"NOTICE: {config_path} still contains the superseded `devflow` spelling in a few "
        "places. Every one is a DELIBERATE, permanently-accepted alias that the migration "
        "left in place ON PURPOSE (it renames top-level keys only, never nested keys or "
        "values) — each resolves correctly and none requires any action:"
    )
    out.extend(f"  - {line}" for line in lines)
    out.append(
        "  Do NOT hand-edit these to \"finish the rename\" — they are correct as they are."
    )
    out.append(
        "  Separately and more importantly: the `DEVFLOW_*` ENVIRONMENT identifiers "
        "(GitHub variables/secrets and shell overrides) must NEVER be hand-renamed either. "
        "Nothing reads a `PRFLOW_*` equivalent, so renaming one removes the setting rather "
        "than moving it, and most fail SILENTLY. That is a separate, frozen inventory — see "
        "`lib/rename-map.json`'s `frozen.env_identifiers` (rendered by "
        "`lib/generate-env-freeze-advisory.py`); this notice does not restate it."
    )
    return "\n".join(out)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description="Report the accepted-alias `devflow` spellings present in a config."
    )
    ap.add_argument("config", help="path to the consumer's .prflow/config.json")
    args = ap.parse_args(argv)

    try:
        cfg = load_config(args.config)
    except InputError as exc:
        print(f"config-alias-advisory: {exc}", file=sys.stderr)
        return 2

    lines = detect(cfg)
    if not lines:
        # Silent when nothing is actionable — no consumer-facing output.
        return 0
    print(render(args.config, lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
