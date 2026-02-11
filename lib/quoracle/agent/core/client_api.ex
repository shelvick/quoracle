defmodule Quoracle.Agent.Core.ClientAPI do
  @moduledoc """
  Client API functions for Core agent GenServer.

  These are thin wrappers around GenServer.call/cast that provide a clean
  interface for interacting with agent processes.
  """

  @doc """
  Get the agent ID for an agent process.
  """
  @spec get_agent_id(pid()) :: {:ok, String.t()} | String.t()
  def get_agent_id(agent) do
    GenServer.call(agent, :get_agent_id)
  end

  @doc """
  Get the current state of an agent.
  Accepts optional timeout (default 5000ms).
  """
  @spec get_state(pid(), timeout()) :: {:ok, map()}
  def get_state(agent, timeout \\ 5000) do
    GenServer.call(agent, :get_state, timeout)
  end

  @doc """
  Get the model histories map for an agent.
  Returns a map of model_id => history list.
  """
  @spec get_model_histories(pid()) :: {:ok, map()}
  def get_model_histories(agent) do
    GenServer.call(agent, :get_model_histories)
  end

  @doc """
  Get the pending actions map for an agent.
  """
  @spec get_pending_actions(pid()) :: {:ok, map()}
  def get_pending_actions(agent) do
    GenServer.call(agent, :get_pending_actions)
  end

  @doc """
  Get the current wait timer reference if one is active.
  """
  @spec get_wait_timer(pid()) :: {:ok, reference() | nil}
  def get_wait_timer(agent) do
    GenServer.call(agent, :get_wait_timer)
  end

  @doc """
  Send a message to an agent for processing.
  """
  @spec handle_message(pid(), any()) :: :ok
  def handle_message(agent, message) do
    GenServer.cast(agent, {:message, message})
  end

  @doc """
  Add a pending action to an agent's state.
  """
  @spec add_pending_action(pid(), String.t(), atom(), map()) :: :ok
  def add_pending_action(agent, action_id, type, params) do
    GenServer.cast(agent, {:add_pending_action, action_id, type, params})
  end

  @doc """
  Send an action result to an agent.
  """
  @spec handle_action_result(pid(), String.t(), any()) :: :ok
  def handle_action_result(agent, action_id, result) do
    GenServer.cast(agent, {:action_result, action_id, result})
  end

  @doc """
  Set a wait timer for an agent.
  """
  @spec set_wait_timer(pid(), non_neg_integer(), String.t()) :: :ok
  def set_wait_timer(agent, duration, timer_id) do
    GenServer.cast(agent, {:set_wait_timer, duration, timer_id})
  end

  @doc """
  Send a message to the user (works like agent_message but from UI).
  """
  @spec send_user_message(pid(), String.t()) :: :ok
  def send_user_message(agent, content) do
    GenServer.cast(agent, {:send_user_message, content})
  end

  @doc """
  Wait for agent to complete initialization (handle_continue).
  Blocks until agent is ready to process messages.
  """
  @spec wait_for_ready(pid(), timeout()) :: :ok | {:error, term()}
  def wait_for_ready(agent, timeout \\ :infinity) do
    # GenServer.call blocks until handle_continue completes
    {:ok, _state} = get_state(agent, timeout)
    :ok
  rescue
    error -> {:error, error}
  end

  @doc """
  Send an agent message that requires consensus.
  """
  @spec handle_agent_message(pid(), String.t()) :: :ok
  def handle_agent_message(agent, content) do
    GenServer.cast(agent, {:agent_message, content})
  end

  @doc """
  Send an internal process message that bypasses consensus.
  """
  @spec handle_internal_message(pid(), atom(), any()) :: :ok
  def handle_internal_message(agent, type, data) do
    GenServer.cast(agent, {:internal, type, data})
  end

  # Dismiss child race prevention (v19.0)

  @doc """
  Set the dismissing flag on an agent to prevent spawn race conditions.
  """
  @spec set_dismissing(pid(), boolean()) :: :ok
  def set_dismissing(agent, value) when is_boolean(value) do
    GenServer.call(agent, {:set_dismissing, value}, :infinity)
  end

  @doc """
  Check if the agent is currently being dismissed.
  """
  @spec dismissing?(pid()) :: boolean()
  def dismissing?(agent) do
    GenServer.call(agent, :dismissing?)
  end

  # Budget system (v4.0)

  @doc """
  Update the agent's committed budget by adding an escrow amount.
  Used when spawning children with allocated budgets.
  """
  @spec update_budget_committed(pid(), Decimal.t()) :: :ok
  def update_budget_committed(agent, amount) do
    GenServer.call(agent, {:update_budget_committed, amount})
  end

  @doc """
  Release committed budget when a child is dismissed.
  Decreases committed by the specified amount.
  """
  @spec release_budget_committed(pid(), Decimal.t()) :: :ok
  def release_budget_committed(agent, amount) do
    GenServer.call(agent, {:release_budget_committed, amount})
  end

  @doc """
  Release child's budget from parent's committed, accounting for child's spending.
  Uses Escrow.release_allocation/3 for proper math and re-evaluates over_budget.
  """
  @spec release_child_budget(pid(), Decimal.t(), Decimal.t()) :: :ok
  def release_child_budget(pid, child_allocated, child_spent) do
    GenServer.call(pid, {:release_child_budget, child_allocated, child_spent}, :infinity)
  end

  @doc """
  Get current budget state including budget_data and over_budget status.
  Returns {:ok, %{budget_data: map(), over_budget: boolean()}}.
  """
  @spec get_budget(pid()) :: {:ok, %{budget_data: map(), over_budget: boolean()}}
  def get_budget(agent) do
    GenServer.call(agent, :get_budget)
  end

  # Budget system (v23.0) - adjust_child_budget

  @doc """
  Adjusts a direct child's budget allocation.

  Atomically updates:
  1. Child's budget_data.allocated
  2. Parent's budget_data.committed (escrow)
  3. Notifies child via system message

  Returns :ok on success or {:error, reason} on failure.
  """
  @spec adjust_child_budget(String.t(), String.t(), Decimal.t(), keyword()) ::
          :ok | {:error, term()}
  def adjust_child_budget(parent_id, child_id, new_budget, opts) do
    registry = Keyword.fetch!(opts, :registry)

    case Registry.lookup(registry, {:agent, parent_id}) do
      [{parent_pid, _}] ->
        GenServer.call(parent_pid, {:adjust_child_budget, child_id, new_budget, opts}, :infinity)

      [] ->
        {:error, :parent_not_found}
    end
  end

  @doc """
  Updates an agent's budget_data struct.
  """
  @spec update_budget_data(pid(), map()) :: :ok
  def update_budget_data(pid, budget_data) do
    GenServer.call(pid, {:update_budget_data, budget_data})
  end
end
