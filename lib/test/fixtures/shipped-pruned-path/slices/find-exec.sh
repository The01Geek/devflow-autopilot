#!/usr/bin/env bash
# Fixture slice (issue #1072): the only removal is a find … -exec composite, so {} is never
# a target — the set is empty and the lint refuses.
devflow_copy_slice() {
  local src="$1" dest="$2" stage
  stage="${dest}.vendor-stage.$$"
  find "$stage" -name __pycache__ -type d -prune -exec rm -rf {} +
}
