defmodule Quoracle.Actions.RouterSendMessageTest.MockAgent do
  @moduledoc false
  use GenServer

  def start_link(state), do: GenServer.start_link(__MODULE__, state)

  def init(state) do
    # Register as root agent (no parent) if registry provided
    if state[:registry] do
      Registry.register(state.registry, {:agent, state.agent_id}, %{
        parent_id: nil,
        parent_pid: nil
      })
    end

    {:ok, state}
  end

  def handle_call(:get_agent_id, _from, state) do
    {:reply, state.agent_id, state}
  end

  def handle_call(:get_task_id, _from, state) do
    {:reply, state.task_id, state}
  end
end

defmodule Quoracle.Actions.RouterSendMessageTest do
  @moduledoc """
  Tests for Router integration with SendMessage action.
  Packet 2: Router Integration for ACTION_SendMessage.
  """

  use ExUnit.Case, async: true
  alias Quoracle.Actions.Router
  alias Quoracle.Actions.RouterSendMessageTest.MockAgent

  import ExUnit.CaptureLog
  import Test.AgentTestHelpers

  setup do
    # Create isolated PubSub for test isolation
    pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
    {:ok, _} = start_supervised({Phoenix.PubSub, name: pubsub})

    # Create isolated Registry for agent discovery
    registry = :"test_registry_#{System.unique_integer([:positive])}"
    {:ok, _} = start_supervised({Registry, keys: :unique, name: registry})

    agent_id = "test-agent-#{System.unique_integer([:positive])}"

    # Per-action Router (v28.0)
    {:ok, router} =
      Router.start_link(
        action_type: :send_message,
        action_id: "action-#{System.unique_integer([:positive])}",
        agent_id: agent_id,
        agent_pid: self(),
        pubsub: pubsub,
        registry: registry
      )

    on_exit(fn ->
      if Process.alive?(router) do
        try do
          GenServer.stop(router, :normal, :infinity)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    %{router: router, pubsub: pubsub, registry: registry, agent_id: agent_id}
  end

  describe "Router dispatch to SendMessage module" do
    test "routes :send_message action to SendMessage module", %{
      router: router,
      pubsub: pubsub,
      registry: registry,
      agent_id: agent_id
    } do
      # Setup mock agent process - use start_supervised! for proper cleanup
      agent_pid =
        start_supervised!(
          {MockAgent, %{agent_id: agent_id, task_id: "task-001", registry: registry}}
        )

      register_agent_cleanup(agent_pid)

      params = %{
        to: :parent,
        content: "Hello from router test"
      }

      # Execute through router with timeout to force sync execution
      result =
        Router.execute(router, :send_message, params, agent_id,
          pubsub: pubsub,
          registry: registry,
          sender_pid: agent_pid,
          timeout: 5000
        )

      assert {:ok, response} = result
      assert response[:action] == "send_message"
      # Root agent (no parent) sends to user
      assert response[:sent_to] == ["user"]
      # content no longer in result (already in action params, saves tokens)
    end

    test "passes PubSub and Registry options to SendMessage", %{
      router: router,
      pubsub: pubsub,
      registry: registry,
      agent_id: agent_id
    } do
      # Mock agent as GenServer - use start_supervised! for proper cleanup
      agent_pid =
        start_supervised!(
          {MockAgent, %{agent_id: agent_id, task_id: "task-123", registry: registry}}
        )

      register_agent_cleanup(agent_pid)

      params = %{
        to: :parent,
        content: "Testing PubSub isolation"
      }

      # Execute with explicit options and timeout for sync execution
      # The fact that this succeeds proves the options are passed correctly
      {:ok, result} =
        Router.execute(router, :send_message, params, agent_id,
          pubsub: pubsub,
          registry: registry,
          sender_pid: agent_pid,
          timeout: 5000
        )

      # Verify the action completed successfully
      assert result[:action] == "send_message"
      # Root agent (no parent) sends to user
      assert result[:sent_to] == ["user"]
    end

    test "handles missing parameters with proper error", %{router: router, agent_id: agent_id} do
      # Missing content
      params = %{to: :parent}

      result = Router.execute(router, :send_message, params, agent_id)

      assert {:error, reason} = result
      # Should fail with validation error (validation happens before module check)
      assert reason == :missing_required_param
    end

    test "broadcasts action lifecycle events for send_message", %{
      router: router,
      pubsub: pubsub,
      registry: registry,
      agent_id: agent_id
    } do
      # Subscribe to action events (broadcasts to actions:all)
      Phoenix.PubSub.subscribe(pubsub, "actions:all")

      agent_pid =
        start_supervised!(
          {MockAgent, %{agent_id: agent_id, task_id: "task-004", registry: registry}}
        )

      register_agent_cleanup(agent_pid)

      params = %{
        to: :parent,
        content: "Test message"
      }

      # Execute action with timeout for sync execution
      {:ok, _} =
        Router.execute(router, :send_message, params, agent_id,
          pubsub: pubsub,
          sender_pid: agent_pid,
          timeout: 5000
        )

      # Should receive action started event
      assert_receive {:action_started, event}, 30_000
      assert event.action_type == :send_message
      assert event.agent_id == agent_id

      # Should receive action completed event
      assert_receive {:action_completed, event}, 30_000
      assert event.agent_id == agent_id
    end

    test "handles agent list targets through router", %{
      router: router,
      registry: registry,
      agent_id: agent_id
    } do
      # Register some target agents
      test_pid = self()

      target1_pid =
        spawn(fn ->
          Registry.register(registry, {:agent, "target-001"}, nil)
          send(test_pid, {:registered, "target-001"})

          receive do
            {:agent_message, from, content} ->
              send(self(), {:got_message, from, content})
          end

          receive do
            :stop -> :ok
          end
        end)

      target2_pid =
        spawn(fn ->
          Registry.register(registry, {:agent, "target-002"}, nil)
          send(test_pid, {:registered, "target-002"})

          receive do
            {:agent_message, from, content} ->
              send(self(), {:got_message, from, content})
          end

          receive do
            :stop -> :ok
          end
        end)

      # Wait for both targets to register before proceeding
      assert_receive {:registered, "target-001"}, 30_000
      assert_receive {:registered, "target-002"}, 30_000

      on_exit(fn ->
        # These are raw spawn()ed processes, not GenServers - use send(:stop)
        if Process.alive?(target1_pid), do: send(target1_pid, :stop)
        if Process.alive?(target2_pid), do: send(target2_pid, :stop)
      end)

      # Mock sender
      sender_pid =
        start_supervised!(
          {MockAgent, %{agent_id: agent_id, task_id: "task-006"}},
          id: :sender_001
        )

      register_agent_cleanup(sender_pid)

      params = %{
        to: ["target-001", "target-002"],
        content: "Broadcast message"
      }

      # Execute through router with timeout for sync execution
      # Capture any potential logs during agent lookup
      capture_log(fn ->
        send(
          self(),
          {:result,
           Router.execute(router, :send_message, params, agent_id,
             registry: registry,
             agent_id: agent_id,
             task_id: "task-006",
             agent_pid: sender_pid,
             timeout: 5000
           )}
        )
      end)

      assert_received {:result, {:ok, result}}
      assert result[:sent_to] == ["target-001", "target-002"]
    end
  end

  describe "Router validation with send_message" do
    test "validates send_message parameters through Schema", %{router: router, agent_id: agent_id} do
      import ExUnit.CaptureLog

      # Invalid parameters (wrong type for 'to')
      params = %{
        to: "invalid_string_instead_of_atom",
        content: "Test"
      }

      # Capture expected error log from invalid target
      capture_log(fn ->
        result = Router.execute(router, :send_message, params, agent_id)
        send(self(), {:result, result})
      end)

      assert_received {:result, {:error, _reason}}
    end

    test "validates send_message params (wait is response-level, not in params)", %{
      router: router,
      agent_id: agent_id
    } do
      agent_pid =
        start_supervised!({MockAgent, %{agent_id: agent_id, task_id: "task-008"}})

      register_agent_cleanup(agent_pid)

      # Params without wait (wait is response-level flow control, not an action param)
      params = %{
        to: :parent,
        content: "Test"
      }

      result =
        Router.execute(router, :send_message, params, agent_id,
          sender_pid: agent_pid,
          timeout: 5000
        )

      assert {:ok, _} = result
    end
  end

  describe "Router error handling for send_message" do
    test "handles SendMessage module errors gracefully", %{router: router, agent_id: agent_id} do
      # Test with nil 'to' parameter which should trigger error
      params = %{
        to: nil,
        content: "Test"
      }

      capture_log(fn ->
        result = Router.execute(router, :send_message, params, agent_id)
        assert {:error, _} = result
      end)
    end

    test "returns success when send_message module is loaded", %{
      router: router,
      agent_id: agent_id
    } do
      # Now that module exists in IMPLEMENT phase, test successful execution
      agent_pid =
        start_supervised!({MockAgent, %{agent_id: agent_id, task_id: "task-010"}})

      register_agent_cleanup(agent_pid)

      params = %{to: :parent, content: "Test"}

      # Add timeout to force sync execution
      result =
        Router.execute(router, :send_message, params, agent_id,
          timeout: 5000,
          sender_pid: agent_pid
        )

      # Should now succeed since module is implemented
      assert {:ok, response} = result
      assert response[:action] == "send_message"
    end
  end

  describe "Router integration with action priorities" do
    test "send_message has correct priority in Schema", %{router: _router} do
      # The Schema already defines send_message with priority 3
      # This test verifies it's accessible through the Router's validation
      assert Quoracle.Actions.Schema.get_action_priority(:send_message) == 3
    end
  end
end
