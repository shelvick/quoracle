defmodule Quoracle.Models.LLMDBModelLoader do
  @moduledoc """
  Helper module to query LLMDB and format model data for UI dropdowns.
  Provides filtered model lists by capability.

  All functions have two arities:
  - /0 arity: Calls LLMDB.models() internally (production use)
  - /1 arity: Accepts models list (testing/dependency injection)
  """

  # =============================================================
  # All Models
  # =============================================================

  @doc """
  Returns all models formatted for dropdown selection.
  Returns list of {display_label, model_spec} tuples.
  """
  @spec all_models() :: [{String.t(), String.t()}]
  def all_models, do: all_models(LLMDB.models())

  @spec all_models([LLMDB.Model.t()]) :: [{String.t(), String.t()}]
  def all_models(models) do
    models
    |> Enum.map(&format_model/1)
    |> Enum.sort_by(fn {label, _} -> label end)
  end

  # =============================================================
  # Chat Models
  # =============================================================

  @doc """
  Returns only chat-capable models (excludes embedding-only models).
  """
  @spec chat_models() :: [{String.t(), String.t()}]
  def chat_models, do: chat_models(LLMDB.models())

  @spec chat_models([LLMDB.Model.t()]) :: [{String.t(), String.t()}]
  def chat_models(models) do
    models
    |> Enum.filter(&chat_capable?/1)
    |> Enum.map(&format_model/1)
    |> Enum.sort_by(fn {label, _} -> label end)
  end

  defp chat_capable?(%LLMDB.Model{capabilities: %{chat: true}}), do: true
  defp chat_capable?(_), do: false

  # =============================================================
  # Embedding Models
  # =============================================================

  @doc """
  Returns only embedding-capable models.
  """
  @spec embedding_models() :: [{String.t(), String.t()}]
  def embedding_models, do: embedding_models(LLMDB.models())

  @spec embedding_models([LLMDB.Model.t()]) :: [{String.t(), String.t()}]
  def embedding_models(models) do
    models
    |> Enum.filter(&embedding_capable?/1)
    |> Enum.map(&format_model/1)
    |> Enum.sort_by(fn {label, _} -> label end)
  end

  defp embedding_capable?(%LLMDB.Model{capabilities: %{embeddings: emb}}) when emb != false,
    do: true

  defp embedding_capable?(_), do: false

  # =============================================================
  # Image Generation Models
  # =============================================================

  @doc """
  Returns only image-generation-capable models.
  Uses ReqLLM.Images.supported_models/0 for best-effort filtering.
  Models not in supported list are gracefully ignored.
  """
  @spec image_generation_models() :: [{String.t(), String.t()}]
  def image_generation_models, do: image_generation_models(LLMDB.models())

  @spec image_generation_models([LLMDB.Model.t()]) :: [{String.t(), String.t()}]
  def image_generation_models(models) do
    supported = MapSet.new(ReqLLM.Images.supported_models())

    models
    |> Enum.filter(fn model ->
      spec = LLMDB.Model.spec(model)
      MapSet.member?(supported, spec) or image_capable?(model)
    end)
    |> Enum.map(&format_model/1)
    |> Enum.sort_by(fn {label, _} -> label end)
  end

  defp image_capable?(%LLMDB.Model{capabilities: caps, id: id}) when is_map(caps) do
    # Check for images capability via Map.get (not in LLMDB type spec but may exist)
    Map.get(caps, :images) == true or name_heuristic_match?(id)
  end

  defp image_capable?(%LLMDB.Model{id: id}) do
    name_heuristic_match?(id)
  end

  defp name_heuristic_match?(id) do
    id_str = to_string(id)

    String.contains?(id_str, "image") or
      String.contains?(id_str, "imagen") or
      String.contains?(id_str, "dall-e")
  end

  # =============================================================
  # Vision Models
  # =============================================================

  @doc """
  Returns only vision-capable models (supports image input).
  """
  @spec vision_models() :: [{String.t(), String.t()}]
  def vision_models, do: vision_models(LLMDB.models())

  @spec vision_models([LLMDB.Model.t()]) :: [{String.t(), String.t()}]
  def vision_models(models) do
    models
    |> Enum.filter(&vision_capable?/1)
    |> Enum.map(&format_model/1)
    |> Enum.sort_by(fn {label, _} -> label end)
  end

  defp vision_capable?(%LLMDB.Model{modalities: %{input: inputs}}) when is_list(inputs),
    do: :image in inputs

  defp vision_capable?(_), do: false

  # =============================================================
  # Models By Provider
  # =============================================================

  @doc """
  Returns models grouped by provider as a map.
  Returns %{provider_name => [{display_label, model_spec}, ...]}
  """
  @spec models_by_provider() :: %{String.t() => [{String.t(), String.t()}]}
  def models_by_provider, do: models_by_provider(LLMDB.models())

  @spec models_by_provider([LLMDB.Model.t()]) :: %{String.t() => [{String.t(), String.t()}]}
  def models_by_provider(models) do
    models
    |> Enum.group_by(fn model -> format_provider(model.provider) end)
    |> Enum.map(fn {provider, provider_models} ->
      formatted = Enum.map(provider_models, &format_model/1)
      {provider, formatted}
    end)
    |> Map.new()
  end

  # =============================================================
  # Availability
  # =============================================================

  @doc """
  Checks if models are available.
  """
  @spec available?() :: boolean()
  def available?, do: available?(LLMDB.models())

  @spec available?([LLMDB.Model.t()]) :: boolean()
  def available?([]), do: false
  def available?(models) when is_list(models), do: true

  # =============================================================
  # Formatting
  # =============================================================

  @doc """
  Formats a single model for dropdown display.
  Returns {display_label, model_spec} tuple.
  """
  @spec format_model(LLMDB.Model.t()) :: {String.t(), String.t()}
  def format_model(%LLMDB.Model{} = model) do
    display = "#{format_provider(model.provider)}: #{model.name || model.id}"
    spec = LLMDB.Model.spec(model)
    {display, spec}
  end

  defp format_provider(provider) when is_atom(provider) do
    provider
    |> Atom.to_string()
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
