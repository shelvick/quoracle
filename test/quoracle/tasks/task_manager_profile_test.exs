defmodule Quoracle.Tasks.TaskManagerProfileTest do
  @moduledoc """
  Tests for TASK_Manager v6.0 - Profile integration in task creation.

  ARC Requirements (feat-20260105-profiles):
  - R23: Profile required for task creation [UNIT]
  - R24: Profile resolved via ProfileResolver [INTEGRATION]
  - R25: Profile not found error [INTEGRATION]
  - R26: Profile stored in task [INTEGRATION]
  - R27: Root agent gets profile data [INTEGRATION]
  - R28: Acceptance - E2E task creation with profile [SYSTEM]
  """

  use Quoracle.DataCase, async: true

  import Test.AgentTestHelpers

  alias Quoracle.Tasks.TaskManager
  alias Quoracle.Tasks.Task
  alias Quoracle.Profiles.TableProfiles
  alias Quoracle.Repo

  setup %{sandbox_owner: sandbox_owner} do
    # Create isolated PubSub
    pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})

    # Create isolated Registry
    registry = :"test_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry})

    # Create isolated DynSup with :infinity shutdown
    dynsup_spec = %{
      id: {DynamicSupervisor, make_ref()},
      start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one]]},
      shutdown: :infinity
    }

    {:ok, dynsup} = start_supervised(dynsup_spec)

    deps = %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    }

    %{deps: deps}
  end

  # Helper to create test profile
  defp create_profile(attrs) do
    default_attrs = %{
      name: "test-profile-#{System.unique_integer([:positive])}",
      model_pool: ["gpt-4o"],
      capability_groups: [
        "hierarchy",
        "local_execution",
        "file_read",
        "file_write",
        "external_api"
      ]
    }

    merged = Map.merge(default_attrs, attrs)

    %TableProfiles{}
    |> TableProfiles.changeset(merged)
    |> Repo.insert!()
  end

  describe "R23: Profile required for task creation" do
    test "returns error when profile not provided", %{deps: deps} do
      task_fields = %{}
      agent_fields = %{task_description: "Build app"}

      opts = [
        dynsup: deps.dynsup,
        registry: deps.registry,
        pubsub: deps.pubsub,
        sandbox_owner: deps.sandbox_owner
      ]

      result = TaskManager.create_task(task_fields, agent_fields, opts)

      assert {:error, :profile_required} = result
    end

    test "returns error when profile is empty string", %{deps: deps} do
      task_fields = %{profile: ""}
      agent_fields = %{task_description: "Build app"}

      opts = [
        dynsup: deps.dynsup,
        registry: deps.registry,
        pubsub: deps.pubsub,
        sandbox_owner: deps.sandbox_owner
      ]

      result = TaskManager.create_task(task_fields, agent_fields, opts)

      assert {:error, :profile_required} = result
    end
  end

  describe "R24: Profile resolved via ProfileResolver" do
    @tag :integration
    test "resolves profile and uses its data", %{deps: deps} do
      profile =
        create_profile(%{
          name: "resolver-test",
          model_pool: ["gpt-4o", "claude-sonnet"],
          capability_groups: ["local_execution", "file_read", "file_write", "external_api"]
        })

      task_fields = %{profile: profile.name}
      agent_fields = %{task_description: "Build app"}

      opts = [
        dynsup: deps.dynsup,
        registry: deps.registry,
        pubsub: deps.pubsub,
        sandbox_owner: deps.sandbox_owner
      ]

      assert {:ok, {_task, agent_pid}} = TaskManager.create_task(task_fields, agent_fields, opts)

      # Wait for agent initialization with GenServer.call (proper synchronization)
      {:ok, state} = Quoracle.Agent.Core.get_state(agent_pid)

      # Verify profile data was resolved and used
      assert state.profile_name == "resolver-test"
      assert state.model_pool == ["gpt-4o", "claude-sonnet"]
      assert state.capability_groups == [:local_execution, :file_read, :file_write, :external_api]

      # Cleanup
      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: deps.registry)
    end
  end

  describe "R25: Profile not found error" do
    @tag :integration
    test "returns error when profile doesn't exist", %{deps: deps} do
      task_fields = %{profile: "nonexistent-profile-xyz"}
      agent_fields = %{task_description: "Build app"}

      opts = [
        dynsup: deps.dynsup,
        registry: deps.registry,
        pubsub: deps.pubsub,
        sandbox_owner: deps.sandbox_owner
      ]

      result = TaskManager.create_task(task_fields, agent_fields, opts)

      assert {:error, :profile_not_found} = result
    end

    @tag :integration
    test "no task created when profile not found", %{deps: deps} do
      task_fields = %{profile: "nonexistent-profile-xyz"}
      agent_fields = %{task_description: "Build app"}

      opts = [
        dynsup: deps.dynsup,
        registry: deps.registry,
        pubsub: deps.pubsub,
        sandbox_owner: deps.sandbox_owner
      ]

      {:error, :profile_not_found} = TaskManager.create_task(task_fields, agent_fields, opts)

      # Verify no task was created
      tasks = Repo.all(Task)
      refute Enum.any?(tasks, &(&1.prompt == "Build app"))
    end
  end

  describe "R26: Profile stored in task" do
    @tag :integration
    test "profile name stored in task record", %{deps: deps} do
      profile = create_profile(%{name: "storage-test"})

      task_fields = %{profile: profile.name}
      agent_fields = %{task_description: "Build app"}

      opts = [
        dynsup: deps.dynsup,
        registry: deps.registry,
        pubsub: deps.pubsub,
        sandbox_owner: deps.sandbox_owner
      ]

      assert {:ok, {task, agent_pid}} = TaskManager.create_task(task_fields, agent_fields, opts)

      # Verify profile_name stored in task
      assert task.profile_name == "storage-test"

      # Verify persisted to DB
      db_task = Repo.get!(Task, task.id)
      assert db_task.profile_name == "storage-test"

      # Cleanup
      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: deps.registry)
    end
  end

  describe "R27: Root agent gets profile data" do
    @tag :integration
    test "root agent state contains profile fields", %{deps: deps} do
      profile =
        create_profile(%{
          name: "agent-test",
          description: "Test profile for agents",
          model_pool: ["gpt-4o"],
          capability_groups: ["hierarchy", "file_read", "file_write"]
        })

      task_fields = %{profile: profile.name}
      agent_fields = %{task_description: "Build app"}

      opts = [
        dynsup: deps.dynsup,
        registry: deps.registry,
        pubsub: deps.pubsub,
        sandbox_owner: deps.sandbox_owner
      ]

      assert {:ok, {_task, agent_pid}} = TaskManager.create_task(task_fields, agent_fields, opts)

      # Synchronous call to wait for init
      {:ok, state} = Quoracle.Agent.Core.get_state(agent_pid)

      # Verify all profile fields in agent state
      assert state.profile_name == "agent-test"
      assert state.profile_description == "Test profile for agents"
      assert state.model_pool == ["gpt-4o"]
      assert state.capability_groups == [:hierarchy, :file_read, :file_write]

      # Cleanup
      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: deps.registry)
    end

    @tag :integration
    test "profile description nil when not set", %{deps: deps} do
      profile =
        create_profile(%{
          name: "no-desc-test",
          model_pool: ["gpt-4o"],
          capability_groups: [
            "hierarchy",
            "local_execution",
            "file_read",
            "file_write",
            "external_api"
          ]
          # No description
        })

      task_fields = %{profile: profile.name}
      agent_fields = %{task_description: "Build app"}

      opts = [
        dynsup: deps.dynsup,
        registry: deps.registry,
        pubsub: deps.pubsub,
        sandbox_owner: deps.sandbox_owner
      ]

      assert {:ok, {_task, agent_pid}} = TaskManager.create_task(task_fields, agent_fields, opts)

      {:ok, state} = Quoracle.Agent.Core.get_state(agent_pid)

      assert state.profile_name == "no-desc-test"
      assert state.profile_description == nil

      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: deps.registry)
    end
  end

  describe "R28: Acceptance - E2E task creation with profile" do
    @tag :acceptance
    @tag :system
    test "full flow: user creates task with profile selection", %{deps: deps} do
      # Setup: Create profile (simulates profile existing in DB)
      profile =
        create_profile(%{
          name: "acceptance-profile",
          description: "For acceptance testing",
          model_pool: ["gpt-4o", "claude-sonnet"],
          capability_groups: ["hierarchy", "file_read", "file_write", "external_api"]
        })

      # Entry point: User submits task form with profile selection
      # (Simulates what Dashboard.handle_submit_prompt does)
      task_fields = %{
        profile: profile.name,
        global_context: "Testing context"
      }

      agent_fields = %{
        task_description: "Complete the acceptance test",
        role: "Tester"
      }

      opts = [
        dynsup: deps.dynsup,
        registry: deps.registry,
        pubsub: deps.pubsub,
        sandbox_owner: deps.sandbox_owner
      ]

      # User action: Create task
      assert {:ok, {task, agent_pid}} = TaskManager.create_task(task_fields, agent_fields, opts)

      # User expectation 1: Task is created and running
      assert task.status == "running"
      assert task.profile_name == "acceptance-profile"
      assert Process.alive?(agent_pid)

      # User expectation 2: Agent has correct profile configuration
      {:ok, state} = Quoracle.Agent.Core.get_state(agent_pid)
      assert state.profile_name == "acceptance-profile"
      assert state.capability_groups == [:hierarchy, :file_read, :file_write, :external_api]
      assert state.model_pool == ["gpt-4o", "claude-sonnet"]

      # User expectation 3: Agent prompt contains task description
      assert state.prompt_fields.provided.task_description == "Complete the acceptance test"

      # Cleanup
      register_agent_cleanup(agent_pid, cleanup_tree: true, registry: deps.registry)
    end
  end
end
