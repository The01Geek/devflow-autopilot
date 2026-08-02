#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Fail RED on a newly introduced superseded ``devflow.<key>`` config leaf (issue #1084).

Issue #1002 Tier 1 renamed the consumer-facing config family ``devflow`` -> ``prflow``
and ``lib/rename-map.json``'s ``frozen.config_keys`` is now empty, so *every*
``devflow.<key>`` config-leaf reference is superseded. #1068 and #1084 swept the tree
twice; this guard is the recurrence backstop those sweeps' acceptance criteria demanded,
so a third accidental introduction turns the suite RED at the desk instead of shipping a
message whose live reader reads ``prflow.<key>`` while the message names the dead spelling.

Scope — deliberately the ``devflow.<key>`` DOT family only. That is the recurring defect
class (an instruction, comment, or emitted remedy naming ``devflow.allowed_bots`` /
``devflow.provider`` / ``devflow.workpad_marker`` / … while the reader beside it reads the
``prflow`` family). Three things are intentionally NOT policed here:

* The ``devflow`` FILENAME / ``devflow_<family>`` underscore / ``DEVFLOW_*`` env / ``/devflow:``
  alias / ``devflow:<agent>`` namespace forms — all frozen (``lib/rename-map.json``). The
  DOT-plus-lowercase-leaf pattern below cannot match any of them (they carry no ``devflow.``
  followed by a config-key leaf), and a small extension allow-list drops ``devflow.yml`` etc.
* The ``workflows["devflow-review"]`` sub-key, which is DELIBERATELY dual-named across the
  tree (``install.sh``'s both-spelling pattern, mirrored into the schema by #1084) so an
  unmigrated consumer still recognises their own key — policing it would flag the correct
  end state.
* The declared-exemption sites below, which must keep the superseded spelling.

Population is sourced from ``git ls-files -z`` (the index, no ``--others``, no recursive
tree walk) per issue #711, so a sibling worktree under ``.claude/worktrees/`` cannot inflate
the count and desk vs. CI stay byte-identical.
"""
from __future__ import annotations

import re
import subprocess
import sys

# A superseded config leaf: ``devflow`` + ``.`` + a lowercase config-key identifier,
# preceded by a non-identifier char so ``.devflow.allowed_bots`` (a jq path) matches while
# ``some_devflow.x`` does not, and ``devflow-review.yml`` (hyphen before the dot's owner) is
# never reached. The leaf is captured so the extension allow-list can drop filename forms.
_LEAF_RE = re.compile(r"(?<![A-Za-z0-9_])devflow\.([a-z][a-z0-9_]*)")

# Leaves that are file extensions, not config keys — ``devflow.yml`` / ``devflow.sh`` / …
# are filenames (the workflow filenames are frozen) and never config-leaf references.
_EXTENSIONS = frozenset(
    "yml yaml sh py json jq md tsv jsonl txt toml lock cfg ini example "
    "tokens gitignore mjs js ts png svg html".split()
)

# Declared exemptions — sites that must keep the superseded spelling. Path prefixes (dirs)
# and exact paths, each with the reason it is exempt. Edited together with the do-not-sweep
# list in issue #1084 / CLAUDE.md's rename gotchas.
_EXEMPT_PREFIXES = (
    ".changeset/",                 # changelog prose describing a fix legitimately names the old key
    ".prflow/learnings/",          # frozen append-only retrospective records (rewriting falsifies them)
    ".prflow/logs/",               # frozen census snapshots / TSV logs
    "lib/test/fixtures/",          # test fixtures that assert on the superseded spelling
    "lib/test/modules/tier1-rename-migration",  # the migration test drives the rename itself
)
_EXEMPT_EXACT = frozenset(
    {
        "install.sh",                       # config scan probes BOTH blocks; names both spellings deliberately
        "docs/install.md",                  # sample installer output names both spellings deliberately
        "docs/external/release-notes.md",   # past-dated historical record (past-time snapshot exemption)
        "CHANGELOG.md",                     # historical changelog entries
        "lib/rename-map.json",              # the single source of truth for the rename itself
        "lib/migrate-config-values.py",     # migration helper docstring naming the rename inputs
        "scripts/scaffold-config.sh",       # live config-key migration regex
        "scripts/migrate-consumer-tier1.sh",  # live migration regex
        "scripts/config-get.sh",            # superseded-key probe (distinguishes absent from empty)
        "lib/test/modules/installer-wiring.sh",   # migration-semantics comment + workflow-filename fixtures
        "lib/test/pin-corpus-lint.py",      # builds the rename substitution from the map
        "lib/test/test_pin_corpus_lint.py",       # its fixtures carry the superseded spelling
        "lib/test/mutation-pin-corpus-adjudications.tsv",  # frozen pin-corpus census snapshot
        "lib/test/lint-superseded-config-keys.py",  # this guard states the pattern in prose
    }
)


def _tracked_files() -> list[str]:
    out = subprocess.run(
        ["git", "ls-files", "-z"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return [p for p in out.split("\0") if p]


def _exempt(path: str) -> bool:
    if path in _EXEMPT_EXACT:
        return True
    return any(path.startswith(pfx) for pfx in _EXEMPT_PREFIXES)


def main() -> int:
    offenders: list[str] = []
    for path in _tracked_files():
        if _exempt(path):
            continue
        try:
            with open(path, "r", encoding="utf-8") as fh:
                lines = fh.readlines()
        except (OSError, UnicodeDecodeError):
            continue  # binary or unreadable: not a text config-leaf reference
        for lineno, line in enumerate(lines, 1):
            for m in _LEAF_RE.finditer(line):
                leaf = m.group(1)
                if leaf in _EXTENSIONS:
                    continue
                offenders.append(f"{path}:{lineno}: devflow.{leaf}")

    if offenders:
        sys.stderr.write(
            "lint-superseded-config-keys: superseded `devflow.<key>` config leaf found "
            "(the family was renamed to `prflow` by issue #1002; rename to `prflow.<key>`, "
            "or add a declared exemption if this site must keep the superseded spelling):\n"
        )
        for o in offenders:
            sys.stderr.write(f"  {o}\n")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
