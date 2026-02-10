defmodule Credo.Check.Warning.RawSpawn do
  @moduledoc """
  Avoid using raw `spawn/1`, `spawn/3`, `spawn_link/1`, `spawn_link/3`.
  Use `Task` or `GenServer` instead for better supervision and error handling.

  ## Why This Matters

  Raw spawn functions bypass OTP supervision and make errors harder to handle:
  - **No supervision** - Crashes don't propagate to supervisors
  - **No monitoring** - Can't detect when process dies
  - **No error handling** - Exceptions disappear silently (spawn/1)
  - **Hard to test** - No way to wait for completion
  - **Memory leaks** - Orphaned processes if parent dies

  Task and GenServer provide proper OTP integration with supervision trees.

  ## Bad Example

      # ❌ BAD: Raw spawn
      def start_worker(data) do
        spawn(fn -> process(data) end)  # Crash disappears silently
      end

      def start_linked(data) do
        spawn_link(fn -> process(data) end)  # Better but still no supervision
      end

      def start_mfa do
        spawn(Worker, :run, [args])  # No way to monitor
      end

  ## Good Example

      # ✅ GOOD: Use Task for simple async work
      def start_worker(data) do
        Task.async(fn -> process(data) end)  # Returns task, can await
      end

      # ✅ GOOD: Use GenServer for stateful processes
      def start_server(args) do
        GenServer.start_link(MyServer, args)  # Supervised, monitored
      end

      # ✅ GOOD: Use DynamicSupervisor for dynamic workers
      def start_worker(args) do
        DynamicSupervisor.start_child(MySup, {Worker, args})
      end

  ## When to Use What

  - `Task.async/1` - Simple one-off async operations, need result
  - `Task.start_link/1` - Fire-and-forget work under supervision
  - `GenServer` - Stateful processes, callbacks, OTP behaviours
  - `DynamicSupervisor` - Many workers with same supervision strategy

  ## Exceptions

  This check skips test files because tests often need raw spawn to:
  - Test spawn-related behavior (can't test spawn without using spawn!)
  - Create mock processes for failure scenarios
  - Simulate process crashes and race conditions

  ## Configuration

  This check runs on production code (lib/) with high priority.
  Part of concurrency safety checks.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Avoid raw spawn/spawn_link - use Task or GenServer instead.

      Raw spawn functions bypass OTP supervision and make errors harder
      to handle. Task and GenServer provide proper supervision and monitoring.
      """
    ]

  @doc false
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(source_file, params \\ []) do
    # Skip test files - they often need raw spawn to test spawn behavior
    if test_file?(source_file) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
    end
  end

  # Match spawn/1 and spawn_link/1
  defp traverse(
         {{:., meta, [{:__aliases__, _, [:Kernel]}, function]}, _, [_fun]} = ast,
         issues,
         issue_meta
       )
       when function in [:spawn, :spawn_link] do
    {ast, [issue_for(issue_meta, meta[:line], function) | issues]}
  end

  # Match spawn/3 and spawn_link/3 (module, function, args)
  defp traverse(
         {{:., meta, [{:__aliases__, _, [:Kernel]}, function]}, _, [_mod, _fun, _args]} = ast,
         issues,
         issue_meta
       )
       when function in [:spawn, :spawn_link] do
    {ast, [issue_for(issue_meta, meta[:line], function) | issues]}
  end

  # Also match unqualified spawn calls (imported from Kernel)
  defp traverse(
         {function, meta, [_fun]} = ast,
         issues,
         issue_meta
       )
       when function in [:spawn, :spawn_link] do
    {ast, [issue_for(issue_meta, meta[:line], function) | issues]}
  end

  defp traverse(
         {function, meta, [_mod, _fun, _args]} = ast,
         issues,
         issue_meta
       )
       when function in [:spawn, :spawn_link] do
    {ast, [issue_for(issue_meta, meta[:line], function) | issues]}
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

  defp issue_for(issue_meta, line_no, function) do
    format_issue(
      issue_meta,
      message:
        "Avoid #{function} - use Task.async/start_link or GenServer for proper supervision and error handling",
      trigger: "#{function}",
      line_no: line_no
    )
  end
end
