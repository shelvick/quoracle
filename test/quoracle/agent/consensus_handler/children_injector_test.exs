defmodule Quoracle.Agent.ConsensusHandler.ChildrenInjectorTest do
  @moduledoc """
  Unit tests for ChildrenInjector module.

  Tests formatting, injection, Registry filtering, and edge case handling.

  WorkGroupID: feat-20251227-children-inject
  Packet: 2 (Injection Logic)
  """
  use ExUnit.Case, async: true

  alias Quoracle.Agent.ConsensusHandler.ChildrenInjector

  # Test helpers
  defp make_child(id, offset_seconds \\ 0) do
    %{
      agent_id: id,
      spawned_at: DateTime.add(~U[2025-12-27 01:00:00Z], offset_seconds, :second)
    }
  end

  defp make_message(content) do
    %{role: "user", content: content}
  end

  defp start_test_registry! do
    name = :"test_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: name})
    name
  end

  defp register_agent(registry, agent_id) do
    Registry.register(registry, {:agent, agent_id}, %{pid: self()})
  end

  defp make_live_registry(children) do
    registry = start_test_registry!()
    for child <- children, do: register_agent(registry, child.agent_id)
    registry
  end

  describe "R1: inject_children_context/2 with empty children" do
    test "returns messages unchanged when children list empty" do
      state = %{children: [], registry: nil}
      messages = [make_message("Hello")]

      result = ChildrenInjector.inject_children_context(state, messages)

      assert result == messages
    end
  end

  describe "R2: inject_children_context/2 with empty messages" do
    test "returns empty list when messages empty" do
      child = make_child("agent-1")
      registry = make_live_registry([child])
      state = %{children: [child], registry: registry}

      result = ChildrenInjector.inject_children_context(state, [])

      assert result == []
    end
  end

  describe "R3-R4: format_children/1" do
    test "formats single child as JSON in children wrapper" do
      children = [make_child("agent-abc123")]

      result = ChildrenInjector.format_children(children)

      assert result =~ "<children>"
      assert result =~ "</children>"
      assert result =~ "agent-abc123"
      # RFC 2822 format for LLM readability
      assert result =~ "Sat, 27 Dec 2025 01:00:00"
      assert result =~ "active"
    end

    test "formats multiple children with comma separation" do
      children = [make_child("agent-1"), make_child("agent-2", 60)]

      result = ChildrenInjector.format_children(children)

      assert result =~ "agent-1"
      assert result =~ "agent-2"
      # JSON objects separated by comma and newline
      assert result =~ "},\n{"
    end

    test "handles empty children list" do
      result = ChildrenInjector.format_children([])

      assert result == "<children>\n</children>"
    end
  end

  describe "R5: 20 children limit" do
    test "limits injection to 20 children" do
      children = for i <- 1..25, do: make_child("agent-#{i}", i)
      registry = make_live_registry(children)
      state = %{children: children, registry: registry}
      messages = [make_message("Hello")]

      result = ChildrenInjector.inject_children_context(state, messages)
      content = hd(result).content

      # Should have exactly 20 agent entries
      assert length(Regex.scan(~r/"agent_id"/, content)) == 20
      # Should have agent-1 through agent-20, not agent-21+
      assert content =~ "agent-1"
      assert content =~ "agent-20"
      refute content =~ "agent-21"
    end
  end

  describe "R6: filter dead children" do
    test "excludes children not found in Registry" do
      live_child = make_child("agent-live")
      dead_child = make_child("agent-dead")
      children = [live_child, dead_child]

      # Registry only contains live_child
      registry = start_test_registry!()
      register_agent(registry, "agent-live")

      state = %{children: children, registry: registry}
      messages = [make_message("Hello")]

      result = ChildrenInjector.inject_children_context(state, messages)
      content = hd(result).content

      assert content =~ "agent-live"
      refute content =~ "agent-dead"
    end

    test "returns messages unchanged when all children dead" do
      dead_child = make_child("agent-dead")
      children = [dead_child]

      # Registry has no agents registered
      registry = start_test_registry!()

      state = %{children: children, registry: registry}
      messages = [make_message("Hello")]

      result = ChildrenInjector.inject_children_context(state, messages)

      # Messages unchanged since no live children
      assert result == messages
    end
  end

  describe "R7: prepend to last message" do
    test "prepends children block to last message content" do
      children = [make_child("agent-1")]
      registry = make_live_registry(children)
      state = %{children: children, registry: registry}
      messages = [make_message("First"), make_message("Last")]

      result = ChildrenInjector.inject_children_context(state, messages)

      # First message unchanged
      assert Enum.at(result, 0).content == "First"
      # Last message has children prepended
      last_content = Enum.at(result, 1).content
      assert String.starts_with?(last_content, "<children>")
      assert last_content =~ "Last"
    end

    test "handles single message correctly" do
      children = [make_child("agent-1")]
      registry = make_live_registry(children)
      state = %{children: children, registry: registry}
      messages = [make_message("Only message")]

      result = ChildrenInjector.inject_children_context(state, messages)

      assert length(result) == 1
      assert hd(result).content =~ "<children>"
      assert hd(result).content =~ "Only message"
    end
  end

  describe "R8: DateTime RFC 2822 format" do
    test "formats spawned_at as RFC 2822 for LLM readability" do
      children = [make_child("agent-1")]

      result = ChildrenInjector.format_children(children)

      # RFC 2822 format: "Sat, 27 Dec 2025 01:00:00 +0000"
      assert result =~ ~r/[A-Z][a-z]{2}, \d{2} [A-Z][a-z]{2} \d{4} \d{2}:\d{2}:\d{2}/
    end
  end

  describe "R9: status always active" do
    test "live children have status active" do
      children = [make_child("agent-1")]

      result = ChildrenInjector.format_children(children)

      assert result =~ ~s("status":"active")
    end
  end

  describe "R10: Registry error fallback" do
    test "handles Registry errors gracefully" do
      children = [make_child("agent-1")]
      # Invalid registry that will cause errors
      state = %{children: children, registry: :invalid_registry}
      messages = [make_message("Hello")]

      # Should not crash, should return messages unchanged (no live children)
      result = ChildrenInjector.inject_children_context(state, messages)

      assert is_list(result)
      # Messages should be unchanged since registry lookup fails
      assert result == messages
    end

    test "handles nil registry gracefully" do
      children = [make_child("agent-1")]
      state = %{children: children, registry: nil}
      messages = [make_message("Hello")]

      result = ChildrenInjector.inject_children_context(state, messages)

      assert is_list(result)
    end
  end

  describe "R11: injection order (after todos)" do
    test "children block appears after todos block in message" do
      # Simulate the call order: todos first, then children
      # TodoInjector runs first, then ChildrenInjector
      # Both prepend to last message, so children should appear before todos

      alias Quoracle.Agent.ConsensusHandler.TodoInjector

      children = [make_child("agent-1")]
      registry = make_live_registry(children)
      todos = [%{content: "Task 1", state: :todo}]

      state = %{
        children: children,
        todos: todos,
        registry: registry
      }

      messages = [make_message("Original")]

      # Call order: todos first, then children (matching production code)
      messages_with_todos = TodoInjector.inject_todo_context(state, messages)
      result = ChildrenInjector.inject_children_context(state, messages_with_todos)

      content = hd(result).content

      # Children should appear before todos (prepended second)
      children_pos = :binary.match(content, "<children>") |> elem(0)
      todos_pos = :binary.match(content, "<todos>") |> elem(0)

      assert children_pos < todos_pos
    end
  end

  describe "preserves message properties" do
    test "preserves other message properties" do
      children = [make_child("agent-1")]
      registry = make_live_registry(children)
      state = %{children: children, registry: registry}
      messages = [%{role: "user", content: "Test", metadata: %{id: 123}}]

      result = ChildrenInjector.inject_children_context(state, messages)

      last_msg = hd(result)
      assert last_msg.role == "user"
      assert last_msg.metadata == %{id: 123}
    end
  end
end
