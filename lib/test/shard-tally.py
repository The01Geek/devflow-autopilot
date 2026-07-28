#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Per-shard tally extraction and cross-shard recombination for the concurrent CI
job matrix (issue #877).

The required merge-gate check `lib + python tests` used to be a single sequential
job running `bash lib/test/run.sh`. It is now satisfied by several shard jobs
running concurrently, recombined by an aggregator job that keeps that exact name.
This helper is the transport-and-recombine layer:

  extract  — parse ONE shard's captured log (plus its process exit code) into a
             small tally directory: the shard's passed/failed/skipped counts, the
             verbatim skip-detail lines, and the failure-identifier lines. Written
             so the shard can upload it as an artifact.

  combine  — read every shard's tally directory, SUM the counts, and render the
             same `N passed, M failed[, K skipped]` summary the single job printed,
             followed by one line per skipped check and a failure recap. Preserves
             the skip population and its per-check detail exactly (issue #456: a
             skipped check is never laundered into a clean pass). Exits non-zero if
             any shard failed, any shard exited non-zero, or any tally is missing or
             malformed — the aggregator FAILS CLOSED, so a lost shard never reads as
             a green merge gate.

Parsing keys on the two stable, unit-tested summary contracts:
  * lib/test/summary.sh   — `N passed, M failed[, K skipped]` + `  SKIP  ...` lines
  * lib/test/run-module.sh — `Module <id>: N passed, M failed`

The counts and the pass/fail DECISION are derived here in python3 (a hard preflight
prerequisite), never through a non-preflight PATH tool (CLAUDE.md guard-class 2).
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# A run.sh final summary line (from lib/test/summary.sh). Anchored to a whole line.
_BARE_SUMMARY = re.compile(r"^(\d+) passed, (\d+) failed(?:, (\d+) skipped)?$")
# A run-module.sh per-module summary line (one per module in a group shard).
_MODULE_SUMMARY = re.compile(r"^Module (\S+): (\d+) passed, (\d+) failed$")
# The skip-itemization lines summary.sh prints after the real summary.
_SKIP_LINE = re.compile(r"^  SKIP  (.*)$")
# The failure-recap header both run.sh and run-module.sh print.
_RECAP_HEADER = "Failure recap:"
# A failure-recap bullet (`  - <identifier>`), common to both formats.
_RECAP_BULLET = re.compile(r"^  - (.*)$")

_TALLY_KEYS = ("shard", "passed", "failed", "skipped", "rc")


def _parse_log(lines: list[str]) -> tuple[int, int, int, list[str], list[str], list[str]]:
    """Return (passed, failed, skipped, skip_details, failure_names, warnings).

    Positional, not global, on purpose: run.sh drives summary.sh over fixtures, so
    its captured output contains many `N passed, M failed` and `  SKIP  ` lines that
    are NOT the real run. The real summary is the LAST bare-format line (the final
    devflow_render_test_summary call runs after every assertion); the real skip
    itemization and failure recap are the lines that follow it. Module-group shards
    carry no bare summary — their counts come from summing every `Module <id>:` line.
    """
    passed = failed = skipped = 0
    warnings: list[str] = []

    # Module tier: sum every per-module summary line (a group shard has >= 1).
    saw_module = False
    for line in lines:
        m = _MODULE_SUMMARY.match(line)
        if m:
            saw_module = True
            passed += int(m.group(2))
            failed += int(m.group(3))

    # Monolith tier: the LAST bare-format summary line is the real run.sh summary.
    last_summary_idx = -1
    for idx, line in enumerate(lines):
        if _BARE_SUMMARY.match(line):
            last_summary_idx = idx
    if last_summary_idx >= 0:
        m = _BARE_SUMMARY.match(lines[last_summary_idx])
        assert m is not None
        passed += int(m.group(1))
        failed += int(m.group(2))
        skipped += int(m.group(3)) if m.group(3) is not None else 0

    # Skip detail: the `  SKIP  ` lines AFTER the real summary, up to the recap
    # header or EOF. Scoping to the tail excludes summary.sh's own self-test
    # fixtures, which emit `  SKIP  ` lines earlier in the capture.
    skip_details: list[str] = []
    if last_summary_idx >= 0:
        for line in lines[last_summary_idx + 1:]:
            if line.strip() == _RECAP_HEADER:
                break
            sm = _SKIP_LINE.match(line)
            if sm:
                skip_details.append(sm.group(1))

    # Failure identifiers: the `  - ` bullets after any `Failure recap:` header
    # (run.sh prints one at the tail; run-module.sh prints one per failing module).
    failure_names: list[str] = []
    in_recap = False
    for line in lines:
        if line.strip() == _RECAP_HEADER:
            in_recap = True
            continue
        if in_recap:
            bm = _RECAP_BULLET.match(line)
            if bm:
                failure_names.append(bm.group(1))
            elif line.startswith("    "):
                # A continuation of a run-module bullet (expected/actual); ignore.
                continue
            else:
                in_recap = False

    if last_summary_idx < 0 and not saw_module:
        warnings.append(
            "no recognizable summary line found in the shard log "
            "(neither run.sh's 'N passed, M failed' nor 'Module <id>: ...')"
        )

    return passed, failed, skipped, skip_details, failure_names, warnings


def _read_tally(dir_path: Path) -> dict[str, str]:
    """Read a tally directory's `summary` file into a dict. Missing keys are absent."""
    summary_path = dir_path / "summary"
    values: dict[str, str] = {}
    text = summary_path.read_text(encoding="utf-8")
    for line in text.splitlines():
        if "\t" not in line:
            continue
        key, _, val = line.partition("\t")
        values[key] = val
    return values


def _write_lines(path: Path, lines: list[str]) -> None:
    path.write_text("".join(f"{ln}\n" for ln in lines), encoding="utf-8")


def cmd_extract(args: argparse.Namespace) -> int:
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    try:
        raw = Path(args.log).read_text(encoding="utf-8", errors="replace")
    except OSError as error:
        # A missing/unreadable log is itself a shard failure — record it so combine
        # fails closed rather than silently dropping the shard's contribution.
        raw = ""
        lines: list[str] = []
        warnings = [f"could not read shard log {args.log}: {error}"]
        passed = failed = skipped = 0
        skip_details: list[str] = []
        failure_names: list[str] = []
    else:
        lines = raw.splitlines()
        passed, failed, skipped, skip_details, failure_names, warnings = _parse_log(lines)

    rc = args.rc

    # Fail closed: a shard whose process exited non-zero but whose parsed failed
    # count is 0 (e.g. run.sh's fail-closed underivable-tally abort, or a crash
    # before the summary) must still count as a failure, or a red shard would
    # recombine as green. Synthesize one so the count and the recap agree.
    if rc != 0 and failed == 0:
        failed = 1
        failure_names.append(
            f"{args.shard}: shard process exited with status {rc} "
            "but no failed assertion was parsed (fail-closed synthetic failure)"
        )
    # A shard that produced no recognizable summary at all is also a failure.
    if warnings and failed == 0:
        failed = 1
        failure_names.append(f"{args.shard}: {warnings[0]}")

    summary_lines = [
        f"shard\t{args.shard}",
        f"passed\t{passed}",
        f"failed\t{failed}",
        f"skipped\t{skipped}",
        f"rc\t{rc}",
    ]
    _write_lines(out_dir / "summary", summary_lines)
    _write_lines(out_dir / "skips", skip_details)
    _write_lines(out_dir / "names", failure_names)

    for w in warnings:
        print(f"shard-tally extract [{args.shard}]: WARNING: {w}", file=sys.stderr)
    print(
        f"shard-tally extract [{args.shard}]: {passed} passed, {failed} failed, "
        f"{skipped} skipped (rc={rc})"
    )
    return 0 if failed == 0 and rc == 0 else 1


def _collect_dirs(args: argparse.Namespace) -> list[Path]:
    dirs: list[Path] = [Path(d) for d in args.dirs]
    if args.scan:
        parent = Path(args.scan)
        if parent.is_dir():
            for child in sorted(parent.iterdir()):
                if (child / "summary").is_file():
                    dirs.append(child)
    return dirs


def cmd_combine(args: argparse.Namespace) -> int:
    dirs = _collect_dirs(args)
    if args.expect is not None and len(dirs) < args.expect:
        # A shard that never uploaded its tally (crashed/cancelled before the upload
        # step) would otherwise be invisible here — combine would sum the survivors
        # and could report green over an incomplete run. Fail closed on a shortfall.
        print(
            f"shard-tally combine: expected {args.expect} shard tally directories "
            f"but found {len(dirs)} — a shard is missing; refusing to report a "
            "green gate over an incomplete run",
            file=sys.stderr,
        )
        return 1
    if not dirs:
        print(
            "shard-tally combine: no shard tally directories given "
            "(--scan found none, and no positional dirs) — refusing to report a "
            "green gate over zero shards",
            file=sys.stderr,
        )
        return 1

    total_pass = total_fail = total_skip = 0
    all_skips: list[str] = []
    all_names: list[str] = []
    shard_names: list[str] = []
    problems: list[str] = []

    for d in dirs:
        try:
            values = _read_tally(d)
        except OSError as error:
            problems.append(f"{d}: tally unreadable ({error})")
            continue
        missing = [k for k in _TALLY_KEYS if k not in values]
        if missing:
            problems.append(f"{d}: tally missing key(s): {', '.join(missing)}")
            continue
        try:
            p = int(values["passed"])
            f = int(values["failed"])
            k = int(values["skipped"])
            rc = int(values["rc"])
        except ValueError:
            problems.append(f"{d}: non-integer count in tally")
            continue
        shard_names.append(values["shard"])
        total_pass += p
        total_fail += f
        total_skip += k
        if rc != 0:
            # rc-carried failure with no counted failure (belt-and-braces; extract
            # already synthesizes one, but a hand-authored/partial tally might not).
            problems.append(f"{values['shard']}: shard exited non-zero (rc={rc})")
        for sk in (d / "skips").read_text(encoding="utf-8").splitlines():
            all_skips.append(sk)
        for nm in (d / "names").read_text(encoding="utf-8").splitlines():
            all_names.append(nm)

    # Render the combined summary in the single-job format.
    if total_skip == 0:
        print(f"{total_pass} passed, {total_fail} failed")
    else:
        print(f"{total_pass} passed, {total_fail} failed, {total_skip} skipped")
        for sk in all_skips:
            print(f"  SKIP  {sk}")
        # The announced skip tally and the itemized lines must agree (issue #456).
        if len(all_skips) != total_skip:
            print(
                f"  SKIP  (skip tally {total_skip} disagrees with "
                f"{len(all_skips)} itemized skip line(s) across shards — the skip "
                "population of this run is unverified)"
            )
            problems.append("skip tally/detail disagreement across shards")

    if total_fail > 0:
        print()
        print("Failure recap:")
        for nm in all_names:
            print(f"  - {nm}")

    print()
    print(f"shard-tally combine: {len(shard_names)} shard(s): {', '.join(shard_names)}")

    if problems:
        print()
        for pr in problems:
            print(f"shard-tally combine: PROBLEM: {pr}", file=sys.stderr)

    # Fail closed: any counted failure, any shard problem (missing/malformed tally,
    # non-zero rc), or a skip disagreement fails the aggregate.
    return 0 if total_fail == 0 and not problems else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    ex = sub.add_parser("extract", help="parse one shard log into a tally directory")
    ex.add_argument("--shard", required=True, help="shard name")
    ex.add_argument("--log", required=True, help="captured shard log path")
    ex.add_argument("--rc", type=int, required=True, help="shard process exit code")
    ex.add_argument("--out", required=True, help="output tally directory")
    ex.set_defaults(func=cmd_extract)

    co = sub.add_parser("combine", help="recombine shard tallies into one summary")
    co.add_argument("dirs", nargs="*", help="shard tally directories")
    co.add_argument("--scan", help="a parent dir; every child holding a summary file is a shard tally")
    co.add_argument("--expect", type=int, help="fail closed unless at least this many shard tallies are present")
    co.set_defaults(func=cmd_combine)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
