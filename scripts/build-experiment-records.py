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
  * MISSING-SOURCE-TOLERANT — every join input is optional. An absent source yields
    null fields plus a provenance note; an unreadable store emits a stderr breadcrumb
    and skips that source. Never an abort, never a fabricated value.

Abandoned runs (a slug with no merged PR) are deliberately EXCLUDED — the record is
keyed on merged PRs — so the cost side carries a documented survivorship bias (a run
that never merged contributes no cost row). See docs/efficiency-trace.md.

Usage:
    build-experiment-records.py [--repo-root DIR] [--prs 431,430,...]
                                [--store PATH] [--retrospectives PATH]
                                [--efficiency-dir DIR] [--dry-run]

Exit codes:
    0  Store written (or dry-run, or nothing to do — a clean no-op is success).
    2  Bad arguments / unusable required inputs.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

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


def _gh_json(endpoint, paginate=False):
    """GET a gh api endpoint, parse JSON. Returns the parsed value, or None on any
    failure (non-zero exit, empty output, parse error) — best-effort, breadcrumbed."""
    cmd = [GH, "api"]
    if paginate:
        cmd.append("--paginate")
    cmd.append(endpoint)
    rc, out, err = _run(cmd)
    if rc != 0 or not out.strip():
        if rc != 0:
            _warn(f"gh api {endpoint} failed (rc={rc}): {(err or '').strip()[:160]}")
        return None
    # --paginate concatenates one JSON value per page. For array endpoints that is
    # `[...][...]`; wrap-and-split so we flatten to a single list. A single object
    # (non-paginated) parses directly.
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        pass
    # Paginated concatenation: split top-level JSON values and merge lists.
    merged = []
    ok = False
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
            _warn(f"gh api {endpoint} returned unparseable paginated output")
            return merged if ok else None
        ok = True
        if isinstance(val, list):
            merged.extend(val)
        else:
            merged.append(val)
        idx = end
    return merged if ok else None


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


# ── config fingerprint (mirror of lib/efficiency-trace.sh's compute) ─────────

def _fingerprint_from_config(cfg):
    """Compute the config fingerprint object from a parsed config dict, or None when
    neither review block exists. Byte-identical canonicalization to the producer in
    lib/efficiency-trace.sh (sorted keys, compact separators) so a record-sourced and
    a git-show-sourced fingerprint agree for the same config."""
    if not isinstance(cfg, dict):
        return None
    blocks = {k: cfg[k] for k in ("devflow_review", "devflow_review_and_fix")
              if isinstance(cfg.get(k), dict)}
    if not blocks:
        return None
    canonical = json.dumps(blocks, sort_keys=True, separators=(",", ":"))
    digest = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    rv = blocks.get("devflow_review", {})
    rf = blocks.get("devflow_review_and_fix", {})
    salient = {}
    for src, name in ((rv, "verdict_severity_threshold"),
                      (rf, "fix_severity_threshold"),
                      (rf, "max_iterations")):
        if name in src:
            salient[name] = src[name]
    return {"sha256": digest, "partial": len(blocks) < 2, "salient": salient}


# ── store I/O ────────────────────────────────────────────────────────────────

def _read_jsonl(path):
    """Read a .jsonl file into a list of dicts. Missing file → []. An unreadable file
    or a malformed line emits a breadcrumb and is skipped (never an abort)."""
    p = Path(path)
    if not p.is_file():
        return []
    entries = []
    try:
        text = p.read_text(encoding="utf-8")
    except OSError as e:
        _warn(f"could not read {path}: {e}; treating as empty")
        return []
    for i, line in enumerate(text.splitlines(), 1):
        line = line.strip()
        if not line:
            continue
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError:
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


def _collect_efficiency(eff_dir, target_slugs):
    """Every efficiency record whose `slug` is in target_slugs, as a per-run list. Each
    entry carries slug, run_id (from the filename), the per-run cost, synthesized flag,
    iteration count, telemetry_complete, and the raw config_fingerprint (for the join)."""
    d = Path(eff_dir)
    runs = []
    if not d.is_dir():
        return runs
    for f in sorted(d.glob("*.json")):
        try:
            record = json.loads(f.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            _warn(f"skipping unreadable efficiency record {f}")
            continue
        if not isinstance(record, dict):
            continue
        slug = record.get("slug")
        if slug not in target_slugs:
            continue
        # run_id = filename with the `<slug>-` prefix and `.json` suffix stripped.
        stem = f.stem
        run_id = stem[len(slug) + 1:] if stem.startswith(slug + "-") else stem
        runs.append({
            "slug": slug,
            "run_id": run_id,
            "source": record.get("source"),
            "iterations": record.get("iterations"),
            "synthesized": bool(record.get("synthesized")),
            "cost": _run_cost(record),
            "telemetry_complete": _telemetry_complete(record),
            "config_fingerprint": record.get("config_fingerprint"),
        })
    return runs


# ── review verdict + Important count ─────────────────────────────────────────

def _parse_verdict(body):
    m = VERDICT_LINE_RE.search(body or "")
    if not m:
        return None
    raw = m.group(1).strip()
    # Drop a trailing "(summary)" the contract allows: "APPROVE with notes (…)".
    raw = re.split(r"\s*\(", raw, 1)[0].strip()
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
    commit_id via the "Reviewed HEAD:" line."""
    verdict = None
    verdict_source = "absent"
    review_commit = None

    reviews = _gh_json(f"repos/{repo}/pulls/{pr}/reviews", paginate=True) if repo else None
    comments = _gh_json(f"repos/{repo}/issues/{pr}/comments", paginate=True) if repo else None
    progress = [c for c in (comments or [])
                if PROGRESS_MARKER in ((c or {}).get("body") or "")]

    if reviews:
        completed = [r for r in reviews
                     if (r or {}).get("state") not in (None, "PENDING")
                     and "## Verdict:" in ((r or {}).get("body") or "")]
        completed.sort(key=lambda r: r.get("submitted_at") or "")
        if completed:
            r0 = completed[0]
            verdict = _parse_verdict(r0.get("body"))
            verdict_source = "pr-review"
            review_commit = r0.get("commit_id")

    fallback_comment = None
    if verdict is None and progress:
        vp = [c for c in progress if "## Verdict:" in (c.get("body") or "")]
        vp.sort(key=lambda c: c.get("created_at") or "")
        if vp:
            fallback_comment = vp[-1]
            verdict = _parse_verdict(fallback_comment.get("body"))
            verdict_source = "progress-comment"
            review_commit = _reviewed_head(fallback_comment.get("body"))

    # Important count — join the progress comment to the review's commit_id.
    important = None
    important_source = "absent"
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
    output[summary] `permission_denials_count:` line. Historical fallback: check-run
    annotations (positive-count-only — a historical zero is indistinguishable from
    unavailable, stated in provenance). Value is carried VERBATIM (`unavailable` stays
    `unavailable`); no path coerces an unestablished count to 0."""
    if not repo:
        return None, "absent"
    for sha in shas:
        if not sha:
            continue
        crs = _gh_json(f"repos/{repo}/commits/{sha}/check-runs")
        runs = (crs or {}).get("check_runs") if isinstance(crs, dict) else None
        dr = [c for c in (runs or []) if (c or {}).get("name") == "Devflow Review"]
        for c in dr:
            summary = ((c.get("output") or {}).get("summary")) or ""
            m = DENIAL_SUMMARY_RE.search(summary)
            if m:
                return m.group(1), "check-run-summary"
        for c in dr:
            ann = _gh_json(f"repos/{repo}/check-runs/{c.get('id')}/annotations")
            for a in (ann or []):
                m = DENIAL_ANNOTATION_RE.search((a or {}).get("message", "") or "")
                if m:
                    return (m.group(1),
                            "check-run-annotation (positive-only bias: a historical "
                            "zero is indistinguishable from unavailable)")
    return None, "absent"


# ── config fingerprint resolution ────────────────────────────────────────────

def _resolve_fingerprint(repo_root, eff_runs, merge_sha):
    """Prefer the fingerprint the efficiency record already stamped; else recompute
    from `git show <merge_sha>:.devflow/config.json` (records predating the field).
    Returns (fingerprint_or_None, source)."""
    for run in eff_runs:
        fp = run.get("config_fingerprint")
        if fp:
            return fp, "efficiency-record"
    if merge_sha:
        text = _git_show(repo_root, f"{merge_sha}:.devflow/config.json")
        if text is not None:
            try:
                fp = _fingerprint_from_config(json.loads(text))
            except json.JSONDecodeError:
                fp = None
            if fp:
                return fp, "merge-commit-config"
    return None, "absent"


# ── gh PR-metadata fallback (no retrospective entry) ─────────────────────────

def _gh_pr_meta(repo, pr):
    """Best-effort metadata for a PR with no retrospective entry. None on failure."""
    rc, out, _ = _run([GH, "pr", "view", str(pr), "--json",
                       "mergedAt,mergeCommit,headRefName,closingIssuesReferences,state"])
    if rc != 0 or not out.strip():
        return None
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return None


# ── per-PR assembly ──────────────────────────────────────────────────────────

def build_record(repo, repo_root, eff_dir, pr, retro_entry):
    provenance = {"notes": []}

    if retro_entry:
        merged_at = retro_entry.get("merged_at")
        merge_sha = retro_entry.get("merge_commit_sha")
        head_sha = retro_entry.get("head_sha")
        branch = retro_entry.get("branch")
        issue = retro_entry.get("issue")
        provenance["retrospective"] = "found"
    else:
        provenance["retrospective"] = "absent"
        provenance["notes"].append("no retrospective entry; PR metadata via gh fallback")
        meta = _gh_pr_meta(repo, pr) if repo else None
        merged_at = (meta or {}).get("mergedAt")
        merge_sha = ((meta or {}).get("mergeCommit") or {}).get("oid")
        head_sha = None
        branch = (meta or {}).get("headRefName")
        refs = (meta or {}).get("closingIssuesReferences") or []
        issue = refs[0].get("number") if refs and isinstance(refs[0], dict) else None

    # Efficiency runs — both slug families.
    target_slugs = {f"pr-{pr}"} | _slug_variants(branch)
    eff_runs = _collect_efficiency(eff_dir, target_slugs)
    provenance["efficiency"] = "found" if eff_runs else "absent"
    if not eff_runs:
        provenance["notes"].append("no efficiency record matched (outcome-only row)")

    fingerprint, fp_source = _resolve_fingerprint(repo_root, eff_runs, merge_sha)
    provenance["config_fingerprint"] = fp_source

    verdict, verdict_source, important, important_source, _ = \
        _resolve_verdict_and_important(repo, pr)
    provenance["verdict"] = verdict_source
    provenance["important_finding_count"] = important_source

    denials, denials_source = _resolve_denials(repo, [head_sha, merge_sha])
    provenance["permission_denials_count"] = denials_source

    return {
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

    # Existing store, keyed by PR (idempotent replace).
    store = {}
    for entry in _read_jsonl(store_path):
        pr = _pr_of(entry)
        if pr is not None:
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
    candidates = list(window)
    for pr in retro_order:
        if pr not in store or pr in window:
            if pr not in candidates:
                candidates.append(pr)

    if not candidates:
        _warn("no candidate PRs to process (scan window empty, store up to date) — no-op")
        # Still rewrite nothing; a no-op is success.
        return 0

    for pr in candidates:
        try:
            store[pr] = build_record(repo, repo_root, eff_dir, pr, retro.get(pr))
        except Exception as e:  # noqa: BLE001 — one bad PR must never abort the batch
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
                     f"{store_path}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
