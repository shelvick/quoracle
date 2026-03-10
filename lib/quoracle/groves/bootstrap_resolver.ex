defmodule Quoracle.Groves.BootstrapResolver do
  @moduledoc """
  Resolves a grove's bootstrap configuration into a map of form field values
  suitable for pre-filling the NewTaskModal.

  Handles two categories of bootstrap keys:
  1. File reference fields (`*_file` keys): Read file content from the grove directory
  2. Inline value fields: Pass through directly as form values
  """

  alias Quoracle.Groves.{Loader, PathSecurity}

  @type form_fields :: %{
          global_context: String.t() | nil,
          task_description: String.t() | nil,
          success_criteria: String.t() | nil,
          immediate_context: String.t() | nil,
          approach_guidance: String.t() | nil,
          global_constraints: String.t() | nil,
          output_style: String.t() | nil,
          cognitive_style: String.t() | nil,
          delegation_strategy: String.t() | nil,
          role: String.t() | nil,
          skills: String.t() | nil,
          profile: String.t() | nil,
          budget_limit: String.t() | nil
        }

  @type resolve_error ::
          {:error,
           :grove_not_found
           | :parse_error
           | {:file_not_found, String.t()}
           | {:path_traversal, String.t()}
           | {:symlink_not_allowed, String.t()}}

  @doc """
  Resolves a grove's bootstrap configuration into form field values.

  Loads the grove's bootstrap config via `Loader.get_bootstrap/2`, then resolves
  all fields into a form-compatible map. File reference fields are read from disk,
  inline values pass through directly, lists are joined, and numbers are stringified.
  """
  @spec resolve(String.t(), keyword()) :: {:ok, form_fields()} | resolve_error()
  def resolve(grove_name, opts \\ []) do
    case Loader.load_grove(grove_name, opts) do
      {:ok, grove} ->
        resolve_from_grove(grove)

      {:error, :not_found} ->
        {:error, :grove_not_found}

      {:error, :parse_error} ->
        {:error, :parse_error}
    end
  end

  @doc """
  Resolves bootstrap fields from an already-loaded grove struct.
  Use this when you already have the grove loaded (avoids duplicate file reads).
  """
  @spec resolve_from_grove(Loader.grove()) :: {:ok, form_fields()} | resolve_error()
  def resolve_from_grove(grove) do
    resolve_fields(grove.bootstrap, grove.path)
  end

  @spec resolve_fields(Loader.grove_bootstrap(), String.t()) ::
          {:ok, form_fields()} | resolve_error()
  defp resolve_fields(bootstrap, grove_path) do
    with {:ok, global_context} <-
           resolve_file_field(bootstrap, :global_context_file, grove_path),
         {:ok, task_description} <-
           resolve_file_field(bootstrap, :task_description_file, grove_path),
         {:ok, success_criteria} <-
           resolve_file_field(bootstrap, :success_criteria_file, grove_path),
         {:ok, immediate_context} <-
           resolve_file_field(bootstrap, :immediate_context_file, grove_path),
         {:ok, approach_guidance} <-
           resolve_file_field(bootstrap, :approach_guidance_file, grove_path) do
      {:ok,
       %{
         global_context: global_context,
         task_description: task_description,
         success_criteria: success_criteria,
         immediate_context: immediate_context,
         approach_guidance: approach_guidance,
         global_constraints: Map.get(bootstrap, :global_constraints),
         output_style: Map.get(bootstrap, :output_style),
         role: Map.get(bootstrap, :role),
         cognitive_style: Map.get(bootstrap, :cognitive_style),
         delegation_strategy: Map.get(bootstrap, :delegation_strategy),
         skills: format_skills(Map.get(bootstrap, :skills)),
         profile: Map.get(bootstrap, :profile),
         budget_limit: format_budget(Map.get(bootstrap, :budget_limit))
       }}
    end
  end

  @spec resolve_file_field(map(), atom(), String.t()) ::
          {:ok, String.t() | nil}
          | {:error,
             {:file_not_found, String.t()}
             | {:path_traversal, String.t()}
             | {:symlink_not_allowed, String.t()}}
  defp resolve_file_field(bootstrap, key, grove_path) do
    case Map.get(bootstrap, key) do
      nil -> {:ok, nil}
      filename -> PathSecurity.safe_read_file(filename, filename, grove_path)
    end
  end

  @spec format_skills([String.t()] | nil) :: String.t() | nil
  defp format_skills(nil), do: nil
  defp format_skills([]), do: nil
  defp format_skills(skills) when is_list(skills), do: Enum.join(skills, ", ")

  @spec format_budget(number() | nil) :: String.t() | nil
  defp format_budget(nil), do: nil
  defp format_budget(budget) when is_number(budget), do: to_string(budget)
end
