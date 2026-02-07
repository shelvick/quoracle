defmodule Quoracle.Providers.RetryHelper do
  @moduledoc """
  Shared retry logic for provider modules.

  Provides exponential backoff retry functionality for handling transient failures
  like rate limiting (429) and server errors (5xx).

  v3.0: ReqLLM compatibility (status field), Retry-After support, infinite retries for 429/5xx.
  v3.1: Exception handling for malformed LLM responses (empty body crashes from req_llm).
  """

  require Logger

  @doc """
  Executes a function with automatic retry logic for transient failures.

  ## Parameters

  - `func` - The function to execute
  - `opts` - Keyword list of options:
    - `:initial_delay` - Initial delay in milliseconds before first retry (default: 1000)
    - `:error_module` - The error module to pattern match (must have `status` field)
    - `:delay_fn` - Injectable delay function for testing (default: Process.sleep/1)

  ## Returns

  - `{:ok, result}` - On successful execution
  - `{:error, reason}` - On non-retryable error (401/403) or non-matching error

  ## Retry Behavior

  - 429 (Rate Limited): Infinite retries with Retry-After header or exponential backoff
  - 5xx (Server Error): Infinite retries with exponential backoff
  - 401/403 (Auth Error): No retry, immediate failure
  - Other errors: No retry, pass through

  ## Examples

      RetryHelper.with_retry(
        fn -> make_api_call(params) end,
        initial_delay: 1000,
        error_module: ReqLLM.Error.API.Request
      )
  """
  @spec with_retry((-> any()), keyword()) :: {:ok, any()} | {:error, any()}
  def with_retry(func, opts \\ []) do
    initial_delay = Keyword.get(opts, :initial_delay, 1000)
    error_module = Keyword.get(opts, :error_module, nil)
    delay_fn = Keyword.get(opts, :delay_fn, &Process.sleep/1)

    do_retry(func, initial_delay, 1, error_module, delay_fn)
  end

  # Private implementation for general retry logic
  # No max_retries for 429/5xx - they retry infinitely
  # v3.1: Wrap external calls with try/rescue - req_llm can throw on malformed responses
  defp do_retry(func, delay, attempt, error_module, delay_fn) do
    result =
      try do
        func.()
      rescue
        # req_llm throws FunctionClauseError on empty/malformed response bodies
        FunctionClauseError ->
          Logger.error("LLM provider returned malformed response (empty body or invalid format)")
          {:error, :malformed_response}

        e ->
          Logger.error("LLM provider call raised exception: #{Exception.message(e)}")
          {:error, {:provider_exception, Exception.message(e)}}
      end

    case {result, error_module} do
      # Success case
      {{:ok, _}, _} ->
        result

      # Handle ReqLLM errors - 429 Rate Limited (infinite retry)
      {{:error, %{__struct__: module, status: 429} = error}, module} ->
        retry_delay = get_retry_delay(error, delay)

        Logger.warning(
          "Rate limited (429), retrying attempt #{attempt + 1} after #{retry_delay}ms"
        )

        delay_fn.(retry_delay)
        do_retry(func, delay * 2, attempt + 1, error_module, delay_fn)

      # Handle ReqLLM errors - 5xx Server Error (infinite retry)
      {{:error, %{__struct__: module, status: status} = error}, module}
      when status >= 500 and status < 600 ->
        retry_delay = get_retry_delay(error, delay)

        Logger.warning(
          "Server error (#{status}), retrying attempt #{attempt + 1} after #{retry_delay}ms"
        )

        delay_fn.(retry_delay)
        do_retry(func, delay * 2, attempt + 1, error_module, delay_fn)

      # Handle ReqLLM errors - 401 Unauthorized (no retry)
      {{:error, %{__struct__: module, status: 401} = error}, module} ->
        Logger.error("Authentication failed (401) - #{inspect(error)}")
        {:error, :authentication_failed}

      # Handle ReqLLM errors - 403 Forbidden (no retry)
      {{:error, %{__struct__: module, status: 403} = error}, module} ->
        Logger.error("Access forbidden (403) - #{inspect(error)}")
        {:error, :access_forbidden}

      # Pass through any other result (non-matching errors, other statuses)
      _ ->
        result
    end
  end

  # Extract Retry-After delay from error response, or fall back to exponential backoff
  @spec get_retry_delay(map(), pos_integer()) :: pos_integer()
  defp get_retry_delay(error, fallback_delay) do
    response_body = Map.get(error, :response_body, %{})

    cond do
      # Check for lowercase "retry_after" (common in JSON responses)
      is_map(response_body) && Map.has_key?(response_body, "retry_after") ->
        response_body["retry_after"] * 1000

      # Check for "Retry-After" (HTTP header style)
      is_map(response_body) && Map.has_key?(response_body, "Retry-After") ->
        response_body["Retry-After"] * 1000

      # Fall back to exponential backoff
      true ->
        fallback_delay
    end
  end

  @doc """
  Applies exponential backoff delay.

  This is a standalone function that can be used for custom retry implementations.

  ## Parameters

  - `retry_count` - The current retry attempt number (0-based)
  - `base_delay` - The base delay in milliseconds (default: 1000)

  ## Returns

  The number of milliseconds to sleep.

  ## Examples

      # First retry: 1000ms
      RetryHelper.apply_backoff(0)

      # Second retry: 2000ms
      RetryHelper.apply_backoff(1)

      # Third retry: 4000ms
      RetryHelper.apply_backoff(2)
  """
  @spec apply_backoff(non_neg_integer(), pos_integer(), (pos_integer() -> any())) :: pos_integer()
  def apply_backoff(retry_count, base_delay \\ 1000, delay_fn \\ &Process.sleep/1) do
    delay = round(:math.pow(2, retry_count) * base_delay)
    delay_fn.(delay)
    delay
  end
end
