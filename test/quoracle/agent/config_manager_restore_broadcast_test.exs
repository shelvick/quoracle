defmodule Quoracle.Agent.ConfigManagerRestoreBroadcastTest do
  @moduledoc """
  Tests for ConfigManager broadcast behavior during agent restoration.

  Packet 2: AGENT_ConfigManager v4.0 - R8-R11, A1
  WorkGroupID: fix-persistence-20251218-185708

  Bug: Restored child agents are NOT visible in UI because ConfigManager
  skips broadcast when parent_id is present. During restoration, children
  are spawned directly via DynSup.restore_agent, not through Spawn action.

  Fix: Also broadcast when restoration_mode is true.
  """
  use Quoracle.DataCase, async: true

  import Test.IsolationHelpers
  import Test.AgentTestHelpers

  alias Quoracle.Tasks.Task
  alias Quoracle.Agents.Agent, as: AgentSchema
  alias Quoracle.Repo

  # ========== BROADCAST BEHAVIOR (R8-R11) ==========

  describe "setup_agent/2 - broadcast behavior" do
    setup %{sandbox_owner: sandbox_owner} do
      deps = create_isolated_deps()

      # Subscribe to agent lifecycle events (correct topic from AgentEvents)
      Phoenix.PubSub.subscribe(deps.pubsub, "agents:lifecycle")

      [
        deps: deps,
        sandbox_owner: sandbox_owner
      ]
    end

    @tag :integration
    test "R8: root agent broadcasts spawn event", %{deps: deps, sandbox_owner: sandbox_owner} do
      agent_id = "root-broadcast-agent-#{System.unique_integer([:positive])}"
      task_id = Ecto.UUID.generate()

      config = %{
        agent_id: agent_id,
        task_id: task_id,
        parent_pid: nil,
        parent_id: nil,
        test_mode: true,
        sandbox_owner: sandbox_owner,
        pubsub: deps.pubsub,
        registry: deps.registry,
        dynsup: deps.dynsup
      }

      # Spawn root agent via ConfigManager
      {:ok, _pid} =
        spawn_agent_with_cleanup(deps.dynsup, config,
          registry: deps.registry,
          pubsub: deps.pubsub
        )

      # Verify broadcast was received (correct format from AgentEvents)
      assert_receive {:agent_spawned, payload}, 30_000
      assert payload.agent_id == agent_id
      assert payload.task_id == task_id
      assert payload.parent_id == nil
    end

    @tag :integration
    test "R9: normal child spawn skips ConfigManager broadcast", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      child_agent_id = "child-normal-agent-#{System.unique_integer([:positive])}"

      # Config simulating a normal Spawn action (parent_id present, no restoration_mode)
      config = %{
        agent_id: child_agent_id,
        task_id: Ecto.UUID.generate(),
        parent_pid: self(),
        parent_id: "parent-agent-id",
        restoration_mode: false,
        test_mode: true,
        sandbox_owner: sandbox_owner,
        pubsub: deps.pubsub,
        registry: deps.registry,
        dynsup: deps.dynsup
      }

      # Spawn child agent
      {:ok, _pid} =
        spawn_agent_with_cleanup(deps.dynsup, config,
          registry: deps.registry,
          pubsub: deps.pubsub
        )

      # Verify NO broadcast from ConfigManager (Spawn action would broadcast separately)
      refute_receive {:agent_spawned, %{agent_id: ^child_agent_id}}, 200
    end

    @tag :integration
    test "R10: restored child agent broadcasts spawn event", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      restored_child_id = "restored-child-agent-#{System.unique_integer([:positive])}"
      task_id = Ecto.UUID.generate()

      # Config simulating restoration (parent_id present, restoration_mode true)
      config = %{
        agent_id: restored_child_id,
        task_id: task_id,
        parent_pid: self(),
        parent_id: "parent-agent-id",
        restoration_mode: true,
        test_mode: true,
        sandbox_owner: sandbox_owner,
        pubsub: deps.pubsub,
        registry: deps.registry,
        dynsup: deps.dynsup
      }

      # Spawn restored child agent
      {:ok, _pid} =
        spawn_agent_with_cleanup(deps.dynsup, config,
          registry: deps.registry,
          pubsub: deps.pubsub
        )

      # Verify broadcast WAS received (this is the fix!)
      assert_receive {:agent_spawned, payload}, 30_000
      assert payload.agent_id == restored_child_id
      assert payload.task_id == task_id
    end

    @tag :integration
    test "R11: restored root agent broadcasts spawn event", %{
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      restored_root_id = "restored-root-agent-#{System.unique_integer([:positive])}"
      task_id = Ecto.UUID.generate()

      # Config simulating root restoration (no parent_id, restoration_mode true)
      config = %{
        agent_id: restored_root_id,
        task_id: task_id,
        parent_pid: nil,
        parent_id: nil,
        restoration_mode: true,
        test_mode: true,
        sandbox_owner: sandbox_owner,
        pubsub: deps.pubsub,
        registry: deps.registry,
        dynsup: deps.dynsup
      }

      # Spawn restored root agent
      {:ok, _pid} =
        spawn_agent_with_cleanup(deps.dynsup, config,
          registry: deps.registry,
          pubsub: deps.pubsub
        )

      # Verify broadcast was received (unchanged behavior)
      assert_receive {:agent_spawned, payload}, 30_000
      assert payload.agent_id == restored_root_id
      assert payload.task_id == task_id
    end
  end

  # ========== ACCEPTANCE TEST (A1) ==========

  describe "A1: Restored children visible in UI" do
    @tag :acceptance
    @tag :integration
    test "restored child agents are announced via PubSub for UI visibility", %{
      sandbox_owner: sandbox_owner
    } do
      deps = create_isolated_deps()

      # Create task in DB
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test task", status: "paused"}))

      # Create parent agent record in DB (simulating existing paused agent)
      parent_agent_id = "accept-parent-#{System.unique_integer([:positive])}"

      {:ok, _parent_db} =
        Repo.insert(%AgentSchema{
          agent_id: parent_agent_id,
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: %{}
        })

      # Create child agent record in DB (simulating existing paused child)
      child_agent_id = "accept-child-#{System.unique_integer([:positive])}"

      {:ok, child_db} =
        Repo.insert(%AgentSchema{
          agent_id: child_agent_id,
          task_id: task.id,
          status: "running",
          parent_id: parent_agent_id,
          config: %{},
          state: %{}
        })

      # Subscribe to agent events (simulating UI subscription)
      Phoenix.PubSub.subscribe(deps.pubsub, "agents:lifecycle")

      # Step 1: Restore the child agent (simulating TaskRestorer flow)
      # This should broadcast agent_spawned event for UI visibility
      assert {:ok, _restored_pid} =
               restore_agent_with_cleanup(deps.dynsup, child_db,
                 registry: deps.registry,
                 pubsub: deps.pubsub,
                 sandbox_owner: sandbox_owner
               )

      # Step 2: Verify UI would receive the spawn event
      # Positive assertion - broadcast received
      assert_receive {:agent_spawned, payload}, 30_000
      assert payload.agent_id == child_agent_id
      assert payload.task_id == task.id

      # Negative assertions - verify no error states
      refute_receive {:agent_terminated, %{agent_id: ^child_agent_id}}, 100
    end
  end
end
