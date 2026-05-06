defmodule SymphonyElixir.MultiLauncherTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias SymphonyElixir.Multi.Config
  alias SymphonyElixir.Multi.Launcher

  @workflow %Config.Workflow{
    name: "api",
    workflow: "C:/repos/api/WORKFLOW.md",
    logs_root: "C:/tmp/cacophany/api",
    port: 4101
  }

  test "builds child command args for a workflow" do
    config = %Config{workflows: [@workflow]}

    assert [
             %{
               name: "api",
               command: "escript",
               args: [
                 "bin/symphony",
                 "--logs-root",
                 "C:/tmp/cacophany/api",
                 "--port",
                 "4101",
                 "--i-understand-that-this-will-be-running-without-the-usual-guardrails",
                 "C:/repos/api/WORKFLOW.md"
               ]
             }
           ] = Launcher.child_commands(config, "escript", ["bin/symphony"])
  end

  test "runs child workflows from the directory containing their workflow file" do
    opts = Launcher.port_options_for_test(["--version"], @workflow)

    assert Keyword.fetch!(opts, :cd) == "C:/repos/api"
    assert Keyword.fetch!(opts, :args) == ["--version"]
  end

  test "default close kills the Windows process tree before closing the port" do
    parent = self()
    process = make_ref()

    port_info = fn ^process, :os_pid -> {:os_pid, 1234} end

    system_cmd = fn command, args, opts ->
      send(parent, {:cmd, command, args, opts})
      {"", 0}
    end

    port_close = fn ^process -> send(parent, :port_closed) end

    assert :ok =
             Launcher.close_process_for_test(process,
               os_type: {:win32, :nt},
               port_info: port_info,
               system_cmd: system_cmd,
               port_close: port_close
             )

    assert_receive {:cmd, "taskkill", ["/PID", "1234", "/T", "/F"], [stderr_to_stdout: true]}
    assert_receive :port_closed
  end

  test "default close signals Unix process group and children before closing the port" do
    parent = self()
    process = make_ref()

    port_info = fn ^process, :os_pid -> {:os_pid, 1234} end

    system_cmd = fn command, args, opts ->
      send(parent, {:cmd, command, args, opts})
      {"", 0}
    end

    sleep = fn ms -> send(parent, {:sleep, ms}) end
    port_close = fn ^process -> send(parent, :port_closed) end

    assert :ok =
             Launcher.close_process_for_test(process,
               os_type: {:unix, :linux},
               port_info: port_info,
               system_cmd: system_cmd,
               sleep: sleep,
               port_close: port_close
             )

    assert_receive {:cmd, "kill", ["-TERM", "-1234"], [stderr_to_stdout: true]}
    assert_receive {:cmd, "pkill", ["-TERM", "-P", "1234"], [stderr_to_stdout: true]}
    assert_receive {:cmd, "kill", ["-TERM", "1234"], [stderr_to_stdout: true]}
    assert_receive {:sleep, 250}
    assert_receive {:cmd, "kill", ["-KILL", "-1234"], [stderr_to_stdout: true]}
    assert_receive {:cmd, "pkill", ["-KILL", "-P", "1234"], [stderr_to_stdout: true]}
    assert_receive {:cmd, "kill", ["-KILL", "1234"], [stderr_to_stdout: true]}
    assert_receive :port_closed
  end

  test "tracks running workflows and exit status" do
    parent = self()
    process_ref = make_ref()

    open_process = fn command, args, workflow ->
      send(parent, {:opened, command, args, workflow.name})
      {:ok, process_ref}
    end

    close_process = fn process -> send(parent, {:closed, process}) end

    assert {:ok, launcher} =
             Launcher.start(%Config{workflows: [@workflow]},
               command: "symphony",
               open_process: open_process,
               close_process: close_process
             )

    assert_received {:opened, "symphony", _args, "api"}
    assert [%{name: "api", status: "running", dashboard_url: "http://127.0.0.1:4101/"}] = Launcher.status(launcher)

    capture_io(:stderr, fn ->
      send(launcher, {process_ref, {:exit_status, 7}})
      assert eventually(fn -> [%{status: "exited", exit_status: 7}] = Launcher.status(launcher) end)
    end)

    GenServer.stop(launcher)
    assert_received {:closed, ^process_ref}
  end

  test "closes already started workflows if a later workflow fails to start" do
    parent = self()
    first_ref = make_ref()

    workflows = [
      %{@workflow | name: "api"},
      %{@workflow | name: "web", workflow: "C:/repos/web/WORKFLOW.md", port: 4102}
    ]

    open_process = fn
      _command, _args, %{name: "api"} -> {:ok, first_ref}
      _command, _args, %{name: "web"} -> {:error, :boom}
    end

    close_process = fn process -> send(parent, {:closed, process}) end

    assert {:error, {:workflow_start_failed, "web", :boom}} =
             Launcher.start(%Config{workflows: workflows},
               command: "symphony",
               open_process: open_process,
               close_process: close_process
             )

    assert_received {:closed, ^first_ref}
  end

  defp eventually(assertion, attempts \\ 20)

  defp eventually(assertion, attempts) when attempts > 0 do
    assertion.()
    true
  rescue
    MatchError ->
      Process.sleep(10)
      eventually(assertion, attempts - 1)
  end

  defp eventually(_assertion, 0), do: false
end
