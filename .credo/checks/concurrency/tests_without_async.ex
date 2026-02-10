defmodule Credo.Check.Concurrency.TestsWithoutAsync do
  @moduledoc """
  Test modules should use `async: true` unless there's a documented reason not to.

  ## Why This Is Critical

  Tests with `async: true` run in parallel, providing:
  - **Faster CI builds** - Utilize all CPU cores
  - **Better test isolation** - Forces you to avoid global state
  - **Catch concurrency bugs** - Reveals race conditions early

  If you use `async: false`, it's usually hiding a concurrency bug or global state
  that should be refactored.

  ## Bad Example

      # ❌ BAD: No async option (defaults to false)
      defmodule MyWorkerTest do
        use ExUnit.Case

        test "uses global state" do
          # Tests run sequentially, hiding concurrency issues
        end
      end

      # ❌ BAD: async: false without explanation
      defmodule MyWorkerTest do
        use ExUnit.Case, async: false

        test "works" do
          # WHY is async: false needed?
        end
      end

  ## Good Example

      # ✅ GOOD: Async tests
      defmodule MyWorkerTest do
        use ExUnit.Case, async: true

        test "isolated test" do
          # Runs in parallel
        end
      end

      # ✅ GOOD: async: false with documented reason
      defmodule MyWorkerTest do
        # async: false - Uses ExVCR cassettes (file-based, not thread-safe)
        use ExUnit.Case, async: false

        test "external API" do
          # Reason documented in comment
        end
      end

  ## Valid Reasons for async: false

  - ExVCR cassettes (file-based HTTP recording)
  - Named global PubSub topics shared across components
  - Shared filesystem resources
  - Tests that modify global application config

  **Always document the reason in a comment!**

  ## Configuration

  This check only runs on test files.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Test modules should use `async: true` unless impossible.

      Async tests run in parallel, making CI faster and forcing proper test
      isolation. If you must use `async: false`, document why in a comment
      above the `use ExUnit.Case` line.
      """
    ]

  @doc false
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(source_file, params \\ []) do
    # Only check test files
    if test_file?(source_file) do
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> Credo.Code.ast()
      |> find_test_modules_without_async(source_file)
      |> Enum.map(fn {line, reason} -> issue_for(issue_meta, line, reason) end)
    else
      []
    end
  end

  defp find_test_modules_without_async(ast, source_file) do
    {_ast, violations} =
      Macro.prewalk(ast, [], fn node, acc ->
        case node do
          # Match: use ExUnit.Case
          {:use, meta, [{:__aliases__, _, [:ExUnit, :Case]}]} ->
            # No options means async defaults to false
            {node, [{meta[:line], :missing_async} | acc]}

          # Match: use ExUnit.Case, async: false
          {:use, meta, [{:__aliases__, _, [:ExUnit, :Case]}, opts]} ->
            case Keyword.get(opts, :async) do
              false ->
                # Check if there's a comment explaining why
                if has_explanatory_comment?(source_file, meta[:line]) do
                  {node, acc}
                else
                  {node, [{meta[:line], :async_false_no_comment} | acc]}
                end

              true ->
                # async: true is good
                {node, acc}

              nil ->
                # No async option means defaults to false
                {node, [{meta[:line], :missing_async} | acc]}
            end

          _ ->
            {node, acc}
        end
      end)

    violations
  end

  # Check if there's a comment on the line before `use ExUnit.Case`
  defp has_explanatory_comment?(source_file, use_line) do
    lines = Credo.SourceFile.lines(source_file)

    # Check the line before for a comment mentioning async: false
    prev_line_idx = use_line - 2

    if prev_line_idx >= 0 and prev_line_idx < length(lines) do
      {_line_no, prev_line_content} = Enum.at(lines, prev_line_idx)
      String.contains?(prev_line_content, "#") and String.contains?(prev_line_content, "async")
    else
      false
    end
  end

  defp test_file?(%{filename: filename}) do
    String.ends_with?(filename, "_test.exs") or
      String.starts_with?(filename, "test/") or
      String.contains?(filename, "/test/")
  end

  defp issue_for(issue_meta, line_no, :missing_async) do
    format_issue(
      issue_meta,
      message: "Test module should use `async: true` (or document why async: false is needed)",
      trigger: "use ExUnit.Case",
      line_no: line_no
    )
  end

  defp issue_for(issue_meta, line_no, :async_false_no_comment) do
    format_issue(
      issue_meta,
      message:
        "async: false should be documented with a comment explaining why (e.g., '# async: false - Uses ExVCR cassettes')",
      trigger: "async: false",
      line_no: line_no
    )
  end
end
