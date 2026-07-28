#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""subagent-write-probe-verdict.py — derive the "does a dispatched subagent's Write
into `.devflow/tmp/**` succeed?" probe verdict from a `claude-code-action` execution
file, per tier (issue #858).

Why a helper rather than inline Python in matcher-probe.yml: this verdict is a
branch-selecting core (a three-outcome PERMITTED / DENIED / unestablished selection,
where every state outside the measurable pair must route to `unestablished` and NEVER
to DENIED — a permission finding must never be published about a run that never
attempted the permission). Inline-in-YAML it cannot be unit-tested, so a regressed arm
would silently misfire while the workflow still "runs" — the same rationale as
scripts/background-tasks-probe-verdict.py (#812), scripts/env-propagation-probe-verdict.py
(#874), scripts/agents-seam-probe-verdict.py (#610), and scripts/describe-denial-count.sh
(PR #367).

THE PREMISE UNDER TEST. `Write(.devflow/tmp/**)` is granted in the review profile and
unrestricted `Write` in the implement profile, but every shipped instruction that authors
into that tree is addressed to the ORCHESTRATOR. Whether a DISPATCHED subagent's Write
lands is unestablished: a grant proven for the dispatcher is not inherited by the
dispatchee (CLAUDE.md: "Unknown is not zero"). Each tier gets its OWN dedicated job whose
prompt contains NO orchestrator write, so a Write record in its execution file has exactly
one possible author — the subagent.

HOW THE MEASUREMENT IS MADE ATTRIBUTABLE. The subagent makes a positive-control call on an
unambiguously granted head BEFORE the write attempt and one AFTER it (mirroring the #812
before/after pair). The two control facts are reported INDEPENDENTLY, never conjoined:

  recorded_at_all     did any subagent-issued call (a control or the write) appear in the
                      execution file at all? A no means the file does not surface
                      dispatchee actions, and nothing about the write can be concluded.
  chain_attributable  did those calls carry a `parent_tool_use_id` chain to a dispatch
                      recorded in this file? A no, WITH calls nonetheless recorded, is a
                      distinct THIRD schema world (dispatchee actions recorded but not
                      attributable by chain) — reported as its own `unestablished` reason,
                      not as "no dispatchee actions recorded".

Conjoining the two would misreport that third world as the first and — because a null
parent chain otherwise routes to `unestablished` — make PERMITTED unreachable by
construction, so the probe could not return the outcome it was filed to obtain.

A subagent-issued call is identified by carrying one of the probe markers in a tool_use
whose own name is NOT the dispatch tool (Task/Agent) — the dispatch's OWN input necessarily
quotes the marker vocabulary (it names what it asks the subagent to emit), so counting the
dispatch entry would credit a subagent call that never happened. This is the same
"the dispatch prompt unavoidably carries the marker" trap the #812 helper guards.

The ORCHESTRATOR is excluded by the same reasoning, but only where the file proves it can
be: this job's top-level session is granted heads whose inputs may also quote the marker
vocabulary (it reports whether the dispatch happened), and a top-level call carries no
`parent_tool_use_id`. So when THIS file records a parent chain on any entry at all, the
harness demonstrably surfaces the chain and a parent-less marker call is orchestrator-issued
and excluded. When NO entry in the file carries a parent, the schema does not surface chains
at all — excluding parent-less calls would then collapse the distinct third world below onto
"no dispatchee actions recorded", so they are retained and the third world's own reason
discloses that they cannot be told apart from orchestrator-issued calls.

Deterministic three-outcome verdict, execution-file + on-disk side-effect only (the
model's prose is NEVER read — only harness-recorded `tool_use` inputs, their
`parent_tool_use_id`, and `permission_denials`):

  PERMITTED       a subagent `Write` tool_use targeting the tier's side-effect path was
                  recorded, its parent chains to a dispatch recorded in this file, AND the
                  on-disk side-effect file is present. The verdict cites the parent chain.
  DENIED          a permission_denials entry attributable to the subagent's Write was
                  recorded. DENIED wins over a present side-effect file (an earlier run's
                  leftover): the denial signal is authoritative. Attribution rests on the
                  job's prompt containing NO orchestrator write, so a Write denial has
                  exactly one possible author; the run's observed denial-entry shape is
                  recorded alongside the verdict, which is what upgrades the denial side
                  from by-construction to measured.
                  Denial entries are classified ONE AT A TIME, never over their
                  concatenation: an entry is a DISPATCH refusal first (its own tool_name is
                  Task/Agent, or — with no tool_name recorded — it carries the quoted
                  `"subagent_type"` key or the `general-purpose` type name), otherwise a
                  WRITE denial (its own tool_name is Write and it names the side-effect path
                  or the payload, or — with no tool_name recorded — it names the side-effect
                  path), otherwise neither. Per-entry classification is what lets a
                  multi-entry list holding BOTH a dispatch refusal and a real Write denial
                  resolve DENIED, while a lone dispatch refusal whose recorded input echoes
                  the subagent prompt verbatim (naming the path and the payload) still routes
                  to `unestablished` rather than a false DENIED. A denial naming some OTHER
                  tool is neither, so a Bash/Read refusal quoting the payload can no longer
                  publish a permission finding about a permission that was granted.
                  Residual, disclosed: an entry recording no tool_name at all and naming the
                  side-effect path is read as the write denial — the per-entry shape is not
                  yet recorded, so no narrower attribution is available for it.
  unestablished   EVERY other state, each with its own named reason (never DENIED):
                  upstream tier job did not complete (consumed allowlist empty/absent),
                  execution file absent/unparseable/engine-errored, a `permission_denials`
                  key present in a shape that is not a list (the denials could not be
                  enumerated, so their absence is unknown rather than zero), a `--tier`
                  outside the closed set (the tier-derived write marker then names no real
                  side-effect file, so nothing measurable is being looked for), dispatch refused
                  (unknown subagent type / dispatch head not granted), no dispatch recorded,
                  no subagent-issued call recorded at all, subagent calls recorded but not
                  chain-attributable, a Write recorded but not chain-attributable to this
                  job's dispatch, a chain-attributable subagent call recorded but the write
                  neither recorded nor denied (the subagent ran but did not attempt it), or a
                  chain-attributable Write with no corroborating on-disk file.

Markers, kept in lockstep with matcher-probe.yml's subagent-write probe prompts:
  SUBWRITE_CONTROL_BEFORE   positive control, before the write attempt
  SUBWRITE_CONTROL_AFTER    positive control, after the write attempt
  SUBWRITE_PAYLOAD          the fixed content the subagent writes into the side-effect file
The tier's side-effect path (`.devflow/tmp/subwrite-<tier>.txt`) is the write marker: a
Write tool_use or a denial naming that path is the write signal.

Usage: subagent-write-probe-verdict.py [EXECUTION_FILE] --tier {review|implement}
                                       [--side-effect-file PATH] [--upstream-tools-empty]
                                       [--allowlist STR] [--permission-mode STR]
                                       [--model STR] [--effort STR] [--ref STR]
                                       [--head-commit STR]
  EXECUTION_FILE       path to the action's execution file; if omitted, read from the
                       EXECUTION_FILE env var. Empty/absent -> unestablished.
  --tier               review or implement (machine-consumed `tier` field in the output).
                       Any other value (including a missing one) emits a stderr breadcrumb
                       naming it and routes the run to `unestablished`.
  --side-effect-file   the tier's `.devflow/tmp/subwrite-<tier>.txt`; its on-disk presence
                       corroborates a PERMITTED. Absent -> no corroboration.
  --upstream-tools-empty  the consumed upstream allowlist output was empty/absent because
                       the upstream tier job did not complete -> unestablished (never a
                       skipped job silently emitting no verdict).
  --allowlist / --permission-mode / --model / --effort / --ref / --head-commit
                       recorded verbatim in the emitted table so the measured condition and
                       every permission-decision parameter travels with the verdict.
Prints the markdown verdict table to stdout (and appends it to GITHUB_STEP_SUMMARY when
set). Always exits 0.
"""

import json
import os
import sys

CONTROL_BEFORE = "SUBWRITE_CONTROL_BEFORE"
CONTROL_AFTER = "SUBWRITE_CONTROL_AFTER"
PAYLOAD = "SUBWRITE_PAYLOAD"
# Lowered once at module scope — every match below is case-insensitive, so recomputing
# `.lower()` on these fixed constants inside the per-entry loops is pure repeated work.
_CONTROL_BEFORE_L = CONTROL_BEFORE.lower()
_CONTROL_AFTER_L = CONTROL_AFTER.lower()
_PAYLOAD_L = PAYLOAD.lower()

# Names of the built-in dispatch tools. A tool_use with one of these names is the
# ORCHESTRATOR'S dispatch, whose input quotes the marker vocabulary — so a marker in such
# an entry is NOT evidence of a subagent-issued call.
DISPATCH_TOOL_NAMES = ("task", "agent")

VALID_TIERS = ("review", "implement")

# Sentinel distinguishing "permission_denials key absent" from "present and holding null" —
# a plain `.get()` default of None would conflate the two, and only the second is a
# wrong-type shape worth a breadcrumb.
_ABSENT = object()

# The closed three-outcome vocabulary. Checked at the end of compute() so a typo in any one
# verdict arm cannot silently ship an invalid verdict into the machine-consumed table; the
# check is an ordinary branch (a breadcrumb plus a fall back to `unestablished`), not an
# `assert`, because `python3 -O` strips asserts and a raising check would break the
# "Always exits 0" contract exactly when it fired.
_VERDICTS = ("PERMITTED", "DENIED", "unestablished")

VERSION_CAVEAT = (
    "This verdict is a dated observation of one `claude-code-action` version and one "
    "subagent definition (the built-in general-purpose type dispatched by the probe's own "
    "prompt under the tier's generated baseline at the recorded commit) — not a platform "
    "contract, and it establishes nothing for a differently-defined subagent type or a "
    "later claude-code-action version. Re-probe (dispatch matcher-probe.yml, or push to a "
    "same-repo PR touching it) after a claude-code-action / CLI upgrade before trusting it."
)


def parse_execution_file(exec_file):
    """Return (parsed, note_top). parsed is a JSON value — an empty list on every failure
    path, so callers need no None-guard — and note_top is a non-empty diagnostic when the
    file was absent/empty/unparseable/partially corrupt (which forces unestablished)."""
    if not (exec_file and os.path.isfile(exec_file)):
        return [], "execution file path absent or not a regular file at '%s'" % exec_file
    try:
        with open(exec_file, encoding="utf-8", errors="replace") as fh:
            raw = fh.read()
    except OSError as e:
        return [], "execution file present but unreadable (%s)" % e.__class__.__name__
    try:
        return json.loads(raw), ""
    except Exception:
        pass
    # Not a single JSON document — try JSONL, counting unparseable lines. A PARTIAL
    # corruption (some lines parse but the write/marker record does not) would otherwise
    # read as a clean measurement, so any drop forces unestablished.
    parsed = []
    dropped = 0
    for line in raw.splitlines():
        s = line.strip()
        if not s:
            continue
        try:
            parsed.append(json.loads(s))
        except Exception:
            dropped += 1
    if not parsed:
        return [], "execution file present but unparseable"
    if dropped:
        return parsed, (
            "%d execution-file line(s) were unparseable — verdict may be incomplete" % dropped
        )
    return parsed, ""


def collect(parsed):
    """Walk the parsed structure and return (denials, tool_uses, shape_notes).

    denials is a list of dicts {text, tool_name}, where text is the json-encoded
    permission_denials entry and tool_name is that entry's own lower-cased `tool_name`
    (or "" when the entry records none, or is not an object at all). tool_uses is a list of
    dicts {text, text_lower, name, id, parent} where text is the json-encoded input, name is
    the lower-cased tool name, id is the tool_use id (or ""), and parent is the
    `parent_tool_use_id` (or None). A tool_use node is recorded even when it carries no
    `input` key, so an input-less entry is not silently dropped. shape_notes is a list of
    specific breadcrumbs for malformed shapes the walk could not enumerate; a non-empty
    shape_notes forces `unestablished` — an unenumerable denial list is unknown, never zero.
    """
    denials = []
    tool_uses = []
    shape_notes = []

    def walk(o):
        if isinstance(o, dict):
            if o.get("type") == "tool_use":
                text = json.dumps(o.get("input"))
                tool_uses.append(
                    {
                        "text": text,
                        # Lowered once here so the per-entry marker matches below never
                        # re-lower the same string two-to-four times.
                        "text_lower": text.lower(),
                        "name": str(o.get("name", "")).lower(),
                        "id": o.get("id") if isinstance(o.get("id"), str) else "",
                        "parent": o.get("parent_tool_use_id"),
                    }
                )
            pd = o.get("permission_denials", _ABSENT)
            if pd is not _ABSENT and not isinstance(pd, list):
                # WRONG-TYPE row of the external-format shape matrix (CLAUDE.md): the key is
                # present but not a list, so the entries cannot be enumerated. Silently
                # skipping it would render a run whose Write was denied as PERMITTED —
                # collapsing an unestablished measurement onto "no denials". Emit a SPECIFIC
                # breadcrumb naming the observed type; the caller folds it into note_top,
                # which forces unestablished.
                shape_notes.append(
                    "a permission_denials key is present but is a %s, not a list — the "
                    "denial entries could not be enumerated" % type(pd).__name__
                )
            if isinstance(pd, list):
                for d in pd:
                    # Retain each denial's own tool_name (lower-cased) so the write-denial
                    # attribution below can exclude a denied DISPATCH — whose recorded
                    # tool_input echoes the subagent prompt (naming the side-effect path and
                    # payload) — the same way is_subagent_marker excludes a dispatch tool_use.
                    tn = str(d.get("tool_name", "")).lower() if isinstance(d, dict) else ""
                    denials.append({"text": json.dumps(d), "tool_name": tn})
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for it in o:
                walk(it)

    walk(parsed)
    return denials, tool_uses, shape_notes


def compute(denials, tool_uses, note_top, side_path, side_present, upstream_empty):
    """Return a dict of every field the table reports plus the final verdict/reason.

    All marker matches are case-insensitive so a decorated recording still reads present.
    `side_path` is the tier's side-effect filename stem used as the write marker."""
    write_marker = side_path.lower()

    # ── Denial classification, ONE ENTRY AT A TIME.
    # Joining the entries and substring-testing the concatenation is what made both denial
    # signals fire on the wrong run: a marker anywhere in ANY entry answered for every
    # entry, so a third tool's refusal that merely quoted the payload published DENIED, and
    # the bare token "agent" (a substring of "subagent_type", "agent_id", and of ordinary
    # prose) made every such list read as a refused dispatch. Each entry is therefore
    # classified on its OWN recorded text and its OWN tool_name, into exactly one bucket.
    #
    # A dispatch refusal is decided first FOR AN ENTRY (not for the run): its recorded
    # tool_input echoes the subagent prompt verbatim — naming `subwrite-<tier>.txt` and
    # SUBWRITE_PAYLOAD — so classifying it as the write denial would publish a permission
    # finding about a permission that was never attempted. With no tool_name recorded (the
    # per-entry shape is not yet recorded) the fingerprint is the quoted `"subagent_type"`
    # key or the `general-purpose` type name, both anchored forms rather than bare tokens.
    def _is_dispatch_denial(d):
        if d["tool_name"] in DISPATCH_TOOL_NAMES:
            return True
        if d["tool_name"]:
            return False  # a denial naming some OTHER tool is not a dispatch refusal
        t = d["text"].lower()
        return '"subagent_type"' in t or "general-purpose" in t

    # A write denial: an entry whose own tool_name is Write and which names the side-effect
    # path or the payload. An entry naming any OTHER tool is NOT the write denial, however
    # its text quotes the markers. Residual, disclosed: an entry recording no tool_name at
    # all is attributed by the side-effect path alone, because no narrower channel exists.
    def _is_write_denial(d):
        t = d["text"].lower()
        if d["tool_name"] == "write":
            return write_marker in t or _PAYLOAD_L in t
        if d["tool_name"]:
            return False
        return write_marker in t

    # One pass, one bucket per entry — never an identity/equality lookup back into a list,
    # which would misroute the second of two byte-identical entries.
    dispatch_denials = []
    write_denials = []
    for _d in denials:
        if _is_dispatch_denial(_d):
            dispatch_denials.append(_d)
        elif _is_write_denial(_d):
            write_denials.append(_d)
    dispatch_denied = bool(dispatch_denials)
    write_denied = bool(write_denials)
    # Only consulted inside the dispatch-refused arm to pick the reason wording, and read
    # from the DISPATCH entries alone rather than from every denial in the run.
    dispatch_denial_text = "\n".join(d["text"] for d in dispatch_denials).lower()
    unknown_type = (
        '"subagent_type"' in dispatch_denial_text
        or "general-purpose" in dispatch_denial_text
        or "unknown" in dispatch_denial_text
    )

    # Ids of the recorded dispatches (Task/Agent tool_use entries). A subagent call is
    # chain-attributable when its parent_tool_use_id is one of these.
    dispatch_ids = {
        tu["id"] for tu in tool_uses if tu["name"] in DISPATCH_TOOL_NAMES and tu["id"]
    }
    dispatch_recorded = any(tu["name"] in DISPATCH_TOOL_NAMES for tu in tool_uses)

    # Does THIS file surface parent chains at all? A top-level (orchestrator-issued) call
    # carries no parent_tool_use_id, so when some entry does carry one the harness
    # demonstrably records the field and a parent-less marker call is the orchestrator's —
    # excluded, because this job's orchestrator is granted heads whose inputs may quote the
    # marker vocabulary while reporting on the dispatch. When NO entry carries a parent the
    # schema does not surface chains at all; excluding parent-less calls would then collapse
    # the distinct "recorded but not chain-attributable" third world onto "no dispatchee
    # action recorded", so they are retained and that arm's reason discloses the ambiguity.
    chains_are_recorded = any(tu["parent"] is not None for tu in tool_uses)

    # Subagent-issued calls: a probe marker in a tool_use whose OWN name is not the
    # dispatch tool (the dispatch's own input quotes the marker vocabulary — counting it
    # would credit a call that never happened).
    def is_subagent_marker(tu):
        if tu["name"] in DISPATCH_TOOL_NAMES:
            return False
        if chains_are_recorded and tu["parent"] is None:
            return False
        t = tu["text_lower"]
        return (
            _CONTROL_BEFORE_L in t
            or _CONTROL_AFTER_L in t
            or write_marker in t
            or _PAYLOAD_L in t
        )

    subagent_calls = [tu for tu in tool_uses if is_subagent_marker(tu)]
    recorded_at_all = bool(subagent_calls)
    # `x in dispatch_ids` is already False for every element when the set is empty, so an
    # explicit `and bool(dispatch_ids)` conjunct would guard nothing — a True `any(...)`
    # here already proves a recorded dispatch was chained to.
    chain_attributable = any(
        (tu["parent"] in dispatch_ids) for tu in subagent_calls if tu["parent"] is not None
    )

    control_before = any(_CONTROL_BEFORE_L in tu["text_lower"] for tu in subagent_calls)
    control_after = any(_CONTROL_AFTER_L in tu["text_lower"] for tu in subagent_calls)

    # The Write tool_use targeting the tier's side-effect path. The recorded tool's OWN name
    # must be `write`: naming the path is not issuing the write, and any granted head can
    # name it — a subagent reading its work back (`Bash: cat .devflow/tmp/subwrite-*.txt`)
    # with a leftover file on disk would otherwise publish PERMITTED for a run in which no
    # Write was ever issued, the probe's headline positive result about a permission that
    # was never exercised. Requiring the name fails CLOSED: a non-Write naming the path now
    # routes to an `unestablished` arm rather than to a false PERMITTED.
    write_calls = [
        tu
        for tu in tool_uses
        if tu["name"] == "write"
        and (write_marker in tu["text_lower"] or _PAYLOAD_L in tu["text_lower"])
    ]
    write_recorded = bool(write_calls)
    write_chain_ok = any(
        (tu["parent"] in dispatch_ids) for tu in write_calls if tu["parent"] is not None
    )

    # ── Verdict, degraded arms FIRST (a measurement that did not run must never read as
    # one that came back negative — the unknown-is-not-zero collapse this ordering stops).
    if upstream_empty:
        verdict, reason = "unestablished", (
            "the consumed upstream allowlist output was empty or absent because the upstream "
            "tier job did not complete (fail/cancel/skip) — nothing was measured"
        )
    elif note_top:
        verdict, reason = "unestablished", (
            "the execution file could not be read cleanly: " + note_top
        )
    elif write_denied:
        # Checked BEFORE the dispatch-refused arm, and safely so: the dispatch-echo hazard
        # is handled per ENTRY above (an entry classified as a dispatch refusal never lands
        # in write_denials), so reaching this arm means some entry is attributable to the
        # write itself. Ordering it first is what lets a multi-entry list holding both a
        # dispatch refusal and a real Write denial resolve DENIED instead of reporting
        # `unestablished` with a positively-stated claim that no write was attempted.
        verdict, reason = "DENIED", (
            "a permission_denials entry for the subagent's Write into %s was recorded; "
            "attribution rests on this job's prompt containing no orchestrator write, so the "
            "denial has exactly one possible author" % side_path
        )
    elif dispatch_denied:
        verdict, reason = "unestablished", (
            "the dispatch was refused by the matcher (%s) and no denial entry is "
            "attributable to the write — no write permission was even attempted"
            % ("unknown subagent type" if unknown_type else "dispatch head not granted")
        )
    elif write_recorded and write_chain_ok and side_present:
        verdict, reason = "PERMITTED", (
            "a subagent Write tool_use targeting %s was recorded, its parent chains to a "
            "dispatch recorded in this file, and the on-disk side-effect file is present" % side_path
        )
    elif not dispatch_recorded and not recorded_at_all:
        verdict, reason = "unestablished", (
            "no dispatch was recorded and no subagent-issued call appeared — the dispatch "
            "never occurred"
        )
    elif not recorded_at_all:
        verdict, reason = "unestablished", (
            "a dispatch was recorded but no subagent-issued call appeared at all — the "
            "execution file does not surface dispatchee actions, so nothing about the write "
            "can be concluded"
        )
    elif not chain_attributable:
        verdict, reason = "unestablished", (
            "marker-carrying calls were recorded but carried no parent chain to a dispatch "
            "in this file — a distinct third schema world: dispatchee actions recorded but "
            "not chain-attributable, so the attribution channel does not exist"
            + (
                ""
                if chains_are_recorded
                else " (and because no entry in this file carries a parent_tool_use_id at "
                "all, these calls cannot be distinguished from orchestrator-issued ones)"
            )
        )
    elif write_recorded and not write_chain_ok:
        verdict, reason = "unestablished", (
            "a Write was recorded but its parent chain does not tie it to this job's "
            "dispatch, so it cannot be attributed to the dispatched subagent"
        )
    elif not write_recorded:
        verdict, reason = "unestablished", (
            "a chain-attributable subagent call was recorded but the write was neither "
            "recorded nor denied — the subagent ran but did not attempt the write"
        )
    else:  # write_recorded and write_chain_ok and not side_present
        verdict, reason = "unestablished", (
            "a chain-attributable Write tool_use was recorded but the on-disk side-effect "
            "file is absent, so the permit is uncorroborated"
        )

    dispatch_outcome = "denied" if dispatch_denied else ("recorded" if dispatch_recorded else "absent")
    write_outcome = "denied" if write_denied else ("recorded" if write_recorded else "absent")

    # A typo in any verdict arm above would otherwise ship an invalid string into the
    # machine-consumed table. An `assert` is not the instrument: `python3 -O` strips it, and
    # were it ever to fire it would raise through main() against the "Always exits 0"
    # contract. An ordinary branch is always live and fails closed onto `unestablished`.
    if verdict not in _VERDICTS:
        sys.stderr.write(
            "subagent-write-probe-verdict: internal error — verdict %r is outside the "
            "closed vocabulary %s; reporting unestablished\n" % (verdict, list(_VERDICTS))
        )
        verdict, reason = "unestablished", (
            "the verdict derivation produced a value outside the closed three-outcome "
            "vocabulary, so nothing about the write is established (see stderr)"
        )
    return {
        "verdict": verdict,
        "reason": reason,
        "dispatch_outcome": dispatch_outcome,
        "recorded_at_all": recorded_at_all,
        "chain_attributable": chain_attributable,
        "control_before": control_before,
        "control_after": control_after,
        "write_outcome": write_outcome,
        "write_chain_ok": write_chain_ok,
        "side_present": side_present,
        "denials": denials,
    }


def render(exec_file, tier, side_effect_file, upstream_empty, params):
    notes = []
    if tier not in VALID_TIERS:
        # A tier outside the closed set is not coerced silently: the write marker is derived
        # FROM the tier, so `unknown` makes the helper look for `subwrite-unknown.txt`, a
        # file no probe job writes — every write-side signal would then read absent and the
        # run would render a confident-looking negative about a marker that never existed.
        notes.append(
            "--tier value '%s' is not one of %s, so the tier-derived write marker names no "
            "side-effect file any probe job writes" % (tier, "/".join(VALID_TIERS))
        )
        sys.stderr.write(
            "subagent-write-probe-verdict: %s; reporting unestablished\n" % notes[-1]
        )
        tier = "unknown"
    side_path = "subwrite-%s.txt" % tier
    side_present = bool(side_effect_file) and os.path.isfile(side_effect_file)

    parsed, parse_note = parse_execution_file(exec_file)
    if parse_note:
        notes.append(parse_note)
    try:
        denials, tool_uses, shape_notes = collect(parsed)
    except RecursionError:
        denials, tool_uses, shape_notes = [], [], []
        notes.append("execution file nested too deeply to walk")
    notes.extend(shape_notes)
    # Any non-empty note forces unestablished in compute()'s second arm — an execution file
    # this helper could not read cleanly, in whole or in part, is unknown, never zero.
    note_top = "; ".join(notes)

    r = compute(denials, tool_uses, note_top, side_path, side_present, upstream_empty)

    out = []
    out.append("## Dispatched-subagent Write probe — %s tier (issue #858)" % tier)
    out.append("")
    out.append("**Verdict: `%s`**" % r["verdict"])
    out.append("")
    out.append(r["reason"] + ".")
    out.append("")
    out.append(
        "Deterministic verdict from the execution file's recorded `tool_use` inputs, their "
        "`parent_tool_use_id`, and `permission_denials`, corroborated by the on-disk "
        "side-effect file `.devflow/tmp/%s`. The model's prose is never the measurement." % side_path
    )
    out.append("")
    out.append("> [!IMPORTANT]")
    out.append("> %s" % VERSION_CAVEAT)
    out.append("")
    # The two control facts, reported INDEPENDENTLY (never conjoined), plus dispatch and
    # write as separate fields so a reader can tell a denied write from an absent dispatch.
    out.append("| Field | Value |")
    out.append("|-------|-------|")
    out.append("| tier | `%s` |" % tier)
    out.append("| verdict | **%s** |" % r["verdict"])
    out.append("| dispatch_outcome | %s |" % r["dispatch_outcome"])
    out.append("| recorded_at_all | %s |" % ("yes" if r["recorded_at_all"] else "no"))
    out.append("| chain_attributable | %s |" % ("yes" if r["chain_attributable"] else "no"))
    out.append("| control_before | %s |" % ("yes" if r["control_before"] else "no"))
    out.append("| control_after | %s |" % ("yes" if r["control_after"] else "no"))
    out.append("| write_outcome | %s |" % r["write_outcome"])
    out.append("| write_chain_ok | %s |" % ("yes" if r["write_chain_ok"] else "no"))
    out.append("| side_effect_present | %s |" % ("yes" if r["side_present"] else "no"))
    out.append("")
    # Every permission-decision parameter travels with the verdict — the resolved literal
    # verbatim, not a prose summary of the composition.
    for label, key in (
        ("permission_mode", "permission_mode"),
        ("model", "model"),
        ("effort", "effort"),
        ("ref", "ref"),
        ("head_commit", "head_commit"),
    ):
        val = params.get(key)
        if val:
            out.append("**%s:** `%s`" % (label, val))
            out.append("")
    allowlist = params.get("allowlist")
    if allowlist:
        out.append("**Resolved `--allowed-tools` literal (the measured condition, verbatim):**")
        out.append("")
        out.append("```")
        out.append(allowlist)
        out.append("```")
        out.append("")
    # The observed denial-entry shape — the read that upgrades the DENIED side from
    # by-construction to measured.
    out.append("### Observed `permission_denials` entries (%d)" % len(r["denials"]))
    out.append("")
    if r["denials"]:
        out.append("```")
        for d in r["denials"]:
            out.append(d["text"][:400])
        out.append("```")
    else:
        out.append("_No permission_denials entries found in the execution file._")
    return "\n".join(out)


def main():
    exec_file = ""
    tier = ""
    side_effect_file = ""
    upstream_empty = False
    params = {}
    args = sys.argv[1:]
    i = 0
    flag_keys = {
        "--tier": "tier",
        "--side-effect-file": "side_effect_file",
        "--allowlist": "allowlist",
        "--permission-mode": "permission_mode",
        "--model": "model",
        "--effort": "effort",
        "--ref": "ref",
        "--head-commit": "head_commit",
    }
    positional = []
    while i < len(args):
        a = args[i]
        if a == "--upstream-tools-empty":
            upstream_empty = True
            i += 1
        elif a in flag_keys:
            # A value-taking flag whose value is missing must not silently swallow the next
            # FLAG as data: `--tier --allowlist X` would otherwise bind tier="--allowlist"
            # and drop the allowlist entirely from the record that is meant to carry "the
            # measured condition, verbatim". Both shapes get a specific breadcrumb and an
            # empty value; an empty --tier then routes to unestablished via render().
            nxt = args[i + 1] if i + 1 < len(args) else None
            if nxt is None or nxt in flag_keys or nxt == "--upstream-tools-empty":
                sys.stderr.write(
                    "subagent-write-probe-verdict: %s was given no value (%s); treating it "
                    "as empty\n"
                    % (a, "end of arguments" if nxt is None else "next argument is %s" % nxt)
                )
                val = ""
                consumed = 1
            else:
                val = nxt
                consumed = 2
            if a == "--tier":
                tier = val
            elif a == "--side-effect-file":
                side_effect_file = val
            else:
                params[flag_keys[a]] = val
            i += consumed
        else:
            positional.append(a)
            i += 1
    if positional:
        exec_file = positional[0]
    if not exec_file:
        exec_file = os.environ.get("EXECUTION_FILE", "") or ""

    table = render(exec_file, tier, side_effect_file, upstream_empty, params)
    print(table)
    summary = os.environ.get("GITHUB_STEP_SUMMARY", "")
    if summary:
        # Best-effort side-output: an unwritable GITHUB_STEP_SUMMARY must not raise through
        # main() and break the "Always exits 0" contract — the verdict already went to
        # stdout, the authoritative surface.
        try:
            with open(summary, "a", encoding="utf-8") as fh:
                fh.write(table + "\n")
        except OSError as e:
            sys.stderr.write(
                "subagent-write-probe-verdict: could not append to GITHUB_STEP_SUMMARY "
                "(%s); verdict is on stdout\n" % e.__class__.__name__
            )
    return 0


if __name__ == "__main__":
    sys.exit(main())
