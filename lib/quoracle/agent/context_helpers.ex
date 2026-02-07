defmodule Quoracle.Agent.ContextHelpers do
  @moduledoc """
  Context management helper functions for Agent message handling.
  Extracted from MessageHandler to keep it under 500 lines.
  """

  alias Quoracle.Agent.TokenManager

  @doc """
  Ensures context limits are loaded.
  Lazy loads context limits on first message.

  Note: Context condensation is handled by AGENT_Consensus/PerModelQuery
  using ACE (Agentic Context Engineering) at 100% threshold per-model.
  """
  @spec ensure_context_ready(map()) :: map()
  def ensure_context_ready(state) do
    # Lazy load context limits on first message
    if state.context_limits_loaded do
      state
    else
      context_limit =
        if state.test_mode do
          state.context_limit
        else
          TokenManager.get_model_context_limit(state.model_id)
        end

      %{state | context_limit: context_limit, context_limits_loaded: true}
    end
  end
end
