#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Fail the suite when a subagent dispatch of a DevFlow skill is not covered by the
committed dispatch-site registry (issue #834).

Why this exists. A consumer prompt extension (`.devflow/prompt-extensions/<skill>.md`)
is honored only when the dispatched skill can reach it. Every `skills/*/SKILL.md`
body carries the loader line, so the load is always *attempted*; what a dispatch
into an isolated subagent changes is whether the skill-directory **anchor resolves**.
A `general-purpose` Task or an Agent-tool subagent receives neither
`$CLAUDE_SKILL_DIR` nor a `Base directory for this skill:` context line, so the
child cannot build the helper path and silently proceeds as though no extension
exists. One instance was fixed (issue #819) and the class declared closed while
three more dispatch sites carried the identical gap. This guard makes the census a
build gate: a newly-added subagent dispatch of a DevFlow skill that is absent from
the registry turns the suite red.

The registry (`lib/subagent-dispatch-sites.json`) is the authority; the scan is a
heuristic. The scan's job is only to make the registry honest in **both**
directions — a registered site the scan cannot see is a build failure (so the token
set is forced wider by a red test, not left to notice), and a section the scan
flags that no record accounts for is a build failure (so a new dispatch cannot ship
unregistered). The `declared_non_dispatch` array is the pressure valve for the
opposite direction — prose that *describes* a dispatch reads like one to any
lexical rule — and it is keyed per (dispatcher, section-heading) and checked for
staleness, so exempting one paragraph never blinds the gate to the rest of its file.

Scan population (index-reading `git ls-files`, no `--others`, so a sibling git
worktree under `.claude/worktrees/` cannot change the result — issue #711):

* every tracked `skills/**/*.md`, and
* every tracked `.devflow/prompt-extensions/*.md` (exactly one level deep).

Section model. A file is split into sections at markdown headings (`#`..`######`).
A section spans from its heading line to the next heading whose level is **not
deeper** (level <= this heading's level), so a section includes its own deeper
subsections; when both a token and a skill reference co-occur in more than one
nested section, only the **innermost** such section is reported, so a parent is
never double-counted with the child that actually carries the dispatch. Content
before the first heading is the file-level (empty-heading) section. Heading
recognition and candidate matching both ignore the interior of fenced code blocks
(``` ``` ``` and `~~~`), so a `#`-prefixed comment line inside a fence neither opens
a section nor contributes a match.

Candidate rule. A section is a candidate when it contains **both**:

* a **dispatch token** — one of this closed set, matched as a substring of the
  fence-stripped section content:
  `subagent_type`, `Agent tool`, `Agent-tool subagent`, `Agent call`,
  `Spawn a **subagent**`, `Read and follow`; **and**
* a **DevFlow skill reference that resolves to a directory under `skills/`** — a
  reference in one of two *dispatch-shaped* forms (a bare cross-reference such as a
  prose "see `/devflow:review`" is deliberately **not** a reference form, which is
  what keeps the scan from flagging every section that merely names another skill):
  * an **anchor-relative** path ending `../<slug>/SKILL.md` (the form a dispatch
    prompt uses to point a child at the skill body it must read and follow). The
    leading `../` is required: a plain `skills/<slug>/SKILL.md` file-path *citation*
    — which peppers the engine's cross-references — is not a dispatch reference; or
  * an *invoke-a-skill* phrase — a `devflow:<slug>` / `/devflow:<slug>` occurrence
    the literal phrase `invoke the` immediately precedes (within
    `_INVOKE_WINDOW` characters, case-insensitive). The phrase (not the bare word
    `invoke`) is required so a cross-reference like "when invoked by `/devflow:x`"
    is not a dispatch reference.
  A reference's `<slug>` is **resolved** against the tree: `skills/<slug>/` present
  → `skills`; else `agents/<slug>.md` present → `agents`; else `unknown`. Only a
  `skills`-resolving reference counts toward the conjunction.

The complement the candidate rule excludes, and the escape that remains:

* a reference whose slug resolves under `agents/` (e.g. `devflow:code-explorer`,
  `subagent_type: devflow:code-reviewer`) — an agent definition loads no consumer
  extension, so it is outside the protected set;
* a dispatch naming a non-DevFlow skill such as `superpowers:writing-skills` — its
  reference has no `devflow:` prefix and no `skills/<slug>/SKILL.md` path, so it
  never resolves to a `skills/` directory;
* a section containing a token but no skill reference, or a skill reference but no
  token, or the two in two *different* sections — the conjunction is section-scoped;
* `declared_non_dispatch` — the one remaining escape for a section the lexical rule
  reaches that is prose *about* a dispatch rather than a dispatch. It is keyed on
  the (dispatcher-path, section-heading) pair, so it exempts one named section and
  leaves every other section of the same file protected, and a stale entry (naming
  a section the scan no longer flags) is itself a failure.

Registry shape (six-shape adversarial matrix per CLAUDE.md, for a machine-consumed
JSON artifact). The accepted registry is a top-level JSON object carrying an
integer `schema_version`, a `sites` array, and a `declared_non_dispatch` array. For
each of those two array-valued keys the lint exits non-zero with a shape-specific
message — never a traceback, never a silent pass — for each of these six shapes,
complete by construction: an object, an array of scalars, a scalar, a valid-falsy
value, the key missing, and a value of the wrong type. A `sites` element names a
`dispatcher` path, a `skill`, and a `handoff` value drawn from the closed set
`by-path` / `resolved-command` / `inherited` / `not-required`. A
`declared_non_dispatch` element names a `dispatcher` path, a `section` heading, and
a `reason`.

Exit status is 0 only when the registry is well-formed and the scan and the
registry are in exact agreement. It is non-zero on any registry-shape failure, any
scan/registry disagreement, an unreadable registry, or an unusable enumeration —
callers read the report, never only the exit code. Every decisive value is computed
in Python from the index listing and the parsed registry — never through a
non-preflight PATH tool (`tr`/`sed`/`wc`/`cut`/`head`), which would fail open on a
host that lacks it.

Usage:
    lint-subagent-extension-handoff.py [--root DIR] [--files-from PATH]
                                       [--registry PATH]
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import sys
from pathlib import Path

# Share the population reader with the other `git ls-files` lints (issue #724):
# the `EnumerationError` fail-closed contract, the index-reading enumeration, the
# per-file reader, and the `--root`/`--files-from` preamble. Import by path with the
# directory's standard idiom and assert the surface at LOAD time so a rename fails
# here, naming the dependency, rather than mid-scan.
_POP_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lint_population.py")
_pop_spec = importlib.util.spec_from_file_location("lint_population", _POP_PATH)
if _pop_spec is None or _pop_spec.loader is None:
    raise SystemExit(
        f"lint-subagent-extension-handoff: the population reader {_POP_PATH} is not "
        "an importable source file; refusing to audit"
    )
_pop = importlib.util.module_from_spec(_pop_spec)
try:
    _pop_spec.loader.exec_module(_pop)
except Exception as _exc:  # a SyntaxError in the sibling must fail here,
    # named, not surface as a raw traceback naming the interpreter.
    raise SystemExit(
        f"lint-subagent-extension-handoff: the shared population reader {_POP_PATH} "
        f"could not be loaded ({_exc.__class__.__name__}: {_exc}); refusing to audit"
    ) from _exc
_REQUIRED_POP_ATTRS = (
    "EnumerationError", "enumerate_population", "read_source",
    "add_population_arguments", "resolve_root", "LS_FILES_INDEX",
)
_pop_missing = [name for name in _REQUIRED_POP_ATTRS if not hasattr(_pop, name)]
if _pop_missing:
    raise SystemExit(
        f"lint-subagent-extension-handoff: {_POP_PATH} no longer provides "
        f"{', '.join(_pop_missing)}; refusing to audit"
    )

EnumerationError = _pop.EnumerationError

#: The registry path, relative to the repository root.
DEFAULT_REGISTRY = "lib/subagent-dispatch-sites.json"

#: The closed handoff-value set (issue #834 Data/Schema Considerations).
HANDOFF_VALUES = ("by-path", "resolved-command", "inherited", "not-required")

#: The closed dispatch-token set, each matched case-sensitively as a substring of
#: the fence-stripped section content.
DISPATCH_TOKENS_CASE = (
    "subagent_type",
    "Agent tool",
    "Agent-tool subagent",
    "Agent call",
    "Spawn a **subagent**",
    "Read and follow",
)

#: The two dispatch-shaped DevFlow skill-reference forms. The path form captures the
#: directory before `/SKILL.md`; the invoke form captures a `devflow:<slug>` the word
#: `invoke` immediately precedes (a bare cross-reference is deliberately excluded).
_DEVFLOW_REF = re.compile(r"/?devflow:([a-z0-9][a-z0-9-]*)")
_SKILL_PATH_REF = re.compile(r"\.\./([a-z0-9][a-z0-9-]*)/SKILL\.md")
#: The invoke-a-skill phrase that must precede a `devflow:<slug>` occurrence, and how
#: far back from the occurrence it may sit, for the occurrence to count as a reference.
_INVOKE_PHRASE = "invoke the"
_INVOKE_WINDOW = 25

#: A markdown ATX heading outside a fence.
_HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*$")
#: A fence opener/closer: three or more backticks or tildes at the line start.
_FENCE = re.compile(r"^(\s*)(`{3,}|~{3,})")


def is_audited(path: str) -> bool:
    """True when `path` is in the scan population (tracked skills/prompt-extension md)."""
    normalized = path.replace("\\", "/")
    if normalized.startswith("skills/") and normalized.endswith(".md"):
        return True
    return bool(re.fullmatch(r"\.devflow/prompt-extensions/[^/]+\.md", normalized))


def resolve_slug(root: Path, slug: str) -> str:
    """Resolve a reference slug to `skills`, `agents`, or `unknown` against the tree."""
    if (root / "skills" / slug).is_dir():
        return "skills"
    if (root / "agents" / f"{slug}.md").exists():
        return "agents"
    return "unknown"


def split_sections(text: str) -> list[tuple[str, int, list[str]]]:
    """Return `(heading_title, level, content_lines)` for every section of `text`.

    Fenced code blocks are inert: a `#` inside a fence opens no section, and the
    fence body is excluded from `content_lines`. The file-level preamble (content
    before the first heading) is returned as an empty-title level-0 section.
    """
    lines = text.split("\n")
    in_fence = False
    fence_marker = ""
    # First pass: classify each line as heading / fenced / plain, so a `#` inside a
    # fence is never mistaken for a heading and fenced content contributes no match.
    classified: list[tuple[str, str, int]] = []  # (kind, text, level)
    for raw in lines:
        fence = _FENCE.match(raw)
        if fence is not None:
            marker = fence.group(2)[0]
            if not in_fence:
                in_fence = True
                fence_marker = marker
            elif marker == fence_marker:
                in_fence = False
            classified.append(("fence", raw, 0))
            continue
        if in_fence:
            classified.append(("fenced", raw, 0))
            continue
        heading = _HEADING.match(raw)
        if heading is not None:
            classified.append(("heading", heading.group(2), len(heading.group(1))))
        else:
            classified.append(("plain", raw, 0))

    sections: list[tuple[str, int, list[str]]] = []
    cur_title = ""
    cur_level = 0
    cur_content: list[str] = []
    started = False
    for kind, value, level in classified:
        if kind == "heading":
            if started or cur_content:
                sections.append((cur_title, cur_level, cur_content))
            cur_title, cur_level, cur_content = value, level, []
            started = True
        elif kind == "plain":
            # The heading line's own text is scannable content of its section too, but
            # fence markers and fenced bodies never contribute a match.
            cur_content.append(value)
        # "fence"/"fenced" lines are dropped from content.
    if started or cur_content:
        sections.append((cur_title, cur_level, cur_content))
    return sections


def _has_token(content: str) -> bool:
    return any(tok in content for tok in DISPATCH_TOKENS_CASE)


def _skills_refs(root: Path, content: str) -> set[str]:
    """Return the set of slugs referenced in `content` that resolve under `skills/`.

    Only the two dispatch-shaped forms count: an anchor-relative `.../<slug>/SKILL.md`
    path, and a `devflow:<slug>` the word `invoke` precedes within `_INVOKE_WINDOW`
    characters. A bare cross-reference (`see /devflow:review`) is not a reference form.
    """
    slugs: set[str] = set()
    for match in _SKILL_PATH_REF.finditer(content):
        slugs.add(match.group(1))
    lowered = content.lower()
    for match in _DEVFLOW_REF.finditer(content):
        window = lowered[max(0, match.start() - _INVOKE_WINDOW):match.start()]
        if _INVOKE_PHRASE in window:
            slugs.add(match.group(1))
    return {slug for slug in slugs if resolve_slug(root, slug) == "skills"}


def scan_file(root: Path, relative: str, text: str) -> list[tuple[str, set[str]]]:
    """Return `(section_heading, skills_refs)` for every flagged section of one file.

    A section is flagged when its span contains both a dispatch token and a
    `skills`-resolving reference; when nested sections both qualify, only the
    innermost is reported so a parent is never double-counted with its child.
    """
    raw_sections = split_sections(text)
    # Reconstruct each section's FULL span content (its own lines plus every deeper
    # subsection's lines) under the "not deeper" rule, so a token in an intro and a
    # ref in a subsection still co-occur; then keep only the innermost qualifying one.
    n = len(raw_sections)
    span_content: list[str] = []
    for i, (_title, level, _content) in enumerate(raw_sections):
        acc: list[str] = list(raw_sections[i][2])
        j = i + 1
        while j < n and raw_sections[j][1] > level:
            acc.extend(raw_sections[j][2])
            j += 1
        span_content.append("\n".join(acc))

    qualifies = [False] * n
    refs_per: list[set[str]] = [set() for _ in range(n)]
    for i in range(n):
        content = span_content[i]
        if not _has_token(content):
            continue
        refs = _skills_refs(root, content)
        if not refs:
            continue
        qualifies[i] = True
        refs_per[i] = refs

    flagged: list[tuple[str, set[str]]] = []
    for i, (title, level, _content) in enumerate(raw_sections):
        if not qualifies[i]:
            continue
        # Innermost only: suppress this section if a deeper nested section (within its
        # span) also qualifies — that child carries the actual co-location.
        end = i + 1
        while end < n and raw_sections[end][1] > level:
            end += 1
        if any(qualifies[k] for k in range(i + 1, end)):
            continue
        flagged.append((title, refs_per[i]))
    return flagged


# ── registry loading and shape validation ────────────────────────────────────


class RegistryError(Exception):
    """A registry-shape failure. Carries a reader-facing message."""


def _validate_array_key(reg: dict, key: str) -> list:
    """Return `reg[key]` when it is an array of objects; raise RegistryError otherwise.

    One shape-specific message per detectable shape, so the six-shape matrix — an
    object, an array of scalars, a scalar, a valid-falsy value, the key missing, and
    a value of the wrong type — each fails distinctly rather than collapsing.
    """
    if key not in reg:
        raise RegistryError(f"`{key}` key is missing — the registry must carry it as a JSON array")
    value = reg[key]
    if isinstance(value, bool):
        raise RegistryError(f"`{key}` must be a JSON array, not a boolean (valid-falsy value)")
    if value is None:
        raise RegistryError(f"`{key}` must be a JSON array, not null (wrong type)")
    if isinstance(value, dict):
        raise RegistryError(f"`{key}` must be a JSON array, not an object")
    if isinstance(value, (int, float)):
        raise RegistryError(f"`{key}` must be a JSON array, not a number (scalar)")
    if isinstance(value, str):
        raise RegistryError(f"`{key}` must be a JSON array, not a string (scalar)")
    if not isinstance(value, list):
        raise RegistryError(f"`{key}` must be a JSON array (wrong type: {type(value).__name__})")
    for index, element in enumerate(value):
        if not isinstance(element, dict):
            raise RegistryError(
                f"`{key}` must be an array of objects; element {index} is a "
                f"{type(element).__name__} (array of scalars)"
            )
    return value


def load_registry(path: Path) -> tuple[list[dict], list[dict]]:
    """Return `(sites, declared_non_dispatch)`; raise RegistryError on any shape fault."""
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise RegistryError(
            f"registry {path} could not be read ({exc}) — the site census is "
            "unestablished, not empty; refusing to report clean"
        ) from exc
    try:
        reg = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RegistryError(f"registry {path} is not valid JSON: {exc}") from exc
    if not isinstance(reg, dict):
        raise RegistryError(
            f"registry {path} must be a top-level JSON object, not a {type(reg).__name__}"
        )
    version = reg.get("schema_version")
    if isinstance(version, bool) or not isinstance(version, int):
        raise RegistryError(
            "`schema_version` must be an integer "
            f"(got {version!r})"
        )
    sites = _validate_array_key(reg, "sites")
    non_dispatch = _validate_array_key(reg, "declared_non_dispatch")
    return sites, non_dispatch


# ── main ──────────────────────────────────────────────────────────────────────


def audit(
    root: Path, files_from: Path | None, registry_path: Path
) -> tuple[list[str], int]:
    """Return `(errors, record_count)` for the audit.

    The registry is validated **first** — it is the authority, and a shape or
    read fault must surface regardless of the file population (an empty or unusable
    population must not mask a malformed registry). Only a well-formed registry then
    proceeds to enumerate the tree for the scan.
    """
    errors: list[str] = []

    try:
        sites, non_dispatch = load_registry(registry_path)
    except RegistryError as exc:
        return [f"lint-subagent-extension-handoff: {exc}"], 0

    try:
        population = _pop.enumerate_population(
            root, files_from, ls_files_argv=_pop.LS_FILES_INDEX
        )
    except EnumerationError as exc:
        return [f"lint-subagent-extension-handoff: enumeration unusable: {exc}"], len(
            [s for s in sites if isinstance(s, dict)]
        )

    tracked = set(population)
    audited_files = [p for p in population if is_audited(p)]

    # Registry-internal checks: field presence, handoff set, dispatcher existence,
    # duplicate (dispatcher, skill).
    site_pairs: dict[tuple[str, str], int] = {}
    valid_sites: list[dict] = []
    for index, record in enumerate(sites):
        dispatcher = record.get("dispatcher")
        skill = record.get("skill")
        handoff = record.get("handoff")
        if not isinstance(dispatcher, str) or not isinstance(skill, str):
            errors.append(
                f"sites[{index}]: each record must name string `dispatcher` and `skill` "
                f"(got dispatcher={dispatcher!r}, skill={skill!r})"
            )
            continue
        if "handoff" not in record:
            errors.append(f"sites[{index}] ({dispatcher}, {skill}): `handoff` key is absent")
        elif handoff not in HANDOFF_VALUES:
            errors.append(
                f"sites[{index}] ({dispatcher}, {skill}): handoff {handoff!r} is outside the "
                f"closed set {HANDOFF_VALUES}"
            )
        if dispatcher not in tracked:
            errors.append(
                f"sites[{index}] ({dispatcher}, {skill}): dispatcher path is absent from the "
                "tracked tree"
            )
        pair = (dispatcher, skill)
        if pair in site_pairs:
            errors.append(
                f"sites[{index}] ({dispatcher}, {skill}): duplicate of sites[{site_pairs[pair]}] "
                "— two records name the same dispatcher-and-skill pair"
            )
        else:
            site_pairs[pair] = index
        valid_sites.append(record)

    nd_keys: dict[tuple[str, str], int] = {}
    for index, record in enumerate(non_dispatch):
        dispatcher = record.get("dispatcher")
        section = record.get("section")
        reason = record.get("reason")
        if not isinstance(dispatcher, str) or not isinstance(section, str) or not isinstance(reason, str):
            errors.append(
                f"declared_non_dispatch[{index}]: each record must name string `dispatcher`, "
                f"`section`, and `reason` (got dispatcher={dispatcher!r}, section={section!r}, "
                f"reason={reason!r})"
            )
            continue
        if dispatcher not in tracked:
            errors.append(
                f"declared_non_dispatch[{index}] ({dispatcher}, '{section}'): dispatcher path is "
                "absent from the tracked tree"
            )
        key = (dispatcher, section)
        if key in nd_keys:
            errors.append(
                f"declared_non_dispatch[{index}] ({dispatcher}, '{section}'): duplicate exemption"
            )
        else:
            nd_keys[key] = index

    # Scan every audited file. Skip a file that cannot be read — never absorb it into
    # a clean pass.
    flagged: list[tuple[str, str, set[str]]] = []  # (file, heading, skills_refs)
    skipped: list[tuple[str, str]] = []
    for relative in audited_files:
        text, skip_reason = _pop.read_source(root / relative, skip_nul=False)
        if text is None:
            skipped.append((relative, skip_reason or "unknown"))
            continue
        for heading, refs in scan_file(root, relative, text):
            flagged.append((relative, heading, refs))

    for relative, reason in skipped:
        errors.append(f"lint-subagent-extension-handoff: SKIPPED {relative}: {reason}")

    flagged_keys = {(f, h) for f, h, _ in flagged}
    reached_pairs: set[tuple[str, str]] = set()

    # Exact agreement, direction 1: every flagged section is accounted for.
    for relative, heading, refs in flagged:
        if (relative, heading) in nd_keys:
            continue  # exempt prose-about-dispatch
        for skill in sorted(refs):
            if (relative, skill) in site_pairs:
                reached_pairs.add((relative, skill))
            else:
                errors.append(
                    f"unregistered dispatch: {relative} section '{heading}' dispatches "
                    f"skills/{skill} but no sites record covers ({relative}, {skill}) and no "
                    "declared_non_dispatch entry exempts the section"
                )

    # Exact agreement, direction 2: every sites record is reached by the scan —
    # EXCEPT `inherited` records. An inherited site (the Step 2.6 shadow) re-dispatches
    # another registered site's roster and carries no unique dispatch wording of its
    # own for the scan to key on, so it is registered for completeness, not because the
    # lexical rule detects it (issue #834: the naive scan "misses the shadow site
    # entirely"). This mirrors the positive-control fixture's inherited exemption.
    inherited_pairs = {
        (r.get("dispatcher"), r.get("skill"))
        for r in valid_sites
        if r.get("handoff") == "inherited"
    }
    for pair, index in site_pairs.items():
        if pair in inherited_pairs:
            continue
        if pair not in reached_pairs:
            errors.append(
                f"sites[{index}] ({pair[0]}, {pair[1]}): registry names a dispatch the scan does "
                "not reach — the token set or reference form no longer matches this site"
            )

    # Staleness: every declared_non_dispatch entry must still be flagged.
    for key, index in nd_keys.items():
        if key not in flagged_keys:
            errors.append(
                f"declared_non_dispatch[{index}] ({key[0]}, '{key[1]}'): the scan no longer flags "
                "this section — the exemption is stale and must be removed"
            )

    return errors, len(valid_sites)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Fail when a subagent dispatch of a DevFlow skill is not covered by the "
            "committed dispatch-site registry."
        )
    )
    _pop.add_population_arguments(parser)
    parser.add_argument(
        "--registry",
        default=None,
        help=f"registry path (default: <root>/{DEFAULT_REGISTRY})",
    )
    args = parser.parse_args(argv)

    root = _pop.resolve_root(args.root, tool="lint-subagent-extension-handoff")
    registry_path = Path(args.registry) if args.registry else root / DEFAULT_REGISTRY
    files_from = Path(args.files_from) if args.files_from else None

    errors, record_count = audit(root, files_from, registry_path)

    for error in errors:
        print(error, file=sys.stderr)
    plural = "record" if record_count == 1 else "records"
    print(
        f"lint-subagent-extension-handoff: audited {record_count} of {record_count} {plural}"
    )
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
