#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Run deterministic Phase 1 preflight checks for /devflow:implement.

The dependency subcommand owns the declared sequencing-dependency recognizer.
It prints one machine-readable outcome so the Phase 1 procedure can decide
before any branch setup begins.

The branch-state subcommand (issue #576, "Verdict B") classifies the
adopted/working branch against the base and emits a one-token verdict + matching
exit code, mirroring scripts/update-branch-checkpoint.sh's one-token-stdout
contract. It closes the ahead-of-base blind spot the §1.4 freshness guard leaves:
the freshness guard derives only the *behind*-by count, so a branch forked from
an unpushed local-main commit reads "behind-by-0 / up to date" while carrying
unrelated *ahead-only* history that every downstream step then treats as the
run's own (the PR #524 incident). branch-state derives the ahead-of-base count
and refuses to proceed when ahead history cannot be validated as the run's own
prior work. It is READ-ONLY with respect to history: it derives via
`git rev-list` / `git rev-parse` / `git check-ref-format` / `git merge-base` and,
on a shallow repository, a single `git fetch --unshallow` to deepen history — it
never resets, rebases, checks out, commits, merges, pushes, or deletes a branch,
so a stop verdict leaves the tree and every ref exactly as it found them.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import NoReturn


GH = os.environ.get("DEVFLOW_GH") or "gh"
# The §1.3.5 gate reads exactly three exit codes: 0 PROCEED, 2 BLOCKED (named
# dependencies still open), 3 UNAVAILABLE (an unestablished measurement — bad
# input, a failed read, or any unanticipated error). Naming them here makes the
# "exit 2 is reserved for BLOCKED" invariant a single source of truth shared by
# _Parser (usage errors route to UNAVAILABLE, never masquerade as BLOCKED),
# dependencies() (its BLOCKED return), and main()'s top-level fail-closed catch.
PROCEED_EXIT = 0
BLOCKED_EXIT = 2
UNAVAILABLE_EXIT = 3
DEPENDENCY_HEADING = re.compile(r"^##\s+Dependencies\s*$", re.IGNORECASE)
HEADING = re.compile(r"^#{1,6}\s+")
ISSUE_REF = re.compile(r"#(\d+)")
# Each declaration keyword may be followed by a run of additional numbers joined
# by "and" / "," / ", and" (Oxford) / ";" / "&", so a single declaration can name
# several dependencies: `blocked by #10 and #11`, `depends on #1, #2`,
# `blocked by #10, and #11`. The number run is captured by a uniform
# `re.findall(ISSUE_REF, match.group(0))` over the whole matched span rather than
# per-pattern capture groups (issue #547 Critical + Important #2), so no
# declaration form silently drops all but its first number. Each joiner still
# requires a following `#\d+`, so an unrelated trailing `#N` after a non-joiner
# word (`blocked by #10 — superseded by #999`) is not swept in.
_NUMBER_RUN = r"#\d+(?:\s*(?:,\s*and\s+|,\s*|;\s*|&\s*|and\s+)#\d+)*"
DECLARATIONS = tuple(
    re.compile(rf"\b{keyword}\s+{_NUMBER_RUN}", re.IGNORECASE)
    for keyword in (r"depends on", r"must merge after", r"blocked by", r"follow-up to")
)
# The bare `after #N` form is the weakest declaration: `cleanup after #5 was
# merged` / `renamed after #5` are provenance, not sequencing dependencies
# (issue #547 Important #3). Anchor it to the start of the line/bullet so an
# incidental mid-sentence "after #N" no longer spuriously BLOCKs; a genuine
# free-prose declaration ("After #5 lands, …") opens its line, and the
# `## Dependencies` section scan below still catches an in-section `after #N`
# regardless of position.
AFTER_DECLARATION = re.compile(rf"^[ \t>*\-]*after\s+{_NUMBER_RUN}", re.IGNORECASE)
# Dependency-flavoured phrasings the fixed vocabulary does NOT recognize. When a
# `#N` sits next to one of these and no declaration matched the line, emit a
# stderr breadcrumb so a missed declaration is observable (issue #547 Important
# #6) — observability only, never a new BLOCK (the line still yields no number).
SOFT_KEYWORDS = re.compile(
    r"\b(?:requires|require|needs|need|waiting on|gated on|predicated on|"
    r"prerequisite|depends upon|built on top of|built upon|based on)\b",
    re.IGNORECASE,
)


def dependency_numbers(body: str) -> list[str]:
    """Return unique declared dependency numbers in source order."""
    found: list[str] = []

    def add(number: str) -> None:
        if number not in found:
            found.append(number)

    in_dependencies = False
    for line in body.splitlines():
        if DEPENDENCY_HEADING.match(line):
            in_dependencies = True
            continue
        if in_dependencies and HEADING.match(line):
            in_dependencies = False
        if in_dependencies:
            for number in ISSUE_REF.findall(line):
                add(number)
            continue
        # Accumulate every declaration match on the line (no early `break`): a
        # line can carry more than one declaration — `depends on #1, blocked by
        # #2` names both (issue #547 Important #2).
        spans = [m.group(0) for pattern in DECLARATIONS for m in pattern.finditer(line)]
        after_match = AFTER_DECLARATION.match(line)
        if after_match:
            spans.append(after_match.group(0))
        for span in spans:
            for number in ISSUE_REF.findall(span):
                add(number)
        if not spans and SOFT_KEYWORDS.search(line):
            for number in dict.fromkeys(ISSUE_REF.findall(line)):
                print(
                    f"preflight.py: unrecognized dependency-flavoured reference to "
                    f"#{number} — not a declared sequencing dependency; if it is one, "
                    f"restate it as `depends on #{number}` / `blocked by #{number}` "
                    f"or list it under a `## Dependencies` section",
                    file=sys.stderr,
                )
    return found


def _gh_issue_view(number: object, field: str) -> str:
    """Run `gh issue view <number> --json <field> -q .<field>` and return stdout.

    encoding="utf-8" with errors="replace" so non-ASCII issue bodies decode and a
    body carrying invalid UTF-8 bytes never raises UnicodeDecodeError (a ValueError
    subclass none of the callers' except-clauses catch). Left unreplaced, that error
    would propagate to main()'s catch-all handler and be converted to a spurious
    UNAVAILABLE/exit 3 — a contained WRONG verdict that would REPLACE the true
    BLOCKED/PROCEED result, not a crash or exit-1 escape (issue #547 review).
    The caller owns the error policy (issue_body raises, issue_state swallows).
    """
    result = subprocess.run(
        [GH, "issue", "view", str(number), "--json", field, "-q", f".{field}"],
        check=True,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
    )
    return result.stdout


def issue_body(issue: int) -> str:
    try:
        return _gh_issue_view(issue, "body")
    except (OSError, subprocess.CalledProcessError) as exc:
        detail = exc.stderr.strip() if isinstance(exc, subprocess.CalledProcessError) else str(exc)
        raise RuntimeError(f"could not read issue body: {detail}") from exc


def issue_state(number: str) -> str | None:
    try:
        state = _gh_issue_view(number, "state").strip()
    except (OSError, subprocess.CalledProcessError):
        return None
    return state if state in {"OPEN", "CLOSED", "MERGED"} else None


def dependencies(args: argparse.Namespace) -> int:
    # `is not None`, not truthiness: an explicit empty `--body-file ""` must read
    # the (empty) file path and fail closed on that path's own read error, not fall
    # through to the issue branch and call `issue_body(None)` — which would run
    # `gh issue view None` and misreport the failure as an issue-fetch problem
    # (PR #572 review). Both arms still fail closed to UNAVAILABLE; this keeps the
    # diagnostic pointed at the surface the caller actually named.
    if args.body_file is not None:
        try:
            # errors="replace": a body file with invalid UTF-8 bytes decodes to
            # replacement chars and is still scanned for real #N declarations,
            # rather than raising UnicodeDecodeError (a ValueError the `except
            # OSError` below does not catch) — which main()'s catch-all would then
            # convert to a spurious UNAVAILABLE/exit 3, REPLACING the true
            # BLOCKED/PROCEED verdict (a contained wrong verdict, issue #547 review).
            body = Path(args.body_file).read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            print(f"preflight.py: could not read dependency body: {exc}", file=sys.stderr)
            print("UNAVAILABLE body", flush=True)
            return UNAVAILABLE_EXIT
    else:
        try:
            body = issue_body(args.issue)
        except RuntimeError as exc:
            print(f"preflight.py: {exc}", file=sys.stderr)
            print("UNAVAILABLE issue", flush=True)
            return UNAVAILABLE_EXIT

    numbers = dependency_numbers(body)
    if not numbers:
        print("PROCEED")
        return PROCEED_EXIT

    open_numbers: list[str] = []
    for number in numbers:
        state = issue_state(number)
        if state is None:
            print(f"preflight.py: could not resolve declared dependency #{number}", file=sys.stderr)
            print(f"UNAVAILABLE {number}")
            return UNAVAILABLE_EXIT
        if state == "OPEN":
            open_numbers.append(number)

    if open_numbers:
        print(f"BLOCKED {','.join(open_numbers)}")
        return BLOCKED_EXIT

    print(f"PROCEED {','.join(numbers)}")
    return PROCEED_EXIT


# ── branch-state (Verdict B, issue #576) ─────────────────────────────────────
# Exit codes reuse the dependency contract's three classes so the §1.4 caller
# reads ONE exit vocabulary across both subcommands:
#   FRESH / VALIDATED_RESUME      → PROCEED_EXIT (0)   proceed to §1.4.1/§1.5
#   AMBIGUOUS / DECISION_BLOCKED  → BLOCKED_EXIT (2)   stop before push/checkpoint
#   UNAVAILABLE <reason>          → UNAVAILABLE_EXIT (3) unestablished measurement
# The two-payload verdicts (AMBIGUOUS/DECISION_BLOCKED) additionally print a
# `<verdict> <payload-file>` where the payload file captures the gathered +
# derived state and the classification reason for the human deciding the stop.

# The workpad front-matter Branch line: `**Branch:** `<name>`` (a real branch)
# or `**Branch:** _(creating…)_` (the 1.3 placeholder, no backticks). Match the
# LABEL to enumerate every Branch line (duplicate detection), then extract the
# first fully-closed backtick span as the recorded name. A line with no closed
# backtick span (the placeholder, or a truncated body that lost its closing
# backtick) yields no recorded name — treated as absent, never as a partial name.
_BRANCH_LABEL = re.compile(r"^\s*\*\*Branch:\*\*", re.MULTILINE)
_BRANCH_BACKTICK = re.compile(r"`([^`]+)`")


def _run_git(args: list[str]) -> subprocess.CompletedProcess[str]:
    """Run a git subcommand on the current checkout, capturing text output.

    encoding/errors mirror _gh_issue_view so an exotic ref name or commit message
    never raises UnicodeDecodeError into main()'s catch-all (a spurious UNAVAILABLE
    that would REPLACE a real verdict). check=False: every caller inspects
    returncode explicitly — a non-zero git exit is data here (a ref that does not
    resolve, a non-ancestor), not an error to raise.
    """
    return subprocess.run(
        ["git", *args],
        check=False,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
    )


def _ref_resolves(ref: str) -> bool:
    """True when `ref` names a resolvable commit."""
    return _run_git(["rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"]).returncode == 0


def parse_recorded_branch(body: str) -> tuple[str | None, bool]:
    """Parse the workpad Branch line. Returns (recorded_name_or_None, duplicate).

    A missing/placeholder/truncated Branch line yields (None, False) — absent.
    More than one Branch line yields (None, True) — the body is ambiguous and no
    single recorded name can be trusted (a marker-forged or corrupted workpad).
    """
    lines = [line for line in body.splitlines() if _BRANCH_LABEL.match(line)]
    if not lines:
        return (None, False)
    if len(lines) > 1:
        return (None, True)
    match = _BRANCH_BACKTICK.search(lines[0])
    if not match:
        return (None, False)  # placeholder or truncated — no closed backtick span
    name = match.group(1).strip()
    # A backtick span holding only a placeholder-shaped value is still "absent".
    if not name or name.startswith("_("):
        return (None, False)
    return (name, False)


def _derive_ahead(base: str) -> tuple[int | None, str]:
    """Ahead-of-base count for HEAD, with shallow unshallow-once-then-rederive.

    Returns (ahead, "") on success, or (None, reason) on an unestablished
    measurement: reason "base" when origin/<base> does not resolve (the caller's
    fetch never landed it), "count" when rev-list cannot produce an integer even
    after deepening a shallow history. Mirrors update-branch-checkpoint.sh: a
    shallow view can UNDERcount ahead-of-base (the merge base may lie beyond the
    shallow boundary), so on a shallow repository deepen the base ref exactly once
    and re-derive — the post-unshallow count is authoritative.
    """
    base_ref = f"refs/remotes/origin/{base}"
    if not _ref_resolves(base_ref):
        return (None, "base")

    def count() -> int | None:
        result = _run_git(["rev-list", "--count", f"{base_ref}..HEAD"])
        value = result.stdout.strip()
        if result.returncode != 0 or not value.isdigit():
            return None
        return int(value)

    ahead = count()
    if _run_git(["rev-parse", "--is-shallow-repository"]).stdout.strip() == "true":
        # Deepen the base ref specifically (fetch-depth cloud checkouts download
        # only the feature ref's history), then re-derive. A fetch failure leaves
        # the shallow count in place rather than erroring — best-effort deepening.
        _run_git(["fetch", "--unshallow", "origin", f"+refs/heads/{base}:{base_ref}"])
        redone = count()
        if redone is not None:
            ahead = redone
    if ahead is None:
        return (None, "count")
    return (ahead, "")


def _published_tip_reachable(current_branch: str) -> bool:
    """True when HEAD is reachable from the branch's published tip.

    origin/<current_branch> reaching HEAD means the branch's ahead commits are
    published under this branch's own name — the strong "this is our own prior
    work" signal a validated resume needs. A branch not yet pushed (no such
    remote ref) is not reachable, so this stays False and the caller cannot reach
    VALIDATED_RESUME on it.
    """
    tip = f"refs/remotes/origin/{current_branch}"
    if not _ref_resolves(tip):
        return False
    return _run_git(["merge-base", "--is-ancestor", "HEAD", tip]).returncode == 0


def _branch_exists(name: str) -> bool | None:
    """Existence probe for a recorded branch name. True/False, or None on error.

    None distinguishes a PROBE FAILURE (git cannot evaluate the ref because the
    recorded NAME is malformed — a space, empty, or otherwise ref-invalid value a
    corrupted/forged workpad can carry) from a CLEAN-EMPTY result (a well-formed
    name that simply is not a ref → False). The caller routes a probe failure to
    UNAVAILABLE and a clean-empty divergent name to DECISION_BLOCKED, so the two
    must never collapse. `git check-ref-format` owns the name-validity contract
    (a malformed name → non-zero) and `git rev-parse` owns existence — because
    both `show-ref --verify` (with --quiet) and `rev-parse --verify` report a
    malformed name and a well-formed-but-absent name with the SAME exit code, so
    neither alone can make this distinction.
    """
    local, remote = f"refs/heads/{name}", f"refs/remotes/origin/{name}"
    for ref in (local, remote):
        if _run_git(["check-ref-format", ref]).returncode != 0:
            return None  # malformed name — existence is unestablishable, not "absent"
    for ref in (local, remote):
        if _ref_resolves(ref):
            return True
    return False


def _write_payload(verdict: str, reason: str, state: dict, derived: dict) -> str:
    """Write the stop-verdict payload file and return its path.

    Captures the gathered state, the internally-derived values, and the
    classification reason so the human deciding the AMBIGUOUS/DECISION_BLOCKED
    stop has the full picture. delete=False: the file outlives this process for
    the caller/human to read; the caller owns its lifetime.
    """
    handle = tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", prefix="devflow-branch-state-", suffix=".json", delete=False
    )
    with handle:
        json.dump({"verdict": verdict, "reason": reason, "state": state, "derived": derived}, handle, indent=2)
    return handle.name


def _classify_branch_state(state: dict) -> tuple[str, str, dict]:
    """Return (verdict, reason, derived). The branch-state decision orchestrator.

    Reads the caller-gathered `state` and derives the git-side facts it needs
    lazily (ahead-of-base count, published-tip reachability, recorded-branch
    existence) — each git helper is invoked only on the paths that consume it, so
    this is not a pure function of `state`; it touches the current checkout via
    git. Verdict vocabulary: FRESH, VALIDATED_RESUME, AMBIGUOUS, DECISION_BLOCKED,
    UNAVAILABLE. The reason is a stable slug (empty for the proceed verdicts).
    """
    base = state["base"]
    current_branch = state["current_branch"]
    ahead, ahead_err = _derive_ahead(base)
    derived: dict = {"ahead": ahead}
    if ahead is None:
        return ("UNAVAILABLE", ahead_err, derived)
    if ahead == 0:
        # No commits ahead of base: a fresh branch, or an adopted branch
        # fast-forwarded to base. Nothing unrelated to validate — proceed. This is
        # also the warm-start case (a gate-pre-created workpad, no work committed).
        return ("FRESH", "", derived)

    # ahead > 0: the branch carries commits not on the base. They are legitimate
    # only if they are this run's own prior work; otherwise §1.5 would publish
    # foreign history into the PR (the PR #524 incident). Validate before proceed.
    if not state.get("provenance_established", False):
        # The workpad's recorded branch / verdict are the only signals that could
        # vouch for the ahead history, and unestablished provenance means they may
        # be marker-forged — so they cannot be trusted to validate anything.
        return ("DECISION_BLOCKED", "unverified-provenance", derived)

    recorded, duplicate = parse_recorded_branch(state.get("workpad_body", ""))
    derived["recorded_branch"] = recorded
    if duplicate:
        return ("AMBIGUOUS", "duplicate-branch-line", derived)

    has_verdict = bool(state.get("has_proceed_verdict", False))

    # Published-tip reachability is only consulted on the absent and matching
    # arms below; the divergent arm never reads it, so it is derived inside those
    # arms rather than eagerly (avoids a wasted rev-parse + merge-base pair on the
    # divergent path).
    if recorded is None:
        # Absent / placeholder / truncated Branch line. A prior proceed verdict
        # PLUS a published tip still vouches for the ahead history even without a
        # recorded name; anything less is a human decision.
        tip_reachable = _published_tip_reachable(current_branch)
        derived["published_tip_reachable"] = tip_reachable
        if has_verdict and tip_reachable:
            return ("VALIDATED_RESUME", "", derived)
        return ("AMBIGUOUS", "no-recorded-branch", derived)

    if recorded == current_branch:
        if has_verdict:
            tip_reachable = _published_tip_reachable(current_branch)
            derived["published_tip_reachable"] = tip_reachable
            if tip_reachable:
                return ("VALIDATED_RESUME", "", derived)
            return ("AMBIGUOUS", "matching-verdict-tip-unreachable", derived)
        return ("AMBIGUOUS", "matching-without-verdict", derived)

    # Divergent: the recorded branch is not the working branch.
    exists = _branch_exists(recorded)
    derived["recorded_branch_exists"] = exists
    if exists is None:
        return ("UNAVAILABLE", "existence-probe", derived)
    if not exists:
        # The workpad names a branch that does not exist — a corrupted or forged
        # record; refuse rather than adopt ahead history against a phantom.
        return ("DECISION_BLOCKED", "divergent-nonexistent", derived)
    if has_verdict:
        return ("AMBIGUOUS", "divergent-existing-with-verdict", derived)
    return ("DECISION_BLOCKED", "divergent-without-verdict", derived)


def _unavailable_state(message: str) -> int:
    """Emit a state-input UNAVAILABLE: a specific stderr cause + the fixed token.

    Every branch-state input-validation failure fails closed to the SAME contract
    — `UNAVAILABLE state` on stdout, `UNAVAILABLE_EXIT` — with only the stderr
    cause varying; routing them through one helper keeps that contract single-sited
    (the classify-path `UNAVAILABLE <reason>` emit stays separate: its token varies).
    """
    print(f"preflight.py: {message}", file=sys.stderr)
    print("UNAVAILABLE state", flush=True)
    return UNAVAILABLE_EXIT


def branch_state(args: argparse.Namespace) -> int:
    # `is not None`: an explicit `--state-file ""` reads the (empty) path and fails
    # closed on that read, never falls through to a phantom default (mirrors the
    # dependency subcommand's body-file discipline).
    if args.state_file is None:
        return _unavailable_state("branch-state requires --state-file")
    try:
        raw = Path(args.state_file).read_text(encoding="utf-8")
    except OSError as exc:
        return _unavailable_state(f"could not read branch-state file: {exc}")
    try:
        state = json.loads(raw)
    except json.JSONDecodeError as exc:
        return _unavailable_state(f"branch-state file is not valid JSON: {exc}")
    if not isinstance(state, dict):
        return _unavailable_state("branch-state file must be a JSON object")
    base = state.get("base")
    current_branch = state.get("current_branch")
    if not isinstance(base, str) or not base or not isinstance(current_branch, str) or not current_branch:
        return _unavailable_state("branch-state requires non-empty string 'base' and 'current_branch'")

    verdict, reason, derived = _classify_branch_state(state)
    if verdict == "UNAVAILABLE":
        print(f"preflight.py: branch-state could not establish '{reason}' — no verdict", file=sys.stderr)
        print(f"UNAVAILABLE {reason}", flush=True)
        return UNAVAILABLE_EXIT
    if verdict in ("FRESH", "VALIDATED_RESUME"):
        print(verdict, flush=True)
        return PROCEED_EXIT
    # AMBIGUOUS / DECISION_BLOCKED — a stop with a payload for the human.
    payload = _write_payload(verdict, reason, state, derived)
    print(f"preflight.py: branch-state {verdict} ({reason}); state written to {payload}", file=sys.stderr)
    print(f"{verdict} {payload}", flush=True)
    return BLOCKED_EXIT


class _Parser(argparse.ArgumentParser):
    """Exit usage errors with UNAVAILABLE_EXIT, not argparse's default 2.

    BLOCKED_EXIT (2) is the contract code the Phase 1 §1.3.5 gate maps to "named
    dependencies are still open". A malformed invocation (bad/empty --issue,
    neither input flag) must not masquerade as that verdict — it is an
    unestablished measurement, so route it to the UNAVAILABLE class
    (UNAVAILABLE_EXIT). The override is scoped to error()-routed failures; every
    non-help exit today flows through error().
    """

    def error(self, message: str) -> NoReturn:
        self.print_usage(sys.stderr)
        self.exit(UNAVAILABLE_EXIT, f"{self.prog}: error: {message}\n")


def main() -> int:
    parser = _Parser(description=__doc__)
    # Make the exit-3 (UNAVAILABLE) contract explicit rather than relying on
    # add_subparsers() defaulting parser_class to type(self): the subparser is
    # what raises `--issue notanint` / both-flags usage errors, so its exit code
    # must route through _Parser.error() → exit 3, not argparse's default 2
    # (which is the BLOCKED contract code). Issue #547 Important #5.
    subparsers = parser.add_subparsers(dest="command", required=True, parser_class=_Parser)
    dependency_parser = subparsers.add_parser("dependencies")
    input_group = dependency_parser.add_mutually_exclusive_group(required=True)
    input_group.add_argument("--issue", type=int)
    input_group.add_argument("--body-file")
    dependency_parser.set_defaults(func=dependencies)
    branch_state_parser = subparsers.add_parser("branch-state")
    branch_state_parser.add_argument("--state-file")
    branch_state_parser.set_defaults(func=branch_state)
    args = parser.parse_args()
    try:
        return args.func(args)
    except Exception as exc:  # noqa: BLE001 - fail closed: any unanticipated error
        # An unanticipated exception would otherwise exit 1 — a fourth code
        # outside the {0,2,3} contract the §1.3.5 gate reads, which enumerates no
        # "other exit code" arm. Route it to UNAVAILABLE (never a silent PROCEED)
        # so any failure stays inside the contract. A SystemExit raised inside the
        # try (argparse's own exits happen in parse_args() above it, and _Parser
        # maps usage errors to UNAVAILABLE_EXIT) is BaseException, not Exception,
        # so it would propagate untouched. Surface the exception TYPE, not just its
        # payload, so a contained programming bug stays debuggable from the one
        # stderr breadcrumb the gate leaves.
        print(f"preflight.py: unexpected error: {type(exc).__name__}: {exc}", file=sys.stderr)
        print("UNAVAILABLE", flush=True)
        return UNAVAILABLE_EXIT


if __name__ == "__main__":
    raise SystemExit(main())
