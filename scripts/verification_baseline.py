#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Offline verification-launch baseline analyzer (issue #527, Wave 1).

Read-only, pure Python standard library, no subprocess, no network. Builds a
source-provenanced baseline of actual verification launches from LOCAL native
transcript events, plus a local + cloud lifecycle census (eligibility + source
missingness) that is independent of transcript survival. Cloud LAUNCH analysis
is excluded in Wave 1 (no durable redacted execution-event source exists
without changing workflows); cloud rows are census/missingness-only.

The analyzer changes no skills/**, agents/**, .github/workflows/** execution
logic, config, allowlists, workpad/iteration writer, consumer routing, process
ownership, cancellation, or verification outcomes. It launches no verification
command and invokes no repository-provided executable — it reads already-imported
bundles + start manifests + the registry + an optional cloud census snapshot,
and that is all. workspace_state coverage is derived from explicit source-event
results, never analyzer-time inspection (so no git/subprocess).

Output is local and gitignored under owner-only 0700 directories and 0600 files
under .devflow/tmp/verification-baselines/. Artifacts carry created_at,
source_snapshot_hash, and expires_at; --cleanup deletes baseline and
manual-review artifacts without touching native sources. Raw transcript text,
tool input, stdout/stderr, secrets, redacted displays, and source paths never
enter model prompts, errors, logs, telemetry, workflow artifacts, PR comments,
or tracked .devflow/logs/**. The report cites source-event IDs only.

Sibling helpers in workflow_flight_recorder (_atomic_write, _timestamp_ms,
_utc_timestamp) are re-implemented here rather than imported, to keep this
analyzer decoupled from the recorder's private surface and to guarantee the
no-subprocess/no-git contract by construction.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import sys
import time
import tracemalloc
from dataclasses import dataclass, field
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Any

# Reuse the recorder's PUBLIC parsing API only (stable, pure stdlib, no git).
# Importing the module is safe — subprocess is only invoked inside functions we
# do not call (inventory_native_transcripts / _shared_storage_root / _run_git).
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import workflow_flight_recorder as wfr  # noqa: E402

SAFE_ID = wfr.SAFE_ID
REGISTRY_SCHEMA_VERSION = 1
CLOUD_MAPPINGS_SCHEMA_VERSION = 1

ELIGIBLE_LIFECYCLE_SCHEMA = 1
VERIFICATION_REQUEST_SCHEMA = 1
VERIFICATION_PROCESS_LAUNCH_SCHEMA = 1
VERIFICATION_BASELINE_SCHEMA = 1

# Census source enum (local vs cloud).
SOURCE_LOCAL = "local"
SOURCE_CLOUD = "cloud"

# Eligibility states — exactly these four, never promoted, never silently omitted.
ELIGIBILITY_CONFIRMED = "confirmed_eligible"
ELIGIBILITY_PROVISIONAL = "provisional_candidate"
ELIGIBILITY_INELIGIBLE = "confirmed_ineligible"
ELIGIBILITY_UNKNOWN = "eligibility_unknown"
ELIGIBILITY_STATES = (
    ELIGIBILITY_CONFIRMED,
    ELIGIBILITY_PROVISIONAL,
    ELIGIBILITY_INELIGIBLE,
    ELIGIBILITY_UNKNOWN,
)

# Local source-status enum (left-join of native imports onto census rows).
SOURCE_AVAILABLE = "source_available"
SOURCE_ELIGIBLE_NOT_IMPORTED = "eligible_not_imported"
SOURCE_IMPORT_FAILED = "import_failed"
SOURCE_MISSING = "source_missing"
SOURCE_UNREADABLE = "source_unreadable"
SOURCE_UNSUPPORTED = "source_unsupported"
SOURCE_UNAVAILABLE = "unavailable"  # cloud census absent/incomplete
LOCAL_SOURCE_STATUSES = (
    SOURCE_AVAILABLE,
    SOURCE_ELIGIBLE_NOT_IMPORTED,
    SOURCE_IMPORT_FAILED,
    SOURCE_MISSING,
    SOURCE_UNREADABLE,
    SOURCE_UNSUPPORTED,
)

# Authorization/start classification (per-source versioned adapters).
START_DENIED_PRE = "denied_pre_start"
START_CANCELLED_PRE = "cancelled_pre_start"
START_CONFIRMED_TERMINAL = "start_confirmed_terminal"
START_CONFIRMED_RESULT_MISSING = "start_confirmed_result_missing"
START_UNKNOWN = "start_unknown"
START_CLASSES = (
    START_DENIED_PRE,
    START_CANCELLED_PRE,
    START_CONFIRMED_TERMINAL,
    START_CONFIRMED_RESULT_MISSING,
    START_UNKNOWN,
)

# Request taxonomy (versioned).
TAXONOMY_VERSION = 1
KIND_VERIFICATION = "verification"
KIND_OTHER_COMMAND = "other_command"
KIND_VERIFICATION_UNKNOWN = "verification_unknown"
REQUEST_KINDS = (KIND_VERIFICATION, KIND_OTHER_COMMAND, KIND_VERIFICATION_UNKNOWN)

# Join confidence — exactly these four.
CONFIDENCE_EXACT = "exact"
CONFIDENCE_PARTIAL = "partial"
CONFIDENCE_AMBIGUOUS = "ambiguous"
CONFIDENCE_UNMATCHED = "unmatched"
CONFIDENCE_CLASSES = (CONFIDENCE_EXACT, CONFIDENCE_PARTIAL, CONFIDENCE_AMBIGUOUS, CONFIDENCE_UNMATCHED)

# Relationship classes — exactly these five.
REL_SINGLE = "single"
REL_CANDIDATE_TRANSPORT_RETRY = "candidate_transport_retry"
REL_INTENTIONAL_RERUN = "intentional_rerun_evidence"
REL_INDEPENDENT_LIFECYCLE = "independent_lifecycle"
REL_UNCLASSIFIABLE = "unclassifiable"
RELATIONSHIP_CLASSES = (
    REL_SINGLE,
    REL_CANDIDATE_TRANSPORT_RETRY,
    REL_INTENTIONAL_RERUN,
    REL_INDEPENDENT_LIFECYCLE,
    REL_UNCLASSIFIABLE,
)

MUTATION_STATE_UNBOUNDED = "mutation_state_unbounded"

# Adjudication verdicts reviewers record (manual-review artifact, initially empty).
ADJUDICATION_CONFIRMED_RETRY = "confirmed_retry_pattern"
ADJUDICATION_INTENTIONAL_RERUN = "intentional_rerun"
ADJUDICATION_INSUFFICIENT = "insufficient_evidence"
ADJUDICATION_VERDICTS = (ADJUDICATION_CONFIRMED_RETRY, ADJUDICATION_INTENTIONAL_RERUN, ADJUDICATION_INSUFFICIENT)

# Verification taxonomy signatures (versioned). A Bash tool_use whose command
# matches one of these is a verification request. Conservative: anything not
# matching a verification signature AND not a clearly-non-verification head is
# verification_unknown (never silently dismissed as "other").
VERIFICATION_PATTERNS = (
    re.compile(r"\blib/test/run\.sh\b"),
    re.compile(r"\bpytest\b"),
    re.compile(r"\bpython3?\s+-m\s+pytest\b"),
    re.compile(r"\bruff\b"),
    re.compile(r"\bshellcheck\b"),
    re.compile(r"\bnpm\s+(run\s+)?test\b"),
    re.compile(r"\byarn\s+test\b"),
    re.compile(r"\bcargo\s+test\b"),
    re.compile(r"\bgo\s+test\b"),
    re.compile(r"\bmvn\s+test\b"),
    re.compile(r"\bgradle\s+test\b"),
    re.compile(r"\bjest\b"),
    re.compile(r"\bvitest\b"),
    re.compile(r"\btox\b"),
)
# Clearly non-verification command heads (a request starting with one of these
# is other_command, not verification). Conservative and small.
NON_VERIFICATION_HEADS = frozenset(
    {"git", "gh", "ls", "cat", "echo", "cd", "pwd", "mkdir", "rm", "cp", "mv",
     "touch", "chmod", "chown", "stat", "file", "which", "env", "export"}
)

# Secret-bearing token patterns (canonicalize+redact before digesting). Matched
# values are replaced with typed markers; the digest is of the redacted form, so
# no secret material reaches the binding identity. A redacted digest alone never
# establishes an exact match (see _join_confidence).
SECRET_ENV_ASSIGNMENT = re.compile(
    r"\b([A-Z0-9_]*(?:TOKEN|SECRET|KEY|PASSWORD|PASS|PAT|CREDENTIAL|PRIVATE_KEY)[A-Z0-9_]*)=(\S+)",
    re.IGNORECASE,
)
SECRET_FLAG = re.compile(
    r"(--(?:token|key|password|passwd|secret|pat|app-key|private-key|credential))"
    r"(?:[ =])(\S+)",
    re.IGNORECASE,
)
SECRET_URL = re.compile(r"(https?://)[^/\s:@]+:[^/\s:@]+@")
BEARER_TOKEN = re.compile(r"(Bearer\s+)([A-Za-z0-9._\-+/=]+)", re.IGNORECASE)

DEFAULT_MANIFESTS_DIR = ".devflow/tmp/workflow-manifests"
DEFAULT_BUNDLES_DIR = ".devflow/tmp/workflow-runs"
DEFAULT_REGISTRY = "scripts/workflow-flight-recorder-registry.json"
DEFAULT_OUT_DIR = ".devflow/tmp/verification-baselines"
DEFAULT_CLOUD_SNAPSHOT = None
DEFAULT_MAX_SOURCE_BYTES = 64 * 1024 * 1024  # 64 MiB per source; breach -> skipped reason.
DEFAULT_TTL_SECONDS = 30 * 24 * 3600  # expires_at = created_at + 30d

DIR_MODE = 0o700
FILE_MODE = 0o600


# --------------------------------------------------------------------------- #
# Path validation (reject symlinks, traversal, root escapes before opening).
# --------------------------------------------------------------------------- #
def _validate_admitted_path(raw: str, must_exist: bool = False) -> Path:
    """Resolve an admitted path, rejecting symlinks/traversal/root escapes.

    Transcript text and cloud-snapshot paths are attacker-shaped data; never
    open them raw. Admits paths under the process cwd (the repo root) and the
    gitignored .devflow/tmp tree, normalized and realpath-checked so a symlink
    or a ``..`` escape cannot reach outside the admitted root.
    """
    if not isinstance(raw, str) or not raw:
        raise ValueError("path must be a non-empty string")
    candidate = Path(raw)
    # Reject path-traversal/root-escape syntactically before any filesystem call.
    if candidate.is_absolute() and not _within_repo_root(candidate):
        raise ValueError(f"path escapes the admitted root: {raw}")
    normalized = (Path(os.getcwd()) / candidate).resolve(strict=False)
    if not _within_repo_root(normalized):
        raise ValueError(f"resolved path escapes the admitted root: {normalized}")
    # Reject symlinks pointing outside the admitted root.
    try:
        if normalized.is_symlink():
            target = normalized.resolve(strict=True)
            if not _within_repo_root(target):
                raise ValueError(f"symlink escapes the admitted root: {raw} -> {target}")
    except OSError:
        if must_exist:
            raise
    if must_exist and not normalized.exists():
        raise FileNotFoundError(f"admitted path does not exist: {normalized}")
    return normalized


def _within_repo_root(path: Path) -> bool:
    root = Path(os.getcwd()).resolve(strict=False)
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


# --------------------------------------------------------------------------- #
# Atomic write (0700 dirs, 0600 files, fsync, atomic replace) — no shell.
# --------------------------------------------------------------------------- #
def _atomic_write(path: Path, data: bytes) -> None:
    parent = path.parent
    parent.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(parent, DIR_MODE)
    except OSError:
        pass
    tmp_fd, tmp_path = tempfile_staged(parent)
    try:
        with os.fdopen(tmp_fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp_path, FILE_MODE)
        os.replace(tmp_path, path)
    finally:
        if os.path.exists(tmp_path) and tmp_path != path:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass


def tempfile_staged(parent: Path) -> "tuple[int, str]":
    import tempfile
    return tempfile.mkstemp(dir=str(parent), prefix=".vb-")


# --------------------------------------------------------------------------- #
# Timestamps (tz-aware; unknown stays unknown — None, never 0).
# --------------------------------------------------------------------------- #
def _now_iso() -> str:
    return datetime.now(tz=timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _parse_iso_ms(value: Any) -> "int | None":
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return int(parsed.timestamp() * 1000)


def _ms_to_iso(ms: "int | None") -> "str | None":
    if ms is None:
        return None
    return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _expires_at(created_iso: str, ttl_seconds: int = DEFAULT_TTL_SECONDS) -> str:
    try:
        created = datetime.fromisoformat(created_iso.replace("Z", "+00:00"))
    except ValueError:
        return created_iso
    return (created + timedelta(seconds=ttl_seconds)).isoformat(timespec="milliseconds").replace("+00:00", "Z")


# --------------------------------------------------------------------------- #
# Surrogate IDs + safe digests.
# --------------------------------------------------------------------------- #
def _sha8(*parts: str) -> str:
    digest = hashlib.sha256("␟".join(parts).encode("utf-8")).hexdigest()
    return digest[:12]


def _sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _surrogate_id(source: str, *identity_parts: str) -> str:
    """Row-local surrogate ID so unknown natural-key fields never coalesce.

    Distinct from a natural key: two rows with unknown/empty natural-key fields
    still get distinct surrogate IDs (the position-in-input is part of the
    hash), so they never join as if they shared an identity.
    """
    return f"{source}-{_sha8(*identity_parts)}"


def _source_event_id(session_id: str, event_index: int) -> str:
    """Cite source events by ID, not raw transcript path/text."""
    return f"evt:{_sha8(session_id)}:{event_index}"


# --------------------------------------------------------------------------- #
# Secret redaction + safe binding identity.
# --------------------------------------------------------------------------- #
@dataclass(frozen=True)
class BindingIdentity:
    digest: str  # keyed digest of the REDACTED canonical command (no secret material)
    secret_affected: bool
    secret_slots: tuple[str, ...]  # typed markers, e.g. ("env:TOKEN", "flag:key", "url-cred", "bearer")
    redacted_display: str  # canonical + redacted, length-bounded (local record only)

    def to_dict(self) -> dict[str, Any]:
        return {
            "digest": self.digest,
            "secret_affected": self.secret_affected,
            "secret_slots": list(self.secret_slots),
            # NOTE: redacted_display is local-record-only (gitignored 0700); it is
            # never emitted into reports/PR comments/logs (reports cite source-event IDs only).
            "redacted_display": self.redacted_display,
        }


def _canonical_command(command: str) -> str:
    # Collapse internal runs of whitespace; strip; lowercase the head is NOT done
    # (binding identity is case-sensitive on purpose — a differently-cased command
    # is a different binding). Trim trailing punctuation noise only.
    return re.sub(r"\s+", " ", command).strip()


def _redact_secrets(command: str) -> "tuple[str, bool, list[str]]":
    """Canonicalize + redact secret-bearing tokens before digesting.

    Returns (redacted_command, secret_affected, typed_slots). No raw secret and
    no unkeyed digest of secret material ever leaves this function: the digest
    (in BindingIdentity) is computed over ``redacted_command``.
    """
    redacted = command
    slots: list[str] = []

    def env_repl(match: "re.Match[str]") -> str:
        name = match.group(1)
        slots.append(f"env:{name.upper()}")
        return f"{name}=<env:{name.upper()}>"

    redacted = SECRET_ENV_ASSIGNMENT.sub(env_repl, redacted)

    def flag_repl(match: "re.Match[str]") -> str:
        flag = match.group(1).lower()
        slots.append(f"flag:{flag.lstrip('-')}")
        return f"{match.group(1)}=<flag:{flag.lstrip('-')}>"

    redacted = SECRET_FLAG.sub(flag_repl, redacted)

    if SECRET_URL.search(redacted):
        redacted = SECRET_URL.sub(r"\1<url-cred>@", redacted)
        slots.append("url-cred")

    def bearer_repl(match: "re.Match[str]") -> str:
        slots.append("bearer")
        return f"{match.group(1)}<bearer>"

    redacted = BEARER_TOKEN.sub(bearer_repl, redacted)

    affected = bool(slots)
    # Deduplicate slots preserving order.
    seen: set[str] = set()
    unique_slots = [s for s in slots if not (s in seen or seen.add(s))]
    return redacted, affected, unique_slots


def _binding_identity(command: str) -> BindingIdentity:
    canonical = _canonical_command(command)
    redacted, affected, slots = _redact_secrets(canonical)
    # Length-bound the local-only display so even the redacted form cannot dump
    # unbounded command text into the (gitignored, 0700) record.
    display = redacted[:500]
    digest = _sha256_hex(redacted.encode("utf-8"))
    return BindingIdentity(digest=digest, secret_affected=affected, secret_slots=tuple(slots), redacted_display=display)


# --------------------------------------------------------------------------- #
# Records (each schema-versioned independently; additive fields do not bump).
# --------------------------------------------------------------------------- #
@dataclass
class EligibleLifecycle:
    source: str  # local | cloud
    surrogate_id: str
    consumer: str | None
    subject: dict | None
    identity: dict  # local: session_id/project_path/started_at; cloud: repo/workflow/run_id/attempt/job/started_at
    eligibility_state: str
    eligibility_evidence: str
    host_profile: dict | None
    source_status: str  # local: LOCAL_SOURCE_STATUSES; cloud: available|unavailable
    provenance: dict  # session_id refs + snapshot_ref (no raw native paths)
    schema_version: int = ELIGIBLE_LIFECYCLE_SCHEMA

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema_version": self.schema_version,
            "source": self.source,
            "surrogate_id": self.surrogate_id,
            "consumer": self.consumer,
            "subject": self.subject,
            "identity": self.identity,
            "eligibility_state": self.eligibility_state,
            "eligibility_evidence": self.eligibility_evidence,
            "host_profile": self.host_profile,
            "source_status": self.source_status,
            "provenance": self.provenance,
        }


@dataclass
class VerificationRequest:
    request_id: str
    source_event_id: str
    lifecycle_id: str | None
    tool_use_id: str
    consumer_skill: str | None
    phase_checkpoint: str | None
    command_head: str
    binding: BindingIdentity
    request_kind: str  # verification | other_command | verification_unknown
    authorization_start: str
    timing: dict  # requested_at, started_at, finished_at, duration_ms
    result_presence: bool | None
    exit_evidence: dict | None
    skipped_check_evidence: dict | None
    provenance: dict
    schema_version: int = VERIFICATION_REQUEST_SCHEMA

    def to_dict(self) -> dict[str, Any]:
        d = {
            "schema_version": self.schema_version,
            "request_id": self.request_id,
            "source_event_id": self.source_event_id,
            "lifecycle_id": self.lifecycle_id,
            "tool_use_id": self.tool_use_id,
            "consumer_skill": self.consumer_skill,
            "phase_checkpoint": self.phase_checkpoint,
            "command_head": self.command_head,
            "binding": self.binding.to_dict(),
            "request_kind": self.request_kind,
            "authorization_start": self.authorization_start,
            "timing": self.timing,
            "result_presence": self.result_presence,
            "exit_evidence": self.exit_evidence,
            "skipped_check_evidence": self.skipped_check_evidence,
            "provenance": self.provenance,
        }
        return d


@dataclass
class VerificationProcessLaunch:
    launch_id: str
    request_id: str
    source_event_id: str
    lifecycle_id: str | None
    tool_use_id: str
    consumer_skill: str | None
    phase_checkpoint: str | None
    command_head: str
    binding: BindingIdentity
    start_authorization: str
    timing: dict  # started_at, finished_at, duration_ms, caller_observed_duration_ms
    workspace_state: dict  # covered_roots, observation_method, coverage, mutation_state_unbounded
    result_presence: bool | None
    exit_evidence: dict | None
    skipped_check_evidence: dict | None
    provenance: dict
    retrigger_evidence: bool = False  # explicit iteration/checkpoint/post-fix/base-merge/human-retrigger; Wave 1 extraction never sets this True (no markers extracted), but the field carries the guard the candidate classification requires.
    schema_version: int = VERIFICATION_PROCESS_LAUNCH_SCHEMA

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema_version": self.schema_version,
            "launch_id": self.launch_id,
            "request_id": self.request_id,
            "source_event_id": self.source_event_id,
            "lifecycle_id": self.lifecycle_id,
            "tool_use_id": self.tool_use_id,
            "consumer_skill": self.consumer_skill,
            "phase_checkpoint": self.phase_checkpoint,
            "command_head": self.command_head,
            "binding": self.binding.to_dict(),
            "start_authorization": self.start_authorization,
            "timing": self.timing,
            "workspace_state": self.workspace_state,
            "result_presence": self.result_presence,
            "exit_evidence": self.exit_evidence,
            "skipped_check_evidence": self.skipped_check_evidence,
            "provenance": self.provenance,
            "retrigger_evidence": self.retrigger_evidence,
        }


@dataclass
class RelationshipGroup:
    group_id: str
    members: list[str]  # launch_ids
    relationship: str
    join_confidence: str
    workspace_state: dict
    binding_digest: str | None
    consumer: str | None
    duration_ms: int | None  # group representative duration (max member duration)
    provenance: dict

    def to_dict(self) -> dict[str, Any]:
        return {
            "group_id": self.group_id,
            "members": self.members,
            "relationship": self.relationship,
            "join_confidence": self.join_confidence,
            "workspace_state": self.workspace_state,
            "binding_digest": self.binding_digest,
            "consumer": self.consumer,
            "duration_ms": self.duration_ms,
            "provenance": self.provenance,
        }


# --------------------------------------------------------------------------- #
# Cloud mappings loader (additive registry section; load_registry ignores it).
# --------------------------------------------------------------------------- #
def load_cloud_mappings(registry_path: Path) -> dict[str, dict[str, str]]:
    """Return {(workflow_file, job): agent_job_entry} from the registry's
    additive cloud_mappings section. Returns {} when the section is absent
    (cloud coverage then reads unavailable, never zero)."""
    try:
        document = json.loads(registry_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(document, dict):
        return {}
    mappings = document.get("cloud_mappings")
    if not isinstance(mappings, dict) or mappings.get("schema_version") != CLOUD_MAPPINGS_SCHEMA_VERSION:
        return {}
    agent_jobs = mappings.get("agent_jobs")
    if not isinstance(agent_jobs, list):
        return {}
    table: dict[str, dict[str, str]] = {}
    for entry in agent_jobs:
        if not isinstance(entry, dict):
            continue
        wf = entry.get("workflow_file")
        job = entry.get("job")
        if not isinstance(wf, str) or not isinstance(job, str):
            continue
        table[f"{wf}\x1f{job}"] = {
            "consumer": str(entry.get("consumer") or ""),
            "routed_command": str(entry.get("routed_command") or ""),
            "agent_step": str(entry.get("agent_step") or ""),
        }
    return table


# --------------------------------------------------------------------------- #
# Local census: one EligibleLifecycle row per start manifest.
# --------------------------------------------------------------------------- #
def build_local_census(manifests_dir: Path, registry: dict) -> list[EligibleLifecycle]:
    rows: list[EligibleLifecycle] = []
    if not manifests_dir.exists() or not manifests_dir.is_dir():
        return rows
    manifest_files = sorted(p for p in manifests_dir.iterdir() if p.is_file() and p.suffix == ".json")
    for position, path in enumerate(manifest_files):
        try:
            raw = path.read_text(encoding="utf-8")
            doc = json.loads(raw)
        except (OSError, json.JSONDecodeError):
            # Unreadable manifest -> denominator row with eligibility_unknown.
            rows.append(_unknown_manifest_row(path, position))
            continue
        if not isinstance(doc, dict):
            rows.append(_unknown_manifest_row(path, position))
            continue
        rows.append(_local_row_from_manifest(doc, path, position, registry))
    return rows


def _unknown_manifest_row(path: Path, position: int) -> EligibleLifecycle:
    sid = _safe_session_id_from_name(path.stem)
    return EligibleLifecycle(
        source=SOURCE_LOCAL,
        surrogate_id=_surrogate_id(SOURCE_LOCAL, sid or path.name, str(position)),
        consumer=None,
        subject=None,
        identity={"session_id": sid, "project_path": None, "started_at": None},
        eligibility_state=ELIGIBILITY_UNKNOWN,
        eligibility_evidence="manifest unreadable or malformed",
        host_profile=None,
        source_status=SOURCE_UNREADABLE,
        provenance={"manifest_session_id": sid},
    )


def _safe_session_id_from_name(stem: str) -> str | None:
    return stem if (isinstance(stem, str) and SAFE_ID.fullmatch(stem)) else None


def _local_row_from_manifest(doc: dict, path: Path, position: int, registry: dict) -> EligibleLifecycle:
    sid = doc.get("session_id") if isinstance(doc.get("session_id"), str) else _safe_session_id_from_name(path.stem)
    sid = sid if (isinstance(sid, str) and SAFE_ID.fullmatch(sid)) else None
    candidate = doc.get("candidate") if isinstance(doc.get("candidate"), dict) else {}
    workflow = candidate.get("workflow") if isinstance(candidate.get("workflow"), str) else None
    subject = candidate.get("subject") if isinstance(candidate.get("subject"), dict) else None
    provisional = bool(candidate.get("provisional", False))
    evidence = str(candidate.get("invocation_evidence") or "")
    started_at = doc.get("submitted_at") if isinstance(doc.get("submitted_at"), str) else None

    # Eligibility (local): exact slash-command/command-markup starts confirmed;
    # embedded candidates provisional unless Skill corroboration (checked later);
    # unknown manifest -> eligibility_unknown.
    if not workflow or workflow not in registry:
        state = ELIGIBILITY_INELIGIBLE
        ev_text = evidence or f"workflow {workflow!r} not in registry (non-agent or unregistered)"
    elif provisional:
        state = ELIGIBILITY_PROVISIONAL
        ev_text = evidence or "embedded first-message candidate; provisional pending Skill corroboration"
    else:
        state = ELIGIBILITY_CONFIRMED
        ev_text = evidence or "exact slash-command or command-markup start"

    host_profile = _host_profile_from_manifest(doc)
    identity = {
        "session_id": sid,
        "project_path": _hashed_if_present(doc.get("cwd")),
        "started_at": started_at,
    }
    return EligibleLifecycle(
        source=SOURCE_LOCAL,
        surrogate_id=_surrogate_id(SOURCE_LOCAL, sid or "unknown", str(position), started_at or ""),
        consumer=workflow if workflow in registry else None,
        subject=subject,
        identity=identity,
        eligibility_state=state,
        eligibility_evidence=ev_text,
        host_profile=host_profile,
        source_status=SOURCE_ELIGIBLE_NOT_IMPORTED,  # default; left-join updates
        provenance={"manifest_session_id": sid},
    )


def _hashed_if_present(value: Any) -> str | None:
    # cwd encodes the repo path; never persist it raw — hash it for identity.
    if not isinstance(value, str) or not value:
        return None
    return _sha8(value)


def _host_profile_from_manifest(doc: dict) -> dict | None:
    profile: dict[str, Any] = {}
    for key in ("provider", "devflow_version", "claude_code_version"):
        v = doc.get(key)
        if isinstance(v, str) and v:
            profile[key] = v
    me = doc.get("model_effort") if isinstance(doc.get("model_effort"), dict) else {}
    if isinstance(me.get("requested_model"), str):
        profile["model"] = me["requested_model"]
    git = doc.get("git") if isinstance(doc.get("git"), dict) else {}
    if isinstance(git.get("branch"), str):
        profile["branch"] = git["branch"]
    if isinstance(doc.get("cwd"), str):
        # host OS is not derivable without a subprocess; record unknown explicitly.
        profile["host_os"] = "unknown"
    return profile or None


# --------------------------------------------------------------------------- #
# Local native import left-join + source missingness.
# --------------------------------------------------------------------------- #
def join_local_imports(rows: list[EligibleLifecycle], bundles_dir: Path, max_bytes: int) -> list[EligibleLifecycle]:
    """Left-join imported bundles onto local census rows; set source_status."""
    out: list[EligibleLifecycle] = []
    for row in rows:
        if row.source != SOURCE_LOCAL:
            out.append(row)
            continue
        sid = row.identity.get("session_id")
        if not sid:
            row.source_status = SOURCE_MISSING
            out.append(row)
            continue
        bundle = bundles_dir / sid
        status = _classify_source_status(bundle, max_bytes)
        row.source_status = status
        out.append(row)
    return out


def _classify_source_status(bundle: Path, max_bytes: int) -> str:
    if not bundle.exists() or not bundle.is_dir():
        return SOURCE_ELIGIBLE_NOT_IMPORTED
    metadata = bundle / "metadata.json"
    transcript = bundle / "transcript.jsonl"
    if metadata.exists():
        try:
            meta = json.loads(metadata.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            meta = {}
        if not isinstance(meta, dict):
            meta = {}
        sv = meta.get("schema_version")
        # Bundle metadata is schema_version 2 (recorder contract). Anything else
        # is unsupported — a denominator row, never a clean classification.
        if sv not in (2,):
            return SOURCE_UNSUPPORTED
    else:
        # Legacy/absent metadata -> treat as unsupported source version.
        return SOURCE_UNSUPPORTED
    if not transcript.exists():
        # A stop-attempts failure with no transcript -> import_failed.
        if _import_failed(bundle):
            return SOURCE_IMPORT_FAILED
        return SOURCE_MISSING
    try:
        size = transcript.stat().st_size
    except OSError:
        return SOURCE_UNREADABLE
    if size > max_bytes:
        # Source-level limit breach -> denominator row with a visible reason;
        # never truncates into a clean classification.
        return SOURCE_UNSUPPORTED
    if size == 0:
        # An empty transcript is available but event-less (no launches); it is
        # not unreadable — the import succeeded, the session was simply empty.
        return SOURCE_AVAILABLE
    try:
        transcript.read_bytes()  # parseable check (parse_events validates JSONL)
    except OSError:
        return SOURCE_UNREADABLE
    # Final parse check: malformed JSONL -> unreadable, not missing.
    try:
        wfr.parse_events(transcript.read_bytes())
    except ValueError:
        return SOURCE_UNREADABLE
    if _import_failed(bundle):
        return SOURCE_IMPORT_FAILED
    return SOURCE_AVAILABLE


def _import_failed(bundle: Path) -> bool:
    attempts = bundle / "stop-attempts.jsonl"
    if not attempts.exists():
        return False
    saw_success = False
    saw_error = False
    try:
        for line in attempts.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(entry, dict):
                continue
            if entry.get("error"):
                saw_error = True
            if entry.get("bytes_verified") is True or entry.get("ok") is True:
                saw_success = True
    except OSError:
        return False
    return saw_error and not saw_success


# --------------------------------------------------------------------------- #
# Verification request + process-launch extraction (local-native only).
# --------------------------------------------------------------------------- #
def _classify_taxonomy(command: str) -> str:
    if any(pat.search(command) for pat in VERIFICATION_PATTERNS):
        return KIND_VERIFICATION
    head = command.strip().split()[0] if command.strip() else ""
    # Strip a leading env-assignment prefix to find the real head (e.g. FOO=bar baz).
    while "=" in head and not head.startswith("/") and not head.startswith("-"):
        rest = command.strip().split(None, 1)
        if len(rest) < 2:
            break
        command = rest[1]
        head = command.strip().split()[0] if command.strip() else ""
    if head in NON_VERIFICATION_HEADS:
        return KIND_OTHER_COMMAND
    return KIND_VERIFICATION_UNKNOWN


def _command_head(command: str) -> str:
    canonical = _canonical_command(command)
    parts = canonical.split(" ", 1) if canonical else []
    head = parts[0] if parts else ""
    # Bound the head (local record only) and strip env-assignment prefixes.
    while head and "=" in head and not head.startswith("/") and not head.startswith("-"):
        rest = canonical.split(None, 1)
        if len(rest) < 2:
            return head
        canonical = rest[1]
        head = canonical.split(" ", 1)[0] if canonical else ""
    return head[:120]


def _result_for(events: list, tool_use_id: str) -> "dict | None":
    for event in events:
        content = event.raw.get("message", {}).get("content") if isinstance(event.raw.get("message"), dict) else None
        if not isinstance(content, list):
            continue
        for item in content:
            if isinstance(item, dict) and item.get("type") == "tool_result" and item.get("tool_use_id") == tool_use_id:
                return item
    return None


def _exit_evidence(result: dict | None) -> "dict | None":
    if not result:
        return None
    is_error = bool(result.get("is_error", False))
    content = result.get("content")
    text = ""
    if isinstance(content, str):
        text = content
    elif isinstance(content, list):
        text = "\n".join(p.get("text", "") for p in content if isinstance(p, dict) and isinstance(p.get("text"), str))
    # Exit-code heuristic: search for a trailing nonzero code in common shapes.
    # Observational only — never used to predict authorization.
    exit_code: int | None = None
    m = re.search(r"(?:exit code|exit|rc)\s*[:=]?\s*(-?\d+)", text, re.IGNORECASE)
    if m:
        try:
            exit_code = int(m.group(1))
        except ValueError:
            exit_code = None
    return {"is_error": is_error, "exit_code": exit_code, "terminal_signal_present": bool(text.strip())}


def _classify_authorization_start(tool_use_id: str, events: list) -> str:
    """Per-source versioned adapter (Wave 1: native Claude transcripts)."""
    result = _result_for(events, tool_use_id)
    if result is None:
        # No result observed -> the request may have been denied or cancelled
        # pre-start, or the transcript is truncated. Conservative: start_unknown.
        return START_UNKNOWN
    # An explicit permission-denial in the result -> denied_pre_start.
    content = result.get("content")
    text = ""
    if isinstance(content, str):
        text = content
    elif isinstance(content, list):
        text = "\n".join(p.get("text", "") for p in content if isinstance(p, dict) and isinstance(p.get("text"), str))
    if result.get("is_error") and re.search(r"permission\s+denied|not\s+allowed|was\s+not\s+granted", text, re.IGNORECASE):
        return START_DENIED_PRE
    # A result that indicates cancellation (e.g. "command was cancelled").
    if re.search(r"\bcancel\w*|\binterrupt\w*|\babort\w*", text, re.IGNORECASE):
        return START_CANCELLED_PRE
    # Terminal result with exit evidence -> start_confirmed_terminal.
    ev = _exit_evidence(result)
    if ev and ev.get("terminal_signal_present"):
        if ev.get("exit_code") is None:
            return START_CONFIRMED_RESULT_MISSING
        return START_CONFIRMED_TERMINAL
    return START_UNKNOWN


def _only_explicit_process_start(result: dict | None) -> bool:
    """Only explicit evidence that the execution surface started a process
    creates a launch. A tool_result with terminal content is explicit; absence
    or a pure denial/cancel is not."""
    if not result:
        return False
    ev = _exit_evidence(result)
    return bool(ev and ev.get("terminal_signal_present"))


def _workspace_state(events: list, start_idx: int, end_idx: int) -> dict:
    """Coverage from explicit source-event results, NOT analyzer-time inspection.

    A complete workspace_state requires explicit coverage of HEAD, index,
    submodules, all tracked files, all untracked files, and each
    ignored/generated/dependency root. Native transcripts almost never carry
    such an enumeration around a verification command, so the conservative
    default is coverage=incomplete -> relationship unclassifiable
    (mutation_state_unbounded). This is the conservative bias the issue demands:
    never claim a stable workspace without explicit evidence.
    """
    covered: set[str] = set()
    for event in events[start_idx : end_idx + 1]:
        content = event.raw.get("message", {}).get("content") if isinstance(event.raw.get("message"), dict) else None
        if not isinstance(content, list):
            continue
        for item in content:
            if not isinstance(item, dict) or item.get("type") != "tool_result":
                continue
            text = ""
            c = item.get("content")
            if isinstance(c, str):
                text = c
            elif isinstance(c, list):
                text = "\n".join(p.get("text", "") for p in c if isinstance(p, dict) and isinstance(p.get("text"), str))
            lower = text.lower()
            if "head " in lower or "head\t" in lower or lower.startswith("head "):
                covered.add("head")
            if "index" in lower:
                covered.add("index")
            if "submodule" in lower:
                covered.add("submodule")
            if "untracked" in lower:
                covered.add("untracked")
            if "tracked" in lower:
                covered.add("tracked")
            # ignored/generated/dependency root: covered when a result explicitly
            # enumerates ignored files OR a generated/dependency root path.
            if "ignored" in lower or any(
                marker in lower for marker in ("node_modules", "target/", "dist/", "build/", "__pycache__", ".venv", "venv/")
            ):
                covered.add("ignored_gen_dep")
    # A complete enumeration would require explicit coverage of ALL six roots
    # (head, index, submodule, tracked, untracked, ignored/generated/dependency).
    # The ignored/generated/dependency root is never explicitly observable from
    # a verification command's source-event results in Wave 1, so coverage is
    # incomplete by construction unless all six are present.
    required = {"head", "index", "submodule", "tracked", "untracked", "ignored_gen_dep"}
    if "ignored_gen_dep" not in covered:
        # No native source-event result explicitly enumerates ignored/generated/
        # dependency roots for a verification command in Wave 1 -> unbounded.
        coverage = "incomplete"
    else:
        coverage = "complete" if required.issubset(covered) else "incomplete"
    return {
        "covered_roots": sorted(covered),
        "observation_method": "source_event_results",
        "coverage": coverage,
        "mutation_state_unbounded": coverage == "incomplete",
    }


def extract_verification_lifecycles(
    rows: list[EligibleLifecycle], bundles_dir: Path, registry: dict, max_bytes: int
) -> "tuple[list[VerificationRequest], list[VerificationProcessLaunch], list[EligibleLifecycle]]":
    """Extract verification requests + process launches from source_available
    local lifecycles. Returns (requests, launches, updated_rows)."""
    requests: list[VerificationRequest] = []
    launches: list[VerificationProcessLaunch] = []
    for row in rows:
        if row.source != SOURCE_LOCAL or row.source_status != SOURCE_AVAILABLE:
            continue
        sid = row.identity.get("session_id")
        if not sid:
            continue
        bundle = bundles_dir / sid
        transcript = bundle / "transcript.jsonl"
        try:
            raw = transcript.read_bytes()
        except OSError:
            row.source_status = SOURCE_UNREADABLE
            continue
        if len(raw) > max_bytes:
            row.source_status = SOURCE_UNSUPPORTED
            continue
        if not raw.strip():
            # Empty transcript: available, but no events to extract.
            continue
        try:
            events = wfr.parse_events(raw)
        except ValueError:
            row.source_status = SOURCE_UNREADABLE
            continue
        occurrences = wfr.detect_occurrences(events, registry)
        # Use the manifest's consumer to scope the root occurrence; fall back to
        # the first top-level occurrence of any registered workflow.
        root = _select_root_occurrence(occurrences, row.consumer)
        if root is None:
            continue
        end_idx = root.end_event if root.end_event is not None else (len(events) - 1)
        row.provenance["lifecycle_id"] = root.occurrence_id
        reqs, launches_in = _extract_from_lifecycle(events, root, end_idx, sid, row.consumer)
        requests.extend(reqs)
        launches.extend(launches_in)
    return requests, launches, rows


def _select_root_occurrence(occurrences: list, consumer: str | None):
    if consumer:
        for occ in occurrences:
            if occ.workflow == consumer and occ.mode == "top-level":
                return occ
    for occ in occurrences:
        if occ.mode == "top-level":
            return occ
    return occurrences[0] if occurrences else None


def _extract_from_lifecycle(events, root, end_idx, sid, consumer):
    requests: list[VerificationRequest] = []
    launches: list[VerificationProcessLaunch] = []
    for event in events[root.start_event : end_idx + 1]:
        if (event.role or event.raw.get("type")) != "assistant":
            continue
        for tool_use in event.tool_uses:
            if tool_use.get("name") != "Bash":
                continue
            inputs = tool_use.get("input") if isinstance(tool_use.get("input"), dict) else {}
            command = inputs.get("command") if isinstance(inputs.get("command"), str) else ""
            if not command:
                continue
            tool_use_id = str(tool_use.get("id") or "")
            req_id = _surrogate_id("req", sid, str(event.index), tool_use_id)
            binding = _binding_identity(command)
            result = _result_for(events, tool_use_id)
            auth = _classify_authorization_start(tool_use_id, events)
            req_timing = {
                "requested_at": _ms_to_iso(event.timestamp_ms),
                "started_at": None,
                "finished_at": None,
                "duration_ms": None,
            }
            req = VerificationRequest(
                request_id=req_id,
                source_event_id=_source_event_id(sid, event.index),
                lifecycle_id=root.occurrence_id,
                tool_use_id=tool_use_id,
                consumer_skill=consumer,
                phase_checkpoint=None,  # Wave 1: not explicitly extracted
                command_head=_command_head(command),
                binding=binding,
                request_kind=_classify_taxonomy(command),
                authorization_start=auth,
                timing=req_timing,
                result_presence=result is not None,
                exit_evidence=_exit_evidence(result),
                skipped_check_evidence=None,
                provenance={"session_id": sid, "event_index": event.index},
            )
            requests.append(req)
            # Only explicit process-start evidence creates a launch, and only for
            # confirmed verification commands; other_command/verification_unknown
            # are request metrics only (excluded from actual-launch counts).
            if req.request_kind == KIND_VERIFICATION and _only_explicit_process_start(result) and auth in (START_CONFIRMED_TERMINAL, START_CONFIRMED_RESULT_MISSING):
                launch_id = _surrogate_id("launch", sid, str(event.index), tool_use_id)
                result_event = _find_result_event(events, tool_use_id)
                launch_timing = _launch_timing(event, result_event)
                ws = _workspace_state(events, root.start_event, end_idx)
                launches.append(VerificationProcessLaunch(
                    launch_id=launch_id,
                    request_id=req_id,
                    source_event_id=_source_event_id(sid, event.index),
                    lifecycle_id=root.occurrence_id,
                    tool_use_id=tool_use_id,
                    consumer_skill=consumer,
                    phase_checkpoint=None,
                    command_head=_command_head(command),
                    binding=binding,
                    start_authorization=auth,
                    timing=launch_timing,
                    workspace_state=ws,
                    result_presence=result is not None,
                    exit_evidence=_exit_evidence(result),
                    skipped_check_evidence=None,
                    provenance={"session_id": sid, "event_index": event.index},
                ))
    return requests, launches


def _find_result_event(events, tool_use_id: str):
    """The event whose content carries the tool_result for tool_use_id, or None."""
    for event in events:
        content = event.raw.get("message", {}).get("content") if isinstance(event.raw.get("message"), dict) else None
        if not isinstance(content, list):
            continue
        for item in content:
            if isinstance(item, dict) and item.get("type") == "tool_result" and item.get("tool_use_id") == tool_use_id:
                return event
    return None


def _launch_timing(tool_use_event, result_event) -> dict:
    """started_at from the tool_use event; finished_at/duration from the result
    event's timestamp — explicit source-event timing only, not analyzer-time
    inspection. Unknown stays None, never 0."""
    started = _ms_to_iso(tool_use_event.timestamp_ms)
    finished = _ms_to_iso(result_event.timestamp_ms) if result_event is not None else None
    duration_ms = None
    if tool_use_event.timestamp_ms is not None and result_event is not None and result_event.timestamp_ms is not None:
        duration_ms = result_event.timestamp_ms - tool_use_event.timestamp_ms
        if duration_ms < 0:
            duration_ms = None
    return {
        "started_at": started,
        "finished_at": finished,
        "duration_ms": duration_ms,
        "caller_observed_duration_ms": duration_ms,
    }


# --------------------------------------------------------------------------- #
# Join confidence — only explicit lifecycle+source-event IDs produce exact.
# --------------------------------------------------------------------------- #
def join_confidence(launch_a: VerificationProcessLaunch, launch_b: VerificationProcessLaunch) -> str:
    # Only explicit lifecycle + source-event identity produces exact; guessed
    # joins are forbidden.
    if launch_a.source_event_id and launch_b.source_event_id and launch_a.source_event_id == launch_b.source_event_id:
        return CONFIDENCE_EXACT
    if launch_a.lifecycle_id and launch_b.lifecycle_id and launch_a.lifecycle_id == launch_b.lifecycle_id:
        if launch_a.binding.digest == launch_b.binding.digest:
            # Secret-affected: a redacted digest alone cannot establish an exact
            # match; requires the same explicit source correlation (distinct
            # source events here) -> partial, excluded from retry-candidate counts.
            if launch_a.binding.secret_affected or launch_b.binding.secret_affected:
                return CONFIDENCE_PARTIAL
            return CONFIDENCE_EXACT
        return CONFIDENCE_AMBIGUOUS
    if launch_a.binding.digest == launch_b.binding.digest:
        # Same binding but distinct lifecycle -> partial (never exact without
        # explicit lifecycle+source identity; guessed joins are forbidden).
        return CONFIDENCE_PARTIAL
    return CONFIDENCE_UNMATCHED


# --------------------------------------------------------------------------- #
# Relationship grouping + classification (conservative: never auto-prove dupes).
# --------------------------------------------------------------------------- #
def group_launches(launches: list[VerificationProcessLaunch]) -> list[RelationshipGroup]:
    """Repeated-binding groups: launches sharing a binding digest."""
    buckets: dict[str, list[VerificationProcessLaunch]] = {}
    order: list[str] = []
    for launch in launches:
        key = launch.binding.digest
        if key not in buckets:
            buckets[key] = []
            order.append(key)
        buckets[key].append(launch)
    groups: list[RelationshipGroup] = []
    for key in order:
        members = buckets[key]
        relationship, confidence = _classify_relationship(members)
        durations = [m.timing.get("duration_ms") for m in members if isinstance(m.timing.get("duration_ms"), int)]
        group_duration = max(durations) if durations else None
        ws = _merge_workspace_state(members)
        groups.append(RelationshipGroup(
            group_id=_surrogate_id("grp", key, members[0].lifecycle_id or "multi"),
            members=[m.launch_id for m in members],
            relationship=relationship,
            join_confidence=confidence,
            workspace_state=ws,
            binding_digest=key,
            consumer=members[0].consumer_skill,
            duration_ms=group_duration,
            provenance={"binding_digest": key, "member_count": len(members)},
        ))
    return groups


def _classify_relationship(members: list[VerificationProcessLaunch]) -> "tuple[str, str]":
    if len(members) == 1:
        return REL_SINGLE, CONFIDENCE_EXACT
    # A redacted digest alone cannot establish an exact binding match: secret-
    # affected groups are excluded from retry-candidate counts (partial confidence).
    if any(m.binding.secret_affected for m in members):
        return REL_UNCLASSIFIABLE, CONFIDENCE_PARTIAL
    # Explicit retrigger evidence (distinct lifecycle IDs, explicit iterations,
    # explicit checkpoints, post-fix commits, base merges, human retriggers)
    # cannot be transport-retry candidates. Wave 1 detects none explicitly, so
    # this branch is conservative: it stays inert unless a future adapter marks
    # retrigger evidence on a member.
    if any(_has_explicit_retrigger(m) for m in members):
        return REL_INTENTIONAL_RERUN, CONFIDENCE_PARTIAL
    lifecycles = {m.lifecycle_id for m in members if m.lifecycle_id}
    if len(lifecycles) > 1:
        # Distinct lifecycle IDs -> independent (cannot be transport-retry).
        return REL_INDEPENDENT_LIFECYCLE, CONFIDENCE_PARTIAL
    # Same lifecycle, repeated binding -> candidate transport-retry only if ALL
    # requirements hold; else unclassifiable.
    any_unbounded = any(m.workspace_state.get("mutation_state_unbounded") for m in members)
    if any_unbounded:
        return REL_UNCLASSIFIABLE, CONFIDENCE_AMBIGUOUS
    ws_complete = all(m.workspace_state.get("coverage") == "complete" for m in members)
    ws_roots = {tuple(m.workspace_state.get("covered_roots", [])) for m in members}
    ws_matching = ws_complete and len(ws_roots) == 1
    if not ws_matching:
        return REL_UNCLASSIFIABLE, CONFIDENCE_AMBIGUOUS
    has_prior_missing = any(
        m.start_authorization in (START_DENIED_PRE, START_CANCELLED_PRE, START_CONFIRMED_RESULT_MISSING, START_UNKNOWN)
        or m.result_presence is False
        for m in members
    )
    bounded = [m for m in members if m.timing.get("started_at") and m.timing.get("finished_at")]
    interval_bounded = len(bounded) >= 2
    # No explicit new iteration/checkpoint/retrigger evidence (Wave 1: none).
    no_retrigger = not any(_has_explicit_retrigger(m) for m in members)
    if has_prior_missing and interval_bounded and ws_matching and no_retrigger:
        return REL_CANDIDATE_TRANSPORT_RETRY, CONFIDENCE_EXACT
    return REL_UNCLASSIFIABLE, CONFIDENCE_AMBIGUOUS


def _has_explicit_retrigger(launch: VerificationProcessLaunch) -> bool:
    # Wave 1 extraction never sets this True from native events (no explicit
    # iteration/checkpoint/post-fix/base-merge/human-retrigger markers are
    # extracted), so retrigger evidence is never fabricated. The field carries
    # the no-retrigger guard the candidate classification requires, and is the
    # hook a future versioned adapter records retrigger evidence into.
    return bool(launch.retrigger_evidence)


def _merge_workspace_state(members: list[VerificationProcessLaunch]) -> dict:
    covered: set[str] = set()
    for m in members:
        covered.update(m.workspace_state.get("covered_roots", []))
    coverages = {m.workspace_state.get("coverage") for m in members}
    coverage = "complete" if coverages == {"complete"} else "incomplete"
    return {
        "covered_roots": sorted(covered),
        "observation_method": "source_event_results",
        "coverage": coverage,
        "mutation_state_unbounded": coverage == "incomplete",
    }


# --------------------------------------------------------------------------- #
# Metrics (unknown stays unknown — null/unavailable, never 0).
# --------------------------------------------------------------------------- #
def compute_metrics(
    rows: list[EligibleLifecycle],
    requests: list[VerificationRequest],
    launches: list[VerificationProcessLaunch],
    groups: list[RelationshipGroup],
    has_cloud_snapshot: bool,
) -> dict[str, Any]:
    def count_by(values):
        tally: dict[str, int] = {}
        for v in values:
            tally[str(v)] = tally.get(str(v), 0) + 1
        return tally

    eligibility_bounds = {s: 0 for s in ELIGIBILITY_STATES}
    for row in rows:
        eligibility_bounds[row.eligibility_state] = eligibility_bounds.get(row.eligibility_state, 0) + 1

    source_missingness = {s: 0 for s in LOCAL_SOURCE_STATUSES}
    source_missingness[SOURCE_UNAVAILABLE] = 0
    for row in rows:
        if row.source == SOURCE_LOCAL:
            source_missingness[row.source_status] = source_missingness.get(row.source_status, 0) + 1
        else:
            source_missingness[SOURCE_UNAVAILABLE] = source_missingness.get(SOURCE_UNAVAILABLE, 0) + (0 if row.source_status == "available" else 1)

    actual_launches = [
        l for l in launches
        if l.start_authorization in (START_CONFIRMED_TERMINAL, START_CONFIRMED_RESULT_MISSING)
    ]
    terminal_results = sum(1 for l in actual_launches if l.exit_evidence and l.exit_evidence.get("exit_code") is not None)
    missing_results = sum(1 for l in launches if l.start_authorization == START_CONFIRMED_RESULT_MISSING)

    rel_dist = {r: 0 for r in RELATIONSHIP_CLASSES}
    for g in groups:
        rel_dist[g.relationship] = rel_dist.get(g.relationship, 0) + 1

    ws_dist = {"complete": 0, "incomplete": 0}
    for g in groups:
        cov = g.workspace_state.get("coverage", "incomplete")
        ws_dist[cov] = ws_dist.get(cov, 0) + 1

    join_dist = {c: 0 for c in CONFIDENCE_CLASSES}
    for g in groups:
        join_dist[g.join_confidence] = join_dist.get(g.join_confidence, 0) + 1

    command_heads = count_by(l.command_head for l in launches)
    consumers = count_by((l.consumer_skill or "unknown") for l in launches)

    candidate_group_durations = [g.duration_ms for g in groups if g.relationship == REL_CANDIDATE_TRANSPORT_RETRY and isinstance(g.duration_ms, int)]
    estimated_wall = sum(candidate_group_durations) if candidate_group_durations else None

    return {
        "eligible_lifecycles": len(rows),
        "eligibility_state_bounds": eligibility_bounds,
        "source_availability_and_missingness": source_missingness,
        "local_actual_launches": len(actual_launches),
        "terminal_results": terminal_results,
        "missing_results": missing_results,
        "repeated_binding_groups": sum(1 for g in groups if len(g.members) > 1),
        "candidate_retries": rel_dist[REL_CANDIDATE_TRANSPORT_RETRY],
        "intentional_rerun_evidence": rel_dist[REL_INTENTIONAL_RERUN],
        "independent_lifecycles": rel_dist[REL_INDEPENDENT_LIFECYCLE],
        "unclassifiable_groups": rel_dist[REL_UNCLASSIFIABLE],
        "single_groups": rel_dist[REL_SINGLE],
        "workspace_coverage_distribution": ws_dist,
        "join_confidence_distribution": join_dist,
        "command_heads": command_heads,
        "consumers_checkpoints": consumers,
        "provenance": {
            "local_manifests": sum(1 for r in rows if r.source == SOURCE_LOCAL),
            "local_bundles_available": sum(1 for r in rows if r.source == SOURCE_LOCAL and r.source_status == SOURCE_AVAILABLE),
            "cloud_snapshot": has_cloud_snapshot,
        },
        "host_profile": _aggregate_host_profile(rows),
        "child_duration_ms": None,  # unknown in Wave 1 (no child-process timing in native events)
        "caller_observed_duration_ms": [l.timing.get("duration_ms") for l in launches if isinstance(l.timing.get("duration_ms"), int)] or None,
        "estimated_repeated_suite_wall_time_ms": estimated_wall,
        "verification_requests": len(requests),
        "verification_process_launches": len(launches),
        # Unknown-is-not-zero: a count that could not be established is null, never 0.
        "notes": "unknown values are null/unavailable, never zero; candidate_retries is a conservative candidate count, not confirmed duplicates",
    }


def _aggregate_host_profile(rows: list[EligibleLifecycle]) -> dict[str, Any]:
    agg: dict[str, set[str]] = {}
    for row in rows:
        if not row.host_profile:
            continue
        for key, value in row.host_profile.items():
            if isinstance(value, str) and value:
                agg.setdefault(key, set()).add(value)
    return {k: sorted(v) for k, v in agg.items()} or {"note": "no host_profile observed"}


# --------------------------------------------------------------------------- #
# Manual-review sampling (deterministic: SHA-256(snapshot_hash || group_id)).
# --------------------------------------------------------------------------- #
def manual_review_sample(groups: list[RelationshipGroup], snapshot_hash: str) -> dict[str, Any]:
    # Sampling unit = relationship groups with >1 member (repeated-binding groups
    # — the only ones that could be retries). Single-launch groups cannot be retries.
    population = [g for g in groups if len(g.members) > 1]
    if not population:
        return {
            "seed": snapshot_hash,
            "eligible_population": [],
            "high_cost_ids": [],
            "remainder_selected_ids": [],
            "selected_ids": [],
            "nonresponses": {},
            "adjudication_totals": {v: 0 for v in ADJUDICATION_VERDICTS},
        }
    n = len(population)
    durations = sorted((g.duration_ms for g in population if isinstance(g.duration_ms, int)), reverse=True)
    decile_count = max(1, math.ceil(0.1 * n))
    if durations:
        threshold = durations[min(decile_count, len(durations)) - 1]
    else:
        threshold = None
    if threshold is not None:
        high_cost = [g for g in population if isinstance(g.duration_ms, int) and g.duration_ms >= threshold]
    else:
        high_cost = []
    high_cost_ids = {g.group_id for g in high_cost}
    remainder = [g for g in population if g.group_id not in high_cost_ids]
    sample_size = min(50, max(20, math.ceil(0.1 * len(remainder)))) if remainder else 0
    sample_size = min(sample_size, len(remainder))

    def sort_key(g: RelationshipGroup) -> str:
        return hashlib.sha256((snapshot_hash + g.group_id).encode("utf-8")).hexdigest()

    remainder_sorted = sorted(remainder, key=sort_key)
    remainder_selected = remainder_sorted[:sample_size]
    return {
        "seed": snapshot_hash,
        "eligible_population": [g.group_id for g in population],
        "high_cost_ids": [g.group_id for g in high_cost],
        "remainder_selected_ids": [g.group_id for g in remainder_selected],
        "selected_ids": [g.group_id for g in high_cost] + [g.group_id for g in remainder_selected],
        "nonresponses": {},
        "adjudication_totals": {v: 0 for v in ADJUDICATION_VERDICTS},
    }


# --------------------------------------------------------------------------- #
# Stratification (incomplete strata marked non-comparable).
# --------------------------------------------------------------------------- #
def stratify(launches: list[VerificationProcessLaunch], rows: list[EligibleLifecycle]) -> dict[str, Any]:
    host_by_sid: dict[str | None, dict[str, Any]] = {}
    for row in rows:
        if row.source == SOURCE_LOCAL and row.identity.get("session_id"):
            host_by_sid[row.identity["session_id"]] = row.host_profile or {}

    def dims_for(launch: VerificationProcessLaunch) -> dict[str, str | None]:
        hp = host_by_sid.get(launch.provenance.get("session_id"), {})
        return {
            "consumer_checkpoint": launch.consumer_skill,
            "command_binding": launch.binding.digest,
            "host_profile": hp.get("host_os"),
            "repository_size_bucket": None,  # unknown without a subprocess
            "duration_bucket": _duration_bucket(launch.timing.get("duration_ms")),
            "model": hp.get("model"),
            "effort": None,  # not extracted in Wave 1
            "output_style": None,  # not extracted in Wave 1
            "prompt_fingerprint": None,  # not extracted in Wave 1
            "devflow_version": hp.get("devflow_version"),
            "claude_action_version": hp.get("claude_code_version"),
            "provider": hp.get("provider"),
        }

    strata: dict[str, list[str]] = {}
    incomplete = 0
    for launch in launches:
        dims = dims_for(launch)
        if any(v is None for v in dims.values()):
            incomplete += 1
        key = json.dumps(dims, sort_keys=True, separators=(",", ":"))
        strata.setdefault(key, []).append(launch.launch_id)
    return {
        "strata_count": len(strata),
        "strata": {k: len(v) for k, v in strata.items()},
        "incomplete_strata_launches": incomplete,
        "non_comparable_note": "incomplete strata (any null dimension) are non-comparable; captured-only rows are never the eligible-lifecycle denominator",
    }


def _duration_bucket(ms: Any) -> "str | None":
    if not isinstance(ms, int):
        return None
    if ms < 10_000:
        return "<10s"
    if ms < 60_000:
        return "10s-1m"
    if ms < 300_000:
        return "1m-5m"
    if ms < 600_000:
        return "5m-10m"
    return ">10m"


# --------------------------------------------------------------------------- #
# Cloud census reader (snapshot is metadata-only; no launch/duration claims).
# --------------------------------------------------------------------------- #
CLOUD_SNAPSHOT_SCHEMA = 1


def read_cloud_census(snapshot_path: Path) -> dict[str, Any] | None:
    """Read an explicit Actions run/job census snapshot. Returns None when the
    snapshot is absent/unreadable — cloud coverage then reads unavailable,
    never zero."""
    if snapshot_path is None:
        return None
    try:
        doc = json.loads(snapshot_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(doc, dict) or doc.get("schema_version") != CLOUD_SNAPSHOT_SCHEMA:
        return None
    return doc


def build_cloud_census(snapshot: dict[str, Any] | None, cloud_mappings: dict[str, dict[str, str]]) -> "tuple[list[EligibleLifecycle], dict[str, Any]]":
    rows: list[EligibleLifecycle] = []
    coverage: dict[str, Any] = {"available": False, "pagination_complete": None, "unavailable": True}
    if snapshot is None:
        # Absent cloud census -> unavailable, never zero.
        return rows, coverage
    coverage["available"] = True
    coverage["unavailable"] = False
    coverage["pagination_complete"] = bool(snapshot.get("pagination_complete", False))
    coverage["snapshot_hash"] = snapshot.get("snapshot_hash")
    coverage["repository"] = snapshot.get("repository")
    coverage["query_time"] = snapshot.get("query_time")
    raw_rows = snapshot.get("rows")
    if not isinstance(raw_rows, list):
        # Incomplete cloud census -> unavailable.
        coverage["available"] = False
        coverage["unavailable"] = True
        coverage["reason"] = "snapshot rows missing or malformed"
        return rows, coverage
    position = 0
    for raw in raw_rows:
        if not isinstance(raw, dict):
            continue
        wf = raw.get("workflow_file")
        job = raw.get("job")
        key = f"{wf}\x1f{job}" if (isinstance(wf, str) and isinstance(job, str)) else ""
        mapping = cloud_mappings.get(key)
        repo = snapshot.get("repository") or raw.get("repository")
        run_id = raw.get("run_id")
        run_attempt = raw.get("run_attempt")
        started_at = raw.get("started_at") or raw.get("created_at")
        # Cloud eligibility: allowlisted (workflow_file, job) + scheduled/started
        # agent-step evidence (the job reached a scheduled/started state).
        status = str(raw.get("status") or "")
        scheduled_started = status in ("queued", "in_progress", "completed") or bool(started_at)
        if mapping is None:
            # Precheck/dedupe/telemetry/relay/skipped non-agent jobs: ineligible.
            state = ELIGIBILITY_INELIGIBLE
            evidence = f"job {job!r} not in cloud_mappings agent_jobs (non-agent)"
        elif not scheduled_started:
            state = ELIGIBILITY_INELIGIBLE
            evidence = "agent job present but no scheduled/started agent-step evidence"
        else:
            state = ELIGIBILITY_CONFIRMED
            evidence = f"allowlisted agent job {job!r} consumer={mapping.get('consumer')} routed={mapping.get('routed_command')}"
        rows.append(EligibleLifecycle(
            source=SOURCE_CLOUD,
            surrogate_id=_surrogate_id(SOURCE_CLOUD, str(repo), str(wf), str(job), str(run_id), str(run_attempt), str(position)),
            consumer=mapping.get("consumer") if mapping else None,
            subject=None,
            identity={
                "repository": repo,
                "workflow_file": wf,
                "run_id": run_id,
                "run_attempt": run_attempt,
                "job": job,
                "started_at": started_at,
            },
            eligibility_state=state,
            eligibility_evidence=evidence,
            host_profile={"conclusion": raw.get("conclusion"), "status": status} or None,
            source_status="available",
            provenance={"snapshot_hash": snapshot.get("snapshot_hash"), "run_id": run_id, "run_attempt": run_attempt},
        ))
        position += 1
    # Cloud rows report census/eligibility/missingness ONLY — no launch/duration/
    # relationship/retry-candidate claims are made here (cloud launch analysis is
    # excluded in Wave 1).
    return rows, coverage


# --------------------------------------------------------------------------- #
# Source snapshot hash + performance reporting.
# --------------------------------------------------------------------------- #
def compute_source_snapshot_hash(rows: list[EligibleLifecycle], cloud_snapshot: dict | None) -> str:
    parts: list[str] = []
    for row in sorted(rows, key=lambda r: r.surrogate_id):
        if row.source == SOURCE_LOCAL:
            parts.append(f"local:{row.identity.get('session_id')}:{row.source_status}:{row.eligibility_state}")
        else:
            parts.append(f"cloud:{row.identity.get('run_id')}:{row.identity.get('job')}:{row.eligibility_state}")
    if cloud_snapshot is not None:
        parts.append(f"snapshot:{cloud_snapshot.get('snapshot_hash')}")
    return _sha256_hex("\n".join(parts).encode("utf-8"))


# --------------------------------------------------------------------------- #
# Report generation (no over-claiming; cites source-event IDs only).
# --------------------------------------------------------------------------- #
def generate_report(baseline: "VerificationBaseline") -> str:
    m = baseline.metrics
    sample = baseline.manual_review_sample
    lines: list[str] = []
    lines.append("# Verification-launch baseline (Wave 1)")
    lines.append("")
    lines.append(f"- created_at: {baseline.created_at}")
    lines.append(f"- source_snapshot_hash: {baseline.source_snapshot_hash}")
    lines.append(f"- expires_at: {baseline.expires_at}")
    lines.append("")
    lines.append("## Census + eligibility (denominator)")
    lines.append(f"- eligible lifecycles: {m['eligible_lifecycles']}")
    bounds = m["eligibility_state_bounds"]
    lines.append(f"- eligibility bounds: confirmed={bounds.get(ELIGIBILITY_CONFIRMED, 0)} provisional={bounds.get(ELIGIBILITY_PROVISIONAL, 0)} ineligible={bounds.get(ELIGIBILITY_INELIGIBLE, 0)} unknown={bounds.get(ELIGIBILITY_UNKNOWN, 0)}")
    sm = m["source_availability_and_missingness"]
    lines.append(f"- source availability/missingness: available={sm.get(SOURCE_AVAILABLE, 0)} eligible_not_imported={sm.get(SOURCE_ELIGIBLE_NOT_IMPORTED, 0)} import_failed={sm.get(SOURCE_IMPORT_FAILED, 0)} source_missing={sm.get(SOURCE_MISSING, 0)} source_unreadable={sm.get(SOURCE_UNREADABLE, 0)} source_unsupported={sm.get(SOURCE_UNSUPPORTED, 0)} unavailable={sm.get(SOURCE_UNAVAILABLE, 0)}")
    if baseline.cloud_coverage.get("unavailable"):
        lines.append("- cloud coverage: unavailable (absent or incomplete cloud census; never zero)")
    else:
        lines.append(f"- cloud coverage: available (pagination_complete={baseline.cloud_coverage.get('pagination_complete')})")
    lines.append("")
    lines.append("## Local actual launches (observed)")
    lines.append(f"- verification requests: {m['verification_requests']}")
    lines.append(f"- confirmed process launches: {m['local_actual_launches']}")
    lines.append(f"- terminal results: {m['terminal_results']}; missing results: {m['missing_results']}")
    lines.append("")
    lines.append("## Repeated-binding relationship classification (conservative)")
    lines.append(f"- repeated-binding groups: {m['repeated_binding_groups']}")
    lines.append(f"- candidate_transport_retry: {m['candidate_retries']} (candidates, NOT confirmed duplicates)")
    lines.append(f"- intentional_rerun_evidence: {m['intentional_rerun_evidence']}")
    lines.append(f"- independent_lifecycle: {m['independent_lifecycles']}")
    lines.append(f"- unclassifiable: {m['unclassifiable_groups']}")
    lines.append(f"- single: {m['single_groups']}")
    lines.append(f"- workspace coverage: {m['workspace_coverage_distribution']}")
    lines.append(f"- join confidence: {m['join_confidence_distribution']}")
    est = m["estimated_repeated_suite_wall_time_ms"]
    lines.append(f"- estimated repeated-suite wall time (ms): {est if est is not None else 'unavailable'}")
    lines.append("")
    lines.append("## Manual-review sample")
    lines.append(f"- seed: {sample['seed']}")
    lines.append(f"- eligible population: {len(sample['eligible_population'])} groups")
    lines.append(f"- selected IDs: {len(sample['selected_ids'])} (high_cost={len(sample['high_cost_ids'])}, remainder={len(sample['remainder_selected_ids'])})")
    lines.append("- reviewers see cited source-event evidence without analyzer relationship labels; record confirmed_retry_pattern / intentional_rerun / insufficient_evidence per group")
    lines.append("")
    lines.append("## Evidence limitations")
    lines.append("- This baseline states observed counts and candidate counts only. It does NOT claim launches avoided, terminal evidence reusable, command authorization safe, or active recovery justified.")
    lines.append("- Cloud rows are census/missingness-only (cloud launch analysis is excluded in Wave 1: no durable redacted execution-event source exists without changing workflows).")
    lines.append("- Captured-only rows are never presented as the eligible-lifecycle denominator; provisional and unknown rows are never promoted to confirmed and never silently omitted.")
    lines.append("")
    lines.append("## Active-recovery gate (later issue)")
    lines.append("- A later LOCAL active-recovery issue requires: a complete local census snapshot, at least 90% local source-status resolution, no local missingness stratum above 20%, and at least two independently adjudicated confirmed patterns in the same proposed consumer/checkpoint/binding target, plus measured cost and a separately reviewed trusted-command and lifecycle design. One confirmation remains exploratory.")
    lines.append("- Cloud active recovery requires a separate evidence-source design and issue. This baseline authorizes no active behavior.")
    lines.append("")
    return "\n".join(lines)


# --------------------------------------------------------------------------- #
# Output bounding (defense-in-depth: bound string lengths before serialization).
# --------------------------------------------------------------------------- #
def _bound_strings(obj: Any, limit: int = 4000) -> Any:
    if isinstance(obj, str):
        return obj if len(obj) <= limit else obj[:limit] + "…<truncated>"
    if isinstance(obj, dict):
        return {k: _bound_strings(v, limit) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_bound_strings(v, limit) for v in obj]
    return obj


# --------------------------------------------------------------------------- #
# Baseline record + main.
# --------------------------------------------------------------------------- #
@dataclass
class VerificationBaseline:
    created_at: str
    source_snapshot_hash: str
    expires_at: str
    census: dict[str, Any]
    cloud_coverage: dict[str, Any]
    verification_requests: list[dict[str, Any]]
    verification_process_launches: list[dict[str, Any]]
    relationship_groups: list[dict[str, Any]]
    metrics: dict[str, Any]
    manual_review_sample: dict[str, Any]
    stratification: dict[str, Any]
    performance: dict[str, Any]
    schema_version: int = VERIFICATION_BASELINE_SCHEMA

    def to_dict(self) -> dict[str, Any]:
        return _bound_strings({
            "schema_version": self.schema_version,
            "created_at": self.created_at,
            "source_snapshot_hash": self.source_snapshot_hash,
            "expires_at": self.expires_at,
            "census": self.census,
            "cloud_coverage": self.cloud_coverage,
            "verification_requests": self.verification_requests,
            "verification_process_launches": self.verification_process_launches,
            "relationship_groups": self.relationship_groups,
            "metrics": self.metrics,
            "manual_review_sample": self.manual_review_sample,
            "stratification": self.stratification,
            "performance": self.performance,
        })


def _cleanup(out_dir: Path) -> int:
    """Delete baseline + manual-review artifacts without touching native sources."""
    if not out_dir.exists():
        return 0
    removed = 0
    for child in sorted(out_dir.iterdir()):
        if child.is_dir():
            for sub in sorted(child.iterdir()):
                if sub.is_file():
                    try:
                        sub.unlink()
                        removed += 1
                    except OSError:
                        pass
            try:
                child.rmdir()
                removed += 1
            except OSError:
                pass
        elif child.is_file():
            try:
                child.unlink()
                removed += 1
            except OSError:
                pass
    return removed


def main(argv: "list[str] | None" = None) -> int:
    parser = argparse.ArgumentParser(description="Offline verification-launch baseline analyzer (issue #527, Wave 1).")
    parser.add_argument("--manifests-dir", default=DEFAULT_MANIFESTS_DIR)
    parser.add_argument("--bundles-dir", default=DEFAULT_BUNDLES_DIR)
    parser.add_argument("--registry", default=DEFAULT_REGISTRY)
    parser.add_argument("--cloud-census", default=DEFAULT_CLOUD_SNAPSHOT)
    parser.add_argument("--out-dir", default=DEFAULT_OUT_DIR)
    parser.add_argument("--max-source-bytes", type=int, default=DEFAULT_MAX_SOURCE_BYTES)
    parser.add_argument("--ttl-seconds", type=int, default=DEFAULT_TTL_SECONDS)
    parser.add_argument("--cleanup", action="store_true", help="delete baseline + manual-review artifacts without touching native sources")
    args = parser.parse_args(argv)

    try:
        out_dir = _validate_admitted_path(args.out_dir)
        manifests_dir = _validate_admitted_path(args.manifests_dir)
        bundles_dir = _validate_admitted_path(args.bundles_dir)
        registry_path = _validate_admitted_path(args.registry, must_exist=True)
    except (ValueError, FileNotFoundError) as exc:
        print(f"devflow verification-baseline: path validation failed: {exc}", file=sys.stderr)
        return 2

    if args.cleanup:
        removed = _cleanup(out_dir)
        print(f"devflow verification-baseline: cleanup removed {removed} artifact(s) under {out_dir} (native sources untouched)")
        return 0

    tracemalloc.start()
    wall_start = time.monotonic()
    input_bytes = 0

    try:
        registry = wfr.load_registry(registry_path)
    except ValueError as exc:
        print(f"devflow verification-baseline: registry load failed: {exc}", file=sys.stderr)
        return 2
    cloud_mappings = load_cloud_mappings(registry_path)

    # 1. Local census (denominator, from start manifests).
    local_rows = build_local_census(manifests_dir, registry)
    for row in local_rows:
        input_bytes += len(row.eligibility_evidence.encode("utf-8"))

    # 2. Left-join local native imports + source missingness.
    local_rows = join_local_imports(local_rows, bundles_dir, args.max_source_bytes)

    # 3. Verification request + process-launch extraction (local-native only).
    requests, launches, local_rows = extract_verification_lifecycles(local_rows, bundles_dir, registry, args.max_source_bytes)

    # 4. Relationship grouping + classification.
    groups = group_launches(launches)

    # 5. Cloud census (census/missingness only; no launch claims).
    cloud_snapshot = None
    if args.cloud_census:
        try:
            cloud_path = _validate_admitted_path(args.cloud_census, must_exist=True)
            cloud_snapshot = read_cloud_census(cloud_path)
        except (ValueError, FileNotFoundError) as exc:
            print(f"devflow verification-baseline: cloud census read failed: {exc}", file=sys.stderr)
    cloud_rows, cloud_coverage = build_cloud_census(cloud_snapshot, cloud_mappings)

    all_rows = local_rows + cloud_rows
    has_cloud = cloud_snapshot is not None

    # 6. Metrics + sampling + stratification.
    metrics = compute_metrics(all_rows, requests, launches, groups, has_cloud)
    snapshot_hash = compute_source_snapshot_hash(all_rows, cloud_snapshot)
    sample = manual_review_sample(groups, snapshot_hash)
    stratification = stratify(launches, all_rows)

    # 7. Performance reporting.
    current, peak = tracemalloc.get_traced_memory()
    tracemalloc.stop()
    wall_ms = int((time.monotonic() - wall_start) * 1000)
    performance = {
        "analyzer_wall_time_ms": wall_ms,
        "peak_memory_bytes": peak,
        "input_bytes": input_bytes,
        "output_bytes": None,  # filled after serialization
        "lifecycle_count": len(all_rows),
        "event_count": None,  # not aggregated across sources in Wave 1 (per-source only)
        "skipped_unsupported_source_count": sum(1 for r in all_rows if r.source_status in (SOURCE_UNSUPPORTED, SOURCE_UNREADABLE)),
    }

    created_at = _now_iso()
    expires_at = _expires_at(created_at, args.ttl_seconds)

    baseline = VerificationBaseline(
        created_at=created_at,
        source_snapshot_hash=snapshot_hash,
        expires_at=expires_at,
        census={
            "local": [r.to_dict() for r in local_rows],
            "cloud": [r.to_dict() for r in cloud_rows],
        },
        cloud_coverage=cloud_coverage,
        verification_requests=[r.to_dict() for r in requests],
        verification_process_launches=[l.to_dict() for l in launches],
        relationship_groups=[g.to_dict() for g in groups],
        metrics=metrics,
        manual_review_sample=sample,
        stratification=stratification,
        performance=performance,
    )

    payload = json.dumps(baseline.to_dict(), indent=2, sort_keys=True).encode("utf-8")
    performance["output_bytes"] = len(payload)
    # Re-serialize with the now-known output_bytes.
    baseline.performance = performance
    payload = json.dumps(baseline.to_dict(), indent=2, sort_keys=True).encode("utf-8")

    report = generate_report(baseline)

    stamp = created_at.replace(":", "").replace(".", "").replace("-", "")[:14]
    out_subdir = out_dir / f"{stamp}-{snapshot_hash[:8]}"
    out_subdir.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(out_subdir, DIR_MODE)
    except OSError:
        pass
    _atomic_write(out_subdir / "verification_baseline.json", payload)
    _atomic_write(out_subdir / "report.md", report.encode("utf-8"))
    # Manual-review artifact (initially empty adjudication; reviewers fill it).
    _atomic_write(out_subdir / "manual_review.json", json.dumps(sample, indent=2, sort_keys=True).encode("utf-8"))

    print(f"devflow verification-baseline: wrote {out_subdir}/verification_baseline.json + report.md")
    print(f"  eligible lifecycles: {metrics['eligible_lifecycles']} | actual launches: {metrics['local_actual_launches']} | candidate retries: {metrics['candidate_retries']} | unclassifiable: {metrics['unclassifiable_groups']}")
    print(f"  wall {wall_ms}ms | peak {peak}B | output {len(payload)}B | skipped/unsupported {performance['skipped_unsupported_source_count']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
