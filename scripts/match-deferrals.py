#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""DevFlow deferred-findings matcher for /devflow:review's Phase 4.0.

Reads the Scope-Acknowledged Findings block from a PR body (between the
DEVFLOW_DEFERRED_FINDINGS_START/END markers), validates each deferral
against three guards, and matches the survivors against the current run's
Phase 3 findings. Emits a JSON demotion map the verdict engine consumes
to demote matched findings to Informational.

Guards (any failing guard rejects the deferral — finding flows through as
normal):
    1. Trusted filer:     PR author is in `devflow.allowed_bots` from
                          .devflow/config.json.
    2. Mutual cross-link: follow-up issue exists, is open, and its body
                          contains the substring "PR #<N>" (where N is the
                          current PR number).
    3. Widens surface:    PR's current diff does not overlap the deferral's
                          file within ±10 lines of its line_range.

Matching rule (v1, conservative): a current finding matches a surviving
deferral iff same file AND same kind AND line_range overlaps within ±25
lines. Summary similarity is not used — file+kind+line_range is strong
enough to prevent false positives, and a more permissive rule would risk
demoting genuinely new findings that share vague terminology.

Usage:
    match-deferrals.py --pr N --diff PATH --findings (PATH | -) [--config PATH]

Pass `--findings -` to read the findings JSON from stdin. The stdin form is
required when the caller cannot write a temp file (e.g., /devflow:review
under devflow.yml's runner `review` profile, which is intentionally
read-only and does not have the Write tool).

Output (JSON to stdout, always exit 0 when the helper itself ran):
    {
      "block_present": true | false,
      "pr_author_trusted": true | false | null,
      "honored": [
        {"finding_index": 0, "deferral_id": "dfr-...",
         "follow_up_issue": 47, "category": "out-of-scope"}
      ],
      "rejected_deferrals": [
        {"deferral_id": "dfr-...", "reason": "<one of: ...>"}
      ],
      "stats": {
        "total_deferrals": 3, "valid_after_guards": 2,
        "honored": 2, "unmatched": 0
      }
    }

Exit codes:
    0  Helper ran successfully (regardless of match results).
    2  Bad arguments / unrecoverable input error.
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

LINE_DRIFT_TOLERANCE = 25
WIDENS_SURFACE_TOLERANCE = 10
BLOCK_START = "<!-- DEVFLOW_DEFERRED_FINDINGS_START -->"
BLOCK_END = "<!-- DEVFLOW_DEFERRED_FINDINGS_END -->"
PAYLOAD_START = "<!-- DEVFLOW_DEFERRED_PAYLOAD"
DEFAULT_CONFIG = ".devflow/config.json"

# Rejection reason codes — mirrored verbatim in skills/review/SKILL.md prose.
# Edit both in lockstep.
REASON_UNTRUSTED_FILER = "untrusted-filer"
REASON_MISSING_FOLLOW_UP_ISSUE = "missing-follow-up-issue"
REASON_ISSUE_UNREADABLE = "issue-unreadable"
REASON_ISSUE_CLOSED = "issue-closed"
REASON_UNLINKED_FOLLOWUP = "unlinked-followup"
REASON_WIDENS_SURFACE = "widens-surface"
REASON_UNMATCHED = "unmatched"


def _fail(msg, code=2):
    sys.stderr.write(f"match-deferrals.py: {msg}\n")
    sys.exit(code)


def _run(cmd, *, check=True):
    # `encoding="utf-8"` pins the gh-output decode: this wrapper reads PR and
    # issue *bodies* (`gh pr view --json body`, `gh issue view --json body`),
    # which are routinely non-ASCII, so decoding through the locale codec would
    # raise UnicodeDecodeError under a non-UTF-8 ambient codec (Windows' cp1252).
    # Implies text mode, so `text=True` is dropped (passing both is redundant).
    return subprocess.run(
        cmd, check=check,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, encoding="utf-8",
    )


def _config_get(key: str, default: str = "", config_path: str = DEFAULT_CONFIG) -> str:
    here = Path(__file__).resolve().parent
    helper = here / "config-get.sh"
    r = _run([str(helper), key, default, config_path], check=False)
    if r.returncode != 0:
        return default
    return r.stdout.strip()


def _extract_block(pr_body: str) -> str | None:
    if BLOCK_START not in pr_body or BLOCK_END not in pr_body:
        return None
    start = pr_body.index(BLOCK_START) + len(BLOCK_START)
    end = pr_body.index(BLOCK_END, start)
    return pr_body[start:end]


def _parse_yaml_payload(block: str) -> dict:
    """Parse the YAML payload from the hidden DEVFLOW_DEFERRED_PAYLOAD comment.

    The PR-description renderer shows a human-readable Markdown table inside the
    START/END markers and stores the exact machine payload in a hidden HTML
    comment so it stays invisible in the rendered PR body. The schema is
    unchanged (schema_version + deferrals[]); only the payload's location moved
    out of a visible ```yaml fence into this comment.
    """
    try:
        import yaml
    except ImportError:
        _fail("PyYAML required to parse deferred-findings block")

    payload_match = re.search(
        re.escape(PAYLOAD_START) + r"\s*\n(.*?)\n-->", block, re.DOTALL
    )
    if not payload_match:
        # The START/END markers exist (we are inside the extracted block), so a
        # payload comment is expected. Its absence means the renderer dropped or
        # malformed it (e.g. an unterminated comment) — warn so a visibly-deferred
        # PR with no machine payload is diagnosable rather than silently honoring
        # nothing. Still degrade gracefully to {} (no run failure).
        sys.stderr.write(
            "match-deferrals.py: deferrals block present but no parseable "
            "DEVFLOW_DEFERRED_PAYLOAD comment found; ignoring the block\n"
        )
        return {}
    try:
        loaded = yaml.safe_load(payload_match.group(1))
    except yaml.YAMLError as e:
        sys.stderr.write(f"match-deferrals.py: YAML parse failed: {e}\n")
        return {}
    if loaded is None:
        # Payload comment present but empty/whitespace-only — same operator-visible
        # outcome as a missing comment (block present, nothing honored), so warn
        # for the same diagnosability reason.
        sys.stderr.write(
            "match-deferrals.py: DEVFLOW_DEFERRED_PAYLOAD comment is empty; "
            "ignoring the block\n"
        )
        return {}
    if not isinstance(loaded, dict):
        sys.stderr.write(
            "match-deferrals.py: payload is not a mapping; ignoring\n"
        )
        return {}
    return loaded


def _get_pr_body_and_author(pr_number: int) -> tuple[str, str]:
    r = _run(
        ["gh", "pr", "view", str(pr_number),
         "--json", "body,author", "--jq",
         "[.body, (.author.login // \"\")] | @json"],
        check=False,
    )
    if r.returncode != 0:
        _fail(f"could not read PR #{pr_number}: {r.stderr.strip()}")
    body, author = json.loads(r.stdout.strip())
    return body, author


def _check_issue_cross_link(issue_number: int, pr_number: int) -> str | None:
    """Returns None if valid, else a rejection reason string."""
    r = _run(
        ["gh", "issue", "view", str(issue_number),
         "--json", "body,state", "--jq",
         "[.body, .state] | @json"],
        check=False,
    )
    if r.returncode != 0:
        return REASON_ISSUE_UNREADABLE
    body, state = json.loads(r.stdout.strip())
    if state.upper() != "OPEN":
        return REASON_ISSUE_CLOSED
    if f"PR #{pr_number}" not in body:
        return REASON_UNLINKED_FOLLOWUP
    return None


def _parse_diff_hunks(diff_text: str) -> dict:
    """Returns {file_path: [(start_line, end_line), ...]} for added/modified
    lines on the new side. Conservative — includes both add and context lines
    in the hunk range, which over-approximates the affected region (safe for
    widens-surface — false positives reject deferrals, never honor them
    incorrectly).
    """
    hunks: dict[str, list[tuple[int, int]]] = {}
    current_file: str | None = None
    file_re = re.compile(r"^\+\+\+ b/(.+)$")
    hunk_re = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")

    for line in diff_text.splitlines():
        m = file_re.match(line)
        if m:
            current_file = m.group(1)
            hunks.setdefault(current_file, [])
            continue
        m = hunk_re.match(line)
        if m and current_file:
            start = int(m.group(1))
            length = int(m.group(2) or "1")
            end = start + max(length - 1, 0)
            hunks[current_file].append((start, end))
    return hunks


def _widens_surface(deferral: dict, hunks: dict) -> bool:
    file_path = deferral.get("finding", {}).get("file")
    line_range = deferral.get("finding", {}).get("line_range") or []
    if not file_path or len(line_range) != 2:
        return False
    start, end = line_range
    file_hunks = hunks.get(file_path, [])
    for h_start, h_end in file_hunks:
        if (h_start - WIDENS_SURFACE_TOLERANCE) <= end and \
           (h_end + WIDENS_SURFACE_TOLERANCE) >= start:
            return True
    return False


def _ranges_overlap(a: list, b: list, tolerance: int) -> bool:
    if len(a) != 2 or len(b) != 2:
        return False
    return (a[0] - tolerance) <= b[1] and (a[1] + tolerance) >= b[0]


def _match_finding_to_deferral(finding: dict, deferral: dict) -> bool:
    df = deferral.get("finding", {})
    if finding.get("file") != df.get("file"):
        return False
    if finding.get("kind") != df.get("kind"):
        return False
    return _ranges_overlap(
        finding.get("line_range") or [],
        df.get("line_range") or [],
        LINE_DRIFT_TOLERANCE,
    )


def _force_utf8_streams():
    """Force stdout/stderr to UTF-8, idempotently and defensively, in the CLI
    entry path only (not at import — so unit-test imports don't mutate the
    importer's global streams). Harmless where this script emits only ASCII, but
    keeps every first-party helper self-defending against a non-UTF-8 ambient
    codec (Windows' cp1252). The guard tolerates a non-`TextIOWrapper` stream."""
    for _stream in (sys.stdout, sys.stderr):
        try:
            _stream.reconfigure(encoding="utf-8")
        except (AttributeError, ValueError):
            pass


def main(argv=None):
    _force_utf8_streams()
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--pr", type=int, required=True,
                   help="PR number whose body holds the deferrals block.")
    p.add_argument("--diff", required=True,
                   help="Path to the cached diff (for widens-surface check).")
    p.add_argument("--findings", required=True,
                   help="Path to JSON file with current Phase 3 findings, "
                        "or `-` to read from stdin.")
    p.add_argument("--config", default=DEFAULT_CONFIG,
                   help="Path to config.json (default: %(default)s).")
    args = p.parse_args(argv)

    diff_path = Path(args.diff)
    if args.findings == "-":
        raw_findings = sys.stdin.read()
        if not raw_findings.strip():
            _fail("--findings - was passed but stdin was empty")
    else:
        findings_path = Path(args.findings)
        if not findings_path.is_file():
            _fail(f"findings file not found: {findings_path}")
        raw_findings = findings_path.read_text(encoding="utf-8")
    try:
        findings = json.loads(raw_findings)
    except json.JSONDecodeError as e:
        _fail(f"findings input is not valid JSON: {e}")
    if not isinstance(findings, list):
        _fail("findings input must be a JSON array")

    pr_body, pr_author = _get_pr_body_and_author(args.pr)
    block = _extract_block(pr_body)

    result = {
        "block_present": block is not None,
        "pr_author_trusted": None,
        "honored": [],
        "rejected_deferrals": [],
        "stats": {"total_deferrals": 0, "valid_after_guards": 0,
                  "honored": 0, "unmatched": 0},
    }

    if block is None:
        print(json.dumps(result, indent=2))
        return 0

    payload = _parse_yaml_payload(block)
    deferrals = payload.get("deferrals") or []
    result["stats"]["total_deferrals"] = len(deferrals)

    if not deferrals:
        print(json.dumps(result, indent=2))
        return 0

    allowed_bots_raw = _config_get(".devflow.allowed_bots", "", args.config)
    allowed_bots = {b.strip() for b in allowed_bots_raw.split(",") if b.strip()}
    pr_author_trusted = pr_author in allowed_bots if allowed_bots else False
    result["pr_author_trusted"] = pr_author_trusted

    if not pr_author_trusted:
        for d in deferrals:
            result["rejected_deferrals"].append({
                "deferral_id": d.get("id", "(no-id)"),
                "reason": REASON_UNTRUSTED_FILER,
            })
        print(json.dumps(result, indent=2))
        return 0

    hunks = {}
    if diff_path.is_file():
        hunks = _parse_diff_hunks(
            diff_path.read_text(encoding="utf-8", errors="replace")
        )

    valid_deferrals: list[dict] = []
    for d in deferrals:
        deferral_id = d.get("id", "(no-id)")
        follow_up = d.get("follow_up") or {}
        issue_n = follow_up.get("issue")
        if not isinstance(issue_n, int):
            result["rejected_deferrals"].append({
                "deferral_id": deferral_id,
                "reason": REASON_MISSING_FOLLOW_UP_ISSUE,
            })
            continue

        cross_link_reason = _check_issue_cross_link(issue_n, args.pr)
        if cross_link_reason:
            result["rejected_deferrals"].append({
                "deferral_id": deferral_id,
                "reason": cross_link_reason,
            })
            continue

        if _widens_surface(d, hunks):
            result["rejected_deferrals"].append({
                "deferral_id": deferral_id,
                "reason": REASON_WIDENS_SURFACE,
            })
            continue

        valid_deferrals.append(d)

    result["stats"]["valid_after_guards"] = len(valid_deferrals)

    claimed_finding_indices: set[int] = set()
    for d in valid_deferrals:
        matched_index = None
        for i, finding in enumerate(findings):
            if i in claimed_finding_indices:
                continue
            if _match_finding_to_deferral(finding, d):
                matched_index = i
                break
        if matched_index is None:
            result["rejected_deferrals"].append({
                "deferral_id": d.get("id", "(no-id)"),
                "reason": REASON_UNMATCHED,
            })
            continue
        claimed_finding_indices.add(matched_index)
        result["honored"].append({
            "finding_index": matched_index,
            "deferral_id": d.get("id", "(no-id)"),
            "follow_up_issue": d.get("follow_up", {}).get("issue"),
            "category": d.get("reason", {}).get("category", "(unspecified)"),
        })

    result["stats"]["honored"] = len(result["honored"])
    result["stats"]["unmatched"] = sum(
        1 for r in result["rejected_deferrals"] if r["reason"] == REASON_UNMATCHED
    )

    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
