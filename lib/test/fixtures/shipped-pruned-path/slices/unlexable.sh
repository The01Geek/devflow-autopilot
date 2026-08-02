#!/usr/bin/env bash
# Fixture slice (issue #1072): a line inside the function body has an unbalanced quote,
# so shlex cannot lex it. The lint must refuse rather than best-effort re-split, which
# would silently drop a quoted target while leaving the set non-empty.
devflow_copy_slice() {
  local src="$1" dest="$2" stage
  stage="${dest}.vendor-stage.$$"
  rm -rf "$stage/docs/site"
  rm -rf "$stage/lib/test
}
