defmodule Quoracle.Actions.API.RequestBuilder do
  @moduledoc """
  Constructs HTTP requests for REST, GraphQL, and JSON-RPC API calls.

  Provides protocol-specific request building while maintaining a consistent interface.
  Validates URL format, request body size, and constructs properly formatted requests
  for each supported protocol.
  """

  @default_max_body_size 5_000_000

  @type params :: map()

  @doc """
  Builds an HTTP request from the provided parameters.

  ## Parameters
    - params: Map with api_type, url, and protocol-specific params

  ## Returns
    - {:ok, request_map} - Successfully built request
    - {:error, reason} - Validation or construction error
  """
  @spec build(params()) :: {:ok, map()} | {:error, atom()}
  def build(params) do
    with :ok <- validate_url(params[:url]),
         :ok <- validate_body_size(params),
         {:ok, method} <- get_http_method(params),
         {:ok, url} <- build_url(params),
         {:ok, headers} <- build_headers(params),
         {:ok, body} <- build_body(params) do
      timeout = (params[:timeout] || 30) * 1000

      request = %{
        method: method,
        url: url,
        headers: headers,
        body: body,
        timeout: timeout,
        follow_redirects: Map.get(params, :follow_redirects, true)
      }

      {:ok, request}
    end
  end

  defp validate_url(nil), do: {:error, :invalid_url}

  defp validate_url(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.scheme in ["http", "https"] and uri.host do
      :ok
    else
      {:error, :invalid_url}
    end
  end

  defp validate_url(_), do: {:error, :invalid_url}

  defp validate_body_size(%{body: body} = params) when is_binary(body) do
    max_size = Map.get(params, :max_body_size, @default_max_body_size)

    if byte_size(body) > max_size do
      {:error, :body_too_large}
    else
      :ok
    end
  end

  defp validate_body_size(%{body: body} = params) when is_map(body) or is_list(body) do
    encoded = Jason.encode!(body)
    max_size = Map.get(params, :max_body_size, @default_max_body_size)

    if byte_size(encoded) > max_size do
      {:error, :body_too_large}
    else
      :ok
    end
  end

  defp validate_body_size(_), do: :ok

  defp get_http_method(%{api_type: :rest, method: method}) when is_binary(method) do
    normalized = method |> String.downcase() |> String.to_atom()

    if normalized in [:get, :post, :put, :delete, :patch, :head, :options] do
      {:ok, normalized}
    else
      {:error, :invalid_method}
    end
  end

  defp get_http_method(%{api_type: :rest}), do: {:error, :missing_required_param}
  defp get_http_method(%{api_type: :graphql}), do: {:ok, :post}
  defp get_http_method(%{api_type: :jsonrpc}), do: {:ok, :post}
  defp get_http_method(_), do: {:error, :missing_required_param}

  defp build_url(%{url: url, query_params: params})
       when is_map(params) and map_size(params) > 0 do
    uri = URI.parse(url)
    existing_query = URI.decode_query(uri.query || "")
    merged_query = Map.merge(existing_query, stringify_keys(params))

    updated_uri = %{uri | query: URI.encode_query(merged_query)}
    {:ok, URI.to_string(updated_uri)}
  end

  defp build_url(%{url: url}), do: {:ok, url}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp build_headers(%{api_type: :rest} = params) do
    base_headers = %{
      "Accept" => "application/json"
    }

    headers =
      if params[:body] do
        Map.put(base_headers, "Content-Type", "application/json")
      else
        base_headers
      end

    custom_headers = params[:headers] || %{}
    {:ok, Map.merge(headers, custom_headers)}
  end

  defp build_headers(%{api_type: api_type} = params) when api_type in [:graphql, :jsonrpc] do
    base_headers = %{
      "Content-Type" => "application/json",
      "Accept" => "application/json"
    }

    custom_headers = params[:headers] || %{}
    {:ok, Map.merge(base_headers, custom_headers)}
  end

  defp build_headers(_), do: {:ok, %{}}

  defp build_body(%{api_type: :rest, body: body}) when is_map(body) or is_list(body) do
    {:ok, Jason.encode!(body)}
  end

  defp build_body(%{api_type: :rest, body: body}) when is_binary(body) do
    {:ok, body}
  end

  defp build_body(%{api_type: :rest}), do: {:ok, ""}

  defp build_body(%{api_type: :graphql, query: query} = params) do
    body = %{
      "query" => query,
      "variables" => params[:variables] || %{}
    }

    {:ok, Jason.encode!(body)}
  end

  defp build_body(%{api_type: :graphql}), do: {:error, :missing_required_param}

  defp build_body(%{api_type: :jsonrpc, rpc_method: method} = params) do
    id = params[:rpc_id] || generate_rpc_id()

    body = %{
      "jsonrpc" => "2.0",
      "method" => method,
      "id" => id
    }

    body =
      if params[:rpc_params] do
        Map.put(body, "params", params[:rpc_params])
      else
        body
      end

    {:ok, Jason.encode!(body)}
  end

  defp build_body(%{api_type: :jsonrpc}), do: {:error, :missing_required_param}

  defp build_body(_), do: {:ok, ""}

  defp generate_rpc_id do
    "rpc_#{:erlang.unique_integer([:positive])}"
  end
end
