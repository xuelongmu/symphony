defmodule SymphonyElixir.GitHubAdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Adapter

  defmodule FakeGitHubClient do
    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def create_comment(issue_id, body) do
      send(self(), {:create_comment_called, issue_id, body})
      Process.get({__MODULE__, :create_comment_result}, :ok)
    end

    def resolve_status_update(issue_id, state_name) do
      send(self(), {:resolve_status_update_called, issue_id, state_name})

      Process.get(
        {__MODULE__, :resolve_status_update_result},
        {:ok,
         %{
           project_id: "project-1",
           item_id: "item-1",
           field_id: "field-status",
           option_id: "option-done",
           state_name: state_name
         }}
      )
    end

    def update_project_item_status(status_update) do
      send(self(), {:update_project_item_status_called, status_update})
      Process.get({__MODULE__, :update_project_item_status_result}, :ok)
    end

    def patch_issue_state(issue_id, state_name) do
      send(self(), {:patch_issue_state_called, issue_id, state_name})
      Process.get({__MODULE__, :patch_issue_state_result}, :ok)
    end
  end

  setup do
    previous_client_module = Application.get_env(:symphony_elixir, :github_client_module)
    Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)

    on_exit(fn ->
      if is_nil(previous_client_module) do
        Application.delete_env(:symphony_elixir, :github_client_module)
      else
        Application.put_env(:symphony_elixir, :github_client_module, previous_client_module)
      end
    end)

    :ok
  end

  test "delegates reads and comment creation to configured GitHub client" do
    assert {:ok, [:candidate]} = Adapter.fetch_candidate_issues()
    assert_receive :fetch_candidate_issues_called

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["12"]} = Adapter.fetch_issue_states_by_ids(["12"])
    assert_receive {:fetch_issue_states_by_ids_called, ["12"]}

    assert :ok = Adapter.create_comment("12", "hello")
    assert_receive {:create_comment_called, "12", "hello"}

    Process.put({FakeGitHubClient, :create_comment_result}, {:error, :boom})
    assert {:error, :boom} = Adapter.create_comment("12", "hello")
  end

  test "updates project status then patches GitHub issue state" do
    assert :ok = Adapter.update_issue_state("12", "Done")

    assert_receive {:resolve_status_update_called, "12", "Done"}

    assert_receive {:update_project_item_status_called,
                    %{
                      project_id: "project-1",
                      item_id: "item-1",
                      field_id: "field-status",
                      option_id: "option-done",
                      state_name: "Done"
                    }}

    assert_receive {:patch_issue_state_called, "12", "Done"}
  end

  test "update_issue_state returns the first GitHub client error" do
    Process.put({FakeGitHubClient, :resolve_status_update_result}, {:error, :state_missing})
    assert {:error, :state_missing} = Adapter.update_issue_state("12", "Missing")
    assert_receive {:resolve_status_update_called, "12", "Missing"}
    refute_receive {:update_project_item_status_called, _}

    Process.delete({FakeGitHubClient, :resolve_status_update_result})
    Process.put({FakeGitHubClient, :update_project_item_status_result}, {:error, :update_failed})
    assert {:error, :update_failed} = Adapter.update_issue_state("12", "Done")
    assert_receive {:update_project_item_status_called, _}
    refute_receive {:patch_issue_state_called, "12", "Done"}

    Process.delete({FakeGitHubClient, :update_project_item_status_result})
    Process.put({FakeGitHubClient, :patch_issue_state_result}, {:error, :patch_failed})
    assert {:error, :patch_failed} = Adapter.update_issue_state("12", "Done")
    assert_receive {:patch_issue_state_called, "12", "Done"}

    Process.put({FakeGitHubClient, :resolve_status_update_result}, :unexpected)
    assert {:error, :github_issue_update_failed} = Adapter.update_issue_state("12", "Done")
  end
end
