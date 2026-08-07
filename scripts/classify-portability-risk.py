#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Shallow-safe portability-risk classifier for the macOS Bash 3.2 lane (issue #1277).

The lane runs a *selected* portable surface rather than the whole one, so this
classifier decides what gets verified. Every way of getting that decision wrong is
asymmetric: over-selecting costs runner minutes, while under-selecting silently
ships an unverified Bash-3.2 incompatibility. So the only two outcomes are

* ``selective``    — the PR-owned changed-file population was **fully established**
  and touches nothing on the select-everything list, so a subset suffices; and
* ``conservative`` — the complete portable population runs.

and every degraded input takes the second. There is deliberately no third outcome and
no ``not_applicable``: an established-and-empty selection is reported as
``selective`` with an empty ``selected`` list, and it is the *lane* — not this
classifier — that turns that into a domain result. Collapsing "we could not look" onto
"we looked and there was nothing" is the failure this vocabulary exists to prevent.

Establishing the changed-file population
----------------------------------------
The population comes from the paginated pull-request **files** API, never from the
local checkout: CI checks out a merge ref whose diff against the local base is not
the PR's own changed-file set, and a shallow checkout cannot compute one at all.
Three independent conditions must all hold before the result is `established`:

1. every page was read (`scripts/gh_json_ex.py`'s establish-vs-absent contract —
   a non-zero `gh` rc or an unparseable body is *unestablished*, never empty);
2. the number of **distinct** filenames returned equals the PR's own
   ``changed_files`` count, which is what detects a truncated pagination; and
3. the head SHA this run was told to classify equals the PR's current head, which is
   what detects evidence bound to a superseded commit.

A duplicate filename returned with conflicting ``status`` values is treated as
conflicting input, not reconciled.

Non-PR CI events
----------------
A push, a schedule, or a manual dispatch has no pull-request files endpoint to read,
so there is no changed-file population to narrow by. Those events select the complete
portable population — a decided outcome, not a degradation, and reported as such.

Exit codes
----------
0 — a decision was produced (including every conservative one; a conservative
    decision is the *correct successful outcome* for degraded input, not an error).
2 — no decision could be produced at all (the registry is unreadable, so even the
    complete portable population is unknown). Never silently empty.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path

SCHEMA_VERSION = 1
CLASSIFIER_VERSION = 1

#: The registry schema this classifier reads; must match the totality checker's.
REGISTRY_SCHEMA_VERSION = 1

#: Changing any of these means the *selection machinery itself* changed, so a subset
#: chosen by the new machinery proves nothing about the old surface. Every one of them
#: selects the complete portable population. Kept as literal paths for the same reason
#: the registry's keys are: a pattern would silently widen or narrow on an unrelated
#: file being added beside one of these.
SELECT_ALL_PATHS = (
    "lib/shell-surface-registry.json",
    "lib/test/check-shell-surface-totality.py",
    "scripts/classify-portability-risk.py",
    "scripts/run-bash32-fixtures.py",
    "lib/test/gate-portability-result.sh",
    "lib/test/fixtures/bash32/manifest.tsv",
    ".github/workflows/ci.yml",
)

#: The fixture corpus is the executable statement of the shell-syntax policy; any
#: change to it re-decides what "portable" means, so it selects everything too.
SELECT_ALL_PREFIXES = ("lib/test/fixtures/bash32/",)

REASON_NON_PR_EVENT = "non-pr-event"
REASON_SELECTION_MACHINERY = "selection-machinery-changed"
REASON_UNCLASSIFIED_SHELL = "unclassified-shell-surface-changed"
REASON_SHARED_DEPENDENCY = "shared-dependency-changed"
REASON_ESTABLISHED = "changed-file-population-established"


def _load_shared_gh():
    module_path = Path(__file__).resolve().parent / "gh_json_ex.py"
    spec = importlib.util.spec_from_file_location("_portability_gh_json_ex", module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load the shared gh reader at {module_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_registry(path: Path):
    """Return `(portable_paths, all_paths, closure_members)` or raise OSError/ValueError.

    The `schema_version` is checked here as well as in the totality checker: this is a
    second reader of one schema, and the failure it guards against is silent — a state
    rename would leave every entry looking non-portable and the lane would verify
    nothing while reporting a clean selection.
    """
    document = json.loads(path.read_text(encoding="utf-8"))
    if document.get("schema_version") != REGISTRY_SCHEMA_VERSION:
        raise ValueError(
            f"unsupported registry schema_version {document.get('schema_version')!r} "
            f"(this classifier understands {REGISTRY_SCHEMA_VERSION})"
        )
    entries = document.get("entries")
    if not isinstance(entries, dict):
        raise ValueError("the registry has no `entries` object")
    portable = sorted(p for p, r in entries.items() if isinstance(r, dict) and r.get("state") == "portable")
    closure_members = set()
    for record in entries.values():
        if isinstance(record, dict) and record.get("state") == "portable":
            closure_members.update(record.get("shared_library_closure") or [])
    return portable, set(entries), closure_members


def changed_files(gh, repo: str, pr: int, head_sha: str):
    """Return `(filenames, detail)`, where `filenames` is None when the population
    could not be established.

    `None` — rather than an empty list plus a separate flag — is what makes the
    unestablished state unrepresentable as "we looked and found nothing": every arm
    below that could not establish an answer returns it, and only the final arm
    returns a list.
    """
    meta, ok = gh.gh_json_ex(f"repos/{repo}/pulls/{pr}")
    if not ok or not isinstance(meta, dict):
        return None, "the pull-request metadata could not be established"
    expected = meta.get("changed_files")
    current_head = ((meta.get("head") or {}).get("sha")) if isinstance(meta.get("head"), dict) else None
    if not isinstance(expected, int):
        return None, "the pull request reported no usable `changed_files` count"
    if head_sha and current_head and head_sha != current_head:
        return None, (
            f"evidence is bound to {head_sha[:12]} but the pull request's current head "
            f"is {current_head[:12]} — the classification would be stale"
        )
    if head_sha and not current_head:
        return None, "the pull request's current head SHA could not be established"

    pages, ok = gh.gh_json_ex(f"repos/{repo}/pulls/{pr}/files?per_page=100", paginate=True)
    if not ok:
        return None, "the pull-request files pages could not be established"
    if pages is None:
        pages = []
    if not isinstance(pages, list):
        return None, "the pull-request files response was not a list"

    statuses: dict[str, set] = {}
    for item in pages:
        if not isinstance(item, dict) or not isinstance(item.get("filename"), str):
            return None, "a pull-request files record was not a usable object"
        statuses.setdefault(item["filename"], set()).add(item.get("status"))
    conflicting = sorted(name for name, seen in statuses.items() if len(seen) > 1)
    if conflicting:
        return None, f"conflicting statuses for the same filename: {', '.join(conflicting[:5])}"

    distinct = sorted(statuses)
    if len(distinct) != expected:
        return None, (
            f"pagination returned {len(distinct)} distinct file(s) but the pull request "
            f"reports changed_files={expected} — the population is truncated or conflicting"
        )
    return distinct, f"{len(distinct)} changed file(s) reconciled against changed_files"


def select(paths, portable, classified, closure_members):
    """Return `(selected, reason)` for an established changed-file population."""
    for path in paths:
        if path in SELECT_ALL_PATHS or path.startswith(SELECT_ALL_PREFIXES):
            return list(portable), REASON_SELECTION_MACHINERY
    for path in paths:
        if path.endswith(".sh") and path not in classified:
            return list(portable), REASON_UNCLASSIFIED_SHELL
    for path in paths:
        if path in closure_members:
            return list(portable), REASON_SHARED_DEPENDENCY
    changed = set(paths)
    return [p for p in portable if p in changed], REASON_ESTABLISHED


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Classify which portable shell surface the macOS lane must run.")
    parser.add_argument("--repo", default="", help="OWNER/REPO")
    parser.add_argument("--pr", default="", help="pull-request number (empty on a non-PR event)")
    parser.add_argument("--head-sha", default="", help="the head SHA this classification is bound to")
    parser.add_argument("--event-name", default="", help="the GitHub Actions event name")
    parser.add_argument("--registry", default=None, help="path to lib/shell-surface-registry.json")
    args = parser.parse_args(argv)

    registry_path = Path(args.registry) if args.registry else Path("lib/shell-surface-registry.json")
    try:
        portable, classified, closure_members = load_registry(registry_path)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        # No decision is possible: without the registry even the conservative
        # population is unknown, and emitting an empty selection here would read as
        # "nothing to verify". Fail loudly instead.
        print(f"classify-portability-risk: the registry could not be read ({registry_path}): {exc}",
              file=sys.stderr)
        return 2

    result = {
        "schema_version": SCHEMA_VERSION,
        "classifier_version": CLASSIFIER_VERSION,
        "event_name": args.event_name,
        "pr": args.pr or None,
        "head_sha": args.head_sha or None,
    }

    if args.event_name != "pull_request" or not args.pr.strip().isdigit():
        result.update(execution="conservative", established=True, selected=list(portable),
                      reason=REASON_NON_PR_EVENT,
                      detail="no pull-request files population exists for this event; "
                             "the complete portable population runs")
        print(json.dumps(result, sort_keys=True))
        return 0

    gh = _load_shared_gh()
    paths, detail = changed_files(gh, args.repo, int(args.pr), args.head_sha)
    if paths is None:
        result.update(execution="conservative", established=False, selected=list(portable),
                      reason="unestablished", detail=detail)
        print(json.dumps(result, sort_keys=True))
        return 0

    selected, reason = select(paths, portable, classified, closure_members)
    result.update(
        execution="conservative" if reason != REASON_ESTABLISHED else "selective",
        established=True, selected=selected, reason=reason,
        detail=detail, changed_file_count=len(paths),
    )
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
