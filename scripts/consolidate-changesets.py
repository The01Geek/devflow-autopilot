#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Consolidate pending ``.changeset/*.md`` files into a version bump + CHANGELOG entry.

DevFlow versions itself with changesets instead of editing ``.claude-plugin/plugin.json``
and ``CHANGELOG.md`` in every PR (see ``.changeset/README.md``). This helper runs at merge
time (push to ``main``) from the ``version-consolidate`` workflow (shipped at
``ci/version-consolidate.yml``, installed by a maintainer into ``.github/workflows/``):

  * globs every pending ``.changeset/*.md`` (ignoring ``README.md`` and any ``config.*``),
  * parses each file's ``bump:`` (required) + optional ``type:`` frontmatter and prose body,
  * computes the single highest pending bump (``patch`` < ``minor`` < ``major``),
  * rewrites ``.claude-plugin/plugin.json``'s ``version`` by that increment,
  * prepends a dated, PR-cited Keep-a-Changelog entry assembled from all the prose, and
  * deletes the consumed changeset files.

It writes nothing else — staging and the ``chore: bump version`` commit are the workflow's job.

Fail-closed contract: a malformed changeset (no frontmatter, missing/invalid ``bump``, an
unknown ``type``, or an empty prose body) aborts with exit 2 and a diagnostic naming the
offending file. All changesets are validated **before any file is modified**, so a malformed
changeset never causes a silent skip or a partial bump. Zero pending changesets is a clean
no-op: nothing is written and the exit code is 0.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from datetime import datetime, timezone

VALID_BUMPS = ("patch", "minor", "major")
_BUMP_RANK = {"patch": 0, "minor": 1, "major": 2}

# Keep-a-Changelog section names, in the canonical order they render within an entry.
CANONICAL_TYPES = ["Added", "Changed", "Deprecated", "Removed", "Fixed", "Security"]
_TYPE_BY_LOWER = {t.lower(): t for t in CANONICAL_TYPES}
DEFAULT_TYPE = "Changed"

VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")


class ChangesetError(Exception):
    """A malformed changeset or manifest — the fail-closed, name-the-file path."""


def _fatal(msg: str) -> "int":
    sys.stderr.write(f"consolidate-changesets.py: {msg}\n")
    return 2


def _is_consumable(name: str) -> bool:
    """A ``.changeset/*.md`` file that is a real changeset (only ``README.md`` is exempt).

    Every other ``*.md`` here is treated as a changeset — an unexpected one with no valid
    frontmatter fails the run loudly (naming it) rather than being silently skipped, which
    is the fail-closed behavior this tool wants. (The npm ``@changesets`` ``config.json`` is
    not markdown, so it is already excluded by the ``.md`` filter — no ``config.*`` special
    case is needed, and a broad one would silently drop a legitimately-named changeset.)
    """
    return name.lower() != "readme.md" and name.lower().endswith(".md")


def _split_frontmatter(path: str) -> "tuple[str, str]":
    """Return ``(frontmatter_text, body_text)`` for a changeset, or raise ChangesetError.

    The file MUST start with a ``---`` fence (a leading BOM or any other prefix defeats
    detection and is rejected loudly rather than silently mis-parsed).
    """
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    m = re.match(r"---[ \t]*\n(.*?)\n---[ \t]*\n?(.*)\Z", text, re.DOTALL)
    if not m:
        raise ChangesetError(
            f"{path}: no YAML frontmatter found — a changeset must start with a "
            "'---' fenced block declaring 'bump:' (a leading BOM or blank line "
            "also trips this)"
        )
    return m.group(1), m.group(2)


def _parse_changeset(path: str) -> "tuple[str, str, str]":
    """Parse one changeset → ``(bump, type, prose)``; raise ChangesetError if malformed."""
    try:
        import yaml
    except ImportError as exc:  # pragma: no cover - environment guard
        raise ChangesetError(
            "PyYAML is required to parse changeset frontmatter but is not installed"
        ) from exc

    fm_text, body = _split_frontmatter(path)
    try:
        fm = yaml.safe_load(fm_text)
    except yaml.YAMLError as exc:
        raise ChangesetError(f"{path}: frontmatter is not valid YAML: {exc}") from exc
    if not isinstance(fm, dict):
        raise ChangesetError(
            f"{path}: frontmatter must be a YAML mapping with a 'bump:' key"
        )

    bump = fm.get("bump")
    if bump is None:
        raise ChangesetError(
            f"{path}: missing required 'bump:' key (expected one of {', '.join(VALID_BUMPS)})"
        )
    if not isinstance(bump, str) or bump.lower() not in VALID_BUMPS:
        raise ChangesetError(
            f"{path}: invalid bump value {bump!r} — expected one of {', '.join(VALID_BUMPS)}"
        )
    bump = bump.lower()

    raw_type = fm.get("type", DEFAULT_TYPE)
    if not isinstance(raw_type, str) or raw_type.lower() not in _TYPE_BY_LOWER:
        raise ChangesetError(
            f"{path}: invalid type value {raw_type!r} — expected one of "
            f"{', '.join(CANONICAL_TYPES)}"
        )
    section = _TYPE_BY_LOWER[raw_type.lower()]

    prose = body.strip()
    if not prose:
        raise ChangesetError(
            f"{path}: empty prose body — a changeset must describe the change "
            "(one or more '-' bullets, PR-cited)"
        )
    return bump, section, prose


def _bump_version(current: str, kind: str) -> str:
    if not VERSION_RE.match(current):
        raise ChangesetError(
            f".claude-plugin/plugin.json: version {current!r} is not an N.N.N string"
        )
    major, minor, patch = (int(p) for p in current.split("."))
    if kind == "major":
        return f"{major + 1}.0.0"
    if kind == "minor":
        return f"{major}.{minor + 1}.0"
    return f"{major}.{minor}.{patch + 1}"


# Read/write the version with a surgical regex rather than json.load/json.dump (or the
# repo's jq-based read): a full JSON round-trip would reserialize the whole manifest and
# churn unrelated formatting (key order, indentation) on every bump. The read uses the same
# regex as the write so the two stay symmetric and neither shells out to jq from Python.
def _read_manifest_version(manifest_path: str) -> str:
    try:
        with open(manifest_path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        raise ChangesetError(f"{manifest_path}: cannot read manifest: {exc}") from exc
    m = re.search(r'"version"\s*:\s*"([^"]*)"', text)
    if not m:
        raise ChangesetError(f"{manifest_path}: no \"version\" key found")
    return m.group(1)


def _write_manifest_version(manifest_path: str, new_version: str) -> None:
    """Rewrite only the version string, preserving the manifest's exact formatting."""
    with open(manifest_path, encoding="utf-8") as fh:
        text = fh.read()
    new_text, n = re.subn(
        r'("version"\s*:\s*")[^"]*(")',
        lambda mo: mo.group(1) + new_version + mo.group(2),
        text,
        count=1,
    )
    if n != 1:
        raise ChangesetError(f"{manifest_path}: could not rewrite the version string")
    with open(manifest_path, "w", encoding="utf-8") as fh:
        fh.write(new_text)


def _assemble_entry(version: str, date: str, sections: "dict[str, list[str]]") -> str:
    """Build the ``## [version] — date`` Keep-a-Changelog block from grouped prose."""
    lines = [f"## [{version}] — {date}", ""]
    for section in CANONICAL_TYPES:
        proses = sections.get(section)
        if not proses:
            continue
        lines.append(f"### {section}")
        for prose in proses:
            lines.append(prose)
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def _prepend_changelog(changelog_path: str, entry: str) -> None:
    """Insert ``entry`` immediately before the first existing ``## [`` version heading."""
    try:
        with open(changelog_path, encoding="utf-8") as fh:
            lines = fh.readlines()
    except OSError as exc:
        raise ChangesetError(f"{changelog_path}: cannot read changelog: {exc}") from exc
    insert_at = None
    for i, line in enumerate(lines):
        if line.startswith("## ["):
            insert_at = i
            break
    block = entry.rstrip("\n") + "\n\n"
    if insert_at is None:
        # No prior versioned entry — append after the file's preamble.
        new_text = "".join(lines).rstrip("\n") + "\n\n" + block
    else:
        new_text = "".join(lines[:insert_at]) + block + "".join(lines[insert_at:])
    with open(changelog_path, "w", encoding="utf-8") as fh:
        fh.write(new_text)


def consolidate(root: str, date: str) -> int:
    changeset_dir = os.path.join(root, ".changeset")
    manifest_path = os.path.join(root, ".claude-plugin", "plugin.json")
    changelog_path = os.path.join(root, "CHANGELOG.md")

    if not os.path.isdir(changeset_dir):
        print("no .changeset/ directory — nothing to consolidate")
        return 0

    pending = sorted(
        os.path.join(changeset_dir, n)
        for n in os.listdir(changeset_dir)
        if _is_consumable(n)
    )
    if not pending:
        print("no pending changesets — no version bump, no CHANGELOG entry")
        return 0

    # Parse ALL changesets first (fail-closed: no write happens until every file is valid).
    parsed = [(p, *_parse_changeset(p)) for p in pending]

    highest = max((bump for _p, bump, _t, _pr in parsed), key=_BUMP_RANK.__getitem__)
    current = _read_manifest_version(manifest_path)
    new_version = _bump_version(current, highest)

    sections: "dict[str, list[str]]" = {}
    for _path, _bump, section, prose in parsed:
        sections.setdefault(section, []).append(prose)

    # Write the manifest first: it is the cheaper, regex-symmetric operation and is the
    # likelier of the two to fail (the write regex is stricter than the read regex), so
    # doing it first means a failure aborts before CHANGELOG.md is touched — no window
    # where CHANGELOG is bumped but the manifest is not. (The workflow also commits
    # atomically from a fresh checkout, so a half-write is never committed; this ordering
    # just keeps the on-disk state consistent even mid-abort.)
    _write_manifest_version(manifest_path, new_version)
    entry = _assemble_entry(new_version, date, sections)
    _prepend_changelog(changelog_path, entry)
    for path in pending:
        os.remove(path)

    print(
        f"consolidated {len(pending)} changeset(s): {current} -> {new_version} "
        f"(highest bump: {highest}); prepended CHANGELOG entry and removed consumed files"
    )
    return 0


def main(argv: "list[str] | None" = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        help="Repository root (default: the DevFlow checkout containing this script)",
    )
    parser.add_argument(
        "--date",
        default=None,
        help="Entry date as YYYY-MM-DD (default: today, UTC)",
    )
    args = parser.parse_args(argv)
    date = args.date or datetime.now(timezone.utc).date().isoformat()
    if not re.match(r"^\d{4}-\d{2}-\d{2}$", date):
        return _fatal(f"--date {date!r} is not YYYY-MM-DD")
    try:
        return consolidate(args.root, date)
    except ChangesetError as exc:
        return _fatal(str(exc))


if __name__ == "__main__":
    sys.exit(main())
