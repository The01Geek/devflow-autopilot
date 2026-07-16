#!/usr/bin/env python3
"""Fail-open local recorder for Claude Code /devflow:implement sessions."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Any


PREFIX = "devflow: implement-flight-recorder:"
SAFE_COMPONENT = re.compile(r"^[A-Za-z0-9._-]+$")
PLAIN_INVOCATION = re.compile(r"(?:^|\s)/devflow:implement\s+(\d+)(?:\s|$)")
MARKUP_INVOCATION = re.compile(
    r"<command-message>\s*(?:/)?devflow:implement\s*</command-message>"
    r"[\s\S]*?<command-args>\s*(\d+)(?:\s[^<]*)?</command-args>",
    re.IGNORECASE,
)


def warn(message: str) -> None:
    print(f"{PREFIX} {message}", file=sys.stderr)


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def run_git(root: Path, *args: str) -> str | None:
    try:
        result = subprocess.run(
            ["git", "-C", str(root), *args],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        value = result.stdout.strip()
        return value or None
    except (OSError, subprocess.CalledProcessError):
        return None


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temp_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=f".{path.name}.", delete=False) as handle:
            temp_name = handle.name
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp_name, 0o600)
        os.replace(temp_name, path)
        temp_name = None
    finally:
        if temp_name:
            try:
                os.unlink(temp_name)
            except OSError:
                pass


def json_bytes(value: Any) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def content_text(value: Any) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        parts = []
        for item in value:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict) and isinstance(item.get("text"), str):
                parts.append(item["text"])
        return "\n".join(parts)
    return ""


def user_text(record: dict[str, Any]) -> str:
    """Return text only when the JSONL record is authoritatively user-originated."""
    message = record.get("message")
    if isinstance(message, dict) and message.get("role") == "user":
        return content_text(message.get("content"))
    if record.get("type") == "user":
        if isinstance(message, dict):
            return content_text(message.get("content"))
        return content_text(record.get("content"))
    return ""


def classify_transcript(raw: bytes) -> int | None:
    issue: int | None = None
    saw_record = False
    for line_number, line in enumerate(raw.splitlines(), 1):
        if not line.strip():
            continue
        saw_record = True
        try:
            record = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ValueError(f"transcript JSONL is malformed at line {line_number}") from exc
        if not isinstance(record, dict):
            raise ValueError(f"transcript JSONL record {line_number} is not an object")
        text = user_text(record)
        match = PLAIN_INVOCATION.search(text) or MARKUP_INVOCATION.search(text)
        if match and issue is None:
            issue = int(match.group(1))
    if not saw_record:
        raise ValueError("transcript JSONL is empty")
    return issue


def prompt_manifest(root: Path) -> tuple[dict[str, Any], str | None, list[str]]:
    candidates: list[tuple[str, str]] = [
        ("skills/implement/SKILL.md", "always"),
        ("skills/review/SKILL.md", "nested"),
        ("skills/review-and-fix/SKILL.md", "nested"),
        ("skills/docs/SKILL.md", "nested"),
    ]
    phase_dir = root / "skills/implement/phases"
    phase_paths = sorted(phase_dir.glob("*.md")) if phase_dir.is_dir() else []
    candidates.extend((path.relative_to(root).as_posix(), "phase") for path in phase_paths)

    surfaces: list[dict[str, Any]] = []
    missing: list[str] = []
    for relative, load_class in candidates:
        path = root / relative
        if not path.is_file():
            missing.append(relative)
            continue
        data = path.read_bytes()
        text = data.decode("utf-8", errors="replace")
        surfaces.append(
            {
                "path": relative,
                "load_class": load_class,
                "bytes": len(data),
                "lines": len(data.splitlines()),
                "words": len(re.findall(r"\S+", text)),
                "approx_tokens": math.ceil(len(data) / 4),
                "sha256": hashlib.sha256(data).hexdigest(),
            }
        )

    totals: dict[str, dict[str, int]] = {}
    for surface in surfaces:
        bucket = totals.setdefault(
            surface["load_class"], {"bytes": 0, "lines": 0, "words": 0, "approx_tokens": 0}
        )
        for key in bucket:
            bucket[key] += surface[key]

    fingerprint = None
    if surfaces:
        material = "".join(
            f"{item['path']}\0{item['sha256']}\0{item['load_class']}\n"
            for item in sorted(surfaces, key=lambda entry: entry["path"])
        ).encode()
        fingerprint = hashlib.sha256(material).hexdigest()
    manifest = {
        "schema_version": 1,
        "token_estimate": "ceil(bytes / 4); heuristic, not API-reported",
        "surfaces": surfaces,
        "totals_by_load_class": totals,
        "missing_surfaces": missing,
    }
    return manifest, fingerprint, missing


def append_attempt(path: Path, record: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(descriptor, json.dumps(record, sort_keys=True, separators=(",", ":")).encode() + b"\n")
    finally:
        os.close(descriptor)


def capture() -> None:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise ValueError("Stop payload is not valid JSON") from exc
    if not isinstance(payload, dict):
        raise ValueError("Stop payload must be a JSON object")

    session_id = payload.get("session_id")
    if not isinstance(session_id, str) or not SAFE_COMPONENT.fullmatch(session_id):
        raise ValueError("session_id is missing or unsafe")
    transcript_value = payload.get("transcript_path")
    if not isinstance(transcript_value, str) or not transcript_value:
        raise ValueError("transcript_path is missing")
    transcript = Path(transcript_value)
    if not transcript.is_file() or not os.access(transcript, os.R_OK):
        raise ValueError("transcript_path is not a readable regular file")
    cwd_value = payload.get("cwd")
    if not isinstance(cwd_value, str) or not Path(cwd_value).is_dir():
        raise ValueError("cwd is missing or is not an existing directory")
    cwd = Path(cwd_value).resolve()
    resolved = run_git(cwd, "rev-parse", "--show-toplevel")
    root = Path(resolved).resolve() if resolved else cwd

    raw = transcript.read_bytes()
    issue_number = classify_transcript(raw)
    if issue_number is None:
        return

    # Measure repository state before creating observer artifacts. Consumer repos
    # may not ignore .devflow/tmp yet; capture must not mark its own run dirty.
    branch = run_git(root, "branch", "--show-current")
    head_sha = run_git(root, "rev-parse", "HEAD")
    status = run_git(root, "status", "--porcelain")
    dirty_tree = None if status is None and head_sha is None else bool(status)
    manifest, fingerprint, missing = prompt_manifest(root)

    bundle = root / ".devflow/tmp/implement-runs" / session_id
    bundle.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        os.chmod(bundle, 0o700)
    except OSError:
        pass
    metadata = {
        "schema_version": 1,
        "session_id": session_id,
        "issue_number": issue_number,
        "captured_at": utc_now(),
        "repository_root": str(root),
        "branch": branch,
        "head_sha": head_sha,
        "dirty_tree": dirty_tree,
        "transcript_bytes": len(raw),
        "prompt_fingerprint": fingerprint,
        "missing_surfaces": missing,
        "active_marker_present": any((root / ".devflow/tmp").glob("implement-active-*")),
        "warnings": (["no expected prompt surfaces were available"] if fingerprint is None else []),
    }
    atomic_write(bundle / "transcript.jsonl", raw)
    atomic_write(bundle / "prompt-surfaces.json", json_bytes(manifest))
    atomic_write(bundle / "metadata.json", json_bytes(metadata))
    append_attempt(
        bundle / "stop-attempts.jsonl",
        {"captured_at": metadata["captured_at"], "transcript_bytes": len(raw), "result": "captured"},
    )


def main() -> int:
    try:
        capture()
    except Exception as exc:  # Stop observers must never block the session they observe.
        warn(str(exc) or exc.__class__.__name__)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
