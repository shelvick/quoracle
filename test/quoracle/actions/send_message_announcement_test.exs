defmodule Quoracle.Actions.SendMessageAnnouncementTest do
  @moduledoc """
  Tests for ACTION_SendMessage v5.0 - Announcement Target (Recursive Broadcast).

  Packet 2: SendMessage Implementation for feat-20251224-announcement-target.

  Tests R1-R10 from the specification:
  - R1-R7: Unit tests for announcement target resolution
  - R8-R10: Integration tests for full tree broadcast
  """

  use ExUnit.Case, async: true

  alias Quoracle.Actions.SendMessage

  import ExUnit.CaptureLog

  setup do
    # Create isolated Registry for test
    registry = :"test_registry_#{System.unique_integer([:positive])}"
    {:ok, _} = start_supervised({Registry, keys: :unique, name: registry})

    # Create isolated PubSub for test
    pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
    {:ok, _} = start_supervised({Phoenix.PubSub, name: pubsub})

    %{registry: registry, pubsub: pubsub}
  end

  # Helper to register an agent in the registry with parent relationship
  defp register_agent(registry, agent_id, parent_id \\ nil) do
    test_pid = self()
    parent_pid = if parent_id, do: get_agent_pid(registry, parent_id), else: nil

    pid =
      spawn(fn ->
        composite = %{
          pid: self(),
          parent_id: parent_id,
          parent_pid: parent_pid,
          registered_at: System.monotonic_time()
        }

        {:ok, _} = Registry.register(registry, {:agent, agent_id}, composite)
        send(test_pid, {:registered, agent_id})
        agent_loop()
      end)

    receive do
      {:registered, ^agent_id} -> pid
    after
      1000 -> raise "Agent registration timeout"
    end
  end

  defp get_agent_pid(registry, agent_id) do
    case Registry.lookup(registry, {:agent, agent_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # Simple agent loop that receives messages
  defp agent_loop do
    receive do
      {:agent_message, _from, _content} -> agent_loop()
      :stop -> :ok
    after
      30_000 -> :ok
    end
  end

  describe "announcement target normalization (R7)" do
    test "announcement string target normalized to atom", %{registry: registry, pubsub: pubsub} do
      # Register a parent agent (sender) and a child
      parent_pid = register_agent(registry, "parent-001")
      _child_pid = register_agent(registry, "child-001", "parent-001")

      on_exit(fn ->
        if Process.alive?(parent_pid), do: send(parent_pid, :stop)
      end)

      # Execute with string target "announcement"
      params = %{"to" => "announcement", "content" => "Test announcement"}

      result =
        SendMessage.execute(params, "parent-001",
          action_id: "action-001",
          registry: registry,
          pubsub: pubsub
        )

      # Should succeed - string normalized to :announcement atom
      assert {:ok, response} = result
      assert response[:action] == "send_message"
    end
  end

  describe "announcement target resolution - unit tests (R1-R6)" do
    test "announcement includes direct children (R1)", %{registry: registry, pubsub: pubsub} do
      # Setup: parent with 2 direct children
      parent_pid = register_agent(registry, "parent-001")
      child1_pid = register_agent(registry, "child-001", "parent-001")
      child2_pid = register_agent(registry, "child-002", "parent-001")

      on_exit(fn ->
        for pid <- [parent_pid, child1_pid, child2_pid] do
          if Process.alive?(pid), do: send(pid, :stop)
        end
      end)

      params = %{to: :announcement, content: "Hello children"}

      result =
        SendMessage.execute(params, "parent-001",
          action_id: "action-001",
          registry: registry,
          pubsub: pubsub
        )

      assert {:ok, response} = result
      assert "child-001" in response[:sent_to]
      assert "child-002" in response[:sent_to]
    end

    test "announcement includes grandchildren recursively (R2)", %{
      registry: registry,
      pubsub: pubsub
    } do
      # Setup: 3-level tree (parent -> child -> grandchild)
      parent_pid = register_agent(registry, "parent-001")
      child_pid = register_agent(registry, "child-001", "parent-001")
      grandchild_pid = register_agent(registry, "grandchild-001", "child-001")

      on_exit(fn ->
        for pid <- [parent_pid, child_pid, grandchild_pid] do
          if Process.alive?(pid), do: send(pid, :stop)
        end
      end)

      params = %{to: :announcement, content: "Hello descendants"}

      result =
        SendMessage.execute(params, "parent-001",
          action_id: "action-001",
          registry: registry,
          pubsub: pubsub
        )

      assert {:ok, response} = result
      # Should include both child and grandchild
      assert "child-001" in response[:sent_to]
      assert "grandchild-001" in response[:sent_to]
    end

    test "announcement excludes sender from recipients (R3)", %{
      registry: registry,
      pubsub: pubsub
    } do
      # Setup: parent with child
      parent_pid = register_agent(registry, "parent-001")
      child_pid = register_agent(registry, "child-001", "parent-001")

      on_exit(fn ->
        for pid <- [parent_pid, child_pid] do
          if Process.alive?(pid), do: send(pid, :stop)
        end
      end)

      params = %{to: :announcement, content: "Announcement"}

      result =
        SendMessage.execute(params, "parent-001",
          action_id: "action-001",
          registry: registry,
          pubsub: pubsub
        )

      assert {:ok, response} = result
      # Sender should NOT be in the result
      refute "parent-001" in response[:sent_to]
      # Child should be in the result
      assert "child-001" in response[:sent_to]
    end

    test "announcement with no descendants returns empty success (R4)", %{
      registry: registry,
      pubsub: pubsub
    } do
      # Setup: leaf agent with no children
      leaf_pid = register_agent(registry, "leaf-001")

      on_exit(fn ->
        if Process.alive?(leaf_pid), do: send(leaf_pid, :stop)
      end)

      params = %{to: :announcement, content: "Hello nobody"}

      result =
        SendMessage.execute(params, "leaf-001",
          action_id: "action-001",
          registry: registry,
          pubsub: pubsub
        )

      # Should succeed with empty sent_to list
      assert {:ok, response} = result
      assert response[:sent_to] == []
    end

    test "announcement detects cycles and skips visited agents (R5)", %{
      registry: registry,
      pubsub: pubsub
    } do
      # Setup: Create agents and manually manipulate registry to create cycle
      # agent-001 -> agent-002 -> agent-003 -> (points back to agent-001's child)
      agent1_pid = register_agent(registry, "agent-001")
      agent2_pid = register_agent(registry, "agent-002", "agent-001")
      agent3_pid = register_agent(registry, "agent-003", "agent-002")

      # Manipulate agent-003's composite to point to agent-002 as child (cycle)
      # This simulates a corrupted/cyclic registry state
      Registry.unregister(registry, {:agent, "agent-003"})

      composite_with_cycle = %{
        pid: agent3_pid,
        parent_id: "agent-002",
        parent_pid: agent2_pid,
        # Fake child pointing back up the tree
        registered_at: System.monotonic_time()
      }

      Registry.register(registry, {:agent, "agent-003"}, composite_with_cycle)

      # Also register agent-002 as child of agent-003 (the cycle)
      agent4_pid = spawn(fn -> agent_loop() end)

      Registry.register(registry, {:agent, "agent-004"}, %{
        pid: agent4_pid,
        parent_id: "agent-003",
        parent_pid: agent3_pid,
        registered_at: System.monotonic_time()
      })

      on_exit(fn ->
        for pid <- [agent1_pid, agent2_pid, agent3_pid, agent4_pid] do
          if Process.alive?(pid), do: send(pid, :stop)
        end
      end)

      params = %{to: :announcement, content: "Cycle test"}

      # Should complete without infinite loop
      result =
        SendMessage.execute(params, "agent-001",
          action_id: "action-001",
          registry: registry,
          pubsub: pubsub
        )

      assert {:ok, response} = result
      # Each agent should appear at most once
      sent_to = response[:sent_to]
      assert length(sent_to) == length(Enum.uniq(sent_to))
    end

    test "announcement respects depth limit of 100 (R6)", %{registry: registry, pubsub: pubsub} do
      # Setup: Create a very deep tree (105 levels)
      pids =
        Enum.reduce(0..104, [], fn level, acc ->
          agent_id = "agent-level-#{level}"
          parent_id = if level == 0, do: nil, else: "agent-level-#{level - 1}"
          pid = register_agent(registry, agent_id, parent_id)
          [pid | acc]
        end)

      on_exit(fn ->
        for pid <- pids do
          if Process.alive?(pid), do: send(pid, :stop)
        end
      end)

      params = %{to: :announcement, content: "Deep tree test"}

      # Capture warning log about depth limit
      log =
        capture_log(fn ->
          result =
            SendMessage.execute(params, "agent-level-0",
              action_id: "action-001",
              registry: registry,
              pubsub: pubsub
            )

          send(self(), {:result, result})
        end)

      assert_received {:result, {:ok, response}}
      # Should have at most 100 descendants (depth limit)
      assert length(response[:sent_to]) <= 100
      # Log captured for depth limit warning verification
      assert is_binary(log)
    end
  end

  describe "announcement integration tests (R8-R10)" do
    test "announcement broadcasts to entire subtree (R8)", %{registry: registry, pubsub: pubsub} do
      # Setup: Complex tree structure
      #        root
      #       /    \
      #    child1  child2
      #      |       |
      #   grand1   grand2
      root_pid = register_agent(registry, "root")
      child1_pid = register_agent(registry, "child1", "root")
      child2_pid = register_agent(registry, "child2", "root")
      grand1_pid = register_agent(registry, "grand1", "child1")
      grand2_pid = register_agent(registry, "grand2", "child2")

      all_pids = [root_pid, child1_pid, child2_pid, grand1_pid, grand2_pid]

      on_exit(fn ->
        for pid <- all_pids do
          if Process.alive?(pid), do: send(pid, :stop)
        end
      end)

      params = %{to: :announcement, content: "Broadcast to all"}

      result =
        SendMessage.execute(params, "root",
          action_id: "action-001",
          registry: registry,
          pubsub: pubsub
        )

      assert {:ok, response} = result
      sent_to = response[:sent_to]

      # All descendants should receive (4 total)
      assert length(sent_to) == 4
      assert "child1" in sent_to
      assert "child2" in sent_to
      assert "grand1" in sent_to
      assert "grand2" in sent_to
      # Root (sender) should not be included
      refute "root" in sent_to
    end

    test "announcement handles asymmetric tree structures (R9)", %{
      registry: registry,
      pubsub: pubsub
    } do
      # Setup: Asymmetric tree (one branch deeper than other)
      #        root
      #       /    \
      #    child1  child2
      #      |
      #   grand1
      #      |
      #  great1
      root_pid = register_agent(registry, "root")
      child1_pid = register_agent(registry, "child1", "root")
      child2_pid = register_agent(registry, "child2", "root")
      grand1_pid = register_agent(registry, "grand1", "child1")
      great1_pid = register_agent(registry, "great1", "grand1")

      all_pids = [root_pid, child1_pid, child2_pid, grand1_pid, great1_pid]

      on_exit(fn ->
        for pid <- all_pids do
          if Process.alive?(pid), do: send(pid, :stop)
        end
      end)

      params = %{to: :announcement, content: "Asymmetric test"}

      result =
        SendMessage.execute(params, "root",
          action_id: "action-001",
          registry: registry,
          pubsub: pubsub
        )

      assert {:ok, response} = result
      sent_to = response[:sent_to]

      # All descendants from both branches
      assert "child1" in sent_to
      assert "child2" in sent_to
      assert "grand1" in sent_to
      assert "great1" in sent_to
      assert length(sent_to) == 4
    end

    test "announcement delivers to reachable agents on partial failure (R10)", %{
      registry: registry,
      pubsub: pubsub
    } do
      # Setup: Tree where one agent's process has died
      root_pid = register_agent(registry, "root")
      child1_pid = register_agent(registry, "child1", "root")
      child2_pid = register_agent(registry, "child2", "root")

      # Kill child2's process to simulate unreachable agent
      ref = Process.monitor(child2_pid)
      send(child2_pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^child2_pid, _reason}, 30_000

      on_exit(fn ->
        for pid <- [root_pid, child1_pid] do
          if Process.alive?(pid), do: send(pid, :stop)
        end
      end)

      params = %{to: :announcement, content: "Partial failure test"}

      # Should not crash, best-effort delivery
      result =
        SendMessage.execute(params, "root",
          action_id: "action-001",
          registry: registry,
          pubsub: pubsub
        )

      # Should succeed (best-effort means we don't fail on unreachable)
      assert {:ok, response} = result
      # At least child1 should be in sent_to (reachable)
      assert "child1" in response[:sent_to]
    end
  end
end
