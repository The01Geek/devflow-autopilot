#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""The focused-first selection record — a named, round-trippable producer/reader
(issue #1229).

A run's focused-first precondition (`.prflow/prompt-extensions/{implement,
review-and-fix,receiving-code-review}.md`) asks the run to *establish*, per touched
surface, either the discharging focused test it selected (the coverage-map entry it
consulted and the target it ran) or the exemption ground that applied, and to record
whether the `scripts/verification-flight.py` single flight was consulted before a
full-suite relaunch. Those rules named no sink, so a followed rule and an ignored one
left identical traces. This module is that record's shape: a single serializer both
sinks share.

The two sinks (named by the prompt extensions, not by this module):
  * An implement run records the marker `encode_marker` emits as a `## Progress`
    note through `scripts/workpad.py` — a machine-parseable named record, not free
    prose in a general-purpose field.
  * A standalone fix loop stores the plain dict `build_record` returns as the
    `focused_selection` field of the iteration record `iter-<N>.json`'s
    `verification_evidence` object (see `skills/review-and-fix/references/fixing.md`).

The record is deliberately a *record of what the run did*, never a launch counter, a
launch ordinal, or a changed-file-to-module routing table — those remain prohibited
by the prompt extensions (issue #1229 AC7). Nothing in this module derives the
touched-surface set; the caller supplies it.

python3 standard library only; no third-party imports.
"""

from __future__ import annotations

import argparse
import base64
import json
import re
import sys

# The named marker literal. Only the current `prflow:` spelling is minted (this
# record postdates the issue #1003 marker-namespace rename). The payload is a
# base64-encoded JSON object, so an arbitrary coverage-map path or module id in the
# record can never smuggle a `-->` and terminate the HTML comment early.
MARKER_PREFIX = "prflow:focused-selection"
_MARKER_RE = re.compile(
    r"<!--\s*" + re.escape(MARKER_PREFIX) + r"\s+([A-Za-z0-9+/=]+)\s*-->"
)

# The two per-surface entry shapes.
ENTRY_FOCUSED_RESULT = "focused-result"
ENTRY_EXEMPTION = "exemption"


def classify_entry(entry: dict) -> str:
    """Classify one per-surface entry as a discharging focused result or an
    exemption ground. Raises ValueError on an entry that is neither (an
    unclassifiable surface must never be recorded silently — the whole point of the
    record is that a discharged surface and an exempt surface are distinguishable)."""
    if not isinstance(entry, dict) or not entry.get("surface"):
        raise ValueError("a focused-selection surface entry must name a `surface`")
    has_focused = bool(entry.get("coverage_map_entry")) and bool(entry.get("target"))
    has_exemption = bool(entry.get("exemption_ground"))
    if has_focused and not has_exemption:
        return ENTRY_FOCUSED_RESULT
    if has_exemption and not has_focused:
        return ENTRY_EXEMPTION
    raise ValueError(
        f"focused-selection entry for {entry.get('surface')!r} is neither a "
        f"discharging focused result (coverage_map_entry + target) nor an exemption "
        f"(exemption_ground), or is ambiguously both"
    )


def build_record(surfaces, single_flight_consulted=None) -> dict:
    """Build the canonical focused-selection record.

    `surfaces` is a list of per-surface entries; each is validated by
    `classify_entry` and normalized to only the fields its shape carries, so a
    round-tripped record is byte-stable. `single_flight_consulted` is either None
    (no relaunch consultation to record) or a JSON-serializable object describing the
    consultation (AC4). Returns a plain dict — the value stored verbatim as
    `verification_evidence.focused_selection` in the standalone sink."""
    if not isinstance(surfaces, list):
        raise ValueError("surfaces must be a list of per-surface entries")
    normalized = []
    for entry in surfaces:
        kind = classify_entry(entry)  # raises on an unclassifiable entry
        if kind == ENTRY_FOCUSED_RESULT:
            normalized.append({
                "surface": entry["surface"],
                "coverage_map_entry": entry["coverage_map_entry"],
                "target": entry["target"],
            })
        else:
            normalized.append({
                "surface": entry["surface"],
                "exemption_ground": entry["exemption_ground"],
            })
    return {
        "surfaces": normalized,
        "single_flight_consulted": single_flight_consulted,
    }


def encode_marker(record: dict) -> str:
    """Serialize a record into the named marker string. The JSON is base64-encoded
    so no record content can terminate the HTML comment or need shell quoting."""
    raw = json.dumps(record, sort_keys=True, separators=(",", ":")).encode("utf-8")
    payload = base64.b64encode(raw).decode("ascii")
    return f"<!-- {MARKER_PREFIX} {payload} -->"


def decode_markers(text: str) -> list:
    """Read every focused-selection record carried by `text` (a workpad body, a note,
    or any string). Returns the list of decoded record dicts in document order — the
    empty list when no marker is present (the "no record at all" case, distinct from
    a real record whose `surfaces` list is empty). A malformed payload (bad base64,
    non-JSON, or a non-object) is skipped, never surfaced as a spurious record —
    fail closed toward "no record" rather than inventing one."""
    out = []
    for m in _MARKER_RE.finditer(text or ""):
        try:
            raw = base64.b64decode(m.group(1), validate=True)
            obj = json.loads(raw.decode("utf-8"))
        except (ValueError, json.JSONDecodeError, UnicodeDecodeError):
            continue
        if isinstance(obj, dict):
            out.append(obj)
    return out


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="focused-selection.py",
        description="Encode/decode the focused-first selection record (issue #1229).",
    )
    sub = p.add_subparsers(dest="cmd", required=True)
    enc = sub.add_parser("encode", help="Read a record JSON object from stdin and "
                                        "print its named marker.")
    enc.set_defaults(func=_cmd_encode)
    dec = sub.add_parser("decode", help="Read text from stdin and print the JSON "
                                        "array of records it carries.")
    dec.set_defaults(func=_cmd_decode)
    return p


def _cmd_encode(_args) -> int:
    obj = json.loads(sys.stdin.read())
    rec = build_record(obj.get("surfaces", []), obj.get("single_flight_consulted"))
    sys.stdout.write(encode_marker(rec) + "\n")
    return 0


def _cmd_decode(_args) -> int:
    sys.stdout.write(json.dumps(decode_markers(sys.stdin.read())) + "\n")
    return 0


def main(argv=None) -> int:
    args = _build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
