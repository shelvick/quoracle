defmodule Quoracle.Actions.Schema.ActionList do
  @moduledoc """
  Defines the list of available actions and ensures required atoms exist.
  """

  @actions [
    :spawn_child,
    :wait,
    :send_message,
    :orient,
    :answer_engine,
    :execute_shell,
    :fetch_web,
    :call_api,
    :call_mcp,
    :todo,
    :generate_secret,
    :search_secrets,
    :dismiss_child,
    :generate_images,
    :record_cost,
    :adjust_budget,
    :file_read,
    :file_write,
    :learn_skills,
    :create_skill,
    :batch_sync,
    :batch_async
  ]

  # Actions that can be included in a batch_sync
  # Excludes: :wait (timing), :batch_sync (no nesting), slow/async actions
  @batchable_actions [
    :spawn_child,
    :send_message,
    :orient,
    :todo,
    :generate_secret,
    :search_secrets,
    :dismiss_child,
    :adjust_budget,
    :record_cost,
    :file_read,
    :file_write,
    :learn_skills,
    :create_skill
  ]

  # Ensure orient param atoms exist for String.to_existing_atom/1
  _ = [
    :current_situation,
    :goal_clarity,
    :available_resources,
    :key_challenges,
    :assumptions,
    :unknowns,
    :approach_options,
    :parallelization_opportunities,
    :risk_factors,
    :success_criteria,
    :next_steps,
    :constraints_impact
  ]

  @doc """
  Returns all action names.
  """
  @spec actions() :: [atom()]
  def actions, do: @actions

  @doc """
  Returns actions that can be included in a batch_sync.
  Excludes: :wait (timing-dependent), :batch_sync (no nesting), slow/async actions.
  """
  @spec batchable_actions() :: [atom()]
  def batchable_actions, do: @batchable_actions

  # Actions excluded from batch_async (all others are allowed)
  @async_excluded_actions [:wait, :batch_sync, :batch_async]

  @doc """
  Returns actions excluded from batch_async.
  """
  @spec async_excluded_actions() :: [atom()]
  def async_excluded_actions, do: @async_excluded_actions

  @doc """
  Check if action is eligible for batch_async.
  Returns true for all actions except :wait, :batch_sync, :batch_async.
  """
  @spec async_batchable?(atom()) :: boolean()
  def async_batchable?(action_type), do: action_type not in @async_excluded_actions
end
