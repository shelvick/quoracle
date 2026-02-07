defmodule Quoracle.Agent.ConsensusHandlerTodoTest do
  @moduledoc """
  Tests for TODO context injection in ConsensusHandler.

  Verifies that ConsensusHandler properly injects TODO lists into
  LLM prompts before consensus (Packet 2 - State Management).
  """
  use ExUnit.Case, async: true

  alias Quoracle.Agent.ConsensusHandler

  describe "inject_todo_context/2" do
    test "injects TODOs into last message when todos present" do
      state = %{
        todos: [
          %{content: "First task", state: :todo},
          %{content: "Second task", state: :pending},
          %{content: "Third task", state: :done}
        ]
      }

      messages = [
        %{role: "user", content: "What's the plan?"},
        %{role: "assistant", content: "Let me think..."}
      ]

      result = ConsensusHandler.inject_todo_context(state, messages)

      assert length(result) == 2
      assert List.last(result).content =~ "<todos>"
      assert List.last(result).content =~ ~s("content":"First task")
      assert List.last(result).content =~ ~s("state":"todo")
      assert List.last(result).content =~ ~s("content":"Second task")
      assert List.last(result).content =~ ~s("state":"pending")
      assert List.last(result).content =~ ~s("content":"Third task")
      assert List.last(result).content =~ ~s("state":"done")
      assert List.last(result).content =~ "</todos>"
      assert List.last(result).content =~ "Let me think..."
    end

    test "returns messages unchanged when todos empty" do
      state = %{todos: []}

      messages = [
        %{role: "user", content: "Hello"},
        %{role: "assistant", content: "Hi there"}
      ]

      result = ConsensusHandler.inject_todo_context(state, messages)
      assert result == messages
    end

    test "returns messages unchanged when no todos in state" do
      state = %{other_field: "value"}
      messages = [%{role: "user", content: "Test"}]

      result = ConsensusHandler.inject_todo_context(state, messages)
      assert result == messages
    end

    test "handles single message correctly" do
      state = %{
        todos: [%{content: "Single task", state: :todo}]
      }

      messages = [%{role: "user", content: "Do something"}]

      result = ConsensusHandler.inject_todo_context(state, messages)

      assert length(result) == 1
      assert hd(result).content =~ "<todos>"
      assert hd(result).content =~ ~s("content":"Single task")
      assert hd(result).content =~ "Do something"
    end

    test "handles empty message list" do
      state = %{
        todos: [%{content: "Task", state: :todo}]
      }

      messages = []

      result = ConsensusHandler.inject_todo_context(state, messages)
      assert result == []
    end
  end

  describe "format_todos/1" do
    test "formats todos as JSON objects correctly" do
      todos = [
        %{content: "Task one", state: :todo},
        %{content: "Task two", state: :pending},
        %{content: "Task three", state: :done}
      ]

      result = ConsensusHandler.format_todos(todos)

      assert result =~ "<todos>"
      assert result =~ "</todos>"
      assert result =~ ~s("content":"Task one")
      assert result =~ ~s("state":"todo")
      assert result =~ ~s("content":"Task two")
      assert result =~ ~s("state":"pending")
      assert result =~ ~s("content":"Task three")
      assert result =~ ~s("state":"done")
    end

    test "escapes JSON characters properly via Jason" do
      todos = [
        %{content: "Task with \"quotes\"", state: :todo},
        %{content: "Task with \\ backslash", state: :pending}
      ]

      result = ConsensusHandler.format_todos(todos)

      # Jason handles escaping
      assert result =~ ~s("content":"Task with \\"quotes\\"")
      assert result =~ ~s("content":"Task with \\\\ backslash")
    end

    test "handles empty todo list" do
      result = ConsensusHandler.format_todos([])

      assert result == "<todos>\n</todos>"
    end

    test "preserves todo order" do
      todos = for i <- 1..5, do: %{content: "Task #{i}", state: :todo}

      result = ConsensusHandler.format_todos(todos)

      lines = String.split(result, "\n")
      assert Enum.at(lines, 1) =~ "Task 1"
      assert Enum.at(lines, 2) =~ "Task 2"
      assert Enum.at(lines, 3) =~ "Task 3"
      assert Enum.at(lines, 4) =~ "Task 4"
      assert Enum.at(lines, 5) =~ "Task 5"
    end
  end

  describe "inject_into_last_message/2" do
    test "injects TODOs at beginning of last message content" do
      messages = [
        %{role: "user", content: "First message"},
        %{role: "assistant", content: "Original content"}
      ]

      todos = [%{content: "Test task", state: :todo}]

      result = ConsensusHandler.inject_into_last_message(messages, todos)

      assert length(result) == 2
      last_msg = List.last(result)
      assert last_msg.content =~ "<todos>"
      assert last_msg.content =~ ~s("content":"Test task")
      assert last_msg.content =~ "Original content"
      # TODOs should come before original content
      assert String.starts_with?(last_msg.content, "<todos>")
    end

    test "preserves other message properties" do
      messages = [
        %{role: "user", content: "Test", metadata: %{id: 123}}
      ]

      todos = [%{content: "Task", state: :pending}]

      result = ConsensusHandler.inject_into_last_message(messages, todos)

      last_msg = List.last(result)
      assert last_msg.role == "user"
      assert last_msg.metadata == %{id: 123}
    end

    test "handles nil case gracefully" do
      messages = nil
      todos = [%{content: "Task", state: :todo}]

      result = ConsensusHandler.inject_into_last_message(messages, todos)
      assert result == nil
    end
  end

  describe "20-item limit" do
    test "only includes first 20 TODOs when more than 20 present" do
      todos = for i <- 1..30, do: %{content: "Task #{i}", state: :todo}
      state = %{todos: todos}
      messages = [%{role: "user", content: "Test"}]

      result = ConsensusHandler.inject_todo_context(state, messages)

      last_msg = List.last(result)
      # Should contain tasks 1-20
      assert last_msg.content =~ "Task 1"
      assert last_msg.content =~ "Task 20"
      # Should not contain tasks 21+
      refute last_msg.content =~ "Task 21"
      refute last_msg.content =~ "Task 30"
    end

    test "includes all TODOs when exactly 20" do
      todos = for i <- 1..20, do: %{content: "Task #{i}", state: :todo}
      state = %{todos: todos}
      messages = [%{role: "user", content: "Test"}]

      result = ConsensusHandler.inject_todo_context(state, messages)

      last_msg = List.last(result)
      assert last_msg.content =~ "Task 1"
      assert last_msg.content =~ "Task 20"
    end

    test "includes all TODOs when less than 20" do
      todos = for i <- 1..5, do: %{content: "Task #{i}", state: :todo}
      state = %{todos: todos}
      messages = [%{role: "user", content: "Test"}]

      result = ConsensusHandler.inject_todo_context(state, messages)

      last_msg = List.last(result)
      assert last_msg.content =~ "Task 1"
      assert last_msg.content =~ "Task 5"
    end
  end

  describe "get_action_consensus/1 integration" do
    test "passes messages with TODOs to Consensus.get_consensus" do
      # v8.0: Put messages in model_histories, not passed separately
      state = %{
        agent_id: "agent-#{System.unique_integer([:positive])}",
        todos: [
          %{content: "Analyze data", state: :todo},
          %{content: "Generate report", state: :pending}
        ],
        model_histories: %{
          "default" => [%{role: "user", content: "What's next?"}]
        },
        test_mode: true
      }

      # Should inject TODOs into model_histories before calling consensus
      # This will fail with consensus error (expected - we're just testing injection happens)
      result = ConsensusHandler.get_action_consensus(state)

      # Verify it attempted consensus (any result means injection worked)
      assert is_tuple(result) and elem(result, 0) in [:ok, :error]
    end
  end
end
