defmodule Quoracle.Agents.JSONBMap do
  @moduledoc """
  Custom Ecto type for PostgreSQL JSONB columns that store maps with string keys.

  This type ensures that all map keys are converted to strings, matching PostgreSQL's
  JSONB behavior where keys are always strings, not atoms.
  """

  use Ecto.Type

  @impl true
  @spec type() :: :map
  def type, do: :map

  @impl true
  @spec cast(term()) :: {:ok, map()} | :error
  def cast(value) when is_map(value) do
    {:ok, stringify_keys(value)}
  end

  def cast(_), do: :error

  @impl true
  @spec load(term()) :: {:ok, map()} | :error
  def load(value) when is_map(value) do
    # Already string keys from database
    {:ok, value}
  end

  def load(_), do: :error

  @impl true
  @spec dump(term()) :: {:ok, map()} | :error
  def dump(value) when is_map(value) do
    {:ok, stringify_keys(value)}
  end

  def dump(_), do: :error

  # Recursively convert all map keys to strings
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      {to_string(k), stringify_keys(v)}
    end)
  end

  defp stringify_keys(list) when is_list(list) do
    Enum.map(list, &stringify_keys/1)
  end

  defp stringify_keys(value), do: value
end
