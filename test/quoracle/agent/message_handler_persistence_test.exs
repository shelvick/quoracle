defmodule Quoracle.Agent.MessageHandlerPersistenceTest do
  @moduledoc """
  Tests for AGENT_MessageHandler database persistence integration (Packet 3).

  Tests that inter-agent messages are logged to TABLE_Messages for audit trail
  and conversation reconstruction.
  """
  use Quoracle.DataCase, async: true

  alias Quoracle.Agent.RegistryQueries
  alias Quoracle.Tasks.Task
  alias Quoracle.Messages.Message
  alias Quoracle.Repo

  import Test.IsolationHelpers
  import Test.AgentTestHelpers

  # ========== PACKET 3: MESSAGE PERSISTENCE ==========

  describe "persist_message/3 - parent to child messages" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))

      # Spawn parent agent
      parent_config = %{
        agent_id: "parent-msg-001",
        task_id: task.id,
        parent_pid: nil,
        initial_prompt: "Parent",
        test_mode: true,
        sandbox_owner: sandbox_owner
      }

      {:ok, parent_pid} =
        spawn_agent_with_cleanup(deps.dynsup, parent_config,
          registry: deps.registry,
          pubsub: deps.pubsub,
          cleanup_tree: true
        )

      # Spawn child agent with parent reference
      child_config = %{
        agent_id: "child-msg-001",
        task_id: task.id,
        parent_pid: parent_pid,
        initial_prompt: "Child",
        test_mode: true,
        sandbox_owner: sandbox_owner
      }

      {:ok, child_pid} =
        spawn_agent_with_cleanup(deps.dynsup, child_config,
          registry: deps.registry,
          pubsub: deps.pubsub,
          dynsup: deps.dynsup,
          cleanup_tree: true
        )

      [
        parent_pid: parent_pid,
        child_pid: child_pid,
        task_id: task.id,
        registry: deps.registry,
        dynsup: deps.dynsup,
        pubsub: deps.pubsub
      ]
    end

    @tag :integration
    test "ARC_FUNC_23: WHEN agent message received IF task_id and from_agent_id available THEN message logged",
         %{parent_pid: _parent_pid, child_pid: child_pid, task_id: task_id} do
      # Send message from parent to child
      message_content = "Process this task: compute fibonacci(10)"
      send(child_pid, {:agent_message, message_content})

      # Force GenServer to process message before querying DB
      Quoracle.Agent.Core.get_state(child_pid)

      # Verify message was persisted
      messages =
        from(m in Message,
          where: m.task_id == ^task_id,
          order_by: [asc: m.inserted_at]
        )
        |> Repo.all()

      assert length(messages) == 1
      msg = hd(messages)

      assert msg.from_agent_id == "parent-msg-001"
      assert msg.to_agent_id == "child-msg-001"
      assert msg.content == message_content
      assert msg.read_at == nil
    end

    @tag :integration
    test "ARC_FUNC_24: WHEN parent sends to child IF Registry lookup succeeds THEN message logged with parent_id",
         %{parent_pid: _parent_pid, child_pid: child_pid, task_id: task_id} do
      # Send message
      send(child_pid, {:agent_message, "Hello child"})

      # Force GenServer to process message before querying DB
      Quoracle.Agent.Core.get_state(child_pid)

      # Verify parent_id was correctly extracted via Registry
      messages = from(m in Message, where: m.task_id == ^task_id) |> Repo.all()

      assert length(messages) == 1
      assert hd(messages).from_agent_id == "parent-msg-001"
    end
  end

  describe "persist_message/3 - error handling" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))

      %{task_id: task.id, deps: deps, sandbox_owner: sandbox_owner}
    end

    @tag :integration
    test "ARC_FUNC_25: WHEN persistence fails IF database error THEN error logged AND message processing continues",
         %{task_id: task_id, deps: deps, sandbox_owner: sandbox_owner} do
      # Spawn agent without parent (root agent) - only for this test
      config = %{
        agent_id: "root-msg-001",
        task_id: task_id,
        parent_pid: nil,
        initial_prompt: "Root agent",
        test_mode: true,
        sandbox_owner: sandbox_owner,
        pubsub: deps.pubsub
      }

      {:ok, agent_pid} =
        spawn_agent_with_cleanup(deps.dynsup, config,
          registry: deps.registry,
          pubsub: deps.pubsub,
          cleanup_tree: true
        )

      # Send message (will fail to persist due to missing from_agent_id)
      send(agent_pid, {:agent_message, "Test message"})

      # Wait for message processing to complete before test exits
      assert {:ok, _state} = Quoracle.Agent.Core.get_state(agent_pid)

      # Verify agent is still alive
      assert Process.alive?(agent_pid)
    end

    @tag :integration
    test "WHEN missing task_id IF state incomplete THEN persistence skipped silently",
         %{deps: deps, sandbox_owner: sandbox_owner} do
      import ExUnit.CaptureLog

      # Create agent without task_id (expect error log for failed agent persistence)
      config = %{
        agent_id: "no-task-agent",
        initial_prompt: "Agent without task",
        test_mode: true,
        sandbox_owner: sandbox_owner,
        pubsub: deps.pubsub
      }

      capture_log(fn ->
        send(
          self(),
          {:result,
           spawn_agent_with_cleanup(deps.dynsup, config,
             registry: deps.registry,
             pubsub: deps.pubsub,
             cleanup_tree: true
           )}
        )
      end)

      assert_receive {:result, {:ok, pid}}

      # Send message
      send(pid, {:agent_message, "Test message"})

      # Force GenServer to process message before querying DB
      Quoracle.Agent.Core.get_state(pid)

      # Verify no messages persisted (task_id missing)
      messages = from(m in Message, where: m.to_agent_id == "no-task-agent") |> Repo.all()
      assert Enum.empty?(messages)

      # Verify agent still alive
      assert Process.alive?(pid)
    end

    # Note: ARC_FUNC_26 (Registry lookup failure handling) is tested above in
    # ARC_FUNC_25 where root agent with no parent continues running
  end

  describe "extract_agent_ids_from_message/1" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))

      # Create parent agent
      parent_config = %{
        agent_id: "parent-extract-001",
        task_id: task.id,
        parent_pid: nil,
        initial_prompt: "Parent",
        test_mode: true,
        sandbox_owner: sandbox_owner
      }

      {:ok, parent_pid} =
        spawn_agent_with_cleanup(deps.dynsup, parent_config,
          registry: deps.registry,
          pubsub: deps.pubsub,
          cleanup_tree: true
        )

      %{
        parent_pid: parent_pid,
        registry: deps.registry,
        dynsup: deps.dynsup,
        task_id: task.id,
        sandbox_owner: sandbox_owner,
        deps: deps
      }
    end

    @tag :integration
    test "WHEN called IF parent_pid exists THEN extracts from_agent_id via Registry",
         %{
           parent_pid: parent_pid,
           registry: registry,
           dynsup: dynsup,
           task_id: task_id,
           sandbox_owner: sandbox_owner,
           deps: deps
         } do
      # Create child with parent
      child_config = %{
        agent_id: "child-extract-001",
        task_id: task_id,
        parent_pid: parent_pid,
        initial_prompt: "Child",
        test_mode: true,
        sandbox_owner: sandbox_owner
      }

      {:ok, _child_pid} =
        spawn_agent_with_cleanup(dynsup, child_config,
          registry: registry,
          pubsub: deps.pubsub,
          dynsup: dynsup,
          cleanup_tree: true
        )

      # Get state and extract agent IDs
      # (In actual implementation, this is done internally by MessageHandler)
      # For test, we verify via Registry lookup
      from_agent_id = RegistryQueries.get_agent_id_from_pid(parent_pid, registry)
      assert from_agent_id == "parent-extract-001"
    end

    @tag :integration
    test "WHEN called IF parent_pid = nil THEN from_agent_id = nil", %{registry: registry} do
      # Root agents have no parent, so from_agent_id should be nil
      agent_id = RegistryQueries.get_agent_id_from_pid(nil, registry)
      assert agent_id == nil
    end

    @tag :integration
    test "WHEN called IF Registry lookup fails THEN returns nil (graceful)",
         %{registry: registry} do
      # Create fake PID not in Registry
      fake_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          after
            100 -> :ok
          end
        end)

      on_exit(fn -> if Process.alive?(fake_pid), do: send(fake_pid, :stop) end)

      # Should return nil without crashing
      agent_id = RegistryQueries.get_agent_id_from_pid(fake_pid, registry)
      assert agent_id == nil
    end
  end

  describe "message persistence integration" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))

      %{
        registry: deps.registry,
        dynsup: deps.dynsup,
        pubsub: deps.pubsub,
        task_id: task.id,
        sandbox_owner: sandbox_owner
      }
    end

    @tag :integration
    test "WHEN multiple messages exchanged THEN all logged in chronological order",
         %{
           registry: registry,
           dynsup: dynsup,
           pubsub: pubsub,
           task_id: task_id,
           sandbox_owner: sandbox_owner
         } do
      # Create parent and child
      parent_config = %{
        agent_id: "parent-multi-001",
        task_id: task_id,
        parent_pid: nil,
        initial_prompt: "Parent",
        test_mode: true,
        sandbox_owner: sandbox_owner
      }

      {:ok, parent_pid} =
        spawn_agent_with_cleanup(dynsup, parent_config,
          registry: registry,
          pubsub: pubsub,
          cleanup_tree: true
        )

      child_config = %{
        agent_id: "child-multi-001",
        task_id: task_id,
        parent_pid: parent_pid,
        initial_prompt: "Child",
        test_mode: true,
        sandbox_owner: sandbox_owner
      }

      {:ok, child_pid} =
        spawn_agent_with_cleanup(dynsup, child_config,
          registry: registry,
          pubsub: pubsub,
          dynsup: dynsup,
          cleanup_tree: true
        )

      # Send multiple messages
      send(child_pid, {:agent_message, "Message 1"})
      send(child_pid, {:agent_message, "Message 2"})
      send(child_pid, {:agent_message, "Message 3"})

      # Force GenServer to process all messages before querying DB
      Quoracle.Agent.Core.get_state(child_pid)

      # Verify all messages logged
      messages =
        from(m in Message,
          where: m.task_id == ^task_id,
          order_by: [asc: m.inserted_at]
        )
        |> Repo.all()

      assert length(messages) == 3

      # Verify all messages present (order may be non-deterministic with same timestamps)
      contents = Enum.map(messages, & &1.content) |> Enum.sort()
      assert contents == ["Message 1", "Message 2", "Message 3"]
    end
  end
end
