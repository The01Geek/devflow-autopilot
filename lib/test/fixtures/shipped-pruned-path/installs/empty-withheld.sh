#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Fixture: DEVFLOW_WITHHELD_TIER declares no literal name.
DEVFLOW_WITHHELD_TIER=""
install_workflows() {
  for w in shipped-one shipped-two; do
    [ -f "$SRC/.github/workflows/$w.yml" ] && install_managed ".github/workflows/$w.yml" "$SRC/.github/workflows/$w.yml"
  done
}
