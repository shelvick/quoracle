defmodule Quoracle.Actions.API do
  @moduledoc """
  Core action module for making external API calls.

  Supports REST, GraphQL, and JSON-RPC protocols. Orchestrates request building,
  authentication, execution, and response parsing while integrating with the
  security system for credential management and output scrubbing.
  """

  alias Quoracle.Actions.API.{AuthHandler, RequestBuilder, ResponseParser}
  alias Quoracle.Security.{SecretResolver, OutputScrubber}

  @max_response_size 10_000_000

  @type params :: map()
  @type agent_id :: String.t()
  @type opts :: keyword()

  @doc """
  Execute an API call following the 3-arity action signature.

  ## Parameters
    - params: Map with api_type, url, and protocol-specific params
    - agent_id: Agent identifier for secret resolution
    - opts: Keyword list options (unused currently)

  ## Returns
    - {:ok, result} - Successfully executed API call with parsed response
    - {:error, reason} - Validation, execution, or parsing error
  """
  @spec execute(params(), agent_id(), opts()) :: {:ok, map()} | {:error, atom()}
  def execute(params, _agent_id, opts \\ []) do
    start_time = System.monotonic_time(:millisecond)

    with {:ok, resolved_params, secrets_used} <- resolve_secrets(params),
         flattened_params = flatten_auth_params(resolved_params),
         {:ok, request} <- RequestBuilder.build(flattened_params),
         {:ok, request_with_auth} <- AuthHandler.apply_auth(request, flattened_params),
         {:ok, response} <- execute_request(request_with_auth, start_time, opts),
         {:ok, parsed} <- ResponseParser.parse(response, params[:api_type]),
         {:ok, scrubbed} <- scrub_output(parsed, secrets_used) do
      # Add api_type and url to the result
      result =
        Map.merge(scrubbed, %{
          api_type: params[:api_type],
          url: request_with_auth.url
        })

      {:ok, result}
    end
  end

  defp resolve_secrets(params) do
    SecretResolver.resolve_params(params)
  end

  # Transforms Schema API format to AuthHandler internal format.
  #
  # Schema uses nested auth structure:
  #   %{auth: %{type: "bearer", token: "xyz"}}
  #
  # AuthHandler expects flattened parameters:
  #   %{auth_type: "bearer", auth_token: "xyz"}
  #
  # This adapter function bridges the two interfaces during integration.
  defp flatten_auth_params(params) do
    case Map.get(params, :auth) do
      %{type: type} = auth_map ->
        params
        |> Map.delete(:auth)
        |> Map.put(:auth_type, type)
        |> Map.put(:auth_token, Map.get(auth_map, :token))
        |> Map.put(:auth_username, Map.get(auth_map, :username))
        |> Map.put(:auth_password, Map.get(auth_map, :password))
        |> Map.put(:auth_key, Map.get(auth_map, :key))
        |> Map.put(:auth_header_name, Map.get(auth_map, :header_name))
        |> Map.put(:auth_client_id, Map.get(auth_map, :client_id))
        |> Map.put(:auth_client_secret, Map.get(auth_map, :client_secret))
        |> Map.put(:auth_token_url, Map.get(auth_map, :token_url))

      _ ->
        params
    end
  end

  defp execute_request(request, start_time, opts) do
    req_opts = [
      method: request.method,
      url: request.url,
      headers: Map.to_list(request.headers),
      body: request.body,
      receive_timeout: request.timeout,
      redirect: request.follow_redirects,
      # Disable Req's automatic retry - agents can retry explicitly via wait+retry pattern
      # Matches web.ex pattern; explicit retries use RetryHelper where needed
      retry: false,
      plug: opts[:plug]
    ]

    case Req.request(req_opts) do
      {:ok, %{status: status, headers: headers, body: body}} ->
        response_size = if is_binary(body), do: byte_size(body), else: 0

        if response_size > @max_response_size do
          {:error, :response_too_large}
        else
          {:ok,
           %{
             status: status,
             headers: normalize_headers(headers),
             body: body,
             start_time: start_time
           }}
        end

      {:error, %{reason: :timeout}} ->
        {:error, :request_timeout}

      {:error, %{reason: :econnrefused}} ->
        {:error, :connection_refused}

      {:error, _reason} ->
        {:error, :request_failed}
    end
  end

  defp normalize_headers(headers), do: headers

  defp scrub_output(result, secrets_used) do
    scrubbed = OutputScrubber.scrub_result(result, secrets_used)
    {:ok, scrubbed}
  end

  @doc """
  Scrubs secret values from API response.

  Removes any secret values that were used in the request from the response
  body, headers, and any nested structures to prevent sensitive data from
  being exposed to agents.

  ## Parameters
    - response: The API response map with status_code, body, headers
    - used_secrets: Map of secret names to their values that should be scrubbed

  ## Returns
    The response with all secret values replaced by [REDACTED:secret_name]
  """
  @spec scrub_response(map(), map()) :: map()
  def scrub_response(response, used_secrets) do
    OutputScrubber.scrub_result(response, used_secrets)
  end

  @doc """
  Scrubs secret values from API error tuples.

  Removes any secret values from error messages and error data structures
  to prevent sensitive data from being exposed in error reports.

  ## Parameters
    - error: Error tuple like {:error, reason, details}
    - used_secrets: Map of secret names to their values that should be scrubbed

  ## Returns
    The error tuple with all secret values replaced by [REDACTED:secret_name]
  """
  @spec scrub_error(tuple(), map()) :: tuple()
  def scrub_error(error, used_secrets) do
    OutputScrubber.scrub_result(error, used_secrets)
  end
end
