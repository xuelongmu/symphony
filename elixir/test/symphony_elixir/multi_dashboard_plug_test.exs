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
end
