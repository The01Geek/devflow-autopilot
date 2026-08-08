#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Fixture: a copy loop whose operand list is QUOTED, so it iterates ONE value. The
# installer would look for `.github/workflows/shipped-one shipped-two.yml`, so neither
# real name reaches a consumer and both must stay in the never-shipped set. A parser that
# re-splits the token on whitespace would drop both from that set — a fail-open.
DEVFLOW_WITHHELD_TIER="alpha beta"
install_workflows() {
  for w in "shipped-one shipped-two"; do
    [ -f "$SRC/.github/workflows/$w.yml" ] && install_managed ".github/workflows/$w.yml" "$SRC/.github/workflows/$w.yml"
  done
}
