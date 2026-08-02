#!/usr/bin/env bash
# Fixture slice (issue #1072): the only stage-suffixed removal is keyed on the destination
# variable, not the staging variable — the destination removal is never a target.
devflow_copy_slice() {
  local src="$1" dest="$2" stage
  stage="${dest}.vendor-stage.$$"
  rm -rf "$dest/lib/test"
}
