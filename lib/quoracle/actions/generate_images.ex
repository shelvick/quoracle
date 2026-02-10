defmodule Quoracle.Actions.GenerateImages do
  @moduledoc """
  Action module for parallel image generation across configured models.
  Uses MODEL_ImageQuery to query all configured image generation models.
  Returns array of generated images with model attribution.
  """

  alias Quoracle.Models.ImageQuery
  alias Quoracle.Costs.Recorder, as: CostRecorder
  require Logger

  @doc """
  Executes image generation across all configured image models.

  ## Parameters
  - params: Map with:
    - :prompt (required, string) - Text prompt for image generation
    - :source_image (optional, string) - Base64-encoded image for editing
  - agent_id: ID of requesting agent
  - opts: Keyword list with:
    - :sandbox_owner - For test DB access
    - :plug - Req plug for HTTP stubbing in tests
    - :agent_id, :task_id, :pubsub - For cost recording

  ## Returns
  - {:ok, %{action: "generate_images", images: [...], execution_time_ms: N}}
  - {:error, :missing_required_param} - No prompt provided
  - {:error, :invalid_param_type} - Prompt is not a string
  - {:error, :no_models_configured} - No image models configured
  - {:error, :no_images_generated} - All models failed
  """
  @spec execute(map(), String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def execute(params, agent_id, opts \\ [])

  def execute(%{prompt: prompt} = params, _agent_id, opts)
      when is_binary(prompt) and prompt != "" do
    # Build query options
    query_opts =
      opts
      |> Keyword.take([:sandbox_owner, :plug])
      |> maybe_add_source_image(params)

    case ImageQuery.generate_images(prompt, query_opts) do
      {:ok, results} ->
        # Format results for action response
        images = format_image_results(results)

        # Record cost if context provided
        maybe_record_cost(results, opts)

        {:ok,
         %{
           action: "generate_images",
           images: images
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def execute(%{prompt: ""}, _agent_id, _opts), do: {:error, :missing_required_param}
  def execute(%{prompt: nil}, _agent_id, _opts), do: {:error, :missing_required_param}

  def execute(%{prompt: prompt}, _agent_id, _opts) when not is_binary(prompt),
    do: {:error, :invalid_param_type}

  def execute(_params, _agent_id, _opts), do: {:error, :missing_required_param}

  # Format results for action response
  defp format_image_results(results) do
    Enum.map(results, fn
      %{model: model, image: image_data} ->
        %{
          model: model,
          data: image_data,
          status: "success"
        }

      %{model: model, error: reason} ->
        %{
          model: model,
          error: format_error(reason),
          status: "error"
        }
    end)
  end

  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp count_successes(results) do
    Enum.count(results, &match?(%{image: _}, &1))
  end

  defp maybe_add_source_image(opts, %{source_image: image}) when is_binary(image) do
    Keyword.put(opts, :source_image, image)
  end

  defp maybe_add_source_image(opts, _params), do: opts

  @doc """
  Looks up LLMDB image pricing for a model_spec string.
  Returns a Decimal cost or nil if unavailable.
  """
  @spec compute_image_cost(String.t()) :: Decimal.t() | nil
  def compute_image_cost(model_spec) when is_binary(model_spec) do
    case LLMDB.model(model_spec) do
      {:ok, %{cost: %{image: cost}}} when not is_nil(cost) ->
        Decimal.new("#{cost}")

      _ ->
        nil
    end
  end

  # Record one cost entry per successful model
  defp maybe_record_cost(results, opts) do
    agent_id = Keyword.get(opts, :agent_id)
    task_id = Keyword.get(opts, :task_id)
    pubsub = Keyword.get(opts, :pubsub)

    # Only record if all required context is present
    if agent_id && task_id && pubsub do
      results
      |> Enum.filter(&match?(%{image: _}, &1))
      |> Enum.each(fn result ->
        cost_data = %{
          agent_id: agent_id,
          task_id: task_id,
          cost_type: "image_generation",
          cost_usd: compute_image_cost(result.model),
          metadata: %{
            "model_spec" => result.model,
            "models_queried" => length(results),
            "models_succeeded" => count_successes(results)
          }
        }

        CostRecorder.record(cost_data, pubsub: pubsub)
      end)
    end
  end
end
