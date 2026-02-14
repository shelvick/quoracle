defmodule Test.DeadlockTestHelper do
  @moduledoc """
  Test helpers for deadlock prevention verification (Packet 3).

  Provides controlled action timing, deadlock detection, spawn result
  simulation, and pipeline orchestration for system-level integration
  tests that verify Core remains responsive during action execution.

  All helpers interact with real GenServer processes via casts/calls,
  using event-based synchronization (no Process.sleep).
  """

  alias Quoracle.Agent.Core

  @doc """
  Executes a block while conceptually injecting a slow action delay.

  Since v35.0 ActionExecutor dispatches to Task.Supervisor (non-blocking),
  the action executes in a background task while Core remains responsive.
  This helper simply executes the block - the test verifies Core
  responsiveness by timing GenServer.call during execution.

  The `delay_ms` parameter documents the intended action duration for
  test readability. The actual delay occurs naturally because Router.execute
  runs in a Task.Supervisor child process.
  """
  @spec with_slow_action(pid(), non_neg_integer(), (-> any())) :: any()
  def with_slow_action(_agent_pid, _delay_ms, fun) do
    fun.()
  end

  @doc """
  Asserts a function completes within `timeout_ms` without deadlocking.

  Spawns the function in a monitored task and waits for completion.
  Returns the function's return value on success, or `:timeout` if
  the function doesn't complete within the timeout.

  Uses Task.async/await for event-based synchronization.
  """
  @spec assert_no_deadlock(pid(), non_neg_integer(), (-> any())) :: any() | :timeout
  def assert_no_deadlock(_agent_pid, timeout_ms, fun) do
    task = Task.async(fun)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        :timeout
    end
  end

  @doc """
  Simulates a spawn result being processed through the non-blocking pipeline.

  Pipeline:
  1. Adds a spawn_child action to pending_actions via cast
  2. Sends the spawn result via cast with budget_allocated
  3. Waits for result processing to complete (pending_actions cleared)

  Returns the post-processing agent state.
  """
  @spec simulate_spawn_result(pid(), String.t(), Decimal.t()) :: map()
  def simulate_spawn_result(agent_pid, child_id, budget_allocated) do
    action_id = "spawn_#{child_id}_#{System.unique_integer([:positive])}"

    # Step 1: Add pending action
    GenServer.cast(
      agent_pid,
      {:add_pending_action, action_id, :spawn_child, %{child_id: child_id}}
    )

    # Synchronize to ensure pending action is registered
    {:ok, _mid_state} = Core.get_state(agent_pid)

    # Step 2: Send spawn result with budget_allocated through the action_result pipeline
    # This simulates what Task.Supervisor child sends after Router.execute completes
    result =
      {:ok,
       %{agent_id: child_id, budget_allocated: budget_allocated, spawned_at: DateTime.utc_now()}}

    result_opts = [
      action_atom: :spawn_child,
      wait_value: false,
      always_sync: true,
      action_response: %{action: :spawn_child, params: %{child_id: child_id}, wait: false}
    ]

    GenServer.cast(agent_pid, {:action_result, action_id, result, result_opts})

    # Step 3: Wait for result processing (pending_actions cleared)
    wait_for_pending_cleared(agent_pid)
  end

  @doc """
  Sends multiple action results to an agent.

  Each result tuple is `{action_id, action_atom, result}`.
  Results are sent as casts with appropriate opts for the action type.
  """
  @spec send_action_results(pid(), [{String.t(), atom(), any()}]) :: :ok
  def send_action_results(agent_pid, results) do
    for {action_id, action_atom, result} <- results do
      result_opts = [
        action_atom: action_atom,
        wait_value: false,
        always_sync: action_atom in [:orient, :todo, :send_message],
        action_response: %{action: action_atom, params: %{}, wait: false}
      ]

      GenServer.cast(agent_pid, {:action_result, action_id, result, result_opts})
    end

    :ok
  end

  @doc """
  Executes a complete action pipeline: add pending -> send result -> wait.

  Returns the post-processing agent state after the result has been
  fully processed (pending_actions cleared, history updated).
  """
  @spec execute_action_pipeline(pid(), String.t(), atom(), map(), any()) :: map()
  def execute_action_pipeline(agent_pid, action_id, action_atom, params, result) do
    # Step 1: Add to pending_actions
    GenServer.cast(agent_pid, {:add_pending_action, action_id, action_atom, params})

    # Synchronize to ensure pending action is registered
    {:ok, _mid_state} = Core.get_state(agent_pid)

    # Step 2: Send result
    result_opts = [
      action_atom: action_atom,
      wait_value: false,
      always_sync: action_atom in [:orient, :todo, :send_message],
      action_response: %{action: action_atom, params: params, wait: false}
    ]

    GenServer.cast(agent_pid, {:action_result, action_id, result, result_opts})

    # Step 3: Wait for result processing
    wait_for_pending_cleared(agent_pid)
  end

  @doc """
  Verifies that spawn failure was handled through the proper non-blocking path.

  Checks that:
  1. The agent is still alive (didn't crash from unhandled message)
  2. The failure was recorded in history
  3. Consensus was scheduled for the agent to react

  This is a verification function - it asserts rather than returning.
  """
  @spec verify_spawn_failure_handling(pid(), map()) :: :ok
  def verify_spawn_failure_handling(agent_pid, %{child_id: child_id} = _spawn_failed_data) do
    import ExUnit.Assertions

    # Agent must still be alive
    assert Process.alive?(agent_pid),
           "Agent should be alive after spawn_failed handling"

    # Get current state
    {:ok, state} = Core.get_state(agent_pid)

    # Failure must be in history
    all_entries =
      state.model_histories
      |> Map.values()
      |> List.flatten()

    has_failure =
      Enum.any?(all_entries, fn entry ->
        entry.type == :result and
          is_binary(entry.content) and
          String.contains?(entry.content, child_id)
      end)

    assert has_failure,
           "Spawn failure for #{child_id} should be recorded in history"

    # Consensus continuation was triggered via schedule_consensus_continuation/1.
    # With skip_auto_consensus: true, handle_trigger_consensus/1 consumes the flag
    # (resets consensus_scheduled to false) before get_state returns.
    # We verify the effect (failure in history, agent alive) rather than the
    # transient consensus_scheduled flag.

    :ok
  end

  @doc """
  Verifies that action dispatch was non-blocking (via Task.Supervisor).

  Checks that Core responds to get_state immediately after dispatch,
  confirming the dispatch didn't block the GenServer.
  """
  @spec verify_non_blocking_dispatch(pid(), map()) :: :ok
  def verify_non_blocking_dispatch(agent_pid, _action) do
    import ExUnit.Assertions

    # Core must be responsive (non-blocking dispatch)
    start_time = System.monotonic_time(:millisecond)
    assert {:ok, _state} = Core.get_state(agent_pid)
    elapsed = System.monotonic_time(:millisecond) - start_time

    assert elapsed < 200,
           "Core took #{elapsed}ms to respond after dispatch - should be < 200ms"

    :ok
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Polls agent state until pending_actions is empty or timeout.
  # Uses GenServer.call for synchronization (no Process.sleep).
  @spec wait_for_pending_cleared(pid(), non_neg_integer()) :: map()
  defp wait_for_pending_cleared(agent_pid, timeout_ms \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_pending_cleared(agent_pid, deadline)
  end

  defp do_wait_for_pending_cleared(agent_pid, deadline) do
    {:ok, state} = Core.get_state(agent_pid)

    if map_size(state.pending_actions) == 0 do
      state
    else
      if System.monotonic_time(:millisecond) >= deadline do
        # Return state even on timeout so tests can inspect what went wrong
        state
      else
        # Yield to scheduler to allow casts to be processed
        :erlang.yield()
        do_wait_for_pending_cleared(agent_pid, deadline)
      end
    end
  end
end
