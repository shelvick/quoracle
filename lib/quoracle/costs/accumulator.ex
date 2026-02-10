defmodule Quoracle.Costs.Accumulator do
  @moduledoc """
  Accumulates cost entries in memory for batch database insertion.

  Used during consensus cycles to reduce DB write pressure.
  Entries are accumulated via add/2 and flushed via UsageHelper.flush_accumulated_costs/2.
  """

  @type cost_entry :: %{
          agent_id: String.t(),
          task_id: binary(),
          cost_type: String.t(),
          cost_usd: Decimal.t() | nil,
          metadata: map()
        }

  @type t :: %__MODULE__{
          entries: [cost_entry()]
        }

  defstruct entries: []

  @doc "Creates a new empty accumulator."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Adds a cost entry to the accumulator."
  @spec add(t(), cost_entry()) :: t()
  def add(%__MODULE__{entries: entries} = acc, entry) when is_map(entry) do
    %{acc | entries: [entry | entries]}
  end

  @doc "Returns all accumulated entries (in insertion order)."
  @spec to_list(t()) :: [cost_entry()]
  def to_list(%__MODULE__{entries: entries}) do
    Enum.reverse(entries)
  end

  @doc "Returns the number of accumulated entries."
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{entries: entries}) do
    length(entries)
  end

  @doc "Checks if accumulator is empty."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{entries: []}), do: true
  def empty?(%__MODULE__{}), do: false
end
