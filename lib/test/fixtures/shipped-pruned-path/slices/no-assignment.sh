#!/usr/bin/env bash
# Fixture slice (issue #1072): the composing assignment is absent, so the staging variable
# cannot be identified at all — the lint refuses rather than guessing a name.
devflow_copy_slice() {
  local src="$1" dest="$2"
  rm -rf "somedir/lib/test"
}
