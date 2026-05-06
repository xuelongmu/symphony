# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls the configured tracker for candidate work
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During Linear app-server sessions, Symphony also serves a client-side `linear_graphql` tool so that
repo skills can make raw Linear GraphQL calls.

If a claimed issue moves to a configured terminal state (`Done`, `Closed`, `Cancelled`, or
`Duplicate` by default), Symphony stops the active agent for that issue and cleans up matching
workspaces.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Configure tracker credentials:
   - For Linear, get a personal token via Settings → Security & access → Personal API keys, and set
     it as the `LINEAR_API_KEY` environment variable.
   - For GitHub, set `GITHUB_TOKEN` to a token that can read/write repository issues and read/write
     the configured Projects v2 project.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL. This applies to `tracker.kind: linear`.
   - For GitHub, use `tracker.kind: github` and configure the repository plus the Projects v2
     project owner, project number, and status field. GitHub Issues alone only has `open` and
     `closed`; Symphony uses the configured Projects v2 Status field as the workflow state source.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Agent Review", "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

Run commands from `elixir/` unless the command uses `make -C elixir ...` from the repository root.

We recommend [mise](https://mise.jdx.dev/installing-mise.html) to manage the Elixir and Erlang
versions pinned by this repo. `mise install` reads [`mise.toml`](mise.toml) and installs the
required runtime.

Required tools:

- Git.
- Make. `mise` does not install Make for this repo; install it with your OS package manager.
- Elixir and Erlang, installed through `mise install`.
- Codex CLI if you want to run Symphony against real work, because the default workflow starts
  `codex app-server`.
- `LINEAR_API_KEY` when running against Linear.

Optional tools:

- Docker with Compose for the live SSH-worker E2E path. `make e2e` uses Docker when
  `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset.

### Install Host Tools

On macOS or Linux, install Git and Make with your normal package manager, then install
[`mise`](https://mise.jdx.dev/installing-mise.html):

```bash
curl https://mise.run | sh
```

On Windows, use [Scoop](https://scoop.sh/) from PowerShell:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
irm get.scoop.sh | iex
scoop install git make mise
```

Then install the pinned Elixir runtime:

```bash
cd elixir
mise trust
mise install
mise exec -- elixir --version
```

On Windows, make sure Git Bash is on `PATH`; Symphony starts Codex through `bash` during real runs.

### Verify

From the repository root:

```bash
git --version
make -C elixir help
elixir --version
erl -noshell -eval "erlang:display(erlang:system_info(otp_release)), halt()."
mix --version
```

If plain `elixir` or `mix` commands do not resolve, run commands through `mise exec -- ...` from
`elixir/`, or activate `mise` in your shell.

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix local.hex --force
mise exec -- mix local.rebar --force
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  ./WORKFLOW.md
```

On Windows, run the built escript with `escript`:

```powershell
mise exec -- escript .\bin\symphony `
  --i-understand-that-this-will-be-running-without-the-usual-guardrails `
  .\WORKFLOW.md
```

To enable the optional dashboard while Symphony runs:

```bash
./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --port 4000 \
  ./WORKFLOW.md
```

Then open `http://127.0.0.1:4000/`.

## Run Multiple Repositories With Cacophany

Use `cacophany` when you want one command to run several independent Symphony workflows and switch
between their dashboards from a small hub page. Each repository still owns its own `WORKFLOW.md`,
workspace root, tracker configuration, and lifecycle hooks.

Create a `CACOPHANY.yml` file:

```yaml
dashboard:
  port: 4100
workflows:
  - name: api
    workflow: C:/repos/api/WORKFLOW.md
    logs_root: C:/tmp/symphony-logs/api
    port: 4101
  - name: web
    workflow: C:/repos/web/WORKFLOW.md
    logs_root: C:/tmp/symphony-logs/web
    port: 4102
```

Start the launcher from `elixir/`:

```bash
./bin/symphony cacophany \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  /path/to/CACOPHANY.yml
```

Open `http://127.0.0.1:4100/` to switch between repo dashboards. The child dashboards remain
available directly on their configured ports.

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

The acknowledgement flag is required because this reference implementation starts Codex without
the usual product guardrails.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal Linear example:

```md
---
tracker:
  kind: linear
  project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a tracker issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
Agent role: {{ agent.role }}
```

Minimal GitHub Issues + Projects v2 example:

```md
---
tracker:
  kind: github
  owner: your-org
  repo: your-repo
  project_owner: your-org
  project_owner_type: organization
  project_number: 12
  project_status_field: Status
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Done
    - Closed
  api_key: $GITHUB_TOKEN
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on GitHub issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- `tracker.kind` supports `linear` and `github`. GitHub tracker mode uses a GitHub Projects v2
  Status field for workflow state and GitHub issue dependencies for `blocked_by`.
- For `tracker.kind: github`, configure `owner`, `repo`, `project_owner`,
  `project_owner_type`, `project_number`, `project_status_field`, `active_states`,
  `terminal_states`, and an API token through `api_key` or `GITHUB_TOKEN`.
  New workflows may instead use the nested `tracker.github.owner`, `tracker.github.repo`,
  `tracker.github.project_number`, and `tracker.github.status_field` keys; Symphony maps them
  onto the same runtime fields.
- GitHub Issues only has `open` and `closed`; the configured Projects v2 `project_status_field`
  value is the workflow state that Symphony compares against `active_states` and
  `terminal_states`.
- GitHub issue identifiers are emitted as route-safe single path segments such as
  `github-your-org-your-repo-123`; `issue.id` remains the raw GitHub issue number for API updates.
- `project_status_field` should name a Projects v2 single-select field, usually `Status`.
  Use `project_owner_type: user` for user-owned projects and `organization` for org-owned
  projects.
- GitHub tokens need Issues read/write on the repository and Projects v2 read/write access on the
  project owner. Classic personal access tokens use `read:project` for Projects v2 GraphQL queries
  and `project` for Projects v2 GraphQL mutations; fine-grained tokens should grant repository
  Issues read/write and project read/write access.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- `review.enabled` enables the automated `Agent Review` role/state loop. Review agents inspect and
  route PRs but do not make implementation changes.
- `review.max_rounds` caps automated review-agent dispatches before Symphony hands the issue to
  `Human Review`. Default: `3`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, agent role, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` for Linear or `GITHUB_TOKEN`/`GH_TOKEN` for GitHub
  when unset or when value is the matching `$VAR`.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

From the repository root, use:

```bash
make -C elixir all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
