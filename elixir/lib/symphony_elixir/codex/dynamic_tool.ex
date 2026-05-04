defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{Config, PathSafety}
  alias SymphonyElixir.GitHub.Client, as: GitHubClient
  alias SymphonyElixir.Linear.Client, as: LinearClient

  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @github_graphql_tool "github_graphql"
  @github_graphql_description """
  Execute a raw GraphQL query or mutation against GitHub using Symphony's configured auth.
  """
  @github_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against GitHub."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @sync_workpad_tool "sync_workpad"
  @sync_workpad_description """
  Create or update a persistent tracker workpad comment from a local markdown file.
  """
  @sync_workpad_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["file_path"],
    "properties" => %{
      "tracker" => %{
        "type" => "string",
        "enum" => ["github", "linear"],
        "description" => "Tracker to sync. Omit to infer from `issue_number` for GitHub or `issue_id` for Linear."
      },
      "file_path" => %{
        "type" => "string",
        "description" =>
          "Path to the local markdown file whose contents become the comment body. " <>
            "Relative paths are allowed only when Symphony provides an active workspace."
      },
      "issue_number" => %{
        "type" => ["integer", "string"],
        "description" => "GitHub issue number. Required for GitHub workpad sync."
      },
      "issue_id" => %{
        "type" => "string",
        "description" => "Linear issue identifier or internal UUID. Required for Linear workpad sync."
      },
      "owner" => %{
        "type" => "string",
        "description" => "GitHub repository owner. Defaults to tracker.owner from WORKFLOW.md when omitted."
      },
      "repo" => %{
        "type" => "string",
        "description" => "GitHub repository name. Defaults to tracker.repo from WORKFLOW.md when omitted."
      },
      "comment_id" => %{
        "type" => "string",
        "description" =>
          "Existing tracker comment ID to update. For GitHub, pass the issue comment node ID. " <>
            "Omit to create a new workpad comment."
      }
    }
  }

  @sync_workpad_allowed_keys ~w(tracker file_path issue_number issue_id owner repo comment_id)

  @linear_sync_workpad_create """
  mutation SymphonyLinearCreateWorkpad($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
      comment {
        id
        url
      }
    }
  }
  """

  @linear_sync_workpad_update """
  mutation SymphonyLinearUpdateWorkpad($id: String!, $body: String!) {
    commentUpdate(id: $id, input: {body: $body}) {
      success
      comment {
        id
        url
      }
    }
  }
  """

  @github_issue_node_query """
  query SymphonyGitHubIssueNode($owner: String!, $repo: String!, $number: Int!) {
    repository(owner: $owner, name: $repo) {
      issue(number: $number) {
        id
        number
        url
      }
    }
  }
  """

  @github_sync_workpad_create """
  mutation SymphonyGitHubCreateWorkpad($subjectId: ID!, $body: String!) {
    addComment(input: {subjectId: $subjectId, body: $body}) {
      commentEdge {
        node {
          id
          url
        }
      }
    }
  }
  """

  @github_sync_workpad_update """
  mutation SymphonyGitHubUpdateWorkpad($id: ID!, $body: String!) {
    updateIssueComment(input: {id: $id, body: $body}) {
      issueComment {
        id
        url
      }
    }
  }
  """

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @github_graphql_tool ->
        execute_github_graphql(arguments, opts)

      @sync_workpad_tool ->
        execute_sync_workpad(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      },
      %{
        "name" => @github_graphql_tool,
        "description" => @github_graphql_description,
        "inputSchema" => @github_graphql_input_schema
      },
      %{
        "name" => @sync_workpad_tool,
        "description" => @sync_workpad_description,
        "inputSchema" => @sync_workpad_input_schema
      }
    ]
  end

  defp execute_linear_graphql(arguments, opts) do
    execute_graphql(arguments, Keyword.get(opts, :linear_client, &LinearClient.graphql/3), @linear_graphql_tool)
  end

  defp execute_github_graphql(arguments, opts) do
    execute_graphql(arguments, Keyword.get(opts, :github_client, &GitHubClient.graphql/3), @github_graphql_tool)
  end

  defp execute_graphql(arguments, client, tool_name) do
    with {:ok, query, variables} <- normalize_graphql_arguments(arguments),
         {:ok, response} <- client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, {:graphql_arguments, reason}} ->
        failure_response(graphql_argument_error_payload(tool_name, reason))

      {:error, reason} ->
        failure_response(graphql_transport_error_payload(tool_name, reason))
    end
  end

  defp execute_sync_workpad(arguments, opts) do
    with {:ok, sync_args} <- normalize_sync_workpad_arguments(arguments),
         {:ok, body} <- read_workpad_file(sync_args.file_path, opts) do
      case sync_args.tracker do
        :github -> sync_github_workpad(sync_args, body, opts)
        :linear -> sync_linear_workpad(sync_args, body, opts)
      end
    else
      {:error, reason} ->
        failure_response(sync_workpad_error_payload(reason))
    end
  end

  defp sync_linear_workpad(sync_args, body, opts) do
    {query, variables} =
      case sync_args.comment_id do
        nil ->
          {@linear_sync_workpad_create, %{"issueId" => sync_args.issue_id, "body" => body}}

        comment_id ->
          {@linear_sync_workpad_update, %{"id" => comment_id, "body" => body}}
      end

    execute_linear_graphql(%{"query" => query, "variables" => variables}, opts)
  end

  defp sync_github_workpad(sync_args, body, opts) do
    github_client = Keyword.get(opts, :github_client, &GitHubClient.graphql/3)

    case sync_args.comment_id do
      nil ->
        sync_new_github_workpad(sync_args, body, opts, github_client)

      comment_id ->
        execute_graphql(
          %{
            "query" => @github_sync_workpad_update,
            "variables" => %{"id" => comment_id, "body" => body}
          },
          github_client,
          @github_graphql_tool
        )
    end
  end

  defp sync_new_github_workpad(sync_args, body, _opts, github_client) do
    with {:ok, owner, repo} <- resolve_github_repo(sync_args),
         {:ok, issue_node_id} <- fetch_github_issue_node_id(github_client, owner, repo, sync_args.issue_number) do
      execute_graphql(
        %{
          "query" => @github_sync_workpad_create,
          "variables" => %{"subjectId" => issue_node_id, "body" => body}
        },
        github_client,
        @github_graphql_tool
      )
    else
      {:error, {:github_issue_lookup_response, response}} ->
        graphql_response(response)

      {:error, {:github_issue_lookup_client, reason}} ->
        failure_response(graphql_transport_error_payload(@github_graphql_tool, reason))

      {:error, reason} ->
        failure_response(sync_workpad_error_payload(reason))
    end
  end

  defp fetch_github_issue_node_id(github_client, owner, repo, issue_number) do
    variables = %{"owner" => owner, "repo" => repo, "number" => issue_number}

    case github_client.(@github_issue_node_query, variables, []) do
      {:ok, response} ->
        cond do
          not graphql_success?(response) ->
            {:error, {:github_issue_lookup_response, response}}

          match?({:ok, _}, github_issue_node_id(response)) ->
            github_issue_node_id(response)

          true ->
            {:error, {:sync_workpad, "GitHub issue ##{issue_number} was not found in #{owner}/#{repo}."}}
        end

      {:error, reason} ->
        {:error, {:github_issue_lookup_client, reason}}
    end
  end

  defp github_issue_node_id(response) do
    case get_in(response, ["data", "repository", "issue", "id"]) do
      issue_node_id when is_binary(issue_node_id) ->
        case String.trim(issue_node_id) do
          "" -> :error
          trimmed -> {:ok, trimmed}
        end

      _ ->
        :error
    end
  end

  defp normalize_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, {:graphql_arguments, :missing_query}}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, {:graphql_arguments, reason}}
        end

      {:error, reason} ->
        {:error, {:graphql_arguments, reason}}
    end
  end

  defp normalize_graphql_arguments(_arguments), do: {:error, {:graphql_arguments, :invalid_arguments}}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp normalize_sync_workpad_arguments(arguments) when is_map(arguments) do
    with :ok <- validate_sync_workpad_keys(arguments),
         {:ok, file_path} <- required_sync_string(arguments, "file_path"),
         {:ok, tracker} <- infer_sync_workpad_tracker(arguments),
         {:ok, comment_id} <- optional_sync_string(arguments, "comment_id") do
      case tracker do
        :github -> normalize_github_sync_workpad(arguments, file_path, comment_id)
        :linear -> normalize_linear_sync_workpad(arguments, file_path, comment_id)
      end
    end
  end

  defp normalize_sync_workpad_arguments(_arguments) do
    {:error, {:sync_workpad, "`sync_workpad` expects an object argument."}}
  end

  defp validate_sync_workpad_keys(arguments) do
    unknown_keys =
      arguments
      |> Map.keys()
      |> Enum.map(&sync_key_name/1)
      |> Enum.reject(&(&1 in @sync_workpad_allowed_keys))
      |> Enum.sort()

    case unknown_keys do
      [] ->
        :ok

      keys ->
        formatted_keys = Enum.map_join(keys, ", ", &"`#{&1}`")
        {:error, {:sync_workpad, "unsupported argument(s): #{formatted_keys}."}}
    end
  end

  defp infer_sync_workpad_tracker(arguments) do
    tracker = sync_field(arguments, "tracker")
    has_issue_number? = sync_field_present?(arguments, "issue_number")
    has_issue_id? = sync_field_present?(arguments, "issue_id")

    case tracker do
      nil ->
        infer_sync_workpad_tracker_from_ids(has_issue_number?, has_issue_id?)

      tracker when is_binary(tracker) ->
        infer_sync_workpad_tracker_from_name(tracker)

      _ ->
        {:error, {:sync_workpad, "`tracker` must be either `github` or `linear`."}}
    end
  end

  defp infer_sync_workpad_tracker_from_ids(true, false), do: {:ok, :github}
  defp infer_sync_workpad_tracker_from_ids(false, true), do: {:ok, :linear}

  defp infer_sync_workpad_tracker_from_ids(true, true) do
    {:error, {:sync_workpad, "cannot infer tracker when both `issue_number` and `issue_id` are provided; set `tracker` to `github` or `linear`."}}
  end

  defp infer_sync_workpad_tracker_from_ids(false, false) do
    {:error, {:sync_workpad, "`issue_number` is required for GitHub sync or `issue_id` is required for Linear sync."}}
  end

  defp infer_sync_workpad_tracker_from_name(tracker) do
    case tracker |> String.trim() |> String.downcase() do
      "github" -> {:ok, :github}
      "linear" -> {:ok, :linear}
      _ -> {:error, {:sync_workpad, "`tracker` must be either `github` or `linear`."}}
    end
  end

  defp normalize_github_sync_workpad(arguments, file_path, comment_id) do
    with :ok <- reject_sync_field(arguments, "issue_id", "`issue_id` is only valid for Linear workpad sync."),
         {:ok, issue_number} <- required_issue_number(arguments),
         {:ok, owner} <- optional_sync_string(arguments, "owner"),
         {:ok, repo} <- optional_sync_string(arguments, "repo") do
      {:ok,
       %{
         tracker: :github,
         file_path: file_path,
         issue_number: issue_number,
         owner: owner,
         repo: repo,
         comment_id: comment_id
       }}
    end
  end

  defp normalize_linear_sync_workpad(arguments, file_path, comment_id) do
    with :ok <- reject_sync_field(arguments, "issue_number", "`issue_number` is only valid for GitHub workpad sync."),
         :ok <- reject_sync_field(arguments, "owner", "`owner` is only valid for GitHub workpad sync."),
         :ok <- reject_sync_field(arguments, "repo", "`repo` is only valid for GitHub workpad sync."),
         {:ok, issue_id} <- required_sync_string(arguments, "issue_id") do
      {:ok,
       %{
         tracker: :linear,
         file_path: file_path,
         issue_id: issue_id,
         comment_id: comment_id
       }}
    end
  end

  defp reject_sync_field(arguments, field, message) do
    if sync_field_present?(arguments, field) do
      {:error, {:sync_workpad, message}}
    else
      :ok
    end
  end

  defp required_sync_string(arguments, field) do
    case sync_field(arguments, field) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:sync_workpad, "`#{field}` is required."}}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, {:sync_workpad, "`#{field}` is required."}}
    end
  end

  defp optional_sync_string(arguments, field) do
    case sync_field(arguments, field) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:ok, nil}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, {:sync_workpad, "`#{field}` must be a string when provided."}}
    end
  end

  defp required_issue_number(arguments) do
    case sync_field(arguments, "issue_number") do
      value when is_integer(value) and value > 0 ->
        {:ok, value}

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {number, ""} when number > 0 -> {:ok, number}
          _ -> {:error, {:sync_workpad, "`issue_number` must be a positive integer."}}
        end

      _ ->
        {:error, {:sync_workpad, "`issue_number` must be a positive integer."}}
    end
  end

  defp sync_field(arguments, field) do
    Map.get(arguments, field) || Map.get(arguments, String.to_atom(field))
  end

  defp sync_field_present?(arguments, field) do
    case sync_field(arguments, field) do
      nil -> false
      value when is_binary(value) -> String.trim(value) != ""
      _ -> true
    end
  end

  defp sync_key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp sync_key_name(key), do: to_string(key)

  defp read_workpad_file(file_path, opts) do
    with {:ok, read_path} <- resolve_workpad_read_path(file_path, opts),
         {:ok, body} <- File.read(read_path) do
      case body do
        "" -> {:error, {:sync_workpad, "file is empty: `#{file_path}`."}}
        body -> {:ok, body}
      end
    else
      {:error, {:sync_workpad, _message} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, {:sync_workpad, "cannot read `#{file_path}`: #{:file.format_error(reason)}."}}
    end
  end

  defp resolve_workpad_read_path(file_path, opts) do
    cond do
      String.contains?(file_path, [<<0>>, "\n", "\r"]) ->
        {:error, {:sync_workpad, "`file_path` must not contain control characters."}}

      workspace = valid_workspace_opt(opts) ->
        resolve_workpad_read_path_in_workspace(file_path, workspace)

      Keyword.has_key?(opts, :workspace) ->
        {:error, {:sync_workpad, "`workspace` option must be a non-empty string when provided."}}

      Path.type(file_path) == :absolute ->
        canonicalize_workpad_path(file_path)

      true ->
        {:error, {:sync_workpad, "`file_path` must be absolute when no active workspace is configured."}}
    end
  end

  defp canonicalize_workpad_path(path) do
    case PathSafety.canonicalize(path) do
      {:ok, canonical_path} ->
        {:ok, canonical_path}

      {:error, {:path_canonicalize_failed, failed_path, reason}} ->
        {:error, {:sync_workpad, "cannot resolve `#{failed_path}`: #{inspect(reason)}."}}
    end
  end

  defp valid_workspace_opt(opts) do
    case Keyword.get(opts, :workspace) do
      workspace when is_binary(workspace) ->
        case String.trim(workspace) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp resolve_workpad_read_path_in_workspace(file_path, workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_path = Path.expand(file_path, expanded_workspace)

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_path} <- PathSafety.canonicalize(expanded_path) do
      if path_within?(canonical_path, canonical_workspace) do
        {:ok, canonical_path}
      else
        {:error, {:sync_workpad, "`file_path` must stay within the active workspace."}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:sync_workpad, "cannot resolve `#{path}`: #{inspect(reason)}."}}
    end
  end

  defp path_within?(path, root) do
    path_segments = comparable_path_segments(path)
    root_segments = comparable_path_segments(root)

    Enum.take(path_segments, length(root_segments)) == root_segments
  end

  defp comparable_path_segments(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> Enum.map(&comparable_path_segment/1)
  end

  defp comparable_path_segment(segment) do
    if match?({:win32, _}, :os.type()) do
      String.downcase(segment)
    else
      segment
    end
  end

  defp resolve_github_repo(sync_args) do
    owner = sync_args.owner || configured_github_value(:owner)
    repo = sync_args.repo || configured_github_value(:repo)

    cond do
      not present_string?(owner) ->
        {:error, {:sync_workpad, "GitHub `owner` is required for creating a workpad comment."}}

      not present_string?(repo) ->
        {:error, {:sync_workpad, "GitHub `repo` is required for creating a workpad comment."}}

      true ->
        {:ok, String.trim(owner), String.trim(repo)}
    end
  end

  defp configured_github_value(field) do
    Config.settings!().tracker
    |> Map.get(field)
    |> present_string_or_nil()
  rescue
    _ -> nil
  end

  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp present_string_or_nil(value) do
    if present_string?(value), do: String.trim(value)
  end

  defp graphql_response(response) do
    dynamic_tool_response(graphql_success?(response), encode_payload(response))
  end

  defp graphql_success?(response) do
    case response do
      %{"errors" => errors} when is_list(errors) and errors != [] -> false
      %{errors: errors} when is_list(errors) and errors != [] -> false
      _ -> true
    end
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp graphql_argument_error_payload(@linear_graphql_tool, :missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp graphql_argument_error_payload(@github_graphql_tool, :missing_query) do
    %{
      "error" => %{
        "message" => "`github_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp graphql_argument_error_payload(@linear_graphql_tool, :invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp graphql_argument_error_payload(@github_graphql_tool, :invalid_arguments) do
    %{
      "error" => %{
        "message" => "`github_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp graphql_argument_error_payload(@linear_graphql_tool, :invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp graphql_argument_error_payload(@github_graphql_tool, :invalid_variables) do
    %{
      "error" => %{
        "message" => "`github_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp graphql_transport_error_payload(@linear_graphql_tool, :missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp graphql_transport_error_payload(@github_graphql_tool, :missing_github_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing GitHub auth. Set `tracker.api_key` in `WORKFLOW.md` or export `GITHUB_TOKEN`."
      }
    }
  end

  defp graphql_transport_error_payload(@github_graphql_tool, :github_tracker_not_configured) do
    %{
      "error" => %{
        "message" => "`github_graphql` is available only when `tracker.kind` is `github`."
      }
    }
  end

  defp graphql_transport_error_payload(@github_graphql_tool, :missing_github_token) do
    graphql_transport_error_payload(@github_graphql_tool, :missing_github_api_token)
  end

  defp graphql_transport_error_payload(@github_graphql_tool, {:github_graphql_request, :missing_github_api_token}) do
    graphql_transport_error_payload(@github_graphql_tool, :missing_github_api_token)
  end

  defp graphql_transport_error_payload(@github_graphql_tool, {:github_graphql_request, :missing_github_token}) do
    graphql_transport_error_payload(@github_graphql_tool, :missing_github_api_token)
  end

  defp graphql_transport_error_payload(@github_graphql_tool, {:github_graphql_request, :github_tracker_not_configured}) do
    graphql_transport_error_payload(@github_graphql_tool, :github_tracker_not_configured)
  end

  defp graphql_transport_error_payload(@github_graphql_tool, {:github_api_request, :missing_github_api_token}) do
    graphql_transport_error_payload(@github_graphql_tool, :missing_github_api_token)
  end

  defp graphql_transport_error_payload(@github_graphql_tool, {:github_api_request, :github_tracker_not_configured}) do
    graphql_transport_error_payload(@github_graphql_tool, :github_tracker_not_configured)
  end

  defp graphql_transport_error_payload(@github_graphql_tool, {:github_graphql_errors, errors}) do
    %{"errors" => errors}
  end

  defp graphql_transport_error_payload(@linear_graphql_tool, {:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp graphql_transport_error_payload(@github_graphql_tool, {:github_api_status, status}) do
    %{
      "error" => %{
        "message" => "GitHub GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp graphql_transport_error_payload(@github_graphql_tool, {:github_graphql_status, status, body}) do
    %{
      "error" => %{
        "message" => "GitHub GraphQL request failed with HTTP #{status}.",
        "status" => status,
        "body" => body
      }
    }
  end

  defp graphql_transport_error_payload(@github_graphql_tool, {:github_graphql_status, status}) do
    graphql_transport_error_payload(@github_graphql_tool, {:github_api_status, status})
  end

  defp graphql_transport_error_payload(@linear_graphql_tool, {:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp graphql_transport_error_payload(@github_graphql_tool, {:github_api_request, reason}) do
    %{
      "error" => %{
        "message" => "GitHub GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp graphql_transport_error_payload(@github_graphql_tool, {:github_graphql_request, reason}) do
    graphql_transport_error_payload(@github_graphql_tool, {:github_api_request, reason})
  end

  defp graphql_transport_error_payload(@linear_graphql_tool, reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp graphql_transport_error_payload(@github_graphql_tool, reason) do
    %{
      "error" => %{
        "message" => "GitHub GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp sync_workpad_error_payload({:sync_workpad, message}) do
    %{
      "error" => %{
        "message" => "sync_workpad: #{message}"
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
