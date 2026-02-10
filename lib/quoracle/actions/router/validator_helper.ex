defmodule Quoracle.Actions.Router.ValidatorHelper do
  @moduledoc """
  Helper module for Router action validation.
  """

  alias Quoracle.Actions.{Schema, Validator}

  @doc """
  Validates an action type and its parameters.

  Returns :ok if valid, {:error, reason} otherwise.
  """
  @spec validate_action(atom(), map()) :: :ok | {:error, any()}
  def validate_action(action_type, params) do
    # First check if action exists in schema
    case Schema.validate_action_type(action_type) do
      {:ok, _} ->
        # Then validate parameters
        action_json = %{"action" => to_string(action_type), "params" => params}

        case Validator.validate_action(action_json) do
          {:ok, _} -> :ok
          {:error, errors} -> {:error, errors}
        end

      {:error, _} ->
        {:error, :unknown_action}
    end
  end
end
