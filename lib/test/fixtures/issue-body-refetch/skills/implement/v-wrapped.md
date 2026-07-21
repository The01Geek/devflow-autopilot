# Planted defect spelled across a line wrap — a line-based scan would miss it.

```bash
gh issue view $ARGUMENTS \
  --json body --jq '.body'
```
