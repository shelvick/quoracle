defmodule Quoracle.Agent.ConsensusHandlerAceDelegateTest do
  @moduledoc """
  Tests for ConsensusHandler v17.0 - ACE injector delegate.

  Verifies that ConsensusHandler exposes inject_ace_context/3 and
  format_ace_context/2 delegates for API consistency with other injectors.

  WorkGroupID: wip-20260104-ace-injector
  Packet: 1 (ACE Injector)

  ARC Verification Criteria: R34-R35
  """
  use ExUnit.Case, async: true

  alias Quoracle.Agent.ConsensusHandler

  # ========== TEST HELPERS ==========

  defp make_lesson(content, type \\ :factual, confidence \\ 0.8) do
    %{content: content, type: type, confidence: confidence}
  end

  defp make_model_state(summary) do
    %{summary: summary}
  end

  defp make_message(role, content) do
    %{role: role, content: content}
  end

  defp make_state(lessons, model_state, model_id \\ "test-model") do
    %{
      context_lessons: if(lessons, do: %{model_id => lessons}, else: %{}),
      model_states: if(model_state, do: %{model_id => model_state}, else: %{})
    }
  end

  # ========== R34: ACE DELEGATE DEFINED ==========

  describe "R34: inject_ace_context delegate exists" do
    test "inject_ace_context/3 callable via ConsensusHandler" do
      # Test behavior: call the delegate and verify it returns expected type
      state = make_state([], nil)
      messages = [make_message("user", "Hello")]
      result = ConsensusHandler.inject_ace_context(state, messages, "test-model")
      assert is_list(result)
    end

    test "format_ace_context/2 callable via ConsensusHandler" do
      # Test behavior: call the delegate and verify it returns expected type
      result = ConsensusHandler.format_ace_context([], nil)
      assert is_binary(result)
    end

    test "inject_ace_context accepts state, messages, model_id" do
      state = make_state([make_lesson("Test")], nil)
      messages = [make_message("user", "Hello")]
      model_id = "test-model"

      # Should not raise - function exists with correct arity
      result = ConsensusHandler.inject_ace_context(state, messages, model_id)

      assert is_list(result)
    end

    test "format_ace_context accepts lessons and model_state" do
      lessons = [make_lesson("Test")]
      model_state = make_model_state("State")

      # Should not raise - function exists with correct arity
      result = ConsensusHandler.format_ace_context(lessons, model_state)

      assert is_binary(result)
    end
  end

  # ========== R35: DELEGATE FORWARDS CORRECTLY ==========

  describe "R35: delegate forwards to AceInjector" do
    test "inject_ace_context returns same result as AceInjector" do
      alias Quoracle.Agent.ConsensusHandler.AceInjector

      state = make_state([make_lesson("Test lesson")], nil)
      messages = [make_message("user", "Hello")]
      model_id = "test-model"

      # Both should return identical results
      handler_result = ConsensusHandler.inject_ace_context(state, messages, model_id)
      direct_result = AceInjector.inject_ace_context(state, messages, model_id)

      assert handler_result == direct_result
    end

    test "format_ace_context returns same result as AceInjector" do
      alias Quoracle.Agent.ConsensusHandler.AceInjector

      lessons = [make_lesson("Test lesson")]
      model_state = make_model_state("Test state")

      handler_result = ConsensusHandler.format_ace_context(lessons, model_state)
      direct_result = AceInjector.format_ace_context(lessons, model_state)

      assert handler_result == direct_result
    end

    test "inject_ace_context with empty lessons forwards correctly" do
      alias Quoracle.Agent.ConsensusHandler.AceInjector

      state = make_state([], nil)
      messages = [make_message("user", "Hello")]
      model_id = "test-model"

      handler_result = ConsensusHandler.inject_ace_context(state, messages, model_id)
      direct_result = AceInjector.inject_ace_context(state, messages, model_id)

      assert handler_result == direct_result
      # Both should return messages unchanged
      assert handler_result == messages
    end

    test "format_ace_context with empty input forwards correctly" do
      alias Quoracle.Agent.ConsensusHandler.AceInjector

      handler_result = ConsensusHandler.format_ace_context([], nil)
      direct_result = AceInjector.format_ace_context([], nil)

      assert handler_result == direct_result
      assert handler_result == ""
    end
  end

  # ========== INTEGRATION: DELEGATE CONSISTENCY ==========

  describe "delegate consistency with other injectors" do
    test "follows same pattern as todo_injector delegate" do
      # Test actual behavior of inject delegates
      state = %{todos: [], children: [], budget_data: nil, registry: nil}
      messages = [make_message("user", "Test")]

      todo_result = ConsensusHandler.inject_todo_context(state, messages)
      assert is_list(todo_result)

      children_result = ConsensusHandler.inject_children_context(state, messages)
      assert is_list(children_result)

      budget_result = ConsensusHandler.inject_budget_context(state, messages)
      assert is_list(budget_result)

      # ACE inject delegate - will fail until implemented
      ace_state = make_state([], nil)
      ace_result = ConsensusHandler.inject_ace_context(ace_state, messages, "model")
      assert is_list(ace_result)
    end

    test "follows same pattern as format delegates" do
      # Test actual behavior of format delegates
      todos_result = ConsensusHandler.format_todos([])
      assert is_binary(todos_result)

      children_result = ConsensusHandler.format_children([])
      assert is_binary(children_result)

      budget_state = %{budget_data: nil}
      budget_result = ConsensusHandler.format_budget(budget_state)
      assert is_binary(budget_result)

      # ACE format delegate - will fail until implemented
      ace_result = ConsensusHandler.format_ace_context([], nil)
      assert is_binary(ace_result)
    end
  end
end
