defmodule Quoracle.Consensus.ActionParser do
  @moduledoc """
  Parses LLM JSON responses into validated action maps.
  Handles both plain JSON and JSON wrapped in Markdown or other formats.
  Supports both ReqLLM.Response structs (production) and maps (legacy/tests).
  """

  require Logger

  alias Quoracle.Utils.{BugReportLogger, JsonExtractor}

  @type action_response :: %{
          action: atom(),
          params: map(),
          reasoning: String.t(),
          wait: boolean() | integer() | nil,
          auto_complete_todo: boolean() | nil
        }

  @doc """
  Parses a JSON response string into an action map.
  Handles both plain JSON and JSON wrapped in Markdown or other formats.
  Validates the action type and required fields.

  ## Options
    * `:log_path` - Path for bug report logging (for test isolation)
    * `:model_id` - Model identifier for bug report attribution
  """
  @spec parse_json_response(String.t(), keyword()) :: {:ok, action_response()} | {:error, atom()}
  def parse_json_response(json_string, opts) when is_binary(json_string) do
    maybe_log_bug_report(json_string, opts)
    parse_json_response(json_string)
  end

  @spec parse_json_response(String.t()) :: {:ok, action_response()} | {:error, atom()}
  def parse_json_response(json_string) when is_binary(json_string) do
    case JsonExtractor.decode_with_extraction(json_string) do
      {:ok, parsed} ->
        validate_and_convert_action(parsed)

      {:error, reason} ->
        Logger.error("Failed to parse JSON: #{reason}")
        {:error, :invalid_json}
    end
  end

  def parse_json_response(_), do: {:error, :invalid_json}

  defp validate_and_convert_action(parsed) when is_map(parsed) do
    with {:ok, action} <- extract_action(parsed),
         {:ok, params} <- extract_params(parsed),
         {:ok, reasoning} <- extract_reasoning(parsed),
         {:ok, wait} <- extract_wait(parsed, action),
         {:ok, auto_complete_todo} <- extract_auto_complete_todo(parsed, action),
         :ok <- validate_action_type(action) do
      {:ok,
       %{
         action: action,
         params: params,
         reasoning: reasoning,
         wait: wait,
         auto_complete_todo: auto_complete_todo
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_action(%{"action" => action}) when is_binary(action) do
    try do
      {:ok, String.to_existing_atom(action)}
    rescue
      ArgumentError -> {:error, :unknown_action}
    end
  end

  defp extract_action(%{"action" => action}) when is_atom(action) do
    {:ok, action}
  end

  defp extract_action(_), do: {:error, :missing_fields}

  defp extract_params(%{"params" => params}) when is_map(params) do
    {:ok, params}
  end

  defp extract_params(_), do: {:error, :missing_fields}

  defp extract_reasoning(%{"reasoning" => reasoning}) when is_binary(reasoning) do
    {:ok, reasoning}
  end

  defp extract_reasoning(_), do: {:error, :missing_fields}

  defp extract_wait(%{"wait" => wait}, _action) when is_boolean(wait) or is_integer(wait) do
    {:ok, wait}
  end

  defp extract_wait(_parsed, :wait) do
    {:ok, nil}
  end

  defp extract_wait(_parsed, _action) do
    {:ok, nil}
  end

  defp extract_auto_complete_todo(_parsed, :todo) do
    {:ok, nil}
  end

  defp extract_auto_complete_todo(%{"auto_complete_todo" => auto_complete_todo}, _action)
       when is_boolean(auto_complete_todo) do
    {:ok, auto_complete_todo}
  end

  defp extract_auto_complete_todo(_parsed, _action) do
    {:ok, nil}
  end

  defp validate_action_type(action) do
    case Quoracle.Actions.Schema.validate_action_type(action) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # =============================================================================
  # LLM Response Parsing (extracted from Consensus module)
  # =============================================================================

  @doc """
  Parses a list of raw LLM responses into action maps.
  Handles both ReqLLM.Response structs (production) and maps (legacy/tests).
  Returns nil for responses that fail to parse.

  ## Options
    * `:log_path` - Path for bug report logging (for test isolation)
  """
  @spec parse_llm_responses([any()], keyword()) :: [action_response() | nil]
  def parse_llm_responses(raw_responses, opts \\ []) do
    Enum.map(raw_responses, &parse_single_response(&1, opts))
  end

  # Parse a single response into action format
  defp parse_single_response(%ReqLLM.Response{} = response, opts) do
    content = ReqLLM.Response.text(response)
    model = response.model
    parse_content(content, model, opts)
  end

  defp parse_single_response(response, opts) when is_map(response) do
    content = response[:content] || response["content"]
    model = response[:model] || response["model"]
    parse_content(content, model, opts)
  end

  defp parse_content(content, model, opts) do
    if content do
      opts_with_model = Keyword.put(opts, :model_id, model)

      case parse_json_response(content, opts_with_model) do
        {:ok, parsed} ->
          parsed

        {:error, reason} ->
          if model do
            Logger.error("Failed to parse JSON from #{model}: #{inspect(reason)}")
          end

          nil
      end
    else
      if model do
        Logger.error("No content in response from #{model}")
      end

      nil
    end
  end

  @doc """
  Extracts the optional condense field from a raw LLM JSON response map.
  Returns a positive integer if valid, nil otherwise.

  Unlike other fields, this is extracted separately from parsing since it's
  per-model-response (like bug_report), not part of the action_response struct.

  ## Examples

      iex> extract_condense(%{"condense" => 5, "action" => "wait"})
      5

      iex> extract_condense(%{"action" => "wait"})
      nil

      iex> extract_condense(%{"condense" => -1})
      nil  # logs warning
  """
  @spec extract_condense(any()) :: pos_integer() | nil
  def extract_condense(%{"condense" => n}) when is_integer(n) and n > 0, do: n

  def extract_condense(%{"condense" => nil}), do: nil

  def extract_condense(%{"condense" => value}) do
    Logger.warning("Invalid condense value: #{inspect(value)} (must be positive integer)")
    nil
  end

  def extract_condense(input) when is_map(input), do: nil

  def extract_condense(_), do: nil

  # Extracts bug_report from raw JSON and logs it if present.
  # Handles both raw JSON and markdown-wrapped JSON (e.g., ```json\n{...}\n```)
  defp maybe_log_bug_report(json_string, opts) do
    case JsonExtractor.decode_with_extraction(json_string) do
      {:ok, %{"bug_report" => bug_report}} when is_binary(bug_report) and bug_report != "" ->
        model_id = Keyword.get(opts, :model_id, "unknown")
        log_opts = if path = Keyword.get(opts, :log_path), do: [path: path], else: []
        BugReportLogger.log(model_id, bug_report, log_opts)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end
end
