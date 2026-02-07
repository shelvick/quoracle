defmodule Quoracle.Agent.Consensus.PerModelQueryInlineCondenseTest do
  @moduledoc """
  Tests for inline condensation triggered by model's `condense` parameter.

  When a model includes `"condense": N` in its response, N oldest messages
  are condensed from that model's history BEFORE consensus aggregation.

  WorkGroupID: wip-20260104-condense-param
  Packet: 2 (Feature Integration)
  Requirements: R65-R79 from AGENT_Consensus v14.0 spec
  """

  use Quoracle.DataCase, async: true

  import Test.IsolationHelpers

  alias Quoracle.Agent.Consensus.PerModelQuery
  alias Quoracle.Tasks.TaskManager
  alias Quoracle.Tasks.Task
  alias Quoracle.Agents.Agent, as: AgentSchema
  alias Quoracle.Repo

  # Helper to build a history with N entries in NEWEST-FIRST order
  # (matching production storage via [entry | history] prepend)
  # Example: build_history(5) => [%{id: 5}, %{id: 4}, %{id: 3}, %{id: 2}, %{id: 1}]
  defp build_history(count) do
    count..1//-1
    |> Enum.map(fn id ->
      %{
        id: id,
        role: if(rem(id, 2) == 1, do: "user", else: "assistant"),
        content: "Message #{id} content",
        timestamp: DateTime.utc_now()
      }
    end)
  end

  # Helper to build a state with model histories
  defp build_state(agent_id, task_id, model_id, history_count) do
    %{
      agent_id: agent_id,
      task_id: task_id,
      restoration_mode: false,
      model_histories: %{
        model_id => build_history(history_count)
      },
      context_lessons: %{},
      model_states: %{}
    }
  end

  describe "R65-R67: Extract condense and trigger condensation" do
    setup %{sandbox_owner: _sandbox_owner} do
      deps = create_isolated_deps()
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))
      agent_id = "condense-test-#{System.unique_integer([:positive])}"

      {:ok, _db_agent} =
        Repo.insert(%AgentSchema{
          agent_id: agent_id,
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: nil,
          inserted_at: ~N[2025-01-01 10:00:00]
        })

      [task_id: task.id, agent_id: agent_id, deps: deps]
    end

    test "extracts condense value from model response", %{agent_id: agent_id, task_id: task_id} do
      model_id = "anthropic:claude-sonnet-4"
      state = build_state(agent_id, task_id, model_id, 10)

      # Mock response with condense parameter
      raw_response = %{"condense" => 5, "action" => "wait", "params" => %{}}

      # This function doesn't exist yet - will fail with UndefinedFunctionError
      result = PerModelQuery.maybe_inline_condense(state, model_id, raw_response, [])

      # State should be updated with condensed history
      assert length(result.model_histories[model_id]) < 10
    end

    @tag :integration
    test "valid condense value triggers inline condensation", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "anthropic:claude-sonnet-4"
      state = build_state(agent_id, task_id, model_id, 10)

      # Mock Reflector to return lessons
      opts = [
        reflector_fn: fn _messages, _model_id, _opts ->
          {:ok,
           %{
             lessons: [%{type: :factual, content: "Test lesson", confidence: 2}],
             state: [%{summary: "Test state", updated_at: DateTime.utc_now()}]
           }}
        end,
        test_mode: true
      ]

      # condense_n_oldest_messages/4 doesn't exist yet - will fail
      result = PerModelQuery.condense_n_oldest_messages(state, model_id, 5, opts)

      # History should be condensed
      assert length(result.model_histories[model_id]) == 5
    end

    test "nil condense skips inline condensation", %{agent_id: agent_id, task_id: task_id} do
      model_id = "anthropic:claude-sonnet-4"
      state = build_state(agent_id, task_id, model_id, 10)

      # Response without condense parameter
      raw_response = %{"action" => "wait", "params" => %{}}

      result = PerModelQuery.maybe_inline_condense(state, model_id, raw_response, [])

      # State should be unchanged
      assert result == state
      assert length(result.model_histories[model_id]) == 10
    end
  end

  describe "R68-R69: Validation and edge cases" do
    setup %{sandbox_owner: _sandbox_owner} do
      deps = create_isolated_deps()
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))
      agent_id = "validate-test-#{System.unique_integer([:positive])}"

      {:ok, _db_agent} =
        Repo.insert(%AgentSchema{
          agent_id: agent_id,
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: nil,
          inserted_at: ~N[2025-01-01 10:00:00]
        })

      [task_id: task.id, agent_id: agent_id, deps: deps]
    end

    test "condense N clamped to max allowed", %{agent_id: agent_id, task_id: task_id} do
      model_id = "anthropic:claude-sonnet-4"
      # History with 5 entries, max N = 5 - 2 = 3
      # Must preserve last 2 messages: assistant (candidate) + user (prompt/refinement context)
      state = build_state(agent_id, task_id, model_id, 5)

      opts = [
        reflector_fn: fn _messages, _model_id, _opts ->
          {:ok, %{lessons: [], state: []}}
        end,
        test_mode: true
      ]

      # Request N=10, should be clamped to 3 (keeps 2 messages for refinement context)
      result = PerModelQuery.condense_n_oldest_messages(state, model_id, 10, opts)

      # Behavior: Should keep 2 messages (5 - 3 = 2) for consensus refinement
      assert length(result.model_histories[model_id]) == 2
    end

    test "short history skips condensation", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "anthropic:claude-sonnet-4"
      # History with only 2 entries - too short to condense
      state = build_state(agent_id, task_id, model_id, 2)

      opts = [test_mode: true]

      result = PerModelQuery.condense_n_oldest_messages(state, model_id, 1, opts)

      # Behavior: State should be unchanged when history too short
      assert result == state
      assert length(result.model_histories[model_id]) == 2
    end

    test "empty history skips condensation", %{agent_id: agent_id, task_id: task_id} do
      model_id = "anthropic:claude-sonnet-4"

      state = %{
        agent_id: agent_id,
        task_id: task_id,
        restoration_mode: false,
        model_histories: %{model_id => []},
        context_lessons: %{},
        model_states: %{}
      }

      opts = [test_mode: true]

      result = PerModelQuery.condense_n_oldest_messages(state, model_id, 5, opts)

      # Behavior: State unchanged when history empty
      assert result == state
    end
  end

  describe "R70-R72: Reflector and ACE pipeline integration" do
    setup %{sandbox_owner: _sandbox_owner} do
      deps = create_isolated_deps()
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))
      agent_id = "reflector-test-#{System.unique_integer([:positive])}"

      {:ok, _db_agent} =
        Repo.insert(%AgentSchema{
          agent_id: agent_id,
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: nil,
          inserted_at: ~N[2025-01-01 10:00:00]
        })

      [task_id: task.id, agent_id: agent_id, deps: deps]
    end

    @tag :integration
    test "Reflector receives oldest N messages", %{agent_id: agent_id, task_id: task_id} do
      model_id = "anthropic:claude-sonnet-4"
      state = build_state(agent_id, task_id, model_id, 10)

      received_messages =
        :ets.new(:"received_messages_#{System.unique_integer([:positive])}", [:set, :public])

      opts = [
        reflector_fn: fn messages, _model_id, _opts ->
          :ets.insert(received_messages, {:messages, messages})
          {:ok, %{lessons: [], state: []}}
        end,
        test_mode: true
      ]

      PerModelQuery.condense_n_oldest_messages(state, model_id, 3, opts)

      [{:messages, messages}] = :ets.lookup(received_messages, :messages)
      :ets.delete(received_messages)

      # Should have received the 3 oldest messages (formatted for reflection)
      assert length(messages) == 3
      # Messages are reformatted with role/content only - verify by content
      contents = Enum.map(messages, & &1.content)
      assert "Message 1 content" in contents
      assert "Message 2 content" in contents
      assert "Message 3 content" in contents
    end

    @tag :integration
    test "lessons accumulated from inline condensation", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "anthropic:claude-sonnet-4"
      state = build_state(agent_id, task_id, model_id, 10)

      opts = [
        reflector_fn: fn _messages, _model_id, _opts ->
          {:ok,
           %{
             lessons: [
               %{type: :factual, content: "Lesson from condensation", confidence: 2}
             ],
             state: []
           }}
        end,
        test_mode: true
      ]

      result = PerModelQuery.condense_n_oldest_messages(state, model_id, 3, opts)

      # Lessons should be accumulated
      assert result.context_lessons[model_id] != []
      lesson = hd(result.context_lessons[model_id])
      assert lesson.content == "Lesson from condensation"
    end

    @tag :integration
    test "model state updated from inline condensation", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "anthropic:claude-sonnet-4"
      state = build_state(agent_id, task_id, model_id, 10)

      opts = [
        reflector_fn: fn _messages, _model_id, _opts ->
          {:ok,
           %{
             lessons: [],
             state: [%{summary: "Updated model state", updated_at: DateTime.utc_now()}]
           }}
        end,
        test_mode: true
      ]

      result = PerModelQuery.condense_n_oldest_messages(state, model_id, 3, opts)

      # Model state should be updated (stored as single map, not list)
      assert result.model_states[model_id] != nil
      assert result.model_states[model_id].summary == "Updated model state"
    end
  end

  describe "R73-R74: History and persistence updates" do
    setup %{sandbox_owner: _sandbox_owner} do
      deps = create_isolated_deps()
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))
      agent_id = "history-test-#{System.unique_integer([:positive])}"

      {:ok, _db_agent} =
        Repo.insert(%AgentSchema{
          agent_id: agent_id,
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: nil,
          inserted_at: ~N[2025-01-01 10:00:00]
        })

      [task_id: task.id, agent_id: agent_id, deps: deps]
    end

    test "history contains only kept messages after condensation", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "anthropic:claude-sonnet-4"
      state = build_state(agent_id, task_id, model_id, 10)

      opts = [
        reflector_fn: fn _messages, _model_id, _opts ->
          {:ok, %{lessons: [], state: []}}
        end,
        test_mode: true
      ]

      result = PerModelQuery.condense_n_oldest_messages(state, model_id, 4, opts)

      # Should have 6 messages left (10 - 4)
      assert length(result.model_histories[model_id]) == 6

      # Remaining should be messages 5-10 in newest-first order
      remaining_ids = Enum.map(result.model_histories[model_id], & &1.id)
      assert remaining_ids == [10, 9, 8, 7, 6, 5]
    end

    @tag :integration
    test "ACE state persisted after inline condensation", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "anthropic:claude-sonnet-4"
      state = build_state(agent_id, task_id, model_id, 10)

      opts = [
        reflector_fn: fn _messages, _model_id, _opts ->
          {:ok,
           %{
             lessons: [%{type: :factual, content: "Persisted lesson", confidence: 2}],
             state: [%{summary: "Persisted state", updated_at: DateTime.utc_now()}]
           }}
        end,
        test_mode: true
      ]

      PerModelQuery.condense_n_oldest_messages(state, model_id, 3, opts)

      # Verify ACE state was persisted to database
      {:ok, db_agent} = TaskManager.get_agent(agent_id)
      assert is_map(db_agent.state)
      assert Map.has_key?(db_agent.state, "context_lessons")
    end
  end

  describe "R75-R76: State propagation and Reflector failure" do
    setup %{sandbox_owner: _sandbox_owner} do
      deps = create_isolated_deps()
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))
      agent_id = "state-test-#{System.unique_integer([:positive])}"

      {:ok, _db_agent} =
        Repo.insert(%AgentSchema{
          agent_id: agent_id,
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: nil,
          inserted_at: ~N[2025-01-01 10:00:00]
        })

      [task_id: task.id, agent_id: agent_id, deps: deps]
    end

    test "condensed state propagated through consensus pipeline", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "anthropic:claude-sonnet-4"
      state = build_state(agent_id, task_id, model_id, 10)

      opts = [
        reflector_fn: fn _messages, _model_id, _opts ->
          {:ok, %{lessons: [], state: []}}
        end,
        test_mode: true
      ]

      result = PerModelQuery.condense_n_oldest_messages(state, model_id, 3, opts)

      # Result should be a map (updated state)
      assert is_map(result)
      assert Map.has_key?(result, :model_histories)
      assert Map.has_key?(result, :context_lessons)
      assert Map.has_key?(result, :model_states)
    end

    test "history condensed even when Reflector fails", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "anthropic:claude-sonnet-4"
      state = build_state(agent_id, task_id, model_id, 10)

      opts = [
        reflector_fn: fn _messages, _model_id, _opts ->
          {:error, :reflection_failed}
        end,
        test_mode: true
      ]

      result = PerModelQuery.condense_n_oldest_messages(state, model_id, 3, opts)

      # History should still be condensed despite Reflector failure
      assert length(result.model_histories[model_id]) == 7
    end
  end

  describe "R77: Other models unaffected" do
    setup %{sandbox_owner: _sandbox_owner} do
      deps = create_isolated_deps()
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))
      agent_id = "multi-model-test-#{System.unique_integer([:positive])}"

      {:ok, _db_agent} =
        Repo.insert(%AgentSchema{
          agent_id: agent_id,
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: nil,
          inserted_at: ~N[2025-01-01 10:00:00]
        })

      [task_id: task.id, agent_id: agent_id, deps: deps]
    end

    test "inline condensation only affects requesting model", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_a = "anthropic:claude-sonnet-4"
      model_b = "azure-openai:gpt-4o"

      # State with two models
      state = %{
        agent_id: agent_id,
        task_id: task_id,
        restoration_mode: false,
        model_histories: %{
          model_a => build_history(10),
          model_b => build_history(8)
        },
        context_lessons: %{},
        model_states: %{}
      }

      opts = [
        reflector_fn: fn _messages, _model_id, _opts ->
          {:ok, %{lessons: [], state: []}}
        end,
        test_mode: true
      ]

      # Condense only model_a
      result = PerModelQuery.condense_n_oldest_messages(state, model_a, 5, opts)

      # Model A should be condensed
      assert length(result.model_histories[model_a]) == 5

      # Model B should be unchanged
      assert length(result.model_histories[model_b]) == 8
    end
  end

  describe "R78-R79: Refinement rounds and timing" do
    setup %{sandbox_owner: _sandbox_owner} do
      deps = create_isolated_deps()
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))
      agent_id = "timing-test-#{System.unique_integer([:positive])}"

      {:ok, _db_agent} =
        Repo.insert(%AgentSchema{
          agent_id: agent_id,
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: nil,
          inserted_at: ~N[2025-01-01 10:00:00]
        })

      [task_id: task.id, agent_id: agent_id, deps: deps]
    end

    @tag :integration
    test "inline condensation works during refinement", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "anthropic:claude-sonnet-4"
      state = build_state(agent_id, task_id, model_id, 10)

      # Add refinement context to opts
      opts = [
        reflector_fn: fn _messages, _model_id, _opts ->
          {:ok, %{lessons: [], state: []}}
        end,
        test_mode: true,
        round: 2,
        refinement_context: "Previous responses disagreed"
      ]

      result = PerModelQuery.condense_n_oldest_messages(state, model_id, 3, opts)

      # Should work the same in refinement round
      assert length(result.model_histories[model_id]) == 7
    end

    @tag :integration
    test "inline condensation timing is post-response pre-aggregation", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "anthropic:claude-sonnet-4"
      state = build_state(agent_id, task_id, model_id, 10)

      execution_order =
        :ets.new(:"execution_order_#{System.unique_integer([:positive])}", [:ordered_set, :public])

      opts = [
        reflector_fn: fn _messages, _model_id, _opts ->
          :ets.insert(execution_order, {System.monotonic_time(), :reflector_called})
          {:ok, %{lessons: [], state: []}}
        end,
        test_mode: true
      ]

      # Record pre-condensation
      :ets.insert(execution_order, {System.monotonic_time(), :before_condense})

      PerModelQuery.condense_n_oldest_messages(state, model_id, 3, opts)

      # Record post-condensation
      :ets.insert(execution_order, {System.monotonic_time(), :after_condense})

      # Get execution order
      events = :ets.tab2list(execution_order) |> Enum.map(fn {_, event} -> event end)
      :ets.delete(execution_order)

      # Verify order: before -> reflector -> after
      assert Enum.at(events, 0) == :before_condense
      assert Enum.at(events, 1) == :reflector_called
      assert Enum.at(events, 2) == :after_condense
    end
  end

  describe "Acceptance test - Full flow" do
    setup %{sandbox_owner: _sandbox_owner} do
      deps = create_isolated_deps()
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))
      agent_id = "acceptance-test-#{System.unique_integer([:positive])}"

      {:ok, _db_agent} =
        Repo.insert(%AgentSchema{
          agent_id: agent_id,
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: nil,
          inserted_at: ~N[2025-01-01 10:00:00]
        })

      [task_id: task.id, agent_id: agent_id, deps: deps]
    end

    @tag :acceptance
    @tag :integration
    test "model condense request triggers inline condensation", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "anthropic:claude-sonnet-4"

      # Build state with 10 messages
      state = build_state(agent_id, task_id, model_id, 10)

      # Simulate model response with condense=5
      raw_response = %{
        "action" => "wait",
        "params" => %{},
        "reasoning" => "Taking a break",
        "condense" => 5
      }

      opts = [
        reflector_fn: fn messages, _model_id, _opts ->
          # Verify we received the 5 oldest messages (formatted for reflection)
          assert length(messages) == 5
          # Messages are reformatted with role/content only - verify by content
          contents = Enum.map(messages, & &1.content)
          assert "Message 1 content" in contents
          assert "Message 5 content" in contents

          {:ok,
           %{
             lessons: [%{type: :factual, content: "Acceptance test lesson", confidence: 2}],
             state: [%{summary: "Acceptance test state", updated_at: DateTime.utc_now()}]
           }}
        end,
        test_mode: true
      ]

      # Trigger inline condensation
      result = PerModelQuery.maybe_inline_condense(state, model_id, raw_response, opts)

      # Verify history was condensed (5 kept in newest-first order)
      assert length(result.model_histories[model_id]) == 5
      remaining_ids = Enum.map(result.model_histories[model_id], & &1.id)
      assert remaining_ids == [10, 9, 8, 7, 6]

      # Verify lessons were accumulated
      assert result.context_lessons[model_id] != []

      # Verify state was updated
      assert result.model_states[model_id] != nil

      # Verify persistence
      {:ok, db_agent} = TaskManager.get_agent(agent_id)
      assert is_map(db_agent.state)
    end
  end

  describe "R80: Query flow condense integration" do
    # Tests that query_single_model_with_retry calls maybe_inline_condense
    # after receiving a model response. This is the critical integration point
    # that wires the condense feature into the production flow.
    #
    # Spec reference: AGENT_Consensus_PerModelHistories v14.0, section 14.3

    setup %{sandbox_owner: _sandbox_owner} do
      deps = create_isolated_deps()
      {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))
      agent_id = "query-flow-test-#{System.unique_integer([:positive])}"

      {:ok, _db_agent} =
        Repo.insert(%AgentSchema{
          agent_id: agent_id,
          task_id: task.id,
          status: "running",
          parent_id: nil,
          config: %{},
          state: nil,
          inserted_at: ~N[2025-01-01 10:00:00]
        })

      [task_id: task.id, agent_id: agent_id, deps: deps]
    end

    @tag :acceptance
    @tag :integration
    test "query_single_model_with_retry triggers condensation when response contains condense", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "anthropic:claude-sonnet-4"

      # Build state with 10 messages
      state = build_state(agent_id, task_id, model_id, 10)

      # Track if reflector was called (proves condensation was triggered)
      reflector_called =
        :ets.new(:"reflector_tracker_#{System.unique_integer([:positive])}", [:set, :public])

      # Mock model_query_fn that returns response with condense parameter
      mock_query_fn = fn _messages, _models, _opts ->
        # Return a response that includes condense=5 in the raw JSON
        response_json =
          Jason.encode!(%{
            "action" => "wait",
            "params" => %{},
            "reasoning" => "Taking a break",
            "condense" => 5
          })

        {:ok,
         %{
           successful_responses: [%{model: model_id, content: response_json}],
           failed_models: []
         }}
      end

      opts = [
        model_query_fn: mock_query_fn,
        reflector_fn: fn _messages, _model_id, _opts ->
          :ets.insert(reflector_called, {:called, true})
          {:ok, %{lessons: [], state: []}}
        end,
        test_mode: true
      ]

      # Call the actual query flow
      {:ok, _response, result_state} =
        PerModelQuery.query_single_model_with_retry(state, model_id, opts)

      # CRITICAL ASSERTION: Condensation should have been triggered
      # This will FAIL until the integration hook is added to query_single_model_with_retry
      assert :ets.lookup(reflector_called, :called) == [{:called, true}],
             "Reflector was not called - maybe_inline_condense hook missing from query flow"

      # History should be condensed (10 - 5 = 5 messages remaining)
      assert length(result_state.model_histories[model_id]) == 5

      :ets.delete(reflector_called)
    end

    @tag :integration
    test "query flow returns original state when no condense parameter", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "anthropic:claude-sonnet-4"
      state = build_state(agent_id, task_id, model_id, 10)

      # Mock model_query_fn returns response WITHOUT condense
      mock_query_fn = fn _messages, _models, _opts ->
        response_json =
          Jason.encode!(%{
            "action" => "wait",
            "params" => %{},
            "reasoning" => "No condensation requested"
          })

        {:ok,
         %{
           successful_responses: [%{model: model_id, content: response_json}],
           failed_models: []
         }}
      end

      opts = [model_query_fn: mock_query_fn, test_mode: true]

      {:ok, _response, result_state} =
        PerModelQuery.query_single_model_with_retry(state, model_id, opts)

      # History should be unchanged (no condense parameter)
      assert length(result_state.model_histories[model_id]) == 10
    end

    @tag :integration
    test "query flow handles invalid condense values gracefully", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "anthropic:claude-sonnet-4"
      state = build_state(agent_id, task_id, model_id, 10)

      # Mock returns invalid condense value (string instead of integer)
      mock_query_fn = fn _messages, _models, _opts ->
        response_json =
          Jason.encode!(%{
            "action" => "wait",
            "params" => %{},
            "reasoning" => "Invalid condense",
            "condense" => "five"
          })

        {:ok,
         %{
           successful_responses: [%{model: model_id, content: response_json}],
           failed_models: []
         }}
      end

      opts = [model_query_fn: mock_query_fn, test_mode: true]

      {:ok, _response, result_state} =
        PerModelQuery.query_single_model_with_retry(state, model_id, opts)

      # History should be unchanged (invalid condense ignored)
      assert length(result_state.model_histories[model_id]) == 10
    end
  end
end
