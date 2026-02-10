defmodule Quoracle.Actions.RecordCost do
  @moduledoc """
  Records external costs incurred by agents.

  Always succeeds - this is accounting of reality, not permission.
  Rejects negative amounts (no refunds via this action).
  Creates agent_cost entry with cost_type "external".
  """

  alias Quoracle.Costs.Recorder

  @type params :: %{
          required(:amount) => number(),
          optional(:description) => String.t(),
          optional(:category) => String.t(),
          optional(:external_reference_id) => String.t()
        }

  @doc """
  Executes the record_cost action.

  ## Parameters
    - params: Map with :amount (required), optional :description, :category, :external_reference_id
    - agent_id: The agent recording the cost
    - opts: Keyword list with :pubsub and :task_id (required)

  ## Returns
    - {:ok, map()} on success with action details
    - {:error, :invalid_amount} if amount is not positive
  """
  @spec execute(params(), String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def execute(params, agent_id, opts) do
    amount = Map.fetch!(params, :amount)

    with :ok <- validate_positive(amount),
         decimal_amount <- to_decimal(amount),
         {:ok, _cost} <- record_cost(agent_id, decimal_amount, params, opts) do
      {:ok,
       %{
         action: "record_cost",
         amount: Decimal.to_string(decimal_amount),
         description: Map.get(params, :description),
         category: Map.get(params, :category),
         message: "Recorded external cost of $#{Decimal.round(decimal_amount, 2)}"
       }}
    end
  end

  @spec validate_positive(number()) :: :ok | {:error, :invalid_amount}
  defp validate_positive(amount) when is_number(amount) and amount > 0, do: :ok
  defp validate_positive(_), do: {:error, :invalid_amount}

  @spec to_decimal(number()) :: Decimal.t()
  defp to_decimal(amount) when is_float(amount), do: Decimal.from_float(amount)
  defp to_decimal(amount) when is_integer(amount), do: Decimal.new(amount)

  @spec record_cost(String.t(), Decimal.t(), map(), keyword()) ::
          {:ok, Quoracle.Costs.AgentCost.t()} | {:error, Ecto.Changeset.t()}
  defp record_cost(agent_id, amount, params, opts) do
    pubsub = Keyword.fetch!(opts, :pubsub)
    task_id = Keyword.fetch!(opts, :task_id)

    Recorder.record(
      %{
        agent_id: agent_id,
        task_id: task_id,
        cost_type: "external",
        cost_usd: amount,
        metadata: %{
          "description" => Map.get(params, :description),
          "category" => Map.get(params, :category),
          "external_reference_id" => Map.get(params, :external_reference_id)
        }
      },
      pubsub: pubsub
    )
  end
end
