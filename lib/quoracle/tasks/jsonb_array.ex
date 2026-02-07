defmodule Quoracle.Tasks.JSONBArray do
  @moduledoc """
  Custom Ecto type for PostgreSQL JSONB columns that store arrays.

  This type handles the conversion between Elixir lists and PostgreSQL JSONB arrays,
  since Ecto's built-in :map type only handles JSONB objects (maps).
  """

  use Ecto.Type

  @impl true
  @spec type() :: :map
  def type, do: :map

  @impl true
  @spec cast(term()) :: {:ok, list()} | :error
  def cast(value) when is_list(value), do: {:ok, value}
  def cast(_), do: :error

  @impl true
  @spec load(term()) :: {:ok, list()} | :error
  def load(value) when is_list(value), do: {:ok, value}
  def load(_), do: :error

  @impl true
  @spec dump(term()) :: {:ok, list()} | :error
  def dump(value) when is_list(value), do: {:ok, value}
  def dump(_), do: :error
end
