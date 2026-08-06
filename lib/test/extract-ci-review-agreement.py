#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Agreement predicate between the consumer snippet in docs/internal/workflow-triggers.md
and the auto_review_trigger job region in .github/workflows/ci.yml (issue #990).

A consumer copies BYTES out of the documented snippet, so the copy is unavoidable;
this extractor is the machine-consumed cross-file contract that keeps the two texts
from drifting. It compares byte-equality on exactly three portable element groups —
complete by construction:

  (i)   the FIVE portable eligibility clauses of the job's `if:`
  (ii)  the `permission-*` inputs on the create-github-app-token mint step
  (iii) the helper basename invoked by the run step(s)

Everything else is excluded by name (the job's `needs:` and the two
`needs.<job>.result` clauses — a consumer's dependency job names differ; the job id,
`name:`, `runs-on:`; the helper directory PREFIX — a consumer resolves it under the
vendored path; and the snippet's vendor-plugin materialization step). The marker
literal is outside the comparison too: the helper owns and emits it.

The extractor is a best-effort parser over human-mutable markdown and YAML and
FAILS CLOSED — each of six input shapes yields `result=error:<shape>` rather than
comparing two empty extractions and agreeing:

    snippet-absent, snippet-empty, snippet-duplicated, snippet-unfenced,
    job-absent, workflow-unparseable

Two empty extractions are never a pass.

Usage: extract-ci-review-agreement.py DOC_MD CI_YML
Prints exactly one line `result=agree|disagree|error:<shape>` to stdout and a
human-readable diagnosis to stderr. Always exits 0 (best-effort; the caller reads
the token, not the exit code).
"""
from __future__ import annotations

import sys

import yaml

SNIPPET_MARKER = "<!-- prflow:ci-review-consumer-snippet -->"

# The five PORTABLE eligibility clauses. A consumer's `if:` carries these verbatim;
# a consumer's own dependency-result clauses and `!cancelled()` are NOT portable and
# are excluded by not appearing in this set.
PORTABLE_CLAUSES = frozenset(
    {
        "github.event_name == 'pull_request'",
        "github.event.pull_request.draft == false",
        "github.event.pull_request.head.repo.full_name == github.repository",
        "github.actor != 'dependabot[bot]'",
        "vars.DEVFLOW_APP_ID != ''",
    }
)

HELPER_BASENAME = "post-ci-review-trigger.sh"


def _fail(shape: str, msg: str) -> None:
    sys.stderr.write(f"extract-ci-review-agreement: error:{shape} — {msg}\n")
    print(f"result=error:{shape}")


def _extract_snippet_yaml(md_text: str) -> tuple[str | None, str]:
    """Return (yaml_text, '') on success, or (None, shape) on a fail-closed shape."""
    lines = md_text.splitlines()
    marker_idxs = [i for i, ln in enumerate(lines) if ln.strip() == SNIPPET_MARKER]
    if not marker_idxs:
        return None, "snippet-absent"
    if len(marker_idxs) > 1:
        return None, "snippet-duplicated"
    start = marker_idxs[0]
    # The next non-blank line must open a fence.
    j = start + 1
    while j < len(lines) and lines[j].strip() == "":
        j += 1
    if j >= len(lines) or not lines[j].lstrip().startswith("```"):
        return None, "snippet-unfenced"
    # Collect until the closing fence.
    body: list[str] = []
    k = j + 1
    closed = False
    while k < len(lines):
        if lines[k].lstrip().startswith("```"):
            closed = True
            break
        body.append(lines[k])
        k += 1
    if not closed:
        return None, "snippet-unfenced"
    if not any(ln.strip() for ln in body):
        return None, "snippet-empty"
    return "\n".join(body), ""


def _sole_job(doc: object) -> dict | None:
    if not isinstance(doc, dict):
        return None
    jobs = doc.get("jobs")
    if not isinstance(jobs, dict) or not jobs:
        return None
    # The snippet carries exactly one job; the helper-invoking one is authoritative
    # if there is ambiguity.
    candidates = [v for v in jobs.values() if isinstance(v, dict)]
    for job in candidates:
        if _helper_basenames(job):
            return job
    return candidates[0] if candidates else None


def _portable_clause_set(job: dict) -> frozenset[str]:
    cond = job.get("if")
    if not isinstance(cond, str):
        return frozenset()
    clauses = {c.strip() for c in cond.split("&&")}
    return frozenset(c for c in clauses if c in PORTABLE_CLAUSES)


def _mint_permissions(job: dict) -> dict:
    steps = job.get("steps")
    if not isinstance(steps, list):
        return {}
    for step in steps:
        if not isinstance(step, dict):
            continue
        uses = step.get("uses", "")
        if isinstance(uses, str) and "create-github-app-token" in uses:
            with_block = step.get("with")
            if isinstance(with_block, dict):
                return {
                    k: with_block[k]
                    for k in with_block
                    if isinstance(k, str) and k.startswith("permission-")
                }
    return {}


def _helper_basenames(job: dict) -> frozenset[str]:
    steps = job.get("steps")
    if not isinstance(steps, list):
        return frozenset()
    found: set[str] = set()
    for step in steps:
        if not isinstance(step, dict):
            continue
        run = step.get("run")
        if isinstance(run, str) and HELPER_BASENAME in run:
            found.add(HELPER_BASENAME)
    return frozenset(found)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        sys.stderr.write("usage: extract-ci-review-agreement.py DOC_MD CI_YML\n")
        print("result=error:usage")
        return 0

    doc_path, ci_path = argv[1], argv[2]
    try:
        md_text = open(doc_path, encoding="utf-8").read()
    except OSError as exc:
        _fail("snippet-absent", f"could not read {doc_path}: {exc}")
        return 0
    try:
        ci_text = open(ci_path, encoding="utf-8").read()
    except OSError as exc:
        _fail("workflow-unparseable", f"could not read {ci_path}: {exc}")
        return 0

    snippet_yaml, shape = _extract_snippet_yaml(md_text)
    if snippet_yaml is None:
        _fail(shape, "snippet block did not extract cleanly")
        return 0
    try:
        snippet_doc = yaml.safe_load(snippet_yaml)
    except yaml.YAMLError as exc:
        _fail("snippet-unfenced", f"snippet block is not valid YAML: {exc}")
        return 0

    try:
        ci_doc = yaml.safe_load(ci_text)
    except yaml.YAMLError as exc:
        _fail("workflow-unparseable", f"ci.yml is not valid YAML: {exc}")
        return 0
    if not isinstance(ci_doc, dict) or not isinstance(ci_doc.get("jobs"), dict):
        _fail("workflow-unparseable", "ci.yml has no jobs mapping")
        return 0
    ci_job = ci_doc["jobs"].get("auto_review_trigger")
    if not isinstance(ci_job, dict):
        _fail("job-absent", "auto_review_trigger job region absent from ci.yml")
        return 0

    snip_job = _sole_job(snippet_doc)
    if snip_job is None:
        _fail("snippet-empty", "snippet carries no job mapping")
        return 0

    snip_clauses = _portable_clause_set(snip_job)
    ci_clauses = _portable_clause_set(ci_job)
    snip_perms = _mint_permissions(snip_job)
    ci_perms = _mint_permissions(ci_job)
    snip_helper = _helper_basenames(snip_job)
    ci_helper = _helper_basenames(ci_job)

    # Two empty extractions are never a pass: each group must be non-trivially
    # populated (all five clauses, a permission input, the helper basename) AND
    # equal on both sides.
    problems: list[str] = []
    if snip_clauses != PORTABLE_CLAUSES or ci_clauses != PORTABLE_CLAUSES:
        problems.append(
            f"portable if-clauses differ: snippet={sorted(snip_clauses)} "
            f"ci={sorted(ci_clauses)} (expected all of {sorted(PORTABLE_CLAUSES)})"
        )
    if not snip_perms or snip_perms != ci_perms:
        problems.append(f"mint permission-* inputs differ: snippet={snip_perms} ci={ci_perms}")
    if not snip_helper or snip_helper != ci_helper:
        problems.append(f"helper basename differs: snippet={sorted(snip_helper)} ci={sorted(ci_helper)}")

    if problems:
        for p in problems:
            sys.stderr.write(f"extract-ci-review-agreement: disagree — {p}\n")
        print("result=disagree")
        return 0

    print("result=agree")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
