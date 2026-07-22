#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
#
# path-portability-test.sh — AC6 of issue #702.
#
# Drives lib/normalize-path.sh's devflow_normalize_path over the
# lib/test/fixtures/path-portability/families.tsv corpus, proving the local
# portable helper-anchor form resolves for each of the four supported
# host-path families (Linux POSIX, macOS POSIX, WSL Windows-form, Git
# Bash/MSYS2 Windows-form). Complete by construction: the corpus is asserted
# to contain exactly those four families.
#
# Self-contained (invoked from lib/test/run.sh). Prints one FAIL line per
# mismatch to stderr and exits non-zero; exits 0 with no output when every
# family resolves as its row specifies. Depends only on a POSIX bash and the
# coreutils normalize-path.sh itself already requires (tr/grep/uname/dirname);
# it stubs wslpath/cygpath/uname exactly as the #247 T4* block does so the run
# is hermetic on any host.

set -u

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NORMALIZE_PATH_SH="$_SCRIPT_DIR/../normalize-path.sh"
CORPUS="$_SCRIPT_DIR/fixtures/path-portability/families.tsv"
BASH_BIN="$(command -v bash)"

FAILS=0
_fail() { printf 'FAIL: %s\n' "$1" >&2; FAILS=$((FAILS + 1)); }

[ -f "$NORMALIZE_PATH_SH" ] || { _fail "normalize-path.sh not found at $NORMALIZE_PATH_SH"; exit 1; }
[ -f "$CORPUS" ] || { _fail "family corpus not found at $CORPUS"; exit 1; }

# Symlink only the named tools into $1 so `command -v` genuinely fails for
# everything else (mirrors run.sh's _mk_restricted).
_mk_restricted() {
  local d="$1" b p; shift
  for b in "$@"; do
    p="$(command -v "$b" 2>/dev/null)"
    [ -n "$p" ] && ln -sf "$p" "$d/$b"
  done
  return 0
}

# Resolve one input base under the simulated host signal.
_resolve() {  # signal input
  local signal="$1" input="$2" sandbox="" out
  case "$signal" in
    posix)
      # POSIX-form input consults no tool and needs no sandbox; run under a
      # normal environment.
      out="$("$BASH_BIN" -c ". \"$NORMALIZE_PATH_SH\"; devflow_normalize_path \"\$1\"" _ "$input" 2>/dev/null)"
      ;;
    wsl)
      sandbox="$(mktemp -d)"
      # No wslpath/cygpath; stub uname reporting a microsoft kernel.
      printf '#!/usr/bin/env bash\necho "5.15.0-microsoft-standard-WSL2"\n' > "$sandbox/uname"
      chmod +x "$sandbox/uname"
      _mk_restricted "$sandbox" bash tr grep dirname
      out="$(env -u MSYSTEM PATH="$sandbox" "$BASH_BIN" -c ". \"$NORMALIZE_PATH_SH\"; devflow_normalize_path \"\$1\"" _ "$input" 2>/dev/null)"
      ;;
    msys2)
      sandbox="$(mktemp -d)"
      # No wslpath/cygpath; MSYSTEM set, non-microsoft uname.
      printf '#!/usr/bin/env bash\necho "generic-kernel"\n' > "$sandbox/uname"
      chmod +x "$sandbox/uname"
      _mk_restricted "$sandbox" bash tr grep dirname
      out="$(MSYSTEM=MINGW64 PATH="$sandbox" "$BASH_BIN" -c ". \"$NORMALIZE_PATH_SH\"; devflow_normalize_path \"\$1\"" _ "$input" 2>/dev/null)"
      ;;
    *)
      out=""
      ;;
  esac
  [ -n "$sandbox" ] && rm -rf "$sandbox"
  printf '%s' "$out"
}

EXPECTED_FAMILIES="gitbash-winform linux-posix macos-posix wsl-winform"
SEEN_FAMILIES=""

while IFS="$(printf '\t')" read -r family signal input expected; do
  case "$family" in ''|'#'*) continue ;; esac
  [ -n "$signal" ] && [ -n "$input" ] && [ -n "$expected" ] || { _fail "$family: malformed corpus row"; continue; }
  SEEN_FAMILIES="$SEEN_FAMILIES $family"

  got="$(_resolve "$signal" "$input")"
  if [ "$got" != "$expected" ]; then
    _fail "$family ($signal): resolved base '$got' != expected '$expected'"
    continue
  fi
  # The equality above is the join's coverage: each expected_base is the clean
  # POSIX base the local portable form appends /../../scripts/<helper> to, so a
  # base that still carried a backslash or drive letter (a normalization miss)
  # would fail here — the /../../scripts/… suffix is a fixed literal
  # normalization never touches, so a separate assertion on the joined string
  # would be tautological.
done < "$CORPUS"

# Complete-by-construction: the corpus must carry exactly the four families.
GOT_SORTED="$(printf '%s\n' $SEEN_FAMILIES | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//')"
if [ "$GOT_SORTED" != "$EXPECTED_FAMILIES" ]; then
  _fail "family set is not complete-by-construction: got '$GOT_SORTED', expected '$EXPECTED_FAMILIES'"
fi

[ "$FAILS" -eq 0 ] || exit 1
exit 0
