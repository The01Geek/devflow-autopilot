#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
"""Executable unit tests for scripts/normalize-verdicts.py (issue #556, T-1/T-3/T-6).

Drives the REAL helper CLI over the hand-built fixture matrix under
lib/test/fixtures/normalize-verdicts/ and asserts the parsed stored verdict,
raw_verdict/normalized fields, defect classification, needs_retry membership, and
the two counts per arm. Exits non-zero on any failure so lib/test/run.sh can gate
on it. Also drives the T-3 planted-defect positive control (a helper mutation that
drops conjunct 2 must turn the false-authored-comment arm RED)."""
import json, subprocess, sys, os
os.chdir(os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")))
H = "scripts/normalize-verdicts.py"
D = "lib/test/fixtures/normalize-verdicts"
def run(f):
    r = subprocess.run(["python3", H, os.path.join(D, f)], capture_output=True, text=True)
    return json.loads(r.stdout), r.returncode
def res0(o): return o["results"][0]
fails = []
def check(name, cond, detail=""):
    print(("PASS" if cond else "FAIL"), name, detail if not cond else "")
    if not cond: fails.append(name)

o,_ = run("norm-basic.json"); r=res0(o)
check("norm-basic normalized", r["normalized"] and r["verdict"]=="PASS" and r["raw_verdict"]=="FAIL")
check("norm-basic count", o["counts"]["normalized_count"]==1)
check("norm-basic evidence prefix", r["evidence"].startswith("NORMALIZED (wording-only): "))

o,_=run("conj1-lite-fail.json"); r=res0(o)
check("conj1 lite not normalized", not r["normalized"] and r["verdict"]=="FAIL")

o,_=run("conj2-source-authored.json"); r=res0(o)
check("conj2 source_authored not normalized", not r["normalized"] and r["verdict"]=="FAIL")
check("conj2 not field-defect-fail", o["counts"]["field_defect_fail_count"]==0)

o,_=run("conj4-string-true.json"); r=res0(o)
check("conj4 string-true not normalized", not r["normalized"] and r["verdict"]=="FAIL")
check("conj4 string-true is field-defect-fail", o["counts"]["field_defect_fail_count"]==1, str(r))

o,_=run("conj4-property-false.json"); r=res0(o)
check("conj4 false not normalized", not r["normalized"] and r["verdict"]=="FAIL")
check("conj4 false NOT field-defect-fail", o["counts"]["field_defect_fail_count"]==0)

o,_=run("conj5-scope-source.json"); r=res0(o)
check("conj5 scope-source not normalized", not r["normalized"])
check("conj5 NOT field-defect-fail", o["counts"]["field_defect_fail_count"]==0)

o,_=run("defect-missing-fence.json"); r=res0(o)
check("missing-fence defect", r["defect"]=="missing_fence" and r["defect_class"]=="verdict")
check("missing-fence needs_retry verdict", o["needs_retry"] and o["needs_retry"][0]["kind"]=="verdict")

o,_=run("tolerance-fenceless-single.json"); r=res0(o)
check("tolerance fenceless single normalized", r["normalized"], str(r))

o,_=run("defect-unparseable-json.json"); r=res0(o)
check("unparseable_json defect", r["defect"]=="unparseable_json")

o,_=run("defect-missing-verdict-field.json"); r=res0(o)
check("missing_verdict_field", r["defect"]=="missing_verdict_field")

o,_=run("defect-non-enum-verdict.json"); r=res0(o)
check("non_enum_verdict", r["defect"]=="non_enum_verdict")

o,_=run("defect-id-mismatch.json"); r=res0(o)
check("id_mismatch", r["defect"]=="id_mismatch")

o,_=run("lastfence.json"); r=res0(o)
check("lastfence uses last (FAIL->normalized)", r["raw_verdict"]=="FAIL" and r["normalized"], str(r))

o,_=run("aux-property-absent.json"); r=res0(o)
check("aux property absent -> auxiliary defect", r["defect_class"]=="auxiliary")
check("aux property absent needs_retry auxiliary", o["needs_retry"] and o["needs_retry"][0]["kind"]=="auxiliary")
check("aux property absent field-defect-fail", o["counts"]["field_defect_fail_count"]==1)

o,_=run("aux-scope-unknown.json"); r=res0(o)
check("aux scope unknown -> auxiliary defect", r["defect_class"]=="auxiliary")

o,_=run("aux-pass-no-retry.json"); r=res0(o)
check("aux PASS defect no retry", not o["needs_retry"], str(o["needs_retry"]))
check("aux PASS stays PASS", r["verdict"]=="PASS")

o,_=run("vfile-channel.json"); r=res0(o)
check("vfile reads file channel", r["source"]=="file", str(r))
check("vfile normalized from file bytes", r["normalized"] and r["file_checked"]=="b.py", str(r))

o,_=run("field-defect-fail.json"); r=res0(o)
check("field-defect-fail not normalized", not r["normalized"])
check("field-defect-fail counted", o["counts"]["field_defect_fail_count"]==1, str(r))
check("field-defect-fail retry auxiliary? no (verdict ok, provenance absent)", not o["needs_retry"], str(o["needs_retry"]))

o,_=run("pinned-verdict.json"); r=res0(o)
check("pinned raw is FAIL not response PASS", r["raw_verdict"]=="FAIL", str(r))
check("pinned stored stays FAIL (property false)", r["verdict"]=="FAIL", str(r))

o,_=run("no-verdict-channel.json"); r=res0(o)
check("no-verdict defect", r["defect"]=="no_verdict", str(r))

o,_=run("empty-pairs.json")
check("empty-pairs results empty", o.get("results")==[] and "bad_input" not in o)

o,_=run("bad-empty.json")
check("bad-empty bad_input", o.get("bad_input") is True and o["error"]=="pairs_file_empty")

o,_=run("bad-unparseable.json")
check("bad-unparseable bad_input", o.get("bad_input") is True and o["error"]=="pairs_file_unparseable")

o,_=run("bad-wrong-shape.json")
check("bad-wrong-shape bad_input", o.get("bad_input") is True and o["error"]=="pairs_file_wrong_shape")

o,_=run("bad-prose-reflection.txt")
check("prose reflection bad_input", o.get("bad_input") is True)

# AC11 — a source_authored item whose authored assertion is false keeps FAIL and
# stays normalization-ineligible (conjunct 2 fails). This isolates conjunct 2 so
# the T-3 mutation control below can prove the guard bites.
o,_=run("ac11-only-conj2.json"); r=res0(o)
check("AC11 source_authored not normalized", not r["normalized"] and r["verdict"]=="FAIL", str(r))

# T-3 planted-defect positive control: a helper mutation dropping conjunct 2 (the
# claim_provenance == generated_paraphrase check) must turn the AC11 arm RED — i.e.
# the mutant WRONGLY normalizes the source_authored item. Proves the guard, not the
# line's mere presence (recorded as mutation evidence, not attestation).
import tempfile, shutil, re as _re
_src = open("scripts/normalize-verdicts.py", encoding="utf-8").read()
_mut = _re.sub(r'if provenance != "generated_paraphrase":',
               'if False:  # T-3 mutation: drop conjunct 2', _src, count=1)
_ctrl_ok = _mut != _src
with tempfile.TemporaryDirectory() as _td:
    _mp = os.path.join(_td, "mutant.py")
    open(_mp, "w", encoding="utf-8").write(_mut)
    _r = subprocess.run(["python3", _mp, os.path.join(D, "ac11-only-conj2.json")],
                        capture_output=True, text=True)
    _mo = json.loads(_r.stdout)
    _mut_normalizes = _mo["results"][0]["normalized"] is True
check("T-3 mutation control: conjunct-2 drop applied", _ctrl_ok)
check("T-3 mutation control: mutant WRONGLY normalizes AC11 (guard bites)", _mut_normalizes, str(_mo["results"][0]))

print("\nFAILURES:", fails if fails else "NONE")
sys.exit(1 if fails else 0)
