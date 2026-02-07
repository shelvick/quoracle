defmodule Quoracle.Agent.Consensus.PerModelQueryRetryInjectorsTest do
  @moduledoc """
  Tests for retry path using unified message-building logic.

  WorkGroupID: wip-20260104-ace-injector
  Packet: 2 (Retry Path Refactor)

  Problem: The retry path (triggered by context_length_exceeded) rebuilds messages
  but skips ALL injectors (ACE, todos, children, budget). This means after condensation,
  the LLM receives incomplete context.

  Fix: Extract message-building into a helper function used by both primary and retry paths.

  ARC Verification Criteria: R65-R70
  """
  use ExUnit.Case, async: true

  alias Quoracle.Agent.Consensus.PerModelQuery

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

  defp make_state_with_all_context(model_id) do
    # Create isolated registry for test
    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    {:ok, _} = Registry.start_link(keys: :unique, name: registry_name)

    # Register a fake child process so ChildrenInjector can find it
    child_agent_id = "child-1"
    Registry.register(registry_name, {:agent, child_agent_id}, %{})

    %{
      # Use atom for agent_id so BudgetInjector uses test path (line 48) not production path (line 36)
      agent_id: :test_agent,
      task_id: "test-task",
      model_histories: %{
        model_id => [
          make_history_entry(:user, "User message"),
          make_history_entry(:assistant, "Assistant response")
        ]
      },
      context_lessons: %{model_id => [make_lesson("Lesson from condensation")]},
      model_states: %{model_id => make_model_state("Task 50% complete")},
      todos: [%{content: "Current task", state: :todo}],
      children: [%{agent_id: child_agent_id, spawned_at: DateTime.utc_now()}],
      # BudgetInjector expects :allocated key, plus :spent/:over_budget for test path
      budget_data: %{allocated: Decimal.new(5000), committed: Decimal.new(0)},
      spent: Decimal.new(1000),
      over_budget: false,
      registry: registry_name
    }
  end

  # ========== R65: RETRY PATH INJECTS ACE ==========

  describe "R65: retry path injects ACE context" do
    test "retry after context_length_exceeded includes ACE lessons" do
      model_id = "test-model"
      state = make_state_with_all_context(model_id)

      test_pid = self()
      call_count = :counters.new(1, [:atomics])

      # Mock query that fails first time (context overflow), succeeds on retry
      mock_query_fn = fn messages, _models, _opts ->
        count = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, count)

        send(test_pid, {:captured_messages, count, messages})

        if count == 1 do
          # First call: simulate context length exceeded
          {:ok,
           %{
             successful_responses: [],
             failed_models: [{model_id, :context_length_exceeded}]
           }}
        else
          # Retry: succeed
          {:ok,
           %{
             successful_responses: [
               %{model: model_id, content: ~s({"action": "orient", "params": {}, "wait": false})}
             ],
             failed_models: []
           }}
        end
      end

      opts = [
        model_query_fn: mock_query_fn,
        round: 1,
        test_mode: true,
        # Mock reflector for condensation
        reflector_fn: fn _messages, _model_id, _opts ->
          {:ok, %{lessons: [], state: []}}
        end
      ]

      {:ok, _response, _state} =
        PerModelQuery.query_single_model_with_retry(state, model_id, opts)

      # Verify retry path (call 2) includes ACE content
      assert_receive {:captured_messages, 2, retry_messages}, 30_000

      all_content =
        Enum.map_join(retry_messages, " ", fn msg ->
          case msg.content do
            c when is_binary(c) -> c
            list when is_list(list) -> Enum.map_join(list, " ", &to_string(&1[:text] || ""))
          end
        end)

      assert all_content =~ "<lessons>",
             "Retry path should inject ACE lessons (currently missing)"
    end
  end

  # ========== R66: RETRY PATH INJECTS TODOS ==========

  describe "R66: retry path injects TODO context" do
    test "retry after context_length_exceeded includes todos" do
      model_id = "test-model"
      state = make_state_with_all_context(model_id)

      test_pid = self()
      call_count = :counters.new(1, [:atomics])

      mock_query_fn = fn messages, _models, _opts ->
        count = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, count)

        send(test_pid, {:captured_messages, count, messages})

        if count == 1 do
          {:ok,
           %{
             successful_responses: [],
             failed_models: [{model_id, :context_length_exceeded}]
           }}
        else
          {:ok,
           %{
             successful_responses: [
               %{model: model_id, content: ~s({"action": "orient", "params": {}, "wait": false})}
             ],
             failed_models: []
           }}
        end
      end

      opts = [
        model_query_fn: mock_query_fn,
        round: 1,
        test_mode: true,
        reflector_fn: fn _messages, _model_id, _opts ->
          {:ok, %{lessons: [], state: []}}
        end
      ]

      {:ok, _response, _state} =
        PerModelQuery.query_single_model_with_retry(state, model_id, opts)

      # Verify retry path includes TODO content
      assert_receive {:captured_messages, 2, retry_messages}, 30_000

      all_content =
        Enum.map_join(retry_messages, " ", fn msg ->
          case msg.content do
            c when is_binary(c) -> c
            list when is_list(list) -> Enum.map_join(list, " ", &to_string(&1[:text] || ""))
          end
        end)

      assert all_content =~ "<todos>",
             "Retry path should inject todos (currently missing)"
    end
  end

  # ========== R67: RETRY PATH INJECTS CHILDREN ==========

  describe "R67: retry path injects children context" do
    test "retry after context_length_exceeded includes children" do
      model_id = "test-model"
      state = make_state_with_all_context(model_id)

      test_pid = self()
      call_count = :counters.new(1, [:atomics])

      mock_query_fn = fn messages, _models, _opts ->
        count = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, count)

        send(test_pid, {:captured_messages, count, messages})

        if count == 1 do
          {:ok,
           %{
             successful_responses: [],
             failed_models: [{model_id, :context_length_exceeded}]
           }}
        else
          {:ok,
           %{
             successful_responses: [
               %{model: model_id, content: ~s({"action": "orient", "params": {}, "wait": false})}
             ],
             failed_models: []
           }}
        end
      end

      opts = [
        model_query_fn: mock_query_fn,
        round: 1,
        test_mode: true,
        reflector_fn: fn _messages, _model_id, _opts ->
          {:ok, %{lessons: [], state: []}}
        end
      ]

      {:ok, _response, _state} =
        PerModelQuery.query_single_model_with_retry(state, model_id, opts)

      # Verify retry path includes children content
      assert_receive {:captured_messages, 2, retry_messages}, 30_000

      all_content =
        Enum.map_join(retry_messages, " ", fn msg ->
          case msg.content do
            c when is_binary(c) -> c
            list when is_list(list) -> Enum.map_join(list, " ", &to_string(&1[:text] || ""))
          end
        end)

      assert all_content =~ "<children>",
             "Retry path should inject children context (currently missing)"
    end
  end

  # ========== R68: RETRY PATH INJECTS BUDGET ==========

  describe "R68: retry path injects budget context" do
    test "retry after context_length_exceeded includes budget" do
      model_id = "test-model"
      state = make_state_with_all_context(model_id)

      test_pid = self()
      call_count = :counters.new(1, [:atomics])

      mock_query_fn = fn messages, _models, _opts ->
        count = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, count)

        send(test_pid, {:captured_messages, count, messages})

        if count == 1 do
          {:ok,
           %{
             successful_responses: [],
             failed_models: [{model_id, :context_length_exceeded}]
           }}
        else
          {:ok,
           %{
             successful_responses: [
               %{model: model_id, content: ~s({"action": "orient", "params": {}, "wait": false})}
             ],
             failed_models: []
           }}
        end
      end

      opts = [
        model_query_fn: mock_query_fn,
        round: 1,
        test_mode: true,
        reflector_fn: fn _messages, _model_id, _opts ->
          {:ok, %{lessons: [], state: []}}
        end
      ]

      {:ok, _response, _state} =
        PerModelQuery.query_single_model_with_retry(state, model_id, opts)

      # Verify retry path includes budget content
      assert_receive {:captured_messages, 2, retry_messages}, 30_000

      all_content =
        Enum.map_join(retry_messages, " ", fn msg ->
          case msg.content do
            c when is_binary(c) -> c
            list when is_list(list) -> Enum.map_join(list, " ", &to_string(&1[:text] || ""))
          end
        end)

      assert all_content =~ "<budget>",
             "Retry path should inject budget context (currently missing)"
    end
  end

  # ========== R69: PRIMARY AND RETRY PATHS EQUIVALENT ==========

  describe "R69: primary and retry paths use same message building" do
    test "retry messages have same injection structure as primary" do
      model_id = "test-model"
      state = make_state_with_all_context(model_id)

      test_pid = self()
      call_count = :counters.new(1, [:atomics])

      mock_query_fn = fn messages, _models, _opts ->
        count = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, count)

        send(test_pid, {:captured_messages, count, messages})

        if count == 1 do
          {:ok,
           %{
             successful_responses: [],
             failed_models: [{model_id, :context_length_exceeded}]
           }}
        else
          {:ok,
           %{
             successful_responses: [
               %{model: model_id, content: ~s({"action": "orient", "params": {}, "wait": false})}
             ],
             failed_models: []
           }}
        end
      end

      opts = [
        model_query_fn: mock_query_fn,
        round: 1,
        test_mode: true,
        reflector_fn: fn _messages, _model_id, _opts ->
          {:ok, %{lessons: [], state: []}}
        end
      ]

      {:ok, _response, _state} =
        PerModelQuery.query_single_model_with_retry(state, model_id, opts)

      # Capture both primary and retry messages
      assert_receive {:captured_messages, 1, primary_messages}, 30_000
      assert_receive {:captured_messages, 2, retry_messages}, 30_000

      # Helper to extract injection markers
      extract_markers = fn messages ->
        all_content =
          Enum.map_join(messages, " ", fn msg ->
            case msg.content do
              c when is_binary(c) -> c
              list when is_list(list) -> Enum.map_join(list, " ", &to_string(&1[:text] || ""))
            end
          end)

        %{
          has_lessons: all_content =~ "<lessons>",
          has_todos: all_content =~ "<todos>",
          has_children: all_content =~ "<children>",
          has_budget: all_content =~ "<budget>"
        }
      end

      primary_markers = extract_markers.(primary_messages)
      retry_markers = extract_markers.(retry_messages)

      # Both paths should have the same injections
      assert primary_markers == retry_markers,
             "Retry path should have same injections as primary path. " <>
               "Primary: #{inspect(primary_markers)}, Retry: #{inspect(retry_markers)}"
    end
  end

  # ========== R70: HELPER FUNCTION EXISTS ==========

  describe "R70: build_query_messages helper exists" do
    test "build_query_messages/3 is a callable function" do
      model_id = "test-model"

      state = %{
        agent_id: "test",
        task_id: "test",
        model_histories: %{model_id => []},
        context_lessons: %{},
        model_states: %{},
        todos: [],
        children: [],
        budget_data: nil,
        registry: nil
      }

      opts = [round: 1]

      # This function should exist after refactoring
      # Will fail with UndefinedFunctionError until implemented
      result = PerModelQuery.build_query_messages(state, model_id, opts)

      assert is_list(result)
    end

    test "build_query_messages includes all injectors" do
      model_id = "test-model"

      # Create isolated registry for test
      registry_name = :"test_registry_r70_#{System.unique_integer([:positive])}"
      {:ok, _} = Registry.start_link(keys: :unique, name: registry_name)

      # Register child so ChildrenInjector can find it
      child_agent_id = "child-1"
      Registry.register(registry_name, {:agent, child_agent_id}, %{})

      state = %{
        # Use atom for agent_id so BudgetInjector uses test path (line 48) not production path (line 36)
        agent_id: :test_agent,
        task_id: "test",
        model_histories: %{
          model_id => [
            %{type: :user, content: "Hello", timestamp: DateTime.utc_now()}
          ]
        },
        context_lessons: %{model_id => [make_lesson("Test lesson")]},
        model_states: %{model_id => make_model_state("State summary")},
        todos: [%{content: "Task 1", state: :todo}],
        children: [%{agent_id: child_agent_id, spawned_at: DateTime.utc_now()}],
        # BudgetInjector expects :allocated key, plus :spent/:over_budget for test path
        budget_data: %{allocated: Decimal.new(1000), committed: Decimal.new(0)},
        spent: Decimal.new(500),
        over_budget: false,
        registry: registry_name
      }

      opts = [round: 1]

      messages = PerModelQuery.build_query_messages(state, model_id, opts)

      all_content =
        Enum.map_join(messages, " ", fn msg ->
          case msg.content do
            c when is_binary(c) -> c
            list when is_list(list) -> Enum.map_join(list, " ", &to_string(&1[:text] || ""))
          end
        end)

      # All injectors should be applied
      assert all_content =~ "<lessons>", "Should include ACE lessons"
      assert all_content =~ "<todos>", "Should include todos"
      assert all_content =~ "<children>", "Should include children"
      assert all_content =~ "<budget>", "Should include budget"
    end
  end
end
