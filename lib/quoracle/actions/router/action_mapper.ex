defmodule Quoracle.Actions.Router.ActionMapper do
  @moduledoc """
  Maps action types to their implementation modules.

  This module handles the mapping between action type atoms and their
  corresponding action module implementations, checking if modules are loaded.
  """

  @doc """
  Gets the action module for a given action type.

  Returns {:ok, module} if the action is implemented and the module is loaded,
  or {:error, :not_implemented} if the action is not yet implemented.
  """
  @spec get_action_module(atom()) :: {:ok, module()} | {:error, :not_implemented}
  def get_action_module(action_type) do
    case Map.get(
           %{
             wait: Quoracle.Actions.Wait,
             orient: Quoracle.Actions.Orient,
             send_message: Quoracle.Actions.SendMessage,
             spawn_child: Quoracle.Actions.Spawn,
             todo: Quoracle.Actions.Todo,
             execute_shell: Quoracle.Actions.Shell,
             fetch_web: Quoracle.Actions.Web,
             answer_engine: Quoracle.Actions.AnswerEngine,
             generate_secret: Quoracle.Actions.GenerateSecret,
             call_api: Quoracle.Actions.API,
             call_mcp: Quoracle.Actions.MCP,
             search_secrets: Quoracle.Actions.SearchSecrets,
             dismiss_child: Quoracle.Actions.DismissChild,
             generate_images: Quoracle.Actions.GenerateImages,
             record_cost: Quoracle.Actions.RecordCost,
             adjust_budget: Quoracle.Actions.AdjustBudget,
             file_read: Quoracle.Actions.FileRead,
             file_write: Quoracle.Actions.FileWrite,
             learn_skills: Quoracle.Actions.LearnSkills,
             create_skill: Quoracle.Actions.CreateSkill,
             batch_sync: Quoracle.Actions.BatchSync,
             batch_async: Quoracle.Actions.BatchAsync
           },
           action_type
         ) do
      nil -> {:error, :not_implemented}
      mod -> if Code.ensure_loaded?(mod), do: {:ok, mod}, else: {:error, :not_implemented}
    end
  end
end
