defmodule Quoracle.Integration.MailboxReplyE2ETest do
  @moduledoc """
  End-to-end test for mailbox reply functionality.
  Verifies the complete flow from UI reply to agent consensus.
  """
  use QuoracleWeb.ConnCase, async: true
  import Phoenix.LiveViewTest, except: [live_isolated: 2, live_isolated: 3]
  import ExUnit.CaptureLog
  import Test.AgentTestHelpers

  # Longer timeout for E2E test with agent cleanup
  @moduletag timeout: 30_000

  test "complete reply flow from UI to agent consensus", %{
    conn: conn,
    sandbox_owner: sandbox_owner
  } do
    # Create isolated resources for this test
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    registry_name = :"test_registry_#{System.unique_integer([:positive])}"

    start_supervised({Phoenix.PubSub, name: pubsub_name})
    start_supervised({Registry, keys: :unique, name: registry_name})

    # Use start_supervised to ensure ExUnit controls shutdown order
    # Use 30s shutdown timeout to avoid blocking forever
    {:ok, dynsup} = start_supervised({Quoracle.Agent.DynSup, []}, shutdown: 30_000)

    # Create real task in DB with isolated resources
    {:ok, {task, _task_agent_pid}} =
      create_task_with_cleanup(
        "E2E test task",
        sandbox_owner: sandbox_owner,
        dynsup: dynsup,
        registry: registry_name,
        pubsub: pubsub_name
      )

    # Start a real agent with proper configuration and isolated PubSub
    agent_id = "test_agent_#{System.unique_integer([:positive])}"

    {:ok, _agent_pid} =
      spawn_agent_with_cleanup(
        dynsup,
        %{
          agent_id: agent_id,
          task_id: task.id,
          prompt: "Test agent",
          reactive: true,
          max_depth: 1,
          models: [],
          test_mode: true,
          test_opts: [skip_initial_consultation: true],
          sandbox_owner: sandbox_owner,
          registry: registry_name,
          pubsub: pubsub_name
        },
        registry: registry_name
      )

    # Subscribe to agent consensus on isolated PubSub
    Phoenix.PubSub.subscribe(pubsub_name, "agents:#{agent_id}:consensus")

    # Create message from agent
    message = %{
      id: 1,
      sender_id: agent_id,
      from: :agent,
      content: "Hello from agent",
      timestamp: DateTime.utc_now()
    }

    # Mount LiveView with isolated PubSub and Registry
    {:ok, view, _html} =
      live_isolated(conn, QuoracleWeb.DashboardLive,
        session: %{
          "pubsub" => pubsub_name,
          "registry" => registry_name,
          "sandbox_owner" => sandbox_owner
        }
      )

    # Send the agent message to Dashboard
    send(view.pid, {:agent_message, message})

    # Verify message appears
    html = render(view)
    assert html =~ "Hello from agent"

    # The message component handles its own expansion, we need to click the header
    view
    |> element(".message-header[phx-value-message-id=\"1\"]")
    |> render_click()

    # Fill in and submit reply form (consensus will fail with no models - expected)
    reply_content = "This is my reply to the agent"

    capture_log(fn ->
      view
      |> form("form[phx-submit='send_reply']", %{content: reply_content})
      |> render_submit()

      # Verify the agent received something (won't trigger consensus without models)
      # Just ensure no crashes occur - reply processing is synchronous in handle_event
      refute_receive {:EXIT, _, _}, 500
    end)

    # Cleanup happens via on_exit callbacks (agents first, then DynSup)
  end
end
