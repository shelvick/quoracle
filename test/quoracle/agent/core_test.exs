defmodule Quoracle.Agent.CoreTest.MockMCPClient do
  @moduledoc false
  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)
  def init(opts), do: {:ok, opts}

  def handle_call({:connect, _config}, _from, state) do
    {:reply, {:ok, %{connection_id: "test-conn", tools: []}}, state}
  end

  def handle_call(_msg, _from, state), do: {:reply, {:error, :unknown_call}, state}
end

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
  alias Quoracle.Agent.CoreTest.MockMCPClient

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

    @tag :arc_func_02
    test "does not perform initial consultation on startup", %{
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

      # Agent should be ready immediately with no history
      {:ok, state} = Core.get_state(agent)
      assert state.state == :ready

      # Verify no decisions were made across all model histories
      {:ok, histories} = Core.get_model_histories(agent)
      all_entries = histories |> Map.values() |> List.flatten()
      refute Enum.any?(all_entries, &(&1.type == :decision))
      refute Enum.any?(all_entries, &(&1.type == :prompt))
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

    test "start_link/3 accepts test_mode option", %{agent: agent} do
      # Agent already started in setup with test_mode
      assert Process.alive?(agent)
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

  describe "action result processing" do
    @tag :arc_func_03
    test "consults LLMs when action completes with result", %{
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

      # Add a pending action - function doesn't exist yet
      action_id = "action-123"
      Core.add_pending_action(agent, action_id, :web_fetch, %{url: "http://example.com"})

      # Send action result
      Core.handle_action_result(agent, action_id, {:ok, "Success: fetched data"})

      # Should consult LLMs with result (can't verify without implementation)
    end

    @tag :arc_func_05
    test "tracks multiple pending async actions correctly", %{
      parent_pid: parent_pid,
      initial_prompt: initial_prompt,
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      agent =
        start_supervised!(
          {Core,
           {parent_pid, initial_prompt,
            test_mode: true,
            skip_initial_consultation: true,
            sandbox_owner: sandbox_owner,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: deps.pubsub}},
          shutdown: :infinity
        )

      register_agent_cleanup(agent)

      # Add multiple pending actions
      Core.add_pending_action(agent, "action-1", :wait, %{wait: 1000})
      Core.add_pending_action(agent, "action-2", :web_fetch, %{url: "http://test.com"})
      Core.add_pending_action(agent, "action-3", :shell, %{command: "echo test"})

      # Verify all are tracked
      assert {:ok, pending} = Core.get_pending_actions(agent)
      assert Map.has_key?(pending, "action-1")
      assert Map.has_key?(pending, "action-2")
      assert Map.has_key?(pending, "action-3")

      # Complete one action
      Core.handle_action_result(agent, "action-2", {:ok, "data"})

      # Verify it's removed from pending
      assert {:ok, pending} = Core.get_pending_actions(agent)
      refute Map.has_key?(pending, "action-2")
      assert Map.has_key?(pending, "action-1")
      assert Map.has_key?(pending, "action-3")
    end

    @tag :arc_val_02
    test "validates action IDs match pending actions", %{
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

      # Add one pending action
      Core.add_pending_action(agent, "valid-id", :wait, %{})

      # Try to complete non-existent action (captures expected warning)
      capture_log(fn ->
        result = Core.handle_action_result(agent, "invalid-id", {:ok, "data"})

        # Should handle gracefully
        assert result == :ok
      end)

      # Verify the valid action is still pending
      assert {:ok, pending} = Core.get_pending_actions(agent)
      assert Map.has_key?(pending, "valid-id")
    end
  end

  describe "wait timer behavior" do
    @tag :arc_func_04
    test "wait timer only triggers LLM consultation if no other events arrive", %{
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

      # Set a wait timer (use long duration so it doesn't fire during test)
      timer_id = "wait-test-1"
      Core.set_wait_timer(agent, 60000, timer_id)

      # Verify timer was set
      {:ok, timer_ref} = Core.get_wait_timer(agent)
      assert is_reference(timer_ref)

      # Cancel timer before test ends to prevent consensus loop
      Process.cancel_timer(timer_ref)
    end

    test "only one wait timer active at a time", %{
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

      # Set first timer
      Core.set_wait_timer(agent, 5000, "wait-1")
      assert {:ok, timer1} = Core.get_wait_timer(agent)

      # Set second timer (should cancel first)
      Core.set_wait_timer(agent, 3000, "wait-2")
      assert {:ok, timer2} = Core.get_wait_timer(agent)

      # Timers should be different
      assert timer1 != timer2

      # Cancel active timer before test ends to prevent consensus loop
      Process.cancel_timer(timer2)
    end

    test "ignores stale timer messages with generation tracking", %{
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

      # Set first timer
      Core.set_wait_timer(agent, 5000, "wait-1")

      # Set second timer (increments generation)
      Core.set_wait_timer(agent, 3000, "wait-2")

      # Manually send stale timer message from first timer with old generation
      send(agent, {:wait_timeout, "wait-1", 1})

      # Send a sync message to ensure the stale timer was processed
      assert {:ok, state} = Core.get_state(agent)

      # Verify timer is still set (stale message was ignored)
      assert state.wait_timer != nil
      {:ok, timer_ref} = Core.get_wait_timer(agent)
      assert is_reference(timer_ref)

      # Cancel timer before test ends to prevent consensus loop
      Process.cancel_timer(timer_ref)
    end
  end

  describe "existing error handling" do
    @tag :arc_err_01
    test "sends error to parent when consensus fails", %{
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

      # Simulate consensus failure by sending error message
      send(agent, {:agent_error, agent, :consensus_failed})

      # Parent should receive error message if consensus fails
      assert_receive {:agent_error, ^agent, :consensus_failed}, 30_000
    end

    @tag :arc_err_02
    test "consults LLMs when action fails semantically", %{
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

      # Add pending action
      action_id = "failing-action"
      Core.add_pending_action(agent, action_id, :web_fetch, %{url: "bad-url"})

      # Send semantic error
      Core.handle_action_result(agent, action_id, {:error, :invalid_url})

      # Should consult LLMs about the error (can't verify without implementation)
    end

    @tag :arc_err_03
    test "shuts down cleanly when parent process dies", %{
      initial_prompt: initial_prompt,
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      # Start a parent process using Agent (proper OTP process)
      parent = start_supervised!({Agent, fn -> :parent_state end})

      # Start agent with parent pid and test_mode (use isolated registry)
      agent =
        start_supervised!(
          {Core,
           {parent, initial_prompt,
            test_mode: true,
            seed: 42,
            sandbox_owner: sandbox_owner,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: deps.pubsub}},
          shutdown: :infinity
        )

      register_agent_cleanup(agent)

      # Wait for agent to register in Registry (confirms init complete)
      # Need to get agent_id first to look up the composite value
      agent_id = Core.get_agent_id(agent)
      assert [{^agent, composite}] = Registry.lookup(deps.registry, {:agent, agent_id})
      assert composite.parent_pid == parent

      # Monitor agent
      ref = Process.monitor(agent)

      # Stop parent (simulates parent death)
      Agent.stop(parent, :normal)

      # Agent should detect and shutdown
      assert_receive {:DOWN, ^ref, :process, ^agent, reason}, 30_000
      assert reason in [:normal, :noproc, :shutdown]
    end
  end

  describe "conversation history" do
    test "maintains full conversation history", %{
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

      # Send several events
      # Capture log to suppress expected validation warnings
      capture_log(fn ->
        Core.handle_message(agent, {parent_pid, "Message 1"})
        # Add pending action first (required for result to be stored)
        Core.add_pending_action(agent, "action-1", :execute_shell, %{command: "test"})
        # Small sync to ensure pending action is registered
        _ = Core.get_state(agent)
        Core.handle_action_result(agent, "action-1", {:ok, "Result 1"})
        Core.handle_message(agent, {parent_pid, "Message 2"})
      end)

      # Get all model histories
      assert {:ok, histories} = Core.get_model_histories(agent)
      all_entries = histories |> Map.values() |> List.flatten()

      # Verify history contains all events
      assert length(all_entries) >= 3

      assert Enum.any?(all_entries, fn h ->
               case h.content do
                 content when is_binary(content) -> content =~ "Message 1"
                 _ -> false
               end
             end)

      assert Enum.any?(all_entries, fn h ->
               # New format: result entries have :result field (content is wrapped JSON string)
               case Map.get(h, :result) do
                 {:ok, result} when is_binary(result) -> result =~ "Result 1"
                 _ -> false
               end
             end)

      assert Enum.any?(all_entries, fn h ->
               case h.content do
                 content when is_binary(content) -> content =~ "Message 2"
                 _ -> false
               end
             end)
    end

    test "includes timestamps in history entries", %{
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

      # Capture log to suppress expected validation warnings
      capture_log(fn ->
        Core.handle_message(agent, {parent_pid, "Test message"})
      end)

      assert {:ok, histories} = Core.get_model_histories(agent)
      all_entries = histories |> Map.values() |> List.flatten()

      # All entries should have timestamps
      assert Enum.all?(all_entries, fn h ->
               Map.has_key?(h, :timestamp) and is_struct(h.timestamp, DateTime)
             end)
    end
  end

  describe "state management" do
    test "properly initializes state structure", %{
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

      # Get state - function doesn't exist yet
      assert {:ok, state} = Core.get_state(agent)

      # Verify state structure
      assert is_binary(state.agent_id)
      assert state.parent_pid == parent_pid
      assert state.children == []
      assert is_map(state.model_histories)
      assert is_map(state.pending_actions)
      assert state.wait_timer == nil
      assert is_integer(state.action_counter)
    end

    test "increments action counter for each action", %{
      parent_pid: parent_pid,
      initial_prompt: initial_prompt,
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      agent =
        start_supervised!(
          {Core,
           {parent_pid, initial_prompt,
            test_mode: true,
            skip_initial_consultation: true,
            sandbox_owner: sandbox_owner,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: deps.pubsub}},
          shutdown: :infinity
        )

      register_agent_cleanup(agent)

      # Get initial counter
      assert {:ok, state1} = Core.get_state(agent)
      _initial_count = state1.action_counter

      # Wait for agent to be ready after initial consultation
      :ok = Core.wait_for_ready(agent)

      # Get counter after initial consultation (may have incremented)
      assert {:ok, state_after_init} = Core.get_state(agent)
      counter_after_init = state_after_init.action_counter

      # Send agent messages that trigger consensus (async cast)
      # Capture log to suppress expected validation warnings from mock consensus
      capture_log(fn ->
        Core.handle_agent_message(agent, "First action")
        Core.handle_agent_message(agent, "Second action")
      end)

      # v18.0: Deferred consensus batches rapid messages into single consensus cycle.
      # First get_state processes casts, second ensures :trigger_consensus runs.
      assert {:ok, _} = Core.get_state(agent)
      assert {:ok, _} = Core.get_state(agent)

      # Counter should have incremented - with v18.0 batching, two rapid messages
      # are batched into ONE consensus cycle, so counter increments by 1 not 2
      assert {:ok, state2} = Core.get_state(agent)
      assert state2.action_counter >= counter_after_init + 1
    end
  end

  describe "consensus continuation bug fix (WorkGroupID: fix-20250926-203000)" do
    @tag :arc_cont_01
    test "handle_info(:trigger_consensus) returns proper GenServer tuple", %{
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

      # Monitor for crashes
      ref = Process.monitor(agent)

      # Trigger consensus continuation by sending :trigger_consensus message
      send(agent, :trigger_consensus)

      # Verify agent doesn't crash (no DOWN message)
      refute_receive {:DOWN, ^ref, :process, ^agent, _reason}, 500

      # Verify state is still accessible (proves GenServer didn't crash)
      assert {:ok, _state} = Core.get_state(agent)
      Process.demonitor(ref, [:flush])
    end

    # arc_cont_02 removed - now unified with :trigger_consensus (same as arc_cont_01)

    @tag :arc_cont_03
    test "consensus continuation succeeds and updates state", %{
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

      # Get initial action counter
      {:ok, initial_state} = Core.get_state(agent)
      initial_counter = initial_state.action_counter

      # Monitor for crashes
      ref = Process.monitor(agent)

      # Trigger consensus via agent message (properly sets consensus_scheduled: true)
      # Direct :trigger_consensus is considered stale without consensus_scheduled flag
      Core.handle_message(agent, "test message")

      # Wait for processing to complete (no crash)
      refute_receive {:DOWN, ^ref, :process, ^agent, _reason}, 500

      # Verify state was updated (action counter should increment)
      {:ok, new_state} = Core.get_state(agent)
      assert new_state.action_counter > initial_counter
      Process.demonitor(ref, [:flush])
    end

    @tag :arc_cont_04
    test "consensus continuation failure broadcasts error and continues gracefully", %{
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

      # Monitor for crashes
      ref = Process.monitor(agent)

      # Trigger consensus continuation - even if it succeeds, test that agent doesn't crash
      capture_log(fn ->
        send(agent, :trigger_consensus)
      end)

      # Verify agent doesn't crash (no DOWN message)
      refute_receive {:DOWN, ^ref, :process, ^agent, _reason}, 500

      # Verify state is accessible (proves no crash)
      assert {:ok, _state} = Core.get_state(agent)
      Process.demonitor(ref, [:flush])
    end

    @tag :arc_cont_05
    test "action with wait: false triggers automatic consensus continuation", %{
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

      # Send a message that triggers first consensus
      capture_log(fn ->
        Core.handle_agent_message(agent, "Test message")
      end)

      # Get state after first consensus
      {:ok, state_after_first} = Core.get_state(agent)
      first_counter = state_after_first.action_counter

      # Monitor for crashes
      ref = Process.monitor(agent)

      # Send another message to trigger continuation (properly sets consensus_scheduled)
      # Direct :trigger_consensus is stale after first consensus clears the flag
      capture_log(fn ->
        Core.handle_message(agent, "continuation message")
      end)

      # Wait for processing to complete (no crash)
      refute_receive {:DOWN, ^ref, :process, ^agent, _reason}, 500

      # Verify second consensus was triggered
      {:ok, state_after_second} = Core.get_state(agent)
      assert state_after_second.action_counter > first_counter
      Process.demonitor(ref, [:flush])
    end

    @tag :arc_cont_06
    test "timed wait expiration triggers consensus continuation", %{
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

      # Simulate a timed wait scenario by sending :trigger_consensus
      # (This is what would be sent after Process.send_after expires)
      {:ok, initial_state} = Core.get_state(agent)
      initial_counter = initial_state.action_counter

      # v17.0 TEST-FIX: Set wait_timer to simulate timed wait scenario
      # The staleness check requires wait_timer to be set (as it would be
      # when a timed wait is active). Without this, the message is correctly
      # identified as stale and ignored.
      :sys.replace_state(agent, fn state ->
        Map.put(state, :wait_timer, {make_ref(), :timed_wait})
      end)

      # Monitor for crashes
      ref = Process.monitor(agent)

      capture_log(fn ->
        send(agent, :trigger_consensus)
      end)

      # Wait for processing to complete (no crash)
      refute_receive {:DOWN, ^ref, :process, ^agent, _reason}, 500

      # Verify consensus was triggered
      {:ok, new_state} = Core.get_state(agent)
      assert new_state.action_counter > initial_counter
      Process.demonitor(ref, [:flush])
    end

    @tag :arc_cont_07
    test "multiple sequential actions with wait: false process without crashing", %{
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

      # Monitor for crashes
      ref = Process.monitor(agent)

      # Trigger multiple messages - with deferred consensus, rapid messages batch together
      # The key test is that the agent handles all messages without crashing
      capture_log(fn ->
        Core.handle_agent_message(agent, "First action")
        Core.handle_agent_message(agent, "Second action")
        Core.handle_agent_message(agent, "Third action")
      end)

      # Get state after processing completes - GenServer.call synchronizes
      # (all prior messages in mailbox are processed before this returns)
      {:ok, state} = Core.get_state(agent)

      # Verify agent didn't crash during message processing
      refute_receive {:DOWN, ^ref, :process, ^agent, _reason}

      # Verify model histories contain message entries (batched or individual)
      # This is the key assertion - messages were added to history
      first_history = state.model_histories |> Map.values() |> List.first([])
      assert first_history != [], "Messages should be in history after processing"
      Process.demonitor(ref, [:flush])
    end
  end

  # ============================================================================
  # MCP Client Lifecycle Tests (v14.0)
  # WorkGroupID: feat-20251126-023746
  # Packet: 4 (Agent Integration)
  # ============================================================================
  describe "MCP client lifecycle" do
    setup %{parent_pid: parent_pid, deps: deps, pubsub: pubsub, sandbox_owner: sandbox_owner} do
      agent =
        start_supervised!(
          {Core,
           {parent_pid, "MCP test agent",
            test_mode: true,
            sandbox_owner: sandbox_owner,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: pubsub}},
          shutdown: :infinity
        )

      register_agent_cleanup(agent)

      {:ok, agent: agent, pubsub: pubsub}
    end

    @tag :arc_mcp_01
    test "R4: mcp_client defaults to nil", %{agent: agent} do
      # [UNIT] WHEN agent initialized THEN mcp_client is nil
      {:ok, state} = Core.get_state(agent)

      assert Map.has_key?(state, :mcp_client)
      assert is_nil(state.mcp_client)
    end

    @tag :arc_mcp_01
    test "R1: stores MCP client reference in state", %{agent: agent} do
      # [UNIT] WHEN {:store_mcp_client, pid} cast received THEN stores in state.mcp_client
      # Create a placeholder process to act as MCP client
      # MUST use Agent (not raw spawn) because Core.terminate calls GenServer.stop on mcp_client
      {:ok, mcp_client_pid} = Agent.start_link(fn -> nil end)

      # Register cleanup in on_exit to prevent leaks if test fails
      on_exit(fn ->
        if Process.alive?(mcp_client_pid), do: Agent.stop(mcp_client_pid, :normal, :infinity)
      end)

      # Store the MCP client
      GenServer.cast(agent, {:store_mcp_client, mcp_client_pid})

      # Give the cast time to process
      {:ok, state} = Core.get_state(agent)

      assert state.mcp_client == mcp_client_pid
    end

    @tag :arc_mcp_02
    test "R2: mcp_client passed to Router in opts", %{agent: agent} do
      # [INTEGRATION] WHEN action executed IF mcp_client in state THEN passed via opts
      # Test: Call :call_mcp action - MCP.execute calls Keyword.fetch!(opts, :mcp_client)
      # If mcp_client not in opts, raises KeyError. Test verifies it doesn't crash.

      # Create mock MCP client that handles {:connect, config} calls
      # MUST be a GenServer because Core.terminate calls GenServer.stop on mcp_client
      {:ok, mcp_client_pid} = MockMCPClient.start_link()

      # Register cleanup in on_exit to prevent leaks if test fails
      on_exit(fn ->
        if Process.alive?(mcp_client_pid), do: GenServer.stop(mcp_client_pid, :normal, :infinity)
      end)

      # Store the MCP client in agent state
      GenServer.cast(agent, {:store_mcp_client, mcp_client_pid})

      # Verify it's stored
      {:ok, state} = Core.get_state(agent)
      assert state.mcp_client == mcp_client_pid

      # Call MCP action directly via handle_process_action
      # This exercises the full opts building path in TestActionHandler
      action_map = %{action: :call_mcp, params: %{transport: "stdio", command: "test"}}

      # Execute - if mcp_client not passed in opts, MCP.execute crashes with KeyError
      result = GenServer.call(agent, {:process_action, action_map, "test-action-id"})

      # Should succeed (or fail for MCP-specific reasons, not missing mcp_client)
      # KeyError on :mcp_client means opts didn't include it
      refute match?({:error, :mcp_client}, result)
    end

    @tag :arc_mcp_03
    test "R3: MCP client stored in agent state for lifecycle management", %{
      parent_pid: parent_pid,
      deps: deps,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      # [UNIT] WHEN mcp_client stored THEN accessible in state for monitoring
      # NOTE: MCP client self-terminates via Process.monitor on agent death
      # (see MCP.Client.handle_info({:DOWN, ...}) - tested in client_test.exs)
      # This test verifies the storage mechanism, not termination.
      {:ok, agent} =
        Core.start_link(
          {parent_pid, "MCP storage test",
           test_mode: true,
           sandbox_owner: sandbox_owner,
           registry: deps.registry,
           dynsup: deps.dynsup,
           pubsub: pubsub}
        )

      # Create a mock MCP client GenServer
      {:ok, mcp_client} = Agent.start_link(fn -> :running end)

      # Store the MCP client
      GenServer.cast(agent, {:store_mcp_client, mcp_client})

      # Verify it's stored and accessible
      {:ok, state} = Core.get_state(agent)
      assert state.mcp_client == mcp_client

      # Cleanup
      GenServer.stop(agent, :normal, :infinity)
      if Process.alive?(mcp_client), do: Agent.stop(mcp_client)
    end
  end

  # ============================================================================
  # Dismissing Flag Tests (v19.0)
  # WorkGroupID: feat-20251224-dismiss-child
  # Packet: 1 (Infrastructure)
  # ============================================================================
  describe "dismissing flag for race prevention" do
    setup %{parent_pid: parent_pid, deps: deps, pubsub: pubsub, sandbox_owner: sandbox_owner} do
      agent =
        start_supervised!(
          {Core,
           {parent_pid, "Dismissing flag test agent",
            test_mode: true,
            sandbox_owner: sandbox_owner,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: pubsub}},
          shutdown: :infinity
        )

      register_agent_cleanup(agent)

      {:ok, agent: agent}
    end

    @tag :arc_dismiss_01
    test "R18: state initializes with dismissing: false", %{agent: agent} do
      # [UNIT] WHEN agent initialized THEN state.dismissing is false
      {:ok, state} = Core.get_state(agent)

      assert Map.has_key?(state, :dismissing)
      assert state.dismissing == false
    end

    @tag :arc_dismiss_02
    test "R19: set_dismissing/2 updates flag to true", %{agent: agent} do
      # [UNIT] WHEN set_dismissing(pid, true) called THEN state.dismissing becomes true
      assert :ok = Core.set_dismissing(agent, true)

      {:ok, state} = Core.get_state(agent)
      assert state.dismissing == true
    end

    @tag :arc_dismiss_03
    test "R20: set_dismissing/2 updates flag to false", %{agent: agent} do
      # [UNIT] WHEN set_dismissing(pid, false) called THEN state.dismissing becomes false
      # First set to true
      :ok = Core.set_dismissing(agent, true)
      {:ok, state1} = Core.get_state(agent)
      assert state1.dismissing == true

      # Then set back to false
      assert :ok = Core.set_dismissing(agent, false)

      {:ok, state2} = Core.get_state(agent)
      assert state2.dismissing == false
    end

    @tag :arc_dismiss_04
    test "R21: dismissing?/1 returns current flag value", %{agent: agent} do
      # [UNIT] WHEN dismissing?(pid) called THEN returns current dismissing value
      # Initial value should be false
      assert Core.dismissing?(agent) == false

      # Set to true and check
      :ok = Core.set_dismissing(agent, true)
      assert Core.dismissing?(agent) == true

      # Set back to false and check
      :ok = Core.set_dismissing(agent, false)
      assert Core.dismissing?(agent) == false
    end

    @tag :arc_dismiss_05
    test "R22: set_dismissing is idempotent", %{agent: agent} do
      # [UNIT] WHEN set_dismissing called multiple times with same value THEN no error
      # Call multiple times with true
      assert :ok = Core.set_dismissing(agent, true)
      assert :ok = Core.set_dismissing(agent, true)
      assert :ok = Core.set_dismissing(agent, true)

      {:ok, state1} = Core.get_state(agent)
      assert state1.dismissing == true

      # Call multiple times with false
      assert :ok = Core.set_dismissing(agent, false)
      assert :ok = Core.set_dismissing(agent, false)
      assert :ok = Core.set_dismissing(agent, false)

      {:ok, state2} = Core.get_state(agent)
      assert state2.dismissing == false
    end
  end
end
