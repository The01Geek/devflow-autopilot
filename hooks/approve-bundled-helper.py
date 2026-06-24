#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""DevFlow PreToolUse hook — local-tier auto-approval of DevFlow's own helpers.

When an adopter drives ``/devflow:implement`` / ``/devflow:review-and-fix``
locally, the Claude Code permission classifier prompts on every invocation of
DevFlow's *own* bundled helpers (``workpad.py``, ``config-get.sh``,
``parse-acs.py``, …). Those helpers live under the version-pinned plugin-cache
path, which is not a stable string an adopter can pre-allow once.

This hook closes that gap with a **containment-only** rule, never a substring
match: it emits ``permissionDecision: "allow"`` for a Bash command exactly when

  (a) the command is a single simple invocation — no ``&&``/``||``/``;``/``|``,
      no command substitution (``$(…)`` / backticks), no redirection, no
      subshell, and no newline (a bash command separator that would otherwise
      slip a trailing line past tokenization);
  (b) the executed program is the leading token, or the script argument to
      ``bash`` / ``python3``; and
  (c) that program canonicalizes (via ``realpath``, symlinks followed) to a
      **real file contained under the canonical ``$CLAUDE_PLUGIN_ROOT``**.

Parameter expansion (``$VAR`` / ``${VAR}``) is **not** disqualifying — unlike
command substitution it cannot change *which* program runs, and the program
token is independently containment-checked — so it is deliberately allowed
through (legitimate helper calls carry ``$ISSUE_NUMBER``-style arguments).

For every other command it prints nothing, leaving the normal permission flow
untouched. It **never** emits ``deny`` and **always** exits 0: a permission hook
that errored or denied would degrade *every* Bash call, not just helper ones, so
the failure mode here is to **fail open** (no decision) — the inverse of the
bundled helpers' fail-closed-with-a-breadcrumb discipline.
"""

import json
import os
import re
import shlex
import sys

_REASON = "DevFlow bundled helper resolved under $CLAUDE_PLUGIN_ROOT"


def _execution_target(command):
    """Return the path of the program a single simple ``command`` would execute,
    or ``None`` when ``command`` is not a shape this hook recognizes.

    Recognized shapes: a direct-exec leading token, ``bash <script> …``, and
    ``python3 <script> …``. Anything with a shell operator, a command
    substitution, or a backtick is rejected (returns ``None``).
    """
    # Command/function substitution that EXECUTES a command but that shlex tokenizes
    # as inert words (so the operator sweep below cannot see it) must be rejected by
    # substring before tokenizing:
    #   - backticks and `$(…)` execute even inside double quotes, where shlex absorbs
    #     `"$(curl evil)"` / `"\`curl evil\`"` into one quoted token;
    #   - the bash 5.3 funsub `${ cmd; }` / valsub `${| cmd; }` run in the current
    #     shell, and `{`/`}`/space are not operator chars, so `${ curl evil }`
    #     tokenizes as plain words. The opener is `${` followed by whitespace or `|`
    #     — which never starts an ordinary `${VAR}` parameter expansion (a name char
    #     follows `${`), so this rejects funsub/valsub without touching legit expansion.
    # A newline / carriage return is a bash command separator that shlex's
    # `whitespace_split` silently erases — a multi-line command would tokenize as one
    # flat "simple" invocation whose first token is a helper, letting a trailing line
    # run un-vetted. Treat any occurrence of these as disqualifying rather than trying
    # to reason about quoting. (`;`/`|`/`&` separators are still caught later as
    # operator tokens; these are the cases tokenization can't see through.)
    if (
        "`" in command
        or "$(" in command
        or re.search(r"\$\{[\s|]", command)
        or "\n" in command
        or "\r" in command
    ):
        return None

    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    # Disable shlex's comment handling: its default `commenters='#'` strips `#` and
    # everything after it — including a hidden `; <command>` separator — but bash
    # only treats `#` as a comment at a word boundary, so mid-word it is a literal
    # and the trailing separator is live. Keeping `#` literal lets the operator
    # sweep below still see that separator (the `#`-twin of the newline guard above).
    lexer.commenters = ""
    tokens = list(lexer)  # raises ValueError on unbalanced quotes
    if not tokens:
        return None

    # Any token made up entirely of operator characters (`;` `|` `&&` `(` `>` …)
    # means the command is not a single simple invocation — e.g. a bare subshell
    # `( … )`, a pipe, a redirection, or a `;`/`&` separator. (Command substitution
    # `$(…)` in any quoting is already rejected by the substring guard above, so it
    # never reaches here.) Read the operator set from the lexer itself
    # (`punctuation_chars`) so there is a single source of truth for "what shlex
    # split out as an operator".
    operator_chars = set(lexer.punctuation_chars)
    for tok in tokens:
        if tok and all(ch in operator_chars for ch in tok):
            return None

    prog = tokens[0]
    if os.path.basename(prog) in ("bash", "python3"):
        # The interpreter's *script argument* is the real target. A leading flag
        # (`bash -c "…"`, `python3 -m mod`) is not a script-file invocation.
        if len(tokens) < 2 or tokens[1].startswith("-"):
            return None
        return tokens[1]
    return prog


def _contained(target, plugin_root):
    """True iff ``target`` canonicalizes to a real file under ``plugin_root``."""
    # A bare command name (no path separator) is resolved via $PATH, never a file
    # under the plugin root — reject it before any filesystem syscall. The hook
    # runs on every Bash call, so this keeps the common non-helper case (`git
    # status`, `ls`, …) at zero realpath/stat. Legitimate helper invocations
    # always carry an absolute cache path, so they still reach the full check.
    if not target or target.startswith("-") or "/" not in target:
        return False
    root_real = os.path.realpath(plugin_root)
    if not os.path.isdir(root_real):
        return False
    target_real = os.path.realpath(target)  # follows symlinks; normalizes `..`
    if not os.path.isfile(target_real):
        return False
    try:
        return os.path.commonpath([root_real, target_real]) == root_real
    except ValueError:
        # Different drives / a relative-vs-absolute mismatch: cannot prove
        # containment, so defer.
        return False


def _should_allow(command, plugin_root):
    """True iff ``command`` is a single simple invocation whose execution target
    is a real file contained under ``plugin_root``."""
    if not command or not plugin_root:
        return False
    try:
        target = _execution_target(command)
    except ValueError:
        return False
    return _contained(target, plugin_root)


def main():
    """Read the PreToolUse payload from stdin; print an ``allow`` decision only
    on a positive containment match. Always exit 0; never deny."""
    try:
        data = json.loads(sys.stdin.read())
        if data.get("tool_name", "Bash") != "Bash":
            return
        tool_input = data.get("tool_input")
        command = tool_input.get("command") if isinstance(tool_input, dict) else None
        plugin_root = os.environ.get("CLAUDE_PLUGIN_ROOT")
        if isinstance(command, str) and _should_allow(command, plugin_root):
            json.dump(
                {
                    "hookSpecificOutput": {
                        "hookEventName": "PreToolUse",
                        "permissionDecision": "allow",
                        "permissionDecisionReason": _REASON,
                    }
                },
                sys.stdout,
            )
    except Exception:
        # Fail open: any error → no decision, defer to the normal permission flow.
        # Never raise, never deny — that would degrade every Bash call.
        pass


if __name__ == "__main__":
    main()
