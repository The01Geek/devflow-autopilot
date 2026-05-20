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
  GitHub App private key and tokens, supplied via the repository secrets
  `DEVFLOW_APP_ID` and `DEVFLOW_APP_PRIVATE_KEY` (and a `PROJECT_PAT` for board
  sync). Never commit these. Store them as encrypted GitHub Actions secrets.
  See `docs/cloud-setup.md`.
- **`project-config.yml` is gitignored** by default precisely so adopters don't
  accidentally commit project board numbers, App IDs, or bot logins. Treat it as
  environment configuration.
- **Skills run shell commands.** DevFlow's skills execute `git`, `gh`, `jq`, and
  bundled Python helpers. Review the skills you install, as you would any plugin.
- **The retrospective loop opens PRs/issues** on the configured repository. It
  never auto-merges; every intervention PR is opened for human review.

## Supported versions

DevFlow follows semantic versioning. Security fixes target the latest released
minor version.
