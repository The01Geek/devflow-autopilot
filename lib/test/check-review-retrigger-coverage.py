# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Assert devflow-review.yml's CI-completion re-trigger list covers every gating workflow.

`devflow-review.yml` defers a review behind `require_ci_green` until every OTHER
Actions run on the PR head has completed, and re-fires it via a
`workflow_run: {workflows: [...], types: [completed]}` trigger. GitHub forbids
wildcards in that list, so it must name EVERY first-party workflow that runs on
PR events (and therefore gates the review). A gating workflow left off the list
that finishes AFTER the listed ones strands the review at the neutral
"waiting: other CI not green" check with no event left to clear it (issue #579:
`Matcher probe` completed after `CI` and wedged the review).

This checker enumerates every `.github/workflows/*.yml` that triggers on
`pull_request`/`pull_request_target`, excludes the review workflow itself (it
must not re-trigger on its own completion), and asserts each remaining
workflow's `name:` appears in the re-trigger list. Exit 0 when the list is a
superset of the gating set; exit 1 (naming the missing workflows) otherwise.

Usage: check-review-retrigger-coverage.py [<workflows-dir>]
Default dir: .github/workflows relative to the repo root (two levels up from lib/test/).
"""

from __future__ import annotations

import sys
from pathlib import Path

import yaml

REVIEW_WF_FILENAME = "devflow-review.yml"
# The review workflow re-triggers off OTHER workflows; it must never list
# itself (recursion) and require_ci_green already excludes it by name.
SELF_WORKFLOW_NAME = "Devflow Review (auto-trigger)"
PR_TRIGGERS = ("pull_request", "pull_request_target")


def _on_block(doc: dict):
    """Return the `on:` mapping/list/scalar, tolerating YAML 1.1's `on` -> True."""
    if not isinstance(doc, dict):
        return None
    if True in doc:  # `on:` parsed as the boolean key True
        return doc[True]
    return doc.get("on")


def _triggers_on_pr(on_block) -> bool:
    if isinstance(on_block, dict):
        keys = on_block.keys()
    elif isinstance(on_block, list):
        keys = on_block
    elif isinstance(on_block, str):
        keys = [on_block]
    else:
        return False
    return any(t in keys for t in PR_TRIGGERS)


def _retrigger_list(review_doc: dict) -> list[str]:
    on_block = _on_block(review_doc)
    if not isinstance(on_block, dict):
        return []
    wr = on_block.get("workflow_run") or {}
    workflows = wr.get("workflows") if isinstance(wr, dict) else None
    if isinstance(workflows, str):
        return [workflows]
    if isinstance(workflows, list):
        return [str(w) for w in workflows]
    return []


def main(argv: list[str]) -> int:
    if len(argv) > 1:
        wf_dir = Path(argv[1])
    else:
        wf_dir = Path(__file__).resolve().parents[2] / ".github" / "workflows"

    if not wf_dir.is_dir():
        print(f"check-review-retrigger-coverage: no workflows dir at {wf_dir}", file=sys.stderr)
        return 1

    review_path = wf_dir / REVIEW_WF_FILENAME
    if not review_path.is_file():
        print(f"check-review-retrigger-coverage: missing {review_path}", file=sys.stderr)
        return 1

    review_doc = yaml.safe_load(review_path.read_text()) or {}
    retrigger = _retrigger_list(review_doc)
    if not retrigger:
        print(
            "check-review-retrigger-coverage: could not read a non-empty "
            "on.workflow_run.workflows list from devflow-review.yml",
            file=sys.stderr,
        )
        return 1

    gating: dict[str, str] = {}  # name -> filename
    for path in sorted(wf_dir.glob("*.yml")):
        doc = yaml.safe_load(path.read_text()) or {}
        if not _triggers_on_pr(_on_block(doc)):
            continue
        name = doc.get("name")
        if not isinstance(name, str) or not name.strip():
            print(
                f"check-review-retrigger-coverage: {path.name} triggers on a PR "
                "event but has no usable `name:` — cannot verify re-trigger coverage",
                file=sys.stderr,
            )
            return 1
        if name == SELF_WORKFLOW_NAME:
            continue  # the review workflow itself: never self-re-triggers
        gating[name] = path.name

    missing = [n for n in gating if n not in retrigger]
    if missing:
        print(
            "check-review-retrigger-coverage: these PR-gating workflows are NOT in "
            "devflow-review.yml's workflow_run re-trigger list, so a review deferred "
            "behind require_ci_green can wedge if one finishes last:",
            file=sys.stderr,
        )
        for n in missing:
            print(f"  - {n!r} (from {gating[n]})", file=sys.stderr)
        print(f"re-trigger list is: {retrigger}", file=sys.stderr)
        return 1

    print(f"re-trigger coverage OK: {sorted(gating)} all covered by {retrigger}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
