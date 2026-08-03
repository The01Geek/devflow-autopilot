#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""DevFlow review-and-fix loop-verdict marker helper (issue #1212).

The `/prflow:review-and-fix` fix loop and the `/prflow:implement` orchestrator
talk across a plugin-version boundary. When the loop finishes it prints a
one-line verdict headline to chat; the implement run reads that headline by
exact string match to decide whether the work was independently reviewed. That
contract is ordinary English prose grepped by exact words — reword one side and
a reader one version behind breaks silently, and in the dangerous direction (an
`APPROVE WITH UNRESOLVED SHADOW FINDINGS` run read as a clean approve and shipped
unreviewed).

This helper is the machine-readable half of the fix, modelled on the review
verdict marker (`scripts/post-review-verdict.sh`, issue #1030). It composes and
parses a single producer-emitted marker line:

    <!-- prflow:loop-verdict result=<result-token> coverage=<full|not-verified> -->

The marker is placed at a FIXED position — line 1 of the loop's chat output,
immediately before the human verdict headline — and the reader looks ONLY at
that line, so a marker a finding quotes deeper in the report is prose, not a
stamp. The explanatory headline prose stays exactly as it was and carries NO
new coverage: only this marker is tool-read (issues #843/#876).

NAMESPACE. `<!-- prflow:` per issue #1003, with NO superseded `devflow:` spelling
accepted anywhere: this marker postdates the rename, so no persisted artifact can
carry the old one.

RESULT tokens (closed vocabulary — the six loop-level results, space-free so a
`key=value` marker parses):

    APPROVE                                 -> approve
    APPROVE with notes                      -> approve-with-notes
    APPROVE WITH CAVEAT                     -> approve-with-caveat
    APPROVE WITH ADVISORY NOTES             -> approve-with-advisory-notes
    APPROVE WITH UNRESOLVED SHADOW FINDINGS -> approve-unresolved-shadow-findings
    REJECT                                  -> reject

COVERAGE tokens: `full` ONLY when the loop's `{shadow status}` phrase is exactly
`shadow agreed, full coverage`; every other phrase (any `shadow agreement not
verified …` variant, an empty phrase, an unrecognized one) normalizes to
`not-verified`. This direction is deliberate and fail-safe: the marker never
over-claims full coverage.

Two subcommands, both stdlib-only, no config / gh / network / git:

  compose --result "<human result>" --coverage "<shadow-status phrase>"
      Emits the marker line to stdout (exit 0). An unmappable result prints a
      stderr breadcrumb and exits 3 with NO marker — a caller that gets no line
      composes its headline prose without a marker rather than stamping a lie.

  read [FILE|-]
      Reads the chat output from FILE (or stdin) and inspects LINE 1 ONLY. Prints
      exactly one closed-vocabulary routing line and exits:

        CLEAN-FULL <result-token>          0  approve-family clean result, coverage=full
        CLEAN-NOT-VERIFIED <result-token>  0  approve-family clean result, coverage=not-verified
        AWUSF <coverage-token>             0  result=approve-unresolved-shadow-findings
        REJECT                             0  result=reject
        NO-MARKER                          2  line 1 is not a loop-verdict marker (prose fallback)
        MALFORMED <reason>                 3  marker-shaped line 1 with a bad/unknown field

      SAFE DIRECTION (issue #1212 AC5): only `CLEAN-FULL` authorizes the
      clean-and-fully-covered completion path. NO-MARKER and MALFORMED never do —
      a missing, malformed, or out-of-vocabulary marker routes the caller to its
      existing exact-wording fallback, and if that cannot resolve the verdict
      either, to the caller's existing not-clean handling. It is never read as a
      clean approve.
"""

from __future__ import annotations

import argparse
import re
import sys

MARKER_PREFIX = "<!-- prflow:loop-verdict "

# Human result string -> result token. Keys compared after collapsing internal
# whitespace runs to single spaces and stripping ends, so a headline that carries
# odd spacing still maps.
_RESULT_TO_TOKEN = {
    "approve": "approve",
    "approve with notes": "approve-with-notes",
    "approve with caveat": "approve-with-caveat",
    "approve with advisory notes": "approve-with-advisory-notes",
    "approve with unresolved shadow findings": "approve-unresolved-shadow-findings",
    "reject": "reject",
}

_RESULT_TOKENS = frozenset(_RESULT_TO_TOKEN.values())
_COVERAGE_TOKENS = frozenset({"full", "not-verified"})
# The clean approve family: every approve-family result EXCEPT the unresolved-shadow
# one, which is emphatically not a clean approval.
_CLEAN_APPROVE_TOKENS = frozenset(
    {
        "approve",
        "approve-with-notes",
        "approve-with-caveat",
        "approve-with-advisory-notes",
    }
)

_FULL_COVERAGE_PHRASE = "shadow agreed, full coverage"

_MARKER_RE = re.compile(
    r"^<!-- prflow:loop-verdict result=(?P<result>\S+) coverage=(?P<coverage>\S+) -->$"
)


def _normalize_result(raw: str) -> str | None:
    key = " ".join(raw.split()).lower()
    return _RESULT_TO_TOKEN.get(key)


def _normalize_coverage(raw: str) -> str:
    # `full` ONLY on the exact full-coverage phrase; everything else is not-verified.
    if " ".join(raw.split()).lower() == _FULL_COVERAGE_PHRASE:
        return "full"
    return "not-verified"


def _cmd_compose(args: argparse.Namespace) -> int:
    token = _normalize_result(args.result)
    if token is None:
        sys.stderr.write(
            "loop-verdict-marker: result '%s' is not one of the six loop-level "
            "results (APPROVE / APPROVE with notes / APPROVE WITH CAVEAT / "
            "APPROVE WITH ADVISORY NOTES / APPROVE WITH UNRESOLVED SHADOW FINDINGS "
            "/ REJECT) — refusing to compose a marker (no line emitted)\n"
            % args.result
        )
        return 3
    coverage = _normalize_coverage(args.coverage)
    sys.stdout.write(
        "<!-- prflow:loop-verdict result=%s coverage=%s -->\n" % (token, coverage)
    )
    return 0


def _cmd_read(args: argparse.Namespace) -> int:
    if args.file in (None, "-"):
        data = sys.stdin.read()
    else:
        try:
            with open(args.file, "r", encoding="utf-8") as fh:
                data = fh.read()
        except (OSError, UnicodeDecodeError) as exc:
            # An unreadable/undecodable input is not a decided verdict: route to the
            # prose fallback, never to clean.
            print("NO-MARKER")
            sys.stderr.write("loop-verdict-marker: could not read input: %s\n" % exc)
            return 2

    # LINE 1 ONLY — the fixed position. splitlines()[0] is line 1; an empty input
    # has no line 1.
    lines = data.splitlines()
    line1 = lines[0] if lines else ""

    if not line1.startswith(MARKER_PREFIX):
        print("NO-MARKER")
        return 2

    m = _MARKER_RE.match(line1)
    if m is None:
        print("MALFORMED marker-shaped-line-1-does-not-match-the-marker-grammar")
        return 3

    result = m.group("result")
    coverage = m.group("coverage")
    if result not in _RESULT_TOKENS:
        print("MALFORMED unknown-result-token=%s" % result)
        return 3
    if coverage not in _COVERAGE_TOKENS:
        print("MALFORMED unknown-coverage-token=%s" % coverage)
        return 3

    if result == "reject":
        print("REJECT")
        return 0
    if result == "approve-unresolved-shadow-findings":
        print("AWUSF %s" % coverage)
        return 0
    # A clean approve-family result.
    if coverage == "full":
        print("CLEAN-FULL %s" % result)
    else:
        print("CLEAN-NOT-VERIFIED %s" % result)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="loop-verdict-marker.py",
        description="Compose or read the review-and-fix loop-verdict marker (issue #1212).",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_compose = sub.add_parser("compose", help="emit the marker line for a verdict")
    p_compose.add_argument("--result", required=True, help="the loop's human result string")
    p_compose.add_argument(
        "--coverage",
        required=True,
        help="the loop's {shadow status} phrase (e.g. 'shadow agreed, full coverage')",
    )
    p_compose.set_defaults(func=_cmd_compose)

    p_read = sub.add_parser("read", help="parse line 1 of a chat output for the marker")
    p_read.add_argument("file", nargs="?", default="-", help="input file, or - for stdin")
    p_read.set_defaults(func=_cmd_read)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
