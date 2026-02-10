defmodule Test.RouterTestHelpers do
  @moduledoc """
  Test helpers for per-action Router spawning (v28.0 pattern).

  Per-action Router requires: action_type, action_id, agent_id, agent_pid, pubsub

  ## Usage

      import Test.RouterTestHelpers

      setup do
        pubsub = start_test_pubsub()
        %{pubsub: pubsub}
      end

      test "my test", %{pubsub: pubsub} do
        router = spawn_router(:call_api, pubsub: pubsub)
        # Router will auto-cleanup when test process exits
      end
  """

  alias Quoracle.Actions.Router

  @doc """
  Spawns a per-action Router with the given action type.

  ## Options
    * `:pubsub` - Required. PubSub instance name
    * `:agent_id` - Agent ID (default: auto-generated)
    * `:agent_pid` - Agent PID to monitor (default: test process)
    * `:action_id` - Action ID (default: auto-generated)
    * `:sandbox_owner` - Ecto sandbox owner (default: nil)

  ## Returns
    Router PID
  """
  @spec spawn_router(atom(), keyword()) :: pid()
  def spawn_router(action_type, opts) do
    pubsub = Keyword.fetch!(opts, :pubsub)
    agent_pid = Keyword.get(opts, :agent_pid, self())
    agent_id = Keyword.get(opts, :agent_id, "test-agent-#{System.unique_integer([:positive])}")
    action_id = Keyword.get(opts, :action_id, "action-#{System.unique_integer([:positive])}")
    sandbox_owner = Keyword.get(opts, :sandbox_owner)

    router_opts = [
      action_type: action_type,
      action_id: action_id,
      agent_id: agent_id,
      agent_pid: agent_pid,
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    ]

    {:ok, router_pid} = Router.start_link(router_opts)

    # Register cleanup - Router will terminate when test process exits (monitored),
    # but explicit cleanup ensures no leaks
    test_pid = self()

    spawn(fn ->
      ref = Process.monitor(test_pid)

      receive do
        {:DOWN, ^ref, :process, ^test_pid, _reason} ->
          if Process.alive?(router_pid) do
            try do
              GenServer.stop(router_pid, :normal, :infinity)
            catch
              :exit, _ -> :ok
            end
          end
      end
    end)

    router_pid
  end

  @doc """
  Starts an isolated PubSub for testing.
  Returns the PubSub name (atom).
  """
  @spec start_test_pubsub() :: atom()
  def start_test_pubsub do
    pubsub = :"test_pubsub_#{System.unique_integer([:positive])}"
    {:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: pubsub)
    pubsub
  end
end
