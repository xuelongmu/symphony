defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  GitHub Issues and Projects v2 client for the tracker adapter.
  """

  require Logger
  alias SymphonyElixir.{Config, Tracker.Issue}

  @api_version "2026-03-10"
  @project_page_size 50
  @blocked_by_page_size 50
  @field_page_size 50
  @max_error_body_log_bytes 1_000

  @project_items_query_user """
  query SymphonyGitHubProjectItems($owner: String!, $number: Int!, $statusFieldName: String!, $first: Int!, $after: String, $blockedByFirst: Int!) {
    user(login: $owner) {
      projectV2(number: $number) {
        id
        items(first: $first, after: $after) {
          nodes {
            id
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
                      name
                      owner {
                        login
                      }
                    }
                  }
                  pageInfo {
                    hasNextPage
                    endCursor
                  }
                }
              }
              ... on PullRequest {
                id
                number
              }
            }
            fieldValueByName(name: $statusFieldName) {
              __typename
              ... on ProjectV2ItemFieldSingleSelectValue {
                name
                optionId
              }
            }
          }
          pageInfo {
            hasNextPage
            endCursor
          }
        }
      }
    }
  }
  """

  @project_items_query_organization """
  query SymphonyGitHubProjectItems($owner: String!, $number: Int!, $statusFieldName: String!, $first: Int!, $after: String, $blockedByFirst: Int!) {
    organization(login: $owner) {
      projectV2(number: $number) {
        id
        items(first: $first, after: $after) {
          nodes {
            id
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
                      name
                      owner {
                        login
                      }
                    }
                  }
                  pageInfo {
                    hasNextPage
                    endCursor
                  }
                }
              }
              ... on PullRequest {
                id
                number
              }
            }
            fieldValueByName(name: $statusFieldName) {
              __typename
              ... on ProjectV2ItemFieldSingleSelectValue {
                name
                optionId
              }
            }
          }
          pageInfo {
            hasNextPage
            endCursor
          }
        }
      }
    }
  }
  """

  @issue_blocked_by_query """
  query SymphonyGitHubIssueBlockers($issueId: ID!, $first: Int!, $after: String) {
    node(id: $issueId) {
      ... on Issue {
        blockedBy(first: $first, after: $after) {
          nodes {
            id
            number
            title
            state
            url
            repository {
              name
              owner {
                login
              }
            }
          }
          pageInfo {
            hasNextPage
            endCursor
          }
        }
      }
    }
  }
  """

  @project_fields_query_user """
  query SymphonyGitHubProjectFields($owner: String!, $number: Int!, $first: Int!, $after: String) {
    user(login: $owner) {
      projectV2(number: $number) {
        id
        fields(first: $first, after: $after) {
          nodes {
            __typename
            ... on ProjectV2FieldCommon {
              id
              name
              dataType
            }
            ... on ProjectV2SingleSelectField {
              options {
                id
                name
              }
            }
          }
          pageInfo {
            hasNextPage
            endCursor
          }
        }
      }
    }
  }
  """

  @project_fields_query_organization """
  query SymphonyGitHubProjectFields($owner: String!, $number: Int!, $first: Int!, $after: String) {
    organization(login: $owner) {
      projectV2(number: $number) {
        id
        fields(first: $first, after: $after) {
          nodes {
            __typename
            ... on ProjectV2FieldCommon {
              id
              name
              dataType
            }
            ... on ProjectV2SingleSelectField {
              options {
                id
                name
              }
            }
          }
          pageInfo {
            hasNextPage
            endCursor
          }
        }
      }
    }
  }
  """

  @update_project_status_mutation """
  mutation SymphonyGitHubUpdateProjectStatus($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
    updateProjectV2ItemFieldValue(input: {
      projectId: $projectId
      itemId: $itemId
      fieldId: $fieldId
      value: { singleSelectOptionId: $optionId }
    }) {
      projectV2Item {
        id
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    with :ok <- validate_tracker_settings(tracker),
         {:ok, issues} <- fetch_project_issues(&graphql/2) do
      {:ok, filter_issues_by_states(issues, tracker.active_states)}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    states =
      state_names
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if states == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker

      with :ok <- validate_tracker_settings(tracker),
           {:ok, issues} <- fetch_project_issues(&graphql/2) do
        {:ok, filter_issues_by_states(issues, states)}
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids =
      issue_ids
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if ids == [] do
      {:ok, []}
    else
      with :ok <- validate_tracker_settings(Config.settings!().tracker),
           {:ok, issues} <- fetch_project_issues(&graphql/2) do
        {:ok,
         issues
         |> Enum.filter(fn %Issue{id: id} -> id in ids end)
         |> sort_issues_by_requested_ids(issue_order_index(ids))}
      end
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    create_comment(issue_id, body, &request/5)
  end

  @spec patch_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def patch_issue_state(issue_id, state_name) when is_binary(issue_id) and is_binary(state_name) do
    patch_issue_state(issue_id, state_name, &request/5)
  end

  @spec resolve_status_update(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def resolve_status_update(issue_id, state_name) when is_binary(issue_id) and is_binary(state_name) do
    resolve_status_update(issue_id, state_name, &graphql/2)
  end

  @spec update_project_item_status(map()) :: :ok | {:error, term()}
  def update_project_item_status(%{
        project_id: project_id,
        item_id: item_id,
        field_id: field_id,
        option_id: option_id
      })
      when is_binary(project_id) and is_binary(item_id) and is_binary(field_id) and is_binary(option_id) do
    with {:ok, response} <-
           graphql(@update_project_status_mutation, %{
             projectId: project_id,
             itemId: item_id,
             fieldId: field_id,
             optionId: option_id
           }),
         updated_item_id when is_binary(updated_item_id) <-
           get_in(response, ["data", "updateProjectV2ItemFieldValue", "projectV2Item", "id"]) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_project_status_update_failed}
    end
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    payload = build_graphql_payload(query, variables, Keyword.get(opts, :operation_name))
    request_fun = Keyword.get(opts, :request_fun, &post_graphql_request/2)

    with {:ok, headers} <- github_headers(),
         {:ok, %{status: 200, body: body}} <- request_fun.(payload, headers),
         :ok <- reject_graphql_errors(body) do
      {:ok, body}
    else
      {:ok, response} ->
        status = response_status(response)
        error_body = summarize_error_body(response_body(response))

        Logger.error(
          "GitHub GraphQL request failed status=#{status}" <>
            github_error_context(payload, error_body)
        )

        {:error, {:github_graphql_status, status, error_body}}

      {:error, {:github_graphql_errors, errors}} ->
        Logger.error("GitHub GraphQL request failed errors=#{inspect(errors, limit: 20)}")
        {:error, {:github_graphql_errors, errors}}

      {:error, reason} ->
        Logger.error("GitHub GraphQL request failed: #{inspect(reason)}")
        {:error, {:github_graphql_request, reason}}
    end
  end

  @doc false
  @spec fetch_candidate_issues_for_test((String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues_for_test(graphql_fun) when is_function(graphql_fun, 2) do
    tracker = Config.settings!().tracker

    with :ok <- validate_tracker_settings(tracker),
         {:ok, issues} <- fetch_project_issues(graphql_fun) do
      {:ok, filter_issues_by_states(issues, tracker.active_states)}
    end
  end

  @doc false
  @spec fetch_issues_by_states_for_test([String.t()], (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states_for_test(states, graphql_fun)
      when is_list(states) and is_function(graphql_fun, 2) do
    with :ok <- validate_tracker_settings(Config.settings!().tracker),
         {:ok, issues} <- fetch_project_issues(graphql_fun) do
      {:ok, filter_issues_by_states(issues, states)}
    end
  end

  @doc false
  @spec fetch_issue_states_by_ids_for_test([String.t()], (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids_for_test(issue_ids, graphql_fun)
      when is_list(issue_ids) and is_function(graphql_fun, 2) do
    ids =
      issue_ids
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if ids == [] do
      {:ok, []}
    else
      with :ok <- validate_tracker_settings(Config.settings!().tracker),
           {:ok, issues} <- fetch_project_issues(graphql_fun) do
        {:ok,
         issues
         |> Enum.filter(fn %Issue{id: id} -> id in ids end)
         |> sort_issues_by_requested_ids(issue_order_index(ids))}
      end
    end
  end

  @doc false
  @spec resolve_status_update_for_test(
          String.t(),
          String.t(),
          (String.t(), map() -> {:ok, map()} | {:error, term()})
        ) :: {:ok, map()} | {:error, term()}
  def resolve_status_update_for_test(issue_id, state_name, graphql_fun)
      when is_binary(issue_id) and is_binary(state_name) and is_function(graphql_fun, 2) do
    resolve_status_update(issue_id, state_name, graphql_fun)
  end

  @doc false
  @spec create_comment_for_test(
          String.t(),
          String.t(),
          (atom(), String.t(), list(), map() | nil, keyword() -> {:ok, map()} | {:error, term()})
        ) :: :ok | {:error, term()}
  def create_comment_for_test(issue_id, body, request_fun)
      when is_binary(issue_id) and is_binary(body) and is_function(request_fun, 5) do
    create_comment(issue_id, body, request_fun)
  end

  @doc false
  @spec patch_issue_state_for_test(
          String.t(),
          String.t(),
          (atom(), String.t(), list(), map() | nil, keyword() -> {:ok, map()} | {:error, term()})
        ) :: :ok | {:error, term()}
  def patch_issue_state_for_test(issue_id, state_name, request_fun)
      when is_binary(issue_id) and is_binary(state_name) and is_function(request_fun, 5) do
    patch_issue_state(issue_id, state_name, request_fun)
  end

  @doc false
  @spec github_rest_url_for_test(String.t()) :: String.t()
  def github_rest_url_for_test(path) when is_binary(path), do: github_rest_url(path)

  @doc false
  @spec normalize_project_item_for_test(map(), map()) :: Issue.t() | nil
  def normalize_project_item_for_test(item, github_config) when is_map(item) and is_map(github_config) do
    tracker = %{
      owner: Map.get(github_config, :owner) || Map.get(github_config, "owner"),
      repo: Map.get(github_config, :repo) || Map.get(github_config, "repo"),
      terminal_states: Map.get(github_config, :terminal_states) || Map.get(github_config, "terminal_states") || ["Closed"]
    }

    normalize_project_item(item, tracker)
  end

  defp fetch_project_issues(graphql_fun) when is_function(graphql_fun, 2) do
    tracker = Config.settings!().tracker

    with {:ok, _project_id, items} <- fetch_project_items(graphql_fun),
         items <- filter_project_issue_items_for_repo(items, tracker),
         {:ok, items} <- hydrate_blocker_pages(items, graphql_fun) do
      issues =
        items
        |> Enum.map(&normalize_project_item(&1, tracker))
        |> Enum.reject(&is_nil/1)

      {:ok, issues}
    end
  end

  defp filter_project_issue_items_for_repo(items, tracker) when is_list(items) do
    Enum.filter(items, fn
      %{"content" => %{"__typename" => "Issue"} = issue} -> repository_matches?(issue, tracker)
      _ -> false
    end)
  end

  defp hydrate_blocker_pages(items, graphql_fun) when is_list(items) and is_function(graphql_fun, 2) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc_items} ->
      case hydrate_project_item_blockers(item, graphql_fun) do
        {:ok, hydrated_item} -> {:cont, {:ok, [hydrated_item | acc_items]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, hydrated_items} -> {:ok, Enum.reverse(hydrated_items)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp hydrate_project_item_blockers(
         %{"content" => %{"__typename" => "Issue", "id" => issue_id, "blockedBy" => blocked_by}} = item,
         graphql_fun
       )
       when is_binary(issue_id) and is_map(blocked_by) do
    blockers = Map.get(blocked_by, "nodes", [])

    with true <- is_list(blockers),
         {:ok, page_info} <- decode_blocker_page_info(blocked_by),
         {:ok, hydrated_blockers} <-
           fetch_remaining_blocker_pages(issue_id, page_info, graphql_fun, blockers) do
      {:ok, put_in(item, ["content", "blockedBy", "nodes"], hydrated_blockers)}
    else
      false -> {:error, :github_unknown_issue_blockers_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp hydrate_project_item_blockers(item, _graphql_fun), do: {:ok, item}

  defp fetch_remaining_blocker_pages(issue_id, page_info, graphql_fun, acc_blockers) do
    case next_page_cursor(page_info, :github_missing_blocked_by_end_cursor) do
      {:ok, next_cursor} ->
        do_fetch_blocker_page(issue_id, graphql_fun, next_cursor, acc_blockers)

      :done ->
        {:ok, acc_blockers}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_fetch_blocker_page(issue_id, graphql_fun, after_cursor, acc_blockers) do
    variables = %{
      issueId: issue_id,
      first: @blocked_by_page_size,
      after: after_cursor
    }

    with {:ok, body} <- graphql_fun.(@issue_blocked_by_query, variables),
         {:ok, blockers, page_info} <- decode_issue_blockers_response(body) do
      updated_blockers = acc_blockers ++ blockers

      case next_page_cursor(page_info, :github_missing_blocked_by_end_cursor) do
        {:ok, next_cursor} ->
          do_fetch_blocker_page(issue_id, graphql_fun, next_cursor, updated_blockers)

        :done ->
          {:ok, updated_blockers}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp fetch_project_items(graphql_fun) when is_function(graphql_fun, 2) do
    tracker = Config.settings!().tracker

    with :ok <- validate_tracker_settings(tracker),
         {:ok, owner_key, query} <- project_items_query(tracker.project_owner_type) do
      do_fetch_project_items_page(query, owner_key, tracker, graphql_fun, nil, nil, [])
    end
  end

  defp do_fetch_project_items_page(query, owner_key, tracker, graphql_fun, after_cursor, project_id, acc_items) do
    variables = %{
      owner: tracker.project_owner,
      number: tracker.project_number,
      statusFieldName: tracker.project_status_field,
      first: @project_page_size,
      blockedByFirst: @blocked_by_page_size,
      after: after_cursor
    }

    with {:ok, body} <- graphql_fun.(query, variables),
         {:ok, page_project_id, items, page_info} <- decode_project_items_response(body, owner_key) do
      updated_project_id = project_id || page_project_id
      updated_items = prepend_page_items(items, acc_items)

      case next_page_cursor(page_info, :github_missing_project_item_end_cursor) do
        {:ok, next_cursor} ->
          do_fetch_project_items_page(
            query,
            owner_key,
            tracker,
            graphql_fun,
            next_cursor,
            updated_project_id,
            updated_items
          )

        :done ->
          {:ok, updated_project_id, finalize_paginated_items(updated_items)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp fetch_project_status_field(graphql_fun) when is_function(graphql_fun, 2) do
    tracker = Config.settings!().tracker

    with :ok <- validate_tracker_settings(tracker),
         {:ok, owner_key, query} <- project_fields_query(tracker.project_owner_type),
         {:ok, project_id, fields} <-
           do_fetch_project_fields_page(query, owner_key, tracker, graphql_fun, nil, nil, []) do
      fields
      |> Enum.find(fn field -> normalized(field["name"]) == normalized(tracker.project_status_field) end)
      |> case do
        nil -> {:error, {:github_project_status_field_not_found, tracker.project_status_field}}
        field -> {:ok, %{project_id: project_id, field: field}}
      end
    end
  end

  defp do_fetch_project_fields_page(query, owner_key, tracker, graphql_fun, after_cursor, project_id, acc_fields) do
    variables = %{
      owner: tracker.project_owner,
      number: tracker.project_number,
      first: @field_page_size,
      after: after_cursor
    }

    with {:ok, body} <- graphql_fun.(query, variables),
         {:ok, page_project_id, fields, page_info} <- decode_project_fields_response(body, owner_key) do
      updated_project_id = project_id || page_project_id
      updated_fields = prepend_page_items(fields, acc_fields)

      case next_page_cursor(page_info, :github_missing_project_field_end_cursor) do
        {:ok, next_cursor} ->
          do_fetch_project_fields_page(
            query,
            owner_key,
            tracker,
            graphql_fun,
            next_cursor,
            updated_project_id,
            updated_fields
          )

        :done ->
          {:ok, updated_project_id, finalize_paginated_items(updated_fields)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp resolve_status_update(issue_id, state_name, graphql_fun) when is_function(graphql_fun, 2) do
    tracker = Config.settings!().tracker

    with {:ok, issue_number} <- parse_issue_number(issue_id),
         {:ok, %{project_id: project_id, field: field}} <- fetch_project_status_field(graphql_fun),
         {:ok, option_id} <- status_option_id(field, state_name),
         {:ok, _project_id, items} <- fetch_project_items(graphql_fun),
         {:ok, item_id} <- project_item_id_for_issue(items, issue_number, tracker) do
      {:ok,
       %{
         project_id: project_id,
         item_id: item_id,
         field_id: field["id"],
         option_id: option_id,
         state_name: state_name
       }}
    end
  end

  defp status_option_id(field, state_name) when is_map(field) do
    option =
      field
      |> Map.get("options", [])
      |> Enum.find(fn option -> normalized(option["name"]) == normalized(state_name) end)

    case option do
      %{"id" => option_id} when is_binary(option_id) ->
        {:ok, option_id}

      _ ->
        {:error, {:github_project_status_option_not_found, field["name"], state_name}}
    end
  end

  defp project_item_id_for_issue(items, issue_number, tracker) when is_list(items) and is_integer(issue_number) do
    items
    |> Enum.find(fn
      %{"id" => item_id, "content" => %{"__typename" => "Issue", "number" => number} = issue}
      when is_binary(item_id) ->
        number == issue_number and repository_matches?(issue, tracker)

      _ ->
        false
    end)
    |> case do
      %{"id" => item_id} -> {:ok, item_id}
      _ -> {:error, {:github_project_item_not_found, Integer.to_string(issue_number)}}
    end
  end

  defp create_comment(issue_id, body, request_fun) when is_function(request_fun, 5) do
    with {:ok, issue_number} <- parse_issue_number(issue_id),
         :ok <- validate_tracker_settings(Config.settings!().tracker),
         {:ok, %{status: 201}} <-
           request_fun.(
             :post,
             repository_issue_path(issue_number) <> "/comments",
             github_headers!(),
             %{"body" => body},
             []
           ) do
      :ok
    else
      {:ok, response} ->
        {:error, github_comment_create_status(response)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp github_comment_create_status(response) do
    {:github_comment_create_status, response_status(response), summarize_error_body(response_body(response))}
  end

  defp patch_issue_state(issue_id, state_name, request_fun) when is_function(request_fun, 5) do
    tracker = Config.settings!().tracker

    with {:ok, issue_number} <- parse_issue_number(issue_id),
         :ok <- validate_tracker_settings(tracker),
         {:ok, %{status: 200}} <-
           request_fun.(
             :patch,
             repository_issue_path(issue_number),
             github_headers!(),
             issue_state_patch_payload(state_name, tracker),
             []
           ) do
      :ok
    else
      {:ok, response} ->
        {:error, {:github_issue_patch_status, response_status(response), summarize_error_body(response_body(response))}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp issue_state_patch_payload(state_name, tracker) do
    if terminal_state?(state_name, tracker) do
      %{"state" => "closed", "state_reason" => closed_state_reason(state_name)}
    else
      %{"state" => "open", "state_reason" => "reopened"}
    end
  end

  defp closed_state_reason(state_name) do
    case normalized(state_name) do
      "duplicate" -> "duplicate"
      "cancelled" -> "not_planned"
      "canceled" -> "not_planned"
      "not planned" -> "not_planned"
      "not_planned" -> "not_planned"
      _ -> "completed"
    end
  end

  defp request(method, path, headers, json, params) do
    opts =
      [
        method: method,
        url: github_rest_url(path),
        headers: headers,
        connect_options: [timeout: 30_000]
      ]
      |> maybe_put_request_option(:json, json)
      |> maybe_put_request_option(:params, params)

    Req.request(opts)
  end

  defp maybe_put_request_option(opts, _key, nil), do: opts
  defp maybe_put_request_option(opts, _key, []), do: opts
  defp maybe_put_request_option(opts, key, value), do: Keyword.put(opts, key, value)

  defp repository_issue_path(issue_number) when is_integer(issue_number) do
    tracker = Config.settings!().tracker
    "/repos/#{path_segment(tracker.owner)}/#{path_segment(tracker.repo)}/issues/#{issue_number}"
  end

  defp github_rest_url(path) when is_binary(path) do
    endpoint =
      Config.settings!().tracker.endpoint
      |> rest_endpoint()

    endpoint <> path
  end

  defp rest_endpoint(endpoint) when is_binary(endpoint) do
    endpoint
    |> String.trim_trailing("/")
    |> String.replace_suffix("/graphql", "")
    |> String.trim_trailing("/")
  end

  defp issue_identifier(number, tracker) do
    case issue_number_id(number) do
      nil ->
        nil

      issue_id ->
        [
          "github",
          identifier_segment(tracker.owner),
          identifier_segment(tracker.repo),
          identifier_segment(issue_id)
        ]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("-")
    end
  end

  defp validate_tracker_settings(tracker) do
    cond do
      tracker.kind != "github" -> {:error, :github_tracker_not_configured}
      not is_binary(tracker.api_key) -> {:error, :missing_github_api_token}
      not is_binary(tracker.owner) -> {:error, :missing_github_owner}
      not is_binary(tracker.repo) -> {:error, :missing_github_repo}
      not is_binary(tracker.project_owner) -> {:error, :missing_github_project_owner}
      not is_integer(tracker.project_number) -> {:error, :missing_github_project_number}
      not is_binary(tracker.project_status_field) -> {:error, :missing_github_project_status_field}
      true -> :ok
    end
  end

  defp project_items_query(owner_type) do
    case normalized(owner_type || "user") do
      "user" -> {:ok, "user", @project_items_query_user}
      "organization" -> {:ok, "organization", @project_items_query_organization}
      "org" -> {:ok, "organization", @project_items_query_organization}
      other -> {:error, {:unsupported_github_project_owner_type, other}}
    end
  end

  defp project_fields_query(owner_type) do
    case normalized(owner_type || "user") do
      "user" -> {:ok, "user", @project_fields_query_user}
      "organization" -> {:ok, "organization", @project_fields_query_organization}
      "org" -> {:ok, "organization", @project_fields_query_organization}
      other -> {:error, {:unsupported_github_project_owner_type, other}}
    end
  end

  defp decode_project_items_response(%{"errors" => errors}, _owner_key), do: {:error, {:github_graphql_errors, errors}}

  defp decode_project_items_response(%{"data" => data}, owner_key) when is_map(data) do
    case get_in(data, [owner_key, "projectV2"]) do
      %{
        "id" => project_id,
        "items" => %{
          "nodes" => items,
          "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
        }
      }
      when is_list(items) ->
        {:ok, project_id, items, %{has_next_page: has_next_page == true, end_cursor: end_cursor}}

      nil ->
        {:error, :github_project_not_found}

      _ ->
        {:error, :github_unknown_project_items_payload}
    end
  end

  defp decode_project_items_response(_response, _owner_key), do: {:error, :github_unknown_project_items_payload}

  defp decode_issue_blockers_response(%{"errors" => errors}), do: {:error, {:github_graphql_errors, errors}}

  defp decode_issue_blockers_response(%{"data" => %{"node" => nil}}), do: {:error, :github_issue_not_found}

  defp decode_issue_blockers_response(%{"data" => %{"node" => %{"blockedBy" => blocked_by}}})
       when is_map(blocked_by) do
    case blocked_by do
      %{"nodes" => blockers} when is_list(blockers) ->
        with {:ok, page_info} <- decode_blocker_page_info(blocked_by) do
          {:ok, blockers, page_info}
        end

      _ ->
        {:error, :github_unknown_issue_blockers_payload}
    end
  end

  defp decode_issue_blockers_response(_response), do: {:error, :github_unknown_issue_blockers_payload}

  defp decode_project_fields_response(%{"errors" => errors}, _owner_key), do: {:error, {:github_graphql_errors, errors}}

  defp decode_project_fields_response(%{"data" => data}, owner_key) when is_map(data) do
    case get_in(data, [owner_key, "projectV2"]) do
      %{
        "id" => project_id,
        "fields" => %{
          "nodes" => fields,
          "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
        }
      }
      when is_list(fields) ->
        {:ok, project_id, fields, %{has_next_page: has_next_page == true, end_cursor: end_cursor}}

      nil ->
        {:error, :github_project_not_found}

      _ ->
        {:error, :github_unknown_project_fields_payload}
    end
  end

  defp decode_project_fields_response(_response, _owner_key), do: {:error, :github_unknown_project_fields_payload}

  defp decode_blocker_page_info(%{"pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}}) do
    {:ok, %{has_next_page: has_next_page == true, end_cursor: end_cursor}}
  end

  defp decode_blocker_page_info(_blocked_by), do: {:error, :github_unknown_issue_blockers_payload}

  defp normalize_project_item(%{"content" => %{"__typename" => "Issue"} = issue} = item, tracker) do
    if repository_matches?(issue, tracker) do
      number = issue["number"]
      status = project_status_name(item)
      assignees = assignee_logins(issue)

      %Issue{
        id: issue_number_id(number),
        identifier: issue_identifier(number, tracker),
        title: issue["title"],
        description: issue["body"],
        priority: nil,
        state: github_issue_state(issue, status, tracker),
        branch_name: nil,
        url: issue["url"],
        assignee_id: List.first(assignees),
        blocked_by: blocker_refs(issue, tracker),
        labels: label_names(issue),
        assigned_to_worker: true,
        created_at: parse_datetime(issue["createdAt"]),
        updated_at: parse_datetime(issue["updatedAt"])
      }
    end
  end

  defp normalize_project_item(_item, _tracker), do: nil

  defp repository_matches?(issue, tracker) do
    repository = issue["repository"] || %{}
    owner = get_in(repository, ["owner", "login"])
    repo = repository["name"]

    normalized(owner) == normalized(tracker.owner) and normalized(repo) == normalized(tracker.repo)
  end

  defp project_status_name(%{"fieldValueByName" => %{"name" => name}}) when is_binary(name), do: name
  defp project_status_name(_item), do: nil

  defp github_issue_state(issue, project_status, tracker) do
    if github_issue_closed?(issue) do
      closed_issue_state(tracker)
    else
      project_status
    end
  end

  defp github_issue_closed?(%{"state" => state}) when is_binary(state), do: normalized(state) == "closed"
  defp github_issue_closed?(_issue), do: false

  defp closed_issue_state(tracker) do
    Enum.find(tracker.terminal_states, &(normalized(&1) == "closed")) || "Closed"
  end

  defp terminal_state?(state_name, tracker) do
    terminal_states =
      tracker.terminal_states
      |> Enum.map(&normalized/1)
      |> MapSet.new()

    MapSet.member?(terminal_states, normalized(state_name))
  end

  defp filter_issues_by_states(issues, state_names) do
    wanted_states =
      state_names
      |> Enum.map(&normalized/1)
      |> Enum.reject(&(&1 == ""))
      |> MapSet.new()

    Enum.filter(issues, fn %Issue{state: state} ->
      MapSet.member?(wanted_states, normalized(state))
    end)
  end

  defp assignee_logins(%{"assignees" => %{"nodes" => assignees}}) when is_list(assignees) do
    assignees
    |> Enum.map(& &1["login"])
    |> Enum.reject(&is_nil/1)
  end

  defp assignee_logins(_issue), do: []

  defp label_names(%{"labels" => %{"nodes" => labels}}) when is_list(labels) do
    labels
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp label_names(_issue), do: []

  defp blocker_refs(%{"blockedBy" => %{"nodes" => blockers}}, tracker) when is_list(blockers) do
    Enum.map(blockers, fn blocker ->
      %{
        id: blocker["id"],
        identifier: blocker_identifier(blocker, tracker),
        title: blocker["title"],
        state: blocker_state(blocker, tracker),
        source: "github",
        url: blocker["url"]
      }
    end)
  end

  defp blocker_refs(_issue, _tracker), do: []

  defp blocker_identifier(%{"number" => number, "repository" => repository}, tracker) do
    owner = get_in(repository || %{}, ["owner", "login"]) || tracker.owner
    repo = (repository || %{})["name"] || tracker.repo

    case issue_number_id(number) do
      nil ->
        nil

      issue_id ->
        [
          "github",
          identifier_segment(owner),
          identifier_segment(repo),
          identifier_segment(issue_id)
        ]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("-")
    end
  end

  defp blocker_identifier(_blocker, _tracker), do: nil

  defp blocker_state(%{"state" => state}, tracker) when is_binary(state) do
    if normalized(state) == "closed", do: closed_issue_state(tracker), else: "Open"
  end

  defp blocker_state(_blocker, _tracker), do: nil

  defp issue_number_id(number) when is_integer(number), do: Integer.to_string(number)
  defp issue_number_id(number) when is_binary(number), do: number
  defp issue_number_id(_number), do: nil

  defp parse_issue_number(issue_id) when is_binary(issue_id) do
    normalized_issue_id =
      issue_id
      |> String.trim()
      |> String.trim_leading("#")

    case Integer.parse(normalized_issue_id) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> {:error, {:invalid_github_issue_number, issue_id}}
    end
  end

  defp issue_order_index(ids) when is_list(ids) do
    ids
    |> Enum.with_index()
    |> Map.new()
  end

  defp sort_issues_by_requested_ids(issues, issue_order_index)
       when is_list(issues) and is_map(issue_order_index) do
    fallback_index = map_size(issue_order_index)

    Enum.sort_by(issues, fn
      %Issue{id: issue_id} -> Map.get(issue_order_index, issue_id, fallback_index)
      _ -> fallback_index
    end)
  end

  defp prepend_page_items(items, acc_items) when is_list(items) and is_list(acc_items) do
    Enum.reverse(items, acc_items)
  end

  defp finalize_paginated_items(acc_items) when is_list(acc_items), do: Enum.reverse(acc_items)

  defp next_page_cursor(%{has_next_page: true, end_cursor: end_cursor}, _error)
       when is_binary(end_cursor) and byte_size(end_cursor) > 0 do
    {:ok, end_cursor}
  end

  defp next_page_cursor(%{has_next_page: true}, error), do: {:error, error}
  defp next_page_cursor(_page_info, _error), do: :done

  defp build_graphql_payload(query, variables, operation_name) do
    %{
      "query" => query,
      "variables" => variables
    }
    |> maybe_put_operation_name(operation_name)
  end

  defp maybe_put_operation_name(payload, operation_name) when is_binary(operation_name) do
    trimmed = String.trim(operation_name)

    if trimmed == "" do
      payload
    else
      Map.put(payload, "operationName", trimmed)
    end
  end

  defp maybe_put_operation_name(payload, _operation_name), do: payload

  defp reject_graphql_errors(%{"errors" => errors}), do: {:error, {:github_graphql_errors, errors}}
  defp reject_graphql_errors(_body), do: :ok

  defp github_error_context(payload, error_body) when is_map(payload) do
    operation_name =
      case Map.get(payload, "operationName") do
        name when is_binary(name) and name != "" -> " operation=#{name}"
        _ -> ""
      end

    operation_name <> " body=" <> error_body
  end

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

  defp github_headers do
    tracker = Config.settings!().tracker

    cond do
      tracker.kind != "github" ->
        {:error, :github_tracker_not_configured}

      is_nil(tracker.api_key) ->
        {:error, :missing_github_api_token}

      true ->
        {:ok,
         [
           {"Authorization", authorization_header(tracker.api_key)},
           {"Accept", "application/vnd.github+json"},
           {"Content-Type", "application/json"},
           {"X-GitHub-Api-Version", @api_version}
         ]}
    end
  end

  defp authorization_header(token) when is_binary(token) do
    if Regex.match?(~r/^(bearer|token)\s+/i, token) do
      token
    else
      "Bearer #{token}"
    end
  end

  defp github_headers! do
    case github_headers() do
      {:ok, headers} -> headers
      {:error, reason} -> raise ArgumentError, message: inspect(reason)
    end
  end

  defp post_graphql_request(payload, headers) do
    Req.post(graphql_endpoint(),
      headers: headers,
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  defp graphql_endpoint do
    endpoint =
      Config.settings!().tracker.endpoint
      |> String.trim_trailing("/")

    if String.ends_with?(endpoint, "/graphql") do
      endpoint
    else
      endpoint <> "/graphql"
    end
  end

  defp path_segment(value) when is_binary(value) do
    URI.encode(value, &URI.char_unreserved?/1)
  end

  defp identifier_segment(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9._~-]+/, "-")
    |> String.trim("-")
  end

  defp response_status(response) when is_map(response) do
    Map.get(response, :status)
  end

  defp response_body(response) when is_map(response) do
    Map.get(response, :body)
  end

  defp normalized(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalized(value), do: value |> to_string() |> normalized()

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end
end
