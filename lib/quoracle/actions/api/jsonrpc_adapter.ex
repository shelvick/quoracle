defmodule Quoracle.Actions.API.JSONRPCAdapter do
  @moduledoc """
  JSON-RPC 2.0 protocol adapter for formatting requests and parsing responses.

  Handles JSON-RPC request formatting with auto-generated IDs, response parsing,
  and protocol validation.
  """

  @doc """
  Formats a JSON-RPC 2.0 request.

  ## Parameters
    - url: The JSON-RPC endpoint URL
    - params: Request parameters including method, params, and optional id

  ## Returns
    - `{:ok, request}` - Formatted request ready for HTTP client
    - `{:error, reason}` - Validation or formatting error
  """
  @spec format_request(String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def format_request(url, params) do
    case validate_request(params) do
      :ok ->
        build_request(url, params)

      error ->
        error
    end
  end

  @doc """
  Parses a JSON-RPC 2.0 response.

  ## Parameters
    - response: HTTP response map with status and body
    - request_id: The request ID to validate against

  ## Returns
    - `{:ok, parsed}` - Parsed response with status and result/error
    - `{:error, reason}` - Parse or validation error
  """
  @spec parse_response(map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def parse_response(%{status: status, body: body}, _request_id) when status >= 400 do
    {:ok, %{status: :http_error, http_status: status, error: body}}
  end

  def parse_response(%{status: 200, body: body}, request_id) when is_map(body) do
    jsonrpc = Map.get(body, "jsonrpc")
    id = Map.get(body, "id")
    result = Map.get(body, "result")
    error = Map.get(body, "error")

    cond do
      jsonrpc != "2.0" ->
        {:error, :invalid_jsonrpc_version}

      id != request_id ->
        {:error, :id_mismatch}

      result != nil ->
        {:ok, %{status: :success, result: result, id: id}}

      error != nil ->
        {:ok, %{status: :error, error: error, id: id}}

      true ->
        {:error, :invalid_jsonrpc_response}
    end
  end

  def parse_response(%{status: 200, body: _body}, _request_id) do
    {:error, :invalid_response_format}
  end

  def parse_response(_, _), do: {:error, :invalid_response_format}

  @doc """
  Formats JSON-RPC errors for display.
  """
  @spec format_error(map()) :: String.t()
  def format_error(error) when is_map(error) do
    code = Map.get(error, "code")
    message = Map.get(error, "message")
    data = Map.get(error, "data")

    base = "JSON-RPC error #{code}: #{message}"

    if data do
      data_str = if is_binary(data), do: data, else: inspect(data)
      "#{base} (#{data_str})"
    else
      base
    end
  end

  def format_error(_), do: "Unknown JSON-RPC error"

  @doc """
  Formats a JSON-RPC request with authentication parameters.

  This function formats the JSON-RPC request and preserves authentication
  parameters for later resolution and application by the AuthHandler.

  ## Parameters
    - url: The JSON-RPC endpoint URL
    - params: Request parameters including method, params, and auth fields

  ## Returns
    - `{:ok, request}` - Formatted request with auth_params preserved
    - `{:error, reason}` - Validation or formatting error
  """
  @spec format_request_with_auth(String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def format_request_with_auth(url, params) do
    # First format the basic request
    case format_request(url, params) do
      {:ok, request} ->
        # Extract auth-related fields to pass to AuthHandler
        auth_fields = [
          :auth_type,
          :auth_token,
          :auth_username,
          :auth_password,
          :auth_key_name,
          :auth_key_value,
          :auth_key_location,
          :auth_client_id,
          :auth_client_secret,
          :auth_token_url,
          :auth_header_name
        ]

        auth_params = Map.take(params, auth_fields)

        # Add auth params to request for AuthHandler to process
        request_with_auth = Map.put(request, :auth_params, auth_params)
        {:ok, request_with_auth}

      error ->
        error
    end
  end

  @doc """
  Validates JSON-RPC request parameters.
  """
  @spec validate_request(map()) :: :ok | {:error, atom()}
  def validate_request(params) do
    method = Map.get(params, :method)
    params_value = Map.get(params, :params)

    cond do
      is_nil(method) ->
        {:error, :missing_method}

      not is_binary(method) ->
        {:error, :invalid_method_type}

      params_value != nil and not is_list(params_value) and not is_map(params_value) ->
        {:error, :invalid_params_type}

      true ->
        :ok
    end
  end

  @doc """
  Generates a unique UUID for request IDs.
  """
  @spec generate_id() :: String.t()
  def generate_id do
    Ecto.UUID.generate()
  end

  @doc """
  Extracts error message from JSON-RPC error object.
  """
  @spec extract_error_message(map()) :: String.t()
  def extract_error_message(error) when is_map(error) do
    code = Map.get(error, "code")
    message = Map.get(error, "message")
    data = Map.get(error, "data")

    cond do
      message && data ->
        "#{message} (#{inspect(data)})"

      message ->
        message

      true ->
        "Unknown error (code: #{code})"
    end
  end

  def extract_error_message(_), do: "Unknown error"

  # Private functions

  defp build_request(url, params) do
    method = Map.get(params, :method)
    params_value = Map.get(params, :params)
    id = Map.get(params, :id, generate_id())

    body = %{
      "jsonrpc" => "2.0",
      "method" => method,
      "id" => id
    }

    body =
      if params_value && params_value != [] && params_value != %{} do
        Map.put(body, "params", params_value)
      else
        body
      end

    request = %{
      method: :post,
      url: url,
      headers: [{"content-type", "application/json"}],
      body: body
    }

    # Pass through auth params for RequestBuilder to handle
    auth_params =
      params
      |> Map.take([:auth_type, :auth_token])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    request =
      if map_size(auth_params) > 0 do
        Map.put(request, :auth_params, auth_params)
      else
        request
      end

    {:ok, request}
  end
end
