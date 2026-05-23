---
name: init
description: Use when setting up DevFlow in a repo for the first time, or after a plugin update — scaffolds .devflow/config.json from the shipped template (only if absent) and refreshes config.schema.json. Invoke explicitly with /devflow:init.
disable-model-invocation: true
---

# DevFlow Init

Scaffold this repo's DevFlow config files. **One command does everything — do not hand-write `config.json` or guess field values.**

## Run

```bash
bash "${CLAUDE_SKILL_DIR}/../../scripts/scaffold-config.sh"
```

This is the single shared scaffolder — the same script `install.sh` uses, so the two entry points can never drift. With no argument it targets the current repo root (git toplevel) and:

- creates `.devflow/config.json` from the shipped `config.example.json` **only if it does not already exist** — it never clobbers a config you've already filled in with real project/board IDs;
- always refreshes `.devflow/config.schema.json` so your editor validates against the current field set;
- creates the **`devflow:implement`** trigger label in the repo if it's missing (best-effort, via `gh` — adding that label to an issue is what starts `/devflow:implement` in the cloud tier; honours `claude_implement.trigger_label`).

It resolves the templates from the installed plugin (`${CLAUDE_SKILL_DIR}/../../.devflow/`), so it works whether DevFlow was installed via the marketplace or vendored by `install.sh`.

## After running

Read the scaffolder's output line and respond accordingly:

- **`scaffolded …`** — a fresh `.devflow/config.json` was created. Every value has a working default, so it's usable as-is; tell the user they only need to edit it to customize (their editor validates against `config.schema.json`).
- **`keeping existing …`** — they already had a `config.json`; it was left untouched and only the schema was refreshed. Nothing more to do.

The scaffolder also prints a `trigger label …` line: report it as-is. If it says gh wasn't available or the label couldn't be created, tell the user to create a label named `devflow:implement` (Issues → Labels) — adding it to an issue is what kicks off `/devflow:implement` in the cloud tier.

If the scaffolder exits non-zero (exit 2 = templates not found next to the script), the plugin install is incomplete. Tell the user to reinstall/update the DevFlow plugin (or run `install.sh` for the cloud tier). **Do not fall back to hand-writing the files** — that reintroduces exactly the drift this skill exists to prevent.
