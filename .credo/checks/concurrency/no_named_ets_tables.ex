defmodule Credo.Check.Concurrency.NoNamedEtsTables do
  @moduledoc """
  ETS tables should not use the `:named_table` option as it creates global state
  that breaks test isolation when tests run in parallel.

  ## Why This Is Critical

  Named ETS tables create global state that causes race conditions in parallel tests.
  Instead, use process-owned tables and pass the table ID (tid) as parameters.

  ## Bad Example

      # ❌ BAD: Named ETS table
      :ets.new(:cache, [:named_table, :public])
      :ets.new(:my_table, [:named_table])

  ## Good Example

      # ✅ GOOD: Process-owned table
      tid = :ets.new(:cache, [:public])
      # Pass tid explicitly to other processes/functions

  ## Configuration

  This check is enabled by default with high priority.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      ETS tables should not use the `:named_table` option.

      Named ETS tables create global state that causes test isolation issues
      when running tests in parallel (`async: true`). Use process-owned tables
      instead and pass the table ID explicitly as parameters.
      """
    ]

  @doc false
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)

    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
  end

  # Match :ets.new(name, options) calls
  defp traverse(
         {{:., meta, [:ets, :new]}, _, [_name, opts]} = ast,
         issues,
         issue_meta
       ) do
    if has_named_table_option?(opts) do
      {ast, [issue_for(issue_meta, meta[:line]) | issues]}
    else
      {ast, issues}
    end
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
  end

  # Check if options list contains :named_table atom
  defp has_named_table_option?(opts) when is_list(opts) do
    Enum.any?(opts, fn
      :named_table -> true
      _ -> false
    end)
  end

  # Can't statically analyze variable options
  defp has_named_table_option?(_), do: false

  defp issue_for(issue_meta, line_no) do
    format_issue(
      issue_meta,
      message: "Avoid using named ETS tables (use process-owned tables for test isolation)",
      trigger: ":named_table",
      line_no: line_no
    )
  end
end
