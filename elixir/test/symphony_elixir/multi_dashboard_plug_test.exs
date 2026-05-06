defmodule SymphonyElixir.MultiDashboardPlugTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias SymphonyElixir.Multi.DashboardPlug

  @status [
    %{
      name: "api",
      workflow: "C:/repos/api/WORKFLOW.md",
      logs_root: "C:/tmp/cacophany/api",
      port: 4001,
      dashboard_url: "http://127.0.0.1:4001/",
      status: "running",
      exit_status: nil,
      started_at: "2026-05-06T00:00:00Z",
      exited_at: nil
    }
  ]

  test "renders cacophany hub with dashboard links" do
    conn =
      :get
      |> conn("/")
      |> DashboardPlug.call(
        launcher: :launcher,
        status_fun: fn :launcher -> @status end,
        fetch_child_state?: false
      )

    assert conn.status == 200
    assert conn.resp_body =~ "Cacophany"
    assert conn.resp_body =~ "http://127.0.0.1:4001/"
    assert conn.resp_body =~ "api"
  end

  test "returns aggregate JSON and preserves child dashboard failures" do
    request_fun = fn _url, _opts -> {:error, :econnrefused} end

    payload =
      DashboardPlug.payload(
        launcher: :launcher,
        status_fun: fn :launcher -> @status end,
        request_fun: request_fun
      )

    assert payload.counts == %{workflows: 1, running: 1, exited: 0}
    assert [%{child_state: %{available: false, error: ":econnrefused"}}] = payload.workflows
  end

  test "fetches child dashboard state concurrently" do
    parent = self()

    statuses =
      Enum.map(1..3, fn index ->
        %{
          hd(@status)
          | name: "repo-#{index}",
            port: 4000 + index,
            dashboard_url: "http://127.0.0.1:#{4000 + index}/"
        }
      end)

    request_fun = fn url, _opts ->
      send(parent, {:request_started, url, self()})

      receive do
        :release -> {:ok, %{status: 200, body: %{"counts" => %{"running" => 1}, "generated_at" => "now"}}}
      end
    end

    task =
      Task.async(fn ->
        DashboardPlug.payload(
          launcher: :launcher,
          status_fun: fn :launcher -> statuses end,
          request_fun: request_fun,
          child_state_max_concurrency: 3,
          child_state_timeout: 2_000
        )
      end)

    request_tasks =
      Enum.map(1..3, fn _index ->
        assert_receive {:request_started, _url, pid}, 500
        pid
      end)

    Enum.each(request_tasks, &send(&1, :release))

    payload = Task.await(task)

    assert Enum.map(payload.workflows, & &1.name) == ["repo-1", "repo-2", "repo-3"]
    assert Enum.all?(payload.workflows, &(&1.child_state.available == true))
  end
end
