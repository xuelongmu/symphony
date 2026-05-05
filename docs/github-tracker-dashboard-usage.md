# GitHub Tracker And Dashboard Usage

This guide describes how to run Symphony against GitHub Issues plus GitHub Projects v2, and how to use the web dashboard to watch it work.

## What Symphony Watches

For GitHub, Symphony treats a GitHub Project v2 single-select field as the workflow state. GitHub issue `open` and `closed` are not enough because GitHub only has those two issue states.

A typical project setup is:

- `Backlog`: not handled by Symphony.
- `Ready`: queued for Symphony.
- `In progress`: work is underway or reserved.
- `In review`: work is done and waiting for review.
- `Done`: terminal state.

In the workflow config, `tracker.active_states` controls what project statuses Symphony may dispatch. To avoid taking over manually owned issues that are already `Ready` or `In progress`, also set `tracker.required_labels` to an explicit ownership label such as `symphony`.

If your GitHub Project uses an iteration planning field, `tracker.current_iteration` can gate intake for selected statuses. A common setup gates only `Ready` so Symphony picks up newly queued work only when the issue belongs to the current Project iteration, while already-started statuses can continue across iteration boundaries.

## GitHub Setup

Create or choose:

- A GitHub repository.
- A GitHub Project v2.
- A single-select project field, usually named `Status`.
- Optionally, an iteration project field, usually named `Iteration`.
- Status options matching your workflow, for example `Ready`, `In progress`, `In review`, and `Done`.

The GitHub token must be available as `GITHUB_TOKEN` or as `tracker.api_key` in `WORKFLOW.md`.

Required access:

- Repository Issues read/write.
- Project v2 read/write for the project owner.
- For classic tokens: `repo`, `read:project`, and `project`.
- For fine-grained tokens: repository Issues read/write plus project read/write access.

## Workflow File

Use a separate GitHub workflow file instead of editing the default Linear one while testing.

Example for the current `xuelongmu/symphony` fork:

```md
---
tracker:
  kind: github
  endpoint: https://api.github.com
  owner: xuelongmu
  repo: symphony
  project_owner: xuelongmu
  project_owner_type: user
  project_number: 1
  project_status_field: Status
  active_states:
    - Ready
  required_labels:
    - symphony
  current_iteration:
    field: Iteration
    states:
      - Ready
  terminal_states:
    - Done
    - Closed
  api_key: $GITHUB_TOKEN
polling:
  interval_ms: 5000
workspace:
  root: C:/tmp/symphony-github-workspaces
hooks:
  after_create: |
    git clone --depth 1 https://github.com/xuelongmu/symphony .
agent:
  max_concurrent_agents: 1
  max_turns: 5
codex:
  command: codex --config shell_environment_policy.inherit=all app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
---

You are working on GitHub issue {{ issue.identifier }}.

Issue number: {{ issue.id }}
Title: {{ issue.title }}
URL: {{ issue.url }}

Use the GitHub issue and project state as the source of truth.
Maintain a `## Codex Workpad` issue comment using `sync_workpad`.
Use `github_graphql` when GitHub issue or project data is needed.
Keep work scoped to the provided workspace.
```

Important fields:

- `tracker.kind: github` enables the GitHub adapter.
- `tracker.owner` and `tracker.repo` identify the issue repository.
- `tracker.project_owner`, `tracker.project_owner_type`, and `tracker.project_number` identify the Project v2 board.
- `tracker.project_status_field` names the single-select field Symphony reads.
- `tracker.active_states` controls what can be dispatched.
- `tracker.required_labels` optionally requires every listed label before an active issue can be dispatched.
- `tracker.current_iteration.field` names the Projects v2 iteration field used for intake gating.
- `tracker.current_iteration.states` lists active statuses that must be assigned to the current iteration before dispatch, typically `Ready`.
- `tracker.terminal_states` controls what counts as complete for cleanup.
- `issue.id` is the raw GitHub issue number.
- `issue.identifier` is a route-safe identifier such as `github-xuelongmu-symphony-12`.

## Start The Dashboard

From `elixir/`:

```powershell
Import-Module "$env:ChocolateyInstall\helpers\chocolateyProfile.psm1"
refreshenv | Out-Null

$env:Path = 'C:\Program Files\Git\bin;C:\Program Files\Git\usr\bin;' + $env:Path
$env:GITHUB_TOKEN = (gh auth token).Trim()

mix escript.build
escript .\bin\symphony `
  --i-understand-that-this-will-be-running-without-the-usual-guardrails `
  --port 4000 `
  C:\tmp\symphony-github-dashboard-WORKFLOW.md
```

The Git Bash path prefix matters on Windows. Symphony starts Codex through `bash`; putting Git Bash first avoids accidentally using WSL bash.

Open:

- Dashboard: `http://127.0.0.1:4000/`
- State API: `http://127.0.0.1:4000/api/v1/state`

Refresh is a POST endpoint:

```powershell
Invoke-RestMethod -Method Post http://127.0.0.1:4000/api/v1/refresh
```

Opening `/api/v1/refresh` directly in a browser sends `GET`, so it will not trigger a refresh.

## Running Work

To queue a real issue:

1. Create a GitHub issue in the configured repository.
2. Add the `symphony` label, if `tracker.required_labels` uses that recommended gate.
3. Add it to the configured Project v2.
4. Set its project `Status` to one of `tracker.active_states`, for example `Ready`.
5. If `tracker.current_iteration.states` includes that status, set the configured iteration field to the current iteration.
6. Wait for the next poll or call `POST /api/v1/refresh`.
7. Watch the dashboard.

When Symphony dispatches the issue, it:

- Creates a workspace under `workspace.root`.
- Uses the route-safe `issue.identifier` for workspace and dashboard identity.
- Runs `hooks.after_create`.
- Starts `codex app-server` in that workspace.
- Injects tracker context into the prompt.
- Makes `github_graphql` and `sync_workpad` available to the agent.

The dashboard shows:

- Active sessions.
- Current issue state.
- Direct tracker links for each session when available, including Linear issues, GitHub issues, or GitHub PRs.
- Session id.
- Stop controls for active sessions.
- Recent past sessions.
- Runtime and turn count.
- Latest Codex event.
- Token totals.
- Retry queue entries.

The per-issue JSON link uses:

```text
/api/v1/<issue.identifier>
```

For example:

```text
http://127.0.0.1:4000/api/v1/github-xuelongmu-symphony-12
```

## Workpad Comments

The agent can keep a GitHub issue comment synced from a workspace file:

```json
{
  "tracker": "github",
  "issue_number": 12,
  "owner": "xuelongmu",
  "repo": "symphony",
  "file_path": "workpad.md"
}
```

If `owner` and `repo` are omitted, Symphony uses the configured tracker repository.

To update an existing workpad comment, pass the GitHub issue comment node id as `comment_id`.

## Completion

Symphony keeps polling while an issue is in an active state. A workflow should define who moves the Project v2 status forward:

- Human-driven review loop: agent opens or updates a PR, syncs the workpad, and leaves the issue in `In review`.
- Fully automated loop: prompt the agent to use `github_graphql` to update the Project v2 item status when the quality bar is met.
- Manual cleanup: move the project item to `Done` yourself after reviewing the result.

When a GitHub issue reaches a terminal state such as `Done`, Symphony considers it complete for cleanup. If `update_issue_state/2` is used by Symphony internals, it updates both the Project v2 status and the GitHub issue open/closed state.

## Safe Local Operating Mode

For initial testing, use:

```yaml
tracker:
  active_states:
    - Ready
  required_labels:
    - symphony
  current_iteration:
    field: Iteration
    states:
      - Ready
agent:
  max_concurrent_agents: 1
```

Then label one disposable issue, assign it to the current iteration, and move it to `Ready`. This gives a controlled end-to-end run without picking up unrelated project items.

For a production board where humans also use `Ready` and `In progress`, use the label as the ownership gate:

```yaml
tracker:
  active_states:
    - Ready
    - In progress
  required_labels:
    - symphony
  current_iteration:
    field: Iteration
    states:
      - Ready
```

Issues without the `symphony` label remain manually owned even if their Project status is active. `Ready` issues outside the current iteration are skipped. `In progress` issues are not blocked by this example iteration gate, so in-flight work can continue when the calendar rolls over. If a running issue loses the required label, Symphony stops and releases its active worker on the next refresh.

For a busier production loop, broaden `active_states` only after the prompt and status transitions are reliable.

## Troubleshooting

No active sessions:

- Confirm the issue is in the configured Project v2.
- Confirm the project field name matches `tracker.project_status_field`.
- Confirm the field option is in `tracker.active_states`.
- If `tracker.required_labels` is set, confirm the issue has every required label.
- If `tracker.current_iteration.states` includes the issue status, confirm the configured iteration field is set to the current iteration.
- Call `POST /api/v1/refresh`.
- Check the terminal logs for GitHub API errors.

GitHub auth errors:

- Confirm `GITHUB_TOKEN` is set in the same shell that starts Symphony.
- Confirm token scopes include repository issue access and project access.
- Check `gh auth status` and `gh auth token`.

Dashboard opens but refresh URL looks wrong:

- Use `/` for the UI.
- Use `GET /api/v1/state` for JSON.
- Use `POST /api/v1/refresh` to request a refresh.

Codex does not start on Windows:

- Run `refreshenv`.
- Put Git Bash first in `PATH`.
- Verify:

```powershell
where.exe bash
bash -lc 'command -v codex; codex --version'
```

Endpoint confusion:

- `tracker.endpoint` can be `https://api.github.com` or `https://api.github.com/graphql`.
- GraphQL calls use `/graphql`.
- REST issue updates use `/repos/...`.

## Stop A Local Dashboard

Find the processes:

```powershell
Get-Process | Where-Object {
  $_.ProcessName -like '*powershell*' -or
  $_.ProcessName -like '*erl*' -or
  $_.ProcessName -like '*beam*'
} | Select-Object Id,ProcessName,StartTime,Path
```

Stop the wrapper PowerShell and Erlang VM:

```powershell
Stop-Process -Id <powershell-id>,<erl-id>
```
