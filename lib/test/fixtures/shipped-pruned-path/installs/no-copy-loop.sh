#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Fixture: no loop names .github/workflows/$<var>.yml.
DEVFLOW_WITHHELD_TIER="alpha beta"
install_workflows() {
  for w in shipped-one shipped-two; do
    cp "$SRC/$w" "./$w"
  done
}
