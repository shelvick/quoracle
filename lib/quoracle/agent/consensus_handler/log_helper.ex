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
    :invalid_param_type,
    :invalid_url,
    :invalid_url_format,
    :invalid_url_scheme,
    :unknown_parameter,
    :unknown_action,
    :service_unavailable,
    :connection_refused,
    :connection_closed,
    :timeout,
    :econnrefused
  ]

  @doc """
  Log action errors - validation/transient errors at warning level, system errors at error level.
  """
  @spec log_action_error(term()) :: :ok
  def log_action_error(reason) when reason in @warning_errors do
    Logger.warning("Action failed: #{inspect(reason)}")
  end

  # L5: Unwrap {:error, reason} wrapper (from ActionResultHandler)
  def log_action_error({:error, reason}) do
    log_action_error(reason)
  end

  # L4: Handle {:action_crashed, tuple_reason} (noproc, timeout, etc.)
  def log_action_error({:action_crashed, reason}) when is_tuple(reason) do
    Logger.error("Action execution crashed: {:action_crashed, #{inspect(reason)}}")
  end

  # Registry errors during test cleanup are warnings, not errors
  def log_action_error({:action_crashed, msg}) when is_binary(msg) do
    if String.contains?(msg, "registry") do
      Logger.warning("Action crashed (cleanup): #{msg}")
    else
      Logger.error("Action execution failed: {:action_crashed, #{inspect(msg)}}")
    end
  end

  # Grove policy denials are expected control-flow, not runtime failures.
  def log_action_error({:confinement_violation, details}) do
    Logger.info("Action blocked by grove confinement: #{inspect(details)}")
  end

  def log_action_error({:hard_rule_violation, details}) do
    Logger.info("Action blocked by grove hard rule: #{inspect(details)}")
  end

  def log_action_error(reason) do
    Logger.error("Action execution failed: #{inspect(reason)}")
  end
end
