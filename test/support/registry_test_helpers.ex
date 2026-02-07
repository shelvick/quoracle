defmodule Test.RegistryTestHelpers do
  @moduledoc """
  Test helpers for Registry async cleanup. Registry cleanup is asynchronous (processes :DOWN
  message in its own time). These helpers poll until cleanup completes to avoid race conditions.
  """

  import ExUnit.Assertions

  @doc """
  Waits for Registry cleanup after process termination. Polls until Registry.lookup returns [].
  Accepts single agent_id or list. Default timeout: 5000ms.
  """
  @spec wait_for_registry_cleanup(Registry.registry(), String.t() | [String.t()], integer()) ::
          :ok
  def wait_for_registry_cleanup(registry, agent_ids, timeout \\ 5000)

  def wait_for_registry_cleanup(registry, agent_ids, timeout) when is_list(agent_ids) do
    Enum.each(agent_ids, &wait_for_registry_cleanup(registry, &1, timeout))
  end

  def wait_for_registry_cleanup(registry, agent_id, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_registry_cleanup(registry, agent_id, deadline, timeout)
  end

  defp poll_registry_cleanup(registry, agent_id, deadline, timeout) do
    case Registry.lookup(registry, {:agent, agent_id}) do
      [] ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          # Yield to allow Registry process to handle :DOWN message
          Enum.each(1..5, fn _ -> :erlang.yield() end)
          poll_registry_cleanup(registry, agent_id, deadline, timeout)
        else
          flunk("Timeout: Agent #{agent_id} still in Registry after #{timeout}ms")
        end
    end
  end
end
