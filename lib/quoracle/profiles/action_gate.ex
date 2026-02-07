defmodule Quoracle.Profiles.ActionGate do
  @moduledoc """
  Runtime permission checker for action execution based on capability groups.
  Called by ACTION_Router before dispatching any action.

  ## Examples

      iex> ActionGate.check(:execute_shell, [:local_execution])
      :ok

      iex> ActionGate.check(:execute_shell, [])
      {:error, :action_not_allowed}
  """

  alias Quoracle.Profiles.ActionNotAllowedError
  alias Quoracle.Profiles.CapabilityGroups

  @doc """
  Checks if action is allowed for the given capability groups.

  ## Parameters
    - `action` - Action atom (e.g., :execute_shell, :spawn_child)
    - `capability_groups` - List of capability group atoms (e.g., [:hierarchy, :local_execution])

  ## Returns
    - `:ok` - Action is allowed
    - `{:error, :action_not_allowed}` - Action is blocked
  """
  @spec check(atom(), [atom()] | nil) :: :ok | {:error, :action_not_allowed}
  def check(_action, nil), do: :ok

  def check(action, capability_groups) when is_list(capability_groups) do
    if CapabilityGroups.action_allowed?(action, capability_groups) do
      :ok
    else
      {:error, :action_not_allowed}
    end
  end

  def check(_action, _invalid), do: {:error, :action_not_allowed}

  @doc """
  Bang version that raises `ActionNotAllowedError` if blocked.
  """
  @spec check!(atom(), [atom()] | nil) :: :ok
  def check!(_action, nil), do: :ok

  def check!(action, capability_groups) when is_list(capability_groups) do
    case check(action, capability_groups) do
      :ok ->
        :ok

      {:error, :action_not_allowed} ->
        raise ActionNotAllowedError, action: action, capability_groups: capability_groups
    end
  end

  @doc """
  Filters a list of actions to only those allowed by the capability groups.
  Used by PromptBuilder to filter schemas before injection.
  """
  @spec filter_actions([atom()], [atom()] | nil) :: [atom()]
  def filter_actions(actions, nil), do: actions

  def filter_actions(actions, capability_groups) when is_list(capability_groups) do
    Enum.filter(actions, &CapabilityGroups.action_allowed?(&1, capability_groups))
  end

  def filter_actions(actions, _invalid), do: actions
end
