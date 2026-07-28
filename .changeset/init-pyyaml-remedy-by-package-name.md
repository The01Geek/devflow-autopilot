---
bump: patch
type: Fixed
---

- **`/devflow:init` now relays `python3 -m pip install PyYAML` instead of `pip install -r requirements.txt`.** The `-r` path resolves against the user's own working directory, not the plugin cache, so in a Python project the relayed remedy would have installed *their* dependency set rather than DevFlow's single requirement. The same change corrects a false parenthetical in `README.md`, `docs/install.md`, and `docs/DEVFLOW_SYSTEM_OVERVIEW.md`, which each claimed a plugin-cache install "has no `requirements.txt` to point `pip` at" — the file is tracked and does ship in the cache; the real reason to name the package is the cwd-relative path. (#PR)
