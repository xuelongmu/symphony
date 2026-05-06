defmodule SymphonyElixir.Multi.CLI do
  @moduledoc """
  CLI entrypoint for launching multiple independent Symphony workflows.
  """

  alias SymphonyElixir.Multi.{Config, DashboardServer, Launcher}

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"
  @switches [{@acknowledgement_switch, :boolean}]

  @type deps :: %{
          optional(:command_parts) => (-> {String.t(), [String.t()]} | {:error, term()}),
          optional(:load_config) => (String.t() -> {:ok, Config.t()} | {:error, term()}),
          optional(:start_launcher) => (Config.t(), String.t(), [String.t()] -> GenServer.on_start()),
          optional(:start_dashboard) => (Config.t(), pid() -> :ok | {:error, term()})
        }

  @spec evaluate([String.t()], deps()) :: {:launcher, pid()} | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps()) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [config_path], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             {:ok, config} <- load_config(config_path, deps),
             {:ok, {command, base_args}} <- command_parts(deps),
             {:ok, launcher} <- start_launcher(config, command, base_args, deps),
             :ok <- start_dashboard(config, launcher, deps) do
          print_startup_summary(config)
          {:launcher, launcher}
        else
          {:error, reason} when is_binary(reason) -> {:error, reason}
          {:error, reason} -> {:error, format_error(reason)}
        end

      _ ->
        {:error, usage_message()}
    end
  end

  @spec wait_for_shutdown(pid()) :: no_return()
  def wait_for_shutdown(launcher) when is_pid(launcher) do
    ref = Process.monitor(launcher)

    receive do
      {:DOWN, ^ref, :process, ^launcher, reason} ->
        case reason do
          :normal -> System.halt(0)
          _ -> System.halt(1)
        end
    end
  end

  @spec usage_message() :: String.t()
  def usage_message do
    "Usage: symphony cacophany #{@ack_flag} path-to-CACOPHANY.yml"
  end

  defp runtime_deps do
    %{
      command_parts: &current_command_parts/0,
      load_config: &Config.load/1,
      start_launcher: fn config, command, base_args ->
        Launcher.start(config, command: command, base_args: base_args)
      end,
      start_dashboard: &start_dashboard/2
    }
  end

  defp require_guardrails_acknowledgement(opts) do
    if Keyword.get(opts, @acknowledgement_switch, false) do
      :ok
    else
      {:error, acknowledgement_banner()}
    end
  end

  defp load_config(config_path, deps) do
    deps
    |> Map.get(:load_config, &Config.load/1)
    |> then(& &1.(config_path))
  end

  defp command_parts(deps) do
    case Map.get(deps, :command_parts, &current_command_parts/0).() do
      {command, base_args} when is_binary(command) and is_list(base_args) -> {:ok, {command, base_args}}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_multi_launcher_command, other}}
    end
  end

  defp start_launcher(config, command, base_args, deps) do
    deps
    |> Map.get(:start_launcher)
    |> case do
      nil -> Launcher.start(config, command: command, base_args: base_args)
      fun -> fun.(config, command, base_args)
    end
  end

  defp start_dashboard(config, launcher, deps) do
    deps
    |> Map.get(:start_dashboard, &start_dashboard/2)
    |> then(& &1.(config, launcher))
  end

  defp start_dashboard(%Config{dashboard: %{port: port}}, launcher) when is_integer(port) do
    case DashboardServer.start_link(port: port, launcher: launcher) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, {:multi_dashboard_start_failed, reason}}
    end
  end

  defp start_dashboard(_config, _launcher), do: :ok

  defp current_command_parts do
    script_name =
      case :escript.script_name() do
        name when is_list(name) -> List.to_string(name)
        name when is_binary(name) -> name
        _ -> ""
      end

    cond do
      script_name != "" and System.find_executable("escript") ->
        {System.find_executable("escript"), [Path.expand(script_name)]}

      script_name != "" ->
        {Path.expand(script_name), []}

      executable = System.find_executable("symphony") ->
        {executable, []}

      true ->
        {:error, :symphony_executable_not_found}
    end
  end

  defp print_startup_summary(config) do
    case config.dashboard.port do
      port when is_integer(port) ->
        IO.puts("Cacophany dashboard: http://127.0.0.1:#{port}/")

      _ ->
        :ok
    end

    Enum.each(config.workflows, fn workflow ->
      dashboard =
        case workflow.port do
          port when is_integer(port) -> " dashboard=http://127.0.0.1:#{port}/"
          _ -> ""
        end

      IO.puts("Started #{workflow.name} workflow=#{workflow.workflow}#{dashboard}")
    end)
  end

  defp acknowledgement_banner do
    [
      "This Symphony implementation is a low key engineering preview.",
      "Codex will run without any guardrails.",
      "To launch cacophany, include `#{@ack_flag}`."
    ]
    |> Enum.join("\n")
  end

  defp format_error({:missing_multi_config_file, path}), do: "Cacophany config file not found: #{path}"
  defp format_error(:multi_config_must_be_a_map), do: "Cacophany config must be a YAML object."
  defp format_error(:multi_config_workflows_required), do: "Cacophany config requires a non-empty workflows list."

  defp format_error({:multi_config_parse_error, reason}) do
    "Failed to parse cacophany config: #{inspect(reason)}"
  end

  defp format_error({:invalid_multi_config_field, field}), do: "Invalid cacophany config field: #{field}"
  defp format_error({:invalid_multi_config_workflow, index}), do: "Invalid workflow entry at index #{index}."

  defp format_error({:missing_workflow_file, index, path}) do
    "Workflow file not found for workflows[#{index}]: #{path}"
  end

  defp format_error({:duplicate_workflow_names, names}) do
    "Duplicate workflow names: #{Enum.join(names, ", ")}"
  end

  defp format_error({:duplicate_workflow_ports, ports}) do
    "Duplicate workflow ports: #{Enum.map_join(ports, ", ", &to_string/1)}"
  end

  defp format_error({:dashboard_port_conflicts_with_workflow, port}) do
    "Dashboard port #{port} conflicts with a workflow dashboard port."
  end

  defp format_error({:workflow_port_required_for_dashboard, name}) do
    "Workflow #{name} must set port when the launcher dashboard is enabled."
  end

  defp format_error({:workflow_start_failed, name, reason}) do
    "Failed to start workflow #{name}: #{inspect(reason)}"
  end

  defp format_error({:multi_dashboard_start_failed, reason}) do
    "Failed to start multi-workflow dashboard: #{inspect(reason)}"
  end

  defp format_error(reason), do: inspect(reason)
end
