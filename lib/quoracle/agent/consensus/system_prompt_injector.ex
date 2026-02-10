defmodule Quoracle.Agent.Consensus.SystemPromptInjector do
  @moduledoc """
  System prompt injection for consensus messages.
  Ensures messages have proper system prompts with action schemas and field-based configuration.
  Extracted from AGENT_Consensus to maintain <500 line modules.
  """

  alias Quoracle.Consensus.PromptBuilder

  @doc "Ensures messages array has both action schema and field-based prompts."
  @spec ensure_system_prompts(list(map()), map()) :: list(map())
  def ensure_system_prompts(messages, field_prompts) do
    ensure_system_prompts(messages, field_prompts, [])
  end

  @doc "Ensures messages have combined system prompt with field-based configuration."
  @spec ensure_system_prompts(list(map()), map(), keyword()) :: list(map())
  def ensure_system_prompts(messages, field_prompts, opts) do
    # Pass field_prompts through opts to build_system_prompt_with_context
    opts_with_fields = Keyword.put(opts, :field_prompts, field_prompts)

    # Build single integrated system prompt
    integrated_system_prompt =
      PromptBuilder.build_system_prompt_with_context(opts_with_fields)

    # Separate action schema prompts (to be replaced) from additional context (to be preserved)
    {_action_schema_msgs, other_system_msgs} =
      Enum.split_with(
        Enum.filter(messages, &(&1.role == "system")),
        &String.contains?(&1.content, "Available Actions")
      )

    # Extract content from additional system messages (e.g., secrets) to append
    additional_system_content = Enum.map_join(other_system_msgs, "\n\n", & &1.content)

    # Combine integrated prompt with any additional system content
    final_system_prompt =
      if additional_system_content == "" do
        integrated_system_prompt
      else
        integrated_system_prompt <> "\n\n" <> additional_system_content
      end

    # Build messages without any system prompts, then add the combined one
    messages_without_system = Enum.reject(messages, &(&1.role == "system"))

    # v15.0: Return messages with system prompt only - no user_prompt injection
    # Initial user message now flows through history via MessageHandler
    [%{role: "system", content: final_system_prompt} | messages_without_system]
  end

  @doc "Extracts field-based prompts (system_prompt, user_prompt) from messages."
  @spec extract_field_prompts(list(map())) :: map()
  def extract_field_prompts(messages) do
    # Find field-based system prompt (has <role> or <cognitive_style> tags)
    field_system =
      Enum.find(messages, fn msg ->
        msg.role == "system" &&
          (String.contains?(msg.content, "<role>") ||
             String.contains?(msg.content, "<cognitive_style>"))
      end)

    # Find field-based user prompt (has <task> tag)
    field_user =
      Enum.find(messages, fn msg ->
        msg.role == "user" && String.contains?(msg.content, "<task>")
      end)

    result = %{}

    result =
      if field_system, do: Map.put(result, :system_prompt, field_system.content), else: result

    if field_user, do: Map.put(result, :user_prompt, field_user.content), else: result
  end
end
