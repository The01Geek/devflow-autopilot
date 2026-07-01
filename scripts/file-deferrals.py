#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""DevFlow follow-up filer for review-and-fix deferrals.

The /implement skill's Phase 4.0.5 merges the run-scoped deferrals manifests
produced by /devflow:review-and-fix (at `.devflow/tmp/review/<slug>/<run-id>/deferrals.json`,
one per run) into a single slug-level aggregate, passes that aggregate as
`--manifest`, files one follow-up GitHub issue per source file, and rewrites
the aggregate with the assigned issue numbers + deterministic deferral IDs. The /devflow:review
verdict engine then matches these entries against the PR-body block to
demote already-acknowledged findings.

The helper is repo-agnostic — title/body templates contain no project names
or hardcoded paths. The `<area>` token in titles is derived from the file
path's first non-`src/`-equivalent segment (or the basename if no such
segment exists).

Usage:
    file-deferrals.py --source-issue N --pr M --manifest PATH [--dry-run]

Exit codes:
    0  At least one group of findings was filed successfully (or --dry-run).
    1  Nothing was filed (every group failed, or input was invalid).
    2  Bad arguments / unusable manifest.
"""

import argparse
import datetime
import hashlib
import json
import os
import subprocess
import sys
from collections import OrderedDict
from pathlib import Path

# The gh binary to shell out to. `DEVFLOW_GH` (the documented override the shell
# helpers resolve via lib/resolve-gh.sh) wins when set and non-empty; else `gh`.
GH = os.environ.get("DEVFLOW_GH") or "gh"

SCHEMA_VERSION = 1
ID_PREFIX = "dfr-"
ID_HEX_LEN = 6


def _force_utf8_streams():
    """Force stdout/stderr to UTF-8, idempotently and defensively. Called from
    the CLI entry path only (not at import) so importing this module for unit
    tests never mutates the importer's global streams. The em-dash/ellipsis this
    script emits (issue-body lines, the dry-run preview) would otherwise raise
    `UnicodeEncodeError` under a non-UTF-8 ambient codec (Windows' cp1252).
    Reconfigure overrides even a hostile `PYTHONIOENCODING`; the guard tolerates
    a non-`TextIOWrapper` stream (e.g. a test's `io.StringIO`)."""
    for _stream in (sys.stdout, sys.stderr):
        try:
            _stream.reconfigure(encoding="utf-8")
        except (AttributeError, ValueError):
            pass


def _run(cmd, *, stdin=None, check=True):
    # `encoding="utf-8"` pins both directions of the gh pipe (decode of output,
    # encode of stdin) so neither raises under a non-UTF-8 ambient codec. Implies
    # text mode, so `text=True` is dropped (passing both is redundant).
    return subprocess.run(
        cmd, check=check, stdin=stdin,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, encoding="utf-8",
    )


def _fail(msg, code=1):
    sys.stderr.write(f"file-deferrals.py: {msg}\n")
    sys.exit(code)


def _now_iso():
    return datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _gh_login():
    """Whoever is actually filing — for the manifest's follow_up.filed_by.

    Tries gh api user first (works for personal access tokens). Falls back
    to GITHUB_ACTOR, then "(unknown)", on ANY gh failure mode — not just the
    canonical 403 "Resource not accessible by integration" you get when
    GITHUB_TOKEN in Actions lacks user:read. That covers any non-zero gh
    exit or empty stdout (403, expired tokens, 5xx, DNS errors,
    rate-limiting) as well as any OS-level spawn failure: these all
    surface as an OSError subclass and are handled uniformly (the
    breadcrumb records only the exception class name) — e.g. gh missing
    from PATH, not executable, wrong arch, or fd/memory exhaustion.
    filed_by is informational only —
    never gate logic — so we degrade rather than fail the run, but we
    leave a stderr breadcrumb so operators can see when the primary lookup
    didn't work. (A non-OSError like UnicodeDecodeError from exotic gh
    output is out of scope by design — the `.login` field is ASCII.)
    """
    rc_info = "no-binary"
    stderr_info = ""
    try:
        r = _run([GH, "api", "user", "--jq", ".login"], check=False)
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
        rc_info = str(r.returncode)
        _err_lines = (r.stderr or "").strip().splitlines()
        stderr_info = _err_lines[0][:120] if _err_lines else ""
    except OSError as e:
        rc_info = f"spawn-error ({type(e).__name__})"
        stderr_info = f"{type(e).__name__}: {e}"[:120]
    sys.stderr.write(
        f"file-deferrals.py: gh api user unavailable "
        f"(rc={rc_info}, stderr={stderr_info!r}), falling back to GITHUB_ACTOR\n"
    )
    actor = os.environ.get("GITHUB_ACTOR", "").strip()
    if actor:
        return actor
    sys.stderr.write(
        "file-deferrals.py: GITHUB_ACTOR unset, filed_by will be '(unknown)'\n"
    )
    return "(unknown)"


def _derive_area(file_path: str) -> str:
    """First non-`src/`-equivalent segment, or basename without extension.

    Examples:
        src/example/transport/http.py -> example
        src/transport/http.py         -> transport
        pyproject.toml                -> pyproject
        scripts/foo/bar.sh            -> scripts
    """
    parts = Path(file_path).parts
    src_like = {"src", "lib", "pkg", "app", "source", "sources"}
    for i, part in enumerate(parts):
        if part.lower() in src_like and i + 1 < len(parts):
            return parts[i + 1]
    if len(parts) > 1:
        return parts[0]
    return Path(file_path).stem or "general"


def _compute_id(entry: dict) -> str:
    """Deterministic ID from the finding's stable identity fields.

    Re-running on the same manifest produces the same ID — important so the
    verdict engine's signature match is stable across regenerations.
    """
    payload = "|".join([
        entry.get("file", ""),
        entry.get("symbol", ""),
        entry.get("kind", ""),
        entry.get("summary", "").strip(),
    ])
    h = hashlib.sha256(payload.encode("utf-8")).hexdigest()[:ID_HEX_LEN]
    return f"{ID_PREFIX}{h}"


def _format_line_range(line_range) -> str:
    if not isinstance(line_range, (list, tuple)) or len(line_range) != 2:
        return "(unspecified)"
    start, end = line_range
    if start == end:
        return str(start)
    return f"{start}-{end}"


def _render_issue_body(group_findings, source_issue: int, pr_number: int) -> str:
    """Issue body — repo-agnostic, contains the mutual-cross-link substring.

    The 'PR #<n>' substring on the first line is what the verdict engine's
    cross-link guard validates against. Do not reformat it without updating
    the matcher.
    """
    lines = [
        f"Carried forward from the /implement run on #{source_issue} "
        f"(PR #{pr_number}).",
        "",
        "The following review-agent findings were surfaced during PR review "
        "but deferred under the Scope-Acknowledged Findings contract. They are "
        "tracked here for follow-up resolution. Closing this issue invalidates "
        "the related deferral and forces re-verification on the next "
        "/devflow:review run.",
        "",
        "## Findings",
        "",
    ]
    for f in group_findings:
        severity = f.get("severity", "Unknown")
        agent = f.get("agent", "unknown-agent")
        file_ = f.get("file", "(unknown)")
        line_str = _format_line_range(f.get("line_range"))
        symbol = f.get("symbol", "") or "(unspecified)"
        kind = f.get("kind", "(unspecified)")
        summary = (f.get("summary", "") or "").strip()
        category = f.get("category", "(unspecified)")
        explanation = (f.get("explanation", "") or "").strip()
        lines.extend([
            f"### {severity} — {agent}",
            f"**File**: {file_}:{line_str}",
            f"**Symbol**: {symbol}",
            f"**Kind**: {kind}",
            "",
            summary,
            "",
            f"**Why deferred**: {category} — {explanation}",
            "",
        ])
    lines.extend([
        "---",
        "Filed automatically by devflow-implement.",
    ])
    return "\n".join(lines)


def _issue_title(area: str, file_path: str, source_issue: int) -> str:
    return (
        f"{area}: deferred review findings in {file_path} "
        f"(carried from #{source_issue})"
    )


def _create_issue(title: str, body: str, dry_run: bool) -> tuple[int, str]:
    """Returns (issue_number, issue_url). Raises on failure."""
    if dry_run:
        sys.stderr.write(
            f"[dry-run] would file issue: {title}\n"
            f"[dry-run] body preview ({len(body)} chars):\n"
            f"{body[:300]}{'…' if len(body) > 300 else ''}\n"
        )
        return (0, "https://example.invalid/dry-run")

    # `encoding="utf-8"` pins the stdin pipe so a non-ASCII issue body (em-dash,
    # ellipsis) is encoded as UTF-8 rather than through the locale codec. Implies
    # text mode, so `text=True` is dropped.
    r = subprocess.run(
        [GH, "issue", "create", "--title", title, "--body-file", "-"],
        input=body, check=False, encoding="utf-8",
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or r.stdout.strip())
    url = r.stdout.strip().splitlines()[-1].strip()
    if "/issues/" not in url:
        raise RuntimeError(f"unexpected gh output: {r.stdout!r}")
    number = int(url.rsplit("/", 1)[-1])
    return (number, url)


def _write_manifest_atomic(path: Path, data: dict) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


def main(argv=None):
    _force_utf8_streams()
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--source-issue", type=int, required=True,
                   help="Issue number that triggered the /implement run.")
    p.add_argument("--pr", type=int, required=True,
                   help="PR number created by /implement Phase 3.1.")
    p.add_argument("--manifest", required=True,
                   help="Path to deferrals.json from review-and-fix.")
    p.add_argument("--dry-run", action="store_true",
                   help="Print actions; do not file issues or modify manifest.")
    args = p.parse_args(argv)

    manifest_path = Path(args.manifest)
    if not manifest_path.is_file():
        _fail(f"manifest not found: {manifest_path}", code=2)

    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        _fail(f"manifest is not valid JSON: {e}", code=2)

    if manifest.get("schema_version") != SCHEMA_VERSION:
        _fail(
            f"manifest schema_version={manifest.get('schema_version')!r} "
            f"unsupported (expected {SCHEMA_VERSION})", code=2,
        )

    deferrals = manifest.get("deferrals") or []
    if not deferrals:
        _fail("manifest contains no deferrals — nothing to file", code=2)

    if any(d.get("follow_up") for d in deferrals):
        _fail(
            "manifest already has follow_up entries — refusing to re-file. "
            "Delete the manifest and re-run review-and-fix to regenerate.",
            code=2,
        )

    filed_by = _gh_login() if not args.dry_run else "(dry-run-user)"
    filed_at = _now_iso()

    groups: "OrderedDict[str, list[dict]]" = OrderedDict()
    for d in deferrals:
        groups.setdefault(d.get("file", "(unknown)"), []).append(d)

    succeeded_numbers: list[int] = []
    failed_files: list[str] = []
    surviving: list[dict] = []

    for file_path, findings in groups.items():
        area = _derive_area(file_path)
        title = _issue_title(area, file_path, args.source_issue)
        body = _render_issue_body(findings, args.source_issue, args.pr)
        try:
            number, url = _create_issue(title, body, args.dry_run)
        except RuntimeError as e:
            sys.stderr.write(
                f"file-deferrals.py: failed to file issue for "
                f"{file_path}: {e}\n"
            )
            failed_files.append(file_path)
            continue

        for f in findings:
            entry = dict(f)
            entry["id"] = _compute_id(f)
            entry["follow_up"] = {
                "issue": number,
                "url": url,
                "filed_at": filed_at,
                "filed_by": filed_by,
            }
            surviving.append(entry)
        succeeded_numbers.append(number)

    if not surviving:
        _fail("no follow-up issues filed — every group failed", code=1)

    new_manifest = dict(manifest)
    new_manifest["deferrals"] = surviving
    new_manifest["generated_at"] = manifest.get("generated_at", filed_at)
    new_manifest["filed_at"] = filed_at

    if args.dry_run:
        sys.stderr.write(
            f"[dry-run] would rewrite manifest with {len(surviving)} entries, "
            f"dropping {len(failed_files)} failed group(s)\n"
        )
    else:
        _write_manifest_atomic(manifest_path, new_manifest)

    for n in succeeded_numbers:
        print(n)

    if failed_files:
        sys.stderr.write(
            f"file-deferrals.py: {len(failed_files)} group(s) failed and "
            f"were dropped from manifest: {', '.join(failed_files)}\n"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
