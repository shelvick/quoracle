defmodule Quoracle.Groves.LogHelper do
  @moduledoc """
  Shared logging helper for grove modules.

  In test environments, the global Logger level is set to :error, which
  suppresses :warning messages.  This helper mirrors the warning at :error
  level so that `capture_log/1` assertions still work.

  """

  require Logger

  @doc """
  Logs a message at :warning level.  When the runtime Logger level is
  above :warning (e.g. :error in tests), mirrors the same message at
  :error so `capture_log/1` captures it.
  """
  @spec log_warning(String.t()) :: :ok
  def log_warning(message) when is_binary(message) do
    Logger.bare_log(:warning, message)

    # In test env, global logger level is :error, so mirror the message at :error
    # to keep warning-behavior assertions observable via capture_log/1.
    if Logger.compare_levels(Logger.level(), :warning) == :gt do
      Logger.bare_log(:error, message)
    end

    :ok
  end
end
