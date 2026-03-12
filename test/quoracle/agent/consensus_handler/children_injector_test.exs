defmodule Quoracle.Agent.ConsensusHandler.ChildrenInjectorTest do
  @moduledoc """
  Unit tests for ChildrenInjector module.

  Tests formatting, injection, Registry filtering, edge case handling,
  and v2.0 message enrichment (latest_message_preview + latest_message_at).

  WorkGroupID: feat-20260309-185610
  Packet: 1 (Message Enrichment)

  Requirements tested:
  - R1-R8, R10-R11: Base injection behavior (v1.0)
  - R20-R28: Message enrichment (v2.0)
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

  # NEW v2.0 helper: create inbox message from a sender
  defp make_inbox_message(from, content, offset_seconds \\ 0) do
    %{
      from: from,
      content: content,
      timestamp: DateTime.add(~U[2025-12-27 02:00:00Z], offset_seconds, :second),
      read: false
    }
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

  defp register_child_with_parent(registry, child_id, parent_pid) do
    test_pid = self()

    pid =
      spawn(fn ->
        Registry.register(registry, {:agent, child_id}, %{
          pid: self(),
          parent_pid: parent_pid,
          registered_at: System.monotonic_time()
        })

        send(test_pid, {:registered, self()})

        receive do
          :stop -> :ok
        end
      end)

    receive do
      {:registered, ^pid} -> pid
    after
      1000 -> raise "Registry registration timeout for #{child_id}"
    end
  end

  defp make_parent_registry_with_children(parent_agent_id, child_ids) do
    registry = start_test_registry!()
    Registry.register(registry, {:agent, parent_agent_id}, %{pid: self()})

    child_pids =
      Enum.map(child_ids, fn child_id ->
        register_child_with_parent(registry, child_id, self())
      end)

    {registry, child_pids}
  end

  describe "R1: inject_children_context/2 with empty children" do
    test "injects empty children signal when children list empty" do
      state = %{children: [], registry: nil}
      messages = [make_message("Hello")]

      result = ChildrenInjector.inject_children_context(state, messages)

      content = hd(result).content
      assert content =~ "<children>No child agents running.</children>"
      assert content =~ "Hello"
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
      # v2.0: enriched children include latest_message_preview and latest_message_at
      children = [
        make_child("agent-abc123")
        |> Map.merge(%{latest_message_preview: nil, latest_message_at: nil})
      ]

      result = ChildrenInjector.format_children(children)

      assert result =~ "<children>"
      assert result =~ "</children>"
      assert result =~ "agent-abc123"
      # RFC 2822 format for LLM readability
      assert result =~ "Sat, 27 Dec 2025 01:00:00"
      # v2.0: null fields present
      assert result =~ ~s("latest_message_preview":null)
      assert result =~ ~s("latest_message_at":null)
    end

    test "formats multiple children with comma separation" do
      # v2.0: enriched children include latest_message_preview and latest_message_at
      children = [
        make_child("agent-1")
        |> Map.merge(%{latest_message_preview: nil, latest_message_at: nil}),
        make_child("agent-2", 60)
        |> Map.merge(%{latest_message_preview: nil, latest_message_at: nil})
      ]

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

  describe "R5: no truncation" do
    test "injects all children beyond the former 20-child limit" do
      children = for i <- 1..30, do: make_child("agent-#{i}", i)
      registry = make_live_registry(children)
      state = %{children: children, registry: registry, messages: []}
      messages = [make_message("Hello")]

      result = ChildrenInjector.inject_children_context(state, messages)
      content = hd(result).content

      assert length(Regex.scan(~r/"agent_id"/, content)) == 30
      assert content =~ "agent-21"
      assert content =~ "agent-30"
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

      state = %{children: children, registry: registry, messages: []}
      messages = [make_message("Hello")]

      result = ChildrenInjector.inject_children_context(state, messages)
      content = hd(result).content

      assert content =~ "agent-live"
      refute content =~ "agent-dead"
    end

    test "injects empty children signal when all children dead" do
      dead_child = make_child("agent-dead")
      children = [dead_child]

      # Registry has no agents registered
      registry = start_test_registry!()

      state = %{children: children, registry: registry, messages: []}
      messages = [make_message("Hello")]

      result = ChildrenInjector.inject_children_context(state, messages)

      content = hd(result).content
      assert content =~ "<children>No child agents running.</children>"
      refute content =~ "agent-dead"
    end
  end

  describe "R7: prepend to last message" do
    test "prepends children block to last message content" do
      children = [make_child("agent-1")]
      registry = make_live_registry(children)
      state = %{children: children, registry: registry, messages: []}
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
      state = %{children: children, registry: registry, messages: []}
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

  describe "R10: Registry error fallback" do
    test "handles Registry errors gracefully" do
      children = [make_child("agent-1")]
      # Invalid registry that will cause errors
      state = %{children: children, registry: :invalid_registry}
      messages = [make_message("Hello")]

      # Should not crash, should inject empty children signal
      result = ChildrenInjector.inject_children_context(state, messages)

      assert is_list(result)
      content = hd(result).content
      assert content =~ "<children>No child agents running.</children>"
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
        registry: registry,
        messages: []
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
      state = %{children: children, registry: registry, messages: []}
      messages = [%{role: "user", content: "Test", metadata: %{id: 123}}]

      result = ChildrenInjector.inject_children_context(state, messages)

      last_msg = hd(result)
      assert last_msg.role == "user"
      assert last_msg.metadata == %{id: 123}
    end
  end

  # ===========================================================================
  # R20-R28: Message Enrichment (v2.0)
  # ===========================================================================

  describe "R20-R28: message enrichment" do
    test "R20: child with messages shows preview and timestamp" do
      child = make_child("agent-1")
      registry = make_live_registry([child])
      inbox = [make_inbox_message("agent-1", "Here are the results")]

      state = %{children: [child], registry: registry, messages: inbox}
      messages = [make_message("Hello")]

      result = ChildrenInjector.inject_children_context(state, messages)
      content = hd(result).content

      assert content =~ "Here are the results"
      # latest_message_at in RFC 2822 format
      assert content =~ ~r/[A-Z][a-z]{2}, \d{2} [A-Z][a-z]{2} \d{4} \d{2}:\d{2}:\d{2}/
    end

    test "R21: child without messages shows null preview and timestamp" do
      child = make_child("agent-1")
      registry = make_live_registry([child])

      state = %{children: [child], registry: registry, messages: []}
      messages = [make_message("Hello")]

      result = ChildrenInjector.inject_children_context(state, messages)
      content = hd(result).content

      # JSON null values for both fields
      assert content =~ ~s("latest_message_preview":null)
      assert content =~ ~s("latest_message_at":null)
    end

    test "R22: preview truncated to 100 chars with ellipsis" do
      child = make_child("agent-1")
      registry = make_live_registry([child])
      long_content = String.duplicate("x", 150)
      inbox = [make_inbox_message("agent-1", long_content)]

      state = %{children: [child], registry: registry, messages: inbox}
      messages = [make_message("Hello")]

      result = ChildrenInjector.inject_children_context(state, messages)
      content = hd(result).content

      # Should contain 100 x's followed by ...
      assert content =~ String.duplicate("x", 100) <> "..."
      # Should NOT contain 101+ x's without the ellipsis (truncated)
      refute content =~ String.duplicate("x", 101)
    end

    test "R23: short messages are not truncated" do
      child = make_child("agent-1")
      registry = make_live_registry([child])
      short_content = "Done!"
      inbox = [make_inbox_message("agent-1", short_content)]

      state = %{children: [child], registry: registry, messages: inbox}
      messages = [make_message("Hello")]

      result = ChildrenInjector.inject_children_context(state, messages)
      content = hd(result).content

      assert content =~ "Done!"
      # No ellipsis appended
      refute content =~ "Done!..."
    end

    test "R24: multiple messages from same child picks most recent by timestamp" do
      child = make_child("agent-1")
      registry = make_live_registry([child])

      older_msg = make_inbox_message("agent-1", "First attempt", 0)
      newer_msg = make_inbox_message("agent-1", "Updated answer", 60)
      inbox = [older_msg, newer_msg]

      state = %{children: [child], registry: registry, messages: inbox}
      messages = [make_message("Hello")]

      result = ChildrenInjector.inject_children_context(state, messages)
      content = hd(result).content

      assert content =~ "Updated answer"
      refute content =~ "First attempt"
    end

    test "R25: messages from non-children are ignored" do
      child = make_child("agent-1")
      registry = make_live_registry([child])
      inbox = [make_inbox_message("agent-stranger", "I am not your child")]

      state = %{children: [child], registry: registry, messages: inbox}
      messages = [make_message("Hello")]

      result = ChildrenInjector.inject_children_context(state, messages)
      content = hd(result).content

      # child-1 should show null (no messages from it)
      assert content =~ ~s("latest_message_preview":null)
      # stranger's message should not appear
      refute content =~ "I am not your child"
    end

    test "R26: message timestamp uses RFC 2822 format" do
      child = make_child("agent-1")
      registry = make_live_registry([child])
      inbox = [make_inbox_message("agent-1", "Result")]

      state = %{children: [child], registry: registry, messages: inbox}
      messages = [make_message("Hello")]

      result = ChildrenInjector.inject_children_context(state, messages)
      content = hd(result).content

      # Extract both timestamps — they should use the same format
      # spawned_at: "Sat, 27 Dec 2025 01:00:00 +0000"
      # latest_message_at: "Sat, 27 Dec 2025 02:00:00 +0000"
      # Both match RFC 2822 pattern
      spawned_matches =
        Regex.scan(~r/\w{3}, \d{2} \w{3} \d{4} \d{2}:\d{2}:\d{2} \+0000/, content)

      assert length(spawned_matches) >= 2, "Both timestamps should be RFC 2822"
    end

    test "R27: empty inbox yields null fields for all children" do
      children = [make_child("agent-1"), make_child("agent-2", 10)]
      registry = make_live_registry(children)

      state = %{children: children, registry: registry, messages: []}
      messages = [make_message("Hello")]

      result = ChildrenInjector.inject_children_context(state, messages)
      content = hd(result).content

      # Both children should have null latest_message_preview
      null_count = length(Regex.scan(~r/"latest_message_preview":null/, content))
      assert null_count == 2
    end

    test "R28: mixed children show independent message status" do
      child_with_msg = make_child("agent-talker")
      child_without = make_child("agent-silent", 10)
      children = [child_with_msg, child_without]
      registry = make_live_registry(children)

      inbox = [make_inbox_message("agent-talker", "Here is my answer")]

      state = %{children: children, registry: registry, messages: inbox}
      messages = [make_message("Hello")]

      result = ChildrenInjector.inject_children_context(state, messages)
      content = hd(result).content

      # agent-talker should have a message
      assert content =~ "Here is my answer"
      # There should still be one null latest_message_preview (for agent-silent)
      assert content =~ ~s("latest_message_preview":null)
    end
  end

  describe "R30-R36: registry fallback" do
    test "R30: discovers children from Registry when state.children is empty" do
      parent_agent_id = "parent-r30-#{System.unique_integer([:positive])}"

      {registry, child_pids} =
        make_parent_registry_with_children(parent_agent_id, ["child-a", "child-b"])

      on_exit(fn -> for pid <- child_pids, do: Process.exit(pid, :kill) end)

      state = %{children: [], registry: registry, messages: [], agent_id: parent_agent_id}
      messages = [make_message("What should I do?")]

      result = ChildrenInjector.inject_children_context(state, messages)
      content = hd(result).content

      assert content =~ "<children>"
      assert content =~ "child-a"
      assert content =~ "child-b"
    end

    test "R32: Registry-only children have approximate spawned_at" do
      parent_agent_id = "parent-r32-#{System.unique_integer([:positive])}"
      {registry, child_pids} = make_parent_registry_with_children(parent_agent_id, ["child-new"])
      on_exit(fn -> for pid <- child_pids, do: Process.exit(pid, :kill) end)

      state = %{children: [], registry: registry, messages: [], agent_id: parent_agent_id}
      messages = [make_message("Hello")]

      result = ChildrenInjector.inject_children_context(state, messages)
      content = hd(result).content

      assert content =~ "child-new"

      current_year = Date.utc_today().year |> to_string()
      assert content =~ current_year
    end

    test "R31-R33: merges tracked children with Registry-only children without duplicates" do
      parent_agent_id = "parent-r33-#{System.unique_integer([:positive])}"

      {registry, child_pids} =
        make_parent_registry_with_children(parent_agent_id, ["child-known", "child-new"])

      on_exit(fn -> for pid <- child_pids, do: Process.exit(pid, :kill) end)

      known_time = ~U[2025-12-27 01:00:00Z]

      state = %{
        children: [%{agent_id: "child-known", spawned_at: known_time}],
        registry: registry,
        messages: [],
        agent_id: parent_agent_id
      }

      messages = [make_message("Hello")]

      result = ChildrenInjector.inject_children_context(state, messages)
      content = hd(result).content

      assert content =~ "child-known"
      assert content =~ "child-new"
      assert content =~ "27 Dec 2025"
      assert length(Regex.scan(~r/"child-known"/, content)) == 1
    end

    test "R34: invalid Registry causes graceful fallback to inject_empty_children" do
      state = %{
        children: [],
        registry: :not_a_real_registry,
        messages: [],
        agent_id: "error-test-agent"
      }

      messages = [make_message("Hello")]

      result = ChildrenInjector.inject_children_context(state, messages)
      content = hd(result).content

      assert content =~ "No child agents running"
    end

    test "R35: nil agent_id skips Registry discovery" do
      registry = start_test_registry!()

      state = %{
        children: [],
        registry: registry,
        messages: [],
        agent_id: nil
      }

      messages = [make_message("Hello")]

      result = ChildrenInjector.inject_children_context(state, messages)
      content = hd(result).content

      assert content =~ "No child agents running"
    end

    test "R36: Registry-discovered children are enriched with messages" do
      parent_agent_id = "parent-r36-#{System.unique_integer([:positive])}"
      {registry, child_pids} = make_parent_registry_with_children(parent_agent_id, ["child-x"])
      on_exit(fn -> for pid <- child_pids, do: Process.exit(pid, :kill) end)

      inbox = [make_inbox_message("child-x", "My results are ready")]

      state = %{children: [], registry: registry, messages: inbox, agent_id: parent_agent_id}
      messages = [make_message("Hello")]

      result = ChildrenInjector.inject_children_context(state, messages)
      content = hd(result).content

      assert content =~ "child-x"
      assert content =~ "My results are ready"
    end
  end
end
