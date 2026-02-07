defmodule Quoracle.Actions.Shared.BatchValidation do
  @moduledoc """
  Shared validation logic for batch actions (batch_sync and batch_async).

  Ensures consistent validation behavior:
  - Minimum batch size (2 actions)
  - Action eligibility checking
  - Individual action parameter validation
  """

  alias Quoracle.Actions.Validator

  @doc """
  Validates batch has minimum required size.

  ## Returns
  - :ok if batch has 2+ actions
  - {:error, :empty_batch} if empty
  - {:error, :batch_too_small} if only 1 action
  """
  @spec validate_batch_size([map()]) :: :ok | {:error, atom()}
  def validate_batch_size([]), do: {:error, :empty_batch}
  def validate_batch_size([_single]), do: {:error, :batch_too_small}
  def validate_batch_size(actions) when is_list(actions), do: :ok

  @doc """
  Validates all actions are eligible for batching.

  ## Parameters
  - actions: List of action specs %{action: atom, params: map}
  - eligible_fn: Function that returns true if action is eligible

  ## Returns
  - :ok if all actions eligible
  - {:error, :unbatchable_action} if any action not eligible
  - {:error, :nested_batch} if batch contains another batch action
  """
  @spec validate_actions_eligible([map()], (atom() -> boolean())) ::
          :ok | {:error, atom()}
  def validate_actions_eligible(actions, eligible_fn) do
    Enum.reduce_while(actions, :ok, fn action, _acc ->
      action_type = get_action_type(action)

      cond do
        action_type in [:batch_sync, :batch_async] ->
          {:halt, {:error, :nested_batch}}

        not eligible_fn.(action_type) ->
          {:halt, {:error, :unbatchable_action}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  @doc """
  Validates individual action parameters before batch execution.

  ## Parameters
  - actions: List of action specs %{action: atom, params: map}

  ## Returns
  - :ok if all actions have valid params
  - {:error, {:invalid_action, action_type, reason}} on first validation failure
  """
  @spec validate_action_params([map()]) :: :ok | {:error, term()}
  def validate_action_params(actions) do
    Enum.reduce_while(actions, :ok, fn action, _acc ->
      action_type = get_action_type(action)
      params = get_action_params(action)

      case Validator.validate_params(action_type, params) do
        {:ok, _} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, {:invalid_action, action_type, reason}}}
      end
    end)
  end

  @doc """
  Performs full batch validation (size + eligibility + params).

  ## Parameters
  - actions: List of action specs
  - eligible_fn: Eligibility checker function

  ## Returns
  - :ok if all validations pass
  - {:error, reason} on first failure
  """
  @spec validate_batch([map()], (atom() -> boolean())) :: :ok | {:error, term()}
  def validate_batch(actions, eligible_fn) do
    with :ok <- validate_batch_size(actions),
         :ok <- validate_actions_eligible(actions, eligible_fn) do
      validate_action_params(actions)
    end
  end

  # Helper to extract action type from action map
  defp get_action_type(%{action: action_type}), do: action_type
  defp get_action_type(%{"action" => action_type}), do: String.to_existing_atom(action_type)

  # Helper to extract params from action map
  defp get_action_params(%{params: params}), do: params
  defp get_action_params(%{"params" => params}), do: params
  defp get_action_params(_), do: %{}
end
