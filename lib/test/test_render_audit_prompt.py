#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Focused unit tests for scripts/render-audit-prompt.py (issue #600).

Levels: unit (renderer over mktemp fixture trees) + a delivery-equivalence
matrix that drives the real scripts/load-prompt-extension.sh over the same
fixtures. Each named assertion (R1..R12) maps to an acceptance criterion; R13
(re-anchored pins) lives in the shell suite, not here.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
RENDERER = REPO / "scripts" / "render-audit-prompt.py"
LOADER = REPO / "scripts" / "load-prompt-extension.sh"
TEMPLATE = REPO / "skills" / "create-issue" / "references" / "audit-prompt-template.md"

READ_INSTRUCTION = "Read the draft file"
DRAFT_UNREADABLE_EMIT = "If you cannot read the file, return **no findings** and end with"
HASH_OBJECT = "run `git hash-object --no-filters` on that draft file and quote the object ID it prints verbatim"
FOUR_PATH_OOB = (
    "The following on-disk files are **out of bounds** — "
    "`.devflow/tmp/issue-derivation-"
)
FIVE_FILE_OOB = "the out-of-bounds declaration names exactly these 5 files"
READ_ORDERING_AMENDED = (
    "before any repository read other than the renderer invocation, or the "
    "documented template-file fallback read, that produced these instructions"
)


def run_renderer(args, stdin=None):
    return subprocess.run(
        [sys.executable, str(RENDERER), *args],
        input=stdin,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        encoding="utf-8",
    )


def run_loader(cwd, section="## Audit dimensions"):
    return subprocess.run(
        ["bash", str(LOADER), "create-issue", "--section", section],
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        encoding="utf-8",
    )


def write_ext(root: Path, body: str) -> Path:
    d = root / ".devflow" / "prompt-extensions"
    d.mkdir(parents=True, exist_ok=True)
    p = d / "create-issue.md"
    p.write_text(body, encoding="utf-8")
    return p


class DispatchArms(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        # An extension carrying the section so status is a stable 'appended'.
        write_ext(self.root, "## Audit dimensions\n\n- **X** — a consumer dim.\n")
        self.ext = self.root / ".devflow" / "prompt-extensions" / "create-issue.md"

    def tearDown(self):
        self.tmp.cleanup()

    def test_R1_file_arm(self):
        r = run_renderer(
            ["file", "--slug", "my-slug", "--draft-path",
             "/abs/issue-draft-my-slug.md", "--extension-file", str(self.ext)]
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        out = r.stdout
        self.assertIn(READ_INSTRUCTION, out)
        self.assertIn(READ_ORDERING_AMENDED, out)  # amended two-transport ordering
        self.assertIn(FOUR_PATH_OOB, out)
        self.assertIn(HASH_OBJECT, out)
        self.assertIn("/abs/issue-draft-my-slug.md", out)  # draft path slot
        self.assertNotIn(FIVE_FILE_OOB, out)  # 4-path, not the embed 5-path

    def test_R2_embed_arm(self):
        r = run_renderer(
            ["embed", "--slug", "my-slug",
             "--sentinel-open", "AUDIT-ABC123-OPEN",
             "--sentinel-close", "AUDIT-ABC123-CLOSE",
             "--extension-file", str(self.ext)],
            stdin="THIS STDIN MUST BE IGNORED",  # renderer consumes no stdin
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        out = r.stdout
        self.assertIn("AUDIT-ABC123-OPEN", out)
        self.assertIn("AUDIT-ABC123-CLOSE", out)
        self.assertIn(FIVE_FILE_OOB, out)
        self.assertIn("spliced here by the dispatch prompt", out)  # splice slot
        self.assertNotIn(READ_INSTRUCTION, out)
        self.assertNotIn("THIS STDIN MUST BE IGNORED", out)

    def test_R3_inline_arm(self):
        r = run_renderer(["inline", "--slug", "my-slug",
                          "--extension-file", str(self.ext)])
        self.assertEqual(r.returncode, 0, r.stderr)
        out = r.stdout
        self.assertNotIn(READ_INSTRUCTION, out)  # no read-the-file instruction
        self.assertNotIn(DRAFT_UNREADABLE_EMIT, out)  # no DRAFT-UNREADABLE emit option
        self.assertIn(FOUR_PATH_OOB, out)  # still declares reasoning artifacts OOB

    def test_R11_checklist_mode(self):
        r = run_renderer(["checklist", "--extension-file", str(self.ext)])
        self.assertEqual(r.returncode, 0, r.stderr)
        out = r.stdout
        self.assertTrue(out.startswith("render-status: "))
        self.assertTrue(out.rstrip("\n").endswith("render-end:"))
        # the generic dimension bullets are present (count guard-locked by A3).
        self.assertIn("**Consumer-repo setup variance**", out)
        self.assertIn("**Authoring-discipline defects**", out)
        # No arm carriage / out-of-bounds / cap material.
        self.assertNotIn("at most five findings", out)
        self.assertNotIn(READ_INSTRUCTION, out)
        self.assertNotIn(FOUR_PATH_OOB, out)


class Extraction(unittest.TestCase):
    """R4 — the four extraction clauses over a mutable-markdown malformed matrix."""

    def _status(self, body, section="audit-dimensions"):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "ext.md"
            p.write_text(body, encoding="utf-8")
            r = run_renderer(["extract", "--hook", section,
                              "--extension-file", str(p)])
            self.assertEqual(r.returncode, 0, r.stderr)
            return r.stdout

    def test_absent_heading(self):
        out = self._status("## Other\n\nnothing here\n")
        self.assertTrue(out.startswith("render-status: absent"))

    def test_duplicate_concatenation_in_order(self):
        out = self._status(
            "## Audit dimensions\n- first\n\n## X\n\n## Audit dimensions\n- second\n"
        )
        self.assertTrue(out.startswith("render-status: appended"))
        i_first = out.index("first")
        i_second = out.index("second")
        self.assertLess(i_first, i_second)  # file order

    def test_empty_section_equals_absent(self):
        out = self._status("## Audit dimensions\n\n## Next\n- body\n")
        self.assertTrue(out.startswith("render-status: absent"))

    def test_heading_in_html_comment_not_extracted(self):
        out = self._status("<!--\n## Audit dimensions\n- hidden\n-->\n")
        self.assertTrue(out.startswith("render-status: absent"))

    def test_fence_marker_inside_comment_is_inert(self):
        # #600 review finding: a ``` line INSIDE an HTML comment must not toggle
        # fence state, or the comment never closes and a later real heading is
        # swallowed (a divergence from load-prompt-extension.sh).
        out = self._status("<!--\n```\n-->\n## Audit dimensions\n- real body\n")
        self.assertTrue(out.startswith("render-status: appended"))
        self.assertIn("real body", out)

    def test_heading_in_fence_not_extracted(self):
        out = self._status("```\n## Audit dimensions\n- fenced\n```\n")
        self.assertTrue(out.startswith("render-status: absent"))

    def test_hash_line_in_fence_neither_starts_nor_ends(self):
        out = self._status(
            "## Audit dimensions\n- real\n```\n## Not a heading\n```\n- still real\n"
        )
        # The fenced `## ` line neither starts nor ends a section, so the text
        # after the fence ("still real") is still part of the section body — the
        # fenced line did not terminate it.
        self.assertTrue(out.startswith("render-status: appended"))
        self.assertIn("real", out)
        self.assertIn("still real", out)

    def test_empty_file(self):
        out = self._status("")
        self.assertTrue(out.startswith("render-status: absent"))

    def test_truncated_text(self):
        out = self._status("## Audit dimen")  # partial heading, no body
        self.assertTrue(out.startswith("render-status: absent"))

    def test_real_extension_fixture(self):
        # Production-realistic: this repo's live extension carries both hooks.
        real = REPO / ".devflow" / "prompt-extensions" / "create-issue.md"
        for hook in ("audit-dimensions", "evidence-axes"):
            r = run_renderer(["extract", "--hook", hook,
                              "--extension-file", str(real)])
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertTrue(r.stdout.startswith("render-status: appended"), hook)


class DeliveryEquivalence(unittest.TestCase):
    """R5 — renderer triage agrees with load-prompt-extension.sh per arm."""

    def _assert_maps(self, make_ext, expected_status):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            make_ext(root)
            # Renderer classification.
            ext = root / ".devflow" / "prompt-extensions" / "create-issue.md"
            r = run_renderer(["status-only", "--extension-file", str(ext)])
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertTrue(
                r.stdout.startswith(f"render-status: {expected_status}"),
                f"renderer said {r.stdout!r}, expected {expected_status}",
            )
            # Loader observed behavior (exit 0+content=appended, 0+empty=absent,
            # 2=unestablished).
            lr = run_loader(str(root))
            if expected_status == "appended":
                self.assertEqual(lr.returncode, 0)
                self.assertTrue(lr.stdout.strip())
            elif expected_status == "absent":
                self.assertEqual(lr.returncode, 0)
                self.assertEqual(lr.stdout.strip(), "")
            else:  # unestablished
                self.assertEqual(lr.returncode, 2)

    def test_present_regular_with_section(self):
        self._assert_maps(
            lambda root: write_ext(root, "## Audit dimensions\n- **x** — d\n"),
            "appended",
        )

    def test_absent(self):
        def make(root):
            (root / ".devflow" / "prompt-extensions").mkdir(parents=True)
        self._assert_maps(make, "absent")

    def test_present_but_empty(self):
        self._assert_maps(lambda root: write_ext(root, ""), "absent")

    def test_present_but_unreadable(self):
        def make(root):
            p = write_ext(root, "## Audit dimensions\n- d\n")
            os.chmod(p, 0)
        if os.geteuid() == 0:
            self.skipTest("root bypasses unreadable-permission triage")
        self._assert_maps(make, "unestablished")

    def test_broken_symlink(self):
        def make(root):
            d = root / ".devflow" / "prompt-extensions"
            d.mkdir(parents=True)
            (d / "create-issue.md").symlink_to(root / "missing-target.md")
        self._assert_maps(make, "unestablished")

    def test_present_but_non_regular(self):
        def make(root):
            d = root / ".devflow" / "prompt-extensions"
            d.mkdir(parents=True)
            (d / "create-issue.md").mkdir()  # a directory, not a regular file
        self._assert_maps(make, "unestablished")


class MarkersAndContract(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def _ext(self, body):
        return write_ext(self.root, body)

    def test_R6_markers_positional_all_three_values(self):
        cases = {
            "appended": "## Audit dimensions\n- **x** — d\n",
            "absent": "## Other\n- nothing\n",
        }
        for status, body in cases.items():
            ext = self._ext(body)
            r = run_renderer(["file", "--slug", "s", "--draft-path", "/a/d.md",
                              "--extension-file", str(ext)])
            lines = r.stdout.splitlines()
            self.assertTrue(lines[0].startswith(f"render-status: {status}"))
            self.assertEqual(lines[-1], "render-end:")  # last line, positional
        # unestablished via a directory-shaped extension.
        d = self.root / "ext-dir"
        d.mkdir()
        r = run_renderer(["file", "--slug", "s", "--draft-path", "/a/d.md",
                          "--extension-file", str(d)])
        self.assertTrue(r.stdout.splitlines()[0].startswith("render-status: unestablished"))

    def test_R6_decoy_end_marker_tail_truncation_detectable(self):
        # A consumer section carrying a decoy interior `render-end:` line: a
        # tail-truncated copy must fail the positional (last-line) check.
        ext = self._ext("## Audit dimensions\n- **x** — a decoy line: render-end:\n")
        r = run_renderer(["file", "--slug", "s", "--draft-path", "/a/d.md",
                          "--extension-file", str(ext)])
        lines = r.stdout.splitlines()
        self.assertEqual(lines[-1], "render-end:")  # true terminal marker
        # Simulate a tail cut just after the decoy: last line is NOT render-end:.
        decoy_idx = max(i for i, ln in enumerate(lines) if ln.endswith("render-end:") and i < len(lines) - 1)
        truncated = lines[: decoy_idx + 1]
        self.assertNotEqual(truncated[-1], "render-end:")  # positional check catches it
        self.assertTrue(truncated[-1].startswith("- "))  # cut lands mid-body

    def test_R7_status_only_one_line_equals_full_first_line(self):
        ext = self._ext("## Audit dimensions\n- **x** — d\n")
        so = run_renderer(["status-only", "--extension-file", str(ext)])
        full = run_renderer(["file", "--slug", "s", "--draft-path", "/a/d.md",
                             "--extension-file", str(ext)])
        self.assertEqual(so.stdout.strip().count("\n"), 0)  # exactly one line
        self.assertEqual(so.stdout.strip(), full.stdout.splitlines()[0])

    def test_R8_determinism(self):
        ext = self._ext("## Audit dimensions\n- **x** — d\n")
        a = run_renderer(["file", "--slug", "s", "--draft-path", "/a/d.md",
                          "--extension-file", str(ext)])
        b = run_renderer(["file", "--slug", "s", "--draft-path", "/a/d.md",
                          "--extension-file", str(ext)])
        self.assertEqual(a.stdout, b.stdout)

    def test_R9_statelessness(self):
        ext = self._ext("## Audit dimensions\n- **x** — d\n")
        before = {p: p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        run_renderer(["embed", "--slug", "s",
                      "--sentinel-open", "AUDIT-AA11BB-OPEN",
                      "--sentinel-close", "AUDIT-AA11BB-CLOSE",
                      "--extension-file", str(ext)])
        after = {p: p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        self.assertEqual(before, after)  # no file written, no fixture mutation

    def test_R10_failure_arms(self):
        # Unusable arguments: file arm without --draft-path.
        r1 = run_renderer(["file", "--slug", "s"])
        self.assertNotEqual(r1.returncode, 0)
        self.assertEqual(r1.stdout, "")
        self.assertTrue(r1.stderr.strip())
        # Unreadable/absent template file.
        r2 = run_renderer(["file", "--slug", "s", "--draft-path", "/a/d.md",
                           "--template-file", "/nonexistent/template.md"])
        self.assertNotEqual(r2.returncode, 0)
        self.assertEqual(r2.stdout, "")
        self.assertTrue(r2.stderr.strip())

    def test_R12_argument_surface_closed(self):
        # Unknown mode rejected (argparse choices).
        self.assertNotEqual(run_renderer(["freeform-mode"]).returncode, 0)
        # Non-kebab slug rejected (no free text).
        self.assertNotEqual(
            run_renderer(["file", "--slug", "Not A Slug",
                          "--draft-path", "/a/d.md"]).returncode, 0)
        # Malformed sentinel rejected.
        self.assertNotEqual(
            run_renderer(["embed", "--slug", "s",
                          "--sentinel-open", "not-a-sentinel",
                          "--sentinel-close", "AUDIT-X-CLOSE"]).returncode, 0)
        # Unknown hook rejected.
        self.assertNotEqual(
            run_renderer(["extract", "--hook", "made-up"]).returncode, 0)


class TemplateFileOwnership(unittest.TestCase):
    """The committed template file is the sole owner of the moved literals."""

    def test_template_carries_moved_literals(self):
        t = TEMPLATE.read_text(encoding="utf-8")
        for lit in (
            "no credit for good intent",
            "write the autopsy",
            HASH_OBJECT,
            DRAFT_UNREADABLE_EMIT,
            "at most five findings",
            '"Quiet Killer"',
            "whose only three legal values are exactly",
            "judge the draft at **issue altitude**",
            READ_ORDERING_AMENDED,
        ):
            self.assertIn(lit, t, lit)


if __name__ == "__main__":
    unittest.main(verbosity=2)
