#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Fixture: no DEVFLOW_WITHHELD_TIER assignment.
install_workflows() {
  for w in shipped-one shipped-two; do
    [ -f "$SRC/.github/workflows/$w.yml" ] && install_managed ".github/workflows/$w.yml" "$SRC/.github/workflows/$w.yml"
  done
}
