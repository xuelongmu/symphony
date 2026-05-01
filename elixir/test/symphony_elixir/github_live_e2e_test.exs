defmodule SymphonyElixir.GitHubLiveE2ETest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Client, as: GitHubClient

  @moduletag :live_e2e
  @moduletag timeout: 600_000

  @result_file "LIVE_GITHUB_E2E_RESULT.txt"
  @default_owner "xuelongmu"
  @default_repo "symphony"

  @live_e2e_skip_reason (cond do
                           System.get_env("SYMPHONY_RUN_GITHUB_LIVE_E2E") != "1" ->
                             "set SYMPHONY_RUN_GITHUB_LIVE_E2E=1 to enable the real GitHub/Codex end-to-end test"

                           System.get_env("GITHUB_TOKEN") in [nil, ""] ->
                             "set GITHUB_TOKEN to enable the real GitHub/Codex end-to-end test"

                           true ->
                             nil
                         end)

  @project_query_user """
  query SymphonyGitHubLiveE2EProject($owner: String!, $number: Int!) {
    user(login: $owner) {
      projectV2(number: $number) {
        id
        fields(first: 50) {
          nodes {
            __typename
            ... on ProjectV2FieldCommon {
              id
              name
            }
            ... on ProjectV2SingleSelectField {
              options {
                id
                name
              }
            }
          }
        }
      }
    }
  }
  """

  @project_query_organization """
  query SymphonyGitHubLiveE2EProject($owner: String!, $number: Int!) {
    organization(login: $owner) {
      projectV2(number: $number) {
        id
        fields(first: 50) {
          nodes {
            __typename
            ... on ProjectV2FieldCommon {
              id
              name
            }
            ... on ProjectV2SingleSelectField {
              options {
                id
                name
              }
            }
          }
        }
      }
    }
  }
  """

  @add_project_item_mutation """
  mutation SymphonyGitHubLiveE2EAddProjectItem($projectId: ID!, $contentId: ID!) {
    addProjectV2ItemById(input: {projectId: $projectId, contentId: $contentId}) {
      item {
        id
      }
    }
  }
  """

  @update_project_status_mutation """
  mutation SymphonyGitHubLiveE2EUpdateProjectStatus($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
    updateProjectV2ItemFieldValue(input: {
      projectId: $projectId
      itemId: $itemId
      fieldId: $fieldId
      value: {singleSelectOptionId: $optionId}
    }) {
      projectV2Item {
        id
      }
    }
  }
  """

  @tag skip: @live_e2e_skip_reason
  test "creates a real GitHub issue and runs a local worker" do
    Application.ensure_all_started(:req)

    config = live_config!()
    run_id = "symphony-github-live-e2e-#{System.unique_integer([:positive])}"
    marker = "LIVE-GITHUB-E2E-#{run_id}"
    test_root = Path.join(System.tmp_dir!(), run_id)
    workflow_file = Path.join(test_root, "WORKFLOW.md")
    original_workflow_path = Workflow.workflow_file_path()
    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

    File.mkdir_p!(test_root)

    try do
      if is_pid(orchestrator_pid) do
        assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
      end

      Workflow.set_workflow_file_path(workflow_file)

      write_workflow_file!(workflow_file,
        tracker_kind: "github",
        tracker_api_token: "$GITHUB_TOKEN",
        tracker_owner: config.owner,
        tracker_repo: config.repo,
        tracker_project_owner: config.project_owner,
        tracker_project_owner_type: config.project_owner_type,
        tracker_project_number: config.project_number,
        tracker_project_status_field: "Status",
        tracker_active_states: ["Ready"],
        tracker_terminal_states: ["Done", "Closed"],
        workspace_root: Path.join(test_root, "workspaces"),
        max_concurrent_agents: 1,
        max_turns: 1,
        codex_command: config.codex_command,
        codex_approval_policy: "never",
        codex_turn_timeout_ms: 600_000,
        codex_stall_timeout_ms: 600_000,
        observability_enabled: false,
        prompt: live_prompt(config, marker)
      )

      project = fetch_project!(config)
      issue = create_issue!(config, run_id)
      Process.put(:github_live_e2e_issue_number, issue.number)

      item_id = add_issue_to_project!(project.project_id, issue.node_id)
      update_project_status!(project, item_id, "Ready")

      tracker_issue = wait_for_tracker_issue!(issue.number, "Ready")

      assert :ok = AgentRunner.run(tracker_issue, self(), max_turns: 1)

      runtime_info = receive_runtime_info!(to_string(issue.number))
      result_path = Path.join(runtime_info.workspace_path, @result_file)
      assert File.read!(result_path) == expected_result(config, issue.number, marker)
      assert eventually?(fn -> issue_has_marker_comment?(config, issue.number, marker) end)

      assert :ok = Tracker.update_issue_state(to_string(issue.number), "Done")

      assert %Issue{state: "Closed"} = wait_for_tracker_issue!(issue.number, "Closed")
    after
      cleanup_issue(config, Process.get(:github_live_e2e_issue_number))
      restart_orchestrator_if_needed()
      Workflow.set_workflow_file_path(original_workflow_path)
      File.rm_rf(test_root)
      Process.delete(:github_live_e2e_issue_number)
    end
  end

  defp live_config! do
    owner = System.get_env("SYMPHONY_LIVE_GITHUB_OWNER") || @default_owner
    repo = System.get_env("SYMPHONY_LIVE_GITHUB_REPO") || @default_repo

    %{
      owner: owner,
      repo: repo,
      project_owner: System.get_env("SYMPHONY_LIVE_GITHUB_PROJECT_OWNER") || owner,
      project_owner_type: System.get_env("SYMPHONY_LIVE_GITHUB_PROJECT_OWNER_TYPE") || "user",
      project_number: parse_project_number!(System.get_env("SYMPHONY_LIVE_GITHUB_PROJECT_NUMBER") || "1"),
      codex_command:
        System.get_env("SYMPHONY_LIVE_GITHUB_CODEX_COMMAND") ||
          "codex --config shell_environment_policy.inherit=all app-server"
    }
  end

  defp parse_project_number!(raw) do
    case Integer.parse(raw) do
      {number, ""} when number > 0 -> number
      _ -> flunk("expected SYMPHONY_LIVE_GITHUB_PROJECT_NUMBER to be a positive integer, got #{inspect(raw)}")
    end
  end

  defp live_prompt(config, marker) do
    """
    You are running a live GitHub Symphony worker smoke test for issue {{ issue.identifier }}.

    Do not modify the source repository. Do not create a pull request. Do not ask for input.

    Step 1: Create #{@result_file} by running this exact command:

    ```sh
    python -c "from pathlib import Path; Path('#{@result_file}').write_bytes(b'issue={{ issue.id }}\\nidentifier={{ issue.identifier }}\\nmarker=#{marker}\\n')"
    ```

    Step 2: Create workpad.md by running this exact command:

    ```sh
    python -c "from pathlib import Path; Path('workpad.md').write_text('## Codex Workpad\\n\\nLive GitHub worker smoke completed.\\n\\nmarker=#{marker}\\nissue={{ issue.identifier }}\\n', encoding='utf-8', newline='\\n')"
    ```

    Step 3: Use the sync_workpad tool to create a GitHub issue comment from workpad.md. Tool arguments: tracker github, issue_number {{ issue.id }}, owner #{config.owner}, repo #{config.repo}, file_path workpad.md.

    Step 4: Use the github_graphql tool once to query repository issue number {{ issue.id }} and confirm its title. Query repository owner #{config.owner} name #{config.repo} and issue number {{ issue.id }} with fields number, title, and state.

    Stop after the file exists, the workpad comment is synced, and the GitHub query succeeds. Do not change issue status; the test harness will do that.
    """
  end

  defp expected_result(config, issue_number, marker) do
    identifier = "github-#{config.owner}-#{config.repo}-#{issue_number}"
    "issue=#{issue_number}\nidentifier=#{identifier}\nmarker=#{marker}\n"
  end

  defp fetch_project!(config) do
    owner_key =
      case config.project_owner_type do
        "organization" -> "organization"
        "org" -> "organization"
        _ -> "user"
      end

    query = if owner_key == "organization", do: @project_query_organization, else: @project_query_user

    data =
      query
      |> graphql_data!(%{owner: config.project_owner, number: config.project_number})
      |> get_in([owner_key, "projectV2"])

    fields = get_in(data, ["fields", "nodes"]) || []

    status_field =
      Enum.find(fields, fn field ->
        field["name"] == "Status" and is_list(field["options"])
      end) || flunk("expected GitHub project to expose a Status single-select field")

    %{
      project_id: data["id"],
      status_field_id: status_field["id"],
      options: status_field["options"]
    }
  end

  defp create_issue!(config, run_id) do
    body = """
    Disposable issue created by Symphony's GitHub live E2E test.

    Run id: #{run_id}
    """

    case Req.post(
           "https://api.github.com/repos/#{config.owner}/#{config.repo}/issues",
           headers: rest_headers(),
           json: %{
             title: "Symphony GitHub live E2E #{run_id}",
             body: body,
             labels: ["github-tracker", "symphony"]
           },
           connect_options: [timeout: 30_000]
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        %{number: body["number"], node_id: body["node_id"]}

      other ->
        flunk("failed to create GitHub issue: #{inspect(other)}")
    end
  end

  defp add_issue_to_project!(project_id, issue_node_id) do
    @add_project_item_mutation
    |> graphql_data!(%{projectId: project_id, contentId: issue_node_id})
    |> get_in(["addProjectV2ItemById", "item", "id"])
    |> case do
      item_id when is_binary(item_id) -> item_id
      payload -> flunk("expected project item id, got #{inspect(payload)}")
    end
  end

  defp update_project_status!(project, item_id, status_name) do
    option =
      Enum.find(project.options, fn option -> option["name"] == status_name end) ||
        flunk("expected project Status option #{inspect(status_name)}")

    @update_project_status_mutation
    |> graphql_data!(%{
      projectId: project.project_id,
      itemId: item_id,
      fieldId: project.status_field_id,
      optionId: option["id"]
    })
    |> get_in(["updateProjectV2ItemFieldValue", "projectV2Item", "id"])
    |> case do
      ^item_id -> :ok
      payload -> flunk("expected updated project item id #{item_id}, got #{inspect(payload)}")
    end
  end

  defp issue_has_marker_comment?(config, issue_number, marker) do
    case Req.get(
           "https://api.github.com/repos/#{config.owner}/#{config.repo}/issues/#{issue_number}/comments",
           headers: rest_headers(),
           connect_options: [timeout: 30_000]
         ) do
      {:ok, %{status: 200, body: comments}} when is_list(comments) ->
        Enum.any?(comments, fn comment ->
          body = comment["body"]
          is_binary(body) and String.contains?(body, "## Codex Workpad") and String.contains?(body, marker)
        end)

      _ ->
        false
    end
  end

  defp cleanup_issue(_config, nil), do: :ok

  defp cleanup_issue(config, issue_number) do
    _ =
      Req.patch(
        "https://api.github.com/repos/#{config.owner}/#{config.repo}/issues/#{issue_number}",
        headers: rest_headers(),
        json: %{state: "closed", state_reason: "completed"},
        connect_options: [timeout: 30_000]
      )

    :ok
  end

  defp graphql_data!(query, variables) do
    case GitHubClient.graphql(query, variables) do
      {:ok, %{"data" => data}} when is_map(data) -> data
      {:ok, payload} -> flunk("GitHub GraphQL returned unexpected payload: #{inspect(payload)}")
      {:error, reason} -> flunk("GitHub GraphQL request failed: #{inspect(reason)}")
    end
  end

  defp rest_headers do
    [
      {"Authorization", "Bearer #{System.fetch_env!("GITHUB_TOKEN")}"},
      {"Accept", "application/vnd.github+json"},
      {"X-GitHub-Api-Version", "2022-11-28"}
    ]
  end

  defp receive_runtime_info!(issue_id) do
    receive do
      {:worker_runtime_info, ^issue_id, %{workspace_path: workspace_path} = runtime_info}
      when is_binary(workspace_path) ->
        runtime_info

      {:codex_worker_update, ^issue_id, _message} ->
        receive_runtime_info!(issue_id)
    after
      5_000 -> flunk("timed out waiting for worker runtime info for #{issue_id}")
    end
  end

  defp wait_for_tracker_issue!(issue_number, expected_state) do
    wait_for_tracker_issue!(issue_number, expected_state, System.monotonic_time(:millisecond) + 30_000)
  end

  defp wait_for_tracker_issue!(issue_number, expected_state, deadline_ms) do
    case Tracker.fetch_issue_states_by_ids([to_string(issue_number)]) do
      {:ok, [%Issue{state: ^expected_state} = issue | _]} ->
        issue

      result ->
        if System.monotonic_time(:millisecond) > deadline_ms do
          flunk("expected GitHub issue #{issue_number} to reach #{expected_state}, got #{inspect(result)}")
        else
          Process.sleep(1_000)
          wait_for_tracker_issue!(issue_number, expected_state, deadline_ms)
        end
    end
  end

  defp eventually?(fun) when is_function(fun, 0), do: eventually?(fun, System.monotonic_time(:millisecond) + 30_000)

  defp eventually?(fun, deadline_ms) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) > deadline_ms ->
        false

      true ->
        Process.sleep(1_000)
        eventually?(fun, deadline_ms)
    end
  end

  defp restart_orchestrator_if_needed do
    if is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
      case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, :running} -> :ok
      end
    end
  end
end
