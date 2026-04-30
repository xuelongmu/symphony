defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  GitHub GraphQL client for polling project-backed issues.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue}

  @project_page_size 50
  @blocked_by_page_size 50
  @project_item_page_size 50
  @graphql_endpoint "https://api.github.com/graphql"
  @max_error_body_log_bytes 1_000

  @project_issues_query """
  query SymphonyGithubProjectIssues($owner: String!, $projectNumber: Int!, $first: Int!, $after: String, $statusField: String!, $blockedByFirst: Int!) {
    organization(login: $owner) {
      projectV2(number: $projectNumber) {
        ...SymphonyGithubProjectIssuePage
      }
    }
    user(login: $owner) {
      projectV2(number: $projectNumber) {
        ...SymphonyGithubProjectIssuePage
      }
    }
  }

  fragment SymphonyGithubProjectIssuePage on ProjectV2 {
    id
    items(first: $first, after: $after) {
      nodes {
        id
        fieldValueByName(name: $statusField) {
          ... on ProjectV2ItemFieldSingleSelectValue {
            name
          }
        }
        content {
          __typename
          ... on Issue {
            id
            number
            title
            body
            state
            url
            createdAt
            updatedAt
            repository {
              name
              nameWithOwner
              owner {
                login
              }
            }
            assignees(first: 10) {
              nodes {
                login
              }
            }
            labels(first: 50) {
              nodes {
                name
              }
            }
            blockedBy(first: $blockedByFirst) {
              nodes {
                id
                number
                title
                state
                url
                repository {
                  nameWithOwner
                }
              }
            }
          }
        }
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @project_status_query """
  query SymphonyGithubProjectStatus($owner: String!, $projectNumber: Int!) {
    organization(login: $owner) {
      projectV2(number: $projectNumber) {
        ...SymphonyGithubProjectStatusFields
      }
    }
    user(login: $owner) {
      projectV2(number: $projectNumber) {
        ...SymphonyGithubProjectStatusFields
      }
    }
  }

  fragment SymphonyGithubProjectStatusFields on ProjectV2 {
    id
    fields(first: 100) {
      nodes {
        __typename
        ... on ProjectV2SingleSelectField {
          id
          name
          options {
            id
            name
          }
        }
      }
    }
  }
  """

  @issue_project_items_query """
  query SymphonyGithubIssueProjectItems($issueId: ID!, $first: Int!) {
    node(id: $issueId) {
      ... on Issue {
        projectItems(first: $first) {
          nodes {
            id
            project {
              id
            }
          }
        }
      }
    }
  }
  """

  @add_comment_mutation """
  mutation SymphonyGithubAddComment($subjectId: ID!, $body: String!) {
    addComment(input: {subjectId: $subjectId, body: $body}) {
      commentEdge {
        node {
          id
        }
      }
    }
  }
  """

  @update_project_status_mutation """
  mutation SymphonyGithubUpdateIssueStatus($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
    updateProjectV2ItemFieldValue(
      input: {
        projectId: $projectId,
        itemId: $itemId,
        fieldId: $fieldId,
        value: {singleSelectOptionId: $optionId}
      }
    ) {
      projectV2Item {
        id
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    fetch_issues_by_states(Config.settings!().tracker.active_states)
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> Enum.reject(&(&1 == ""))
      |> MapSet.new()

    if MapSet.size(normalized_states) == 0 do
      {:ok, []}
    else
      with {:ok, issues} <- fetch_project_issues() do
        {:ok,
         Enum.filter(issues, fn %Issue{state: state} ->
           MapSet.member?(normalized_states, normalize_state(state))
         end)}
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    wanted_ids =
      issue_ids
      |> Enum.uniq()
      |> MapSet.new()

    if MapSet.size(wanted_ids) == 0 do
      {:ok, []}
    else
      with {:ok, issues} <- fetch_project_issues() do
        {:ok,
         Enum.filter(issues, fn %Issue{id: id} ->
           MapSet.member?(wanted_ids, id)
         end)}
      end
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- graphql(@add_comment_mutation, %{subjectId: issue_id, body: body}),
         comment_id when is_binary(comment_id) <-
           get_in(response, ["data", "addComment", "commentEdge", "node", "id"]) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_comment_create_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, status_context} <- resolve_project_status_context(),
         {:ok, item_id} <- resolve_issue_project_item_id(issue_id, status_context.project_id),
         {:ok, option_id} <- status_option_id(status_context.options, state_name),
         {:ok, response} <-
           graphql(@update_project_status_mutation, %{
             projectId: status_context.project_id,
             itemId: item_id,
             fieldId: status_context.field_id,
             optionId: option_id
           }),
         project_item_id when is_binary(project_item_id) <-
           get_in(response, ["data", "updateProjectV2ItemFieldValue", "projectV2Item", "id"]) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_issue_update_failed}
    end
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    payload = %{"query" => query, "variables" => variables}
    request_fun = Keyword.get(opts, :request_fun, &post_graphql_request/2)

    with {:ok, headers} <- graphql_headers(),
         {:ok, %{status: 200, body: body}} <- request_fun.(payload, headers) do
      {:ok, body}
    else
      {:ok, response} ->
        Logger.error("GitHub GraphQL request failed status=#{response.status} body=#{summarize_error_body(response.body)}")

        {:error, {:github_api_status, response.status}}

      {:error, reason} ->
        Logger.error("GitHub GraphQL request failed: #{inspect(reason)}")
        {:error, {:github_api_request, reason}}
    end
  end

  @doc false
  @spec normalize_project_item_for_test(map(), map()) :: Issue.t() | nil
  def normalize_project_item_for_test(item, github_config) when is_map(item) and is_map(github_config) do
    normalize_project_item(item, github_config, nil)
  end

  @doc false
  @spec fetch_issues_by_states_for_test([String.t()], (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states_for_test(state_names, graphql_fun)
      when is_list(state_names) and is_function(graphql_fun, 2) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    with {:ok, issues} <- fetch_project_issues(graphql_fun) do
      {:ok,
       Enum.filter(issues, fn %Issue{state: state} ->
         MapSet.member?(normalized_states, normalize_state(state))
       end)}
    end
  end

  defp fetch_project_issues(graphql_fun \\ &graphql/2) when is_function(graphql_fun, 2) do
    github = Config.settings!().tracker.github
    do_fetch_project_issue_page(github, graphql_fun, nil, [])
  end

  defp do_fetch_project_issue_page(github, graphql_fun, after_cursor, acc_issues) do
    with {:ok, body} <-
           graphql_fun.(@project_issues_query, %{
             owner: github.owner,
             projectNumber: github.project_number,
             first: @project_page_size,
             after: after_cursor,
             statusField: github.status_field,
             blockedByFirst: @blocked_by_page_size
           }),
         {:ok, issues, page_info} <- decode_project_issue_page(body, github) do
      updated_acc = Enum.reverse(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} -> do_fetch_project_issue_page(github, graphql_fun, next_cursor, updated_acc)
        :done -> {:ok, Enum.reverse(updated_acc)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp decode_project_issue_page(body, github) when is_map(body) do
    with {:ok, project} <- project_from_body(body),
         %{"items" => %{"nodes" => nodes, "pageInfo" => page_info}} <- project do
      issues =
        nodes
        |> Enum.map(&normalize_project_item(&1, github, Config.settings!().tracker.assignee))
        |> Enum.reject(&is_nil/1)

      {:ok, issues, page_info}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_project_unknown_payload}
    end
  end

  defp project_from_body(%{"errors" => errors}), do: {:error, {:github_graphql_errors, errors}}

  defp project_from_body(%{"data" => data}) when is_map(data) do
    project =
      get_in(data, ["organization", "projectV2"]) ||
        get_in(data, ["user", "projectV2"])

    case project do
      %{} = project -> {:ok, project}
      _ -> {:error, :github_project_not_found}
    end
  end

  defp project_from_body(_body), do: {:error, :github_project_unknown_payload}

  defp normalize_project_item(
         %{"content" => %{"__typename" => "Issue"} = issue} = item,
         github,
         configured_assignee
       ) do
    if repository_matches?(issue, github) do
      assignees = assignee_logins(issue)

      %Issue{
        id: issue["id"],
        identifier: github_issue_identifier(issue),
        title: issue["title"],
        description: issue["body"],
        priority: nil,
        state: project_item_state(item, issue),
        branch_name: nil,
        url: issue["url"],
        assignee_id: List.first(assignees),
        blocked_by: extract_blockers(issue),
        labels: extract_labels(issue),
        assigned_to_worker: assigned_to_worker?(assignees, configured_assignee),
        created_at: parse_datetime(issue["createdAt"]),
        updated_at: parse_datetime(issue["updatedAt"])
      }
    end
  end

  defp normalize_project_item(_item, _github, _configured_assignee), do: nil

  defp repository_matches?(issue, github) do
    repo_name = get_in(issue, ["repository", "name"])
    owner_login = get_in(issue, ["repository", "owner", "login"])

    repo_name == github.repo and normalize_state(owner_login) == normalize_state(github.owner)
  end

  defp project_item_state(%{"fieldValueByName" => %{"name" => state_name}}, _issue)
       when is_binary(state_name) do
    state_name
  end

  defp project_item_state(_item, issue), do: github_issue_state_to_tracker_state(issue["state"])

  defp github_issue_identifier(issue) do
    name_with_owner = get_in(issue, ["repository", "nameWithOwner"]) || "github"

    case issue["number"] do
      number when is_integer(number) -> name_with_owner <> "#" <> Integer.to_string(number)
      number when is_binary(number) -> name_with_owner <> "#" <> number
      _ -> issue["id"]
    end
  end

  defp extract_labels(%{"labels" => %{"nodes" => labels}}) when is_list(labels) do
    labels
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_labels(_issue), do: []

  defp assignee_logins(%{"assignees" => %{"nodes" => assignees}}) when is_list(assignees) do
    assignees
    |> Enum.map(& &1["login"])
    |> Enum.filter(&is_binary/1)
  end

  defp assignee_logins(_issue), do: []

  defp assigned_to_worker?(_assignees, nil), do: true

  defp assigned_to_worker?(assignees, configured_assignee) when is_binary(configured_assignee) do
    normalized_assignee = normalize_state(configured_assignee)

    Enum.any?(assignees, fn assignee ->
      normalize_state(assignee) == normalized_assignee
    end)
  end

  defp assigned_to_worker?(_assignees, _configured_assignee), do: false

  defp extract_blockers(%{"blockedBy" => %{"nodes" => blockers}}) when is_list(blockers) do
    Enum.map(blockers, fn blocker ->
      %{
        id: blocker["id"],
        identifier: github_issue_identifier(blocker),
        state: github_issue_state_to_tracker_state(blocker["state"]),
        source: "github",
        url: blocker["url"]
      }
    end)
  end

  defp extract_blockers(_issue), do: []

  defp github_issue_state_to_tracker_state("CLOSED"), do: "Closed"
  defp github_issue_state_to_tracker_state("OPEN"), do: "Open"
  defp github_issue_state_to_tracker_state(state) when is_binary(state), do: state
  defp github_issue_state_to_tracker_state(_state), do: nil

  defp resolve_project_status_context(graphql_fun \\ &graphql/2) when is_function(graphql_fun, 2) do
    github = Config.settings!().tracker.github

    with {:ok, body} <-
           graphql_fun.(@project_status_query, %{
             owner: github.owner,
             projectNumber: github.project_number
           }),
         {:ok, project} <- project_from_body(body),
         {:ok, field} <- status_field(project, github.status_field) do
      {:ok,
       %{
         project_id: project["id"],
         field_id: field["id"],
         options: field["options"] || []
       }}
    end
  end

  defp status_field(%{"fields" => %{"nodes" => fields}}, status_field_name) when is_list(fields) do
    case Enum.find(fields, &status_field_match?(&1, status_field_name)) do
      %{} = field -> {:ok, field}
      _ -> {:error, :github_status_field_not_found}
    end
  end

  defp status_field(_project, _status_field_name), do: {:error, :github_status_field_not_found}

  defp status_field_match?(
         %{"__typename" => "ProjectV2SingleSelectField", "name" => name},
         status_field_name
       )
       when is_binary(name) do
    normalize_state(name) == normalize_state(status_field_name)
  end

  defp status_field_match?(_field, _status_field_name), do: false

  defp status_option_id(options, state_name) when is_list(options) do
    case Enum.find(options, fn
           %{"name" => option_name} when is_binary(option_name) ->
             normalize_state(option_name) == normalize_state(state_name)

           _ ->
             false
         end) do
      %{"id" => option_id} when is_binary(option_id) -> {:ok, option_id}
      _ -> {:error, :github_status_option_not_found}
    end
  end

  defp resolve_issue_project_item_id(issue_id, project_id, graphql_fun \\ &graphql/2)
       when is_binary(issue_id) and is_binary(project_id) and is_function(graphql_fun, 2) do
    with {:ok, body} <-
           graphql_fun.(@issue_project_items_query, %{
             issueId: issue_id,
             first: @project_item_page_size
           }) do
      decode_issue_project_item_id(body, project_id)
    end
  end

  defp decode_issue_project_item_id(
         %{"data" => %{"node" => %{"projectItems" => %{"nodes" => items}}}},
         project_id
       )
       when is_list(items) do
    case Enum.find(items, fn
           %{"project" => %{"id" => ^project_id}} -> true
           _ -> false
         end) do
      %{"id" => item_id} when is_binary(item_id) -> {:ok, item_id}
      _ -> {:error, :github_project_item_not_found}
    end
  end

  defp decode_issue_project_item_id(%{"errors" => errors}, _project_id),
    do: {:error, {:github_graphql_errors, errors}}

  defp decode_issue_project_item_id(_body, _project_id), do: {:error, :github_project_item_not_found}

  defp next_page_cursor(%{"hasNextPage" => true, "endCursor" => cursor})
       when is_binary(cursor) and cursor != "" do
    {:ok, cursor}
  end

  defp next_page_cursor(%{"hasNextPage" => true}), do: {:error, :github_missing_end_cursor}
  defp next_page_cursor(%{"hasNextPage" => false}), do: :done
  defp next_page_cursor(_page_info), do: {:error, :github_invalid_page_info}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp graphql_headers do
    case Config.settings!().tracker.api_key do
      nil ->
        {:error, :missing_github_api_token}

      token ->
        {:ok,
         [
           {"Authorization", "Bearer " <> token},
           {"Accept", "application/vnd.github+json"},
           {"Content-Type", "application/json"},
           {"X-GitHub-Api-Version", "2022-11-28"}
         ]}
    end
  end

  defp post_graphql_request(payload, headers) do
    Req.post(@graphql_endpoint,
      headers: headers,
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  defp normalize_state(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_value), do: ""

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end
end
