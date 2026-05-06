defmodule SymphonyElixir.MultiConfigTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Multi.Config

  test "parses valid cacophany config with dashboard and workflows" do
    base_dir = Path.join(System.tmp_dir!(), "cacophany-config-#{System.unique_integer([:positive])}")
    api_workflow = Path.expand("api/WORKFLOW.md", base_dir)
    web_workflow = Path.expand("web/WORKFLOW.md", base_dir)

    attrs = %{
      "dashboard" => %{"port" => 4100},
      "workflows" => [
        %{
          "name" => "api",
          "workflow" => "api/WORKFLOW.md",
          "logs_root" => "logs/api",
          "port" => 4101
        },
        %{"name" => "web", "workflow" => "web/WORKFLOW.md", "port" => 4102}
      ]
    }

    assert {:ok, config} =
             Config.from_map(attrs, base_dir, fn path -> path in [api_workflow, web_workflow] end)

    assert config.dashboard.port == 4100
    assert Config.dashboard_enabled?(config)
    assert Enum.map(config.workflows, & &1.name) == ["api", "web"]

    [api, web] = config.workflows
    assert api.workflow == api_workflow
    assert api.logs_root == Path.expand("logs/api", base_dir)
    assert api.port == 4101
    assert web.workflow == web_workflow
  end

  test "rejects extra args because child CLI switches are strict" do
    attrs = %{
      "workflows" => [
        %{"name" => "api", "workflow" => "api/WORKFLOW.md", "extra_args" => ["--trace"]}
      ]
    }

    assert {:error, {:unsupported_multi_config_field, "workflows[1].extra_args"}} =
             Config.from_map(attrs, File.cwd!(), fn _path -> true end)
  end

  test "requires unique workflow names" do
    attrs = %{
      "workflows" => [
        %{"name" => "api", "workflow" => "api/WORKFLOW.md"},
        %{"name" => "API", "workflow" => "other/WORKFLOW.md"}
      ]
    }

    assert {:error, {:duplicate_workflow_names, ["api"]}} =
             Config.from_map(attrs, File.cwd!(), fn _path -> true end)
  end

  test "requires unique workflow ports and no dashboard collision" do
    duplicate_attrs = %{
      "workflows" => [
        %{"name" => "api", "workflow" => "api/WORKFLOW.md", "port" => 4101},
        %{"name" => "web", "workflow" => "web/WORKFLOW.md", "port" => 4101}
      ]
    }

    assert {:error, {:duplicate_workflow_ports, [4101]}} =
             Config.from_map(duplicate_attrs, File.cwd!(), fn _path -> true end)

    collision_attrs = %{
      "dashboard" => %{"port" => 4100},
      "workflows" => [
        %{"name" => "api", "workflow" => "api/WORKFLOW.md", "port" => 4100}
      ]
    }

    assert {:error, {:dashboard_port_conflicts_with_workflow, 4100}} =
             Config.from_map(collision_attrs, File.cwd!(), fn _path -> true end)
  end

  test "rejects ephemeral port zero because dashboard URLs need stable ports" do
    dashboard_attrs = %{
      "dashboard" => %{"port" => 0},
      "workflows" => [
        %{"name" => "api", "workflow" => "api/WORKFLOW.md", "port" => 4101}
      ]
    }

    assert {:error, {:invalid_multi_config_field, "dashboard.port"}} =
             Config.from_map(dashboard_attrs, File.cwd!(), fn _path -> true end)

    workflow_attrs = %{
      "workflows" => [
        %{"name" => "api", "workflow" => "api/WORKFLOW.md", "port" => 0}
      ]
    }

    assert {:error, {:invalid_multi_config_field, "workflows[1].port"}} =
             Config.from_map(workflow_attrs, File.cwd!(), fn _path -> true end)
  end

  test "requires workflow ports when dashboard hub is enabled" do
    attrs = %{
      "dashboard" => %{"port" => 4100},
      "workflows" => [
        %{"name" => "api", "workflow" => "api/WORKFLOW.md"}
      ]
    }

    assert {:error, {:workflow_port_required_for_dashboard, "api"}} =
             Config.from_map(attrs, File.cwd!(), fn _path -> true end)
  end
end
