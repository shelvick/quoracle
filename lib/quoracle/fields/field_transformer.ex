defmodule Quoracle.Fields.FieldTransformer do
  @moduledoc """
  Transforms fields during hierarchical propagation.
  """

  alias Quoracle.Models.ConfigModelSettings
  alias Quoracle.Models.ModelQuery
  require Logger

  @max_narrative_length 500

  @doc """
  Summarizes narrative by combining parent and new context.

  Calls LLM for summarization if combined text exceeds max length.

  ## Parameters
    * `parent_fields` - Parent agent's fields
    * `provided_fields` - Child's provided fields
    * `opts` - Options including :sandbox_owner for test DB access

  ## Examples

      iex> summarize_narrative(%{transformed: %{accumulated_narrative: "Parent"}}, %{immediate_context: "Child"})
      "Parent Child"
  """
  @spec summarize_narrative(map(), map(), keyword()) :: String.t()
  def summarize_narrative(parent_fields, provided_fields, opts \\ []) do
    # Build narrative from parent's accumulated + new context
    parent_narrative = get_in(parent_fields, [:transformed, :accumulated_narrative]) || ""
    new_context = Map.get(provided_fields, :immediate_context) || ""

    combined = combine_narratives(parent_narrative, new_context)

    if String.length(combined) <= @max_narrative_length do
      combined
    else
      summarize_with_llm(combined, opts)
    end
  end

  @doc """
  Applies all field transformations.

  ## Parameters
    * `parent_fields` - Parent agent's fields
    * `child_fields` - Child's provided fields
    * `opts` - Options including :sandbox_owner for test DB access

  ## Examples

      iex> apply_transformations(%{}, %{immediate_context: "Context"})
      %{accumulated_narrative: "Context"}
  """
  @spec apply_transformations(map(), map(), keyword()) :: map()
  def apply_transformations(parent_fields, child_fields, opts \\ []) do
    # Apply all field transformations
    %{
      accumulated_narrative: summarize_narrative(parent_fields, child_fields, opts)
      # Other transformations handled by specialized modules
    }
  end

  defp summarize_with_llm(text, opts) do
    messages = [
      %{
        role: "system",
        content:
          "Summarize the following narrative in under #{@max_narrative_length} characters, " <>
            "preserving key context. Be concise but preserve exact syntax, templates, and " <>
            "security-critical instructions verbatim."
      },
      %{
        role: "user",
        content: text
      }
    ]

    # Get model from configuration - raises if not configured
    model_spec = ConfigModelSettings.get_summarization_model!()

    # Pass sandbox_owner for test DB access, plug for cassette testing
    # Pass cost recording context with llm_summarization type (R9-R11)
    # skip_json_mode: true - summarization returns plain text, not JSON
    query_opts =
      %{sandbox_owner: Keyword.get(opts, :sandbox_owner), skip_json_mode: true}
      |> maybe_add_plug(Keyword.get(opts, :plug))
      |> maybe_add_cost_context(opts)

    case ModelQuery.query_models(messages, [model_spec], query_opts) do
      {:ok, %{successful_responses: [response | _]}} ->
        extract_text_from_response(response)

      {:ok, %{successful_responses: [], failed_models: failed}} ->
        Logger.warning("LLM summarization failed - all models failed: #{inspect(failed)}")
        text

      {:error, reason} ->
        Logger.warning("LLM summarization failed - error: #{inspect(reason)}")
        text
    end
  end

  defp extract_text_from_response(%ReqLLM.Response{} = response) do
    ReqLLM.Response.text(response)
  end

  defp extract_text_from_response(%{content: content}) when is_binary(content) do
    content
  end

  defp extract_text_from_response(_), do: ""

  defp combine_narratives(parent, new) do
    case {parent, new} do
      {"", new} -> new
      {parent, ""} -> parent
      {parent, new} -> "#{parent} #{new}"
    end
  end

  defp maybe_add_plug(opts, nil), do: opts
  defp maybe_add_plug(opts, plug), do: Map.put(opts, :plug, plug)

  # Add cost recording context for summarization (R9-R11)
  defp maybe_add_cost_context(query_opts, opts) do
    agent_id = Keyword.get(opts, :agent_id)
    task_id = Keyword.get(opts, :task_id)
    pubsub = Keyword.get(opts, :pubsub)

    if agent_id && task_id && pubsub do
      query_opts
      |> Map.put(:agent_id, agent_id)
      |> Map.put(:task_id, task_id)
      |> Map.put(:pubsub, pubsub)
      |> Map.put(:cost_type, "llm_summarization")
    else
      query_opts
    end
  end
end
