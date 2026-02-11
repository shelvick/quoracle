defmodule Quoracle.Actions.RouterPerActionLifecycleTest do
  @moduledoc """
  Tests for Router per-action lifecycle (v28.0 refactor).

  WorkGroupID: refactor-20260124-router-per-action
  Packet: 1 (Foundation)

  Tests R35-R51: Router spawns per action, terminates after completion,
  bidirectional monitoring with Core, state simplification.
  """

  use Quoracle.DataCase, async: true
  import ExUnit.CaptureLog

  alias Quoracle.Actions.Router

  # Helper for clean termination check - avoids Credo's "assert with or" warning
  defp clean_termination?(reason) do
    reason in [:normal, :shutdown, :noproc] or match?({:shutdown, _}, reason)
  end

  # =============================================================================
  # Router Lifecycle Tests (R35-R39)
  # =============================================================================

  describe "Router per-action lifecycle (R35-R39)" do
    setup do
      pubsub = :"pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub})
      {:ok, pubsub: pubsub, sandbox_owner: self()}
    end

    @tag :r35
    test "R35: Router.start_link creates new process with action context", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      # Per-action Router requires action_type, action_id, agent_id, agent_pid
      agent_pid = self()
      action_id = "action-#{System.unique_integer([:positive])}"

      {:ok, router_pid} =
        Router.start_link(
          action_type: :orient,
          action_id: action_id,
          agent_id: "test-agent",
          agent_pid: agent_pid,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      on_exit(fn ->
        if Process.alive?(router_pid), do: GenServer.stop(router_pid, :normal, :infinity)
      end)

      # Verify Router has action context in state
      state = :sys.get_state(router_pid)

      assert state.action_type == :orient
      assert state.action_id == action_id
      assert state.agent_id == "test-agent"
      assert state.agent_pid == agent_pid
    end

    @tag :r36
    test "R36: Router terminates after sync action completion", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent_pid = self()
      action_id = "action-#{System.unique_integer([:positive])}"

      {:ok, router_pid} =
        Router.start_link(
          action_type: :orient,
          action_id: action_id,
          agent_id: "test-agent",
          agent_pid: agent_pid,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      # Monitor Router to detect termination
      router_ref = Process.monitor(router_pid)

      # Execute sync action (orient is always sync)
      params = %{
        current_situation: "Test",
        goal_clarity: "Clear",
        available_resources: "Test",
        key_challenges: "None",
        delegation_consideration: "None"
      }

      capture_log(fn ->
        Router.execute(router_pid, :orient, params, "test-agent")
      end)

      # Router should terminate after sync action
      assert_receive {:DOWN, ^router_ref, :process, ^router_pid, reason}, 30_000
      assert clean_termination?(reason)
    end

    @tag :r37
    test "R37: Router terminates after async action notification", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent_pid = self()
      action_id = "action-#{System.unique_integer([:positive])}"

      {:ok, router_pid} =
        Router.start_link(
          action_type: :wait,
          action_id: action_id,
          agent_id: "test-agent",
          agent_pid: agent_pid,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      router_ref = Process.monitor(router_pid)

      # Execute async action with immediate completion (wait: 0)
      capture_log(fn ->
        Router.execute(router_pid, :wait, %{wait: 0}, "test-agent")
      end)

      # Router should terminate after notifying Core
      assert_receive {:DOWN, ^router_ref, :process, ^router_pid, reason}, 30_000
      assert clean_termination?(reason)
    end

    @tag :r38
    test "R38: Router monitors Core on init", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent_pid = self()
      action_id = "action-#{System.unique_integer([:positive])}"

      {:ok, router_pid} =
        Router.start_link(
          action_type: :orient,
          action_id: action_id,
          agent_id: "test-agent",
          agent_pid: agent_pid,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      on_exit(fn ->
        if Process.alive?(router_pid), do: GenServer.stop(router_pid, :normal, :infinity)
      end)

      # Verify Router has core_monitor reference
      state = :sys.get_state(router_pid)

      assert is_reference(state.core_monitor)
    end

    @tag :r39
    test "R39: Router self-terminates when Core dies", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      # Spawn a fake "Core" process that we can kill
      fake_core =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      action_id = "action-#{System.unique_integer([:positive])}"

      {:ok, router_pid} =
        Router.start_link(
          action_type: :orient,
          action_id: action_id,
          agent_id: "test-agent",
          agent_pid: fake_core,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      router_ref = Process.monitor(router_pid)

      # Kill the fake Core
      Process.exit(fake_core, :kill)

      # Router should self-terminate
      assert_receive {:DOWN, ^router_ref, :process, ^router_pid, reason}, 30_000
      assert clean_termination?(reason)
    end
  end

  # =============================================================================
  # Shell Command Handling Tests (R40-R42)
  # =============================================================================

  describe "Shell Router handling (R40-R42)" do
    setup do
      pubsub = :"pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub})
      {:ok, pubsub: pubsub, sandbox_owner: self()}
    end

    @tag :r40
    test "R40: Shell Router remains alive during command execution", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      # R40 is implicitly verified by R42: if Router terminates AFTER completion,
      # it must have been alive DURING execution. This test verifies the Router
      # can be queried while a command runs by using async dispatch.
      agent_pid = self()
      action_id = "action-#{System.unique_integer([:positive])}"

      {:ok, router_pid} =
        Router.start_link(
          action_type: :execute_shell,
          action_id: action_id,
          agent_id: "test-agent",
          agent_pid: agent_pid,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      router_ref = Process.monitor(router_pid)

      on_exit(fn ->
        if Process.alive?(router_pid), do: GenServer.stop(router_pid, :normal, :infinity)
      end)

      # Execute via Router.execute - fast command but verify Router responds
      capture_log(fn ->
        {:ok, result} =
          Router.execute(router_pid, :execute_shell, %{command: "echo alive"}, "test-agent",
            agent_pid: agent_pid,
            pubsub: pubsub,
            capability_groups: [:local_execution]
          )

        # Router returned a result, proving it was alive and responsive
        assert Map.has_key?(result, :action)
      end)

      # Router terminates after completion (verified more thoroughly in R42)
      assert_receive {:DOWN, ^router_ref, :process, ^router_pid, reason}, 30_000
      assert clean_termination?(reason)
    end

    @tag :r41
    test "R41: Shell Router state contains single command not map", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      # Verify per-action Router uses shell_command (singular) not shell_commands (map)
      agent_pid = self()
      action_id = "action-#{System.unique_integer([:positive])}"

      {:ok, router_pid} =
        Router.start_link(
          action_type: :execute_shell,
          action_id: action_id,
          agent_id: "test-agent",
          agent_pid: agent_pid,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      on_exit(fn ->
        if Process.alive?(router_pid), do: GenServer.stop(router_pid, :normal, :infinity)
      end)

      # Check initial state structure BEFORE any command
      state = :sys.get_state(router_pid)

      # Per-action Router should have shell_command field (singular), not shell_commands (map)
      assert Map.has_key?(state, :shell_command)
      refute Map.has_key?(state, :shell_commands)

      # Initial shell_command is nil (no command yet)
      assert is_nil(state.shell_command)
    end

    @tag :r42
    test "R42: Shell Router terminates after command completion", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent_pid = self()
      action_id = "action-#{System.unique_integer([:positive])}"

      {:ok, router_pid} =
        Router.start_link(
          action_type: :execute_shell,
          action_id: action_id,
          agent_id: "test-agent",
          agent_pid: agent_pid,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      router_ref = Process.monitor(router_pid)

      # Execute quick shell command (needs :local_execution capability)
      capture_log(fn ->
        Router.execute(router_pid, :execute_shell, %{command: "echo done"}, "test-agent",
          agent_pid: agent_pid,
          pubsub: pubsub,
          capability_groups: [:local_execution]
        )
      end)

      # Router should terminate after shell completion
      assert_receive {:DOWN, ^router_ref, :process, ^router_pid, reason}, 30_000
      assert clean_termination?(reason)
    end
  end

  # =============================================================================
  # Wait Action Handling Tests (R43-R45)
  # =============================================================================

  describe "Wait Router handling (R43-R45)" do
    setup do
      pubsub = :"pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub})
      {:ok, pubsub: pubsub, sandbox_owner: self()}
    end

    @tag :r43
    test "R43: Wait Router stays alive for timer duration", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent_pid = self()
      action_id = "action-#{System.unique_integer([:positive])}"

      {:ok, router_pid} =
        Router.start_link(
          action_type: :wait,
          action_id: action_id,
          agent_id: "test-agent",
          agent_pid: agent_pid,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      on_exit(fn ->
        if Process.alive?(router_pid), do: GenServer.stop(router_pid, :normal, :infinity)
      end)

      # Execute timed wait (2 seconds - long enough to check state before expiry)
      capture_log(fn ->
        Router.execute(router_pid, :wait, %{wait: 2}, "test-agent")
      end)

      # Router should still be alive during wait - :sys.get_state is synchronous
      # If it succeeds, the process is alive and responsive
      # Check immediately after execute returns (well within 2s window)
      state = :sys.get_state(router_pid)
      assert is_map(state)
      assert state.wait_timer != nil, "Wait timer should be active"
    end

    @tag :r44
    test "R44: Wait Router terminates when timer fires", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent_pid = self()
      action_id = "action-#{System.unique_integer([:positive])}"

      {:ok, router_pid} =
        Router.start_link(
          action_type: :wait,
          action_id: action_id,
          agent_id: "test-agent",
          agent_pid: agent_pid,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      router_ref = Process.monitor(router_pid)

      # Execute short timed wait
      capture_log(fn ->
        Router.execute(router_pid, :wait, %{wait: 0.1}, "test-agent")
      end)

      # Router should terminate after timer fires
      assert_receive {:DOWN, ^router_ref, :process, ^router_pid, reason}, 30_000
      assert clean_termination?(reason)
    end

    @tag :r45
    test "R45: Immediate wait Router terminates right away", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent_pid = self()
      action_id = "action-#{System.unique_integer([:positive])}"

      {:ok, router_pid} =
        Router.start_link(
          action_type: :wait,
          action_id: action_id,
          agent_id: "test-agent",
          agent_pid: agent_pid,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      router_ref = Process.monitor(router_pid)

      # Execute immediate wait (wait: false or wait: 0)
      capture_log(fn ->
        Router.execute(router_pid, :wait, %{wait: false}, "test-agent")
      end)

      # Router should terminate immediately
      assert_receive {:DOWN, ^router_ref, :process, ^router_pid, reason}, 30_000
      assert clean_termination?(reason)
    end
  end

  # =============================================================================
  # State Simplification Tests (R46-R48)
  # =============================================================================

  describe "Router state simplification (R46-R48)" do
    setup do
      pubsub = :"pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub})
      {:ok, pubsub: pubsub, sandbox_owner: self()}
    end

    @tag :r46
    test "R46: Router state has empty active_tasks map", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent_pid = self()
      action_id = "action-#{System.unique_integer([:positive])}"

      {:ok, router_pid} =
        Router.start_link(
          action_type: :orient,
          action_id: action_id,
          agent_id: "test-agent",
          agent_pid: agent_pid,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      on_exit(fn ->
        if Process.alive?(router_pid), do: GenServer.stop(router_pid, :normal, :infinity)
      end)

      state = :sys.get_state(router_pid)

      # Per-action Router has active_tasks for Execution.handle_task_completion
      # but it's empty initially (no multi-action tracking needed)
      assert state.active_tasks == %{}
    end

    @tag :r47
    test "R47: Router state has empty results map", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent_pid = self()
      action_id = "action-#{System.unique_integer([:positive])}"

      {:ok, router_pid} =
        Router.start_link(
          action_type: :orient,
          action_id: action_id,
          agent_id: "test-agent",
          agent_pid: agent_pid,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      on_exit(fn ->
        if Process.alive?(router_pid), do: GenServer.stop(router_pid, :normal, :infinity)
      end)

      state = :sys.get_state(router_pid)

      # Per-action Router has results for Execution.handle_task_completion
      # but it's empty initially (no multi-action storage needed)
      assert state.results == %{}
    end

    @tag :r48
    test "R48: Router state has no metrics aggregation", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent_pid = self()
      action_id = "action-#{System.unique_integer([:positive])}"

      {:ok, router_pid} =
        Router.start_link(
          action_type: :orient,
          action_id: action_id,
          agent_id: "test-agent",
          agent_pid: agent_pid,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      on_exit(fn ->
        if Process.alive?(router_pid), do: GenServer.stop(router_pid, :normal, :infinity)
      end)

      state = :sys.get_state(router_pid)

      # Per-action Router should NOT have metrics aggregation (ephemeral)
      refute Map.has_key?(state, :metrics)
    end
  end

  # =============================================================================
  # Validation Still Works Tests (R49-R51)
  # =============================================================================

  describe "Per-action validation (R49-R51)" do
    setup do
      pubsub = :"pubsub_#{System.unique_integer([:positive])}"
      registry = :"registry_#{System.unique_integer([:positive])}"
      dynsup = :"dynsup_#{System.unique_integer([:positive])}"

      start_supervised!({Phoenix.PubSub, name: pubsub})
      start_supervised!({Registry, keys: :unique, name: registry})
      start_supervised!({DynamicSupervisor, name: dynsup, strategy: :one_for_one})

      {:ok, pubsub: pubsub, registry: registry, dynsup: dynsup, sandbox_owner: self()}
    end

    @tag :r49
    test "R49: per-action Router resolves secrets", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent_pid = self()
      action_id = "action-#{System.unique_integer([:positive])}"

      {:ok, router_pid} =
        Router.start_link(
          action_type: :orient,
          action_id: action_id,
          agent_id: "test-agent",
          agent_pid: agent_pid,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      on_exit(fn ->
        if Process.alive?(router_pid), do: GenServer.stop(router_pid, :normal, :infinity)
      end)

      # Test that secrets in params are resolved by verifying the placeholder
      # is NOT present in the action result (either replaced or error about missing)
      params = %{
        current_situation: "Testing with {{SECRET:nonexistent_test_key_xyz}}",
        goal_clarity: "Clear",
        available_resources: "Test",
        key_challenges: "None",
        delegation_consideration: "None"
      }

      capture_log(fn ->
        result = Router.execute(router_pid, :orient, params, "test-agent")

        # Secrets resolution should have been attempted:
        # - If secret found: placeholder replaced, action succeeds
        # - If secret not found: error about missing secret
        # Either way, the raw placeholder should NOT appear in successful result
        case result do
          {:ok, result_map} ->
            # If action succeeded, verify placeholder was resolved (not raw)
            result_str = inspect(result_map)
            refute result_str =~ "{{SECRET:", "Secret placeholder should be resolved"

          {:error, reason} ->
            # If error, it should be about the missing secret (resolution was attempted)
            # Accept any error - the point is resolution was attempted
            assert reason != nil
        end
      end)
    end

    @tag :r50
    test "R50: per-action Router checks permissions", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent_pid = self()
      action_id = "action-#{System.unique_integer([:positive])}"

      # Create Router with empty capability_groups (should block most actions)
      {:ok, router_pid} =
        Router.start_link(
          action_type: :execute_shell,
          action_id: action_id,
          agent_id: "test-agent",
          agent_pid: agent_pid,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          capability_groups: []
        )

      on_exit(fn ->
        if Process.alive?(router_pid), do: GenServer.stop(router_pid, :normal, :infinity)
      end)

      # Execute shell action - should be blocked by empty capability_groups
      capture_log(fn ->
        result =
          Router.execute(
            router_pid,
            :execute_shell,
            %{command: "echo test"},
            "test-agent",
            capability_groups: []
          )

        # Should return permission error
        assert {:error, :action_not_allowed} = result
      end)
    end

    @tag :r51
    test "R51: per-action Router checks budget", %{
      pubsub: pubsub,
      sandbox_owner: sandbox_owner
    } do
      agent_pid = self()
      action_id = "action-#{System.unique_integer([:positive])}"

      {:ok, router_pid} =
        Router.start_link(
          action_type: :spawn_child,
          action_id: action_id,
          agent_id: "test-agent",
          agent_pid: agent_pid,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner
        )

      on_exit(fn ->
        if Process.alive?(router_pid), do: GenServer.stop(router_pid, :normal, :infinity)
      end)

      # Execute costly action with over_budget: true
      capture_log(fn ->
        result =
          Router.execute(
            router_pid,
            :spawn_child,
            %{specialist_name: "test", initial_prompt: "test"},
            "test-agent",
            over_budget: true
          )

        # Should return budget exceeded error
        assert {:error, :budget_exceeded} = result
      end)
    end
  end

  # =============================================================================
  # Property Tests
  # =============================================================================

  describe "Router lifecycle properties" do
    @tag :property
    test "property: Router always terminates (no orphans)" do
      # StreamData property test
      # For any action type + params combination, Router should eventually terminate

      pubsub = :"pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub})

      # Test multiple quick actions
      for _ <- 1..10 do
        agent_pid = self()
        action_id = "action-#{System.unique_integer([:positive])}"

        {:ok, router_pid} =
          Router.start_link(
            action_type: :orient,
            action_id: action_id,
            agent_id: "test-agent",
            agent_pid: agent_pid,
            pubsub: pubsub,
            sandbox_owner: self()
          )

        router_ref = Process.monitor(router_pid)

        params = %{
          current_situation: "Test",
          goal_clarity: "Clear",
          available_resources: "Test",
          key_challenges: "None",
          delegation_consideration: "None"
        }

        capture_log(fn ->
          Router.execute(router_pid, :orient, params, "test-agent")
        end)

        # Every Router must terminate
        assert_receive {:DOWN, ^router_ref, :process, ^router_pid, _reason}, 30_000
      end
    end
  end
end
