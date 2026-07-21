# §1.1 producer allowance — writes the cache, so it carries the cache-path literal.

```bash
gh issue view $ARGUMENTS --json body --jq '.body' > "$DEVFLOW_ROOT/.devflow/tmp/issue-body/issue-$ARGUMENTS.md"
```
