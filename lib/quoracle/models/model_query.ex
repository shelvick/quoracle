defmodule Quoracle.Models.ModelQuery do
  @moduledoc """
  Synchronous pure module for querying multiple LLM models in parallel.
  Calls ReqLLM.generate_text directly with model_spec from credentials.
  """

  alias Quoracle.Models.{CredentialManager, Embeddings, TableCredentials}
  alias Quoracle.Models.ModelQuery.{CacheHelper, MessageBuilder, OptionsBuilder, UsageHelper}
  alias Quoracle.Providers.RetryHelper
  require Logger

  @type content_part :: %{
          type: atom(),
          text: String.t() | nil,
          url: String.t() | nil,
          data: binary() | nil,
          media_type: String.t() | nil
        }

  @type message :: %{
          role: String.t(),
          content: String.t() | [content_part()]
        }

  @type query_result :: %{
          successful_responses: list(map()),
          failed_models: list({String.t(), atom()}),
          total_latency_ms: integer(),
          aggregate_usage: %{
            input_tokens: integer(),
            output_tokens: integer(),
            input_cost: Decimal.t() | nil,
            output_cost: Decimal.t() | nil,
            total_cost: Decimal.t() | nil
          }
        }

  @doc """
  Queries multiple LLM models in parallel, returning all responses or error.
  """
  @spec query_models([message()], [String.t()], map() | nil) ::
          {:ok, query_result()} | {:error, atom()}
  def query_models(_messages, [], _options) do
    {:error, :no_models_specified}
  end

  def query_models(_messages, model_names, _options) when not is_list(model_names) do
    {:error, :invalid_input}
  end

  def query_models(messages, model_names, options) do
    options = options || %{}

    # Validate message format
    case MessageBuilder.validate_messages(messages) do
      :ok ->
        # Do NOT deduplicate - allow duplicate model names for multiple queries
        # Check if any models are embeddings - if so, reject them early
        if Enum.any?(model_names, &String.contains?(&1, "embedding")) do
          # If ALL models are embeddings, return error
          non_embedding = Enum.reject(model_names, &String.contains?(&1, "embedding"))

          if Enum.empty?(non_embedding) do
            {:error, :model_not_found}
          else
            # Continue with non-embedding models
            with :ok <- validate_all_models_exist(non_embedding) do
              execute_parallel_queries(messages, non_embedding, options)
            end
          end
        else
          # No embedding models, proceed normally
          with :ok <- validate_all_models_exist(model_names) do
            execute_parallel_queries(messages, model_names, options)
          end
        end

      {:error, _reason} ->
        {:error, :invalid_message_format}
    end
  end

  defp validate_all_models_exist(_model_names) do
    # Validation now happens in query_real_model when we check credentials/config
    :ok
  end

  defp execute_parallel_queries(messages, model_names, options) do
    start_time = System.monotonic_time(:millisecond)

    # Execute queries based on configured execution mode
    # Parallel execution by default for optimal performance
    # Caller can override with execution_mode option if needed
    # Sandbox access is properly handled in query_single_model for test isolation
    execution_mode = Map.get(options, :execution_mode, :parallel)

    results =
      case execution_mode do
        :sequential ->
          # Sequential execution - safe for test environments
          Enum.map(model_names, &query_single_model(messages, &1, options))

        :parallel ->
          # Parallel execution - optimal for production
          # Let providers handle their own timeouts - we wait forever
          tasks =
            Enum.map(
              model_names,
              &Task.async(fn -> query_single_model(messages, &1, options) end)
            )

          try do
            # Wait indefinitely - let HTTP layer handle timeouts
            Task.await_many(tasks, :infinity)
          rescue
            error ->
              # Clean up any still-running tasks to prevent resource leaks
              Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
              reraise error, __STACKTRACE__
          catch
            :exit, reason ->
              # Clean up on exit as well
              Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
              exit(reason)
          end
      end

    end_time = System.monotonic_time(:millisecond)
    total_latency = end_time - start_time
    process_results(results, model_names, total_latency, options)
  end

  defp query_single_model(messages, model_name, options) do
    # FIX: Setup sandbox access for test environment to prevent DB connection races
    # Only call Sandbox.allow when in parallel mode (Task.async spawns new processes)
    # In sequential mode, the test process already has access and re-allowing can cause issues
    execution_mode = options[:execution_mode]

    if owner_pid = options[:sandbox_owner] do
      # Only setup sandbox for spawned processes (parallel mode)
      # Sequential mode runs in test process which already has access
      if execution_mode != :sequential do
        Ecto.Adapters.SQL.Sandbox.allow(Quoracle.Repo, owner_pid, self())
      end
    end

    start_time = System.monotonic_time(:millisecond)

    # FIX: Skip DB operations if we're in a test that will simulate failure
    # This prevents DB connection errors when the test process crashes
    result =
      if options[:simulate_failure] || options[:force_consensus_failure] do
        # Return mock error for tests that will crash
        {:error, :simulated_failure}
      else
        # Query the real model through providers
        query_real_model(model_name, messages, options, start_time)
      end

    {model_name, result}
  end

  defp query_real_model(model_name, messages, options, start_time) do
    # Fetch credentials from CredentialManager - this validates the model exists
    # Wrap in try/rescue/catch to handle test cleanup race conditions
    credentials_result =
      try do
        CredentialManager.get_credentials(model_name)
      rescue
        _e in DBConnection.OwnershipError ->
          # Task has no sandbox access (test without sandbox_owner passed)
          {:error, :db_access_required}
      catch
        :exit, {:shutdown, %DBConnection.ConnectionError{}} ->
          # Expected during async test cleanup when owner exits
          {:error, :test_cleanup}

        :exit, _reason ->
          # Other exit reasons during test cleanup
          {:error, :test_cleanup}
      end

    do_query_real_model(
      nil,
      model_name,
      messages,
      options,
      start_time,
      credentials_result
    )
  end

  defp do_query_real_model(
         _model_atom,
         _model_name,
         messages,
         options,
         _start_time,
         credentials_result
       ) do
    case credentials_result do
      {:ok, credential} ->
        # Validate credential has model_spec for ReqLLM
        if is_nil(credential.model_spec) or credential.model_spec == "" do
          Logger.error("Credential for model missing model_spec - cannot use ReqLLM")
          {:error, :missing_model_spec}
        else
          # Direct ReqLLM path - all production credentials must have model_spec
          query_via_reqllm(credential, credential.model_spec, messages, options)
        end

      {:error, :not_found} ->
        # Credentials not in database - model not configured
        {:error, :model_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Direct ReqLLM path with retry support (v8.0)
  defp query_via_reqllm(credential, model_spec, messages, options) do
    # Build ReqLLM messages from string-role messages
    req_messages = MessageBuilder.build_messages(messages)
    # Build options with credential info
    req_opts = build_options(credential, options)

    # v8.0: Wrap ReqLLM call with RetryHelper for 429/5xx retry
    # Uses infinite retries with Retry-After support
    # Allow delay_fn injection for testing (skips real delays)
    retry_opts = [
      initial_delay: 1000,
      error_module: ReqLLM.Error.API.Request
    ]

    # Pass through delay_fn if provided (for test isolation)
    retry_opts =
      if delay_fn = Map.get(options, :delay_fn) do
        Keyword.put(retry_opts, :delay_fn, delay_fn)
      else
        retry_opts
      end

    case RetryHelper.with_retry(
           fn -> ReqLLM.generate_text(model_spec, req_messages, req_opts) end,
           retry_opts
         ) do
      {:ok, response} ->
        CacheHelper.log_cache_metrics(response)
        {:ok, response}

      error ->
        error
    end
  end

  @doc false
  # Public for testing (R14-R17) - builds provider-specific options for ReqLLM
  @spec build_options(%TableCredentials{}, map()) :: keyword()
  defdelegate build_options(credential, options), to: OptionsBuilder

  # Delegate cache functions to CacheHelper (extracted for <500 line module)
  defdelegate log_cache_metrics(response), to: CacheHelper

  defp process_results(results, model_names, total_latency, options) do
    # Separate successful and failed responses, keeping model names with responses
    {successful_with_models, failed} =
      results
      |> Enum.zip(model_names)
      |> Enum.reduce({[], []}, fn
        {{_result_model, {:ok, response}}, model_name}, {succ, fail} ->
          {[{model_name, response} | succ], fail}

        {{model_name, {:error, reason}}, _}, {succ, fail} ->
          {succ, [{model_name, reason} | fail]}

        {{model_name, _}, _}, {succ, fail} ->
          {succ, [{model_name, :unknown_error} | fail]}
      end)

    successful_with_models = Enum.reverse(successful_with_models)
    successful_responses = Enum.map(successful_with_models, fn {_model, response} -> response end)
    failed_models = Enum.reverse(failed)

    # Check if all models failed with permanent errors (not timeouts)
    all_permanent_failures =
      not Enum.empty?(failed_models) and
        Enum.empty?(successful_responses) and
        Enum.all?(failed_models, fn {_model, reason} ->
          permanent_error?(reason)
        end)

    if all_permanent_failures do
      {:error, :all_models_unavailable}
    else
      # Calculate aggregate usage
      aggregate_usage = UsageHelper.calculate_aggregate_usage(successful_responses)

      # Record costs for each successful model if context provided
      UsageHelper.maybe_record_costs(successful_with_models, options)

      {:ok,
       %{
         successful_responses: successful_responses,
         failed_models: failed_models,
         total_latency_ms: total_latency,
         aggregate_usage: aggregate_usage
       }}
    end
  end

  @doc """
  Check if an error is permanent (not a transient/timeout error).
  v8.0: 429 is NOT permanent - it should be retried.
  Only 401 (auth failed) and 403 (forbidden) are permanent.
  """
  @spec permanent_error?(term()) :: boolean()
  def permanent_error?(%ReqLLM.Error.API.Request{status: status})
      when status in [401, 403] do
    true
  end

  def permanent_error?(reason)
      when reason in [:provider_error, :authentication_failed] do
    true
  end

  def permanent_error?(_), do: false

  # Delegate usage calculation to UsageHelper (extracted for <500 line module)
  defdelegate calculate_aggregate_usage(responses), to: UsageHelper

  @doc """
  Gets all models for a specific provider prefix.

  ## Parameters
  - `provider_prefix`: Provider prefix from model_spec (e.g., "azure", "google-vertex")

  ## Returns
  - List of credentials matching the provider prefix
  """
  @spec get_models_by_provider(String.t()) :: list(map())
  def get_models_by_provider(provider_prefix) when is_binary(provider_prefix) do
    import Ecto.Query
    alias Quoracle.Models.TableCredentials

    # Query credentials by model_spec prefix (e.g., "azure:" matches "azure:o1")
    prefix_pattern = "#{provider_prefix}:%"

    TableCredentials
    |> where([c], like(c.model_spec, ^prefix_pattern))
    |> Quoracle.Repo.all()
  end

  @doc """
  Gets embedding for text using azure_text_embedding_3_large model.
  Automatically chunks long text and averages embeddings.
  Returns {:ok, %{embedding: list(), cached: boolean(), chunks: integer()}}
  """
  @spec get_embedding(String.t()) :: {:ok, map()} | {:error, atom()}
  @spec get_embedding(String.t(), map() | keyword()) :: {:ok, map()} | {:error, atom()}
  defdelegate get_embedding(text), to: Embeddings
  defdelegate get_embedding(text, options), to: Embeddings
end
