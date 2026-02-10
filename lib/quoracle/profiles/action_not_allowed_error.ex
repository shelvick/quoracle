defmodule Quoracle.Profiles.ActionNotAllowedError do
  @moduledoc """
  Exception raised when an action is blocked by the agent's capability groups.
  """

  defexception [:action, :capability_groups]

  @impl true
  def message(%{action: action, capability_groups: groups}) when is_list(groups) do
    group_str = Enum.map_join(groups, ", ", &to_string/1)
    "Action #{action} is not allowed for capability groups [#{group_str}]"
  end
end
