defmodule Quoracle.Agent.ConsensusContinuationTest do
  @moduledoc """
  Tests for consensus continuation fix (Packet 2)

  WorkGroupID: fix-20260117-consensus-continuation
  Packet: 2 (Caller Updates + Integration)
  Requirements: R8-R21, A1-A3

  Bug: Self-contained actions (`:todo`, `:orient`) with wait:false don't auto-continue
  because ActionExecutor sends `:trigger_consensus` but never sets `consensus_scheduled = true`,
  causing the staleness check to ignore the trigger.

  Fix: All callers now use StateUtils.schedule_consensus_continuation/1 which sets the flag.
  WaitFlow no longer sends any triggers (moved to Agent layer).
  """
  use Quoracle.DataCase, async: true

  import ExUnit.CaptureLog

  alias Quoracle.Agent.StateUtils
  alias Quoracle.Agent.Core.MessageInfoHandler
  alias Quoracle.Actions.Router.WaitFlow

  # =============================================================
  # Test Infrastructure
  # =============================================================

  defp unique_id, do: "agent-#{System.unique_integer([:positive])}"

  defp create_isolated_infrastructure do
    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    dynsup_name = :"test_dynsup_#{System.unique_integer([:positive])}"

    start_supervised!({Registry, keys: :unique, name: registry_name})
    start_supervised!({Phoenix.PubSub, name: pubsub_name})
    start_supervised!({DynamicSupervisor, name: dynsup_name, strategy: :one_for_one})

    %{registry: registry_name, pubsub: pubsub_name, dynsup: dynsup_name}
  end

  defp create_test_state(infra, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id, unique_id())

    %{
      agent_id: agent_id,
      router_pid: self(),
      registry: infra.registry,
      dynsup: infra.dynsup,
      pubsub: infra.pubsub,
      model_histories: %{"model1" => []},
      models: ["model1"],
      pending_actions: %{},
      queued_messages: [],
      consensus_scheduled: false,
      wait_timer: nil,
      skip_auto_consensus: true,
      test_mode: true,
      context_limits_loaded: true,
      context_limit: 4000,
      context_lessons: %{},
      model_states: %{},
      action_counter: 0
    }
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  # =============================================================
  # [UNIT] R8-R12: Source Verification
  # =============================================================

  describe "[UNIT] R8: handle_wait_parameter Uses Helper" do
    test "consensus_handler source uses schedule_consensus_continuation" do
      source = File.read!("lib/quoracle/agent/consensus_handler.ex")

      # Should use the helper for wait:false/0 cases
      assert String.contains?(source, "StateUtils.schedule_consensus_continuation"),
             "ConsensusHandler should use StateUtils.schedule_consensus_continuation"
    end

    test "consensus_handler has no raw send for wait:false case" do
      source = File.read!("lib/quoracle/agent/consensus_handler.ex")

      # Should NOT have raw send(self(), :trigger_consensus) for wait:false/0 case
      # The pattern is: `v when v in [false, 0] -> send(self(), :trigger_consensus)`
      refute Regex.match?(~r/v when v in \[false, 0\] ->\s*\n\s*send\(self\(\)/, source),
             "ConsensusHandler should not have raw send for wait:false/0"
    end
  end

  describe "[UNIT] R9-R10: ActionExecutor Uses Helper" do
    test "action_executor dispatches async - continuation handled by MessageHandler" do
      # v35.0: ActionExecutor dispatches to Task.Supervisor (non-blocking).
      # Consensus continuation is now handled by MessageHandler.handle_action_result_continuation/3,
      # which uses StateUtils.schedule_consensus_continuation.
      # ActionExecutor itself no longer calls schedule_consensus_continuation directly.
      source = File.read!("lib/quoracle/agent/consensus_handler/action_executor.ex")
      handler_source = File.read!("lib/quoracle/agent/message_handler.ex")

      # ActionExecutor dispatches via Task.Supervisor (non-blocking pattern)
      assert String.contains?(source, "Task.Supervisor.start_child"),
             "ActionExecutor should dispatch via Task.Supervisor"

      assert String.contains?(source, "GenServer.cast(agent_pid, {:action_result"),
             "ActionExecutor should send results via GenServer.cast"

      # MessageHandler handles continuation using the helper
      assert String.contains?(handler_source, "StateUtils.schedule_consensus_continuation"),
             "MessageHandler should use StateUtils.schedule_consensus_continuation for continuation"
    end

    test "action_executor has no raw trigger_consensus sends" do
      source = File.read!("lib/quoracle/agent/consensus_handler/action_executor.ex")

      # Should NOT have raw send(self(), :trigger_consensus) or send(agent_pid, :trigger_consensus)
      raw_sends =
        Regex.scan(~r/send\((?:self\(\)|agent_pid), :trigger_consensus\)/, source)

      assert raw_sends == [],
             "ActionExecutor should not have raw trigger_consensus sends, found: #{inspect(raw_sends)}"
    end
  end

  describe "[UNIT] R11-R12: WaitFlow No Triggers" do
    test "wait_flow source has no trigger_consensus sends" do
      source = File.read!("lib/quoracle/actions/router/wait_flow.ex")

      # Should NOT have any :trigger_consensus sends
      refute String.contains?(source, ":trigger_consensus"),
             "WaitFlow should not contain :trigger_consensus"
    end

    test "wait_flow source has no Process.send_after" do
      source = File.read!("lib/quoracle/actions/router/wait_flow.ex")

      # Should NOT have any timer creation
      refute String.contains?(source, "Process.send_after"),
             "WaitFlow should not contain Process.send_after"
    end
  end

  # =============================================================
  # [INTEGRATION] R13-R18: Self-Contained Actions
  # =============================================================

  describe "[INTEGRATION] R13-R16: Action Continuation" do
    setup do
      infra = create_isolated_infrastructure()
      {:ok, infra: infra}
    end

    test "orient action with wait:false sets consensus_scheduled flag", %{infra: infra} do
      import Quoracle.Agent.ConsensusTestHelpers, only: [execute_and_collect_result: 2]

      # Suppress expected error logs from action execution
      capture_log(fn ->
        state = create_test_state(infra)

        action_response = %{
          action: :orient,
          params: %{situation_analysis: "Test analysis"},
          wait: false
        }

        # v35.0: Use async helper - dispatches, receives cast, processes through MessageHandler
        result_state = execute_and_collect_result(state, action_response)

        # The key assertion: consensus_scheduled must be set to true
        assert result_state.consensus_scheduled == true,
               "Orient action with wait:false should set consensus_scheduled to true"

        # Should also have sent the trigger message
        assert_receive :trigger_consensus
      end)
    end

    test "todo action with wait:false sets consensus_scheduled flag", %{infra: infra} do
      import Quoracle.Agent.ConsensusTestHelpers, only: [execute_and_collect_result: 2]

      # Suppress expected error logs from action execution
      capture_log(fn ->
        state = create_test_state(infra)

        action_response = %{
          action: :todo,
          params: %{items: [%{content: "Test task", status: :todo}]},
          wait: false
        }

        # v35.0: Use async helper
        result_state = execute_and_collect_result(state, action_response)

        assert result_state.consensus_scheduled == true,
               "Todo action with wait:false should set consensus_scheduled to true"

        assert_receive :trigger_consensus
      end)
    end

    test "error case still sets consensus_scheduled flag", %{infra: infra} do
      import Quoracle.Agent.ConsensusTestHelpers, only: [execute_and_collect_result: 2]

      # Suppress expected error logs from action execution
      capture_log(fn ->
        state = create_test_state(infra)

        # Use action that will error
        action_response = %{
          action: :send_message,
          params: %{target: :nonexistent_target, content: "test"},
          wait: false
        }

        # v35.0: Use async helper
        result_state = execute_and_collect_result(state, action_response)

        # Should still set flag even on error path
        assert result_state.consensus_scheduled == true,
               "Error case should still set consensus_scheduled to true"
      end)
    end

    test "R15: all self-contained actions with wait:false auto-continue", %{infra: infra} do
      import Quoracle.Agent.ConsensusTestHelpers, only: [execute_and_collect_result: 2]

      # Suppress expected error logs from action execution
      capture_log(fn ->
        # Self-contained actions that complete synchronously
        # Note: :wait and :generate_secret go through Router which causes self-call
        # in this test context, so we test the ones that work directly
        self_contained_actions = [:todo, :orient, :send_message]

        for action <- self_contained_actions do
          state = create_test_state(infra)
          params = build_valid_params(action)
          flush_mailbox()

          action_response = %{action: action, params: params, wait: false}
          # v35.0: Use async helper
          result_state = execute_and_collect_result(state, action_response)

          assert result_state.consensus_scheduled == true,
                 "Action #{action} did not set consensus_scheduled"

          # Clear trigger message for next iteration
          assert_receive :trigger_consensus
        end
      end)
    end
  end

  # Helper to build params for self-contained actions
  # These params trigger the error path (missing required fields) which still tests
  # that consensus_scheduled gets set via the error handler
  defp build_valid_params(:todo), do: %{items: [%{content: "Test task", status: :todo}]}
  defp build_valid_params(:orient), do: %{situation_analysis: "Test analysis"}
  defp build_valid_params(:send_message), do: %{target: :parent, content: "test message"}

  describe "[INTEGRATION] R17-R18: Staleness Check Compatibility" do
    setup do
      infra = create_isolated_infrastructure()
      {:ok, infra: infra}
    end

    test "trigger with consensus_scheduled=true passes staleness check", %{infra: infra} do
      state =
        create_test_state(infra)
        |> Map.put(:consensus_scheduled, true)

      {:noreply, result_state} = MessageInfoHandler.handle_trigger_consensus(state)

      # Should process (clear flag), not ignore
      assert result_state.consensus_scheduled == false,
             "Valid trigger should clear consensus_scheduled flag"
    end

    test "orphan trigger without flag is still ignored", %{infra: infra} do
      state =
        create_test_state(infra)
        |> Map.put(:consensus_scheduled, false)
        |> Map.put(:wait_timer, nil)

      initial_state = state
      {:noreply, result_state} = MessageInfoHandler.handle_trigger_consensus(state)

      # Should be ignored (state unchanged)
      assert result_state == initial_state,
             "Orphan trigger should be ignored (state unchanged)"
    end
  end

  # =============================================================
  # [PROPERTY] R19-R21: Invariants
  # =============================================================

  describe "[PROPERTY] R19-R21: Invariants" do
    @tag :property
    test "property: schedule_consensus_continuation always sets flag and sends message" do
      # Test across many state variations
      states = [
        %{},
        %{consensus_scheduled: false},
        %{consensus_scheduled: true},
        %{consensus_scheduled: false, agent_id: "test", other: :field},
        %{consensus_scheduled: false, wait_timer: {make_ref(), :timed_wait}}
      ]

      for state <- states do
        flush_mailbox()

        result = StateUtils.schedule_consensus_continuation(state)

        assert result.consensus_scheduled == true,
               "Invariant violated: consensus_scheduled not true for state #{inspect(state)}"

        assert_receive :trigger_consensus,
                       100,
                       "Invariant violated: no :trigger_consensus for state #{inspect(state)}"
      end
    end

    @tag :property
    test "property: multiple schedule_consensus_continuation calls are safe" do
      state = %{consensus_scheduled: false, agent_id: "test"}

      # Call multiple times rapidly
      final_state =
        1..10
        |> Enum.reduce(state, fn _, acc ->
          StateUtils.schedule_consensus_continuation(acc)
        end)

      # Flag should still be true
      assert final_state.consensus_scheduled == true

      # Should have 10 messages (all calls send)
      for _ <- 1..10 do
        assert_receive :trigger_consensus
      end
    end

    @tag :property
    test "property: WaitFlow does not send trigger_consensus messages" do
      for wait_value <- [false, 0, true, 5, :invalid] do
        flush_mailbox()

        task_ref = make_ref()
        agent_pid = self()

        WaitFlow.handle_immediate(task_ref, wait_value, agent_pid)
        WaitFlow.handle_after_result(task_ref, wait_value, agent_pid, {:ok, %{}})

        # Should NOT receive :trigger_consensus from WaitFlow (triggers moved to Agent layer)
        # Timer notifications (:wait_timer_started) are still allowed
        refute_receive :trigger_consensus,
                       50,
                       "WaitFlow sent :trigger_consensus for wait_value: #{inspect(wait_value)}"
      end
    end
  end

  # =============================================================
  # [ACCEPTANCE] A1-A3: User-Observable Behavior
  # =============================================================

  describe "[ACCEPTANCE] A1-A3: Continuation" do
    setup %{sandbox_owner: sandbox_owner} do
      infra = create_isolated_infrastructure()
      {:ok, infra: infra, sandbox_owner: sandbox_owner}
    end

    @tag :acceptance
    test "A1: trigger with consensus_scheduled=true is processed", %{
      infra: infra,
      sandbox_owner: sandbox_owner
    } do
      # This tests the user-observable behavior:
      # When an action sets consensus_scheduled=true and sends :trigger_consensus,
      # the staleness check should PROCESS the trigger (not ignore it)

      alias Quoracle.Agent.Core

      config = %{
        agent_id: unique_id(),
        task_id: unique_id(),
        task_description: "Test task",
        registry: infra.registry,
        dynsup: infra.dynsup,
        pubsub: infra.pubsub,
        test_mode: true,
        skip_auto_consensus: true,
        sandbox_owner: sandbox_owner
      }

      {:ok, agent_pid} = DynamicSupervisor.start_child(infra.dynsup, {Core, config})

      on_exit(fn ->
        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Wait for initialization
      {:ok, initial_state} = Core.get_state(agent_pid)
      assert initial_state.consensus_scheduled == false

      # Step 1: Set the flag (without sending trigger yet)
      :sys.replace_state(agent_pid, fn state ->
        %{state | consensus_scheduled: true}
      end)

      # Verify flag was set - use :sys.get_state for immediate read
      state_with_flag = :sys.get_state(agent_pid)

      assert state_with_flag.consensus_scheduled == true,
             "Positive: consensus_scheduled should be true after action sets it"

      # Step 2: Now send the trigger and verify it gets processed (not ignored)
      send(agent_pid, :trigger_consensus)

      # Force processing by doing a GenServer.call (goes through mailbox order)
      {:ok, _} = Core.get_state(agent_pid)
      {:ok, state_after_trigger} = Core.get_state(agent_pid)

      # KEY ASSERTION: Flag should be cleared (trigger was processed, not ignored)
      assert state_after_trigger.consensus_scheduled == false,
             "Positive: consensus_scheduled should be false after trigger processed"

      # Negative assertion: state should be valid
      refute state_after_trigger.agent_id == nil, "Agent ID should not be nil"
    end

    @tag :acceptance
    test "A2: trigger without flag is ignored (staleness check)", %{
      infra: infra,
      sandbox_owner: sandbox_owner
    } do
      # This tests that the staleness check still works:
      # An orphan :trigger_consensus without consensus_scheduled=true should be ignored

      alias Quoracle.Agent.Core

      config = %{
        agent_id: unique_id(),
        task_id: unique_id(),
        task_description: "Test task",
        registry: infra.registry,
        dynsup: infra.dynsup,
        pubsub: infra.pubsub,
        test_mode: true,
        skip_auto_consensus: true,
        sandbox_owner: sandbox_owner
      }

      {:ok, agent_pid} = DynamicSupervisor.start_child(infra.dynsup, {Core, config})

      on_exit(fn ->
        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      {:ok, initial_state} = Core.get_state(agent_pid)

      # Ensure flag is false and no timer
      :sys.replace_state(agent_pid, fn state ->
        %{state | consensus_scheduled: false, wait_timer: nil}
      end)

      # Send orphan trigger directly (simulating stale message)
      send(agent_pid, :trigger_consensus)

      # Force processing
      {:ok, _} = Core.get_state(agent_pid)
      {:ok, state_after} = Core.get_state(agent_pid)

      # KEY ASSERTION: Flag should STILL be false (trigger was ignored)
      assert state_after.consensus_scheduled == false,
             "Positive: orphan trigger should be ignored, flag stays false"

      # State should be otherwise unchanged
      assert state_after.agent_id == initial_state.agent_id,
             "Negative: agent_id should not change"
    end

    @tag :acceptance
    test "A3: multiple triggers - first processed, rest ignored", %{
      infra: infra,
      sandbox_owner: sandbox_owner
    } do
      # This tests idempotency: multiple rapid triggers don't cause errors

      alias Quoracle.Agent.Core

      config = %{
        agent_id: unique_id(),
        task_id: unique_id(),
        task_description: "Test task",
        registry: infra.registry,
        dynsup: infra.dynsup,
        pubsub: infra.pubsub,
        test_mode: true,
        skip_auto_consensus: true,
        sandbox_owner: sandbox_owner
      }

      {:ok, agent_pid} = DynamicSupervisor.start_child(infra.dynsup, {Core, config})

      on_exit(fn ->
        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      {:ok, _initial_state} = Core.get_state(agent_pid)

      # Set flag and send MULTIPLE triggers (simulating rapid action completions)
      :sys.replace_state(agent_pid, fn state ->
        send(agent_pid, :trigger_consensus)
        send(agent_pid, :trigger_consensus)
        send(agent_pid, :trigger_consensus)
        %{state | consensus_scheduled: true}
      end)

      # Force processing of all triggers
      {:ok, _} = Core.get_state(agent_pid)
      {:ok, _} = Core.get_state(agent_pid)
      {:ok, state_final} = Core.get_state(agent_pid)

      # KEY ASSERTION: Flag should be false (first trigger processed)
      assert state_final.consensus_scheduled == false,
             "Positive: flag should be cleared after first trigger"

      # Negative assertion: agent should still be operational
      refute state_final.agent_id == nil, "Agent should still be operational"
    end
  end
end
