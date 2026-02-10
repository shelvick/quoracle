defmodule Quoracle.Actions.Validator.BatchAsync do
  @moduledoc """
  Batch async validation functions.
  Uses SHARED_BatchValidation for common logic, adds wait param validation.
  """

  alias Quoracle.Actions.Schema.ActionList
  alias Quoracle.Actions.Shared.BatchValidation
  alias Quoracle.Actions.ValidationHelpers

  @doc """
  Validates batch_async params - checks batch size, eligibility, wait type, and sub-action params.
  """
  @spec validate(map()) :: :ok | {:error, term()}
  def validate(params) do
    atom_params = ValidationHelpers.string_keys_to_atoms(params)
    actions = Map.get(atom_params, :actions, [])

    with :ok <- BatchValidation.validate_batch_size(actions),
         :ok <-
           BatchValidation.validate_actions_eligible(actions, &ActionList.async_batchable?/1),
         :ok <- validate_wait_param(atom_params) do
      BatchValidation.validate_action_params(actions)
    end
  end

  defp validate_wait_param(%{wait: wait}) when is_boolean(wait), do: :ok
  defp validate_wait_param(%{wait: _}), do: {:error, :invalid_wait_type}
  defp validate_wait_param(_), do: :ok
end
