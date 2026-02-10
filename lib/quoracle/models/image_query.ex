defmodule Quoracle.Models.ImageQuery do
  @moduledoc """
  Parallel image generation across configured image-capable models.
  Uses Task.async_stream for concurrent execution with ordered results.

  Returns list of per-model results with success/error tuples.
  """

  alias Quoracle.Models.{ConfigModelSettings, CredentialManager}

  @default_timeout 60_000

  @doc """
  Generates images across all configured image generation models.

  ## Parameters
  - prompt: Text prompt for image generation
  - opts: Keyword list with:
    - :source_image (optional) - Base64-encoded image for editing
    - :sandbox_owner (optional) - For test DB access
    - :plug (optional) - Req plug for HTTP stubbing in tests
    - :timeout (optional) - Task timeout in ms (default: 60_000)

  ## Returns
  - {:ok, [%{model: String.t(), image: binary()} | %{model: String.t(), error: term()}]}
  - {:error, :no_models_configured} - No image models configured
  - {:error, :no_images_generated} - All models failed
  """
  @spec generate_images(String.t(), keyword()) ::
          {:ok, [map()]} | {:error, :no_models_configured | :no_images_generated}
  def generate_images(prompt, opts \\ []) do
    case ConfigModelSettings.get_image_generation_models() do
      {:ok, model_ids} ->
        generate_images(prompt, model_ids, opts)

      {:error, :not_configured} ->
        {:error, :no_models_configured}
    end
  end

  @doc """
  Generates images with injectable model list for testing.
  """
  @spec generate_images(String.t(), [String.t()], keyword()) ::
          {:ok, [map()]} | {:error, :no_models_configured | :no_images_generated}
  def generate_images(_prompt, [], _opts) do
    {:error, :no_models_configured}
  end

  def generate_images(prompt, model_ids, opts) when is_list(model_ids) do
    sandbox_owner = Keyword.get(opts, :sandbox_owner)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    results =
      model_ids
      |> Task.async_stream(
        fn model_id -> query_single_model(model_id, prompt, opts, sandbox_owner) end,
        ordered: true,
        timeout: timeout,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, :timeout} -> %{model: "unknown", error: :timeout}
        {:exit, reason} -> %{model: "unknown", error: reason}
      end)

    # Check if at least one image was generated
    successful = Enum.filter(results, &match?(%{image: _}, &1))

    if Enum.empty?(successful) do
      {:error, :no_images_generated}
    else
      {:ok, results}
    end
  end

  defp query_single_model(model_id, prompt, opts, sandbox_owner) do
    # Setup DB access for spawned task
    if sandbox_owner do
      Ecto.Adapters.SQL.Sandbox.allow(Quoracle.Repo, sandbox_owner, self())
    end

    with {:ok, credential} <- CredentialManager.get_credentials(model_id),
         model_spec = Map.get(credential, :model_spec, model_id),
         {:ok, response} <- call_image_api(model_spec, prompt, credential, opts) do
      # Extract image data from ReqLLM.Response
      image_data = extract_image_data(response)
      %{model: model_spec, image: image_data}
    else
      {:error, reason} ->
        %{model: model_id, error: reason}
    end
  end

  defp call_image_api(model_spec, prompt, credential, opts) do
    req_opts = build_req_opts(credential, opts)

    # Build prompt - either text-only or multimodal (text + image)
    prompt_or_context =
      case Keyword.get(opts, :source_image) do
        nil -> prompt
        image_data -> build_edit_context(prompt, image_data)
      end

    ReqLLM.Images.generate_image(model_spec, prompt_or_context, req_opts)
  end

  defp build_edit_context(prompt, image_data) do
    # Build ReqLLM.Context with image for editing
    alias ReqLLM.Message.ContentPart

    ReqLLM.Context.user([
      ContentPart.text(prompt),
      ContentPart.image(image_data, "image/png")
    ])
  end

  defp extract_image_data(%ReqLLM.Response{} = response) do
    # Extract first image from response - try data first, then URL
    ReqLLM.Response.image_data(response) || ReqLLM.Response.image_url(response)
  end

  defp build_req_opts(credential, opts) do
    base_opts = []

    # Add auth based on credential type
    base_opts =
      cond do
        Map.has_key?(credential, :api_key) ->
          Keyword.put(base_opts, :api_key, credential.api_key)

        Map.has_key?(credential, :access_token) ->
          Keyword.put(base_opts, :access_token, credential.access_token)

        true ->
          base_opts
      end

    # Add provider-specific options
    base_opts =
      base_opts
      |> maybe_add(:endpoint_url, credential[:endpoint_url])
      |> maybe_add(:deployment_id, credential[:deployment_id])
      |> maybe_add(:project_id, credential[:resource_id])
      |> maybe_add(:region, credential[:region])

    # Add test plug if provided
    if plug = Keyword.get(opts, :plug) do
      Keyword.put(base_opts, :req_http_options, plug: plug)
    else
      base_opts
    end
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)
end
