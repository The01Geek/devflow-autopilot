#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Focused tests for the receiving-review session artifact producer (issue #668).

Drives the real scripts/reception_identity.py library and scripts/reception-record.py
CLI against real scratch git fixture repositories (git is not mocked), plus the
scripts/verification-flight.py optional-field extension through its module API.

Covers the issue #668 acceptance matrix:
  * the identity contract rows (edit+untracked, one-byte change, gitignored append,
    deletion, rename, `git commit -am` falsifier),
  * shallow-clone and cone-mode sparse-checkout invariance,
  * every derivation failure mode -> named breadcrumb, no printed identity,
  * one-invocation-writes-both-artifacts, token nonce, gitignored keying,
  * the ignore-rule precondition, the session pointer, idempotency,
  * the findings ledger + disposition subcommand + the four-channel guard,
  * the six-shape adversarial matrix over each JSON artifact read back,
  * degenerate inputs (no commits, empty tree, mode change, symlink, newline
    filename, absent index), the no-history / index-unmodified scale properties,
  * the flight_key-unchanged property for a candidate_identity sibling field.
"""

from __future__ import annotations

import importlib.util
import io
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout, redirect_stderr
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1].parent / "scripts"
sys.path.insert(0, str(SCRIPTS))
import reception_identity as ri  # noqa: E402


def _load_hyphenated(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


rr = _load_hyphenated("reception_record", "reception-record.py")
vf = _load_hyphenated("verification_flight", "verification-flight.py")


def git(cwd, *args, check=True, env=None):
    e = os.environ.copy()
    e.setdefault("GIT_AUTHOR_NAME", "t")
    e.setdefault("GIT_AUTHOR_EMAIL", "t@t")
    e.setdefault("GIT_COMMITTER_NAME", "t")
    e.setdefault("GIT_COMMITTER_EMAIL", "t@t")
    if env:
        e.update(env)
    p = subprocess.run(["git", *args], cwd=cwd, env=e,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if check and p.returncode != 0:
        raise AssertionError(f"git {args} failed: {p.stderr}")
    return p


def committed_tree(cwd) -> str:
    return git(cwd, "rev-parse", "HEAD^{tree}").stdout.strip()


class ScratchRepo:
    def __init__(self, path: Path):
        self.path = path
        path.mkdir(parents=True, exist_ok=True)
        git(path, "init", "-q")
        # A gitignore so the session dir is ignored (mirrors the scaffolder).
        (path / ".gitignore").write_text("/.devflow/*\n")
        git(path, "add", ".gitignore")
        git(path, "commit", "-qm", "seed")

    def write(self, rel, content):
        p = self.path / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content)

    def commit_all(self, msg="c"):
        git(self.path, "add", "-A")
        git(self.path, "commit", "-qm", msg)


class IdentityContractTests(unittest.TestCase):
    def _repo(self):
        d = Path(tempfile.mkdtemp())
        return ScratchRepo(d)

    def test_edit_plus_untracked_committed_equal(self):
        r = self._repo()
        r.write("a.txt", "one\n")
        r.commit_all("a")
        r.write("a.txt", "two\n")      # tracked edit
        r.write("b.txt", "new\n")      # new untracked
        derived = ri.derive_candidate_identity(str(r.path))
        r.commit_all("stage")
        self.assertEqual(derived, committed_tree(r.path))

    def test_one_byte_change_after_unequal(self):
        r = self._repo()
        r.write("a.txt", "one\n")
        derived = ri.derive_candidate_identity(str(r.path))
        r.write("a.txt", "onx\n")
        self.assertNotEqual(derived, ri.derive_candidate_identity(str(r.path)))

    def test_gitignored_append_equal(self):
        r = self._repo()
        r.write(".gitignore", "/.devflow/*\nignored.log\n")
        r.write("ignored.log", "x\n")
        derived = ri.derive_candidate_identity(str(r.path))
        r.write("ignored.log", "x\nmore\n")
        self.assertEqual(derived, ri.derive_candidate_identity(str(r.path)))

    def test_deletion_committed_equal(self):
        r = self._repo()
        r.write("a.txt", "one\n")
        r.commit_all("a")
        os.remove(r.path / "a.txt")
        derived = ri.derive_candidate_identity(str(r.path))
        r.commit_all("del")
        self.assertEqual(derived, committed_tree(r.path))

    def test_rename_committed_equal(self):
        r = self._repo()
        r.write("a.txt", "one\n")
        r.commit_all("a")
        os.rename(r.path / "a.txt", r.path / "renamed.txt")
        derived = ri.derive_candidate_identity(str(r.path))
        r.commit_all("ren")
        self.assertEqual(derived, committed_tree(r.path))

    def test_commit_am_falsifier_unequal(self):
        r = self._repo()
        r.write("a.txt", "one\n")
        r.commit_all("a")
        r.write("a.txt", "two\n")   # tracked mod
        r.write("b.txt", "new\n")   # untracked
        derived = ri.derive_candidate_identity(str(r.path))
        git(r.path, "commit", "-am", "am")   # stages tracked mods only
        self.assertNotEqual(derived, committed_tree(r.path))

    def test_index_not_modified(self):
        r = self._repo()
        r.write("a.txt", "one\n")
        r.commit_all("a")
        r.write("a.txt", "two\n")
        r.write("b.txt", "new\n")
        index = r.path / ".git" / "index"
        before = index.read_bytes()
        ri.derive_candidate_identity(str(r.path))
        self.assertEqual(before, index.read_bytes())

    def test_shallow_equals_full(self):
        src = self._repo()
        for i in range(3):
            src.write("a.txt", f"v{i}\n")
            src.commit_all(f"c{i}")
        src.write("a.txt", "dirty\n")
        src.write("u.txt", "untracked\n")
        full = ri.derive_candidate_identity(str(src.path))
        shallow = Path(tempfile.mkdtemp()) / "shallow"
        git(Path(tempfile.gettempdir()), "clone", "-q", "--depth", "1",
            f"file://{src.path}", str(shallow))
        (shallow / "a.txt").write_text("dirty\n")
        (shallow / "u.txt").write_text("untracked\n")
        self.assertEqual(full, ri.derive_candidate_identity(str(shallow)))

    def test_sparse_cone_equals_committed(self):
        src = self._repo()
        src.write("inc/keep.txt", "keep\n")
        src.write("exc/drop.txt", "drop\n")
        src.commit_all("tree")
        clone = Path(tempfile.mkdtemp()) / "sparse"
        git(Path(tempfile.gettempdir()), "clone", "-q", f"file://{src.path}", str(clone))
        git(clone, "sparse-checkout", "init", "--cone")
        git(clone, "sparse-checkout", "set", "inc")
        # exc/ is off disk now; make an in-cone change and derive
        (clone / "inc" / "keep.txt").write_text("keep2\n")
        derived = ri.derive_candidate_identity(str(clone))
        git(clone, "commit", "-am", "sparse")
        self.assertEqual(derived, committed_tree(clone))
        # the derived tree still lists the skip-worktree path
        listing = git(clone, "ls-tree", "-r", "--name-only", derived).stdout
        self.assertIn("exc/drop.txt", listing)

    def test_no_commits(self):
        d = Path(tempfile.mkdtemp())
        git(d, "init", "-q")
        (d / "a.txt").write_text("x\n")
        # No HEAD yet; write-tree still succeeds against the staged content.
        val = ri.derive_candidate_identity(str(d))
        self.assertRegex(val, r"^[0-9a-f]{40,64}$")

    def test_empty_tree(self):
        d = Path(tempfile.mkdtemp())
        git(d, "init", "-q")
        val = ri.derive_candidate_identity(str(d))
        self.assertRegex(val, r"^[0-9a-f]{40,64}$")

    def test_mode_change(self):
        r = self._repo()
        p = r.path / "s.sh"
        p.write_text("#!/bin/sh\n")
        r.commit_all("s")
        os.chmod(p, 0o755)
        derived = ri.derive_candidate_identity(str(r.path))
        r.commit_all("mode")
        self.assertEqual(derived, committed_tree(r.path))

    def test_symlink_tracked(self):
        r = self._repo()
        r.write("target.txt", "t\n")
        os.symlink("target.txt", r.path / "link")
        r.commit_all("link")
        r.write("target.txt", "t2\n")
        derived = ri.derive_candidate_identity(str(r.path))
        r.commit_all("edit")
        self.assertEqual(derived, committed_tree(r.path))

    def test_newline_filename(self):
        r = self._repo()
        weird = r.path / "a\nb.txt"
        try:
            weird.write_text("x\n")
        except OSError:
            self.skipTest("filesystem rejects newline in filename")
        derived = ri.derive_candidate_identity(str(r.path))
        r.commit_all("nl")
        self.assertEqual(derived, committed_tree(r.path))

    def test_absent_index(self):
        r = self._repo()
        r.write("a.txt", "x\n")
        index = r.path / ".git" / "index"
        if index.exists():
            os.remove(index)
        val = ri.derive_candidate_identity(str(r.path))
        self.assertRegex(val, r"^[0-9a-f]{40,64}$")


class FailureModeTests(unittest.TestCase):
    def test_git_absent(self):
        r = ScratchRepo(Path(tempfile.mkdtemp()))
        orig = ri.GIT
        ri.GIT = "definitely-not-a-real-git-binary-xyz"
        try:
            with self.assertRaises(ri.IdentityError) as cm:
                ri.derive_candidate_identity(str(r.path))
            self.assertEqual(cm.exception.reason, "git_not_found")
        finally:
            ri.GIT = orig

    def test_not_a_repo(self):
        d = Path(tempfile.mkdtemp())
        with self.assertRaises(ri.IdentityError) as cm:
            ri.derive_candidate_identity(str(d))
        self.assertTrue(cm.exception.reason.startswith("git_failed:"))


class RecordCliTests(unittest.TestCase):
    def _repo(self):
        return ScratchRepo(Path(tempfile.mkdtemp()))

    def _run(self, argv):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = rr.main(argv)
        return code, out.getvalue(), err.getvalue()

    def test_record_writes_both_and_pointer(self):
        r = self._repo()
        r.write("a.txt", "x\n")
        code, out, err = self._run(["record", "--repo-root", str(r.path)])
        self.assertEqual(code, 0, err)
        payload = json.loads(out)
        self.assertTrue(payload["ok"])
        token = payload["claim_context_token"]
        self.assertRegex(token, r"^[0-9a-f]{32}$")
        idp = Path(payload["identity_path"])
        fdp = Path(payload["findings_path"])
        self.assertTrue(idp.exists() and fdp.exists())
        idrec = json.loads(idp.read_text())
        self.assertEqual(idrec["candidate_identity"], payload["candidate_identity"])
        self.assertEqual(idrec["claim_context_token"], token)
        fdrec = json.loads(fdp.read_text())
        self.assertEqual(fdrec["claim_context_token"], token)
        self.assertEqual(fdrec["findings"], [])
        pointer = json.loads((idp.parent / rr.POINTER_NAME).read_text())
        self.assertEqual(pointer["identity_path"], str(idp))
        self.assertEqual(pointer["findings_path"], str(fdp))

    def test_token_is_random(self):
        r = self._repo()
        t1 = json.loads(self._run(["record", "--repo-root", str(r.path)])[1])["claim_context_token"]
        t2 = json.loads(self._run(["record", "--repo-root", str(r.path)])[1])["claim_context_token"]
        self.assertNotEqual(t1, t2)

    def test_dir_not_ignored_no_write(self):
        # A repo with NO ignore rule for the session dir.
        d = Path(tempfile.mkdtemp())
        git(d, "init", "-q")
        (d / "a.txt").write_text("x\n")
        git(d, "add", "a.txt")
        git(d, "commit", "-qm", "seed")
        code, out, err = self._run(["record", "--repo-root", str(d)])
        self.assertNotEqual(code, 0)
        self.assertEqual(out, "")
        self.assertIn("session_dir_not_ignored", err)
        self.assertFalse((d / rr.SESSION_DIRNAME).exists())

    def test_never_invoked_no_pointer(self):
        r = self._repo()
        self.assertFalse((r.path / rr.SESSION_DIRNAME / rr.POINTER_NAME).exists())

    def test_idempotent_record(self):
        r = self._repo()
        r.write("a.txt", "x\n")
        p1 = json.loads(self._run(["record", "--repo-root", str(r.path)])[1])
        token = p1["claim_context_token"]
        # append a disposition
        self._run(["append-disposition", "--repo-root", str(r.path), "--token", token,
                   "--summary", "s", "--disposition", "fixed"])
        # re-record for the same token: findings preserved, no duplicate
        p2 = json.loads(self._run(["record", "--repo-root", str(r.path), "--token", token])[1])
        self.assertEqual(p2["claim_context_token"], token)
        fdrec = json.loads(Path(p2["findings_path"]).read_text())
        self.assertEqual(len(fdrec["findings"]), 1)

    def test_disposition_assigns_id(self):
        r = self._repo()
        r.write("a.txt", "x\n")
        token = json.loads(self._run(["record", "--repo-root", str(r.path)])[1])["claim_context_token"]
        c, out, err = self._run(["append-disposition", "--repo-root", str(r.path),
                                 "--token", token, "--summary", "s1", "--disposition", "fixed"])
        self.assertEqual(c, 0, err)
        self.assertEqual(json.loads(out)["finding_id"], "f001")
        c, out, _ = self._run(["append-disposition", "--repo-root", str(r.path),
                               "--token", token, "--summary", "s2", "--disposition",
                               "deferred", "--channel", "code-comment"])
        self.assertEqual(json.loads(out)["finding_id"], "f002")

    def test_deferral_requires_channel(self):
        r = self._repo()
        r.write("a.txt", "x\n")
        token = json.loads(self._run(["record", "--repo-root", str(r.path)])[1])["claim_context_token"]
        c, out, err = self._run(["append-disposition", "--repo-root", str(r.path),
                                 "--token", token, "--summary", "s", "--disposition", "deferred"])
        self.assertNotEqual(c, 0)
        self.assertEqual(out, "")
        self.assertIn("deferral_missing_channel", err)

    def test_disposition_records_channel(self):
        r = self._repo()
        r.write("a.txt", "x\n")
        token = json.loads(self._run(["record", "--repo-root", str(r.path)])[1])["claim_context_token"]
        self._run(["append-disposition", "--repo-root", str(r.path), "--token", token,
                   "--summary", "s", "--disposition", "pushback", "--channel", "pr-thread"])
        fdp = r.path / rr.SESSION_DIRNAME / f"{token}.findings.json"
        entry = json.loads(fdp.read_text())["findings"][0]
        self.assertEqual(entry["channel"], "pr-thread")

    def test_unwritable_dir_no_identity(self):
        # uid-independent unwritability: a regular FILE stands where a session-dir
        # parent component must be, so mkdir raises NotADirectoryError regardless
        # of the runner uid (a chmod 0500 dir is bypassed by root in CI).
        r = self._repo()
        r.write("a.txt", "x\n")
        blocker = r.path / ".devflow" / "tmp" / "blocker"
        blocker.parent.mkdir(parents=True, exist_ok=True)
        blocker.write_text("i am a file\n")
        sd = blocker / "sub"   # a directory under a file -> unwritable by construction
        code, out, err = self._run(["record", "--repo-root", str(r.path),
                                    "--session-dir", str(sd)])
        self.assertNotEqual(code, 0)
        self.assertNotIn("candidate_identity", out)
        self.assertIn("write_failed", err)


class AdversarialArtifactMatrixTests(unittest.TestCase):
    """Six-shape matrix over the findings artifact the append path reads back."""

    def _repo_token(self):
        r = ScratchRepo(Path(tempfile.mkdtemp()))
        r.write("a.txt", "x\n")
        out = io.StringIO()
        with redirect_stdout(out):
            rr.main(["record", "--repo-root", str(r.path)])
        token = json.loads(out.getvalue())["claim_context_token"]
        return r, token

    def _append(self, repo, token):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = rr.main(["append-disposition", "--repo-root", str(repo.path),
                            "--token", token, "--summary", "s", "--disposition", "fixed"])
        return code, out.getvalue(), err.getvalue()

    def _findings_path(self, repo, token):
        return repo.path / rr.SESSION_DIRNAME / f"{token}.findings.json"

    def test_matrix(self):
        cases = {
            "object_valid": (json.dumps({"schema_version": 1, "findings": []}), True),
            "array": (json.dumps([1, 2, 3]), False),
            "scalar": (json.dumps(5), False),
            "valid_falsy": (json.dumps(False), False),
            "missing": (None, False),
            "wrong_type_findings": (json.dumps({"findings": "nope"}), False),
        }
        for name, (content, ok) in cases.items():
            with self.subTest(name):
                repo, token = self._repo_token()
                fdp = self._findings_path(repo, token)
                if content is None:
                    os.remove(fdp)
                else:
                    fdp.write_text(content)
                code, out, err = self._append(repo, token)
                if ok:
                    self.assertEqual(code, 0, err)
                else:
                    self.assertNotEqual(code, 0)
                    self.assertEqual(out, "")
                    self.assertTrue(err.strip())

    def test_truncated_and_non_utf8(self):
        repo, token = self._repo_token()
        fdp = self._findings_path(repo, token)
        fdp.write_text('{"findings": [')  # truncated JSON
        code, out, err = self._append(repo, token)
        self.assertNotEqual(code, 0)
        self.assertIn("findings_malformed", err)
        fdp.write_bytes(b"\xff\xfe not utf8")
        code, out, err = self._append(repo, token)
        self.assertNotEqual(code, 0)


class FlightExtensionTests(unittest.TestCase):
    def _decl(self, with_ci=False):
        d = {
            "schema_version": vf.SCHEMA_VERSION,
            "profile": {
                "profile_version": "1",
                "argv": ["run.sh"],
                "cwd": "/x",
                "environment": {},
                "toolchain": {},
                "dependencies": {},
                "output_roots": [],
                "external_services": "none",
            },
            "checkout": {k: "v" for k in vf._CHECKOUT_REQUIRED},
        }
        if with_ci:
            d["candidate_identity"] = "deadbeef" * 5
        return d

    def test_flight_key_unchanged_by_sibling_field(self):
        base = vf._derive(self._decl(with_ci=False))
        withid = vf._derive(self._decl(with_ci=True))
        self.assertEqual(base["flight_key"], withid["flight_key"])
        self.assertEqual(base["descriptor_digest"], withid["descriptor_digest"])

    def test_candidate_identity_recorded(self):
        d = vf._derive(self._decl(with_ci=True))
        self.assertEqual(d["candidate_identity"], "deadbeef" * 5)

    def test_absent_field_records_none(self):
        d = vf._derive(self._decl(with_ci=False))
        self.assertIsNone(d["candidate_identity"])

    def test_claim_handle_records_candidate_identity(self):
        state = Path(tempfile.mkdtemp())
        logs = Path(tempfile.mkdtemp())
        decl = Path(tempfile.mkdtemp()) / "d.json"
        decl.write_text(json.dumps(self._decl(with_ci=True)))
        out = io.StringIO()
        with redirect_stdout(out):
            code = vf.main(["claim", "--input-file", str(decl),
                            "--state-dir", str(state), "--logs-dir", str(logs)])
        self.assertEqual(code, vf.EXIT_OK)
        key = json.loads(out.getvalue())["flight_key"]
        handle = json.loads((state / f"{key}.json").read_text())
        self.assertEqual(handle["candidate_identity"], "deadbeef" * 5)


if __name__ == "__main__":
    unittest.main()
