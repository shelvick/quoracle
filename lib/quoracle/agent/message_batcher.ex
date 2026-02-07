defmodule Quoracle.Agent.MessageBatcher do
  @moduledoc """
  Handles message batching and mailbox draining for Agent.Core.
  Extracted from MessageHandler to keep it under 500 lines.
  """

  @doc """
  Drain all pending messages from mailbox before requesting consensus.
  Preserves strict temporal ordering (FIFO).
  """
  @spec drain_mailbox() :: [any()]
  def drain_mailbox() do
    drain_mailbox([])
  end

  defp drain_mailbox(acc) do
    receive do
      msg -> drain_mailbox([msg | acc])
    after
      # Return in FIFO order
      0 -> Enum.reverse(acc)
    end
  end

  @doc """
  Categorize a message by its type for processing.
  """
  @spec categorize_message(any()) :: atom()
  def categorize_message({:user_message, _content}), do: :user_message
  def categorize_message({:action_result, _ref, _result}), do: :action_result
  def categorize_message({:agent_message, _from, _content}), do: :agent_message
  def categorize_message(_), do: :unknown
end
