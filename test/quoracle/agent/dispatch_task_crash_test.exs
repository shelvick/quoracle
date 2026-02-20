defmodule Quoracle.Agent.DispatchTaskCrashTest do
  @moduledoc """
  Tests for FIX_DispatchTaskCrashPropagation - Guarantee error delivery on task crash.

  WorkGroupID: fix-20260219-mcp-reliability
  Packet: 1

  Verifies that when a Task.Supervisor child spawned by dispatch_action/8 crashes
  from an uncaught exception, throw, or exit, the agent still receives an error
  result via GenServer.cast -- preventing permanent pending_action stalls.

  ARC Verification Criteria: R1-R6

  ## Crash Mechanism

  The implementation wraps the ENTIRE task body in an outer try/rescue/catch.
  Tests inject crashes via a :crash_in_task key in the agent state, which the
  dispatch_action task body checks before proceeding with normal execution.
  Values: :raise (RuntimeError), :throw (throw), :exit (Process.exit).
  Value :none means crash protection is active but no crash is injected.

  ## How Crash Injection Works (Implemented)

  - R1/R2: The outer rescue/catch in dispatch_action wraps the entire task body.
    The :crash_in_task state key triggers crashes (:raise, :throw, :exit) before
    Router.execute, producing {:error, {:task_crash, _}} via the outer handler.
  - R3: Crash injection fires, {:task_crash, _} error arrives via cast,
    and pending_action is cleared through the crash recovery path.
  - R4: crash_in_task: :none activates the wrapper without injecting a crash.
    The normal path produces {:ok, _} with crash_protected: true in opts.
  - R5: Crash error is stored in agent's model_histories via ActionResultHandler.
  - R6: Uses a real agent. The :dispatch_with_crash cast triggers
    execute_consensus_action with crash_in_task set in state.
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Agent.Core
  alias Quoracle.Agent.ConsensusHandler.ActionExecutor
  alias Quoracle.Agent.MessageHandler.ActionResultHandler

  alias Test.IsolationHelpers

  @moduletag capture_log: true

  # Valid orient params to pass schema validation
  @valid_orient_params %{
    current_situation: "testing crash protection",
    goal_clarity: "verify task crash error delivery",
    available_resources: "test infrastructure",
    key_challenges: "crash injection mechanism",
    delegation_consideration: "none needed"
  }

  # ============================================================================
  # Setup
  # ============================================================================

  setup %{sandbox_owner: sandbox_owner} do
    deps = IsolationHelpers.create_isolated_deps()

    base_state = %{
      agent_id: "agent-crash-#{System.unique_integer([:positive])}",
      task_id: "task-#{System.unique_integer([:positive])}",
      pending_actions: %{},
      model_histories: %{},
      children: [],
      wait_timer: nil,
      timer_generation: 0,
      action_counter: 0,
      state: :processing,
      context_summary: nil,
      context_limit: 4000,
      context_limits_loaded: true,
      additional_context: [],
      test_mode: true,
      skip_auto_consensus: true,
      skip_consensus: true,
      pubsub: deps.pubsub,
      registry: deps.registry,
      dynsup: deps.dynsup,
      sandbox_owner: sandbox_owner,
      queued_messages: [],
      consensus_scheduled: false,
      budget_data: nil,
      over_budget: false,
      dismissing: false,
      capability_groups: [:hierarchy, :local_execution],
      consensus_retry_count: 0,
      prompt_fields: nil,
      system_prompt: nil,
      active_skills: [],
      todos: [],
      parent_pid: nil,
      active_routers: %{},
      shell_routers: %{}
    }

    %{state: base_state, deps: deps, sandbox_owner: sandbox_owner}
  end

  # Helper: spawn a test agent with standard config
  defp spawn_test_agent(deps, sandbox_owner) do
    agent_id = "agent-crash-#{System.unique_integer([:positive])}"

    config = %{
      agent_id: agent_id,
      task_id: Ecto.UUID.generate(),
      test_mode: true,
      skip_auto_consensus: true,
      sandbox_owner: sandbox_owner,
      pubsub: deps.pubsub,
      budget_data: nil,
      prompt_fields: %{
        provided: %{task_description: "Task crash test"},
        injected: %{global_context: "", constraints: []},
        transformed: %{}
      },
      models: [],
      capability_groups: [:hierarchy, :local_execution]
    }

    spawn_agent_with_cleanup(deps.dynsup, config,
      registry: deps.registry,
      pubsub: deps.pubsub,
      sandbox_owner: sandbox_owner
    )
  end

  # Helper: poll agent state until condition is met or timeout.
  defp wait_for_condition(agent_pid, condition_fn, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_condition(agent_pid, condition_fn, deadline)
  end

  defp do_wait_for_condition(agent_pid, condition_fn, deadline) do
    {:ok, state} = Core.get_state(agent_pid)

    if condition_fn.(state) do
      {:ok, state}
    else
      if System.monotonic_time(:millisecond) >= deadline do
        {:timeout, state}
      else
        :erlang.yield()
        do_wait_for_condition(agent_pid, condition_fn, deadline)
      end
    end
  end

  # ============================================================================
  # R1: Rescue catches exceptions
  # [UNIT] WHEN action execution raises an exception (not caught by inner
  # try/catch) THEN outer rescue sends {:error, {:task_crash, message}}
  # to agent via cast.
  #
  # The outer rescue/catch in dispatch_action catches the injected crash
  # and sends {:error, {:task_crash, _}} to the agent via cast.
  # ============================================================================

  describe "R1: rescue catches exceptions" do
    test "rescue catches exceptions and sends error to agent",
         %{state: state} do
      # Inject crash trigger: :raise causes RuntimeError in task body
      # before Router.execute, outside the inner try/catch :exit block.
      state = Map.put(state, :crash_in_task, :raise)

      action_response = %{
        action: :orient,
        params: @valid_orient_params,
        wait: false
      }

      _result_state =
        ActionExecutor.execute_consensus_action(state, action_response, self())

      # The outer rescue catches the raise and sends a task_crash error.
      assert_receive {:"$gen_cast",
                      {:action_result, _action_id, {:error, {:task_crash, message}}, opts}},
                     5000

      assert is_binary(message)
      assert Keyword.has_key?(opts, :action_atom)
      assert opts[:action_atom] == :orient
    end
  end

  # ============================================================================
  # R2: Catch handles throws and exits
  # [UNIT] WHEN action execution throws or exits (not caught by inner
  # try/catch) THEN outer catch sends {:error, {:task_crash, message}}
  # to agent via cast.
  #
  # The outer catch in dispatch_action catches the injected throw/exit
  # and sends {:error, {:task_crash, _}} to the agent via cast.
  # ============================================================================

  describe "R2: catch handles throws and exits" do
    test "catch handles throws and sends error to agent",
         %{state: state} do
      # Inject crash trigger: :throw causes throw in task body
      state = Map.put(state, :crash_in_task, :throw)

      action_response = %{
        action: :orient,
        params: @valid_orient_params,
        wait: false
      }

      _result_state =
        ActionExecutor.execute_consensus_action(state, action_response, self())

      assert_receive {:"$gen_cast",
                      {:action_result, _action_id, {:error, {:task_crash, message}}, opts}},
                     5000

      assert is_binary(message)
      assert opts[:action_atom] == :orient
    end

    test "catch handles exits and sends error to agent",
         %{state: state} do
      # Inject crash trigger: :exit causes non-GenServer exit in task body,
      # outside the inner try/catch scope
      state = Map.put(state, :crash_in_task, :exit)

      action_response = %{
        action: :orient,
        params: @valid_orient_params,
        wait: false
      }

      _result_state =
        ActionExecutor.execute_consensus_action(state, action_response, self())

      assert_receive {:"$gen_cast",
                      {:action_result, _action_id, {:error, {:task_crash, message}}, opts}},
                     5000

      assert is_binary(message)
      assert opts[:action_atom] == :orient
    end
  end

  # ============================================================================
  # R3: Pending action cleared after crash
  # [INTEGRATION] WHEN task crash error received by Core THEN pending_action
  # for that action_id removed from state.
  #
  # Tests the full dispatch path: execute_consensus_action adds to
  # pending_actions, crash injection fires, outer rescue sends cast,
  # assert that the cast contains {:error, {:task_crash, _}} and that
  # the action_id was previously in pending_actions.
  #
  # The crash injection fires, the outer rescue sends {:error, {:task_crash, _}},
  # and ActionResultHandler clears the pending action.
  # ============================================================================

  describe "R3: pending action cleared after crash" do
    test "pending action cleared after task crash error",
         %{state: state} do
      state = Map.put(state, :crash_in_task, :raise)

      action_response = %{
        action: :orient,
        params: @valid_orient_params,
        wait: false
      }

      result_state =
        ActionExecutor.execute_consensus_action(state, action_response, self())

      # After dispatch, pending_actions should contain the action
      assert map_size(result_state.pending_actions) >= 1
      [action_id] = Map.keys(result_state.pending_actions)

      # Receive the crash error cast
      assert_receive {:"$gen_cast",
                      {:action_result, ^action_id, {:error, {:task_crash, _message}}, opts}},
                     5000

      # Feed the crash error through the handler to verify pending is cleared
      {:noreply, new_state} =
        ActionResultHandler.handle_action_result(
          result_state,
          action_id,
          {:error, {:task_crash, "test crash"}},
          opts
        )

      assert map_size(new_state.pending_actions) == 0,
             "Pending action should be cleared after task crash error"
    end
  end

  # ============================================================================
  # R4: Normal path unaffected
  # [INTEGRATION] WHEN action completes normally THEN existing cast behavior
  # unchanged (outer rescue/catch not entered). The crash_in_task: :none
  # option is recognized by the task body but does not trigger a crash.
  #
  # The outer try wrapper sets crash_protected: true in opts to confirm
  # crash protection is active even when no crash occurs.
  # ============================================================================

  describe "R4: normal path unaffected" do
    test "normal action completion unaffected by crash protection",
         %{state: state} do
      # crash_in_task: :none means crash protection wrapper is active
      # but no crash should be injected
      state = Map.put(state, :crash_in_task, :none)

      action_response = %{
        action: :orient,
        params: @valid_orient_params,
        wait: false
      }

      result_state =
        ActionExecutor.execute_consensus_action(state, action_response, self())

      # Action should be dispatched (pending_actions populated)
      assert map_size(result_state.pending_actions) >= 1

      # Normal result should arrive via cast
      assert_receive {:"$gen_cast", {:action_result, _action_id, result, opts}},
                     5000

      # Result should be {:ok, _} -- NOT {:error, {:task_crash, _}}
      assert match?({:ok, _}, result),
             "Expected normal {:ok, _} result but got: #{inspect(result)}"

      refute match?({:error, {:task_crash, _}}, result)

      assert opts[:action_atom] == :orient

      # The outer crash protection wrapper should include a :crash_protected
      # key in result_opts to signal that the task ran inside the outer
      # try/rescue/catch. This confirms the wrapper is active even when
      # no crash occurs.
      # Outer wrapper sets crash_protected: true in opts.
      assert opts[:crash_protected] == true,
             "Expected opts to include crash_protected: true from the outer " <>
               "try/rescue/catch wrapper. Current opts keys: #{inspect(Keyword.keys(opts))}"
    end
  end

  # ============================================================================
  # R5: Error stored in history
  # [INTEGRATION] WHEN task crash error received by Core THEN error stored
  # in agent's model_histories.
  #
  # Tests the full flow through handle_action_result: the crash error
  # is stored as a :result entry in all model histories.
  #
  # The crash error is stored as a :result entry in all model histories
  # via ActionResultHandler.
  # ============================================================================

  describe "R5: error stored in history" do
    test "task crash error stored in agent history",
         %{state: state} do
      state = Map.put(state, :crash_in_task, :raise)

      action_response = %{
        action: :orient,
        params: @valid_orient_params,
        wait: false
      }

      result_state =
        ActionExecutor.execute_consensus_action(state, action_response, self())

      [action_id] = Map.keys(result_state.pending_actions)

      # Receive crash error cast
      assert_receive {:"$gen_cast",
                      {:action_result, ^action_id, {:error, {:task_crash, crash_message}}, opts}},
                     5000

      # Feed through handler to verify history storage
      {:noreply, new_state} =
        ActionResultHandler.handle_action_result(
          result_state,
          action_id,
          {:error, {:task_crash, crash_message}},
          opts
        )

      # The crash error should be stored in at least one model history.
      # Note: `content` is JSON-normalized by StateUtils.add_history_entry_with_action,
      # so check the `result` field which stores the raw tuple.
      has_crash_in_history =
        new_state.model_histories
        |> Map.values()
        |> List.flatten()
        |> Enum.any?(fn entry ->
          match?(
            %{type: :result, result: {:error, {:task_crash, _}}},
            entry
          )
        end)

      assert has_crash_in_history,
             "Task crash error should be stored in agent model_histories"
    end
  end

  # ============================================================================
  # R6: Agent continues after action crash (System)
  # [SYSTEM] WHEN agent dispatches action via consensus AND action task
  # crashes (raise/throw/exit) THEN agent receives error in history AND
  # pending_action is cleared AND agent proceeds to next consensus round
  # (does not stall).
  #
  # Uses a real agent process. The crash injection dispatches an action
  # through the agent's consensus handler, the task crashes, and the
  # agent should recover.
  #
  # The :dispatch_with_crash cast is handled by Core, which sets
  # crash_in_task in state and runs execute_consensus_action. The agent
  # recovers and can process subsequent messages.
  # ============================================================================

  describe "R6: agent continues after action crash" do
    @tag :system
    test "agent continues processing after action task crash",
         %{deps: deps, sandbox_owner: sandbox_owner} do
      {:ok, agent_pid} = spawn_test_agent(deps, sandbox_owner)

      # Verify agent starts clean
      {:ok, initial_state} = Core.get_state(agent_pid)
      assert map_size(initial_state.pending_actions) == 0

      # Step 1: Dispatch an action that crashes in the task via the agent.
      # The :dispatch_with_crash cast tells Core to run
      # execute_consensus_action with crash_in_task set in state.
      # This is the crash injection entry point for system-level testing.
      GenServer.cast(agent_pid, {:dispatch_with_crash, :orient, @valid_orient_params, :raise})

      # Step 2: Wait for the crash error to be processed
      {crash_result, state_after_crash} =
        wait_for_condition(agent_pid, fn state ->
          # Check for crash error in history.
          # Note: `content` is JSON-normalized; use `result` field for raw tuple.
          Enum.any?(Map.values(state.model_histories), fn history ->
            Enum.any?(history, fn entry ->
              match?(%{type: :result, result: {:error, {:task_crash, _}}}, entry)
            end)
          end)
        end)

      # Crash error should appear in history after agent processes it.
      assert crash_result == :ok,
             "Agent did not process crash error. " <>
               "Pending actions: #{map_size(state_after_crash.pending_actions)}, " <>
               "History types: #{inspect(get_history_types(state_after_crash))}"

      # Step 3: Verify pending_actions are cleared
      assert map_size(state_after_crash.pending_actions) == 0,
             "Pending action should be cleared after task crash"

      # Step 4: Verify agent can still process messages (not stalled).
      # Use {:send_user_message, ...} which routes through handle_agent_message
      # with :user sender_id, storing as :event type with from/content map.
      GenServer.cast(agent_pid, {:send_user_message, "Are you alive after crash?"})

      {msg_result, _final_state} =
        wait_for_condition(agent_pid, fn state ->
          Enum.any?(Map.values(state.model_histories), fn history ->
            Enum.any?(history, fn entry ->
              case entry do
                %{type: :event, content: %{from: "user", content: content}}
                when is_binary(content) ->
                  content =~ "Are you alive"

                _ ->
                  false
              end
            end)
          end)
        end)

      assert msg_result == :ok,
             "Agent stalled after crash -- could not process subsequent message"
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp get_history_types(state) do
    state.model_histories
    |> Map.values()
    |> List.flatten()
    |> Enum.map(fn entry -> Map.get(entry, :type, :unknown) end)
  end
end
