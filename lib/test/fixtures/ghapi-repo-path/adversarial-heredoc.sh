#!/usr/bin/env bash
# A violation inside a heredoc body is FLAGGED: the scanner deliberately does not
# skip heredoc bodies, because a recipe emitted from one runs exactly as written.
cat <<'EOF'
gh api "repos/$GITHUB_REPOSITORY/issues/1"
EOF
