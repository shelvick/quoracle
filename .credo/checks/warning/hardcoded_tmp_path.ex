defmodule Credo.Check.Warning.HardcodedTmpPath do
  @moduledoc """
  Never use hardcoded `/tmp/` paths in tests - use `System.tmp_dir!()` instead.

  ## Why This Matters

  Hardcoded `/tmp/` paths cause several problems in tests:

  - **Portability** - `/tmp` doesn't exist on Windows, breaks CI on different OS
  - **Test isolation** - Multiple tests writing to same path causes race conditions
  - **Cleanup failures** - Leftover files from failed tests affect subsequent runs
  - **Permission issues** - Different systems may have different `/tmp` permissions

  ## Bad Example

      # ❌ BAD: Hardcoded /tmp path
      test "writes config file" do
        File.write!("/tmp/config.json", "{}")
        assert File.exists?("/tmp/config.json")
      end

      # ❌ BAD: Path.join with hardcoded /tmp
      test "reads data" do
        path = Path.join("/tmp", "data.txt")
        File.write!(path, "test")
      end

  ## Good Example

      # ✅ GOOD: Use System.tmp_dir!() with unique subdirectory
      test "writes config file" do
        tmp_dir = Path.join([
          System.tmp_dir!(),
          "my_app_test",
          to_string(System.unique_integer([:positive]))
        ])
        File.mkdir_p!(tmp_dir)

        config_path = Path.join(tmp_dir, "config.json")
        File.write!(config_path, "{}")
        assert File.exists?(config_path)

        on_exit(fn -> File.rm_rf!(tmp_dir) end)
      end

      # ✅ GOOD: Helper function for temp directories
      defp unique_tmp_dir do
        path = Path.join([
          System.tmp_dir!(),
          "test",
          to_string(System.unique_integer([:positive]))
        ])
        File.mkdir_p!(path)
        path
      end

  ## Why Unique Subdirectories

  Even with `System.tmp_dir!()`, you need unique subdirectories because:

  1. **Parallel tests** - `async: true` means multiple tests run simultaneously
  2. **No collisions** - `System.unique_integer([:positive])` ensures unique paths
  3. **Easy cleanup** - `File.rm_rf!/1` on the unique directory cleans everything

  ## Configuration

  This check runs on test files only with high priority.
  Enforces portable, isolated file system operations in tests.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Never use hardcoded /tmp/ paths in tests - use System.tmp_dir!() instead.

      Hardcoded /tmp paths break portability (Windows), cause test isolation issues
      when multiple tests access the same path, and leave behind cleanup problems.
      """
    ]

  @file_functions ~w(write write! read read! rm rm! rm_rf rm_rf! mkdir mkdir! mkdir_p mkdir_p! cp cp! rename rename!)a
  @path_functions ~w(join expand absname)a

  @doc false
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(source_file, params \\ []) do
    if test_file?(source_file) do
      issue_meta = IssueMeta.for(source_file, params)
      Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
    else
      []
    end
  end

  # Match File.<function>("/tmp/...") - direct string literal
  defp traverse(
         {{:., meta, [{:__aliases__, _, [:File]}, func]}, _, [path | _rest]} = ast,
         issues,
         issue_meta
       )
       when func in @file_functions do
    if hardcoded_tmp_path?(path) do
      {ast, [issue_for(issue_meta, meta[:line], "File.#{func}") | issues]}
    else
      {ast, issues}
    end
  end

  # Match Path.join("/tmp", ...) or Path.join(["/tmp", ...])
  defp traverse(
         {{:., meta, [{:__aliases__, _, [:Path]}, func]}, _, args} = ast,
         issues,
         issue_meta
       )
       when func in @path_functions do
    if path_starts_with_tmp?(args) do
      {ast, [issue_for(issue_meta, meta[:line], "Path.#{func}") | issues]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
  end

  # Check if a string literal starts with /tmp
  defp hardcoded_tmp_path?(path) when is_binary(path) do
    String.starts_with?(path, "/tmp/") or path == "/tmp"
  end

  defp hardcoded_tmp_path?(_), do: false

  # Check if Path.join args start with /tmp
  # Path.join("/tmp", "foo") - two arguments
  defp path_starts_with_tmp?([first | _rest]) when is_binary(first) do
    String.starts_with?(first, "/tmp/") or first == "/tmp"
  end

  # Path.join(["/tmp", "foo", "bar"]) - list argument
  defp path_starts_with_tmp?([{:__block__, _, [list]}]) when is_list(list) do
    case list do
      [first | _] when is_binary(first) ->
        String.starts_with?(first, "/tmp/") or first == "/tmp"

      _ ->
        false
    end
  end

  # Path.join(["/tmp", "foo"]) - list literal
  defp path_starts_with_tmp?([[first | _rest]]) when is_binary(first) do
    String.starts_with?(first, "/tmp/") or first == "/tmp"
  end

  defp path_starts_with_tmp?(_), do: false

  defp test_file?(%{filename: filename}) do
    String.ends_with?(filename, "_test.exs") or
      String.ends_with?(filename, "test_helper.exs") or
      String.starts_with?(filename, "test/") or
      String.contains?(filename, "/test/")
  end

  defp issue_for(issue_meta, line_no, trigger) do
    format_issue(
      issue_meta,
      message:
        "Hardcoded /tmp path in #{trigger} - use System.tmp_dir!() with unique subdirectory instead for portability and test isolation",
      trigger: trigger,
      line_no: line_no
    )
  end
end
