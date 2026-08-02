#!/usr/bin/env bash
# Fixture slice (issue #1072): positive control for the comment-stripping lexer arm. A
# prose comment inside the function body carries an apostrophe, exactly as the real
# vendor-slice.sh does ("DevFlow's own test suite"). It must be stripped before lexing
# rather than read as an unbalanced quote, so the set still derives.
devflow_copy_slice() {
  local src="$1" dest="$2" stage
  stage="${dest}.vendor-stage.$$"
  # Prune the project's own test suite under lib/test (it isn't shipped to a consumer).
  rm -rf "$stage/lib/test"
}
