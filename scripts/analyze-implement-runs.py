#!/usr/bin/env python3
"""Launch a fresh, read-only analyst over captured implement-run bundles."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Any


SAFE_ID = re.compile(r"^[A-Za-z0-9._-]+$")
SAFE_SLUG = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
REPORT_BEGIN = "<!-- DEVFLOW_REPORT_BEGIN -->"
REPORT_END = "<!-- DEVFLOW_REPORT_END -->"
ISSUE_BEGIN = re.compile(
    r"^<!-- DEVFLOW_ISSUE_BEGIN slug=([a-z0-9][a-z0-9-]{0,62}) runs=([A-Za-z0-9._,-]+) -->$",
    re.MULTILINE,
)
ISSUE_END = "<!-- DEVFLOW_ISSUE_END -->"


class AnalysisError(Exception):
    pass


def git_root() -> Path:
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        raise AnalysisError("current directory is not inside a Git repository") from exc
    return Path(result.stdout.strip()).resolve()


def read_bundle(bundle: Path) -> dict[str, Any]:
    if not (bundle / "transcript.jsonl").is_file():
        raise AnalysisError(f"bundle {bundle.name!r} has no transcript.jsonl")
    try:
        metadata = json.loads((bundle / "metadata.json").read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise AnalysisError(f"bundle {bundle.name!r} has invalid metadata.json") from exc
    if not isinstance(metadata, dict) or metadata.get("session_id") != bundle.name:
        raise AnalysisError(f"bundle {bundle.name!r} metadata identity does not match")
    captured = metadata.get("captured_at")
    if not isinstance(captured, str):
        raise AnalysisError(f"bundle {bundle.name!r} has no captured_at timestamp")
    try:
        metadata["_captured_sort"] = dt.datetime.fromisoformat(captured.replace("Z", "+00:00"))
    except ValueError as exc:
        raise AnalysisError(f"bundle {bundle.name!r} has invalid captured_at timestamp") from exc
    return metadata


def discover(bundle_root: Path) -> list[tuple[Path, dict[str, Any]]]:
    found = []
    if not bundle_root.is_dir():
        return found
    for path in bundle_root.iterdir():
        if not path.is_dir() or not SAFE_ID.fullmatch(path.name):
            continue
        try:
            found.append((path, read_bundle(path)))
        except AnalysisError:
            continue
    return sorted(found, key=lambda item: item[1]["_captured_sort"], reverse=True)


def select_bundles(root: Path, args: list[str]) -> list[tuple[Path, dict[str, Any]]]:
    bundle_root = root / ".devflow/tmp/implement-runs"
    available = discover(bundle_root)
    if not args or args == ["latest"]:
        if not available:
            raise AnalysisError("no valid implement-run bundles found")
        return available[:1]
    if args[:1] == ["--last"]:
        if len(args) != 2 or not args[1].isdigit() or int(args[1]) != 3:
            raise AnalysisError("--last currently requires exactly 3")
        selected = available[:3]
        if len(selected) != 3:
            raise AnalysisError("--last 3 requires three valid run bundles")
    else:
        if len(args) not in (1, 3):
            raise AnalysisError("select one run or an explicit cohort of exactly three runs")
        selected = []
        for session_id in args:
            if not SAFE_ID.fullmatch(session_id):
                raise AnalysisError(f"unsafe session id: {session_id!r}")
            bundle = bundle_root / session_id
            selected.append((bundle, read_bundle(bundle)))

    if len(selected) > 1:
        fingerprints = {metadata.get("prompt_fingerprint") for _, metadata in selected}
        if None in fingerprints or len(fingerprints) != 1:
            raise AnalysisError("multi-run cohorts require one matching non-null prompt fingerprint")
    return selected


def atomic_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.", delete=False
        ) as handle:
            temporary = handle.name
            handle.write(content)
            if not content.endswith("\n"):
                handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary:
            try:
                os.unlink(temporary)
            except OSError:
                pass


def analysis_dir(root: Path, selected: list[tuple[Path, dict[str, Any]]]) -> Path:
    identities = ",".join(path.name for path, _ in selected)
    digest = hashlib.sha256(identities.encode()).hexdigest()[:10]
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return root / ".devflow/tmp/implement-analyses" / f"{stamp}-{digest}"


def parse_output(output: str, cohort_ids: list[str]) -> tuple[str, list[tuple[str, str]]]:
    if output.count(REPORT_BEGIN) != 1 or output.count(REPORT_END) != 1:
        raise AnalysisError("model output must contain exactly one report block")
    begin = output.index(REPORT_BEGIN) + len(REPORT_BEGIN)
    end = output.index(REPORT_END)
    if end < begin:
        raise AnalysisError("report delimiters are out of order")
    report = output[begin:end].strip()
    if not report:
        raise AnalysisError("report block is empty")

    headers = list(ISSUE_BEGIN.finditer(output))
    if output.count("<!-- DEVFLOW_ISSUE_BEGIN") != len(headers) or output.count(ISSUE_END) != len(headers):
        raise AnalysisError("issue delimiters are malformed or unbalanced")
    if len(cohort_ids) == 1 and headers:
        raise AnalysisError("single-run analysis cannot publish issue drafts")

    issues: list[tuple[str, str]] = []
    seen_slugs: set[str] = set()
    cursor = 0
    for header in headers:
        if header.start() < cursor:
            raise AnalysisError("issue blocks overlap")
        close = output.find(ISSUE_END, header.end())
        next_header = output.find("<!-- DEVFLOW_ISSUE_BEGIN", header.end())
        if close < 0 or (next_header >= 0 and next_header < close):
            raise AnalysisError("issue blocks are nested or unclosed")
        slug = header.group(1)
        if not SAFE_SLUG.fullmatch(slug) or slug in seen_slugs:
            raise AnalysisError("issue slug is unsafe or duplicated")
        supporting = header.group(2).split(",")
        if len(supporting) != len(set(supporting)) or len(supporting) < 2:
            raise AnalysisError(f"issue {slug!r} needs at least two unique supporting runs")
        if any(item not in cohort_ids for item in supporting):
            raise AnalysisError(f"issue {slug!r} cites a run outside the selected cohort")
        body = output[header.end():close].strip()
        if not body:
            raise AnalysisError(f"issue {slug!r} is empty")
        issues.append((slug, body))
        seen_slugs.add(slug)
        cursor = close + len(ISSUE_END)
    return report, issues


def main(argv: list[str]) -> int:
    try:
        root = git_root()
        selected = select_bundles(root, argv)
        cohort_ids = [path.name for path, _ in selected]
        out_dir = analysis_dir(root, selected)
        if len(selected) > 1:
            cohort = {
                "schema_version": 1,
                "session_ids": cohort_ids,
                "prompt_fingerprint": selected[0][1]["prompt_fingerprint"],
                "created_at": dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z"),
            }
            atomic_text(out_dir / "cohort.json", json.dumps(cohort, indent=2, sort_keys=True))

        template = (Path(__file__).parent / "prompts/implement-flight-recorder-analysis.md").read_text()
        paths = "\n".join(f"- {path.resolve()}" for path, _ in selected)
        prompt = f"{template}\n\nSupplied run bundles:\n{paths}\n"
        claude = os.environ.get("DEVFLOW_CLAUDE_BIN", "claude")
        command = [
            claude,
            "--safe-mode",
            "--print",
            "--permission-mode",
            "dontAsk",
            "--allowedTools",
            "Read,Grep,Glob",
            prompt,
        ]
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if result.returncode != 0:
            atomic_text(out_dir / "model-error.txt", result.stderr or f"model exited {result.returncode}")
            raise AnalysisError(f"analyst failed; diagnostic: {out_dir / 'model-error.txt'}")
        try:
            report, issues = parse_output(result.stdout, cohort_ids)
        except AnalysisError:
            atomic_text(out_dir / "invalid-model-output.txt", result.stdout)
            raise

        if len(selected) == 1:
            destination = selected[0][0] / "run-report.md"
            atomic_text(destination, report)
            print(destination)
        else:
            destination = out_dir / "comparison-report.md"
            atomic_text(destination, report)
            for slug, body in issues:
                atomic_text(out_dir / "issue-drafts" / f"{slug}.md", body)
            print(out_dir)
        return 0
    except (AnalysisError, OSError) as exc:
        print(f"devflow: implement-run-analysis: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
