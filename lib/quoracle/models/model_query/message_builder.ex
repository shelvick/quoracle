defmodule Quoracle.Models.ModelQuery.MessageBuilder do
  @moduledoc """
  Builds ReqLLM messages from string-role messages.
  Handles multimodal content (text + images) with various input formats.
  Extracted from ModelQuery for 500-line module limit.
  """

  alias Quoracle.Utils.ImageCompressor

  @doc """
  Validates that all messages have correct format.
  Returns :ok or {:error, :invalid_message_format}.
  """
  @spec validate_messages([map()]) :: :ok | {:error, :invalid_message_format}
  def validate_messages(messages) do
    if Enum.all?(messages, &valid_message?/1) do
      :ok
    else
      {:error, :invalid_message_format}
    end
  end

  @doc """
  Checks if a message has valid structure (role + content).
  """
  @spec valid_message?(map()) :: boolean()
  def valid_message?(%{role: role, content: content})
      when is_binary(role) and is_binary(content) do
    true
  end

  # Accept list content (multimodal: text + images)
  def valid_message?(%{role: role, content: content})
      when is_binary(role) and is_list(content) do
    Enum.all?(content, &valid_content_part?/1)
  end

  def valid_message?(%{role: role}) when is_binary(role), do: false
  def valid_message?(_), do: false

  # Validate content parts - must have :type field (atom or string key/value)
  defp valid_content_part?(%ReqLLM.Message.ContentPart{}), do: true
  defp valid_content_part?(%{type: type}) when is_atom(type), do: true
  defp valid_content_part?(%{type: type}) when is_binary(type), do: true
  defp valid_content_part?(%{"type" => type}) when is_binary(type), do: true
  defp valid_content_part?(_), do: false

  @doc """
  Build ReqLLM.Message list from messages with string or list content.
  """
  @spec build_messages([map()]) :: [ReqLLM.Message.t()]
  def build_messages(messages) do
    Enum.map(messages, fn msg ->
      case msg.content do
        content when is_binary(content) ->
          # String content - use ReqLLM.Context helpers
          build_text_message(msg.role, content)

        content when is_list(content) ->
          # List content (multimodal) - build Message with ContentParts
          build_multimodal_message(msg.role, content)
      end
    end)
  end

  defp build_text_message(role, content) do
    case role do
      "system" -> ReqLLM.Context.system(content)
      "user" -> ReqLLM.Context.user(content)
      "assistant" -> ReqLLM.Context.assistant(content)
      _ -> ReqLLM.Context.user(content)
    end
  end

  defp build_multimodal_message(role, content_parts) do
    role_atom =
      case role do
        "system" -> :system
        "user" -> :user
        "assistant" -> :assistant
        _ -> :user
      end

    parts = Enum.map(content_parts, &to_content_part/1)

    %ReqLLM.Message{
      role: role_atom,
      content: parts
    }
  end

  # Convert various content part formats to ReqLLM.Message.ContentPart
  # Idempotent - already a ContentPart struct passes through
  defp to_content_part(%ReqLLM.Message.ContentPart{} = part), do: part

  # Map with atom keys and atom type values
  defp to_content_part(%{type: :text, text: text}) do
    ReqLLM.Message.ContentPart.text(text)
  end

  defp to_content_part(%{type: :image_url, url: url}) do
    ReqLLM.Message.ContentPart.image_url(url)
  end

  defp to_content_part(%{type: :image_url, image_url: %{url: url}}) do
    ReqLLM.Message.ContentPart.image_url(url)
  end

  defp to_content_part(%{type: :image, data: data, media_type: media_type}) do
    {:ok, compressed, final_media_type} = ImageCompressor.maybe_compress(data, media_type)
    ReqLLM.Message.ContentPart.image(compressed, final_media_type)
  end

  defp to_content_part(%{type: :image, data: data}) do
    {:ok, compressed, media_type} = ImageCompressor.maybe_compress(data, "image/png")
    ReqLLM.Message.ContentPart.image(compressed, media_type)
  end

  # Map with atom keys and string type values (common in Elixir code)
  defp to_content_part(%{type: "text", text: text}) do
    ReqLLM.Message.ContentPart.text(text)
  end

  defp to_content_part(%{type: "image_url", url: url}) do
    ReqLLM.Message.ContentPart.image_url(url)
  end

  defp to_content_part(%{type: "image_url", image_url: %{url: url}}) do
    ReqLLM.Message.ContentPart.image_url(url)
  end

  defp to_content_part(%{type: "image", data: data, media_type: media_type}) do
    {:ok, compressed, final_media_type} = ImageCompressor.maybe_compress(data, media_type)
    ReqLLM.Message.ContentPart.image(compressed, final_media_type)
  end

  defp to_content_part(%{type: "image", data: data}) do
    {:ok, compressed, media_type} = ImageCompressor.maybe_compress(data, "image/png")
    ReqLLM.Message.ContentPart.image(compressed, media_type)
  end

  # Map with string keys (from JSON)
  defp to_content_part(%{"type" => "text", "text" => text}) do
    ReqLLM.Message.ContentPart.text(text)
  end

  defp to_content_part(%{"type" => "image_url", "url" => url}) do
    ReqLLM.Message.ContentPart.image_url(url)
  end

  defp to_content_part(%{"type" => "image_url", "image_url" => %{"url" => url}}) do
    ReqLLM.Message.ContentPart.image_url(url)
  end

  defp to_content_part(%{"type" => "image", "data" => data, "media_type" => media_type}) do
    {:ok, compressed, final_media_type} = ImageCompressor.maybe_compress(data, media_type)
    ReqLLM.Message.ContentPart.image(compressed, final_media_type)
  end

  defp to_content_part(%{"type" => "image", "data" => data}) do
    {:ok, compressed, media_type} = ImageCompressor.maybe_compress(data, "image/png")
    ReqLLM.Message.ContentPart.image(compressed, media_type)
  end
end
