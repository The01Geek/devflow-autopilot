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

  **Relocation diagnosis (issue #661, opt-in via ``--reloc``).** A bare
  ``ABSENT`` reads identically for a pin literal that was *relocated* into a
  different file and one that was genuinely *deleted*. When ``--reloc`` is
  passed and a pin literal is ABSENT from its named target (whitespace-normalized
  and rendered-surface, so a wrapped literal still counts), the guard searches a
  scoped tracked-file set — from ``--reloc-search-set`` when supplied (the
  git-free path the self-tests use) else ``git ls-files`` — **minus** the
  pin-source file(s) that declare the literal (auto-excluded plus any
  ``--reloc-exclude`` prefix) and the non-source trees ``.devflow/vendor/`` /
  ``.devflow/tmp/``, and reports every other file where the literal resolves as
  ``RELOCATED … relocated to <file>; update the pin target``. Only when the set
  was enumerated successfully **and** the literal resolves nowhere in it does it
  read ``deleted (not found anywhere)`` — a failed/empty enumeration is reported
  ``relocation diagnosis unavailable`` on stderr and is **never** collapsed to
  ``deleted`` (fail-closed). Without ``--reloc`` the ABSENT emit is unchanged.

**Fail-closed:** a call site the scanner cannot resolve statically (the literal
interpolates a variable it cannot resolve, or the target file is a variable with
no ``--var`` binding and no ``$LIB``-relative assignment) is COUNTED and reported
on stderr, never silently skipped.

Both subcommands exit 0. Findings go to stdout (one per line, tab-separated);
the unresolvable count and per-site detail go to stderr.

CLI::

    pin-corpus-lint.py lint    PIN_SOURCE [--lib DIR] [--var NAME=PATH ...]
    pin-corpus-lint.py wrapped PIN_SOURCE [--lib DIR] [--var NAME=PATH ...]
                               [--reloc] [--reloc-search-set FILE]
                               [--reloc-exclude PREFIX ...]

``PIN_SOURCE`` is the shell file whose pin call sites are scanned (``run.sh``
itself for the real corpus, a synthetic fixture for the self-tests). ``--var``
supplies the runtime value of a target-file variable the helper cannot resolve
statically (e.g. ``DEF_SKILL``, the mktemp'd implement-skill bundle); ``--lib``
binds ``$LIB`` so ``VAR="$LIB/../skills/…"`` assignments resolve on their own.
``--reloc`` enables the issue-#661 relocation diagnosis on the ``wrapped``
guard's ABSENT branch; ``--reloc-search-set FILE`` supplies the search set as a
newline-delimited file (git-free, for the self-tests) instead of ``git
ls-files``; ``--reloc-exclude PREFIX`` (repeatable) drops any tracked path
containing PREFIX from the search set (the pin-source file(s) that declare the
literal).
"""

from __future__ import annotations

import os
import re
import subprocess
import sys

# Non-source trees always excluded from the relocation search set (issue #661): a
# committed vendored plugin copy and the run's own draft/derivation artifacts both
# quote pin literals and would otherwise be reported as spurious destinations.
RELOC_DEFAULT_EXCLUDES = (".devflow/vendor/", ".devflow/tmp/")

# (literal_arg_index, file_arg_index, default_file_var).  Indices are 0-based
# over the call's arguments AFTER the helper name.  A file index past the actual
# arg list means the optional file arg was omitted -> use default_file_var.
HELPERS = {
    "assert_pin_unique": (1, 2, None),
    "pin_count": (0, 1, None),
    "assert_pin_red_on_removal": (1, 2, "MAXI_SKILL"),
    "assert_pin_red_under": (1, 3, "MAXI_SKILL"),
    # Namespaced module pin API (module-harness.sh, issue #577) so the meta-lints
    # cover pins that extraction moves out of run.sh into lib/test/modules/*.sh
    # (issue #591). Module pins always pass the target file explicitly — no default.
    "devflow_module_pin_count": (0, 1, None),
    "devflow_module_pin_unique": (1, 2, None),
    "devflow_module_pin_present": (1, 2, None),
    "devflow_module_pin_red_under": (1, 3, None),
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
                if repl is None:
                    return None
                out.append(repl)
            else:
                out.append(neutral.replace(NUL, "$").replace(TCK, "`").replace("\x00b", "\\"))
        else:  # bare
            m = _VARREF.match(val)
            if m:
                repl = (path_vars if want_path else literal_vars).get(m.group(1))
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
            # A pin call with too few args to carry its literal — malformed, but still
            # surfaced as unresolved (literal=None) rather than silently dropped, honoring
            # the "never silently skipped" contract.
            yield {"lineno": lineno, "helper": first[0], "literal": None, "file": None}
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
            elif (
                c == "#"
                and not insq
                and not indq
                and (j == 0 or line[j - 1] in " \t")
            ):
                # A `#` starts a shell/py comment only at a word boundary (line start
                # or after whitespace) — mirroring tokenize()'s `not cur` rule. Keying
                # on any unquoted `#` misclassified a mid-word `#` (e.g. `url#anchor`)
                # as a comment start, moving operative text into the "comment" region
                # and making a real collision go UNFLAGGED (a fail-open in the guard
                # direction).
                start = j
                break
            j += 1
        if start is not None:
            out.append((i, line[start:]))
    return out


def md_comment_text(text):
    return "\n".join(re.findall(r"<!--(.*?)-->", text, flags=re.DOTALL))


def md_fenced_hash_comment_spans(text):
    """Return {lineno: comment_text} for #-comment regions inside fenced code
    blocks (``` / ~~~, language-tagged or indented) of a markdown target.

    The #375 .md arm scanned only HTML ``<!-- … -->`` regions; a pin literal
    quoted in a ``#`` comment inside a ```` ```bash ```` fence of a skill bundle
    was folded into the operative "outside" text, so a #370-class count-inflation
    collision there went unflagged (issue #394). Extracting these fenced ``#``
    comments lets the .md arm subtract them from "outside" symmetrically with the
    .sh/.py arm, so such a collision is flagged while a literal living ONLY in a
    fenced comment (the ``lit in outside`` conjunct) still is not.

    Fence tracking mirrors CommonMark's opener/closer rules enough for this use:
    an opening fence is a line whose first non-space run is >=3 backticks or
    tildes (a backtick opener's info string may not itself contain a backtick);
    the matching closer is the same marker char, at least as long, with only
    whitespace after it. Language-tagged fences and fences indented up to 3
    spaces are handled; a run indented >=4 spaces is CommonMark *indented code*,
    NOT a fence, so it is deliberately not treated as a fence marker — otherwise
    a deeply-indented ``` in prose would spuriously open a never-closed fence and
    fold every following operative ``#``-line into the comment region, a
    fail-open that could hide a real #370-class collision (issue #394 review).
    The fence markers themselves are never treated as content.

    An UNTERMINATED fence fails closed (issue #394 review): a fence opener that
    never meets a matching closer before EOF is suspect (a stray/unbalanced ```
    in a malformed target), so its content lines are discarded rather than folded
    into the comment region — otherwise every following operative ``#``-line (an
    ATX heading, say) would be stripped out of "outside", masking a real
    #370-class collision. Only lines inside a PROPERLY CLOSED fence are trusted.
    """
    lines = text.split("\n")
    fence = None  # (char, length) while inside a fence, else None
    inside = []  # (lineno, line) content lines strictly inside fences
    committed = 0  # inside[:committed] are lines from PROPERLY CLOSED fences
    for i, line in enumerate(lines, 1):
        # 0-3 leading spaces only (>=4 is indented code, not a fence marker).
        m = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", line)
        if fence is None:
            # A backtick opener's info string must not contain a backtick.
            if m and not (m.group(1)[0] == "`" and "`" in m.group(2)):
                fence = (m.group(1)[0], len(m.group(1)))
            continue
        if (
            m
            and m.group(1)[0] == fence[0]
            and len(m.group(1)) >= fence[1]
            and m.group(2).strip() == ""
        ):
            fence = None
            committed = len(inside)  # this fence closed cleanly — trust its lines
            continue
        inside.append((i, line))
    # Fail closed on an UNTERMINATED trailing fence (issue #394 review): a stray or
    # unbalanced opener that never meets a closer is suspect, so drop its content
    # rather than fold every following operative `#`-line out of "outside" and mask a
    # real #370-class collision. Only PROPERLY CLOSED fences' lines are trusted.
    if fence is not None:
        inside = inside[:committed]
    spans = {}
    for idx, ctext in hash_comment_regions([ln for _, ln in inside]):
        spans[inside[idx - 1][0]] = ctext
    return spans


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


def _strip_line_spans(lines, spans):
    """Remove each line-keyed comment suffix from `lines`, returning the joined
    "outside-comments" text. Shared by the hash arm and the .md fenced-#-comment
    arm (issue #394) so the two subtractions stay in lockstep rather than being
    two hand-maintained copies of the same off-by-one-prone slice."""
    return "\n".join(
        (line[: len(line) - len(spans[i])] if i in spans else line)
        for i, line in enumerate(lines, 1)
    )


def _lint_view(path, ext, cache):
    """Memoized per-target-file comment analysis (read + comment regions + the
    outside-comments text). Many pins share a target, so this is derived once per
    file rather than once per pin."""
    v = cache.get(path)
    if v is not None:
        return v
    ftext, err = _read_target(path)
    if err is not None:
        v = ("unreadable", err, None)
        cache[path] = v
        return v
    if ext in COMMENT_HASH_EXTS:
        lines = ftext.split("\n")
        comment_spans = {cln: ctext for cln, ctext in hash_comment_regions(lines)}
        outside = _strip_line_spans(lines, comment_spans)
        v = ("hash", comment_spans, outside)
    elif ext in COMMENT_MD_EXTS:
        # Comment regions of a .md target are BOTH its HTML <!-- … --> spans AND
        # the #-comments inside its fenced code blocks (issue #394). Union them
        # into `comments`, and subtract both from `outside` symmetrically so a
        # literal living only in a fenced # comment is removed from "outside"
        # (preserving the `lit in outside` conjunct) exactly as the .sh/.py arm.
        fenced_spans = md_fenced_hash_comment_spans(ftext)
        comment_text = md_comment_text(ftext)
        if fenced_spans:
            comment_text = comment_text + "\n" + "\n".join(fenced_spans.values())
        without_fenced = _strip_line_spans(ftext.split("\n"), fenced_spans)
        outside = re.sub(r"<!--.*?-->", "", without_fenced, flags=re.DOTALL)
        v = ("md", comment_text, outside)
    else:
        v = ("none", None, None)
    cache[path] = v
    return v


def _wrapped_view(path, cache):
    """Memoized per-target-file wrapped-literal analysis (lines + whitespace-normalized
    whole file + normalized multi-literal help= renderings). Derived once per file."""
    v = cache.get(path)
    if v is not None:
        return v
    ftext, err = _read_target(path)
    if err is not None:
        v = ("unreadable", err, None)
        cache[path] = v
        return v
    helps = [normalize_ws(r) for r in multiliteral_help_renderings(ftext)] if path.endswith(".py") else []
    v = (ftext.split("\n"), normalize_ws(ftext), helps)
    cache[path] = v
    return v


def run_lint(pin_source, lib, overrides, md_targets):
    text = _read(pin_source)
    unresolved = 0
    resolved = 0
    collisions = []
    view_cache = {}
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
        kind, comments, outside = _lint_view(pin["file"], ext, view_cache)
        if kind == "unreadable":
            unresolved += 1
            sys.stderr.write(
                f"UNRESOLVED\t{pin_source}:{pin['lineno']}\t{pin['helper']}\t"
                f"target-unreadable={pin['file']} ({comments})\n"
            )
            continue
        resolved += 1
        lit = pin["literal"]
        # The defect (#370): a comment occurrence that COEXISTS with an operative
        # occurrence — it inflates the count / can mask a refactored-away operative
        # site. A literal that lives ONLY in a comment (an SPDX-header pin, a
        # deliberately comment-targeted contract) is the pin's intended home, not the
        # count-inflation defect, so it is NOT flagged. Hence: flag only when the
        # literal appears in a comment AND ALSO outside every comment region.
        if kind == "hash":
            in_comment_line = next((cln for cln, ctext in comments.items() if lit in ctext), None)
            if in_comment_line is not None and lit in outside:
                collisions.append((pin, in_comment_line))
        elif kind == "md":
            if lit in comments and lit in outside:
                collisions.append((pin, None))
    for pin, cln in collisions:
        loc = f":{cln}" if cln else ""
        print(f"COLLISION\t{pin['file']}{loc}\t{pin['helper']}@{pin_source}:{pin['lineno']}\t{pin['literal']}")
    sys.stderr.write(f"UNRESOLVED-COUNT\t{unresolved}\n")
    sys.stderr.write(f"RESOLVED-COUNT\t{resolved}\n")
    return 0


# ── #661 relocation diagnosis ───────────────────────────────────────────────
def _git_ls_files():
    """Enumerate tracked files with the granted ``git ls-files``. Returns
    (paths, None) on success or (None, reason) fail-closed on any error / empty
    output — the caller must NOT collapse a failed enumeration to "deleted"."""
    try:
        res = subprocess.run(
            ["git", "ls-files", "-z"], capture_output=True, text=True, check=False
        )
    except OSError as exc:
        return None, f"git-ls-files-error:{type(exc).__name__}"
    if res.returncode != 0:
        return None, f"git-ls-files-rc:{res.returncode}"
    paths = [p for p in res.stdout.split("\0") if p]
    if not paths:
        return None, "git-ls-files-empty"
    return paths, None


def resolve_reloc_search_set(explicit_file):
    """Resolve the relocation search set. An explicit ``--reloc-search-set`` file
    (the git-free self-test path) wins; otherwise ``git ls-files``. A file that is
    unreadable, or a raw enumeration that fails or is empty, returns (None, reason)
    so the ABSENT branch fails closed rather than reporting a false deletion."""
    if explicit_file is not None:
        try:
            raw = _read(explicit_file)
        except OSError as exc:
            return None, f"search-set-unreadable:{type(exc).__name__}"
        paths = [ln.strip() for ln in raw.splitlines() if ln.strip()]
        if not paths:
            return None, "search-set-empty"
        return paths, None
    return _git_ls_files()


def _reloc_excluded(path, exclude_tokens):
    """A search-set path is excluded when any exclude token is a substring of it
    (the distinctive ``.devflow/vendor/`` / ``.devflow/tmp/`` trees, or a
    pin-source path/prefix). Substring — not just prefix — so a temp-dir stand-in
    like ``/tmp/xxx/.devflow/vendor/copy.md`` matches the same token a
    repo-relative ``.devflow/vendor/…`` path does."""
    return any(tok and tok in path for tok in exclude_tokens)


def _literal_resolves_in(lit, nlit, path, cache):
    """True when the pin literal resolves in a candidate file — on a single line,
    in the whitespace-normalized rendering (a wrapped-adjacent-literal destination,
    #375), or in a multi-literal argparse help= rendering. Reuses _wrapped_view so
    an unreadable candidate is simply not a destination (never a crash)."""
    view = _wrapped_view(path, cache)
    if view[0] == "unreadable":
        return False
    lines, nfile, helps = view
    if any(lit in ln for ln in lines):
        return True
    if nlit and nlit in nfile:
        return True
    return bool(nlit and any(nlit in h for h in helps))


def diagnose_relocation(lit, nlit, target, search_paths, exclude_tokens, cache):
    """Given the resolved (non-None) search set, return the sorted list of files
    (excluding the pin-source/vendor/tmp set and the target itself) where the
    literal resolves. An empty list means the literal was found nowhere → the
    caller reports a genuine deletion."""
    dests = []
    for path in search_paths:
        if path == target or _reloc_excluded(path, exclude_tokens):
            continue
        if _literal_resolves_in(lit, nlit, path, cache):
            dests.append(path)
    return sorted(set(dests))


def run_wrapped(pin_source, lib, overrides, md_targets,
                reloc=False, reloc_search_file=None, reloc_exclude=None):
    text = _read(pin_source)
    unresolved = 0
    resolved = 0
    view_cache = {}
    # Resolve the relocation search set ONCE (issue #661) — only when --reloc is on.
    # A resolution failure is carried as (None, reason): the ABSENT branch then reports
    # "relocation diagnosis unavailable" and never a false "deleted". The pin-source file
    # is auto-excluded (a pin literal is present in its own declaration by construction),
    # alongside the always-on vendor/tmp trees and any --reloc-exclude prefix.
    reloc_paths, reloc_err = (None, None)
    reloc_excludes = ()
    if reloc:
        reloc_paths, reloc_err = resolve_reloc_search_set(reloc_search_file)
        reloc_excludes = (
            (pin_source,) + tuple(RELOC_DEFAULT_EXCLUDES) + tuple(reloc_exclude or ())
        )
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
        lines, nfile, helps = _wrapped_view(pin["file"], view_cache)
        if lines == "unreadable":
            unresolved += 1
            sys.stderr.write(
                f"UNRESOLVED\t{pin_source}:{pin['lineno']}\t{pin['helper']}\t"
                f"target-unreadable={pin['file']} ({nfile})\n"
            )
            continue
        resolved += 1
        lit = pin["literal"]
        if any(lit in ln for ln in lines):
            # The phrase IS on a line; nothing to flag.
            continue
        # occurs on no single line: distinguish a multi-literal help= (needs the
        # rendered surface), a whitespace-wrapped phrase, and a genuinely-absent one.
        nlit = normalize_ws(lit)
        if nlit and any(nlit in h for h in helps):
            print(
                f"HELP\t{pin['file']}\t{pin['helper']}@{pin_source}:{pin['lineno']}\t"
                f"pin targets a multi-literal argparse help= string; pin the RENDERED "
                f"surface (captured --help output / real stderr), not the source\t{lit}"
            )
            continue
        _emit_wrapped_or_absent(
            pin, pin_source, nlit, nfile, lit,
            reloc=reloc, reloc_paths=reloc_paths, reloc_err=reloc_err,
            reloc_excludes=reloc_excludes, cache=view_cache,
        )
    sys.stderr.write(f"UNRESOLVED-COUNT\t{unresolved}\n")
    sys.stderr.write(f"RESOLVED-COUNT\t{resolved}\n")
    return 0


def _emit_wrapped_or_absent(pin, pin_source, nlit, nfile, lit,
                            reloc=False, reloc_paths=None, reloc_err=None,
                            reloc_excludes=(), cache=None):
    if nlit and nlit in nfile:
        print(
            f"WRAPPED\t{pin['file']}\t{pin['helper']}@{pin_source}:{pin['lineno']}\t"
            f"phrase occurs on NO single line but IS present in the whitespace-normalized "
            f"rendering — a wrapped-literal blind spot; pin the rendered surface\t{lit}"
        )
        return
    site = f"{pin['helper']}@{pin_source}:{pin['lineno']}"
    if not reloc:
        # Relocation diagnosis off — the pre-#661 ABSENT emit, byte-identical.
        print(
            f"ABSENT\t{pin['file']}\t{site}\t"
            f"phrase absent from the target entirely (not merely wrapped)\t{lit}"
        )
        return
    if reloc_paths is None:
        # The search set could not be enumerated (git ls-files failed/empty, or an
        # unreadable --reloc-search-set). Fail closed: report unavailability on stderr
        # and NEVER collapse to "deleted" — a failed enumeration is not evidence of
        # deletion. stdout still carries an ABSENT line so a real absent pin stays RED.
        sys.stderr.write(
            f"RELOC-UNAVAILABLE\t{pin['file']}\t{site}\t{reloc_err}\n"
        )
        print(
            f"ABSENT\t{pin['file']}\t{site}\t"
            f"phrase absent from the target entirely; relocation diagnosis unavailable "
            f"({reloc_err})\t{lit}"
        )
        return
    dests = diagnose_relocation(lit, nlit, pin["file"], reloc_paths, reloc_excludes, cache or {})
    if dests:
        print(
            f"RELOCATED\t{pin['file']}\t{site}\t"
            f"relocated to {', '.join(dests)}; update the pin target\t{lit}"
        )
    else:
        print(
            f"ABSENT\t{pin['file']}\t{site}\t"
            f"phrase absent from the target AND from the scoped tracked-file set — "
            f"deleted (not found anywhere)\t{lit}"
        )


def _read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def _read_target(path):
    """Read a resolved target file, returning (text, None) on success or
    (None, reason) when the file passed os.path.isfile yet cannot be read or
    decoded (permission, non-UTF-8, a directory racing in). Its callers turn a
    non-None reason into an UNRESOLVED count + stderr breadcrumb — so a
    resolved-but-unreadable target fails CLOSED (counted, matching the module's
    fail-closed contract) instead of raising an uncaught exception that would
    empty stdout and pass the real-corpus assertion vacuously (issue #375 review)."""
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read(), None
    except (OSError, UnicodeDecodeError) as exc:
        return None, type(exc).__name__


def main(argv):
    if len(argv) < 3 or argv[1] not in ("lint", "wrapped"):
        sys.stderr.write(__doc__ or "")
        return 2
    cmd, pin_source = argv[1], argv[2]
    lib = None
    overrides = {}
    md_targets = set()
    reloc = False
    reloc_search_file = None
    reloc_exclude = []
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
        elif argv[i] == "--reloc":
            reloc = True
            i += 1
        elif argv[i] == "--reloc-search-set" and i + 1 < len(argv):
            reloc_search_file = argv[i + 1]
            i += 2
        elif argv[i] == "--reloc-exclude" and i + 1 < len(argv):
            reloc_exclude.append(argv[i + 1])
            i += 2
        else:
            sys.stderr.write(f"unknown arg: {argv[i]}\n")
            return 2
    if lib is None:
        lib = os.path.dirname(os.path.dirname(os.path.abspath(pin_source)))
    if cmd == "lint":
        return run_lint(pin_source, lib, overrides, md_targets)
    return run_wrapped(
        pin_source, lib, overrides, md_targets,
        reloc=reloc, reloc_search_file=reloc_search_file, reloc_exclude=reloc_exclude,
    )


if __name__ == "__main__":
    sys.exit(main(sys.argv))
