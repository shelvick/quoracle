defmodule Credo.Check.Warning.LiteralMonitorExitReason do
  @moduledoc """
  Avoid matching literal exit reasons in monitor DOWN messages.

  ## Why This Is a Problem

  When monitoring a process, the exit reason depends on timing:
  - `:normal` - process exited normally before or after monitor
  - `:noproc` - process was already dead when monitor was set up
  - `:shutdown` - process was shut down
  - `{:shutdown, reason}` - process shut down with reason

  Matching a specific literal reason causes flaky tests under load.

  ## Bad Example

      # ❌ BAD: Assumes specific exit reason
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

  ## Good Example

      # ✅ GOOD: Accept any clean termination reason
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}
      assert reason in [:normal, :noproc, :shutdown]

  ## Configuration

  This check runs on test files only.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Don't match literal exit reasons in {:DOWN, ...} messages.

      Process exit reasons are timing-dependent. Use a variable and
      assert it's in an acceptable set of values.
      """
    ]

  @literal_reasons [:normal, :noproc, :shutdown, :killed, :kill]

  @doc false
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(source_file, params \\ []) do
    # Only check test files
    if test_file?(source_file) do
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> Credo.Code.ast()
      |> find_literal_exit_reasons()
      |> Enum.map(fn {line, reason} -> issue_for(issue_meta, line, reason) end)
    else
      []
    end
  end

  defp find_literal_exit_reasons(ast) do
    {_ast, violations} =
      Macro.prewalk(ast, [], fn node, acc ->
        case node do
          # Match: assert_receive {:DOWN, _, :process, _, :normal}
          # The pattern is a tuple with 5 elements where last is literal atom
          {:assert_receive, meta,
           [
             {:{}, _,
              [
                :DOWN,
                _ref,
                :process,
                _pid,
                reason
              ]}
             | _rest
           ]} ->
            if literal_exit_reason?(reason) do
              {node, [{meta[:line], reason} | acc]}
            else
              {node, acc}
            end

          # Also match receive do pattern
          # {:DOWN, ref, :process, pid, :normal} -> ...
          {:->, meta,
           [
             [
               {:{}, _,
                [:DOWN, _ref, :process, _pid, reason]}
             ],
             _body
           ]} ->
            if literal_exit_reason?(reason) do
              {node, [{meta[:line], reason} | acc]}
            else
              {node, acc}
            end

          _ ->
            {node, acc}
        end
      end)

    violations
  end

  defp literal_exit_reason?(reason) when reason in @literal_reasons, do: true
  # Pinned variable like ^:normal would be {:^, _, [:normal]}
  defp literal_exit_reason?({:^, _, [reason]}) when reason in @literal_reasons, do: true
  defp literal_exit_reason?(_), do: false

  defp test_file?(%{filename: filename}) do
    String.ends_with?(filename, "_test.exs") or
      String.starts_with?(filename, "test/") or
      String.contains?(filename, "/test/")
  end

  defp issue_for(issue_meta, line_no, reason) do
    format_issue(
      issue_meta,
      message:
        "Literal exit reason #{inspect(reason)} in DOWN pattern - use variable and assert membership",
      trigger: inspect(reason),
      line_no: line_no
    )
  end
end
