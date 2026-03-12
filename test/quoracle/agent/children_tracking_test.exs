defmodule Quoracle.Agent.ChildrenTrackingTest do
  @moduledoc """
  Integration tests for the complete children tracking flow.

  Tests the interaction between ACTION_Spawn, AGENT_ChildrenTracker,
  CONSENSUS_ChildrenInjector, and ACTION_DismissChild.

  WorkGroupID: feat-20260309-185610
  Packet: 1 (Message Enrichment)

  Requirements tested:
  - R1: Spawn Updates Parent Children List
  - R2: Child Has spawned_at Timestamp
  - R3: Dismiss Removes Child from List
  - R4: Children Injected into Consensus Prompts
  - R4a: Enriched children context shows message from child (v2.0)
  - R4b: Children context shows null when child has not replied (v2.0)
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

  defp register_registry_child(registry, child_id, parent_pid) do
    Registry.register(registry, {:agent, child_id}, %{
      pid: self(),
      parent_pid: parent_pid,
      registered_at: System.monotonic_time()
    })

    child_id
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
    test "parent without children shows empty children signal", %{
      deps: deps,
      profile: _profile
    } do
      # Arrange: Create parent agent WITHOUT any children
      {:ok, parent_pid} = spawn_parent_agent(deps)
      {:ok, parent_state} = Core.get_state(parent_pid)
      assert parent_state.children == [], "Parent should have no children"

      # Act: Build consensus state and verify empty children signal
      alias Quoracle.Agent.ConsensusHandler

      messages = [%{role: "user", content: "What should I do?"}]
      injected = ConsensusHandler.inject_children_context(parent_state, messages)

      # Assert: Empty children signal injected
      content = hd(injected).content
      assert content =~ "<children>No child agents running.</children>"
      assert content =~ "What should I do?"
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

    # R4a: Enriched children context shows message from child (NEW v2.0)
    @tag :r4a
    test "children context includes preview when child has sent a message", %{
      deps: deps,
      profile: _profile
    } do
      # Arrange: Create parent agent and manually add child
      {:ok, parent_pid} = spawn_parent_agent(deps)
      {:ok, _parent_state} = Core.get_state(parent_pid)

      child_id = "child-enriched-#{System.unique_integer([:positive])}"
      child_data = %{agent_id: child_id, spawned_at: DateTime.utc_now()}

      # Register fake child in Registry so filter_live_children finds it
      Registry.register(deps.registry, {:agent, child_id}, %{pid: self()})
      GenServer.cast(parent_pid, {:child_spawned, child_data})

      # Simulate child sending a message to the parent (3-tuple format)
      send(parent_pid, {:agent_message, child_id, "Here are the benchmark results"})

      # Sync wait — get_state processes all preceding messages
      {:ok, state_with_child} = Core.get_state(parent_pid)

      # Act: Inject children context as consensus would
      messages = [%{role: "user", content: "What should I do next?"}]
      injected = ChildrenInjector.inject_children_context(state_with_child, messages)

      # Assert: Children block contains message preview
      content = hd(injected).content
      assert content =~ "<children>"
      assert content =~ child_id
      assert content =~ "Here are the benchmark results"
      # Should have a latest_message_at timestamp (not null)
      refute content =~ ~s("latest_message_preview":null)
    end

    # R4b: Children context shows null when child has NOT sent a message (NEW v2.0)
    @tag :r4b
    test "children context shows null preview when child has not replied", %{
      deps: deps,
      profile: _profile
    } do
      # Arrange: Create parent agent with child but NO messages from child
      {:ok, parent_pid} = spawn_parent_agent(deps)

      child_id = "child-silent-#{System.unique_integer([:positive])}"
      child_data = %{agent_id: child_id, spawned_at: DateTime.utc_now()}

      Registry.register(deps.registry, {:agent, child_id}, %{pid: self()})
      GenServer.cast(parent_pid, {:child_spawned, child_data})

      {:ok, state_with_child} = Core.get_state(parent_pid)

      # Act
      messages = [%{role: "user", content: "What should I do next?"}]
      injected = ChildrenInjector.inject_children_context(state_with_child, messages)

      # Assert: Child entry has null message fields
      content = hd(injected).content
      assert content =~ child_id
      assert content =~ ~s("latest_message_preview":null)
      assert content =~ ~s("latest_message_at":null)
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

  describe "R37-R39: race condition and dedup fixes" do
    @tag :acceptance
    test "children visible in consensus when child_spawned casts lag", %{deps: deps} do
      response_json =
        Jason.encode!(%{"action" => "wait", "params" => %{}, "reasoning" => "test"})

      mock_query_fn = fn _messages, [model_id], _opts ->
        {:ok,
         %{
           successful_responses: [%{model: model_id, content: response_json}],
           failed_models: []
         }}
      end

      {:ok, parent_pid} =
        spawn_agent_with_cleanup(
          deps.dynsup,
          %{
            agent_id: "parent-#{System.unique_integer([:positive])}",
            task_id: Ecto.UUID.generate(),
            test_mode: true,
            sandbox_owner: deps.sandbox_owner,
            registry: deps.registry,
            dynsup: deps.dynsup,
            pubsub: deps.pubsub,
            model_pool: ["mock-model"],
            model_histories: %{"mock-model" => []},
            prompt_fields: %{
              provided: %{task_description: "Parent agent task"},
              injected: %{global_context: "", constraints: []},
              transformed: %{}
            },
            test_opts: [model_query_fn: mock_query_fn]
          },
          registry: deps.registry,
          pubsub: deps.pubsub,
          sandbox_owner: deps.sandbox_owner
        )

      {:ok, parent_state} = Core.get_state(parent_pid)
      Phoenix.PubSub.subscribe(deps.pubsub, "agents:#{parent_state.agent_id}:logs")

      child_ids =
        for i <- 1..3 do
          register_registry_child(
            deps.registry,
            "race-child-#{i}-#{System.unique_integer([:positive])}",
            parent_pid
          )
        end

      {:ok, state} = Core.get_state(parent_pid)
      assert state.children == []

      Core.send_user_message(parent_pid, "What should I do?")

      receive_consensus_log = fn receive_consensus_log, remaining_ms ->
        receive do
          {:log_entry, log_entry} ->
            if log_entry.message =~ "Sending to consensus" do
              log_entry
            else
              receive_consensus_log.(receive_consensus_log, remaining_ms)
            end
        after
          remaining_ms ->
            flunk("Expected a 'Sending to consensus' log entry")
        end
      end

      log_entry = receive_consensus_log.(receive_consensus_log, 30_000)

      sent_messages = log_entry.metadata[:sent_messages]
      assert is_list(sent_messages)
      [model_entry | _] = sent_messages

      last_user_message = Enum.find(Enum.reverse(model_entry.messages), &(&1.role == "user"))
      assert last_user_message, "Expected at least one user message in sent_messages"

      last_user_content =
        case last_user_message.content do
          binary when is_binary(binary) -> binary
          list when is_list(list) -> Enum.map_join(list, " ", &to_string(&1[:text] || ""))
        end

      assert last_user_content =~ "What should I do?"
      assert last_user_content =~ "<children>"
      refute last_user_content =~ "No child agents running"

      for child_id <- child_ids do
        assert last_user_content =~ child_id
      end
    end

    test "duplicate child_spawned casts don't create duplicate children", %{deps: deps} do
      {:ok, parent_pid} = spawn_parent_agent(deps)

      child_id = "dedup-child-#{System.unique_integer([:positive])}"
      register_registry_child(deps.registry, child_id, parent_pid)

      child_data = %{agent_id: child_id, spawned_at: DateTime.utc_now()}

      GenServer.cast(parent_pid, {:child_spawned, child_data})
      GenServer.cast(parent_pid, {:child_spawned, child_data})

      {:ok, state} = Core.get_state(parent_pid)

      matching = Enum.filter(state.children, &(&1.agent_id == child_id))
      assert length(matching) == 1
    end

    test "children from both state tracking and Registry merge correctly", %{deps: deps} do
      {:ok, parent_pid} = spawn_parent_agent(deps)

      tracked_child_id = "tracked-#{System.unique_integer([:positive])}"
      registry_only_child_id = "untracked-#{System.unique_integer([:positive])}"

      register_registry_child(deps.registry, tracked_child_id, parent_pid)
      register_registry_child(deps.registry, registry_only_child_id, parent_pid)

      tracked_child = %{agent_id: tracked_child_id, spawned_at: DateTime.utc_now()}
      GenServer.cast(parent_pid, {:child_spawned, tracked_child})

      {:ok, state} = Core.get_state(parent_pid)

      assert Enum.any?(state.children, &(&1.agent_id == tracked_child_id))
      refute Enum.any?(state.children, &(&1.agent_id == registry_only_child_id))

      messages = [%{role: "user", content: "Status?"}]
      injected = ChildrenInjector.inject_children_context(state, messages)
      content = hd(injected).content

      assert content =~ tracked_child_id
      assert content =~ registry_only_child_id
    end
  end
end
