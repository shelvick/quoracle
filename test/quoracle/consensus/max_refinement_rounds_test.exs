defmodule Quoracle.Consensus.MaxRefinementRoundsTest do
  @moduledoc """
  Handler-level tests for max_refinement_rounds threading through consensus pipeline.
  v19.0 ARC R95-R101 + TEST_ProfileMaxRounds R3-R9.
  """
  use QuoracleWeb.ConnCase, async: true

  alias Quoracle.Agent.{Consensus, Core}
  alias Quoracle.Consensus.Result
  alias Quoracle.Profiles.Resolver
  alias Quoracle.Repo

  import ExUnit.CaptureLog

  # --- Helpers: mock responses for round-counting tests ---

  @model_ids ["mock:round-test-a", "mock:round-test-b", "mock:round-test-c"]
  @diverse_actions [:wait, :orient, :send_message]

  defp mock_params_for(:orient) do
    %{
      "current_situation" => "test",
      "goal_clarity" => "test",
      "available_resources" => "test",
      "key_challenges" => "test",
      "delegation_consideration" => "none"
    }
  end

  defp mock_params_for(:wait), do: %{"wait" => 1000}
  defp mock_params_for(:send_message), do: %{"to" => "parent", "content" => "test"}

  defp counting_diverse_query_fn(test_pid) do
    fn _messages, [model_id], _opts ->
      send(test_pid, :model_queried)
      idx = Enum.find_index(@model_ids, &(&1 == model_id)) || 0
      action = Enum.at(@diverse_actions, rem(idx, length(@diverse_actions)))
      params = mock_params_for(action)

      response_map = %{
        "action" => Atom.to_string(action),
        "params" => params,
        "reasoning" => "Mock diverse reasoning"
      }

      response_map =
        if action != :wait, do: Map.put(response_map, "wait", true), else: response_map

      {:ok,
       %{
         successful_responses: [%{model: model_id, content: Jason.encode!(response_map)}],
         failed_models: []
       }}
    end
  end

  defp build_consensus_state(max_refinement_rounds) do
    base = %{
      model_histories:
        Map.new(@model_ids, fn id ->
          {id, [%{type: :user, content: "Test prompt", timestamp: DateTime.utc_now()}]}
        end),
      context_lessons: Map.new(@model_ids, fn id -> {id, []} end),
      model_states: %{},
      todos: [],
      children: [],
      registry: nil,
      system_prompt: nil,
      context_summary: nil,
      additional_context: []
    }

    if is_nil(max_refinement_rounds),
      do: base,
      else: Map.put(base, :max_refinement_rounds, max_refinement_rounds)
  end

  defp drain_query_count do
    drain_query_count(0)
  end

  defp drain_query_count(acc) do
    receive do
      :model_queried -> drain_query_count(acc + 1)
    after
      0 -> acc
    end
  end

  # Query function that returns diverse responses until a target round,
  # then fails for all models to trigger the error fallback in execute_refinement.
  defp error_at_round_query_fn(error_round) do
    fn _messages, [model_id], query_opts ->
      round = Map.get(query_opts, :round, 1)

      if round >= error_round do
        {:error, :simulated_failure}
      else
        idx = Enum.find_index(@model_ids, &(&1 == model_id)) || 0
        action = Enum.at(@diverse_actions, rem(idx, length(@diverse_actions)))
        params = mock_params_for(action)

        response_map = %{
          "action" => Atom.to_string(action),
          "params" => params,
          "reasoning" => "Mock reasoning for round #{round}",
          "wait" => true
        }

        {:ok,
         %{
           successful_responses: [%{model: model_id, content: Jason.encode!(response_map)}],
           failed_models: []
         }}
      end
    end
  end

  # --- Helpers: format_result clusters ---

  defp build_majority_cluster do
    action = %{
      action: :orient,
      params: %{
        current_situation: "test",
        goal_clarity: "test",
        available_resources: "test",
        key_challenges: "test",
        delegation_consideration: "none"
      },
      reasoning: "test reasoning"
    }

    %{count: 2, actions: [action, action], representative: action}
  end

  # R95: State-threaded round control
  # max=0 in state → force at initial round → only 3 queries
  describe "round control from state (R95, R98)" do
    test "max=0 forces at initial round" do
      query_fn = counting_diverse_query_fn(self())
      state = build_consensus_state(0)

      capture_log(fn ->
        {:ok, _, _} = Consensus.get_consensus_with_state(state, model_query_fn: query_fn)
      end)

      query_count = drain_query_count()

      # max=0: round 1 > 0 → force immediately → 3 queries (initial only)
      # Current: ignores state, Manager gives 4, round >= 4 forces at round 4 → 12 queries
      assert query_count == 3
    end
  end

  # R96: Forced decision at round > max_refinement_rounds
  # max=2 → force at round 3 → initial + 2 refinements = 9 queries
  describe "force at round > max (R96)" do
    test "max=2 forces at round 3" do
      query_fn = counting_diverse_query_fn(self())
      state = build_consensus_state(2)

      capture_log(fn ->
        {:ok, _, _} = Consensus.get_consensus_with_state(state, model_query_fn: query_fn)
      end)

      query_count = drain_query_count()

      # max=2: rounds 1,2 refine; round 3 > 2 → force
      # = initial(3) + 2 refinements(6) = 9 queries
      # Current: ignores state, always 12 queries (round >= 4)
      assert query_count == 9
    end
  end

  # R97: Within max allows refinement (integration-level round counting)
  # max=5 allows more rounds than max=2
  # R96 already verifies max=2 → 9 queries, so we only run max=5 here and compare
  describe "within max allows refinement (R97)" do
    test "max=5 allows more rounds than max=2" do
      query_fn = counting_diverse_query_fn(self())

      # max=5: allows refinement past round 3 → 18 queries
      state_max5 = build_consensus_state(5)

      capture_log(fn ->
        {:ok, _, _} = Consensus.get_consensus_with_state(state_max5, model_query_fn: query_fn)
      end)

      count_max5 = drain_query_count()

      # max=5 must allow more rounds than max=2 (which produces 9 queries per R96)
      assert count_max5 > 9
    end
  end

  # R98: max=0 applies penalty from round 1
  describe "max=0 penalty at round 1 (R98)" do
    test "max=0 applies penalty from round 1" do
      cluster = build_majority_cluster()

      {_, _, opts0} = Result.format_result([cluster], 3, 1, max_refinement_rounds: 0)
      {_, _, opts4} = Result.format_result([cluster], 3, 1, max_refinement_rounds: 4)

      assert Keyword.get(opts0, :confidence) < Keyword.get(opts4, :confidence)
    end
  end

  # R100: format_result uses max_refinement_rounds from opts
  describe "opts thread to Result (R100)" do
    test "format_result uses max from opts" do
      cluster = build_majority_cluster()

      # max=2 at round 6: penalty = (6-2)*0.1 = 0.4
      {_, _, opts2} = Result.format_result([cluster], 3, 6, max_refinement_rounds: 2)
      # max=8 at round 6: no penalty (6 <= 8)
      {_, _, opts8} = Result.format_result([cluster], 3, 6, max_refinement_rounds: 8)

      assert Keyword.get(opts2, :confidence) < Keyword.get(opts8, :confidence)
    end
  end

  # R8: Default max=4 round control
  # Without max in state, defaults to 4 → forces at round 5 → 15 queries
  describe "default round control (R8)" do
    test "default allows 4 refinement rounds" do
      query_fn = counting_diverse_query_fn(self())
      # State without max_refinement_rounds field → default 4
      state = build_consensus_state(nil)

      capture_log(fn ->
        {:ok, _, _} = Consensus.get_consensus_with_state(state, model_query_fn: query_fn)
      end)

      query_count = drain_query_count()

      # Default max=4: round > 4 forces at round 5
      # = initial(3) + 4 refinements(12) = 15 queries
      # Current: Manager gives 4, round >= 4 at round 4 → 12 queries
      assert query_count == 15
    end
  end

  # R101: Default path uses max=4 for penalty threshold
  # After IMPLEMENT: calculate_confidence uses max=4 (not hardcoded 3)
  describe "default penalty threshold (R101)" do
    test "default uses max=4 for round penalty" do
      cluster = build_majority_cluster()

      # format_result at round 5 without explicit max
      # base = 2/3 ≈ 0.667, majority_bonus = 0.10 (0.667 > 0.6)
      # After IMPLEMENT: default max=4, penalty=(5-4)*0.1=0.1, conf ≈ 0.667
      # Currently: hardcoded threshold=3, penalty=(5-3)*0.1=0.2, conf ≈ 0.567
      {_, _, opts} = Result.format_result([cluster], 3, 5)
      confidence = Keyword.get(opts, :confidence)

      assert_in_delta confidence, 0.667, 0.001
    end
  end

  # Integration audit: extract_cost_opts (consensus.ex:359) omits :max_refinement_rounds
  # from Keyword.take. The error fallback (line 332) calls extract_cost_opts, passing
  # cost_opts without max_refinement_rounds to Result.format_result, which defaults to
  # max=4. When round > 4 but <= agent's actual max, an incorrect penalty is applied.
  #
  # The nil-state fallback (line 293) has the same bug but is not observable because it
  # only triggers at round 1, where penalty=0 regardless of max value.
  describe "error fallback cost_opts (audit)" do
    test "confidence has no round penalty when error occurs at round <= max" do
      # Query function: diverse responses for rounds 1-5, all models fail at round 6.
      # Round 6 = refinement query for round 5. Error fallback fires at round 5.
      query_fn = error_at_round_query_fn(6)
      state = build_consensus_state(7)

      capture_log(fn ->
        {:ok, {_result_type, _action, meta}, _updated_state} =
          Consensus.get_consensus_with_state(state, model_query_fn: query_fn)

        send(self(), {:confidence, Keyword.get(meta, :confidence)})
      end)

      assert_received {:confidence, confidence}

      # With max=7 at round 5: 5 <= 7, so NO round penalty should apply
      # base_confidence = 1/3 ~ 0.333 (3 diverse actions, largest cluster has count=1)
      # Expected: confidence ~ 0.333 (no penalty)
      # Bug: extract_cost_opts defaults to max=4, penalty = (5-4)*0.1 = 0.1
      #   -> confidence ~ 0.233
      assert confidence >= 0.3,
             "Expected no round penalty at round 5 with max=7, " <>
               "but got confidence #{confidence} " <>
               "(penalty applied using default max=4 instead of configured max=7)"
    end

    test "error fallback confidence matches direct calculation with correct max" do
      query_fn = error_at_round_query_fn(6)
      state = build_consensus_state(7)

      capture_log(fn ->
        {:ok, {_result_type, _action, meta}, _updated_state} =
          Consensus.get_consensus_with_state(state, model_query_fn: query_fn)

        send(self(), {:confidence, Keyword.get(meta, :confidence)})
      end)

      assert_received {:confidence, pipeline_confidence}

      # Directly calculate expected confidence with correct max=7 at round 5.
      # Error fallback clusters diverse responses: 3 clusters of 1, total=3.
      cluster = %{count: 1, actions: []}
      expected = Result.calculate_confidence(cluster, 3, 5, max_refinement_rounds: 7)

      # Pipeline should produce same confidence as direct calculation with correct max.
      # Bug: pipeline uses default max=4 -> different confidence
      assert_in_delta pipeline_confidence,
                      expected,
                      0.001,
                      "Pipeline confidence #{pipeline_confidence} should match " <>
                        "expected #{expected} (calculated with max=7 at round 5)"
    end
  end

  # R9: System/acceptance test — UI profile creation to consensus
  describe "profile to consensus (R9)" do
    @tag :acceptance
    test "UI-created profile max flows to consensus", %{
      conn: conn,
      sandbox_owner: sandbox_owner
    } do
      %{registry: registry, dynsup: dynsup, pubsub: pubsub} = create_isolated_deps()

      # Insert credentials for model_pool select
      %Quoracle.Models.TableCredentials{}
      |> Quoracle.Models.TableCredentials.changeset(%{
        model_id: "azure:o1",
        model_spec: "azure:o1",
        api_key: "test-key",
        deployment_id: "o1"
      })
      |> Repo.insert(on_conflict: :nothing, conflict_target: :model_id)

      # Mount settings page via real route
      conn =
        Plug.Test.init_test_session(conn, %{
          "sandbox_owner" => sandbox_owner,
          "pubsub" => pubsub
        })

      {:ok, view, _html} = live(conn, "/settings")

      # Switch to profiles tab
      html =
        view
        |> element("[phx-click='switch_tab'][phx-value-tab='profiles']")
        |> render_click()

      # Verify profiles tab loaded
      assert html =~ "New Profile"

      # Click "New Profile"
      html =
        view
        |> element("button", "New Profile")
        |> render_click()

      # Verify form is visible with max_refinement_rounds field
      assert html =~ "max_refinement_rounds"

      # Create profile with max_refinement_rounds=2
      unique_name = "max-rounds-r9-#{System.unique_integer([:positive])}"

      view
      |> form("#profile-form", %{
        profile: %{
          name: unique_name,
          description: "R9 acceptance test",
          model_pool: ["azure:o1"],
          capability_groups: ["file_read"],
          max_refinement_rounds: "2"
        }
      })
      |> render_submit()

      # Verify profile stored with correct max_refinement_rounds (not default)
      {:ok, data} = Resolver.resolve(unique_name)
      assert data.max_refinement_rounds == 2
      refute data.max_refinement_rounds == 4

      # Spawn real agent with profile's max (goes through ConfigManager pipeline)
      query_fn = counting_diverse_query_fn(self())

      agent_config = %{
        agent_id: "r9-test-#{System.unique_integer([:positive])}",
        task_description: "R9 consensus test",
        max_refinement_rounds: data.max_refinement_rounds,
        model_pool: @model_ids,
        test_mode: true,
        test_opts: [model_query_fn: query_fn],
        sandbox_owner: sandbox_owner,
        pubsub: pubsub
      }

      {:ok, agent_pid} = spawn_agent_with_cleanup(dynsup, agent_config, registry: registry)

      # Get state from real ConfigManager pipeline (not manual construction)
      {:ok, agent_state} = Core.get_state(agent_pid)
      assert agent_state.max_refinement_rounds == 2

      # Run consensus with agent's real state
      capture_log(fn ->
        {:ok, _, _} = Consensus.get_consensus_with_state(agent_state, model_query_fn: query_fn)
      end)

      query_count = drain_query_count()

      # Profile max=2: force at round 3 → initial(3) + 2 refinements(6) = 9 queries
      # Current: ignores state max, always 12 queries
      assert query_count == 9
    end
  end
end
