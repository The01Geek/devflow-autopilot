#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Durable staged-write transport for the `/devflow:create-issue` canonical draft (issue #705).

`/devflow:create-issue` mutates its canonical draft file at three sites. Before this
helper the write transport was unspecified prose, so a run landed anywhere between a
single monolithic generated shell command (one interruption destroys the only copy of a
pending mutation) and dozens of per-edit calls (each an interruption point that can leave
the canonical file neither the audited bytes nor the intended bytes). This helper is the
one transport every canonical-draft write goes through: it assembles the intended bytes in
a durable staging artifact, replaces the canonical file from that artifact in one atomic
operation, and re-digests the result to prove the replace landed.

THREE MODES, one process each (each ```bash fence is a fresh shell, so a digest computed in
one statement does not survive into a later one — the replace and its verification therefore
happen in the SAME process):

  * ``stage --path P`` — read the intended bytes on stdin and land them at the staging path
    P atomically, through a temporary sibling and an ``os.replace`` rename, so no transport
    outside this helper decides whether a staging write is atomic and an interrupted staging
    write leaves the previous complete staged copy intact. Prints ``digest=<oid>``.

  * ``emit --path P`` — write the staging artifact's bytes byte-exactly to stdout, exiting
    non-zero on an artifact that is absent or unreadable. It is the heredoc-free transport
    that carries staged bytes into ``issue-audit-state.py record-revision --stdin-digest``.

  * ``apply --staged S --canonical C --expect-digest D`` — replace the canonical file C from
    the staging artifact S and report whether the result agrees with the caller's DECLARED
    expectation D. It COPIES S to a temporary sibling of C and ``os.replace``s that temporary
    onto C (a rename within a filesystem never exposes a partially-written canonical file the
    way a truncate-and-write does), and it NEVER renames the staging artifact itself, so S
    survives a successful replace and a failed one alike (the recovery arm reads it back). It
    then digests C and compares that digest against D — NOT against S, because a self-
    comparison would agree over any bytes sitting at S, including a leftover this run did not
    write. When S's own digest does not match D it refuses, leaving C untouched. Within one
    uninterrupted process this comparison is a copy-fault and wrong-artifact guard, not an
    interruption detector; interruption is caught by the caller's cross-turn landed re-check.
    Prints ``canonical_digest=<oid> agree=yes|no`` on a decided answer.

Digests come from ``git hash-object --stdin --no-filters`` — the one filter-free mode
``issue-audit-state.py`` uses at every compare site, so all digests agree byte-for-byte on
every host regardless of ``core.autocrlf``. The helper names no non-preflight PATH tool:
its only subprocess is native ``git`` (preflight-guaranteed), and it is invoked as a
leading-token ``python3 <path>`` call behind the portable skill anchor, the shape every
existing create-issue helper call already uses.
"""

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

if sys.version_info < (3, 11):
    sys.stderr.write(
        'stage-draft-write.py: python3 >= 3.11 required (found '
        f'{sys.version_info.major}.{sys.version_info.minor})\n'
    )
    raise SystemExit(1)


def _fail(mode, msg, code=1):
    """Emit a named stderr breadcrumb and exit non-zero (the structural-failure contract)."""
    sys.stderr.write(f'stage-draft-write.py {mode}: {msg}\n')
    raise SystemExit(code)


def _hash_bytes(data, mode):
    """Object id of `data` via `git hash-object --stdin --no-filters`, or fail closed.

    The one filter-free digest form issue-audit-state.py uses at every compare site, so the
    staged digest, the recorded `stdin_digest`, and the post-replace canonical digest all
    agree byte-for-byte on every host.
    """
    try:
        r = subprocess.run(['git', 'hash-object', '--stdin', '--no-filters'],
                           input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           check=True)
    except subprocess.CalledProcessError as exc:
        err = exc.stderr.decode('utf-8', 'replace').strip()
        _fail(mode, f'git hash-object failed: {err}')
    except OSError as exc:
        _fail(mode, f'could not execute git: {exc}')
    oid = r.stdout.decode('ascii', 'replace').strip()
    if not oid:
        # A shimmed or broken `git` can exit 0 with empty stdout. An empty object id must
        # never read as a successful digest — it would compare equal to another empty one.
        _fail(mode, 'git hash-object returned an empty object id on exit 0')
    return oid


def _read_file_bytes(path, mode):
    try:
        return Path(path).read_bytes()
    except FileNotFoundError as exc:
        _fail(mode, f'staging artifact {path} does not exist: {exc}')
    except OSError as exc:
        _fail(mode, f'could not read staging artifact {path}: {exc}')


def _atomic_write(target, data, mode):
    """Write `data` to `target` atomically: a temp sibling, fsync, then os.replace.

    The temp sibling lives in the SAME directory as `target` so os.replace is a
    same-filesystem rename that overwrites the destination and never exposes a
    partially-written target. On any failure the temp sibling is removed so no residual is
    left behind.
    """
    target = Path(target)
    directory = target.parent
    try:
        directory.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        _fail(mode, f'could not create the directory for {target}: {exc}')
    fd, tmp = tempfile.mkstemp(prefix=target.name + '.', suffix='.tmp', dir=str(directory))
    try:
        with os.fdopen(fd, 'wb') as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, str(target))
    except OSError as exc:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        _fail(mode, f'could not land bytes at {target}: {exc}')


def cmd_stage(args):
    """Read intended bytes on stdin and land them atomically at the staging path."""
    try:
        data = sys.stdin.buffer.read()
    except OSError as exc:
        _fail('stage', f'could not read intended bytes from stdin: {exc}')
    # An empty staged body is a lost upstream composition, never a legitimate draft — refuse
    # it rather than atomically landing zero bytes the apply step would then replace in.
    if not data:
        _fail('stage', 'no intended bytes were received on stdin')
    digest = _hash_bytes(data, 'stage')
    _atomic_write(args.path, data, 'stage')
    print(f'digest={digest}')


def cmd_emit(args):
    """Write the staging artifact's bytes byte-exactly to stdout."""
    data = _read_file_bytes(args.path, 'emit')
    try:
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
    except OSError as exc:
        _fail('emit', f'could not write staged bytes to stdout: {exc}')


def cmd_apply(args):
    """Replace the canonical file from the staging artifact, then verify against --expect-digest."""
    staged = _read_file_bytes(args.staged, 'apply')
    staged_digest = _hash_bytes(staged, 'apply')
    # Wrong-artifact / copy-fault guard: the caller declares the bytes it INTENDS via
    # --expect-digest. A self-comparison against the staging artifact would agree over any
    # bytes sitting there, including a leftover this run did not write, so compare the
    # staging artifact's own digest against the DECLARED expectation first and refuse when
    # they disagree — leaving the canonical file untouched.
    if staged_digest != args.expect_digest:
        print(f'canonical_digest={staged_digest} agree=no reason=staged-digest-mismatch')
        return
    # COPY the staged bytes onto the canonical path atomically via _atomic_write (a temporary
    # sibling + fsync + os.replace). _atomic_write writes the in-memory `staged` bytes to a
    # fresh temp and never touches the staging artifact, so that artifact survives the call
    # for the recovery arm to read back — the copy-not-rename property this mode requires.
    _atomic_write(args.canonical, staged, 'apply')
    canonical = Path(args.canonical)
    # Re-digest the canonical file THROUGH git hash-object (not the in-memory staged bytes):
    # the answer is meaningful only if it reads back from disk what the replace wrote.
    try:
        landed = Path(canonical).read_bytes()
    except OSError as exc:
        _fail('apply', f'could not read the canonical file back after the replace: {exc}')
    canonical_digest = _hash_bytes(landed, 'apply')
    agree = 'yes' if canonical_digest == args.expect_digest else 'no'
    print(f'canonical_digest={canonical_digest} agree={agree}')


def build_parser():
    p = argparse.ArgumentParser(
        prog='stage-draft-write.py',
        description='Durable staged-write transport for the create-issue canonical draft (#705).')
    sub = p.add_subparsers(dest='mode', required=True)

    s = sub.add_parser('stage', help='Read intended bytes on stdin; land them atomically at '
                                     'the staging path. Prints digest=<oid>.')
    s.add_argument('--path', required=True,
                   help='The staging artifact path (issue-draft-<slug>.<nonce>.staged.md).')
    s.set_defaults(func=cmd_stage)

    s = sub.add_parser('emit', help='Write the staging artifact bytes byte-exactly to stdout.')
    s.add_argument('--path', required=True, help='The staging artifact path to read.')
    s.set_defaults(func=cmd_emit)

    s = sub.add_parser('apply', help='Replace the canonical file from the staging artifact and '
                                     'verify against --expect-digest. Prints '
                                     'canonical_digest=<oid> agree=yes|no.')
    s.add_argument('--staged', required=True, help='The staging artifact to copy from.')
    s.add_argument('--canonical', required=True, help='The canonical draft file to replace.')
    s.add_argument('--expect-digest', required=True,
                   help='The object id of the bytes the caller intends (the staged digest '
                        'stage mode printed this turn; on a revision write, the value '
                        'record-revision recorded as stdin_digest).')
    s.set_defaults(func=cmd_apply)
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    args.func(args)


if __name__ == '__main__':
    main()
