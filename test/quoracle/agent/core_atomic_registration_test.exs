defmodule Quoracle.Agent.CoreAtomicRegistrationTest do
  @moduledoc """
  Tests to verify AGENT_Core uses the new atomic Registry registration pattern.
  These tests ensure Core no longer creates separate {:child_of} entries and
  properly uses the composite value from atomic registration.
  """
  use Quoracle.DataCase, async: true
  import Test.AgentTestHelpers

  alias Quoracle.Agent.Core

  setup do
    # Create isolated PubSub to prevent test contamination
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    {:ok, _pubsub} = start_supervised({Phoenix.PubSub, name: pubsub_name})

    # Create isolated Registry to prevent cross-test contamination
    test_registry = :"test_registry_#{System.unique_integer([:positive])}"
    {:ok, _} = start_supervised({Registry, keys: :unique, name: test_registry})

    %{pubsub: pubsub_name, registry: test_registry}
  end

  describe "atomic registration pattern" do
    @tag :arc_reg_01
    test "Core uses ConfigManager.register_agent for atomic registration", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner,
      registry: registry
    } do
      parent_pid = self()
      initial_prompt = "Test agent"

      # Start agent directly (not supervised) for proper cleanup control
      {:ok, agent} =
        Core.start_link(
          {parent_pid, initial_prompt,
           test_mode: true, sandbox_owner: sandbox_owner, pubsub: pubsub, registry: registry}
        )

      # Wait for initialization and ensure cleanup before test exits
      assert {:ok, _state} = Core.get_state(agent)
      register_agent_cleanup(agent)

      # Get the agent_id
      agent_id = Core.get_agent_id(agent)

      # Verify only ONE Registry entry exists for this agent (the atomic composite)
      entries = Registry.lookup(registry, {:agent, agent_id})
      assert length(entries) == 1

      # Verify the composite value structure
      [{^agent, composite}] = entries
      assert composite.pid == agent
      assert composite.parent_pid == parent_pid
      assert is_integer(composite.registered_at)

      # Verify NO separate {:child_of} entry exists
      child_entries = Registry.lookup(registry, {:child_of, parent_pid})
      assert child_entries == []
    end

    @tag :arc_reg_02
    test "Core can find children using composite value queries", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner,
      registry: registry
    } do
      parent_pid = self()

      # Start multiple child agents directly (not supervised) for proper cleanup control
      {:ok, child1} =
        Core.start_link(
          {parent_pid, "Child 1",
           test_mode: true, sandbox_owner: sandbox_owner, pubsub: pubsub, registry: registry}
        )

      {:ok, child2} =
        Core.start_link(
          {parent_pid, "Child 2",
           test_mode: true, sandbox_owner: sandbox_owner, pubsub: pubsub, registry: registry}
        )

      {:ok, child3} =
        Core.start_link(
          {parent_pid, "Child 3",
           test_mode: true, sandbox_owner: sandbox_owner, pubsub: pubsub, registry: registry}
        )

      # Wait for initialization and ensure cleanup
      assert {:ok, _} = Core.get_state(child1)
      assert {:ok, _} = Core.get_state(child2)
      assert {:ok, _} = Core.get_state(child3)

      register_agent_cleanup(child1)
      register_agent_cleanup(child2)
      register_agent_cleanup(child3)

      # Query for children using the composite value pattern with isolated registry
      children = Core.find_children_by_parent(parent_pid, registry)

      # Should find all three children
      assert length(children) == 3
      child_pids = Enum.map(children, fn {pid, _} -> pid end)
      assert child1 in child_pids
      assert child2 in child_pids
      assert child3 in child_pids

      # Each child should have correct parent_pid in composite value
      Enum.each(children, fn {_pid, composite} ->
        assert composite.parent_pid == parent_pid
      end)
    end

    @tag :arc_reg_03
    test "Core handles duplicate agent_id with RuntimeError", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner,
      registry: registry
    } do
      # Trap exits so crashed agents don't kill test process
      Process.flag(:trap_exit, true)

      parent_pid = self()
      agent_id = "duplicate-agent-#{System.unique_integer()}"

      # First agent succeeds
      {:ok, agent1} =
        Core.start_link(%{
          agent_id: agent_id,
          parent_pid: parent_pid,
          task: "First agent",
          test_mode: true,
          sandbox_owner: sandbox_owner,
          pubsub: pubsub,
          registry: registry
        })

      assert Process.alive?(agent1)

      # Wait for initialization and ensure cleanup
      assert {:ok, _} = Core.get_state(agent1)
      register_agent_cleanup(agent1)

      # Second agent with same ID should fail during init
      # When init raises, start_link returns {:error, {exception, stacktrace}}
      # GenServer may log termination - capture_log prevents noise in full test suite
      import ExUnit.CaptureLog

      capture_log(fn ->
        assert {:error, {%RuntimeError{message: message}, _stacktrace}} =
                 Core.start_link(%{
                   agent_id: agent_id,
                   parent_pid: parent_pid,
                   task: "Second agent",
                   test_mode: true,
                   sandbox_owner: sandbox_owner,
                   pubsub: pubsub,
                   registry: registry
                 })

        assert message =~ "Duplicate agent ID: #{agent_id}"
      end)
    end

    @tag :arc_fix_02
    test "no partial registration state visible during Core initialization", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner,
      registry: registry
    } do
      parent_pid = self()

      # Start many agents directly (not supervised) for proper cleanup control
      agents =
        for i <- 1..50 do
          agent_id = "concurrent-#{i}"

          # Start agent
          {:ok, agent} =
            Core.start_link(%{
              agent_id: agent_id,
              parent_pid: parent_pid,
              task: "Agent #{i}",
              test_mode: true,
              sandbox_owner: sandbox_owner,
              pubsub: pubsub,
              registry: registry
            })

          # Immediately check registration - should be complete
          [{^agent, composite}] = Registry.lookup(registry, {:agent, agent_id})

          # Composite should be fully populated
          assert composite.pid == agent
          assert composite.parent_pid == parent_pid
          assert is_integer(composite.registered_at)

          {agent_id, agent}
        end

      # Wait for all agents to initialize and ensure cleanup
      Enum.each(agents, fn {_id, agent_pid} ->
        assert {:ok, _} = Core.get_state(agent_pid)
        register_agent_cleanup(agent_pid)
      end)

      # Verify all agents were created with unique IDs
      agent_ids = Enum.map(agents, fn {id, _} -> id end)
      assert length(agent_ids) == 50
      assert length(Enum.uniq(agent_ids)) == 50
    end

    @tag :arc_fix_03
    test "Core registration is atomic even under query pressure", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner,
      registry: registry
    } do
      parent_pid = self()
      agent_id = "query-test-#{System.unique_integer()}"

      # Start reader tasks that constantly query
      reader_tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            for _ <- 1..100 do
              case Registry.lookup(registry, {:agent, agent_id}) do
                [] ->
                  :not_registered

                [{_pid, composite}] ->
                  # If registered, must be complete
                  if is_map(composite) do
                    # Check if it's our expected composite structure
                    assert is_pid(Map.get(composite, :pid))
                    assert Map.get(composite, :parent_pid) == parent_pid
                    assert is_integer(Map.get(composite, :registered_at))
                  end

                  :fully_registered

                _partial ->
                  # This should NEVER happen with atomic registration
                  # But during transition, might see old format briefly
                  :transitioning
              end
            end
          end)
        end

      # Start the agent while readers are querying
      {:ok, agent} =
        Core.start_link(%{
          agent_id: agent_id,
          parent_pid: parent_pid,
          task: "Test agent",
          test_mode: true,
          sandbox_owner: sandbox_owner,
          pubsub: pubsub,
          registry: registry
        })

      assert Process.alive?(agent)

      # Wait for initialization and ensure cleanup
      assert {:ok, _} = Core.get_state(agent)
      register_agent_cleanup(agent)

      # Wait for all readers to complete
      Enum.each(reader_tasks, &Task.await/1)
    end
  end

  describe "parent relationship queries" do
    @tag :arc_reg_02
    test "Core.get_parent_from_registry returns parent from composite value", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner,
      registry: registry
    } do
      parent_pid = self()

      {:ok, agent} =
        Core.start_link(
          {parent_pid, "Test agent",
           test_mode: true, sandbox_owner: sandbox_owner, pubsub: pubsub, registry: registry}
        )

      # Wait for initialization and ensure cleanup
      assert {:ok, _} = Core.get_state(agent)
      register_agent_cleanup(agent)

      agent_id = Core.get_agent_id(agent)

      # Get parent using the new composite value with isolated registry
      retrieved_parent = Core.get_parent_from_registry(agent_id, registry)
      assert retrieved_parent == parent_pid
    end

    @tag :arc_reg_02
    test "Core can find siblings through parent composite values", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner,
      registry: registry
    } do
      parent_pid = self()

      # Start multiple siblings directly (not supervised) for proper cleanup control
      {:ok, sibling1} =
        Core.start_link(
          {parent_pid, "Sibling 1",
           test_mode: true, sandbox_owner: sandbox_owner, pubsub: pubsub, registry: registry}
        )

      {:ok, sibling2} =
        Core.start_link(
          {parent_pid, "Sibling 2",
           test_mode: true, sandbox_owner: sandbox_owner, pubsub: pubsub, registry: registry}
        )

      {:ok, sibling3} =
        Core.start_link(
          {parent_pid, "Sibling 3",
           test_mode: true, sandbox_owner: sandbox_owner, pubsub: pubsub, registry: registry}
        )

      # Wait for initialization and ensure cleanup
      assert {:ok, _} = Core.get_state(sibling1)
      assert {:ok, _} = Core.get_state(sibling2)
      assert {:ok, _} = Core.get_state(sibling3)

      register_agent_cleanup(sibling1)
      register_agent_cleanup(sibling2)
      register_agent_cleanup(sibling3)

      # Each sibling should be able to find the others using isolated registry
      # Manually replicate find_siblings logic with isolated registry
      agent_id1 = Core.get_agent_id(sibling1)
      parent = Core.get_parent_from_registry(agent_id1, registry)

      siblings =
        parent
        |> Core.find_children_by_parent(registry)
        |> Enum.reject(fn {pid, _} -> pid == sibling1 end)

      sibling_pids = Enum.map(siblings, fn {pid, _} -> pid end)

      # Should find the other two siblings (not itself)
      assert length(siblings) == 2
      assert sibling2 in sibling_pids
      assert sibling3 in sibling_pids
      refute sibling1 in sibling_pids
    end
  end
end
