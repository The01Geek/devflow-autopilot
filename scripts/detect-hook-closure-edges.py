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

Python-import edges (issue #805). A `.py` closure member can pull in another repo file
NOT through a shell spawn but through an in-process `importlib.util.spec_from_file_location`
load (the idiom modules with hyphenated filenames use — scripts/pretooluse-shape-guard.py
loads lib/test/extract-command-shapes.py this way, which loads extract-command-heads.py in
turn). That edge runs PR-head-editable Python inside the sourcing process, so it is exactly
as trust-sensitive as a `source`/`exec`, yet the shell-syntax regexes above cannot see it.
`pyimport_re` matches a `spec_from_file_location(..., <path-with-a-repo-file>)` load and adds
the referenced basename to the edge set, so the guard's own dependency edge is auditable and
the closure the trusted-source floor certifies is one the walker can actually inspect. Its
`.py` capture requires the path literal carry a `/` and a `.py` suffix; a fully variable-
assembled path is not statically resolvable (the same limit `assign_var_re` documents for
the shell forms).

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
    syntaxes above and the `importlib` load form below, not for Python-mediated
    subprocess spawns.
  - **Line-continuation source/exec.** Matching is line-based: `src_re`/`slashsh_re` and
    the exec regexes require the keyword and the path on the SAME line, so a
    backslash-continued source (a `.`/`source` whose path sits on the next physical line
    after a trailing backslash) is not captured.
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
# Python-import edge (issue #805): a `.py` closure member that loads another repo file
# via `importlib.util.spec_from_file_location`. The loaded path is normally assembled with
# `os.path.join(dir, "name.py")` (the basename literal sits on the join line, not the spec
# line), so the basename is captured from a quoted `.py`/`.sh` literal inside an
# `os.path.join(...)` call — but ONLY counted for a file that also contains a
# `spec_from_file_location` call (`_HAS_SPEC` below), so an ordinary `os.path.join` of a
# data file in a non-importing member is not misread as a code edge. A path passed as a
# literal directly to `spec_from_file_location(...)` is captured too.
_HAS_SPEC = re.compile(r'\bspec_from_file_location\b')
# `.*?` (non-greedy, line-scoped) so a nested call inside the join —
# `os.path.join(os.path.dirname(os.path.abspath(__file__)), "x.py")` — does not truncate
# the scan at its inner `)`; it stops at the FIRST quoted `.py`/`.sh` literal on the line.
pyjoin_re = re.compile(
    r'os\.path\.join\(.*?["\']([A-Za-z0-9_.-]+\.(?:py|sh))["\']'
)
specarg_re = re.compile(
    r'spec_from_file_location\([^)]*["\']([^\s"\']*/[A-Za-z0-9_.-]+\.(?:py|sh))["\']'
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
    has_spec = False
    py_import_candidates = set()
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
            if _HAS_SPEC.search(line):
                has_spec = True
            for m in pyjoin_re.finditer(line):
                py_import_candidates.add(m.group(1))
            for m in specarg_re.finditer(line):
                py_import_candidates.add(os.path.basename(m.group(1)))
    # A member's `importlib.util.spec_from_file_location` load is a real, trust-sensitive
    # edge only when the file actually performs such a load; the `os.path.join(... .py ...)`
    # basename candidates are added to the edge set only then (fail toward NOT inventing an
    # edge for a data-file join in a non-importing member).
    if has_spec:
        out |= py_import_candidates
    return out


def _real_repo_basenames(root):
    """The basenames of every tracked .sh/.py under scripts/ and lib/. A closure ESCAPE
    is a reference to a real repo file NOT in the closure; a reference whose basename
    matches no real file is documentation/example noise (a `.py`/`.sh` token inside a
    docstring or an illustrative comment — e.g. `bash x.sh`), never a live source/exec/
    import edge, so it is not a violation. Walk only scripts/ and lib/ (NOT the repo root,
    which would descend into sibling git worktrees under .claude/worktrees/, issue #711)."""
    real = set()
    for sub in ("scripts", "lib"):
        base = os.path.join(root, sub)
        for dirpath, _dirs, files in os.walk(base):
            for name in files:
                if name.endswith((".sh", ".py")):
                    real.add(name)
    return real


def main():
    root = os.environ["REPO_ROOT"]
    closure = os.environ["CLOSURE"].split()
    closure_base = {os.path.basename(p) for p in closure}
    real_basenames = _real_repo_basenames(root)
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
            if base not in real_basenames:
                continue  # references no real repo file — doc/example noise, not an edge
            if base not in closure_base:
                violations.append(f"{rel} -> {ref} (not in HOOK_TARGETS)")
    for v in sorted(set(violations)):
        print(v)


if __name__ == "__main__":
    main()
