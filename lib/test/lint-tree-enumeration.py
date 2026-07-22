#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Fail the suite when a tracked file under `lib/test/` enumerates the repository
tree with a recursive walk that has not been declared.

Why this exists (issue #711): a repository-root-anchored recursive filesystem walk
descends into every sibling git worktree under `.claude/worktrees/` — this
repository's own working mode, since `EnterWorktree` creates every worktree it
makes there. A suite assertion built on such a walk then counts the worktrees'
copies of whatever it is trying to prove unique, and fails locally with a number
that has nothing to do with the repository's state. CI never sees it: a fresh
`actions/checkout` has no `.claude/worktrees/`, so the required job stays green
while every local run in a worktree-carrying checkout eats a red suite. The
durable population source is an **index-reading** `git ls-files` — no `--others`,
whose working-tree enumeration is worktree-immune only through untracked
`.git/info/exclude` state that no clone inherits.

This guard does not bar a recursive walk. Its violation condition is a candidate
token carrying no marker, and it never judges what a marker's reason claims — so
what it buys is a reviewable, greppable declaration at the desk. A marked walk
still ships; it ships visibly. The marker is `# tree-walk-ok: <reason>`, the third
member of the declaration-marker family this repository already applies through
`# raw-guard-ok:` and `# structural-pin-ok:`.

Audited population, closed by enumeration:

* The tracked files under `lib/test/` whose suffix is `.py`, and the tracked files
  under `lib/test/` whose suffix is `.sh`, less this guard's own path.
  `lib/test/fixtures/**` is **inside** that population: a fixture is as able to
  carry a real walk as any other file.
* The population's complement is unaudited and that is deliberate: `scripts/` and
  the non-test `lib/` helpers are outside this guard entirely. They are not
  covered elsewhere.

Candidate token set, closed by enumeration:

* the literal `rglob(`;
* the literal `os.walk(`;
* the literal `iglob(`;
* a call carrying the keyword `recursive=True`;
* a `glob(`-family call any of whose arguments — at any nesting depth inside the
  call — is a string literal containing a `**` component. The depth-descending
  test is deliberate: `glob.glob(os.path.join(root, "skills", "**", "SKILL.md"))`
  puts the `**` in a *separate* argument from the `glob` call, so a test requiring
  the two in one literal would miss it entirely;
* a `glob(`-family call whose pattern argument is not a string literal — a call with
  **no positional argument at all** (`p.glob(pattern=x)`) is not a candidate, since
  there is no pattern argument to judge;
* a shell `find`, and a shell `grep -r` or `grep -R`, **any** of whose path operands
  textually contains a repository-root-resolving fragment at any position.

The shell arm's fragments are matched by **property, not by an allowlist of exact
spellings**: `$LIB/..`, the bare substring `ROOT`, `REPO_ROOT`, and an operand that
is `.` or begins with `./`. `ROOT` is matched as a bare substring rather than as
`$ROOT` precisely so a root reached through a differently-named variable is still
seen — `grep -r … "$DGH_ROOT/scripts"`, whose variable was assigned
`"$(cd "$LIB/.." && pwd)"`, matches on that substring. **Every** path operand is
tested rather than a computed "first" one, because selecting one requires an option
table that would drift: under a first-operand rule
`grep -r --include '*.sh' NEEDLE "$ROOT"` and `find -maxdepth 2 "$ROOT"` both walk
past the real path. `grep`'s **pattern** — its first non-option token — is the one
token deliberately excluded, since it is text to search for, not a path.

Accepted residuals, each stated with its own reason rather than folded together:

* **Shell-arm complement.** A `find` or `grep -r` whose root operand reaches the
  repository root **without** any of those textual fragments — through a
  fully-resolved absolute path, or through a variable whose name this fragment
  match does not see — is an accepted residual, not a covered case. The fragment
  test is textual; it resolves nothing.
* **Root indirection.** A walk whose enumeration *root* arrives through an
  assignment hop the receiver test does not recognize is unaudited. The Python
  arms never inspect the receiver of a `glob(`-family call at all, so a walk
  rooted at a variable is judged only by its pattern.
* **Pattern indirection.** Separately from the above, a walk whose *pattern*
  arrives through an assignment hop is unaudited past the non-literal-pattern arm:
  that arm flags a non-literal pattern at the call site, but a pattern assembled
  earlier and passed in as a plain name is flagged only because it is non-literal,
  never because of what it contains. Root indirection and pattern indirection are
  two distinct escapes and neither implies the other.
* **This guard's own path** is excluded from the audited population. Its source
  must contain the candidate token literals in order to detect them, and those
  literals sit in string constants rather than comments, so the comment-aware rule
  does not reach them. Marking them instead would put a marker on a line that
  declares nothing.
* **Index-only population.** Because the population is index-reading `git ls-files`
  with no `--others`, a violation living in an untracked working file is invisible
  until it is added to the index. That is the price of worktree immunity and is
  paid deliberately.
* **Embedded Python inside shell.** A `.sh` file is scanned with the literal arms
  and the shell arm, never the AST arms — so a `glob()` call with a `**` component
  embedded in a `python3 -c` body is reached only if it also carries one of the
  literal tokens.
* **Head indirection.** A shell walk whose *head* arrives through a variable —
  `$GREP -r … "$ROOT"`, the shape this repository's own `DEVFLOW_GH`/`DEVFLOW_JQ`
  resolver convention would produce — is not seen: both the substring pre-filter and
  the head test compare against the literal names `find`/`grep`. This is the shell
  arm's analogue of root and pattern indirection, and is listed separately because it
  escapes at the *head*, not at an operand.
* **A bare `find` with no path operand.** GNU `find` defaults to `.`; BSD `find`
  requires the operand. Because the defaulting is not portable, no operand is
  synthesized and the call is not flagged. `grep`'s implicit `.` **is** synthesized,
  because it is required by POSIX rather than a GNU extension.
* **Python string-literal prose.** The comment-awareness rule strips `#` comments
  only, so a candidate token inside a module docstring or any other triple-quoted
  string is scanned as code and would demand a marker. Prose in a `#` comment is
  free; prose in a `\"\"\"` block is not.

Usage:
    lint-tree-enumeration.py [--root DIR] [--files-from PATH]

Exit status is 0 only when every selected file was read and none of them carried
an undeclared candidate. It is non-zero when a violation is found, when the
enumeration is unusable, and when any selected path could not be read or parsed —
callers distinguish them by reading the report, never the exit code.
"""

from __future__ import annotations

import argparse
import ast
import importlib.util
import os
import re
import subprocess
import sys
from pathlib import Path

# Reuse the issue-#363 extractor's quote/substitution/tokenization machinery — the same
# import `extract-command-shapes.py` and `lint-gh-api-repo-path.py` use, and for the same
# reason: a fourth independent notion of "a shell statement" in lib/test/ would drift, and
# this guard would then disagree with its siblings about where a command head begins. It is
# what reaches a `find`/`grep -r` head hidden behind an assignment and a substitution
# (`VAR="$(grep -rlF … "$ROOT/scripts")"`), which a bare whitespace split never sees.
_HEADS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "extract-command-heads.py")
_spec = importlib.util.spec_from_file_location("extract_command_heads", _HEADS_PATH)
_heads = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_heads)

#: The format-strict declaration marker. A line carrying the bare substring
#: `tree-walk-ok` without this comment form does **not** exempt it.
TREE_WALK_OK_MARKER = "# tree-walk-ok:"

#: This guard's own path, excluded from the audited population. See the docstring.
SELF_PATH = "lib/test/lint-tree-enumeration.py"

#: The audited population's prefix and suffixes.
AUDITED_PREFIX = "lib/test/"
AUDITED_SUFFIXES = (".py", ".sh")

#: Literal candidate tokens, scanned in both `.py` and `.sh` sources.
LITERAL_TOKENS = ("rglob(", "os.walk(", "iglob(", "recursive=True")

#: The `glob(`-family call names the AST arms recognize.
GLOB_CALL_NAMES = ("glob", "iglob", "rglob")

#: Textual fragments that make a shell path operand repository-root-resolving.
#: Matched as bare substrings — see the docstring on why `ROOT` is not `$ROOT`.
ROOT_FRAGMENTS = ("$LIB/..", "ROOT", "REPO_ROOT")  # REPO_ROOT is subsumed by ROOT; kept because the enumeration IS the contract

#: A `grep` recursion flag, in long form or inside a combined short cluster.
_GREP_RECURSIVE = re.compile(r"^--recursive$|^--dereference-recursive$|^-[A-Za-z]*[rR]")

#: A marker whose reason is non-empty. The reason is never interpreted.
_MARKER_RE = re.compile(re.escape(TREE_WALK_OK_MARKER) + r"\s*\S")


class EnumerationError(Exception):
    """The audited population could not be established. Always fails closed."""


def enumerate_population(root: Path, files_from: Path | None) -> list[str]:
    """Return the repo-relative paths to consider, before exclusions.

    Raises `EnumerationError` when the source cannot be read or yields nothing —
    the two arms that must never be mistaken for a clean audit. The git arm is
    index-reading (`git ls-files` with no `--others`), which is the whole point of
    this guard: a working-tree enumeration at the repository root is exactly the
    worktree-permeable shape it exists to remove.
    """
    if files_from is not None:
        try:
            raw = files_from.read_text(encoding="utf-8")
        except OSError as exc:
            raise EnumerationError(
                f"--files-from list could not be read ({files_from}): {exc}"
            ) from exc
    else:
        try:
            proc = subprocess.run(
                ["git", "ls-files"],
                cwd=str(root),
                capture_output=True,
                text=True,
                check=False,
            )
        except OSError as exc:
            raise EnumerationError(f"git ls-files could not be run: {exc}") from exc
        if proc.returncode != 0:
            raise EnumerationError(
                "git ls-files exited "
                f"{proc.returncode}: {proc.stderr.strip() or '(no stderr)'}"
            )
        raw = proc.stdout

    # Strip ONLY the line terminator: a path with leading/trailing spaces is legal in
    # git, and trimming it would yield a path that cannot open — silently dropping a
    # real file from the audit through the skip arm below.
    paths = [line.rstrip("\r\n") for line in raw.split("\n") if line.rstrip("\r\n")]
    if not paths:
        raise EnumerationError(
            "the enumeration yielded zero paths before any exclusion was applied"
        )
    return paths


def is_audited(path: str) -> bool:
    """True when `path` survives the population exclusions."""
    normalized = path.replace("\\", "/")
    if normalized == SELF_PATH:
        return False
    if not normalized.startswith(AUDITED_PREFIX):
        return False
    return normalized.endswith(AUDITED_SUFFIXES)


def _read(path: Path) -> tuple[str | None, str | None]:
    """Return `(text, skip_reason)` — exactly one of the two is None.

    Decoding is explicitly lossy (`errors="replace"`), so a tracked file that is
    not valid UTF-8 is scanned to completion rather than raising: the audited
    population contains one such file today, planted as an adversarial fixture for
    a different lint. An unopenable path is a reported skip, never an absorbed one —
    "audited nothing" must never read as "audited everything, found nothing".

    Deliberate divergence from `lint-gh-api-repo-path.py`'s sibling reader, recorded
    so the two are not mistaken for a stale copy: that one additionally skips a
    NUL-carrying file as "not a UTF-8-superset text file". This population is the
    tracked `.py`/`.sh` files under `lib/test/` — sources, never binaries — and the
    governing acceptance criterion requires an explicit lossy decode that raises on
    no tracked file, so a NUL arm here would add a skip path (and with it a non-zero
    exit) that nothing in this population can legitimately reach.
    """
    try:
        data = path.read_bytes()
    except OSError as exc:
        return None, f"unreadable ({exc.__class__.__name__}: {exc})"
    return data.decode("utf-8", errors="replace").replace("\r\n", "\n"), None


def _comment_split(line: str) -> tuple[str, str]:
    """Return `(code, comment_tail)` for one raw line, quote- and escape-aware.

    A `#` introduces a comment only at a **word boundary** — line start, or preceded
    by whitespace. Without that rule a shell parameter expansion (`${rel#*/}`,
    `${x##*/}`) reads as a comment and everything after it is deleted from the code
    half, so a real walk sharing that logical line becomes invisible and the guard
    reports clean over it. Those expansions are ordinary idiom throughout this
    population, so the naive form fails open exactly where this guard claims to fail
    closed. A backslash escapes the next character, so `\\"` no longer desynchronises
    the quote state for the remainder of the line.
    """
    split = _split_at_hash(line, quotes_active=True)
    if split is not None:
        return split
    # Quote-aware scanning left a quote open at end of line, so this line's quote
    # state is not self-contained — the commonest cause is a `\`-continued shell
    # statement whose opening quote is on an earlier line. Scanning it as if the
    # quote were still open would swallow a real trailing comment (and with it the
    # declaration marker), so re-scan with quotes inert and let the word-boundary
    # rule alone decide. Precision is retained on every line whose quotes balance,
    # which is the case the string-literal exemption hole lives in.
    fallback = _split_at_hash(line, quotes_active=False)
    return fallback if fallback is not None else (line, "")


def _split_at_hash(line: str, quotes_active: bool) -> tuple[str, str] | None:
    """Split at the first comment-introducing `#`, or None if quotes were left open."""
    quote: str | None = None
    index = 0
    while index < len(line):
        char = line[index]
        # A backslash escapes the next character, so `\"` no longer desynchronises the
        # quote state for the rest of the line — except inside single quotes, where
        # both shell and this population's regex idiom take it literally.
        if char == "\\" and quote != "'":
            index += 2
            continue
        if quote is not None:
            if char == quote:
                quote = None
            index += 1
            continue
        if quotes_active and char in ("'", '"'):
            quote = char
            index += 1
            continue
        if char == "#" and (index == 0 or line[index - 1].isspace()):
            return line[:index], line[index:]
        index += 1
    return None if quote is not None else (line, "")


def strip_comment(line: str) -> str:
    """Return `line` with any trailing comment removed, quote-aware.

    Candidate detection reads this stripped form, so a token that appears only
    inside a comment is not a candidate — prose describing a walk needs no marker.
    """
    return _comment_split(line)[0]


def has_marker(line: str) -> bool:
    """True when `line` carries a format-strict marker with a reason IN ITS COMMENT.

    The marker is tested against the comment tail alone, never the whole raw line:
    the contract calls it a format-strict *comment* marker, and a raw-line search
    lets a string literal that merely contains the marker text — `x = ["# tree-walk-ok:
    y", root.rglob("*")]` — exempt a real walk on that same line. The sibling
    `pin-corpus-lint.py` marker is quote-aware for the same reason.
    """
    return bool(_MARKER_RE.search(_comment_split(line)[1]))


def fold_continuations(lines: list[tuple[int, str]]) -> list[tuple[int, int, str]]:
    """Fold `\\`-continued lines into `(head line, last line, text)` triples.

    The shell arm needs this: several recursive `grep` sites in the suite put the
    root operand on the line after the flags, so an unfolded scan would see a
    `grep -r` with no path operand at all and a path operand with no head. The end
    line is carried because a continued statement's head line ends in `\\`, where a
    trailing `#` comment would swallow the continuation — so the declaration marker
    is accepted anywhere in the folded span rather than only on the head line.
    """
    folded: list[tuple[int, int, str]] = []
    pending_number: int | None = None
    pending_text = ""
    last_number = 0
    for number, line in lines:
        last_number = number
        if pending_number is None:
            pending_number, pending_text = number, line
        else:
            pending_text += " " + line.lstrip()
        if pending_text.rstrip().endswith("\\"):
            pending_text = pending_text.rstrip()[:-1]
            continue
        folded.append((pending_number, number, pending_text))
        pending_number, pending_text = None, ""
    if pending_number is not None:
        folded.append((pending_number, last_number, pending_text))
    return folded


def _marker_lines(raw_lines: list[str], start: int, end: int) -> bool:
    """True when any raw source line in the inclusive 1-based span carries a marker.

    A call may span several lines; the declaration is accepted anywhere within it
    so an author is not forced to break a wrapped call to place the comment.
    """
    for number in range(start, min(end, len(raw_lines)) + 1):
        if has_marker(raw_lines[number - 1]):
            return True
    return False


def scan_literals(raw_lines: list[str]) -> list[tuple[int, str]]:
    """Return `(line number, reason)` for every unmarked literal-token candidate."""
    found: list[tuple[int, str]] = []
    for number, raw in enumerate(raw_lines, start=1):
        if has_marker(raw):
            continue
        code = strip_comment(raw)
        for token in LITERAL_TOKENS:
            if token in code:
                found.append((number, f"undeclared recursive walk (`{token}`)"))
                break
    return found


def _call_name(node: ast.Call) -> str | None:
    func = node.func
    if isinstance(func, ast.Attribute):
        return func.attr
    if isinstance(func, ast.Name):
        return func.id
    return None


def scan_python_ast(text: str, raw_lines: list[str]) -> list[tuple[int, str]]:
    """Return `(line number, reason)` for the two arms only a parse can judge.

    Raises `SyntaxError` to the caller, which reports it as a skip: a file that
    cannot be parsed has not been audited, and reporting clean over it would be the
    same fail-open this guard exists to prevent.
    """
    tree = ast.parse(text)
    found: list[tuple[int, str]] = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        name = _call_name(node)
        if name not in GLOB_CALL_NAMES:
            continue
        end = getattr(node, "end_lineno", node.lineno) or node.lineno
        if _marker_lines(raw_lines, node.lineno, end):
            continue
        # Arm 1 — a `**` component in any string literal anywhere inside the call,
        # which is how the `os.path.join(root, "skills", "**", …)` shape is reached.
        starred = any(
            isinstance(inner, ast.Constant)
            and isinstance(inner.value, str)
            and "**" in inner.value
            for inner in ast.walk(node)
        )
        if starred:
            found.append(
                (node.lineno, f"undeclared recursive walk (`{name}(` with a `**` pattern component)")
            )
            continue
        # Arm 2 — a pattern argument that is not a string literal, which no literal
        # inspection can judge. `rglob`/`iglob` also fire the literal arm, so an
        # unmarked one reaches here too; the per-line dedupe in `scan_file` then
        # collapses the duplicate. A marked call never reaches either arm.
        if not node.args:
            continue
        first = node.args[0]
        if isinstance(first, ast.Constant) and isinstance(first.value, str):
            continue
        found.append(
            (node.lineno, f"undeclared recursive walk (`{name}(` with a non-literal pattern)")
        )
    return found


def _path_operands(tokens: list[str], head_index: int) -> list[str]:
    """Return EVERY candidate path operand of the shell command at `head_index`.

    Deliberately a list, not "the first one". Selecting a single operand requires
    knowing which options take a **separated** value, and getting that wrong walks
    right past the real path: under a first-operand rule
    `grep -r --include '*.sh' NEEDLE "$ROOT"` selects `NEEDLE` and never examines
    `"$ROOT"`, and `find -maxdepth 2 "$ROOT"` selects `2` — both silently unflagged.
    Rather than re-derive an option table that would drift against two tools'
    real surfaces, test them all: an over-fire here is a declarable marker, while an
    under-fire is the fail-open this guard exists to remove.

    The one token deliberately excluded is `grep`'s **pattern** — its first non-option
    token — because a pattern is text to search *for*, not a path to search *in*, and
    testing it would flag `grep -r "ROOT" somedir` on its needle. When `grep -r` has
    no operand at all it defaults to the current directory, which is the bare `.` the
    fragment set already treats as root-resolving.
    """
    head = tokens[head_index]
    is_grep = head.endswith("grep")
    operands: list[str] = []
    skipped_pattern = not is_grep
    for token in tokens[head_index + 1 :]:
        if token.startswith("-"):
            continue
        if not skipped_pattern:
            skipped_pattern = True
            continue
        operands.append(token)
    if is_grep and not operands:
        operands.append(".")
    return operands


def _is_root_operand(operand: str | None) -> bool:
    if operand is None:
        return False
    stripped = operand.strip("'\"")
    if stripped == "." or stripped.startswith("./"):
        return True
    return any(fragment in stripped for fragment in ROOT_FRAGMENTS)


def statements_in(text: str) -> list[str]:
    """Return every statement in one logical line, descending into `$(…)` bodies.

    Composed from the shared machinery rather than re-derived: `_split_statements`
    keeps a substitution's body intact as part of its enclosing statement, and
    `_substitutions` hands back those bodies to be split in their own right — which
    is how `VAR="$(grep -r … "$ROOT/lib")"` is reached without the assignment prefix
    hiding the head. The descent repeats until no further substitution appears.
    """
    found: list[str] = []
    pending = [text]
    while pending:
        current = pending.pop()
        for statement in _heads._split_statements(current):
            found.append(statement)
            pending.extend(_heads._substitutions(statement))
    return found


def scan_shell(raw_lines: list[str]) -> list[tuple[int, str]]:
    """Return `(line number, reason)` for every unmarked shell-walk candidate."""
    found: list[tuple[int, str]] = []
    considered = [
        (number, strip_comment(raw)) for number, raw in enumerate(raw_lines, start=1)
    ]
    for number, end, line in fold_continuations(considered):
        if not line.strip():
            continue
        # Substring pre-filter before the tokenizer. This arm can only fire on a `find` or
        # `grep` HEAD, and a head must contain its own name textually, so a line carrying
        # neither name can never produce one — while `statements_in` never rewrites text, so
        # skipping cannot change a verdict. It is a large saving on the one 50k-line file in
        # the population: measured 0.53s -> 0.10s over lib/test/run.sh.
        if "find" not in line and "grep" not in line:
            continue
        if _marker_lines(raw_lines, number, end):
            continue
        for statement in statements_in(line):
            tokens = [_heads._normalize(t) for t in _heads._tokenize(statement)]
            if not tokens:
                continue
            bare = tokens[0].rsplit("/", 1)[-1]
            if bare not in ("find", "grep"):
                continue
            if bare == "grep" and not any(
                _GREP_RECURSIVE.match(t) for t in tokens[1:]
            ):
                continue
            if not any(
                _is_root_operand(operand) for operand in _path_operands(tokens, 0)
            ):
                continue
            found.append(
                (number, f"undeclared recursive walk (shell `{bare}` rooted at the repository root)")
            )
            break
    return found


def scan_file(relative: str, text: str) -> tuple[list[tuple[int, str]], str | None]:
    """Return `(findings, skip_reason)` for one audited file."""
    raw_lines = text.split("\n")
    findings = scan_literals(raw_lines)
    if relative.endswith(".py"):
        try:
            findings += scan_python_ast(text, raw_lines)
        except SyntaxError as exc:
            return findings, f"could not be parsed as Python ({exc})"
    else:
        findings += scan_shell(raw_lines)
    # Deduplicate by line: a `glob(` call can satisfy more than one arm, and one
    # declaration per line is what the marker contract asks for.
    seen: set[int] = set()
    unique: list[tuple[int, str]] = []
    for number, reason in sorted(findings):
        if number not in seen:
            seen.add(number)
            unique.append((number, reason))
    return unique, None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Fail when a tracked file under lib/test/ enumerates the repository "
            "tree with an undeclared recursive walk."
        )
    )
    parser.add_argument(
        "--root",
        default=None,
        help="repository root to enumerate and resolve paths against (default: the git toplevel, else the cwd)",
    )
    parser.add_argument(
        "--files-from",
        default=None,
        help="read the population from this newline-separated path list instead of git ls-files",
    )
    args = parser.parse_args(argv)

    if args.root is not None:
        root = Path(args.root)
    else:
        proc = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode == 0 and proc.stdout.strip():
            root = Path(proc.stdout.strip())
        else:
            # Never a silent default (the #295 repo-root contract): a wrong root feeds
            # straight into the read loop, and with --files-from it would otherwise
            # produce a green run over files that do not exist.
            root = Path.cwd()
            print(
                "lint-tree-enumeration: no git toplevel "
                f"({proc.stderr.strip() or 'git rev-parse failed'}); "
                f"resolving paths against the cwd {root}",
                file=sys.stderr,
            )

    try:
        population = enumerate_population(root, Path(args.files_from) if args.files_from else None)
    except EnumerationError as exc:
        print(f"lint-tree-enumeration: enumeration unusable: {exc}", file=sys.stderr)
        return 1

    audited = [path for path in population if is_audited(path)]

    findings: list[str] = []
    skipped: list[tuple[str, str]] = []
    read_ok = 0
    for relative in audited:
        text, skip_reason = _read(root / relative)
        if text is None:
            skipped.append((relative, skip_reason or "unknown"))
            continue
        file_findings, parse_skip = scan_file(relative, text)
        if parse_skip is not None:
            # Report the literal-arm findings the scan already collected ALONGSIDE the
            # skip rather than discarding them. The skip already forces a non-zero exit,
            # so nothing is weakened — but an unparseable file that also carries an
            # undeclared walk would otherwise report only the parse failure, costing the
            # author a second red run for a violation this run already knew about.
            skipped.append((relative, parse_skip))
        else:
            read_ok += 1
        for number, reason in file_findings:
            findings.append(
                f"{relative}:{number}: {reason} — declare it with "
                f"`{TREE_WALK_OK_MARKER} <reason>` on that line, or source the "
                "population from an index-reading `git ls-files`"
            )

    for finding in findings:
        print(finding)
    for relative, reason in skipped:
        print(f"lint-tree-enumeration: SKIPPED {relative}: {reason}", file=sys.stderr)
    # The tally counts files actually READ, against the number selected — never the
    # selection alone, which would report work that did not happen.
    print(
        f"lint-tree-enumeration: audited {read_ok} of {len(audited)} files"
        + (f" ({len(skipped)} skipped)" if skipped else "")
    )
    if skipped:
        # A skipped file is never a clean pass (the repo's standing suite convention):
        # a PARTIAL skip is the same defect as a total one, just quieter — the guard
        # reports clean over a population it did not fully read.
        print(
            f"lint-tree-enumeration: {len(skipped)} selected path(s) could not be audited — "
            "refusing to report clean; see the SKIPPED lines above",
            file=sys.stderr,
        )
        return 1
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
