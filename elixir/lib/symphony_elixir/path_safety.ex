defmodule SymphonyElixir.PathSafety do
  @moduledoc false

  @spec canonicalize(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def canonicalize(path) when is_binary(path) do
    expanded_path = Path.expand(path)
    {root, segments} = split_absolute_path(expanded_path)

    case resolve_segments(root, [], segments) do
      {:ok, canonical_path} ->
        {:ok, canonical_path}

      {:error, reason} ->
        {:error, {:path_canonicalize_failed, expanded_path, reason}}
    end
  end

  defp split_absolute_path(path) when is_binary(path) do
    [root | segments] = Path.split(path)
    {root, segments}
  end

  defp resolve_segments(root, resolved_segments, []), do: {:ok, join_path(root, resolved_segments)}

  defp resolve_segments(root, resolved_segments, [segment | rest]) do
    with :ok <- validate_segment_length(segment) do
      candidate_path = join_path(root, resolved_segments ++ [segment])
      resolve_candidate(File.lstat(candidate_path), candidate_path, root, resolved_segments, segment, rest)
    end
  end

  defp validate_segment_length(segment) do
    if byte_size(segment) > 255, do: {:error, :enametoolong}, else: :ok
  end

  defp resolve_candidate({:ok, %File.Stat{type: :symlink}}, candidate_path, root, resolved_segments, _segment, rest) do
    with {:ok, target} <- :file.read_link_all(String.to_charlist(candidate_path)) do
      resolved_target = Path.expand(IO.chardata_to_string(target), join_path(root, resolved_segments))
      {target_root, target_segments} = split_absolute_path(resolved_target)
      resolve_segments(target_root, [], target_segments ++ rest)
    end
  end

  defp resolve_candidate({:ok, _stat}, _candidate_path, root, resolved_segments, segment, rest) do
    resolve_segments(root, resolved_segments ++ [segment], rest)
  end

  defp resolve_candidate({:error, :enoent}, _candidate_path, root, resolved_segments, segment, rest) do
    {:ok, join_path(root, resolved_segments ++ [segment | rest])}
  end

  defp resolve_candidate({:error, reason}, _candidate_path, _root, _resolved_segments, _segment, _rest) do
    {:error, reason}
  end

  defp join_path(root, segments) when is_list(segments) do
    Enum.reduce(segments, root, fn segment, acc -> Path.join(acc, segment) end)
  end
end
