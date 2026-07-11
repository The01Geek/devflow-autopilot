#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Shared config-fingerprint canonicalization (issue #431).

The single source of truth for the `config_fingerprint` object. Imported by
`scripts/build-experiment-records.py` (the reader, resolving a record predating
the field from `git show <merge_sha>:.devflow/config.json`) AND invoked as a CLI
by `lib/efficiency-trace.sh`'s `compute_config_fingerprint` (the producer,
stamping the field into each per-run record). Both paths therefore share ONE
implementation, so a record-sourced and a git-show-sourced fingerprint are
byte-identical for the same config by construction — not by a hand-kept mirror
(the coupled-mirror hazard CLAUDE.md repeatedly warns against).

The module name uses an underscore (not the repo's usual hyphen) so it is
importable by build-experiment-records.py. python3 is a hard preflight
prerequisite, so invoking this CLI from the shell adds no new command head.
"""

import hashlib
import json
import sys

# Salient key-value pairs carried VERBATIM into the fingerprint, in this fixed
# order (the insertion order is part of the byte-identical contract): (block, key).
SALIENT_KEYS = (
    ("devflow_review", "verdict_severity_threshold"),
    ("devflow_review_and_fix", "fix_severity_threshold"),
    ("devflow_review_and_fix", "max_iterations"),
)


def fingerprint_from_config(cfg):
    """Return the fingerprint object {sha256, partial, salient} for a parsed config
    dict, or None when neither review block exists. Canonicalization: only
    object-typed devflow_review / devflow_review_and_fix blocks contribute; keys
    sorted and separators compact so it is stable across key order / whitespace;
    `partial` records that the hash covers fewer than both blocks."""
    if not isinstance(cfg, dict):
        return None
    blocks = {k: cfg[k] for k in ("devflow_review", "devflow_review_and_fix")
              if isinstance(cfg.get(k), dict)}
    if not blocks:
        return None
    canonical = json.dumps(blocks, sort_keys=True, separators=(",", ":"))
    digest = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    salient = {}
    for block, name in SALIENT_KEYS:
        b = blocks.get(block)
        if isinstance(b, dict) and name in b:
            salient[name] = b[name]
    return {"sha256": digest, "partial": len(blocks) < 2, "salient": salient}


def _main(argv):
    """CLI: read a config path (argv[1]), print the fingerprint JSON object or the
    literal `null`. Best-effort — a missing/unreadable/non-object config prints
    `null` and exits 0 so the shell producer degrades gracefully."""
    if len(argv) < 2:
        print("null")
        return 0
    try:
        with open(argv[1], encoding="utf-8") as fh:
            cfg = json.load(fh)
    except (OSError, ValueError):
        print("null")
        return 0
    fp = fingerprint_from_config(cfg)
    print(json.dumps(fp, separators=(",", ":")) if fp else "null")
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
