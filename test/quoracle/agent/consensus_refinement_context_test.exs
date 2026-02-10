defmodule Quoracle.Agent.ConsensusRefinementContextTest do
  @moduledoc """
  Tests for per-model refinement context fix in AGENT_Consensus.
  WorkGroupID: fix-20251225-consensus-bugs, Packet 2

  Bug #1: Refinement rounds have NO conversation context. The refinement uses
  query_models_with_messages with an empty context.conversation_history because
  build_context(prompt, []) passes an empty array.

  Solution: Refinement should ALSO use per-model histories, with the shared
  refinement prompt (showing other models' responses) appended as the final
  user message.

  Requirements: R43-R50
  """

  use ExUnit.Case, async: true

  alias Quoracle.Agent.Consensus
  alias Quoracle.Agent.Consensus.PerModelQuery
  alias Quoracle.Consensus.{Aggregator, Temperature}

  # Force ActionList to load - ensures :orient atom exists for String.to_existing_atom/1
  alias Quoracle.Actions.Schema.ActionList
  _ = ActionList.actions()
  _ = Temperature

  # ============================================================================
  # ACCEPTANCE TEST - User-observable behavior
  # ============================================================================

  describe "Acceptance: Refinement Context" do
    @tag :acceptance
    test "refinement round includes per-model conversation history" do
      # User scenario: Agent with divergent model histories triggers refinement
      # User expectation: Each model sees its own history during refinement, not empty context

      state = %{
        model_histories: %{
          "model-a" => [
            %{
              type: :user,
              content: "Task: Implement authentication module",
              timestamp: DateTime.utc_now()
            },
            %{
              type: :assistant,
              content: "I'll start with user login flow",
              timestamp: DateTime.utc_now()
            }
          ],
          "model-b" => [
            %{
              type: :user,
              content: "Task: Implement authentication module",
              timestamp: DateTime.utc_now()
            },
            %{
              type: :assistant,
              content: "Let me analyze the requirements first",
              timestamp: DateTime.utc_now()
            }
          ]
        },
        task_id: Ecto.UUID.generate(),
        test_mode: true
      }

      test_pid = self()

      # Capture messages sent to each model during refinement
      mock_query_fn = fn messages, [model_id], _opts ->
        send(test_pid, {:refinement_query, model_id, messages})
        # Return valid orient response
        response =
          Jason.encode!(%{
            "action" => "orient",
            "params" => %{
              "current_situation" => "Processing",
              "goal_clarity" => "Clear",
              "available_resources" => "Available",
              "key_challenges" => "None",
              "delegation_consideration" => "none"
            },
            "reasoning" => "Reconsidering"
          })

        {:ok, %{successful_responses: [%{model: model_id, content: response}], failed_models: []}}
      end

      opts = [
        test_mode: true,
        model_pool: ["model-a", "model-b"],
        force_no_consensus: true,
        model_query_fn: mock_query_fn
      ]

      # POSITIVE: Consensus completes (doesn't crash due to missing context)
      {:ok, {result_type, action, _meta}, _updated_state} =
        Consensus.get_consensus_with_state(state, opts)

      assert result_type in [:consensus, :forced_decision]
      assert action != nil

      # POSITIVE: During refinement, models received their conversation history
      # Currently FAILS because refinement uses empty context, not per-model histories
      assert_receive {:refinement_query, "model-a", model_a_messages}, 30_000
      assert_receive {:refinement_query, "model-b", model_b_messages}, 30_000
      # Model A should see its history (authentication module task)
      model_a_content =
        Enum.map_join(model_a_messages, " ", &(&1[:content] || &1.content))

      assert model_a_content =~ "Implement authentication module",
             "Model A should receive its task description in refinement"

      # NEGATIVE: Models should NOT receive empty context
      refute model_a_messages == [],
             "Refinement should not send empty messages to models"

      refute model_b_messages == [],
             "Refinement should not send empty messages to models"
    end
  end

  # ============================================================================
  # R43: State Included in Context
  # [UNIT] WHEN get_consensus_with_state called THEN context includes :state key
  # ============================================================================

  describe "R43: State Included in Context" do
    test "execute_refinement receives state via context for per-model access" do
      # Verify that when refinement is called, it has access to state
      # to query per-model histories (not empty conversation_history)

      state = %{
        model_histories: %{
          "model-a" => [
            %{type: :user, content: "Unique context for model A", timestamp: DateTime.utc_now()}
          ],
          "model-b" => [
            %{
              type: :user,
              content: "Different context for model B",
              timestamp: DateTime.utc_now()
            }
          ]
        },
        task_id: Ecto.UUID.generate(),
        test_mode: true
      }

      test_pid = self()
      query_count = :counters.new(1, [:atomics])

      # Track what gets sent in refinement (not initial) queries
      mock_query_fn = fn messages, [model_id], _opts ->
        :counters.add(query_count, 1, 1)
        count = :counters.get(query_count, 1)

        # First 2 queries are initial round, 3+ are refinement
        if count >= 3 do
          send(test_pid, {:refinement_messages, model_id, messages})
        end

        # Return different actions initially to force no consensus
        action =
          if count <= 2 do
            if model_id == "model-a", do: "orient", else: "wait"
          else
            "orient"
          end

        response =
          if action == "wait" do
            Jason.encode!(%{
              "action" => "wait",
              "params" => %{"wait" => true},
              "reasoning" => "test"
            })
          else
            Jason.encode!(%{
              "action" => "orient",
              "params" => %{
                "current_situation" => "Processing",
                "goal_clarity" => "Clear",
                "available_resources" => "Available",
                "key_challenges" => "None",
                "delegation_consideration" => "none"
              },
              "reasoning" => "test"
            })
          end

        {:ok, %{successful_responses: [%{model: model_id, content: response}], failed_models: []}}
      end

      opts = [
        test_mode: true,
        model_pool: ["model-a", "model-b"],
        force_no_consensus: true,
        model_query_fn: mock_query_fn
      ]

      _result = Consensus.get_consensus_with_state(state, opts)

      # Refinement should have access to state with model_histories
      # Currently FAILS because context = Manager.build_context(prompt, [])
      # does NOT include :state, so refinement can't access per-model histories
      assert_receive {:refinement_messages, "model-a", messages_a}, 30_000
      # Messages should contain model A's unique context
      content_a = Enum.map_join(messages_a, " ", &(&1[:content] || &1.content))

      assert content_a =~ "Unique context for model A",
             "Refinement must have access to state for per-model histories"
    end
  end

  # ============================================================================
  # R44: Refinement Uses Per-Model Histories
  # [INTEGRATION] WHEN refinement triggered THEN each model receives its own history
  # ============================================================================

  describe "R44: Refinement Uses Per-Model Histories" do
    test "refinement queries each model with its own divergent history" do
      # Create state where each model has DIFFERENT history
      state = %{
        model_histories: %{
          "model-a" => [
            %{
              type: :user,
              content: "Model A: Working on authentication",
              timestamp: DateTime.utc_now()
            }
          ],
          "model-b" => [
            %{type: :user, content: "Model B: Working on payments", timestamp: DateTime.utc_now()}
          ]
        },
        task_id: Ecto.UUID.generate(),
        test_mode: true
      }

      test_pid = self()
      query_count = :counters.new(1, [:atomics])

      mock_query_fn = fn messages, [model_id], _opts ->
        :counters.add(query_count, 1, 1)
        count = :counters.get(query_count, 1)

        # Only send messages for refinement queries (3+)
        if count >= 3 do
          send(test_pid, {:model_query, model_id, messages})
        end

        # Return different actions initially to force no consensus
        action =
          if count <= 2 do
            if model_id == "model-a", do: "orient", else: "wait"
          else
            "orient"
          end

        response =
          if action == "wait" do
            Jason.encode!(%{
              "action" => "wait",
              "params" => %{"wait" => true},
              "reasoning" => "test"
            })
          else
            Jason.encode!(%{
              "action" => "orient",
              "params" => %{
                "current_situation" => "Processing",
                "goal_clarity" => "Clear",
                "available_resources" => "Available",
                "key_challenges" => "None",
                "delegation_consideration" => "none"
              },
              "reasoning" => "test"
            })
          end

        {:ok, %{successful_responses: [%{model: model_id, content: response}], failed_models: []}}
      end

      opts = [
        test_mode: true,
        model_pool: ["model-a", "model-b"],
        force_no_consensus: true,
        model_query_fn: mock_query_fn
      ]

      _result = Consensus.get_consensus_with_state(state, opts)

      # Get refinement round messages (initial queries are filtered out by count check)
      # Currently FAILS: refinement uses shared empty history for all models
      assert_receive {:model_query, "model-a", refinement_a}, 30_000
      assert_receive {:model_query, "model-b", refinement_b}, 30_000
      # Model A should see "authentication", Model B should see "payments"
      content_a = Enum.map_join(refinement_a, " ", &(&1[:content] || &1.content))
      content_b = Enum.map_join(refinement_b, " ", &(&1[:content] || &1.content))

      # POSITIVE: Each model receives its own unique history content
      assert content_a =~ "Model A: Working on authentication",
             "Model A should receive its own history"

      assert content_b =~ "Model B: Working on payments",
             "Model B should receive its own history"

      # NEGATIVE: Each model's history messages (non-refinement) should be isolated.
      # The shared refinement prompt may contain one model's user content in its
      # **Prompt:** field, but the actual history entries should be per-model.
      # Extract only non-system, non-refinement history messages for isolation check.
      history_only_a =
        refinement_a
        |> Enum.filter(&(&1.role == "user"))
        |> Enum.reject(&(&1.content =~ "Consensus Refinement"))
        |> Enum.map_join(" ", & &1.content)

      history_only_b =
        refinement_b
        |> Enum.filter(&(&1.role == "user"))
        |> Enum.reject(&(&1.content =~ "Consensus Refinement"))
        |> Enum.map_join(" ", & &1.content)

      refute history_only_a =~ "Model B:",
             "Model A's history should NOT contain Model B's entries"

      refute history_only_b =~ "Model A:",
             "Model B's history should NOT contain Model A's entries"
    end
  end

  # ============================================================================
  # R45: Refinement Prompt Appended
  # [UNIT] WHEN refinement_prompt in opts THEN appended as final user message
  # ============================================================================

  describe "R45: Refinement Prompt Appended" do
    test "refinement prompt appended to per-model messages" do
      state = %{
        model_histories: %{
          "model-a" => [
            %{type: :user, content: "Original task", timestamp: DateTime.utc_now()}
          ]
        },
        task_id: Ecto.UUID.generate(),
        test_mode: true
      }

      test_pid = self()

      mock_query_fn = fn messages, _models, _opts ->
        send(test_pid, {:messages_sent, messages})
        {:ok, %{successful_responses: [%{model: "model-a", content: "{}"}], failed_models: []}}
      end

      opts = [
        test_mode: true,
        refinement_prompt: "Other models suggested orient. Please reconsider.",
        model_query_fn: mock_query_fn
      ]

      _result = PerModelQuery.query_single_model_with_retry(state, "model-a", opts)

      assert_receive {:messages_sent, messages}, 30_000
      # After fix: Last user message should contain the refinement prompt
      # Currently FAILS because refinement_prompt is ignored
      last_user_msg =
        messages
        |> Enum.filter(&(&1.role == "user"))
        |> List.last()

      assert last_user_msg.content =~ "Other models suggested",
             "Expected refinement prompt to be appended as final user message"

      # NEGATIVE: Should not clobber original history
      all_content = Enum.map_join(messages, " ", & &1.content)

      assert all_content =~ "Original task",
             "Original history should be preserved when appending refinement prompt"
    end

    test "refinement prompt has timestamp prepended" do
      alias Quoracle.Utils.MessageTimestamp

      refinement_prompt = "Please reconsider your action."
      timestamped = MessageTimestamp.prepend(refinement_prompt)

      assert timestamped =~ ~r/^<timestamp>/
      assert timestamped =~ refinement_prompt
    end
  end

  # ============================================================================
  # R45b: Refinement Prompt Merged (No Consecutive User Messages)
  # [UNIT] WHEN refinement_prompt in opts THEN merged into last user message, not appended
  # ============================================================================

  describe "R45b: Refinement Prompt Merged Into Last User Message" do
    test "refinement prompt merged into last user message, no consecutive user messages" do
      state = %{
        model_histories: %{
          "model-a" => [
            %{type: :user, content: "Current task prompt", timestamp: DateTime.utc_now()}
          ]
        },
        task_id: Ecto.UUID.generate(),
        test_mode: true
      }

      test_pid = self()

      mock_query_fn = fn messages, _models, _opts ->
        send(test_pid, {:messages_sent, messages})
        {:ok, %{successful_responses: [%{model: "model-a", content: "{}"}], failed_models: []}}
      end

      opts = [
        test_mode: true,
        refinement_prompt: "## Consensus Refinement - Round 2\nPlease reconsider.",
        model_query_fn: mock_query_fn
      ]

      _result = PerModelQuery.query_single_model_with_retry(state, "model-a", opts)

      assert_receive {:messages_sent, messages}, 30_000

      # No consecutive user messages (alternation must be maintained)
      roles = Enum.map(messages, & &1.role)
      consecutive_user_pairs = Enum.chunk_every(roles, 2, 1, :discard)

      refute Enum.any?(consecutive_user_pairs, fn [a, b] -> a == "user" and b == "user" end),
             "Must not have consecutive user messages. Roles: #{inspect(roles)}"
    end

    test "refinement prompt content is present in last user message" do
      state = %{
        model_histories: %{
          "model-a" => [
            %{type: :user, content: "My task description", timestamp: DateTime.utc_now()}
          ]
        },
        task_id: Ecto.UUID.generate(),
        test_mode: true
      }

      test_pid = self()

      mock_query_fn = fn messages, _models, _opts ->
        send(test_pid, {:messages_sent, messages})
        {:ok, %{successful_responses: [%{model: "model-a", content: "{}"}], failed_models: []}}
      end

      opts = [
        test_mode: true,
        refinement_prompt: "Consensus Refinement content here",
        model_query_fn: mock_query_fn
      ]

      _result = PerModelQuery.query_single_model_with_retry(state, "model-a", opts)

      assert_receive {:messages_sent, messages}, 30_000

      last_user_msg =
        messages
        |> Enum.filter(&(&1.role == "user"))
        |> List.last()

      # Both the original content and refinement content should be in the same message
      assert last_user_msg.content =~ "My task description"
      assert last_user_msg.content =~ "Consensus Refinement content here"
    end
  end

  # ============================================================================
  # R45c: context.prompt Contains Actual User Content
  # [UNIT] WHEN refinement prompt built THEN context.prompt is the real user message
  # ============================================================================

  describe "R45c: context.prompt Contains Actual User Content" do
    test "refinement prompt contains actual last user message, not placeholder" do
      state = %{
        model_histories: %{
          "model-a" => [
            %{
              type: :user,
              content: "Analyze the payment processing module",
              timestamp: DateTime.utc_now()
            }
          ],
          "model-b" => [
            %{
              type: :user,
              content: "Analyze the payment processing module",
              timestamp: DateTime.utc_now()
            }
          ]
        },
        task_id: Ecto.UUID.generate(),
        test_mode: true
      }

      test_pid = self()
      query_count = :counters.new(1, [:atomics])

      mock_query_fn = fn messages, [model_id], _opts ->
        :counters.add(query_count, 1, 1)
        count = :counters.get(query_count, 1)

        # Capture refinement round messages (queries 3+)
        if count >= 3 do
          send(test_pid, {:refinement_messages, model_id, messages})
        end

        action =
          if count <= 2 do
            if model_id == "model-a", do: "orient", else: "wait"
          else
            "orient"
          end

        response =
          if action == "wait" do
            Jason.encode!(%{
              "action" => "wait",
              "params" => %{"wait" => true},
              "reasoning" => "test"
            })
          else
            Jason.encode!(%{
              "action" => "orient",
              "params" => %{
                "current_situation" => "Processing",
                "goal_clarity" => "Clear",
                "available_resources" => "Available",
                "key_challenges" => "None",
                "delegation_consideration" => "none"
              },
              "reasoning" => "test"
            })
          end

        {:ok, %{successful_responses: [%{model: model_id, content: response}], failed_models: []}}
      end

      opts = [
        test_mode: true,
        model_pool: ["model-a", "model-b"],
        model_query_fn: mock_query_fn
      ]

      _result = Consensus.get_consensus_with_state(state, opts)

      assert_receive {:refinement_messages, _, messages}, 30_000

      # The refinement content (merged into last user message) should contain the
      # actual user prompt "Analyze the payment processing module", NOT the placeholder
      all_content =
        Enum.map_join(messages, " ", fn msg ->
          case msg.content do
            c when is_binary(c) -> c
            c when is_list(c) -> Enum.map_join(c, " ", &Map.get(&1, :text, ""))
            _ -> ""
          end
        end)

      assert all_content =~ "Analyze the payment processing module",
             "Refinement prompt **Prompt:** field should contain the actual user message"

      refute all_content =~ "Agent decision from per-model histories",
             "Placeholder string should not appear in refinement messages"
    end
  end

  # ============================================================================
  # R46: Refinement Prompt Shows Other Responses
  # [UNIT] WHEN refinement prompt built THEN includes other models' candidate responses
  # ============================================================================

  describe "R46: Refinement Prompt Shows Other Responses" do
    test "refinement prompt includes other models' responses" do
      responses = [
        %{action: :orient, params: %{}, reasoning: "Model A thinks we should orient"},
        %{
          action: :spawn_child,
          params: %{task_description: "subtask"},
          reasoning: "Model B wants to spawn"
        },
        %{action: :orient, params: %{}, reasoning: "Model C agrees with orient"}
      ]

      round = 1

      context = %{
        model_pool: ["model-a", "model-b", "model-c"],
        prompt: "What action should we take?"
      }

      prompt = Aggregator.build_refinement_prompt(responses, round, context)

      # Prompt should include the action proposals
      assert prompt =~ "orient"
      assert prompt =~ "spawn"

      assert prompt =~ "Round",
             "Refinement prompt should show round number"
    end
  end

  # ============================================================================
  # R47: Per-Model Condensation in Refinement
  # [INTEGRATION] WHEN model history exceeds limit during refinement THEN condensation still triggers
  # ============================================================================

  describe "R47: Per-Model Condensation in Refinement" do
    test "condensation works during refinement rounds" do
      large_history =
        for i <- 1..100 do
          %{
            type: :user,
            content: "Message #{i}: " <> String.duplicate("word ", 50),
            timestamp: DateTime.utc_now()
          }
        end

      state = %{
        model_histories: %{
          "openai:gpt-3.5-turbo-0613" => large_history
        },
        context_lessons: %{},
        model_states: %{},
        test_mode: true
      }

      opts = [
        test_mode: true,
        model_pool: ["openai:gpt-3.5-turbo-0613"],
        force_no_consensus: true
      ]

      # This should trigger refinement, and condensation should happen
      {:ok, _result, _updated_state} = Consensus.get_consensus_with_state(state, opts)

      # Success = didn't fail with context_length_exceeded
      # Condensation during refinement uses maybe_condense_for_model
    end
  end

  # ============================================================================
  # R48: Messages-Based API Behavior
  # [UNIT] Messages-based API works for initial consensus, returns forced_decision if refinement needed
  # ============================================================================

  describe "R48: Messages-Based API Behavior" do
    test "messages-based API works for initial consensus" do
      messages = [
        %{role: "user", content: "What action should I take?"}
      ]

      opts = [test_mode: true, model_pool: ["model-a", "model-b", "model-c"]]

      result = Consensus.get_consensus(messages, opts)

      assert {:ok, {result_type, _action, _meta}} = result
      assert result_type in [:consensus, :forced_decision]
    end

    test "messages-based API returns forced_decision when refinement would be needed" do
      messages = [
        %{role: "user", content: "Shared context for all models"}
      ]

      # Without state in context, refinement is not possible - returns forced_decision
      opts = [
        test_mode: true,
        model_pool: ["model-a", "model-b"],
        force_no_consensus: true
      ]

      {:ok, {result_type, _action, _meta}} = Consensus.get_consensus(messages, opts)

      # Messages-based API cannot do per-model refinement, returns forced_decision
      assert result_type == :forced_decision
    end
  end

  # ============================================================================
  # R49: Round Number Incremented
  # [UNIT] WHEN refinement called THEN round + 1 passed in opts
  # ============================================================================

  describe "R49: Round Number Incremented" do
    test "refinement queries use incremented round number" do
      state = %{
        model_histories: %{
          "model-a" => [%{type: :user, content: "Task", timestamp: DateTime.utc_now()}],
          "model-b" => [%{type: :user, content: "Task", timestamp: DateTime.utc_now()}]
        },
        task_id: Ecto.UUID.generate(),
        test_mode: true
      }

      test_pid = self()
      query_count = :counters.new(1, [:atomics])

      mock_query_fn = fn _messages, [model_id], opts ->
        :counters.add(query_count, 1, 1)
        count = :counters.get(query_count, 1)

        # Capture round from opts on refinement queries (query 3+)
        if count >= 3 do
          send(test_pid, {:refinement_opts, opts})
        end

        # Return different actions initially to force no consensus
        action =
          if count <= 2 do
            if model_id == "model-a", do: "orient", else: "wait"
          else
            "orient"
          end

        response =
          if action == "wait" do
            Jason.encode!(%{
              "action" => "wait",
              "params" => %{"wait" => true},
              "reasoning" => "test"
            })
          else
            Jason.encode!(%{
              "action" => "orient",
              "params" => %{
                "current_situation" => "Processing",
                "goal_clarity" => "Clear",
                "available_resources" => "Available",
                "key_challenges" => "None",
                "delegation_consideration" => "none"
              },
              "reasoning" => "test"
            })
          end

        {:ok, %{successful_responses: [%{model: model_id, content: response}], failed_models: []}}
      end

      opts = [
        test_mode: true,
        model_pool: ["model-a", "model-b"],
        force_no_consensus: true,
        model_query_fn: mock_query_fn
      ]

      _result = Consensus.get_consensus_with_state(state, opts)

      # Currently FAILS: refinement doesn't pass incremented round in opts
      assert_receive {:refinement_opts, refinement_opts}, 30_000
      # Refinement should use round 2 (initial was round 1)
      round = Map.get(refinement_opts, :round) || refinement_opts[:round]

      assert round == 2,
             "Refinement should use round 2 (got: #{inspect(round)})"
    end

    test "round number in opts affects temperature calculation" do
      opts_round_1 = [round: 1]
      opts_round_3 = [round: 3]

      temp_r1 = PerModelQuery.build_query_options("anthropic:claude-sonnet-4", opts_round_1)
      temp_r3 = PerModelQuery.build_query_options("anthropic:claude-sonnet-4", opts_round_3)

      assert temp_r3.temperature < temp_r1.temperature
    end
  end

  # ============================================================================
  # R50: Temperature Descends in Refinement
  # [INTEGRATION] WHEN refinement round N THEN temperature lower than round N-1
  # ============================================================================

  describe "R50: Temperature Descends in Refinement" do
    test "refinement rounds use descending temperature" do
      model_id = "anthropic:claude-sonnet-4"

      temp_r1 = Temperature.calculate_round_temperature(model_id, 1)
      temp_r2 = Temperature.calculate_round_temperature(model_id, 2)
      temp_r3 = Temperature.calculate_round_temperature(model_id, 3)

      assert temp_r1 > temp_r2
      assert temp_r2 > temp_r3

      # Claude max=1.0 (default 4 rounds): 1.0 → 0.7 → 0.5
      assert temp_r1 == 1.0
      assert temp_r2 == 0.7
      assert temp_r3 == 0.5
    end

    test "per-model query uses Temperature module for refinement rounds" do
      opts_round_1 = [round: 1]
      opts_round_4 = [round: 4]

      claude_r1 = PerModelQuery.build_query_options("anthropic:claude-sonnet-4", opts_round_1)
      claude_r4 = PerModelQuery.build_query_options("anthropic:claude-sonnet-4", opts_round_4)

      assert claude_r4.temperature < claude_r1.temperature
      assert claude_r1.temperature == 1.0
      # Round 4 with default 4 rounds = floor = 0.2
      assert claude_r4.temperature == 0.2
    end

    test "different model families get different temperatures at same round" do
      opts = [round: 2]

      # Round 2 with default 4 rounds
      claude_temp = PerModelQuery.build_query_options("anthropic:claude-sonnet-4", opts)
      assert claude_temp.temperature == 0.7

      gpt_temp = PerModelQuery.build_query_options("openai:gpt-4o", opts)
      assert gpt_temp.temperature == 1.5

      assert gpt_temp.temperature > claude_temp.temperature
    end
  end
end
