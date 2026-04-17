defmodule Quoracle.Actions.DismissChild.CostTransaction do
  @moduledoc """
  Atomic subtree cost absorption for child dismissal.

  Moves subtree costs to parent absorption rows in a single DB transaction.
  """

  import Ecto.Query

  alias Quoracle.Costs.{AgentCost, Aggregator, Recorder}
  alias Quoracle.Repo

  @type absorption_ctx :: %{
          optional(:task_id) => binary() | nil,
          optional(:child_budget_data) => map() | nil
        }

  @doc """
  Atomically snapshots subtree costs, deletes subtree rows, and inserts parent
  absorption rows.
  """
  @spec absorb_subtree(String.t(), String.t(), absorption_ctx()) ::
          {:ok, [AgentCost.t()]} | {:error, atom() | term()}
  def absorb_subtree(parent_id, child_id, absorption_ctx)
      when is_binary(parent_id) and is_binary(child_id) and is_map(absorption_ctx) do
    Repo.transaction(fn ->
      subtree_ids = collect_subtree_agent_ids(child_id)

      per_model =
        try do
          Aggregator.by_agent_ids_and_model_detailed(subtree_ids)
        catch
          kind, reason ->
            Repo.rollback({:snapshot_failed, {kind, reason}})
        end

      records = build_absorption_records(per_model, parent_id, child_id, absorption_ctx)

      case records do
        [] ->
          []

        _ ->
          with :ok <- validate_absorption_batch(records),
               {_count, _rows} <-
                 Repo.delete_all(from(c in AgentCost, where: c.agent_id in ^subtree_ids)),
               {:ok, inserted} <- Recorder.record_silent_batch(records) do
            inserted
          else
            {:error, :invalid_task_id} -> Repo.rollback(:invalid_task_id)
            {:error, reason} -> Repo.rollback({:insert_failed, reason})
          end
      end
    end)
  end

  @spec collect_subtree_agent_ids(String.t()) :: [String.t()]
  defp collect_subtree_agent_ids(root_id) do
    [root_id | Aggregator.get_descendant_agent_ids(root_id)]
    |> Enum.uniq()
  end

  @spec build_absorption_records([map()], String.t(), String.t(), absorption_ctx()) :: [map()]
  defp build_absorption_records(per_model, parent_id, child_id, absorption_ctx) do
    task_id = Map.get(absorption_ctx, :task_id)
    child_budget_data = Map.get(absorption_ctx, :child_budget_data)

    allocated =
      if is_map(child_budget_data), do: Map.get(child_budget_data, :allocated), else: nil

    tree_spent = sum_tree_costs(per_model)

    per_model
    |> Enum.filter(fn model_row ->
      cost = model_row.total_cost
      cost && not Decimal.equal?(cost, Decimal.new("0"))
    end)
    |> Enum.map(fn model_row ->
      %{
        agent_id: parent_id,
        task_id: task_id,
        cost_type: "child_budget_absorbed",
        cost_usd: model_row.total_cost,
        metadata: build_absorption_metadata(model_row, child_id, allocated, tree_spent)
      }
    end)
  end

  @spec sum_tree_costs([map()]) :: Decimal.t()
  defp sum_tree_costs(per_model) do
    Enum.reduce(per_model, Decimal.new("0"), fn model_row, acc ->
      if model_row.total_cost do
        Decimal.add(acc, model_row.total_cost)
      else
        acc
      end
    end)
  end

  @spec build_absorption_metadata(map(), String.t(), Decimal.t() | nil, Decimal.t()) :: map()
  defp build_absorption_metadata(model_row, child_id, allocated, tree_spent) do
    %{
      "child_agent_id" => child_id,
      "child_allocated" => format_allocated(allocated),
      "child_tree_spent" => decimal_to_string(tree_spent),
      "unspent_returned" => format_unspent(allocated, tree_spent),
      "dismissed_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "model_spec" => model_row.model_spec || "(external)",
      "input_tokens" => to_string(model_row.input_tokens || 0),
      "output_tokens" => to_string(model_row.output_tokens || 0),
      "reasoning_tokens" => to_string(model_row.reasoning_tokens || 0),
      "cached_tokens" => to_string(model_row.cached_tokens || 0),
      "cache_creation_tokens" => to_string(model_row.cache_creation_tokens || 0),
      "input_cost" => decimal_to_string(model_row.input_cost || Decimal.new("0")),
      "output_cost" => decimal_to_string(model_row.output_cost || Decimal.new("0"))
    }
  end

  @spec validate_absorption_batch([map()]) :: :ok | {:error, :invalid_task_id}
  defp validate_absorption_batch(records_to_insert) do
    if Enum.all?(records_to_insert, &valid_absorption_record?/1) do
      :ok
    else
      {:error, :invalid_task_id}
    end
  end

  @spec valid_absorption_record?(map()) :: boolean()
  defp valid_absorption_record?(%{task_id: task_id}) when is_binary(task_id), do: true
  defp valid_absorption_record?(_), do: false

  @spec format_allocated(Decimal.t() | nil) :: String.t()
  defp format_allocated(nil), do: "N/A"
  defp format_allocated(allocated), do: decimal_to_string(allocated)

  @spec format_unspent(Decimal.t() | nil, Decimal.t()) :: String.t()
  defp format_unspent(nil, _tree_spent), do: "0"

  defp format_unspent(allocated, tree_spent) do
    decimal_to_string(Decimal.max(Decimal.sub(allocated, tree_spent), Decimal.new("0")))
  end

  @spec decimal_to_string(Decimal.t()) :: String.t()
  defp decimal_to_string(decimal) do
    if Decimal.equal?(decimal, Decimal.new("0")) do
      "0"
    else
      decimal |> Decimal.round(2) |> Decimal.to_string()
    end
  end
end
