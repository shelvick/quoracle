defmodule Credo.Check.Warning.GenServerStopFiniteTimeout do
  @moduledoc """
  Always use `:infinity` timeout for `GenServer.stop/3` with DB-connected GenServers.

  ## Why This Matters

  Using a finite timeout (like 1000 or 5000) with `GenServer.stop/3` causes:
  - **Connection leaks** - GenServer killed mid-DB-operation, connection not returned
  - **Postgrex errors** - "owner exited while client was still running"
  - **Test pollution** - Leaked connections affect subsequent tests
  - **Resource exhaustion** - Connection pool depleted over time

  When a GenServer is stopped with a finite timeout:
  1. GenServer tries to terminate cleanly
  2. If timeout expires, process is killed with `:kill` signal
  3. DB connection held by GenServer is not properly cleaned up
  4. Ecto Sandbox owner dies, but GenServer still holds connection reference

  ## Bad Example

      # ❌ BAD: Finite timeout in test cleanup
      test "worker processes data", %{sandbox_owner: owner} do
        {:ok, pid} = GenServer.start_link(Worker, [sandbox_owner: owner])

        on_exit(fn ->
          if Process.alive?(pid) do
            # Kills after 1s!
            stop_timeout = 1000
            GenServer.stop(pid, :normal, stop_timeout)
          end
        end)
      end

      # ❌ BAD: Even 5000ms is finite
      def cleanup(pid) do
        # Still causes leaks
        stop_timeout = 5000
        GenServer.stop(pid, :normal, stop_timeout)
      end

  ## Good Example

      # ✅ GOOD: Infinite timeout
      test "worker processes data", %{sandbox_owner: owner} do
        {:ok, pid} = GenServer.start_link(Worker, [sandbox_owner: owner])

        on_exit(fn ->
          if Process.alive?(pid) do
            try do
              GenServer.stop(pid, :normal, :infinity)  # Wait forever
            catch
              :exit, _ -> :ok
            end
          end
        end)
      end

  ## Why :infinity is Safe

  - GenServer termination is typically fast (milliseconds)
  - If it hangs, there's a real bug you should know about
  - Test will timeout and fail (better than silent connection leak)
  - `:infinity` ensures DB connections are properly cleaned up

  ## When Finite Timeout is OK

  Only for GenServers that:
  - Don't hold DB connections
  - Don't hold any pooled resources
  - Are pure computation without external resources

  **In practice:** Just always use `:infinity`. It's simpler and safer.

  ## Configuration

  This check runs on all files with high priority.
  Prevents DB connection leaks from incomplete GenServer termination.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Use :infinity timeout for GenServer.stop/3 to prevent connection leaks.

      Finite timeouts cause GenServers to be killed before cleanup completes,
      leaking DB connections and causing Postgrex errors.
      """
    ]

  @doc false
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)
    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
  end

  # Match GenServer.stop(pid, reason, timeout) where timeout is an integer
  defp traverse(
         {{:., meta, [{:__aliases__, _, [:GenServer]}, :stop]}, _, [_pid, _reason, timeout]} =
           ast,
         issues,
         issue_meta
       )
       when is_integer(timeout) do
    {ast, [issue_for(issue_meta, meta[:line], timeout) | issues]}
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
  end

  defp issue_for(issue_meta, line_no, timeout) do
    format_issue(
      issue_meta,
      message:
        "GenServer.stop with finite timeout (#{timeout}ms) can cause DB connection leaks. Use :infinity instead to ensure cleanup completes",
      trigger: "GenServer.stop",
      line_no: line_no
    )
  end
end
