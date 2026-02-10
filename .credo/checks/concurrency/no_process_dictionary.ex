defmodule Credo.Check.Concurrency.NoProcessDictionary do
  @moduledoc """
  The Process dictionary should not be used in production code as it doesn't
  propagate to spawned processes, causing subtle bugs.

  ## Why This Is Critical

  The Process dictionary has a major flaw: it does NOT propagate to spawned processes.
  This means:
  - `Task.async` creates a NEW process with an EMPTY dictionary
  - `GenServer.start_link` creates a NEW process with an EMPTY dictionary
  - Any spawned process won't see values set in the parent

  This leads to code that works in simple cases but breaks when you spawn processes,
  which is extremely common in Elixir.

  ## Bad Example

      # ❌ BAD: Process dictionary doesn't propagate
      def get_client do
        Process.get(:test_client) || @default_client
      end

      # In a test:
      Process.put(:test_client, mock_client)
      task = Task.async(fn -> get_client() end)
      # get_client() returns @default_client! Process.get returns nil

  ## Good Example

      # ✅ GOOD: Explicit parameter passing
      def get_client(client) do
        client
      end

      # In a test:
      task = Task.async(fn -> get_client(mock_client) end)
      # Works correctly - client explicitly passed

  ## Exception

  This check allows Process dictionary in test files (`test/**/*.exs`) since
  Ecto.Adapters.SQL.Sandbox uses it internally for test isolation. However,
  even in tests, prefer explicit parameter passing.

  ## Configuration

  This check is enabled by default with high priority.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Avoid using Process dictionary in production code.

      The Process dictionary doesn't propagate to spawned processes (Task.async,
      GenServer.start_link, etc.), causing subtle bugs. Always pass state explicitly
      through function parameters.

      Exception: Allowed in test files for Ecto.Sandbox compatibility.
      """
    ]

  @doc false
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(source_file, params \\ []) do
    # Allow in test files (Ecto.Sandbox uses it)
    if test_file?(source_file) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
    end
  end

  # Match Process.get/put/delete calls
  defp traverse(
         {{:., meta, [{:__aliases__, _, [:Process]}, function]}, _, _args} = ast,
         issues,
         issue_meta
       )
       when function in [:get, :put, :delete] do
    {ast, [issue_for(issue_meta, meta[:line], function) | issues]}
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
  end

  defp test_file?(%{filename: filename}) do
    String.starts_with?(filename, "test/") or String.contains?(filename, "/test/")
  end

  defp issue_for(issue_meta, line_no, function) do
    format_issue(
      issue_meta,
      message:
        "Avoid Process dictionary - it doesn't propagate to spawned processes (Task.async, GenServer, etc.)",
      trigger: "Process.#{function}",
      line_no: line_no
    )
  end
end
