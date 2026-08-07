#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Fixture slice (issue #1309): prunes docs/external, docs/site and lib/test — the
# shape the exemption membership assertion needs (docs/external is a prune target
# AND a documented docs.* default, so the exemption removes it; docs/site and
# lib/test are not defaults and survive).
devflow_copy_slice() {
  local src="$1" dest="$2" stage
  : "$src"
  stage="${dest}.vendor-stage.$$"
  rm -rf "$stage/docs/external" "$stage/docs/site" "$stage/lib/test"
}
