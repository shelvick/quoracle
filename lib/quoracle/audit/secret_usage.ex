defmodule Quoracle.Audit.SecretUsage do
  @moduledoc """
  Audit logging for secret usage. Tracks which agents use which secrets
  in which actions for security monitoring and compliance.
  """

  import Ecto.Query
  alias Quoracle.Repo
  alias Quoracle.Models.TableSecretUsage

  @doc """
  Logs a secret usage event.

  ## Parameters
  - secret_name: Name of the secret used
  - agent_id: ID of the agent using the secret
  - action_type: Type of action (execute_shell, call_api, etc.)
  - task_id: Optional task context

  ## Returns
  - {:ok, usage} on success
  - {:error, changeset} on validation failure
  """
  @spec log_usage(String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, TableSecretUsage.t()} | {:error, Ecto.Changeset.t()}
  def log_usage(secret_name, agent_id, action_type, task_id) do
    attrs = %{
      secret_name: secret_name,
      agent_id: agent_id,
      action_type: action_type,
      task_id: task_id,
      accessed_at: DateTime.utc_now()
    }

    %TableSecretUsage{}
    |> TableSecretUsage.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Queries usage history for a specific secret.

  ## Parameters
  - secret_name: Name of the secret to query
  - opts: Query options (order, limit, offset, etc.)

  ## Returns
  {:ok, [usage]} list of usage records
  """
  @spec usage_by_secret(String.t(), keyword()) :: {:ok, [TableSecretUsage.t()]}
  def usage_by_secret(secret_name, opts \\ []) do
    order = Keyword.get(opts, :order, :asc)

    query =
      from(u in TableSecretUsage,
        where: u.secret_name == ^secret_name,
        order_by: [{^order, u.accessed_at}]
      )

    results = Repo.all(query)
    {:ok, results}
  end

  @doc """
  Queries all secrets used by a specific agent.

  ## Parameters
  - agent_id: ID of the agent to query
  - opts: Query options

  ## Returns
  {:ok, [usage]} list of usage records for that agent
  """
  @spec usage_by_agent(String.t(), keyword()) :: {:ok, [TableSecretUsage.t()]}
  def usage_by_agent(agent_id, _opts \\ []) do
    query =
      from(u in TableSecretUsage,
        where: u.agent_id == ^agent_id
      )

    results = Repo.all(query)
    {:ok, results}
  end

  @doc """
  Queries usage with various filters.

  ## Parameters
  - opts: Keyword list of filters
    - :secret_name - Filter by secret name
    - :agent_id - Filter by agent ID
    - :action_type - Filter by action type
    - :from - Start datetime
    - :to - End datetime
    - :limit - Maximum results
    - :offset - Pagination offset

  ## Returns
  {:ok, [usage]} list of usage records matching filters
  """
  @spec query_usage(keyword()) :: {:ok, [TableSecretUsage.t()]}
  def query_usage(opts \\ []) do
    query = from(u in TableSecretUsage)

    query =
      if secret_name = opts[:secret_name] do
        from(u in query, where: u.secret_name == ^secret_name)
      else
        query
      end

    query =
      if agent_id = opts[:agent_id] do
        from(u in query, where: u.agent_id == ^agent_id)
      else
        query
      end

    query =
      if action_type = opts[:action_type] do
        from(u in query, where: u.action_type == ^action_type)
      else
        query
      end

    query =
      if from_time = opts[:from] do
        from(u in query, where: u.accessed_at >= ^from_time)
      else
        query
      end

    query =
      if to_time = opts[:to] do
        from(u in query, where: u.accessed_at <= ^to_time)
      else
        query
      end

    query =
      if limit = opts[:limit] do
        from(u in query, limit: ^limit)
      else
        query
      end

    query =
      if offset = opts[:offset] do
        from(u in query, offset: ^offset)
      else
        query
      end

    results = Repo.all(query)
    {:ok, results}
  end

  @doc """
  Returns recent usage entries.

  ## Parameters
  - limit: Number of entries (integer) or time-based options
    - Integer: Returns last N entries
    - Keyword list with :hours - Returns entries from last N hours

  ## Returns
  {:ok, [usage]} most recent usage records
  """
  @spec recent_usage(integer() | keyword()) :: {:ok, [TableSecretUsage.t()]}
  def recent_usage(limit) when is_integer(limit) do
    query =
      from(u in TableSecretUsage,
        order_by: [desc: u.accessed_at],
        limit: ^limit
      )

    results = Repo.all(query)
    {:ok, results}
  end

  def recent_usage(opts) when is_list(opts) do
    if hours = opts[:hours] do
      cutoff = DateTime.add(DateTime.utc_now(), -hours, :hour)

      query =
        from(u in TableSecretUsage,
          where: u.accessed_at > ^cutoff,
          order_by: [desc: u.accessed_at]
        )

      results = Repo.all(query)
      {:ok, results}
    else
      {:ok, []}
    end
  end

  @doc """
  Removes audit logs older than the specified number of days.

  ## Parameters
  - days: Number of days to retain (logs older than this are deleted)

  ## Returns
  - {:ok, count} number of records deleted
  - {:error, reason} if days is invalid
  """
  @spec cleanup_old_logs(integer()) :: {:ok, integer()} | {:error, String.t()}
  def cleanup_old_logs(days) when days <= 0 do
    {:error, "Days must be positive"}
  end

  def cleanup_old_logs(days) do
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)

    {count, _} =
      from(u in TableSecretUsage, where: u.accessed_at < ^cutoff)
      |> Repo.delete_all()

    {:ok, count}
  end
end
