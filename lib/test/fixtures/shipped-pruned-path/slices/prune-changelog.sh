#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Fixture slice (issue #1309): prunes CHANGELOG.md — the non-path-default control. Against
# the real schema, `changelog_file`'s default is CHANGELOG.md but carries no `/`, so it
# contributes no exemption and CHANGELOG.md stays forbidden.
devflow_copy_slice() {
  local src="$1" dest="$2" stage
  : "$src"
  stage="${dest}.vendor-stage.$$"
  rm -rf "$stage/CHANGELOG.md"
}
