defmodule SymphonyElixir.Multi.Launcher do
  @moduledoc """
  Starts and tracks one Symphony child process per workflow.
  """

  use GenServer

  alias SymphonyElixir.Multi.Config

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  defstruct [:config, :command, :base_args, :open_process, :close_process, processes: %{}, workflows: %{}]

  @type workflow_status :: %{
          name: String.t(),
          workflow: Path.t(),
          logs_root: Path.t() | nil,
          port: non_neg_integer() | nil,
          dashboard_url: String.t() | nil,
          status: String.t(),
          exit_status: non_neg_integer() | nil,
          started_at: String.t() | nil,
          exited_at: String.t() | nil
        }

  @spec start_link(Config.t(), keyword()) :: GenServer.on_start()
  def start_link(%Config{} = config, opts \\ []) do
    GenServer.start_link(__MODULE__, {config, opts})
  end

  @spec start(Config.t(), keyword()) :: GenServer.on_start()
  def start(%Config{} = config, opts \\ []) do
    GenServer.start(__MODULE__, {config, opts})
  end

  @spec status(GenServer.server()) :: [workflow_status()]
  def status(server) do
    GenServer.call(server, :status)
  end

  @spec child_commands(Config.t(), String.t(), [String.t()]) :: [map()]
  def child_commands(%Config{workflows: workflows}, command, base_args \\ [])
      when is_binary(command) and is_list(base_args) do
    Enum.map(workflows, fn workflow ->
      %{
        name: workflow.name,
        command: command,
        args: base_args ++ child_args(workflow)
      }
    end)
  end

  @impl true
  def init({%Config{} = config, opts}) do
    command = Keyword.fetch!(opts, :command)
    base_args = Keyword.get(opts, :base_args, [])
    open_process = Keyword.get(opts, :open_process, &default_open_process/3)
    close_process = Keyword.get(opts, :close_process, &default_close_process/1)

    state = %__MODULE__{
      config: config,
      command: command,
      base_args: base_args,
      open_process: open_process,
      close_process: close_process
    }

    case start_workflows(config.workflows, state) do
      {:ok, state} ->
        {:ok, state}

      {:error, reason, state} ->
        close_started_processes(state)
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, workflow_statuses(state), state}
  end

  @impl true
  def handle_info({process, {:data, data}}, state) do
    case Map.get(state.processes, process) do
      %{name: name} -> write_child_output(name, data)
      _unknown -> :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({process, {:exit_status, exit_status}}, state) do
    case Map.get(state.processes, process) do
      %{name: name} ->
        exited_at = now_iso8601()

        workflows =
          Map.update!(state.workflows, name, fn workflow ->
            workflow
            |> Map.put(:status, "exited")
            |> Map.put(:exit_status, exit_status)
            |> Map.put(:exited_at, exited_at)
          end)

        IO.puts(:stderr, "[#{name}] exited with status #{exit_status}")
        {:noreply, %{state | workflows: workflows}}

      _unknown ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    close_started_processes(state)
    :ok
  end

  defp start_workflows(workflows, state) do
    Enum.reduce_while(workflows, {:ok, state}, fn workflow, {:ok, state} ->
      args = state.base_args ++ child_args(workflow)

      case state.open_process.(state.command, args, workflow) do
        {:ok, process} ->
          started_at = now_iso8601()

          workflow_state = %{
            name: workflow.name,
            workflow: workflow.workflow,
            logs_root: workflow.logs_root,
            port: workflow.port,
            dashboard_url: dashboard_url(workflow.port),
            status: "running",
            exit_status: nil,
            started_at: started_at,
            exited_at: nil
          }

          state = %{
            state
            | processes: Map.put(state.processes, process, workflow_state),
              workflows: Map.put(state.workflows, workflow.name, workflow_state)
          }

          {:cont, {:ok, state}}

        {:error, reason} ->
          {:halt, {:error, {:workflow_start_failed, workflow.name, reason}, state}}
      end
    end)
  end

  defp child_args(workflow) do
    []
    |> maybe_append("--logs-root", workflow.logs_root)
    |> maybe_append("--port", workflow.port && Integer.to_string(workflow.port))
    |> Kernel.++([@ack_flag])
    |> Kernel.++([workflow.workflow])
  end

  defp maybe_append(args, _switch, nil), do: args
  defp maybe_append(args, switch, value), do: args ++ [switch, value]

  @doc false
  @spec port_options_for_test([String.t()], Config.Workflow.t()) :: list()
  def port_options_for_test(args, workflow), do: port_options(args, workflow)

  @doc false
  @spec close_process_for_test(term(), keyword()) :: :ok
  def close_process_for_test(process, opts), do: close_process(process, opts)

  defp default_open_process(command, args, workflow) do
    port =
      Port.open({:spawn_executable, command}, port_options(args, workflow))

    {:ok, port}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp default_close_process(process), do: close_process(process, [])

  defp close_process(process, opts) when is_port(process) or opts != [] do
    port_info = Keyword.get(opts, :port_info, &:erlang.port_info/2)
    port_close = Keyword.get(opts, :port_close, &Port.close/1)
    system_cmd = Keyword.get(opts, :system_cmd, &System.cmd/3)
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
    os_type = Keyword.get(opts, :os_type, :os.type())

    process
    |> os_pid(port_info)
    |> terminate_process_tree(os_type, system_cmd, sleep)

    close_port(process, port_close)
  end

  defp close_process(_process, _opts), do: :ok

  defp os_pid(process, port_info) do
    case port_info.(process, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) and os_pid > 0 -> os_pid
      _unknown -> nil
    end
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  defp terminate_process_tree(nil, _os_type, _system_cmd, _sleep), do: :ok

  defp terminate_process_tree(os_pid, {:win32, _}, system_cmd, _sleep) do
    run_system_cmd(system_cmd, "taskkill", ["/PID", Integer.to_string(os_pid), "/T", "/F"])
  end

  defp terminate_process_tree(os_pid, {:unix, _}, system_cmd, sleep) do
    pid = Integer.to_string(os_pid)
    process_group = "-#{pid}"

    run_system_cmd(system_cmd, "kill", ["-TERM", process_group])
    run_system_cmd(system_cmd, "pkill", ["-TERM", "-P", pid])
    run_system_cmd(system_cmd, "kill", ["-TERM", pid])
    sleep.(250)
    run_system_cmd(system_cmd, "kill", ["-KILL", process_group])
    run_system_cmd(system_cmd, "pkill", ["-KILL", "-P", pid])
    run_system_cmd(system_cmd, "kill", ["-KILL", pid])
  end

  defp terminate_process_tree(os_pid, _os_type, system_cmd, _sleep) do
    run_system_cmd(system_cmd, "kill", ["-TERM", Integer.to_string(os_pid)])
  end

  defp run_system_cmd(system_cmd, command, args) do
    system_cmd.(command, args, stderr_to_stdout: true)
    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp close_port(process, port_close) do
    port_close.(process)
    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp port_options(args, workflow) do
    [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: args,
      cd: Path.dirname(workflow.workflow)
    ]
  end

  defp close_started_processes(state) do
    Enum.each(Map.keys(state.processes), state.close_process)
  end

  defp workflow_statuses(state) do
    Enum.map(state.config.workflows, fn workflow ->
      Map.fetch!(state.workflows, workflow.name)
    end)
  end

  defp dashboard_url(nil), do: nil
  defp dashboard_url(port), do: "http://127.0.0.1:#{port}/"

  defp now_iso8601 do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp write_child_output(name, data) when is_binary(data) do
    data
    |> String.split(~r/\R/, trim: false)
    |> Enum.reject(&(&1 == ""))
    |> Enum.each(&IO.puts("[#{name}] #{&1}"))
  end
end
