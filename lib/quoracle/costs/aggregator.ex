defmodule Quoracle.Costs.Aggregator do
  @moduledoc """
  Aggregation queries for agent costs.

  Provides various views into cost data:
  - Per-model totals (which models cost how much)
  - Per-agent own costs (single agent's direct costs)
  - Per-agent children costs (costs of agent's descendants)
  - Per-task totals (entire task tree costs)
  """

  alias Quoracle.Costs.AgentCost
  alias Quoracle.Repo
  import Ecto.Query

  @type cost_summary :: %{
          total_cost: Decimal.t() | nil,
          total_requests: non_neg_integer(),
          by_type: %{String.t() => Decimal.t() | nil}
        }

  @type model_cost :: %{
          model_spec: String.t(),
          total_cost: Decimal.t() | nil,
          request_count: non_neg_integer(),
          total_tokens: non_neg_integer()
        }

  @type model_cost_detailed :: %{
          model_spec: String.t(),
          request_count: non_neg_integer(),
          # Token counts (5 types)
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          reasoning_tokens: non_neg_integer(),
          cached_tokens: non_neg_integer(),
          cache_creation_tokens: non_neg_integer(),
          # Aggregate costs from ReqLLM
          input_cost: Decimal.t() | nil,
          output_cost: Decimal.t() | nil,
          total_cost: Decimal.t() | nil
        }

  # ============================================================
  # Per-Agent Queries (Own Costs)
  # ============================================================

  @doc """
  Returns total costs for a single agent (not including children).
  """
  @spec by_agent(String.t()) :: cost_summary()
  def by_agent(agent_id) do
    query =
      from(c in AgentCost,
        where: c.agent_id == ^agent_id,
        select: %{
          total_cost: sum(c.cost_usd),
          total_requests: count(c.id)
        }
      )

    case Repo.one(query) do
      nil -> %{total_cost: nil, total_requests: 0, by_type: %{}}
      result -> Map.put(result, :by_type, by_agent_and_type(agent_id))
    end
  end

  @doc """
  Returns costs grouped by cost_type for a single agent.
  """
  @spec by_agent_and_type(String.t()) :: %{String.t() => Decimal.t() | nil}
  def by_agent_and_type(agent_id) do
    from(c in AgentCost,
      where: c.agent_id == ^agent_id,
      group_by: c.cost_type,
      select: {c.cost_type, sum(c.cost_usd)}
    )
    |> Repo.all()
    |> Map.new()
  end

  # ============================================================
  # Per-Agent Children Queries (Descendants Only)
  # ============================================================

  @doc """
  Returns total costs for an agent's children (descendants only, NOT self).

  Uses recursive CTE to find all descendant agent_ids, then sums their costs.
  """
  @spec by_agent_children(String.t()) :: cost_summary()
  def by_agent_children(agent_id) do
    child_ids = get_descendant_agent_ids(agent_id)

    if Enum.empty?(child_ids) do
      %{total_cost: nil, total_requests: 0, by_type: %{}}
    else
      query =
        from(c in AgentCost,
          where: c.agent_id in ^child_ids,
          select: %{
            total_cost: sum(c.cost_usd),
            total_requests: count(c.id)
          }
        )

      case Repo.one(query) do
        nil -> %{total_cost: nil, total_requests: 0, by_type: %{}}
        result -> Map.put(result, :by_type, by_agent_ids_and_type(child_ids))
      end
    end
  end

  @doc """
  Returns all descendant agent_ids for a given agent (recursive).
  """
  @spec get_descendant_agent_ids(String.t()) :: [String.t()]
  def get_descendant_agent_ids(agent_id) do
    # Recursive CTE to find all descendants
    # Note: agents.parent_id is a string field containing agent_id, not a UUID
    sql = """
    WITH RECURSIVE descendants AS (
      SELECT agent_id
      FROM agents
      WHERE parent_id = $1

      UNION ALL

      SELECT a.agent_id
      FROM agents a
      INNER JOIN descendants d ON a.parent_id = d.agent_id
    )
    SELECT agent_id FROM descendants
    """

    case Repo.query(sql, [agent_id]) do
      {:ok, %{rows: rows}} -> List.flatten(rows)
      {:error, _} -> []
    end
  end

  defp by_agent_ids_and_type(agent_ids) do
    from(c in AgentCost,
      where: c.agent_id in ^agent_ids,
      group_by: c.cost_type,
      select: {c.cost_type, sum(c.cost_usd)}
    )
    |> Repo.all()
    |> Map.new()
  end

  # ============================================================
  # Per-Task Queries
  # ============================================================

  @doc """
  Returns total costs for an entire task (all agents).
  """
  @spec by_task(binary()) :: cost_summary()
  def by_task(task_id) do
    query =
      from(c in AgentCost,
        where: c.task_id == ^task_id,
        select: %{
          total_cost: sum(c.cost_usd),
          total_requests: count(c.id)
        }
      )

    case Repo.one(query) do
      nil -> %{total_cost: nil, total_requests: 0, by_type: %{}}
      result -> Map.put(result, :by_type, by_task_and_type(task_id))
    end
  end

  @doc """
  Returns costs grouped by cost_type for a task.
  """
  @spec by_task_and_type(binary()) :: %{String.t() => Decimal.t() | nil}
  def by_task_and_type(task_id) do
    from(c in AgentCost,
      where: c.task_id == ^task_id,
      group_by: c.cost_type,
      select: {c.cost_type, sum(c.cost_usd)}
    )
    |> Repo.all()
    |> Map.new()
  end

  # ============================================================
  # Per-Model Queries
  # ============================================================

  @doc """
  Returns costs grouped by model_spec for a task.
  """
  @spec by_task_and_model(binary()) :: [model_cost()]
  def by_task_and_model(task_id) do
    # Query using JSONB extraction for model_spec
    sql = """
    SELECT
      metadata->>'model_spec' as model_spec,
      SUM(cost_usd) as total_cost,
      COUNT(*) as request_count,
      SUM(COALESCE((metadata->>'input_tokens')::integer, 0) +
          COALESCE((metadata->>'output_tokens')::integer, 0)) as total_tokens
    FROM agent_costs
    WHERE task_id = $1
      AND metadata->>'model_spec' IS NOT NULL
    GROUP BY metadata->>'model_spec'
    ORDER BY total_cost DESC NULLS LAST
    """

    # Convert string UUID to binary for Postgrex
    {:ok, uuid_binary} = Ecto.UUID.dump(task_id)

    case Repo.query(sql, [uuid_binary]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [model_spec, cost, count, tokens] ->
          %{
            model_spec: model_spec,
            total_cost: cost,
            request_count: count,
            total_tokens: tokens || 0
          }
        end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Returns costs grouped by model_spec for a single agent.
  """
  @spec by_agent_and_model(String.t()) :: [model_cost()]
  def by_agent_and_model(agent_id) do
    sql = """
    SELECT
      metadata->>'model_spec' as model_spec,
      SUM(cost_usd) as total_cost,
      COUNT(*) as request_count,
      SUM(COALESCE((metadata->>'input_tokens')::integer, 0) +
          COALESCE((metadata->>'output_tokens')::integer, 0)) as total_tokens
    FROM agent_costs
    WHERE agent_id = $1
      AND metadata->>'model_spec' IS NOT NULL
    GROUP BY metadata->>'model_spec'
    ORDER BY total_cost DESC NULLS LAST
    """

    case Repo.query(sql, [agent_id]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [model_spec, cost, count, tokens] ->
          %{
            model_spec: model_spec,
            total_cost: cost,
            request_count: count,
            total_tokens: tokens || 0
          }
        end)

      {:error, _} ->
        []
    end
  end

  # ============================================================
  # Detailed Per-Model Queries (v2.0 - Token Breakdown)
  # ============================================================

  @doc """
  Returns detailed costs grouped by model_spec for a task.
  Includes all 5 token types and aggregate costs.
  """
  @spec by_task_and_model_detailed(binary()) :: [model_cost_detailed()]
  def by_task_and_model_detailed(task_id) do
    {:ok, uuid_binary} = Ecto.UUID.dump(task_id)
    execute_detailed_model_query("task_id", uuid_binary)
  end

  @doc """
  Returns detailed costs grouped by model_spec for a single agent.
  Includes all 5 token types and aggregate costs.
  """
  @spec by_agent_and_model_detailed(String.t()) :: [model_cost_detailed()]
  def by_agent_and_model_detailed(agent_id) do
    execute_detailed_model_query("agent_id", agent_id)
  end

  # Shared SQL execution for detailed model queries
  @spec execute_detailed_model_query(String.t(), binary() | String.t()) :: [model_cost_detailed()]
  defp execute_detailed_model_query(id_column, id_value) do
    sql = """
    SELECT
      metadata->>'model_spec' as model_spec,
      COUNT(*) as request_count,
      SUM(COALESCE((metadata->>'input_tokens')::integer, 0)) as input_tokens,
      SUM(COALESCE((metadata->>'output_tokens')::integer, 0)) as output_tokens,
      SUM(COALESCE((metadata->>'reasoning_tokens')::integer, 0)) as reasoning_tokens,
      SUM(COALESCE((metadata->>'cached_tokens')::integer, 0)) as cached_tokens,
      SUM(COALESCE((metadata->>'cache_creation_tokens')::integer, 0)) as cache_creation_tokens,
      SUM(COALESCE((metadata->>'input_cost')::numeric, 0)) as input_cost,
      SUM(COALESCE((metadata->>'output_cost')::numeric, 0)) as output_cost,
      SUM(cost_usd) as total_cost
    FROM agent_costs
    WHERE #{id_column} = $1
      AND metadata->>'model_spec' IS NOT NULL
    GROUP BY metadata->>'model_spec'
    ORDER BY total_cost DESC NULLS LAST
    """

    case Repo.query(sql, [id_value]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, &row_to_detailed_model_cost/1)

      {:error, _} ->
        []
    end
  end

  @spec row_to_detailed_model_cost(list()) :: model_cost_detailed()
  defp row_to_detailed_model_cost([
         model_spec,
         request_count,
         input_tokens,
         output_tokens,
         reasoning_tokens,
         cached_tokens,
         cache_creation_tokens,
         input_cost,
         output_cost,
         total_cost
       ]) do
    %{
      model_spec: model_spec,
      request_count: request_count,
      input_tokens: input_tokens || 0,
      output_tokens: output_tokens || 0,
      reasoning_tokens: reasoning_tokens || 0,
      cached_tokens: cached_tokens || 0,
      cache_creation_tokens: cache_creation_tokens || 0,
      input_cost: to_decimal_or_nil(input_cost),
      output_cost: to_decimal_or_nil(output_cost),
      total_cost: to_decimal_or_nil(total_cost)
    }
  end

  @spec to_decimal_or_nil(term()) :: Decimal.t() | nil
  defp to_decimal_or_nil(nil), do: nil
  defp to_decimal_or_nil(0), do: nil

  defp to_decimal_or_nil(%Decimal{} = d) do
    if Decimal.eq?(d, 0), do: nil, else: d
  end

  defp to_decimal_or_nil(value) when is_number(value) do
    if value == 0, do: nil, else: Decimal.from_float(value / 1)
  end

  defp to_decimal_or_nil(_), do: nil

  # ============================================================
  # Individual Request Queries (for LogView)
  # ============================================================

  @doc """
  Returns individual cost records for an agent, ordered by time.
  """
  @spec list_by_agent(String.t(), keyword()) :: [AgentCost.t()]
  def list_by_agent(agent_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    from(c in AgentCost,
      where: c.agent_id == ^agent_id,
      order_by: [desc: c.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Returns individual cost records for a task, ordered by time.
  """
  @spec list_by_task(binary(), keyword()) :: [AgentCost.t()]
  def list_by_task(task_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    from(c in AgentCost,
      where: c.task_id == ^task_id,
      order_by: [desc: c.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end
end
