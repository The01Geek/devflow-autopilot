#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Coverage-map ratchet guard (issue #591).

Fails RED — never a skip, never a silent pass — when the module coverage map
(`lib/test/modules/coverage-map.json`) falls out of sync with the git-tracked
`lib/` / `scripts/` surface or the module registry, so a new code unit cannot
ship without a recorded coverage decision.

Selection path derives every decision through `git` and `python3` ONLY (both
preflight-guaranteed; CLAUDE.md guard-class 2 forbids a non-preflight PATH tool
deciding a selection): git-tracked paths come from `git ls-files` (an index read,
shallow-clone-safe, reads no history), and all shape/membership logic is Python.

The guard is importable — `evaluate(...)` is a pure function over
(tracked_files, map value, registry value) so `test_coverage_map_guard.py` can
drive every one of its arms with synthetic fixtures — and runnable as a CLI:
`python3 lib/test/coverage_map_guard.py [repo_root]` prints one violation per
line to stdout and exits non-zero on any violation (or a fail-closed input
error), 0 when clean.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

MAP_REL = "lib/test/modules/coverage-map.json"
REGISTRY_REL = "scripts/workflow-flight-recorder-registry.json"
RUN_SH_REL = "lib/test/run.sh"
GUARD_REL = "lib/test/coverage_map_guard.py"
MODULES_GLOB = "lib/test/modules/*.sh"

# The synthetic aggregate key: no mechanical derivation ever produces it, so both
# halves of arm 9 exempt it rather than reporting it as a stale entry.
UNLABELED_KEY = "unlabeled"

# The depth-1 patterns, as (top-level dir, extension) pairs. Complete by
# construction at seeding time (issue #591 AC). Note scripts/*.jq is deliberately
# NOT a pattern — a depth-1 scripts/*.jq is a code unit outside the set, caught by
# arm 5 (absent from non_code_exempt) so the pattern set itself is ratcheted.
PATTERNS = frozenset(
    {("lib", ".sh"), ("lib", ".jq"), ("lib", ".py"), ("scripts", ".sh"), ("scripts", ".py")}
)
CODE_EXTS = frozenset({".sh", ".jq", ".py"})
TOP_DIRS = frozenset({"lib", "scripts"})
UNMODULARIZED = "unmodularized"

MAP_REMEDY = (
    f"repair or regenerate {MAP_REL} per CONTRIBUTING.md's module-authoring "
    "checklist (schema_version 1; files/run_sh_blocks objects; "
    "non_code_exempt/exempt_subtrees arrays; generated_by string)"
)
REGISTRY_REMEDY = (
    f"repair {REGISTRY_REL} so test_modules is a JSON object of module entries"
)


# ── Shared label derivation (issue #695) ──────────────────────────────────────
# ONE implementation, used for lib/test/run.sh and for every lib/test/modules/*.sh,
# so the monolith half and the module half of arm 9 can never disagree about what a
# "label" is. It anchors on ASSERTION-NAME POSITION — the first quoted argument of an
# assertion call — so `# see issue #533` in a comment, or a `#533` inside a later
# argument, derives nothing. That positional anchor is the whole point: a label set
# derived by scanning for `#\d+` anywhere would attribute a module's *history notes*
# as coverage it does not carry.

# Assertion heads recognized everywhere: the monolith's helpers plus the namespaced
# harness API a module uses instead of them. `devflow_module_pin_count` is included
# for coverage of the whole namespaced API; its first argument is a pinned literal
# rather than a name, which only ever narrows what a module can under-report.
_BASE_ASSERTION_HEADS = (
    "assert_eq",
    "assert_true",
    "assert_pin_unique",
    "assert_pin_red_under",
    "assert_pin_red_on_removal",
    "check",
    "devflow_module_pin_unique",
    "devflow_module_pin_red_under",
    "devflow_module_pin_present",
    "devflow_module_pin_count",
)

_FUNCTION_DEF_RE = re.compile(r"^([ \t]*)([A-Za-z_][A-Za-z0-9_]*)\(\)[ \t]*\{", re.MULTILINE)
_LABEL_RE = re.compile(r"#(\d{2,5})")


def _function_bodies(text: str) -> "dict[str, str]":
    """Map each `name() {` definition in TEXT to its body text.

    A ONE-LINE definition (`mktemp() { return 1; }` — the fixture-stub shape
    `lib/test/run.sh` uses to shadow a command inside a subshell) yields only the text
    between its own braces. Otherwise the body runs to the first line that closes the
    definition at the SAME indentation — the shape every multi-line helper in this
    repo's shell sources uses. Handling the one-liner separately is load-bearing: its
    closer never appears on a line of its own, so a shared fallback would hand a stub
    named `sed`/`mktemp` a "body" made of the surrounding real assertions and promote
    it to an assertion head. A definition whose closer is genuinely never found yields
    the remainder of the file, which can only over-approximate."""
    lines = text.split("\n")
    starts: "list[tuple[int, str, str, int]]" = []
    for match in _FUNCTION_DEF_RE.finditer(text):
        line_index = text.count("\n", 0, match.start())
        line_start = text.rfind("\n", 0, match.start()) + 1
        starts.append((line_index, match.group(2), match.group(1), match.end() - line_start))
    bodies: "dict[str, str]" = {}
    for line_index, name, indent, brace_offset in starts:
        line = lines[line_index]
        if "}" in line[brace_offset:]:
            bodies[name] = line[brace_offset : line.rindex("}")]
            continue
        closer = indent + "}"
        end = len(lines)
        for offset in range(line_index + 1, len(lines)):
            if lines[offset] == closer or lines[offset].startswith(closer + " "):
                end = offset
                break
        bodies[name] = "\n".join(lines[line_index + 1 : end])
    return bodies


def _assertion_heads(text: str) -> "set[str]":
    """The base heads plus every module-private assertion wrapper defined in TEXT.

    A wrapper is a function that FORWARDS ITS OWN FIRST POSITIONAL into a recognized
    head's name slot — `assert_eq "$1" …`, `devflow_module_pin_unique "$1" …`, `"$@"` —
    the shape of `_cap_fail`, `_ra_has`, `_raf_pin_unique`, `drp` and friends.
    Discovery iterates to a fixpoint so a wrapper around a wrapper is also covered.
    Without this, converting a monolith `assert_pin_unique` call to the namespaced
    API or to a private wrapper would make the label invisible — exactly the blindness
    that made the retired `generated_by` scanner under-report module coverage.

    The forwarding requirement is what keeps the over-approximation safe. Merely
    *containing* a head is far too loose: `lib/test/run.sh` writes fixture stub scripts
    inside heredocs, so a `sed() {` / `mktemp() {` line inside one is picked up as a
    definition whose apparent body bleeds into surrounding real assertions. Treating
    those as heads would make every ordinary `sed 's/#604/#609/'` derive a spurious
    label from a fixture argument — a name the tree never asserts."""
    heads = set(_BASE_ASSERTION_HEADS)
    bodies = _function_bodies(text)
    while True:
        grown = False
        for name, body in bodies.items():
            if name in heads:
                continue
            for head in heads:
                forwards = rf"(?<![A-Za-z0-9_]){re.escape(head)}[ \t]+\"\$(?:\{{1\}}|[1@])\""
                if re.search(forwards, body):
                    heads.add(name)
                    grown = True
                    break
        if not grown:
            return heads


def derive_labels(text: str) -> "set[str]":
    """Return the issue labels TEXT asserts, as bare digit strings.

    A label is derived only from the first quoted argument of an assertion call — the
    assertion NAME. Comments are stripped from consideration by the same rule: a `#`
    comment carries no assertion head in command position followed by a quoted name."""
    heads = _assertion_heads(text)
    alternation = "|".join(sorted((re.escape(head) for head in heads), key=len, reverse=True))
    # The separator admits a `\`-continuation, so a call whose name argument wraps to
    # the next line is still anchored at name position rather than silently missed.
    call_re = re.compile(
        rf"(?<![A-Za-z0-9_])(?:{alternation})[ \t\\\n]+(\"(?:[^\"\\]|\\.)*\"|'[^']*')"
    )
    # An assertion head can never be invoked from inside a `#` comment line, so the
    # comment lines are dropped before the scan — this is what makes a label token
    # that appears only in a comment underive, per the arm's positional contract.
    code = "\n".join(
        line for line in text.split("\n") if not line.lstrip().startswith("#")
    )
    labels: "set[str]" = set()
    for match in call_re.finditer(code):
        labels.update(_LABEL_RE.findall(match.group(1)))
    return labels


def _depth1(path: str) -> bool:
    parts = path.split("/")
    return len(parts) == 2 and parts[0] in TOP_DIRS


def _ext(path: str) -> str:
    name = path.rsplit("/", 1)[-1]
    dot = name.rfind(".")
    return name[dot:] if dot > 0 else ""


def _matches_pattern(path: str) -> bool:
    return _depth1(path) and (path.split("/")[0], _ext(path)) in PATTERNS


def _under_lib_or_scripts(path: str) -> bool:
    return path.split("/")[0] in TOP_DIRS and "/" in path


def _valid_owner(owner: object, valid_ids: "set[str] | None") -> bool:
    if owner == UNMODULARIZED:
        return True
    if valid_ids is None:
        # Registry unreadable/wrong-shape: the comparand set is unavailable, so
        # owner validity cannot be established. Arm 8 already recorded the
        # registry failure; do not double-report every owner here.
        return True
    return isinstance(owner, str) and owner in valid_ids


def _registry_module_ids(registry_value: object) -> "set[str] | None":
    """Return the set of registered test_modules ids, or None if the registry is
    absent/unreadable/wrong-shape (including a non-object test_modules section)."""
    if not isinstance(registry_value, dict):
        return None
    modules = registry_value.get("test_modules")
    if not isinstance(modules, dict):
        return None
    return set(modules.keys())


def _map_shape_error(map_value: object) -> "str | None":
    """Return a specific breadcrumb if the map is not a well-shaped object, else None.

    Structural types only — arm 4. Owner *values* are checked by arm 3, and an
    empty-but-legal `files: {}` is a valid shape (it makes every unit unlisted,
    caught non-vacuously by arm 1), so it is NOT a shape error here."""
    if not isinstance(map_value, dict):
        return f"coverage-map is not a JSON object; {MAP_REMEDY}"
    # bool is an int subclass, so `isinstance(True, int)` is True and `True == 1`; reject
    # bool explicitly (mirrors the sibling generator's T13e manifest_version guard) so a
    # `"schema_version": true` is not accepted as integer 1.
    schema_version = map_value.get("schema_version")
    if isinstance(schema_version, bool) or not isinstance(schema_version, int) or schema_version != 1:
        return f"coverage-map schema_version must be integer 1; {MAP_REMEDY}"
    if not isinstance(map_value.get("files"), dict):
        return f"coverage-map 'files' must be a JSON object; {MAP_REMEDY}"
    if not isinstance(map_value.get("run_sh_blocks"), dict):
        return f"coverage-map 'run_sh_blocks' must be a JSON object; {MAP_REMEDY}"
    if not isinstance(map_value.get("non_code_exempt"), list):
        return f"coverage-map 'non_code_exempt' must be a JSON array; {MAP_REMEDY}"
    if not isinstance(map_value.get("exempt_subtrees"), list):
        return f"coverage-map 'exempt_subtrees' must be a JSON array; {MAP_REMEDY}"
    if not isinstance(map_value.get("generated_by"), str):
        return f"coverage-map 'generated_by' must be a string; {MAP_REMEDY}"
    for key, entry in map_value["files"].items():
        if not isinstance(entry, dict) or not isinstance(entry.get("owner"), str):
            return f"coverage-map files entry {key!r} must be an object with a string 'owner'; {MAP_REMEDY}"
    for key, entry in map_value["run_sh_blocks"].items():
        if not isinstance(entry, dict) or not isinstance(entry.get("owner"), str):
            return f"coverage-map run_sh_blocks entry {key!r} must be an object with a string 'owner'; {MAP_REMEDY}"
    for item in map_value["non_code_exempt"]:
        if not isinstance(item, str):
            return f"coverage-map non_code_exempt entries must be strings; {MAP_REMEDY}"
    for item in map_value["exempt_subtrees"]:
        if not isinstance(item, str):
            return f"coverage-map exempt_subtrees entries must be strings; {MAP_REMEDY}"
    return None


def evaluate(
    tracked_files,
    map_value,
    registry_value,
    *,
    map_read_error: "str | None" = None,
    registry_read_error: "str | None" = None,
    run_sh_labels: "set[str] | None" = None,
    module_labels: "dict[str, set[str]] | None" = None,
    scan_read_errors: "list[str] | None" = None,
):
    """Return a list of violation breadcrumbs (empty ⇒ clean). Never raises.

    Each arm records a FAIL line. `map_read_error` / `registry_read_error`
    carry a read/parse failure the CLI already hit (arms 4 / 8 fail closed on an
    absent/unreadable file too, not only a wrong shape).

    `run_sh_labels` / `module_labels` / `scan_read_errors` carry arm 9's derived
    inputs, produced by `main()` and injected here exactly like the read-error
    keywords, so this function performs no file access and its positional call
    contract is unchanged. Omitting them (every pre-existing caller) leaves arm 9
    stood down — it has no derivation to compare against, and inventing an empty one
    would report every mapped label as stale."""
    violations = []

    # ── Arm 8: registry absent/unreadable/wrong-shape (incl. non-object test_modules)
    if registry_read_error is not None:
        violations.append(f"[arm8] registry unreadable: {registry_read_error}; {REGISTRY_REMEDY}")
        valid_ids = None
    else:
        valid_ids = _registry_module_ids(registry_value)
        if valid_ids is None:
            violations.append(
                f"[arm8] registry {REGISTRY_REL} is wrong-shape (test_modules is not a JSON object); {REGISTRY_REMEDY}"
            )

    # ── Arm 4: map absent/unreadable/wrong-shape → fail closed, skip map-dependent arms
    if map_read_error is not None:
        violations.append(f"[arm4] coverage-map unreadable: {map_read_error}; {MAP_REMEDY}")
        return violations
    shape_error = _map_shape_error(map_value)
    if shape_error is not None:
        violations.append(f"[arm4] {shape_error}")
        return violations

    files = map_value["files"]
    non_code_exempt = list(map_value["non_code_exempt"])
    exempt_subtrees = list(map_value["exempt_subtrees"])
    run_sh_blocks = map_value["run_sh_blocks"]
    tracked = set(tracked_files)
    non_code_set = set(non_code_exempt)

    # ── Arm 1: a git-tracked depth-1 pattern unit absent from `files`
    for path in sorted(tracked):
        if _matches_pattern(path) and path not in files:
            violations.append(
                f"[arm1] git-tracked depth-1 unit {path!r} matches a coverage pattern but is absent from coverage-map 'files' — add it with an owner"
            )

    # ── Arm 5: a git-tracked depth-1 file matching NO pattern, absent from non_code_exempt
    for path in sorted(tracked):
        if _depth1(path) and not _matches_pattern(path) and path not in non_code_set:
            hint = (
                " (it carries a code extension — extend the pattern set in map+guard+convention, never list a code file in non_code_exempt)"
                if _ext(path) in CODE_EXTS
                else ""
            )
            violations.append(
                f"[arm5] git-tracked depth-1 file {path!r} matches none of the coverage patterns and is absent from non_code_exempt{hint}"
            )

    # ── Arm 6: a git-tracked code file deeper than depth-1, outside every exempt subtree
    # Compare against a slash-terminated subtree prefix so an entry `lib/test` (no trailing
    # slash) matches `lib/test/x.sh` but NOT a sibling like `lib/testfoo/x.sh`.
    exempt_prefixes = [sub if sub.endswith("/") else sub + "/" for sub in exempt_subtrees]
    for path in sorted(tracked):
        if _under_lib_or_scripts(path) and not _depth1(path) and _ext(path) in CODE_EXTS:
            if not any(path.startswith(pref) for pref in exempt_prefixes):
                violations.append(
                    f"[arm6] git-tracked code file {path!r} is deeper than depth-1 and outside every exempt_subtrees entry — cover it or add its subtree to exempt_subtrees"
                )

    # ── Arm 2: a files or non_code_exempt entry naming a non-git-tracked path
    for path in sorted(files):
        if path not in tracked:
            violations.append(f"[arm2] coverage-map files entry {path!r} is not a git-tracked file")
    for path in non_code_exempt:
        if path not in tracked:
            violations.append(f"[arm2] coverage-map non_code_exempt entry {path!r} is not a git-tracked file")

    # ── Arm 7: a non_code_exempt entry whose path carries a code extension
    for path in non_code_exempt:
        if _ext(path) in CODE_EXTS:
            violations.append(
                f"[arm7] coverage-map non_code_exempt entry {path!r} carries a code extension — a code unit misfiled as non-code; move it to 'files' with an owner"
            )

    # ── Arm 3: an owner value that is neither a registered module id nor `unmodularized`
    for path in sorted(files):
        owner = files[path].get("owner")
        if not _valid_owner(owner, valid_ids):
            violations.append(
                f"[arm3] coverage-map files entry {path!r} owner {owner!r} is neither a registered test_modules id nor {UNMODULARIZED!r}"
            )
    for label in sorted(run_sh_blocks):
        owner = run_sh_blocks[label].get("owner")
        if not _valid_owner(owner, valid_ids):
            violations.append(
                f"[arm3] coverage-map run_sh_blocks entry {label!r} owner {owner!r} is neither a registered test_modules id nor {UNMODULARIZED!r}"
            )

    # ── Arm 9: run_sh_blocks completeness + fully-extracted attribution (issue #695)
    violations.extend(
        _arm9(run_sh_blocks, valid_ids, run_sh_labels, module_labels, scan_read_errors)
    )

    return violations


ARM9_REMEDY = f"run `python3 {GUARD_REL} . --fix` to repair {MAP_REL}"


def _fully_extracted(run_sh_labels, module_labels):
    """Return {label: sorted module ids} for labels a module carries and run.sh does not.

    A label a module carries while assertions REMAIN in run.sh is *partially*
    extracted and is deliberately absent from this mapping: a single `owner` string
    cannot truthfully describe split coverage, so such a label keeps `unmodularized`
    and is never an attribution violation."""
    carriers: "dict[str, list[str]]" = {}
    for module_id, labels in sorted(module_labels.items()):
        for label in labels:
            if label in run_sh_labels:
                continue
            carriers.setdefault(label, []).append(module_id)
    return carriers


def _arm9(run_sh_blocks, valid_ids, run_sh_labels, module_labels, scan_read_errors):
    violations = []
    for error in scan_read_errors or []:
        violations.append(
            f"[arm9] label-derivation source unreadable: {error}; an unreadable source is "
            f"NOT an empty label set — restore the file, then {ARM9_REMEDY}"
        )
    if run_sh_labels is None or module_labels is None:
        # No derivation was injected (a pure-`evaluate` caller, or a scan that could
        # not establish the monolith's label set). Stand down rather than report every
        # mapped label as unmatched — the read failure above is the recorded signal.
        return violations

    for label in sorted(run_sh_labels - set(run_sh_blocks), key=_label_sort_key):
        if label == UNLABELED_KEY:
            continue
        violations.append(
            f"[arm9] label {label!r} is asserted in {RUN_SH_REL} but has no "
            f"coverage-map run_sh_blocks entry — {ARM9_REMEDY}"
        )

    if valid_ids is None:
        # The registered-id set is unavailable, so "owner names a module carrying the
        # label" cannot be established. Arm 8 already recorded the registry failure;
        # stand down here exactly as _valid_owner does, rather than double-reporting.
        return violations

    for label, carriers in sorted(
        _fully_extracted(run_sh_labels, module_labels).items(), key=lambda kv: _label_sort_key(kv[0])
    ):
        if label == UNLABELED_KEY:
            continue
        named = ", ".join(carriers)
        entry = run_sh_blocks.get(label)
        if entry is None:
            violations.append(
                f"[arm9] label {label!r} is carried wholly by module(s) {named} and asserted "
                f"nowhere in {RUN_SH_REL}, but has no coverage-map run_sh_blocks entry — "
                f"{ARM9_REMEDY}"
            )
            continue
        owner = entry.get("owner")
        if owner not in carriers:
            violations.append(
                f"[arm9] label {label!r} is fully extracted into module(s) {named} but its "
                f"coverage-map run_sh_blocks owner is {owner!r} — attribute it to a module "
                f"that carries it; {ARM9_REMEDY}"
            )
    return violations


def _label_sort_key(label: str):
    """Numeric-first ordering so violation lists are stable and human-readable."""
    return (0, int(label), "") if label.isdigit() else (1, 0, label)


def _git_tracked(repo_root: Path):
    """git-tracked repo-relative paths (index read; reads no history)."""
    result = subprocess.run(
        ["git", "-C", str(repo_root), "ls-files"],
        capture_output=True,
        text=True,
        check=True,
    )
    return [line for line in result.stdout.split("\n") if line]


def _load_json(path: Path):
    """Return (value, error). A read/parse failure returns (None, breadcrumb)."""
    try:
        return json.loads(path.read_text(encoding="utf-8")), None
    except FileNotFoundError:
        return None, f"{path} not found"
    except (OSError, UnicodeError) as error:
        return None, f"{path} unreadable ({error})"
    except json.JSONDecodeError as error:
        return None, f"{path} is malformed JSON ({error})"


def _scan_labels(repo_root: Path):
    """Read lib/test/run.sh and lib/test/modules/*.sh and derive their label sets.

    Returns (run_sh_labels, module_labels, read_errors). A source that cannot be read
    yields `None` (monolith) / an omitted module entry PLUS a named read error — never
    an empty label set, which would silently read as "this file asserts nothing" and
    turn a real completeness violation into a clean pass. All file access lives here,
    in main()'s call path; `evaluate` stays pure."""
    read_errors: "list[str]" = []
    try:
        run_sh_labels = derive_labels(
            (repo_root / RUN_SH_REL).read_text(encoding="utf-8")
        )
    except (OSError, UnicodeError) as error:
        run_sh_labels = None
        read_errors.append(f"{RUN_SH_REL} ({error})")
    module_labels: "dict[str, set[str]]" = {}
    for module_path in sorted((repo_root / "lib/test/modules").glob("*.sh")):
        module_id = module_path.stem
        try:
            module_labels[module_id] = derive_labels(
                module_path.read_text(encoding="utf-8")
            )
        except (OSError, UnicodeError) as error:
            read_errors.append(f"lib/test/modules/{module_path.name} ({error})")
    return run_sh_labels, module_labels, read_errors


def _apply_fix(map_value, run_sh_labels, module_labels):
    """Mutate MAP_VALUE's run_sh_blocks so arm 9 reports nothing. Returns True if changed.

    A missing run.sh label is added as `unmodularized` (its coverage is still in the
    monolith); a fully-extracted label's owner is set to a module that carries it. The
    repair never removes an entry — a map key with no derivation behind it is a curated
    historical record arm 9 deliberately does not report, so `--fix` does not delete it."""
    blocks = map_value["run_sh_blocks"]
    changed = False
    for label in sorted(run_sh_labels, key=_label_sort_key):
        if label == UNLABELED_KEY or label in blocks:
            continue
        blocks[label] = {"note": "", "owner": UNMODULARIZED}
        changed = True
    for label, carriers in _fully_extracted(run_sh_labels, module_labels).items():
        if label == UNLABELED_KEY:
            continue
        owner = carriers[0]
        entry = blocks.get(label)
        if entry is None:
            blocks[label] = {"note": "", "owner": owner}
            changed = True
        elif entry.get("owner") not in carriers:
            entry["owner"] = owner
            changed = True
    return changed


def _write_map(path: Path, map_value) -> None:
    """Serialize with the map's existing shape: 2-space indent, sorted keys, one
    trailing newline. Byte-identical to the checked-in file when nothing changed, which
    is what makes a second `--fix` run a no-op."""
    path.write_text(
        json.dumps(map_value, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )


def _run_fix(repo_root: Path) -> int:
    map_path = repo_root / MAP_REL
    map_value, map_error = _load_json(map_path)
    if map_error is not None:
        print(f"[fix-refused] coverage-map unreadable: {map_error}; {MAP_REMEDY}")
        return 1
    shape_error = _map_shape_error(map_value)
    if shape_error is not None:
        # Refuse to write rather than corrupt a malformed map: the repair assumes the
        # arm-4 shape, and a partial rewrite of a hand-corrupted file is worse than
        # leaving it exactly as the operator left it.
        print(f"[fix-refused] {shape_error}")
        return 1
    run_sh_labels, module_labels, read_errors = _scan_labels(repo_root)
    if read_errors or run_sh_labels is None:
        for error in read_errors:
            print(f"[fix-refused] label-derivation source unreadable: {error}")
        return 1
    if _apply_fix(map_value, run_sh_labels, module_labels):
        _write_map(map_path, map_value)
        print(f"[fix] repaired {MAP_REL}")
    else:
        print(f"[fix] {MAP_REL} already satisfies the coverage-map block-ownership arm")
    return 0


def main(argv):
    # `--fix` is a HAND-INVOKED repair, never wired into the batched generated-artifact
    # pass: lib/test/regenerate-artifacts.py keeps the coverage map a `by-hand` judgment
    # row whose `#619 A3` assertion proves the pass leaves it byte-unchanged. The
    # positional repo-root argument is unchanged, so lib/test/run.sh's existing
    # invocation needs no edit.
    arguments = [argument for argument in argv[1:] if argument != "--fix"]
    if "--fix" in argv[1:]:
        return _run_fix(Path(arguments[0]).resolve() if arguments else Path.cwd())
    repo_root = Path(argv[1]).resolve() if len(argv) > 1 else Path.cwd()
    # git is preflight-guaranteed, but honor the file's fail-closed-with-a-named-breadcrumb
    # posture (the JSON reads do the same via _load_json) rather than letting a git failure
    # surface as a raw traceback.
    try:
        tracked = _git_tracked(repo_root)
    except (subprocess.CalledProcessError, FileNotFoundError, OSError) as error:
        print(
            f"[input-error] git ls-files failed under {repo_root} ({error}); cannot "
            "enumerate the tracked lib/scripts surface — run from a git repo with git on PATH"
        )
        return 1
    map_value, map_error = _load_json(repo_root / MAP_REL)
    registry_value, registry_error = _load_json(repo_root / REGISTRY_REL)
    run_sh_labels, module_labels, scan_read_errors = _scan_labels(repo_root)
    violations = evaluate(
        tracked,
        map_value,
        registry_value,
        map_read_error=map_error,
        registry_read_error=registry_error,
        run_sh_labels=run_sh_labels,
        module_labels=module_labels,
        scan_read_errors=scan_read_errors,
    )
    for line in violations:
        print(line)
    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
