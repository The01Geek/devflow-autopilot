# ⚡ devflow-autopilot

**Turn GitHub issues into reviewed, documented pull requests — automatically.**

devflow-autopilot is a template that wires Claude Code into your GitHub workflow. Drop an issue into your project board, and the automation handles the rest: branch creation, implementation, multi-agent code review, documentation, and status tracking.

---

## 🎬 See It In Action

<div align="center">

<a href="https://www.youtube.com/watch?v=Uyls8rcviBg">
  <img src="https://img.youtube.com/vi/Uyls8rcviBg/maxresdefault.jpg" alt="Watch the demo on YouTube" width="600">
</a>

**[▶ Watch the full walkthrough on YouTube](https://www.youtube.com/watch?v=Uyls8rcviBg)**

</div>

---

## ⚡ The `/implement` Pipeline

From a GitHub issue to a production-ready pull request — four phases, multiple AI agents, zero manual coding:

```mermaid
flowchart TD
    input(["📥 GitHub Issue"]):::input

    input --> P2

    subgraph P2 ["🧠 Phase 2 — Discover & Build"]
        B1{{"🔍 code-explorer<br/>Understands your<br/>codebase & patterns"}}:::agent
        B2{{"📐 code-architect<br/>Designs the<br/>right solution"}}:::agent
        B3["💻 Implementer<br/>Writes code + tests"]:::code
        B1 --> B2 --> B3
    end

    P2 --> P3

    subgraph P3 ["🛡️ Phase 3 — Quality Gate"]
        C2{{"🔄 /review-and-fix<br/>5 specialized review<br/>agents in parallel"}}:::agent
        C3{"✅ Pass?"}:::decision
        C4["🔧 Auto-fix<br/>findings"]:::fix
        C5["✨ Quality<br/>approved"]:::success
        C2 --> C3
        C3 -- "❌ Fail" --> C4 --> C2
        C3 -- "✅ Pass" --> C5
    end

    P3 --> P4

    subgraph P4 ["📚 Phase 4 — Documentation"]
        direction LR
        D1["📘 Internal<br/>tech docs"]:::docs
        D2["📗 External<br/>user docs"]:::docs
        D3["📋 Release<br/>notes"]:::docs
        D4["📝 PR<br/>description"]:::docs
        D1 --> D2 --> D3 --> D4
    end

    P4 --> output

    output(["📤 Production-Ready PR<br/>Reviewed · Documented · Tested"]):::output

    classDef input fill:#f0f9ff,stroke:#0284c7,stroke-width:3px,color:#0c4a6e
    classDef output fill:#d1fae5,stroke:#059669,stroke-width:3px,color:#065f46
    classDef agent fill:#ede9fe,stroke:#7c3aed,stroke-width:2px,color:#4c1d95
    classDef code fill:#dbeafe,stroke:#2563eb,stroke-width:1.5px,color:#1e3a8a
    classDef review fill:#e0e7ff,stroke:#4f46e5,stroke-width:2px,color:#3730a3
    classDef decision fill:#fef3c7,stroke:#d97706,stroke-width:2px,color:#92400e
    classDef fix fill:#fecaca,stroke:#dc2626,stroke-width:2px,color:#7f1d1d
    classDef success fill:#bbf7d0,stroke:#16a34a,stroke-width:2px,color:#14532d
    classDef docs fill:#fce7f3,stroke:#db2777,stroke-width:2px,color:#9d174d

    style P2 fill:#faf5ff,stroke:#7c3aed,stroke-width:2px
    style P3 fill:#fffbeb,stroke:#d97706,stroke-width:2px
    style P4 fill:#fdf2f8,stroke:#db2777,stroke-width:2px
```

---

## 🔄 What happens when you create an issue

```mermaid
flowchart TD
    A(["🆕 You create an issue"]):::user
    B{"📋 Draft on<br/>project board?"}:::decision
    C["🤖 Bot posts<br/>@claude /implement"]:::process
    D["💬 You post<br/>@claude /implement"]:::user
    E["⚡ /implement runs"]:::core
    F["📂 Branch created"]:::process
    G["🔍 Explore codebase<br/>🏗️ Design architecture"]:::process
    H["💻 Write code & tests"]:::process
    I["📋 Open draft PR"]:::process
    J["🔄 Multi-agent review<br/>+ auto-fix loop"]:::agent
    K["📘 Generate documentation<br/>Internal · External · Release Notes"]:::docs
    L["✅ PR ready for review"]:::success
    M(["👀 You review & merge"]):::user

    A --> B
    B -- Yes --> C --> E
    B -- No --> D --> E
    E --> F --> G --> H --> I --> J --> K --> L --> M

    classDef user fill:#d1fae5,stroke:#059669,stroke-width:2px,color:#065f46
    classDef decision fill:#fef3c7,stroke:#d97706,stroke-width:2px,color:#92400e
    classDef process fill:#dbeafe,stroke:#2563eb,stroke-width:1.5px,color:#1e3a8a
    classDef core fill:#c7d2fe,stroke:#4f46e5,stroke-width:3px,color:#312e81
    classDef agent fill:#ede9fe,stroke:#7c3aed,stroke-width:2px,color:#4c1d95
    classDef docs fill:#fce7f3,stroke:#db2777,stroke-width:2px,color:#9d174d
    classDef success fill:#bbf7d0,stroke:#16a34a,stroke-width:2px,color:#14532d
```

You review the PR. Merge when ready. That's the workflow.

---

## 🚀 Quick Start

1. **Use this template** > Create a new repository
2. Install the [Radman AI](https://github.com/apps/radman-ai) GitHub App on your repo
3. Edit `.github/project-config.yml` with your project number and branch
4. Add secrets: `CLAUDE_CODE_OAUTH_TOKEN`, `RADMAN_AI_PRIVATE_KEY`, `PROJECT_PAT` ([setup guide](#-authentication))
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

`/review` runs a multi-agent pipeline. `/review-and-fix` wraps it with an auto-fix loop (up to 4 iterations):

```mermaid
flowchart TD
    diff["📄 Git diff + changed files"]:::input
    gen{{"📝 Checklist Generator<br/>Enumerate every verifiable claim"}}:::agent
    verify{{"✅ Checklist Verifiers<br/>Verify each claim in parallel"}}:::agent

    diff --> gen --> verify --> par

    subgraph par ["🔍 Review Agents — run in parallel"]
        direction LR
        R1{{"Code<br/>Reviewer"}}:::agent
        R2{{"Silent Failure<br/>Hunter"}}:::agent
        R3{{"Comment<br/>Analyzer"}}:::agent
        R4{{"Test Coverage<br/>Analyzer"}}:::agent
        R5{{"Type Design<br/>Analyzer"}}:::agent
    end

    par --> agg["📊 Aggregate findings"]:::process
    agg --> verdict{"Verdict"}:::decision
    verdict -- "✅ APPROVE" --> done["🎉 Review complete"]:::success
    verdict -- "❌ REJECT" --> fix["🔧 Auto-fix + commit"]:::fix
    fix -.-> diff

    classDef input fill:#f3f4f6,stroke:#6b7280,stroke-width:2px,color:#374151
    classDef agent fill:#ede9fe,stroke:#7c3aed,stroke-width:2px,color:#4c1d95
    classDef process fill:#dbeafe,stroke:#2563eb,stroke-width:1.5px,color:#1e3a8a
    classDef decision fill:#fef3c7,stroke:#d97706,stroke-width:2px,color:#92400e
    classDef success fill:#bbf7d0,stroke:#16a34a,stroke-width:2px,color:#14532d
    classDef fix fill:#fecaca,stroke:#dc2626,stroke-width:2px,color:#7f1d1d
```

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

### Project Board Statuses

Issues flow through these statuses automatically. Each arrow shows the workflow that handles the transition:

```mermaid
flowchart LR
    A(["📋 Draft"]):::draft
    B(["🔨 In Progress"]):::progress
    C(["🤖 AI PR Drafted"]):::pr
    D(["🚀 Released"]):::released
    E(["✅ Closed"]):::closed

    A -- "move-to-in-progress.yml<br/>Branch created" --> B
    B -- "sync-pr-status-to-issue.yml<br/>PR opened" --> C
    C -- "Merged + tagged" --> D
    D -- "close-released-items.yml<br/>Manual dispatch" --> E

    classDef draft fill:#fef3c7,stroke:#d97706,stroke-width:2px,color:#92400e
    classDef progress fill:#dbeafe,stroke:#2563eb,stroke-width:2px,color:#1e3a8a
    classDef pr fill:#ede9fe,stroke:#7c3aed,stroke-width:2px,color:#4c1d95
    classDef released fill:#d1fae5,stroke:#059669,stroke-width:2px,color:#065f46
    classDef closed fill:#f3f4f6,stroke:#6b7280,stroke-width:2px,color:#374151
```

### Workflow Trigger Map

Six workflows react to GitHub events and keep everything moving:

```mermaid
flowchart LR
    subgraph events ["⚡ GitHub Events"]
        E1(["Issue opened"]):::event
        E2(["Branch created"]):::event
        E3(["@claude mentioned"]):::event
        E4(["PR opened / updated"]):::event
        E5(["Manual dispatch"]):::event
    end

    subgraph workflows ["⚙️ Workflows"]
        W1["comment-on-<br/>draft-issues"]:::workflow
        W2["move-to-<br/>in-progress"]:::workflow
        W3["claude.yml"]:::workflow
        W4["sync-pr-status-<br/>to-issue"]:::workflow
        W5["WikiWizard"]:::workflow
        W6["close-released-<br/>items"]:::workflow
    end

    subgraph effects ["✨ What Happens"]
        F1["Posts @claude /implement<br/>on Draft issues"]:::effect
        F2["Board status →<br/>In Progress"]:::effect
        F3["Runs any Claude Code<br/>skill or agent"]:::effect
        F4["Syncs PR status<br/>to linked issues"]:::effect
        F5["Generates docs +<br/>triggers /review"]:::effect
        F6["Moves Released →<br/>Closed"]:::effect
    end

    E1 --> W1 --> F1
    E2 --> W2 --> F2
    E3 --> W3 --> F3
    E4 --> W4 --> F4
    E4 --> W5 --> F5
    E5 --> W6 --> F6

    classDef event fill:#fef3c7,stroke:#d97706,stroke-width:2px,color:#92400e
    classDef workflow fill:#dbeafe,stroke:#2563eb,stroke-width:2px,color:#1e3a8a
    classDef effect fill:#d1fae5,stroke:#059669,stroke-width:2px,color:#065f46
```

---

## 📦 Configuration

Everything is in `.github/project-config.yml`. Key fields:

| Field | What it controls | Default |
|-------|-----------------|---------|
| `project_number` | Your GitHub Project board number | `"1"` |
| `app_id` | GitHub App ID for project automation | `"3102164"` (Radman AI) |
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
| `RADMAN_AI_PRIVATE_KEY` | GitHub App private key |
| `PROJECT_PAT` | Classic PAT with `repo` + `project` scopes — used for all ProjectV2 operations |

The GitHub App ID is configured in `.github/project-config.yml` (`app_id` field, defaults to `3102164` for Radman AI).

> **Why a PAT?** GitHub App installation tokens cannot access user-owned ProjectsV2 (there is no "Projects" permission for personal accounts). The `PROJECT_PAT` works around this limitation. If you move to an organization, you can switch back to the app token by granting "Organization permissions → Projects: Read & Write" on your GitHub App.

### GitHub App Setup

**Option 1: Install Radman AI (recommended)**

1. Install [Radman AI](https://github.com/apps/radman-ai) on your repository
2. Add the private key as a repo secret (`RADMAN_AI_PRIVATE_KEY`)

**Option 2: Create your own GitHub App**

1. Settings > Developer settings > GitHub Apps > New
2. Permissions: issues (write), pull_requests (write), projects (read/write), contents (read)
3. Install on your repo
4. Add the private key as a repo secret
5. Set `app_id` in `.github/project-config.yml` to your app's ID
6. Update `bot_login` and `allowed_bots` in `.github/project-config.yml` to match your app's slug

To use different secret names, find-and-replace `RADMAN_AI_` in the workflow files.

### Classic PAT for Project Board Access

GitHub App tokens **cannot access user-owned ProjectsV2** — this is a platform limitation. All project board workflows use the `PROJECT_PAT` secret instead.

1. Go to [Settings → Developer settings → Personal access tokens → Tokens (classic)](https://github.com/settings/tokens)
2. Create a token with scopes: **`repo`** and **`project`**
3. Add it as a repository secret named **`PROJECT_PAT`**
4. Rotate before expiry

If you move to an **organization**, you can switch back to the GitHub App token by adding "Organization permissions → Projects: Read & Write" to your app, then removing the `PROJECT_PAT` references from the workflow files.

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
- A GitHub App (Radman AI or your own) for issue/PR automation
- A Classic PAT with `repo` + `project` scopes for project board access

No GitHub Projects? Disable the board-dependent workflows and use Claude Code skills directly from issues and PRs.

---

## License

MIT
