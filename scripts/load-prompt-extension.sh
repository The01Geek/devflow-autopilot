#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Print a consumer-owned prompt-extension file verbatim, if present.
#
# Usage: load-prompt-extension.sh SKILL_NAME [--section '<## heading>']
#   SKILL_NAME   the skill's directory name under skills/ (e.g. create-issue,
#                implement, review). This is the only POSITIONAL argument.
#   --section    optional; emit only the named section of the extension instead of
#                the whole file. Its value is the exact '## '-prefixed heading line.
#                At most one section per invocation; a repeated flag takes its LAST
#                occurrence. Omitting the flag keeps the byte-identical full-file
#                behavior every pre-existing caller depends on.
#
# The --section extraction rule (issue #611) is SPECIFIED in
# skills/create-issue/SKILL.md (Step 2's `## Evidence axes` forwarding paragraph)
# and IMPLEMENTED here; that skill sentence is the specification of record and this
# helper is its single implementation — a coupled pair, edited together. The rule:
#   * a section spans its heading line to the next line beginning '## ' (two hashes
#     PLUS A SPACE, so a '###' sub-heading line is section content, not a
#     terminator), else to end of file;
#   * duplicate same-heading sections are concatenated in file order;
#   * an empty section is equivalent to an absent heading (both emit nothing);
#   * a heading line inside an HTML comment block is never a heading;
#   * a '##' line inside a fenced code block neither starts nor terminates a
#     section, and an unclosed fence runs to end of file;
#   * trailing whitespace is stripped from both the candidate heading line and the
#     --section value before comparison, so a CRLF-authored extension and a heading
#     hand-authored with trailing spaces both still extract.
#
# Section bytes are selected and emitted with bash builtins only (read/printf/case
# parameter expansion) — never awk/sed/tr/head. The emitted section decides what a
# consumer skill sees, so under the repo's non-preflight-PATH-tool rule it must not
# be derived through a tool `lib/preflight.sh` does not guarantee: such a tool going
# missing would empty the selection silently rather than failing loudly.
#
# Two sibling '## '-heading scanners live in scripts/, and their terminator rules
# DIFFER deliberately — do not "unify" them without re-reading all three contracts:
#   * scripts/parse-acs.py `_extract_section` terminates on the next heading of the
#     SAME-OR-HIGHER level, so a '###' sub-heading DOES end its section there.
#   * scripts/workpad.py `_split_sections` splits on '## ' and matches the heading
#     name case-INsensitively.
#   * this one terminates only on '## ' (a '###' line is section content) and matches
#     the heading line EXACTLY after a trailing-whitespace strip, because it feeds
#     agent-executed prompt prose where a sub-heading is part of the section body and
#     a case-drifted heading must be reported rather than silently accepted.
#
# Reads .devflow/prompt-extensions/<SKILL_NAME>.md anchored to the git repo root
# (git rev-parse --show-toplevel, falling back to pwd when not in a git tree —
# mirroring lib/config-source.sh; issue #295) and writes it byte-for-byte to
# stdout when it exists. Anchoring to the root means a skill invoked from any
# subdirectory of the repo still loads the consumer's committed extension, instead
# of silently missing it. When the file is absent — or present but empty — this
# prints nothing and exits 0 (the no-op path), so a skill that calls this behaves
# exactly as before unless the consumer opted in. (Limitation: --show-toplevel
# returns the NEAREST git root, so a nested submodule/inner repo or a monorepo whose
# .devflow/ is not at the git root is not covered — consistent with config-source.sh.)
#
# This is DevFlow's single upgrade-safe extension point: a consumer adds
# repo-specific instructions to any skill by committing one Markdown file in
# their own repo, with no plugin edit and no fork to maintain. The file lives in
# the consumer's repo, never in the plugin, so marketplace updates never touch
# it and never conflict with it. The skill that calls this treats the printed
# text as additional instructions appended to the end of its own prompt.
#
# SKILL_NAME is validated BEFORE any filesystem access: a value that is empty or
# contains a '/' character or a '..' sequence is rejected (exit 2). This
# constrains the *name* — so the model-executed argument can never name a file
# outside .devflow/prompt-extensions/ — NOT the resolved target: a symlink the
# repo owner commits inside that directory is still followed by `cat`. That is by
# design — the directory's contents are consumer-owned trusted prose, and a
# consumer who symlinks outward is only reaching into their own repo. The argument
# is the only attacker-influenceable input (a skill could be coaxed to pass an
# unexpected value); the file's bytes are trusted.
#
# Plain POSIX-portable shell, no GNU-only flags — runs on macOS/BSD without GNU
# coreutils. `cat` reproduces the file's bytes exactly, adding or stripping no
# trailing newline beyond the file's own.
#
# Exit codes:
#   0  file printed verbatim (or the selected section), or absent/empty (no-op) —
#      including the designed no-op of an absent heading or an empty section under
#      --section, which additionally emits a stderr breadcrumb when the heading is
#      absent from a NON-empty extension (the no-op stays exit 0; the breadcrumb
#      only makes it observable, so a near-miss heading is never silent)
#   2  bad arguments (missing SKILL_NAME, a SKILL_NAME containing '/' or '..' or
#      given as a '--'-prefixed token, an unrecognized '--' argument, a --section
#      missing its value, or a --section whose value is empty after stripping), OR the named
#      extension exists but cannot be delivered as a Markdown file (unreadable, a
#      symlink whose target is missing, or not a regular file — a directory or a
#      symlink resolving to one) — refused loudly rather than left to masquerade as
#      the empty no-op the calling skill treats as "proceed unchanged", which would
#      silently drop the consumer's customization

set -euo pipefail

# Strip trailing whitespace (spaces, tabs, and a CR from a CRLF-authored file) with
# pure parameter expansion — no `tr`/`sed`. Used on both sides of the heading
# comparison, so a CRLF extension and a heading typed with trailing spaces both match.
_lpe_rstrip() {
    _lpe_rstripped="$1"
    while [ "${_lpe_rstripped%[[:space:]]}" != "$_lpe_rstripped" ]; do
        _lpe_rstripped="${_lpe_rstripped%[[:space:]]}"
    done
}

skill="${1:-}"

if [ -z "$skill" ]; then
    echo "load-prompt-extension.sh: usage: load-prompt-extension.sh SKILL_NAME [--section '<## heading>']" >&2
    exit 2
fi

# A '--'-prefixed token in the SKILL-NAME slot is a transposed invocation
# (`--section '## X' <skill>`). Refuse it loudly: without this guard the helper would
# look up a skill literally named `--section`, find no such extension, and exit 0
# printing nothing — a silent no-op indistinguishable from a consumer who genuinely
# has no extension, which is precisely the silent-drop class the guards below exist
# to close.
case "$skill" in
    --*)
        echo "load-prompt-extension.sh: SKILL_NAME must be the first argument, but got the flag '$skill' (usage: load-prompt-extension.sh SKILL_NAME [--section '<## heading>'])" >&2
        exit 2
        ;;
esac

# Parse the optional flags after the positional. A repeated --section takes its LAST
# occurrence; bare non-flag extra arguments stay ignored, preserving the pre-flag
# behavior for any caller that already passed a stray word. An unrecognized
# '--'-prefixed argument is refused rather than ignored: silently reverting to the
# full-file dump would hand a caller the entire extension where it asked for one
# section — the opposite of the context saving --section exists to provide, and
# invisible at the call site.
section=""
section_requested=0
shift || true
while [ "$#" -gt 0 ]; do
    case "$1" in
        --section)
            if [ "$#" -lt 2 ]; then
                echo "load-prompt-extension.sh: --section requires a value (the exact '## '-prefixed heading line)" >&2
                exit 2
            fi
            section="$2"
            section_requested=1
            shift 2
            ;;
        --*)
            echo "load-prompt-extension.sh: unrecognized argument '$1' (usage: load-prompt-extension.sh SKILL_NAME [--section '<## heading>'])" >&2
            exit 2
            ;;
        *)
            shift
            ;;
    esac
done

if [ "$section_requested" -eq 1 ]; then
    _lpe_rstrip "$section"
    section="$_lpe_rstripped"
    # A whitespace-only value would compare equal to no heading at all and silently
    # select nothing, reading exactly like a legitimate absent-heading no-op. Refuse it.
    if [ -z "$section" ]; then
        echo "load-prompt-extension.sh: --section value is empty after stripping trailing whitespace (expected the exact '## '-prefixed heading line)" >&2
        exit 2
    fi
fi

# Reject path-traversal vectors before touching the filesystem. '*/*' matches any
# slash; '*..*' matches any '..' sequence (covering '..', '../x', 'x/../y').
case "$skill" in
    */* | *..*)
        echo "load-prompt-extension.sh: invalid skill name '$skill' (must not contain '/' or '..')" >&2
        exit 2
        ;;
esac

# Anchor to the repo root (issue #295) so a subdirectory invocation still finds the
# consumer's extension. Mirror lib/config-source.sh's discovery expression.
# git rev-parse prints nothing and exits non-zero outside a git tree; the trailing
# `|| _devflow_root=""` keeps that assignment set -e-safe. Then fall back to cwd, with a
# breadcrumb only when NEITHER a git root NOR a .devflow/ dir can be located.
_devflow_root="$(git rev-parse --show-toplevel 2>/dev/null)" || _devflow_root=""
if [ -z "$_devflow_root" ]; then
    _devflow_root="$(pwd)"
    # git can exit non-zero while genuinely INSIDE a repo (safe.directory /
    # dubious-ownership refusal), or be absent from PATH — not only "outside a git
    # tree". Don't assert "not in a git repo"; report that the root could not be
    # resolved and surface git's own stderr (re-run on this rare path only; `|| true`
    # keeps it set -e-safe).
    if [ ! -d "${_devflow_root}/.devflow" ]; then
        _git_err="$(git rev-parse --show-toplevel 2>&1 >/dev/null)" || true
        echo "load-prompt-extension.sh: could not resolve a git repo root${_git_err:+ (git: ${_git_err})} and no .devflow/ at '${_devflow_root}'; no extension loaded" >&2
    fi
fi

ext_file="${_devflow_root}/.devflow/prompt-extensions/${skill}.md"

# Refuse every "present but undeliverable" shape loudly (exit 2 + a specific
# breadcrumb) instead of letting it fall through to the silent empty no-op the
# calling skill reads as "proceed unchanged" — that would drop the consumer
# extension. The guards below partition those shapes; an absent file (none of them
# fire) is the only path that reaches the no-op exit 0 at the very end.
#
# A symlink whose target is missing makes the `-f` test below false, so without
# this branch a committed `<skill>.md -> ../moved.md` (or a link that resolves only
# on another machine) would silently no-op and drop the consumer extension — the
# same failure class the unreadable guard below closes. Refuse it loudly too.
# (-L true AND -e false = a present-but-broken symlink; a resolvable symlink is
# -e true and is followed by design, per the header.)
if [ -L "$ext_file" ] && [ ! -e "$ext_file" ]; then
    echo "load-prompt-extension.sh: '$ext_file' is a symlink with a missing target; refusing to silently skip a consumer extension (fix or remove the link)" >&2
    exit 2
fi

# A present entry that is NOT a regular file — a directory (e.g. a fat-fingered
# `mkdir <skill>.md`), a symlink resolving to a directory, a fifo/device — also
# makes the `-f` test below false and would silently no-op, dropping the consumer
# extension (same class as the guards above). Refuse it loudly. A regular file, or
# a symlink resolving to one, is `-f` true and falls through to be read.
if [ -e "$ext_file" ] && [ ! -f "$ext_file" ]; then
    echo "load-prompt-extension.sh: '$ext_file' exists but is not a regular file; refusing to silently skip a consumer extension (expected a Markdown file)" >&2
    exit 2
fi

# By here the broken-symlink and non-regular guards above have fired on every
# undeliverable *present* shape, so the only present case reaching `-f` is a
# regular file (an absent file makes `-f` false → the no-op exit 0 at the end).
# A present-but-unreadable regular file is still refused loudly (exit 2) rather
# than letting a bare `cat` failure under `set -e` masquerade as the empty no-op
# the calling skill reads as "proceed unchanged". (Note: a process running as root
# bypasses the permission bits, so this guard only fires for an ordinary user.)
if [ -f "$ext_file" ]; then
    if [ ! -r "$ext_file" ]; then
        echo "load-prompt-extension.sh: '$ext_file' exists but is not readable; refusing to silently skip a consumer extension (fix its permissions)" >&2
        exit 2
    fi
    if [ "$section_requested" -eq 0 ]; then
        cat "$ext_file"
    else
        # One pass over the file, tracking three pieces of state: whether we are
        # inside a fenced code block, inside an HTML comment block, and inside the
        # requested section. Fence and comment state are tracked GLOBALLY (not only
        # while inside the section) because a fence opened before the heading and
        # closed after it still governs whether the lines between them are headings.
        _in_fence=0
        _in_comment=0
        _in_section=0
        _found=0
        _has_body=0
        _out=""
        _headings=""
        _partial=0
        # The `|| { [ -n "$_line" ] && _partial=1; }` clause is what makes a final
        # line with NO terminating newline survive: `read` returns non-zero on it
        # while still assigning it, so a bare `while read` silently DROPS that line.
        # The flag also records that the line was unterminated, so it is re-emitted
        # without inventing a newline the source file never had.
        while IFS= read -r _line || { [ -n "$_line" ] && _partial=1; }; do
            _is_heading=0
            if [ "$_in_fence" -eq 1 ]; then
                # Inside a fence nothing is a heading; only the closing fence matters.
                case "$_line" in '```'*) _in_fence=0 ;; esac
            elif [ "$_in_comment" -eq 1 ]; then
                # Inside a comment block nothing is a heading; only the close matters.
                case "$_line" in *'-->'*) _in_comment=0 ;; esac
            else
                case "$_line" in
                    '```'*)
                        # An unclosed fence is never reset, so it runs to end of file
                        # — the truncation shape a hand-edited extension can leave.
                        _in_fence=1
                        ;;
                    *'<!--'*)
                        # A comment that also closes on the same line leaves the block
                        # state alone; either way this line is not a heading.
                        case "$_line" in *'-->'*) : ;; *) _in_comment=1 ;; esac
                        ;;
                    '## '*)
                        # Two hashes PLUS A SPACE. '### Foo' fails this pattern (its
                        # third character is '#', not a space), so a sub-heading is
                        # section content and terminates nothing.
                        _is_heading=1
                        ;;
                esac
            fi
            if [ "$_is_heading" -eq 1 ]; then
                _lpe_rstrip "$_line"
                _headings="${_headings}${_headings:+, }${_lpe_rstripped}"
                if [ "$_lpe_rstripped" = "$section" ]; then
                    # A duplicate same-heading section re-enters rather than
                    # restarting, so the sections concatenate in file order.
                    _in_section=1
                    _found=1
                else
                    _in_section=0
                fi
            fi
            if [ "$_in_section" -eq 1 ]; then
                # One append; the unterminated final line just skips the newline the
                # source file never had.
                _out="${_out}${_line}"
                [ "$_partial" -eq 1 ] || _out="${_out}"$'\n'
                if [ "$_is_heading" -eq 0 ]; then
                    # Any non-whitespace content below a heading makes the section
                    # non-empty. Checked with a bash pattern, never `grep`/`tr`.
                    case "$_line" in *[![:space:]]*) _has_body=1 ;; esac
                fi
            fi
            [ "$_partial" -eq 1 ] && break
        done < "$ext_file"

        if [ "$_found" -eq 1 ]; then
            # Found-but-empty emits nothing and stays breadcrumb-FREE on purpose — the
            # rule's "an empty section is equivalent to an absent heading" clause. The
            # heading WAS found, so the consumer's hook is wired correctly and there is
            # nothing for a reader to fix.
            # An explicit `if`, NOT `[ … ] && printf`: under `set -e` that AND-list is
            # the last statement of this branch, so a false test would propagate a
            # non-zero status out of the script and turn the designed empty-section
            # no-op into an exit-1 failure.
            if [ "$_has_body" -eq 1 ]; then
                printf '%s' "$_out"
            fi
        else
            # The heading is absent from the extension. The no-op itself is DESIGNED (a
            # single-hook extension carrying only the other heading is the routine case,
            # and it must not fail), so this stays exit 0 — but a silent no-op is
            # indistinguishable from a heading the consumer typo'd, so name what was
            # asked for and what is actually there. Only headings the extractor
            # genuinely recognizes are listed: advertising a heading inside a comment
            # block or a fence would send the caller chasing one it can never select.
            # The two arms share one message prefix rather than spelling it twice, so
            # the wording cannot drift between them.
            _detail="the file carries no '## '-prefixed headings"
            [ -n "$_headings" ] && _detail="headings present: ${_headings}"
            echo "load-prompt-extension.sh: no section headed '$section' in '$ext_file'; ${_detail}" >&2
        fi
    fi
fi
