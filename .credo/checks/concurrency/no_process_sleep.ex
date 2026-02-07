defmodule Credo.Check.Concurrency.NoProcessSleep do
  @moduledoc """
  `Process.sleep/1` should not be used for synchronization as it creates
  non-deterministic timing assumptions that cause flaky tests and race conditions.

  ## Why This Is Critical

  Using `Process.sleep/1` for synchronization is an anti-pattern because:
  - Timing is non-deterministic (varies by system load)
  - Causes flaky tests that pass/fail randomly
  - Hides race conditions instead of fixing them
  - Blocks the scheduler unnecessarily

  ## Bad Example

      # ❌ BAD: Sleep for synchronization
      Task.async(fn -> do_work() end)
      Process.sleep(100)  # Hope work is done?
      check_result()

      # ❌ BAD: Sleep in tests
      test "async operation" do
        start_worker()
        Process.sleep(50)  # Flaky timing assumption
        assert result_ready?()
      end

  ## Good Example

      # ✅ GOOD: Wait for actual completion
      task = Task.async(fn -> do_work() end)
      result = Task.await(task, 5000)

      # ✅ GOOD: Synchronous calls
      :ok = GenServer.call(worker, :do_work)

      # ✅ GOOD: Explicit message waiting in tests
      test "async operation" do
        start_worker()
        assert_receive {:work_done, result}, 1000
      end

      # ✅ GOOD: Non-blocking delays
      Process.send_after(self(), :timeout, 5000)

  ## Configuration

  This check is enabled by default with high priority.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Avoid using `Process.sleep/1` for synchronization.

      `Process.sleep/1` creates non-deterministic timing assumptions that cause
      flaky tests and hide race conditions. Use proper synchronization instead:
      - `Task.await/2` for async operations
      - `GenServer.call/3` for synchronous requests
      - `assert_receive/2` in tests for message waiting
      - `Process.send_after/3` for non-blocking delays
      """
    ]

  @doc false
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(source_file, params \\ []) do
    issue_meta = IssueMeta.for(source_file, params)

    Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
  end

  # Match Process.sleep(arg) calls
  defp traverse(
         {{:., meta, [{:__aliases__, _, [:Process]}, :sleep]}, _, [_arg]} = ast,
         issues,
         issue_meta
       ) do
    {ast, [issue_for(issue_meta, meta[:line]) | issues]}
  end

  defp traverse(ast, issues, _issue_meta) do
    {ast, issues}
  end

  defp issue_for(issue_meta, line_no) do
    format_issue(
      issue_meta,
      message:
        "Avoid Process.sleep for synchronization (use Task.await, GenServer.call, or assert_receive instead)",
      trigger: "Process.sleep",
      line_no: line_no
    )
  end
end
