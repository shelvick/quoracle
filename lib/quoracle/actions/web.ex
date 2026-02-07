defmodule Quoracle.Actions.Web do
  @moduledoc """
  Action module for fetching web content and converting to Markdown.
  """

  require Logger

  alias Quoracle.Utils.ResponseTruncator

  @image_content_types ["image/png", "image/jpeg", "image/gif", "image/webp", "image/svg+xml"]

  @doc """
  Fetches web content from URL and converts HTML to Markdown.

  ## Parameters
  - `params`: Map with:
    - `:url` (required, string) - URL to fetch
    - `:timeout` (optional, integer) - HTTP timeout in seconds (default: 30)
    - `:security_check` (optional, boolean) - Enable SSRF protection (default: false)
    - `:user_agent` (optional, string) - Custom User-Agent header (default: HTTP client default)
    - `:follow_redirects` (optional, boolean) - Follow HTTP redirects (default: true)
  - `agent_id`: ID of requesting agent
  - `opts`: Keyword list of options (pubsub, etc.)

  ## Returns
  - `{:ok, result_map}` - Success with markdown, status_code, content_type, sizes, execution_time
  - `{:error, reason}` - Validation errors, HTTP errors, or network failures

  ## Examples
      iex> Web.execute(%{url: "https://example.com"}, "agent-123", [])
      {:ok, %{action: "fetch_web", markdown: "# Example Domain...", ...}}

      iex> Web.execute(%{url: "not-a-url"}, "agent-123", [])
      {:error, :invalid_url_format}
  """
  @spec execute(map(), String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def execute(%{url: url} = params, agent_id, opts) when is_binary(url) do
    start_time = System.monotonic_time(:millisecond)

    with {:ok, validated_url} <- validate_url(url),
         :ok <- validate_url_security(validated_url, params[:security_check]),
         :ok <- validate_timeout(params[:timeout]) do
      fetch_and_convert(validated_url, params, agent_id, opts, start_time)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(%{url: _url}, _agent_id, _opts) do
    {:error, :invalid_param_type}
  end

  def execute(_params, _agent_id, _opts) do
    {:error, :missing_required_param}
  end

  defp validate_url(url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      url == "" -> {:error, :invalid_url_format}
      uri.scheme not in ["http", "https"] -> {:error, :invalid_url_format}
      true -> {:ok, url}
    end
  end

  defp validate_timeout(nil), do: :ok
  defp validate_timeout(timeout) when is_integer(timeout) and timeout > 0, do: :ok
  defp validate_timeout(_), do: {:error, :invalid_timeout}

  defp validate_url_security(_url, false), do: :ok
  defp validate_url_security(_url, nil), do: :ok

  defp validate_url_security(url, true) do
    uri = URI.parse(url)
    host = uri.host || ""

    if blocked_host?(host) do
      {:error, :blocked_domain}
    else
      :ok
    end
  end

  defp blocked_host?(host) do
    String.match?(host, ~r/^localhost$/i) or
      String.starts_with?(host, "127.") or
      String.starts_with?(host, "10.") or
      String.starts_with?(host, "192.168.") or
      String.starts_with?(host, "169.254.") or
      String.match?(host, ~r/^::1$/) or
      String.starts_with?(host, "fc00:") or
      String.starts_with?(host, "fe80:") or
      range_172_16_31?(host)
  end

  defp range_172_16_31?(host) do
    case String.split(host, ".") do
      ["172", second | _] ->
        case Integer.parse(second) do
          {n, _} when n >= 16 and n <= 31 -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp fetch_and_convert(url, params, _agent_id, opts, start_time) do
    # Create request with redirect tracking
    # Convert timeout from seconds to milliseconds (LLMs pass timeout in seconds)
    timeout_ms = (params[:timeout] || 30) * 1000
    headers = if params[:user_agent], do: [{"user-agent", params[:user_agent]}], else: []

    request =
      Req.new(
        base_url: url,
        receive_timeout: timeout_ms,
        redirect: params[:follow_redirects] != false,
        headers: headers,
        retry: false,
        plug: opts[:plug]
      )
      |> Req.Request.prepend_response_steps(
        track_final_url: fn {req, resp} ->
          final_url = req.url |> URI.to_string()
          resp = Req.Response.put_private(resp, :final_url, final_url)
          {req, resp}
        end
      )

    case Req.get(request) do
      {:ok, %Req.Response{status: status, body: body, headers: headers, private: private}} ->
        final_url = Map.get(private, :final_url, url)
        handle_response(status, body, headers, final_url, start_time)

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :request_timeout}

      {:error, %Req.TransportError{reason: :econnrefused}} ->
        {:error, :endpoint_unreachable}

      {:error, %Req.TransportError{reason: :nxdomain}} ->
        {:error, :endpoint_unreachable}

      {:error, reason} ->
        Logger.warning("[fetch_web] Request failed: #{inspect(reason)}")
        {:error, :request_failed}
    end
  end

  defp handle_response(status, body, headers, url, _start_time)
       when status >= 200 and status < 300 do
    content_type = get_content_type(headers)

    if image_content_type?(content_type) do
      # Return image as multimodal structure for ImageDetector
      media_type = normalize_media_type(content_type)
      base64_data = Base.encode64(body)

      {:ok,
       %{
         action: "fetch_web",
         url: url,
         type: "image",
         data: base64_data,
         mimeType: media_type,
         status_code: status,
         content_type: content_type
       }}
    else
      {_original_size, body_string} = get_body_string(body)
      # Truncate HTML BEFORE conversion to limit input size
      truncated_body = ResponseTruncator.truncate_if_large(body_string)
      # Only convert HTML content - other types pass through raw
      # (htmd handles HTML only - XML/SVG pass through raw)
      markdown = maybe_convert_to_markdown(truncated_body, content_type)
      # Final truncation in case conversion expanded content
      truncated_markdown = ResponseTruncator.truncate_if_large(markdown)

      {:ok,
       %{
         action: "fetch_web",
         url: url,
         status_code: status,
         content_type: content_type,
         markdown: truncated_markdown
       }}
    end
  end

  defp handle_response(status, body, headers, url, _start_time)
       when status >= 300 and status < 400 do
    # Handle redirects when follow_redirects: false
    content_type = get_content_type(headers)
    {_original_size, body_string} = get_body_string(body)

    {:ok,
     %{
       action: "fetch_web",
       url: url,
       status_code: status,
       content_type: content_type,
       markdown: body_string
     }}
  end

  defp handle_response(404, _b, _h, _u, _st), do: {:error, :not_found}
  defp handle_response(401, _b, _h, _u, _st), do: {:error, :unauthorized}
  defp handle_response(403, _b, _h, _u, _st), do: {:error, :forbidden}
  defp handle_response(429, _b, _h, _u, _st), do: {:error, :rate_limit_exceeded}

  defp handle_response(status, _b, _h, _u, _st) when status >= 500,
    do: {:error, :service_unavailable}

  defp handle_response(status, _b, _h, url, _st) do
    Logger.warning("[fetch_web] Unhandled HTTP status #{status} for #{url}")
    {:error, :request_failed}
  end

  defp get_content_type(headers) do
    case Enum.find(headers, fn {k, _v} -> String.downcase(k) == "content-type" end) do
      {_k, [v | _]} -> v
      {_k, v} when is_binary(v) -> v
      nil -> "text/html"
    end
  end

  defp image_content_type?(content_type) do
    Enum.any?(@image_content_types, &String.contains?(content_type, &1))
  end

  defp normalize_media_type(content_type) do
    content_type
    |> String.split(";")
    |> List.first()
    |> String.trim()
  end

  defp get_body_string(body) when is_binary(body), do: {byte_size(body), body}

  defp get_body_string(body) when is_map(body) do
    json_string = Jason.encode!(body)
    {byte_size(json_string), json_string}
  end

  defp get_body_string(body) do
    string_body = inspect(body)
    {byte_size(string_body), string_body}
  end

  # Tags to skip during HTML→Markdown conversion (non-content elements)
  @skip_tags ["script", "style", "svg"]

  defp maybe_convert_to_markdown(body, content_type) when is_binary(body) do
    if html_content_type?(content_type) do
      body
      |> Htmd.convert!(skip_tags: @skip_tags)
      |> strip_invisible_unicode()
      |> String.trim()
    else
      String.trim(body)
    end
  end

  # Strip invisible Unicode characters that can cause issues with LLM tokenizers
  # U+200B Zero Width Space, U+200C Zero Width Non-Joiner, U+200D Zero Width Joiner,
  # U+FEFF Byte Order Mark, U+00AD Soft Hyphen
  defp strip_invisible_unicode(text) do
    String.replace(text, ~r/[\x{200B}\x{200C}\x{200D}\x{FEFF}\x{00AD}]/u, "")
  end

  defp html_content_type?(content_type) do
    # Only convert actual HTML - everything else passes through raw
    content_type =~ ~r{^text/html}i or content_type =~ ~r{^application/xhtml\+xml}i
  end
end
