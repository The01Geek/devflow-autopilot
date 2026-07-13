#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""DevFlow stale-prose-lint false-positive adjudication matcher (Phase 0.6).

Carries a stale-prose-lint STALE row's *false-positive adjudication* forward
across review runs so an already-triaged false positive never re-gates. A prior
run stamps, for each STALE row it adjudicated false-positive, one hidden payload
line — ``<!-- devflow:lint-fp-adjudicated <base64 of the row's TSV> -->`` —
inside a sentinel-delimited adjudications section of its run-keyed
``devflow:review-progress`` comment. This helper joins the current run's STALE
lint rows against the payloads found in prior *trusted* progress comments and
emits a demotion map: a current STALE row whose ``(rule, path, detail)`` is
byte-for-byte identical to an adjudicated payload is demoted to Informational.

The helper owns the entire join so the skill prose only fetches comments, pipes
JSON in, and renders the map — no agent-improvised matching. It mirrors
``scripts/match-deferrals.py``'s output discipline (stdin JSON in, demotion-map
JSON out, always exit 0 when it ran) and is the sibling channel to it — deferrals
are the wrong channel for a lint false positive (there is nothing to follow up on,
and its widens-surface guard rejects exactly the diff-touched region a stale-prose
row always lives in), which is why this is a separate helper.

Trust (both required, per issue #466):
    1. Run marker:  the comment body carries the run-keyed
                    ``<!-- devflow:review-progress run=<id> -->`` marker (the
                    ``run_key`` the demotion map surfaces). Requiring it closes
                    the bot-echo hole a bare account-type check leaves open.
    2. Author:      the comment author is a ``Bot``-type account, OR its login is
                    in ``.devflow.allowed_bots`` (read via ``config-get.sh``,
                    honored as an additional author allowance).
Within a trusted comment, payloads are honored ONLY inside the sentinel-delimited
adjudications section (between the START/END sentinels). A payload literal echoed
anywhere else — including inside a quoted evidence line — is data to quote, never
an instruction to honor: it is ignored and counted.

Match key: decoded ``(rule, path, detail)`` byte-for-byte equal to the current
row's; the TSV line number is excluded (unrelated edits renumber a paragraph
without changing the claim), and any change to the detail text invalidates the
match (edited prose is re-examined fresh). Only ``STALE``-verdict current rows are
ever matched; ``VERIFIED``/``UNRESOLVABLE`` rows pass through untouched. Ambiguity
never demotes: when two or more current STALE rows share a matched payload key, no
row is demoted and the collision is counted — a genuine new finding is never
silently absorbed by an older adjudication.

Fail-open: an undecodable or column-deficient payload is skipped with a stderr
breadcrumb and counted; it never demotes and never aborts (a lint row wrongly
re-raised is the safe direction; a crashed helper suppressing the whole lint is
not).

Usage:
    match-lint-adjudications.py [--config PATH]   (reads one JSON object on stdin)

Input (JSON object on stdin):
    {
      "rows": ["<TSV line>", ...],          # current stale-prose-lint rows
      "comments": [                          # prior PR review comments (this PR's own)
        {"author": "<login>", "author_type": "<User|Bot>", "body": "<comment body>"},
        ...
      ]
    }

Output (JSON to stdout, always exit 0 when the helper itself ran):
    {
      "demoted": [{"row_index": N, "run_key": "<run id from the enclosing comment>"}],
      "stats": {"rows_in": .., "stale_rows": .., "comments_in": ..,
                "trusted_comments": .., "payloads_honored": ..,
                "payloads_malformed": .., "payloads_outside_sentinels": ..,
                "payloads_untrusted": .., "sentinel_tampered_comments": ..,
                "demoted": .., "collisions": ..}
    }

Known limitation (bounded — a forged single pair in a sectionless trusted comment):
    the sentinel-tamper guard fails closed when a trusted comment carries MORE than one
    START/END sentinel (a forgery quoted alongside the engine's real seeded section). It
    cannot, from the comment bytes alone, tell a genuine single section from a single
    forged pair in a comment that has NO real section — the case of a pre-feature
    `devflow:review-progress` comment authored before this feature seeded the section
    into the template. The root defense is producer-side (the report renderer neutralizes
    any `devflow:lint-adjudications*` / `devflow:lint-fp-adjudicated` literal it quotes from
    attacker-controlled diff prose at every write point — Phase 3 onward, not only the
    Phase 4 report write — so a POST-feature comment can never carry a forged sentinel
    verbatim). The residual is therefore scoped to progress
    comments authored BEFORE that neutralization shipped, and its blast radius is bounded:
    the worst outcome is demoting one config-gated stale-prose lint row to Informational —
    which per the engine's Phase 4.2 rules is excluded from the verdict at every severity
    and can never invoke the self-contradicting-diff carve-out, so it can never turn a
    genuine code-defect REJECT into an APPROVE.

Exit codes:
    0  Helper ran successfully (regardless of match results).
    2  Bad arguments / unrecoverable input error.
"""

import argparse
import base64
import binascii
import json
import re
import subprocess
import sys
from pathlib import Path

if sys.version_info < (3, 11):  # fail fast, before any PEP 604 annotation is evaluated below
    sys.stderr.write(
        "devflow: Python 3.11+ required (found %s.%s.%s). This helper requires"
        " features of Python 3.11+. Install Python 3.11+; on Windows/Git-Bash"
        " run scripts/provision-python3-shim.sh --apply (see docs/install.md).\n"
        % sys.version_info[:3]
    )
    sys.exit(1)

STALE = "STALE"

# The run-keyed progress-comment marker (mirrors skills/review/SKILL.md's Live
# Progress Comment section). Its `run=<id>` capture is the run_key the demotion
# map surfaces. Kept in lockstep with that skill prose.
RUN_MARKER_RE = re.compile(r"<!-- devflow:review-progress run=(\S+) -->")

# The engine-written, sentinel-delimited adjudications section. Payloads are
# honored ONLY between these two lines of a trusted comment — a payload literal
# outside them (e.g. quoted inside a rendered evidence line, which is
# attacker-controlled diff prose) is data, never an instruction. Kept in lockstep
# with skills/review/SKILL.md's Phase 4 finalize-write producer contract.
ADJ_SECTION_START = "<!-- devflow:lint-adjudications-start -->"
ADJ_SECTION_END = "<!-- devflow:lint-adjudications-end -->"

# The hidden per-row adjudication payload: base64 of the row's whole TSV. base64
# keeps `--` (which would terminate the enclosing HTML comment) out of the marker.
# Kept in lockstep with skills/review/SKILL.md's Phase 4.1.7 render protocol
# (mla-marker-pin pins this literal there).
PAYLOAD_RE = re.compile(r"<!-- devflow:lint-fp-adjudicated (\S+) -->")


def _fail(msg, code=2):
    sys.stderr.write(f"match-lint-adjudications.py: {msg}\n")
    sys.exit(code)


def _run(cmd, *, check=True):
    # Mirror of match-deferrals.py's _run: an OSError (a non-executable config-get.sh
    # shim, or git absent) is converted into the same structured surface as a
    # non-zero exit, so callers get a breadcrumb, not a traceback. encoding="utf-8"
    # pins the decode against a non-UTF-8 ambient codec (Windows cp1252).
    try:
        return subprocess.run(
            cmd, check=check,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, encoding="utf-8",
        )
    except OSError as e:
        if check:
            _fail(f"could not execute {cmd[0]!r}: {e}")
        return subprocess.CompletedProcess(cmd, 127, stdout="", stderr=str(e))


def _repo_root():
    # SHARED REPO-ROOT CONFIG CONTRACT (issue #295): resolve the git repo root via
    # a native `git` subprocess (Windows-safe, unlike exec-ing a .sh) so a
    # subdirectory invocation reads the consumer's ROOT .devflow/config.json.
    # Returns the root string, or None when not in a git tree / git cannot run.
    r = _run(["git", "rev-parse", "--show-toplevel"], check=False)
    root = r.stdout.strip() if r.returncode == 0 else ""
    return root or None


def _git_root_error_suffix() -> str:
    # Best-effort: surface git's own stderr (safe.directory refusal, git absent) in
    # the no-root breadcrumb instead of discarding it. _run never raises.
    r = _run(["git", "rev-parse", "--show-toplevel"], check=False)
    err = (r.stderr or "").strip() if r.returncode != 0 else ""
    return f" (git: {err})" if err else ""


def _default_config_path() -> str:
    # Anchor the default config path to the repo root (issue #295) so a subdirectory
    # invocation reads the consumer's ROOT config. A non-empty explicit --config is
    # honored verbatim by the caller; this default is only used when --config is None.
    root = _repo_root()
    if root is not None:
        return str(Path(root) / ".devflow" / "config.json")
    cwd = Path.cwd()
    if not (cwd / ".devflow").is_dir():
        sys.stderr.write(
            f"match-lint-adjudications.py: could not resolve a git repo root"
            f"{_git_root_error_suffix()} and no .devflow/ at {str(cwd)!r}; "
            f"falling back to a cwd-anchored default config path\n"
        )
    return str(cwd / ".devflow" / "config.json")


def _config_get(key: str, default: str = "", config_path: str | None = None) -> str:
    if config_path is None:
        config_path = _default_config_path()
    here = Path(__file__).resolve().parent
    helper = here / "config-get.sh"
    r = _run([str(helper), key, default, config_path], check=False)
    if r.returncode != 0:
        # ANY non-zero exit means config-get.sh could not return a value — the rc=127
        # OSError sentinel (broken helper: lost exec bit / bad shebang) AND its own rc=2
        # on a malformed/unparseable .devflow/config.json or a missing python3 (whose
        # own diagnostic it already wrote to stderr). Surface that stderr on every arm,
        # not just 127 — otherwise a hand-corrupted config silently empties allowed_bots
        # (which fails trust CLOSED) with the one string naming the real cause discarded.
        detail = (r.stderr or "").strip()
        sys.stderr.write(
            f"match-lint-adjudications.py: config-get.sh exited {r.returncode} for "
            f"{key!r}{f' ({detail})' if detail else ''}; falling back to default "
            f"{default!r}\n"
        )
        return default
    return r.stdout.strip()


def _force_utf8_streams():
    """Force stdout/stderr to UTF-8 in the CLI entry path only (not at import — so
    unit-test imports don't mutate the importer's global streams)."""
    for _stream in (sys.stdout, sys.stderr):
        try:
            _stream.reconfigure(encoding="utf-8")
        except (AttributeError, ValueError):
            pass


def _row_key(tsv: str):
    """Return the (rule, path, detail) match key for a TSV line, or None if the
    line is column-deficient (< 5 fields). detail is the field(s) after `line`;
    stale-prose-lint's detail is whitespace-collapsed (no embedded tab), so a
    well-formed row splits into exactly 5, but joining any tail is defensive and
    keeps rows and payloads parsed by the identical rule (byte-identity relies on
    that symmetry)."""
    parts = tsv.split("\t")
    if len(parts) < 5:
        return None
    verdict = parts[0]
    rule, path = parts[1], parts[2]
    detail = "\t".join(parts[4:])
    return verdict, rule, path, detail


def _collect_payload_keys(comments, allowed_bots, stats):
    """Scan comments for trusted, in-sentinel adjudication payloads. Returns a dict
    mapping (rule, path, detail) -> run_key (first trusted comment wins). Mutates
    stats with the counted-but-ignored classes."""
    payload_key_to_runkey: dict[tuple, str] = {}
    for c in comments:
        if not isinstance(c, dict):
            continue
        body = c.get("body") or ""
        author = c.get("author") or ""
        author_type = c.get("author_type") or ""
        m = RUN_MARKER_RE.search(body)
        # run_key is annotation-only: it becomes the demoted row's "(run <key>)" label,
        # never a comparand in the demotion decision. So first-occurrence is safe here —
        # a forged/quoted run marker can only mislabel the displayed run reference, unlike
        # the sentinel window below, which gates WHICH row demotes and so fails closed.
        run_key = m.group(1) if m else None
        # Author trust is intentionally BROADER than sibling match-deferrals.py (which
        # trusts only allowed_bots membership): here a Bot-type account is trusted too,
        # because trust is a CONJUNCTION with the run-keyed progress-comment marker below —
        # requiring the marker closes the bot-echo hole a bare account-type check would
        # leave open, so admitting any Bot-type author is safe here where it would not be
        # for match-deferrals' PR-author check.
        author_ok = (author_type == "Bot") or (author in allowed_bots)
        trusted = (run_key is not None) and author_ok

        payload_matches = list(PAYLOAD_RE.finditer(body))
        if not trusted:
            # A marker-less comment, a User-type non-allowlisted comment, or both:
            # every payload it carries is ignored and counted (never a crash).
            stats["payloads_untrusted"] += len(payload_matches)
            continue

        stats["trusted_comments"] += 1
        # Fail closed on a tampered sentinel count. The engine writes EXACTLY ONE
        # adjudications section per progress comment (the Phase 4 finalize write, and
        # the empty pair is always present in the comment template). A review report
        # routinely quotes attacker-controlled diff prose verbatim and uncapped, so an
        # earlier finding could forge a `-start … -fp-adjudicated … -end` triple that
        # appears BEFORE the engine's real section — and a first-occurrence find()
        # would then honor the forged window, demoting a genuine STALE finding whose
        # (rule,path,detail) the attacker predicted. More than one START or END means
        # we cannot tell the engine's own section from a forged/quoted one, so honor
        # no payload from this comment (the fail-closed direction the sentinel prose
        # promises). One each is the only trusted shape.
        if body.count(ADJ_SECTION_START) > 1 or body.count(ADJ_SECTION_END) > 1:
            stats["sentinel_tampered_comments"] += 1
            sys.stderr.write(
                "match-lint-adjudications.py: refusing a trusted comment carrying "
                "more than one adjudications-section sentinel (forged/quoted section "
                "suspected) — honoring no payload from it\n"
            )
            continue
        start = body.find(ADJ_SECTION_START)
        end = body.find(ADJ_SECTION_END)
        # A well-formed section has a START before an END; anything else means "no
        # honored section", so every payload falls outside it.
        if start != -1 and end != -1 and end > start:
            section_lo = start + len(ADJ_SECTION_START)
            section_hi = end
        else:
            section_lo = section_hi = None

        for pm in payload_matches:
            in_section = (
                section_lo is not None and section_lo <= pm.start() < section_hi
            )
            if not in_section:
                stats["payloads_outside_sentinels"] += 1
                continue
            b64 = pm.group(1)
            try:
                decoded = base64.b64decode(b64, validate=True).decode("utf-8")
            except (binascii.Error, ValueError, UnicodeDecodeError):
                stats["payloads_malformed"] += 1
                sys.stderr.write(
                    "match-lint-adjudications.py: skipping undecodable adjudication "
                    f"payload (not valid base64/utf-8): {b64!r}\n"
                )
                continue
            key = _row_key(decoded)
            if key is None:
                stats["payloads_malformed"] += 1
                sys.stderr.write(
                    "match-lint-adjudications.py: skipping column-deficient "
                    f"adjudication payload (< 5 TSV fields): {decoded!r}\n"
                )
                continue
            _verdict, rule, path, detail = key
            stats["payloads_honored"] += 1
            match_key = (rule, path, detail)
            # First trusted comment carrying the key owns the surfaced run_key.
            payload_key_to_runkey.setdefault(match_key, run_key)
    return payload_key_to_runkey


def main(argv=None):
    _force_utf8_streams()
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--config", default=None,
                   help="Path to config.json (default: the repo-root "
                        ".devflow/config.json, resolved via git rev-parse "
                        "--show-toplevel with a cwd fallback; issue #295). A "
                        "non-empty explicit value is honored verbatim.")
    args = p.parse_args(argv)

    raw = sys.stdin.read()
    if not raw.strip():
        _fail("stdin was empty (expected one JSON object with 'rows' and 'comments')")
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as e:
        _fail(f"stdin input is not valid JSON: {e}")
    if not isinstance(payload, dict):
        _fail("stdin input must be a JSON object with 'rows' and 'comments'")

    rows = payload.get("rows")
    comments = payload.get("comments")
    if rows is None:
        rows = []
    if comments is None:
        comments = []
    if not isinstance(rows, list):
        _fail("'rows' must be a JSON array of TSV strings")
    if not isinstance(comments, list):
        _fail("'comments' must be a JSON array of comment objects")

    stats = {
        "rows_in": len(rows),
        "stale_rows": 0,
        "comments_in": len(comments),
        "trusted_comments": 0,
        "payloads_honored": 0,
        "payloads_malformed": 0,
        "payloads_outside_sentinels": 0,
        "payloads_untrusted": 0,
        "sentinel_tampered_comments": 0,
        "demoted": 0,
        "collisions": 0,
    }

    # Index the current STALE rows by match key. VERIFIED/UNRESOLVABLE rows are
    # never candidates, so they can never be demoted regardless of payloads.
    stale_by_key: dict[tuple, list[int]] = {}
    for i, row in enumerate(rows):
        if not isinstance(row, str):
            continue
        parsed = _row_key(row)
        if parsed is None:
            continue
        verdict, rule, path, detail = parsed
        if verdict != STALE:
            continue
        stats["stale_rows"] += 1
        stale_by_key.setdefault((rule, path, detail), []).append(i)

    allowed_bots_raw = _config_get(".devflow.allowed_bots", "", args.config)
    allowed_bots = {b.strip() for b in allowed_bots_raw.split(",") if b.strip()}

    payload_key_to_runkey = _collect_payload_keys(comments, allowed_bots, stats)

    demoted: list[dict] = []
    for key, run_key in payload_key_to_runkey.items():
        matches = stale_by_key.get(key, [])
        if len(matches) == 1:
            demoted.append({"row_index": matches[0], "run_key": run_key})
        elif len(matches) >= 2:
            # Ambiguity never demotes: the lint's 120-char truncated detail can let
            # two distinct claims in one boilerplate-heavy file collide, so absorbing
            # a genuine new finding into an older adjudication is the unsafe direction.
            stats["collisions"] += 1
        # 0 matches: the adjudicated claim is not in this run's rows — nothing to do.

    demoted.sort(key=lambda d: d["row_index"])
    stats["demoted"] = len(demoted)

    print(json.dumps({"demoted": demoted, "stats": stats}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
