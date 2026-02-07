defmodule Quoracle.Actions.RouterSpawnTest do
  @moduledoc """
  Tests for Router integration with Spawn action via execute/5 path.
  Verifies that spawn_child routes through ActionMapper to Spawn module.

  Note: These tests verify routing only, not full spawn execution.
  Full spawn integration is tested in integration/spawn_test.exs.
  """

  use ExUnit.Case, async: true
  alias Quoracle.Actions.Router

  setup do
    pubsub_name = :"test_pubsub_#{System.unique_integer([:positive])}"
    {:ok, _pubsub} = start_supervised({Phoenix.PubSub, name: pubsub_name})

    agent_id = "test-agent-#{System.unique_integer([:positive])}"

    # Per-action Router (v28.0) - use :spawn_child for spawn tests
    {:ok, router} =
      Router.start_link(
        action_type: :spawn_child,
        action_id: "action-#{System.unique_integer([:positive])}",
        agent_id: agent_id,
        agent_pid: self(),
        pubsub: pubsub_name
      )

    # Ensure router terminates before sandbox owner exits
    on_exit(fn ->
      if Process.alive?(router) do
        try do
          GenServer.stop(router, :normal, :infinity)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    {:ok, router: router, pubsub: pubsub_name, agent_id: agent_id}
  end

  describe "Router dispatch to Spawn module via ActionMapper" do
    test "ActionMapper recognizes :spawn_child action", %{router: _router} do
      # This test verifies the bug fix: ActionMapper now includes spawn_child mapping
      alias Quoracle.Actions.Router.ActionMapper

      # After the fix, ActionMapper should return the Spawn module
      assert {:ok, Quoracle.Actions.Spawn} = ActionMapper.get_action_module(:spawn_child)
    end

    test "validates spawn_child parameters through Schema before dispatch", %{
      router: router,
      pubsub: pubsub
    } do
      # Missing required :task parameter
      params = %{}
      agent_id = "parent-#{System.unique_integer([:positive])}"

      opts = [
        pubsub: pubsub,
        agent_pid: self()
      ]

      # Should fail validation before reaching Spawn module
      result = Router.execute(router, :spawn_child, params, agent_id, opts)

      assert {:error, _reason} = result
    end

    test "validates spawn_child with invalid task parameter type", %{
      router: router,
      pubsub: pubsub
    } do
      # Task must be a string, not an integer
      params = %{task: 12345}
      agent_id = "parent-#{System.unique_integer([:positive])}"

      opts = [
        pubsub: pubsub,
        agent_pid: self()
      ]

      result = Router.execute(router, :spawn_child, params, agent_id, opts)

      # Should return validation error before reaching Spawn module
      assert {:error, _reason} = result
    end
  end
end
