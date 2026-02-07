defmodule Quoracle.Agent.Consensus.MessageBuilderContextTest do
  @moduledoc """
  Tests for context token injection integration in MessageBuilder.
  Packet 2: Context Token Injection - MODEL_Query v15.0 requirements R54-R58, A2.

  Verifies that ContextInjector is called in the message building pipeline
  and that token counts are injected at the end of the last user message.
  """
  use ExUnit.Case, async: true

  alias Quoracle.Agent.Consensus.MessageBuilder

  # Helper to build history entries (atom keys - ContextManager format)
  defp build_history_entry(content, role \\ "user") do
    %{role: role, content: content, timestamp: DateTime.utc_now()}
  end

  # Helper to build state with model histories
  defp build_state(model_id, history, opts \\ []) do
    registry_name = :"test_registry_#{System.unique_integer([:positive])}"
    {:ok, _} = Registry.start_link(keys: :unique, name: registry_name)

    base_state = %{
      agent_id: :test_agent,
      task_id: "test-task",
      model_histories: %{model_id => history},
      context_lessons: %{},
      model_states: %{},
      todos: [],
      children: [],
      budget_data: Keyword.get(opts, :budget_data),
      spent: Keyword.get(opts, :spent, Decimal.new(0)),
      over_budget: Keyword.get(opts, :over_budget, false),
      registry: registry_name,
      system_prompt: Keyword.get(opts, :system_prompt)
    }

    Keyword.get(opts, :extra, %{})
    |> Enum.reduce(base_state, fn {k, v}, acc -> Map.put(acc, k, v) end)
  end

  # Helper to extract all content from messages as single string
  defp extract_all_content(messages) do
    Enum.map_join(messages, " ", fn msg ->
      case msg.content || msg["content"] do
        c when is_binary(c) -> c
        list when is_list(list) -> Enum.map_join(list, " ", &to_string(&1[:text] || ""))
        _ -> ""
      end
    end)
  end

  # Helper to get the last user message content
  defp get_last_user_message_content(messages) do
    messages
    |> Enum.filter(fn msg ->
      role = msg[:role] || msg["role"]
      role == "user"
    end)
    |> List.last()
    |> case do
      nil -> nil
      msg -> msg[:content] || msg["content"]
    end
  end

  describe "R54: Context Tokens Injected" do
    test "build_messages_for_model includes context token injection" do
      model_id = "test-model"
      history = [build_history_entry("Hello, how are you?")]
      state = build_state(model_id, history)

      # MessageBuilder doesn't call ContextInjector yet - will fail
      messages = MessageBuilder.build_messages_for_model(state, model_id, [])

      all_content = extract_all_content(messages)

      # Should include ctx tag with token count
      assert all_content =~ "<ctx>",
             "MessageBuilder should inject context tokens via ContextInjector"

      assert all_content =~ "tokens in context</ctx>",
             "Context token tag should have proper format"
    end
  end

  describe "R55: Injection at End of Last User Message" do
    test "ctx tag appears at end of last user message" do
      model_id = "test-model"

      history = [
        build_history_entry("First user message"),
        build_history_entry("Assistant response", "assistant"),
        build_history_entry("Second user message")
      ]

      state = build_state(model_id, history)

      messages = MessageBuilder.build_messages_for_model(state, model_id, [])

      last_user_content = get_last_user_message_content(messages)

      # ctx tag should be at the END of the last user message
      assert last_user_content != nil, "Should have a user message"

      assert String.ends_with?(last_user_content, "</ctx>\n"),
             "ctx tag should be at end of last user message, got: #{inspect(String.slice(last_user_content, -50..-1))}"
    end

    test "original content preserved before ctx tag" do
      model_id = "test-model"
      original_content = "My original question about the task"
      history = [build_history_entry(original_content)]
      state = build_state(model_id, history)

      messages = MessageBuilder.build_messages_for_model(state, model_id, [])

      last_user_content = get_last_user_message_content(messages)

      # Original content should be preserved (somewhere before ctx tag)
      assert last_user_content =~ original_content,
             "Original content should be preserved in message"
    end
  end

  describe "R56: Per-Model Token Count" do
    test "token count is per-model not aggregate" do
      model_a = "model-a"
      model_b = "model-b"

      # Model A has short history
      history_a = [build_history_entry("Hi")]

      # Model B has much longer history
      history_b = [
        build_history_entry("This is a much longer message with many more tokens"),
        build_history_entry("And another long assistant response here", "assistant"),
        build_history_entry("Plus a follow-up question with additional context")
      ]

      # State with both models
      state = %{
        agent_id: :test_agent,
        task_id: "test-task",
        model_histories: %{
          model_a => history_a,
          model_b => history_b
        },
        context_lessons: %{},
        model_states: %{},
        todos: [],
        children: [],
        budget_data: nil,
        registry: nil,
        system_prompt: nil
      }

      messages_a = MessageBuilder.build_messages_for_model(state, model_a, [])
      messages_b = MessageBuilder.build_messages_for_model(state, model_b, [])

      content_a = extract_all_content(messages_a)
      content_b = extract_all_content(messages_b)

      # Extract token counts from ctx tags
      extract_count = fn content ->
        case Regex.run(~r/<ctx>([\d,]+) tokens in context<\/ctx>/, content) do
          [_, count_str] -> count_str |> String.replace(",", "") |> String.to_integer()
          _ -> 0
        end
      end

      tokens_a = extract_count.(content_a)
      tokens_b = extract_count.(content_b)

      # Model B should have significantly more tokens than Model A
      assert tokens_b > tokens_a,
             "Model B (longer history) should show more tokens than Model A. " <>
               "Got A=#{tokens_a}, B=#{tokens_b}"
    end
  end

  describe "R57: Injection After Budget" do
    test "ctx injection happens after budget injection" do
      model_id = "test-model"
      history = [build_history_entry("What is my budget status?")]

      state =
        build_state(model_id, history,
          budget_data: %{allocated: Decimal.new("100.00"), committed: Decimal.new("0")},
          spent: Decimal.new("25.00"),
          over_budget: false
        )

      messages = MessageBuilder.build_messages_for_model(state, model_id, [])

      last_user_content = get_last_user_message_content(messages)

      # Both budget and ctx should be present
      assert last_user_content =~ "<budget>", "Budget should be injected"
      assert last_user_content =~ "<ctx>", "Context tokens should be injected"

      # ctx should appear AFTER budget (at the very end)
      budget_pos = :binary.match(last_user_content, "</budget>") |> elem(0)
      ctx_pos = :binary.match(last_user_content, "<ctx>") |> elem(0)

      assert ctx_pos > budget_pos,
             "ctx tag (pos #{ctx_pos}) should appear after budget tag (pos #{budget_pos})"
    end
  end

  describe "R58: Works in Refinement Rounds" do
    test "ctx injection works in refinement rounds" do
      model_id = "test-model"

      history = [
        build_history_entry("Initial query"),
        build_history_entry("First response", "assistant")
      ]

      state = build_state(model_id, history)

      # Build messages with refinement prompt (consensus refinement round)
      refinement_prompt = "Please reconsider the previous responses and reach consensus."

      messages =
        MessageBuilder.build_messages_for_model(state, model_id,
          refinement_prompt: refinement_prompt
        )

      all_content = extract_all_content(messages)

      # Should still have ctx tag even in refinement rounds
      assert all_content =~ "<ctx>",
             "Context tokens should be injected in refinement rounds"

      assert all_content =~ "tokens in context</ctx>",
             "Context token format should be correct in refinement rounds"

      # Refinement prompt should also be present
      assert all_content =~ refinement_prompt,
             "Refinement prompt should be included"
    end

    test "ctx tag in refinement round reflects updated context" do
      model_id = "test-model"

      # Build longer history that would exist after first round
      history = [
        build_history_entry("Initial question with some context"),
        build_history_entry("First round response from model", "assistant"),
        build_history_entry("Follow-up question")
      ]

      state = build_state(model_id, history)

      messages =
        MessageBuilder.build_messages_for_model(state, model_id,
          refinement_prompt: "Refine please"
        )

      all_content = extract_all_content(messages)

      # Extract token count
      case Regex.run(~r/<ctx>([\d,]+) tokens in context<\/ctx>/, all_content) do
        [_, count_str] ->
          tokens = count_str |> String.replace(",", "") |> String.to_integer()
          # Should have non-zero tokens from the history
          assert tokens > 0, "Should have positive token count for non-empty history"

        _ ->
          flunk("Should have ctx tag with token count")
      end
    end
  end

  describe "A2: Full Consensus Query - Agent Receives Token Count" do
    @tag :acceptance
    test "agent receives token count in consensus query messages" do
      # This acceptance test verifies the full flow:
      # User action: Agent accumulates conversation history
      # User expectation: Agent sees token count and can make informed condensation decisions

      model_id = "test-model"

      # Simulate realistic conversation history
      history = [
        build_history_entry("I need you to analyze this codebase and find bugs"),
        build_history_entry("I'll analyze the codebase systematically...", "assistant"),
        build_history_entry("Start with the authentication module"),
        build_history_entry("Looking at auth module now...", "assistant"),
        build_history_entry("What vulnerabilities did you find?")
      ]

      state = build_state(model_id, history)

      # Build messages as would happen in real consensus query
      messages = MessageBuilder.build_messages_for_model(state, model_id, [])

      # Agent should see token count in the messages
      all_content = extract_all_content(messages)

      # Positive assertion: ctx tag with token count present
      assert all_content =~ ~r/<ctx>[\d,]+ tokens in context<\/ctx>/,
             "Agent should receive token count in consensus messages"

      # Extract and verify the count is reasonable
      [_, count_str] = Regex.run(~r/<ctx>([\d,]+) tokens in context<\/ctx>/, all_content)
      tokens = count_str |> String.replace(",", "") |> String.to_integer()

      # With 5 messages, should have substantial token count
      assert tokens > 20,
             "Token count should reflect actual history content, got #{tokens}"

      # Negative assertion: no error states (specific patterns, not just "error" word)
      refute all_content =~ "<error>",
             "Should not contain error XML tags"

      refute all_content =~ ~r/\bnil\b/,
             "Should not contain nil values in content"
    end
  end

  describe "edge cases" do
    test "handles empty history" do
      model_id = "test-model"
      state = build_state(model_id, [])

      messages = MessageBuilder.build_messages_for_model(state, model_id, [])

      # Even with empty history, if there's a user message from somewhere,
      # it should have ctx tag (with 0 tokens)
      all_content = extract_all_content(messages)

      # Empty history may result in no user messages, which is acceptable
      # But if there are user messages, they should have ctx
      user_messages =
        Enum.filter(messages, fn msg ->
          (msg[:role] || msg["role"]) == "user"
        end)

      unless Enum.empty?(user_messages) do
        assert all_content =~ "<ctx>0 tokens in context</ctx>",
               "Empty history should show 0 tokens"
      end
    end

    test "handles missing model in histories" do
      model_a = "model-a"
      model_b = "model-b"

      # Only model_a has history
      history_a = [build_history_entry("Hello")]

      state = %{
        agent_id: :test_agent,
        task_id: "test-task",
        model_histories: %{model_a => history_a},
        context_lessons: %{},
        model_states: %{},
        todos: [],
        children: [],
        budget_data: nil,
        registry: nil,
        system_prompt: nil
      }

      # Query for model_b which has no history
      messages = MessageBuilder.build_messages_for_model(state, model_b, [])

      all_content = extract_all_content(messages)

      # Should handle gracefully - either 0 tokens or no injection
      # (depends on whether there's a user message to inject into)
      user_messages =
        Enum.filter(messages, fn msg ->
          (msg[:role] || msg["role"]) == "user"
        end)

      unless Enum.empty?(user_messages) do
        assert all_content =~ "<ctx>0 tokens in context</ctx>",
               "Missing model history should show 0 tokens"
      end
    end
  end
end
