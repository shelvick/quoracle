defmodule Quoracle.Integration.MessageFlowTest do
  @moduledoc """
  Integration test to verify message flow from agent to UI.
  """
  use QuoracleWeb.ConnCase, async: true
  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]
  import Test.AgentTestHelpers
  alias Phoenix.PubSub

  describe "message flow from agent to UI" do
    test "Dashboard receives and displays messages broadcast to task topic", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      # Create isolated dependencies for this test
      pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
      registry = :"test_registry_#{System.unique_integer([:positive])}"

      start_supervised!({Phoenix.PubSub, name: pubsub})
      start_supervised!({Registry, keys: :unique, name: registry})

      # Use start_supervised to ensure ExUnit controls shutdown order
      # Agent cleanup (via on_exit) runs BEFORE DynSup shutdown, preventing orphaned processes
      {:ok, dynsup} = start_supervised({Quoracle.Agent.DynSup, []}, shutdown: :infinity)

      # Create real task in DB first with isolated dependencies
      {:ok, {task, _task_agent_pid}} =
        create_task_with_cleanup(
          "Message flow test task",
          sandbox_owner: sandbox_owner,
          dynsup: dynsup,
          registry: registry,
          pubsub: pubsub
        )

      # Start Dashboard with isolated PubSub and Registry
      {:ok, view, _html} =
        live_isolated(conn, QuoracleWeb.DashboardLive,
          session: %{
            "pubsub" => pubsub,
            "registry" => registry,
            "sandbox_owner" => sandbox_owner
          }
        )

      # Simulate agent spawning - set current_task_id
      send(
        view.pid,
        {:agent_spawned,
         %{
           agent_id: "test_agent",
           task_id: task.id,
           parent_id: nil,
           timestamp: DateTime.utc_now()
         }}
      )

      # Force synchronous processing of agent_spawned message
      render(view)

      # Broadcast a message to the task topic
      message = %{
        id: System.unique_integer([:positive]),
        from: :user,
        sender_id: "test_agent",
        content: "Test message that should appear",
        timestamp: DateTime.utc_now(),
        status: :received
      }

      PubSub.broadcast(pubsub, "tasks:#{task.id}:messages", {:agent_message, message})

      # Force synchronous processing of agent_message
      html = render(view)

      # Verify message was received and stored (LiveView state)
      state = :sys.get_state(view.pid)
      socket = state.socket
      messages = socket.assigns.messages

      assert length(messages) == 1
      assert hd(messages).content == "Test message that should appear"

      # Verify it shows in the rendered HTML
      assert html =~ "Test message that should appear"
    end
  end
end
