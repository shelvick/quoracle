defmodule Quoracle.Agent.ConsensusHandler.Helpers do
  @moduledoc """
  Helper functions for ConsensusHandler.
  Extracted to maintain 500-line limit in parent module.
  """

  @doc "Actions that complete instantly - wait:true on these stalls indefinitely."
  @spec self_contained_actions() :: [atom()]
  def self_contained_actions do
    [
      :orient,
      :todo,
      :generate_secret,
      :search_secrets,
      :learn_skills,
      :create_skill,
      # Added 2026-01-16: These have no external responder, wait:true stalls indefinitely
      :adjust_budget,
      :file_read,
      :file_write,
      # batch_sync completes inline and returns collected results - no external responder
      # at the batch level (sub-action side-effects arrive as separate agent messages)
      :batch_sync
    ]
  end

  @doc """
  Check if a batch_sync action has all self-contained sub-actions.

  Returns true only when every sub-action in the batch is in self_contained_actions().
  Mixed batches (e.g., file_read + send_message) return false because the non-self-contained
  sub-action may trigger an external response the agent should wait for.
  """
  @spec batch_all_self_contained?(map()) :: boolean()
  def batch_all_self_contained?(%{params: %{actions: actions}}) when is_list(actions) do
    self_contained = self_contained_actions()

    Enum.all?(actions, fn
      %{action: action_type} -> to_action_atom(action_type) in self_contained
      %{"action" => action_type} -> to_action_atom(action_type) in self_contained
      _ -> false
    end)
  end

  def batch_all_self_contained?(_action_response), do: false

  defp to_action_atom(action_type) when is_atom(action_type), do: action_type

  defp to_action_atom(action_type) when is_binary(action_type),
    do: String.to_existing_atom(action_type)

  @doc "Normalize sibling_context: empty map -> empty list (LLM JSON confusion fix)."
  @spec normalize_sibling_context(map()) :: map()
  def normalize_sibling_context(%{params: params} = action_response) do
    case Map.get(params, :sibling_context) do
      value when value == %{} ->
        %{action_response | params: Map.put(params, :sibling_context, [])}

      _ ->
        action_response
    end
  end

  def normalize_sibling_context(action_response), do: action_response

  @doc """
  Coerce string wait values to native Elixir types.

  LLMs return strings from JSON ("true"/"false"), but the wait parameter
  needs native booleans/numbers for pattern matching throughout ActionExecutor.
  """
  @spec coerce_wait_value(term()) :: boolean() | number() | nil
  def coerce_wait_value("true"), do: true
  def coerce_wait_value("false"), do: false
  def coerce_wait_value(other), do: other

  @doc """
  Extract check_id from shell action params for routing through existing Router.

  Shell termination uses `check_id` + `terminate: true`, not a separate param.
  Returns the check_id value for shell actions, nil for all other actions.
  """
  @spec extract_shell_check_id(map(), atom()) :: String.t() | nil
  def extract_shell_check_id(params, :execute_shell) when is_map(params) do
    Map.get(params, "check_id") || Map.get(params, :check_id)
  end

  def extract_shell_check_id(_params, _action_atom), do: nil

  @doc "Prepend text to message content, handling both binary and multimodal (list) formats."
  @spec prepend_to_content(String.t(), binary() | list()) :: binary() | list()
  def prepend_to_content(prefix, content) when is_list(content) do
    [%{type: :text, text: prefix} | content]
  end

  def prepend_to_content(prefix, content) when is_binary(content) do
    prefix <> content
  end
end
