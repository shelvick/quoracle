defmodule Credo.Check.Warning.FunctionExportedTest do
  @moduledoc """
  Don't use `function_exported?/3` in tests to check if functions exist.
  Test behavior, not implementation.

  ## Why This Matters

  Using `function_exported?/3` in tests is redundant and creates maintenance issues:
  - **Compiler already checks** - If function doesn't exist, code won't compile
  - **Tests implementation, not behavior** - Doesn't verify the function works correctly
  - **Causes race conditions** - With `async: true`, Code.ensure_loaded!/1 creates conflicts
  - **Brittle tests** - Break when refactoring even if behavior unchanged
  - **No value** - Test passes even if function is completely broken

  The compiler provides better guarantees than runtime checks.

  ## Bad Example

      # ❌ BAD: Testing that function exists
      test "has process function" do
        assert function_exported?(MyModule, :process, 2)
        # What does this prove? Function could be broken!
      end

      # ❌ BAD: Redundant with compiler
      test "implements callback" do
        Code.ensure_loaded!(MyModule)  # Race condition with async: true
        assert function_exported?(MyModule, :handle_call, 3)
      end

  ## Good Example

      # ✅ GOOD: Test the actual behavior
      test "processes data correctly" do
        input = %{name: "test"}
        result = MyModule.process(input, [])  # Compiler errors if missing
        assert {:ok, processed} = result
        assert processed.name == "TEST"
      end

      # ✅ GOOD: Test callback behavior
      test "handles call" do
        state = %{counter: 0}
        {:reply, result, new_state} = MyModule.handle_call(:increment, self(), state)
        assert result == 1
        assert new_state.counter == 1
      end

  ## Compiler vs Runtime

  Compiler guarantees:
  - Function exists with correct arity
  - Module is loadable
  - Types match (with dialyzer)

  Runtime checks can't guarantee:
  - Function works correctly
  - Returns expected values
  - Handles edge cases

  **Always prefer compiler checks over runtime checks.**

  ## Legitimate Uses (Production Code)

  `function_exported?/3` is fine in production code for feature detection:

  ```elixir
  def supports_feature?(module) do
    function_exported?(module, :new_feature, 1)
  end
  ```

  This check only flags usage in **test files**.

  ## Configuration

  This check runs on test files only with high priority.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Don't use function_exported? in tests - test behavior, not implementation.

      The compiler already verifies functions exist. Using function_exported? in
      tests is redundant and can cause race conditions with async: true.
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

  # Match function_exported?/3 calls (unqualified)
  defp traverse(
         {:function_exported?, meta, [_module, _function, _arity]} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(issue_meta, meta[:line]) | issues]}
  end

  # Match Kernel.function_exported?/3 calls
  defp traverse(
         {{:., meta, [{:__aliases__, _, [:Kernel]}, :function_exported?]}, _,
          [_module, _function, _arity]} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(issue_meta, meta[:line]) | issues]}
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
  end

  defp test_file?(%{filename: filename}) do
    String.ends_with?(filename, "_test.exs") or
      String.ends_with?(filename, "test_helper.exs") or
      String.starts_with?(filename, "test/") or
      String.contains?(filename, "/test/")
  end

  defp issue_for(issue_meta, line_no) do
    format_issue(
      issue_meta,
      message:
        "Don't use function_exported? in tests - compiler already verifies functions exist. Test behavior, not implementation",
      trigger: "function_exported?",
      line_no: line_no
    )
  end
end
