defmodule Quoracle.Models.ModelQuery.UsageHelper do
  @moduledoc """
  Helper module for LLM usage and cost calculations.
  Extracted from ModelQuery for module size compliance (<500 lines).
  """

  alias Quoracle.Costs.{Accumulator, AgentCost, Recorder}
  alias Quoracle.Costs.Recorder, as: CostRecorder
  alias Quoracle.Repo
  require Logger

  @doc """
  Calculates aggregate usage from a list of LLM responses.

  Sums input/output tokens and costs across all responses.
  Handles nil cost values by treating them as zero.

  ## Parameters
  - `responses`: List of ReqLLM.Response structs or legacy map responses

  ## Returns
  Map with input_tokens, output_tokens, input_cost, output_cost, total_cost
  """
  @spec calculate_aggregate_usage(list(map())) :: map()
  def calculate_aggregate_usage(responses) do
    initial = %{
      input_tokens: 0,
      output_tokens: 0,
      input_cost: Decimal.new(0),
      output_cost: Decimal.new(0),
      total_cost: Decimal.new(0)
    }

    Enum.reduce(responses, initial, fn response, acc ->
      # Handle ReqLLM.Response, legacy map responses, and raw usage maps
      usage =
        case response do
          %ReqLLM.Response{usage: usage} when is_map(usage) -> usage
          %{usage: usage} when is_map(usage) -> usage
          # Raw usage map (has input_tokens directly)
          %{input_tokens: _} = raw_usage -> raw_usage
          _ -> %{}
        end

      %{
        input_tokens: acc.input_tokens + Map.get(usage, :input_tokens, 0),
        output_tokens: acc.output_tokens + Map.get(usage, :output_tokens, 0),
        input_cost: Decimal.add(acc.input_cost, to_decimal(Map.get(usage, :input_cost))),
        output_cost: Decimal.add(acc.output_cost, to_decimal(Map.get(usage, :output_cost))),
        total_cost: Decimal.add(acc.total_cost, to_decimal(Map.get(usage, :total_cost)))
      }
    end)
  end

  @doc """
  Records costs for each successful model response.
  Only records if agent_id, task_id, and pubsub are all present in options.
  Handles sandbox owner exit gracefully during test cleanup.
  """
  @spec maybe_record_costs(list({String.t(), map()}), map()) :: :ok
  def maybe_record_costs(successful_with_models, options) do
    agent_id = Map.get(options, :agent_id)
    task_id = Map.get(options, :task_id)
    pubsub = Map.get(options, :pubsub)
    cost_type = Map.get(options, :cost_type, "llm_consensus")

    # Only record if all required context is present
    if agent_id && task_id && pubsub do
      Enum.each(successful_with_models, fn {model_name, response} ->
        usage = extract_usage(response)

        cost_data = %{
          agent_id: agent_id,
          task_id: task_id,
          cost_type: cost_type,
          cost_usd: extract_total_cost(usage),
          metadata: %{
            "model_spec" => model_name,
            "input_tokens" => Map.get(usage, :input_tokens),
            "output_tokens" => Map.get(usage, :output_tokens),
            "reasoning_tokens" => Map.get(usage, :reasoning_tokens),
            "cached_tokens" => Map.get(usage, :cached_tokens),
            "cache_creation_tokens" => Map.get(usage, :cache_creation_input_tokens),
            "input_cost" => format_cost(Map.get(usage, :input_cost)),
            "output_cost" => format_cost(Map.get(usage, :output_cost)),
            "total_cost" => format_cost(Map.get(usage, :total_cost))
          }
        }

        # Handle sandbox owner exit gracefully during test cleanup
        # This prevents Postgrex "client exited" errors when test process
        # exits while Core GenServer is still recording costs
        try do
          CostRecorder.record(cost_data, pubsub: pubsub)
        catch
          :exit, {:shutdown, %DBConnection.ConnectionError{}} ->
            # Expected during async test cleanup when sandbox owner exits
            :ok

          :exit, _reason ->
            # Other exit reasons during test cleanup
            :ok
        end
      end)
    else
      Logger.warning(
        "Cost recording skipped: missing context " <>
          "(agent_id=#{inspect(agent_id)}, task_id=#{inspect(task_id)}, " <>
          "pubsub=#{inspect(not is_nil(pubsub))}, cost_type=#{cost_type})"
      )
    end

    :ok
  end

  @doc """
  Records cost for a single AI request (non-consensus).

  Handles response parsing, usage extraction, and database recording.
  Used by answer_engine, embeddings, and other single-request AI calls.

  ## Parameters
  - `response`: ReqLLM.Response, Req.Response body, or map with usage data
  - `cost_type`: String like "llm_answer", "llm_embedding", "llm_condensation"
  - `options`: Map with agent_id, task_id, pubsub (all required)
  - `extra_metadata`: Additional metadata to merge (e.g., sources_count, chunks)

  ## Returns
  :ok (always succeeds, logs errors gracefully)
  """
  @spec record_single_request(map(), String.t(), map(), map()) :: :ok
  def record_single_request(response, cost_type, options, extra_metadata \\ %{}) do
    agent_id = Map.get(options, :agent_id)
    task_id = Map.get(options, :task_id)
    pubsub = Map.get(options, :pubsub)

    if agent_id && task_id && pubsub do
      usage = extract_usage(response)
      model_spec = Map.get(options, :model_spec, "unknown")

      base_metadata = %{
        "model_spec" => model_spec,
        "input_tokens" => Map.get(usage, :input_tokens),
        "output_tokens" => Map.get(usage, :output_tokens),
        "total_cost" => format_cost(Map.get(usage, :total_cost))
      }

      cost_data = %{
        agent_id: agent_id,
        task_id: task_id,
        cost_type: cost_type,
        cost_usd: extract_total_cost(usage),
        metadata: Map.merge(base_metadata, stringify_keys(extra_metadata))
      }

      try do
        CostRecorder.record(cost_data, pubsub: pubsub)
      catch
        :exit, {:shutdown, %DBConnection.ConnectionError{}} -> :ok
        :exit, _reason -> :ok
      end
    else
      Logger.warning(
        "Cost recording skipped: missing context " <>
          "(agent_id=#{inspect(agent_id)}, task_id=#{inspect(task_id)}, " <>
          "pubsub=#{inspect(not is_nil(pubsub))}, cost_type=#{cost_type})"
      )
    end

    :ok
  end

  # Convert atom keys to strings for JSONB storage
  @spec stringify_keys(map()) :: map()
  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  @doc """
  Flushes accumulated costs to the database in a single batch insert.
  Broadcasts each cost record to PubSub after insertion.

  Returns :ok on success. Logs and discards on failure (non-critical path).
  """
  @spec flush_accumulated_costs(Accumulator.t(), atom()) :: :ok
  def flush_accumulated_costs(%Accumulator{} = accumulator, pubsub) when is_atom(pubsub) do
    entries = Accumulator.to_list(accumulator)

    if entries == [] do
      :ok
    else
      do_flush_costs(entries, pubsub)
    end
  end

  defp do_flush_costs(entries, pubsub) do
    # Build insert data with timestamps
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    insert_data =
      Enum.map(entries, fn entry ->
        %{
          id: Ecto.UUID.generate(),
          agent_id: entry.agent_id,
          task_id: entry.task_id,
          cost_type: entry.cost_type,
          cost_usd: entry.cost_usd,
          metadata: entry.metadata || %{},
          inserted_at: now
        }
      end)

    try do
      {_count, inserted} = Repo.insert_all(AgentCost, insert_data, returning: true)

      # Broadcast each inserted cost (maintains existing UI update behavior)
      Enum.each(inserted, fn cost ->
        Recorder.broadcast_cost_recorded(cost, pubsub)
      end)

      :ok
    catch
      kind, reason ->
        Logger.warning(
          "Cost flush failed: #{inspect(kind)} #{inspect(reason)}, " <>
            "discarding #{length(entries)} cost entries"
        )

        :ok
    end
  end

  @doc """
  Extracts usage map from various response formats.
  Handles ReqLLM.Response, legacy map responses, embedding responses, and returns empty map for unknown formats.
  Normalizes string keys to atoms for consistent access.
  """
  @spec extract_usage(map()) :: map()
  def extract_usage(%ReqLLM.Response{usage: usage}) when is_map(usage), do: usage
  def extract_usage(%{usage: usage}) when is_map(usage), do: usage
  # Handle embedding API responses with string keys (Azure OpenAI format)
  def extract_usage(%{"usage" => usage}) when is_map(usage), do: normalize_usage_keys(usage)
  def extract_usage(_), do: %{}

  # Normalize string keys to atoms for embedding responses
  # Maps prompt_tokens -> input_tokens for consistency
  defp normalize_usage_keys(usage) do
    %{
      input_tokens: usage["prompt_tokens"] || usage[:prompt_tokens],
      output_tokens: usage["completion_tokens"] || usage[:completion_tokens] || 0,
      total_tokens: usage["total_tokens"] || usage[:total_tokens],
      total_cost: usage["total_cost"] || usage[:total_cost]
    }
  end

  @doc """
  Extracts total_cost from usage map and converts to Decimal.
  Returns nil if total_cost is not present or cannot be converted.
  """
  @spec extract_total_cost(map()) :: Decimal.t() | nil
  def extract_total_cost(usage) do
    case Map.get(usage, :total_cost) do
      nil -> nil
      value when is_binary(value) -> Decimal.new(value)
      %Decimal{} = value -> value
      value when is_number(value) -> Decimal.from_float(value / 1)
      _ -> nil
    end
  end

  # Convert string/nil cost to Decimal, treating nil as zero
  @spec to_decimal(term()) :: Decimal.t()
  defp to_decimal(nil), do: Decimal.new(0)
  defp to_decimal(value) when is_binary(value), do: Decimal.new(value)
  defp to_decimal(%Decimal{} = value), do: value
  defp to_decimal(value) when is_number(value), do: Decimal.from_float(value / 1)
  defp to_decimal(_), do: Decimal.new(0)

  # Format cost value for JSON storage (string or nil)
  @spec format_cost(term()) :: String.t() | nil
  defp format_cost(nil), do: nil
  defp format_cost(%Decimal{} = d), do: Decimal.to_string(d)
  defp format_cost(f) when is_float(f), do: Float.to_string(f)
  defp format_cost(_), do: nil
end
