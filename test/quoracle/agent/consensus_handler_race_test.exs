# Mock Router that returns configurable results for race condition tests
defmodule Quoracle.Agent.ConsensusHandlerRaceTest.MockRouter do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def init(opts), do: {:ok, %{result: Keyword.get(opts, :result, %{status: "ok"})}}

  def handle_call(
        {:execute, _module, _params, _agent_id, _action_id, _smart_threshold, _timeout,
         _sandbox_owner, _secrets_used, _opts},
        _from,
        state
      ) do
    {:reply, {:ok, state.result}, state}
  end

  def handle_call(:get_pubsub, _from, state) do
    {:reply, :test_pubsub, state}
  end

  def handle_cast({:increment_metric, _}, state), do: {:noreply, state}
end

defmodule Quoracle.Agent.ConsensusHandlerRaceTest do
  @moduledoc """
  Tests for race condition fix in ConsensusHandler (WorkGroupID: fix-20251211-051748, Packet 2).

  v35.0: Updated for non-blocking dispatch pattern (fix-20260212-action-deadlock).
  ActionExecutor now dispatches to Task.Supervisor; results arrive via GenServer.cast.
  Tests use execute_and_collect_result helper to receive async results and process
  them through MessageHandler.handle_action_result, simulating the full GenServer flow.

  Requirements tested: R15-R24
  """

  use Quoracle.DataCase, async: true
  import ExUnit.CaptureLog
  import Quoracle.Agent.ConsensusTestHelpers, only: [execute_and_collect_result: 3]

  alias Quoracle.Agent.ConsensusHandler
  alias Quoracle.Agent.StateUtils
  alias Quoracle.Agent.ConsensusHandlerRaceTest.MockRouter

  # Valid orient params (schema requires these 4 fields)
  @valid_orient_params %{
    current_situation: "Testing race condition fix",
    goal_clarity: "Verify synchronous result storage",
    available_resources: "Unit tests",
    key_challenges: "Race between cast and message processing"
  }

  describe "R15: Result stored after dispatch + collect" do
    setup do
      {:ok, router} = MockRouter.start_link(result: %{status: "sent", sync: true})

      state = %{
        agent_id: "test-agent-#{System.unique_integer([:positive])}",
        pending_actions: %{},
        action_counter: 0,
        wait_timer: nil,
        model_histories: %{"model_1" => []},
        pubsub: :test_pubsub,
        consensus_scheduled: false,
        queued_messages: [],
        children: []
      }

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{state: state, router: router}
    end

    test "wait:false result is available after cast arrives", %{state: state} do
      action_response = %{
        action: :orient,
        params: @valid_orient_params,
        wait: false
      }

      # v35.0: Use helper to dispatch + collect async result
      result_state = execute_and_collect_result(state, action_response, self())

      # Result arrives via cast and is processed by handle_action_result
      histories = result_state.model_histories["model_1"]
      result_entry = Enum.find(histories, fn entry -> entry.type == :result end)

      assert result_entry != nil, "Result should be available after cast collected"
    end

    test "wait:0 result is available after cast arrives", %{state: state} do
      action_response = %{
        action: :orient,
        params: @valid_orient_params,
        wait: 0
      }

      result_state = execute_and_collect_result(state, action_response, self())

      histories = result_state.model_histories["model_1"]
      result_entry = Enum.find(histories, fn entry -> entry.type == :result end)

      assert result_entry != nil, "Result should be available after cast collected for wait: 0"
    end
  end

  describe "R16: Result delivered via cast" do
    setup do
      {:ok, router} = MockRouter.start_link(result: %{status: "sent", sync: true})

      state = %{
        agent_id: "test-agent-#{System.unique_integer([:positive])}",
        pending_actions: %{},
        action_counter: 0,
        wait_timer: nil,
        model_histories: %{"model_1" => []},
        pubsub: :test_pubsub,
        consensus_scheduled: false,
        queued_messages: [],
        children: []
      }

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{state: state}
    end

    test "wait:false delivers result via GenServer.cast", %{state: state} do
      action_response = %{
        action: :orient,
        params: @valid_orient_params,
        wait: false
      }

      # v35.0: Non-blocking dispatch sends result via cast
      ConsensusHandler.execute_consensus_action(
        state,
        action_response,
        self()
      )

      # v35.0: Result arrives as cast (this is the new intended behavior)
      assert_receive {:"$gen_cast", {:action_result, _, _, _}},
                     5000,
                     "wait:false should deliver result via GenServer.cast"
    end
  end

  describe "R17: Consensus triggered after result" do
    setup do
      {:ok, router} = MockRouter.start_link(result: %{status: "sent", sync: true})

      state = %{
        agent_id: "test-agent-#{System.unique_integer([:positive])}",
        pending_actions: %{},
        action_counter: 0,
        wait_timer: nil,
        model_histories: %{"model_1" => []},
        pubsub: :test_pubsub,
        consensus_scheduled: false,
        queued_messages: [],
        children: []
      }

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{state: state}
    end

    test "wait:false triggers consensus via cast result processing", %{state: state} do
      action_response = %{
        action: :orient,
        params: @valid_orient_params,
        wait: false
      }

      # v35.0: Collect result through helper (processes handle_action_result)
      result_state = execute_and_collect_result(state, action_response, self())

      # v35.0: handle_action_result sends :trigger_consensus after processing
      assert_receive :trigger_consensus
      assert result_state.consensus_scheduled
    end

    test "wait:0 also triggers consensus via cast result processing", %{state: state} do
      action_response = %{
        action: :orient,
        params: @valid_orient_params,
        wait: 0
      }

      result_state = execute_and_collect_result(state, action_response, self())

      assert_receive :trigger_consensus
      assert result_state.consensus_scheduled
    end
  end

  describe "R18: Race condition prevented" do
    setup do
      {:ok, router} = MockRouter.start_link(result: %{status: "message_sent", sync: true})

      state = %{
        agent_id: "test-agent-#{System.unique_integer([:positive])}",
        pending_actions: %{},
        action_counter: 0,
        wait_timer: nil,
        model_histories: %{"model_1" => []},
        pubsub: :test_pubsub,
        consensus_scheduled: false,
        queued_messages: [],
        children: []
      }

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{state: state}
    end

    test "immediate reply does not race with result storage", %{state: state} do
      # Simulate: Agent sends message with wait:false, recipient replies immediately
      action_response = %{
        action: :orient,
        params: @valid_orient_params,
        wait: false
      }

      # v35.0: Collect result through helper
      result_state = execute_and_collect_result(state, action_response, self())

      # After collect, the result is in history
      histories = result_state.model_histories["model_1"]
      result_count = Enum.count(histories, fn e -> e.type == :result end)

      assert result_count >= 1,
             "Result MUST be in history after cast collected (race prevention)"
    end
  end

  describe "R19: History alternation maintained" do
    setup do
      {:ok, router} =
        MockRouter.start_link(result: %{action: "orient", status: "completed", sync: true})

      state = %{
        agent_id: "test-agent-#{System.unique_integer([:positive])}",
        pending_actions: %{},
        action_counter: 0,
        wait_timer: nil,
        model_histories: %{"model_1" => []},
        pubsub: :test_pubsub,
        consensus_scheduled: false,
        queued_messages: [],
        children: []
      }

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{state: state}
    end

    test "history alternation maintained after wait:false action", %{state: state} do
      action_response = %{
        action: :orient,
        params: @valid_orient_params,
        wait: false
      }

      # v35.0: Collect result through helper
      result_state = execute_and_collect_result(state, action_response, self())

      # R19: History should have proper alternation for LLM APIs
      histories = result_state.model_histories["model_1"]
      types = Enum.map(histories, & &1.type)

      assert :decision in types, "History must contain decision"
      assert :result in types, "History must contain result"

      # With prepending: result (newer, added second) should be at lower index
      decision_idx = Enum.find_index(types, &(&1 == :decision))
      result_idx = Enum.find_index(types, &(&1 == :result))

      assert result_idx < decision_idx,
             "Result (newer) should have lower index than decision (older) in prepended history"
    end
  end

  # R20: Dead code path (defense-in-depth)
  describe "R20: Nil wait dead code path" do
    setup do
      {:ok, router} = MockRouter.start_link(result: %{status: "ok", sync: true})

      state = %{
        agent_id: "test-agent-#{System.unique_integer([:positive])}",
        pending_actions: %{},
        action_counter: 0,
        wait_timer: nil,
        model_histories: %{"model_1" => []},
        pubsub: :test_pubsub,
        consensus_scheduled: false,
        queued_messages: [],
        children: []
      }

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{state: state}
    end

    test "dead nil wait path stores result defensively", %{state: state} do
      action_response = %{
        action: :orient,
        params: @valid_orient_params,
        wait: false
      }

      # v35.0: Collect result through helper
      result_state = execute_and_collect_result(state, action_response, self())

      # R20 defense-in-depth: Result must be in state (not lost)
      histories = result_state.model_histories["model_1"]
      result_entry = Enum.find(histories, fn entry -> entry.type == :result end)

      assert result_entry != nil, "Result must be stored to prevent silent data loss"
    end
  end

  describe "Acceptance: immediate reply after wait:false" do
    setup do
      {:ok, router} = MockRouter.start_link(result: %{status: "sent", sync: true})

      state = %{
        agent_id: "test-agent-#{System.unique_integer([:positive])}",
        pending_actions: %{},
        action_counter: 0,
        wait_timer: nil,
        model_histories: %{"model_1" => []},
        pubsub: :test_pubsub,
        consensus_scheduled: false,
        queued_messages: [],
        children: []
      }

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{state: state}
    end

    test "agent handles immediate reply after wait:false send_message", %{state: state} do
      action_response = %{
        action: :orient,
        params: @valid_orient_params,
        wait: false
      }

      # v35.0: Collect result through helper
      result_state = execute_and_collect_result(state, action_response, self())

      # Simulate immediate reply arriving in mailbox
      reply_message = %{
        sender: %{agent_id: "child-agent", name: "child"},
        content: "response"
      }

      state_with_reply =
        StateUtils.add_history_entry(result_state, :message, reply_message)

      # ACCEPTANCE: History should be valid for LLM API (alternation maintained)
      histories = state_with_reply.model_histories["model_1"]
      types = Enum.map(histories, & &1.type)

      assert :decision in types, "History must have decision"
      assert :result in types, "History must have result (not lost to race)"
      assert :message in types, "History must have incoming message"
    end
  end

  # ==========================================================================
  # Bug 1 Tests: wait:true Race Condition (R21-R24)
  # ==========================================================================

  describe "R21: Synchronous result storage for wait:true" do
    setup do
      {:ok, router} =
        MockRouter.start_link(result: %{child_agent_id: "child-123", status: "spawned"})

      state = %{
        agent_id: "test-agent-#{System.unique_integer([:positive])}",
        pending_actions: %{},
        action_counter: 0,
        wait_timer: nil,
        model_histories: %{"model_1" => []},
        pubsub: :test_pubsub,
        consensus_scheduled: false,
        queued_messages: [],
        children: []
      }

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{state: state, router: router}
    end

    test "wait:true result available after cast collected", %{state: state} do
      action_response = %{
        action: :orient,
        params: @valid_orient_params,
        wait: true
      }

      # v35.0: Collect result (capture expected auto-correction warning)
      {result_state, _log} =
        with_log(fn ->
          execute_and_collect_result(state, action_response, self())
        end)

      # Result arrives via cast and is processed
      histories = result_state.model_histories["model_1"]
      result_entry = Enum.find(histories, fn entry -> entry.type == :result end)

      assert result_entry != nil,
             "wait:true result should be available after cast collected"
    end
  end

  describe "R22: Result delivered via cast for wait:true" do
    setup do
      {:ok, router} =
        MockRouter.start_link(result: %{child_agent_id: "child-123", status: "spawned"})

      state = %{
        agent_id: "test-agent-#{System.unique_integer([:positive])}",
        pending_actions: %{},
        action_counter: 0,
        wait_timer: nil,
        model_histories: %{"model_1" => []},
        pubsub: :test_pubsub,
        consensus_scheduled: false,
        queued_messages: [],
        children: []
      }

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{state: state}
    end

    test "wait:true delivers result via GenServer.cast", %{state: state} do
      action_response = %{
        action: :orient,
        params: @valid_orient_params,
        wait: true
      }

      # v35.0: Non-blocking dispatch sends result via cast
      capture_log(fn ->
        ConsensusHandler.execute_consensus_action(
          state,
          action_response,
          self()
        )
      end)

      # v35.0: Result arrives as cast (new intended behavior)
      assert_receive {:"$gen_cast", {:action_result, _, _, _}},
                     5000,
                     "wait:true should deliver result via GenServer.cast"
    end
  end

  describe "R23: Always-sync wait:true no consensus trigger" do
    setup do
      # Per-action Router (v28.0) requires real pubsub
      pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})

      state = %{
        agent_id: "test-agent-#{System.unique_integer([:positive])}",
        pending_actions: %{},
        action_counter: 0,
        wait_timer: nil,
        model_histories: %{"model_1" => []},
        pubsub: pubsub_name,
        capability_groups: [:hierarchy],
        consensus_scheduled: false,
        queued_messages: [],
        children: []
      }

      %{state: state}
    end

    test "always_sync with wait:true stores result without triggering consensus", %{state: state} do
      # send_message is always_sync but NOT self-contained (expects external reply)
      action_response = %{
        action: :send_message,
        params: %{to: "parent", content: "test message"},
        wait: true
      }

      # v35.0: Collect result through helper
      result_state = execute_and_collect_result(state, action_response, self())

      # R23: Result stored but NO :trigger_consensus sent
      # (always_sync + wait:true = result stored, no continuation)
      histories = result_state.model_histories["model_1"]
      result_entry = Enum.find(histories, fn entry -> entry.type == :result end)

      assert result_entry != nil, "Result must be stored after cast collected"

      # Should NOT trigger consensus (always_sync with wait:true)
      refute_receive :trigger_consensus,
                     100,
                     "always_sync with wait:true should NOT trigger consensus"
    end
  end

  describe "R24: Race condition prevented for wait:true" do
    setup do
      {:ok, router} =
        MockRouter.start_link(result: %{child_agent_id: "child-123", status: "spawned"})

      state = %{
        agent_id: "test-agent-#{System.unique_integer([:positive])}",
        pending_actions: %{},
        action_counter: 0,
        wait_timer: nil,
        model_histories: %{"model_1" => []},
        pubsub: :test_pubsub,
        consensus_scheduled: false,
        queued_messages: [],
        children: []
      }

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{state: state}
    end

    test "immediate child message does not race with wait:true result storage", %{state: state} do
      action_response = %{
        action: :orient,
        params: @valid_orient_params,
        wait: true
      }

      # v35.0: Collect result (capture expected auto-correction warning)
      {result_state, _log} =
        with_log(fn ->
          execute_and_collect_result(state, action_response, self())
        end)

      # After collect, result is in history
      histories = result_state.model_histories["model_1"]
      result_entry = Enum.find(histories, fn entry -> entry.type == :result end)

      assert result_entry != nil,
             "wait:true result MUST be in history after cast collected (race prevention)"
    end
  end

  describe "Bug 1 Acceptance: spawn result before immediate child reply" do
    setup do
      {:ok, router} =
        MockRouter.start_link(result: %{child_agent_id: "child-456", status: "spawned"})

      state = %{
        agent_id: "parent-agent-#{System.unique_integer([:positive])}",
        pending_actions: %{},
        action_counter: 0,
        wait_timer: nil,
        model_histories: %{"model_1" => []},
        pubsub: :test_pubsub,
        consensus_scheduled: false,
        queued_messages: [],
        children: []
      }

      on_exit(fn ->
        if Process.alive?(router) do
          try do
            GenServer.stop(router, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{state: state}
    end

    test "spawn result appears before immediate child reply in history", %{state: state} do
      action_response = %{
        action: :orient,
        params: @valid_orient_params,
        wait: true
      }

      # v35.0: Collect result (capture expected auto-correction warning)
      {result_state, _log} =
        with_log(fn ->
          execute_and_collect_result(state, action_response, self())
        end)

      # Simulate immediate child reply
      child_message = %{
        sender: %{agent_id: "child-456", name: "child"},
        content: "Hello parent, I'm ready!"
      }

      state_with_child_msg =
        StateUtils.add_history_entry(result_state, :event, child_message)

      # ACCEPTANCE: History should have spawn result BEFORE child message
      histories = state_with_child_msg.model_histories["model_1"]
      types = Enum.map(histories, & &1.type)

      assert :result in types, "History must have spawn result"
      assert :event in types, "History must have child message"

      # With prepending: result (older) should have HIGHER index than event (newer)
      result_idx = Enum.find_index(types, &(&1 == :result))
      event_idx = Enum.find_index(types, &(&1 == :event))

      assert event_idx < result_idx,
             "Spawn result (older) must appear before child message (newer) in history"
    end
  end
end
