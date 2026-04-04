# ⚡ devflow-autopilot

**Turn GitHub issues into reviewed, documented pull requests — automatically.**

devflow-autopilot is a template that wires Claude Code into your GitHub workflow. Drop an issue into your project board, and the automation handles the rest: branch creation, implementation, multi-agent code review, documentation, and status tracking.

---

## 🔄 What happens when you create an issue

```
1. You create a GitHub issue              (that's it — that's your part)

2. Claude implements the feature           /implement orchestrates discovery,
                                           planning, coding, and testing

3. PR opens with full code review          /review runs parallel agents:
                                           verification checklist, code review,
                                           silent failure hunting, and more

4. Docs update themselves                  WikiWizard generates:
                                           📘 Internal technical docs (for devs
                                              and future AI agent context)
                                           📗 External user-facing docs
                                           📋 Release notes

5. Project board stays current             Status moves from Draft → In Progress
                                           → AI PR Drafted automatically
```

You review the PR. Merge when ready. That's the workflow.

---

## 🚀 Quick Start

1. **Use this template** > Create a new repository
2. Install the [Radman AI](https://github.com/apps/radman-ai) GitHub App on your repo
3. Edit `.github/project-config.yml` with your project number and branch
4. Add secrets: `CLAUDE_CODE_OAUTH_TOKEN`, `RADMAN_AI_APP_ID`, `RADMAN_AI_PRIVATE_KEY` ([setup guide](#-authentication))
5. Create a [GitHub Projects (v2)](https://docs.github.com/en/issues/planning-and-tracking-with-projects) board with statuses: Draft, In Progress, AI PR Drafted, Released, Closed
6. Fill in `CLAUDE.md` with your project's conventions

Create an issue. Watch it become a PR.

---

## 🛠️ Skills

Skills are slash commands you can run from issues, PRs, or the CLI.

### Development

| Skill | What it does |
|-------|-------------|
| `/implement` | Full lifecycle: issue → branch → implemented PR with tests |
| `/review` | Four-phase code review with verification checklist and APPROVE/REJECT verdict |
| `/review-and-fix` | Runs /review, fixes findings, re-reviews — up to 4 iterations |
| `/create-issue` | Turns a rough idea into a structured GitHub issue |
| `/pr-description` | Generates PR descriptions from branch diff, preserves human edits |

### 📘 Documentation

Two types of documentation are managed automatically:

- **Internal docs** (`docs/internal/`) — Technical documentation for developers and AI coding agents. These serve as context for future Claude Code sessions, making each subsequent implementation more informed.
- **External docs** (`docs/external/`) — Customer-facing documentation. Stripped of implementation details, written for end users.

| Skill | What it does |
|-------|-------------|
| `/docs` | Updates internal docs, external docs, and release notes in one pass |
| `/docs-verify` | Checks if documentation for a specific topic is accurate and current |
| `/docs-sync-internal` | Syncs internal technical docs to match code changes on the branch |
| `/docs-sync-external` | Aligns customer-facing docs with internal docs |
| `/docs-bootstrap-internal` | Generates internal technical docs from scratch for undocumented codebases |
| `/docs-bootstrap-external` | Creates external user-facing docs from existing internal docs |
| `/docs-release-notes` | Writes release note entries for customer-visible changes |

---

## 🤖 Agents

Specialized reviewers that run in parallel during `/review`.

| Agent | Focus area |
|-------|-----------|
| 📝 checklist-generator | Enumerates every verifiable claim in a diff |
| ✅ checklist-verifier | Checks each claim against actual source code |
| 📌 github-issue-creator | Structures rough requirements into detailed issues |

---

## ⚙️ Workflows

| Workflow | Trigger | What it does |
|----------|---------|-------------|
| claude.yml | `@claude` mention | Runs Claude Code with full skill/agent access |
| WikiWizard.yml | PR opened or updated | Generates internal docs, external docs, and release notes on the PR branch |
| comment-on-draft-issues.yml | Issue created | Auto-triggers `/implement` on Draft issues |
| move-to-in-progress.yml | Branch created | Updates issue status in project board |
| sync-pr-status-to-issue.yml | PR state change | Keeps linked issues in sync with PR status |
| close-released-items.yml | Manual | Moves "Released" items to "Closed" |

---

## 📦 Configuration

Everything is in `.github/project-config.yml`. Key fields:

| Field | What it controls | Default |
|-------|-----------------|---------|
| `project_number` | Your GitHub Project board number | `"1"` |
| `base_branch` | Default PR target | `"main"` |
| `claude_model` | Model for AI workflows | `"claude-opus-4-6"` |
| `statuses.*` | Project board status names | Draft, In Progress, etc. |
| `docs.internal` / `docs.external` | Documentation paths | `docs/internal/`, `docs/external/` |
| `bot_login` | Bot account for AI-authored PRs | `"radman-ai"` |
| `claude.allowed_bots` | Bots that can trigger Claude | `"radman-ai"` |
| `wikiwizard.*` | Doc generation settings | label, release notes path, allowed bots |
| `workflows.*` | Toggle each workflow on/off | all `true` |

---

## 🔐 Authentication

### Required Secrets

| Secret | Purpose |
|--------|---------|
| `CLAUDE_CODE_OAUTH_TOKEN` | Claude Code API access ([docs](https://docs.anthropic.com/en/docs/claude-code/github-actions)) |
| `RADMAN_AI_APP_ID` | GitHub App ID for project automation |
| `RADMAN_AI_PRIVATE_KEY` | GitHub App private key |

### GitHub App Setup

**Option 1: Install Radman AI (recommended)**

1. Install [Radman AI](https://github.com/apps/radman-ai) on your repository
2. Add the App ID and private key as repo secrets (`RADMAN_AI_APP_ID`, `RADMAN_AI_PRIVATE_KEY`)

**Option 2: Create your own GitHub App**

1. Settings > Developer settings > GitHub Apps > New
2. Permissions: issues (write), pull_requests (write), projects (read/write), contents (read)
3. Install on your repo
4. Add the App ID and private key as repo secrets
5. Update `bot_login` and `allowed_bots` in `.github/project-config.yml` to match your app's slug

To use different secret names, find-and-replace `RADMAN_AI_` in the workflow files.

A Personal Access Token with `project` scope works as an alternative.

---

## 🧩 Customization

- **Toggle workflows** on/off in `project-config.yml`
- **Add your own skills** — create a directory under `.claude/skills/` with a `SKILL.md`
- **Add your own agents** — drop an `.md` file in `.claude/agents/`
- **Add language plugins** — edit `.claude/settings.json`
- **Define conventions** — fill in `CLAUDE.md` so Claude follows your project's standards
- **Configure tests** — document test/lint commands in `CLAUDE.md` so `/review-and-fix` can run them

---

## 📋 Requirements

- A GitHub repository (public or private)
- [GitHub Projects (v2)](https://docs.github.com/en/issues/planning-and-tracking-with-projects) board with a Status field
- Claude Code OAuth token
- A GitHub App or PAT for project automation

No GitHub Projects? Disable the board-dependent workflows and use Claude Code skills directly from issues and PRs.

---

## License

MIT
