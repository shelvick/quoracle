defmodule Quoracle.Actions.API.ResponseParser do
  @moduledoc """
  Parses HTTP responses based on API protocol type (REST, GraphQL, JSON-RPC).

  Extracts data and errors appropriately, and returns standardized result structures.
  Handles protocol-specific error formats while maintaining consistent error reporting.
  """

  @max_response_size 10_000_000

  @type response :: map()
  @type api_type :: :rest | :graphql | :jsonrpc

  @doc """
  Parses an HTTP response based on the API type.

  ## Parameters
    - response: Map with status, headers, body
    - api_type: Protocol type (:rest, :graphql, :jsonrpc)

  ## Returns
    - {:ok, parsed_result} - Successfully parsed response
    - {:error, reason} - Parse error or protocol violation
  """
  @spec parse(response(), api_type()) :: {:ok, map()} | {:error, atom()}
  def parse(response, api_type) do
    with :ok <- check_response_size(response) do
      case api_type do
        :rest -> parse_rest(response)
        :graphql -> parse_graphql(response)
        :jsonrpc -> parse_jsonrpc(response)
        _ -> {:error, :invalid_api_type}
      end
    end
  end

  defp check_response_size(%{body: body}) when is_binary(body) do
    if byte_size(body) > @max_response_size do
      {:error, :response_too_large}
    else
      :ok
    end
  end

  defp check_response_size(_), do: :ok

  defp parse_rest(%{status: status, body: body, headers: headers} = response) do
    cond do
      status >= 200 and status < 300 ->
        data = parse_body(body, headers)
        result = build_result(status, data, [], response)
        {:ok, result}

      status == 400 ->
        {:error, :bad_request}

      status == 401 ->
        {:error, :auth_failed}

      status == 403 ->
        {:error, :forbidden}

      status == 404 ->
        {:error, :not_found}

      status == 408 ->
        {:error, :request_timeout}

      status == 429 ->
        {:error, :rate_limit_exceeded}

      status == 500 ->
        {:error, :internal_server_error}

      status == 502 ->
        {:error, :bad_gateway}

      status == 503 ->
        {:error, :service_unavailable}

      status == 504 ->
        {:error, :gateway_timeout}

      true ->
        {:error, :unknown_error}
    end
  end

  defp parse_graphql(%{status: status, body: body} = response) do
    if status != 200 do
      {:error, :graphql_http_error}
    else
      case parse_json(body) do
        {:ok, %{"data" => data, "errors" => errors}} when is_list(errors) ->
          # Partial success - has both data and errors
          result = build_result(status, data, errors, response)
          {:ok, result}

        {:ok, %{"data" => data}} ->
          # Success - data only
          result = build_result(status, data, [], response)
          {:ok, result}

        {:ok, %{"errors" => errors}} when is_list(errors) ->
          # Error only - no data
          result = build_result(status, nil, errors, response)
          {:ok, result}

        {:ok, parsed} ->
          # Malformed GraphQL response - handle gracefully
          result = build_result(status, parsed, [], response)
          {:ok, result}

        {:error, _} ->
          {:error, :parse_failed}
      end
    end
  end

  defp parse_jsonrpc(%{status: status, body: body} = response) do
    case parse_json(body) do
      {:ok, [%{"result" => result, "id" => _id, "jsonrpc" => _version}]} ->
        # Single-item batch response with id - unwrap the array
        parsed_result = build_result(status, result, [], response)
        {:ok, parsed_result}

      {:ok, [%{"result" => result, "jsonrpc" => _version}]} ->
        # Single-item batch notification (no id field) - unwrap the array
        parsed_result = build_result(status, result, [], response)
        {:ok, parsed_result}

      {:ok, %{"result" => result, "id" => _id, "jsonrpc" => _version}} ->
        # Success response with id (lenient version checking)
        parsed_result = build_result(status, result, [], response)
        {:ok, parsed_result}

      {:ok, %{"result" => result, "jsonrpc" => _version}} ->
        # Notification response (no id field, lenient version)
        parsed_result = build_result(status, result, [], response)
        {:ok, parsed_result}

      {:ok, %{"error" => _error, "id" => _id, "jsonrpc" => _version}} ->
        # Error response - JSON-RPC errors are returned as error tuples
        {:error, :rpc_error}

      {:ok, %{"error" => _error, "jsonrpc" => _version}} ->
        # Error notification (no id field)
        {:error, :rpc_error}

      {:ok, %{"jsonrpc" => _version}} ->
        # Valid JSON-RPC but missing result/error
        {:error, :invalid_jsonrpc_response}

      {:ok, _} ->
        # Not JSON-RPC format
        {:error, :invalid_jsonrpc_response}

      {:error, _} ->
        {:error, :parse_failed}
    end
  end

  defp parse_body(body, headers) when is_binary(body) do
    content_type = get_content_type(headers)

    cond do
      String.contains?(content_type, "json") ->
        case parse_json(body) do
          {:ok, parsed} -> parsed
          {:error, _} -> body
        end

      String.contains?(content_type, "html") ->
        body

      String.contains?(content_type, "xml") ->
        body

      String.contains?(content_type, "text") ->
        body

      true ->
        # Try to parse as JSON anyway
        case parse_json(body) do
          {:ok, parsed} -> parsed
          {:error, _} -> body
        end
    end
  end

  defp parse_body(body, _headers), do: body

  defp parse_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp parse_json(body), do: {:ok, body}

  defp get_content_type(headers) when is_map(headers) do
    headers
    |> Enum.find(fn {k, _v} -> String.downcase(to_string(k)) == "content-type" end)
    |> case do
      {_k, v} -> String.downcase(to_string(v))
      nil -> ""
    end
  end

  defp get_content_type(_), do: ""

  defp build_result(status_code, data, errors, _response) do
    %{
      action: "call_api",
      status_code: status_code,
      data: data,
      errors: errors
    }
  end
end
