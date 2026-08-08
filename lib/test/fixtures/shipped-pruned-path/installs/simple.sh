#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Fixture: the well-formed shape both install.sh declarations take. Carries the
# decoy loop over a variable BEFORE the copy loop, so a parser that keys on the
# workflow-path body reference alone selects the wrong one.
DEVFLOW_WITHHELD_TIER="alpha beta"
devflow_withheld_tier_present() {
  local _wt found=""
  for _wt in $DEVFLOW_WITHHELD_TIER; do
    [ -f ".github/workflows/$_wt.yml" ] && found="$found $_wt"
  done
  printf '%s' "${found# }"
}
install_workflows() {
  for w in shipped-one shipped-two; do
    [ -f "$SRC/.github/workflows/$w.yml" ] && install_managed ".github/workflows/$w.yml" "$SRC/.github/workflows/$w.yml"
  done
}
