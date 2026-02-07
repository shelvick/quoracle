defmodule Quoracle.Agent.ConsensusTestHelpers do
  @moduledoc """
  Test helpers for building consensus test messages.
  Centralizes message construction for test maintainability.

  This module provides helpers for testing the Consensus module,
  particularly for constructing message arrays that follow the
  production pattern of including system prompts and handling
  conversation history alternation.

  ## Performance Optimization

  The system prompt is cached at compile time via `@cached_system_prompt`
  to avoid rebuilding the expensive prompt on every test iteration.
  Property tests that call `build_test_messages` hundreds of times
  benefit significantly from this caching (~80% speedup).
  """

  alias Quoracle.Consensus.PromptBuilder

  # Cache system prompt at compile time - building it is expensive
  # and it doesn't change between test iterations
  @cached_system_prompt PromptBuilder.build_system_prompt()

  @doc """
  Returns the cached system prompt for tests that need direct access.
  """
  @spec cached_system_prompt() :: String.t()
  def cached_system_prompt, do: @cached_system_prompt

  @doc """
  Builds test messages with system prompt, optional history, and user prompt.

  Follows production pattern for consistency with actual message building:
  - Adds PromptBuilder system prompt at position 0
  - Handles conversation history alternation (drops last user message if present)
  - Appends final user prompt

  Uses cached system prompt for performance (avoids rebuilding on each call).

  ## Examples

      iex> build_test_messages("What is 2+2?", [])
      [
        %{role: "system", content: "[PromptBuilder system prompt]"},
        %{role: "user", content: "What is 2+2?"}
      ]

      iex> history = [%{role: "user", content: "Hi"}, %{role: "assistant", content: "Hello"}]
      iex> build_test_messages("How are you?", history)
      [
        %{role: "system", content: "[PromptBuilder system prompt]"},
        %{role: "user", content: "Hi"},
        %{role: "assistant", content: "Hello"},
        %{role: "user", content: "How are you?"}
      ]
  """
  @spec build_test_messages(String.t(), list(map())) :: list(map())
  def build_test_messages(prompt, history \\ []) do
    # Use cached system prompt for performance
    system_message = %{role: "system", content: @cached_system_prompt}

    # Handle history alternation (follow production pattern)
    # If last message in history is "user", drop it to avoid consecutive user messages
    adjusted_history =
      case List.last(history || []) do
        %{role: "user"} -> Enum.drop(history, -1)
        _ -> history
      end

    # Structure: [system] -> [adjusted history] -> [user prompt]
    [system_message | adjusted_history] ++ [%{role: "user", content: prompt}]
  end

  @doc """
  Verifies a message array has a system prompt at position 0.

  Returns true if first message has role "system", false otherwise.
  """
  @spec has_system_prompt?(list(map())) :: boolean()
  def has_system_prompt?([%{role: "system"} | _rest]), do: true
  def has_system_prompt?(_messages), do: false

  @doc """
  Extracts the system prompt content from a message array.

  Returns the content of the first system message, or nil if not present.
  """
  @spec get_system_prompt_content(list(map())) :: String.t() | nil
  def get_system_prompt_content([%{role: "system", content: content} | _rest]), do: content
  def get_system_prompt_content(_messages), do: nil
end
