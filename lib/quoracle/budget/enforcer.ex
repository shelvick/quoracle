defmodule Quoracle.Budget.Enforcer do
  @moduledoc """
  Pre-action budget enforcement.

  Actions are classified as:
  - Costly: May incur external costs, blocked in over-budget mode
  - Free: No external cost potential, always allowed

  Special cases:
  - execute_shell: check_id/terminate allowed, new shell blocked
  """

  alias Quoracle.Budget.Tracker

  @type check_result :: :allowed | {:blocked, :over_budget}

  @costly_actions [
    :spawn_child,
    :call_api,
    :call_mcp,
    :fetch_web,
    :answer_engine,
    :generate_images
  ]

  @free_actions [
    :orient,
    :send_message,
    :wait,
    :dismiss_child,
    :manage_todo,
    :generate_secret,
    :search_secrets,
    :record_cost
  ]

  @spec check_action(atom(), map(), map(), Decimal.t()) :: check_result()
  def check_action(action, params, budget_data, spent) do
    case classify_action(action, params) do
      :free ->
        :allowed

      :costly ->
        if Tracker.over_budget?(budget_data, spent) do
          {:blocked, :over_budget}
        else
          :allowed
        end
    end
  end

  @spec costly_action?(atom(), map()) :: boolean()
  def costly_action?(action, params) do
    classify_action(action, params) == :costly
  end

  @spec classify_action(atom(), map()) :: :costly | :free
  def classify_action(:execute_shell, params) do
    if Map.has_key?(params, :check_id) or Map.has_key?(params, :terminate) do
      :free
    else
      :costly
    end
  end

  def classify_action(action, _params) when action in @costly_actions, do: :costly
  def classify_action(action, _params) when action in @free_actions, do: :free
  def classify_action(_action, _params), do: :free
end
