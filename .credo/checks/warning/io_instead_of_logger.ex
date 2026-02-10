defmodule Credo.Check.Warning.IoInsteadOfLogger do
  @moduledoc """
  Don't use `IO.puts/warn/inspect` in test files - they pollute test output.

  ## Why This Matters

  `IO.puts`, `IO.warn`, and `IO.inspect` in tests pollute test output:
  - **Can't be silenced** - Always print, even with `async: true`
  - **Clutter CI logs** - Make it hard to find real failures
  - **Don't respect ExUnit.CaptureLog** - Bypass test capture
  - **Hide real output** - Mix with actual test results
  - **Not assertions** - Don't verify behavior

  Tests should either:
  - Use `ExUnit.CaptureLog` if you need to verify logging
  - Use assertions to verify behavior (not debug output)
  - Remove debug statements before committing

  ## Bad Example

      # ❌ BAD: IO.puts pollutes test output
      defmodule MyModuleTest do
        use ExUnit.Case

        test "processes data" do
          IO.puts("Starting test...")  # Clutters output
          result = MyModule.process(data)
          IO.inspect(result, label: "Debug")  # Not an assertion
          assert result == expected
        end
      end

  ## Good Example

      # ✅ GOOD: Clean test output
      defmodule MyModuleTest do
        use ExUnit.Case

        test "processes data" do
          result = MyModule.process(data)
          assert result == expected
        end
      end

      # ✅ GOOD: Verify logging with capture_log
      defmodule MyModuleTest do
        use ExUnit.Case
        import ExUnit.CaptureLog

        test "logs processing" do
          log = capture_log(fn ->
            MyModule.process(data)
          end)

          assert log =~ "Processing data"
        end
      end

  ## Exceptions

  This check only runs on **test files**. Production code can use IO.puts
  for legitimate purposes (CLI tools, scripts, mix tasks).

  ## Configuration

  This check runs on test files only with high priority.
  Prevents test output pollution.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Don't use IO.puts/warn/inspect in test files - they pollute output.

      IO functions in tests clutter test output and make CI logs hard to read.
      Use assertions or ExUnit.CaptureLog instead.
      """
    ]

  # IO functions used for logging (exclude file I/O like read/write)
  @logging_functions [:puts, :warn, :inspect]

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

  # Match IO.puts, IO.warn, IO.inspect
  defp traverse(
         {{:., meta, [{:__aliases__, _, [:IO]}, function]}, _, _args} = ast,
         issues,
         issue_meta
       )
       when function in @logging_functions do
    {ast, [issue_for(issue_meta, meta[:line], function) | issues]}
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
        "Don't use IO.#{function} in tests - it pollutes test output. Use assertions to verify behavior or ExUnit.CaptureLog to test logging",
      trigger: "IO.#{function}",
      line_no: line_no
    )
  end
end
