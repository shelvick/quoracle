defmodule Quoracle.Agent.StateUtils do
  @moduledoc """
  Shared utility functions for agent state management.
  Extracted to avoid circular dependencies between Core and ConsensusHandler.

  ## Per-Model Histories

  Agent state uses `model_histories` - a map of model_id to history list.
  When adding entries, they are appended to ALL model histories simultaneously.
  Query functions (find_*) require a model_id to search a specific history.
  """

  alias Quoracle.Utils.InjectionProtection
  alias Quoracle.Utils.JSONNormalizer

  @doc """
  Adds an entry to ALL model histories in the agent state.
  Each model gets the same entry (identical until condensation diverges them).
  """
  @spec add_history_entry(map(), atom(), any()) :: map()
  def add_history_entry(state, type, content) do
    entry = %{
      type: type,
      content: content,
      timestamp: DateTime.utc_now()
    }

    updated_histories = append_to_all_histories(state.model_histories, entry)
    %{state | model_histories: updated_histories}
  end

  @doc """
  Adds an action result entry with NO_EXECUTE wrapping baked in.

  Content is normalized to JSON and wrapped with NO_EXECUTE tags immediately,
  with a random tag_id generated once and stored. This ensures cache-friendly
  behavior - the same wrapped content is returned on every read.

  The action_id is stored separately to support lookups via find_result_for_action/3.
  """
  @spec add_history_entry_with_action(map(), atom(), {String.t(), any()}, atom()) :: map()
  def add_history_entry_with_action(state, type, {action_id, result}, action_type) do
    # Normalize and wrap content immediately - tag_id generated once and stored
    normalized = JSONNormalizer.normalize({action_id, result})
    wrapped = InjectionProtection.wrap_if_untrusted(normalized, action_type)

    entry = %{
      type: type,
      content: wrapped,
      action_id: action_id,
      result: result,
      action_type: action_type,
      timestamp: DateTime.utc_now()
    }

    updated_histories = append_to_all_histories(state.model_histories, entry)
    %{state | model_histories: updated_histories}
  end

  @doc """
  Finds the most recent decision entry in a specific model's history.
  Returns nil if no decision found or model not in histories.
  """
  @spec find_last_decision(map(), String.t()) :: map() | nil
  def find_last_decision(state, model_id) do
    history = Map.get(state.model_histories, model_id, [])
    Enum.find(history, &(&1.type == :decision))
  end

  @doc """
  Finds the result entry matching the given action_id in a specific model's history.
  Returns nil if no matching result found or model not in histories.
  """
  @spec find_result_for_action(map(), String.t(), String.t()) :: map() | nil
  def find_result_for_action(state, model_id, action_id) do
    history = Map.get(state.model_histories, model_id, [])

    Enum.find(history, fn entry ->
      entry.type == :result && Map.get(entry, :action_id) == action_id
    end)
  end

  # Default model ID used when model_histories is empty (backward compatibility)
  @default_model_id "default"

  # Appends entry to all model histories (prepend for newest-first ordering)
  # SPEC CLARIFICATION: Empty map creates default model to prevent silent message loss
  # Original R4 said "returns empty map" but this causes messages to be dropped.
  # Correct behavior: create default model to preserve backward compatibility.
  defp append_to_all_histories(model_histories, entry) when model_histories == %{} do
    %{@default_model_id => [entry]}
  end

  defp append_to_all_histories(model_histories, entry) do
    Map.new(model_histories, fn {model_id, history} ->
      {model_id, [entry | history]}
    end)
  end

  # =============================================================
  # Timer Cancellation (v5.0)
  # =============================================================

  @doc """
  Cancels any active wait timer and clears the wait_timer field to nil.
  Handles nil, 2-tuple {ref, type}, and 3-tuple {ref, id, gen} formats.
  """
  @spec cancel_wait_timer(map()) :: map()
  def cancel_wait_timer(%{wait_timer: nil} = state), do: state

  def cancel_wait_timer(%{wait_timer: {timer_ref, _type}} = state)
      when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref)
    %{state | wait_timer: nil}
  end

  def cancel_wait_timer(%{wait_timer: {timer_ref, _id, _gen}} = state)
      when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref)
    %{state | wait_timer: nil}
  end

  # Fallback for unknown formats - clear to nil
  def cancel_wait_timer(%{wait_timer: _} = state) do
    %{state | wait_timer: nil}
  end

  # =============================================================
  # Consensus Continuation Scheduling (v6.0)
  # =============================================================

  @doc """
  Schedules a consensus continuation by setting the flag and sending the trigger message.

  Always sets consensus_scheduled = true before sending :trigger_consensus to ensure
  the staleness check in MessageInfoHandler.handle_trigger_consensus/1 processes the message.

  Idempotent: safe to call multiple times (flag overwritten, extra triggers ignored by staleness check).
  """
  @spec schedule_consensus_continuation(map()) :: map()
  def schedule_consensus_continuation(state) do
    send(self(), :trigger_consensus)
    Map.put(state, :consensus_scheduled, true)
  end

  # =============================================================
  # Model Pool Re-keying (v2.0)
  # =============================================================

  @doc """
  Re-keys model histories under new model IDs.

  All new models share the same history reference.
  """
  @spec rekey_model_histories([String.t()], list()) :: %{String.t() => list()}
  def rekey_model_histories(new_model_pool, history) when is_list(new_model_pool) do
    Map.new(new_model_pool, fn model_id -> {model_id, history} end)
  end

  # =============================================================
  # ACE State Merging (v3.0 - extracted from MessageHandler)
  # =============================================================

  @doc """
  Merges condensation state updates from consensus into GenServer state.
  Only merges ACE-related fields (model_histories, context_lessons, model_states).
  Uses conditional update to handle tests using minimal state maps without ACE keys.
  """
  @spec merge_consensus_state(map(), map()) :: map()
  def merge_consensus_state(genserver_state, consensus_state) do
    ace_keys = [:model_histories, :context_lessons, :model_states]

    Enum.reduce(ace_keys, genserver_state, fn key, acc ->
      if Map.has_key?(acc, key) and Map.has_key?(consensus_state, key) do
        Map.put(acc, key, Map.get(consensus_state, key))
      else
        acc
      end
    end)
  end
end
