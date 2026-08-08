#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Fixture: two DEVFLOW_WITHHELD_TIER assignments.
DEVFLOW_WITHHELD_TIER="alpha"
DEVFLOW_WITHHELD_TIER="alpha beta"
install_workflows() {
  for w in shipped-one shipped-two; do
    [ -f "$SRC/.github/workflows/$w.yml" ] && install_managed ".github/workflows/$w.yml" "$SRC/.github/workflows/$w.yml"
  done
}
