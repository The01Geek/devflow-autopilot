#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Assemble the unified experiment record — join per-run cost to review outcome.

Writes one JSON line per merged PR into `.devflow/learnings/experiment-records.jsonl`
(tracked). Each line joins, for one PR:

  * ALL matching per-run efficiency records (both slug families — `pr-<N>` directly
    and the branch slug resolved from the retrospective entry's `branch` field, with
    a `gh` lookup fallback) as a per-run list with per-run cost — never newest-wins,
    since discarding earlier runs' cost corrupts a cost-vs-outcome experiment;
  * the retrospective entry for the PR (from `.devflow/learnings/retrospectives.jsonl`);
  * the first-completed independent-review VERDICT, selected by artifact shape — the
    first completed PR review whose body matches the `## Verdict:` contract regardless
    of bot identity, with a progress-comment fallback and a null-verdict arm (#403);
  * the Important-finding count parsed from the run-keyed `devflow:review-progress`
    comment, joined via `review.commit_id` == the comment's "Reviewed HEAD:" line —
    the engine's own join (see skills/review/SKILL.md, cited as the normative source);
  * the permission-denial count (from the `Devflow Review` check-run output[summary]
    for PRs after issue #431, with a best-effort check-run-annotation fallback for
    historical PRs) carried VERBATIM — `unavailable` stays `unavailable`, and no path
    coerces an unestablished count to 0;
  * the config fingerprint (from the efficiency record's `config_fingerprint`, else a
    `git show <merge_sha>:.devflow/config.json` fallback, with the source marked).

Design invariants:
  * IDEMPOTENT — re-running replaces a PR's line, keyed by PR number (one line per PR).
  * INCREMENTAL — processes the scan window (`--prs`) plus any merged PR present in the
    retrospective store but absent from the experiment store; never a full-history
    sweep of already-stored PRs per invocation.
  * MISSING-SOURCE-TOLERANT, BUT ONLY FOR THE INPUTS — every join INPUT is optional: an
    absent source yields null fields plus a provenance tag, and an unreadable input store
    emits a stderr breadcrumb and simply does not join. Never a fabricated value.
    The DESTINATION store is the deliberate exception: it is read STRICTLY, because this
    script REWRITES it rather than appending, so tolerating a corrupt line there would
    silently delete every record it could not parse (see `_read_jsonl`'s `strict` arm).
    A corrupt destination store, a PR whose merge state could not be established, and a
    failed assembly all exit 2 — see Exit codes below. "Tolerant" is a claim about the
    inputs, never about the run's exit status.

Abandoned runs (a slug with no merged PR) are deliberately EXCLUDED — the record is
keyed on merged PRs — so the cost side carries a documented survivorship bias (a run
that never merged contributes no cost row). See docs/efficiency-trace.md.

Usage:
    build-experiment-records.py [--repo-root DIR] [--prs 431,430,...]
                                [--store PATH] [--retrospectives PATH]
                                [--efficiency-dir DIR] [--dry-run]

Exit codes:
    0  Store written (or dry-run, or nothing to do — a clean no-op is success).
    2  The run did not fully succeed and the caller must surface it: bad arguments, an
       unreadable existing store (refused rather than rewritten from a partial read — a
       rewrite would DELETE what it could not parse), an unwritable store, or one or more
       candidate PRs that failed to assemble. The exit code is the caller's only failure
       channel (retrospective-weekly Step 6.5 turns it into a blocker note), so a PARTIAL
       failure exits 2 too, not just a total one.
"""

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

# Import the shared config-fingerprint canonicalization (issue #431) — the ONE
# implementation the producer (lib/efficiency-trace.sh) and this reader both use,
# so a record-sourced and a git-show-sourced fingerprint are byte-identical.
# Insert this script's own dir so the sibling module resolves regardless of cwd.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from config_fingerprint import fingerprint_from_config  # noqa: E402

# The gh binary — DEVFLOW_GH (the documented override the shell helpers resolve via
# lib/resolve-gh.sh) wins when set and non-empty, else `gh`. No probe (the test-stub
# contract), matching workpad.py / file-deferrals.py.
GH = os.environ.get("DEVFLOW_GH") or "gh"
# The git binary — same DEVFLOW-override / no-probe pattern, native subprocess (never
# a .sh exec) so Windows works (issue #295).
GIT = os.environ.get("DEVFLOW_GIT") or "git"

STORE_SCHEMA_VERSION = 1
PROGRESS_MARKER = "<!-- devflow:review-progress"
VERDICT_LINE_RE = re.compile(r"^\s*##\s*Verdict:\s*(.+?)\s*$", re.MULTILINE)
REVIEWED_HEAD_RE = re.compile(r"^\*\*Reviewed HEAD:\*\*\s*(\S+)", re.MULTILINE)
# The Important-findings sub-heading in the engine's `## Code Review Findings`
# section (skills/review/SKILL.md renders "### 🟠 Important / Major"). Match on the
# stable "Important" word so a future icon/label tweak degrades gracefully.
FINDINGS_SECTION_RE = re.compile(r"^##\s+Code Review Findings\s*$", re.MULTILINE)
IMPORTANT_HEADING_RE = re.compile(r"^###\s+.*Important", re.MULTILINE)
NUMBERED_ITEM_RE = re.compile(r"^\s*\d+\.\s")
DENIAL_SUMMARY_RE = re.compile(r"permission_denials_count:\s*(\S+)")
DENIAL_ANNOTATION_RE = re.compile(r"recorded\s+(\d+)\s+permission denial")

# ── provenance vocabulary + coherence invariant ──────────────────────────────
# Every provenance key, mapped to the record field(s) it governs. A provenance entry is
# a claim about HOW a field was established, so the coherence check below needs to know
# which values each claim covers — including the one-to-MANY case: `retrospective` is the
# provenance of the PR-metadata join, and that single join produces four fields.
_PROVENANCED_FIELDS = {
    "verdict": ("verdict",),
    "important_finding_count": ("important_finding_count",),
    "permission_denials_count": ("permission_denials_count",),
    "config_fingerprint": ("config_fingerprint",),
    "retrospective": ("merged_at", "merge_commit_sha", "branch", "issue"),
}
# UNESTABLISHED provenance: the join could not be measured at all. `fetch-failed` = the
# call ran and did not yield a usable answer; `no-repo` = nothing was queryable (repo
# unresolvable); `no-sha` = the metadata that supplies the query key was itself
# unestablished, so this join is unestablished by cascade. NONE of these is `absent`, which
# asserts the far stronger claim "we looked and it genuinely was not there" (issue #431
# review, convergence shadow).
PROVENANCE_UNESTABLISHED = ("fetch-failed", "no-repo", "no-sha")

# The CLOSED provenance vocabulary — every tag any resolver may emit. This exists because
# the coherence guard below tests MEMBERSHIP in PROVENANCE_UNESTABLISHED and would happily
# `continue` past any value it does not recognize: a typo (`fetch_failed`) or a future
# unestablished-meaning tag whose author forgets to add it to the tuple would silently
# bypass the check and let the record publish a non-null measurement under an unestablished
# source — the exact fabrication the guard is written to make impossible. That is this
# repo's own "a guard whose comparand its producer does not guarantee fails open exactly
# where it claims to fail closed" pattern, turned on the guard itself. Asserting every
# emitted tag is in this set is what makes the vocabulary closed in the CODE rather than
# only in the comments (issue #431 convergence shadow).
PROVENANCE_SOURCES = PROVENANCE_UNESTABLISHED + (
    "found", "absent", "unparseable",
    "pr-review", "progress-comment", "progress-comment-degraded",
    "check-run-summary", "check-run-annotation",
    "efficiency-record", "merge-commit-config", "mixed-across-runs",
)


def _assert_provenance_coherent(record):
    """The record's own type-level invariant, enforced at construction rather than left
    to reviewer vigilance: every field governed by an UNESTABLISHED provenance MUST be
    null. The whole point of the unestablished vocabulary is that no analysis can read a
    real measurement out of a join that never happened, so a non-null value labeled
    `fetch-failed`/`no-repo`/`no-sha` is incoherent by construction.

    The governed set is `_PROVENANCED_FIELDS` — which deliberately includes the
    `retrospective` join's four metadata fields, not only the four scalar joins. Those
    four happen to be null today on every unestablished path, so the invariant holds by
    accident there; checking them makes it hold by CONSTRUCTION, so a future edit that
    back-fills e.g. `branch` from a slug heuristic while the metadata fetch failed cannot
    quietly publish a value under an unestablished provenance (#431 review).

    Raises AssertionError — a build-time bug in this script, never a data condition
    (every degradation path yields null) — so such an edit fails at the desk instead of
    silently publishing a fabricated measurement."""
    prov = record.get("provenance") or {}
    for prov_key, source in prov.items():
        if prov_key == "notes":
            continue
        # Close the vocabulary IN CODE. Without this, an unrecognized tag (a typo, or a
        # new unestablished-meaning tag not added to PROVENANCE_UNESTABLISHED) would slip
        # past the membership test below and let the record publish a value under a source
        # that means "never measured" — the guard failing open exactly where it claims to
        # fail closed (issue #431 convergence shadow).
        if source not in PROVENANCE_SOURCES:
            raise AssertionError(
                f"provenance incoherent: {prov_key} carries the unrecognized source "
                f"{source!r}. Every tag must be in the closed PROVENANCE_SOURCES "
                f"vocabulary — an unrecognized tag would bypass the unestablished check "
                f"below and could publish a fabricated measurement")
    for prov_key, fields in _PROVENANCED_FIELDS.items():
        source = prov.get(prov_key)
        if source not in PROVENANCE_UNESTABLISHED:
            continue
        for field in fields:
            if record.get(field) is not None:
                raise AssertionError(
                    f"provenance incoherent: {field}={record.get(field)!r} is non-null "
                    f"but its source ({prov_key}) is {source!r} (unestablished) — an "
                    f"unqueryable join must never publish a value")


def _warn(msg):
    sys.stderr.write(f"build-experiment-records.py: {msg}\n")


# ── subprocess wrappers (best-effort) ────────────────────────────────────────

def _run(cmd):
    """Run cmd; return (rc, stdout, stderr). Never raises — an OSError (gh/git
    absent, non-executable shim) is folded into a non-zero rc so every caller
    degrades uniformly to its null/absent arm."""
    try:
        r = subprocess.run(
            cmd, check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            encoding="utf-8",
        )
        return r.returncode, r.stdout, r.stderr
    except OSError as e:
        return 127, "", f"{type(e).__name__}: {e}"


def _gh_json_ex(endpoint, paginate=False):
    """GET a gh api endpoint and parse it, returning (value, ok). `ok` is False whenever
    the call did not yield a USABLE ANSWER — the "could not establish" case — and True
    only when it did.

    Two ways to fail to establish, and both must set ok=False (issue #431 review):
      * the gh call itself failed (non-zero rc: transport/auth/rate-limit/absent binary);
      * the call exited 0 but its body is NON-EMPTY and unparseable (a truncated
        response, an HTML proxy error page served with rc 0, a `gh` whose --paginate
        output shape changed). Reading that as ok=True laundered it into the caller's
        `absent` arm — the strong claim "we looked and it genuinely was not there" —
        which is precisely the conflation the no-repo/no-sha/fetch-failed vocabulary
        exists to prevent, and which `_assert_provenance_coherent` cannot catch because
        the value is null while the provenance claims a successful measurement.

    An EMPTY body with rc 0 stays ok=True: that is a real answer (the artifact is
    genuinely absent), not a failure to establish one."""
    cmd = [GH, "api"]
    if paginate:
        cmd.append("--paginate")
    cmd.append(endpoint)
    rc, out, err = _run(cmd)
    if rc != 0:
        _warn(f"gh api {endpoint} failed (rc={rc}): {(err or '').strip()[:160]}")
        return None, False
    if not out.strip():
        return None, True
    # --paginate concatenates one JSON value per page. For array endpoints that is
    # `[...][...]`; wrap-and-split so we flatten to a single list. A single object
    # (non-paginated) parses directly.
    try:
        return json.loads(out), True
    except json.JSONDecodeError:
        pass
    # Paginated concatenation: split top-level JSON values and merge lists.
    merged = []
    parsed_any = False
    dec = json.JSONDecoder()
    idx, n = 0, len(out)
    while idx < n:
        while idx < n and out[idx].isspace():
            idx += 1
        if idx >= n:
            break
        try:
            val, end = dec.raw_decode(out, idx)
        except json.JSONDecodeError:
            # rc was 0 but the body does not parse. NOT ok: we did not establish an
            # answer (see the docstring). Return whatever pages did parse alongside
            # ok=False so the caller degrades to an unestablished provenance rather
            # than asserting a measured absence.
            _warn(f"gh api {endpoint} returned unparseable output (rc=0) — treating as "
                  "unestablished, not as a genuine absence")
            return (merged if parsed_any else None), False
        parsed_any = True
        if isinstance(val, list):
            merged.extend(val)
        else:
            merged.append(val)
        idx = end
    return (merged if parsed_any else None), True


def _git_show(repo_root, spec):
    """`git show <spec>` (e.g. '<sha>:.devflow/config.json') at repo_root. Returns
    the file text, or None on any failure (missing ref/path, git absent)."""
    rc, out, err = _run([GIT, "-C", str(repo_root), "show", spec])
    if rc != 0:
        _warn(f"git show {spec} failed (rc={rc}): {(err or '').strip()[:120]}")
        return None
    return out


def _resolve_repo():
    """owner/repo for the gh api path. GITHUB_REPOSITORY wins (set in Actions and by
    tests); else `gh repo view`. None when unresolvable — the gh joins then degrade."""
    env = os.environ.get("GITHUB_REPOSITORY", "").strip()
    if env:
        return env
    rc, out, _ = _run([GH, "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"])
    if rc == 0 and out.strip():
        return out.strip()
    return None


# ── store I/O ────────────────────────────────────────────────────────────────

class StoreReadError(Exception):
    """The DESTINATION store could not be read in full. Fatal by design — see
    `_read_jsonl`'s `strict` arm."""


class UnestablishedPRError(Exception):
    """This PR's merge state could not be ESTABLISHED (the gh metadata call failed, or
    the repo was unresolvable), so the run can neither publish it nor honestly exclude
    it. Distinct from a PR observed to be unmerged, which is a clean exclusion: this one
    must reach the caller's failure channel, or a gh outage would silently drop PRs that
    no later incremental pass re-selects (they never enter the store, and only stored or
    retrospective-listed PRs become candidates). Unknown is not zero, in the flow-control
    dimension (issue #431 fix-delta gate)."""


def _read_jsonl(path, strict=False):
    """Read a .jsonl file into a list of dicts. Missing file → [].

    Two modes, and the distinction is load-bearing:

    * `strict=False` (the default, for the INPUT sources — the retrospective store and
      the efficiency records): an unreadable file or a malformed line emits a breadcrumb
      and is skipped. Missing-source tolerance is correct for an input — a source we
      cannot read simply does not join, and the record says so in its provenance.

    * `strict=True` (for the DESTINATION store): an unreadable file or a malformed line
      raises `StoreReadError`. Tolerance here would be DESTRUCTIVE, not merely lossy:
      `main()` does not append to the store, it REWRITES it from what this read
      returned, and `lib/open-state-pr.sh` then commits the result. So a transient
      `OSError` (EIO, a permissions blip, a half-synced worktree) or one corrupt line
      left by a killed prior run would silently DELETE every historical record the read
      could not account for — and ship the truncation in the state PR. A destination you
      are about to overwrite is not a degradable input: fail closed and let the operator
      look (issue #431 review)."""
    p = Path(path)
    if not p.is_file():
        return []
    entries = []
    try:
        text = p.read_text(encoding="utf-8")
    except OSError as e:
        if strict:
            raise StoreReadError(f"could not read {path}: {e}") from e
        _warn(f"could not read {path}: {e}; treating as empty")
        return []
    for i, line in enumerate(text.splitlines(), 1):
        line = line.strip()
        if not line:
            continue
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError as e:
            if strict:
                raise StoreReadError(f"{path}:{i}: malformed JSON line: {e}") from e
            _warn(f"{path}:{i}: malformed JSON line skipped")
    return entries


# ── cost / telemetry derivation ──────────────────────────────────────────────

_COST_KEYS = ("tokens", "calls", "wall_clock_s")


def _accumulate_cost(node, acc):
    """Recursively sum numeric leaf values named tokens/calls/wall_clock_s. Returns
    True if any numeric telemetry value was seen."""
    seen = False
    if isinstance(node, dict):
        for k, v in node.items():
            if k in _COST_KEYS and isinstance(v, (int, float)) and not isinstance(v, bool):
                acc[k] = acc.get(k, 0) + v
                seen = True
            elif isinstance(v, (dict, list)):
                seen = _accumulate_cost(v, acc) or seen
    elif isinstance(node, list):
        for item in node:
            seen = _accumulate_cost(item, acc) or seen
    return seen


def _run_cost(record):
    """Per-run cost summary summed across the record's telemetry, or None when the
    run carries no numeric token telemetry."""
    acc = {}
    seen = _accumulate_cost(record.get("telemetry") or [], acc)
    if not seen:
        return None
    return {k: acc.get(k, 0) for k in _COST_KEYS}


def _telemetry_complete(record):
    """True only when the record is not synthesized, every iteration carries non-null
    token telemetry, and no degradation breadcrumb is present. The synthesized flag is
    the degradation breadcrumb; a null-token iteration disqualifies."""
    if record.get("synthesized"):
        return False
    tel = record.get("telemetry")
    if not tel or not isinstance(tel, list):
        return False
    for entry in tel:
        phases = (entry or {}).get("phases") if isinstance(entry, dict) else None
        if not phases:
            return False
        acc = {}
        if not _accumulate_cost(phases, acc) or acc.get("tokens", 0) <= 0:
            return False
    return True


# ── efficiency-record collection (both slug families) ────────────────────────

def _slug_variants(branch):
    """Candidate branch-mode slugs. The exact producer sanitization is not exposed as a
    shared helper, so match a small variant set; a slug whose sanitization diverges from
    all of these is the documented residual (the pr-<N> family is always covered)."""
    if not branch:
        return set()
    v = {branch, branch.replace("/", "-")}
    v.add(re.sub(r"[^A-Za-z0-9._-]", "-", branch))
    return v


def _index_efficiency(eff_dir):
    """Parse the efficiency store ONCE into `slug -> [per-run entry]`, so the per-PR
    loop does dict lookups instead of re-globbing/re-parsing the whole dir for each
    candidate PR (the O(N×M) cost of a per-PR scan). Each entry carries slug, run_id
    (from the filename), per-run cost, synthesized flag, iteration count,
    telemetry_complete, and the raw config_fingerprint (for the join)."""
    index = {}
    d = Path(eff_dir)
    if not d.is_dir():
        return index
    for f in sorted(d.glob("*.json")):
        try:
            record = json.loads(f.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            _warn(f"skipping unreadable efficiency record {f}")
            continue
        if not isinstance(record, dict):
            continue
        slug = record.get("slug")
        if not isinstance(slug, str):
            continue
        # run_id = filename with the `<slug>-` prefix and `.json` suffix stripped.
        stem = f.stem
        run_id = stem[len(slug) + 1:] if stem.startswith(slug + "-") else stem
        index.setdefault(slug, []).append({
            "slug": slug,
            "run_id": run_id,
            "source": record.get("source"),
            "iterations": record.get("iterations"),
            "synthesized": bool(record.get("synthesized")),
            "cost": _run_cost(record),
            "telemetry_complete": _telemetry_complete(record),
            "config_fingerprint": record.get("config_fingerprint"),
        })
    return index


def _collect_efficiency(eff_index, target_slugs):
    """Every indexed efficiency run whose `slug` is in target_slugs, as a per-run list
    (both slug families). Sorted by (slug, run_id) for a deterministic store."""
    runs = []
    for slug in target_slugs:
        runs.extend(eff_index.get(slug, []))
    runs.sort(key=lambda r: (r["slug"], r["run_id"]))
    return runs


# ── review verdict + Important count ─────────────────────────────────────────

def _parse_verdict(body):
    m = VERDICT_LINE_RE.search(body or "")
    if not m:
        return None
    raw = m.group(1).strip()
    # Drop the stub-body suffix the engine appends on the pr-review surface when a live
    # progress comment is active (skills/review/SKILL.md Phase 4.4 stub form:
    # "## Verdict: {VERDICT} — full report in PR comment"). This is the DEFAULT cloud
    # path, so without this strip the primary outcome variable stores
    # "APPROVE — full report in PR comment" instead of "APPROVE" (issue #431 review).
    raw = re.split(r"\s*[—–-]+\s*full report in PR comment", raw, maxsplit=1)[0].strip()
    # Drop a trailing "(summary)" the contract allows: "APPROVE with notes (…)".
    raw = re.split(r"\s*\(", raw, maxsplit=1)[0].strip()
    return raw or None


def _reviewed_head(body):
    m = REVIEWED_HEAD_RE.search(body or "")
    return m.group(1).strip() if m else None


def _count_important(body):
    """Count numbered items under the "### … Important …" sub-heading of the
    `## Code Review Findings` section. Returns an int (0 when the section exists but
    has no Important group — the engine omits empty groups) or None when the comment
    carries no findings section at all (unparseable for this purpose)."""
    body = body or ""
    if not FINDINGS_SECTION_RE.search(body):
        return None
    imp = IMPORTANT_HEADING_RE.search(body)
    if not imp:
        return 0
    # Walk lines from just after the Important heading until the next "### "/"## " heading.
    tail = body[imp.end():]
    count = 0
    for line in tail.splitlines():
        if re.match(r"^###?\s", line):  # next sub-heading or section — stop
            break
        if NUMBERED_ITEM_RE.match(line):
            count += 1
    return count


def _resolve_verdict_and_important(repo, pr):
    """Returns (verdict, verdict_source, important, important_source, review_commit).

    Verdict by artifact shape: the first completed PR review (any bot) whose body
    matches `## Verdict:`; else the latest progress comment carrying `## Verdict:`;
    else null (#403). Important count from the progress comment joined to the review's
    commit_id via the "Reviewed HEAD:" line.

    With no resolvable repo NOTHING is queryable, so both sources read `no-repo` rather
    than the measured-and-found-nothing `absent` (issue #431 review, convergence shadow):
    an unqueryable join is unestablished, not an observed absence of a review."""
    if not repo:
        return None, "no-repo", None, "no-repo", None

    verdict = None
    verdict_source = "absent"
    review_commit = None

    reviews, reviews_ok = _gh_json_ex(f"repos/{repo}/pulls/{pr}/reviews", paginate=True)
    comments, comments_ok = _gh_json_ex(f"repos/{repo}/issues/{pr}/comments", paginate=True)
    # If a source could not be fetched at all (rc≠0), we could not ESTABLISH the
    # verdict — distinct from a genuinely-absent review/comment (issue #431). Default
    # the source to "fetch-failed" in that case; a parsed verdict below overrides it.
    if not reviews_ok or not comments_ok:
        verdict_source = "fetch-failed"
    progress = [c for c in (comments or [])
                if PROGRESS_MARKER in ((c or {}).get("body") or "")]

    if reviews:
        completed = [r for r in reviews
                     if (r or {}).get("state") not in (None, "PENDING")
                     and "## Verdict:" in ((r or {}).get("body") or "")]
        completed.sort(key=lambda r: r.get("submitted_at") or "")
        if completed:
            r0 = completed[0]
            parsed = _parse_verdict(r0.get("body"))
            if parsed is not None:
                # Verdict parsed cleanly — attribute it and take the review's commit_id
                # as the join key for the Important-count lookup below.
                verdict = parsed
                verdict_source = "pr-review"
                review_commit = r0.get("commit_id")
            else:
                # A completed review carried the "## Verdict:" marker but its line did
                # not parse. Do NOT claim source "pr-review" over a null value (that
                # asserts a success the code never established) and do NOT set
                # review_commit — fall through to the progress-comment fallback, giving
                # verdict a distinct "unparseable" source symmetric with `important`.
                verdict_source = "unparseable"

    fallback_comment = None
    if verdict is None and progress:
        vp = [c for c in progress if "## Verdict:" in (c.get("body") or "")]
        vp.sort(key=lambda c: c.get("created_at") or "")
        if vp:
            fallback_comment = vp[-1]
            parsed = _parse_verdict(fallback_comment.get("body"))
            # Keep review_commit (the Reviewed HEAD join key) even when the verdict
            # line does not parse, so the Important-count join can still target this
            # comment. But mirror the pr-review arm's coherence rule: do NOT claim a
            # "progress-comment" success provenance over a null verdict — a
            # marker-present-but-unparseable line gets "unparseable", symmetric with
            # the important-count field (issue #431 review, shadow pass).
            review_commit = _reviewed_head(fallback_comment.get("body"))
            if parsed is not None:
                verdict = parsed
                # When the PRIMARY source (the formal PR review — the canonical surface,
                # and the one supplying commit_id for the Important-count join) could not
                # be fetched at all, a verdict recovered from the comment is DEGRADED: it
                # may predate the final HEAD. Mark it distinctly so an analysis can tell
                # "the review was checked and had nothing, so we used the comment" from
                # "the review was unreachable, so the comment is all we have".
                #
                # A BARE tag, not prose — the same closed-vocabulary rule the denial tag
                # follows: every inhabitant of a provenance field must be matchable on
                # equality, or a consumer testing `== "progress-comment"` silently misses
                # every degraded row. The explanation belongs in provenance["notes"], and
                # the caller records it there (issue #431 fix-delta gate — this is the
                # defect the same diff fixed on the denial tag, reintroduced here).
                verdict_source = ("progress-comment-degraded" if not reviews_ok
                                  else "progress-comment")
            else:
                verdict_source = "unparseable"

    # Important count — join the progress comment to the review's commit_id. The count
    # lives in the progress (issue) comments, so if that fetch failed we could not
    # establish it: "fetch-failed", not "absent" (issue #431).
    important = None
    important_source = "fetch-failed" if not comments_ok else "absent"
    target = None
    if review_commit and progress:
        for c in progress:
            if _reviewed_head(c.get("body")) == review_commit:
                target = c
                break
    if target is None and fallback_comment is not None:
        target = fallback_comment
    if target is not None:
        cnt = _count_important(target.get("body"))
        if cnt is None:
            important_source = "unparseable"
        else:
            important = cnt
            important_source = "progress-comment"
    return verdict, verdict_source, important, important_source, review_commit


# ── permission-denial count (verbatim) ───────────────────────────────────────

def _resolve_denials(repo, shas):
    """Returns (value_verbatim, source). Forward path: the `Devflow Review` check-run
    output[summary] `permission_denials_count:` line. Historical fallback: annotations
    on the `Devflow Review` check-run (positive-count-only — a historical zero is
    indistinguishable from unavailable, stated in provenance). The fallback is
    OPPORTUNISTIC: it recovers a count only if a "recorded N permission denial(s)"
    annotation is attached to the `Devflow Review` check-run itself — a `::warning::`
    emitted by surface-execution-diagnostics attaches to the Actions job check-run, not
    this one, so many historical PRs will not recover via this path (they simply read
    `absent`, never a fabricated 0). Value is carried VERBATIM (`unavailable` stays
    `unavailable`); no path coerces an unestablished count to 0.

    UNQUERYABLE ≠ ABSENT. Two preconditions make the lookup impossible rather than
    merely fruitless, and each gets its own provenance rather than the measured-and-
    found-nothing `absent` (issue #431 review, convergence shadow): an unresolvable
    repo (`no-repo` — nothing is queryable at all) and an empty sha set (`no-sha` —
    the PR metadata that would supply head/merge shas was itself unestablished, so the
    denial count is unestablished by cascade, not measured-absent)."""
    if not repo:
        return None, "no-repo"
    probeable = [s for s in shas if s]
    if not probeable:
        return None, "no-sha"
    # Track whether the check-runs fetch itself failed on any probed sha, so a
    # transport/auth failure is reported as "fetch-failed" rather than laundered into
    # "absent" — the unknown-is-not-zero provenance analogue (issue #431).
    any_fetch_failed = False
    for sha in probeable:
        # Paginate: /commits/{sha}/check-runs serves only the first 30 check-runs per
        # page, so on a commit with a large CI matrix the `Devflow Review` check can sit
        # on page 2+ and an unpaginated read silently returns (None, "absent"), defeating
        # the denial-count durability guarantee (issue #431 review). With --paginate the
        # endpoint returns one `{check_runs:[…]}` object per page (concatenated), so merge
        # the `check_runs` arrays across every page shape the wrapper can hand back.
        crs, crs_ok = _gh_json_ex(f"repos/{repo}/commits/{sha}/check-runs", paginate=True)
        if not crs_ok:
            any_fetch_failed = True
        runs = []
        if isinstance(crs, dict):
            runs = crs.get("check_runs") or []
        elif isinstance(crs, list):
            for page in crs:
                if isinstance(page, dict):
                    runs.extend(page.get("check_runs") or [])
        dr = [c for c in runs if (c or {}).get("name") == "Devflow Review"]
        for c in dr:
            summary = ((c.get("output") or {}).get("summary")) or ""
            m = DENIAL_SUMMARY_RE.search(summary)
            if m:
                return m.group(1), "check-run-summary"
        for c in dr:
            # The annotations sub-fetch must consume the `ok` signal like every other
            # call: an annotations fetch that FAILS (rc≠0) leaves the count unestablished,
            # and an earlier revision discarded `ok` here, laundering that failure into a
            # measured `absent` — the same conflation the check-runs fetch above already
            # guards (issue #431 review, convergence shadow).
            ann, ann_ok = _gh_json_ex(f"repos/{repo}/check-runs/{c.get('id')}/annotations")
            if not ann_ok:
                any_fetch_failed = True
            for a in (ann or []):
                m = DENIAL_ANNOTATION_RE.search((a or {}).get("message", "") or "")
                if m:
                    # A BARE tag, never prose. Every other inhabitant of this field is a
                    # bare tag, and the coherence checker tests membership
                    # (`source in PROVENANCE_UNESTABLISHED`), so an embedded caveat
                    # sentence would make the vocabulary a non-closed set that no
                    # consumer could match on equality. The positive-only-bias caveat
                    # this tag carries is recorded in provenance["notes"] by the caller
                    # (issue #431 review).
                    return m.group(1), "check-run-annotation"
    return None, ("fetch-failed" if any_fetch_failed else "absent")


# ── config fingerprint resolution ────────────────────────────────────────────

def _resolve_fingerprint(repo_root, eff_runs, merge_sha):
    """Prefer the fingerprint the efficiency record already stamped; else recompute
    from `git show <merge_sha>:.devflow/config.json` (records predating the field).
    Returns (fingerprint_or_None, source).

    Like `_resolve_denials`, this separates UNQUERYABLE from ABSENT (issue #431 review,
    convergence shadow): with no merge sha there is nothing to read the config out of, so
    the fingerprint is unestablished by cascade (`no-sha`) — not measured-and-missing; and
    a `git show` that FAILS is `fetch-failed`, reserving `absent` for the case where the
    config was actually read and simply yielded no fingerprint.

    ACROSS RUNS the fingerprint is published only when every fingerprint-bearing run
    AGREES. This field is the experiment's attribution key — it says which config variant
    produced this PR's outcome — so first-wins would silently stamp a PR whose runs
    straddle a config change with the OLDER variant, misattributing its outcome in
    exactly the config-vs-outcome comparison the store exists to support. On disagreement
    the record-level value is null with source `mixed-across-runs`; nothing is lost,
    because the per-run fingerprints remain in `efficiency_runs[]`. This is the same
    refusal-to-collapse that keeps per-run COST a list rather than newest-wins (#431
    review)."""
    fps = [r.get("config_fingerprint") for r in eff_runs if r.get("config_fingerprint")]
    if fps:
        # Compare on `sha256` — the IDENTITY — not on the whole {sha256, partial, salient}
        # envelope. `salient` is a derived projection of SALIENT_KEYS, an explicitly
        # growable tuple: the moment a fourth key is added, two runs of the same PR against
        # an UNCHANGED config (one stamped before the change, one after) carry the same
        # sha256 but different `salient`, compare unequal, and collapse the record to
        # `mixed-across-runs` — firing the refusal-to-collapse guard on a config change that
        # never happened and destroying the attribution axis it exists to protect (issue
        # #431 convergence shadow).
        # An UNUSABLE identity must be NON-COMPARABLE, never equal-to-itself. `dict.get`
        # returns None for an envelope with no (or a null) `sha256`, so a naive
        # `ids[0] == ids[1]` would make two such runs compare EQUAL and publish a
        # confident single-config attribution over runs that demonstrably straddled a
        # config change — a FALSE AGREEMENT, the dangerous direction, and exactly the
        # misattribution `mixed-across-runs` exists to prevent. Our own producer always
        # emits `sha256`, but `_index_efficiency` copies `config_fingerprint` raw out of
        # arbitrary JSON under .devflow/logs/efficiency/, so a legacy, hand-edited, or
        # half-written record is squarely in this file's untrusted-input class: validate
        # the comparand at the boundary rather than letting its absence resolve to a value
        # that agrees with itself (issue #431 fix-delta gate).
        ids = [fp.get("sha256") if isinstance(fp, dict) else None for fp in fps]
        if all(isinstance(i, str) and i for i in ids):
            if all(i == ids[0] for i in ids[1:]):
                return fps[0], "efficiency-record"
            # Two or more USABLE identities that genuinely disagree. This — and only this —
            # is `mixed-across-runs`: an OBSERVED config change across the PR's runs.
            return None, "mixed-across-runs"
        # At least one identity is UNUSABLE (no sha256, a null one, a non-dict envelope —
        # the legacy / hand-edited / half-written shapes `_index_efficiency` admits raw).
        # That is an UNESTABLISHED identity, NOT a measured disagreement: reporting it as
        # `mixed-across-runs` would assert the runs straddled a config change — a fabricated
        # fact, and absurd outright when there is only ONE run — collapsing unknown onto a
        # real value in the exact field this guard exists to protect. Warn (a corrupt record
        # otherwise costs a PR its attribution in silence) and fall THROUGH to the
        # merge-commit recompute, which can still establish the fingerprint honestly.
        _warn("config_fingerprint identity unusable on at least one efficiency run (no "
              "sha256) — unestablished, NOT a measured config change; trying the "
              "merge-commit config")
    if not merge_sha:
        # `unparseable` when we HAD a fingerprint but could not read its identity; `no-sha`
        # when there was nothing to read and no sha to recompute from. Both unestablished,
        # and neither is a claim about disagreement.
        return None, ("unparseable" if fps else "no-sha")
    text = _git_show(repo_root, f"{merge_sha}:.devflow/config.json")
    if text is None:
        return None, "fetch-failed"
    try:
        fp = fingerprint_from_config(json.loads(text))
    except json.JSONDecodeError:
        fp = None
    if fp:
        return fp, "merge-commit-config"
    return None, "absent"


# ── gh PR-metadata fallback (no retrospective entry) ─────────────────────────

def _gh_pr_meta(repo, pr):
    """Best-effort metadata for a PR with no retrospective entry. Returns (meta, ok):
    `ok` is False whenever the call did not yield a USABLE ANSWER — the same rule
    `_gh_json_ex` follows, and for the same reason.

    It matters MORE here than anywhere else in this module, because this is the only
    wrapper whose result feeds a FLOW-CONTROL decision rather than a provenance string:
    `build_record`'s merged-state gate reads `mergedAt` from it, so an `ok=True` over a
    body that could not be parsed makes the gate take the *observed*-not-merged arm — the
    run breadcrumbs "observed not-merged", counts a clean skip, and exits 0. A merged PR
    is then dropped from the store permanently (it never enters the store, and only stored
    or retrospective-listed PRs are re-selected as candidates), while the retrospective
    reports a clean run. A truncated response or an HTML proxy error page served with rc 0
    makes a PR UNESTABLISHED, never unmerged (issue #431 convergence shadow — reproduced
    against HEAD, so ok=False on every did-not-establish arm).

    `--repo` is passed explicitly: this is porcelain, which otherwise resolves the repo
    from the CWD's git remote, while every other call in this module is scoped to the
    RESOLVED repo. `--repo-root` deliberately decouples the data root from cwd, and
    `_resolve_repo()` prefers `$GITHUB_REPOSITORY`, so the two can disagree — and reading
    PR #N's merge state out of a different repository is exactly the shape that gate must
    never see. Matches `lib/scan.sh`, which also passes `--repo`.

    Fetches headRefOid too so the gh-fallback path has a real head sha for the
    denial-count check-run lookup (which runs on the PR head)."""
    rc, out, err = _run([GH, "pr", "view", str(pr), "--repo", repo, "--json",
                         "mergedAt,mergeCommit,headRefName,headRefOid,"
                         "closingIssuesReferences,state"])
    if rc != 0:
        _warn(f"gh pr view {pr} failed (rc={rc}): {(err or '').strip()[:160]}")
        return None, False
    if not out.strip():
        _warn(f"gh pr view {pr} returned an empty body (rc=0) — treating as "
              "unestablished, not as a genuine absence")
        return None, False
    try:
        return json.loads(out), True
    except json.JSONDecodeError:
        _warn(f"gh pr view {pr} returned unparseable output (rc=0) — treating as "
              "unestablished, not as a genuine absence")
        return None, False


# ── per-PR assembly ──────────────────────────────────────────────────────────

def build_record(repo, repo_root, eff_index, pr, retro_entry):
    """Assemble one PR's record, or return None when the PR is not an established merged
    PR (the caller skips it — see the merged-state gate below)."""
    provenance = {"notes": []}

    if retro_entry:
        merged_at = retro_entry.get("merged_at")
        merge_sha = retro_entry.get("merge_commit_sha")
        head_sha = retro_entry.get("head_sha")
        branch = retro_entry.get("branch")
        issue = retro_entry.get("issue")
        provenance["retrospective"] = "found"
    else:
        meta, meta_ok = _gh_pr_meta(repo, pr) if repo else (None, None)
        merged_at = (meta or {}).get("mergedAt")
        merge_sha = ((meta or {}).get("mergeCommit") or {}).get("oid")
        head_sha = (meta or {}).get("headRefOid")
        branch = (meta or {}).get("headRefName")
        refs = (meta or {}).get("closingIssuesReferences") or []
        issue = refs[0].get("number") if refs and isinstance(refs[0], dict) else None
        # Three arms, deliberately NOT two: `meta_ok is None` is the no-repo sentinel
        # (the fallback was never even attempted because nothing is queryable), False is
        # a call that did not yield a usable answer, True is a successful call. Folding
        # the first into `not meta_ok` would report a fetch that never ran as a fetch that
        # failed, and folding it into the else-arm would report it as a measured absence —
        # both launder an unqueryable join into a measured one (issue #431 convergence
        # shadow).
        if meta_ok is None:
            provenance["retrospective"] = "no-repo"
            provenance["notes"].append(
                "repo unresolvable; PR metadata not queryable (no gh fallback attempted)")
        elif not meta_ok:
            # The call did not establish the metadata — a non-zero exit, OR an exit-0 body
            # that was empty or unparseable (an HTML proxy error page, a truncated
            # response). Do NOT say "rc≠0" here: that is the arm this PR widened, so an
            # operator hitting the exact case it was written to fix would be sent hunting
            # for a transport error that never happened (#431 delta review).
            provenance["retrospective"] = "fetch-failed"
            provenance["notes"].append(
                "PR metadata could not be established (the gh call did not yield a usable "
                "answer); metadata unestablished")
        else:
            provenance["retrospective"] = "absent"
            provenance["notes"].append(
                "no retrospective entry; PR metadata via gh fallback")

    # Merged-state gate. The store is keyed on MERGED PRs — that is what makes the
    # abandoned-run exclusion (and its documented cost-side survivorship bias) true, and
    # what keeps every row a finished experiment. `--prs` is an operator handle that can
    # name ANY PR, so without this gate `--prs <open-pr>` would write a row with a null
    # merged_at, a still-accumulating cost list, and a verdict scraped from an in-flight
    # review — entering the store as a shipped PR and skewing the very cost-vs-outcome
    # comparison the store exists to make (issue #431 review).
    #
    # The gate applies ONLY to the gh-fallback arm, deliberately. On the retrospective
    # arm, the ENTRY'S EXISTENCE is the merge proof: `lib/scan.sh` builds that store from
    # `gh pr list --state merged`, so an entry exists only for a merged PR. Re-deriving
    # the fact from the entry's `merged_at` FIELD would be a guard over a PROXY whose
    # producer does not guarantee it — `lib/fetch-pr-context.sh` passes it as a shell
    # `--arg`, so a failed extraction yields `""` (a shape `lib/compute-patterns.jq`
    # already guards, and the retrospective SKILL's LLM-authored JSON can omit the key
    # outright). Gating on it would drop a genuinely-merged PR with real cost and verdict
    # data — permanently, since a PR absent from the store is re-selected and re-skipped
    # every week. That is the #62/#98 operand-contract class: a guard whose accepted-input
    # set is narrower than its consumer's contract (issue #431 fix-delta gate).
    if not retro_entry:
        if meta_ok:
            # The call SUCCEEDED, so `mergedAt`/`state` are a real answer. An unmerged PR
            # here is a clean, intentional exclusion — the caller counts it as a skip.
            if not merged_at:
                _warn(f"PR #{pr}: observed not-merged (state="
                      f"{(meta or {}).get('state') or 'unknown'}) — skipping; the "
                      "experiment store is keyed on merged PRs")
                return None
        else:
            # The call did NOT succeed (fetch-failed / no-repo), so the merge state is
            # UNESTABLISHED. Do not publish it (we cannot claim it merged) and do not
            # silently exclude it either (we cannot claim it did not) — raise, so it
            # reaches the caller's failure channel. See UnestablishedPRError.
            raise UnestablishedPRError(
                f"merge state unestablished (metadata provenance="
                f"{provenance['retrospective']})")

    # Efficiency runs — both slug families.
    target_slugs = {f"pr-{pr}"} | _slug_variants(branch)
    eff_runs = _collect_efficiency(eff_index, target_slugs)
    provenance["efficiency"] = "found" if eff_runs else "absent"
    if not eff_runs:
        provenance["notes"].append("no efficiency record matched (outcome-only row)")

    fingerprint, fp_source = _resolve_fingerprint(repo_root, eff_runs, merge_sha)
    provenance["config_fingerprint"] = fp_source

    verdict, verdict_source, important, important_source, _ = \
        _resolve_verdict_and_important(repo, pr)
    provenance["verdict"] = verdict_source
    provenance["important_finding_count"] = important_source
    if verdict_source == "progress-comment-degraded":
        # Bare tag above; the caveat lives here, per the closed-vocabulary rule.
        provenance["notes"].append(
            "verdict taken from the progress comment because the PR-reviews call could "
            "not be established; it may predate the final reviewed HEAD")

    denials, denials_source = _resolve_denials(repo, [head_sha, merge_sha])
    provenance["permission_denials_count"] = denials_source
    if denials_source == "check-run-annotation":
        # The tag stays a bare, matchable token; its caveat lives here (issue #431 review).
        provenance["notes"].append(
            "denial count recovered from a check-run annotation (positive-count-only "
            "bias: a historical zero is indistinguishable from unavailable)")

    record = {
        "schema_version": STORE_SCHEMA_VERSION,
        "pr": pr,
        "issue": issue,
        "branch": branch,
        "merged_at": merged_at,
        "merge_commit_sha": merge_sha,
        "efficiency_runs": eff_runs,
        "retrospective": retro_entry,
        "verdict": verdict,
        "important_finding_count": important,
        "permission_denials_count": denials,
        "config_fingerprint": fingerprint,
        "provenance": provenance,
    }
    _assert_provenance_coherent(record)
    return record


# ── driver ───────────────────────────────────────────────────────────────────

def _pr_of(entry):
    v = entry.get("pr") if isinstance(entry, dict) else None
    return v if isinstance(v, int) else None


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--repo-root", default=None,
                   help="Repo root (default: git toplevel, else cwd).")
    p.add_argument("--prs", default="",
                   help="Comma-separated scan-window PR numbers to (re)process even "
                        "if already stored. Absent-from-store PRs are always processed.")
    p.add_argument("--store", default=None,
                   help="experiment-records.jsonl path (default under repo root).")
    p.add_argument("--retrospectives", default=None,
                   help="retrospectives.jsonl path (default under repo root).")
    p.add_argument("--efficiency-dir", default=None,
                   help=".devflow/logs/efficiency dir (default under repo root).")
    p.add_argument("--dry-run", action="store_true",
                   help="Print the assembled store to stdout; do not write.")
    args = p.parse_args(argv)

    if args.repo_root:
        repo_root = Path(args.repo_root)
    else:
        rc, out, _ = _run([GIT, "rev-parse", "--show-toplevel"])
        repo_root = Path(out.strip()) if rc == 0 and out.strip() else Path.cwd()

    store_path = Path(args.store) if args.store \
        else repo_root / ".devflow/learnings/experiment-records.jsonl"
    retro_path = Path(args.retrospectives) if args.retrospectives \
        else repo_root / ".devflow/learnings/retrospectives.jsonl"
    eff_dir = Path(args.efficiency_dir) if args.efficiency_dir \
        else repo_root / ".devflow/logs/efficiency"

    repo = _resolve_repo()
    if repo is None:
        _warn("could not resolve owner/repo (GITHUB_REPOSITORY unset, gh repo view "
              "failed); review/denial joins will be absent for this run")

    # Existing store, keyed by PR (idempotent replace). Read STRICTLY: the store is the
    # DESTINATION this run rewrites wholesale, so a tolerated read error would silently
    # drop history rather than merely skip a source (see _read_jsonl's strict arm).
    store = {}
    try:
        existing = _read_jsonl(store_path, strict=True)
    except StoreReadError as e:
        _warn(f"{e}")
        _warn(f"refusing to rewrite {store_path} from a partial read — every record this "
              "read could not account for would be DELETED. Fix or remove the corrupt "
              "line and re-run; the store is left untouched.")
        return 2
    for i, entry in enumerate(existing, 1):
        pr = _pr_of(entry)
        if pr is None:
            # Same destructive shape as an unparseable line: the rewrite is keyed on
            # `pr`, so a well-formed-JSON line WITHOUT one is not merely ignored — it is
            # dropped from the output. Fail closed rather than quietly shrink the store.
            _warn(f"{store_path}:{i}: store line has no integer 'pr' key; refusing to "
                  "rewrite the store (this line would be silently DELETED)")
            return 2
        store[pr] = entry

    # Retrospective catalog of merged PRs, keyed by PR (latest wins on duplicate).
    retro = {}
    retro_order = []
    for entry in _read_jsonl(retro_path):
        pr = _pr_of(entry)
        if pr is None:
            continue
        if pr not in retro:
            retro_order.append(pr)
        retro[pr] = entry

    # Scan window: explicit --prs (always reprocessed) plus retrospective PRs absent
    # from the store. Never a full sweep of already-stored PRs.
    window = set()
    for tok in args.prs.split(","):
        tok = tok.strip()
        if tok.isdigit():
            window.add(int(tok))
    candidates = list(window)   # window PRs are always reprocessed
    for pr in retro_order:       # plus retrospective PRs not yet stored
        if pr not in store and pr not in candidates:
            candidates.append(pr)

    if not candidates:
        _warn("no candidate PRs to process (scan window empty, store up to date) — no-op")
        # Still rewrite nothing; a no-op is success.
        return 0

    # Parse the efficiency store ONCE up front (not per candidate PR).
    eff_index = _index_efficiency(eff_dir)

    assembled = 0
    failed = 0
    skipped = 0
    unestablished = 0
    for pr in candidates:
        try:
            record = build_record(repo, repo_root, eff_index, pr, retro.get(pr))
            if record is None:
                # OBSERVED not-merged — build_record already breadcrumbed why. A clean,
                # intentional exclusion, and not a failure.
                skipped += 1
                continue
            store[pr] = record
            assembled += 1
        except UnestablishedPRError as e:
            # NOT a clean exclusion: we could not establish whether this PR merged, so
            # excluding it silently would be the unknown-collapsed-onto-a-value bug in the
            # flow-control dimension. Counted separately and folded into the non-zero exit
            # below, because the exit code is the caller's ONLY failure channel and such a
            # PR is otherwise lost for good — it never enters the store, and only stored or
            # retrospective-listed PRs are ever re-selected as candidates.
            unestablished += 1
            _warn(f"PR #{pr}: {e}; skipping, but the run will NOT report success")
        except Exception as e:  # noqa: BLE001 — one bad PR must never abort the batch
            failed += 1
            _warn(f"PR #{pr}: assembly failed ({type(e).__name__}: {e}); leaving prior "
                  "store line untouched")

    # Deterministic output: one line per PR, ascending by PR number.
    lines = [json.dumps(store[pr], sort_keys=True, separators=(",", ":"))
             for pr in sorted(store)]
    output = "\n".join(lines) + ("\n" if lines else "")

    if args.dry_run:
        sys.stdout.write(output)
        return 0

    try:
        store_path.parent.mkdir(parents=True, exist_ok=True)
        tmp = store_path.with_suffix(store_path.suffix + ".tmp")
        tmp.write_text(output, encoding="utf-8")
        tmp.replace(store_path)
    except OSError as e:
        _warn(f"could not write {store_path}: {e}")
        return 2
    sys.stderr.write(f"build-experiment-records.py: wrote {len(store)} record(s) to "
                     f"{store_path} (assembled={assembled} skipped={skipped} "
                     f"unestablished={unestablished} failed={failed})\n")
    # Aggregate guard. Prior store lines are preserved above, but ANY assembly failure
    # means the store is missing records it should carry, so exit non-zero and let the
    # best-effort caller surface it.
    #
    # This fires on failed>0, not only on the all-failed case, because the caller's ONLY
    # detection channel is the exit code: retrospective-weekly Step 6.5 runs this as
    # `… || echo "failed" >&2` and turns that breadcrumb into a blocker note. An
    # all-failed-only guard left that check INERT for the dominant shape — 9 of 10 PRs
    # raising still exited 0 — so the retrospective would report a clean run while most
    # of the week's records were never assembled, and the next incremental pass would
    # silently retry-and-fail the same way (issue #431 review). A guard whose comparand
    # the producer never emits on the paths it now selects is a guard that fails open.
    if failed > 0 or unestablished > 0:
        systematic = (" — SYSTEMATIC (no candidate assembled)"
                      if assembled == 0 else "")
        _warn(f"{failed} of {len(candidates)} candidate PR(s) failed to assemble and "
              f"{unestablished} had an unestablished merge state{systematic}; their "
              "prior store lines (if any) are unchanged")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
