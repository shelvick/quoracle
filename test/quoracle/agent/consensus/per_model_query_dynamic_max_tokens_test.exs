defmodule Quoracle.Agent.Consensus.PerModelQueryDynamicMaxTokensTest do
  @moduledoc """
  Tests for PerModelQuery v16.0 dynamic max_tokens calculation.

  Verifies the formula: max_tokens = min(context_window - input_tokens, output_limit)
  with condensation floor at 4096 tokens.

  WorkGroupID: fix-20260210-dynamic-max-tokens
  Spec: CONSENSUS_DynamicMaxTokens v1.0, Section 8 (Unit Tests - PerModelQuery)
  """

  use Quoracle.DataCase, async: true

  import Test.IsolationHelpers

  alias Quoracle.Agent.Consensus.PerModelQuery
  alias Quoracle.Tasks.Task
  alias Quoracle.Agents.Agent, as: AgentSchema
  alias Quoracle.Repo

  # Helper to build a minimal state for testing
  defp build_state(agent_id, task_id, model_id, opts) do
    history_count = Keyword.get(opts, :history_count, 5)
    system_prompt = Keyword.get(opts, :system_prompt, "You are a test assistant.")

    history =
      history_count..1//-1
      |> Enum.map(fn id ->
        %{
          id: id,
          role: if(rem(id, 2) == 1, do: "user", else: "assistant"),
          content: "Message #{id} content",
          timestamp: DateTime.utc_now()
        }
      end)

    %{
      agent_id: agent_id,
      task_id: task_id,
      restoration_mode: false,
      model_histories: %{
        model_id => history
      },
      context_lessons: %{},
      model_states: %{},
      system_prompt: system_prompt,
      prompt_fields: %{system_prompt: system_prompt},
      config: %{"model_pool" => [model_id]},
      children: [],
      todos: [],
      active_skills: [],
      skills_path: nil,
      pending_actions: %{},
      queued_messages: [],
      consensus_scheduled: false,
      wait_timer: nil,
      consensus_retry_count: 0,
      max_refinement_rounds: 4
    }
  end

  # Helper to create DB records needed for tests
  defp setup_db_records(_context) do
    _deps = create_isolated_deps()
    {:ok, task} = Repo.insert(Task.changeset(%Task{}, %{prompt: "Test", status: "running"}))
    agent_id = "dyn-max-tokens-#{System.unique_integer([:positive])}"

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

    [task_id: task.id, agent_id: agent_id]
  end

  describe "max_tokens capped when available < limit" do
    setup :setup_db_records

    test "caps max_tokens to available output space for high-output models", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      # DeepSeek-V3.2 scenario: output_limit=128000, context=131072
      # With large input, available_output < output_limit
      model_id = "anthropic:claude-sonnet-4"
      state = build_state(agent_id, task_id, model_id, history_count: 5)

      # Mock query function that captures the max_tokens from query options
      captured_opts =
        :ets.new(:"captured_opts_#{System.unique_integer([:positive])}", [:set, :public])

      mock_query_fn = fn _messages, _models, opts ->
        :ets.insert(captured_opts, {:max_tokens, Map.get(opts, :max_tokens)})

        response_json =
          Jason.encode!(%{
            "action" => "orient",
            "params" => %{
              "current_situation" => "Test",
              "goal_clarity" => "Clear",
              "available_resources" => "Full",
              "key_challenges" => "None",
              "delegation_consideration" => "none"
            },
            "reasoning" => "Test"
          })

        {:ok,
         %{
           successful_responses: [%{model: model_id, content: response_json}],
           failed_models: []
         }}
      end

      opts = [model_query_fn: mock_query_fn, test_mode: true]

      # This should calculate dynamic max_tokens using the formula
      # max_tokens = min(context_window - input_tokens, output_limit)
      # The function calculate_max_tokens doesn't exist yet - will fail
      {:ok, _response, _result_state} =
        PerModelQuery.query_single_model_with_retry(state, model_id, opts)

      # Verify max_tokens was dynamically calculated and passed to query
      [{:max_tokens, actual_max_tokens}] = :ets.lookup(captured_opts, :max_tokens)
      :ets.delete(captured_opts)

      # max_tokens should be a positive integer, dynamically calculated
      assert is_integer(actual_max_tokens)
      assert actual_max_tokens > 0

      # CRITICAL: The value should NOT be the old hardcoded 4096 default.
      # Dynamic calculation should produce a value based on LLMDB limits,
      # not the dead constant.
      assert actual_max_tokens != 4096,
             "max_tokens should be dynamically calculated, not the old static 4096 default"
    end
  end

  describe "max_tokens = output_limit when room" do
    setup :setup_db_records

    test "uses output_limit when context has plenty of room", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      # When input is small, available_output >> output_limit
      # max_tokens should equal output_limit (the lesser of the two)
      model_id = "anthropic:claude-sonnet-4"
      state = build_state(agent_id, task_id, model_id, history_count: 2)

      captured_opts =
        :ets.new(:"captured_opts_#{System.unique_integer([:positive])}", [:set, :public])

      mock_query_fn = fn _messages, _models, opts ->
        :ets.insert(captured_opts, {:max_tokens, Map.get(opts, :max_tokens)})

        response_json =
          Jason.encode!(%{
            "action" => "wait",
            "params" => %{},
            "reasoning" => "Waiting"
          })

        {:ok,
         %{
           successful_responses: [%{model: model_id, content: response_json}],
           failed_models: []
         }}
      end

      opts = [model_query_fn: mock_query_fn, test_mode: true]

      # calculate_max_tokens doesn't exist yet - the query will still use
      # the old static max_tokens: 4096 default until implemented
      {:ok, _response, _result_state} =
        PerModelQuery.query_single_model_with_retry(state, model_id, opts)

      [{:max_tokens, actual_max_tokens}] = :ets.lookup(captured_opts, :max_tokens)
      :ets.delete(captured_opts)

      # With tiny input, available space far exceeds output_limit
      # Dynamic calculation: min(huge_available, output_limit) = output_limit
      # This SHOULD NOT be the old static 4096 default
      # Claude has output_limit of ~8192 (or similar from LLMDB)
      # The key assertion: it should NOT be the old dead constant 4096
      assert actual_max_tokens != 4096,
             "max_tokens should be dynamically calculated, not the old static 4096 default"
    end
  end

  describe "condensation when available < floor" do
    setup :setup_db_records

    test "proactive condensation when output space below floor", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      # Use a model with small context limit where a large history fills most of it
      # openrouter:openai/gpt-3.5-turbo-0613 has 4095 context limit in LLMDB
      # With large history, available_output will be < 4096 (the floor)
      model_id = "openrouter:openai/gpt-3.5-turbo-0613"

      # Build history that nearly fills the 4095-token context
      # "word " is ~1 token, so 3500 words = ~3500 tokens
      large_history = [
        %{
          id: 1,
          role: "user",
          content: String.duplicate("word ", 3500),
          timestamp: DateTime.utc_now()
        }
      ]

      state = %{
        agent_id: agent_id,
        task_id: task_id,
        restoration_mode: false,
        model_histories: %{model_id => large_history},
        context_lessons: %{},
        model_states: %{},
        system_prompt: "System prompt taking more space",
        prompt_fields: %{system_prompt: "System prompt taking more space"},
        config: %{"model_pool" => [model_id]},
        children: [],
        todos: [],
        active_skills: [],
        skills_path: nil,
        pending_actions: %{},
        queued_messages: [],
        consensus_scheduled: false,
        wait_timer: nil,
        consensus_retry_count: 0,
        max_refinement_rounds: 4
      }

      condensation_triggered =
        :ets.new(:"condensation_#{System.unique_integer([:positive])}", [:set, :public])

      mock_query_fn = fn _messages, _models, _opts ->
        response_json =
          Jason.encode!(%{
            "action" => "wait",
            "params" => %{},
            "reasoning" => "Waiting"
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
          :ets.insert(condensation_triggered, {:triggered, true})
          {:ok, %{lessons: [], state: []}}
        end,
        test_mode: true
      ]

      # When available_output < 4096, proactive condensation should trigger
      # This will fail until the dynamic max_tokens + condensation floor is implemented
      {:ok, _response, result_state} =
        PerModelQuery.query_single_model_with_retry(state, model_id, opts)

      # Verify condensation was triggered (reflector called)
      assert :ets.lookup(condensation_triggered, :triggered) == [{:triggered, true}],
             "Condensation should trigger when available output space < 4096 floor"

      # History should be shorter after condensation
      assert length(result_state.model_histories[model_id]) <
               length(state.model_histories[model_id]),
             "History should be condensed when output space is below floor"

      :ets.delete(condensation_triggered)
    end
  end

  describe "messages rebuilt after condensation" do
    setup :setup_db_records

    test "query uses rebuilt messages from condensed state", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "openrouter:openai/gpt-3.5-turbo-0613"

      # Large history to trigger condensation floor
      large_history =
        Enum.map(20..1//-1, fn id ->
          %{
            id: id,
            role: if(rem(id, 2) == 1, do: "user", else: "assistant"),
            content: String.duplicate("word ", 200),
            timestamp: DateTime.utc_now()
          }
        end)

      state = %{
        agent_id: agent_id,
        task_id: task_id,
        restoration_mode: false,
        model_histories: %{model_id => large_history},
        context_lessons: %{},
        model_states: %{},
        system_prompt: "You are a test assistant.",
        prompt_fields: %{system_prompt: "You are a test assistant."},
        config: %{"model_pool" => [model_id]},
        children: [],
        todos: [],
        active_skills: [],
        skills_path: nil,
        pending_actions: %{},
        queued_messages: [],
        consensus_scheduled: false,
        wait_timer: nil,
        consensus_retry_count: 0,
        max_refinement_rounds: 4
      }

      message_counts =
        :ets.new(:"msg_counts_#{System.unique_integer([:positive])}", [:set, :public])

      mock_query_fn = fn messages, _models, opts ->
        :ets.insert(message_counts, {:count, length(messages)})
        :ets.insert(message_counts, {:max_tokens, Map.get(opts, :max_tokens)})

        response_json =
          Jason.encode!(%{
            "action" => "wait",
            "params" => %{},
            "reasoning" => "Done"
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
          {:ok, %{lessons: [], state: []}}
        end,
        test_mode: true
      ]

      # If condensation happens, messages should be rebuilt from condensed state
      # This will fail until dynamic max_tokens + condensation floor is implemented
      {:ok, _response, _result_state} =
        PerModelQuery.query_single_model_with_retry(state, model_id, opts)

      [{:count, query_msg_count}] = :ets.lookup(message_counts, :count)
      [{:max_tokens, actual_max_tokens}] = :ets.lookup(message_counts, :max_tokens)
      :ets.delete(message_counts)

      # After condensation, the message count sent to the query should be
      # fewer than original history + system prompt
      # Original: 20 history messages + 1 system = 21
      assert query_msg_count < 21,
             "Messages should be rebuilt from condensed state with fewer entries"

      # CRITICAL: max_tokens must be dynamically calculated, not the old 4096
      assert actual_max_tokens != 4096,
             "max_tokens should be dynamically calculated after condensation, not old 4096"
    end
  end

  describe "proceeds when post-condensation below floor" do
    setup :setup_db_records

    test "query succeeds with positive max_tokens even when context is tight", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      # Create scenario where even after condensation, system prompt alone
      # nearly fills the tiny context window
      model_id = "openrouter:openai/gpt-3.5-turbo-0613"

      # Tiny history (will be condensed to near-zero)
      small_history = [
        %{
          id: 1,
          role: "user",
          content: "Hello",
          timestamp: DateTime.utc_now()
        }
      ]

      # Large system prompt that eats most of the 4095-token context
      large_system_prompt = String.duplicate("This is a verbose system prompt. ", 200)

      state = %{
        agent_id: agent_id,
        task_id: task_id,
        restoration_mode: false,
        model_histories: %{model_id => small_history},
        context_lessons: %{},
        model_states: %{},
        system_prompt: large_system_prompt,
        prompt_fields: %{system_prompt: large_system_prompt},
        config: %{"model_pool" => [model_id]},
        children: [],
        todos: [],
        active_skills: [],
        skills_path: nil,
        pending_actions: %{},
        queued_messages: [],
        consensus_scheduled: false,
        wait_timer: nil,
        consensus_retry_count: 0,
        max_refinement_rounds: 4
      }

      captured = :ets.new(:"captured_#{System.unique_integer([:positive])}", [:set, :public])

      mock_query_fn = fn _messages, _models, opts ->
        :ets.insert(captured, {:max_tokens, Map.get(opts, :max_tokens)})

        response_json =
          Jason.encode!(%{"action" => "wait", "params" => %{}, "reasoning" => "Done"})

        {:ok,
         %{
           successful_responses: [%{model: model_id, content: response_json}],
           failed_models: []
         }}
      end

      opts = [
        model_query_fn: mock_query_fn,
        reflector_fn: fn _messages, _model_id, _opts ->
          {:ok, %{lessons: [], state: []}}
        end,
        test_mode: true
      ]

      # Query should succeed even when context is tight
      assert {:ok, _response, _state} =
               PerModelQuery.query_single_model_with_retry(state, model_id, opts)

      # max_tokens should be positive (whatever space is available)
      [{:max_tokens, actual_max_tokens}] = :ets.lookup(captured, :max_tokens)
      :ets.delete(captured)

      assert is_integer(actual_max_tokens) and actual_max_tokens > 0,
             "max_tokens should be positive even when context is tight"
    end
  end

  describe "dead 4096 removed from build_opts" do
    test "build_query_options does not hardcode max_tokens: 4096" do
      model_id = "anthropic:claude-sonnet-4"
      opts = []

      # build_query_options currently has max_tokens: Keyword.get(opts, :max_tokens, 4096)
      # After implementation, it should NOT default to 4096 — caller provides via calculate_max_tokens
      result = PerModelQuery.build_query_options(model_id, opts)

      # The dead default max_tokens: 4096 should be removed
      # After fix: either no max_tokens key, or max_tokens comes from opts (not hardcoded)
      # This will FAIL because current code still has the 4096 default
      refute Map.get(result, :max_tokens) == 4096,
             "build_query_options should not hardcode max_tokens: 4096 — caller must provide"
    end

    test "build_query_options passes through caller-provided max_tokens" do
      model_id = "anthropic:claude-sonnet-4"
      opts = [max_tokens: 50_000]

      result = PerModelQuery.build_query_options(model_id, opts)

      # Caller-provided max_tokens should pass through
      assert result.max_tokens == 50_000,
             "build_query_options should pass through caller-provided max_tokens"
    end
  end

  describe "retry path uses dynamic max_tokens" do
    setup :setup_db_records

    test "retry after context_length_exceeded recalculates max_tokens", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "anthropic:claude-sonnet-4"
      state = build_state(agent_id, task_id, model_id, history_count: 10)

      call_count = :ets.new(:"call_count_#{System.unique_integer([:positive])}", [:set, :public])
      :ets.insert(call_count, {:count, 0})

      captured_max_tokens =
        :ets.new(:"captured_mt_#{System.unique_integer([:positive])}", [:ordered_set, :public])

      mock_query_fn = fn _messages, _models, opts ->
        [{:count, count}] = :ets.lookup(call_count, :count)
        :ets.insert(call_count, {:count, count + 1})
        :ets.insert(captured_max_tokens, {count, Map.get(opts, :max_tokens)})

        if count == 0 do
          # First call: simulate context_length_exceeded
          {:ok,
           %{
             successful_responses: [],
             failed_models: [{model_id, :context_length_exceeded}]
           }}
        else
          # Retry: succeed
          response_json =
            Jason.encode!(%{
              "action" => "wait",
              "params" => %{},
              "reasoning" => "Success on retry"
            })

          {:ok,
           %{
             successful_responses: [%{model: model_id, content: response_json}],
             failed_models: []
           }}
        end
      end

      opts = [
        model_query_fn: mock_query_fn,
        reflector_fn: fn _messages, _model_id, _opts ->
          {:ok, %{lessons: [], state: []}}
        end,
        test_mode: true
      ]

      {:ok, _response, _result_state} =
        PerModelQuery.query_single_model_with_retry(state, model_id, opts)

      # Both the initial call and the retry should have max_tokens
      # The retry max_tokens should be recalculated after condensation
      entries = :ets.tab2list(captured_max_tokens)
      :ets.delete(call_count)
      :ets.delete(captured_max_tokens)

      assert length(entries) >= 2, "Should have made at least 2 queries (initial + retry)"

      [{0, first_max_tokens}, {1, retry_max_tokens}] = Enum.sort(entries)

      # Both should have dynamic max_tokens (not nil, not the old 4096)
      assert is_integer(first_max_tokens),
             "First query should have dynamically calculated max_tokens"

      assert is_integer(retry_max_tokens),
             "Retry query should have dynamically calculated max_tokens"

      # After condensation, retry max_tokens should differ from first
      # (condensation reduces input_tokens, so available_output increases)
      assert retry_max_tokens != first_max_tokens,
             "Retry max_tokens should be recalculated after condensation"
    end
  end

  describe "max_tokens recalc after condense" do
    setup :setup_db_records

    test "recalculated max_tokens reflects condensed state", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      # When condensation happens (available < floor), max_tokens should be
      # recalculated using the new (shorter) messages
      model_id = "openrouter:openai/gpt-3.5-turbo-0613"

      large_history =
        Enum.map(15..1//-1, fn id ->
          %{
            id: id,
            role: if(rem(id, 2) == 1, do: "user", else: "assistant"),
            content: String.duplicate("word ", 250),
            timestamp: DateTime.utc_now()
          }
        end)

      state = %{
        agent_id: agent_id,
        task_id: task_id,
        restoration_mode: false,
        model_histories: %{model_id => large_history},
        context_lessons: %{},
        model_states: %{},
        system_prompt: "Short system prompt.",
        prompt_fields: %{system_prompt: "Short system prompt."},
        config: %{"model_pool" => [model_id]},
        children: [],
        todos: [],
        active_skills: [],
        skills_path: nil,
        pending_actions: %{},
        queued_messages: [],
        consensus_scheduled: false,
        wait_timer: nil,
        consensus_retry_count: 0,
        max_refinement_rounds: 4
      }

      captured_max_tokens =
        :ets.new(:"captured_mt2_#{System.unique_integer([:positive])}", [:set, :public])

      mock_query_fn = fn _messages, _models, opts ->
        :ets.insert(captured_max_tokens, {:max_tokens, Map.get(opts, :max_tokens)})

        response_json =
          Jason.encode!(%{"action" => "wait", "params" => %{}, "reasoning" => "Done"})

        {:ok,
         %{
           successful_responses: [%{model: model_id, content: response_json}],
           failed_models: []
         }}
      end

      opts = [
        model_query_fn: mock_query_fn,
        reflector_fn: fn _messages, _model_id, _opts ->
          {:ok, %{lessons: [], state: []}}
        end,
        test_mode: true
      ]

      # After condensation, the max_tokens passed to query should reflect
      # the reduced input size
      {:ok, _response, _state} =
        PerModelQuery.query_single_model_with_retry(state, model_id, opts)

      [{:max_tokens, actual_max_tokens}] = :ets.lookup(captured_max_tokens, :max_tokens)
      :ets.delete(captured_max_tokens)

      # max_tokens should be positive and dynamically calculated
      assert is_integer(actual_max_tokens)

      assert actual_max_tokens > 0,
             "max_tokens should be recalculated to a positive value after condensation"

      # CRITICAL: Must NOT be the old hardcoded 4096 default
      assert actual_max_tokens != 4096,
             "max_tokens should be dynamically calculated, not the old static 4096 default"
    end
  end
end
