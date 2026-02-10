defmodule Credo.Check.Concurrency.NoSetupAll do
  @moduledoc """
  `setup_all` creates shared state between tests, breaking test isolation
  and preventing parallel test execution.

  ## Why This Is Critical

  `setup_all` is an anti-pattern because:
  - Creates state shared across ALL tests in a module
  - Tests become order-dependent and can't run in parallel
  - Forces `async: false` (or causes race conditions if not set)
  - One test's modifications affect other tests
  - Makes tests non-deterministic and harder to debug

  ## Bad Example

      # ❌ BAD: Shared state across all tests
      defmodule MyWorkerTest do
        use ExUnit.Case  # async: false by default

        setup_all do
          {:ok, cache} = Cache.start_link()
          %{cache: cache}
        end

        test "test 1", %{cache: cache} do
          # Modifies shared cache
        end

        test "test 2", %{cache: cache} do
          # Sees modifications from test 1!
        end
      end

  ## Good Example

      # ✅ GOOD: Fresh state per test
      defmodule MyWorkerTest do
        use ExUnit.Case, async: true

        setup do
          {:ok, cache} = start_supervised(Cache)
          %{cache: cache}
        end

        test "test 1", %{cache: cache} do
          # Fresh cache instance
        end

        test "test 2", %{cache: cache} do
          # Different fresh cache instance
        end
      end

  ## Configuration

  This check only runs on test files (`test/**/*.exs`).
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Avoid using `setup_all` in test files.

      `setup_all` creates shared state across all tests, preventing parallel
      execution and making tests order-dependent. Use `setup` instead for
      per-test isolation, which allows `async: true`.
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

  # Match setup_all do ... end
  defp traverse(
         {:setup_all, meta, _args} = ast,
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
      String.starts_with?(filename, "test/") or
      String.contains?(filename, "/test/")
  end

  defp issue_for(issue_meta, line_no) do
    format_issue(
      issue_meta,
      message: "Avoid setup_all - use setup for per-test isolation and async: true support",
      trigger: "setup_all",
      line_no: line_no
    )
  end
end
