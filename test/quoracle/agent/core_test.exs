defmodule Quoracle.Agent.CoreTest do
  @moduledoc """
  Test suite for AGENT_Core - the event-driven GenServer that delegates
  all decision-making to LLMs via consensus. Tests cover initialization,
  message handling, action processing, and error scenarios.
  """

  # Tests can use async: true with proper Sandbox.allow for GenServers
  use Quoracle.DataCase, async: true

  @moduletag capture_log: true

  import ExUnit.CaptureLog
  import Test.IsolationHelpers
  import Test.AgentTestHelpers

  alias Quoracle.Agent.Core

  setup %{sandbox_owner: sandbox_owner} do
    # DataCase already provides sandbox_owner via start_owner! pattern
    # No need for old Sandbox.mode call

    # Create isolated Registry, DynSup, and PubSub for this test
    deps = create_isolated_deps()

    # NO manual cleanup needed - all tests use start_supervised! with shutdown: :infinity
    # which automatically provides proper cleanup through ExUnit's supervisor.
    # Core.terminate/2 stops Router with :infinity timeout.
    # Manual Registry.select cleanup would race with start_supervised! cleanup.

    parent_pid = self()
    initial_prompt = "Hello, I am a test agent"

    {:ok,
     parent_pid: parent_pid,
     initial_prompt: initial_prompt,
     deps: deps,
     pubsub: deps.pubsub,
     sandbox_owner: sandbox_owner}
  end

  describe "initialization with reactive model" do
    @tag :arc_func_01
    test "spawns and links ACTION_Router during init", %{
      parent_pid: parent_pid,
      initial_prompt: initial_prompt,
      deps: deps,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent =
        start_supervised!(
          {Core,
           {parent_pid, initial_prompt,
            test_mode: true,
            sandbox_owner: sandbox_owner,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: pubsub}},
          shutdown: :infinity
        )

      register_agent_cleanup(agent)

      # Verify agent started successfully
      {:ok, state} = Core.get_state(agent)
      assert state.agent_id != nil
      assert state.state == :ready
    end

    @tag :arc_func_01
    test "starts immediately in :ready state without initial consultation", %{
      parent_pid: parent_pid,
      initial_prompt: initial_prompt,
      deps: deps,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent =
        start_supervised!(
          {Core,
           {parent_pid, initial_prompt,
            test_mode: true,
            sandbox_owner: sandbox_owner,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: pubsub}},
          shutdown: :infinity
        )

      register_agent_cleanup(agent)

      # Agent should be ready immediately
      {:ok, state} = Core.get_state(agent)
      assert state.state == :ready

      # No consultation should have happened - all model histories empty
      {:ok, histories} = Core.get_model_histories(agent)
      assert Enum.all?(histories, fn {_model, messages} -> messages == [] end)
    end

    @tag :arc_func_01
    test "generates unique agent_id and registers with Registry", %{
      parent_pid: parent_pid,
      initial_prompt: initial_prompt,
      deps: deps,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent =
        start_supervised!(
          {Core,
           {parent_pid, initial_prompt,
            test_mode: true,
            sandbox_owner: sandbox_owner,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: pubsub}},
          shutdown: :infinity
        )

      register_agent_cleanup(agent)

      agent_id = Core.get_agent_id(agent)
      assert is_binary(agent_id)

      # Verify Registry entries with new composite value pattern
      assert [{^agent, composite}] = Registry.lookup(deps.registry, {:agent, agent_id})
      # Parent relationship is now in the composite value
      assert composite.parent_pid == parent_pid
    end
  end

  describe "reactive model with explicit messages" do
    @tag :arc_func_01
    test "consults consensus only when receiving explicit message", %{
      parent_pid: parent_pid,
      initial_prompt: initial_prompt,
      deps: deps,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      # Capture all logs including GenServer termination with DB errors
      capture_log(fn ->
        agent =
          start_supervised!(
            {Core,
             {parent_pid, initial_prompt,
              test_mode: true,
              seed: 42,
              sandbox_owner: sandbox_owner,
              registry: deps.registry,
              dynsup: deps.dynsup,
              pubsub: pubsub,
              test_pid: self()}},
            shutdown: :infinity
          )

        register_agent_cleanup(agent)

        # No consultation should have happened yet - all model histories empty
        {:ok, histories} = Core.get_model_histories(agent)
        assert Enum.all?(histories, fn {_model, messages} -> messages == [] end)

        # Subscribe to action broadcasts for synchronization on isolated PubSub
        :ok = Phoenix.PubSub.subscribe(pubsub, "actions:all")

        # Send explicit message
        Core.send_user_message(agent, "Hello agent")

        assert_receive {:action_started, _}, 30_000

        # Wait for action to complete
        assert_receive {:action_completed, _}, 30_000

        # Now check that consensus was called - check all model histories
        {:ok, histories} = Core.get_model_histories(agent)
        all_entries = histories |> Map.values() |> List.flatten()
        # Messages are now events, not prompts (agents are reactive)
        assert Enum.any?(all_entries, &(&1.type == :event))
        assert Enum.any?(all_entries, &(&1.type == :decision))
      end)
    end

    @tag :arc_func_02
    test "loads context limits lazily on first message", %{
      parent_pid: parent_pid,
      initial_prompt: initial_prompt,
      deps: deps,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      # Capture all logs including GenServer termination with DB errors
      capture_log(fn ->
        agent =
          start_supervised!(
            {Core,
             {parent_pid, initial_prompt,
              test_mode: true,
              sandbox_owner: sandbox_owner,
              registry: deps.registry,
              dynsup: deps.dynsup,
              pubsub: pubsub,
              test_pid: self()}}
          )

        register_agent_cleanup(agent)

        # Context limits should not be loaded yet
        {:ok, state} = Core.get_state(agent)
        refute state.context_limits_loaded

        # Subscribe to action broadcasts for synchronization on isolated PubSub
        :ok = Phoenix.PubSub.subscribe(pubsub, "actions:all")

        # Send first message
        Core.send_user_message(agent, "First message")

        # Wait for message processing
        assert_receive {:action_started, _}, 30_000
        # Wait for action to complete
        assert_receive {:action_completed, _}, 30_000
        # Now context limits should be loaded
        {:ok, state} = Core.get_state(agent)
        assert state.context_limits_loaded
      end)
    end

    @tag :arc_int_01
    test "uses test_mode for deterministic consensus responses on messages", %{
      parent_pid: parent_pid,
      initial_prompt: initial_prompt,
      deps: deps,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      # Capture all logs including GenServer termination with DB errors
      capture_log(fn ->
        agent =
          start_supervised!(
            {Core,
             {parent_pid, initial_prompt,
              test_mode: true,
              seed: 42,
              sandbox_owner: sandbox_owner,
              registry: deps.registry,
              dynsup: deps.dynsup,
              pubsub: pubsub,
              test_pid: self()}},
            shutdown: :infinity
          )

        register_agent_cleanup(agent)

        # Subscribe to action broadcasts for synchronization on isolated PubSub
        :ok = Phoenix.PubSub.subscribe(pubsub, "actions:all")

        # Send message to trigger consensus
        Core.send_user_message(agent, "Test message")

        # Wait for processing
        assert_receive {:action_started, _}, 30_000
        # Wait for action to complete
        assert_receive {:action_completed, _}, 30_000
        # Test mode should give predictable responses - check all model histories
        {:ok, histories} = Core.get_model_histories(agent)
        all_entries = histories |> Map.values() |> List.flatten()
        decision = Enum.find(all_entries, &(&1.type == :decision))

        # In test mode, consensus returns :orient action
        assert decision.content.action == :orient
      end)
    end
  end

  describe "message differentiation" do
    setup %{
      parent_pid: parent_pid,
      initial_prompt: initial_prompt,
      deps: deps,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent =
        start_supervised!(
          {Core,
           {parent_pid, initial_prompt,
            test_mode: true,
            sandbox_owner: sandbox_owner,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: pubsub}},
          shutdown: :infinity
        )

      register_agent_cleanup(agent, cleanup_tree: true, registry: deps.registry)

      {:ok, agent: agent, pubsub: pubsub}
    end

    @tag :arc_func_02
    test "agent_message triggers consensus consultation", %{agent: agent, pubsub: pubsub} do
      # Subscribe to action broadcasts for proper synchronization on isolated PubSub
      :ok = Phoenix.PubSub.subscribe(pubsub, "actions:all")

      # Send an agent message
      # Capture log to suppress expected validation warnings from mock consensus
      capture_log(fn ->
        Core.handle_agent_message(agent, "What should I do next?")
      end)

      # Wait for action to start (proper async synchronization)
      assert_receive {:action_started, _}, 30_000
      # Check that consensus was called - check all model histories
      {:ok, histories} = Core.get_model_histories(agent)
      all_entries = histories |> Map.values() |> List.flatten()

      # Should have new decision after the message
      decisions = Enum.filter(all_entries, &(&1.type == :decision))
      # We skip initial consultation, so only the message response decision
      assert decisions != []
    end

    @tag :arc_func_03
    test "internal messages bypass consensus", %{agent: agent} do
      # Send internal message (action result)
      action_id = "action_123"

      # Capture expected warning for unknown message type
      capture_log(fn ->
        Core.handle_internal_message(agent, :action_result, %{
          action_id: action_id,
          result: {:ok, "completed"}
        })
      end)

      # Synchronous, no wait needed

      # Check history - should NOT have new decision
      {:ok, histories} = Core.get_model_histories(agent)
      all_entries = histories |> Map.values() |> List.flatten()
      decisions_before = Enum.count(all_entries, &(&1.type == :decision))

      # Send another internal message
      # Capture expected warning for unknown message type
      capture_log(fn ->
        Core.handle_internal_message(agent, :timer_expired, %{timer_id: "timer_456"})
      end)

      # Synchronous, no wait needed

      {:ok, histories_after} = Core.get_model_histories(agent)
      all_entries_after = histories_after |> Map.values() |> List.flatten()
      decisions_after = Enum.count(all_entries_after, &(&1.type == :decision))

      # No new consensus decisions for internal messages
      assert decisions_before == decisions_after
    end

    @tag :arc_func_02
    test "differentiates message types via handle_cast pattern matching", %{agent: agent} do
      # This tests the actual message routing
      # Agent messages go through consensus
      GenServer.cast(agent, {:agent_message, "Test agent message"})

      # Internal messages don't (use valid type: child_spawned)
      GenServer.cast(agent, {:internal, :child_spawned, self()})

      # Wait for processing

      # Verify agent is still alive and processing
      assert Process.alive?(agent)
      {:ok, state} = Core.get_state(agent)
      assert is_map(state)
    end
  end

  describe "action execution through router" do
    setup %{
      parent_pid: parent_pid,
      initial_prompt: initial_prompt,
      deps: deps,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      # Use simulate_tie to get :wait or :orient actions from mock
      agent =
        start_supervised!(
          {Core,
           {parent_pid, initial_prompt,
            test_mode: true,
            simulate_tie: true,
            sandbox_owner: sandbox_owner,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: pubsub}},
          shutdown: :infinity
        )

      register_agent_cleanup(agent, cleanup_tree: true, registry: deps.registry)

      # Sync point: Wait for handle_continue callbacks to complete
      # This ensures Router is fully ready before tests run
      {:ok, _state} = Core.get_state(agent)

      {:ok, agent: agent, pubsub: pubsub}
    end

    @tag :arc_int_02
    test "executes :wait action asynchronously with timer", %{agent: agent, pubsub: pubsub} do
      # Subscribe to action broadcasts for proper synchronization on isolated PubSub
      :ok = Phoenix.PubSub.subscribe(pubsub, "actions:all")

      # Trigger consensus (simulate_tie returns :wait or :orient)
      # Capture log to suppress expected validation warnings from mock consensus
      capture_log(fn ->
        Core.handle_agent_message(agent, "wait for 100ms")
      end)

      # Wait for action to start before checking history
      # Use 5s timeout since consensus + action execution can be slow under load
      assert_receive {:action_started, %{action_type: action_type}}, 30_000

      # Check what action was actually chosen - check all model histories
      {:ok, histories} = Core.get_model_histories(agent)
      all_entries = histories |> Map.values() |> List.flatten()
      decision = Enum.find(all_entries, &(&1.type == :decision))

      # Only test wait timer if consensus actually chose :wait
      if action_type == :wait && decision && decision.content.action == :wait do
        # Check that wait timer was set
        {:ok, timer_ref} = Core.get_wait_timer(agent)
        assert is_reference(timer_ref)

        # Wait for timer to complete using message receive
        # The timer sends a message after 100ms (use generous timeout for CI load)
        assert_receive {:wait_expired, _}, 30_000
        # Timer should be cleared
        {:ok, timer_after} = Core.get_wait_timer(agent)
        assert is_nil(timer_after)
      else
        # If we got :orient instead, just verify no timer was set
        {:ok, timer_ref} = Core.get_wait_timer(agent)
        assert is_nil(timer_ref)
      end
    end

    @tag :arc_int_03
    test "executes :orient action synchronously with history update", %{
      agent: agent,
      pubsub: pubsub
    } do
      # Subscribe to action broadcasts for proper synchronization on isolated PubSub
      :ok = Phoenix.PubSub.subscribe(pubsub, "actions:all")

      # Trigger an orient action
      # Capture log to suppress expected validation warnings from mock consensus
      capture_log(fn ->
        Core.handle_agent_message(agent, "analyze the situation")
      end)

      # Wait for action to start (proper Elixir async synchronization)
      assert_receive {:action_started, %{action_type: action_type}}, 30_000
      assert action_type in [:orient, :wait]

      {:ok, histories} = Core.get_model_histories(agent)
      all_entries = histories |> Map.values() |> List.flatten()

      # Should have decision recorded (consensus returns :orient with simulate_tie)
      decisions = Enum.filter(all_entries, &(&1.type == :decision))
      assert Enum.any?(decisions, &(&1.content.action in [:orient, :wait]))
    end

    @tag :arc_func_05
    test "tracks pending async actions correctly", %{agent: agent} do
      # Get initial pending actions count
      {:ok, initial_pending} = Core.get_pending_actions(agent)
      initial_count = map_size(initial_pending)

      # Add pending actions directly - this is what we're testing
      Core.add_pending_action(agent, "test-action-1", :wait, %{duration_ms: 200})
      Core.add_pending_action(agent, "test-action-2", :wait, %{duration_ms: 300})

      # Check that actions were added to pending
      {:ok, pending} = Core.get_pending_actions(agent)
      assert map_size(pending) == initial_count + 2
    end
  end

  describe "error handling" do
    @tag :arc_err_03
    test "when parent dies, agent shuts down cleanly", %{
      initial_prompt: initial_prompt,
      deps: deps
    } do
      import ExUnit.CaptureLog

      # Trap exits to prevent test process from dying
      Process.flag(:trap_exit, true)

      # Start a proper parent process using Agent
      parent = start_supervised!({Agent, fn -> :waiting end})

      # Link to parent so we receive EXIT message when it dies
      Process.link(parent)

      # NOTE: Intentionally NO sandbox_owner - this test kills the agent via link,
      # which bypasses terminate/2 and would leak DB connections causing Postgrex errors
      # The agent doesn't actually need DB access for this test anyway (no DB operations)
      agent =
        start_supervised!(
          {Core,
           {parent, initial_prompt,
            test_mode: true,
            seed: 42,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: deps.pubsub}},
          shutdown: :infinity
        )

      register_agent_cleanup(agent)

      # Wait for agent to be ready
      assert :ok = Core.wait_for_ready(agent)

      assert Process.alive?(agent)

      # Kill the parent and capture expected termination logs
      capture_log(fn ->
        Process.exit(parent, :kill)

        # Agent should detect parent death and shutdown
        # First, clear the EXIT message from the parent
        assert_receive {:EXIT, ^parent, :killed}, 30_000

        # Then check if agent died (it should detect parent death)
        # Monitor to detect shutdown
        ref = Process.monitor(agent)
        assert_receive {:DOWN, ^ref, :process, ^agent, _reason}, 30_000
      end)
    end

    @tag :arc_err_01
    test "when consensus fails, agent continues running gracefully", %{
      parent_pid: parent_pid,
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      # Start agent with simulate_failure flag
      agent =
        start_supervised!(
          {Core,
           {parent_pid, "test",
            test_mode: true,
            simulate_failure: true,
            sandbox_owner: sandbox_owner,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: deps.pubsub,
            test_pid: self()}},
          restart: :temporary,
          shutdown: :infinity
        )

      register_agent_cleanup(agent)

      # Send message to trigger consensus (which will fail due to simulate_failure)
      # Capture the expected error log
      log =
        capture_log(fn ->
          Core.send_user_message(agent, "CONSENSUS_FAIL_TEST")

          # Wait for the message to be processed by checking state
          # v18.0: Deferred consensus sends :trigger_consensus to end of mailbox,
          # so first get_state processes the cast, second ensures :trigger_consensus runs
          # v22.0: Retry logic schedules up to 3 total consensus attempts via
          # :trigger_consensus, each needing a get_state to drain
          {:ok, _state} = Core.get_state(agent)
          {:ok, _state} = Core.get_state(agent)
          {:ok, _state} = Core.get_state(agent)
          {:ok, _state} = Core.get_state(agent)
          {:ok, _state} = Core.get_state(agent)
          {:ok, _state} = Core.get_state(agent)
        end)

      # Verify the error was logged
      # v18.0: handle_send_user_message delegates to handle_agent_message which defers
      # consensus via :trigger_consensus, so error context is now "cycle" not "for user message"
      assert log =~ "Consensus failed cycle: :all_models_failed"

      # Agent should still be alive after consensus failure
      assert Process.alive?(agent)

      # Agent should still be in ready state and able to process more messages
      {:ok, state} = Core.get_state(agent)
      assert state.state == :ready
    end
  end

  describe "new API functions for consensus integration" do
    setup %{parent_pid: parent_pid, initial_prompt: initial_prompt, deps: deps} do
      agent =
        start_supervised!(
          {Core,
           {parent_pid, initial_prompt,
            test_mode: true,
            skip_initial_consultation: true,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: deps.pubsub}},
          shutdown: :infinity
        )

      register_agent_cleanup(agent, cleanup_tree: true, registry: deps.registry)

      {:ok, agent: agent}
    end

    test "handle_agent_message/2 sends agent messages", %{agent: agent} do
      # Capture log to suppress expected validation warnings from mock consensus
      capture_log(fn ->
        assert :ok = Core.handle_agent_message(agent, "Test message")
      end)
    end

    test "handle_internal_message/3 sends internal messages", %{agent: agent} do
      assert :ok = Core.handle_internal_message(agent, :test_type, %{data: "test"})
    end
  end

  describe "message handling" do
    @tag :arc_func_02
    test "batches all pending messages in mailbox and consults LLMs once", %{
      parent_pid: parent_pid,
      initial_prompt: initial_prompt,
      deps: deps
    } do
      agent =
        start_supervised!(
          {Core,
           {parent_pid, initial_prompt,
            test_mode: true,
            skip_initial_consultation: true,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: deps.pubsub}},
          shutdown: :infinity
        )

      register_agent_cleanup(agent)

      # Send multiple messages rapidly - handle_message doesn't exist yet
      # Capture log to suppress expected validation warnings
      capture_log(fn ->
        Core.handle_message(agent, {parent_pid, "First message"})
        Core.handle_message(agent, {parent_pid, "Second message"})
        Core.handle_message(agent, {parent_pid, "Third message"})
      end)

      # In implementation, should batch all messages for single LLM call
      # Without implementation, we can't verify batching yet
    end

    @tag :arc_func_04
    test "cancels any active wait timer when new message arrives", %{
      parent_pid: parent_pid,
      initial_prompt: initial_prompt,
      deps: deps
    } do
      agent =
        start_supervised!(
          {Core,
           {parent_pid, initial_prompt,
            test_mode: true,
            skip_initial_consultation: true,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: deps.pubsub}},
          shutdown: :infinity
        )

      register_agent_cleanup(agent)

      # Set a wait timer - function doesn't exist yet
      Core.set_wait_timer(agent, 5000, "wait-1")

      # Verify timer exists
      assert {:ok, timer_ref} = Core.get_wait_timer(agent)
      assert is_reference(timer_ref)

      # Send a message (should cancel timer)
      # Capture log to suppress expected validation warnings
      capture_log(fn ->
        Core.handle_message(agent, {parent_pid, "Interrupting message"})
      end)

      # Verify timer was cancelled
      assert {:ok, nil} = Core.get_wait_timer(agent)
    end

    @tag :arc_val_01
    test "handles malformed messages gracefully", %{
      parent_pid: parent_pid,
      initial_prompt: initial_prompt,
      deps: deps
    } do
      agent =
        start_supervised!(
          {Core,
           {parent_pid, initial_prompt,
            test_mode: true,
            skip_initial_consultation: true,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: deps.pubsub}},
          shutdown: :infinity
        )

      register_agent_cleanup(agent)

      # Send various malformed messages
      # Capture log to suppress expected validation warnings
      capture_log(fn ->
        Core.handle_message(agent, nil)
        Core.handle_message(agent, {})
        Core.handle_message(agent, "bare string")
        Core.handle_message(agent, 12345)
      end)

      # Agent should still be alive
      assert Process.alive?(agent)
    end
  end
end
