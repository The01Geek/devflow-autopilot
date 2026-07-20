#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""DevFlow deferrals-manifest discovery for /implement Phase 4.0.5.

Phase 4.0.5 of `/devflow:implement` files follow-up GitHub issues for review
findings deferred during the Phase 3.3 fix loop. Its first step discovers the
run-scoped deferrals manifests written by /devflow:review-and-fix at
`.devflow/tmp/review/<slug>/<run-id>/deferrals.json` (one per run). The old
inline `find $SEARCH_DIRS … | sort` capture collapsed a *failed* search and a
*clean no-match* search onto the same empty output — a degraded search then read
as the clean no-op and acknowledged deferrals were silently stranded (issue #555,
observed live in #533). This helper searches each candidate root INDEPENDENTLY,
classifies each root's outcome, and preserves discovery status through the exit
code so output production can never mask a failed search.

Each supplied root is classified into exactly one of three outcomes:
    ok      searched cleanly (zero matches allowed)
    absent  the root path does not exist (benign — contributes nothing)
    failed  the root exists but could not be fully traversed (an OSError at the
            root OR anywhere the walk actually visits — a non-directory root, a
            permission or I/O error, an unreadable subtree at depth <= 2). The
            walk is pruned below depth 2 (nothing deeper can match), so a
            subtree at depth >= 3 is never visited and cannot classify a root
            `failed`; that is out of the matching contract's reach by
            construction, not a swallowed error. This does NOT rely on os.walk's
            default error-swallowing (`onerror=None` silently skips an unreadable
            subtree and would classify the root `ok` with the manifest inside it
            missing — the exact silent-loss shape this helper exists to remove,
            re-created one level down). We pass a raising `onerror`.

stdout: the de-duplicated, lexicographically sorted list of matching manifest
paths, one per line, in POSIX separator form (forward slashes) so the list is
stable across native-Windows python3 hosts (#275's documented host shape).
A match is a file named `deferrals.json`, size > 0 bytes, located EXACTLY two
directory levels below a supplied root (`<root>/<run-id>/deferrals.json`) —
mirroring the retired `find -mindepth 2 -maxdepth 2 -name deferrals.json -size +0c`.

stderr carries a roots-echo line naming every root's absolute path (os.path.abspath
— normalized, NOT symlink-resolved) and classification on every *discovery* run,
i.e. whenever at least one root argument was supplied, so an `absent` root is
observable rather than silent. The zero-argument usage error (exit 2) returns
before any root is classified and therefore emits only the usage message.
Failed roots additionally emit a per-root breadcrumb, and a discovery run emits
at most one aggregate discrimination marker the fence greps.

Exit codes:
    0  no root classified `failed` (all ok/absent, including zero total matches)
    2  invoked with zero root arguments (usage message; NO discovery marker)
    3  partial — at least one `failed` AND at least one `ok`/`absent`
       (discovered paths are still printed); stderr carries `devflow: discovery partial:`
    4  every root classified `failed` (empty stdout); stderr carries `devflow: discovery failed:`
An uncaught exception exits non-zero (interpreter default), which the fence's
else-arm treats as failed — ambiguous failures fail closed.

Usage:
    discover-deferral-manifests.py ROOT [ROOT ...]
"""

import os
import sys

MANIFEST_NAME = "deferrals.json"

# Aggregate discrimination markers the §4.0.5 fence greps. At most one is emitted
# per run (the partial/all-failed arms are exclusive branches), and the per-root
# failed breadcrumb below is deliberately worded so its own fixed text contains
# NEITHER contiguous substring — the fence's `grep -q 'devflow: discovery partial:'`
# discrimination is only sound under that exclusivity. NOTE the residual: the
# per-root breadcrumb interpolates the root path and the OSError text, so a CALLER
# that passes a root path literally containing a marker substring can defeat the
# exclusivity. The §4.0.5 fence cannot: both its roots are path-safe components
# (`pr-<N>` and an `[a-z0-9._-]`-sanitized branch slug), which admit neither `:`
# nor a space. This helper does not sanitize argv, so the guarantee is the fence's
# input discipline plus the fixed wording — not an unconditional property of the
# helper for an arbitrary caller.
MARKER_PARTIAL = "devflow: discovery partial:"
MARKER_FAILED = "devflow: discovery failed:"


def _force_utf8_streams():
    """Force stdout/stderr to UTF-8, idempotently and defensively. Called from
    the CLI entry path only (not at import) so importing this module for unit
    tests never mutates the importer's global streams. The guard tolerates a
    stream replaced with a non-`TextIOWrapper` (e.g. a test's `io.StringIO`),
    which has no `reconfigure` (issue #222)."""
    for _stream in (sys.stdout, sys.stderr):
        try:
            _stream.reconfigure(encoding="utf-8")
        except (AttributeError, ValueError):
            pass


def _raise(err):
    # os.walk's onerror: re-raise so an unreadable subtree surfaces as a `failed`
    # classification instead of being silently skipped (the #555 silent-loss shape).
    raise err


def _depth_below(root, dirpath):
    # Number of path segments `dirpath` lies below `root`. The root itself is 0.
    rel = os.path.relpath(dirpath, root)
    if rel == os.curdir:
        return 0
    return rel.count(os.sep) + 1


def classify_root(root):
    """Classify one candidate root. Returns (status, matches) where status is
    one of 'ok' / 'absent' / 'failed' and matches is a list of POSIX-form paths
    to non-empty deferrals.json files exactly two levels below the root."""
    if not os.path.exists(root):
        return "absent", []
    # A non-directory root (a regular file supplied where a directory was
    # expected — the deterministic ENOTDIR shape) is a traversal failure, not an
    # empty `ok`: os.walk over a regular file yields nothing silently, which would
    # misclassify it `ok`. Catch it explicitly.
    if not os.path.isdir(root):
        # EVERY `failed` classification breadcrumbs the root and the reason — this arm
        # raises no OSError, so without its own write it would be the one failure the
        # operator cannot attribute to a root.
        sys.stderr.write(
            "devflow: discovery: root %s failed traversal (not a directory)\n"
            % os.path.abspath(root)
        )
        return "failed", []
    matches = []
    try:
        for dirpath, dirnames, filenames in os.walk(root, onerror=_raise):
            # Files exactly two levels below root live in directories exactly one
            # level below root (`<root>/<run-id>/`). Prune deeper descent for speed
            # and to keep the depth-2 contract exact.
            depth = _depth_below(root, dirpath)
            if depth >= 2:
                dirnames[:] = []
                continue
            if depth != 1:
                continue
            if MANIFEST_NAME in filenames:
                candidate = os.path.join(dirpath, MANIFEST_NAME)
                # getsize can itself raise OSError (a file vanishing mid-walk) —
                # that is a traversal failure of this root, handled by the except.
                if os.path.getsize(candidate) > 0:
                    matches.append(candidate.replace(os.sep, "/"))
    except OSError as exc:
        sys.stderr.write(
            "devflow: discovery: root %s failed traversal (%s)\n"
            % (os.path.abspath(root), exc)
        )
        return "failed", []
    return "ok", matches


def main(argv=None):
    _force_utf8_streams()
    args = list(sys.argv[1:] if argv is None else argv)
    if not args:
        # NO discovery marker here — a usage error is not a discovery outcome, so
        # it must not be mistaken for a PARTIAL one. Emitting neither marker is
        # what routes it to the fence's else arm (`DISCOVERY_STATE=failed`), the
        # fail-closed direction: nothing is filed. The fence's else-arm reflection
        # names the two shapes it expects (all roots failed / a harness denial),
        # so a usage error — which the fence itself cannot produce, since it always
        # passes $SEARCH_DIRS — would be recorded under a diagnosis one word wider
        # than the truth. That is the accepted cost of a single fail-closed arm;
        # do NOT add a marker here to sharpen it, because any marker this arm
        # emitted would have to be discriminated from a real discovery outcome.
        sys.stderr.write(
            "devflow: discovery: usage: discover-deferral-manifests.py ROOT [ROOT ...]\n"
        )
        return 2

    results = []          # (root, status)
    all_matches = set()
    for root in args:
        status, matches = classify_root(root)
        results.append((root, status))
        all_matches.update(matches)

    # Roots-echo: name every root's ABSOLUTE path (os.path.abspath — normalized,
    # NOT symlink-resolved) and classification on every run that reaches here, so
    # an `absent`-classified root is observable in the fence's tool result (the
    # fence surfaces this line unconditionally) rather than silent. The zero-arg
    # usage error returns above, before any root exists to echo.
    echo = " ".join(
        "%s=%s" % (os.path.abspath(root), status) for root, status in results
    )
    sys.stderr.write("devflow: discovery roots: %s\n" % echo)

    # stdout: sorted, de-duplicated, POSIX-form. Printed even on a partial run —
    # output production must NOT be able to alter the exit status below.
    for path in sorted(all_matches):
        sys.stdout.write(path + "\n")

    failed = sum(1 for _, s in results if s == "failed")
    total = len(results)
    if failed == 0:
        return 0
    if failed == total:
        sys.stderr.write(
            "%s all %d candidate root(s) failed traversal.\n" % (MARKER_FAILED, total)
        )
        return 4
    sys.stderr.write(
        "%s %d of %d candidate root(s) failed traversal; discovered manifests printed "
        "from the rest.\n" % (MARKER_PARTIAL, failed, total)
    )
    return 3


if __name__ == "__main__":
    sys.exit(main())
