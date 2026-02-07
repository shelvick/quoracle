defmodule Credo.Check.Warning.DbgInProduction do
  @moduledoc """
  Don't use `dbg()` in production code. Use `Logger.debug/1` instead.

  ## Why This Matters

  The `dbg()` macro (introduced in Elixir 1.14) is a debugging tool that:
  - **Prints to stdout** - Can't be controlled by log levels
  - **Pollutes output** - Always runs, even in production
  - **Performance overhead** - Evaluates expressions and formats output
  - **No structured logging** - Can't filter, search, or route logs
  - **CI noise** - Clutters test output and CI logs

  `dbg()` is perfect for **temporary debugging during development**, but should
  never be committed to production code.

  ## Bad Example

      # ❌ BAD: dbg() in production code
      defmodule UserService do
        def create_user(params) do
          dbg(params)  # Always prints, can't disable
          result = Repo.insert(changeset)
          dbg(result)  # Pollutes production logs
          result
        end
      end

  ## Good Example

      # ✅ GOOD: Use Logger.debug
      defmodule UserService do
        require Logger

        def create_user(user_attrs) do
          Logger.debug("Creating user")
          result = Repo.insert(changeset)
          Logger.debug("Created successfully")
          result
        end
      end

      # ✅ GOOD: Or remove debugging entirely
      defmodule UserService do
        def create_user(user_attrs) do
          Repo.insert(changeset)
        end
      end

  ## Logger.debug vs dbg()

  **Logger.debug advantages:**
  - Respects log level config (disabled in prod by default)
  - Structured with metadata (module, line, timestamp)
  - Can be routed to different backends
  - Searchable and filterable
  - No performance impact when disabled

  **dbg() use cases (development only):**
  - Quick temporary debugging
  - REPL/IEx sessions
  - One-off investigations
  - **Never committed to version control**

  ## Exceptions

  This check allows `dbg()` in:
  - Test files (`test/**/*_test.exs`)
  - Test support files (`test/support/**/*.ex`)
  - Scripts (`*.exs` files outside lib/)

  ## Configuration

  This check runs on production code (lib/) with high priority.
  Enforces phase-review rule: No debug code in commits.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Don't use dbg() in production code - use Logger.debug instead.

      The dbg() macro prints directly to stdout and can't be controlled by
      log levels. Use Logger.debug for proper structured logging.
      """
    ]

  @doc false
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(source_file, params \\ []) do
    # Skip test files and scripts
    if production_file?(source_file) do
      issue_meta = IssueMeta.for(source_file, params)
      Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
    else
      []
    end
  end

  # Match dbg() calls (unqualified)
  defp traverse(
         {:dbg, meta, _args} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(issue_meta, meta[:line]) | issues]}
  end

  # Match Kernel.dbg() calls
  defp traverse(
         {{:., meta, [{:__aliases__, _, [:Kernel]}, :dbg]}, _, _args} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(issue_meta, meta[:line]) | issues]}
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
  end

  defp production_file?(%{filename: filename}) do
    # Only check lib/ files (production code)
    # Allow test files and scripts
    cond do
      String.starts_with?(filename, "lib/") -> true
      String.contains?(filename, "/lib/") -> true
      String.ends_with?(filename, "_test.exs") -> false
      String.contains?(filename, "/test/") -> false
      String.ends_with?(filename, ".exs") -> false
      true -> false
    end
  end

  defp issue_for(issue_meta, line_no) do
    format_issue(
      issue_meta,
      message:
        "Don't use dbg() in production code - it prints to stdout and can't be controlled. Use Logger.debug(inspect(value)) instead",
      trigger: "dbg",
      line_no: line_no
    )
  end
end
