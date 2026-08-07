#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Fixture slice (issue #1309): prunes exactly docs/external and docs/internal — every
# target is also a docs.* default under the ext-int schema, so the exemption empties the
# forbidden set and the lint refuses (the fail-open shape one level down from the
# empty-prune-set refusal).
devflow_copy_slice() {
  local src="$1" dest="$2" stage
  : "$src"
  stage="${dest}.vendor-stage.$$"
  rm -rf "$stage/docs/external" "$stage/docs/internal"
}
