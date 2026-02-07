defmodule Quoracle.Budget.Schema do
  @moduledoc """
  Type definitions and helpers for budget data stored in agents.state JSONB.

  Budget data is stored as:
  - allocated: Decimal - Total budget allocated to this agent
  - committed: Decimal - Amount locked for children (escrow)
  - mode: :root | :allocated | :na - How budget was assigned

  Spent is NOT stored - derived from COST_Aggregator queries (single source of truth).
  Available = allocated - spent - committed (computed, not stored).
  """

  @type budget_mode :: :root | :allocated | :na

  @type budget_data :: %{
          allocated: Decimal.t() | nil,
          committed: Decimal.t(),
          mode: budget_mode()
        }

  @type child_allocation :: %{
          agent_id: String.t(),
          amount: Decimal.t(),
          allocated_at: DateTime.t()
        }

  @spec new_root(Decimal.t() | nil) :: budget_data()
  def new_root(nil), do: %{allocated: nil, committed: Decimal.new(0), mode: :na}

  def new_root(limit) when is_struct(limit, Decimal) do
    %{allocated: limit, committed: Decimal.new(0), mode: :root}
  end

  @spec new_allocated(Decimal.t()) :: budget_data()
  def new_allocated(amount) when is_struct(amount, Decimal) do
    %{allocated: amount, committed: Decimal.new(0), mode: :allocated}
  end

  @spec new_na() :: budget_data()
  def new_na do
    %{allocated: nil, committed: Decimal.new(0), mode: :na}
  end

  @spec serialize(budget_data()) :: map()
  def serialize(%{allocated: allocated, committed: committed, mode: mode}) do
    %{
      "allocated" => decimal_to_string(allocated),
      "committed" => Decimal.to_string(committed),
      "mode" => Atom.to_string(mode)
    }
  end

  @spec deserialize(map() | nil) :: budget_data()
  def deserialize(nil), do: new_na()

  def deserialize(%{"allocated" => alloc, "committed" => comm, "mode" => mode}) do
    %{
      allocated: string_to_decimal(alloc),
      committed: Decimal.new(comm),
      mode: String.to_existing_atom(mode)
    }
  end

  @spec add_committed(budget_data(), Decimal.t()) :: budget_data()
  def add_committed(%{committed: nil} = budget, amount) do
    %{budget | committed: amount}
  end

  def add_committed(%{committed: current} = budget, amount) do
    %{budget | committed: Decimal.add(current, amount)}
  end

  @spec release_committed(budget_data(), Decimal.t()) :: budget_data()
  def release_committed(%{committed: nil} = budget, _amount), do: budget

  def release_committed(%{committed: current} = budget, amount) do
    new_committed = Decimal.sub(current, amount)

    clamped =
      if Decimal.compare(new_committed, Decimal.new(0)) == :lt do
        Decimal.new(0)
      else
        new_committed
      end

    %{budget | committed: clamped}
  end

  defp decimal_to_string(nil), do: nil
  defp decimal_to_string(d), do: Decimal.to_string(d)

  defp string_to_decimal(nil), do: nil
  defp string_to_decimal(s), do: Decimal.new(s)
end
