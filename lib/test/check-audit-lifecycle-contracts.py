#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Reconcile the create-issue audit lifecycle's prose against machine-consumed contracts.

Issue #795. Two reconciliations that a `git grep` for a sentence could never perform,
plus the measurement figure derived from the second:

  read-backs   The multi-line read-back enumeration carried by `scripts/issue-audit-state.py`'s
               `TWO-CLASS CLI CONTRACT` docstring is compared against `_MULTILINE_READBACKS`
               — the set the module's own emission machinery dispatches on — and every name
               in that set is required to be a subcommand the parser actually registers.
               So the guard grades the docstring against what the tool DOES, not against
               its own wording, and a name in the prose that no parser choice backs is RED.

  sequence     Every state-owner invocation named in `step-3-6-audit.md`'s ordered
               call-sequence paragraph is required to be a registered subcommand (the prose
               can never name a call the tool would not accept), and the count of
               unconditional calls that paragraph plus `step-4-present-create.md` jointly
               mandate is reported.

  figure       The per-round measurement figure the suite pins, derived from `sequence`
               rather than hand-transcribed — so a later addition of an unconditional call
               MOVES the figure instead of leaving a stale literal behind.

FAIL CLOSED, NEVER CLEAN-ZERO. Both prose readers parse a human-editable markdown file, so
each refuses rather than reporting an empty result: no candidate section, more than one
candidate section, or zero invocations extracted is a named RED breadcrumb. A rewrap or a
duplicated heading must not make a check pass vacuously and freeze the figure.

Exit 0 with a report on stdout when every reconciliation holds; exit 1 with the failing
reconciliation named on stderr otherwise.
"""

from __future__ import annotations

import importlib.util
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
IAS = REPO / "scripts" / "issue-audit-state.py"
STEP36 = REPO / "skills" / "create-issue" / "references" / "step-3-6-audit.md"
STEP4 = REPO / "skills" / "create-issue" / "references" / "step-4-present-create.md"

# The paragraph that opens the ordered call sequence. A closed anchor, not a fuzzy match:
# exactly one line must carry it, so a duplicated or renamed heading is RED rather than
# silently selecting the first hit.
_SEQUENCE_ANCHOR = "**The call sequence, in order.** The normal clean run:"

# The docstring section carrying the read-back enumeration.
_DOCSTRING_ANCHOR = "TWO-CLASS CLI CONTRACT"

# Calls the prose marks conditional on the run's shape; excluded from the unconditional
# figure by name, and the prose is required to still mark them so (checked below).
_CONDITIONAL = ("record-offer", "query-adjudication-records")


class Refusal(Exception):
    """A reconciliation could not be established — never reported as a clean result."""


def _load_module():
    spec = importlib.util.spec_from_file_location("_ias795", IAS)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as exc:
        raise Refusal(f"could not read {path.relative_to(REPO)}: {exc}") from exc


def _sole_paragraph(text: str, anchor: str, where: str) -> str:
    """The single paragraph following `anchor`, or a refusal naming why not."""
    hits = [i for i, line in enumerate(text.splitlines()) if anchor in line]
    if not hits:
        raise Refusal(f"{where}: no line carries the anchor {anchor!r} — the section was "
                      "renamed, rewrapped, or removed; refusing rather than reporting an "
                      "empty extraction")
    if len(hits) > 1:
        raise Refusal(f"{where}: {len(hits)} lines carry the anchor {anchor!r}; exactly one "
                      "candidate is required, so a duplicated heading cannot make this "
                      "check pass against the wrong paragraph")
    lines = text.splitlines()
    start = hits[0] + 1
    while start < len(lines) and not lines[start].strip():
        start += 1
    end = start
    while end < len(lines) and lines[end].strip():
        end += 1
    body = "\n".join(lines[start:end]).strip()
    if not body:
        raise Refusal(f"{where}: the paragraph after {anchor!r} is empty")
    return body


def _backticked(text: str) -> list[str]:
    """Every backtick-quoted token in `text`, in document order."""
    return re.findall(r"`([^`]+)`", text)


def _invocations(text: str, registered: frozenset[str], where: str) -> list[str]:
    """The registered subcommand names a prose passage invokes, in document order.

    A name called twice contributes twice: the count is of invocations, not of distinct
    subcommands.
    """
    found = []
    for token in _backticked(text):
        head = token.split()[0] if token.split() else ""
        if head in registered:
            found.append(head)
    if not found:
        raise Refusal(f"{where}: zero state-owner invocations extracted. A clean zero here "
                      "would freeze the derived figure and let the reconciliation pass "
                      "vacuously, so it is a refusal")
    return found


def check_readbacks(module, registered, report):
    """The docstring's read-back enumeration vs. the dispatched `_MULTILINE_READBACKS`."""
    doc = module.__doc__ or ""
    if _DOCSTRING_ANCHOR not in doc:
        raise Refusal("read-backs: the module docstring carries no "
                      f"{_DOCSTRING_ANCHOR!r} section")
    section = doc.split(_DOCSTRING_ANCHOR, 1)[1]
    named = {t for t in _backticked(section) if t in registered and t.startswith("query-")}
    dispatched = set(module._MULTILINE_READBACKS)  # noqa: SLF001
    unbacked = sorted(dispatched - registered)
    if unbacked:
        raise Refusal("read-backs: _MULTILINE_READBACKS names "
                      f"{unbacked} which the parser does not register — the set the "
                      "emission machinery dispatches on must be a subset of the real "
                      "subcommand vocabulary")
    missing = sorted(dispatched - named)
    if missing:
        raise Refusal("read-backs: the TWO-CLASS CLI CONTRACT docstring does not name "
                      f"{missing}, which _MULTILINE_READBACKS dispatches as multi-line. "
                      "The prose enumeration and the dispatched set must agree")
    report.append(f"read-backs: {len(dispatched)} multi-line read-backs, "
                  "docstring enumeration reconciled against the dispatched set")


def check_sequence(registered, report):
    """The ordered call sequence vs. the invocations the helper accepts. Returns the
    unconditional joint count."""
    seq_text = _read(STEP36)
    paragraph = _sole_paragraph(seq_text, _SEQUENCE_ANCHOR, "sequence")
    named = _invocations(paragraph, registered, "sequence")
    unknown = sorted(set(named) - registered)
    if unknown:
        raise Refusal(f"sequence: the ordered sequence names {unknown}, which the parser "
                      "does not register")
    for cond in _CONDITIONAL:
        if cond in named:
            raise Refusal(f"sequence: {cond!r} is conditional on the run's shape and must "
                          "not sit in the unconditional ordered sequence")
        if f"`{cond}`" not in seq_text:
            raise Refusal(f"sequence: {cond!r} is no longer named anywhere in "
                          "step-3-6-audit.md, so its conditional status is unstated")
    # The joint scope: step-4's own mandated calls that the sequence attributes to it.
    step4 = _read(STEP4)
    if "query-draft-binding" not in step4:
        raise Refusal("sequence: step-4-present-create.md no longer mandates the "
                      "query-draft-binding re-detect the sequence's joint scope counts")
    report.append(f"sequence: {len(named)} unconditional invocations jointly mandated, "
                  "every one a registered subcommand")
    return len(named)


def main(argv):
    report: list[str] = []
    try:
        module = _load_module()
        registered = module.registered_subcommands()
        check_readbacks(module, registered, report)
        unconditional = check_sequence(registered, report)
    except Refusal as exc:
        sys.stderr.write(f"check-audit-lifecycle-contracts: {exc}\n")
        return 1
    # The measurement figure, DERIVED — never hand-transcribed. Reported on the SUCCESS
    # path so a passing suite carries the evidence rather than only a failure message.
    report.append(f"unconditional_call_count={unconditional}")
    report.append(f"registered_subcommand_count={len(registered)}")
    for line in report:
        print(line)
    if "--count" in argv:
        print(unconditional)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
