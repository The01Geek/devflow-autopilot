#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Static self-scan of `lib/test/run.sh`'s own pin corpus (issue #375).

Two mechanical guards over the suite's pin-helper call sites, so a defect the
parents (#370, #371) had to rediscover in a later shadow instead fails RED at
authoring time:

* ``lint`` — the **pin-in-comment lint.** A pin literal that also appears inside
  a *comment* of its own target file inflates the occurrence count the pin reads
  (issue #370's evidence: a ``pin_count`` expecting 2 read 3 because the phase
  file's own comment quoted the literal, so collapsing a real call site brought
  the count *down* to the expected 2 — the pin passed on the regression it
  guards). This scan enumerates every statically-resolvable ``(literal, target)``
  pair from the four pin helpers and FAILs when the literal sits in a ``#``
  comment (``.sh``/``.py``/``.jq``/``.yml``) or an ``<!-- … -->`` region
  (``.md``) of its target.

* ``wrapped`` — the **wrapped-literal meta-guard.** A contract phrase assembled
  from wrapped adjacent string literals (``'… OLD does '`` then ``'not) …'`` in
  an argparse ``help=``) lives on *no single line*, so a line-based ``grep`` /
  ``pin_count`` finds nothing even though the rendered ``--help`` text contains
  it (issue #371's evidence). This scan flags any source-grep pin whose phrase
  occurs on no single line of its target, distinguishing *absent* from *present
  only in the whitespace-normalized rendering* (``tr -s '[:space:]' ' '``), and
  additionally FAILs any pin into a multi-literal argparse ``help=`` string,
  requiring the pin to target the rendered surface (captured ``--help`` output,
  real stderr) instead.

**Fail-closed:** a call site the scanner cannot resolve statically (the literal
interpolates a variable it cannot resolve, or the target file is a variable with
no ``--var`` binding and no ``$LIB``-relative assignment) is COUNTED and reported
on stderr, never silently skipped.

Both subcommands exit 0. Findings go to stdout (one per line, tab-separated);
the unresolvable count and per-site detail go to stderr.

CLI::

    pin-corpus-lint.py lint    PIN_SOURCE [--lib DIR] [--var NAME=PATH ...]
    pin-corpus-lint.py wrapped PIN_SOURCE [--lib DIR] [--var NAME=PATH ...]

``PIN_SOURCE`` is the shell file whose pin call sites are scanned (``run.sh``
itself for the real corpus, a synthetic fixture for the self-tests). ``--var``
supplies the runtime value of a target-file variable the helper cannot resolve
statically (e.g. ``DEF_SKILL``, the mktemp'd implement-skill bundle); ``--lib``
binds ``$LIB`` so ``VAR="$LIB/../skills/…"`` assignments resolve on their own.
"""

from __future__ import annotations

import os
import re
import sys

# (literal_arg_index, file_arg_index, default_file_var).  Indices are 0-based
# over the call's arguments AFTER the helper name.  A file index past the actual
# arg list means the optional file arg was omitted -> use default_file_var.
HELPERS = {
    "assert_pin_unique": (1, 2, None),
    "pin_count": (0, 1, None),
    "assert_pin_red_on_removal": (1, 2, "MAXI_SKILL"),
    "assert_pin_red_under": (1, 3, "MAXI_SKILL"),
}

COMMENT_HASH_EXTS = {".sh", ".py", ".jq", ".yml", ".yaml"}
COMMENT_MD_EXTS = {".md"}


# ── shell tokenizing ────────────────────────────────────────────────────────
def join_logical_lines(text):
    """Yield (start_lineno, logical_line) joining backslash-continued lines."""
    physical = text.split("\n")
    i = 0
    while i < len(physical):
        start = i + 1
        line = physical[i]
        while line.endswith("\\") and not line.endswith("\\\\") and i + 1 < len(physical):
            line = line[:-1] + "\n" + physical[i + 1]
            i += 1
        yield start, line
        i += 1


def tokenize(s):
    """Split a shell fragment into argument tokens, quote-aware.

    Returns a list of tokens, each a list of (kind, value) segments where kind
    is 'sq' (single-quoted, literal), 'dq' (double-quoted), or 'bare'. Adjacent
    segments with no separating whitespace belong to one token (shell
    concatenation, e.g. `'a'"$B"`).
    """
    tokens = []
    cur = []  # list of (kind, value) segments for the current token
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c in " \t\n":
            if cur:
                tokens.append(cur)
                cur = []
            i += 1
            continue
        if c == "#" and not cur:
            # A '#' starting a token begins a comment (only outside a token, so
            # `foo#bar` bare words are unaffected — none occur in pin calls).
            break
        if c == "'":
            j = s.index("'", i + 1) if "'" in s[i + 1 :] else n
            cur.append(("sq", s[i + 1 : j]))
            i = j + 1
            continue
        if c == '"':
            j = i + 1
            buf = []
            while j < n and s[j] != '"':
                if s[j] == "\\" and j + 1 < n:
                    buf.append(s[j : j + 2])
                    j += 1
                else:
                    buf.append(s[j])
                j += 1
            cur.append(("dq", "".join(buf)))
            i = j + 1
            continue
        # bare run up to next whitespace/quote
        j = i
        buf = []
        while j < n and s[j] not in " \t\n'\"":
            if s[j] == "\\" and j + 1 < n:
                buf.append(s[j + 1])
                j += 1
            else:
                buf.append(s[j])
            j += 1
        cur.append(("bare", "".join(buf)))
        i = j
    if cur:
        tokens.append(cur)
    return tokens


# ── variable resolution ─────────────────────────────────────────────────────
_VARREF = re.compile(r"^\$\{?(\w+)\}?$")


def build_var_maps(text, lib, overrides):
    """Return (path_vars, literal_vars).

    path_vars: NAME -> resolved filesystem path (from `--var` overrides and from
    `VAR="$LIB/..."` / `VAR=$OTHER` assignments).
    literal_vars: NAME -> literal string value (from `VAR='single-quoted'`).
    """
    path_vars = dict(overrides)
    literal_vars = {}
    # First pass: collect raw RHS of simple `NAME=...` assignments at line start.
    assigns = {}
    for _, line in join_logical_lines(text):
        m = re.match(r"^([A-Za-z_]\w*)=(.*)$", line)
        if not m:
            continue
        name, rhs = m.group(1), m.group(2).strip()
        assigns.setdefault(name, rhs)  # first assignment wins (definition order)
    # Literal vars: RHS is a single-quoted string (no interpolation).
    for name, rhs in assigns.items():
        if len(rhs) >= 2 and rhs[0] == "'" and rhs.endswith("'") and "'" not in rhs[1:-1]:
            literal_vars[name] = rhs[1:-1]
    # Path vars: iterative resolution of `$LIB`/`$OTHER`-based path assignments.
    for _ in range(10):
        changed = False
        for name, rhs in assigns.items():
            if name in path_vars:
                continue
            val = _resolve_path_rhs(rhs, lib, path_vars)
            if val is not None:
                path_vars[name] = val
                changed = True
        if not changed:
            break
    return path_vars, literal_vars


def _resolve_path_rhs(rhs, lib, path_vars):
    # Strip surrounding quotes if the whole RHS is quoted.
    r = rhs
    if len(r) >= 2 and r[0] == '"' and r.endswith('"'):
        r = r[1:-1]
    elif len(r) >= 2 and r[0] == "'" and r.endswith("'"):
        return None  # single-quoted -> a literal var, not a path
    # `$OTHER` alone
    m = _VARREF.match(r)
    if m:
        return path_vars.get(m.group(1))
    # `$LIB/relative...` or `${LIB}/...`
    m = re.match(r"^\$\{?LIB\}?/(.*)$", r)
    if m and lib is not None:
        return os.path.normpath(os.path.join(lib, m.group(1)))
    # `$OTHER/relative...`
    m = re.match(r"^\$\{?(\w+)\}?/(.*)$", r)
    if m and m.group(1) in path_vars:
        return os.path.normpath(os.path.join(path_vars[m.group(1)], m.group(2)))
    # A bare literal path (no `$`).
    if "$" not in r and "(" not in r and r:
        # Only treat as a path if it looks like one (has a slash or extension).
        if "/" in r or "." in r:
            return r if os.path.isabs(r) else os.path.normpath(os.path.join(lib or ".", r))
    return None


def resolve_arg(segments, literal_vars, path_vars, want_path):
    """Resolve one argument's segments to a string, or None if unresolvable.

    want_path=True resolves against path_vars (target file); otherwise against
    literal_vars (the pinned literal).
    """
    out = []
    for kind, val in segments:
        if kind == "sq":
            out.append(val)
        elif kind == "dq":
            # Neutralize backslash-escaped metacharacters first: `\$`, `` \` ``, `\"`,
            # `\\` are literal, not interpolation. Only an UNescaped `$`/backtick that
            # remains is real interpolation (and then only a whole `$VAR` resolves).
            NUL, TCK = "\x00d", "\x00t"
            neutral = (
                val.replace("\\\\", "\x00b")
                .replace("\\$", NUL)
                .replace("\\`", TCK)
                .replace('\\"', '"')
            )
            if "$" in neutral or "`" in neutral:
                m = _VARREF.match(neutral)
                if not m:
                    return None
                repl = (path_vars if want_path else literal_vars).get(m.group(1))
                if repl is None and want_path:
                    repl = path_vars.get(m.group(1))
                if repl is None:
                    return None
                out.append(repl)
            else:
                out.append(neutral.replace(NUL, "$").replace(TCK, "`").replace("\x00b", "\\"))
        else:  # bare
            m = _VARREF.match(val)
            if m:
                repl = (path_vars if want_path else literal_vars).get(m.group(1))
                if repl is None and want_path:
                    repl = path_vars.get(m.group(1))
                if repl is None:
                    return None
                out.append(repl)
            elif "$" in val:
                return None
            else:
                out.append(val)
    return "".join(out)


# ── call-site extraction ────────────────────────────────────────────────────
def extract_pins(text, lib, overrides):
    """Yield dicts for each pin call site: resolved (literal, file) or unresolved."""
    path_vars, literal_vars = build_var_maps(text, lib, overrides)
    for lineno, line in join_logical_lines(text):
        stripped = line.lstrip()
        if stripped.startswith("#"):
            continue
        first = stripped.split(None, 1)
        if not first or first[0] not in HELPERS:
            continue
        toks = tokenize(stripped)
        if not toks or "".join(v for _, v in toks[0]) != first[0]:
            continue
        args = toks[1:]
        lit_idx, file_idx, default_file = HELPERS[first[0]]
        if lit_idx >= len(args):
            continue
        literal = resolve_arg(args[lit_idx], literal_vars, path_vars, want_path=False)
        if file_idx < len(args):
            fpath = resolve_arg(args[file_idx], literal_vars, path_vars, want_path=True)
        elif default_file is not None:
            fpath = path_vars.get(default_file)
        else:
            fpath = None
        yield {
            "lineno": lineno,
            "helper": first[0],
            "literal": literal,
            "file": fpath,
        }


# ── comment / rendering analysis of a target file ───────────────────────────
def hash_comment_regions(lines):
    """Return list of (lineno, comment_text) for #-comment regions, quote-aware."""
    out = []
    for i, line in enumerate(lines, 1):
        insq = indq = False
        start = None
        j = 0
        while j < len(line):
            c = line[j]
            if c == "\\" and (insq or indq):
                j += 2
                continue
            if c == "'" and not indq:
                insq = not insq
            elif c == '"' and not insq:
                indq = not indq
            elif c == "#" and not insq and not indq:
                start = j
                break
            j += 1
        if start is not None:
            out.append((i, line[start:]))
    return out


def md_comment_text(text):
    return "\n".join(re.findall(r"<!--(.*?)-->", text, flags=re.DOTALL))


def normalize_ws(s):
    return " ".join(s.split())


def multiliteral_help_renderings(text):
    """Yield the concatenated rendering of each multi-literal argparse help=.

    Detects `help=` followed by two or more adjacent string literals (Python's
    implicit string concatenation, optionally parenthesized / across lines).
    """
    out = []
    for m in re.finditer(r"help\s*=\s*\(?", text):
        i = m.end()
        lits = []
        while True:
            # skip whitespace and line continuations
            while i < len(text) and text[i] in " \t\r\n\\":
                i += 1
            if i >= len(text) or text[i] not in "'\"":
                break
            q = text[i]
            # handle triple quotes
            if text[i : i + 3] == q * 3:
                end = text.find(q * 3, i + 3)
                if end == -1:
                    break
                lits.append(text[i + 3 : end])
                i = end + 3
            else:
                j = i + 1
                buf = []
                while j < len(text) and text[j] != q:
                    if text[j] == "\\" and j + 1 < len(text):
                        buf.append(text[j + 1])
                        j += 1
                    else:
                        buf.append(text[j])
                    j += 1
                lits.append("".join(buf))
                i = j + 1
        if len(lits) >= 2:
            out.append("".join(lits))
    return out


# ── the two guards ──────────────────────────────────────────────────────────
def _target_ext(path, md_targets):
    """Extension used to pick the comment syntax; a `--md`-flagged target (e.g. the
    extensionless mktemp'd skill bundle, which is markdown) is treated as `.md`."""
    if path in md_targets:
        return ".md"
    return os.path.splitext(path)[1]


def run_lint(pin_source, lib, overrides, md_targets):
    text = _read(pin_source)
    unresolved = 0
    collisions = []
    for pin in extract_pins(text, lib, overrides):
        if pin["literal"] is None or pin["file"] is None:
            unresolved += 1
            sys.stderr.write(
                f"UNRESOLVED\t{pin_source}:{pin['lineno']}\t{pin['helper']}\t"
                f"literal={'?' if pin['literal'] is None else 'ok'}\t"
                f"file={'?' if pin['file'] is None else pin['file']}\n"
            )
            continue
        if not os.path.isfile(pin["file"]):
            unresolved += 1
            sys.stderr.write(
                f"UNRESOLVED\t{pin_source}:{pin['lineno']}\t{pin['helper']}\t"
                f"target-missing={pin['file']}\n"
            )
            continue
        ext = _target_ext(pin["file"], md_targets)
        ftext = _read(pin["file"])
        lit = pin["literal"]
        # The defect (#370): a comment occurrence that COEXISTS with an operative
        # occurrence — it inflates the count / can mask a refactored-away operative
        # site. A literal that lives ONLY in a comment (an SPDX-header pin, a
        # deliberately comment-targeted contract) is the pin's intended home, not the
        # count-inflation defect, so it is NOT flagged. Hence: flag only when the
        # literal appears in a comment AND ALSO outside every comment region.
        if ext in COMMENT_HASH_EXTS:
            lines = ftext.split("\n")
            comment_spans = {cln: ctext for cln, ctext in hash_comment_regions(lines)}
            in_comment_line = None
            for cln, ctext in comment_spans.items():
                if lit in ctext:
                    in_comment_line = cln
                    break
            if in_comment_line is not None:
                # Is there any occurrence OUTSIDE a comment? Strip each line's comment
                # region, then look for the literal in what remains.
                outside = "\n".join(
                    (line[: len(line) - len(comment_spans.get(i, ""))] if i in comment_spans else line)
                    for i, line in enumerate(lines, 1)
                )
                if lit in outside:
                    collisions.append((pin, in_comment_line))
        elif ext in COMMENT_MD_EXTS:
            comment_text = md_comment_text(ftext)
            if lit in comment_text:
                # Occurrence outside <!-- --> comments?
                outside = re.sub(r"<!--.*?-->", "", ftext, flags=re.DOTALL)
                if lit in outside:
                    collisions.append((pin, None))
    for pin, cln in collisions:
        loc = f":{cln}" if cln else ""
        print(f"COLLISION\t{pin['file']}{loc}\t{pin['helper']}@{pin_source}:{pin['lineno']}\t{pin['literal']}")
    sys.stderr.write(f"UNRESOLVED-COUNT\t{unresolved}\n")
    return 0


def run_wrapped(pin_source, lib, overrides, md_targets):
    text = _read(pin_source)
    unresolved = 0
    for pin in extract_pins(text, lib, overrides):
        if pin["literal"] is None or pin["file"] is None:
            unresolved += 1
            continue
        if not os.path.isfile(pin["file"]):
            unresolved += 1
            continue
        ftext = _read(pin["file"])
        lines = ftext.split("\n")
        lit = pin["literal"]
        on_a_line = any(lit in ln for ln in lines)
        if on_a_line:
            # If the phrase IS on a line but that line is inside a multi-literal
            # help=, it is already fine (single rendered literal); nothing to flag.
            continue
        # occurs on no single line: distinguish wrapped vs absent.
        nlit = normalize_ws(lit)
        nfile = normalize_ws(ftext)
        if pin["file"].endswith(".py"):
            for rendering in multiliteral_help_renderings(ftext):
                if nlit and nlit in normalize_ws(rendering):
                    print(
                        f"HELP\t{pin['file']}\t{pin['helper']}@{pin_source}:{pin['lineno']}\t"
                        f"pin targets a multi-literal argparse help= string; pin the RENDERED "
                        f"surface (captured --help output / real stderr), not the source\t{lit}"
                    )
                    break
            else:
                _emit_wrapped_or_absent(pin, pin_source, nlit, nfile, lit)
        else:
            _emit_wrapped_or_absent(pin, pin_source, nlit, nfile, lit)
    sys.stderr.write(f"UNRESOLVED-COUNT\t{unresolved}\n")
    return 0


def _emit_wrapped_or_absent(pin, pin_source, nlit, nfile, lit):
    if nlit and nlit in nfile:
        print(
            f"WRAPPED\t{pin['file']}\t{pin['helper']}@{pin_source}:{pin['lineno']}\t"
            f"phrase occurs on NO single line but IS present in the whitespace-normalized "
            f"rendering — a wrapped-literal blind spot; pin the rendered surface\t{lit}"
        )
    else:
        print(
            f"ABSENT\t{pin['file']}\t{pin['helper']}@{pin_source}:{pin['lineno']}\t"
            f"phrase absent from the target entirely (not merely wrapped)\t{lit}"
        )


def _read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def main(argv):
    if len(argv) < 3 or argv[1] not in ("lint", "wrapped"):
        sys.stderr.write(__doc__ or "")
        return 2
    cmd, pin_source = argv[1], argv[2]
    lib = None
    overrides = {}
    md_targets = set()
    i = 3
    while i < len(argv):
        if argv[i] == "--lib" and i + 1 < len(argv):
            lib = argv[i + 1]
            i += 2
        elif argv[i] == "--var" and i + 1 < len(argv):
            name, _, val = argv[i + 1].partition("=")
            overrides[name] = val
            i += 2
        elif argv[i] == "--md" and i + 1 < len(argv):
            md_targets.add(argv[i + 1])
            i += 2
        else:
            sys.stderr.write(f"unknown arg: {argv[i]}\n")
            return 2
    if lib is None:
        lib = os.path.dirname(os.path.dirname(os.path.abspath(pin_source)))
    if cmd == "lint":
        return run_lint(pin_source, lib, overrides, md_targets)
    return run_wrapped(pin_source, lib, overrides, md_targets)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
