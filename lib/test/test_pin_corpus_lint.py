#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Focused tests for the issue-810 pin-corpus authoring gate.

SHARDING REQUIREMENT (issue #870). lib/test/modules/harness-python-guards.sh runs this
file as several concurrent selector processes, which is only safe because every test here
is independent of every other: no ``os.chdir``, no module-level mutable state, and each
test allocating its own ``tempfile.TemporaryDirectory()`` and passing an explicit ``cwd=``
to its subprocesses. A test added here that takes a process-global lock on the working
directory, or shares mutable state across tests, breaks that property and makes the
sharded run order-dependent. Keep new tests self-contained.
"""

from __future__ import annotations

import importlib.util
import hashlib
import io
import json
import re
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
EXTRACTOR = HERE / "extract-command-heads.py"


def load_linter():
    spec = importlib.util.spec_from_file_location("pin_corpus_lint_810", LINTER)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def load_extractor():
    spec = importlib.util.spec_from_file_location(
        "extract_command_heads_687", EXTRACTOR
    )
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


class Issue687OutputRoutingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.linter = load_linter()
        cls.extractor = load_extractor()

    def test_pin_corpus_clean_scans_route_accounting_only_to_stderr(self):
        with tempfile.TemporaryDirectory() as td:
            pin_source = Path(td) / "pins.sh"
            pin_source.write_text("", encoding="utf-8")
            for scan in (self.linter.run_lint, self.linter.run_wrapped):
                with (
                    self.subTest(scan=scan.__name__),
                    mock.patch("sys.stdout", new_callable=io.StringIO) as stdout,
                    mock.patch("sys.stderr", new_callable=io.StringIO) as stderr,
                ):
                    rc = scan(
                        str(pin_source),
                        str(REPO_ROOT),
                        {},
                        set(),
                        strict=True,
                    )
                    self.assertEqual(0, rc)
                    self.assertEqual("", stdout.getvalue())
                    self.assertEqual(
                        "UNRESOLVED-COUNT\t0\nRESOLVED-COUNT\t0\n",
                        stderr.getvalue(),
                    )

    def test_extract_heads_stdout_is_only_the_sorted_data_product(self):
        with tempfile.TemporaryDirectory() as td:
            source = Path(td) / "commands.md"
            source.write_text(
                "```bash\n"
                "git status\n"
                "echo ready\n"
                "```\n",
                encoding="utf-8",
            )
            with (
                mock.patch("sys.stdout", new_callable=io.StringIO) as stdout,
                mock.patch("sys.stderr", new_callable=io.StringIO) as stderr,
            ):
                rc = self.extractor.main(
                    ["extract-command-heads.py", "heads", str(source)]
                )
            self.assertEqual(0, rc)
            self.assertEqual("echo\ngit status\n", stdout.getvalue())
            self.assertEqual("", stderr.getvalue())

    def test_ungranted_strict_exit_tracks_the_emitted_finding(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            source = root / "commands.md"
            allowlist = root / "allowlist.txt"
            source.write_text(
                "```bash\nzzcmd687 --flag\n```\n",
                encoding="utf-8",
            )
            allowlist.write_text("Bash(othercmd:*)\n", encoding="utf-8")
            with (
                mock.patch("sys.stdout", new_callable=io.StringIO) as stdout,
                mock.patch("sys.stderr", new_callable=io.StringIO) as stderr,
            ):
                rc = self.extractor.main(
                    [
                        "extract-command-heads.py",
                        "ungranted",
                        "--strict",
                        str(source),
                        str(allowlist),
                    ]
                )
            self.assertEqual(3, rc)
            self.assertEqual("zzcmd687\n", stdout.getvalue())
            self.assertEqual("", stderr.getvalue())


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

    def test_raw_presence_matches_bind_to_the_exact_executable_grep(self):
        inert = (
            "DOC=\"$LIB/../docs/x.md\"\n"
            "printf '%s' '$(grep -qF -- \"fake\" \"$DOC\")'; grep --help"
        )
        self.assertEqual(
            [],
            self.mod.extract_guard_sites(
                inert, "lib/test/a.sh", repo_root="/repo"
            ),
        )

        genuine = (
            "DOC=\"$LIB/../docs/x.md\"\n"
            "printf '%s' '$(grep -qF -- \"fake\" \"$DOC\")'; "
            "grep -qF -- 'real' \"$DOC\""
        )
        sites = self.mod.extract_guard_sites(
            genuine, "lib/test/a.sh", repo_root="/repo"
        )
        self.assertEqual(1, len(sites))
        self.assertEqual("real", sites[0].literal)
        self.assertEqual("/repo/docs/x.md", sites[0].target_path)

    def test_raw_presence_after_shell_command_boundaries_is_extracted(self):
        prefixes = {
            "pipe": "true | ",
            "attached pipe-stderr": "true|&",
            "background": "true & ",
            "subshell": "( ",
        }
        for label, prefix in prefixes.items():
            with self.subTest(label=label):
                source = (
                    "DOC=\"$LIB/../docs/x.md\"\n"
                    f"{prefix}grep -qF -- 'literal' \"$DOC\""
                )
                sites = self.mod.extract_guard_sites(
                    source, "lib/test/a.sh", repo_root="/repo"
                )
                self.assertEqual(1, len(sites))
                self.assertEqual("literal", sites[0].literal)

    def test_multiple_executable_raw_presence_commands_fail_closed(self):
        separators = {
            "semicolon": "; ",
            "spaced pipe": " | ",
            "attached pipe": "|",
            "attached pipe-stderr": "|&",
        }
        for label, separator in separators.items():
            with self.subTest(label=label):
                old = (
                    "DOC=\"$LIB/../docs/x.md\"\n"
                    "grep -qF -- 'one' \"$DOC\""
                )
                source = (
                    old
                    + separator
                    + "grep -qF -- 'two' \"$DOC\""
                )
                with self.assertRaisesRegex(
                    self.mod.InfrastructureError,
                    "multiple raw presence commands",
                ):
                    self.mod.scan_changed_sources(
                        {"lib/test/a.sh": source},
                        {"lib/test/a.sh": old},
                        one_file_diff("lib/test/a.sh", old, source),
                        repo_root="/repo",
                    )

    def test_declaration_cannot_hide_a_second_raw_presence_command(self):
        old = (
            "DOC=\"$LIB/../docs/x.md\"\n"
            "grep -qF -- 'one' \"$DOC\""
        )
        source = (
            old
            + "; grep -qF -- 'two' \"$DOC\"  "
            "# structural-pin-ok: helper-contract -- first grep is executable"
        )
        with self.assertRaisesRegex(
            self.mod.InfrastructureError,
            "multiple raw presence commands",
        ):
            self.mod.scan_changed_sources(
                {"lib/test/a.sh": source},
                {"lib/test/a.sh": old},
                one_file_diff("lib/test/a.sh", old, source),
                repo_root="/repo",
            )

    def test_assignment_change_preserves_identical_raw_occurrences(self):
        calls = (
            "grep -qF -- 'literal' \"$DOC\"; "
            "grep -qF -- 'literal' \"$DOC\""
        )
        old = "DOC=\"$LIB/../docs/old.md\"\n" + calls
        source = "DOC=\"$LIB/../docs/new.md\"\n" + calls
        diff = (
            "diff --git a/lib/test/a.sh b/lib/test/a.sh\n"
            "--- a/lib/test/a.sh\n"
            "+++ b/lib/test/a.sh\n"
            "@@ -1 +1 @@\n"
            "-DOC=\"$LIB/../docs/old.md\"\n"
            "+DOC=\"$LIB/../docs/new.md\"\n"
        )
        findings = self.mod.scan_changed_sources(
            {"lib/test/a.sh": source},
            {"lib/test/a.sh": old},
            diff,
            repo_root="/repo",
        )
        self.assertEqual(2, len(findings))
        self.assertTrue(
            all("missing structural declaration" in item for item in findings)
        )

    def test_quoted_escaped_and_argument_grep_words_are_not_executable(self):
        source = (
            "DOC=\"$LIB/../docs/x.md\"\n"
            "printf '%s' 'grep -qF -- \"one\" \"$DOC\"' "
            "'grep -qF -- \"two\" \"$DOC\"'; "
            "\\grep -qF -- 'escaped' \"$DOC\"; "
            "printf '%s' grep -qF -- 'argument' \"$DOC\""
        )
        self.assertEqual(
            [],
            self.mod.extract_guard_sites(
                source, "lib/test/a.sh", repo_root="/repo"
            ),
        )

    def test_command_substitution_looking_grep_in_comment_is_inert(self):
        source = (
            "DOC=\"$LIB/../docs/x.md\"\n"
            "printf x # $(grep -qF -- 'fake' \"$DOC\")"
        )
        self.assertEqual(
            [],
            self.mod.extract_guard_sites(
                source, "lib/test/a.sh", repo_root="/repo"
            ),
        )
        self.assertEqual(
            [],
            self.mod.scan_changed_sources(
                {"lib/test/a.sh": source},
                {"lib/test/a.sh": ""},
                one_file_diff("lib/test/a.sh", "", source),
                repo_root="/repo",
            ),
        )

    def test_runtime_pipe_count_absence_and_temp_greps_are_not_raw_presence_pins(self):
        source = "\n".join(
            [
                "assert_eq \"runtime\" \"yes\" \"$(printf x | grep -qF x && echo yes || echo no)\"",
                "assert_eq \"count\" \"1\" \"$(grep -cF x \"$DOC\")\"",
                "assert_eq \"absence\" \"no\" \"$(grep -qF x \"$DOC\" && echo yes || echo no)\"",
                "assert_eq \"temp\" \"yes\" \"$(grep -qF x \"$TMP_FILE\" && echo yes || echo no)\"",
                # A scratch DIR plus a relative capture name is the ordinary way to
                # write a runtime haystack; it is the same carve-out as the bare var.
                "assert_eq \"temp dir\" \"yes\" \"$(grep -qF x \"$TMP_MI/edit-args\" && echo yes || echo no)\"",
                "assert_eq \"temp braced\" \"yes\" \"$(grep -qF x \"${TEMP_D}/args\" && echo yes || echo no)\"",
            ]
        )
        sites = self.mod.extract_guard_sites(source, "lib/test/a.sh", repo_root="/repo")
        self.assertEqual([], [site for site in sites if site.family == "raw-presence"])

    def test_a_temp_named_var_that_resolves_into_the_repo_stays_in_scope(self):
        # The carve-out is for UNRESOLVABLE runtime scratch only. A `TMP_`-named var
        # that actually resolves to repository source is a source-presence pin and
        # must not be exempted by its name.
        source = "\n".join(
            [
                'TMP_DOC="$LIB/../docs/x.md"',
                "assert_eq \"named temp\" \"yes\" \"$(grep -qF x \"$TMP_DOC\" && echo yes || echo no)\"",
                "assert_eq \"inline temp\" \"yes\" \"$(grep -qF x \"$TMP_DOC/y\" && echo yes || echo no)\"",
            ]
        )
        sites = self.mod.extract_guard_sites(source, "lib/test/a.sh", repo_root="/repo")
        self.assertEqual(
            2, len([site for site in sites if site.family == "raw-presence"])
        )

    def test_moves_are_reclassified_under_the_current_site_policy(self):
        marker = "# structural-pin-ok: helper-contract -- the helper name is invoked"
        prefix = "F=\"$LIB/../docs/x.md\"\n"
        legacy = prefix + "assert_pin_unique \"legacy\" 'L' \"$F\""
        typed = prefix + f"assert_pin_unique \"typed\" 'T' \"$F\"  {marker}"
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            target = root / "docs/x.md"
            target.parent.mkdir(parents=True)
            target.write_text("L\nT\n", encoding="utf-8")
            findings = self.mod.scan_changed_sources(
                {"lib/test/new.sh": legacy},
                {"lib/test/old.sh": legacy},
                one_file_diff("lib/test/old.sh", legacy, "")
                + one_file_diff("lib/test/new.sh", "", legacy),
                repo_root=root,
            )
            self.assertEqual(1, len(findings))
            self.assertIn("missing structural declaration", findings[0])

            findings = self.mod.scan_changed_sources(
                {"lib/test/new.sh": typed},
                {"lib/test/old.sh": typed},
                one_file_diff("lib/test/old.sh", typed, "")
                + one_file_diff("lib/test/new.sh", "", typed),
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

    def test_invalid_declaration_fails_after_a_move(self):
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

    def test_untyped_move_to_a_changed_target_surface_fails(self):
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

    def test_untyped_reformat_is_reclassified_and_no_move_matcher_remains(self):
        old = (
            'F="$LIB/../docs/x.md"\n'
            "assert_pin_unique \"legacy\" 'TOKEN' \"$F\""
        )
        new = (
            'F="$LIB/../docs/x.md"\n'
            "assert_pin_unique \\\n"
            "  \"legacy\" \\\n"
            "  'TOKEN' \\\n"
            "  \"$F\""
        )
        findings = self.mod.scan_changed_sources(
            {"lib/test/a.sh": new},
            {"lib/test/a.sh": old},
            one_file_diff("lib/test/a.sh", old, new),
            repo_root="/repo",
        )
        self.assertEqual(1, len(findings))
        self.assertIn("missing structural declaration", findings[0])
        self.assertFalse(hasattr(self.mod, "_move_class"))
        self.assertFalse(hasattr(self.mod, "_move_compatible"))

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

    def _static_registry(self):
        return {
            "schema_version": 1,
            "test_modules": {
                path.removeprefix("lib/test/modules/").removesuffix(".sh"): {
                    "path": path,
                    "minimum_assertions": 1,
                }
                for path in self.mod.AUDITED_PIN_SOURCES
                if path != "lib/test/run.sh"
            },
        }

    def _static_worktree_fixture(
        self,
        root,
        registry=None,
        calls=None,
        *,
        local_main_rc=1,
        merge_base="mergebase\n",
        python_tracked=(),
        python_untracked=(),
        show_rc=0,
    ):
        """Build a git_runner stub for ``scan_static_pin_changes``.

        The ``lib/test/test_*.py`` glob reads are answered from
        ``python_tracked``/``python_untracked`` and are kept distinct from the
        audited-source reads that share the same ``ls-files`` subcommand, so a
        test can drive the two populations independently.
        """
        for path in self.mod.AUDITED_PIN_SOURCES:
            target = root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("", encoding="utf-8")
        adjudication_text = (
            REPO_ROOT / "lib/test/pin-corpus-adjudications.tsv"
        ).read_text(encoding="utf-8")
        adjudications = root / "lib/test/pin-corpus-adjudications.tsv"
        adjudications.parent.mkdir(parents=True, exist_ok=True)
        adjudications.write_text(adjudication_text, encoding="utf-8")
        retirement_manifests = {}
        for path in self.mod._RETIREMENT_MANIFEST_SPECS:
            payload = (REPO_ROOT / path).read_bytes()
            retirement_manifests[path] = payload
            target = root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(payload)
        for path in tuple(python_tracked) + tuple(python_untracked):
            target = root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("", encoding="utf-8")
        registry_path = root / "scripts/workflow-flight-recorder-registry.json"
        registry_path.parent.mkdir(parents=True, exist_ok=True)
        registry_path.write_text(
            json.dumps(registry or self._static_registry()),
            encoding="utf-8",
        )
        audited = "\n".join(sorted(self.mod.AUDITED_PIN_SOURCES)) + "\n"
        python_glob = "lib/test/test_*.py"

        def _lines(paths):
            return "".join(f"{path}\n" for path in sorted(paths))

        def _tree_rows(paths):
            return "".join(
                f"100644 blob object\t{path}\0" for path in sorted(paths)
            )

        def runner(args, **_kwargs):
            rendered = " ".join(args)
            if calls is not None:
                calls.append(rendered)
            if "show-ref --verify --quiet refs/heads/main" in rendered:
                return subprocess.CompletedProcess(args, local_main_rc, "", "")
            if "merge-base --is-ancestor" in rendered:
                return subprocess.CompletedProcess(args, 0, "", "")
            if "merge-base origin/main HEAD" in rendered:
                return subprocess.CompletedProcess(args, 0, merge_base, "")
            if "rev-parse HEAD" in rendered:
                return subprocess.CompletedProcess(args, 0, "head\n", "")
            if "ls-tree -r -z head" in rendered:
                return subprocess.CompletedProcess(
                    args,
                    0,
                    _tree_rows(set(self.mod.AUDITED_PIN_SOURCES) | set(python_tracked)),
                    "",
                )
            if "ls-tree -r -z mergebase" in rendered:
                return subprocess.CompletedProcess(
                    args,
                    0,
                    _tree_rows(set(self.mod.AUDITED_PIN_SOURCES) | set(python_tracked)),
                    "",
                )
            if python_glob in rendered:
                population = (
                    python_untracked
                    if "ls-files --others" in rendered
                    else python_tracked
                )
                return subprocess.CompletedProcess(args, 0, _lines(population), "")
            if "ls-files --cached" in rendered or "ls-tree -r" in rendered:
                return subprocess.CompletedProcess(args, 0, audited, "")
            if (
                "ls-tree HEAD -- lib/test/pin-corpus-adjudications.tsv"
                in rendered
            ):
                return subprocess.CompletedProcess(
                    args,
                    0,
                    "100644 blob object\t"
                    "lib/test/pin-corpus-adjudications.tsv\n",
                    "",
                )
            for path, payload in retirement_manifests.items():
                if f"ls-tree mergebase -- {path}" in rendered:
                    return subprocess.CompletedProcess(
                        args, 0, f"100644 blob object\t{path}\n", ""
                    )
                if f"ls-tree HEAD -- {path}" in rendered:
                    return subprocess.CompletedProcess(
                        args, 0, f"100644 blob object\t{path}\n", ""
                    )
                if (
                    f"show mergebase:{path}" in rendered
                    or f"show HEAD:{path}" in rendered
                ):
                    return subprocess.CompletedProcess(args, 0, payload, b"")
            if "show HEAD:lib/test/pin-corpus-adjudications.tsv" in rendered:
                return subprocess.CompletedProcess(
                    args, 0, adjudication_text.encode("utf-8"), b""
                )
            if (
                "show mergebase:lib/test/pin-corpus-adjudications.tsv"
                in rendered
            ):
                return subprocess.CompletedProcess(
                    args, 0, adjudication_text.encode("utf-8"), b""
                )
            if "show mergebase:" in rendered:
                return subprocess.CompletedProcess(args, show_rc, "", "injected")
            return subprocess.CompletedProcess(args, 0, "", "")

        return runner

    def test_static_worktree_git_and_population_failures_are_infrastructure(self):
        commands = (
            "rev-parse --verify origin/main",
            "merge-base --is-ancestor",
            "merge-base origin/main HEAD",
            "diff --no-color",
            "diff --cached",
            "ls-files --others",
            "ls-tree -r",
        )
        for failed_command in commands:
            with self.subTest(command=failed_command):

                def runner(args, **_kwargs):
                    rendered = " ".join(args)
                    rc = 1 if failed_command in rendered else 0
                    stdout = (
                        "mergebase\n"
                        if "merge-base origin/main HEAD" in rendered
                        else ""
                    )
                    return subprocess.CompletedProcess(args, rc, stdout, "injected")

                with self.assertRaises(self.mod.InfrastructureError):
                    self.mod.scan_static_pin_changes(
                        "/repo",
                        git_runner=runner,
                    )

        def broken_local_main(args, **_kwargs):
            rendered = " ".join(args)
            if "refs/heads/main" in rendered:
                return subprocess.CompletedProcess(args, 2, "", "injected")
            return subprocess.CompletedProcess(args, 0, "base\n", "")

        with self.assertRaisesRegex(
            self.mod.InfrastructureError,
            "local main resolution failed",
        ):
            self.mod.scan_static_pin_changes(
                "/repo",
                git_runner=broken_local_main,
            )

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            registry = self._static_registry()
            registry["test_modules"].pop(next(iter(registry["test_modules"])))
            with self.assertRaisesRegex(
                self.mod.InfrastructureError,
                "stale audited pin source absent from registry",
            ):
                self.mod.scan_static_pin_changes(
                    root,
                    git_runner=self._static_worktree_fixture(root, registry),
                )

    def _public_static_failure(self, runner):
        def static_only(repo_root, base_ref="origin/main", **_kwargs):
            return self.mod.scan_static_pin_changes(
                repo_root,
                base_ref,
                git_runner=runner,
            )

        with (
            mock.patch.object(self.mod, "scan_worktree", side_effect=static_only),
            mock.patch("sys.stdout", new_callable=io.StringIO) as stdout,
            mock.patch("sys.stderr", new_callable=io.StringIO) as stderr,
        ):
            try:
                rc = self.mod.main(
                    ["pin-corpus-lint.py", "mutation-routing-worktree", "/repo"]
                )
            except (OSError, UnicodeDecodeError) as exc:
                self.fail(
                    "public static gate leaked "
                    f"{type(exc).__name__} instead of infrastructure exit 2: {exc}"
                )
        return rc, stdout.getvalue(), stderr.getvalue()

    def test_public_static_git_spawn_failure_is_attributed_infrastructure(self):
        def runner(args, **_kwargs):
            raise OSError("injected spawn failure")

        rc, stdout, stderr = self._public_static_failure(runner)
        self.assertEqual(2, rc)
        self.assertEqual("", stdout)
        self.assertIn("MUTATION-ROUTING-INFRASTRUCTURE", stderr)
        self.assertIn("git rev-parse --verify origin/main", stderr)
        self.assertIn("injected spawn failure", stderr)

    def test_public_static_git_decode_failure_is_attributed_infrastructure(self):
        def runner(args, **_kwargs):
            rendered = " ".join(args)
            if "show-ref --verify --quiet refs/heads/main" in rendered:
                raise UnicodeDecodeError(
                    "utf-8",
                    b"\xff",
                    0,
                    1,
                    "injected decode failure",
                )
            return subprocess.CompletedProcess(args, 0, "base\n", "")

        rc, stdout, stderr = self._public_static_failure(runner)
        self.assertEqual(2, rc)
        self.assertEqual("", stdout)
        self.assertIn("MUTATION-ROUTING-INFRASTRUCTURE", stderr)
        self.assertIn(
            "git show-ref --verify --quiet refs/heads/main",
            stderr,
        )
        self.assertIn("injected decode failure", stderr)

    def test_static_worktree_reads_merge_base_blobs_without_local_main(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            calls = []
            findings = self.mod.scan_static_pin_changes(
                root,
                git_runner=self._static_worktree_fixture(root, calls=calls),
            )
        self.assertEqual([], findings)
        self.assertTrue(
            any("merge-base origin/main HEAD" in call for call in calls),
            calls,
        )
        self.assertTrue(any("show mergebase:" in call for call in calls), calls)

    def test_static_worktree_with_local_main_present_verifies_ancestry(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            calls = []
            findings = self.mod.scan_static_pin_changes(
                root,
                git_runner=self._static_worktree_fixture(
                    root, calls=calls, local_main_rc=0
                ),
            )
        self.assertEqual([], findings)
        self.assertTrue(
            any(
                "merge-base --is-ancestor refs/heads/main origin/main" in call
                for call in calls
            ),
            calls,
        )

    def test_static_worktree_empty_merge_base_is_infrastructure(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            with self.assertRaisesRegex(
                self.mod.InfrastructureError,
                "comparison merge base resolved to empty output",
            ):
                self.mod.scan_static_pin_changes(
                    root,
                    git_runner=self._static_worktree_fixture(root, merge_base="  \n"),
                )

    def test_static_worktree_base_blob_read_failure_is_infrastructure(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            with self.assertRaisesRegex(
                self.mod.InfrastructureError,
                r"git show mergebase:.* failed \(exit 1\)",
            ):
                self.mod.scan_static_pin_changes(
                    root,
                    git_runner=self._static_worktree_fixture(root, show_rc=1),
                )

    def test_static_worktree_unreadable_pin_source_is_infrastructure(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            runner = self._static_worktree_fixture(root)
            # The fixture materialized every audited source as a file; replacing
            # one with a directory makes read_text raise IsADirectoryError, the
            # OSError arm of the pin-source read.
            victim = root / sorted(self.mod.AUDITED_PIN_SOURCES)[0]
            victim.unlink()
            victim.mkdir()
            with self.assertRaisesRegex(
                self.mod.InfrastructureError,
                "pin source unreadable: " + re.escape(sorted(self.mod.AUDITED_PIN_SOURCES)[0]),
            ):
                self.mod.scan_static_pin_changes(root, git_runner=runner)

    def test_static_worktree_reads_python_glob_populations_separately(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            calls = []
            findings = self.mod.scan_static_pin_changes(
                root,
                git_runner=self._static_worktree_fixture(
                    root,
                    calls=calls,
                    python_tracked=("lib/test/test_tracked_fixture.py",),
                    python_untracked=("lib/test/test_untracked_fixture.py",),
                ),
            )
        self.assertEqual([], findings)
        glob_calls = [call for call in calls if "lib/test/test_*.py" in call]
        self.assertEqual(1, len(glob_calls), calls)
        self.assertIn("ls-files --others", glob_calls[0])
        self.assertTrue(any("ls-tree -r -z head -- lib/test" in call for call in calls))
        # Both populations reached the scan: tracked Python leaves come from the
        # exact HEAD tree, while only the untracked population uses the glob and
        # receives a synthetic diff stanza.
        self.assertTrue(
            any("lib/test/test_tracked_fixture.py" in call for call in calls), calls
        )
        self.assertTrue(
            any("lib/test/test_untracked_fixture.py" in call for call in calls), calls
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


class AdjudicationStateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_linter()

    def test_current_adjudications_preserve_exact_valid_rows(self):
        literal = "literal:" + "a" * 64
        site = "site:" + "b" * 64
        text = (
            "adjudication_key\tbucket_final\trationale\n"
            f"{literal}\tboundary\t exact rationale \n"
            f"{site}\tconfig-key\tsecond rationale\n"
        )
        self.assertEqual(
            {
                literal: ("boundary", " exact rationale "),
                site: ("config-key", "second rationale"),
            },
            self.mod.parse_current_adjudications(text),
        )

    def test_current_adjudications_reject_noncanonical_table_rows(self):
        key = "literal:" + "a" * 64
        invalid = {
            "reordered header": (
                "bucket_final\tadjudication_key\trationale\n"
                f"boundary\t{key}\twhy\n"
            ),
            "extra cell": (
                "adjudication_key\tbucket_final\trationale\n"
                f"{key}\tboundary\twhy\textra\n"
            ),
            "invalid key grammar": (
                "adjudication_key\tbucket_final\trationale\n"
                "literal:ABC\tboundary\twhy\n"
            ),
            "unclear bucket": (
                "adjudication_key\tbucket_final\trationale\n"
                f"{key}\tunclear\twhy\n"
            ),
            "empty rationale": (
                "adjudication_key\tbucket_final\trationale\n"
                f"{key}\tboundary\t\n"
            ),
            "duplicate key": (
                "adjudication_key\tbucket_final\trationale\n"
                f"{key}\tboundary\tfirst\n{key}\tboundary\tsecond\n"
            ),
            "carriage return": (
                "adjudication_key\tbucket_final\trationale\r\n"
                f"{key}\tboundary\twhy\r\n"
            ),
            "tombstone event": (
                "adjudication_key\tbucket_final\trationale\n"
                f"tombstone:{key}\ttombstone\twhy\n"
            ),
            "supersede event": (
                "adjudication_key\tbucket_final\trationale\n"
                f"supersede:{key}\tboundary\twhy\n"
            ),
        }
        for label, text in invalid.items():
            with self.subTest(label=label):
                with self.assertRaises(self.mod.InfrastructureError):
                    self.mod.parse_current_adjudications(text)

    def test_delta_manifest_requires_exact_canonical_json_states(self):
        key = "literal:" + "a" * 64
        valid = (
            "adjudication_key\tbase_state\tcurrent_state\n"
            f'{key}\tnull\t["boundary","new rationale"]\n'
        )
        self.assertEqual(
            {key: (None, ("boundary", "new rationale"))},
            self.mod.parse_adjudication_delta_manifest(valid),
        )

        invalid = {
            "operation field": (
                "adjudication_key\tbase_state\tcurrent_state\toperation\n"
                f'{key}\tnull\t["boundary","new rationale"]\tadd\n'
            ),
            "noncompact state": (
                "adjudication_key\tbase_state\tcurrent_state\n"
                f'{key}\tnull\t["boundary", "new rationale"]\n'
            ),
            "wrong state shape": (
                "adjudication_key\tbase_state\tcurrent_state\n"
                f'{key}\tnull\t["boundary"]\n'
            ),
            "event key": (
                "adjudication_key\tbase_state\tcurrent_state\n"
                f'tombstone:{key}\tnull\t["boundary","new rationale"]\n'
            ),
        }
        for label, text in invalid.items():
            with self.subTest(label=label):
                with self.assertRaises(self.mod.InfrastructureError):
                    self.mod.parse_adjudication_delta_manifest(text)

    def test_canonical_table_hash_and_delta_capture_all_state_changes(self):
        first = "literal:" + "a" * 64
        second = "site:" + "b" * 64
        third = "literal:" + "c" * 64
        base = {
            first: ("boundary", "old rationale"),
            second: ("config-key", "deleted rationale"),
        }
        current = {
            first: ("boundary", "new rationale"),
            third: ("generated", "added rationale"),
        }
        self.assertEqual(
            (
                '[['
                '"literal:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",'
                '"boundary","old rationale"],'
                '["site:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",'
                '"config-key","deleted rationale"]]'
            ),
            self.mod.canonical_adjudication_table_state(base),
        )
        self.assertEqual(
            self.mod.hash_adjudication_table_state(base),
            self.mod.hash_adjudication_table_state(dict(reversed(list(base.items())))),
        )
        self.assertNotEqual(
            self.mod.hash_adjudication_table_state(base),
            self.mod.hash_adjudication_table_state(current),
        )
        self.assertEqual(
            {
                first: (("boundary", "old rationale"), ("boundary", "new rationale")),
                second: (("config-key", "deleted rationale"), None),
                third: (None, ("generated", "added rationale")),
            },
            self.mod.compute_adjudication_delta(base, current),
        )

    def test_delta_authorization_requires_exact_complete_current_state(self):
        key = "literal:" + "a" * 64
        changed = ("boundary", "new rationale")
        cases = {
            "addition": ({}, {key: changed}, {key: (None, changed)}),
            "deletion": ({key: changed}, {}, {key: (changed, None)}),
            "modification": (
                {key: ("boundary", "old rationale")},
                {key: changed},
                {key: (("boundary", "old rationale"), changed)},
            ),
        }
        for label, (base, current, exact) in cases.items():
            with self.subTest(change=label):
                self.assertTrue(
                    self.mod.is_exactly_authorized_adjudication_delta(base, current, [exact])
                )
                self.assertFalse(
                    self.mod.is_exactly_authorized_adjudication_delta(base, current, [])
                )

        base, current, exact = cases["modification"]
        with self.assertRaisesRegex(self.mod.InfrastructureError, "stale or extra"):
            self.mod.is_exactly_authorized_adjudication_delta(
                base,
                current,
                [{key: (("boundary", "older rationale"), ("boundary", "new rationale"))}],
            )
        with self.assertRaisesRegex(self.mod.InfrastructureError, "stale or extra"):
            self.mod.is_exactly_authorized_adjudication_delta(
                base,
                current,
                [{key: (("boundary", "old rationale"), ("boundary", "old rationale"))}],
            )
        with self.assertRaisesRegex(self.mod.InfrastructureError, "duplicate key"):
            self.mod.is_exactly_authorized_adjudication_delta(base, current, [exact, exact])
        extra_key = "site:" + "b" * 64
        with self.assertRaisesRegex(self.mod.InfrastructureError, "stale or extra"):
            self.mod.is_exactly_authorized_adjudication_delta(
                base,
                current,
                [
                    exact,
                    {extra_key: (None, ("generated", "unrelated authorization"))},
                ],
            )

    def test_current_base_ancestry_requires_the_configured_base_tip(self):
        def runner(outputs):
            def invoke(args, **kwargs):
                return subprocess.CompletedProcess(args, 0, outputs[tuple(args[3:])], "")

            return invoke

        outputs = {
            ("merge-base", "origin/main", "HEAD"): "base-tip\n",
            ("rev-parse", "origin/main"): "base-tip\n",
        }
        self.assertEqual(
            "base-tip",
            self.mod.require_current_adjudication_base(
                "/repo", "origin/main", git_runner=runner(outputs)
            ),
        )
        outputs[("merge-base", "origin/main", "HEAD")] = "older-tip\n"
        with self.assertRaisesRegex(self.mod.InfrastructureError, "not based on current"):
            self.mod.require_current_adjudication_base(
                "/repo", "origin/main", git_runner=runner(outputs)
            )

    def _bundle_manifest(self):
        key = "literal:" + "a" * 64
        return (
            "adjudication_key\tbase_state\tcurrent_state\n"
            f'{key}\tnull\t["boundary","authorized rationale"]\n'
        )

    def _commit(self, root, message):
        subprocess.run(["git", "add", "."], cwd=root, check=True)
        subprocess.run(["git", "commit", "-qm", message], cwd=root, check=True)

    def _prepared_bundle_repo(self, root):
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        subprocess.run(
            ["git", "config", "user.email", "test@example.com"], cwd=root, check=True
        )
        subprocess.run(
            ["git", "config", "user.name", "Test User"], cwd=root, check=True
        )
        historical = (
            root
            / ".devflow/logs/pin-corpus-adjudication-changes/historical/adjudication-delta.tsv"
        )
        historical.parent.mkdir(parents=True)
        historical.write_text(self._bundle_manifest(), encoding="utf-8")
        self._commit(root, "base")
        base = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=root, check=True, text=True, capture_output=True
        ).stdout.strip()
        current = (
            root
            / ".devflow/logs/pin-corpus-adjudication-changes/current/adjudication-delta.tsv"
        )
        current.parent.mkdir(parents=True)
        current.write_text(self._bundle_manifest(), encoding="utf-8")
        self._commit(root, "add current bundle")
        return base, historical, current

    def test_new_bundle_discovery_rejects_historical_changes(self):
        key = "literal:" + "a" * 64
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            base, historical, added = self._prepared_bundle_repo(root)
            self.assertEqual(
                [{key: (None, ("boundary", "authorized rationale"))}],
                self.mod.discover_new_adjudication_delta_manifests(root, base),
            )
            historical.write_text(
                self._bundle_manifest().replace("authorized", "changed"), encoding="utf-8"
            )
            self._commit(root, "alter historical bundle")
            with self.assertRaisesRegex(self.mod.InfrastructureError, "historical"):
                self.mod.discover_new_adjudication_delta_manifests(root, base)

    def test_new_bundle_discovery_rejects_unsafe_ids_and_nested_paths(self):
        def runner(diff_row):
            def invoke(args, **kwargs):
                command = tuple(args[3:])
                output = "" if command[0] in {"ls-tree", "status"} else diff_row
                return subprocess.CompletedProcess(args, 0, output, "")

            return invoke

        for label, path in (
            ("dot id", ".devflow/logs/pin-corpus-adjudication-changes/./adjudication-delta.tsv"),
            ("dotdot id", ".devflow/logs/pin-corpus-adjudication-changes/../adjudication-delta.tsv"),
        ):
            with self.subTest(case=label):
                with self.assertRaisesRegex(self.mod.InfrastructureError, "unsafe bundle ID"):
                    self.mod.discover_new_adjudication_delta_manifests(
                        "/repo", "base", git_runner=runner(f"A\t{path}\n")
                    )

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            base, _, current = self._prepared_bundle_repo(root)
            nested = current.parent / "nested" / "unexpected.tsv"
            nested.parent.mkdir()
            nested.write_text(self._bundle_manifest(), encoding="utf-8")
            self._commit(root, "add unexpected nested file")
            with self.assertRaisesRegex(self.mod.InfrastructureError, "unexpected bundle path"):
                self.mod.discover_new_adjudication_delta_manifests(root, base)

    def test_new_bundle_discovery_rejects_worktree_drift_and_head_symlinks(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "repo"
            root.mkdir()
            base, historical, current = self._prepared_bundle_repo(root)
            current.write_text(
                self._bundle_manifest().replace("authorized", "tampered"), encoding="utf-8"
            )
            with self.assertRaisesRegex(self.mod.InfrastructureError, "bundle worktree differs"):
                self.mod.discover_new_adjudication_delta_manifests(root, base)
            current.unlink()
            with self.assertRaisesRegex(self.mod.InfrastructureError, "bundle worktree differs"):
                self.mod.discover_new_adjudication_delta_manifests(root, base)
            subprocess.run(["git", "checkout", "--", str(current.relative_to(root))], cwd=root, check=True)
            historical.write_text(
                self._bundle_manifest().replace("authorized", "tampered"), encoding="utf-8"
            )
            with self.assertRaisesRegex(self.mod.InfrastructureError, "bundle worktree differs"):
                self.mod.discover_new_adjudication_delta_manifests(root, base)

        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "repo"
            root.mkdir()
            base, _, current = self._prepared_bundle_repo(root)
            current.unlink()
            external = Path(td) / "external-manifest.tsv"
            external.write_text(self._bundle_manifest(), encoding="utf-8")
            current.symlink_to(external)
            self._commit(root, "add symlinked bundle manifest")
            with self.assertRaisesRegex(self.mod.InfrastructureError, "HEAD blob"):
                self.mod.discover_new_adjudication_delta_manifests(root, base)


class AdjudicationChangeScanTests(unittest.TestCase):
    MIGRATION_PATH = (
        ".devflow/logs/pin-corpus-adjudication-changes/"
        "2026-07-26-pr-849/migration.tsv"
    )

    @classmethod
    def setUpClass(cls):
        cls.mod = load_linter()
        cls.live_table = (
            REPO_ROOT / "lib/test/pin-corpus-adjudications.tsv"
        ).read_text(encoding="utf-8")
        cls.legacy_table = subprocess.run(
            [
                "git",
                "show",
                "63585ad75031859db3b25db5432e3af3d515ba3a:"
                "lib/test/pin-corpus-adjudications.tsv",
            ],
            cwd=REPO_ROOT,
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        cls.migration_certificate = (
            REPO_ROOT / cls.MIGRATION_PATH
        ).read_text(encoding="utf-8")

    def _commit(self, root, message):
        subprocess.run(["git", "add", "."], cwd=root, check=True)
        subprocess.run(["git", "commit", "-qm", message], cwd=root, check=True)
        return subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

    def _repo(self, root, base_table):
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        subprocess.run(
            ["git", "config", "user.email", "test@example.com"],
            cwd=root,
            check=True,
        )
        subprocess.run(
            ["git", "config", "user.name", "Test User"],
            cwd=root,
            check=True,
        )
        table = root / "lib/test/pin-corpus-adjudications.tsv"
        table.parent.mkdir(parents=True)
        table.write_text(base_table, encoding="utf-8")
        base = self._commit(root, "base")
        subprocess.run(
            ["git", "update-ref", "refs/remotes/origin/main", base],
            cwd=root,
            check=True,
        )
        return base, table

    def _write_bundle(self, root, relative, text):
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def _scan(self, root, merge_base):
        return self.mod.scan_adjudication_changes(
            root, merge_base, "origin/main"
        )

    def test_former_legacy_base_is_rejected_by_strict_current_state_parser(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            base, table = self._repo(root, self.legacy_table)
            table.write_text(self.live_table, encoding="utf-8")
            self._commit(root, "replace legacy event table")
            with self.assertRaisesRegex(
                self.mod.InfrastructureError, "invalid adjudication key"
            ):
                self._scan(root, base)

    def test_new_migration_certificate_is_not_a_supported_bundle_payload(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            base, _table = self._repo(root, self.live_table)
            self._write_bundle(
                root, self.MIGRATION_PATH, self.migration_certificate
            )
            self._commit(root, "attempt a second migration")
            with self.assertRaisesRegex(
                self.mod.InfrastructureError, "unexpected bundle path"
            ):
                self._scan(root, base)

    def test_historical_migration_certificate_is_inert_but_immutable(self):
        for mutation in ("edit", "delete", "type"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as td:
                root = Path(td)
                _base, _table = self._repo(root, self.live_table)
                certificate = self._write_bundle(
                    root, self.MIGRATION_PATH, self.migration_certificate
                )
                base = self._commit(root, "record historical migration")
                subprocess.run(
                    ["git", "update-ref", "refs/remotes/origin/main", base],
                    cwd=root,
                    check=True,
                )
                self.assertEqual([], self._scan(root, base))

                if mutation == "edit":
                    certificate.write_text(
                        self.migration_certificate + "changed\n",
                        encoding="utf-8",
                    )
                else:
                    certificate.unlink()
                    if mutation == "type":
                        target = root / "historical-certificate.tsv"
                        target.write_text(
                            self.migration_certificate, encoding="utf-8"
                        )
                        certificate.symlink_to(target)
                self._commit(root, f"{mutation} historical migration")
                with self.assertRaises(self.mod.InfrastructureError):
                    self._scan(root, base)

    def test_strict_table_delta_requires_exact_authorization(self):
        key = "literal:" + "a" * 64
        base_table = (
            "adjudication_key\tbucket_final\trationale\n"
            f"{key}\tboundary\told rationale\n"
        )
        current_table = base_table.replace("old rationale", "new rationale")
        manifest = (
            "adjudication_key\tbase_state\tcurrent_state\n"
            f'{key}\t["boundary","old rationale"]\t'
            '["boundary","new rationale"]\n'
        )
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            base, table = self._repo(root, base_table)
            table.write_text(current_table, encoding="utf-8")
            self._commit(root, "unauthorized change")
            self.assertEqual(
                ["MUTATION-ROUTING\tunauthorized pin adjudication delta"],
                self._scan(root, base),
            )

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            base, table = self._repo(root, base_table)
            table.write_text(current_table, encoding="utf-8")
            self._write_bundle(
                root,
                ".devflow/logs/pin-corpus-adjudication-changes/change-1/"
                "adjudication-delta.tsv",
                manifest,
            )
            self._commit(root, "authorized change")
            self.assertEqual([], self._scan(root, base))

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            base, table = self._repo(root, base_table)
            table.write_text(current_table, encoding="utf-8")
            self._write_bundle(
                root,
                ".devflow/logs/pin-corpus-adjudication-changes/change-1/"
                "adjudication-delta.tsv",
                manifest.replace("old rationale", "older rationale"),
            )
            self._commit(root, "stale authorization")
            with self.assertRaisesRegex(self.mod.InfrastructureError, "stale or extra"):
                self._scan(root, base)

    def test_adjudication_change_rejects_a_branch_behind_the_base_tip(self):
        key = "literal:" + "a" * 64
        base_table = (
            "adjudication_key\tbucket_final\trationale\n"
            f"{key}\tboundary\told rationale\n"
        )
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            base, table = self._repo(root, base_table)
            subprocess.run(["git", "switch", "-qc", "feature"], cwd=root, check=True)
            table.write_text(
                base_table.replace("old rationale", "new rationale"),
                encoding="utf-8",
            )
            self._write_bundle(
                root,
                ".devflow/logs/pin-corpus-adjudication-changes/change-1/"
                "adjudication-delta.tsv",
                (
                    "adjudication_key\tbase_state\tcurrent_state\n"
                    f'{key}\t["boundary","old rationale"]\t'
                    '["boundary","new rationale"]\n'
                ),
            )
            feature = self._commit(root, "feature change")
            subprocess.run(["git", "switch", "--detach", base], cwd=root, check=True)
            (root / "main-advance.txt").write_text("new base tip\n", encoding="utf-8")
            main_tip = self._commit(root, "advance main")
            subprocess.run(
                ["git", "update-ref", "refs/remotes/origin/main", main_tip],
                cwd=root,
                check=True,
            )
            subprocess.run(["git", "switch", "--detach", feature], cwd=root, check=True)
            with self.assertRaisesRegex(
                self.mod.InfrastructureError, "not based on current"
            ):
                self._scan(root, base)

    def test_committed_delta_cannot_be_hidden_by_restoring_only_the_worktree(self):
        key = "literal:" + "a" * 64
        base_table = (
            "adjudication_key\tbucket_final\trationale\n"
            f"{key}\tboundary\told rationale\n"
        )
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            base, table = self._repo(root, base_table)
            table.write_text(
                base_table.replace("old rationale", "unauthorized rationale"),
                encoding="utf-8",
            )
            self._commit(root, "committed unauthorized delta")
            self.assertEqual(
                ["MUTATION-ROUTING\tunauthorized pin adjudication delta"],
                self._scan(root, base),
            )
            table.write_text(base_table, encoding="utf-8")
            with self.assertRaisesRegex(
                self.mod.InfrastructureError,
                "adjudication table worktree differs from HEAD",
            ):
                self._scan(root, base)

    def test_adjudication_change_rejects_a_committed_table_symlink(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            base, table = self._repo(root, self.live_table)
            resolved = root / "resolved.tsv"
            resolved.write_text(self.live_table, encoding="utf-8")
            table.unlink()
            table.symlink_to("../../resolved.tsv")
            self._commit(root, "symlinked adjudication table")
            with self.assertRaisesRegex(
                self.mod.InfrastructureError,
                "adjudication table is not a regular HEAD blob",
            ):
                self._scan(root, base)

    def test_clean_head_rejects_dirty_table_edits_and_deletion(self):
        for mutation in ("edit", "delete"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as td:
                root = Path(td)
                base, table = self._repo(root, self.live_table)
                self.assertEqual([], self._scan(root, base))
                if mutation == "edit":
                    table.write_text(
                        self.live_table.replace("boundary", "generated", 1),
                        encoding="utf-8",
                    )
                else:
                    table.unlink()
                with self.assertRaisesRegex(
                    self.mod.InfrastructureError,
                    "adjudication table worktree differs from HEAD",
                ):
                    self._scan(root, base)


class RetiredPinRevivalTests(unittest.TestCase):
    LITERAL = "MACHINE SENTINEL"
    RATIONALE = "the fenced token is consumed as a machine sentinel"
    MARKER = (
        "# structural-pin-ok: machine-sentinel-provenance -- "
        + RATIONALE
    )
    SOURCE = (
        'F="$LIB/../docs/x.md"\n'
        "assert_pin_unique \"sentinel\" 'MACHINE SENTINEL' \"$F\"  "
        + MARKER
        + "\n"
    )

    @classmethod
    def setUpClass(cls):
        cls.mod = load_linter()
        cls.literal_key = (
            "literal:" + hashlib.sha256(cls.LITERAL.encode("utf-8")).hexdigest()
        )

    def _commit(self, root, message):
        subprocess.run(["git", "add", "."], cwd=root, check=True)
        subprocess.run(["git", "commit", "-qm", message], cwd=root, check=True)
        return subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

    def _write_retirement_manifests(self, root):
        manifests = {
            ".devflow/logs/residual-prose-retirement-manifest.tsv": (
                "source_file\thelper\tassertion_name\tliteral\tresolved_target\t"
                "target_defaulted\tsurface\tdisposition\trationale\n"
                '"lib/test/old.sh"\tassert_pin_unique\t"old"\t'
                f'"""{self.LITERAL}"""\t"docs/x.md"\tfalse\tReview\t'
                "RETIRE_PROSE\tretired prose\n"
            ),
            ".devflow/logs/residual-required-copy-retirement-manifest.tsv": (
                "source_file\thelper\tassertion_name\tliteral\tresolved_target\t"
                "target_defaulted\tdisposition\trationale\n"
                '"lib/test/kept.sh"\tassert_pin_unique\t"kept"\t'
                '"""NOT RETIRED"""\t"docs/x.md"\tfalse\tRETAIN_BOUNDARY\tkept\n'
            ),
            ".devflow/logs/red-on-removal-retirement-manifest.tsv": (
                "source_file\thelper\tassertion_name\tliteral\tresolved_target\t"
                "target_defaulted\tdisposition\tcall_sha256\n"
                '"lib/test/converted.sh"\tassert_pin_red_on_removal\t"converted"\t'
                '"""NOT RETIRED EITHER"""\t"docs/x.md"\tfalse\tconvert_presence\t-\n'
            ),
        }
        for relative, text in manifests.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")

    def _repo(self, root, *, base_source="", active_adjudication=True):
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        subprocess.run(
            ["git", "config", "user.email", "test@example.com"],
            cwd=root,
            check=True,
        )
        subprocess.run(
            ["git", "config", "user.name", "Test User"],
            cwd=root,
            check=True,
        )
        self._write_retirement_manifests(root)
        target = root / "docs/x.md"
        target.parent.mkdir(parents=True)
        target.write_text("```text\nMACHINE SENTINEL\n```\n", encoding="utf-8")
        source = root / "lib/test/old.sh"
        source.parent.mkdir(parents=True)
        source.write_text(base_source, encoding="utf-8")
        table = root / "lib/test/pin-corpus-adjudications.tsv"
        table.write_text(
            "adjudication_key\tbucket_final\trationale\n"
            + (
                f"{self.literal_key}\tboundary\tlegacy rationale\n"
                if active_adjudication
                else ""
            ),
            encoding="utf-8",
        )
        base = self._commit(root, "base")
        subprocess.run(
            ["git", "update-ref", "refs/remotes/origin/main", base],
            cwd=root,
            check=True,
        )
        subprocess.run(["git", "switch", "-qc", "topic"], cwd=root, check=True)
        return base, table

    def _write_authorization_bundle(
        self,
        root,
        *,
        include_delta=True,
        include_revival=True,
        duplicate_revival=False,
        added_adjudication=False,
        authorization_family="static-helper",
        authorization_helper="assert_pin_unique",
    ):
        bundle = (
            root
            / ".devflow/logs/pin-corpus-adjudication-changes/revive-machine-sentinel"
        )
        bundle.mkdir(parents=True, exist_ok=True)
        if include_delta:
            base_state = (
                "null"
                if added_adjudication
                else '["boundary","legacy rationale"]'
            )
            (bundle / "adjudication-delta.tsv").write_text(
                "adjudication_key\tbase_state\tcurrent_state\n"
                f"{self.literal_key}\t{base_state}\t"
                '["boundary","deliberate machine-boundary revival"]\n',
                encoding="utf-8",
            )
        if include_revival:
            row = (
                f"lib/test/new.sh\t{authorization_family}\t{authorization_helper}\t"
                f"{self.literal_key}\tdocs/x.md\tmachine-sentinel-provenance\t"
                f"{self.RATIONALE}\n"
            )
            (bundle / "retired-pin-revivals.tsv").write_text(
                "source_path\tfamily\thelper\tliteral_key\ttarget_path\t"
                "structural_category\tstructural_rationale\n"
                + row
                + (row if duplicate_revival else ""),
                encoding="utf-8",
            )

    def _scan_sources(self, root, base, analysis):
        diff = subprocess.run(
            ["git", "diff", "--no-color", "--unified=0", base, "HEAD", "--", "lib/test"],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        current = {}
        base_sources = {}
        for relative in ("lib/test/old.sh", "lib/test/new.sh"):
            path = root / relative
            if path.exists():
                current[relative] = path.read_text(encoding="utf-8")
            result = subprocess.run(
                ["git", "show", f"{base}:{relative}"],
                cwd=root,
                check=False,
                capture_output=True,
                text=True,
            )
            if result.returncode == 0:
                base_sources[relative] = result.stdout
        return self.mod.scan_changed_sources(
            current,
            base_sources,
            diff,
            root,
            retired_literal_keys=self.mod.load_retired_wording_literal_keys(
                root, base
            ),
            revival_authorizations=analysis.revival_authorizations,
            adjudication_delta=analysis.delta,
            current_adjudications=analysis.current,
        )

    def _commit_revival(
        self,
        root,
        table,
        *,
        source=None,
        delta=False,
        revival=False,
        duplicate_revival=False,
        added_adjudication=False,
        authorization_family="static-helper",
        authorization_helper="assert_pin_unique",
    ):
        if source is None:
            source = self.SOURCE
        new_source = root / "lib/test/new.sh"
        new_source.write_text(source, encoding="utf-8")
        if delta:
            table.write_text(
                "adjudication_key\tbucket_final\trationale\n"
                f"{self.literal_key}\tboundary\tdeliberate machine-boundary revival\n",
                encoding="utf-8",
            )
        if delta or revival:
            self._write_authorization_bundle(
                root,
                include_delta=delta,
                include_revival=revival,
                duplicate_revival=duplicate_revival,
                added_adjudication=added_adjudication,
                authorization_family=authorization_family,
                authorization_helper=authorization_helper,
            )
        self._commit(root, "revive")

    def _analysis(self, root, base):
        return self.mod.analyze_adjudication_changes(
            root, base, "origin/main"
        )

    def test_retired_literal_requires_both_authorizations_not_just_a_marker(self):
        cases = (
            ("marker only", False, False),
            ("adjudication only", True, False),
        )
        for label, delta, revival in cases:
            with self.subTest(case=label), tempfile.TemporaryDirectory() as td:
                root = Path(td)
                base, table = self._repo(root)
                self._commit_revival(
                    root, table, delta=delta, revival=revival
                )
                analysis = self._analysis(root, base)
                findings = self._scan_sources(root, base, analysis)
                self.assertEqual(1, len(findings))
                self.assertIn("retired wording-pin", findings[0])

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            base, table = self._repo(root, active_adjudication=False)
            self._commit_revival(root, table)
            analysis = self._analysis(root, base)
            findings = self._scan_sources(root, base, analysis)
            self.assertEqual(1, len(findings))
            self.assertIn("same-branch boundary adjudication", findings[0])

    def test_copied_and_moved_retired_literals_are_revival_candidates(self):
        for operation in ("copy", "move"):
            with self.subTest(operation=operation), tempfile.TemporaryDirectory() as td:
                root = Path(td)
                base, table = self._repo(root, base_source=self.SOURCE)
                if operation == "move":
                    (root / "lib/test/old.sh").write_text("", encoding="utf-8")
                self._commit_revival(root, table)
                analysis = self._analysis(root, base)
                findings = self._scan_sources(root, base, analysis)
                self.assertEqual(1, len(findings))
                self.assertIn("retired wording-pin", findings[0])

    def test_exact_authorized_genuine_machine_boundary_passes(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            base, table = self._repo(root)
            self._commit_revival(root, table, delta=True, revival=True)
            analysis = self._analysis(root, base)
            self.assertEqual([], analysis.findings)
            self.assertEqual([], self._scan_sources(root, base, analysis))
            (root / "unrelated.txt").write_text("worktree-only edit\n", encoding="utf-8")
            self.assertEqual([], self._scan_sources(root, base, analysis))

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            base, table = self._repo(root, active_adjudication=False)
            self._commit_revival(
                root,
                table,
                delta=True,
                revival=True,
                added_adjudication=True,
            )
            analysis = self._analysis(root, base)
            self.assertEqual([], self._scan_sources(root, base, analysis))

    def test_duplicate_or_unconsumed_revival_authorization_fails_closed(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            base, table = self._repo(root)
            self._commit_revival(
                root,
                table,
                delta=True,
                revival=True,
                duplicate_revival=True,
            )
            with self.assertRaisesRegex(
                self.mod.InfrastructureError, "duplicate revival"
            ):
                self._analysis(root, base)

        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            base, table = self._repo(root)
            self._commit_revival(root, table, delta=True, revival=True)
            analysis = self._analysis(root, base)
            with self.assertRaisesRegex(
                self.mod.InfrastructureError, "unconsumed revival"
            ):
                self.mod.scan_changed_sources(
                    {},
                    {},
                    "",
                    root,
                    retired_literal_keys=self.mod.load_retired_wording_literal_keys(
                        root, base
                    ),
                    revival_authorizations=analysis.revival_authorizations,
                    adjudication_delta=analysis.delta,
                    current_adjudications=analysis.current,
                )

    def test_duplicate_normalized_revival_sites_fail_closed_as_ambiguous(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            base, table = self._repo(root)
            self._commit_revival(
                root,
                table,
                source=self.SOURCE + self.SOURCE,
                delta=True,
                revival=True,
            )
            analysis = self._analysis(root, base)
            with self.assertRaisesRegex(
                self.mod.InfrastructureError, "revival site is ambiguous"
            ):
                self._scan_sources(root, base, analysis)

    def test_historical_retirement_manifests_are_immutable_regular_blobs(self):
        mutations = ("committed edit", "dirty edit", "symlink")
        relative = ".devflow/logs/residual-prose-retirement-manifest.tsv"
        for mutation in mutations:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as td:
                root = Path(td)
                base, _table = self._repo(root)
                path = root / relative
                if mutation == "committed edit":
                    path.write_text(
                        path.read_text(encoding="utf-8") + "# changed\n",
                        encoding="utf-8",
                    )
                    self._commit(root, mutation)
                elif mutation == "dirty edit":
                    path.write_text(
                        path.read_text(encoding="utf-8") + "# dirty\n",
                        encoding="utf-8",
                    )
                else:
                    external = root / "external.tsv"
                    external.write_text(path.read_text(encoding="utf-8"), encoding="utf-8")
                    path.unlink()
                    path.symlink_to(external)
                with self.assertRaises(self.mod.InfrastructureError):
                    self.mod.load_retired_wording_literal_keys(root, base)

    def test_convert_presence_is_not_a_retired_wording_disposition(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            base, _table = self._repo(root)
            retired = self.mod.load_retired_wording_literal_keys(root, base)
            converted = (
                "literal:"
                + hashlib.sha256("NOT RETIRED EITHER".encode("utf-8")).hexdigest()
            )
            self.assertNotIn(converted, retired)

    def test_count_helpers_cannot_bypass_retired_literal_policy(self):
        for helper in ("pin_count", "devflow_module_pin_count"):
            source = (
                'F="$LIB/../docs/x.md"\n'
                f"{helper} 'MACHINE SENTINEL' \"$F\"  {self.MARKER}\n"
            )
            with self.subTest(helper=helper), tempfile.TemporaryDirectory() as td:
                root = Path(td)
                base, table = self._repo(root)
                self._commit_revival(root, table, source=source)
                analysis = self._analysis(root, base)
                findings = self._scan_sources(root, base, analysis)
                self.assertEqual(1, len(findings))
                self.assertIn("retired wording-pin", findings[0])

    def test_count_helper_exact_authorized_structural_revival_passes(self):
        source = (
            'F="$LIB/../docs/x.md"\n'
            f"pin_count 'MACHINE SENTINEL' \"$F\"  {self.MARKER}\n"
        )
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            base, table = self._repo(root)
            self._commit_revival(
                root,
                table,
                source=source,
                delta=True,
                revival=True,
                authorization_family="count-helper",
                authorization_helper="pin_count",
            )
            analysis = self._analysis(root, base)
            self.assertEqual([], self._scan_sources(root, base, analysis))


class StaticPinWorktreeCompositionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_linter()

    def _repo(self, root):
        for relative in (
            *sorted(self.mod.AUDITED_PIN_SOURCES),
            "lib/test/module-harness.sh",
            "lib/test/pin-corpus-lint.py",
            "lib/test/test_pin_corpus_lint.py",
            "lib/test/pin-corpus-adjudications.tsv",
            ".devflow/logs/residual-prose-retirement-manifest.tsv",
            ".devflow/logs/residual-required-copy-retirement-manifest.tsv",
            ".devflow/logs/red-on-removal-retirement-manifest.tsv",
            ".devflow/logs/mutation-pin-corpus-inventory.tsv",
            "scripts/workflow-flight-recorder-registry.json",
        ):
            source = REPO_ROOT / relative
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        fixture = root / "lib/test/static-pin-fixture.sh"
        fixture.write_text("STATIC_PIN_FIXTURE=1\n", encoding="utf-8")
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        subprocess.run(
            ["git", "config", "user.email", "test@example.com"],
            cwd=root,
            check=True,
        )
        subprocess.run(
            ["git", "config", "user.name", "Test"],
            cwd=root,
            check=True,
        )
        subprocess.run(["git", "add", "."], cwd=root, check=True)
        subprocess.run(["git", "commit", "-qm", "base"], cwd=root, check=True)
        subprocess.run(
            ["git", "update-ref", "refs/remotes/origin/main", "HEAD"],
            cwd=root,
            check=True,
        )

    def _public_rc(self, root):
        with (
            mock.patch("sys.stdout", new_callable=io.StringIO) as stdout,
            mock.patch("sys.stderr", new_callable=io.StringIO) as stderr,
        ):
            rc = self.mod.main(
                ["pin-corpus-lint.py", "mutation-routing-worktree", str(root)]
            )
        return rc, stdout.getvalue(), stderr.getvalue()

    def test_undeclared_static_pin_is_a_public_worktree_policy_failure(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            self._repo(root)
            source = root / "lib/test/run.sh"
            source.write_text(
                source.read_text(encoding="utf-8")
                + "\nassert_pin_unique 'new static pin' 'STATIC_PIN_FIXTURE=1' "
                + "\"$LIB/test/static-pin-fixture.sh\"\n",
                encoding="utf-8",
            )
            rc, stdout, stderr = self._public_rc(root)
        self.assertEqual(3, rc, stderr)
        self.assertIn("MUTATION-ROUTING", stdout)

    def test_typed_static_boundary_passes_public_worktree_policy(self):
        marker = (
            "# structural-pin-ok: machine-sentinel-provenance -- "
            "the fixture token is consumed as an executable sentinel"
        )
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            self._repo(root)
            source = root / "lib/test/run.sh"
            source.write_text(
                source.read_text(encoding="utf-8")
                + "\nassert_pin_unique 'typed static pin' 'STATIC_PIN_FIXTURE=1' "
                + f"\"$LIB/test/static-pin-fixture.sh\"  {marker}\n",
                encoding="utf-8",
            )
            self.assertEqual((0, "", ""), self._public_rc(root))

    def test_unrelated_edit_passes_public_worktree_policy(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            self._repo(root)
            source = root / "lib/test/run.sh"
            source.write_text(
                source.read_text(encoding="utf-8") + "\n# unrelated fixture edit\n",
                encoding="utf-8",
            )
            self.assertEqual((0, "", ""), self._public_rc(root))

    def _audited_source_added_after_base(self, root, relative):
        """Rewind ``origin/main`` past ``relative`` so HEAD adds it, as a branch would."""
        (root / relative).unlink()
        subprocess.run(["git", "add", "-A"], cwd=root, check=True)
        subprocess.run(["git", "commit", "-qm", "base without module"], cwd=root, check=True)
        subprocess.run(
            ["git", "update-ref", "refs/remotes/origin/main", "HEAD"],
            cwd=root,
            check=True,
        )
        # Commit the registration on a BRANCH, not on main: the gate requires local
        # main to be an ancestor of origin/main, which is the real branch shape.
        subprocess.run(["git", "checkout", "-q", "-b", "feature"], cwd=root, check=True)
        shutil.copy2(REPO_ROOT / relative, root / relative)
        subprocess.run(["git", "add", "-A"], cwd=root, check=True)
        subprocess.run(["git", "commit", "-qm", "register module"], cwd=root, check=True)

    def test_audited_source_registered_after_the_merge_base_passes(self):
        # A branch that registers a new focused module adds the module file and its
        # AUDITED_PIN_SOURCES entry in the same change, so the path is absent from the
        # base tree by construction. Requiring it there failed the gate closed on the
        # one shape the census exists to admit.
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            self._repo(root)
            self._audited_source_added_after_base(
                root, "lib/test/modules/experiment-records.sh"
            )
            self.assertEqual((0, "", ""), self._public_rc(root))

    def test_audited_source_absent_from_head_is_an_infrastructure_failure(self):
        # The HEAD arm still fails closed: an audited path the committed tree does not
        # carry leaves its pins unscanned, which is what the census exists to prevent.
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            self._repo(root)
            subprocess.run(["git", "checkout", "-q", "-b", "feature"], cwd=root, check=True)
            (root / "lib/test/modules/experiment-records.sh").unlink()
            subprocess.run(["git", "add", "-A"], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "drop module"], cwd=root, check=True)
            rc, stdout, stderr = self._public_rc(root)
        self.assertEqual(2, rc, stderr)
        self.assertIn("lib/test/modules/experiment-records.sh", stdout + stderr)

    def test_retired_helper_remains_a_public_worktree_policy_failure(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            self._repo(root)
            source = root / "lib/test/run.sh"
            source.write_text(
                source.read_text(encoding="utf-8")
                + "\nassert_pin_red_under new retired helper call\n",
                encoding="utf-8",
            )
            rc, stdout, stderr = self._public_rc(root)
        self.assertEqual(3, rc, stderr)
        self.assertIn("MUTATION-ROUTING", stdout)

    def test_public_worktree_scans_tracked_and_untracked_python_tests(self):
        source = (
            "\nclass StaticPinFixtureTest(unittest.TestCase):\n"
            "    def test_wording(self):\n"
            "        self.assertIn(\n"
            "            'STATIC_PIN_FIXTURE=1',\n"
            "            Path('lib/test/static-pin-fixture.sh').read_text(),\n"
            "        )\n"
        )
        for state in ("tracked", "untracked"):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as td:
                root = Path(td)
                self._repo(root)
                if state == "tracked":
                    path = root / "lib/test/test_pin_corpus_lint.py"
                    path.write_text(
                        path.read_text(encoding="utf-8") + source,
                        encoding="utf-8",
                    )
                else:
                    path = root / "lib/test/test_static_pin_fixture.py"
                    path.write_text(
                        "from pathlib import Path\n"
                        "import unittest\n"
                        + source,
                        encoding="utf-8",
                    )
                rc, stdout, stderr = self._public_rc(root)
                self.assertEqual(3, rc, stderr)
                self.assertIn("MUTATION-ROUTING", stdout)

    def test_committed_head_pin_cannot_be_hidden_by_worktree_restore(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            self._repo(root)
            subprocess.run(["git", "switch", "-qc", "topic"], cwd=root, check=True)
            source = root / "lib/test/run.sh"
            source.write_text(
                source.read_text(encoding="utf-8")
                + "\nassert_pin_unique 'hidden committed pin' "
                + "'STATIC_PIN_FIXTURE=1' \"$LIB/test/static-pin-fixture.sh\"\n",
                encoding="utf-8",
            )
            subprocess.run(["git", "add", str(source)], cwd=root, check=True)
            subprocess.run(
                ["git", "commit", "-qm", "commit undeclared pin"],
                cwd=root,
                check=True,
            )
            subprocess.run(
                [
                    "git",
                    "restore",
                    "--worktree",
                    "--source=origin/main",
                    "lib/test/run.sh",
                ],
                cwd=root,
                check=True,
            )
            rc, stdout, stderr = self._public_rc(root)
        self.assertEqual(3, rc, stderr)
        self.assertIn("STATIC_PIN_FIXTURE=1", stdout)
        self.assertIn("missing structural declaration", stdout)

    def test_staged_pin_cannot_be_hidden_by_worktree_restore(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            self._repo(root)
            source = root / "lib/test/run.sh"
            source.write_text(
                source.read_text(encoding="utf-8")
                + "\nassert_pin_unique 'hidden staged pin' "
                + "'STATIC_PIN_FIXTURE=1' \"$LIB/test/static-pin-fixture.sh\"\n",
                encoding="utf-8",
            )
            subprocess.run(["git", "add", str(source)], cwd=root, check=True)
            subprocess.run(
                [
                    "git",
                    "restore",
                    "--worktree",
                    "--source=HEAD",
                    "lib/test/run.sh",
                ],
                cwd=root,
                check=True,
            )
            rc, stdout, stderr = self._public_rc(root)
        self.assertEqual(2, rc)
        self.assertEqual("", stdout)
        self.assertIn("index differs from HEAD", stderr)

    def test_scanned_source_symlinks_fail_closed(self):
        cases = (
            "audited worktree",
            "audited HEAD",
            "untracked Python",
            "symlinked parent",
        )
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as td:
                root = Path(td) / "repo"
                root.mkdir()
                self._repo(root)
                external = Path(td) / "external.txt"
                external.write_text("# harmless external target\n", encoding="utf-8")
                if case == "symlinked parent":
                    test_dir = root / "lib/test"
                    real_dir = root / "lib/test-real"
                    test_dir.rename(real_dir)
                    test_dir.symlink_to(real_dir.name)
                    with self.assertRaisesRegex(
                        self.mod.InfrastructureError,
                        "symlinked worktree parent",
                    ):
                        self.mod._read_worktree_source(
                            root,
                            "lib/test/run.sh",
                            "100755",
                        )
                elif case.startswith("audited"):
                    source = root / "lib/test/run.sh"
                    source.unlink()
                    source.symlink_to(external)
                    if case.endswith("HEAD"):
                        subprocess.run(
                            ["git", "switch", "-qc", "topic"],
                            cwd=root,
                            check=True,
                        )
                        subprocess.run(["git", "add", str(source)], cwd=root, check=True)
                        subprocess.run(
                            ["git", "commit", "-qm", "symlink audited source"],
                            cwd=root,
                            check=True,
                        )
                else:
                    source = root / "lib/test/test_symlink_leaf.py"
                    source.symlink_to(external)
                rc, stdout, stderr = self._public_rc(root)
                self.assertEqual(2, rc)
                self.assertEqual("", stdout)
                self.assertIn("MUTATION-ROUTING-INFRASTRUCTURE", stderr)

    def test_multiple_direct_helpers_on_one_logical_line_fail_closed(self):
        marker = (
            "# structural-pin-ok: machine-sentinel-provenance -- "
            "the fixture token is an executable sentinel"
        )
        joiners = (" ; ", " && ", " | ", " |& ", " & ", ";", "|", "|&", "&")
        for joiner in joiners:
            with self.subTest(joiner=joiner), tempfile.TemporaryDirectory() as td:
                root = Path(td)
                self._repo(root)
                source = root / "lib/test/run.sh"
                source.write_text(
                    source.read_text(encoding="utf-8")
                    + "\nassert_pin_unique 'typed first' 'STATIC_PIN_FIXTURE=1' "
                    + f"\"$LIB/test/static-pin-fixture.sh\"{joiner}"
                    + "assert_pin_unique 'undeclared second' 'STATIC_PIN_FIXTURE=1' "
                    + f"\"$LIB/test/static-pin-fixture.sh\" {marker}\n",
                    encoding="utf-8",
                )
                rc, stdout, stderr = self._public_rc(root)
                self.assertEqual(2, rc)
                self.assertEqual("", stdout)
                self.assertIn("multiple supported helper calls", stderr)

    def test_pipe_background_and_subshell_rhs_helpers_are_scanned(self):
        leaders = (": | ", ":|", ": |& ", ":|&", ": & ", ":&", "( ", "(")
        for leader in leaders:
            with self.subTest(leader=leader), tempfile.TemporaryDirectory() as td:
                root = Path(td)
                self._repo(root)
                source = root / "lib/test/run.sh"
                suffix = " )" if leader.startswith("(") else ""
                source.write_text(
                    source.read_text(encoding="utf-8")
                    + f"\n{leader}assert_pin_unique 'operator-prefixed pin' "
                    + "'STATIC_PIN_FIXTURE=1' "
                    + f"\"$LIB/test/static-pin-fixture.sh\"{suffix}\n",
                    encoding="utf-8",
                )
                rc, stdout, stderr = self._public_rc(root)
                self.assertEqual(3, rc, stderr)
                self.assertIn("STATIC_PIN_FIXTURE=1", stdout)

    def test_quoted_and_escaped_operator_suffixes_are_not_command_boundaries(self):
        values = (
            "'|'",
            "'|&'",
            "'&'",
            "';'",
            "'not|'",
            "'not|&'",
            "'not&'",
            "'not;'",
            r"\|",
            r"\&",
            r"\;",
        )
        for value in values:
            with self.subTest(value=value), tempfile.TemporaryDirectory() as td:
                root = Path(td)
                self._repo(root)
                source = root / "lib/test/run.sh"
                source.write_text(
                    source.read_text(encoding="utf-8")
                    + f"\nprintf '%s\\n' {value} assert_pin_unique "
                    + "'argument only' 'STATIC_PIN_FIXTURE=1' "
                    + "\"$LIB/test/static-pin-fixture.sh\"\n",
                    encoding="utf-8",
                )
                rc, stdout, stderr = self._public_rc(root)
                self.assertEqual(0, rc, stderr)
                self.assertEqual("", stdout)

    def test_command_prefixed_direct_helper_is_not_skipped(self):
        for prefix in ("command", "command --", "command -p"):
            with self.subTest(prefix=prefix), tempfile.TemporaryDirectory() as td:
                root = Path(td)
                self._repo(root)
                source = root / "lib/test/run.sh"
                source.write_text(
                    source.read_text(encoding="utf-8")
                    + f"\n{prefix} assert_pin_unique 'command-prefixed pin' "
                    + "'STATIC_PIN_FIXTURE=1' \"$LIB/test/static-pin-fixture.sh\"\n",
                    encoding="utf-8",
                )
                rc, stdout, stderr = self._public_rc(root)
                self.assertEqual(3, rc, stderr)
                self.assertIn("STATIC_PIN_FIXTURE=1", stdout)

        for lookup in ("command -v", "command -V", "echo command"):
            with self.subTest(lookup=lookup), tempfile.TemporaryDirectory() as td:
                root = Path(td)
                self._repo(root)
                source = root / "lib/test/run.sh"
                source.write_text(
                    source.read_text(encoding="utf-8")
                    + f"\n{lookup} assert_pin_unique\n",
                    encoding="utf-8",
                )
                self.assertEqual((0, "", ""), self._public_rc(root))

    def test_time_prefixed_direct_helper_is_not_skipped(self):
        for prefix in (
            "time",
            "time -p",
            "PIN_LABEL=fixture time",
            "PIN_LABEL=fixture time -p",
            "time --",
            "time -p --",
            "X=1 time --",
            "time command",
            "time command --",
            "time -p command -p",
            "X=1 time command",
        ):
            with self.subTest(prefix=prefix), tempfile.TemporaryDirectory() as td:
                root = Path(td)
                self._repo(root)
                source = root / "lib/test/run.sh"
                source.write_text(
                    source.read_text(encoding="utf-8")
                    + f"\n{prefix} assert_pin_unique 'time-prefixed pin' "
                    + "'STATIC_PIN_FIXTURE=1' \"$LIB/test/static-pin-fixture.sh\"\n",
                    encoding="utf-8",
                )
                rc, stdout, stderr = self._public_rc(root)
                self.assertEqual(3, rc, stderr)
                self.assertIn("STATIC_PIN_FIXTURE=1", stdout)

        for mention in (
            "echo time assert_pin_unique",
            "printf '%s' time assert_pin_unique",
            "time -v assert_pin_unique",
            "time command -v assert_pin_unique",
            "time command -V assert_pin_unique",
        ):
            with self.subTest(mention=mention), tempfile.TemporaryDirectory() as td:
                root = Path(td)
                self._repo(root)
                source = root / "lib/test/run.sh"
                source.write_text(
                    source.read_text(encoding="utf-8") + f"\n{mention}\n",
                    encoding="utf-8",
                )
                self.assertEqual((0, "", ""), self._public_rc(root))

    def test_committed_prose_target_cannot_be_laundered_by_dirty_fenced_target(self):
        marker = (
            "# structural-pin-ok: machine-sentinel-provenance -- "
            "the fixture token is claimed as an executable sentinel"
        )
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            self._repo(root)
            subprocess.run(["git", "switch", "-qc", "topic"], cwd=root, check=True)
            target = root / "docs/static-pin-target.md"
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("## STATIC PIN PROSE\n", encoding="utf-8")
            source = root / "lib/test/run.sh"
            source.write_text(
                source.read_text(encoding="utf-8")
                + "\nassert_pin_unique 'committed prose target' 'STATIC PIN PROSE' "
                + f"\"$LIB/../docs/static-pin-target.md\"  {marker}\n",
                encoding="utf-8",
            )
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(
                ["git", "commit", "-qm", "commit invalid prose pin"],
                cwd=root,
                check=True,
            )

            clean_rc, clean_stdout, clean_stderr = self._public_rc(root)
            self.assertEqual(3, clean_rc, clean_stderr)
            self.assertIn("cannot exempt prose presence", clean_stdout)

            target.write_text(
                "```text\nSTATIC PIN PROSE\n```\n",
                encoding="utf-8",
            )
            dirty_rc, dirty_stdout, dirty_stderr = self._public_rc(root)
            self.assertEqual(3, dirty_rc, dirty_stderr)
            self.assertIn("cannot exempt prose presence", dirty_stdout)

    def test_authorized_retired_revival_cannot_launder_committed_prose_target(self):
        literal = "Step 3.6 fresh-context audit"
        literal_key = (
            "literal:" + hashlib.sha256(literal.encode("utf-8")).hexdigest()
        )
        rationale = "the token is claimed as an executable machine sentinel"
        marker = (
            "# structural-pin-ok: machine-sentinel-provenance -- " + rationale
        )
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            self._repo(root)
            self.assertIn(
                literal_key,
                self.mod.load_retired_wording_literal_keys(root, "HEAD"),
            )
            subprocess.run(["git", "switch", "-qc", "topic"], cwd=root, check=True)
            target = root / "docs/retired-pin-target.md"
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(f"## {literal}\n", encoding="utf-8")
            source = root / "lib/test/run.sh"
            source.write_text(
                source.read_text(encoding="utf-8")
                + f"\nassert_pin_unique 'retired prose target' '{literal}' "
                + f"\"$LIB/../docs/retired-pin-target.md\"  {marker}\n",
                encoding="utf-8",
            )
            table = root / "lib/test/pin-corpus-adjudications.tsv"
            table.write_text(
                table.read_text(encoding="utf-8")
                + f"{literal_key}\tboundary\tdeliberate machine-boundary revival\n",
                encoding="utf-8",
            )
            bundle = (
                root
                / ".devflow/logs/pin-corpus-adjudication-changes"
                / "retired-prose-snapshot-test"
            )
            bundle.mkdir(parents=True)
            (bundle / "adjudication-delta.tsv").write_text(
                "adjudication_key\tbase_state\tcurrent_state\n"
                f"{literal_key}\tnull\t"
                '["boundary","deliberate machine-boundary revival"]\n',
                encoding="utf-8",
            )
            (bundle / "retired-pin-revivals.tsv").write_text(
                "source_path\tfamily\thelper\tliteral_key\ttarget_path\t"
                "structural_category\tstructural_rationale\n"
                f"lib/test/run.sh\tstatic-helper\tassert_pin_unique\t{literal_key}\t"
                "docs/retired-pin-target.md\tmachine-sentinel-provenance\t"
                f"{rationale}\n",
                encoding="utf-8",
            )
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(
                ["git", "commit", "-qm", "authorize invalid retired revival"],
                cwd=root,
                check=True,
            )
            target.write_text(f"```text\n{literal}\n```\n", encoding="utf-8")

            rc, stdout, stderr = self._public_rc(root)
            self.assertEqual(3, rc, stderr)
            self.assertIn("cannot exempt prose presence", stdout)

    def test_worktree_target_snapshot_detects_byte_mode_and_path_races(self):
        for mutation in ("bytes", "mode", "path"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as td:
                root = Path(td)
                target = root / "docs/target.md"
                target.parent.mkdir(parents=True)
                target.write_text("TOKEN\n", encoding="utf-8")
                loader, verify = self.mod._worktree_target_loader(root)
                self.assertEqual(("TOKEN\n", None), loader(target))
                if mutation == "bytes":
                    target.write_text("CHANGED\n", encoding="utf-8")
                elif mutation == "mode":
                    target.chmod(0o755)
                else:
                    target.unlink()
                    target.write_text("TOKEN\n", encoding="utf-8")
                with self.assertRaisesRegex(
                    self.mod.InfrastructureError,
                    "changed during worktree analysis",
                ):
                    verify()

    def test_composition_preserves_subgate_order_and_infrastructure_precedence(self):
        retired = ["MUTATION-ROUTING\tretired"]
        static = ["MUTATION-ROUTING\tstatic"]
        with (
            mock.patch.object(
                self.mod,
                "scan_retired_mutation_population",
                return_value=retired,
            ),
            mock.patch.object(
                self.mod,
                "scan_static_pin_changes",
                return_value=static,
            ),
        ):
            self.assertEqual(retired + static, self.mod.scan_worktree("/repo"))

        with (
            mock.patch.object(
                self.mod,
                "scan_retired_mutation_population",
                return_value=retired,
            ),
            mock.patch.object(
                self.mod,
                "scan_static_pin_changes",
                side_effect=self.mod.InfrastructureError("static unavailable"),
            ),
        ):
            with self.assertRaisesRegex(
                self.mod.InfrastructureError,
                "static unavailable",
            ):
                self.mod.scan_worktree("/repo")

        # The retired subgate runs first, so its infrastructure failure preempts
        # the static subgate rather than being masked by it.
        with (
            mock.patch.object(
                self.mod,
                "scan_retired_mutation_population",
                side_effect=self.mod.InfrastructureError("retired unavailable"),
            ),
            mock.patch.object(
                self.mod,
                "scan_static_pin_changes",
                side_effect=self.mod.InfrastructureError("static unavailable"),
            ) as static,
        ):
            with self.assertRaisesRegex(
                self.mod.InfrastructureError,
                "retired unavailable",
            ):
                self.mod.scan_worktree("/repo")
            static.assert_not_called()

    def test_public_retired_subgate_infrastructure_failure_exits_two(self):
        with (
            mock.patch.object(
                self.mod,
                "scan_retired_mutation_population",
                side_effect=self.mod.InfrastructureError("retired census unavailable"),
            ),
            mock.patch("sys.stdout", new_callable=io.StringIO) as stdout,
            mock.patch("sys.stderr", new_callable=io.StringIO) as stderr,
        ):
            rc = self.mod.main(
                ["pin-corpus-lint.py", "mutation-routing-worktree", "/repo"]
            )
        self.assertEqual(2, rc)
        self.assertEqual("", stdout.getvalue())
        self.assertIn("MUTATION-ROUTING-INFRASTRUCTURE", stderr.getvalue())
        self.assertIn("retired census unavailable", stderr.getvalue())

    def test_pin_relocated_into_a_newly_committed_source_is_not_double_counted(self):
        """A pin source committed after the merge base appears in the real
        ``git diff`` output; it must be classified exactly once under the strict
        current-site policy rather than duplicated by a synthetic hunk."""
        pin = (
            "\nclass RelocatedFixtureTest(unittest.TestCase):\n"
            "    def test_wording(self):\n"
            "        self.assertIn(\n"
            "            'STATIC_PIN_FIXTURE=1',\n"
            "            Path('lib/test/static-pin-fixture.sh').read_text(),\n"
            "        )\n"
        )
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            self._repo(root)
            origin = root / "lib/test/test_pin_corpus_lint.py"
            origin.write_text(
                origin.read_text(encoding="utf-8") + pin, encoding="utf-8"
            )
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "add pin"], cwd=root, check=True)
            subprocess.run(
                ["git", "update-ref", "refs/remotes/origin/main", "HEAD"],
                cwd=root,
                check=True,
            )
            # Commit the relocation on a topic branch so local main stays at the
            # merge base and the ancestry precheck holds.
            subprocess.run(["git", "checkout", "-qb", "topic"], cwd=root, check=True)
            # Relocate the pin into a Python leaf committed in the same change:
            # tracked at HEAD, absent at the merge base, so it is already carried
            # by the real `git diff` output.
            origin.write_text(
                origin.read_text(encoding="utf-8").replace(pin, ""), encoding="utf-8"
            )
            (root / "lib/test/test_relocated_fixture.py").write_text(
                "from pathlib import Path\nimport unittest\n" + pin,
                encoding="utf-8",
            )
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "relocate"], cwd=root, check=True)
            rc, stdout, stderr = self._public_rc(root)
        self.assertEqual(3, rc, f"stdout={stdout!r} stderr={stderr!r}")
        self.assertEqual(1, stdout.count("MUTATION-ROUTING"))


class RetiredMutationHelperBanTests(unittest.TestCase):
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

    def test_zero_population_and_unrelated_edits_pass(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            self._repo(root)
            self.assertEqual(
                [],
                self.mod.scan_retired_mutation_population(root),
            )
            outside = root / "docs/unfrozen.md"
            outside.parent.mkdir(parents=True)
            outside.write_text("ordinary unrelated addition\n", encoding="utf-8")
            audited = root / sorted(self.mod.AUDITED_PIN_SOURCES)[0]
            audited.write_text(
                "# ordinary non-helper edit\n"
                + audited.read_text(encoding="utf-8"),
                encoding="utf-8",
            )
            self.assertEqual(
                [],
                self.mod.scan_retired_mutation_population(root),
            )

    def test_every_retired_helper_invocation_is_a_policy_finding(self):
        for helper in (
            "assert_pin_red_under",
            "devflow_module_pin_red_under",
            "assert_count_red_under",
            "_ra_conflict_red_under",
        ):
            with self.subTest(helper=helper), tempfile.TemporaryDirectory() as td:
                root = Path(td)
                self._repo(root)
                source = root / sorted(self.mod.AUDITED_PIN_SOURCES)[0]
                source.write_text(
                    source.read_text(encoding="utf-8")
                    + f"\n{helper} new retired helper call\n",
                    encoding="utf-8",
                )
                findings = self.mod.scan_retired_mutation_population(root)
                self.assertTrue(findings)
                self.assertTrue(
                    all(finding.startswith("MUTATION-ROUTING\t") for finding in findings)
                )

    def test_retired_helper_definition_or_wrapper_fails_closed(self):
        cases = (
            (
                "definition",
                "lib/test/module-harness.sh",
                "\nassert_pin_red_under() { :; }\n",
            ),
            (
                "wrapper",
                sorted(self.mod.AUDITED_PIN_SOURCES)[0],
                '\nwrap() { assert_pin_red_under "$@"; }\n',
            ),
        )
        for label, relative, addition in cases:
            with self.subTest(label=label), tempfile.TemporaryDirectory() as td:
                root = Path(td)
                self._repo(root)
                path = root / relative
                path.write_text(
                    path.read_text(encoding="utf-8") + addition,
                    encoding="utf-8",
                )
                with self.assertRaises(self.mod.InfrastructureError):
                    self.mod.scan_retired_mutation_population(root)

    def test_inventory_missing_malformed_or_nonempty_is_infrastructure(self):
        cases = ("missing", "malformed", "nonempty")
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
                else:
                    inventory.write_text(
                        inventory.read_text(encoding="utf-8")
                        + "lib/test/run.sh\tassert_pin_red_under\t"
                        '"assert_pin_red_under n l m f"\t1\t1\t'
                        + "a" * 64
                        + "\tretain_executable_boundary\tstale row\n",
                        encoding="utf-8",
                    )
                with self.assertRaises(self.mod.InfrastructureError):
                    self.mod.scan_retired_mutation_population(root)

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
                self.assertEqual(
                    [],
                    self.mod.scan_retired_mutation_population(root),
                )


if __name__ == "__main__":
    unittest.main()
