#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Cloud-writer trust-closure dependency classification (issue #583, AC5).

Why this exists: the AC1 reachability contract (``cloud_writer_contract.py``)
names *which* bundled helper entry points a cloud writer session reaches, and
pins each to the vendored leading token the matcher grants. But a granted
leading token only vouches for the *first* executable token of a command — it
says nothing about what that helper then reaches when it runs: a sourced
sibling, an exec'd script, an imported module, or an external binary. This
module classifies those static source/exec/import edges out of every AC1-closure
helper entry point, so the executable trust boundary can be audited one hop
deep, not just at the leading token.

The classification is derived-plus-declared, mirroring the AC1 design
(``DISPATCH_EDGES`` is hand-declared data checked by a consistency guard):

* **import edges** (``.py`` entry points) and **source edges** (``.sh`` ``.``/
  ``source`` includes) are **derived** by static scan of the real source, so an
  added import or sourced sibling cannot silently escape the classification
  (reverse-drift is structural).
* **exec edges** (an external binary or a repository-owned script the helper
  runs) are **declared** in ``EXEC_EDGES`` and **forward-verified** against the
  *comment-stripped* source (an external target counts the ``DEVFLOW_<TOOL>``
  override form as evidence too): an invented, typo'd, or comment-only declared
  token goes RED. This liveness check does not give exec edges the structural
  reverse-drift the derived kinds have — a newly-added, undeclared exec still
  escapes — the same disclosed tradeoff AC1's hand-declared ``DISPATCH_EDGES``
  accepts.

``check_dependencies()`` is the AC5 guard. It fails when:

* an AC1-closure entry point is not classified (coverage gap);
* a **repository-owned** edge does not resolve *beneath*
  ``.devflow/vendor/devflow/`` (a repo-root ``../../scripts/…`` form escapes the
  vendored tree and is rejected) or its target file is absent on disk;
* an **external** runtime edge names no preflight guarantee (``lib/preflight.sh``
  guarantees ``git``/``gh``/``jq``/``python3``/PyYAML) or explicit profile grant;
* a declared exec edge's target token is absent from the helper source.

``classify_all()`` returns the full machine-readable classification (one row per
edge) — the AC5 deliverable — and ``main(["show"])`` prints it as JSON.
"""
from __future__ import annotations

import ast
import functools
import json
import re
import sys
from pathlib import Path
from posixpath import normpath

# Reuse the AC1 closure as the single source of truth for entry points and the
# one granted vendored prefix, so this classification can never name an entry
# point the reachability contract does not.
_LIBTEST = Path(__file__).resolve().parent
sys.path.insert(0, str(_LIBTEST))
import cloud_writer_contract as cwc  # noqa: E402

REPO_ROOT = cwc.REPO_ROOT
VENDOR_PREFIX = cwc.VENDOR_PREFIX  # ".devflow/vendor/devflow/"

# lib/preflight.sh guarantees exactly these external runtimes on PATH; an
# external edge is authorized only by naming one of them (or, below, an explicit
# profile grant). Kept in lockstep with lib/preflight.sh — a new hard preflight
# prerequisite is added here so an external edge onto it classifies authorized.
PREFLIGHT_GUARANTEES = frozenset({"git", "gh", "jq", "python3", "PyYAML"})

EDGE_KINDS = frozenset({"source", "exec", "import"})
EDGE_CLASSES = frozenset({"repo-owned", "external"})

# The Python module name PyYAML installs (its import edge maps to the PyYAML
# preflight guarantee, not the stdlib).
_PYYAML_MODULE = "yaml"


def entry_points():
    """Sorted repo-relative source paths of every AC1-closure helper entry point.

    The union of REQUIRED_HELPER_HEADS across all cloud profiles, mapped from the
    vendored leading token back to its repository-owned source path.
    """
    paths = set()
    for heads in cwc.REQUIRED_HELPER_HEADS.values():
        for token in heads:
            paths.add(cwc._helper_source_path(token))
    return sorted(paths)


# --- AC5: declared exec edges (external binaries + repo-owned script execs) -----
# Each entry point maps to the binaries/scripts it *runs* (subprocess/exec), the
# one edge kind a static import/source scan cannot deterministically recover. An
# external target names a preflight-guaranteed binary; a repo-owned target is a
# repo-relative script path (resolved beneath the vendored tree by the guard).
# Every target here is forward-verified present in the helper source, so a stale
# declaration fails closed rather than vouching for an edge that no longer exists.
_EXT = "external"
_REPO = "repo-owned"
EXEC_EDGES = {
    "scripts/run-jq.sh": [("jq", _EXT)],
    "scripts/config-get.sh": [("git", _EXT), ("python3", _EXT)],
    "scripts/workpad.py": [("gh", _EXT), ("git", _EXT)],
    "scripts/parse-acs.py": [("gh", _EXT)],
    "scripts/branch-for-issue.py": [("git", _EXT)],
    "scripts/file-deferrals.py": [("gh", _EXT)],
    "scripts/match-deferrals.py": [("gh", _EXT), ("git", _EXT)],
    # resolve-review-overrides.py delegates every config read to config-get.sh
    # (never re-parsing config itself) — a repository-owned exec edge.
    "scripts/resolve-review-overrides.py": [("scripts/config-get.sh", _REPO)],
    "scripts/stale-prose-lint.py": [("git", _EXT)],
    "scripts/match-lint-adjudications.py": [("git", _EXT)],
    "scripts/apply-labels.sh": [("gh", _EXT)],
    "scripts/ensure-label.sh": [("gh", _EXT)],
    "scripts/dismiss-stale-rejections.sh": [("gh", _EXT)],
    "scripts/load-prompt-extension.sh": [("git", _EXT)],
    "scripts/react-to-trigger.sh": [("gh", _EXT)],
    "scripts/extract-doc-needed-paths.sh": [("git", _EXT)],
    "scripts/update-branch-checkpoint.sh": [("git", _EXT)],
    # efficiency-trace.sh runs its jq program, a git history walk, and the
    # config_fingerprint.py helper (a repository-owned exec edge).
    "lib/efficiency-trace.sh": [
        ("jq", _EXT),
        ("git", _EXT),
        ("python3", _EXT),
        ("scripts/config_fingerprint.py", _REPO),
    ],
}


class Edge:
    """One classified dependency edge out of a helper entry point.

    ``target`` is a binary name (external) or a repo-relative path (repo-owned).
    ``auth`` names the authorization for an external edge (a preflight guarantee
    or a ``grant:<token>`` string); it is ``None`` for a repo-owned edge and for
    an *unauthorized* external edge (which the guard rejects).
    """

    __slots__ = ("helper", "kind", "target", "klass", "auth")

    def __init__(self, helper, kind, target, klass, auth=None):
        self.helper = helper
        self.kind = kind
        self.target = target
        self.klass = klass
        self.auth = auth

    def as_dict(self):
        return {
            "helper": self.helper,
            "kind": self.kind,
            "target": self.target,
            "class": self.klass,
            "auth": self.auth,
        }

    def __repr__(self):
        return f"Edge({self.as_dict()!r})"


@functools.lru_cache(maxsize=None)
def _read(rel):
    # Sources are read-only within a run and each entry point is read by both the
    # scanner and exec-edge forward-verification, so memoize to one read per file.
    return (REPO_ROOT / rel).read_text(encoding="utf-8")


def _sibling_module_path(module):
    """Repo-relative path of a repository-owned Python sibling module, or None.

    A closure entry point that imported a repo-owned sibling (``scripts/x.py`` /
    ``lib/x.py``) would be a repo-owned import edge; today none do, but the guard
    classifies one correctly if introduced.
    """
    top = module.split(".", 1)[0]
    for cand in (f"scripts/{top}.py", f"lib/{top}.py"):
        if (REPO_ROOT / cand).is_file():
            return cand
    return None


def _scan_python_imports(helper):
    """Derive import edges from a ``.py`` entry point via a full AST walk.

    Walks every ``import``/``from`` node (not just module top level), so a lazy
    in-function import (e.g. match-deferrals.py's ``import yaml``) is classified.
    """
    edges = []
    seen = set()
    tree = ast.parse(_read(helper), filename=helper)
    for node in ast.walk(tree):
        modules = []
        if isinstance(node, ast.Import):
            modules = [alias.name for alias in node.names]
        elif isinstance(node, ast.ImportFrom):
            # Relative imports (level > 0) would be repo-owned package siblings;
            # the closure helpers use none. Absolute (level 0) name the module.
            if node.level == 0 and node.module:
                modules = [node.module]
        for module in modules:
            top = module.split(".", 1)[0]
            if top in seen:
                continue
            seen.add(top)
            repo = _sibling_module_path(top)
            if repo is not None:
                edges.append(Edge(helper, "import", repo, "repo-owned"))
            elif top == _PYYAML_MODULE:
                edges.append(Edge(helper, "import", top, "external",
                                  "PyYAML (preflight guarantee)"))
            elif top in sys.stdlib_module_names:
                edges.append(Edge(helper, "import", top, "external",
                                  "python3 standard library (preflight guarantee: python3)"))
            else:
                # An unvetted third-party import names no preflight guarantee —
                # auth stays None and the guard rejects it.
                edges.append(Edge(helper, "import", top, "external", None))
    return edges


# A `.`/`source` command in a closure `.sh` helper — matched at any *command
# position* (line start, or after `&&`/`||`/`;`/`{`/`(`), because closure helpers
# source their resolver siblings inside compounds (`[ -f X ] && . X`, run-jq.sh)
# and `||`-guarded includes (efficiency-trace.sh), not only at line start. `.`
# must be followed by whitespace, so a `../parent` path never false-matches.
_SRC_CMD = re.compile(r'(?:^|[;&|{}()]|&&|\|\|)[ \t]*(?:\.|source)[ \t]')
# The sourced-file operand: a path token ending in `.sh`/`.bash`, allowing the
# `$VAR` / `${VAR}` / `$(…)`-substitution chars the include expressions carry. The
# `$(cd … && pwd)` prefix is stripped naturally (parens/quotes are not in the
# class), leaving the helper-dir-relative tail.
_SH_TOKEN = re.compile(r'[\w./${}\[\]\-]*\.(?:sh|bash)')

# The include target is always expressed relative to the helper's own directory
# — `$HERE/x.sh`, `${VAR}/x.sh`, `$_DIR/../lib/x.sh`, or `$(cd … && pwd)/[../]…/x.sh`
# — so the tail after the leading directory expression resolves against the
# helper dir (see the call sites in run-jq/apply-labels/efficiency-trace).


def _source_tail(raw_target):
    """Extract the helper-dir-relative include tail from a `.`/`source` operand.

    Strips a leading `$VAR` / `${VAR}` directory expression, leaving e.g.
    `../lib/resolve-gh.sh`, `resolve-jq.sh`, or `config-source.sh` — each
    relative to the sourcing helper's directory.
    """
    # The operand comes from `_SH_TOKEN`, whose character class excludes parens
    # and quotes, so any `$(cd … && pwd)` prefix and surrounding quotes are
    # already gone — only a leading `$VAR` / `${VAR}` directory expression can
    # remain. Drop it, then the leading `/`.
    tok = raw_target.strip()
    if tok.startswith("$"):
        m = re.match(r'\$\{?\w+\}?', tok)
        if m:
            tok = tok[m.end():]
    return tok.lstrip("/")


def _scan_shell_sources(helper):
    """Derive source edges from a `.sh` entry point's `.`/`source` includes."""
    edges = []
    seen = set()
    helper_dir = str(Path(helper).parent.as_posix())
    for line in _read(helper).splitlines():
        if line.lstrip().startswith("#"):
            continue
        for cmd in _SRC_CMD.finditer(line):
            tok = _SH_TOKEN.search(line, cmd.end())
            if not tok:
                continue
            tail = _source_tail(tok.group())
            if not tail or not tail.endswith((".sh", ".bash")):
                continue
            repo_rel = normpath(f"{helper_dir}/{tail}")
            if repo_rel in seen:
                continue
            seen.add(repo_rel)
            edges.append(Edge(helper, "source", repo_rel, "repo-owned"))
    return edges


def _declared_exec_edges(helper):
    edges = []
    for target, klass in EXEC_EDGES.get(helper, []):
        if klass == _EXT:
            auth = (f"{target} (preflight guarantee)"
                    if target in PREFLIGHT_GUARANTEES else None)
            edges.append(Edge(helper, "exec", target, "external", auth))
        else:
            edges.append(Edge(helper, "exec", target, "repo-owned"))
    return edges


def classify_all():
    """Full machine-readable dependency classification over the AC1 closure.

    One ``Edge`` per static source/exec/import edge out of every entry point.
    """
    edges = []
    for helper in entry_points():
        if helper.endswith(".py"):
            edges.extend(_scan_python_imports(helper))
        elif helper.endswith(".sh"):
            edges.extend(_scan_shell_sources(helper))
        edges.extend(_declared_exec_edges(helper))
    return edges


def resolves_beneath_vendor(repo_rel):
    """True iff ``repo_rel`` vendors to a path *beneath* ``.devflow/vendor/devflow/``.

    A repo-root-escaping form (``../../scripts/foo`` from a ``scripts/`` helper)
    normalizes to ``.devflow/vendor/scripts/foo`` — outside the vendored tree —
    and is rejected. This is the executable trust boundary the AC5 guard enforces.
    """
    # An absolute target would reset the join (`.devflow/vendor/devflow/` + `/x`
    # normalizes to `.devflow/vendor/devflow/x`, and `REPO_ROOT / "/x"` resets to
    # `/x`), so reject it up front — no legitimate edge is absolute (derived tails
    # are `lstrip("/")`-ed; declared repo-owned targets are repo-relative).
    if repo_rel.startswith("/"):
        return False
    vendored = normpath(VENDOR_PREFIX + repo_rel)
    root = VENDOR_PREFIX.rstrip("/")
    return vendored == root or vendored.startswith(root + "/")


def _strip_line_comments(source):
    """Drop the `#`-to-EOL portion of each line (shell and python line comments).

    A heuristic for forward-verification only: it over-strips a `#` inside a string
    literal, which can only make the presence check *stricter* (a false "not
    found"), never falsely pass — acceptable, and the point is to stop a token that
    lives only in a comment from vouching for a declared edge. It does NOT strip a
    python triple-quoted docstring, so forward-verification catches an invented or
    typo'd token and a comment-only stale mention, but is not a guarantee against a
    declaration whose token survives only in a docstring — the same disclosed
    liveness limitation as the exec dimension's lack of reverse-drift.
    """
    return "\n".join(line.split("#", 1)[0] for line in source.splitlines())


def _external_evidence_tokens(bin_name):
    """Whole-word tokens that count as a live invocation of an external binary.

    The closure helpers invoke resolvable externals through the documented
    `DEVFLOW_<TOOL>` override (`"${DEVFLOW_GH:=…}"`, `os.environ.get("DEVFLOW_GH")`)
    as well as the bare name / `.exe`, so any of the three counts as evidence.
    """
    return {bin_name, bin_name + ".exe", "DEVFLOW_" + bin_name.upper()}


def _exec_target_present(helper, target, klass):
    """Forward-verification: a declared exec target actually appears in code.

    Searches the comment-stripped source so a token that lives only in a comment
    cannot vouch for a stale declaration (see `_strip_line_comments`).
    """
    code = _strip_line_comments(_read(helper))
    tokens = {Path(target).name} if klass == _REPO else _external_evidence_tokens(target)
    return any(re.search(r'(?<!\w)' + re.escape(t) + r'(?!\w)', code) for t in tokens)


def check_dependencies(edges=None):
    """AC5 guard. Return a list of human-readable violations (empty == OK).

    When ``edges`` is None, classifies the live closure; a caller may pass a
    synthetic edge list to drive a single invariant (the guard's non-vacuity
    proofs inject one crafted edge at a time).
    """
    live = edges is None
    if live:
        edges = classify_all()
    errors = []

    if live:
        # Coverage, per derived-scan kind — not merely per-helper. Checking only
        # "the helper appears in some edge" is defeated by its declared exec edges:
        # a silent import/source-scan regression that drops every derived edge
        # still leaves the helper present via its exec edge, masking the exact scan
        # gap this check exists to catch. So require the derived scanner's output
        # where a helper must have one: a `.py` entry point always imports at least
        # argparse/sys, so zero import edges means the AST import scan regressed.
        # A `.sh` helper may legitimately source no sibling (config-get.sh sources
        # nothing), so its floor stays "at least one edge of any kind"; a dropped
        # source edge on a helper that does source (run-jq.sh) is caught by that
        # helper's positive fixture instead.
        kinds_by_helper = {}
        for e in edges:
            kinds_by_helper.setdefault(e.helper, set()).add(e.kind)
        for helper in entry_points():
            kinds = kinds_by_helper.get(helper, set())
            if not kinds:
                errors.append(f"entry point not classified (no edges scanned): {helper}")
            elif helper.endswith(".py") and "import" not in kinds:
                errors.append(
                    f"entry point produced no import edges (AST import scan gap?): {helper}"
                )

    for e in edges:
        if e.kind not in EDGE_KINDS:
            errors.append(f"{e.helper}: edge to {e.target!r} has unknown kind {e.kind!r}")
        if e.klass not in EDGE_CLASSES:
            errors.append(f"{e.helper}: edge to {e.target!r} has unknown class {e.klass!r}")
        if e.klass == "repo-owned":
            if not resolves_beneath_vendor(e.target):
                errors.append(
                    f"{e.helper}: repo-owned {e.kind} edge {e.target!r} does not "
                    f"resolve beneath {VENDOR_PREFIX} (repo-root escape)"
                )
            elif not (REPO_ROOT / e.target).is_file():
                errors.append(
                    f"{e.helper}: repo-owned {e.kind} edge target missing on disk: {e.target}"
                )
        elif e.klass == "external":
            if not e.auth:
                errors.append(
                    f"{e.helper}: external {e.kind} edge {e.target!r} names no "
                    f"preflight guarantee or explicit profile grant"
                )
        # Forward-verify a declared exec edge is real (skip synthetic-injection
        # runs, which reference helpers/targets that need not co-exist on disk).
        if live and e.kind == "exec" and not _exec_target_present(e.helper, e.target, e.klass):
            errors.append(
                f"{e.helper}: declared exec edge target {e.target!r} not found in source"
            )

    return errors


def main(argv=None):
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command", choices=("check", "show"),
        help="check: AC5 trust-closure guard; show: print the classification as JSON",
    )
    args = parser.parse_args(argv)

    if args.command == "show":
        print(json.dumps([e.as_dict() for e in classify_all()], indent=2))
        return 0

    errors = check_dependencies()
    if errors:
        for e in errors:
            print(f"cloud-writer-deps: {e}")
        return 1
    print("cloud-writer-deps: trust closure OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
