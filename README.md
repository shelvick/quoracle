# Quoracle

Recursive agent orchestration with multi-LLM consensus.

Quoracle is a Phoenix LiveView application that lets you build hierarchical agent systems where _every decision_ is made by consensus across multiple language models. Instead of trusting one model to get it right, Quoracle queries your entire model pool and only executes the action they agree on. Agents spawn child agents, communicate via messages, and persist their full state to PostgreSQL -- all visible in real time through a browser-based dashboard.

<p align="center">
  <img src="assets/static/images/hero.svg" alt="Recursive Agent Orchestration with Multi-LLM Consensus" width="800"/>
</p>

**What this is for:** Exploring multi-agent orchestration, experimenting with consensus-driven AI, and running complex tasks that benefit from diverse model perspectives. If you've ever wished you could throw three different LLMs at a problem and take the best answer, this is that -- but recursive.

**What this is _not_ for:** Simple chatbot interfaces, single-model workflows (you'd be better served by something lighter), or unsupervised production deployments (see [Security](#security)).

## Table of Contents

- [Prerequisites](#prerequisites)
- [Setup](#setup)
  - [Development](#development)
  - [Docker](#docker)
  - [Release Tarball](#release-tarball)
- [First Run](#first-run)
  - [1. Add Credentials](#1-add-credentials)
  - [2. Configure Model Roles](#2-configure-model-roles)
  - [3. Create Profiles](#3-create-profiles)
  - [4. Create a Task](#4-create-a-task)
- [Usage Tips](#usage-tips)
  - [Writing Good Profiles](#writing-good-profiles)
  - [Using Skills](#using-skills)
  - [Prompting Well](#prompting-well)
- [Security](#security)
- [Tech Rundown](#tech-rundown)
  - [Agent Architecture](#agent-architecture)
  - [Recursive Hierarchy](#recursive-hierarchy)
  - [Persistence & Real-Time UI](#persistence--real-time-ui)
  - [Consensus Pipeline](#consensus-pipeline)
  - [Per-Model Conversation History](#per-model-conversation-history)
  - [Actions](#actions)
  - [PubSub Isolation](#pubsub-isolation)
- [Configuration Reference](#configuration-reference)
- [Current Status](#current-status)
- [Contributing](#contributing)
- [License](#license)

## Prerequisites

What you need depends on how you're deploying:

**All deployments:**
- **API keys** for at least one supported LLM provider, plus an embedding model (see [First Run](#first-run))

**Development** (building from source):
- **Elixir** >= 1.18 with **OTP** >= 27
- **PostgreSQL** >= 14 (tested with 17)
- **libvips** -- required for vision/image features
  - Debian/Ubuntu: `sudo apt install libvips libvips-dev`
  - Fedora/RHEL: `sudo dnf install vips vips-devel`
  - macOS: `brew install vips`

**Docker:**
- **Docker** and **Docker Compose** (PostgreSQL is included)

**Release tarball:**
- **PostgreSQL** >= 14
- **libvips** (runtime library only, no dev headers needed)
  - Debian/Ubuntu: `sudo apt install libvips`
  - Fedora/RHEL: `sudo dnf install vips`
- No Elixir or Erlang required -- the release is self-contained

## Setup

Three ways to run Quoracle, depending on your situation.

### Development

The standard "clone and go" workflow:

```bash
git clone https://github.com/shelvick/quoracle.git
cd quoracle
```

PostgreSQL needs password authentication for Ecto (it connects via TCP, so peer auth won't work). If you haven't set a password for your database user:

```bash
sudo -u postgres psql -c "ALTER USER postgres PASSWORD 'postgres';"
```

Then:

```bash
mix setup
```

This pulls dependencies, compiles everything, creates the database, runs migrations, and builds assets.

You'll also need an encryption key to store API credentials:

```bash
export CLOAK_ENCRYPTION_KEY=$(openssl rand -base64 32)
```

Without it the app still starts, but you won't be able to add model credentials, which means you won't be able to do much of anything.

You can put this (and other env vars) in a `.env` file in the project root for convenience. The dev server doesn't source it automatically, but you can use [direnv](https://direnv.net/) or `source .env` before starting:

```bash
cp .env.example .env
# edit .env, then:
source .env
mix phx.server
```

Open [http://localhost:4000](http://localhost:4000).

### Docker

```bash
git clone https://github.com/shelvick/quoracle.git
cd quoracle
cp .env.example .env
```

Edit `.env` and fill in the required values:

```bash
SECRET_KEY_BASE=$(openssl rand -base64 64 | tr -d '\n')
CLOAK_ENCRYPTION_KEY=$(openssl rand -base64 32)
```

Then:

```bash
docker-compose up
```

The database URL and bind address are handled automatically by `docker-compose.yml` -- you don't need to touch those.

### Release Tarball

Download the latest release tarball from [GitHub Releases](https://github.com/shelvick/quoracle/releases), or build one yourself:

```bash
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix compile
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
```

The tarball extracts into a `quoracle-VERSION/` directory. Inside you'll find a `.env.example` -- copy it to `.env` and fill in all three required values:

```bash
DATABASE_URL=ecto://user:password@localhost/quoracle
SECRET_KEY_BASE=<generate with: openssl rand -base64 64 | tr -d '\n'>
CLOAK_ENCRYPTION_KEY=<generate with: openssl rand -base64 32>
```

Create the database and start the server:

```bash
bin/migrate    # creates database (if needed) and runs migrations
bin/server     # runs migrate, then starts the application
```

Both `bin/migrate` and `bin/server` source `.env` automatically if it's present in the release root.

By default Quoracle binds to `127.0.0.1`. Set `PHX_BIND_ADDRESS=0.0.0.0` if you need it on all interfaces (Docker does this automatically). See [Configuration Reference](#configuration-reference) for all options.

## First Run

Once Quoracle is running, open the dashboard and head to **Settings** (top-right).

### 1. Add Credentials

Go to the **Credentials** tab. This is where you give Quoracle access to your LLM providers.

Quoracle supports (in theory) any model listed on [models.dev](https://models.dev) via the ReqLLM library. The model spec format is `provider:model-name`. A few common examples:

| Provider | Model Spec Format | Extra Fields |
|----------|-------------------|--------------|
| OpenAI | `openai:gpt-4o` | -- |
| Anthropic | `anthropic:claude-sonnet-4-20250514` | -- |
| Google | `google:gemini-2.5-pro` | -- |
| Google Vertex AI | `google-vertex:gemini-2.5-pro` | Resource ID (project ID) |
| Azure OpenAI | `azure:gpt-4` | Deployment ID |
| Groq | `groq:llama-3.3-70b-versatile` | -- |

This is not an exhaustive list -- any provider supported by ReqLLM should work. API keys are encrypted at rest with AES-256-GCM.

You need at least one credential to do anything, but the real value of Quoracle comes from having _multiple_ models from _different_ providers.

### 2. Configure Model Roles

Switch to the **Model Config** tab. Here you assign models to specific system functions:

- **Embedding model** -- used for semantic similarity within consensus and for deduplicating agent lessons. Required.
- **Answer engine model** -- powers the `answer_engine` action (web search/grounding). Pick a model with web search capability; Google models get native search grounding, but any model that supports search will work.
- **Summarization model** -- used when spawning child agents to summarize the accumulated context that gets passed down the hierarchy.
- **Image generation models** -- for the `generate_images` action.

These should be configured before you start creating tasks. If an agent tries to use a feature (say, the answer engine) and no model is configured for it, it will fail at runtime rather than degrade gracefully.

### 3. Create Profiles

Switch to the **Profiles** tab. A profile defines _which models_ participate in consensus and _what actions_ the agent is allowed to take.

**Model pool**: Pick at least one model, but three is the sweet spot for consensus. Mixing providers (e.g., one OpenAI, one Anthropic, one Google) gives you the most diverse perspectives.

**Capability groups** control what actions are available:

| Group | What It Unlocks |
|-------|-----------------|
| `file_read` | Read files from disk |
| `file_write` | Write and edit files |
| `external_api` | Call external APIs (`call_api` action) |
| `hierarchy` | Spawn/dismiss child agents, adjust budgets |
| `local_execution` | Shell commands, MCP tools |

Some actions are always available regardless of groups: `wait`, `orient`, `todo`, `send_message`, `fetch_web`, `answer_engine`, `generate_images`, batch operations, and skill management.

Note that profile **names** and **descriptions** are visible to parent agents when they're deciding which profile to assign to a child. A well-named profile like "Cautious Researcher -- read-only analysis, no execution" helps the parent make better delegation decisions.

### 4. Create a Task

Back on the main dashboard, click **New Task**. The form has three sections:

**Agent Identity** (shapes the system prompt):
- **Profile** -- which consensus profile to use (see above)
- **Role** -- who the agent _is_ ("Senior DevOps Engineer", "Security Auditor")
- **Skills** -- comma-separated skill names to pre-load (see [Usage Tips](#usage-tips))
- **Cognitive Style** -- how the agent thinks: _Efficient_, _Exploratory_, _Problem Solving_, _Creative_, or _Systematic_
- **Output Style** -- response format: _Detailed_, _Concise_, _Technical_, or _Narrative_
- **Delegation Strategy** -- _Sequential_ or _Parallel_ child spawning
- **Global Constraints** -- hard rules enforced across the entire agent hierarchy
- **Global Context** -- project background shared with all agents

**Task Work** (shapes the user prompt):
- **Task Description** -- what the agent should accomplish (this is the only required field)
- **Success Criteria** -- how the agent knows it's done
- **Immediate Context** -- relevant situational information
- **Approach Guidance** -- methodology hints

**Budget** -- maximum spend in USD across all models for this task's entire agent tree.

Hit create, and the root agent will begin its first consensus cycle.

## Usage Tips

### Writing Good Profiles

The model pool is where most of the magic happens. A few things we've found:

- **Three models is the sweet spot.** Two can disagree with no tiebreaker. Four works but costs more without much benefit. Three gives you a clear majority.
- **Mix providers.** An all-OpenAI pool is just GPT with extra steps. Claude Sonnet + GPT + Gemini gives you genuinely different reasoning styles.
- **Match capability groups to the task.** Fewer available actions means a smaller decision space, which means fewer opportunities for the model to go sideways. A research agent that only reads the web doesn't need `local_execution`. A deployment agent does. Give agents exactly the capabilities they need and no more.
- **Create specialized profiles.** "Researcher" (read-only, no execution), "Builder" (full access), "Analyst" (external API + file read) -- then pick the right one per task.
- **Put thought into the name and description.** Parent agents see them when choosing which profile to give a child. "Careful Code Reviewer" and "Fast Prototyper" will lead to different delegation patterns even with identical capability groups.

### Using Skills

Skills are reusable knowledge files that get injected into an agent's system prompt. They live at `~/.quoracle/skills/`:

```
~/.quoracle/skills/
  deployment/
    SKILL.md          # required -- main skill content
    scripts/           # optional -- shell scripts referenced by the skill
    references/        # optional -- documentation, links
    assets/            # optional -- images, files
  code-review/
    SKILL.md
```

A `SKILL.md` is YAML frontmatter plus markdown:

```yaml
---
name: deployment
description: Production deployment procedures for our infrastructure
metadata:
  complexity: medium
---

# Deployment

## Steps
1. Validate configuration against schema
2. Run preflight checks
3. ...
```

Attach skills at task creation by listing them comma-separated in the **Skills** field. Agents can also learn additional skills at runtime via the `learn_skills` action. Think of skills as giving your agent a procedures manual rather than hoping it figures things out from scratch.

The format is compatible with skills from other agentic tools -- if you already have skill files from another framework, they should work here, though you may want to edit out any tool-specific instructions that don't apply.

### Prompting Well

The prompt fields map directly to how the LLM sees its instructions. A few patterns that work:

**Role** is the most impactful field. Be specific. "Software engineer" is vague; "Senior Python backend engineer specializing in async systems" gives the model a much clearer persona to adopt.

**Task Description + Success Criteria** work as a pair. The description says _what_, the criteria say _when you're done_. Vague criteria lead to agents that spin their wheels ("improve the codebase" vs. "all tests pass and coverage exceeds 80%").

**Cognitive Style** matters more than you'd think. _Systematic_ works well for multi-step procedures. _Exploratory_ is better for research tasks where you don't know exactly what you're looking for. _Problem Solving_ shines for debugging.

**Global Constraints** propagate to _every_ agent in the hierarchy, including children and grandchildren. Use them for hard rules: "Never modify files in the /prod directory", "All API calls must use HTTPS", "Budget per child must not exceed $0.50".

**Approach Guidance** is your chance to nudge the methodology without mandating it. "Consider using blue-green deployment" is a suggestion; putting it in constraints makes it a rule.

## Security

Quoracle stores API keys and secrets encrypted at rest using AES-256-GCM via [Cloak](https://hexdocs.pm/cloak_ecto). Sensitive values in action parameters (like `{{SECRET:my_api_key}}`) are resolved at execution time and scrubbed from results before they're fed back to the LLMs.

That said, there are important limitations.

### What Quoracle Does

- **Encrypts credentials and secrets at rest** -- AES-256-GCM, key derived from `CLOAK_ENCRYPTION_KEY`
- **Scrubs secrets from action results** -- API keys, auth headers, and secret values are stripped from results before models see them
- **Tags untrusted content** -- results from external sources (shell output, web fetches, API responses) are wrapped in `NO_EXECUTE` tags with cryptographically random IDs, making it difficult for injected instructions to escape their context
- **Multi-model consensus as a defense layer** -- prompt injection against a single model doesn't help if the other models in the pool disagree. A successful injection would need to compromise a _majority_ of models simultaneously, which is substantially harder. If you find a prompt injection that reliably defeats a multi-model profile, we'd consider that a bug -- please [report it](https://github.com/shelvick/quoracle/issues).
- **Enforces capability groups** -- agents can only execute actions their profile allows
- **Per-agent budgets** -- spending limits with escrow-based allocation to children
- **Secret templating** -- `{{SECRET:name}}` syntax keeps secrets out of prompt fields entirely

### What Quoracle Does _Not_ Do

- **No user authentication.** There is no login system. Anyone who can reach the web interface has full access to everything -- dashboard, settings, credentials. Quoracle assumes a single-user deployment or a trusted network.
- **No sandbox for shell execution.** The `execute_shell` action runs commands as the application's OS user. Capability groups gate _whether_ an agent can run commands, not _which_ commands.
- **No network isolation.** Agents with `external_api` or `fetch_web` can reach any endpoint the host machine can reach.

**The practical advice:** Run Quoracle in a VM or container where you're comfortable with the LLMs having the same access you'd give a junior developer you trust but want to keep an eye on. Don't expose the web interface to the public internet. Use capability groups to limit blast radius.

## Tech Rundown

### Agent Architecture

Agents are GenServers under a DynamicSupervisor. When an agent needs to execute an action, it spawns an ephemeral Router process for that specific action. The Router handles execution, returns the result, and terminates. This keeps action execution isolated -- one slow API call doesn't block another agent's shell command.

The agent itself has _zero_ hardcoded decision logic. It doesn't know what "deploy" means or how to "write code." It receives messages, asks its model pool what to do, and executes whatever consensus returns. All intelligence lives in the LLMs and the prompt fields you configure.

### Recursive Hierarchy

<p align="center">
  <img src="assets/static/images/agent-hierarchy.svg" alt="Agent Hierarchy" width="800"/>
</p>

Agents can spawn child agents via the `spawn_child` action. Children inherit their parent's global context and constraints, plus whatever new prompt fields the parent specifies. Communication flows through direct messages between parent and child. Budget is allocated from parent to child with escrow-based tracking.

### Persistence & Real-Time UI

Everything is persisted to PostgreSQL: tasks, agents, logs, messages, action results, costs. The LiveView dashboard subscribes to PubSub topics for real-time updates -- you see consensus decisions, action results, and inter-agent messages as they happen.

The dashboard has three panels: a task tree (left) showing the agent hierarchy, a log viewer (middle) with per-agent filtering, and a mailbox (right) for messages between you and your root agents.

### Consensus Pipeline

<p align="center">
  <img src="assets/static/images/consensus-pipeline.svg" alt="Consensus Pipeline" width="800"/>
</p>

When an agent needs to make a decision, here's what happens:

1. **Prompt building** -- the agent's prompt fields are assembled into a system prompt (identity, constraints, context) and a user prompt (task, criteria, situational info). Available actions are filtered by capability groups and serialized as a JSON schema.
2. **Parallel model query** -- every model in the pool receives the same prompt simultaneously via `Task.async`. Each model returns a candidate action with reasoning.
3. **Action parsing** -- responses are parsed into structured actions. Invalid or malformed responses are filtered out.
4. **Fingerprint clustering** -- similar actions are grouped. "spawn_child with role DevOps" from two models clusters together even if the exact phrasing differs.
5. **Winner selection** -- the largest cluster wins. Ties are broken by a multi-level scoring algorithm that considers action priority, wait parameters, and completion flags to select the most conservative option.
6. **Execution** -- an ephemeral Router process spawns to handle the action (API call, file op, shell command, etc.) and terminates when done.
7. **Loop** -- the result flows back as a message, and the agent enters its next consensus cycle.

### Per-Model Conversation History

Each model in the consensus pool maintains its own separate conversation history. There are a few reasons for this:

- **Context window utilization** -- different models have different context limits. Per-model history lets each model use its full window without being constrained by the smallest in the pool.
- **Independent condensation** -- models decide for themselves when and how to summarize their history, preserving what _they_ consider important.
- **Cross-model memory** -- when one model condenses away a detail that another model retained, the retained detail can still influence consensus. Models effectively remind each other of things the group might otherwise forget.

### Actions

Agents choose from a broad action set, gated by capability groups:

| Category | Actions |
|----------|---------|
| **Always available** | `wait`, `orient`, `todo`, `send_message`, `fetch_web`, `answer_engine`, `generate_images`, `batch_sync`, `batch_async`, `create_skill`, `learn_skills` |
| **File read** | `file_read` |
| **File write** | `file_write` |
| **External API** | `call_api` |
| **Hierarchy** | `spawn_child`, `dismiss_child`, `adjust_budget` |
| **Local execution** | `execute_shell`, `call_mcp` |

Batch operations (`batch_sync`, `batch_async`) let agents execute multiple actions in a single consensus cycle -- sequentially or in parallel. Skill management (`create_skill`, `learn_skills`) lets agents author and load reusable knowledge on the fly.

### PubSub Isolation

Every component receives its PubSub instance as an explicit parameter -- no global topics, no named processes, no process dictionary. This means the full test suite of 5600+ tests runs with `async: true`.

## Configuration Reference

All configuration is via environment variables. In development, these override the defaults in `config/dev.exs`. In production, all three "required" variables must be set.

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `DATABASE_URL` | yes | `ecto://postgres:postgres@localhost/quoracle_dev` (dev) | PostgreSQL connection URL |
| `SECRET_KEY_BASE` | yes | (from dev.exs in dev) | Phoenix session signing key. Generate with `openssl rand -base64 64 \| tr -d '\n'` |
| `CLOAK_ENCRYPTION_KEY` | yes | -- | AES-256-GCM encryption key for credentials/secrets. Generate with `openssl rand -base64 32` |
| `PHX_HOST` | no | `localhost` | Hostname for URL generation |
| `PORT` | no | `4000` | HTTP listen port |
| `POOL_SIZE` | no | `10` | Database connection pool size |
| `PHX_BIND_ADDRESS` | no | `127.0.0.1` | Listen address. Set to `0.0.0.0` for all interfaces (Docker sets this automatically) |
| `ECTO_IPV6` | no | -- | Set to `true` to enable IPv6 for database connections |

In development, `DATABASE_URL` and `SECRET_KEY_BASE` have sensible defaults and only need to be set if you want to override them. `CLOAK_ENCRYPTION_KEY` has no default -- the app starts without it, but credential storage won't work.

## Current Status

Quoracle should be considered **beta**. The core consensus pipeline, agent hierarchy, and action system are functional and well-tested, but the project is under active development.

Things that work well:
- Multi-model consensus with 3+ providers
- Recursive agent spawning and communication
- Real-time dashboard with full observability
- Credential encryption and secret management
- Capability-based action gating
- Persistent state with task restoration on restart

Known limitations:
- No user authentication (single-user assumption)
- No sandboxing for shell/file operations
- Multi-model consensus multiplies API costs and latency (every decision queries N models, and refinement rounds multiply that further)
- UX is a work in progress

If a particular feature or improvement is important to you, please [file an issue](https://github.com/shelvick/quoracle/issues).

## Contributing

Contributions are welcome. If you're thinking about a large change, please open an issue first so we can discuss the approach before you invest significant effort.

```bash
# Run the full test suite
mix test

# Code quality checks
mix format --check-formatted
mix credo --min-priority=high
mix dialyzer
```

All tests run with `async: true`. If you're adding new tests, please maintain this -- see the project's concurrency patterns in the test support modules for how we handle PubSub isolation, database sandboxing, and GenServer cleanup.

## License

Quoracle is licensed under the [GNU Affero General Public License v3.0](LICENSE).
