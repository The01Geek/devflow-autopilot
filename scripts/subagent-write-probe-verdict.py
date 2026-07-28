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

Deterministic three-outcome verdict, execution-file + on-disk side-effect only (the
model's prose is NEVER read — only harness-recorded `tool_use` inputs, their
`parent_tool_use_id`, and `permission_denials`):

  PERMITTED       a subagent Write tool_use targeting the tier's side-effect path was
                  recorded, its parent chains to a dispatch recorded in this file, AND the
                  on-disk side-effect file is present. The verdict cites the parent chain.
  DENIED          a permission_denials entry for the subagent's Write was recorded. This
                  wins over a present side-effect file (an earlier run's leftover): the
                  denial signal is authoritative. Attribution rests on the job's prompt
                  containing NO orchestrator write (the permission_denials per-entry shape
                  is not yet recorded, so a Write denial has exactly one possible author);
                  the run's observed denial-entry shape is recorded alongside the verdict,
                  which is what upgrades the denial side from by-construction to measured.
  unestablished   EVERY other state, each with its own named reason (never DENIED):
                  upstream tier job did not complete (consumed allowlist empty/absent),
                  execution file absent/unparseable/engine-errored, dispatch refused
                  (unknown subagent type / dispatch head not granted), no dispatch recorded,
                  no subagent-issued call recorded at all, subagent calls recorded but not
                  chain-attributable, a Write recorded but not chain-attributable to this
                  job's dispatch, both controls recorded and chain-attributable but the
                  write neither recorded nor denied (the subagent did not attempt it), or a
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
    """Walk the parsed structure and return (denials, tool_uses).

    denials is a list of json-encoded permission_denials entries. tool_uses is a list of
    dicts {text, name, id, parent} where text is the json-encoded input, name is the
    lower-cased tool name, id is the tool_use id (or ""), and parent is the
    `parent_tool_use_id` (or None). A tool_use node is recorded even when it carries no
    `input` key, so an input-less entry is not silently dropped."""
    denials = []
    tool_uses = []

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
            pd = o.get("permission_denials")
            if isinstance(pd, list):
                for d in pd:
                    denials.append(json.dumps(d))
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for it in o:
                walk(it)

    walk(parsed)
    return denials, tool_uses


def compute(denials, tool_uses, note_top, side_path, side_present, upstream_empty):
    """Return a dict of every field the table reports plus the final verdict/reason.

    All marker matches are case-insensitive so a decorated recording still reads present.
    `side_path` is the tier's side-effect filename stem used as the write marker."""
    write_marker = side_path.lower()
    denial_text = "\n".join(denials).lower()

    # Ids of the recorded dispatches (Task/Agent tool_use entries). A subagent call is
    # chain-attributable when its parent_tool_use_id is one of these.
    dispatch_ids = {
        tu["id"] for tu in tool_uses if tu["name"] in DISPATCH_TOOL_NAMES and tu["id"]
    }
    dispatch_recorded = any(tu["name"] in DISPATCH_TOOL_NAMES for tu in tool_uses)

    # A dispatch denial: a permission_denials entry naming a dispatch tool or the
    # subagent-type/definition machinery. Each substring is tested once and reused.
    has_subagent_type = "subagent_type" in denial_text
    has_general_purpose = "general-purpose" in denial_text
    dispatch_denied = (
        any(n in denial_text for n in DISPATCH_TOOL_NAMES)
        or has_subagent_type
        or has_general_purpose
    )
    # Only consulted inside the `elif dispatch_denied:` arm to pick the reason wording.
    unknown_type = has_subagent_type or has_general_purpose or "unknown" in denial_text

    # Subagent-issued calls: a probe marker in a tool_use whose OWN name is not the
    # dispatch tool (the dispatch's own input quotes the marker vocabulary — counting it
    # would credit a call that never happened).
    def is_subagent_marker(tu):
        if tu["name"] in DISPATCH_TOOL_NAMES:
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

    # The Write tool_use targeting the tier's side-effect path (name == write, or the
    # payload/path marker in a non-dispatch entry).
    write_calls = [
        tu
        for tu in tool_uses
        if tu["name"] not in DISPATCH_TOOL_NAMES
        and (write_marker in tu["text_lower"] or (tu["name"] == "write" and _PAYLOAD_L in tu["text_lower"]))
    ]
    write_recorded = bool(write_calls)
    write_chain_ok = any(
        (tu["parent"] in dispatch_ids) for tu in write_calls if tu["parent"] is not None
    )
    write_denied = write_marker in denial_text or (
        "write" in denial_text and _PAYLOAD_L in denial_text
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
        verdict, reason = "DENIED", (
            "a permission_denials entry for the subagent's Write into %s was recorded; "
            "attribution rests on this job's prompt containing no orchestrator write, so the "
            "denial has exactly one possible author" % side_path
        )
    elif write_recorded and write_chain_ok and side_present:
        verdict, reason = "PERMITTED", (
            "a subagent Write tool_use targeting %s was recorded, its parent chains to a "
            "dispatch recorded in this file, and the on-disk side-effect file is present" % side_path
        )
    elif dispatch_denied:
        verdict, reason = "unestablished", (
            "the dispatch was refused by the matcher (%s) — no write permission was even "
            "attempted" % ("unknown subagent type" if unknown_type else "dispatch head not granted")
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
            "subagent-issued calls were recorded but carried no parent chain to a dispatch "
            "in this file — a distinct third schema world: dispatchee actions recorded but "
            "not chain-attributable, so the attribution channel does not exist"
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
    tier = tier if tier in VALID_TIERS else "unknown"
    side_path = "subwrite-%s.txt" % tier
    side_present = bool(side_effect_file) and os.path.isfile(side_effect_file)

    parsed, note_top = parse_execution_file(exec_file)
    try:
        denials, tool_uses = collect(parsed)
    except RecursionError:
        denials, tool_uses = [], []
        note_top = (note_top + "; " if note_top else "") + "execution file nested too deeply to walk"

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
            out.append(d[:400])
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
            val = args[i + 1] if i + 1 < len(args) else ""
            if a == "--tier":
                tier = val
            elif a == "--side-effect-file":
                side_effect_file = val
            else:
                params[flag_keys[a]] = val
            i += 2
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
