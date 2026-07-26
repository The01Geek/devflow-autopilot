#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Focused tests for the issue-810 pin-corpus authoring gate."""

from __future__ import annotations

import importlib.util
import io
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent
LINTER = HERE / "pin-corpus-lint.py"


def load_linter():
    spec = importlib.util.spec_from_file_location("pin_corpus_lint_810", LINTER)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def one_file_diff(path: str, old: str, new: str) -> str:
    old_lines = old.splitlines()
    new_lines = new.splitlines()
    body = [f"diff --git a/{path} b/{path}", f"--- a/{path}", f"+++ b/{path}"]
    body.append(f"@@ -1,{len(old_lines)} +1,{len(new_lines)} @@")
    body.extend(f"-{line}" for line in old_lines)
    body.extend(f"+{line}" for line in new_lines)
    return "\n".join(body) + "\n"


class PinCorpusLint810Tests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_linter()

    def test_closed_structural_categories_accept_nonempty_rationales(self):
        expected = {
            "helper-contract",
            "schema-config-vocabulary",
            "security-credential-boundary",
            "machine-sentinel-provenance",
            "routing-dispatch-contract",
            "lifecycle-state-transition",
            "generated-artifact-identity",
            "cross-file-phase-contract",
        }
        self.assertEqual(expected, set(self.mod.STRUCTURAL_PIN_CATEGORIES))
        for category in expected:
            declaration, error = self.mod.parse_structural_declaration(
                [f"# structural-pin-ok: {category} -- protects a machine boundary"]
            )
            self.assertIsNone(error)
            self.assertEqual(category, declaration.category)

    def test_structural_declaration_rejects_missing_unknown_empty_quoted_and_duplicate(self):
        invalid = {
            "missing category": ["# structural-pin-ok: -- because"],
            "unknown category": ["# structural-pin-ok: prose-presence -- because"],
            "empty rationale": ["# structural-pin-ok: helper-contract --   "],
            "quoted marker": [
                "assert_pin_unique 'x' '# structural-pin-ok: helper-contract -- fake' \"$F\""
            ],
            "duplicate marker": [
                "# structural-pin-ok: helper-contract -- one",
                "# structural-pin-ok: helper-contract -- two",
            ],
        }
        for label, lines in invalid.items():
            with self.subTest(label=label):
                declaration, error = self.mod.parse_structural_declaration(lines)
                self.assertIsNone(declaration)
                self.assertIsNotNone(error)

    def test_path_aware_diff_scopes_only_the_changed_file(self):
        shared = "assert_pin_unique \"wording\" 'same literal' \"$F\""
        sources = {"lib/test/a.sh": shared, "lib/test/b.sh": shared}
        base_sources = {"lib/test/a.sh": "old", "lib/test/b.sh": shared}
        findings = self.mod.scan_changed_sources(
            sources,
            base_sources,
            one_file_diff("lib/test/a.sh", "old", shared),
            repo_root="/repo",
        )
        self.assertEqual(1, len(findings))
        self.assertIn("lib/test/a.sh", findings[0])

    def test_partial_multiline_edit_scopes_the_complete_helper_site(self):
        old = (
            "assert_pin_unique \"wording\" \\\n"
            "  'old literal' \\\n"
            "  \"$F\""
        )
        new = old.replace("old literal", "new literal")
        diff = (
            "diff --git a/lib/test/a.sh b/lib/test/a.sh\n"
            "--- a/lib/test/a.sh\n+++ b/lib/test/a.sh\n"
            "@@ -2 +2 @@\n-  'old literal' \\\n+  'new literal' \\\n"
        )
        findings = self.mod.scan_changed_sources(
            {"lib/test/a.sh": new},
            {"lib/test/a.sh": old},
            diff,
            repo_root="/repo",
        )
        self.assertEqual(1, len(findings))
        self.assertIn("new literal", findings[0])

    def test_helper_and_raw_wording_pins_share_the_policy(self):
        helper = "assert_pin_unique \"wording\" 'literal' \"$F\""
        raw = (
            "DOC=\"$LIB/../docs/x.md\"\n"
            "assert_eq \"wording\" \"yes\" "
            "\"$(grep -qF -- 'literal' \"$DOC\" && echo yes || echo no)\""
        )
        for path, text in (("lib/test/helper.sh", helper), ("lib/test/raw.sh", raw)):
            with self.subTest(path=path):
                findings = self.mod.scan_changed_sources(
                    {path: text}, {path: ""}, one_file_diff(path, "", text), repo_root="/repo"
                )
                self.assertEqual(1, len(findings))
                self.assertIn("literal", findings[0])

    def test_valid_typed_helper_and_raw_pins_pass(self):
        marker = (
            "# structural-pin-ok: machine-sentinel-provenance -- "
            "the token is parsed by the consumer"
        )
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            target = root / "docs/x.md"
            target.parent.mkdir(parents=True)
            target.write_text("literal\n", encoding="utf-8")
            helper = (
                "F=\"$LIB/../docs/x.md\"\n"
                f"assert_pin_unique \"sentinel\" 'literal' \"$F\"  {marker}"
            )
            raw = (
                "DOC=\"$LIB/../docs/x.md\"\n"
                "assert_eq \"sentinel\" \"yes\" "
                f"\"$(grep -qF -- 'literal' \"$DOC\" && echo yes || echo no)\"  {marker}"
            )
            for path, text in (
                ("lib/test/helper.sh", helper),
                ("lib/test/raw.sh", raw),
            ):
                findings = self.mod.scan_changed_sources(
                    {path: text},
                    {path: ""},
                    one_file_diff(path, "", text),
                    repo_root=root,
                )
                self.assertEqual([], findings)

    def test_typed_declaration_requires_resolved_readable_target_and_literal(self):
        marker = (
            "# structural-pin-ok: cross-file-phase-contract -- "
            "claimed executable boundary"
        )
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "repo"
            root.mkdir()
            target = root / "docs/x.md"
            target.parent.mkdir(parents=True)
            target.write_text("TOKEN\n", encoding="utf-8")
            outside = Path(td) / "outside.md"
            outside.write_text("TOKEN\n", encoding="utf-8")
            cases = (
                (
                    "unresolved target",
                    f"assert_pin_unique \"wording\" 'human-facing prose' \"$UNKNOWN\"  {marker}",
                ),
                (
                    "unresolved literal",
                    "F=\"$LIB/../docs/x.md\"\n"
                    f"assert_pin_unique \"wording\" \"$UNKNOWN\" \"$F\"  {marker}",
                ),
                (
                    "empty literal",
                    "F=\"$LIB/../docs/x.md\"\n"
                    f"assert_pin_unique \"wording\" '' \"$F\"  {marker}",
                ),
                (
                    "missing target",
                    "F=\"$LIB/../docs/missing.md\"\n"
                    f"assert_pin_unique \"wording\" 'human-facing prose' \"$F\"  {marker}",
                ),
                (
                    "outside repository",
                    f"F=\"{outside}\"\n"
                    f"assert_pin_unique \"wording\" 'TOKEN' \"$F\"  {marker}",
                ),
                (
                    "literal absent from target",
                    "F=\"$LIB/../docs/x.md\"\n"
                    f"assert_pin_unique \"wording\" 'ABSENT' \"$F\"  {marker}",
                ),
            )
            for label, source in cases:
                with self.subTest(label=label):
                    findings = self.mod.scan_changed_sources(
                        {"lib/test/a.sh": source},
                        {"lib/test/a.sh": ""},
                        one_file_diff("lib/test/a.sh", "", source),
                        repo_root=root,
                    )
                    self.assertEqual(1, len(findings))
                    self.assertIn("cannot be inspected", findings[0])

    def test_typed_declaration_cannot_launder_prose(self):
        marker = (
            "# structural-pin-ok: cross-file-phase-contract -- "
            "the sentence is claimed to connect two phases"
        )
        for target_path, target_text in (
            ("docs/x.md", "## Advisory heading\n\nThis is human-facing prose.\n"),
            ("docs/x.md", "## Overview\n"),
            ("lib/x.sh", "# Advisory heading\nprintf '%s\\n' runtime\n"),
        ):
            with self.subTest(target=target_path), tempfile.TemporaryDirectory() as td:
                root = Path(td)
                target = root / target_path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(target_text, encoding="utf-8")
                literal = "Overview" if target_text == "## Overview\n" else "Advisory heading"
                source = (
                    f"F=\"$LIB/../{target_path}\"\n"
                    f"assert_pin_unique \"heading\" '{literal}' \"$F\"  {marker}"
                )
                findings = self.mod.scan_changed_sources(
                    {"lib/test/a.sh": source},
                    {"lib/test/a.sh": ""},
                    one_file_diff("lib/test/a.sh", "", source),
                    repo_root=root,
                )
                self.assertEqual(1, len(findings))
                self.assertIn("prose", findings[0])

    def test_typed_markdown_machine_token_in_code_fence_is_not_prose(self):
        marker = (
            "# structural-pin-ok: machine-sentinel-provenance -- "
            "the fenced token is parsed by a consumer"
        )
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            target = root / "docs/x.md"
            target.parent.mkdir(parents=True)
            target.write_text("```text\nMACHINE SENTINEL\n```\n", encoding="utf-8")
            source = (
                "F=\"$LIB/../docs/x.md\"\n"
                f"assert_pin_unique \"sentinel\" 'MACHINE SENTINEL' \"$F\"  {marker}"
            )
            findings = self.mod.scan_changed_sources(
                {"lib/test/a.sh": source},
                {"lib/test/a.sh": ""},
                one_file_diff("lib/test/a.sh", "", source),
                repo_root=root,
            )
        self.assertEqual([], findings)

    def test_direct_inline_repository_file_is_a_raw_presence_pin(self):
        source = (
            "assert_eq \"wording\" \"yes\" "
            "\"$(grep -qF -- 'literal' \"$LIB/../docs/x.md\" "
            "&& echo yes || echo no)\""
        )
        sites = self.mod.extract_guard_sites(source, "lib/test/a.sh", repo_root="/repo")
        self.assertEqual(["raw-presence"], [site.family for site in sites])

    def test_equivalent_helper_and_raw_command_forms_are_extracted(self):
        sources = {
            "helper under if": (
                "F=\"$LIB/../docs/x.md\"\n"
                "if assert_pin_unique \"wording\" 'literal' \"$F\"; then :; fi"
            ),
            "private wrapper": (
                "_raf_pin_unique() { devflow_module_pin_unique \"$@\"; }\n"
                "F=\"$LIB/../docs/x.md\"\n"
                "_raf_pin_unique \"wording\" 'literal' \"$F\""
            ),
            "opaque forwarding wrapper": (
                "F=\"$LIB/../docs/x.md\"\n"
                "contract_surface() { "
                "devflow_module_pin_present \"wrapped $1\" \"$2\" \"$F\"; }\n"
                "contract_surface \"wording\" 'literal'"
            ),
            "generic forwarding wrapper": (
                "F=\"$LIB/../docs/x.md\"\n"
                "contract_surface() { devflow_module_pin_present \"$@\"; }\n"
                "contract_surface \"wording\" 'literal' \"$F\""
            ),
            "short flags reversed": (
                "DOC=\"$LIB/../docs/x.md\"\n"
                "assert_eq \"wording\" \"yes\" "
                "\"$(grep -Fq -- 'literal' \"$DOC\" && echo yes || echo no)\""
            ),
            "short flags split": (
                "DOC=\"$LIB/../docs/x.md\"\n"
                "assert_eq \"wording\" \"yes\" "
                "\"$(grep -q -F -- 'literal' \"$DOC\" && echo yes || echo no)\""
            ),
            "long flags": (
                "DOC=\"$LIB/../docs/x.md\"\n"
                "assert_eq \"wording\" \"yes\" "
                "\"$(grep --fixed-strings --quiet -- 'literal' \"$DOC\" "
                "&& echo yes || echo no)\""
            ),
            "numeric boolean": (
                "DOC=\"$LIB/../docs/x.md\"\n"
                "assert_eq \"wording\" \"1\" "
                "\"$(grep -Fq -- 'literal' \"$DOC\" && echo 1 || echo 0)\""
            ),
            "if control flow": (
                "DOC=\"$LIB/../docs/x.md\"\n"
                "if grep -Fq -- 'literal' \"$DOC\"; then "
                "assert_eq \"wording\" \"yes\" \"yes\"; fi"
            ),
            "literal variable": (
                "DOC=\"$LIB/../docs/x.md\"\n"
                "LIT='literal'\n"
                "assert_eq \"wording\" \"yes\" "
                "\"$(grep -Fq -- $LIT \"$DOC\" && echo yes || echo no)\""
            ),
        }
        for label, source in sources.items():
            with self.subTest(label=label):
                sites = self.mod.extract_guard_sites(
                    source, "lib/test/a.sh", repo_root="/repo"
                )
                self.assertEqual(1, len(sites))
                self.assertEqual("literal", sites[0].literal)

        reversed_output = (
            "DOC=\"$LIB/../docs/x.md\"\n"
            "assert_eq \"absence\" \"yes\" "
            "\"$(grep -Fq -- 'literal' \"$DOC\" && echo no || echo yes)\""
        )
        self.assertEqual(
            [],
            self.mod.extract_guard_sites(
                reversed_output, "lib/test/a.sh", repo_root="/repo"
            ),
        )

    def test_runtime_pipe_count_absence_and_temp_greps_are_not_raw_presence_pins(self):
        source = "\n".join(
            [
                "assert_eq \"runtime\" \"yes\" \"$(printf x | grep -qF x && echo yes || echo no)\"",
                "assert_eq \"count\" \"1\" \"$(grep -cF x \"$DOC\")\"",
                "assert_eq \"absence\" \"no\" \"$(grep -qF x \"$DOC\" && echo yes || echo no)\"",
                "assert_eq \"temp\" \"yes\" \"$(grep -qF x \"$TMP_FILE\" && echo yes || echo no)\"",
            ]
        )
        sites = self.mod.extract_guard_sites(source, "lib/test/a.sh", repo_root="/repo")
        self.assertEqual([], [site for site in sites if site.family == "raw-presence"])

    def test_move_exemption_preserves_classification_one_to_one(self):
        marker = "# structural-pin-ok: helper-contract -- the helper name is invoked"
        prefix = "F=\"$LIB/../docs/x.md\"\n"
        legacy = prefix + "assert_pin_unique \"legacy\" 'L' \"$F\""
        typed = prefix + f"assert_pin_unique \"typed\" 'T' \"$F\"  {marker}"
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            target = root / "docs/x.md"
            target.parent.mkdir(parents=True)
            target.write_text("L\nT\n", encoding="utf-8")
            for old, new in ((legacy, legacy), (typed, typed)):
                findings = self.mod.scan_changed_sources(
                    {"lib/test/new.sh": new},
                    {"lib/test/old.sh": old},
                    one_file_diff("lib/test/old.sh", old, "")
                    + one_file_diff("lib/test/new.sh", "", new),
                    repo_root=root,
                )
                self.assertEqual([], findings)

            downgraded = prefix + "assert_pin_unique \"typed\" 'T' \"$F\""
            findings = self.mod.scan_changed_sources(
                {"lib/test/new.sh": downgraded},
                {"lib/test/old.sh": typed},
                one_file_diff("lib/test/old.sh", typed, "")
                + one_file_diff("lib/test/new.sh", "", downgraded),
                repo_root=root,
            )
            self.assertEqual(1, len(findings))

    def test_invalid_declaration_is_never_exempted_as_a_move(self):
        old = "assert_pin_unique \"legacy\" 'L' \"$F\""
        invalid = (
            "assert_pin_unique \"moved\" 'L' \"$F\"  "
            "# structural-pin-ok: prose-presence -- invalid category"
        )
        findings = self.mod.scan_changed_sources(
            {"lib/test/new.sh": invalid},
            {"lib/test/old.sh": old},
            one_file_diff("lib/test/old.sh", old, "")
            + one_file_diff("lib/test/new.sh", "", invalid),
            repo_root="/repo",
        )
        self.assertEqual(1, len(findings))
        self.assertIn("unknown structural category", findings[0])

    def test_move_exemption_rejects_a_changed_target_surface(self):
        old = (
            "F=\"$LIB/../scripts/tool.sh\"\n"
            "assert_pin_unique \"legacy\" 'TOKEN' \"$F\""
        )
        new = (
            "F=\"$LIB/../docs/tool.md\"\n"
            "assert_pin_unique \"moved\" 'TOKEN' \"$F\""
        )
        findings = self.mod.scan_changed_sources(
            {"lib/test/new.sh": new},
            {"lib/test/old.sh": old},
            one_file_diff("lib/test/old.sh", old, "")
            + one_file_diff("lib/test/new.sh", "", new),
            repo_root="/repo",
        )
        self.assertEqual(1, len(findings))

    def test_assignment_only_literal_change_reclassifies_unchanged_call(self):
        old = "LIT='old wording'\nassert_pin_unique \"wording\" \"$LIT\" \"$F\""
        new = "LIT='new wording'\nassert_pin_unique \"wording\" \"$LIT\" \"$F\""
        diff = (
            "diff --git a/lib/test/a.sh b/lib/test/a.sh\n"
            "--- a/lib/test/a.sh\n+++ b/lib/test/a.sh\n"
            "@@ -1 +1 @@\n-LIT='old wording'\n+LIT='new wording'\n"
        )
        findings = self.mod.scan_changed_sources(
            {"lib/test/a.sh": new},
            {"lib/test/a.sh": old},
            diff,
            repo_root="/repo",
        )
        self.assertEqual(1, len(findings))
        self.assertIn("new wording", findings[0])

    def test_inserted_site_does_not_shift_semantic_pairing_of_existing_sites(self):
        marker = "# structural-pin-ok: helper-contract -- executable helper token"
        prefix = "F=\"$LIB/../docs/x.md\"\n"
        existing_call = f"assert_pin_unique \"existing\" 'TOKEN' \"$F\"  {marker}"
        inserted = "assert_pin_unique \"new\" 'wording' \"$F\""
        existing = prefix + existing_call
        new = prefix + inserted + "\n" + existing_call
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            target = root / "docs/x.md"
            target.parent.mkdir(parents=True)
            target.write_text("TOKEN\nwording\n", encoding="utf-8")
            findings = self.mod.scan_changed_sources(
                {"lib/test/a.sh": new},
                {"lib/test/a.sh": existing},
                one_file_diff("lib/test/a.sh", existing, new),
                repo_root=root,
            )
            self.assertEqual(1, len(findings))
            self.assertIn("wording", findings[0])

    def test_latest_assignment_before_call_controls_effective_literal(self):
        source = (
            "LIT='stale wording'\n"
            "LIT='effective wording'\n"
            "assert_pin_unique \"wording\" \"$LIT\" \"$F\""
        )
        sites = self.mod.extract_guard_sites(
            source, "lib/test/a.sh", repo_root="/repo"
        )
        self.assertEqual("effective wording", sites[0].literal)

    def test_legacy_scans_resolve_assignments_at_each_call_site(self):
        source = (
            "F=\"$LIB/../docs/first.md\"\n"
            "assert_pin_unique \"first\" 'FIRST' \"$F\"\n"
            "F=\"$LIB/../docs/second.md\"\n"
            "assert_pin_unique \"second\" 'SECOND' \"$F\""
        )
        pins = list(self.mod.extract_pins(source, "/repo/lib", {}))
        self.assertEqual(
            ["/repo/docs/first.md", "/repo/docs/second.md"],
            [pin["file"] for pin in pins],
        )

    def test_git_quoted_unified_diff_paths_are_decoded(self):
        for encoded, decoded in (
            ('"b/lib/test/quoted name.sh"', "lib/test/quoted name.sh"),
            ('"b/lib/test/\\303\\251.sh"', "lib/test/é.sh"),
        ):
            with self.subTest(encoded=encoded):
                diff = (
                    f'diff --git "a/lib/test/old.sh" {encoded}\n'
                    "--- a/lib/test/old.sh\n"
                    f"+++ {encoded}\n"
                    "@@ -0,0 +1 @@\n"
                    "+assert_pin_unique \"wording\" 'literal' \"$F\"\n"
                )
                patches = self.mod.parse_unified_diff(diff)
                self.assertEqual(decoded, patches[0].new_path)

    def test_malformed_unified_diff_fails_closed(self):
        malformed = (
            (
                "unterminated quoted path",
                'diff --git a/lib/test/a.sh b/lib/test/a.sh\n'
                "--- a/lib/test/a.sh\n"
                '+++ "b/lib/test/a.sh\n'
                "@@ -0,0 +1 @@\n"
                "+assert_pin_unique \"wording\" 'literal' \"$F\"\n",
            ),
            (
                "missing new header",
                "diff --git a/lib/test/a.sh b/lib/test/a.sh\n"
                "--- a/lib/test/a.sh\n"
                "@@ -0,0 +1 @@\n"
                "+assert_pin_unique \"wording\" 'literal' \"$F\"\n",
            ),
            (
                "malformed hunk",
                "diff --git a/lib/test/a.sh b/lib/test/a.sh\n"
                "--- a/lib/test/a.sh\n"
                "+++ b/lib/test/a.sh\n"
                "@@ malformed @@\n"
                "+assert_pin_unique \"wording\" 'literal' \"$F\"\n",
            ),
            (
                "truncated hunk",
                "diff --git a/lib/test/a.sh b/lib/test/a.sh\n"
                "--- a/lib/test/a.sh\n"
                "+++ b/lib/test/a.sh\n"
                "@@ -0,0 +1,2 @@\n"
                "+assert_pin_unique \"wording\" 'literal' \"$F\"\n",
            ),
            (
                "headers without hunk",
                "diff --git a/lib/test/a.sh b/lib/test/a.sh\n"
                "--- a/lib/test/a.sh\n"
                "+++ b/lib/test/a.sh\n",
            ),
            (
                "arbitrary post-header text",
                "diff --git a/lib/test/a.sh b/lib/test/a.sh\n"
                "--- a/lib/test/a.sh\n"
                "+++ b/lib/test/a.sh\n"
                "GARBAGE\n",
            ),
            (
                "both sides dev null",
                "diff --git a/lib/test/a.sh b/lib/test/a.sh\n"
                "--- /dev/null\n"
                "+++ /dev/null\n"
                "@@ -0,0 +1 @@\n"
                "+wording\n",
            ),
            (
                "misplaced no-newline marker",
                "diff --git a/lib/test/a.sh b/lib/test/a.sh\n"
                "--- a/lib/test/a.sh\n"
                "+++ b/lib/test/a.sh\n"
                "@@ -1 +1 @@\n"
                "\\ No newline at end of file\n"
                "-old\n"
                "+new\n",
            ),
            (
                "duplicate no-newline marker",
                "diff --git a/lib/test/a.sh b/lib/test/a.sh\n"
                "--- a/lib/test/a.sh\n"
                "+++ b/lib/test/a.sh\n"
                "@@ -1 +1 @@\n"
                "-old\n"
                "\\ No newline at end of file\n"
                "\\ No newline at end of file\n"
                "+new\n",
            ),
            (
                "bare diff header",
                "diff --git a/lib/test/a.sh b/lib/test/a.sh\n",
            ),
            (
                "index without change record",
                "diff --git a/lib/test/a.sh b/lib/test/a.sh\n"
                "index 123..456 100644\n",
            ),
            (
                "malformed index metadata",
                "diff --git a/lib/test/a.sh b/lib/test/a.sh\n"
                "index garbage\n",
            ),
        )
        for label, diff in malformed:
            with self.subTest(label=label), self.assertRaises(
                self.mod.InfrastructureError
            ):
                self.mod.parse_unified_diff(diff)

    def test_hunk_content_that_resembles_file_headers_is_valid(self):
        diff = (
            "diff --git a/lib/test/a.sh b/lib/test/a.sh\n"
            "--- a/lib/test/a.sh\n"
            "+++ b/lib/test/a.sh\n"
            "@@ -1 +1 @@\n"
            "---old\n"
            "+++new\n"
        )
        patches = self.mod.parse_unified_diff(diff)
        self.assertEqual(frozenset({1}), patches[0].deleted_lines)
        self.assertEqual(frozenset({1}), patches[0].added_lines)

    def test_valid_no_newline_markers_after_old_and_new_lines(self):
        diff = (
            "diff --git a/lib/test/a.sh b/lib/test/a.sh\n"
            "--- a/lib/test/a.sh\n"
            "+++ b/lib/test/a.sh\n"
            "@@ -1 +1 @@\n"
            "-old\n"
            "\\ No newline at end of file\n"
            "+new\n"
            "\\ No newline at end of file\n"
        )
        patches = self.mod.parse_unified_diff(diff)
        self.assertEqual(frozenset({1}), patches[0].deleted_lines)
        self.assertEqual(frozenset({1}), patches[0].added_lines)

    def test_complete_metadata_only_mode_change_is_valid(self):
        diff = (
            "diff --git a/lib/test/a.sh b/lib/test/a.sh\n"
            "old mode 100644\n"
            "new mode 100755\n"
        )
        self.assertEqual((), self.mod.parse_unified_diff(diff))

    def test_mutation_to_static_and_one_delete_to_two_adds_are_not_exempt(self):
        old = "assert_pin_red_under \"behavior\" 'L' 's/x/y/' \"$F\""
        new = "assert_pin_unique \"wording\" 'L' \"$F\""
        doubled = new + "\n" + new
        findings = self.mod.scan_changed_sources(
            {"lib/test/new.sh": doubled},
            {"lib/test/old.sh": old},
            one_file_diff("lib/test/old.sh", old, "")
            + one_file_diff("lib/test/new.sh", "", doubled),
            repo_root="/repo",
        )
        self.assertEqual(2, len(findings))

    def test_forwarding_wrapper_preserves_mutation_helper_family(self):
        source = (
            "wrap() { devflow_module_pin_red_under \"$@\"; }\n"
            "wrap \"behavior\" 'TOKEN' 's/x/y/' \"$F\""
        )
        sites = self.mod.extract_guard_sites(
            source, "lib/test/a.sh", repo_root="/repo"
        )
        self.assertEqual(1, len(sites))
        self.assertEqual("mutation-helper", sites[0].family)
        findings = self.mod.scan_changed_sources(
            {"lib/test/a.sh": source},
            {"lib/test/a.sh": ""},
            one_file_diff("lib/test/a.sh", "", source),
            repo_root="/repo",
        )
        self.assertEqual([], findings)

    def test_invoked_wrapper_does_not_hide_additional_body_pin(self):
        source = (
            "F=\"$LIB/../docs/x.md\"\n"
            "wrap() {\n"
            "  devflow_module_pin_red_under \"$@\"\n"
            "  devflow_module_pin_present \"wording\" 'HUMAN PROSE' \"$F\"\n"
            "}\n"
            "wrap \"behavior\" 'TOKEN' 's/x/y/' \"$F\""
        )
        sites = self.mod.extract_guard_sites(
            source, "lib/test/a.sh", repo_root="/repo"
        )
        self.assertEqual(
            ["mutation-helper", "static-helper"],
            sorted(site.family for site in sites),
        )
        findings = self.mod.scan_changed_sources(
            {"lib/test/a.sh": source},
            {"lib/test/a.sh": ""},
            one_file_diff("lib/test/a.sh", "", source),
            repo_root="/repo",
        )
        self.assertEqual(1, len(findings))
        self.assertIn("HUMAN PROSE", findings[0])

    def test_wrapper_family_comes_from_body_not_name_suffix(self):
        for name in ("fake_pin_red_under", "fake_pin_count"):
            with self.subTest(name=name):
                source = (
                    f"{name}() {{ devflow_module_pin_present \"$@\"; }}\n"
                    f"{name} \"wording\" 'literal' \"$F\""
                )
                sites = self.mod.extract_guard_sites(
                    source, "lib/test/a.sh", repo_root="/repo"
                )
                self.assertEqual(["static-helper"], [site.family for site in sites])
                findings = self.mod.scan_changed_sources(
                    {"lib/test/a.sh": source},
                    {"lib/test/a.sh": ""},
                    one_file_diff("lib/test/a.sh", "", source),
                    repo_root="/repo",
                )
                self.assertEqual(1, len(findings))

    def test_multiline_positional_wrapper_has_one_inferred_call_site(self):
        source = (
            "F=\"$LIB/../docs/x.md\"\n"
            "wrap() {\n"
            "  devflow_module_pin_present \"wrapped ${1}\" \"${2}\" \"${3}\"\n"
            "}\n"
            "wrap \"wording\" 'literal' \"$F\""
        )
        sites = self.mod.extract_guard_sites(
            source, "lib/test/a.sh", repo_root="/repo"
        )
        self.assertEqual(1, len(sites))
        self.assertEqual("literal", sites[0].literal)
        self.assertEqual("/repo/docs/x.md", sites[0].target_path)

    def test_helper_name_used_as_an_argument_is_not_a_call(self):
        sites = self.mod.extract_guard_sites(
            "printf '%s' assert_pin_unique",
            "lib/test/a.sh",
            repo_root="/repo",
        )
        self.assertEqual([], sites)

    def test_uninferred_forwarding_body_is_not_silently_skipped(self):
        source = 'f() { assert_pin_unique "$@" extra; }'
        sites = self.mod.extract_guard_sites(
            source, "lib/test/a.sh", repo_root="/repo"
        )
        self.assertEqual(1, len(sites))
        findings = self.mod.scan_changed_sources(
            {"lib/test/a.sh": source},
            {"lib/test/a.sh": ""},
            one_file_diff("lib/test/a.sh", "", source),
            repo_root="/repo",
        )
        self.assertEqual(1, len(findings))

    def test_function_comment_brace_does_not_terminate_wrapper_scan(self):
        source = (
            "F=\"$LIB/../docs/x.md\"\n"
            "wrap() {\n"
            "  # a comment with } must not close the body\n"
            "  devflow_module_pin_present \"$@\"\n"
            "}\n"
            "wrap \"wording\" 'literal' \"$F\""
        )
        sites = self.mod.extract_guard_sites(
            source, "lib/test/a.sh", repo_root="/repo"
        )
        self.assertEqual(1, len(sites))
        self.assertEqual("literal", sites[0].literal)

    def test_dependent_path_assignment_keeps_assignment_time_value(self):
        source = (
            "A=\"$LIB/../docs\"\n"
            "B=\"$A/x.md\"\n"
            "A=\"$LIB/../other\"\n"
            "assert_pin_unique \"wording\" 'literal' \"$B\""
        )
        sites = self.mod.extract_guard_sites(
            source, "lib/test/a.sh", repo_root="/repo"
        )
        self.assertEqual("/repo/docs/x.md", sites[0].target_path)

    def test_fixed_literal_inside_wrapper_definition_is_not_skipped(self):
        source = (
            "F=\"$LIB/../docs/x.md\"\n"
            "wrap() { devflow_module_pin_present \"wording\" 'literal' \"$F\"; }\n"
            "wrap"
        )
        sites = self.mod.extract_guard_sites(
            source, "lib/test/a.sh", repo_root="/repo"
        )
        self.assertEqual(1, len(sites))
        self.assertEqual("literal", sites[0].literal)

    def test_fixed_literal_wrapper_with_forwarded_target_is_inferred(self):
        for target_ref in ("$1", "${1}"):
            with self.subTest(target_ref=target_ref):
                source = (
                    "F=\"$LIB/../docs/x.md\"\n"
                    "wrap() { "
                    f"devflow_module_pin_present \"wording\" 'FIXED LITERAL' "
                    f'"{target_ref}"; }}\n'
                    "wrap \"$F\""
                )
                sites = self.mod.extract_guard_sites(
                    source, "lib/test/a.sh", repo_root="/repo"
                )
                self.assertEqual(1, len(sites))
                self.assertEqual("FIXED LITERAL", sites[0].literal)
                self.assertEqual("/repo/docs/x.md", sites[0].target_path)
                findings = self.mod.scan_changed_sources(
                    {"lib/test/a.sh": source},
                    {"lib/test/a.sh": ""},
                    one_file_diff("lib/test/a.sh", "", source),
                    repo_root="/repo",
                )
                self.assertEqual(1, len(findings))

    def test_fixed_prefix_before_splat_wrapper_is_inferred(self):
        source = (
            "F=\"$LIB/../docs/x.md\"\n"
            "wrap() { devflow_module_pin_present \"label\" \"$@\"; }\n"
            "wrap 'HUMAN PROSE' \"$F\""
        )
        sites = self.mod.extract_guard_sites(
            source, "lib/test/a.sh", repo_root="/repo"
        )
        self.assertEqual(1, len(sites))
        self.assertEqual("HUMAN PROSE", sites[0].literal)
        self.assertEqual("/repo/docs/x.md", sites[0].target_path)
        findings = self.mod.scan_changed_sources(
            {"lib/test/a.sh": source},
            {"lib/test/a.sh": ""},
            one_file_diff("lib/test/a.sh", "", source),
            repo_root="/repo",
        )
        self.assertEqual(1, len(findings))

    def test_raw_presence_unresolved_indented_and_quoted_targets_fail_closed(self):
        cases = (
            (
                "computed",
                "DOC=\"$(printf %s \"$LIB/../docs/x.md\")\"\n"
                "assert_eq \"wording\" \"yes\" "
                "\"$(grep -qF -- 'HUMAN PROSE' \"$DOC\" && echo yes || echo no)\"",
            ),
            (
                "indented assignment",
                "wrap() {\n"
                "  local DOC=\"$LIB/../docs/x.md\"\n"
                "  assert_eq \"wording\" \"yes\" "
                "\"$(grep -Fq -- 'HUMAN PROSE' \"$DOC\" && echo yes || echo no)\"\n"
                "}",
            ),
            (
                "single-quoted target",
                "assert_eq \"wording\" \"yes\" "
                "\"$(grep -Fq -- 'HUMAN PROSE' 'docs/x.md' "
                "&& echo yes || echo no)\"",
            ),
        )
        for label, source in cases:
            with self.subTest(label=label):
                sites = self.mod.extract_guard_sites(
                    source, "lib/test/a.sh", repo_root="/repo"
                )
                self.assertEqual(1, len(sites))
                findings = self.mod.scan_changed_sources(
                    {"lib/test/a.sh": source},
                    {"lib/test/a.sh": ""},
                    one_file_diff("lib/test/a.sh", "", source),
                    repo_root="/repo",
                )
                self.assertEqual(1, len(findings))

    def test_shell_cat_membership_presence_assertion_shares_policy(self):
        source = (
            "DOC=\"$LIB/../docs/x.md\"\n"
            "[[ \"$(cat \"$DOC\")\" == *'HUMAN PROSE'* ]]"
        )
        sites = self.mod.extract_guard_sites(
            source, "lib/test/a.sh", repo_root="/repo"
        )
        self.assertEqual(1, len(sites))
        self.assertEqual("HUMAN PROSE", sites[0].literal)
        findings = self.mod.scan_changed_sources(
            {"lib/test/a.sh": source},
            {"lib/test/a.sh": ""},
            one_file_diff("lib/test/a.sh", "", source),
            repo_root="/repo",
        )
        self.assertEqual(1, len(findings))

    def test_python_file_text_presence_assertion_shares_policy(self):
        source = (
            "from pathlib import Path\n"
            "import unittest\n\n"
            "class T(unittest.TestCase):\n"
            "    def test_wording(self):\n"
            "        self.assertIn('advisory wording', Path('docs/x.md').read_text())\n"
        )
        sites = self.mod.extract_guard_sites(
            source, "lib/test/test_wording.py", repo_root="/repo"
        )
        self.assertEqual(1, len(sites))
        findings = self.mod.scan_changed_sources(
            {"lib/test/test_wording.py": source},
            {"lib/test/test_wording.py": ""},
            one_file_diff("lib/test/test_wording.py", "", source),
            repo_root="/repo",
        )
        self.assertEqual(1, len(findings))
        self.assertIn("advisory wording", findings[0])

    def test_python_regex_and_assigned_file_text_share_policy(self):
        cases = (
            (
                "regex",
                "self.assertRegex(Path('docs/x.md').read_text(), 'advisory wording')",
            ),
            (
                "assigned pathlib",
                "text = Path('docs/x.md').read_text()\n"
                "self.assertIn('advisory wording', text)",
            ),
            (
                "assigned open",
                "text = open('docs/x.md').read()\n"
                "self.assertIn('advisory wording', text)",
            ),
            (
                "plain assert",
                "assert 'advisory wording' in Path('docs/x.md').read_text()",
            ),
        )
        for label, body in cases:
            with self.subTest(label=label):
                source = "from pathlib import Path\n" + body + "\n"
                findings = self.mod.scan_changed_sources(
                    {"lib/test/test_wording.py": source},
                    {"lib/test/test_wording.py": ""},
                    one_file_diff("lib/test/test_wording.py", "", source),
                    repo_root="/repo",
                )
                self.assertEqual(1, len(findings))
                self.assertIn("advisory wording", findings[0])

    def test_python_assigned_read_respects_scope_order_and_reassignment(self):
        source = (
            "from pathlib import Path\n"
            "import unittest\n\n"
            "class T(unittest.TestCase):\n"
            "    def test_runtime(self):\n"
            "        text = get_output()\n"
            "        self.assertIn('runtime status', text)\n\n"
            "    def test_file(self):\n"
            "        text = Path('docs/x.md').read_text()\n"
            "        text = get_output()\n"
            "        self.assertIn('later runtime status', text)\n"
        )
        sites = self.mod.extract_guard_sites(
            source, "lib/test/test_wording.py", repo_root="/repo"
        )
        self.assertEqual([], sites)

    def test_python_direct_file_assertion_can_use_valid_typed_boundary(self):
        marker = (
            "# structural-pin-ok: machine-sentinel-provenance -- "
            "the token is parsed by the consumer"
        )
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            target = root / "docs/x.md"
            target.parent.mkdir()
            target.write_text("TOKEN\n", encoding="utf-8")
            source = (
                "from pathlib import Path\n"
                "self.assertIn('TOKEN', Path('docs/x.md').read_text())  "
                f"{marker}\n"
            )
            findings = self.mod.scan_changed_sources(
                {"lib/test/test_wording.py": source},
                {"lib/test/test_wording.py": ""},
                one_file_diff("lib/test/test_wording.py", "", source),
                repo_root=root,
            )
        self.assertEqual([], findings)

    def test_scanner_population_is_exactly_registry_closed(self):
        registry = {
            "schema_version": 1,
            "test_modules": {
                "one": {
                    "path": "lib/test/modules/one.sh",
                    "minimum_assertions": 1,
                },
                "two": {
                    "path": "lib/test/modules/two.sh",
                    "minimum_assertions": 2,
                },
            }
        }
        expected = {
            "lib/test/run.sh",
            "lib/test/modules/one.sh",
            "lib/test/modules/two.sh",
        }
        self.assertEqual([], self.mod.validate_audited_population(registry, expected, expected))
        self.assertTrue(
            self.mod.validate_audited_population(
                registry, expected - {"lib/test/modules/two.sh"}, expected
            )
        )
        self.assertTrue(
            self.mod.validate_audited_population(
                registry, expected | {"lib/test/modules/stale.sh"}, expected
            )
        )

    def test_duplicate_registry_keys_are_rejected_at_load_boundary(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "registry.json"
            path.write_text(
                '{"schema_version":0,"schema_version":1,"test_modules":{}}',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                self.mod.InfrastructureError, "duplicate registry key"
            ):
                self.mod.load_registry(path)

    def test_public_worktree_command_maps_infrastructure_and_findings_to_exit_codes(self):
        with mock.patch.object(
            self.mod, "scan_worktree", side_effect=self.mod.InfrastructureError("boom")
        ):
            self.assertEqual(
                2, self.mod.main(["pin-corpus-lint.py", "mutation-routing-worktree", "/repo"])
            )
        with mock.patch.object(
            self.mod, "scan_worktree", return_value=["MUTATION-ROUTING\tfinding"]
        ):
            self.assertEqual(
                3, self.mod.main(["pin-corpus-lint.py", "mutation-routing-worktree", "/repo"])
            )

    def test_registry_fixture_is_json_serializable(self):
        # Sanity-check the same shape used by the production population validator.
        registry = {
            "schema_version": 1,
            "test_modules": {
                "x": {
                    "path": "lib/test/modules/x.sh",
                    "minimum_assertions": 1,
                }
            },
        }
        self.assertEqual(
            [],
            self.mod.validate_audited_population(
                registry,
                {"lib/test/run.sh", "lib/test/modules/x.sh"},
                {"lib/test/run.sh", "lib/test/modules/x.sh"},
            ),
        )


class RetainedBoundaryRatchetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_linter()

    def _repo(self, root):
        for relative in (
            *sorted(self.mod.AUDITED_PIN_SOURCES),
            "lib/test/module-harness.sh",
            "lib/test/pin-corpus-lint.py",
            ".devflow/logs/mutation-pin-corpus-inventory.tsv",
            "scripts/workflow-flight-recorder-registry.json",
        ):
            source = REPO_ROOT / relative
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        subprocess.run(["git", "add", "."], cwd=root, check=True)

    def _public_rc(self, root):
        with (
            mock.patch("sys.stdout", new_callable=io.StringIO) as stdout,
            mock.patch("sys.stderr", new_callable=io.StringIO) as stderr,
        ):
            rc = self.mod.main(
                ["pin-corpus-lint.py", "mutation-routing-worktree", str(root)]
            )
        return rc, stdout.getvalue(), stderr.getvalue()

    def _census(self, root):
        return self.mod._load_mutation_census_module().build_census(root)

    def _rewrite_inventory(self, root):
        census = self.mod._load_mutation_census_module()
        inventory = root / ".devflow/logs/mutation-pin-corpus-inventory.tsv"
        inventory.write_text(
            census.render_adjudication_tsv(
                census.build_census(root),
                "a" * 40,
            ),
            encoding="utf-8",
        )

    def _first_retained_row(self, root):
        return self._census(root).rows[0]

    def _replace_call(self, root, row, replacement):
        path = root / row.path
        lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
        replacement_lines = [replacement + "\n"] if replacement else []
        path.write_text(
            "".join(
                [
                    *lines[: row.line_start - 1],
                    *replacement_lines,
                    *lines[row.line_end :],
                ]
            ),
            encoding="utf-8",
        )

    def test_current_census_and_unrelated_edits_pass(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            self._repo(root)
            self.assertEqual((0, "", ""), self._public_rc(root))
            outside = root / "docs/unfrozen.md"
            outside.parent.mkdir(parents=True)
            outside.write_text("ordinary unrelated addition\n", encoding="utf-8")
            self.assertEqual((0, "", ""), self._public_rc(root))
            row = self._first_retained_row(root)
            audited = root / row.path
            audited.write_text(
                "# unrelated audited-source line before retained calls\n"
                + audited.read_text(encoding="utf-8"),
                encoding="utf-8",
            )
            self.assertEqual((0, "", ""), self._public_rc(root))

    def test_deletion_passes_when_inventory_is_updated(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            self._repo(root)
            row = self._first_retained_row(root)
            self._replace_call(root, row, "")
            self._rewrite_inventory(root)
            self.assertEqual((0, "", ""), self._public_rc(root))

    def test_new_changed_and_reformatted_calls_are_policy_findings(self):
        def append_call(root, row, call):
            path = root / row.path
            path.write_text(
                path.read_text(encoding="utf-8") + "\n" + call + "\n",
                encoding="utf-8",
            )

        mutations = {
            "new generic": lambda root, row: append_call(
                root,
                row,
                "assert_pin_red_under new literal mutation target",
            ),
            "new count": lambda root, row: append_call(
                root,
                row,
                "assert_count_red_under new count mutation target",
            ),
            "changed": lambda root, row: self._replace_call(
                root,
                row,
                row.logical_call + " changed",
            ),
            "reformatted": lambda root, row: self._replace_call(
                root,
                row,
                row.logical_call.replace(" ", "  ", 1),
            ),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as td:
                root = Path(td)
                self._repo(root)
                row = self._first_retained_row(root)
                mutate(root, row)
                rc, stdout, stderr = self._public_rc(root)
                self.assertEqual(3, rc, stderr)
                self.assertIn("MUTATION-ROUTING", stdout)

    def test_same_file_byte_identical_move_is_the_documented_identity_limit(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            self._repo(root)
            row = self._first_retained_row(root)
            self._replace_call(root, row, "")
            path = root / row.path
            path.write_text(
                path.read_text(encoding="utf-8")
                + "\n"
                + row.logical_call
                + "\n",
                encoding="utf-8",
            )
            self.assertEqual((0, "", ""), self._public_rc(root))

    def test_inventory_missing_malformed_duplicate_or_mismatched_is_infrastructure(self):
        cases = ("missing", "malformed", "duplicate", "mismatch")
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as td:
                root = Path(td)
                self._repo(root)
                inventory = (
                    root / ".devflow/logs/mutation-pin-corpus-inventory.tsv"
                )
                if case == "missing":
                    inventory.unlink()
                elif case == "malformed":
                    inventory.write_text(
                        "not\ta\tvalid\tinventory\n",
                        encoding="utf-8",
                    )
                elif case == "duplicate":
                    lines = inventory.read_text(encoding="utf-8").splitlines()
                    lines.insert(4, lines[3])
                    inventory.write_text(
                        "\n".join(lines) + "\n",
                        encoding="utf-8",
                    )
                else:
                    lines = inventory.read_text(encoding="utf-8").splitlines()
                    inventory.write_text(
                        "\n".join([*lines[:3], *lines[4:]]) + "\n",
                        encoding="utf-8",
                    )
                rc, _stdout, stderr = self._public_rc(root)
                self.assertEqual(2, rc)
                self.assertIn("MUTATION-ROUTING-INFRASTRUCTURE", stderr)

    def test_nonretain_inventory_disposition_is_infrastructure(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            self._repo(root)
            inventory = root / ".devflow/logs/mutation-pin-corpus-inventory.tsv"
            text = inventory.read_text(encoding="utf-8")
            inventory.write_text(
                text.replace(
                    "\tretain_executable_boundary\t",
                    "\tretire_presence_equivalent\t",
                    1,
                ),
                encoding="utf-8",
            )
            self.assertEqual(2, self._public_rc(root)[0])

    def test_census_ambiguity_is_infrastructure(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            self._repo(root)
            row = self._first_retained_row(root)
            path = root / row.path
            path.write_text(
                path.read_text(encoding="utf-8")
                + "\ncommand assert_count_red_under ambiguous call\n",
                encoding="utf-8",
            )
            self.assertEqual(2, self._public_rc(root)[0])

    def test_required_path_runs_only_git_enumeration_not_mutation_semantics(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            self._repo(root)
            real_run = subprocess.run

            def git_only(args, **kwargs):
                self.assertEqual(args[:2], ["git", "ls-files"])
                return real_run(args, **kwargs)

            with mock.patch.object(
                subprocess,
                "run",
                side_effect=git_only,
            ):
                self.assertEqual((0, "", ""), self._public_rc(root))


if __name__ == "__main__":
    unittest.main()
