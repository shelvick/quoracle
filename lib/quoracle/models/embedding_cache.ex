defmodule Quoracle.Models.EmbeddingCache do
  @moduledoc """
  Manages the ETS table for embedding cache.

  This GenServer owns a process-local ETS table, ensuring proper isolation
  for concurrent test execution and preventing race conditions.
  """

  use GenServer

  @doc """
  Starts the EmbeddingCache GenServer and creates the ETS table.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Gets the ETS table reference from the GenServer.
  """
  @spec get_table(pid()) :: :ets.tid()
  def get_table(pid) do
    GenServer.call(pid, :get_table)
  end

  @impl true
  @spec init(keyword()) :: {:ok, map()}
  def init(_opts) do
    # Create the ETS table owned by this process (not named)
    table = :ets.new(:embedding_cache, [:set, :public])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call(:get_table, _from, state) do
    {:reply, state.table, state}
  end
end
