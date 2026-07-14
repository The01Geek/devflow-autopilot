#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Extract Bash command heads from the ```bash fences of a Markdown file and
check each against a Claude Code `--allowed-tools` allowlist string.

Why this exists (issue #363): `skills/review/SKILL.md` is executed under TWO
allowlists — the `review` profile in `.github/workflows/devflow-runner.yml` and
the command allowlist in `.github/workflows/devflow.yml`. A command head the
skill invokes but neither allowlist grants is *silently denied* at runtime: the
engine burns turns rediscovering the boundary and can end a run with no verdict.
This module is the drift pin that turns that class of divergence RED at the desk.

Scope boundary (deliberate, and asserted by the suite):

* Only fenced blocks whose info string is exactly `bash` are scanned. Commands
  that appear as inline-backtick prose (e.g. `git cat-file -e` in Phase 0.3.6)
  are OUT of reach — matching prose would resurrect the `git a` / `git failure` /
  `git said` false-positive class this extractor exists to avoid. Grants for
  inline-prose commands are pinned directly by literal, not through this
  extractor.
* Command substitutions are descended into. `VAR=$(gh pr view ...)` is the
  dominant invocation shape in the skill, so an extractor blind to `$(...)`
  would miss most real heads.

Claude Code's own matching behavior, which this models:

* A compound command is split on `&&`, `||`, `;`, `|`, `|&`, `&`, and newline,
  and EVERY subcommand must match a rule independently.
* The process wrappers `timeout`, `time`, `nice`, `nohup`, `stdbuf`, and bare
  `xargs` are stripped before matching, so `timeout 300 bash x.sh` matches as
  `bash ...`.

CLI:
    extract-command-heads.py heads FILE
        -> one extracted head per line, sorted and deduped.
    extract-command-heads.py ungranted FILE ALLOWLIST_FILE [tools-line]
        -> one head per line that no rule in ALLOWLIST_FILE grants.
       By default every `Bash(<spec>:*)` rule anywhere in ALLOWLIST_FILE grants —
       including one merely CITED inside a comment. Pass the literal `tools-line`
       to parse only a workflow's real `TOOLS='...'` allowlist line; both workflows
       carry cited specs in their deny-floor commentary, so `tools-line` is the only
       correct form to use against them.
Both subcommands exit 0; `ungranted` prints nothing when everything is granted.
"""

from __future__ import annotations

import re
import sys

# POSIX reserved words plus the bracket/brace/paren syntax families. A token in
# this set is shell syntax, never a command head. The list is fixed and small on
# purpose: an unrecognized token is REPORTED (and must be granted or explicitly
# handled), never silently absorbed as "probably noise" — the fail-closed
# posture. `[` / `[[` are treated as syntax rather than as the `test` binary,
# matching how the fences actually use them (`if [ -z "$WP" ]; then`).
RESERVED = frozenset(
    """
    if then else elif fi for while until do done case esac in function select
    { } ( ) [[ ]] [ ] : . source return break continue exit
    """.split()
)

# Stripped before the head is read, mirroring Claude Code's wrapper handling.
WRAPPERS = frozenset({"timeout", "time", "nice", "nohup", "stdbuf", "xargs"})

# Wrappers that take exactly one bare (non-flag) operand of their own before the
# real command begins: `timeout 300 bash x.sh`, `nice 5 cmd`. `time`, `nohup`,
# `xargs` and `stdbuf` take only flags, so consuming their flags suffices.
WRAPPERS_WITH_OPERAND = frozenset({"timeout", "nice"})

# The portable single-statement skill anchor. A helper invoked through it lives
# at the vendored path at cloud-review runtime, which is the form the allowlists
# grant, so normalize before matching. Matches both the quoted and bare shapes
# and any placeholder text inside the `:-` default.
_ANCHOR = re.compile(r'^"?\$\{CLAUDE_SKILL_DIR:-[^}]*\}"?/\.\./\.\./')

_ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")

# `Bash(spec:*)` / `Bash(spec)` — the command-position token is everything before
# the first `:` (mirrors the deny-list-floor parsing in devflow-runner.yml).
_RULE = re.compile(r"Bash\(([^)]*)\)")

_HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")

# A `case` arm's pattern (`critical|important)`, `*)`, `[RC])`, `''|*[!0-9]*)`) is
# shell syntax, not a command. This regex is applied by `_strip_case_patterns` ONLY
# at a position where an arm may legally begin (right after `case … in`, and right
# after each `;;`); a statement in the case *body* is never offered to it. That
# positional guard — not the character class — is what keeps a real command ending
# in `)` (a subshell close such as `(dd)`) from being mistaken for an arm: the class
# still admits the optional leading `(`, which is correct for a genuine `(pattern)`
# arm and is only ever reached at an arm position. The class stays restricted to
# glob/alternation characters — including `!` and `^`, because a bracket expression
# may be negated in either spelling (bash's `[!0-9]`, POSIX's `[^0-9]`) — so an arm
# pattern is recognized in full; widening it further would let a body statement look
# like an arm from the other side.
_CASE_PATTERN = re.compile(r"^\s*\(?\s*([\w*?\[\]|.\-\"' !^]+?)\)\s*")

# A leading redirection (`>file`, `2>&1`, `&>log`) is not a command head.
_REDIRECTION = re.compile(r"^&?[0-9]*[<>]")

# Longest head we ever try to match: `gh pr diff` is 3 words.
_MAX_HEAD_WORDS = 3

_SEPARATORS = ("|&", "&&", "||", ";", "|", "&", "\n")


def _fenced_bash_blocks(text: str) -> list[str]:
    """Return the bodies of every fence whose info string is exactly `bash`."""
    blocks: list[str] = []
    body: list[str] | None = None
    for line in text.splitlines():
        stripped = line.strip()
        if body is None:
            if stripped == "```bash":
                body = []
            continue
        if stripped == "```":
            blocks.append("\n".join(body))
            body = None
            continue
        body.append(line)
    return blocks


def _strip_comments_and_heredocs(block: str) -> str:
    """Drop `#` comments and heredoc bodies, both quote-aware.

    A `#` only opens a comment at the start of a word and outside quotes, so
    `"a#b"` and `${x#y}` survive. A heredoc body is skipped wholesale, which is
    what keeps a documentation sample containing `rm -rf /` from being read as a
    command.
    """
    out: list[str] = []
    pending_tag: str | None = None
    for line in block.split("\n"):
        if pending_tag is not None:
            if line.strip() == pending_tag:
                pending_tag = None
            continue

        kept: list[str] = []
        quote: str | None = None
        prev = ""
        for ch in line:
            if quote:
                kept.append(ch)
                if ch == quote and prev != "\\":
                    quote = None
            elif ch in ("'", '"'):
                quote = ch
                kept.append(ch)
            elif ch == "#" and (prev == "" or prev.isspace()):
                break
            else:
                kept.append(ch)
            prev = ch
        cleaned = "".join(kept)

        match = _HEREDOC.search(cleaned)
        if match:
            pending_tag = match.group(2)
            cleaned = cleaned[: match.start()]

        out.append(cleaned)
    return "\n".join(out)


def _strip_case_patterns(block: str) -> str:
    """Drop `case` arm patterns (`critical|important)`, `*)`, `[RC])`).

    A pattern's `|` alternation would otherwise be split as a pipe, yielding each
    alternative as its own bogus command. Tracked line-by-line, which is how the
    fences actually write case arms.

    Arm patterns are stripped ONLY at a position where an arm may legally begin —
    the statement immediately after `case … in`, and the statement immediately after
    each `;;` terminator — so a statement in the case *body* (e.g. a bare subshell
    `(dd)`) is never mistaken for a pattern and keeps its head. Two pieces of state
    carry this: `in_case` (inside a `case` block) and `expect_arm` (an arm pattern
    may start on this line). `expect_arm` is set on entry and re-set after each `;;`,
    and cleared after the first non-comment line at an arm position (whether or not a
    pattern actually matched).

    Accepted limitations (none occurs in skills/review/SKILL.md today; left unhandled
    deliberately, since handling them would add complexity the real input never
    exercises). Two of the three fail CLOSED — the unhandled shape leaks an arm pattern
    as a bogus head that no allowlist grants, turning the suite RED, never a silently
    un-granted command:
    - The bash fall-through terminators `;&` and `;;&` do not re-arm (only `;;` does),
      so an arm terminated by one leaks the *next* arm's pattern. (fails CLOSED)
    - A blank line between arms consumes `expect_arm` without a pattern, so the next
      arm's pattern is not stripped. (fails CLOSED)
    The third can fail OPEN, and is relied upon not to occur:
    - `in_case` is a flag, not a depth counter, so a *nested* `case` clears the outer
      state one `esac` too early. The multi-line spelling leaks a bogus head (fails
      closed), but a *single-line* inner `case … esac` silently drops its body command
      with no bogus head emitted (fails OPEN). This is backstopped not by a leak but by
      the `lib/test/run.sh` 88/28 head-count pins on the real skill: a nested `case`
      added to a review fence would move those counts and turn the suite RED.
    """
    out: list[str] = []
    in_case = False
    expect_arm = False
    for line in block.split("\n"):
        stripped = line.strip()
        if re.match(r"^case\b", stripped):
            in_case = True
            expect_arm = True
            # A single-line `case … esac` opens and closes on the same line; leave
            # the block cleanly so following lines parse as ordinary statements.
            # This is the latch the old flag-only stripper never released.
            if re.search(r"\besac\b", stripped):
                in_case = False
                expect_arm = False
        elif re.match(r"^esac\b", stripped):
            in_case = False
            expect_arm = False
        elif expect_arm and not stripped.startswith("#"):
            # `expect_arm` is only ever set while inside a `case` block, so it alone
            # gates the strip (it implies `in_case`). The `#` check is defensive:
            # `extract_heads` runs `_strip_comments_and_heredocs` first, so in the real
            # pipeline no line reaching here starts with `#` (a comment is already
            # blanked to whitespace — and such a blank line at an arm position DOES
            # consume `expect_arm`, which is the documented blank-line limitation). A
            # `;;`-leading line can't reach here either, because `expect_arm` is False
            # on the terminator's own line.
            pattern = _CASE_PATTERN.match(line)
            if pattern:
                line = line[pattern.end() :]
            expect_arm = False
        # A `;;` terminator (matched on the ORIGINAL line, before any strip above)
        # means the next line may open a new arm.
        if in_case and stripped.endswith(";;"):
            expect_arm = True
        out.append(line)
    return "\n".join(out)


def _join_continuations(block: str) -> str:
    """Fold `\\`-continued lines into one logical line before any splitting.

    The backslash-newline pair is REMOVED, not replaced by a space — that is the shell's
    own rule, and the difference is load-bearing, not cosmetic. A continuation may split a
    line MID-TOKEN (`…/apply\\<newline>-labels.sh 1 X` is one word to the shell), and a
    space-join reconstructs it as two words (`apply -labels.sh`) — a token that matches no
    helper-name literal. Every name-literal rule downstream (the #363 head grants, the #455
    implement-tier label rules) then reads a helper that is not there and ships the denied
    shape GREEN (issue #480). Token separation is preserved without the space: the shell
    keeps whatever whitespace precedes the backslash and follows the newline, so
    `cmd \\<newline>    --flag` still joins to `cmd     --flag` (two tokens), while
    `cmd\\<newline>--flag` joins to `cmd--flag` — as bash reads them.

    NON-GOALS (disclosed, so the joiner's accepted set is not mistaken for the shell's):
    it tracks neither QUOTE STATE nor ESCAPED BACKSLASHES, so a `\\`+newline inside single
    quotes (which the shell keeps literally, not as a continuation) and a line-final `\\\\`
    (an escaped literal backslash, not a continuation) are both folded anyway. Both are
    pre-existing limits of this textual join, no fence writes either shape, and the failure
    direction is a *joined* line — never a dropped one — so a name-literal rule downstream
    still sees the helper. A guard must not lie about what it accepts (issue #480).
    """
    return re.sub(r"\\\n", "", block)


def _split_statements(text: str) -> list[str]:
    """Split on Claude Code's separator set, outside quotes and outside `$(...)`.

    `$(...)` bodies are kept intact here and recursed into later, so a separator
    inside a substitution splits that substitution's own statements, not the
    enclosing one.
    """
    statements: list[str] = []
    current: list[str] = []
    quote: str | None = None
    depth = 0
    i = 0
    prev = ""
    while i < len(text):
        ch = text[i]
        if quote:
            current.append(ch)
            if ch == quote and prev != "\\":
                quote = None
            prev = ch
            i += 1
            continue
        if ch in ("'", '"'):
            quote = ch
            current.append(ch)
            prev = ch
            i += 1
            continue
        if text.startswith("$(", i):
            depth += 1
            current.append(text[i : i + 2])
            prev = "("
            i += 2
            continue
        if ch == ")" and depth:
            depth -= 1
            current.append(ch)
            prev = ch
            i += 1
            continue
        if depth == 0:
            for sep in _SEPARATORS:
                if not text.startswith(sep, i):
                    continue
                # `&` is a separator only as a real control operator. In `2>&1`,
                # `>&2`, and `&>log` it is part of a redirection, and splitting
                # there would emit the file descriptor (`1`, `2`) as a command.
                if sep == "&" and (prev in ("<", ">") or text.startswith("&>", i)):
                    continue
                statements.append("".join(current))
                current = []
                prev = ""
                i += len(sep)
                break
            else:
                current.append(ch)
                prev = ch
                i += 1
            continue
        current.append(ch)
        prev = ch
        i += 1
    statements.append("".join(current))
    return [s for s in (st.strip() for st in statements) if s]


def _substitutions(statement: str) -> list[str]:
    """Return the bodies of every `$(...)` in a statement, outermost first."""
    bodies: list[str] = []
    quote: str | None = None
    stack: list[int] = []
    i = 0
    prev = ""
    while i < len(statement):
        ch = statement[i]
        if quote:
            # A `$(` inside double quotes is still a substitution.
            if quote == '"' and statement.startswith("$(", i):
                stack.append(i + 2)
                i += 2
                prev = "("
                continue
            if quote == '"' and ch == ")" and stack:
                start = stack.pop()
                bodies.append(statement[start:i])
                i += 1
                prev = ch
                continue
            if ch == quote and prev != "\\":
                quote = None
            prev = ch
            i += 1
            continue
        if ch in ("'", '"'):
            quote = ch
            prev = ch
            i += 1
            continue
        if statement.startswith("$(", i):
            stack.append(i + 2)
            i += 2
            prev = "("
            continue
        if ch == ")" and stack:
            start = stack.pop()
            bodies.append(statement[start:i])
            i += 1
            prev = ch
            continue
        prev = ch
        i += 1
    return bodies


def _tokenize(statement: str) -> list[str]:
    """Whitespace-split, keeping quoted spans and `$(...)` bodies as one token."""
    tokens: list[str] = []
    current: list[str] = []
    quote: str | None = None
    depth = 0
    prev = ""
    for ch in statement:
        if quote:
            current.append(ch)
            if ch == quote and prev != "\\":
                quote = None
        elif ch in ("'", '"'):
            quote = ch
            current.append(ch)
        elif ch == "(" and prev == "$":
            depth += 1
            current.append(ch)
        elif ch == ")" and depth:
            depth -= 1
            current.append(ch)
        elif ch.isspace() and depth == 0:
            if current:
                tokens.append("".join(current))
                current = []
        else:
            current.append(ch)
        prev = ch
    if current:
        tokens.append("".join(current))
    return tokens


def _normalize(token: str) -> str:
    token = _ANCHOR.sub(".devflow/vendor/devflow/", token)
    return token.strip("'\"")


def _head_of(statement: str) -> list[str] | None:
    """Return the argv words of a statement's head command, or None."""
    statement = statement.strip()
    # A bare subshell `(cmd …)` runs `cmd`; the allowlist must grant that inner
    # command, so descend through a wrapping `(…)` to its head. (A `$(…)` command
    # substitution starts with `$`, not `(`, and is handled by _substitutions —
    # this arm only fires for a real subshell group.) Once `_strip_case_patterns`
    # has removed arm patterns at their legal positions, the only `(…)` a body
    # statement carries is a genuine subshell, so this never re-swallows an arm.
    if statement.startswith("(") and statement.endswith(")"):
        return _head_of(statement[1:-1])
    tokens = _tokenize(statement)
    i = 0
    # Strip a leading `!` negation (`if ! VAR=$(cmd); then`).
    while i < len(tokens) and tokens[i] == "!":
        i += 1
    # Strip leading `VAR=value` env assignments.
    while i < len(tokens) and _ASSIGNMENT.match(tokens[i]):
        i += 1
    # Strip process wrappers, their flags, and (for timeout/nice) one operand.
    while i < len(tokens) and _normalize(tokens[i]) in WRAPPERS:
        wrapper = _normalize(tokens[i])
        i += 1
        while i < len(tokens) and tokens[i].startswith("-"):
            i += 1
        if wrapper in WRAPPERS_WITH_OPERAND and i < len(tokens):
            if not tokens[i].startswith("-") and re.fullmatch(
                r"[0-9]+[smhd]?", tokens[i]
            ):
                i += 1
    # Skip leading redirections (`>out cmd` is legal, if rare).
    while i < len(tokens) and _REDIRECTION.match(tokens[i]):
        i += 1
    if i >= len(tokens):
        return None
    words = [_normalize(t) for t in tokens[i : i + _MAX_HEAD_WORDS]]
    if not words or not words[0] or words[0] in RESERVED:
        return None
    if words[0].startswith("-") or _REDIRECTION.match(words[0]):
        return None
    return words


def extract_heads(text: str) -> list[list[str]]:
    """Every command head's argv words, from every ```bash fence in `text`."""
    heads: list[list[str]] = []
    for block in _fenced_bash_blocks(text):
        cleaned = _strip_case_patterns(_strip_comments_and_heredocs(block))
        _collect(_join_continuations(cleaned), heads)
    return heads


def _collect(text: str, heads: list[list[str]]) -> None:
    for statement in _split_statements(text):
        for body in _substitutions(statement):
            _collect(body, heads)
        head = _head_of(statement)
        if head is not None:
            heads.append(head)


def tools_allowlist_line(text: str) -> str:
    """Return the single `TOOLS='...'` allowlist line from a workflow file.

    Scoping to that line is load-bearing, not hygiene: both workflows mention
    `Bash(...)` specs inside *comments* (devflow-runner.yml's deny-floor commentary
    cites `Bash(npm:*)`, `Bash(env bash:*)`, …). Parsing the whole file would read
    those citations as grants and the pin would pass on a head nothing grants.

    Both allowlists live on such a line — devflow-runner.yml's `review` case arm and
    devflow.yml's hoisted `Resolve allowed-tools` step. devflow-runner.yml also
    carries a `TOOLS="$TOOLS,$FILTERED"` append under provision_env; the
    single-quote anchor excludes it, so the match stays unique.

    Uniqueness is ENFORCED, not assumed. Returning the first of several matches would
    silently pick one allowlist and ignore the rest, so a second profile's `TOOLS='...'`
    line added later would be audited against the wrong grants — a fail-open in the very
    matcher the #363 pins rely on. Zero matches and more than one match both abort.
    """
    matches = [line for line in text.splitlines() if re.match(r"^\s*TOOLS='", line)]
    if not matches:
        raise SystemExit("devflow: no `TOOLS='...'` allowlist line found")
    if len(matches) > 1:
        raise SystemExit(
            f"devflow: {len(matches)} `TOOLS='...'` allowlist lines found; expected exactly one. "
            "Refusing to guess which one grants the review engine's commands."
        )
    return matches[0]


def parse_allowlist(text: str) -> set[tuple[str, ...]]:
    """Granted command-position specs, as word tuples, from `Bash(spec:*)` rules."""
    granted: set[tuple[str, ...]] = set()
    for spec in _RULE.findall(text):
        command = spec.split(":", 1)[0].strip()
        if command:
            granted.add(tuple(command.split()))
    return granted


def is_granted(head: list[str], granted: set[tuple[str, ...]]) -> bool:
    """True when any word-prefix of `head` exactly matches a granted spec.

    Longest-prefix-first is irrelevant to the boolean, but matters for how an
    ungranted head is *named*: see `name_of`.
    """
    return any(tuple(head[:n]) in granted for n in range(len(head), 0, -1))


def name_of(head: list[str]) -> str:
    """The head's canonical, matchable name — the exact spec a rule must grant.

    Only the command-position words are named, never the arguments: `echo "a b"`
    is `echo`, not `echo a b`. `git` takes a one-word subcommand (`git checkout`)
    and `gh` a two-word one (`gh pr diff`), matching the specs the profiles carry.
    Naming arguments would make an ungranted-head report unactionable and would
    leak string contents (e.g. a `git said:` message) into the report.
    """
    if head[0] == "gh":
        return " ".join(head[: min(3, len(head))])
    if head[0] == "git" and len(head) > 1:
        return " ".join(head[:2])
    return head[0]


def main(argv: list[str]) -> int:
    if len(argv) >= 3 and argv[1] == "heads":
        with open(argv[2], encoding="utf-8") as handle:
            heads = extract_heads(handle.read())
        for name in sorted({name_of(h) for h in heads}):
            print(name)
        return 0
    if len(argv) >= 4 and argv[1] == "ungranted":
        with open(argv[2], encoding="utf-8") as handle:
            heads = extract_heads(handle.read())
        with open(argv[3], encoding="utf-8") as handle:
            allowlist = handle.read()
        if len(argv) >= 5 and argv[4] == "tools-line":
            allowlist = tools_allowlist_line(allowlist)
        granted = parse_allowlist(allowlist)
        for name in sorted(
            {name_of(h) for h in heads if not is_granted(h, granted)}
        ):
            print(name)
        return 0
    print(
        "usage: extract-command-heads.py heads FILE\n"
        "       extract-command-heads.py ungranted FILE ALLOWLIST_FILE [tools-line]",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
