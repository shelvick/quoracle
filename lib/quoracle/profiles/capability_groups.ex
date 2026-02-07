defmodule Quoracle.Profiles.CapabilityGroups do
  @moduledoc """
  Pure module defining 5 selectable capability groups and their associated actions.
  Replaces the fixed 5-level autonomy system with user-selectable capability checkboxes.
  This is the single source of truth for what actions each capability group enables.
  """

  @always_allowed [
    :wait,
    :orient,
    :todo,
    :send_message,
    :fetch_web,
    :answer_engine,
    :generate_images,
    :learn_skills,
    :create_skill,
    :batch_sync,
    :batch_async
  ]

  @hierarchy_actions [:spawn_child, :dismiss_child, :adjust_budget]

  @local_execution_actions [
    :execute_shell,
    :call_mcp,
    :record_cost,
    :search_secrets,
    :generate_secret
  ]

  @file_read_actions [:file_read]

  @file_write_actions [:file_write, :search_secrets, :generate_secret]

  @external_api_actions [:call_api, :record_cost, :search_secrets, :generate_secret]

  @valid_groups [:file_read, :file_write, :external_api, :hierarchy, :local_execution]

  @group_descriptions %{
    file_read: "Read files from the filesystem",
    file_write: "Write and edit files on the filesystem",
    external_api: "Make HTTP requests to external APIs",
    hierarchy: "Spawn and manage child agents",
    local_execution: "Execute shell commands and MCP calls"
  }

  @doc "Returns the list of all valid capability group atoms in display order."
  @spec groups() :: [atom()]
  def groups do
    @valid_groups
  end

  @doc "Returns the actions enabled by a specific capability group."
  @spec group_actions(atom()) :: {:ok, [atom()]} | {:error, :invalid_group}
  def group_actions(:file_read), do: {:ok, @file_read_actions}
  def group_actions(:file_write), do: {:ok, @file_write_actions}
  def group_actions(:external_api), do: {:ok, @external_api_actions}
  def group_actions(:hierarchy), do: {:ok, @hierarchy_actions}
  def group_actions(:local_execution), do: {:ok, @local_execution_actions}
  def group_actions(_invalid), do: {:error, :invalid_group}

  @doc "Returns all allowed actions for a list of capability groups (base + group-specific)."
  @spec allowed_actions_for_groups([atom()]) :: {:ok, [atom()]} | {:error, :invalid_group}
  def allowed_actions_for_groups(capability_groups) when is_list(capability_groups) do
    with :ok <- validate_groups(capability_groups) do
      group_actions_list =
        capability_groups
        |> Enum.flat_map(fn group ->
          {:ok, actions} = group_actions(group)
          actions
        end)

      all_actions = @always_allowed ++ group_actions_list
      {:ok, Enum.uniq(all_actions)}
    end
  end

  def allowed_actions_for_groups(_), do: {:error, :invalid_group}

  @doc "Returns true if the action is allowed for the given capability groups."
  @spec action_allowed?(atom(), [atom()]) :: boolean()
  def action_allowed?(action, capability_groups) when is_list(capability_groups) do
    case allowed_actions_for_groups(capability_groups) do
      {:ok, allowed} -> action in allowed
      {:error, _} -> false
    end
  end

  def action_allowed?(_action, _), do: false

  @doc "Returns the human-readable description of a capability group."
  @spec get_group_description(atom()) :: {:ok, String.t()} | {:error, :invalid_group}
  def get_group_description(group) when is_map_key(@group_descriptions, group) do
    {:ok, Map.fetch!(@group_descriptions, group)}
  end

  def get_group_description(_invalid), do: {:error, :invalid_group}

  @doc "Returns the base actions that are always allowed regardless of capability groups."
  @spec base_actions() :: [atom()]
  def base_actions, do: @always_allowed

  # Private helpers

  defp validate_groups(groups) do
    if Enum.all?(groups, &(&1 in @valid_groups)) do
      :ok
    else
      {:error, :invalid_group}
    end
  end
end
