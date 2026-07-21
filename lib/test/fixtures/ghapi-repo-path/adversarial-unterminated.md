# Unterminated fence

The fence below is never closed, so its remainder is treated as fence interior
and the violation after it is FLAGGED.

```bash
echo opening
gh api "repos/$GITHUB_REPOSITORY/issues/1"
