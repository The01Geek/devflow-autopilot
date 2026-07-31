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
from pathlib import Path

# `lib/rename-map.json` is the SINGLE SOURCE for the devflow→prflow rename (CLAUDE.md), so
# the superseded spellings this advisory looks for are DERIVED from it rather than carried
# as literal copies — the same single-source discipline the env-half sibling
# (lib/generate-env-freeze-advisory.py) follows. The map sits next to this helper in lib/.
MAP_REL = Path(__file__).resolve().parent / "rename-map.json"

# Fallbacks used ONLY when the map cannot be read (a degraded/partial deployment): the
# advisory is best-effort and must never break a scaffold over a missing or corrupt map.
# A map that IS present always wins, so these copies never cause drift when the map changes.
_FALLBACK_TOKEN = "devflow"
_FALLBACK_BLOCKS = {"prflow": "devflow", "prflow_review": "devflow_review"}


class InputError(Exception):
    """The config could not be read or is not an object. Routed to exit 2, not 0."""


class Vocab:
    """The superseded spellings to look for, derived from lib/rename-map.json.

    - ``token``: the superseded product name, lowercased (from the map's `provenance-label`
      identifier — `DevFlow` → `devflow`). One token serves every substring test: the
      workpad marker, the provenance-label values, and the `<token>:` override namespace.
    - ``blocks``: canonical → superseded top-level block names (from the map's `config_keys`),
      so a block is located whether or not this consumer's Tier-1 key migration has run.
    """

    def __init__(self, token: str, blocks: dict[str, str]):
        self.token = token
        self.blocks = blocks

    @property
    def override_prefix(self) -> str:
        return f"{self.token}:"


def load_vocab() -> Vocab:
    token = _FALLBACK_TOKEN
    blocks = dict(_FALLBACK_BLOCKS)
    try:
        data = json.loads(MAP_REL.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return Vocab(token, blocks)
    if not isinstance(data, dict):
        return Vocab(token, blocks)
    for row in data.get("identifiers") or []:
        if isinstance(row, dict) and row.get("id") == "provenance-label":
            superseded = row.get("superseded")
            if isinstance(superseded, str) and superseded.strip():
                token = superseded.lower()
            break
    config_keys = data.get("config_keys")
    if isinstance(config_keys, dict):
        derived = {
            current: superseded
            for superseded, current in config_keys.items()
            if isinstance(superseded, str) and isinstance(current, str)
        }
        # Keep only the two blocks this advisory probes; ignore the rest of the map.
        blocks = {c: derived[c] for c in ("prflow", "prflow_review") if c in derived} or blocks
    return Vocab(token, blocks)


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


def _nested_object(cfg: dict, canonical: str, blocks: dict[str, str]) -> dict | None:
    """Return the `canonical` block (or its superseded-spelled twin) when it is an object.

    Both the canonical (`prflow*`) and superseded (`devflow*`) top-level spellings are
    probed, because a consumer whose Tier-1 migration has not run yet still keys its blocks
    under the superseded name. Every access is type-guarded — a scalar, array, or missing
    block simply contributes nothing, never a crash.
    """
    for key in (canonical, blocks.get(canonical, "")):
        value = cfg.get(key) if key else None
        if isinstance(value, dict):
            return value
    return None


def _string(container: dict | None, key: str) -> str | None:
    if not isinstance(container, dict):
        return None
    value = container.get(key)
    return value if isinstance(value, str) else None


def detect(cfg: dict, vocab: Vocab) -> list[str]:
    """Derive one advisory line per superseded-alias category actually present.

    Returns the list of category lines (empty when nothing is superseded).
    """
    lines: list[str] = []

    # 1. agent_overrides namespace — keys spelled `devflow:<agent>`.
    review = _nested_object(cfg, "prflow_review", vocab.blocks)
    overrides = review.get("agent_overrides") if review else None
    if isinstance(overrides, dict):
        alias_keys = sorted(
            k for k in overrides if isinstance(k, str) and k.startswith(vocab.override_prefix)
        )
        if alias_keys:
            lines.append(
                "the `agent_overrides` namespace — "
                + ", ".join(f"`{k}`" for k in alias_keys)
                + " (both the `prflow:` and `devflow:` spellings resolve, canonical "
                "first, with deterministic precedence)"
            )

    # 2. workpad marker — a `devflow`-spelled marker string.
    top = _nested_object(cfg, "prflow", vocab.blocks)
    marker = _string(top, "workpad_marker")
    if marker is not None and vocab.token in marker.lower():
        lines.append(
            f"the workpad marker — `{marker}` (readers dual-map either namespace, so "
            "workpads written under it still resolve)"
        )

    # 3. provenance labels — `docs.labels` / `deferred.labels` naming `DevFlow`.
    label_hits: list[str] = []
    for block, key in (("docs", "labels"), ("deferred", "labels")):
        value = _string(cfg.get(block), key)
        if value is not None and vocab.token in value.lower():
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

    lines = detect(cfg, load_vocab())
    if not lines:
        # Silent when nothing is actionable — no consumer-facing output.
        return 0
    print(render(args.config, lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
