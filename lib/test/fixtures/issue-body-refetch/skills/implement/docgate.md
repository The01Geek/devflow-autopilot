# §4.1 Documentation-Needed gate allowance — carries the docgate literal.

```bash
gh issue view $ISSUE_NUMBER --json body --jq '.body' > /tmp/devflow-docgate-body-$ISSUE_NUMBER.txt 2>/tmp/devflow-docgate-gh.err
```
