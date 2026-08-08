#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Fixture: every candidate loop iterates a variable reference.
DEVFLOW_WITHHELD_TIER="alpha beta"
devflow_withheld_tier_present() {
  local _wt found=""
  for _wt in $DEVFLOW_WITHHELD_TIER; do
    [ -f ".github/workflows/$_wt.yml" ] && found="$found $_wt"
  done
}
