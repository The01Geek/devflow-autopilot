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
  A `cat`-headed heredoc write (`cat >`/`cat >>` … `<<`) is flagged to ANY target:
  the /tmp arm is probe-denied (row 1, which is /tmp-targeted and so confounded
  like row 7); the in-workspace arm is UNPROVEN either way and is banned as
  discipline in favor of the proven Write-tool/`tee` alternatives — a lint rule,
  not a probe result (mirrors skills/review/SKILL.md's discipline section).
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
      (/tmp arm probe-denied — row 1; in-workspace arm unproven, banned as
      discipline in favor of the proven `tee` (row 6) / Write-tool (row 9) forms).
  R4  a leading interpreter (`python3`, `python`, `node`) — the read-only
      `review` profile grants no interpreter (run 29105381021 denials).

CLI:
    extract-command-shapes.py [--profile review|implement] FILE
        -> one `FILE:LINE  RULE  statement` per denied-shape hit; exit 1 if any hit,
           exit 0 when the file is clean. The default `review` profile applies R1-R4
           (read-only review allowlist). `--profile implement` applies the implement-
           tier rules (issue #455), keyed to the SEPARATE devflow-implement matcher
           probe (matcher-probe.yml's implement-probe job):

  IR1 a `for` loop — ANY spelling, including C-style `for ((i=0;…))` — whose do…done
      span invokes a label helper (probe row I4). (`select … in` is not matched: a
      stated non-goal, never probed and never written in these files.)
  IR2 a `while` / `until` loop whose do…done span invokes a label helper (row I5,
      which measured the piped-`while read` spelling; the rule matches the loop
      keyword in COMMAND POSITION, so any spelling of the same denied shape is
      caught, not only the piped one).
  IR3 a command substitution invoking a label helper — `$(…)`, backtick, or `<(…)`
      process substitution — in ASSIGNMENT, ARGUMENT, or CONDITION position. (Row I6
      measured the ASSIGNMENT spelling; the others are the same shape, unmeasured, and
      flagged deliberately — a guard that knows one spelling of what it forbids is a hole.)
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

_INTERPRETERS = frozenset({"python3", "python", "node"})

# A redirection token: an optional fd/`&` then `>`/`>>`, with the target either
# attached (`2>/tmp/f`) or in the next token (`> /tmp/f`).
_REDIR = re.compile(r"^&?[0-9]*(>>|>)(.*)$")


def _strip_line_comment(line: str, quote: str | None = None) -> tuple[str, str | None]:
    """Drop a quote-aware `#` comment from one line. Returns `(cleaned, quote_state_out)`.

    `quote` carries the open-quote state IN from the previous line. A shell string spans
    lines, so a `#`-leading line INSIDE a multi-line double-quoted argument is argument
    text, not a comment — stripping it would hide any capture on it. But carrying state is
    not safe alone either (one unbalanced apostrophe would stop every later comment being
    stripped), so the IMPLEMENT scan (`find_implement_violations`) runs `_preprocess` BOTH
    ways and unions the hits — see `_mask_quoted_lines`, which makes the same trade for the
    loop scan. The review tier (`find_violations`) runs the per-line form only.
    """
    kept: list[str] = []
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
    return "".join(kept), quote


def _shape_preprocess_lines(block: str) -> list[str]:
    """`_shape_preprocess`, but LINE-PRESERVING: returns exactly one cleaned line per
    input line, so a caller that reports a block-relative line offset (the implement-
    tier loop scan) can clean the source and still attribute a hit to the right line.

    A heredoc BODY line is blanked to `""` rather than dropped — dropping it is what
    makes the joined form unusable for offset attribution. Blanking is equivalent for
    statement splitting (an empty line yields no statement).

    Two heredoc rules, both fail-CLOSED (a preprocessor that blanks what it cannot
    measure silently disarms every rule downstream of it — the worst failure this file
    can have, because it is invisible):

    * The opener is matched on the QUOTE-MASKED line, so a `<<` inside a string
      (`echo "see << EOF for details"`) cannot open a PHANTOM heredoc.
    * An opener whose terminator never appears in the block is NOT treated as a heredoc
      at all: its tail is scanned as ordinary shell. Blanking to end-of-block on an
      unterminated tag — an elided body, a `…` placeholder, a typo, all routine in the
      DOCUMENTATION fences this lint exists to scan — would blank the rest of the fence
      and let a denied shape below it ship green.
    """
    return _preprocess(block, carry_comments=False)[0]


def _preprocess(block: str, carry_comments: bool = False) -> tuple[list[str], list[int]]:
    """The single heredoc/comment scan. Returns `(cleaned_lines, expanding_body_offsets)`,
    where the second element lists the body lines of an UNQUOTED heredoc.

    Why that second list exists: a heredoc body is blanked because its text is DATA, not
    shell — a `for … done` written in one is inert. But that is only true of the text as
    *commands*. With an UNQUOTED delimiter (`<<EOF`, not `<<'EOF'`) the shell still expands
    command substitutions inside the body, so `$(apply-labels.sh …)` in there is a real,
    executed capture — the I6 denied shape — while a blanked body hides it from every rule.
    IR3 therefore re-scans exactly these lines (see `find_implement_violations`), while the
    loop rules keep ignoring them, which is correct for both.
    """
    raw_lines = block.split("\n")
    n = len(raw_lines)
    out: list[str] = []
    _q: str | None = None
    for _line in raw_lines:
        _cleaned, _q_out = _strip_line_comment(_line, _q if carry_comments else None)
        out.append(_cleaned)
        _q = _q_out
    expanding: list[int] = []
    i = 0
    while i < n:
        cleaned = out[i]
        # Masking preserves length, so the probe's offset is valid in `cleaned`; re-search
        # the ORIGINAL there to read the real tag (a quoted tag, `<<'EOF'`, is itself
        # masked, so the probe's own group(2) cannot be trusted).
        probe = _HEREDOC.search(_mask_quoted(cleaned))
        match = _HEREDOC.search(cleaned, probe.start()) if probe else None
        if not match:
            i += 1
            continue
        tag = match.group(2)
        close = next(
            (j for j in range(i + 1, n) if raw_lines[j].strip() == tag), None
        )
        if close is None:
            i += 1  # unterminated: NOT a heredoc — fail closed, keep scanning the tail
            continue
        if not match.group(1):  # unquoted tag ⇒ the shell EXPANDS substitutions in the body
            expanding.extend(range(i + 1, close))
        for k in range(i + 1, close + 1):  # body + terminator (opener token retained)
            out[k] = ""
        i = close + 1
    return out, expanding


def _shape_preprocess(block: str) -> str:
    """Drop `#` comments (quote-aware) and heredoc BODIES, but KEEP the heredoc
    OPENER token (`<<'EOF'`) so a `cat > f <<'EOF'` write is still one statement.

    This differs from extract-command-heads.py's stripper, which truncates the
    opener at `<<` — that erases the very signal R3's cat-heredoc arm needs.

    NOTE this DOES affect the review tier (R1-R4), which also reads this text. The
    blank-vs-drop change is behavior-preserving, but the two heredoc fail-closed rules in
    `_shape_preprocess_lines` are not: a `<<` inside a quoted string no longer opens a
    phantom heredoc, and an unterminated heredoc no longer blanks the tail — so a review
    statement that used to be silently swallowed is now scanned. That is a strict
    tightening (previously-missed shapes are now caught), never a loosening.
    """
    return "\n".join(_shape_preprocess_lines(block))


def _statements(block: str) -> list[str]:
    """Every logical statement of a fence block, substitutions descended into."""
    return _statements_from_lines(_shape_preprocess_lines(block))


def _statements_from_lines(clean_lines: list[str]) -> list[str]:
    """`_statements`, from lines a caller already preprocessed (so the implement-tier scan
    can union two different comment-strippings without re-deriving them)."""
    cleaned = _heads._strip_case_patterns("\n".join(clean_lines))
    joined = _heads._join_continuations(cleaned)
    result: list[str] = []
    _collect_statements(joined, result)
    return result


def _collect_statements(text: str, out: list[str]) -> None:
    for statement in _heads._split_statements(text):
        for body in _heads._substitutions(statement):
            _collect_statements(body, out)
        out.append(statement)


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


# Control words that may legally precede a command (or an assignment-capture) in a
# condition. Stripped before the shape check so `elif WP=$(cmd)` is read as its
# `WP=$(cmd)` capture, not misread as a bare-`elif` head.
_CONTROL_PREFIX = re.compile(r"^(?:if|elif|while|until|!)\s+")


def _leading_substitution_split(value: str):
    """For an assignment value beginning `$(` or `"$(`, find where that leading
    substitution ends and return `(balanced, rest_after_it)`; return None when the
    value does not begin with one. The walk tracks paren depth with single/double
    quote and backslash awareness, so a capture whose inner command carries its own
    quoted arguments is measured by its real closing paren, not the first `)`."""
    v = value.lstrip()
    quoted = v.startswith('"$(')
    if not (v.startswith("$(") or quoted):
        return None
    i = 3 if quoted else 2  # first char inside the substitution
    depth = 1
    in_d = in_s = False
    while i < len(v):
        c = v[i]
        if in_s:
            if c == "'":
                in_s = False
        elif c == "\\":
            i += 1  # skip the escaped char (no escapes exist inside single quotes)
        elif in_d:
            if c == '"':
                in_d = False
        elif c == "'":
            in_s = True
        elif c == '"':
            in_d = True
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                i += 1
                if quoted:
                    if i < len(v) and v[i] == '"':
                        i += 1
                    else:  # `"$(…)` never re-closed its quote — not a clean capture
                        return (False, v[i:])
                return (True, v[i:])
        i += 1
    return (False, "")


def _strip_control(raw: str) -> str:
    """Iteratively strip leading control words (`if`/`elif`/`!`/…) so a wrapped
    `VAR=$(cmd)` capture reads as its bare assignment.

    Used by the review-tier `_assignment_violation` ONLY. The implement-tier
    `_label_capture_violation` deliberately does not call it: IR3 scans the substitution
    bodies of the WHOLE statement, so a leading control word is already irrelevant there —
    which is exactly what lets it catch `if [ -n "$(…)" ]` and `export LBL=$(…)` for free."""
    while True:
        stripped = _CONTROL_PREFIX.sub("", raw, count=1)
        if stripped == raw:
            return raw
        raw = stripped.lstrip()


def _assignment_violation(statement: str) -> bool:
    raw = statement.strip()
    # Strip leading control words so `elif WP=$(cmd)` reads as its `WP=$(cmd)` capture.
    raw = _strip_control(raw)
    lead = re.match(r"^([A-Za-z_][A-Za-z0-9_]*=)(.*)$", raw, re.S)
    if not lead:
        return False
    value_rest = lead.group(2)
    # Substitution-valued assignment: `VAR=$(…)` / `VAR="$(…)"`. A PURE capture (the
    # substitution spans the whole statement) is permitted — the matcher descends into
    # the substitution and matches the inner granted head; real-run evidence: run
    # 29105381021 seeded its progress comment through a `WP=$(vendored-path create …)`
    # call. But the same value followed by a command token — `M=$(x) printf hi` — is
    # the denied leading-`VAR=value` env-prefix shape exactly like a literal value
    # (the pre-fix version exempted EVERY `$(`-value here before checking for a
    # following command — the fail-open the PR #397 review caught). The split is done
    # by a quote-aware balanced scan, NOT the tokenizer, because a capture whose inner
    # command carries its own double quotes (`TELEM="$(… "$WORKPAD_DIR" …)"`) splinters
    # under naive tokenization.
    sub = _leading_substitution_split(value_rest)
    if sub is not None:
        balanced, rest = sub
        if balanced and not rest.strip():
            return False
        if balanced:
            # A chain of further assignments (`M=$(x) N=1 cmd`) is still the same
            # env-prefix compound — skip assignment tokens (each of which may itself
            # carry a substitution value) and judge the first non-assignment token.
            rest_s = rest.lstrip()
            while True:
                chain = re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", rest_s)
                if not chain:
                    break
                tail = rest_s[chain.end():]
                nested = _leading_substitution_split(tail)
                if nested is not None:
                    n_balanced, n_rest = nested
                    if not n_balanced:
                        return True  # fail closed on an unmeasurable chain
                    rest_s = n_rest.lstrip()
                else:
                    parts = tail.split(None, 1)
                    rest_s = parts[1].lstrip() if len(parts) > 1 else ""
            if not rest_s:
                return False  # a chain of captures/assignments with no command
            return _is_command_token(rest_s.split(None, 1)[0])
        # Unbalanced leading substitution inside one statement: a splitting artifact
        # or crafted input. Fail CLOSED — flag rather than exempt what the scan could
        # not measure (a guard that shrugs here re-opens the fail-open).
        return True
    # R1b standalone computed literal: `VAR="…"` whose double-quoted content is
    # non-empty. A bare-word constant (`VAR=critical`), a numeric (`n=0`), a status
    # capture (`rc=$?`), an ANSI-C sentinel (`VAR=$'…'`), and an empty reset
    # (`WP=""` / `IFS=`) are all deliberately NOT this shape.
    if value_rest.startswith('"'):
        after = value_rest[1:]
        inner = after.split('"', 1)[0] if '"' in after else after
        return bool(inner.strip())
    # R1a env-prefix compound with a literal value: a NON-EMPTY assignment value
    # followed by a real command (`M=x printf …`, probe row 2). `IFS= read …` — an
    # EMPTY-valued prefix, the pure-shell field-split idiom — is not this shape and
    # never fires. (Literal values tokenize reliably; the substitution-valued arm was
    # handled above by the balanced scan.)
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
            # A space-separated redirect (`> /tmp/f`, `2> /tmp/f`) carries its target in
            # the NEXT token; attached forms (`>/tmp/f`, `2>/tmp/f`, `&>/tmp/f`) already
            # carry it in group(2) above.
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


def _attribute_line(statement: str, start: int, block_line_count: int,
                    lines: list[str]) -> int:
    """Best-effort line attribution: the source line of the statement's first line-
    fragment found verbatim in the fence's source lines, else the fence start. Shared
    by `find_violations` and `find_implement_violations` so the two profiles'
    attribution cannot drift."""
    probe = statement.strip().split("\n", 1)[0][:40]
    for off in range(block_line_count):
        src_idx = start - 1 + off
        if src_idx >= len(lines):
            break
        if probe and probe in lines[src_idx]:
            return start + off
    return start


def find_violations(text: str) -> list[tuple[int, str, str]]:
    """Every (approx line, rule, statement) denied-shape hit in the file's fences."""
    lines = text.splitlines()
    hits: list[tuple[int, str, str]] = []
    for start, block in _fence_line_offsets(text):
        for statement in _statements(block):
            rules = classify(statement)
            if not rules:
                continue
            lineno = _attribute_line(statement, start, len(block.split("\n")), lines)
            for rule in rules:
                hits.append((lineno, rule, statement.strip()))
    return hits


# ── Implement-tier rules (issue #450 -> #455) ────────────────────────────────
# The read-write `devflow-implement` profile is a SEPARATE allowlist from the
# read-only `review` profile the rules above target, with its OWN empirically
# probed denied shapes (matcher-probe.yml's implement-probe job; evidence of record
# on issues #450/#455). The label helpers ensure-label.sh / apply-labels.sh ARE
# granted as vendored literals, but the matcher denies WRAPPING them in a `for` /
# piped-`while read` loop or a `VAR="$(…)"` output capture (probe rows I4/I5/I6). The
# rules below pin exactly those wrappers AROUND A LABEL HELPER, so the agent-level rework of
# all four label channels (Phase 3.1's provenance apply, 4.0/4.0.5's deferred applies, 4.1's
# docs apply) cannot silently regress.
#
# SCOPE BOUNDARY — and it rests on an INFERENCE, not a measurement. A loop or capture
# of any OTHER command (config-get.sh, gh) is NOT flagged, because the implement skill
# legitimately uses that shape (`DEFERRED_LABELS=$(…config-get.sh …)`) and we infer the
# matcher descends into a non-label `$(…)` and matches the inner granted head. That
# inference is carried over from the REVIEW tier (run 29105381021's `WP=$(vendored-path
# create …)` executed), and this file's own rule is that a shape proven on the review
# tier is UNPROVEN here. No implement-tier row has ever measured a non-label capture,
# and the only capture row that WAS measured — I6 — came back DENIED while confounding
# three properties at once (a label helper AND a `VAR="$(…)"` capture AND an inner
# `2>&1`). So if I6's denial is attributable to the capture SHAPE, the reworked fences'
# own `config-get.sh` read is silently denied too and these rules would not catch it.
# matcher-probe.yml rows 8 (non-label capture) and 9 (redirect-free label capture) are
# the disambiguators; until a dispatch records them, treat the non-label carve-out as a
# stated inference and NOT as probe-proven — and keep the phase-4 fences fail-closed on
# a config read that produces no output (a denied command and an empty value must not
# look the same to the agent).
#
# NON-GOALS (stated, not accidental — a limit mistaken for coverage is how a guard lies):
#  * The rules match the helper by NAME, so a label helper reached through a VARIABLE
#    (`H=…/apply-labels.sh; for n in …; do "$H" "$n"; done`) is not flagged. Inherent to a
#    name-literal desk lint — resolving it needs dataflow — and the skill files never write it.
#    The same limit covers a FUNCTION wrapper (`lbl() { …/apply-labels.sh "$1" X; }; for n in …;
#    do lbl "$n"; done`) — same dataflow gap, same disclosure.
#  * A LOOP-EQUIVALENT per-item wrapper by another head — `… | xargs -I{} …/apply-labels.sh {} X`,
#    `find … -exec …/apply-labels.sh …` — is not flagged either. It has the same "the helper is
#    not the leading token" property the probe measured for I4/I5/I6, and `xargs` IS granted, so
#    whether the matcher permits it is precisely UNMEASURED. Not flagged on no evidence; disclosed
#    rather than silently missing. A probe row would settle it.
#  * `select … in` is not matched (never probed, never written here).
#
# Probe row I1 (the unexpanded `${CLAUDE_SKILL_DIR:-…}` anchor as a leading token) is
# deliberately NOT a rule here: every legitimate helper call keeps the portable
# anchor in source (issue #275) and resolves it to the vendored literal at runtime,
# so a fence-static rule would flag every call site. It is a prose-discipline rule
# (the skill's *Cloud command-shape discipline* + *Cloud helper-invocation form*
# sections), exactly as the unexpanded-anchor case is handled in the review skill.

_LABEL_HELPER = re.compile(r"(?:apply-labels|ensure-label)\.sh\b")


def _substitution_bodies(value: str) -> list[str]:
    """Every command-substitution body in a shell fragment — the `$( … )` form
    (paren-balanced) and the backtick form, which are the same shape spelled two ways.

    The fragment is whatever the caller passes: an assignment's right-hand side, or (as
    IR3 does) a WHOLE statement — which is what lets IR3 see a capture in argument or
    condition position, not only one behind a `VAR=`.

    SINGLE-quoted spans are masked out first: a backtick or `$(` inside `'…'` is literal
    text, not a substitution (`NOTE='runs `once`'`). Double-quoted spans are NOT masked —
    `"$(cmd)"` is a real substitution, and it is the exact form the denied shape uses.
    Masking preserves length, so offsets into `value` stay valid.
    """
    # Mask SINGLE-quoted spans only, double-quote-aware (see `_mask_single_quoted`): inside
    # `"…"` a `$(…)` IS a substitution — it is the denied shape's own spelling — and a `'`
    # there is just an apostrophe, not a quote opener.
    masked = _mask_single_quoted(value)
    bodies: list[str] = []
    i = 0
    n = len(value)
    while i < n:
        # `<(…)` / `>(…)` process substitution: the same denied shape — the label helper is not
        # the leading token of the tool call — and it is exactly how an author told "no `$( )`
        # capture" re-introduces the capture (`mapfile -t X < <(apply-labels.sh …)`,
        # `gh issue comment -F <(apply-labels.sh …)`). Read its body like any substitution.
        if masked[i] in "<>" and masked.startswith("(", i + 1):
            depth = 1
            j = i + 2
            start = j
            while j < n and depth:
                if masked[j] == "(":
                    depth += 1
                elif masked[j] == ")":
                    depth -= 1
                j += 1
            bodies.append(value[start : j - 1] if depth == 0 else value[start:])
            i = j
            continue
        if masked.startswith("$(", i):
            depth = 1
            j = i + 2
            start = j
            while j < n and depth:
                if masked[j] == "(":
                    depth += 1
                elif masked[j] == ")":
                    depth -= 1
                j += 1
            # Unbalanced (`$(` with no close) → take the tail: fail CLOSED, since an
            # unmeasurable capture must not be waved through.
            bodies.append(value[start : j - 1] if depth == 0 else value[start:])
            i = j
        elif masked[i] == "`":
            close = masked.find("`", i + 1)
            bodies.append(value[i + 1 : close] if close != -1 else value[i + 1 :])
            i = (close + 1) if close != -1 else n
        else:
            i += 1
    return bodies


def _label_capture_violation(statement: str) -> bool:
    """IR3: a command substitution that invokes a label helper — `VAR=$(…)`,
    `VAR="$(…)"`, a backtick capture, and equally a capture in ARGUMENT or CONDITION
    position (probe row I6 — the old `LBL_ERR="$(apply-labels.sh … 2>&1)"`).

    Scoped to the whole STATEMENT, not just an assignment's right-hand side. Anchoring
    on `^VAR=` was a fail-open on the most natural regression there is: the removed code
    captured the helper's stderr *in order to put it in a comment body*, so the obvious
    way to re-introduce it is to inline the capture into the argument —
    `gh issue comment -b "$(apply-labels.sh … 2>&1)"` — which is the same denied shape
    with no assignment anywhere. `[ -n "$(ensure-label.sh …)" ]` is the same story.

    The BACKTICK form is likewise the same shape spelled differently. A guard that knows
    only one spelling of what it forbids is a hole an author falls into by accident.

    Scoping (see the rule-block comment above): a capture of a NON-label command is not
    flagged, on the *inference* — not a measurement — that the matcher descends into it.
    """
    # Search the SUBSTITUTION BODIES of the whole statement: the shape is "a capture OF a
    # label helper", so a statement that merely NAMES one outside any substitution — a
    # message string like `MSG="$(date -u) applied via apply-labels.sh"`, or the permitted
    # bare call `apply-labels.sh 1 X` itself — is not this shape and must not be flagged.
    return any(_LABEL_HELPER.search(body) for body in _substitution_bodies(statement))


# A loop keyword only OPENS a loop in COMMAND POSITION — at the start of a statement,
# or right after a separator (`;` `|` `&&` `||` `(` `{`) or a case-arm `)` , a
# negation/wrapper (`!`, `time`),
# or an opening keyword (`do`/`then`/`else`). A bare `\bwhile\b` line match instead fires
# on the word `while` anywhere — including inside a command ARGUMENT (`echo "wait a
# while"`) — and, paired with the span rule below, swallowed every later label call in
# the fence. Callers pass COMMENT-STRIPPED, QUOTE-MASKED lines, so neither a `#` comment
# nor a quoted argument can supply a phantom separator or keyword.
_LOOP_OPENER = re.compile(
    r"(?:^|[;|&({)]|\b(?:do|then|else|time)\b|!)\s*(for|while|until)\b"
)
# `do` / `done` in command position, used to DEPTH-COUNT the span. Counting is what makes
# a NESTED loop safe: taking the first `done` after the opener let an inner one-line loop
# (`for x in a b; do echo; done`) close the OUTER span, so a label call after it fell
# outside and shipped green — a fail-open. `do` never matches inside `done` (the lookahead
# rejects the `n`).
#
# BOTH classes are command-position-anchored (line start or after a separator), NOT a bare
# `\s`. With a bare whitespace lead, an ARGUMENT-position word matched: `echo done` inside a
# loop body decremented the depth to 0, closed the span early, and every label call below it
# in that loop fell outside the scanned range and shipped GREEN — a fail-open. The mirror
# hazard applies to `do` (an argument-position `do` inflates depth, the closing `done` is never
# reached, and the opener is skipped entirely).
#
# `_DONE_TOK`'s trailing class is load-bearing and is the ONLY place `done`-recognition is
# decided. A closing `done` may be followed by a subshell/redirect/pipe close, not just
# whitespace — `(…; done)`, `done>/dev/null`, `done | tee`, `done <labels.txt` are all
# ordinary spellings — and `_loop_violations` SKIPS an opener whose `done` it cannot find.
# So omitting `)`/`<`/`>` here is a FAIL-OPEN: a real label-helper loop closed `done)` is
# silently never scanned, the guard failing open in exactly the direction it exists to
# fail closed.
_DO_TOK = re.compile(r"(?:^\s*|[;|&({]\s*)do(?=$|[;|&\s])")
_DONE_TOK = re.compile(r"(?:^\s*|[;|&({]\s*)done(?=$|[;|&)<>\s])")


def _mask_quoted(line: str, single_only: bool = False) -> str:
    """Replace the CONTENT of quoted spans with `x`, preserving length exactly (callers
    slice the ORIGINAL string using offsets found in the masked one, so any length change
    would silently mis-extract).

    The loop scan is a regex over shell TEXT, so without this a `;`, `(`, or loop keyword
    inside an ordinary argument — `gh issue comment -b "Deferred; while open, do not
    merge"` — reads as a command-position loop opener and starts a phantom span.
    Comment-stripping alone does not cover it: that text is code, just quoted.

    `single_only=True` masks ONLY `'…'` spans. This distinction is load-bearing for
    `_substitution_bodies`: inside DOUBLE quotes a `$(…)` is a real substitution — it is
    the denied shape's own spelling (`LBL_ERR="$(apply-labels.sh …)"`) — so masking
    double-quoted content there would blank the very capture the guard must find, and one
    apostrophe anywhere in the value (`… 'DevFlow')`) would be enough to hide it. Inside
    SINGLE quotes a backtick or `$(` is literal text, never a substitution.
    """
    out: list[str] = []
    quote: str | None = None
    prev = ""
    for ch in line:
        if quote:
            if ch == quote and prev != "\\":
                quote = None
                out.append(ch)
            else:
                out.append("x")
        elif ch == "'" or (ch == '"' and not single_only):
            quote = ch
            out.append(ch)
        else:
            out.append(ch)
        prev = ch
    return "".join(out)


def _mask_quoted_lines(lines: list[str], carry: bool) -> list[str]:
    """`_mask_quoted` over a block. `carry` selects whether quote state crosses newlines.

    NEITHER setting is safe alone, which is why `_loop_violations` scans BOTH and unions
    the hits (a loop opener visible under *either* masking is a hit — fail-closed):

    * `carry=False` (per-line): a double-quoted argument that OPENS on one line and CLOSES
      on a later one inverts the closing line's parity — the masker reads the closing `"`
      as an *opening* quote and masks the rest of that line, hiding a loop opener chained
      after it. `phase-4-documentation.md` already writes such arguments
      (`--body "$(cat <<'EOF' … )"`) around the code the removed label loop lived in.
    * `carry=True` (stateful): an UNBALANCED quote — an apostrophe in an ordinary word
      (`echo "the config didn't resolve"` written unquoted, a stray `'` — routine in the
      prose-heavy fences this lint scans) — opens a span that never closes, masking every
      line below it and hiding every loop opener in the rest of the fence.

    Each masking is blind exactly where the other sees, so the union is what actually fails
    closed. The residual cost is a possible spurious RED when a loop keyword AND a label
    helper both sit inside a multi-line quoted string (the per-line pass reads the string's
    later lines as code). That is the safe direction, and no fence writes that shape.
    """
    out: list[str] = []
    quote: str | None = None
    for line in lines:
        if not carry:
            quote = None
        kept: list[str] = []
        prev = ""
        for ch in line:
            if quote:
                if ch == quote and prev != "\\":
                    quote = None
                    kept.append(ch)
                else:
                    kept.append("x")
            elif ch in ("'", '"'):
                quote = ch
                kept.append(ch)
            else:
                kept.append(ch)
            prev = ch
        out.append("".join(kept))
    return out


def _mask_single_quoted(text: str) -> str:
    """Mask the content of `'…'` spans ONLY, tracking double-quote state so a `'` INSIDE a
    double-quoted string is not mistaken for a quote opener.

    This is what `_substitution_bodies` needs, and getting it wrong is a fail-open: with a
    naive single-quote-only scan, an apostrophe inside a double-quoted argument — `gh issue
    comment -b "Doesn't matter: $(apply-labels.sh …)"`, and an English message body
    routinely has one — opens a phantom single-quoted span that never closes, masking the
    `$(` so IR3 never sees the capture. Inside `"…"` a `$(…)` IS a substitution and a `'` is
    just a character; inside `'…'` neither is. Length is preserved (callers slice by offset).
    """
    out: list[str] = []
    in_s = False
    in_d = False
    prev = ""
    for ch in text:
        if in_s:
            if ch == "'":
                in_s = False
                out.append(ch)
            else:
                out.append("x")
        elif in_d:
            out.append(ch)
            if ch == '"' and prev != "\\":
                in_d = False
        elif ch == "'":
            in_s = True
            out.append(ch)
        elif ch == '"':
            in_d = True
            out.append(ch)
        else:
            out.append(ch)
        prev = ch
    return "".join(out)


def _loop_violations(lines: list[str]) -> list[tuple[int, str]]:
    """IR1/IR2: a `for` loop — any spelling, incl. C-style `for ((…))` (IR1) — or a
    `while` / `until` loop (IR2) whose do…done span invokes a label helper (probe rows
    I4/I5). Returns (block-relative line offset of the opener, rule). `lines` MUST be
    comment-stripped/heredoc-blanked
    (`_shape_preprocess_lines`) — scanning raw source made a `#` comment mentioning a
    loop a false hit.

    The span runs from the opener to its OWN closing `done`, INCLUSIVE — `do`/`done` are
    depth-counted, so a NESTED inner loop's `done` cannot close the outer span and hide a
    label call that follows it. A one-line loop (`for f in a b; do …; done`) is closed by
    the `done` on the opener line itself. An opener with NO `done` anywhere in the fence
    is NOT a loop we can measure — it is skipped, never treated as running to end-of-fence
    (that made every later label call in the block a phantom hit of a loop that does not
    exist).
    """
    # SHELL STRUCTURE (loop openers, `done`) is read from the QUOTE-MASKED lines, so a
    # separator or keyword inside a quoted argument cannot fake a loop. The LABEL-HELPER
    # search runs over the UNMASKED lines, because a real denied call routinely sits
    # inside quotes — the removed Phase 4.0 shape was `LBL_ERR="$(… apply-labels.sh …)"`,
    # whose helper name lives inside a double-quoted capture. Masking both would blind
    # IR1/IR2 to precisely the shape they exist to catch. Same length, so offsets align.
    # BOTH maskings are scanned and the hits UNIONED — each is blind exactly where the
    # other sees (see `_mask_quoted_lines`), so only the union fails closed.
    hits_seen: set[tuple[int, str]] = set()
    for masked in (_mask_quoted_lines(lines, carry=True), _mask_quoted_lines(lines, carry=False)):
        for hit in _scan_loops(lines, masked):
            hits_seen.add(hit)
    return sorted(hits_seen)


def _scan_loops(lines: list[str], masked: list[str]) -> list[tuple[int, str]]:
    """One loop scan over one masking of `lines` (see `_loop_violations`, which unions two)."""
    hits: list[tuple[int, str]] = []
    n = len(lines)
    i = 0
    while i < n:
        opener = _LOOP_OPENER.search(masked[i])
        if not opener:
            i += 1
            continue
        rule = "IR1" if opener.group(1) == "for" else "IR2"
        # Walk to the loop's OWN closing `done`, depth-counting `do`/`done` so a nested
        # loop's `done` cannot close this span. On the opener line only the text AFTER the
        # loop keyword counts (a one-line `for …; do …; done` closes on its own line).
        end: int | None = None
        depth = 0
        j = i
        while j < n:
            seg = masked[j][opener.end():] if j == i else masked[j]
            depth += len(_DO_TOK.findall(seg))
            closes = len(_DONE_TOK.findall(seg))
            if closes:
                depth -= closes
                if depth <= 0:
                    end = j
                    break
            j += 1
        if end is None:
            i += 1  # unterminated: not a measurable loop span — do NOT swallow the tail
            continue
        if any(_LABEL_HELPER.search(lines[k]) for k in range(i, end + 1)):
            hits.append((i, rule))
        i = end + 1
    return hits


def find_implement_violations(text: str) -> list[tuple[int, str, str]]:
    """Every (approx line, rule, statement) implement-tier denied-shape hit."""
    lines = text.splitlines()
    hits: list[tuple[int, str, str]] = []
    for start, block in _fence_line_offsets(text):
        block_lines = block.split("\n")
        seen: set[tuple[int, str, str]] = set()
        # Preprocess BOTH ways and union the hits. The comment stripper has the same
        # per-line-vs-carried quote dilemma the loop mask does: a `#`-leading line INSIDE a
        # multi-line double-quoted argument is argument text (carried is right), but one
        # unbalanced apostrophe would stop every later comment being stripped (per-line is
        # right). Each is blind exactly where the other sees, so only the union fails closed.
        for carry in (False, True):
            clean_lines, expanding = _preprocess(block, carry_comments=carry)
            for statement in _statements_from_lines(clean_lines):
                if not _label_capture_violation(statement):
                    continue
                lineno = _attribute_line(statement, start, len(block_lines), lines)
                seen.add((lineno, "IR3", statement.strip()))
            # IR3 in an UNQUOTED heredoc body: blanked above (its text is data, not
            # commands), but the shell still EXPANDS a `$(…)` there — so a label-helper
            # capture in `gh issue comment -F - <<EOF … $(apply-labels.sh …) … EOF` really
            # executes, and blanking alone would hide the denied shape. Re-scan those lines.
            for off in expanding:
                if _label_capture_violation(block_lines[off]):
                    seen.add((start + off, "IR3", block_lines[off].strip()))
            for off, rule in _loop_violations(clean_lines):
                seen.add((start + off, rule, block_lines[off].strip()))
        hits.extend(sorted(seen))
    return hits


_USAGE = "usage: extract-command-shapes.py [--profile review|implement] FILE"


def main(argv: list[str]) -> int:
    args = argv[1:]
    profile = "review"
    if args and args[0] == "--profile":
        if len(args) < 2:
            print(_USAGE, file=sys.stderr)
            return 2
        profile = args[1]
        args = args[2:]
    if len(args) != 1 or profile not in ("review", "implement"):
        print(_USAGE, file=sys.stderr)
        return 2
    path = args[0]
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    hits = find_implement_violations(text) if profile == "implement" else find_violations(text)
    for lineno, rule, statement in hits:
        oneline = " ".join(statement.split())
        if len(oneline) > 160:
            oneline = oneline[:157] + "..."
        print(f"{path}:{lineno}  {rule}  {oneline}")
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
