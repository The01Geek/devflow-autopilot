#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Fixture slice (issue #1309): prunes the BARE `docs` directory — the equality-not-prefix
# control. A schema whose only default is docs/internal/ must NOT exempt `docs` (a finer
# default exempting a coarser target would silently empty the guard), so `docs` survives.
devflow_copy_slice() {
  local src="$1" dest="$2" stage
  : "$src"
  stage="${dest}.vendor-stage.$$"
  rm -rf "$stage/docs"
}
