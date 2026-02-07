defmodule Quoracle.Actions.Validator.BatchSync do
  @moduledoc """
  Batch sync validation functions.
  Extracted from Validator to maintain <500 line modules.
  """

  alias Quoracle.Actions.Schema.ActionList
  alias Quoracle.Actions.ValidationHelpers

  @doc """
  Validates batch_sync params - checks batch length, nesting, and batchable actions.
  """
  @spec validate(map()) :: :ok | {:error, term()}
  def validate(params) do
    atom_params = ValidationHelpers.string_keys_to_atoms(params)
    actions = Map.get(atom_params, :actions, [])

    with :ok <- check_batch_length(actions),
         :ok <- check_no_nested_batch(actions),
         :ok <- check_all_batchable(actions) do
      check_each_action_valid(actions)
    end
  end

  @doc false
  def check_batch_length(actions) when length(actions) < 2, do: {:error, :batch_too_short}
  def check_batch_length(_), do: :ok

  @doc false
  def check_no_nested_batch(actions) do
    has_nested =
      Enum.any?(actions, fn action ->
        action_type = get_action_type(action)
        action_type == :batch_sync or action_type == "batch_sync"
      end)

    if has_nested, do: {:error, :nested_batch}, else: :ok
  end

  @doc false
  def check_all_batchable(actions) do
    batchable = ActionList.batchable_actions()

    Enum.find_value(actions, :ok, fn action ->
      action_type = get_action_type(action)

      action_atom =
        case action_type do
          a when is_atom(a) -> a
          s when is_binary(s) -> String.to_existing_atom(s)
        end

      if action_atom in batchable do
        nil
      else
        {:error, {:not_batchable, action_atom}}
      end
    end)
  end

  @doc false
  def check_each_action_valid(actions) do
    # Import validate_params from parent module
    validator = Quoracle.Actions.Validator

    Enum.find_value(actions, :ok, fn action ->
      action_type = get_action_type(action)
      action_params = get_action_params(action)

      action_atom =
        case action_type do
          a when is_atom(a) -> a
          s when is_binary(s) -> String.to_existing_atom(s)
        end

      case validator.validate_params(action_atom, action_params) do
        {:ok, _} -> nil
        {:error, reason} -> {:error, {:action_invalid, action_atom, reason}}
      end
    end)
  end

  @doc """
  Extract action type from action map (handles both atom and string keys).
  """
  @spec get_action_type(map()) :: atom() | String.t() | nil
  def get_action_type(action) when is_map(action) do
    Map.get(action, :action) || Map.get(action, "action")
  end

  @doc """
  Extract params from action map (handles both atom and string keys).
  """
  @spec get_action_params(map()) :: map()
  def get_action_params(action) when is_map(action) do
    Map.get(action, :params) || Map.get(action, "params") || %{}
  end
end
