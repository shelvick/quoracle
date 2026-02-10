defmodule Quoracle.Agent.Consensus.PerModelQueryAceInjectorTest do
  @moduledoc """
  Tests for PerModelQuery v13.0 - ACE injector integration.

  Verifies that AceInjector is called during per-model consensus queries
  to inject ACE context into the first user message.

  WorkGroupID: wip-20260104-ace-injector
  Packet: 1 (ACE Injector)

  ARC Verification Criteria: R61-R64
  """
  use Quoracle.DataCase, async: true

  alias Quoracle.Agent.Consensus.PerModelQuery
  alias Quoracle.Agent.ConsensusHandler.AceInjector

  # ========== TEST HELPERS ==========

  defp make_lesson(content, type \\ :factual, confidence \\ 0.8) do
    %{content: content, type: type, confidence: confidence}
  end

  defp make_model_state(summary) do
    %{summary: summary}
  end

  defp make_history_entry(type, content) do
    %{type: type, content: content, timestamp: DateTime.utc_now()}
  end

  defp make_state_with_ace(model_id, lessons, model_state \\ nil) do
    %{
      agent_id: "test-agent-#{System.unique_integer([:positive])}",
      task_id: "test-task",
      model_histories: %{
        model_id => [
          make_history_entry(:user, "Initial user message"),
          make_history_entry(:assistant, "Initial response")
        ]
      },
      context_lessons: if(lessons, do: %{model_id => lessons}, else: %{}),
      model_states: if(model_state, do: %{model_id => model_state}, else: %{}),
      todos: [],
      children: [],
      budget_data: nil
    }
  end

  # ========== R61: ACE INJECTOR CALLED ==========

  describe "R61: AceInjector called during query" do
    test "query_single_model_with_retry injects ACE into messages sent to LLM" do
      # This test verifies the ACTUAL code path in PerModelQuery
      # by capturing the messages sent to the LLM via injectable model_query_fn
      model_id = "test-model"
      lessons = [make_lesson("ACE lesson from condensation")]
      state = make_state_with_ace(model_id, lessons)

      # Capture messages sent to LLM
      test_pid = self()

      mock_query_fn = fn messages, _models, _opts ->
        # Send captured messages back to test process
        send(test_pid, {:captured_messages, messages})

        # Return mock successful response
        {:ok,
         %{
           successful_responses: [
             %{model: model_id, content: ~s({"action": "orient", "params": {}, "wait": false})}
           ],
           failed_models: []
         }}
      end

      opts = [
        model_query_fn: mock_query_fn,
        round: 1
      ]

      # Call actual PerModelQuery function
      {:ok, _response, _state} =
        PerModelQuery.query_single_model_with_retry(state, model_id, opts)

      # Verify ACE content appears in captured messages
      assert_receive {:captured_messages, messages}, 30_000

      all_content = Enum.map_join(messages, " ", & &1.content)

      # R61: ACE should be injected into messages
      assert all_content =~ "<lessons>",
             "ACE lessons should be injected into messages sent to LLM"

      assert all_content =~ "ACE lesson from condensation"
    end

    test "query_single_model_with_retry injects model state into messages" do
      model_id = "test-model"
      model_state = make_model_state("Task is 75% complete")
      state = make_state_with_ace(model_id, [], model_state)

      test_pid = self()

      mock_query_fn = fn messages, _models, _opts ->
        send(test_pid, {:captured_messages, messages})

        {:ok,
         %{
           successful_responses: [
             %{model: model_id, content: ~s({"action": "orient", "params": {}, "wait": false})}
           ],
           failed_models: []
         }}
      end

      opts = [model_query_fn: mock_query_fn, round: 1]

      {:ok, _response, _state} =
        PerModelQuery.query_single_model_with_retry(state, model_id, opts)

      assert_receive {:captured_messages, messages}, 30_000
      all_content = Enum.map_join(messages, " ", & &1.content)

      # R61: Model state should be injected
      assert all_content =~ "<state>", "Model state should be injected into messages"
      assert all_content =~ "Task is 75% complete"
    end

    test "AceInjector.inject_ace_context callable directly" do
      # Unit test for isolated AceInjector behavior
      state = make_state_with_ace("test-model", [make_lesson("Test lesson")])
      messages = [%{role: "user", content: "Test"}]

      result = AceInjector.inject_ace_context(state, messages, "test-model")
      assert is_list(result)
    end
  end

  # ========== R62: ACE INJECTED BEFORE TODOS ==========

  describe "R62: ACE in first message, todos in last" do
    test "ACE appears in first user message, not last" do
      model_id = "test-model"
      lessons = [make_lesson("Historical knowledge")]

      state =
        make_state_with_ace(model_id, lessons)
        |> Map.put(:todos, [%{content: "Current task", state: :todo}])

      # Build messages as PerModelQuery would
      messages = build_messages_with_injections(state, model_id)

      # Find first user message
      first_user_idx = Enum.find_index(messages, &(&1.role == "user"))
      assert first_user_idx != nil

      first_user = Enum.at(messages, first_user_idx)

      # First user message should have ACE content
      assert first_user.content =~ "<lessons>"
      assert first_user.content =~ "Historical knowledge"

      # Last message should have todos
      last = Enum.at(messages, -1)
      assert last.content =~ "<todos>"

      # If first user != last, ACE should only be in first user message
      # If first user == last (single user message), both are in same message
      if first_user.content != last.content do
        refute last.content =~ "<lessons>", "ACE should not be in last message"
      end
    end

    test "injection order correct with multiple messages" do
      model_id = "test-model"
      lessons = [make_lesson("Lesson content")]

      state =
        make_state_with_ace(model_id, lessons)
        |> Map.put(:model_histories, %{
          model_id => [
            make_history_entry(:user, "First user"),
            make_history_entry(:assistant, "First response"),
            make_history_entry(:user, "Second user"),
            make_history_entry(:assistant, "Second response"),
            make_history_entry(:user, "Third user")
          ]
        })
        |> Map.put(:todos, [%{content: "Task", state: :todo}])

      messages = build_messages_with_injections(state, model_id)

      # First user message has ACE
      first_user = Enum.find(messages, &(&1.role == "user"))
      assert first_user.content =~ "<lessons>"

      # Last message has todos
      last = Enum.at(messages, -1)
      assert last.content =~ "<todos>"

      # They should be in different messages
      first_user_content = first_user.content
      last_content = last.content

      # If first == last, both should be present
      if first_user_content == last_content do
        assert first_user_content =~ "<lessons>"
        assert first_user_content =~ "<todos>"
      else
        # Otherwise, ACE only in first, todos only in last
        refute last_content =~ "<lessons>"
      end
    end
  end

  # ========== R63: MODEL-SPECIFIC ACE ==========

  describe "R63: each model receives its own lessons" do
    test "model A gets only model A lessons" do
      model_a = "anthropic:claude-sonnet-4"
      model_b = "google:gemini-2.0-flash"

      state = %{
        agent_id: "test-agent",
        task_id: "test-task",
        model_histories: %{
          model_a => [make_history_entry(:user, "Hello from A")],
          model_b => [make_history_entry(:user, "Hello from B")]
        },
        context_lessons: %{
          model_a => [make_lesson("Lesson for A")],
          model_b => [make_lesson("Lesson for B")]
        },
        model_states: %{},
        todos: [],
        children: [],
        budget_data: nil
      }

      messages_a = build_messages_with_injections(state, model_a)
      messages_b = build_messages_with_injections(state, model_b)

      # Model A should see only its lessons
      content_a = Enum.map_join(messages_a, " ", & &1.content)
      assert content_a =~ "Lesson for A"
      refute content_a =~ "Lesson for B"

      # Model B should see only its lessons
      content_b = Enum.map_join(messages_b, " ", & &1.content)
      assert content_b =~ "Lesson for B"
      refute content_b =~ "Lesson for A"
    end

    test "model-specific state also isolated" do
      model_a = "model-a"
      model_b = "model-b"

      state = %{
        agent_id: "test-agent",
        task_id: "test-task",
        model_histories: %{
          model_a => [make_history_entry(:user, "Hello")],
          model_b => [make_history_entry(:user, "Hello")]
        },
        context_lessons: %{},
        model_states: %{
          model_a => make_model_state("State for A"),
          model_b => make_model_state("State for B")
        },
        todos: [],
        children: [],
        budget_data: nil
      }

      messages_a = build_messages_with_injections(state, model_a)
      messages_b = build_messages_with_injections(state, model_b)

      content_a = Enum.map_join(messages_a, " ", & &1.content)
      content_b = Enum.map_join(messages_b, " ", & &1.content)

      assert content_a =~ "State for A"
      refute content_a =~ "State for B"

      assert content_b =~ "State for B"
      refute content_b =~ "State for A"
    end
  end

  # ========== R64: EMPTY ACE NO CHANGE ==========

  describe "R64: empty ACE leaves messages unchanged" do
    test "no injection when no lessons for model" do
      model_id = "test-model"
      other_model = "other-model"

      state = %{
        agent_id: "test-agent",
        task_id: "test-task",
        model_histories: %{
          model_id => [make_history_entry(:user, "Original content")]
        },
        # Lessons only for other model
        context_lessons: %{other_model => [make_lesson("Other lesson")]},
        model_states: %{},
        todos: [],
        children: [],
        budget_data: nil
      }

      messages = build_messages_with_injections(state, model_id)

      # No ACE tags should be present
      content = Enum.map_join(messages, " ", & &1.content)
      refute content =~ "<lessons>"
      refute content =~ "<state>"
      refute content =~ "Other lesson"
    end

    test "no injection when context_lessons empty" do
      model_id = "test-model"

      state = %{
        agent_id: "test-agent",
        task_id: "test-task",
        model_histories: %{
          model_id => [make_history_entry(:user, "Just a message")]
        },
        context_lessons: %{},
        model_states: %{},
        todos: [],
        children: [],
        budget_data: nil
      }

      messages = build_messages_with_injections(state, model_id)

      content = Enum.map_join(messages, " ", & &1.content)
      refute content =~ "<lessons>"
      refute content =~ "<state>"

      # Original content preserved
      assert content =~ "Just a message"
    end

    test "no injection when both lessons and state nil for model" do
      model_id = "test-model"

      state = %{
        agent_id: "test-agent",
        task_id: "test-task",
        model_histories: %{
          model_id => [make_history_entry(:user, "User content")]
        },
        context_lessons: nil,
        model_states: nil,
        todos: [],
        children: [],
        budget_data: nil
      }

      messages = build_messages_with_injections(state, model_id)

      content = Enum.map_join(messages, " ", & &1.content)
      refute content =~ "<lessons>"
      refute content =~ "<state>"
    end
  end

  # ========== HELPER: BUILD MESSAGES WITH ALL INJECTIONS ==========

  # Simulates the injection order in PerModelQuery.query_single_model_with_retry/3
  defp build_messages_with_injections(state, model_id) do
    alias Quoracle.Agent.ContextManager
    alias Quoracle.Agent.ConsensusHandler.{TodoInjector, ChildrenInjector}

    # 1. Build base messages from history
    messages = ContextManager.build_conversation_messages(state, model_id)

    # 2. Inject ACE into FIRST user message (NEW - what we're testing)
    messages = AceInjector.inject_ace_context(state, messages, model_id)

    # 3. Inject todos into LAST message
    messages = TodoInjector.inject_todo_context(state, messages)

    # 4. Inject children into LAST message
    messages = ChildrenInjector.inject_children_context(state, messages)

    messages
  end
end
