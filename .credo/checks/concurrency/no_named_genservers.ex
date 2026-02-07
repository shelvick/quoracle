defmodule Credo.Check.Concurrency.NoNamedGenServers do
  @moduledoc """
  GenServers should not use the `name:` option as it creates global state
  that breaks test isolation when tests run in parallel.

  ## Why This Is Critical

  Named processes create global state that causes race conditions in parallel tests.
  Instead, use PIDs directly and pass them as parameters.

  ## Bad Example

      # ❌ BAD: Named GenServer
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      GenServer.start_link(Worker, [], name: :my_worker)

  ## Good Example

      # ✅ GOOD: Use PIDs
      {:ok, pid} = GenServer.start_link(__MODULE__, opts)
      # Pass pid explicitly to other processes/functions

  ## Configuration

  This check is enabled by default with high priority.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      GenServers should not use the `name:` option.

      Named processes create global state that causes test isolation issues
      when running tests in parallel (`async: true`). Use PIDs instead and
      pass them explicitly as parameters.
      """
    ]

  @doc false
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)

    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
  end

  # Match GenServer.start_link or GenServer.start with name option
  defp traverse(
         {{:., meta, [{:__aliases__, _, [:GenServer]}, function]}, _,
          [_module, _init_arg, opts]} = ast,
         issues,
         issue_meta
       )
       when function in [:start_link, :start] do
    if has_name_option?(opts) do
      {ast, [issue_for(issue_meta, meta[:line]) | issues]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
  end

  # Check if keyword list contains name: option
  defp has_name_option?(opts) when is_list(opts) do
    Enum.any?(opts, fn
      {:name, _} -> true
      _ -> false
    end)
  end

  defp has_name_option?(_), do: false

  defp issue_for(issue_meta, line_no) do
    format_issue(
      issue_meta,
      message: "Avoid using named GenServers (use PIDs for test isolation)",
      trigger: "name:",
      line_no: line_no
    )
  end
end
