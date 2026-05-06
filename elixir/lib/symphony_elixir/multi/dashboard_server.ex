defmodule SymphonyElixir.Multi.DashboardServer do
  @moduledoc """
  Starts the launcher dashboard hub.
  """

  alias SymphonyElixir.Multi.DashboardPlug

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    port = Keyword.fetch!(opts, :port)
    launcher = Keyword.fetch!(opts, :launcher)

    Bandit.start_link(
      plug: {DashboardPlug, launcher: launcher},
      scheme: :http,
      port: port
    )
  end
end
