#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Fixture: a literal-operand removal loop precedes the copy loop.
DEVFLOW_WITHHELD_TIER="alpha beta"
prune_stale() {
  for w in internal-only probe; do
    rm -f ".github/workflows/$w.yml"
  done
}
install_workflows() {
  for w in shipped-one shipped-two; do
    [ -f "$SRC/.github/workflows/$w.yml" ] && install_managed ".github/workflows/$w.yml" "$SRC/.github/workflows/$w.yml"
  done
}
