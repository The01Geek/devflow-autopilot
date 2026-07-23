#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Guard the lib/test CI-shellcheck lint carve-out (issue #717).

`.github/workflows/ci.yml` lints the repo's shell scripts with shellcheck. The
`git ls-files '*.sh' | grep -v '^lib/test/'` glob deliberately EXCLUDES `lib/test/`
(its gh-stub fixtures are intentionally unlinted), and the excluded shipped files
are then re-added by a hand-maintained explicit list plus a dedicated job for
`lib/test/run.sh`. Nothing guarded that hand-maintained list, so a new
`lib/test/**/*.sh` file that was neither added to the list nor deliberately left a
fixture silently shipped unlinted.

This guard reconciles the two sides. It reads ci.yml, derives the set of
`lib/test/**/*.sh` files CI actually lints (the union of every literal `lib/test/*`
argument to a direct `shellcheck` invocation), and fails naming the offending path
when any tracked `lib/test/**/*.sh` file is neither in that set nor under the single
declared exempt prefix `lib/test/fixtures/`.

It is a BEST-EFFORT reader of a human-maintained YAML file, so it fails CLOSED on
every shape it cannot interpret (unreadable/empty/non-YAML ci.yml; no shellcheck
invocation locatable; the `git ls-files '*.sh'` glob's `lib/test/` exclusion changed
from the exact recognized form) rather than reporting full coverage from the
explicit list alone. A red guard is the safe direction: it forces human attention.

Exit 0 = every tracked lib/test file is CI-linted or under the exempt prefix.
Exit 1 = a fail-closed condition, or an offending uncovered non-exempt file.
The verdict line is printed to stdout (`OK` / `FAIL: <reason>`); details go to stderr.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

# The single declared exempt prefix. A tracked lib/test file under this prefix is
# deliberately unlinted (adversarial/malformed fixtures live here); anything else
# must be CI-linted. This is EXACTLY one prefix and no other path (AC, issue #717).
EXEMPT_PREFIX = "lib/test/fixtures/"

# The exact `grep -v` exclusion expression the glob invocation must carry for the
# derivation to trust that the `git ls-files '*.sh'` glob contributes ZERO lib/test
# coverage. If the glob feeds shellcheck but this exact expression is absent (removed
# or narrowed), the guard cannot reason about what the glob now lints, so it fails
# closed rather than deriving coverage from the explicit list alone (AC, issue #717).
RECOGNIZED_GLOB_EXCLUSION = "^lib/test/"


class GuardError(Exception):
    """A fail-closed condition: the guard could not establish coverage."""


def _strip_shell_comments(text: str) -> str:
    """Drop shell comments so a lib/test path named ONLY in a comment is not counted
    as covered (AC, issue #717). Removes full-line `#` comments and an inline ` #...`
    tail. Best-effort: a lib/test path is a bare token that never contains ` #`, so a
    naive inline strip cannot swallow a real argument."""
    out = []
    for line in text.split("\n"):
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        # inline comment: a ' #' preceded by whitespace starts a comment tail here.
        m = re.search(r"\s#", line)
        if m:
            line = line[: m.start()]
        out.append(line)
    return "\n".join(out)


def _collect_run_blocks(ci_text: str) -> str:
    """Parse ci.yml and return every step `run:` block joined. Fails closed on a
    non-YAML / empty / non-mapping document (AC malformed-shape rows)."""
    try:
        import yaml  # lazy: PyYAML is a preflight prerequisite
    except Exception as exc:  # pragma: no cover - preflight guarantees PyYAML
        raise GuardError(f"PyYAML unavailable to parse .github/workflows/ci.yml: {exc}")
    try:
        doc = yaml.safe_load(ci_text)
    except Exception as exc:
        raise GuardError(f".github/workflows/ci.yml is not valid YAML: {exc}")
    if not isinstance(doc, dict) or not doc:
        raise GuardError(".github/workflows/ci.yml is empty or not a YAML mapping")
    jobs = doc.get("jobs")
    if not isinstance(jobs, dict):
        raise GuardError(".github/workflows/ci.yml has no `jobs:` mapping")
    runs: list[str] = []
    for job in jobs.values():
        if not isinstance(job, dict):
            continue
        for step in job.get("steps") or []:
            if isinstance(step, dict) and isinstance(step.get("run"), str):
                runs.append(step["run"])
    return "\n".join(runs)


def _shellcheck_invocations(cleaned: str) -> list[str]:
    """Return each direct `shellcheck ...` invocation as one joined-continuation
    string. `cleaned` is the comment-stripped, continuation-joined run-block text
    (produced once by the caller)."""
    invocations: list[str] = []
    # A shellcheck command begins at a `shellcheck` token that starts a command
    # (line start, after `|`, `;`, `&&`, `||`, or `xargs [-r] `). Capture to the next
    # newline (its arguments are all on the joined line).
    for line in cleaned.split("\n"):
        for m in re.finditer(r"(?:^|\||;|&&|\|\||xargs(?:\s+-\w+)*\s+)\s*shellcheck\b", line):
            invocations.append(line[m.end():])
    return invocations


def _glob_exclusion_ok(cleaned: str) -> bool:
    """True iff a `git ls-files '*.sh'` pipeline that feeds shellcheck carries the
    EXACT recognized `grep -v '^lib/test/'` exclusion. If such a glob pipeline exists
    but its exclusion differs (removed/narrowed), return False → fail closed. `cleaned`
    is the comment-stripped, continuation-joined run-block text (produced once by the
    caller)."""
    # Find a `git ls-files '*.sh'` pipeline that eventually reaches shellcheck.
    glob_lines = [
        ln
        for ln in cleaned.split("\n")
        if re.search(r"git\s+ls-files\s+'\*\.sh'", ln) and "shellcheck" in ln
    ]
    if not glob_lines:
        # No glob feeding shellcheck at all — the derivation does not depend on it,
        # so there is nothing to distrust. (A ci.yml with NO shellcheck anywhere is
        # caught separately as "no invocation locatable".)
        return True
    for ln in glob_lines:
        m = re.search(r"grep\s+-v\s+'([^']*)'", ln)
        if not m or m.group(1) != RECOGNIZED_GLOB_EXCLUSION:
            return False
    return True


def derive_ci_linted(ci_text: str) -> set[str]:
    """Derive the set of lib/test/**/*.sh paths CI lints. Raises GuardError on any
    fail-closed condition."""
    run_text = _collect_run_blocks(ci_text)
    # Comment-strip + join line-continuations ONCE; both derivations below read it.
    cleaned = _strip_shell_comments(run_text).replace("\\\n", " ")
    invocations = _shellcheck_invocations(cleaned)
    if not invocations:
        raise GuardError(
            "could not locate any shellcheck invocation in "
            ".github/workflows/ci.yml (fail-closed: not reporting coverage)"
        )
    if not _glob_exclusion_ok(cleaned):
        raise GuardError(
            "the `git ls-files '*.sh'` glob's lib/test/ exclusion is not the exact "
            f"recognized form `grep -v '{RECOGNIZED_GLOB_EXCLUSION}'` in "
            ".github/workflows/ci.yml (fail-closed: cannot derive coverage from the "
            "explicit list alone)"
        )
    linted: set[str] = set()
    for seg in invocations:
        for tok in re.findall(r"lib/test/[A-Za-z0-9_./-]+\.sh", seg):
            linted.add(tok)
    return linted


def tracked_lib_test_scripts(repo_root: Path) -> list[str]:
    """Enumerate tracked lib/test/**/*.sh via index-reading `git ls-files` (issue
    #711: never a recursive filesystem walk, which would descend into sibling
    worktrees under .claude/worktrees/ and count their copies)."""
    out = subprocess.run(
        ["git", "ls-files", "lib/test/*.sh", "lib/test/**/*.sh"],
        cwd=str(repo_root),
        capture_output=True,
        text=True,
    )
    if out.returncode != 0:
        raise GuardError(f"git ls-files failed enumerating lib/test scripts: {out.stderr.strip()}")
    seen: list[str] = []
    for line in out.stdout.splitlines():
        p = line.strip()
        if p and p not in seen:
            seen.append(p)
    return seen


def check(ci_text: str, files: list[str]) -> tuple[bool, str]:
    """Return (ok, message). ok=False on the first offending file. Fail-closed
    conditions propagate as GuardError to the caller."""
    linted = derive_ci_linted(ci_text)
    for f in files:
        if f.startswith(EXEMPT_PREFIX):
            continue  # deliberately-unlinted fixture side of the partition
        if f in linted:
            continue  # CI-linted side of the partition
        return (
            False,
            f"FAIL: {f} is a tracked lib/test/**/*.sh file that CI does not lint and "
            f"that is NOT under the exempt prefix `{EXEMPT_PREFIX}` — it landed on the "
            "not-CI-linted, not-exempt side of the partition. Add it to a shellcheck "
            "invocation in .github/workflows/ci.yml, or (if it is a deliberately "
            f"unlintable fixture) move it under {EXEMPT_PREFIX}.",
        )
    return (True, "OK")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--repo-root", default=".", help="repository root (default: cwd)")
    ap.add_argument(
        "--ci-file",
        default=None,
        help="workflow file to analyse (default: <repo-root>/.github/workflows/ci.yml)",
    )
    ap.add_argument(
        "--files-file",
        default=None,
        help="newline-separated list of lib/test paths to check "
        "(default: derived via `git ls-files` at --repo-root). Used by synthetic tests.",
    )
    args = ap.parse_args(argv)

    repo_root = Path(args.repo_root)
    ci_path = Path(args.ci_file) if args.ci_file else repo_root / ".github/workflows/ci.yml"

    try:
        try:
            ci_text = ci_path.read_text(encoding="utf-8")
        except OSError as exc:
            raise GuardError(f"could not read {ci_path}: {exc}")

        if args.files_file:
            files = [
                ln.strip()
                for ln in Path(args.files_file).read_text(encoding="utf-8").splitlines()
                if ln.strip()
            ]
        else:
            files = tracked_lib_test_scripts(repo_root)

        ok, message = check(ci_text, files)
    except GuardError as exc:
        print(f"FAIL: {exc}")
        print(f"lint-carveout-guard: {exc}", file=sys.stderr)
        return 1

    print(message)
    if not ok:
        print(message, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
