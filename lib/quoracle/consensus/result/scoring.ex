defmodule Quoracle.Consensus.Result.Scoring do
  @moduledoc """
  Scoring and tiebreaking functions for consensus results.
  Extracted from Result to maintain <500 line modules.
  """

  alias Quoracle.Actions.Schema

  @doc """
  Breaks a tie between clusters using 3-level chain:
  1. Action priority (lowest wins)
  2. Cluster wait score (lexicographic, lowest wins)
  3. Cluster auto_complete_todo score (lexicographic, lowest wins)
  """
  @spec break_tie([map()]) :: map()
  def break_tie([cluster]), do: cluster

  def break_tie(tied_clusters) do
    tied_clusters
    |> Enum.sort_by(fn cluster ->
      priority = calculate_cluster_priority(cluster)
      wait = cluster_wait_score(cluster)
      auto = cluster_auto_complete_score(cluster)

      {priority, wait, auto}
    end)
    |> hd()
  end

  @doc """
  Calculate wait score as {true_count, finite_sum}.
  Lower score = more conservative = wins ties.
  """
  @spec wait_score(boolean() | integer() | nil) :: {non_neg_integer(), non_neg_integer()}
  def wait_score(true), do: {0, 0}
  def wait_score(nil), do: {0, 1}
  def wait_score(n) when is_integer(n) and n > 0, do: {0, 1 + n}
  def wait_score(0), do: {1, 0}
  def wait_score(false), do: {1, 0}

  @doc """
  Calculate auto_complete_todo score as {true_count, finite_sum}.
  Lower score = more conservative = wins ties.
  """
  @spec auto_complete_score(boolean() | nil) :: {non_neg_integer(), non_neg_integer()}
  def auto_complete_score(false), do: {0, 0}
  def auto_complete_score(nil), do: {0, 1}
  def auto_complete_score(true), do: {1, 0}

  @doc """
  Sum wait scores across all responses in cluster.
  Missing :wait fields are treated as nil.
  """
  @spec cluster_wait_score(map()) :: {non_neg_integer(), non_neg_integer()}
  def cluster_wait_score(%{actions: actions}) do
    actions
    |> Enum.map(fn action -> Map.get(action, :wait) end)
    |> Enum.map(&wait_score/1)
    |> Enum.reduce({0, 0}, fn {tc, fs}, {acc_tc, acc_fs} ->
      {tc + acc_tc, fs + acc_fs}
    end)
  end

  def cluster_wait_score(_cluster), do: {0, 0}

  @doc """
  Sum auto_complete_todo scores across all responses in cluster.
  Missing fields are treated as nil.
  """
  @spec cluster_auto_complete_score(map()) :: {non_neg_integer(), non_neg_integer()}
  def cluster_auto_complete_score(%{actions: actions}) do
    actions
    |> Enum.map(fn action -> Map.get(action, :auto_complete_todo) end)
    |> Enum.map(&auto_complete_score/1)
    |> Enum.reduce({0, 0}, fn {tc, fs}, {acc_tc, acc_fs} ->
      {tc + acc_tc, fs + acc_fs}
    end)
  end

  def cluster_auto_complete_score(_cluster), do: {0, 0}

  # Calculate priority for a cluster, with special handling for batch_sync/batch_async
  @doc false
  def calculate_cluster_priority(%{
        representative: %{action: :batch_async, params: %{actions: actions}}
      })
      when is_list(actions) and actions != [] do
    # For batch_async: use max priority of all actions in batch
    actions
    |> Enum.map(fn %{action: action_type} ->
      case Schema.get_action_priority(action_type) do
        {:error, _} -> 999
        p -> p
      end
    end)
    |> Enum.max()
  end

  def calculate_cluster_priority(%{representative: %{action: :batch_async}}) do
    # Empty batch_async - use high priority (999) so it loses to real actions
    999
  end

  def calculate_cluster_priority(%{
        representative: %{action: :batch_sync, params: %{actions: actions}}
      })
      when is_list(actions) and actions != [] do
    # For batch_sync: use max priority of all actions in sequence
    actions
    |> Enum.map(fn %{action: action_type} ->
      case Schema.get_action_priority(action_type) do
        {:error, _} -> 999
        p -> p
      end
    end)
    |> Enum.max()
  end

  def calculate_cluster_priority(%{representative: %{action: :batch_sync}}) do
    # Empty batch_sync - use high priority (999) so it loses to real actions
    999
  end

  def calculate_cluster_priority(%{representative: %{action: action}}) do
    case Schema.get_action_priority(action) do
      {:error, :unknown_action} -> 999
      p -> p
    end
  end
end
