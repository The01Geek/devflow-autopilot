# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""detect-hook-closure-edges.py — the #458 Stop-hook closure drift-guard walker.

Statically walk every source/`.`/exec/`python3 <path>` edge in each closure file
named by CLOSURE and report every referenced repo .sh/.py that is NOT itself in the
closure — so a future added `source`/exec of a NEW helper is surfaced instead of
silently re-opening the one-hop-deeper hole scripts/harden-stop-hooks.sh closes.

This is the shared walker extracted from lib/test/run.sh's `#458 drift-guard`
assertion (issue #460): a single copy so the drift-guard and its positive-control
test exercise the SAME regex set, and a regex regression turns the suite RED rather
than diverging silently between two hand-copied programs.

I/O contract (env, matching the former inline heredoc):
  input  : env REPO_ROOT — repo root the closure paths are resolved against.
           env CLOSURE    — space-separated repo-relative closure paths (HOOK_TARGETS).
  stdout : one violation line per issue, sorted+deduped. Two shapes:
             `rel -> ref (not in HOOK_TARGETS)`        — an edge escaping the closure
             `rel -> UNREADABLE (<Error>): ...`        — a closure member that could
                                                          not be read/audited at all
  exit   : always 0 — this is a REPORTER; the caller decides (empty output == clean).

Fail-closed reads (issue #460 review): a closure member that is missing, unreadable,
or a directory is itself reported as a violation, NOT swallowed — a drift guard that
cannot read a member it is meant to audit must turn the desk RED, never green. The
file is opened with `errors="replace"` so a stray non-UTF-8 byte in one member does
not crash the whole walk (the regexes are ASCII-anchored, so a replacement char is
harmless); an OSError (missing / permission / is-a-directory) is caught and surfaced.

Command-position source edges are matched by `src_re`, whose prefix set covers both
the shell metacharacters that can precede a command-position `.`/`source` — line
start, `;`, `&`, `|`, `(`, and (issue #460) `!` and `{` — AND (issue #460 review) the
reserved words that open a command position — `then`, `do`, `else`, `elif` — so a
negation-guarded (`if ! . "$dep"`), brace-grouped (`{ . "$dep"; }`), or keyword-
position (`then . "$dep"`) source edge is detected, not a blind spot. Trailing shell
comments are stripped quote-aware (a `#` inside a quoted string — e.g. an `issue #$n`
breadcrumb — is NOT a comment, so a real edge later on the same line is not lost).

Known granularity limits (documented, not silently assumed — none occur in the current
closure; all are conservative gaps a maintainer widening the closure should keep in
mind):
  - **Basename-only membership.** Closure membership is compared by BASENAME only — the
    sources reference their deps by `$DIR/…`-relative paths not statically resolvable
    here — so a same-basename file at a different path reads as in-closure.
  - **Slash-less source.** `slashsh_re` requires a `/` before the `.sh`, so a slash-less
    same-directory `. foo.sh` source is not captured.
  - **Variable-indirected source (issue #460 review).** A source whose path is held
    entirely in a variable set elsewhere (`DEP="$HERE/newdep.sh"; . "$DEP"`) is only
    caught via `assign_re`/`assign_var_re` on the *assignment* line; if the path is
    assembled dynamically (e.g. built from `$1`, a loop, or command output) the edge
    escapes. `assign_var_re` widens the common `VAR="$DIR/name.sh"` shape into scope,
    but a fully-dynamic indirection is not statically resolvable.
  - **Python-internal spawns.** The regexes are shell-syntax-only, so a `.py` closure
    member's `subprocess.run(["bash", "scripts/new.sh"])` (or `os.system`) spawn of a
    repo script is NOT matched — a `.py` member is audited only for the shell-form edge
    syntaxes above, not for Python-mediated subprocess spawns.
The jq PROGRAM edge (`-f *.jq`) is out of scope (jq is sandboxed — not a shell/RCE
vector).
"""

import os
import re

src_re = re.compile(r'(?:^|[;&|(!{]|\b(?:then|do|else|elif)\b)\s*(?:\.|source)\s')
slashsh_re = re.compile(r'/([A-Za-z0-9_.-]+\.sh)\b')
pyexec_re = re.compile(r'\bpython3\s+"?([^\s"]*\.py)\b')
shexec_re = re.compile(r'\b(?:bash|sh)\s+"?([^\s"]*\.sh)\b')
execb_re = re.compile(r'\bexec\s+"?([^\s"]*\.(?:sh|py))\b')
assign_re = re.compile(
    r'\b[A-Za-z_][A-Za-z0-9_]*=[^\s#]*?((?:scripts|lib)/[A-Za-z0-9_.-]+\.(?:sh|py))'
)
# A `$DIR/name.sh`-style assignment (issue #460 review): catches the common variable-
# indirected source shape `DEP="$HERE/newdep.sh"; . "$DEP"` at the assignment line, where
# the sourced path carries no literal `scripts/`/`lib/` prefix. Captures the basename.
assign_var_re = re.compile(
    r'\b[A-Za-z_][A-Za-z0-9_]*=\s*"?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?'
    r'(?:/[A-Za-z0-9_.-]+)*/([A-Za-z0-9_.-]+\.(?:sh|py))\b'
)


def _strip_comment(line):
    """Drop a trailing shell comment, quote-aware.

    A comment starts at the first '#' that is UNQUOTED and at a token boundary
    (line start or preceded by whitespace). A '#' inside a single/double-quoted
    string (e.g. an `issue #$n` breadcrumb) is preserved, so a real source/exec
    edge later on the same line is not lost (issue #460 review, FP4).
    """
    in_s = in_d = False
    prev_ws = True  # line start is a token boundary
    for i, ch in enumerate(line):
        if ch == "'" and not in_d:
            in_s = not in_s
        elif ch == '"' and not in_s:
            in_d = not in_d
        elif ch == '#' and not in_s and not in_d and prev_ws:
            return line[:i]
        prev_ws = ch.isspace()
    return line


def refs_in(path):
    """Return the set of repo-file basenames referenced by source/exec edges in `path`.

    Raises OSError if `path` cannot be opened (missing / permission / directory) —
    the caller surfaces that as a violation rather than treating it as "no edges".
    """
    out = set()
    with open(path, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = _strip_comment(raw)
            if not line.strip():
                continue
            if src_re.search(line):
                for m in slashsh_re.finditer(line):
                    out.add(m.group(1))
            for rx in (pyexec_re, shexec_re, execb_re):
                for m in rx.finditer(line):
                    out.add(os.path.basename(m.group(1)))
            for rx in (assign_re, assign_var_re):
                for m in rx.finditer(line):
                    out.add(os.path.basename(m.group(1)))
    return out


def main():
    root = os.environ["REPO_ROOT"]
    closure = os.environ["CLOSURE"].split()
    closure_base = {os.path.basename(p) for p in closure}
    violations = []
    for rel in closure:
        try:
            refs = refs_in(os.path.join(root, rel))
        except OSError as exc:
            # A closure member the guard cannot read is a fail-CLOSED violation, never
            # a silent empty set: it means HOOK_TARGETS names a path that is missing,
            # unreadable, or a directory — a drift the guard exists to surface.
            violations.append(
                f"{rel} -> UNREADABLE ({exc.__class__.__name__}): cannot audit this closure member"
            )
            continue
        for ref in refs:
            base = os.path.basename(ref)
            if base == os.path.basename(rel):
                continue
            if base not in closure_base:
                violations.append(f"{rel} -> {ref} (not in HOOK_TARGETS)")
    for v in sorted(set(violations)):
        print(v)


if __name__ == "__main__":
    main()
