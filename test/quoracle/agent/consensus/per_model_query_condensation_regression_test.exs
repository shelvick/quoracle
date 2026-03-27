defmodule Quoracle.Agent.Consensus.PerModelQueryCondensationRegressionTest do
  @moduledoc """
  Regression tests for FEAT_CondenseParam v3.0 (Packet 2).

  WorkGroupID: wip-20260301-condensation-progress
  Scope: Batched reflection + recursive summarization for oversized entries.
  """

  use Quoracle.DataCase, async: true

  import Test.IsolationHelpers
  import Test.AgentTestHelpers

  alias Quoracle.Agent.Consensus.PerModelQuery.Condensation
  alias Quoracle.Agent.Core
  alias Quoracle.Agent.TokenManager
  alias Quoracle.Agents.Agent, as: AgentSchema
  alias Quoracle.Repo
  alias Quoracle.Tasks.Task

  setup do
    {:ok, task} =
      Repo.insert(Task.changeset(%Task{}, %{prompt: "Packet 2 test", status: "running"}))

    agent_id = "packet2-condense-#{System.unique_integer([:positive])}"

    {:ok, _agent} =
      Repo.insert(%AgentSchema{
        agent_id: agent_id,
        task_id: task.id,
        status: "running",
        parent_id: nil,
        config: %{},
        state: nil,
        inserted_at: ~N[2025-01-01 10:00:00]
      })

    %{agent_id: agent_id, task_id: task.id}
  end

  defp history_entry(id, content) do
    %{id: id, type: :event, content: content, timestamp: DateTime.utc_now()}
  end

  defp oldest_first_entries(count, words_per_entry) do
    Enum.map(1..count, fn id ->
      history_entry(id, "entry-#{id} " <> String.duplicate("token ", words_per_entry))
    end)
  end

  defp newest_first_entries(count, words_per_entry \\ 80) do
    Enum.map(count..1//-1, fn id ->
      history_entry(id, "entry-#{id} " <> String.duplicate("token ", words_per_entry))
    end)
  end

  defp build_state(agent_id, task_id, model_id, history) do
    %{
      agent_id: agent_id,
      task_id: task_id,
      restoration_mode: false,
      model_histories: %{model_id => history},
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
  end

  defp drain_tagged(tag), do: drain_tagged(tag, [])

  defp drain_tagged(tag, acc) do
    receive do
      {^tag, payload} -> drain_tagged(tag, [payload | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # ============================================================================
  # R29-R34: Batched reflection
  # ============================================================================

  describe "R29-R34 batched reflection" do
    test "R29 single batch when to_discard fits reflection budget", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "anthropic:claude-sonnet-4"
      state = build_state(agent_id, task_id, model_id, newest_first_entries(4))
      to_discard = oldest_first_entries(2, 30)
      to_keep = newest_first_entries(2, 20)
      call_counter = :counters.new(1, [])

      opts = [
        max_batch_tokens: 10_000,
        test_mode: true,
        reflector_fn: fn messages, _model_id, _opts ->
          :counters.add(call_counter, 1, 1)
          send(self(), {:r29_batch, Enum.map(messages, & &1.content)})
          {:ok, %{lessons: [%{type: :factual, content: "r29", confidence: 1}], state: []}}
        end
      ]

      result =
        Condensation.apply_reflection_and_finalize(state, model_id, to_discard, to_keep, opts)

      lessons = Map.get(result.context_lessons, model_id, [])
      assert Enum.any?(lessons, &(&1.content == "r29"))
      assert result.model_histories[model_id] == to_keep
      assert :counters.get(call_counter, 1) == 1
      assert drain_tagged(:r29_batch) == [Enum.map(to_discard, & &1.content)]
    end

    test "R30 creates multiple batches when to_discard exceeds budget", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "anthropic:claude-sonnet-4"
      state = build_state(agent_id, task_id, model_id, newest_first_entries(6))
      to_discard = oldest_first_entries(4, 120)
      to_keep = newest_first_entries(2, 20)

      opts = [
        max_batch_tokens: 150,
        test_mode: true,
        reflector_fn: fn messages, _model_id, _opts ->
          send(self(), {:r30_batch, messages})

          {:ok,
           %{lessons: [%{type: :factual, content: "r30-reflection", confidence: 1}], state: []}}
        end
      ]

      result =
        Condensation.apply_reflection_and_finalize(state, model_id, to_discard, to_keep, opts)

      batches = drain_tagged(:r30_batch)

      assert length(batches) >= 2

      assert Enum.all?(batches, fn batch ->
               batch
               |> Enum.map_join(" ", & &1.content)
               |> TokenManager.estimate_tokens() <= 150
             end)

      assert result.model_histories[model_id] == to_keep
    end

    test "R31 accumulates lessons across reflection batches", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "anthropic:claude-sonnet-4"
      state = build_state(agent_id, task_id, model_id, newest_first_entries(6))
      to_discard = oldest_first_entries(4, 100)
      to_keep = newest_first_entries(2, 20)
      call_counter = :counters.new(1, [])

      opts = [
        max_batch_tokens: 150,
        test_mode: true,
        reflector_fn: fn _messages, _model_id, _opts ->
          :counters.add(call_counter, 1, 1)
          n = :counters.get(call_counter, 1)

          {:ok,
           %{
             lessons: [%{type: :factual, content: "lesson-from-batch-#{n}", confidence: 1}],
             state: []
           }}
        end
      ]

      result =
        Condensation.apply_reflection_and_finalize(state, model_id, to_discard, to_keep, opts)

      lessons = Map.get(result.context_lessons, model_id, [])
      assert :counters.get(call_counter, 1) >= 2
      assert Enum.any?(lessons, &(&1.content == "lesson-from-batch-1"))
      assert Enum.any?(lessons, &(&1.content == "lesson-from-batch-2"))
    end

    test "R32 continues processing remaining batches after one fails", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "anthropic:claude-sonnet-4"
      state = build_state(agent_id, task_id, model_id, newest_first_entries(6))
      to_discard = oldest_first_entries(4, 120)
      to_keep = newest_first_entries(2, 20)
      call_counter = :counters.new(1, [])

      opts = [
        max_batch_tokens: 150,
        test_mode: true,
        reflector_fn: fn _messages, _model_id, _opts ->
          :counters.add(call_counter, 1, 1)

          case :counters.get(call_counter, 1) do
            1 ->
              {:error, :reflection_failed}

            n ->
              {:ok,
               %{lessons: [%{type: :factual, content: "batch-#{n}-ok", confidence: 1}], state: []}}
          end
        end
      ]

      result =
        Condensation.apply_reflection_and_finalize(state, model_id, to_discard, to_keep, opts)

      lessons = Map.get(result.context_lessons, model_id, [])
      assert :counters.get(call_counter, 1) >= 2
      assert Enum.any?(lessons, &(&1.content == "batch-2-ok"))

      assert Enum.any?(lessons, fn lesson ->
               String.contains?(lesson.content, "Unreflected content discarded")
             end)
    end

    test "R33 context_lessons and model_states updated after all batches", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "anthropic:claude-sonnet-4"
      state = build_state(agent_id, task_id, model_id, newest_first_entries(6))
      to_discard = oldest_first_entries(4, 80)
      to_keep = newest_first_entries(2, 20)
      call_counter = :counters.new(1, [])

      opts = [
        max_batch_tokens: 150,
        test_mode: true,
        reflector_fn: fn _messages, _model_id, _opts ->
          :counters.add(call_counter, 1, 1)
          n = :counters.get(call_counter, 1)

          {:ok,
           %{
             lessons: [%{type: :factual, content: "r33-lesson-#{n}", confidence: 1}],
             state: [%{summary: "r33-state-#{n}", updated_at: DateTime.utc_now()}]
           }}
        end
      ]

      result =
        Condensation.apply_reflection_and_finalize(state, model_id, to_discard, to_keep, opts)

      calls = :counters.get(call_counter, 1)
      assert calls >= 2
      assert Map.has_key?(result.context_lessons, model_id)
      assert Map.has_key?(result.model_states, model_id)
      assert result.model_states[model_id].summary == "r33-state-#{calls}"
      assert Enum.any?(result.context_lessons[model_id], &(&1.content == "r33-lesson-1"))
    end

    test "R34 preserves chronological order across batches", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "anthropic:claude-sonnet-4"
      state = build_state(agent_id, task_id, model_id, newest_first_entries(6))

      to_discard = [
        history_entry(1, "oldest-1 " <> String.duplicate("a ", 80)),
        history_entry(2, "oldest-2 " <> String.duplicate("b ", 80)),
        history_entry(3, "newer-3 " <> String.duplicate("c ", 80)),
        history_entry(4, "newer-4 " <> String.duplicate("d ", 80))
      ]

      opts = [
        max_batch_tokens: 150,
        test_mode: true,
        reflector_fn: fn messages, _model_id, _opts ->
          send(self(), {:r34_batch, Enum.map(messages, & &1.content)})
          {:ok, %{lessons: [], state: []}}
        end
      ]

      _ = Condensation.apply_reflection_and_finalize(state, model_id, to_discard, [], opts)
      batches = drain_tagged(:r34_batch)

      assert length(batches) >= 2
      assert List.flatten(batches) == Enum.map(to_discard, & &1.content)
      assert hd(hd(batches)) == hd(Enum.map(to_discard, & &1.content))
    end
  end

  # ============================================================================
  # R35-R40: Recursive pre-summarization
  # ============================================================================

  describe "R35-R40 recursive pre-summarization" do
    test "R35 pre-summarizes oversized entry before reflection", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "openrouter:openai/gpt-3.5-turbo-0613"
      state = build_state(agent_id, task_id, model_id, newest_first_entries(2, 20))

      oversized = [
        history_entry(
          1,
          String.duplicate("Very long paragraph with details.\n\n", 600)
        )
      ]

      opts = [
        max_batch_tokens: 50,
        test_mode: true,
        summarization_model: "anthropic:claude-sonnet-4",
        summarize_fn: fn content, _model, _opts ->
          send(self(), {:r35_summarize, content})
          {:ok, "condensed-#{String.slice(content, 0, 30)}"}
        end,
        reflector_fn: fn messages, _model_id, _opts ->
          send(self(), {:r35_reflector, messages})
          {:ok, %{lessons: [%{type: :factual, content: "r35", confidence: 1}], state: []}}
        end
      ]

      _ = Condensation.apply_reflection_and_finalize(state, model_id, oversized, [], opts)

      assert drain_tagged(:r35_summarize) != []
      [first_reflection_batch | _] = drain_tagged(:r35_reflector)
      assert Enum.all?(first_reflection_batch, &(TokenManager.estimate_tokens(&1.content) <= 50))
    end

    test "R36 recursively summarizes until within budget", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "anthropic:claude-sonnet-4"
      state = build_state(agent_id, task_id, model_id, newest_first_entries(2, 20))
      oversized = [history_entry(1, String.duplicate("word ", 500))]

      opts = [
        max_batch_tokens: 40,
        test_mode: true,
        summarization_model: "anthropic:claude-sonnet-4",
        summarize_fn: fn content, _model, _opts ->
          send(self(), {:r36_summarize, content})

          tokens = TokenManager.estimate_tokens(content)

          # Always reduce — use div(tokens, 3) words so recursive rounds converge
          {:ok, String.duplicate("s ", max(div(tokens, 3), 1))}
        end,
        reflector_fn: fn messages, _model_id, _opts ->
          send(self(), {:r36_reflector, messages})
          {:ok, %{lessons: [], state: []}}
        end
      ]

      _ = Condensation.apply_reflection_and_finalize(state, model_id, oversized, [], opts)

      assert length(drain_tagged(:r36_summarize)) >= 2
      [first_reflection_batch | _] = drain_tagged(:r36_reflector)
      assert Enum.all?(first_reflection_batch, &(TokenManager.estimate_tokens(&1.content) <= 40))
    end

    test "R37 splits content at semantic boundaries before summarizing", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "anthropic:claude-sonnet-4"
      state = build_state(agent_id, task_id, model_id, newest_first_entries(2, 20))

      content =
        "Paragraph one about topic A.\n\n" <>
          "Paragraph two about topic B.\n\n" <>
          "Paragraph three about topic C."

      oversized = [history_entry(1, content)]

      opts = [
        max_batch_tokens: 10,
        test_mode: true,
        summarization_model: "anthropic:claude-sonnet-4",
        summarize_fn: fn chunk, _model, _opts ->
          send(self(), {:r37_chunk, chunk})
          {:ok, "ok"}
        end,
        reflector_fn: fn _messages, _model_id, _opts ->
          {:ok, %{lessons: [], state: []}}
        end
      ]

      _ = Condensation.apply_reflection_and_finalize(state, model_id, oversized, [], opts)

      chunks = drain_tagged(:r37_chunk)

      assert Enum.any?(chunks, &String.contains?(&1, "Paragraph one"))
      assert Enum.any?(chunks, &String.contains?(&1, "Paragraph two"))
      assert Enum.any?(chunks, &String.contains?(&1, "Paragraph three"))
    end

    test "R38 uses configured summarization model for pre-summarization", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "anthropic:claude-sonnet-4"
      state = build_state(agent_id, task_id, model_id, newest_first_entries(2, 20))
      oversized = [history_entry(1, String.duplicate("word ", 500))]

      # Set via ConfigModelSettings — sandbox rollback handles cleanup automatically,
      # no on_exit needed (on_exit runs in ExUnit.OnExitHandler without sandbox access).
      {:ok, _} =
        Quoracle.Models.ConfigModelSettings.set_summarization_model("anthropic:claude-sonnet-4")

      # No summarization_model in opts — falls through to ConfigModelSettings production path
      opts = [
        max_batch_tokens: 40,
        test_mode: true,
        summarize_fn: fn _content, model, _opts ->
          send(self(), {:r38_model, model})
          {:ok, "short summary"}
        end,
        reflector_fn: fn _messages, _model_id, _opts ->
          {:ok, %{lessons: [], state: []}}
        end
      ]

      _ = Condensation.apply_reflection_and_finalize(state, model_id, oversized, [], opts)

      used_models = drain_tagged(:r38_model)
      assert used_models != []
      assert Enum.all?(used_models, &(&1 == "anthropic:claude-sonnet-4"))
    end

    test "R39 stops recursion at max depth and uses fallback", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "anthropic:claude-sonnet-4"
      state = build_state(agent_id, task_id, model_id, newest_first_entries(2, 20))
      oversized = [history_entry(1, String.duplicate("word ", 500))]

      opts = [
        max_batch_tokens: 20,
        max_summarize_depth: 2,
        test_mode: true,
        summarization_model: "anthropic:claude-sonnet-4",
        summarize_fn: fn _content, _model, _opts ->
          send(self(), {:r39_summarize_attempt, :called})
          {:ok, String.duplicate("still-too-long ", 300)}
        end,
        reflector_fn: fn _messages, _model_id, _opts ->
          {:ok, %{lessons: [], state: []}}
        end
      ]

      result =
        Condensation.apply_reflection_and_finalize(
          state,
          model_id,
          oversized,
          [],
          opts
        )

      # Summarization was attempted (called per-chunk-per-depth-level, not once per level)
      assert length(drain_tagged(:r39_summarize_attempt)) >= 2

      assert Enum.any?(result.context_lessons[model_id], fn lesson ->
               String.contains?(lesson.content, "Unreflected content discarded")
             end)
    end

    test "R40 creates fallback artifact when summarization model not configured", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "anthropic:claude-sonnet-4"
      state = build_state(agent_id, task_id, model_id, newest_first_entries(2, 20))
      oversized = [history_entry(1, String.duplicate("word ", 500))]

      # No summarization_model in opts → falls through to ConfigModelSettings which
      # returns {:error, :not_configured} in test env → fallback artifact created.
      # No global state mutation needed.
      opts = [
        max_batch_tokens: 20,
        test_mode: true,
        summarize_fn: fn _content, _model, _opts ->
          flunk("summarize_fn must not run when summarization model is missing")
        end,
        reflector_fn: fn _messages, _model_id, _opts ->
          {:ok, %{lessons: [], state: []}}
        end
      ]

      result =
        Condensation.apply_reflection_and_finalize(
          state,
          model_id,
          oversized,
          [],
          opts
        )

      assert Enum.any?(result.context_lessons[model_id], fn lesson ->
               String.contains?(lesson.content, "Unreflected content discarded")
             end)
    end
  end

  # ============================================================================
  # R41-R43: Fallback artifact invariants
  # ============================================================================

  describe "R41-R43 fallback artifact invariants" do
    test "R41 creates fallback artifact when a reflection batch fails", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "anthropic:claude-sonnet-4"
      state = build_state(agent_id, task_id, model_id, newest_first_entries(6))
      to_discard = oldest_first_entries(4, 120)
      to_keep = newest_first_entries(2, 20)
      call_counter = :counters.new(1, [])

      opts = [
        max_batch_tokens: 150,
        test_mode: true,
        reflector_fn: fn _messages, _model_id, _opts ->
          :counters.add(call_counter, 1, 1)

          case :counters.get(call_counter, 1) do
            1 ->
              {:error, :reflection_failed}

            _ ->
              {:ok,
               %{lessons: [%{type: :factual, content: "normal-lesson", confidence: 2}], state: []}}
          end
        end
      ]

      result =
        Condensation.apply_reflection_and_finalize(state, model_id, to_discard, to_keep, opts)

      lessons = Map.get(result.context_lessons, model_id, [])

      assert Enum.any?(lessons, &(&1.content == "normal-lesson"))

      assert Enum.any?(lessons, fn lesson ->
               String.contains?(lesson.content, "Unreflected content discarded")
             end)
    end

    test "R42 fallback artifact has expected shape and truncated content", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "anthropic:claude-sonnet-4"
      state = build_state(agent_id, task_id, model_id, newest_first_entries(5))

      long_content =
        "BEGIN-" <>
          String.duplicate("x", 1200) <> "-END"

      opts = [
        max_batch_tokens: 100,
        test_mode: true,
        reflector_fn: fn _messages, _model_id, _opts ->
          {:error, :always_fail}
        end
      ]

      result =
        Condensation.apply_reflection_and_finalize(
          state,
          model_id,
          [history_entry(1, long_content)],
          newest_first_entries(2),
          opts
        )

      [fallback | _] = Map.get(result.context_lessons, model_id, [])

      expected_tokens = TokenManager.estimate_tokens(long_content)

      assert fallback.type == :factual
      assert fallback.confidence == 0
      assert String.contains?(fallback.content, "Unreflected content discarded")
      assert String.contains?(fallback.content, "#{expected_tokens}")
      assert String.contains?(fallback.content, String.slice(long_content, 0, 500))
    end

    test "R43 every discarded batch produces lessons or fallback artifact", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "anthropic:claude-sonnet-4"
      state = build_state(agent_id, task_id, model_id, newest_first_entries(6))
      to_discard = oldest_first_entries(4, 120)

      opts = [
        max_batch_tokens: 150,
        test_mode: true,
        reflector_fn: fn _messages, _model_id, _opts ->
          {:error, :forced_failure}
        end
      ]

      result = Condensation.apply_reflection_and_finalize(state, model_id, to_discard, [], opts)
      lessons = Map.get(result.context_lessons, model_id, [])

      assert length(lessons) >= 2

      assert Enum.all?(lessons, fn lesson ->
               String.contains?(lesson.content, "Unreflected content discarded")
             end)
    end
  end

  # ============================================================================
  # R44-R45: Finalization invariants
  # ============================================================================

  describe "R44-R45 finalization invariants" do
    test "R44 history updated with to_keep after batched reflection", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      model_id = "anthropic:claude-sonnet-4"
      to_keep = newest_first_entries(3, 20)
      to_discard = oldest_first_entries(4, 120)
      state = build_state(agent_id, task_id, model_id, to_discard ++ to_keep)

      opts = [
        max_batch_tokens: 150,
        test_mode: true,
        reflector_fn: fn _messages, _model_id, _opts ->
          {:ok, %{lessons: [], state: []}}
        end
      ]

      result =
        Condensation.apply_reflection_and_finalize(state, model_id, to_discard, to_keep, opts)

      assert result.model_histories[model_id] == to_keep
    end

    test "R45 persist called once after all batches complete", %{
      agent_id: agent_id,
      task_id: task_id
    } do
      test_pid = self()
      model_id = "anthropic:claude-sonnet-4"
      state = build_state(agent_id, task_id, model_id, newest_first_entries(6))
      to_discard = oldest_first_entries(4, 120)
      to_keep = newest_first_entries(2, 20)

      # Use persist_fn injection instead of global telemetry to avoid catching
      # UPDATE queries from other parallel tests (concurrency-safe).
      opts = [
        max_batch_tokens: 150,
        test_mode: true,
        reflector_fn: fn _messages, _model_id, _opts ->
          {:ok, %{lessons: [%{type: :factual, content: "r45-lesson", confidence: 1}], state: []}}
        end,
        persist_fn: fn _state ->
          send(test_pid, {:r45_persist_called, :ok})
          :ok
        end
      ]

      result =
        Condensation.apply_reflection_and_finalize(state, model_id, to_discard, to_keep, opts)

      persist_calls = drain_tagged(:r45_persist_called)

      assert result.model_histories[model_id] == to_keep
      assert length(persist_calls) == 1
    end
  end

  # ============================================================================
  # R46-R47: System acceptance (real system boundary via Core GenServer)
  # ============================================================================

  describe "R46-R47 system acceptance" do
    setup %{sandbox_owner: sandbox_owner, task_id: task_id} do
      deps = create_isolated_deps()
      [deps: deps, task_id: task_id, sandbox_owner: sandbox_owner]
    end

    @tag :acceptance
    @tag :integration
    test "R46 batched condensation restores positive output budget", %{
      agent_id: agent_id,
      task_id: task_id,
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      test_pid = self()
      model_id = "openrouter:openai/gpt-3.5-turbo-0613"
      large_history = newest_first_entries(120, 400)

      config = %{
        agent_id: agent_id,
        task_id: task_id,
        task_description: "R46 condensation budget acceptance",
        model_pool: [model_id],
        model_histories: %{model_id => large_history},
        context_lessons: %{model_id => []},
        model_states: %{model_id => nil},
        registry: deps.registry,
        dynsup: deps.dynsup,
        pubsub: deps.pubsub,
        sandbox_owner: sandbox_owner,
        test_mode: true,
        test_opts: [
          max_batch_tokens: 1000,
          model_query_fn: fn messages, _models, opts ->
            send(test_pid, {:r46_query, length(messages), Map.get(opts, :max_tokens)})

            response_json =
              Jason.encode!(%{"action" => "wait", "params" => %{}, "reasoning" => "R46"})

            {:ok,
             %{
               successful_responses: [%{model: model_id, content: response_json}],
               failed_models: []
             }}
          end,
          reflector_fn: fn messages, _model_id, _opts ->
            send(test_pid, {:r46_batch, messages})

            {:ok,
             %{lessons: [%{type: :factual, content: "r46-lesson", confidence: 1}], state: []}}
          end
        ]
      }

      {:ok, agent_pid} =
        spawn_agent_with_cleanup(deps.dynsup, config, registry: deps.registry)

      {:ok, pre_state} = Core.get_state(agent_pid)
      pre_history = pre_state.model_histories[model_id]
      pre_tokens = TokenManager.estimate_history_tokens(pre_history)
      context_limit = TokenManager.get_model_context_limit(model_id)

      assert pre_tokens > context_limit

      Core.send_user_message(agent_pid, "continue")

      assert_receive {:r46_query, _msg_count, max_tokens}, 30_000
      assert is_integer(max_tokens) and max_tokens > 0

      {:ok, post_state} = Core.get_state(agent_pid)
      post_history = post_state.model_histories[model_id]
      post_tokens = TokenManager.estimate_history_tokens(post_history)
      available_output = context_limit - post_tokens
      reflection_batches = drain_tagged(:r46_batch)
      lessons = Map.get(post_state.context_lessons, model_id, [])

      assert pre_tokens > context_limit * 10
      assert length(post_history) < length(pre_history)
      assert available_output > 0
      assert length(reflection_batches) >= 2
      assert Enum.any?(lessons, &(&1.content == "r46-lesson"))
      refute post_history == pre_history
      refute max_tokens <= 0
    end

    @tag :acceptance
    @tag :integration
    test "R47 oversized entry summarized and output budget restored", %{
      agent_id: agent_id,
      task_id: task_id,
      deps: deps,
      sandbox_owner: sandbox_owner
    } do
      test_pid = self()
      model_id = "openrouter:openai/gpt-3.5-turbo-0613"

      oversized_oldest =
        history_entry(
          1,
          String.duplicate("/very/long/path/segment/with/context ", 3000)
        )

      history = [
        history_entry(4, "recent assistant reply"),
        history_entry(3, "recent user prompt"),
        history_entry(2, "prior context"),
        oversized_oldest
      ]

      config = %{
        agent_id: agent_id,
        task_id: task_id,
        task_description: "R47 oversized entry summarization acceptance",
        model_pool: [model_id],
        model_histories: %{model_id => history},
        context_lessons: %{model_id => []},
        model_states: %{model_id => nil},
        registry: deps.registry,
        dynsup: deps.dynsup,
        pubsub: deps.pubsub,
        sandbox_owner: sandbox_owner,
        test_mode: true,
        test_opts: [
          max_batch_tokens: 150,
          force_token_management: true,
          summarization_model: "anthropic:claude-sonnet-4",
          model_query_fn: fn _messages, _models, opts ->
            send(test_pid, {:r47_query, Map.get(opts, :max_tokens)})

            response_json =
              Jason.encode!(%{"action" => "wait", "params" => %{}, "reasoning" => "R47"})

            {:ok,
             %{
               successful_responses: [%{model: model_id, content: response_json}],
               failed_models: []
             }}
          end,
          summarize_fn: fn content, summarize_model, _opts ->
            send(test_pid, {:r47_summarize, summarize_model, content})
            {:ok, String.slice(content, 0, 300)}
          end,
          reflector_fn: fn _messages, _model_id, _opts ->
            {:ok,
             %{lessons: [%{type: :factual, content: "r47-lesson", confidence: 1}], state: []}}
          end
        ]
      }

      {:ok, agent_pid} =
        spawn_agent_with_cleanup(deps.dynsup, config, registry: deps.registry)

      {:ok, pre_state} = Core.get_state(agent_pid)
      pre_history = pre_state.model_histories[model_id]
      pre_tokens = TokenManager.estimate_history_tokens(pre_history)
      context_limit = TokenManager.get_model_context_limit(model_id)

      assert pre_tokens > context_limit

      Core.send_user_message(agent_pid, "continue")

      assert_receive {:r47_summarize, "anthropic:claude-sonnet-4", _}, 30_000
      assert_receive {:r47_query, max_tokens}, 30_000
      assert is_integer(max_tokens) and max_tokens > 0

      {:ok, post_state} = Core.get_state(agent_pid)

      post_history = post_state.model_histories[model_id]
      post_tokens = TokenManager.estimate_history_tokens(post_history)
      available_output = context_limit - post_tokens

      assert length(post_history) < length(pre_history)
      assert available_output > 0
      assert Enum.any?(post_state.context_lessons[model_id], &(&1.content == "r47-lesson"))
      refute post_history == pre_history
      refute max_tokens <= 0
    end
  end
end
