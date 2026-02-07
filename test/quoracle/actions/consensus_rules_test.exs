defmodule Quoracle.Actions.ConsensusRulesTest do
  @moduledoc """
  Tests for consensus rules including semantic similarity with embeddings.
  Semantic similarity tests use the identical-string optimization path (no API calls).
  """

  use Quoracle.DataCase, async: true
  use ExUnitProperties
  import StreamData
  alias Quoracle.Actions.ConsensusRules

  setup tags do
    # DataCase handles sandbox via start_owner! pattern - no manual mode setting needed
    # Manual {:shared, self()} conflicts with async: true and causes query cancellation

    # Start EmbeddingCache for tests that use embeddings
    {:ok, _cache_pid} = start_supervised(Quoracle.Models.EmbeddingCache)

    # Configure embedding model for v3.0 config-driven selection
    # Tests that need embeddings will fail at API call (no credentials), not config lookup
    {:ok, _} =
      Quoracle.Models.ConfigModelSettings.set_embedding_model("azure:test-embedding-model")

    {:ok, sandbox_owner: tags[:sandbox_owner]}
  end

  describe "exact_match rule" do
    test "returns value when all identical" do
      values = ["command1", "command1", "command1"]
      assert {:ok, "command1"} = ConsensusRules.apply_rule(:exact_match, values)
    end

    test "returns error when values differ" do
      values = ["command1", "command2"]
      assert {:error, :no_consensus} = ConsensusRules.apply_rule(:exact_match, values)
    end

    test "handles empty list" do
      assert {:error, :no_values} = ConsensusRules.apply_rule(:exact_match, [])
    end

    test "handles single value" do
      assert {:ok, "value"} = ConsensusRules.apply_rule(:exact_match, ["value"])
    end
  end

  describe "semantic_similarity rule" do
    # Note: These tests use the identical string optimization path (no API calls needed)
    # The actual embedding API is tested in model_query_embedding_test.exs
    # Cosine similarity math is tested in property tests below

    test "handles exact matches via optimization (no API call)" do
      # Identical strings trigger early return - no embedding API needed
      values = ["exact", "exact", "exact"]
      rule = {:semantic_similarity, threshold: 0.95}
      assert {:ok, "exact"} = ConsensusRules.apply_rule(rule, values)
    end

    test "handles empty strings" do
      # Empty strings are identical - triggers optimization
      values = ["", "", ""]
      rule = {:semantic_similarity, threshold: 0.95}
      assert {:ok, ""} = ConsensusRules.apply_rule(rule, values)
    end

    test "handles caching for repeated identical strings" do
      # All identical - triggers optimization, no API call
      values = ["Query database", "Query database", "Query database"]
      rule = {:semantic_similarity, threshold: 0.85}
      assert {:ok, "Query database"} = ConsensusRules.apply_rule(rule, values)
    end

    test "returns no_consensus when embeddings unavailable for different strings" do
      # Different strings need embedding API - without credentials returns error
      values = ["Process data", "Beautiful sunset", "Pizza recipe"]
      rule = {:semantic_similarity, threshold: 0.99}
      # Will return :no_consensus because embedding API fails without credentials
      assert {:error, :no_consensus} = ConsensusRules.apply_rule(rule, values)
    end
  end

  describe "mode_selection rule" do
    test "returns most frequent value" do
      values = [:get, :get, :post, :get]
      assert {:ok, :get} = ConsensusRules.apply_rule(:mode_selection, values)
    end

    test "handles tie by returning first" do
      values = [:get, :post, :get, :post]
      assert {:ok, :get} = ConsensusRules.apply_rule(:mode_selection, values)
    end

    test "works with atoms" do
      values = [:atom1, :atom1, :atom2]
      assert {:ok, :atom1} = ConsensusRules.apply_rule(:mode_selection, values)
    end

    test "works with strings" do
      values = ["a", "b", "a", "a"]
      assert {:ok, "a"} = ConsensusRules.apply_rule(:mode_selection, values)
    end

    test "handles single value" do
      assert {:ok, :single} = ConsensusRules.apply_rule(:mode_selection, [:single])
    end
  end

  describe "union_merge rule" do
    test "combines unique values from lists" do
      values = [[:a, :b], [:b, :c], [:a]]
      assert {:ok, merged} = ConsensusRules.apply_rule(:union_merge, values)
      assert Enum.sort(merged) == [:a, :b, :c]
    end

    test "removes duplicates" do
      values = [[:a, :a], [:b, :b], [:a, :b]]
      assert {:ok, merged} = ConsensusRules.apply_rule(:union_merge, values)
      assert Enum.sort(merged) == [:a, :b]
    end

    test "preserves order" do
      values = [[:a, :b], [:c], [:d]]
      assert {:ok, [:a, :b, :c, :d]} = ConsensusRules.apply_rule(:union_merge, values)
    end

    test "handles empty lists" do
      values = [[], [:a], []]
      assert {:ok, [:a]} = ConsensusRules.apply_rule(:union_merge, values)
    end

    test "handles nested lists properly" do
      values = [[:a], [:b, :c], [:d]]
      assert {:ok, [:a, :b, :c, :d]} = ConsensusRules.apply_rule(:union_merge, values)
    end
  end

  describe "structural_merge rule" do
    test "deep merges maps" do
      values = [%{a: 1}, %{b: 2}, %{c: 3}]
      assert {:ok, %{a: 1, b: 2, c: 3}} = ConsensusRules.apply_rule(:structural_merge, values)
    end

    test "later values override earlier" do
      values = [%{a: 1}, %{a: 2}, %{a: 3}]
      assert {:ok, %{a: 3}} = ConsensusRules.apply_rule(:structural_merge, values)
    end

    test "handles nested maps" do
      values = [
        %{outer: %{inner: 1}},
        %{outer: %{other: 2}}
      ]

      assert {:ok, %{outer: %{inner: 1, other: 2}}} =
               ConsensusRules.apply_rule(:structural_merge, values)
    end

    test "handles empty maps" do
      values = [%{}, %{a: 1}, %{}]
      assert {:ok, %{a: 1}} = ConsensusRules.apply_rule(:structural_merge, values)
    end

    test "preserves non-conflicting keys" do
      values = [%{a: 1, b: 2}, %{c: 3}, %{d: 4}]

      assert {:ok, %{a: 1, b: 2, c: 3, d: 4}} =
               ConsensusRules.apply_rule(:structural_merge, values)
    end
  end

  describe "percentile rule" do
    test "calculates median (50th percentile)" do
      values = [100, 200, 300, 400, 500]
      assert {:ok, 300} = ConsensusRules.apply_rule({:percentile, 50}, values)
    end

    test "calculates 75th percentile" do
      values = [100, 200, 300, 400]
      assert {:ok, 325} = ConsensusRules.apply_rule({:percentile, 75}, values)
    end

    test "handles single value" do
      assert {:ok, 42} = ConsensusRules.apply_rule({:percentile, 50}, [42])
    end

    test "handles even number of values for median" do
      values = [10, 20, 30, 40]
      assert {:ok, 25} = ConsensusRules.apply_rule({:percentile, 50}, values)
    end

    test "handles odd number of values for median" do
      values = [10, 20, 30, 40, 50]
      assert {:ok, 30} = ConsensusRules.apply_rule({:percentile, 50}, values)
    end
  end

  describe "merge_params/3 integration" do
    test "merge_params uses correct rule for spawn_child task_description" do
      # Test with identical strings - exact_match path (no embeddings needed)
      identical_values = ["Process data", "Process data", "Process data"]

      # semantic_similarity with identical values should find consensus
      # Uses exact match optimization path, no API call needed
      assert {:ok, "Process data"} =
               ConsensusRules.merge_params(:spawn_child, :task_description, identical_values)
    end

    test "merge_params uses correct rule for wait duration" do
      values = [1000, 2000, 3000, 4000, 5000]
      assert {:ok, 3000} = ConsensusRules.merge_params(:wait, :wait, values)
    end

    test "merge_params uses correct rule for send_message to" do
      values = [:parent, :parent, :parent]
      assert {:ok, :parent} = ConsensusRules.merge_params(:send_message, :to, values)
    end

    test "merge_params handles unknown param gracefully" do
      values = ["value1", "value2"]

      assert {:error, :unknown_param} =
               ConsensusRules.merge_params(:spawn_child, :unknown, values)
    end

    # NOTE: models and config removed from spawn_child schema - agents can't know
    # which models are configured. These params now return :unknown_param.
    test "merge_params returns unknown_param for removed models param" do
      values = [[:model1], [:model2]]

      assert {:error, :unknown_param} =
               ConsensusRules.merge_params(:spawn_child, :models, values)
    end

    test "merge_params uses exact match for execute_shell command" do
      values = ["ls -la", "ls -la", "ls -la"]
      assert {:ok, "ls -la"} = ConsensusRules.merge_params(:execute_shell, :command, values)
    end

    test "merge_params returns error for conflicting exact match" do
      values = ["ls -la", "rm -rf"]

      assert {:error, :no_consensus} =
               ConsensusRules.merge_params(:execute_shell, :command, values)
    end
  end

  describe "cosine_similarity function" do
    test "computes cosine similarity between identical vectors" do
      vec1 = List.duplicate(0.5, 3072)
      vec2 = List.duplicate(0.5, 3072)

      similarity = ConsensusRules.cosine_similarity(vec1, vec2)

      assert_in_delta similarity, 1.0, 0.0001
    end

    test "computes cosine similarity between orthogonal vectors" do
      # Create orthogonal vectors (dot product = 0)
      vec1 = [1.0] ++ List.duplicate(0.0, 3071)
      vec2 = [0.0, 1.0] ++ List.duplicate(0.0, 3070)

      similarity = ConsensusRules.cosine_similarity(vec1, vec2)

      assert_in_delta similarity, 0.0, 0.0001
    end

    test "computes cosine similarity between opposite vectors" do
      vec1 = List.duplicate(1.0, 3072)
      vec2 = List.duplicate(-1.0, 3072)

      similarity = ConsensusRules.cosine_similarity(vec1, vec2)

      assert_in_delta similarity, -1.0, 0.0001
    end

    test "handles vectors of different lengths" do
      vec1 = List.duplicate(0.5, 3072)
      # Wrong dimension
      vec2 = List.duplicate(0.5, 100)

      assert_raise ArgumentError, fn ->
        ConsensusRules.cosine_similarity(vec1, vec2)
      end
    end

    test "handles zero vectors gracefully" do
      vec1 = List.duplicate(0.0, 3072)
      vec2 = List.duplicate(0.0, 3072)

      # Zero vectors have undefined cosine similarity
      # Implementation should handle this case
      result = ConsensusRules.cosine_similarity(vec1, vec2)

      # Zero vectors return 0.0 (not error) - implementation handles gracefully
      assert result == 0.0
    end

    test "returns float between -1 and 1" do
      # Random vectors should have similarity in valid range
      vec1 = for _ <- 1..3072, do: :rand.uniform() - 0.5
      vec2 = for _ <- 1..3072, do: :rand.uniform() - 0.5

      similarity = ConsensusRules.cosine_similarity(vec1, vec2)

      assert similarity >= -1.0
      assert similarity <= 1.0
    end
  end

  describe "wait parameter merging" do
    test "all booleans false returns false" do
      values = [false, false, false]
      assert {:ok, false} = ConsensusRules.apply_rule(:wait_parameter, values)
    end

    test "all booleans true returns true" do
      values = [true, true, true]
      assert {:ok, true} = ConsensusRules.apply_rule(:wait_parameter, values)
    end

    test "mixed booleans with any true returns true (true-biased)" do
      values = [true, false, true]
      assert {:ok, true} = ConsensusRules.apply_rule(:wait_parameter, values)

      values2 = [false, true, true, true, true]
      assert {:ok, true} = ConsensusRules.apply_rule(:wait_parameter, values2)

      # Even a single true among many false
      values3 = [false, false, true]
      assert {:ok, true} = ConsensusRules.apply_rule(:wait_parameter, values3)
    end

    test "all integers returns median" do
      values = [10, 20, 30]
      assert {:ok, 20} = ConsensusRules.apply_rule(:wait_parameter, values)

      values2 = [5, 10, 15, 20, 25]
      assert {:ok, 15} = ConsensusRules.apply_rule(:wait_parameter, values2)
    end

    test "single integer returns that value" do
      assert {:ok, 42} = ConsensusRules.apply_rule(:wait_parameter, [42])
    end

    test "mixed types converts false to 0" do
      values = [false, 10, 20]
      # false becomes 0, median of [0, 10, 20] is 10
      assert {:ok, 10} = ConsensusRules.apply_rule(:wait_parameter, values)
    end

    test "mixed types converts true to highest integer or 30" do
      values = [true, 10, 20]
      # true becomes 20 (highest), median of [10, 20, 20] is 20
      assert {:ok, 20} = ConsensusRules.apply_rule(:wait_parameter, values)
    end

    test "true with no integers converts to 30" do
      values = [true, false]
      # true becomes 30, false becomes 0, median of [0, 30] is 15
      assert {:ok, 15} = ConsensusRules.apply_rule(:wait_parameter, values)
    end

    test "handles edge case with even number of values" do
      values = [10, 20, 30, 40]
      # Median of even list is average of middle two: (20 + 30) / 2 = 25
      assert {:ok, 25} = ConsensusRules.apply_rule(:wait_parameter, values)
    end

    test "handles zeros and false equivalence" do
      values = [0, false, 0]
      # All become 0, median is 0
      assert {:ok, 0} = ConsensusRules.apply_rule(:wait_parameter, values)
    end
  end

  describe "merge_params/3 for wait parameter" do
    test "applies wait parameter rule when param is :wait" do
      values = [true, false, true]
      assert {:ok, true} = ConsensusRules.merge_params(:orient, :wait, values)
    end

    test "does not apply wait rule for other parameters" do
      values = [100, 200, 300]
      # Should use action's defined rule, not wait_parameter rule
      assert {:ok, _} = ConsensusRules.merge_params(:wait, :wait, values)
    end
  end

  describe "property-based tests" do
    property "exact_match is commutative" do
      check all(values <- list_of(binary(), min_length: 1)) do
        result1 = ConsensusRules.apply_rule(:exact_match, values)
        result2 = ConsensusRules.apply_rule(:exact_match, Enum.reverse(values))
        assert result1 == result2
      end
    end

    property "union_merge always includes all unique elements" do
      # Bound generators to avoid arbitrarily large nested lists
      check all(
              lists <-
                list_of(list_of(atom(:alphanumeric), max_length: 10),
                  min_length: 1,
                  max_length: 5
                ),
              max_runs: 50
            ) do
        {:ok, merged} = ConsensusRules.apply_rule(:union_merge, lists)
        all_elements = lists |> List.flatten() |> Enum.uniq()
        assert Enum.sort(merged) == Enum.sort(all_elements)
      end
    end

    property "mode_selection always returns an input value" do
      check all(values <- list_of(integer(), min_length: 1)) do
        {:ok, result} = ConsensusRules.apply_rule(:mode_selection, values)
        assert result in values
      end
    end

    property "percentile always within min/max range" do
      check all(
              values <- list_of(integer(), min_length: 1),
              percentile <- integer(0..100)
            ) do
        {:ok, result} = ConsensusRules.apply_rule({:percentile, percentile}, values)
        assert result >= Enum.min(values)
        assert result <= Enum.max(values)
      end
    end

    # === v3.0 Cost Context Threading Tests (fix-costs-20260129) ===

    # R41: Cost Context Threaded to Embeddings
    test "passes cost context to embedding calls in semantic similarity" do
      # When apply_rule is called with cost context opts (3rd arg),
      # the embedding calls should receive agent_id/task_id/pubsub.
      # Test that apply_rule/3 exists and accepts a 3rd argument.
      cost_opts = [agent_id: "test-agent", task_id: 123, pubsub: :test_pubsub]

      # This should not raise — apply_rule/3 must accept opts
      # With identical values, it short-circuits (no embedding calls needed)
      result =
        ConsensusRules.apply_rule(
          {:semantic_similarity, threshold: 0.9},
          ["identical", "identical"],
          cost_opts
        )

      assert {:ok, "identical"} = result
    end

    # R42: Backward Compatible Without Opts
    test "apply_rule works without opts parameter" do
      # apply_rule/2 must still work (opts defaults to [])
      result =
        ConsensusRules.apply_rule(
          {:semantic_similarity, threshold: 0.9},
          ["same", "same"]
        )

      assert {:ok, "same"} = result
    end

    property "structural_merge preserves all keys" do
      # Bound generators to avoid arbitrarily large nested maps
      check all(
              maps <-
                list_of(map_of(atom(:alphanumeric), integer(), max_length: 10),
                  min_length: 1,
                  max_length: 5
                ),
              max_runs: 50
            ) do
        {:ok, merged} = ConsensusRules.apply_rule(:structural_merge, maps)
        all_keys = maps |> Enum.flat_map(&Map.keys/1) |> Enum.uniq()
        assert Enum.sort(Map.keys(merged)) == Enum.sort(all_keys)
      end
    end
  end

  # ============================================================
  # ACTION_ConsensusRules v4.0: Cost Accumulator Threading
  # WorkGroupID: feat-20260203-194408
  # Packet: 2 (Threading)
  # ============================================================

  alias Quoracle.Costs.Accumulator

  # ============================================================
  # R43: Accumulator Threaded to Embeddings [INTEGRATION]
  # ============================================================

  describe "R43: accumulator threaded to embeddings" do
    test "threads cost_accumulator to embedding calls" do
      # Use mock embedding function that captures the accumulator
      test_pid = self()

      mock_embedding_fn = fn text, opts ->
        send(test_pid, {:embedding_called, text, opts})
        {:ok, %{embedding: Enum.map(1..10, fn i -> :math.sin(i) end)}}
      end

      values = ["text one", "text two"]
      acc = Accumulator.new()

      rule = {:semantic_similarity, threshold: 0.5, embedding_fn: mock_embedding_fn}
      opts = [cost_accumulator: acc]

      ConsensusRules.apply_rule(rule, values, opts)

      # Verify embedding function received cost_accumulator in opts
      assert_receive {:embedding_called, "text one", embed_opts1}, 1000
      assert Map.has_key?(embed_opts1, :cost_accumulator)

      assert_receive {:embedding_called, "text two", embed_opts2}, 1000
      assert Map.has_key?(embed_opts2, :cost_accumulator)
    end
  end

  # ============================================================
  # R44: Accumulator Updated After Embeddings [INTEGRATION]
  # ============================================================

  describe "R44: accumulator updated after embeddings" do
    test "accumulates costs from multiple embedding calls" do
      # Mock embedding function that returns updated accumulator
      mock_embedding_fn = fn _text, opts ->
        acc = Map.get(opts, :cost_accumulator, Accumulator.new())

        entry = %{
          agent_id: "test",
          task_id: Ecto.UUID.generate(),
          cost_type: "llm_embedding",
          cost_usd: Decimal.new("0.001"),
          metadata: %{}
        }

        updated_acc = Accumulator.add(acc, entry)
        {:ok, %{embedding: Enum.map(1..10, fn i -> :math.sin(i) end)}, updated_acc}
      end

      values = ["text one", "text two", "text three"]
      acc = Accumulator.new()

      rule = {:semantic_similarity, threshold: 0.5, embedding_fn: mock_embedding_fn}
      opts = [cost_accumulator: acc]

      {_result, final_acc} = ConsensusRules.apply_rule(rule, values, opts)

      # Should have accumulated costs from all embedding calls
      assert %Accumulator{} = final_acc
      assert Accumulator.count(final_acc) >= 2
    end
  end

  # ============================================================
  # R45: Works Without Accumulator [UNIT]
  # ============================================================

  describe "R45: works without accumulator" do
    test "works without cost_accumulator (backward compatible)" do
      # Uses identical strings to trigger optimization (no API call)
      values = ["identical", "identical", "identical"]
      rule = {:semantic_similarity, threshold: 0.95}

      # No cost_accumulator in opts
      result = ConsensusRules.apply_rule(rule, values, [])

      assert {:ok, "identical"} = result
    end

    test "returns result without accumulator tuple when not provided" do
      values = ["same", "same"]
      rule = {:semantic_similarity, threshold: 0.9}

      result = ConsensusRules.apply_rule(rule, values, [])

      # Should return plain result, not tuple with accumulator
      assert {:ok, _value} = result
      refute match?({:ok, _, %Accumulator{}}, result)
    end
  end
end
