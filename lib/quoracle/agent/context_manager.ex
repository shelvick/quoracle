defmodule Quoracle.Agent.ContextManager do
  @moduledoc """
  Conversation context and message management for AGENT_Core.
  Handles history building, context injection, and message formatting.

  Note: Context condensation is handled by AGENT_Consensus/PerModelQuery
  using ACE (Agentic Context Engineering) with proper lesson extraction.
  """

  require Logger

  alias Quoracle.Utils.JSONNormalizer
  alias Quoracle.Utils.MessageTimestamp

  @doc """
  Builds conversation messages for a specific model's history.
  Used by consensus to construct LLM context per model.
  Returns messages in chronological order (oldest first).
  Injects context summary, additional context, and lessons/state.
  Merges consecutive same-role messages to maintain alternation.
  """
  @spec build_conversation_messages(map(), String.t()) :: list(map())
  def build_conversation_messages(state, model_id) do
    # Get this model's specific history
    history = Map.get(state.model_histories, model_id, [])

    # NOTE: ACE context (lessons/model_state) is now injected by AceInjector
    # into the FIRST user message, not as a system message here.
    # This makes lessons visible in UI conversation history.

    # Start with context summary if present
    context_summary = Map.get(state, :context_summary)

    messages =
      if context_summary do
        [%{role: "system", content: "Previous context summary: #{context_summary}"}]
      else
        []
      end

    # Add additional context (including secrets) if present
    additional = Map.get(state, :additional_context, [])
    messages = messages ++ additional

    # Convert history entries to messages (oldest first for LLM)
    history_messages =
      history
      |> Enum.reverse()
      |> Enum.map(&format_history_entry/1)
      |> Enum.reject(&is_nil/1)

    # Combine all messages and merge consecutive same-role messages
    (messages ++ history_messages)
    |> merge_consecutive_messages()
  end

  # Merges consecutive messages with the same role to maintain alternation
  # Required by Claude/Bedrock APIs which reject consecutive same-role messages
  # Handles both string content and multimodal (list) content
  @spec merge_consecutive_messages(list(map())) :: list(map())
  defp merge_consecutive_messages([]), do: []

  defp merge_consecutive_messages(messages) do
    messages
    |> Enum.reduce([], fn msg, acc ->
      case acc do
        [%{role: role, content: prev_content} | rest] when role == msg.role ->
          # Same role - merge content (handles string and list content)
          merged = %{role: role, content: merge_content(prev_content, msg.content)}
          [merged | rest]

        _ ->
          # Different role - add as new message
          [msg | acc]
      end
    end)
    |> Enum.reverse()
  end

  # Merge message content - handles string, list, and mixed content types
  defp merge_content(prev, new) when is_binary(prev) and is_binary(new) do
    prev <> "\n\n" <> new
  end

  defp merge_content(prev, new) when is_list(prev) and is_list(new) do
    prev ++ new
  end

  defp merge_content(prev, new) when is_binary(prev) and is_list(new) do
    [%{type: :text, text: prev}] ++ new
  end

  defp merge_content(prev, new) when is_list(prev) and is_binary(new) do
    prev ++ [%{type: :text, text: new}]
  end

  # NOTE: build_context_prefix/2 and format_lessons/1 removed in v7.0
  # ACE context is now injected by AceInjector into first user message

  # Format a single history entry into a message map
  # Wrapped with error handling to guarantee valid output and log failures
  defp format_history_entry(entry) do
    try do
      do_format_history_entry(entry)
    rescue
      e ->
        Logger.error(
          "format_history_entry failed: #{Exception.message(e)}, " <>
            "entry: #{inspect(entry, limit: 300, pretty: true)}"
        )

        # Return valid message to preserve alternation
        %{role: "user", content: "[Message formatting error: #{Exception.message(e)}]"}
    end
  end

  defp do_format_history_entry(entry) do
    content_str =
      case Map.get(entry, :type) do
        :prompt ->
          Map.get(entry, :content)

        :event ->
          content = Map.get(entry, :content)

          cond do
            # v6.0: Format events with sender info as JSON
            is_map(content) && Map.has_key?(content, :from) ->
              JSONNormalizer.normalize(content)

            # Legacy: Extract content only (no sender)
            is_map(content) && Map.has_key?(content, :content) ->
              Map.get(content, :content)

            # Fallback: inspect unknown content types
            true ->
              inspect(content)
          end

        :decision ->
          JSONNormalizer.normalize(Map.get(entry, :content))

        :result ->
          # Content is already normalized and wrapped with NO_EXECUTE at storage time
          Map.get(entry, :content)

        :user ->
          content = Map.get(entry, :content)

          if is_map(content) && Map.has_key?(content, :content) do
            Map.get(content, :content)
          else
            content
          end

        :assistant ->
          Map.get(entry, :content)

        # Multimodal content - list of ContentPart-like maps (text, image_url, image)
        # Returned as-is; no JSON normalization needed
        :image ->
          Map.get(entry, :content)

        _ ->
          Map.get(entry, :content)
      end

    case Map.get(entry, :type, :user) do
      :prompt ->
        %{role: "user", content: prepend_timestamp(entry, content_str)}

      :event ->
        %{role: "user", content: prepend_timestamp(entry, content_str)}

      :decision ->
        %{role: "assistant", content: content_str}

      :result ->
        %{role: "user", content: prepend_timestamp(entry, content_str)}

      :user ->
        %{role: "user", content: prepend_timestamp(entry, content_str)}

      :assistant ->
        %{role: "assistant", content: content_str}

      # Multimodal: content_str is already a list, prepend_timestamp handles it
      :image ->
        %{role: "user", content: prepend_timestamp(entry, content_str)}

      unknown_type ->
        Logger.error(
          "[AlternationGuard] format_history_entry unknown type: #{inspect(unknown_type)}, " <>
            "entry: #{inspect(entry, limit: 200)}"
        )

        # Return valid message instead of raw entry to preserve alternation
        %{role: "user", content: prepend_timestamp(entry, inspect(entry[:content], limit: 500))}
    end
  end

  # Prepends human-readable UTC timestamp to user-role message content.
  # Uses stored entry timestamp, or current time as fallback.
  # Handles string content, multimodal (list) content, and unexpected types (with logging).
  @spec prepend_timestamp(map(), term()) :: String.t() | list()
  defp prepend_timestamp(entry, content) when is_binary(content) do
    timestamp = Map.get(entry, :timestamp)
    MessageTimestamp.prepend(content, timestamp)
  end

  defp prepend_timestamp(entry, content) when is_list(content) do
    timestamp = Map.get(entry, :timestamp)
    timestamp_str = MessageTimestamp.format(timestamp)
    # Prepend timestamp as text content part
    [%{type: :text, text: "[#{timestamp_str}]"} | content]
  end

  # Catch-all for unexpected content types - log and convert to string
  defp prepend_timestamp(entry, content) do
    Logger.error(
      "[AlternationGuard] prepend_timestamp received unexpected content type: #{inspect(content, limit: 200)}, " <>
        "entry type: #{inspect(Map.get(entry, :type))}, action_type: #{inspect(Map.get(entry, :action_type))}"
    )

    # Convert to string representation to preserve data
    timestamp = Map.get(entry, :timestamp)
    content_str = inspect(content, limit: 500, pretty: true)
    MessageTimestamp.prepend(content_str, timestamp)
  end

  @doc """
  Injects field-based prompts into message list.
  Prepends system_prompt as system message and user_prompt as user message.
  Returns messages unchanged if prompts are nil or empty.
  """
  @spec inject_field_prompts(list(map()), map()) :: list(map())
  def inject_field_prompts(messages, field_prompts) do
    # Build list of prompts to prepend
    prompts_to_add = []

    # Add system_prompt if present
    prompts_to_add =
      case Map.get(field_prompts, :system_prompt) do
        nil -> prompts_to_add
        "" -> prompts_to_add
        system_prompt -> prompts_to_add ++ [%{role: "system", content: system_prompt}]
      end

    # Add user_prompt if present
    prompts_to_add =
      case Map.get(field_prompts, :user_prompt) do
        nil -> prompts_to_add
        "" -> prompts_to_add
        user_prompt -> prompts_to_add ++ [%{role: "user", content: user_prompt}]
      end

    # Prepend field prompts to existing messages
    prompts_to_add ++ messages
  end
end
