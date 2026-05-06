defmodule SymphonyElixir.MultiDashboardServerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Multi.DashboardServer

  test "binds the cacophany hub to loopback" do
    opts = DashboardServer.bandit_options_for_test(port: 4000, launcher: self())

    assert Keyword.fetch!(opts, :ip) == {127, 0, 0, 1}
    assert Keyword.fetch!(opts, :port) == 4000
  end
end
