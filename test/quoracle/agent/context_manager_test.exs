defmodule Quoracle.Agent.ContextManagerTest do
  @moduledoc """
  Tests for improved context management in ContextManager.
  These tests verify DB-based context limits and percentage-based retention.
  """

  # Tests use async: true with proper sandbox_owner passing for spawned processes
  use Quoracle.DataCase, async: true
  import ExUnit.CaptureLog
  alias Quoracle.Agent.{Core, ContextManager, StateUtils, TokenManager}

  setup do
    pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
    registry = :"test_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Phoenix.PubSub, name: pubsub})
    start_supervised!({Registry, keys: :unique, name: registry})
    %{pubsub: pubsub, registry: registry}
  end

  describe "model-specific context limits from database" do
    test "gets context limit from model config in database", %{
      sandbox_owner: sandbox_owner,
      pubsub: pubsub,
      registry: registry
    } do
      # In test mode, we simulate DB lookup by passing context_limit in test_opts
      # TODO: When DB seeding is implemented, this should read from actual DB
      config = %{
        agent_id: "test-db-context",
        task: "Test DB context limits",
        model_id: "gpt-4",
        test_mode: true,
        test_opts: [context_limit: 8000, skip_initial_consultation: true],
        sandbox_owner: sandbox_owner,
        pubsub: pubsub,
        registry: registry
      }

      {:ok, agent} =
        capture_log(fn ->
          # Use GenServer.start (no link) so agent doesn't die when test exits
          # This allows on_exit to stop it gracefully with :infinity timeout
          send(self(), {:result, GenServer.start(Core, config)})
        end)
        |> then(fn _ ->
          assert_received {:result, result}
          result
        end)

      # Ensure agent stops BEFORE sandbox owner (on_exit runs LIFO)
      # Use :infinity timeout to wait for DB operations to complete
      on_exit(fn ->
        if Process.alive?(agent) do
          try do
            GenServer.stop(agent, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      {:ok, state} = Core.get_state(agent)

      # Should have the context limit from simulated DB lookup
      assert state.context_limit == 8000
    end

    test "uses model-specific limit for context percentage calculation", %{
      sandbox_owner: sandbox_owner,
      pubsub: pubsub,
      registry: registry
    } do
      # Simulate a small context limit in test mode
      # TODO: When DB seeding is implemented, this should read from actual DB
      config = %{
        agent_id: "test-small-context",
        task: "Test small context",
        model_id: "small-model",
        test_mode: true,
        test_opts: [context_limit: 1000, skip_initial_consultation: true],
        sandbox_owner: sandbox_owner,
        pubsub: pubsub,
        registry: registry
      }

      {:ok, agent} =
        capture_log(fn ->
          # Use GenServer.start (no link) so agent doesn't die when test exits
          # This allows on_exit to stop it gracefully with :infinity timeout
          send(self(), {:result, GenServer.start(Core, config)})
        end)
        |> then(fn _ ->
          assert_received {:result, result}
          result
        end)

      # Ensure agent stops BEFORE sandbox owner (on_exit runs LIFO)
      # Use :infinity timeout to wait for DB operations to complete
      on_exit(fn ->
        if Process.alive?(agent) do
          try do
            GenServer.stop(agent, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Add enough messages to reach 80% of the small limit
      # tiktoken: "word " = ~1 token per rep, 800 reps = ~800 tokens = 80% of 1000
      state = %{
        # Should come from DB
        context_limit: 1000,
        model_histories: %{
          "default" => [
            %{
              type: :prompt,
              content: String.duplicate("word ", 800),
              timestamp: DateTime.utc_now()
            }
          ]
        }
      }

      # This function should use DB-loaded limit
      percentage = TokenManager.context_usage_percentage(state)
      assert percentage >= 79.0
      assert percentage <= 82.0
    end

    test "handles missing model config gracefully", %{
      sandbox_owner: sandbox_owner,
      pubsub: pubsub,
      registry: registry
    } do
      config = %{
        agent_id: "test-missing-model",
        task: "Test missing model",
        model_id: "nonexistent-model",
        test_mode: true,
        test_opts: [skip_initial_consultation: true],
        sandbox_owner: sandbox_owner,
        pubsub: pubsub,
        registry: registry
      }

      # Should use a sensible default or fail gracefully
      {:ok, agent} =
        capture_log(fn ->
          # Use GenServer.start (no link) so agent doesn't die when test exits
          # This allows on_exit to stop it gracefully with :infinity timeout
          send(self(), {:result, GenServer.start(Core, config)})
        end)
        |> then(fn _ ->
          assert_received {:result, result}
          result
        end)

      # Ensure agent stops BEFORE sandbox owner (on_exit runs LIFO)
      # Use :infinity timeout to wait for DB operations to complete
      on_exit(fn ->
        if Process.alive?(agent) do
          try do
            GenServer.stop(agent, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      {:ok, state} = Core.get_state(agent)

      # Should have a default context limit
      # Default fallback
      assert state.context_limit == 4000
    end
  end

  describe "removal of token usage history" do
    test "state no longer contains token_usage_history field", %{
      sandbox_owner: sandbox_owner,
      pubsub: pubsub,
      registry: registry
    } do
      config = %{
        agent_id: "test-no-history",
        task: "Test no token history",
        test_mode: true,
        test_opts: [skip_initial_consultation: true],
        sandbox_owner: sandbox_owner,
        pubsub: pubsub,
        registry: registry
      }

      {:ok, agent} =
        capture_log(fn ->
          # Use GenServer.start (no link) so agent doesn't die when test exits
          # This allows on_exit to stop it gracefully with :infinity timeout
          send(self(), {:result, GenServer.start(Core, config)})
        end)
        |> then(fn _ ->
          assert_received {:result, result}
          result
        end)

      # Ensure agent stops BEFORE sandbox owner (on_exit runs LIFO)
      # Use :infinity timeout to wait for DB operations to complete
      on_exit(fn ->
        if Process.alive?(agent) do
          try do
            GenServer.stop(agent, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      {:ok, state} = Core.get_state(agent)

      # Should not have token_usage_history field
      refute Map.has_key?(state, :token_usage_history)
    end
  end

  # ==========================================================================
  # v5.0 BUG FIX - 1-arity causes N× history duplication
  # WorkGroupID: fix-20251209-035351
  # Packet 1: Foundation
  #
  # R13: 1-arity function deleted (compiler enforces after fix)
  # R14: 2-arity function unchanged (covered by context_manager_per_model_test.exs)
  # R15: No callers of 1-arity (grep check, not runtime test)
  # ==========================================================================

  describe "v5.0 FIX: 1-arity function deleted" do
    @tag :regression
    test "2-arity function returns single model's history (no N× duplication)" do
      # The 1-arity function was deleted because it caused N× duplication
      # by flattening ALL model histories (bug: 813,101 tokens ≈ 3× the 272,000 limit).
      # The 2-arity function correctly uses only the specified model's history.

      # Create state with multiple models - each with same message
      history_entry = %{
        type: :user,
        content: "shared message",
        timestamp: DateTime.utc_now()
      }

      state = %{
        model_histories: %{
          "model-a" => [history_entry],
          "model-b" => [history_entry],
          "model-c" => [history_entry]
        },
        test_mode: true
      }

      # Call 2-arity with specific model - should return only that model's history
      messages = ContextManager.build_conversation_messages(state, "model-a")

      # Should have exactly 1 message (from model-a only, no duplication)
      # Content now includes timestamp prefix, so check with String.contains?
      user_messages =
        Enum.filter(messages, fn msg ->
          msg.role == "user" && String.contains?(msg.content, "shared message")
        end)

      # This verifies the fix: only 1 message (not 3× from all models)
      assert length(user_messages) == 1,
             "2-arity should return only the specified model's history, got #{length(user_messages)}"
    end
  end

  # ==========================================================================
  # NO_EXECUTE Tag Wrapping for Untrusted Action Results
  # Security fix: Wrap external content in conversation history to prevent
  # prompt injection attacks from fetch_web, execute_shell, call_api, etc.
  # ==========================================================================

  describe "NO_EXECUTE tag wrapping for action results" do
    # Note: NO_EXECUTE wrapping now happens at storage time in StateUtils.add_history_entry_with_action
    # These tests verify that wrapped content is preserved through build_conversation_messages

    test "wraps untrusted action results with NO_EXECUTE tags" do
      # Use StateUtils to create properly wrapped entry
      base_state = %{model_histories: %{"default" => []}, test_mode: true}

      state =
        StateUtils.add_history_entry_with_action(
          base_state,
          :result,
          {"action_123", {:ok, %{stdout: "ls output"}}},
          :execute_shell
        )

      messages = ContextManager.build_conversation_messages(state, "default")
      result_msg = Enum.find(messages, &(&1.role == "user"))

      assert result_msg.content =~ "<NO_EXECUTE_"
      assert result_msg.content =~ "</NO_EXECUTE_"
      assert result_msg.content =~ "ls output"
    end

    test "wraps fetch_web results with NO_EXECUTE tags" do
      base_state = %{model_histories: %{"default" => []}, test_mode: true}

      state =
        StateUtils.add_history_entry_with_action(
          base_state,
          :result,
          {"action_456", {:ok, %{body: "<html>malicious</html>"}}},
          :fetch_web
        )

      messages = ContextManager.build_conversation_messages(state, "default")
      result_msg = Enum.find(messages, &(&1.role == "user"))

      assert result_msg.content =~ "<NO_EXECUTE_"
      assert result_msg.content =~ "malicious"
    end

    test "wraps call_api results with NO_EXECUTE tags" do
      base_state = %{model_histories: %{"default" => []}, test_mode: true}

      state =
        StateUtils.add_history_entry_with_action(
          base_state,
          :result,
          {"action_789", {:ok, %{response: "api data"}}},
          :call_api
        )

      messages = ContextManager.build_conversation_messages(state, "default")
      result_msg = Enum.find(messages, &(&1.role == "user"))

      assert result_msg.content =~ "<NO_EXECUTE_"
    end

    test "does NOT wrap trusted action results (send_message)" do
      base_state = %{model_histories: %{"default" => []}, test_mode: true}

      state =
        StateUtils.add_history_entry_with_action(
          base_state,
          :result,
          {"action_abc", {:ok, :delivered}},
          :send_message
        )

      messages = ContextManager.build_conversation_messages(state, "default")
      result_msg = Enum.find(messages, &(&1.role == "user"))

      refute result_msg.content =~ "<NO_EXECUTE_"
    end

    test "wraps call_mcp results with NO_EXECUTE tags" do
      base_state = %{model_histories: %{"default" => []}, test_mode: true}

      state =
        StateUtils.add_history_entry_with_action(
          base_state,
          :result,
          {"action_mcp", {:ok, %{tool_result: "external data"}}},
          :call_mcp
        )

      messages = ContextManager.build_conversation_messages(state, "default")
      result_msg = Enum.find(messages, &(&1.role == "user"))

      assert result_msg.content =~ "<NO_EXECUTE_"
    end

    test "wraps answer_engine results with NO_EXECUTE tags" do
      base_state = %{model_histories: %{"default" => []}, test_mode: true}

      state =
        StateUtils.add_history_entry_with_action(
          base_state,
          :result,
          {"action_ae", {:ok, %{answer: "search result"}}},
          :answer_engine
        )

      messages = ContextManager.build_conversation_messages(state, "default")
      result_msg = Enum.find(messages, &(&1.role == "user"))

      assert result_msg.content =~ "<NO_EXECUTE_"
    end
  end

  # ==========================================================================
  # Defensive Message Formatting (FIX: Alternation Violation Prevention)
  # Ensures format_history_entry always returns valid %{role: _, content: _}
  # regardless of malformed input - prevents LLM API alternation errors.
  # ==========================================================================

  describe "defensive message formatting - always returns valid messages" do
    test "unknown entry type returns valid user message" do
      # Silence expected error log for unknown type
      capture_log(fn ->
        state = %{
          model_histories: %{
            "default" => [
              %{type: :unknown_type, content: "some content", timestamp: DateTime.utc_now()}
            ]
          },
          test_mode: true
        }

        messages = ContextManager.build_conversation_messages(state, "default")

        assert length(messages) == 1
        msg = hd(messages)
        assert msg.role == "user"
        assert is_binary(msg.content)
        assert msg.content =~ "some content"
      end)
    end

    test "nil content returns valid message" do
      # Capture expected log from AlternationGuard about unexpected content type
      capture_log(fn ->
        state = %{
          model_histories: %{
            "default" => [
              %{
                type: :result,
                content: nil,
                action_type: :execute_shell,
                timestamp: DateTime.utc_now()
              }
            ]
          },
          test_mode: true
        }

        messages = ContextManager.build_conversation_messages(state, "default")

        assert length(messages) == 1
        msg = hd(messages)
        assert msg.role == "user"
        assert is_binary(msg.content)
      end)
    end

    test "map content (not string) returns valid message with data preserved" do
      # Silence expected error log for unexpected content type
      capture_log(fn ->
        state = %{
          model_histories: %{
            "default" => [
              %{type: :user, content: %{unexpected: "structure"}, timestamp: DateTime.utc_now()}
            ]
          },
          test_mode: true
        }

        messages = ContextManager.build_conversation_messages(state, "default")

        assert length(messages) == 1
        msg = hd(messages)
        assert msg.role == "user"
        assert is_binary(msg.content)
        # Data should be preserved in string form
        assert msg.content =~ "unexpected"
        assert msg.content =~ "structure"
      end)
    end

    test "integer content returns valid message with value preserved" do
      # Silence expected error log for unexpected content type
      capture_log(fn ->
        state = %{
          model_histories: %{
            "default" => [
              %{type: :prompt, content: 12345, timestamp: DateTime.utc_now()}
            ]
          },
          test_mode: true
        }

        messages = ContextManager.build_conversation_messages(state, "default")

        assert length(messages) == 1
        msg = hd(messages)
        assert msg.role == "user"
        assert is_binary(msg.content)
        assert msg.content =~ "12345"
      end)
    end

    test "reference content returns valid message" do
      state = %{
        model_histories: %{
          "default" => [
            %{type: :decision, content: :erlang.make_ref(), timestamp: DateTime.utc_now()}
          ]
        },
        test_mode: true
      }

      messages = ContextManager.build_conversation_messages(state, "default")

      assert length(messages) == 1
      msg = hd(messages)
      assert msg.role in ["user", "assistant"]
      assert is_binary(msg.content)
    end

    test "malformed entry (string instead of map) returns valid fallback message" do
      state = %{
        model_histories: %{
          "default" => ["just a string instead of entry map"]
        },
        test_mode: true
      }

      # Should not crash - capture any logs but don't assert on them
      capture_log(fn ->
        messages = ContextManager.build_conversation_messages(state, "default")

        assert length(messages) == 1
        msg = hd(messages)
        assert msg.role == "user"
        assert is_binary(msg.content)
      end)
    end
  end
end
