defmodule Quoracle.Agent.WaitTimerRouterBugTest do
  @moduledoc """
  Test proving the wait timer bug: timer goes to ephemeral Router instead of Agent.

  ## The Bug

  In Router.ex lines 241-247, for :wait actions, the Router overrides `agent_pid`
  to be `self()` (the Router process). This means `Process.send_after(caller, ...)`
  sends the timer message to the Router.

  But per-action Routers (v28.0) terminate after the action completes. When the
  timer fires (e.g., 15 minutes later), the Router is dead and the message is lost.

  ## Expected Behavior

  The timer message `{:wait_expired, timer_ref}` should go to the Agent process,
  which has the `handle_wait_expired` handler to trigger consensus continuation.
  """
  use Quoracle.DataCase, async: true

  import Test.IsolationHelpers

  @moduletag :acceptance

  describe "wait timer delivery bug" do
    setup do
      deps = create_isolated_deps()
      {:ok, deps: deps}
    end

    test "Wait.execute sends timer to agent_pid from opts", %{deps: deps} do
      # This test verifies that Wait.execute sends the timer to the correct process.
      # The bug is that Router overrides agent_pid, but we can test Wait.execute directly.

      # We are the "agent" - we should receive the timer
      agent_pid = self()

      # 10ms timer
      params = %{wait: 0.01}
      agent_id = "test-agent-#{System.unique_integer([:positive])}"
      opts = [pubsub: deps.pubsub, agent_pid: agent_pid]

      # Execute wait action directly
      {:ok, result} = Quoracle.Actions.Wait.execute(params, agent_id, opts)

      assert is_reference(result.timer_id)
      timer_ref = result.timer_id

      # We should receive the timer message since we passed ourselves as agent_pid
      assert_receive {:wait_expired, ^timer_ref}, 5000, "Timer message should arrive at agent_pid"
    end

    test "Router overrides agent_pid for wait actions - BUG", %{deps: deps} do
      # This test demonstrates the bug: Router replaces agent_pid with self()
      # for wait actions, causing the timer to go to the Router (which dies).

      # We are the "agent" that SHOULD receive the timer
      agent_pid = self()
      agent_id = "test-agent-#{System.unique_integer([:positive])}"

      # Start a per-action Router for :wait
      {:ok, router_pid} =
        Quoracle.Actions.Router.start_link(
          action_type: :wait,
          action_id: "action_#{System.unique_integer([:positive])}",
          agent_id: agent_id,
          agent_pid: agent_pid,
          pubsub: deps.pubsub,
          sandbox_owner: nil
        )

      # Execute wait through Router
      # 10ms timer
      params = %{wait: 0.01}
      opts = [pubsub: deps.pubsub, agent_pid: agent_pid]

      {:ok, result} =
        Quoracle.Actions.Router.execute(router_pid, :wait, params, agent_id, opts)

      assert is_reference(result.timer_id)
      timer_ref = result.timer_id

      # EXPECTED: Timer should arrive at agent_pid (us), not the dead Router.
      # This will FAIL until the bug is fixed.
      assert_receive {:wait_expired, ^timer_ref}, 5000, """
      BUG CONFIRMED: Timer went to dead Router!

      The Router overrides agent_pid to self() for :wait actions.
      The timer was sent to the Router, which terminated after
      the action completed. The timer message was lost.

      Fix: Remove agent_pid override in Router.ex lines 241-247
      """
    end
  end
end
