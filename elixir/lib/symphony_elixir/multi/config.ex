defmodule SymphonyElixir.Multi.Config do
  @moduledoc """
  Loads and validates multi-workflow launcher configuration.
  """

  defmodule Dashboard do
    @moduledoc false
    defstruct [:port]

    @type t :: %__MODULE__{port: non_neg_integer() | nil}
  end

  defmodule Workflow do
    @moduledoc false
    defstruct [:name, :workflow, :logs_root, :port]

    @type t :: %__MODULE__{
            name: String.t(),
            workflow: Path.t(),
            logs_root: Path.t() | nil,
            port: non_neg_integer() | nil
          }
  end

  defstruct dashboard: nil, workflows: []

  @type t :: %__MODULE__{dashboard: Dashboard.t(), workflows: [Workflow.t()]}

  @type file_regular? :: (Path.t() -> boolean())

  @spec load(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def load(path, opts \\ []) when is_binary(path) do
    expanded_path = Path.expand(path)
    file_regular? = Keyword.get(opts, :file_regular?, &File.regular?/1)

    with true <- file_regular?.(expanded_path),
         {:ok, content} <- File.read(expanded_path),
         {:ok, decoded} <- decode_yaml(content),
         {:ok, config} <- from_map(decoded, Path.dirname(expanded_path), file_regular?) do
      {:ok, config}
    else
      false -> {:error, {:missing_multi_config_file, expanded_path}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec from_map(map(), Path.t()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs, base_dir), do: from_map(attrs, base_dir, &File.regular?/1)

  @spec from_map(map(), Path.t(), file_regular?()) :: {:ok, t()} | {:error, term()}
  def from_map(attrs, base_dir, file_regular?)
      when is_map(attrs) and is_binary(base_dir) and is_function(file_regular?, 1) do
    with {:ok, dashboard} <- parse_dashboard(Map.get(attrs, "dashboard", %{})),
         {:ok, workflows} <- parse_workflows(Map.get(attrs, "workflows"), base_dir, file_regular?),
         :ok <- validate_unique_names(workflows),
         :ok <- validate_unique_ports(dashboard, workflows),
         :ok <- validate_dashboard_workflow_ports(dashboard, workflows) do
      {:ok, %__MODULE__{dashboard: dashboard, workflows: workflows}}
    end
  end

  def from_map(_attrs, _base_dir, _file_regular?), do: {:error, :multi_config_must_be_a_map}

  @spec dashboard_enabled?(t()) :: boolean()
  def dashboard_enabled?(%__MODULE__{dashboard: %Dashboard{port: port}}), do: is_integer(port)

  defp decode_yaml(content) do
    case YamlElixir.read_from_string(content) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _decoded} -> {:error, :multi_config_must_be_a_map}
      {:error, reason} -> {:error, {:multi_config_parse_error, reason}}
    end
  end

  defp parse_dashboard(nil), do: {:ok, %Dashboard{}}
  defp parse_dashboard(attrs) when attrs == %{}, do: {:ok, %Dashboard{}}

  defp parse_dashboard(attrs) when is_map(attrs) do
    with {:ok, port} <- parse_optional_port(Map.get(attrs, "port"), "dashboard.port") do
      {:ok, %Dashboard{port: port}}
    end
  end

  defp parse_dashboard(_attrs), do: {:error, {:invalid_multi_config_field, "dashboard"}}

  defp parse_workflows(workflows, _base_dir, _file_regular?) when not is_list(workflows) do
    {:error, :multi_config_workflows_required}
  end

  defp parse_workflows([], _base_dir, _file_regular?), do: {:error, :multi_config_workflows_required}

  defp parse_workflows(workflows, base_dir, file_regular?) do
    workflows
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {workflow, index}, {:ok, acc} ->
      case parse_workflow(workflow, index, base_dir, file_regular?) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp parse_workflow(attrs, index, base_dir, file_regular?) when is_map(attrs) do
    with {:ok, name} <- required_string(attrs, "name", workflow_field(index, "name")),
         {:ok, workflow_path} <- required_string(attrs, "workflow", workflow_field(index, "workflow")),
         expanded_workflow <- expand_path(workflow_path, base_dir),
         true <- file_regular?.(expanded_workflow),
         {:ok, logs_root} <- optional_path(attrs, "logs_root", base_dir, workflow_field(index, "logs_root")),
         {:ok, port} <- parse_optional_port(Map.get(attrs, "port"), workflow_field(index, "port")),
         :ok <- reject_extra_args(Map.get(attrs, "extra_args", []), workflow_field(index, "extra_args")) do
      {:ok,
       %Workflow{
         name: name,
         workflow: expanded_workflow,
         logs_root: logs_root,
         port: port
       }}
    else
      false -> {:error, {:missing_workflow_file, index, expand_path(Map.get(attrs, "workflow", ""), base_dir)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_workflow(_attrs, index, _base_dir, _file_regular?) do
    {:error, {:invalid_multi_config_workflow, index}}
  end

  defp required_string(attrs, key, field) do
    case Map.get(attrs, key) do
      value when is_binary(value) ->
        value = String.trim(value)

        if value == "" do
          {:error, {:invalid_multi_config_field, field}}
        else
          {:ok, value}
        end

      _ ->
        {:error, {:invalid_multi_config_field, field}}
    end
  end

  defp optional_path(attrs, key, base_dir, field) do
    case Map.get(attrs, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        value = String.trim(value)

        if value == "" do
          {:error, {:invalid_multi_config_field, field}}
        else
          {:ok, expand_path(value, base_dir)}
        end

      _ ->
        {:error, {:invalid_multi_config_field, field}}
    end
  end

  defp parse_optional_port(nil, _field), do: {:ok, nil}

  defp parse_optional_port(port, _field) when is_integer(port) and port > 0, do: {:ok, port}

  defp parse_optional_port(_port, field), do: {:error, {:invalid_multi_config_field, field}}

  defp reject_extra_args(nil, _field), do: :ok
  defp reject_extra_args([], _field), do: :ok
  defp reject_extra_args(_args, field), do: {:error, {:unsupported_multi_config_field, field}}

  defp validate_unique_names(workflows) do
    duplicates =
      workflows
      |> Enum.map(&String.downcase(&1.name))
      |> duplicates()

    case duplicates do
      [] -> :ok
      names -> {:error, {:duplicate_workflow_names, names}}
    end
  end

  defp validate_unique_ports(%Dashboard{port: dashboard_port}, workflows) do
    workflow_ports = workflows |> Enum.map(& &1.port) |> Enum.reject(&is_nil/1)

    cond do
      duplicates(workflow_ports) != [] ->
        {:error, {:duplicate_workflow_ports, duplicates(workflow_ports)}}

      is_integer(dashboard_port) and dashboard_port in workflow_ports ->
        {:error, {:dashboard_port_conflicts_with_workflow, dashboard_port}}

      true ->
        :ok
    end
  end

  defp validate_dashboard_workflow_ports(%Dashboard{port: nil}, _workflows), do: :ok

  defp validate_dashboard_workflow_ports(%Dashboard{port: _port}, workflows) do
    case Enum.find(workflows, &is_nil(&1.port)) do
      nil -> :ok
      workflow -> {:error, {:workflow_port_required_for_dashboard, workflow.name}}
    end
  end

  defp duplicates(values) do
    values
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(fn {value, _count} -> value end)
  end

  defp workflow_field(index, field), do: "workflows[#{index}].#{field}"

  defp expand_path(path, base_dir) do
    if Path.type(path) == :absolute do
      Path.expand(path)
    else
      Path.expand(path, base_dir)
    end
  end
end
