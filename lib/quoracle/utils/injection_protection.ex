defmodule Quoracle.Utils.InjectionProtection do
  @moduledoc """
  Prompt injection protection via NO_EXECUTE XML tags.

  Wraps untrusted content (shell output, web scraping, API responses, etc.)
  in <NO_EXECUTE_[random_id]>...</NO_EXECUTE_[random_id]> tags to prevent
  LLMs from executing embedded malicious instructions.

  Trusted actions (send_message, spawn_child, wait, orient, todo) are not wrapped
  since they contain agent-generated or framework-controlled content.
  """

  require Logger

  @untrusted_actions [
    :execute_shell,
    :fetch_web,
    :call_api,
    :call_mcp,
    :answer_engine
  ]

  @doc """
  Generates a random 8-character hexadecimal tag ID.

  Uses cryptographically strong random bytes for unpredictability.

  ## Examples

      iex> id = Quoracle.Utils.InjectionProtection.generate_tag_id()
      iex> String.length(id)
      8
      iex> String.match?(id, ~r/^[0-9a-f]{8}$/)
      true
  """
  @spec generate_tag_id() :: String.t()
  def generate_tag_id do
    :crypto.strong_rand_bytes(4)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Checks if an action type produces untrusted content requiring NO_EXECUTE wrapping.

  ## Untrusted actions (return true):
  - :execute_shell - Shell command output
  - :fetch_web - Scraped web content
  - :call_api - External API responses
  - :call_mcp - MCP tool responses
  - :answer_engine - Search results with citations

  ## Trusted actions (return false):
  - :send_message - Internal agent messages
  - :spawn_child - Spawn operation metadata
  - :wait - Timing information
  - :orient - Internal reflection
  - :todo - TODO list data
  - All other actions default to trusted (false)

  ## Examples

      iex> Quoracle.Utils.InjectionProtection.untrusted_action?(:execute_shell)
      true

      iex> Quoracle.Utils.InjectionProtection.untrusted_action?(:send_message)
      false
  """
  @spec untrusted_action?(atom()) :: boolean()
  def untrusted_action?(action) when action in @untrusted_actions, do: true
  def untrusted_action?(_action), do: false

  @doc """
  Unconditionally wraps content in NO_EXECUTE tags with a random ID.

  Use this for action results where unpredictability prevents spoofing.

  ## Examples

      iex> content = "shell output"
      iex> result = Quoracle.Utils.InjectionProtection.wrap_content(content)
      iex> String.contains?(result, "<NO_EXECUTE_")
      true
      iex> String.contains?(result, content)
      true
  """
  @spec wrap_content(String.t()) :: String.t()
  def wrap_content(content) do
    tag_id = generate_tag_id()
    "<NO_EXECUTE_#{tag_id}>\n#{content}\n</NO_EXECUTE_#{tag_id}>"
  end

  @doc """
  Wraps content in NO_EXECUTE tags with a deterministic content-based ID.

  Use this for system prompt content where consistency enables KV cache hits.
  The tag ID is derived from a SHA256 hash of the content, so identical content
  always produces identical tags.

  ## Examples

      iex> content = "profile docs"
      iex> result1 = Quoracle.Utils.InjectionProtection.wrap_content_deterministic(content)
      iex> result2 = Quoracle.Utils.InjectionProtection.wrap_content_deterministic(content)
      iex> result1 == result2
      true
      iex> String.contains?(result1, "<NO_EXECUTE_")
      true
  """
  @spec wrap_content_deterministic(String.t()) :: String.t()
  def wrap_content_deterministic(content) do
    tag_id = generate_deterministic_tag_id(content)
    "<NO_EXECUTE_#{tag_id}>\n#{content}\n</NO_EXECUTE_#{tag_id}>"
  end

  @doc """
  Generates a deterministic 8-character hex tag ID from content hash.

  Uses SHA256 hash of the content, taking the first 8 hex characters.
  Same content always produces the same ID.

  ## Examples

      iex> id1 = Quoracle.Utils.InjectionProtection.generate_deterministic_tag_id("test")
      iex> id2 = Quoracle.Utils.InjectionProtection.generate_deterministic_tag_id("test")
      iex> id1 == id2
      true
      iex> String.length(id1)
      8
  """
  @spec generate_deterministic_tag_id(String.t()) :: String.t()
  def generate_deterministic_tag_id(content) do
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 8)
  end

  @doc """
  Detects existing NO_EXECUTE tags in content (case-insensitive).

  Returns true if content contains any NO_EXECUTE tag patterns,
  which may indicate prompt injection attempts. Checks both uppercase
  and lowercase variants for more defensive security.

  ## Examples

      iex> Quoracle.Utils.InjectionProtection.detect_existing_tags("<NO_EXECUTE_abc123>bad</NO_EXECUTE_abc123>")
      true

      iex> Quoracle.Utils.InjectionProtection.detect_existing_tags("clean content")
      false
  """
  @spec detect_existing_tags(String.t()) :: boolean()
  def detect_existing_tags(content) do
    String.contains?(content, "NO_EXECUTE_") or String.contains?(content, "no_execute_")
  end

  @doc """
  Conditionally wraps content based on action type.

  If action is untrusted, wraps content in NO_EXECUTE tags.
  If action is trusted, returns content unchanged.

  Logs a warning if existing NO_EXECUTE tags are detected in the content.

  ## Examples

      iex> result = Quoracle.Utils.InjectionProtection.wrap_if_untrusted("output", :execute_shell)
      iex> String.contains?(result, "<NO_EXECUTE_")
      true

      iex> result = Quoracle.Utils.InjectionProtection.wrap_if_untrusted("message", :send_message)
      iex> result
      "message"
  """
  @spec wrap_if_untrusted(String.t(), atom()) :: String.t()
  def wrap_if_untrusted(content, action) do
    # Detect existing tags and log warning
    if detect_existing_tags(content) do
      Logger.warning(
        "NO_EXECUTE tag detected in content for action #{action} - possible injection attempt"
      )
    end

    # Wrap if untrusted, otherwise return as-is
    if untrusted_action?(action) do
      wrap_content(content)
    else
      content
    end
  end
end
