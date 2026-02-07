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
      :file_write
    ]
  end

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

  @doc "Prepend text to message content, handling both binary and multimodal (list) formats."
  @spec prepend_to_content(String.t(), binary() | list()) :: binary() | list()
  def prepend_to_content(prefix, content) when is_list(content) do
    [%{type: :text, text: prefix} | content]
  end

  def prepend_to_content(prefix, content) when is_binary(content) do
    prefix <> content
  end
end
