# SPDX-FileCopyrightText: 2026 Daniel Radman
# SPDX-License-Identifier: MIT
# Elide the *bodies* of generated/vendored files from a unified diff, keeping
# the `diff --git` header line (so the path still shows) but replacing the hunk
# text with a one-line marker. Mirrors the prior python regex 1:1.
#
# Reads a diff on stdin, writes the trimmed diff on stdout. Used by
# lib/fetch-pr-context.sh and exercised by lib/test/run.sh. POSIX ERE only
# (works under mawk and gawk).

function is_noise(p) {
  if (p ~ /(^|\/)(package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|composer\.lock|Gemfile\.lock|poetry\.lock|Cargo\.lock|go\.sum)$/) return 1
  if (p ~ /\.min\.(js|css|mjs)$/) return 1
  if (p ~ /\.map$/) return 1
  if (p ~ /(^|\/)(node_modules|vendor|dist|build)\//) return 1
  return 0
}

BEGIN { elide = 0 }

/^diff --git / {
  # Third whitespace field is the `a/<path>` token (a path containing a space
  # is truncated at the space here, exactly as the prior python str.split did).
  path = ""
  if ($3 ~ /^a\//) path = substr($3, 3)
  elide = (path != "" && is_noise(path))
  print
  if (elide) print "[devflow: diff body elided — generated/vendored file: " path "]"
  next
}

{ if (!elide) print }
