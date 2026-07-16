#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Export an immutable Actions run/job census snapshot (issue #527, Wave 1).

This is the SOLE networked step in the verification-launch baseline pipeline and
is explicit-invocation-only: it is never run by the offline analyzer. It queries
the GitHub Actions API (via gh) for ONE declared repository, workflow set, and
closed time window, paginates, and writes an immutable metadata-only snapshot
(run/job identity, run ID + attempt, created/started/completed timestamps,
conclusion). The offline analyzer (verification_baseline.py) reads this snapshot
without any network access.

The snapshot records its hash, query time, and pagination completeness. It
contains ONLY Actions metadata — no transcript text, no tool input, no stdout/
stderr, no secrets, no source paths. An absent or incomplete snapshot makes the
analyzer's cloud coverage ``unavailable``, never zero.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SNAPSHOT_SCHEMA = 1
FILE_MODE = 0o600
DIR_MODE = 0o700


def _now_iso() -> str:
    return datetime.now(tz=timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def build_snapshot(repo: str, workflow_set: list[str], closed_after: str, closed_before: str,
                   runs: list[dict[str, Any]], jobs_by_run: dict[int, list[dict[str, Any]]],
                   query_time: str, pagination_complete: bool) -> dict[str, Any]:
    """Build the immutable census snapshot from already-fetched runs + jobs.

    Pure function (no network) — testable independently of gh. ``rows`` carries
    ONLY Actions metadata: workflow/job identity, run ID + attempt, timestamps,
    conclusion, status, html_url. No transcript text, no secrets, no source paths.
    """
    rows: list[dict[str, Any]] = []
    for run in runs:
        if not isinstance(run, dict):
            continue
        run_id = run.get("id")
        wf_path = run.get("path") or run.get("workflow_file")
        wf_name = run.get("name")
        attempt = run.get("run_attempt", 1)
        for job in jobs_by_run.get(run_id, []):
            if not isinstance(job, dict):
                continue
            rows.append({
                "workflow_file": wf_path,
                "workflow_name": wf_name,
                "job": job.get("name"),
                "run_id": run_id,
                "run_attempt": attempt,
                "created_at": run.get("created_at"),
                "started_at": job.get("started_at") or run.get("run_started_at"),
                "completed_at": job.get("completed_at"),
                "conclusion": job.get("conclusion") or run.get("conclusion"),
                "status": job.get("status") or run.get("status"),
                "html_url": job.get("html_url") or run.get("html_url"),
            })
    rows_payload = json.dumps(rows, sort_keys=True, separators=(",", ":")).encode("utf-8")
    snapshot_hash = hashlib.sha256(rows_payload).hexdigest()
    return {
        "schema_version": SNAPSHOT_SCHEMA,
        "snapshot_hash": snapshot_hash,
        "query_time": query_time,
        "pagination_complete": bool(pagination_complete),
        "repository": repo,
        "workflow_set": workflow_set,
        "closed_window": {"created_after": closed_after, "created_before": closed_before},
        "row_count": len(rows),
        "rows": rows,
    }


def _gh_json(gh: str, args: list[str]) -> Any:
    """Run gh with --jq '.' (JSON) and parse. Returns None on failure.

    Surfaces gh's stderr on a non-zero exit so the sole networked step is
    diagnosable: a 401, a rate limit, and a legitimately empty window no longer
    all read as an indistinguishable "pagination_complete=False"."""
    cmd = [gh, *args, "--jq", "."]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0 or not proc.stdout.strip():
        stderr = (proc.stderr or "").strip()
        if stderr:
            print(f"devflow census-export: gh failed (rc={proc.returncode}): {stderr[:300]}", file=sys.stderr)
        return None
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        # A gh success with malformed stdout degrades to None (→ pagination
        # incomplete). Surface it like the rc-nonzero branch above so it isn't a
        # silent failure indistinguishable from an empty window (issue #527 review).
        print("devflow census-export: gh returned malformed JSON stdout; treating as a failed fetch", file=sys.stderr)
        return None


def fetch_runs_and_jobs(gh: str, repo: str, workflows: list[str], created_after: str, created_before: str) -> "tuple[list[dict], dict[int, list[dict]], bool]":
    """Paginate Actions runs + their jobs via gh. Returns (runs, jobs_by_run, pagination_complete).

    Pagination is complete only if every page was fetched and the final page was
    a partial page (< per_page); a transport failure on any page marks it
    incomplete (the analyzer then reads cloud coverage as unavailable, never zero).
    """
    runs: list[dict] = []
    page = 1
    per_page = 100
    pagination_complete = True
    while True:
        # --method GET is REQUIRED: `gh api` switches to POST as soon as any
        # parameter is added, and POSTing to the GET-only runs endpoint fails
        # (returns None here) — so without it the exporter can never fetch a run.
        # The closed window is ONE `created` range param (`after..before`): a
        # separate `created<=` field is split by gh on the first `=` into the
        # unknown key `created<`, which GitHub ignores, silently dropping the
        # upper bound (issue #527 review findings). `--raw-field` forces the
        # value to a string, avoiding `--field`'s magic type coercion.
        doc = _gh_json(gh, ["api", "--method", "GET", f"repos/{repo}/actions/runs",
                            f"--field=per_page={per_page}", f"--field=page={page}",
                            f"--raw-field=created={created_after}..{created_before}"])
        if doc is None or not isinstance(doc, dict):
            pagination_complete = False
            break
        page_runs = doc.get("workflow_runs")
        if not isinstance(page_runs, list):
            pagination_complete = False
            break
        # Filter to the declared workflow set by workflow path/name.
        filtered = [r for r in page_runs if isinstance(r, dict) and _matches_workflow_set(r, workflows)] if workflows else list(page_runs)
        runs.extend(filtered)
        if len(page_runs) < per_page:
            break
        page += 1
        if page > 200:  # hard cap; a real closed window is bounded
            pagination_complete = False
            break
    jobs_by_run: dict[int, list[dict]] = {}
    for run in runs:
        run_id = run.get("id")
        if run_id is None:
            continue
        # Page the jobs endpoint the SAME way as runs — a run with a large matrix
        # can have >100 jobs, and a single per_page=100 fetch silently truncated
        # the cloud denominator while still reporting pagination_complete=True
        # (issue #527 review finding). A transport failure or a page that under-
        # counts vs total_count marks the census incomplete (the analyzer then
        # reads cloud coverage as unavailable, never a partial-presented-as-whole).
        collected: list[dict] = []
        jpage = 1
        truncated = False
        while True:
            jdoc = _gh_json(gh, ["api", "--method", "GET", f"repos/{repo}/actions/runs/{run_id}/jobs",
                                 f"--field=per_page={per_page}", f"--field=page={jpage}"])
            if jdoc is None or not isinstance(jdoc, dict) or not isinstance(jdoc.get("jobs"), list):
                truncated = True
                break
            page_jobs = jdoc["jobs"]
            collected.extend(page_jobs)
            total = jdoc.get("total_count")
            if len(page_jobs) < per_page:
                # Last (partial) page. If the API told us a total and we have
                # fewer, something was dropped — mark incomplete rather than trust
                # a short census.
                if isinstance(total, int) and len(collected) < total:
                    truncated = True
                break
            jpage += 1
            if jpage > 200:  # hard cap; a real run's job count is bounded
                truncated = True
                break
        if truncated:
            pagination_complete = False
        jobs_by_run[run_id] = collected
    return runs, jobs_by_run, pagination_complete


def _matches_workflow_set(run: dict, workflows: list[str]) -> bool:
    path = run.get("path") or ""
    name = run.get("name") or ""
    return any(wf in (path, name) for wf in workflows)


def _atomic_write(path: Path, data: bytes) -> None:
    parent = path.parent
    parent.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(parent, DIR_MODE)
    except OSError:
        pass
    import tempfile
    fd, tmp = tempfile.mkstemp(dir=str(parent), prefix=".census-")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, FILE_MODE)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp) and tmp != str(path):
            try:
                os.unlink(tmp)
            except OSError:
                pass


def main(argv: "list[str] | None" = None) -> int:
    parser = argparse.ArgumentParser(description="Export an immutable Actions run/job census snapshot (issue #527).")
    parser.add_argument("--repo", required=True, help="owner/repo to census")
    parser.add_argument("--workflows", default="", help="comma-separated workflow file paths/names to include (empty = all)")
    parser.add_argument("--created-after", required=True, help="ISO-8601; runs created at or after")
    parser.add_argument("--created-before", required=True, help="ISO-8601; runs created at or before (inclusive upper bound of the closed window)")
    parser.add_argument("--out", required=True, help="output snapshot path")
    parser.add_argument("--gh", default=os.environ.get("DEVFLOW_GH") or "gh")
    args = parser.parse_args(argv)

    workflows = [w.strip() for w in args.workflows.split(",") if w.strip()] if args.workflows else []
    query_time = _now_iso()
    runs, jobs_by_run, pagination_complete = fetch_runs_and_jobs(args.gh, args.repo, workflows, args.created_after, args.created_before)
    snapshot = build_snapshot(args.repo, workflows, args.created_after, args.created_before, runs, jobs_by_run, query_time, pagination_complete)
    payload = json.dumps(snapshot, indent=2, sort_keys=True).encode("utf-8")
    out_path = Path(args.out)
    _atomic_write(out_path, payload)
    print(f"devflow census-export: wrote {out_path} (rows={snapshot['row_count']} pagination_complete={pagination_complete} hash={snapshot['snapshot_hash'][:12]})")
    if not pagination_complete:
        # Loud degradation: the snapshot is INCOMPLETE (a transport failure or a
        # truncated page). The analyzer reads this as cloud coverage 'unavailable'
        # (never a partial-as-complete census), so exit 0 is intentional — the
        # degraded snapshot is still usable — but the operator must see it (issue
        # #527 review). The in-file `pagination_complete: false` is the durable record.
        print("devflow census-export: WARNING — pagination incomplete; the snapshot is partial and the analyzer will read cloud coverage as unavailable", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
