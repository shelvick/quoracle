defmodule Quoracle.Actions.Router.Security do
  @moduledoc """
  Secret resolution and output scrubbing for action execution.

  Integrates with SECURITY_SecretResolver to replace {{SECRET:name}} templates
  in action parameters and SECURITY_OutputScrubber to remove secret values
  from action results before they reach LLMs.
  """

  alias Quoracle.Security.{SecretResolver, OutputScrubber}

  @doc """
  Resolves secret templates in action parameters.

  Replaces {{SECRET:name}} templates with actual secret values.
  Returns resolved params and map of secret names to values for audit/scrubbing.

  Missing secrets are left as literal text and a warning is logged.
  This allows example syntax like {{SECRET:example}} without causing errors.

  ## Examples

      iex> params = %{"token" => "{{SECRET:github_token}}"}
      iex> resolve_secrets(params)
      {:ok, %{"token" => "actual_secret_value"}, %{"github_token" => "actual_secret_value"}}

      iex> params = %{"key" => "{{SECRET:missing}}"}
      iex> resolve_secrets(params)
      # Logs warning, keeps literal
      {:ok, %{"key" => "{{SECRET:missing}}"}, %{}}
  """
  @spec resolve_secrets(map()) :: {:ok, map(), %{String.t() => String.t()}}
  def resolve_secrets(params) do
    SecretResolver.resolve_params(params)
  end

  @doc """
  Scrubs secret values from action results.

  Removes any occurrence of secret values from the result to prevent
  exposing them to LLMs in action_result messages.

  ## Examples

      iex> result = %{output: "Token: abc123"}
      iex> scrub_output(result, %{"github_token" => "abc123"})
      %{output: "Token: [REDACTED]"}
  """
  @spec scrub_output(any(), %{String.t() => String.t()}) :: any()
  def scrub_output(result, secrets_used) do
    OutputScrubber.scrub_result(result, secrets_used)
  end
end
