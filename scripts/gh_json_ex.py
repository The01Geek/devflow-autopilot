#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""The shared paginated `gh api` reader and its establish-vs-absent contract.

`scripts/build-experiment-records.py` introduced this reader for issue #431 and was
its only consumer. Issue #1277's portability classifier needs the *same* contract —
and needs it for the same reason: a classifier that reads a failed API call as "the
PR changed no risky files" selects the empty population and the lane verifies
nothing, silently. The distinction between "we looked and it genuinely was not
there" and "we could not establish an answer" is the whole safety property, so it
lives in one module rather than being re-derived per caller.

`gh` is resolved through the `DEVFLOW_GH` override the repository's resolver family
uses, defaulting to the bare binary; the Python callers deliberately do not probe it
(the shell resolver `lib/resolve-gh.sh` owns probing).
"""
from __future__ import annotations

import json
import os
import subprocess
import sys

GH = os.environ.get("DEVFLOW_GH") or "gh"


def warn(msg: str) -> None:
    """Emit a breadcrumb. Overridable by a caller that has its own warn channel."""
    print(f"gh_json_ex: {msg}", file=sys.stderr)


def run(cmd):
    """Run cmd; return (rc, stdout, stderr). Never raises — an OSError (gh absent, a
    non-executable shim) is folded into a non-zero rc so every caller degrades
    uniformly to its unestablished arm rather than to an exception at an arbitrary
    point in the pipeline. `errors="replace"` is part of that contract: undecodable
    bytes on either stream would otherwise raise a UnicodeDecodeError past the
    OSError arm, at the one point no caller has an unestablished path for."""
    try:
        result = subprocess.run(
            cmd, check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            encoding="utf-8", errors="replace",
        )
        return result.returncode, result.stdout, result.stderr
    except OSError as exc:
        return 127, "", f"{type(exc).__name__}: {exc}"


def gh_json_ex(endpoint, paginate=False, warn_fn=None, gh=None, run_fn=None):
    """GET a `gh api` endpoint and parse it, returning `(value, ok)`.

    `ok` is False whenever the call did not yield a USABLE ANSWER — the "could not
    establish" case — and True only when it did.

    Two ways to fail to establish, and both must set `ok=False` (issue #431 review):

    * the gh call itself failed (non-zero rc: transport/auth/rate-limit/absent binary);
    * the call exited 0 but its body is NON-EMPTY and unparseable (a truncated
      response, an HTML proxy error page served with rc 0, a `gh` whose `--paginate`
      output shape changed). Reading that as `ok=True` launders it into the caller's
      `absent` arm — the strong claim "we looked and it genuinely was not there" —
      which is precisely the conflation this vocabulary exists to prevent.

    An EMPTY body with rc 0 stays `ok=True`: that is a real answer (the artifact is
    genuinely absent), not a failure to establish one.

    `gh` and `run_fn` are injection points for a caller that already owns its own
    resolved binary and subprocess wrapper (`scripts/build-experiment-records.py`
    does), so delegating here does not move that caller's `DEVFLOW_GH` read out of
    its own module.
    """
    emit = warn_fn or warn
    invoke = run_fn or run
    cmd = [gh or GH, "api"]
    if paginate:
        cmd.append("--paginate")
    cmd.append(endpoint)
    rc, out, err = invoke(cmd)
    if rc != 0:
        emit(f"gh api {endpoint} failed (rc={rc}): {(err or '').strip()[:160]}")
        return None, False
    if not out.strip():
        return None, True
    # --paginate concatenates one JSON value per page. For array endpoints that is
    # `[...][...]`; wrap-and-split so we flatten to a single list. A single object
    # (non-paginated) parses directly.
    try:
        return json.loads(out), True
    except json.JSONDecodeError:
        pass
    # Paginated concatenation: split top-level JSON values and merge lists.
    merged = []
    parsed_any = False
    decoder = json.JSONDecoder()
    idx, n = 0, len(out)
    while idx < n:
        while idx < n and out[idx].isspace():
            idx += 1
        if idx >= n:
            break
        try:
            value, end = decoder.raw_decode(out, idx)
        except json.JSONDecodeError:
            # rc was 0 but the body does not parse. NOT ok: we did not establish an
            # answer (see the docstring). Return whatever pages did parse alongside
            # ok=False so the caller degrades to an unestablished provenance rather
            # than asserting a measured absence.
            emit(f"gh api {endpoint} returned unparseable output (rc=0) — treating as "
                 "unestablished, not as a genuine absence")
            return (merged if parsed_any else None), False
        parsed_any = True
        if isinstance(value, list):
            merged.extend(value)
        else:
            merged.append(value)
        idx = end
    return (merged if parsed_any else None), True
