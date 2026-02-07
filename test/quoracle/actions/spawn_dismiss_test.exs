defmodule Quoracle.Actions.SpawnDismissTest do
  @moduledoc """
  Tests for Spawn/DismissChild integration.

  Tests verify:
  - R1: Spawn fails when parent is being terminated (dismissing flag set by TreeTerminator)
  - R2: Spawn succeeds when parent not being terminated
  - R3: Spawn allowed after dismiss of sibling completes

  Note: The parent's dismissing flag is set by TreeTerminator when the parent itself
  is being terminated (prevents spawning children while dying). The dismiss_child action
  does NOT set the parent's dismissing flag - only the children being dismissed get
  their flags set.
  """

  # Uses event-based synchronization (PubSub + assert_receive), not timing
  use Quoracle.DataCase, async: true

  alias Quoracle.Actions.Spawn
  alias Quoracle.Actions.DismissChild
  alias Quoracle.Agent.Core
  alias Test.IsolationHelpers

  import Test.AgentTestHelpers,
    only: [
      create_test_profile: 0,
      spawn_agent_with_cleanup: 3
    ]

  setup %{sandbox_owner: sandbox_owner} do
    deps = IsolationHelpers.create_isolated_deps()
    deps = Map.put(deps, :sandbox_owner, sandbox_owner)

    # Add spawn_complete_notify for async spawn tests
    test_pid = self()
    deps = Map.put(deps, :spawn_complete_notify, test_pid)

    # Add parent_config to deps - required by ConfigBuilder (prevents GenServer deadlock)
    deps =
      Map.put(deps, :parent_config, %{
        task_id: Ecto.UUID.generate(),
        prompt_fields: %{
          injected: %{global_context: "", constraints: []},
          provided: %{},
          transformed: %{}
        },
        models: [],
        sandbox_owner: sandbox_owner,
        test_mode: true,
        pubsub: deps.pubsub,
        skip_auto_consensus: true
      })

    {:ok, deps: deps, profile: create_test_profile()}
  end

  # Helper to spawn a test agent with proper parent relationship
  defp spawn_test_agent(agent_id, deps, opts \\ []) do
    parent_id = Keyword.get(opts, :parent_id)
    parent_pid = Keyword.get(opts, :parent_pid)

    config = %{
      agent_id: agent_id,
      parent_id: parent_id,
      parent_pid: parent_pid,
      task_id: Keyword.get(opts, :task_id, Ecto.UUID.generate()),
      test_mode: true,
      skip_auto_consensus: true,
      sandbox_owner: deps.sandbox_owner
    }

    spawn_agent_with_cleanup(
      deps.dynsup,
      config,
      registry: deps.registry,
      pubsub: deps.pubsub
    )
  end

  # Helper to check if agent exists in registry
  defp agent_exists?(agent_id, registry) do
    case Registry.lookup(registry, {:agent, agent_id}) do
      [{_pid, _meta}] -> true
      [] -> false
    end
  end

  # Wait for agent to be removed from Registry (handles async cleanup race)
  defp wait_for_registry_cleanup(agent_id, registry, timeout \\ 1000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_cleanup(agent_id, registry, deadline)
  end

  defp do_wait_for_cleanup(agent_id, registry, deadline) do
    if agent_exists?(agent_id, registry) do
      if System.monotonic_time(:millisecond) < deadline do
        # Registry cleanup is async (DOWN message handling)
        # Use receive/after instead of Process.sleep (Credo-compliant)
        receive do
        after
          5 -> do_wait_for_cleanup(agent_id, registry, deadline)
        end
      else
        {:error, :timeout}
      end
    else
      :ok
    end
  end

  # Build spawn params with required fields
  defp spawn_params(task, profile) do
    %{
      "task_description" => task,
      "success_criteria" => "Complete the task",
      "immediate_context" => "Test context",
      "approach_guidance" => "Standard approach",
      "profile" => profile.name
    }
  end

  # Build opts for Spawn.execute/3 - include all deps for background task
  defp spawn_opts(deps, parent_pid) do
    Map.to_list(deps) ++ [agent_pid: parent_pid]
  end

  # Wait for background spawn to complete (prevents sandbox exit race)
  defp wait_for_spawn_complete(child_id, timeout \\ 2000) do
    receive do
      {:spawn_complete, ^child_id, _result} -> :ok
    after
      timeout -> :timeout
    end
  end

  # Build opts for DismissChild.execute/3
  defp dismiss_opts(deps) do
    [
      registry: deps.registry,
      dynsup: deps.dynsup,
      pubsub: deps.pubsub,
      sandbox_owner: deps.sandbox_owner
    ]
  end

  # ==========================================================================
  # Spawn Blocked When Agent Being Terminated (R1, R2)
  # ==========================================================================

  describe "spawn blocked when agent being terminated" do
    @tag :r1
    test "R1: spawn fails when parent is being terminated (dismissing flag set)", %{
      deps: deps,
      profile: profile
    } do
      # Arrange: Create parent agent
      {:ok, parent_pid} = spawn_test_agent("parent", deps)

      # Simulate parent being terminated by TreeTerminator (sets dismissing flag)
      :ok = Core.set_dismissing(parent_pid, true)

      # Act: Try to spawn child
      result =
        Spawn.execute(
          spawn_params("new child task", profile),
          "parent",
          spawn_opts(deps, parent_pid)
        )

      # Assert: Spawn blocked with :parent_dismissing error
      assert {:error, :parent_dismissing} = result
    end

    @tag :r2
    test "R2: spawn succeeds when parent not being terminated", %{deps: deps, profile: profile} do
      # Arrange: Create parent agent (not dismissing)
      {:ok, parent_pid} = spawn_test_agent("parent", deps)

      # Verify parent is not dismissing
      assert Core.dismissing?(parent_pid) == false

      # Act: Spawn child
      result =
        Spawn.execute(
          spawn_params("child task", profile),
          "parent",
          spawn_opts(deps, parent_pid)
        )

      # Assert: Spawn succeeds
      assert {:ok, %{action: "spawn", agent_id: child_id}} = result
      assert is_binary(child_id)

      # Wait for background spawn to complete (prevents sandbox exit race)
      assert :ok = wait_for_spawn_complete(child_id)
    end
  end

  # ==========================================================================
  # Spawn During/After Sibling Dismiss (R3)
  # ==========================================================================

  describe "spawn during sibling dismiss" do
    @tag :r3
    test "R3: spawn allowed while sibling is being dismissed", %{
      deps: deps,
      profile: profile
    } do
      # Arrange: Create parent with child
      {:ok, parent_pid} = spawn_test_agent("parent", deps)

      {:ok, _child_pid} =
        spawn_test_agent("child-to-dismiss", deps,
          parent_id: "parent",
          parent_pid: parent_pid
        )

      # Subscribe to child termination
      Phoenix.PubSub.subscribe(deps.pubsub, "agents:child-to-dismiss")

      # Act: Start dismiss of sibling
      {:ok, _} =
        DismissChild.execute(
          %{child_id: "child-to-dismiss"},
          "parent",
          dismiss_opts(deps)
        )

      # Parent's dismissing flag should NOT be set (only the child being dismissed gets it)
      assert Core.dismissing?(parent_pid) == false

      # Spawn new child should work even while sibling dismiss is in progress
      result =
        Spawn.execute(
          spawn_params("new child during sibling dismiss", profile),
          "parent",
          spawn_opts(deps, parent_pid)
        )

      # Assert: Spawn succeeds (parent is not being terminated)
      assert {:ok, %{action: "spawn", agent_id: new_child_id}} = result

      # Wait for background spawn to complete (prevents sandbox exit race)
      assert :ok = wait_for_spawn_complete(new_child_id)

      # Wait for sibling dismiss to complete
      assert_receive {:agent_terminated, %{agent_id: "child-to-dismiss"}}, 30_000
      :ok = wait_for_registry_cleanup("child-to-dismiss", deps.registry)

      # Verify dismissed child is gone, new child exists
      refute agent_exists?("child-to-dismiss", deps.registry)
      assert agent_exists?(new_child_id, deps.registry)
    end
  end
end
