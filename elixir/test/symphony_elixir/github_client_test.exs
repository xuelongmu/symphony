defmodule SymphonyElixir.GitHubClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Client, as: GitHubClient

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_endpoint: "https://api.github.test",
      tracker_api_token: "github-token",
      tracker_owner: "xuelongmu",
      tracker_repo: "symphony",
      tracker_project_owner: "xuelongmu",
      tracker_project_owner_type: "user",
      tracker_project_number: 1,
      tracker_project_status_field: "Status",
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Closed", "Done"]
    )

    :ok
  end

  test "fetches candidate issues from paginated project items and excludes pull requests" do
    graphql_fun = fn query, variables ->
      send(self(), {:project_items_query, query, variables})

      case variables.after do
        nil ->
          {:ok,
           project_items_response(
             [
               project_issue_item(%{
                 item_id: "item-1",
                 number: 1,
                 title: "Open todo",
                 status: "Todo",
                 state: "OPEN",
                 labels: ["Backend"],
                 assignees: ["alice"],
                 blocked_by: [%{number: 99, title: "Blocking issue", state: "OPEN"}]
               }),
               project_pull_request_item(%{item_id: "item-pr", number: 2, status: "Todo"}),
               project_issue_item(%{
                 item_id: "item-3",
                 number: 3,
                 title: "Closed but stale",
                 status: "Todo",
                 state: "CLOSED"
               })
             ],
             has_next_page: true,
             end_cursor: "cursor-1"
           )}

        "cursor-1" ->
          {:ok,
           project_items_response(
             [
               project_issue_item(%{
                 item_id: "item-4",
                 number: 4,
                 title: "Second page",
                 status: "In Progress",
                 state: "OPEN"
               }),
               project_issue_item(%{
                 item_id: "item-other-repo",
                 number: 5,
                 title: "Other repo",
                 status: "Todo",
                 state: "OPEN",
                 repo: "elsewhere"
               })
             ],
             has_next_page: false,
             end_cursor: nil
           )}
      end
    end

    assert {:ok, issues} = GitHubClient.fetch_candidate_issues_for_test(graphql_fun)

    assert Enum.map(issues, & &1.id) == ["1", "4"]
    assert Enum.map(issues, & &1.identifier) == ["github-xuelongmu-symphony-1", "github-xuelongmu-symphony-4"]
    refute Enum.any?(issues, &String.contains?(&1.identifier, ["/", "#", "?"]))
    assert Enum.map(issues, & &1.state) == ["Todo", "In Progress"]

    first_issue = hd(issues)
    assert first_issue.labels == ["backend"]
    assert first_issue.assignee_id == "alice"
    assert first_issue.url == "https://github.com/xuelongmu/symphony/issues/1"

    assert first_issue.blocked_by == [
             %{
               id: "blocker-node-99",
               identifier: "github-xuelongmu-symphony-99",
               title: "Blocking issue",
               state: "Open",
               source: "github",
               url: "https://github.com/xuelongmu/symphony/issues/99"
             }
           ]

    assert first_issue.created_at == ~U[2026-01-01 00:00:00Z]
    assert first_issue.updated_at == ~U[2026-01-02 00:00:00Z]

    assert_receive {:project_items_query, query, %{after: nil, blockedByFirst: 50, first: 50, statusFieldName: "Status"}}
    assert query =~ "SymphonyGitHubProjectItems"
    assert_receive {:project_items_query, ^query, %{after: "cursor-1", blockedByFirst: 50, first: 50, statusFieldName: "Status"}}
  end

  test "fetches project iteration metadata and marks the current iteration" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_endpoint: "https://api.github.test",
      tracker_api_token: "github-token",
      tracker_owner: "xuelongmu",
      tracker_repo: "symphony",
      tracker_project_owner: "xuelongmu",
      tracker_project_owner_type: "user",
      tracker_project_number: 1,
      tracker_project_status_field: "Status",
      tracker_active_states: ["Ready"],
      tracker_terminal_states: ["Closed", "Done"],
      tracker_current_iteration: %{field: "Iteration", states: ["Ready"]}
    )

    start_date = Date.utc_today() |> Date.add(-1)
    start_date_iso = Date.to_iso8601(start_date)

    graphql_fun = fn query, variables ->
      cond do
        query =~ "SymphonyGitHubProjectItems" ->
          send(self(), {:project_items_query, query, variables})

          item =
            project_issue_item(%{
              item_id: "item-1",
              number: 1,
              title: "Ready current iteration",
              status: "Ready",
              state: "OPEN"
            })
            |> Map.put(
              "iterationFieldValue",
              project_iteration_value(%{
                id: "iteration-current",
                title: "Current",
                start_date: start_date_iso,
                duration: 14
              })
            )

          {:ok, project_items_response([item], has_next_page: false, end_cursor: nil)}

        query =~ "SymphonyGitHubProjectFields" ->
          send(self(), {:project_fields_query, query, variables})

          {:ok,
           project_fields_response([
             project_iteration_field(%{
               id: "field-iteration",
               name: "Iteration",
               iterations: [
                 %{
                   "id" => "iteration-current",
                   "title" => "Current",
                   "startDate" => start_date_iso,
                   "duration" => 14
                 }
               ]
             })
           ])}
      end
    end

    assert {:ok, [issue]} = GitHubClient.fetch_candidate_issues_for_test(graphql_fun)

    assert issue.iteration == %{
             iteration_id: "iteration-current",
             title: "Current",
             start_date: start_date,
             duration: 14,
             current: true
           }

    assert_receive {:project_items_query, query,
                    %{
                      after: nil,
                      blockedByFirst: 50,
                      first: 50,
                      iterationFieldName: "Iteration",
                      statusFieldName: "Status"
                    }}

    assert query =~ "iterationFieldValue"
    assert_receive {:project_fields_query, fields_query, %{after: nil, first: 50, number: 1, owner: "xuelongmu"}}
    assert fields_query =~ "ProjectV2IterationField"
  end

  test "current iteration calculation treats duration end dates as exclusive" do
    iterations = [
      %{"id" => "iteration-2", "title" => "Iteration 2", "startDate" => "2026-05-01", "duration" => 14},
      %{"id" => "iteration-3", "title" => "Iteration 3", "startDate" => "2026-05-15", "duration" => 14}
    ]

    assert GitHubClient.current_iteration_from_iterations_for_test(iterations, ~D[2026-05-01]).iteration_id ==
             "iteration-2"

    assert GitHubClient.current_iteration_from_iterations_for_test(iterations, ~D[2026-05-14]).iteration_id ==
             "iteration-2"

    assert GitHubClient.current_iteration_from_iterations_for_test(iterations, ~D[2026-05-15]).iteration_id ==
             "iteration-3"

    assert GitHubClient.current_iteration_from_iterations_for_test(iterations, ~D[2026-04-30]) == nil
  end

  test "fetches all blocker dependency pages before returning candidates" do
    graphql_fun = fn query, variables ->
      cond do
        query =~ "SymphonyGitHubProjectItems" ->
          send(self(), {:project_items_query, variables})

          {:ok,
           project_items_response(
             [
               project_issue_item(%{
                 item_id: "item-1",
                 number: 1,
                 title: "Blocked issue",
                 status: "Todo",
                 state: "OPEN",
                 blocked_by: [%{number: 100, title: "First blocker", state: "CLOSED"}],
                 blocked_by_page_info: %{has_next_page: true, end_cursor: "blocker-cursor-1"}
               })
             ],
             has_next_page: false,
             end_cursor: nil
           )}

        query =~ "SymphonyGitHubIssueBlockers" ->
          send(self(), {:issue_blockers_query, variables})

          {:ok,
           issue_blockers_response(
             [%{number: 101, title: "Second blocker", state: "OPEN"}],
             has_next_page: false,
             end_cursor: nil
           )}
      end
    end

    assert {:ok, [issue]} = GitHubClient.fetch_candidate_issues_for_test(graphql_fun)

    assert Enum.map(issue.blocked_by, & &1.identifier) == [
             "github-xuelongmu-symphony-100",
             "github-xuelongmu-symphony-101"
           ]

    assert Enum.map(issue.blocked_by, & &1.state) == ["Closed", "Open"]

    assert_receive {:project_items_query, %{after: nil, blockedByFirst: 50, first: 50, statusFieldName: "Status"}}
    assert_receive {:issue_blockers_query, %{after: "blocker-cursor-1", first: 50, issueId: "issue-node-1"}}
  end

  test "does not hydrate blocker pages for project issues outside the configured repo" do
    graphql_fun = fn query, variables ->
      cond do
        query =~ "SymphonyGitHubProjectItems" ->
          send(self(), {:project_items_query, variables})

          {:ok,
           project_items_response(
             [
               project_issue_item(%{
                 item_id: "item-other-repo",
                 number: 1,
                 title: "Other repo blocker pages",
                 status: "Todo",
                 state: "OPEN",
                 repo: "elsewhere",
                 blocked_by_page_info: %{has_next_page: true, end_cursor: "ignored-cursor"}
               }),
               project_issue_item(%{
                 item_id: "item-2",
                 number: 2,
                 title: "Tracked repo issue",
                 status: "Todo",
                 state: "OPEN"
               })
             ],
             has_next_page: false,
             end_cursor: nil
           )}

        query =~ "SymphonyGitHubIssueBlockers" ->
          flunk("unexpected blocker hydration query: #{inspect(variables)}")
      end
    end

    assert {:ok, [issue]} = GitHubClient.fetch_candidate_issues_for_test(graphql_fun)

    assert issue.id == "2"
    assert issue.identifier == "github-xuelongmu-symphony-2"
    assert issue.blocked_by == []

    assert_receive {:project_items_query, %{after: nil, blockedByFirst: 50, first: 50, statusFieldName: "Status"}}
  end

  test "closed issues are returned as Closed for terminal-state fetch even when project status is stale" do
    graphql_fun = fn _query, _variables ->
      {:ok,
       project_items_response(
         [
           project_issue_item(%{
             item_id: "item-1",
             number: 1,
             title: "Open todo",
             status: "Todo",
             state: "OPEN"
           }),
           project_issue_item(%{
             item_id: "item-2",
             number: 2,
             title: "Closed stale status",
             status: "Todo",
             state: "CLOSED"
           })
         ],
         has_next_page: false,
         end_cursor: nil
       )}
    end

    assert {:ok, [%Issue{id: "2", state: "Closed"}]} =
             GitHubClient.fetch_issues_by_states_for_test(["Closed"], graphql_fun)
  end

  test "fetch_issue_states_by_ids preserves requested id ordering" do
    graphql_fun = fn _query, _variables ->
      {:ok,
       project_items_response(
         [
           project_issue_item(%{
             item_id: "item-1",
             number: 1,
             title: "First",
             status: "Todo",
             state: "OPEN"
           }),
           project_issue_item(%{
             item_id: "item-4",
             number: 4,
             title: "Fourth",
             status: "In Progress",
             state: "OPEN"
           })
         ],
         has_next_page: false,
         end_cursor: nil
       )}
    end

    assert {:ok, issues} = GitHubClient.fetch_issue_states_by_ids_for_test(["4", "1", "missing"], graphql_fun)
    assert Enum.map(issues, & &1.id) == ["4", "1"]
  end

  test "resolves project status field option and project item ids for updates" do
    graphql_fun = fn query, variables ->
      cond do
        query =~ "SymphonyGitHubProjectFields" ->
          send(self(), {:project_fields_query, variables})

          {:ok,
           project_fields_response([
             %{"id" => "field-priority", "name" => "Priority", "dataType" => "SINGLE_SELECT", "options" => []},
             %{
               "id" => "field-status",
               "name" => "Status",
               "dataType" => "SINGLE_SELECT",
               "options" => [
                 %{"id" => "option-todo", "name" => "Todo"},
                 %{"id" => "option-done", "name" => "Done"}
               ]
             }
           ])}

        query =~ "SymphonyGitHubProjectItems" ->
          send(self(), {:project_items_query, variables})

          {:ok,
           project_items_response(
             [
               project_issue_item(%{
                 item_id: "item-other-repo",
                 number: 12,
                 title: "Other repo same number",
                 status: "Todo",
                 state: "OPEN",
                 repo: "elsewhere"
               }),
               project_issue_item(%{
                 item_id: "item-12",
                 number: 12,
                 title: "Done issue",
                 status: "Todo",
                 state: "OPEN"
               })
             ],
             has_next_page: false,
             end_cursor: nil
           )}
      end
    end

    assert {:ok,
            %{
              project_id: "project-1",
              item_id: "item-12",
              field_id: "field-status",
              option_id: "option-done",
              state_name: "Done"
            }} = GitHubClient.resolve_status_update_for_test("12", "Done", graphql_fun)

    assert_receive {:project_fields_query, %{after: nil, first: 50, number: 1, owner: "xuelongmu"}}
    assert_receive {:project_items_query, %{after: nil, blockedByFirst: 50, first: 50, number: 1, owner: "xuelongmu"}}
  end

  test "returns GitHub-specific errors for missing status options and invalid issue ids" do
    graphql_fun = fn query, _variables ->
      cond do
        query =~ "SymphonyGitHubProjectFields" ->
          {:ok,
           project_fields_response([
             %{
               "id" => "field-status",
               "name" => "Status",
               "dataType" => "SINGLE_SELECT",
               "options" => [%{"id" => "option-todo", "name" => "Todo"}]
             }
           ])}

        query =~ "SymphonyGitHubProjectItems" ->
          {:ok, project_items_response([], has_next_page: false, end_cursor: nil)}
      end
    end

    assert {:error, {:github_project_status_option_not_found, "Status", "Done"}} =
             GitHubClient.resolve_status_update_for_test("12", "Done", graphql_fun)

    assert {:error, {:invalid_github_issue_number, "not-a-number"}} =
             GitHubClient.resolve_status_update_for_test("not-a-number", "Done", graphql_fun)
  end

  test "creates comments and patches issue state through REST request seam" do
    request_fun = fn method, path, headers, json, params ->
      send(self(), {:github_request, method, path, headers, json, params})
      {:ok, %{status: if(method == :post, do: 201, else: 200), body: %{}}}
    end

    assert :ok = GitHubClient.create_comment_for_test("#12", "hello", request_fun)

    assert_receive {:github_request, :post, "/repos/xuelongmu/symphony/issues/12/comments", headers, %{"body" => "hello"}, []}

    assert {"Authorization", "Bearer github-token"} in headers
    assert {"X-GitHub-Api-Version", "2026-03-10"} in headers

    assert :ok = GitHubClient.patch_issue_state_for_test("12", "Done", request_fun)

    assert_receive {:github_request, :patch, "/repos/xuelongmu/symphony/issues/12", _headers, %{"state" => "closed", "state_reason" => "completed"}, []}

    assert :ok = GitHubClient.patch_issue_state_for_test("12", "Todo", request_fun)

    assert_receive {:github_request, :patch, "/repos/xuelongmu/symphony/issues/12", _headers, %{"state" => "open", "state_reason" => "reopened"}, []}
  end

  test "REST request failures include GitHub-specific status tuples" do
    request_fun = fn _method, _path, _headers, _json, _params ->
      {:ok, %{status: 422, body: %{"message" => "Validation Failed"}}}
    end

    assert {:error, {:github_comment_create_status, 422, body}} =
             GitHubClient.create_comment_for_test("12", "hello", request_fun)

    assert body =~ "Validation Failed"

    assert {:error, {:github_issue_patch_status, 422, body}} =
             GitHubClient.patch_issue_state_for_test("12", "Done", request_fun)

    assert body =~ "Validation Failed"
  end

  test "REST URLs are built from GraphQL-suffixed endpoints by stripping the GraphQL path" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_endpoint: "https://api.github.test/graphql/",
      tracker_api_token: "github-token",
      tracker_owner: "xuelongmu",
      tracker_repo: "symphony",
      tracker_project_owner: "xuelongmu",
      tracker_project_owner_type: "user",
      tracker_project_number: 1,
      tracker_project_status_field: "Status",
      tracker_active_states: ["Todo", "In Progress"],
      tracker_terminal_states: ["Closed", "Done"]
    )

    assert GitHubClient.github_rest_url_for_test("/repos/xuelongmu/symphony/issues/12") ==
             "https://api.github.test/repos/xuelongmu/symphony/issues/12"
  end

  defp project_items_response(items, opts) do
    %{
      "data" => %{
        "user" => %{
          "projectV2" => %{
            "id" => "project-1",
            "items" => %{
              "nodes" => items,
              "pageInfo" => %{
                "hasNextPage" => Keyword.fetch!(opts, :has_next_page),
                "endCursor" => Keyword.fetch!(opts, :end_cursor)
              }
            }
          }
        }
      }
    }
  end

  defp project_fields_response(fields) do
    %{
      "data" => %{
        "user" => %{
          "projectV2" => %{
            "id" => "project-1",
            "fields" => %{
              "nodes" => fields,
              "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
            }
          }
        }
      }
    }
  end

  defp project_iteration_field(attrs) do
    %{
      "__typename" => "ProjectV2IterationField",
      "id" => Map.fetch!(attrs, :id),
      "name" => Map.fetch!(attrs, :name),
      "dataType" => "ITERATION",
      "configuration" => %{
        "iterations" => Map.get(attrs, :iterations, []),
        "completedIterations" => Map.get(attrs, :completed_iterations, [])
      }
    }
  end

  defp project_iteration_value(attrs) do
    %{
      "__typename" => "ProjectV2ItemFieldIterationValue",
      "iterationId" => Map.fetch!(attrs, :id),
      "title" => Map.fetch!(attrs, :title),
      "startDate" => Map.fetch!(attrs, :start_date),
      "duration" => Map.fetch!(attrs, :duration)
    }
  end

  defp issue_blockers_response(blockers, opts) do
    %{
      "data" => %{
        "node" => %{
          "blockedBy" => %{
            "nodes" => Enum.map(blockers, &blocker_issue("xuelongmu", "symphony", &1)),
            "pageInfo" => %{
              "hasNextPage" => Keyword.fetch!(opts, :has_next_page),
              "endCursor" => Keyword.fetch!(opts, :end_cursor)
            }
          }
        }
      }
    }
  end

  defp project_issue_item(attrs) do
    number = Map.fetch!(attrs, :number)
    owner = Map.get(attrs, :owner, "xuelongmu")
    repo = Map.get(attrs, :repo, "symphony")
    blocked_by_page_info = Map.get(attrs, :blocked_by_page_info, %{has_next_page: false, end_cursor: nil})

    %{
      "id" => Map.fetch!(attrs, :item_id),
      "content" => %{
        "__typename" => "Issue",
        "id" => "issue-node-#{number}",
        "number" => number,
        "title" => Map.fetch!(attrs, :title),
        "body" => Map.get(attrs, :body, "Issue body"),
        "state" => Map.fetch!(attrs, :state),
        "url" => "https://github.com/#{owner}/#{repo}/issues/#{number}",
        "createdAt" => "2026-01-01T00:00:00Z",
        "updatedAt" => "2026-01-02T00:00:00Z",
        "repository" => %{"name" => repo, "owner" => %{"login" => owner}},
        "assignees" => %{
          "nodes" => Enum.map(Map.get(attrs, :assignees, []), &%{"login" => &1})
        },
        "labels" => %{
          "nodes" => Enum.map(Map.get(attrs, :labels, []), &%{"name" => &1})
        },
        "blockedBy" => %{
          "nodes" => Enum.map(Map.get(attrs, :blocked_by, []), &blocker_issue(owner, repo, &1)),
          "pageInfo" => %{
            "hasNextPage" => Map.fetch!(blocked_by_page_info, :has_next_page),
            "endCursor" => Map.fetch!(blocked_by_page_info, :end_cursor)
          }
        }
      },
      "fieldValueByName" => %{
        "__typename" => "ProjectV2ItemFieldSingleSelectValue",
        "name" => Map.fetch!(attrs, :status),
        "optionId" => "option-#{String.downcase(Map.fetch!(attrs, :status))}"
      }
    }
  end

  defp blocker_issue(owner, repo, attrs) do
    number = Map.fetch!(attrs, :number)

    %{
      "id" => Map.get(attrs, :id, "blocker-node-#{number}"),
      "number" => number,
      "title" => Map.fetch!(attrs, :title),
      "state" => Map.fetch!(attrs, :state),
      "url" => "https://github.com/#{owner}/#{repo}/issues/#{number}",
      "repository" => %{"name" => repo, "owner" => %{"login" => owner}}
    }
  end

  defp project_pull_request_item(attrs) do
    status = Map.fetch!(attrs, :status)

    %{
      "id" => Map.fetch!(attrs, :item_id),
      "content" => %{
        "__typename" => "PullRequest",
        "id" => "pr-node-#{Map.fetch!(attrs, :number)}",
        "number" => Map.fetch!(attrs, :number)
      },
      "fieldValueByName" => %{
        "__typename" => "ProjectV2ItemFieldSingleSelectValue",
        "name" => status,
        "optionId" => "option-#{String.downcase(status)}"
      }
    }
  end
end
