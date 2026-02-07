defmodule Quoracle.Consensus.ResultAccumulatorThreadingTest do
  @moduledoc """
  Integration tests for accumulator threading through merge_params_by_rules.

  WorkGroupID: feat-20260203-194408
  Audit Finding: merge_params_by_rules discards updated accumulators (result.ex:350)

  The Bug:
  - ConsensusRules.apply_rule returns {{:ok, value}, updated_accumulator}
  - merge_params_by_rules matches this but DISCARDS the accumulator
  - Each param's embedding costs are lost, not threaded to next iteration
  - Final accumulator is missing costs from all but the last param

  Requirements:
  - R102: Multiple semantic_similarity params thread accumulator between iterations [INTEGRATION]
  - R103: format_result returns accumulator with ALL embedding costs [INTEGRATION]
  - R104: merge_cluster_params returns updated accumulator [INTEGRATION]
  """

  use Quoracle.DataCase, async: true

  alias Quoracle.Consensus.Result
  alias Quoracle.Costs.Accumulator

  # ============================================================
  # R102: Multi-Param Accumulator Threading [INTEGRATION]
  # ============================================================

  describe "R102: merge_params_by_rules threads accumulator between params" do
    setup do
      pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})

      task =
        %Quoracle.Tasks.Task{}
        |> Quoracle.Tasks.Task.changeset(%{prompt: "Threading test", status: "running"})
        |> Quoracle.Repo.insert!()

      {:ok, pubsub: pubsub_name, task_id: task.id}
    end

    test "accumulator from first param's embeddings is passed to second param", %{
      pubsub: pubsub,
      task_id: task_id
    } do
      # Track which params triggered embedding calls
      call_tracker =
        :ets.new(:"call_tracker_#{System.unique_integer([:positive])}", [:set, :public])

      # Mock embedding function that tracks calls and threads accumulator
      # Use param_marker as seed so same params get identical embeddings (pass similarity)
      mock_embedding_fn = fn text, opts ->
        param_marker = extract_param_marker(text)
        :ets.insert(call_tracker, {param_marker, true})

        # Generate embedding based on param marker (not full text)
        # This ensures values for same param are similar enough to pass threshold
        embedding = for i <- 1..10, do: :erlang.phash2({param_marker, i}) / 4_294_967_295

        case Map.get(opts, :cost_accumulator) do
          %Accumulator{} = acc ->
            # Add cost entry with param marker to track threading
            updated_acc =
              Accumulator.add(acc, %{
                agent_id: opts[:agent_id] || "test",
                task_id: opts[:task_id],
                cost_type: "llm_embedding",
                cost_usd: Decimal.new("0.0001"),
                metadata: %{"param" => param_marker, "text" => String.slice(text, 0..30)}
              })

            {:ok, %{embedding: embedding}, updated_acc}

          nil ->
            {:ok, %{embedding: embedding}}
        end
      end

      # Create cluster with spawn_child action - has multiple semantic_similarity params
      # Values are different enough to require actual embedding comparison
      cluster = %{
        count: 2,
        actions: [
          %{
            action: :spawn_child,
            params: %{
              task_description: "TASK_DESC: Build a web server",
              success_criteria: "SUCCESS: Server responds on port 8080",
              immediate_context: "CONTEXT: Starting from scratch",
              approach_guidance: "APPROACH: Use Phoenix framework",
              profile: "default"
            },
            reasoning: "R1",
            wait: false
          },
          %{
            action: :spawn_child,
            params: %{
              task_description: "TASK_DESC: Create a web application",
              success_criteria: "SUCCESS: Application handles HTTP requests",
              immediate_context: "CONTEXT: Clean slate project",
              approach_guidance: "APPROACH: Leverage Phoenix/Elixir",
              profile: "default"
            },
            reasoning: "R2",
            wait: false
          }
        ],
        representative: %{action: :spawn_child, params: %{}, reasoning: "R1"}
      }

      initial_acc = Accumulator.new()

      cost_opts = [
        agent_id: "threading-test-#{System.unique_integer([:positive])}",
        task_id: task_id,
        pubsub: pubsub,
        cost_accumulator: initial_acc,
        embedding_fn: mock_embedding_fn
      ]

      # Call merge_cluster_params - should thread accumulator through all params
      result = Result.merge_cluster_params(cluster, cost_opts)

      # The result should include the updated accumulator
      # CURRENTLY: merge_cluster_params only returns the merged action
      # EXPECTED: Should return {merged_action, updated_accumulator}

      case result do
        {merged_action, %Accumulator{} = final_acc} ->
          # SUCCESS: Accumulator was threaded and returned
          assert is_map(merged_action)

          # Verify accumulator has costs from MULTIPLE params (not just one)
          entries = Accumulator.to_list(final_acc)
          param_markers = entries |> Enum.map(& &1.metadata["param"]) |> Enum.uniq()

          # Should have entries from multiple semantic_similarity params
          assert length(param_markers) >= 2,
                 "Expected costs from multiple params, got: #{inspect(param_markers)}. " <>
                   "Accumulator threading between params is broken."

        merged_action when is_map(merged_action) ->
          # FAILURE: No accumulator returned = threading broken
          # This is the current behavior - merge_cluster_params doesn't return accumulator
          flunk(
            "merge_cluster_params did not return accumulator. " <>
              "Expected {action, accumulator} tuple, got just action map. " <>
              "Fix: merge_params_by_rules must thread and return accumulator."
          )

        {:error, reason} ->
          flunk("merge_cluster_params returned error: #{inspect(reason)}")
      end
    end

    test "second param receives accumulator with first param's costs", %{
      pubsub: pubsub,
      task_id: task_id
    } do
      # This test verifies the accumulator passed to each param contains
      # costs from ALL previous params (not just the initial empty accumulator)

      received_accumulators =
        :ets.new(:"received_accs_#{System.unique_integer([:positive])}", [:bag, :public])

      mock_embedding_fn = fn text, opts ->
        param_marker = extract_param_marker(text)
        # Use param_marker as seed so same params get identical embeddings
        embedding = for i <- 1..10, do: :erlang.phash2({param_marker, i}) / 4_294_967_295

        # Record what accumulator we received for this param
        case Map.get(opts, :cost_accumulator) do
          %Accumulator{} = acc ->
            count = Accumulator.count(acc)
            :ets.insert(received_accumulators, {param_marker, count})

            updated_acc =
              Accumulator.add(acc, %{
                agent_id: "test",
                task_id: opts[:task_id],
                cost_type: "llm_embedding",
                cost_usd: Decimal.new("0.0001"),
                metadata: %{"param" => param_marker}
              })

            {:ok, %{embedding: embedding}, updated_acc}

          nil ->
            :ets.insert(received_accumulators, {param_marker, :no_accumulator})
            {:ok, %{embedding: embedding}}
        end
      end

      cluster = %{
        count: 2,
        actions: [
          %{
            action: :spawn_child,
            params: %{
              task_description: "TASK_DESC: First task",
              success_criteria: "SUCCESS: First criteria"
            },
            reasoning: "R1",
            wait: false
          },
          %{
            action: :spawn_child,
            params: %{
              task_description: "TASK_DESC: Second task",
              success_criteria: "SUCCESS: Second criteria"
            },
            reasoning: "R2",
            wait: false
          }
        ],
        representative: %{action: :spawn_child, params: %{}, reasoning: "R1"}
      }

      cost_opts = [
        agent_id: "threading-test-2",
        task_id: task_id,
        pubsub: pubsub,
        cost_accumulator: Accumulator.new(),
        embedding_fn: mock_embedding_fn
      ]

      _result = Result.merge_cluster_params(cluster, cost_opts)

      # Check what accumulators each param received
      all_received = :ets.tab2list(received_accumulators)

      # Group by param marker
      by_param =
        Enum.group_by(all_received, fn {param, _} -> param end, fn {_, count} -> count end)

      # If threading works correctly:
      # - First param (task_description) receives accumulator with 0 entries initially
      # - Second param (success_criteria) FIRST call receives accumulator with entries from TASK_DESC
      #
      # CRITICAL: We check the MINIMUM count for SUCCESS, not ANY.
      # Within a single param, later calls naturally get entries from earlier calls.
      # But across params, the FIRST call should have entries from previous param.
      # If threading is broken, first SUCCESS call gets 0 entries.

      task_desc_counts = Map.get(by_param, "TASK_DESC", [])
      success_counts = Map.get(by_param, "SUCCESS", [])

      # Filter to only integer counts (not :no_accumulator atoms)
      success_int_counts = Enum.filter(success_counts, &is_integer/1)

      # The minimum count for SUCCESS should be > 0 if threading works
      # (meaning even the FIRST SUCCESS call got entries from TASK_DESC)
      min_success_count = if success_int_counts == [], do: nil, else: Enum.min(success_int_counts)

      assert min_success_count != nil,
             "No SUCCESS embedding calls were made"

      assert min_success_count > 0,
             "First SUCCESS call received accumulator with 0 entries. " <>
               "This proves accumulator is NOT threaded between params. " <>
               "TASK_DESC counts: #{inspect(task_desc_counts)}, " <>
               "SUCCESS counts: #{inspect(success_counts)}. " <>
               "Expected first SUCCESS call to receive accumulator with TASK_DESC costs."
    end
  end

  # ============================================================
  # R103: format_result Returns Accumulator [INTEGRATION]
  # ============================================================

  describe "R103: format_result returns accumulator with all embedding costs" do
    setup do
      pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})

      task =
        %Quoracle.Tasks.Task{}
        |> Quoracle.Tasks.Task.changeset(%{prompt: "Format result test", status: "running"})
        |> Quoracle.Repo.insert!()

      {:ok, pubsub: pubsub_name, task_id: task.id}
    end

    test "format_result returns tuple with updated accumulator", %{
      pubsub: pubsub,
      task_id: task_id
    } do
      embedding_call_count = :counters.new(1, [:atomics])

      mock_embedding_fn = fn text, opts ->
        :counters.add(embedding_call_count, 1, 1)
        # Use param_marker as seed so same params get identical embeddings
        param_marker = extract_param_marker(text)
        embedding = for i <- 1..10, do: :erlang.phash2({param_marker, i}) / 4_294_967_295

        case Map.get(opts, :cost_accumulator) do
          %Accumulator{} = acc ->
            updated_acc =
              Accumulator.add(acc, %{
                agent_id: "test",
                task_id: opts[:task_id],
                cost_type: "llm_embedding",
                cost_usd: Decimal.new("0.0001"),
                metadata: %{"call" => :counters.get(embedding_call_count, 1)}
              })

            {:ok, %{embedding: embedding}, updated_acc}

          nil ->
            {:ok, %{embedding: embedding}}
        end
      end

      clusters = [
        %{
          count: 2,
          actions: [
            %{
              action: :spawn_child,
              params: %{
                task_description: "TASK: Build API",
                success_criteria: "SUCCESS: Endpoints work"
              },
              reasoning: "R1",
              wait: false
            },
            %{
              action: :spawn_child,
              params: %{
                task_description: "TASK: Create API",
                success_criteria: "SUCCESS: Endpoints respond"
              },
              reasoning: "R2",
              wait: false
            }
          ],
          representative: %{action: :spawn_child, params: %{}, reasoning: "R1"}
        }
      ]

      cost_opts = [
        agent_id: "format-result-test",
        task_id: task_id,
        pubsub: pubsub,
        cost_accumulator: Accumulator.new(),
        embedding_fn: mock_embedding_fn
      ]

      result = Result.format_result(clusters, 2, 1, cost_opts)

      # CURRENT: Returns {result_type, action, confidence: float}
      # EXPECTED: Should return {result_type, action, confidence: float, accumulator}
      # OR: {result_type, action, [confidence: float, accumulator: acc]}

      case result do
        {_result_type, _action, opts} when is_list(opts) ->
          case Keyword.get(opts, :accumulator) do
            %Accumulator{} = acc ->
              # SUCCESS: Accumulator returned in opts
              total_calls = :counters.get(embedding_call_count, 1)

              assert Accumulator.count(acc) == total_calls,
                     "Accumulator has #{Accumulator.count(acc)} entries but #{total_calls} embedding calls were made. " <>
                       "Some costs were lost during param iteration."

            nil ->
              flunk(
                "format_result did not return accumulator in opts. " <>
                  "Got: #{inspect(opts)}. " <>
                  "Fix: format_result must return accumulator for caller to flush."
              )
          end

        other ->
          flunk(
            "format_result returned unexpected format: #{inspect(other)}. " <>
              "Expected accumulator in return value."
          )
      end
    end

    test "all semantic_similarity params contribute to final accumulator", %{
      pubsub: pubsub,
      task_id: task_id
    } do
      # Track which params triggered embeddings
      params_with_embeddings =
        :ets.new(:"params_embedded_#{System.unique_integer([:positive])}", [:set, :public])

      mock_embedding_fn = fn text, opts ->
        param_marker = extract_param_marker(text)
        :ets.insert(params_with_embeddings, {param_marker, true})

        # Use param_marker as seed so same params get identical embeddings
        embedding = for i <- 1..10, do: :erlang.phash2({param_marker, i}) / 4_294_967_295

        case Map.get(opts, :cost_accumulator) do
          %Accumulator{} = acc ->
            updated_acc =
              Accumulator.add(acc, %{
                agent_id: "test",
                task_id: opts[:task_id],
                cost_type: "llm_embedding",
                cost_usd: Decimal.new("0.0001"),
                metadata: %{"param" => param_marker}
              })

            {:ok, %{embedding: embedding}, updated_acc}

          nil ->
            {:ok, %{embedding: embedding}}
        end
      end

      # Use orient action - required string fields use semantic_similarity
      # Required params: current_situation, goal_clarity, available_resources, key_challenges, delegation_consideration
      clusters = [
        %{
          count: 2,
          actions: [
            %{
              action: :orient,
              params: %{
                current_situation: "SITUATION: Analyzing codebase",
                goal_clarity: "GOAL: Improve performance",
                available_resources: "RESOURCES: CPU and memory",
                key_challenges: "CHALLENGES: Legacy code",
                delegation_consideration: "DELEGATION: May need specialists"
              },
              reasoning: "R1",
              wait: false
            },
            %{
              action: :orient,
              params: %{
                current_situation: "SITUATION: Reviewing code structure",
                goal_clarity: "GOAL: Enhance performance",
                available_resources: "RESOURCES: Compute and RAM",
                key_challenges: "CHALLENGES: Old codebase",
                delegation_consideration: "DELEGATION: Might require experts"
              },
              reasoning: "R2",
              wait: false
            }
          ],
          representative: %{action: :orient, params: %{}, reasoning: "R1"}
        }
      ]

      cost_opts = [
        agent_id: "multi-param-test",
        task_id: task_id,
        pubsub: pubsub,
        cost_accumulator: Accumulator.new(),
        embedding_fn: mock_embedding_fn
      ]

      result = Result.format_result(clusters, 2, 1, cost_opts)

      # Count which params had embeddings called
      embedded_params = :ets.tab2list(params_with_embeddings) |> Enum.map(&elem(&1, 0))

      # At least 3 of the 5 required params should have triggered embeddings
      # (some may be optimized away if values are identical)
      assert "SITUATION" in embedded_params, "current_situation did not trigger embeddings"
      assert "GOAL" in embedded_params, "goal_clarity did not trigger embeddings"
      assert "RESOURCES" in embedded_params, "available_resources did not trigger embeddings"

      # Now verify the accumulator has costs from ALL of them
      case result do
        {_type, _action, opts} when is_list(opts) ->
          case Keyword.get(opts, :accumulator) do
            %Accumulator{} = acc ->
              entries = Accumulator.to_list(acc)
              params_in_acc = entries |> Enum.map(& &1.metadata["param"]) |> Enum.uniq()

              assert "SITUATION" in params_in_acc,
                     "SITUATION costs missing from accumulator"

              assert "GOAL" in params_in_acc,
                     "GOAL costs missing from accumulator"

              assert "RESOURCES" in params_in_acc,
                     "RESOURCES costs missing from accumulator"

            nil ->
              flunk("format_result did not return accumulator")
          end

        _ ->
          flunk("format_result did not return accumulator in expected format")
      end
    end
  end

  # ============================================================
  # R104: merge_cluster_params Returns Accumulator [INTEGRATION]
  # ============================================================

  describe "R104: merge_cluster_params returns updated accumulator" do
    setup do
      pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub_name})

      task =
        %Quoracle.Tasks.Task{}
        |> Quoracle.Tasks.Task.changeset(%{prompt: "Merge params test", status: "running"})
        |> Quoracle.Repo.insert!()

      {:ok, pubsub: pubsub_name, task_id: task.id}
    end

    test "merge_cluster_params returns {action, accumulator} tuple", %{
      pubsub: pubsub,
      task_id: task_id
    } do
      mock_embedding_fn = fn text, opts ->
        # Use param_marker as seed so same params get identical embeddings
        param_marker = extract_param_marker(text)
        embedding = for i <- 1..10, do: :erlang.phash2({param_marker, i}) / 4_294_967_295

        case Map.get(opts, :cost_accumulator) do
          %Accumulator{} = acc ->
            updated_acc =
              Accumulator.add(acc, %{
                agent_id: "test",
                task_id: opts[:task_id],
                cost_type: "llm_embedding",
                cost_usd: Decimal.new("0.0001"),
                metadata: %{}
              })

            {:ok, %{embedding: embedding}, updated_acc}

          nil ->
            {:ok, %{embedding: embedding}}
        end
      end

      cluster = %{
        count: 2,
        actions: [
          %{
            action: :send_message,
            params: %{to: :parent, content: "MESSAGE: Hello from child A"},
            reasoning: "R1",
            wait: false
          },
          %{
            action: :send_message,
            params: %{to: :parent, content: "MESSAGE: Hello from child B"},
            reasoning: "R2",
            wait: false
          }
        ],
        representative: %{action: :send_message, params: %{}, reasoning: "R1"}
      }

      cost_opts = [
        agent_id: "merge-params-test",
        task_id: task_id,
        pubsub: pubsub,
        cost_accumulator: Accumulator.new(),
        embedding_fn: mock_embedding_fn
      ]

      result = Result.merge_cluster_params(cluster, cost_opts)

      case result do
        {merged_action, %Accumulator{} = acc} ->
          # SUCCESS: Tuple with accumulator
          assert is_map(merged_action)
          assert Map.has_key?(merged_action, :action)
          assert not Accumulator.empty?(acc), "Accumulator should have embedding costs"

        merged_action when is_map(merged_action) ->
          # FAILURE: Just the action, no accumulator
          flunk(
            "merge_cluster_params returned only action map, not {action, accumulator} tuple. " <>
              "Accumulator with embedding costs is lost. " <>
              "Got: #{inspect(Map.keys(merged_action))}"
          )

        {:error, reason} ->
          flunk("merge_cluster_params returned error: #{inspect(reason)}")

        other ->
          flunk("Unexpected return format: #{inspect(other)}")
      end
    end

    test "returned accumulator is not empty when embeddings were called", %{
      pubsub: pubsub,
      task_id: task_id
    } do
      embedding_called = :counters.new(1, [:atomics])

      mock_embedding_fn = fn text, opts ->
        :counters.add(embedding_called, 1, 1)
        # Use param_marker as seed so same params get identical embeddings
        param_marker = extract_param_marker(text)
        embedding = for i <- 1..10, do: :erlang.phash2({param_marker, i}) / 4_294_967_295

        case Map.get(opts, :cost_accumulator) do
          %Accumulator{} = acc ->
            updated_acc =
              Accumulator.add(acc, %{
                agent_id: "test",
                task_id: opts[:task_id],
                cost_type: "llm_embedding",
                cost_usd: Decimal.new("0.0001"),
                metadata: %{"text" => String.slice(text, 0..20)}
              })

            {:ok, %{embedding: embedding}, updated_acc}

          nil ->
            {:ok, %{embedding: embedding}}
        end
      end

      cluster = %{
        count: 2,
        actions: [
          %{
            action: :orient,
            params: %{current_situation: "ORIENT: State A"},
            reasoning: "R1",
            wait: false
          },
          %{
            action: :orient,
            params: %{current_situation: "ORIENT: State B"},
            reasoning: "R2",
            wait: false
          }
        ],
        representative: %{action: :orient, params: %{}, reasoning: "R1"}
      }

      cost_opts = [
        agent_id: "nonempty-acc-test",
        task_id: task_id,
        pubsub: pubsub,
        cost_accumulator: Accumulator.new(),
        embedding_fn: mock_embedding_fn
      ]

      result = Result.merge_cluster_params(cluster, cost_opts)

      total_embedding_calls = :counters.get(embedding_called, 1)

      if total_embedding_calls > 0 do
        case result do
          {_action, %Accumulator{} = acc} ->
            assert Accumulator.count(acc) == total_embedding_calls,
                   "Accumulator count (#{Accumulator.count(acc)}) != embedding calls (#{total_embedding_calls})"

          action when is_map(action) ->
            flunk(
              "#{total_embedding_calls} embedding calls made but accumulator not returned. " <>
                "Costs are lost."
            )

          _ ->
            flunk("Unexpected result format")
        end
      end
    end
  end

  # ============================================================
  # Helpers
  # ============================================================

  # Extract a marker from the text to identify which param triggered the embedding
  defp extract_param_marker(text) do
    cond do
      String.starts_with?(text, "TASK_DESC:") -> "TASK_DESC"
      String.starts_with?(text, "TASK:") -> "TASK"
      String.starts_with?(text, "SUCCESS:") -> "SUCCESS"
      String.starts_with?(text, "CONTEXT:") -> "CONTEXT"
      String.starts_with?(text, "APPROACH:") -> "APPROACH"
      String.starts_with?(text, "SITUATION:") -> "SITUATION"
      String.starts_with?(text, "GOAL:") -> "GOAL"
      String.starts_with?(text, "RESOURCES:") -> "RESOURCES"
      String.starts_with?(text, "CHALLENGES:") -> "CHALLENGES"
      String.starts_with?(text, "DELEGATION:") -> "DELEGATION"
      String.starts_with?(text, "MESSAGE:") -> "MESSAGE"
      String.starts_with?(text, "ORIENT:") -> "ORIENT"
      true -> "UNKNOWN"
    end
  end
end
