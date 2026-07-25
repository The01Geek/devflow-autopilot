#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Focused tests for the issue-810 pin-corpus authoring gate."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
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
        helper = f"assert_pin_unique \"sentinel\" 'literal' \"$F\"  {marker}"
        raw = (
            "DOC=\"$LIB/../docs/x.md\"\n"
            "assert_eq \"sentinel\" \"yes\" "
            f"\"$(grep -qF -- 'literal' \"$DOC\" && echo yes || echo no)\"  {marker}"
        )
        for path, text in (("lib/test/helper.sh", helper), ("lib/test/raw.sh", raw)):
            findings = self.mod.scan_changed_sources(
                {path: text}, {path: ""}, one_file_diff(path, "", text), repo_root="/repo"
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
        legacy = "assert_pin_unique \"legacy\" 'L' \"$F\""
        typed = f"assert_pin_unique \"typed\" 'T' \"$F\"  {marker}"
        for old, new in ((legacy, legacy), (typed, typed)):
            findings = self.mod.scan_changed_sources(
                {"lib/test/new.sh": new},
                {"lib/test/old.sh": old},
                one_file_diff("lib/test/old.sh", old, "")
                + one_file_diff("lib/test/new.sh", "", new),
                repo_root="/repo",
            )
            self.assertEqual([], findings)

        downgraded = "assert_pin_unique \"typed\" 'T' \"$F\""
        findings = self.mod.scan_changed_sources(
            {"lib/test/new.sh": downgraded},
            {"lib/test/old.sh": typed},
            one_file_diff("lib/test/old.sh", typed, "")
            + one_file_diff("lib/test/new.sh", "", downgraded),
            repo_root="/repo",
        )
        self.assertEqual(1, len(findings))

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

    def test_scanner_population_is_exactly_registry_closed(self):
        registry = {
            "test_modules": {
                "one": {"path": "lib/test/modules/one.sh"},
                "two": {"path": "lib/test/modules/two.sh"},
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

    def test_worktree_setup_failures_are_infrastructure_errors(self):
        commands = (
            "rev-parse --verify origin/main",
            "merge-base --is-ancestor",
            "merge-base origin/main HEAD",
            "diff --no-color",
            "ls-files --others",
            "ls-files --cached",
            "ls-tree -r",
        )
        for failed_command in commands:
            with self.subTest(command=failed_command):
                def runner(args, **_kwargs):
                    rendered = " ".join(args)
                    rc = 1 if failed_command in rendered else 0
                    stdout = ""
                    if "rev-parse --verify origin/main" in rendered:
                        stdout = "base\n"
                    elif "merge-base origin/main HEAD" in rendered:
                        stdout = "mergebase\n"
                    return subprocess.CompletedProcess(args, rc, stdout, "injected")

                with self.assertRaises(self.mod.InfrastructureError):
                    self.mod.scan_worktree(
                        "/repo",
                        git_runner=runner,
                        scratch_factory=lambda: tempfile.TemporaryFile(mode="w+"),
                    )

        with self.assertRaises(self.mod.InfrastructureError):
            self.mod.scan_worktree(
                "/repo",
                git_runner=lambda args, **_kwargs: subprocess.CompletedProcess(
                    args, 0, "base\n", ""
                ),
                scratch_factory=lambda: (_ for _ in ()).throw(OSError("injected")),
            )

        def broken_local_main(args, **_kwargs):
            rendered = " ".join(args)
            if "refs/heads/main" in rendered:
                return subprocess.CompletedProcess(args, 2, "", "injected")
            return subprocess.CompletedProcess(args, 0, "base\n", "")

        with self.assertRaisesRegex(self.mod.InfrastructureError, "local main resolution"):
            self.mod.scan_worktree(
                "/repo",
                git_runner=broken_local_main,
                scratch_factory=lambda: tempfile.TemporaryFile(mode="w+"),
            )

    def test_required_path_has_no_classifier_or_inventory_dependency(self):
        text = LINTER.read_text(encoding="utf-8")
        start = text.index("def scan_worktree")
        required_path = text[start : text.index("\ndef main", start)]
        self.assertNotIn("pin-corpus-classifier", required_path)
        self.assertNotIn("pin-corpus-inventory.tsv", required_path)

    def test_registry_fixture_is_json_serializable(self):
        # Keeps the registry fixture shape coupled to the production JSON boundary.
        json.dumps({"test_modules": {"x": {"path": "lib/test/modules/x.sh"}}})


if __name__ == "__main__":
    unittest.main()
