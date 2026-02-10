defmodule Quoracle.Agent.MessageHandler.MessageProcessor do
  @moduledoc """
  Message processing logic for MessageHandler.
  Extracted to keep MessageHandler under 500 lines while maintaining all functionality.
  """

  alias Quoracle.Agent.{StateUtils, MessageBatcher}

  @doc """
  Process a message using the pubsub instance from Core state.
  State must include :pubsub field with the PubSub instance to use.
  """
  @spec process_message(any(), map()) :: map()
  def process_message(message, state) do
    # Extract pubsub from state (required - no defaults)
    _pubsub = Map.fetch!(state, :pubsub)

    # Process message based on type
    case categorize_message(message) do
      :user_message ->
        handle_user_message(message, state)

      :action_result ->
        handle_action_result(message, state)

      :agent_message ->
        handle_agent_message_with_state(message, state)

      _ ->
        state
    end
  end

  defp categorize_message(message), do: MessageBatcher.categorize_message(message)

  defp handle_user_message({:user_message, content}, state) do
    # Add to conversation history
    state = StateUtils.add_history_entry(state, :user, content)
    state
  end

  defp handle_action_result({:action_result, action_id, result}, state) do
    # Extract action_type from pending_actions for NO_EXECUTE tracking
    action_info = Map.get(state.pending_actions, action_id)
    action_type = if action_info, do: Map.get(action_info, :type), else: nil

    # Store result WITH action_type in history
    state =
      if action_type do
        StateUtils.add_history_entry_with_action(state, :result, {action_id, result}, action_type)
      else
        # Fallback for missing action type (shouldn't happen in normal flow)
        StateUtils.add_history_entry(state, :result, {action_id, result})
      end

    # Remove from pending actions
    pending = Map.delete(state.pending_actions, action_id)
    %{state | pending_actions: pending}
  end

  defp handle_agent_message_with_state({:agent_message, from, content}, state) do
    # Add agent message to conversation history
    state = StateUtils.add_history_entry(state, :agent, %{from: from, content: content})
    state
  end
end
