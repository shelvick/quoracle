defmodule Credo.Check.Warning.MonitoringSandboxOwner do
  @moduledoc """
  Never monitor the sandbox owner process - use `on_exit` cleanup instead.

  ## Why This Matters

  Monitoring the sandbox_owner process creates a dangerous anti-pattern that causes
  "owner exited while client was still running" errors:

  - **Kills mid-operation** - Monitor triggers when owner exits, killing GenServers during DB operations
  - **Connection leaks** - GenServers don't finish cleanup before being killed
  - **Race conditions** - No guarantee of cleanup order
  - **Test pollution** - Leaked connections affect subsequent tests

  When sandbox_owner is monitored:
  1. Test completes and sandbox_owner exits
  2. Monitor receives :DOWN message
  3. Test process kills all monitored GenServers immediately
  4. GenServers die mid-DB-operation without cleanup
  5. DB connections leak → Postgrex errors

  ## Bad Example

      # ❌ BAD: Monitoring sandbox_owner
      test "worker processes data", %{sandbox_owner: owner} do
        {:ok, pid} = Worker.start_link(sandbox_owner: owner)

        # Anti-pattern: Kills workers mid-operation when owner exits!
        monitor_ref = owner
        ref = Process.monitor(monitor_ref)

        # When owner exits, worker is killed immediately
        # No time for cleanup → connection leak
      end

  ## Good Example

      # ✅ GOOD: Use on_exit with :infinity timeout
      test "worker processes data", %{sandbox_owner: owner} do
        {:ok, pid} = Worker.start_link(sandbox_owner: owner)

        on_exit(fn ->
          if Process.alive?(pid) do
            try do
              GenServer.stop(pid, :normal, :infinity)  # Proper cleanup
            catch
              :exit, _ -> :ok
            end
          end
        end)
      end

  ## Why on_exit is Safe

  - Runs after test completes but before cleanup
  - Gives GenServer time to finish DB operations
  - :infinity timeout ensures cleanup completes
  - Proper shutdown order (children before parents)

  ## Configuration

  This check runs on test files only with high priority.
  Prevents monitoring anti-pattern that causes Postgrex errors.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Never monitor sandbox_owner - use on_exit cleanup instead.

      Monitoring sandbox_owner kills GenServers mid-DB-operation when the owner
      exits, leaking connections and causing Postgrex errors.
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

  # Match Process.monitor(sandbox_owner) or Process.monitor(owner)
  defp traverse(
         {{:., meta, [{:__aliases__, _, [:Process]}, :monitor]}, _, [{var_name, _, _}]} = ast,
         issues,
         issue_meta
       )
       when var_name in [:sandbox_owner, :owner] do
    {ast, [issue_for(issue_meta, meta[:line], var_name) | issues]}
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

  defp issue_for(issue_meta, line_no, var_name) do
    format_issue(
      issue_meta,
      message:
        "Never monitor #{var_name} - kills GenServers mid-DB-operation when owner exits. Use on_exit with GenServer.stop(:infinity) instead",
      trigger: "Process.monitor",
      line_no: line_no
    )
  end
end
