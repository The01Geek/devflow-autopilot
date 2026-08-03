#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Fail the suite when a tracked path would be refused by git's Windows checkout.

Why this exists (issue #1196). This repository *is* its own plugin: the
`.claude-plugin/marketplace.json` entry declares `"source": "./"`, so
`claude plugin marketplace add …` and every consumer plugin update clone the
**whole repository**. Every tracked path is therefore materialised on every
consumer machine at checkout time — long before, and independent of, whatever the
vendor slice later prunes. Pruning governs what *ships*; this failure happens at
*clone/checkout* time, which is upstream of pruning and cannot be affected by it.

git validates each path component during checkout and *refuses* to write a path
that is illegal on Windows (`error: invalid path '<path>'`), which aborts the
clone. But that validation is compiled out on the platforms we develop and test
on: `is_valid_path(path)` is `#define`d to the constant `1` on non-Windows in
`git-compat-util.h`, and only expands to `is_valid_win32_path(...)` on Windows via
`compat/mingw.h`. `core.protectNTFS` does **not** re-enable it — that setting
gates a different check (`is_ntfs_dotgit`). So a path that is fatal on Windows
passes every gate we run: CI is `ubuntu-latest`, local development is macOS/Linux,
and the reserved-name checker does not exist in those git binaries. We shipped
exactly that in `lib/test/fixtures/shipped-pruned-path/skills/nul.md` (`nul` is a
Windows reserved device stem) and it stayed green until a Windows user's install
failed. PR #1195 removed the file; this guard prevents the *class* from recurring.

Because a Windows-invalid tracked path breaks **every** Windows clone with no
partial-install fallback, this guard is deliberately **absolute**: it offers no
`# …-ok:` declaration marker. A declared exception would still take every Windows
consumer offline, so there is nothing a reviewer could reasonably wave through.

What git rejects (read from `is_valid_win32_path()` in git's `compat/mingw.c`,
reached from `verify_path_internal()` in `read-cache.c`; the check is per path
component and case-insensitive):

* **Reserved device names** — `AUX`, `CON`, `CONIN$`, `CONOUT$`, `NUL`, `PRN`,
  `COM1`–`COM9`, `LPT0`–`LPT9`. The `COM`/`LPT` asymmetry is real and modelled as
  git does it: `COM` is followed by a digit `1`–`9` (so `COM0` is **not**
  reserved), while `LPT` is followed by any digit `0`–`9` (so `LPT0` **is**
  reserved). A reserved stem stays reserved when followed — after skipping any
  trailing spaces — by end-of-component, a `.` (any extension), a `:` (NTFS
  alternate data stream), or a directory separator. So `nul.md`, `nul:ads`, and
  `nul   ` are all rejected; `nulls.md` is not (the terminator test, not a naive
  "stem before the first dot").
* **Trailing space or period** — a component ending in ` ` or `.`, except the
  literal `.` and `..`.
* **Forbidden characters** — `<` `>` `:` `"` `|` `?` `*` anywhere in a component.
  (A leading DOS drive prefix such as `C:` is subsumed here: its `:` is a
  forbidden character, so a drive-prefixed path is flagged without a separate arm.)
* **Control characters** — bytes `0x01`–`0x1F`.
* **Backslash** — a backslash anywhere in the path (git rejects it in
  `verify_path_internal` under `GIT_WINDOWS_NATIVE || __CYGWIN__`).

Population. The tracked paths come from an **index-reading `git ls-files` with no
`--others`** (derived from `lint_population.LS_FILES_INDEX`) — the issue-#711
convention: a repository-root-anchored recursive walk would descend into sibling git
worktrees under `.claude/worktrees/` and audit other checkouts' copies, going red
locally with a per-run-varying count while CI (a fresh checkout with no worktrees)
stays green. That enumeration runs with **`core.quotePath=false`**, which since issue
#1217 the shared constant itself carries; see the note beside `TOOL` below for why the
default would turn every legally-named non-ASCII path into a false RED. This guard judges path **strings**, never filesystem
entries: the whole point is to flag a path that *cannot exist on the host running the
guard*, and the `--files-from` harness feeds synthetic path strings (a reserved-name
fixture must never be planted on disk — that is the very incident this guard
prevents).

Fail-closed (issue #724 `EnumerationError`): a population that cannot be
established, or that is empty before any judgement, exits non-zero — "audited
nothing" must never read as "audited everything, found nothing". This guard
applies no exclusions: every tracked path is part of every consumer's clone, so
every tracked path is audited.

Usage:
    lint-windows-uncheckoutable-path.py [--root DIR] [--files-from PATH]

Exit status is 0 only when every tracked path is checkout-valid on Windows. It is
non-zero when any path would be refused and when the enumeration is unusable;
callers distinguish them by reading the report, never the exit code.
"""

from __future__ import annotations

import argparse
import importlib.util
import os
import sys
from pathlib import Path

# Import the shared population reader with the same spec_from_file_location idiom the
# directory's other lints use (the module's filename is not an importable identifier).
_POP_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lint_population.py")
_spec = importlib.util.spec_from_file_location("lint_population", _POP_PATH)
if _spec is None or _spec.loader is None:
    raise SystemExit(
        f"lint-windows-uncheckoutable-path: could not load the shared population reader "
        f"{_POP_PATH}; refusing to audit rather than enumerating without it"
    )
_pop = importlib.util.module_from_spec(_spec)
try:
    _spec.loader.exec_module(_pop)
except Exception as _exc:  # a broken sibling must fail closed here, naming the dependency,
    # not mid-scan with a raw traceback naming the interpreter.
    raise SystemExit(
        f"lint-windows-uncheckoutable-path: the shared population reader {_POP_PATH} could "
        f"not be loaded ({_exc.__class__.__name__}: {_exc}); refusing to audit"
    ) from _exc
EnumerationError = _pop.EnumerationError

TOOL = "lint-windows-uncheckoutable-path"

#: This guard depends on the enumeration being unquoted, but no longer owns the flag:
#: issue #1217 retired the module-private `_LS_FILES_INDEX_UNQUOTED` PR #1201 added here,
#: because `lint_population.LS_FILES_INDEX` now carries `-c core.quotePath=false` for every
#: caller. The mechanism and the `-z` trade-off are stated once, in that module's docstring.
#: What is specific to THIS guard is the residual: the flag drops only the *non-ASCII*
#: escaping, so a path containing a backslash, a double quote, or a control character is
#: still C-quoted — and those are exactly the paths this guard must reject. The quoted
#: rendering still carries a backslash, so each stays RED; only the reason string may name
#: the backslash rule rather than the underlying one, a diagnostic nuance on an
#: already-correct verdict rather than a missed violation. Were the flag ever dropped, a
#: legitimately-named non-ASCII path would take the whole suite RED for a character it does
#: not contain, and this guard deliberately offers no `# …-ok:` declaration marker to wave
#: that through.

#: Forbidden characters in a path component (git's Windows rule). `:` is included, which
#: also subsumes a leading DOS drive prefix (`C:`), so no separate drive-prefix arm exists.
_FORBIDDEN_CHARS = frozenset('<>:"|?*')

#: Reserved device-name stems with no numeric suffix (compared case-insensitively).
_FIXED_RESERVED = frozenset({"aux", "con", "prn", "nul", "conin$", "conout$"})

#: Every reserved device-name stem (lowercased), computed once. The COM/LPT asymmetry is
#: modelled exactly as git does it: COM1..COM9 — NOT COM0 (git tests c < '1' || c > '9'),
#: LPT0..LPT9 — LPT0 IS reserved (git tests isdigit()).
_RESERVED_STEMS = frozenset(
    _FIXED_RESERVED
    | {"com" + d for d in "123456789"}
    | {"lpt" + d for d in "0123456789"}
)


def _is_reserved_stem(lc_component: str) -> str | None:
    """Return the matched reserved stem, or None.

    A component matches when it begins with a reserved stem and — after skipping any
    trailing spaces — is at end-of-component or is followed by `.` or `:`.
    """
    for stem in _RESERVED_STEMS:
        if not lc_component.startswith(stem):
            continue
        rest = lc_component[len(stem):].lstrip(" ")
        if rest == "" or rest[0] in ".:":
            return stem.upper()
    return None


def check_component(component: str) -> str | None:
    """Return a violation reason for one path component, or None if it is valid.

    `component` is a single segment already split on `/` (never containing `/`).
    """
    # Control characters 0x01-0x1F anywhere in the component.
    for ch in component:
        if "\x01" <= ch <= "\x1f":
            return f"control-character(0x{ord(ch):02x})"

    # Reserved device names are checked BEFORE the forbidden-character arm below, so a
    # reserved name carrying a `:` suffix (`nul:ads`) is reported as the reserved-device
    # violation rather than as a stray `:` — the diagnostic then points at the dominant
    # cause. A component with a forbidden character and no reserved stem falls through to
    # the forbidden-character arm unchanged.
    reserved = _is_reserved_stem(component.lower())
    if reserved is not None:
        return f"reserved-device-name({reserved})"

    for ch in component:
        if ch in _FORBIDDEN_CHARS:
            return f"forbidden-character({ch!r})"

    # Trailing space or period, except the special components `.` and `..`.
    if component not in (".", "..") and component and component[-1] in " .":
        return f"trailing-{'space' if component[-1] == ' ' else 'period'}"

    return None


def check_path(path: str) -> str | None:
    """Return a violation reason for a whole repo-relative path, or None if valid.

    The reason names the offending component and the rule it broke, so the fix is
    obvious without reading git's source.
    """
    # Backslash is rejected anywhere in the path (git treats it as a separator on
    # Windows/Cygwin), so check the whole string before splitting on `/`.
    if "\\" in path:
        return f"{path} -> backslash-in-path"

    for component in path.split("/"):
        if component == "":
            # An empty component (leading/trailing/doubled `/`) is not a Windows
            # reserved-name concern; git ls-files never emits one. Skip it rather
            # than mis-flagging it as a trailing-period-style violation.
            continue
        reason = check_component(component)
        if reason is not None:
            return f"{path} -> {component!r} {reason}"
    return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Fail when a tracked path would be refused by git's Windows checkout "
            "validation (the whole repository is cloned by every plugin consumer)."
        )
    )
    _pop.add_population_arguments(parser)
    args = parser.parse_args(argv)

    root = _pop.resolve_root(args.root, tool=TOOL)

    try:
        population = _pop.enumerate_population(
            root,
            Path(args.files_from) if args.files_from else None,
            ls_files_argv=_pop.LS_FILES_INDEX,
        )
    except EnumerationError as exc:
        print(f"{TOOL}: enumeration unusable: {exc}", file=sys.stderr)
        return 1

    findings = [reason for path in population if (reason := check_path(path)) is not None]

    for finding in findings:
        print(f"{TOOL}: RED: {finding}")
    # The tally counts every path judged, against the population — this guard applies no
    # exclusions, so the two are equal and a collapsed-to-zero enumeration is impossible
    # to mistake for a clean audit (EnumerationError already fails an empty population).
    print(f"{TOOL}: audited {len(population)} tracked path(s), {len(findings)} violation(s)")
    if findings:
        print(
            f"{TOOL}: {len(findings)} tracked path(s) would be refused by git's Windows "
            "checkout validation — every Windows clone of this repository would fail. "
            "Rename or remove the offending path(s); there is no declaration marker for "
            "this class.",
            file=sys.stderr,
        )
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
