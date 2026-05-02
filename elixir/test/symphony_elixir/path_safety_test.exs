defmodule SymphonyElixir.PathSafetyTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.PathSafety

  test "canonicalize resolves existing symlink path segments" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-path-safety-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      actual_root = Path.join(test_root, "actual")
      linked_root = Path.join(test_root, "linked")
      nested_path = Path.join(actual_root, "nested")
      expected_path = Path.expand(nested_path)

      File.mkdir_p!(nested_path)

      case File.ln_s(actual_root, linked_root) do
        :ok ->
          assert {:ok, ^expected_path} =
                   PathSafety.canonicalize(Path.join(linked_root, "nested"))

        {:error, reason} when reason in [:eperm, :eacces] ->
          :ok

        {:error, reason} ->
          flunk("failed to create symlink #{inspect(linked_root)}: #{inspect(reason)}")
      end
    after
      File.rm_rf(test_root)
    end
  end

  test "canonicalize returns non-enoent lstat errors" do
    if windows?() do
      :ok
    else
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-path-safety-lstat-error-#{System.unique_integer([:positive])}"
        )

      locked_path = Path.join(test_root, "locked")
      child_path = Path.join(locked_path, "child")
      expanded_path = Path.expand(child_path)

      try do
        File.mkdir_p!(locked_path)
        :ok = File.chmod(locked_path, 0o000)

        assert {:error, {:path_canonicalize_failed, ^expanded_path, reason}} =
                 PathSafety.canonicalize(child_path)

        assert reason in [:eacces, :eperm]
      after
        File.chmod(locked_path, 0o700)
        File.rm_rf(test_root)
      end
    end
  end

  defp windows?, do: match?({:win32, _}, :os.type())
end
