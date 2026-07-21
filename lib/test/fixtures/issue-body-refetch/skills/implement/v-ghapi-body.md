# Planted defect: gh api reading an issue's body.

```bash
gh api "repos/{owner}/{repo}/issues/$ARGUMENTS" --jq '.body'
```
