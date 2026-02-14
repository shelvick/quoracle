defmodule Quoracle.Integration.ReplyToConsensusTest do
  @moduledoc """
  Integration test for edge cases in mailbox reply handling.
  The happy-path reply flow is covered by MailboxReplyE2ETest.
  """
  use QuoracleWeb.ConnCase, async: true

  setup do
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    {:ok, _pubsub} = start_supervised({Phoenix.PubSub, name: pubsub_name})

    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    {:ok, _registry} = start_supervised({Registry, keys: :unique, name: registry_name})

    %{pubsub: pubsub_name, registry: registry_name}
  end

  test "reply to terminated agent does not crash", %{
    conn: conn,
    pubsub: pubsub,
    registry: registry,
    sandbox_owner: sandbox_owner
  } do
    # Create a message from a non-existent agent
    message = %{
      id: 1,
      sender_id: "non_existent_agent",
      from: :agent,
      content: "Message from terminated agent",
      timestamp: DateTime.utc_now()
    }

    # Navigate to the dashboard with isolated PubSub
    {:ok, view, _html} =
      live_isolated(conn, QuoracleWeb.DashboardLive,
        session: %{"pubsub" => pubsub, "registry" => registry, "sandbox_owner" => sandbox_owner}
      )

    # Send the agent message to Dashboard
    send(view.pid, {:agent_message, message})

    # Send a reply to the non-existent agent
    send(view.pid, {:send_reply, 1, "Reply to terminated agent"})

    # Verify the Dashboard handled it gracefully and is still alive
    assert Process.alive?(view.pid)
  end
end
