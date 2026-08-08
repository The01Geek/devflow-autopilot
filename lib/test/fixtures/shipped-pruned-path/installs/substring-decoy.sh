#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Fixture: substring decoys. `probe` and `alpha` appear in prose below.
# rm -rf .github/workflows/probe.yml   # a comment that removes the probe tier
# log "specificity: probe coverage and alpha rollout"
DEVFLOW_WITHHELD_TIER="alpha"
install_workflows() {
  for w in shipped-one; do
    [ -f "$SRC/.github/workflows/$w.yml" ] && install_managed ".github/workflows/$w.yml" "$SRC/.github/workflows/$w.yml"
  done
}
