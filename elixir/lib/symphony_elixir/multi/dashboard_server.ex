defmodule SymphonyElixir.Multi.DashboardServer do
  @moduledoc """
  Starts the launcher dashboard hub.
  """

  alias SymphonyElixir.Multi.DashboardPlug

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts
    |> bandit_options()
    |> Bandit.start_link()
  end

  @doc false
  @spec bandit_options_for_test(keyword()) :: keyword()
  def bandit_options_for_test(opts), do: bandit_options(opts)

  defp bandit_options(opts) do
    port = Keyword.fetch!(opts, :port)
    launcher = Keyword.fetch!(opts, :launcher)

    [
      plug: {DashboardPlug, launcher: launcher},
      scheme: :http,
      ip: {127, 0, 0, 1},
      port: port
    ]
  end
end
