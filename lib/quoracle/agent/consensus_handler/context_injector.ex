defmodule Quoracle.Agent.ConsensusHandler.ContextInjector do
  @moduledoc """
  Injects token count into consensus messages.
  Gives agents visibility into context accumulation for informed condensation decisions.

  Counts tokens from the fully-built message list (after all injections), excluding
  the system prompt. This provides accurate context visibility since agents can't
  control the system prompt overhead.

  Format: `<ctx>12,345 tokens in context</ctx>` appended to end of last user message.
  """

  alias Quoracle.Agent.TokenManager

  @doc """
  Injects token count into the last user message.

  Counts tokens from all non-system messages in the provided list.
  Returns messages unchanged if empty or no user messages.
  """
  @spec inject_context_tokens(list(map())) :: list(map())
  def inject_context_tokens([]), do: []

  def inject_context_tokens(messages) do
    token_count = TokenManager.estimate_messages_tokens(messages)
    context_str = format_context_tokens(token_count)
    append_to_last_user_message(messages, context_str)
  end

  @doc """
  Formats token count as XML with comma-separated thousands.
  Returns string like `<ctx>12,345 tokens in context</ctx>\n`
  """
  @spec format_context_tokens(non_neg_integer()) :: String.t()
  def format_context_tokens(count) do
    formatted = format_with_commas(count)
    "\n<ctx>#{formatted} tokens in context</ctx>\n"
  end

  # Format number with comma separators for thousands
  defp format_with_commas(number) when number < 1000, do: Integer.to_string(number)

  defp format_with_commas(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  # Append content to the end of the last user-role message
  # Supports both atom and string keys, skips non-string content (e.g., multimodal)
  defp append_to_last_user_message(messages, content) do
    case find_last_user_message_index(messages) do
      nil ->
        messages

      idx ->
        List.update_at(messages, idx, fn msg ->
          append_to_message_content(msg, content)
        end)
    end
  end

  # Append to message content, handling both atom and string keys
  defp append_to_message_content(%{content: existing} = msg, content) when is_binary(existing) do
    %{msg | content: existing <> "\n" <> content}
  end

  defp append_to_message_content(%{"content" => existing} = msg, content)
       when is_binary(existing) do
    Map.put(msg, "content", existing <> "\n" <> content)
  end

  # Non-string content (multimodal lists, etc.) - return unchanged
  defp append_to_message_content(msg, _content), do: msg

  # Find index of the last user message in the list
  # Supports both atom and string keys
  defp find_last_user_message_index(messages) do
    messages
    |> Enum.with_index()
    |> Enum.filter(fn {msg, _idx} -> user_message?(msg) end)
    |> List.last()
    |> case do
      nil -> nil
      {_msg, idx} -> idx
    end
  end

  defp user_message?(%{role: "user"}), do: true
  defp user_message?(%{"role" => "user"}), do: true
  defp user_message?(_), do: false
end
