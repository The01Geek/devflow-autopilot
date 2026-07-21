# Legitimate corpus — prose

This paragraph quotes the prohibition itself: never write
`gh api "repos/$GITHUB_REPOSITORY/issues/1"` on a surface that can run outside
Actions. Prose outside a fence is out of the scanner's reach by construction, so
a document may state the rule it enforces.

```bash
gh api "repos/{owner}/{repo}/issues/1"
```
