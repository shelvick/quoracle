defmodule Quoracle.Agent.CoreRouterLifecycleTest do
  @moduledoc """
  Tests for Core Router lifecycle management (v30.0 refactor).

  WorkGroupID: refactor-20260124-router-per-action

  Packet 2 (Core Integration):
  Tests R52-R65: Core spawns Router per action, tracks active Routers,
  routes shell status checks, cleans up on Router death.
  Also includes ConfigManager tests R34-R37: No Router startup at init.

  Packet 3 (Shell Adaptation):
  Tests S1-S9: Shell Router lifecycle, single command state, completion flow,
  ShellCommandManager simplification.
  """

  use Quoracle.DataCase, async: true
  use ExUnitProperties
  import ExUnit.CaptureLog

  @moduletag capture_log: true

  alias Quoracle.Agent.ConfigManager
  alias Quoracle.Agent.Core
  alias Quoracle.Agent.Core.State

  # Helper for clean termination check
  defp clean_termination?(reason) do
    reason in [:normal, :shutdown, :noproc] or match?({:shutdown, _}, reason)
  end

  # Helper to wait for async condition (Router cleanup via :DOWN message)
  defp wait_until(condition_fn, timeout_ms \\ 1000, interval_ms \\ 10) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(condition_fn, deadline, interval_ms)
  end

  defp do_wait_until(condition_fn, deadline, interval_ms) do
    if condition_fn.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("wait_until timeout - condition not met")
      else
        # credo:disable-for-next-line Credo.Check.Concurrency.NoProcessSleep
        Process.sleep(interval_ms)
        do_wait_until(condition_fn, deadline, interval_ms)
      end
    end
  end

  # FIFO helpers for deterministic shell command blocking (no sleep timing)
  # FIFO blocks on read until written to - instant unblock when needed
  defp create_blocking_fifo do
    # Use both unique_integer AND monotonic time for true uniqueness across VM restarts
    # Also include random bytes to prevent any possibility of collision
    unique_id = "#{System.unique_integer([:positive])}_#{System.monotonic_time(:nanosecond)}"
    fifo_name = "test_fifo_#{unique_id}"
    fifo_path = Path.join(System.tmp_dir!(), fifo_name)

    # Clean up any leftover file first (handles VM restart collisions)
    File.rm(fifo_path)

    {_, 0} = System.cmd("mkfifo", [fifo_path])
    fifo_path
  end

  defp unblock_fifo(fifo_path) do
    # Write to FIFO to unblock any `cat` waiting on it
    # CRITICAL: Open with O_RDWR which NEVER blocks on FIFO (acts as both reader+writer)
    # This prevents deadlock when cat hasn't opened the FIFO yet
    case :file.open(fifo_path, [:read, :write, :raw]) do
      {:ok, fd} ->
        :file.write(fd, "done\n")
        :file.close(fd)

      {:error, :enoent} ->
        # FIFO already cleaned up - ok
        :ok

      {:error, _reason} ->
        # Other error (e.g., process died) - ok for cleanup
        :ok
    end
  end

  defp cleanup_fifo(fifo_path) do
    File.rm(fifo_path)
  end

  # Blocking command that waits on FIFO - use instead of "sleep N"
  defp blocking_command(fifo_path), do: "cat #{fifo_path}"

  # Wait for Router to appear in state using monitor-based synchronization
  # Polls with :sys.get_state which is a sync call (no raw sleep)
  defp wait_for_router_in_state(agent_pid, timeout \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_router(agent_pid, deadline)
  end

  defp do_wait_for_router(agent_pid, deadline) do
    state = :sys.get_state(agent_pid)

    cond do
      map_size(state.active_routers) > 0 ->
        state

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("Router not spawned within timeout")

      true ->
        :erlang.yield()
        do_wait_for_router(agent_pid, deadline)
    end
  end

  # Wait for Router cleanup using monitor-based synchronization
  defp wait_for_router_cleanup(agent_pid, timeout \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_cleanup(agent_pid, deadline)
  end

  defp do_wait_for_cleanup(agent_pid, deadline) do
    state = :sys.get_state(agent_pid)

    cond do
      map_size(state.active_routers) == 0 and map_size(state.shell_routers) == 0 ->
        state

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("Router cleanup not completed within timeout")

      true ->
        :erlang.yield()
        do_wait_for_cleanup(agent_pid, deadline)
    end
  end

  # Models TestActionHandler state transitions for property testing (R65)
  # Simulates: add shell router (both maps), add other router (active only), remove router
  defp apply_operation(state, {:add, :shell}) do
    ref = make_ref()
    # Use ref as fake PID for property testing
    pid = make_ref()
    action_id = "action_#{:erlang.unique_integer([:positive])}"

    %{
      state
      | active: Map.put(state.active, ref, pid),
        shell: Map.put(state.shell, action_id, pid),
        refs: [{ref, action_id, :shell} | state.refs]
    }
  end

  defp apply_operation(state, {:add, :other}) do
    ref = make_ref()
    pid = make_ref()

    %{
      state
      | active: Map.put(state.active, ref, pid),
        refs: [{ref, nil, :other} | state.refs]
    }
  end

  defp apply_operation(%{refs: []} = state, :remove), do: state

  defp apply_operation(state, :remove) do
    # Remove most recent router (simulates DOWN message handling)
    [{ref, action_id, type} | rest] = state.refs

    new_active = Map.delete(state.active, ref)

    new_shell =
      if type == :shell and action_id do
        Map.delete(state.shell, action_id)
      else
        state.shell
      end

    %{state | active: new_active, shell: new_shell, refs: rest}
  end

  # =============================================================================
  # State Field Tests (R52-R54)
  # =============================================================================

  describe "Core.State fields (R52-R54)" do
    @tag :r52
    test "R52: Core.State has no router_pid field" do
      # Per-action Router (v28.0): router_pid removed from Core state
      # Router is now spawned per-action, not per-agent

      state_fields = State.__struct__() |> Map.keys()

      refute :router_pid in state_fields,
             "Core.State should not have router_pid field - Routers are per-action now"
    end

    @tag :r53
    test "R53: Core.State initializes active_routers as empty map" do
      # Per-action Router (v30.0): Core tracks active Routers for cleanup

      state_fields = State.__struct__() |> Map.keys()

      assert :active_routers in state_fields,
             "Core.State should have active_routers field"

      # Verify default value is empty map
      default_state = State.__struct__()

      assert default_state.active_routers == %{},
             "active_routers should default to empty map"
    end

    @tag :r54
    test "R54: Core.State initializes shell_routers as empty map" do
      # Per-action Router (v30.0): Core tracks shell command Routers

      state_fields = State.__struct__() |> Map.keys()

      assert :shell_routers in state_fields,
             "Core.State should have shell_routers field"

      # Verify default value is empty map
      default_state = State.__struct__()

      assert default_state.shell_routers == %{},
             "shell_routers should default to empty map"
    end
  end

  # =============================================================================
  # Core → Shell Integration Test
  # =============================================================================

  describe "Core → Shell integration" do
    setup do
      pubsub = :"pubsub_#{System.unique_integer([:positive])}"
      registry = :"registry_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub})
      start_supervised!({Registry, keys: :unique, name: registry})

      dynsup = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

      {:ok, pubsub: pubsub, registry: registry, dynsup: dynsup, sandbox_owner: self()}
    end

    @tag :integration
    @tag :core_shell
    test "quick shell command through Core process_action completes", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # This test verifies the full Core → TestActionHandler → Router → Shell path
      # Uses a quick command that completes immediately

      agent_id = "agent-#{System.unique_integer([:positive])}"

      {:ok, agent_pid} =
        Core.start_link(
          agent_id: agent_id,
          registry: registry,
          dynsup: dynsup,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          test_mode: true,
          skip_auto_consensus: true,
          capability_groups: [:local_execution]
        )

      on_exit(fn ->
        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Use quick command that completes immediately
      action_map = %{action: :execute_shell, params: %{command: "echo hello"}}
      action_id = "test-action-#{System.unique_integer([:positive])}"

      result =
        capture_log(fn ->
          GenServer.call(agent_pid, {:process_action, action_map, action_id}, 30_000)
        end)

      # Should complete without timeout
      assert is_binary(result), "Should complete without timeout"
    end

    @tag :integration
    @tag :core_shell_async
    test "slow shell command through Core process_action returns async", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # This test verifies Shell detects slow command (>100ms threshold) and returns async
      # Uses sleep 0.5 which exceeds the 100ms smart_threshold

      agent_id = "agent-#{System.unique_integer([:positive])}"

      {:ok, agent_pid} =
        Core.start_link(
          agent_id: agent_id,
          registry: registry,
          dynsup: dynsup,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          test_mode: true,
          skip_auto_consensus: true,
          capability_groups: [:local_execution]
        )

      on_exit(fn ->
        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Command takes 500ms - well over 100ms smart_threshold
      # Should return async result quickly, not block for 500ms
      action_map = %{action: :execute_shell, params: %{command: "sleep 0.5 && echo done"}}
      action_id = "test-action-#{System.unique_integer([:positive])}"

      {:ok, result} = GenServer.call(agent_pid, {:process_action, action_map, action_id}, 30_000)

      # Should return async result (not wait for command to complete)
      assert result.status == :running, "Should return status: :running"
    end

    @tag :integration
    @tag :core_shell_fifo
    test "FIFO-blocked shell command through Core process_action returns async", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # This test verifies FIFO-blocked commands return async through Core path

      agent_id = "agent-#{System.unique_integer([:positive])}"
      fifo_path = create_blocking_fifo()

      {:ok, agent_pid} =
        Core.start_link(
          agent_id: agent_id,
          registry: registry,
          dynsup: dynsup,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          test_mode: true,
          skip_auto_consensus: true,
          capability_groups: [:local_execution]
        )

      # CRITICAL: Unblock FIFO before stopping agent
      on_exit(fn ->
        unblock_fifo(fifo_path)
        cleanup_fifo(fifo_path)

        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # FIFO-blocked command - should return async quickly
      action_map = %{action: :execute_shell, params: %{command: blocking_command(fifo_path)}}
      action_id = "test-action-#{System.unique_integer([:positive])}"

      {:ok, result} = GenServer.call(agent_pid, {:process_action, action_map, action_id}, 30_000)

      # Should return async result (not block on FIFO)
      assert result.status == :running, "Should return status: :running"
    end
  end

  # =============================================================================
  # Router Spawning Tests (R55-R57)
  # =============================================================================

  describe "Router spawning (R55-R57)" do
    setup do
      pubsub = :"pubsub_#{System.unique_integer([:positive])}"
      registry = :"registry_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub})
      start_supervised!({Registry, keys: :unique, name: registry})

      dynsup = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

      {:ok, pubsub: pubsub, registry: registry, dynsup: dynsup, sandbox_owner: self()}
    end

    @tag :r55
    test "R55: Core spawns new Router for each action", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # Per-action Router (v30.0): Each action gets its own Router

      agent_id = "agent-#{System.unique_integer([:positive])}"

      {:ok, agent_pid} =
        Core.start_link(
          agent_id: agent_id,
          registry: registry,
          dynsup: dynsup,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          test_mode: true,
          skip_auto_consensus: true
        )

      on_exit(fn ->
        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Get initial state - should have no active Routers
      initial_state = :sys.get_state(agent_pid)
      assert initial_state.active_routers == %{}

      # Execute an action through the test handler
      # Orient requires: current_situation, goal_clarity, available_resources, key_challenges, delegation_consideration
      action_map = %{
        action: :orient,
        params: %{
          current_situation: "testing router lifecycle",
          goal_clarity: "high",
          available_resources: "test resources",
          key_challenges: "none",
          delegation_consideration: "none"
        }
      }

      action_id = "test-action-#{System.unique_integer([:positive])}"

      capture_log(fn ->
        {:ok, _result} = GenServer.call(agent_pid, {:process_action, action_map, action_id})
      end)

      # Wait for Router cleanup (:DOWN message processing is async)
      wait_until(fn ->
        state = :sys.get_state(agent_pid)
        state.active_routers == %{}
      end)
    end

    @tag :r56
    test "R56: Core monitors spawned Routers", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # Per-action Router (v30.0): Core monitors Routers for cleanup

      agent_id = "agent-#{System.unique_integer([:positive])}"

      {:ok, agent_pid} =
        Core.start_link(
          agent_id: agent_id,
          registry: registry,
          dynsup: dynsup,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          test_mode: true,
          skip_auto_consensus: true,
          capability_groups: [:local_execution]
        )

      # Create FIFO for deterministic blocking (instant unblock, no sleep timing)
      fifo_path = create_blocking_fifo()

      on_exit(fn ->
        unblock_fifo(fifo_path)
        cleanup_fifo(fifo_path)

        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Execute shell command - spawn a task to run it async so we can check state
      task =
        Task.async(fn ->
          action_map = %{action: :execute_shell, params: %{command: blocking_command(fifo_path)}}
          action_id = "test-action-#{System.unique_integer([:positive])}"

          capture_log(fn ->
            GenServer.call(agent_pid, {:process_action, action_map, action_id}, 30_000)
          end)
        end)

      # Wait for Router to be spawned and check state
      state = wait_for_router_in_state(agent_pid)

      # active_routers should contain the shell Router with monitor ref
      assert map_size(state.active_routers) >= 1,
             "active_routers should track the shell command Router"

      # Keys should be monitor refs (references)
      for {ref, _pid} <- state.active_routers do
        assert is_reference(ref), "active_routers keys should be monitor references"
      end

      # Cleanup task (FIFO unblock handled by on_exit)
      Task.shutdown(task, :brutal_kill)
    end

    @tag :r57
    test "R57: Core tracks shell command Routers in shell_routers map", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # Per-action Router (v30.0): Shell Routers tracked by command_id

      agent_id = "agent-#{System.unique_integer([:positive])}"

      {:ok, agent_pid} =
        Core.start_link(
          agent_id: agent_id,
          registry: registry,
          dynsup: dynsup,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          test_mode: true,
          skip_auto_consensus: true,
          capability_groups: [:local_execution]
        )

      # Create FIFO for deterministic blocking
      fifo_path = create_blocking_fifo()

      on_exit(fn ->
        unblock_fifo(fifo_path)
        cleanup_fifo(fifo_path)

        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Execute async shell command in background
      task =
        Task.async(fn ->
          action_map = %{action: :execute_shell, params: %{command: blocking_command(fifo_path)}}
          action_id = "test-action-#{System.unique_integer([:positive])}"

          capture_log(fn ->
            GenServer.call(agent_pid, {:process_action, action_map, action_id}, 30_000)
          end)
        end)

      # Wait for Router to be spawned and check state
      state = wait_for_router_in_state(agent_pid)

      # shell_routers should map command_id => router_pid
      assert map_size(state.shell_routers) >= 1,
             "shell_routers should track the shell command Router"

      # Keys should be command_id strings, values should be PIDs
      for {cmd_id, router_pid} <- state.shell_routers do
        assert is_binary(cmd_id), "shell_routers keys should be command_id strings"
        assert is_pid(router_pid), "shell_routers values should be Router PIDs"
      end

      # Cleanup task (FIFO unblock handled by on_exit)
      Task.shutdown(task, :brutal_kill)
    end
  end

  # =============================================================================
  # Status Check Routing Tests (R58-R60)
  # =============================================================================

  describe "Shell status check routing (R58-R60)" do
    setup do
      pubsub = :"pubsub_#{System.unique_integer([:positive])}"
      registry = :"registry_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub})
      start_supervised!({Registry, keys: :unique, name: registry})

      dynsup = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

      {:ok, pubsub: pubsub, registry: registry, dynsup: dynsup, sandbox_owner: self()}
    end

    @tag :r58
    test "R58: shell_status routed to correct Router via shell_routers", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # Per-action Router (v30.0): Core routes status checks to shell Routers

      agent_id = "agent-#{System.unique_integer([:positive])}"

      {:ok, agent_pid} =
        Core.start_link(
          agent_id: agent_id,
          registry: registry,
          dynsup: dynsup,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          test_mode: true,
          skip_auto_consensus: true,
          capability_groups: [:local_execution]
        )

      # Create FIFO for deterministic blocking
      fifo_path = create_blocking_fifo()

      on_exit(fn ->
        unblock_fifo(fifo_path)
        cleanup_fifo(fifo_path)

        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Start a shell command in background
      task =
        Task.async(fn ->
          action_map = %{action: :execute_shell, params: %{command: blocking_command(fifo_path)}}
          action_id = "test-action-#{System.unique_integer([:positive])}"

          capture_log(fn ->
            GenServer.call(agent_pid, {:process_action, action_map, action_id}, 30_000)
          end)
        end)

      # Wait for Router to be spawned
      state = wait_for_router_in_state(agent_pid)
      command_id = state.shell_routers |> Map.keys() |> List.first()

      # Route status check through Core
      result = GenServer.call(agent_pid, {:shell_status, command_id})

      # Should get status from the Router
      assert {:ok, status} = result
      assert status.status == :running

      # Cleanup task (FIFO unblock handled by on_exit)
      Task.shutdown(task, :brutal_kill)
    end

    @tag :r59
    test "R59: shell_status returns error for unknown command", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # Per-action Router (v30.0): Unknown command returns :command_not_found

      agent_id = "agent-#{System.unique_integer([:positive])}"

      {:ok, agent_pid} =
        Core.start_link(
          agent_id: agent_id,
          registry: registry,
          dynsup: dynsup,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          test_mode: true,
          skip_auto_consensus: true
        )

      on_exit(fn ->
        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Request status for non-existent command
      result = GenServer.call(agent_pid, {:shell_status, "fake-command-id"})

      assert {:error, :command_not_found} = result
    end

    @tag :r60
    test "R60: terminate_shell routed to correct Router", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # Per-action Router (v30.0): Core routes termination to shell Routers

      agent_id = "agent-#{System.unique_integer([:positive])}"

      {:ok, agent_pid} =
        Core.start_link(
          agent_id: agent_id,
          registry: registry,
          dynsup: dynsup,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          test_mode: true,
          skip_auto_consensus: true,
          capability_groups: [:local_execution]
        )

      # Create FIFO for deterministic blocking
      fifo_path = create_blocking_fifo()

      on_exit(fn ->
        unblock_fifo(fifo_path)
        cleanup_fifo(fifo_path)

        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Start a shell command in background
      task =
        Task.async(fn ->
          action_map = %{action: :execute_shell, params: %{command: blocking_command(fifo_path)}}
          action_id = "test-action-#{System.unique_integer([:positive])}"

          capture_log(fn ->
            GenServer.call(agent_pid, {:process_action, action_map, action_id}, 30_000)
          end)
        end)

      # Wait for Router to be spawned
      state = wait_for_router_in_state(agent_pid)
      command_id = state.shell_routers |> Map.keys() |> List.first()

      # Terminate through Core
      result = GenServer.call(agent_pid, {:terminate_shell, command_id})

      # Should get termination result from the Router
      assert {:ok, term_result} = result
      assert term_result.terminated == true

      # Cleanup task (FIFO unblock handled by on_exit)
      Task.shutdown(task, :brutal_kill)
    end
  end

  # =============================================================================
  # Cleanup Tests (R61-R63)
  # =============================================================================

  describe "Router cleanup (R61-R63)" do
    setup do
      pubsub = :"pubsub_#{System.unique_integer([:positive])}"
      registry = :"registry_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub})
      start_supervised!({Registry, keys: :unique, name: registry})

      dynsup = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

      {:ok, pubsub: pubsub, registry: registry, dynsup: dynsup, sandbox_owner: self()}
    end

    @tag :r61
    test "R61: Core cleans up tracking maps when Router dies", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # Per-action Router (v30.0): Router death cleans active_routers and shell_routers

      agent_id = "agent-#{System.unique_integer([:positive])}"

      {:ok, agent_pid} =
        Core.start_link(
          agent_id: agent_id,
          registry: registry,
          dynsup: dynsup,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          test_mode: true,
          skip_auto_consensus: true,
          capability_groups: [:local_execution]
        )

      # Create FIFO for deterministic blocking
      fifo_path = create_blocking_fifo()

      on_exit(fn ->
        unblock_fifo(fifo_path)
        cleanup_fifo(fifo_path)

        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Start a shell command in background
      task =
        Task.async(fn ->
          action_map = %{action: :execute_shell, params: %{command: blocking_command(fifo_path)}}
          action_id = "test-action-#{System.unique_integer([:positive])}"

          capture_log(fn ->
            GenServer.call(agent_pid, {:process_action, action_map, action_id}, 30_000)
          end)
        end)

      # Wait for Router to be spawned
      state = wait_for_router_in_state(agent_pid)
      [{_cmd_id, router_pid}] = Map.to_list(state.shell_routers)

      # Kill the Router
      Process.exit(router_pid, :kill)

      # Wait for cleanup to complete (Core processes DOWN message)
      wait_for_router_cleanup(agent_pid)

      # Verify cleanup
      final_state = :sys.get_state(agent_pid)
      assert final_state.active_routers == %{}, "active_routers should be cleaned up"
      assert final_state.shell_routers == %{}, "shell_routers should be cleaned up"

      # Cleanup task (FIFO unblock handled by on_exit)
      Task.shutdown(task, :brutal_kill)
    end

    @tag :r62
    test "R62: Core.terminate stops all active Routers", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # Per-action Router (v30.0): Core terminates all Routers on shutdown

      agent_id = "agent-#{System.unique_integer([:positive])}"

      {:ok, agent_pid} =
        Core.start_link(
          agent_id: agent_id,
          registry: registry,
          dynsup: dynsup,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          test_mode: true,
          skip_auto_consensus: true,
          capability_groups: [:local_execution]
        )

      # Sync point: wait for handle_continue to complete before calling process_action
      # Without this, GenServer.call queues behind handle_continue's DB operations
      # which can timeout under full suite load with DB pool contention
      _ = :sys.get_state(agent_pid)

      # Create FIFOs for deterministic blocking (one per command)
      fifo_paths = for _ <- 1..2, do: create_blocking_fifo()

      on_exit(fn ->
        for fifo_path <- fifo_paths, do: unblock_fifo(fifo_path)
        for fifo_path <- fifo_paths, do: cleanup_fifo(fifo_path)
      end)

      # Start multiple shell commands in background to have active Routers
      tasks =
        for fifo_path <- fifo_paths do
          Task.async(fn ->
            action_map = %{
              action: :execute_shell,
              params: %{command: blocking_command(fifo_path)}
            }

            action_id = "test-action-#{System.unique_integer([:positive])}"

            capture_log(fn ->
              GenServer.call(agent_pid, {:process_action, action_map, action_id}, 30_000)
            end)
          end)
        end

      # Wait for Routers to be spawned
      state = wait_for_router_in_state(agent_pid)
      router_pids = Map.values(state.shell_routers)

      # Monitor all Routers
      refs = Enum.map(router_pids, &Process.monitor/1)

      # Unblock FIFOs before terminating (uses O_RDWR internally - never blocks)
      for fifo_path <- fifo_paths, do: unblock_fifo(fifo_path)

      # Terminate Core
      GenServer.stop(agent_pid, :normal, :infinity)

      # All Routers should be terminated
      for ref <- refs do
        assert_receive {:DOWN, ^ref, :process, _pid, reason}, 30_000
        assert clean_termination?(reason)
      end

      # Cleanup tasks
      for task <- tasks, do: Task.shutdown(task, :brutal_kill)
    end

    @tag :r63
    test "R63: Core uses :infinity timeout when stopping Routers", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # Per-action Router (v30.0): :infinity timeout allows DB operations to complete

      agent_id = "agent-#{System.unique_integer([:positive])}"

      {:ok, agent_pid} =
        Core.start_link(
          agent_id: agent_id,
          registry: registry,
          dynsup: dynsup,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          test_mode: true,
          skip_auto_consensus: true,
          capability_groups: [:local_execution]
        )

      # Create FIFO for deterministic blocking
      fifo_path = create_blocking_fifo()

      on_exit(fn ->
        cleanup_fifo(fifo_path)
      end)

      # Start a shell command in background
      task =
        Task.async(fn ->
          action_map = %{action: :execute_shell, params: %{command: blocking_command(fifo_path)}}
          action_id = "test-action-#{System.unique_integer([:positive])}"

          capture_log(fn ->
            GenServer.call(agent_pid, {:process_action, action_map, action_id}, 30_000)
          end)
        end)

      # Wait for Router to be spawned
      _state = wait_for_router_in_state(agent_pid)

      # Unblock FIFO before terminating Core (so shell command can complete)
      unblock_fifo(fifo_path)

      # Terminate Core - should complete without timeout errors
      result =
        try do
          GenServer.stop(agent_pid, :normal, :infinity)
          :ok
        catch
          :exit, reason -> {:error, reason}
        end

      assert result == :ok, "Core termination should complete without timeout"

      # Cleanup
      Task.shutdown(task, :brutal_kill)
    end
  end

  # =============================================================================
  # Property Tests (R64-R65)
  # =============================================================================

  describe "Router lifecycle properties (R64-R65)" do
    setup do
      pubsub = :"pubsub_#{System.unique_integer([:positive])}"
      registry = :"registry_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub})
      start_supervised!({Registry, keys: :unique, name: registry})

      dynsup = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

      {:ok, pubsub: pubsub, registry: registry, dynsup: dynsup, sandbox_owner: self()}
    end

    @tag :r64
    @tag :property
    test "R64: property - all spawned Routers terminate", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # Per-action Router (v30.0): No orphan Routers after Core terminates

      # Run multiple iterations with random action sequences
      for _i <- 1..5 do
        agent_id = "agent-#{System.unique_integer([:positive])}"

        {:ok, agent_pid} =
          Core.start_link(
            agent_id: agent_id,
            registry: registry,
            dynsup: dynsup,
            pubsub: pubsub,
            sandbox_owner: sandbox_owner,
            test_mode: true,
            skip_auto_consensus: true
          )

        # Execute a few quick actions (orient requires 5 mandatory fields)
        # current_situation, goal_clarity, available_resources, key_challenges, delegation_consideration
        capture_log(fn ->
          for _ <- 1..3 do
            action_map = %{
              action: :orient,
              params: %{
                current_situation: "testing router lifecycle",
                goal_clarity: "high",
                available_resources: "test resources",
                key_challenges: "none",
                delegation_consideration: "none"
              }
            }

            action_id = "test-action-#{System.unique_integer([:positive])}"
            GenServer.call(agent_pid, {:process_action, action_map, action_id})
          end
        end)

        # Get any remaining active Routers
        state = :sys.get_state(agent_pid)
        router_pids = Map.values(state.active_routers)
        refs = Enum.map(router_pids, &Process.monitor/1)

        # Terminate Core
        GenServer.stop(agent_pid, :normal, :infinity)

        # All Routers should terminate
        for ref <- refs do
          assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 30_000
        end
      end
    end

    @tag :r65
    @tag :property
    property "R65: shell_routers subset of active_routers for any operation sequence" do
      # Property test: state management logic maintains invariant
      # Models TestActionHandler's state transitions without actual processes

      # Operation: {:add, :shell | :other} or {:remove, ref}
      operation_gen =
        StreamData.frequency([
          {3, StreamData.constant({:add, :shell})},
          {2, StreamData.constant({:add, :other})},
          {2, StreamData.constant(:remove)}
        ])

      check all(
              operations <- StreamData.list_of(operation_gen, min_length: 1, max_length: 20),
              max_runs: 100
            ) do
        # Simulate state transitions
        {_final_state, all_valid} =
          Enum.reduce(operations, {%{active: %{}, shell: %{}, refs: []}, true}, fn
            op, {state, valid} ->
              new_state = apply_operation(state, op)
              # Check invariant after each operation
              shell_pids = MapSet.new(Map.values(new_state.shell))
              active_pids = MapSet.new(Map.values(new_state.active))
              still_valid = valid and MapSet.subset?(shell_pids, active_pids)
              {new_state, still_valid}
          end)

        assert all_valid, "Invariant violated during operation sequence"
      end
    end
  end

  # =============================================================================
  # ConfigManager Tests (R34-R37)
  # =============================================================================

  describe "ConfigManager Router removal (R34-R37)" do
    setup do
      pubsub = :"pubsub_#{System.unique_integer([:positive])}"
      registry = :"registry_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub})
      start_supervised!({Registry, keys: :unique, name: registry})

      dynsup = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

      {:ok, pubsub: pubsub, registry: registry, dynsup: dynsup, sandbox_owner: self()}
    end

    @tag :r34
    test "R34: setup_agent does not start Router" do
      # Per-action Router (v10.0): Router.start_link removed from ConfigManager

      # Read the ConfigManager module source and verify no Router.start_link
      {:ok, source} = File.read("lib/quoracle/agent/config_manager.ex")

      refute String.contains?(source, "Router.start_link"),
             "ConfigManager should not contain Router.start_link"
    end

    @tag :r35
    test "R35: setup_agent state has no router_pid field", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # Per-action Router (v10.0): No router_pid in returned config

      agent_id = "agent-#{System.unique_integer([:positive])}"

      config = %{
        agent_id: agent_id,
        registry: registry,
        dynsup: dynsup,
        pubsub: pubsub,
        sandbox_owner: sandbox_owner,
        test_mode: true
      }

      # setup_agent returns State struct directly
      setup_result = ConfigManager.setup_agent(config)

      refute Map.has_key?(setup_result, :router_pid),
             "setup_agent result should not contain router_pid"
    end

    @tag :r36
    test "R36: agent initializes successfully without per-agent Router", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # Per-action Router (v10.0): Agent starts without Router

      agent_id = "agent-#{System.unique_integer([:positive])}"

      result =
        Core.start_link(
          agent_id: agent_id,
          registry: registry,
          dynsup: dynsup,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          test_mode: true,
          skip_auto_consensus: true
        )

      assert {:ok, agent_pid} = result
      assert Process.alive?(agent_pid)

      # Cleanup
      GenServer.stop(agent_pid, :normal, :infinity)
    end

    @tag :r37
    test "R37: no Router process exists immediately after agent spawn", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # Per-action Router (v10.0): No Router until action executed

      agent_id = "agent-#{System.unique_integer([:positive])}"

      {:ok, agent_pid} =
        Core.start_link(
          agent_id: agent_id,
          registry: registry,
          dynsup: dynsup,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          test_mode: true,
          skip_auto_consensus: true
        )

      on_exit(fn ->
        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Check state immediately after spawn
      state = :sys.get_state(agent_pid)

      # No router_pid field should exist
      refute Map.has_key?(state, :router_pid),
             "Agent state should not have router_pid field"

      # active_routers should be empty (no Routers spawned yet)
      assert state.active_routers == %{},
             "active_routers should be empty immediately after spawn"
    end
  end

  # =============================================================================
  # Packet 3: Shell Router Adaptation (S1-S9)
  # =============================================================================

  describe "Shell Router adaptation (S1-S9)" do
    setup do
      pubsub = :"pubsub_#{System.unique_integer([:positive])}"
      registry = :"registry_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub})
      start_supervised!({Registry, keys: :unique, name: registry})

      dynsup = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

      {:ok, pubsub: pubsub, registry: registry, dynsup: dynsup, sandbox_owner: self()}
    end

    @tag :s1
    test "S1: Router stays alive during async shell command", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # Per-action Router (v2.0): Router remains alive for async shell commands

      agent_id = "agent-#{System.unique_integer([:positive])}"

      {:ok, agent_pid} =
        Core.start_link(
          agent_id: agent_id,
          registry: registry,
          dynsup: dynsup,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          test_mode: true,
          skip_auto_consensus: true,
          capability_groups: [:local_execution]
        )

      # Create FIFO for deterministic blocking
      fifo_path = create_blocking_fifo()

      on_exit(fn ->
        unblock_fifo(fifo_path)
        cleanup_fifo(fifo_path)

        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Start async shell command (FIFO blocks until written to)
      task =
        Task.async(fn ->
          action_map = %{action: :execute_shell, params: %{command: blocking_command(fifo_path)}}
          action_id = "test-action-#{System.unique_integer([:positive])}"

          capture_log(fn ->
            GenServer.call(agent_pid, {:process_action, action_map, action_id}, 30_000)
          end)
        end)

      # Wait for Router to be spawned
      state = wait_for_router_in_state(agent_pid)
      [{_cmd_id, router_pid}] = Map.to_list(state.shell_routers)

      # Router should be alive during command execution
      assert Process.alive?(router_pid), "Router must stay alive during async shell command"

      # Verify Router is tracked in both maps
      assert map_size(state.active_routers) >= 1
      assert map_size(state.shell_routers) >= 1

      # Cleanup task (FIFO unblock handled by on_exit)
      Task.shutdown(task, :brutal_kill)
    end

    @tag :s2
    test "S2: Router terminates after shell completion notification", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # Per-action Router (v2.0): Router terminates after notifying Core of completion

      agent_id = "agent-#{System.unique_integer([:positive])}"

      {:ok, agent_pid} =
        Core.start_link(
          agent_id: agent_id,
          registry: registry,
          dynsup: dynsup,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          test_mode: true,
          skip_auto_consensus: true,
          capability_groups: [:local_execution]
        )

      on_exit(fn ->
        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Execute short shell command that completes quickly
      action_map = %{action: :execute_shell, params: %{command: "echo hello"}}
      action_id = "test-action-#{System.unique_integer([:positive])}"

      capture_log(fn ->
        {:ok, result} =
          GenServer.call(agent_pid, {:process_action, action_map, action_id}, 30_000)

        # Verify command completed (result has action field)
        # Don't check :sync field - that's implementation detail (sync vs async depends on timing)
        assert result.action == "shell", "Should get shell result"
      end)

      # After completion, Router should have terminated and been cleaned up
      # Wait for cleanup
      wait_for_router_cleanup(agent_pid)

      final_state = :sys.get_state(agent_pid)
      assert final_state.active_routers == %{}, "Router should terminate after shell completion"
      assert final_state.shell_routers == %{}, "Shell router entry should be cleaned up"
    end

    @tag :s3
    test "S3: status check routes through Core shell_routers map", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # Per-action Router (v2.0): Core routes status checks via shell_routers

      agent_id = "agent-#{System.unique_integer([:positive])}"

      {:ok, agent_pid} =
        Core.start_link(
          agent_id: agent_id,
          registry: registry,
          dynsup: dynsup,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          test_mode: true,
          skip_auto_consensus: true,
          capability_groups: [:local_execution]
        )

      # Create FIFO for deterministic blocking
      fifo_path = create_blocking_fifo()

      on_exit(fn ->
        unblock_fifo(fifo_path)
        cleanup_fifo(fifo_path)

        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Start async shell command
      task =
        Task.async(fn ->
          action_map = %{action: :execute_shell, params: %{command: blocking_command(fifo_path)}}
          action_id = "test-action-#{System.unique_integer([:positive])}"

          capture_log(fn ->
            GenServer.call(agent_pid, {:process_action, action_map, action_id}, 30_000)
          end)
        end)

      # Wait for Router to be spawned
      state = wait_for_router_in_state(agent_pid)
      command_id = state.shell_routers |> Map.keys() |> List.first()

      # Verify shell_routers contains the command
      assert command_id != nil, "shell_routers should contain command_id"

      # Status check should route through Core to correct Router
      {:ok, status} = GenServer.call(agent_pid, {:shell_status, command_id})

      assert status.status == :running, "Should get status from routed Router"
      assert is_binary(status.command), "Status should include command string"

      # Cleanup task (FIFO unblock handled by on_exit)
      Task.shutdown(task, :brutal_kill)
    end

    @tag :s4
    test "S4: status check for unknown command returns error", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # Per-action Router (v2.0): Unknown command_id returns :command_not_found

      agent_id = "agent-#{System.unique_integer([:positive])}"

      {:ok, agent_pid} =
        Core.start_link(
          agent_id: agent_id,
          registry: registry,
          dynsup: dynsup,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          test_mode: true,
          skip_auto_consensus: true
        )

      on_exit(fn ->
        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Request status for non-existent command
      result = GenServer.call(agent_pid, {:shell_status, "nonexistent-command-id"})

      assert {:error, :command_not_found} = result
    end

    @tag :s5
    test "S5: termination routes through Core shell_routers map", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # Per-action Router (v2.0): Core routes termination via shell_routers

      agent_id = "agent-#{System.unique_integer([:positive])}"
      fifo_path = create_blocking_fifo()

      {:ok, agent_pid} =
        Core.start_link(
          agent_id: agent_id,
          registry: registry,
          dynsup: dynsup,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          test_mode: true,
          skip_auto_consensus: true,
          capability_groups: [:local_execution]
        )

      on_exit(fn ->
        unblock_fifo(fifo_path)
        cleanup_fifo(fifo_path)

        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Start async shell command with FIFO blocking
      task =
        Task.async(fn ->
          action_map = %{action: :execute_shell, params: %{command: blocking_command(fifo_path)}}
          action_id = "test-action-#{System.unique_integer([:positive])}"

          capture_log(fn ->
            GenServer.call(agent_pid, {:process_action, action_map, action_id}, 30_000)
          end)
        end)

      # Wait for Router to be spawned
      state = wait_for_router_in_state(agent_pid)
      command_id = state.shell_routers |> Map.keys() |> List.first()

      # Termination should route through Core to correct Router
      {:ok, term_result} = GenServer.call(agent_pid, {:terminate_shell, command_id})

      assert term_result.terminated == true, "Termination should succeed via routed Router"

      # Cleanup task (FIFO unblock handled by on_exit)
      Task.shutdown(task, :brutal_kill)
    end

    @tag :s6
    test "S6: Router terminates after shell command termination", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # Per-action Router (v2.0): Router self-terminates after returning termination result

      agent_id = "agent-#{System.unique_integer([:positive])}"
      fifo_path = create_blocking_fifo()

      {:ok, agent_pid} =
        Core.start_link(
          agent_id: agent_id,
          registry: registry,
          dynsup: dynsup,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          test_mode: true,
          skip_auto_consensus: true,
          capability_groups: [:local_execution]
        )

      on_exit(fn ->
        unblock_fifo(fifo_path)
        cleanup_fifo(fifo_path)

        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Start async shell command with FIFO blocking
      task =
        Task.async(fn ->
          action_map = %{action: :execute_shell, params: %{command: blocking_command(fifo_path)}}
          action_id = "test-action-#{System.unique_integer([:positive])}"

          capture_log(fn ->
            GenServer.call(agent_pid, {:process_action, action_map, action_id}, 30_000)
          end)
        end)

      # Wait for Router to be spawned
      state = wait_for_router_in_state(agent_pid)
      [{command_id, router_pid}] = Map.to_list(state.shell_routers)

      # Monitor the Router
      router_ref = Process.monitor(router_pid)

      # Terminate the shell command
      {:ok, _term_result} = GenServer.call(agent_pid, {:terminate_shell, command_id})

      # Router should terminate after handling termination
      assert_receive {:DOWN, ^router_ref, :process, ^router_pid, reason}, 30_000
      assert clean_termination?(reason), "Router should terminate cleanly"

      # Cleanup task (FIFO unblock handled by on_exit)
      Task.shutdown(task, :brutal_kill)
    end

    @tag :s7
    test "S7: Router stores single shell command state (not map)", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # Per-action Router (v2.0): Router has single shell_command, not map of commands

      agent_id = "agent-#{System.unique_integer([:positive])}"
      fifo_path = create_blocking_fifo()

      {:ok, agent_pid} =
        Core.start_link(
          agent_id: agent_id,
          registry: registry,
          dynsup: dynsup,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          test_mode: true,
          skip_auto_consensus: true,
          capability_groups: [:local_execution]
        )

      on_exit(fn ->
        unblock_fifo(fifo_path)
        cleanup_fifo(fifo_path)

        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Start async shell command with FIFO blocking
      task =
        Task.async(fn ->
          action_map = %{action: :execute_shell, params: %{command: blocking_command(fifo_path)}}
          action_id = "test-action-#{System.unique_integer([:positive])}"

          capture_log(fn ->
            GenServer.call(agent_pid, {:process_action, action_map, action_id}, 30_000)
          end)
        end)

      # Wait for Router to be spawned
      state = wait_for_router_in_state(agent_pid)
      [{_cmd_id, router_pid}] = Map.to_list(state.shell_routers)

      # Get Router state and verify structure
      router_state = :sys.get_state(router_pid)

      # Should have shell_command field (single struct or map), NOT shell_commands (map of commands)
      refute Map.has_key?(router_state, :shell_commands),
             "Router should not have :shell_commands map (old per-agent pattern)"

      assert Map.has_key?(router_state, :shell_command),
             "Router should have :shell_command field (single command)"

      # shell_command should be a struct/map or nil, not a Map with command_id keys
      shell_cmd = router_state.shell_command

      if shell_cmd != nil do
        refute is_map(shell_cmd) and map_size(shell_cmd) > 0 and
                 shell_cmd |> Map.keys() |> List.first() |> is_binary(),
               "shell_command should not be a map keyed by command_id"
      end

      # Cleanup task (FIFO unblock handled by on_exit)
      Task.shutdown(task, :brutal_kill)
    end

    @tag :s8
    test "S8: shell completion notifies Core via handle_action_result", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # Per-action Router (v2.0): Shell completion flows through Core.handle_action_result

      agent_id = "agent-#{System.unique_integer([:positive])}"

      {:ok, agent_pid} =
        Core.start_link(
          agent_id: agent_id,
          registry: registry,
          dynsup: dynsup,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          test_mode: true,
          skip_auto_consensus: true,
          capability_groups: [:local_execution]
        )

      on_exit(fn ->
        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Subscribe to action completion events to verify the flow
      Phoenix.PubSub.subscribe(pubsub, "agent:#{agent_id}")

      # Execute shell command that completes quickly
      action_map = %{action: :execute_shell, params: %{command: "echo 'test output'"}}
      action_id = "test-action-#{System.unique_integer([:positive])}"

      capture_log(fn ->
        {:ok, result} =
          GenServer.call(agent_pid, {:process_action, action_map, action_id}, 30_000)

        # Verify result is a valid shell response (sync or async depending on load)
        assert result.action == "shell", "Shell result action should be 'shell'"
      end)

      # After completion, verify Core cleaned up (indication it processed the result)
      wait_for_router_cleanup(agent_pid)

      final_state = :sys.get_state(agent_pid)
      assert final_state.shell_routers == %{}, "Core should have processed completion"
    end

    @tag :s9
    test "S9: ShellCommandManager.init returns nil (single command, not map)" do
      # Per-action Router (v2.0): ShellCommandManager simplified to single-command state
      # init/0 should return nil (no command) instead of %{} (empty command map)

      alias Quoracle.Actions.Router.ShellCommandManager

      # WILL FAIL: Current implementation returns %{} (multi-command map)
      # Expected: nil (single command state - no command initially)
      result = ShellCommandManager.init()

      assert result == nil,
             "ShellCommandManager.init/0 should return nil for per-action Router " <>
               "(got #{inspect(result)} - still using multi-command map pattern)"
    end
  end

  # =============================================================================
  # Packet 4: BatchSync Fix (R14-R22)
  # =============================================================================

  describe "BatchSync validation bypass fix (R14-R22)" do
    setup do
      pubsub = :"pubsub_#{System.unique_integer([:positive])}"
      registry = :"registry_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub})
      start_supervised!({Registry, keys: :unique, name: registry})

      dynsup = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

      {:ok, pubsub: pubsub, registry: registry, dynsup: dynsup, sandbox_owner: self()}
    end

    @tag :r14
    test "R14: sub-actions route through Core.execute_action", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # [INTEGRATION] - WHEN batch_sync executes sub-action THEN calls Core
      # (not direct module.execute which bypasses Router)

      agent_id = "agent-#{System.unique_integer([:positive])}"

      {:ok, agent_pid} =
        Core.start_link(
          agent_id: agent_id,
          registry: registry,
          dynsup: dynsup,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          test_mode: true,
          skip_auto_consensus: true
        )

      on_exit(fn ->
        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Execute batch_sync through Core's test handler
      # If sub-actions route through Core, they'll spawn per-action Routers
      batch_action = %{
        action: :batch_sync,
        params: %{
          actions: [
            %{action: :todo, params: %{items: []}},
            %{
              action: :orient,
              params: %{
                current_situation: "testing batch routing",
                goal_clarity: "high",
                available_resources: "test resources",
                key_challenges: "none",
                delegation_consideration: "none"
              }
            }
          ]
        }
      }

      action_id = "test-batch-#{System.unique_integer([:positive])}"

      # Execute the batch - current implementation bypasses Router for sub-actions
      # This test verifies batch completion baseline behavior.
      # Core routing is verified indirectly via R15 (secrets), R16 (permissions),
      # R17 (metrics), and R21 (history) - all of which FAIL proving the bypass.
      capture_log(fn ->
        {:ok, %{results: results}} =
          GenServer.call(agent_pid, {:process_action, batch_action, action_id}, 30_000)

        # batch_sync returns {:ok, %{results: [...]}} - a map with results list
        assert is_list(results), "Batch should return list of results"
        assert length(results) == 2, "Both sub-actions should complete"
      end)
    end

    @tag :r15
    test "R15: sub-action secrets are resolved by Router", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # [INTEGRATION] - WHEN sub-action has secret placeholder THEN secret resolved before execution
      # Router.Security.resolve_secrets/1 handles {{SECRET:name}} placeholders
      # When routed through Core→Router, secrets are resolved before action execution

      # Strategy: Use file_read with a path containing secret placeholder
      # If secrets are resolved: path becomes valid (or at least the placeholder is gone)
      # If secrets NOT resolved: path contains literal "{{SECRET:...}}" which is invalid

      # Create a temp file to read
      temp_dir =
        Path.join([
          System.tmp_dir!(),
          "batch_sync_secret_test",
          "#{System.unique_integer([:positive])}"
        ])

      File.mkdir_p!(temp_dir)
      test_file = Path.join(temp_dir, "test.txt")
      File.write!(test_file, "test content")

      on_exit(fn -> File.rm_rf!(temp_dir) end)

      agent_id = "agent-#{System.unique_integer([:positive])}"

      {:ok, agent_pid} =
        Core.start_link(
          agent_id: agent_id,
          registry: registry,
          dynsup: dynsup,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          test_mode: true,
          skip_auto_consensus: true,
          # Include :file_read capability so permission passes and secret resolution is tested
          capability_groups: [:file_read, :file_write]
        )

      on_exit(fn ->
        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Create a secret that resolves to the test file path
      # If Router.Security.resolve_secrets is called, the placeholder will be replaced
      # with the actual path, and file_read will succeed.
      # If bypassed, the literal placeholder string is used as path, and file_read fails.
      {:ok, _secret} =
        Quoracle.Models.TableSecrets.create(%{
          name: "test_file_path",
          value: test_file
        })

      batch_action = %{
        action: :batch_sync,
        params: %{
          actions: [
            %{action: :todo, params: %{items: []}},
            %{action: :file_read, params: %{path: "{{SECRET:test_file_path}}"}}
          ]
        }
      }

      action_id = "test-batch-secret-#{System.unique_integer([:positive])}"

      # With proper routing through Router.Security.resolve_secrets:
      # - Secret placeholder is resolved to actual file path
      # - file_read succeeds and returns file content
      #
      # With bypass (no Router):
      # - Literal "{{SECRET:test_file_path}}" used as path
      # - file_read fails with :file_not_found
      result = GenServer.call(agent_pid, {:process_action, batch_action, action_id}, 30_000)

      # Verify file_read succeeded (proves secret was resolved)
      assert {:ok, %{results: results}} = result,
             "Batch should succeed when secrets are resolved (got: #{inspect(result)})"

      # Find the file_read result - wrapped in %{action: _, result: inner_result}
      file_read_result =
        Enum.find(results, fn r ->
          r[:action] == "file_read" || r["action"] == "file_read"
        end)

      assert file_read_result != nil,
             "Should have file_read result in: #{inspect(results)}"

      # Get the inner result (file_read returns wrapped result)
      inner_result = file_read_result[:result] || file_read_result["result"]

      # Content includes line numbers (e.g., "1\ttest content")
      content = inner_result[:content] || inner_result["content"]

      assert content =~ "test content",
             "file_read should return content from resolved path (got: #{inspect(inner_result)})"
    end

    @tag :r16
    test "R16: sub-action permissions validated by Router", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # [INTEGRATION] - WHEN sub-action requires permission THEN permission checked by Router
      # Agent with NO :file_read capability trying to file_read as sub-action

      # Create a real temp file so file-not-found doesn't mask permission error
      temp_dir =
        Path.join([
          System.tmp_dir!(),
          "batch_sync_perm_test",
          "#{System.unique_integer([:positive])}"
        ])

      File.mkdir_p!(temp_dir)
      test_file = Path.join(temp_dir, "readable.txt")
      File.write!(test_file, "test content for permission check")

      on_exit(fn -> File.rm_rf!(temp_dir) end)

      agent_id = "agent-#{System.unique_integer([:positive])}"

      # Create agent with only :hierarchy capability (allows batch_sync, not file_read)
      # file_read requires :file_read capability group
      {:ok, agent_pid} =
        Core.start_link(
          agent_id: agent_id,
          registry: registry,
          dynsup: dynsup,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          test_mode: true,
          skip_auto_consensus: true,
          capability_groups: [:hierarchy]
        )

      on_exit(fn ->
        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # file_read requires :file_read capability which :hierarchy doesn't provide
      # The file EXISTS, so any error must be permission-related (not file-not-found)
      batch_action = %{
        action: :batch_sync,
        params: %{
          actions: [
            %{action: :todo, params: %{items: []}},
            %{action: :file_read, params: %{path: test_file}}
          ]
        }
      }

      action_id = "test-batch-perm-#{System.unique_integer([:positive])}"

      # WILL FAIL: Current BatchSync bypasses permission checks for sub-actions
      # Expected: file_read rejected with :action_not_allowed due to missing :file_read capability
      capture_log(fn ->
        result = GenServer.call(agent_pid, {:process_action, batch_action, action_id}, 30_000)

        # With proper permission validation via Core routing:
        # - todo would succeed (base action, always allowed)
        # - file_read would fail with :action_not_allowed (requires :file_read capability)
        # - batch returns partial results with permission error
        case result do
          {:error, :action_not_allowed} ->
            # batch_sync itself blocked - need different capability setup
            flunk("batch_sync blocked - test needs different capability setup")

          {:error, {partial_results, :action_not_allowed}} ->
            # Expected: sub-action permission check via Router
            assert length(partial_results) == 1, "Todo should succeed, file_read should fail"

          {:error, {partial_results, {:error, :action_not_allowed}}} ->
            # Expected: sub-action permission check via Router (wrapped error)
            assert length(partial_results) == 1, "Todo should succeed, file_read should fail"

          {:error, {partial_results, error}} when is_list(partial_results) ->
            # With proper routing, error should be :action_not_allowed
            # With bypass, file_read succeeds (file exists) so we hit {:ok, results} branch instead
            assert error == :action_not_allowed,
                   "Expected :action_not_allowed from permission check, got: #{inspect(error)}"

          {:ok, results} ->
            # Current implementation bypasses permissions for sub-actions
            results_list = if is_list(results), do: results, else: Map.get(results, :results, [])

            # If file_read succeeded on an EXISTING file, permissions were bypassed
            file_read_result = Enum.find(results_list, &(&1.action == "file_read"))

            if file_read_result do
              # File read succeeded - this proves permissions were NOT checked
              # because agent lacks :file_read capability
              flunk(
                "file_read succeeded on existing file despite agent lacking :file_read capability " <>
                  "(current implementation bypasses permission validation for sub-actions)"
              )
            else
              flunk("file_read result not found in batch results")
            end
        end
      end)
    end

    @tag :r17
    test "R17: sub-action metrics tracked by Router", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # [INTEGRATION] - WHEN sub-action completes THEN metrics recorded via telemetry

      agent_id = "agent-#{System.unique_integer([:positive])}"

      {:ok, agent_pid} =
        Core.start_link(
          agent_id: agent_id,
          registry: registry,
          dynsup: dynsup,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          test_mode: true,
          skip_auto_consensus: true
        )

      on_exit(fn ->
        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Track telemetry events
      test_pid = self()
      handler_id = {:test_handler, System.unique_integer([:positive])}

      :telemetry.attach(
        handler_id,
        [:quoracle, :action, :execute, :stop],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, metadata.action_type, measurements})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      batch_action = %{
        action: :batch_sync,
        params: %{
          actions: [
            %{action: :todo, params: %{items: []}},
            %{
              action: :orient,
              params: %{
                current_situation: "testing metrics",
                goal_clarity: "high",
                available_resources: "test resources",
                key_challenges: "none",
                delegation_consideration: "none"
              }
            }
          ]
        }
      }

      action_id = "test-batch-metrics-#{System.unique_integer([:positive])}"

      capture_log(fn ->
        {:ok, _result} =
          GenServer.call(agent_pid, {:process_action, batch_action, action_id}, 30_000)
      end)

      # WILL FAIL: Current BatchSync bypasses Router metrics
      # Expected: Each sub-action should emit telemetry event
      # Telemetry events are delivered synchronously, so they're already in mailbox

      # Check for telemetry events from sub-actions
      # Router emits [:quoracle, :action, :execute, :stop] for each action
      received_todo =
        receive do
          {:telemetry_event, :todo, _measurements} -> true
        after
          100 -> false
        end

      received_orient =
        receive do
          {:telemetry_event, :orient, _measurements} -> true
        after
          100 -> false
        end

      # Both sub-actions should emit telemetry when routed through Core/Router
      assert received_todo,
             "Todo sub-action should emit telemetry event (current implementation bypasses metrics)"

      assert received_orient,
             "Orient sub-action should emit telemetry event (current implementation bypasses metrics)"
    end

    @tag :r18
    test "R18: batch actions execute sequentially", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # [UNIT] - WHEN batch executes THEN actions run sequentially (not parallel)

      agent_id = "agent-#{System.unique_integer([:positive])}"

      {:ok, agent_pid} =
        Core.start_link(
          agent_id: agent_id,
          registry: registry,
          dynsup: dynsup,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          test_mode: true,
          skip_auto_consensus: true
        )

      on_exit(fn ->
        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Use multiple orient actions to verify sequential execution
      orient_params = fn situation ->
        %{
          current_situation: situation,
          goal_clarity: "high",
          available_resources: "test",
          key_challenges: "none",
          delegation_consideration: "none"
        }
      end

      batch_action = %{
        action: :batch_sync,
        params: %{
          actions: [
            %{action: :orient, params: orient_params.("first action")},
            %{action: :orient, params: orient_params.("second action")},
            %{action: :orient, params: orient_params.("third action")}
          ]
        }
      }

      action_id = "test-batch-seq-#{System.unique_integer([:positive])}"

      capture_log(fn ->
        {:ok, result} =
          GenServer.call(agent_pid, {:process_action, batch_action, action_id}, 30_000)

        results = if is_list(result), do: result, else: result.results
        assert length(results) == 3, "All three actions should complete"

        # Verify sequential order preserved
        assert Enum.all?(results, &(&1.action == "orient")), "All should be orient results"
      end)
    end

    @tag :r19
    test "R19: batch stops on first sub-action error", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # [UNIT] - WHEN sub-action fails THEN subsequent actions not executed

      agent_id = "agent-#{System.unique_integer([:positive])}"

      {:ok, agent_pid} =
        Core.start_link(
          agent_id: agent_id,
          registry: registry,
          dynsup: dynsup,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          test_mode: true,
          skip_auto_consensus: true
        )

      on_exit(fn ->
        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # First succeeds, second fails (nonexistent file), third never reached
      batch_action = %{
        action: :batch_sync,
        params: %{
          actions: [
            %{action: :todo, params: %{items: []}},
            %{action: :file_read, params: %{path: "/nonexistent/path/file.txt"}},
            %{action: :todo, params: %{items: []}}
          ]
        }
      }

      action_id = "test-batch-stop-#{System.unique_integer([:positive])}"

      capture_log(fn ->
        result = GenServer.call(agent_pid, {:process_action, batch_action, action_id}, 30_000)

        case result do
          {:error, {partial_results, _error}} ->
            # Correct behavior: stopped on error with partial results
            assert length(partial_results) == 1, "Only first action should have completed"

          {:ok, results} ->
            results_list = if is_list(results), do: results, else: results.results
            # If we got OK, verify third action wasn't reached (error mid-batch)
            assert length(results_list) < 3, "Third action should not execute after error"
        end
      end)
    end

    @tag :r20
    test "R20: batch returns partial results on error", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # [UNIT] - WHEN sub-action fails THEN preceding results returned

      agent_id = "agent-#{System.unique_integer([:positive])}"

      {:ok, agent_pid} =
        Core.start_link(
          agent_id: agent_id,
          registry: registry,
          dynsup: dynsup,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          test_mode: true,
          skip_auto_consensus: true
        )

      on_exit(fn ->
        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # Two succeed (todo with empty items, orient), third fails (nonexistent file)
      batch_action = %{
        action: :batch_sync,
        params: %{
          actions: [
            %{action: :todo, params: %{items: []}},
            %{
              action: :orient,
              params: %{
                current_situation: "test",
                goal_clarity: "high",
                available_resources: "test",
                key_challenges: "none",
                delegation_consideration: "none"
              }
            },
            %{action: :file_read, params: %{path: "/nonexistent/path/file.txt"}}
          ]
        }
      }

      action_id = "test-batch-partial-#{System.unique_integer([:positive])}"

      capture_log(fn ->
        result = GenServer.call(agent_pid, {:process_action, batch_action, action_id}, 30_000)

        case result do
          {:error, {partial_results, _error}} ->
            # Verify partial results contain the two successful actions
            assert length(partial_results) == 2, "Two actions succeeded before failure"
            action_types = Enum.map(partial_results, & &1.action)
            assert "todo" in action_types, "Todo result should be in partial results"
            assert "orient" in action_types, "Orient result should be in partial results"

          {:ok, _} ->
            flunk("Batch should have failed on file_read")
        end
      end)
    end

    @tag :r21
    test "R21: sub-actions recorded in agent history", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # [INTEGRATION] - WHEN batch completes THEN each sub-action recorded separately

      agent_id = "agent-#{System.unique_integer([:positive])}"

      {:ok, agent_pid} =
        Core.start_link(
          agent_id: agent_id,
          registry: registry,
          dynsup: dynsup,
          pubsub: pubsub,
          sandbox_owner: sandbox_owner,
          test_mode: true,
          skip_auto_consensus: true
        )

      on_exit(fn ->
        if Process.alive?(agent_pid) do
          try do
            GenServer.stop(agent_pid, :normal, :infinity)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      batch_action = %{
        action: :batch_sync,
        params: %{
          actions: [
            %{action: :todo, params: %{items: []}},
            %{
              action: :orient,
              params: %{
                current_situation: "testing history",
                goal_clarity: "high",
                available_resources: "test resources",
                key_challenges: "none",
                delegation_consideration: "none"
              }
            }
          ]
        }
      }

      action_id = "test-batch-history-#{System.unique_integer([:positive])}"

      capture_log(fn ->
        {:ok, _result} =
          GenServer.call(agent_pid, {:process_action, batch_action, action_id}, 30_000)
      end)

      # Allow casts to be processed - sync call forces mailbox drain
      _ = GenServer.call(agent_pid, :sync)

      # Get model histories and check for sub-action entries
      {:ok, histories} = Core.get_model_histories(agent_pid)

      # Find entries that reference our sub-actions
      # Raw history entries have format: %{type: :result, content: ..., timestamp: ...}
      all_entries =
        histories
        |> Map.values()
        |> List.flatten()

      # Look for :result type entries from our sub-actions
      history_actions =
        all_entries
        |> Enum.filter(fn entry ->
          case entry do
            %{type: :result} -> true
            _ -> false
          end
        end)

      # With proper routing, each sub-action result is recorded via :batch_action_result cast
      assert history_actions != [],
             "Sub-action results should be recorded in agent history " <>
               "(current implementation bypasses history recording)"
    end

    @tag :r22
    @tag :property
    property "R22: batch results match sequential individual execution", %{
      pubsub: pubsub,
      registry: registry,
      dynsup: dynsup,
      sandbox_owner: sandbox_owner
    } do
      # [PROPERTY] - FOR ALL valid batches, batch_sync produces same results as individual execution

      # Generator for orient params (required fields only)
      orient_params_gen =
        StreamData.fixed_map(%{
          current_situation: StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
          goal_clarity: StreamData.member_of(["high", "medium", "low"]),
          available_resources: StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
          key_challenges: StreamData.string(:alphanumeric, min_length: 1, max_length: 20),
          delegation_consideration:
            StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
        })

      # Generator for batchable actions (todo and orient are simplest)
      action_gen =
        StreamData.one_of([
          StreamData.constant(%{action: :todo, params: %{items: []}}),
          StreamData.map(orient_params_gen, fn params -> %{action: :orient, params: params} end)
        ])

      # Generate batches of 2-4 actions
      batch_gen = StreamData.list_of(action_gen, min_length: 2, max_length: 4)

      check all(actions <- batch_gen, max_runs: 10) do
        agent_id = "agent-#{System.unique_integer([:positive])}"

        {:ok, agent_pid} =
          Core.start_link(
            agent_id: agent_id,
            registry: registry,
            dynsup: dynsup,
            pubsub: pubsub,
            sandbox_owner: sandbox_owner,
            test_mode: true,
            skip_auto_consensus: true
          )

        try do
          # Execute as batch
          batch_action = %{action: :batch_sync, params: %{actions: actions}}
          batch_action_id = "batch-#{System.unique_integer([:positive])}"

          capture_log(fn ->
            {:ok, %{results: batch_results}} =
              GenServer.call(agent_pid, {:process_action, batch_action, batch_action_id}, 30_000)

            # Execute each action individually
            individual_results =
              Enum.map(actions, fn action_spec ->
                action_id = "individual-#{System.unique_integer([:positive])}"
                action = %{action: action_spec.action, params: action_spec.params}

                {:ok, result} =
                  GenServer.call(agent_pid, {:process_action, action, action_id}, 30_000)

                result
              end)

            # Batch returns %{results: [...]} with :action and :result keys
            # Individual returns direct result maps
            # Compare action types and result structure
            batch_action_types = Enum.map(batch_results, & &1.action)
            individual_action_types = Enum.map(actions, fn %{action: a} -> to_string(a) end)

            assert batch_action_types == individual_action_types,
                   "Batch action types should match individual execution order"

            assert length(batch_results) == length(individual_results),
                   "Batch should return same number of results as individual execution"
          end)
        after
          GenServer.stop(agent_pid, :normal, :infinity)
        end
      end
    end
  end
end
