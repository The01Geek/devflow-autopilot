# GREEN fixture — both loads carry vendored-literal + anchor fallback (issue #1124)

```bash
.prflow/vendor/prflow/scripts/load-prompt-extension.sh review-and-fix
```

```bash
"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/load-prompt-extension.sh review-and-fix
```

```bash
.prflow/vendor/prflow/scripts/load-prompt-extension.sh receiving-code-review
```

```bash
"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/load-prompt-extension.sh receiving-code-review
```
