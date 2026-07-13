# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""detect-hook-closure-edges.py — the #458 Stop-hook closure drift-guard walker.

Statically walk every source/`.`/exec/`python3 <path>` edge in each closure file
named by CLOSURE and report every referenced repo .sh/.py that is NOT itself in the
closure — so a future added `source`/exec of a NEW helper is surfaced instead of
silently re-opening the one-hop-deeper hole scripts/harden-stop-hooks.sh closes.

This is the shared walker extracted from lib/test/run.sh's `#458 drift-guard`
assertion (issue #460): a single copy so the drift-guard and its positive-control
test exercise the SAME regex set, and a regex regression turns the suite RED rather
than diverging silently between two hand-copied programs.

I/O contract (env, matching the former inline heredoc):
  input  : env REPO_ROOT — repo root the closure paths are resolved against.
           env CLOSURE    — space-separated repo-relative closure paths (HOOK_TARGETS).
  stdout : one `rel -> ref (not in HOOK_TARGETS)` line per violation, sorted+deduped.
  exit   : always 0 — this is a REPORTER; the caller decides (empty output == clean).

Comment mentions are excluded (only real edge syntax matches); the jq PROGRAM edge
(`-f *.jq`) is out of scope (jq is sandboxed — not a shell/RCE vector). The command-
position source prefix set below anchors on the shell metacharacters that can precede
a `.`/`source` — line start, `;`, `&`, `|`, `(`, and (issue #460) `!` and `{` — so a
negation-guarded (`if ! . "$dep"`) or brace-grouped (`{ . "$dep"; }`) source edge is
detected, not a blind spot.
"""

import os
import re

src_re = re.compile(r'(?:^|[;&|(!{])\s*(?:\.|source)\s')
slashsh_re = re.compile(r'/([A-Za-z0-9_.-]+\.sh)\b')
pyexec_re = re.compile(r'\bpython3\s+"?([^\s"]*\.py)\b')
shexec_re = re.compile(r'\b(?:bash|sh)\s+"?([^\s"]*\.sh)\b')
execb_re = re.compile(r'\bexec\s+"?([^\s"]*\.(?:sh|py))\b')
assign_re = re.compile(
    r'\b[A-Za-z_][A-Za-z0-9_]*=[^\s#]*?((?:scripts|lib)/[A-Za-z0-9_.-]+\.(?:sh|py))'
)


def refs_in(path):
    out = set()
    try:
        with open(path, encoding="utf-8") as fh:
            for raw in fh:
                line = re.sub(r'#.*$', '', raw)   # drop # comments; real edge lines carry no '#'
                if not line.strip():
                    continue
                if src_re.search(line):
                    for m in slashsh_re.finditer(line):
                        out.add(m.group(1))
                for rx in (pyexec_re, shexec_re, execb_re):
                    for m in rx.finditer(line):
                        out.add(os.path.basename(m.group(1)))
                for m in assign_re.finditer(line):
                    out.add(os.path.basename(m.group(1)))
    except OSError:
        pass
    return out


def main():
    root = os.environ["REPO_ROOT"]
    closure = os.environ["CLOSURE"].split()
    closure_base = {os.path.basename(p) for p in closure}
    violations = []
    for rel in closure:
        for ref in refs_in(os.path.join(root, rel)):
            base = os.path.basename(ref)
            if base == os.path.basename(rel):
                continue
            if base not in closure_base:
                violations.append(f"{rel} -> {ref} (not in HOOK_TARGETS)")
    for v in sorted(set(violations)):
        print(v)


if __name__ == "__main__":
    main()
