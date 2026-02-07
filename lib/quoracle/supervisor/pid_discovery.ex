defmodule Quoracle.Supervisor.PidDiscovery do
  @moduledoc """
  Utility module for discovering PIDs of supervised children.

  Consolidates the PID discovery pattern used across multiple modules
  to avoid code duplication and standardize error handling.
  """

  @doc """
  Finds the PID of a child process by its module name.

  Returns the PID if found, or nil if not found.

  ## Examples

      iex> find_child_pid(Quoracle.Agent.DynSup)
      #PID<0.123.0>

      iex> find_child_pid(NonExistentModule)
      nil
  """
  @spec find_child_pid(module()) :: pid() | nil
  def find_child_pid(child_module) do
    case Process.whereis(Quoracle.Supervisor) do
      nil ->
        nil

      sup_pid ->
        children = Supervisor.which_children(sup_pid)

        case Enum.find(children, fn
               {^child_module, _, _, _} -> true
               _ -> false
             end) do
          {_, pid, _, _} when is_pid(pid) -> pid
          _ -> nil
        end
    end
  end

  @doc """
  Finds the PID of a child process by its module name.

  Raises an exception if the supervisor or child is not found.

  ## Examples

      iex> find_child_pid!(Quoracle.Agent.DynSup)
      #PID<0.123.0>

      iex> find_child_pid!(NonExistentModule)
      ** (RuntimeError) Child NonExistentModule not found under Quoracle.Supervisor
  """
  @spec find_child_pid!(module()) :: pid()
  def find_child_pid!(child_module) do
    case find_child_pid(child_module) do
      nil ->
        raise "Child #{inspect(child_module)} not found under Quoracle.Supervisor"

      pid ->
        pid
    end
  end
end
