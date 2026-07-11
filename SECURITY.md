# Security Policy

## Reporting a vulnerability

If you discover a security issue in DevFlow, please report it privately rather
than opening a public issue. Use GitHub's **private vulnerability reporting**
(the "Report a vulnerability" button under the repository's *Security* tab), or
email **daniel@radman.ai**. You'll get an acknowledgement within a few days.

Please include reproduction steps and the affected version or commit.

## Scope and considerations

DevFlow runs as a Claude Code plugin and, optionally, as a set of GitHub Actions
workflows. A few areas warrant care:

- **Cloud tier credentials.** The optional GitHub Actions automation uses a
  Claude Code OAuth token (`CLAUDE_CODE_OAUTH_TOKEN`). Never commit it. Store it
  as an encrypted GitHub Actions secret. See `docs/cloud-setup.md`.
- **`config.json` is committed, not gitignored.** DevFlow's cloud tier reads it
  from the committed tree, so the scaffolded `.devflow/.gitignore` ignores only
  `tmp/` and leaves `config.json` tracked. Because it is committed, keep secrets
  out of it — it holds only non-secret environment configuration (project/board
  IDs, model names). Store credentials as encrypted GitHub Actions secrets, never
  in `config.json`.
- **Skills run shell commands.** DevFlow's skills execute `git`, `gh`, `jq`, and
  bundled Python helpers. Review the skills you install, as you would any plugin.
- **The retrospective loop opens PRs/issues** on the configured repository. It
  never auto-merges and never auto-edits the repo; each recurring pattern is filed
  as an issue for human triage, and the weekly state PR awaits human review.

## Supported versions

DevFlow follows semantic versioning. Security fixes target the latest released
minor version.
