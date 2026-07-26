#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Freeze the audited residual prose-pin population before source retirement."""

from __future__ import annotations

import csv
import hashlib
import importlib.util
import io
import json
import subprocess
import sys
import unittest
from collections import Counter
from pathlib import Path


HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent
BASE_REVISION = "1d4d306bcacd4970df170faeab94e602724943b8"
MANIFEST = REPO_ROOT / ".devflow/logs/residual-prose-retirement-manifest.tsv"
ADJUDICATIONS = REPO_ROOT / "lib/test/pin-corpus-adjudications.tsv"
CLASSIFIER = HERE / "pin-corpus-classifier.py"

IDENTITY_COLUMNS = (
    "source_file",
    "helper",
    "assertion_name",
    "literal",
    "resolved_target",
    "target_defaulted",
)
MANIFEST_COLUMNS = IDENTITY_COLUMNS + ("surface", "disposition", "rationale")
MAPPING_CANONICAL_HEADER = "\t".join(MANIFEST_COLUMNS) + "\n"
RAW_SELECTOR_INDICES = (0, 2, 1, 5, 6, 7)
PROSE_BUCKETS = {"prose-sole-copy", "prose-multi-copy"}
EXPECTED_SURFACES = {
    "Review": 120,
    "Implement/Create-Issue": 119,
    "other/shared": 3,
}
EXPECTED_DISPOSITIONS = {"RETIRE_PROSE": 39, "RETAIN_BOUNDARY": 203}
# This is the independently recorded selector digest in the implementation plan.
EXPECTED_SELECTOR_DIGEST = "7505469a1b2538622d653cc225fe3571bf9c41d4d3c004011241e89b1e93bf40"
EXPECTED_AUDIT_MAPPING_DIGEST = (
    "047165133b3aa37e7c44a902f73b46ba428f00eb8b7b1468acf985a4f5489d1b"
)
SOURCE_FILES = (
    "lib/test/run.sh",
    "lib/test/modules/create-issue-contract.sh",
)


def compact_json(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def decode_cell(value: str) -> object:
    return json.loads(value)


def decode_manifest_row(row: dict[str, str]) -> dict[str, object]:
    decoded: dict[str, object] = {
        "source_file": decode_cell(row["source_file"]),
        "helper": row["helper"],
        "assertion_name": decode_cell(row["assertion_name"]),
        "literal": decode_cell(row["literal"]),
        "resolved_target": decode_cell(row["resolved_target"]),
        "target_defaulted": row["target_defaulted"] == "true",
        "surface": row["surface"],
        "disposition": row["disposition"],
        "rationale": row["rationale"],
    }
    return decoded


def identity(row: dict[str, object]) -> tuple[object, ...]:
    return tuple(row[column] for column in IDENTITY_COLUMNS)


def canonical_identity(row: dict[str, object]) -> str:
    """Keep identities independent of a source line number or audit report order."""
    cells = []
    for column in IDENTITY_COLUMNS:
        value = row[column]
        if column in {"source_file", "assertion_name", "literal", "resolved_target"}:
            cells.append(compact_json(value))
        elif column == "target_defaulted":
            cells.append("true" if value else "false")
        else:
            cells.append(str(value))
    return "\t".join(cells)


def canonical_mapping(row: dict[str, object]) -> str:
    return "\t".join(
        (
            canonical_identity(row),
            str(row["surface"]),
            str(row["disposition"]),
            str(row["rationale"]),
        )
    )


def site_identity(site: object) -> tuple[object, ...]:
    """Project a current extracted site onto the manifest identity contract."""
    return tuple(getattr(site, column) for column in IDENTITY_COLUMNS)


def canonical_tsv(header: str, lines: list[str]) -> str:
    """The newline-terminated, sorted bytes used for frozen census digests."""
    return header + "\n".join(sorted(lines)) + "\n"


def load_classifier():
    spec = importlib.util.spec_from_file_location("pin_corpus_classifier", CLASSIFIER)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class ResidualProseRetirementManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.classifier = load_classifier()

    def load_manifest(self) -> tuple[dict[str, str], list[dict[str, object]]]:
        raw = MANIFEST.read_text(encoding="utf-8")
        metadata = {}
        table = []
        for line in raw.splitlines():
            if line.startswith("# "):
                key, _, value = line[2:].partition(": ")
                metadata[key] = value
            else:
                table.append(line)
        reader = csv.DictReader(io.StringIO("\n".join(table)), delimiter="\t")
        self.assertEqual(MANIFEST_COLUMNS, tuple(reader.fieldnames or ()))
        return metadata, [decode_manifest_row(row) for row in reader]

    def selected_base_inventory(self) -> set[tuple[object, ...]]:
        result = subprocess.run(
            ["git", "show", f"{BASE_REVISION}:.devflow/logs/pin-corpus-inventory.tsv"],
            cwd=REPO_ROOT,
            text=True,
            capture_output=True,
            check=True,
        )
        reader = csv.DictReader(
            (line for line in result.stdout.splitlines() if not line.startswith("# ")),
            delimiter="\t",
        )
        selected = set()
        for row in reader:
            if row["bucket_final"] not in PROSE_BUCKETS:
                continue
            selected.add(
                (
                    decode_cell(row["source_file"]),
                    row["helper"],
                    decode_cell(row["assertion_name"]),
                    decode_cell(row["literal"]),
                    decode_cell(row["resolved_target"]),
                    row["target_defaulted"] == "true",
                )
            )
        return selected

    def selected_base_raw_canonical(self) -> bytes:
        """Return the documented raw-cell selector bytes from immutable inventory text.

        The historical digest intentionally operates on the six JSON-encoded TSV
        cells as stored by the classifier, not their decoded Python values.  Keep
        the raw field positions explicit: source, helper, assertion, literal,
        target, and target_defaulted are indexes 0, 2, 1, 5, 6, and 7.
        """
        result = subprocess.run(
            ["git", "show", f"{BASE_REVISION}:.devflow/logs/pin-corpus-inventory.tsv"],
            cwd=REPO_ROOT,
            text=True,
            capture_output=True,
            check=True,
        )
        lines: list[bytes] = []
        for raw in result.stdout.splitlines():
            if raw.startswith("#") or raw.startswith("source_file\t"):
                continue
            cells = raw.split("\t")
            if cells[15] not in PROSE_BUCKETS:
                continue
            lines.append(
                "\t".join(cells[index] for index in RAW_SELECTOR_INDICES).encode("utf-8")
            )
        # Sorting encoded records is deliberately bytewise, matching LC_ALL=C.
        return b"\n".join(sorted(lines)) + b"\n"

    def current_source_identities(self) -> set[tuple[object, ...]]:
        source_texts = {
            source_file: (REPO_ROOT / source_file).read_text(encoding="utf-8")
            for source_file in SOURCE_FILES
        }
        overrides = {}
        for text in source_texts.values():
            overrides.update(self.classifier.recover_override_names(text))
        return {
            site_identity(site)
            for source_file, text in source_texts.items()
            for site in self.classifier.extract_existence_sites(
                text, source_file, str(REPO_ROOT / "lib"), overrides
            )
        }

    def test_manifest_exactly_partitions_the_frozen_prose_selector(self):
        # Break caught: an audited site is silently omitted, duplicated, or reassigned.
        metadata, rows = self.load_manifest()
        self.assertEqual(BASE_REVISION, metadata["source-revision"])
        self.assertEqual(EXPECTED_SELECTOR_DIGEST, metadata["selector-identity-sha256"])
        self.assertEqual(242, len(rows))
        self.assertEqual(EXPECTED_SURFACES, Counter(row["surface"] for row in rows))
        self.assertEqual(EXPECTED_DISPOSITIONS, Counter(row["disposition"] for row in rows))

        identities = {identity(row) for row in rows}
        self.assertEqual(242, len(identities))
        base_identities = self.selected_base_inventory()
        self.assertEqual(base_identities, identities)
        base_raw_canonical = self.selected_base_raw_canonical()
        self.assertEqual(
            EXPECTED_SELECTOR_DIGEST,
            hashlib.sha256(base_raw_canonical).hexdigest(),
        )
        self.assertEqual(
            EXPECTED_SELECTOR_DIGEST,
            metadata["raw-selector-canonical-sha256"],
        )

        by_surface = {
            surface: {identity(row) for row in rows if row["surface"] == surface}
            for surface in EXPECTED_SURFACES
        }
        self.assertEqual(set(), by_surface["Review"] & by_surface["Implement/Create-Issue"])
        self.assertEqual(set(), by_surface["Review"] & by_surface["other/shared"])
        self.assertEqual(
            set(), by_surface["Implement/Create-Issue"] & by_surface["other/shared"]
        )
        self.assertEqual(identities, set().union(*by_surface.values()))

        canonical = "\n".join(sorted(canonical_identity(row) for row in rows)) + "\n"
        self.assertEqual(metadata["canonical-bytes"], str(len(canonical.encode("utf-8"))))
        self.assertEqual(
            metadata["canonical-sha256"],
            hashlib.sha256(canonical.encode("utf-8")).hexdigest(),
        )
        mapping_canonical = canonical_tsv(
            MAPPING_CANONICAL_HEADER, [canonical_mapping(row) for row in rows]
        )
        self.assertEqual(
            EXPECTED_AUDIT_MAPPING_DIGEST,
            hashlib.sha256(mapping_canonical.encode("utf-8")).hexdigest(),
        )
        self.assertEqual(EXPECTED_AUDIT_MAPPING_DIGEST, metadata["audit-mapping-sha256"])

    def test_every_retained_literal_has_an_explicit_non_mechanical_adjudication(self):
        # Break caught: a retained boundary falls back to a mechanical prose bucket.
        _, rows = self.load_manifest()
        adjudications = self.classifier.parse_adjudications(
            ADJUDICATIONS.read_text(encoding="utf-8")
        )
        retained = [row["literal"] for row in rows if row["disposition"] == "RETAIN_BOUNDARY"]
        self.assertEqual(203, len(retained))
        for literal in retained:
            key = self.classifier.literal_adjudication_key(literal)
            self.assertIn(key, adjudications, literal)
            bucket, rationale = adjudications[key]
            self.assertEqual("boundary", bucket, literal)
            self.assertFalse(rationale.startswith("mechanical:"), literal)

    def test_current_tree_realizes_the_retirement_manifest(self):
        # Break caught: a retired wording pin remains, or a retained boundary vanishes.
        _, rows = self.load_manifest()
        retired = {
            identity(row) for row in rows if row["disposition"] == "RETIRE_PROSE"
        }
        retained = {
            identity(row) for row in rows if row["disposition"] == "RETAIN_BOUNDARY"
        }
        current = self.current_source_identities()
        self.assertSetEqual(
            set(),
            retired & current,
            "still-live RETIRE_PROSE identities:\n"
            + "\n".join(sorted(map(repr, retired & current))),
        )
        self.assertSetEqual(
            set(),
            retained - current,
            "missing RETAIN_BOUNDARY identities:\n"
            + "\n".join(sorted(map(repr, retained - current))),
        )


if __name__ == "__main__":
    unittest.main()
