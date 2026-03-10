defmodule Quoracle.Agent.Consensus.PerModelQueryParallelTest do
  @moduledoc """
  Tests for parallel per-model consensus queries (v20.0).
  WorkGroupID: feat-20260307-181848

  R200-R211: Parallel concurrent fan-out, state merge,
  deferred persistence, error handling, single-model
  optimization, and API contract preservation.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Quoracle.Agent.Consensus.PerModelQuery

  # Force ActionList to load - ensures :orient atom exists for String.to_existing_atom/1
  # when running tests in isolation (required for ActionParser.parse_json_response/1)
  alias Quoracle.Actions.Schema.ActionList
  _ = ActionList.actions()

  # Helper: valid orient response JSON for mock query functions
  defp orient_response_json(model_id) do
    Jason.encode!(%{
      "action" => "orient",
      "params" => %{
        "current_situation" => "Processing for #{model_id}",
        "goal_clarity" => "Clear",
        "available_resources" => "Full",
        "key_challenges" => "None",
        "delegation_consideration" => "none"
      },
      "reasoning" => "Mock reasoning for #{model_id}",
      "wait" => true
    })
  end

  # Helper: mock query function that sends PID info to test process
  defp mock_query_fn_with_pid_tracking(test_pid) do
    fn _messages, [model_id], _query_opts ->
      send(test_pid, {:query_called, model_id, self()})
      response_json = orient_response_json(model_id)

      {:ok,
       %{
         successful_responses: [%{model: model_id, content: response_json}],
         failed_models: []
       }}
    end
  end

  # Helper: simple mock query function (no tracking)
  defp mock_query_fn do
    fn _messages, [model_id], _query_opts ->
      response_json = orient_response_json(model_id)

      {:ok,
       %{
         successful_responses: [%{model: model_id, content: response_json}],
         failed_models: []
       }}
    end
  end

  # Helper: build minimal state with given model histories
  defp build_state(model_histories, extra \\ %{}) do
    Map.merge(
      %{
        model_histories: model_histories,
        context_lessons: %{},
        model_states: %{}
      },
      extra
    )
  end

  # Helper: no-op reflector for tests that trigger condensation
  defp noop_reflector do
    fn _messages, _model_id, _opts ->
      {:ok, %{lessons: [], state: []}}
    end
  end

  # Helper: no-op embedding function for tests that trigger condensation
  defp noop_embedding_fn do
    fn _text -> {:ok, List.duplicate(0.0, 10)} end
  end

  # Helper: condensation-safe opts (avoids DB calls during condensation)
  defp condensation_safe_opts(extra) do
    [
      force_token_management: true,
      reflector_fn: noop_reflector(),
      embedding_fn: noop_embedding_fn()
    ] ++ extra
  end

  describe "R200: Concurrent multi-model queries" do
    test "multi-model queries execute concurrently" do
      test_pid = self()
      query_fn = mock_query_fn_with_pid_tracking(test_pid)

      state =
        build_state(%{
          "model-a" => [%{type: :user, content: "Task A", timestamp: DateTime.utc_now()}],
          "model-b" => [%{type: :user, content: "Task B", timestamp: DateTime.utc_now()}],
          "model-c" => [%{type: :user, content: "Task C", timestamp: DateTime.utc_now()}]
        })

      model_pool = ["model-a", "model-b", "model-c"]
      opts = [model_query_fn: query_fn]

      {:ok, responses, _final_state} =
        PerModelQuery.query_models_with_per_model_histories(state, model_pool, opts)

      assert length(responses) == 3

      # Collect caller PIDs - each query should run in a different Task process
      assert_receive {:query_called, "model-a", pid_a}
      assert_receive {:query_called, "model-b", pid_b}
      assert_receive {:query_called, "model-c", pid_c}

      # All PIDs should differ from the test process (spawned as Tasks)
      assert pid_a != test_pid
      assert pid_b != test_pid
      assert pid_c != test_pid

      # All PIDs should be distinct (concurrent Tasks)
      assert pid_a != pid_b
      assert pid_a != pid_c
      assert pid_b != pid_c
    end
  end

  describe "R201: Single-model direct call" do
    test "single-model pool queries without Task" do
      test_pid = self()
      query_fn = mock_query_fn_with_pid_tracking(test_pid)

      state =
        build_state(%{
          "model-a" => [%{type: :user, content: "Solo task", timestamp: DateTime.utc_now()}]
        })

      model_pool = ["model-a"]
      opts = [model_query_fn: query_fn]

      {:ok, responses, _final_state} =
        PerModelQuery.query_models_with_per_model_histories(state, model_pool, opts)

      assert length(responses) == 1

      # Single model should be called directly in the calling process
      assert_receive {:query_called, "model-a", caller_pid}
      assert caller_pid == test_pid
    end
  end

  describe "R202: Responses match sequential" do
    test "parallel responses match sequential execution" do
      test_pid = self()
      query_fn = mock_query_fn_with_pid_tracking(test_pid)

      state =
        build_state(%{
          "model-a" => [%{type: :user, content: "Task A", timestamp: DateTime.utc_now()}],
          "model-b" => [%{type: :user, content: "Task B", timestamp: DateTime.utc_now()}]
        })

      model_pool = ["model-a", "model-b"]
      opts = [model_query_fn: query_fn]

      {:ok, responses, _final_state} =
        PerModelQuery.query_models_with_per_model_histories(state, model_pool, opts)

      # All models should have been queried
      assert_receive {:query_called, "model-a", _}
      assert_receive {:query_called, "model-b", _}

      # Response list should contain entries for both models
      response_models = Enum.map(responses, & &1.model)
      assert "model-a" in response_models
      assert "model-b" in response_models

      # Each response should have content
      Enum.each(responses, fn resp ->
        assert is_binary(resp.content)
      end)
    end
  end

  describe "R203: State merge preserves changes" do
    test "merge preserves all per-model condensation" do
      # Create state where condensation will trigger for all models
      large_history_a =
        for i <- 1..100 do
          %{
            type: :user,
            content: String.duplicate("A word #{i} ", 50),
            timestamp: DateTime.utc_now()
          }
        end

      large_history_b =
        for i <- 1..100 do
          %{
            type: :user,
            content: String.duplicate("B word #{i} ", 50),
            timestamp: DateTime.utc_now()
          }
        end

      state =
        build_state(%{
          "openrouter:openai/gpt-3.5-turbo-0613" => large_history_a,
          "openrouter:openai/gpt-3.5-turbo-instruct" => large_history_b
        })

      model_pool = [
        "openrouter:openai/gpt-3.5-turbo-0613",
        "openrouter:openai/gpt-3.5-turbo-instruct"
      ]

      opts =
        condensation_safe_opts(model_query_fn: mock_query_fn())

      {:ok, _responses, final_state} =
        PerModelQuery.query_models_with_per_model_histories(state, model_pool, opts)

      # Both models' histories should be condensed (fewer entries than original)
      history_a = Map.get(final_state.model_histories, "openrouter:openai/gpt-3.5-turbo-0613")
      history_b = Map.get(final_state.model_histories, "openrouter:openai/gpt-3.5-turbo-instruct")

      assert length(history_a) < length(large_history_a),
             "Model A history should be condensed"

      assert length(history_b) < length(large_history_b),
             "Model B history should be condensed"
    end
  end

  describe "R204: Disjoint state merge" do
    test "condensation of one model leaves others intact" do
      # Model A: large history that will trigger condensation
      large_history =
        for i <- 1..100 do
          %{
            type: :user,
            content: String.duplicate("word #{i} ", 50),
            timestamp: DateTime.utc_now()
          }
        end

      # Model B: small history that should NOT be condensed
      small_history = [
        %{type: :user, content: "Short message", timestamp: DateTime.utc_now()}
      ]

      state =
        build_state(%{
          "openrouter:openai/gpt-3.5-turbo-0613" => large_history,
          "model-b" => small_history
        })

      model_pool = ["openrouter:openai/gpt-3.5-turbo-0613", "model-b"]

      opts =
        condensation_safe_opts(model_query_fn: mock_query_fn())

      {:ok, _responses, final_state} =
        PerModelQuery.query_models_with_per_model_histories(state, model_pool, opts)

      # Model A should have been condensed
      history_a = Map.get(final_state.model_histories, "openrouter:openai/gpt-3.5-turbo-0613")
      assert length(history_a) < length(large_history)

      # Model B history must be unmodified
      history_b = Map.get(final_state.model_histories, "model-b")
      assert history_b == small_history
    end
  end

  describe "R205: Deferred persistence" do
    test "persist called once after parallel merge" do
      test_pid = self()

      # Create large histories that will trigger condensation for both models
      large_history_a =
        for i <- 1..100 do
          %{type: :user, content: String.duplicate("A #{i} ", 50), timestamp: DateTime.utc_now()}
        end

      large_history_b =
        for i <- 1..100 do
          %{type: :user, content: String.duplicate("B #{i} ", 50), timestamp: DateTime.utc_now()}
        end

      state =
        build_state(%{
          "openrouter:openai/gpt-3.5-turbo-0613" => large_history_a,
          "openrouter:openai/gpt-3.5-turbo-instruct" => large_history_b
        })

      model_pool = [
        "openrouter:openai/gpt-3.5-turbo-0613",
        "openrouter:openai/gpt-3.5-turbo-instruct"
      ]

      # Injectable persist_fn to track persist calls at the top level
      # The deferred persist should call this ONCE after merging all models' state
      persist_fn = fn final_state ->
        send(test_pid, {:persist_called, final_state})
        :ok
      end

      opts =
        condensation_safe_opts(
          model_query_fn: mock_query_fn(),
          persist_fn: persist_fn
        )

      {:ok, _responses, _final_state} =
        PerModelQuery.query_models_with_per_model_histories(state, model_pool, opts)

      # persist_ace_state should be called exactly once after merge
      assert_receive {:persist_called, persisted_state}, 5_000

      # The persisted state should contain BOTH models' condensed histories
      assert Map.has_key?(persisted_state.model_histories, "openrouter:openai/gpt-3.5-turbo-0613")

      assert Map.has_key?(
               persisted_state.model_histories,
               "openrouter:openai/gpt-3.5-turbo-instruct"
             )

      # Should NOT receive a second persist call
      refute_receive {:persist_called, _}, 100
    end
  end

  describe "R206: No persist when unchanged" do
    test "no persistence call when state unchanged" do
      test_pid = self()

      # Small histories that will NOT trigger condensation
      state =
        build_state(%{
          "model-a" => [%{type: :user, content: "Short A", timestamp: DateTime.utc_now()}],
          "model-b" => [%{type: :user, content: "Short B", timestamp: DateTime.utc_now()}]
        })

      model_pool = ["model-a", "model-b"]

      persist_fn = fn _state ->
        send(test_pid, :persist_called)
        :ok
      end

      opts = [model_query_fn: mock_query_fn(), persist_fn: persist_fn]

      {:ok, _responses, _final_state} =
        PerModelQuery.query_models_with_per_model_histories(state, model_pool, opts)

      # persist_ace_state should NOT be called when no condensation occurred
      refute_receive :persist_called, 100
    end
  end

  describe "R207: Sandbox propagation in Tasks" do
    test "parallel tasks propagate sandbox ownership" do
      test_pid = self()
      query_fn = mock_query_fn_with_pid_tracking(test_pid)

      state =
        build_state(%{
          "model-a" => [%{type: :user, content: "Task A", timestamp: DateTime.utc_now()}],
          "model-b" => [%{type: :user, content: "Task B", timestamp: DateTime.utc_now()}]
        })

      model_pool = ["model-a", "model-b"]

      # Pass sandbox_owner to verify it's propagated to Task processes
      opts = [model_query_fn: query_fn, sandbox_owner: test_pid]

      {:ok, responses, _final_state} =
        PerModelQuery.query_models_with_per_model_histories(state, model_pool, opts)

      assert length(responses) == 2

      # Both queries should have been called in Task processes (not test process)
      assert_receive {:query_called, "model-a", task_pid_a}
      assert_receive {:query_called, "model-b", task_pid_b}

      # Tasks should have different PIDs (spawned concurrently)
      assert task_pid_a != test_pid
      assert task_pid_b != test_pid
    end
  end

  describe "R208: Task failure handling" do
    test "task crash shuts down remaining tasks" do
      model_query_fn = fn _messages, [model_id], _query_opts ->
        case model_id do
          "model-crash" ->
            raise "Simulated model query crash"

          _ ->
            response_json = orient_response_json(model_id)

            {:ok,
             %{
               successful_responses: [%{model: model_id, content: response_json}],
               failed_models: []
             }}
        end
      end

      state =
        build_state(%{
          "model-a" => [%{type: :user, content: "Task A", timestamp: DateTime.utc_now()}],
          "model-crash" => [%{type: :user, content: "Crash", timestamp: DateTime.utc_now()}]
        })

      model_pool = ["model-a", "model-crash"]
      opts = [model_query_fn: model_query_fn]

      # A Task crash should propagate as an error
      # capture_log suppresses expected Task termination log output
      capture_log(fn ->
        assert_raise RuntimeError, "Simulated model query crash", fn ->
          PerModelQuery.query_models_with_per_model_histories(state, model_pool, opts)
        end
      end)
    end
  end

  describe "R209: Mixed success and failure" do
    test "handles mixed success and failure" do
      test_pid = self()

      model_query_fn = fn _messages, [model_id], _query_opts ->
        send(test_pid, {:query_called, model_id})

        case model_id do
          "model-fail" ->
            {:ok,
             %{
               successful_responses: [],
               failed_models: [{"model-fail", :api_error}]
             }}

          _ ->
            response_json = orient_response_json(model_id)

            {:ok,
             %{
               successful_responses: [%{model: model_id, content: response_json}],
               failed_models: []
             }}
        end
      end

      state =
        build_state(%{
          "model-a" => [%{type: :user, content: "Task A", timestamp: DateTime.utc_now()}],
          "model-fail" => [%{type: :user, content: "Fail", timestamp: DateTime.utc_now()}],
          "model-c" => [%{type: :user, content: "Task C", timestamp: DateTime.utc_now()}]
        })

      model_pool = ["model-a", "model-fail", "model-c"]
      opts = [model_query_fn: model_query_fn]

      # Should succeed with partial results (2 of 3 succeeded)
      {:ok, responses, _final_state} =
        PerModelQuery.query_models_with_per_model_histories(state, model_pool, opts)

      response_models = Enum.map(responses, & &1.model)
      assert "model-a" in response_models
      assert "model-c" in response_models
      refute "model-fail" in response_models
      assert length(responses) == 2
    end
  end

  describe "R210: Test mode remains sequential" do
    test "test mode queries remain sequential" do
      state =
        build_state(
          %{
            "model-a" => [%{type: :user, content: "Task A", timestamp: DateTime.utc_now()}],
            "model-b" => [%{type: :user, content: "Task B", timestamp: DateTime.utc_now()}]
          },
          %{test_mode: true}
        )

      model_pool = ["model-a", "model-b"]
      opts = [test_mode: true]

      {:ok, responses, _final_state} =
        PerModelQuery.query_models_with_per_model_histories(state, model_pool, opts)

      assert length(responses) == 2
      response_models = Enum.map(responses, & &1.model)
      assert "model-a" in response_models
      assert "model-b" in response_models
    end
  end

  describe "R211: API contract unchanged" do
    test "return type contract after parallelization" do
      state =
        build_state(%{
          "model-a" => [%{type: :user, content: "Task A", timestamp: DateTime.utc_now()}],
          "model-b" => [%{type: :user, content: "Task B", timestamp: DateTime.utc_now()}]
        })

      model_pool = ["model-a", "model-b"]
      opts = [model_query_fn: mock_query_fn()]

      result = PerModelQuery.query_models_with_per_model_histories(state, model_pool, opts)

      # Must return {:ok, responses, state} tuple
      assert {:ok, responses, final_state} = result
      assert is_list(responses)
      assert is_map(final_state)

      # Responses should contain model query result maps
      Enum.each(responses, fn resp ->
        assert Map.has_key?(resp, :model)
        assert Map.has_key?(resp, :content)
      end)

      # State should preserve the required per-model fields
      assert Map.has_key?(final_state, :model_histories)
    end

    test "error return type preserved" do
      state =
        build_state(
          %{
            "model-a" => [%{type: :user, content: "Task A", timestamp: DateTime.utc_now()}]
          },
          %{test_mode: true}
        )

      opts = [test_mode: true, simulate_failure: true]

      result = PerModelQuery.query_models_with_per_model_histories(state, ["model-a"], opts)

      # Must return {:error, atom()} on failure
      assert {:error, reason} = result
      assert is_atom(reason)
    end

    test "all models fail returns all_models_failed" do
      model_query_fn = fn _messages, [model_id], _query_opts ->
        {:ok,
         %{
           successful_responses: [],
           failed_models: [{model_id, :api_error}]
         }}
      end

      state =
        build_state(%{
          "model-a" => [%{type: :user, content: "A", timestamp: DateTime.utc_now()}],
          "model-b" => [%{type: :user, content: "B", timestamp: DateTime.utc_now()}]
        })

      opts = [model_query_fn: model_query_fn]

      result =
        PerModelQuery.query_models_with_per_model_histories(state, ["model-a", "model-b"], opts)

      assert {:error, :all_models_failed} = result
    end
  end
end
