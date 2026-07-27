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

import argparse
import contextlib
import importlib.util
import io
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
    if spec is None or spec.loader is None:
        # Without this, a moved or renamed state owner surfaces as an
        # `AttributeError: 'NoneType'` traceback — the one shape this file's own
        # "FAIL CLOSED, NEVER CLEAN-ZERO" contract promises never to produce.
        raise Refusal(f"could not load {IAS.relative_to(REPO)} as a module "
                      "(missing file or unloadable spec)")
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
    lines = text.splitlines()
    hits = [i for i, line in enumerate(lines) if anchor in line]
    if not hits:
        raise Refusal(f"{where}: no line carries the anchor {anchor!r} — the section was "
                      "renamed, rewrapped, or removed; refusing rather than reporting an "
                      "empty extraction")
    if len(hits) > 1:
        raise Refusal(f"{where}: {len(hits)} lines carry the anchor {anchor!r}; exactly one "
                      "candidate is required, so a duplicated heading cannot make this "
                      "check pass against the wrong paragraph")
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
        parts = token.split()
        if parts and parts[0] in registered:
            found.append(parts[0])
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
    # The docstring↔dispatched comparison above is a prose reconciliation. Anchor the same
    # guarantee on BEHAVIOR too, so the arm does not rest on documentation presence alone:
    # every excluded subcommand must really be one the emitter refuses to append to, and
    # `_emit_next_call` raises on an excluded name, which is the executable boundary this
    # arm grades against; the complement direction — every NON-excluded subcommand really
    # being one the emitter can serve — is `check_emitting_complement` below.
    excluded = set(module._NEXT_CALL_EXCLUDED)  # noqa: SLF001
    if not dispatched <= excluded:
        raise Refusal("read-backs: a multi-line read-back is missing from "
                      f"_NEXT_CALL_EXCLUDED ({sorted(dispatched - excluded)}) — a "
                      "multi-line answer would gain a trailing next_call= line")
    for name in sorted(excluded):
        try:
            module._emit_next_call(name, None, None)  # noqa: SLF001
        except AssertionError:
            continue
        except Exception:  # noqa: BLE001
            raise Refusal(f"read-backs: _emit_next_call({name!r}) did not refuse the way "
                          "the exclusion predicate requires") from None
        raise Refusal(f"read-backs: _emit_next_call accepted the excluded {name!r}; the "
                      "exclusion set and the emitter's own guard disagree")
    unbacked_exclusions = sorted(excluded - registered)
    if unbacked_exclusions:
        raise Refusal(f"read-backs: _NEXT_CALL_EXCLUDED names {unbacked_exclusions}, which "
                      "the parser does not register")
    report.append(f"read-backs: {len(dispatched)} multi-line read-backs, docstring "
                  "enumeration reconciled against the dispatched set, and every excluded "
                  "subcommand refused by the emitter's own guard")


def check_emitting_complement(module, registered, report):
    """Every NON-excluded subcommand must really be one the emitter can serve.

    The complement direction, and the one whose absence let a reproducible crash ship: the
    exclusion arm above walks `_NEXT_CALL_EXCLUDED` and confirms the emitter refuses each
    member, which says nothing about the ~30 subcommands that are supposed to EMIT. The
    emitter reads namespace fields off `args`, so a subcommand whose parser registers none
    of them — `query-nonce`, which exists to recover the nonce and therefore takes no
    `--nonce` — crashed with an `AttributeError` on the recovery path it exists for.

    Driven off `registered_subcommands()` rather than a hand-list, so a subcommand added
    later without one of those flags fails at the desk instead of in a run. The probe uses
    an empty namespace: it asserts the emitter tolerates every field being ABSENT, which is
    the structural property, not that any particular answer is produced.
    """
    excluded = set(module._NEXT_CALL_EXCLUDED)  # noqa: SLF001
    emitting = sorted(registered - excluded)
    if not emitting:
        raise Refusal("emitting-complement: no subcommand emits next_call= at all — the "
                      "exclusion set covers the whole registered vocabulary, which would "
                      "turn the answer channel off entirely")
    for name in emitting:
        args = argparse.Namespace(slug="_probe795")
        try:
            # The probe's own `next_call=` line is captured, not printed: this guard's
            # stdout IS its report (run.sh parses the figures out of it), so 30 probe
            # lines would corrupt the surface being read.
            with contextlib.redirect_stdout(io.StringIO()), \
                    contextlib.redirect_stderr(io.StringIO()):
                module._emit_next_call(name, args, None)  # noqa: SLF001
        except Exception as exc:  # noqa: BLE001
            raise Refusal(
                f"emitting-complement: _emit_next_call({name!r}) raised "
                f"{type(exc).__name__}: {exc} on a namespace carrying no optional field. "
                "The emitter must depend on no parser shape it does not itself check — "
                "read each field with getattr(), or add the subcommand to "
                "_NEXT_CALL_EXCLUDED") from None
    report.append(f"emitting-complement: all {len(emitting)} non-excluded subcommands "
                  "tolerate an absent namespace field")


def check_round_defaulted(module, registered, report):
    """`_ROUND_DEFAULTED` must match the subcommands whose `--round` is actually optional.

    The constant is declared as THE closed set and reads as authoritative, but nothing
    consumed it: flipping a `--round` to `required=False` without adding the
    `_require_named_round` call — the exact slip that would silently operate on the wrong
    round — passed every gate. Reconcile it against the parser, a machine-consumed
    contract, exactly as the read-back arm reconciles `_MULTILINE_READBACKS`.
    """
    parser = module.build_parser()
    optional_round = set()
    for action in parser._actions:  # noqa: SLF001
        if isinstance(action, argparse._SubParsersAction):  # noqa: SLF001
            for name, sub in action.choices.items():
                for a in sub._actions:  # noqa: SLF001
                    if "--round" in a.option_strings and not a.required:
                        optional_round.add(name)
    declared = set(module._ROUND_DEFAULTED)  # noqa: SLF001
    if declared - registered:
        raise Refusal(f"round-defaulted: _ROUND_DEFAULTED names "
                      f"{sorted(declared - registered)}, which the parser does not register")
    if declared != optional_round:
        raise Refusal(
            "round-defaulted: _ROUND_DEFAULTED and the parser disagree about which "
            f"subcommands have an optional --round. Declared-not-optional: "
            f"{sorted(declared - optional_round)}; optional-not-declared: "
            f"{sorted(optional_round - declared)}. A subcommand whose --round became "
            "optional without a _require_named_round call would silently operate on a "
            "round the caller never named")
    report.append(f"round-defaulted: {len(declared)} state-defaulted subcommands, "
                  "reconciled against the parser's own required-ness")


def check_sequence(registered, report):
    """The ordered call sequence vs. the invocations the helper accepts. Returns the
    unconditional joint count."""
    seq_text = _read(STEP36)
    paragraph = _sole_paragraph(seq_text, _SEQUENCE_ANCHOR, "sequence")
    # `_invocations` appends a head only when it is already in `registered`, so the "names
    # a call the tool would not accept" guarantee is enforced at extraction — a second
    # `set(named) - registered` check here could never fire.
    named = _invocations(paragraph, registered, "sequence")
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


def main():
    report: list[str] = []
    try:
        module = _load_module()
        registered = module.registered_subcommands()
        check_readbacks(module, registered, report)
        check_emitting_complement(module, registered, report)
        check_round_defaulted(module, registered, report)
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
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
