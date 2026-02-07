defmodule Quoracle.Actions.CreateSkill do
  @moduledoc """
  Action module for creating new skill files.
  Validates name format and prevents overwriting existing skills.
  """

  alias Quoracle.Skills.Creator

  @max_description_length 1024

  @doc """
  Creates a new skill.
  Standard 3-arity action signature.
  """
  @spec execute(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(params, _agent_id, opts) do
    with {:ok, validated} <- validate_params(params) do
      case Creator.create(validated, opts) do
        {:ok, path} ->
          {:ok,
           %{
             action: "create_skill",
             name: validated.name,
             path: path
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp validate_params(params) do
    name = Map.get(params, :name) || Map.get(params, "name")
    description = Map.get(params, :description) || Map.get(params, "description")
    content = Map.get(params, :content) || Map.get(params, "content")

    with :ok <- validate_required(name, "name"),
         :ok <- validate_required(description, "description"),
         :ok <- validate_required(content, "content"),
         :ok <- Creator.validate_name(name),
         :ok <- validate_description_length(description) do
      {:ok,
       %{
         name: name,
         description: description,
         content: content,
         metadata: Map.get(params, :metadata) || Map.get(params, "metadata") || %{},
         attachments: Map.get(params, :attachments) || Map.get(params, "attachments") || []
       }}
    end
  end

  defp validate_required(nil, field), do: {:error, "#{field} is required"}
  defp validate_required("", field), do: {:error, "#{field} is required"}
  defp validate_required(_, _field), do: :ok

  defp validate_description_length(description) when is_binary(description) do
    if String.length(description) <= @max_description_length do
      :ok
    else
      {:error, "description must be #{@max_description_length} characters or less"}
    end
  end

  defp validate_description_length(_), do: :ok
end
