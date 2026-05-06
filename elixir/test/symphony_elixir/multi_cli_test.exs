defmodule SymphonyElixir.MultiCLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias SymphonyElixir.Multi.CLI
  alias SymphonyElixir.Multi.Config

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  test "requires acknowledgement before loading config" do
    parent = self()

    deps = %{
      load_config: fn _path ->
        send(parent, :loaded)
        {:error, :boom}
      end,
      command_parts: fn -> {"symphony", []} end,
      start_launcher: fn _config, _command, _base_args -> {:ok, self()} end,
      start_dashboard: fn _config, _launcher -> :ok end
    }

    assert {:error, banner} = CLI.evaluate(["CACOPHANY.yml"], deps)
    assert banner =~ "To launch cacophany"
    refute_received :loaded
  end

  test "starts launcher and dashboard from config" do
    parent = self()

    config = %Config{
      dashboard: %Config.Dashboard{port: 4100},
      workflows: [
        %Config.Workflow{
          name: "api",
          workflow: "C:/repos/api/WORKFLOW.md",
          logs_root: "C:/tmp/cacophany/api",
          port: 4101
        }
      ]
    }

    deps = %{
      load_config: fn "CACOPHANY.yml" -> {:ok, config} end,
      command_parts: fn -> {"escript", ["bin/symphony"]} end,
      start_launcher: fn loaded_config, command, base_args ->
        send(parent, {:launcher_started, loaded_config, command, base_args})
        {:ok, self()}
      end,
      start_dashboard: fn loaded_config, launcher ->
        send(parent, {:dashboard_started, loaded_config.dashboard.port, launcher})
        :ok
      end
    }

    output =
      capture_io(fn ->
        assert {:launcher, launcher} = CLI.evaluate([@ack_flag, "CACOPHANY.yml"], deps)
        assert launcher == self()
      end)

    assert output =~ "Cacophany dashboard: http://127.0.0.1:4100/"
    assert_received {:launcher_started, ^config, "escript", ["bin/symphony"]}
    assert_received {:dashboard_started, 4100, launcher}
    assert launcher == self()
  end
end
