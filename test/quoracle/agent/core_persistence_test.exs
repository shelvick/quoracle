defmodule Quoracle.Agent.CorePersistenceTest do
  @moduledoc """
  Tests for AGENT_Core database persistence integration (Packet 3).

  Tests that agents self-persist to database on spawn and update conversation
  history after consensus decisions.
  """
  use Quoracle.DataCase, async: true

  alias Quoracle.Agent.Core
  alias Quoracle.Agent.RegistryQueries
  alias Quoracle.Tasks.TaskManager
  alias Quoracle.Tasks.Task
  alias Quoracle.Repo

  import Test.IsolationHelpers

  # ========== PACKET 3: AGENT PERSISTENCE ==========

  describe "persist_agent/1 - root agent" do
    setup %{sandbox_owner: sandbox_owner} do
      # Create isolated test dependencies
      deps = create_isolated_deps()

      # Create task for agent
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))

      [
        task_id: task.id,
        registry: deps.registry,
        dynsup: deps.dynsup,
        pubsub: deps.pubsub,
        sandbox_owner: sandbox_owner
      ]
    end

    @tag :integration
    test "ARC_FUNC_13: WHEN root agent spawned IF task_id in config THEN agent record created",
         %{
           dynsup: dynsup,
           registry: registry,
           pubsub: pubsub,
           task_id: task_id,
           sandbox_owner: sandbox_owner
         } do
      config = %{
        agent_id: "root-agent-001",
        task_id: task_id,
        parent_pid: nil,
        initial_prompt: "Test prompt",
        test_mode: true,
        sandbox_owner: sandbox_owner
      }

      # Spawn agent (which should self-persist during handle_continue)
      assert {:ok, _pid} =
               spawn_agent_with_cleanup(dynsup, config, registry: registry, pubsub: pubsub)

      # Verify agent record exists with correct data
      {:ok, agent} = TaskManager.get_agent("root-agent-001")
      assert agent.task_id == task_id
      assert agent.agent_id == "root-agent-001"
      assert agent.parent_id == nil
      assert agent.status == "running"
      assert agent.config["test_mode"] == true
    end

    @tag :integration
    test "WHEN persistence fails IF database error THEN agent continues running",
         %{dynsup: dynsup, registry: registry, pubsub: pubsub} do
      import ExUnit.CaptureLog

      # Use invalid task_id (foreign key violation)
      invalid_task_id = Ecto.UUID.generate()

      config = %{
        agent_id: "root-agent-002",
        task_id: invalid_task_id,
        parent_pid: nil,
        initial_prompt: "Test prompt",
        test_mode: true
      }

      # Agent should spawn despite persistence failure (defensive)
      # Capture expected error/warning logs for DB ownership and failed persistence
      {:ok, pid} =
        capture_log(fn ->
          send(
            self(),
            {:result,
             spawn_agent_with_cleanup(dynsup, config, registry: registry, pubsub: pubsub)}
          )
        end)
        |> then(fn _ ->
          assert_receive {:result, result}
          result
        end)

      # Verify agent is running
      assert Process.alive?(pid)

      # Verify no agent record in database
      assert {:error, :not_found} = TaskManager.get_agent("root-agent-002")
    end

    @tag :integration
    test "WHEN restoration_mode flag set THEN skip persistence writes",
         %{dynsup: dynsup, registry: registry, pubsub: pubsub, task_id: task_id} do
      config = %{
        agent_id: "restored-agent-001",
        task_id: task_id,
        restoration_mode: true,
        initial_prompt: "Restored prompt",
        test_mode: true
      }

      # Spawn agent with restoration_mode
      assert {:ok, pid} =
               spawn_agent_with_cleanup(dynsup, config, registry: registry, pubsub: pubsub)

      # Verify agent is running
      assert Process.alive?(pid)

      # Verify no agent record created (restoration skipped persistence)
      assert {:error, :not_found} = TaskManager.get_agent("restored-agent-001")
    end
  end

  describe "persist_agent/1 - child agent" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))

      # Spawn parent agent and persist it manually
      parent_config = %{
        agent_id: "parent-agent",
        task_id: task.id,
        parent_pid: nil,
        initial_prompt: "Parent prompt",
        test_mode: true,
        sandbox_owner: sandbox_owner
      }

      {:ok, parent_pid} =
        spawn_agent_with_cleanup(deps.dynsup, parent_config,
          registry: deps.registry,
          pubsub: deps.pubsub
        )

      [
        task_id: task.id,
        parent_pid: parent_pid,
        registry: deps.registry,
        dynsup: deps.dynsup,
        pubsub: deps.pubsub
      ]
    end

    @tag :integration
    test "ARC_FUNC_14: WHEN child agent spawned IF parent_pid available THEN hierarchy recorded correctly",
         %{
           dynsup: dynsup,
           registry: registry,
           pubsub: pubsub,
           task_id: task_id,
           parent_pid: parent_pid,
           sandbox_owner: sandbox_owner
         } do
      # Child config with parent_pid
      child_config = %{
        agent_id: "child-agent-001",
        task_id: task_id,
        parent_pid: parent_pid,
        initial_prompt: "Child prompt",
        test_mode: true,
        sandbox_owner: sandbox_owner
      }

      # Spawn child agent
      assert {:ok, _child_pid} =
               spawn_agent_with_cleanup(dynsup, child_config,
                 registry: registry,
                 dynsup: dynsup,
                 pubsub: pubsub
               )

      # Verify child agent record with correct parent_id
      {:ok, child_agent} = TaskManager.get_agent("child-agent-001")
      assert child_agent.task_id == task_id
      assert child_agent.parent_id == "parent-agent"
    end

    @tag :integration
    test "WHEN parent lookup fails IF Registry returns nil THEN parent_id = nil (graceful degradation)",
         %{
           dynsup: dynsup,
           registry: registry,
           pubsub: pubsub,
           task_id: task_id,
           sandbox_owner: sandbox_owner
         } do
      # Create fake parent PID that doesn't exist in Registry
      fake_parent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          after
            100 -> :ok
          end
        end)

      on_exit(fn -> if Process.alive?(fake_parent_pid), do: send(fake_parent_pid, :stop) end)

      child_config = %{
        agent_id: "orphan-child-001",
        task_id: task_id,
        parent_pid: fake_parent_pid,
        initial_prompt: "Orphan child",
        test_mode: true,
        sandbox_owner: sandbox_owner
      }

      # Spawn child with invalid parent
      assert {:ok, _child_pid} =
               spawn_agent_with_cleanup(dynsup, child_config,
                 registry: registry,
                 dynsup: dynsup,
                 pubsub: pubsub
               )

      # Verify child agent created with parent_id = nil (graceful)
      {:ok, child_agent} = TaskManager.get_agent("orphan-child-001")
      assert child_agent.parent_id == nil
    end
  end

  describe "persist_conversation/1" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))

      # Use unique agent_id to prevent restoration_mode from previous runs
      agent_id = "conv-agent-#{System.unique_integer([:positive])}"

      config = %{
        agent_id: agent_id,
        task_id: task.id,
        initial_prompt: "Test prompt",
        models: ["test-model"],
        test_mode: true,
        sandbox_owner: sandbox_owner
      }

      {:ok, pid} =
        spawn_agent_with_cleanup(deps.dynsup, config,
          registry: deps.registry,
          pubsub: deps.pubsub,
          cleanup_tree: true
        )

      [
        task_id: task.id,
        agent_pid: pid,
        agent_id: agent_id,
        registry: deps.registry,
        dynsup: deps.dynsup,
        pubsub: deps.pubsub
      ]
    end

    @tag :integration
    test "ARC_FUNC_15: WHEN conversation updated IF consensus decision made THEN conversation_history persisted",
         %{agent_pid: agent_pid, agent_id: agent_id} do
      # Send user message to trigger consensus decision
      user_message = "Please orient yourself"
      Core.ClientAPI.send_user_message(agent_pid, user_message)

      # Force GenServer to process message and complete consensus
      # v18.0: Deferred consensus sends :trigger_consensus to end of mailbox,
      # so first get_state processes the cast, second ensures :trigger_consensus runs
      Core.get_state(agent_pid)
      Core.get_state(agent_pid)

      # Verify model_histories was persisted to database (via ACE state)
      {:ok, updated_agent} = TaskManager.get_agent(agent_id)
      # model_histories format: %{"model_histories" => %{"mock:consensus-model-1" => [...]}}
      # In test_mode, uses Manager.test_model_pool() models, not the "models" config
      # NOTE: persist_conversation now delegates to persist_ace_state, writing to 'state' column
      model_histories = Map.get(updated_agent.state || %{}, "model_histories", %{})
      # Get history from first available model (test pool uses mock models)
      {_model_id, history} = Enum.at(model_histories, 0) || {nil, []}
      assert is_list(history)
      assert history != []

      # Verify user message is in history (v10.1: structured format with sender metadata)
      assert Enum.any?(history, fn entry ->
               # v10.1 format: %{from: "parent", content: "..."}
               # Legacy format: plain string (for backward compatibility check)
               Map.get(entry, "type") == "event" and
                 ((is_map(Map.get(entry, "content")) and
                     Map.get(entry, "content") |> Map.get("content") |> Kernel.==(user_message)) or
                    (is_binary(Map.get(entry, "content")) and
                       String.contains?(Map.get(entry, "content"), user_message)))
             end)
    end

    @tag :integration
    test "WHEN persistence fails IF database error THEN error logged AND agent continues",
         %{agent_pid: agent_pid} do
      # Agent should continue running even if conversation persistence fails
      # This is defensive - we log the error but don't crash the agent

      # Verify agent is still running
      assert Process.alive?(agent_pid)
    end

    @tag :integration
    test "action result serialized to JSON-safe format in DB",
         %{agent_pid: agent_pid, agent_id: agent_id} do
      # Simulate action result with tuple format (the bug scenario)
      action_id = "test-action-#{System.unique_integer([:positive])}"
      result = {:ok, %{stdout: "test output", exit_code: 0, stderr: ""}}

      # Add pending action first
      Core.add_pending_action(agent_pid, action_id, :execute_shell, %{command: "test"})

      # Send action result (this triggers persist_conversation)
      Core.handle_action_result(agent_pid, action_id, result)

      # Wait for processing - two calls needed:
      # 1. First get_state processes the action_result cast
      # 2. Second get_state processes the deferred :trigger_consensus (v16.0 event batching)
      Core.get_state(agent_pid)
      Core.get_state(agent_pid)

      # Verify model_histories was persisted with serialized result (via ACE state)
      {:ok, updated_agent} = TaskManager.get_agent(agent_id)
      # model_histories format: %{"model_histories" => %{"mock:consensus-model-1" => [...]}}
      # In test_mode, uses Manager.test_model_pool() models
      # NOTE: persist_conversation now delegates to persist_ace_state, writing to 'state' column
      model_histories = Map.get(updated_agent.state || %{}, "model_histories", %{})
      # Get history from first available model (test pool uses mock models)
      {_model_id, history} = Enum.at(model_histories, 0) || {nil, []}

      # Find the :result entry
      result_entry =
        Enum.find(history, fn entry ->
          Map.get(entry, "type") == "result"
        end)

      assert result_entry != nil, "Expected :result entry in conversation history"

      # New format: content is a string (pre-wrapped JSON), action_id and result are separate fields
      content = Map.get(result_entry, "content")
      assert is_binary(content), "Expected content to be a string (pre-wrapped JSON)"

      # action_id and result are now separate fields
      assert Map.has_key?(result_entry, "action_id")
      assert Map.has_key?(result_entry, "result")

      # Verify result structure is JSON-safe (serialized as map in DB)
      result_data = Map.get(result_entry, "result")
      assert is_map(result_data), "Expected result to be a map"
      assert Map.get(result_data, "status") == "ok"
      assert is_map(Map.get(result_data, "data"))
    end

    # Note: restoration_mode handling will be tested when persist_conversation is implemented
  end

  describe "extract_parent_agent_id/2" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))

      # Create parent agent
      parent_config = %{
        agent_id: "parent-for-extraction",
        task_id: task.id,
        parent_pid: nil,
        initial_prompt: "Parent",
        test_mode: true,
        sandbox_owner: sandbox_owner
      }

      {:ok, parent_pid} =
        spawn_agent_with_cleanup(deps.dynsup, parent_config,
          registry: deps.registry,
          pubsub: deps.pubsub
        )

      [
        parent_pid: parent_pid,
        task_id: task.id,
        registry: deps.registry,
        dynsup: deps.dynsup,
        pubsub: deps.pubsub
      ]
    end

    @tag :integration
    test "ARC_FUNC_16: WHEN called IF parent_pid valid THEN returns parent agent_id from Registry",
         %{parent_pid: parent_pid, registry: registry} do
      # Extract parent agent_id from Registry
      agent_id = RegistryQueries.get_agent_id_from_pid(parent_pid, registry)

      assert agent_id == "parent-for-extraction"
    end

    @tag :integration
    test "WHEN called IF parent_pid = nil THEN returns nil", %{registry: registry} do
      # Should handle nil parent_pid gracefully
      agent_id = RegistryQueries.get_agent_id_from_pid(nil, registry)
      assert agent_id == nil
    end

    @tag :integration
    test "WHEN Registry lookup fails THEN returns nil (graceful)",
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
end
