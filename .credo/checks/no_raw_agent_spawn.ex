defmodule Credo.Check.Custom.NoRawAgentSpawn do
  @moduledoc """
  Prevents spawning agents in tests without using test helpers.

  This check prevents orphaned processes and DB connection leaks by enforcing
  the use of spawn_agent_with_cleanup instead of raw agent spawning.

  ## Forbidden patterns in test files:
  - DynSup.start_agent(...)
  - GenServer.start_link(Core, ...)
  - DynamicSupervisor.start_child(...)
  - Agent.start_link(...)

  ## Required patterns:
  - spawn_agent_with_cleanup(dynsup, config, opts)
  - create_task_with_cleanup(prompt, opts)
  - start_supervised!({Core, ...})

  ## Why this matters:
  Without proper cleanup, spawned agents hold DB connections, causing:
  - Postgrex "owner exited while client was still running" errors
  - Race conditions between parallel tests
  - Non-deterministic test failures

  ## Configuration:
  Add to .credo.exs:
  ```elixir
  {Credo.Check.Custom.NoRawAgentSpawn, []}
  ```
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Use spawn_agent_with_cleanup instead of raw agent spawning in tests.

      Raw agent spawning without proper cleanup causes DB connection leaks.
      """
    ]

  @doc false
  def run(%SourceFile{filename: filename} = source_file, params) do
    # Only check test files
    if String.contains?(filename, "/test/") do
      issue_meta = IssueMeta.for(source_file, params)

      case Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta), []) do
        {_ast, issues} when is_list(issues) -> issues
        issues when is_list(issues) -> issues
        _ -> []
      end
    else
      []
    end
  end

  # Catch DynSup.start_agent calls
  defp traverse(
         {:., meta, [{:__aliases__, _, [:DynSup]}, :start_agent]} = ast,
         issues,
         issue_meta
       ) do
    new_issue = issue_for(issue_meta, meta[:line], "DynSup.start_agent", "spawn_agent_with_cleanup")
    {ast, [new_issue | issues]}
  end

  # Catch GenServer.start_link(Core, ...) calls
  defp traverse(
         {:., meta,
          [
            {:__aliases__, _, [:GenServer]},
            :start_link
          ]} = ast,
         issues,
         issue_meta
       ) do
    new_issue = issue_for(issue_meta, meta[:line], "GenServer.start_link", "start_supervised!")
    {ast, [new_issue | issues]}
  end

  # Catch DynamicSupervisor.start_child calls
  defp traverse(
         {:., meta,
          [
            {:__aliases__, _, [:DynamicSupervisor]},
            :start_child
          ]} = ast,
         issues,
         issue_meta
       ) do
    new_issue =
      issue_for(issue_meta, meta[:line], "DynamicSupervisor.start_child", "spawn_agent_with_cleanup")

    {ast, [new_issue | issues]}
  end

  # Catch DynamicSupervisor.start_link calls (should use start_supervised!)
  defp traverse(
         {:., meta,
          [
            {:__aliases__, _, [:DynamicSupervisor]},
            :start_link
          ]} = ast,
         issues,
         issue_meta
       ) do
    new_issue =
      issue_for(issue_meta, meta[:line], "DynamicSupervisor.start_link", "start_supervised!")

    {ast, [new_issue | issues]}
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
  end

  defp issue_for(issue_meta, line, forbidden_call, recommended_alternative) do
    format_issue(
      issue_meta,
      message:
        "Use #{recommended_alternative} instead of #{forbidden_call} in tests to ensure proper cleanup",
      line_no: line,
      trigger: forbidden_call
    )
  end
end
