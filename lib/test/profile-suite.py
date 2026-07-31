#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Opt-in wall-clock profiler for the shell test suite (`lib/test/run.sh`).

WHY THIS EXISTS
    CI wall-clock is set by the slowest shard, and the `monolith` shard (run.sh with
    the module tier skipped) is the long pole. Nothing in the tree could answer
    "where does that time go", so tuning it meant guessing — and guessing is how a
    good assertion gets deleted for a bad reason. This makes the question answerable
    on demand, without a special expedition each time.

WHY A LAUNCHER RATHER THAN IN-SUITE TIMING CALLS
    The suite ALREADY emits a timeline: one line per section header, one line per
    assertion (`  PASS  <name>` / `  FAIL  <name>`), one per self-skip (`  NOTE  …`).
    bash flushes its stdout per builtin even through a pipe (measured: a
    `printf; sleep 1; printf` pipeline arrives at 0.00s / 1.00s, not in one block),
    so timestamping the suite's OWN output attributes elapsed time exactly, with:

      * zero edits to any assertion, its name, its order, or the emitted tally — the
        suite is byte-identical whether profiled or not, which is the strongest
        possible form of "does not change assertion behaviour or count";
      * zero cost when not profiling — this file is not read, let alone executed, by
        an ordinary run;
      * no distortion of the thing being measured — no per-command DEBUG trap, no
        subshell per timing mark.

    The alternative (a timing call at each of run.sh's section headers — ~121 of them
    match the banner shape below) would edit every one of those sites inside a file
    whose meta-assertions audit its own source shape,
    for strictly worse fidelity: it could not attribute time to INDIVIDUAL
    assertions, only to sections, and several sections span thousands of lines.

WHY NOT lib/test/shard-tally.py
    That helper parses a CAPTURED log — a file with no timestamps — and its output is
    the REQUIRED merge-gate accounting (`lib + python tests`). Timing needs live
    per-line arrival times, which only a process launcher can observe, and coupling a
    merge-gate-critical parser to an opt-in dev tool buys nothing: the two share no
    regex (shard-tally reads summary/skip/recap lines; this reads per-assertion
    lines). They are deliberately separate mechanisms over the same output contract.

THE THREE ATTRIBUTION AXES
    section   — the suite's own `echo "…"` banner lines (the labelled regions between
                the `# ── … ──` rules). What a human scrolls to.
    label     — the `#NNN` issue label carried in an assertion's NAME. This is the
                same unit `lib/test/modules/coverage-map.json` keys its
                `run_sh_blocks` on, so a per-label cost reads directly as "what would
                extracting this block into a module move off this shard".
    assertion — the individual `PASS`/`FAIL`/`NOTE` line. The finest actionable unit;
                the report maps the expensive ones back to a run.sh line number by
                looking their names up in the source (unconditional, no flag).

TIME SOURCE
    `time.monotonic()` in python3 — a hard preflight prerequisite. Deliberately NOT
    `date` (a non-preflight PATH tool, and the GNU flags for sub-second output are
    not portable) and NOT `bc`. Nothing here decides a suite result, but the same
    discipline applies: an absent tool must not silently produce a wrong number.

USAGE
    lib/test/profile-suite.py run                      # profile the monolith shard
    lib/test/profile-suite.py run --out DIR -- CMD...  # profile an arbitrary command
    lib/test/profile-suite.py report --out DIR --top 20

    POSIX-only: the child is launched with `start_new_session` + a `preexec_fn`, both
    of which raise on Windows. Profiling is a maintainer-side diagnostic, so this is a
    stated limitation rather than something the launcher works around.

    `run` writes DIR/{log.txt,events.tsv,sections.tsv,labels.tsv,assertions.tsv,
    run.json} and prints the top-N report. The child's exit status is this
    process's exit status, so a profiled run still fails the way an unprofiled one
    would. DIR defaults to `.devflow/tmp/profile/<label>` — inside `.devflow/tmp/`,
    which .gitignore already covers, so a profiled run never dirties the tree (a
    dirty tree self-skips the #434 stale-prose gate).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path

# An assertion result line as printed by run.sh's assert_eq / assert_pin_unique /
# check / the harness FAIL sites, and by skip(). Two-space indent, a status word,
# two spaces, then the assertion NAME. Anchored so a nested/quoted reproduction of
# such a line inside a fixture's captured output still parses as what it looks like
# — this is a profiler, not the merge gate, and over-attribution of a fixture's echo
# to an assertion costs a slightly mislabelled row, never a wrong pass/fail.
_RESULT_RE = re.compile(r"^  (PASS|FAIL|NOTE)  (.*)$")

# The `#NNN` issue label inside an assertion name. Mirrors the label shape
# lib/test/coverage_map_guard.py derives its `run_sh_blocks` keys from (`#(\d{2,5})`),
# so a per-label cost here lines up with a coverage-map entry rather than approximating
# one. An assertion name may carry several; each gets credited (see _labels_of).
_LABEL_RE = re.compile(r"#(\d{2,5})")

# A run.sh section banner in SOURCE position: a top-level `echo "…"` with a plain
# double-quoted literal, no expansion and no redirect. Restricting to that shape is
# what keeps a fixture's `echo '[]'` (single-quoted, inside a heredoc that writes a
# stub script) and `echo "stub: … $a" >&2` out of the banner set — both would
# otherwise let a fixture's OUTPUT masquerade as a section boundary.
_BANNER_RE = re.compile(r'^echo "([^"$\\]{8,})"\s*$')


def _repo_root(start: Path) -> Path:
    """Resolve the git repo root, falling back to the file's own grandparent.

    Matches the repo's root-anchoring convention (CLAUDE.md #295) so the profiler
    finds run.sh when invoked from a subdirectory. Uses a native `git` subprocess,
    never a `.sh` exec.
    """
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            cwd=str(start),
            capture_output=True,
            text=True,
            check=False,
        )
        if out.returncode == 0 and out.stdout.strip():
            return Path(out.stdout.strip())
    except OSError:
        pass
    return start


def _banner_set(run_sh: Path) -> "set[str]":
    """The literal texts run.sh prints as section banners.

    Derived from the SOURCE (not guessed from output shape) so an output line is
    treated as a section boundary only when run.sh actually contains a banner
    printing exactly that text. An unreadable run.sh yields an empty set: the
    profile then degrades to one `(unsectioned)` bucket plus the full per-assertion
    and per-label detail, rather than inventing boundaries.
    """
    try:
        lines = run_sh.read_text(encoding="utf-8", errors="replace").split("\n")
    except OSError as exc:  # pragma: no cover - diagnostic path
        print(f"profile-suite: cannot read {run_sh}: {exc}", file=sys.stderr)
        return set()
    banners = set()
    for line in lines:
        m = _BANNER_RE.match(line)
        if m:
            banners.add(m.group(1))
    return banners


def _labels_of(name: str) -> "list[str]":
    """Every `#NNN` label in an assertion name, deduplicated, order-preserving."""
    seen = []
    for lab in _LABEL_RE.findall(name):
        tag = "#" + lab
        if tag not in seen:
            seen.append(tag)
    return seen


class Profile:
    """Accumulates per-section / per-label / per-assertion elapsed time.

    ATTRIBUTION MODEL — stated explicitly because it decides how every number below
    is read: the gap between output line N-1 and output line N is the work that
    PRODUCED line N, and is charged to the section that was current before line N
    was printed. A banner line therefore charges its own preceding gap to the
    OUTGOING section (run.sh prints a banner before that section's work, so the gap
    before it is the previous section's trailing work), then opens the new one. Time
    after the final output line — teardown, the EXIT trap — is charged to the
    section that was current, and reported separately as `tail_s`.
    """

    def __init__(self, banners: "set[str]") -> None:
        self.banners = banners
        self.section = "(preamble)"
        self.sections: "dict[str, float]" = {}
        self.section_counts: "dict[str, int]" = {}
        self.labels: "dict[str, float]" = {}
        self.label_counts: "dict[str, int]" = {}
        self.assertions: "list[tuple[float, str, str, str]]" = []
        self.events: "list[tuple[float, float, str, str, str]]" = []
        self.counts = {"PASS": 0, "FAIL": 0, "NOTE": 0}
        self.tail_s = 0.0

    def feed(self, rel: float, delta: float, line: str) -> None:
        self.sections[self.section] = self.sections.get(self.section, 0.0) + delta
        if line in self.banners:
            self.events.append((rel, delta, "SECTION", self.section, line))
            self.section = line
            self.section_counts.setdefault(line, 0)
            return
        m = _RESULT_RE.match(line)
        if not m:
            return
        status, name = m.group(1), m.group(2)
        self.counts[status] = self.counts.get(status, 0) + 1
        self.section_counts[self.section] = self.section_counts.get(self.section, 0) + 1
        self.assertions.append((delta, self.section, status, name))
        self.events.append((rel, delta, status, self.section, name))
        for lab in _labels_of(name):
            self.labels[lab] = self.labels.get(lab, 0.0) + delta
            self.label_counts[lab] = self.label_counts.get(lab, 0) + 1

    def close(self, delta: float) -> None:
        self.tail_s = delta
        self.sections[self.section] = self.sections.get(self.section, 0.0) + delta


def _write_tsv(path: Path, header: "list[str]", rows) -> None:
    with path.open("w", encoding="utf-8") as fh:
        fh.write("\t".join(header) + "\n")
        for row in rows:
            fh.write("\t".join(str(c) for c in row) + "\n")


def _sanitize(text: str) -> str:
    """Strip TAB/CR/NEWLINE from a TSV field so one row stays one row.

    Same fail-closed shape as run.sh's own skip() sanitization: a name that arrives
    with an embedded tab would otherwise transpose the columns of a machine-read
    file.
    """
    return text.replace("\t", " ").replace("\r", " ").replace("\n", " ")


def _emit(prof: Profile, out: Path, total: float, cmd: "list[str]", rc: int) -> None:
    total = total or 1e-9
    sec_rows = [
        (f"{s:.3f}", f"{100.0 * s / total:.2f}", prof.section_counts.get(name, 0), _sanitize(name))
        for name, s in sorted(prof.sections.items(), key=lambda kv: -kv[1])
    ]
    _write_tsv(out / "sections.tsv", ["seconds", "share_pct", "assertions", "section"], sec_rows)

    lab_rows = [
        (f"{s:.3f}", f"{100.0 * s / total:.2f}", prof.label_counts.get(lab, 0), lab)
        for lab, s in sorted(prof.labels.items(), key=lambda kv: -kv[1])
    ]
    _write_tsv(out / "labels.tsv", ["seconds", "share_pct", "assertions", "issue_label"], lab_rows)

    a_rows = [
        (f"{d:.3f}", status, _sanitize(section), _sanitize(name))
        for d, section, status, name in sorted(prof.assertions, key=lambda r: -r[0])
    ]
    _write_tsv(out / "assertions.tsv", ["seconds", "status", "section", "assertion"], a_rows)

    _write_tsv(
        out / "events.tsv",
        ["t_rel_s", "delta_s", "kind", "section", "text"],
        [
            (f"{rel:.3f}", f"{d:.3f}", kind, _sanitize(sec), _sanitize(txt))
            for rel, d, kind, sec, txt in prof.events
        ],
    )

    (out / "run.json").write_text(
        json.dumps(
            {
                "command": cmd,
                "exit_code": rc,
                "total_s": round(total, 3),
                "tail_s": round(prof.tail_s, 3),
                "passed": prof.counts.get("PASS", 0),
                "failed": prof.counts.get("FAIL", 0),
                "noted": prof.counts.get("NOTE", 0),
                "sections": len(prof.sections),
                "labels": len(prof.labels),
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )


def _resolve_lines(run_sh: Path, names: "list[str]") -> "dict[str, int]":
    """Best-effort assertion-name -> run.sh line number, for the report only.

    A name is looked up as a fixed substring; the FIRST hit wins and a name that is
    composed at runtime (an interpolated variable) simply resolves to 0. Report
    garnish, never an input to any number.
    """
    try:
        lines = run_sh.read_text(encoding="utf-8", errors="replace").split("\n")
    except OSError as exc:
        # Breadcrumb, not silence — matching _banner_set's identical read. Without it a
        # column of zeroes is indistinguishable from "every name is built at runtime".
        print(f"profile-suite: cannot read {run_sh} for line resolution: {exc}", file=sys.stderr)
        return {}
    wanted = {n: 0 for n in names}
    for idx, line in enumerate(lines, start=1):
        for n in list(wanted):
            if wanted[n] == 0 and n and n in line:
                wanted[n] = idx
    return wanted


def _report(out: Path, top: int, run_sh: "Path | None") -> int:
    # `report --out DIR` exists to re-render a PRE-EXISTING directory, so a stale,
    # truncated, or hand-edited profile is its ordinary input, not an exotic one. Every
    # read below therefore degrades to this file's own `profile-suite: <reason>`
    # breadcrumb + rc 2 — the same contract the missing-run.json arm already had —
    # rather than to a raw KeyError/ValueError traceback from a half-written file.
    meta_path = out / "run.json"
    if not meta_path.is_file():
        print(f"profile-suite: no run.json in {out}", file=sys.stderr)
        return 2
    try:
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        total = float(meta["total_s"]) or 1e-9
        for key in ("exit_code", "passed", "failed", "noted", "sections", "labels"):
            meta[key] = int(meta[key])
    except (OSError, ValueError, TypeError, KeyError) as exc:
        print(f"profile-suite: unreadable or malformed {meta_path}: {exc}", file=sys.stderr)
        return 2

    def rows(name):
        """Well-formed data rows of a profile TSV, skipping any the writer did not finish.

        A row is kept only when it has at least the four columns every table in this
        file writes AND its numeric columns parse. A run killed mid-write leaves one
        short/partial trailing line; dropping it renders the rest rather than aborting
        the whole report over the row that was being written when the process died.
        """
        path = out / name
        if not path.is_file():
            print(f"profile-suite: missing {path} — table omitted", file=sys.stderr)
            return []
        try:
            body = path.read_text(encoding="utf-8").split("\n")[1:]
        except OSError as exc:
            print(f"profile-suite: unreadable {path}: {exc} — table omitted", file=sys.stderr)
            return []
        kept, dropped = [], 0
        for ln in body:
            if not ln.strip():
                continue
            cells = ln.split("\t")
            if len(cells) < 4:
                dropped += 1
                continue
            try:
                float(cells[0])
                if name != "assertions.tsv":
                    int(cells[2])
            except ValueError:
                dropped += 1
                continue
            kept.append(cells)
        if dropped:
            print(f"profile-suite: {path}: skipped {dropped} malformed row(s)", file=sys.stderr)
        return kept

    print(
        f"total {meta['total_s']:.1f}s  rc={meta['exit_code']}  "
        f"{meta['passed']} passed, {meta['failed']} failed, {meta['noted']} noted  "
        f"({meta['sections']} sections, {meta['labels']} issue labels)"
    )
    print(f"\n== top {top} sections ==")
    print(f"{'secs':>8} {'share':>7} {'#asrt':>6}  section")
    for r in rows("sections.tsv")[:top]:
        print(f"{float(r[0]):8.1f} {float(r[1]):6.2f}% {int(r[2]):6d}  {r[3]}")

    print(f"\n== top {top} issue labels (coverage-map run_sh_blocks units) ==")
    print(f"{'secs':>8} {'share':>7} {'#asrt':>6}  label")
    for r in rows("labels.tsv")[:top]:
        print(f"{float(r[0]):8.1f} {float(r[1]):6.2f}% {int(r[2]):6d}  {r[3]}")

    a = rows("assertions.tsv")[:top]
    line_of = _resolve_lines(run_sh, [r[3] for r in a]) if run_sh else {}
    print(f"\n== top {top} individual assertions ==")
    print(f"{'secs':>8} {'share':>7} {'line':>7}  assertion")
    for r in a:
        ln = line_of.get(r[3], 0)
        print(f"{float(r[0]):8.1f} {100.0 * float(r[0]) / total:6.2f}% {ln:7d}  {r[3][:110]}")
    return 0


def _run(args: argparse.Namespace) -> int:
    root = _repo_root(Path(__file__).resolve().parent)
    run_sh = root / "lib" / "test" / "run.sh"
    cmd = list(args.command) if args.command else [str(run_sh)]
    out = Path(args.out) if args.out else root / ".devflow" / "tmp" / "profile" / args.label
    out.mkdir(parents=True, exist_ok=True)

    env = dict(os.environ)
    if not args.command and not args.with_modules:
        # The CI `monolith` shard's exact invocation: the whole suite minus the module
        # tier, which the modules-* shards own. Profiling the shard as CI runs it is
        # the point; --with-modules profiles a full local run instead.
        env["DEVFLOW_SKIP_SUITE_MODULES"] = "1"

    banners = _banner_set(run_sh)
    prof = Profile(banners)
    log_path = out / "log.txt"

    # start_new_session + SIGINT restored to SIG_DFL in the child: the suite carries
    # signal-trap assertions that fail spuriously when SIGINT arrives as SIG_IGN
    # (which is what a backgrounded launch hands a child), and a child left in this
    # process's group gets SIGTERM'd mid-run. Both are the documented way to launch
    # this suite from a wrapper.
    proc = subprocess.Popen(  # noqa: S603 - argv list, no shell
        cmd,
        cwd=str(root),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        start_new_session=True,
        preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL),  # noqa: PLW1509
    )
    t0 = time.monotonic()
    prev = t0
    assert proc.stdout is not None
    with log_path.open("w", encoding="utf-8") as log:
        for raw in proc.stdout:
            now = time.monotonic()
            log.write(raw)
            line = raw.rstrip("\n")
            prof.feed(now - t0, now - prev, line)
            prev = now
            if args.tee:
                sys.stdout.write(raw)
    rc = proc.wait()
    end = time.monotonic()
    prof.close(end - prev)
    total = end - t0

    _emit(prof, out, total, cmd, rc)
    print(f"\nprofile written to {out}", file=sys.stderr)
    _report(out, args.top, run_sh)
    return rc


def main(argv: "list[str] | None" = None) -> int:
    ap = argparse.ArgumentParser(description="Opt-in wall-clock profiler for lib/test/run.sh")
    sub = ap.add_subparsers(dest="mode", required=True)

    r = sub.add_parser("run", help="profile a suite run and report")
    r.add_argument("--out", help="output directory (default .devflow/tmp/profile/<label>)")
    r.add_argument("--label", default="monolith", help="name of the default output directory")
    r.add_argument("--top", type=int, default=20, help="rows per report table")
    r.add_argument("--tee", action="store_true", help="also stream the suite output to stdout")
    r.add_argument(
        "--with-modules",
        action="store_true",
        help="profile a FULL run (do not set DEVFLOW_SKIP_SUITE_MODULES=1)",
    )
    r.add_argument("command", nargs=argparse.REMAINDER, help="-- CMD ... to profile instead")

    p = sub.add_parser("report", help="re-render the report from an existing profile dir")
    p.add_argument("--out", required=True)
    p.add_argument("--top", type=int, default=20)

    args = ap.parse_args(argv)
    if args.mode == "run":
        if args.command and args.command[0] == "--":
            args.command = args.command[1:]
        return _run(args)
    root = _repo_root(Path(__file__).resolve().parent)
    return _report(Path(args.out), args.top, root / "lib" / "test" / "run.sh")


if __name__ == "__main__":
    sys.exit(main())
