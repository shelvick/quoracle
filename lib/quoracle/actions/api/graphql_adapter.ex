defmodule Quoracle.Actions.API.GraphQLAdapter do
  @moduledoc """
  GraphQL protocol adapter for formatting requests and parsing responses.

  Handles GraphQL query/mutation formatting, variable injection, and response parsing
  including partial success scenarios.
  """

  @doc """
  Formats a GraphQL request.

  ## Parameters
    - url: The GraphQL endpoint URL
    - params: Request parameters including query, variables, operation_name

  ## Returns
    - `{:ok, request}` - Formatted request ready for HTTP client
    - `{:error, reason}` - Validation or formatting error
  """
  @spec format_request(String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def format_request(url, params) do
    query = Map.get(params, :query)

    cond do
      is_nil(query) ->
        {:error, :missing_query}

      query == "" or String.trim(query) == "" ->
        {:error, :empty_query}

      true ->
        case validate_query(query) do
          :ok ->
            build_request(url, params)

          error ->
            error
        end
    end
  end

  @doc """
  Parses a GraphQL response.

  ## Parameters
    - response: HTTP response map with status and body

  ## Returns
    - `{:ok, parsed}` - Parsed response with status and data/errors
    - `{:error, reason}` - Parse error
  """
  @spec parse_response(map()) :: {:ok, map()} | {:error, atom()}
  def parse_response(%{status: status, body: body}) when status >= 400 do
    {:ok, %{status: :http_error, http_status: status, error: body}}
  end

  def parse_response(%{status: 200, body: body}) when is_map(body) do
    data = Map.get(body, "data")
    errors = Map.get(body, "errors")

    cond do
      data && errors ->
        {:ok, %{status: :partial_success, data: data, errors: errors}}

      data ->
        {:ok, %{status: :success, data: data}}

      errors ->
        {:ok, %{status: :error, errors: errors}}

      true ->
        {:error, :invalid_graphql_response}
    end
  end

  def parse_response(%{status: 200, body: _body}) do
    {:error, :invalid_response_format}
  end

  def parse_response(_), do: {:error, :invalid_response_format}

  @doc """
  Formats GraphQL errors for display.
  """
  @spec format_error(list()) :: String.t()
  def format_error([error]) when is_map(error) do
    message = Map.get(error, "message", "Unknown error")
    extensions = Map.get(error, "extensions")
    path = Map.get(error, "path")
    locations = Map.get(error, "locations")

    cond do
      extensions && Map.has_key?(extensions, "code") ->
        code = extensions["code"]
        "GraphQL error: #{message} (#{code})"

      path ->
        path_str = Enum.join(path, ".")
        "GraphQL error: #{message} (at #{path_str})"

      locations && locations != [] ->
        loc = hd(locations)
        line = Map.get(loc, "line")
        column = Map.get(loc, "column")
        "GraphQL error: #{message} (line #{line}, column #{column})"

      true ->
        "GraphQL error: #{message}"
    end
  end

  def format_error(errors) when is_list(errors) and length(errors) > 1 do
    messages = Enum.map(errors, fn error -> Map.get(error, "message", "Unknown") end)
    formatted = Enum.map_join(messages, "\n- ", & &1)
    "GraphQL errors:\n- #{formatted}"
  end

  def format_error(_), do: "Unknown GraphQL error"

  @doc """
  Formats a GraphQL request with authentication parameters.

  This function formats the GraphQL request and preserves authentication
  parameters for later resolution and application by the AuthHandler.

  ## Parameters
    - url: The GraphQL endpoint URL
    - params: Request parameters including query, variables, and auth fields

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
  Validates GraphQL query syntax.
  """
  @spec validate_query(String.t()) :: :ok | {:error, atom()}
  def validate_query(query) when is_binary(query) do
    trimmed = String.trim(query)

    cond do
      trimmed == "" ->
        {:error, :empty_query}

      not has_braces?(trimmed) ->
        {:error, :invalid_graphql_syntax}

      not balanced_braces?(trimmed) ->
        {:error, :unbalanced_braces}

      true ->
        :ok
    end
  end

  def validate_query(_), do: {:error, :empty_query}

  @doc """
  Extracts the operation type from a GraphQL query.
  """
  @spec extract_operation_type(String.t()) :: :query | :mutation | :subscription
  def extract_operation_type(query) when is_binary(query) do
    trimmed = String.trim(query)

    cond do
      String.starts_with?(trimmed, "mutation") ->
        :mutation

      String.starts_with?(trimmed, "subscription") ->
        :subscription

      true ->
        # Default to query (including shorthand syntax like "{ user { name } }")
        :query
    end
  end

  # Private functions

  defp build_request(url, params) do
    query = Map.get(params, :query)
    variables = Map.get(params, :variables)
    operation_name = Map.get(params, :operation_name)

    body = %{"query" => query}

    body =
      if variables && variables != %{} && variables != [] do
        Map.put(body, "variables", variables)
      else
        body
      end

    body =
      if operation_name do
        Map.put(body, "operationName", operation_name)
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

  defp has_braces?(query) do
    # Simple check: must contain both opening and closing braces
    # This catches obvious syntax errors before checking balance
    has_open = String.contains?(query, "{")
    has_close = String.contains?(query, "}")

    # Must have both, and opening must come before closing
    if has_open and has_close do
      open_pos = :binary.match(query, "{") |> elem(0)
      close_pos = :binary.match(query, "}") |> elem(0)
      open_pos < close_pos
    else
      false
    end
  end

  defp balanced_braces?(query) do
    chars = String.graphemes(query)

    count =
      Enum.reduce(chars, 0, fn
        "{", acc -> acc + 1
        "}", acc -> acc - 1
        _, acc -> acc
      end)

    count == 0
  end
end
