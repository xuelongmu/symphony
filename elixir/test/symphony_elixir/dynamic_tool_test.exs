defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool

  test "tool_specs advertises dynamic tool input contracts" do
    specs = DynamicTool.tool_specs()

    assert Enum.map(specs, & &1["name"]) == [
             "linear_graphql",
             "github_graphql",
             "sync_workpad"
           ]

    linear_spec = Enum.find(specs, &(&1["name"] == "linear_graphql"))
    github_spec = Enum.find(specs, &(&1["name"] == "github_graphql"))
    sync_spec = Enum.find(specs, &(&1["name"] == "sync_workpad"))

    assert linear_spec["description"] =~ "Linear"
    assert linear_spec["inputSchema"]["required"] == ["query"]
    assert Map.has_key?(linear_spec["inputSchema"]["properties"], "variables")

    assert github_spec["description"] =~ "GitHub"
    assert github_spec["inputSchema"]["required"] == ["query"]
    assert Map.has_key?(github_spec["inputSchema"]["properties"], "variables")

    assert sync_spec["description"] =~ "workpad"
    assert sync_spec["inputSchema"]["additionalProperties"] == false
    assert sync_spec["inputSchema"]["required"] == ["file_path"]
    assert Map.has_key?(sync_spec["inputSchema"]["properties"], "issue_number")
    assert Map.has_key?(sync_spec["inputSchema"]["properties"], "issue_id")
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["linear_graphql", "github_graphql", "sync_workpad"]
             }
           }

    assert response["contentItems"] == [
             %{
               "type" => "inputText",
               "text" => response["output"]
             }
           ]
  end

  test "linear_graphql returns successful GraphQL responses as tool text" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "query Viewer { viewer { id } }",
          "variables" => %{"includeTeams" => false}
        },
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{"includeTeams" => false}, []}

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]
  end

  test "linear_graphql accepts a raw GraphQL query string" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        "  query Viewer { viewer { id } }  ",
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_456"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql ignores legacy operationName arguments" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "operationName" => "Viewer"},
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_789"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql passes multi-operation documents through unchanged" do
    test_pid = self()

    query = """
    query Viewer { viewer { id } }
    query Teams { teams { nodes { id } } }
    """

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => query},
        linear_client: fn forwarded_query, variables, opts ->
          send(test_pid, {:linear_client_called, forwarded_query, variables, opts})
          {:ok, %{"errors" => [%{"message" => "Must provide operation name if query contains multiple operations."}]}}
        end
      )

    assert_received {:linear_client_called, forwarded_query, %{}, []}
    assert forwarded_query == String.trim(query)
    assert response["success"] == false
  end

  test "linear_graphql rejects blank raw query strings even when using the default client" do
    response = DynamicTool.execute("linear_graphql", "   ")

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }
  end

  test "linear_graphql marks GraphQL error responses as failures while preserving the body" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "mutation BadMutation { nope }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{"errors" => [%{"message" => "Unknown field `nope`"}], "data" => nil}}
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "data" => nil,
             "errors" => [%{"message" => "Unknown field `nope`"}]
           }
  end

  test "linear_graphql marks atom-key GraphQL error responses as failures" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{errors: [%{message: "boom"}], data: nil}}
        end
      )

    assert response["success"] == false
  end

  test "linear_graphql validates required arguments before calling Linear" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"variables" => %{"commentId" => "comment-1"}},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }

    blank_query =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "   "},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when the query is blank")
        end
      )

    assert blank_query["success"] == false
  end

  test "linear_graphql rejects invalid argument types" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        [:not, :valid],
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
             }
           }
  end

  test "linear_graphql rejects invalid variables" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "variables" => ["bad"]},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when variables are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql.variables` must be a JSON object when provided."
             }
           }
  end

  test "linear_graphql formats transport and auth failures" do
    missing_token =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :missing_linear_api_token} end
      )

    assert missing_token["success"] == false

    assert Jason.decode!(missing_token["output"]) == %{
             "error" => %{
               "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
             }
           }

    status_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_status, 503}} end
      )

    assert Jason.decode!(status_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed with HTTP 503.",
               "status" => 503
             }
           }

    request_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_request, :timeout}} end
      )

    assert Jason.decode!(request_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end

  test "linear_graphql formats unexpected failures from the client" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :boom} end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL tool execution failed.",
               "reason" => ":boom"
             }
           }
  end

  test "linear_graphql falls back to inspect for non-JSON payloads" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:ok, :ok} end
      )

    assert response["success"] == true
    assert response["output"] == ":ok"
  end

  test "github_graphql returns successful GraphQL responses as tool text" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "github_graphql",
        %{
          "query" => "query Repo($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { id } }",
          "variables" => %{"owner" => "xuelongmu", "name" => "symphony"}
        },
        github_client: fn query, variables, opts ->
          send(test_pid, {:github_client_called, query, variables, opts})
          {:ok, %{"data" => %{"repository" => %{"id" => "repo_node_1"}}}}
        end
      )

    assert_received {:github_client_called, _query, %{"owner" => "xuelongmu", "name" => "symphony"}, []}

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"data" => %{"repository" => %{"id" => "repo_node_1"}}}
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]
  end

  test "github_graphql validates arguments before calling GitHub" do
    response =
      DynamicTool.execute(
        "github_graphql",
        %{"variables" => %{}},
        github_client: fn _query, _variables, _opts ->
          flunk("github client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`github_graphql` requires a non-empty `query` string."
             }
           }

    invalid_variables =
      DynamicTool.execute(
        "github_graphql",
        %{"query" => "query Viewer { viewer { login } }", "variables" => ["bad"]},
        github_client: fn _query, _variables, _opts ->
          flunk("github client should not be called when variables are invalid")
        end
      )

    assert invalid_variables["success"] == false

    assert Jason.decode!(invalid_variables["output"]) == %{
             "error" => %{
               "message" => "`github_graphql.variables` must be a JSON object when provided."
             }
           }
  end

  test "github_graphql marks GraphQL errors as failures while preserving the body" do
    response =
      DynamicTool.execute(
        "github_graphql",
        %{"query" => "query Bad { nope }"},
        github_client: fn _query, _variables, _opts ->
          {:ok, %{"errors" => [%{"message" => "Field 'nope' does not exist"}], "data" => nil}}
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "data" => nil,
             "errors" => [%{"message" => "Field 'nope' does not exist"}]
           }

    wrapped_errors =
      DynamicTool.execute(
        "github_graphql",
        %{"query" => "query Bad { nope }"},
        github_client: fn _query, _variables, _opts ->
          {:error, {:github_graphql_errors, [%{"message" => "Field 'nope' does not exist"}]}}
        end
      )

    assert wrapped_errors["success"] == false
    assert Jason.decode!(wrapped_errors["output"]) == %{"errors" => [%{"message" => "Field 'nope' does not exist"}]}
  end

  test "github_graphql formats transport and auth failures" do
    missing_token =
      DynamicTool.execute(
        "github_graphql",
        %{"query" => "query Viewer { viewer { login } }"},
        github_client: fn _query, _variables, _opts -> {:error, :missing_github_api_token} end
      )

    assert missing_token["success"] == false

    assert Jason.decode!(missing_token["output"]) == %{
             "error" => %{
               "message" => "Symphony is missing GitHub auth. Set `tracker.api_key` in `WORKFLOW.md` or export `GITHUB_TOKEN`."
             }
           }

    wrapped_missing_token =
      DynamicTool.execute(
        "github_graphql",
        %{"query" => "query Viewer { viewer { login } }"},
        github_client: fn _query, _variables, _opts ->
          {:error, {:github_graphql_request, :missing_github_api_token}}
        end
      )

    assert Jason.decode!(wrapped_missing_token["output"]) == %{
             "error" => %{
               "message" => "Symphony is missing GitHub auth. Set `tracker.api_key` in `WORKFLOW.md` or export `GITHUB_TOKEN`."
             }
           }

    wrong_tracker =
      DynamicTool.execute(
        "github_graphql",
        %{"query" => "query Viewer { viewer { login } }"},
        github_client: fn _query, _variables, _opts -> {:error, :github_tracker_not_configured} end
      )

    assert Jason.decode!(wrong_tracker["output"]) == %{
             "error" => %{
               "message" => "`github_graphql` is available only when `tracker.kind` is `github`."
             }
           }

    status_error =
      DynamicTool.execute(
        "github_graphql",
        %{"query" => "query Viewer { viewer { login } }"},
        github_client: fn _query, _variables, _opts -> {:error, {:github_graphql_status, 502, "bad gateway"}} end
      )

    assert Jason.decode!(status_error["output"]) == %{
             "error" => %{
               "message" => "GitHub GraphQL request failed with HTTP 502.",
               "status" => 502,
               "body" => "bad gateway"
             }
           }

    request_error =
      DynamicTool.execute(
        "github_graphql",
        %{"query" => "query Viewer { viewer { login } }"},
        github_client: fn _query, _variables, _opts -> {:error, {:github_api_request, :timeout}} end
      )

    assert Jason.decode!(request_error["output"]) == %{
             "error" => %{
               "message" => "GitHub GraphQL request failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end

  test "sync_workpad creates a GitHub issue comment from a workspace-relative file" do
    root = tmp_root()
    body = "## Codex Workpad\n\n- [ ] Plan"
    write_workpad!(root, "notes/workpad.md", body)
    test_pid = self()

    try do
      response =
        DynamicTool.execute(
          "sync_workpad",
          %{
            "tracker" => "github",
            "issue_number" => 3,
            "owner" => "xuelongmu",
            "repo" => "symphony",
            "file_path" => "notes/workpad.md"
          },
          workspace: root,
          github_client: fn query, variables, opts ->
            send(test_pid, {:github_client_called, query, variables, opts})

            cond do
              query =~ "SymphonyGitHubIssueNode" ->
                {:ok, %{"data" => %{"repository" => %{"issue" => %{"id" => "ISSUE_node_3"}}}}}

              query =~ "addComment" ->
                {:ok,
                 %{
                   "data" => %{
                     "addComment" => %{
                       "commentEdge" => %{"node" => %{"id" => "IC_node_1", "url" => "https://github.test/comment"}}
                     }
                   }
                 }}

              true ->
                flunk("unexpected GitHub query: #{query}")
            end
          end
        )

      assert_received {:github_client_called, lookup_query, %{"owner" => "xuelongmu", "repo" => "symphony", "number" => 3}, []}

      assert lookup_query =~ "issue(number: $number)"

      assert_received {:github_client_called, create_query, %{"subjectId" => "ISSUE_node_3", "body" => ^body}, []}
      assert create_query =~ "addComment"

      assert response["success"] == true
      assert get_in(Jason.decode!(response["output"]), ["data", "addComment", "commentEdge", "node", "id"]) == "IC_node_1"
    after
      File.rm_rf(root)
    end
  end

  test "sync_workpad updates a GitHub issue comment from an explicit absolute file path" do
    root = tmp_root()
    body = "Updated GitHub workpad."
    path = write_workpad!(root, "workpad.md", body)
    test_pid = self()

    try do
      response =
        DynamicTool.execute(
          "sync_workpad",
          %{
            "tracker" => "github",
            "issue_number" => "3",
            "comment_id" => "IC_node_1",
            "file_path" => path
          },
          github_client: fn query, variables, opts ->
            send(test_pid, {:github_client_called, query, variables, opts})
            {:ok, %{"data" => %{"updateIssueComment" => %{"issueComment" => %{"id" => "IC_node_1"}}}}}
          end
        )

      assert_received {:github_client_called, query, %{"id" => "IC_node_1", "body" => ^body}, []}
      assert query =~ "updateIssueComment"
      assert response["success"] == true
    after
      File.rm_rf(root)
    end
  end

  test "sync_workpad preserves Linear create and update behavior" do
    root = tmp_root()
    create_body = "Linear workpad."
    update_body = "Updated Linear workpad."
    create_path = write_workpad!(root, "create.md", create_body)
    update_path = write_workpad!(root, "update.md", update_body)
    test_pid = self()

    try do
      create_response =
        DynamicTool.execute(
          "sync_workpad",
          %{"issue_id" => "ENG-42", "file_path" => create_path},
          linear_client: fn query, variables, opts ->
            send(test_pid, {:linear_client_called, query, variables, opts})
            {:ok, %{"data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => "c1"}}}}}
          end
        )

      assert_received {:linear_client_called, create_query, %{"issueId" => "ENG-42", "body" => ^create_body}, []}
      assert create_query =~ "commentCreate"
      assert create_response["success"] == true

      update_response =
        DynamicTool.execute(
          "sync_workpad",
          %{"tracker" => "linear", "issue_id" => "ENG-42", "comment_id" => "c1", "file_path" => update_path},
          linear_client: fn query, variables, opts ->
            send(test_pid, {:linear_client_called, query, variables, opts})
            {:ok, %{"data" => %{"commentUpdate" => %{"success" => true, "comment" => %{"id" => "c1"}}}}}
          end
        )

      assert_received {:linear_client_called, update_query, %{"id" => "c1", "body" => ^update_body}, []}
      assert update_query =~ "commentUpdate"
      assert update_response["success"] == true
    after
      File.rm_rf(root)
    end
  end

  test "sync_workpad validates arguments before reading files or calling clients" do
    response =
      DynamicTool.execute(
        "sync_workpad",
        %{"issue_number" => 3, "file_path" => "workpad.md", "extra" => true},
        github_client: fn _query, _variables, _opts ->
          flunk("github client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "unsupported argument"

    missing_issue =
      DynamicTool.execute(
        "sync_workpad",
        %{"tracker" => "github", "file_path" => "workpad.md"},
        github_client: fn _query, _variables, _opts ->
          flunk("github client should not be called when the issue number is missing")
        end
      )

    assert missing_issue["success"] == false
    assert Jason.decode!(missing_issue["output"])["error"]["message"] =~ "issue_number"

    invalid_linear =
      DynamicTool.execute(
        "sync_workpad",
        %{"tracker" => "linear", "issue_id" => "ENG-42", "issue_number" => 3, "file_path" => "workpad.md"},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when GitHub-only arguments are present")
        end
      )

    assert invalid_linear["success"] == false
    assert Jason.decode!(invalid_linear["output"])["error"]["message"] =~ "issue_number"
  end

  test "sync_workpad constrains file reads to the active workspace when provided" do
    root = tmp_root()
    outside_root = tmp_root()
    outside_path = write_workpad!(outside_root, "outside.md", "outside")

    try do
      response =
        DynamicTool.execute(
          "sync_workpad",
          %{
            "tracker" => "github",
            "issue_number" => 3,
            "comment_id" => "IC_node_1",
            "file_path" => outside_path
          },
          workspace: root,
          github_client: fn _query, _variables, _opts ->
            flunk("github client should not be called when file_path escapes the workspace")
          end
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "active workspace"
    after
      File.rm_rf(root)
      File.rm_rf(outside_root)
    end
  end

  test "sync_workpad requires absolute file paths when no workspace is configured" do
    response =
      DynamicTool.execute(
        "sync_workpad",
        %{
          "tracker" => "github",
          "issue_number" => 3,
          "comment_id" => "IC_node_1",
          "file_path" => "workpad.md"
        },
        github_client: fn _query, _variables, _opts ->
          flunk("github client should not be called for relative paths without a workspace")
        end
      )

    assert response["success"] == false
    assert Jason.decode!(response["output"])["error"]["message"] =~ "must be absolute"
  end

  test "sync_workpad rejects empty workpad files" do
    root = tmp_root()
    write_workpad!(root, "empty.md", "")

    try do
      response =
        DynamicTool.execute(
          "sync_workpad",
          %{
            "tracker" => "github",
            "issue_number" => 3,
            "comment_id" => "IC_node_1",
            "file_path" => "empty.md"
          },
          workspace: root,
          github_client: fn _query, _variables, _opts ->
            flunk("github client should not be called for empty workpad files")
          end
        )

      assert response["success"] == false
      assert Jason.decode!(response["output"])["error"]["message"] =~ "file is empty"
    after
      File.rm_rf(root)
    end
  end

  defp tmp_root do
    Path.join(System.tmp_dir!(), "dynamic_tool_test_#{:erlang.unique_integer([:positive])}")
  end

  defp write_workpad!(root, relative_path, body) do
    path = Path.join(root, relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    path
  end
end
