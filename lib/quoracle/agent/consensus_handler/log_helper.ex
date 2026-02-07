defmodule Quoracle.Agent.ConsensusHandler.LogHelper do
  @moduledoc """
  Logging helpers for ConsensusHandler.
  Extracted to maintain <500 line modules.
  """

  require Logger
  alias Quoracle.PubSub.AgentEvents

  @doc """
  Safely broadcasts log events, handling cleanup edge cases where PubSub is gone.
  """
  @spec safe_broadcast_log(String.t(), atom(), String.t(), map(), atom()) :: :ok
  def safe_broadcast_log(agent_id, level, message, metadata, pubsub) do
    try do
      AgentEvents.broadcast_log(agent_id, level, message, metadata, pubsub)
    rescue
      ArgumentError -> :ok
    end
  end

  @warning_errors [
    :missing_required_param,
    :invalid_param,
    :unknown_parameter,
    :service_unavailable
  ]

  @doc """
  Log action errors - validation/transient errors at warning level, system errors at error level.
  """
  @spec log_action_error(term()) :: :ok
  def log_action_error(reason) when reason in @warning_errors do
    Logger.warning("Action failed: #{inspect(reason)}")
  end

  # Registry errors during test cleanup are warnings, not errors
  def log_action_error({:action_crashed, msg}) when is_binary(msg) do
    if String.contains?(msg, "registry") do
      Logger.warning("Action crashed (cleanup): #{msg}")
    else
      Logger.error("Action execution failed: {:action_crashed, #{inspect(msg)}}")
    end
  end

  def log_action_error(reason) do
    Logger.error("Action execution failed: #{inspect(reason)}")
  end
end
