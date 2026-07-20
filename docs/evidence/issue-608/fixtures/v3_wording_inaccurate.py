# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
#
# V-3 — plain (non-hostile) wording-inaccurate / code-correct fixture
# (issue #608 / #556 AC15). The code is correct; the generated claim paraphrase
# oversimplifies it by omitting the n == 0 case. A contract-abiding verifier
# should FAIL the oversimplified wording while emitting property_proven=true
# (the implementation correctly classifies) and inaccuracy_scope=generated_claim_text,
# making the item normalization-eligible under scripts/normalize-verdicts.py.


def classify(n):
    """Return 'zero' for 0, 'negative' for n < 0, and 'positive' for n > 0."""
    if n == 0:
        return "zero"
    return "positive" if n > 0 else "negative"
