defmodule Quoracle.Messages.Queries do
  @moduledoc """
  Query helpers for the messages table.
  """

  import Ecto.Query
  alias Quoracle.Messages.Message

  @doc """
  Get messages sent to an agent (inbox).
  """
  @spec inbox(String.t(), integer()) :: Ecto.Query.t()
  def inbox(to_agent_id, limit \\ 50) do
    from(m in Message,
      where: m.to_agent_id == ^to_agent_id,
      order_by: [desc: m.inserted_at],
      limit: ^limit
    )
  end

  @doc """
  Get messages sent by an agent (outbox).
  """
  @spec outbox(String.t(), integer()) :: Ecto.Query.t()
  def outbox(from_agent_id, limit \\ 50) do
    from(m in Message,
      where: m.from_agent_id == ^from_agent_id,
      order_by: [desc: m.inserted_at],
      limit: ^limit
    )
  end

  @doc """
  Get conversation between two agents.
  """
  @spec conversation(String.t(), String.t()) :: Ecto.Query.t()
  def conversation(agent_id_1, agent_id_2) do
    from(m in Message,
      where:
        (m.from_agent_id == ^agent_id_1 and m.to_agent_id == ^agent_id_2) or
          (m.from_agent_id == ^agent_id_2 and m.to_agent_id == ^agent_id_1),
      order_by: [asc: m.inserted_at]
    )
  end

  @doc """
  Get all messages for a task.
  """
  @spec for_task(Ecto.UUID.t()) :: Ecto.Query.t()
  def for_task(task_id) do
    from(m in Message,
      where: m.task_id == ^task_id,
      order_by: [asc: m.inserted_at]
    )
  end

  @doc """
  Get unread messages for an agent.
  """
  @spec unread(String.t()) :: Ecto.Query.t()
  def unread(to_agent_id) do
    from(m in Message,
      where: m.to_agent_id == ^to_agent_id and is_nil(m.read_at),
      order_by: [asc: m.inserted_at]
    )
  end

  @doc """
  Count messages sent by an agent.
  """
  @spec count_sent(String.t()) :: Ecto.Query.t()
  def count_sent(from_agent_id) do
    from(m in Message,
      where: m.from_agent_id == ^from_agent_id,
      select: count(m.id)
    )
  end
end
