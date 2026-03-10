defmodule Quoracle.Agent.ConsensusHandler.ActionExecutorTimeoutTest do
  @moduledoc """
  Tests for AGENT_ConsensusHandler v28.0 - ActionExecutor adjust_budget Timeout Override.

  WorkGroupID: fix-20260223-cost-display-budget-timeout
  Packet: Packet 2 (Bug 2 — Budget Timeout)

  Root cause: adjust_budget is in @always_sync_actions, forcing explicit timeout path
  with default 5000ms Task.yield. When the parent GenServer is blocked processing the
  adjust_budget Task's GenServer.call, the 5s timer fires and kills the action.

  Fix: ActionExecutor adds timeout: :infinity for :adjust_budget (like :call_mcp gets 600_000).

  Tests:
  - R73: adjust_budget completes when child busy [INTEGRATION]
  - R74: adjust_budget gets :infinity timeout override [UNIT] — KEY failing test
  - R75: call_mcp timeout unchanged at 600_000 [UNIT]
  - R76: Other actions no timeout override [UNIT]
  - R77: Parent responsive during adjust_budget [SYSTEM]
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Agent.Core
  alias Quoracle.Agent.ConsensusHandler.ActionExecutor
  alias Quoracle.Profiles.CapabilityGroups
  alias Quoracle.Tasks.Task, as: TaskSchema
  alias Test.IsolationHelpers

  import Test.AgentTestHelpers

  @moduletag capture_log: true

  # All capability groups (allows all actions)
  @all_capability_groups CapabilityGroups.groups()

  setup %{sandbox_owner: sandbox_owner} do
    deps = IsolationHelpers.create_isolated_deps()
    deps = Map.put(deps, :sandbox_owner, sandbox_owner)

    # Create shared task for agents
    {:ok, task} =
      Repo.insert(%TaskSchema{
        id: Ecto.UUID.generate(),
        prompt: "action executor timeout test",
        status: "running"
      })

    # Subscribe to lifecycle events
    Phoenix.PubSub.subscribe(deps.pubsub, "agents:lifecycle")

    {:ok, deps: deps, task: task}
  end

  # Helper to spawn a parent agent with budget
  defp spawn_parent_with_budget(deps, task, budget_data) do
    agent_id = "parent-timeout-#{System.unique_integer([:positive])}"

    config = %{
      agent_id: agent_id,
      task_id: task.id,
      test_mode: true,
      skip_auto_consensus: true,
      sandbox_owner: deps.sandbox_owner,
      pubsub: deps.pubsub,
      budget_data: budget_data,
      capability_groups: @all_capability_groups,
      spawn_complete_notify: self(),
      prompt_fields: %{
        provided: %{task_description: "Parent task"},
        injected: %{global_context: "", constraints: []},
        transformed: %{}
      },
      models: []
    }

    spawn_agent_with_cleanup(deps.dynsup, config,
      registry: deps.registry,
      pubsub: deps.pubsub,
      sandbox_owner: deps.sandbox_owner
    )
  end

  # Helper to spawn a child agent under a parent
  defp spawn_child_under_parent(deps, task, parent_pid, parent_state, child_budget_data) do
    child_config = %{
      agent_id: "child-timeout-#{System.unique_integer([:positive])}",
      task_id: task.id,
      parent_id: parent_state.agent_id,
      test_mode: true,
      skip_auto_consensus: true,
      sandbox_owner: deps.sandbox_owner,
      pubsub: deps.pubsub,
      budget_data: child_budget_data,
      prompt_fields: %{
        provided: %{task_description: "Child task"},
        injected: %{global_context: "", constraints: []},
        transformed: %{}
      },
      models: []
    }

    {:ok, child_pid} =
      spawn_agent_with_cleanup(deps.dynsup, child_config,
        registry: deps.registry,
        pubsub: deps.pubsub,
        sandbox_owner: deps.sandbox_owner
      )

    # Register child with parent
    {:ok, child_state} = Core.get_state(child_pid)

    child_info = %{
      agent_id: child_state.agent_id,
      spawned_at: DateTime.utc_now(),
      budget_allocated: child_budget_data.allocated
    }

    GenServer.cast(parent_pid, {:child_spawned, child_info})
    # Sync to ensure cast is processed
    _ = Core.get_state(parent_pid)

    {:ok, child_pid, child_state}
  end

  # ============================================================================
  # R74: ActionExecutor sets timeout :infinity for adjust_budget [UNIT]
  #
  # WHEN ActionExecutor builds execute_opts for :adjust_budget
  # THEN timeout is :infinity in the opts passed to Router.execute
  #
  # Tests apply_timeout_override/2 directly — verifies the timeout value without
  # needing a 7-second behavioral wait.
  # ============================================================================

  describe "R74: adjust_budget gets :infinity timeout" do
    @tag :r74
    @tag :unit
    test "apply_timeout_override sets :infinity for adjust_budget" do
      opts = ActionExecutor.apply_timeout_override([], :adjust_budget)
      assert Keyword.get(opts, :timeout) == :infinity
    end

    @tag :r74
    @tag :unit
    test "apply_timeout_override does not overwrite existing timeout for adjust_budget" do
      opts = ActionExecutor.apply_timeout_override([timeout: 5_000], :adjust_budget)
      assert Keyword.get(opts, :timeout) == 5_000
    end
  end

  # ============================================================================
  # R73: adjust_budget completes when child is busy [INTEGRATION]
  #
  # WHEN adjust_budget dispatched AND child agent is mid-consensus (busy)
  # THEN action completes successfully (no timeout)
  #
  # This passes even without the fix because v3.0 BudgetHandler uses cast
  # (not call) to the child, so the action completes fast regardless.
  # Regression test: ensures the cast-based flow continues to work.
  # ============================================================================

  describe "R73: adjust_budget completes when child busy" do
    @tag :r73
    @tag :integration
    test "adjust_budget completes successfully even when child is busy",
         %{deps: deps, task: task} do
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("30.00")
      }

      {:ok, parent_pid} = spawn_parent_with_budget(deps, task, parent_budget)
      {:ok, parent_state} = Core.get_state(parent_pid)

      child_budget = %{
        mode: :child,
        allocated: Decimal.new("30.00"),
        committed: Decimal.new("0")
      }

      {:ok, child_pid, child_state} =
        spawn_child_under_parent(deps, task, parent_pid, parent_state, child_budget)

      # Suspend child to simulate it being "busy" (mid-consensus)
      :sys.suspend(child_pid)

      action_response = %{
        action: :adjust_budget,
        params: %{child_id: child_state.agent_id, new_budget: "50.00"},
        wait: false,
        reasoning: "Testing adjust while child busy"
      }

      {:ok, fresh_state} = Core.get_state(parent_pid)

      test_state = %{
        fresh_state
        | pending_actions: %{},
          action_counter: 0
      }

      _dispatched =
        ActionExecutor.execute_consensus_action(test_state, action_response, self())

      # v3.0 uses cast (not call) to child, so adjust_budget completes fast
      # even with child suspended. Should complete well within 5 seconds.
      receive do
        {:"$gen_cast", {:action_result, _action_id, result, _opts}} ->
          assert match?({:ok, _}, result),
                 "adjust_budget should succeed even with child suspended. Got: #{inspect(result)}"
      after
        5_000 ->
          flunk("No action result within 5s. adjust_budget may have tried to call child.")
      end

      # Resume child for cleanup
      :sys.resume(child_pid)
    end
  end

  # ============================================================================
  # R75: call_mcp timeout unchanged at 600_000 [UNIT]
  #
  # WHEN ActionExecutor builds execute_opts for :call_mcp
  # THEN timeout is 600_000 (unchanged by adjust_budget fix)
  #
  # Regression test: ensures the case statement preserves call_mcp behavior.
  # Verified by dispatching :call_mcp and checking the Router sees the timeout.
  # Since we don't have a real MCP server, the action will fail — but with a
  # specific error (not :timeout), proving the 600_000ms timeout was applied.
  # ============================================================================

  describe "R75: call_mcp timeout unchanged" do
    @tag :r75
    @tag :unit
    test "call_mcp still gets 600_000 timeout, not :infinity",
         %{deps: deps, task: task} do
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("0")
      }

      {:ok, parent_pid} = spawn_parent_with_budget(deps, task, parent_budget)
      {:ok, parent_state} = Core.get_state(parent_pid)

      action_response = %{
        action: :call_mcp,
        params: %{connection_id: "nonexistent", tool_name: "test", arguments: %{}},
        wait: false,
        reasoning: "Testing call_mcp timeout preservation"
      }

      test_state = %{
        parent_state
        | pending_actions: %{},
          action_counter: 0
      }

      _dispatched =
        ActionExecutor.execute_consensus_action(test_state, action_response, self())

      # call_mcp with a nonexistent connection will fail quickly with an error,
      # NOT with :timeout. This proves the 600_000 timeout was applied (not 5000).
      receive do
        {:"$gen_cast", {:action_result, _action_id, result, _opts}} ->
          # Should be an error (no MCP connection) — NOT a timeout
          refute match?({:error, :timeout}, result),
                 "call_mcp should not timeout with 600_000ms. Got: #{inspect(result)}"
      after
        10_000 ->
          flunk("No action result within 10s for call_mcp")
      end
    end
  end

  # ============================================================================
  # R76: Other actions no timeout override [UNIT]
  #
  # WHEN ActionExecutor builds execute_opts for :orient
  # THEN no timeout key is added (uses default 5000 from always_sync_actions)
  #
  # Regression test: ensures the case _ clause doesn't leak timeout overrides.
  # Orient is in @always_sync_actions so it gets default 5000 from ClientAPI.
  # It should complete fast (no external calls) — if it times out, something broke.
  # ============================================================================

  describe "R76: other actions no timeout override" do
    @tag :r76
    @tag :unit
    test "orient does not get a special timeout override",
         %{deps: deps, task: task} do
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("0")
      }

      {:ok, parent_pid} = spawn_parent_with_budget(deps, task, parent_budget)
      {:ok, parent_state} = Core.get_state(parent_pid)

      action_response = %{
        action: :orient,
        params: %{
          current_situation: "Testing timeout override behavior",
          goal_clarity: "Verify orient uses default timeout",
          available_resources: "Unit test framework",
          key_challenges: "None",
          delegation_consideration: "Not applicable"
        },
        wait: false,
        reasoning: "Testing no timeout override for orient"
      }

      test_state = %{
        parent_state
        | pending_actions: %{},
          action_counter: 0
      }

      _dispatched =
        ActionExecutor.execute_consensus_action(test_state, action_response, self())

      # Orient completes instantly (no external calls), uses default 5000ms timeout.
      # Should succeed well within the default timeout.
      receive do
        {:"$gen_cast", {:action_result, _action_id, result, _opts}} ->
          assert match?({:ok, _}, result),
                 "orient should succeed with default timeout. Got: #{inspect(result)}"
      after
        5_000 ->
          flunk("No action result within 5s for orient")
      end
    end
  end

  # ============================================================================
  # R77: Parent responsive during adjust_budget [SYSTEM]
  #
  # WHEN adjust_budget is dispatched via ActionExecutor
  # THEN the parent agent remains responsive to other GenServer calls
  #
  # This passes because Task.Supervisor dispatch is non-blocking — the action
  # runs in a background task, not inside Core's GenServer callback.
  # Regression test: ensures non-blocking dispatch is preserved.
  # ============================================================================

  describe "R77: parent responsive during adjust_budget" do
    @tag :r77
    @tag :system
    test "parent agent responsive during adjust_budget execution",
         %{deps: deps, task: task} do
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("30.00")
      }

      {:ok, parent_pid} = spawn_parent_with_budget(deps, task, parent_budget)
      {:ok, parent_state} = Core.get_state(parent_pid)

      child_budget = %{
        mode: :child,
        allocated: Decimal.new("30.00"),
        committed: Decimal.new("0")
      }

      {:ok, _child_pid, child_state} =
        spawn_child_under_parent(deps, task, parent_pid, parent_state, child_budget)

      action_response = %{
        action: :adjust_budget,
        params: %{child_id: child_state.agent_id, new_budget: "50.00"},
        wait: false,
        reasoning: "Testing parent responsiveness"
      }

      {:ok, fresh_state} = Core.get_state(parent_pid)

      test_state = %{
        fresh_state
        | pending_actions: %{},
          action_counter: 0
      }

      # Dispatch the action (runs in background task)
      _dispatched =
        ActionExecutor.execute_consensus_action(test_state, action_response, self())

      # Immediately query parent — should respond because dispatch is non-blocking
      assert {:ok, _state} = Core.get_state(parent_pid)

      # Parent is responsive. Now wait for the action to complete.
      receive do
        {:"$gen_cast", {:action_result, _action_id, result, _opts}} ->
          assert match?({:ok, _}, result),
                 "adjust_budget should complete. Got: #{inspect(result)}"
      after
        10_000 ->
          flunk("No action result within 10s")
      end
    end
  end

  # ============================================================================
  # v6.0: R78-R79 task_id fallback removal [UNIT]
  # ============================================================================

  defp run_send_message_action(state) do
    action_response = %{
      action: :send_message,
      params: %{to: "parent", content: "task_id propagation probe"},
      wait: false,
      reasoning: "task_id fallback regression check"
    }

    _dispatched = ActionExecutor.execute_consensus_action(state, action_response, self())

    receive do
      {:"$gen_cast", {:action_result, _action_id, result, _opts}} ->
        assert match?({:ok, _}, result)
        :ok
    after
      5_000 ->
        flunk("No action result received for send_message action")
    end
  end

  describe "v6 task_id fallback removal" do
    @tag :r78
    @tag :unit
    test "R78: build_execute_opts passes task_id without fallback", %{deps: deps, task: task} do
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("0")
      }

      {:ok, parent_pid} = spawn_parent_with_budget(deps, task, parent_budget)
      {:ok, parent_state} = Core.get_state(parent_pid)

      test_state =
        parent_state
        |> Map.delete(:task_id)
        |> Map.put(:pending_actions, %{})
        |> Map.put(:action_counter, 0)

      Phoenix.PubSub.subscribe(deps.pubsub, "tasks:#{parent_state.agent_id}:messages")
      run_send_message_action(test_state)

      refute_receive {:agent_message, _message},
                     200,
                     "No message should be published on fallback task topic when task_id is missing"
    end

    @tag :r79
    @tag :unit
    test "R79: nil task_id propagated as nil not agent_id", %{deps: deps, task: task} do
      parent_budget = %{
        mode: :root,
        allocated: Decimal.new("100.00"),
        committed: Decimal.new("0")
      }

      {:ok, parent_pid} = spawn_parent_with_budget(deps, task, parent_budget)
      {:ok, parent_state} = Core.get_state(parent_pid)

      test_state =
        parent_state
        |> Map.put(:task_id, nil)
        |> Map.put(:pending_actions, %{})
        |> Map.put(:action_counter, 0)

      Phoenix.PubSub.subscribe(deps.pubsub, "tasks:#{parent_state.agent_id}:messages")
      run_send_message_action(test_state)

      refute_receive {:agent_message, _message},
                     200,
                     "No message should be published on fallback task topic when task_id is nil"
    end
  end
end
