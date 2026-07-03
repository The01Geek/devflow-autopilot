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

### Windows: resolving `gh`

On Windows (WSL-bash or Git Bash), `PATH` can place a **non-executable `gh`** — for example a Python-provided `gh` script carrying a Windows shebang — ahead of the real GitHub CLI (`gh.exe`). A bare `gh` then resolves to that shim, which fails with `cannot execute: required file not found`, so every DevFlow helper that shells out to `gh` breaks even though `gh` works from PowerShell.

DevFlow resolves this automatically: `lib/resolve-gh.sh` (used by every gh-calling helper and by `lib/preflight.sh`) picks the first of `gh`, `gh.exe` whose `gh --version` **actually runs** (a network- and auth-free probe), so a present-but-unrunnable shim is rejected in favor of a working `gh.exe`. On macOS/Linux/cloud, where bare `gh` runs, it returns `gh` on the first probe — no behavior change.

If your host needs a specific binary (or you want to bypass probing entirely), set the **`DEVFLOW_GH`** environment variable to the working `gh` / `gh.exe` (a name on PATH or an absolute path). When set and non-empty it takes top precedence — the probe runs only when `DEVFLOW_GH` is unset or empty — and it is honored by both the shell helpers and the Python helpers (`workpad.py`, `file-deferrals.py`, `match-deferrals.py`, `parse-acs.py`):

```bash
export DEVFLOW_GH=gh.exe   # or an absolute path to the working GitHub CLI
```

`bash lib/preflight.sh` reports a present-but-unrunnable `gh` with this remedy.

### Windows: resolving `jq`

The same shadowing can hit `jq`: a present-but-unrunnable `jq` earlier on `PATH` (a bad-shebang shim, a cleared exec bit) passes a naive presence check while every jq-dependent DevFlow step breaks.

DevFlow resolves this the same way: the shared resolver `lib/resolve-bin.sh` (which every jq-calling helper and `lib/preflight.sh` route through, and which `lib/resolve-gh.sh` delegates to for `gh`; `install.sh` alone carries an inline adaptation, since it runs before any checkout exists — there a broken `DEVFLOW_JQ` falls back to python3 with a warning) picks the first of `jq`, `jq.exe` whose `jq --version` **actually runs** (a network- and auth-free probe), rejecting an unrunnable shim in favor of a working `jq.exe`. On macOS/Linux/cloud, where bare `jq` runs, it returns `jq` on the first probe — no behavior change.

If your host needs a specific binary (or you want to bypass probing entirely), set the **`DEVFLOW_JQ`** environment variable to the working `jq` / `jq.exe` (a name on PATH or an absolute path). When set and non-empty it takes top precedence — the probe runs only when `DEVFLOW_JQ` is unset or empty:

```bash
export DEVFLOW_JQ=jq.exe   # or an absolute path to the working jq
```

`bash lib/preflight.sh` execution-verifies `jq` through the same resolver and reports a present-but-unrunnable `jq` with this remedy.

Relatedly, DevFlow ships `lib/normalize-path.sh` (`devflow_normalize_path`), a sourced helper that converts a Windows-form path (`C:\...`) to the running shell's POSIX form — `wslpath` when present, else `cygpath`, else an environment-detected translation (`/mnt/c/...` under WSL, `/c/...` under MSYS/Git Bash) — echoing an already-POSIX path through unchanged. Runner-reported Windows-form paths (like a skill's base directory on a non-Claude-Code runner) are normalized with the same chain.

### Windows: choosing the bash DevFlow runs under (`DEVFLOW_BASH`)

DevFlow's helpers are `.sh` scripts, so they need a **POSIX bash** to run. On Linux/macOS/cloud that is the default shell and there is nothing to do. On Windows the *default* shell may be PowerShell, and the working bash is whichever of **WSL bash**, **Git Bash**, or **MSYS2 bash** you have — **any of them works**; DevFlow does not mandate a specific one.

Unlike `gh`/`jq` (tools a *running* bash calls, resolved by a sourced `resolve-*.sh` helper), the bash that *runs* the scripts is chosen one layer up — at the **invocation boundary**, before any `.sh` executes — so a sourced resolver cannot select it (it would itself need a chosen bash to run). That layer (the agent or runner that shells into bash) honors the **`DEVFLOW_BASH`** environment variable: set it to the POSIX bash you want DevFlow's helpers to run under.

```bash
export DEVFLOW_BASH=/path/to/bash   # e.g. a WSL, Git Bash, or MSYS2 bash
```

`bash lib/preflight.sh` prints a `devflow-bash:` breadcrumb naming the bash it is running under (interpreter path + `$BASH_VERSION`) and surfaces `DEVFLOW_BASH` when set, so you can confirm the intended bash took effect. If preflight finds it is **not** running under a POSIX bash (empty `$BASH_VERSION` — e.g. when the `.sh` is executed by `sh`/`dash` rather than bash), it prints a remedy naming the three supported bashes and the `DEVFLOW_BASH` override, and exits non-zero. On Linux/macOS/cloud the running `bash` is used unchanged and an unset `DEVFLOW_BASH` is a no-op.

**Known non-goal.** A host with **no POSIX bash at all** (PowerShell-only, with no WSL, Git Bash, or MSYS2 installed) cannot run the `.sh` helpers regardless — that irreducible case is out of scope. Install any one of the three supported bashes; that is the fix, not a `DEVFLOW_BASH` value.

### Non-Claude-Code runners (Copilot CLI, Cursor, Codex CLI, Gemini CLI): the skill anchor

Every local-tier skill locates its bundled helpers through a **portable single-statement anchor**: `"${CLAUDE_SKILL_DIR:-<absolute skill base directory this runner reports in context>}"/../../scripts/…`. On Claude Code, `$CLAUDE_SKILL_DIR` is exported and the command runs as written. On other runners the variable expands **empty**; the agent substitutes the placeholder with the skill base directory the runner reports in context (Copilot CLI prints a `Base directory for this skill:` line), normalizing a Windows-form path (`C:\...`) to POSIX form first (`wslpath -u` / `cygpath -u`, or the `lib/normalize-path.sh` drive-letter rules). Two constraints make the *single-statement* shape load-bearing rather than stylistic:

- **Inline-bash variable stripping (Copilot CLI, verified on 1.0.68):** a variable assigned in one statement of an inline `bash -c` command reads **empty** in a later statement of the same command (`bash -c 'v=hi && echo $v'` prints nothing; the same lines in a `.sh` file work). So never rework a skill's helper call into an assign-then-use form (`SKILL_DIR=…; "$SKILL_DIR"/../…`) — resolve the anchor inline in the statement that uses it, every time.
- **Fail closed:** when neither `$CLAUDE_SKILL_DIR` nor a runner-reported base directory is available, the skills stop and report the unresolved anchor instead of running a broken `/../../…` path.

### Windows: PowerShell file-write encoding (UTF-16LE pitfall)

PowerShell 5.x's `>` redirection and `Out-File` write **UTF-16LE with a BOM** by default. DevFlow's helpers read their input files (issue bodies, workpad body files, AC lists) as **UTF-8**, so a file produced with a PowerShell `>` silently arrives corrupted (NUL-interleaved text, a `ÿþ` BOM). When preparing any file a DevFlow helper will read from PowerShell, write UTF-8 **without** BOM explicitly — e.g. `[IO.File]::WriteAllText($path, $text)` or `Set-Content -Encoding utf8NoBOM` (PowerShell 7+) — or simply create the file from inside your POSIX bash instead.

### Windows: quoting `workpad.py` text arguments from PowerShell

PowerShell's double-quote handling can split a `--note`/`--reflection` text argument into extra argv tokens before Python sees it. `workpad.py` fails closed in that case (exit 2, no partial write) — but the fix is on the caller: **single-quote** the text argument in PowerShell (`--note 'my note text'`), or invoke the helper from bash.

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

Bump `devflow_version` in `.devflow/config.json` to a newer tag, branch, or commit SHA (the workflows fetch that ref at runtime), or just re-run the same `install.sh` — now a small diff, since it refreshes the workflows/actions without committing the plugin tree, and keeps your config. Re-running only re-stamps `devflow_version` itself when the existing value is empty or already looks like a commit SHA; a hand-set non-SHA value (a branch name, a tag) is preserved — see [`cloud-setup.md`](cloud-setup.md#install-and-update-the-cloud-tier) for the exact rule. (The plugin must be at the literal workspace path when CI runs because a marketplace install isn't reachable from the Actions sandbox; the `vendor-plugin` action satisfies this at runtime — see [`cloud-setup.md`](cloud-setup.md#why-the-plugin-lives-at-a-workspace-path-not-added-as-a-github-marketplace-in-ci).)
