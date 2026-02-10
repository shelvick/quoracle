defmodule Quoracle.UI.EventHistoryTest do
  @moduledoc """
  Integration tests for the EventHistory GenServer.
  Tests PubSub subscription, buffering, and query API with isolated dependencies.
  """

  use ExUnit.Case, async: true

  alias Quoracle.UI.EventHistory
  alias Phoenix.PubSub

  # Helper to wait for a condition (replaces timing assumptions with event-based sync)
  defp wait_until(condition_fn, timeout_ms, interval_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    do_wait_until(condition_fn, deadline, interval_ms)
  end

  defp do_wait_until(condition_fn, deadline, interval_ms) do
    if condition_fn.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        :timeout
      else
        # credo:disable-for-next-line Credo.Check.Concurrency.NoProcessSleep
        Process.sleep(interval_ms)
        do_wait_until(condition_fn, deadline, interval_ms)
      end
    end
  end

  # Test fixtures
  defp sample_log(agent_id, id \\ 1) do
    %{
      id: id,
      agent_id: agent_id,
      level: :info,
      message: "Test log #{id}",
      metadata: %{},
      timestamp: DateTime.utc_now()
    }
  end

  defp sample_message(task_id, id) do
    %{
      id: id,
      task_id: task_id,
      from: :agent,
      sender_id: "agent-001",
      content: "Test message #{id}",
      timestamp: DateTime.utc_now(),
      status: :received
    }
  end

  describe "startup" do
    # R1: Startup with PubSub
    test "starts successfully with pubsub option" do
      pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})

      {:ok, pid} = EventHistory.start_link(pubsub: pubsub_name)

      assert Process.alive?(pid)

      GenServer.stop(pid, :normal, :infinity)
    end

    # R2: Startup without PubSub
    test "raises when pubsub not provided" do
      assert_raise KeyError, fn ->
        EventHistory.start_link([])
      end
    end
  end

  describe "subscriptions" do
    setup do
      pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})

      {:ok, pid} = start_supervised({EventHistory, pubsub: pubsub_name})

      # Wait for handle_continue to complete (subscribes to agents:lifecycle)
      _ = :sys.get_state(pid)

      on_exit(fn ->
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{pubsub: pubsub_name, event_history: pid}
    end

    # R3: Lifecycle Subscription
    test "subscribes to agents:lifecycle on startup", %{pubsub: pubsub, event_history: pid} do
      # Force state sync to ensure subscription is complete
      _ = :sys.get_state(pid)

      # Broadcast on lifecycle topic should be received by EventHistory
      # We verify by checking the process can handle the message without crashing
      PubSub.broadcast(
        pubsub,
        "agents:lifecycle",
        {:agent_spawned,
         %{
           agent_id: "agent-test",
           task_id: 1
         }}
      )

      # Force state sync again to process the message
      state = :sys.get_state(pid)

      # EventHistory should have processed the spawn without crashing
      assert Process.alive?(pid)
      # The state should track subscribed agents
      assert is_struct(state)
    end

    # R4: Existing Agent Discovery
    test "subscribes to existing agent topics on startup", %{pubsub: pubsub} do
      # Create a registry with existing agents
      registry_name = :"test_registry_#{System.unique_integer([:positive])}"
      start_supervised!({Registry, keys: :unique, name: registry_name})

      # Register an "existing" agent before starting EventHistory
      Registry.register(registry_name, {:agent, "existing-agent"}, %{task_id: 1})

      # Start new EventHistory with registry
      {:ok, pid} = EventHistory.start_link(pubsub: pubsub, registry: registry_name)

      # Force state sync
      _ = :sys.get_state(pid)

      # Broadcast a log to the existing agent's topic
      PubSub.broadcast(
        pubsub,
        "agents:existing-agent:logs",
        {:log_entry, sample_log("existing-agent")}
      )

      # Force state sync
      _ = :sys.get_state(pid)

      # The log should be buffered
      logs = EventHistory.get_logs(pid, ["existing-agent"])
      assert length(logs["existing-agent"]) == 1

      GenServer.stop(pid, :normal, :infinity)
    end

    # R5: New Agent Subscription
    test "subscribes to new agent log topic on spawn", %{pubsub: pubsub, event_history: pid} do
      # Spawn an agent via lifecycle event
      PubSub.broadcast(
        pubsub,
        "agents:lifecycle",
        {:agent_spawned,
         %{
           agent_id: "new-agent",
           task_id: 1
         }}
      )

      # Force state sync - ensure agent_spawned is processed and subscription is active
      # Double-sync to handle high parallel load (PubSub delivery can be delayed)
      _ = :sys.get_state(pid)
      _ = :sys.get_state(pid)

      # Now broadcast a log to that agent's topic
      PubSub.broadcast(pubsub, "agents:new-agent:logs", {:log_entry, sample_log("new-agent")})

      # Force state sync - ensure log_entry is processed
      # Triple-sync to handle high parallel load
      _ = :sys.get_state(pid)
      _ = :sys.get_state(pid)
      _ = :sys.get_state(pid)

      # The log should be buffered
      logs = EventHistory.get_logs(pid, ["new-agent"])
      assert length(logs["new-agent"]) == 1
    end
  end

  describe "log buffering" do
    setup do
      pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})

      {:ok, pid} = start_supervised({EventHistory, pubsub: pubsub_name})

      # Wait for handle_continue to complete (subscribes to agents:lifecycle)
      _ = :sys.get_state(pid)

      on_exit(fn ->
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{pubsub: pubsub_name, event_history: pid}
    end

    # R6: Log Buffering
    test "buffers log entries per agent", %{pubsub: pubsub, event_history: pid} do
      # Spawn agent first
      PubSub.broadcast(
        pubsub,
        "agents:lifecycle",
        {:agent_spawned,
         %{
           agent_id: "agent-001",
           task_id: 1
         }}
      )

      _ = :sys.get_state(pid)

      # Send multiple logs
      PubSub.broadcast(pubsub, "agents:agent-001:logs", {:log_entry, sample_log("agent-001", 1)})
      PubSub.broadcast(pubsub, "agents:agent-001:logs", {:log_entry, sample_log("agent-001", 2)})
      PubSub.broadcast(pubsub, "agents:agent-001:logs", {:log_entry, sample_log("agent-001", 3)})
      _ = :sys.get_state(pid)

      logs = EventHistory.get_logs(pid, ["agent-001"])
      assert length(logs["agent-001"]) == 3
    end

    # R7: Log Buffer Limit
    test "evicts oldest logs when buffer full", %{pubsub: _pubsub} do
      pubsub_name = :"test_pubsub_small_#{System.unique_integer([:positive, :monotonic])}"
      {:ok, pubsub_pid} = Phoenix.PubSub.Supervisor.start_link(name: pubsub_name)

      # Start with small buffer size
      {:ok, pid} =
        EventHistory.start_link(
          pubsub: pubsub_name,
          log_buffer_size: 3
        )

      # Wait for handle_continue to complete (subscribes to agents:lifecycle)
      _ = EventHistory.get_logs(pid, [])

      on_exit(fn ->
        try do
          if Process.alive?(pid), do: GenServer.stop(pid, :normal, :infinity)
        catch
          :exit, _ -> :ok
        end

        try do
          if Process.alive?(pubsub_pid), do: Supervisor.stop(pubsub_pid)
        catch
          :exit, _ -> :ok
        end
      end)

      # Spawn agent
      PubSub.broadcast(
        pubsub_name,
        "agents:lifecycle",
        {:agent_spawned,
         %{
           agent_id: "agent-overflow",
           task_id: 1
         }}
      )

      # Use GenServer.call for sync (not :sys.get_state which uses system messages)
      _ = EventHistory.get_logs(pid, [])

      # Send 5 logs to buffer of size 3
      for i <- 1..5 do
        PubSub.broadcast(
          pubsub_name,
          "agents:agent-overflow:logs",
          {:log_entry, sample_log("agent-overflow", i)}
        )
      end

      # Use GenServer.call for sync (not :sys.get_state which uses system messages)
      _ = EventHistory.get_logs(pid, [])

      logs = EventHistory.get_logs(pid, ["agent-overflow"])
      log_ids = Enum.map(logs["agent-overflow"], & &1.id)

      # Should have only last 3 logs (ids 3, 4, 5)
      assert length(log_ids) == 3
      assert log_ids == [3, 4, 5]

      GenServer.stop(pid, :normal, :infinity)
    end
  end

  describe "message buffering" do
    setup do
      pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})

      {:ok, pid} = start_supervised({EventHistory, pubsub: pubsub_name})

      # Wait for handle_continue to complete (subscribes to agents:lifecycle)
      _ = :sys.get_state(pid)

      on_exit(fn ->
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{pubsub: pubsub_name, event_history: pid}
    end

    # R8: Message Buffering
    test "buffers messages per task", %{pubsub: pubsub, event_history: pid} do
      task_id = 42

      # Spawn agent to set up task subscription
      PubSub.broadcast(
        pubsub,
        "agents:lifecycle",
        {:agent_spawned,
         %{
           agent_id: "agent-msg",
           task_id: task_id
         }}
      )

      _ = :sys.get_state(pid)

      # Send messages
      PubSub.broadcast(
        pubsub,
        "tasks:#{task_id}:messages",
        {:agent_message, sample_message(task_id, 1)}
      )

      PubSub.broadcast(
        pubsub,
        "tasks:#{task_id}:messages",
        {:agent_message, sample_message(task_id, 2)}
      )

      _ = :sys.get_state(pid)

      messages = EventHistory.get_messages(pid, [task_id])
      assert length(messages) == 2
    end

    # R9: Message Buffer Limit
    test "evicts oldest messages when buffer full", %{pubsub: _pubsub} do
      pubsub_name = :"test_pubsub_msg_#{System.unique_integer([:positive, :monotonic])}"
      {:ok, pubsub_pid} = Phoenix.PubSub.Supervisor.start_link(name: pubsub_name)

      # Start with small buffer size
      {:ok, pid} =
        EventHistory.start_link(
          pubsub: pubsub_name,
          message_buffer_size: 3
        )

      on_exit(fn ->
        try do
          if Process.alive?(pid), do: GenServer.stop(pid, :normal, :infinity)
        catch
          :exit, _ -> :ok
        end

        try do
          if Process.alive?(pubsub_pid), do: Supervisor.stop(pubsub_pid)
        catch
          :exit, _ -> :ok
        end
      end)

      # Sync: ensure handle_continue(:setup) completes before broadcasting
      # (PubSub subscription happens in handle_continue, race condition without this)
      _ = :sys.get_state(pid)

      task_id = 99

      # Spawn agent
      PubSub.broadcast(
        pubsub_name,
        "agents:lifecycle",
        {:agent_spawned,
         %{
           agent_id: "agent-msg-overflow",
           task_id: task_id
         }}
      )

      # Wait for PubSub broadcast to be processed (PubSub goes through dispatcher,
      # so GenServer.call doesn't guarantee ordering)
      # Timeout is not under test - use large value for synchronization only
      :ok =
        wait_until(
          fn ->
            state = :sys.get_state(pid)
            MapSet.member?(state.subscribed_tasks, task_id)
          end,
          30_000,
          10
        )

      # Verify subscription is now active
      state = :sys.get_state(pid)
      assert MapSet.member?(state.subscribed_tasks, task_id), "Task should be subscribed"

      # Send 5 messages to buffer of size 3
      for i <- 1..5 do
        PubSub.broadcast(
          pubsub_name,
          "tasks:#{task_id}:messages",
          {:agent_message, sample_message(task_id, i)}
        )
      end

      _ = :sys.get_state(pid)

      messages = EventHistory.get_messages(pid, [task_id])
      message_ids = Enum.map(messages, & &1.id)

      # Should have only last 3 messages (ids 3, 4, 5)
      assert length(message_ids) == 3
      assert message_ids == [3, 4, 5]

      GenServer.stop(pid, :normal, :infinity)
    end
  end

  describe "query API" do
    setup do
      pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})

      {:ok, pid} = start_supervised({EventHistory, pubsub: pubsub_name})

      # Wait for handle_continue to complete (subscribes to agents:lifecycle)
      _ = :sys.get_state(pid)

      on_exit(fn ->
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{pubsub: pubsub_name, event_history: pid}
    end

    # R10: Get Logs Query
    test "get_logs returns logs in chronological order", %{pubsub: pubsub, event_history: pid} do
      # Spawn agent
      PubSub.broadcast(
        pubsub,
        "agents:lifecycle",
        {:agent_spawned,
         %{
           agent_id: "agent-chrono",
           task_id: 1
         }}
      )

      _ = :sys.get_state(pid)

      # Send logs in order
      PubSub.broadcast(
        pubsub,
        "agents:agent-chrono:logs",
        {:log_entry, sample_log("agent-chrono", 1)}
      )

      PubSub.broadcast(
        pubsub,
        "agents:agent-chrono:logs",
        {:log_entry, sample_log("agent-chrono", 2)}
      )

      PubSub.broadcast(
        pubsub,
        "agents:agent-chrono:logs",
        {:log_entry, sample_log("agent-chrono", 3)}
      )

      _ = :sys.get_state(pid)

      logs = EventHistory.get_logs(pid, ["agent-chrono"])
      log_ids = Enum.map(logs["agent-chrono"], & &1.id)

      # Oldest first (chronological)
      assert log_ids == [1, 2, 3]
    end

    # R11: Get Logs Missing Agent
    test "get_logs returns empty list for unknown agent", %{event_history: pid} do
      logs = EventHistory.get_logs(pid, ["nonexistent-agent"])

      assert logs["nonexistent-agent"] == []
    end

    # R12: Get Messages Query
    test "get_messages returns messages in chronological order", %{
      pubsub: pubsub,
      event_history: pid
    } do
      task_id = 123

      # Spawn agent
      PubSub.broadcast(
        pubsub,
        "agents:lifecycle",
        {:agent_spawned,
         %{
           agent_id: "agent-msg-chrono",
           task_id: task_id
         }}
      )

      _ = :sys.get_state(pid)

      # Send messages in order
      PubSub.broadcast(
        pubsub,
        "tasks:#{task_id}:messages",
        {:agent_message, sample_message(task_id, 1)}
      )

      PubSub.broadcast(
        pubsub,
        "tasks:#{task_id}:messages",
        {:agent_message, sample_message(task_id, 2)}
      )

      PubSub.broadcast(
        pubsub,
        "tasks:#{task_id}:messages",
        {:agent_message, sample_message(task_id, 3)}
      )

      _ = :sys.get_state(pid)

      messages = EventHistory.get_messages(pid, [task_id])
      message_ids = Enum.map(messages, & &1.id)

      # Oldest first (chronological)
      assert message_ids == [1, 2, 3]
    end
  end

  describe "edge cases" do
    setup do
      pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})

      {:ok, pid} = start_supervised({EventHistory, pubsub: pubsub_name})

      # Wait for handle_continue to complete (subscribes to agents:lifecycle)
      _ = :sys.get_state(pid)

      on_exit(fn ->
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{pubsub: pubsub_name, event_history: pid}
    end

    # R13: Buffer Persistence After Termination
    test "agent buffer retained after termination", %{pubsub: pubsub, event_history: pid} do
      # Spawn agent
      PubSub.broadcast(
        pubsub,
        "agents:lifecycle",
        {:agent_spawned,
         %{
           agent_id: "agent-term",
           task_id: 1
         }}
      )

      _ = :sys.get_state(pid)

      # Add logs
      PubSub.broadcast(
        pubsub,
        "agents:agent-term:logs",
        {:log_entry, sample_log("agent-term", 1)}
      )

      PubSub.broadcast(
        pubsub,
        "agents:agent-term:logs",
        {:log_entry, sample_log("agent-term", 2)}
      )

      _ = :sys.get_state(pid)

      # Terminate agent
      PubSub.broadcast(
        pubsub,
        "agents:lifecycle",
        {:agent_terminated,
         %{
           agent_id: "agent-term",
           task_id: 1,
           reason: :normal
         }}
      )

      _ = :sys.get_state(pid)

      # Logs should still be available
      logs = EventHistory.get_logs(pid, ["agent-term"])
      assert length(logs["agent-term"]) == 2
    end

    # R14: Sandbox Setup
    test "sets up sandbox access when sandbox_owner provided" do
      pubsub_name = :"test_pubsub_sandbox_#{System.unique_integer([:positive, :monotonic])}"
      {:ok, pubsub_pid} = Phoenix.PubSub.Supervisor.start_link(name: pubsub_name)

      # Start with sandbox_owner
      {:ok, pid} =
        EventHistory.start_link(
          pubsub: pubsub_name,
          sandbox_owner: self()
        )

      on_exit(fn ->
        try do
          if Process.alive?(pid), do: GenServer.stop(pid, :normal, :infinity)
        catch
          :exit, _ -> :ok
        end

        try do
          if Process.alive?(pubsub_pid), do: Supervisor.stop(pubsub_pid)
        catch
          :exit, _ -> :ok
        end
      end)

      # Force state sync to trigger handle_continue
      _ = :sys.get_state(pid)

      # GenServer should start without crashing
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal, :infinity)
    end

    # R15: PID Discovery
    test "get_pid returns running GenServer PID" do
      # Production supervisor starts EventHistory with name Quoracle.UI.EventHistory
      # get_pid/0 looks up that global name
      result = EventHistory.get_pid()

      assert is_pid(result)
      assert Process.alive?(result)
    end

    # R16: Configurable Buffer Sizes
    test "uses custom buffer sizes from options" do
      pubsub_name = :"test_pubsub_config_#{System.unique_integer([:positive, :monotonic])}"
      {:ok, pubsub_pid} = Phoenix.PubSub.Supervisor.start_link(name: pubsub_name)

      # Start with custom buffer sizes
      {:ok, pid} =
        EventHistory.start_link(
          pubsub: pubsub_name,
          log_buffer_size: 5,
          message_buffer_size: 3
        )

      on_exit(fn ->
        try do
          if Process.alive?(pid), do: GenServer.stop(pid, :normal, :infinity)
        catch
          :exit, _ -> :ok
        end

        try do
          if Process.alive?(pubsub_pid), do: Supervisor.stop(pubsub_pid)
        catch
          :exit, _ -> :ok
        end
      end)

      # SYNC: Ensure handle_continue has completed (subscribes to agents:lifecycle)
      # start_link returns after init/1, but handle_continue runs async after that.
      # A GenServer.call blocks until handle_continue finishes.
      _ = EventHistory.get_logs(pid, [])

      # Spawn agent
      PubSub.broadcast(
        pubsub_name,
        "agents:lifecycle",
        {:agent_spawned,
         %{
           agent_id: "agent-config",
           task_id: 1
         }}
      )

      # SYNC: GenServer.call ensures spawn message is processed before we send logs
      # :sys.get_state is insufficient because PubSub delivery is async - the spawn
      # message might not have arrived at EventHistory's mailbox yet.
      # get_logs/2 is a GenServer.call that processes all pending messages first.
      _ = EventHistory.get_logs(pid, ["agent-config"])

      # Send 7 logs to buffer of size 5
      for i <- 1..7 do
        PubSub.broadcast(
          pubsub_name,
          "agents:agent-config:logs",
          {:log_entry, sample_log("agent-config", i)}
        )
      end

      _ = :sys.get_state(pid)

      logs = EventHistory.get_logs(pid, ["agent-config"])

      # Should have only 5 logs due to custom size
      assert length(logs["agent-config"]) == 5

      GenServer.stop(pid, :normal, :infinity)
    end
  end
end
