defmodule Quoracle.Agent.Consensus.ResponseLogger do
  @moduledoc """
  Extracted response logging and slimming utilities for Consensus module.
  Handles broadcasting LLM response summaries to PubSub for UI display,
  and slimming ReqLLM.Response structs to avoid O(n^2) memory growth.
  """

  @doc """
  Broadcasts a debug log for received LLM responses if agent_id and pubsub are provided.
  """
  @spec maybe_log_responses(map(), keyword()) :: :ok
  def maybe_log_responses(result, opts) do
    if opts[:agent_id] && opts[:pubsub] do
      Quoracle.PubSub.AgentEvents.broadcast_log(
        opts[:agent_id],
        :debug,
        "Received #{length(result.successful_responses)} LLM responses",
        %{
          raw_responses: slim_responses_for_logging(result.successful_responses),
          failed_models: result.failed_models,
          total_latency_ms: result.total_latency_ms,
          aggregate_usage: result.aggregate_usage
        },
        opts[:pubsub]
      )
    end

    :ok
  end

  @doc """
  Extracts only the fields needed for UI display from ReqLLM.Response objects.
  Drops the `context` field which contains the full conversation history and
  causes O(n^2) memory growth when stored in log metadata.
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
