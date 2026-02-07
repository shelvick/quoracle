defmodule Quoracle.Actions.SearchSecrets do
  @moduledoc """
  Action module for searching secret names by search terms.
  Returns matching secret names without exposing values.
  """

  alias Quoracle.Models.TableSecrets

  @spec execute(map(), String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def execute(params, _agent_id, _opts) do
    with {:ok, terms} <- validate_search_terms(params) do
      {:ok, names} = TableSecrets.search_by_terms(terms)

      {:ok,
       %{
         action: "search_secrets",
         matching_secrets: names
       }}
    end
  end

  defp validate_search_terms(params) when is_map(params) do
    terms = Map.get(params, :search_terms) || Map.get(params, "search_terms")

    cond do
      is_nil(terms) ->
        {:error, "search_terms is required"}

      not is_list(terms) ->
        {:error, "search_terms must be a list of strings"}

      not Enum.all?(terms, &is_binary/1) ->
        {:error, "search_terms must contain only strings"}

      true ->
        {:ok, terms}
    end
  end

  defp validate_search_terms(_), do: {:error, "search_terms is required"}
end
