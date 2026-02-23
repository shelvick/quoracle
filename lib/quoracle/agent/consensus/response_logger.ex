defmodule Quoracle.Agent.Consensus.ResponseLogger do
  @moduledoc """
  Helpers for logging LLM responses during consensus.
  Extracts only UI-needed fields from ReqLLM.Response objects to prevent
  O(n^2) memory growth from storing full conversation context in log metadata.
  """

  @doc """
  Slim a list of LLM responses for logging, dropping the massive context field.
  """
  @spec slim_responses_for_logging([any()]) :: [map()]
  def slim_responses_for_logging(responses) when is_list(responses) do
    Enum.map(responses, &slim_single_response/1)
  end

  @spec slim_single_response(any()) :: map()
  defp slim_single_response(%ReqLLM.Response{} = response) do
    # Keep all UI-needed fields, drop only the massive context field
    %{
      model: response.model,
      usage: response.usage,
      text: ReqLLM.Response.text(response),
      finish_reason: response.finish_reason,
      latency_ms: Map.get(response, :latency_ms)
    }
  end

  defp slim_single_response(response) when is_map(response) do
    # Fallback for non-struct responses (tests, legacy)
    # Preserve all fields except context to maintain UI compatibility
    response
    |> Map.drop([:context, "context"])
    |> Map.put_new(:text, response[:content] || response["content"])
  end

  defp slim_single_response(other) do
    # Catch-all for nil, error tuples, or unexpected types
    %{model: nil, usage: nil, text: inspect(other), finish_reason: nil, latency_ms: nil}
  end
end
