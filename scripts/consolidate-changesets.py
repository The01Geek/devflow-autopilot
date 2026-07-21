#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Consolidate pending ``.changeset/*.md`` files into a version bump + CHANGELOG entry.

DevFlow versions itself with changesets instead of editing ``.claude-plugin/plugin.json``
and ``CHANGELOG.md`` in every PR (see ``.changeset/README.md``). This helper runs at merge
time (push to ``main``) from the ``version-consolidate`` workflow at
``.github/workflows/version-consolidate.yml``:

  * globs every pending ``.changeset/*.md`` (ignoring ``README.md``),
  * parses each file's ``bump:`` (required) + optional ``type:`` frontmatter and prose body,
  * computes the single highest pending bump (``patch`` < ``minor`` < ``major``),
  * rewrites ``.claude-plugin/plugin.json``'s ``version`` by that increment,
  * rewrites ``CITATION.cff``'s ``version`` to the same value (when the file is present),
  * rewrites the ``marketplace.json`` plugin entry's ``version`` to the same value (when present),
  * prepends a dated, PR-cited Keep-a-Changelog entry assembled from all the prose, and
  * deletes the consumed changeset files.

It writes nothing else — staging and the ``chore: bump version`` commit are the workflow's job.

Fail-closed contract: a malformed changeset (no frontmatter, missing/invalid ``bump``, an
unknown ``type``, or an empty prose body) aborts with exit 2 and a diagnostic naming the
offending file. Everything is **validated before any file is modified** — all changesets are
parsed *and* both output files (``plugin.json``, ``CHANGELOG.md``) are read and their new
contents assembled in memory *before* the first write, so a malformed changeset or an
output-side read/parse fault never causes a silent skip or a partial bump — it aborts before
any write. (The two writes themselves are sequential and non-atomic, so a *write*-side fault
between them can still leave one output rewritten and the other not; the workflow commits from
a fresh ``git reset --hard origin/main`` checkout on each attempt, so a half-write is never
committed.) Every OS-level fault (a read, write, or delete)
is wrapped into the same name-the-file exit-2 path — a top-level ``except OSError`` backstop in
``main`` catches any site not individually wrapped — so the tool never exits 1 with a bare
``OSError`` traceback. Zero pending changesets is a clean no-op: nothing is written and the
exit code is 0.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from datetime import datetime, timezone
from typing import NamedTuple

# Single source of the ordered bump domain: _BUMP_RANK is DERIVED from VALID_BUMPS (mirroring
# the CANONICAL_TYPES → _TYPE_BY_LOWER pattern below), so adding a bump value cannot desync the
# two into a KeyError at the `max(..., key=_BUMP_RANK.__getitem__)` lookup.
VALID_BUMPS = ("patch", "minor", "major")
_BUMP_RANK = {bump: rank for rank, bump in enumerate(VALID_BUMPS)}

# Keep-a-Changelog section names, in the canonical order they render within an entry.
CANONICAL_TYPES = ["Added", "Changed", "Deprecated", "Removed", "Fixed", "Security"]
_TYPE_BY_LOWER = {t.lower(): t for t in CANONICAL_TYPES}
DEFAULT_TYPE = "Changed"

VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")


class ChangesetError(Exception):
    """A malformed changeset or manifest — the fail-closed, name-the-file path."""


class Frontmatter(NamedTuple):
    """A changeset split into its YAML frontmatter text and prose body."""

    frontmatter: str
    body: str


class Changeset(NamedTuple):
    """One parsed changeset: its bump kind, CHANGELOG section, and prose body."""

    bump: str
    section: str
    prose: str


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


def _split_frontmatter(path: str) -> Frontmatter:
    """Return a ``Frontmatter(frontmatter, body)`` for a changeset, or raise ChangesetError.

    The file MUST start with a ``---`` fence (a leading BOM or any other prefix defeats
    detection and is rejected loudly rather than silently mis-parsed).
    """
    text = _read_text(path, "changeset")
    m = re.match(r"---[ \t]*\n(.*?)\n---[ \t]*\n?(.*)\Z", text, re.DOTALL)
    if not m:
        raise ChangesetError(
            f"{path}: no YAML frontmatter found — a changeset must start with a "
            "'---' fenced block declaring 'bump:' (a leading BOM or blank line "
            "also trips this)"
        )
    return Frontmatter(m.group(1), m.group(2))


def _parse_changeset(path: str) -> Changeset:
    """Parse one changeset → ``Changeset(bump, section, prose)``; raise on malformed input."""
    try:
        import yaml
    except ImportError as exc:  # pragma: no cover - environment guard
        raise ChangesetError(
            "PyYAML is required to parse changeset frontmatter but is not installed"
        ) from exc

    split = _split_frontmatter(path)
    fm_text, body = split.frontmatter, split.body
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
    return Changeset(bump, section, prose)


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
    text = _read_text(manifest_path, "manifest")
    m = re.search(r'"version"\s*:\s*"([^"]*)"', text)
    if not m:
        raise ChangesetError(f"{manifest_path}: no \"version\" key found")
    return m.group(1)


def _read_text(path: str, what: str) -> str:
    """Read ``path`` as UTF-8 text, wrapping any OS fault into the name-the-file exit-2 path.

    Mirror of ``_write_text`` so read and write share one wrap site — a new reader cannot
    diverge with a subtly different or missing diagnostic.
    """
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except OSError as exc:
        raise ChangesetError(f"{path}: cannot read {what}: {exc}") from exc


def _write_text(path: str, text: str) -> None:
    """Write ``text`` to ``path``, wrapping any OS fault into the name-the-file exit-2 path."""
    try:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
    except OSError as exc:
        raise ChangesetError(f"{path}: cannot write: {exc}") from exc


def _render_manifest(manifest_path: str, new_version: str) -> str:
    """Read the manifest and return its new text with only the version string rewritten.

    Pure read + assemble (no write) so ``consolidate`` can prove both outputs are writable-in-
    memory before touching disk. Preserves the manifest's exact formatting.
    """
    text = _read_text(manifest_path, "manifest")
    new_text, n = re.subn(
        r'("version"\s*:\s*")[^"]*(")',
        lambda mo: mo.group(1) + new_version + mo.group(2),
        text,
        count=1,
    )
    if n != 1:
        raise ChangesetError(f"{manifest_path}: could not rewrite the version string")
    return new_text


def _render_citation(citation_path: str, new_version: str) -> str:
    """Read ``CITATION.cff`` and return its text with only the top-level ``version`` rewritten.

    Uses the same surgical-regex approach as ``_render_manifest`` (no YAML round-trip, so the
    file's exact formatting is preserved). The pattern is anchored to a line beginning exactly
    ``version:`` (``re.MULTILINE``), so the sibling ``cff-version:`` key is never matched.
    Pure read + assemble (no write) so ``consolidate`` can prove the output is writable-in-
    memory before touching disk.
    """
    text = _read_text(citation_path, "citation")
    new_text, n = re.subn(
        r"(?m)^(version:[ \t]*)\S.*$",
        lambda mo: mo.group(1) + new_version,
        text,
        count=1,
    )
    if n != 1:
        raise ChangesetError(f"{citation_path}: could not rewrite the version field")
    return new_text


def _render_marketplace_version(marketplace_path: str, new_version: str) -> str:
    """Read ``marketplace.json`` and return its text with the plugin entry's ``version`` rewritten.

    The marketplace manifest carries exactly one ``version`` key (its single ``plugins[0]``
    entry's — there is no marketplace-level ``version``), so the same surgical JSON regex
    ``_render_manifest`` uses, with ``count=1``, targets it and no other. Pure read + assemble
    (no write), so ``consolidate`` can prove the output is writable-in-memory before touching
    disk, and formatting is preserved. Keeps the marketplace listing's advertised plugin version
    in lockstep with the ``plugin.json`` the consolidator bumps.
    """
    text = _read_text(marketplace_path, "marketplace")
    new_text, n = re.subn(
        r'("version"\s*:\s*")[^"]*(")',
        lambda mo: mo.group(1) + new_version + mo.group(2),
        text,
        count=1,
    )
    if n != 1:
        raise ChangesetError(
            f"{marketplace_path}: could not rewrite the plugin entry version"
        )
    return new_text


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


def _render_changelog(changelog_path: str, entry: str) -> str:
    """Read the changelog and return its new text with ``entry`` prepended.

    Pure read + assemble (no write): ``entry`` is inserted immediately before the first
    existing ``## [`` version heading, or appended after the preamble when none exists.
    """
    lines = _read_text(changelog_path, "changelog").splitlines(keepends=True)
    insert_at = None
    for i, line in enumerate(lines):
        if line.startswith("## ["):
            insert_at = i
            break
    block = entry.rstrip("\n") + "\n\n"
    if insert_at is None:
        # No prior versioned entry — append after the file's preamble.
        return "".join(lines).rstrip("\n") + "\n\n" + block
    return "".join(lines[:insert_at]) + block + "".join(lines[insert_at:])


def consolidate(root: str, date: str) -> int:
    changeset_dir = os.path.join(root, ".changeset")
    manifest_path = os.path.join(root, ".claude-plugin", "plugin.json")
    changelog_path = os.path.join(root, "CHANGELOG.md")
    citation_path = os.path.join(root, "CITATION.cff")
    marketplace_path = os.path.join(root, ".claude-plugin", "marketplace.json")

    if not os.path.isdir(changeset_dir):
        print("no .changeset/ directory — nothing to consolidate")
        return 0

    try:
        names = os.listdir(changeset_dir)
    except OSError as exc:
        raise ChangesetError(f"{changeset_dir}: cannot list changesets: {exc}") from exc
    pending = sorted(
        os.path.join(changeset_dir, n) for n in names if _is_consumable(n)
    )
    if not pending:
        print("no pending changesets — no version bump, no CHANGELOG entry")
        return 0

    # Parse ALL changesets first (fail-closed: no write happens until every file is valid).
    parsed = [_parse_changeset(p) for p in pending]

    highest = max((cs.bump for cs in parsed), key=_BUMP_RANK.__getitem__)
    current = _read_manifest_version(manifest_path)
    new_version = _bump_version(current, highest)

    sections: "dict[str, list[str]]" = {}
    for cs in parsed:
        sections.setdefault(cs.section, []).append(cs.prose)
    entry = _assemble_entry(new_version, date, sections)

    # Read-before-write: assemble BOTH output files' new contents in memory (each read here
    # can raise ChangesetError) before writing either — so an output-side read/parse fault
    # aborts before any write, leaving plugin.json and CHANGELOG.md byte-for-byte unchanged.
    # No os.access() check-then-write (TOCTOU): the render helpers do the real read.
    new_manifest = _render_manifest(manifest_path, new_version)
    new_changelog = _render_changelog(changelog_path, entry)
    # CITATION.cff tracks the manifest version. It is optional supplementary metadata: absent
    # → skipped (None); present-but-unrewritable → _render_citation raises before any write,
    # preserving the read-before-write atomicity guarantee above.
    new_citation = (
        _render_citation(citation_path, new_version)
        if os.path.exists(citation_path)
        else None
    )
    # The marketplace entry advertises the same plugin version; keep it in lockstep so the
    # listing never drifts behind the manifest. Same optional/read-before-write treatment as
    # CITATION.cff: absent → skipped; present-but-unrewritable → raises before any write.
    new_marketplace = (
        _render_marketplace_version(marketplace_path, new_version)
        if os.path.exists(marketplace_path)
        else None
    )

    _write_text(manifest_path, new_manifest)
    _write_text(changelog_path, new_changelog)
    if new_citation is not None:
        _write_text(citation_path, new_citation)
    if new_marketplace is not None:
        _write_text(marketplace_path, new_marketplace)
    for path in pending:
        try:
            os.remove(path)
        except OSError as exc:
            raise ChangesetError(f"{path}: cannot delete consumed changeset: {exc}") from exc

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
    except OSError as exc:
        # Removal-proof backstop: every OS site above is individually wrapped into a
        # ChangesetError, but a site added later (or missed) must still exit 2 with a
        # diagnostic rather than a bare OSError traceback / exit 1.
        return _fatal(f"unhandled OS error: {exc}")


if __name__ == "__main__":
    sys.exit(main())
