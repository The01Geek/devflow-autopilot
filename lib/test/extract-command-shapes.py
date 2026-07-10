#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Flag proven-denied command *shapes* in the ```bash fences of a Markdown file.

Why this exists (issue #401). `lib/test/extract-command-heads.py` (issue #363)
validates that every command *head* the review skill invokes is granted by both
cloud allowlists. But the deployed `claude-code-action` matcher denies whole
command *shapes* even when the head is granted — a leading `VAR="…"` assignment, a
shell `>`/`>>` redirect to `/tmp`, a `cat`-headed heredoc write, a leading `cd`,
or an interpreter head (`python3`) the read-only `review` profile never grants.
When the engine emits one of those, the harness refuses it silently, the run burns
budget re-trying variants, and a cloud review can end with no verdict at all
(Devflow Review run 29105381021 on PR #397: 22 denials, engine quit mid-Phase-3).

The denied shapes here are keyed to the empirical matcher probe, whose evidence of
record is `.github/workflows/matcher-probe.yml`'s job-summary table (re-runnable
after any `claude-code-action` / Claude Code CLI upgrade — URLs rot, the workflow
does not). This module is the desk-time drift pin for that class: it turns a review
fence that teaches a denied shape RED before it ships.

Scope boundary (deliberate — mirrors extract-command-heads.py's narrow reach):

* Only ```bash fences are scanned. Inline-backtick prose is out of reach (matching
  it resurrects the false-positive class the head extractor documents), so a
  positive-recipe example written in prose is intentionally invisible here.
* R3 flags a `>`/`>>` redirect only when its target is under `/tmp/` (out of the
  workspace, and the exact shape the probe denied), NOT every `>` redirect: an
  in-workspace `> .devflow/tmp/…` write of a granted head is left to the existing
  head/allowlist pins, matching how the skill already authors run-scoped scratch.
  A `cat`-headed heredoc write (`cat >`/`cat >>` … `<<`) is flagged to ANY target,
  because the probe denied the heredoc-write shape itself (probe row 1).
* R1 flags an env-prefix compound (`VAR=v cmd …`) and a computed double-quoted
  literal assignment (`MARKER="…"`), NOT a pure-shell sentinel/counter/status
  capture (`WP=""`, `n=0`, `rc=$?`, `VAR=$'…'`) nor a command-substitution capture
  (`WP=$(cmd)` / `WP="$(cmd)"` — the proven-PERMITTED form the matcher descends
  into, real-run evidence: run 29105381021 seeded its progress comment through
  exactly a `WP=$(vendored-path create …)` call).

Rule table (each keyed to a probe row / run — see .github/workflows/matcher-probe.yml):

  R1  a fence statement whose leading token is a `VAR=value` assignment —
      env-prefix compound (`M=x printf …`, probe row 2) OR a computed
      double-quoted literal (`MARKER="…"`, run 29105381021 denials). The
      proven-permitted `VAR=$(cmd)` / `VAR="$(cmd)"` capture is NOT flagged.
  R2  a leading `cd` (probe row 3 — DROPPED as unproven/confounded; treat as denied).
  R3  a `>`/`>>` redirect (stdout or `2>`/`&>` stderr) to a `/tmp/…` target
      (probe rows 1,2,7 — out-of-workspace + `>`-redirect denials), OR a
      `cat`-headed heredoc write (`cat >`/`cat >>` with `<<`) to ANY target
      (probe row 1 — heredoc-write shape denied; row 6 shows only `tee` passes).
  R4  a leading interpreter (`python3`, `python`, `node`) — the read-only
      `review` profile grants no interpreter (run 29105381021 denials).

CLI:
    extract-command-shapes.py FILE
        -> one `FILE:LINE  RULE  statement` per denied-shape hit; exit 1 if any hit,
           exit 0 when the file is clean.
"""

from __future__ import annotations

import importlib.util
import os
import re
import sys

# Reuse the issue-#363 extractor's fence/quote/heredoc/substitution machinery so
# the two guards can never disagree about what a "statement" is.
_HEADS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "extract-command-heads.py")
_spec = importlib.util.spec_from_file_location("extract_command_heads", _HEADS_PATH)
_heads = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_heads)

_ASSIGNMENT = _heads._ASSIGNMENT
_HEREDOC = _heads._HEREDOC

# Control words that may legally precede a command (or an assignment-capture) in a
# condition. Stripped before the shape check so `elif WP=$(cmd)` is read as its
# `WP=$(cmd)` capture, not misread as a bare-`elif` head.
_CONTROL = frozenset({"if", "elif", "while", "until", "!"})

_INTERPRETERS = frozenset({"python3", "python", "node"})

# A redirection token: an optional fd/`&` then `>`/`>>`, with the target either
# attached (`2>/tmp/f`) or in the next token (`> /tmp/f`).
_REDIR = re.compile(r"^&?[0-9]*(>>|>)(.*)$")


def _shape_preprocess(block: str) -> str:
    """Drop `#` comments (quote-aware) and heredoc BODIES, but KEEP the heredoc
    OPENER token (`<<'EOF'`) so a `cat > f <<'EOF'` write is still one statement.

    This differs from extract-command-heads.py's stripper, which truncates the
    opener at `<<` — that erases the very signal R3's cat-heredoc arm needs.
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
            # KEEP cleaned as-is (opener token retained) — do NOT truncate at <<.
        out.append(cleaned)
    return "\n".join(out)


def _statements(block: str) -> list[str]:
    """Every logical statement of a fence block, substitutions descended into."""
    cleaned = _heads._strip_case_patterns(_shape_preprocess(block))
    joined = _heads._join_continuations(cleaned)
    result: list[str] = []
    _collect_statements(joined, result)
    return result


def _collect_statements(text: str, out: list[str]) -> None:
    for statement in _heads._split_statements(text):
        for body in _heads._substitutions(statement):
            _collect_statements(body, out)
        out.append(statement)


def _leading_after_control(tokens: list[str]) -> list[str]:
    i = 0
    while i < len(tokens) and tokens[i] in _CONTROL:
        i += 1
    return tokens[i:]


def _is_command_token(token: str) -> bool:
    """True when a token is a plausible command head (not an assignment, redirect,
    heredoc opener, separator remnant, or shell syntax word)."""
    if not token or _ASSIGNMENT.match(token):
        return False
    if _REDIR.match(token) or token.startswith("<<") or token.startswith("<"):
        return False
    norm = _heads._normalize(token)
    if not norm or norm in _heads.RESERVED:
        return False
    return True


_CONTROL_PREFIX = re.compile(r"^(?:if|elif|while|until|!)\s+")


def _assignment_violation(statement: str) -> bool:
    raw = statement.strip()
    # Strip leading control words so `elif WP=$(cmd)` reads as its `WP=$(cmd)` capture.
    while True:
        stripped = _CONTROL_PREFIX.sub("", raw, count=1)
        if stripped == raw:
            break
        raw = stripped.lstrip()
    lead = re.match(r"^([A-Za-z_][A-Za-z0-9_]*=)(.*)$", raw, re.S)
    if not lead:
        return False
    value_rest = lead.group(2)
    vlstrip = value_rest.lstrip()
    # PERMITTED substitution capture: `VAR=$(cmd)` / `VAR="$(cmd)"`. The matcher
    # descends into the substitution and matches the inner granted head — real-run
    # evidence (run 29105381021 seeded its progress comment through a
    # `WP=$(vendored-path create …)` call). Never a denied shape.
    if vlstrip.startswith("$(") or vlstrip.startswith('"$('):
        return False
    # R1b standalone computed literal: `VAR="…"` whose double-quoted content is
    # non-empty. A bare-word constant (`VAR=critical`), a numeric (`n=0`), a status
    # capture (`rc=$?`), an ANSI-C sentinel (`VAR=$'…'`), and an empty reset
    # (`WP=""` / `IFS=`) are all deliberately NOT this shape.
    if value_rest.startswith('"'):
        after = value_rest[1:]
        inner = after.split('"', 1)[0] if '"' in after else after
        return bool(inner.strip())
    # R1a env-prefix compound: a NON-EMPTY assignment value followed by a real
    # command (`M=x printf …`, probe row 2). `IFS= read …` — an EMPTY-valued prefix,
    # the pure-shell field-split idiom — is not this shape and never fires.
    tokens = _heads._tokenize(raw)
    if not tokens or not _ASSIGNMENT.match(tokens[0]):
        return False
    first_value = tokens[0].split("=", 1)[1]
    j = 0
    while j < len(tokens) and _ASSIGNMENT.match(tokens[j]):
        j += 1
    following = tokens[j:]
    return bool(first_value) and bool(following) and _is_command_token(following[0])


def _redirect_violation(statement: str) -> bool:
    tokens = _heads._tokenize(statement)
    for idx, tok in enumerate(tokens):
        m = _REDIR.match(tok)
        if not m:
            continue
        target = m.group(2)
        if not target:
            # target is the next token; skip fd-dup forms handled by the regex not matching `&`
            target = tokens[idx + 1] if idx + 1 < len(tokens) else ""
        target = target.strip("'\"")
        if target.startswith("/tmp/"):
            return True
    return False


def _cat_heredoc_violation(statement: str) -> bool:
    head = _heads._head_of(statement)
    if not head or head[0] != "cat":
        return False
    tokens = _heads._tokenize(statement)
    has_redirect = any(_REDIR.match(t) for t in tokens)
    has_heredoc = any(t.startswith("<<") for t in tokens)
    return has_redirect and has_heredoc


def classify(statement: str) -> list[str]:
    """Return the rule ids this statement violates (possibly several)."""
    hits: list[str] = []
    if _assignment_violation(statement):
        hits.append("R1")
    head = _heads._head_of(statement)
    if head and head[0] == "cd":
        hits.append("R2")
    if _redirect_violation(statement) or _cat_heredoc_violation(statement):
        hits.append("R3")
    if head and head[0] in _INTERPRETERS:
        hits.append("R4")
    return hits


def _fence_line_offsets(text: str) -> list[tuple[int, str]]:
    """Return (1-based line number, block-body) for every ```bash fence."""
    blocks: list[tuple[int, str]] = []
    body: list[str] | None = None
    start = 0
    for lineno, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        if body is None:
            if stripped == "```bash":
                body = []
                start = lineno + 1
            continue
        if stripped == "```":
            blocks.append((start, "\n".join(body)))
            body = None
            continue
        body.append(line)
    return blocks


def find_violations(text: str) -> list[tuple[int, str, str]]:
    """Every (approx line, rule, statement) denied-shape hit in the file's fences."""
    lines = text.splitlines()
    hits: list[tuple[int, str, str]] = []
    for start, block in _fence_line_offsets(text):
        for statement in _statements(block):
            rules = classify(statement)
            if not rules:
                continue
            # Best-effort line attribution: find the statement's first source-line
            # fragment verbatim in the fence's source lines.
            probe = statement.strip().split("\n", 1)[0][:40]
            lineno = start
            block_len = len(block.split("\n"))
            for off in range(block_len):
                src_idx = start - 1 + off
                if src_idx >= len(lines):
                    break
                if probe and probe in lines[src_idx]:
                    lineno = start + off
                    break
            for rule in rules:
                hits.append((lineno, rule, statement.strip()))
    return hits


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: extract-command-shapes.py FILE", file=sys.stderr)
        return 2
    path = argv[1]
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    hits = find_violations(text)
    for lineno, rule, statement in hits:
        oneline = " ".join(statement.split())
        if len(oneline) > 160:
            oneline = oneline[:157] + "..."
        print(f"{path}:{lineno}  {rule}  {oneline}")
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
