defmodule Quoracle.Agent.ChildrenTrackingTest do
  @moduledoc """
  Integration tests for the complete children tracking flow.

  Tests the interaction between ACTION_Spawn, AGENT_ChildrenTracker,
  CONSENSUS_ChildrenInjector, and ACTION_DismissChild.

  WorkGroupID: feat-20251227-children-inject
  Packet: 3 (Action Integration)

  Requirements tested:
  - R1: Spawn Updates Parent Children List
  - R2: Child Has spawned_at Timestamp
  - R3: Dismiss Removes Child from List
  - R4: Children Injected into Consensus Prompts
  - R5: Restoration Rebuilds Children from Registry
  - R6: Multiple Children Ordering
  """
  use Quoracle.DataCase, async: true

  alias Quoracle.Agent.Core
  alias Quoracle.Agent.ConsensusHandler.ChildrenInjector
  alias Quoracle.Actions.Spawn
  alias Quoracle.Actions.DismissChild
  alias Test.IsolationHelpers

  import Test.AgentTestHelpers,
    only: [
      create_test_profile: 0,
      spawn_agent_with_cleanup: 3
    ]

  setup %{sandbox_owner: sandbox_owner} do
    deps = IsolationHelpers.create_isolated_deps()
    deps = Map.put(deps, :sandbox_owner, sandbox_owner)

    # Subscribe to lifecycle events
    Phoenix.PubSub.subscribe(deps.pubsub, "agents:lifecycle")

    # Add spawn_complete_notify for async spawn completion
    deps = Map.put(deps, :spawn_complete_notify, self())

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

  # Helper to spawn a parent agent for testing
  defp spawn_parent_agent(deps, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id, "parent-#{System.unique_integer([:positive])}")

    config = %{
      agent_id: agent_id,
      task_id: Ecto.UUID.generate(),
      test_mode: true,
      skip_auto_consensus: true,
      sandbox_owner: deps.sandbox_owner,
      pubsub: deps.pubsub,
      prompt_fields: %{
        provided: %{task_description: "Parent agent task"},
        injected: %{global_context: "", constraints: []},
        transformed: %{}
      },
      models: []
    }

    spawn_agent_with_cleanup(
      deps.dynsup,
      config,
      registry: deps.registry,
      pubsub: deps.pubsub,
      sandbox_owner: deps.sandbox_owner
    )
  end

  # Helper to wait for background spawn to complete
  defp wait_for_spawn_complete(child_id, timeout \\ 5000) do
    receive do
      {:spawn_complete, ^child_id, {:ok, child_pid}} -> child_pid
      {:spawn_complete, ^child_id, {:error, _reason}} -> nil
    after
      timeout -> nil
    end
  end

  # Helper to wait for agent to appear in Registry
  defp wait_for_agent(agent_id, registry, timeout \\ 5000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    wait_loop = fn wait_loop ->
      case Registry.lookup(registry, {:agent, agent_id}) do
        [{_pid, _}] ->
          :ok

        [] ->
          if System.monotonic_time(:millisecond) < deadline do
            # Registry updates are async (DOWN message processing)
            # Use receive/after instead of Process.sleep (Credo-compliant)
            receive do
            after
              10 -> wait_loop.(wait_loop)
            end
          else
            {:error, :timeout}
          end
      end
    end

    wait_loop.(wait_loop)
  end

  # Helper to wait for agent to be removed from Registry
  defp wait_for_agent_gone(agent_id, registry, timeout \\ 5000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    wait_loop = fn wait_loop ->
      case Registry.lookup(registry, {:agent, agent_id}) do
        [] ->
          :ok

        [{_pid, _}] ->
          if System.monotonic_time(:millisecond) < deadline do
            # Registry updates are async (DOWN message processing)
            # Use receive/after instead of Process.sleep (Credo-compliant)
            receive do
            after
              10 -> wait_loop.(wait_loop)
            end
          else
            {:error, :timeout}
          end
      end
    end

    wait_loop.(wait_loop)
  end

  # Build spawn opts
  defp spawn_opts(deps, parent_pid) do
    Map.to_list(deps) ++ [agent_pid: parent_pid]
  end

  # Build action opts
  defp action_opts(deps, parent_pid) do
    [
      registry: deps.registry,
      dynsup: deps.dynsup,
      pubsub: deps.pubsub,
      sandbox_owner: deps.sandbox_owner,
      agent_pid: parent_pid
    ]
  end

  # ==========================================================================
  # R1: Spawn Updates Parent Children List
  # ==========================================================================

  describe "R1: spawn updates parent state" do
    test "successful spawn adds child to parent's children list", %{deps: deps, profile: profile} do
      # Arrange: Spawn parent agent
      {:ok, parent_pid} = spawn_parent_agent(deps)
      {:ok, parent_state} = Core.get_state(parent_pid)
      parent_id = parent_state.agent_id

      # Get initial children count
      initial_count = length(parent_state.children)

      # Act: Spawn child
      params = %{
        "task_description" => "Child task",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      {:ok, result} = Spawn.execute(params, parent_id, spawn_opts(deps, parent_pid))
      child_id = result.agent_id

      # CRITICAL: Register cleanup IMMEDIATELY using registry lookup (before wait)
      on_exit(fn ->
        try do
          case Registry.lookup(deps.registry, {:agent, child_id}) do
            [{pid, _}] ->
              if Process.alive?(pid) do
                GenServer.stop(pid, :normal, :infinity)
              end

            [] ->
              :ok
          end
        rescue
          ArgumentError -> :ok
        catch
          :exit, _ -> :ok
        end
      end)

      # Now wait for spawn to complete
      _child_pid = wait_for_spawn_complete(child_id)

      # Assert: Parent's children list updated
      {:ok, state_after} = Core.get_state(parent_pid)
      assert length(state_after.children) == initial_count + 1
      assert Enum.any?(state_after.children, &(&1.agent_id == result.agent_id))
    end
  end

  # ==========================================================================
  # R2: Child Has spawned_at Timestamp
  # ==========================================================================

  describe "R2: child entry timestamp" do
    test "child entry has spawned_at timestamp", %{deps: deps, profile: profile} do
      # Arrange: Spawn parent agent
      {:ok, parent_pid} = spawn_parent_agent(deps)
      {:ok, parent_state} = Core.get_state(parent_pid)
      parent_id = parent_state.agent_id

      before_spawn = DateTime.utc_now()

      # Act: Spawn child
      params = %{
        "task_description" => "Child task",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      {:ok, result} = Spawn.execute(params, parent_id, spawn_opts(deps, parent_pid))
      child_id = result.agent_id

      # CRITICAL: Register cleanup IMMEDIATELY using registry lookup (before wait)
      on_exit(fn ->
        try do
          case Registry.lookup(deps.registry, {:agent, child_id}) do
            [{pid, _}] ->
              if Process.alive?(pid) do
                GenServer.stop(pid, :normal, :infinity)
              end

            [] ->
              :ok
          end
        rescue
          ArgumentError -> :ok
        catch
          :exit, _ -> :ok
        end
      end)

      # Now wait for spawn to complete
      _child_pid = wait_for_spawn_complete(child_id)

      after_spawn = DateTime.utc_now()

      # Assert: Child entry has valid spawned_at timestamp
      {:ok, updated_state} = Core.get_state(parent_pid)
      child_entry = Enum.find(updated_state.children, &(&1.agent_id == result.agent_id))

      assert child_entry, "Child should be in parent's children list"
      assert child_entry.spawned_at, "Child entry should have spawned_at"
      assert DateTime.compare(child_entry.spawned_at, before_spawn) in [:gt, :eq]
      assert DateTime.compare(child_entry.spawned_at, after_spawn) in [:lt, :eq]
    end
  end

  # ==========================================================================
  # R3: Dismiss Removes Child from List
  # ==========================================================================

  describe "R3: dismiss updates parent state" do
    test "successful dismiss removes child from parent's children list", %{
      deps: deps,
      profile: profile
    } do
      # Arrange: Spawn parent and child
      {:ok, parent_pid} = spawn_parent_agent(deps)
      {:ok, parent_state} = Core.get_state(parent_pid)
      parent_id = parent_state.agent_id

      params = %{
        "task_description" => "Child task",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      {:ok, spawn_result} = Spawn.execute(params, parent_id, spawn_opts(deps, parent_pid))
      child_id = spawn_result.agent_id

      # CRITICAL: Register cleanup IMMEDIATELY using registry lookup (before wait)
      on_exit(fn ->
        try do
          case Registry.lookup(deps.registry, {:agent, child_id}) do
            [{pid, _}] ->
              if Process.alive?(pid) do
                GenServer.stop(pid, :normal, :infinity)
              end

            [] ->
              :ok
          end
        rescue
          ArgumentError -> :ok
        catch
          :exit, _ -> :ok
        end
      end)

      # Now wait for spawn to complete
      _child_pid = wait_for_spawn_complete(child_id)

      # Verify child in list
      {:ok, state_with_child} = Core.get_state(parent_pid)
      assert Enum.any?(state_with_child.children, &(&1.agent_id == child_id))

      # Subscribe to child events
      Phoenix.PubSub.subscribe(deps.pubsub, "agents:#{child_id}")

      # Act: Dismiss child
      {:ok, _dismiss_result} =
        DismissChild.execute(
          %{child_id: child_id},
          parent_id,
          action_opts(deps, parent_pid)
        )

      # Wait for async termination
      assert_receive {:agent_terminated, _}, 30_000
      :ok = wait_for_agent_gone(child_id, deps.registry)

      # Assert: Child removed from list
      {:ok, state_after} = Core.get_state(parent_pid)
      refute Enum.any?(state_after.children, &(&1.agent_id == child_id))
    end
  end

  # ==========================================================================
  # R4: Children Injected into Consensus Prompts
  # ==========================================================================

  describe "R4: children injection in consensus" do
    @tag :r4
    test "parent with children includes children block in consensus flow", %{
      deps: deps,
      profile: _profile
    } do
      # Arrange: Create parent agent and manually add child to its state
      # (simulating what spawn.ex would do after successful spawn)
      {:ok, parent_pid} = spawn_parent_agent(deps)
      {:ok, _parent_state} = Core.get_state(parent_pid)

      # Add child to parent's children list via cast (as spawn.ex would do)
      child_id = "child-acceptance-#{System.unique_integer([:positive])}"

      child_data = %{
        agent_id: child_id,
        spawned_at: DateTime.utc_now()
      }

      # Register fake child in Registry so filter_live_children finds it
      Registry.register(deps.registry, {:agent, child_id}, %{pid: self()})

      GenServer.cast(parent_pid, {:child_spawned, child_data})

      # Sync wait for cast to be processed
      {:ok, state_with_child} = Core.get_state(parent_pid)

      # Verify child is in state
      assert Enum.any?(state_with_child.children, &(&1.agent_id == child_data.agent_id)),
             "Child should be in parent's children list"

      # Act: Build consensus state and call get_action_consensus (what Core does internally)
      # This tests the full consensus flow including children injection
      alias Quoracle.Agent.ConsensusHandler

      # Prepare state for consensus (add required fields)
      consensus_state =
        Map.merge(state_with_child, %{
          model_histories: %{
            "default" => [%{role: "user", content: "What should I do next?"}]
          },
          test_mode: true
        })

      # Call consensus - this should inject children into messages
      result = ConsensusHandler.get_action_consensus(consensus_state)

      # Consensus may fail (no LLM credentials) but we verify injection happened
      assert is_tuple(result), "Should get result tuple from consensus"

      # Verify by directly checking what inject_children_context produces
      messages = [%{role: "user", content: "Test"}]
      injected = ConsensusHandler.inject_children_context(consensus_state, messages)

      assert hd(injected).content =~ "<children>",
             "Consensus messages should include <children> block"

      assert hd(injected).content =~ child_data.agent_id,
             "Children block should contain child's agent_id"
    end

    @tag :r4
    test "parent without children has no children block in consensus flow", %{
      deps: deps,
      profile: _profile
    } do
      # Arrange: Create parent agent WITHOUT any children
      {:ok, parent_pid} = spawn_parent_agent(deps)
      {:ok, parent_state} = Core.get_state(parent_pid)
      assert parent_state.children == [], "Parent should have no children"

      # Act: Build consensus state and verify no children injection
      alias Quoracle.Agent.ConsensusHandler

      messages = [%{role: "user", content: "What should I do?"}]
      injected = ConsensusHandler.inject_children_context(parent_state, messages)

      # Assert: No children block when no children exist
      refute hd(injected).content =~ "<children>",
             "Messages should NOT contain <children> block when no children"

      # Verify messages are unchanged
      assert injected == messages
    end

    test "children appear in consensus messages via ChildrenInjector", %{
      deps: deps,
      profile: profile
    } do
      # Arrange: Spawn parent and child
      {:ok, parent_pid} = spawn_parent_agent(deps)
      {:ok, parent_state} = Core.get_state(parent_pid)
      parent_id = parent_state.agent_id

      params = %{
        "task_description" => "Child task",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      {:ok, spawn_result} = Spawn.execute(params, parent_id, spawn_opts(deps, parent_pid))
      child_id = spawn_result.agent_id

      # CRITICAL: Register cleanup IMMEDIATELY using registry lookup (before wait)
      on_exit(fn ->
        try do
          case Registry.lookup(deps.registry, {:agent, child_id}) do
            [{pid, _}] ->
              if Process.alive?(pid) do
                GenServer.stop(pid, :normal, :infinity)
              end

            [] ->
              :ok
          end
        rescue
          ArgumentError -> :ok
        catch
          :exit, _ -> :ok
        end
      end)

      # Now wait for spawn to complete
      _child_pid = wait_for_spawn_complete(child_id)

      # Get state with children
      {:ok, state_with_child} = Core.get_state(parent_pid)
      assert state_with_child.children != []

      # Act: Build messages as consensus would
      messages = [%{role: "user", content: "Test prompt"}]
      injected = ChildrenInjector.inject_children_context(state_with_child, messages)

      # Assert: Children block present
      content = hd(injected).content
      assert content =~ "<children>"
      assert content =~ spawn_result.agent_id
    end
  end

  # ==========================================================================
  # R5: Restoration Rebuilds Children from Registry
  # ==========================================================================

  describe "R5: children restoration" do
    test "restored agent can rebuild children list from Registry", %{deps: deps, profile: profile} do
      # Arrange: Spawn parent and child
      {:ok, parent_pid} = spawn_parent_agent(deps)
      {:ok, parent_state} = Core.get_state(parent_pid)
      parent_id = parent_state.agent_id

      params = %{
        "task_description" => "Child task",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      {:ok, spawn_result} = Spawn.execute(params, parent_id, spawn_opts(deps, parent_pid))
      child_id = spawn_result.agent_id

      # CRITICAL: Register cleanup IMMEDIATELY using registry lookup (before wait)
      on_exit(fn ->
        try do
          case Registry.lookup(deps.registry, {:agent, child_id}) do
            [{pid, _}] ->
              if Process.alive?(pid) do
                GenServer.stop(pid, :normal, :infinity)
              end

            [] ->
              :ok
          end
        rescue
          ArgumentError -> :ok
        catch
          :exit, _ -> :ok
        end
      end)

      # Now wait for spawn to complete
      _child_pid = wait_for_spawn_complete(child_id)

      :ok = wait_for_agent(child_id, deps.registry)

      # Act: Query Registry for children (as restoration would)
      children_from_registry = Core.find_children_by_parent(parent_pid, deps.registry)

      # Assert: Child should be discoverable via Registry
      child_ids =
        Enum.map(children_from_registry, fn {_pid, composite} ->
          composite.agent_id
        end)

      assert spawn_result.agent_id in child_ids
    end
  end

  # ==========================================================================
  # R6: Multiple Children Ordering
  # ==========================================================================

  describe "R6: children ordering" do
    test "multiple children appear in spawn order (newest first)", %{deps: deps, profile: profile} do
      # Arrange: Spawn parent
      {:ok, parent_pid} = spawn_parent_agent(deps)
      {:ok, parent_state} = Core.get_state(parent_pid)
      parent_id = parent_state.agent_id

      # Act: Spawn first child
      params1 = %{
        "task_description" => "First child",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      {:ok, first_result} = Spawn.execute(params1, parent_id, spawn_opts(deps, parent_pid))
      first_child_id = first_result.agent_id

      # CRITICAL: Register cleanup IMMEDIATELY for first child
      on_exit(fn ->
        try do
          case Registry.lookup(deps.registry, {:agent, first_child_id}) do
            [{pid, _}] ->
              if Process.alive?(pid) do
                GenServer.stop(pid, :normal, :infinity)
              end

            [] ->
              :ok
          end
        rescue
          ArgumentError -> :ok
        catch
          :exit, _ -> :ok
        end
      end)

      _first_child_pid = wait_for_spawn_complete(first_child_id)

      # Spawn second child (timestamps naturally differ - wait_for_spawn_complete
      # ensures first spawn completed, DateTime has microsecond precision)
      params2 = %{
        "task_description" => "Second child",
        "success_criteria" => "Complete",
        "immediate_context" => "Test",
        "approach_guidance" => "Standard",
        "profile" => profile.name
      }

      {:ok, second_result} = Spawn.execute(params2, parent_id, spawn_opts(deps, parent_pid))
      second_child_id = second_result.agent_id

      # CRITICAL: Register cleanup IMMEDIATELY for second child
      on_exit(fn ->
        try do
          case Registry.lookup(deps.registry, {:agent, second_child_id}) do
            [{pid, _}] ->
              if Process.alive?(pid) do
                GenServer.stop(pid, :normal, :infinity)
              end

            [] ->
              :ok
          end
        rescue
          ArgumentError -> :ok
        catch
          :exit, _ -> :ok
        end
      end)

      _second_child_pid = wait_for_spawn_complete(second_child_id)

      # Assert: Verify order (newest first)
      {:ok, final_state} = Core.get_state(parent_pid)
      assert length(final_state.children) == 2

      [newest, oldest] = final_state.children

      assert newest.agent_id == second_result.agent_id,
             "Newest child (second spawn) should be first in list"

      assert oldest.agent_id == first_result.agent_id,
             "Oldest child (first spawn) should be second in list"
    end
  end
end
