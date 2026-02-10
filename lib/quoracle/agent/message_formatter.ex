defmodule Quoracle.Agent.MessageFormatter do
  @moduledoc """
  Formats messages for LLM consumption.
  Extracted from MessageHandler to keep it under 500 lines.
  """

  alias Quoracle.Utils.JSONNormalizer

  @doc """
  Format batched messages as XML for LLM consumption.
  Maintains chronological order with clear attribution.
  """
  @spec format_batch_message([any()]) :: String.t()
  def format_batch_message([]), do: ""

  def format_batch_message(messages) do
    Enum.map_join(messages, "\n", &format_single_message/1)
  end

  @doc """
  Format a single message for LLM consumption.
  """
  @spec format_single_message(any()) :: String.t()
  def format_single_message({:action_result, action_id, result}) do
    """
    <action_result id="#{action_id}" from="system">
    #{JSONNormalizer.normalize(result)}
    </action_result>
    """
  end

  def format_single_message({:agent_message, from, content}) do
    from_attr =
      case from do
        :parent -> "parent"
        :child -> "child"
        pid when is_pid(pid) -> "agent_#{inspect(pid)}"
        _ -> "unknown"
      end

    """
    <agent_message from="#{from_attr}">
    #{content}
    </agent_message>
    """
  end

  def format_single_message({:user_message, content}) do
    content
  end

  def format_single_message({:system_event, type, data}) do
    """
    <system_event type="#{type}">
    #{JSONNormalizer.normalize(data)}
    </system_event>
    """
  end

  def format_single_message({:wait_timeout, timer_id}) do
    """
    <wait_timeout timer_id="#{timer_id}" from="system">
    Timer expired
    </wait_timeout>
    """
  end

  def format_single_message(other) do
    """
    <unknown_message>
    #{JSONNormalizer.normalize(other)}
    </unknown_message>
    """
  end
end
