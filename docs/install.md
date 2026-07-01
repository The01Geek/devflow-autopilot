# Installing & updating DevFlow

The [README quick start](../README.md#quick-start) gets you running in one line. This page is the full reference: every install path, the now-zero companion-plugin dependency set, and how updates work for both tiers.

## Local tier

DevFlow is published as a Claude Code plugin from this repository, which is also its own marketplace.

**In your terminal** (two commands — run them in order; works in any shell, including PowerShell and fish that don't support `&&` chaining):

```bash
claude plugin marketplace add The01Geek/devflow-autopilot
claude plugin install devflow@devflow-marketplace
```

**Or from inside Claude Code:**

```text
# Add the marketplace
/plugin marketplace add The01Geek/devflow-autopilot

# Install plugin
/plugin install devflow@devflow-marketplace
```

Then run `/reload-plugins` (or restart) to activate. That's it for the local tier — it needs **zero configuration**.

### No companion plugins to add

DevFlow declares **zero companion-plugin dependencies** — every external asset its engine once dispatched is now a first-party DevFlow file: the `pr-review-toolkit` review agents and the `feature-dev` `code-explorer`/`code-architect` discovery/planning subagents live under `agents/`, and the `superpowers` final-pass reviewer (`requesting-code-review`) and fix-loop `receiving-code-review` principles live under `skills/` — all hard-forked with their upstream licenses retained verbatim under `LICENSES/`. So `/plugin install devflow@devflow-marketplace` resolves with **nothing else to add**: no `claude-plugins-official` marketplace prerequisite, and none of the old `/plugin` **Errors**-tab `dependency-unsatisfied` friction that a missing cross-marketplace dependency used to cause. `/simplify` is a built-in Claude Code skill and needs no installation.

### The step people miss: PyYAML

`/plugin install` resolves companion *plugins* only — it **never runs `pip`**. DevFlow's shell helpers need **PyYAML**, so install it yourself:

```bash
python3 -m pip install -r requirements.txt
```

(The cloud-tier `install.sh` handles PyYAML for you.) See [Requirements](../README.md#requirements) for the full PATH checklist; `bash lib/preflight.sh` verifies everything.

### Windows: resolving `python3`

A stock Windows Python install (python.org / `winget install python`) exposes Python on PATH as `python` and the `py -3` launcher — there is **no `python3`**. Because DevFlow's helpers, the agent-typed `python3 <path>` convention, and the cloud `Bash(python3:*)` allowlist all invoke the literal `python3`, the toolchain otherwise fails with `python3: command not found` even with a perfectly good Python 3.11+ installed.

When `python3` is absent but a `>=3.11` Python is reachable as `python` or `py -3`, run the consent-gated provisioner once to install a small `python3` shim onto the first writable directory already on your PATH (falling back to Git-Bash's `~/bin`, with a PATH note, if none is writable):

```bash
bash scripts/provision-python3-shim.sh --apply
```

It selects the first of `python3`/`py -3`/`python` reporting `>=3.11`, writes a `python3` that forwards all arguments and the exit code to it (never recursing), and prints a `devflow-python:` breadcrumb. Without `--apply` it prints exactly what it would do and writes nothing. It is idempotent — a no-op when a real `python3 >=3.11` already resolves — and refuses to write a shim if no `>=3.11` interpreter exists. `install.sh` surfaces this provisioner in plan-only mode on the clone-based install path, and `bash lib/preflight.sh` (which `/devflow:init` relays) points you here when it detects the no-`python3`/has-alternate state. macOS/Linux already ship a real `python3`, so this step is a no-op there.

## Cloud tier (optional, autonomous)

For autonomous GitHub Actions automation, run this from your repo root — the same command installs and later updates it:

```bash
curl -fsSL https://raw.githubusercontent.com/The01Geek/devflow-autopilot/main/install.sh | bash
```

See **[`cloud-setup.md`](cloud-setup.md)** for secrets, triggers, and the full guide.

**Thin by default.** `install.sh` does **not** commit the plugin tree to your repo — it installs the workflows, composite actions, a local `marketplace.json`, and a `.devflow/config.json` scaffold, and pins a `devflow_version` (the commit it installed from). At runtime the workflows materialize the plugin into `.devflow/vendor/devflow/` via the `vendor-plugin` composite action, so there's no bulky vendored diff to carry. Pass `DEVFLOW_VENDOR=1` to commit the tree instead (self-hosting; `devflow_version` is then ignored).

**Both tiers on one repo?** No conflict — the local marketplace copy is cached centrally; the cloud tier materializes its own copy under `.devflow/vendor/devflow/` at runtime (or commits one with `DEVFLOW_VENDOR=1`). Just don't run `/plugin marketplace add ./` there (it would activate two marketplaces named `devflow-marketplace`).

## Updating

### Local tier

Running `/devflow:init` provisions your repo's project `.claude/settings.json` so Claude Code keeps the plugin updated — it registers `devflow-marketplace` under `extraKnownMarketplaces` with `autoUpdate: true` and enables the plugin under `enabledPlugins`, additively and without clobbering anything you already set (re-running is a no-op once the keys exist). Review the change before committing. The provisioned block looks like:

```jsonc
{
  "extraKnownMarketplaces": {
    "devflow-marketplace": {
      "source": { "source": "github", "repo": "The01Geek/devflow-autopilot" },
      "autoUpdate": true
    }
  },
  "enabledPlugins": { "devflow@devflow-marketplace": true }
}
```

Or update on demand: `/plugin marketplace update devflow-marketplace`.

If you run Claude Code against a **third-party model provider** (Amazon Bedrock, Google Vertex AI, or Microsoft Foundry), `/devflow:init` can also — **only with your explicit consent** — make `auto` permission mode **selectable** in the Shift+Tab cycle by adding `CLAUDE_CODE_ENABLE_AUTO_MODE="1"` to your **user-global** `~/.claude/settings.json` (it must live at user scope; Claude Code ignores it in a project file). This is *selectable, never on*: it writes no `permissions.defaultMode`, so you still choose `auto` yourself and plan/model/admin gates still apply. It asks before touching the user-global file, preserves a deliberately-disabled `"0"` (never flips it to `"1"`), and is idempotent, atomic, and fail-closed; decline and it just prints the one-line setting for you to add yourself. On the **Anthropic API this step is skipped entirely** — `auto` mode is already available there by default, so the env var would do nothing.

### Cloud tier

Bump `devflow_version` in `.devflow/config.json` to a newer tag, branch, or commit SHA (the workflows fetch that ref at runtime), or just re-run the same `install.sh` — now a small diff, since it re-stamps `devflow_version` and refreshes the workflows/actions without committing the plugin tree, and keeps your config. (The plugin must be at the literal workspace path when CI runs because a marketplace install isn't reachable from the Actions sandbox; the `vendor-plugin` action satisfies this at runtime — see [`cloud-setup.md`](cloud-setup.md#why-the-plugin-lives-at-a-workspace-path-not-added-as-a-github-marketplace-in-ci).)
