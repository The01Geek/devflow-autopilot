#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Fixture: a copy loop whose operand list is QUOTED, so shlex yields it as one token.
# `_literal_words`' whitespace re-split is what recovers the two members; without it the
# shipped set would hold the single bogus name `shipped-one shipped-two` and both real
# names would wrongly enter the never-shipped set.
DEVFLOW_WITHHELD_TIER="alpha beta"
install_workflows() {
  for w in "shipped-one shipped-two"; do
    [ -f "$SRC/.github/workflows/$w.yml" ] && install_managed ".github/workflows/$w.yml" "$SRC/.github/workflows/$w.yml"
  done
}
