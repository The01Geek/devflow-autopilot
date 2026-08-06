# GREEN fixture — vendored-literal leading token + anchor fallback arm (issue #1124)

Enrolled at issue #1264, when render-time injection gave this call site the
vendored-literal fallback arm it previously lacked.

```bash
.prflow/vendor/prflow/scripts/load-prompt-extension.sh implement
```

```bash
"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/load-prompt-extension.sh implement
```
