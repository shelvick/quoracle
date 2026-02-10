defmodule Quoracle.Utils.MessageTimestamp do
  @moduledoc """
  Utility for adding human-readable UTC timestamps to LLM user-role messages.
  Enables agents to perceive elapsed time between requests.

  ## Format
  `<timestamp>Day, DD Mon YYYY HH:MM:SS +0000</timestamp>` (RFC 2822)

  Timestamps are prepended to message content, preserving the original content.
  """

  @doc """
  Formats a DateTime as an RFC 2822 timestamp string with day-of-week.

  ## Examples

      iex> dt = ~U[2025-12-17 14:30:45Z]
      iex> MessageTimestamp.format(dt)
      "Wed, 17 Dec 2025 14:30:45 +0000"
  """
  @spec format(DateTime.t()) :: String.t()
  def format(%DateTime{} = dt) do
    Calendar.strftime(dt, "%a, %d %b %Y %H:%M:%S +0000")
  end

  @doc """
  Wraps a formatted timestamp in XML tags.

  ## Examples

      iex> MessageTimestamp.wrap("Wed, 17 Dec 2025 14:30:45 +0000")
      "<timestamp>Wed, 17 Dec 2025 14:30:45 +0000</timestamp>"
  """
  @spec wrap(String.t()) :: String.t()
  def wrap(formatted_timestamp) do
    "<timestamp>#{formatted_timestamp}</timestamp>"
  end

  @doc """
  Prepends a timestamp to message content.
  Uses the provided DateTime, or current UTC time if not provided.

  ## Examples

      iex> MessageTimestamp.prepend("Hello", ~U[2025-12-17 14:30:45Z])
      "<timestamp>Wed, 17 Dec 2025 14:30:45 +0000</timestamp>\\nHello"

      iex> MessageTimestamp.prepend("Hello")
      "<timestamp>Wed, 17 Dec 2025 ...></timestamp>\\nHello"
  """
  @spec prepend(String.t(), DateTime.t() | nil) :: String.t()
  def prepend(content, datetime \\ nil) do
    dt = datetime || DateTime.utc_now()
    timestamp_tag = dt |> format() |> wrap()
    "#{timestamp_tag}\n#{content}"
  end

  @doc """
  Prepends timestamp to a message map's content if role is "user".
  Non-user messages are returned unchanged.

  ## Examples

      iex> msg = %{role: "user", content: "Hello"}
      iex> MessageTimestamp.prepend_to_message(msg)
      %{role: "user", content: "<timestamp>Wed, 17 Dec 2025 ...</timestamp>\\nHello"}

      iex> msg = %{role: "assistant", content: "Hi"}
      iex> MessageTimestamp.prepend_to_message(msg)
      %{role: "assistant", content: "Hi"}
  """
  @spec prepend_to_message(map(), DateTime.t() | nil) :: map()
  def prepend_to_message(msg, datetime \\ nil)

  def prepend_to_message(%{role: "user", content: content} = msg, datetime) do
    %{msg | content: prepend(content, datetime)}
  end

  def prepend_to_message(msg, _datetime), do: msg
end
