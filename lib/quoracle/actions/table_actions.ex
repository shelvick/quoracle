defmodule Quoracle.Actions.TableActions do
  @moduledoc """
  Schema for action execution audit trail.
  Stores complete parameters and results for all agent actions.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, warn: false
  alias Quoracle.Repo
  alias Quoracle.Actions.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # Import action types from single source of truth
  @action_types Schema.list_actions() |> Enum.map(&to_string/1)
  @statuses ~w(pending running completed failed)

  schema "actions" do
    field(:agent_id, :binary_id)
    field(:action_type, :string)
    field(:params, :map)
    field(:reasoning, :string)
    field(:result, :map)
    field(:status, :string)
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
    field(:error_message, :string)
    belongs_to(:parent_action, __MODULE__)

    timestamps()
  end

  @doc """
  Creates a changeset for the action.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(action, attrs) do
    action
    |> cast(attrs, [
      :agent_id,
      :action_type,
      :params,
      :reasoning,
      :result,
      :status,
      :started_at,
      :completed_at,
      :error_message,
      :parent_action_id
    ])
    |> validate_required([:agent_id, :action_type, :params, :status, :started_at])
    |> validate_inclusion(:action_type, @action_types)
    |> validate_inclusion(:status, @statuses)
    |> validate_uuid(:agent_id)
    |> validate_uuid(:parent_action_id)
    |> validate_completion_time()
    |> validate_status_requirements()
    |> validate_status_transition()
  end

  defp validate_uuid(changeset, field) do
    validate_change(changeset, field, fn _, value ->
      case value do
        nil ->
          []

        _ ->
          case Ecto.UUID.cast(value) do
            {:ok, _} -> []
            :error -> [{field, "is invalid"}]
          end
      end
    end)
  end

  defp validate_completion_time(changeset) do
    started = get_change(changeset, :started_at) || get_field(changeset, :started_at)
    completed = get_change(changeset, :completed_at)

    if started && completed do
      case DateTime.compare(completed, started) do
        :lt -> add_error(changeset, :completed_at, "must be after started_at")
        _ -> changeset
      end
    else
      changeset
    end
  end

  defp validate_status_requirements(changeset) do
    status = get_change(changeset, :status) || get_field(changeset, :status)

    changeset
    |> validate_error_message_for_failed(status)
    |> validate_completed_at_for_final_status(status)
  end

  defp validate_error_message_for_failed(changeset, "failed") do
    if get_field(changeset, :error_message) == nil do
      add_error(changeset, :error_message, "can't be blank when status is failed")
    else
      changeset
    end
  end

  defp validate_error_message_for_failed(changeset, _), do: changeset

  defp validate_completed_at_for_final_status(changeset, status)
       when status in ["completed", "failed"] do
    if get_field(changeset, :completed_at) == nil do
      add_error(changeset, :completed_at, "can't be blank when status is #{status}")
    else
      changeset
    end
  end

  defp validate_completed_at_for_final_status(changeset, _), do: changeset

  defp validate_status_transition(changeset) do
    # Only validate if we're actually changing the status
    new_status = get_change(changeset, :status)

    if new_status do
      old_status = changeset.data.status

      case {old_status, new_status} do
        # Initial status can be anything
        {nil, _} -> changeset
        # Valid transitions
        {"pending", status} when status in ["running", "failed"] -> changeset
        {"running", status} when status in ["completed", "failed"] -> changeset
        # Invalid transitions
        {"running", "pending"} -> add_error(changeset, :status, "invalid status transition")
        {"completed", _} -> add_error(changeset, :status, "invalid status transition")
        {"failed", _} -> add_error(changeset, :status, "invalid status transition")
        # Same status is ok
        {same, same} -> changeset
        # Default to allowing the transition
        _ -> changeset
      end
    else
      changeset
    end
  end

  @doc """
  Creates an action with the given attributes.
  """
  @spec create_action(map()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def create_action(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an action with the given attributes.
  """
  @spec update_action(struct(), map()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def update_action(action, attrs) do
    action
    |> changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Gets an action by ID.
  """
  @spec get_action(binary(), keyword()) :: struct() | nil
  def get_action(id, opts \\ []) do
    query = from(a in __MODULE__, where: a.id == ^id)

    query =
      case Keyword.get(opts, :preload) do
        nil -> query
        preloads -> from(a in query, preload: ^preloads)
      end

    Repo.one(query)
  end

  @doc """
  Deletes an action.
  """
  @spec delete_action(struct()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def delete_action(action) do
    # Check for child actions
    child_count =
      from(a in __MODULE__, where: a.parent_action_id == ^action.id)
      |> Repo.aggregate(:count, :id)

    if child_count > 0 do
      changeset =
        action
        |> change()
        |> add_error(:base, "has child actions")

      {:error, changeset}
    else
      Repo.delete(action)
    end
  end

  @doc """
  Lists actions for a specific agent.
  """
  @spec list_actions_for_agent(binary(), keyword()) :: [struct()]
  def list_actions_for_agent(agent_id, opts \\ []) do
    query =
      from(a in __MODULE__,
        where: a.agent_id == ^agent_id,
        order_by: [desc: a.started_at]
      )

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> from(a in query, where: a.status == ^status)
      end

    query =
      case Keyword.get(opts, :limit) do
        nil -> query
        limit -> from(a in query, limit: ^limit)
      end

    Repo.all(query)
  end

  @doc """
  Lists failed actions within a time window.
  """
  @spec list_failed_actions(keyword()) :: [struct()]
  def list_failed_actions(opts \\ []) do
    query = from(a in __MODULE__, where: a.status == "failed")

    query =
      case Keyword.get(opts, :hours) do
        nil ->
          query

        hours ->
          cutoff = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)
          from(a in query, where: a.started_at > ^cutoff)
      end

    Repo.all(query)
  end

  @doc """
  Lists child actions for a parent action.
  """
  @spec list_child_actions(binary(), keyword()) :: [struct()]
  def list_child_actions(parent_id, opts \\ []) do
    query = from(a in __MODULE__, where: a.parent_action_id == ^parent_id)

    query =
      case Keyword.get(opts, :preload) do
        nil -> query
        preloads -> from(a in query, preload: ^preloads)
      end

    Repo.all(query)
  end

  @doc """
  Counts actions by status for an agent.
  """
  @spec count_actions_by_status(binary()) :: map()
  def count_actions_by_status(agent_id) do
    counts =
      from(a in __MODULE__,
        where: a.agent_id == ^agent_id,
        group_by: a.status,
        select: {a.status, count(a.id)}
      )
      |> Repo.all()
      |> Map.new()

    # Ensure all statuses are present
    %{
      "pending" => Map.get(counts, "pending", 0),
      "running" => Map.get(counts, "running", 0),
      "completed" => Map.get(counts, "completed", 0),
      "failed" => Map.get(counts, "failed", 0)
    }
  end
end
