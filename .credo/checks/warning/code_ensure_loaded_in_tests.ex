defmodule Credo.Check.Warning.CodeEnsureLoadedInTests do
  @moduledoc """
  `Code.ensure_loaded!/1` and `Code.ensure_loaded?/1` should not be used in test files.

  ## Why This Is Critical

  Using `Code.ensure_loaded!/1` in tests with `async: true` causes race conditions.
  Multiple tests loading the same module simultaneously can lead to non-deterministic
  failures.

  More importantly, the compiler already verifies that modules exist. Testing for
  module existence is testing the **compiler**, not your code behavior.

  ## Bad Example

      # ❌ BAD: Testing module exists (compiler already does this)
      test "module exists" do
        Code.ensure_loaded!(MyModule)
        assert function_exported?(MyModule, :process, 2)
      end

  ## Good Example

      # ✅ GOOD: Test behavior, not implementation
      test "processes data correctly" do
        result = MyModule.process(input, opts)
        # Compiler errors if MyModule.process/2 doesn't exist
        assert {:ok, processed} = result
      end

  ## Why This Works

  - If `MyModule` doesn't exist, the compiler will error
  - If `MyModule.process/2` doesn't exist, the compiler will error
  - You're testing actual behavior, not module existence

  ## Configuration

  This check only runs on test files with high priority.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Avoid `Code.ensure_loaded!/1` and `Code.ensure_loaded?/1` in test files.

      These functions cause race conditions with `async: true` and test the
      compiler instead of your code. Test behavior directly - the compiler
      will error if modules don't exist.
      """
    ]

  @doc false
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(source_file, params \\ []) do
    # Only check test files
    if test_file?(source_file) do
      issue_meta = IssueMeta.for(source_file, params)
      Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
    else
      []
    end
  end

  # Match Code.ensure_loaded!/1
  defp traverse(
         {{:., meta, [{:__aliases__, _, [:Code]}, :ensure_loaded!]}, _, _args} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(issue_meta, meta[:line], :ensure_loaded!) | issues]}
  end

  # Match Code.ensure_loaded?/1
  defp traverse(
         {{:., meta, [{:__aliases__, _, [:Code]}, :ensure_loaded?]}, _, _args} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(issue_meta, meta[:line], :ensure_loaded?) | issues]}
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
  end

  defp test_file?(%{filename: filename}) do
    String.ends_with?(filename, "_test.exs") or
      String.starts_with?(filename, "test/") or
      String.contains?(filename, "/test/")
  end

  defp issue_for(issue_meta, line_no, function) do
    format_issue(
      issue_meta,
      message:
        "Avoid Code.#{function} in tests - causes race conditions with async: true. Test behavior instead (compiler verifies modules exist)",
      trigger: "Code.#{function}",
      line_no: line_no
    )
  end
end
