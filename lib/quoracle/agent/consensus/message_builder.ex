defmodule Quoracle.Agent.Consensus.MessageBuilder do
  @moduledoc """
  Single source of truth for consensus message building.

  This module consolidates the message building pipeline that was previously
  duplicated between ConsensusHandler (for UI logging) and PerModelQuery
  (for LLM queries). Both paths now call this module to ensure consistency.

  ## Injection Order

  1. Build base messages from model history
  2. Inject ACE context into FIRST user message (historical knowledge)
  3. Append refinement_prompt if provided (consensus refinement rounds)
  4. Inject TODO context into LAST message (current state)
  5. Inject children context into LAST message (current state)
  6. Add system prompts (includes profile, action schemas, etc.)
  7. Inject budget context into LAST message (current state)
  8. Inject context token count at END of LAST user message (meta context)
  """

  alias Quoracle.Agent.ContextManager
  alias Quoracle.Agent.Consensus.SystemPromptInjector

  alias Quoracle.Agent.ConsensusHandler.{
    AceInjector,
    BudgetInjector,
    ChildrenInjector,
    ContextInjector,
    TodoInjector
  }

  alias Quoracle.Utils.MessageTimestamp

  @doc """
  Builds complete consensus messages for a single model.

  This is the single source of truth for message building. Both UI logging
  and LLM query paths use this function to ensure consistency.

  ## Parameters

  - `state` - Agent state containing model_histories, todos, children, budget, etc.
  - `model_id` - The model ID to build messages for
  - `opts` - Options including:
    - `:refinement_prompt` - Optional refinement prompt for consensus rounds
    - `:profile_name` - Profile name for system prompt
    - `:profile_description` - Profile description for system prompt
    - `:capability_groups` - Capability groups for action filtering

  ## Returns

  List of messages ready for LLM query or UI display.
  """
  @spec build_messages_for_model(map(), String.t(), keyword()) :: list(map())
  def build_messages_for_model(state, model_id, opts \\ []) do
    # Step 1: Build base messages from history
    messages = ContextManager.build_conversation_messages(state, model_id)

    # Step 2: Inject ACE context into FIRST user message (historical knowledge)
    messages = AceInjector.inject_ace_context(state, messages, model_id)

    # Step 3: Append refinement_prompt if provided (consensus refinement rounds)
    messages = maybe_append_refinement_prompt(messages, opts)

    # Step 4: Inject TODO context into LAST message
    messages = TodoInjector.inject_todo_context(state, messages)

    # Step 5: Inject children context into LAST message
    messages = ChildrenInjector.inject_children_context(state, messages)

    # Step 6: Add system prompts with action schemas and profile information
    field_prompts = %{system_prompt: Map.get(state, :system_prompt)}

    messages = SystemPromptInjector.ensure_system_prompts(messages, field_prompts, opts)

    # Step 7: Inject budget context (after system prompt injection)
    messages = BudgetInjector.inject_budget_context(state, messages)

    # Step 8: Inject context token count LAST (at end of last user message)
    # Counts all non-system message tokens from steps 1-7
    ContextInjector.inject_context_tokens(messages)
  end

  @doc """
  Builds messages for multiple models.

  Returns a list of `%{model_id: model_id, messages: messages}` maps,
  suitable for UI logging display.
  """
  @spec build_messages_for_models(map(), list(String.t()), keyword()) :: list(map())
  def build_messages_for_models(state, model_ids, opts \\ []) do
    Enum.map(model_ids, fn model_id ->
      %{model_id: model_id, messages: build_messages_for_model(state, model_id, opts)}
    end)
  end

  # Private helpers

  defp maybe_append_refinement_prompt(messages, opts) do
    case Keyword.get(opts, :refinement_prompt) do
      nil ->
        messages

      refinement_prompt ->
        timestamped_prompt = MessageTimestamp.prepend(refinement_prompt)
        merge_into_last_user_message(messages, timestamped_prompt)
    end
  end

  # Merge refinement prompt into the last user message to maintain alternation.
  # History always ends with a user-role message (:user, :result, :event all map to "user").
  defp merge_into_last_user_message(messages, content) do
    case Enum.reverse(messages) do
      [%{role: "user", content: prev} = last | rest] ->
        merged = merge_content(prev, content)
        Enum.reverse([%{last | content: merged} | rest])

      _ ->
        # Fallback: append as new message (shouldn't happen in practice)
        messages ++ [%{role: "user", content: content}]
    end
  end

  # Refinement prompt (new) is always a binary string from MessageTimestamp.prepend.
  # Previous content may be binary (normal) or list (multimodal).
  defp merge_content(prev, new) when is_binary(prev) and is_binary(new),
    do: prev <> "\n\n" <> new

  defp merge_content(prev, new) when is_list(prev) and is_binary(new),
    do: prev ++ [%{type: :text, text: new}]
end
