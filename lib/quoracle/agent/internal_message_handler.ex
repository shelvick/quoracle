defmodule Quoracle.Agent.InternalMessageHandler do
  @moduledoc """
  Handles internal process messages for Agent.Core.
  Extracted from MessageHandler to keep it under 500 lines.
  """

  require Logger

  @doc """
  Handle internal process messages that bypass consensus.
  Internal messages are used for agent coordination and state management.
  """
  @spec handle_internal_message(map(), atom(), any()) :: {:noreply, map()}
  def handle_internal_message(state, type, data) do
    # Internal process messages bypass consensus
    Logger.debug("Agent #{state.agent_id} received internal message: #{type}")

    case type do
      :child_spawned ->
        # Add child to tracking list
        {:noreply, %{state | children: [data | state.children]}}

      :child_terminated ->
        # Remove child from tracking list
        {:noreply, %{state | children: List.delete(state.children, data)}}

      _ ->
        Logger.warning("Unknown internal message type: #{type}")
        {:noreply, state}
    end
  end
end
