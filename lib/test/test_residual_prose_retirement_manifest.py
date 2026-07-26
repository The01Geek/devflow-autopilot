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
import tempfile
import unittest
from collections import Counter
from pathlib import Path


HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent
BASE_REVISION = "1d4d306bcacd4970df170faeab94e602724943b8"
MANIFEST = REPO_ROOT / ".devflow/logs/residual-prose-retirement-manifest.tsv"
# The manifest's own identity set is frozen against BASE_REVISION's committed
# inventory, so a row there can never be edited to track a rename.  A rename is
# declared here instead, and only the current-tree realization consumes it.  This
# is hand-maintained maintainer intent, not classifier output, so it lives beside
# its sibling pin-corpus-adjudications.tsv rather than under .devflow/logs/.
IDENTITY_REFRESHES = HERE / "pin-identity-refreshes.tsv"
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
REFRESH_COLUMNS = IDENTITY_COLUMNS + ("new_assertion_name", "rationale")
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


def decode_identity_row(row: dict[str, str]) -> dict[str, object]:
    """Decode the six identity cells shared by the manifest and the refresh ledger."""
    return {
        "source_file": decode_cell(row["source_file"]),
        "helper": row["helper"],
        "assertion_name": decode_cell(row["assertion_name"]),
        "literal": decode_cell(row["literal"]),
        "resolved_target": decode_cell(row["resolved_target"]),
        "target_defaulted": row["target_defaulted"] == "true",
    }


def decode_manifest_row(row: dict[str, str]) -> dict[str, object]:
    return {
        **decode_identity_row(row),
        "surface": row["surface"],
        "disposition": row["disposition"],
        "rationale": row["rationale"],
    }


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


class RefreshLedgerError(ValueError):
    """A refresh-ledger row that cannot be admitted, named by row and cause."""


def parse_identity_refreshes(raw: str) -> list[dict[str, object]]:
    """Parse the refresh ledger, naming the offending row rather than raising raw.

    The ledger is hand-maintained, so every malformed shape a maintainer can
    produce -- a short row, an unquoted cell, a wrapped continuation line -- is
    reported with its row number and column instead of surfacing as a bare
    TypeError or JSONDecodeError from deep inside the decode.
    """
    # Drop every "#" line, not only "# " ones: the header wraps its contract
    # onto indented continuation lines, and a bare "#" left in would parse as
    # a data row rather than a comment.
    table = [line for line in raw.splitlines() if not line.startswith("#")]
    reader = csv.DictReader(io.StringIO("\n".join(table)), delimiter="\t")
    fieldnames = tuple(reader.fieldnames or ())
    if fieldnames != REFRESH_COLUMNS:
        raise RefreshLedgerError(
            f"refresh ledger header is {fieldnames!r}, expected {REFRESH_COLUMNS!r}"
        )
    rows = []
    for number, row in enumerate(reader, start=1):
        if row.get(None) is not None:
            raise RefreshLedgerError(f"row {number} carries more cells than columns")
        decoded: dict[str, object] = {}
        for column in REFRESH_COLUMNS:
            cell = row[column]
            # csv.DictReader pads a short row with None. Reject that explicitly:
            # str(None) is the truthy "None", so a non-empty check downstream
            # would read an ABSENT cell as a supplied one.
            if cell is None:
                raise RefreshLedgerError(f"row {number} is missing the {column!r} cell")
            if column == "rationale":
                decoded[column] = cell
            elif column == "target_defaulted":
                decoded[column] = cell == "true"
            elif column == "helper":
                decoded[column] = cell
            else:
                try:
                    decoded[column] = decode_cell(cell)
                except json.JSONDecodeError as exc:
                    raise RefreshLedgerError(
                        f"row {number} cell {column!r} is not a JSON-encoded cell: {exc}"
                    ) from exc
        rows.append(decoded)
    return rows


def refresh_mapping_of(rows: list[dict[str, object]]) -> dict[tuple[object, ...], tuple[object, ...]]:
    """Project each declared old identity onto the identity the tree now carries."""
    mapping = {}
    for row in rows:
        refreshed = dict(row)
        refreshed["assertion_name"] = row["new_assertion_name"]
        mapping[identity(row)] = identity(refreshed)
    return mapping


def refresh_admission_error(
    rows: list[dict[str, object]],
    retained: set[tuple[object, ...]],
    current: set[tuple[object, ...]],
) -> str | None:
    """Return why these refresh rows are inadmissible, or None when they are clean.

    This is the single implementation of the admission rule: the live guard calls
    it over the shipped ledger, and the negative table drives every arm over
    synthetic rows.  A mirrored second copy would let an inverted arm here stay
    green there, which is the coupled-mirror hazard the split exists to avoid.
    """
    mapping = refresh_mapping_of(rows)
    # One row per declared old identity: a duplicate would make mapping[old]
    # resolve to the last row's new name, so an earlier row's missing target
    # would slip past the per-row liveness arm below.
    if len(rows) != len(mapping):
        return "duplicate old identity"
    # No injectivity arm: `refreshed` rewrites only assertion_name, so two rows
    # could collide on one new identity only by agreeing on all five other
    # identity cells -- and the frozen manifest carries no two RETAIN_BOUNDARY
    # rows sharing those five.  It is digest-pinned and can never grow, so that
    # collision is decidable now and absent, exactly like the chaining case
    # below.  Asserting either would be a dead arm.
    for row in rows:
        old = identity(row)
        if old not in retained:
            # Renaming an already-refreshed pin UPDATES that row's
            # new_assertion_name in place; it never adds a second row, because
            # `old` would then name an intermediate the frozen manifest lacks.
            return "old identity is not a RETAIN_BOUNDARY row"
        if not str(row["new_assertion_name"]).strip():
            return "empty new_assertion_name"
        if row["assertion_name"] == row["new_assertion_name"]:
            return "self-mapping row"
        if not str(row["rationale"]).strip():
            return "empty rationale"
        # A refresh is only ever a live rename: the old name must be gone from
        # the tree and the new one present.  A refresh whose old identity still
        # resolves is stale and would silently outlive the rename it recorded.
        if old in current:
            return "stale refresh: the old identity is still live"
        if mapping[old] not in current:
            return "refreshed identity is absent from the tree"
    # Chaining needs no arm of its own: the two liveness checks above make it
    # unreachable, because a chained hop's middle identity would have to be both
    # present in the tree (as one row's new name) and absent from it (as the
    # next row's old name).  So the mapping is always a single hop.
    return None


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


class ResidualRequiredCopyRetirementManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.classifier = load_classifier()
        cls._current_identities = None

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

    def load_identity_refreshes(self) -> list[dict[str, object]]:
        """Return the declared same-change renames of frozen retained identities."""
        return parse_identity_refreshes(IDENTITY_REFRESHES.read_text(encoding="utf-8"))

    def refresh_mapping(self) -> dict[tuple[object, ...], tuple[object, ...]]:
        """Project each declared old identity onto the identity the tree now carries."""
        return refresh_mapping_of(self.load_identity_refreshes())

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
            # Decode through the shared identity contract rather than transcribing
            # the six cells positionally, so a change to IDENTITY_COLUMNS cannot
            # desync this projection from identity()'s ordering.
            selected.add(identity(decode_identity_row(row)))
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
        # Re-extracting the sites is the expensive step here — the classifier
        # walks all of run.sh — and several tests in this class need the same
        # answer, so memoize it on the class (the sentinel is initialized in
        # setUpClass; the fill happens at the end of this method). The cache is
        # valid only while this class reads one fixed SOURCE_FILES set: the
        # sibling class's current_source_identities takes a per-call source set
        # and must not reuse this method. Hand out a frozenset so a caller
        # cannot mutate the shared answer.
        cached = getattr(type(self), "_current_identities", None)
        if cached is not None:
            return cached
        source_texts = {
            source_file: (REPO_ROOT / source_file).read_text(encoding="utf-8")
            for source_file in SOURCE_FILES
        }
        overrides = {}
        for text in source_texts.values():
            overrides.update(self.classifier.recover_override_names(text))
        identities = frozenset(
            site_identity(site)
            for source_file, text in source_texts.items()
            for site in self.classifier.extract_existence_sites(
                text, source_file, str(REPO_ROOT / "lib"), overrides
            )
        )
        type(self)._current_identities = identities
        return identities

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

    def test_identity_refreshes_are_declared_and_live(self):
        # Break caught: a refresh launders a vanished pin, or outlives its rename.
        _, rows = self.load_manifest()
        retained = {
            identity(row) for row in rows if row["disposition"] == "RETAIN_BOUNDARY"
        }
        current = self.current_source_identities()
        self.assertIsNone(
            refresh_admission_error(self.load_identity_refreshes(), retained, current),
            "the shipped refresh ledger is inadmissible",
        )

    def test_refresh_admission_rejects_every_malformed_declaration(self):
        # Break caught: an admission arm is inverted, dropped, or made vacuous.
        _, manifest = self.load_manifest()
        retained = {
            identity(row) for row in manifest if row["disposition"] == "RETAIN_BOUNDARY"
        }
        current = self.current_source_identities()
        live = self.load_identity_refreshes()
        self.assertIsNone(
            refresh_admission_error(live, retained, current),
            "the shipped ledger must itself be admissible",
        )
        base = live[0]

        def mutated(**overrides):
            row = dict(base)
            row.update(overrides)
            return [row]

        unretained = dict(base)
        unretained["literal"] = "a literal no frozen manifest row carries"
        cases = {
            "duplicate old identity": [dict(base), dict(base)],
            "old identity is not a RETAIN_BOUNDARY row": [unretained],
            "empty new_assertion_name": mutated(new_assertion_name="   "),
            "self-mapping row": mutated(new_assertion_name=base["assertion_name"]),
            "empty rationale": mutated(rationale=""),
            "refreshed identity is absent from the tree": mutated(
                new_assertion_name="a name the tree does not carry"
            ),
        }
        for expected, rows in cases.items():
            with self.subTest(case=expected):
                self.assertEqual(expected, refresh_admission_error(rows, retained, current))
        # The stale arm needs an old identity that is BOTH retained and still live,
        # so it is built from a second frozen row the tree still carries unrenamed.
        stale_source = next(
            row
            for row in manifest
            if row["disposition"] == "RETAIN_BOUNDARY" and identity(row) in current
        )
        stale = {column: stale_source[column] for column in IDENTITY_COLUMNS}
        stale["new_assertion_name"] = "a renamed form the tree does not carry"
        stale["rationale"] = "stale-refresh probe"
        self.assertEqual(
            "stale refresh: the old identity is still live",
            refresh_admission_error([stale], retained, current),
        )

    def test_refresh_ledger_parser_names_its_malformed_rows(self):
        # Break caught: a hand-edit fails with a raw decode error naming no row.
        def tsv(cells):
            # Render through csv so the JSON cells carry the same quoting the
            # real ledger has; a hand-joined row would decode differently.
            buf = io.StringIO()
            csv.writer(buf, delimiter="\t", lineterminator="").writerow(cells)
            return buf.getvalue()

        header = tsv(REFRESH_COLUMNS)
        good = tsv(
            (
                compact_json("lib/test/run.sh"),
                "assert_pin_unique",
                compact_json("old name"),
                compact_json("a literal"),
                compact_json("a target"),
                "false",
                compact_json("new name"),
                "why",
            )
        )
        self.assertEqual(1, len(parse_identity_refreshes(f"# c\n{header}\n{good}\n")))
        # A wrapped header continuation is a comment, not a data row.
        self.assertEqual(
            1, len(parse_identity_refreshes(f"# c\n#   more\n{header}\n{good}\n"))
        )
        cases = {
            "header": f"# c\n{tsv(IDENTITY_COLUMNS)}\n",
            "missing the 'rationale' cell": f"# c\n{header}\n{good.rsplit(chr(9), 1)[0]}\n",
            "more cells than columns": f"# c\n{header}\n{good}\textra\n",
            "not a JSON-encoded cell": f"# c\n{header}\n{good.replace(tsv([compact_json('a literal')]), 'a literal', 1)}\n",
        }
        for expected, text in cases.items():
            with self.subTest(case=expected):
                with self.assertRaises(RefreshLedgerError) as caught:
                    parse_identity_refreshes(text)
                self.assertIn(expected, str(caught.exception))

    def test_current_tree_realizes_the_retirement_manifest(self):
        # Break caught: a retired wording pin remains, or a retained boundary vanishes.
        _, rows = self.load_manifest()
        mapping = self.refresh_mapping()
        retired = {
            identity(row) for row in rows if row["disposition"] == "RETIRE_PROSE"
        }
        # A retained identity the ledger renames is realized under its new name.
        retained = {
            mapping.get(identity(row), identity(row))
            for row in rows
            if row["disposition"] == "RETAIN_BOUNDARY"
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


NEW_BASE_REVISION = "29f3298b0cd0bbd5efea4c01ca592041a2be92e4"
NEW_MANIFEST = REPO_ROOT / ".devflow/logs/residual-required-copy-retirement-manifest.tsv"
NEW_MANIFEST_COLUMNS = IDENTITY_COLUMNS + ("disposition", "rationale")
NEW_EXPECTED_SELECTOR_DIGEST = "d412dfc70f1830fafe8388f33d42057722999d5f34876b6cfd16a629bd6b7abb"
NEW_EXPECTED_CANONICAL_BYTES = 31254
NEW_EXPECTED_CANONICAL_SHA256 = "d412dfc70f1830fafe8388f33d42057722999d5f34876b6cfd16a629bd6b7abb"
NEW_EXPECTED_AUDIT_MAPPING_BYTES = 55610
NEW_EXPECTED_AUDIT_MAPPING_SHA256 = "30c00f2b96f79c5fe4ff64fa42d01767a46288eb0ebf1c92727259460cae1829"
NEW_EXPECTED_COUNTS = {"historical": 141, "retire_prose": 30, "retain_boundary": 111, "distinct_literals": 130, "retired_distinct_literals": 26, "retained_distinct_literals": 105}
HARNESS_INVENTORY = REPO_ROOT / "lib/test/modules/harness-python-guards.inventory.md"


class ResidualProseRetirementManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.classifier = load_classifier()

    def load_manifest(self) -> tuple[dict[str, str], list[dict[str, object]]]:
        raw = NEW_MANIFEST.read_text(encoding="utf-8")
        metadata: dict[str, str] = {}
        table = []
        for line in raw.splitlines():
            if line.startswith("# "):
                key, _, value = line[2:].partition(": ")
                metadata[key] = value
            else:
                table.append(line)
        reader = csv.DictReader(io.StringIO("\n".join(table)), delimiter="\t")
        self.assertEqual(NEW_MANIFEST_COLUMNS, tuple(reader.fieldnames or ()))
        rows = []
        for row in reader:
            rows.append(
                {
                    "source_file": decode_cell(row["source_file"]),
                    "helper": row["helper"],
                    "assertion_name": decode_cell(row["assertion_name"]),
                    "literal": decode_cell(row["literal"]),
                    "resolved_target": decode_cell(row["resolved_target"]),
                    "target_defaulted": row["target_defaulted"] == "true",
                    "disposition": row["disposition"],
                    "rationale": row["rationale"],
                }
            )
        return metadata, rows

    def selected_base_rows(self) -> tuple[set[tuple[object, ...]], bytes]:
        with tempfile.TemporaryDirectory() as temporary:
            inventory = Path(temporary) / "inventory.tsv"
            subprocess.run(
                [
                    sys.executable,
                    str(CLASSIFIER),
                    "--repo-root",
                    str(REPO_ROOT),
                    "--adjudications",
                    str(ADJUDICATIONS),
                    "--output",
                    str(inventory),
                    "--revision",
                    NEW_BASE_REVISION,
                ],
                cwd=REPO_ROOT,
                check=True,
                text=True,
                capture_output=True,
            )
            raw = inventory.read_text(encoding="utf-8")
        reader = csv.DictReader(
            (line for line in raw.splitlines() if not line.startswith("# ")),
            delimiter="\t",
        )
        rows = []
        canonical = []
        for row in reader:
            if row["bucket_final"] == "boundary":
                continue
            rows.append(
                (
                    decode_cell(row["source_file"]),
                    row["helper"],
                    decode_cell(row["assertion_name"]),
                    decode_cell(row["literal"]),
                    decode_cell(row["resolved_target"]),
                    row["target_defaulted"] == "true",
                )
            )
            canonical.append(
                "\t".join(
                    row[column]
                    for column in IDENTITY_COLUMNS
                ).encode("utf-8")
            )
        return set(rows), b"\n".join(sorted(canonical)) + b"\n"

    def test_manifest_exactly_partitions_the_frozen_selector(self):
        # Break caught: an audited required-copy or suite-internal site is omitted or reassigned.
        metadata, rows = self.load_manifest()
        base_identities, raw_canonical = self.selected_base_rows()
        self.assertEqual(NEW_BASE_REVISION, metadata["source-revision"])
        self.assertEqual(NEW_EXPECTED_SELECTOR_DIGEST, metadata["raw-selector-canonical-sha256"])
        self.assertEqual(NEW_EXPECTED_SELECTOR_DIGEST, hashlib.sha256(raw_canonical).hexdigest())
        canonical = "\n".join(sorted(canonical_identity(row) for row in rows)) + "\n"
        self.assertEqual(str(NEW_EXPECTED_CANONICAL_BYTES), metadata["canonical-bytes"])
        self.assertEqual(NEW_EXPECTED_CANONICAL_BYTES, len(canonical.encode("utf-8")))
        self.assertEqual(NEW_EXPECTED_CANONICAL_SHA256, metadata["canonical-sha256"])
        self.assertEqual(NEW_EXPECTED_CANONICAL_SHA256, hashlib.sha256(canonical.encode("utf-8")).hexdigest())
        mapping = (
            "\t".join(NEW_MANIFEST_COLUMNS)
            + "\n"
            + "\n".join(
                sorted(
                    canonical_identity(row)
                    + "\t"
                    + str(row["disposition"])
                    + "\t"
                    + str(row["rationale"])
                    for row in rows
                )
            )
            + "\n"
        )
        self.assertEqual(str(NEW_EXPECTED_AUDIT_MAPPING_BYTES), metadata["audit-mapping-bytes"])
        self.assertEqual(NEW_EXPECTED_AUDIT_MAPPING_BYTES, len(mapping.encode("utf-8")))
        self.assertEqual(NEW_EXPECTED_AUDIT_MAPPING_SHA256, metadata["audit-mapping-sha256"])
        self.assertEqual(NEW_EXPECTED_AUDIT_MAPPING_SHA256, hashlib.sha256(mapping.encode("utf-8")).hexdigest())
        self.assertEqual(NEW_EXPECTED_COUNTS["historical"], len(rows))
        self.assertEqual(NEW_EXPECTED_COUNTS["historical"], len(set(map(identity, rows))))
        self.assertEqual(base_identities, set(map(identity, rows)))
        self.assertEqual(
            {"RETIRE_PROSE": NEW_EXPECTED_COUNTS["retire_prose"], "RETAIN_BOUNDARY": NEW_EXPECTED_COUNTS["retain_boundary"]},
            Counter(row["disposition"] for row in rows),
        )
        self.assertTrue({row["disposition"] for row in rows} <= {"RETIRE_PROSE", "RETAIN_BOUNDARY"})
        for row in rows:
            if row["disposition"] == "RETAIN_BOUNDARY":
                self.assertRegex(str(row["rationale"]), r"^Retain .+ boundary:")
        self.assertEqual(NEW_EXPECTED_COUNTS["distinct_literals"], len({row["literal"] for row in rows}))
        self.assertEqual(NEW_EXPECTED_COUNTS["retired_distinct_literals"], len({row["literal"] for row in rows if row["disposition"] == "RETIRE_PROSE"}))
        self.assertEqual(NEW_EXPECTED_COUNTS["retained_distinct_literals"], len({row["literal"] for row in rows if row["disposition"] == "RETAIN_BOUNDARY"}))

    def test_every_retained_literal_has_an_explicit_non_mechanical_adjudication(self):
        # Break caught: a retained boundary falls back to required-copy classification.
        _, rows = self.load_manifest()
        adjudications = self.classifier.parse_adjudications(ADJUDICATIONS.read_text(encoding="utf-8"))
        retained = {row["literal"] for row in rows if row["disposition"] == "RETAIN_BOUNDARY"}
        self.assertEqual(NEW_EXPECTED_COUNTS["retained_distinct_literals"], len(retained))
        for literal in retained:
            key = self.classifier.literal_adjudication_key(literal)
            self.assertIn(key, adjudications, literal)
            bucket, rationale = adjudications[key]
            self.assertEqual("boundary", bucket, literal)
            self.assertTrue(rationale and not rationale.startswith("mechanical:"), literal)

    def test_adjudications_keep_the_base_table_as_an_exact_prefix(self):
        base = subprocess.run(
            ["git", "show", f"{NEW_BASE_REVISION}:lib/test/pin-corpus-adjudications.tsv"],
            cwd=REPO_ROOT, text=True, capture_output=True, check=True,
        ).stdout
        self.assertTrue(ADJUDICATIONS.read_text(encoding="utf-8").startswith(base))

    def current_source_identities(
        self, source_files: set[str]
    ) -> set[tuple[object, ...]]:
        source_texts = {
            source_file: (REPO_ROOT / source_file).read_text(encoding="utf-8")
            for source_file in source_files
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

    def test_current_tree_realizes_the_retirement_and_inventory_summary(self):
        # Break caught: a wording-only pin remains, a boundary vanishes, or summary drifts.
        _, rows = self.load_manifest()
        retired = {identity(row) for row in rows if row["disposition"] == "RETIRE_PROSE"}
        retained = {identity(row) for row in rows if row["disposition"] == "RETAIN_BOUNDARY"}
        current = self.current_source_identities(
            {str(row["source_file"]) for row in rows}
        )
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
        summary = {}
        for line in HARNESS_INVENTORY.read_text(encoding="utf-8").splitlines():
            if not line.startswith("residual_required_copy_retirement "):
                continue
            summary = dict(field.split("=", 1) for field in line.split()[1:])
        self.assertEqual(
            {
                "historical": str(len(rows)),
                "retire_prose": str(len(retired)),
                "retain_boundary": str(len(retained)),
            },
            summary,
        )

    def test_final_inventory_is_a_canonical_boundary_only_realization(self):
        inventory = REPO_ROOT / ".devflow/logs/pin-corpus-inventory.tsv"
        raw = inventory.read_text(encoding="utf-8")
        metadata = dict(
            line[2:].split(": ", 1) for line in raw.splitlines() if line.startswith("# ")
        )
        revision = metadata["revision"]
        self.assertRegex(revision, r"^[0-9a-f]{40}$")
        subprocess.run(["git", "cat-file", "-e", f"{revision}^{{commit}}"], cwd=REPO_ROOT, check=True)
        self.assertEqual(
            "python3 lib/test/pin-corpus-classifier.py --repo-root . --adjudications "
            "lib/test/pin-corpus-adjudications.tsv --output .devflow/logs/pin-corpus-inventory.tsv "
            f"--revision {revision}",
            metadata["producing-command"],
        )
        rows = list(csv.DictReader((line for line in raw.splitlines() if not line.startswith("# ")), delimiter="\t"))
        self.assertTrue(rows)
        self.assertEqual({"boundary"}, {row["bucket_final"] for row in rows})
        self.assertTrue(all(".devflow/logs/pin-corpus-inventory.tsv" not in decode_cell(row["homes"]) for row in rows))
        _, manifest = self.load_manifest()
        retired = {identity(row) for row in manifest if row["disposition"] == "RETIRE_PROSE"}
        retained = {identity(row) for row in manifest if row["disposition"] == "RETAIN_BOUNDARY"}
        observed = {
            (decode_cell(row["source_file"]), row["helper"], decode_cell(row["assertion_name"]), decode_cell(row["literal"]), decode_cell(row["resolved_target"]), row["target_defaulted"] == "true")
            for row in rows
        }
        self.assertFalse(retired & observed)
        self.assertTrue(retained <= observed)


if __name__ == "__main__":
    unittest.main()
