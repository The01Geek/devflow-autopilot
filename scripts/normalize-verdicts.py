#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""DevFlow checklist-verdict parse + wording-only normalization helper (Phase 2.2).

The checklist-verifier is a strict measuring instrument: it grades
partially-correct claims FAIL and reports structured operands
(``property_proven``, ``inaccuracy_scope``) without ever self-normalizing. This
helper owns the parse contract and the single normalization decision, so the
review-engine prose only assembles inputs, runs the helper, and renders outputs
(the ``match-lint-adjudications.py`` / ``match-deferrals.py`` helper-owns-the-join
idiom). It is stdlib-only, reads no config, and makes no ``gh``/network/``git``
calls — unit-testable exactly like ``consolidate-changesets.py`` (issue #556).

Input — one pairs file (a JSON object) named as ``argv[1]``. The orchestrator
Writes it into the run-scoped ``.devflow/tmp/`` tree. Shape::

    {
      "pairs": [
        {
          "item": { "id": "VC-3", "verification_mode": "agent",
                    "claim_provenance": "generated_paraphrase",
                    "source_excerpt": "<verbatim authored text, source_authored items only>", ... },
          "verdict_path": ".devflow/tmp/review/<slug>/<run>/verdicts/iter-1/VC-3-<nonce>.json",
          "response_text": "...transcribed verifier response (fallback channel)...",
          "pinned_verdict": "FAIL"   # optional: field-completion re-ask — the raw
                                      # FAIL is pinned to the first response; any
                                      # verdict token the re-ask returns is ignored.
        },
        ...
      ]
    }

The verdict bytes for each pair are read from **exactly** the ``verdict_path``
named in that pair entry (every file the pairs file does not name is ignored, so
a compromised verifier can affect only its own item — the nonce binding). When no
readable file exists at that path, the pair's transcribed ``response_text`` is the
fallback channel; when neither exists the item carries a verdict defect.

Output — one JSON object on stdout, rc 0 whenever the helper ran::

    {
      "results": [ { "id", "raw_verdict", "verdict", "normalized",
                     "evidence", "file_checked", "source",
                     "defect", "defect_class",
                     "normalization_ineligible" }, ... ],
      "needs_retry": [ { "id", "kind": "verdict"|"auxiliary", "defect" }, ... ],
      "counts": { "normalized_count", "field_defect_fail_count" }
    }

A malformed pairs file (unparseable / truncated / wrong-shape) instead prints the
structured **bad-input report** — ``{"bad_input": true, "error": ...}`` — to
stdout with rc 0, so a transcription failure is an outcome distinguishable from
results, from error text, and from silence (a matcher denial prints nothing).

Verdict defect shapes (item keeps its raw verdict, is normalization-ineligible,
and enters ``needs_retry`` with kind ``verdict``): ``missing_fence`` (no ``json``
fence and the body does not contain exactly one parseable object),
``unparseable_json``, ``missing_verdict_field``, ``non_enum_verdict``,
``id_mismatch``, ``no_verdict`` (neither file nor response_text). More than one
``json`` fence reads the LAST fence as authoritative (final-answer convention).

Auxiliary-field defects (an absent / unknown-token / wrong-typed
``property_proven`` or ``inaccuracy_scope``) never invalidate a well-formed
verdict: the item keeps its raw verdict and is normalization-ineligible. Only when
the raw verdict is the byte-exact token ``FAIL`` and the item carries
``claim_provenance: "generated_paraphrase"`` (the sole population conjuncts 3-5
can ever admit) does an auxiliary defect enter ``needs_retry`` with kind
``auxiliary`` for a field-completion re-ask; a PASS or INCONCLUSIVE with a
defective auxiliary field is never re-dispatched.

The five-conjunct normalization predicate (raw FAIL -> stored PASS) holds exactly
when ALL hold: (1) ``verification_mode == "agent"``; (2)
``claim_provenance == "generated_paraphrase"``; (3) raw verdict byte-exact
``FAIL``; (4) ``property_proven`` is JSON boolean ``true`` (a JSON string
``"true"`` does not qualify — a real type check); (5)
``inaccuracy_scope == "generated_claim_text"``. No malformed shape of any class
ever resolves to a stored PASS.

Exit codes:
    0  Helper ran (results OR bad-input report printed).
    1  Unsupported Python (< 3.11).
    2  Bad arguments (no pairs-file path given).
"""

import json
import sys

if sys.version_info < (3, 11):  # fail fast, before any PEP 604 annotation below
    sys.stderr.write(
        "devflow: Python 3.11+ required (found %s.%s.%s).\n" % sys.version_info[:3]
    )
    sys.exit(1)

VERDICT_ENUM = ("PASS", "FAIL", "INCONCLUSIVE")
SCOPE_ENUM = ("generated_claim_text", "source_authored_text", "none")
NORMALIZED_PREFIX = "NORMALIZED (wording-only): "


def _brace_objects(text):
    """Return every top-level balanced ``{...}`` substring of ``text`` that parses
    as a JSON dict, in order. String contents (and escaped quotes/braces inside
    them) are respected so a ``{`` inside a JSON string never opens a candidate."""
    objs = []
    depth = 0
    start = -1
    in_str = False
    esc = False
    for i, ch in enumerate(text):
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch == "{":
            if depth == 0:
                start = i
            depth += 1
        elif ch == "}":
            if depth > 0:
                depth -= 1
                if depth == 0 and start != -1:
                    candidate = text[start:i + 1]
                    try:
                        parsed = json.loads(candidate)
                    except (json.JSONDecodeError, ValueError):
                        parsed = None
                    if isinstance(parsed, dict):
                        objs.append(parsed)
                    start = -1
    return objs


def _json_fences(text):
    """Return the inner text of each ```` ```json ... ``` ```` fence, in order."""
    fences = []
    marker = "```json"
    idx = 0
    while True:
        open_at = text.find(marker, idx)
        if open_at == -1:
            break
        body_start = open_at + len(marker)
        close_at = text.find("```", body_start)
        if close_at == -1:
            break
        fences.append(text[body_start:close_at])
        idx = close_at + 3
    return fences


def extract_verdict_object(text):
    """Parse the verdict object out of verifier bytes (a file's content or a
    transcribed response). Returns ``(obj, defect)`` — exactly one is None.

    Parse contract: prefer ``json`` fences (LAST fence authoritative when more
    than one); with no fence, tolerate a body that contains exactly one parseable
    JSON object; otherwise ``missing_fence``."""
    if text is None:
        return None, "no_verdict"
    fences = _json_fences(text)
    if fences:
        chosen = fences[-1].strip()
        try:
            obj = json.loads(chosen)
        except (json.JSONDecodeError, ValueError):
            return None, "unparseable_json"
        if not isinstance(obj, dict):
            return None, "unparseable_json"
        return obj, None
    objs = _brace_objects(text)
    if len(objs) == 1:
        return objs[0], None
    # zero parseable objects, or an ambiguous multiple — neither is a verdict.
    return None, "missing_fence"


def _aux_state(obj, field):
    """Classify an auxiliary field. Returns one of ``"ok"``, ``"real"``
    (present, correct type, a legitimate non-normalizing value), or ``"defect"``
    (absent / wrong type / unknown token — a field-emission miss)."""
    present = field in obj
    val = obj.get(field)
    if field == "property_proven":
        if not present:
            return "defect"
        if not isinstance(val, bool):  # a JSON string "true" is NOT a boolean
            return "defect"
        return "ok" if val is True else "real"
    if field == "inaccuracy_scope":
        if not present or not isinstance(val, str) or val not in SCOPE_ENUM:
            return "defect"
        return "ok" if val == "generated_claim_text" else "real"
    return "defect"


def _read_verdict_bytes(pair):
    """Return ``(text, source)`` — the verdict bytes and their channel. Reads ONLY
    the exact ``verdict_path`` named in this pair (ignoring every unnamed file);
    falls back to the transcribed ``response_text`` when no readable file exists.

    An ABSENT file is the legitimate fallback and yields ``source == "response_text"``.
    A file that is PRESENT but unreadable (permission error or invalid UTF-8) is an
    anomaly — the trusted channel was abandoned — so it yields
    ``source == "response_text_file_unreadable"`` (still a response_text read) so the
    downgrade off the authoritative nonce file is observable, never silent."""
    downgraded = False
    path = pair.get("verdict_path")
    if isinstance(path, str) and path:
        try:
            with open(path, "r", encoding="utf-8") as fh:
                return fh.read(), "file"
        except FileNotFoundError:
            pass  # file genuinely absent -> the legitimate silent fallback
        except (OSError, UnicodeDecodeError):
            downgraded = True  # present but unreadable -> surface the downgrade
    rt = pair.get("response_text")
    if isinstance(rt, str):
        return rt, ("response_text_file_unreadable" if downgraded else "response_text")
    return None, ("none_file_unreadable" if downgraded else "none")


def _verdict_defect(result, item_id, defect):
    """Stamp a verdict-defect result and its full-re-dispatch retry entry.
    Returns ``(result, retry, False)`` — a verdict defect is never a
    field-defect-fail (it has no established raw verdict)."""
    result["defect"] = defect
    result["defect_class"] = "verdict"
    result["normalization_ineligible"] = f"verdict defect: {defect}"
    return result, {"id": item_id, "kind": "verdict", "defect": defect}, False


def _process_pair(pair):
    """Return ``(result_dict, retry_entry_or_None, is_field_defect_fail)`` for one
    pair. ``is_field_defect_fail`` is decided here from the structured blocker
    lists (never re-derived from the rendered ``normalization_ineligible`` string)."""
    item = pair.get("item") if isinstance(pair.get("item"), dict) else {}
    item_id = item.get("id")
    mode = item.get("verification_mode")
    provenance = item.get("claim_provenance")
    pinned = pair.get("pinned_verdict")

    text, source = _read_verdict_bytes(pair)
    obj, defect = extract_verdict_object(text)
    is_pinned = isinstance(pinned, str) and pinned in VERDICT_ENUM

    result = {
        "id": item_id,
        "raw_verdict": None,
        "verdict": None,
        "normalized": False,
        "evidence": None,
        "file_checked": None,
        "source": source,
        "defect": None,
        "defect_class": None,
        "normalization_ineligible": None,
    }

    if is_pinned:
        # Pinned-first-verdict rule (field-completion re-ask): the raw verdict is
        # PINNED to the first response's FAIL, and the re-ask response is parsed ONLY
        # for the two auxiliary fields — any verdict token it returns, OR its absence
        # (a compliant re-ask returns only the aux fields), is ignored. The re-ask
        # fires at most once, so a verdict-less / unparseable response never
        # re-dispatches: the pinned raw stands and the item resolves through the
        # predicate below. (Ordered before the verdict-defect arms so a compliant
        # aux-only response is never mis-classified as missing_verdict_field.)
        raw = pinned
        obj = obj if isinstance(obj, dict) else {}
    else:
        # --- verdict-defect arm: keep no verdict, flag for a full re-dispatch ----
        if defect is not None:
            return _verdict_defect(result, item_id, defect)
        # object well-formed enough to inspect; validate the mandatory verdict field
        if "verdict" not in obj:
            return _verdict_defect(result, item_id, "missing_verdict_field")
        raw = obj.get("verdict")
        if not isinstance(raw, str) or raw not in VERDICT_ENUM:
            return _verdict_defect(result, item_id, "non_enum_verdict")
        obj_id = obj.get("id")
        if item_id is not None and obj_id is not None and obj_id != item_id:
            return _verdict_defect(result, item_id, "id_mismatch")

    evidence = obj.get("evidence")
    result["raw_verdict"] = raw
    result["verdict"] = raw  # stored verdict defaults to raw; normalization may flip it
    result["evidence"] = evidence if isinstance(evidence, str) else None
    fc = obj.get("file_checked")
    result["file_checked"] = fc if isinstance(fc, str) else None

    # --- auxiliary-field classification ----------------------------------------
    pp_state = _aux_state(obj, "property_proven")
    scope_state = _aux_state(obj, "inaccuracy_scope")
    aux_defects = []
    if pp_state == "defect":
        aux_defects.append("property_proven")
    if scope_state == "defect":
        aux_defects.append("inaccuracy_scope")

    # --- five-conjunct normalization predicate ---------------------------------
    real_blockers = []
    field_defect_blockers = []
    if mode != "agent":
        real_blockers.append("not agent")
    if provenance != "generated_paraphrase":
        if provenance == "source_authored":
            real_blockers.append("source_authored provenance")
        elif provenance is None:
            field_defect_blockers.append("claim_provenance absent")
        else:
            field_defect_blockers.append("claim_provenance invalid")
    if pp_state == "real":
        real_blockers.append("property not proven")
    elif pp_state == "defect":
        field_defect_blockers.append("property_proven field defect")
    if scope_state == "real":
        real_blockers.append("inaccuracy_scope not generated_claim_text")
    elif scope_state == "defect":
        field_defect_blockers.append("inaccuracy_scope field defect")

    can_normalize = (
        raw == "FAIL"
        and not real_blockers
        and not field_defect_blockers
    )

    if can_normalize:
        result["verdict"] = "PASS"
        result["normalized"] = True
        base = result["evidence"] or ""
        result["evidence"] = NORMALIZED_PREFIX + base
        return result, None, False

    # not normalized: record the ineligibility reason(s)
    if raw == "FAIL":
        blockers = real_blockers + field_defect_blockers
        if blockers:
            result["normalization_ineligible"] = "; ".join(blockers)

    # Exact membership for ``field_defect_fail_count``, decided from the STRUCTURED
    # blocker lists (never re-parsed from the rendered string): a raw byte-exact
    # FAIL whose SOLE normalization blocker is a field defect — a real-value blocker
    # (source_authored provenance, property-not-proven, lite item) disqualifies it.
    is_field_defect_fail = (
        raw == "FAIL"
        and bool(field_defect_blockers)
        and not real_blockers
    )

    # auxiliary re-ask: only for a raw FAIL + generated_paraphrase agent item with a
    # defective auxiliary field (never re-roll a PASS/INCONCLUSIVE — a bookkeeping
    # defect must not re-roll a decided verdict). The common defect stamp is hoisted;
    # only the retry entry is gated on the re-ask population.
    retry = None
    if aux_defects:
        result["defect"] = "aux:" + ",".join(aux_defects)
        result["defect_class"] = "auxiliary"
        # A pinned pair IS the field-completion re-ask (fires at most once), so it is
        # never re-dispatched again — its persisting aux defect leaves the raw FAIL
        # standing with the marker.
        if not is_pinned and raw == "FAIL" and provenance == "generated_paraphrase" and mode == "agent":
            retry = {"id": item_id, "kind": "auxiliary", "defect": ",".join(aux_defects)}

    return result, retry, is_field_defect_fail


def run(pairs_file):
    try:
        with open(pairs_file, "r", encoding="utf-8") as fh:
            raw = fh.read()
    except (OSError, UnicodeDecodeError) as e:
        return {"bad_input": True, "error": "pairs_file_unreadable", "detail": str(e)}

    if not raw.strip():
        return {"bad_input": True, "error": "pairs_file_empty",
                "detail": "the pairs file was empty"}
    try:
        payload = json.loads(raw)
    except (json.JSONDecodeError, ValueError) as e:
        return {"bad_input": True, "error": "pairs_file_unparseable",
                "detail": f"not valid JSON (truncated or mis-escaped transcription?): {e}"}
    if not isinstance(payload, dict) or not isinstance(payload.get("pairs"), list):
        return {"bad_input": True, "error": "pairs_file_wrong_shape",
                "detail": "expected a JSON object with a 'pairs' array"}

    results = []
    needs_retry = []
    field_defect_fail_count = 0
    for idx, pair in enumerate(payload["pairs"]):
        if not isinstance(pair, dict):
            # A non-dict element (a stray null/string/number/list from a corrupt
            # transcription) is a verdict defect, NOT a silent no-op: emit an
            # observable result + retry so a single-element corruption cannot drop a
            # verdict unnoticed (the pairs file is LLM-transcribed, so this is the
            # per-element analogue of the whole-file bad-input report).
            malformed = {
                "id": None, "raw_verdict": None, "verdict": None, "normalized": False,
                "evidence": None, "file_checked": None, "source": "none",
                "defect": "malformed_pair", "defect_class": "verdict",
                "normalization_ineligible": "verdict defect: malformed_pair",
                "pair_index": idx,
            }
            results.append(malformed)
            needs_retry.append({"id": None, "kind": "verdict",
                                "defect": "malformed_pair", "pair_index": idx})
            continue
        result, retry, is_field_defect_fail = _process_pair(pair)
        results.append(result)
        if retry is not None:
            needs_retry.append(retry)
        if is_field_defect_fail:
            field_defect_fail_count += 1

    normalized_count = sum(1 for r in results if r.get("normalized"))

    return {
        "results": results,
        "needs_retry": needs_retry,
        "counts": {
            "normalized_count": normalized_count,
            "field_defect_fail_count": field_defect_fail_count,
        },
    }


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv:
        sys.stderr.write("normalize-verdicts.py: a pairs-file path argument is required\n")
        return 2
    out = run(argv[0])
    print(json.dumps(out, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
