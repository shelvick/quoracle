defmodule Quoracle.Fields.PromptFieldManager do
  @moduledoc """
  Central orchestrator for hierarchical prompt field management.
  """

  alias Quoracle.Fields.{
    FieldValidator,
    FieldTransformer,
    GlobalContextInjector,
    ConstraintAccumulator,
    CognitiveStyles,
    Schemas
  }

  @spec extract_fields_from_params(map()) ::
          {:ok, map()} | {:error, {:missing_required_fields, [atom()]} | any()}
  def extract_fields_from_params(params) when is_map(params) do
    # Extract only known fields from params
    provided_fields = extract_provided_fields(params)

    # Validate the extracted fields
    case FieldValidator.validate_fields(provided_fields) do
      {:ok, validated} ->
        {:ok, %{provided: validated}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec transform_for_child(map(), map(), String.t(), keyword()) :: map()
  def transform_for_child(parent_fields, provided_fields, task_id, opts \\ []) do
    # Inherit injected fields from parent if present, otherwise query from task
    injected =
      case get_in(parent_fields, [:injected]) do
        nil ->
          # No parent injected fields - query from database
          GlobalContextInjector.inject(task_id)

        parent_injected when is_map(parent_injected) ->
          # Inherit parent's injected fields
          parent_injected

        _ ->
          # Fallback to database query
          GlobalContextInjector.inject(task_id)
      end

    # Transform fields for child
    # Constraints come from THREE sources (all merged):
    # 1. Task's initial_constraints (from injected.constraints)
    # 2. Parent's accumulated constraints (from parent_fields.transformed.constraints)
    # 3. New constraints from spawn params (from provided_fields.constraints)
    task_initial = Map.get(injected, :constraints, [])
    parent_accumulated = get_in(parent_fields, [:transformed, :constraints]) || []

    # Merge task initial + parent accumulated as the base
    base_constraints = (task_initial ++ parent_accumulated) |> Enum.uniq()

    parent_for_accumulation = %{transformed: %{constraints: base_constraints}}

    transformed = %{
      accumulated_narrative:
        FieldTransformer.summarize_narrative(parent_fields, provided_fields, opts),
      constraints: ConstraintAccumulator.accumulate(parent_for_accumulation, provided_fields)
    }

    %{
      injected: injected,
      provided: provided_fields,
      transformed: transformed
    }
  end

  @spec build_prompts_from_fields(map()) :: {String.t(), String.t()}
  def build_prompts_from_fields(fields) do
    system_prompt = build_system_prompt(fields)
    user_prompt = build_user_prompt(fields)
    {system_prompt, user_prompt}
  end

  # Private functions

  defp extract_provided_fields(params) do
    # Extract all known fields from params (provided + transformed that can be passed in)
    # Injected fields come from GlobalContextInjector, not from params
    all_known_fields = Schemas.list_fields()
    injected_fields = Schemas.get_fields_by_category(:injected)
    extractable_fields = all_known_fields -- injected_fields

    params
    |> Enum.filter(fn {key, _value} -> key in extractable_fields end)
    |> Map.new()
  end

  defp build_system_prompt(fields) do
    parts = []

    # Add role if present
    parts =
      if role = get_in(fields, [:provided, :role]) do
        if role != "" do
          parts ++ ["<role>#{role}</role>"]
        else
          parts
        end
      else
        parts
      end

    # Add cognitive style if present
    parts =
      if style = get_in(fields, [:provided, :cognitive_style]) do
        # Convert string to atom if needed (FieldValidator returns original string value)
        # Safe conversion with rescue - validation should have caught invalid values
        style_atom =
          if is_binary(style) do
            try do
              String.to_existing_atom(style)
            rescue
              ArgumentError -> nil
            end
          else
            style
          end

        case CognitiveStyles.get_style_prompt(style_atom) do
          {:ok, style_prompt} -> parts ++ [style_prompt]
          _ -> parts
        end
      else
        parts
      end

    # Add constraints (accumulated from task initial_constraints + parent constraints)
    parts =
      if constraints = get_in(fields, [:transformed, :constraints]) do
        if constraints != [] do
          constraints_xml =
            "<constraints>\n" <>
              Enum.map_join(constraints, "\n", fn c -> "- #{c}" end) <> "\n</constraints>"

          parts ++ [constraints_xml]
        else
          parts
        end
      else
        parts
      end

    # Add output style if present
    parts =
      if output_style = get_in(fields, [:provided, :output_style]) do
        parts ++ ["<output_style>#{output_style}</output_style>"]
      else
        parts
      end

    # Add delegation strategy if present
    parts =
      if strategy = get_in(fields, [:provided, :delegation_strategy]) do
        parts ++ ["<delegation_strategy>#{strategy}</delegation_strategy>"]
      else
        parts
      end

    # Add global context if present
    parts =
      if global_context = get_in(fields, [:injected, :global_context]) do
        if global_context != "" do
          parts ++ ["<global_context>#{global_context}</global_context>"]
        else
          parts
        end
      else
        parts
      end

    Enum.join(parts, "\n\n")
  end

  defp build_user_prompt(fields) do
    parts = []

    # Add task description
    parts =
      if task = get_in(fields, [:provided, :task_description]) do
        parts ++ ["<task>#{task}</task>"]
      else
        parts
      end

    # Add success criteria
    parts =
      if criteria = get_in(fields, [:provided, :success_criteria]) do
        parts ++ ["<success_criteria>#{criteria}</success_criteria>"]
      else
        parts
      end

    # Add immediate context
    parts =
      if context = get_in(fields, [:provided, :immediate_context]) do
        parts ++ ["<immediate_context>#{context}</immediate_context>"]
      else
        parts
      end

    # Add approach guidance
    parts =
      if guidance = get_in(fields, [:provided, :approach_guidance]) do
        parts ++ ["<approach_guidance>#{guidance}</approach_guidance>"]
      else
        parts
      end

    # Add sibling context if present - formatted as directive boundaries
    parts =
      if siblings = get_in(fields, [:provided, :sibling_context]) do
        if siblings != [] do
          sibling_lines =
            Enum.map_join(siblings, "\n", fn s ->
              "- Agent #{s.agent_id}: #{s.task}"
            end)

          sibling_xml =
            "<sibling_context>\n" <>
              "SCOPE BOUNDARIES: The following sibling agents are handling related work.\n" <>
              "Their scopes are OFF-LIMITS to you - do not duplicate their work.\n\n" <>
              sibling_lines <>
              "\n</sibling_context>"

          parts ++ [sibling_xml]
        else
          parts
        end
      else
        parts
      end

    # Add accumulated narrative if present
    parts =
      if narrative = get_in(fields, [:transformed, :accumulated_narrative]) do
        if narrative != "" do
          parts ++ ["<accumulated_narrative>#{narrative}</accumulated_narrative>"]
        else
          parts
        end
      else
        parts
      end

    Enum.join(parts, "\n\n")
  end
end
